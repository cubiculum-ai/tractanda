import CSQLite
import Foundation

extension ItemIndex {
    /// Accepted facts/outcomes never read the structurally staged tables. These views require the
    /// exact accepted logical root and retained root-original identity, excluding physical parts.
    func initializeAtomicAuthorityAcceptedSchema() throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try requireGraphCapacity(additionalBytes: 64 * 1024)
            try installAtomicAuthorityIndexSchema(.accepted)
        }
    }

    /// Only Store's final semantic/publication phase may call this, inside the exact whole-root
    /// canonical comparison scope. The enclosing writer savepoint rolls back all rows/head on error.
    func retainValidatedAtomicControl(_ plan: AuthorityStore.VerifiedAtomicControlPlan) throws {
        let stage = plan.stage
        let header = stage.header
        let binding = header.binding
        guard activeAtomicControlFinalization == binding else {
            throw AtomicAuthorityFormat.invalid(
                "Atomic acceptance requires the active exact canonical finalization.")
        }
        guard let original = try retainedAuthorityObject(id: binding.recordID),
            original.descriptor.kind == .authority, original.descriptor.sha256 == binding.sha256,
            original.descriptor.length == stage.rootBytes.count
        else {
            throw AtomicAuthorityFormat.invalid("Accepted atomic root lacks its exact retained original.")
        }
        let kind = try corpusPrepare(
            "SELECT control_kind FROM authority_objects WHERE id=?", [binding.recordID])
        defer { sqlite3_finalize(kind) }
        guard catalogueStep(kind) == SQLITE_ROW, try atomicAcceptanceText(kind, 0) == "atomicControl" else {
            throw AtomicAuthorityFormat.invalid(
                "A physical part or legacy original cannot be an atomic root.")
        }
        if try hasValidatedAuthorityControl(binding) { return }
        let source = LogicalControlSource.atomic(stage)
        let priorHead = try authorityControlHead(originID: header.origin)
        guard priorHead == header.previous else {
            throw AtomicAuthorityFormat.invalid(
                "Atomic origin head changed or skipped its exact previous root.")
        }
        var parentCursor: Int64 = -1
        while true {
            let page = try source.parents(index: self, afterOrdinal: parentCursor)
            if page.isEmpty { break }
            for parent in page {
                guard try hasValidatedAuthorityControl(parent.binding) else {
                    throw AtomicAuthorityFormat.invalid("Original PRE contains an unaccepted logical parent.")
                }
                parentCursor = parent.ordinal
            }
        }
        if let bootstrap = header.bootstrap {
            guard let row = try retainedAuthorityObject(id: bootstrap.recordID),
                row.descriptor.kind == .authority, row.descriptor.sha256 == bootstrap.sha256
            else { throw AtomicAuthorityFormat.invalid("Atomic bootstrap binding is absent.") }
        }
        // Every bounded batch gets ordinary progress/capacity checks. Store must not wrap the
        // entire logical root in a nonresumable VM/read window; its validation work owns windows.
        var supportCursor: Int64 = -1
        var previousTarget: String?
        var previousState: Bool?
        var targets: Int64 = 0
        while true {
            let page = try source.supports(index: self, afterOrdinal: supportCursor)
            if page.isEmpty { break }
            for support in page {
                let delta = support.delta
                guard let target = try retainedAuthorityObject(id: delta.target.revisionID),
                    target.descriptor.kind == .item, target.descriptor.sha256 == delta.target.sha256
                else {
                    throw AtomicAuthorityFormat.invalid("Atomic effect target differs from retained bytes.")
                }
                let targetIdentity = try corpusPrepare(
                    "SELECT 1 FROM authority_objects WHERE id=? AND kind='item' AND item=? AND sha256=?",
                    [delta.target.revisionID, delta.target.itemID, delta.target.sha256])
                let exactTarget = catalogueStep(targetIdentity)
                sqlite3_finalize(targetIdentity)
                guard exactTarget == SQLITE_ROW else {
                    if exactTarget != SQLITE_DONE { throw graphSQLiteError() }
                    throw AtomicAuthorityFormat.invalid("Atomic target changed its exact item identity.")
                }
                if previousTarget == delta.target.revisionID {
                    guard previousState == delta.eligible else {
                        throw AtomicAuthorityFormat.invalid(
                            "One atomic target has contradictory support outcomes.")
                    }
                } else {
                    targets = try AtomicAuthorityFormat.sum(targets, 1)
                    previousTarget = delta.target.revisionID
                    previousState = delta.eligible
                }
                try retainAtomicAcceptedDependency(
                    root: binding, kind: "atomicSupportTarget",
                    value: .init(recordID: delta.target.revisionID, sha256: delta.target.sha256),
                    expectedKind: .item)
                if let evidence = delta.evidence {
                    try retainAtomicAcceptedDependency(
                        root: binding, kind: "atomicSupportEvidence", value: evidence,
                        expectedKind: .authority)
                }
                for policy in delta.policyIDs {
                    guard let row = try retainedAuthorityObject(id: policy), row.descriptor.kind == .item
                    else {
                        throw AtomicAuthorityFormat.invalid(
                            "Atomic policy dependency lacks its exact original.")
                    }
                    try retainAtomicAcceptedDependency(
                        root: binding, kind: "atomicSupportPolicy",
                        value: .init(recordID: policy, sha256: row.descriptor.sha256), expectedKind: .item)
                }
                try checkCatalogueScanProgress()
                try requireGraphCapacity(
                    additionalBytes: UInt64(try JSON.encode(delta.itemValue).count) * 4 + 8192)
                // These remain real original facts; no combined or empty policy/evidence surrogate.
                try execute(
                    "INSERT INTO authority_control_support VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                    [
                        binding.recordID, binding.sha256, delta.target.revisionID, support.fingerprint,
                        delta.target.itemID, delta.target.sha256, delta.eligible ? "1" : "0", delta.actor,
                        String(decoding: try JSON.encode(delta.policyIDs), as: UTF8.self),
                        String(decoding: try JSON.encode(delta.causes), as: UTF8.self),
                        String(
                            decoding: try JSON.encode(
                                ItemValue.list(delta.evidence.map { [$0.itemValue] } ?? [])), as: UTF8.self),
                        String(decoding: try JSON.encode(delta.itemValue), as: UTF8.self),
                    ])
                try execute(
                    "INSERT OR IGNORE INTO authority_atomic_outcome VALUES(?,?,?,?,?,?)",
                    [
                        binding.recordID, binding.sha256, delta.target.revisionID, delta.target.itemID,
                        delta.target.sha256, delta.eligible ? "1" : "0",
                    ])
                try execute(
                    "INSERT OR IGNORE INTO authority_control_affected VALUES('actor',?,?)",
                    [delta.actor, delta.target.itemID])
                for policy in delta.policyIDs {
                    try execute(
                        "INSERT OR IGNORE INTO authority_control_affected VALUES('policy',?,?)",
                        [policy, delta.target.itemID])
                }
                for cause in delta.causes {
                    guard try atomicAcceptanceCause(cause, delta: delta, header: header) else {
                        throw AtomicAuthorityFormat.invalid("Atomic support names an unvalidated cause.")
                    }
                    try retainAtomicAcceptedDependency(
                        root: binding, kind: "atomicSupportCause", value: cause, expectedKind: .authority)
                    try execute(
                        "INSERT OR IGNORE INTO authority_control_affected VALUES('cause',?,?)",
                        [cause.sha256, delta.target.itemID])
                }
                supportCursor = support.ordinal
            }
        }
        guard targets == stage.effects.targetCount else {
            throw AtomicAuthorityFormat.invalid("Accepted atomic target count differs from canonical root.")
        }
        let next = try atomicAcceptanceNextOrdinal()
        try execute(
            "INSERT INTO authority_control VALUES(?,?,?,?,?,?,?)",
            [
                binding.recordID, binding.sha256, header.origin, String(next),
                header.bootstrap?.recordID ?? "", header.bootstrap?.sha256 ?? "",
                header.previous?.recordID ?? "",
            ])
        try execute("INSERT INTO authority_atomic_accepted VALUES(?,?)", [binding.recordID, binding.sha256])
        parentCursor = -1
        while true {
            let page = try source.parents(index: self, afterOrdinal: parentCursor)
            if page.isEmpty { break }
            for parent in page {
                try retainAtomicAcceptedDependency(
                    root: binding, kind: "controlParent", value: parent.binding, expectedKind: .authority)
                try execute(
                    "INSERT INTO authority_control_edges VALUES(?,?,?)",
                    [binding.recordID, parent.binding.recordID, parent.binding.sha256])
                parentCursor = parent.ordinal
            }
        }
        try execute(
            "INSERT OR REPLACE INTO authority_control_heads VALUES(?,?,?)",
            [header.origin, binding.recordID, binding.sha256])
        try execute("DELETE FROM authority_control_pending WHERE id=?", [binding.recordID])
        try execute(
            "UPDATE authority_control_pending SET missing=missing-1 WHERE missing>0 AND id IN(SELECT source FROM authority_dependencies INDEXED BY authority_dependencies_reverse WHERE target=? AND kind='controlParent' AND package='' AND sha256=?)",
            [binding.recordID, binding.sha256])
    }

    /// Derived export closure only, after whole canonical binding/Store semantics/accepted seal.
    /// It records every genuine fact context without materializing all root dependencies at once.
    private func retainAtomicAcceptedDependency(
        root: AuthorityBinding, kind: String, value: AuthorityBinding, expectedKind: PeerPackage.Kind
    ) throws {
        guard activeAtomicControlFinalization == root,
            let original = try retainedAuthorityObject(id: value.recordID),
            original.descriptor.kind == expectedKind, original.descriptor.sha256 == value.sha256
        else { throw AtomicAuthorityFormat.invalid("Accepted atomic export dependency changed identity.") }
        try execute(
            "INSERT OR IGNORE INTO authority_dependencies VALUES(?,?,?,?,?)",
            [root.recordID, kind, value.recordID, value.sha256, ""])
    }

    private func atomicAcceptanceText(_ s: OpaquePointer, _ column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(s, column))
        guard sqlite3_column_type(s, column) == SQLITE_TEXT, count >= 0,
            count <= AtomicAuthorityFormat.maximumEnvelopeBytes,
            let bytes = sqlite3_column_text(s, column),
            let text = String(data: Data(bytes: bytes, count: count), encoding: .utf8)
        else { throw AtomicAuthorityFormat.invalid("Malformed or non-UTF8 atomic metadata text.") }
        return text
    }
    private func atomicAcceptanceCause(
        _ cause: AuthorityBinding, delta: AuthorityStore.DispositionDelta,
        header: LogicalControlSource.Header
    ) throws -> Bool {
        if try hasValidatedAuthorityControl(cause) { return true }
        // Existing explicit D/B/C uses the exact decision as cause, not a logical control.
        // Only its already validated/applied, non-recovery application bound to THIS root
        // and this held/resolution target supplies that narrowly scoped exception.
        let s = try corpusPrepare(
            "SELECT EXISTS(SELECT 1 FROM authority_review_applied a JOIN authority_review_event e ON e.id=a.decision AND e.sha256=a.sha256 JOIN authority_objects o ON o.id=e.id AND o.sha256=e.sha256 AND o.control_kind='reviewDecision' WHERE a.decision=? AND a.sha256=? AND a.control=? AND a.control_digest=? AND a.origin=? AND a.actor=? AND a.recovery=0 AND e.item=? AND ((e.target=? AND e.target_digest=?) OR (e.resolution=? AND e.resolution_digest=?)))",
            [
                cause.recordID, cause.sha256, header.binding.recordID, header.binding.sha256,
                header.origin, header.actor, delta.target.itemID, delta.target.revisionID,
                delta.target.sha256,
                delta.target.revisionID, delta.target.sha256,
            ])
        defer { sqlite3_finalize(s) }
        guard catalogueStep(s) == SQLITE_ROW else { throw graphSQLiteError() }
        return sqlite3_column_int(s, 0) == 1
    }
    private func atomicAcceptanceNextOrdinal() throws -> Int64 {
        let s = try corpusPrepare("SELECT COALESCE(MAX(ordinal),0) FROM authority_control")
        defer { sqlite3_finalize(s) }
        guard catalogueStep(s) == SQLITE_ROW else { throw graphSQLiteError() }
        return try AtomicAuthorityFormat.sum(sqlite3_column_int64(s, 0), 1)
    }
}

/// Fixed disposable-schema DDL only. No caller-supplied SQL or accepted data mutation.
enum AtomicAuthorityIndexSchema {
    enum Slice: Hashable { case staging, accepted, dependencyExport, publication }
    static func statements(_ slice: Slice) -> [String] {
        switch slice {
        case .staging: staging
        case .accepted: accepted
        case .publication:
            [
                "CREATE TABLE IF NOT EXISTS authority_atomic_publication_spool(token TEXT NOT NULL,id TEXT NOT NULL,descriptor TEXT NOT NULL,PRIMARY KEY(token,id))"
            ]
        case .dependencyExport:
            [
                "CREATE INDEX IF NOT EXISTS authority_dependencies_export ON authority_dependencies(source,package,kind,target,sha256)"
            ]
        }
    }
    private static let staging: [String] = [
        "CREATE TABLE IF NOT EXISTS authority_atomic_stage(id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,root TEXT NOT NULL,parents INTEGER NOT NULL DEFAULT 0,facts INTEGER NOT NULL DEFAULT 0,targets INTEGER NOT NULL DEFAULT 0,complete INTEGER NOT NULL DEFAULT 0)",
        "CREATE TABLE IF NOT EXISTS authority_atomic_parent_stage(root TEXT NOT NULL,ordinal INTEGER NOT NULL,id TEXT NOT NULL,sha256 TEXT NOT NULL,PRIMARY KEY(root,ordinal),UNIQUE(root,id))",
        "CREATE INDEX IF NOT EXISTS authority_atomic_parent_domain ON authority_atomic_parent_stage(root)",
        "CREATE TABLE IF NOT EXISTS authority_atomic_support_stage(root TEXT NOT NULL,ordinal INTEGER NOT NULL,target TEXT NOT NULL,fingerprint TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(root,ordinal),UNIQUE(root,target,fingerprint))",
        "CREATE INDEX IF NOT EXISTS authority_atomic_support_domain ON authority_atomic_support_stage(root)",
    ]
    private static let accepted: [String] = [
        "CREATE UNIQUE INDEX IF NOT EXISTS authority_atomic_head_id ON authority_control_heads(id)",
        "CREATE TABLE IF NOT EXISTS authority_atomic_accepted(control TEXT PRIMARY KEY,sha256 TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS authority_atomic_outcome(control TEXT NOT NULL,control_digest TEXT NOT NULL,target TEXT NOT NULL,item TEXT NOT NULL,sha256 TEXT NOT NULL,eligible INTEGER NOT NULL,PRIMARY KEY(control,target))",
        "CREATE INDEX IF NOT EXISTS authority_atomic_outcome_target ON authority_atomic_outcome(target,control)",
        "CREATE TABLE IF NOT EXISTS authority_control_support(control TEXT NOT NULL,control_digest TEXT NOT NULL,target TEXT NOT NULL,fingerprint TEXT NOT NULL,item TEXT NOT NULL,sha256 TEXT NOT NULL,eligible INTEGER NOT NULL,actor TEXT NOT NULL,policies TEXT NOT NULL,causes TEXT NOT NULL,evidence TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(control,target,fingerprint))",
        "CREATE INDEX IF NOT EXISTS authority_control_support_target ON authority_control_support(target,control,fingerprint)",
        "CREATE VIEW IF NOT EXISTS authority_control_facts AS SELECT d.control,d.target,d.item,d.sha256,d.eligible,d.actor,d.policies,d.causes,d.evidence,'' AS fingerprint FROM authority_control_delta d JOIN authority_control c ON c.id=d.control JOIN authority_objects o ON o.id=c.id AND o.sha256=c.sha256 AND o.control_kind='controlCommit' UNION ALL SELECT s.control,s.target,s.item,s.sha256,s.eligible,s.actor,s.policies,s.causes,s.evidence,s.fingerprint FROM authority_control_support s JOIN authority_atomic_accepted a ON a.control=s.control AND a.sha256=s.control_digest JOIN authority_control c ON c.id=a.control AND c.sha256=a.sha256 JOIN authority_objects o ON o.id=c.id AND o.sha256=c.sha256 AND o.control_kind='atomicControl'",
        "CREATE VIEW IF NOT EXISTS authority_control_outcomes AS SELECT d.control,d.target,d.item,d.sha256,d.eligible FROM authority_control_delta d JOIN authority_control c ON c.id=d.control JOIN authority_objects o ON o.id=c.id AND o.sha256=c.sha256 AND o.control_kind='controlCommit' UNION ALL SELECT d.control,d.target,d.item,d.sha256,d.eligible FROM authority_atomic_outcome d JOIN authority_atomic_accepted a ON a.control=d.control AND a.sha256=d.control_digest JOIN authority_control c ON c.id=a.control AND c.sha256=a.sha256 JOIN authority_objects o ON o.id=c.id AND o.sha256=c.sha256 AND o.control_kind='atomicControl'",
    ]
}
