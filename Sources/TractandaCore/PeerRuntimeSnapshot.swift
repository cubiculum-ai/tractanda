import Foundation

/// Host-private admission inputs, never a service response or a lasting authorization grant.
package final class PeerRuntimeSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    package let credentials: [PeerCredential]
    /// Non-secret canonical security state, separate from node-local endpoint settings.
    package let securityToken: String
    let canonicalGeneration: UInt64
    private let owner: UUID
    let material: Material

    struct Material: Sendable, CustomStringConvertible, CustomReflectable {
        let credentials: [PeerCredential]
        let securityToken: String
        let storeID: String
        let replicaID: String
        private let witnesses: [String: String]

        init(credentials: [PeerCredential], securityToken: String, storeID: String, replicaID: String) throws {
            self.credentials = credentials
            self.securityToken = securityToken
            self.storeID = storeID
            self.replicaID = replicaID
            guard credentials.count <= 256 else {
                throw TractandaError("resourceLimit", "Peer runtime credential limit exceeded.")
            }
            var witnesses: [String: String] = [:]
            for credential in credentials {
                guard try witnesses.updateValue(credential.privateBytesDigest,
                    forKey: credential.binding.peerID) == nil else { throw PeerRuntimeSnapshot.changed() }
            }
            self.witnesses = witnesses
        }

        func requireCurrent(_ current: Self) throws {
            guard securityToken == current.securityToken, storeID == current.storeID,
                replicaID == current.replicaID, witnesses == current.witnesses else {
                throw PeerRuntimeSnapshot.changed()
            }
        }
        func hasSameCredentials(as other: Self) -> Bool {
            storeID == other.storeID && replicaID == other.replicaID && witnesses == other.witnesses
        }
        var description: String { "PeerRuntimeSnapshot.Material(<redacted>)" }
        var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
    }

    init(material: Material, owner: UUID, canonicalGeneration: UInt64) {
        self.material = material
        self.credentials = material.credentials
        self.securityToken = material.securityToken
        self.owner = owner
        self.canonicalGeneration = canonicalGeneration
    }

    func requireOwner(_ owner: UUID) throws {
        guard self.owner == owner else { throw Self.changed() }
    }
    /// Private-input continuity only, never validation of either snapshot's current authority.
    package func hasSameCredentials(as other: PeerRuntimeSnapshot) -> Bool {
        owner == other.owner && material.hasSameCredentials(as: other.material)
    }

    /// Current job ownership includes the canonical rebuild generation; ordinary writes do not.
    package func hasSameAdmission(as other: PeerRuntimeSnapshot) -> Bool {
        canonicalGeneration == other.canonicalGeneration && securityToken == other.securityToken
            && hasSameCredentials(as: other)
    }
    private static func changed() -> TractandaError {
        TractandaError("peerConfigurationChanged", "Peer runtime snapshot is no longer current.")
    }
    package var description: String { "PeerRuntimeSnapshot(<redacted>)" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}
