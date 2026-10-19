import Foundation

/// Bounded reference reducer only. It neither publishes records nor changes current policy.
enum AuthorityEligibility {
    enum Verdict: Equatable, Sendable { case allowed, denied, unknown }
    struct Evaluation: Sendable {
        let source: Verdict
        let current: Verdict
        /// All known canonical revocations invalidating the original claim, even if a
        /// later grant makes current rights allowed. The evaluator verifies policy meaning.
        let invalidatingRevocations: [String]
    }
    enum Disposition: Equatable, Sendable {
        case eligible, approved, rejected, reviewRequired, unknownAuthority, missingDependencies
    }
    struct Attested: Sendable {
        let authority: AuthorityRecordCodec.Verified
        let peer: TrustedAuthorityPeer
    }
    struct PinnedInitialBootstrap: Sendable {
        fileprivate let authority: AuthorityRecordCodec.Verified
        fileprivate init(_ authority: AuthorityRecordCodec.Verified) { self.authority = authority }
    }
    /// A one-time explicit baseline choice under fresh source/current canonical admin
    /// contexts. The returned binding is reusable; later OS membership is not migration.
    static func pinInitialBootstrap(
        _ manifest: AuthorityRecordCodec.Verified, peer: TrustedAuthorityPeer,
        administrator: (AuthorityRecord) throws -> Evaluation
    ) throws -> PinnedInitialBootstrap? {
        guard manifest.record.kind == .bootstrap else {
            throw TractandaError("invalidAuthority", "Initial pin requires a bootstrap manifest.")
        }
        guard peer.permits(manifest.record) else { return nil }
        let evaluation = try administrator(manifest.record)
        guard evaluation.source == .allowed, evaluation.current == .allowed,
            evaluation.invalidatingRevocations.isEmpty
        else { return nil }
        return .init(manifest)
    }
    struct Limits: Sendable {
        var maximumRevisions = 256
        var maximumRecords = 512
        var maximumBytes = 16 * 1024 * 1024
        var maximumWork = 1_000_000
    }
    /// Fresh injected evaluators operate across canonical witness contexts, not an
    /// intersection of every host's OS group database. Unknown differs from proven denial.
    static func reduce(
        revisions: [AuthorityRevision], records: [Attested], limits: Limits = .init(),
        initialBootstrap: PinnedInitialBootstrap? = nil,
        progress: (() throws -> Void)? = nil,
        evaluate: (AuthorityRevision, AuthorityRecord?) throws -> Evaluation,
        currentAdministrator: (AuthorityRecord) throws -> Evaluation
    ) throws -> [String: Disposition] {
        try progress?()
        var state = try State(revisions: revisions, records: records, limits: limits, progress: progress)
        return try state.reduce(
            initialBootstrap: initialBootstrap, evaluate: evaluate, administrator: currentAdministrator)
    }

    private struct State {
        var revisions: [String: AuthorityRevision] = [:]
        var records: [String: AuthorityRecordCodec.Verified] = [:]
        var trusted: Set<String> = []
        var edges: [String: [String]] = [:]
        var evidence: [String: String] = [:]
        var work: Int
        let limits: Limits
        let progress: (() throws -> Void)?
        init(
            revisions input: [AuthorityRevision], records attested: [Attested], limits: Limits,
            progress: (() throws -> Void)?
        ) throws {
            guard limits.maximumRevisions > 0, limits.maximumRecords > 0, limits.maximumBytes > 0,
                limits.maximumRevisions <= 4096, limits.maximumRecords <= 8192,
                limits.maximumBytes <= 256 * 1024 * 1024,
                limits.maximumWork > 0, input.count <= limits.maximumRevisions,
                attested.count <= limits.maximumRecords
            else { throw Self.resource() }
            self.limits = limits
            self.progress = progress
            work = limits.maximumWork
            var bytes = 0
            for node in input {
                guard node.originalBytes.count <= limits.maximumBytes - bytes else { throw Self.resource() }
                bytes += node.originalBytes.count
                let id = node.revision.revisionID
                if let old = revisions[id], old.originalBytes != node.originalBytes {
                    throw Self.invalid("Revision identity collision.")
                }
                revisions[id] = node
                edges[id] = node.parents
            }
            var storeID: String?
            for entry in attested {
                let node = entry.authority
                guard node.originalBytes.count <= limits.maximumBytes - bytes else { throw Self.resource() }
                bytes += node.originalBytes.count
                let record = node.record
                guard storeID == nil || storeID == record.storeID else {
                    throw Self.invalid("Mixed logical stores.")
                }
                storeID = record.storeID
                guard revisions[record.recordID] == nil else {
                    throw Self.invalid("Authority/revision identity collision.")
                }
                if let old = records[record.recordID], old.originalBytes != node.originalBytes {
                    throw Self.invalid("Authority identity collision.")
                }
                records[record.recordID] = node
                edges[record.recordID] = record.parentAuthorityIDs
                if entry.peer.permits(record) { trusted.insert(record.recordID) }
            }
            for node in records.values {
                let record = node.record
                let bindingFields: [String]
                switch record.kind {
                case .authoredEvidence: bindingFields = ["itemPolicies", "admissionPolicies"]
                case .bootstrap: bindingFields = ["administrationPolicies"]
                case .bootstrapPage: bindingFields = ["entries"]
                case .bootstrapIndex: bindingFields = []
                case .enrollmentApproval, .controlCommit, .visibilityWitness, .reconciliationWitness, .originRetirement,
                    .originRetirementPage:
                    throw Self.invalid("Causal control semantics require the disk authority engine.")
                case .reviewHold: bindingFields = ["revocations"]
                case .reviewDecision: bindingFields = ["administrationPolicies", "itemPolicies"]
                }
                for field in bindingFields {
                    for binding in try AuthorityRecord.list(record.payload[field]) {
                        let value = record.kind == .bootstrapPage ? binding.map!["target"]! : binding
                        let policy = try AuthorityRecord.binding(value)
                        if revisions[policy.revisionID] != nil { try requireBinding(value) }
                        edges[record.recordID, default: []].append(policy.revisionID)
                    }
                }
                for parent in record.parentAuthorityIDs where revisions[parent] != nil {
                    throw Self.invalid("Authority parents must reference authority records.")
                }
                if record.kind == .reviewHold || record.kind == .reviewDecision {
                    let target = try AuthorityRecord.binding(record.payload["target"])
                    if revisions[target.revisionID] != nil { try requireBinding(record.payload["target"]) }
                    edges[record.recordID, default: []].append(target.revisionID)
                }
            }
            for node in records.values where node.record.kind == .authoredEvidence {
                let record = node.record
                let target = try AuthorityRecord.binding(record.payload["target"])
                guard let revision = revisions[target.revisionID] else { continue }
                try requireBinding(record.payload["target"])
                guard trusted.contains(record.recordID),
                    record.originReplicaID == (try revision.revision.provenance?.originReplicaID)
                else { continue }
                guard evidence[target.revisionID] == nil || evidence[target.revisionID] == record.recordID
                else {
                    throw Self.invalid("Competing evidence for one authored event.")
                }
                guard try AuthorityRecord.ids(record.payload["parents"], maximum: 1024) == revision.parents,
                    let provenance = try revision.revision.provenance, provenance.kind != .automaticMerge,
                    let intent = record.payload["intent"]?.map,
                    intent["writtenFields"] == .list(provenance.writtenFields.map(ItemValue.text)),
                    intent["unsetFields"] == .list(provenance.unsetFields.map(ItemValue.text)),
                    record.actorPrincipal == record.payload["principal"]?.string,
                    revision.revision.fields["actor"]?.string == "user:" + record.actorPrincipal
                        || revision.revision.fields["actor"]?.string
                            == "uid:" + String(record.payload["sourceUID"]!.integerValue!)
                else { throw Self.invalid("Evidence differs from original authenticated intent.") }
                evidence[target.revisionID] = record.recordID
                edges[target.revisionID, default: []].append(record.recordID)
                for ref in try AuthorityRecord.list(record.payload["acceptedAuthority"]) {
                    let fields = ref.map!
                    let id = fields["recordID"]!.string!
                    guard record.parentAuthorityIDs.contains(id) else {
                        throw Self.invalid("Accepted authority omitted its causal parent.")
                    }
                    if let previous = records[id] {
                        guard previous.sha256 == fields["sha256"]?.string,
                            previous.record.kind == .reviewDecision
                        else { throw Self.invalid("Accepted review authority binding mismatch.") }
                    }
                }
            }
            try rejectCycles()
            for group in Dictionary(grouping: revisions.values, by: { $0.revision.itemID }).values {
                if group.allSatisfy({ $0.parents.allSatisfy { revisions[$0] != nil } }) {
                    let nodes = try group.map { node in
                        try RevisionMerge.node(
                            node.revision, parent: node.parents.first.flatMap { revisions[$0]?.revision })
                    }
                    // The reference graph has its own guard; precharge this operation
                    // before invoking it, rather than hiding independent phase work.
                    try charge(group.reduce(0) { $0 + $1.originalBytes.count + $1.parents.count + 1 })
                    _ = try RevisionGraph(
                        nodes: nodes,
                        limits: .init(
                            maximumNodes: limits.maximumRevisions, maximumEdges: limits.maximumRecords * 256,
                            maximumEncodedBytes: limits.maximumBytes, maximumWork: work))
                }
            }
            for (id, evidenceID) in evidence where try completeDependencies(id) {
                let node = revisions[id]!
                let provenance = try node.revision.provenance!
                let frontier: [String]
                if provenance.kind == .resolution {
                    frontier = provenance.frontier
                } else if let parent = node.parents.first, let revision = revisions[parent]?.revision {
                    let ancestry = try revision.provenance
                    frontier = ancestry?.kind == .automaticMerge ? ancestry!.frontier : [parent]
                } else {
                    frontier = []
                }
                guard
                    try AuthorityRecord.ids(records[evidenceID]!.record.payload["frontier"], maximum: 1024)
                        == frontier
                else {
                    throw Self.invalid("Evidence frontier differs from actual authored parent context.")
                }
            }
            for node in records.values where node.record.kind == .reviewHold {
                if try completeDependencies(node.record.recordID) { try validateHoldContext(node.record) }
            }
        }
        mutating func charge(_ amount: Int = 1) throws {
            guard amount >= 0, amount <= work else { throw Self.resource() }
            work -= amount
            if work % 128 == 0 { try progress?() }
        }
        func requireBinding(_ value: ItemValue?) throws {
            let binding = try AuthorityRecord.binding(value)
            guard let node = revisions[binding.revisionID], node.sha256 == binding.sha256,
                node.revision.itemID == binding.itemID
            else { throw Self.invalid("Original revision binding mismatch.") }
        }
        mutating func reachable(_ ancestor: String, from descendant: String) throws -> Bool {
            var pending = [descendant]
            var seen: Set<String> = []
            while let id = pending.popLast() {
                try charge()
                if id == ancestor { return true }
                if seen.insert(id).inserted { pending.append(contentsOf: edges[id] ?? []) }
            }
            return false
        }
        mutating func rejectCycles() throws {
            var complete: Set<String> = []
            var remaining = Set(edges.keys)
            while !remaining.isEmpty {
                var ready: [String] = []
                for id in remaining {
                    try charge()
                    if (edges[id] ?? []).allSatisfy({ edges[$0] == nil || complete.contains($0) }) {
                        ready.append(id)
                    }
                }
                guard !ready.isEmpty else { throw Self.invalid("Cyclic authority/knowledge graph.") }
                complete.formUnion(ready)
                remaining.subtract(ready)
            }
        }
        mutating func completeDependencies(_ id: String) throws -> Bool {
            var pending = [id]
            var seen: Set<String> = []
            while let next = pending.popLast() {
                try charge()
                guard edges[next] != nil else { return false }
                if seen.insert(next).inserted { pending.append(contentsOf: edges[next]!) }
            }
            return true
        }
        mutating func validateHoldContext(_ record: AuthorityRecord) throws {
            let target = try AuthorityRecord.binding(record.payload["target"]).revisionID
            let declared = try AuthorityRecord.ids(record.payload["decisionFrontier"])
            var ancestors: [String] = []
            for node in records.values where node.record.kind == .reviewDecision {
                if try AuthorityRecord.binding(node.record.payload["target"]).revisionID == target,
                    try reachable(node.record.recordID, from: record.recordID)
                {
                    ancestors.append(node.record.recordID)
                }
            }
            var maxima: [String] = []
            for candidate in ancestors {
                var dominated = false
                for other in ancestors where candidate != other {
                    if try reachable(candidate, from: other) {
                        dominated = true
                        break
                    }
                }
                if !dominated { maxima.append(candidate) }
            }
            guard declared == maxima.sorted(), Set(declared).isSubset(of: record.parentAuthorityIDs) else {
                throw Self.invalid("Hold frontier differs from its actual reviewed context.")
            }
        }
        mutating func reduce(
            initialBootstrap: PinnedInitialBootstrap?,
            evaluate: (AuthorityRevision, AuthorityRecord?) throws -> Evaluation,
            administrator: (AuthorityRecord) throws -> Evaluation
        ) throws -> [String: Disposition] {
            var bootstrap: Set<String> = []
            let manifests = records.values.filter {
                $0.record.kind == .bootstrap && trusted.contains($0.record.recordID)
                    && $0.record.recordID == initialBootstrap?.authority.record.recordID
                    && $0.sha256 == initialBootstrap?.authority.sha256
            }
            if let manifest = manifests.first,
                try completeDependencies(manifest.record.recordID)
            {
                var candidate: Set<String> = []
                var visited: Set<String> = []
                if try collectBootstrap(
                    AuthorityRecord.list(manifest.record.payload["pages"]), parent: manifest.record,
                    manifestID: manifest.record.recordID, depth: 0, visited: &visited, candidate: &candidate)
                {
                    bootstrap = candidate
                }
            }
            var result: [String: Disposition] = [:]
            for id in revisions.keys.sorted() {
                try charge()
                guard try completeDependencies(id) else {
                    result[id] = .missingDependencies
                    continue
                }
                let node = revisions[id]!
                if try node.revision.provenance?.kind == .automaticMerge {
                    result[id] = .eligible
                    continue
                }
                let evidenceID = evidence[id]
                let claim = evidenceID.flatMap { records[$0]?.record }
                guard claim != nil || bootstrap.contains(id) else {
                    result[id] = .unknownAuthority
                    continue
                }
                let evaluation = try evaluate(node, claim)
                let revocations = Array(Set(evaluation.invalidatingRevocations)).sorted()
                guard revocations.count <= limits.maximumRevisions else { throw Self.resource() }
                var stale = false
                var missing = false
                for revocation in revocations {
                    guard revisions[revocation] != nil else {
                        missing = true
                        break
                    }
                    if try !reachable(id, from: revocation) { stale = true }
                }
                if missing {
                    result[id] = .missingDependencies
                } else if stale {
                    result[id] = .reviewRequired
                } else if bootstrap.contains(id) {
                    // Explicit initial history needs no retrospective writer lookup;
                    // concurrent invalidating revocations above still demote it.
                    result[id] = .eligible
                } else if evaluation.source == .unknown || evaluation.current == .unknown {
                    result[id] = .unknownAuthority
                } else if (claim != nil && claim?.payload["evaluated"] != .boolean(true))
                    || evaluation.source == .denied
                {
                    result[id] = .reviewRequired
                } else if evaluation.current == .allowed || !revocations.isEmpty {
                    result[id] = .eligible
                } else {
                    result[id] = .reviewRequired
                }
                var activeHolds: [String] = []
                for hold in records.values
                where hold.record.kind == .reviewHold && trusted.contains(hold.record.recordID) {
                    let record = hold.record
                    guard try AuthorityRecord.binding(record.payload["target"]).revisionID == id else {
                        continue
                    }
                    try charge()
                    try requireBinding(record.payload["target"])
                    let ref = record.payload["evidence"]!.map!
                    guard ref["recordID"]?.string == evidenceID,
                        ref["sha256"]?.string == evidenceID.flatMap({ records[$0]?.sha256 }),
                        evidenceID.map({ record.parentAuthorityIDs.contains($0) }) == true
                    else { throw Self.invalid("Review hold evidence mismatch.") }
                    guard try completeDependencies(record.recordID) else {
                        result[id] = .missingDependencies
                        continue
                    }
                    for ref in try AuthorityRecord.list(record.payload["revocations"]) {
                        let revocation = try AuthorityRecord.binding(ref).revisionID
                        guard revocations.contains(revocation), try !reachable(id, from: revocation) else {
                            throw Self.invalid(
                                "Review hold lacks an invalidating concurrent/later authority witness.")
                        }
                    }
                    activeHolds.append(record.recordID)
                    result[id] = .reviewRequired
                }
                if let evidenceID,
                    let reviewed = try decision(
                        for: id, evidenceID: evidenceID, activeHolds: activeHolds,
                        administrator: administrator)
                {
                    if reviewed != .approved
                        || (result[id] != .missingDependencies && result[id] != .unknownAuthority)
                    {
                        result[id] = reviewed
                    }
                }
            }
            // A child cannot route around a missing/rejected/held original parent.
            var changed = true
            while changed {
                changed = false
                for id in revisions.keys.sorted() where result[id] == .eligible || result[id] == .approved {
                    try charge()
                    if revisions[id]!.parents.contains(where: {
                        result[$0] != .eligible && result[$0] != .approved
                    }) {
                        result[id] = .missingDependencies
                        changed = true
                    }
                }
            }
            return result
        }
        mutating func collectBootstrap(
            _ refs: [ItemValue], parent: AuthorityRecord, manifestID: String, depth: Int,
            visited: inout Set<String>, candidate: inout Set<String>
        ) throws -> Bool {
            guard depth <= 64 else { throw Self.resource() }
            for ref in refs {
                try charge()
                let id = try AuthorityRecord.persistentID(ref.map?["recordID"])
                guard let page = records[id], trusted.contains(id),
                    page.sha256 == ref.map?["sha256"]?.string,
                    page.record.payload["manifestID"]?.string == manifestID,
                    parent.parentAuthorityIDs.contains(id)
                else { return false }
                guard visited.insert(id).inserted else { throw Self.invalid("Repeated bootstrap page.") }
                if page.record.kind == .bootstrapIndex {
                    if try !collectBootstrap(
                        AuthorityRecord.list(page.record.payload["children"]),
                        parent: page.record, manifestID: manifestID, depth: depth + 1,
                        visited: &visited, candidate: &candidate)
                    {
                        return false
                    }
                } else if page.record.kind == .bootstrapPage {
                    for binding in try AuthorityRecord.list(page.record.payload["entries"]) {
                        try charge()
                        let entry = try AuthorityRecord.binding(binding.map?["target"])
                        guard let node = revisions[entry.revisionID] else { return false }
                        try requireBinding(binding.map?["target"])
                        let provenance = try node.revision.provenance
                        let frontier =
                            provenance?.kind == .automaticMerge ? provenance!.frontier : [entry.revisionID]
                        guard try AuthorityRecord.ids(binding.map?["frontier"], maximum: 1024) == frontier
                        else {
                            throw Self.invalid("Bootstrap frontier differs from original causal state.")
                        }
                        guard candidate.insert(entry.revisionID).inserted else {
                            throw Self.invalid("Repeated bootstrap entry.")
                        }
                    }
                } else {
                    throw Self.invalid("Unexpected bootstrap child profile.")
                }
            }
            return true
        }
        mutating func decision(
            for id: String, evidenceID: String, activeHolds: [String],
            administrator: (AuthorityRecord) throws -> Evaluation
        ) throws -> Disposition? {
            let relevant = try records.values.filter { node in
                try node.record.kind == .reviewDecision
                    && AuthorityRecord.binding(node.record.payload["target"]).revisionID == id
            }
            var candidates: [String] = []
            var readyDecisions: Set<String> = []
            for node in relevant {
                try charge()
                let record = node.record
                try requireBinding(record.payload["target"])
                let ref = record.payload["evidence"]!.map!
                guard ref["recordID"]?.string == evidenceID,
                    ref["sha256"]?.string == records[evidenceID]?.sha256
                else {
                    throw Self.invalid("Review decision evidence mismatch.")
                }
                guard trusted.contains(record.recordID) else { continue }
                candidates.append(record.recordID)
                guard try completeDependencies(record.recordID),
                    record.parentAuthorityIDs.contains(evidenceID)
                else {
                    continue
                }
                let frontier = try AuthorityRecord.ids(record.payload["decisionFrontier"])
                for parent in frontier {
                    guard record.parentAuthorityIDs.contains(parent), let previous = records[parent],
                        previous.record.kind == .reviewDecision,
                        try AuthorityRecord.binding(previous.record.payload["target"]).revisionID == id
                    else { throw Self.invalid("Review omitted its declared context.") }
                }
                for hold in try AuthorityRecord.ids(record.payload["holds"]) {
                    guard record.parentAuthorityIDs.contains(hold), let previous = records[hold],
                        previous.record.kind == .reviewHold,
                        try AuthorityRecord.binding(previous.record.payload["target"]).revisionID == id
                    else { throw Self.invalid("Review hold binding mismatch.") }
                }
                // Completeness is relative to this decision's actual parent context,
                // never all globally known heads (unknown concurrent decisions remain valid).
                var ancestors: [String] = []
                for previous in relevant where previous.record.recordID != record.recordID {
                    if try reachable(previous.record.recordID, from: record.recordID) {
                        ancestors.append(previous.record.recordID)
                    }
                }
                var maxima: [String] = []
                for ancestor in ancestors {
                    var dominated = false
                    for other in ancestors where other != ancestor {
                        if try reachable(ancestor, from: other) {
                            dominated = true
                            break
                        }
                    }
                    if !dominated { maxima.append(ancestor) }
                }
                guard frontier == maxima.sorted() else {
                    throw Self.invalid("Review frontier omits actual parent decisions.")
                }
                var context: [String] = []
                for event in records.values where event.record.recordID != record.recordID {
                    if event.record.kind == .reviewHold || event.record.kind == .reviewDecision,
                        try AuthorityRecord.binding(event.record.payload["target"]).revisionID == id,
                        try reachable(event.record.recordID, from: record.recordID)
                    {
                        context.append(event.record.recordID)
                    }
                }
                var heldContext: [String] = []
                for event in context where records[event]!.record.kind == .reviewHold {
                    var consumed = false
                    for other in context where event != other {
                        if try reachable(event, from: other) {
                            consumed = true
                            break
                        }
                    }
                    if !consumed { heldContext.append(event) }
                }
                guard try AuthorityRecord.ids(record.payload["holds"]) == heldContext.sorted() else {
                    throw Self.invalid("Review omitted its actual current held context.")
                }
                readyDecisions.insert(record.recordID)
            }
            var maximal: [String] = []
            let events = candidates + activeHolds
            for candidate in events {
                var dominated = false
                for other in events where other != candidate {
                    if try reachable(candidate, from: other) {
                        dominated = true
                        break
                    }
                }
                if !dominated { maximal.append(candidate) }
            }
            // A later hold must be consumed by a new authorized decision. An older
            // approval is not reconsidered simply because its original bytes remain.
            if maximal.contains(where: { records[$0]!.record.kind == .reviewHold }) { return .reviewRequired }
            guard let chosen = maximal.first else { return nil }
            for id in maximal {
                guard readyDecisions.contains(id), try completeDependencies(id),
                    try administratorVerdict(records[id]!.record, evaluate: administrator) == .allowed
                else { return .unknownAuthority }
            }
            let decisions = Set(maximal.map { records[$0]!.record.payload["decision"]!.string! })
            guard decisions.count == 1 else { return .reviewRequired }
            return records[chosen]!.record.payload["decision"]?.string == "accept" ? .approved : .rejected
        }
        mutating func administratorVerdict(
            _ record: AuthorityRecord, evaluate: (AuthorityRecord) throws -> Evaluation
        ) throws -> Verdict {
            let context = try evaluate(record)
            guard context.source == .allowed else { return context.source }
            let revocations = Array(Set(context.invalidatingRevocations)).sorted()
            guard revocations.count <= limits.maximumRevisions else { throw Self.resource() }
            for revocation in revocations {
                guard revisions[revocation] != nil, try completeDependencies(revocation) else {
                    return .unknown
                }
                guard try reachable(record.recordID, from: revocation) else { return .denied }
                guard let evidenceID = evidence[revocation], let witness = records[evidenceID],
                    witness.record.payload["evaluated"] == .boolean(true),
                    try AuthorityRecord.list(witness.record.payload["acceptedAuthority"]).contains(where: {
                        $0.map?["recordID"]?.string == record.recordID
                            && $0.map?["sha256"]?.string == records[record.recordID]?.sha256
                    })
                else { return .unknown }
            }
            // Known canonical revocation observes this already accepted decision. No
            // current OS-group lookup retroactively erases that causal history.
            if !revocations.isEmpty { return .allowed }
            return context.current
        }
        static func invalid(_ message: String) -> TractandaError { .init("invalidAuthority", message) }
        static func resource() -> TractandaError {
            .init("resourceLimit", "Pure authority work/byte/count window exceeded.")
        }
    }
}
