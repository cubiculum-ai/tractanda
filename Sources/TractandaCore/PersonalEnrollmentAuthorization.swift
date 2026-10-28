import Foundation

/// A trusted current server's bounded administrator decision. This is operational input,
/// not a bearer grant: the receiver must bind it to the actual authenticated current peer.
package struct PersonalEnrollmentAdminDecision: Codable, Equatable, Sendable {
    package let operationID: String
    package let authorizingReplicaID: String
    package let administrator: String
    package let expectedMembershipDigest: String
    package let configuration: PersonalMembershipConfiguration
    package let nonce: String

    package static func issue(authorization: PersonalEnrollmentLocalAuthorization,
        operationID: String, configuration: PersonalMembershipConfiguration, nonce: String) throws -> Self {
        guard let current = authorization.identity.membership else {
            throw TractandaError("membershipConflict", "Current-member delegation requires committed membership.")
        }
        let decision = Self(operationID: operationID,
            authorizingReplicaID: authorization.identity.replicaID,
            administrator: authorization.administrator, expectedMembershipDigest: try current.digest,
            configuration: configuration, nonce: nonce)
        try decision.validate()
        guard configuration.storeID == current.storeID,
            configuration.members.contains(where: { $0.replicaID == authorization.identity.replicaID })
        else { throw PersonalEnrollmentError.conflict() }
        return decision
    }
    package func validate() throws {
        try PersonalSyncValidation.identifier(operationID)
        try PersonalSyncValidation.identifier(authorizingReplicaID)
        try PersonalSyncValidation.identifier(nonce)
        try PersonalSyncValidation.sha256(expectedMembershipDigest)
        try configuration.validate()
        guard !administrator.isEmpty, administrator.utf8.count <= 255,
            !administrator.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            configuration.members.contains(where: { $0.replicaID == authorizingReplicaID })
        else { throw PersonalEnrollmentError.invalid() }
    }
    package static func decodeStrict(_ bytes: Data) throws -> Self {
        guard bytes.count <= 160 * 1024,
            let original = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(original.keys) == ["operationID", "authorizingReplicaID", "administrator", "expectedMembershipDigest", "configuration", "nonce"] else {
            throw PersonalEnrollmentError.invalid()
        }
        let value = try JSON.decode(Self.self, bytes)
        try value.validate()
        let normalized = try JSONSerialization.jsonObject(with: JSON.encode(value)) as! [AnyHashable: Any]
        guard NSDictionary(dictionary: original).isEqual(to: normalized) else { throw PersonalEnrollmentError.invalid() }
        return value
    }
}

/// Unforgeable by JSON: only the host's actual current-peer validation constructs it.
/// It authorizes precisely one membership decision and carries a local identity mapping;
/// it does not change access context, imply UID 0 or make ordinary peer methods admins.
package struct PersonalEnrollmentScopedAuthorization: Sendable {
    package let decision: PersonalEnrollmentAdminDecision
    package let localUID: UInt32
    package let localName: String
    private let binding: PeerExchangeBinding
    private init(decision: PersonalEnrollmentAdminDecision, account: AccountIdentity, binding: PeerExchangeBinding) {
        self.decision = decision; localUID = account.uid; localName = account.name
        self.binding = binding
    }
    package static func receive(store: ItemStore, binding: PeerExchangeBinding,
        decision: PersonalEnrollmentAdminDecision) throws -> Self {
        try decision.validate()
        // This checks the existing current credential and canonical membership. A mere
        // invitation/prepared-only connection cannot construct an administrator witness.
        try store.validatePersonalPeerBinding(binding)
        let identity = try store.personalSyncIdentity()
        guard let current = identity.membership,
            try current.digest == decision.expectedMembershipDigest,
            binding.configurationDigest == decision.expectedMembershipDigest,
            binding.remoteReplicaID == decision.authorizingReplicaID,
            binding.storeID == decision.configuration.storeID,
            identity.storeID == decision.configuration.storeID,
            decision.configuration.members.contains(where: { $0.replicaID == identity.replicaID })
        else { throw PersonalEnrollmentError.conflict() }
        let account = try store.personalEnrollmentResolvePrincipal(decision.administrator)
        // Deliberately no receiver-local administrator veto. The trusted source checked
        // that local administrator afresh when issuing this exact scoped decision.
        return .init(decision: decision, account: account, binding: binding)
    }
    package func revalidate(store: ItemStore) throws {
        let current = try Self.receive(store: store, binding: binding, decision: decision)
        guard current.localUID == localUID, current.localName == localName else {
            throw PersonalEnrollmentError.conflict()
        }
    }
    package func require(configuration: PersonalMembershipConfiguration, nonce: String,
        expectedDigest: String?, administrator: String) throws {
        guard decision.configuration == configuration, decision.nonce == nonce,
            decision.expectedMembershipDigest == expectedDigest,
            localName == administrator, localName == decision.administrator
        else { throw PersonalEnrollmentError.conflict() }
    }
}
