import CTractandaPlatform
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import TractandaCore
import TractandaKanban

/// A single-user browser adapter. The item service remains the only store writer.
public enum LocalWebServer {
    public struct Session: Codable, Sendable {
        public let url: String
        public let viewItemID: String
        public let processID: Int32
    }

    public struct BoardConfiguration: Sendable {
        public let viewItemID: String?
        public let projectBoard: KanbanRepository.ProjectBoardConfiguration?

        public init(viewItemID: String) {
            self.viewItemID = viewItemID
            projectBoard = nil
        }
        public init(projectBoard: KanbanRepository.ProjectBoardConfiguration) {
            viewItemID = nil
            self.projectBoard = projectBoard
        }
        fileprivate var initialID: String { projectBoard?.initialProjectID ?? viewItemID! }
    }

    /// Binds IPv4 loopback only. The launch callback receives a fresh session capability.
    /// HTTP clients act as this adapter's OS account; the token is not an independent OS identity.
    public static func serve(
        socketPath: String, viewItemID: String, port: Int = 0,
        onStart: (Session) throws -> Void
    ) throws {
        try serve(
            connection: ServerConnection(socketPath: socketPath), viewItemID: viewItemID, port: port,
            onStart: onStart)
    }

    public static func serve(
        connection: ServerConnection, viewItemID: String, port: Int = 0,
        onStart: (Session) throws -> Void
    ) throws {
        try serve(
            connection: connection, board: BoardConfiguration(viewItemID: viewItemID), port: port,
            onStart: onStart)
    }

    public static func serve(
        connection: ServerConnection, board: BoardConfiguration, port: Int = 0,
        onStart: (Session) throws -> Void
    ) throws {
        guard (0...65535).contains(port) else {
            throw TractandaError("invalidPort", "Use a port from 0 through 65535.")
        }
        let repository = KanbanRepository(client: ItemClient(connection: connection))
        if let projectBoard = board.projectBoard {
            // A stale bookmark must not prevent the adapter from starting: the browser can
            // discover the remaining authorized projects and clear that selection.  Validate
            // the configured roots through the implicit All projects choice instead.
            _ = try repository.projectSnapshot(
                projectID: projectBoard.projectRootID, projectRootID: projectBoard.projectRootID,
                statusRootID: projectBoard.statusRootID)
        } else if let viewItemID = board.viewItemID {
            _ = try repository.snapshot(for: viewItemID)
        }
        let sessionToken = BrowserAuthentication.makeToken()
        let authentication = BrowserAuthentication(launchToken: sessionToken)
        let nonce = BrowserAuthentication.makeToken()
        let page = try KanbanPage.render(
            viewItemID: board.initialID, projectBoard: board.projectBoard, nonce: nonce)
        guard
            let manualURL = Bundle.module.url(
                forResource: "Manual", withExtension: "html", subdirectory: "Resources")
        else {
            throw TractandaError("missingResource", "The web client manual resource is unavailable.")
        }
        let manual = try Data(contentsOf: manualURL)
        let eventLoops = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let workers = NIOThreadPool(numberOfThreads: 2)
        workers.start()
        defer {
            try? workers.syncShutdownGracefully()
            try? eventLoops.syncShutdownGracefully()
        }
        let bootstrap = ServerBootstrap(group: eventLoops)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                    let boundPort = channel.localAddress!.port!
                    try channel.pipeline.syncOperations.addHandler(
                        KanbanHTTPHandler(
                            connection: connection, port: boundPort,
                            authentication: authentication, nonce: nonce, page: page, manual: manual,
                            workers: workers))
                }
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
        defer { try? channel.close().wait() }
        guard tractanda_start_signals() == 0 else {
            throw TractandaError("signalError", "Cannot install shutdown handlers.")
        }
        defer { tractanda_restore_signals() }
        let boundPort = channel.localAddress!.port!
        try onStart(
            Session(
                url: "http://127.0.0.1:\(boundPort)/#token=\(sessionToken)", viewItemID: board.initialID,
                processID: ProcessInfo.processInfo.processIdentifier))
        // The event loop handles I/O; this thread only observes the existing portable signal flag.
        while tractanda_stopping() == 0 && channel.isActive { Thread.sleep(forTimeInterval: 0.2) }
    }
}

private final class KanbanHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let connection: ServerConnection
    private let host: String
    private let authentication: BrowserAuthentication
    private let nonce: String
    private let page: Data
    private let manual: Data
    private let workers: NIOThreadPool
    private var requestHead: HTTPRequestHead?
    private var body = Data()
    private var hasFinished = false
    private var deadline: Scheduled<Void>?
    private static let maximumBodySize = 8 * 1024 * 1024

    init(
        connection: ServerConnection, port: Int, authentication: BrowserAuthentication, nonce: String,
        page: Data, manual: Data,
        workers: NIOThreadPool
    ) {
        self.connection = connection
        host = "127.0.0.1:\(port)"
        self.authentication = authentication
        self.nonce = nonce
        self.page = page
        self.manual = manual
        self.workers = workers
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        deadline = context.eventLoop.scheduleTask(in: .seconds(20)) { boundContext.value.close(promise: nil) }
    }
    func handlerRemoved(context: ChannelHandlerContext) { deadline?.cancel() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !hasFinished else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            let route = String(
                head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            guard head.headers["host"] == [host] else {
                fail(context, status: .forbidden, code: "invalidHost")
                return
            }
            // Bookmarkable selection is the sole shell query.  API and authentication routes
            // stay exact so a query string cannot create an alternate endpoint.
            if route != head.uri, !(route == "/" && head.method == .GET) {
                fail(context, status: .notFound, code: "notFound")
                return
            }
            if ["/", "/login", "/manual", "/manual.html"].contains(route), head.method == .GET { return }
            guard ["/api", "/auth/session", "/auth/login", "/auth/logout"].contains(route) else {
                fail(context, status: .notFound, code: "notFound")
                return
            }
            guard head.method == (route == "/auth/session" ? .GET : .POST) else {
                fail(context, status: .methodNotAllowed, code: "methodNotAllowed")
                return
            }
            let origins = head.headers["origin"]
            guard origins.isEmpty || origins == ["http://\(host)"],
                !head.headers["sec-fetch-site"].contains(where: { $0 == "cross-site" || $0 == "same-site" })
            else {
                fail(context, status: .forbidden, code: "invalidOrigin")
                return
            }
            if ["/api", "/auth/logout"].contains(route) {
                guard authentication.authorize(Self.bearerToken(head)) else {
                    fail(
                        context, status: .unauthorized, code: "unauthorized",
                        message: "Your session has expired. Sign in again.")
                    return
                }
            }
            if route == "/auth/session" { return }
            guard head.headers["content-type"].count == 1,
                head.headers["content-type"][0].split(separator: ";").first?.trimmingCharacters(
                    in: .whitespaces
                ).lowercased() == "application/json"
            else {
                fail(context, status: .unsupportedMediaType, code: "unsupportedMediaType")
                return
            }
            if let length = head.headers.first(name: "content-length"),
                let count = Int(length), count > Self.bodyLimit(for: route)
            {
                fail(context, status: .payloadTooLarge, code: "requestTooLarge")
            }
        case .body(let buffer):
            guard let route = requestHead?.uri, ["/api", "/auth/login", "/auth/logout"].contains(route),
                body.count <= Self.bodyLimit(for: route) - buffer.readableBytes
            else {
                fail(context, status: .payloadTooLarge, code: "requestTooLarge")
                return
            }
            body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let head = requestHead else {
                fail(context, status: .badRequest, code: "invalidRequest")
                return
            }
            hasFinished = true
            let route = String(
                head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            if ["/", "/login"].contains(route) {
                respond(context, status: .ok, data: page, contentType: "text/html; charset=utf-8")
                return
            }
            if ["/manual", "/manual.html"].contains(route) {
                respond(context, status: .ok, data: manual, contentType: "text/html; charset=utf-8")
                return
            }
            if route == "/auth/session" {
                respond(
                    context, status: .ok,
                    data: (try? JSON.encode(authentication.profile(for: Self.bearerToken(head)))) ?? Data())
                return
            }
            // An upload may finish after another connection signs out or the session expires.
            if ["/api", "/auth/logout"].contains(route), !authentication.authorize(Self.bearerToken(head)) {
                fail(
                    context, status: .unauthorized, code: "unauthorized",
                    message: "Your session has expired. Sign in again.")
                return
            }
            if route == "/auth/logout" {
                authentication.signOut(Self.bearerToken(head))
                respond(context, status: .ok, data: Data("{\"signedOut\":true}".utf8))
                return
            }
            let request = body
            body.removeAll(keepingCapacity: false)
            let connection = connection
            let authentication = authentication
            let isSignIn = route == "/auth/login"
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            let boundHandler = NIOLoopBound(self, eventLoop: context.eventLoop)
            workers.runIfActive(eventLoop: context.eventLoop) {
                if isSignIn {
                    guard let fields = try? JSONSerialization.jsonObject(with: request) as? [String: String],
                        Set(fields.keys) == ["username", "password"], let username = fields["username"],
                        let password = fields["password"]
                    else {
                        throw TractandaError("invalidCredentials", "Enter your account name and password.")
                    }
                    return try JSON.encode(authentication.signIn(username: username, password: password))
                }
                return try connection.send(request)
            }.whenComplete { result in
                let handler = boundHandler.value
                let context = boundContext.value
                switch result {
                case .success(let response): handler.respond(context, status: .ok, data: response)
                case .failure(let error):
                    if isSignIn {
                        let failure =
                            error as? TractandaError
                            ?? TractandaError(
                                "authenticationUnavailable", "OS sign-in is unavailable on this server.")
                        let status: HTTPResponseStatus =
                            failure.code == "signInLimited"
                            ? .tooManyRequests
                            : failure.code == "invalidCredentials" ? .unauthorized : .serviceUnavailable
                        handler.fail(context, status: status, code: failure.code, message: failure.message)
                    } else {
                        handler.fail(
                            context, status: .serviceUnavailable, code: "transportUnavailable",
                            message:
                                "The native service did not return an outcome. Retry mutations with identical arguments and operationID."
                        )
                    }
                }
            }
        }
    }

    private static func bearerToken(_ head: HTTPRequestHead) -> String? {
        let values = head.headers["authorization"]
        guard values.count == 1, values[0].hasPrefix("Bearer ") else { return nil }
        return String(values[0].dropFirst(7))
    }

    private static func bodyLimit(for route: String) -> Int {
        route == "/api" ? maximumBodySize : 16 * 1024
    }

    private func fail(
        _ context: ChannelHandlerContext, status: HTTPResponseStatus, code: String, message: String? = nil
    ) {
        hasFinished = true
        let data = (try? JSON.encode(TractandaError(code, message ?? code))) ?? Data()
        respond(context, status: status, data: data)
    }

    private func respond(
        _ context: ChannelHandlerContext, status: HTTPResponseStatus, data: Data,
        contentType: String = "application/json; charset=utf-8"
    ) {
        var headers = HTTPHeaders([
            ("Content-Type", contentType), ("Content-Length", String(data.count)), ("Connection", "close"),
            ("Cache-Control", "no-store"), ("Referrer-Policy", "no-referrer"),
            ("X-Content-Type-Options", "nosniff"),
            (
                "Content-Security-Policy",
                "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
            ),
        ])
        if status == .unauthorized { headers.add(name: "WWW-Authenticate", value: "Bearer") }
        if status == .tooManyRequests { headers.add(name: "Retry-After", value: "60") }
        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))),
            promise: nil)
        context.write(
            wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: data)))), promise: nil)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
    }
}
