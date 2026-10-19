import CSQLite
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

extension ItemIndex {
    /// Internal writer-only analysis. The caller supplies the existing verified byte loader;
    /// this has no client-serving, intake, authorization or publication side effect.
    func analyzeRevisionProjection(
        itemID: String, loadVerified: @escaping (CatalogueRow) throws -> PooledCanonicalRecord,
        limits: RevisionProjection.Limits = .init(), progress: (() throws -> Void)? = nil,
        reusingActiveBudget: Bool = false
    ) throws -> RevisionProjection.Snapshot {
        guard !revisionProjectionActive else {
            throw TractandaError("indexTransient", "A projection operation already owns this catalogue.")
        }
        guard limits.maximumVMInstructions > 0, limits.maximumHydratedBytes > 0,
            limits.maximumResultBytes > 0, limits.maximumCandidateCount > 0,
            limits.maximumFrontierCount > 0, limits.maximumStagingBytes > 0
        else {
            throw TractandaError("resourceLimit", "Invalid projection resource limits.")
        }
        revisionProjectionActive = true
        defer { revisionProjectionActive = false }
        let oldVM = graphMaximumVMInstructions
        let oldBytes = graphMaximumTemporaryBytes
        let oldReserve = graphReserveBytes
        graphMaximumVMInstructions = min(oldVM, limits.maximumVMInstructions)
        graphMaximumTemporaryBytes = min(oldBytes, limits.maximumStagingBytes)
        graphReserveBytes = max(oldReserve, limits.minimumFreeBytes)
        defer {
            graphMaximumVMInstructions = oldVM
            graphMaximumTemporaryBytes = oldBytes
            graphReserveBytes = oldReserve
        }
        try execute("SAVEPOINT revision_projection")
        do {
            let operation = DiskRevisionProjection(
                index: self, itemID: itemID, limits: limits, load: loadVerified, progress: progress)
            let result = try withCatalogueScanBudget(
                progress: progress, reusingActiveBudget: reusingActiveBudget
            ) {
                // One work allowance covers admission (when stale), analysis and cleanup.
                try prepareRevisionProjectionGraph(progress: progress)
                let result = try operation.run()
                try operation.clear()
                lastAnalyzedProjection = result
                return result
            }
            try execute("RELEASE revision_projection")
            return result
        } catch {
            // Admission may have succeeded inside the savepoint before a later failure.
            invalidateRevisionGraphValidation()
            try? execute("ROLLBACK TO revision_projection")
            try? execute("RELEASE revision_projection")
            throw error
        }
    }
}

/// All history-sized state is in the owning main database. Swift retains bounded witnesses,
/// one canonical record, sparse candidates and the explicitly byte-capped final field map.
private final class DiskRevisionProjection {
    let index: ItemIndex
    let itemID: String
    let limits: RevisionProjection.Limits
    let load: (ItemIndex.CatalogueRow) throws -> PooledCanonicalRecord
    let progress: (() throws -> Void)?
    var hydrated: UInt64 = 0
    var resultBytes = 0
    var staging: UInt64 = 0
    var cached: (String, Revision)?
    let tables = [
        "rp_nodes", "rp_segments", "rp_writes", "rp_frontier", "rp_scope", "rp_fields", "rp_memo",
        "rp_origins", "rp_lookup", "rp_seen", "rp_ready",
    ]

    init(
        index: ItemIndex, itemID: String, limits: RevisionProjection.Limits,
        load: @escaping (ItemIndex.CatalogueRow) throws -> PooledCanonicalRecord,
        progress: (() throws -> Void)?
    ) {
        self.index = index
        self.itemID = itemID
        self.limits = limits
        self.load = load
        self.progress = progress
    }
    func setup() throws {
        // Admission work tables coexist with the item memo: share the staging ceiling.
        let count = try number("SELECT COUNT(*) FROM revision_catalog")
        let edges = try number("SELECT COUNT(*) FROM revision_parents")
        let legacy = try number(
            "SELECT COALESCE(SUM(length(CAST(v.field AS BLOB))+length(CAST(v.digest AS BLOB))+512),0) FROM revision_field_values v JOIN revision_catalog r ON r.revision=v.revision WHERE r.provenance IS NULL"
        )
        guard count >= 0, edges >= 0, legacy >= 0 else {
            throw resource("Admission staging estimate overflowed.")
        }
        for (amount, copies) in [(count, Int64(512)), (edges, Int64(128)), (legacy, Int64(4))] {
            let bytes = UInt64(amount).multipliedReportingOverflow(by: UInt64(copies))
            guard !bytes.overflow else { throw resource("Admission staging estimate overflowed.") }
            try charge(bytes.partialValue)
        }
        try capacity()
        for sql in [
            "CREATE TABLE IF NOT EXISTS rp_nodes(revision TEXT PRIMARY KEY,ordinal INTEGER NOT NULL,segment TEXT NOT NULL,position INTEGER NOT NULL,kind TEXT NOT NULL,protected_class INTEGER NOT NULL,validated INTEGER NOT NULL DEFAULT 0)",
            "CREATE INDEX IF NOT EXISTS rp_node_order ON rp_nodes(ordinal,revision)",
            "CREATE TABLE IF NOT EXISTS rp_segments(segment TEXT NOT NULL,parent TEXT NOT NULL,PRIMARY KEY(segment,parent))",
            "CREATE TABLE IF NOT EXISTS rp_writes(segment TEXT NOT NULL,field TEXT NOT NULL,position INTEGER NOT NULL,writer TEXT NOT NULL,PRIMARY KEY(segment,field,position,writer))",
            "CREATE TABLE IF NOT EXISTS rp_frontier(revision TEXT NOT NULL,author TEXT NOT NULL,PRIMARY KEY(revision,author))",
            "CREATE TABLE IF NOT EXISTS rp_scope(revision TEXT PRIMARY KEY)",
            "CREATE TABLE IF NOT EXISTS rp_fields(field TEXT PRIMARY KEY)",
            "CREATE TABLE IF NOT EXISTS rp_memo(revision TEXT NOT NULL,field TEXT NOT NULL,ready INTEGER NOT NULL,PRIMARY KEY(revision,field))",
            "CREATE TABLE IF NOT EXISTS rp_origins(revision TEXT NOT NULL,field TEXT NOT NULL,writer TEXT NOT NULL,PRIMARY KEY(revision,field,writer))",
            "CREATE TABLE IF NOT EXISTS rp_lookup(revision TEXT NOT NULL,field TEXT NOT NULL,ordinal INTEGER NOT NULL,PRIMARY KEY(revision,field))",
            "CREATE INDEX IF NOT EXISTS rp_lookup_order ON rp_lookup(ordinal,revision,field)",
            "CREATE TABLE IF NOT EXISTS rp_seen(segment TEXT PRIMARY KEY)",
            "CREATE TABLE IF NOT EXISTS rp_ready(segment TEXT PRIMARY KEY)",
        ] { try index.execute(sql) }
        try clear()
    }
    func clear() throws { for table in tables { try index.execute("DELETE FROM \(table)") } }
    func boundary() throws {
        try Task.checkCancellation()
        try progress?()
        try capacity()
    }
    func capacity() throws {
        let path =
            index.corpusIndexPath == ":memory:"
            ? FileManager.default.temporaryDirectory.path
            : URL(fileURLWithPath: index.corpusIndexPath).deletingLastPathComponent().path
        var value = statvfs()
        guard statvfs(path, &value) == 0, value.f_frsize > 0 else {
            throw resource("Cannot determine projection filesystem capacity.")
        }
        let free = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_frsize))
        let needed = max(limits.minimumFreeBytes, index.graphReserveBytes).addingReportingOverflow(staging)
        guard !free.overflow, !needed.overflow, free.partialValue >= needed.partialValue else {
            throw resource("Projection cannot retain its filesystem reserve.")
        }
    }
    func charge(_ bytes: UInt64) throws {
        let sum = staging.addingReportingOverflow(bytes)
        guard !sum.overflow,
            sum.partialValue <= min(limits.maximumStagingBytes, index.graphMaximumTemporaryBytes)
        else {
            throw resource("Projection memo/queue staging exceeded its byte budget.")
        }
        staging = sum.partialValue
    }
    func resource(_ message: String) -> TractandaError { TractandaError("resourceLimit", message) }
    func invalid(_ message: String) -> TractandaError { TractandaError("invalidRevisionGraph", message) }
    func strings(_ sql: String, _ args: [String] = [], maximum: Int? = nil) throws -> [String] {
        let statement = try index.corpusPrepare(sql, args)
        defer { sqlite3_finalize(statement) }
        var output: [String] = []
        var bytes = 0
        while true {
            let status = index.catalogueStep(statement)
            if status == SQLITE_DONE { return output }
            guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
                throw index.graphSQLiteError()
            }
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard size <= limits.maximumResultBytes - bytes,
                output.count < (maximum ?? limits.maximumCandidateCount)
            else { throw resource("Projection witness list exceeded its window.") }
            bytes += size
            output.append(String(cString: value))
        }
    }
    func number(_ sql: String, _ args: [String] = []) throws -> Int64 {
        let statement = try index.corpusPrepare(sql, args)
        defer { sqlite3_finalize(statement) }
        guard index.catalogueStep(statement) == SQLITE_ROW else { throw index.graphSQLiteError() }
        return sqlite3_column_int64(statement, 0)
    }
    func pair(_ sql: String, _ args: [String] = []) throws -> (String, Int64)? {
        let statement = try index.corpusPrepare(sql, args)
        defer { sqlite3_finalize(statement) }
        let status = index.catalogueStep(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw index.graphSQLiteError()
        }
        guard sqlite3_column_bytes(statement, 0) <= limits.maximumResultBytes else {
            throw resource("Projection identifier exceeds its window.")
        }
        return (String(cString: value), sqlite3_column_int64(statement, 1))
    }
    func revision(_ id: String) throws -> Revision {
        if let cached, cached.0 == id { return cached.1 }
        guard let row = try index.revision(id), row.itemID == itemID else {
            throw invalid("Projection loader references another or missing item.")
        }
        let sum = hydrated.addingReportingOverflow(row.size)
        guard !sum.overflow, sum.partialValue <= limits.maximumHydratedBytes else {
            throw resource("Cumulative verified projection bytes exceeded their window.")
        }
        hydrated = sum.partialValue
        let record = try load(row)
        let value = record.revision
        let metadata = record.metadata
        guard value.itemID == row.itemID, value.revisionID == row.revisionID,
            value.supersedes == row.parentID,
            value.modifiedAt == row.modifiedAt, try value.provenance == row.provenance,
            value.fields["createdAt"]?.dateString == row.createdAt,
            value.fields["actor"]?.string == row.actor,
            value.fields["operationID"]?.string == row.operationID,
            metadata.size == row.size, metadata.inode == row.inode, metadata.uid == row.uid,
            metadata.mode == row.mode,
            metadata.modificationSeconds == row.modificationSeconds,
            metadata.modificationNanoseconds == row.modificationNanoseconds,
            try index.revision(id) == row
        else { throw invalid("Verified projection hydration changed its canonical row binding.") }
        try value.validate()
        try ItemSemantics.validate(value)
        let fields = RevisionMerge.semanticFields(value)
        let fingerprints = try index.corpusPrepare(
            "SELECT field,digest FROM revision_field_values WHERE revision=? ORDER BY field", [id])
        defer { sqlite3_finalize(fingerprints) }
        var checked = 0
        while true {
            let status = index.catalogueStep(fingerprints)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,
                let key = sqlite3_column_text(fingerprints, 0),
                let digest = sqlite3_column_text(fingerprints, 1),
                sqlite3_column_bytes(fingerprints, 0) <= limits.maximumResultBytes,
                sqlite3_column_bytes(fingerprints, 1) == 64
            else { throw invalid("Normalized field fingerprints are malformed.") }
            let field = String(cString: key)
            guard let canonical = fields[field],
                try ItemIndex.graphValueDigest(canonical) == String(cString: digest)
            else { throw invalid("Normalized fields differ from verified canonical bytes.") }
            checked += 1
        }
        guard checked == fields.count else {
            throw invalid("Normalized fields omit verified canonical values.")
        }
        cached = (id, value)
        return value
    }
    func run() throws -> RevisionProjection.Snapshot {
        try boundary()
        try setup()
        guard try index.revisionCount(itemID: itemID) > 0 else {
            throw invalid("No accepted revisions exist for projection.")
        }
        var cursor: Int64 = 0
        while let next = try pair(
            "SELECT r.revision,o.ordinal FROM recovery_ordinals o JOIN revision_catalog r ON r.revision=o.revision AND r.item=o.item WHERE o.item=? AND o.ordinal>? ORDER BY o.ordinal LIMIT 1",
            [itemID, String(cursor)])
        {
            cursor = next.1
            let value = try revision(next.0)
            let parents = try strings(
                "SELECT parent FROM revision_parents WHERE child=? ORDER BY parent", [next.0])
            var segment = next.0
            var position: Int64 = 1
            if parents.count == 1,
                try number("SELECT COUNT(*) FROM revision_parents WHERE parent=?", [parents[0]]) == 1,
                let inherited = try pair(
                    "SELECT segment,position FROM rp_nodes WHERE revision=?", [parents[0]])
            {
                segment = inherited.0
                position = inherited.1 + 1
            }
            try charge(UInt64(next.0.utf8.count + segment.utf8.count + 512))
            let kind = try value.provenance?.kind.rawValue ?? "authored"
            try index.execute(
                "INSERT INTO rp_nodes VALUES(?,?,?,?,?,?,0)",
                [
                    next.0, String(next.1), segment, String(position), kind,
                    RevisionMerge.protectedClasses.contains(value.classID) ? "1" : "0",
                ])
            if position == 1 {
                for parent in parents {
                    try charge(512)
                    try index.execute("INSERT INTO rp_segments VALUES(?,?)", [segment, parent])
                }
            }
            let writeBytes = try number(
                "SELECT COALESCE(SUM(length(CAST(field AS BLOB))*2+length(CAST(revision AS BLOB))*2+1024),0) FROM revision_field_writes WHERE revision=?",
                [next.0])
            guard writeBytes >= 0 else { throw resource("Projection write estimate overflowed.") }
            try charge(UInt64(writeBytes))
            try index.execute(
                "INSERT INTO rp_writes SELECT ?,field,?,revision FROM revision_field_writes WHERE revision=?",
                [segment, String(position), next.0])
            try validateNode(value, parents: parents)
            try index.execute("UPDATE rp_nodes SET validated=1 WHERE revision=?", [next.0])
            if cursor % 128 == 0 { try boundary() }
        }
        // Also check the final partial batch before exposing any computed result.
        try boundary()
        let heads = try strings(
            "SELECT revision FROM revision_catalog r WHERE item=? AND NOT EXISTS(SELECT 1 FROM revision_parents p WHERE p.parent=r.revision) ORDER BY revision",
            [itemID], maximum: limits.maximumFrontierCount)
        let frontier = try contextFrontier(heads)
        let clockRows = try index.graphCatalogueRows(
            where: "WHERE item=? ORDER BY modified_ticks DESC,revision DESC", bindings: [itemID], limit: 1)
        guard let clock = clockRows.first else { throw invalid("Accepted projection has no clock witness.") }
        resultBytes = 0
        try chargeResult(512 + itemID.utf8.count)
        for id in heads + frontier { try chargeResult(id.utf8.count + 64) }
        try chargeResult(clock.revisionID.utf8.count + clock.modifiedAt.utf8.count + 128)
        let state = try evaluate(heads, frontier: frontier, output: nil, retainedBytes: resultBytes)
        var representative: String?
        if state.isResolved {
            if frontier.count == 1 {
                representative = frontier[0]
            }
            do {
                let statement = try index.corpusPrepare(
                    "SELECT revision FROM rp_nodes WHERE kind='automaticMerge' ORDER BY ordinal")
                defer { sqlite3_finalize(statement) }
                while true {
                    let status = index.catalogueStep(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { throw index.graphSQLiteError() }
                    let id = String(cString: sqlite3_column_text(statement, 0)!)
                    if try nodeFrontier(id) == frontier {
                        if let existing = representative {
                            if try newer(id, than: existing) { representative = id }
                        } else {
                            representative = id
                        }
                    }
                }
            }
        }
        let row = try representative.flatMap { try index.revision($0) }
        if let row { try chargeResult(row.revisionID.utf8.count + row.modifiedAt.utf8.count + 128) }
        var needs = state.isResolved && row == nil
        if state.isResolved, let row {
            needs = try RevisionTimestamp(row.modifiedAt) < RevisionTimestamp(clock.modifiedAt)
        }
        let analysis = RevisionMerge.Analysis(
            frontier: frontier, values: state.values, conflicts: state.conflicts,
            protectedFields: state.protectedFields, representativeRevisionID: representative,
            needsMaterialization: needs)
        return .init(
            itemID: itemID, analysis: analysis,
            representative: row.map { .init(revisionID: $0.revisionID, modifiedAt: $0.modifiedAt) },
            clockFloor: .init(revisionID: clock.revisionID, modifiedAt: clock.modifiedAt),
            physicalHeads: heads)
    }
    func newer(_ id: String, than other: String) throws -> Bool {
        let a = try index.revision(id)!
        let b = try index.revision(other)!
        let ta = try RevisionTimestamp(a.modifiedAt)
        let tb = try RevisionTimestamp(b.modifiedAt)
        return ta > tb || (ta == tb && id > other)
    }

    func ancestor(_ old: String, of descendant: String) throws -> Bool {
        if old == descendant { return true }
        guard let a = try pair("SELECT segment,position FROM rp_nodes WHERE revision=?", [old]),
            let b = try pair("SELECT segment,position FROM rp_nodes WHERE revision=?", [descendant])
        else { throw invalid("Causal lookup precedes validated graph order.") }
        if a.0 == b.0 { return a.1 <= b.1 }
        try index.execute("DELETE FROM rp_seen")
        try index.execute("DELETE FROM rp_ready")
        try charge(512)
        try index.execute("INSERT INTO rp_ready VALUES(?)", [b.0])
        var visits = 0
        while let next = try pair("SELECT segment,0 FROM rp_ready ORDER BY segment LIMIT 1") {
            try index.execute("DELETE FROM rp_ready WHERE segment=?", [next.0])
            try charge(512)
            try index.execute("INSERT OR IGNORE INTO rp_seen VALUES(?)", [next.0])
            let parents = try strings(
                "SELECT parent FROM rp_segments WHERE segment=? ORDER BY parent", [next.0])
            for parent in parents {
                guard let point = try pair("SELECT segment,position FROM rp_nodes WHERE revision=?", [parent])
                else { throw invalid("Segment boundary references an unknown node.") }
                if point.0 == a.0, point.1 >= a.1 { return true }
                try charge(512)
                try index.execute(
                    "INSERT OR IGNORE INTO rp_ready SELECT ? WHERE NOT EXISTS(SELECT 1 FROM rp_seen WHERE segment=?)",
                    [point.0, point.0])
            }
            visits += 1
            if visits % 128 == 0 { try boundary() }
        }
        return false
    }
    func reduce(_ input: [String]) throws -> [String] {
        let unique = Array(Set(input)).sorted()
        guard unique.count <= limits.maximumCandidateCount else {
            throw resource("Causal candidates exceed their count window.")
        }
        var output: [String] = []
        for candidate in unique {
            var dominated = false
            for other in unique where other != candidate {
                if try ancestor(candidate, of: other) {
                    dominated = true
                    break
                }
            }
            if !dominated { output.append(candidate) }
        }
        return output
    }
    func nodeFrontier(_ node: String) throws -> [String] {
        try strings(
            "SELECT author FROM rp_frontier WHERE revision=? ORDER BY author", [node],
            maximum: limits.maximumFrontierCount)
    }
    func contextFrontier(_ parents: [String]) throws -> [String] {
        var values: Set<String> = []
        for parent in parents {
            for value in try nodeFrontier(parent) {
                values.insert(value)
                guard values.count <= limits.maximumFrontierCount else {
                    throw resource("Parent frontier union exceeds its window.")
                }
            }
        }
        let reduced = try reduce(Array(values))
        guard reduced.count <= limits.maximumFrontierCount else {
            throw resource("Authored frontier exceeds its window.")
        }
        return reduced
    }
    func origins(_ node: String, field: String) throws -> [String] {
        if try number("SELECT COUNT(*) FROM rp_memo WHERE revision=? AND field=? AND ready=1", [node, field])
            == 0
        {
            try charge(UInt64(node.utf8.count + field.utf8.count + 512))
            try index.execute(
                "INSERT OR IGNORE INTO rp_lookup SELECT revision,?,ordinal FROM rp_nodes WHERE revision=?",
                [field, node])
        }
        while let next = try pair("SELECT revision,ordinal FROM rp_lookup ORDER BY ordinal,revision LIMIT 1")
        {
            // All requests in this work queue concern this field; clear after completion.
            if try number(
                "SELECT COUNT(*) FROM rp_memo WHERE revision=? AND field=? AND ready=1", [next.0, field]) > 0
            {
                try index.execute("DELETE FROM rp_lookup WHERE revision=? AND field=?", [next.0, field])
                continue
            }
            guard let point = try pair("SELECT segment,position FROM rp_nodes WHERE revision=?", [next.0])
            else { throw invalid("Origin lookup has no segment.") }
            let newest = try strings(
                "SELECT writer FROM rp_writes WHERE segment=? AND field=? AND position<=? ORDER BY position DESC LIMIT 1",
                [point.0, field, String(point.1)], maximum: 1)
            var writers = newest
            if newest.isEmpty {
                let parents = try strings(
                    "SELECT parent FROM rp_segments WHERE segment=? ORDER BY parent", [point.0])
                var ready = true
                for parent in parents {
                    if try number(
                        "SELECT COUNT(*) FROM rp_memo WHERE revision=? AND field=? AND ready=1",
                        [parent, field]) == 0
                    {
                        try charge(UInt64(parent.utf8.count + field.utf8.count + 512))
                        try index.execute(
                            "INSERT OR IGNORE INTO rp_lookup SELECT revision,?,ordinal FROM rp_nodes WHERE revision=?",
                            [field, parent])
                        ready = false
                    }
                }
                if !ready { continue }
                var union: Set<String> = []
                for parent in parents {
                    for writer in try strings(
                        "SELECT writer FROM rp_origins WHERE revision=? AND field=? ORDER BY writer",
                        [parent, field])
                    {
                        union.insert(writer)
                        guard union.count <= limits.maximumCandidateCount else {
                            throw resource("Origin union exceeds its candidate window.")
                        }
                    }
                }
                writers = try reduce(Array(union))
            }
            try index.execute("INSERT OR REPLACE INTO rp_memo VALUES(?,?,1)", [next.0, field])
            for writer in writers {
                try charge(UInt64(next.0.utf8.count + field.utf8.count + writer.utf8.count + 512))
                try index.execute("INSERT OR IGNORE INTO rp_origins VALUES(?,?,?)", [next.0, field, writer])
            }
            try index.execute("DELETE FROM rp_lookup WHERE revision=? AND field=?", [next.0, field])
        }
        return try strings(
            "SELECT writer FROM rp_origins WHERE revision=? AND field=? ORDER BY writer", [node, field])
    }
    func write(_ writer: String, field: String) throws -> RevisionFieldWrite {
        let actions = try strings(
            "SELECT action FROM revision_field_writes WHERE revision=? AND field=?", [writer, field],
            maximum: 1)
        guard let action = actions.first else {
            throw invalid("Resolved origin has no authored field write.")
        }
        let value = try revision(writer).fields[field]
        if action == "unset" {
            guard value == nil else { throw invalid("Canonical unset still has a value.") }
            return .unset
        }
        guard action == "set", let value else { throw invalid("Canonical authored set has no value.") }
        return .set(value)
    }
    func chargeValue(_ write: RevisionFieldWrite, field: String, writer: String?) throws {
        let encoded: Int
        switch write {
        case .set(let value): encoded = try JSON.encode(value).count
        case .unset: encoded = 32
        }
        let fieldBytes = try JSON.encode(ItemValue.text(field)).count
        let extra = encoded.addingReportingOverflow(fieldBytes + (writer?.utf8.count ?? 0) + 128)
        guard !extra.overflow, extra.partialValue <= limits.maximumResultBytes - resultBytes else {
            throw resource("Accumulated projection fields/candidates exceed their byte window.")
        }
        resultBytes += extra.partialValue
    }
    func chargeResult(_ bytes: Int) throws {
        guard bytes >= 0, bytes <= limits.maximumResultBytes - resultBytes else {
            throw resource("Complete projection result metadata exceeds its byte window.")
        }
        resultBytes += bytes
    }
    func evaluate(
        _ parents: [String], frontier: [String], output: String?, retainedBytes: Int = 0
    ) throws -> RevisionMerge.Analysis {
        resultBytes = retainedBytes
        try index.execute("DELETE FROM rp_scope")
        try index.execute("DELETE FROM rp_fields")
        for parent in parents {
            try charge(512)
            try index.execute("INSERT OR IGNORE INTO rp_scope VALUES(?)", [parent])
        }
        // Include authored unsets even when every current snapshot omits the field.
        // Other accepted contexts may add names, but origins are resolved only in parents.
        var fieldBytes = 0
        func addNames(_ sql: String, _ bindings: [String] = []) throws {
            let names = try index.corpusPrepare(sql, bindings)
            defer { sqlite3_finalize(names) }
            while true {
                let status = index.catalogueStep(names)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let raw = sqlite3_column_text(names, 0) else {
                    throw index.graphSQLiteError()
                }
                let size = Int(sqlite3_column_bytes(names, 0))
                guard size <= limits.maximumResultBytes else {
                    throw resource("Projection field name exceeds its byte window.")
                }
                let field = String(cString: raw)
                if try number("SELECT COUNT(*) FROM rp_fields WHERE field=?", [field]) > 0 { continue }
                let extra = size.addingReportingOverflow(128)
                let storage = size.multipliedReportingOverflow(by: 2)
                let indexed = storage.partialValue.addingReportingOverflow(512)
                guard !extra.overflow, !storage.overflow, !indexed.overflow,
                    extra.partialValue <= limits.maximumResultBytes - fieldBytes
                else { throw resource("Projection field-name stream exceeds its byte window.") }
                fieldBytes += extra.partialValue
                try charge(UInt64(indexed.partialValue))
                try index.execute("INSERT INTO rp_fields VALUES(?)", [field])
            }
        }
        // No DISTINCT/UNION ephemeral set may materialize before the byte guard.
        try addNames(
            "SELECT w.field FROM revision_field_writes w JOIN rp_nodes n ON n.revision=w.revision WHERE n.validated=1"
        )
        if let output {
            try addNames("SELECT field FROM revision_field_values WHERE revision=?", [output])
            try addNames("SELECT field FROM revision_field_writes WHERE revision=?", [output])
        }
        var protectedClass = false
        let classes = try index.corpusPrepare(
            "SELECT revision FROM rp_nodes WHERE protected_class=1 AND kind!='automaticMerge' ORDER BY ordinal"
        )
        defer { sqlite3_finalize(classes) }
        while true {
            let status = index.catalogueStep(classes)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw index.graphSQLiteError() }
            let id = String(cString: sqlite3_column_text(classes, 0)!)
            for parent in parents where !protectedClass {
                if try ancestor(id, of: parent) { protectedClass = true }
            }
            if protectedClass { break }
        }
        var values: [String: RevisionFieldWrite] = [:]
        var conflicts: [String: [RevisionMerge.Candidate]] = [:]
        var protected: Set<String> = []
        let fields = try index.corpusPrepare("SELECT field FROM rp_fields ORDER BY field")
        defer { sqlite3_finalize(fields) }
        while true {
            let status = index.catalogueStep(fields)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_text(fields, 0) else {
                throw index.graphSQLiteError()
            }
            let field = String(cString: bytes)
            var uniqueCandidates: Set<String> = []
            for parent in parents {
                for candidate in try origins(parent, field: field) {
                    uniqueCandidates.insert(candidate)
                    guard uniqueCandidates.count <= limits.maximumCandidateCount else {
                        throw resource("Field origin union exceeds its window.")
                    }
                }
            }
            let candidates = try reduce(Array(uniqueCandidates))
            var choices: [RevisionMerge.Candidate] = []
            for candidate in candidates {
                let value = try write(candidate, field: field)
                try chargeValue(value, field: field, writer: candidate)
                choices.append(.init(revisionID: candidate, write: value))
                if protectedClass || RevisionMerge.protectedFields.contains(field) {
                    for head in frontier where head != candidate {
                        if try !ancestor(candidate, of: head), try !ancestor(head, of: candidate) {
                            if protected.insert(field).inserted {
                                try chargeResult(try JSON.encode(ItemValue.text(field)).count + 32)
                            }
                        }
                    }
                }
            }
            if let first = choices.first {
                if choices.allSatisfy({ $0.write == first.write }) {
                    values[field] = first.write
                } else {
                    conflicts[field] = choices
                }
            }
        }
        return .init(
            frontier: frontier, values: values, conflicts: conflicts, protectedFields: protected,
            representativeRevisionID: nil, needsMaterialization: false)
    }
    func validateNode(_ value: Revision, parents: [String]) throws {
        let beforeFrontier = try contextFrontier(parents)
        if let provenance = try value.provenance, provenance.kind != .authored {
            guard provenance.frontier == beforeFrontier else {
                throw invalid("Materialization/resolution frontier differs from actual parents.")
            }
            let before = try evaluate(parents, frontier: beforeFrontier, output: value.revisionID)
            var expected = before.fields
            if provenance.kind == .automaticMerge {
                guard
                    [RevisionMerge.profile, AuthorityStore.reconciliationProfile].contains(
                        provenance.mergeProfile ?? ""), before.isResolved,
                    !beforeFrontier.isEmpty
                else { throw invalid("Automatic materialization is ineligible.") }
                if provenance.mergeProfile == AuthorityStore.reconciliationProfile {
                    try index.validateAuthorityReconciliationMetadata(value)
                }
                var equivalent: [RevisionTimestamp] = []
                var witness: [RevisionTimestamp] = []
                for parent in parents {
                    let time = try RevisionTimestamp(index.revision(parent)!.modifiedAt)
                    if try nodeFrontier(parent) == beforeFrontier {
                        equivalent.append(time)
                    } else {
                        witness.append(time)
                    }
                }
                if provenance.mergeProfile == RevisionMerge.profile, let current = equivalent.max() {
                    guard let maximum = witness.max(), maximum > current else {
                        throw invalid("Equivalent-only materialization has no advancing witness.")
                    }
                }
            } else {
                let addressed = Set(provenance.writtenFields + provenance.unsetFields)
                guard Set(before.conflicts.keys).union(before.protectedFields).isSubset(of: addressed) else {
                    throw invalid("Resolution omitted a conflicting/protected field choice.")
                }
                for field in provenance.writtenFields { expected[field] = value.fields[field]! }
                for field in provenance.unsetFields { expected.removeValue(forKey: field) }
            }
            guard expected == RevisionMerge.semanticFields(value) else {
                throw invalid("Materialization/resolution payload differs from authored causes.")
            }
            for parent in parents {
                guard
                    try RevisionTimestamp(value.modifiedAt)
                        > RevisionTimestamp(index.revision(parent)!.modifiedAt)
                else { throw invalid("Materialization time does not exceed each actual parent.") }
            }
        }
        if try value.provenance?.mergeProfile == AuthorityStore.reconciliationProfile {
            try index.completeAuthorityReconciliationProjection(value)
        }
        try index.completeRecoveryAuthorityReview(resolutionID: value.revisionID)
        let kind = try value.provenance?.kind
        let frontier = kind == .automaticMerge ? beforeFrontier : [value.revisionID]
        for author in frontier {
            try charge(512)
            try index.execute("INSERT INTO rp_frontier VALUES(?,?)", [value.revisionID, author])
        }
    }
}
