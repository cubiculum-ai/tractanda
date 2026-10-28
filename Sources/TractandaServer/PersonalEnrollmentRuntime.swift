import Foundation
import TractandaClient
import TractandaCore
import TractandaPeerTransport

/// A daemon-owned temporary coordinator. All durable state remains one bounded current
/// operation, and ordinary item writers never depend on this actor's availability.
actor PersonalEnrollmentRuntime {
    private let coordinator: ServiceCoordinator
    private let runtime: PersonalPeerRuntime
    private let processGeneration = UUID()
    private var task: Task<Void, Never>?
    private var stopped = false
    private var driverStarts: UInt64 = 0
    private var beforeDriverStartForTesting: (@Sendable () async -> Void)?
    private var lastErrorCode: String?
    private var issuerErrorCode: String?
    private struct CutWindow {
        let selectionID: String
        let configurationDigest: String
        let sourceReplicaID: String
        var ordinal: UInt64
        var first: PersonalEnrollmentCompletedCut?
        var readiness: PersonalEnrollmentBaselineReadiness?
    }
    private var cuts: CutWindow?
    struct NodeReply: Codable, Sendable {
        let status: PersonalEnrollmentNodeStatus
        let endpoints: [PeerRuntimeConfiguration.Endpoint]
    }
    init(coordinator: ServiceCoordinator, runtime: PersonalPeerRuntime) {
        self.coordinator = coordinator; self.runtime = runtime
    }
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
    func activate() async {
        let coordinator = coordinator
        await runtime.setEnrollmentBridge(material: {
            try await coordinator.personalEnrollmentRuntimeMaterial(now: Self.now())
        }, validate: { [weak self] binding, purpose in
            guard let self else { throw CancellationError() }
            try await self.validate(binding, purpose: purpose)
        }, handle: { [weak self] binding, purpose, request in
            guard let self else { throw CancellationError() }
            return try await self.handle(binding, purpose: purpose, request: request)
        }, completedCut: { [weak self] binding, report in
            await self?.completedCut(binding, report: report)
        })
        await ensureRunning()
    }
    func beginClose() { stopped = true; task?.cancel() }
    func finishClose() async { await task?.value; task = nil }
    func setBeforeDriverStartForTesting(_ hook: (@Sendable () async -> Void)?) { beforeDriverStartForTesting = hook }
    func driverStartsForTesting() -> UInt64 { driverStarts }
    private func ensureRunning() async {
        guard !stopped, task == nil else { return }
        do {
            let state = try await coordinator.personalEnrollmentHostState()
            guard state.sourceJob.map({ $0.phase != .complete }) == true || state.target.map({ $0.phase != .complete }) == true
                || state.replacement != nil else { return }
        } catch { lastErrorCode = Self.code(error); return }
        await beforeDriverStartForTesting?()
        // HostState suspends this actor. Another caller or shutdown may have claimed
        // the driver slot while it was being read.
        guard !stopped, task == nil else { return }
        driverStarts += 1
        task = Task { [weak self] in guard let self else { return }; await self.run() }
    }
    private func run() async {
        while !stopped && !Task.isCancelled {
            do {
                let state = try await coordinator.personalEnrollmentHostState()
                let sourceActive = state.sourceJob.map { $0.phase != .complete } ?? false
                let targetActive = state.target.map { $0.phase != .complete } ?? false
                guard sourceActive || targetActive || state.replacement != nil else { break }
                if state.replacement != nil { try await advanceReplacement(state) }
                else if targetActive { try await advanceTarget(state) }
                if sourceActive {
                    try await advanceSource()
                    if let current = try await coordinator.personalEnrollmentHostState().sourceJob,
                        current.phase != .complete, current.lastErrorCode != nil {
                        var cleared = current; cleared.lastErrorCode = nil
                        try await coordinator.personalEnrollmentWriteJob(cleared, replacing: current)
                    }
                }
                lastErrorCode = nil
            } catch {
                if Task.isCancelled || stopped { break }
                let code = Self.code(error); lastErrorCode = code
                if let state = try? await coordinator.personalEnrollmentHostState(), var job = state.sourceJob,
                    job.phase != .complete, job.lastErrorCode != code {
                    let old = job; job.lastErrorCode = code
                    try? await coordinator.personalEnrollmentWriteJob(job, replacing: old)
                }
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
        }
        task = nil
    }
    private static func code(_ error: any Error) -> String {
        let value = (error as? TractandaError)?.code ?? (error as? JMAPMethodError)?.type ?? "enrollmentUnavailable"
        guard value.utf8.count <= 128, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }) else { return "enrollmentUnavailable" }
        return value
    }
    private func validate(_ binding: PeerExchangeBinding, purpose: PersonalEnrollmentTransportPurpose) async throws {
        guard !stopped else { throw CancellationError() }
        try await coordinator.personalEnrollmentValidateTransport(binding, purpose: purpose, now: Self.now())
    }
    private func advanceTarget(_ state: PersonalEnrollmentHostState) async throws {
        guard let target = state.target, target.phase != .complete else { return }
        let material = try await coordinator.personalEnrollmentRuntimeMaterial(now: Self.now())
        guard let continuation = material.privatePeers.first(where: {
            $0.purpose == .continuation && $0.binding.localIsInitiator && $0.binding.pairingID == target.claim.continuationPairingID
        }) else { throw TractandaError("enrollmentConflict", "Exact target continuation is unavailable.") }
        if target.phase != .claiming {
            let bytes = try await runtime.privateRequest(binding: continuation.binding,
                request: .init("enrollment.job.status", ["operationID": .text(target.invitation.operationID)]))
            issuerErrorCode = try JMAPValue.decode(bytes)["lastErrorCode"]?.text
            return
        }
        // Always try the durable continuation first: the prior claim response may have
        // been lost after its atomic consume on the issuer.
        do {
            _ = try await runtime.privateRequest(binding: continuation.binding,
                request: .init("enrollment.job.status", ["operationID": .text(target.invitation.operationID)]))
            try await coordinator.personalEnrollmentTargetAcknowledged(binding: continuation.binding)
            return
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // No authenticated continuation yet; an unused invitation may still be claimed.
        }
        guard let invitation = material.privatePeers.first(where: {
            $0.purpose == .invitation && $0.binding.localIsInitiator
        }) else { throw TractandaError("membersOffline", "Waiting for the exact issuer continuation.") }
        let claim = try await coordinator.personalEnrollmentTargetClaim()
        _ = try await runtime.privateRequest(binding: invitation.binding,
            request: .init("enrollment.claim", ["claim": .bytes(claim.privateEncodedBytes())]))
        await runtime.refreshNow()
    }
    private func advanceReplacement(_ state: PersonalEnrollmentHostState) async throws {
        if try await coordinator.personalEnrollmentCleanupSupersededCandidates() { return }
        if try await coordinator.personalEnrollmentCleanupReplacement() { return }
        if try await coordinator.personalEnrollmentCleanupRenewal() { return }
        guard let candidate = state.replacement else { return }
        let material = try await coordinator.personalEnrollmentRuntimeMaterial(now: Self.now())
        let retained = material.privatePeers.filter { $0.purpose == .continuation && $0.binding.localIsInitiator }
        let operations = [state.target, state.replacement].compactMap { $0 }
        let invitationID = state.renewal?.invitation.pairingID ?? candidate.invitation.pairingID
        guard let invitation = material.privatePeers.first(where: {
            $0.purpose == .invitation && $0.binding.localIsInitiator && $0.binding.pairingID == invitationID
        }) else { throw TractandaError("enrollmentConflict", "No exact pending invitation is available.") }
        let runtime = runtime, coordinator = coordinator
        let result = try await Self.raceRenewalRecovery(retained: retained.compactMap { peer in
            guard let target = operations.first(where: { $0.claim.continuationPairingID == peer.binding.pairingID }) else { return nil }
            return {
                let bytes = try await runtime.privateRequest(binding: peer.binding,
                    request: .init("enrollment.job.status", ["operationID": .text(target.invitation.operationID)]))
                guard try JMAPValue.decode(bytes)["operationID"]?.text == target.invitation.operationID else {
                    throw TractandaError("enrollmentConflict", "The issuer confirmed a different operation.")
                }
                return .continuation(peer.binding)
            }
        }, probe: {
            if state.renewal != nil {
                return .renewal(try await runtime.authenticateRenewalProbe(binding: invitation.binding))
            }
            let claim = try await coordinator.personalEnrollmentTargetClaim(operationID: candidate.invitation.operationID)
            _ = try await runtime.privateRequest(binding: invitation.binding,
                request: .init("enrollment.claim", ["claim": .bytes(claim.privateEncodedBytes())]))
            return .claimSent
        })
        switch result {
        case .continuation(let binding):
            await runtime.cancelRenewalProbe(binding: invitation.binding)
            try await coordinator.personalEnrollmentConfirmRetainedContinuation(binding: binding)
            cuts = nil
        case .renewal(let ready):
            // Only the Runtime's fresh TLS/hello ready path constructs this observation.
            // Its one-shot control remains live through the atomic candidate publication.
            try await coordinator.personalEnrollmentAcceptRenewal(binding: ready.binding, control: ready.consume())
        case .claimSent: break
        }
        await runtime.refreshNow()
    }
    enum RenewalRecoveryResult: Sendable {
        case continuation(PeerExchangeBinding)
        case renewal(PersonalEnrollmentAuthenticatedReady)
        case claimSent
    }
    /// Attempts run concurrently so a slow unused-code probe cannot hide an already
    /// accepted continuation after restart. All losing tasks are cancelled and reaped;
    /// an actual continuation reply takes precedence over a simultaneous ready proof.
    static func raceRenewalRecovery(
        retained: [@Sendable () async throws -> RenewalRecoveryResult],
        probe: @escaping @Sendable () async throws -> RenewalRecoveryResult
    ) async throws -> RenewalRecoveryResult {
        try await withThrowingTaskGroup(of: RenewalRecoveryResult?.self) { group in
            for attempt in retained { group.addTask { try? await attempt() } }
            group.addTask { try? await probe() }
            var selected: RenewalRecoveryResult?
            while let outcome = try await group.next() {
                guard let outcome else { continue }
                selected = outcome; group.cancelAll(); break
            }
            while let outcome = try await group.next() {
                if case .some(.continuation) = outcome { selected = outcome }
            }
            try Task.checkCancellation()
            guard let selected else { throw TractandaError("membersOffline", "Waiting for an authenticated retained continuation or unused renewal code.") }
            return selected
        }
    }
    private func advanceSource() async throws {
        let (_, snapshot) = try await coordinator.personalEnrollmentSourceAuthorization()
        guard var job = snapshot.job, job.phase != .complete else { return }
        if snapshot.issuer?.phase == .complete { try await coordinator.personalEnrollmentFinishSource(); return }
        guard let issuer = snapshot.issuer, let claim = issuer.claim else { return }
        let material = try await coordinator.personalEnrollmentRuntimeMaterial(now: Self.now())
        guard let continuation = material.privatePeers.first(where: {
            $0.purpose == .continuation && !$0.binding.localIsInitiator
        }) else { throw TractandaError("membersOffline", "Waiting for the claimed target connection.") }
        if job.plan == nil {
            let data = try await runtime.privateRequest(binding: continuation.binding,
                request: .init("enrollment.target.status", ["operationID": .text(job.invitation.operationID)]))
            let target = try JSON.decode(NodeReply.self, data)
            guard target.status.identity.storeID == job.invitation.storeID,
                target.status.identity.replicaID == claim.targetReplicaID,
                target.status.operationID == job.invitation.operationID else { throw TractandaError("enrollmentConflict", "Target identity changed.") }
            let sourceMember = try PersonalMember(replicaID: snapshot.identity.replicaID,
                hostname: snapshot.identity.membership?.members.first(where: { $0.replicaID == snapshot.identity.replicaID })?.hostname
                    ?? job.invitation.endpoints[0].host)
            var members = snapshot.identity.membership?.members ?? [sourceMember]
            var endpoints: [String: [PeerRuntimeConfiguration.Endpoint]] = [sourceMember.replicaID: job.invitation.endpoints,
                claim.targetReplicaID: target.endpoints]
            if let previous = snapshot.identity.membership {
                let digest = try previous.digest
                for member in previous.members where member.replicaID != sourceMember.replicaID {
                    let bytes = try await runtime.controlRequest(remoteReplicaID: member.replicaID, configurationDigest: digest,
                        request: .init("enrollment.member.inspect", ["operationID": .text(job.invitation.operationID)]))
                    let inspected = try JSON.decode(NodeReply.self, bytes)
                    guard inspected.status.identity.replicaID == member.replicaID,
                        inspected.status.identity.membership == previous,
                        inspected.status.admission == job.admission, !inspected.status.baselinePending,
                        inspected.status.pendingMembershipDigest == nil,
                        inspected.status.activeMemberOperationID == nil else {
                        throw TractandaError("configurationDrift", "A current member has a different policy, membership or active operation.")
                    }
                    endpoints[member.replicaID] = inspected.endpoints
                }
            }
            members.append(try .init(replicaID: claim.targetReplicaID, hostname: claim.targetHostname))
            let configuration = try PersonalMembershipConfiguration(storeID: snapshot.identity.storeID,
                configurationID: UUID.makeVersion1().uuidString.lowercased(), members: members)
            let plan = PersonalEnrollmentPlan(operationID: job.invitation.operationID,
                issuerReplicaID: snapshot.identity.replicaID, administrator: job.administrator,
                nonce: try UUID.makeVersion1().uuidString.lowercased(), previousMembership: snapshot.identity.membership,
                configuration: configuration, admission: job.admission,
                endpoints: endpoints)
            try plan.validate()
            let old = job; job.plan = plan; job.phase = .staging; job.lastErrorCode = nil
            try await coordinator.personalEnrollmentWriteJob(job, replacing: old)
            return
        }
        guard let plan = job.plan else { throw TractandaError("enrollmentConflict", "No exact join plan.") }
        let sourceID = snapshot.identity.replicaID, targetID = claim.targetReplicaID
        if job.phase == .staging {
            let keys = try await coordinator.personalEnrollmentPlanCredentials(plan)
            if !job.stagedMembers.contains(sourceID) {
                let local = keys.filter { $0.binding.localReplicaID == sourceID }
                _ = try await coordinator.personalEnrollmentPrepareLocal(plan: plan, keys: local)
                await runtime.refreshNow()
                let old = job; job.stagedMembers.append(sourceID); job.stagedMembers.sort()
                try await coordinator.personalEnrollmentWriteJob(job, replacing: old)
                return
            }
            if !job.stagedMembers.contains(targetID) {
                if let previous = plan.previousMembership, let decision = try plan.decision,
                    let retained = previous.members.first(where: { $0.replicaID != sourceID && !job.stagedMembers.contains($0.replicaID) }) {
                    let packet = try PersonalEnrollmentStagePacket(plan: plan, credentials: keys, localReplicaID: retained.replicaID)
                    _ = try await runtime.controlRequest(remoteReplicaID: retained.replicaID, configurationDigest: previous.digest,
                        request: .init("enrollment.member.stage", ["operationID": .text(plan.operationID),
                            "decision": .bytes(JSON.encode(decision)), "payload": .bytes(JSON.encode(packet))]))
                    let old = job; job.stagedMembers.append(retained.replicaID); job.stagedMembers.sort()
                    try await coordinator.personalEnrollmentWriteJob(job, replacing: old)
                    return
                }
                let packet = try PersonalEnrollmentStagePacket(plan: plan, credentials: keys, localReplicaID: targetID)
                _ = try await runtime.privateRequest(binding: continuation.binding,
                    request: .init("enrollment.target.stage", ["operationID": .text(plan.operationID), "payload": .bytes(JSON.encode(packet))]))
                let old = job; job.stagedMembers.append(targetID); job.stagedMembers.sort()
                try await coordinator.personalEnrollmentWriteJob(job, replacing: old)
                return
            }
            let old = job; job.phase = .committing
            try await coordinator.personalEnrollmentWriteJob(job, replacing: old)
            return
        }
        if job.phase == .committing {
            if let previous = plan.previousMembership, let decision = try plan.decision,
                let retained = previous.members.first(where: { $0.replicaID != sourceID && !job.committedMembers.contains($0.replicaID) }) {
                _ = try await runtime.controlRequest(remoteReplicaID: retained.replicaID, configurationDigest: previous.digest,
                    request: .init("enrollment.member.commit", ["operationID": .text(plan.operationID),
                        "decision": .bytes(JSON.encode(decision)), "payload": .bytes(JSON.encode(plan))]))
                let old = job; job.committedMembers.append(retained.replicaID); job.committedMembers.sort()
                try await coordinator.personalEnrollmentWriteJob(job, replacing: old)
                return
            }
            let keys = try await coordinator.personalEnrollmentPlanCredentials(plan)
            let local = try await coordinator.personalEnrollmentPrepareLocal(plan: plan,
                keys: keys.filter { $0.binding.localReplicaID == sourceID })
            _ = try await runtime.commitEnrollment(preparation: local.preparation, authorization: local.authorization)
            let old = job
            job.committedMembers = Array(Set(job.committedMembers + [sourceID])).sorted()
            job.phase = .copyingBaseline
            try await coordinator.personalEnrollmentWriteJob(job, replacing: old)
            return
        }
        if job.phase == .copyingBaseline {
            let reply: NodeReply
            do {
                reply = try JSON.decode(NodeReply.self, await runtime.privateRequest(binding: continuation.binding,
                    request: .init("enrollment.target.finish", ["operationID": .text(plan.operationID)])))
            } catch {
                // After a lost final reply the target may have retired its private key.
                // Query only its actual current paired server, never infer completion.
                reply = try JSON.decode(NodeReply.self, await runtime.controlRequest(remoteReplicaID: targetID,
                    configurationDigest: plan.configuration.digest,
                    request: .init("enrollment.member.inspect", ["operationID": .text(plan.operationID)])))
            }
            guard reply.status.identity.replicaID == targetID,
                reply.status.identity.membership == plan.configuration else { throw TractandaError("membersOffline", "Target membership is not committed.") }
            if !job.committedMembers.contains(targetID) {
                let old = job; job.committedMembers.append(targetID); job.committedMembers.sort()
                try await coordinator.personalEnrollmentWriteJob(job, replacing: old)
            }
            if reply.status.baselinePending || reply.status.targetPhase != .complete { return }
            if let previous = plan.previousMembership, let decision = try plan.decision {
                for retained in previous.members where retained.replicaID != sourceID {
                    _ = try await coordinator.personalEnrollmentSourceAuthorization()
                    _ = try await runtime.controlRequest(remoteReplicaID: retained.replicaID,
                        configurationDigest: plan.configuration.digest,
                        request: .init("enrollment.member.complete", ["operationID": .text(plan.operationID),
                            "decision": .bytes(JSON.encode(decision)), "payload": .bytes(JSON.encode(plan))]))
                }
            }
            let old = job; job.committedMembers = plan.configuration.members.map(\.replicaID).sorted()
            try await coordinator.personalEnrollmentWriteJob(job, replacing: old)
            try await coordinator.personalEnrollmentFinishSource()
        }
    }
    private func handle(_ binding: PeerExchangeBinding, purpose: PersonalEnrollmentTransportPurpose,
        request: PeerExchangeRequest) async throws -> Data {
        guard !stopped else { throw CancellationError() }
        try await validate(binding, purpose: purpose)
        if request.operation == "enrollment.claim" {
            guard purpose == .invitation, request.fields.count == 1, case .bytes(let bytes) = request.fields["claim"] else {
                throw TractandaError("invalidArguments", "Invalid private claim.")
            }
            let claimed = try await coordinator.personalEnrollmentClaim(.decodePrivate(bytes), binding: binding, now: Self.now())
            await runtime.refreshNow()
            await ensureRunning()
            return try JSON.encode(claimed)
        }
        guard case .text(let operationID) = request.fields["operationID"] else {
            throw TractandaError("invalidArguments", "An exact operation is required.")
        }
        // This handler is reached only after actual TLS authentication and the exact
        // purpose hello. The validator also runs before dialing and must stay pure.
        if purpose == .continuation && ["enrollment.target.stage", "enrollment.target.finish"].contains(request.operation) {
            let current = try await coordinator.personalEnrollmentHostState()
            if current.replacement?.claim.continuationPairingID == binding.pairingID {
                try await coordinator.personalEnrollmentPromoteReplacement(binding: binding)
            } else if current.target?.claim.continuationPairingID == binding.pairingID,
                current.target?.phase == .claiming {
                try await coordinator.personalEnrollmentTargetAcknowledged(binding: binding)
            }
        }
        let state = try await coordinator.personalEnrollmentHostState()
        switch request.operation {
        case "enrollment.job.status":
            guard purpose == .continuation, state.sourceJob?.invitation.operationID == operationID else {
                throw TractandaError("enrollmentConflict", "This continuation belongs to another operation.")
            }
            return try summary(state)
        case "enrollment.member.inspect":
            guard purpose == .memberControl, request.fields.count == 1 else { throw TractandaError("invalidArguments", "Invalid member inspection.") }
            return try await nodeReply()
        case "enrollment.member.stage":
            guard purpose == .memberControl, request.fields.count == 3,
                case .bytes(let decisionBytes) = request.fields["decision"],
                case .bytes(let payload) = request.fields["payload"] else { throw TractandaError("invalidArguments", "Invalid member stage.") }
            let decision = try PersonalEnrollmentAdminDecision.decodeStrict(decisionBytes)
            let packet = try PersonalEnrollmentStagePacket.decodeStrict(payload)
            guard packet.plan.operationID == operationID else { throw TractandaError("enrollmentConflict", "Stage belongs to another operation.") }
            _ = try await coordinator.personalEnrollmentPrepareMember(packet, decision: decision, binding: binding)
            await runtime.refreshNow()
            return try await nodeReply()
        case "enrollment.member.commit":
            guard purpose == .memberControl, request.fields.count == 3,
                case .bytes(let decisionBytes) = request.fields["decision"],
                case .bytes(let payload) = request.fields["payload"] else { throw TractandaError("invalidArguments", "Invalid member commit.") }
            let plan = try PersonalEnrollmentPlan.decodeStrict(payload)
            guard plan.operationID == operationID else { throw TractandaError("enrollmentConflict", "Commit belongs to another operation.") }
            let work = try await coordinator.personalEnrollmentMemberPrepared(plan: plan,
                decision: .decodeStrict(decisionBytes), binding: binding)
            _ = try await runtime.commitEnrollment(preparation: work.preparation, authorization: work.authorization)
            return try await nodeReply()
        case "enrollment.member.complete":
            guard purpose == .memberControl, request.fields.count == 3,
                case .bytes(let decisionBytes) = request.fields["decision"],
                case .bytes(let payload) = request.fields["payload"] else { throw TractandaError("invalidArguments", "Invalid member completion.") }
            let plan = try PersonalEnrollmentPlan.decodeStrict(payload)
            guard plan.operationID == operationID else { throw TractandaError("enrollmentConflict", "Completion belongs to another operation.") }
            try await coordinator.personalEnrollmentCompleteMember(plan: plan, decision: .decodeStrict(decisionBytes), binding: binding)
            await runtime.refreshNow()
            return try await nodeReply()
        case "enrollment.target.status":
            guard purpose == .continuation,
                state.target?.invitation.operationID == operationID || state.replacement?.invitation.operationID == operationID,
                request.fields.count == 1 else {
                throw TractandaError("enrollmentConflict", "This target belongs to another operation.")
            }
            return try await nodeReply(operationID: operationID)
        case "enrollment.target.stage":
            guard purpose == .continuation, state.target?.invitation.operationID == operationID,
                request.fields.count == 2, case .bytes(let payload) = request.fields["payload"] else {
                throw TractandaError("invalidArguments", "Invalid target stage.")
            }
            let packet = try PersonalEnrollmentStagePacket.decodeStrict(payload)
            guard packet.plan.operationID == operationID else { throw TractandaError("enrollmentConflict", "Stage belongs to another operation.") }
            _ = try await coordinator.personalEnrollmentPrepareTarget(packet, binding: binding)
            cuts = nil
            await runtime.refreshNow()
            return try await nodeReply()
        case "enrollment.target.finish":
            guard purpose == .continuation, state.target?.invitation.operationID == operationID, request.fields.count == 1 else {
                throw TractandaError("enrollmentConflict", "This target belongs to another operation.")
            }
            let work = try await coordinator.personalEnrollmentTargetPrepared(binding: binding)
            _ = try await runtime.commitEnrollment(preparation: work.preparation, authorization: work.authorization)
            try await coordinator.personalEnrollmentTargetCommitted(authorization: work.authorization)
            if !(try await coordinator.personalEnrollmentHostState()).baselinePending {
                try await coordinator.personalEnrollmentFinishTarget(readiness: nil, authorization: work.authorization)
            } else if let readiness = cuts?.readiness {
                let coordinator = coordinator
                try await runtime.withEnrollmentFinalization(remoteReplicaID: work.authorization.plan.issuerReplicaID,
                    configurationDigest: work.authorization.plan.configuration.digest) {
                        try await coordinator.personalEnrollmentFinishTarget(readiness: readiness, authorization: work.authorization)
                    }
            }
            return try await nodeReply()
        default: throw TractandaError("unsupportedPeerOperation", "This private operation is not supported.")
        }
    }
    private func nodeReply(operationID: String? = nil) async throws -> Data {
        let status = try await coordinator.personalEnrollmentNodeStatus(operationID: operationID)
        var host = status.identity.membership?.members.first(where: { $0.replicaID == status.identity.replicaID })?.hostname
        if host == nil { host = try await coordinator.personalEnrollmentHostState().target?.claim.targetHostname }
        let endpoints: [PeerRuntimeConfiguration.Endpoint]
        if let host { endpoints = try await runtime.effectiveOwnEndpoints(hostname: host) } else { endpoints = [] }
        return try JSON.encode(NodeReply(status: status, endpoints: endpoints))
    }
    private func completedCut(_ binding: PeerExchangeBinding, report: PersonalSyncReport) async {
        guard let generation = report.sourceCatalogueGeneration, let row = report.cutRowID else { return }
        do {
            let state = try await coordinator.personalEnrollmentHostState()
            guard let target = state.target, let selection = target.selectionID, let plan = target.plan,
                target.phase != .complete, binding.remoteReplicaID == plan.issuerReplicaID,
                binding.localReplicaID == target.claim.targetReplicaID,
                try binding.configurationDigest == plan.configuration.digest else { return }
            if cuts?.selectionID != selection || cuts?.configurationDigest != binding.configurationDigest {
                cuts = .init(selectionID: selection, configurationDigest: binding.configurationDigest,
                    sourceReplicaID: binding.remoteReplicaID, ordinal: 0)
            }
            guard var window = cuts else { return }
            window.ordinal += 1
            let cut = try PersonalEnrollmentCompletedCut(binding: binding, selectionID: selection,
                jobGeneration: processGeneration, ordinal: window.ordinal, sourceCatalogueGeneration: generation, cutRowID: row)
            if let first = window.first {
                do { window.readiness = try .observed(first: first, rescan: cut) }
                catch { window.first = cut; window.readiness = nil }
            } else { window.first = cut }
            cuts = window
        } catch { lastErrorCode = Self.code(error) }
    }
    /// Called only by the marked private Unix session, never ordinary native/MCP/HTTP.
    func native(_ data: Data, forUID uid: UInt32, principal: NativePrincipalPin) async throws -> Data {
        guard !stopped else { throw CancellationError() }
        _ = try await coordinator.personalPeerLocalRequest(.init("identity"), forUID: uid, principal: principal)
        let limits = JMAPKernel.Limits(maximumRequestBytes: NativePersonalEnrollment.maximumInput,
            maximumCalls: 1, maximumJSONDepth: 32, maximumResponseBytes: NativePersonalEnrollment.maximumReply)
        do {
            let request = try JMAPRequest.decode(data, limits: limits)
            guard request.using == [NativePersonalEnrollment.capability] else { throw JMAPProblem("unknownCapability") }
            let names = ["invite", "join", "status", "resume"].map { "TractandaEnrollmentLocal/" + $0 }
            let state = try JMAPSessionState("personal-enrollment-local-v1")
            if let forbidden = request.methodCalls.first(where: { !names.contains($0.name) }) {
                return try JMAPValue.object([
                    .init("sessionState", .string(state.value)),
                    .init("methodResponses", .array([JMAPInvocation(name: "error",
                        arguments: .object([.init("type", .string("unknownMethod"))]), callID: forbidden.callID).value])),
                ]).encoded()
            }
            var methods: [String: JMAPMethodDefinition] = [:]
            for name in names {
                let mutation = !name.hasSuffix("/status")
                methods[name] = .init(capability: NativePersonalEnrollment.capability,
                    effect: mutation ? .mayMutate : .readOnly, scope: .session,
                    maximumResponseBytes: 32 * 1024,
                    requiresMutationAdmission: mutation) { [weak self] arguments, context in
                    do {
                        guard let self else { throw CancellationError() }
                        if mutation {
                            try context.replyBudget.reserveMutationResponse(maximumResponseBytes: 32 * 1024)
                            context.replyBudget.markDomainOperationBegan()
                        }
                        let value = try await self.nativeMethod(name, arguments: arguments, forUID: uid, principal: principal)
                        return .success([.init(name, value)])
                    } catch {
                        return .failure(.init(Self.code(error), description: "Private enrollment request could not complete; inspect job status."),
                            effects: context.replyBudget.provesNoEffects ? .none : .unknown)
                    }
                }
            }
            return try await JMAPKernel(methods: methods, limits: limits, sessionState: { state }).execute(request).value.encoded()
        } catch let problem as JMAPProblem { return try problem.value.encoded() }
    }
    private func nativeMethod(_ name: String, arguments: JMAPValue, forUID uid: UInt32, principal: NativePrincipalPin) async throws -> JMAPValue {
        _ = try await coordinator.personalPeerLocalRequest(.init("identity"), forUID: uid, principal: principal)
        guard let members = arguments.members else { throw JMAPMethodError("invalidArguments") }
        let keys = Set(members.map(\.name))
        switch name {
        case "TractandaEnrollmentLocal/invite":
            guard keys.isSubset(of: ["hostname", "fallbackHosts", "resume"]) else { throw JMAPMethodError("invalidArguments") }
            guard await runtime.synchronizationEnabledForEnrollment() else {
                throw TractandaError("peerRuntimeUnavailable", "Explicit synchronization policy is required before joining.")
            }
            let snapshot = try await coordinator.personalEnrollmentSourceSnapshot(forUID: uid, principal: principal)
            let resume: Bool
            if let value = arguments["resume"] {
                guard case .bool(let flag) = value else { throw JMAPMethodError("invalidArguments") }
                resume = flag
            } else { resume = false }
            if resume {
                guard !keys.contains("hostname"), !keys.contains("fallbackHosts"),
                    let existing = snapshot.issuer, existing.phase == .invitation,
                    existing.invitation.expiresAt > Self.now() else {
                    throw TractandaError("invitationExpired", "No still-unused invitation is available for exact redisplay.")
                }
            }
            let selectedHost = arguments["hostname"]?.text
                ?? snapshot.identity.membership?.members.first(where: { $0.replicaID == snapshot.identity.replicaID })?.hostname
                ?? snapshot.issuer?.invitation.endpoints.first?.host
            guard let selectedHost else { throw JMAPMethodError("invalidArguments") }
            let primary = try await runtime.effectiveOwnEndpoints(hostname: selectedHost)
            guard let endpoint = primary.first else {
                throw TractandaError("peerRuntimeUnavailable", "An explicitly configured listening peer is required to issue a code.")
            }
            var endpoints = primary
            if !keys.contains("hostname"), !keys.contains("fallbackHosts"),
                let existing = snapshot.issuer, existing.phase == .invitation,
                existing.invitation.endpoints.first?.port == endpoint.port {
                endpoints = existing.invitation.endpoints
            }
            if let value = arguments["fallbackHosts"] {
                guard let alternatives = value.elements, alternatives.count <= 3 else { throw JMAPMethodError("invalidArguments") }
                for value in alternatives {
                    guard let host = value.text else { throw JMAPMethodError("invalidArguments") }
                    endpoints.append(try .init(host: host, port: endpoint.port))
                }
            }
            let invitation = try await coordinator.personalEnrollmentIssue(forUID: uid, endpoints: endpoints, now: Self.now(),
                expectedUnusedOperationID: resume ? snapshot.issuer?.invitation.operationID : nil, principal: principal)
            await runtime.refreshNow(); await ensureRunning()
            return .object([.init("code", .string(try invitation.privateCode())),
                .init("invitation", try .decode(JSON.encode(invitation.metadata)))])
        case "TractandaEnrollmentLocal/join":
            guard keys.isSubset(of: ["code", "hostname", "replaceExpired"]), let code = arguments["code"]?.text,
                let hostname = arguments["hostname"]?.text else { throw JMAPMethodError("invalidArguments") }
            guard await runtime.synchronizationEnabledForEnrollment() else {
                throw TractandaError("peerRuntimeUnavailable", "Explicit synchronization policy is required before joining.")
            }
            let invitation = try PersonalEnrollmentInvitation.parsePrivateCode(code)
            if let value = arguments["replaceExpired"] {
                guard case .bool(true) = value else { throw JMAPMethodError("invalidArguments") }
                _ = try await coordinator.personalEnrollmentBeginReplacement(forUID: uid, invitation: invitation,
                    hostname: hostname, now: Self.now(), principal: principal)
            } else {
                _ = try await coordinator.personalEnrollmentBeginTarget(forUID: uid, invitation: invitation, hostname: hostname, principal: principal)
            }
            await runtime.refreshNow(); await ensureRunning()
            return try .decode(summary(await coordinator.personalEnrollmentHostState()))
        case "TractandaEnrollmentLocal/status", "TractandaEnrollmentLocal/resume":
            guard keys.isSubset(of: ["operationID", "familyID"]) else { throw JMAPMethodError("invalidArguments") }
            let state = try await coordinator.personalEnrollmentHostState()
            if let value = arguments["familyID"] {
                guard let family = value.text, try JMAPValue.decode(summary(state))["familyID"]?.text == family else {
                    throw TractandaError("enrollmentConflict", "No matching current invitation family is selected.")
                }
            }
            if let value = arguments["operationID"] {
                guard let operation = value.text,
                    operation == state.sourceJob?.invitation.operationID || operation == state.target?.invitation.operationID
                        || operation == state.member?.plan.operationID || operation == state.replacement?.invitation.operationID
                        || operation == state.renewal?.invitation.operationID else {
                    throw TractandaError("enrollmentConflict", "No matching current operation is selected.")
                }
            }
            if name.hasSuffix("/resume") { await ensureRunning() }
            return try .decode(summary(state))
        default: throw JMAPMethodError("unknownMethod")
        }
    }
    private func summary(_ state: PersonalEnrollmentHostState) throws -> Data {
        struct Summary: Encodable {
            let storeID: String; let replicaID: String; let operationID: String?; let familyID: String?
            let role: String?; let phase: String?; let baselinePending: Bool; let lastErrorCode: String?
            let stagedMembers: [String]; let committedMembers: [String]
        }
        let sourceActive = state.sourceJob.map { $0.phase != .complete } ?? false
        let targetActive = state.target.map { $0.phase != .complete } ?? false
        let memberActive = state.member.map { $0.phase != .complete } ?? false
        let sourceCurrent = state.sourceJob?.plan?.configuration == state.identity.membership && state.sourceJob != nil
        let memberCurrent = state.member?.plan.configuration == state.identity.membership && state.member != nil
        let sourceSelected = sourceActive || (!targetActive && !memberActive && (sourceCurrent || (state.target == nil && !memberCurrent)))
        let memberSelected = !sourceActive && !targetActive && (memberActive || (!sourceCurrent && memberCurrent))
        let selectedOperation = state.renewal?.invitation.operationID ?? state.replacement?.invitation.operationID ?? (sourceSelected ? state.sourceJob?.invitation.operationID
            : memberSelected ? state.member?.plan.operationID : state.target?.invitation.operationID)
        let selectedRole = state.replacement != nil ? "target" : sourceSelected ? (state.sourceJob == nil ? nil : "issuer") : memberSelected ? "member" : state.target == nil ? nil : "target"
        let selectedPhase = state.renewal != nil ? "authenticatingUnusedRenewal" : state.replacement != nil ? "confirmingReplacement" : sourceSelected ? state.sourceJob?.phase.rawValue : memberSelected ? state.member?.phase.rawValue : state.target?.phase.rawValue
        let family = state.renewal?.invitation.familyID ?? state.replacement?.invitation.familyID
            ?? (sourceSelected ? state.sourceJob?.invitation.familyID : memberSelected ? nil : state.target?.invitation.familyID)
        return try JSON.encode(Summary(storeID: state.identity.storeID, replicaID: state.identity.replicaID,
            operationID: selectedOperation, familyID: family, role: selectedRole, phase: selectedPhase,
            baselinePending: state.baselinePending, lastErrorCode: lastErrorCode ?? issuerErrorCode ?? state.sourceJob?.lastErrorCode,
            stagedMembers: state.sourceJob?.stagedMembers ?? [], committedMembers: state.sourceJob?.committedMembers ?? []))
    }
}
