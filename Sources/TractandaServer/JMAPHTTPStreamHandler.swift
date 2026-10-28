import Foundation
import NIOCore
import NIOHTTP1
import TractandaCore

/// HTTP/1 streaming binding. Only structured API/login JSON is aggregated; binary bodies have a bounded queue.
final class JMAPHTTPStreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    private let begin: @Sendable (PublicJMAPRequestHead) async throws -> any PublicJMAPRequestSink
    private var head: HTTPRequestHead?
    private var sink: (any PublicJMAPRequestSink)?
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var ended = false
    private var busy = false
    private var responding = false
    private var inactive = false
    private var operation: Task<Void, Never>?
    private var authorizationMonitor: Task<Void, Never>?
    private var headerDeadline: Scheduled<Void>?
    private var bodyIdle: Scheduled<Void>?
    private let bodyIdleSeconds: Double
    private var writer: JMAPHTTPWriter?
    private let work: NativeConnectionWork?
    init(
        begin: @escaping @Sendable (PublicJMAPRequestHead) async throws -> any PublicJMAPRequestSink,
        work: NativeConnectionWork? = nil, bodyIdleSeconds: Double = 3600
    ) {
        self.begin = begin
        self.work = work
        self.bodyIdleSeconds = bodyIdleSeconds
    }

    func handlerAdded(context: ChannelHandlerContext) {
        writer = JMAPHTTPWriter(channel: context.channel)
        armHeaderDeadline(context)
    }
    private func armHeaderDeadline(_ context: ChannelHandlerContext) {
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        // Header admission only. A healthy upload/download/event stream has no absolute body deadline.
        headerDeadline = context.eventLoop.scheduleTask(in: .seconds(60)) { bound.value.close(promise: nil) }
    }
    private func terminate(_ context: ChannelHandlerContext) {
        guard !inactive else { return }
        inactive = true
        operation?.cancel()
        authorizationMonitor?.cancel()
        headerDeadline?.cancel()
        bodyIdle?.cancel()
        writer?.closed()
        if let sink { cancel(sink, context: context) }
        self.sink = nil
        pending.removeAll()
        pendingBytes = 0
    }
    func channelInactive(context: ChannelHandlerContext) {
        terminate(context)
        context.fireChannelInactive()
    }
    func handlerRemoved(context: ChannelHandlerContext) {
        terminate(context)
        context.close(promise: nil)
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        operation?.cancel()
        context.close(promise: nil)
    }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        writer?.writabilityChanged()
        context.fireChannelWritabilityChanged()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !inactive else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard self.head == nil, !responding,
                head.uri.utf8.count <= 16 * 1024,
                head.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 16 * 1024
            else {
                fail(
                    context, PublicJMAPHTTPError(400, "invalidHeaders", "Invalid or pipelined request head."))
                return
            }
            self.head = head
            headerDeadline?.cancel()
            busy = true
            pause(context)
            let request = PublicJMAPRequestHead(
                method: head.method.rawValue, uri: head.uri,
                headers: Dictionary(grouping: head.headers, by: { $0.name.lowercased() }).mapValues {
                    $0.map(\.value)
                })
            let begin = begin
            run(
                context, operation: { try await begin(request) },
                complete: { handler, context, result in
                    handler.busy = false
                    switch result {
                    case .success(let sink):
                        guard !handler.inactive else {
                            handler.cancel(sink, context: context)
                            return
                        }
                        handler.sink = sink
                        handler.monitorAuthorization(sink, context: context)
                        if head.headers.first(name: "expect")?.lowercased() == "100-continue" {
                            context.writeAndFlush(
                                NIOAny(
                                    HTTPServerResponsePart.head(
                                        .init(version: head.version, status: .continue))),
                                promise: nil)
                        }
                        handler.pump(context)
                    case .failure(let error): handler.fail(context, error)
                    }
                })
        case .body(let body):
            bodyIdle?.cancel()
            guard head != nil, !responding, body.readableBytes <= 262_144,
                pendingBytes <= 262_144 - body.readableBytes
            else {
                fail(context, PublicJMAPHTTPError(413, "limit", "HTTP ingress window exceeded."))
                return
            }
            pending.append(Data(body.readableBytesView))
            pendingBytes += body.readableBytes
            pause(context)
            pump(context)
        case .end(let trailers):
            bodyIdle?.cancel()
            guard head != nil, !ended, trailers == nil || trailers!.isEmpty else {
                fail(context, PublicJMAPHTTPError(400, "invalidHeaders", "Unexpected request end/trailers."))
                return
            }
            ended = true
            pause(context)
            pump(context)
        }
    }
    private func pause(_ context: ChannelHandlerContext) {
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in
            bound.value.close(promise: nil)
        }
    }
    private func resume(_ context: ChannelHandlerContext) {
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in
            bound.value.close(promise: nil)
        }
    }
    private func pump(_ context: ChannelHandlerContext) {
        guard !inactive, !busy, !responding, let sink else { return }
        if !pending.isEmpty {
            let bytes = pending.removeFirst()
            pendingBytes -= bytes.count
            busy = true
            run(
                context, operation: { try await sink.append(bytes) },
                complete: { handler, context, result in
                    handler.busy = false
                    switch result {
                    case .success: handler.pump(context)
                    case .failure(let error): handler.fail(context, error)
                    }
                })
        } else if ended {
            busy = true
            run(
                context, operation: { try await sink.finish() },
                complete: { handler, context, result in
                    handler.busy = false
                    switch result {
                    case .success(let response):
                        handler.respond(context, response: response, forceClose: false)
                    case .failure(let error): handler.fail(context, error)
                    }
                })
        } else {
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            bodyIdle?.cancel()
            bodyIdle = context.eventLoop.scheduleTask(
                in: .nanoseconds(Int64(bodyIdleSeconds * 1_000_000_000))
            ) {
                handler.value.fail(
                    bound.value, PublicJMAPHTTPError(408, "requestIdleTimeout", "No request body progress."))
            }
            resume(context)
        }
    }
    private func fail(_ context: ChannelHandlerContext, _ error: any Error) {
        if responding || inactive {
            context.close(promise: nil)
            return
        }
        operation?.cancel()
        bodyIdle?.cancel()
        authorizationMonitor?.cancel()
        if let sink { cancel(sink, context: context) }
        sink = nil
        pending.removeAll()
        pendingBytes = 0
        respond(context, response: PublicJMAPApplication.problem(error), forceClose: true)
    }
    private func respond(_ context: ChannelHandlerContext, response: PublicJMAPResponse, forceClose: Bool) {
        guard !responding, !inactive, let writer else {
            context.close(promise: nil)
            return
        }
        responding = true
        pause(context)
        let version = head?.version ?? .http1_1
        let keepAlive = !forceClose && (head?.isKeepAlive ?? false) && version == .http1_1
        var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
        switch response.body {
        case .bytes(let bytes): headers.replaceOrAdd(name: "content-length", value: String(bytes.count))
        case .download(let source): headers.replaceOrAdd(name: "content-length", value: String(source.size))
        case .events:
            headers.replaceOrAdd(name: "transfer-encoding", value: "chunked")
            headers.replaceOrAdd(name: "x-accel-buffering", value: "no")
        }
        headers.replaceOrAdd(name: "connection", value: keepAlive ? "keep-alive" : "close")
        context.writeAndFlush(
            NIOAny(
                HTTPServerResponsePart.head(
                    .init(
                        version: version,
                        status: .init(statusCode: response.status), headers: headers))), promise: nil)
        run(
            context,
            operation: {
                switch response.body {
                case .bytes(let bytes):
                    for offset in stride(from: 0, to: bytes.count, by: 262_144) {
                        try Task.checkCancellation()
                        try await writer.write(Data(bytes[offset..<min(bytes.count, offset + 262_144)]))
                    }
                case .download(let source):
                    do {
                        var offset: Int64 = 0
                        while offset < source.size {
                            try Task.checkCancellation()
                            let chunk = try await source.read(offset: offset, limit: 262_144)
                            guard !chunk.isEmpty, chunk.count <= 262_144,
                                Int64(chunk.count) <= source.size - offset
                            else { throw CancellationError() }
                            try await writer.write(chunk)
                            offset += Int64(chunk.count)
                        }
                        await source.close()
                    } catch {
                        await source.close()
                        throw error
                    }
                case .events(let subscription):
                    do {
                        while let event = try await subscription.next() {
                            try Task.checkCancellation()
                            guard ["state", "ping"].contains(event.name), event.id?.utf8.count ?? 0 <= 4096,
                                event.id?.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) ?? true
                            else { throw CancellationError() }
                            var frame = "event: " + event.name + "\n"
                            if let id = event.id { frame += "id: " + id + "\n" }
                            frame +=
                                "data: " + String(decoding: try event.data.encoded(), as: UTF8.self) + "\n\n"
                            guard frame.utf8.count <= 16 * 1024 else { throw CancellationError() }
                            try await writer.write(Data(frame.utf8))
                        }
                        await subscription.cancel()
                    } catch {
                        await subscription.cancel()
                        throw error
                    }
                }
            },
            complete: { handler, context, result in
                switch result {
                case .failure: context.close(promise: nil)
                case .success:
                    let boundHandler = NIOLoopBound(handler, eventLoop: context.eventLoop)
                    let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
                    if keepAlive {
                        // Pipeline assistance can release the next already-buffered request during end.write.
                        // Retire this request first; do not overwrite a newly admitted head in the completion.
                        handler.authorizationMonitor?.cancel()
                        handler.authorizationMonitor = nil
                        handler.head = nil
                        handler.sink = nil
                        handler.ended = false
                        handler.responding = false
                        handler.pending.removeAll()
                        handler.pendingBytes = 0
                    }
                    context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete {
                        completion in
                        let handler = boundHandler.value
                        let context = boundContext.value
                        guard case .success = completion, keepAlive, !handler.inactive else {
                            context.close(promise: nil)
                            return
                        }
                        if handler.head == nil {
                            handler.armHeaderDeadline(context)
                            handler.resume(context)
                        }
                    }
                }
            })
    }
    private func monitorAuthorization(_ sink: any PublicJMAPRequestSink, context: ChannelHandlerContext) {
        authorizationMonitor?.cancel()
        work?.begin()
        let obligation = work.map { NIOLoopBound($0, eventLoop: context.eventLoop) }
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        let loop = context.eventLoop
        authorizationMonitor = Task {
            var rejected = false
            do {
                while true {
                    try await Task.sleep(for: .seconds(30))
                    try await sink.checkAuthorization()
                }
            } catch { rejected = !Task.isCancelled }
            let close = rejected
            loop.execute {
                if close { bound.value.close(promise: nil) }
                obligation?.value.finish()
            }
        }
    }
    private func cancel(_ sink: any PublicJMAPRequestSink, context: ChannelHandlerContext) {
        work?.begin()
        let bound = work.map { NIOLoopBound($0, eventLoop: context.eventLoop) }
        context.eventLoop.makeFutureWithTask { await sink.cancel() }.whenComplete { _ in bound?.value.finish()
        }
    }
    private func run<T: Sendable>(
        _ context: ChannelHandlerContext,
        operation: @escaping @Sendable () async throws -> T,
        complete:
            @escaping @Sendable (JMAPHTTPStreamHandler, ChannelHandlerContext, Result<T, any Error>) -> Void
    ) {
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        let loop = context.eventLoop
        work?.begin()
        let obligation = work.map { NIOLoopBound($0, eventLoop: loop) }
        self.operation = Task {
            let result: Result<T, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            loop.execute {
                defer { obligation?.value.finish() }
                complete(handler.value, bound.value, result)
            }
        }
    }
}

/// The channel owns this writer; all mutable fields below are confined to its event loop.
private final class JMAPHTTPWriter: @unchecked Sendable {
    let channel: any Channel
    private var writable: EventLoopPromise<Void>?
    init(channel: any Channel) { self.channel = channel }
    private func ready() -> EventLoopFuture<Void> {
        channel.eventLoop.preconditionInEventLoop()
        guard channel.isActive else { return channel.eventLoop.makeFailedFuture(CancellationError()) }
        if channel.isWritable { return channel.eventLoop.makeSucceededVoidFuture() }
        if let writable { return writable.futureResult }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        writable = promise
        return promise.futureResult
    }
    func write(_ data: Data) async throws {
        try await channel.eventLoop.flatSubmit { [self] in
            ready().flatMap { [self] in
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                return channel.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))))
            }
        }.get()
    }
    func writabilityChanged() {
        channel.eventLoop.preconditionInEventLoop()
        if channel.isWritable {
            let promise = writable
            writable = nil
            promise?.succeed(())
        }
    }
    func closed() {
        channel.eventLoop.preconditionInEventLoop()
        let promise = writable
        writable = nil
        promise?.fail(CancellationError())
    }
}
