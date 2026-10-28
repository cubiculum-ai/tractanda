import Foundation
import NIOPosix
import TractandaCore
import TractandaHTTPSIdentity
import TractandaPeerTransport
import TractandaWeb

public struct DaemonEndpoints: Codable, Sendable {
    public let socketPath: String
    public let httpURL: String?
    public let mcpURL: String?
    public let publicJMAPURL: String?
    /// A bound explicit transport endpoint, not a claim of peer admission or synchronization.
    public let peerHost: String?
    public let peerPort: Int?
    public let processID: Int32
}

public actor SharedDaemon {
    private let coordinator: ServiceCoordinator
    private let sessions: SessionAuthority
    private let application: DaemonApplication
    private let group: MultiThreadedEventLoopGroup
    private let unix: DaemonListener
    private let http: DaemonListener?
    private let publicHTTP: DaemonListener?
    private let publicApplication: PublicJMAPApplication?
    private let publicIdentity: HTTPSIdentityContextStore?
    private let publicConfiguration: PublicJMAPConfiguration?
    private let peer: DaemonListener?
    private let peerRuntime: PeerServiceRuntime?
    private let synchronization: PeerSyncRuntime?
    private let personalPeerRuntime: PersonalPeerRuntime?
    private let personalEnrollment: PersonalEnrollmentRuntime?
    private let readiness: DaemonReadiness
    private let endpointsValue: DaemonEndpoints
    private var maintenance: Task<Void, Never>?
    private var modelProvisioning: ModelProvisioningRuntime?
    private let peerClockMonitor: PeerClockMonitor
    private var closed = false
    private var closing = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    public static func start(
        configuration: DaemonConfiguration,
        authenticator: any PasswordAuthenticating = SystemPasswordAuthenticator(),
        claimStartupReadiness: @Sendable () -> Bool = { true }
    ) async throws -> SharedDaemon {
        try await startOwned(
            configuration: configuration, authenticator: authenticator,
            claimStartupReadiness: claimStartupReadiness, makeAccountDirectory: { SystemAccountDirectory() },
            peerLimits: .init(), syncLimits: .init())
    }
    /// Host-only fixture injection; no request/CLI can select an account provider or deadlines.
    static func startForTesting(
        configuration: DaemonConfiguration,
        makeAccountDirectory: @escaping @Sendable () -> any AccountDirectory,
        authenticator: any PasswordAuthenticating = SystemPasswordAuthenticator(),
        peerLimits: PeerConnectionLimits = .init(),
        syncLimits: PeerSyncLimits = .init(),
        personalChunkObserverForTesting: PersonalChunkObserver? = nil,
        modelProvisioningOriginForTesting: URL? = nil,
        claimStartupReadiness: @escaping @Sendable () -> Bool = { true }
    ) async throws -> SharedDaemon {
        try await startOwned(
            configuration: configuration, authenticator: authenticator,
            claimStartupReadiness: claimStartupReadiness, makeAccountDirectory: makeAccountDirectory,
            peerLimits: peerLimits, syncLimits: syncLimits,
            personalChunkObserverForTesting: personalChunkObserverForTesting,
            modelProvisioningOriginForTesting: modelProvisioningOriginForTesting)
    }
    private static func startOwned(
        configuration: DaemonConfiguration,
        authenticator: any PasswordAuthenticating,
        claimStartupReadiness: @Sendable () -> Bool,
        makeAccountDirectory: @escaping @Sendable () -> any AccountDirectory,
        peerLimits: PeerConnectionLimits, syncLimits: PeerSyncLimits,
        personalChunkObserverForTesting: PersonalChunkObserver? = nil,
        modelProvisioningOriginForTesting: URL? = nil
    ) async throws -> SharedDaemon {
        try configuration.validate()
        try configuration.publicJMAP?.prepareHeadlessPolicy()
        // An explicit personal profile is decoded before opening canonical content or
        // allocating listeners. Old authority runtime JSON cannot select this gateway.
        let personalConfiguration = try configuration.peerRuntimeConfigurationPath.map {
            try PersonalPeerRuntimeConfiguration.load(from: $0)
        }
        let peerConfiguration = personalConfiguration?.settings
        let nonce = Self.nonce()
        let manual = configuration.httpPort == nil ? Data() : try KanbanPage.manual()
        let page = try Self.page(configuration: configuration, nonce: nonce, fallback: manual)
        let coordinator = try await ServiceCoordinator(
            opening: URL(fileURLWithPath: configuration.storePath),
            indexDirectory: configuration.indexDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) },
            documentConverter: configuration.documentConverter,
            documentJobResources: configuration.documentJobResources ?? DocumentJobResources(),
            attachmentUploadPolicy: configuration.attachmentUploadPolicy ?? AttachmentUploadPolicy(),
            rebuildNoProgressTimeoutSeconds: configuration.rebuildNoProgressTimeoutSeconds ?? 120,
            makeAccountDirectory: makeAccountDirectory)
        do { try await coordinator.personalPeerCleanOrphanedWork() } catch {
            await coordinator.close()
            throw error
        }
        let blobs = JMAPBlobService(
            coordinator: coordinator,
            limits: try configuration.publicJMAP?.blobLimits()
                ?? JMAPBlobLimits(
                    maxSizeUpload: 50_000_000,
                    minimumFreeBytes: configuration.attachmentUploadPolicy?.minimumFreeBytes ?? 1024 * 1024
                        * 1024))
        let sessions = SessionAuthority(coordinator: coordinator, authenticator: authenticator)
        let application = DaemonApplication(
            coordinator: coordinator, sessions: sessions, page: page, manual: manual, nonce: nonce)
        await application.setBlobProvider(blobs)
        let readiness = DaemonReadiness()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        var unix: DaemonListener?
        var http: DaemonListener?
        var publicHTTP: DaemonListener?
        var publicApplication: PublicJMAPApplication?
        var publicIdentity: HTTPSIdentityContextStore?
        var notifications: JMAPEventHub?
        var peer: DaemonListener?
        var peerRuntime: PeerServiceRuntime?
        var synchronization: PeerSyncRuntime?
        var personalPeerRuntime: PersonalPeerRuntime?
        var personalEnrollment: PersonalEnrollmentRuntime?
        do {
            if let publicConfiguration = configuration.publicJMAP {
                publicIdentity = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(with: Result { try publicConfiguration.loadIdentity() })
                    }
                }
                let callbackTransport = try NIOJMAPCallbackTransport(
                    group: group, policy: publicConfiguration.callbackPolicy)
                let hub = try JMAPEventHub(
                    stateProvider: { try await coordinator.jmapVisibleStates(authentication: $0) },
                    callbackTransport: callbackTransport,
                    credentialResolver: { [weak sessions] id in
                        try await sessions?.authentication(credentialID: id)
                    })
                notifications = hub
                publicApplication = try PublicJMAPApplication(
                    coordinator: coordinator, sessions: sessions,
                    blobs: blobs, notifications: hub, baseURL: publicConfiguration.baseURL)
            }
            let eventProvider = notifications
            try await sessions.installResourceMethods { [blobs, weak eventProvider] authentication in
                var methods = try await blobs.methods(authentication: authentication)
                if let eventProvider {
                    for (name, method) in try await eventProvider.methods(authentication: authentication) {
                        methods[name] = method
                    }
                }
                return methods
            }
            if let peerConfiguration, let path = configuration.peerRuntimeConfigurationPath {
                let runtime = try PersonalPeerRuntime(
                    configuration: peerConfiguration, configurationPath: path,
                    coordinator: coordinator, group: group,
                    chunkObserverForTesting: personalChunkObserverForTesting)
                personalPeerRuntime = runtime
                if let endpoint = peerConfiguration.listen {
                    peer = try await DaemonListeners.peer(
                        group: group, host: endpoint.host, port: endpoint.port,
                        initialize: { runtime.install(on: $0) })
                }
                await runtime.refreshNow()
                let enrollment = PersonalEnrollmentRuntime(coordinator: coordinator, runtime: runtime)
                personalEnrollment = enrollment
                await application.setPersonalEnrollmentProvider { data, uid, principal in
                    try await enrollment.native(data, forUID: uid, principal: principal)
                }
            }
            let statusPersonal = personalPeerRuntime
            let statusRuntime = peerRuntime
            let statusSynchronization = synchronization
            await application.setPersonalPeerAdminProvider { request, uid in
                if ["membership.commit", "sync.status"].contains(request.operation) {
                    guard let statusPersonal else {
                        throw TractandaError(
                            "peerRuntimeUnavailable",
                            "Personal membership commit requires its configured runtime.")
                    }
                    return try await statusPersonal.admin(request, forUID: uid)
                }
                return try await coordinator.personalPeerLocalRequest(request, forUID: uid)
            }
            await application.setPeerStatusProvider {
                if let statusPersonal { return try await statusPersonal.operatorStatus() }
                if let statusRuntime {
                    let sync: PeerSynchronizationStatus
                    if let statusSynchronization {
                        sync = try await statusSynchronization.operatorStatus()
                    } else {
                        sync = try .init(state: .disabled)
                    }
                    let status = try await statusRuntime.operatorStatus(synchronization: sync)
                    return try .init(
                        state: status.state,
                        configurationPath: configuration.peerRuntimeConfigurationPath,
                        settingsDigest: peerConfiguration?.settingsDigest,
                        synchronizationEnabled: peerConfiguration?.synchronization.enabled ?? false,
                        listenerConfigured: status.listenerConfigured,
                        responderPublished: status.responderPublished,
                        incomingConnectionCount: status.incomingConnectionCount,
                        outgoingConnectionCount: status.outgoingConnectionCount,
                        pendingConnectionCount: status.pendingConnectionCount,
                        lastErrorCode: status.lastErrorCode, synchronization: status.synchronization)
                }
                return try .init(state: .disabled, synchronization: .init(state: .disabled))
            }
            unix = try await DaemonListeners.unixWithPrivateCredential(
                group: group, socketPath: configuration.socketPath,
                permissions: try await coordinator.localSocketPermissions(), managed: configuration.managed,
                handler: { request, uid in
                    guard await readiness.isReady() else {
                        return try JSONSerialization.data(withJSONObject: [
                            "code": "serviceStarting", "message": "Service is starting.",
                        ])
                    }
                    return try await application.native(request, forUID: uid)
                },
                privateBegin: { request, uid, control in
                    guard await readiness.isReady() else {
                        throw TractandaError("serviceBusy", "Service is starting or stopping.")
                    }
                    return try await application.beginPrivateCredential(
                        request, forUID: uid, control: control)
                },
                enrollmentBegin: { request, uid, control in
                    guard await readiness.isReady() else {
                        throw TractandaError("serviceBusy", "Service is starting or stopping.")
                    }
                    return try await application.beginPrivateEnrollment(
                        request, forUID: uid, control: control)
                },
                personalEnrollmentBegin: { request, uid, control in
                    guard await readiness.isReady() else {
                        throw TractandaError("serviceBusy", "Service is starting or stopping.")
                    }
                    return try await application.beginPrivatePersonalEnrollment(
                        request, forUID: uid, control: control)
                })
            if let port = configuration.httpPort {
                http = try await DaemonListeners.http(
                    group: group, port: port,
                    handler: { request in
                        guard await readiness.isReady() else { return DaemonHTTPResponse(status: 503) }
                        return try await application.http(request)
                    })
            }
            if let publicConfiguration = configuration.publicJMAP, let publicApplication {
                publicHTTP = try await DaemonListeners.publicJMAP(
                    group: group, configuration: publicConfiguration,
                    identity: publicIdentity, managed: configuration.managed,
                    begin: { request in
                        guard await readiness.isReady() else {
                            throw TractandaError("serviceBusy", "Service is starting or stopping.")
                        }
                        return try await publicApplication.begin(request)
                    })
            }
            guard claimStartupReadiness() else { throw CancellationError() }
            try Task.checkCancellation()
            await personalPeerRuntime?.activate()
            await personalEnrollment?.activate()
            await peerRuntime?.activate()
            await synchronization?.activate()
            await readiness.activate()
            await coordinator.startCanonicalVerification()
            let daemon = SharedDaemon(
                coordinator: coordinator, sessions: sessions, application: application, group: group,
                unix: unix!, http: http, publicHTTP: publicHTTP, publicApplication: publicApplication,
                publicIdentity: publicIdentity, publicConfiguration: configuration.publicJMAP, peer: peer,
                peerRuntime: peerRuntime,
                synchronization: synchronization, personalPeerRuntime: personalPeerRuntime,
                personalEnrollment: personalEnrollment,
                readiness: readiness,
                endpoints: .init(
                    socketPath: configuration.socketPath,
                    httpURL: http.map { "http://127.0.0.1:\($0.port ?? 0)" },
                    mcpURL: http.map { "http://127.0.0.1:\($0.port ?? 0)/mcp" },
                    publicJMAPURL: publicHTTP == nil ? nil : configuration.publicJMAP?.baseURL,
                    peerHost: peer == nil ? nil : peerConfiguration?.listen?.host,
                    peerPort: peer?.port, processID: getpid()))
            if let provisioning = configuration.modelProvisioning {
                try await daemon.startModelProvisioning(
                    provisioning, resumeDocumentJobs: configuration.documentConverter?.modelIsReady == false,
                    originForTesting: modelProvisioningOriginForTesting)
            }
            return daemon
        } catch {
            await readiness.deactivate()
            await personalEnrollment?.beginClose()
            await personalPeerRuntime?.deactivate()
            await peerRuntime?.deactivate()
            await synchronization?.close()
            try? await peer?.close()
            await personalPeerRuntime?.close()
            await personalEnrollment?.finishClose()
            await peerRuntime?.close()
            try? await publicHTTP?.close()
            await publicApplication?.close()
            await notifications?.close()
            try? await http?.close()
            try? await unix?.close()
            await application.close()
            await coordinator.close()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private init(
        coordinator: ServiceCoordinator, sessions: SessionAuthority, application: DaemonApplication,
        group: MultiThreadedEventLoopGroup, unix: DaemonListener, http: DaemonListener?,
        publicHTTP: DaemonListener?, publicApplication: PublicJMAPApplication?,
        publicIdentity: HTTPSIdentityContextStore?, publicConfiguration: PublicJMAPConfiguration?,
        peer: DaemonListener?, peerRuntime: PeerServiceRuntime?, synchronization: PeerSyncRuntime?,
        personalPeerRuntime: PersonalPeerRuntime?, personalEnrollment: PersonalEnrollmentRuntime?,
        readiness: DaemonReadiness,
        endpoints: DaemonEndpoints
    ) {
        self.coordinator = coordinator
        self.sessions = sessions
        self.application = application
        self.group = group
        self.unix = unix
        self.http = http
        self.publicHTTP = publicHTTP
        self.publicApplication = publicApplication
        self.publicIdentity = publicIdentity
        self.publicConfiguration = publicConfiguration
        self.peer = peer
        self.peerRuntime = peerRuntime
        self.synchronization = synchronization
        self.personalPeerRuntime = personalPeerRuntime
        self.personalEnrollment = personalEnrollment
        self.readiness = readiness
        endpointsValue = endpoints
        let sampler = NISTTimeSampler(group: group)
        let clockMonitor = PeerClockMonitor(
            prepare: { now, interval, configuration in
                try await coordinator.preparePeerClockSample(
                    monotonicNow: now, interval: interval, configuration: configuration)
            },
            finish: { lease, sample, now, interval in
                try await coordinator.finishPeerClockSample(
                    lease, sample: sample, monotonicNow: now, nextInterval: interval)
            },
            sample: { configuration in try await sampler.sample(configuration: configuration) })
        peerClockMonitor = clockMonitor
        maintenance = Task { [coordinator, clockMonitor, peerRuntime, synchronization, personalPeerRuntime] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled {
                    await personalPeerRuntime?.tick()
                    await peerRuntime?.tick()
                    await synchronization?.tick()
                    await clockMonitor.tick()
                    try? await coordinator.maintain()
                }
            }
        }
    }

    private func startModelProvisioning(
        _ configuration: ModelProvisioningConfiguration, resumeDocumentJobs: Bool, originForTesting: URL?
    ) async throws {
        let coordinator = self.coordinator
        let runtime = try ModelProvisioningRuntime(
            configuration: configuration, testingOrigin: originForTesting
        ) { artifact in
            if resumeDocumentJobs && artifact.identifier == "granite-docling-258m-mlx" {
                await coordinator.documentModelDidBecomeReady()
            }
        }
        modelProvisioning = runtime
        await application.setModelStatusProvider { runtime.workers.flatMap { $0.status() } }
    }

    /// Explicit management hook for externally replaced identities; no automatic CA/renewal service.
    public func reloadPublicHTTPSIdentity() async throws {
        guard !closed, let publicConfiguration, let publicIdentity else {
            throw TractandaError("unsupportedFeature", "Built-in public HTTPS is not configured.")
        }
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        _ = try publicIdentity.reload {
                            guard let replacement = try publicConfiguration.loadIdentity() else {
                                throw HTTPSIdentityError.identityUnavailable
                            }
                            return try replacement.contextForNewConnection(now: Date())
                        }
                    })
            }
        }
    }

    func coordinatorForTesting() -> ServiceCoordinator { coordinator }
    func peerRuntimeForTesting() -> PeerServiceRuntime? { peerRuntime }
    func personalPeerRuntimeForTesting() -> PersonalPeerRuntime? { personalPeerRuntime }
    func synchronizationForTesting() -> PeerSyncRuntime? { synchronization }
    package func connectPeer(peerID: String) async throws -> PeerExchangeConnection {
        guard !closed, let peerRuntime else {
            throw TractandaError("peerRuntimeUnavailable", "Peer runtime is disabled or closed.")
        }
        return try await peerRuntime.connect(peerID: peerID)
    }
    func setMaintenanceForTesting(_ task: Task<Void, Never>) {
        maintenance?.cancel()
        maintenance = task
    }
    public func endpoints() -> DaemonEndpoints { endpointsValue }

    public func close() async {
        if closed {
            if closing {
                await withCheckedContinuation { closeWaiters.append($0) }
            }
            return
        }
        closed = true
        closing = true
        await readiness.deactivate()
        maintenance?.cancel()
        await modelProvisioning?.close()
        await personalEnrollment?.beginClose()
        await personalPeerRuntime?.deactivate()
        await peerRuntime?.deactivate()
        await synchronization?.close()
        try? await peer?.close()
        await personalPeerRuntime?.close()
        await personalEnrollment?.finishClose()
        await peerRuntime?.close()
        await coordinator.requestBackgroundStop()
        await peerClockMonitor.close()
        _ = await maintenance?.result
        try? await publicHTTP?.close()
        await publicApplication?.close()
        try? await http?.close()
        try? await unix.close()
        await application.close()
        await sessions.close()
        await coordinator.close()
        try? await group.shutdownGracefully()
        closing = false
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private static func nonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }
    private static func page(configuration: DaemonConfiguration, nonce: String, fallback: Data) throws -> Data
    {
        if let view = configuration.viewItemID {
            return try KanbanPage.render(viewItemID: view, nonce: nonce)
        }
        guard let projectRoot = configuration.projectRootID, let statusRoot = configuration.statusRootID
        else { return fallback }
        return try KanbanPage.render(
            viewItemID: configuration.initialProjectID ?? projectRoot,
            projectBoard: .init(
                initialProjectID: configuration.initialProjectID ?? projectRoot, projectRootID: projectRoot,
                statusRootID: statusRoot), nonce: nonce)
    }
}

private actor DaemonReadiness {
    private var ready = false
    func activate() { ready = true }
    func deactivate() { ready = false }
    func isReady() -> Bool { ready }
}
