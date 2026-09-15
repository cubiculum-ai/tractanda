import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

private let maximumRequestBodyBytes = 2 * 1024 * 1024
private let maximumInputs = 16

private struct EmbeddingRequest: Decodable {
    private struct RequestKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case model
        case input
    }

    enum Input: Decodable {
        case text(String)
        case texts([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .texts(try container.decode([String].self))
            }
        }

        var texts: [String] {
            switch self {
            case .text(let value): [value]
            case .texts(let values): values
            }
        }
    }

    let model: String
    let input: Input

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: RequestKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(["model", "input"]) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath, debugDescription: "Unexpected embedding request fields."))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        input = try container.decode(Input.self, forKey: .input)
    }
}

private struct ErrorEnvelope: Encodable, Sendable {
    struct Detail: Encodable, Sendable {
        let message: String
    }

    let error: Detail

    init(_ message: String) {
        error = Detail(message: message)
    }
}

private struct HealthResponse: Encodable, Sendable {
    let ready = true
    let model = ModelProfile.alias
}

private actor AdmissionGate {
    private var active = 0

    func acquire() -> Bool {
        guard active < 2 else { return false }
        active += 1
        return true
    }

    func release() {
        precondition(active > 0)
        active -= 1
    }
}

private struct LoopReply: Sendable {
    let context: NIOLoopBound<ChannelHandlerContext>

    func send(status: HTTPResponseStatus, payload: Data) {
        let loopContext = context
        loopContext.eventLoop.execute {
            let context = loopContext.value
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/json")
            headers.add(name: "content-length", value: String(payload.count))
            headers.add(name: "connection", value: "close")
            context.write(
                NIOAny(
                    HTTPServerResponsePart.head(
                        HTTPResponseHead(
                            version: .http1_1, status: status, headers: headers))),
                promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                loopContext.eventLoop.execute {
                    loopContext.value.close(promise: nil)
                }
            }
        }
    }
}

private final class IdleCloseHandler: ChannelInboundHandler {
    typealias InboundIn = Never

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }
}

private final class EmbeddingHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let engine: any EmbeddingServing
    private let gate: AdmissionGate
    private var requestHead: HTTPRequestHead?
    private var body = ByteBuffer()
    private var responseStarted = false
    private var requestTask: Task<Void, Never>?

    init(engine: any EmbeddingServing, gate: AdmissionGate) {
        self.engine = engine
        self.gate = gate
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responseStarted else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard requestHead == nil else {
                fail(
                    context: context, status: .badRequest,
                    message: "Only one request is permitted per connection.")
                return
            }
            requestHead = head
            body.clear()
        case .body(var chunk):
            guard requestHead != nil else {
                fail(context: context, status: .badRequest, message: "Request body arrived before headers.")
                return
            }
            guard body.readableBytes <= maximumRequestBodyBytes - chunk.readableBytes else {
                fail(context: context, status: .payloadTooLarge, message: "Request exceeds 2 MiB.")
                return
            }
            body.writeBuffer(&chunk)
        case .end:
            handleCompletedRequest(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        requestTask?.cancel()
        requestTask = nil
        context.fireChannelInactive()
    }

    private func handleCompletedRequest(context: ChannelHandlerContext) {
        guard let head = requestHead else {
            fail(context: context, status: .badRequest, message: "Request headers are required.")
            return
        }
        if head.method == .GET, head.uri == "/health" {
            respond(context: context, status: .ok, value: HealthResponse())
            return
        }
        guard head.method == .POST, head.uri == "/v1/embeddings" else {
            fail(context: context, status: .notFound, message: "Use GET /health or POST /v1/embeddings.")
            return
        }
        guard let requestBytes = body.getBytes(at: body.readerIndex, length: body.readableBytes),
            let request = try? JSONDecoder().decode(EmbeddingRequest.self, from: Data(requestBytes))
        else {
            fail(context: context, status: .badRequest, message: "Invalid embedding JSON.")
            return
        }
        let texts = request.input.texts
        guard request.model == ModelProfile.alias else {
            fail(context: context, status: .badRequest, message: "Unknown model alias.")
            return
        }
        guard (1...maximumInputs).contains(texts.count), texts.allSatisfy({ !$0.isEmpty }) else {
            fail(
                context: context, status: .badRequest,
                message: "input must contain 1 through 16 nonempty texts.")
            return
        }
        responseStarted = true
        let reply = LoopReply(context: context.loopBound)
        let engine = engine
        let gate = gate
        requestTask = Task {
            guard await gate.acquire() else {
                reply.send(
                    status: .serviceUnavailable,
                    payload: Self.encode(ErrorEnvelope("Embedding host is busy.")))
                return
            }
            do {
                let response = try await engine.embed(texts)
                reply.send(status: .ok, payload: Self.encode(response))
            } catch let failure as EmbeddingFailure {
                reply.send(
                    status: HTTPResponseStatus(statusCode: failure.status),
                    payload: Self.encode(ErrorEnvelope(failure.message)))
            } catch is CancellationError {
                // The peer is gone. Release the bounded admission permit.
            } catch {
                reply.send(
                    status: .internalServerError,
                    payload: Self.encode(ErrorEnvelope("Local embedding failed.")))
            }
            await gate.release()
        }
    }

    private func fail(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        guard !responseStarted else { return }
        responseStarted = true
        LoopReply(context: context.loopBound).send(
            status: status, payload: Self.encode(ErrorEnvelope(message)))
    }

    private func respond<T: Encodable>(context: ChannelHandlerContext, status: HTTPResponseStatus, value: T) {
        guard !responseStarted else { return }
        responseStarted = true
        LoopReply(context: context.loopBound).send(status: status, payload: Self.encode(value))
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("{\"error\":{\"message\":\"Encoding failed.\"}}".utf8)
    }
}

/// Serve only the pinned embedding model on IPv4 loopback. Each connection is
/// deliberately closed after its first response to make pipelined bytes inert.
func serveEmbeddings(engine: any EmbeddingServing, port: Int) async throws {
    guard (0...65_535).contains(port) else {
        throw EmbeddingFailure(status: 400, message: "Port must be from 0 through 65535.")
    }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let gate = AdmissionGate()
    do {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        IdleStateHandler(readTimeout: .seconds(20)))
                    try channel.pipeline.syncOperations.addHandler(IdleCloseHandler())
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(
                            HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)))
                    try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())
                    try channel.pipeline.syncOperations.addHandler(
                        EmbeddingHTTPHandler(engine: engine, gate: gate))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: port)
            .get()
        try await channel.closeFuture.get()
        try await group.shutdownGracefully()
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}
