import Foundation

extension PeerIntakeCoordinator {
    struct SourceCutDraft {
        let cut: AuthorityBinding?
        let records: [AuthorityRecord]
    }
    func sourceControl(_ evidence: AuthorityRecord) throws -> AuthorityBinding? {
        try AuthorityRecord.list(evidence.payload["sourceControl"]).first.map(AuthorityBinding.init(value:))
    }
    func control(_ binding: AuthorityBinding, index: ItemIndex) throws -> AuthorityRecordCodec.Verified {
        guard let row = try index.retainedAuthorityObject(id: binding.recordID),
            row.descriptor.kind == .authority, row.descriptor.sha256 == binding.sha256
        else {
            throw TractandaError("missingDependencies", "Exact causal control is missing.")
        }
        return try AuthorityRecordCodec.decode(bytes(row))
    }
    func bindingAtCut(_ value: ItemValue, cut: AuthorityBinding, index: ItemIndex) throws
        -> AuthorityRevision?
    {
        let target = try AuthorityRecord.binding(value)
        guard try index.eligibilityAtCut(revisionID: target.revisionID, cut: cut) == .eligible,
            let row = try index.retainedAuthorityObject(id: target.revisionID),
            row.descriptor.sha256 == target.sha256
        else { return nil }
        let result = try AuthorityRevision(originalBytes: bytes(row))
        guard result.revision.itemID == target.itemID else {
            throw TractandaError("invalidAuthority", "Cut policy identity differs.")
        }
        return result
    }
    func validatePolicyCut(_ evidence: AuthorityRecord, index: ItemIndex) throws {
        guard let cut = try sourceControl(evidence), try index.hasValidatedAuthorityControl(cut) else {
            throw TractandaError("missingDependencies", "Source PRE-publication cut is not validated.")
        }
        guard try control(cut, index: index).record.originReplicaID == evidence.originReplicaID else {
            throw TractandaError(
                "invalidAuthority", "A source PRE cut must be this writing replica's validated context.")
        }
        for field in ["admissionPolicies", "itemPolicies"] {
            var groups: [String: [String]] = [:]
            for value in try AuthorityRecord.list(evidence.payload[field]) {
                let b = try AuthorityRecord.binding(value)
                groups[b.itemID, default: []].append(b.revisionID)
            }
            for (item, ids) in groups {
                let maxima = try index.authorityItemFrontierAtCut(itemID: item, cut: cut)
                if maxima == ids.sorted() { continue }
                guard field == "itemPolicies", ids.count == 1,
                    try AuthorityRecord.ids(evidence.payload["parents"], maximum: 1024).contains(ids[0]),
                    try index.authorityPolicyFrontierCovered(parentID: ids[0], physicalFrontier: maxima),
                    let parentRow = try index.retainedAuthorityObject(id: ids[0])
                else {
                    throw TractandaError(
                        "invalidAuthority", "Source policies are not current at the frozen PRE cut.")
                }
                let parent = try AuthorityRevision(originalBytes: bytes(parentRow)).revision
                let context =
                    try parent.provenance?.kind == .automaticMerge
                    ? parent.provenance!.frontier : [parent.revisionID]
                for id in maxima {
                    guard let row = try index.retainedAuthorityObject(id: id) else {
                        throw TractandaError("missingDependencies", "Exact-cut policy original is missing.")
                    }
                    let value = try AuthorityRevision(originalBytes: bytes(row)).revision
                    let other =
                        try value.provenance?.kind == .automaticMerge
                        ? value.provenance!.frontier : [id]
                    if context == other,
                        RevisionMerge.semanticFields(parent) != RevisionMerge.semanticFields(value)
                    {
                        throw TractandaError(
                            "invalidAuthority", "Equivalent causal policies have different complete payloads."
                        )
                    }
                }
            }
        }
    }
    func makeControl(
        origin: String, actor: String, localParent: AuthorityBinding?, parents: [AuthorityBinding],
        deltas: [AuthorityStore.DispositionDelta], bootstrap: AuthorityBinding?
    ) throws -> AuthorityRecord {
        try AuthorityRecord(
            recordID: UUID.makeVersion1().uuidString.lowercased(), storeID: storeID,
            originReplicaID: origin, kind: .controlCommit,
            parentAuthorityIDs: parents.map(\.recordID).sorted(),
            actorPrincipal: actor, createdAt: Timestamp.now(),
            payload: [
                "controls": .list(parents.sorted { $0.recordID < $1.recordID }.map(\.itemValue)),
                "localParent": .list(localParent.map { [$0.itemValue] } ?? []),
                "deltas": .list(
                    deltas.sorted { $0.target.revisionID < $1.target.revisionID }.map(\.itemValue)),
                "bootstrap": .list(bootstrap.map { [$0.itemValue] } ?? []),
            ])
    }
    func recordBinding(_ record: AuthorityRecord) throws -> AuthorityBinding {
        try .init(
            recordID: record.recordID,
            sha256: AuthorityRecordCodec.sha256(AuthorityRecordCodec.encode(record)))
    }
    private func acceptedImportContext(
        _ head: AuthorityBinding, previous: AuthorityBinding?, index: ItemIndex,
        work: inout Int
    ) throws -> Bool {
        let token = "accepted-import:" + Identifier.make()
        try index.authorityBeginWalk(token: token)
        defer { try? index.authorityEndWalk(token: token) }
        var stack = [head]
        while let next = stack.popLast() {
            work += 1
            try progress?()
            guard work <= journal.limits.maximumWork,
                UInt64(stack.count) * 256 < journal.limits.maximumStagedBytes
            else {
                throw TractandaError("resourceLimit", "Accepted import-frontier work exhausted.")
            }
            if let previous, try index.authorityControlIsAbsorbed(next, localCut: previous) { continue }
            guard try index.authorityVisitOnce(token: token, id: next.recordID) else { continue }
            var after: String?
            while true {
                let page = try index.authorityControlDeltaPage(next, afterRevisionID: after, limit: 128)
                if page.isEmpty { break }
                for delta in page {
                    after = delta.target.revisionID
                    let state = try index.authorityDisposition(id: delta.target.revisionID)?.disposition
                    // Missing data/identity is not a review decision. Keep this newer head
                    // as private knowledge and select a usable ancestor instead.
                    if state == nil || state == .pending || state == .missingDependencies
                        || state == .unknownOrigin
                    {
                        return false
                    }
                }
            }
            stack.append(contentsOf: try index.authorityControlParents(next))
        }
        return true
    }
    /// Only called while staging a real item/authorization effect. Receipt-only exchange never
    /// invokes this method. Explicit overrides bind original target/actor/policies and control causes.
    func prepareSourceCut(index: ItemIndex, origin: String, actor: String) throws -> SourceCutDraft {
        try index.withCatalogueScanBudget(progress: progress, reusingActiveBudget: true) {
            try prepareSourceCutBody(index: index, origin: origin, actor: actor)
        }
    }
    private func prepareSourceCutBody(index: ItemIndex, origin: String, actor: String) throws
        -> SourceCutDraft
    {
        let previous = try index.authorityControlHead(originID: origin)
        var current = previous
        var records: [AuthorityRecord] = []
        var encoded = 0
        let bootstrap = try configuration()?.bootstrap.map {
            try AuthorityBinding(recordID: $0.recordID, sha256: $0.sha256)
        }
        var afterOrigin: String?
        let walk = "join:" + (try UUID.makeVersion1().uuidString.lowercased())
        try index.authorityBeginWalk(token: walk)
        defer { try? index.authorityEndWalk(token: walk) }
        var work = 0
        func appendJoin(head: AuthorityBinding, deltas: [AuthorityStore.DispositionDelta]) throws {
            let parents = Array(Set([head] + (current.map { [$0] } ?? []))).sorted {
                $0.recordID < $1.recordID
            }
            let record = try makeControl(
                origin: origin, actor: actor, localParent: current,
                parents: parents, deltas: deltas, bootstrap: bootstrap)
            encoded += try AuthorityRecordCodec.encode(record).count
            guard UInt64(encoded) <= journal.limits.maximumStagedBytes else {
                throw TractandaError("resourceLimit", "Pre-cut join byte allowance exhausted.")
            }
            records.append(record)
            current = try recordBinding(record)
        }
        while true {
            let heads = try index.authorityControlHeadPage(afterOriginID: afterOrigin, limit: 128)
            if heads.isEmpty { break }
            for head in heads {
                let original = try control(head, index: index)
                afterOrigin = original.record.originReplicaID
                if original.record.originReplicaID == origin { continue }
                if let previous, try index.authorityControlIsAbsorbed(head, localCut: previous) { continue }
                var candidates = [head]
                while let head = candidates.popLast() {
                    if let previous, try index.authorityControlIsAbsorbed(head, localCut: previous) {
                        continue
                    }
                    if try !acceptedImportContext(head, previous: previous, index: index, work: &work) {
                        candidates.append(contentsOf: try index.authorityControlParents(head))
                        guard UInt64(candidates.count) * 256 <= journal.limits.maximumStagedBytes else {
                            throw TractandaError(
                                "resourceLimit", "Accepted import candidates exceed operation allowance.")
                        }
                        continue
                    }
                    var stack = [head]
                    var deltas: [AuthorityStore.DispositionDelta] = []
                    while let next = stack.popLast() {
                        try progress?()
                        work += 1
                        guard work <= journal.limits.maximumWork,
                            UInt64(stack.count) * 256 < journal.limits.maximumStagedBytes
                        else {
                            throw TractandaError(
                                "resourceLimit", "Imported control walk allowance exhausted.")
                        }
                        if let previous, try index.authorityControlIsAbsorbed(next, localCut: previous) {
                            continue
                        }
                        guard try index.authorityVisitOnce(token: walk, id: next.recordID) else { continue }
                        var cursor: String?
                        while true {
                            let page = try index.authorityControlDeltaPage(
                                next, afterRevisionID: cursor, limit: 128)
                            if page.isEmpty { break }
                            for old in page {
                                cursor = old.target.revisionID
                                guard try index.authorityVisitOnce(token: walk, id: old.target.revisionID)
                                else {
                                    continue
                                }
                                guard
                                    let retained = try index.retainedAuthorityObject(
                                        id: old.target.revisionID),
                                    retained.descriptor.sha256 == old.target.sha256
                                else {
                                    throw TractandaError(
                                        "missingDependencies", "Join target original is absent.")
                                }
                                let eligible =
                                    try index.authorityDisposition(id: old.target.revisionID)?.disposition
                                    == .eligible
                                deltas.append(
                                    .init(
                                        target: old.target, eligible: eligible, actor: old.actor,
                                        policyIDs: old.policyIDs,
                                        causes: Array(Set([head] + (previous.map { [$0] } ?? []))).sorted {
                                            $0.recordID < $1.recordID
                                        }, evidence: old.evidence))
                                if deltas.count == 128 {
                                    try appendJoin(head: head, deltas: deltas)
                                    deltas.removeAll(keepingCapacity: true)
                                }
                            }
                        }
                        stack.append(contentsOf: try index.authorityControlParents(next))
                    }
                    if !deltas.isEmpty || current == previous { try appendJoin(head: head, deltas: deltas) }
                }
            }
        }
        var pendingAfter: String?
        while true {
            let page = try index.authorityDispositionEffectPage(afterRevisionID: pendingAfter, limit: 128)
            if page.isEmpty { break }
            pendingAfter = page.last!.target.revisionID
            let parents = Array(Set((current.map { [$0] } ?? []) + page.flatMap(\.causes))).sorted {
                $0.recordID < $1.recordID
            }
            guard parents.count <= 256 else {
                throw TractandaError("resourceLimit", "Disposition join needs smaller cause pages.")
            }
            let record = try makeControl(
                origin: origin, actor: actor, localParent: current,
                parents: parents, deltas: page, bootstrap: bootstrap)
            encoded += try AuthorityRecordCodec.encode(record).count
            guard UInt64(encoded) <= journal.limits.maximumStagedBytes else {
                throw TractandaError("resourceLimit", "Disposition join byte allowance exhausted.")
            }
            records.append(record)
            current = try recordBinding(record)
        }
        if current == nil, let bootstrap {
            let genesis = try makeControl(
                origin: origin, actor: actor, localParent: nil, parents: [],
                deltas: [], bootstrap: bootstrap)
            records.append(genesis)
            current = try recordBinding(genesis)
        }
        return .init(cut: current, records: records)
    }
    func localControlRecords(
        revision: Revision, bytes: Data, evidence: AuthorityRecord?, draft: SourceCutDraft,
        origin: String, actor: String, causeKey: String? = nil
    ) throws -> [AuthorityRecord] {
        let policies =
            try evidence.map { witness in
                try
                    (AuthorityRecord.list(witness.payload["admissionPolicies"])
                    + AuthorityRecord.list(witness.payload["itemPolicies"]))
                    .map { try AuthorityRecord.binding($0).revisionID }
            } ?? []
        let delta = AuthorityStore.DispositionDelta(
            target: try .init(
                itemID: revision.itemID,
                revisionID: revision.revisionID, sha256: AuthorityRecordCodec.sha256(bytes)), eligible: true,
            actor: revision.fields["actor"]!.string!, policyIDs: Array(Set(policies)).sorted(),
            evidence: try evidence.map(recordBinding))
        let bootstrap = try configuration()?.bootstrap.map {
            try AuthorityBinding(recordID: $0.recordID, sha256: $0.sha256)
        }
        let commit = try makeControl(
            origin: origin, actor: actor, localParent: draft.cut,
            parents: draft.cut.map { [$0] } ?? [], deltas: [delta], bootstrap: bootstrap)
        let cut = try recordBinding(commit)
        let visibility = try AuthorityRecord(
            recordID: UUID.makeVersion1().uuidString.lowercased(), storeID: storeID,
            originReplicaID: origin, kind: .visibilityWitness, parentAuthorityIDs: [cut.recordID],
            actorPrincipal: actor,
            createdAt: Timestamp.now(),
            payload: [
                "target": delta.target.itemValue, "cut": cut.itemValue,
                "modifiedAt": .date(revision.modifiedAt),
                "causeKey": .list(causeKey.map { [.text($0)] } ?? []),
            ])
        return draft.records + [commit, visibility]
    }
}

extension PeerIntakeCoordinator {
    /// Hierarchical local bundle framing; only newly authored bounded control objects are held
    /// in this operation's array, never a collection of existing history snapshots.
    func stageObjects(
        _ values: [(PeerPackage.Object, Data)], context: PeerPackage.Context,
        packageID: String, reservedPageID: String? = nil
    ) throws -> PeerPackage.Manifest {
        if let reservedPageID {
            _ = try AuthorityRecord.persistentID(.text(reservedPageID))
            guard values.count <= 256 else {
                throw TractandaError("resourceLimit", "Reserved local framing requires a single bounded page.")
            }
        }
        var objects = values
        var level: [PeerPackage.Object] = []
        // A reserved small local unit must retry with the same manifest identity after
        // begin/chunk/prepare failures. Transport packages already supply fixed page IDs.
        let oldBegin = try journal.files.readIfPresent(
            path: ["authority", "intake", packageID, "begin.json"], maximumBytes: PeerPackage.maximumPageBytes
        )
        .map { try PeerPackage.decode(PeerIntakeJournal.Begin.self, $0) }
        func page(_ value: PeerPackage.Page) throws -> PeerPackage.Object {
            let data = try JSON.encode(value)
            let pageID =
                try values.count <= 256
                ? reservedPageID ?? oldBegin?.manifest.root.id ?? UUID.makeVersion1().uuidString.lowercased()
                : UUID.makeVersion1().uuidString.lowercased()
            let result = PeerPackage.Object(
                kind: .index, id: pageID,
                length: data.count, sha256: AuthorityRecordCodec.sha256(data))
            objects.append((result, data))
            return result
        }
        for start in stride(from: 0, to: values.count, by: 256) {
            level.append(
                try page(
                    .init(
                        objects: Array(values[start..<min(start + 256, values.count)]).map(\.0), children: [])
                ))
        }
        while level.count > 1 {
            var next: [PeerPackage.Object] = []
            for start in stride(from: 0, to: level.count, by: 256) {
                next.append(
                    try page(
                        .init(objects: [], children: Array(level[start..<min(start + 256, level.count)]))))
            }
            level = next
        }
        guard let root = level.first else {
            throw TractandaError("invalidPeerPackage", "Empty local control unit.")
        }
        if let oldBegin {
            guard context.peerID == "local", oldBegin.context == context,
                oldBegin.manifest.packageID == packageID,
                oldBegin.manifest.storeID == storeID, oldBegin.manifest.root == root
            else {
                throw TractandaError("invalidPeerPackage", "Reserved local metadata continuation changed.")
            }
        }
        let manifest = PeerPackage.Manifest(
            packageID: packageID, storeID: storeID, root: root,
            profile: oldBegin?.manifest.profile ?? PeerPackage.profile)
        _ = try journal.begin(
            context: context, manifestBytes: JSON.encode(manifest), retainedLocal: oldBegin != nil)
        for (descriptor, data) in objects {
            for offset in stride(from: 0, to: data.count, by: PeerPackage.maximumChunkBytes) {
                _ = try journal.append(
                    context: context, packageID: packageID, object: descriptor, offset: offset,
                    bytes: Data(data[offset..<min(data.count, offset + PeerPackage.maximumChunkBytes)]),
                    retainedLocal: oldBegin != nil)
            }
        }
        return manifest
    }
}

extension PeerIntakeCoordinator {
    struct InvalidationOutcome {
        var denied = false
        var preserved = false
        var causes: [AuthorityBinding] = []
    }
    func admissionAllows(_ configuration: AccessConfiguration, evidence: AuthorityRecord) throws -> Bool {
        let name = configuration.userAliases[evidence.actorPrincipal] ?? evidence.actorPrincipal
        let groups = Set(evidence.payload["groups"]!.map!.keys.map { configuration.groupAliases[$0] ?? $0 })
        if try SourceAdministration.administrator(configuration, evidence: evidence) { return true }
        return configuration.users.contains { (configuration.userAliases[$0] ?? $0) == name }
            || configuration.groups.contains { groups.contains(configuration.groupAliases[$0] ?? $0) }
    }
    func policyContextAllows(
        _ configuration: AccessConfiguration, evidence: AuthorityRecord,
        index: ItemIndex
    ) throws -> Bool {
        guard try admissionAllows(configuration, evidence: evidence) else { return false }
        var aliases: [String: ItemValue] = [:]
        for (name, value) in configuration.userAliases.merging(
            configuration.groupAliases,
            uniquingKeysWith: { $0 == $1 ? $0 : "" })
        {
            guard !value.isEmpty else { return false }
            aliases[name] = .text(value)
        }
        let frozen = evidence.payload["aliases"]!.map!
        let groups = Set(evidence.payload["groups"]!.map!.keys)
        // Service-owner testimony is a source role, never a receiver UID/GID grant.
        let sourceAdmin = try SourceAdministration.administrator(configuration, evidence: evidence)
        if sourceAdmin { return true }
        for value in try AuthorityRecord.list(evidence.payload["itemPolicies"]) {
            let target = try AuthorityRecord.binding(value)
            guard let row = try index.retainedAuthorityObject(id: target.revisionID),
                row.descriptor.sha256 == target.sha256
            else { throw TractandaError("missingDependencies", "Exact policy context is missing.") }
            let revision = try AuthorityRevision(originalBytes: bytes(row)).revision
            guard let permission = revision.fields["permissions"],
                try RuntimeAuthorityEvaluator.sourceAllows(
                    ItemPermissions(permission), principal: evidence.actorPrincipal,
                    groups: groups, aliases: aliases, identityAliases: frozen)
            else { return false }
        }
        return true
    }
    /// Every relevant validated transition is consulted, including a revocation hidden by a
    /// later grant. A different policy UUID alone does not establish a loss of authority.
    func invalidationOutcome(
        _ node: AuthorityRevision, evidence: AuthorityRecord,
        contextHeads: [AuthorityBinding]? = nil, index: ItemIndex
    ) throws -> InvalidationOutcome {
        var outcome = InvalidationOutcome()
        let policies =
            try AuthorityRecord.list(evidence.payload["admissionPolicies"])
            + AuthorityRecord.list(evidence.payload["itemPolicies"])
        let items = try Set(policies.map { try AuthorityRecord.binding($0).itemID })
        for item in items.sorted() {
            var cursor: (controlID: String, previousPolicyID: String)?
            while true {
                let page = try index.authorityInvalidationPage(
                    policyItemID: item, after: cursor, limit: 128)
                if page.isEmpty { break }
                for transition in page {
                    cursor = (transition.control.recordID, transition.previousPolicyID)
                    // A policy author and the exact named B/C accepted in this SAME
                    // fully applied atomic review are not stale offline recipients of
                    // their own transition. No descendant or later control is covered.
                    if transition.policy.revisionID == node.revision.revisionID
                        && transition.policy.sha256 == node.sha256
                    {
                        continue
                    }
                    if try index.authorityReviewControlAllows(
                        control: transition.control, revisionID: node.revision.revisionID)
                    {
                        continue
                    }
                    if contextHeads == nil,
                        try index.authorityDisposition(id: transition.policy.revisionID)?.disposition
                            != .eligible
                    {
                        continue
                    }
                    if let frozen = try sourceControl(evidence),
                        try index.authorityControlContains(transition.control, in: frozen)
                    {
                        // This is a new intent after the transition. Its exact source frontier
                        // and source rights were independently validated, including any later grant.
                        continue
                    }

                    if let heads = contextHeads {
                        var relevant = false
                        for head in heads
                        where try index.authorityControlContains(transition.control, in: head) {
                            relevant = true
                            break
                        }
                        if !relevant { continue }
                    }
                    guard let oldRow = try index.retainedAuthorityObject(id: transition.previousPolicyID),
                        let newRow = try index.retainedAuthorityObject(id: transition.policy.revisionID),
                        newRow.descriptor.sha256 == transition.policy.sha256
                    else {
                        throw TractandaError(
                            "missingDependencies", "Validated policy transition original is missing.")
                    }
                    let old = try AuthorityRevision(originalBytes: bytes(oldRow)).revision
                    let new = try AuthorityRevision(originalBytes: bytes(newRow)).revision
                    let wasAllowed: Bool
                    let nowAllowed: Bool
                    if new.classID == AccessConfiguration.classID {
                        wasAllowed = try policyContextAllows(
                            AccessConfiguration(old.fields["accessConfiguration"]!), evidence: evidence,
                            index: index)
                        nowAllowed = try policyContextAllows(
                            AccessConfiguration(new.fields["accessConfiguration"]!), evidence: evidence,
                            index: index)
                    } else {
                        let groups = Set(evidence.payload["groups"]!.map!.keys)
                        // Absence is an exact admin-only policy, never an inherited ACL.
                        wasAllowed =
                            try old.fields["permissions"].map {
                                try RuntimeAuthorityEvaluator.sourceAllows(
                                    ItemPermissions($0), principal: evidence.actorPrincipal,
                                    groups: groups, aliases: evidence.payload["aliases"]!.map!)
                            } ?? false
                        nowAllowed =
                            try new.fields["permissions"].map {
                                try RuntimeAuthorityEvaluator.sourceAllows(
                                    ItemPermissions($0), principal: evidence.actorPrincipal,
                                    groups: groups, aliases: evidence.payload["aliases"]!.map!)
                            } ?? false
                    }
                    if wasAllowed && !nowAllowed {
                        outcome.causes.append(transition.control)
                        if try index.eligibilityAtCut(
                            revisionID: node.revision.revisionID, cut: transition.sourceCut) == .eligible
                        {
                            outcome.preserved = true
                        } else {
                            outcome.denied = true
                        }
                    }
                }
            }
        }
        outcome.causes = Array(Set(outcome.causes)).sorted { $0.recordID < $1.recordID }
        if outcome.denied,
            try index.authorityReviewApprovalCovers(
                revisionID: node.revision.revisionID, causes: outcome.causes)
        {
            outcome.denied = false
            outcome.preserved = true
        }
        return outcome
    }
}

extension PeerIntakeCoordinator {
    private func verifiedExposurePlanForExport(_ ref: AuthorityBinding, index: ItemIndex) throws
        -> AuthorityStore.VerifiedExposurePlan
    {
        try .init(witness: control(ref, index: index))
    }
    func exportControlClosure(revisionID: String, index: ItemIndex) throws -> [(PeerPackage.Object, Data)] {
        let token = "export:" + (try UUID.makeVersion1().uuidString.lowercased())
        try index.authorityBeginWalk(token: token)
        defer { try? index.authorityEndWalk(token: token) }
        var pending = [revisionID]
        var result: [(PeerPackage.Object, Data)] = []
        var total: UInt64 = 0
        var work = 0
        while let id = pending.popLast() {
            try progress?()
            work += 1
            guard work <= journal.limits.maximumWork,
                UInt64(pending.count) * 256 <= journal.limits.maximumStagedBytes
            else {
                throw TractandaError(
                    "resourceLimit", "Control export work allowance exhausted; use streamed packages.")
            }
            guard try index.authorityVisitOnce(token: token, id: id) else { continue }
            guard let row = try index.retainedAuthorityObject(id: id) else {
                throw TractandaError("missingDependencies", "Control export original is absent.")
            }
            guard
                UInt64(row.descriptor.length) <= journal.limits.maximumReadBytes
                    - min(total, journal.limits.maximumReadBytes)
            else {
                throw TractandaError(
                    "resourceLimit", "Control export byte allowance exhausted; use streamed packages.")
            }
            let data = try bytes(row)
            total += UInt64(data.count)
            result.append((row.descriptor, data))
            if row.descriptor.kind == .item {
                let node = try AuthorityRevision(originalBytes: data)
                if let evidence = try index.authorityEvidence(revisionID: id) {
                    pending.append(evidence.descriptor.id)
                } else {
                    var after: String?
                    while true {
                        let page = try index.authorityEvidenceCandidates(
                            revisionID: id, after: after, limit: 128)
                        if page.isEmpty { break }
                        for candidate in page {
                            after = candidate.descriptor.id
                            pending.append(candidate.descriptor.id)
                        }
                    }
                }
                if let control = try index.authorityAcceptanceControl(revisionID: id) {
                    pending.append(control.recordID)
                }
                if let exposure = try index.authorityExposure(revisionID: id) {
                    pending.append(exposure.witness.recordID)
                }
                if let witness = try node.revision.provenance?.authorityWitness {
                    pending.append(witness.recordID)
                }
            } else if row.descriptor.kind == .authority {
                let record = try AuthorityRecordCodec.decode(data).record
                pending.append(contentsOf: record.parentAuthorityIDs)
                if record.kind == .controlCommit {
                    let plan = try AuthorityStore.VerifiedControlPlan(
                        control: AuthorityRecordCodec.decode(data))
                    // Target bytes are separately resumable dependencies; ordinary export does not copy prior history.
                    if let bootstrap = plan.bootstrap { pending.append(bootstrap.recordID) }
                    pending.append(contentsOf: plan.deltas.compactMap { $0.evidence?.recordID })
                } else if record.kind == .authoredEvidence {
                    for value in try AuthorityRecord.list(record.payload["admissionPolicies"])
                        + AuthorityRecord.list(record.payload["itemPolicies"])
                    {
                        _ = try AuthorityRecord.binding(value)  // dependency is fetched explicitly if absent
                    }
                } else if record.kind == .visibilityWitness {
                    // An exposure alone never imports its target as accepted history.
                } else if record.kind == .reconciliationWitness {
                    let plan = try AuthorityStore.VerifiedReconciliationPlan(
                        witness: AuthorityRecordCodec.decode(data))
                    for ref in plan.exposures {
                        let exposure = try verifiedExposurePlanForExport(ref, index: index)
                        pending.append(exposure.target.revisionID)
                    }
                } else if record.kind == .bootstrap || record.kind == .bootstrapIndex {
                    // Bootstrap parents are already exact page/index references.
                }
            }
        }
        return result.sorted { a, b in
            if a.0.id == revisionID { return true }
            if b.0.id == revisionID { return false }
            return a.0.id < b.0.id
        }
    }
}

extension PeerIntakeCoordinator {
    func hasLocalPublicationReceipt(objectID: String, origin: String, index: ItemIndex) throws -> Bool {
        let local = try context(peerID: "local")
        guard local.permittedOrigins == [origin] else { return false }
        var after: String?
        while true {
            let rows = try index.authorityObjectReceiptPage(
                objectID: objectID, afterPackageID: after, limit: 128)
            if rows.isEmpty { return false }
            for row in rows {
                after = row.packageID
                guard row.peerID == "local", row.permittedOrigin,
                    row.configurationDigest == local.configurationDigest,
                    let publication = try journal.publication(row.packageID), publication.context == local
                else { continue }
                return true
            }
        }
    }
}

extension PeerIntakeCoordinator {
    func stageControlUnit(_ records: [AuthorityRecord], contextToken: String) throws -> String {
        let context = try context(peerID: "local")
        let packageID = try UUID.makeVersion1().uuidString.lowercased()
        let objects = try records.map { record -> (PeerPackage.Object, Data) in
            let data = try AuthorityRecordCodec.encode(record)
            return (
                .init(
                    kind: .authority, id: record.recordID, length: data.count,
                    sha256: AuthorityRecordCodec.sha256(data)), data
            )
        }
        let manifest = try stageObjects(objects, context: context, packageID: packageID)
        let stamp = try RevisionTimestamp(Timestamp.now()).formatted()
        let minute = String(stamp.prefix(16)).replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: "T", with: "/").replacingOccurrences(of: ":", with: "/")
        try journal.prepare(
            .init(
                packageID: packageID,
                manifestDigest: AuthorityRecordCodec.sha256(JSON.encode(manifest)), context: context,
                contextToken: contextToken, arrivalMinute: minute))
        try CanonicalReaderRequirement.beforeControlPublication(root: root, ownerUID: ownerUID)
        try StoreCheckpoint.markDirty(root: root)
        try journal.seal(packageID)
        return packageID
    }
}
