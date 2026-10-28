import CTractandaPlatform
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import TractandaCore
import TractandaHTTPSIdentity

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
  private let closeCompletion: EventLoopPromise<Void>

  public var port: Int? { channel.localAddress?.port }

  /// Force actual transport closure without releasing native work ownership; fixture-only.
  func closeChildrenForTesting() async {
    for child in connections.currentChildren() { await child.close(waitForNativeWork: false) }
  }

  fileprivate init(channel: Channel, connections: ConnectionRegistry, socket: OwnedSocket? = nil) {
    self.channel = channel
    self.connections = connections
    self.socket = socket
    self.closeCompletion = channel.eventLoop.makePromise(of: Void.self)
  }

  /// Stops accepting first, then closes every admitted child. Repeated calls are harmless.
  public func close() async throws {
    guard
      didClose.withLock({ closed in
        guard !closed else { return false }
        closed = true
        return true
      })
    else { return try await closeCompletion.futureResult.get() }

    let children = connections.stopAdmission()
    var closeFailure: (any Error)?
    do {
      try await channel.close().get()
    } catch {
      closeFailure = error
    }
    for child in children { await child.close() }
    if let socket { removeSocketIfOwned(socket) }
    if let closeFailure {
      closeCompletion.fail(closeFailure)
      throw closeFailure
    }
    closeCompletion.succeed(())
  }
}

public enum DaemonListeners {
  private static let maximumConnections = 64
  private static let maximumNativeFrame = 8 * 1024 * 1024
  private static let maximumHTTPBody = 8 * 1024 * 1024
  private static let maximumLoginBody = 16 * 1024
  private static let maximumHTTPHeaderBytes = 16 * 1024

  /// Only an explicitly configured peer endpoint calls this factory. Admission/TLS are
  /// supplied by the owned peer runtime, never by an HTTP/native request.
  static func peer(
    group: MultiThreadedEventLoopGroup, host: String, port: Int,
    initialize: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
  ) async throws -> DaemonListener {
    let connections = ConnectionRegistry(limit: maximumConnections)
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 64)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        guard connections.admit(channel) else { return channel.close() }
        return initialize(channel)
      }
    let channel = try await bootstrap.bind(host: host == "*" ? "0.0.0.0" : host, port: port).get()
    return DaemonListener(channel: channel, connections: connections)
  }

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

  static func publicJMAP(
    group: MultiThreadedEventLoopGroup, configuration: PublicJMAPConfiguration,
    identity: HTTPSIdentityContextStore?, managed: Bool,
    begin: @escaping @Sendable (PublicJMAPRequestHead) async throws -> any PublicJMAPRequestSink
  ) async throws -> DaemonListener {
    let connections = ConnectionRegistry(limit: maximumConnections)
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 64)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .childChannelOption(
        ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 65_536)
      )
      .childChannelOption(
        ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 65_536, high: 262_144)
      )
      .childChannelInitializer { channel in
        let work = NativeConnectionWork(eventLoop: channel.eventLoop)
        guard connections.admit(channel, nativeWork: work) else {
          work.finish()
          work.channelClosed()
          return channel.close()
        }
        let bound = NIOLoopBound(work, eventLoop: channel.eventLoop)
        let tls: EventLoopFuture<Void>
        do {
          if let identity {
            tls = channel.pipeline.addHandler(try identity.makeServerHandler(now: Date()))
          } else {
            tls = channel.eventLoop.makeSucceededVoidFuture()
          }
        } catch { tls = channel.eventLoop.makeFailedFuture(error) }
        let installed = tls.flatMap {
          channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
        }.flatMap {
          channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(
              JMAPHTTPStreamHandler(
                begin: begin, work: bound.value,
                bodyIdleSeconds: configuration.requestBodyIdleSeconds))
          }
        }
        installed.whenComplete { _ in bound.value.finish() }
        return installed
      }
    switch configuration.transport {
    case .builtinTLS(let host, let port, _):
      guard identity != nil else { throw HTTPSIdentityError.identityUnavailable }
      let channel = try await bootstrap.bind(host: host, port: port).get()
      return DaemonListener(channel: channel, connections: connections)
    case .trustedProxyUnix(let path):
      guard identity == nil, !path.contains("\0"), path.utf8.count <= 103 else {
        throw DaemonListenerError.invalidSocketPath
      }
      try configuration.validateProtectedProxyParents()
      if socketIdentity(at: path) != nil {
        guard managed, tractanda_remove_stale_socket(path) == 0 else {
          throw DaemonListenerError.socketExists
        }
      }
      let descriptor = tractanda_listen_mode(path, 0o600)
      guard descriptor >= 0, let socket = socketIdentity(at: path) else {
        if descriptor >= 0 { tractanda_close(descriptor) }
        throw DaemonListenerError.bindFailed
      }
      let owned = OwnedSocket(path: path, identity: socket)
      do {
        return DaemonListener(
          channel: try await bootstrap.withBoundSocket(descriptor).get(), connections: connections,
          socket: owned)
      } catch {
        removeSocketIfOwned(owned)
        throw error
      }
    }
  }

  public static func unix(
    group: MultiThreadedEventLoopGroup, socketPath: String, permissions: UInt32, managed: Bool,
    handler: @escaping @Sendable (Data, UInt32) async throws -> Data
  ) async throws -> DaemonListener {
    try await unixOwned(
      group: group, socketPath: socketPath, permissions: permissions, managed: managed,
      handler: handler, privateBegin: nil)
  }
  static func unixWithPrivateCredential(
    group: MultiThreadedEventLoopGroup, socketPath: String, permissions: UInt32, managed: Bool,
    connectionLimitForTesting: Int = maximumConnections,
    handler: @escaping @Sendable (Data, UInt32) async throws -> Data,
    privateBegin:
      @escaping @Sendable (Data, UInt32, PeerExchangeControl) async throws ->
      NativeCredentialRegistrationSession,
    enrollmentBegin: (
      @Sendable (Data, UInt32, PeerExchangeControl) async throws -> NativePeerEnrollmentSession
    )? = nil,
    personalEnrollmentBegin: (
      @Sendable (Data, UInt32, PeerExchangeControl) async throws -> NativePersonalEnrollmentSession
    )? = nil
  ) async throws -> DaemonListener {
    try await unixOwned(
      group: group, socketPath: socketPath, permissions: permissions, managed: managed,
      handler: handler, privateBegin: privateBegin, enrollmentBegin: enrollmentBegin,
      personalEnrollmentBegin: personalEnrollmentBegin,
      connectionLimit: connectionLimitForTesting)
  }
  private static func unixOwned(
    group: MultiThreadedEventLoopGroup, socketPath: String, permissions: UInt32, managed: Bool,
    handler: @escaping @Sendable (Data, UInt32) async throws -> Data,
    privateBegin: (
      @Sendable (Data, UInt32, PeerExchangeControl) async throws ->
        NativeCredentialRegistrationSession
    )?,
    enrollmentBegin: (
      @Sendable (Data, UInt32, PeerExchangeControl) async throws -> NativePeerEnrollmentSession
    )? = nil,
    personalEnrollmentBegin: (
      @Sendable (Data, UInt32, PeerExchangeControl) async throws -> NativePersonalEnrollmentSession
    )? = nil,
    connectionLimit: Int = maximumConnections
  ) async throws -> DaemonListener {
    guard (1...maximumConnections).contains(connectionLimit) else {
      throw DaemonListenerError.invalidLimit
    }
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

    let connections = ConnectionRegistry(limit: connectionLimit)
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 64)
      .childChannelInitializer { channel in
        let work = NativeConnectionWork(eventLoop: channel.eventLoop)
        guard connections.admit(channel, nativeWork: work) else {
          work.finish()
          work.channelClosed()
          return channel.close()
        }
        let boundWork = NIOLoopBound(work, eventLoop: channel.eventLoop)
        let installed = channel.eventLoop.submit {
          try channel.pipeline.syncOperations.addHandler(
            UnixConnectionHandler(
              handler: handler, maximumFrame: maximumNativeFrame, privateBegin: privateBegin,
              enrollmentBegin: enrollmentBegin, personalEnrollmentBegin: personalEnrollmentBegin, work: boundWork.value))
        }
        installed.whenComplete { _ in boundWork.value.finish() }
        return installed
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

private enum DaemonListenerError: Error {
  case invalidSocketPath, socketExists, bindFailed, invalidLimit
}

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
  var nativeDrain: EventLoopFuture<Void>? = nil

  func close(waitForNativeWork: Bool = true) async {
    await withCheckedContinuation { continuation in
      channel.eventLoop.execute {
        channel.value.close(promise: nil)
        channel.value.closeFuture.whenComplete { _ in
          if waitForNativeWork, let nativeDrain {
            nativeDrain.whenComplete { _ in continuation.resume() }
          } else {
            continuation.resume()
          }
        }
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

  func admit(_ channel: Channel, nativeWork: NativeConnectionWork? = nil) -> Bool {
    let identifier = ObjectIdentifier(channel)
    let child = ChildChannel(
      channel: NIOLoopBound(channel, eventLoop: channel.eventLoop), nativeDrain: nativeWork?.drained
    )
    let admitted = state.withLock { state in
      guard state.accepting, state.children.count < limit else { return false }
      state.children[identifier] = child
      return true
    }
    if admitted {
      let boundWork = nativeWork.map { NIOLoopBound($0, eventLoop: channel.eventLoop) }
      channel.closeFuture.whenComplete { [self] _ in
        if let boundWork {
          let work = boundWork.value
          work.channelClosed()
          work.drained.whenComplete { [self] _ in remove(identifier) }
        } else {
          remove(identifier)
        }
      }
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
  func currentChildren() -> [ChildChannel] { state.withLock { Array($0.children.values) } }

  private func remove(_ identifier: ObjectIdentifier) {
    _ = state.withLock { $0.children.removeValue(forKey: identifier) }
  }
}

/// The native child's existing connection slot covers its handler and all async obligations.
/// Only the channel event loop mutates this counter. Follow-up cleanup is charged before
/// releasing the operation that produced it, including a late successful authorization.
final class NativeConnectionWork {
  private let loop: EventLoop
  private let promise: EventLoopPromise<Void>
  // Installation owns the initial barrier, before handlerAdded can establish its own.
  private var pending = 1
  private var closed = false
  private var completed = false
  var drained: EventLoopFuture<Void> { promise.futureResult }
  init(eventLoop: EventLoop) {
    loop = eventLoop
    promise = eventLoop.makePromise(of: Void.self)
  }
  func begin() {
    loop.assertInEventLoop()
    precondition(!completed)
    pending += 1
  }
  func finish() {
    loop.assertInEventLoop()
    precondition(pending > 0)
    pending -= 1
    completeIfReady()
  }
  func channelClosed() {
    loop.assertInEventLoop()
    closed = true
    completeIfReady()
  }
  private func completeIfReady() {
    if closed && pending == 0 && !completed {
      completed = true
      promise.succeed(())
    }
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
    deadline = context.eventLoop.scheduleTask(in: .seconds(20)) {
      boundContext.value.close(promise: nil)
    }
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
    headers.reduce(into: 0) { total, header in
      total += header.name.utf8.count + header.value.utf8.count
    }
  }

  private func fail(_ context: ChannelHandlerContext, status: HTTPResponseStatus) {
    guard !dispatched else { return }
    dispatched = true
    deadline?.cancel()
    respond(
      context, version: head?.version ?? .http1_1,
      response: .init(status: Int(status.code), body: listenerErrorData))
  }

  private func respond(
    _ context: ChannelHandlerContext, version: HTTPVersion, response: DaemonHTTPResponse
  ) {
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
  private enum Phase: Equatable {
    case initial, ordinary, authorizing, readyWriting, payload, committing, replying, closed
  }
  private let handler: @Sendable (Data, UInt32) async throws -> Data
  private let privateBegin:
    (
      @Sendable (Data, UInt32, PeerExchangeControl) async throws ->
        NativeCredentialRegistrationSession
    )?
  private let maximumFrame: Int
  private let enrollmentBegin:
    (@Sendable (Data, UInt32, PeerExchangeControl) async throws -> NativePeerEnrollmentSession)?
  private let personalEnrollmentBegin:
    (@Sendable (Data, UInt32, PeerExchangeControl) async throws -> NativePersonalEnrollmentSession)?
  private var buffer = ByteBuffer()
  private var phase = Phase.initial
  private var markedBegin = false
  private var deadline: Scheduled<Void>?
  private var control: PeerExchangeControl?
  private var session: NativePrivateSession?
  private let work: NativeConnectionWork
  private var handlerOwned = false

  init(
    handler: @escaping @Sendable (Data, UInt32) async throws -> Data, maximumFrame: Int,
    privateBegin: (
      @Sendable (Data, UInt32, PeerExchangeControl) async throws ->
        NativeCredentialRegistrationSession
    )?,
    enrollmentBegin: (
      @Sendable (Data, UInt32, PeerExchangeControl) async throws -> NativePeerEnrollmentSession
    )?,
    personalEnrollmentBegin: (
      @Sendable (Data, UInt32, PeerExchangeControl) async throws -> NativePersonalEnrollmentSession
    )? = nil,
    work: NativeConnectionWork
  ) {
    self.handler = handler
    self.maximumFrame = maximumFrame
    self.privateBegin = privateBegin
    self.enrollmentBegin = enrollmentBegin
    self.personalEnrollmentBegin = personalEnrollmentBegin
    self.work = work
  }
  func handlerAdded(context: ChannelHandlerContext) {
    work.begin()
    handlerOwned = true
    let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
    deadline = context.eventLoop.scheduleTask(in: .seconds(20)) { bound.value.close(promise: nil) }
  }
  private func clearBuffer() {
    // Best effort only: NIO/Data may have copied the bytes already.
    _ = buffer.withUnsafeMutableReadableBytes { raw in
      raw.initializeMemory(as: UInt8.self, repeating: 0)
    }
    buffer = ByteBuffer()
  }
  private func cleanup(context: ChannelHandlerContext) {
    guard phase != .closed else { return }
    phase = .closed
    deadline?.cancel()
    control?.cancel()
    clearBuffer()
    if let session {
      self.session = nil
      cancelSession(session, context: context)
    }
    if handlerOwned {
      handlerOwned = false
      work.finish()
    }
  }
  private func cancelSession(_ session: NativePrivateSession, context: ChannelHandlerContext) {
    work.begin()
    let boundWork = NIOLoopBound(work, eventLoop: context.eventLoop)
    context.eventLoop.makeFutureWithTask { await session.cancel() }.whenComplete { _ in
      boundWork.value.finish()
    }
  }
  func handlerRemoved(context: ChannelHandlerContext) { cleanup(context: context) }
  func channelInactive(context: ChannelHandlerContext) {
    cleanup(context: context)
    context.fireChannelInactive()
  }
  func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
  private func reply(_ data: Data, context: ChannelHandlerContext) {
    guard phase != .closed else { return }
    phase = .replying
    let output = data.count <= maximumFrame ? data : listenerErrorData
    var framed = context.channel.allocator.buffer(capacity: output.count + 4)
    framed.writeInteger(UInt32(output.count))
    framed.writeBytes(output)
    let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
    context.writeAndFlush(NIOAny(framed)).whenComplete { _ in bound.value.close(promise: nil) }
  }
  private func completePrivateOutput(
    _ session: NativePrivateSession, context: ChannelHandlerContext
  ) {
    work.begin()
    let boundHandler = NIOLoopBound(self, eventLoop: context.eventLoop)
    let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
    context.eventLoop.makeFutureWithTask {
      let data = try await session.complete(nil)
      try await session.validateBeforeDelivery()
      return data
    }.whenComplete { result in
      let handler = boundHandler.value
      let context = boundContext.value
      defer { handler.work.finish() }
      guard handler.phase != .closed else { return }
      switch result {
      case .success(let data):
        do {
          try session.checkDelivery()
          handler.reply(
            data.count <= session.maximumReply
              ? data : session.failure(NativePeerEnrollment.failure()), context: context)
        } catch { handler.reply(session.failure(error), context: context) }
      case .failure(let error): handler.reply(session.failure(error), context: context)
      }
    }
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard phase == .initial || phase == .payload else {
      // Only bytes observed in this phase are rejected; kernel queues cannot prove send-time.
      control?.cancel()
      context.close(promise: nil)
      return
    }
    var incoming = unwrapInboundIn(data)
    if buffer.readableBytes < 4 {
      let count = min(4 - buffer.readableBytes, incoming.readableBytes)
      if var header = incoming.readSlice(length: count) { buffer.writeBuffer(&header) }
    }
    guard buffer.readableBytes >= 4,
      let rawLength: UInt32 = buffer.getInteger(at: buffer.readerIndex)
    else { return }
    markedBegin = phase == .initial && rawLength & 0x8000_0000 != 0
    let length = markedBegin ? rawLength & 0x7fff_ffff : rawLength
    let maximum =
      phase == .payload
      ? (session?.byteCount ?? 0)
      : markedBegin ? NativePeerCredentialRegistration.maximumBegin : maximumFrame
    guard length <= maximum else {
      context.close(promise: nil)
      return
    }
    if phase == .payload, Int(length) != session?.byteCount {
      context.close(promise: nil)
      return
    }
    let cap = maximum + 4
    guard incoming.readableBytes <= cap - buffer.readableBytes else {
      context.close(promise: nil)
      return
    }
    buffer.writeBuffer(&incoming)
    guard buffer.readableBytes >= 4 + Int(length) else { return }
    let request = Data(buffer.getBytes(at: buffer.readerIndex + 4, length: Int(length)) ?? [])
    let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
    let boundHandler = NIOLoopBound(self, eventLoop: context.eventLoop)
    if phase == .payload {
      guard buffer.readableBytes == 4 + Int(length), let session, let control else {
        context.close(promise: nil)
        return
      }
      clearBuffer()
      phase = .committing
      context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in
        boundContext.value.close(promise: nil)
      }
      do {
        try control.check()
        work.begin()
        context.eventLoop.makeFutureWithTask { try await session.complete(request) }.whenComplete {
          result in
          let handler = boundHandler.value
          let context = boundContext.value
          defer { handler.work.finish() }
          guard handler.phase != .closed else { return }
          switch result {
          case .success(let result):
            handler.reply(
              result.count <= session.maximumReply
                ? result : session.failure(NativePeerEnrollment.failure()), context: context)
          case .failure(let error): handler.reply(session.failure(error), context: context)
          }
        }
      } catch { reply(NativePeerCredentialRegistration.failure(error), context: context) }
      return
    }
    var uid: UInt32 = .max
    _ = try? context.channel.pipeline.syncOperations.withUnsafeTransportIfAvailable(
      of: NIOBSDSocket.Handle.self
    ) {
      _ = tractanda_peer_uid($0, &uid)
    }
    guard uid != .max else {
      context.close(promise: nil)
      return
    }
    let peer = uid
    if markedBegin {
      guard buffer.readableBytes == 4 + Int(length),
        request.count <= NativePeerCredentialRegistration.maximumBegin
      else {
        context.close(promise: nil)
        return
      }
      let begin: @Sendable (Data, UInt32, PeerExchangeControl) async throws -> NativePrivateSession
      let enrollment = request.starts(with: NativePeerEnrollment.prefix)
      let personal = request.starts(with: NativePersonalEnrollment.prefix)
      if personal {
        guard let personalEnrollmentBegin else { context.close(promise: nil); return }
        begin = { .personal(try await personalEnrollmentBegin($0, $1, $2)) }
      } else if enrollment {
        guard let enrollmentBegin else {
          context.close(promise: nil)
          return
        }
        begin = { .enrollment(try await enrollmentBegin($0, $1, $2)) }
      } else {
        guard let privateBegin else {
          context.close(promise: nil)
          return
        }
        begin = { .credential(try await privateBegin($0, $1, $2)) }
      }
      clearBuffer()
      phase = .authorizing
      context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in
        boundContext.value.close(promise: nil)
      }
      do {
        let control = try PeerExchangeControl(maximumSeconds: 20)
        self.control = control
        work.begin()
        context.eventLoop.makeFutureWithTask { try await begin(request, peer, control) }
          .whenComplete { result in
            let handler = boundHandler.value
            let context = boundContext.value
            defer { handler.work.finish() }
            switch result {
            case .failure(let error):
              handler.reply(
                personal ? NativePersonalEnrollment.failureData(error) : enrollment
                  ? NativePeerEnrollment.failure(error)
                  : NativePeerCredentialRegistration.failure(error), context: context)
            case .success(let session):
              guard handler.phase == .authorizing, context.channel.isActive,
                (try? control.check()) != nil
              else {
                control.cancel()
                handler.cancelSession(session, context: context)
                return
              }
              handler.session = session
              handler.phase = .readyWriting
              var output = context.channel.allocator.buffer(capacity: session.ready.count + 4)
              output.writeInteger(UInt32(session.ready.count))
              output.writeBytes(session.ready)
              context.writeAndFlush(NIOAny(output)).whenComplete { sent in
                let handler = boundHandler.value
                let context = boundContext.value
                guard handler.phase == .readyWriting else { return }
                switch sent {
                case .success:
                  if session.outputOnly {
                    handler.phase = .committing
                    handler.completePrivateOutput(session, context: context)
                  } else {
                    handler.phase = .payload
                    context.channel.setOption(ChannelOptions.autoRead, value: true)
                      .whenFailure { _ in boundContext.value.close(promise: nil) }
                  }
                case .failure: context.close(promise: nil)
                }
              }
            }
          }
      } catch { reply(NativePeerCredentialRegistration.failure(error), context: context) }
    } else {
      phase = .ordinary
      deadline?.cancel()
      buffer = ByteBuffer()
      let callback = handler
      work.begin()
      context.eventLoop.makeFutureWithTask { try await callback(request, peer) }.whenComplete {
        result in
        let handler = boundHandler.value
        let context = boundContext.value
        defer { handler.work.finish() }
        switch result {
        case .success(let response): handler.reply(response, context: context)
        case .failure: handler.reply(listenerErrorData, context: context)
        }
      }
    }
  }
}

private let listenerErrorData = Data(
  #"{"code":"listenerFailure","message":"The daemon could not complete the request."}"#.utf8)
