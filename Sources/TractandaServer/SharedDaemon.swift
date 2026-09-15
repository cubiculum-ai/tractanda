import Foundation
import NIOPosix
import TractandaCore
import TractandaWeb

public struct DaemonEndpoints: Codable, Sendable {
    public let socketPath: String
    public let httpURL: String?
    public let mcpURL: String?
    public let processID: Int32
}

public actor SharedDaemon {
    private let coordinator: ServiceCoordinator
    private let sessions: SessionAuthority
    private let application: DaemonApplication
    private let group: MultiThreadedEventLoopGroup
    private let unix: DaemonListener
    private let http: DaemonListener?
    private let readiness: DaemonReadiness
    private let endpointsValue: DaemonEndpoints
    private var maintenance: Task<Void, Never>?
    private var closed = false
    private var closing = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    public static func start(
        configuration: DaemonConfiguration,
        authenticator: any PasswordAuthenticating = SystemPasswordAuthenticator(),
        claimStartupReadiness: @Sendable () -> Bool = { true }
    ) async throws -> SharedDaemon {
        try configuration.validate()
        let nonce = Self.nonce()
        let manual = configuration.httpPort == nil ? Data() : try KanbanPage.manual()
        let page = try Self.page(configuration: configuration, nonce: nonce, fallback: manual)
        let coordinator = try await ServiceCoordinator(
            opening: URL(fileURLWithPath: configuration.storePath),
            indexDirectory: configuration.indexDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) })
        let sessions = SessionAuthority(coordinator: coordinator, authenticator: authenticator)
        let application = DaemonApplication(
            coordinator: coordinator, sessions: sessions, page: page, manual: manual, nonce: nonce)
        let readiness = DaemonReadiness()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        var unix: DaemonListener?
        var http: DaemonListener?
        do {
            unix = try await DaemonListeners.unix(
                group: group, socketPath: configuration.socketPath,
                permissions: try await coordinator.localSocketPermissions(), managed: configuration.managed,
                handler: { request, uid in
                    guard await readiness.isReady() else {
                        return try JSONSerialization.data(withJSONObject: [
                            "code": "serviceStarting", "message": "Service is starting.",
                        ])
                    }
                    return try await application.native(request, forUID: uid)
                })
            if let port = configuration.httpPort {
                http = try await DaemonListeners.http(
                    group: group, port: port,
                    handler: { request in
                        guard await readiness.isReady() else { return DaemonHTTPResponse(status: 503) }
                        return try await application.http(request)
                    })
            }
            guard claimStartupReadiness() else { throw CancellationError() }
            await readiness.activate()
            return SharedDaemon(
                coordinator: coordinator, sessions: sessions, application: application, group: group,
                unix: unix!, http: http, readiness: readiness,
                endpoints: .init(
                    socketPath: configuration.socketPath,
                    httpURL: http.map { "http://127.0.0.1:\($0.port ?? 0)" },
                    mcpURL: http.map { "http://127.0.0.1:\($0.port ?? 0)/mcp" }, processID: getpid()))
        } catch {
            await readiness.deactivate()
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
        readiness: DaemonReadiness,
        endpoints: DaemonEndpoints
    ) {
        self.coordinator = coordinator
        self.sessions = sessions
        self.application = application
        self.group = group
        self.unix = unix
        self.http = http
        self.readiness = readiness
        endpointsValue = endpoints
        maintenance = Task { [coordinator] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { try? await coordinator.maintain() }
            }
        }
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
        _ = await maintenance?.result
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
