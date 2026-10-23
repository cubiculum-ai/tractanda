import CSQLite
import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ItemIndex {
    static let catalogueSchemaVersion = "20"
    static let catalogueEngine = "tractanda-sqlite-catalogue-v18"
    static let catalogueRowByteWindow = 8 * 1024 * 1024 + 4096
    static let cataloguePageByteWindow = catalogueRowByteWindow
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
        let modifiedAt: String
        let provenance: RevisionProvenance?

        init(
            revisionID: String, itemID: String, path: String, parentID: String?, actor: String,
            operationID: String, size: UInt64, inode: UInt64, uid: UInt32, mode: UInt32,
            modificationSeconds: Int64, modificationNanoseconds: Int32, digest: Data,
            createdAt: String = "", feedbackRevisionIDs: [String] = [], modifiedAt: String = "",
            provenance: RevisionProvenance? = nil
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
            self.modifiedAt = modifiedAt
            self.provenance = provenance
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
    let corpusIndexPath: String
    private var database: OpaquePointer?
    private let createdForConstruction: Bool
    private var atomicCanonicalReconstruction = false
    private var activeCatalogueScanBudget: CatalogueScanBudget?
    var onPersistentFailure: (() -> Void)?
    static func shouldQuarantineSQLiteFailure(_ code: Int32) -> Bool {
        ![SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT, SQLITE_NOMEM, SQLITE_TOOBIG, SQLITE_FULL]
            .contains(code)
    }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var corpusGCStatsForTesting = IndexCorpusGCStats()
    var afterCorpusReadCommitForTesting: (() throws -> Void)?
    var graphReserveBytes: UInt64 = 1024 * 1024 * 1024
    var graphMaximumTemporaryBytes: UInt64 = 256 * 1024 * 1024
    var graphMaximumVMInstructions: Int64 = 200_000_000
    var graphMaximumPageBytes = ItemIndex.cataloguePageByteWindow
    var revisionProjectionActive = false
    var currentProjectionSchemaReady = false
    var projectionAppendActive = false
    var authorityControlSchemaReady = false
    /// Queue-confined borrow, present only inside a complete canonical-to-staged finalization.
    var activeAtomicControlFinalization: AuthorityBinding?
    private var atomicAcceptedStepError: TractandaError?
    private var atomicAcceptedActivation: (root: AuthorityBinding, context: String, receipt: String)?
    /// Trusted post-seal phase only. Structural comparison alone never enables this classification.
    func withAtomicAcceptedActivation<T>(
        plan: AuthorityStore.VerifiedAtomicControlPlan,
        sealed: AtomicAuthorityAcceptance.Sealed, _ body: () throws -> T
    ) throws -> T {
        guard plan.reconstruction == nil || atomicCanonicalReconstruction else {
            throw AtomicAuthorityFormat.invalid("Historical activation cannot run on a serving Index.")
        }
        let acceptedContext = try plan.acceptanceContextSHA256(sealed)
        guard activeAtomicControlFinalization == plan.binding,
            sealed.receipt.root == plan.binding,
            sealed.receipt.validationContextSHA256 == acceptedContext,
            atomicAcceptedActivation == nil
        else {
            throw AtomicAuthorityFormat.invalid("Atomic activation lacks exact validated accepted proof.")
        }
        // The immutable decision has already passed private, charged work windows. Its local
        // durable activation is not another network-sized logical-root budget: each SQLite step
        // below owns a bounded native allowance, while the enclosing caller keeps its exact tail.
        guard let database else { throw graphSQLiteError() }
        let enclosing = activeCatalogueScanBudget
        try enclosing?.requireAvailable()
        activeCatalogueScanBudget = nil
        sqlite3_progress_handler(database, 0, nil, nil)
        atomicAcceptedStepError = nil
        atomicAcceptedActivation = (plan.binding, acceptedContext, sealed.bytesSHA256)
        defer {
            atomicAcceptedActivation = nil
            atomicAcceptedStepError = nil
            activeCatalogueScanBudget = enclosing
            if let enclosing {
                sqlite3_progress_handler(
                    database, Int32(enclosing.quantum), catalogueScanProgress,
                    Unmanaged.passUnretained(enclosing).toOpaque())
            }
        }
        return try body()
    }
    /// Queue-confined borrow of the completed original-PRE closure during final Store activation.
    /// It is released before its private work closes; accepted facts never retain this callback.
    var activeAtomicOriginalPREContains: ((AuthorityBinding) throws -> Bool)?
    private var installedAtomicAuthoritySchemas: Set<AtomicAuthorityIndexSchema.Slice> = []
    var atomicPublicationSpoolActive = false
    private var atomicStageMutationGeneration: UInt64 = 0
    private var atomicStageMutationOverflow = false
    private var frozenAtomicStage: AtomicStageFreeze?
    struct AtomicStageFreeze {
        fileprivate let id: String
        let root: AuthorityBinding
        fileprivate let generation: UInt64
        fileprivate let dataVersion: Int64
    }
    var lastAnalyzedProjection: RevisionProjection.Snapshot?
    var admittedProjectionCheckpointWatermark: Int64?
    private var validatedGraphWatermark: Int64?
    private var validatedGraphAllowsOnlyLinear = false
    private(set) var graphValidationPassesForTesting = 0
    private(set) var lastCatalogueScanWorkForTesting: Int64 = 0
    var atomicRemainingScanWorkForTesting: Int64? { activeCatalogueScanBudget?.remaining }
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
                "INSERT INTO text_snapshot (id, subject, body, metadata) VALUES (?, ?, ?, ?)",
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
    enum JournalMode: String { case wal, delete }
    init(path: String, create: Bool, noFollow: Bool = false, journalMode: JournalMode = .wal) throws {
        corpusIndexPath = path
        createdForConstruction = create
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | (noFollow ? SQLITE_OPEN_NOFOLLOW : 0)
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK
        else {
            if let database { sqlite3_close(database) }
            database = nil
            throw TractandaError("indexError", "Cannot open disposable SQLite index.")
        }
        sqlite3_busy_timeout(database, 3000)
        if path != ":memory:" {
            do {
                try configureWriter(journalMode: journalMode)
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
                "CREATE TABLE text_snapshot (id TEXT PRIMARY KEY,subject TEXT NOT NULL,body TEXT NOT NULL,metadata TEXT NOT NULL)"
            )
            try createCorpusTables()
            try execute("CREATE TABLE checkpoint_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute(
                "CREATE TABLE revision_catalog (revision TEXT PRIMARY KEY, item TEXT NOT NULL, path TEXT NOT NULL, parent TEXT, actor TEXT NOT NULL, operation TEXT NOT NULL, size INTEGER NOT NULL, inode INTEGER NOT NULL, uid INTEGER NOT NULL, mode INTEGER NOT NULL, mtime_seconds INTEGER NOT NULL, mtime_nanoseconds INTEGER NOT NULL, digest TEXT NOT NULL, created_at TEXT NOT NULL, modified_at TEXT NOT NULL, provenance TEXT, modified_ticks INTEGER)"
            )
            try execute("CREATE INDEX revision_catalog_item ON revision_catalog(item, revision)")
            try execute(
                "CREATE INDEX revision_catalog_operation ON revision_catalog(actor, operation)")
            try execute("CREATE UNIQUE INDEX revision_catalog_path ON revision_catalog(path)")
            try execute(
                "CREATE INDEX revision_catalog_parent ON revision_catalog(item,parent) WHERE parent IS NOT NULL"
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
            try createRevisionGraphTables()
        }
        if !create {
            // No old-schema shim: rebuilding preserves canonical items and constructs this disposable projection.
            try execute("SELECT encoded_bytes,owner_work_id FROM corpus_generation LIMIT 0")
            try execute("SELECT generation_id FROM corpus_gc_candidate LIMIT 0")
            try execute("SELECT status,dirty FROM current_projection LIMIT 0")
            currentProjectionSchemaReady = true
        }
        // Request-local authorization state belongs to each connection, including
        // reopened read-only connections; TEMP writes do not mutate the main catalogue.
        try execute("CREATE TEMP TABLE request_users (name TEXT PRIMARY KEY, uid INTEGER NOT NULL)")
        try execute(
            "CREATE TEMP TABLE request_groups (name TEXT PRIMARY KEY, gid INTEGER NOT NULL, member INTEGER NOT NULL)"
        )
        try execute("CREATE TEMP TABLE request_actor (uid INTEGER NOT NULL)")
        sqlite3_update_hook(
            database,
            { context, _, _, name, _ in
                guard let context, let name else { return }
                if strcmp(name, "authority_atomic_stage") == 0
                    || strcmp(name, "authority_atomic_parent_stage") == 0
                    || strcmp(name, "authority_atomic_support_stage") == 0
                {
                    Unmanaged<ItemIndex>.fromOpaque(context).takeUnretainedValue().noteAtomicStageMutation()
                }
            }, Unmanaged.passUnretained(self).toOpaque())
    }
    deinit {
        if let database {
            sqlite3_update_hook(database, nil, nil)
            sqlite3_close_v2(database)
        }
    }
    func close() {
        try? closeChecked()
    }
    func closeChecked() throws {
        guard let database else { return }
        let status = sqlite3_close(database)
        guard status == SQLITE_OK else { throw error() }
        self.database = nil
    }
    private func configureWriter(journalMode: JournalMode) throws {
        guard let database else { throw TractandaError("indexError", "Index closed.") }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, "PRAGMA journal_mode=" + journalMode.rawValue, -1, &statement, nil)
                == SQLITE_OK,
            let statement
        else { throw error() }
        guard catalogueStep(statement) == SQLITE_ROW,
            let mode = sqlite3_column_text(statement, 0),
            String(cString: mode).lowercased() == journalMode.rawValue
        else {
            sqlite3_finalize(statement)
            throw TractandaError("indexError", "SQLite did not enable its selected journal mode.")
        }
        sqlite3_finalize(statement)
        try execute("PRAGMA synchronous=FULL")
        if journalMode == .wal { try execute("PRAGMA wal_autocheckpoint=1000") }
        var syncStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA synchronous", -1, &syncStatement, nil) == SQLITE_OK,
            let syncStatement
        else { throw error() }
        guard catalogueStep(syncStatement) == SQLITE_ROW,
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
        guard catalogueStep(statement) == SQLITE_ROW else { throw error() }
        return sqlite3_column_int(statement, 0)
    }
    func holdStatementForTesting() throws -> OpaquePointer {
        try prepare("SELECT 1")
    }
    /// Internal same-executor bridge for the corpus projection; never exported in a capability.
    func corpusPrepare(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        try prepare(sql, values)
    }
    private func prepare(_ sql: String, _ bindings: [String] = []) throws -> OpaquePointer {
        try activeCatalogueScanBudget?.requireAvailable()
        let tokens = sql.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let verb = tokens.first ?? ""
        let target: String?
        switch verb {
        case "insert", "replace":
            target = tokens.firstIndex(of: "into").flatMap { position in
                position + 1 < tokens.count ? tokens[position + 1] : nil
            }
        case "update": target = tokens.count > 1 ? tokens[1] : nil
        case "delete": target = tokens.count > 2 && tokens[1] == "from" ? tokens[2] : nil
        case "create", "drop", "alter":
            if let position = tokens.firstIndex(where: { ["table", "index"].contains($0) }) {
                target = tokens.dropFirst(position + 1).first {
                    !["if", "not", "exists"].contains($0)
                }
            } else {
                target = nil
            }
        default: target = nil
        }
        let targetTable = target?.split(separator: "(", maxSplits: 1).first.map(String.init)
        if frozenAtomicStage != nil,
            !["select", "explain", "savepoint", "release", "rollback", "begin", "commit", "end"].contains(
                verb),
            targetTable == nil
                || [
                    "authority_atomic_stage", "authority_atomic_parent_stage",
                    "authority_atomic_support_stage",
                ].contains(targetTable!)
        {
            throw TractandaError("storeBusy", "The exact atomic stage is frozen for canonical comparison.")
        }
        let projectionTargets: Set<String> = [
            "peer_original_required", "peer_original_present", "peer_original_revision", "peer_original_text",
            "temp.peer_original_required", "temp.peer_original_present", "temp.peer_original_revision",
            "temp.peer_original_text",
            "peer_original_document", "peer_original_document_present",
            "temp.peer_original_document", "temp.peer_original_document_present",
            "peer_original_item", "temp.peer_original_item",
            "peer_inventory_state", "peer_inventory_receipt", "authority_atomic_publication_spool",
            "peer_export_plan", "peer_export_object", "peer_export_ready", "peer_export_page",
            "peer_document_work", "peer_document_part", "peer_document_corpus_owner",
            "peer_document_corpus_work",
            "peer_lifecycle_retired", "peer_lifecycle_cutoff", "peer_lifecycle_decision",
            "peer_lifecycle_effect", "peer_lifecycle_recheck",
            "authority_origin_issued", "authority_kind",
            "authority_review_event", "authority_review_target", "authority_review_edge",
            "authority_review_children", "authority_review_head", "authority_review_applied",
            "authority_review_resolution", "authority_review_item",
            "rp_nodes", "rp_node_order", "rp_segments", "rp_writes", "rp_frontier", "rp_scope",
            "rp_fields", "rp_memo", "rp_origins", "rp_lookup", "rp_lookup_order", "rp_seen", "rp_ready",
            "recovery_ordinals", "recovery_heads", "recovery_graph_work", "recovery_ready",
            "recovery_roots", "recovery_item_progress", "recovery_forks", "recovery_reach_seen",
            "recovery_reach_ready",
            "current_projection", "current_policy", "projection_acl", "projection_acl_named",
            "projection_principal_counts", "request_users", "request_groups", "request_actor",
            "checkpoint_meta", "corpus_index_identity", "page_text_index", "text_index",
            "acl_principal_counts",
            "document_owners", "attachment_owners",
            "items", "head_summaries", "field_presence", "scalar_value", "acl_named", "acl_core",
            "text_snapshot", "corpus_head", "corpus_link", "corpus_generation", "corpus_work",
            "corpus_work_generation", "corpus_unit", "corpus_span", "corpus_gc_candidate", "corpus_gc_cursor",
            "saved_view_targets", "saved_view_dependencies", "saved_view_coverage", "saved_view_staging",
            "saved_view_build_state", "saved_view_base", "category_include_candidates",
            "category_decision_candidates",
            "category_edges", "personal_category_delta", "personal_overlay_targets",
            "authority_original_receipts", "authority_objects", "authority_packages",
            "authority_dispositions", "authority_dependencies",
            "authority_evidence_target", "authority_packages_object", "authority_dependencies_reverse",
            "authority_ready_status", "authority_walk", "authority_package_pending",
            "authority_objects_path", "authority_objects_kind_id",
            "authority_evidence_binding", "authority_object_receipts",
            "authority_pending_effect", "authority_retired_items", "authority_control_pending",
            "authority_control_pending_package",
            "authority_control_pending_ready", "authority_control_pending_object",
            "authority_reconciliation_witness", "authority_reconciliation_recovery", "authority_absorbed",
            "authority_absorbed_cut",
            "authority_invalidation",
            "authority_invalidation_item", "authority_objects_item",
            "authority_control", "authority_control_origin", "authority_control_heads",
            "authority_control_edges",
            "authority_control_children", "authority_control_delta", "authority_control_target",
            "authority_atomic_stage", "authority_atomic_parent_stage", "authority_atomic_support_stage",
            "authority_control_affected", "authority_control_work", "authority_control_work_order",
            "authority_exposure", "authority_exposure_order", "authority_reconciliation",
            "authority_exposure_revision", "authority_local_exposure", "authority_local_exposure_order",
            "authority_local_exposure_revision", "authority_local_visibility_work",
            "authority_local_acceptance", "authority_local_assessment", "authority_local_bootstrap",
            "authority_local_history", "authority_local_history_order",
            "peer_origin_reconsideration",
        ]
        let readOrControl = [
            "select", "explain", "savepoint", "release", "rollback", "begin", "commit", "end",
        ]
        // The canonical catalogue audit uses this exact read-only pragma. All other
        // pragma syntax retains the conservative fallback, including unknown queries.
        let readOnlyIntegrityAudit = bindings.isEmpty && tokens == ["pragma", "integrity_check"]
        let exactAtomicAcceptedInsert =
            atomicAcceptedActivation.map { activation in
                verb == "insert"
                    && [
                        "authority_control_support", "authority_atomic_outcome", "authority_atomic_accepted",
                    ].contains(targetTable ?? "")
                    && (sql.hasPrefix("INSERT INTO " + (targetTable ?? "") + " VALUES(")
                        || sql.hasPrefix("INSERT OR IGNORE INTO " + (targetTable ?? "") + " VALUES("))
                    && bindings.count >= 2 && bindings[0] == activation.root.recordID
                    && bindings[1] == activation.root.sha256
            } ?? false
        if !readOrControl.contains(verb),
            !readOnlyIntegrityAudit, !exactAtomicAcceptedInsert,
            targetTable == nil || !projectionTargets.contains(targetTable!)
        {
            // Only our explicitly known work targets retain proof. Unsupported syntax,
            // including CTE mutations/quoted targets, conservatively invalidates it.
            invalidateRevisionGraphValidation()
            if currentProjectionSchemaReady, !projectionAppendActive {
                try execute("DELETE FROM checkpoint_meta WHERE key='graphAdmissionProof'")
                try execute("UPDATE current_projection SET dirty=1")
            }
        }
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
        if let atomicAcceptedStepError { return atomicAcceptedStepError }
        if let budget = activeCatalogueScanBudget {
            if let callbackError = budget.callbackError {
                return callbackError as? TractandaError
                    ?? TractandaError("indexTransient", "Catalogue control interrupted a query.")
            }
            if budget.exhausted {
                return TractandaError("resourceLimit", "Catalogue VM work budget exceeded.")
            }
            if budget.cancelled { return TractandaError("cancelled", "Catalogue scan was cancelled.") }
        }
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
        let status = catalogueStep(statement)
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
    func putForRebuild(
        _ revision: Revision, using statements: RebuildStatements,
        corpusInput: PageCorpusInput? = nil, pageProvider: (any PageCorpusPageProvider)? = nil,
        corpusBoundary: () throws -> Void = {}
    ) throws {
        if let corpusInput {
            guard corpusInput.revision == revision, let pageProvider else {
                throw TractandaError(
                    "indexError", "Rebuild corpus input must bind its actual current head/provider.")
            }
            try installCorpusForRebuild(input: corpusInput, provider: pageProvider, boundary: corpusBoundary)
        }
        try putCorpus(revision)
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
        let status = catalogueStep(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw error() }
    }

    /// Only this fixed CREATE IF NOT EXISTS list bypasses data-write invalidation. Adding empty
    /// disposable tables/views is not an authority transition; accepted INSERT/UPDATE/DELETE still
    /// use execute and invalidate relevant current state. No arbitrary SQL is accepted here.
    func installAtomicAuthorityIndexSchema(_ slice: AtomicAuthorityIndexSchema.Slice) throws {
        guard !installedAtomicAuthoritySchemas.contains(slice) else { return }
        guard let database else { throw TractandaError("indexError", "Catalogue is closed.") }
        for sql in AtomicAuthorityIndexSchema.statements(slice) {
            try checkCatalogueScanProgress()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                let statement
            else { throw error() }
            let status = catalogueStep(statement)
            sqlite3_finalize(statement)
            guard status == SQLITE_DONE else { throw error() }
        }
        installedAtomicAuthoritySchemas.insert(slice)
    }

    /// Final local writer phase, not a renewable peer scan budget. Caller validates current
    /// rights before the durable seal, retains it through derived activation, and owns recovery
    /// if an error/crash follows that seal. No nested or partially visible transaction is allowed.
    /// Native reconstruction only: a fresh, unpublished rebuild-UUID database in its outer
    /// transaction, borrowing the Store's already-held lifetime canonical writer descriptor.
    /// Portable inode checks bind the descriptor; the caller retains the actual flock lease.
    func withAtomicCanonicalReconstruction<T>(
        canonicalRoot: URL, indexDirectory: URL, ownerUID: UInt32, writerDescriptor: Int32,
        _ body: () throws -> T
    ) throws -> T {
        let path = URL(fileURLWithPath: corpusIndexPath)
        let name = path.lastPathComponent
        var held = stat()
        var named = stat()
        guard createdForConstruction, !atomicCanonicalReconstruction, let database,
            sqlite3_get_autocommit(database) == 0,
            path.deletingLastPathComponent().path == indexDirectory.path,
            name.hasPrefix("rebuild-"), name.hasSuffix(".sqlite"),
            UUID(uuidString: String(name.dropFirst(8).dropLast(7))) != nil,
            writerDescriptor >= 0, fstat(writerDescriptor, &held) == 0,
            lstat(canonicalRoot.appendingPathComponent(".writer.lock").path, &named) == 0,
            held.st_dev == named.st_dev, held.st_ino == named.st_ino,
            held.st_uid == ownerUID, held.st_nlink == 1,
            held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), held.st_mode & 0o777 == 0o600
        else {
            throw TractandaError(
                "storeBusy", "Historical atomic activation requires its unpublished native rebuild owner.")
        }
        atomicCanonicalReconstruction = true
        defer { atomicCanonicalReconstruction = false }
        return try body()
    }
    func withAtomicFinalWriter<T>(
        existingAcceptance: AtomicAuthorityAcceptance.Sealed? = nil,
        _ body: () throws -> T
    ) throws -> T {
        guard let database else { throw graphSQLiteError() }
        let nested = sqlite3_get_autocommit(database) == 0
        guard existingAcceptance == nil || atomicCanonicalReconstruction,
            !nested || (existingAcceptance != nil && atomicCanonicalReconstruction)
        else {
            throw TractandaError("storeBusy", "Atomic activation requires its own final writer phase.")
        }
        // Only exact, already canonical historical proof may enter the unpublished rebuild's
        // outer transaction. Ordinary online acceptance never receives this restoration mode.
        try execute(nested ? "SAVEPOINT atomic_canonical_reconstruction" : "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute(nested ? "RELEASE atomic_canonical_reconstruction" : "COMMIT")
            return result
        } catch {
            try? rollbackAtomicFinalWriter(reconstruction: nested)
            throw error
        }
    }
    private func rollbackAtomicFinalWriter(reconstruction: Bool = false) throws {
        guard let database else {
            throw TractandaError("indexError", "Catalogue closed during atomic cleanup.")
        }
        let budget = activeCatalogueScanBudget
        activeCatalogueScanBudget = nil
        sqlite3_progress_handler(database, 0, nil, nil)
        defer {
            activeCatalogueScanBudget = budget
            if let budget {
                sqlite3_progress_handler(
                    database, Int32(budget.quantum), catalogueScanProgress,
                    Unmanaged.passUnretained(budget).toOpaque())
            }
        }
        if reconstruction {
            try execute("ROLLBACK TO atomic_canonical_reconstruction")
            try execute("RELEASE atomic_canonical_reconstruction")
        } else {
            try execute("ROLLBACK")
        }
    }

    /// Freeze is a private read-input lease, never authority. Executed prepared/trigger writes
    /// are observed by SQLite's update hook even when they bypass a new prepare() call.
    func freezeAtomicStage(_ root: AuthorityBinding) throws -> AtomicStageFreeze {
        guard frozenAtomicStage == nil, !atomicStageMutationOverflow else {
            throw TractandaError("storeBusy", "Atomic input is already frozen or its generation exhausted.")
        }
        let token = AtomicStageFreeze(
            id: Identifier.make(), root: root, generation: atomicStageMutationGeneration,
            dataVersion: try atomicIndexDataVersion())
        frozenAtomicStage = token
        return token
    }
    func checkAtomicStageFreeze(_ token: AtomicStageFreeze) throws {
        guard frozenAtomicStage?.id == token.id, !atomicStageMutationOverflow,
            atomicStageMutationGeneration == token.generation,
            try atomicIndexDataVersion() == token.dataVersion
        else {
            throw AtomicAuthorityFormat.invalid("Frozen canonical comparison input changed between windows.")
        }
    }
    func releaseAtomicStageFreeze(_ token: AtomicStageFreeze) throws {
        guard frozenAtomicStage?.id == token.id else {
            throw AtomicAuthorityFormat.invalid("A stale atomic stage lease cannot release another owner.")
        }
        frozenAtomicStage = nil
    }
    private func noteAtomicStageMutation() {
        let next = atomicStageMutationGeneration.addingReportingOverflow(1)
        if next.overflow {
            atomicStageMutationOverflow = true
        } else {
            atomicStageMutationGeneration = next.partialValue
        }
    }
    private func atomicIndexDataVersion() throws -> Int64 {
        guard let database else { throw TractandaError("indexError", "Catalogue is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA main.data_version", -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw error() }
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW else { throw error() }
        return sqlite3_column_int64(statement, 0)
    }

    func registerRecoveryDocument(_ document: AttachmentDocumentRepresentation, itemID: String) throws -> Bool
    {
        guard let reference = document.content else { return false }
        let encoded = String(decoding: try JSON.encode(document), as: UTF8.self)
        let statement = try prepare(
            "SELECT item, descriptor FROM document_owners WHERE id = ?", [reference.contentID])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_ROW {
            guard let item = sqlite3_column_text(statement, 0),
                let descriptor = sqlite3_column_text(statement, 1),
                String(cString: item) == itemID, String(cString: descriptor) == encoded
            else {
                throw TractandaError(
                    "recoveryError", "Document content identity was rebound across canonical revisions.")
            }
            return false
        }
        guard status == SQLITE_DONE else { throw error() }
        try execute("INSERT INTO document_owners VALUES (?, ?, ?)", [reference.contentID, itemID, encoded])
        return true
    }

    /// Disk-backed recovery ownership prevents an immutable identity from changing owner or bytes.
    func registerRecoveryAttachment(_ descriptor: AttachmentDescriptor, itemID: String) throws -> Bool {
        let encoded = String(decoding: try JSON.encode(descriptor), as: UTF8.self)
        let statement = try prepare(
            "SELECT item, descriptor FROM attachment_owners WHERE id = ?", [descriptor.attachmentID])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_ROW {
            guard let storedItem = sqlite3_column_text(statement, 0),
                let storedDescriptor = sqlite3_column_text(statement, 1),
                String(cString: storedItem) == itemID,
                String(cString: storedDescriptor) == encoded
            else {
                throw TractandaError(
                    "recoveryError", "Attachment identity was rebound across canonical revisions.")
            }
            return false
        } else {
            guard status == SQLITE_DONE else { throw error() }
            try execute(
                "INSERT INTO attachment_owners VALUES (?, ?, ?)", [descriptor.attachmentID, itemID, encoded])
            return true
        }
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
        try execute("INSERT INTO checkpoint_meta VALUES ('schema', ?)", [Self.catalogueSchemaVersion])
        try execute("INSERT INTO checkpoint_meta VALUES ('engine', ?)", [Self.catalogueEngine])
        try execute("INSERT INTO checkpoint_meta VALUES ('itemTextProfile', ?)", [ItemTextContent.profile])
        for table in [
            "revision_parents", "revision_field_values", "revision_field_writes", "revision_frontier",
            "scoped_operation_receipts",
        ] {
            try execute("DELETE FROM \(table)")
        }
        for row in rows { try insertRecoveryRow(row) }
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
        guard catalogueStep(integrity) == SQLITE_ROW,
            exactString(integrity, 0) == "ok",
            catalogueStep(integrity) == SQLITE_DONE
        else { return nil }
        let invalidReceipt = try prepare(
            "SELECT 1 FROM revision_catalog r LEFT JOIN operation_receipts o ON o.revision=r.revision LEFT JOIN scoped_operation_receipts m ON m.revision=r.revision WHERE (r.provenance IS NULL AND (o.revision IS NULL OR o.actor!=r.actor OR o.operation!=r.operation OR o.item!=r.item)) OR (r.provenance IS NOT NULL AND (m.revision IS NULL OR m.actor!=r.actor OR m.operation!=r.operation OR m.item!=r.item)) LIMIT 1"
        )
        defer { sqlite3_finalize(invalidReceipt) }
        guard catalogueStep(invalidReceipt) == SQLITE_DONE else { return nil }
        let receiptCounts = try prepare(
            "SELECT (SELECT COUNT(*) FROM revision_catalog),(SELECT COUNT(*) FROM operation_receipts)+(SELECT COUNT(*) FROM scoped_operation_receipts)"
        )
        defer { sqlite3_finalize(receiptCounts) }
        guard catalogueStep(receiptCounts) == SQLITE_ROW,
            sqlite3_column_int64(receiptCounts, 0) == sqlite3_column_int64(receiptCounts, 1),
            catalogueStep(receiptCounts) == SQLITE_DONE
        else { return nil }
        let meta = try prepare("SELECT value FROM checkpoint_meta WHERE key = 'identity'")
        defer { sqlite3_finalize(meta) }
        guard catalogueStep(meta) == SQLITE_ROW,
            exactString(meta, 0) == identity, catalogueStep(meta) == SQLITE_DONE
        else { return nil }
        let schema = try prepare("SELECT value FROM checkpoint_meta WHERE key = 'schema'")
        defer { sqlite3_finalize(schema) }
        guard catalogueStep(schema) == SQLITE_ROW,
            exactString(schema, 0) == Self.catalogueSchemaVersion, catalogueStep(schema) == SQLITE_DONE
        else { return nil }
        let extraction = try prepare("SELECT value FROM checkpoint_meta WHERE key = 'itemTextProfile'")
        defer { sqlite3_finalize(extraction) }
        guard catalogueStep(extraction) == SQLITE_ROW,
            exactString(extraction, 0) == ItemTextContent.profile, catalogueStep(extraction) == SQLITE_DONE
        else { return nil }
        let engine = try prepare("SELECT value FROM checkpoint_meta WHERE key = 'engine'")
        defer { sqlite3_finalize(engine) }
        guard catalogueStep(engine) == SQLITE_ROW,
            exactString(engine, 0) == Self.catalogueEngine, catalogueStep(engine) == SQLITE_DONE
        else { return nil }
        // A copied or partially replaced v3 catalogue can retain valid metadata while
        // its derived query table no longer matches the current engine contract.
        func hasColumns(_ sql: String) -> Bool {
            guard let statement = try? prepare(sql) else { return false }
            defer { sqlite3_finalize(statement) }
            return catalogueStep(statement) == SQLITE_DONE
        }
        for sql in [
            "SELECT id,revision,class,deleted,modified,created,fields FROM items LIMIT 0",
            "SELECT revision,item,path,parent,actor,operation,size,inode,uid,mode,mtime_seconds,mtime_nanoseconds,digest,created_at,modified_at,provenance,modified_ticks FROM revision_catalog LIMIT 0",
            "SELECT actor,operation,revision,item FROM operation_receipts LIMIT 0",
            "SELECT origin,kind,actor,operation,revision,item FROM scoped_operation_receipts LIMIT 0",
            "SELECT child,parent FROM revision_parents LIMIT 0",
            "SELECT revision,field,action,digest FROM revision_field_writes LIMIT 0",
            "SELECT revision,field,digest FROM revision_field_values LIMIT 0",
            "SELECT revision,item FROM recovery_ready LIMIT 0",
            "SELECT revision,item,indegree,processed FROM recovery_graph_work LIMIT 0",
            "SELECT revision,authored FROM revision_frontier LIMIT 0",
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
        var pageBytes = 0
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { return nil }
            try boundCatalogueRow(statement, remaining: &pageBytes, maximum: graphMaximumPageBytes)
            guard let row = try catalogueRow(statement) else { return nil }
            rows.append(row)
        }
        let receipts = try prepare(
            "SELECT (SELECT COUNT(*) FROM operation_receipts)+(SELECT COUNT(*) FROM scoped_operation_receipts)"
        )
        defer { sqlite3_finalize(receipts) }
        guard catalogueStep(receipts) == SQLITE_ROW,
            sqlite3_column_int64(receipts, 0) == Int64(rows.count),
            catalogueStep(receipts) == SQLITE_DONE
        else { return nil }
        let mismatches = try prepare(
            "SELECT COUNT(*) FROM revision_catalog r LEFT JOIN operation_receipts o "
                + "ON o.revision=r.revision LEFT JOIN scoped_operation_receipts m ON m.revision=r.revision "
                + "WHERE (r.provenance IS NULL AND (o.revision IS NULL OR o.actor!=r.actor OR o.operation!=r.operation OR o.item!=r.item)) "
                + "OR (r.provenance IS NOT NULL AND (m.revision IS NULL OR m.actor!=r.actor OR m.operation!=r.operation OR m.item!=r.item))"
        )
        defer { sqlite3_finalize(mismatches) }
        guard catalogueStep(mismatches) == SQLITE_ROW, sqlite3_column_int64(mismatches, 0) == 0,
            catalogueStep(mismatches) == SQLITE_DONE
        else { return nil }
        return rows
    }

    func upsertCatalogue(_ row: CatalogueRow, graphFields: [String: ItemValue]? = nil) throws {
        try insertRecoveryRow(row, graphFields: graphFields)
    }

    func insertRecoveryRow(_ row: CatalogueRow, graphFields: [String: ItemValue]? = nil) throws {
        if row.provenance?.mergeProfile == AuthorityStore.reconciliationProfile {
            guard let graphFields else {
                throw TractandaError("invalidAuthority", "Reconciliation needs actual canonical fields.")
            }
            try validateAuthorityReconciliationMetadata(
                Revision(fields: graphFields, formatVersion: 2), allowUnprojectedRecoveryParents: true)
        }
        try insertGraphCatalogueRow(row, graphFields: graphFields)
        if authorityControlSchemaReady {
            try execute("UPDATE authority_local_history SET retired=0 WHERE revision=?", [row.revisionID])
            try execute("DELETE FROM authority_retired_items WHERE item=?", [row.itemID])
        }
    }

    func catalogueCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM revision_catalog")
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Immutable revisions only append; capture this on the owner queue before a detached scan.
    func catalogueWatermark() throws -> Int64 {
        let statement = try prepare("SELECT COALESCE(MAX(rowid), 0) FROM revision_catalog")
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW else { throw error() }
        let watermark = sqlite3_column_int64(statement, 0)
        guard catalogueStep(statement) == SQLITE_DONE else { throw error() }
        return watermark
    }

    func sealCatalogue(identity: String) throws {
        try execute("SAVEPOINT seal_catalogue")
        do {
            try execute("INSERT OR REPLACE INTO checkpoint_meta VALUES ('identity', ?)", [identity])
            try execute(
                "INSERT OR REPLACE INTO checkpoint_meta VALUES ('schema', ?)", [Self.catalogueSchemaVersion])
            try execute(
                "INSERT OR REPLACE INTO checkpoint_meta VALUES ('engine', ?)", [Self.catalogueEngine])
            try execute(
                "INSERT OR REPLACE INTO checkpoint_meta VALUES ('itemTextProfile', ?)",
                [ItemTextContent.profile])
            if try acceptedGraphProofIsCurrent() { try persistAcceptedGraphProof() }
            try execute("RELEASE seal_catalogue")
        } catch {
            try? execute("ROLLBACK TO seal_catalogue")
            try? execute("RELEASE seal_catalogue")
            throw error
        }
    }

    func recoveryRowPage(after revision: String? = nil, limit: Int = 128) throws -> [CatalogueRow] {
        guard (1...1024).contains(limit) else {
            throw TractandaError("invalidLimit", "Recovery page limit is invalid.")
        }
        let sql =
            revision == nil
            ? "SELECT \(catalogueColumns) FROM revision_catalog ORDER BY revision LIMIT ?"
            : "SELECT \(catalogueColumns) FROM revision_catalog WHERE revision>? ORDER BY revision LIMIT ?"
        let bindings = revision.map { [$0, String(limit)] } ?? [String(limit)]
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [CatalogueRow] = []
        var pageBytes = 0
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw error() }
            guard
                try boundCatalogueRow(
                    statement, remaining: &pageBytes, maximum: graphMaximumPageBytes, allowPrefix: true)
            else { return rows }
            guard let row = try catalogueRow(statement) else { throw error() }
            rows.append(row)
        }
    }

    /// Shape/causal-reference validation is disk backed; semantic projection remains gated.
    func validateRecoveryGraph(
        requireLinearProjection: Bool = true, progress: (() throws -> Void)? = nil
    ) throws {
        invalidateRevisionGraphValidation()
        try execute("SAVEPOINT graph_admission")
        do {
            try validateCatalogueGraph(requireLinearProjection: requireLinearProjection, progress: progress)
            graphValidationPassesForTesting += 1
            validatedGraphWatermark = try catalogueWatermark()
            validatedGraphAllowsOnlyLinear = requireLinearProjection
            try persistAcceptedGraphProof()
            try execute("RELEASE graph_admission")
        } catch {
            try? execute("ROLLBACK TO graph_admission")
            try? execute("RELEASE graph_admission")
            invalidateRevisionGraphValidation()
            try? execute("DELETE FROM checkpoint_meta WHERE key='graphAdmissionProof'")
            throw error
        }
    }
    func invalidateRevisionGraphValidation() {
        validatedGraphWatermark = nil
        lastAnalyzedProjection = nil
        admittedProjectionCheckpointWatermark = nil
    }
    struct AuthorityPeerGraphState {
        let watermark: Int64?
        let linear: Bool
        let analysis: RevisionProjection.Snapshot?
        let checkpoint: Int64?
    }
    func captureAuthorityPeerGraphState() -> AuthorityPeerGraphState {
        .init(
            watermark: validatedGraphWatermark, linear: validatedGraphAllowsOnlyLinear,
            analysis: lastAnalyzedProjection, checkpoint: admittedProjectionCheckpointWatermark)
    }
    func restoreAuthorityPeerGraphState(_ state: AuthorityPeerGraphState) {
        validatedGraphWatermark = state.watermark
        validatedGraphAllowsOnlyLinear = state.linear
        lastAnalyzedProjection = state.analysis
        admittedProjectionCheckpointWatermark = state.checkpoint
    }
    /// Only fixed rollback/release statements bypass a failed scan callback. Cleanup
    /// is bounded by already guarded writes and must restore SQL before restoring proof.
    func rollbackAuthorityPeerMaterialization() throws {
        try rollbackAuthoritySavepoint(review: false)
    }
    func rollbackAuthorityReview() throws {
        try rollbackAuthoritySavepoint(review: true)
    }
    func rollbackPeerInventoryRetain() throws {
        try rollbackAuthoritySavepoint(review: false, inventory: true)
    }
    private func rollbackAuthoritySavepoint(review: Bool, inventory: Bool = false) throws {
        guard let database else { throw TractandaError("indexError", "Catalogue closed during cleanup.") }
        let budget = activeCatalogueScanBudget
        activeCatalogueScanBudget = nil
        sqlite3_progress_handler(database, 0, nil, nil)
        defer {
            activeCatalogueScanBudget = budget
            if let budget {
                sqlite3_progress_handler(
                    database, Int32(budget.quantum), catalogueScanProgress,
                    Unmanaged.passUnretained(budget).toOpaque())
            }
        }
        if inventory {
            try execute("ROLLBACK TO peer_inventory_retain")
            try execute("RELEASE peer_inventory_retain")
        } else if review {
            try execute("ROLLBACK TO authority_review")
            try execute("RELEASE authority_review")
        } else {
            try execute("ROLLBACK TO authority_peer_materialization")
            try execute("RELEASE authority_peer_materialization")
        }
    }
    func withAuthorityPeerWorkAllowance<T>(maximum: Int64, _ body: () throws -> T) throws -> T {
        guard maximum > 0, let budget = activeCatalogueScanBudget else {
            throw TractandaError("resourceLimit", "Missing peer work allowance.")
        }
        try budget.requireAvailable()
        let remaining = budget.remaining
        let allowance = min(remaining, maximum)
        budget.remaining = allowance
        defer { budget.remaining = remaining - max(0, allowance - budget.remaining) }
        return try body()
    }
    func acceptedGraphProofIsCurrent() throws -> Bool {
        try validatedGraphWatermark != nil && validatedGraphWatermark == catalogueWatermark()
    }
    func advanceAcceptedGraphProof(retainsLinearProjection: Bool = false) throws {
        validatedGraphWatermark = try catalogueWatermark()
        validatedGraphAllowsOnlyLinear = validatedGraphAllowsOnlyLinear && retainsLinearProjection
        try persistAcceptedGraphProof()
    }
    private struct GraphAdmissionProof: Codable {
        let schema: String
        let engine: String
        let ancestryProfile: String
        let mergeProfile: String
        let identity: String
        let watermark: Int64
        let linear: Bool
    }
    private func proofIdentity() throws -> String? {
        let statement = try prepare("SELECT value FROM checkpoint_meta WHERE key='identity'")
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, sqlite3_column_bytes(statement, 0) <= 4096,
            let value = sqlite3_column_text(statement, 0)
        else { throw error() }
        return String(cString: value)
    }
    private func persistAcceptedGraphProof() throws {
        guard let watermark = validatedGraphWatermark, let identity = try proofIdentity() else { return }
        let marker = GraphAdmissionProof(
            schema: Self.catalogueSchemaVersion, engine: Self.catalogueEngine,
            ancestryProfile: RevisionProvenance.profile, mergeProfile: RevisionMerge.profile,
            identity: identity, watermark: watermark, linear: validatedGraphAllowsOnlyLinear)
        try execute(
            "INSERT OR REPLACE INTO checkpoint_meta VALUES('graphAdmissionProof',?)",
            [String(decoding: try JSON.encode(marker), as: UTF8.self)])
    }
    /// Called only after canonical inventory and complete current-cache checkpoint admission.
    func resumeAcceptedGraphProofFromCheckpoint(
        validated: ValidatedCatalogue, requireLinearProjection: Bool = true
    ) throws -> Bool {
        guard try proofIdentity() == validated.identity else { return false }
        let statement = try prepare("SELECT value FROM checkpoint_meta WHERE key='graphAdmissionProof'")
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW, sqlite3_column_bytes(statement, 0) <= 4096,
            let raw = sqlite3_column_text(statement, 0),
            let marker = try? JSON.decode(
                GraphAdmissionProof.self, Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, 0)))),
            marker.schema == Self.catalogueSchemaVersion, marker.engine == Self.catalogueEngine,
            marker.ancestryProfile == RevisionProvenance.profile,
            marker.mergeProfile == RevisionMerge.profile,
            marker.identity == validated.identity, !requireLinearProjection || marker.linear,
            marker.watermark == admittedProjectionCheckpointWatermark,
            marker.watermark == (try catalogueWatermark())
        else { return false }
        validatedGraphWatermark = marker.watermark
        validatedGraphAllowsOnlyLinear = marker.linear
        return true
    }

    func prepareRevisionProjectionGraph(progress: (() throws -> Void)?) throws {
        if validatedGraphWatermark != (try catalogueWatermark()) {
            try validateRecoveryGraph(requireLinearProjection: false, progress: progress)
        }
    }

    /// Enumerates accepted items without inventing a current representative for a fork.
    func recoveryItem(after itemID: String? = nil) throws -> String? {
        let sql =
            itemID == nil
            ? "SELECT item FROM recovery_roots ORDER BY item LIMIT 1"
            : "SELECT item FROM recovery_roots WHERE item>? ORDER BY item LIMIT 1"
        let statement = try prepare(sql, itemID.map { [$0] } ?? [])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let item = sqlite3_column_text(statement, 0) else { throw error() }
        return String(cString: item)
    }

    func recoveryHead(after itemID: String? = nil) throws -> (itemID: String, revisionID: String)? {
        let sql =
            itemID == nil
            ? "SELECT item,revision FROM recovery_heads ORDER BY item LIMIT 1"
            : "SELECT item,revision FROM recovery_heads WHERE item>? ORDER BY item LIMIT 1"
        let statement = try prepare(sql, itemID.map { [$0] } ?? [])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
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
            let status = catalogueStep(statement)
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

    private func catalogueRow(_ statement: OpaquePointer?) throws -> CatalogueRow? {
        var rowBytes = 0
        try boundCatalogueRow(statement, remaining: &rowBytes, maximum: Self.catalogueRowByteWindow)
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
        guard let size = UInt64(exactly: sqlite3_column_int64(statement, 6)),
            let inode = UInt64(exactly: sqlite3_column_int64(statement, 7)),
            let uid = UInt32(exactly: sqlite3_column_int64(statement, 8)),
            let mode = UInt32(exactly: sqlite3_column_int64(statement, 9)),
            let nanos = Int32(exactly: sqlite3_column_int64(statement, 11)),
            let modifiedAt = string(14)
        else { return nil }
        if !modifiedAt.isEmpty {
            guard sqlite3_column_type(statement, 16) == SQLITE_INTEGER,
                try RevisionTimestamp(modifiedAt).ticks == sqlite3_column_int64(statement, 16)
            else { throw TractandaError("recoveryError", "Exact catalogue timestamp metadata disagrees.") }
        }
        let row = CatalogueRow(
            revisionID: revision, itemID: item, path: path, parentID: parent, actor: actor,
            operationID: operation, size: size, inode: inode, uid: uid, mode: mode,
            modificationSeconds: sqlite3_column_int64(statement, 10),
            modificationNanoseconds: nanos, digest: digest,
            createdAt: string(13) ?? "", feedbackRevisionIDs: try feedbackRevisionIDs(revision),
            modifiedAt: modifiedAt, provenance: try decodeCatalogueProvenance(statement, column: 15))
        try validateGraphReceipt(row)
        return row
    }

    private let catalogueColumns =
        "revision,item,path,parent,actor,operation,size,inode,uid,mode,mtime_seconds,mtime_nanoseconds,digest,created_at,modified_at,provenance,modified_ticks"

    private func decodeCatalogueProvenance(_ statement: OpaquePointer?, column: Int32) throws
        -> RevisionProvenance?
    {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= RevisionProvenance.maximumBytes, let bytes = sqlite3_column_text(statement, column)
        else {
            throw TractandaError("recoveryError", "Invalid catalogue ancestry metadata.")
        }
        return try RevisionProvenance(value: JSON.decode(ItemValue.self, Data(bytes: bytes, count: count)))
    }

    /// Same-executor bridge; rows remain metadata only and each page has a hard bound.
    func graphCatalogueRows(where clause: String, bindings: [String], limit: Int) throws -> [CatalogueRow] {
        guard (1...1024).contains(limit) else {
            throw TractandaError("invalidLimit", "Graph page limit is invalid.")
        }
        let statement = try prepare(
            "SELECT \(catalogueColumns) FROM revision_catalog \(clause) LIMIT ?", bindings + [String(limit)])
        defer { sqlite3_finalize(statement) }
        var rows: [CatalogueRow] = []
        var pageBytes = 0
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw error() }
            guard
                try boundCatalogueRow(
                    statement, remaining: &pageBytes, maximum: graphMaximumPageBytes, allowPrefix: true)
            else { return rows }
            guard let row = try catalogueRow(statement) else { throw error() }
            rows.append(row)
        }
    }

    func graphSQLiteError() -> TractandaError { error() }

    /// Every protected step charges its measured VM delta exactly once. The progress
    /// handler bounds in-flight work and preparation without charging the same step twice.
    func catalogueStep(_ statement: OpaquePointer?) -> Int32 {
        guard let statement else { return SQLITE_MISUSE }
        guard let budget = activeCatalogueScanBudget else {
            // Only an exact post-seal Store activation can borrow this local batch allowance.
            // Every step remains cancellable and VM-bounded; no whole-logical-root ceiling or
            // silent renewal of the suspended peer allowance is introduced.
            if atomicAcceptedActivation != nil {
                do {
                    return try withCatalogueScanBudget(progress: { try Task.checkCancellation() }) {
                        catalogueStep(statement)
                    }
                } catch {
                    atomicAcceptedStepError =
                        error as? TractandaError
                        ?? TractandaError("cancelled", "Local accepted activation was cancelled.")
                    return SQLITE_INTERRUPT
                }
            }
            return sqlite3_step(statement)
        }
        let before = sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)
        guard budget.beginStep(before: before) else { return SQLITE_INTERRUPT }
        let status = sqlite3_step(statement)
        let after = sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)
        guard budget.finishStep(after: after) else { return SQLITE_INTERRUPT }
        return status
    }

    /// Count raw SQLite bytes before materializing Strings, JSON or a page's next metadata row.
    @discardableResult
    private func boundCatalogueRow(
        _ statement: OpaquePointer?, remaining accumulated: inout Int, maximum: Int,
        allowPrefix: Bool = false
    ) throws -> Bool {
        guard maximum > 0 else {
            throw TractandaError("resourceLimit", "Invalid catalogue page byte window.")
        }
        var rowBytes = 128
        for column in 0..<sqlite3_column_count(statement) {
            let bytes = Int(sqlite3_column_bytes(statement, column))
            let sum = rowBytes.addingReportingOverflow(bytes)
            guard bytes >= 0, !sum.overflow else {
                throw TractandaError("resourceLimit", "Catalogue row byte count overflowed.")
            }
            rowBytes = sum.partialValue
        }
        guard rowBytes <= Self.catalogueRowByteWindow else {
            throw TractandaError("resourceLimit", "Catalogue row exceeds its byte window before decoding.")
        }
        let feedback = try prepare(
            "SELECT COALESCE(SUM(length(CAST(target AS BLOB))+64),0) FROM feedback_refs WHERE revision=?")
        defer { sqlite3_finalize(feedback) }
        guard let revision = sqlite3_column_text(statement, 0),
            sqlite3_bind_text(feedback, 1, revision, sqlite3_column_bytes(statement, 0), transient)
                == SQLITE_OK,
            catalogueStep(feedback) == SQLITE_ROW
        else { throw error() }
        let feedbackBytes = sqlite3_column_int64(feedback, 0)
        guard let feedbackSize = Int(exactly: feedbackBytes), feedbackSize >= 0,
            !rowBytes.addingReportingOverflow(feedbackSize).overflow
        else {
            throw TractandaError("resourceLimit", "Catalogue feedback byte count overflowed.")
        }
        rowBytes += feedbackSize
        let total = accumulated.addingReportingOverflow(rowBytes)
        guard !total.overflow, rowBytes <= Self.catalogueRowByteWindow else {
            throw TractandaError(
                "resourceLimit", "Catalogue metadata exceeds its byte window; retry a smaller page.")
        }
        if total.partialValue > maximum {
            if allowPrefix, accumulated > 0 { return false }
            throw TractandaError(
                "resourceLimit", "Catalogue metadata exceeds its byte window; retry a smaller page.")
        }
        accumulated = total.partialValue
        return true
    }

    /// Explicit short-operation boundary; the active budget remains connection-private.
    func checkCatalogueScanProgress() throws {
        try Task.checkCancellation()
        guard let budget = activeCatalogueScanBudget else { return }
        try budget.requireAvailable()
        do {
            try budget.progress?()
        } catch {
            budget.callbackError = error
            throw error
        }
    }

    /// Private staging may yield BEFORE exhausting its enclosing allowance. This only observes
    /// remaining work; it never renews/resets a caller's security or catalogue budget.
    func atomicPrivateWindowHasRoom(minimumVMInstructions: Int64 = 4096) throws -> Bool {
        guard minimumVMInstructions > 0 else {
            throw TractandaError("resourceLimit", "Invalid atomic work-window reserve.")
        }
        try checkCatalogueScanProgress()
        return activeCatalogueScanBudget.map { $0.remaining >= minimumVMInstructions } ?? true
    }

    /// Explicit Store-owned local step; the enclosing scan tail is suspended, never renewed.
    /// Peer callbacks cannot mint the owner and continue to borrow/yield their network window.
    func withStoreOwnedAtomicValidationWindow<T>(
        _ owner: ItemStore.AtomicLocalValidationOwner, _ body: () throws -> T
    ) throws -> T {
        _ = try AuthorityRecord.persistentID(.text(owner.root.recordID))
        _ = try AuthorityRecord.digest(.text(owner.contextSHA256))
        guard let database else { throw graphSQLiteError() }
        let saved = activeCatalogueScanBudget
        activeCatalogueScanBudget = nil
        sqlite3_progress_handler(database, 0, nil, nil)
        defer {
            activeCatalogueScanBudget = saved
            if let saved {
                sqlite3_progress_handler(
                    database, Int32(saved.quantum), catalogueScanProgress,
                    Unmanaged.passUnretained(saved).toOpaque())
            }
        }
        return try withCatalogueScanBudget { try body() }
    }
    /// Private payload descriptor scratch belongs to the same serialized Store request. It
    /// borrows, rather than resets, that request's active measured VM allowance.
    func withBorrowedAtomicPreparationBudget<T>(from owner: ItemIndex, _ body: () throws -> T) throws -> T {
        guard self !== owner, let database, activeCatalogueScanBudget == nil,
            let borrowed = owner.activeCatalogueScanBudget
        else { throw TractandaError("resourceLimit", "Missing atomic preparation owner allowance.") }
        try borrowed.requireAvailable()
        activeCatalogueScanBudget = borrowed
        sqlite3_progress_handler(
            database, Int32(borrowed.quantum), catalogueScanProgress,
            Unmanaged.passUnretained(borrowed).toOpaque())
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            activeCatalogueScanBudget = nil
        }
        return try body()
    }

    func withCatalogueScanBudget<T>(
        progress: (() throws -> Void)? = nil, reusingActiveBudget: Bool = false,
        _ body: () throws -> T
    ) throws -> T {
        if reusingActiveBudget, let active = activeCatalogueScanBudget {
            try active.requireAvailable()
            return try body()
        }
        guard let database, graphMaximumVMInstructions > 0, activeCatalogueScanBudget == nil else {
            throw TractandaError("resourceLimit", "Invalid graph work budget or closed catalogue.")
        }
        let budget = CatalogueScanBudget(maximum: graphMaximumVMInstructions, progress: progress)
        activeCatalogueScanBudget = budget
        sqlite3_progress_handler(
            database, Int32(budget.quantum), catalogueScanProgress,
            Unmanaged.passUnretained(budget).toOpaque())
        defer {
            lastCatalogueScanWorkForTesting = graphMaximumVMInstructions - budget.remaining
            sqlite3_progress_handler(database, 0, nil, nil)
            activeCatalogueScanBudget = nil
        }
        do {
            try progress?()
            let result = try body()
            if let callbackError = budget.callbackError { throw callbackError }
            if budget.exhausted {
                throw TractandaError("resourceLimit", "Revision catalogue work budget exceeded.")
            }
            if budget.cancelled {
                throw TractandaError("cancelled", "Revision catalogue validation was cancelled.")
            }
            return result
        } catch {
            if let callbackError = budget.callbackError { throw callbackError }
            if budget.cancelled {
                throw TractandaError("cancelled", "Revision catalogue validation was cancelled.")
            }
            if budget.exhausted {
                throw TractandaError("resourceLimit", "Revision catalogue work budget exceeded.")
            }
            throw error
        }
    }

    func revision(_ revisionID: String) throws -> CatalogueRow? {
        let statement = try prepare(
            "SELECT \(catalogueColumns) FROM revision_catalog WHERE revision=?", [revisionID])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        guard status == SQLITE_ROW else {
            if status == SQLITE_DONE { return nil }
            throw error()
        }
        guard let row = try catalogueRow(statement), catalogueStep(statement) == SQLITE_DONE else {
            throw error()
        }
        return row
    }

    func revision(itemID: String, revisionID: String) throws -> CatalogueRow? {
        guard let row = try revision(revisionID), row.itemID == itemID else { return nil }
        return row
    }

    func revisionCount(itemID: String) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM revision_catalog WHERE item=?", [itemID])
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW else { throw error() }
        let count = sqlite3_column_int64(statement, 0)
        guard count >= 0, let result = Int(exactly: count), catalogueStep(statement) == SQLITE_DONE
        else { throw error() }
        return result
    }

    func successor(itemID: String, parentID: String) throws -> CatalogueRow? {
        let statement = try prepare(
            "SELECT \(catalogueColumns) FROM revision_catalog WHERE item=? AND parent=?", [itemID, parentID])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        guard status == SQLITE_ROW else {
            if status == SQLITE_DONE { return nil }
            throw error()
        }
        guard let row = try catalogueRow(statement), catalogueStep(statement) == SQLITE_DONE else {
            throw error()
        }
        return row
    }

    func receipt(actor: String, operationID: String) throws -> CatalogueRow? {
        let statement = try prepare(
            "SELECT \(catalogueColumns) FROM revision_catalog WHERE revision=(SELECT revision FROM operation_receipts WHERE actor=? AND operation=?)",
            [actor, operationID])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        guard status == SQLITE_ROW else {
            if status == SQLITE_DONE { return nil }
            throw error()
        }
        guard let row = try catalogueRow(statement), catalogueStep(statement) == SQLITE_DONE else {
            throw error()
        }
        return row
    }

    func receipts(
        named operationID: String, localReplicaID: String? = nil,
        kind: RevisionProvenance.Kind = .authored, maximum: Int = 1024
    ) throws
        -> [CatalogueRow]?
    {
        guard (1...1024).contains(maximum) else {
            throw TractandaError("invalidLimit", "Receipt limit is invalid.")
        }
        let sql: String
        let bindings: [String]
        if let localReplicaID {
            guard kind != .automaticMerge else { return [] }
            try Identifier.validate(localReplicaID)
            sql =
                "SELECT \(catalogueColumns) FROM revision_catalog WHERE revision IN "
                + "(SELECT revision FROM scoped_operation_receipts WHERE operation=? AND origin=? AND kind=?) "
                + "ORDER BY actor,revision LIMIT ?"
            bindings = [operationID, localReplicaID, kind.rawValue, String(maximum + 1)]
        } else {
            guard kind == .authored else { return [] }
            sql =
                "SELECT \(catalogueColumns) FROM revision_catalog WHERE revision IN "
                + "(SELECT revision FROM operation_receipts WHERE operation=?) ORDER BY actor,revision LIMIT ?"
            bindings = [operationID, String(maximum + 1)]
        }
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [CatalogueRow] = []
        var pageBytes = 0
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return rows.count <= maximum ? rows : nil }
            guard status == SQLITE_ROW else { throw error() }
            try boundCatalogueRow(statement, remaining: &pageBytes, maximum: graphMaximumPageBytes)
            guard let row = try catalogueRow(statement) else { throw error() }
            rows.append(row)
            if rows.count > maximum { return nil }
        }
    }

    func validatedCatalogue(identity: String) throws -> ValidatedCatalogue? {
        // This is the clean-start admission probe. A full integrity/receipt audit scans
        // catalogue-sized data and belongs to explicit audit/rebuild work, not startup.
        for (key, expected) in [
            ("identity", identity), ("schema", Self.catalogueSchemaVersion), ("engine", Self.catalogueEngine),
            ("itemTextProfile", ItemTextContent.profile),
        ] {
            let statement = try prepare("SELECT value FROM checkpoint_meta WHERE key=?", [key])
            let valid =
                catalogueStep(statement) == SQLITE_ROW
                && sqlite3_column_text(statement, 0).map({ String(cString: $0) }) == expected
                && catalogueStep(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            guard valid else { return nil }
        }
        func hasColumns(_ sql: String) -> Bool {
            guard let statement = try? prepare(sql) else { return false }
            defer { sqlite3_finalize(statement) }
            return catalogueStep(statement) == SQLITE_DONE
        }
        for sql in [
            "SELECT id,revision,class,deleted,modified,created,fields FROM items LIMIT 0",
            "SELECT item_id,revision,class,deleted,fields,clock_dependent,category FROM head_summaries LIMIT 0",
            "SELECT revision,item,path,parent,actor,operation,size,inode,uid,mode,mtime_seconds,mtime_nanoseconds,digest,created_at,modified_at,provenance,modified_ticks FROM revision_catalog LIMIT 0",
            "SELECT actor,operation,revision,item FROM operation_receipts LIMIT 0",
            "SELECT origin,kind,actor,operation,revision,item FROM scoped_operation_receipts LIMIT 0",
            "SELECT child,parent FROM revision_parents LIMIT 0",
            "SELECT revision,field,action,digest FROM revision_field_writes LIMIT 0",
            "SELECT revision,field,digest FROM revision_field_values LIMIT 0",
            "SELECT revision,item FROM recovery_ready LIMIT 0",
            "SELECT revision,item,indegree,processed FROM recovery_graph_work LIMIT 0",
            "SELECT revision,authored FROM revision_frontier LIMIT 0",
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
        guard catalogueStep(triggers) == SQLITE_ROW, sqlite3_column_int64(triggers, 0) == 4,
            catalogueStep(triggers) == SQLITE_DONE
        else { return nil }
        let savedViewIndexes = try prepare(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='index' "
                + "AND name IN ('saved_view_base_item','saved_view_staging_item')")
        defer { sqlite3_finalize(savedViewIndexes) }
        guard catalogueStep(savedViewIndexes) == SQLITE_ROW,
            sqlite3_column_int64(savedViewIndexes, 0) == 2,
            catalogueStep(savedViewIndexes) == SQLITE_DONE
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
        let status = catalogueStep(statement)
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
        let status = catalogueStep(statement)
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
        let status = catalogueStep(statement)
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
        let status = catalogueStep(statement)
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
        guard catalogueStep(statement) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func currentCategoryHeadID(after itemID: String? = nil) throws -> String? {
        let sql =
            itemID == nil
            ? "SELECT item_id FROM head_summaries WHERE category=1 ORDER BY item_id LIMIT 1"
            : "SELECT item_id FROM head_summaries WHERE category=1 AND item_id>? ORDER BY item_id LIMIT 1"
        let statement = try prepare(sql, itemID.map { [$0] } ?? [])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { throw error() }
        return String(cString: bytes)
    }

    func hasClockDependentCategories() throws -> Bool {
        let statement = try prepare("SELECT 1 FROM head_summaries WHERE clock_dependent=1 LIMIT 1")
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_DONE { return false }
        guard status == SQLITE_ROW else { throw error() }
        return true
    }

    func hasActiveHead(classID: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM head_summaries WHERE class=? AND deleted=0 LIMIT 1", [classID])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
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
        var pageBytes = 0
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw error() }
            guard
                try boundCatalogueRow(
                    statement, remaining: &pageBytes, maximum: graphMaximumPageBytes, allowPrefix: true)
            else { return rows }
            guard let row = try catalogueRow(statement) else { throw error() }
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
            let status = catalogueStep(statement)
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
            let status = catalogueStep(statement)
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
        return try corpusMatches(revision) && row.revisionID == revision.revisionID
            && row.subject == corpus.subject
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
    func put(_ revision: Revision, corpus: IndexedCorpusStage? = nil) throws {
        try putCorpus(revision, stage: corpus)
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
        try execute("DELETE FROM text_snapshot WHERE id = ?", [revision.itemID])
        try execute(
            "INSERT INTO text_snapshot (id, subject, body, metadata) VALUES (?, ?, ?, ?)",
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
        let priorStatus = catalogueStep(prior)
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
        guard catalogueStep(target) == SQLITE_ROW,
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
        guard catalogueStep(coverage) == SQLITE_ROW,
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
        guard catalogueStep(build) == SQLITE_ROW,
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
            let status = catalogueStep(statement)
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
        guard catalogueStep(retained) == SQLITE_ROW else { throw error() }
        var retainedRows = Int(sqlite3_column_int64(retained, 0))
        let stagedCount = try prepare("SELECT COUNT(*) FROM saved_view_staging")
        defer { sqlite3_finalize(stagedCount) }
        guard catalogueStep(stagedCount) == SQLITE_ROW else { throw error() }
        retainedRows += Int(sqlite3_column_int64(stagedCount, 0))
        let candidateCount = candidateCountBefore + batch.count
        var serializedBytes = 0
        let byteLimit = max(
            1, savedViewMaterializationByteLimitForTesting ?? savedViewMaterializationByteLimit)
        for row in batch {
            let fieldsStatement = try prepare(
                "SELECT fields FROM items WHERE id=? AND deleted=0", [row.0])
            guard catalogueStep(fieldsStatement) == SQLITE_ROW,
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
            let revision = try Revision(
                fields: fields, formatVersion: fields["revisionAncestry"] == nil ? 1 : 2)
            guard query?.matches(revision, at: Date()) ?? true else { continue }
            let staged = try prepare(
                "SELECT 1 FROM saved_view_staging WHERE view_id=? AND item_id=?",
                [id, row.0])
            let alreadyStaged = catalogueStep(staged) == SQLITE_ROW
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
        guard catalogueStep(current) == SQLITE_ROW,
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
        guard catalogueStep(target) == SQLITE_ROW, let bytes = sqlite3_column_text(target, 0) else {
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
            guard catalogueStep(row) == SQLITE_ROW, sqlite3_column_int(row, 1) == 0,
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
                let status = catalogueStep(children)
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
                let status = catalogueStep(exclusions)
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
        guard catalogueStep(statement) == SQLITE_ROW,
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
                let status = catalogueStep(statement)
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
            let status = catalogueStep(existingViews)
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
            let predicateStatus = catalogueStep(predicateDependency)
            sqlite3_finalize(predicateDependency)
            let predicateChanged = predicateStatus == SQLITE_ROW
            let hasCategoryRuleDependency = try {
                let statement = try prepare(
                    "SELECT 1 FROM saved_view_dependencies WHERE view_id=? AND kind='categoryRule' LIMIT 1",
                    [id])
                defer { sqlite3_finalize(statement) }
                return catalogueStep(statement) == SQLITE_ROW
            }()
            if categoryStructureChanged && hasCategoryRuleDependency { continue }
            let stateStatement = try prepare(
                "SELECT state,definition_hash,dependency_epoch FROM saved_view_coverage WHERE view_id=?", [id]
            )
            guard catalogueStep(stateStatement) == SQLITE_ROW,
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
            let hasRow = catalogueStep(existing) == SQLITE_ROW
            sqlite3_finalize(existing)
            let target = try prepare(
                "SELECT selection,class_filter FROM saved_view_targets WHERE id=?", [id])
            guard catalogueStep(target) == SQLITE_ROW,
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
                let seedMatches = catalogueStep(match) == SQLITE_ROW
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
                guard catalogueStep(retained) == SQLITE_ROW else {
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
                let status = catalogueStep(statement)
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
                "SELECT name FROM acl_principal_counts WHERE kind='user' AND refcount>0 UNION SELECT name FROM projection_principal_counts WHERE kind='user' AND refcount>0 ORDER BY name LIMIT \(maximum + 1)"
            ),
            let groups = try names(
                "SELECT name FROM acl_principal_counts WHERE kind='group' AND refcount>0 UNION SELECT name FROM projection_principal_counts WHERE kind='group' AND refcount>0 ORDER BY name LIMIT \(maximum + 1)"
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
                let status = catalogueStep(statement)
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
                let status = catalogueStep(statement)
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
                    let status = catalogueStep(statement)
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
                        let status = catalogueStep(statement)
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
                let status = catalogueStep(statement)
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
                let status = catalogueStep(statement)
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
        let joins =
            aclUserID == nil
            ? " FROM items"
            : " FROM (\(aclAuthorizedIDs)) acl_visible CROSS JOIN items ON items.id=acl_visible.item_id"
        var predicates = includeDeleted ? ["1"] : ["items.deleted = 0"]
        predicates.append(
            "NOT EXISTS(SELECT 1 FROM current_projection cp WHERE cp.item=items.id AND (cp.dirty=1 OR cp.status!='ready' OR cp.policies_complete=0))"
        )
        var arguments: [String] = []
        if let lexicalText {
            predicates.append(Self.corpusLiteralMembershipSQL)
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
            let status = catalogueStep(statement)
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
            let status = catalogueStep(statement)
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
            let status = catalogueStep(statement)
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
            let status = catalogueStep(statement)
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
            guard catalogueStep(counter) == SQLITE_ROW else { throw error() }
            let total = Int(sqlite3_column_int64(counter, 0))
            guard catalogueStep(counter) == SQLITE_DONE else { throw error() }
            let statement = try prepare(
                "SELECT items.id" + source
                    + " ORDER BY items.\(order.column) DESC, items.id LIMIT ? OFFSET ?",
                arguments + [String(limit), String(position)])
            defer { sqlite3_finalize(statement) }
            var ids: [String] = []
            while true {
                let status = catalogueStep(statement)
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
            let status = catalogueStep(statement)
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
            guard catalogueStep(countStatement) == SQLITE_ROW else { throw error() }
            total = Int(sqlite3_column_int64(countStatement, 0))
            guard catalogueStep(countStatement) == SQLITE_DONE else { throw error() }
        } else {
            let countStatement = try prepare("SELECT items.id" + itemSource.sql, itemSource.arguments)
            defer { sqlite3_finalize(countStatement) }
            total = 0
            while true {
                let status = catalogueStep(countStatement)
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
            let status = catalogueStep(statement)
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
        let status = catalogueStep(statement)
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
        guard catalogueStep(statement) == SQLITE_ROW,
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
            let status = catalogueStep(statement)
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
            let status = catalogueStep(statement)
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
            let step = catalogueStep(statement)
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
                    "SELECT items.id FROM items WHERE " + Self.corpusLiteralMembershipSQL
                        + " AND items.id IN (\(placeholders)) ORDER BY items.id",
                    [phrase] + batch)
                defer { sqlite3_finalize(statement) }
                while true {
                    let step = catalogueStep(statement)
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
            sql = "SELECT items.id FROM items WHERE " + Self.corpusLiteralMembershipSQL + " ORDER BY items.id"
            args = [phrase]
        } else {
            sql = "SELECT id FROM items ORDER BY id"
            args = []
        }
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let step = catalogueStep(statement)
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
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw error() }
            let id = String(cString: value)
            if restrictedIDs == nil || restrictedIDs!.contains(id) { try body(id) }
        }
    }
    func textRow(id: String) throws -> TextRow? {
        let statement = try prepare(
            "SELECT items.revision, text_snapshot.id, text_snapshot.subject, text_snapshot.body, text_snapshot.metadata FROM items LEFT JOIN text_snapshot ON items.id = text_snapshot.id WHERE items.id = ?",
            [id])
        defer { sqlite3_finalize(statement) }
        let step = catalogueStep(statement)
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
        guard catalogueStep(statement) == SQLITE_DONE else {
            throw TractandaError("indexError", "Ambiguous indexed text.")
        }
        return result
    }
}
