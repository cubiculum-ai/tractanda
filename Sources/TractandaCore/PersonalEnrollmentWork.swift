import Foundation

/// Host-private snapshots; deliberately not Codable because target state contains its
/// local selection token. Peer/native diagnostics use an explicit smaller public summary.
package struct PersonalEnrollmentHostState: Sendable {
    package let identity: PersonalSyncIdentity
    package let issuer: PersonalEnrollmentIssuerStatus?
    package let sourceJob: PersonalEnrollmentSourceJob?
    package let target: PersonalEnrollmentTargetStatus?
    package let member: PersonalEnrollmentMemberState?
    package let replacement: PersonalEnrollmentTargetStatus?
    package let renewal: PersonalEnrollmentRenewalStatus?
    package let baselinePending: Bool
}

package struct PersonalEnrollmentPreparedWork: Sendable {
    package let preparation: PersonalMembershipPreparation
    package let authorization: PersonalEnrollmentMembershipAuthorization
}
package struct PersonalEnrollmentNodeStatus: Codable, Sendable {
    package let identity: PersonalSyncIdentity
    package let admission: PersonalEnrollmentAdmission
    package let baselinePending: Bool
    package let targetPhase: PersonalEnrollmentTargetStatus.Phase?
    package let operationID: String?
    package let pendingMembershipDigest: String?
    package let activeMemberOperationID: String?
}

extension ItemStore {
    package func personalEnrollmentNodeStatus(operationID: String? = nil) throws -> PersonalEnrollmentNodeStatus {
        let registry = PersonalEnrollmentTargetRegistry(root: root)
        var target = try registry.runtimeMaterial(store: self)?.0
        if let operationID, let replacement = try registry.replacementStatus(store: self),
            replacement.invitation.operationID == operationID { target = replacement }
        let member = try PersonalEnrollmentMemberRegistry(root: root).state()
        let admission = try personalEnrollmentCurrentAdmission()
        try personalEnrollmentValidateRetainedAdmission(admission)
        return try .init(identity: personalSyncIdentity(), admission: admission,
            baselinePending: isPersonalBaselinePending, targetPhase: target?.phase, operationID: target?.invitation.operationID,
            pendingMembershipDigest: personalEnrollmentPendingConfiguration()?.digest,
            activeMemberOperationID: member?.phase == .complete ? nil : member?.plan.operationID)
    }
    package func personalEnrollmentHostState() throws -> PersonalEnrollmentHostState {
        try .init(identity: personalSyncIdentity(),
            issuer: PersonalEnrollmentRegistry(root: root, ownerUID: ownerUID).runtimeStatus(),
            sourceJob: PersonalEnrollmentJobRegistry(root: root).job(),
            target: PersonalEnrollmentTargetRegistry(root: root).runtimeMaterial(store: self)?.0,
            member: PersonalEnrollmentMemberRegistry(root: root).state(),
            replacement: PersonalEnrollmentTargetRegistry(root: root).replacementStatus(store: self),
            renewal: PersonalEnrollmentTargetRegistry(root: root).renewalStatus(store: self),
            baselinePending: isPersonalBaselinePending)
    }
    package func personalEnrollmentSourceAuthorization() throws -> (UInt32, PersonalEnrollmentSourceSnapshot) {
        guard let job = try PersonalEnrollmentJobRegistry(root: root).job() else { throw PersonalEnrollmentError.conflict() }
        let uid = try personalEnrollmentResolvePrincipal(job.administrator).uid
        let snapshot = try personalEnrollmentSourceSnapshot(forUID: uid)
        let membershipMatches: Bool
        if let plan = job.plan {
            membershipMatches = snapshot.identity.membership == plan.previousMembership || snapshot.identity.membership == plan.configuration
        } else { membershipMatches = try snapshot.identity.membership?.digest == job.invitation.expectedMembershipDigest }
        guard snapshot.admission == job.admission, snapshot.issuer?.invitation == job.invitation,
            membershipMatches else {
            throw PersonalEnrollmentError.conflict()
        }
        return (uid, snapshot)
    }
    package func personalEnrollmentWriteJob(_ job: PersonalEnrollmentSourceJob,
        replacing expected: PersonalEnrollmentSourceJob) throws {
        _ = try personalEnrollmentSourceAuthorization()
        guard job.administrator == expected.administrator, job.invitation == expected.invitation,
            job.admission == expected.admission else { throw PersonalEnrollmentError.conflict() }
        try PersonalEnrollmentJobRegistry(root: root).write(job, replacing: expected)
    }
    package func personalEnrollmentPlanCredentials(_ plan: PersonalEnrollmentPlan) throws -> [PeerCredential] {
        let (_, snapshot) = try personalEnrollmentSourceAuthorization()
        guard snapshot.job?.plan == plan else { throw PersonalEnrollmentError.conflict() }
        return try PersonalEnrollmentJobRegistry(root: root).credentials(plan: plan)
    }
    package func personalEnrollmentPrepareLocal(plan: PersonalEnrollmentPlan, keys: [PeerCredential]) throws -> PersonalEnrollmentPreparedWork {
        let (uid, snapshot) = try personalEnrollmentSourceAuthorization()
        guard snapshot.job?.plan == plan else { throw PersonalEnrollmentError.conflict() }
        let member = PersonalEnrollmentMemberRegistry(root: root)
        let authorization = try member.acceptLocal(plan, store: self, forUID: uid)
        let local = try PersonalEnrollmentLocalAuthorization.authorize(store: self, forUID: uid)
        let registry = PersonalEnrollmentRegistry(root: root, ownerUID: ownerUID)
        if snapshot.identity.membership == plan.configuration {
            guard try registry.status(authorization: local)?.resultingMembership == plan.configuration else { throw PersonalEnrollmentError.conflict() }
        } else { try registry.stageMembershipProposal(authorization: local, configuration: plan.configuration) }
        let preparation = try preparePersonalMembershipChange(authorization: authorization)
        try registerPersonalPeerCredentials(keys, authorization: authorization)
        try member.prepared(preparation, plan: plan)
        try member.publishRoutes(plan: plan)
        return .init(preparation: preparation, authorization: authorization)
    }
    package func personalEnrollmentPrepareMember(_ packet: PersonalEnrollmentStagePacket,
        decision: PersonalEnrollmentAdminDecision, binding: PeerExchangeBinding) throws -> PersonalEnrollmentPreparedWork {
        let identity = try personalSyncIdentity()
        let keys = try packet.credentials(localReplicaID: identity.replicaID)
        let member = PersonalEnrollmentMemberRegistry(root: root)
        let authorization = try member.accept(packet.plan, store: self, binding: binding, decision: decision)
        let preparation = try preparePersonalMembershipChange(authorization: authorization)
        try registerPersonalPeerCredentials(keys, authorization: authorization)
        try member.prepared(preparation, plan: packet.plan)
        try member.publishRoutes(plan: packet.plan)
        return .init(preparation: preparation, authorization: authorization)
    }
    package func personalEnrollmentMemberPrepared(plan: PersonalEnrollmentPlan,
        decision: PersonalEnrollmentAdminDecision, binding: PeerExchangeBinding) throws -> PersonalEnrollmentPreparedWork {
        guard try plan.decision == decision, let current = try PersonalEnrollmentMemberRegistry(root: root).state(),
            current.plan == plan else { throw PersonalEnrollmentError.conflict() }
        let authorization = try PersonalEnrollmentMembershipAuthorization.member(store: self, binding: binding, plan: plan)
        return try .init(preparation: preparePersonalMembershipChange(authorization: authorization), authorization: authorization)
    }
    package func personalEnrollmentRecordCommitted(authorization: PersonalEnrollmentMembershipAuthorization) throws {
        let member = PersonalEnrollmentMemberRegistry(root: root)
        if let current = try member.state(), current.plan == authorization.plan, current.phase != .complete {
            try member.committed(plan: authorization.plan)
        }
    }
    package func personalEnrollmentCompleteMember(plan: PersonalEnrollmentPlan,
        decision: PersonalEnrollmentAdminDecision, binding: PeerExchangeBinding) throws {
        let authorization = try PersonalEnrollmentCompletionAuthorization.currentMember(store: self,
            binding: binding, plan: plan, decision: decision)
        try personalEnrollmentRetireOldCredentials(authorization: authorization)
    }
    private func personalEnrollmentRetireOldCredentials(authorization: PersonalEnrollmentCompletionAuthorization) throws {
        let plan = authorization.plan
        guard try personalSyncIdentity().membership == plan.configuration else { throw PersonalEnrollmentError.conflict() }
        if let old = plan.previousMembership {
            try PersonalEnrollmentCredentialCleanup.remove(root: root, ownerUID: ownerUID, old: old,
                current: plan.configuration, pending: personalEnrollmentPendingConfiguration())
        }
        try PersonalEnrollmentMemberRegistry(root: root).complete(plan: plan)
    }
    package func personalEnrollmentTargetAcknowledged(binding: PeerExchangeBinding) throws {
        try PersonalEnrollmentTargetRegistry(root: root).continuationAccepted(store: self, binding: binding)
    }
    package func personalEnrollmentTargetClaim(operationID: String? = nil) throws -> PersonalEnrollmentClaim {
        let registry = PersonalEnrollmentTargetRegistry(root: root)
        if let operationID, let (candidate, _, claim) = try registry.replacementRuntimeMaterial(store: self),
            candidate.invitation.operationID == operationID, let claim { return claim }
        guard let (target, _, claim) = try PersonalEnrollmentTargetRegistry(root: root).runtimeMaterial(store: self),
            target.phase == .claiming, operationID == nil || target.invitation.operationID == operationID,
            let claim else { throw PersonalEnrollmentError.conflict() }
        return claim
    }
    package func personalEnrollmentCleanupReplacement() throws -> Bool {
        try PersonalEnrollmentTargetRegistry(root: root).cleanupAcceptedReplacement(store: self)
    }
    package func personalEnrollmentPromoteReplacement(binding: PeerExchangeBinding) throws {
        try PersonalEnrollmentTargetRegistry(root: root).promoteReplacement(store: self, binding: binding)
    }
    package func personalEnrollmentCleanupRenewal() throws -> Bool {
        try PersonalEnrollmentTargetRegistry(root: root).cleanupConfirmedRenewal(store: self)
    }
    package func personalEnrollmentCleanupSupersededCandidates() throws -> Bool {
        try PersonalEnrollmentTargetRegistry(root: root).cleanupSupersededCandidates(store: self)
    }
    package func personalEnrollmentConfirmRetainedContinuation(binding: PeerExchangeBinding) throws {
        try PersonalEnrollmentTargetRegistry(root: root).confirmRetainedContinuation(store: self, binding: binding)
    }
    package func personalEnrollmentAcceptRenewal(binding: PeerExchangeBinding, control: PeerExchangeControl) throws {
        try PersonalEnrollmentTargetRegistry(root: root).acceptAuthenticatedRenewal(store: self, binding: binding, control: control)
    }
    package func personalEnrollmentPrepareTarget(_ packet: PersonalEnrollmentStagePacket,
        binding: PeerExchangeBinding) throws -> PersonalEnrollmentPreparedWork {
        let identity = try personalSyncIdentity()
        let keys = try packet.credentials(localReplicaID: identity.replicaID)
        let registry = PersonalEnrollmentTargetRegistry(root: root)
        try registry.acceptRuntimePlan(store: self, binding: binding, plan: packet.plan)
        let authorization = try PersonalEnrollmentMembershipAuthorization.target(store: self, binding: binding, plan: packet.plan)
        let preparation = try preparePersonalMembershipChange(authorization: authorization)
        try registerPersonalPeerCredentials(keys, authorization: authorization)
        try PersonalEnrollmentMemberRegistry(root: root).publishRoutes(plan: packet.plan)
        let selection = try startPersonalBaseline(authorization: authorization)
        try registry.selectedBaseline(store: self, selectionID: selection, authorization: authorization)
        return .init(preparation: preparation, authorization: authorization)
    }
    package func personalEnrollmentTargetPrepared(binding: PeerExchangeBinding) throws -> PersonalEnrollmentPreparedWork {
        guard let target = try PersonalEnrollmentTargetRegistry(root: root).runtimeMaterial(store: self)?.0,
            let plan = target.plan else { throw PersonalEnrollmentError.conflict() }
        let authorization = try PersonalEnrollmentMembershipAuthorization.target(store: self, binding: binding, plan: plan)
        return try .init(preparation: preparePersonalMembershipChange(authorization: authorization), authorization: authorization)
    }
    package func personalEnrollmentTargetCommitted(authorization: PersonalEnrollmentMembershipAuthorization) throws {
        try PersonalEnrollmentTargetRegistry(root: root).membershipCommitted(store: self, authorization: authorization)
    }
    package func personalEnrollmentFinishTarget(readiness: PersonalEnrollmentBaselineReadiness?,
        authorization: PersonalEnrollmentMembershipAuthorization) throws {
        guard let target = try PersonalEnrollmentTargetRegistry(root: root).runtimeMaterial(store: self)?.0,
            let selection = target.selectionID else { throw PersonalEnrollmentError.conflict() }
        if isPersonalBaselinePending {
            guard let readiness else { throw TractandaError("baselineNotReady", "No exact current cut and rescan witness is available.") }
            try finishPersonalBaseline(selectionID: selection, readiness: readiness, authorization: authorization)
        }
        try PersonalEnrollmentTargetRegistry(root: root).complete(store: self, authorization: authorization)
    }
    package func personalEnrollmentFinishSource() throws {
        let (uid, snapshot) = try personalEnrollmentSourceAuthorization()
        guard let job = snapshot.job, let plan = job.plan, snapshot.identity.membership == plan.configuration,
            Set(job.committedMembers) == Set(plan.configuration.members.map(\.replicaID)) else { throw PersonalEnrollmentError.conflict() }
        let authorization = try PersonalEnrollmentLocalAuthorization.authorize(store: self, forUID: uid)
        if snapshot.issuer?.phase != .complete {
            try PersonalEnrollmentRegistry(root: root, ownerUID: ownerUID).finish(authorization: authorization,
                operationID: job.invitation.operationID, cancelled: false)
        }
        if let member = try PersonalEnrollmentMemberRegistry(root: root).state(), member.plan == plan {
            try personalEnrollmentRetireOldCredentials(authorization: .local(store: self, forUID: uid, plan: plan))
        }
        try PersonalEnrollmentJobRegistry(root: root).clearCredentials()
        var complete = job; complete.phase = .complete; complete.lastErrorCode = nil
        try PersonalEnrollmentJobRegistry(root: root).write(complete, replacing: job)
    }
}
