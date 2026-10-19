import Foundation
import NIOCore
import NIOPosix
import TractandaCore
import TractandaPeerTransport

/// Node-local network ownership. The separate synchronization owner leases its connector.
actor PeerServiceRuntime {
    private struct Publication: Sendable {
        let snapshot: PeerRuntimeSnapshot
        let responder: PeerExchangeResponder?
    }
    private struct Outgoing: Sendable {
        let id: UUID
        let connection: PeerExchangeConnection
    }
    private let coordinator: ServiceCoordinator
    private let group: MultiThreadedEventLoopGroup
    private let configuration: PeerRuntimeConfiguration
    private let limits: PeerConnectionLimits
    private let resolver: PeerNameResolver
    private let logicalScanEntries: Int
    private struct Logical {
        let id: UUID
        let snapshot: PeerRuntimeSnapshot
        let task: Task<PeerLogicalExchange, Error>
    }
    private var logical: [String: Logical] = [:]
    private var publication: Publication?
    private var lastAccepted: PeerRuntimeSnapshot?
    private var refreshRequest = UUID()
    private var refreshTask: Task<Void, Never>?
    private var nextRefresh: Double = 0
    private var incoming: [UUID: any Channel] = [:]
    private var incomingConnections: [UUID: PeerExchangeConnection] = [:]
    private var outgoing: [String: Outgoing] = [:]
    private var reservedPeers: Set<String> = []
    private var synchronizationLeases: Set<String> = []
    private var connecting: [String: Task<PeerExchangeConnection, Error>] = [:]
    private var pending = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false
    private var admitting = false
    private var logicalAttachedHookForTesting: (@Sendable () async -> Void)?
    private var refreshLoadedHookForTesting: (@Sendable () async -> Void)?
    private(set) var lastErrorCode: String?
    private static let maximumConnections = 64

    init(
        configuration: PeerRuntimeConfiguration, coordinator: ServiceCoordinator,
        group: MultiThreadedEventLoopGroup, limits: PeerConnectionLimits = .init(),
        resolver: PeerNameResolver? = nil, logicalScanEntriesForTesting: Int = 128
    ) throws {
        try limits.validate()
        guard (1...128).contains(logicalScanEntriesForTesting) else {
            throw TractandaError("resourceLimit", "Invalid logical scan window.")
        }
        self.logicalScanEntries = logicalScanEntriesForTesting
        self.configuration = configuration
        self.coordinator = coordinator
        self.group = group
        self.limits = limits
        self.resolver = resolver ?? PeerNameResolver(loop: group.next())
    }

    /// Called by existing service maintenance; the owned task performs Store work off NIO.
    func tick(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard !stopped, refreshTask == nil, now >= nextRefresh else { return }
        nextRefresh = now + 5
        refreshTask = Task { [self] in
            await refreshNow()
            refreshFinished()
        }
    }
    private func refreshFinished() { refreshTask = nil }
    func activate() { if !stopped { admitting = true } }

    func refreshNow() async {
        guard !stopped else { return }
        let request = UUID()
        refreshRequest = request
        pending += 1
        defer { finishWork() }
        do {
            let snapshot = try await coordinator.loadPeerRuntimeSnapshot()
            await refreshLoadedHookForTesting?()
            try Task.checkCancellation()
            let pairings = try snapshot.credentials.filter { !$0.binding.localIsInitiator }.map {
                try PeerPairing(credential: $0)
            }
            let responder = try pairings.isEmpty ? nil : PeerExchangeResponder(pairings: pairings)
            try await coordinator.validatePeerRuntimeSnapshot(snapshot)
            // Same-generation private-file loss/substitution is not an automatic key rotation.
            if let previous = lastAccepted, previous.securityToken == snapshot.securityToken {
                guard previous.hasSameCredentials(as: snapshot) else {
                    throw TractandaError(
                        "peerConfigurationChanged", "Private peer credentials changed without rotation.")
                }
            }
            guard !stopped, refreshRequest == request else { return }
            let changed = lastAccepted.map { !$0.hasSameAdmission(as: snapshot) } ?? false
            publication = Publication(snapshot: snapshot, responder: responder)
            lastAccepted = snapshot
            lastErrorCode = nil
            if changed {
                await invalidateLogical()
                await closeConnections()
            }
        } catch {
            guard !stopped, refreshRequest == request else { return }
            publication = nil
            lastErrorCode = (error as? TractandaError)?.code ?? "peerRuntimeUnavailable"
            await invalidateLogical()
            await closeConnections()
        }
    }

    /// One retained host-owned context per exact current credential. The opaque context ID
    /// never bypasses TLS, current private witnesses, canonical generation or security gates.
    private func logicalLease(
        _ binding: PeerExchangeBinding, publication expected: Publication,
        close: @escaping @Sendable () async -> Void
    ) async throws -> PeerLogicalExchange.Lease {
        try await authorize(expected)
        guard !binding.localIsInitiator else {
            throw TractandaError("invalidPeerRole", "Responder logical context requires its fixed role.")
        }
        guard
            expected.snapshot.credentials.contains(where: {
                $0.binding.peerID == binding.peerID && $0.binding.pairingID == binding.pairingID
                    && $0.binding.localIsInitiator == binding.localIsInitiator
                    && $0.binding.configurationDigest == binding.configurationDigest
            })
        else { throw TractandaError("untrustedPeer", "Logical context does not match current pairing.") }
        if let old = logical[binding.peerID], !old.snapshot.hasSameAdmission(as: expected.snapshot) {
            logical.removeValue(forKey: binding.peerID)
            if let context = try? await old.task.value { await context.invalidate() }
        }
        if logical[binding.peerID] == nil {
            guard logical.count < 256 else {
                throw TractandaError("resourceLimit", "Logical pairing capacity reached.")
            }
            let coordinator = coordinator
            let scanEntries = logicalScanEntries
            let task = Task {
                try await PeerLogicalExchange(
                    coordinator: coordinator, binding: binding,
                    snapshot: expected.snapshot, maximumScanEntries: scanEntries)
            }
            logical[binding.peerID] = Logical(id: UUID(), snapshot: expected.snapshot, task: task)
        }
        let entry = logical[binding.peerID]!
        let context: PeerLogicalExchange
        do { context = try await entry.task.value } catch {
            if logical[binding.peerID]?.id == entry.id { logical.removeValue(forKey: binding.peerID) }
            throw error
        }
        try await authorize(expected)
        guard logical[binding.peerID]?.id == entry.id else { throw CancellationError() }
        // A replaced attach owns no right to remove/invalidate the shared context. Its
        // generation-fenced failure is local to that socket, not the newer socket lease.
        let lease = try await context.attach(close: close)
        do {
            await logicalAttachedHookForTesting?()
            try Task.checkCancellation()
            try await authorize(expected)
            return lease
        } catch {
            await lease.detach()
            throw error
        }
    }
    private func invalidateLogical() async {
        let entries = Array(logical.values)
        logical.removeAll()
        for entry in entries { if let context = try? await entry.task.value { await context.invalidate() } }
    }

    /// NIO's initializer only starts this task; all Store/snapshot work runs outside its callback.
    nonisolated func install(on channel: any Channel) -> EventLoopFuture<Void> {
        let task = Task { try await self.accept(channel) }
        let deadline = channel.eventLoop.scheduleTask(
            in: .nanoseconds(Int64(limits.handshakeSeconds * 1_000_000_000))
        ) {
            task.cancel()
            channel.close(promise: nil)
        }
        channel.closeFuture.whenComplete { _ in task.cancel() }
        return channel.eventLoop.makeFutureWithTask {
            do {
                let connection = try await task.value
                connection.ready.whenComplete { _ in deadline.cancel() }
            } catch {
                deadline.cancel()
                channel.close(promise: nil)
                throw error
            }
        }
    }
    private func accept(_ channel: any Channel) async throws -> PeerExchangeConnection {
        guard !stopped, admitting,
            incoming.count + outgoing.count + reservedPeers.count < Self.maximumConnections,
            let publication, let responder = publication.responder
        else {
            throw TractandaError("untrustedPeer", "No current responder credentials are available.")
        }
        let id = UUID()
        incoming[id] = channel
        pending += 1
        defer { finishWork() }
        channel.closeFuture.whenComplete { [self] _ in Task { await removeIncoming(id) } }
        do {
            try await authorize(publication)
            try Task.checkCancellation()
            let connection = try await PeerExchangeConnection.install(
                on: channel, responder: responder,
                coordinator: coordinator, limits: limits.exchange,
                authorizeAdmission: { try await self.authorize(publication) },
                logicalLease: { binding, close in
                    try await self.logicalLease(binding, publication: publication, close: close)
                }
            ).get()
            try Task.checkCancellation()
            guard !stopped, incoming[id] === channel else { throw CancellationError() }
            incomingConnections[id] = connection
            return connection
        } catch {
            try? await channel.close().get()
            try? await channel.closeFuture.get()
            removeIncoming(id)
            throw error
        }
    }
    private func authorize(_ expected: Publication) async throws {
        guard !stopped, admitting, publication != nil else {
            throw TractandaError("serviceClosed", "Peer admission is unavailable.")
        }
        try await coordinator.validatePeerRuntimeSnapshot(expected.snapshot)
        guard !stopped, admitting, publication != nil else {
            throw TractandaError("serviceClosed", "Peer admission is unavailable.")
        }
    }
    private func removeIncoming(_ id: UUID) {
        incoming.removeValue(forKey: id)
        incomingConnections.removeValue(forKey: id)
    }

    /// Explicit, owned one-attempt connection; no background dialing or retry is started.
    func connect(peerID: String) async throws -> PeerExchangeConnection {
        guard !configuration.synchronization.enabled else {
            throw TractandaError(
                "serviceBusy", "The configured synchronization owner leases peer connections.")
        }
        return try await connectOwned(peerID: peerID)
    }
    private func connectOwned(peerID: String) async throws -> PeerExchangeConnection {
        guard !stopped, admitting, !reservedPeers.contains(peerID),
            incoming.count + outgoing.count + reservedPeers.count < Self.maximumConnections
        else {
            throw TractandaError("serviceBusy", "Peer connector is stopped or busy.")
        }
        reservedPeers.insert(peerID)
        pending += 1
        defer {
            reservedPeers.remove(peerID)
            connecting.removeValue(forKey: peerID)
            finishWork()
        }
        await refreshNow()
        guard !stopped, let publication,
            let endpoint = configuration.peers.first(where: { $0.alias == peerID })?.endpoint,
            let credential = publication.snapshot.credentials.first(where: { $0.binding.peerID == peerID })
        else {
            throw TractandaError("untrustedPeer", "Peer endpoint or current credentials are unavailable.")
        }
        guard credential.binding.localIsInitiator else {
            throw TractandaError("invalidPeerRole", "Only the configured initiator can connect.")
        }
        try await authorize(publication)
        if let existing = outgoing[peerID] {
            if existing.connection.isActive { return existing.connection }
            await closeSynchronizationConnection(peerID: peerID)
        }
        let pairing = try PeerPairing(credential: credential)
        let task = Task { [self] in
            try await PeerConnector.connect(
                group: group, host: endpoint.host, port: endpoint.port,
                pairing: pairing, coordinator: coordinator, resolver: resolver, limits: limits,
                authorizeAdmission: { try await self.authorize(publication) })
        }
        connecting[peerID] = task
        let connection = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        do {
            try Task.checkCancellation()
            try await authorize(publication)
            let id = UUID()
            outgoing[peerID] = Outgoing(id: id, connection: connection)
            connection.closed.whenComplete { [self] _ in Task { await removeOutgoing(peerID, id: id) } }
            return connection
        } catch {
            try? await connection.close().get()
            try? await connection.closed.get()
            throw error
        }
    }
    func synchronize(peerID: String, driver: PeerSyncDriver) async throws -> PeerSyncDriver.Report {
        guard !synchronizationLeases.contains(peerID) else {
            throw TractandaError("serviceBusy", "A synchronization job already owns this paired edge.")
        }
        synchronizationLeases.insert(peerID)
        defer { synchronizationLeases.remove(peerID) }
        do {
            let connection = try await connectOwned(peerID: peerID)
            let result = try await driver.run(connection: connection)
            await closeSynchronizationConnection(peerID: peerID)
            return result
        } catch {
            await closeSynchronizationConnection(peerID: peerID)
            throw error
        }
    }
    func closeSynchronizationConnection(peerID: String) async {
        if let entry = outgoing[peerID] {
            try? await entry.connection.close().get()
            try? await entry.connection.closed.get()
            removeOutgoing(peerID, id: entry.id)
        }
    }
    private func removeOutgoing(_ peerID: String, id: UUID) {
        if outgoing[peerID]?.id == id { outgoing.removeValue(forKey: peerID) }
    }

    private func closeConnections() async {
        for task in connecting.values { task.cancel() }
        let children = Array(incoming)
        let connections = Array(outgoing)
        for (id, channel) in children {
            try? await channel.close().get()
            try? await channel.closeFuture.get()
            removeIncoming(id)
        }
        for (peerID, value) in connections {
            try? await value.connection.close().get()
            try? await value.connection.closed.get()
            removeOutgoing(peerID, id: value.id)
        }
    }
    func deactivate() {
        stopped = true
        admitting = false
        publication = nil
        refreshRequest = UUID()
        refreshTask?.cancel()
    }
    func close() async {
        stopped = true
        admitting = false
        publication = nil
        refreshRequest = UUID()
        refreshTask?.cancel()
        await invalidateLogical()
        await closeConnections()
        while pending > 0 { await withCheckedContinuation { idleWaiters.append($0) } }
        await refreshTask?.value
        refreshTask = nil
        try? await resolver.close()
    }
    private func finishWork() {
        pending -= 1
        guard pending == 0 else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func operatorStatus(synchronization: PeerSynchronizationStatus) throws -> PeerOperatorRuntimeStatus {
        try .init(
            state: stopped ? .stopped : admitting ? .active : .unavailable,
            listenerConfigured: configuration.listen != nil,
            responderPublished: publication?.responder != nil,
            incomingConnectionCount: incoming.count, outgoingConnectionCount: outgoing.count,
            pendingConnectionCount: reservedPeers.count, lastErrorCode: lastErrorCode,
            synchronization: synchronization)
    }

    func setLogicalAttachedHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        logicalAttachedHookForTesting = hook
    }
    func setRefreshLoadedHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        refreshLoadedHookForTesting = hook
    }
    func isStoppedForTesting() -> Bool { stopped }
    func hasResponderForTesting() -> Bool { publication?.responder != nil }
    func connectionsForTesting() -> [PeerExchangeConnection] {
        Array(incomingConnections.values) + outgoing.values.map(\.connection)
    }
}
