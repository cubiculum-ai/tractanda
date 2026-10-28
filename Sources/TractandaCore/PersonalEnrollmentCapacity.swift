import Foundation

/// A coordinator/runtime qualification limit, deliberately independent of the canonical
/// membership schema's 256 members. Check before any remote preparation or policy change.
package struct PersonalEnrollmentCapacity: Sendable {
    package static let maximumQualifiedMembers = 16
    package let maximumOverlappingSockets: Int
    package let maximumResponderContexts: Int
    package let maximumCredentialRoles: Int
    package static func preflight(current: PersonalMembershipConfiguration?,
        proposed: PersonalMembershipConfiguration, initiatingReplicaID: String,
        runtimeSocketLimit: Int, tlsContextLimit: Int, credentialRoleLimit: Int) throws -> Self {
        try proposed.validate()
        try current?.validate()
        try PersonalSyncValidation.identifier(initiatingReplicaID)
        let old = Set(current?.members.map(\.replicaID) ?? [initiatingReplicaID])
        let next = Set(proposed.members.map(\.replicaID))
        guard current == nil || current?.storeID == proposed.storeID,
            old.contains(initiatingReplicaID), next.contains(initiatingReplicaID),
            old.isSubset(of: next) || next.isSubset(of: old) else {
            throw PersonalEnrollmentError.conflict()
        }
        guard max(old.count, next.count) <= maximumQualifiedMembers else {
            throw TractandaError("enrollmentCapacityUnsupported",
                "Native enrollment currently supports at most 16 members; no membership or policy was changed.")
        }
        var sockets = 0, contexts = 0, roles = 0
        for member in old.union(next) {
            let oldRemote = old.contains(member) ? old.count - 1 : 0
            let nextRemote = next.contains(member) ? next.count - 1 : 0
            // Keep old and next sessions intact, reserve invitation+continuation and
            // the existing two concurrent dial starts. No healthy-session eviction.
            sockets = max(sockets, oldRemote + nextRemote + 4)
            contexts = max(contexts, oldRemote + nextRemote + 2)
            roles = max(roles, 2 * (oldRemote + nextRemote))
        }
        guard runtimeSocketLimit > 0, tlsContextLimit > 0, credentialRoleLimit > 0,
            sockets <= runtimeSocketLimit, contexts <= tlsContextLimit, roles <= credentialRoleLimit else {
            throw TractandaError("enrollmentCapacityUnsupported",
                "Old and proposed peer contexts exceed configured runtime capacity; no membership or policy was changed.")
        }
        return .init(maximumOverlappingSockets: sockets, maximumResponderContexts: contexts, maximumCredentialRoles: roles)
    }
}
