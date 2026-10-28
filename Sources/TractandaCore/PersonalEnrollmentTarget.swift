import Foundation

package struct PersonalEnrollmentTargetStatus: Codable, Equatable, Sendable {
    package enum Phase: String, Codable, Sendable { case claiming, claimed, prepared, copying, complete }
    package let invitation: PersonalEnrollmentInvitationMetadata
    package let claim: PersonalEnrollmentClaimMetadata
    package let administrator: String
    package var phase: Phase
    package let provisionalAdmissionDigest: String
    package var admission: PersonalEnrollmentAdmission?
    package var configuration: PersonalMembershipConfiguration?
    package var selectionID: String?
    package var plan: PersonalEnrollmentPlan?
}
package struct PersonalEnrollmentRenewalStatus: Codable, Equatable, Sendable {
    package let invitation: PersonalEnrollmentInvitationMetadata
    package let administrator: String
    package let hostname: String
}

/// Target continuation is persisted BEFORE claim. On a lost claim response, the target
/// already knows the continuation PSK and never reuses the single-use invitation to fetch it.
package struct PersonalEnrollmentTargetRegistry {
    private let files: PersonalEnrollmentStateFiles
    package init(root: URL) { files = .init(root: root) }
    private func renewal() throws -> (Data, PersonalEnrollmentRenewalStatus, PersonalEnrollmentSecret)? {
        guard let bytes = try files.read("renewal.bin") else { return nil }
        let (status, secret) = try PersonalEnrollmentPrivateCodec.decode(PersonalEnrollmentRenewalStatus.self, bytes: bytes)
        try status.invitation.validate(); try PrincipalNames.validate(status.administrator)
        let host = try PersonalMember(replicaID: status.invitation.issuerReplicaID, hostname: status.hostname).hostname
        guard host == status.hostname else { throw PersonalEnrollmentError.invalid() }
        return (bytes, status, secret)
    }
    private struct Record {
        var status: PersonalEnrollmentTargetStatus
        let invitationSecret: PersonalEnrollmentSecret?
        let continuationSecret: PersonalEnrollmentSecret?
        func encoded() throws -> Data {
            let header = try PersonalEnrollmentPrivateCodec.encode(status, secret: nil,
                maximumHeaderBytes: PersonalEnrollmentPrivateCodec.operationHeaderBytes)
            return header + (invitationSecret?.withBytes { Data($0) } ?? Data())
                + (continuationSecret?.withBytes { Data($0) } ?? Data())
        }
    }
    private func load(_ name: String = "target.bin") throws -> (Data, Record)? {
        guard let bytes = try files.read(name) else { return nil }
        guard bytes.count >= 4 else { throw PersonalEnrollmentError.invalid() }
        let count = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(count) <= bytes.count - 4 else { throw PersonalEnrollmentError.invalid() }
        let status = try JSON.decode(PersonalEnrollmentTargetStatus.self, Data(bytes.dropFirst(4).prefix(Int(count))))
        try status.invitation.validate(); try status.claim.validate(invitation: status.invitation)
        try PersonalSyncValidation.sha256(status.provisionalAdmissionDigest)
        try PrincipalNames.validate(status.administrator)
        try status.admission?.validate(); try status.configuration?.validate()
        try status.plan?.validate()
        if let plan = status.plan {
            guard plan.operationID == status.invitation.operationID,
                plan.issuerReplicaID == status.invitation.issuerReplicaID,
                plan.configuration == status.configuration, plan.admission == status.admission else { throw PersonalEnrollmentError.invalid() }
        }
        if let configuration = status.configuration {
            guard configuration.storeID == status.invitation.storeID,
                configuration.members.contains(where: { $0.replicaID == status.claim.targetReplicaID }),
                configuration.members.contains(where: { $0.replicaID == status.invitation.issuerReplicaID })
            else { throw PersonalEnrollmentError.invalid() }
        }
        if let selectionID = status.selectionID { try PersonalSyncValidation.identifier(selectionID) }
        let secrets = status.phase == .claiming ? 64 : status.phase == .complete ? 0 : 32
        _ = try PersonalEnrollmentPrivateCodec.decodeHeader(PersonalEnrollmentTargetStatus.self, bytes: bytes,
            secretCount: secrets, maximumHeaderBytes: PersonalEnrollmentPrivateCodec.operationHeaderBytes)
        let suffix = Data(bytes.suffix(secrets))
        let invite = status.phase == .claiming ? try PersonalEnrollmentSecret(bytes: Array(suffix.prefix(32))) : nil
        let continuation = secrets > 0 ? try PersonalEnrollmentSecret(bytes: Array(suffix.suffix(32))) : nil
        return (bytes, .init(status: status, invitationSecret: invite, continuationSecret: continuation))
    }
    private func authorize(_ record: Record, store: ItemStore, uid: UInt32) throws -> PersonalEnrollmentLocalAuthorization {
        let authorization = try PersonalEnrollmentLocalAuthorization.authorize(store: store, forUID: uid)
        guard authorization.administrator == record.status.administrator,
            authorization.identity.storeID == record.status.invitation.storeID,
            authorization.identity.replicaID == record.status.claim.targetReplicaID else {
            throw PersonalEnrollmentError.conflict()
        }
        return authorization
    }
    package func begin(store: ItemStore, forUID uid: UInt32, invitation: PersonalEnrollmentInvitation,
        hostname: String) throws -> PersonalEnrollmentTargetStatus {
        let canonicalHostname = try PersonalMember(replicaID: store.personalSyncIdentity().replicaID, hostname: hostname).hostname
        if let (_, record) = try load() {
            _ = try authorize(record, store: store, uid: uid)
            guard record.status.invitation == invitation.metadata, record.status.claim.targetHostname == canonicalHostname else {
                throw PersonalEnrollmentError.conflict()
            }
            return record.status
        }
        let authorization = try store.personalEnrollmentAuthorizeFreshTarget(forUID: uid,
            commonStoreID: invitation.metadata.storeID)
        let continuation = try PersonalEnrollmentSecret.generate()
        let claim = PersonalEnrollmentClaimMetadata(operationID: invitation.metadata.operationID,
            targetReplicaID: authorization.identity.replicaID, targetHostname: canonicalHostname,
            continuationPairingID: try UUID.makeVersion1().uuidString.lowercased())
        try claim.validate(invitation: invitation.metadata)
        let status = PersonalEnrollmentTargetStatus(invitation: invitation.metadata, claim: claim,
            administrator: authorization.administrator, phase: .claiming,
            provisionalAdmissionDigest: try store.personalEnrollmentAdmission(forUID: uid).digest)
        let record = Record(status: status, invitationSecret: invitation.secret, continuationSecret: continuation)
        try files.replace("target.bin", bytes: record.encoded(), expected: nil)
        return status
    }
    package func beginReplacement(store: ItemStore, forUID uid: UInt32, invitation: PersonalEnrollmentInvitation,
        hostname: String, now: Int64) throws -> PersonalEnrollmentTargetStatus {
        let authorization = try store.personalEnrollmentAuthorizeFreshTarget(forUID: uid, commonStoreID: invitation.metadata.storeID)
        guard let (_, current) = try load(), current.status.phase == .claiming,
            current.status.plan == nil, current.status.configuration == nil, current.status.admission == nil,
            current.status.selectionID == nil, now >= current.status.invitation.expiresAt,
            try store.personalEnrollmentPendingConfiguration() == nil,
            invitation.metadata.storeID == current.status.invitation.storeID,
            invitation.metadata.issuerReplicaID == current.status.invitation.issuerReplicaID,
            invitation.metadata.familyID == current.status.invitation.familyID,
            invitation.metadata.operationID != current.status.invitation.operationID else { throw PersonalEnrollmentError.conflict() }
        let canonical = try PersonalMember(replicaID: authorization.identity.replicaID, hostname: hostname).hostname
        guard canonical == current.status.claim.targetHostname else { throw PersonalEnrollmentError.conflict() }
        if let (_, replacement) = try load("replacement.bin") {
            guard replacement.status.claim.targetReplicaID == authorization.identity.replicaID else { throw PersonalEnrollmentError.conflict() }
            if replacement.status.invitation != invitation.metadata {
                guard replacement.status.phase == .claiming, replacement.status.plan == nil,
                    replacement.status.configuration == nil, replacement.status.admission == nil, replacement.status.selectionID == nil,
                    now >= replacement.status.invitation.expiresAt, invitation.metadata.expiresAt > now else { throw PersonalEnrollmentError.conflict() }
                let old = try files.read("renewal.bin")
                let probe = PersonalEnrollmentRenewalStatus(invitation: invitation.metadata,
                    administrator: authorization.administrator, hostname: canonical)
                try files.replace("renewal.bin", bytes: PersonalEnrollmentPrivateCodec.encode(probe, secret: invitation.secret), expected: old)
            }
            return replacement.status
        }
        let claim = PersonalEnrollmentClaimMetadata(operationID: invitation.metadata.operationID,
            targetReplicaID: authorization.identity.replicaID, targetHostname: canonical,
            continuationPairingID: try UUID.makeVersion1().uuidString.lowercased())
        try claim.validate(invitation: invitation.metadata)
        let status = PersonalEnrollmentTargetStatus(invitation: invitation.metadata, claim: claim,
            administrator: authorization.administrator, phase: .claiming,
            provisionalAdmissionDigest: current.status.provisionalAdmissionDigest)
        let candidate = Record(status: status, invitationSecret: invitation.secret,
            continuationSecret: try .generate())
        try files.replace("replacement.bin", bytes: candidate.encoded(), expected: nil)
        return status
    }
    package func renewalStatus(store: ItemStore) throws -> PersonalEnrollmentRenewalStatus? {
        guard let (_, probe, _) = try renewal() else { return nil }
        let identity = try store.personalSyncIdentity()
        guard identity.storeID == probe.invitation.storeID else { throw PersonalEnrollmentError.conflict() }
        return probe
    }
    package func renewalRuntimeMaterial(store: ItemStore) throws -> PersonalEnrollmentInvitation? {
        guard let (_, probe, secret) = try renewal() else { return nil }
        let identity = try store.personalSyncIdentity()
        guard identity.storeID == probe.invitation.storeID else { throw PersonalEnrollmentError.conflict() }
        return try .init(metadata: probe.invitation, secret: secret)
    }
    @discardableResult package func cleanupConfirmedRenewal(store: ItemStore) throws -> Bool {
        guard let (bytes, probe, _) = try renewal(), let (_, candidate) = try load("replacement.bin"),
            candidate.status.invitation == probe.invitation else { return false }
        let identity = try store.personalSyncIdentity()
        guard identity.storeID == candidate.status.invitation.storeID,
            identity.replicaID == candidate.status.claim.targetReplicaID else { throw PersonalEnrollmentError.conflict() }
        try files.remove("renewal.bin", expected: bytes)
        return true
    }
    /// A durable accepted continuation wins over future, still-unaccepted codes in the
    /// same unused family. Cleanup can resume after acknowledgement publication; it
    /// never promotes a candidate or changes membership, admission or baseline state.
    @discardableResult package func cleanupSupersededCandidates(store: ItemStore) throws -> Bool {
        guard let (_, current) = try load(), current.status.phase != .claiming else { return false }
        let identity = try store.personalSyncIdentity()
        guard identity.storeID == current.status.invitation.storeID,
            identity.replicaID == current.status.claim.targetReplicaID else { throw PersonalEnrollmentError.conflict() }
        let candidate = try load("replacement.bin"), probe = try renewal()
        if let (_, candidate) = candidate {
            guard candidate.status.phase == .claiming, candidate.status.plan == nil,
                candidate.status.configuration == nil, candidate.status.admission == nil, candidate.status.selectionID == nil,
                candidate.status.claim.targetReplicaID == current.status.claim.targetReplicaID,
                candidate.status.claim.targetHostname == current.status.claim.targetHostname,
                candidate.status.invitation.familyID == current.status.invitation.familyID,
                candidate.status.invitation.issuerReplicaID == current.status.invitation.issuerReplicaID,
                candidate.status.invitation.storeID == current.status.invitation.storeID else { throw PersonalEnrollmentError.conflict() }
        }
        if let (_, probe, _) = probe {
            guard probe.invitation.familyID == current.status.invitation.familyID,
                probe.invitation.issuerReplicaID == current.status.invitation.issuerReplicaID,
                probe.invitation.storeID == current.status.invitation.storeID,
                probe.hostname == current.status.claim.targetHostname else { throw PersonalEnrollmentError.conflict() }
        }
        if let (bytes, _, _) = probe { try files.remove("renewal.bin", expected: bytes) }
        if let (bytes, _) = candidate { try files.remove("replacement.bin", expected: bytes) }
        return candidate != nil || probe != nil
    }
    package func confirmRetainedContinuation(store: ItemStore, binding: PeerExchangeBinding) throws {
        guard let (_, current) = try load() else { throw PersonalEnrollmentError.conflict() }
        if current.status.claim.continuationPairingID == binding.pairingID {
            try continuationAccepted(store: store, binding: binding)
        } else {
            try promoteReplacement(store: store, binding: binding)
        }
        _ = try cleanupSupersededCandidates(store: store)
    }
    package func acceptAuthenticatedRenewal(store: ItemStore, binding: PeerExchangeBinding, control: PeerExchangeControl,
        afterPublication: () throws -> Void = {}) throws {
        try control.check()
        guard let (probeBytes, probe, secret) = try renewal(), let (candidateBytes, previous) = try load("replacement.bin"),
            let (_, original) = try load(), original.status.phase == .claiming, original.status.plan == nil,
            original.status.configuration == nil, original.status.admission == nil, original.status.selectionID == nil,
            previous.status.phase == .claiming, previous.status.plan == nil, previous.status.configuration == nil,
            previous.status.admission == nil, previous.status.selectionID == nil,
            probe.invitation.familyID == original.status.invitation.familyID,
            probe.invitation.familyID == previous.status.invitation.familyID,
            probe.invitation.issuerReplicaID == original.status.invitation.issuerReplicaID,
            probe.invitation.storeID == original.status.invitation.storeID,
            try store.personalEnrollmentPendingConfiguration() == nil else { throw PersonalEnrollmentError.conflict() }
        try store.personalEnrollmentRequireEmptyUnjoinedTarget(commonStoreID: probe.invitation.storeID)
        let invitation = try PersonalEnrollmentInvitation(metadata: probe.invitation, secret: secret)
        guard try PersonalEnrollmentPeerMaterial.invitation(invitation, localIsIssuer: false).binding == binding else { throw PersonalEnrollmentError.conflict() }
        let claim = PersonalEnrollmentClaimMetadata(operationID: probe.invitation.operationID,
            targetReplicaID: original.status.claim.targetReplicaID, targetHostname: probe.hostname,
            continuationPairingID: try UUID.makeVersion1().uuidString.lowercased())
        let status = PersonalEnrollmentTargetStatus(invitation: probe.invitation, claim: claim,
            administrator: probe.administrator, phase: .claiming,
            provisionalAdmissionDigest: original.status.provisionalAdmissionDigest)
        // A fresh continuation is generated/persisted only after actual unused-issuer
        // authentication. Neither the original nor pending continuation is dropped sooner.
        let candidate = Record(status: status, invitationSecret: secret, continuationSecret: try .generate())
        try files.replace("replacement.bin", bytes: candidate.encoded(), expected: candidateBytes,
            beforePublication: control.check)
        try afterPublication()
        try files.remove("renewal.bin", expected: probeBytes)
    }
    package func replacementRuntimeMaterial(store: ItemStore) throws
        -> (PersonalEnrollmentTargetStatus, PersonalEnrollmentInvitation?, PersonalEnrollmentClaim?)? {
        guard let (_, candidate) = try load("replacement.bin") else { return nil }
        let identity = try store.personalSyncIdentity()
        guard identity.storeID == candidate.status.invitation.storeID,
            identity.replicaID == candidate.status.claim.targetReplicaID else { throw PersonalEnrollmentError.conflict() }
        if let (_, current) = try load(), current.status.invitation == candidate.status.invitation {
            // Exact recovery after accepted current-record publication and before candidate
            // unlink. This removes a duplicate only; no unverified candidate is promoted.
            guard current.status.phase != .claiming, current.status.claim == candidate.status.claim else { throw PersonalEnrollmentError.conflict() }
            return nil
        }
        return try material(candidate)
    }
    package func replacementStatus(store: ItemStore) throws -> PersonalEnrollmentTargetStatus? {
        guard let (_, candidate) = try load("replacement.bin") else { return nil }
        let identity = try store.personalSyncIdentity()
        guard identity.storeID == candidate.status.invitation.storeID,
            identity.replicaID == candidate.status.claim.targetReplicaID else { throw PersonalEnrollmentError.conflict() }
        return candidate.status
    }
    @discardableResult package func cleanupAcceptedReplacement(store: ItemStore) throws -> Bool {
        guard let (bytes, candidate) = try load("replacement.bin"), let (_, current) = try load(),
            current.status.invitation == candidate.status.invitation,
            current.status.claim == candidate.status.claim, current.status.phase != .claiming else { return false }
        let identity = try store.personalSyncIdentity()
        guard identity.storeID == current.status.invitation.storeID,
            identity.replicaID == current.status.claim.targetReplicaID else { throw PersonalEnrollmentError.conflict() }
        try files.remove("replacement.bin", expected: bytes)
        return true
    }
    package func promoteReplacement(store: ItemStore, binding: PeerExchangeBinding,
        afterPublication: () throws -> Void = {}) throws {
        guard let (candidateBytes, candidate) = try load("replacement.bin"),
            let secret = candidate.continuationSecret,
            let (oldBytes, current) = try load(), current.status.phase == .claiming,
            current.status.plan == nil, current.status.configuration == nil, current.status.admission == nil,
            current.status.selectionID == nil,
            candidate.status.invitation.familyID == current.status.invitation.familyID,
            candidate.status.invitation.issuerReplicaID == current.status.invitation.issuerReplicaID,
            candidate.status.invitation.storeID == current.status.invitation.storeID,
            try store.personalEnrollmentPendingConfiguration() == nil else { throw PersonalEnrollmentError.conflict() }
        try store.personalEnrollmentRequireEmptyUnjoinedTarget(commonStoreID: candidate.status.invitation.storeID)
        let actual = try PersonalEnrollmentPeerMaterial.continuation(invitation: candidate.status.invitation,
            claim: .init(metadata: candidate.status.claim, continuationSecret: secret), localIsIssuer: false)
        guard actual.binding == binding else { throw PersonalEnrollmentError.conflict() }
        var accepted = candidate.status; accepted.phase = .claimed
        try files.replace("target.bin", bytes: Record(status: accepted, invitationSecret: nil,
            continuationSecret: secret).encoded(), expected: oldBytes)
        try afterPublication()
        try files.remove("replacement.bin", expected: candidateBytes)
    }
    package func status(store: ItemStore, forUID uid: UInt32) throws -> PersonalEnrollmentTargetStatus? {
        guard let (_, record) = try load() else { return nil }
        _ = try authorize(record, store: store, uid: uid)
        return record.status
    }
    /// Trusted host runtime only; the actual TLS purpose/pairing is checked before use.
    package func material(store: ItemStore, forUID uid: UInt32) throws
        -> (PersonalEnrollmentTargetStatus, PersonalEnrollmentInvitation?, PersonalEnrollmentClaim?)? {
        guard let (_, record) = try load() else { return nil }
        _ = try authorize(record, store: store, uid: uid)
        return try material(record)
    }
    package func runtimeMaterial(store: ItemStore) throws
        -> (PersonalEnrollmentTargetStatus, PersonalEnrollmentInvitation?, PersonalEnrollmentClaim?)? {
        guard let (_, record) = try load() else { return nil }
        let identity = try store.personalSyncIdentity()
        guard identity.storeID == record.status.invitation.storeID,
            identity.replicaID == record.status.claim.targetReplicaID else { throw PersonalEnrollmentError.conflict() }
        return try material(record)
    }
    private func material(_ record: Record) throws
        -> (PersonalEnrollmentTargetStatus, PersonalEnrollmentInvitation?, PersonalEnrollmentClaim?) {
        let invitation = try record.invitationSecret.map {
            try PersonalEnrollmentInvitation(metadata: record.status.invitation, secret: $0)
        }
        let continuation = record.continuationSecret.map {
            PersonalEnrollmentClaim(metadata: record.status.claim, continuationSecret: $0)
        }
        return (record.status, invitation, continuation)
    }
    package func acceptPlan(store: ItemStore, forUID uid: UInt32, plan: PersonalEnrollmentPlan) throws {
        try plan.validate()
        guard let (old, record) = try load(), record.status.phase != .claiming, record.status.phase != .complete,
            record.status.invitation.operationID == plan.operationID,
            record.status.invitation.issuerReplicaID == plan.issuerReplicaID,
            plan.configuration.storeID == record.status.invitation.storeID,
            plan.configuration.members.contains(where: { $0.replicaID == record.status.claim.targetReplicaID && $0.hostname == record.status.claim.targetHostname }),
            record.status.plan == nil || record.status.plan == plan,
            record.status.configuration == nil || record.status.configuration == plan.configuration,
            record.status.admission == nil || record.status.admission == plan.admission else { throw PersonalEnrollmentError.conflict() }
        _ = try authorize(record, store: store, uid: uid)
        var next = record
        next.status.plan = plan; next.status.admission = plan.admission; next.status.configuration = plan.configuration
        try files.replace("target.bin", bytes: next.encoded(), expected: old)
        try store.personalEnrollmentAdoptAcceptedAdmission(plan.admission, operationID: plan.operationID, forUID: uid)
    }
    package func acceptRuntimePlan(store: ItemStore, binding: PeerExchangeBinding, plan: PersonalEnrollmentPlan) throws {
        try plan.validate()
        guard let (old, record) = try load(), record.status.phase != .claiming, record.status.phase != .complete,
            let continuation = record.continuationSecret,
            record.status.invitation.operationID == plan.operationID,
            record.status.invitation.issuerReplicaID == plan.issuerReplicaID,
            plan.configuration.storeID == record.status.invitation.storeID,
            plan.configuration.members.contains(where: { $0.replicaID == record.status.claim.targetReplicaID && $0.hostname == record.status.claim.targetHostname }),
            try record.status.invitation.expectedMembershipDigest == plan.previousMembership?.digest,
            record.status.plan == nil || record.status.plan == plan,
            record.status.configuration == nil || record.status.configuration == plan.configuration,
            record.status.admission == nil || record.status.admission == plan.admission else { throw PersonalEnrollmentError.conflict() }
        let material = try PersonalEnrollmentPeerMaterial.continuation(invitation: record.status.invitation,
            claim: .init(metadata: record.status.claim, continuationSecret: continuation), localIsIssuer: false)
        guard material.binding == binding else { throw PersonalEnrollmentError.conflict() }
        var next = record
        next.status.plan = plan; next.status.admission = plan.admission; next.status.configuration = plan.configuration
        try files.replace("target.bin", bytes: next.encoded(), expected: old)
        let authorization = try PersonalEnrollmentMembershipAuthorization.target(store: store, binding: binding, plan: plan)
        try store.personalEnrollmentAdoptAcceptedAdmission(plan.admission, authorization: authorization)
    }
    package func continuationAccepted(store: ItemStore, forUID uid: UInt32,
        issuerReplicaID: String, pairingID: String, operationID: String) throws {
        guard let (old, record) = try load() else { throw PersonalEnrollmentError.conflict() }
        _ = try authorize(record, store: store, uid: uid)
        guard record.status.invitation.operationID == operationID,
            record.status.invitation.issuerReplicaID == issuerReplicaID,
            record.status.claim.continuationPairingID == pairingID else { throw PersonalEnrollmentError.conflict() }
        if record.status.phase != .claiming { return }
        var next = record
        next.status.phase = .claimed
        let consumed = Record(status: next.status, invitationSecret: nil, continuationSecret: record.continuationSecret)
        try files.replace("target.bin", bytes: consumed.encoded(), expected: old)
    }
    package func continuationAccepted(store: ItemStore, binding: PeerExchangeBinding) throws {
        guard let (old, record) = try load(), let secret = record.continuationSecret else { throw PersonalEnrollmentError.conflict() }
        let material = try PersonalEnrollmentPeerMaterial.continuation(invitation: record.status.invitation,
            claim: .init(metadata: record.status.claim, continuationSecret: secret), localIsIssuer: false)
        let identity = try store.personalSyncIdentity()
        guard material.binding == binding, identity.storeID == record.status.invitation.storeID,
            identity.replicaID == record.status.claim.targetReplicaID else { throw PersonalEnrollmentError.conflict() }
        if record.status.phase != .claiming { return }
        var next = record; next.status.phase = .claimed
        try files.replace("target.bin", bytes: Record(status: next.status, invitationSecret: nil,
            continuationSecret: record.continuationSecret).encoded(), expected: old)
    }
    package func acceptPlan(store: ItemStore, forUID uid: UInt32, operationID: String,
        admission: PersonalEnrollmentAdmission, configuration: PersonalMembershipConfiguration) throws {
        guard let (old, record) = try load(), record.status.phase != .complete, record.status.phase != .claiming,
            record.status.invitation.operationID == operationID else { throw PersonalEnrollmentError.conflict() }
        _ = try authorize(record, store: store, uid: uid)
        try admission.validate(); try configuration.validate()
        guard configuration.members.count <= PersonalEnrollmentCapacity.maximumQualifiedMembers else {
            throw TractandaError("enrollmentCapacityUnsupported", "Native enrollment currently supports at most 16 members; target policy was not changed.")
        }
        guard configuration.storeID == record.status.invitation.storeID,
            configuration.members.contains(where: { $0.replicaID == record.status.claim.targetReplicaID && $0.hostname == record.status.claim.targetHostname }),
            configuration.members.contains(where: { $0.replicaID == record.status.invitation.issuerReplicaID }),
            record.status.admission == nil || record.status.admission == admission,
            record.status.configuration == nil || record.status.configuration == configuration else {
            throw PersonalEnrollmentError.conflict()
        }
        // Persist this exact accepted source plan before changing the provisional policy.
        // A crash retries the same admission/configuration, never a different source plan.
        var next = record
        next.status.admission = admission; next.status.configuration = configuration
        try files.replace("target.bin", bytes: next.encoded(), expected: old)
        try store.personalEnrollmentAdoptAcceptedAdmission(admission, operationID: operationID, forUID: uid)
    }
    package func selectedBaseline(store: ItemStore, forUID uid: UInt32, operationID: String,
        selectionID: String) throws {
        guard let (old, record) = try load(), record.status.invitation.operationID == operationID,
            record.status.configuration != nil, record.status.admission != nil else { throw PersonalEnrollmentError.conflict() }
        _ = try authorize(record, store: store, uid: uid)
        try PersonalSyncValidation.identifier(selectionID)
        guard record.status.selectionID == nil || record.status.selectionID == selectionID else { throw PersonalEnrollmentError.conflict() }
        var next = record; next.status.selectionID = selectionID; next.status.phase = .copying
        try files.replace("target.bin", bytes: next.encoded(), expected: old)
    }
    package func selectedBaseline(store: ItemStore, selectionID: String,
        authorization: PersonalEnrollmentMembershipAuthorization) throws {
        try authorization.revalidate(store: store)
        guard let (old, record) = try load(), record.status.plan == authorization.plan,
            record.status.selectionID == nil || record.status.selectionID == selectionID else { throw PersonalEnrollmentError.conflict() }
        try PersonalSyncValidation.identifier(selectionID)
        var next = record; next.status.selectionID = selectionID; next.status.phase = .prepared
        try files.replace("target.bin", bytes: next.encoded(), expected: old)
    }
    package func membershipCommitted(store: ItemStore, authorization: PersonalEnrollmentMembershipAuthorization) throws {
        try authorization.revalidate(store: store)
        guard let (old, record) = try load(), record.status.plan == authorization.plan,
            try store.personalSyncIdentity().membership == authorization.plan.configuration else { throw PersonalEnrollmentError.conflict() }
        if record.status.phase == .complete || record.status.phase == .copying { return }
        var next = record; next.status.phase = .copying
        try files.replace("target.bin", bytes: next.encoded(), expected: old)
    }
    package func complete(store: ItemStore, forUID uid: UInt32, operationID: String) throws {
        guard let (old, record) = try load(), record.status.invitation.operationID == operationID,
            let membership = record.status.configuration, record.status.selectionID != nil,
            !store.isPersonalBaselinePending else { throw PersonalEnrollmentError.conflict() }
        let authorization = try authorize(record, store: store, uid: uid)
        guard authorization.identity.membership == membership else { throw PersonalEnrollmentError.conflict() }
        var next = record; next.status.phase = .complete
        let finished = Record(status: next.status, invitationSecret: nil, continuationSecret: nil)
        try files.replace("target.bin", bytes: finished.encoded(), expected: old)
    }
    package func complete(store: ItemStore, authorization: PersonalEnrollmentMembershipAuthorization) throws {
        try authorization.revalidate(store: store)
        guard let (old, record) = try load(), record.status.plan == authorization.plan,
            record.status.selectionID != nil, !store.isPersonalBaselinePending,
            try store.personalSyncIdentity().membership == authorization.plan.configuration else { throw PersonalEnrollmentError.conflict() }
        var next = record; next.status.phase = .complete
        try files.replace("target.bin", bytes: Record(status: next.status, invitationSecret: nil,
            continuationSecret: nil).encoded(), expected: old)
    }
    package func acceptedAdmission(operationID: String) throws -> (PersonalEnrollmentTargetStatus, PersonalEnrollmentAdmission) {
        guard let (_, record) = try load(), record.status.invitation.operationID == operationID,
            let admission = record.status.admission else { throw PersonalEnrollmentError.conflict() }
        return (record.status, admission)
    }
}
