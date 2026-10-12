import CSQLite
import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Ephemeral fence for this open session, never persisted as a store/device identity.
struct IndexCorpusFileFence: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    static func capture(_ path: String) throws -> Self {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw TractandaError("indexUnavailable", "The current corpus index file is unavailable.")
        }
        return Self(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

struct IndexCorpusWriteBatch: Sendable {
    enum Phase: Sendable { case before, after, afterCommit }
    let phase: Phase
    let workID: String
    let estimatedAdditionalBytes: Int64
    let units: Int
    let pendingEncodedBytes: Int64
    let retainedEncodedBytes: Int64
    init(
        phase: Phase, workID: String, estimatedAdditionalBytes: Int64, units: Int,
        pendingEncodedBytes: Int64 = 0, retainedEncodedBytes: Int64 = 0
    ) {
        self.phase = phase
        self.workID = workID
        self.estimatedAdditionalBytes = estimatedAdditionalBytes
        self.units = units
        self.pendingEncodedBytes = pendingEncodedBytes
        self.retainedEncodedBytes = retainedEncodedBytes
    }
}

struct IndexedCorpusComponent: Codable, Sendable, Equatable {
    let generationID: String
    let sourceKey: String
    let kind: String
    let unitCount: Int64
    let byteCount: Int64
}

/// Publication-local identities are deliberately separate from immutable reusable page bytes.
struct IndexedCorpusOverlay: Codable, Sendable, Equatable {
    let attachmentID: String?
    let representationID: String?
    let contentID: String?
}

struct IndexedCorpusLink: Codable, Sendable, Equatable {
    let component: IndexedCorpusComponent
    let unitStart: Int64
    let byteStart: Int64
    let overlay: IndexedCorpusOverlay
}

struct IndexedCorpusIdentity: Codable, Sendable, Equatable {
    let itemID: String
    let revisionID: String
    let layout: String
    let contentHash: String
    let unitCount: Int64
    let utf8Bytes: Int64
}

struct IndexedCorpusSnapshot: Sendable, Equatable {
    let identity: IndexedCorpusIdentity
    let indexPath: String
    let indexIdentity: String
    let fence: IndexCorpusFileFence
    let links: [IndexedCorpusLink]  // <=257 canonical field/text/document components.
    let retentionID: String?
}

struct IndexedCorpusStage: Sendable, Equatable {
    let workID: String
    let indexIdentity: String
    let fence: IndexCorpusFileFence
    let source: PageCorpusBinding
    let ordinaryFingerprint: String
    let components: [IndexedCorpusComponent]
}

struct IndexedCorpusUnitWindow: Sendable {
    let identity: IndexedCorpusIdentity
    let ordinal: Int64
    let byteStart: Int64
    let byteCount: Int64
    let offset: Int64
    let nextOffset: Int64
    let data: Data
    let origin: PageCorpusOrigin
    let spans: [PageCorpusSpan]  // All spans in one existing at-most512-block page.
}

struct IndexCorpusComponentPlan: Sendable {
    let sourceKey: String
    let kind: String
    let attachmentID: String?
    let overlay: IndexedCorpusOverlay
}

private struct IndexDocumentSourceIdentity: Encodable {
    let layout: String
    let source: AttachmentDocumentSource
    let identity: DocumentConverterIdentity
    let extractedAt: String
    let rootSHA256: String?
    let pageCount: Int64
    let encodedBytes: Int64
    let coverage: DocumentCoverage
    let inlinePages: [AttachmentDocumentPage]
}

private struct IndexTextSourceIdentity: Encodable {
    let layout: String
    let schema: String
    let converter: String
    let extractedAt: String
    let source: AttachmentTextSource
    let sourceByteStart: Int
    let text: String
}

/// Only bounded canonical ordinary values are hashed. No document source string is assembled.
enum IndexCorpusPlan {
    static func ordinaryFingerprint(_ revision: Revision) throws -> String {
        var digest = SHA256()
        func part(_ data: Data) {
            digest.update(data: Data((String(data.count) + ":").utf8))
            digest.update(data: data)
        }
        part(Data(PageCorpusBinding.layoutName.utf8))
        try forEachField(revision) { path, text in
            part(Data(path.utf8))
            part(Data(text.utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func forEachField(_ revision: Revision, visit: (String, String) throws -> Void) throws {
        guard !revision.isDeleted else { return }
        func quoted(_ value: String) throws -> String {
            String(decoding: try JSON.encode(value), as: UTF8.self)
        }
        func visitValue(_ node: ItemValue, path: String, depth: Int) throws {
            guard depth <= 64 else {
                throw TractandaError("resourceLimit", "Owned field nesting exceeds the corpus window.")
            }
            switch node {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try visit(path, text) }
            case .object(let values):
                for key in values.keys.sorted() {
                    try visitValue(values[key]!, path: path + "[" + quoted(key) + "]", depth: depth + 1)
                }
            case .list(let values):
                for (index, child) in values.enumerated() {
                    try visitValue(child, path: path + "[\(index)]", depth: depth + 1)
                }
            case .integer, .real, .boolean, .date, .reference, .bytes: break
            }
        }
        for key in revision.fields.keys.sorted() where !ItemTextContent.excludedRootFields.contains(key) {
            try visitValue(revision.fields[key]!, path: "field[" + quoted(key) + "]", depth: 0)
        }
    }

    static func components(_ input: PageCorpusInput) throws -> [IndexCorpusComponentPlan] {
        guard !input.revision.isDeleted else { return [] }
        var result = [
            IndexCorpusComponentPlan(
                sourceKey: "fields:" + (try ordinaryFingerprint(input.revision)), kind: "field",
                attachmentID: nil, overlay: .init(attachmentID: nil, representationID: nil, contentID: nil))
        ]
        for text in input.texts {
            let key = PageCorpusInput.digest(
                try JSON.encode(
                    IndexTextSourceIdentity(
                        layout: PageCorpusBinding.layoutName, schema: AttachmentTextRepresentation.schema,
                        converter: AttachmentTextRepresentation.converter, extractedAt: text.extractedAt,
                        source: text.source,
                        sourceByteStart: text.sourceByteStart, text: text.text)))
            result.append(
                .init(
                    sourceKey: "text:" + key, kind: "originalBytes", attachmentID: text.attachmentID,
                    overlay: .init(
                        attachmentID: text.attachmentID, representationID: text.representationID,
                        contentID: nil)))
        }
        for document in input.documents {
            let key = PageCorpusInput.digest(
                try JSON.encode(
                    IndexDocumentSourceIdentity(
                        layout: PageCorpusBinding.layoutName, source: document.source,
                        identity: document.identity, extractedAt: document.extractedAt,
                        rootSHA256: document.rootSHA256, pageCount: document.pageCount,
                        encodedBytes: document.totalEncodedBytes, coverage: document.coverage,
                        inlinePages: document.inlinePages)))
            result.append(
                .init(
                    sourceKey: "document:" + key, kind: "document", attachmentID: document.attachmentID,
                    overlay: .init(
                        attachmentID: document.attachmentID, representationID: document.representationID,
                        contentID: document.savedContent?.contentID)))
        }
        guard result.count <= 1 + 2 * AttachmentDescriptor.maximumAttachments else {
            throw TractandaError(
                "resourceLimit", "Corpus component descriptors exceed their canonical window.")
        }
        return result
    }

    static func origin(_ origin: PageCorpusOrigin, overlay: IndexedCorpusOverlay) -> PageCorpusOrigin {
        PageCorpusOrigin(
            kind: origin.kind, fieldPath: origin.fieldPath, attachmentID: overlay.attachmentID,
            representationID: overlay.representationID, contentID: overlay.contentID,
            documentSource: origin.documentSource, textSource: origin.textSource,
            pageNumber: origin.pageNumber, sourceByteStart: origin.sourceByteStart,
            sourceByteEnd: origin.sourceByteEnd, rasterSHA256: origin.rasterSHA256, geometry: origin.geometry)
    }
}

/// A connection owns its executor. This type is never part of a Sendable capability.
final class IndexCorpusSQL {
    enum Value {
        case text(String)
        case integer(Int64)
        case null
    }
    private var database: OpaquePointer?
    init(path: String, readOnly: Bool) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            throw TractandaError("indexUnavailable", "Cannot open the corpus index connection.")
        }
        sqlite3_busy_timeout(database, 50)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 16 * 1024 * 1024)
        do {
            if !readOnly {
                try execute("PRAGMA synchronous=FULL")
                try execute("PRAGMA temp_store=MEMORY")
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }
    deinit { if let database { sqlite3_close(database) } }
    func execute(_ sql: String, _ values: [Value] = []) throws { try rows(sql, values) { _ in } }
    func rows(_ sql: String, _ values: [Value] = [], visit: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let status: Int32
            switch value {
            case .text(let text):
                guard let count = Int32(exactly: text.utf8.count) else { throw failure() }
                status = text.withCString {
                    sqlite3_bind_text(statement, Int32(offset + 1), $0, count, transient)
                }
            case .integer(let number): status = sqlite3_bind_int64(statement, Int32(offset + 1), number)
            case .null: status = sqlite3_bind_null(statement, Int32(offset + 1))
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw failure() }
            try visit(statement)
        }
    }
    func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        let data = data(statement, column)
        guard let string = String(data: data, encoding: .utf8) else {
            throw TractandaError("indexError", "Corpus metadata is not UTF8.")
        }
        return string
    }
    func data(_ statement: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
    func scalar(_ sql: String, _ values: [Value] = []) throws -> String? {
        var value: String?
        try rows(sql, values) { statement in
            guard value == nil else { throw TractandaError("indexError", "Corpus scalar is ambiguous.") }
            value = try text(statement, 0)
        }
        return value
    }
    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    var lastRowID: Int64 { sqlite3_last_insert_rowid(database) }
    private func failure() -> TractandaError {
        let code = sqlite3_errcode(database)
        return TractandaError(
            [SQLITE_BUSY, SQLITE_LOCKED].contains(code)
                ? "indexBusy" : [SQLITE_FULL, SQLITE_TOOBIG].contains(code) ? "resourceLimit" : "indexError",
            "Corpus SQLite operation failed.")
    }
}

extension ItemIndex {
    func createCorpusTables() throws {
        try execute("CREATE TABLE corpus_index_identity (id TEXT NOT NULL UNIQUE)")
        try execute(
            "INSERT INTO corpus_index_identity VALUES (?)", [try UUID.makeVersion1().uuidString.lowercased()])
        try execute(
            "CREATE TABLE corpus_generation (id TEXT PRIMARY KEY,source_key TEXT NOT NULL,kind TEXT NOT NULL,state TEXT NOT NULL,unit_count INTEGER NOT NULL,byte_count INTEGER NOT NULL,owner_work_id TEXT,header_bytes INTEGER NOT NULL,encoded_bytes INTEGER NOT NULL)"
        )
        try execute("CREATE INDEX corpus_generation_owner ON corpus_generation(owner_work_id,id)")
        try execute("CREATE TABLE corpus_gc_candidate (generation_id TEXT PRIMARY KEY)")
        try execute(
            "CREATE TABLE corpus_gc_cursor (singleton INTEGER PRIMARY KEY CHECK(singleton=1),generation_id TEXT NOT NULL)"
        )
        try execute("INSERT INTO corpus_gc_cursor VALUES (1,'')")
        try execute(
            "CREATE UNIQUE INDEX corpus_ready_key ON corpus_generation(source_key) WHERE state='ready'")
        try execute(
            "CREATE TABLE corpus_work (id TEXT PRIMARY KEY,kind TEXT NOT NULL,source TEXT NOT NULL,encoded_bytes INTEGER NOT NULL)"
        )
        try execute(
            "CREATE TABLE corpus_work_generation (work_id TEXT NOT NULL,generation_id TEXT NOT NULL,PRIMARY KEY(work_id,generation_id))"
        )
        try execute(
            "CREATE INDEX corpus_work_generation_source ON corpus_work_generation(generation_id,work_id)")
        try execute(
            "CREATE TABLE corpus_unit (id INTEGER PRIMARY KEY,generation_id TEXT NOT NULL,ordinal INTEGER NOT NULL,byte_start INTEGER NOT NULL,byte_count INTEGER NOT NULL,origin TEXT NOT NULL,encoded_bytes INTEGER NOT NULL,UNIQUE(generation_id,ordinal))"
        )
        try execute(
            "CREATE TABLE corpus_span (unit_id INTEGER NOT NULL,block_index INTEGER NOT NULL,start INTEGER NOT NULL,end INTEGER NOT NULL,box TEXT,PRIMARY KEY(unit_id,block_index))"
        )
        try execute("CREATE VIRTUAL TABLE page_text_index USING fts5(text,tokenize='unicode61')")
        try execute(
            "CREATE TABLE corpus_head (item_id TEXT PRIMARY KEY,revision_id TEXT NOT NULL,layout TEXT NOT NULL,content_hash TEXT NOT NULL,unit_count INTEGER NOT NULL,byte_count INTEGER NOT NULL)"
        )
        try execute(
            "CREATE TABLE corpus_link (item_id TEXT NOT NULL,ordinal INTEGER NOT NULL,generation_id TEXT NOT NULL,unit_start INTEGER NOT NULL,byte_start INTEGER NOT NULL,overlay TEXT NOT NULL,PRIMARY KEY(item_id,ordinal))"
        )
        try execute("CREATE INDEX corpus_link_generation ON corpus_link(generation_id,item_id)")
    }

    /// Correlated membership preserves item counts/order/seek and one literal phrase boundary.
    static var corpusLiteralMembershipSQL: String {
        "EXISTS (SELECT 1 FROM corpus_head h JOIN corpus_link l ON l.item_id=h.item_id JOIN corpus_generation g ON g.id=l.generation_id AND g.state='ready' JOIN corpus_unit u ON u.generation_id=g.id JOIN page_text_index ON page_text_index.rowid=u.id WHERE h.item_id=items.id AND h.revision_id=items.revision AND h.layout='"
            + PageCorpusBinding.layoutName + "' AND page_text_index MATCH ?)"
    }
}

extension ItemIndex {
    /// Main persists workID before this call and authenticates the PageCorpus provider/source.
    /// Independent writer batches never publish current links or touch the live ItemIndex handle.
    static func stageCorpus(
        indexPath: String, input: PageCorpusInput, prepared: PreparedPageCorpus, workID: String,
        writeBoundary: (IndexCorpusWriteBatch) throws -> Void, boundary: () throws -> Void
    ) throws -> IndexedCorpusStage {
        try PageCorpusInput.validateID(workID)
        try boundary()
        try PageCorpusProjection.verify(prepared, expected: input.binding, boundary: boundary)
        if let retained = try loadStagedCorpus(
            indexPath: indexPath, input: input, workID: workID, boundary: boundary)
        {
            let observation = try IndexCorpusSQL(path: indexPath, readOnly: true)
            try writeBoundary(
                .init(
                    phase: .afterCommit, workID: workID, estimatedAdditionalBytes: 0, units: 0,
                    retainedEncodedBytes: observation.retainedEncodedBytes(workID)))
            return retained
        }
        let fence = try IndexCorpusFileFence.capture(indexPath)
        let writer = try IndexCorpusSQL(path: indexPath, readOnly: false)
        guard let indexIdentity = try writer.scalar("SELECT id FROM corpus_index_identity") else {
            throw TractandaError("indexUnavailable", "The corpus index requires rebuilding.")
        }
        let plans = try IndexCorpusPlan.components(input)
        var components: [String: IndexedCorpusComponent] = [:]
        var created: Set<String> = []  // Bounded by canonical component descriptors, never pages/items.
        var owners: [String: Int] = [:]
        var counts: [String: (Int64, Int64)] = [:]
        func fenceBoundary() throws {
            try boundary()
            guard try IndexCorpusFileFence.capture(indexPath) == fence,
                try writer.scalar("SELECT id FROM corpus_index_identity") == indexIdentity
            else {
                throw TractandaError("indexUnavailable", "The corpus index changed during staging.")
            }
        }
        let sourceJSON = String(decoding: try JSON.encode(input.binding), as: UTF8.self)
        let workEncoded = try IndexCorpusEncoding.work(workID, "stage", sourceJSON)
        func afterCommit(_ units: Int, _ pending: Int64 = 0) throws {
            try writeBoundary(
                .init(
                    phase: .afterCommit, workID: workID, estimatedAdditionalBytes: 0, units: units,
                    pendingEncodedBytes: pending, retainedEncodedBytes: writer.retainedEncodedBytes(workID)))
            try fenceBoundary()
        }
        try writeBoundary(
            .init(
                phase: .before, workID: workID, estimatedAdditionalBytes: 65_536 + Int64(plans.count) * 4096,
                units: 0, pendingEncodedBytes: workEncoded,
                retainedEncodedBytes: writer.retainedEncodedBytes(workID)))
        try writer.transaction {
            var pending: Int64 = 0
            try writer.rows("SELECT count(*) FROM (SELECT 1 FROM corpus_work LIMIT 64)") {
                pending = sqlite3_column_int64($0, 0)
            }
            guard pending < 64 else {
                throw TractandaError(
                    "resourceLimit", "The corpus work window is full; finish or discard retained work.")
            }
            try writer.execute(
                "INSERT INTO corpus_work VALUES (?,'stage',?,?)",
                [.text(workID), .text(sourceJSON), .integer(workEncoded)])
            for (offset, plan) in plans.enumerated() {
                if components[plan.sourceKey] == nil {
                    var component: IndexedCorpusComponent?
                    try writer.rows(
                        "SELECT id,kind,unit_count,byte_count FROM corpus_generation WHERE source_key=? AND state='ready'",
                        [.text(plan.sourceKey)]
                    ) { row in
                        component = try IndexedCorpusComponent(
                            generationID: writer.text(row, 0), sourceKey: plan.sourceKey,
                            kind: writer.text(row, 1), unitCount: sqlite3_column_int64(row, 2),
                            byteCount: sqlite3_column_int64(row, 3))
                    }
                    if let component {
                        guard component.kind == plan.kind, component.unitCount >= 0, component.byteCount >= 0
                        else {
                            throw TractandaError("indexError", "A reusable corpus component is malformed.")
                        }
                        components[plan.sourceKey] = component
                    } else {
                        let generationID = try UUID.makeVersion1().uuidString.lowercased()
                        let header = try IndexCorpusEncoding.generation(
                            generationID, plan.sourceKey, plan.kind, "writing", 0, 0, workID)
                        try writer.execute(
                            "INSERT INTO corpus_generation VALUES (?,?,?,'writing',0,0,?,?,?)",
                            [
                                .text(generationID), .text(plan.sourceKey), .text(plan.kind), .text(workID),
                                .integer(header), .integer(header),
                            ])
                        try writer.execute(
                            "INSERT OR IGNORE INTO corpus_gc_candidate VALUES (?)", [.text(generationID)])
                        components[plan.sourceKey] = .init(
                            generationID: generationID, sourceKey: plan.sourceKey, kind: plan.kind,
                            unitCount: 0, byteCount: 0)
                        created.insert(plan.sourceKey)
                        owners[plan.sourceKey] = offset
                        counts[plan.sourceKey] = (0, 0)
                    }
                }
                let component = components[plan.sourceKey]!
                try writer.execute(
                    "INSERT OR IGNORE INTO corpus_work_generation VALUES (?,?)",
                    [.text(workID), .text(component.generationID)])
            }
            try writeBoundary(.init(phase: .after, workID: workID, estimatedAdditionalBytes: 0, units: 0))
            try fenceBoundary()
        }
        try afterCommit(0, workEncoded)
        do {
            let spool = try IndexCorpusSQL(path: prepared.databaseURL.path, readOnly: true)
            var seenUnits: Int64 = 0
            var seenBytes: Int64 = 0
            try spool.rows(
                "SELECT u.id,u.ordinal,u.byte_count,u.origin,t.text FROM corpus_unit u JOIN text_index t ON t.rowid=u.id ORDER BY u.ordinal"
            ) { row in
                try fenceBoundary()
                let sourceID = sqlite3_column_int64(row, 0)
                let ordinal = sqlite3_column_int64(row, 1)
                let byteCount = sqlite3_column_int64(row, 2)
                let origin = try JSON.decode(PageCorpusOrigin.self, Data(spool.text(row, 3).utf8))
                let text = try spool.text(row, 4)
                guard ordinal == seenUnits, byteCount == Int64(text.utf8.count), byteCount <= 8 * 1024 * 1024,
                    let planIndex = plans.firstIndex(where: {
                        $0.kind == origin.kind && $0.attachmentID == origin.attachmentID
                    })
                else {
                    throw TractandaError("indexError", "The sealed corpus unit/source binding changed.")
                }
                seenUnits = try PageCorpusEmitter.add(seenUnits, 1)
                seenBytes = try PageCorpusEmitter.add(seenBytes, byteCount)
                let plan = plans[planIndex]
                guard created.contains(plan.sourceKey), owners[plan.sourceKey] == planIndex else { return }
                let component = components[plan.sourceKey]!
                let counter = counts[plan.sourceKey]!
                var spans: [PageCorpusSpan] = []
                try spool.rows(
                    "SELECT block_index,start,end,box FROM corpus_span WHERE unit_id=? ORDER BY block_index LIMIT 513",
                    [.integer(sourceID)]
                ) { span in
                    let box: DoclingBoundingBox? =
                        sqlite3_column_type(span, 3) == SQLITE_NULL
                        ? nil : try JSON.decode(DoclingBoundingBox.self, Data(spool.text(span, 3).utf8))
                    spans.append(
                        .init(
                            blockIndex: sqlite3_column_int64(span, 0),
                            unitByteStart: sqlite3_column_int64(span, 1),
                            unitByteEnd: sqlite3_column_int64(span, 2), box: box))
                }
                guard spans.count <= 512,
                    spans.allSatisfy({
                        $0.unitByteStart >= 0 && $0.unitByteEnd >= $0.unitByteStart
                            && $0.unitByteEnd <= byteCount
                    })
                else { throw TractandaError("indexError", "Corpus spans exceed their exact page window.") }
                let metadata = try JSON.encode(origin)
                let spanBytes = try JSON.encode(spans)
                let growth = try PageCorpusEmitter.add(
                    byteCount, Int64(metadata.count + spanBytes.count + 65_536))
                let estimate = growth.multipliedReportingOverflow(by: 4)
                guard !estimate.overflow else {
                    throw TractandaError("resourceLimit", "Corpus batch estimate overflow.")
                }
                let unitEncoded = try IndexCorpusEncoding.unit(
                    component.generationID, counter.0, counter.1, text, origin, spans)
                let newCount = try PageCorpusEmitter.add(counter.0, 1)
                let newBytes = try PageCorpusEmitter.add(counter.1, byteCount)
                let oldHeader = try IndexCorpusEncoding.generation(
                    component.generationID, plan.sourceKey, plan.kind, "writing", counter.0, counter.1, workID
                )
                let newHeader = try IndexCorpusEncoding.generation(
                    component.generationID, plan.sourceKey, plan.kind, "writing", newCount, newBytes, workID)
                let pendingEncoded = try PageCorpusEmitter.add(unitEncoded, newHeader - oldHeader)
                var oldEncoded: Int64 = 0
                try writer.rows(
                    "SELECT encoded_bytes FROM corpus_generation WHERE id=?", [.text(component.generationID)]
                ) { row in
                    guard sqlite3_column_type(row, 0) == SQLITE_INTEGER else {
                        throw TractandaError("indexError", "Corpus generation charge is not an integer.")
                    }
                    oldEncoded = sqlite3_column_int64(row, 0)
                }
                let newEncoded = try PageCorpusEmitter.add(oldEncoded, pendingEncoded)
                try writeBoundary(
                    .init(
                        phase: .before, workID: workID, estimatedAdditionalBytes: estimate.partialValue,
                        units: 1, pendingEncodedBytes: pendingEncoded,
                        retainedEncodedBytes: writer.retainedEncodedBytes(workID)))
                try writer.transaction {
                    try fenceBoundary()
                    try writer.execute(
                        "INSERT INTO corpus_unit(generation_id,ordinal,byte_start,byte_count,origin,encoded_bytes) VALUES (?,?,?,?,?,?)",
                        [
                            .text(component.generationID), .integer(counter.0), .integer(counter.1),
                            .integer(byteCount), .text(String(decoding: metadata, as: UTF8.self)),
                            .integer(unitEncoded),
                        ])
                    let unitID = writer.lastRowID
                    try writer.execute(
                        "INSERT INTO page_text_index(rowid,text) VALUES (?,?)",
                        [.integer(unitID), .text(text)])
                    for span in spans {
                        let box: IndexCorpusSQL.Value =
                            try span.box.map { .text(String(decoding: try JSON.encode($0), as: UTF8.self)) }
                            ?? .null
                        try writer.execute(
                            "INSERT INTO corpus_span VALUES (?,?,?,?,?)",
                            [
                                .integer(unitID), .integer(span.blockIndex), .integer(span.unitByteStart),
                                .integer(span.unitByteEnd), box,
                            ])
                    }
                    try writer.execute(
                        "UPDATE corpus_generation SET unit_count=?,byte_count=?,header_bytes=?,encoded_bytes=? WHERE id=? AND state='writing'",
                        [
                            .integer(newCount), .integer(newBytes), .integer(newHeader),
                            .integer(newEncoded), .text(component.generationID),
                        ])
                    try writeBoundary(
                        .init(phase: .after, workID: workID, estimatedAdditionalBytes: 0, units: 1))
                    try fenceBoundary()
                }
                try afterCommit(1, pendingEncoded)
                counts[plan.sourceKey] = (
                    try PageCorpusEmitter.add(counter.0, 1), try PageCorpusEmitter.add(counter.1, byteCount)
                )
            }
            guard seenUnits == prepared.receipt.summary.unitCount,
                seenBytes == prepared.receipt.summary.utf8Bytes
            else { throw TractandaError("indexError", "The sealed corpus unit totals changed.") }
            try writer.transaction {
                try fenceBoundary()
                for key in created.sorted() {
                    let component = components[key]!
                    let counter = counts[key]!
                    var concurrent: IndexedCorpusComponent?
                    try writer.rows(
                        "SELECT id,kind,unit_count,byte_count FROM corpus_generation WHERE source_key=? AND state='ready'",
                        [.text(key)]
                    ) { row in
                        concurrent = try .init(
                            generationID: writer.text(row, 0), sourceKey: key, kind: writer.text(row, 1),
                            unitCount: sqlite3_column_int64(row, 2), byteCount: sqlite3_column_int64(row, 3))
                    }
                    if let concurrent {
                        guard concurrent.kind == component.kind, concurrent.unitCount == counter.0,
                            concurrent.byteCount == counter.1
                        else {
                            throw TractandaError(
                                "indexError", "Concurrent immutable corpus source totals disagree.")
                        }
                        try writer.execute(
                            "DELETE FROM corpus_work_generation WHERE work_id=? AND generation_id=?",
                            [.text(workID), .text(component.generationID)])
                        try writer.execute(
                            "INSERT OR IGNORE INTO corpus_work_generation VALUES (?,?)",
                            [.text(workID), .text(concurrent.generationID)])
                        components[key] = concurrent
                    } else {
                        try writer.execute(
                            "UPDATE corpus_generation SET state='ready',header_bytes=?,encoded_bytes=encoded_bytes-header_bytes+? WHERE id=? AND state='writing'",
                            [
                                .integer(
                                    try IndexCorpusEncoding.generation(
                                        component.generationID, key, component.kind, "ready", counter.0,
                                        counter.1, workID)),
                                .integer(
                                    try IndexCorpusEncoding.generation(
                                        component.generationID, key, component.kind, "ready", counter.0,
                                        counter.1, workID)), .text(component.generationID),
                            ])
                        components[key] = .init(
                            generationID: component.generationID, sourceKey: key, kind: component.kind,
                            unitCount: counter.0, byteCount: counter.1)
                    }
                }
            }
            try afterCommit(0)
            return IndexedCorpusStage(
                workID: workID, indexIdentity: indexIdentity, fence: fence, source: input.binding,
                ordinaryFingerprint: try IndexCorpusPlan.ordinaryFingerprint(input.revision),
                components: plans.map { components[$0.sourceKey]! })
        } catch {
            // Committed encoded bytes, work ownership and producer refs remain durable. Main
            // fences this producer and explicitly resumes/disposes; never refund on an error.
            throw error
        }
    }
}

extension IndexCorpusPlan {
    static func current(_ revision: Revision) throws -> [IndexCorpusComponentPlan] {
        guard try JSON.encode(revision).count <= 8 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Corpus head exceeds its canonical record window.")
        }
        guard !revision.isDeleted else { return [] }
        let originals = try AttachmentDescriptor.descriptors(in: revision.fields)
        let texts = try AttachmentTextRepresentation.representations(in: revision.fields).filter { text in
            originals.contains {
                $0.attachmentID == text.attachmentID && $0.sha256 == text.source.sha256
                    && $0.byteCount == text.source.byteCount && $0.mediaType == text.source.mediaType
            }
        }
        let documents = try AttachmentDocumentRepresentation.representations(in: revision.fields).filter {
            document in
            originals.contains {
                $0.attachmentID == document.attachmentID && $0.sha256 == document.source.sha256
                    && $0.byteCount == document.source.byteCount && $0.mediaType == document.source.mediaType
            }
        }
        var plans = [
            IndexCorpusComponentPlan(
                sourceKey: "fields:" + (try ordinaryFingerprint(revision)), kind: "field", attachmentID: nil,
                overlay: .init(attachmentID: nil, representationID: nil, contentID: nil))
        ]
        for text in texts {
            let key = PageCorpusInput.digest(
                try JSON.encode(
                    IndexTextSourceIdentity(
                        layout: PageCorpusBinding.layoutName, schema: AttachmentTextRepresentation.schema,
                        converter: AttachmentTextRepresentation.converter, extractedAt: text.extractedAt,
                        source: text.source,
                        sourceByteStart: text.sourceByteStart, text: text.text)))
            plans.append(
                .init(
                    sourceKey: "text:" + key, kind: "originalBytes", attachmentID: text.attachmentID,
                    overlay: .init(
                        attachmentID: text.attachmentID, representationID: text.representationID,
                        contentID: nil)))
        }
        for value in documents {
            let document = try PageCorpusDocumentPlan(document: value)
            let key = PageCorpusInput.digest(
                try JSON.encode(
                    IndexDocumentSourceIdentity(
                        layout: PageCorpusBinding.layoutName, source: document.source,
                        identity: document.identity, extractedAt: document.extractedAt,
                        rootSHA256: document.rootSHA256, pageCount: document.pageCount,
                        encodedBytes: document.totalEncodedBytes, coverage: document.coverage,
                        inlinePages: document.inlinePages)))
            plans.append(
                .init(
                    sourceKey: "document:" + key, kind: "document", attachmentID: document.attachmentID,
                    overlay: .init(
                        attachmentID: document.attachmentID, representationID: document.representationID,
                        contentID: document.savedContent?.contentID)))
        }
        return plans
    }
}

extension ItemIndex {
    private func corpusRows(_ sql: String, _ values: [String] = [], visit: (OpaquePointer) throws -> Void)
        throws
    {
        let statement = try corpusPrepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else {
                throw TractandaError("indexError", "Corpus index operation failed.")
            }
            try visit(statement)
        }
    }
    private func corpusText(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard let pointer = sqlite3_column_text(statement, column),
            let string = String(
                bytes: UnsafeBufferPointer(
                    start: pointer, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
        else { throw TractandaError("indexError", "Corpus metadata is not valid UTF8.") }
        return string
    }
    private func readyCorpusComponent(_ sourceKey: String) throws -> IndexedCorpusComponent? {
        var component: IndexedCorpusComponent?
        try corpusRows(
            "SELECT id,kind,unit_count,byte_count FROM corpus_generation WHERE source_key=? AND state='ready'",
            [sourceKey]
        ) { row in
            guard component == nil else {
                throw TractandaError("indexError", "Corpus source key is ambiguous.")
            }
            component = try IndexedCorpusComponent(
                generationID: corpusText(row, 0), sourceKey: sourceKey, kind: corpusText(row, 1),
                unitCount: sqlite3_column_int64(row, 2), byteCount: sqlite3_column_int64(row, 3))
        }
        return component
    }

    private func installBoundedOrdinaryCorpus(_ revision: Revision, plans: [IndexCorpusComponentPlan]) throws
    {
        for plan in plans where plan.kind != "document" {
            guard try readyCorpusComponent(plan.sourceKey) == nil else { continue }
            let generationID = try UUID.makeVersion1().uuidString.lowercased()
            try execute(
                "INSERT INTO corpus_generation VALUES (?,?,?,'writing',0,0,NULL,0,0)",
                [generationID, plan.sourceKey, plan.kind])
            var count: Int64 = 0
            var bytes: Int64 = 0
            func unit(_ text: String, origin: PageCorpusOrigin) throws {
                guard text.utf8.count <= 8 * 1024 * 1024 else {
                    throw TractandaError(
                        "resourceLimit", "Corpus value exceeds its bounded canonical window.")
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                try execute(
                    "INSERT INTO corpus_unit(generation_id,ordinal,byte_start,byte_count,origin,encoded_bytes) VALUES (?,?,?,?,?,0)",
                    [
                        generationID, String(count), String(bytes), String(text.utf8.count),
                        String(decoding: try JSON.encode(origin), as: UTF8.self),
                    ])
                var unitID: String?
                try corpusRows(
                    "SELECT id FROM corpus_unit WHERE generation_id=? AND ordinal=?",
                    [generationID, String(count)]
                ) { unitID = try corpusText($0, 0) }
                guard let unitID else {
                    throw TractandaError("indexError", "The new bounded corpus unit is absent.")
                }
                try execute("INSERT INTO page_text_index(rowid,text) VALUES (?,?)", [unitID, text])
                count = try PageCorpusEmitter.add(count, 1)
                bytes = try PageCorpusEmitter.add(bytes, Int64(text.utf8.count))
            }
            if plan.kind == "field" {
                try IndexCorpusPlan.forEachField(revision) { path, text in
                    try unit(
                        text,
                        origin: .init(
                            kind: "field", fieldPath: path, attachmentID: nil, representationID: nil,
                            contentID: nil, documentSource: nil, textSource: nil, pageNumber: nil,
                            sourceByteStart: nil, sourceByteEnd: nil, rasterSHA256: nil, geometry: nil))
                }
            } else {
                guard
                    let text = try AttachmentTextRepresentation.representations(in: revision.fields).first(
                        where: { $0.attachmentID == plan.attachmentID })
                else { throw TractandaError("indexError", "The current saved text binding is absent.") }
                try unit(
                    text.text,
                    origin: .init(
                        kind: "originalBytes", fieldPath: nil, attachmentID: text.attachmentID,
                        representationID: text.representationID, contentID: nil, documentSource: nil,
                        textSource: text.source, pageNumber: nil,
                        sourceByteStart: Int64(text.sourceByteStart), sourceByteEnd: text.source.byteCount,
                        rasterSHA256: nil, geometry: nil))
            }
            try execute(
                "UPDATE corpus_generation SET state='ready',unit_count=?,byte_count=? WHERE id=?",
                [String(count), String(bytes), generationID])
        }
    }

    /// Caller owns the enclosing head/scalar/CAS transaction and fresh current authorization.
    /// This changes compact links only for staged pages, never imports a spool or copies pages.
    func putCorpus(_ revision: Revision, stage: IndexedCorpusStage? = nil) throws {
        let plans = try IndexCorpusPlan.current(revision)
        if let stage {
            guard revision.itemID == stage.source.itemID, revision.supersedes == stage.source.baseRevisionID,
                try IndexCorpusFileFence.capture(corpusIndexPath) == stage.fence,
                try IndexCorpusPlan.ordinaryFingerprint(revision) == stage.ordinaryFingerprint
            else {
                throw TractandaError(
                    "indexError", "The staged corpus publication base or ordinary fields changed.")
            }
            var identity: String?
            var source: PageCorpusBinding?
            try corpusRows("SELECT id FROM corpus_index_identity") { identity = try corpusText($0, 0) }
            try corpusRows("SELECT source FROM corpus_work WHERE id=? AND kind='stage'", [stage.workID]) {
                source = try JSON.decode(PageCorpusBinding.self, Data(corpusText($0, 0).utf8))
            }
            guard identity == stage.indexIdentity, source == stage.source else {
                throw TractandaError("indexError", "The staged corpus capability is unavailable.")
            }
            for plan in plans {
                guard let component = stage.components.first(where: { $0.sourceKey == plan.sourceKey }),
                    let current = try readyCorpusComponent(plan.sourceKey), current == component
                else {
                    throw TractandaError("indexError", "A staged current source/component binding changed.")
                }
                var retained = false
                try corpusRows(
                    "SELECT 1 FROM corpus_work_generation WHERE work_id=? AND generation_id=?",
                    [stage.workID, component.generationID]
                ) { _ in retained = true }
                guard retained else {
                    throw TractandaError("indexError", "A staged component lost its retention capability.")
                }
            }
            guard Set(plans.map(\.sourceKey)) == Set(stage.components.map(\.sourceKey)) else {
                throw TractandaError(
                    "indexError", "Staged components do not match the actual current sources.")
            }
        } else {
            // These values are bounded by the existing canonical record, never referenced pages.
            try installBoundedOrdinaryCorpus(revision, plans: plans)
        }
        var links: [IndexedCorpusLink] = []
        var count: Int64 = 0
        var bytes: Int64 = 0
        for plan in plans {
            guard let component = try readyCorpusComponent(plan.sourceKey), component.kind == plan.kind,
                component.unitCount >= 0, component.byteCount >= 0
            else {
                throw TractandaError(
                    "indexUnavailable", "The current document corpus requires authenticated staging/rebuild.")
            }
            links.append(
                .init(component: component, unitStart: count, byteStart: bytes, overlay: plan.overlay))
            count = try PageCorpusEmitter.add(count, component.unitCount)
            bytes = try PageCorpusEmitter.add(bytes, component.byteCount)
        }
        struct ContentIdentity: Encodable {
            let layout: String
            let components: [String]
        }
        let hash = PageCorpusInput.digest(
            try JSON.encode(
                ContentIdentity(
                    layout: PageCorpusBinding.layoutName, components: links.map { $0.component.sourceKey })))
        var previous: [String] = []
        try corpusRows(
            "SELECT generation_id FROM corpus_link WHERE item_id=? ORDER BY ordinal LIMIT 258",
            [revision.itemID]
        ) { previous.append(try corpusText($0, 0)) }
        guard previous.count <= 257 else {
            throw TractandaError("indexError", "Prior corpus components exceed their bounded window.")
        }
        try execute("DELETE FROM corpus_link WHERE item_id=?", [revision.itemID])
        for (ordinal, link) in links.enumerated() {
            try execute(
                "INSERT INTO corpus_link VALUES (?,?,?,?,?,?)",
                [
                    revision.itemID, String(ordinal), link.component.generationID, String(link.unitStart),
                    String(link.byteStart), String(decoding: try JSON.encode(link.overlay), as: UTF8.self),
                ])
        }
        try execute(
            "INSERT OR REPLACE INTO corpus_head VALUES (?,?,?,?,?,?)",
            [
                revision.itemID, revision.revisionID, PageCorpusBinding.layoutName, hash, String(count),
                String(bytes),
            ])
        for link in links {
            try execute(
                "DELETE FROM corpus_gc_candidate WHERE generation_id=?", [link.component.generationID])
        }
        for id in previous {
            try execute(
                "INSERT OR IGNORE INTO corpus_gc_candidate SELECT ? WHERE NOT EXISTS (SELECT 1 FROM corpus_link WHERE generation_id=?)",
                [id, id])
        }
        if let stage { try retireCorpusWork(stage.workID) }
    }
}

struct IndexedCorpusWork: Sendable {
    let workID: String
    let kind: String
    let source: Data
}

extension ItemIndex {
    func captureCorpusSnapshot(itemID: String, expectedRevisionID: String, retentionID: String? = nil) throws
        -> IndexedCorpusSnapshot?
    {
        var transactionOpen = false
        if let retentionID {
            try PageCorpusInput.validateID(retentionID)
            try execute("BEGIN IMMEDIATE")
            transactionOpen = true
        }
        do {
            var identity: IndexedCorpusIdentity?
            try corpusRows(
                "SELECT h.revision_id,h.layout,h.content_hash,h.unit_count,h.byte_count FROM corpus_head h JOIN items ON items.id=h.item_id AND items.revision=h.revision_id WHERE h.item_id=? AND items.deleted=0",
                [itemID]
            ) { row in
                guard try corpusText(row, 0) == expectedRevisionID,
                    try corpusText(row, 1) == PageCorpusBinding.layoutName
                else { return }
                identity = try .init(
                    itemID: itemID, revisionID: corpusText(row, 0), layout: corpusText(row, 1),
                    contentHash: corpusText(row, 2), unitCount: sqlite3_column_int64(row, 3),
                    utf8Bytes: sqlite3_column_int64(row, 4))
            }
            guard let identity else {
                if retentionID != nil {
                    try execute("COMMIT")
                    transactionOpen = false
                }
                return nil
            }
            var links: [IndexedCorpusLink] = []
            var ordinal: Int64 = 0
            var bytes: Int64 = 0
            try corpusRows(
                "SELECT l.generation_id,l.unit_start,l.byte_start,l.overlay,g.source_key,g.kind,g.unit_count,g.byte_count FROM corpus_link l JOIN corpus_generation g ON g.id=l.generation_id AND g.state='ready' WHERE l.item_id=? ORDER BY l.ordinal LIMIT 258",
                [itemID]
            ) { row in
                guard links.count < 257, sqlite3_column_int64(row, 1) == ordinal,
                    sqlite3_column_int64(row, 2) == bytes
                else {
                    throw TractandaError(
                        "indexError", "Current corpus links exceed or disagree with their bounded head.")
                }
                let count = sqlite3_column_int64(row, 6)
                let byteCount = sqlite3_column_int64(row, 7)
                guard count >= 0, byteCount >= 0 else {
                    throw TractandaError("indexError", "Current corpus component totals are invalid.")
                }
                let component = try IndexedCorpusComponent(
                    generationID: corpusText(row, 0), sourceKey: corpusText(row, 4), kind: corpusText(row, 5),
                    unitCount: count, byteCount: byteCount)
                let overlay = try JSON.decode(IndexedCorpusOverlay.self, Data(corpusText(row, 3).utf8))
                links.append(
                    .init(component: component, unitStart: ordinal, byteStart: bytes, overlay: overlay))
                ordinal = try PageCorpusEmitter.add(ordinal, count)
                bytes = try PageCorpusEmitter.add(bytes, byteCount)
            }
            guard ordinal == identity.unitCount, bytes == identity.utf8Bytes else {
                throw TractandaError("indexError", "Current corpus projection totals disagree with its head.")
            }
            var indexIdentity: String?
            try corpusRows("SELECT id FROM corpus_index_identity") { indexIdentity = try corpusText($0, 0) }
            guard let indexIdentity else {
                throw TractandaError("indexError", "Corpus index identity is missing.")
            }
            if let retentionID {
                var pending: Int64 = 0
                try corpusRows("SELECT count(*) FROM (SELECT 1 FROM corpus_work LIMIT 64)") {
                    pending = sqlite3_column_int64($0, 0)
                }
                guard pending < 64 else {
                    throw TractandaError("resourceLimit", "The corpus work window is full.")
                }
                try execute(
                    "INSERT INTO corpus_work VALUES (?,'read',?,?)",
                    [
                        retentionID, String(decoding: try JSON.encode(identity), as: UTF8.self),
                        String(
                            try IndexCorpusEncoding.work(
                                retentionID, "read",
                                String(decoding: try JSON.encode(identity), as: UTF8.self))),
                    ])
                for link in links {
                    try execute(
                        "INSERT OR IGNORE INTO corpus_work_generation VALUES (?,?)",
                        [retentionID, link.component.generationID])
                }
                try execute("COMMIT")
                transactionOpen = false
                try afterCorpusReadCommitForTesting?()
            }
            return .init(
                identity: identity, indexPath: corpusIndexPath, indexIdentity: indexIdentity,
                fence: try IndexCorpusFileFence.capture(corpusIndexPath), links: links,
                retentionID: retentionID)
        } catch {
            if transactionOpen { try? execute("ROLLBACK") }
            throw error
        }
    }

    /// Owning lifecycle must fence the producer first. Release/discard never deletes current bytes.
    func releaseCorpusWork(_ workID: String) throws {
        try PageCorpusInput.validateID(workID)
        try execute("BEGIN IMMEDIATE")
        do {
            try retireCorpusWork(workID)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func corpusWorkPage(after: String? = nil, limit: Int = 64) throws -> [IndexedCorpusWork] {
        guard (1...64).contains(limit) else {
            throw TractandaError("invalidArguments", "Use a bounded corpus work cursor.")
        }
        var result: [IndexedCorpusWork] = []
        try corpusRows(
            "SELECT id,kind,source FROM corpus_work WHERE id>? ORDER BY id LIMIT ?",
            [after ?? "", String(limit)]
        ) { row in
            let source = try corpusText(row, 2)
            guard source.utf8.count <= 16 * 1024 else {
                throw TractandaError("indexError", "Corpus work source binding exceeds its recovery window.")
            }
            result.append(
                try .init(workID: corpusText(row, 0), kind: corpusText(row, 1), source: Data(source.utf8)))
        }
        return result
    }

    /// A cursor visits at most sixteen RETIREMENT candidates, never all live/protected pages.
    /// Per-generation unit selection uses the (generation_id,ordinal) index and a fixed row budget.
    @discardableResult
    func cleanupCorpus(limit: Int = 16, boundary: () throws -> Void = {}) throws -> Int {
        guard (1...16).contains(limit) else {
            throw TractandaError(
                "invalidArguments", "Use a cleanup batch of one through sixteen corpus units.")
        }
        try boundary()
        corpusGCStatsForTesting = .init()
        try execute("BEGIN IMMEDIATE")
        do {
            var cursor = ""
            try corpusRows("SELECT generation_id FROM corpus_gc_cursor WHERE singleton=1") {
                cursor = try corpusText($0, 0)
            }
            var candidates: [String] = []
            try corpusRows(
                "SELECT generation_id FROM corpus_gc_candidate WHERE generation_id>? ORDER BY generation_id LIMIT 16",
                [cursor]
            ) { candidates.append(try corpusText($0, 0)) }
            if candidates.isEmpty, cursor != "" {
                cursor = ""
                try execute("UPDATE corpus_gc_cursor SET generation_id='' WHERE singleton=1")
                try corpusRows(
                    "SELECT generation_id FROM corpus_gc_candidate ORDER BY generation_id LIMIT 16"
                ) { candidates.append(try corpusText($0, 0)) }
            }
            var owners: Set<String> = []  // At most sixteen candidate headers, not a store-sized set.
            var removed = 0
            for id in candidates {
                try boundary()
                corpusGCStatsForTesting.candidateGenerations += 1
                var protected = false
                try corpusRows(
                    "SELECT 1 WHERE EXISTS (SELECT 1 FROM corpus_link WHERE generation_id=?) OR EXISTS (SELECT 1 FROM corpus_work_generation WHERE generation_id=?)",
                    [id, id]
                ) { _ in protected = true }
                cursor = id
                if protected { continue }
                var owner: String?
                try corpusRows("SELECT owner_work_id FROM corpus_generation WHERE id=?", [id]) { row in
                    if sqlite3_column_type(row, 0) != SQLITE_NULL { owner = try corpusText(row, 0) }
                }
                if let owner { owners.insert(owner) }
                // Retire BEFORE deleting any bytes so an immutable ready source cannot be reused halfway through GC.
                if let owner {
                    var header: Int64 = 0
                    try corpusRows(
                        "SELECT source_key,kind,unit_count,byte_count FROM corpus_generation WHERE id=?", [id]
                    ) { row in
                        header = try IndexCorpusEncoding.generation(
                            id, corpusText(row, 0), corpusText(row, 1), "retired",
                            sqlite3_column_int64(row, 2), sqlite3_column_int64(row, 3), owner)
                    }
                    try execute(
                        "UPDATE corpus_generation SET state='retired',encoded_bytes=encoded_bytes-header_bytes+?,header_bytes=? WHERE id=?",
                        [String(header), String(header), id])
                } else {
                    try execute("UPDATE corpus_generation SET state='retired' WHERE id=?", [id])
                }
                var units: [(String, Int64)] = []
                let remaining = limit - removed
                if remaining > 0 {
                    try corpusRows(
                        "SELECT id,encoded_bytes FROM corpus_unit WHERE generation_id=? ORDER BY ordinal LIMIT ?",
                        [id, String(remaining)]
                    ) { row in
                        let encoded = sqlite3_column_int64(row, 1)
                        guard encoded >= 0 else {
                            throw TractandaError("indexError", "Retired corpus unit charge is invalid.")
                        }
                        units.append((try corpusText(row, 0), encoded))
                    }
                }
                corpusGCStatsForTesting.unitsExamined += units.count
                for (unitID, encoded) in units {
                    try boundary()
                    try execute("DELETE FROM page_text_index WHERE rowid=?", [unitID])
                    try execute("DELETE FROM corpus_span WHERE unit_id=?", [unitID])
                    try execute("DELETE FROM corpus_unit WHERE id=?", [unitID])
                    try execute(
                        "UPDATE corpus_generation SET encoded_bytes=encoded_bytes-? WHERE id=? AND encoded_bytes>=?",
                        [String(encoded), id, String(encoded)])
                    removed += 1
                }
                var remainingUnits = false
                try corpusRows("SELECT 1 FROM corpus_unit WHERE generation_id=? LIMIT 1", [id]) { _ in
                    remainingUnits = true
                }
                if !remainingUnits {
                    try execute("DELETE FROM corpus_generation WHERE id=?", [id])
                    try execute("DELETE FROM corpus_gc_candidate WHERE generation_id=?", [id])
                    corpusGCStatsForTesting.headersDeleted += 1
                }
                if removed == limit { break }
            }
            try execute("UPDATE corpus_gc_cursor SET generation_id=? WHERE singleton=1", [cursor])
            for owner in owners {
                try execute(
                    "DELETE FROM corpus_work WHERE id=? AND kind='discard' AND NOT EXISTS (SELECT 1 FROM corpus_generation WHERE owner_work_id=?)",
                    [owner, owner])
            }
            corpusGCStatsForTesting.unitsDeleted = removed
            try boundary()
            try execute("COMMIT")
            return removed
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func corpusGCPlanForTesting() throws -> [String] {
        var plans: [String] = []
        try corpusRows(
            "EXPLAIN QUERY PLAN SELECT id,encoded_bytes FROM corpus_unit WHERE generation_id=? ORDER BY ordinal LIMIT 16",
            ["fixture-generation"]
        ) { plans.append(try corpusText($0, 3)) }
        try corpusRows(
            "EXPLAIN QUERY PLAN SELECT generation_id FROM corpus_gc_candidate WHERE generation_id>? ORDER BY generation_id LIMIT 16",
            [""]
        ) { plans.append(try corpusText($0, 3)) }
        return plans
    }

    /// Independent readonly access to one captured component, not the live Store/SQLite handle.
    /// Main repeats fresh current-head/active-original/current-ACL checks before caller delivery.
    static func readCorpusUnit(
        _ snapshot: IndexedCorpusSnapshot, ordinal: Int64, offset: Int64 = 0, limit: Int = 262_144,
        boundary: () throws -> Void = {}
    ) throws -> IndexedCorpusUnitWindow {
        guard ordinal >= 0, offset >= 0, offset < Int64.max, (1...262_144).contains(limit),
            let link = snapshot.links.first(where: {
                ordinal >= $0.unitStart && ordinal - $0.unitStart < $0.component.unitCount
            })
        else { throw TractandaError("invalidArguments", "Use a current bounded corpus unit window.") }
        try boundary()
        guard try IndexCorpusFileFence.capture(snapshot.indexPath) == snapshot.fence else {
            throw TractandaError("indexUnavailable", "The captured corpus index was replaced.")
        }
        let reader = try IndexCorpusSQL(path: snapshot.indexPath, readOnly: true)
        guard try reader.scalar("SELECT id FROM corpus_index_identity") == snapshot.indexIdentity else {
            throw TractandaError("indexUnavailable", "The captured corpus index identity changed.")
        }
        if let workID = snapshot.retentionID {
            guard
                try reader.scalar(
                    "SELECT generation_id FROM corpus_work_generation WHERE work_id=? AND generation_id=?",
                    [.text(workID), .text(link.component.generationID)]) == link.component.generationID
            else {
                throw TractandaError("indexUnavailable", "The corpus reader lost its retention capability.")
            }
        }
        var window: IndexedCorpusUnitWindow?
        try reader.rows(
            "SELECT u.id,u.byte_start,u.byte_count,u.origin,substr(CAST(t.text AS BLOB),?,?) FROM corpus_unit u JOIN corpus_generation g ON g.id=u.generation_id AND g.state='ready' JOIN page_text_index t ON t.rowid=u.id WHERE u.generation_id=? AND u.ordinal=? AND g.source_key=? AND g.unit_count=? AND g.byte_count=?",
            [
                .integer(offset + 1), .integer(Int64(limit)), .text(link.component.generationID),
                .integer(ordinal - link.unitStart), .text(link.component.sourceKey),
                .integer(link.component.unitCount), .integer(link.component.byteCount),
            ]
        ) { row in
            let unitID = sqlite3_column_int64(row, 0)
            let start = sqlite3_column_int64(row, 1)
            let count = sqlite3_column_int64(row, 2)
            guard start >= 0, count >= 0, count <= 8 * 1024 * 1024, offset <= count else {
                throw TractandaError("indexError", "Corpus unit byte range is invalid.")
            }
            var data = reader.data(row, 4)
            guard Int64(data.count) == min(Int64(limit), count - offset) else {
                throw TractandaError("indexError", "Corpus unit window length changed.")
            }
            if let first = data.first, first & 0xC0 == 0x80 {
                throw TractandaError("invalidArguments", "The corpus offset is inside a UTF8 scalar.")
            }
            if String(data: data, encoding: .utf8) == nil {
                var valid = false
                for trim in 1...min(3, data.count) {
                    let candidate = data.dropLast(trim)
                    if !candidate.isEmpty, String(data: candidate, encoding: .utf8) != nil {
                        data = Data(candidate)
                        valid = true
                        break
                    }
                }
                guard valid else {
                    throw TractandaError(
                        "invalidArguments",
                        "The requested corpus window cannot contain a complete UTF8 scalar.")
                }
            }
            let origin = try IndexCorpusPlan.origin(
                JSON.decode(PageCorpusOrigin.self, Data(reader.text(row, 3).utf8)), overlay: link.overlay)
            var spans: [PageCorpusSpan] = []
            try reader.rows(
                "SELECT block_index,start,end,box FROM corpus_span WHERE unit_id=? ORDER BY block_index LIMIT 513",
                [.integer(unitID)]
            ) { span in
                let box: DoclingBoundingBox? =
                    sqlite3_column_type(span, 3) == SQLITE_NULL
                    ? nil : try JSON.decode(DoclingBoundingBox.self, Data(reader.text(span, 3).utf8))
                spans.append(
                    .init(
                        blockIndex: sqlite3_column_int64(span, 0),
                        unitByteStart: sqlite3_column_int64(span, 1),
                        unitByteEnd: sqlite3_column_int64(span, 2), box: box))
            }
            guard spans.count <= 512,
                spans.allSatisfy({
                    $0.unitByteStart >= 0 && $0.unitByteEnd >= $0.unitByteStart && $0.unitByteEnd <= count
                })
            else { throw TractandaError("indexError", "Corpus page spans exceed their exact bound.") }
            window = .init(
                identity: snapshot.identity, ordinal: ordinal,
                byteStart: try PageCorpusEmitter.add(link.byteStart, start), byteCount: count, offset: offset,
                nextOffset: try PageCorpusEmitter.add(offset, Int64(data.count)), data: data, origin: origin,
                spans: spans)
        }
        try boundary()
        guard try IndexCorpusFileFence.capture(snapshot.indexPath) == snapshot.fence, let window else {
            throw TractandaError("indexUnavailable", "The captured corpus unit is unavailable.")
        }
        return window
    }
}

extension ItemIndex {
    /// Lost replies can reload a completed unpublished capability. An unfinished import is
    /// derived work: its owning job fences/discards it, then reimports saved authenticated pages.
    static func loadStagedCorpus(
        indexPath: String, input: PageCorpusInput, workID: String, boundary: () throws -> Void = {}
    ) throws -> IndexedCorpusStage? {
        try PageCorpusInput.validateID(workID)
        try boundary()
        let fence = try IndexCorpusFileFence.capture(indexPath)
        let reader = try IndexCorpusSQL(path: indexPath, readOnly: true)
        guard let indexIdentity = try reader.scalar("SELECT id FROM corpus_index_identity") else {
            throw TractandaError("indexUnavailable", "Corpus index identity is unavailable.")
        }
        var source: PageCorpusBinding?
        try reader.rows("SELECT source FROM corpus_work WHERE id=? AND kind='stage'", [.text(workID)]) {
            source = try JSON.decode(PageCorpusBinding.self, Data(reader.text($0, 0).utf8))
        }
        guard let source else { return nil }
        guard source == input.binding else {
            throw TractandaError(
                "indexProjectionPending",
                "Retained corpus work has another publication base; fence/discard it before rebasing.")
        }
        let plans = try IndexCorpusPlan.components(input)
        var components: [IndexedCorpusComponent] = []
        for plan in plans {
            try boundary()
            var component: IndexedCorpusComponent?
            try reader.rows(
                "SELECT g.id,g.kind,g.unit_count,g.byte_count FROM corpus_work_generation w JOIN corpus_generation g ON g.id=w.generation_id WHERE w.work_id=? AND g.source_key=? AND g.state='ready'",
                [.text(workID), .text(plan.sourceKey)]
            ) { row in
                guard component == nil else {
                    throw TractandaError("indexError", "Retained corpus source key is ambiguous.")
                }
                component = try .init(
                    generationID: reader.text(row, 0), sourceKey: plan.sourceKey, kind: reader.text(row, 1),
                    unitCount: sqlite3_column_int64(row, 2), byteCount: sqlite3_column_int64(row, 3))
            }
            guard let component else {
                throw TractandaError(
                    "indexProjectionPending",
                    "Retained corpus import is incomplete; fence/discard then reimport saved pages.")
            }
            guard component.kind == plan.kind, component.unitCount >= 0, component.byteCount >= 0 else {
                throw TractandaError("indexError", "Retained corpus component identity is malformed.")
            }
            components.append(component)
        }
        guard try IndexCorpusFileFence.capture(indexPath) == fence else {
            throw TractandaError("indexUnavailable", "The retained corpus index was replaced.")
        }
        return .init(
            workID: workID, indexIdentity: indexIdentity, fence: fence, source: source,
            ordinaryFingerprint: try IndexCorpusPlan.ordinaryFingerprint(input.revision),
            components: components)
    }
}

extension ItemIndex {
    /// Exclusive rebuild streams authenticated saved pages on the already-owned fresh connection.
    /// Main owns the enclosing transaction, disk admission and cooperative rebuild boundaries.
    func installCorpusForRebuild(
        input: PageCorpusInput, provider: any PageCorpusPageProvider, boundary: () throws -> Void
    ) throws {
        let plans = try IndexCorpusPlan.components(input)
        var components: [String: IndexedCorpusComponent] = [:]
        var owners: [String: Int] = [:]
        var counters: [String: (Int64, Int64)] = [:]
        for (offset, plan) in plans.enumerated() where components[plan.sourceKey] == nil {
            try boundary()
            if let existing = try readyCorpusComponent(plan.sourceKey) {
                components[plan.sourceKey] = existing
                continue
            }
            let id = try UUID.makeVersion1().uuidString.lowercased()
            try execute(
                "INSERT INTO corpus_generation VALUES (?,?,?,'writing',0,0,NULL,0,0)",
                [id, plan.sourceKey, plan.kind])
            components[plan.sourceKey] = .init(
                generationID: id, sourceKey: plan.sourceKey, kind: plan.kind, unitCount: 0, byteCount: 0)
            owners[plan.sourceKey] = offset
            counters[plan.sourceKey] = (0, 0)
        }
        _ = try PageCorpusEmitter.emit(input, provider: provider, boundary: boundary) { unit in
            try boundary()
            guard
                let offset = plans.firstIndex(where: {
                    $0.kind == unit.origin.kind && $0.attachmentID == unit.origin.attachmentID
                })
            else { throw TractandaError("indexError", "The rebuild source unit has no current component.") }
            let plan = plans[offset]
            guard owners[plan.sourceKey] == offset else { return }
            let component = components[plan.sourceKey]!
            let counter = counters[plan.sourceKey]!
            try execute(
                "INSERT INTO corpus_unit(generation_id,ordinal,byte_start,byte_count,origin,encoded_bytes) VALUES (?,?,?,?,?,0)",
                [
                    component.generationID, String(counter.0), String(counter.1),
                    String(unit.text.utf8.count),
                    String(decoding: try JSON.encode(unit.origin), as: UTF8.self),
                ])
            var id: String?
            try corpusRows(
                "SELECT id FROM corpus_unit WHERE generation_id=? AND ordinal=?",
                [component.generationID, String(counter.0)]
            ) { id = try corpusText($0, 0) }
            guard let id else { throw TractandaError("indexError", "The rebuild corpus unit is absent.") }
            try execute("INSERT INTO page_text_index(rowid,text) VALUES (?,?)", [id, unit.text])
            guard unit.spans.count <= 512 else {
                throw TractandaError("indexError", "The rebuild page span window is invalid.")
            }
            for span in unit.spans {
                if let box = span.box {
                    try execute(
                        "INSERT INTO corpus_span VALUES (?,?,?,?,?)",
                        [
                            id, String(span.blockIndex), String(span.unitByteStart), String(span.unitByteEnd),
                            String(decoding: try JSON.encode(box), as: UTF8.self),
                        ])
                } else {
                    try execute(
                        "INSERT INTO corpus_span VALUES (?,?,?,?,NULL)",
                        [id, String(span.blockIndex), String(span.unitByteStart), String(span.unitByteEnd)])
                }
            }
            counters[plan.sourceKey] = (
                try PageCorpusEmitter.add(counter.0, 1),
                try PageCorpusEmitter.add(counter.1, Int64(unit.text.utf8.count))
            )
            try boundary()
        }
        for (key, counter) in counters {
            try boundary()
            try execute(
                "UPDATE corpus_generation SET state='ready',unit_count=?,byte_count=? WHERE id=?",
                [String(counter.0), String(counter.1), components[key]!.generationID])
        }
    }
}

extension ItemIndex {
    /// Compact trust check: current active sources/ordinary values, never document text restream.
    func corpusMatches(_ revision: Revision) throws -> Bool {
        let plans = try IndexCorpusPlan.current(revision)
        var actual: [String] = []
        var current = false
        try corpusRows("SELECT revision_id,layout FROM corpus_head WHERE item_id=?", [revision.itemID]) {
            current =
                try corpusText($0, 0) == revision.revisionID
                && corpusText($0, 1) == PageCorpusBinding.layoutName
        }
        guard current else { return false }
        try corpusRows(
            "SELECT g.source_key,l.overlay FROM corpus_link l JOIN corpus_generation g ON g.id=l.generation_id AND g.state='ready' WHERE l.item_id=? ORDER BY l.ordinal LIMIT 258",
            [revision.itemID]
        ) { row in
            guard actual.count < plans.count,
                try JSON.decode(IndexedCorpusOverlay.self, Data(corpusText(row, 1).utf8))
                    == plans[actual.count].overlay
            else {
                current = false
                return
            }
            actual.append(try corpusText(row, 0))
        }
        return current && actual == plans.map(\.sourceKey)
    }
}

/// Normative encoded accounting, NOT SQLite allocation or compression attribution.
private enum IndexCorpusEncoding {
    struct Work: Encodable {
        let workID: String
        let kind: String
        let source: String
    }
    struct Generation: Encodable {
        let id: String
        let sourceKey: String
        let kind: String
        let state: String
        let unitCount: Int64
        let byteCount: Int64
        let ownerWorkID: String
    }
    struct Unit: Encodable {
        let generationID: String
        let ordinal: Int64
        let byteStart: Int64
        let byteCount: Int64
        let origin: PageCorpusOrigin
        let spans: [PageCorpusSpan]
    }
    static func work(_ id: String, _ kind: String, _ source: String) throws -> Int64 {
        Int64(try JSON.encode(Work(workID: id, kind: kind, source: source)).count)
    }
    static func generation(
        _ id: String, _ key: String, _ kind: String, _ state: String, _ units: Int64, _ bytes: Int64,
        _ workID: String
    ) throws -> Int64 {
        Int64(
            try JSON.encode(
                Generation(
                    id: id, sourceKey: key, kind: kind, state: state, unitCount: units, byteCount: bytes,
                    ownerWorkID: workID)
            ).count)
    }
    static func unit(
        _ id: String, _ ordinal: Int64, _ start: Int64, _ text: String, _ origin: PageCorpusOrigin,
        _ spans: [PageCorpusSpan]
    ) throws -> Int64 {
        let metadata = try JSON.encode(
            Unit(
                generationID: id, ordinal: ordinal, byteStart: start, byteCount: Int64(text.utf8.count),
                origin: origin, spans: spans))
        return try PageCorpusEmitter.add(Int64(metadata.count), Int64(text.utf8.count))
    }
}

struct IndexedCorpusRetainedWork: Sendable {
    let workID: String
    let kind: String
    let retainedEncodedBytes: Int64
}

extension IndexCorpusSQL {
    func retainedEncodedBytes(_ workID: String) throws -> Int64 {
        var bytes: Int64 = 0
        try rows(
            "SELECT w.encoded_bytes+COALESCE((SELECT SUM(g.encoded_bytes) FROM corpus_generation g WHERE g.owner_work_id=w.id AND NOT EXISTS (SELECT 1 FROM corpus_link l WHERE l.generation_id=g.id)),0) FROM corpus_work w WHERE w.id=?",
            [.text(workID)]
        ) { row in
            guard sqlite3_column_type(row, 0) == SQLITE_INTEGER else {
                throw TractandaError("indexError", "Corpus encoded charge overflowed its integer domain.")
            }
            bytes = sqlite3_column_int64(row, 0)
            guard bytes >= 0 else {
                throw TractandaError("indexError", "Corpus encoded recovery charge overflowed.")
            }
        }
        return bytes
    }
}

extension ItemIndex {
    func corpusRetainedBytes(_ workID: String) throws -> Int64 {
        var bytes: Int64 = 0
        try corpusRows(
            "SELECT w.encoded_bytes+COALESCE((SELECT SUM(g.encoded_bytes) FROM corpus_generation g WHERE g.owner_work_id=w.id AND NOT EXISTS (SELECT 1 FROM corpus_link l WHERE l.generation_id=g.id)),0) FROM corpus_work w WHERE w.id=?",
            [workID]
        ) { row in
            guard sqlite3_column_type(row, 0) == SQLITE_INTEGER else {
                throw TractandaError("indexError", "Corpus encoded charge overflowed its integer domain.")
            }
            bytes = sqlite3_column_int64(row, 0)
            guard bytes >= 0 else {
                throw TractandaError("indexError", "Corpus encoded recovery charge overflowed.")
            }
        }
        return bytes
    }
    func retainedCorpusWorkPage(after: String? = nil, limit: Int = 64) throws -> [IndexedCorpusRetainedWork] {
        guard (1...64).contains(limit) else {
            throw TractandaError("invalidArguments", "Use a bounded retained corpus ledger page.")
        }
        var result: [IndexedCorpusRetainedWork] = []
        try corpusRows(
            "SELECT id,kind FROM corpus_work WHERE id>? ORDER BY id LIMIT ?", [after ?? "", String(limit)]
        ) { row in
            let id = try corpusText(row, 0)
            result.append(
                try .init(workID: id, kind: corpusText(row, 1), retainedEncodedBytes: corpusRetainedBytes(id))
            )
        }
        return result
    }

    /// Called under the existing writer transaction AFTER producer fence/promotion. Shared
    /// new bytes transfer to another retaining work token; unreferenced debt waits for real GC.
    private func retireCorpusWork(_ workID: String) throws {
        // A source has <=257 retained component references; concurrency may additionally
        // leave private duplicate generations owned/charged by the same work. Do not scan or
        // cap all owned debt at final CAS. Unreferenced duplicate debt stays for indexed GC.
        var referencedOwned: [String] = []
        var references = 0
        try corpusRows(
            "SELECT w.generation_id,g.owner_work_id FROM corpus_work_generation w JOIN corpus_generation g ON g.id=w.generation_id WHERE w.work_id=? ORDER BY w.generation_id LIMIT 258",
            [workID]
        ) { row in
            references += 1
            if sqlite3_column_type(row, 1) != SQLITE_NULL, try corpusText(row, 1) == workID {
                referencedOwned.append(try corpusText(row, 0))
            }
        }
        guard references <= 257 else {
            throw TractandaError("indexError", "Corpus work retains excess component references.")
        }
        try execute("DELETE FROM corpus_work_generation WHERE work_id=?", [workID])
        for generationID in referencedOwned {
            var active = false
            try corpusRows("SELECT 1 FROM corpus_link WHERE generation_id=? LIMIT 1", [generationID]) { _ in
                active = true
            }
            if active {
                try execute("UPDATE corpus_generation SET owner_work_id=NULL WHERE id=?", [generationID])
                try execute("DELETE FROM corpus_gc_candidate WHERE generation_id=?", [generationID])
                continue
            }
            var successor: String?
            try corpusRows(
                "SELECT work_id FROM corpus_work_generation WHERE generation_id=? ORDER BY work_id LIMIT 1",
                [generationID]
            ) { successor = try corpusText($0, 0) }
            if let successor {
                try execute(
                    "UPDATE corpus_generation SET owner_work_id=? WHERE id=?", [successor, generationID])
            }
            try execute("INSERT OR IGNORE INTO corpus_gc_candidate VALUES (?)", [generationID])
        }
        var remains = false
        try corpusRows("SELECT 1 FROM corpus_generation WHERE owner_work_id=? LIMIT 1", [workID]) { _ in
            remains = true
        }
        if remains {
            var source: String?
            try corpusRows("SELECT source FROM corpus_work WHERE id=?", [workID]) {
                source = try corpusText($0, 0)
            }
            guard let source else {
                throw TractandaError("indexError", "Retained corpus debt lost its work header.")
            }
            try execute(
                "UPDATE corpus_work SET kind='discard',encoded_bytes=? WHERE id=?",
                [String(try IndexCorpusEncoding.work(workID, "discard", source)), workID])
        } else {
            try execute("DELETE FROM corpus_work WHERE id=?", [workID])
        }
    }
}

struct IndexCorpusGCStats: Sendable {
    var candidateGenerations: Int = 0
    var unitsExamined: Int = 0
    var unitsDeleted: Int = 0
    var headersDeleted: Int = 0
}

extension ItemIndex {
    /// Normative encoded metadata; physical SQLite growth has its separate filesystem preflight.
    static func corpusReadLeaseCharge(_ id: String, identity: IndexedCorpusIdentity) throws -> Int64 {
        try PageCorpusInput.validateID(id)
        return try IndexCorpusEncoding.work(
            id, "read", String(decoding: JSON.encode(identity), as: UTF8.self))
    }
    func corpusReadWorkPage(after: String? = nil, limit: Int = 64) throws -> [String] {
        guard (1...64).contains(limit) else {
            throw TractandaError("invalidArguments", "Use a bounded read-lease cursor.")
        }
        var ids: [String] = []
        try corpusRows(
            "SELECT id FROM corpus_work WHERE kind='read' AND id>? ORDER BY id LIMIT ?",
            [after ?? "", String(limit)]
        ) { ids.append(try corpusText($0, 0)) }
        return ids
    }
    func validateCorpusReadLease(_ snapshot: IndexedCorpusSnapshot) throws {
        guard snapshot.indexPath == corpusIndexPath,
            try IndexCorpusFileFence.capture(corpusIndexPath) == snapshot.fence,
            let id = snapshot.retentionID
        else { throw TractandaError("indexUnavailable", "Reader retention/index identity changed.") }
        var valid = false
        try corpusRows(
            "SELECT 1 FROM corpus_work w,corpus_index_identity i WHERE w.id=? AND w.kind='read' AND w.source=? AND i.id=?",
            [id, String(decoding: try JSON.encode(snapshot.identity), as: UTF8.self), snapshot.indexIdentity]
        ) { _ in valid = true }
        guard valid else {
            throw TractandaError("indexUnavailable", "Reader lease was released or superseded.")
        }
    }
}
