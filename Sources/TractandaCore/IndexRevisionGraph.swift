import CSQLite
import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// One scan owns the connection's progress handler. No transitive closure is retained.
final class CatalogueScanBudget {
    var remaining: Int64
    var exhausted = false
    var cancelled = false
    var callbackError: Error?
    let progress: (() throws -> Void)?
    let quantum: Int64
    struct StepFrame {
        let before: Int32
        var pending: Int64 = 0
    }
    var frames: [StepFrame] = []
    init(maximum: Int64, progress: (() throws -> Void)?) {
        remaining = maximum
        self.progress = progress
        quantum = min(1000, maximum)
    }

    func requireAvailable() throws {
        if let callbackError { throw callbackError }
        guard !cancelled else { throw TractandaError("cancelled", "Catalogue scan was cancelled.") }
        guard remaining > 0, !exhausted else {
            exhausted = true
            throw TractandaError("resourceLimit", "Catalogue statement work budget exceeded.")
        }
    }

    func beginStep(before: Int32) -> Bool {
        guard callbackError == nil, !cancelled, !exhausted, remaining > 0,
            before >= 0, frames.count < 8
        else {
            exhausted = callbackError == nil && !cancelled
            return false
        }
        frames.append(.init(before: before))
        return true
    }

    func finishStep(after: Int32) -> Bool {
        guard let frame = frames.popLast(), after >= frame.before else {
            // A reset/wrap during a running step cannot be accounted reliably.
            exhausted = true
            return false
        }
        let measured = Int64(after) - Int64(frame.before)
        guard measured <= remaining else {
            exhausted = true
            return false
        }
        remaining -= measured
        return callbackError == nil && !cancelled && !exhausted
    }

    func progressWorkFits() -> Bool {
        if frames.isEmpty {
            // SQLite can also invoke progress during prepare/schema work, which has no VM counter.
            guard remaining >= quantum else {
                exhausted = true
                return false
            }
            remaining -= quantum
            return true
        }
        let last = frames.count - 1
        let pending = frames[last].pending.addingReportingOverflow(quantum)
        guard !pending.overflow else {
            exhausted = true
            return false
        }
        frames[last].pending = pending.partialValue
        // Pending long-step work is an interruption bound, not a second charge.
        guard pending.partialValue < remaining else {
            exhausted = true
            return false
        }
        return true
    }
}

func catalogueScanProgress(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
    guard let pointer else { return 1 }
    let budget = Unmanaged<CatalogueScanBudget>.fromOpaque(pointer).takeUnretainedValue()
    do { try budget.progress?() } catch {
        budget.callbackError = error
        return 1
    }
    if Task.isCancelled {
        budget.cancelled = true
        return 1
    }
    return budget.progressWorkFits() ? 0 : 1
}

extension ItemIndex {
    func createRevisionGraphTables() throws {
        for sql in [
            "CREATE TABLE scoped_operation_receipts (origin TEXT NOT NULL,kind TEXT NOT NULL,actor TEXT NOT NULL,operation TEXT NOT NULL,revision TEXT NOT NULL UNIQUE,item TEXT NOT NULL,PRIMARY KEY(origin,kind,actor,operation))",
            "CREATE INDEX scoped_receipt_name ON scoped_operation_receipts(origin,kind,operation,actor,revision)",
            "CREATE INDEX scoped_receipt_item_kind ON scoped_operation_receipts(item,kind,revision)",
            "CREATE TABLE revision_parents (child TEXT NOT NULL,parent TEXT NOT NULL,PRIMARY KEY(child,parent))",
            "CREATE INDEX revision_parent_children ON revision_parents(parent,child)",
            "CREATE TABLE revision_field_values (revision TEXT NOT NULL,field TEXT NOT NULL,digest TEXT NOT NULL,PRIMARY KEY(revision,field))",
            "CREATE TABLE revision_field_writes (revision TEXT NOT NULL,field TEXT NOT NULL,action TEXT NOT NULL,digest TEXT,PRIMARY KEY(revision,field))",
            "CREATE TABLE revision_frontier (revision TEXT NOT NULL,authored TEXT NOT NULL,PRIMARY KEY(revision,authored))",
            "CREATE INDEX revision_history_order ON revision_catalog(item,modified_ticks,revision)",
            "CREATE TABLE recovery_graph_work (revision TEXT PRIMARY KEY,item TEXT NOT NULL,indegree INTEGER NOT NULL,processed INTEGER NOT NULL DEFAULT 0)",
            "CREATE TABLE recovery_ready (revision TEXT PRIMARY KEY,item TEXT NOT NULL)",
            "CREATE INDEX recovery_ready_order ON recovery_ready(item,revision)",
            "CREATE TABLE recovery_roots (item TEXT PRIMARY KEY,revision TEXT NOT NULL,created_at TEXT NOT NULL)",
            "CREATE TABLE recovery_item_progress (item TEXT PRIMARY KEY,ordinal INTEGER NOT NULL)",
            "CREATE TABLE recovery_forks (item TEXT PRIMARY KEY)",
            "CREATE TABLE recovery_reach_seen (revision TEXT PRIMARY KEY)",
            "CREATE TABLE recovery_reach_ready (revision TEXT PRIMARY KEY)",
        ] { try execute(sql) }
        try createCurrentProjectionTables()
    }

    func insertGraphCatalogueRow(_ row: CatalogueRow, graphFields: [String: ItemValue]?) throws {
        invalidateRevisionGraphValidation()
        try Task.checkCancellation()
        guard row.digest.count == 32, !row.revisionID.isEmpty, !row.itemID.isEmpty,
            !row.path.isEmpty, !row.actor.isEmpty, !row.operationID.isEmpty
        else {
            throw TractandaError("recoveryError", "Invalid revision catalogue locator.")
        }
        if let existing = try revision(row.revisionID) {
            guard existing == row else {
                throw TractandaError(
                    "recoveryError", "Duplicate revision identity has different bytes or metadata.")
            }
            return
        }
        let ticks = try row.modifiedAt.isEmpty ? nil : RevisionTimestamp(row.modifiedAt).ticks
        let encodedProvenance: String
        if let provenance = row.provenance {
            guard let graphFields, ticks != nil,
                graphFields["itemID"]?.string == row.itemID,
                graphFields["revisionID"]?.string == row.revisionID,
                graphFields["modifiedAt"]?.dateString == row.modifiedAt,
                graphFields["revisionAncestry"] == provenance.itemValue,
                graphFields["supersedes"]?.string == row.parentID,
                row.parentID == nil || provenance.parents == [row.parentID!]
            else {
                throw TractandaError(
                    "recoveryError", "Modern catalogue rows require matching canonical fields.")
            }
            try provenance.validate(in: graphFields)
            encodedProvenance = String(decoding: try JSON.encode(provenance.itemValue), as: UTF8.self)
        } else {
            guard graphFields?["revisionAncestry"] == nil else {
                throw TractandaError(
                    "recoveryError", "Canonical ancestry was omitted from its catalogue row.")
            }
            encodedProvenance = ""
        }
        var additionalBytes: UInt64 = 1024 * 1024
        func addEstimate(_ bytes: UInt64, copies: UInt64 = 1) throws {
            let multiplied = bytes.multipliedReportingOverflow(by: copies)
            let total = additionalBytes.addingReportingOverflow(multiplied.partialValue)
            guard !multiplied.overflow, !total.overflow else {
                throw TractandaError("resourceLimit", "Catalogue storage estimate overflowed.")
            }
            additionalBytes = total.partialValue
        }
        // Include locator, receipt and B-tree duplicates, not just normalized field keys.
        for text in [
            row.revisionID, row.itemID, row.path, row.parentID ?? "", row.actor, row.operationID,
            row.createdAt, row.modifiedAt, encodedProvenance,
        ] {
            try addEstimate(UInt64(text.utf8.count), copies: 6)
        }
        for field in graphFields?.keys ?? [String: ItemValue]().keys {
            try addEstimate(UInt64(field.utf8.count), copies: 6)
            try addEstimate(512, copies: 6)
        }
        for identifier in (row.provenance?.parents ?? []) + (row.provenance?.frontier ?? [])
            + row.feedbackRevisionIDs
        {
            try addEstimate(UInt64(identifier.utf8.count), copies: 6)
            try addEstimate(512, copies: 6)
        }
        guard additionalBytes <= graphMaximumTemporaryBytes else {
            throw TractandaError("resourceLimit", "Catalogue row metadata exceeds its byte budget.")
        }
        try requireGraphCapacity(additionalBytes: additionalBytes)
        try execute("SAVEPOINT catalogue_row")
        do {
            try execute(
                "INSERT INTO revision_catalog VALUES (?,?,?,NULLIF(?,''),?,?,?,?,?,?,?,?,?,?,?,NULLIF(?,''),CAST(NULLIF(?,'') AS INTEGER))",
                [
                    row.revisionID, row.itemID, row.path, row.parentID ?? "", row.actor, row.operationID,
                    String(row.size), String(row.inode), String(row.uid), String(row.mode),
                    String(row.modificationSeconds), String(row.modificationNanoseconds),
                    row.digest.map { String(format: "%02x", $0) }.joined(), row.createdAt, row.modifiedAt,
                    encodedProvenance, ticks.map(String.init) ?? "",
                ])
            if let provenance = row.provenance {
                try execute(
                    "INSERT INTO scoped_operation_receipts VALUES (?,?,?,?,?,?)",
                    [
                        provenance.originReplicaID, provenance.kind.rawValue, row.actor, row.operationID,
                        row.revisionID, row.itemID,
                    ])
            } else {
                try execute(
                    "INSERT INTO operation_receipts VALUES (?,?,?,?)",
                    [row.actor, row.operationID, row.revisionID, row.itemID])
            }
            for parent in row.provenance?.parents ?? row.parentID.map({ [$0] }) ?? [] {
                try execute("INSERT INTO revision_parents VALUES (?,?)", [row.revisionID, parent])
            }
            for target in row.feedbackRevisionIDs {
                try execute("INSERT INTO feedback_refs VALUES (?,?,?)", [row.itemID, row.revisionID, target])
            }
            if let graphFields {
                var processed = 0
                for (field, value) in graphFields where !RevisionMerge.managedFields.contains(field) {
                    try value.validate()
                    let digest = try Self.graphValueDigest(value)
                    try execute(
                        "INSERT INTO revision_field_values VALUES (?,?,?)",
                        [row.revisionID, field.precomposedStringWithCanonicalMapping, digest])
                    processed += 1
                    if processed % 128 == 0 {
                        try Task.checkCancellation()
                        try requireGraphCapacity(additionalBytes: 64 * 1024)
                    }
                }
            }
            if let provenance = row.provenance {
                for field in provenance.writtenFields {
                    let digest = try Self.graphValueDigest(graphFields![field]!)
                    try execute(
                        "INSERT INTO revision_field_writes VALUES (?,?,'set',?)",
                        [row.revisionID, field.precomposedStringWithCanonicalMapping, digest])
                }
                for field in provenance.unsetFields {
                    try execute(
                        "INSERT INTO revision_field_writes VALUES (?,?,'unset',NULL)",
                        [row.revisionID, field.precomposedStringWithCanonicalMapping])
                }
                for authored in provenance.frontier {
                    try execute("INSERT INTO revision_frontier VALUES (?,?)", [row.revisionID, authored])
                }
            }
            try execute("RELEASE catalogue_row")
        } catch {
            try? execute("ROLLBACK TO catalogue_row")
            try? execute("RELEASE catalogue_row")
            throw error
        }
    }

    /// ItemValue equality treats -0.0 and +0.0 equally, recursively; tags remain distinct.
    static func graphValueDigest(_ value: ItemValue) throws -> String {
        func normalize(_ value: ItemValue) -> ItemValue {
            switch value {
            case .text(let text): return .text(text.precomposedStringWithCanonicalMapping)
            case .real(let number): return .real(number == 0 ? 0 : number)
            case .list(let list): return .list(list.map(normalize))
            case .object(let object):
                return .object(
                    object.reduce(into: [:]) { result, pair in
                        result[pair.key.precomposedStringWithCanonicalMapping] = normalize(pair.value)
                    })
            default: return value
            }
        }
        return SHA256.hash(data: try JSON.encode(normalize(value))).map { String(format: "%02x", $0) }
            .joined()
    }

    func hasModernRevisionOrigins() throws -> Bool {
        let statement = try corpusPrepare(
            "SELECT 1 FROM revision_catalog WHERE provenance IS NOT NULL LIMIT 1")
        defer { sqlite3_finalize(statement) }
        switch catalogueStep(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw graphSQLiteError()
        }
    }

    func validateGraphReceipt(_ row: CatalogueRow) throws {
        let statement: OpaquePointer
        if let provenance = row.provenance {
            statement = try corpusPrepare(
                "SELECT 1 FROM scoped_operation_receipts WHERE revision=? AND origin=? AND kind=? AND actor=? AND operation=? AND item=?",
                [
                    row.revisionID, provenance.originReplicaID, provenance.kind.rawValue, row.actor,
                    row.operationID, row.itemID,
                ])
        } else {
            statement = try corpusPrepare(
                "SELECT 1 FROM operation_receipts WHERE revision=? AND actor=? AND operation=? AND item=?",
                [row.revisionID, row.actor, row.operationID, row.itemID])
        }
        defer { sqlite3_finalize(statement) }
        let forbidden = row.provenance == nil ? "scoped_operation_receipts" : "operation_receipts"
        try graphReject(
            "SELECT 1 FROM \(forbidden) WHERE revision=? LIMIT 1", [row.revisionID],
            "Receipt namespace disagrees with canonical ancestry.")
        guard catalogueStep(statement) == SQLITE_ROW, catalogueStep(statement) == SQLITE_DONE else {
            throw TractandaError("recoveryError", "Receipt scope disagrees with immutable revision metadata.")
        }
    }

    func graphHeadPage(itemID: String, afterRevisionID: String? = nil, limit: Int = 128) throws
        -> [CatalogueRow]
    {
        let suffix = afterRevisionID == nil ? "" : " AND revision>?"
        return try graphCatalogueRows(
            where:
                "WHERE item=? AND NOT EXISTS(SELECT 1 FROM revision_parents p WHERE p.parent=revision_catalog.revision)\(suffix) ORDER BY revision",
            bindings: [itemID] + (afterRevisionID.map { [$0] } ?? []), limit: limit)
    }

    func historyRowPage(
        itemID: String, afterModifiedTicks: Int64? = nil, afterRevisionID: String? = nil, limit: Int = 128
    ) throws -> [CatalogueRow] {
        guard (afterModifiedTicks == nil) == (afterRevisionID == nil) else {
            throw TractandaError(
                "invalidArguments", "History cursor requires both time and revision identity.")
        }
        try graphReject(
            "SELECT 1 FROM revision_catalog WHERE item=? AND modified_ticks IS NULL LIMIT 1", [itemID],
            "History lacks exact timestamp metadata.")
        var bindings = [itemID]
        let cursor: String
        if let afterModifiedTicks, let afterRevisionID {
            cursor = " AND (modified_ticks,revision)>(CAST(? AS INTEGER),?)"
            bindings += [String(afterModifiedTicks), afterRevisionID]
        } else {
            cursor = ""
        }
        return try graphCatalogueRows(
            where: "WHERE item=?\(cursor) ORDER BY modified_ticks,revision", bindings: bindings, limit: limit)
    }

    func validateCatalogueGraph(requireLinearProjection: Bool, progress: (() throws -> Void)?) throws {
        try withCatalogueScanBudget(progress: progress, reusingActiveBudget: true) {
            try Task.checkCancellation()
            let count = try graphCount("SELECT COUNT(*) FROM revision_catalog")
            let edges = try graphCount("SELECT COUNT(*) FROM revision_parents")
            let estimate = count.multipliedReportingOverflow(by: 512)
            let edgeEstimate = edges.multipliedReportingOverflow(by: 128)
            let total = estimate.partialValue.addingReportingOverflow(edgeEstimate.partialValue)
            guard !estimate.overflow, !edgeEstimate.overflow, !total.overflow,
                total.partialValue >= 0, UInt64(total.partialValue) <= graphMaximumTemporaryBytes
            else {
                throw TractandaError("resourceLimit", "Revision graph staging budget exceeded.")
            }
            let fingerprintBytes = try graphCount(
                "SELECT COALESCE(SUM(length(CAST(v.field AS BLOB))+length(CAST(v.digest AS BLOB))+512),0) FROM revision_field_values v JOIN revision_catalog r ON r.revision=v.revision WHERE r.provenance IS NULL"
            )
            let fingerprintEstimate = UInt64(fingerprintBytes).multipliedReportingOverflow(by: 4)
            let stagingEstimate = UInt64(total.partialValue).addingReportingOverflow(
                fingerprintEstimate.partialValue)
            guard !fingerprintEstimate.overflow, !stagingEstimate.overflow,
                stagingEstimate.partialValue <= graphMaximumTemporaryBytes
            else {
                throw TractandaError("resourceLimit", "Legacy field staging exceeds its byte budget.")
            }
            try requireGraphCapacity(additionalBytes: stagingEstimate.partialValue)
            try validateNormalizedGraphMetadata(progress: progress)
            // Declared writes cover every actual authored snapshot delta; extra same-value
            // sets and absent-key unsets are valid explicit intent.
            try graphReject(
                "SELECT 1 FROM revision_field_values child JOIN scoped_operation_receipts o ON o.revision=child.revision AND o.kind='authored' JOIN revision_parents e ON e.child=child.revision LEFT JOIN revision_field_values parent ON parent.revision=e.parent AND parent.field=child.field WHERE (parent.field IS NULL OR parent.digest!=child.digest) AND NOT EXISTS(SELECT 1 FROM revision_field_writes w WHERE w.revision=child.revision AND w.field=child.field AND w.action='set' AND w.digest=child.digest) LIMIT 1",
                [], "Modern authored snapshot changed a field without declaring its write.")
            try graphReject(
                "SELECT 1 FROM revision_field_values parent JOIN revision_parents e ON e.parent=parent.revision JOIN scoped_operation_receipts o ON o.revision=e.child AND o.kind='authored' LEFT JOIN revision_field_values child ON child.revision=e.child AND child.field=parent.field WHERE child.field IS NULL AND NOT EXISTS(SELECT 1 FROM revision_field_writes w WHERE w.revision=e.child AND w.field=parent.field AND w.action='unset') LIMIT 1",
                [], "Modern authored snapshot removed a field without declaring its unset.")
            for table in [
                "recovery_ordinals", "recovery_heads", "recovery_graph_work", "recovery_ready",
                "recovery_roots", "recovery_item_progress", "recovery_forks", "recovery_reach_seen",
                "recovery_reach_ready",
            ] {
                try execute("DELETE FROM \(table)")
            }
            try graphReject(
                "SELECT 1 FROM revision_parents e LEFT JOIN revision_catalog c ON c.revision=e.child LEFT JOIN revision_catalog p ON p.revision=e.parent WHERE c.revision IS NULL OR p.revision IS NULL OR c.item!=p.item LIMIT 1",
                [], "Missing or cross-item revision parent.")
            try graphReject(
                "SELECT 1 FROM revision_catalog r WHERE (r.parent IS NOT NULL AND NOT EXISTS(SELECT 1 FROM revision_parents e WHERE e.child=r.revision AND e.parent=r.parent)) OR (r.provenance IS NULL AND (SELECT COUNT(*) FROM revision_parents e WHERE e.child=r.revision)!=(r.parent IS NOT NULL)) LIMIT 1",
                [], "Legacy predecessor differs from normalized ancestry.")
            try graphReject(
                "SELECT item FROM revision_catalog r GROUP BY item HAVING SUM(NOT EXISTS(SELECT 1 FROM revision_parents e WHERE e.child=r.revision))!=1 LIMIT 1",
                [], "An item needs exactly one initial revision.")
            try execute(
                "INSERT INTO recovery_roots SELECT item,revision,created_at FROM revision_catalog r WHERE NOT EXISTS(SELECT 1 FROM revision_parents e WHERE e.child=r.revision)"
            )
            try graphReject(
                "SELECT 1 FROM revision_catalog r JOIN recovery_roots root ON root.item=r.item WHERE r.created_at!=root.created_at LIMIT 1",
                [], "Item creation time changed.")
            try graphReject(
                "SELECT 1 FROM revision_frontier f JOIN revision_catalog source ON source.revision=f.revision LEFT JOIN revision_catalog target ON target.revision=f.authored WHERE target.revision IS NULL OR target.item!=source.item LIMIT 1",
                [], "Missing or cross-item declared frontier.")
            try graphReject(
                "SELECT 1 FROM scoped_operation_receipts o JOIN revision_parents e ON e.child=o.revision JOIN revision_catalog c ON c.revision=e.child JOIN revision_catalog p ON p.revision=e.parent WHERE o.kind!='authored' AND (c.modified_ticks IS NULL OR p.modified_ticks IS NULL OR c.modified_ticks<=p.modified_ticks) LIMIT 1",
                [], "Merge timestamp must exceed every input.")
            // Fingerprints carry values without a second body; legacy applied deltas derive after all parents arrive.
            try execute(
                "DELETE FROM revision_field_writes WHERE revision IN(SELECT revision FROM revision_catalog WHERE provenance IS NULL)"
            )
            try execute(
                "INSERT INTO revision_field_writes SELECT v.revision,v.field,'set',v.digest FROM revision_field_values v JOIN revision_catalog r ON r.revision=v.revision LEFT JOIN revision_field_values p ON p.revision=r.parent AND p.field=v.field WHERE r.provenance IS NULL AND (p.field IS NULL OR p.digest!=v.digest)"
            )
            try execute(
                "INSERT INTO revision_field_writes SELECT r.revision,p.field,'unset',NULL FROM revision_catalog r JOIN revision_field_values p ON p.revision=r.parent LEFT JOIN revision_field_values v ON v.revision=r.revision AND v.field=p.field WHERE r.provenance IS NULL AND v.field IS NULL"
            )
            try execute(
                "INSERT INTO recovery_graph_work SELECT r.revision,r.item,COUNT(e.parent),0 FROM revision_catalog r LEFT JOIN revision_parents e ON e.child=r.revision GROUP BY r.revision"
            )
            try execute("INSERT INTO recovery_item_progress SELECT item,0 FROM recovery_roots")
            try execute(
                "INSERT INTO recovery_ready SELECT revision,item FROM recovery_graph_work WHERE indegree=0")
            try execute(
                "INSERT OR IGNORE INTO recovery_forks SELECT item FROM recovery_graph_work WHERE indegree>1")
            try execute(
                "INSERT OR IGNORE INTO recovery_forks SELECT p.item FROM revision_parents e JOIN revision_catalog p ON p.revision=e.parent GROUP BY e.parent HAVING COUNT(*)>1"
            )
            var processed: Int64 = 0
            while let next = try graphPair(
                "SELECT item,revision FROM recovery_ready ORDER BY item,revision LIMIT 1")
            {
                try execute("DELETE FROM recovery_ready WHERE revision=?", [next.1])
                try execute("UPDATE recovery_graph_work SET processed=1 WHERE revision=?", [next.1])
                try execute("UPDATE recovery_item_progress SET ordinal=ordinal+1 WHERE item=?", [next.0])
                try execute(
                    "INSERT INTO recovery_ordinals SELECT item,?,ordinal FROM recovery_item_progress WHERE item=?",
                    [next.1, next.0])
                try execute(
                    "UPDATE recovery_graph_work SET indegree=indegree-1 WHERE revision IN(SELECT child FROM revision_parents WHERE parent=?)",
                    [next.1])
                try execute(
                    "INSERT OR IGNORE INTO recovery_ready SELECT w.revision,w.item FROM recovery_graph_work w JOIN revision_parents e ON e.child=w.revision WHERE e.parent=? AND w.indegree=0 AND w.processed=0",
                    [next.1])
                processed += 1
                if processed % 128 == 0 {
                    try progress?()
                    try Task.checkCancellation()
                    try requireGraphCapacity(additionalBytes: 64 * 1024)
                }
            }
            guard processed == count else {
                throw TractandaError(
                    "recoveryError", "Revision graph contains a cycle or disconnected ancestry.")
            }
            try validateGraphFeedback(progress: progress)
            if requireLinearProjection {
                try graphReject(
                    "SELECT 1 FROM recovery_forks LIMIT 1", [],
                    "Revision DAG requires coordinated current projection.",
                    code: "revisionProjectionRequired")
                try graphReject(
                    "SELECT 1 FROM scoped_operation_receipts o JOIN revision_catalog r ON r.revision=o.revision WHERE o.kind!='authored' OR (EXISTS(SELECT 1 FROM revision_parents e WHERE e.child=r.revision) AND (r.parent IS NULL OR NOT EXISTS(SELECT 1 FROM revision_parents e WHERE e.child=r.revision AND e.parent=r.parent))) LIMIT 1",
                    [], "Modern ancestry needs coordinated history/projection support.",
                    code: "revisionProjectionRequired")
            }
            // A physical single head is not a semantic DAG projection; only proved chains populate runtime heads.
            try execute(
                "INSERT INTO recovery_heads SELECT r.item,r.revision FROM revision_catalog r WHERE NOT EXISTS(SELECT 1 FROM recovery_forks f WHERE f.item=r.item) AND NOT EXISTS(SELECT 1 FROM revision_parents e WHERE e.parent=r.revision)"
            )
        }
    }

    private func validateNormalizedGraphMetadata(progress: (() throws -> Void)?) throws {
        var cursor: String?
        while true {
            let page = try recoveryRowPage(after: cursor, limit: 128)
            if page.isEmpty { break }
            for row in page {
                let parents = row.provenance?.parents ?? row.parentID.map({ [$0] }) ?? []
                try graphRequireMembers(
                    table: "revision_parents", key: "child", column: "parent", revision: row.revisionID,
                    members: parents)
                if let provenance = row.provenance {
                    try graphRequireMembers(
                        table: "revision_frontier", key: "revision", column: "authored",
                        revision: row.revisionID, members: provenance.frontier)
                    let count = try graphCount(
                        "SELECT COUNT(*) FROM revision_field_writes WHERE revision=?", [row.revisionID])
                    guard count == Int64(provenance.writtenFields.count + provenance.unsetFields.count) else {
                        throw TractandaError("recoveryError", "Normalized field-write count disagrees.")
                    }
                    for field in provenance.writtenFields {
                        let statement = try corpusPrepare(
                            "SELECT 1 FROM revision_field_writes w JOIN revision_field_values v ON v.revision=w.revision AND v.field=w.field WHERE w.revision=? AND w.field=? AND w.action='set' AND w.digest=v.digest",
                            [row.revisionID, field.precomposedStringWithCanonicalMapping])
                        defer { sqlite3_finalize(statement) }
                        guard catalogueStep(statement) == SQLITE_ROW else {
                            throw TractandaError(
                                "recoveryError", "Normalized applied write differs from snapshot fingerprint."
                            )
                        }
                    }
                    for field in provenance.unsetFields {
                        let statement = try corpusPrepare(
                            "SELECT 1 FROM revision_field_writes w WHERE w.revision=? AND w.field=? AND w.action='unset' AND w.digest IS NULL AND NOT EXISTS(SELECT 1 FROM revision_field_values v WHERE v.revision=w.revision AND v.field=w.field)",
                            [row.revisionID, field.precomposedStringWithCanonicalMapping])
                        defer { sqlite3_finalize(statement) }
                        guard catalogueStep(statement) == SQLITE_ROW else {
                            throw TractandaError(
                                "recoveryError", "Normalized unset differs from snapshot fingerprint.")
                        }
                    }
                }
            }
            cursor = page.last!.revisionID
            try progress?()
            try Task.checkCancellation()
        }
    }

    private func graphRequireMembers(
        table: String, key: String, column: String, revision: String, members: [String]
    ) throws {
        let statement = try corpusPrepare(
            "SELECT \(column) FROM \(table) WHERE \(key)=? ORDER BY \(column)", [revision])
        defer { sqlite3_finalize(statement) }
        var ordinal = 0
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE {
                guard ordinal == members.count else {
                    throw TractandaError("recoveryError", "Normalized ancestry count differs.")
                }
                return
            }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                throw graphSQLiteError()
            }
            guard ordinal < members.count, String(cString: text) == members[ordinal] else {
                throw TractandaError("recoveryError", "Normalized ancestry differs from canonical metadata.")
            }
            ordinal += 1
        }
    }

    private func validateGraphFeedback(progress: (() throws -> Void)?) throws {
        try graphReject(
            "SELECT 1 FROM feedback_refs f LEFT JOIN revision_catalog source ON source.revision=f.revision LEFT JOIN revision_catalog target ON target.revision=f.target WHERE source.revision IS NULL OR target.revision IS NULL OR source.item!=f.item OR target.item!=f.item OR f.target=f.revision LIMIT 1",
            [], "Feedback must reference a proper ancestor of the same item.")
        let statement = try corpusPrepare(
            "SELECT f.revision,f.target,CASE WHEN forks.item IS NULL THEN target.ordinal<source.ordinal ELSE NULL END FROM feedback_refs f JOIN recovery_ordinals source ON source.revision=f.revision JOIN recovery_ordinals target ON target.revision=f.target LEFT JOIN recovery_forks forks ON forks.item=f.item"
        )
        defer { sqlite3_finalize(statement) }
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW, let sourceBytes = sqlite3_column_text(statement, 0),
                let targetBytes = sqlite3_column_text(statement, 1)
            else { throw graphSQLiteError() }
            let valid: Bool
            if sqlite3_column_type(statement, 2) != SQLITE_NULL {
                valid = sqlite3_column_int(statement, 2) == 1
            } else {
                valid = try graphHasProperAncestor(
                    source: String(cString: sourceBytes), target: String(cString: targetBytes),
                    progress: progress)
            }
            guard valid else {
                throw TractandaError("recoveryError", "Feedback target is not a proper causal ancestor.")
            }
        }
    }

    func graphHasProperAncestor(source: String, target: String, progress: (() throws -> Void)?) throws
        -> Bool
    {
        try execute("DELETE FROM recovery_reach_seen")
        try execute("DELETE FROM recovery_reach_ready")
        try execute(
            "INSERT INTO recovery_reach_ready SELECT parent FROM revision_parents WHERE child=?", [source])
        var visited = 0
        while let next = try graphPair(
            "SELECT revision,revision FROM recovery_reach_ready ORDER BY revision LIMIT 1")
        {
            if next.0 == target { return true }
            try execute("DELETE FROM recovery_reach_ready WHERE revision=?", [next.0])
            try execute("INSERT OR IGNORE INTO recovery_reach_seen VALUES (?)", [next.0])
            try execute(
                "INSERT OR IGNORE INTO recovery_reach_ready SELECT parent FROM revision_parents e WHERE child=? AND NOT EXISTS(SELECT 1 FROM recovery_reach_seen v WHERE v.revision=e.parent)",
                [next.0])
            visited += 1
            if visited % 128 == 0 {
                try progress?()
                try Task.checkCancellation()
                try requireGraphCapacity(additionalBytes: 64 * 1024)
            }
        }
        return false
    }

    private func graphReject(
        _ sql: String, _ bindings: [String], _ message: String, code: String = "recoveryError"
    ) throws {
        let statement = try corpusPrepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        guard status != SQLITE_ROW else { throw TractandaError(code, message) }
        guard status == SQLITE_DONE else { throw graphSQLiteError() }
    }

    private func graphCount(_ sql: String, _ bindings: [String] = []) throws -> Int64 {
        let statement = try corpusPrepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW else { throw graphSQLiteError() }
        let count = sqlite3_column_int64(statement, 0)
        guard count >= 0, catalogueStep(statement) == SQLITE_DONE else { throw graphSQLiteError() }
        return count
    }

    private func graphPair(_ sql: String) throws -> (String, String)? {
        let statement = try corpusPrepare(sql)
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let first = sqlite3_column_text(statement, 0),
            let second = sqlite3_column_text(statement, 1)
        else { throw graphSQLiteError() }
        return (String(cString: first), String(cString: second))
    }

    func requireGraphCapacity(additionalBytes: UInt64) throws {
        let directory =
            corpusIndexPath == ":memory:"
            ? FileManager.default.temporaryDirectory.path
            : URL(fileURLWithPath: corpusIndexPath).deletingLastPathComponent().path
        var filesystem = statvfs()
        guard statvfs(directory, &filesystem) == 0, filesystem.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot determine genuine catalogue filesystem capacity.")
        }
        let available = UInt64(filesystem.f_bavail).multipliedReportingOverflow(
            by: UInt64(filesystem.f_frsize))
        let required = graphReserveBytes.addingReportingOverflow(additionalBytes)
        guard !available.overflow, !required.overflow, available.partialValue >= required.partialValue else {
            throw TractandaError(
                "resourceLimit", "Revision catalogue cannot preserve its free-space reserve.")
        }
    }
}
