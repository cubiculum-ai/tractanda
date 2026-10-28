import Foundation

/// One exact current operation, including only logical admission names and explicit DNS
/// routes. No numeric OS identities, historical authorization snapshots or generic calls.
package struct PersonalEnrollmentPlan: Codable, Equatable, Sendable {
    package let operationID: String
    package let issuerReplicaID: String
    package let administrator: String
    package let nonce: String
    package let previousMembership: PersonalMembershipConfiguration?
    package let configuration: PersonalMembershipConfiguration
    package let admission: PersonalEnrollmentAdmission
    package let endpoints: [String: [PeerRuntimeConfiguration.Endpoint]]
    package init(operationID: String, issuerReplicaID: String, administrator: String, nonce: String,
        previousMembership: PersonalMembershipConfiguration?, configuration: PersonalMembershipConfiguration,
        admission: PersonalEnrollmentAdmission, endpoints: [String: [PeerRuntimeConfiguration.Endpoint]]) {
        self.operationID = operationID; self.issuerReplicaID = issuerReplicaID
        self.administrator = administrator; self.nonce = nonce; self.previousMembership = previousMembership
        self.configuration = configuration; self.admission = admission; self.endpoints = endpoints
    }
    package func validate() throws {
        try PersonalSyncValidation.identifier(operationID)
        try PersonalSyncValidation.identifier(issuerReplicaID)
        try PersonalSyncValidation.identifier(nonce)
        try PrincipalNames.validate(administrator)
        try previousMembership?.validate(); try configuration.validate(); try admission.validate()
        let members = Set(configuration.members.map(\.replicaID))
        guard members.contains(issuerReplicaID), Set(endpoints.keys) == members,
            previousMembership == nil || previousMembership?.storeID == configuration.storeID,
            try JSON.encode(self).count <= 320 * 1024 else { throw PersonalEnrollmentError.invalid() }
        for (replicaID, routes) in endpoints {
            guard routes.count <= 4, Set(routes.map { $0.host + ":" + String($0.port) }).count == routes.count else {
                throw PersonalEnrollmentError.invalid()
            }
            for endpoint in routes { _ = try PersonalMember(replicaID: replicaID, hostname: endpoint.host) }
        }
        _ = try PersonalEnrollmentCapacity.preflight(current: previousMembership, proposed: configuration,
            initiatingReplicaID: issuerReplicaID, runtimeSocketLimit: 64, tlsContextLimit: 256, credentialRoleLimit: 512)
        // The current qualification keeps direct authenticated presence between members.
        // At most one member can be outbound-only; no hidden relay/master is introduced.
        guard endpoints.values.filter({ $0.isEmpty }).count <= 1,
            endpoints[issuerReplicaID]?.isEmpty == false else {
            throw TractandaError("enrollmentTopologyUnsupported",
                "This native workflow needs a listening issuer and direct peer reachability; no policy or membership was changed.")
        }
    }
    package var digest: String { get throws { try validate(); return try PersonalSyncValidation.digest(JSON.encode(self)) } }
    package var decision: PersonalEnrollmentAdminDecision? {
        get throws {
            guard let previousMembership else { return nil }
            return .init(operationID: operationID, authorizingReplicaID: issuerReplicaID,
                administrator: administrator, expectedMembershipDigest: try previousMembership.digest,
                configuration: configuration, nonce: nonce)
        }
    }
    package static func decodeStrict(_ bytes: Data) throws -> Self {
        guard bytes.count <= 320 * 1024 else { throw PersonalEnrollmentError.invalid() }
        let object = try JSONSerialization.jsonObject(with: bytes)
        guard let fields = object as? [String: Any], Set(fields.keys).isSubset(of: [
            "operationID", "issuerReplicaID", "administrator", "nonce", "previousMembership", "configuration", "admission", "endpoints",
        ]) else { throw PersonalEnrollmentError.invalid() }
        let value = try JSON.decode(Self.self, bytes)
        try value.validate()
        // Decode through the common structured JMAP value first; formatting differences
        // are permitted, but unknown fields anywhere in these typed packets are not.
        let normalized = try JSONSerialization.jsonObject(with: JSON.encode(value))
        guard NSDictionary(dictionary: fields).isEqual(to: normalized as! [AnyHashable: Any]) else {
            throw PersonalEnrollmentError.invalid()
        }
        return value
    }
}

package struct PersonalEnrollmentRouteState: Codable, Equatable, Sendable {
    package let operationID: String
    package let configurationDigest: String
    package let endpoints: [String: [PeerRuntimeConfiguration.Endpoint]]
}

package struct PersonalEnrollmentMemberState: Codable, Equatable, Sendable {
    package enum Phase: String, Codable, Sendable { case prepared, committed, complete }
    package let plan: PersonalEnrollmentPlan
    package var phase: Phase
    package var preparation: PersonalMembershipPreparation?
}
