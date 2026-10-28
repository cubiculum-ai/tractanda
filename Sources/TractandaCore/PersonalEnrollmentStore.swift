import Foundation

package struct PersonalEnrollmentSourceSnapshot: Sendable {
    package let identity: PersonalSyncIdentity
    package let admission: PersonalEnrollmentAdmission
    package let issuer: PersonalEnrollmentIssuerStatus?
    package let job: PersonalEnrollmentSourceJob?
}

extension ItemStore {
    package func personalEnrollmentSourceSnapshot(forUID uid: UInt32) throws -> PersonalEnrollmentSourceSnapshot {
        let authorization = try PersonalEnrollmentLocalAuthorization.authorize(store: self, forUID: uid)
        return try .init(identity: authorization.identity, admission: personalEnrollmentAdmission(forUID: uid),
            issuer: PersonalEnrollmentRegistry(root: root, ownerUID: ownerUID).runtimeStatus(),
            job: PersonalEnrollmentJobRegistry(root: root).job())
    }
    package func personalEnrollmentIssue(forUID uid: UInt32, endpoints: [PeerRuntimeConfiguration.Endpoint], now: Int64,
        expectedUnusedOperationID: String? = nil) throws
        -> PersonalEnrollmentInvitation {
        let authorization = try PersonalEnrollmentLocalAuthorization.authorize(store: self, forUID: uid)
        guard !isPersonalBaselinePending else { throw TractandaError("invalidEnrollmentTarget", "An unjoined target cannot issue cluster invitations.") }
        if let target = try PersonalEnrollmentTargetRegistry(root: root).runtimeMaterial(store: self)?.0, target.phase != .complete {
            throw TractandaError("enrollmentConflict", "Finish the current exact join before issuing another invitation.")
        }
        let registry = PersonalEnrollmentRegistry(root: root, ownerUID: ownerUID)
        let jobs = PersonalEnrollmentJobRegistry(root: root)
        let admission = try personalEnrollmentAdmission(forUID: uid)
        let oldJob = try jobs.job()
        if let expectedUnusedOperationID {
            guard let current = try registry.runtimeStatus(), current.phase == .invitation,
                current.invitation.operationID == expectedUnusedOperationID,
                try registry.invitationCredential(now: now) != nil else {
                throw TractandaError("invitationExpired", "The exact still-unused invitation is unavailable; no new grant was created.")
            }
        }
        if let status = try registry.runtimeStatus(), status.phase == .invitation,
            let invitation = try registry.invitationCredential(now: now) {
            _ = try registry.status(authorization: authorization)
            guard status.invitation.endpoints == endpoints else { throw PersonalEnrollmentError.conflict() }
            if let oldJob, oldJob.invitation.operationID == status.invitation.operationID {
                guard oldJob.administrator == authorization.administrator, oldJob.admission == admission,
                    oldJob.phase == .awaitingTarget else { throw PersonalEnrollmentError.conflict() }
            } else {
                try jobs.write(.init(invitation: invitation.metadata, administrator: authorization.administrator,
                    admission: admission, phase: .awaitingTarget), replacing: oldJob)
            }
            return invitation
        }
        if let oldJob, oldJob.phase != .complete, let status = try registry.runtimeStatus(), status.phase == .complete {
            throw TractandaError("enrollmentConflict", "Finish the previous exact operation cleanup before issuing another invitation.")
        }
        let invitation = try registry.issue(authorization: authorization, endpoints: endpoints, now: now)
        try jobs.write(.init(invitation: invitation.metadata, administrator: authorization.administrator,
            admission: admission, phase: .awaitingTarget), replacing: oldJob)
        return invitation
    }
    package func personalEnrollmentRuntimeMaterial(now: Int64) throws -> PersonalEnrollmentRuntimeMaterial {
        var privatePeers: [PersonalEnrollmentPeerMaterial] = []
        let issuer = PersonalEnrollmentRegistry(root: root, ownerUID: ownerUID)
        if let status = try issuer.runtimeStatus(), status.phase == .invitation || status.phase == .claimed {
            let administrator = try personalEnrollmentResolvePrincipal(status.administrator)
            let authorization = try PersonalEnrollmentLocalAuthorization.authorize(store: self, forUID: administrator.uid)
            _ = try issuer.status(authorization: authorization)
            if let invitation = try issuer.invitationCredential(now: now) {
                privatePeers.append(try .invitation(invitation, localIsIssuer: true))
            }
            if let continuation = try issuer.continuationCredential() {
                privatePeers.append(try .continuation(invitation: status.invitation, claim: continuation, localIsIssuer: true))
            }
        }
        let targetRegistry = PersonalEnrollmentTargetRegistry(root: root)
        let replacement = try targetRegistry.replacementRuntimeMaterial(store: self)
        let renewal = try targetRegistry.renewalRuntimeMaterial(store: self)
        if let (status, invitation, continuation) = try targetRegistry.runtimeMaterial(store: self) {
            // begin() durably accepted precisely this join under the actual local
            // administrator. Its private continuation does not add a second local
            // administrator veto to the issuer's fresh scoped global decision.
            if replacement == nil, let invitation { privatePeers.append(try .invitation(invitation, localIsIssuer: false)) }
            if let continuation { privatePeers.append(try .continuation(invitation: status.invitation, claim: continuation, localIsIssuer: false)) }
        }
        if let (status, invitation, continuation) = replacement {
            if renewal == nil, let invitation { privatePeers.append(try .invitation(invitation, localIsIssuer: false)) }
            if let continuation { privatePeers.append(try .continuation(invitation: status.invitation, claim: continuation, localIsIssuer: false)) }
        }
        if let renewal { privatePeers.append(try .invitation(renewal, localIsIssuer: false)) }
        let member = PersonalEnrollmentMemberRegistry(root: root)
        let route = try member.routes()
        if let route {
            let identity = try personalSyncIdentity()
            let pending = try personalEnrollmentPendingConfiguration()
            guard try identity.membership?.digest == route.configurationDigest || pending?.digest == route.configurationDigest else {
                throw PersonalEnrollmentError.conflict()
            }
        }
        return try .init(retainedControlCredentials: personalEnrollmentRetainedCredentials(), privatePeers: privatePeers, routes: route)
    }
    package func personalEnrollmentValidateTransport(_ binding: PeerExchangeBinding,
        purpose: PersonalEnrollmentTransportPurpose, now: Int64) throws {
        if purpose == .memberControl {
            do { try validatePersonalPeerBinding(binding); return }
            catch { try personalEnrollmentValidateRetainedControlBinding(binding); return }
        }
        let material = try personalEnrollmentRuntimeMaterial(now: now)
        guard material.privatePeers.contains(where: { $0.binding == binding && $0.purpose == purpose }) else {
            throw TractandaError("untrustedPeer", "No exact current private enrollment binding is available.")
        }
    }
    package func personalEnrollmentClaim(_ claim: PersonalEnrollmentClaim, binding: PeerExchangeBinding, now: Int64) throws
        -> PersonalEnrollmentIssuerStatus {
        try personalEnrollmentValidateTransport(binding, purpose: .invitation, now: now)
        let registry = PersonalEnrollmentRegistry(root: root, ownerUID: ownerUID)
        guard let status = try registry.runtimeStatus(), binding.localReplicaID == status.invitation.issuerReplicaID else {
            throw PersonalEnrollmentError.conflict()
        }
        let administrator = try personalEnrollmentResolvePrincipal(status.administrator)
        let authorization = try PersonalEnrollmentLocalAuthorization.authorize(store: self, forUID: administrator.uid)
        return try registry.claim(claim, authenticatedInvitation: status.invitation, authorization: authorization, now: now)
    }
}
