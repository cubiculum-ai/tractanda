import Foundation

/// Bounded, single-item graph analysis. It grants neither author nor importer authority.
struct RevisionGraph {
    struct Node: Equatable, Sendable {
        let revision: Revision
        let parents: [String]
        let kind: RevisionAncestry.Kind

    }

    struct Limits: Sendable {
        let maximumNodes: Int
        let maximumEdges: Int
        let maximumEncodedBytes: Int
        let maximumWork: Int

        init(
            maximumNodes: Int = 256, maximumEdges: Int = 1024,
            maximumEncodedBytes: Int = 8 * 1024 * 1024, maximumWork: Int = 1_000_000
        ) {
            self.maximumNodes = maximumNodes
            self.maximumEdges = maximumEdges
            self.maximumEncodedBytes = maximumEncodedBytes
            self.maximumWork = maximumWork
        }
    }

    private let nodes: [String: Node]
    private let physicalHeads: [String]
    private let result: RevisionMerge.Analysis
    private let profile: String
    private let clockWitnessID: String
    let personalPermissionPlan: PermissionConsolidation.Plan?

    init(nodes: [Node], profile: String = RevisionMerge.profile, limits: Limits = .init()) throws {
        var builder = try Builder(nodes: nodes, profile: profile, limits: limits)
        try builder.validate()
        self.nodes = builder.nodes
        self.profile = profile
        let referenced = Set(nodes.flatMap(\.parents))
        physicalHeads = builder.nodes.keys.filter { !referenced.contains($0) }.sorted()
        result = try builder.currentAnalysis()
        clockWitnessID = try builder.clockWitness()
        personalPermissionPlan = builder.personalPermissionPlan
    }

    func analyze() throws -> RevisionMerge.Analysis { result }

    /// Allocation happens only after analysis/timestamp validation and is never publication.
    func draft(now: () -> String, allocateRevisionID: () throws -> String) throws -> RevisionMerge.Draft? {
        guard result.needsMaterialization else { return nil }
        let parents: [String]
        if let representative = result.representativeRevisionID {
            parents = [representative, clockWitnessID].sorted()
        } else {
            parents = Array(Set(physicalHeads + [clockWitnessID])).sorted()
        }
        let modifiedAt = try RevisionPublicationClock.after(
            parents.map { nodes[$0]!.revision.modifiedAt }, now: now)
        let revisionID = try allocateRevisionID()
        try Self.validatePersistentID(revisionID)
        guard nodes[revisionID] == nil, revisionID != nodes.values.first!.revision.itemID else {
            throw TractandaError("identifierCollision", "Merge allocation repeated an existing identity.")
        }
        return RevisionMerge.Draft(
            itemID: nodes.values.first!.revision.itemID, revisionID: revisionID,
            parents: parents, frontier: result.frontier, profile: profile,
            fields: result.fields, modifiedAt: modifiedAt)
    }

    private static func validatePersistentID(_ id: String) throws {
        try Identifier.validate(id)
        _ = try UUIDVersion1Components(UUID(uuidString: id)!)
    }

    private struct Builder {
        let nodes: [String: Node]
        let profile: String
        var contexts: [String: Set<String>] = [:]
        var remainingWork: Int
        var creationTime: String?
        var ownershipChanges: [String: [String: String]] = [:]
        var personalPermissionPlan: PermissionConsolidation.Plan?

        init(nodes input: [Node], profile: String, limits: Limits) throws {
            guard [RevisionMerge.profile, RevisionMerge.personalProfile].contains(profile) else {
                throw TractandaError("unsupportedMergeProfile", "Unknown graph merge profile.")
            }
            guard limits.maximumNodes > 0, limits.maximumEdges >= 0,
                limits.maximumEncodedBytes > 0, limits.maximumWork > 0,
                !input.isEmpty, input.count <= limits.maximumNodes
            else { throw TractandaError("resourceLimit", "Invalid or exceeded revision graph budgets.") }
            self.profile = profile
            remainingWork = limits.maximumWork
            var all: [String: Node] = [:]
            var edges = 0
            var encodedBytes = 0
            var estimateRemaining = limits.maximumEncodedBytes
            var inputWork = limits.maximumWork
            for node in input {
                guard node.parents.count <= limits.maximumEdges - edges else {
                    throw TractandaError("resourceLimit", "Revision graph edge budget exceeded.")
                }
                edges += node.parents.count
                let claimed: [String]
                switch node.kind {
                case .authored: claimed = []
                case .automaticMerge(let declaredProfile, let frontier):
                    guard
                        declaredProfile == profile
                            || (profile == RevisionMerge.personalProfile
                                && declaredProfile == RevisionMerge.profile)
                    else {
                        throw TractandaError("unsupportedMergeProfile", "Unknown materialization profile.")
                    }
                    claimed = frontier
                case .resolution(let reviewed, _): claimed = reviewed
                }
                guard claimed.count <= limits.maximumNodes else {
                    throw TractandaError("resourceLimit", "Claimed frontier exceeds the node budget.")
                }
                try Self.boundValue(
                    .list((node.parents + claimed).map(ItemValue.text)),
                    remaining: &estimateRemaining, work: &inputWork)
                for id in claimed { try RevisionGraph.validatePersistentID(id) }
                try Self.boundValue(
                    .object(node.revision.fields), remaining: &estimateRemaining, work: &inputWork)
                for (key, write) in node.kind.writes {
                    try Self.boundValue(.text(key), remaining: &estimateRemaining, work: &inputWork)
                    if case .set(let value) = write {
                        try Self.boundValue(value, remaining: &estimateRemaining, work: &inputWork)
                    }
                }
                try node.revision.validate()
                try ItemSemantics.validate(node.revision)
                if try node.revision.provenance != nil {
                    let declared = try RevisionMerge.node(node.revision)
                    guard declared.parents == node.parents, declared.kind == node.kind else {
                        throw TractandaError(
                            "invalidRevisionGraph",
                            "Graph adapter disagrees with canonical revision ancestry.")
                    }
                }
                try RevisionGraph.validatePersistentID(node.revision.itemID)
                try RevisionGraph.validatePersistentID(node.revision.revisionID)
                _ = try RevisionTimestamp(node.revision.modifiedAt)
                guard node.revision.itemID != node.revision.revisionID else {
                    throw TractandaError("invalidRevisionGraph", "Item and revision identity collide.")
                }
                if let previous = all[node.revision.revisionID] {
                    guard previous == node else {
                        throw TractandaError(
                            "invalidRevisionGraph", "Conflicting bytes/ancestry for one revision identity.")
                    }
                    continue
                }
                guard Set(node.parents).count == node.parents.count else {
                    throw TractandaError("invalidRevisionGraph", "Repeated parent identity.")
                }
                for parent in node.parents { try RevisionGraph.validatePersistentID(parent) }
                if let predecessor = node.revision.supersedes {
                    guard node.parents == [predecessor] else {
                        throw TractandaError(
                            "invalidRevisionGraph", "Single predecessor and ancestry disagree.")
                    }
                }
                let bytes = try JSON.encode(node.revision).count
                guard bytes <= limits.maximumEncodedBytes - encodedBytes else {
                    throw TractandaError("resourceLimit", "Encoded revision graph budget exceeded.")
                }
                encodedBytes += bytes
                for (key, write) in node.kind.writes {
                    guard !key.isEmpty, !key.contains("\0"), !RevisionMerge.managedFields.contains(key) else {
                        throw TractandaError(
                            "invalidRevisionGraph", "Normalized writes contain managed/invalid fields.")
                    }
                    if case .set(let value) = write { try value.validate() }
                }
                all[node.revision.revisionID] = node
            }
            nodes = all
            remainingWork = inputWork
        }

        /// Conservative preflight prevents encoding an unbounded payload before enforcing limits.
        private static func boundValue(
            _ value: ItemValue, remaining: inout Int, work: inout Int, depth: Int = 0
        ) throws {
            guard depth < 32, remaining >= 64, work > 0 else {
                throw TractandaError("resourceLimit", "Graph value depth/byte budget exceeded.")
            }
            remaining -= 64
            work -= 1
            func consume(_ bytes: Int) throws {
                guard bytes <= remaining / 6 else {
                    throw TractandaError("resourceLimit", "Graph value byte budget exceeded.")
                }
                remaining -= bytes * 6
            }
            switch value {
            case .text(let text), .date(let text): try consume(text.utf8.count)
            case .bytes(let data): try consume(data.count)
            case .reference(let reference):
                try consume(reference.itemID.utf8.count + (reference.revisionID?.utf8.count ?? 0))
            case .list(let values):
                for child in values {
                    try boundValue(child, remaining: &remaining, work: &work, depth: depth + 1)
                }
            case .object(let values):
                for (key, child) in values {
                    try consume(key.utf8.count)
                    try boundValue(child, remaining: &remaining, work: &work, depth: depth + 1)
                }
            default: break
            }
        }

        private mutating func spend(_ amount: Int = 1) throws {
            guard amount >= 0, amount <= remainingWork else {
                throw TractandaError("resourceLimit", "Revision graph work budget exceeded.")
            }
            remainingWork -= amount
        }

        mutating func validate() throws {
            let roots = nodes.values.filter { $0.parents.isEmpty }
            guard roots.count == 1, !roots[0].kind.isAutomatic else {
                throw TractandaError("invalidRevisionGraph", "An item needs one authored initial revision.")
            }
            let root = roots[0].revision
            creationTime = root.fields["createdAt"]?.dateString
            for node in nodes.values {
                try spend()
                guard node.revision.itemID == root.itemID,
                    node.revision.fields["createdAt"]?.dateString == creationTime
                else {
                    throw TractandaError("invalidRevisionGraph", "Cross-item graph or changed creation time.")
                }
                for parent in node.parents {
                    try spend()
                    guard let source = nodes[parent], source.revision.itemID == root.itemID else {
                        throw TractandaError("invalidRevisionGraph", "Missing or cross-item parent.")
                    }
                }
            }
            var remaining = Set(nodes.keys)
            while !remaining.isEmpty {
                var ready: [String] = []
                for id in remaining.sorted() {
                    try spend(1 + nodes[id]!.parents.count)
                    if nodes[id]!.parents.allSatisfy({ contexts[$0] != nil }) { ready.append(id) }
                }
                guard !ready.isEmpty else {
                    throw TractandaError("invalidRevisionGraph", "Revision ancestry contains a cycle.")
                }
                for id in ready {
                    try validateNode(id)
                    remaining.remove(id)
                }
            }
        }

        private mutating func validateNode(_ id: String) throws {
            let node = nodes[id]!
            var context: Set<String> = []
            for parent in node.parents {
                let inherited = contexts[parent]!
                try spend(inherited.count)
                context.formUnion(inherited)
            }
            let validationProfile: String
            if case .automaticMerge(let declared, _) = node.kind {
                validationProfile = declared
            } else {
                validationProfile = profile
            }
            let before = try evaluate(context, using: validationProfile)
            var fields = before.fields
            switch node.kind {
            case .authored(let writes):
                guard node.parents.count <= 1, before.isResolved else {
                    throw TractandaError(
                        "invalidRevisionGraph", "Ordinary authorship requires a resolved single parent.")
                }
                if node.parents.isEmpty {
                    guard
                        writes
                            == RevisionMerge.semanticFields(node.revision).mapValues(RevisionFieldWrite.set)
                    else {
                        throw TractandaError(
                            "invalidRevisionGraph", "Root writes must seed its exact snapshot.")
                    }
                }
                try apply(writes, to: &fields)
                context.insert(id)
            case .resolution(let reviewed, let writes):
                guard !node.parents.isEmpty, reviewed == before.frontier,
                    Set(before.conflicts.keys).union(before.protectedFields).isSubset(of: writes.keys)
                else {
                    throw TractandaError(
                        "invalidRevisionGraph",
                        "Resolution must consume and explicitly resolve its reviewed frontier.")
                }
                try apply(writes, to: &fields)
                context.insert(id)
            case .automaticMerge(let declaredProfile, let frontier):
                guard declaredProfile == validationProfile, frontier == before.frontier,
                    !frontier.isEmpty, node.parents.count > 1, before.isResolved
                else {
                    throw TractandaError(
                        "invalidRevisionGraph", "Merge profile/frontier or eligibility is invalid.")
                }
                var equivalentTimes: [RevisionTimestamp] = []
                var witnessTimes: [RevisionTimestamp] = []
                for parent in node.parents {
                    let time = try RevisionTimestamp(nodes[parent]!.revision.modifiedAt)
                    if try maximal(contexts[parent]!) == frontier {
                        equivalentTimes.append(time)
                    } else {
                        witnessTimes.append(time)
                    }
                }
                if let current = equivalentTimes.max() {
                    guard let witness = witnessTimes.max(), witness > current else {
                        throw TractandaError(
                            "invalidRevisionGraph",
                            "Equivalent-only materialization has no clock advance to reconcile.")
                    }
                }
            }
            if case .authored = node.kind {
                // Ordinary historical authored clocks are retained even when they went backward.
            } else {
                for parent in node.parents {
                    try spend()
                    guard
                        try RevisionTimestamp(node.revision.modifiedAt)
                            > RevisionTimestamp(nodes[parent]!.revision.modifiedAt)
                    else {
                        throw TractandaError(
                            "invalidMergeTimestamp", "Merge timestamp must exceed every parent.")
                    }
                }
            }
            try spend(fields.count)
            guard fields == RevisionMerge.semanticFields(node.revision) else {
                throw TractandaError(
                    "invalidRevisionGraph", "Snapshot disagrees with applied writes or derived merge payload."
                )
            }
            if !node.kind.isAutomatic, node.kind.writes["permissions"] != nil,
                let value = fields["permissions"]
            {
                let current = try ItemPermissions(value)
                let prior = try before.fields["permissions"].map(ItemPermissions.init)
                var changes: [String: String] = [:]
                if prior?.owner != current.owner { changes["owner"] = current.owner }
                if prior?.group != current.group { changes["group"] = current.group }
                ownershipChanges[id] = changes
            }
            contexts[id] = context
        }

        private mutating func apply(
            _ writes: [String: RevisionFieldWrite], to fields: inout [String: ItemValue]
        )
            throws
        {
            for (field, write) in writes {
                try spend()
                switch write {
                case .set(let value): fields[field] = value
                case .unset: fields.removeValue(forKey: field)
                }
            }
        }

        private mutating func maximal(_ context: Set<String>) throws -> [String] {
            var result: [String] = []
            for candidate in context.sorted() {
                var dominated = false
                for other in context where other != candidate {
                    try spend()
                    if contexts[other]!.contains(candidate) {
                        dominated = true
                        break
                    }
                }
                if !dominated { result.append(candidate) }
            }
            return result
        }

        private mutating func evaluate(_ context: Set<String>, using requestedProfile: String? = nil) throws
            -> RevisionMerge.Analysis
        {
            let frontier = try maximal(context)
            var byField: [String: [RevisionMerge.Candidate]] = [:]
            for id in context.sorted() {
                for (field, write) in nodes[id]!.kind.writes {
                    try spend()
                    byField[field, default: []].append(.init(revisionID: id, write: write))
                }
            }
            var values: [String: RevisionFieldWrite] = [:]
            var conflicts: [String: [RevisionMerge.Candidate]] = [:]
            var protected: Set<String> = []
            let protectedClass = context.contains {
                RevisionMerge.protectedClasses.contains(nodes[$0]!.revision.classID)
            }
            for field in byField.keys.sorted() {
                let candidates = byField[field]!
                var maximalWrites: [RevisionMerge.Candidate] = []
                for candidate in candidates {
                    var dominated = false
                    for other in candidates where other.revisionID != candidate.revisionID {
                        try spend()
                        if contexts[other.revisionID]!.contains(candidate.revisionID) {
                            dominated = true
                            break
                        }
                    }
                    if !dominated { maximalWrites.append(candidate) }
                }
                if field == "permissions", (requestedProfile ?? profile) == RevisionMerge.personalProfile {
                    let components = maximalWrites.compactMap { candidate -> ItemValue? in
                        if case .set(let value) = candidate.write { return value }
                        return nil
                    }
                    if components.count == maximalWrites.count, !components.isEmpty {
                        let ownership = try selectedOwnership(in: context)
                        let plan = try PermissionConsolidation.plan(components, selectedOwnership: ownership)
                        personalPermissionPlan = plan
                        if let value = plan.outcome.posixValue {
                            values[field] = .set(value)
                            continue
                        }
                    }
                }
                if let first = maximalWrites.first {
                    try spend(maximalWrites.count)
                    if maximalWrites.allSatisfy({ $0.write == first.write }) {
                        values[field] = first.write
                    } else {
                        conflicts[field] = maximalWrites
                    }
                }
                if protectedClass || RevisionMerge.protectedFields.contains(field) {
                    for writer in maximalWrites {
                        for head in frontier where head != writer.revisionID {
                            try spend()
                            if !contexts[head]!.contains(writer.revisionID),
                                !contexts[writer.revisionID]!.contains(head)
                            {
                                protected.insert(field)
                            }
                        }
                    }
                }
            }
            return RevisionMerge.Analysis(
                frontier: frontier, values: values, conflicts: conflicts, protectedFields: protected,
                representativeRevisionID: nil, needsMaterialization: false)
        }

        /// Only actual property changes participate. A chmod snapshot carrying an older role
        /// is not another ownership write. Caller must authorize intake; graph validation grants none.
        private mutating func selectedOwnership(in context: Set<String>) throws -> PermissionConsolidation
            .Ownership?
        {
            func role(_ key: String) throws -> String? {
                let candidates = context.filter { ownershipChanges[$0]?[key] != nil }
                var maximal: [String] = []
                for candidate in candidates {
                    var dominated = false
                    for other in candidates where candidate != other {
                        try spend()
                        if contexts[other]!.contains(candidate) {
                            dominated = true
                            break
                        }
                    }
                    if !dominated { maximal.append(candidate) }
                }
                let winner = try maximal.sorted { a, b in
                    let left = try UUIDVersion1Components(UUID(uuidString: a)!).timestamp
                    let right = try UUIDVersion1Components(UUID(uuidString: b)!).timestamp
                    return left == right ? a < b : left < right
                }.last
                return winner.flatMap { ownershipChanges[$0]?[key] }
            }
            guard let owner = try role("owner"), let group = try role("group") else { return nil }
            return .init(owner: owner, group: group)
        }

        mutating func currentAnalysis() throws -> RevisionMerge.Analysis {
            var context: Set<String> = []
            for inherited in contexts.values {
                try spend(inherited.count)
                context.formUnion(inherited)
            }
            let state = try evaluate(context)
            var representative: String?
            if state.isResolved {
                if state.frontier.count == 1 {
                    representative = state.frontier[0]
                }
                for id in nodes.keys.sorted() where nodes[id]!.kind.isAutomatic {
                    try spend()
                    guard try maximal(contexts[id]!) == state.frontier else { continue }
                    if let previous = representative {
                        let nextTime = try RevisionTimestamp(nodes[id]!.revision.modifiedAt)
                        let oldTime = try RevisionTimestamp(nodes[previous]!.revision.modifiedAt)
                        if nextTime > oldTime || (nextTime == oldTime && id > previous) {
                            representative = id
                        }
                    } else {
                        representative = id
                    }
                }
            }
            let floorID = try clockWitness()
            let needsClock: Bool
            if let representative {
                needsClock =
                    try RevisionTimestamp(nodes[representative]!.revision.modifiedAt)
                    < RevisionTimestamp(nodes[floorID]!.revision.modifiedAt)
            } else {
                needsClock = false
            }
            return RevisionMerge.Analysis(
                frontier: state.frontier, values: state.values, conflicts: state.conflicts,
                protectedFields: state.protectedFields, representativeRevisionID: representative,
                needsMaterialization: state.isResolved && (representative == nil || needsClock))
        }

        mutating func clockWitness() throws -> String {
            var witness: String?
            for id in nodes.keys.sorted() {
                try spend()
                if let old = witness {
                    let time = try RevisionTimestamp(nodes[id]!.revision.modifiedAt)
                    let oldTime = try RevisionTimestamp(nodes[old]!.revision.modifiedAt)
                    if time > oldTime || (time == oldTime && id > old) { witness = id }
                } else {
                    witness = id
                }
            }
            return witness!
        }
    }
}
