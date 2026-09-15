import Foundation
import Logging
import MCP
import NIOCore
import NIOPosix
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Bounded newline framing for the SDK, with serialized NIO writes under backpressure.
/// Duplicated descriptors are owned by the channel; application stdout is MCP messages only.
actor StandardIOTransport: Transport {
    static let maximumMessageSize = 4 * 1024 * 1024
    nonisolated let logger = Logger(label: "tractanda.mcp", factory: { _ in SwiftLogNoOpLogHandler() })
    private var group: MultiThreadedEventLoopGroup?
    private var channel: (any Channel)?
    private var pendingWrites = 0
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        stream = pair.stream
        continuation = pair.continuation
    }

    func connect() async throws {
        guard group == nil else { return }
        let input = dup(STDIN_FILENO)
        guard input >= 0 else { throw TractandaError("transportError", "Cannot duplicate standard input.") }
        let output = dup(STDOUT_FILENO)
        guard output >= 0 else {
            close(input)
            throw TractandaError("transportError", "Cannot duplicate standard output.")
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let continuation = continuation
        do {
            channel = try await NIOPipeBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(
                            ByteToMessageHandler(MessageDecoder()), MessageHandler(continuation: continuation)
                        )
                    }
                }
                .takingOwnershipOfDescriptors(input: input, output: output).get()
        } catch {
            await disconnect()
            throw error
        }
    }

    func disconnect() async {
        continuation.finish()
        if let channel {
            self.channel = nil
            try? await channel.close().get()
        }
        if let group {
            self.group = nil
            await withCheckedContinuation { continuation in
                group.shutdownGracefully { _ in continuation.resume() }
            }
        }
    }

    func send(_ data: Data) async throws {
        guard let channel, channel.isActive else {
            throw TractandaError("transportError", "MCP connection is closed.")
        }
        guard data.count <= Self.maximumMessageSize, pendingWrites < 32 else {
            await disconnect()
            throw TractandaError("limit", "MCP output limit exceeded.")
        }
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        var buffer = channel.allocator.buffer(capacity: data.count + 1)
        buffer.writeBytes(data)
        buffer.writeInteger(UInt8(ascii: "\n"))
        try await channel.writeAndFlush(buffer).get()
    }

    func receive() -> AsyncThrowingStream<Data, any Error> { stream }
}

private struct MessageDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let newline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            guard buffer.readableBytes <= StandardIOTransport.maximumMessageSize else {
                throw TractandaError("limit", "MCP input message exceeds 4 MiB.")
            }
            return .needMoreData
        }
        let size = newline - buffer.readerIndex
        guard size <= StandardIOTransport.maximumMessageSize else {
            throw TractandaError("limit", "MCP input message exceeds 4 MiB.")
        }
        let message = buffer.readSlice(length: size)!
        buffer.moveReaderIndex(forwardBy: 1)
        if size > 0 { context.fireChannelRead(wrapInboundOut(message)) }
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws
        -> DecodingState
    {
        let result = try decode(context: context, buffer: &buffer)
        if seenEOF, result == .needMoreData, buffer.readableBytes > 0 {
            throw TractandaError("protocolError", "MCP message ended before its newline.")
        }
        return result
    }
}

private final class MessageHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    init(continuation: AsyncThrowingStream<Data, any Error>.Continuation) { self.continuation = continuation }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch continuation.yield(Data(unwrapInboundIn(data).readableBytesView)) {
        case .enqueued: break
        case .dropped:
            continuation.finish(throwing: TractandaError("limit", "Too many pending MCP messages."))
            context.close(promise: nil)
        case .terminated: context.close(promise: nil)
        @unknown default: context.close(promise: nil)
        }
    }
    func channelInactive(context: ChannelHandlerContext) { continuation.finish() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}
