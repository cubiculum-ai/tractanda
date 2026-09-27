import CSQLite
import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ItemIndex {
    static let headSummaryFieldNames: Set<String> = [
        "permissions", "selection", "categoryParents", "categoryOrder", "subject", "target",
        "categoryOverrides", "personalOverrides", "viewDefinition", "accessConfiguration",
        "createdAt", "modifiedAt",
        "categoryOrder", "subject",
    ]
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
        let createdAt: String
        let feedbackRevisionIDs: [String]

        init(
            revisionID: String, itemID: String, path: String, parentID: String?, actor: String,
            operationID: String, size: UInt64, inode: UInt64, uid: UInt32, mode: UInt32,
            modificationSeconds: Int64, modificationNanoseconds: Int32, digest: Data,
            createdAt: String = "", feedbackRevisionIDs: [String] = []
        ) {
            self.revisionID = revisionID
            self.itemID = itemID
            self.path = path
            self.parentID = parentID
            self.actor = actor
            self.operationID = operationID
            self.size = size
            self.inode = inode
            self.uid = uid
            self.mode = mode
            self.modificationSeconds = modificationSeconds
            self.modificationNanoseconds = modificationNanoseconds
            self.digest = digest
            self.createdAt = createdAt
            self.feedbackRevisionIDs = feedbackRevisionIDs
        }
    }
    struct ValidatedCatalogue: Sendable { fileprivate let identity: String }
    struct TextRow {
        let revisionID: String
        let subject: String
        let body: String
        let metadata: String
    }
    struct Page: Sendable {
        let ids: [String]
        let total: Int
    }
    struct SeekPage: Sendable {
        let ids: [String]
        let total: Int
    }
    private var database: OpaquePointer?
    var onPersistentFailure: (() -> Void)?
    static func shouldQuarantineSQLiteFailure(_ code: Int32) -> Bool {
        ![SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT, SQLITE_NOMEM, SQLITE_TOOBIG, SQLITE_FULL]
            .contains(code)
    }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var seekVMInstructionsForTesting = 0
    private(set) var principalLookupVMInstructionsForTesting = 0
    private(set) var savedViewCategoryPlanLookupsForTesting = 0
    final class RebuildStatements {
        fileprivate var items: OpaquePointer?
        fileprivate var text: OpaquePointer?
        fileprivate var view: OpaquePointer?
        fileprivate var removeView: OpaquePointer?
        fileprivate var presence: OpaquePointer?
        fileprivate var scalar: OpaquePointer?
        fileprivate var acl: OpaquePointer?
        fileprivate var aclNamed: OpaquePointer?

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
                "INSERT OR IGNORE INTO field_presence VALUES (?, ?)",
                "INSERT INTO scalar_value VALUES (?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''))",
                "INSERT INTO acl_core VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                "INSERT INTO acl_named VALUES (?, ?, ?, ?)",
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
            presence = prepared[4]
            scalar = prepared[5]
            acl = prepared[6]
            aclNamed = prepared[7]
        }

        deinit {
            close()
        }

        func close() {
            if let items { sqlite3_finalize(items) }
            if let text { sqlite3_finalize(text) }
            if let view { sqlite3_finalize(view) }
            if let removeView { sqlite3_finalize(removeView) }
            if let presence { sqlite3_finalize(presence) }
            if let scalar { sqlite3_finalize(scalar) }
            if let acl { sqlite3_finalize(acl) }
            if let aclNamed { sqlite3_finalize(aclNamed) }
            items = nil
            text = nil
            view = nil
            removeView = nil
            presence = nil
            scalar = nil
            acl = nil
            aclNamed = nil
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
        if path != ":memory:" {
            do {
                try configureWriter()
            } catch {
                sqlite3_close_v2(database)
                self.database = nil
                throw error
            }
        }
        if create {
            try execute(
                """
                CREATE TABLE items (id TEXT PRIMARY KEY, revision TEXT NOT NULL,
                class TEXT NOT NULL, deleted INTEGER NOT NULL, modified REAL NOT NULL,
                created REAL NOT NULL,
                fields TEXT NOT NULL);
                """)
            try execute(
                "CREATE TABLE head_summaries (item_id TEXT PRIMARY KEY, revision TEXT NOT NULL, class TEXT NOT NULL, deleted INTEGER NOT NULL, fields TEXT NOT NULL, clock_dependent INTEGER NOT NULL, category INTEGER NOT NULL)"
            )
            try execute(
                "CREATE TABLE field_presence (item_id TEXT NOT NULL, field TEXT NOT NULL, PRIMARY KEY(item_id, field))"
            )
            try execute("CREATE INDEX field_presence_lookup ON field_presence(field, item_id)")
            try execute(
                "CREATE TABLE scalar_value (item_id TEXT NOT NULL, field TEXT NOT NULL, member_ordinal INTEGER NOT NULL, type TEXT NOT NULL, int_value INTEGER, real_value REAL, date_value REAL, bool_value INTEGER)"
            )
            try execute("CREATE INDEX scalar_int_lookup ON scalar_value(field, type, int_value, item_id)")
            try execute("CREATE INDEX scalar_real_lookup ON scalar_value(field, type, real_value, item_id)")
            try execute("CREATE INDEX scalar_date_lookup ON scalar_value(field, type, date_value, item_id)")
            try execute("CREATE INDEX scalar_bool_lookup ON scalar_value(field, type, bool_value, item_id)")
            try execute(
                "CREATE TABLE acl_core (item_id TEXT PRIMARY KEY, owner TEXT NOT NULL, group_name TEXT NOT NULL, mode INTEGER NOT NULL, mask INTEGER NOT NULL, owning_rights INTEGER NOT NULL, other_rights INTEGER NOT NULL, extended INTEGER NOT NULL)"
            )
            try execute("CREATE INDEX acl_owner_lookup ON acl_core(owner,item_id)")
            try execute("CREATE INDEX acl_group_lookup ON acl_core(group_name,item_id)")
            try execute("CREATE INDEX acl_other_lookup ON acl_core(other_rights,item_id)")
            try execute(
                "CREATE TABLE acl_named (item_id TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL, rights INTEGER NOT NULL, PRIMARY KEY(item_id,kind,name))"
            )
            try execute("CREATE INDEX acl_named_lookup ON acl_named(kind,name,item_id)")
            try execute(
                "CREATE TABLE acl_principal_counts (kind TEXT NOT NULL, name TEXT NOT NULL, refcount INTEGER NOT NULL, PRIMARY KEY(kind,name))"
            )
            try execute("CREATE INDEX acl_principal_name ON acl_principal_counts(kind,name,refcount)")
            try execute(
                "CREATE TRIGGER acl_core_principal_insert AFTER INSERT ON acl_core BEGIN INSERT INTO acl_principal_counts VALUES ('user',NEW.owner,1) ON CONFLICT(kind,name) DO UPDATE SET refcount=refcount+1; INSERT INTO acl_principal_counts VALUES ('group',NEW.group_name,1) ON CONFLICT(kind,name) DO UPDATE SET refcount=refcount+1; END"
            )
            try execute(
                "CREATE TRIGGER acl_core_principal_delete AFTER DELETE ON acl_core BEGIN UPDATE acl_principal_counts SET refcount=refcount-1 WHERE kind='user' AND name=OLD.owner; DELETE FROM acl_principal_counts WHERE kind='user' AND name=OLD.owner AND refcount=0; UPDATE acl_principal_counts SET refcount=refcount-1 WHERE kind='group' AND name=OLD.group_name; DELETE FROM acl_principal_counts WHERE kind='group' AND name=OLD.group_name AND refcount=0; END"
            )
            try execute(
                "CREATE TRIGGER acl_named_principal_insert AFTER INSERT ON acl_named BEGIN INSERT INTO acl_principal_counts VALUES (NEW.kind,NEW.name,1) ON CONFLICT(kind,name) DO UPDATE SET refcount=refcount+1; END"
            )
            try execute(
                "CREATE TRIGGER acl_named_principal_delete AFTER DELETE ON acl_named BEGIN UPDATE acl_principal_counts SET refcount=refcount-1 WHERE kind=OLD.kind AND name=OLD.name; DELETE FROM acl_principal_counts WHERE kind=OLD.kind AND name=OLD.name AND refcount=0; END"
            )
            try execute("CREATE INDEX item_class ON items(class)")
            try execute("CREATE INDEX item_order ON items(deleted, modified DESC, id)")
            try execute("CREATE INDEX item_class_order ON items(class, deleted, modified DESC, id)")
            try execute("CREATE INDEX item_created_order ON items(deleted, created DESC, id)")
            try execute("CREATE INDEX item_class_created_order ON items(class, deleted, created DESC, id)")
            try execute(
                "CREATE TABLE saved_view_targets (id TEXT PRIMARY KEY, selection TEXT NOT NULL, "
                    + "class_filter TEXT, dependencies TEXT NOT NULL, state TEXT NOT NULL)"
            )
            // Durable positive membership for a small, explicitly supported subset of
            // saved views. These rows are disposable index data; callers still evaluate
            // the saved predicate and current ACL before counting or paging.
            try execute(
                "CREATE TABLE saved_view_base (view_id TEXT NOT NULL, item_id TEXT NOT NULL, "
                    + "modified REAL NOT NULL, created REAL NOT NULL, PRIMARY KEY(view_id,item_id))"
            )
            try execute(
                "CREATE INDEX saved_view_base_modified ON saved_view_base(view_id,modified DESC,item_id)"
            )
            try execute(
                "CREATE INDEX saved_view_base_created ON saved_view_base(view_id,created DESC,item_id)"
            )
            try execute("CREATE INDEX saved_view_base_item ON saved_view_base(item_id,view_id)")
            try execute(
                "CREATE TABLE saved_view_dependencies (view_id TEXT NOT NULL, kind TEXT NOT NULL, "
                    + "key TEXT NOT NULL, PRIMARY KEY(view_id,kind,key))"
            )
            try execute(
                "CREATE INDEX saved_view_dependency_reverse ON saved_view_dependencies(kind,key,view_id)"
            )
            try execute(
                "CREATE TABLE saved_view_coverage (view_id TEXT PRIMARY KEY, "
                    + "definition_revision TEXT NOT NULL, definition_hash TEXT NOT NULL, "
                    + "dependency_epoch INTEGER NOT NULL, applied_through TEXT NOT NULL, "
                    + "state TEXT NOT NULL)"
            )
            try execute(
                "CREATE TABLE saved_view_staging (view_id TEXT NOT NULL, item_id TEXT NOT NULL, "
                    + "modified REAL NOT NULL, created REAL NOT NULL, PRIMARY KEY(view_id,item_id))"
            )
            try execute("CREATE INDEX saved_view_staging_item ON saved_view_staging(item_id,view_id)")
            try execute(
                "CREATE TABLE saved_view_build_state (view_id TEXT PRIMARY KEY, "
                    + "definition_hash TEXT NOT NULL, dependency_epoch INTEGER NOT NULL, "
                    + "cursor TEXT NOT NULL, candidate_count INTEGER NOT NULL)"
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
                "CREATE TABLE category_decision_candidates (category_id TEXT NOT NULL, target_id TEXT NOT NULL, source_id TEXT NOT NULL, PRIMARY KEY(source_id,category_id,target_id))"
            )
            try execute(
                "CREATE INDEX category_decision_target ON category_decision_candidates(category_id,target_id)"
            )
            try execute(
                "CREATE TABLE category_edges (source_id TEXT NOT NULL, target_id TEXT NOT NULL, kind TEXT NOT NULL, PRIMARY KEY(source_id,target_id,kind))"
            )
            try execute("CREATE INDEX category_edges_target ON category_edges(target_id,kind,source_id)")
            try execute(
                "CREATE TABLE personal_category_delta (owner_name TEXT NOT NULL, target_id TEXT NOT NULL, category_id TEXT NOT NULL, decision TEXT NOT NULL, source_id TEXT NOT NULL, PRIMARY KEY(source_id,category_id))"
            )
            try execute(
                "CREATE INDEX personal_delta_lookup ON personal_category_delta(category_id,target_id,owner_name)"
            )
            try execute(
                "CREATE TABLE personal_overlay_targets (owner_name TEXT NOT NULL, target_id TEXT NOT NULL, source_id TEXT PRIMARY KEY)"
            )
            try execute(
                "CREATE INDEX personal_overlay_target_lookup ON personal_overlay_targets(target_id,owner_name)"
            )
            try execute("CREATE INDEX personal_overlay_owner_lookup ON personal_overlay_targets(owner_name)")
            try execute(
                "CREATE VIRTUAL TABLE text_index USING fts5(id UNINDEXED, subject, body, metadata, tokenize='unicode61')"
            )
            try execute("CREATE TABLE checkpoint_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute(
                "CREATE TABLE revision_catalog (revision TEXT PRIMARY KEY, item TEXT NOT NULL, path TEXT NOT NULL, parent TEXT, actor TEXT NOT NULL, operation TEXT NOT NULL, size INTEGER NOT NULL, inode INTEGER NOT NULL, uid INTEGER NOT NULL, mode INTEGER NOT NULL, mtime_seconds INTEGER NOT NULL, mtime_nanoseconds INTEGER NOT NULL, digest TEXT NOT NULL, created_at TEXT NOT NULL)"
            )
            try execute("CREATE INDEX revision_catalog_item ON revision_catalog(item, revision)")
            try execute(
                "CREATE UNIQUE INDEX revision_catalog_operation ON revision_catalog(actor, operation)")
            try execute("CREATE UNIQUE INDEX revision_catalog_path ON revision_catalog(path)")
            try execute(
                "CREATE UNIQUE INDEX revision_catalog_parent ON revision_catalog(item,parent) WHERE parent IS NOT NULL"
            )
            try execute(
                "CREATE TABLE operation_receipts (actor TEXT NOT NULL, operation TEXT NOT NULL, revision TEXT NOT NULL UNIQUE, item TEXT NOT NULL, PRIMARY KEY(actor, operation))"
            )
            try execute(
                "CREATE INDEX operation_receipts_name ON operation_receipts(operation, actor, revision)")
            try execute(
                "CREATE TABLE feedback_refs (item TEXT NOT NULL, revision TEXT NOT NULL, target TEXT NOT NULL)"
            )
            try execute("CREATE INDEX feedback_refs_revision ON feedback_refs(revision, target)")
            try execute(
                "CREATE TABLE recovery_ordinals (item TEXT NOT NULL, revision TEXT PRIMARY KEY, ordinal INTEGER NOT NULL, UNIQUE(item, ordinal))"
            )
            try execute("CREATE TABLE recovery_heads (item TEXT PRIMARY KEY, revision TEXT NOT NULL UNIQUE)")
        }
        // Request-local authorization state belongs to each connection, including
        // reopened read-only connections; TEMP writes do not mutate the main catalogue.
        try execute("CREATE TEMP TABLE request_users (name TEXT PRIMARY KEY, uid INTEGER NOT NULL)")
        try execute(
            "CREATE TEMP TABLE request_groups (name TEXT PRIMARY KEY, gid INTEGER NOT NULL, member INTEGER NOT NULL)"
        )
        try execute("CREATE TEMP TABLE request_actor (uid INTEGER NOT NULL)")
    }
    deinit { if let database { sqlite3_close_v2(database) } }
    func close() {
        try? closeChecked()
    }
    func closeChecked() throws {
        guard let database else { return }
        let status = sqlite3_close(database)
        guard status == SQLITE_OK else { throw error() }
        self.database = nil
    }
    private func configureWriter() throws {
        guard let database else { throw TractandaError("indexError", "Index closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA journal_mode=WAL", -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw error() }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let mode = sqlite3_column_text(statement, 0), String(cString: mode).lowercased() == "wal"
        else {
            sqlite3_finalize(statement)
            throw TractandaError("indexError", "SQLite did not enable WAL mode.")
        }
        sqlite3_finalize(statement)
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA wal_autocheckpoint=1000")
        var syncStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA synchronous", -1, &syncStatement, nil) == SQLITE_OK,
            let syncStatement
        else { throw error() }
        guard sqlite3_step(syncStatement) == SQLITE_ROW,
            sqlite3_column_int(syncStatement, 0) == 2
        else {
            sqlite3_finalize(syncStatement)
            throw TractandaError("indexError", "SQLite synchronous mode is not FULL.")
        }
        sqlite3_finalize(syncStatement)
    }
    func synchronousModeForTesting() throws -> Int32 {
        guard let database else { throw TractandaError("indexError", "Index closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA synchronous", -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw error() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return sqlite3_column_int(statement, 0)
    }
    func holdStatementForTesting() throws -> OpaquePointer {
        try prepare("SELECT 1")
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
        let code = database.map { sqlite3_errcode($0) } ?? SQLITE_MISUSE
        if Self.shouldQuarantineSQLiteFailure(code) { onPersistentFailure?() }
        let errorCode: String
        if [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT].contains(code) {
            errorCode = "indexTransient"
        } else if [SQLITE_NOMEM, SQLITE_TOOBIG, SQLITE_FULL].contains(code) {
            errorCode = "indexResource"
        } else {
            errorCode = "indexError"
        }
        return TractandaError(
            errorCode, database.map { String(cString: sqlite3_errmsg($0)) } ?? "Index closed.")
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
        try putHeadSummary(revision)
        try run(text, [revision.itemID, corpus.subject, corpus.body, corpus.metadata])
        if let target = try savedViewTarget(for: revision) {
            try run(
                view,
                [
                    revision.itemID, target.selection, target.classFilter,
                    target.dependencies, target.state,
                ])
            try replaceSavedViewDependencies(id: revision.itemID, dependencies: target.dependencies)
            try registerSavedViewCoverage(
                id: revision.itemID, revisionID: revision.revisionID, target: target)
        } else {
            try run(removeView, [revision.itemID])
            try execute("DELETE FROM saved_view_base WHERE view_id = ?", [revision.itemID])
            try execute("DELETE FROM saved_view_dependencies WHERE view_id = ?", [revision.itemID])
            try execute("DELETE FROM saved_view_coverage WHERE view_id = ?", [revision.itemID])
            try execute("DELETE FROM saved_view_staging WHERE view_id = ?", [revision.itemID])
            try execute("DELETE FROM saved_view_build_state WHERE view_id = ?", [revision.itemID])
        }
        try putCategoryIncludes(for: revision, deletingPreviousSourceRows: false)
        try putScalars(
            for: revision, presenceStatement: statements.presence, scalarStatement: statements.scalar)
        try putACL(for: revision, coreStatement: statements.acl, namedStatement: statements.aclNamed)
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
        if definition.expression == nil && !definition.categoryPath.isEmpty {
            selectionFields["positiveCategorySeed"] = .boolean(true)
        }
        if let text = definition.text { selectionFields["text"] = .text(text) }
        let selection = String(decoding: try JSON.encode(selectionFields), as: UTF8.self)
        let query = try definition.expression.map(SpotlightQuery.init)
        let classFilter = query?.indexClassEquals
        var dependencies = Set((query?.indexDependencies.fields ?? []).map { "field:" + $0 })
        if definition.expression != nil {
            dependencies.insert("field:isDeleted")
            dependencies.insert("field:classID")
        }
        if query?.indexDependencies.usesClock == true { dependencies.insert("time") }
        if definition.sort.isEmpty { dependencies.insert("sort:modifiedAt") }
        if definition.text != nil { dependencies.insert("text") }
        for id in definition.categoryPath + definition.excludedCategoryIDs
            + definition.presentation.sectionIDs
        {
            dependencies.insert("category:" + id)
            if definition.categoryPath.contains(id) { dependencies.insert("categoryRule:" + id) }
        }
        for comparator in definition.sort {
            if let property = comparator.property { dependencies.insert("sort:" + metadataKey(property)) }
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
            definition.excludedCategoryIDs.isEmpty
            && eligibleSort
            && (definition.expression == nil || query?.indexExactClassEquals != nil
                || query?.supportsPersistentSavedViewMaterialization == true)
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
        try execute("DELETE FROM feedback_refs")
        try execute("DELETE FROM recovery_ordinals")
        try execute("DELETE FROM recovery_heads")
        try execute("DELETE FROM checkpoint_meta")
        try execute("INSERT INTO checkpoint_meta VALUES ('identity', ?)", [identity])
        try execute("INSERT INTO checkpoint_meta VALUES ('schema', '11')")
        try execute("INSERT INTO checkpoint_meta VALUES ('engine', 'tractanda-sqlite-catalogue-v11')")
        for row in rows {
            let values = [
                row.revisionID, row.itemID, row.path, row.parentID ?? "", row.actor,
                row.operationID, String(row.size), String(row.inode),
                String(row.uid), String(row.mode), String(row.modificationSeconds),
                String(row.modificationNanoseconds), row.digest.map { String(format: "%02x", $0) }.joined(),
                row.createdAt,
            ]
            try execute(
                "INSERT INTO revision_catalog VALUES (?, ?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                values)
            try execute(
                "INSERT INTO operation_receipts VALUES (?, ?, ?, ?)",
                [row.actor, row.operationID, row.revisionID, row.itemID])
            try insertFeedback(row)
        }
    }

    func catalogue(identity: String) throws -> [CatalogueRow]? {
        guard try validatedCatalogue(identity: identity) != nil else { return nil }
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
        let invalidReceipt = try prepare(
            "SELECT 1 FROM revision_catalog r LEFT JOIN operation_receipts o ON o.actor=r.actor AND o.operation=r.operation WHERE o.revision IS NULL OR o.revision!=r.revision OR o.item!=r.item LIMIT 1"
        )
        defer { sqlite3_finalize(invalidReceipt) }
        guard sqlite3_step(invalidReceipt) == SQLITE_DONE else { return nil }
        let receiptCounts = try prepare(
            "SELECT (SELECT COUNT(*) FROM revision_catalog),(SELECT COUNT(*) FROM operation_receipts)")
        defer { sqlite3_finalize(receiptCounts) }
        guard sqlite3_step(receiptCounts) == SQLITE_ROW,
            sqlite3_column_int64(receiptCounts, 0) == sqlite3_column_int64(receiptCounts, 1),
            sqlite3_step(receiptCounts) == SQLITE_DONE
        else { return nil }
        let meta = try prepare("SELECT value FROM checkpoint_meta WHERE key = 'identity'")
        defer { sqlite3_finalize(meta) }
        guard sqlite3_step(meta) == SQLITE_ROW,
            exactString(meta, 0) == identity, sqlite3_step(meta) == SQLITE_DONE
        else { return nil }
        let schema = try prepare("SELECT value FROM checkpoint_meta WHERE key = 'schema'")
        defer { sqlite3_finalize(schema) }
        guard sqlite3_step(schema) == SQLITE_ROW,
            exactString(schema, 0) == "11", sqlite3_step(schema) == SQLITE_DONE
        else { return nil }
        let engine = try prepare("SELECT value FROM checkpoint_meta WHERE key = 'engine'")
        defer { sqlite3_finalize(engine) }
        guard sqlite3_step(engine) == SQLITE_ROW,
            exactString(engine, 0) == "tractanda-sqlite-catalogue-v11", sqlite3_step(engine) == SQLITE_DONE
        else { return nil }
        // A copied or partially replaced v3 catalogue can retain valid metadata while
        // its derived query table no longer matches the current engine contract.
        func hasColumns(_ sql: String) -> Bool {
            guard let statement = try? prepare(sql) else { return false }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_DONE
        }
        for sql in [
            "SELECT id,revision,class,deleted,modified,created,fields FROM items LIMIT 0",
            "SELECT revision,item,path,parent,actor,operation,size,inode,uid,mode,mtime_seconds,mtime_nanoseconds,digest,created_at FROM revision_catalog LIMIT 0",
            "SELECT actor,operation,revision,item FROM operation_receipts LIMIT 0",
            "SELECT item,revision,target FROM feedback_refs LIMIT 0",
            "SELECT item_id,field FROM field_presence LIMIT 0",
            "SELECT item_id,field,member_ordinal,type,int_value,real_value,date_value,bool_value FROM scalar_value LIMIT 0",
            "SELECT item_id,owner,group_name,mode,mask,owning_rights,other_rights,extended FROM acl_core LIMIT 0",
            "SELECT item_id,kind,name,rights FROM acl_named LIMIT 0",
        ] where !hasColumns(sql) { return nil }
        let statement = try prepare(
            "SELECT \(catalogueColumns) FROM revision_catalog ORDER BY revision"
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
            guard let digestHex = string(12), digestHex.count == 64, let createdAt = string(13) else {
                return nil
            }
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
                    modificationNanoseconds: mtimeNanoseconds, digest: digest,
                    createdAt: createdAt, feedbackRevisionIDs: try feedbackRevisionIDs(revision)))
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
            "INSERT INTO revision_catalog VALUES (?, ?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                row.revisionID, row.itemID, row.path, row.parentID ?? "", row.actor, row.operationID,
                String(row.size), String(row.inode), String(row.uid), String(row.mode),
                String(row.modificationSeconds), String(row.modificationNanoseconds),
                row.digest.map { String(format: "%02x", $0) }.joined(), row.createdAt,
            ])
        try execute(
            "INSERT INTO operation_receipts VALUES (?, ?, ?, ?)",
            [row.actor, row.operationID, row.revisionID, row.itemID])
        try execute("DELETE FROM feedback_refs WHERE revision=?", [row.revisionID])
        try insertFeedback(row)
    }

    func insertRecoveryRow(_ row: CatalogueRow) throws {
        let values = [
            row.revisionID, row.itemID, row.path, row.parentID ?? "", row.actor, row.operationID,
            String(row.size), String(row.inode), String(row.uid), String(row.mode),
            String(row.modificationSeconds), String(row.modificationNanoseconds),
            row.digest.map { String(format: "%02x", $0) }.joined(), row.createdAt,
        ]
        try execute(
            "INSERT INTO revision_catalog VALUES (?, ?, ?, NULLIF(?, ''), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            values)
        try execute(
            "INSERT INTO operation_receipts VALUES (?, ?, ?, ?)",
            [row.actor, row.operationID, row.revisionID, row.itemID])
        try insertFeedback(row)
    }

    func catalogueCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM revision_catalog")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Immutable revisions only append; capture this on the owner queue before a detached scan.
    func catalogueWatermark() throws -> Int64 {
        let statement = try prepare("SELECT COALESCE(MAX(rowid), 0) FROM revision_catalog")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        let watermark = sqlite3_column_int64(statement, 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        return watermark
    }

    func sealCatalogue(identity: String) throws {
        try execute("INSERT OR REPLACE INTO checkpoint_meta VALUES ('identity', ?)", [identity])
        try execute("INSERT OR REPLACE INTO checkpoint_meta VALUES ('schema', '11')")
        try execute(
            "INSERT OR REPLACE INTO checkpoint_meta VALUES ('engine', 'tractanda-sqlite-catalogue-v11')")
    }

    func recoveryRowPage(after revision: String? = nil, limit: Int = 128) throws -> [CatalogueRow] {
        let sql =
            revision == nil
            ? "SELECT \(catalogueColumns) FROM revision_catalog ORDER BY revision LIMIT ?"
            : "SELECT \(catalogueColumns) FROM revision_catalog WHERE revision>? ORDER BY revision LIMIT ?"
        let bindings = revision.map { [$0, String(limit)] } ?? [String(limit)]
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [CatalogueRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW, let row = catalogueRow(statement) else { throw error() }
            rows.append(row)
        }
    }

    /// Validate graph shape with indexed successor lookups and disk-backed ordinals.
    /// No revision-sized Swift collection is constructed.
    func validateRecoveryGraph() throws {
        try execute("DELETE FROM recovery_ordinals")
        try execute("DELETE FROM recovery_heads")
        let invalidParents = try prepare(
            "SELECT 1 FROM revision_catalog r LEFT JOIN revision_catalog p ON p.revision=r.parent "
                + "WHERE r.parent IS NOT NULL AND (p.revision IS NULL OR p.item!=r.item) LIMIT 1")
        defer { sqlite3_finalize(invalidParents) }
        guard sqlite3_step(invalidParents) == SQLITE_DONE else {
            throw TractandaError("recoveryError", "Missing predecessor or cross-item link.")
        }
        let roots = try prepare(
            "SELECT item,COUNT(*) FROM revision_catalog GROUP BY item "
                + "HAVING SUM(parent IS NULL)!=1 LIMIT 1")
        defer { sqlite3_finalize(roots) }
        guard sqlite3_step(roots) == SQLITE_DONE else {
            throw TractandaError("recoveryError", "An item must have exactly one initial revision.")
        }
        let rootRows = try prepare(
            "SELECT item,revision,created_at FROM revision_catalog WHERE parent IS NULL ORDER BY item")
        defer { sqlite3_finalize(rootRows) }
        while true {
            let status = sqlite3_step(rootRows)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,
                let itemBytes = sqlite3_column_text(rootRows, 0),
                let rootBytes = sqlite3_column_text(rootRows, 1),
                let createdBytes = sqlite3_column_text(rootRows, 2)
            else { throw error() }
            let item = String(cString: itemBytes)
            var current = String(cString: rootBytes)
            let createdAt = String(cString: createdBytes)
            var ordinal: Int64 = 0
            while true {
                ordinal += 1
                try execute(
                    "INSERT INTO recovery_ordinals VALUES (?, ?, ?)", [item, current, String(ordinal)])
                let createdCheck = try prepare(
                    "SELECT created_at FROM revision_catalog WHERE revision=?", [current])
                let createdStatus = sqlite3_step(createdCheck)
                let sameCreatedAt =
                    createdStatus == SQLITE_ROW
                    && sqlite3_column_text(createdCheck, 0).map({ String(cString: $0) }) == createdAt
                let createdDone = sqlite3_step(createdCheck) == SQLITE_DONE
                sqlite3_finalize(createdCheck)
                guard sameCreatedAt && createdDone else {
                    throw TractandaError(
                        "recoveryError", "An item's creation time changed between revisions.")
                }
                let successor = try prepare(
                    "SELECT revision FROM revision_catalog WHERE item=? AND parent=?", [item, current])
                let nextStatus = sqlite3_step(successor)
                if nextStatus == SQLITE_DONE {
                    sqlite3_finalize(successor)
                    break
                }
                guard nextStatus == SQLITE_ROW, let nextBytes = sqlite3_column_text(successor, 0) else {
                    sqlite3_finalize(successor)
                    throw error()
                }
                current = String(cString: nextBytes)
                guard sqlite3_step(successor) == SQLITE_DONE else {
                    sqlite3_finalize(successor)
                    throw TractandaError("recoveryError", "Competing revisions.")
                }
                sqlite3_finalize(successor)
            }
            try execute("INSERT INTO recovery_heads VALUES (?, ?)", [item, current])
            let expected = try prepare("SELECT COUNT(*) FROM revision_catalog WHERE item=?", [item])
            let expectedStatus = sqlite3_step(expected)
            let expectedCount = expectedStatus == SQLITE_ROW ? sqlite3_column_int64(expected, 0) : -1
            let expectedDone = sqlite3_step(expected) == SQLITE_DONE
            sqlite3_finalize(expected)
            guard expectedCount == ordinal && expectedDone else {
                throw TractandaError("recoveryError", "Disconnected revision chain or cycle.")
            }
        }
        let feedback = try prepare(
            "SELECT 1 FROM feedback_refs f LEFT JOIN recovery_ordinals source "
                + "ON source.revision=f.revision AND source.item=f.item "
                + "LEFT JOIN recovery_ordinals target ON target.revision=f.target AND target.item=f.item "
                + "WHERE source.revision IS NULL OR target.revision IS NULL OR target.ordinal>=source.ordinal LIMIT 1"
        )
        defer { sqlite3_finalize(feedback) }
        guard sqlite3_step(feedback) == SQLITE_DONE else {
            throw TractandaError(
                "recoveryError", "Learning feedback must refer to an earlier revision of the same item.")
        }
    }

    func recoveryHead(after itemID: String? = nil) throws -> (itemID: String, revisionID: String)? {
        let sql =
            itemID == nil
            ? "SELECT item,revision FROM recovery_heads ORDER BY item LIMIT 1"
            : "SELECT item,revision FROM recovery_heads WHERE item>? ORDER BY item LIMIT 1"
        let statement = try prepare(sql, itemID.map { [$0] } ?? [])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let item = sqlite3_column_text(statement, 0),
            let revision = sqlite3_column_text(statement, 1)
        else { throw error() }
        return (String(cString: item), String(cString: revision))
    }

    private func feedbackRevisionIDs(_ revision: String) throws -> [String] {
        let statement = try prepare("SELECT target FROM feedback_refs WHERE revision=?", [revision])
        defer { sqlite3_finalize(statement) }
        var targets: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return targets }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { throw error() }
            targets.append(String(cString: bytes))
        }
    }

    private func insertFeedback(_ row: CatalogueRow) throws {
        for target in row.feedbackRevisionIDs {
            try execute("INSERT INTO feedback_refs VALUES (?, ?, ?)", [row.itemID, row.revisionID, target])
        }
    }

    private func catalogueRow(_ statement: OpaquePointer?) -> CatalogueRow? {
        func string(_ column: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, column) else { return nil }
            return String(
                bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))),
                encoding: .utf8)
        }
        guard let revision = string(0), let item = string(1), let path = string(2),
            let actor = string(4), let operation = string(5), let digestHex = string(12),
            digestHex.count == 64
        else { return nil }
        let parent = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : string(3)
        var digest = Data()
        var cursor = digestHex.startIndex
        for _ in 0..<32 {
            let end = digestHex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(digestHex[cursor..<end], radix: 16) else { return nil }
            digest.append(byte)
            cursor = end
        }
        return CatalogueRow(
            revisionID: revision, itemID: item, path: path, parentID: parent, actor: actor,
            operationID: operation, size: UInt64(sqlite3_column_int64(statement, 6)),
            inode: UInt64(sqlite3_column_int64(statement, 7)),
            uid: UInt32(sqlite3_column_int64(statement, 8)),
            mode: UInt32(sqlite3_column_int64(statement, 9)),
            modificationSeconds: sqlite3_column_int64(statement, 10),
            modificationNanoseconds: Int32(sqlite3_column_int64(statement, 11)), digest: digest,
            createdAt: string(13) ?? "", feedbackRevisionIDs: (try? feedbackRevisionIDs(revision)) ?? [])
    }

    private let catalogueColumns =
        "revision,item,path,parent,actor,operation,size,inode,uid,mode,mtime_seconds,mtime_nanoseconds,digest,created_at"

    func revision(_ revisionID: String) throws -> CatalogueRow? {
        let statement = try prepare(
            "SELECT \(catalogueColumns) FROM revision_catalog WHERE revision=?", [revisionID])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else {
            if status == SQLITE_DONE { return nil }
            throw error()
        }
        guard let row = catalogueRow(statement), sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        return row
    }

    func revision(itemID: String, revisionID: String) throws -> CatalogueRow? {
        guard let row = try revision(revisionID), row.itemID == itemID else { return nil }
        return row
    }

    func revisionCount(itemID: String) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM revision_catalog WHERE item=?", [itemID])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        let count = sqlite3_column_int64(statement, 0)
        guard count >= 0, let result = Int(exactly: count), sqlite3_step(statement) == SQLITE_DONE
        else { throw error() }
        return result
    }

    func successor(itemID: String, parentID: String) throws -> CatalogueRow? {
        let statement = try prepare(
            "SELECT \(catalogueColumns) FROM revision_catalog WHERE item=? AND parent=?", [itemID, parentID])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else {
            if status == SQLITE_DONE { return nil }
            throw error()
        }
        guard let row = catalogueRow(statement), sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        return row
    }

    func receipt(actor: String, operationID: String) throws -> CatalogueRow? {
        let statement = try prepare(
            "SELECT \(catalogueColumns) FROM revision_catalog WHERE revision=(SELECT revision FROM operation_receipts WHERE actor=? AND operation=?)",
            [actor, operationID])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else {
            if status == SQLITE_DONE { return nil }
            throw error()
        }
        guard let row = catalogueRow(statement), sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        return row
    }

    func receipts(named operationID: String, maximum: Int = 1024) throws -> [CatalogueRow]? {
        let statement = try prepare(
            "SELECT \(catalogueColumns) FROM revision_catalog WHERE operation=? ORDER BY actor LIMIT ?",
            [operationID, String(maximum + 1)])
        defer { sqlite3_finalize(statement) }
        var rows: [CatalogueRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows.count <= maximum ? rows : nil }
            guard status == SQLITE_ROW, let row = catalogueRow(statement) else { throw error() }
            rows.append(row)
            if rows.count > maximum { return nil }
        }
    }

    func validatedCatalogue(identity: String) throws -> ValidatedCatalogue? {
        // This is the clean-start admission probe. A full integrity/receipt audit scans
        // catalogue-sized data and belongs to explicit audit/rebuild work, not startup.
        for (key, expected) in [
            ("identity", identity), ("schema", "11"), ("engine", "tractanda-sqlite-catalogue-v11"),
        ] {
            let statement = try prepare("SELECT value FROM checkpoint_meta WHERE key=?", [key])
            let valid =
                sqlite3_step(statement) == SQLITE_ROW
                && sqlite3_column_text(statement, 0).map({ String(cString: $0) }) == expected
                && sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            guard valid else { return nil }
        }
        func hasColumns(_ sql: String) -> Bool {
            guard let statement = try? prepare(sql) else { return false }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_DONE
        }
        for sql in [
            "SELECT id,revision,class,deleted,modified,created,fields FROM items LIMIT 0",
            "SELECT item_id,revision,class,deleted,fields,clock_dependent,category FROM head_summaries LIMIT 0",
            "SELECT revision,item,path,parent,actor,operation,size,inode,uid,mode,mtime_seconds,mtime_nanoseconds,digest,created_at FROM revision_catalog LIMIT 0",
            "SELECT actor,operation,revision,item FROM operation_receipts LIMIT 0",
            "SELECT item,revision,target FROM feedback_refs LIMIT 0",
            "SELECT item_id,field FROM field_presence LIMIT 0",
            "SELECT item_id,field,member_ordinal,type,int_value,real_value,date_value,bool_value FROM scalar_value LIMIT 0",
            "SELECT item_id,owner,group_name,mode,mask,owning_rights,other_rights,extended FROM acl_core LIMIT 0",
            "SELECT item_id,kind,name,rights FROM acl_named LIMIT 0",
        ] where !hasColumns(sql) { return nil }
        let triggers = try prepare(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('acl_core_principal_insert','acl_core_principal_delete','acl_named_principal_insert','acl_named_principal_delete')"
        )
        defer { sqlite3_finalize(triggers) }
        guard sqlite3_step(triggers) == SQLITE_ROW, sqlite3_column_int64(triggers, 0) == 4,
            sqlite3_step(triggers) == SQLITE_DONE
        else { return nil }
        let savedViewIndexes = try prepare(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='index' "
                + "AND name IN ('saved_view_base_item','saved_view_staging_item')")
        defer { sqlite3_finalize(savedViewIndexes) }
        guard sqlite3_step(savedViewIndexes) == SQLITE_ROW,
            sqlite3_column_int64(savedViewIndexes, 0) == 2,
            sqlite3_step(savedViewIndexes) == SQLITE_DONE
        else { return nil }
        return ValidatedCatalogue(identity: identity)
    }

    /// Stream the current item-head table one row at a time for clean checkpoint loading.
    func checkpointHead(after itemID: String? = nil)
        throws -> (itemID: String, revisionID: String)?
    {
        let sql: String
        if itemID == nil {
            sql = "SELECT id,revision FROM items ORDER BY id LIMIT 1"
        } else {
            sql = "SELECT id,revision FROM items WHERE id>? ORDER BY id LIMIT 1"
        }
        let statement = try prepare(sql, itemID.map { [$0] } ?? [])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else {
            if status == SQLITE_DONE { return nil }
            throw error()
        }
        guard let item = sqlite3_column_text(statement, 0), let revision = sqlite3_column_text(statement, 1)
        else { throw error() }
        return (String(cString: item), String(cString: revision))
    }

    /// Point-load the disposable current-head projection. This is only a locator and
    /// predicate summary; callers must use the canonical revision loader before returning
    /// a complete Revision to a client.
    func currentHeadSummary(_ itemID: String) throws -> (
        revisionID: String, classID: String, isDeleted: Bool, fields: [String: ItemValue]
    )? {
        let statement = try prepare(
            "SELECT revision,class,deleted,fields FROM head_summaries WHERE item_id=?", [itemID])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let revision = sqlite3_column_text(statement, 0),
            let classID = sqlite3_column_text(statement, 1),
            let fieldsBytes = sqlite3_column_text(statement, 3)
        else { throw error() }
        let fieldByteCount = Int(sqlite3_column_bytes(statement, 3))
        guard fieldByteCount <= 2 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Current-head summary exceeds its byte budget.")
        }
        let fieldsData = Data(bytes: fieldsBytes, count: fieldByteCount)
        let fields = try JSON.decode([String: ItemValue].self, fieldsData)
        return (
            String(cString: revision), String(cString: classID), sqlite3_column_int(statement, 2) != 0, fields
        )
    }

    func currentHeadSummary(classID: String) throws -> (
        itemID: String, revisionID: String, classID: String, isDeleted: Bool, fields: [String: ItemValue]
    )? {
        let statement = try prepare(
            "SELECT item_id,revision,class,deleted,fields FROM head_summaries WHERE class=? ORDER BY item_id LIMIT 1",
            [classID])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let item = sqlite3_column_text(statement, 0),
            let revision = sqlite3_column_text(statement, 1), let cls = sqlite3_column_text(statement, 2),
            let fieldsBytes = sqlite3_column_text(statement, 4)
        else { throw error() }
        let fieldByteCount = Int(sqlite3_column_bytes(statement, 4))
        guard fieldByteCount <= 2 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Current-head summary exceeds its byte budget.")
        }
        let fieldsData = Data(bytes: fieldsBytes, count: fieldByteCount)
        return (
            String(cString: item), String(cString: revision), String(cString: cls),
            sqlite3_column_int(statement, 3) != 0, try JSON.decode([String: ItemValue].self, fieldsData)
        )
    }

    /// Enumerate item IDs with a keyset cursor; callers retain at most one summary at a time.
    func currentHeadID(after itemID: String? = nil, classID: String? = nil) throws -> String? {
        let sql: String
        let bindings: [String]
        switch (itemID, classID) {
        case (nil, nil):
            sql = "SELECT item_id FROM head_summaries ORDER BY item_id LIMIT 1"
            bindings = []
        case (let cursor?, nil):
            sql = "SELECT item_id FROM head_summaries WHERE item_id>? ORDER BY item_id LIMIT 1"
            bindings = [cursor]
        case (nil, let cls?):
            sql = "SELECT item_id FROM head_summaries WHERE class=? ORDER BY item_id LIMIT 1"
            bindings = [cls]
        case (let cursor?, let cls?):
            sql = "SELECT item_id FROM head_summaries WHERE class=? AND item_id>? ORDER BY item_id LIMIT 1"
            bindings = [cls, cursor]
        }
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { throw error() }
        return String(cString: bytes)
    }

    func currentHeadCount(classID: String? = nil) throws -> Int {
        let statement = try prepare(
            classID == nil
                ? "SELECT COUNT(*) FROM head_summaries"
                : "SELECT COUNT(*) FROM head_summaries WHERE class=?", classID.map { [$0] } ?? [])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func currentCategoryHeadID(after itemID: String? = nil) throws -> String? {
        let sql =
            itemID == nil
            ? "SELECT item_id FROM head_summaries WHERE category=1 ORDER BY item_id LIMIT 1"
            : "SELECT item_id FROM head_summaries WHERE category=1 AND item_id>? ORDER BY item_id LIMIT 1"
        let statement = try prepare(sql, itemID.map { [$0] } ?? [])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { throw error() }
        return String(cString: bytes)
    }

    func hasClockDependentCategories() throws -> Bool {
        let statement = try prepare("SELECT 1 FROM head_summaries WHERE clock_dependent=1 LIMIT 1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return false }
        guard status == SQLITE_ROW else { throw error() }
        return true
    }

    func hasActiveHead(classID: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM head_summaries WHERE class=? AND deleted=0 LIMIT 1", [classID])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return false }
        guard status == SQLITE_ROW else { throw error() }
        return true
    }

    func cataloguePage(_ catalogue: ValidatedCatalogue, after revisionID: String? = nil, limit: Int = 256)
        throws -> [CatalogueRow]
    {
        guard (1...1024).contains(limit) else {
            throw TractandaError("invalidLimit", "Catalogue page limit is invalid.")
        }
        let sql =
            revisionID == nil
            ? "SELECT \(catalogueColumns) FROM revision_catalog ORDER BY revision LIMIT ?"
            : "SELECT \(catalogueColumns) FROM revision_catalog WHERE revision>? ORDER BY revision LIMIT ?"
        let bindings = revisionID.map { [$0, String(limit)] } ?? [String(limit)]
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [CatalogueRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW, let row = catalogueRow(statement) else { throw error() }
            rows.append(row)
        }
    }

    func cataloguePageQueryPlanForTesting(after revisionID: String) throws -> [String] {
        let statement = try prepare(
            "EXPLAIN QUERY PLAN SELECT revision FROM revision_catalog WHERE revision>? ORDER BY revision LIMIT 256",
            [revisionID])
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return details }
            guard status == SQLITE_ROW, let detail = sqlite3_column_text(statement, 3) else { throw error() }
            details.append(String(cString: detail))
        }
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
        guard let database else { throw TractandaError("indexError", "Index closed.") }
        var logFrames: Int32 = -1
        var checkpointedFrames: Int32 = -1
        let status = sqlite3_wal_checkpoint_v2(
            database, nil, SQLITE_CHECKPOINT_FULL, &logFrames, &checkpointedFrames)
        guard status == SQLITE_OK, logFrames >= 0, checkpointedFrames == logFrames else {
            throw TractandaError(
                "indexError",
                "WAL checkpoint incomplete or busy (status \(status), log \(logFrames), "
                    + "copied \(checkpointedFrames)).")
        }
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
        let changedSavedViewFields = try changedFields(for: revision)
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
        try putHeadSummary(revision)
        try execute("DELETE FROM field_presence WHERE item_id = ?", [revision.itemID])
        try execute("DELETE FROM scalar_value WHERE item_id = ?", [revision.itemID])
        try putScalars(for: revision)
        try putACL(for: revision)
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
            try replaceSavedViewDependencies(id: revision.itemID, dependencies: target.dependencies)
            try registerSavedViewCoverage(
                id: revision.itemID, revisionID: revision.revisionID, target: target)
        } else {
            try execute("DELETE FROM saved_view_targets WHERE id = ?", [revision.itemID])
            try execute("DELETE FROM saved_view_base WHERE view_id = ?", [revision.itemID])
            try execute("DELETE FROM saved_view_dependencies WHERE view_id = ?", [revision.itemID])
            try execute("DELETE FROM saved_view_coverage WHERE view_id = ?", [revision.itemID])
            try execute("DELETE FROM saved_view_staging WHERE view_id = ?", [revision.itemID])
            try execute("DELETE FROM saved_view_build_state WHERE view_id = ?", [revision.itemID])
        }
        try putCategoryIncludes(for: revision)
        try updateSavedViewBase(for: revision, changedFields: changedSavedViewFields)
    }

    private let savedViewMaterializationBatchLimit = 256
    private let savedViewMaterializationByteLimit = 2 * 1024 * 1024
    private let savedViewMaterializedRowLimit = 65_536
    var savedViewMaterializationBatchLimitForTesting: Int?
    var savedViewMaterializationByteLimitForTesting: Int?

    private func replaceSavedViewDependencies(id: String, dependencies: String) throws {
        try execute("DELETE FROM saved_view_dependencies WHERE view_id=?", [id])
        for dependency in try JSON.decode([String].self, Data(dependencies.utf8)) {
            let parts = dependency.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            try execute(
                "INSERT INTO saved_view_dependencies(view_id,kind,key) VALUES (?,?,?)",
                [id, parts[0], parts[1]])
        }
    }

    private func registerSavedViewCoverage(
        id: String, revisionID: String, target: SavedViewTarget
    ) throws {
        let hashInput = Data((target.selection + "\0" + target.dependencies).utf8)
        let hash = SHA256.hash(data: hashInput).map { String(format: "%02x", $0) }.joined()
        let materialized =
            target.state == "ready" && target.classFilter.isEmpty
            && (target.selection.contains("\"expression\"")
                || target.selection.contains("\"positiveCategorySeed\""))
        let coverageState = materialized ? "building" : target.state
        let prior = try prepare("SELECT definition_hash FROM saved_view_coverage WHERE view_id=?", [id])
        let priorStatus = sqlite3_step(prior)
        let changed =
            priorStatus == SQLITE_DONE
            || (priorStatus == SQLITE_ROW
                && (sqlite3_column_text(prior, 0).map { String(cString: $0) } != hash))
        sqlite3_finalize(prior)
        try execute(
            "INSERT INTO saved_view_coverage VALUES (?,?,?,0,?,?) "
                + "ON CONFLICT(view_id) DO UPDATE SET definition_revision=excluded.definition_revision, "
                + "definition_hash=excluded.definition_hash,dependency_epoch=0, "
                + "applied_through=excluded.applied_through,state=excluded.state "
                + "WHERE saved_view_coverage.definition_hash!=excluded.definition_hash",
            [id, revisionID, hash, revisionID, coverageState])
        if materialized && changed {
            try setSavedViewState("building", id: id)
            try execute("DELETE FROM saved_view_base WHERE view_id=?", [id])
            try execute("DELETE FROM saved_view_staging WHERE view_id=?", [id])
            try execute(
                "INSERT OR REPLACE INTO saved_view_build_state VALUES (?,?,0,'',0)", [id, hash])
        } else if changed {
            try setSavedViewState(target.state, id: id)
            try execute("DELETE FROM saved_view_staging WHERE view_id=?", [id])
            try execute("DELETE FROM saved_view_build_state WHERE view_id=?", [id])
        }
    }

    private func setSavedViewState(_ state: String, id: String) throws {
        try execute("UPDATE saved_view_targets SET state=? WHERE id=?", [state, id])
        try execute("UPDATE saved_view_coverage SET state=? WHERE view_id=?", [state, id])
    }

    /// Advances one bounded on-demand batch. Staging rows remain private until the
    /// cursor is exhausted and the definition hash/dependency epoch still match.
    func advanceSavedViewMaterialization(id: String) throws {
        let target = try prepare(
            "SELECT selection,class_filter,state FROM saved_view_targets WHERE id = ?", [id])
        guard sqlite3_step(target) == SQLITE_ROW,
            let selectionBytes = sqlite3_column_text(target, 0),
            let stateBytes = sqlite3_column_text(target, 2)
        else {
            sqlite3_finalize(target)
            return
        }
        let selectionData = Data(String(cString: selectionBytes).utf8)
        let selection = try JSON.decode([String: ItemValue].self, selectionData)
        let storedClassFilter = sqlite3_column_text(target, 1).map { String(cString: $0) } ?? ""
        let classFilter: String? = storedClassFilter.isEmpty ? nil : storedClassFilter
        let viewState = String(cString: stateBytes)
        sqlite3_finalize(target)
        guard viewState == "building", classFilter == nil else { return }
        let query: SpotlightQuery?
        if let expression = selection["expression"]?.string {
            guard let parsed = try? SpotlightQuery(expression),
                parsed.indexExactClassEquals != nil || parsed.supportsPersistentSavedViewMaterialization
            else { return }
            query = parsed
        } else {
            query = nil
        }
        guard query != nil || selection["positiveCategorySeed"] == .boolean(true) else { return }
        let coverage = try prepare(
            "SELECT definition_hash,dependency_epoch,state FROM saved_view_coverage WHERE view_id=?",
            [id])
        guard sqlite3_step(coverage) == SQLITE_ROW,
            let hashBytes = sqlite3_column_text(coverage, 0),
            let coverageStateBytes = sqlite3_column_text(coverage, 2),
            String(cString: coverageStateBytes) == "building"
        else {
            sqlite3_finalize(coverage)
            return
        }
        let definitionHash = String(cString: hashBytes)
        let dependencyEpoch = sqlite3_column_int64(coverage, 1)
        sqlite3_finalize(coverage)
        let build = try prepare(
            "SELECT definition_hash,dependency_epoch,cursor,candidate_count FROM saved_view_build_state WHERE view_id=?",
            [id])
        guard sqlite3_step(build) == SQLITE_ROW,
            let buildHashBytes = sqlite3_column_text(build, 0),
            let cursorBytes = sqlite3_column_text(build, 2),
            String(cString: buildHashBytes) == definitionHash,
            sqlite3_column_int64(build, 1) == dependencyEpoch
        else {
            sqlite3_finalize(build)
            try execute("DELETE FROM saved_view_staging WHERE view_id=?", [id])
            try execute("DELETE FROM saved_view_build_state WHERE view_id=?", [id])
            try execute(
                "INSERT INTO saved_view_build_state VALUES (?,?,?,'',0)",
                [id, definitionHash, String(dependencyEpoch)])
            return
        }
        let storedCursor = String(cString: cursorBytes)
        let candidateCountBefore = Int(sqlite3_column_int64(build, 3))
        sqlite3_finalize(build)
        let plan: SpotlightQuery.IndexCandidatePlan
        if let categoryPlan = try savedViewCategoryCandidatePlan(id: id, registerDependencies: true) {
            plan = .and(query?.boundedIndexCandidatePlan ?? .all, categoryPlan)
        } else {
            if case .list(let categoryPath)? = selection["categoryPath"], !categoryPath.isEmpty {
                try execute("DELETE FROM saved_view_base WHERE view_id=?", [id])
                try execute("DELETE FROM saved_view_staging WHERE view_id=?", [id])
                try execute("DELETE FROM saved_view_build_state WHERE view_id=?", [id])
                try setSavedViewState("fallback", id: id)
                return
            }
            plan = query?.boundedIndexCandidatePlan ?? .all
        }
        let cursor: String? = storedCursor.isEmpty ? nil : storedCursor
        let batchLimit = max(
            1, savedViewMaterializationBatchLimitForTesting ?? savedViewMaterializationBatchLimit)
        let source = itemSource(
            lexicalText: nil, classEquals: classFilter?.isEmpty == true ? nil : classFilter,
            candidatePlan: plan)
        let cursorClause = cursor == nil ? "" : " AND items.id>?"
        let bindings = source.arguments + (cursor.map { [$0] } ?? [])
        let statement = try prepare(
            "SELECT items.id,items.modified,items.created" + source.sql
                + cursorClause + " ORDER BY items.id LIMIT \(batchLimit)",
            bindings)
        var batch: [(String, Double, Double)] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let idBytes = sqlite3_column_text(statement, 0)
            else {
                sqlite3_finalize(statement)
                throw error()
            }
            let itemID = String(cString: idBytes)
            batch.append(
                (itemID, sqlite3_column_double(statement, 1), sqlite3_column_double(statement, 2)))
        }
        sqlite3_finalize(statement)
        let retained = try prepare("SELECT COUNT(*) FROM saved_view_base")
        defer { sqlite3_finalize(retained) }
        guard sqlite3_step(retained) == SQLITE_ROW else { throw error() }
        var retainedRows = Int(sqlite3_column_int64(retained, 0))
        let stagedCount = try prepare("SELECT COUNT(*) FROM saved_view_staging")
        defer { sqlite3_finalize(stagedCount) }
        guard sqlite3_step(stagedCount) == SQLITE_ROW else { throw error() }
        retainedRows += Int(sqlite3_column_int64(stagedCount, 0))
        let candidateCount = candidateCountBefore + batch.count
        var serializedBytes = 0
        let byteLimit = max(
            1, savedViewMaterializationByteLimitForTesting ?? savedViewMaterializationByteLimit)
        for row in batch {
            let fieldsStatement = try prepare(
                "SELECT fields FROM items WHERE id=? AND deleted=0", [row.0])
            guard sqlite3_step(fieldsStatement) == SQLITE_ROW,
                let fieldsBytes = sqlite3_column_text(fieldsStatement, 0)
            else {
                sqlite3_finalize(fieldsStatement)
                throw error()
            }
            let fieldByteCount = Int(sqlite3_column_bytes(fieldsStatement, 0))
            guard fieldByteCount <= byteLimit - serializedBytes else {
                sqlite3_finalize(fieldsStatement)
                try execute("DELETE FROM saved_view_staging WHERE view_id=?", [id])
                try execute("DELETE FROM saved_view_build_state WHERE view_id=?", [id])
                try setSavedViewState("fallback", id: id)
                return
            }
            let fieldData = Data(bytes: fieldsBytes, count: fieldByteCount)
            sqlite3_finalize(fieldsStatement)
            serializedBytes += fieldByteCount
            let fields = try JSON.decode([String: ItemValue].self, fieldData)
            let revision = try Revision(fields: fields)
            guard query?.matches(revision, at: Date()) ?? true else { continue }
            let staged = try prepare(
                "SELECT 1 FROM saved_view_staging WHERE view_id=? AND item_id=?",
                [id, row.0])
            let alreadyStaged = sqlite3_step(staged) == SQLITE_ROW
            sqlite3_finalize(staged)
            guard alreadyStaged || retainedRows < savedViewMaterializedRowLimit else {
                try execute("DELETE FROM saved_view_staging WHERE view_id=?", [id])
                try execute("DELETE FROM saved_view_build_state WHERE view_id=?", [id])
                try setSavedViewState("fallback", id: id)
                return
            }
            try execute(
                "INSERT INTO saved_view_staging(view_id,item_id,modified,created) VALUES (?,?,?,?) "
                    + "ON CONFLICT(view_id,item_id) DO UPDATE SET modified=excluded.modified,created=excluded.created",
                [id, row.0, String(row.1), String(row.2)])
            if !alreadyStaged { retainedRows += 1 }
        }
        let nextCursor = batch.last?.0 ?? cursor ?? ""
        try execute(
            "UPDATE saved_view_build_state SET cursor=?,candidate_count=? WHERE view_id=?",
            [nextCursor, String(candidateCount), id])
        guard batch.count < batchLimit else { return }
        let current = try prepare(
            "SELECT definition_hash,dependency_epoch,state FROM saved_view_coverage WHERE view_id=?", [id])
        guard sqlite3_step(current) == SQLITE_ROW,
            let currentHash = sqlite3_column_text(current, 0),
            String(cString: currentHash) == definitionHash,
            sqlite3_column_int64(current, 1) == dependencyEpoch,
            let currentState = sqlite3_column_text(current, 2),
            String(cString: currentState) == "building"
        else {
            sqlite3_finalize(current)
            try execute("DELETE FROM saved_view_staging WHERE view_id=?", [id])
            try execute("DELETE FROM saved_view_build_state WHERE view_id=?", [id])
            return
        }
        sqlite3_finalize(current)
        try execute(
            "INSERT INTO saved_view_base(view_id,item_id,modified,created) "
                + "SELECT view_id,item_id,modified,created FROM saved_view_staging WHERE view_id=?", [id])
        try execute("DELETE FROM saved_view_staging WHERE view_id=?", [id])
        try execute("DELETE FROM saved_view_build_state WHERE view_id=?", [id])
        try setSavedViewState("ready", id: id)
    }

    private func savedViewCategoryCandidatePlan(id: String, registerDependencies: Bool = false) throws
        -> SpotlightQuery.IndexCandidatePlan?
    {
        savedViewCategoryPlanLookupsForTesting += 1
        let target = try prepare("SELECT selection FROM saved_view_targets WHERE id=?", [id])
        guard sqlite3_step(target) == SQLITE_ROW, let bytes = sqlite3_column_text(target, 0) else {
            sqlite3_finalize(target)
            return nil
        }
        let selection = try JSON.decode([String: ItemValue].self, Data(String(cString: bytes).utf8))
        sqlite3_finalize(target)
        let roots: [String]
        if case .list(let values)? = selection["categoryPath"] {
            roots = values.compactMap(\.string)
        } else {
            roots = []
        }
        guard !roots.isEmpty else { return nil }
        var pending = roots
        var categories: Set<String> = []
        var rules: [SpotlightQuery.IndexCandidatePlan] = []
        var ruleFields: Set<String> = ["categoryOverrides"]
        var atomCount = 0
        while let categoryID = pending.popLast() {
            guard categories.insert(categoryID).inserted else { continue }
            guard categories.count <= 32 else { return nil }
            let row = try prepare("SELECT fields,deleted FROM items WHERE id=?", [categoryID])
            guard sqlite3_step(row) == SQLITE_ROW, sqlite3_column_int(row, 1) == 0,
                let fieldBytes = sqlite3_column_text(row, 0)
            else {
                sqlite3_finalize(row)
                return nil
            }
            let fields = try JSON.decode(
                [String: ItemValue].self,
                Data(bytes: fieldBytes, count: Int(sqlite3_column_bytes(row, 0))))
            sqlite3_finalize(row)
            guard let selection = fields["selection"]?.map else { return nil }
            if selection["timeWindow"] != nil { return nil }
            if let expression = selection["expression"]?.string {
                guard let rule = try? SpotlightQuery(expression),
                    !rule.indexDependencies.usesClock, !rule.boundedIndexCandidatePlan.isAll
                else { return nil }
                atomCount += rule.boundedIndexCandidatePlan.atomCount
                guard atomCount <= 16 else { return nil }
                rules.append(rule.boundedIndexCandidatePlan)
                ruleFields.formUnion(rule.indexDependencies.fields)
            }
            let children = try prepare(
                "SELECT target_id FROM category_edges WHERE source_id=? AND kind='parent'", [categoryID])
            while true {
                let status = sqlite3_step(children)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let child = sqlite3_column_text(children, 0) else {
                    sqlite3_finalize(children)
                    throw error()
                }
                pending.append(String(cString: child))
            }
            sqlite3_finalize(children)
            let exclusions = try prepare(
                "SELECT target_id FROM category_edges WHERE source_id=? AND kind='exclusion'", [categoryID])
            while true {
                let status = sqlite3_step(exclusions)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let excluded = sqlite3_column_text(exclusions, 0) else {
                    sqlite3_finalize(exclusions)
                    throw error()
                }
                pending.append(String(cString: excluded))
            }
            sqlite3_finalize(exclusions)
        }
        guard !rules.isEmpty else { return nil }
        if registerDependencies {
            try execute(
                "DELETE FROM saved_view_dependencies WHERE view_id=? AND kind='categoryRuleField'", [id])
            for field in ruleFields.sorted() {
                try execute(
                    "INSERT INTO saved_view_dependencies(view_id,kind,key) VALUES (?,'categoryRuleField',?)",
                    [id, field])
            }
        }
        var positives = rules.reduce(SpotlightQuery.IndexCandidatePlan.all) { current, next in
            current.isAll ? next : .or(current, next)
        }
        let manual = SpotlightQuery.IndexCandidatePlan.categoryDecisions(categories)
        positives = .or(positives, manual)
        return positives
    }

    /// Clears derived state after streamed recovery. Eligible targets remain `building`
    /// and are advanced in bounded batches on demand by their next saved-view reads.
    func finalizeSavedViewMaterializations() throws {
        try execute("DELETE FROM saved_view_base")
        try execute("DELETE FROM saved_view_staging")
        try execute("DELETE FROM saved_view_build_state")
        try execute(
            "INSERT INTO saved_view_build_state(view_id,definition_hash,dependency_epoch,cursor,candidate_count) "
                + "SELECT view_id,definition_hash,dependency_epoch,'',0 FROM saved_view_coverage WHERE state='building'"
        )
        try execute(
            "UPDATE saved_view_targets SET state='building' WHERE id IN (SELECT view_id FROM saved_view_coverage WHERE state='building')"
        )
    }

    /// Replaces the changed item's positive rows in every ready exact-class view.
    /// Current ACL remains request-scoped and is never persisted here.
    private func changedFields(for revision: Revision) throws -> Set<String> {
        let statement = try prepare("SELECT fields FROM items WHERE id=?", [revision.itemID])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let bytes = sqlite3_column_text(statement, 0)
        else { return Set(revision.fields.keys).union(["modifiedAt"]) }
        let old = try JSON.decode(
            [String: ItemValue].self,
            Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        let keys = Set(old.keys).union(revision.fields.keys)
        return Set(keys.filter { old[$0] != revision.fields[$0] }).union(["modifiedAt"])
    }

    private func updateSavedViewBase(for revision: Revision, changedFields: Set<String>) throws {
        guard !changedFields.isEmpty else { return }
        let categoryStructureChanged =
            revision.fields["selection"] != nil || changedFields.contains("selection")
            || changedFields.contains("categoryParents") || revision.classID == "CategoryItem"
        if categoryStructureChanged {
            // Category descendants and exclusions can change the positive source of a view
            // rooted elsewhere. Reset all category targets transactionally, without retaining
            // a view-sized Swift collection; later reads catch up in bounded batches.
            let categoryViews =
                "SELECT view_id FROM saved_view_dependencies WHERE kind='categoryRule'"
            try execute("DELETE FROM saved_view_base WHERE view_id IN (\(categoryViews))")
            try execute("DELETE FROM saved_view_staging WHERE view_id IN (\(categoryViews))")
            try execute("DELETE FROM saved_view_build_state WHERE view_id IN (\(categoryViews))")
            try execute(
                "UPDATE saved_view_coverage SET dependency_epoch=dependency_epoch+1,state='building' "
                    + "WHERE view_id IN (\(categoryViews))")
            try execute(
                "UPDATE saved_view_targets SET state='building' WHERE id IN (\(categoryViews))")
            try execute(
                "DELETE FROM saved_view_dependencies WHERE kind='categoryRuleField' "
                    + "AND view_id IN (\(categoryViews))")
            try execute(
                "INSERT INTO saved_view_build_state(view_id,definition_hash,dependency_epoch,cursor,candidate_count) "
                    + "SELECT view_id,definition_hash,dependency_epoch,'',0 FROM saved_view_coverage "
                    + "WHERE view_id IN (\(categoryViews))")
        }
        var affected = Set<String>()
        let keys = changedFields.sorted()
        for offset in stride(from: 0, to: keys.count, by: 300) {
            let batch = Array(keys[offset..<min(offset + 300, keys.count)])
            let statement = try prepare(
                "SELECT DISTINCT view_id FROM saved_view_dependencies "
                    + "WHERE kind IN ('field','categoryRuleField') AND key IN "
                    + "(\(Array(repeating: "?", count: batch.count).joined(separator: ",")))",
                batch)
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
                    sqlite3_finalize(statement)
                    throw error()
                }
                affected.insert(String(cString: raw))
                if affected.count > 256 {
                    sqlite3_finalize(statement)
                    try fallbackAllSavedViewMaterializations()
                    return
                }
            }
            sqlite3_finalize(statement)
        }
        // An order-only edit affects only views already containing the item. The reverse
        // indexes avoid probing every saved view for unrelated ingestion.
        let existingViews = try prepare(
            "SELECT view_id FROM saved_view_base WHERE item_id=? "
                + "UNION SELECT view_id FROM saved_view_staging WHERE item_id=?",
            [revision.itemID, revision.itemID])
        while true {
            let status = sqlite3_step(existingViews)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let raw = sqlite3_column_text(existingViews, 0) else {
                sqlite3_finalize(existingViews)
                throw error()
            }
            affected.insert(String(cString: raw))
            if affected.count > 256 {
                sqlite3_finalize(existingViews)
                try fallbackAllSavedViewMaterializations()
                return
            }
        }
        sqlite3_finalize(existingViews)
        guard !affected.isEmpty else { return }
        for id in affected {
            let predicateDependency = try prepare(
                "SELECT 1 FROM saved_view_dependencies WHERE view_id=? AND kind='field' AND key IN "
                    + "(\(Array(repeating: "?", count: keys.count).joined(separator: ","))) LIMIT 1",
                [id] + keys)
            let predicateStatus = sqlite3_step(predicateDependency)
            sqlite3_finalize(predicateDependency)
            let predicateChanged = predicateStatus == SQLITE_ROW
            let hasCategoryRuleDependency = try {
                let statement = try prepare(
                    "SELECT 1 FROM saved_view_dependencies WHERE view_id=? AND kind='categoryRule' LIMIT 1",
                    [id])
                defer { sqlite3_finalize(statement) }
                return sqlite3_step(statement) == SQLITE_ROW
            }()
            if categoryStructureChanged && hasCategoryRuleDependency { continue }
            let stateStatement = try prepare(
                "SELECT state,definition_hash,dependency_epoch FROM saved_view_coverage WHERE view_id=?", [id]
            )
            guard sqlite3_step(stateStatement) == SQLITE_ROW,
                let stateBytes = sqlite3_column_text(stateStatement, 0),
                let hashBytes = sqlite3_column_text(stateStatement, 1)
            else {
                sqlite3_finalize(stateStatement)
                continue
            }
            let state = String(cString: stateBytes)
            let hash = String(cString: hashBytes)
            let epoch = sqlite3_column_int64(stateStatement, 2) + 1
            sqlite3_finalize(stateStatement)
            guard state == "ready" || state == "building" else { continue }
            let destination = state == "building" ? "saved_view_staging" : "saved_view_base"
            let existing = try prepare(
                "SELECT 1 FROM \(destination) WHERE view_id=? AND item_id=? LIMIT 1",
                [id, revision.itemID])
            let hasRow = sqlite3_step(existing) == SQLITE_ROW
            sqlite3_finalize(existing)
            let target = try prepare(
                "SELECT selection,class_filter FROM saved_view_targets WHERE id=?", [id])
            guard sqlite3_step(target) == SQLITE_ROW,
                let selectionBytes = sqlite3_column_text(target, 0)
            else {
                sqlite3_finalize(target)
                continue
            }
            let classFilter = sqlite3_column_text(target, 1).map { String(cString: $0) } ?? ""
            let selection = try JSON.decode(
                [String: ItemValue].self, Data(String(cString: selectionBytes).utf8))
            sqlite3_finalize(target)
            guard classFilter.isEmpty else { continue }
            let newMatches: Bool
            if hasCategoryRuleDependency, !revision.isDeleted {
                guard let categoryPlan = try savedViewCategoryCandidatePlan(id: id) else {
                    try execute("DELETE FROM saved_view_base WHERE view_id=?", [id])
                    try execute("DELETE FROM saved_view_staging WHERE view_id=?", [id])
                    try execute("DELETE FROM saved_view_build_state WHERE view_id=?", [id])
                    try setSavedViewState("fallback", id: id)
                    continue
                }
                let queryMatches: Bool
                if let expression = selection["expression"]?.string,
                    let predicate = try? SpotlightQuery(expression)
                {
                    queryMatches = predicate.matches(revision, at: Date())
                } else {
                    queryMatches = true
                }
                let candidate = candidateSQL(categoryPlan)
                let match = try prepare(
                    "SELECT 1 FROM items WHERE id=? AND deleted=0 AND \(candidate.0) LIMIT 1",
                    [revision.itemID] + candidate.1)
                let seedMatches = sqlite3_step(match) == SQLITE_ROW
                sqlite3_finalize(match)
                newMatches = queryMatches && seedMatches
            } else if predicateChanged, !revision.isDeleted,
                classFilter.isEmpty || classFilter == revision.classID,
                let expression = selection["expression"]?.string,
                let predicate = try? SpotlightQuery(expression)
            {
                newMatches = predicate.matches(revision, at: Date())
            } else {
                newMatches = false
            }
            let membershipChanged = predicateChanged || hasCategoryRuleDependency
            guard membershipChanged ? (hasRow || newMatches) : hasRow else { continue }
            try execute(
                "UPDATE saved_view_coverage SET dependency_epoch=?,applied_through=? WHERE view_id=?",
                [String(epoch), revision.revisionID, id])
            if state == "building" {
                try execute(
                    "UPDATE saved_view_build_state SET dependency_epoch=? WHERE view_id=? AND definition_hash=?",
                    [String(epoch), id, hash])
            }
            if membershipChanged {
                try execute(
                    "DELETE FROM \(destination) WHERE view_id=? AND item_id=?", [id, revision.itemID])
            }
            if revision.isDeleted || membershipChanged && !newMatches { continue }
            guard case .date(let modifiedValue)? = revision.fields["modifiedAt"],
                let modified = Timestamp.parse(modifiedValue)?.timeIntervalSinceReferenceDate,
                case .date(let createdValue)? = revision.fields["createdAt"],
                let created = Timestamp.parse(createdValue)?.timeIntervalSinceReferenceDate
            else { continue }
            if membershipChanged {
                let retained = try prepare(
                    "SELECT (SELECT COUNT(*) FROM saved_view_base)+(SELECT COUNT(*) FROM saved_view_staging)"
                )
                guard sqlite3_step(retained) == SQLITE_ROW else {
                    sqlite3_finalize(retained)
                    throw error()
                }
                let retainedCount = Int(sqlite3_column_int64(retained, 0))
                sqlite3_finalize(retained)
                guard retainedCount < savedViewMaterializedRowLimit else {
                    try execute("DELETE FROM saved_view_base WHERE view_id=?", [id])
                    try execute("DELETE FROM saved_view_staging WHERE view_id=?", [id])
                    try execute("DELETE FROM saved_view_build_state WHERE view_id=?", [id])
                    try setSavedViewState("fallback", id: id)
                    continue
                }
                try execute(
                    "INSERT INTO \(destination)(view_id,item_id,modified,created) VALUES (?,?,?,?)",
                    [id, revision.itemID, String(modified), String(created)])
            } else {
                try execute(
                    "UPDATE \(destination) SET modified=?,created=? WHERE view_id=? AND item_id=?",
                    [String(modified), String(created), id, revision.itemID])
            }
        }
    }

    private func fallbackAllSavedViewMaterializations() throws {
        // A single item can intersect arbitrarily many registered views. Exceeding the
        // bounded owner-queue delta fanout discards disposable acceleration atomically;
        // every view remains answerable through its exact query path.
        try execute("DELETE FROM saved_view_base")
        try execute("DELETE FROM saved_view_staging")
        try execute("DELETE FROM saved_view_build_state")
        try execute("UPDATE saved_view_targets SET state='fallback'")
        try execute("UPDATE saved_view_coverage SET state='fallback'")
    }

    private func putHeadSummary(_ revision: Revision) throws {
        let retained = revision.fields.filter { Self.headSummaryFieldNames.contains($0.key) }
        let fields = String(decoding: try JSON.encode(retained), as: UTF8.self)
        let selection = revision.fields["selection"]?.map
        let clockDependent =
            !revision.isDeleted
            && (selection?["timeWindow"] != nil
                || selection?["expression"]?.string?.contains("$time.") == true)
        let category = revision.fields["selection"] != nil || revision.fields["categoryParents"] != nil
        try execute(
            "INSERT OR REPLACE INTO head_summaries VALUES (?, ?, ?, ?, ?, ?, ?)",
            [
                revision.itemID, revision.revisionID, revision.classID,
                revision.isDeleted ? "1" : "0", fields,
                clockDependent ? "1" : "0", category ? "1" : "0",
            ])
    }

    private func putScalars(
        for revision: Revision, presenceStatement: OpaquePointer? = nil,
        scalarStatement: OpaquePointer? = nil
    ) throws {
        var ownedPresence: OpaquePointer?
        var ownedScalar: OpaquePointer?
        if presenceStatement == nil {
            ownedPresence = try prepare("INSERT OR IGNORE INTO field_presence VALUES (?, ?)")
        }
        if scalarStatement == nil {
            ownedScalar = try prepare(
                "INSERT INTO scalar_value VALUES (?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''))"
            )
        }
        defer {
            if let ownedPresence { sqlite3_finalize(ownedPresence) }
            if let ownedScalar { sqlite3_finalize(ownedScalar) }
        }
        guard let presence = presenceStatement ?? ownedPresence,
            let scalar = scalarStatement ?? ownedScalar
        else { throw error() }
        for (rawField, value) in revision.fields {
            // Persist the actual canonical key. Aliases are normalized at query time;
            // normalizing stored user keys would fabricate presence for another field.
            let field = rawField
            try run(presence, [revision.itemID, field])
            let values = value.array ?? [value]
            for (ordinal, member) in values.enumerated() {
                let type: String
                let integer: String
                let real: String
                let date: String
                let boolean: String
                switch member {
                case .integer(let number):
                    type = "integer"
                    integer = String(number)
                    real = ""
                    date = ""
                    boolean = ""
                case .real(let number) where number.isFinite:
                    type = "real"
                    integer = ""
                    real = String(number)
                    date = ""
                    boolean = ""
                case .boolean(let value):
                    type = "boolean"
                    integer = ""
                    real = ""
                    date = ""
                    boolean = value ? "1" : "0"
                case .date(let value):
                    guard let parsed = Timestamp.parse(value), parsed.timeIntervalSinceReferenceDate.isFinite
                    else { continue }
                    type = "date"
                    integer = ""
                    real = ""
                    date = String(parsed.timeIntervalSinceReferenceDate)
                    boolean = ""
                default: continue
                }
                try run(
                    scalar, [revision.itemID, field, String(ordinal), type, integer, real, date, boolean])
            }
        }
    }

    private func putACL(
        for revision: Revision, coreStatement: OpaquePointer? = nil,
        namedStatement: OpaquePointer? = nil
    ) throws {
        try execute("DELETE FROM acl_named WHERE item_id = ?", [revision.itemID])
        try execute("DELETE FROM acl_core WHERE item_id = ?", [revision.itemID])
        guard !revision.isDeleted,
            let value = revision.fields["permissions"],
            let permissions = try? ItemPermissions(value)
        else { return }
        var owned: OpaquePointer?
        if coreStatement == nil {
            owned = try prepare("INSERT INTO acl_core VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        }
        defer { if let owned { sqlite3_finalize(owned) } }
        guard let core = coreStatement ?? owned else { throw error() }
        let mask = permissions.mask ?? ((permissions.mode >> 3) & 7)
        try run(
            core,
            [
                revision.itemID, permissions.owner, permissions.group, String(permissions.mode), String(mask),
                String(permissions.owningGroupPermissions), String(permissions.mode & 7),
                permissions.mask == nil ? "0" : "1",
            ])
        var ownedNamed: OpaquePointer?
        if namedStatement == nil { ownedNamed = try prepare("INSERT INTO acl_named VALUES (?, ?, ?, ?)") }
        defer { if let ownedNamed { sqlite3_finalize(ownedNamed) } }
        guard let named = namedStatement ?? ownedNamed else { throw error() }
        for (name, rights) in permissions.users {
            try run(named, [revision.itemID, "user", name, String(rights)])
        }
        for (name, rights) in permissions.groups {
            try run(named, [revision.itemID, "group", name, String(rights)])
        }
    }

    func aclPrincipalNames(maximum: Int = 1024) throws -> (users: [String], groups: [String])? {
        func names(_ sql: String) throws -> [String]? {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            defer {
                principalLookupVMInstructionsForTesting += Int(
                    sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
            }
            var result: [String] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                    throw error()
                }
                result.append(String(cString: text))
                if result.count > maximum { return nil }
            }
        }
        guard
            let users = try names(
                "SELECT name FROM acl_principal_counts WHERE kind='user' AND refcount>0 ORDER BY name LIMIT \(maximum + 1)"
            ),
            let groups = try names(
                "SELECT name FROM acl_principal_counts WHERE kind='group' AND refcount>0 ORDER BY name LIMIT \(maximum + 1)"
            ),
            users.count <= maximum, groups.count <= maximum
        else { return nil }
        return (users, groups)
    }

    func resetPrincipalLookupVMInstructionsForTesting() {
        principalLookupVMInstructionsForTesting = 0
    }

    func setRequestPrincipals(
        actorUID: UInt32, users: [String: UInt32], groups: [String: (id: UInt32, member: Bool)]
    ) throws {
        try execute("SAVEPOINT request_principals")
        do {
            try execute("DELETE FROM request_users")
            try execute("DELETE FROM request_groups")
            try execute("DELETE FROM request_actor")
            for (name, uid) in users {
                try execute("INSERT INTO request_users VALUES (?, ?)", [name, String(uid)])
            }
            for (name, group) in groups {
                try execute(
                    "INSERT INTO request_groups VALUES (?, ?, ?)",
                    [name, String(group.id), group.member ? "1" : "0"])
            }
            try execute("INSERT INTO request_actor VALUES (?)", [String(actorUID)])
            try execute("RELEASE request_principals")
        } catch {
            try? execute("ROLLBACK TO request_principals")
            try? execute("RELEASE request_principals")
            try? execute("DELETE FROM request_users")
            try? execute("DELETE FROM request_groups")
            try? execute("DELETE FROM request_actor")
            throw error
        }
    }

    func clearRequestPrincipals() throws {
        try execute("DELETE FROM request_users")
        try execute("DELETE FROM request_groups")
        try execute("DELETE FROM request_actor")
    }

    private let aclReadPredicate = """
            EXISTS (SELECT 1 FROM acl_core a WHERE a.item_id=items.id
              AND NOT EXISTS (SELECT 1 FROM acl_named n JOIN request_users ru ON ru.name=n.name
                WHERE n.item_id=a.item_id AND n.kind='user'
                GROUP BY n.item_id HAVING COUNT(DISTINCT ru.uid) != COUNT(*))
              AND NOT EXISTS (SELECT 1 FROM acl_named n JOIN request_groups rg ON rg.name=n.name
                WHERE n.item_id=a.item_id AND n.kind='group'
                GROUP BY n.item_id HAVING COUNT(DISTINCT rg.gid) != COUNT(*))
              AND CASE
                WHEN EXISTS (SELECT 1 FROM request_users u, request_actor actor WHERE u.name=a.owner AND u.uid=actor.uid)
                  THEN ((a.mode >> 6) & 4)=4
                WHEN EXISTS (SELECT 1 FROM acl_named n JOIN request_users u ON u.name=n.name
                  WHERE n.item_id=a.item_id AND n.kind='user' AND u.uid=(SELECT uid FROM request_actor))
                  THEN EXISTS (SELECT 1 FROM acl_named n JOIN request_users u ON u.name=n.name
                    WHERE n.item_id=a.item_id AND n.kind='user' AND u.uid=(SELECT uid FROM request_actor) AND (n.rights & a.mask & 4)=4)
                WHEN EXISTS (SELECT 1 FROM request_groups g WHERE g.name=a.group_name AND g.member=1)
                  THEN (a.owning_rights & a.mask & 4)=4
                     OR EXISTS (SELECT 1 FROM acl_named n JOIN request_groups g ON g.name=n.name
                       WHERE n.item_id=a.item_id AND n.kind='group' AND g.member=1 AND (n.rights & a.mask & 4)=4)
                WHEN EXISTS (SELECT 1 FROM acl_named n JOIN request_groups g ON g.name=n.name
                  WHERE n.item_id=a.item_id AND n.kind='group' AND g.member=1)
                  THEN EXISTS (SELECT 1 FROM acl_named n JOIN request_groups g ON g.name=n.name
                    WHERE n.item_id=a.item_id AND n.kind='group' AND g.member=1 AND (n.rights & a.mask & 4)=4)
                ELSE (a.other_rights & 4)=4
              END=1)
        """

    private var aclAuthorizedIDs: String {
        let valid = """
            NOT EXISTS (SELECT 1 FROM acl_named n JOIN request_users ru ON ru.name=n.name
              WHERE n.item_id=a.item_id AND n.kind='user'
              GROUP BY n.item_id HAVING COUNT(DISTINCT ru.uid) != COUNT(*))
            AND NOT EXISTS (SELECT 1 FROM acl_named n JOIN request_groups rg ON rg.name=n.name
              WHERE n.item_id=a.item_id AND n.kind='group'
              GROUP BY n.item_id HAVING COUNT(DISTINCT rg.gid) != COUNT(*))
            """
        let ownerMatch =
            "EXISTS (SELECT 1 FROM request_users u JOIN request_actor actor ON actor.uid=u.uid WHERE u.name=a.owner)"
        let namedUserMatch =
            "EXISTS (SELECT 1 FROM acl_named n JOIN request_users u ON u.name=n.name JOIN request_actor actor ON actor.uid=u.uid WHERE n.item_id=a.item_id AND n.kind='user')"
        let groupMatch =
            "EXISTS (SELECT 1 FROM request_groups g WHERE g.name=a.group_name AND g.member=1) OR EXISTS (SELECT 1 FROM acl_named n JOIN request_groups g ON g.name=n.name WHERE n.item_id=a.item_id AND n.kind='group' AND g.member=1)"
        return """
            SELECT item_id FROM (
            SELECT a.item_id FROM request_users u JOIN request_actor actor ON actor.uid=u.uid
            CROSS JOIN acl_core a INDEXED BY acl_owner_lookup
            WHERE a.owner=u.name AND ((a.mode >> 6) & 4)=4 AND \(valid)
            UNION
            SELECT a.item_id FROM request_users u JOIN request_actor actor ON actor.uid=u.uid
            CROSS JOIN acl_named n INDEXED BY acl_named_lookup JOIN acl_core a ON a.item_id=n.item_id
            WHERE n.name=u.name AND n.kind='user' AND (n.rights & a.mask & 4)=4
                  AND NOT (\(ownerMatch)) AND \(valid)
              UNION
            SELECT a.item_id FROM request_groups g
              CROSS JOIN acl_core a INDEXED BY acl_group_lookup
              WHERE a.group_name=g.name AND g.member=1 AND (a.owning_rights & a.mask & 4)=4
                  AND NOT (\(ownerMatch)) AND NOT (\(namedUserMatch)) AND \(valid)
              UNION
            SELECT a.item_id FROM request_groups g
            CROSS JOIN acl_named n INDEXED BY acl_named_lookup JOIN acl_core a ON a.item_id=n.item_id
            WHERE n.name=g.name AND n.kind='group' AND g.member=1 AND (n.rights & a.mask & 4)=4
                  AND NOT (\(ownerMatch)) AND NOT (\(namedUserMatch)) AND \(valid)
              UNION
              SELECT a.item_id FROM acl_core a INDEXED BY acl_other_lookup
                WHERE a.other_rights IN (4,6) AND NOT (\(ownerMatch)) AND NOT (\(namedUserMatch))
                  AND NOT (\(groupMatch)) AND \(valid)
            )
            """
    }

    private func putCategoryIncludes(for revision: Revision, deletingPreviousSourceRows: Bool = true) throws {
        if deletingPreviousSourceRows {
            try execute("DELETE FROM category_include_candidates WHERE source_id = ?", [revision.itemID])
            try execute("DELETE FROM category_decision_candidates WHERE source_id = ?", [revision.itemID])
            // Parent edges belong to the child revision; revising a parent must not
            // erase its unchanged children's links.
            try execute(
                "DELETE FROM category_edges WHERE target_id = ? AND kind = 'parent'", [revision.itemID])
            try execute(
                "DELETE FROM category_edges WHERE source_id = ? AND kind = 'exclusion'", [revision.itemID])
            try execute("DELETE FROM personal_category_delta WHERE source_id = ?", [revision.itemID])
            try execute("DELETE FROM personal_overlay_targets WHERE source_id = ?", [revision.itemID])
        }
        guard !revision.isDeleted else { return }
        if revision.fields["selection"] != nil {
            for parent in try CategoryHierarchy.parents(of: revision) {
                try execute(
                    "INSERT OR IGNORE INTO category_edges VALUES (?, ?, 'parent')", [parent, revision.itemID])
            }
            for excluded in try CategoryHierarchy.excludedCategories(
                revision.fields["selection"]?.map?["excludedCategoryIDs"])
            {
                try execute(
                    "INSERT OR IGNORE INTO category_edges VALUES (?, ?, 'exclusion')",
                    [revision.itemID, excluded])
            }
        }
        for (categoryID, decision) in revision.fields["categoryOverrides"]?.map ?? [:]
        where ["include", "exclude"].contains(decision.string ?? "") {
            if revision.classID != "PersonalStateItem" {
                try execute(
                    "INSERT OR IGNORE INTO category_decision_candidates VALUES (?, ?, ?)",
                    [categoryID, revision.itemID, revision.itemID])
            }
        }
        for (categoryID, decision) in revision.fields["categoryOverrides"]?.map ?? [:]
        where decision.string == "include" {
            try execute(
                "INSERT OR IGNORE INTO category_include_candidates VALUES (?, ?, ?)",
                [categoryID, revision.itemID, revision.itemID])
        }
        if revision.classID == "PersonalStateItem",
            let targetID = revision.fields["target"]?.link?.itemID
        {
            let owner = revision.fields["permissions"]?.map?["owner"]?.string ?? ""
            try execute(
                "INSERT OR REPLACE INTO personal_overlay_targets VALUES (?, ?, ?)",
                [owner, targetID, revision.itemID])
            for (categoryID, decision) in revision.fields["personalOverrides"]?.map ?? [:]
            where ["include", "exclude"].contains(decision.string ?? "") {
                try execute(
                    "INSERT OR REPLACE INTO personal_category_delta VALUES (?, ?, ?, ?, ?)",
                    [owner, targetID, categoryID, decision.string!, revision.itemID])
            }
            for (categoryID, decision) in revision.fields["personalOverrides"]?.map ?? [:]
            where decision.string == "include" {
                try execute(
                    "INSERT OR IGNORE INTO category_include_candidates VALUES (?, ?, ?)",
                    [categoryID, targetID, revision.itemID])
            }
        }
    }

    func relatedCategoryIDs(startingAt roots: Set<String>, limit: Int = 4_096) throws -> Set<String> {
        var seen = roots
        var pending = Array(roots)
        while let id = pending.popLast() {
            let statement = try prepare(
                "SELECT target_id FROM category_edges WHERE source_id=? ", [id])
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    sqlite3_finalize(statement)
                    throw error()
                }
                if let raw = sqlite3_column_text(statement, 0) {
                    let next = String(cString: raw)
                    if seen.insert(next).inserted {
                        guard seen.count <= limit else {
                            sqlite3_finalize(statement)
                            throw TractandaError(
                                "resourceLimit", "Relevant category graph exceeds its bounded closure.")
                        }
                        pending.append(next)
                    }
                }
            }
            sqlite3_finalize(statement)
        }
        return seen
    }

    func forEachPersonalOwnerName(_ body: (String) throws -> Void) throws {
        let statement = try prepare(
            "SELECT DISTINCT owner_name FROM personal_overlay_targets ORDER BY owner_name")
        do {
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { throw error() }
                try body(String(cString: raw))
            }
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        sqlite3_finalize(statement)
    }

    func forEachPersonalDeltaTarget(
        categoryIDs: Set<String>, ownerNames: Set<String>, _ body: (String) throws -> Void
    ) throws {
        try forEachPersonalLookup(
            select: "DISTINCT target_id", categoryIDs: categoryIDs, ownerNames: ownerNames,
            targetID: nil, body)
    }

    func forEachPersonalOverlayID(
        targetID: String, ownerNames: Set<String>, _ body: (String) throws -> Void
    ) throws {
        guard !ownerNames.isEmpty else { return }
        let owners = ownerNames.sorted()
        for offset in stride(from: 0, to: owners.count, by: 300) {
            let batch = Array(owners[offset..<min(offset + 300, owners.count)])
            let statement = try prepare(
                "SELECT source_id FROM personal_overlay_targets WHERE target_id=? AND owner_name IN "
                    + "(\(Array(repeating: "?", count: batch.count).joined(separator: ",")))",
                [targetID] + batch)
            do {
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
                        throw error()
                    }
                    try body(String(cString: raw))
                }
            } catch {
                sqlite3_finalize(statement)
                throw error
            }
            sqlite3_finalize(statement)
        }
    }

    private func forEachPersonalLookup(
        select: String, categoryIDs: Set<String>, ownerNames: Set<String>, targetID: String?,
        _ body: (String) throws -> Void
    ) throws {
        guard !ownerNames.isEmpty else { return }
        let owners = ownerNames.sorted()
        for ownerOffset in stride(from: 0, to: owners.count, by: 300) {
            let ownerBatch = Array(owners[ownerOffset..<min(ownerOffset + 300, owners.count)])
            let categories = categoryIDs.sorted()
            let categoryChunks =
                categories.isEmpty
                ? [[]]
                : stride(from: 0, to: categories.count, by: 400).map {
                    Array(categories[$0..<min($0 + 400, categories.count)])
                }
            for categoryBatch in categoryChunks {
                var clauses = [
                    "owner_name IN (\(Array(repeating: "?", count: ownerBatch.count).joined(separator: ",")))"
                ]
                var bindings = ownerBatch
                if let targetID {
                    clauses.append("target_id=?")
                    bindings.append(targetID)
                }
                if !categoryBatch.isEmpty {
                    clauses.append(
                        "category_id IN (\(Array(repeating: "?", count: categoryBatch.count).joined(separator: ",")))"
                    )
                    bindings.append(contentsOf: categoryBatch)
                }
                let statement = try prepare(
                    "SELECT \(select) FROM personal_category_delta WHERE \(clauses.joined(separator: " AND "))",
                    bindings)
                do {
                    while true {
                        let status = sqlite3_step(statement)
                        if status == SQLITE_DONE { break }
                        guard status == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
                            throw error()
                        }
                        try body(String(cString: raw))
                    }
                } catch {
                    sqlite3_finalize(statement)
                    throw error
                }
                sqlite3_finalize(statement)
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

    func categoryDecisionCandidateIDs(categoryIDs: Set<String>) throws -> Set<String> {
        guard !categoryIDs.isEmpty else { return [] }
        var result = Set<String>()
        let ordered = categoryIDs.sorted()
        for offset in stride(from: 0, to: ordered.count, by: 400) {
            let batch = Array(ordered[offset..<min(offset + 400, ordered.count)])
            let statement = try prepare(
                "SELECT DISTINCT target_id FROM category_decision_candidates WHERE category_id IN "
                    + "(\(Array(repeating: "?", count: batch.count).joined(separator: ",")))", batch)
            defer { sqlite3_finalize(statement) }
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { throw error() }
                result.insert(String(cString: raw))
                guard result.count <= 4_096 else {
                    throw TractandaError(
                        "resourceLimit", "Manual category candidates exceed the bounded working set.")
                }
            }
        }
        return result
    }

    private func candidateSQL(_ plan: SpotlightQuery.IndexCandidatePlan) -> (String, [String]) {
        switch plan {
        case .all: return ("1", [])
        case .and(let left, let right), .or(let left, let right):
            let a = candidateSQL(left)
            let b = candidateSQL(right)
            let join = {
                if case .and = plan { return " AND " }
                return " OR "
            }()
            return ("(\(a.0)\(join)\(b.0))", a.1 + b.1)
        case .categoryIncludes(let categoryIDs):
            guard !categoryIDs.isEmpty else { return ("0", []) }
            let ids = categoryIDs.sorted()
            return (
                "items.id IN (SELECT target_id FROM category_include_candidates WHERE category_id IN "
                    + "(\(Array(repeating: "?", count: ids.count).joined(separator: ","))))",
                ids
            )
        case .categoryDecisions(let categoryIDs):
            guard !categoryIDs.isEmpty else { return ("0", []) }
            let ids = categoryIDs.sorted()
            return (
                "items.id IN (SELECT target_id FROM category_decision_candidates WHERE category_id IN "
                    + "(\(Array(repeating: "?", count: ids.count).joined(separator: ","))))",
                ids
            )
        case .personalCategoryDeltas(let categoryIDs):
            guard !categoryIDs.isEmpty else { return ("0", []) }
            let ids = categoryIDs.sorted()
            return (
                "items.id IN (SELECT target_id FROM personal_category_delta WHERE category_id IN "
                    + "(\(Array(repeating: "?", count: ids.count).joined(separator: ","))))",
                ids
            )
        case .savedViewBase(let viewID):
            return (
                "items.id IN (SELECT item_id FROM saved_view_base WHERE view_id=?)", [viewID]
            )
        case .atom(let atom):
            if atom.kind == "exists" {
                let op = atom.operation == "==" ? "IN" : "NOT IN"
                return (
                    "items.id \(op) (SELECT p.item_id FROM field_presence p WHERE p.field=?)",
                    [atom.field]
                )
            }
            if atom.field == "itemID" { return ("items.id = ?", [atom.value]) }
            if ["createdAt", "modifiedAt"].contains(atom.field),
                atom.kind == "date" || atom.kind.isEmpty,
                ["==", "!=", "<", "<=", ">", ">="].contains(atom.operation)
            {
                let column = atom.field == "createdAt" ? "items.created" : "items.modified"
                let sqlOp = atom.operation == "==" ? "=" : atom.operation
                return ("\(column) \(sqlOp) ?", [atom.value])
            }
            if atom.operation == "!=" {
                return (
                    "items.id IN (SELECT p.item_id FROM field_presence p WHERE p.field=?)",
                    [atom.field]
                )
            }
            let op = atom.operation == "==" ? "=" : atom.operation
            switch atom.kind {
            case "boolean":
                return (
                    "items.id IN (SELECT s.item_id FROM scalar_value s WHERE s.field=? AND s.type='boolean' AND s.bool_value \(op) CAST(? AS INTEGER))",
                    [atom.field, atom.value]
                )
            case "integer", "real", "date":
                guard ["=", "<", "<=", ">", ">="].contains(op) else { return ("1", []) }
                // The Swift evaluator compares two Int64 values exactly. Mixed Int64/REAL
                // or Int64/date comparisons use Double; for a noninteger literal every
                // integer remains a safe candidate rather than risking a rounded bound.
                let integer: (String, [String])
                if atom.kind == "integer" {
                    integer = (
                        "SELECT s.item_id FROM scalar_value s WHERE s.field=? AND s.type='integer' AND s.int_value \(op) CAST(? AS INTEGER)",
                        [atom.field, atom.value]
                    )
                } else {
                    integer = (
                        "SELECT s.item_id FROM scalar_value s WHERE s.field=? AND s.type='integer'",
                        [atom.field]
                    )
                }
                // SQLite's decimal-to-REAL conversion need not use the same rounding
                // path as Swift's Int64-to-Double conversion. Keep all cross-type rows
                // for an integer literal; the original Swift predicate remains exact.
                let real: (String, [String])
                let date: (String, [String])
                if atom.kind == "integer" {
                    real = (
                        "SELECT s.item_id FROM scalar_value s WHERE s.field=? AND s.type='real'",
                        [atom.field]
                    )
                    date = (
                        "SELECT s.item_id FROM scalar_value s WHERE s.field=? AND s.type='date'",
                        [atom.field]
                    )
                } else {
                    real = (
                        "SELECT s.item_id FROM scalar_value s WHERE s.field=? AND s.type='real' AND s.real_value \(op) CAST(? AS REAL)",
                        [atom.field, atom.value]
                    )
                    date = (
                        "SELECT s.item_id FROM scalar_value s WHERE s.field=? AND s.type='date' AND s.date_value \(op) CAST(? AS REAL)",
                        [atom.field, atom.value]
                    )
                }
                return (
                    "items.id IN (\(integer.0) UNION ALL \(real.0) UNION ALL \(date.0))",
                    integer.1 + real.1 + date.1
                )
            default: return ("1", [])
            }
        }
    }

    private func itemSource(
        lexicalText: String?, classEquals: String?,
        candidatePlan: SpotlightQuery.IndexCandidatePlan, aclUserID: UInt32? = nil,
        includeDeleted: Bool = false, savedViewID: String? = nil
    ) -> (sql: String, arguments: [String]) {
        var joins =
            aclUserID == nil
            ? " FROM items"
            : " FROM (\(aclAuthorizedIDs)) acl_visible CROSS JOIN items ON items.id=acl_visible.item_id"
        var predicates = includeDeleted ? ["1"] : ["items.deleted = 0"]
        var arguments: [String] = []
        if let lexicalText {
            joins += " JOIN text_index ON text_index.id = items.id"
            predicates.append("text_index MATCH ?")
            arguments.append("\"" + lexicalText.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
        }
        if let classEquals {
            predicates.append("items.class = ?")
            arguments.append(classEquals)
        }
        if let savedViewID {
            predicates.append(
                "(NOT EXISTS (SELECT 1 FROM saved_view_targets v WHERE v.id=? AND v.state='ready' "
                    + "AND instr(v.selection,'\"expression\"')>0 AND v.class_filter='') "
                    + "OR items.id IN (SELECT b.item_id FROM saved_view_base b WHERE b.view_id=?))"
            )
            arguments += [savedViewID, savedViewID]
        }
        let candidate = candidateSQL(candidatePlan)
        predicates.append(candidate.0)
        arguments += candidate.1
        if aclUserID != nil {
            predicates.append(aclReadPredicate)
        }
        return (joins + " WHERE " + predicates.joined(separator: " AND "), arguments)
    }

    func pooledQuerySource(
        classEquals: String?, candidatePlan: SpotlightQuery.IndexCandidatePlan, aclUserID: UInt32?
    ) -> (sql: String, arguments: [String]) {
        itemSource(
            lexicalText: nil, classEquals: classEquals, candidatePlan: candidatePlan,
            aclUserID: aclUserID)
    }

    /// Diagnostic evidence for the typed candidate path; this executes no query rows.
    func candidateQueryPlan(_ plan: SpotlightQuery.IndexCandidatePlan) throws -> [String] {
        let source = itemSource(lexicalText: nil, classEquals: nil, candidatePlan: plan)
        let statement = try prepare("EXPLAIN QUERY PLAN SELECT items.id" + source.sql, source.arguments)
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return details }
            guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 3) else {
                throw error()
            }
            details.append(String(cString: value))
        }
    }

    func seekQueryPlan(
        order: IndexedOrder, classEquals: String?, candidatePlan: SpotlightQuery.IndexCandidatePlan
    ) throws -> [String] {
        let source = itemSource(lexicalText: nil, classEquals: classEquals, candidatePlan: candidatePlan)
        let column = order.column
        let statement = try prepare(
            "EXPLAIN QUERY PLAN SELECT items.id" + source.sql
                + " AND (items.\(column) < ? OR (items.\(column) = ? AND items.id > ?))"
                + " ORDER BY items.\(column) DESC, items.id ASC LIMIT ?",
            source.arguments + ["1", "1", "00000000-0000-1000-8000-000000000001", "16"])
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return details }
            guard status == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 3) else { throw error() }
            details.append(String(cString: pointer))
        }
    }

    func aclQueryPlan(actorUID: UInt32) throws -> [String] {
        let source = itemSource(lexicalText: nil, classEquals: nil, candidatePlan: .all, aclUserID: actorUID)
        let statement = try prepare(
            "EXPLAIN QUERY PLAN SELECT items.id" + source.sql + " ORDER BY items.modified DESC, items.id",
            source.arguments)
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return details }
            guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 3) else { throw error() }
            details.append(String(cString: value))
        }
    }

    /// Returns nil as soon as the caller would admit one more than the bounded number
    /// of readable rows. It deliberately has no SQL LIMIT because authorization can
    /// reject any number of earlier index rows.
    func boundedCandidateIDs(
        restrictions: [SpotlightQuery.IndexCandidateRestriction], maximumReadable: Int,
        accepts: (String) throws -> Bool
    ) throws -> [String]? {
        precondition(maximumReadable >= 0)
        let legacyPlan: SpotlightQuery.IndexCandidatePlan = restrictions.reversed().reduce(.all) {
            result, item in
            let atom = SpotlightQuery.IndexCandidatePlan.atom(item)
            return result.isAll ? atom : .and(result, atom)
        }
        let source = itemSource(lexicalText: nil, classEquals: nil, candidatePlan: legacyPlan)
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
        fastCount: Bool, candidatePlan: SpotlightQuery.IndexCandidatePlan = .all,
        aclUserID: UInt32? = nil, savedViewID: String? = nil,
        accepts: (String) throws -> Bool
    ) throws -> Page {
        let itemSource = itemSource(
            lexicalText: lexicalText, classEquals: classEquals,
            candidatePlan: candidatePlan, aclUserID: aclUserID, savedViewID: savedViewID)
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

    /// Range-seeks a covered order from a typed boundary. The cursor never supplies a SQL
    /// fragment; only the fixed indexed column and a server-validated timestamp are bound.
    func orderedSeekPage(
        lexicalText: String?, classEquals: String?, order: IndexedOrder, boundary: Double,
        boundaryID: String, previous: Bool, limit: Int, fastCount: Bool,
        knownTotal: Int? = nil,
        exactPredicate: Bool = true,
        candidatePlan: SpotlightQuery.IndexCandidatePlan = .all, aclUserID: UInt32? = nil,
        accepts: (String) throws -> Bool
    ) throws -> SeekPage {
        let itemSource = itemSource(
            lexicalText: lexicalText, classEquals: classEquals,
            candidatePlan: candidatePlan, aclUserID: aclUserID)
        let column = order.column
        let comparison = previous ? ">" : "<"
        let tie = previous ? "<" : ">"
        let predicate = "(items.\(column) \(comparison) ? OR (items.\(column) = ? AND items.id \(tie) ?))"
        var total: Int
        if let knownTotal {
            total = knownTotal
        } else if fastCount {
            let countStatement = try prepare("SELECT COUNT(*)" + itemSource.sql, itemSource.arguments)
            defer { sqlite3_finalize(countStatement) }
            guard sqlite3_step(countStatement) == SQLITE_ROW else { throw error() }
            total = Int(sqlite3_column_int64(countStatement, 0))
            guard sqlite3_step(countStatement) == SQLITE_DONE else { throw error() }
        } else {
            let countStatement = try prepare("SELECT items.id" + itemSource.sql, itemSource.arguments)
            defer { sqlite3_finalize(countStatement) }
            total = 0
            while true {
                let status = sqlite3_step(countStatement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let pointer = sqlite3_column_text(countStatement, 0) else {
                    throw error()
                }
                if try accepts(String(cString: pointer)) { total += 1 }
            }
        }
        let direction = previous ? "ASC" : "DESC"
        let tieDirection = previous ? "DESC" : "ASC"
        let limitBeforeResidual = fastCount && exactPredicate
        let limitClause = limitBeforeResidual ? " LIMIT ?" : ""
        let pageArguments =
            itemSource.arguments + [String(boundary), String(boundary), boundaryID]
            + (limitBeforeResidual ? [String(limit)] : [])
        let statement = try prepare(
            "SELECT items.id" + itemSource.sql + " AND " + predicate
                + " ORDER BY items.\(column) \(direction), items.id \(tieDirection)" + limitClause,
            pageArguments)
        defer {
            seekVMInstructionsForTesting += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
            sqlite3_finalize(statement)
        }
        var ids: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else { throw error() }
            let id = String(cString: pointer)
            if try accepts(id) {
                ids.append(id)
                if !limitBeforeResidual && ids.count == limit { break }
            }
        }
        if previous { ids.reverse() }
        return SeekPage(ids: ids, total: total)
    }

    func resetSeekVMInstructionsForTesting() { seekVMInstructionsForTesting = 0 }
    func savedViewIsReady(id: String) throws -> Bool {
        let statement = try prepare(
            "SELECT t.state,c.state,c.definition_hash FROM saved_view_targets t "
                + "JOIN saved_view_coverage c ON c.view_id=t.id WHERE t.id=?", [id])
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return false }
        guard status == SQLITE_ROW, let targetState = sqlite3_column_text(statement, 0),
            let coverageState = sqlite3_column_text(statement, 1),
            let hash = sqlite3_column_text(statement, 2)
        else { throw error() }
        return String(cString: targetState) == "ready" && String(cString: coverageState) == "ready"
            && !String(cString: hash).isEmpty
    }
    func savedViewCategorySelectionMatches(
        id: String, expression: String?, text: String?, categoryPath: [String],
        excludedCategoryIDs: [String], sort: [ItemSort]
    ) throws -> Bool {
        let statement = try prepare("SELECT selection FROM saved_view_targets WHERE id=?", [id])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let bytes = sqlite3_column_text(statement, 0)
        else { return false }
        let selection = try JSON.decode(
            [String: ItemValue].self,
            Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        let path: ItemValue = .list(categoryPath.map(ItemValue.text))
        let exclusions: ItemValue = .list(excludedCategoryIDs.map(ItemValue.text))
        let ordering: ItemValue = .list(sort.map(\.value))
        return selection["categoryPath"] == path
            && selection["excludedCategoryIDs"] == exclusions
            && selection["sort"] == ordering
            && selection["expression"]?.string == expression
            && selection["text"]?.string == text
    }
    func savedViewBaseIDsForTesting(id: String) throws -> Set<String> {
        let statement = try prepare("SELECT item_id FROM saved_view_base WHERE view_id=?", [id])
        defer { sqlite3_finalize(statement) }
        var ids = Set<String>()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return ids }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else {
                throw error()
            }
            ids.insert(String(cString: bytes))
        }
    }
    func savedViewStagedIDsForTesting(id: String) throws -> Set<String> {
        let statement = try prepare("SELECT item_id FROM saved_view_staging WHERE view_id=?", [id])
        defer { sqlite3_finalize(statement) }
        var ids = Set<String>()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return ids }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else {
                throw error()
            }
            ids.insert(String(cString: bytes))
        }
    }
    func candidateIDs(_ plan: SpotlightQuery.IndexCandidatePlan) throws -> Set<String> {
        guard !plan.isAll else { return [] }
        let candidate = candidateSQL(plan)
        let statement = try prepare(
            "SELECT items.id FROM items WHERE items.deleted=0 AND " + candidate.0, candidate.1)
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw error() }
            result.insert(String(cString: text))
        }
    }
    func ids(
        lexicalText: String? = nil, restrictingTo restrictedIDs: Set<String>? = nil,
        candidatePlan: SpotlightQuery.IndexCandidatePlan = .all
    ) throws -> [String] {
        let plannedIDs = try candidateIDs(candidatePlan)
        let effectiveIDs: Set<String>?
        if candidatePlan.isAll {
            effectiveIDs = restrictedIDs
        } else if let restrictedIDs {
            effectiveIDs = restrictedIDs.intersection(plannedIDs)
        } else {
            effectiveIDs = plannedIDs
        }
        let restrictedIDs = effectiveIDs
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

    /// Visits candidate IDs in deterministic order without retaining the catalogue-sized
    /// ID array. Restrictions are a safe caller-computed superset and are checked per row.
    func forEachCandidateID(
        lexicalText: String?, restrictingTo restrictedIDs: Set<String>?,
        candidatePlan: SpotlightQuery.IndexCandidatePlan, includeDeleted: Bool = false,
        order: IndexedOrder? = nil, savedViewID: String? = nil,
        _ body: (String) throws -> Void
    ) throws {
        let source = itemSource(
            lexicalText: lexicalText, classEquals: nil, candidatePlan: candidatePlan,
            includeDeleted: includeDeleted, savedViewID: savedViewID)
        let ordering: String
        switch order {
        case .modifiedAt: ordering = "items.modified DESC, items.id ASC"
        case .createdAt: ordering = "items.created DESC, items.id ASC"
        case nil: ordering = "items.id ASC"
        }
        let statement = try prepare(
            "SELECT items.id" + source.sql + " ORDER BY " + ordering, source.arguments)
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw error() }
            let id = String(cString: value)
            if restrictedIDs == nil || restrictedIDs!.contains(id) { try body(id) }
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
