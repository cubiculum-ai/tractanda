import Foundation

/// Trusted host-private TLS construction input. This is not Codable; secret descriptions
/// and mirrors remain redacted. A frame cannot supply a transport purpose or binding.
package struct PersonalEnrollmentPeerMaterial: Sendable {
    package let binding: PeerExchangeBinding
    package let purpose: PersonalEnrollmentTransportPurpose
    package let secret: PersonalEnrollmentSecret
    package let endpoints: [PeerRuntimeConfiguration.Endpoint]
    package static func invitation(_ invitation: PersonalEnrollmentInvitation, localIsIssuer: Bool) throws -> Self {
        let meta = invitation.metadata
        return try .init(binding: .init(peerID: "enrollment-invitation-" + meta.operationID, storeID: meta.storeID,
            localReplicaID: localIsIssuer ? meta.issuerReplicaID : meta.bootstrapReplicaID,
            remoteReplicaID: localIsIssuer ? meta.bootstrapReplicaID : meta.issuerReplicaID,
            pairingID: meta.pairingID, localIsInitiator: !localIsIssuer,
            configurationDigest: PersonalSyncValidation.digest(JSON.encode(meta))),
            purpose: .invitation, secret: invitation.secret, endpoints: localIsIssuer ? [] : meta.endpoints)
    }
    package static func continuation(invitation: PersonalEnrollmentInvitationMetadata,
        claim: PersonalEnrollmentClaim, localIsIssuer: Bool) throws -> Self {
        try claim.metadata.validate(invitation: invitation)
        struct Context: Encodable { let invitation: PersonalEnrollmentInvitationMetadata; let claim: PersonalEnrollmentClaimMetadata }
        let digest = try PersonalSyncValidation.digest(JSON.encode(Context(invitation: invitation, claim: claim.metadata)))
        return try .init(binding: .init(peerID: "enrollment-continuation-" + invitation.operationID, storeID: invitation.storeID,
            localReplicaID: localIsIssuer ? invitation.issuerReplicaID : claim.metadata.targetReplicaID,
            remoteReplicaID: localIsIssuer ? claim.metadata.targetReplicaID : invitation.issuerReplicaID,
            pairingID: claim.metadata.continuationPairingID, localIsInitiator: !localIsIssuer, configurationDigest: digest),
            purpose: .continuation, secret: claim.continuationSecret, endpoints: localIsIssuer ? [] : invitation.endpoints)
    }
}

package struct PersonalEnrollmentRuntimeMaterial: Sendable {
    package let retainedControlCredentials: [PeerCredential]
    package let privatePeers: [PersonalEnrollmentPeerMaterial]
    package let routes: PersonalEnrollmentRouteState?
    package init(retainedControlCredentials: [PeerCredential] = [], privatePeers: [PersonalEnrollmentPeerMaterial] = [],
        routes: PersonalEnrollmentRouteState? = nil) {
        self.retainedControlCredentials = retainedControlCredentials; self.privatePeers = privatePeers; self.routes = routes
    }
}
