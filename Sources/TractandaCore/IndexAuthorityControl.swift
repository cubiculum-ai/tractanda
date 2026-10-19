import CSQLite
import Foundation

/// Disposable sparse indexes over Store-verified, sealed causal controls. Caller owns the
/// serialized writer transaction, current authority, serving barriers and publication.
extension ItemIndex {
    func initializeAuthorityControlSchema() throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try controlCapacity(64 * 1024)
            for sql in [
                "CREATE TABLE IF NOT EXISTS authority_pending_effect(revision TEXT PRIMARY KEY,item TEXT NOT NULL,fingerprint TEXT NOT NULL,payload TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS authority_retired_items(item TEXT PRIMARY KEY)",
                "CREATE TABLE IF NOT EXISTS authority_control(id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,origin TEXT NOT NULL,ordinal INTEGER NOT NULL UNIQUE,bootstrap TEXT NOT NULL,bootstrap_digest TEXT NOT NULL,local_parent TEXT NOT NULL)",
                "CREATE INDEX IF NOT EXISTS authority_control_origin ON authority_control(origin,ordinal DESC)",
                "CREATE TABLE IF NOT EXISTS authority_invalidation(control TEXT NOT NULL,sha256 TEXT NOT NULL,cut TEXT NOT NULL,cut_digest TEXT NOT NULL,item TEXT NOT NULL,revision TEXT NOT NULL,digest TEXT NOT NULL,previous TEXT NOT NULL,PRIMARY KEY(control,previous))",
                "CREATE INDEX IF NOT EXISTS authority_invalidation_item ON authority_invalidation(item,control,previous)",
                "CREATE TABLE IF NOT EXISTS authority_absorbed(id TEXT PRIMARY KEY)",
                "CREATE TABLE IF NOT EXISTS authority_absorbed_cut(slot INTEGER PRIMARY KEY,id TEXT NOT NULL,sha256 TEXT NOT NULL,cost INTEGER NOT NULL)",
                "CREATE TABLE IF NOT EXISTS authority_control_pending(package TEXT NOT NULL,id TEXT NOT NULL,missing INTEGER NOT NULL,PRIMARY KEY(package,id))",
                "CREATE INDEX IF NOT EXISTS authority_control_pending_package ON authority_control_pending(package,missing,id)",
                "CREATE INDEX IF NOT EXISTS authority_control_pending_ready ON authority_control_pending(missing,id,package)",
                "CREATE INDEX IF NOT EXISTS authority_control_pending_object ON authority_control_pending(id,package)",
                "CREATE TABLE IF NOT EXISTS authority_control_heads(origin TEXT PRIMARY KEY,id TEXT NOT NULL,sha256 TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS authority_control_edges(child TEXT NOT NULL,parent TEXT NOT NULL,sha256 TEXT NOT NULL,PRIMARY KEY(child,parent))",
                "CREATE INDEX IF NOT EXISTS authority_control_children ON authority_control_edges(parent,child)",
                "CREATE TABLE IF NOT EXISTS authority_control_delta(control TEXT NOT NULL,target TEXT NOT NULL,item TEXT NOT NULL,sha256 TEXT NOT NULL,eligible INTEGER NOT NULL,actor TEXT NOT NULL,policies TEXT NOT NULL,causes TEXT NOT NULL,evidence TEXT NOT NULL,PRIMARY KEY(control,target))",
                "CREATE INDEX IF NOT EXISTS authority_control_target ON authority_control_delta(target,control)",
                "CREATE TABLE IF NOT EXISTS authority_control_affected(kind TEXT NOT NULL,value TEXT NOT NULL,item TEXT NOT NULL,PRIMARY KEY(kind,value,item))",
                "CREATE TABLE IF NOT EXISTS authority_control_work(token TEXT NOT NULL,id TEXT NOT NULL,ordinal INTEGER NOT NULL,covered INTEGER NOT NULL,processed INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(token,id))",
                "CREATE INDEX IF NOT EXISTS authority_control_work_order ON authority_control_work(token,processed,ordinal DESC,id)",
                "CREATE TABLE IF NOT EXISTS authority_exposure(id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,item TEXT NOT NULL,revision TEXT NOT NULL,digest TEXT NOT NULL,cut TEXT NOT NULL,cut_digest TEXT NOT NULL,modified TEXT NOT NULL,ticks INTEGER NOT NULL,cause TEXT NOT NULL)",
                "CREATE INDEX IF NOT EXISTS authority_exposure_order ON authority_exposure(item,ticks DESC,revision DESC,id DESC)",
                "CREATE INDEX IF NOT EXISTS authority_exposure_revision ON authority_exposure(revision,id)",
                "CREATE TABLE IF NOT EXISTS authority_local_exposure(witness TEXT PRIMARY KEY,item TEXT NOT NULL,revision TEXT NOT NULL,ticks INTEGER NOT NULL)",
                "CREATE INDEX IF NOT EXISTS authority_local_exposure_order ON authority_local_exposure(item,ticks DESC,revision DESC,witness DESC)",
                "CREATE INDEX IF NOT EXISTS authority_local_exposure_revision ON authority_local_exposure(revision,witness)",
                "CREATE TABLE IF NOT EXISTS authority_local_visibility_work(item TEXT PRIMARY KEY,token TEXT NOT NULL,kind TEXT NOT NULL,cause TEXT NOT NULL,sha256 TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS authority_local_acceptance(control TEXT PRIMARY KEY,sha256 TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS authority_local_assessment(revision TEXT PRIMARY KEY,sha256 TEXT NOT NULL,package TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS authority_local_bootstrap(pin TEXT PRIMARY KEY,sha256 TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS authority_local_history(revision TEXT PRIMARY KEY,item TEXT NOT NULL,digest TEXT NOT NULL,modified TEXT NOT NULL,ticks INTEGER NOT NULL,retired INTEGER NOT NULL)",
                "CREATE INDEX IF NOT EXISTS authority_local_history_order ON authority_local_history(item,retired,ticks DESC,revision DESC)",
                "CREATE TABLE IF NOT EXISTS authority_reconciliation_witness(witness TEXT PRIMARY KEY,witness_digest TEXT NOT NULL,item TEXT NOT NULL,revision TEXT NOT NULL UNIQUE,plan_digest TEXT NOT NULL,modified TEXT NOT NULL,parents TEXT NOT NULL,frontier TEXT NOT NULL,base_floor TEXT NOT NULL,cause_key TEXT NOT NULL,reservation_key TEXT NOT NULL,recovery INTEGER NOT NULL)",
                "CREATE INDEX IF NOT EXISTS authority_reconciliation_recovery ON authority_reconciliation_witness(recovery,revision)",
                "CREATE TABLE IF NOT EXISTS authority_reconciliation(key TEXT PRIMARY KEY,item TEXT NOT NULL,revision TEXT NOT NULL UNIQUE,witness TEXT NOT NULL,witness_digest TEXT NOT NULL,plan_digest TEXT NOT NULL,modified TEXT NOT NULL,output_digest TEXT,parents TEXT NOT NULL,frontier TEXT NOT NULL,base_floor TEXT NOT NULL)",
            ] { try execute(sql) }
            authorityControlSchemaReady = true
            // Local applied shared review is now a history proof alongside local controls.
            try initializeAuthorityReviewSchema()
        }
    }
    func clearAuthorityControlDerivedState() throws {
        try clearAuthorityReviewDerivedState()
        guard
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='authority_control')")
                == 1
        else { return }
        for table in [
            "authority_pending_effect", "authority_retired_items", "authority_control_pending",
            "authority_reconciliation_witness", "authority_absorbed",
            "authority_absorbed_cut", "authority_invalidation",
            "authority_reconciliation", "authority_local_exposure", "authority_local_visibility_work",
            "authority_local_acceptance", "authority_local_assessment",
            "authority_local_bootstrap", "authority_local_history",
            "authority_exposure",
            "authority_control_work", "authority_control_affected", "authority_control_delta",
            "authority_control_edges", "authority_control_heads", "authority_control",
        ] {
            try execute("DELETE FROM \(table)")
        }
    }
    // History is backed by private-local acceptance/bootstrap OR actual local exposure.
    // None of these membership rows confers current writing or reading authority.
    private var authorityLocalHistoryProof: String {
        "(EXISTS(SELECT 1 FROM authority_local_exposure l JOIN authority_exposure e ON e.id=l.witness WHERE l.revision=v.revision AND l.item=v.item AND l.ticks=v.ticks AND e.revision=v.revision AND e.item=v.item AND e.digest=v.digest AND e.ticks=v.ticks) OR EXISTS(SELECT 1 FROM authority_control_delta d INDEXED BY authority_control_target JOIN authority_local_acceptance l ON l.control=d.control JOIN authority_control c ON c.id=l.control AND c.sha256=l.sha256 WHERE d.target=v.revision AND d.item=v.item AND d.sha256=v.digest AND d.eligible=1) OR EXISTS(SELECT 1 FROM authority_local_assessment a JOIN authority_objects o ON o.id=a.revision AND o.sha256=a.sha256 AND o.item=v.item WHERE a.revision=v.revision AND a.sha256=v.digest) OR EXISTS(SELECT 1 FROM authority_review_applied a JOIN authority_review_event e ON e.id=a.decision AND e.sha256=a.sha256 JOIN authority_control c ON c.id=a.control AND c.sha256=a.control_digest WHERE a.recovery=0 AND e.item=v.item AND ((e.target=v.revision AND e.target_digest=v.digest) OR (a.revision=v.revision AND a.digest=v.digest))) OR EXISTS(SELECT 1 FROM authority_dependencies d JOIN authority_local_bootstrap l ON l.pin=d.target AND l.sha256=d.sha256 JOIN authority_objects o ON o.id=d.source AND o.sha256=v.digest WHERE d.source=v.revision AND d.kind='bootstrap'))"
    }
    private func enqueueLocalAuthorityVisibility(itemID: String, cause: AuthorityBinding, kind: String) throws
    {
        let token = try AuthorityRecordCodec.sha256(
            JSON.encode(
                ItemValue.object(["item": .text(itemID), "kind": .text(kind), "cause": cause.itemValue])))
        let s = try corpusPrepare(
            "SELECT token,kind,cause,sha256 FROM authority_local_visibility_work WHERE item=?", [itemID])
        let status = catalogueStep(s)
        if status == SQLITE_ROW {
            let oldToken = try controlText(s, 0)
            let oldKind = try controlText(s, 1)
            let old = try AuthorityBinding(recordID: controlText(s, 2), sha256: controlText(s, 3))
            sqlite3_finalize(s)
            if oldToken == token || (oldKind == "control" && kind == "bootstrap") { return }
            if oldKind == "control", kind == "control", try authorityControlContains(cause, in: old) {
                return
            }
        } else {
            sqlite3_finalize(s)
            guard status == SQLITE_DONE else { throw graphSQLiteError() }
        }
        try controlCapacity(8192)
        try execute(
            "INSERT INTO authority_local_visibility_work VALUES(?,?,?,?,?) ON CONFLICT(item) DO UPDATE SET token=excluded.token,kind=excluded.kind,cause=excluded.cause,sha256=excluded.sha256",
            [itemID, token, kind, cause.recordID, cause.sha256])
    }
    func authorityLocalVisibilityWorkPage(afterItemID: String? = nil, limit: Int = 128) throws -> [(
        itemID: String, token: String
    )] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit) else { throw controlInvalid("Invalid local visibility page.") }
            let s = try corpusPrepare(
                "SELECT item,token FROM authority_local_visibility_work"
                    + (afterItemID == nil ? "" : " WHERE item>?") + " ORDER BY item LIMIT ?",
                (afterItemID.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var rows: [(itemID: String, token: String)] = []
            var bytes = 0
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return rows }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                if try !controlBoundRow(s, bytes: &bytes, prefix: !rows.isEmpty) { return rows }
                rows.append(try (controlText(s, 0), controlText(s, 1)))
            }
        }
    }
    func authorityLocalVisibilityWorkCount() throws -> Int {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let n = try controlNumber("SELECT COUNT(*) FROM authority_local_visibility_work")
            guard let count = Int(exactly: n), count >= 0 else {
                throw controlResource("Visibility work count overflowed.")
            }
            return count
        }
    }
    func clearAuthorityLocalVisibilityWork(itemID: String, token: String) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.digest(.text(token))
            try execute(
                "DELETE FROM authority_local_visibility_work WHERE item=? AND token=?", [itemID, token])
        }
    }
    /// Main calls only for an exact private sealed LOCAL acceptance receipt.
    func retainLocalAuthorityAcceptance(_ plan: AuthorityStore.VerifiedControlPlan) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try hasValidatedAuthorityControl(plan.binding),
                try AuthorityStore.VerifiedControlPlan(control: plan.control) == plan
            else { throw controlInvalid("Local historical acceptance lacks its exact validated control.") }
            if try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_local_acceptance WHERE control=? AND sha256=?)",
                [plan.binding.recordID, plan.binding.sha256]) == 1
            {
                return
            }
            try controlCapacity(8192)
            try execute(
                "INSERT OR IGNORE INTO authority_local_acceptance VALUES(?,?)",
                [plan.binding.recordID, plan.binding.sha256])
            for delta in plan.deltas {
                try enqueueLocalAuthorityVisibility(
                    itemID: delta.target.itemID, cause: plan.binding, kind: "control")
                guard delta.eligible else { continue }
                if let evidence = delta.evidence {
                    try controlOriginalBinding(evidence, kind: "authoredEvidence")
                }
                try retainLocalHistoryTarget(delta.target)
            }
        }
    }
    /// Main has validated an exact sealed PRIVATE eligible assessment. No shared
    /// acceptance control or clock visibility is created for received materializations.
    func retainLocalAssessedMaterialization(_ original: AuthorityRevision, packageID: String) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let value = original.revision
            guard let p = try value.provenance, p.kind == .automaticMerge,
                [RevisionMerge.profile, AuthorityStore.reconciliationProfile].contains(p.mergeProfile ?? ""),
                p.writtenFields.isEmpty, p.unsetFields.isEmpty,
                let receipt = try authorityReceipt(objectID: value.revisionID, packageID: packageID),
                receipt.descriptor.kind == .item,
                receipt.descriptor.sha256 == original.sha256,
                receipt.descriptor.length == original.originalBytes.count
            else {
                throw controlInvalid(
                    "Private assessed materialization differs from its exact retained receipt.")
            }
            if try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_local_assessment WHERE revision=? AND sha256=?)",
                [value.revisionID, original.sha256]) == 1
            {
                return
            }
            try controlCapacity(8192)
            try execute(
                "INSERT INTO authority_local_assessment VALUES(?,?,?)",
                [value.revisionID, original.sha256, packageID])
            try retainLocalHistoryTarget(
                .init(itemID: value.itemID, revisionID: value.revisionID, sha256: original.sha256))
            try enqueueLocalAuthorityVisibility(
                itemID: value.itemID, cause: .init(recordID: value.revisionID, sha256: original.sha256),
                kind: "assessment:" + packageID)
        }
    }
    /// Only Main's reviewed, private configured initial pin invokes this bounded replay.
    func retainLocalBootstrapAcceptance(_ pin: AuthorityStore.BootstrapPin) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let binding = try AuthorityBinding(recordID: pin.recordID, sha256: pin.sha256)
            try controlOriginalBinding(binding, kind: "bootstrap")
            guard
                try controlNumber(
                    "SELECT EXISTS(SELECT 1 FROM authority_local_bootstrap WHERE pin!=? OR sha256!=?)",
                    [pin.recordID, pin.sha256]) == 0
            else { throw controlInvalid("Local bootstrap history is pinned to another initial baseline.") }
            if try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_local_bootstrap WHERE pin=? AND sha256=?)",
                [pin.recordID, pin.sha256]) == 1
            {
                return
            }
            try controlCapacity(8192)
            try execute(
                "INSERT OR IGNORE INTO authority_local_bootstrap VALUES(?,?)", [pin.recordID, pin.sha256])
            var after: String?
            while true {
                let ids = try controlStringPage(
                    "SELECT source FROM authority_dependencies INDEXED BY authority_dependencies_reverse WHERE target=? AND kind='bootstrap' AND sha256=? AND package=''"
                        + (after == nil ? "" : " AND source>?") + " ORDER BY source LIMIT 128",
                    [pin.recordID, pin.sha256] + (after.map { [$0] } ?? []), limit: 128)
                if ids.isEmpty { break }
                for id in ids {
                    let s = try corpusPrepare(
                        "SELECT item,sha256 FROM authority_objects WHERE id=? AND kind='item'", [id])
                    defer { sqlite3_finalize(s) }
                    guard catalogueStep(s) == SQLITE_ROW else {
                        throw controlInvalid("Local pin history is missing its exact original.")
                    }
                    try retainLocalHistoryTarget(
                        .init(itemID: controlText(s, 0), revisionID: id, sha256: controlText(s, 1)))
                    try enqueueLocalAuthorityVisibility(
                        itemID: controlText(s, 0), cause: binding, kind: "bootstrap")
                }
                after = ids.last
            }
        }
    }
    private func retainLocalHistoryTarget(_ target: AuthorityStore.Target) throws {
        try controlTarget(target)
        let s = try corpusPrepare("SELECT modified FROM authority_objects WHERE id=?", [target.revisionID])
        defer { sqlite3_finalize(s) }
        guard catalogueStep(s) == SQLITE_ROW else {
            throw controlInvalid("Local history original is absent.")
        }
        let modified = try controlText(s, 0)
        let ticks = try RevisionTimestamp(modified).ticks
        try controlCapacity(8192)
        try execute(
            "INSERT OR IGNORE INTO authority_local_history VALUES(?,?,?,?,?,?)",
            [
                target.revisionID, target.itemID, target.sha256, modified, String(ticks),
                (try revision(target.revisionID)) == nil ? "1" : "0",
            ])
        try execute(
            "INSERT OR IGNORE INTO authority_retired_items SELECT ? WHERE NOT EXISTS(SELECT 1 FROM revision_catalog WHERE item=?)",
            [target.itemID, target.itemID])
    }
    func noteAuthorityDispositionEffect(_ delta: AuthorityStore.DispositionDelta) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityStore.DispositionDelta(value: delta.itemValue)
            try controlTarget(delta.target)
            let ids = delta.causes.map(\.recordID)
            guard !ids.isEmpty, ids == Array(Set(ids)).sorted() else {
                throw controlInvalid("Disposition effects need sorted unique validated causes.")
            }
            for cause in delta.causes {
                guard try hasValidatedAuthorityControl(cause) else {
                    throw controlInvalid("Disposition effect cause is not a validated control.")
                }
            }
            let bytes = try JSON.encode(delta.itemValue)
            guard bytes.count <= AuthorityRecord.maximumBytes else {
                throw controlResource("Disposition effect exceeds its metadata window.")
            }
            try controlCapacity(UInt64(bytes.count) * 8 + 8192)
            let fingerprint = AuthorityRecordCodec.sha256(bytes)
            try execute(
                "INSERT INTO authority_pending_effect VALUES(?,?,?,?) ON CONFLICT(revision) DO UPDATE SET item=excluded.item,fingerprint=excluded.fingerprint,payload=excluded.payload WHERE authority_pending_effect.fingerprint!=excluded.fingerprint",
                [
                    delta.target.revisionID, delta.target.itemID, fingerprint,
                    String(decoding: bytes, as: UTF8.self),
                ])
        }
    }
    func authorityDispositionEffectPage(afterRevisionID: String? = nil, limit: Int = 128) throws
        -> [AuthorityStore.DispositionDelta]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit) else { throw controlInvalid("Invalid pending-effect page.") }
            let s = try corpusPrepare(
                "SELECT payload FROM authority_pending_effect"
                    + (afterRevisionID == nil ? "" : " WHERE revision>?") + " ORDER BY revision LIMIT ?",
                (afterRevisionID.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var rows: [AuthorityStore.DispositionDelta] = []
            var bytes = 0
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return rows }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                if try !controlBoundRow(s, bytes: &bytes, prefix: !rows.isEmpty) { return rows }
                rows.append(try .init(value: JSON.decode(ItemValue.self, Data(controlText(s, 0).utf8))))
            }
        }
    }
    /// Main calls only after its private local publication receipt is sealed, while
    /// this exact control is still the current local head in the serialized transaction.
    func clearAuthorityDispositionEffects(coveredBy control: AuthorityBinding, originID: String) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try authorityControlHead(originID: originID) == control else {
                throw controlInvalid("Old or foreign control cannot clear pending effects.")
            }
            var cursor: String?
            while true {
                let page = try authorityControlDeltaPage(control, afterRevisionID: cursor, limit: 128)
                if page.isEmpty { break }
                for delta in page {
                    for cause in delta.causes {
                        guard try hasValidatedAuthorityControl(cause),
                            try authorityControlContains(cause, in: control)
                        else { throw controlInvalid("Covering control omitted a bound effect cause.") }
                    }
                    let bytes = try JSON.encode(delta.itemValue)
                    try execute(
                        "DELETE FROM authority_pending_effect WHERE revision=? AND fingerprint=? AND payload=?",
                        [
                            delta.target.revisionID, AuthorityRecordCodec.sha256(bytes),
                            String(decoding: bytes, as: UTF8.self),
                        ])
                }
                cursor = page.last?.target.revisionID
            }
        }
    }
    func authorityHistoricalCount(itemID: String) throws -> Int {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let n = try controlNumber(
                "SELECT (SELECT COUNT(*) FROM revision_catalog WHERE item=?)+(SELECT COUNT(*) FROM authority_local_history v WHERE item=? AND retired=1 AND "
                    + authorityLocalHistoryProof
                    + " AND NOT EXISTS(SELECT 1 FROM revision_catalog r WHERE r.revision=v.revision))",
                [itemID, itemID])
            guard let count = Int(exactly: n), count >= 0 else {
                throw controlResource("Physical history count overflowed.")
            }
            return count
        }
    }
    func authorityRetiredItemPage(after: String? = nil, limit: Int = 128) throws -> [String] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try controlStringPage(
                "SELECT item FROM authority_retired_items WHERE NOT EXISTS(SELECT 1 FROM revision_catalog r WHERE r.item=authority_retired_items.item) AND EXISTS(SELECT 1 FROM authority_local_history v WHERE v.item=authority_retired_items.item AND "
                    + authorityLocalHistoryProof + ")"
                    + (after == nil ? "" : " AND item>?") + " ORDER BY item LIMIT ?",
                (after.map { [$0] } ?? []) + [String(limit)], limit: limit)
        }
    }
    func authorityChildPage(parentID: String, after: String? = nil, limit: Int = 128) throws
        -> [AuthorityStore.RetainedObject]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit) else { throw controlInvalid("Invalid child page limit.") }
            return try authorityRows(
                "SELECT o.id,o.kind,o.length,o.sha256,o.path,p.package,p.peer,p.configuration,p.permitted FROM authority_dependencies d INDEXED BY authority_dependencies_reverse CROSS JOIN authority_objects o ON o.id=d.source AND o.kind='item' CROSS JOIN authority_packages p ON p.object=o.id AND p.package=(SELECT q.package FROM authority_packages q INDEXED BY authority_packages_object WHERE q.object=o.id ORDER BY q.permitted DESC,q.package LIMIT 1) WHERE d.target=? AND d.kind='parent' AND d.package=''"
                    + (after == nil ? "" : " AND d.source>?") + " ORDER BY d.source LIMIT ?",
                [parentID] + (after.map { [$0] } ?? []) + [String(limit)])
        }
    }
    func authorityHeldReceipts(operationID: String, originID: String, limit: Int = 1024) throws
        -> [AuthorityStore.RetainedObject]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit) else { throw controlInvalid("Invalid held-receipt limit.") }
            let rows = try authorityRows(
                "SELECT o.id,o.kind,o.length,o.sha256,o.path,p.package,p.peer,p.configuration,p.permitted FROM authority_original_receipts r JOIN authority_objects o ON o.id=r.revision JOIN authority_dispositions d ON d.object=o.id AND d.state!='eligible' JOIN authority_packages p ON p.object=o.id AND p.package=(SELECT q.package FROM authority_packages q INDEXED BY authority_packages_object WHERE q.object=o.id ORDER BY q.permitted DESC,q.package LIMIT 1) WHERE r.origin=? AND r.operation=? ORDER BY r.revision LIMIT ?",
                [originID, operationID, String(limit + 1)])
            // This is a collision check, not prefix pagination: never hide a later alias.
            guard rows.count <= limit, rows.count < limit + 1 else {
                throw controlResource("Held receipts exceed their count window.")
            }
            let count = try controlNumber(
                "SELECT COUNT(*) FROM authority_original_receipts r JOIN authority_dispositions d ON d.object=r.revision AND d.state!='eligible' WHERE r.origin=? AND r.operation=?",
                [originID, operationID])
            guard count == Int64(rows.count) else {
                throw controlResource("Held receipts exceed their aggregate byte window.")
            }
            return rows
        }
    }
    func hasValidatedAuthorityControl(_ binding: AuthorityBinding) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_control WHERE id=? AND sha256=?)",
                [binding.recordID, binding.sha256]) == 1
        }
    }
    func authorityControlHead(originID: String) throws -> AuthorityBinding? {
        _ = try AuthorityRecord.persistentID(.text(originID))
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT id,sha256 FROM authority_control_heads WHERE origin=?",
                [originID])
            defer { sqlite3_finalize(s) }
            let status = catalogueStep(s)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            return try AuthorityBinding(recordID: controlText(s, 0), sha256: controlText(s, 1))
        }
    }
    func authorityControlParents(_ binding: AuthorityBinding) throws -> [AuthorityBinding] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try hasValidatedAuthorityControl(binding) else {
                throw controlInvalid("Unknown exact control cut.")
            }
            let s = try corpusPrepare(
                "SELECT parent,sha256 FROM authority_control_edges WHERE child=? ORDER BY parent",
                [binding.recordID])
            defer { sqlite3_finalize(s) }
            var result: [AuthorityBinding] = []
            var bytes = 0
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                try controlBoundRow(s, bytes: &bytes, prefix: false)
                result.append(try .init(recordID: controlText(s, 0), sha256: controlText(s, 1)))
            }
        }
    }
    func retainValidatedControl(_ plan: AuthorityStore.VerifiedControlPlan) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let record = plan.control.record
            try controlOriginal(plan.control)
            if try hasValidatedAuthorityControl(plan.binding) { return }
            guard
                try controlNumber("SELECT COUNT(*) FROM authority_control WHERE id=?", [record.recordID]) == 0
            else { throw controlInvalid("Control identity changed digest.") }
            let canonical = try AuthorityStore.VerifiedControlPlan(control: plan.control)
            guard canonical == plan else {
                throw controlInvalid("Control plan differs from sealed canonical bytes.")
            }
            for parent in plan.parents {
                guard try hasValidatedAuthorityControl(parent) else {
                    throw controlInvalid("Control parent is absent or unvalidated.")
                }
            }
            if let head = try authorityControlHead(originID: record.originReplicaID) {
                guard plan.localParent == head, plan.parents.contains(head) else {
                    throw controlInvalid("Origin control chain forked or skipped its prior head.")
                }
            }
            if let localParent = plan.localParent {
                guard
                    try controlNumber(
                        "SELECT EXISTS(SELECT 1 FROM authority_control WHERE id=? AND sha256=? AND origin=?)",
                        [localParent.recordID, localParent.sha256, record.originReplicaID]) == 1
                else { throw controlInvalid("Local control parent belongs to another issuer.") }
            }
            if let bootstrap = plan.bootstrap {
                try controlOriginalBinding(bootstrap, kind: "bootstrap")
            }
            try controlCapacity(UInt64(plan.control.originalBytes.count) * 16 + 64 * 1024)
            let previous = try controlNumber("SELECT COALESCE(MAX(ordinal),0) FROM authority_control")
            let next = previous.addingReportingOverflow(1)
            guard !next.overflow else { throw controlResource("Control ordinal exhausted.") }
            try execute(
                "INSERT INTO authority_control VALUES(?,?,?,?,?,?,?)",
                [
                    record.recordID, plan.control.sha256, record.originReplicaID, String(next.partialValue),
                    plan.bootstrap?.recordID ?? "", plan.bootstrap?.sha256 ?? "",
                    plan.localParent?.recordID ?? "",
                ])
            try execute(
                "INSERT OR REPLACE INTO authority_control_heads VALUES(?,?,?)",
                [record.originReplicaID, record.recordID, plan.control.sha256])
            for parent in plan.parents {
                try execute(
                    "INSERT INTO authority_control_edges VALUES(?,?,?)",
                    [record.recordID, parent.recordID, parent.sha256])
            }
            for delta in plan.deltas {
                try checkCatalogueScanProgress()
                try controlTarget(delta.target)
                try execute(
                    "INSERT INTO authority_control_delta VALUES(?,?,?,?,?,?,?,?,?)",
                    [
                        record.recordID, delta.target.revisionID, delta.target.itemID, delta.target.sha256,
                        delta.eligible ? "1" : "0", delta.actor,
                        String(decoding: try JSON.encode(delta.policyIDs), as: UTF8.self),
                        String(decoding: try JSON.encode(delta.causes), as: UTF8.self),
                        String(
                            decoding: try JSON.encode(
                                ItemValue.list(delta.evidence.map { [$0.itemValue] } ?? [])), as: UTF8.self),
                    ])
                _ = try AuthorityRecord.text(.text(delta.actor))
                try execute(
                    "INSERT OR IGNORE INTO authority_control_affected VALUES('actor',?,?)",
                    [delta.actor, delta.target.itemID])
                for policy in delta.policyIDs {
                    _ = try AuthorityRecord.persistentID(.text(policy))
                    try execute(
                        "INSERT OR IGNORE INTO authority_control_affected VALUES('policy',?,?)",
                        [policy, delta.target.itemID])
                }
                for cause in delta.causes {
                    try controlOriginalBinding(cause)
                    try execute(
                        "INSERT OR IGNORE INTO authority_control_affected VALUES('cause',?,?)",
                        [cause.sha256, delta.target.itemID])
                }
            }
            try execute("DELETE FROM authority_control_pending WHERE id=?", [record.recordID])
            try execute(
                "UPDATE authority_control_pending SET missing=missing-1 WHERE missing>0 AND id IN(SELECT source FROM authority_dependencies INDEXED BY authority_dependencies_reverse WHERE target=? AND kind='controlParent' AND package='' AND sha256=?)",
                [record.recordID, plan.control.sha256])

        }
    }
    func authorityControlContains(_ ancestor: AuthorityBinding, in cut: AuthorityBinding) throws -> Bool {
        let token = "contains." + Identifier.make()
        defer {
            try? execute("DELETE FROM authority_control_work WHERE token=?", [token])
            try? authorityEndWalk(token: token)
        }
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try hasValidatedAuthorityControl(ancestor), try hasValidatedAuthorityControl(cut) else {
                return false
            }
            if ancestor == cut { return true }
            if try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_absorbed_cut WHERE slot=1 AND id=? AND sha256=?)",
                [cut.recordID, cut.sha256]) == 1
            {
                return try controlNumber(
                    "SELECT EXISTS(SELECT 1 FROM authority_absorbed WHERE id=?)", [ancestor.recordID]) == 1
            }
            try authorityBeginWalk(token: token)
            try controlQueue(token: token, id: cut.recordID, covered: false)
            while let node = try controlNext(token) {
                try checkCatalogueScanProgress()
                if node.0 == ancestor.recordID { return true }
                for parent in try authorityControlParents(
                    .init(recordID: node.0, sha256: controlDigest(node.0)))
                { try controlQueue(token: token, id: parent.recordID, covered: false) }
                try execute(
                    "UPDATE authority_control_work SET processed=1 WHERE token=? AND id=?", [token, node.0])
            }
            return false
        }
    }
    /// One current-local-cut absorption cache, never an all-cut reachability closure.
    /// Cache validity is removed before extension, so interruption cannot expose partial proof.
    func authorityControlIsAbsorbed(_ binding: AuthorityBinding, localCut: AuthorityBinding?) throws -> Bool {
        guard let localCut else { return false }
        let token = "absorbed." + Identifier.make()
        defer {
            try? execute("DELETE FROM authority_control_work WHERE token=?", [token])
            try? authorityEndWalk(token: token)
        }
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try hasValidatedAuthorityControl(localCut), try hasValidatedAuthorityControl(binding) else {
                return false
            }
            let marker = try corpusPrepare("SELECT id,sha256,cost FROM authority_absorbed_cut WHERE slot=1")
            let status = catalogueStep(marker)
            var old: String?
            var cost: Int64 = 0
            if status == SQLITE_ROW {
                old = try controlText(marker, 0)
                cost = sqlite3_column_int64(marker, 2)
                if try old == localCut.recordID && controlText(marker, 1) == localCut.sha256 {
                    sqlite3_finalize(marker)
                    return try controlNumber(
                        "SELECT EXISTS(SELECT 1 FROM authority_absorbed WHERE id=?)", [binding.recordID]) == 1
                }
            } else if status != SQLITE_DONE {
                sqlite3_finalize(marker)
                throw graphSQLiteError()
            }
            sqlite3_finalize(marker)
            var cursor = localCut.recordID
            var extends = false
            while let previous = old {
                if cursor == previous {
                    extends = true
                    break
                }
                try checkCatalogueScanProgress()
                let p = try corpusPrepare("SELECT local_parent FROM authority_control WHERE id=?", [cursor])
                let state = catalogueStep(p)
                guard state == SQLITE_ROW else {
                    sqlite3_finalize(p)
                    throw controlInvalid("Absorption chain is missing.")
                }
                cursor = try controlText(p, 0)
                sqlite3_finalize(p)
                if cursor.isEmpty { break }
            }
            try execute("DELETE FROM authority_absorbed_cut")
            if !extends {
                try execute("DELETE FROM authority_absorbed")
                cost = 0
            }
            try authorityBeginWalk(token: token)
            try controlQueue(token: token, id: localCut.recordID, covered: false)
            while let node = try controlNext(token) {
                try checkCatalogueScanProgress()
                if try controlNumber("SELECT EXISTS(SELECT 1 FROM authority_absorbed WHERE id=?)", [node.0])
                    == 0
                {
                    let next = cost.addingReportingOverflow(256)
                    guard !next.overflow, next.partialValue >= 0 else {
                        throw controlResource("Absorption staging overflowed.")
                    }
                    try controlCapacity(UInt64(next.partialValue))
                    cost = next.partialValue
                    try execute("INSERT INTO authority_absorbed VALUES(?)", [node.0])
                    let parents = try authorityControlParents(
                        try .init(recordID: node.0, sha256: controlDigest(node.0)))
                    for parent in parents {
                        try controlQueue(token: token, id: parent.recordID, covered: false)
                    }
                }
                try execute(
                    "UPDATE authority_control_work SET processed=1 WHERE token=? AND id=?", [token, node.0])
            }
            try execute(
                "INSERT INTO authority_absorbed_cut VALUES(1,?,?,?)",
                [localCut.recordID, localCut.sha256, String(cost)])
            return try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_absorbed WHERE id=?)", [binding.recordID]) == 1
        }
    }
    private func controlDigest(_ id: String) throws -> String {
        let s = try corpusPrepare("SELECT sha256 FROM authority_control WHERE id=?", [id])
        defer { sqlite3_finalize(s) }
        guard catalogueStep(s) == SQLITE_ROW else { throw controlInvalid("Missing control digest.") }
        return try controlText(s, 0)
    }
    func authorityControlDeltaPage(
        _ binding: AuthorityBinding, afterRevisionID: String? = nil, limit: Int = 128
    ) throws -> [AuthorityStore.DispositionDelta] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit), try hasValidatedAuthorityControl(binding) else {
                throw controlInvalid("Unknown control or invalid delta page.")
            }
            let s = try corpusPrepare(
                "SELECT item,target,sha256,eligible,actor,policies,causes,evidence FROM authority_control_delta WHERE control=?"
                    + (afterRevisionID == nil ? "" : " AND target>?") + " ORDER BY target LIMIT ?",
                [binding.recordID] + (afterRevisionID.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var rows: [AuthorityStore.DispositionDelta] = []
            var bytes = 0
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return rows }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                if try !controlBoundRow(s, bytes: &bytes, prefix: !rows.isEmpty) { return rows }
                let selected = try AuthorityRecord.list(
                    JSON.decode(ItemValue.self, Data(controlText(s, 7).utf8)))
                guard selected.count <= 1 else {
                    throw controlInvalid("Normalized control evidence has multiple selections.")
                }
                rows.append(
                    try .init(
                        target: .init(
                            itemID: controlText(s, 0), revisionID: controlText(s, 1),
                            sha256: controlText(s, 2)), eligible: sqlite3_column_int(s, 3) != 0,
                        actor: controlText(s, 4),
                        policyIDs: JSON.decode([String].self, Data(controlText(s, 5).utf8)),
                        causes: JSON.decode([AuthorityBinding].self, Data(controlText(s, 6).utf8)),
                        evidence: try selected.first.map(AuthorityBinding.init(value:))))
            }
        }
    }
    /// Exact causal-maximal disposition reduction. Descending topological order lets a
    /// covered bit propagate through converging paths without a transitive closure.
    func eligibilityAtCut(revisionID: String, cut: AuthorityBinding) throws
        -> AuthorityStore.HistoricalEligibility
    {
        _ = try AuthorityRecord.persistentID(.text(revisionID))
        let token = "cut." + Identifier.make()
        defer {
            try? execute("DELETE FROM authority_control_work WHERE token=?", [token])
            try? authorityEndWalk(token: token)
        }
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try hasValidatedAuthorityControl(cut) else { return .unknown }
            guard let original = try retainedAuthorityObject(id: revisionID),
                original.descriptor.kind == .item
            else { return .unknown }
            // Ordinary publication's own acceptance is a constant-work fast path.
            if let state = try controlDelta(cut.recordID, revisionID, original.descriptor.sha256) {
                return state ? .eligible : .held
            }
            try authorityBeginWalk(token: token)
            try controlQueue(token: token, id: cut.recordID, covered: false)
            var sawEligible = false
            var sawHeld = false
            while let node = try controlNext(token) {
                try checkCatalogueScanProgress()
                var covered = node.1
                if !covered {
                    if let state = try controlDelta(node.0, revisionID, original.descriptor.sha256) {
                        sawEligible = sawEligible || state
                        sawHeld = sawHeld || !state
                        covered = true
                    } else if try controlNumber(
                        "SELECT EXISTS(SELECT 1 FROM authority_control c JOIN authority_dependencies d ON d.target=c.bootstrap AND d.sha256=c.bootstrap_digest AND d.kind='bootstrap' WHERE c.id=? AND d.source=?)",
                        [node.0, revisionID]) == 1
                    {
                        sawEligible = true
                        covered = true
                    }
                }
                let parents = try corpusPrepare(
                    "SELECT parent FROM authority_control_edges WHERE child=? ORDER BY parent", [node.0])
                defer { sqlite3_finalize(parents) }
                while true {
                    let status = catalogueStep(parents)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { throw graphSQLiteError() }
                    try controlQueue(token: token, id: controlText(parents, 0), covered: covered)
                }
                try execute(
                    "UPDATE authority_control_work SET processed=1 WHERE token=? AND id=?", [token, node.0])
            }
            // A conflicting maximal hold never becomes an implicit approval.
            return sawHeld ? .held : (sawEligible ? .eligible : .unknown)
        }
    }
    /// Complete negative causal-maximal dispositions at the reviewed PRE cut.
    /// Uses the same bounded sparse control walk as eligibilityAtCut.
    func authorityReviewControlHolds(revisionID: String, cut: AuthorityBinding) throws -> [AuthorityBinding] {
        let token = "review.holds." + Identifier.make()
        defer {
            try? execute("DELETE FROM authority_control_work WHERE token=?", [token])
            try? authorityEndWalk(token: token)
        }
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try hasValidatedAuthorityControl(cut),
                let raw = try retainedAuthorityObject(id: revisionID), raw.descriptor.kind == .item
            else {
                throw controlInvalid("Review PRE cut or target is not validated.")
            }
            try authorityBeginWalk(token: token)
            try controlQueue(token: token, id: cut.recordID, covered: false)
            var result: [AuthorityBinding] = []
            var bytes = 0
            while let node = try controlNext(token) {
                try checkCatalogueScanProgress()
                var covered = node.1
                if !covered {
                    if let state = try controlDelta(node.0, revisionID, raw.descriptor.sha256) {
                        covered = true
                        if !state {
                            let binding = try AuthorityBinding(
                                recordID: node.0, sha256: controlDigest(node.0))
                            guard result.count < 256,
                                bytes + binding.recordID.utf8.count + binding.sha256.utf8.count + 256
                                    <= graphMaximumPageBytes
                            else {
                                throw controlResource("Complete control-hold frontier exceeds its window.")
                            }
                            bytes += binding.recordID.utf8.count + binding.sha256.utf8.count + 256
                            result.append(binding)
                        }
                    } else if try controlNumber(
                        "SELECT EXISTS(SELECT 1 FROM authority_control c JOIN authority_dependencies d ON d.target=c.bootstrap AND d.sha256=c.bootstrap_digest AND d.kind='bootstrap' WHERE c.id=? AND d.source=?)",
                        [node.0, revisionID]) == 1
                    {
                        covered = true
                    }
                }
                for parent in try authorityControlParents(
                    .init(recordID: node.0, sha256: controlDigest(node.0)))
                {
                    try controlQueue(token: token, id: parent.recordID, covered: covered)
                }
                try execute(
                    "UPDATE authority_control_work SET processed=1 WHERE token=? AND id=?", [token, node.0])
            }
            return result.sorted { $0.recordID < $1.recordID }
        }
    }
    func affectedAuthorityItemPage(kind: String, value: String, after: String? = nil, limit: Int = 128) throws
        -> [String]
    {
        guard ["actor", "policy", "cause"].contains(kind) else {
            throw controlInvalid("Unknown affected-scope key.")
        }
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            try controlStringPage(
                "SELECT item FROM authority_control_affected WHERE kind=? AND value=?"
                    + (after == nil ? "" : " AND item>?") + " ORDER BY item LIMIT ?",
                [kind, value] + (after.map { [$0] } ?? []) + [String(limit)], limit: limit)
        }
    }
    func retainValidatedInvalidation(_ plan: AuthorityStore.VerifiedInvalidationPlan) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let policy = plan.policy.revision
            guard policy.classID == "AccessConfigurationItem" || policy.fields["permissions"]?.map != nil,
                policy.supersedes == plan.previousPolicyID,
                try hasValidatedAuthorityControl(plan.control),
                try hasValidatedAuthorityControl(plan.sourceCut),
                try eligibilityAtCut(revisionID: policy.revisionID, cut: plan.control) == .eligible,
                try authorityControlParents(plan.control).contains(plan.sourceCut)
            else {
                throw controlInvalid("Invalidation does not bind validated policy/control source context.")
            }
            try recordValidatedAuthorityInvalidation(
                .init(
                    control: plan.control, sourceCut: plan.sourceCut,
                    policy: .init(
                        itemID: policy.itemID, revisionID: policy.revisionID, sha256: plan.policy.sha256),
                    previousPolicyID: plan.previousPolicyID))
        }
    }
    /// Shared storage primitive; callers validate either a linear authored transition
    /// or the exact fully applied atomic review closure before entering here.
    func recordValidatedAuthorityInvalidation(_ transition: AuthorityStore.Invalidation) throws {
        try controlTarget(transition.policy)
        try controlCapacity(8192)
        let values = [
            transition.control.recordID, transition.control.sha256,
            transition.sourceCut.recordID, transition.sourceCut.sha256,
            transition.policy.itemID, transition.policy.revisionID, transition.policy.sha256,
            transition.previousPolicyID,
        ]
        try execute("INSERT OR IGNORE INTO authority_invalidation VALUES(?,?,?,?,?,?,?,?)", values)
        guard
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_invalidation WHERE control=? AND sha256=? AND cut=? AND cut_digest=? AND item=? AND revision=? AND digest=? AND previous=?)",
                values) == 1
        else { throw controlInvalid("Invalidation identity rebound.") }
    }
    func authorityInvalidationPage(
        policyItemID: String, after: (controlID: String, previousPolicyID: String)? = nil, limit: Int = 128
    )
        throws -> [AuthorityStore.Invalidation]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit) else { throw controlInvalid("Invalid invalidation page.") }
            _ = try AuthorityRecord.persistentID(.text(policyItemID))
            if let after {
                _ = try AuthorityRecord.persistentID(.text(after.controlID))
                _ = try AuthorityRecord.persistentID(.text(after.previousPolicyID))
            }
            let s = try corpusPrepare(
                "SELECT control,sha256,cut,cut_digest,item,revision,digest,previous FROM authority_invalidation WHERE item=?"
                    + (after == nil ? "" : " AND (control,previous)>(?,?)")
                    + " ORDER BY control,previous LIMIT ?",
                [policyItemID] + (after.map { [$0.controlID, $0.previousPolicyID] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var rows: [AuthorityStore.Invalidation] = []
            var bytes = 0
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return rows }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                if try !controlBoundRow(s, bytes: &bytes, prefix: !rows.isEmpty) { return rows }
                rows.append(
                    try .init(
                        control: .init(recordID: controlText(s, 0), sha256: controlText(s, 1)),
                        sourceCut: .init(recordID: controlText(s, 2), sha256: controlText(s, 3)),
                        policy: .init(
                            itemID: controlText(s, 4), revisionID: controlText(s, 5),
                            sha256: controlText(s, 6)), previousPolicyID: controlText(s, 7)))
            }
        }
    }
    /// The Store ready/admission gate supplies active, fully verified originals.
    /// This proves only causal coverage; Main still compares every protected policy value.
    func authorityPolicyFrontierCovered(parentID: String, physicalFrontier: [String]) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard !physicalFrontier.isEmpty, try acceptedGraphProofIsCurrent(),
                let parent = try revision(parentID)
            else { return false }
            var bytes = 0
            for id in physicalFrontier {
                guard id.utf8.count <= graphMaximumPageBytes - min(bytes, graphMaximumPageBytes) else {
                    throw controlResource("Policy frontier exceeds its metadata byte window.")
                }
                bytes += id.utf8.count
            }
            func context(_ row: CatalogueRow) throws -> [String] {
                if row.provenance?.kind == .automaticMerge {
                    guard let p = row.provenance,
                        [RevisionMerge.profile, AuthorityStore.reconciliationProfile].contains(
                            p.mergeProfile ?? "")
                    else { throw controlInvalid("Unknown active materialization policy context.") }
                    return p.frontier
                }
                return [row.revisionID]
            }
            let actual = try context(parent)
            for id in actual {
                guard let row = try revision(id), row.itemID == parent.itemID,
                    row.provenance?.kind != .automaticMerge
                else { return false }
            }
            for maximum in physicalFrontier {
                try checkCatalogueScanProgress()
                guard let row = try revision(maximum), row.itemID == parent.itemID else { return false }
                for authored in try context(row) {
                    guard let event = try revision(authored), event.itemID == parent.itemID,
                        event.provenance?.kind != .automaticMerge
                    else { return false }
                    var covered = actual.contains(authored)
                    for head in actual where !covered {
                        try checkCatalogueScanProgress()
                        covered = try graphHasProperAncestor(
                            source: head, target: authored,
                            progress: { try self.checkCatalogueScanProgress() })
                    }
                    if !covered { return false }
                }
            }
            return true
        }
    }
    /// Conservative bounded historical policy lookup. It intentionally does not claim
    /// linear complexity: each distinct target may require its own exact sparse cut walk.
    func authorityItemFrontierAtCut(itemID: String, cut: AuthorityBinding) throws -> [String] {
        let token = "itemcut." + Identifier.make()
        defer {
            try? execute("DELETE FROM authority_control_work WHERE token=?", [token])
            try? authorityEndWalk(token: token)
        }
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try hasValidatedAuthorityControl(cut) else {
                throw controlInvalid("Unknown exact policy cut.")
            }
            try authorityBeginWalk(token: token)
            var after: String?
            while true {
                let page = try controlStringPage(
                    "SELECT id FROM authority_objects WHERE item=? AND kind='item'"
                        + (after == nil ? "" : " AND id>?") + " ORDER BY id LIMIT 128",
                    [itemID] + (after.map { [$0] } ?? []), limit: 128)
                if page.isEmpty { break }
                for id in page where try eligibilityAtCut(revisionID: id, cut: cut) == .eligible {
                    _ = try authorityVisitOnce(token: token, id: id)
                    try execute("INSERT INTO authority_control_work VALUES(?,?,0,0,1)", [token, id])
                }
                after = page.last
            }
            // Existing raw direct-parent edges, no alternative ancestry model. Walk each
            // eligible target's ancestors with shared visited state to mark dominated targets.
            var candidateCursor: String?
            while true {
                let candidate = try corpusPrepare(
                    "SELECT id FROM authority_control_work WHERE token=? AND covered=0"
                        + (candidateCursor == nil ? "" : " AND id>?") + " ORDER BY id LIMIT 1",
                    [token] + (candidateCursor.map { [$0] } ?? []))
                let status = catalogueStep(candidate)
                if status == SQLITE_DONE {
                    sqlite3_finalize(candidate)
                    break
                }
                guard status == SQLITE_ROW else {
                    sqlite3_finalize(candidate)
                    throw graphSQLiteError()
                }
                let id = try controlText(candidate, 0)
                sqlite3_finalize(candidate)
                candidateCursor = id
                let parents = try corpusPrepare(
                    "SELECT target FROM authority_dependencies WHERE source=? AND kind='parent'", [id])
                defer { sqlite3_finalize(parents) }
                while true {
                    let status = catalogueStep(parents)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { throw graphSQLiteError() }
                    try controlItemAncestorQueue(token: token, id: controlText(parents, 0), itemID: itemID)
                }
            }
            while let next = try controlNext(token) {
                try checkCatalogueScanProgress()
                let p = try corpusPrepare(
                    "SELECT target FROM authority_dependencies WHERE source=? AND kind='parent'", [next.0])
                defer { sqlite3_finalize(p) }
                while true {
                    let status = catalogueStep(p)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { throw graphSQLiteError() }
                    try controlItemAncestorQueue(token: token, id: controlText(p, 0), itemID: itemID)
                }
                try execute(
                    "UPDATE authority_control_work SET processed=1 WHERE token=? AND id=?", [token, next.0])
            }
            return try controlStringPage(
                "SELECT id FROM authority_control_work WHERE token=? AND covered=0 ORDER BY id LIMIT 2147483647",
                [token], limit: 1024, allowPrefix: false)
        }
    }
    private func controlItemAncestorQueue(token: String, id: String, itemID: String) throws {
        guard
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_objects WHERE id=? AND item=? AND kind='item')",
                [id, itemID]) == 1
        else { throw controlInvalid("Policy ancestry is missing or crosses items.") }
        if try authorityVisitOnce(token: token, id: id) {
            try execute("INSERT INTO authority_control_work VALUES(?,?,0,1,0)", [token, id])
        } else {
            try execute(
                "UPDATE authority_control_work SET covered=1,processed=0 WHERE token=? AND id=? AND covered=0",
                [token, id])
        }
    }
    func retainValidatedExposure(
        _ plan: AuthorityStore.VerifiedExposurePlan, revision original: AuthorityRevision? = nil,
        locallyVisible: Bool = false
    ) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try controlOriginal(plan.witness)
            guard try AuthorityStore.VerifiedExposurePlan(witness: plan.witness) == plan else {
                throw controlInvalid("Visibility plan does not match canonical bytes.")
            }
            try controlTarget(plan.target)
            guard try eligibilityAtCut(revisionID: plan.target.revisionID, cut: plan.cut) == .eligible else {
                throw controlInvalid("Visibility target was not eligible in its legitimate source cut.")
            }
            if let row = try revision(plan.target.revisionID) {
                guard row.itemID == plan.target.itemID, controlHex(row.digest) == plan.target.sha256,
                    row.modifiedAt == plan.modifiedAt
                else { throw controlInvalid("Visibility differs from accepted original clock/digest.") }
            } else {
                guard let original, original.revision.revisionID == plan.target.revisionID,
                    original.revision.itemID == plan.target.itemID, original.sha256 == plan.target.sha256,
                    original.revision.modifiedAt == plan.modifiedAt
                else {
                    throw controlInvalid("Historical visibility requires the exact original bytes and clock.")
                }
            }
            if let cause = plan.causeKey {
                guard
                    try controlNumber(
                        "SELECT EXISTS(SELECT 1 FROM authority_reconciliation_witness WHERE revision=? AND cause_key=?)",
                        [plan.target.revisionID, cause]) == 1
                else { throw controlInvalid("Visibility cause does not bind its reconciliation output.") }
            } else {
                guard
                    try controlNumber(
                        "SELECT EXISTS(SELECT 1 FROM authority_reconciliation_witness WHERE revision=?)",
                        [plan.target.revisionID]) == 0
                else { throw controlInvalid("Reconciliation visibility omitted its stable cause identity.") }
            }
            try controlCapacity(8192)
            let ticks = try RevisionTimestamp(plan.modifiedAt).ticks
            try execute(
                "INSERT OR IGNORE INTO authority_exposure VALUES(?,?,?,?,?,?,?,?,?,?)",
                [
                    plan.witness.record.recordID, plan.witness.sha256, plan.target.itemID,
                    plan.target.revisionID, plan.target.sha256, plan.cut.recordID, plan.cut.sha256,
                    plan.modifiedAt, String(ticks), plan.causeKey ?? "",
                ])
            // Main supplies this only after verifying its sealed private local journal,
            // retained ReplicaID and receipt. A source witness/origin claim alone cannot do so.
            if locallyVisible {
                try execute(
                    "INSERT OR IGNORE INTO authority_local_exposure VALUES(?,?,?,?)",
                    [plan.witness.record.recordID, plan.target.itemID, plan.target.revisionID, String(ticks)])
                try execute(
                    "INSERT OR IGNORE INTO authority_local_history VALUES(?,?,?,?,?,?)",
                    [
                        plan.target.revisionID, plan.target.itemID, plan.target.sha256, plan.modifiedAt,
                        String(ticks), (try revision(plan.target.revisionID)) == nil ? "1" : "0",
                    ])
                try execute(
                    "INSERT OR IGNORE INTO authority_retired_items SELECT ? WHERE NOT EXISTS(SELECT 1 FROM revision_catalog WHERE item=?)",
                    [plan.target.itemID, plan.target.itemID])
            }

        }
    }
    func authorityExposureFloor(itemID: String, excludingCauseKey: String? = nil) throws -> AuthorityStore
        .Exposure?
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT e.id,e.sha256,e.item,e.revision,e.digest,e.cut,e.cut_digest,e.modified,e.cause FROM authority_local_exposure l INDEXED BY authority_local_exposure_order CROSS JOIN authority_exposure e ON e.id=l.witness WHERE l.item=?"
                    + (excludingCauseKey == nil ? "" : " AND e.cause!=?")
                    + " ORDER BY l.ticks DESC,l.revision DESC,l.witness DESC LIMIT 1",
                [itemID] + (excludingCauseKey.map { [$0] } ?? []))
            defer { sqlite3_finalize(s) }
            let status = catalogueStep(s)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            var bytes = 0
            try controlBoundRow(s, bytes: &bytes, prefix: false)
            let cause = try controlText(s, 8)
            return try .init(
                witness: .init(recordID: controlText(s, 0), sha256: controlText(s, 1)),
                target: .init(
                    itemID: controlText(s, 2), revisionID: controlText(s, 3), sha256: controlText(s, 4)),
                cut: .init(recordID: controlText(s, 5), sha256: controlText(s, 6)),
                modifiedAt: controlText(s, 7), causeKey: cause.isEmpty ? nil : cause)
        }
    }
    func reserveReconciliation(_ plan: AuthorityStore.VerifiedReconciliationPlan) throws
        -> AuthorityStore.ReconciliationReservation
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let key = try registerAuthorityReconciliation(plan)
            if let old = try controlReservation(key) {
                guard
                    try controlNumber(
                        "SELECT EXISTS(SELECT 1 FROM authority_reconciliation WHERE key=? AND plan_digest=?)",
                        [key, plan.planDigest]) == 1
                else { throw controlInvalid("Equivalent reconciliation key proposed another payload.") }
                return old
            }
            try controlCapacity(UInt64(plan.witness.originalBytes.count) * 8 + 8192)
            try execute(
                "INSERT INTO authority_reconciliation VALUES(?,?,?,?,?,?,?,NULL,?,?,?)",
                [
                    key, plan.itemID, plan.outputRevisionID, plan.witness.record.recordID,
                    plan.witness.sha256, plan.planDigest, plan.modifiedAt,
                    String(decoding: try JSON.encode(plan.parents), as: UTF8.self),
                    String(decoding: try JSON.encode(plan.frontier), as: UTF8.self), plan.baseFloor,
                ])
            return .init(
                key: key, revisionID: plan.outputRevisionID,
                witness: try .init(recordID: plan.witness.record.recordID, sha256: plan.witness.sha256),
                outputDigest: nil)
        }
    }
    func retainValidatedReconciliation(_ plan: AuthorityStore.VerifiedReconciliationPlan) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try registerAuthorityReconciliation(plan)
        }
    }
    /// Recovery-only provisional binding; no active graph or current projection is
    /// asserted until complete graph admission and the disk reducer validate the output.
    func retainRecoveryReconciliation(
        _ plan: AuthorityStore.VerifiedReconciliationPlan, parents: [AuthorityRevision]
    ) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try registerAuthorityReconciliation(plan, recoveryParents: parents)
        }
    }
    private func registerAuthorityReconciliation(
        _ plan: AuthorityStore.VerifiedReconciliationPlan, recoveryParents: [AuthorityRevision]? = nil
    ) throws
        -> String
    {
        try controlOriginal(plan.witness)
        guard try AuthorityStore.VerifiedReconciliationPlan(witness: plan.witness) == plan,
            !plan.parents.isEmpty, !plan.frontier.isEmpty,
            try RevisionTimestamp(plan.modifiedAt) > RevisionTimestamp(plan.baseFloor)
        else {
            throw controlInvalid("Reconciliation lacks exact witness, accepted proof or advancing clock.")
        }
        if let recoveryParents {
            guard recoveryParents.map({ $0.revision.revisionID }).sorted() == plan.parents else {
                throw controlInvalid("Recovery witness omitted or repeated actual parents.")
            }
            var bytes: UInt64 = 0
            for parent in recoveryParents {
                try checkCatalogueScanProgress()
                let next = bytes.addingReportingOverflow(UInt64(parent.originalBytes.count))
                guard !next.overflow, next.partialValue <= graphMaximumTemporaryBytes else {
                    throw controlResource("Recovery parents exceed their aggregate byte allowance.")
                }
                bytes = next.partialValue
                guard parent.revision.itemID == plan.itemID,
                    let retained = try retainedAuthorityObject(id: parent.revision.revisionID),
                    retained.descriptor.kind == .item,
                    retained.descriptor.sha256 == parent.sha256,
                    retained.descriptor.length == parent.originalBytes.count,
                    try authorityDisposition(id: parent.revision.revisionID)?.disposition == .eligible,
                    try RevisionTimestamp(plan.modifiedAt) > RevisionTimestamp(parent.revision.modifiedAt)
                else {
                    throw controlInvalid(
                        "Recovery witness parent differs from exact eligible retained bytes or clock.")
                }
            }
        } else {
            guard try acceptedGraphProofIsCurrent() else {
                throw controlInvalid("Runtime reconciliation needs completed accepted graph admission.")
            }
            for parent in plan.parents {
                let accepted = try revision(parent)
                guard let row = accepted, row.itemID == plan.itemID,
                    try authorityDisposition(id: parent)?.disposition == .eligible,
                    try RevisionTimestamp(plan.modifiedAt) > RevisionTimestamp(row.modifiedAt)
                else {
                    let disposition =
                        (try? authorityDisposition(id: parent))?.disposition.rawValue ?? "unavailable"
                    throw controlInvalid(
                        "Reconciliation parent is not accepted eligible ancestry. "
                            + "[witness=\(plan.witness.record.recordID.prefix(64)) "
                            + "item=\(plan.itemID.prefix(64)) parent=\(parent.prefix(64)) "
                            + "accepted=\(accepted != nil) "
                            + "acceptedItem=\((accepted?.itemID ?? "missing").prefix(64)) "
                            + "disposition=\(disposition) "
                            + "outputAt=\(plan.modifiedAt.prefix(64)) "
                            + "parentAt=\((accepted?.modifiedAt ?? "missing").prefix(64))]")
                }
            }
        }
        for cause in plan.causes { try controlOriginalBinding(cause) }
        let causeKey = try authorityReconciliationCauseKey(
            itemID: plan.itemID, frontier: plan.frontier, causes: plan.causes)
        var hasExactFloor = false
        for exposure in plan.exposures {
            guard
                try controlNumber(
                    "SELECT EXISTS(SELECT 1 FROM authority_exposure WHERE id=? AND sha256=? AND item=? AND ticks<=? AND cause!=?)",
                    [
                        exposure.recordID, exposure.sha256, plan.itemID,
                        String(try RevisionTimestamp(plan.baseFloor).ticks), causeKey,
                    ]) == 1
            else { throw controlInvalid("Reconciliation exposure floor is unproven.") }
            hasExactFloor =
                try hasExactFloor
                || (controlNumber(
                    "SELECT EXISTS(SELECT 1 FROM authority_exposure WHERE id=? AND ticks=?)",
                    [exposure.recordID, String(try RevisionTimestamp(plan.baseFloor).ticks)]) == 1)
        }
        guard hasExactFloor else {
            throw controlInvalid("Reconciliation floor is not an actual legitimate exposure.")
        }
        let key = try AuthorityRecordCodec.sha256(
            JSON.encode(
                ItemValue.object([
                    "cause": .text(causeKey), "floor": .integer(RevisionTimestamp(plan.baseFloor).ticks),
                ])))
        try controlCapacity(UInt64(plan.witness.originalBytes.count) * 8 + 8192)
        try execute(
            "INSERT OR IGNORE INTO authority_reconciliation_witness VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            [
                plan.witness.record.recordID, plan.witness.sha256, plan.itemID, plan.outputRevisionID,
                plan.planDigest, plan.modifiedAt,
                String(decoding: try JSON.encode(plan.parents), as: UTF8.self),
                String(decoding: try JSON.encode(plan.frontier), as: UTF8.self), plan.baseFloor, causeKey,
                key, recoveryParents == nil ? "0" : "1",
            ])
        guard
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_reconciliation_witness WHERE witness=? AND witness_digest=? AND revision=? AND reservation_key=?)",
                [plan.witness.record.recordID, plan.witness.sha256, plan.outputRevisionID, key]) == 1
        else { throw controlInvalid("Reconciliation witness rebound its output.") }
        return key
    }
    func authorityReconciliationCauseKey(
        itemID: String, frontier: [String], causes: [AuthorityBinding]
    ) throws -> String {
        try AuthorityRecordCodec.sha256(
            JSON.encode(
                ItemValue.object([
                    "itemID": .text(itemID), "frontier": .list(frontier.sorted().map(ItemValue.text)),
                    "causes": .list(causes.sorted { $0.recordID < $1.recordID }.map(\.itemValue)),

                ])))
    }
    func authorityReconciliationPlanDigest(fields: [String: ItemValue]) throws -> String {
        try AuthorityRecordCodec.sha256(JSON.encode(ItemValue.object(fields)))
    }
    func validateAuthorityReconciliation(
        _ value: Revision, snapshot: RevisionProjection.Snapshot
    ) throws {
        guard snapshot.itemID == value.itemID, snapshot.analysis.isResolved,
            snapshot.analysis.frontier == (try value.provenance)?.frontier,
            RevisionMerge.semanticFields(value) == snapshot.analysis.fields
        else {
            throw controlInvalid("Reconciliation differs from the eligible authored projection.")
        }
        try completeAuthorityReconciliationProjection(value)
    }
    /// Disk projection separately recomputes actual context fields/frontier. This binds
    /// canonical metadata to the externally validated, durably reserved witness.
    func validateAuthorityReconciliationMetadata(
        _ value: Revision, allowUnprojectedRecoveryParents: Bool = false
    ) throws {
        guard let p = try value.provenance, p.kind == .automaticMerge,
            p.mergeProfile == AuthorityStore.reconciliationProfile,
            p.writtenFields.isEmpty, p.unsetFields.isEmpty, let witness = p.authorityWitness
        else {
            throw controlInvalid("Missing zero-write reconciliation witness.")
        }
        let s = try corpusPrepare(
            "SELECT w.revision,w.plan_digest,w.modified,w.parents,w.frontier,w.base_floor,o.origin,w.recovery FROM authority_reconciliation_witness w JOIN authority_objects o ON o.id=w.witness WHERE w.witness=? AND w.witness_digest=? AND w.item=?",
            [witness.recordID, witness.sha256, value.itemID])
        defer { sqlite3_finalize(s) }
        guard catalogueStep(s) == SQLITE_ROW else {
            throw controlInvalid("Reconciliation has no validated reservation.")
        }
        var bytes = 0
        try controlBoundRow(s, bytes: &bytes, prefix: false)
        let parents = try JSON.decode([String].self, Data(controlText(s, 3).utf8))
        let frontier = try JSON.decode([String].self, Data(controlText(s, 4).utf8))
        guard try controlText(s, 0) == value.revisionID,
            try controlText(s, 1)
                == authorityReconciliationPlanDigest(fields: RevisionMerge.semanticFields(value)),
            try controlText(s, 2) == value.modifiedAt, parents == p.parents, frontier == p.frontier,
            try controlText(s, 6) == p.originReplicaID,
            try RevisionTimestamp(value.modifiedAt) > RevisionTimestamp(controlText(s, 5))
        else {
            throw controlInvalid("Reconciliation bytes differ from the reserved projection/clock.")
        }
        for parent in p.parents {
            guard try authorityDisposition(id: parent)?.disposition == .eligible else {
                throw controlInvalid("Reconciliation contains withheld ancestry.")
            }
            if let row = try revision(parent) {
                guard row.itemID == value.itemID else {
                    throw controlInvalid("Reconciliation ancestry crosses items.")
                }
            } else {
                guard allowUnprojectedRecoveryParents, sqlite3_column_int(s, 7) == 1,
                    try controlNumber(
                        "SELECT EXISTS(SELECT 1 FROM authority_objects WHERE id=? AND item=? AND kind='item')",
                        [parent, value.itemID]) == 1
                else {
                    throw controlInvalid(
                        "Reconciliation ancestry is not admitted or provisionally byte-bound for recovery.")
                }
            }
        }

    }
    func completeAuthorityReconciliationProjection(_ value: Revision) throws {
        try validateAuthorityReconciliationMetadata(value)
        let witness = try value.provenance!.authorityWitness!
        try execute(
            "UPDATE authority_reconciliation_witness SET recovery=0 WHERE witness=? AND witness_digest=?",
            [witness.recordID, witness.sha256])
    }
    func authorityRecoveryProjectionIsComplete() throws -> Bool {
        guard try authorityReviewRecoveryIsComplete() else { return false }
        guard
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='authority_reconciliation_witness')"
            ) == 1
        else { return true }
        return try controlNumber(
            "SELECT EXISTS(SELECT 1 FROM authority_reconciliation_witness w JOIN revision_catalog r ON r.revision=w.revision WHERE w.recovery=1 LIMIT 1)"
        ) == 0
    }
    func validatePeerMaterialization(
        row: CatalogueRow, revision: AuthorityRevision,
        loadVerified: @escaping (CatalogueRow) throws -> PooledCanonicalRecord,
        limits: RevisionProjection.Limits = .init(), progress: (() throws -> Void)? = nil
    ) throws {
        _ = try authorityPeerMaterialization(
            row: row, original: revision, loadVerified: loadVerified, limits: limits, progress: progress,
            preview: true)
    }
    func appendValidatedPeerMaterialization(
        row: CatalogueRow, revision: AuthorityRevision,
        loadVerified: @escaping (CatalogueRow) throws -> PooledCanonicalRecord,
        limits: RevisionProjection.Limits = .init(), progress: (() throws -> Void)? = nil
    ) throws -> RevisionProjection.Snapshot {
        try authorityPeerMaterialization(
            row: row, original: revision, loadVerified: loadVerified, limits: limits, progress: progress,
            preview: false)
    }
    private func authorityPeerMaterialization(
        row: CatalogueRow, original: AuthorityRevision,
        loadVerified: @escaping (CatalogueRow) throws -> PooledCanonicalRecord,
        limits: RevisionProjection.Limits, progress: (() throws -> Void)?, preview: Bool
    ) throws -> RevisionProjection.Snapshot {
        guard !projectionAppendActive, !revisionProjectionActive else {
            throw controlInvalid("Another operation owns peer graph admission.")
        }
        let saved = captureAuthorityPeerGraphState()
        let oldVM = graphMaximumVMInstructions
        let oldBytes = graphMaximumTemporaryBytes
        let oldReserve = graphReserveBytes
        graphMaximumVMInstructions = min(oldVM, limits.maximumVMInstructions)
        graphMaximumTemporaryBytes = min(oldBytes, limits.maximumStagingBytes)
        graphReserveBytes = max(oldReserve, limits.minimumFreeBytes)
        projectionAppendActive = true
        defer {
            projectionAppendActive = false
            graphMaximumVMInstructions = oldVM
            graphMaximumTemporaryBytes = oldBytes
            graphReserveBytes = oldReserve
        }
        try execute("SAVEPOINT authority_peer_materialization")
        do {
            let result = try withCatalogueScanBudget(progress: progress, reusingActiveBudget: true) {
                try withAuthorityPeerWorkAllowance(maximum: limits.maximumVMInstructions) {
                    guard try acceptedGraphProofIsCurrent() else {
                        throw controlInvalid("Peer materialization requires existing accepted proof.")
                    }
                    let value = original.revision
                    try value.validate()
                    try ItemSemantics.validate(value)
                    guard let p = try value.provenance, p.kind == .automaticMerge,
                        [RevisionMerge.profile, AuthorityStore.reconciliationProfile].contains(
                            p.mergeProfile ?? ""),
                        p.writtenFields.isEmpty, p.unsetFields.isEmpty,
                        row.revisionID == value.revisionID, row.itemID == value.itemID,
                        row.modifiedAt == value.modifiedAt,
                        row.parentID == value.supersedes, row.provenance == p,
                        row.createdAt == value.fields["createdAt"]?.dateString,
                        row.actor == value.fields["actor"]?.string,
                        row.operationID == value.fields["operationID"]?.string,
                        controlHex(row.digest) == original.sha256,
                        row.size == UInt64(original.originalBytes.count),
                        let retained = try retainedAuthorityObject(id: row.revisionID),
                        retained.path == row.path,
                        retained.descriptor.sha256 == original.sha256,
                        retained.descriptor.length == original.originalBytes.count,
                        retained.descriptor.kind == .item
                    else {
                        throw controlInvalid(
                            "Peer materialization does not bind one exact retained original.")
                    }
                    if !preview {
                        guard try authorityDisposition(id: row.revisionID)?.disposition == .eligible else {
                            throw controlInvalid("Peer materialization is not currently eligible.")
                        }
                    }
                    if p.mergeProfile == AuthorityStore.reconciliationProfile {
                        try validateAuthorityReconciliationMetadata(value)
                    }
                    let feedback =
                        (value.fields["learningFeedback"]?.map?.values.compactMap {
                            $0.map?["revisionID"]?.string
                        } ?? []).sorted()
                    guard feedback == row.feedbackRevisionIDs.sorted() else {
                        throw controlInvalid("Peer materialization omitted original feedback references.")
                    }
                    for parent in p.parents {
                        guard let input = try self.revision(parent), input.itemID == row.itemID,
                            input.createdAt == row.createdAt,
                            try authorityDisposition(id: parent)?.disposition == .eligible,
                            try RevisionTimestamp(value.modifiedAt) > RevisionTimestamp(input.modifiedAt)
                        else { throw controlInvalid("Peer materialization parent or timestamp is invalid.") }
                    }
                    if let existing = try self.revision(row.revisionID) {
                        guard existing == row else {
                            throw controlInvalid("Peer materialization ID collided with accepted bytes.")
                        }
                    } else {
                        try insertRecoveryRow(row, graphFields: value.fields)
                        _ = try appendAcceptedGraphBookkeeping(
                            row: row, parents: p.parents, feedback: feedback)
                        try execute("UPDATE current_projection SET dirty=1 WHERE item=?", [row.itemID])
                        try advanceAcceptedGraphProof()
                    }
                    // The reducer validates EVERY node in its own parent context. Its
                    // returned current representative may be a later dominating authored E.
                    return try analyzeRevisionProjection(
                        itemID: row.itemID, loadVerified: loadVerified, limits: limits, progress: progress,
                        reusingActiveBudget: true)
                }
            }
            if preview {
                try rollbackAuthorityPeerMaterialization()
                restoreAuthorityPeerGraphState(saved)
            } else {
                try execute("RELEASE authority_peer_materialization")
            }
            return result
        } catch {
            do {
                try rollbackAuthorityPeerMaterialization()
                restoreAuthorityPeerGraphState(saved)
            } catch {
                invalidateRevisionGraphValidation()
                throw error
            }
            throw error
        }
    }
    /// A validated authority transition has already installed a serving barrier. Remove
    /// only this item's ineligible active rows; retained originals/exposures never change.
    func reconcileAuthorityAcceptedItem(itemID: String) throws {
        guard !projectionAppendActive else { throw controlInvalid("Another append owns the accepted proof.") }
        projectionAppendActive = true
        defer { projectionAppendActive = false }
        try execute("SAVEPOINT authority_item_reconcile")
        do {
            try withCatalogueScanBudget(reusingActiveBudget: true) {
                guard try acceptedGraphProofIsCurrent() else {
                    throw controlInvalid("Scoped demotion requires the completed accepted proof.")
                }
                // A retained eligible child may not silently inherit a held ancestor.
                guard
                    try controlNumber(
                        "SELECT EXISTS(SELECT 1 FROM revision_catalog r JOIN authority_dispositions d ON d.object=r.revision AND d.state='eligible' JOIN revision_parents p ON p.child=r.revision LEFT JOIN authority_dispositions a ON a.object=p.parent WHERE r.item=? AND (a.object IS NULL OR a.state!='eligible') LIMIT 1)",
                        [itemID]) == 0
                else {
                    throw controlInvalid("Demotion did not hold every affected descendant.")
                }
                var after: String?
                while true {
                    let ids = try controlStringPage(
                        "SELECT r.revision FROM revision_catalog r LEFT JOIN authority_dispositions d ON d.object=r.revision WHERE r.item=? AND (d.object IS NULL OR d.state!='eligible')"
                            + (after == nil ? "" : " AND r.revision>?") + " ORDER BY r.revision LIMIT 128",
                        [itemID] + (after.map { [$0] } ?? []), limit: 128)
                    if ids.isEmpty { break }
                    for id in ids {
                        try checkCatalogueScanProgress()
                        // Feedback is proper ancestry, so parent-closure implies feedback closure.
                        for (table, field) in [
                            ("revision_parents", "child"), ("revision_field_values", "revision"),
                            ("revision_field_writes", "revision"), ("revision_frontier", "revision"),
                            ("scoped_operation_receipts", "revision"), ("operation_receipts", "revision"),
                            ("feedback_refs", "revision"), ("recovery_ordinals", "revision"),
                            ("recovery_graph_work", "revision"),
                        ] {
                            try execute("DELETE FROM \(table) WHERE \(field)=?", [id])
                        }
                        try execute("UPDATE authority_local_history SET retired=1 WHERE revision=?", [id])
                        try execute("DELETE FROM revision_catalog WHERE revision=?", [id])
                    }
                    after = ids.last
                }
                for table in ["recovery_roots", "recovery_heads", "recovery_forks", "recovery_item_progress"]
                { try execute("DELETE FROM \(table) WHERE item=?", [itemID]) }
                try execute(
                    "INSERT INTO recovery_roots SELECT r.item,r.revision,r.created_at FROM revision_catalog r WHERE r.item=? AND NOT EXISTS(SELECT 1 FROM revision_parents p WHERE p.child=r.revision)",
                    [itemID])
                try execute(
                    "INSERT INTO recovery_item_progress SELECT item,MAX(ordinal) FROM recovery_ordinals WHERE item=? GROUP BY item",
                    [itemID])
                try execute(
                    "INSERT OR IGNORE INTO recovery_forks SELECT ? WHERE EXISTS(SELECT 1 FROM revision_catalog r JOIN revision_parents p ON p.child=r.revision WHERE r.item=? GROUP BY p.child HAVING COUNT(*)>1) OR EXISTS(SELECT 1 FROM revision_parents p JOIN revision_catalog r ON r.revision=p.child WHERE r.item=? GROUP BY p.parent HAVING COUNT(*)>1)",
                    [itemID, itemID, itemID])
                try execute(
                    "INSERT INTO recovery_heads SELECT item,revision FROM revision_catalog r WHERE item=? AND NOT EXISTS(SELECT 1 FROM revision_parents p WHERE p.parent=r.revision) AND NOT EXISTS(SELECT 1 FROM recovery_forks f WHERE f.item=r.item)",
                    [itemID])
                try removeCurrentContentProjection(itemID: itemID)
                try execute("UPDATE current_projection SET dirty=1 WHERE item=?", [itemID])
                try execute(
                    "INSERT OR IGNORE INTO authority_retired_items SELECT ? WHERE NOT EXISTS(SELECT 1 FROM revision_catalog WHERE item=?) AND EXISTS(SELECT 1 FROM authority_local_history v WHERE v.item=? AND "
                        + authorityLocalHistoryProof + ")",
                    [itemID, itemID, itemID])
                try advanceAcceptedGraphProof()
            }
            try execute("RELEASE authority_item_reconcile")
        } catch {
            try? execute("ROLLBACK TO authority_item_reconcile")
            try? execute("RELEASE authority_item_reconcile")
            invalidateRevisionGraphValidation()
            throw error
        }
    }
    /// Checkpoint-only exception for local, previously visible history with no
    /// remaining eligible root. It confers no nonadministrator disclosure authority.
    func authorityAllowsHistoryOnlyBarrier(_ current: CurrentProjection) throws -> Bool {
        let state = current.state
        guard state.status == .reviewRequired, state.representativeRevisionID == nil,
            state.frontier?.isEmpty ?? true, !current.policiesComplete,
            current.representativeDigest == nil, current.clockFloor == nil,
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='authority_local_exposure')"
            ) == 1
        else { return false }
        for (table, column) in [
            ("revision_catalog", "item"), ("items", "id"), ("current_policy", "item"),
            ("projection_acl", "item"), ("projection_acl_named", "item"),
        ] {
            guard
                try controlNumber(
                    "SELECT EXISTS(SELECT 1 FROM \(table) WHERE \(column)=? LIMIT 1)", [state.itemID]) == 0
            else { return false }
        }
        return try controlNumber(
            "SELECT EXISTS(SELECT 1 FROM authority_local_history v WHERE v.item=? AND v.retired=1 AND "
                + authorityLocalHistoryProof + " LIMIT 1)", [state.itemID]) == 1

    }
    /// Retained local historical membership, including accepted branches never READY.
    /// Use authorityLocallyExposed for the separate clock/visibility fact.
    func authorityHasLocalHistoryAdmission(revisionID: String) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_local_history v WHERE v.revision=? AND "
                    + authorityLocalHistoryProof + ")", [revisionID]) == 1
        }
    }
    func authorityLocallyExposed(revisionID: String) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_local_exposure l JOIN authority_exposure e ON e.id=l.witness AND e.revision=l.revision AND e.item=l.item AND e.ticks=l.ticks WHERE l.revision=? LIMIT 1)",
                [revisionID]) == 1
        }
    }
    func authorityHistoricalPage(itemID: String, afterRevisionID: String? = nil, limit: Int = 128) throws
        -> [AuthorityStore.RetainedObject]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit) else { throw controlInvalid("Invalid physical history page.") }
            var cursor: [String] = []
            if let afterRevisionID {
                let s = try corpusPrepare(
                    "SELECT modified_ticks FROM revision_catalog WHERE item=? AND revision=? UNION SELECT ticks FROM authority_local_history WHERE item=? AND revision=? LIMIT 1",
                    [itemID, afterRevisionID, itemID, afterRevisionID])
                defer { sqlite3_finalize(s) }
                guard catalogueStep(s) == SQLITE_ROW else {
                    throw controlInvalid("Unknown physical history cursor.")
                }
                let at = String(sqlite3_column_int64(s, 0))
                cursor = [at, at, afterRevisionID]
            }
            let predicate = afterRevisionID == nil ? "" : " AND (ticks<? OR (ticks=? AND revision<?))"
            let acceptedPredicate =
                afterRevisionID == nil ? "" : " AND (modified_ticks<? OR (modified_ticks=? AND revision<?))"
            let relation =
                "SELECT revision,ticks FROM (SELECT revision,modified_ticks AS ticks FROM revision_catalog WHERE item=?"
                + acceptedPredicate
                + " ORDER BY modified_ticks DESC,revision DESC LIMIT ?) UNION ALL SELECT revision,ticks FROM (SELECT revision,ticks FROM authority_local_history v WHERE item=? AND retired=1 AND "
                + authorityLocalHistoryProof
                + predicate + " ORDER BY ticks DESC,revision DESC LIMIT ?)"
            return try authorityRows(
                "SELECT o.id,o.kind,o.length,o.sha256,o.path,p.package,p.peer,p.configuration,p.permitted FROM ("
                    + relation
                    + ") h JOIN authority_objects o ON o.id=h.revision JOIN authority_packages p ON p.object=o.id AND p.package=(SELECT q.package FROM authority_packages q INDEXED BY authority_packages_object WHERE q.object=o.id ORDER BY q.permitted DESC,q.package LIMIT 1) ORDER BY h.ticks DESC,h.revision DESC LIMIT ?",
                [itemID] + cursor + [String(limit), itemID] + cursor + [String(limit), String(limit)])

        }
    }
    func authorityControlHeadPage(afterOriginID: String? = nil, limit: Int = 128) throws -> [AuthorityBinding]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit) else { throw controlInvalid("Invalid control head page.") }
            let s = try corpusPrepare(
                "SELECT id,sha256 FROM authority_control_heads"
                    + (afterOriginID == nil ? "" : " WHERE origin>?") + " ORDER BY origin LIMIT ?",
                (afterOriginID.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var rows: [AuthorityBinding] = []
            var bytes = 0
            while true {
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return rows }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                if try !controlBoundRow(s, bytes: &bytes, prefix: !rows.isEmpty) { return rows }
                rows.append(try .init(recordID: controlText(s, 0), sha256: controlText(s, 1)))
            }
        }
    }
    func authorityReadyControlPage(packageID: String? = nil, after: String? = nil, limit: Int = 128) throws
        -> [AuthorityStore.RetainedObject]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit) else { throw controlInvalid("Invalid ready-control page.") }
            let index =
                packageID == nil ? "authority_control_pending_ready" : "authority_control_pending_package"
            let selected =
                packageID == nil
                ? " AND ready.package=(SELECT q.package FROM authority_control_pending q INDEXED BY authority_control_pending_object JOIN authority_packages receipt ON receipt.package=q.package AND receipt.object=q.id AND receipt.permitted=1 WHERE q.id=ready.id AND q.missing=0 ORDER BY q.package LIMIT 1)"
                : " AND ready.package=?"
            return try authorityRows(
                "SELECT o.id,o.kind,o.length,o.sha256,o.path,p.package,p.peer,p.configuration,p.permitted FROM authority_control_pending ready INDEXED BY "
                    + index
                    + " CROSS JOIN authority_objects o ON o.id=ready.id CROSS JOIN authority_packages p ON p.object=ready.id AND p.package=ready.package AND p.permitted=1 WHERE ready.missing=0"
                    + selected + (after == nil ? "" : " AND ready.id>?") + " ORDER BY ready.id LIMIT ?",
                (packageID.map { [$0] } ?? []) + (after.map { [$0] } ?? []) + [String(limit)])
        }
    }
    func authorityLocallyAccepted(revisionID: String, originID: String) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_control_delta d INDEXED BY authority_control_target JOIN authority_control c ON c.id=d.control WHERE d.target=? AND d.eligible=1 AND c.origin=? LIMIT 1) OR EXISTS(SELECT 1 FROM authority_dependencies d JOIN authority_control c ON c.bootstrap=d.target AND c.bootstrap_digest=d.sha256 WHERE d.source=? AND d.kind='bootstrap' AND c.origin=? LIMIT 1)",
                [revisionID, originID, revisionID, originID]) == 1
        }
    }
    func authorityExposure(revisionID: String) throws -> AuthorityStore.Exposure? {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT id,sha256,item,revision,digest,cut,cut_digest,modified,cause FROM authority_exposure WHERE revision=? ORDER BY id DESC LIMIT 1",
                [revisionID])
            defer { sqlite3_finalize(s) }
            let status = catalogueStep(s)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            var bytes = 0
            try controlBoundRow(s, bytes: &bytes, prefix: false)
            let cause = try controlText(s, 8)
            return try .init(
                witness: .init(recordID: controlText(s, 0), sha256: controlText(s, 1)),
                target: .init(
                    itemID: controlText(s, 2), revisionID: controlText(s, 3), sha256: controlText(s, 4)),
                cut: .init(recordID: controlText(s, 5), sha256: controlText(s, 6)),
                modifiedAt: controlText(s, 7), causeKey: cause.isEmpty ? nil : cause)
        }
    }
    func authorityAcceptanceControl(revisionID: String) throws -> AuthorityBinding? {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT c.id,c.sha256 FROM authority_control_delta d INDEXED BY authority_control_target CROSS JOIN authority_control c ON c.id=d.control WHERE d.target=? AND d.eligible=1 ORDER BY d.control LIMIT 1",
                [revisionID])
            defer { sqlite3_finalize(s) }
            let status = catalogueStep(s)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            return try .init(recordID: controlText(s, 0), sha256: controlText(s, 1))
        }
    }
    func completeReconciliation(
        _ reservation: AuthorityStore.ReconciliationReservation, revision original: AuthorityRevision
    ) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try validateAuthorityReconciliationMetadata(original.revision)
            guard let stored = try controlReservation(reservation.key),
                stored.revisionID == reservation.revisionID, stored.witness == reservation.witness,
                original.revision.revisionID == stored.revisionID,
                let row = try revision(stored.revisionID), controlHex(row.digest) == original.sha256,
                row.itemID == original.revision.itemID,
                stored.outputDigest == nil || stored.outputDigest == original.sha256
            else { throw controlInvalid("Reserved reconciliation output identity or digest changed.") }
            try execute(
                "UPDATE authority_reconciliation SET output_digest=? WHERE key=?",
                [original.sha256, reservation.key])
        }
    }
    private func controlReservation(_ key: String) throws -> AuthorityStore.ReconciliationReservation? {
        let s = try corpusPrepare(
            "SELECT revision,witness,witness_digest,output_digest FROM authority_reconciliation WHERE key=?",
            [key])
        defer { sqlite3_finalize(s) }
        let status = catalogueStep(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw graphSQLiteError() }
        return try .init(
            key: key, revisionID: controlText(s, 0),
            witness: .init(recordID: controlText(s, 1), sha256: controlText(s, 2)),
            outputDigest: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : controlText(s, 3))
    }
    private func controlOriginal(_ control: AuthorityRecordCodec.Verified) throws {
        guard let row = try retainedAuthorityObject(id: control.record.recordID),
            row.descriptor.kind == .authority, row.descriptor.sha256 == control.sha256,
            row.descriptor.length == control.originalBytes.count
        else { throw controlInvalid("Control is not an exact sealed retained original.") }
    }
    private func controlOriginalBinding(_ binding: AuthorityBinding, kind: String? = nil) throws {
        guard
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_objects WHERE id=? AND sha256=? AND kind='authority'"
                    + (kind == nil ? "" : " AND control_kind=?") + ")",
                [binding.recordID, binding.sha256] + (kind.map { [$0] } ?? [])) == 1
        else { throw controlInvalid("Control dependency digest/kind is absent.") }
    }
    private func controlTarget(_ target: AuthorityStore.Target) throws {
        guard let row = try retainedAuthorityObject(id: target.revisionID), row.descriptor.kind == .item,
            row.descriptor.sha256 == target.sha256,
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_objects WHERE id=? AND item=?)",
                [target.revisionID, target.itemID]) == 1
        else { throw controlInvalid("Control target differs from retained original bytes.") }
    }
    private func controlDelta(_ control: String, _ revision: String, _ digest: String) throws -> Bool? {
        let s = try corpusPrepare(
            "SELECT sha256,eligible FROM authority_control_delta WHERE control=? AND target=?",
            [control, revision])
        defer { sqlite3_finalize(s) }
        let status = catalogueStep(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, try controlText(s, 0) == digest else {
            throw controlInvalid("Historical disposition rebound its target digest.")
        }
        return sqlite3_column_int(s, 1) != 0
    }
    private func controlQueue(token: String, id: String, covered: Bool) throws {
        if try authorityVisitOnce(token: token, id: id) {
            try execute(
                "INSERT INTO authority_control_work SELECT ?,id,ordinal,?,0 FROM authority_control WHERE id=?",
                [token, covered ? "1" : "0", id])
        } else if covered {
            try execute("UPDATE authority_control_work SET covered=1 WHERE token=? AND id=?", [token, id])
        }
    }
    private func controlNext(_ token: String) throws -> (String, Bool)? {
        let s = try corpusPrepare(
            "SELECT id,covered FROM authority_control_work WHERE token=? AND processed=0 ORDER BY ordinal DESC,id LIMIT 1",
            [token])
        defer { sqlite3_finalize(s) }
        let status = catalogueStep(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw graphSQLiteError() }
        return try (controlText(s, 0), sqlite3_column_int(s, 1) != 0)
    }
    private func controlStringPage(_ sql: String, _ bindings: [String], limit: Int, allowPrefix: Bool = true)
        throws -> [String]
    {
        guard (1...1024).contains(limit) else { throw controlInvalid("Invalid control page limit.") }
        let s = try corpusPrepare(sql, bindings)
        defer { sqlite3_finalize(s) }
        var values: [String] = []
        var bytes = 0
        while true {
            try checkCatalogueScanProgress()
            let status = catalogueStep(s)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            if try !controlBoundRow(s, bytes: &bytes, prefix: allowPrefix && !values.isEmpty) {
                return values
            }
            values.append(try controlText(s, 0))
        }
    }
    @discardableResult
    private func controlBoundRow(_ s: OpaquePointer, bytes: inout Int, prefix: Bool) throws -> Bool {
        var size = 128
        for c in 0..<sqlite3_column_count(s) {
            let n = Int(sqlite3_column_bytes(s, c))
            guard n <= AuthorityRecord.maximumBytes - min(size, AuthorityRecord.maximumBytes) else {
                throw controlResource("Control metadata row exceeds its window.")
            }
            size += n
        }
        guard size <= graphMaximumPageBytes - min(bytes, graphMaximumPageBytes) else {
            if prefix { return false }
            throw controlResource("Control metadata page cannot fit one row.")
        }
        bytes += size
        return true
    }
    private func controlText(_ s: OpaquePointer, _ c: Int32) throws -> String {
        guard sqlite3_column_bytes(s, c) <= AuthorityRecord.maximumBytes, let p = sqlite3_column_text(s, c)
        else { throw controlInvalid("Malformed control metadata text.") }
        return String(cString: p)
    }
    private func controlNumber(_ sql: String, _ args: [String] = []) throws -> Int64 {
        let s = try corpusPrepare(sql, args)
        defer { sqlite3_finalize(s) }
        guard catalogueStep(s) == SQLITE_ROW else { throw graphSQLiteError() }
        return sqlite3_column_int64(s, 0)
    }
    private func controlCapacity(_ bytes: UInt64) throws {
        try checkCatalogueScanProgress()
        guard bytes <= graphMaximumTemporaryBytes else {
            throw controlResource("Control staging exceeds its byte allowance.")
        }
        try requireGraphCapacity(additionalBytes: bytes)
    }
    private func controlHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private func controlInvalid(_ message: String) -> TractandaError { .init("invalidAuthority", message) }
    private func controlResource(_ message: String) -> TractandaError { .init("resourceLimit", message) }
    /// Store's exact sealed local/foreign review application is a LOCAL admission fact.
    /// A raw observed decision or provisional application never supplies the proof predicate above.
    func retainAppliedReviewHistory(_ plan: AuthorityStore.VerifiedReviewPlan) throws {
        guard
            try controlNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_review_applied WHERE decision=? AND sha256=? AND control=? AND control_digest=? AND revision=? AND digest=?)",
                [
                    plan.event.binding.recordID, plan.event.binding.sha256, plan.control.binding.recordID,
                    plan.control.binding.sha256, plan.event.resolution.revisionID,
                    plan.event.resolution.sha256,
                ]) == 1
        else {
            throw controlInvalid("Reviewed history lacks its exact private application.")
        }
        try retainLocalHistoryTarget(plan.event.target)
        try retainLocalHistoryTarget(plan.event.resolution)
        try enqueueLocalAuthorityVisibility(
            itemID: plan.event.target.itemID, cause: plan.control.binding, kind: "review")
    }
    func locallyAppliedReviewControl(revisionID: String, digest: String) throws -> AuthorityBinding? {
        let statement = try corpusPrepare(
            "SELECT a.control,a.control_digest FROM authority_review_applied a JOIN authority_review_event e ON e.id=a.decision AND e.sha256=a.sha256 JOIN authority_control c ON c.id=a.control AND c.sha256=a.control_digest WHERE a.recovery=0 AND ((a.revision=? AND a.digest=?) OR (e.target=? AND e.target_digest=?)) ORDER BY a.decision LIMIT 1",
            [revisionID, digest, revisionID, digest])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw graphSQLiteError() }
        return try .init(recordID: controlText(statement, 0), sha256: controlText(statement, 1))
    }

}
