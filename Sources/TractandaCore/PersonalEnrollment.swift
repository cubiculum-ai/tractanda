import Foundation

/// Public invitation routing and identity only. The copyable code's secret is deliberately
/// not Codable and cannot be included in ordinary status/CLI output by accident.
public struct PersonalEnrollmentInvitationMetadata: Codable, Equatable, Sendable {
    public let profile: String
    public let operationID: String
    public let storeID: String
    public let issuerReplicaID: String
    public let bootstrapReplicaID: String
    public let pairingID: String
    public let endpoints: [PeerRuntimeConfiguration.Endpoint]
    public let expiresAt: Int64
    public let expectedMembershipDigest: String?
    /// Stable only across successive expired, never-claimed invitations. Accepted
    /// operation metadata is immutable; a later completed workflow starts a new family.
    public let unusedFamilyID: String?
    public var familyID: String { unusedFamilyID ?? operationID }

    package init(
        operationID: String, storeID: String, issuerReplicaID: String,
        bootstrapReplicaID: String, pairingID: String,
        endpoints: [PeerRuntimeConfiguration.Endpoint], expiresAt: Int64,
        expectedMembershipDigest: String?, unusedFamilyID: String? = nil
    ) throws {
        profile = "tractanda.personal-enrollment-invitation.v1"
        self.operationID = operationID
        self.storeID = storeID
        self.issuerReplicaID = issuerReplicaID
        self.bootstrapReplicaID = bootstrapReplicaID
        self.pairingID = pairingID
        self.endpoints = endpoints
        self.expiresAt = expiresAt
        self.expectedMembershipDigest = expectedMembershipDigest
        self.unusedFamilyID = unusedFamilyID ?? operationID
        try validate()
    }
    public func validate() throws {
        guard profile == "tractanda.personal-enrollment-invitation.v1", expiresAt > 0,
            (1...4).contains(endpoints.count),
            Set(endpoints.map { $0.host + ":" + String($0.port) }).count == endpoints.count
        else { throw PersonalEnrollmentError.invalid() }
        for id in [operationID, storeID, issuerReplicaID, bootstrapReplicaID, pairingID] {
            try PersonalSyncValidation.identifier(id)
        }
        guard Set([storeID, issuerReplicaID, bootstrapReplicaID]).count == 3 else {
            throw PersonalEnrollmentError.invalid()
        }
        if let expectedMembershipDigest { try PersonalSyncValidation.sha256(expectedMembershipDigest) }
        if let unusedFamilyID { try PersonalSyncValidation.identifier(unusedFamilyID) }
        for endpoint in endpoints {
            _ = try PersonalMember(replicaID: issuerReplicaID, hostname: endpoint.host)
        }
    }
}

package enum PersonalEnrollmentError {
    package static func invalid() -> TractandaError {
        .init("invalidEnrollmentInput", "Invalid private enrollment input.")
    }
    package static func conflict() -> TractandaError {
        .init("enrollmentConflict", "Resume the exact current enrollment operation.")
    }
}

/// Explicit private-channel material. Like the established PeerCredential, supplied copies
/// remain caller-owned. No reflection, Codable or ordinary diagnostic reveals these bytes.
package final class PersonalEnrollmentSecret: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    private let bytes: [UInt8]
    package init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw PersonalEnrollmentError.invalid() }
        self.bytes = bytes
    }
    package static func generate() throws -> PersonalEnrollmentSecret {
        var generator = SystemRandomNumberGenerator()
        return try .init(bytes: (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
    package func withBytes<T>(_ body: ([UInt8]) throws -> T) rethrows -> T { try body(bytes) }
    package var description: String { "PersonalEnrollmentSecret(<redacted>)" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

/// A code may be read/displayed only through an explicitly private product action.
/// Setup may parse it but only public metadata is available to its ordinary receipts.
public final class PersonalEnrollmentInvitation: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let metadata: PersonalEnrollmentInvitationMetadata
    package let secret: PersonalEnrollmentSecret
    package init(metadata: PersonalEnrollmentInvitationMetadata, secret: PersonalEnrollmentSecret) throws {
        try metadata.validate()
        self.metadata = metadata
        self.secret = secret
    }
    public static func parsePrivateCode(_ code: String) throws -> PersonalEnrollmentInvitation {
        guard code.utf8.count <= 12 * 1024, code.hasPrefix("tractanda-pair-v1.") else {
            throw PersonalEnrollmentError.invalid()
        }
        let encoded = String(code.dropFirst("tractanda-pair-v1.".count))
        guard let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded else {
            throw PersonalEnrollmentError.invalid()
        }
        let (metadata, secret) = try PersonalEnrollmentPrivateCodec.decode(
            PersonalEnrollmentInvitationMetadata.self, bytes: bytes)
        return try .init(metadata: metadata, secret: secret)
    }
    /// Never feed this result to ordinary JSON/stdout; only TTY or an owned private file.
    package func privateCode() throws -> String {
        "tractanda-pair-v1."
            + (try PersonalEnrollmentPrivateCodec.encode(metadata, secret: secret)).base64EncodedString()
    }
    public var description: String { "PersonalEnrollmentInvitation(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

package struct PersonalEnrollmentClaimMetadata: Codable, Equatable, Sendable {
    package let operationID: String
    package let targetReplicaID: String
    package let targetHostname: String
    package let continuationPairingID: String
    package func validate(invitation: PersonalEnrollmentInvitationMetadata) throws {
        try PersonalSyncValidation.identifier(operationID)
        try PersonalSyncValidation.identifier(continuationPairingID)
        let member = try PersonalMember(replicaID: targetReplicaID, hostname: targetHostname)
        guard operationID == invitation.operationID,
            targetHostname == member.hostname,
            ![invitation.storeID, invitation.issuerReplicaID, invitation.bootstrapReplicaID].contains(
                targetReplicaID),
            continuationPairingID != invitation.pairingID
        else { throw PersonalEnrollmentError.invalid() }
    }
}

package final class PersonalEnrollmentClaim: Sendable, CustomStringConvertible, CustomReflectable {
    package let metadata: PersonalEnrollmentClaimMetadata
    package let continuationSecret: PersonalEnrollmentSecret
    package init(metadata: PersonalEnrollmentClaimMetadata, continuationSecret: PersonalEnrollmentSecret) {
        self.metadata = metadata
        self.continuationSecret = continuationSecret
    }
    package func privateEncodedBytes() throws -> Data {
        try PersonalEnrollmentPrivateCodec.encode(metadata, secret: continuationSecret)
    }
    package static func decodePrivate(_ bytes: Data) throws -> PersonalEnrollmentClaim {
        let (metadata, secret) = try PersonalEnrollmentPrivateCodec.decode(
            PersonalEnrollmentClaimMetadata.self, bytes: bytes)
        return .init(metadata: metadata, continuationSecret: secret)
    }
    package var description: String { "PersonalEnrollmentClaim(<redacted>)" }
    package var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
}

package enum PersonalEnrollmentPrivateCodec {
    package static let operationHeaderBytes = 384 * 1024
    package static func encode<T: Encodable>(
        _ metadata: T, secret: PersonalEnrollmentSecret?,
        maximumHeaderBytes: Int = 12 * 1024
    ) throws -> Data {
        let header = try JSON.encode(metadata)
        guard header.count <= maximumHeaderBytes else { throw PersonalEnrollmentError.invalid() }
        let count = UInt32(header.count)
        let prefix = Data([
            UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255),
        ])
        return prefix + header + (secret?.withBytes { Data($0) } ?? Data())
    }
    package static func decode<T: Codable>(_ type: T.Type, bytes: Data) throws -> (
        T, PersonalEnrollmentSecret
    ) {
        let (metadata, suffix) = try decodeHeader(type, bytes: bytes, secretCount: 32)
        return (metadata, try .init(bytes: Array(suffix)))
    }
    package static func decodeHeader<T: Codable>(
        _ type: T.Type, bytes: Data, secretCount: Int,
        maximumHeaderBytes: Int = 12 * 1024
    ) throws -> (T, Data) {
        guard bytes.count >= 4 + secretCount, bytes.count <= maximumHeaderBytes + 4 + secretCount else {
            throw PersonalEnrollmentError.invalid()
        }
        let count = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(count) == bytes.count - 4 - secretCount else { throw PersonalEnrollmentError.invalid() }
        let header = Data(bytes.dropFirst(4).prefix(Int(count)))
        let metadata = try JSON.decode(type, header)
        guard try JSON.encode(metadata) == header else { throw PersonalEnrollmentError.invalid() }
        return (metadata, Data(bytes.suffix(secretCount)))
    }
}

/// Only a fresh actual local administrator check constructs this witness. It is not Codable
/// or caller-supplied and grants only enrollment transitions for one current local identity.
package struct PersonalEnrollmentLocalAuthorization: Sendable {
    package let identity: PersonalSyncIdentity
    package let administrator: String
    private init(identity: PersonalSyncIdentity, administrator: String) {
        self.identity = identity
        self.administrator = administrator
    }
    package static func authorize(store: ItemStore, forUID uid: UInt32) throws -> Self {
        try store.withAccess(forUID: uid) {
            try store.requireAdministrator()
            return try .init(
                identity: store.personalSyncIdentity(), administrator: store.accountIdentity(forUID: uid).name
            )
        }
    }
}

package struct PersonalEnrollmentIssuerStatus: Codable, Equatable, Sendable {
    package enum Phase: String, Codable, Sendable { case invitation, claimed, cancelled, complete }
    package let phase: Phase
    package let invitation: PersonalEnrollmentInvitationMetadata
    package let administrator: String
    package let claim: PersonalEnrollmentClaimMetadata?
    package let resultingMembership: PersonalMembershipConfiguration?
    package init(
        phase: Phase, invitation: PersonalEnrollmentInvitationMetadata, administrator: String,
        claim: PersonalEnrollmentClaimMetadata?, resultingMembership: PersonalMembershipConfiguration? = nil
    ) {
        self.phase = phase
        self.invitation = invitation
        self.administrator = administrator
        self.claim = claim
        self.resultingMembership = resultingMembership
    }
}

/// Serialized by the Store's existing lifetime writer/coordinator. One current operation;
/// no authorization history. An atomic state replacement consumes the code and publishes
/// its exact continuation together, so a lost claim reply needs no invitation replay.
package struct PersonalEnrollmentRegistry {
    private let files: DocumentContentFiles
    package init(root: URL, ownerUID: UInt32, minimumFreeBytes: Int64 = 10 * 1024 * 1024 * 1024) {
        files = .init(root: root, ownerUID: ownerUID, minimumFreeBytes: minimumFreeBytes)
    }
    private func load() throws -> (Data, PersonalEnrollmentIssuerStatus, PersonalEnrollmentSecret?)? {
        guard let bytes = try files.readPersonalEnrollmentState() else { return nil }
        // Phase is public metadata, but only the private reader inspects this bounded header.
        guard bytes.count >= 4 else { throw PersonalEnrollmentError.invalid() }
        let count = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(count) <= bytes.count - 4 else { throw PersonalEnrollmentError.invalid() }
        let status = try JSON.decode(
            PersonalEnrollmentIssuerStatus.self, Data(bytes.dropFirst(4).prefix(Int(count))))
        try status.invitation.validate()
        guard !status.administrator.isEmpty, status.administrator.utf8.count <= 255,
            !status.administrator.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else { throw PersonalEnrollmentError.invalid() }
        let hasSecret = status.phase == .invitation || status.phase == .claimed
        let (checked, suffix) = try PersonalEnrollmentPrivateCodec.decodeHeader(
            PersonalEnrollmentIssuerStatus.self, bytes: bytes, secretCount: hasSecret ? 32 : 0,
            maximumHeaderBytes: PersonalEnrollmentPrivateCodec.operationHeaderBytes)
        guard checked == status, (status.phase == .claimed) == (status.claim != nil) || !hasSecret else {
            throw PersonalEnrollmentError.invalid()
        }
        try status.claim?.validate(invitation: status.invitation)
        if let resulting = status.resultingMembership {
            try resulting.validate()
            guard resulting.storeID == status.invitation.storeID, let target = status.claim,
                resulting.members.contains(where: {
                    $0.replicaID == target.targetReplicaID && $0.hostname == target.targetHostname
                }),
                resulting.members.contains(where: { $0.replicaID == status.invitation.issuerReplicaID })
            else { throw PersonalEnrollmentError.invalid() }
        }
        return (bytes, status, hasSecret ? try .init(bytes: Array(suffix)) : nil)
    }
    private func check(
        _ authorization: PersonalEnrollmentLocalAuthorization,
        status: PersonalEnrollmentIssuerStatus, allowExactResult: Bool = false
    ) throws {
        let identity = authorization.identity
        let expected = try identity.membership?.digest == status.invitation.expectedMembershipDigest
        let exactResult =
            allowExactResult && status.resultingMembership != nil
            && identity.membership == status.resultingMembership
        guard identity.storeID == status.invitation.storeID,
            identity.replicaID == status.invitation.issuerReplicaID,
            expected || exactResult,
            authorization.administrator == status.administrator
        else { throw PersonalEnrollmentError.conflict() }
    }
    package func issue(
        authorization: PersonalEnrollmentLocalAuthorization,
        endpoints: [PeerRuntimeConfiguration.Endpoint], now: Int64, lifetimeSeconds: Int64 = 600
    ) throws -> PersonalEnrollmentInvitation {
        guard now > 0, (1...3600).contains(lifetimeSeconds), now <= Int64.max - lifetimeSeconds else {
            throw PersonalEnrollmentError.invalid()
        }
        let old = try load()
        if let (_, status, _) = old,
            status.phase == .claimed || (status.phase == .invitation && now < status.invitation.expiresAt)
        {
            throw PersonalEnrollmentError.conflict()
        }
        func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        let metadata = try PersonalEnrollmentInvitationMetadata(
            operationID: id(),
            storeID: authorization.identity.storeID, issuerReplicaID: authorization.identity.replicaID,
            bootstrapReplicaID: id(), pairingID: id(), endpoints: endpoints, expiresAt: now + lifetimeSeconds,
            expectedMembershipDigest: authorization.identity.membership?.digest,
            unusedFamilyID: old.flatMap { _, status, _ in
                status.phase == .invitation && now >= status.invitation.expiresAt
                    && status.invitation.storeID == authorization.identity.storeID
                    && status.invitation.issuerReplicaID == authorization.identity.replicaID
                    ? status.invitation.familyID : nil
            })
        let secret = try PersonalEnrollmentSecret.generate()
        let status = PersonalEnrollmentIssuerStatus(
            phase: .invitation, invitation: metadata,
            administrator: authorization.administrator, claim: nil)
        try files.replacePersonalEnrollmentState(
            PersonalEnrollmentPrivateCodec.encode(
                status, secret: secret,
                maximumHeaderBytes: PersonalEnrollmentPrivateCodec.operationHeaderBytes), expected: old?.0)
        return try .init(metadata: metadata, secret: secret)
    }
    package func status(authorization: PersonalEnrollmentLocalAuthorization) throws
        -> PersonalEnrollmentIssuerStatus?
    {
        guard let (_, status, _) = try load() else { return nil }
        try check(authorization, status: status, allowExactResult: true)
        return status
    }
    package func invitationCredential(now: Int64) throws -> PersonalEnrollmentInvitation? {
        guard let (_, status, secret) = try load(), status.phase == .invitation,
            now < status.invitation.expiresAt, let secret
        else { return nil }
        return try .init(metadata: status.invitation, secret: secret)
    }
    package func claim(
        _ claim: PersonalEnrollmentClaim,
        authenticatedInvitation: PersonalEnrollmentInvitationMetadata,
        authorization: PersonalEnrollmentLocalAuthorization, now: Int64
    ) throws -> PersonalEnrollmentIssuerStatus {
        guard now > 0, let (old, status, _) = try load(), status.phase == .invitation,
            authenticatedInvitation == status.invitation
        else { throw PersonalEnrollmentError.conflict() }
        try check(authorization, status: status)
        guard now < status.invitation.expiresAt else {
            throw TractandaError("invitationExpired", "The unused pairing invitation expired.")
        }
        try claim.metadata.validate(invitation: status.invitation)
        let next = PersonalEnrollmentIssuerStatus(
            phase: .claimed, invitation: status.invitation,
            administrator: status.administrator, claim: claim.metadata)
        try files.replacePersonalEnrollmentState(
            PersonalEnrollmentPrivateCodec.encode(
                next, secret: claim.continuationSecret,
                maximumHeaderBytes: PersonalEnrollmentPrivateCodec.operationHeaderBytes), expected: old)
        return next
    }
    package func continuationCredential() throws -> PersonalEnrollmentClaim? {
        guard let (_, status, secret) = try load(), status.phase == .claimed,
            let metadata = status.claim, let secret
        else { return nil }
        return .init(metadata: metadata, continuationSecret: secret)
    }
    /// Host-private material inspection; no native/HTTP/MCP diagnostic route exposes it.
    package func runtimeStatus() throws -> PersonalEnrollmentIssuerStatus? { try load()?.1 }
    package func stageMembershipProposal(
        authorization: PersonalEnrollmentLocalAuthorization,
        configuration: PersonalMembershipConfiguration
    ) throws {
        guard let (old, status, secret) = try load(), status.phase == .claimed,
            let claim = status.claim, let secret
        else { throw PersonalEnrollmentError.conflict() }
        try check(authorization, status: status)
        try configuration.validate()
        let oldMembers = authorization.identity.membership?.members ?? []
        let oldIDs = Set(oldMembers.map(\.replicaID)).union([authorization.identity.replicaID])
        guard configuration.storeID == status.invitation.storeID,
            Set(configuration.members.map(\.replicaID)) == oldIDs.union([claim.targetReplicaID]),
            !oldIDs.contains(claim.targetReplicaID),
            oldMembers.allSatisfy({ configuration.members.contains($0) }),
            configuration.members.contains(where: {
                $0.replicaID == claim.targetReplicaID && $0.hostname == claim.targetHostname
            }),
            status.resultingMembership == nil || status.resultingMembership == configuration
        else { throw PersonalEnrollmentError.conflict() }
        let next = PersonalEnrollmentIssuerStatus(
            phase: .claimed, invitation: status.invitation,
            administrator: status.administrator, claim: claim, resultingMembership: configuration)
        try files.replacePersonalEnrollmentState(
            PersonalEnrollmentPrivateCodec.encode(
                next, secret: secret,
                maximumHeaderBytes: PersonalEnrollmentPrivateCodec.operationHeaderBytes), expected: old)
    }
    package func finish(
        authorization: PersonalEnrollmentLocalAuthorization, operationID: String, cancelled: Bool
    ) throws {
        guard let (old, status, _) = try load(), status.invitation.operationID == operationID else {
            throw PersonalEnrollmentError.conflict()
        }
        try check(authorization, status: status, allowExactResult: !cancelled)
        if cancelled {
            // Once a proposal is distributed, another member might already have committed.
            // Cancellation then needs the coordinated job, never this local secret cleanup.
            guard status.resultingMembership == nil else { throw PersonalEnrollmentError.conflict() }
        } else {
            guard status.phase == .claimed, let resulting = status.resultingMembership,
                authorization.identity.membership == resulting
            else { throw PersonalEnrollmentError.conflict() }
        }
        let next = PersonalEnrollmentIssuerStatus(
            phase: cancelled ? .cancelled : .complete,
            invitation: status.invitation, administrator: status.administrator, claim: status.claim,
            resultingMembership: status.resultingMembership)
        try files.replacePersonalEnrollmentState(
            PersonalEnrollmentPrivateCodec.encode(
                next, secret: nil,
                maximumHeaderBytes: PersonalEnrollmentPrivateCodec.operationHeaderBytes), expected: old)
    }
}
