import Foundation

/// Shared bounded disk-analysis and planning values. No DTO grants intake/publication authority.
enum RevisionProjection {
    /// Exact accepted authored-frontier snapshot policy; no current principal grant is implied.
    struct PolicyWitness: Equatable, Sendable {
        let revisionID: String
        let classID: String
        let permissions: ItemValue?
    }

    struct Limits: Sendable {
        var maximumVMInstructions: Int64 = 200_000_000
        var maximumHydratedBytes: UInt64 = 512 * 1024 * 1024
        var maximumResultBytes: Int = 32 * 1024 * 1024
        var maximumCandidateCount: Int = 4096
        var maximumFrontierCount: Int = 4096
        var maximumStagingBytes: UInt64 = 256 * 1024 * 1024
        var minimumFreeBytes: UInt64 = 1024 * 1024 * 1024
    }

    struct Representation: Equatable, Sendable {
        let revisionID: String
        let modifiedAt: String
    }

    struct ClockWitness: Equatable, Sendable {
        let revisionID: String
        let modifiedAt: String
    }

    struct Snapshot: Equatable, Sendable {
        let itemID: String
        let analysis: RevisionMerge.Analysis
        let representative: Representation?
        let clockFloor: ClockWitness
        let physicalHeads: [String]
    }

    enum Reason: String, Sendable { case fieldMerge, clockReconciliation }
    enum Block: Equatable, Sendable {
        case payloadLimit(actualBytes: Int, maximumBytes: Int)
        case ancestryLimit(parents: Int, frontier: Int)
    }
    enum PlanResult: Equatable, Sendable {
        case unchanged
        case conflicted
        case blocked(Block)
        case ready(Plan)
    }
    struct Plan: Equatable, Sendable {
        let reason: Reason
        let parents: [String]
        let frontier: [String]
        let profile: String
        let fields: [String: ItemValue]
        let modifiedAt: String
    }

    static func plan(
        _ snapshot: Snapshot, maximumPayloadBytes: Int = 8 * 1024 * 1024, now: () -> String
    ) throws -> PlanResult {
        try Identifier.validate(snapshot.itemID)
        let floor = try RevisionTimestamp(snapshot.clockFloor.modifiedAt)
        guard snapshot.analysis.isResolved else { return .conflicted }
        let reason: Reason
        let parents: [String]
        if let representative = snapshot.representative {
            guard snapshot.analysis.representativeRevisionID == representative.revisionID else {
                throw TractandaError("invalidRevisionGraph", "Projection representative metadata disagrees.")
            }
            let current = try RevisionTimestamp(representative.modifiedAt)
            guard current <= floor else {
                throw TractandaError(
                    "invalidRevisionGraph", "Representative exceeds its accepted clock floor.")
            }
            if current == floor { return .unchanged }
            guard representative.revisionID != snapshot.clockFloor.revisionID else {
                throw TractandaError(
                    "invalidRevisionGraph", "A clock witness cannot contradict its own revision.")
            }
            reason = .clockReconciliation
            parents = [representative.revisionID, snapshot.clockFloor.revisionID].sorted()
        } else {
            reason = .fieldMerge
            parents = Array(Set(snapshot.physicalHeads + [snapshot.clockFloor.revisionID])).sorted()
        }
        let frontier = snapshot.analysis.frontier
        guard parents.count > 1, !frontier.isEmpty,
            frontier == Array(Set(frontier)).sorted()
        else {
            throw TractandaError(
                "invalidRevisionGraph", "Materialization needs complete distinct input ancestry.")
        }
        for id in parents + frontier {
            try Identifier.validate(id)
            guard UUID(uuidString: id)?.version1Components != nil else {
                throw TractandaError(
                    "invalidRevisionGraph", "Projection ancestry must preserve UUIDv1 identity.")
            }
        }
        if parents.count > 1024 || frontier.count > 1024 {
            return .blocked(.ancestryLimit(parents: parents.count, frontier: frontier.count))
        }
        guard maximumPayloadBytes > 0 else {
            throw TractandaError("resourceLimit", "Invalid materialization payload window.")
        }
        let fields = snapshot.analysis.fields
        let encodedBytes = try JSON.encode(fields).count
        if encodedBytes > maximumPayloadBytes {
            return .blocked(.payloadLimit(actualBytes: encodedBytes, maximumBytes: maximumPayloadBytes))
        }
        return .ready(
            Plan(
                reason: reason, parents: parents, frontier: frontier, profile: RevisionMerge.profile,
                fields: fields,
                modifiedAt: try RevisionPublicationClock.after([snapshot.clockFloor.modifiedAt], now: now)))
    }

    /// The runtime publisher must still validate complete record/domain/current-authority limits.
    static func draft(
        _ plan: Plan, itemID: String, allocate: () throws -> UUID,
        isAvailable: (String) throws -> Bool
    ) throws -> RevisionMerge.Draft {
        let uuid = try allocate()
        let id = uuid.uuidString.lowercased()
        guard uuid.version1Components != nil, id != itemID,
            !plan.parents.contains(id), !plan.frontier.contains(id), try isAvailable(id)
        else {
            throw TractandaError("identifierCollision", "Materialization needs a new actual UUIDv1 identity.")
        }
        return RevisionMerge.Draft(
            itemID: itemID, revisionID: id, parents: plan.parents, frontier: plan.frontier,
            profile: plan.profile, fields: plan.fields, modifiedAt: plan.modifiedAt)
    }
}
