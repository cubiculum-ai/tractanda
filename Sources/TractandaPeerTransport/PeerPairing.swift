import Foundation
import TractandaCore
import TractandaPeerTLS

/// Host-private pairing, supplied directly or reconstructed from the current private generation.
package final class PeerPairing: Sendable {
    let tls: PeerTLSContext
    private let peerID: String
    private let configurationDigest: String
    package init(
        peerID: String, profile: PeerTLSProfile, role: PeerTLSRole,
        configurationDigest: String, secret: PeerTLSSecret
    ) throws {
        tls = try PeerTLSContext(profile: profile, role: role, secret: secret)
        self.peerID = peerID
        self.configurationDigest = configurationDigest
    }
    package convenience init(credential: PeerCredential) throws {
        let input = try credential.withTLSInput { binding, bytes in
            let profile = try PeerTLSProfile(
                storeID: binding.storeID,
                initiatorReplicaID: binding.localIsInitiator
                    ? binding.localReplicaID : binding.remoteReplicaID,
                responderReplicaID: binding.localIsInitiator
                    ? binding.remoteReplicaID : binding.localReplicaID,
                pairingID: binding.pairingID)
            return (binding, profile, try PeerTLSSecret(bytes: bytes))
        }
        try self.init(
            peerID: input.0.peerID, profile: input.1,
            role: input.0.localIsInitiator ? .initiator : .responder,
            configurationDigest: input.0.configurationDigest, secret: input.2)
    }
    package static func load(peerID: String, coordinator: ServiceCoordinator) async throws -> PeerPairing {
        try PeerPairing(credential: await coordinator.loadPeerCredential(peerID: peerID))
    }
    func resolve(_ session: PeerTLSSession) throws -> PeerExchangeBinding {
        let profile = tls.profile
        let initiator = tls.role == .initiator
        guard session.profile == profile, session.cipherSuite == 0x1302,
            session.keyExchangeGroup == 0x11ec,
            session.localReplicaID == (initiator ? profile.initiatorReplicaID : profile.responderReplicaID),
            session.remoteReplicaID == (initiator ? profile.responderReplicaID : profile.initiatorReplicaID)
        else { throw TractandaError("untrustedPeer", "Authenticated TLS pairing differs from local record.") }
        return try PeerExchangeBinding(
            peerID: peerID, storeID: profile.storeID, localReplicaID: session.localReplicaID,
            remoteReplicaID: session.remoteReplicaID, pairingID: profile.pairingID,
            localIsInitiator: initiator, configurationDigest: configurationDigest)
    }
}
