import CSQLite
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ItemIndex {
    enum IndexedOrder {
        case modifiedAt
        case createdAt

        var column: String {
            switch self {
            case .modifiedAt: "modified"
            case .createdAt: "created"
            }
        }
    }
    struct CatalogueRow: Sendable, Equatable {
        let revisionID: String
        let itemID: String
        let path: String
        let parentID: String?
        let actor: String
        let operationID: String
        let size: UInt64
        let inode: UInt64
        let uid: UInt32
        let mode: UInt32
        let modificationSeconds: Int64
        let modificationNanoseconds: Int32
        let digest: Data
    }
    struct TextRow {
        let revisionID: String
        let subject: String
        let body: String
        let metadata: String
    }
    struct Page {
        let ids: [String]
        let total: Int
    }
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    final class RebuildStatements {
        fileprivate var items: OpaquePointer?
        fileprivate var text: OpaquePointer?
        fileprivate var view: OpaquePointer?
        fileprivate var removeView: OpaquePointer?

        fileprivate init(prepare: (String) throws -> OpaquePointer) throws {
            let sql = [
                "INSERT OR REPLACE INTO items VALUES (?, ?, ?, ?, ?, ?, ?)",
                "INSERT INTO text_index (id, subject, body, metadata) VALUES (?, ?, ?, ?)",
                "INSERT INTO saved_view_targets VALUES (?, ?, ?, ?, ?) "
                    + "ON CONFLICT(id) DO UPDATE SET selection=excluded.selection, "
                    + "class_filter=excluded.class_filter, dependencies=excluded.dependencies, "
                    + "state=excluded.state "
                    + "WHERE selection != excluded.selection OR dependencies != excluded.dependencies",
                "DELETE FROM saved_view_targets WHERE id = ?",
            ]
            var prepared: [OpaquePointer] = []
            do {
                for statement in sql { prepared.append(try prepare(statement)) }
            } catch {
                for statement in prepared { sqlite3_finalize(statement) }
                throw error
            }
            items = prepared[0]
            text = prepared[1]
            view = prepared[2]
            removeView = prepared[3]
        }

        deinit {
            close()
        }

        func close() {
            if let items { sqlite3_finalize(items) }
            if let text { sqlite3_finalize(text) }
            if let view { sqlite3_finalize(view) }
            if let removeView { sqlite3_finalize(removeView) }
            items = nil
            text = nil
            view = nil
            removeView = nil
        }
    }
    init(path: String, create: Bool) throws {
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else {
            if let database { sqlite3_close(database) }
            database = nil
            throw TractandaError("indexError", "Cannot open disposable SQLite index.")
        }
        sqlite3_busy_timeout(database, 3000)
        if create {
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute(
                """
                CREATE TABLE items (id TEXT PRIMARY KEY, revision TEXT NOT NULL,
                class TEXT NOT NULL, deleted INTEGER NOT NULL, modified REAL NOT NULL,
                created REAL NOT NULL,
                fields TEXT NOT NULL);
                """)
            try execute("CREATE INDEX item_class ON items(class)")
            try execute("CREATE INDEX item_order ON items(deleted, modified DESC, id)")
            try execute("CREATE INDEX item_class_order ON items(class, deleted, modified DESC, id)")
            try execute("CREATE INDEX item_created_order ON items(deleted, created DESC, id)")
            try execute("CREATE INDEX item_class_created_order ON items(class, deleted, created DESC, id)")
            try execute(
                "CREATE TABLE saved_view_targets (id TEXT PRIMARY KEY, selection TEXT NOT NULL, "
                    + "class_filter TEXT, dependencies TEXT NOT NULL, state TEXT NOT NULL)"
            )
            try execute(
                "CREATE TABLE category_include_candidates (category_id TEXT NOT NULL, "
                    + "target_id TEXT NOT NULL, source_id TEXT NOT NULL, "
                    + "PRIMARY KEY(source_id, category_id, target_id))"
            )
            try execute(
                "CREATE INDEX category_include_target ON category_include_candidates(category_id, target_id)"
            )
            try execute(
                "CREATE VIRTUAL TABLE text_index USING fts5(id UNINDEXED, subject, body, metadata, tokenize='unicode61')"
            )
            try execute("CREATE TABLE checkpoint_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute(
                "CREATE TABLE revision_catalog (revision TEXT PRIMARY KEY, item TEXT NOT NULL, path TEXT NOT NULL, parent TEXT, actor TEXT NOT NULL, operation TEXT NOT NULL, size INTEGER NOT NULL, inode INTEGER NOT NULL, uid INTEGER NOT NULL, mode INTEGER NOT NULL, mtime_seconds INTEGER NOT NULL, mtime_nanoseconds INTEGER NOT NULL, digest TEXT NOT NULL)"
            )
            try execute("CREATE INDEX revision_catalog_item ON revision_catalog(item, revision)")
            try execute(
                "CREATE TABLE operation_receipts (actor TEXT NOT NULL, operation TEXT NOT NULL, revision TEXT NOT NULL UNIQUE, item TEXT NOT NULL, PRIMARY KEY(actor, operation))"
            )
        }
    }
    deinit { if let database { sqlite3_close(database) } }
    func close() {
        if let database { sqlite3_close(database) }
        database = nil
    }
    private func prepare(_ sql: String, _ bindings: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        for (offset, value) in bindings.enumerated() {
            let result = value.withCString {
                sqlite3_bind_text(statement, Int32(offset + 1), $0, Int32(value.utf8.count), transient)
            }
            if result != SQLITE_OK {
                sqlite3_finalize(statement)
                throw error()
            }
        }
        return statement
    }
    private func error() -> TractandaError {
        TractandaError("indexError", database.map { String(cString: sqlite3_errmsg($0)) } ?? "Index closed.")
    }
    private func run(_ statement: OpaquePointer, _ bindings: [String]) throws {
        _ = sqlite3_reset(statement)
        _ = sqlite3_clear_bindings(statement)
        defer {
            _ = sqlite3_reset(statement)
            _ = sqlite3_clear_bindings(statement)
        }
        for (offset, value) in bindings.enumerated() {
            let result = value.withCString {
                sqlite3_bind_text(statement, Int32(offset + 1), $0, Int32(value.utf8.count), transient)
            }
            guard result == SQLITE_OK else { throw error() }
        }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw error() }
    }
    func makeRebuildStatements() throws -> RebuildStatements {
        guard database != nil else { throw error() }
        return try RebuildStatements { [weak self] sql in
            guard let self else { throw TractandaError("indexError", "Index closed.") }
            return try self.prepare(sql)
        }
    }

    /// Inserts a head into the known-empty temporary rebuild database. Its FTS row
    /// cannot exist yet, so this intentionally omits only the ordinary put's delete.
    func putForRebuild(_ revision: Revision, using statements: RebuildStatements) throws {
        let fields = String(decoding: try JSON.encode(revision.fields), as: UTF8.self)
        let corpus = ItemTextContent.corpus(for: revision)
        guard case .date(let timestamp) = revision.fields["modifiedAt"],
            let modified = Timestamp.parse(timestamp)?.timeIntervalSinceReferenceDate
        else { throw TractandaError("indexError", "Head has no valid modification time.") }
        guard case .date(let createdTimestamp) = revision.fields["createdAt"],
            let created = Timestamp.parse(createdTimestamp)?.timeIntervalSinceReferenceDate,
            created.isFinite
        else { throw TractandaError("indexError", "Head has no valid creation time.") }
        guard let items = statements.items, let text = statements.text,
            let view = statements.view, let removeView = statements.removeView
        else { throw TractandaError("indexError", "Rebuild statements are closed.") }
        try run(
            items,
            [
                revision.itemID, revision.revisionID, revision.classID, revision.isDeleted ? "1" : "0",
                String(modified), String(created), fields,
            ])
        try run(text, [revision.itemID, corpus.subject, corpus.body, corpus.metadata])
        if let target = try savedViewTarget(for: revision) {
            try run(
                view,
                [
                    revision.itemID, target.selection, target.classFilter,
                    target.dependencies, target.state,
                ])
        } else {
            try run(removeView, [revision.itemID])
        }
        try putCategoryIncludes(for: revision, deletingPreviousSourceRows: false)
    }

    private struct SavedViewTarget {
        let selection: String
        let classFilter: String
        let dependencies: String
        let state: String
    }

    private func savedViewTarget(for revision: Revision) throws -> SavedViewTarget? {
        guard !revision.isDeleted, let value = revision.fields["viewDefinition"],
            let definition = try? SavedViewDefinition(value)
        else { return nil }
        var selectionFields: [String: ItemValue] = [
            "categoryPath": .list(definition.categoryPath.map(ItemValue.text)),
            "excludedCategoryIDs": .list(definition.excludedCategoryIDs.map(ItemValue.text)),
            "sort": .list(definition.sort.map(\.value)),
        ]
        if let expression = definition.expression { selectionFields["expression"] = .text(expression) }
        if let text = definition.text { selectionFields["text"] = .text(text) }
        let selection = String(decoding: try JSON.encode(selectionFields), as: UTF8.self)
        let query = try definition.expression.map(SpotlightQuery.init)
        let classFilter = query?.indexClassEquals
        var dependencies = Set((query?.indexDependencies.fields ?? []).map { "field:" + $0 })
        if query?.indexDependencies.usesClock == true { dependencies.insert("time") }
        if definition.text != nil { dependencies.insert("text") }
        for id in definition.categoryPath + definition.excludedCategoryIDs
            + definition.presentation.sectionIDs
        { dependencies.insert("category:" + id) }
        for comparator in definition.sort {
            if let property = comparator.property { dependencies.insert("field:" + metadataKey(property)) }
            if let root = comparator.categoryRootID { dependencies.insert("category:" + root) }
        }
        let dependencyJSON = String(decoding: try JSON.encode(dependencies.sorted()), as: UTF8.self)
        let eligibleSort =
            definition.sort.isEmpty
            || (definition.sort.count == 1 && definition.sort[0].categoryRootID == nil
                && !definition.sort[0].isAscending
                && ["modifiedAt", "createdAt"].contains(
                    definition.sort[0].property.map(metadataKey) ?? ""))
        let eligible =
            definition.categoryPath.isEmpty && definition.excludedCategoryIDs.isEmpty
            && eligibleSort && (definition.expression == nil || classFilter != nil)
        return SavedViewTarget(
            selection: selection, classFilter: classFilter ?? "",
            dependencies: dependencyJSON, state: eligible ? "ready" : "fallback")
    }
    func execute(_ sql: String, _ bindings: [String] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw error() }
    }

    func replaceCatalogue<Rows: Sequence>(identity: String, rows: Rows) throws
    where Rows.Element == CatalogueRow {
        try execute("DELETE FROM revision_catalog")
        try execute("DELETE FROM operation_receipts")
        try execute("DELETE FROM checkpoint_meta")
        try execute("INSERT INTO checkpoint_meta VALUES ('identity', ?)", [identity])
        try execute("INSERT INTO checkpoint_meta VALUES ('schema', '3')")
        try execute("INSERT INTO checkpoint_meta VALUES ('engine', 'tractanda-sqlite-catalogue-v3')")
        for row in rows {
            let values = [
                row.revisionID, row.itemID, row.path, row.parentID ?? "", row.actor,
                row.operationID, String(row.size), String(row.inode),
                String(row.uid), String(row.mode), String(row.modificationSeconds),
                String(row.modificationNanoseconds), row.digest.map { String(format: "%02x", $0) }.joined(),
            ]
            try execute(
                "INSERT INTO revision_catalog VALUES (?, ?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                values)
            try execute(
                "INSERT INTO operation_receipts VALUES (?, ?, ?, ?)",
                [row.actor, row.operationID, row.revisionID, row.itemID])
        }
    }

    func catalogue(identity: String) throws -> [CatalogueRow]? {
        func exactString(_ statement: OpaquePointer?, _ column: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, column) else { return nil }
            return String(
                bytes: UnsafeBufferPointer(
                    start: bytes, count: Int(sqlite3_column_bytes(statement, column))),
                encoding: .utf8)
        }
        let integrity = try prepare("PRAGMA integrity_check")
        defer { sqlite3_finalize(integrity) }
        guard sqlite3_step(integrity) == SQLITE_ROW,
            exactString(integrity, 0) == "ok",
            sqlite3_step(integrity) == SQLITE_DONE
        else { return nil }
        let meta = try prepare("SELECT value FROM checkpoint_meta WHERE key = 'identity'")
        defer { sqlite3_finalize(meta) }
        guard sqlite3_step(meta) == SQLITE_ROW,
            exactString(meta, 0) == identity, sqlite3_step(meta) == SQLITE_DONE
        else { return nil }
        let schema = try prepare("SELECT value FROM checkpoint_meta WHERE key = 'schema'")
        defer { sqlite3_finalize(schema) }
        guard sqlite3_step(schema) == SQLITE_ROW,
            exactString(schema, 0) == "3", sqlite3_step(schema) == SQLITE_DONE
        else { return nil }
        let engine = try prepare("SELECT value FROM checkpoint_meta WHERE key = 'engine'")
        defer { sqlite3_finalize(engine) }
        guard sqlite3_step(engine) == SQLITE_ROW,
            exactString(engine, 0) == "tractanda-sqlite-catalogue-v3", sqlite3_step(engine) == SQLITE_DONE
        else { return nil }
        // A copied or partially replaced v3 catalogue can retain valid metadata while
        // its derived query table no longer matches the current engine contract.
        guard
            let itemSchema = try? prepare(
                "SELECT id,revision,class,deleted,modified,created,fields FROM items LIMIT 0")
        else { return nil }
        sqlite3_finalize(itemSchema)
        let statement = try prepare(
            "SELECT revision,item,path,parent,actor,operation,size,inode,uid,mode,mtime_seconds,mtime_nanoseconds,digest FROM revision_catalog ORDER BY revision"
        )
        defer { sqlite3_finalize(statement) }
        var rows: [CatalogueRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { return nil }
            func string(_ i: Int32) -> String? {
                exactString(statement, i)
            }
            guard let revision = string(0), let item = string(1), let path = string(2),
                let actor = string(4), let operation = string(5)
            else { return nil }
            let parent = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : string(3)
            let size = UInt64(sqlite3_column_int64(statement, 6))
            let inode = UInt64(sqlite3_column_int64(statement, 7))
            let uid = UInt32(sqlite3_column_int64(statement, 8))
            let mode = UInt32(sqlite3_column_int64(statement, 9))
            let mtimeSeconds = sqlite3_column_int64(statement, 10)
            let mtimeNanoseconds = Int32(sqlite3_column_int64(statement, 11))
            guard let digestHex = string(12), digestHex.count == 64 else { return nil }
            var digest = Data()
            var cursor = digestHex.startIndex
            for _ in 0..<32 {
                let end = digestHex.index(cursor, offsetBy: 2)
                guard let byte = UInt8(digestHex[cursor..<end], radix: 16) else { return nil }
                digest.append(byte)
                cursor = end
            }
            rows.append(
                CatalogueRow(
                    revisionID: revision, itemID: item, path: path, parentID: parent,
                    actor: actor, operationID: operation, size: size,
                    inode: inode, uid: uid, mode: mode,
                    modificationSeconds: mtimeSeconds,
                    modificationNanoseconds: mtimeNanoseconds, digest: digest))
        }
        let receipts = try prepare("SELECT COUNT(*) FROM operation_receipts")
        defer { sqlite3_finalize(receipts) }
        guard sqlite3_step(receipts) == SQLITE_ROW,
            sqlite3_column_int64(receipts, 0) == Int64(rows.count),
            sqlite3_step(receipts) == SQLITE_DONE
        else { return nil }
        let mismatches = try prepare(
            "SELECT COUNT(*) FROM revision_catalog r LEFT JOIN operation_receipts o "
                + "ON o.actor=r.actor AND o.operation=r.operation "
                + "WHERE o.revision IS NULL OR o.revision != r.revision OR o.item != r.item")
        defer { sqlite3_finalize(mismatches) }
        guard sqlite3_step(mismatches) == SQLITE_ROW, sqlite3_column_int64(mismatches, 0) == 0,
            sqlite3_step(mismatches) == SQLITE_DONE
        else { return nil }
        return rows
    }

    func upsertCatalogue(_ row: CatalogueRow) throws {
        try execute(
            "INSERT OR REPLACE INTO revision_catalog VALUES (?, ?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                row.revisionID, row.itemID, row.path, row.parentID ?? "", row.actor, row.operationID,
                String(row.size), String(row.inode), String(row.uid), String(row.mode),
                String(row.modificationSeconds), String(row.modificationNanoseconds),
                row.digest.map { String(format: "%02x", $0) }.joined(),
            ])
        try execute(
            "INSERT OR REPLACE INTO operation_receipts VALUES (?, ?, ?, ?)",
            [row.actor, row.operationID, row.revisionID, row.itemID])
    }

    func catalogueMatchesHeads(_ expected: [String: String]) throws -> Bool {
        let statement = try prepare("SELECT id,revision FROM items")
        defer { sqlite3_finalize(statement) }
        var actual: [String: String] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = sqlite3_column_text(statement, 0),
                let revision = sqlite3_column_text(statement, 1)
            else { return false }
            actual[String(cString: id)] = String(cString: revision)
        }
        return actual == expected
    }

    func textMatches(_ revision: Revision) throws -> Bool {
        guard let row = try textRow(id: revision.itemID) else { return false }
        let corpus = ItemTextContent.corpus(for: revision)
        return row.revisionID == revision.revisionID && row.subject == corpus.subject
            && row.body == corpus.body && row.metadata == corpus.metadata
    }

    func checkpoint(path: String) throws {
        try execute("PRAGMA wal_checkpoint(FULL)")
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw TractandaError("indexError", "Cannot open checkpoint database.") }
        defer {
            #if canImport(Darwin)
                _ = Darwin.close(descriptor)
            #else
                _ = Glibc.close(descriptor)
            #endif
        }
        guard fsync(descriptor) == 0 else {
            throw TractandaError("indexError", "Cannot synchronize checkpoint database.")
        }
    }
    func put(_ revision: Revision) throws {
        let fields = String(decoding: try JSON.encode(revision.fields), as: UTF8.self)
        let corpus = ItemTextContent.corpus(for: revision)
        guard case .date(let timestamp) = revision.fields["modifiedAt"],
            let modified = Timestamp.parse(timestamp)?.timeIntervalSinceReferenceDate
        else { throw TractandaError("indexError", "Head has no valid modification time.") }
        guard case .date(let createdTimestamp) = revision.fields["createdAt"],
            let created = Timestamp.parse(createdTimestamp)?.timeIntervalSinceReferenceDate,
            created.isFinite
        else { throw TractandaError("indexError", "Head has no valid creation time.") }
        try execute(
            "INSERT OR REPLACE INTO items VALUES (?, ?, ?, ?, ?, ?, ?)",
            [
                revision.itemID, revision.revisionID, revision.classID, revision.isDeleted ? "1" : "0",
                String(modified), String(created), fields,
            ])
        try execute("DELETE FROM text_index WHERE id = ?", [revision.itemID])
        try execute(
            "INSERT INTO text_index (id, subject, body, metadata) VALUES (?, ?, ?, ?)",
            [
                revision.itemID, corpus.subject, corpus.body, corpus.metadata,
            ])
        if let target = try savedViewTarget(for: revision) {
            try execute(
                "INSERT INTO saved_view_targets VALUES (?, ?, ?, ?, ?) "
                    + "ON CONFLICT(id) DO UPDATE SET selection=excluded.selection, "
                    + "class_filter=excluded.class_filter, dependencies=excluded.dependencies, "
                    + "state=excluded.state "
                    + "WHERE selection != excluded.selection OR dependencies != excluded.dependencies",
                [
                    revision.itemID, target.selection, target.classFilter,
                    target.dependencies, target.state,
                ])
        } else {
            try execute("DELETE FROM saved_view_targets WHERE id = ?", [revision.itemID])
        }
        try putCategoryIncludes(for: revision)
    }

    private func putCategoryIncludes(for revision: Revision, deletingPreviousSourceRows: Bool = true) throws {
        if deletingPreviousSourceRows {
            try execute("DELETE FROM category_include_candidates WHERE source_id = ?", [revision.itemID])
        }
        guard !revision.isDeleted else { return }
        for (categoryID, decision) in revision.fields["categoryOverrides"]?.map ?? [:]
        where decision.string == "include" {
            try execute(
                "INSERT OR IGNORE INTO category_include_candidates VALUES (?, ?, ?)",
                [categoryID, revision.itemID, revision.itemID])
        }
        if revision.classID == "PersonalStateItem",
            let targetID = revision.fields["target"]?.link?.itemID
        {
            for (categoryID, decision) in revision.fields["personalOverrides"]?.map ?? [:]
            where decision.string == "include" {
                try execute(
                    "INSERT OR IGNORE INTO category_include_candidates VALUES (?, ?, ?)",
                    [categoryID, targetID, revision.itemID])
            }
        }
    }

    func categoryIncludeCandidateIDs(categoryIDs: Set<String>) throws -> Set<String> {
        guard !categoryIDs.isEmpty else { return [] }
        var result = Set<String>()
        let orderedIDs = categoryIDs.sorted()
        for offset in stride(from: 0, to: orderedIDs.count, by: 400) {
            let batch = Array(orderedIDs[offset..<min(offset + 400, orderedIDs.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let statement = try prepare(
                "SELECT DISTINCT target_id FROM category_include_candidates "
                    + "WHERE category_id IN (\(placeholders))",
                batch)
            defer { sqlite3_finalize(statement) }
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                    throw error()
                }
                result.insert(String(cString: text))
            }
        }
        return result
    }

    private func itemSource(
        lexicalText: String?, classEquals: String?,
        candidateRestrictions: [SpotlightQuery.IndexCandidateRestriction]
    ) -> (sql: String, arguments: [String]) {
        var joins = ""
        var predicates = ["items.deleted = 0"]
        var arguments: [String] = []
        if let lexicalText {
            joins = " JOIN text_index ON text_index.id = items.id"
            predicates.append("text_index MATCH ?")
            arguments.append("\"" + lexicalText.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
        }
        if let classEquals {
            predicates.append("items.class = ?")
            arguments.append(classEquals)
        }
        for restriction in candidateRestrictions {
            switch restriction.field {
            case "itemID":
                guard restriction.operation == "=" else { continue }
                predicates.append("items.id = ?")
                arguments.append(restriction.value)
            case "createdAt":
                guard ["=", "<", "<=", ">", ">="].contains(restriction.operation) else { continue }
                predicates.append("items.created \(restriction.operation) ?")
                arguments.append(restriction.value)
            case "modifiedAt":
                guard ["=", "<", "<=", ">", ">="].contains(restriction.operation) else { continue }
                predicates.append("items.modified \(restriction.operation) ?")
                arguments.append(restriction.value)
            default: continue
            }
        }
        return (" FROM items" + joins + " WHERE " + predicates.joined(separator: " AND "), arguments)
    }

    /// Returns nil as soon as the caller would admit one more than the bounded number
    /// of readable rows. It deliberately has no SQL LIMIT because authorization can
    /// reject any number of earlier index rows.
    func boundedCandidateIDs(
        restrictions: [SpotlightQuery.IndexCandidateRestriction], maximumReadable: Int,
        accepts: (String) throws -> Bool
    ) throws -> [String]? {
        precondition(maximumReadable >= 0)
        let source = itemSource(lexicalText: nil, classEquals: nil, candidateRestrictions: restrictions)
        let statement = try prepare("SELECT items.id" + source.sql, source.arguments)
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return ids }
            guard status == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else { throw error() }
            let id = String(cString: pointer)
            guard try accepts(id) else { continue }
            guard ids.count < maximumReadable else { return nil }
            ids.append(id)
        }
    }

    /// Streams ordered IDs so neither a page nor an exact authorized total needs a full
    /// in-memory result array. The caller checks current access before offset and count.
    func orderedPage(
        lexicalText: String?, classEquals: String?, order: IndexedOrder, position: Int, limit: Int,
        fastCount: Bool, candidateRestrictions: [SpotlightQuery.IndexCandidateRestriction] = [],
        accepts: (String) throws -> Bool
    ) throws -> Page {
        let itemSource = itemSource(
            lexicalText: lexicalText, classEquals: classEquals,
            candidateRestrictions: candidateRestrictions)
        let source = itemSource.sql
        let arguments = itemSource.arguments
        if fastCount {
            let counter = try prepare("SELECT COUNT(*)" + source, arguments)
            defer { sqlite3_finalize(counter) }
            guard sqlite3_step(counter) == SQLITE_ROW else { throw error() }
            let total = Int(sqlite3_column_int64(counter, 0))
            guard sqlite3_step(counter) == SQLITE_DONE else { throw error() }
            let statement = try prepare(
                "SELECT items.id" + source
                    + " ORDER BY items.\(order.column) DESC, items.id LIMIT ? OFFSET ?",
                arguments + [String(limit), String(position)])
            defer { sqlite3_finalize(statement) }
            var ids: [String] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return Page(ids: ids, total: total) }
                guard status == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else {
                    throw error()
                }
                let id = String(cString: pointer)
                guard try accepts(id) else {
                    throw TractandaError(
                        "indexError", "Indexed authorization assumptions changed during a request.")
                }
                ids.append(id)
            }
        }
        let statement = try prepare(
            "SELECT items.id" + source + " ORDER BY items.\(order.column) DESC, items.id", arguments)
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        var total = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return Page(ids: ids, total: total) }
            guard status == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else { throw error() }
            let id = String(cString: pointer)
            if try accepts(id) {
                if total >= position && ids.count < limit { ids.append(id) }
                total += 1
            }
        }
    }
    func savedViewIsReady(id: String) throws -> Bool {
        let statement = try prepare("SELECT state FROM saved_view_targets WHERE id = ?", [id])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return false }
        guard status == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else { throw error() }
        return String(cString: pointer) == "ready"
    }
    func ids(lexicalText: String? = nil, restrictingTo restrictedIDs: Set<String>? = nil) throws -> [String] {
        if let restrictedIDs, restrictedIDs.isEmpty { return [] }
        if lexicalText == nil, let restrictedIDs { return restrictedIDs.sorted() }
        if let lexicalText, let restrictedIDs {
            let phrase = "\"" + lexicalText.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            var result = Set<String>()
            let orderedIDs = restrictedIDs.sorted()
            for offset in stride(from: 0, to: orderedIDs.count, by: 400) {
                let batch = Array(orderedIDs[offset..<min(offset + 400, orderedIDs.count)])
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let statement = try prepare(
                    "SELECT id FROM text_index WHERE text_index MATCH ? AND id IN (\(placeholders)) "
                        + "ORDER BY rank, id",
                    [phrase] + batch)
                defer { sqlite3_finalize(statement) }
                while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                        throw error()
                    }
                    result.insert(String(cString: text))
                }
            }
            return result.sorted()
        }
        let sql: String
        let args: [String]
        if let lexicalText {
            // A literal phrase, not arbitrary executable SQL or an accidental FTS expression.
            let phrase = "\"" + lexicalText.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sql = "SELECT id FROM text_index WHERE text_index MATCH ? ORDER BY rank, id"
            args = [phrase]
        } else {
            sql = "SELECT id FROM items ORDER BY id"
            args = []
        }
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw error() }
            result.append(String(cString: text))
        }
    }
    func textRow(id: String) throws -> TextRow? {
        let statement = try prepare(
            "SELECT items.revision, text_index.id, text_index.subject, text_index.body, text_index.metadata FROM items LEFT JOIN text_index ON items.id = text_index.id WHERE items.id = ?",
            [id])
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw error() }
        if sqlite3_column_type(statement, 1) == SQLITE_NULL { return nil }
        func value(_ column: Int32) throws -> String {
            guard let pointer = sqlite3_column_text(statement, column),
                let text = String(
                    bytes: UnsafeBufferPointer(
                        start: pointer, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
            else { throw TractandaError("indexError", "Invalid indexed text.") }
            return text
        }
        let result = try TextRow(revisionID: value(0), subject: value(2), body: value(3), metadata: value(4))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TractandaError("indexError", "Ambiguous indexed text.")
        }
        return result
    }
}
