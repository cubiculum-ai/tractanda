import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import TractandaCore
import TractandaHTTPSIdentity
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One-shot HTTPS posts over NIO. DNS is screened before connection; a vetted numeric address is
/// passed to connect(to:), while original DNS identity is retained for certificate checks and Host.
public final class NIOJMAPCallbackTransport: JMAPCallbackTransport, @unchecked Sendable {
    public typealias Resolver = @Sendable (String, Int) async throws -> [SocketAddress]
    private let group: any EventLoopGroup
    private let policy: JMAPCallbackPolicy
    private let installTLS: @Sendable (any Channel, String) throws -> EventLoopFuture<Void>
    private let resolve: Resolver
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: any Channel] = [:]
    private var closed = false
    public init(
        group: any EventLoopGroup, policy: JMAPCallbackPolicy = .init(),
        resolver: @escaping Resolver = NIOJMAPCallbackTransport.systemResolve
    ) throws {
        self.group = group; self.policy = policy; self.resolve = resolver
        guard policy.privateOrigins.count <= 128,
            policy.privateOrigins.allSatisfy({ origin in
                guard let endpoint = try? JMAPCallbackEndpoint(
                    "https://\(origin.host.contains(":" ) ? "[\(origin.host)]" : origin.host):\(origin.port)/")
                else { return false }
                return endpoint.origin == origin
            }) else { throw Self.failure() }
        let trust = try HTTPSClientTrustContext()
        installTLS = { channel, hostname in
            try channel.pipeline.addHandler(trust.makeClientHandler(serverHostname: hostname))
        }
    }
    /// Private fixture seam: production construction above always uses operating-system trust.
    init(
        group: any EventLoopGroup, policy: JMAPCallbackPolicy,
        resolver: @escaping Resolver,
        installTLS: @escaping @Sendable (any Channel, String) throws -> EventLoopFuture<Void>
    ) {
        self.group = group; self.policy = policy; self.resolve = resolver; self.installTLS = installTLS
    }
    public func validate(url: String) async throws { _ = try await vetted(url) }
    private func vetted(_ url: String) async throws -> (JMAPCallbackEndpoint, [SocketAddress]) {
        guard !lock.withLock({ closed }) else { throw Self.failure() }
        let endpoint = try JMAPCallbackEndpoint(url)
        let addresses = try await resolve(endpoint.host, endpoint.port)
        let privateAllowed = policy.privateOrigins.contains(endpoint.origin)
        let literal = try? SocketAddress(ipAddress: endpoint.host, port: endpoint.port)
        guard !addresses.isEmpty, addresses.count <= 64,
            addresses.allSatisfy({ address in
                guard address.port == endpoint.port, literal == nil || literal == address,
                    let ip = address.ipAddress else { return false }
                let kind = Self.addressKind(ip)
                return kind == .publicInternet || (kind == .privateNetwork && privateAllowed)
            }) else { throw Self.failure() }
        return (endpoint, addresses)
    }
    public func post(
        url: String, body: Data, encrypted: Bool, ttlSeconds: Int, expiresAt: Date
    ) async throws -> JMAPCallbackResponse {
        guard body.count <= 4096, (0...60).contains(ttlSeconds), expiresAt > Date() else {
            throw Self.failure()
        }
        let (endpoint, addresses) = try await vetted(url)
        try Task.checkCancellation()
        guard expiresAt > Date() else { throw Self.failure() }
        let eventLoop = group.next()
        let promise = eventLoop.makePromise(of: JMAPCallbackResponse.self)
        let cancellation = CallbackCancellation()
        let handler = CallbackResponseHandler(promise: promise)
        let bootstrap = ClientBootstrap(group: eventLoop)
            // Connection setup is bounded by credential/subscription expiry, not a healthy body timer.
            .connectTimeout(.nanoseconds(Int64(min(43_200, max(0.001, expiresAt.timeIntervalSinceNow)) * 1_000_000_000)))
            .channelInitializer { [installTLS] channel in
                do {
                    cancellation.install(channel)
                    return try installTLS(channel, endpoint.host).flatMap {
                        channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .dropBytes)
                    }.flatMap { channel.pipeline.addHandler(handler) }
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }
        return try await withTaskCancellationHandler {
            // Do not fall back/re-resolve on failure: an initial verification gets one attempt.
            let channel = try await bootstrap.connect(to: addresses[0]).get()
            cancellation.install(channel)
            let identity = ObjectIdentifier(channel)
            let admitted = lock.withLock { () -> Bool in
                guard !closed, channels.count < 4 else { return false }
                channels[identity] = channel; return true
            }
            guard admitted else { try? await channel.close().get(); throw Self.failure() }
            defer {
                lock.withLock { _ = channels.removeValue(forKey: identity) }
                channel.close(promise: nil)
            }
            let expiry = channel.eventLoop.scheduleTask(in: .nanoseconds(
                Int64(max(0, min(43_200, expiresAt.timeIntervalSinceNow)) * 1_000_000_000)
            )) { channel.close(promise: nil) }
            defer { expiry.cancel() }
            try Task.checkCancellation()
            guard expiresAt > Date() else { throw Self.failure() }
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: endpoint.hostHeader)
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: String(body.count))
            headers.add(name: "TTL", value: String(ttlSeconds))
            headers.add(name: "Connection", value: "close")
            if encrypted { headers.add(name: "Content-Encoding", value: "aes128gcm") }
            let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: endpoint.requestTarget, headers: headers)
            channel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
            channel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(channel.allocator.buffer(bytes: body)))), promise: nil)
            try await channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).get()
            return try await promise.futureResult.get()
        } onCancel: { cancellation.cancel() }
    }
    public func close() async {
        let active = lock.withLock { () -> [any Channel] in
            closed = true; let result = Array(channels.values); channels.removeAll(); return result
        }
        for channel in active { try? await channel.close().get() }
    }
    public static func systemResolve(_ host: String, _ port: Int) async throws -> [SocketAddress] {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_flags = 0
            var first: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &first) == 0, let first else { throw failure() }
            defer { freeaddrinfo(first) }
            var result: [SocketAddress] = [], cursor: UnsafeMutablePointer<addrinfo>? = first
            while let entry = cursor {
                defer { cursor = entry.pointee.ai_next }
                guard entry.pointee.ai_family == AF_INET || entry.pointee.ai_family == AF_INET6,
                    let address = entry.pointee.ai_addr else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0,
                    NI_NUMERICHOST) == 0 else { throw failure() }
                let ip = String(cString: buffer)
                let socket = try SocketAddress(ipAddress: ip, port: port)
                if !result.contains(socket) { result.append(socket) }
                guard result.count <= 64 else { throw failure() }
            }
            return result
        }.value
    }
    package enum AddressKind { case publicInternet, privateNetwork, forbidden }
    package static func addressKind(_ ip: String) -> AddressKind {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            let a = Int(bytes[0]), b = Int(bytes[1]), c = Int(bytes[2])
            if a == 0 || a >= 224 || bytes == [255,255,255,255] { return .forbidden }
            if a == 10 || a == 127 || (a == 100 && (64...127).contains(b))
                || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
                || (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99)))
                || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
                || (a == 203 && b == 0 && c == 113) { return .privateNetwork }
            return .publicInternet
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, ip, &v6) == 1 else { return .forbidden }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            return addressKind(bytes.suffix(4).map(String.init).joined(separator: "."))
        }
        if bytes.allSatisfy({ $0 == 0 }) || bytes[0] == 255 { return .forbidden }
        // Conservative global-unicast floor; all transition, local, documentation and special-use
        // ranges require explicit origin approval. No IPv6-to-IPv4 bypass for mapped private IPs.
        guard bytes[0] & 0xe0 == 0x20 else { return .privateNetwork }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 2 { return .privateNetwork }
        if bytes[0...3].elementsEqual([0x20,0x01,0x0d,0xb8]) || bytes[0...1].elementsEqual([0x20,0x02])
            || (bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0) { return .privateNetwork }
        return .publicInternet
    }
    private static func failure() -> TractandaError {
        TractandaError("callbackUnavailable", "Callback destination is unavailable or disallowed.")
    }
}

private final class CallbackCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var channel: (any Channel)?; private var cancelled = false
    func install(_ value: any Channel) {
        let stop = lock.withLock { () -> Bool in channel = value; return cancelled }
        if stop { value.close(promise: nil) }
    }
    func cancel() {
        let active = lock.withLock { () -> (any Channel)? in cancelled = true; return channel }
        active?.close(promise: nil)
    }
}
private final class CallbackResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    private let promise: EventLoopPromise<JMAPCallbackResponse>
    private var completed = false
    init(promise: EventLoopPromise<JMAPCallbackResponse>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else { return }
        if case .head(let head) = unwrapInboundIn(data) {
            // Interim responses do not complete the callback. Never follow Location/redirects.
            if (100...199).contains(Int(head.status.code)) { return }
            let total = head.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
            guard total <= 16_384 else { fail(context); return }
            let values = head.headers["retry-after"]
            let retry = values.count == 1 ? Int(values[0]).map { min(86_400, max(0, $0)) } : nil
            completed = true
            promise.succeed(.init(status: Int(head.status.code), retryAfterSeconds: retry))
            context.close(promise: nil)
        }
    }
    func channelInactive(context: ChannelHandlerContext) { fail(context); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { fail(context) }
    private func fail(_ context: ChannelHandlerContext) {
        if !completed { completed = true; promise.fail(TractandaError("callbackUnavailable", "Callback failed.")) }
        context.close(promise: nil)
    }
}
