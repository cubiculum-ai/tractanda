import Dispatch
import Foundation
import NIOCore
import NIOPosix
import TractandaCore

/// One bounded unauthenticated NTP exchange. The caller owns and drains the NIO group.
final class NISTTimeSampler: Sendable {
    struct Clock: Sendable {
        var wall: @Sendable () -> Double = { Date().timeIntervalSince1970 }
        var monotonic: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    }
    enum Failure: Error { case unavailable, timeout, cancelled, invalidSource }
    typealias Resolution = @Sendable (String, Int) throws -> SocketAddress
    private let group: MultiThreadedEventLoopGroup
    private let resolver: NTPResolverGate
    private let clock: Clock

    init(
        group: MultiThreadedEventLoopGroup, clock: Clock = .init(),
        resolve: @escaping Resolution = { try SocketAddress.makeAddressResolvingHost($0, port: $1) }
    ) {
        self.group = group
        self.clock = clock
        resolver = NTPResolverGate(resolve: resolve)
    }

    func sample(configuration: PeerClockHealth.Configuration, port: Int = 123) async throws
        -> PeerClockHealth.Sample
    {
        let configuration = try PeerClockHealth(configuration: configuration).configuration
        let attempt = NTPAttempt(
            loop: group.next(), resolver: resolver, clock: clock, configuration: configuration)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                attempt.start(port: port, continuation: continuation)
            }
        } onCancel: {
            attempt.cancel()
        }
    }
}

/// libc getaddrinfo cannot be cancelled portably. Never create a lookup per timed-out caller:
/// retain at most one lookup and reject subsequent attempts until the OS returns. The completion
/// has no dependency on an event loop and is safe after the daemon's group is shut down.
private final class NTPResolverGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resolving = false
    private let queue = DispatchQueue(label: "ai.tractanda.ntp-dns", qos: .utility)
    private let resolve: NISTTimeSampler.Resolution
    init(resolve: @escaping NISTTimeSampler.Resolution) { self.resolve = resolve }
    func lookup(
        host: String, port: Int,
        completion: @escaping @Sendable (Result<SocketAddress, any Error>) -> Void
    ) {
        lock.lock()
        guard !resolving else {
            lock.unlock()
            completion(.failure(NISTTimeSampler.Failure.unavailable))
            return
        }
        resolving = true
        lock.unlock()
        queue.async { [self] in
            let result = Result { try resolve(host, port) }
            lock.lock()
            resolving = false
            lock.unlock()
            completion(result)
        }
    }
}

/// Mutable transport state stays on one event loop. The small dispatch gate fences late DNS and
/// task-cancellation callbacks before completion, so they cannot touch a shut-down event loop.
private final class NTPAttempt: @unchecked Sendable {
    private let gate = NSLock()
    private var dispatchOpen = true
    private var cancellationRequested = false
    private let loop: any EventLoop
    private let resolver: NTPResolverGate
    private let clock: NISTTimeSampler.Clock
    private let configuration: PeerClockHealth.Configuration
    private var continuation: CheckedContinuation<PeerClockHealth.Sample, any Error>?
    private var timeoutTask: Scheduled<Void>?
    private var channel: (any Channel)?
    private var binding = false
    private var closing = false
    private var terminal: Result<PeerClockHealth.Sample, any Error>?
    private var endpoint: SocketAddress?
    private let nonce = UInt64.random(in: 1...UInt64.max)
    private var sentWall = 0.0
    private var sentMonotonic = 0.0

    init(
        loop: any EventLoop, resolver: NTPResolverGate, clock: NISTTimeSampler.Clock,
        configuration: PeerClockHealth.Configuration
    ) {
        self.loop = loop
        self.resolver = resolver
        self.clock = clock
        self.configuration = configuration
    }
    func start(port: Int, continuation: CheckedContinuation<PeerClockHealth.Sample, any Error>) {
        dispatch { [self] in
            self.continuation = continuation
            gate.lock()
            let cancelled = cancellationRequested
            gate.unlock()
            guard !cancelled else { return finish(.failure(NISTTimeSampler.Failure.cancelled)) }
            let timeoutNanoseconds = Int64(configuration.timeout * 1_000_000_000)
            timeoutTask = loop.scheduleTask(in: .nanoseconds(timeoutNanoseconds)) { [self] in
                finish(.failure(NISTTimeSampler.Failure.timeout))
            }
            resolver.lookup(host: configuration.referenceHost, port: port) { [self] result in
                dispatch { [self] in resolved(result) }
            }
        }
    }
    func cancel() {
        gate.lock()
        cancellationRequested = true
        if dispatchOpen {
            loop.execute { [self] in
                // start() installs the continuation before completing pre-start cancellation.
                if continuation != nil { finish(.failure(NISTTimeSampler.Failure.cancelled)) }
            }
        }
        gate.unlock()
    }
    private func dispatch(_ body: @escaping @Sendable () -> Void) {
        gate.lock()
        if dispatchOpen { loop.execute(body) }
        gate.unlock()
    }
    private func resolved(_ result: Result<SocketAddress, any Error>) {
        guard terminal == nil else { return }
        switch result {
        case .failure(let error): finish(.failure(error))
        case .success(let address):
            endpoint = address
            binding = true
            let bootstrap = DatagramBootstrap(group: loop)
                .channelOption(
                    ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 49)
                )
                .channelInitializer { channel in
                    channel.pipeline.addHandler(NTPResponseHandler(attempt: self))
                }
            let bindHost = address.protocol == .inet6 ? "::" : "0.0.0.0"
            let bindAddress: SocketAddress
            do { bindAddress = try SocketAddress(ipAddress: bindHost, port: 0) } catch {
                binding = false
                finish(.failure(error))
                return
            }
            bootstrap.bind(to: bindAddress).whenComplete { [self] result in
                binding = false
                switch result {
                case .failure(let error): finish(.failure(error))
                case .success(let opened):
                    channel = opened
                    if terminal != nil {
                        closeAndComplete()
                        return
                    }
                    sentWall = clock.wall()
                    sentMonotonic = clock.monotonic()
                    var packet = opened.allocator.buffer(capacity: 48)
                    packet.writeBytes(NTPPacket.request(nonce: nonce))
                    opened.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: packet)).whenFailure
                    {
                        [self] error in finish(.failure(error))
                    }
                }
            }
        }
    }
    func received(_ packet: AddressedEnvelope<ByteBuffer>) {
        guard terminal == nil, let endpoint, sentMonotonic > 0 else { return }
        guard packet.remoteAddress == endpoint else {
            return finish(.failure(NISTTimeSampler.Failure.invalidSource))
        }
        let elapsed = clock.monotonic() - sentMonotonic
        finish(
            Result {
                try NTPPacket.sample(
                    response: Array(packet.data.readableBytesView), nonce: nonce, sentWall: sentWall,
                    receivedWall: clock.wall(), elapsed: elapsed, timeout: configuration.timeout)
            })
    }
    func failed(_ error: any Error) { finish(.failure(error)) }
    private func finish(_ result: Result<PeerClockHealth.Sample, any Error>) {
        if terminal == nil { terminal = result }
        timeoutTask?.cancel()
        timeoutTask = nil
        guard !binding else { return }
        closeAndComplete()
    }
    private func closeAndComplete() {
        guard !closing else { return }
        if let channel {
            closing = true
            self.channel = nil
            channel.close().whenComplete { [self] _ in
                closing = false
                complete()
            }
        } else {
            complete()
        }
    }
    private func complete() {
        guard let continuation, let terminal else { return }
        self.continuation = nil
        gate.lock()
        dispatchOpen = false
        gate.unlock()
        continuation.resume(with: terminal)
    }
}

private final class NTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    private let attempt: NTPAttempt
    init(attempt: NTPAttempt) { self.attempt = attempt }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        attempt.received(unwrapInboundIn(data))
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { attempt.failed(error) }
}
