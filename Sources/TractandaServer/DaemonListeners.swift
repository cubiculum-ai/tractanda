import CTractandaPlatform
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A listener owned by its caller's event-loop group. It has no signal or store responsibilities.
public final class DaemonListener: @unchecked Sendable {
    private let channel: Channel
    private let connections: ConnectionRegistry
    private let socket: OwnedSocket?
    private let didClose = Mutex(false)

    public var port: Int? { channel.localAddress?.port }

    fileprivate init(channel: Channel, connections: ConnectionRegistry, socket: OwnedSocket? = nil) {
        self.channel = channel
        self.connections = connections
        self.socket = socket
    }

    /// Stops accepting first, then closes every admitted child. Repeated calls are harmless.
    public func close() async throws {
        guard
            didClose.withLock({ closed in
                guard !closed else { return false }
                closed = true
                return true
            })
        else { return }

        let children = connections.stopAdmission()
        var closeFailure: (any Error)?
        do {
            try await channel.close().get()
        } catch {
            closeFailure = error
        }
        for child in children { await child.close() }
        if let socket { removeSocketIfOwned(socket) }
        if let closeFailure { throw closeFailure }
    }
}

public enum DaemonListeners {
    private static let maximumConnections = 64
    private static let maximumNativeFrame = 8 * 1024 * 1024
    private static let maximumHTTPBody = 8 * 1024 * 1024
    private static let maximumLoginBody = 16 * 1024
    private static let maximumHTTPHeaderBytes = 16 * 1024

    public static func http(
        group: MultiThreadedEventLoopGroup, port: Int,
        handler: @escaping @Sendable (DaemonHTTPRequest) async throws -> DaemonHTTPResponse
    ) async throws -> DaemonListener {
        let connections = ConnectionRegistry(limit: maximumConnections)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                guard connections.admit(channel) else { return channel.close() }
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.eventLoop.submit {
                        try channel.pipeline.syncOperations.addHandler(
                            HTTPConnectionHandler(
                                handler: handler, maximumBody: maximumHTTPBody,
                                maximumLoginBody: maximumLoginBody,
                                maximumHeaderBytes: maximumHTTPHeaderBytes))
                    }
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        return DaemonListener(channel: channel, connections: connections)
    }

    public static func unix(
        group: MultiThreadedEventLoopGroup, socketPath: String, permissions: UInt32, managed: Bool,
        handler: @escaping @Sendable (Data, UInt32) async throws -> Data
    ) async throws -> DaemonListener {
        guard !socketPath.contains("\0"), socketPath.utf8.count <= 103 else {
            throw DaemonListenerError.invalidSocketPath
        }
        // The caller holds the writer lock before managed startup. Do not use NIO's
        // cleanupExistingSocketFile: it unlinks arbitrary socket paths without ownership proof.
        if socketIdentity(at: socketPath) != nil {
            guard managed, tractanda_remove_stale_socket(socketPath) == 0 else {
                throw DaemonListenerError.socketExists
            }
        }
        let descriptor = tractanda_listen_mode(socketPath, permissions)
        guard descriptor >= 0, let identity = socketIdentity(at: socketPath) else {
            if descriptor >= 0 { tractanda_close(descriptor) }
            throw DaemonListenerError.bindFailed
        }

        let connections = ConnectionRegistry(limit: maximumConnections)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .childChannelInitializer { channel in
                guard connections.admit(channel) else { return channel.close() }
                return channel.eventLoop.submit {
                    try channel.pipeline.syncOperations.addHandler(
                        UnixConnectionHandler(handler: handler, maximumFrame: maximumNativeFrame))
                }
            }
        do {
            // This transfers the pre-bound descriptor to NIO. ServerSocket then has no pathname
            // cleanup ownership, so close below can verify the inode before unlinking.
            let channel = try await bootstrap.withBoundSocket(descriptor).get()
            return DaemonListener(
                channel: channel, connections: connections,
                socket: OwnedSocket(path: socketPath, identity: identity))
        } catch {
            removeSocketIfOwned(OwnedSocket(path: socketPath, identity: identity))
            throw error
        }
    }
}

private enum DaemonListenerError: Error { case invalidSocketPath, socketExists, bindFailed }

private struct SocketIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

private struct OwnedSocket: Sendable {
    let path: String
    let identity: SocketIdentity
}

private func socketIdentity(at path: String) -> SocketIdentity? {
    var metadata = stat()
    let socketMask = mode_t(S_IFMT)
    let socketType = mode_t(S_IFSOCK)
    guard
        path.withCString({ lstat($0, &metadata) }) == 0,
        metadata.st_mode & socketMask == socketType
    else {
        return nil
    }
    return SocketIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
}

private func removeSocketIfOwned(_ socket: OwnedSocket) {
    // Never delete a replacement, a regular file, or a socket with another identity. ENOENT is fine.
    guard socketIdentity(at: socket.path) == socket.identity else { return }
    _ = socket.path.withCString { unlink($0) }
}

private struct ChildChannel: Sendable {
    let channel: NIOLoopBound<Channel>

    func close() async {
        await withCheckedContinuation { continuation in
            channel.eventLoop.execute {
                channel.value.close().whenComplete { _ in continuation.resume() }
            }
        }
    }
}

/// Checked cross-event-loop admission state. Mutable request handlers remain event-loop confined.
private final class ConnectionRegistry: Sendable {
    private struct State: Sendable {
        var accepting = true
        var children: [ObjectIdentifier: ChildChannel] = [:]
    }

    private let limit: Int
    private let state = Mutex(State())

    init(limit: Int) { self.limit = limit }

    func admit(_ channel: Channel) -> Bool {
        let identifier = ObjectIdentifier(channel)
        let child = ChildChannel(channel: NIOLoopBound(channel, eventLoop: channel.eventLoop))
        let admitted = state.withLock { state in
            guard state.accepting, state.children.count < limit else { return false }
            state.children[identifier] = child
            return true
        }
        if admitted {
            channel.closeFuture.whenComplete { [self] _ in remove(identifier) }
        }
        return admitted
    }

    func stopAdmission() -> [ChildChannel] {
        state.withLock { state in
            state.accepting = false
            defer { state.children.removeAll() }
            return Array(state.children.values)
        }
    }

    private func remove(_ identifier: ObjectIdentifier) {
        _ = state.withLock { $0.children.removeValue(forKey: identifier) }
    }
}

private final class HTTPConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    private let handler: @Sendable (DaemonHTTPRequest) async throws -> DaemonHTTPResponse
    private let maximumBody: Int
    private let maximumLoginBody: Int
    private let maximumHeaderBytes: Int
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var dispatched = false
    private var deadline: Scheduled<Void>?

    init(
        handler: @escaping @Sendable (DaemonHTTPRequest) async throws -> DaemonHTTPResponse,
        maximumBody: Int, maximumLoginBody: Int, maximumHeaderBytes: Int
    ) {
        self.handler = handler
        self.maximumBody = maximumBody
        self.maximumLoginBody = maximumLoginBody
        self.maximumHeaderBytes = maximumHeaderBytes
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        deadline = context.eventLoop.scheduleTask(in: .seconds(20)) { boundContext.value.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) { deadline?.cancel() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let incomingHead):
            guard !dispatched, head == nil, headerBytes(incomingHead.headers) <= maximumHeaderBytes else {
                fail(context, status: .requestHeaderFieldsTooLarge)
                return
            }
            head = incomingHead
            if let value = incomingHead.headers.first(name: "content-length"),
                let length = Int(value), length > bodyLimit(for: incomingHead.uri)
            {
                fail(context, status: .payloadTooLarge)
            }
        case .body(var incomingBody):
            guard let head, !dispatched,
                body.readableBytes <= bodyLimit(for: head.uri) - incomingBody.readableBytes
            else {
                fail(context, status: .payloadTooLarge)
                return
            }
            body.writeBuffer(&incomingBody)
        case .end:
            guard let head, !dispatched else {
                context.close(promise: nil)
                return
            }
            dispatched = true
            deadline?.cancel()
            let headers = Dictionary(grouping: head.headers, by: { $0.name.lowercased() }).mapValues {
                $0.map(\.value)
            }
            let request = DaemonHTTPRequest(
                method: head.method.rawValue, uri: head.uri, headers: headers,
                body: Data(body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []),
                localPort: context.channel.localAddress?.port ?? 0)
            body.clear()
            let callback = handler
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            let boundHandler = NIOLoopBound(self, eventLoop: context.eventLoop)
            context.eventLoop.makeFutureWithTask { try await callback(request) }.whenComplete { result in
                let context = boundContext.value
                let handler = boundHandler.value
                switch result {
                case .success(let response) where response.body.count <= handler.maximumBody:
                    handler.respond(context, version: head.version, response: response)
                default:
                    handler.respond(
                        context, version: head.version, response: .init(status: 500, body: listenerErrorData))
                }
            }
        }
    }

    private func bodyLimit(for uri: String) -> Int {
        String(uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            == "/auth/login"
            ? maximumLoginBody : maximumBody
    }

    private func headerBytes(_ headers: HTTPHeaders) -> Int {
        headers.reduce(into: 0) { total, header in total += header.name.utf8.count + header.value.utf8.count }
    }

    private func fail(_ context: ChannelHandlerContext, status: HTTPResponseStatus) {
        guard !dispatched else { return }
        dispatched = true
        deadline?.cancel()
        respond(
            context, version: head?.version ?? .http1_1,
            response: .init(status: Int(status.code), body: listenerErrorData))
    }

    private func respond(_ context: ChannelHandlerContext, version: HTTPVersion, response: DaemonHTTPResponse)
    {
        var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
        if !headers.contains(name: "content-type") {
            headers.add(name: "content-type", value: "application/json; charset=utf-8")
        }
        headers.replaceOrAdd(name: "content-length", value: String(response.body.count))
        headers.replaceOrAdd(name: "connection", value: "close")
        context.write(
            NIOAny(
                HTTPServerResponsePart.head(
                    HTTPResponseHead(
                        version: version, status: HTTPResponseStatus(statusCode: response.status),
                        headers: headers))),
            promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
            boundContext.value.close(promise: nil)
        }
    }
}

private final class UnixConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let handler: @Sendable (Data, UInt32) async throws -> Data
    private let maximumFrame: Int
    private var buffer = ByteBuffer()
    private var dispatched = false
    private var deadline: Scheduled<Void>?

    init(handler: @escaping @Sendable (Data, UInt32) async throws -> Data, maximumFrame: Int) {
        self.handler = handler
        self.maximumFrame = maximumFrame
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        deadline = context.eventLoop.scheduleTask(in: .seconds(20)) { boundContext.value.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) { deadline?.cancel() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !dispatched else {
            context.close(promise: nil)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard buffer.readableBytes >= 4, let length: UInt32 = buffer.getInteger(at: buffer.readerIndex) else {
            return  // Fragmented frame header is valid.
        }
        guard length <= maximumFrame else {
            context.close(promise: nil)
            return
        }
        guard buffer.readableBytes >= 4 + Int(length) else {
            return  // Fragmented body is valid and retains its 20-second deadline.
        }
        var uid: UInt32 = .max
        _ = try? context.channel.pipeline.syncOperations.withUnsafeTransportIfAvailable(
            of: NIOBSDSocket.Handle.self
        ) { handle in
            _ = tractanda_peer_uid(handle, &uid)
        }
        guard uid != .max else {
            context.close(promise: nil)
            return
        }
        dispatched = true
        deadline?.cancel()
        let request = Data(buffer.getBytes(at: buffer.readerIndex + 4, length: Int(length)) ?? [])
        let callback = handler
        let peer = uid  // Kernel socket identity; never supplied by request bytes.
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let boundHandler = NIOLoopBound(self, eventLoop: context.eventLoop)
        context.eventLoop.makeFutureWithTask { try await callback(request, peer) }.whenComplete { result in
            let context = boundContext.value
            let handler = boundHandler.value
            let output: Data
            switch result {
            case .success(let response) where response.count <= handler.maximumFrame: output = response
            default: output = listenerErrorData
            }
            var framed = context.channel.allocator.buffer(capacity: output.count + 4)
            framed.writeInteger(UInt32(output.count))
            framed.writeBytes(output)
            context.writeAndFlush(NIOAny(framed)).whenComplete { _ in boundContext.value.close(promise: nil) }
        }
    }
}

private let listenerErrorData = Data(
    #"{"code":"listenerFailure","message":"The daemon could not complete the request."}"#.utf8)
