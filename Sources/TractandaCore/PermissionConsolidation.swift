import Foundation

/// Pure planning over the original concurrent policies. This does not authorize an edit or publish a revision.
/// Keep the components when combining plans: a conservative POSIX result is not an exact meet.
struct PermissionConsolidation {
    struct Limits: Sendable {
        var maximumComponents = 256
        var maximumEncodedBytes = 1024 * 1024
    }

    enum ConservativeReason: String, Equatable, Sendable {
        case unsupportedPOSIXIntersection
    }

    /// Caller-selected current roles, after separately authorizing and ordering actual identity changes.
    /// This planner does not select a winner from snapshot timestamps.
    struct Ownership: Equatable, Sendable {
        let owner: String
        let group: String
    }

    struct OwnershipCandidates: Equatable, Sendable {
        let owners: [String]
        let groups: [String]
    }

    enum Outcome: Equatable, Sendable {
        case exactPOSIX(ItemValue)
        /// An owner-only lower bound, not necessarily the greatest representable lower bound.
        case conservativePOSIX(ItemValue, reason: ConservativeReason)
        case needsOwnershipSelection(OwnershipCandidates)

        /// Structural candidate only. Validate original principals before using it as a current policy.
        var posixValue: ItemValue? {
            switch self {
            case .exactPOSIX(let value), .conservativePOSIX(let value, _): return value
            case .needsOwnershipSelection: return nil
            }
        }
    }

    struct Plan: Sendable {
        /// Sorted, deduplicated source descriptors; never persist this as a new permission language.
        let components: [ItemValue]
        let outcome: Outcome
        let ownership: Ownership?
        private let originalPermissions: [ItemPermissions]
        private let permissions: [ItemPermissions]

        fileprivate init(
            components: [ItemValue], originalPermissions: [ItemPermissions], permissions: [ItemPermissions],
            outcome: Outcome, ownership: Ownership?
        ) {
            self.components = components
            self.originalPermissions = originalPermissions
            self.permissions = permissions
            self.outcome = outcome
            self.ownership = ownership
        }

        /// Do not let simplification hide an unresolved name or duplicate resolved ACL principal.
        /// This checks only current identity mappings; it retains neither UIDs nor membership snapshots.
        func validatedPOSIXValue(using resolver: PrincipalResolver) throws -> ItemValue? {
            for permission in originalPermissions { try permission.validate(using: resolver) }
            for permission in permissions { try permission.validate(using: resolver) }
            return outcome.posixValue
        }

        /// Diagnostic conjunction of original principals' grants, before any ownership-role selection.
        func allowsInEveryOriginalComponent(
            _ rights: Int, for account: AccountIdentity, using resolver: PrincipalResolver
        ) throws -> Bool {
            guard [2, 4, 6].contains(rights) else {
                throw TractandaError("invalidPermissions", "Expected a read, write or combined request.")
            }
            return try originalPermissions.allSatisfy { try $0.allows(rights, for: account, using: resolver) }
        }

        /// Exact conjunction AFTER applying caller-selected roles, not an intersection of the original
        /// principals' grants when ownership changed. Requests 4, 2 and 6 retain their distinct semantics.
        func allowsInEveryNormalizedComponent(
            _ rights: Int, for account: AccountIdentity, using resolver: PrincipalResolver
        ) throws -> Bool {
            guard [2, 4, 6].contains(rights) else {
                throw TractandaError("invalidPermissions", "Expected a read, write or combined request.")
            }
            guard ownership != nil else {
                throw TractandaError("ownershipSelectionRequired", "Current ownership has not been selected.")
            }
            return try permissions.allSatisfy { try $0.allows(rights, for: account, using: resolver) }
        }

        /// Reports the existing Store sharing-edit condition after explicit role selection.
        /// It does not add content-right bits to the selected owner's role.
        func ownerCanManageUnderExistingRules(
            _ account: AccountIdentity, using resolver: PrincipalResolver
        ) throws -> Bool {
            guard let ownership, try resolver.userID(ownership.owner) == account.uid else { return false }
            return try allowsInEveryNormalizedComponent(6, for: account, using: resolver)
        }
    }

    static func plan(
        _ values: [ItemValue], selectedOwnership: Ownership? = nil, limits: Limits = .init()
    ) throws -> Plan {
        guard limits.maximumComponents > 0, limits.maximumEncodedBytes > 0,
            !values.isEmpty, values.count <= limits.maximumComponents
        else { throw TractandaError("resourceLimit", "Permission component budget is invalid or exceeded.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var unique: [Data: (ItemValue, ItemPermissions)] = [:]
        var remaining = limits.maximumEncodedBytes
        for value in values {
            // Validate the bounded POSIX shape before encoding any caller-supplied value.
            let permission = try ItemPermissions(value)
            let key = try encoder.encode(value)
            guard key.count <= remaining else {
                throw TractandaError("resourceLimit", "Permission encoding budget exceeded.")
            }
            remaining -= key.count
            unique[key] = (value, permission)
        }
        let ordered = unique.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { unique[$0]! }
        let components = ordered.map(\.0)
        let originals = ordered.map(\.1)
        let owners = Set(originals.map(\.owner)).sorted()
        let groups = Set(originals.map(\.group)).sorted()
        let ownership =
            selectedOwnership
            ?? (owners.count == 1 && groups.count == 1
                ? Ownership(owner: owners[0], group: groups[0]) : nil)
        if let ownership {
            try PrincipalNames.validate(ownership.owner)
            try PrincipalNames.validate(ownership.group)
        }
        let normalized = components.map { component -> ItemValue in
            guard let ownership else { return component }
            var fields = component.map!
            fields["owner"] = .text(ownership.owner)
            fields["group"] = .text(ownership.group)
            return .object(fields)
        }
        let policies = try normalized.map(ItemPermissions.init)
        let outcome: Outcome
        if ownership == nil {
            // Missing provenance is not a mandatory administrator-review policy or an arbitrary winner.
            outcome = .needsOwnershipSelection(.init(owners: owners, groups: groups))
        } else if components.count == 1 {
            outcome = .exactPOSIX(normalized[0])
        } else if policies.allSatisfy({
            $0.groups.isEmpty && Set($0.users.keys) == Set(policies[0].users.keys)
        }) {
            // These descriptors have identical decision branches: owner, named user, one group, other.
            let ownerRights = policies.reduce(6) { $0 & (($1.mode >> 6) & 6) }
            let otherRights = policies.reduce(6) { $0 & ($1.mode & 6) }
            if policies.allSatisfy({ $0.mask == nil }) {
                let groupRights = policies.reduce(6) { $0 & $1.owningGroupPermissions }
                outcome = .exactPOSIX(
                    value(
                        owner: ownership!.owner, group: ownership!.group,
                        mode: ownerRights << 6 | groupRights << 3 | otherRights))
            } else {
                let groupRights = policies.reduce(6) { $0 & $1.owningGroupPermissions & ($1.mask ?? 6) }
                let users = policies[0].users.keys.reduce(into: [String: ItemValue]()) { result, name in
                    result[name] = .integer(
                        Int64(policies.reduce(6) { $0 & $1.users[name]! & ($1.mask ?? 6) }))
                }
                outcome = .exactPOSIX(
                    value(
                        owner: ownership!.owner, group: ownership!.group,
                        mode: ownerRights << 6 | 6 << 3 | otherRights,
                        acl: [
                            "mask": .integer(6), "owningGroup": .integer(Int64(groupRights)),
                            "users": .object(users),
                        ]))
            }
        } else {
            // Named precedence and dynamic groups make a pointwise map/mode AND unsound in general.
            let ownerRights = policies.reduce(6) { $0 & (($1.mode >> 6) & 6) }
            outcome = .conservativePOSIX(
                value(owner: ownership!.owner, group: ownership!.group, mode: ownerRights << 6),
                reason: .unsupportedPOSIXIntersection)
        }
        return Plan(
            components: components, originalPermissions: originals, permissions: policies,
            outcome: outcome, ownership: ownership)
    }

    /// Ownership is supplied afresh: a previous role selection must not silently overrule newer changes.
    static func combine(
        _ plans: [Plan], selectedOwnership: Ownership? = nil, limits: Limits = .init()
    ) throws -> Plan {
        var components: [ItemValue] = []
        for plan in plans {
            guard plan.components.count <= limits.maximumComponents - components.count else {
                throw TractandaError("resourceLimit", "Combined permission component budget exceeded.")
            }
            components.append(contentsOf: plan.components)
        }
        return try self.plan(components, selectedOwnership: selectedOwnership, limits: limits)
    }

    private static func value(
        owner: String, group: String, mode: Int, acl: [String: ItemValue] = [:]
    ) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner), "group": .text(group),
            "mode": .integer(Int64(mode)), "acl": .object(acl),
        ])
    }
}
