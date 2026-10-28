import Foundation
import NIOCore
import NIOPosix
import TractandaCore
import TractandaPeerTransport

/// Created only after the actual purpose-bound TLS/hello ready future succeeds.
/// Pure local validation callbacks cannot construct this network observation.
final class PersonalEnrollmentAuthenticatedReady: @unchecked Sendable {
    let binding: PeerExchangeBinding
    private let control: PeerExchangeControl
    private let lock = NSLock()
    private var used = false
    fileprivate init(binding: PeerExchangeBinding, control: PeerExchangeControl) {
        self.binding = binding
        self.control = control
    }
    func consume() throws -> PeerExchangeControl {
        lock.lock()
        defer { lock.unlock() }
        guard !used else {
            throw TractandaError("enrollmentConflict", "Renewal authentication was already consumed.")
        }
        try control.check()
        used = true
        return control
    }
}

/// One equivalent mesh member. TLS has directional contexts, while both endpoints own a
/// pull driver on every admitted connection. Local item writers never wait for this owner.
actor PersonalPeerRuntime {
    private struct Session: Sendable {
        let id: UUID
        let binding: PeerExchangeBinding
        let connection: PersonalPeerConnection
        let incoming: Bool
        var controlOnly: Bool
        var job: Task<Void, Never>?
        var pullID: UUID?
        var currentPull: PersonalPullProgress?
        var progressDelivery: (@Sendable (PersonalPullProgress) async -> Void)?
        var nextPull: Double
    }
    private struct EnrollmentSession {
        let id: UUID
        let binding: PeerExchangeBinding
        let purpose: PersonalEnrollmentTransportPurpose
        let connection: PersonalPeerConnection
    }
    private var enrollmentBridge: PersonalEnrollmentRuntimeBridge?
    private var enrollmentMaterial: PersonalEnrollmentRuntimeMaterial?
    private var enrollmentSessions: [String: EnrollmentSession] = [:]
    private var retiringEnrollment: [UUID: PersonalPeerConnection] = [:]
    private var currentControlDials: [String: Task<Session, Error>] = [:]
    private var enrollmentDials: [String: Task<PersonalPeerConnection, Error>] = [:]
    private var dialSlots: [UUID: Int] = [:]
    private var controlPending: Set<String> = []
    private var enrollmentFinalizing = false
    private var pullWaiters:
        [UUID: (peer: String, sessionID: UUID, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var refreshID = UUID()
    private(set) var enrollmentErrorCode: String?
    private let configuration: PeerRuntimeConfiguration
    private let configurationPath: String
    private let coordinator: ServiceCoordinator
    private let group: MultiThreadedEventLoopGroup
    private let resolver: PeerNameResolver
    private let limits: PersonalPeerLimits
    private var credentials: [PeerCredential] = []
    private var responder: PeerExchangeResponder?
    private var sessions: [String: Session] = [:]
    private var handshaking: [UUID: any Channel] = [:]
    private var readyAdmissions:
        [ObjectIdentifier: (PeerExchangeBinding, PersonalEnrollmentTransportPurpose)] = [:]
    private var reservations: [String: (PeerExchangeBinding, any Channel)] = [:]
    private var acceptingTasks: [UUID: Task<Void, Never>] = [:]
    private var pullJobs: [UUID: Task<Void, Never>] = [:]
    private var dialing: [String: Task<Void, Never>] = [:]
    private var nextDial: [String: Double] = [:]
    private var failures: [String: Int] = [:]
    private var reports: [String: PersonalSyncReport] = [:]
    private var completedCuts: [String: Int] = [:]
    private struct Observation {
        var connectedAt: String?
        var disconnectedAt: String?
        var pullStartedAt: String?
        var pullFinishedAt: String?
        var outcome: PersonalPeerObservation.Outcome?
        var errorCode: String?
        var errorAt: String?
    }
    private var observations: [String: Observation] = [:]
    private static func eventTime() -> String { ISO8601DateFormatter().string(from: Date()) }
    private var refresh: Task<Void, Never>?
    private var nextRefresh: Double = 0
    private var accepting = false
    private var stopped = false
    private var renewalProbeKeys = Set<String>()
    private var dialingSuspendedForTesting = false
    private var chunkObserverForTesting: PersonalChunkObserver?
    private(set) var lastErrorCode: String?

    init(
        configuration: PeerRuntimeConfiguration, configurationPath: String,
        coordinator: ServiceCoordinator, group: MultiThreadedEventLoopGroup,
        limits: PersonalPeerLimits? = nil, chunkObserverForTesting: PersonalChunkObserver? = nil
    ) throws {
        let limits = try limits ?? PersonalPeerLimits.configured()
        try limits.validate()
        self.configuration = configuration
        self.configurationPath = configurationPath
        self.coordinator = coordinator
        self.group = group
        self.limits = limits
        self.chunkObserverForTesting = chunkObserverForTesting
        resolver = PeerNameResolver(loop: group.next(), maximumConcurrentLookups: 8)
    }
    private nonisolated func operations(reserving channel: (any Channel)? = nil) -> PersonalPeerOperations {
        PersonalPeerOperations(
            validate: { [coordinator] binding in
                try await coordinator.personalPeerValidate(binding, controlOnly: true)
            },
            handle: { [coordinator] binding, request in
                // A retained control context never grants ordinary data access.
                try await coordinator.personalPeerRequest(binding, request: request)
            },
            beforeReady: { [self] binding in
                if let channel { try await reserve(channel, binding: binding) }
            },
            enrollmentValidate: { [self] binding, purpose in
                try await validateEnrollment(binding, purpose: purpose)
                if let channel, purpose != .memberControl {
                    await reservePrivateAdmission(channel, binding: binding, purpose: purpose)
                }
            },
            enrollmentHandle: { [self] binding, purpose, request in
                try await handleEnrollment(binding, purpose: purpose, request: request)
            }, transportValidate: { [self] binding in try await validateTransport(binding) })
    }
    private func validateTransport(_ binding: PeerExchangeBinding) async throws {
        do { try await coordinator.personalPeerValidate(binding, controlOnly: true) } catch {
            guard
                enrollmentMaterial?.retainedControlCredentials.contains(where: { $0.binding == binding })
                    == true
            else { throw error }
            try await validateEnrollment(binding, purpose: .memberControl)
        }
    }
    private func validateEnrollment(
        _ binding: PeerExchangeBinding, purpose: PersonalEnrollmentTransportPurpose
    ) async throws {
        guard !stopped, enrollmentErrorCode == nil, let bridge = enrollmentBridge else {
            throw TractandaError("untrustedPeer", "Enrollment context is unavailable.")
        }
        if purpose == .memberControl {
            // The provider validates actual current membership or one exact retained job.
            try await bridge.validate(binding, purpose)
        } else {
            guard
                enrollmentMaterial?.privatePeers.contains(where: {
                    $0.binding == binding && $0.purpose == purpose
                }) == true
            else {
                throw TractandaError("untrustedPeer", "Enrollment context is unavailable.")
            }
            try await bridge.validate(binding, purpose)
        }
        guard !stopped else { throw CancellationError() }
    }
    private func handleEnrollment(
        _ binding: PeerExchangeBinding, purpose: PersonalEnrollmentTransportPurpose,
        request: PeerExchangeRequest
    ) async throws -> Data {
        try await validateEnrollment(binding, purpose: purpose)
        guard let bridge = enrollmentBridge else { throw CancellationError() }
        return try await bridge.handle(binding, purpose, request)
    }
    private func reserve(_ channel: any Channel, binding: PeerExchangeBinding) async throws {
        try await validateTransport(binding)
        try Task.checkCancellation()
        guard accepting, !stopped, channel.isActive else { throw CancellationError() }
        let peer = Self.key(binding)
        if let previous = sessions[peer], previous.connection.isActive,
            previous.binding.pairingID == binding.pairingID
        {
            throw TractandaError("duplicatePeer", "A preferred personal peer channel is already active.")
        }
        let key = peer + "|" + binding.pairingID
        if let previous = reservations[key], previous.1.isActive, previous.1 !== channel {
            throw TractandaError("duplicatePeer", "This pairing already reserved a personal peer channel.")
        }
        guard reservations.count < 64 || reservations[key] != nil else {
            throw TractandaError("resourceLimit", "Personal peer channel reservation limit reached.")
        }
        reservations[key] = (binding, channel)
        readyAdmissions[ObjectIdentifier(channel)] = (binding, .memberControl)
        channel.closeFuture.whenComplete { [self] _ in
            Task { await releaseReservation(key, channel: channel) }
        }
    }
    private func releaseReservation(_ key: String, channel: any Channel) {
        if reservations[key]?.1 === channel { reservations[key] = nil }
        readyAdmissions[ObjectIdentifier(channel)] = nil
    }
    private func reservePrivateAdmission(
        _ channel: any Channel, binding: PeerExchangeBinding,
        purpose: PersonalEnrollmentTransportPurpose
    ) {
        let key = ObjectIdentifier(channel)
        if readyAdmissions[key] == nil {
            readyAdmissions[key] = (binding, purpose)
            channel.closeFuture.whenComplete { [self] _ in Task { await releasePrivateAdmission(key) } }
        }
    }
    private func releasePrivateAdmission(_ key: ObjectIdentifier) { readyAdmissions[key] = nil }
    func activate() { if !stopped { accepting = true } }
    func setEnrollmentBridge(
        material: @escaping @Sendable () async throws -> PersonalEnrollmentRuntimeMaterial,
        validate:
            @escaping @Sendable (PeerExchangeBinding, PersonalEnrollmentTransportPurpose) async throws -> Void,
        handle:
            @escaping @Sendable (PeerExchangeBinding, PersonalEnrollmentTransportPurpose, PeerExchangeRequest)
            async throws -> Data,
        completedCut: @escaping @Sendable (PeerExchangeBinding, PersonalSyncReport) async -> Void = { _, _ in
        }
    ) async {
        guard !stopped else { return }
        enrollmentBridge = .init(
            material: material, validate: validate, handle: handle, completedCut: completedCut)
        await refreshNow()
    }
    func clearEnrollmentBridge() async {
        enrollmentBridge = nil
        await refreshNow()
    }
    func synchronizationEnabledForEnrollment() -> Bool { configuration.synchronization.enabled }
    func effectiveOwnEndpoints(hostname: String) throws -> [PeerRuntimeConfiguration.Endpoint] {
        guard let listen = configuration.listen else { return [] }
        return [try .init(host: hostname, port: listen.port)]
    }
    private var connectionSlots: Int {
        sessions.count + enrollmentSessions.count + retiringEnrollment.count + handshaking.count
            + dialSlots.values.reduce(0, +)
    }
    private func reserveDial(_ count: Int) throws -> UUID {
        guard accepting, !stopped, count > 0, count <= 4, connectionSlots <= 64 - count else {
            throw TractandaError("resourceLimit", "The shared peer connection limit is full.")
        }
        let id = UUID()
        dialSlots[id] = count
        return id
    }
    private static func enrollmentKey(_ binding: PeerExchangeBinding) -> String {
        binding.pairingID + "|" + binding.configurationDigest + (binding.localIsInitiator ? "|out" : "|in")
    }
    private func validateMaterial(_ value: PersonalEnrollmentRuntimeMaterial) throws {
        guard value.retainedControlCredentials.count <= 64, value.privatePeers.count <= 4 else {
            throw PersonalEnrollmentError.invalid()
        }
        let privateIDs = value.privatePeers.map { $0.binding.pairingID }
        guard Set(privateIDs).count == privateIDs.count else { throw PersonalEnrollmentError.invalid() }
        for peer in value.privatePeers {
            guard peer.purpose != .memberControl, peer.endpoints.count <= 4,
                !peer.binding.localIsInitiator || !peer.endpoints.isEmpty
            else { throw PersonalEnrollmentError.invalid() }
            for endpoint in peer.endpoints {
                guard (1...65535).contains(endpoint.port) else { throw PersonalEnrollmentError.invalid() }
                _ = try PersonalMember(replicaID: peer.binding.remoteReplicaID, hostname: endpoint.host)
            }
        }
        if let route = value.routes {
            try Identifier.validate(route.operationID)
            guard UUID(uuidString: route.operationID)?.version1Components != nil,
                route.configurationDigest.utf8.count == 64,
                route.configurationDigest.utf8.allSatisfy({
                    (48...57).contains($0) || (97...102).contains($0)
                })
            else {
                throw PersonalEnrollmentError.invalid()
            }
            guard route.endpoints.count <= PersonalEnrollmentCapacity.maximumQualifiedMembers else {
                throw PersonalEnrollmentError.invalid()
            }
            for (replica, endpoints) in route.endpoints {
                try Identifier.validate(replica)
                guard UUID(uuidString: replica)?.version1Components != nil else {
                    throw PersonalEnrollmentError.invalid()
                }
                guard endpoints.count <= 4 else { throw PersonalEnrollmentError.invalid() }
                for endpoint in endpoints {
                    guard (1...65535).contains(endpoint.port) else { throw PersonalEnrollmentError.invalid() }
                    _ = try PersonalMember(replicaID: replica, hostname: endpoint.host)
                }
            }
        }
    }
    private func makeResponder(current: [PeerCredential], material: PersonalEnrollmentRuntimeMaterial?) throws
        -> PeerExchangeResponder?
    {
        var pairings: [String: PeerPairing] = [:]
        var bindings: [String: PeerExchangeBinding] = [:]
        for credential in current + (material?.retainedControlCredentials ?? [])
        where !credential.binding.localIsInitiator {
            let pairing = try PeerPairing(credential: credential)
            if let prior = bindings[credential.binding.pairingID] {
                guard prior == credential.binding else { throw PersonalEnrollmentError.invalid() }
            } else {
                pairings[credential.binding.pairingID] = pairing
                bindings[credential.binding.pairingID] = credential.binding
            }
        }
        for peer in material?.privatePeers ?? [] where !peer.binding.localIsInitiator {
            guard pairings[peer.binding.pairingID] == nil else { throw PersonalEnrollmentError.invalid() }
            pairings[peer.binding.pairingID] = try PeerPairing(enrollment: peer)
        }
        return try pairings.isEmpty ? nil : PeerExchangeResponder(pairings: Array(pairings.values))
    }
    func refreshNow() async {
        guard !stopped else { return }
        let generation = UUID()
        refreshID = generation
        var material: PersonalEnrollmentRuntimeMaterial?
        var materialError: String?
        if let bridge = enrollmentBridge {
            do {
                let candidate = try await bridge.material()
                try validateMaterial(candidate)
                material = candidate
            } catch { materialError = "enrollmentRuntimeUnavailable" }
        }
        guard !stopped, refreshID == generation else { return }
        do {
            let loaded = try await coordinator.loadPersonalPeerCredentials()
            for credential in loaded {
                try await coordinator.personalPeerValidate(credential.binding, controlOnly: true)
            }
            guard !stopped, refreshID == generation else { return }
            // A bad registry/context affects enrollment only. Canonical current credentials
            // and existing healthy data sessions remain available.
            var nextResponder: PeerExchangeResponder?
            do { nextResponder = try makeResponder(current: loaded, material: material) } catch {
                material = nil
                materialError = "enrollmentRuntimeUnavailable"
                nextResponder = try makeResponder(current: loaded, material: nil)
            }
            credentials = loaded
            enrollmentMaterial = material
            enrollmentErrorCode = materialError
            responder = nextResponder
            for (key, reservation) in reservations
            where !loaded.contains(where: { $0.binding == reservation.0 })
                && material?.retainedControlCredentials.contains(where: { $0.binding == reservation.0 })
                    != true
            {
                reservations[key] = nil
                // The physical accept task still owns this channel. Its ready admission
                // either fails current checks or adopts it for reply-flush retirement;
                // do not preempt a membership reply accepted just before refresh.
            }
            let retainedKeys = Set(loaded.map { Self.key($0.binding) })
            reports = reports.filter { retainedKeys.contains($0.key) }
            completedCuts = completedCuts.filter { retainedKeys.contains($0.key) }
            observations = observations.filter { retainedKeys.contains($0.key) }
            for (peer, session) in sessions {
                guard !stopped, refreshID == generation else { return }
                if !loaded.contains(where: { $0.binding == session.binding }) {
                    if material?.retainedControlCredentials.contains(where: { $0.binding == session.binding })
                        == true
                    {
                        sessions[peer] = nil
                        session.job?.cancel()
                        rememberEnrollment(
                            session.connection, binding: session.binding, purpose: .memberControl)
                    } else {
                        await remove(peer: peer, id: session.id)
                    }
                } else if session.controlOnly,
                    (try? await coordinator.personalPeerValidate(session.binding)) != nil,
                    var current = sessions[peer], current.id == session.id
                {
                    current.controlOnly = false
                    sessions[peer] = current
                }
            }
            guard !stopped, refreshID == generation else { return }
            retireWithdrawnEnrollment()
            lastErrorCode = nil
        } catch {
            guard refreshID == generation, !stopped else { return }
            lastErrorCode = (error as? TractandaError)?.code ?? "peerRuntimeUnavailable"
            credentials = []
            responder = nil
            enrollmentMaterial = material
            enrollmentErrorCode = materialError
            let reserved = Array(reservations.values)
            reservations = [:]
            for (_, channel) in reserved { try? await channel.close().get() }
            for (peer, session) in sessions { await remove(peer: peer, id: session.id) }
            // Enrollment is independent of the ordinary item/index startup path.
            responder = try? makeResponder(current: [], material: material)
            retireWithdrawnEnrollment()
        }
    }
    private func retireWithdrawnEnrollment() {
        let admitted = Set(
            (enrollmentMaterial?.privatePeers.map { Self.enrollmentKey($0.binding) } ?? [])
                + (enrollmentMaterial?.retainedControlCredentials.map { Self.enrollmentKey($0.binding) } ?? [])
        )
        for (key, task) in enrollmentDials where !admitted.contains(key) { task.cancel() }
        for (key, session) in enrollmentSessions {
            let retained =
                session.purpose == .memberControl
                ? enrollmentMaterial?.retainedControlCredentials.contains(where: {
                    $0.binding == session.binding
                }) == true
                : enrollmentMaterial?.privatePeers.contains(where: {
                    $0.binding == session.binding && $0.purpose == session.purpose
                }) == true
            if !retained { _ = session.connection.closeAfterReplyFlush() }
            // Keep its capacity slot until the actual close callback reaps it.
            if !session.connection.isActive { enrollmentSessions[key] = nil }
        }
    }
    private func rememberEnrollment(
        _ connection: PersonalPeerConnection, binding: PeerExchangeBinding,
        purpose: PersonalEnrollmentTransportPurpose
    ) {
        let key = Self.enrollmentKey(binding)
        let id = UUID()
        if let old = enrollmentSessions[key], old.connection.isActive {
            guard old.connection !== connection else { return }
            let retiringID = UUID()
            retiringEnrollment[retiringID] = connection
            connection.closeAfterReplyFlush().whenComplete { [self] _ in
                Task { await removeRetiringEnrollment(retiringID) }
            }
            return
        }
        enrollmentSessions[key] = .init(id: id, binding: binding, purpose: purpose, connection: connection)
        connection.closed.whenComplete { [self] _ in Task { await removeEnrollment(key, id: id) } }
    }
    private func removeRetiringEnrollment(_ id: UUID) { retiringEnrollment[id] = nil }
    private func removeEnrollment(_ key: String, id: UUID) {
        if enrollmentSessions[key]?.id == id { enrollmentSessions[key] = nil }
    }
    private func endpoints(for binding: PeerExchangeBinding) -> [PeerRuntimeConfiguration.Endpoint]? {
        if let local = configuration.peers.first(where: { $0.alias == binding.peerID }) {
            return local.endpoints
        }
        if let routes = enrollmentMaterial?.routes, routes.configurationDigest == binding.configurationDigest,
            let endpoints = routes.endpoints[binding.remoteReplicaID]
        {
            return endpoints.isEmpty ? nil : endpoints
        }
        return nil
    }
    func endpointsForTesting(_ binding: PeerExchangeBinding) -> [PeerRuntimeConfiguration.Endpoint]? {
        endpoints(for: binding)
    }
    func tick(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard accepting, !stopped else { return }
        if refresh == nil, now >= nextRefresh {
            nextRefresh = now + 5
            refresh = Task { [self] in
                await refreshNow()
                refresh = nil
            }
        }
        guard configuration.synchronization.enabled else { return }
        for (peer, session) in sessions
        where !session.controlOnly && session.job == nil && session.nextPull <= now
            && !controlPending.contains(peer)
        {
            if activeJobCount >= 2 { break }
            startPull(peer: peer)
        }
        guard !dialingSuspendedForTesting else { return }
        for credential in credentials where credential.binding.localIsInitiator {
            let binding = credential.binding
            guard sessions[Self.key(binding)] == nil,
                dialing[binding.peerID + binding.configurationDigest] == nil,
                dialing.count < 2, now >= nextDial[binding.peerID, default: 0],
                let endpoints = endpoints(for: binding), !endpoints.isEmpty,
                let slot = try? reserveDial(endpoints.count)
            else { continue }
            dialing[binding.peerID + binding.configurationDigest] = Task { [self] in
                defer { dialSlots[slot] = nil }
                do {
                    let pairing = try PeerPairing(credential: credential)
                    let connection = try await PersonalPeerConnector.connect(
                        group: group, endpoints: endpoints, pairing: pairing,
                        operations: operations(), resolver: resolver, limits: limits)
                    let admitted = try await connection.ready.get()
                    try await adopt(connection, binding: admitted, incoming: false)
                    failures[binding.peerID] = nil
                    nextDial[binding.peerID] = ProcessInfo.processInfo.systemUptime + 1
                } catch {
                    let count = min(8, failures[binding.peerID, default: 0] + 1)
                    failures[binding.peerID] = count
                    nextDial[binding.peerID] =
                        ProcessInfo.processInfo.systemUptime + min(300, pow(2, Double(count)))
                    lastErrorCode = (error as? TractandaError)?.code ?? "connectionFailed"
                    var observation = observations[Self.key(binding), default: Observation()]
                    observation.errorCode = lastErrorCode
                    observation.errorAt = Self.eventTime()
                    observations[Self.key(binding)] = observation
                }
                dialing[binding.peerID + binding.configurationDigest] = nil
            }
        }
    }
    private static func key(_ binding: PeerExchangeBinding) -> String {
        binding.remoteReplicaID + "|" + binding.configurationDigest
    }
    private var activeJobCount: Int { pullJobs.count }
    nonisolated func install(on channel: any Channel) -> EventLoopFuture<Void> {
        channel.eventLoop.makeFutureWithTask { try await self.accept(channel) }
    }
    private func accept(_ channel: any Channel) async throws {
        guard accepting, !stopped, connectionSlots < 64, let responder else {
            throw TractandaError("untrustedPeer", "No current personal pairing accepts this connection.")
        }
        let id = UUID()
        handshaking[id] = channel
        do {
            let connection = try await PersonalPeerConnection.install(
                on: channel, responder: responder, operations: operations(reserving: channel), limits: limits
            ).get()
            acceptingTasks[id] = Task { [self] in
                do {
                    let binding = try await connection.ready.get()
                    guard accepting, !stopped else { throw CancellationError() }
                    let admission = readyAdmissions[ObjectIdentifier(channel)]
                    if let admission, admission.0 == binding, admission.1 != .memberControl {
                        // Admission preceded the responder hello. A claim/finish may already
                        // have consumed its key before this ready callback reaches the actor.
                        rememberEnrollment(connection, binding: binding, purpose: admission.1)
                        retireWithdrawnEnrollment()
                    } else if (try? await coordinator.personalPeerValidate(binding, controlOnly: true)) == nil
                    {
                        guard admission?.0 == binding else {
                            throw TractandaError("untrustedPeer", "Missing physical peer admission.")
                        }
                        rememberEnrollment(connection, binding: binding, purpose: .memberControl)
                        retireWithdrawnEnrollment()
                    } else {
                        try await adopt(connection, binding: binding, incoming: true)
                    }
                    readyAdmissions[ObjectIdentifier(channel)] = nil
                } catch { try? await channel.close().get() }
                handshaking[id] = nil
                acceptingTasks[id] = nil
            }
        } catch {
            handshaking[id] = nil
            try? await channel.close().get()
            throw error
        }
    }
    private func adopt(
        _ connection: PersonalPeerConnection, binding: PeerExchangeBinding,
        incoming: Bool
    ) async throws {
        do {
            guard accepting, !stopped else { throw CancellationError() }
            try await coordinator.personalPeerValidate(binding, controlOnly: true)
            let controlOnly = (try? await coordinator.personalPeerValidate(binding)) == nil
            guard accepting, !stopped else { throw CancellationError() }
            let peer = Self.key(binding)
            while let previous = sessions[peer] {
                // Both ends choose the same physical socket when they dial concurrently.
                // Pairing IDs are shared random identities, never a role-as-master rule.
                guard binding.pairingID < previous.binding.pairingID || !previous.connection.isActive else {
                    try? await connection.close().get()
                    return
                }
                await remove(peer: peer, id: previous.id)
                // Removal suspends while the channel closes. A reentrant admission may
                // have installed another candidate, so compare again before publication.
                guard accepting, !stopped else { throw CancellationError() }
                try Task.checkCancellation()
            }
            let id = UUID()
            sessions[peer] = Session(
                id: id, binding: binding, connection: connection,
                incoming: incoming, controlOnly: controlOnly, job: nil, pullID: nil, currentPull: nil,
                progressDelivery: nil, nextPull: 0)
            var observation = observations[peer, default: Observation()]
            observation.connectedAt = Self.eventTime()
            observations[peer] = observation
            // The active session now protects this pairing; retain no extra handshake slot.
            let reservationKey = peer + "|" + binding.pairingID
            if let reservation = reservations[reservationKey], connection.uses(reservation.1) {
                reservations[reservationKey] = nil
            }
            connection.closed.whenComplete { [self] _ in Task { await remove(peer: peer, id: id) } }
            if !controlOnly, configuration.synchronization.enabled, activeJobCount < 2 {
                startPull(peer: peer)
            }
        } catch {
            try? await connection.close().get()
            throw error
        }
    }
    private func startPull(peer: String) {
        guard var session = sessions[peer], !session.controlOnly, session.job == nil, !stopped,
            !controlPending.contains(peer), !enrollmentFinalizing
        else { return }
        let id = session.id
        let pullID = UUID()
        session.pullID = pullID
        session.currentPull = try? .init(phase: .checkingReadiness)
        let delivery: @Sendable (PersonalPullProgress) async -> Void = { [self] progress in
            await recordProgress(progress, peer: peer, sessionID: id, pullID: pullID)
        }
        let mailbox = PersonalProgressMailbox(deliver: delivery)
        let progressSink: PersonalSyncProgressObserver = { mailbox.publish($0) }
        session.progressDelivery = delivery
        let connection = session.connection
        let binding = session.binding
        let chunkObserver = chunkObserverForTesting
        var observation = observations[peer, default: Observation()]
        observation.pullStartedAt = Self.eventTime()
        observations[peer] = observation
        session.job = Task { [self] in
            let result: Result<PersonalSyncReport?, Error>
            do {
                let remoteReadiness = try JSON.decode(
                    [String: Bool].self,
                    await connection.request(.init("personal.sync.ready")).get())
                if remoteReadiness["ready"] == true {
                    result = .success(
                        try await PersonalSyncDriver.pull(
                            connection: connection, coordinator: coordinator, binding: binding,
                            afterChunkForTesting: chunkObserver, observeProgress: progressSink))
                } else {
                    result = .success(nil)
                }
            } catch { result = .failure(error) }
            await finished(peer: peer, id: id, result: result)
        }
        sessions[peer] = session
        pullJobs[id] = session.job
    }
    private func recordProgress(_ progress: PersonalPullProgress, peer: String, sessionID: UUID, pullID: UUID)
    {
        guard var session = sessions[peer], session.id == sessionID, session.pullID == pullID,
            session.job != nil
        else { return }
        session.currentPull = progress
        sessions[peer] = session
    }
    func progressDeliveryForTesting(remoteReplicaID: String) -> (
        @Sendable (PersonalPullProgress) async -> Void
    )? {
        sessions.values.first { $0.binding.remoteReplicaID == remoteReplicaID }?.progressDelivery
    }
    private func finished(peer: String, id: UUID, result: Result<PersonalSyncReport?, Error>) async {
        defer {
            pullJobs[id] = nil
            resumePullWaiters(peer: peer, sessionID: id, error: stopped ? CancellationError() : nil)
        }
        guard !stopped, var session = sessions[peer], session.id == id else { return }
        // Retain the job slot while the cut callback suspends; otherwise a tick could
        // start another pull whose lifetime entry the old completion would then erase.
        session.pullID = nil
        session.currentPull = nil
        session.progressDelivery = nil
        session.nextPull =
            ProcessInfo.processInfo.systemUptime + Double(configuration.synchronization.intervalSeconds)
        sessions[peer] = session
        var observation = observations[peer, default: Observation()]
        observation.pullFinishedAt = Self.eventTime()
        switch result {
        case .success(let report):
            observation.outcome = report == nil ? .remoteNotReady : .complete
            if let report {
                reports[peer] = report
                completedCuts[peer] = min(Int.max - 1, completedCuts[peer, default: 0]) + 1
                if report.sourceCatalogueGeneration != nil, report.cutRowID != nil,
                    let bridge = enrollmentBridge
                {
                    await bridge.completedCut(session.binding, report)
                    guard sessions[peer]?.id == id, !stopped else { return }
                }
            } else if var current = sessions[peer], current.id == id {
                current.nextPull = ProcessInfo.processInfo.systemUptime + 1
                sessions[peer] = current
            }
            lastErrorCode = nil
        case .failure(let error):
            lastErrorCode = (error as? TractandaError)?.code ?? "peerSyncUnavailable"
            observation.outcome = .failed
            observation.errorCode = lastErrorCode
            observation.errorAt = Self.eventTime()
            observations[peer] = observation
            await remove(peer: peer, id: id)
            return
        }
        observations[peer] = observation
        if var current = sessions[peer], current.id == id {
            current.job = nil
            sessions[peer] = current
        }
    }
    private func remove(peer: String, id: UUID) async {
        guard let session = sessions[peer], session.id == id else { return }
        sessions[peer] = nil
        resumePullWaiters(peer: peer, sessionID: id, error: CancellationError())
        var observation = observations[peer, default: Observation()]
        observation.disconnectedAt = Self.eventTime()
        observations[peer] = observation
        session.job?.cancel()
        try? await session.connection.close().get()
        // The caller may be the driver's completion task; it cannot await itself. The
        // lifetime close owner retains/reaps all jobs separately before Store shutdown.
    }
    func deactivate() { accepting = false }
    func close() async {
        guard !stopped else { return }
        stopped = true
        accepting = false
        let waiting = pullWaiters
        pullWaiters = [:]
        for waiter in waiting.values { waiter.continuation.resume(throwing: CancellationError()) }
        refresh?.cancel()
        let dials = Array(dialing.values)
        let privateDials = Array(enrollmentDials.values)
        let controlDials = Array(currentControlDials.values)
        for task in controlDials { task.cancel() }
        let privateActive = Array(enrollmentSessions.values)
        let draining = Array(retiringEnrollment.values)
        for connection in draining { try? await connection.close().get() }
        for task in privateDials { task.cancel() }
        for session in privateActive { try? await session.connection.close().get() }
        let active = Array(sessions.values)
        let accepts = Array(acceptingTasks.values)
        let pulls = Array(pullJobs.values)
        for task in accepts + pulls { task.cancel() }
        for task in dials { task.cancel() }
        for session in active {
            session.job?.cancel()
            try? await session.connection.close().get()
        }
        for channel in handshaking.values { try? await channel.close().get() }
        for task in dials + accepts + pulls { await task.value }
        for task in privateDials { _ = try? await task.value }
        for task in controlDials { _ = try? await task.value }
        for session in privateActive { try? await session.connection.closed.get() }
        for connection in draining { try? await connection.closed.get() }
        for session in active {
            await session.job?.value
            try? await session.connection.closed.get()
        }
        await refresh?.value
        sessions = [:]
        dialing = [:]
        handshaking = [:]
        reservations = [:]
        readyAdmissions = [:]
        credentials = []
        responder = nil
        enrollmentSessions = [:]
        enrollmentDials = [:]
        currentControlDials = [:]
        enrollmentMaterial = nil
        enrollmentBridge = nil
        dialSlots = [:]
        controlPending = []
        retiringEnrollment = [:]
        try? await resolver.close()
    }
    private func waitForPull(peer: String) async throws {
        guard let session = sessions[peer], session.job != nil else { return }
        let waiterID = UUID()
        let sessionID = session.id
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pullWaiters[waiterID] = (peer, sessionID, continuation)
                if Task.isCancelled { cancelPullWaiter(waiterID) }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelPullWaiter(waiterID) }
        }
    }
    private func cancelPullWaiter(_ id: UUID) {
        pullWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
    private func resumePullWaiters(peer: String, sessionID: UUID, error: (any Error)?) {
        for (id, waiter) in pullWaiters where waiter.peer == peer && waiter.sessionID == sessionID {
            pullWaiters[id] = nil
            if let error { waiter.continuation.resume(throwing: error) } else { waiter.continuation.resume() }
        }
    }
    private func ensureCurrentConnection(
        remoteReplicaID: String, configurationDigest: String,
        cancellation: PersonalEnrollmentRequestCancellation? = nil
    ) async throws -> Session {
        let key = remoteReplicaID + "|" + configurationDigest
        if let session = sessions[key], session.connection.isActive { return session }
        guard
            let credential = credentials.first(where: {
                $0.binding.remoteReplicaID == remoteReplicaID
                    && $0.binding.configurationDigest == configurationDigest
                    && $0.binding.localIsInitiator
            }), let routes = endpoints(for: credential.binding), !routes.isEmpty
        else {
            throw TractandaError("membersOffline", "A required member has no current dial route.")
        }
        if let task = dialing[credential.binding.peerID + configurationDigest] {
            cancellation?.add { task.cancel() }
            await task.value
            try Task.checkCancellation()
            if let session = sessions[key], session.connection.isActive { return session }
        }
        if let task = currentControlDials[key] {
            cancellation?.add { task.cancel() }
            return try await task.value
        }
        let slot = try reserveDial(routes.count)
        let task = Task { [self] () async throws -> Session in
            defer {
                dialSlots[slot] = nil
                currentControlDials[key] = nil
            }
            let connection = try await PersonalPeerConnector.connect(
                group: group, endpoints: routes,
                pairing: PeerPairing(credential: credential), operations: operations(), resolver: resolver,
                limits: limits)
            do {
                let binding = try await connection.ready.get()
                try Task.checkCancellation()
                try await adopt(connection, binding: binding, incoming: false)
                guard let session = sessions[key], session.connection.isActive else {
                    throw TractandaError("membersOffline", "The current peer connection was not admitted.")
                }
                return session
            } catch {
                try? await connection.close().get()
                throw error
            }
        }
        currentControlDials[key] = task
        cancellation?.add { task.cancel() }
        return try await task.value
    }
    private func enrollmentConnection(
        binding: PeerExchangeBinding, purpose: PersonalEnrollmentTransportPurpose,
        endpoints: [PeerRuntimeConfiguration.Endpoint], pairing: PeerPairing,
        cancellation: PersonalEnrollmentRequestCancellation
    ) async throws -> PersonalPeerConnection {
        let key = Self.enrollmentKey(binding)
        if let session = enrollmentSessions[key], session.connection.isActive { return session.connection }
        if let task = enrollmentDials[key] {
            cancellation.add { task.cancel() }
            return try await task.value
        }
        let slot = try reserveDial(endpoints.count)
        let task = Task { [self] () async throws -> PersonalPeerConnection in
            defer {
                dialSlots[slot] = nil
                enrollmentDials[key] = nil
            }
            let connection = try await PersonalPeerConnector.connect(
                group: group, endpoints: endpoints,
                pairing: pairing, operations: operations(), resolver: resolver, limits: limits)
            do {
                _ = try await connection.ready.get()
                try await validateEnrollment(binding, purpose: purpose)
                try Task.checkCancellation()
                rememberEnrollment(connection, binding: binding, purpose: purpose)
                return enrollmentSessions[key]?.connection ?? connection
            } catch {
                try? await connection.close().get()
                throw error
            }
        }
        enrollmentDials[key] = task
        cancellation.add { task.cancel() }
        return try await task.value
    }
    func controlRequest(remoteReplicaID: String, configurationDigest: String, request: PeerExchangeRequest)
        async throws -> Data
    {
        let cancellation = PersonalEnrollmentRequestCancellation()
        return try await withTaskCancellationHandler {
            try await controlRequest(
                remoteReplicaID: remoteReplicaID, configurationDigest: configurationDigest,
                request: request, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }
    private func controlRequest(
        remoteReplicaID: String, configurationDigest: String, request: PeerExchangeRequest,
        cancellation: PersonalEnrollmentRequestCancellation
    ) async throws -> Data {
        guard PersonalEnrollmentJMAP.permits(request.operation, purpose: .memberControl), !stopped else {
            throw TractandaError(
                "unsupportedPeerOperation", "Expected a restricted enrollment member method.")
        }
        let peer = remoteReplicaID + "|" + configurationDigest
        guard !controlPending.contains(peer) else {
            throw TractandaError("serviceBusy", "Enrollment control is already active.")
        }
        controlPending.insert(peer)
        defer { controlPending.remove(peer) }
        // Every pull has a finite cut. Wait for it rather than colliding with its one
        // outstanding request or disrupting an otherwise healthy transfer.
        try await waitForPull(peer: peer)
        try Task.checkCancellation()
        let connection: PersonalPeerConnection
        let binding: PeerExchangeBinding
        if credentials.contains(where: {
            $0.binding.remoteReplicaID == remoteReplicaID
                && $0.binding.configurationDigest == configurationDigest
        }) {
            let session = try await ensureCurrentConnection(
                remoteReplicaID: remoteReplicaID, configurationDigest: configurationDigest,
                cancellation: cancellation)
            connection = session.connection
            binding = session.binding
        } else if let retained = enrollmentMaterial?.retainedControlCredentials.first(where: {
            $0.binding.remoteReplicaID == remoteReplicaID
                && $0.binding.configurationDigest == configurationDigest && $0.binding.localIsInitiator
        }), let endpoints = endpoints(for: retained.binding) {
            binding = retained.binding
            try await validateEnrollment(binding, purpose: .memberControl)
            connection = try await enrollmentConnection(
                binding: binding, purpose: .memberControl,
                endpoints: endpoints, pairing: PeerPairing(credential: retained), cancellation: cancellation)
        } else if let session = enrollmentSessions.values.first(where: {
            $0.purpose == .memberControl && $0.binding.remoteReplicaID == remoteReplicaID
                && $0.binding.configurationDigest == configurationDigest && $0.connection.isActive
        }) {
            binding = session.binding
            connection = session.connection
        } else {
            throw TractandaError(
                "membersOffline", "No exact current or retained member control connection is available.")
        }
        try await validateEnrollment(binding, purpose: .memberControl)
        cancellation.attach(connection)
        try Task.checkCancellation()
        return try await connection.request(request).get()
    }
    func privateRequest(binding: PeerExchangeBinding, request: PeerExchangeRequest) async throws -> Data {
        let cancellation = PersonalEnrollmentRequestCancellation()
        return try await withTaskCancellationHandler {
            try await privateRequest(binding: binding, request: request, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }
    func authenticateRenewalProbe(binding: PeerExchangeBinding) async throws
        -> PersonalEnrollmentAuthenticatedReady
    {
        let cancellation = PersonalEnrollmentRequestCancellation()
        return try await withTaskCancellationHandler {
            guard let peer = enrollmentMaterial?.privatePeers.first(where: { $0.binding == binding }),
                peer.purpose == .invitation, binding.localIsInitiator
            else {
                throw TractandaError("untrustedPeer", "No exact never-claimed renewal probe is available.")
            }
            let key = Self.enrollmentKey(binding)
            guard renewalProbeKeys.insert(key).inserted else {
                throw TractandaError("serviceBusy", "Renewal authentication is already active.")
            }
            defer { renewalProbeKeys.remove(key) }
            if let pending = enrollmentDials[key] {
                pending.cancel()
                _ = try? await pending.value
            }
            if let cached = enrollmentSessions.removeValue(forKey: key) {
                try? await cached.connection.close().get()
            }
            try await validateEnrollment(binding, purpose: .invitation)
            let connection = try await enrollmentConnection(
                binding: binding, purpose: .invitation,
                endpoints: peer.endpoints, pairing: PeerPairing(enrollment: peer), cancellation: cancellation)
            cancellation.attach(connection)
            let actual = try await connection.ready.get()
            guard actual == binding, connection.isActive else {
                throw TractandaError("membersOffline", "Renewal authentication disconnected.")
            }
            try Task.checkCancellation()
            let control = PeerExchangeControl.commitCompletion()
            connection.closed.whenComplete { _ in control.cancel() }
            return PersonalEnrollmentAuthenticatedReady(binding: actual, control: control)
        } onCancel: {
            cancellation.cancel()
        }
    }
    func cancelRenewalProbe(binding: PeerExchangeBinding) async {
        let key = Self.enrollmentKey(binding)
        if let pending = enrollmentDials[key] {
            pending.cancel()
            _ = try? await pending.value
        }
        if let session = enrollmentSessions[key], session.purpose == .invitation {
            enrollmentSessions.removeValue(forKey: key)
            try? await session.connection.close().get()
        }
    }
    private func privateRequest(
        binding: PeerExchangeBinding, request: PeerExchangeRequest,
        cancellation: PersonalEnrollmentRequestCancellation
    ) async throws -> Data {
        guard let peer = enrollmentMaterial?.privatePeers.first(where: { $0.binding == binding }),
            PersonalEnrollmentJMAP.permits(request.operation, purpose: peer.purpose)
        else {
            throw TractandaError("untrustedPeer", "No exact private enrollment route is available.")
        }
        try await validateEnrollment(binding, purpose: peer.purpose)
        let connection: PersonalPeerConnection
        if let accepted = enrollmentSessions[Self.enrollmentKey(binding)], accepted.connection.isActive {
            connection = accepted.connection
        } else {
            guard binding.localIsInitiator else {
                throw TractandaError(
                    "membersOffline", "The target has not established its exact private connection.")
            }
            connection = try await enrollmentConnection(
                binding: binding, purpose: peer.purpose,
                endpoints: peer.endpoints, pairing: PeerPairing(enrollment: peer), cancellation: cancellation)
        }
        cancellation.attach(connection)
        try Task.checkCancellation()
        return try await connection.request(request).get()
    }
    func withEnrollmentFinalization(
        remoteReplicaID: String, configurationDigest: String,
        action: @Sendable () async throws -> Void
    ) async throws {
        let peer = remoteReplicaID + "|" + configurationDigest
        guard accepting, !stopped, !enrollmentFinalizing, !controlPending.contains(peer), activeJobCount == 0,
            sessions[peer]?.job == nil, observations[peer]?.outcome == .complete,
            reports[peer]?.sourceCatalogueGeneration != nil, reports[peer]?.cutRowID != nil
        else {
            throw TractandaError(
                "baselineNotReady", "Actual transfer work must finish before baseline finalization.")
        }
        enrollmentFinalizing = true
        controlPending.insert(peer)
        defer {
            enrollmentFinalizing = false
            controlPending.remove(peer)
        }
        try Task.checkCancellation()
        try await action()
    }
    func commitEnrollment(
        preparation: PersonalMembershipPreparation,
        authorization: PersonalEnrollmentMembershipAuthorization
    ) async throws -> PersonalMembershipConfiguration {
        let cancellation = PersonalEnrollmentRequestCancellation()
        return try await withTaskCancellationHandler {
            try await commitEnrollment(
                preparation: preparation, authorization: authorization, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }
    private func commitEnrollment(
        preparation: PersonalMembershipPreparation,
        authorization: PersonalEnrollmentMembershipAuthorization,
        cancellation: PersonalEnrollmentRequestCancellation
    ) async throws -> PersonalMembershipConfiguration {
        guard accepting, !stopped else { throw CancellationError() }
        let identity = try await coordinator.personalEnrollmentIdentity(authorization: authorization)
        let capacity = try PersonalEnrollmentCapacity.preflight(
            current: authorization.plan.previousMembership,
            proposed: preparation.configuration, initiatingReplicaID: authorization.plan.issuerReplicaID,
            runtimeSocketLimit: 64, tlsContextLimit: 256, credentialRoleLimit: 512)
        let extra = max(0, capacity.maximumOverlappingSockets - sessions.count - enrollmentSessions.count)
        guard connectionSlots <= 64 - extra else {
            throw TractandaError(
                "enrollmentCapacityUnsupported",
                "Shared connection capacity is unavailable; membership was not changed.")
        }
        let bytes = try JSON.encode(preparation)
        let digest = try preparation.configuration.digest
        var acknowledgements: [PersonalMembershipOnlineAcknowledgement] = []
        if identity.membership != preparation.configuration {
            for replica in preparation.requiredOnlineReplicaIDs where replica != identity.replicaID {
                let key = replica + "|" + digest
                guard !controlPending.contains(key) else {
                    throw TractandaError("serviceBusy", "A membership control call is active.")
                }
                controlPending.insert(key)
                defer { controlPending.remove(key) }
                try await waitForPull(peer: key)
                let session = try await ensureCurrentConnection(
                    remoteReplicaID: replica, configurationDigest: digest, cancellation: cancellation)
                cancellation.attach(session.connection)
                try Task.checkCancellation()
                let ready = try JSON.decode(
                    PersonalMembershipReady.self,
                    await session.connection.request(
                        .init("personal.membership.ready", ["preparation": .bytes(bytes)])
                    ).get())
                let presence = PeerExchangeControl.commitCompletion()
                session.connection.closed.whenComplete { _ in presence.cancel() }
                guard session.connection.isActive else {
                    throw TractandaError("membersOffline", "A required member disconnected.")
                }
                acknowledgements.append(
                    try .init(binding: session.binding, response: ready, control: presence))
            }
        }
        guard accepting, !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        let committed = try await coordinator.personalEnrollmentCommitMembership(
            preparation: preparation,
            acknowledgements: acknowledgements, authorization: authorization)
        await refreshNow()
        return committed
    }
    func enrollmentCountsForTesting() -> (sessions: Int, dials: Int, slots: Int, error: String?) {
        (
            enrollmentSessions.count + retiringEnrollment.count, enrollmentDials.count, connectionSlots,
            enrollmentErrorCode
        )
    }

    func admin(_ request: PeerExchangeRequest, forUID uid: UInt32) async throws -> Data {
        // Authorize the actual Unix caller before asking peers or disclosing mesh state.
        let identity = try JSON.decode(
            PersonalSyncIdentity.self,
            await coordinator.personalPeerLocalRequest(.init("identity"), forUID: uid))
        if request.operation == "sync.status" {
            guard request.fields.isEmpty else {
                throw TractandaError("invalidArguments", "Sync status takes no fields.")
            }
            struct Row: Codable {
                let replicaID: String
                let configurationDigest: String
                let controlOnly: Bool
                let completedCuts: Int
                let report: PersonalSyncReport?
            }
            return try JSON.encode([
                "peers": sessions.map { key, value in
                    Row(
                        replicaID: value.binding.remoteReplicaID,
                        configurationDigest: value.binding.configurationDigest,
                        controlOnly: value.controlOnly, completedCuts: completedCuts[key, default: 0],
                        report: reports[key])
                }.sorted { $0.replicaID < $1.replicaID }
            ])
        }
        guard request.operation == "membership.commit", request.fields.count == 1,
            case .bytes(let bytes) = request.fields["preparation"]
        else {
            throw TractandaError("invalidArguments", "Expected one exact personal membership preparation.")
        }
        let preparation = try JSON.decode(PersonalMembershipPreparation.self, bytes)
        let digest = try preparation.configuration.digest
        var acknowledgements: [PersonalMembershipOnlineAcknowledgement] = []
        if identity.membership != preparation.configuration {
            for replica in preparation.requiredOnlineReplicaIDs where replica != identity.replicaID {
                guard
                    let session = sessions.values.first(where: {
                        $0.binding.remoteReplicaID == replica && $0.binding.configurationDigest == digest
                            && $0.connection.isActive
                    })
                else {
                    throw TractandaError(
                        "membersOffline",
                        "A required member has no authenticated current/proposed connection.")
                }
                let response = try JSON.decode(
                    PersonalMembershipReady.self,
                    await session.connection.request(
                        .init("personal.membership.ready", ["preparation": .bytes(bytes)])
                    ).get())
                let presence = PeerExchangeControl.commitCompletion()
                session.connection.closed.whenComplete { _ in presence.cancel() }
                guard session.connection.isActive else {
                    throw TractandaError("membersOffline", "A required member disconnected.")
                }
                acknowledgements.append(
                    try PersonalMembershipOnlineAcknowledgement(
                        binding: session.binding,
                        response: response, control: presence))
            }
        }
        let committed = try await coordinator.personalPeerCommitMembership(
            preparation: preparation,
            acknowledgements: acknowledgements, forUID: uid)
        await refreshNow()
        return try JSON.encode(committed)
    }

    func setChunkObserverForTesting(_ observer: PersonalChunkObserver?) { chunkObserverForTesting = observer }
    func interruptForTesting(remoteReplicaID: String) async {
        accepting = false
        for (key, session) in sessions where session.binding.remoteReplicaID == remoteReplicaID {
            await remove(peer: key, id: session.id)
        }
    }
    func setDialingSuspendedForTesting(_ value: Bool) { dialingSuspendedForTesting = value }
    func closeConnectionsForTesting(remoteReplicaID: String) async {
        let selected = sessions.filter { $0.value.binding.remoteReplicaID == remoteReplicaID }
        for (key, session) in selected {
            await remove(peer: key, id: session.id)
            await session.job?.value
        }
    }
    func connectForTesting(remoteReplicaID: String) async throws {
        guard
            let credential = credentials.first(where: {
                $0.binding.localIsInitiator && $0.binding.remoteReplicaID == remoteReplicaID
            }),
            let endpoints = configuration.peers.first(where: { $0.alias == credential.binding.peerID })?
                .endpoints
        else {
            throw TractandaError("untrustedPeer", "No current outbound fixture pairing.")
        }
        let slot = try reserveDial(endpoints.count)
        defer { dialSlots[slot] = nil }
        let connection = try await PersonalPeerConnector.connect(
            group: group, endpoints: endpoints,
            pairing: PeerPairing(credential: credential), operations: operations(), resolver: resolver,
            limits: limits)
        let binding = try await connection.ready.get()
        try await adopt(connection, binding: binding, incoming: false)
    }
    func lastReportForTesting(remoteReplicaID: String) -> PersonalSyncReport? {
        sessions.filter { $0.value.binding.remoteReplicaID == remoteReplicaID }.keys
            .compactMap { reports[$0] }.first
    }
    func requestPullForTesting(remoteReplicaID: String) {
        for (key, var session) in sessions
        where session.binding.remoteReplicaID == remoteReplicaID && !session.controlOnly {
            session.nextPull = 0
            sessions[key] = session
        }
    }
    func completedCutsForTesting(remoteReplicaID: String) -> Int {
        sessions.filter { $0.value.binding.remoteReplicaID == remoteReplicaID }.keys
            .map { completedCuts[$0, default: 0] }.max() ?? 0
    }
    func hasConnectionForTesting(remoteReplicaID: String) -> Bool {
        sessions.values.contains { $0.binding.remoteReplicaID == remoteReplicaID && $0.connection.isActive }
    }

    func operatorStatus() throws -> PeerOperatorRuntimeStatus {
        // Credentials are already loaded runtime bindings. Status never opens their files.
        let bindings = Dictionary(grouping: credentials.map(\.binding), by: Self.key)
        let peers = try bindings.keys.sorted().map { key -> PersonalPeerObservation in
            let binding = bindings[key]![0]
            let active = sessions[key].flatMap { $0.connection.isActive ? $0 : nil }
            let observation = observations[key] ?? Observation()
            let report = reports[key]
            return try .init(
                replicaID: binding.remoteReplicaID, configurationDigest: binding.configurationDigest,
                connected: active != nil,
                incomingConnectionCount: active?.incoming == true ? 1 : 0,
                outgoingConnectionCount: active?.incoming == false ? 1 : 0,
                controlOnly: active?.controlOnly, pullRunning: active?.job != nil,
                completedCuts: completedCuts[key, default: 0], currentPull: active?.currentPull,
                lastConnectedAt: observation.connectedAt, lastDisconnectedAt: observation.disconnectedAt,
                lastPullStartedAt: observation.pullStartedAt, lastPullFinishedAt: observation.pullFinishedAt,
                lastOutcome: observation.outcome, lastErrorCode: observation.errorCode,
                lastErrorAt: observation.errorAt, lastRevisionCount: report?.revisions,
                lastTransferredBytes: report?.transferredBytes,
                lastRevisionOutcomes: report?.outcomes ?? [:])
        }
        return try .init(
            state: stopped ? .stopped : accepting ? .active : .unavailable,
            configurationPath: configurationPath, settingsDigest: configuration.settingsDigest,
            synchronizationEnabled: configuration.synchronization.enabled,
            listenerConfigured: configuration.listen != nil, responderPublished: responder != nil,
            incomingConnectionCount: sessions.values.filter(\.incoming).count,
            outgoingConnectionCount: sessions.values.filter { !$0.incoming }.count,
            pendingConnectionCount: dialing.count + handshaking.count,
            lastErrorCode: lastErrorCode ?? enrollmentErrorCode,
            synchronization: .init(
                state: stopped
                    ? .stopped
                    : !configuration.synchronization.enabled ? .disabled : accepting ? .active : .unavailable,
                activeJobCount: activeJobCount,
                eligibleEdgeCount: Set(credentials.map { $0.binding.remoteReplicaID }).count,
                outcomeCounts: ["complete": reports.count], lastErrorCode: lastErrorCode),
            configuredPeers: configuration.peers, personalPeers: peers)
    }
}
