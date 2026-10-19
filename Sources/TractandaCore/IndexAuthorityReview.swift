import CSQLite
import Foundation

extension ItemIndex {

    /// Derived facts only. The owning Store serializes, authenticates and seals the
    /// complete review unit; none of these methods commits its transaction.
    func initializeAuthorityReviewSchema() throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try reviewCapacity(32 * 1024)
            for sql in [
                "CREATE TABLE IF NOT EXISTS authority_review_event(id TEXT PRIMARY KEY,sha256 TEXT NOT NULL,item TEXT NOT NULL,target TEXT NOT NULL,target_digest TEXT NOT NULL,evidence TEXT NOT NULL,evidence_digest TEXT NOT NULL,kind TEXT NOT NULL,resolution TEXT NOT NULL,resolution_digest TEXT NOT NULL,cut TEXT NOT NULL,cut_digest TEXT NOT NULL)",
                "CREATE INDEX IF NOT EXISTS authority_review_target ON authority_review_event(target,id)",
                "CREATE INDEX IF NOT EXISTS authority_review_item ON authority_review_event(item,id)",
                "CREATE TABLE IF NOT EXISTS authority_review_edge(child TEXT NOT NULL,parent TEXT NOT NULL,sha256 TEXT NOT NULL,PRIMARY KEY(child,parent))",
                "CREATE INDEX IF NOT EXISTS authority_review_children ON authority_review_edge(parent,child)",
                "CREATE TABLE IF NOT EXISTS authority_review_head(target TEXT NOT NULL,id TEXT NOT NULL,PRIMARY KEY(target,id))",
                "CREATE TABLE IF NOT EXISTS authority_review_applied(decision TEXT PRIMARY KEY,sha256 TEXT NOT NULL,revision TEXT NOT NULL,digest TEXT NOT NULL,control TEXT NOT NULL,control_digest TEXT NOT NULL,origin TEXT NOT NULL,actor TEXT NOT NULL,operation TEXT NOT NULL,request TEXT NOT NULL,recovery INTEGER NOT NULL,UNIQUE(origin,actor,operation))",
                "CREATE INDEX IF NOT EXISTS authority_review_resolution ON authority_review_applied(revision,recovery,decision)",
            ] { try execute(sql) }
        }
    }
    func clearAuthorityReviewDerivedState() throws {
        let s = try corpusPrepare(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='authority_review_event'")
        let status = catalogueStep(s)
        sqlite3_finalize(s)
        if status == SQLITE_DONE { return }
        guard status == SQLITE_ROW else { throw graphSQLiteError() }
        for table in [
            "authority_review_applied", "authority_review_head", "authority_review_edge",
            "authority_review_event",
        ] {
            try execute("DELETE FROM \(table)")
        }
    }
    /// Complete current decision/hold frontier, never a silently truncated page.
    func authorityReviewFrontier(revisionID: String) throws -> [AuthorityBinding] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT e.id,e.sha256 FROM authority_review_head h JOIN authority_review_event e ON e.id=h.id WHERE h.target=? ORDER BY e.id",
                [revisionID])
            defer { sqlite3_finalize(s) }
            var result: [AuthorityBinding] = []
            var bytes = 0
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                try reviewBoundRow(s, bytes: &bytes)
                guard result.count < 256 else {
                    throw reviewResource("Review frontier exceeds its complete proof window.")
                }
                result.append(try .init(recordID: reviewText(s, 0), sha256: reviewText(s, 1)))
            }
        }
    }
    func authorityReviewDisposition(revisionID: String) throws -> AuthorityStore.ReviewDisposition {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let heads = try authorityReviewFrontier(revisionID: revisionID)
            if heads.isEmpty { return .unknown }
            var resolution: AuthorityBinding?
            for head in heads {
                guard try peerAuthorityIssuerPermits(head.recordID) else { continue }
                let s = try corpusPrepare(
                    "SELECT e.kind,e.resolution,e.resolution_digest,a.decision FROM authority_review_event e LEFT JOIN authority_review_applied a ON a.decision=e.id AND a.sha256=e.sha256 AND a.recovery=0 WHERE e.id=? AND e.sha256=?",
                    [head.recordID, head.sha256])
                defer { sqlite3_finalize(s) }
                guard catalogueStep(s) == SQLITE_ROW else {
                    throw reviewInvalid("Review frontier is incomplete.")
                }
                guard try reviewText(s, 0) == "reviewDecision", sqlite3_column_type(s, 3) != SQLITE_NULL
                else { return .held }
                let current = try AuthorityBinding(recordID: reviewText(s, 1), sha256: reviewText(s, 2))
                if let resolution, resolution != current { return .conflicted }
                resolution = current
            }
            return resolution == nil ? .held : .approved
        }
    }

    /// Store has verified administrator authority and exact observed dependencies.
    /// Registration alone never makes a decision an applied acceptance.
    func retainValidatedReviewHold(_ original: AuthorityRecordCodec.Verified) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard original.record.kind == .reviewHold else { throw reviewInvalid("Expected a review hold.") }
            try reviewRetained(original)
            let target = try AuthorityStore.Target(value: original.record.payload["target"]!)
            let evidence = try AuthorityBinding(value: original.record.payload["evidence"]!)
            let ids = try AuthorityRecord.ids(original.record.payload["decisionFrontier"])
            var parents: [AuthorityBinding] = []
            for id in ids {
                let p = try corpusPrepare(
                    "SELECT sha256 FROM authority_review_event WHERE id=? AND target=?",
                    [id, target.revisionID])
                defer { sqlite3_finalize(p) }
                guard catalogueStep(p) == SQLITE_ROW else {
                    throw reviewInvalid("Hold lacks its validated reviewed context.")
                }
                parents.append(try .init(recordID: id, sha256: reviewText(p, 0)))
            }
            try reviewInsertEvent(
                original, target: target, evidence: evidence, parents: parents, preCut: nil, resolution: nil)
        }
    }
    func retainValidatedReviewEvent(_ event: AuthorityStore.VerifiedReviewEvent) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try reviewRetained(event.record)
            try reviewCheckEvent(event)
            try reviewInsertEvent(
                event.record, target: event.target, evidence: event.evidence, parents: event.parents,
                preCut: event.preCut, resolution: event.resolution)
        }
    }
    private func reviewCheckEvent(_ event: AuthorityStore.VerifiedReviewEvent) throws {
        let record = event.record.record
        let cuts = try AuthorityRecord.list(record.payload["sourceControl"])
        let resolutions = try AuthorityRecord.list(record.payload["resolution"])
        guard cuts.count == 1, resolutions.count == 1, record.kind == .reviewDecision,
            record.payload["decision"]?.string == "accept",
            try AuthorityRecordCodec.decode(event.record.originalBytes) == event.record,
            try AuthorityStore.Target(value: record.payload["target"]!) == event.target,
            try AuthorityBinding(value: record.payload["evidence"]!) == event.evidence,
            try AuthorityRecord.ids(record.payload["decisionFrontier"]) == event.parents.map(\.recordID),
            try AuthorityBinding(value: cuts[0]) == event.preCut,
            try AuthorityStore.Target(value: resolutions[0]) == event.resolution,
            try AuthorityRecord.list(record.payload["controlHolds"]).map(AuthorityBinding.init(value:))
                == event.controlHolds,
            event.target.itemID == event.resolution.itemID,
            event.target.revisionID != event.resolution.revisionID,
            try hasValidatedAuthorityControl(event.preCut)
        else { throw reviewInvalid("Decision differs from its exact reviewed canonical bindings.") }
        guard
            try authorityReviewControlHolds(revisionID: event.target.revisionID, cut: event.preCut)
                == event.controlHolds
        else {
            throw reviewInvalid("Decision omitted an actual maximal control hold at its PRE cut.")
        }
        for cause in event.retirements {
            guard let root = try retainedAuthorityObject(id: cause.recordID),
                root.descriptor.sha256 == cause.sha256
            else {
                throw reviewInvalid("Review retirement cause is missing or changed.")
            }
        }
        for cause in event.controlHolds {
            guard try hasValidatedAuthorityControl(cause) else {
                throw reviewInvalid("Decision hold cause is not validated.")
            }
        }
    }
    private func reviewInsertEvent(
        _ original: AuthorityRecordCodec.Verified, target: AuthorityStore.Target, evidence: AuthorityBinding,
        parents: [AuthorityBinding], preCut: AuthorityBinding?, resolution: AuthorityStore.Target?,
        recovery: Bool = false
    ) throws {
        guard let raw = try retainedAuthorityObject(id: target.revisionID), raw.descriptor.kind == .item,
            raw.descriptor.sha256 == target.sha256,
            try reviewNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_objects WHERE id=? AND item=?)",
                [target.revisionID, target.itemID]) == 1,
            try reviewNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_objects WHERE id=? AND sha256=? AND control_kind='authoredEvidence' AND evidence_target=?)",
                [evidence.recordID, evidence.sha256, target.revisionID]) == 1,
            parents.count <= 256, parents.map(\.recordID) == Array(Set(parents.map(\.recordID))).sorted()
        else { throw reviewInvalid("Review event lacks its exact retained target/evidence/context.") }
        let id = original.record.recordID
        let values = [
            id, original.sha256, target.itemID, target.revisionID, target.sha256, evidence.recordID,
            evidence.sha256, original.record.kind.rawValue, resolution?.revisionID ?? "",
            resolution?.sha256 ?? "", preCut?.recordID ?? "", preCut?.sha256 ?? "",
        ]
        if try reviewNumber("SELECT EXISTS(SELECT 1 FROM authority_review_event WHERE id=?)", [id]) == 1 {
            let s = try corpusPrepare(
                "SELECT id,sha256,item,target,target_digest,evidence,evidence_digest,kind,resolution,resolution_digest,cut,cut_digest FROM authority_review_event WHERE id=?",
                [id])
            defer { sqlite3_finalize(s) }
            guard catalogueStep(s) == SQLITE_ROW else { throw graphSQLiteError() }
            for column in 0..<values.count where try reviewText(s, Int32(column)) != values[column] {
                throw reviewInvalid("Review event ID collided with another binding.")
            }
            return
        }
        try reviewCapacity(UInt64(original.originalBytes.count) * 8 + UInt64(parents.count) * 2048 + 16384)
        for parent in parents {
            let validated =
                try reviewNumber(
                    "SELECT EXISTS(SELECT 1 FROM authority_review_event WHERE id=? AND sha256=? AND target=? AND target_digest=? AND evidence=? AND evidence_digest=?)",
                    [
                        parent.recordID, parent.sha256, target.revisionID, target.sha256, evidence.recordID,
                        evidence.sha256,
                    ]) == 1
            let provisional: Bool
            if recovery {
                provisional =
                    try reviewNumber(
                        "SELECT EXISTS(SELECT 1 FROM authority_objects o JOIN authority_dependencies d ON d.source=o.id AND d.kind='target' WHERE o.id=? AND o.sha256=? AND o.control_kind IN('reviewHold','reviewDecision') AND d.target=? AND d.sha256=?)",
                        [parent.recordID, parent.sha256, target.revisionID, target.sha256]) == 1
            } else {
                provisional = false
            }
            guard parent.recordID != id, original.record.parentAuthorityIDs.contains(parent.recordID),
                validated || provisional
            else { throw reviewInvalid("Review edge does not bind a validated same-target context.") }
        }
        try execute("INSERT INTO authority_review_event VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", values)
        for parent in parents {
            try execute(
                "INSERT INTO authority_review_edge VALUES(?,?,?)", [id, parent.recordID, parent.sha256])
            try execute(
                "DELETE FROM authority_review_head WHERE target=? AND id=?",
                [target.revisionID, parent.recordID])
        }
        try execute(
            "INSERT INTO authority_review_head SELECT ?,? WHERE NOT EXISTS(SELECT 1 FROM authority_review_edge WHERE parent=?)",
            [target.revisionID, id, id])
    }
    private func reviewRetained(_ original: AuthorityRecordCodec.Verified) throws {
        guard let raw = try retainedAuthorityObject(id: original.record.recordID),
            raw.descriptor.kind == .authority,
            raw.descriptor.sha256 == original.sha256, raw.descriptor.length == original.originalBytes.count,
            try AuthorityRecordCodec.decode(original.originalBytes) == original
        else { throw reviewInvalid("Review control differs from its sealed retained original.") }
    }

    func previewAuthorityReviewContext(
        held: AuthorityRevision, heldRow: CatalogueRow,
        loadVerified: @escaping (CatalogueRow) throws -> PooledCanonicalRecord,
        limits: RevisionProjection.Limits = .init(), progress: (() throws -> Void)? = nil
    ) throws -> RevisionProjection.Snapshot {
        guard !projectionAppendActive, !revisionProjectionActive else {
            throw reviewInvalid("Another writer owns review context.")
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
        var hydration = UInt64(held.originalBytes.count)
        guard hydration <= limits.maximumHydratedBytes else {
            throw reviewResource("Held review context exceeds hydration allowance.")
        }
        let bounded: (CatalogueRow) throws -> PooledCanonicalRecord = { row in
            guard row.size <= limits.maximumHydratedBytes - hydration else {
                throw self.reviewResource("Review context exhausted hydration allowance.")
            }
            hydration += row.size
            return try loadVerified(row)
        }
        try execute("SAVEPOINT authority_review")
        do {
            let snapshot = try withCatalogueScanBudget(progress: progress, reusingActiveBudget: true) {
                try withAuthorityPeerWorkAllowance(maximum: limits.maximumVMInstructions) {
                    guard try acceptedGraphProofIsCurrent(), try held.revision.provenance?.kind == .authored
                    else {
                        throw reviewInvalid("Held review context needs accepted proof and exact authored B.")
                    }
                    try reviewBindOriginal(held, row: heldRow, retained: true)
                    try reviewAdmitOriginal(held, row: heldRow, loadVerified: bounded)
                    try advanceAcceptedGraphProof()
                    return try analyzeRevisionProjection(
                        itemID: heldRow.itemID, loadVerified: bounded, limits: limits, progress: progress,
                        reusingActiveBudget: true)
                }
            }
            try rollbackAuthorityReview()
            restoreAuthorityPeerGraphState(saved)
            return snapshot
        } catch {
            do {
                try rollbackAuthorityReview()
                restoreAuthorityPeerGraphState(saved)
            } catch {
                invalidateRevisionGraphValidation()
                throw error
            }
            throw error
        }
    }
    func authorityReviewControlAllows(control: AuthorityBinding, revisionID: String) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            if try !reviewSchemaExists() { return false }
            return try reviewNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_review_applied a JOIN authority_review_event e ON e.id=a.decision AND e.sha256=a.sha256 WHERE a.control=? AND a.control_digest=? AND a.recovery=0 AND (e.target=? OR e.resolution=?))",
                [control.recordID, control.sha256, revisionID, revisionID]) == 1
        }
    }
    func previewAuthorityReview(
        plan: AuthorityStore.VerifiedReviewPlan, resolutionRow: CatalogueRow,
        loadVerified: @escaping (CatalogueRow) throws -> PooledCanonicalRecord,
        limits: RevisionProjection.Limits = .init(), progress: (() throws -> Void)? = nil,
        validate: ((RevisionProjection.Snapshot) throws -> Void)? = nil,
        allowConcurrentCurrent: Bool = false
    ) throws -> RevisionProjection.Snapshot {
        try performAuthorityReview(
            plan: plan, resolutionRow: resolutionRow, loadVerified: loadVerified,
            limits: limits, progress: progress, validate: validate, preview: true,
            allowConcurrentCurrent: allowConcurrentCurrent)
    }
    func applyValidatedReview(
        plan: AuthorityStore.VerifiedReviewPlan, resolutionRow: CatalogueRow,
        loadVerified: @escaping (CatalogueRow) throws -> PooledCanonicalRecord,
        limits: RevisionProjection.Limits = .init(), progress: (() throws -> Void)? = nil,
        validate: ((RevisionProjection.Snapshot) throws -> Void)? = nil,
        allowConcurrentCurrent: Bool = false
    ) throws -> RevisionProjection.Snapshot {
        try performAuthorityReview(
            plan: plan, resolutionRow: resolutionRow, loadVerified: loadVerified,
            limits: limits, progress: progress, validate: validate, preview: false,
            allowConcurrentCurrent: allowConcurrentCurrent)
    }
    private func performAuthorityReview(
        plan: AuthorityStore.VerifiedReviewPlan, resolutionRow: CatalogueRow,
        loadVerified: @escaping (CatalogueRow) throws -> PooledCanonicalRecord,
        limits: RevisionProjection.Limits, progress: (() throws -> Void)?,
        validate: ((RevisionProjection.Snapshot) throws -> Void)?, preview: Bool,
        allowConcurrentCurrent: Bool = false
    ) throws -> RevisionProjection.Snapshot {
        guard !projectionAppendActive, !revisionProjectionActive else {
            throw reviewInvalid("Another writer owns review admission.")
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
        var hydration = UInt64(
            plan.held.originalBytes.count + plan.resolution.originalBytes.count
                + plan.event.record.originalBytes.count + plan.evidence.originalBytes.count
                + plan.control.control.originalBytes.count)
        guard hydration <= limits.maximumHydratedBytes else {
            throw reviewResource("Review closure exceeds its hydration allowance.")
        }
        let boundedLoad: (CatalogueRow) throws -> PooledCanonicalRecord = { row in
            guard row.size <= limits.maximumHydratedBytes - hydration else {
                throw self.reviewResource("Review operation exhausted its cumulative hydration allowance.")
            }
            hydration += row.size
            return try loadVerified(row)
        }
        try execute("SAVEPOINT authority_review")
        do {
            let snapshot = try withCatalogueScanBudget(progress: progress, reusingActiveBudget: true) {
                try withAuthorityPeerWorkAllowance(maximum: limits.maximumVMInstructions) {
                    guard try acceptedGraphProofIsCurrent() else {
                        throw reviewInvalid("Review needs completed accepted graph proof.")
                    }
                    try reviewValidatePlan(plan, resolutionRow: resolutionRow, retained: !preview)
                    let event = plan.event
                    let priorApplied =
                        try reviewNumber(
                            "SELECT EXISTS(SELECT 1 FROM authority_review_applied WHERE decision=? AND sha256=? AND recovery=0)",
                            [event.record.record.recordID, event.record.sha256]) == 1
                    if priorApplied {
                        try reviewRequireCurrentReplay(plan, resolutionRow: resolutionRow)
                        // This is only an idempotent view of the CURRENT accepted graph.
                        // Never insert old B/C, dirty its cache or re-stage old dispositions.
                        let current = try analyzeRevisionProjection(
                            itemID: event.target.itemID, loadVerified: boundedLoad, limits: limits,
                            progress: progress, reusingActiveBudget: true)
                        try validate?(current)
                        return current
                    }
                    if !priorApplied && !allowConcurrentCurrent {
                        let frontier = try authorityReviewFrontier(revisionID: event.target.revisionID)
                        let own = try AuthorityBinding(
                            recordID: event.record.record.recordID, sha256: event.record.sha256)
                        guard frontier == event.parents || frontier == [own],
                            try authorityControlHead(originID: event.record.record.originReplicaID)
                                == event.preCut
                        else {
                            throw TractandaError(
                                "revisionConflict", "Review context changed before atomic application.")
                        }
                        let active = try revisionCount(itemID: event.target.itemID)
                        if active > 0 {
                            let before = try analyzeRevisionProjection(
                                itemID: event.target.itemID, loadVerified: boundedLoad, limits: limits,
                                progress: progress, reusingActiveBudget: true)
                            guard before.analysis.frontier == plan.policyFrontier.map(\.revisionID).sorted()
                            else { throw reviewInvalid("Review omitted a current accepted policy/input.") }
                        } else if !plan.policyFrontier.isEmpty {
                            throw reviewInvalid("Rootless review invented an accepted policy.")
                        }
                    }
                    for target in plan.policyFrontier {
                        guard
                            try eligibilityAtCut(revisionID: target.revisionID, cut: event.preCut)
                                == .eligible,
                            let row = try revision(target.revisionID), row.itemID == target.itemID,
                            reviewHex(row.digest) == target.sha256
                        else {
                            throw reviewInvalid("Review policy is not an exact PRE-cut eligible snapshot.")
                        }
                    }
                    try reviewInsertEvent(
                        event.record, target: event.target, evidence: event.evidence,
                        parents: event.parents, preCut: event.preCut, resolution: event.resolution)
                    try reviewAdmitOriginal(plan.held, row: plan.heldRow, loadVerified: boundedLoad)
                    try advanceAcceptedGraphProof()
                    if !priorApplied && !allowConcurrentCurrent {
                        let context = try analyzeRevisionProjection(
                            itemID: event.target.itemID, loadVerified: boundedLoad, limits: limits,
                            progress: progress, reusingActiveBudget: true)
                        guard
                            Set(context.physicalHeads).isSubset(
                                of: Set(try plan.resolution.revision.provenance!.parents))
                        else {
                            throw reviewInvalid("Fresh resolution omitted an actual reviewed physical input.")
                        }
                    }
                    try reviewAdmitOriginal(plan.resolution, row: resolutionRow, loadVerified: boundedLoad)
                    try execute("UPDATE current_projection SET dirty=1 WHERE item=?", [event.target.itemID])
                    try advanceAcceptedGraphProof()
                    // No B policy/body is installed. C is validated in its OWN actual parent context,
                    // even when an already accepted later revision dominates it on replay.
                    let current = try analyzeRevisionProjection(
                        itemID: event.target.itemID, loadVerified: boundedLoad,
                        limits: limits, progress: progress, reusingActiveBudget: true)
                    try validate?(current)
                    try reviewStageDispositions(plan)
                    try reviewRecordApplication(plan, recovery: false)
                    return current
                }
            }
            if preview {
                try rollbackAuthorityReview()
                restoreAuthorityPeerGraphState(saved)
            } else {
                try execute("RELEASE authority_review")
            }
            return snapshot
        } catch {
            do {
                try rollbackAuthorityReview()
                restoreAuthorityPeerGraphState(saved)
            } catch {
                invalidateRevisionGraphValidation()
                throw error
            }
            throw error
        }
    }
    private func reviewRequireCurrentReplay(
        _ plan: AuthorityStore.VerifiedReviewPlan, resolutionRow: CatalogueRow
    ) throws {
        guard try authorityReviewDisposition(revisionID: plan.event.target.revisionID) == .approved,
            try authorityDisposition(id: plan.event.target.revisionID)?.disposition == .eligible,
            try authorityDisposition(id: plan.event.resolution.revisionID)?.disposition == .eligible,
            try revision(plan.event.target.revisionID) == plan.heldRow,
            try revision(plan.event.resolution.revisionID) == resolutionRow,
            let current = try authorityControlHead(originID: plan.event.record.record.originReplicaID)
        else {
            throw TractandaError(
                "operationReviewRequired",
                "Historical approval is not a currently eligible accepted review effect.")
        }
        for id in [plan.event.target.revisionID, plan.event.resolution.revisionID] {
            for hold in try authorityReviewControlHolds(revisionID: id, cut: current) {
                guard try authorityControlContains(hold, in: plan.event.preCut) else {
                    throw TractandaError(
                        "operationReviewRequired",
                        "A newer validated causal hold supersedes this historical approval.")
                }
            }
        }
    }
    private func reviewValidatePlan(
        _ plan: AuthorityStore.VerifiedReviewPlan, resolutionRow: CatalogueRow, retained: Bool
    ) throws {
        try reviewCheckEvent(plan.event)
        try reviewBindOriginal(plan.held, row: plan.heldRow, retained: true)
        try reviewBindOriginal(plan.resolution, row: resolutionRow, retained: retained)
        try reviewValidateClosure(plan, retained: retained)
    }
    private func reviewValidateClosure(_ plan: AuthorityStore.VerifiedReviewPlan, retained: Bool) throws {
        let held = plan.held.revision
        let resolution = plan.resolution.revision
        try held.validate()
        try resolution.validate()
        try ItemSemantics.validate(held)
        try ItemSemantics.validate(resolution)
        guard plan.policyFrontier.count <= 1024,
            plan.policyFrontier.map(\.revisionID)
                == Array(Set(plan.policyFrontier.map(\.revisionID))).sorted(),
            plan.event.target
                == (try .init(itemID: held.itemID, revisionID: held.revisionID, sha256: plan.held.sha256)),
            plan.event.resolution
                == (try .init(
                    itemID: resolution.itemID, revisionID: resolution.revisionID,
                    sha256: plan.resolution.sha256)),
            try held.provenance?.kind == .authored, let p = try resolution.provenance,
            p.kind == .resolution, p.parents.contains(held.revisionID),
            resolution.fields["operationID"]?.string == plan.operationID,
            plan.event.record.record.actorPrincipal == plan.evidence.record.actorPrincipal,
            plan.evidence.record.payload["principal"]?.string == plan.event.record.record.actorPrincipal,
            resolution.fields["actor"]?.string == "user:" + plan.event.record.record.actorPrincipal
                || resolution.fields["actor"]?.string == "uid:"
                    + String(plan.evidence.record.payload["sourceUID"]!.integerValue!),
            plan.evidence.record.kind == .authoredEvidence,
            try AuthorityStore.Target(value: plan.evidence.record.payload["target"]!)
                == plan.event.resolution,
            try AuthorityRecord.list(plan.evidence.record.payload["sourceControl"]).map(
                AuthorityBinding.init(value:)) == [plan.event.preCut],
            try AuthorityRecord.list(plan.evidence.record.payload["acceptedAuthority"]).map(
                AuthorityBinding.init(value:)) == [
                    .init(recordID: plan.event.record.record.recordID, sha256: plan.event.record.sha256)
                ],
            try AuthorityStore.VerifiedControlPlan(control: plan.control.control) == plan.control,
            plan.control.control.record.originReplicaID == p.originReplicaID,
            plan.control.parents.contains(plan.event.preCut)
        else { throw reviewInvalid("Atomic review omitted or rebound its B/C/evidence/control closure.") }
        for (target, evidence) in [
            (plan.event.target, plan.event.evidence),
            (
                plan.event.resolution,
                try .init(recordID: plan.evidence.record.recordID, sha256: plan.evidence.sha256)
            ),
        ] {
            guard let delta = plan.control.deltas.first(where: { $0.target.revisionID == target.revisionID }),
                delta.target == target, delta.eligible, delta.evidence == evidence,
                delta.causes.contains(
                    try .init(recordID: plan.event.record.record.recordID, sha256: plan.event.record.sha256))
            else { throw reviewInvalid("Review post-control lacks an exact positive B/C decision effect.") }
        }
        guard plan.control.deltas.count == 2 else {
            throw reviewInvalid("Review cannot approve unnamed descendants.")
        }
        if retained {
            try reviewRetained(plan.event.record)
            try reviewRetained(plan.evidence)
            try reviewRetained(plan.control.control)
        }
        let sum = UInt64(plan.held.originalBytes.count).addingReportingOverflow(
            UInt64(plan.resolution.originalBytes.count))
        guard !sum.overflow else { throw reviewResource("Review hydration estimate overflowed.") }
        try reviewCapacity(
            sum.partialValue + UInt64(
                plan.event.record.originalBytes.count + plan.evidence.originalBytes.count
                    + plan.control.control.originalBytes.count) * 8)
    }
    private func reviewBindOriginal(_ original: AuthorityRevision, row: CatalogueRow, retained: Bool) throws {
        let value = original.revision
        try value.validate()
        try ItemSemantics.validate(value)
        guard row.revisionID == value.revisionID, row.itemID == value.itemID,
            row.parentID == value.supersedes,
            row.modifiedAt == value.modifiedAt, row.createdAt == value.fields["createdAt"]?.dateString,
            row.actor == value.fields["actor"]?.string,
            row.operationID == value.fields["operationID"]?.string,
            row.provenance == (try value.provenance), row.size == UInt64(original.originalBytes.count),
            reviewHex(row.digest) == original.sha256
        else { throw reviewInvalid("Review original does not bind its exact descriptor.") }
        if retained {
            guard let raw = try retainedAuthorityObject(id: value.revisionID), raw.descriptor.kind == .item,
                raw.path == row.path, raw.descriptor.sha256 == original.sha256,
                raw.descriptor.length == original.originalBytes.count
            else { throw reviewInvalid("Review original lacks its sealed retained locator.") }
        }
    }
    private func reviewAdmitOriginal(
        _ original: AuthorityRevision, row: CatalogueRow,
        loadVerified: (CatalogueRow) throws -> PooledCanonicalRecord
    ) throws {
        if let existing = try revision(row.revisionID) {
            guard existing == row else {
                throw reviewInvalid("Review revision ID collided with accepted bytes.")
            }
            return
        }
        let value = original.revision
        let parents = try value.provenance?.parents ?? []
        if parents.isEmpty {
            guard try revisionCount(itemID: row.itemID) == 0 else {
                throw reviewInvalid("Review would introduce a second item root.")
            }
        }
        for parent in parents {
            guard let row = try revision(parent) else {
                throw TractandaError(
                    "missingDependencies", "Review requires its actual eligible parent before admission.")
            }
            guard row.itemID == value.itemID,
                row.createdAt == value.fields["createdAt"]?.dateString,
                try RevisionTimestamp(value.modifiedAt) > RevisionTimestamp(row.modifiedAt)
            else { throw reviewInvalid("Review parent is cross-item or not causally older.") }
        }
        if try value.provenance?.kind == .authored, let parentID = parents.first,
            let row = try revision(parentID)
        {
            let parent = try loadVerified(row).revision
            try bindNormalizedSnapshot(parent)
            let before = RevisionMerge.semanticFields(parent)
            let after = RevisionMerge.semanticFields(value)
            let p = try value.provenance!
            for field in Set(before.keys).union(after.keys) where before[field] != after[field] {
                guard after[field] == nil ? p.unsetFields.contains(field) : p.writtenFields.contains(field)
                else { throw reviewInvalid("Reviewed authored revision omitted an actual snapshot delta.") }
            }
        }
        let feedback =
            (value.fields["learningFeedback"]?.map?.values.compactMap { $0.map?["revisionID"]?.string } ?? [])
            .sorted()
        guard feedback == row.feedbackRevisionIDs.sorted() else {
            throw reviewInvalid("Review omitted feedback references.")
        }
        try insertRecoveryRow(row, graphFields: value.fields)
        _ = try appendAcceptedGraphBookkeeping(row: row, parents: parents, feedback: feedback)
    }
    private func reviewRecordApplication(_ plan: AuthorityStore.VerifiedReviewPlan, recovery: Bool) throws {
        let d = plan.event.record
        let request = plan.resolution.revision.fields["requestIdentity"]?.string ?? ""
        let values = [
            d.record.recordID, d.sha256, plan.event.resolution.revisionID, plan.event.resolution.sha256,
            plan.control.binding.recordID, plan.control.binding.sha256, d.record.originReplicaID,
            d.record.actorPrincipal, plan.operationID, request,
        ]
        let s = try corpusPrepare(
            "SELECT decision,sha256,revision,digest,control,control_digest,origin,actor,operation,request FROM authority_review_applied WHERE decision=? OR (origin=? AND actor=? AND operation=?)",
            [d.record.recordID, d.record.originReplicaID, d.record.actorPrincipal, plan.operationID])
        let status = catalogueStep(s)
        if status == SQLITE_ROW {
            defer { sqlite3_finalize(s) }
            for column in 0..<values.count where try reviewText(s, Int32(column)) != values[column] {
                throw reviewInvalid("Review retry differs from its reserved canonical operation.")
            }
            guard catalogueStep(s) == SQLITE_DONE else {
                throw reviewInvalid("Review operation has competing canonical bindings.")
            }
            if !recovery {
                try execute(
                    "UPDATE authority_review_applied SET recovery=0 WHERE decision=?", [d.record.recordID])
            }
            return
        }
        sqlite3_finalize(s)
        guard status == SQLITE_DONE else { throw graphSQLiteError() }
        try execute(
            "INSERT INTO authority_review_applied VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            values + [recovery ? "1" : "0"])
    }
    /// One exact reviewed C may replace several PRE policy snapshots. Each pair
    /// remains a separate historical transition so a later grant cannot hide a revoke.
    func retainValidatedReviewInvalidation(
        _ plan: AuthorityStore.VerifiedReviewPlan, previous: AuthorityRevision
    ) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try reviewCheckEvent(plan.event)
            try reviewValidateClosure(plan, retained: true)
            let c = plan.resolution.revision
            let old = previous.revision
            let target = try AuthorityStore.Target(
                itemID: old.itemID, revisionID: old.revisionID, sha256: previous.sha256)
            guard plan.policyFrontier.contains(target), old.itemID == c.itemID,
                try AuthorityRecord.list(plan.event.record.record.payload["itemPolicies"]).map(
                    AuthorityStore.Target.init(value:)) == plan.policyFrontier,
                try hasValidatedAuthorityControl(plan.control.binding),
                try authorityReviewControlAllows(control: plan.control.binding, revisionID: c.revisionID),
                try reviewNumber(
                    "SELECT EXISTS(SELECT 1 FROM authority_review_applied a JOIN authority_review_event e ON e.id=a.decision AND e.sha256=a.sha256 WHERE a.decision=? AND a.sha256=? AND a.revision=? AND a.digest=? AND a.control=? AND a.control_digest=? AND a.recovery=0 AND e.cut=? AND e.cut_digest=?)",
                    [
                        plan.event.binding.recordID, plan.event.binding.sha256, c.revisionID,
                        plan.resolution.sha256, plan.control.binding.recordID, plan.control.binding.sha256,
                        plan.event.preCut.recordID, plan.event.preCut.sha256,
                    ]) == 1,
                try eligibilityAtCut(revisionID: old.revisionID, cut: plan.event.preCut) == .eligible,
                try eligibilityAtCut(revisionID: c.revisionID, cut: plan.control.binding) == .eligible,
                let raw = try retainedAuthorityObject(id: old.revisionID), raw.descriptor.kind == .item,
                raw.descriptor.sha256 == previous.sha256,
                raw.descriptor.length == previous.originalBytes.count,
                try c.provenance?.kind == .resolution
            else {
                throw reviewInvalid(
                    "Review invalidation lacks its exact applied D/C/control and eligible PRE policy.")
            }
            try AuthorityStore.validateReviewPolicyTransition(plan, previous: previous)
            try recordValidatedAuthorityInvalidation(
                .init(
                    control: plan.control.binding, sourceCut: plan.event.preCut,
                    policy: plan.event.resolution, previousPolicyID: old.revisionID))
        }
    }
    /// Consume only an obsolete queued NEGATIVE effect. Canonical/local acceptance
    /// and its exact source context must already be validated; this grants nothing
    /// and never changes dispositions, ancestry, local history or exposure clocks.
    func consumeSupersededAuthorityEffect(
        control: AuthorityBinding, originID: String, target: AuthorityStore.Target, cut: AuthorityBinding,
        original: AuthorityRevision? = nil, evidence: AuthorityRecordCodec.Verified? = nil,
        review: AuthorityStore.VerifiedReviewPlan? = nil
    ) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let pending = try corpusPrepare(
                "SELECT item,fingerprint,payload FROM authority_pending_effect WHERE revision=?",
                [target.revisionID])
            let status = catalogueStep(pending)
            if status == SQLITE_DONE {
                sqlite3_finalize(pending)
                return
            }
            guard status == SQLITE_ROW else {
                sqlite3_finalize(pending)
                throw graphSQLiteError()
            }
            var rowBytes = 0
            let item: String
            let fingerprint: String
            let payload: String
            do {
                try reviewBoundRow(pending, bytes: &rowBytes)
                item = try reviewText(pending, 0)
                fingerprint = try reviewText(pending, 1)
                payload = try reviewText(pending, 2)
            } catch {
                sqlite3_finalize(pending)
                throw error
            }
            sqlite3_finalize(pending)
            let delta = try AuthorityStore.DispositionDelta(
                value: JSON.decode(ItemValue.self, Data(payload.utf8)))
            let encoded = try JSON.encode(delta.itemValue)
            guard item == target.itemID, delta.target == target, !delta.eligible,
                !delta.causes.isEmpty, fingerprint == AuthorityRecordCodec.sha256(encoded),
                payload == String(decoding: encoded, as: UTF8.self),
                try authorityControlHead(originID: originID) == control,
                try hasValidatedAuthorityControl(cut), try authorityControlContains(cut, in: control),
                try reviewNumber(
                    "SELECT EXISTS(SELECT 1 FROM authority_control c JOIN authority_local_acceptance l ON l.control=c.id AND l.sha256=c.sha256 JOIN authority_control_delta d ON d.control=c.id WHERE c.id=? AND c.sha256=? AND c.origin=? AND d.target=? AND d.item=? AND d.sha256=? AND d.eligible=1)",
                    [
                        control.recordID, control.sha256, originID, target.revisionID, target.itemID,
                        target.sha256,
                    ]) == 1,
                try eligibilityAtCut(revisionID: target.revisionID, cut: control) == .eligible
            else {
                throw reviewInvalid(
                    "Pending-effect consumption lacks an exact current local positive control/fingerprint.")
            }
            if let review {
                guard original == nil, evidence == nil, review.control.binding == control,
                    review.event.preCut == cut,
                    target == review.event.target || target == review.event.resolution,
                    try authorityReviewControlAllows(control: control, revisionID: target.revisionID),
                    try reviewNumber(
                        "SELECT EXISTS(SELECT 1 FROM authority_review_applied WHERE decision=? AND sha256=? AND revision=? AND digest=? AND control=? AND control_digest=? AND recovery=0)",
                        [
                            review.event.binding.recordID, review.event.binding.sha256,
                            review.event.resolution.revisionID, review.event.resolution.sha256,
                            control.recordID, control.sha256,
                        ]) == 1
                else {
                    throw reviewInvalid(
                        "Only the fully applied exact review can consume its named B/C effects.")
                }
                try reviewCheckEvent(review.event)
                try reviewValidateClosure(review, retained: true)
            } else {
                guard let original, let evidence else {
                    throw reviewInvalid("Independent authored cleanup needs its exact original/evidence.")
                }
                try reviewRequireAcceptedAuthoredSource(
                    control: control, target: target, cut: cut, original: original, evidence: evidence)
            }
            for cause in delta.causes {
                guard try hasValidatedAuthorityControl(cause) else {
                    throw reviewInvalid("Pending effect has an unvalidated cause.")
                }
                if try !authorityControlContains(cause, in: cut) { return }
            }
            // Exact CAS: a changed/newer row can never be cleared by this old snapshot.
            try execute(
                "DELETE FROM authority_pending_effect WHERE revision=? AND item=? AND fingerprint=? AND payload=?",
                [target.revisionID, target.itemID, fingerprint, payload])
        }
    }
    /// Canonical selected testimony is necessary even for an already locally accepted
    /// authored fact. A raw sourceControl field or authoredEvidence kind is insufficient.
    private func reviewRequireAcceptedAuthoredSource(
        control: AuthorityBinding, target: AuthorityStore.Target, cut: AuthorityBinding,
        original: AuthorityRevision, evidence: AuthorityRecordCodec.Verified
    ) throws {
        guard let p = try original.revision.provenance,
            p.kind == .authored, original.revision.itemID == target.itemID,
            original.revision.revisionID == target.revisionID, original.sha256 == target.sha256,
            let raw = try retainedAuthorityObject(id: target.revisionID),
            raw.descriptor.kind == .item,
            raw.descriptor.sha256 == original.sha256,
            raw.descriptor.length == original.originalBytes.count,
            evidence.record.kind == .authoredEvidence,
            evidence.record.originReplicaID == p.originReplicaID,
            evidence.record.actorPrincipal == evidence.record.payload["principal"]?.string,
            original.revision.fields["actor"]?.string == "user:" + evidence.record.actorPrincipal
                || original.revision.fields["actor"]?.string == "uid:"
                    + String(evidence.record.payload["sourceUID"]!.integerValue!),
            try AuthorityStore.Target(value: evidence.record.payload["target"]!) == target,
            try AuthorityRecord.ids(evidence.record.payload["parents"], maximum: 1024) == p.parents,
            evidence.record.payload["intent"]?.map?["writtenFields"]
                == .list(p.writtenFields.map(ItemValue.text)),
            evidence.record.payload["intent"]?.map?["unsetFields"]
                == .list(p.unsetFields.map(ItemValue.text)),
            evidence.record.payload["evaluated"] == .boolean(true),
            try AuthorityRecord.list(evidence.record.payload["acceptedAuthority"]).isEmpty,
            try AuthorityRecord.list(evidence.record.payload["sourceControl"]).map(
                AuthorityBinding.init(value:)) == [cut],
            let selected = try authorityEvidence(revisionID: target.revisionID),
            selected.descriptor.id == evidence.record.recordID,
            selected.descriptor.sha256 == evidence.sha256,
            selected.descriptor.length == evidence.originalBytes.count,
            try reviewNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_control WHERE id=? AND sha256=? AND origin=?)",
                [cut.recordID, cut.sha256, p.originReplicaID]) == 1,
            try reviewNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_control_delta WHERE control=? AND target=? AND evidence=?)",
                [
                    control.recordID, target.revisionID,
                    String(
                        decoding: JSON.encode(
                            ItemValue.list([
                                AuthorityBinding(
                                    recordID: evidence.record.recordID, sha256: evidence.sha256
                                ).itemValue
                            ])), as: UTF8.self),
                ]) == 1
        else {
            throw reviewInvalid(
                "Independent authored cleanup lacks selected local accepted source evidence.")
        }
        try reviewRetained(evidence)
    }
    /// Recovery-only incremental graph restore after Main has restored exact LOCAL
    /// sealed acceptance and selected testimony. Does not authorize or publish a write.
    func restoreLocallyAcceptedAuthored(
        row: CatalogueRow, original: AuthorityRevision, control: AuthorityBinding,
        evidence: AuthorityRecordCodec.Verified,
        loadVerified: @escaping (CatalogueRow) throws -> PooledCanonicalRecord,
        limits: RevisionProjection.Limits = .init(), progress: (() throws -> Void)? = nil
    ) throws {
        guard !projectionAppendActive, !revisionProjectionActive else {
            throw reviewInvalid("Another writer owns accepted graph restoration.")
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
        var hydration = UInt64(original.originalBytes.count + evidence.originalBytes.count)
        guard hydration <= limits.maximumHydratedBytes else {
            throw reviewResource("Accepted authored restoration exceeds hydration allowance.")
        }
        let bounded: (CatalogueRow) throws -> PooledCanonicalRecord = { row in
            guard row.size <= limits.maximumHydratedBytes - hydration else {
                throw self.reviewResource("Accepted restoration exhausted cumulative hydration allowance.")
            }
            hydration += row.size
            let loaded = try loadVerified(row)
            try self.reviewBindHydrated(loaded, row: row)
            return loaded
        }
        try execute("SAVEPOINT authority_review")
        do {
            try withCatalogueScanBudget(progress: progress, reusingActiveBudget: true) {
                try withAuthorityPeerWorkAllowance(maximum: limits.maximumVMInstructions) {
                    guard try acceptedGraphProofIsCurrent(), let p = try original.revision.provenance,
                        p.kind == .authored,
                        try authorityDisposition(id: row.revisionID)?.disposition == .eligible,
                        try !authorityReviewIsProvisional(revisionID: row.revisionID),
                        try reviewNumber(
                            "SELECT EXISTS(SELECT 1 FROM authority_control c JOIN authority_control_heads h ON h.id=c.id AND h.sha256=c.sha256 AND h.origin=c.origin JOIN authority_local_acceptance l ON l.control=c.id AND l.sha256=c.sha256 JOIN authority_control_delta d ON d.control=c.id WHERE c.id=? AND c.sha256=? AND d.target=? AND d.item=? AND d.sha256=? AND d.eligible=1)",
                            [control.recordID, control.sha256, row.revisionID, row.itemID, original.sha256])
                            == 1,
                        try eligibilityAtCut(revisionID: row.revisionID, cut: control) == .eligible
                    else {
                        throw reviewInvalid(
                            "Accepted authored restoration lacks current private-local positive proof.")
                    }
                    try reviewBindOriginal(original, row: row, retained: true)
                    let cuts = try AuthorityRecord.list(evidence.record.payload["sourceControl"])
                    guard cuts.count == 1 else {
                        throw reviewInvalid("Accepted authored source cut is missing or ambiguous.")
                    }
                    let cut = try AuthorityBinding(value: cuts[0])
                    guard try hasValidatedAuthorityControl(cut),
                        try authorityControlContains(cut, in: control)
                    else {
                        throw reviewInvalid(
                            "Accepted authored source cut is not validated in the local acceptance.")
                    }
                    try reviewRequireAcceptedAuthoredSource(
                        control: control,
                        target: .init(
                            itemID: row.itemID, revisionID: row.revisionID, sha256: original.sha256),
                        cut: cut, original: original, evidence: evidence)
                    for parent in p.parents {
                        guard let accepted = try revision(parent),
                            try authorityDisposition(id: parent)?.disposition == .eligible
                        else {
                            throw TractandaError(
                                "missingDependencies",
                                "Locally accepted authored parent has not been restored.")
                        }
                        guard accepted.itemID == row.itemID,
                            try !authorityReviewIsProvisional(revisionID: parent)
                        else {
                            throw reviewInvalid(
                                "Accepted authored parent is cross-item or provisionally reviewed.")
                        }
                    }
                    if let existing = try revision(row.revisionID) {
                        guard existing == row else {
                            throw reviewInvalid(
                                "Accepted authored identity collided with catalogue metadata/bytes.")
                        }
                        return
                    }
                    try reviewCapacity(
                        UInt64(original.originalBytes.count + evidence.originalBytes.count) * 8 + 16384)
                    let loaded = try bounded(row)
                    guard loaded.revision == original.revision else {
                        throw reviewInvalid("Accepted authored hydration differs from exact original bytes.")
                    }
                    try reviewAdmitOriginal(original, row: row, loadVerified: bounded)
                    try execute("UPDATE current_projection SET dirty=1 WHERE item=?", [row.itemID])
                    try advanceAcceptedGraphProof()
                }
            }
            try execute("RELEASE authority_review")
        } catch {
            do {
                try rollbackAuthorityReview()
                restoreAuthorityPeerGraphState(saved)
            } catch {
                invalidateRevisionGraphValidation()
                throw error
            }
            throw error
        }
    }
    private func reviewBindHydrated(_ record: PooledCanonicalRecord, row: CatalogueRow) throws {
        let value = record.revision
        let m = record.metadata
        guard value.revisionID == row.revisionID, value.itemID == row.itemID,
            value.modifiedAt == row.modifiedAt, value.supersedes == row.parentID,
            value.fields["createdAt"]?.dateString == row.createdAt,
            value.fields["actor"]?.string == row.actor,
            value.fields["operationID"]?.string == row.operationID,
            try value.provenance == row.provenance,
            m.size == row.size, m.inode == row.inode, m.uid == row.uid, m.mode == row.mode,
            m.modificationSeconds == row.modificationSeconds,
            m.modificationNanoseconds == row.modificationNanoseconds
        else { throw reviewInvalid("Accepted restoration loader did not bind its exact canonical row.") }
    }
    func authorityReviewApprovalCovers(revisionID: String, causes: [AuthorityBinding]) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            if try !reviewSchemaExists() { return false }
            guard try authorityReviewDisposition(revisionID: revisionID) == .approved else { return false }
            for head in try authorityReviewFrontier(revisionID: revisionID) {
                guard try peerAuthorityIssuerPermits(head.recordID) else { continue }
                let s = try corpusPrepare(
                    "SELECT cut,cut_digest FROM authority_review_event WHERE id=? AND sha256=?",
                    [head.recordID, head.sha256])
                defer { sqlite3_finalize(s) }
                guard catalogueStep(s) == SQLITE_ROW else {
                    throw reviewInvalid("Approved decision is missing.")
                }
                let cut = try AuthorityBinding(recordID: reviewText(s, 0), sha256: reviewText(s, 1))
                for cause in causes where try !authorityControlContains(cause, in: cut) { return false }
            }
            return true
        }
    }
    /// Typed, sealed recovery closure only. Current authority remains gated until
    /// the ordinary accepted graph and C's own-context projection validate in full.
    func retainRecoveryAuthorityReview(plan: AuthorityStore.VerifiedReviewPlan) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try reviewCheckEvent(plan.event)
            try reviewValidateClosure(plan, retained: true)
            guard let c = try retainedAuthorityObject(id: plan.event.resolution.revisionID),
                c.descriptor.sha256 == plan.resolution.sha256,
                let b = try retainedAuthorityObject(id: plan.event.target.revisionID),
                b.descriptor.sha256 == plan.held.sha256,
                try AuthorityStore.Target(value: plan.evidence.record.payload["target"]!)
                    == plan.event.resolution
            else { throw reviewInvalid("Recovery review lacks exact B/C/evidence bytes.") }
            try reviewInsertEvent(
                plan.event.record, target: plan.event.target, evidence: plan.event.evidence,
                parents: plan.event.parents, preCut: plan.event.preCut, resolution: plan.event.resolution,
                recovery: true)
            try reviewStageDispositions(plan)
            try reviewRecordApplication(plan, recovery: true)
        }
    }
    func completeRecoveryAuthorityReview(resolutionID: String) throws {
        guard try reviewSchemaExists() else { return }
        let s = try corpusPrepare(
            "SELECT a.decision,a.digest,e.item FROM authority_review_applied a JOIN authority_review_event e ON e.id=a.decision AND e.sha256=a.sha256 WHERE a.revision=? AND a.recovery=1",
            [resolutionID])
        defer { sqlite3_finalize(s) }
        let status = catalogueStep(s)
        if status == SQLITE_DONE { return }
        guard revisionProjectionActive, try acceptedGraphProofIsCurrent(), status == SQLITE_ROW,
            let row = try revision(resolutionID), row.itemID == (try reviewText(s, 2)),
            reviewHex(row.digest) == (try reviewText(s, 1)), row.provenance?.kind == .resolution
        else { throw reviewInvalid("Recovery resolution does not bind its validated review target.") }
        let decision = try reviewText(s, 0)
        guard
            try reviewNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_review_edge x JOIN authority_review_event c ON c.id=x.child LEFT JOIN authority_review_event p ON p.id=x.parent AND p.sha256=x.sha256 AND p.target=c.target AND p.target_digest=c.target_digest AND p.evidence=c.evidence AND p.evidence_digest=c.evidence_digest WHERE x.child=? AND p.id IS NULL)",
                [decision]) == 0
        else { throw reviewInvalid("Recovery review context is incomplete.") }
        try execute("UPDATE authority_review_applied SET recovery=0 WHERE decision=?", [decision])
    }
    /// A sealed recovery candidate, explicitly NOT a current eligibility/permission.
    /// Main uses this only to defer its post-control until full C validation completes.
    func authorityReviewIsProvisional(revisionID: String) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(revisionID))
            if try !reviewSchemaExists() { return false }
            if try reviewNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_review_applied INDEXED BY authority_review_resolution WHERE revision=? AND recovery=1)",
                [revisionID]) == 1
            {
                return true
            }
            return try reviewNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_review_event e INDEXED BY authority_review_target JOIN authority_review_applied a ON a.decision=e.id AND a.sha256=e.sha256 WHERE e.target=? AND a.recovery=1)",
                [revisionID]) == 1
        }
    }
    /// Keyset over registered review effects only. A byte-limited prefix is not end;
    /// callers continue with the last returned item until the next page is empty.
    func authorityReviewItemPage(after: String? = nil, limit: Int = 128) throws -> [String] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit) else { throw reviewInvalid("Invalid review item page limit.") }
            if let after { _ = try AuthorityRecord.persistentID(.text(after)) }
            if try !reviewSchemaExists() { return [] }
            let s = try corpusPrepare(
                "SELECT DISTINCT item FROM authority_review_event INDEXED BY authority_review_item"
                    + (after == nil ? "" : " WHERE item>?") + " ORDER BY item LIMIT ?",
                (after.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var result: [String] = []
            var bytes = 0
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                let next = Int(sqlite3_column_bytes(s, 0))
                guard next <= AuthorityRecord.maximumBytes - 256 else {
                    throw reviewResource("Review item metadata exceeds its row window.")
                }
                if !result.isEmpty, next + 256 > graphMaximumPageBytes - min(bytes, graphMaximumPageBytes) {
                    return result
                }
                try reviewBoundRow(s, bytes: &bytes)
                result.append(try reviewText(s, 0))
            }
        }
    }
    func authorityReviewRecoveryIsComplete() throws -> Bool {
        if try !reviewSchemaExists() { return true }
        return try reviewNumber(
            "SELECT EXISTS(SELECT 1 FROM authority_review_applied WHERE recovery=1 LIMIT 1)") == 0
    }
    private func reviewSchemaExists() throws -> Bool {
        try reviewNumber(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='authority_review_event')")
            == 1
    }
    /// Receipt selection is intentionally left to Main's sealed-control restore,
    /// inside the same nonserving transaction; a raw permitted-origin OR is no grant.
    private func reviewStageDispositions(_ plan: AuthorityStore.VerifiedReviewPlan) throws {
        for target in [plan.event.target, plan.event.resolution] {
            try execute(
                "UPDATE authority_dispositions SET state='eligible',reason='Exact sealed atomic review closure.' WHERE object=?",
                [target.revisionID])
            try execute("UPDATE authority_packages SET pending=0 WHERE object=?", [target.revisionID])
        }
    }
    private func reviewHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func reviewText(_ s: OpaquePointer, _ column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(s, column))
        guard count <= AuthorityRecord.maximumBytes, let value = sqlite3_column_text(s, column),
            let text = String(bytes: UnsafeBufferPointer(start: value, count: count), encoding: .utf8)
        else { throw reviewInvalid("Malformed review metadata.") }
        return text
    }
    private func reviewBoundRow(_ s: OpaquePointer, bytes: inout Int) throws {
        var size = 256
        for column in 0..<sqlite3_column_count(s) {
            let count = Int(sqlite3_column_bytes(s, column))
            guard count <= AuthorityRecord.maximumBytes - min(size, AuthorityRecord.maximumBytes) else {
                throw reviewResource("Review metadata row exceeds its window.")
            }
            size += count
        }
        guard size <= graphMaximumPageBytes - min(bytes, graphMaximumPageBytes) else {
            throw reviewResource("Complete review metadata exceeds its byte window.")
        }
        bytes += size
    }
    private func reviewNumber(_ sql: String, _ args: [String] = []) throws -> Int64 {
        let s = try corpusPrepare(sql, args)
        defer { sqlite3_finalize(s) }
        guard catalogueStep(s) == SQLITE_ROW else { throw graphSQLiteError() }
        return sqlite3_column_int64(s, 0)
    }
    private func reviewCapacity(_ bytes: UInt64) throws {
        try checkCatalogueScanProgress()
        guard bytes <= graphMaximumTemporaryBytes else {
            throw reviewResource("Review staging exceeds its allowance.")
        }
        try requireGraphCapacity(additionalBytes: bytes)
    }
    private func reviewInvalid(_ message: String) -> TractandaError {
        .init("invalidAuthorityReview", message)
    }
    private func reviewResource(_ message: String) -> TractandaError { .init("resourceLimit", message) }
    func restoreRetirementHeldHistory(
        original: AuthorityRevision, row: CatalogueRow,
        loadVerified: (CatalogueRow) throws -> PooledCanonicalRecord
    ) throws {
        guard try peerRetirementRecheckContains(row.revisionID),
            try authorityHasLocalHistoryAdmission(revisionID: row.revisionID),
            try authorityDisposition(id: row.revisionID)?.disposition == .eligible,
            try acceptedGraphProofIsCurrent()
        else {
            throw reviewInvalid("Timestamp recheck cannot manufacture historical acceptance.")
        }
        try reviewBindOriginal(original, row: row, retained: true)
        try reviewAdmitOriginal(original, row: row, loadVerified: loadVerified)
        try execute("UPDATE current_projection SET dirty=1 WHERE item=?", [row.itemID])
        try advanceAcceptedGraphProof()
    }
    func authorityAppliedReviewControl(resolutionID: String, digest: String) throws -> AuthorityBinding? {
        guard try reviewSchemaExists() else { return nil }
        let statement = try corpusPrepare(
            "SELECT control,control_digest FROM authority_review_applied WHERE revision=? AND digest=? AND recovery=0",
            [resolutionID, digest])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw graphSQLiteError() }
        return try .init(recordID: reviewText(statement, 0), sha256: reviewText(statement, 1))
    }

}
