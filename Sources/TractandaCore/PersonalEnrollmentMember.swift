import Foundation

/// One temporary old/next operation, retained only until coordinated completion. It lets
/// authenticated old control channels finish a partial commit without restoring old data
/// access or installing a permanent historical authority record.
package struct PersonalEnrollmentMemberRegistry {
    private let files: PersonalEnrollmentStateFiles
    package init(root: URL) { files = .init(root: root) }
    package func state() throws -> PersonalEnrollmentMemberState? {
        guard let bytes = try files.read("member.bin") else { return nil }
        let state = try JSON.decode(PersonalEnrollmentMemberState.self, bytes)
        try state.plan.validate()
        guard try JSON.encode(state) == bytes else { throw PersonalEnrollmentError.invalid() }
        if let preparation = state.preparation {
            guard preparation.configuration == state.plan.configuration,
                preparation.nonce == state.plan.nonce, preparation.administrator == state.plan.administrator else {
                throw PersonalEnrollmentError.invalid()
            }
        }
        return state
    }
    package func accept(_ plan: PersonalEnrollmentPlan, store: ItemStore,
        binding: PeerExchangeBinding, decision: PersonalEnrollmentAdminDecision) throws -> PersonalEnrollmentMembershipAuthorization {
        try plan.validate(); try decision.validate()
        guard try plan.decision == decision else { throw PersonalEnrollmentError.conflict() }
        let old = try files.read("member.bin")
        if let current = try state(), current.phase != .complete {
            guard current.plan == plan else { throw PersonalEnrollmentError.conflict() }
        } else {
            _ = try PersonalEnrollmentScopedAuthorization.receive(store: store, binding: binding, decision: decision)
            try store.personalEnrollmentValidateRetainedAdmission(plan.admission)
            let state = PersonalEnrollmentMemberState(plan: plan, phase: .prepared, preparation: nil)
            try files.replace("member.bin", bytes: JSON.encode(state), expected: old)
        }
        return try .member(store: store, binding: binding, plan: plan)
    }
    package func acceptLocal(_ plan: PersonalEnrollmentPlan, store: ItemStore, forUID uid: UInt32) throws
        -> PersonalEnrollmentMembershipAuthorization {
        try plan.validate()
        let authorization = try PersonalEnrollmentMembershipAuthorization.local(store: store, forUID: uid, plan: plan)
        try store.personalEnrollmentValidateRetainedAdmission(plan.admission)
        let old = try files.read("member.bin")
        if let current = try state(), current.phase != .complete {
            guard current.plan == plan else { throw PersonalEnrollmentError.conflict() }
        } else {
            try files.replace("member.bin", bytes: JSON.encode(PersonalEnrollmentMemberState(
                plan: plan, phase: .prepared, preparation: nil)), expected: old)
        }
        return authorization
    }
    package func prepared(_ preparation: PersonalMembershipPreparation, plan: PersonalEnrollmentPlan) throws {
        guard let old = try files.read("member.bin"), var current = try state(), current.plan == plan,
            preparation.configuration == plan.configuration, preparation.nonce == plan.nonce,
            preparation.administrator == plan.administrator else { throw PersonalEnrollmentError.conflict() }
        guard current.preparation == nil || current.preparation == preparation else { throw PersonalEnrollmentError.conflict() }
        current.preparation = preparation
        try files.replace("member.bin", bytes: JSON.encode(current), expected: old)
    }
    package func committed(plan: PersonalEnrollmentPlan) throws {
        guard let old = try files.read("member.bin"), var current = try state(), current.plan == plan else {
            throw PersonalEnrollmentError.conflict()
        }
        if current.phase == .complete { return }
        current.phase = .committed
        try files.replace("member.bin", bytes: JSON.encode(current), expected: old)
    }
    package func complete(plan: PersonalEnrollmentPlan) throws {
        guard let old = try files.read("member.bin"), var current = try state(), current.plan == plan else {
            throw PersonalEnrollmentError.conflict()
        }
        current.phase = .complete
        try files.replace("member.bin", bytes: JSON.encode(current), expected: old)
    }
    package func routes() throws -> PersonalEnrollmentRouteState? {
        guard let bytes = try files.read("routes.json") else { return nil }
        let route = try JSON.decode(PersonalEnrollmentRouteState.self, bytes)
        guard try JSON.encode(route) == bytes else { throw PersonalEnrollmentError.invalid() }
        try PersonalSyncValidation.identifier(route.operationID)
        try PersonalSyncValidation.sha256(route.configurationDigest)
        guard route.endpoints.count <= PersonalEnrollmentCapacity.maximumQualifiedMembers else { throw PersonalEnrollmentError.invalid() }
        for (replica, endpoints) in route.endpoints {
            guard endpoints.count <= 4 else { throw PersonalEnrollmentError.invalid() }
            for endpoint in endpoints { _ = try PersonalMember(replicaID: replica, hostname: endpoint.host) }
        }
        return route
    }
    package func publishRoutes(plan: PersonalEnrollmentPlan) throws {
        try plan.validate()
        let old = try files.read("routes.json")
        var endpoints = plan.endpoints
        if let previous = try routes() {
            let oldDigest = try plan.previousMembership?.digest, newDigest = try plan.configuration.digest
            let oldContext = previous.configurationDigest == oldDigest
            let exactRetry = previous.operationID == plan.operationID && previous.configurationDigest == newDigest
            if oldContext || exactRetry {
                let oldMembers = plan.previousMembership?.members.map(\.replicaID) ?? [plan.issuerReplicaID]
                let retained = Set(oldMembers).intersection(plan.configuration.members.map(\.replicaID))
                for member in retained { if let local = previous.endpoints[member] { endpoints[member] = local } }
            }
        }
        let next = PersonalEnrollmentRouteState(operationID: plan.operationID,
            configurationDigest: try plan.configuration.digest, endpoints: endpoints)
        try files.replace("routes.json", bytes: JSON.encode(next), expected: old)
    }
}

/// Explicit scoped authority for membership operations only. It never enters ordinary
/// access context or grants ordinary item methods administrator privileges.
package struct PersonalEnrollmentMembershipAuthorization: Sendable {
    package let plan: PersonalEnrollmentPlan
    private enum Source: Sendable { case local(UInt32), member(PeerExchangeBinding), target(PeerExchangeBinding) }
    private let source: Source
    private init(plan: PersonalEnrollmentPlan, source: Source) { self.plan = plan; self.source = source }
    package static func local(store: ItemStore, forUID uid: UInt32, plan: PersonalEnrollmentPlan) throws -> Self {
        let result = Self(plan: plan, source: .local(uid)); try result.revalidate(store: store); return result
    }
    package static func member(store: ItemStore, binding: PeerExchangeBinding, plan: PersonalEnrollmentPlan) throws -> Self {
        let result = Self(plan: plan, source: .member(binding)); try result.revalidate(store: store); return result
    }
    package static func target(store: ItemStore, binding: PeerExchangeBinding,
        plan: PersonalEnrollmentPlan) throws -> Self {
        let result = Self(plan: plan, source: .target(binding)); try result.revalidate(store: store); return result
    }
    package func revalidate(store: ItemStore) throws {
        try plan.validate()
        let identity = try store.personalSyncIdentity()
        guard identity.storeID == plan.configuration.storeID,
            plan.configuration.members.contains(where: { $0.replicaID == identity.replicaID }) else {
            throw PersonalEnrollmentError.conflict()
        }
        switch source {
        case .local(let uid):
            guard identity.membership == plan.previousMembership || identity.membership == plan.configuration else { throw PersonalEnrollmentError.conflict() }
            let local = try PersonalEnrollmentLocalAuthorization.authorize(store: store, forUID: uid)
            guard local.administrator == plan.administrator, identity.replicaID == plan.issuerReplicaID else {
                throw PersonalEnrollmentError.conflict()
            }
        case .member(let binding):
            guard identity.membership == plan.previousMembership || identity.membership == plan.configuration else { throw PersonalEnrollmentError.conflict() }
            guard let current = try PersonalEnrollmentMemberRegistry(root: store.root).state(), current.plan == plan,
                current.phase != .complete, binding.remoteReplicaID == plan.issuerReplicaID,
                binding.localReplicaID == identity.replicaID else { throw PersonalEnrollmentError.conflict() }
            try store.personalEnrollmentValidateOperationBinding(binding, plan: plan)
            _ = try store.personalEnrollmentResolvePrincipal(plan.administrator)
            try store.personalEnrollmentValidateRetainedAdmission(plan.admission)
        case .target(let binding):
            guard identity.membership == nil || identity.membership == plan.configuration else { throw PersonalEnrollmentError.conflict() }
            let registry = PersonalEnrollmentTargetRegistry(root: store.root)
            guard let (target, _, claim) = try registry.runtimeMaterial(store: store),
                target.invitation.operationID == plan.operationID,
                target.invitation.issuerReplicaID == plan.issuerReplicaID,
                target.configuration == plan.configuration, target.admission == plan.admission, target.plan == plan,
                binding.localReplicaID == identity.replicaID, binding.remoteReplicaID == plan.issuerReplicaID,
                binding.pairingID == claim?.metadata.continuationPairingID else { throw PersonalEnrollmentError.conflict() }
            _ = try store.personalEnrollmentResolvePrincipal(plan.administrator)
        }
    }
}

/// Only operational credential retirement for the exact committed operation. A completed
/// acknowledgement is idempotent and does not reopen membership preparation or item access.
package struct PersonalEnrollmentCompletionAuthorization: Sendable {
    package let plan: PersonalEnrollmentPlan
    private init(plan: PersonalEnrollmentPlan) { self.plan = plan }
    package static func currentMember(store: ItemStore, binding: PeerExchangeBinding,
        plan: PersonalEnrollmentPlan, decision: PersonalEnrollmentAdminDecision) throws -> Self {
        try plan.validate(); try decision.validate()
        try store.validatePersonalPeerBinding(binding)
        let identity = try store.personalSyncIdentity()
        guard try plan.decision == decision, binding.remoteReplicaID == plan.issuerReplicaID,
            binding.localReplicaID == identity.replicaID, identity.membership == plan.configuration,
            let member = try PersonalEnrollmentMemberRegistry(root: store.root).state(), member.plan == plan else {
            throw PersonalEnrollmentError.conflict()
        }
        _ = try store.personalEnrollmentResolvePrincipal(plan.administrator)
        try store.personalEnrollmentValidateRetainedAdmission(plan.admission)
        return .init(plan: plan)
    }
    package static func local(store: ItemStore, forUID uid: UInt32, plan: PersonalEnrollmentPlan) throws -> Self {
        let authorization = try PersonalEnrollmentMembershipAuthorization.local(store: store, forUID: uid, plan: plan)
        try authorization.revalidate(store: store)
        guard try store.personalSyncIdentity().membership == plan.configuration else { throw PersonalEnrollmentError.conflict() }
        return .init(plan: plan)
    }
}
