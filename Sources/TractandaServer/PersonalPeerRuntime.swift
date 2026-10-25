import Foundation
import NIOCore
import NIOPosix
import TractandaCore
import TractandaPeerTransport

/// One equivalent mesh member. TLS has directional contexts, while both endpoints own a
/// pull driver on every admitted connection. Local item writers never wait for this owner.
actor PersonalPeerRuntime {
    private struct Session {
        let id: UUID
        let binding: PeerExchangeBinding
        let connection: PersonalPeerConnection
        let incoming: Bool
        var controlOnly: Bool
        var job: Task<Void, Never>?
        var nextPull: Double
    }
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
    private var acceptingTasks: [UUID: Task<Void, Never>] = [:]
    private var pullJobs: [UUID: Task<Void, Never>] = [:]
    private var dialing: [String: Task<Void, Never>] = [:]
    private var nextDial: [String: Double] = [:]
    private var failures: [String: Int] = [:]
    private var reports: [String: PersonalSyncReport] = [:]
    private var completedCuts: [String: Int] = [:]
    private var refresh: Task<Void, Never>?
    private var nextRefresh: Double = 0
    private var accepting = false
    private var stopped = false
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
        resolver = PeerNameResolver(loop: group.next())
    }
    private nonisolated var operations: PersonalPeerOperations {
        PersonalPeerOperations(
            validate: { [coordinator] binding in
                try await coordinator.personalPeerValidate(binding, controlOnly: true)
            },
            handle: { [coordinator] binding, request in
                try await coordinator.personalPeerRequest(binding, request: request)
            })
    }
    func activate() { if !stopped { accepting = true } }
    func refreshNow() async {
        guard !stopped else { return }
        do {
            let loaded = try await coordinator.loadPersonalPeerCredentials()
            for credential in loaded {
                try await coordinator.personalPeerValidate(credential.binding, controlOnly: true)
            }
            let candidate = try loaded.filter { !$0.binding.localIsInitiator }.map {
                try PeerPairing(credential: $0)
            }
            let nextResponder = try candidate.isEmpty ? nil : PeerExchangeResponder(pairings: candidate)
            guard !stopped else { return }
            credentials = loaded
            let retainedKeys = Set(loaded.map { Self.key($0.binding) })
            reports = reports.filter { retainedKeys.contains($0.key) }
            completedCuts = completedCuts.filter { retainedKeys.contains($0.key) }
            responder = nextResponder
            for (peer, session) in sessions {
                if !loaded.contains(where: { $0.binding == session.binding }) {
                    await remove(peer: peer, id: session.id)
                } else if session.controlOnly,
                    (try? await coordinator.personalPeerValidate(session.binding)) != nil,
                    var current = sessions[peer], current.id == session.id
                {
                    current.controlOnly = false
                    sessions[peer] = current
                }
            }
            lastErrorCode = nil
        } catch {
            lastErrorCode = (error as? TractandaError)?.code ?? "peerRuntimeUnavailable"
            credentials = []
            responder = nil
            for (peer, session) in sessions { await remove(peer: peer, id: session.id) }
        }
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
        where !session.controlOnly && session.job == nil && session.nextPull <= now {
            if activeJobCount >= 2 { break }
            startPull(peer: peer)
        }
        guard !dialingSuspendedForTesting else { return }
        for credential in credentials where credential.binding.localIsInitiator {
            let binding = credential.binding
            guard sessions[Self.key(binding)] == nil,
                dialing[binding.peerID + binding.configurationDigest] == nil,
                dialing.count < 2, now >= nextDial[binding.peerID, default: 0],
                let endpoint = configuration.peers.first(where: { $0.alias == binding.peerID })?.endpoint
            else { continue }
            dialing[binding.peerID + binding.configurationDigest] = Task { [self] in
                do {
                    let pairing = try PeerPairing(credential: credential)
                    let connection = try await PersonalPeerConnector.connect(
                        group: group, host: endpoint.host, port: endpoint.port, pairing: pairing,
                        operations: operations, resolver: resolver, limits: limits)
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
        guard accepting, !stopped, sessions.count + handshaking.count < 64, let responder else {
            throw TractandaError("untrustedPeer", "No current personal pairing accepts this connection.")
        }
        let id = UUID()
        handshaking[id] = channel
        do {
            let connection = try await PersonalPeerConnection.install(
                on: channel, responder: responder, operations: operations, limits: limits
            ).get()
            acceptingTasks[id] = Task { [self] in
                do {
                    let binding = try await connection.ready.get()
                    try await adopt(connection, binding: binding, incoming: true)
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
                incoming: incoming, controlOnly: controlOnly, job: nil, nextPull: 0)
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
        guard var session = sessions[peer], !session.controlOnly, session.job == nil, !stopped else { return }
        let id = session.id
        let connection = session.connection
        let binding = session.binding
        let chunkObserver = chunkObserverForTesting
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
                            afterChunkForTesting: chunkObserver))
                } else {
                    result = .success(nil)
                }
            } catch { result = .failure(error) }
            await finished(peer: peer, id: id, result: result)
        }
        sessions[peer] = session
        pullJobs[id] = session.job
    }
    private func finished(peer: String, id: UUID, result: Result<PersonalSyncReport?, Error>) async {
        defer { pullJobs[id] = nil }
        guard var session = sessions[peer], session.id == id else { return }
        session.job = nil
        session.nextPull =
            ProcessInfo.processInfo.systemUptime + Double(configuration.synchronization.intervalSeconds)
        sessions[peer] = session
        switch result {
        case .success(let report):
            if let report {
                reports[peer] = report
                completedCuts[peer] = min(Int.max - 1, completedCuts[peer, default: 0]) + 1
            } else if var current = sessions[peer], current.id == id {
                current.nextPull = ProcessInfo.processInfo.systemUptime + 1
                sessions[peer] = current
            }
            lastErrorCode = nil
        case .failure(let error):
            lastErrorCode = (error as? TractandaError)?.code ?? "peerSyncUnavailable"
            await remove(peer: peer, id: id)
        }
    }
    private func remove(peer: String, id: UUID) async {
        guard let session = sessions[peer], session.id == id else { return }
        sessions[peer] = nil
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
        refresh?.cancel()
        let dials = Array(dialing.values)
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
        for session in active {
            await session.job?.value
            try? await session.connection.closed.get()
        }
        await refresh?.value
        sessions = [:]
        dialing = [:]
        handshaking = [:]
        credentials = []
        responder = nil
        try? await resolver.close()
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
            let endpoint = configuration.peers.first(where: { $0.alias == credential.binding.peerID })?
                .endpoint
        else {
            throw TractandaError("untrustedPeer", "No current outbound fixture pairing.")
        }
        let connection = try await PersonalPeerConnector.connect(
            group: group, host: endpoint.host, port: endpoint.port,
            pairing: PeerPairing(credential: credential), operations: operations, resolver: resolver,
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
        try .init(
            state: stopped ? .stopped : accepting ? .active : .unavailable,
            configurationPath: configurationPath, settingsDigest: configuration.settingsDigest,
            synchronizationEnabled: configuration.synchronization.enabled,
            listenerConfigured: configuration.listen != nil, responderPublished: responder != nil,
            incomingConnectionCount: sessions.values.filter(\.incoming).count,
            outgoingConnectionCount: sessions.values.filter { !$0.incoming }.count,
            pendingConnectionCount: dialing.count + handshaking.count, lastErrorCode: lastErrorCode,
            synchronization: .init(
                state: stopped
                    ? .stopped
                    : !configuration.synchronization.enabled ? .disabled : accepting ? .active : .unavailable,
                activeJobCount: activeJobCount,
                eligibleEdgeCount: Set(credentials.map { $0.binding.remoteReplicaID }).count,
                outcomeCounts: ["complete": reports.count], lastErrorCode: lastErrorCode))
    }
}
