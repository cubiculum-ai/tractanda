import Foundation
import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import TractandaCore
@testable import TractandaServer

private final class CallbackTLSCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(host: String?, authorization: String?, ttl: String?, type: String?, body: Data)] = []
    func record(_ head: HTTPRequestHead, _ body: Data) {
        lock.withLock { requests.append((head.headers.first(name: "host"), head.headers.first(name: "authorization"),
            head.headers.first(name: "ttl"), head.headers.first(name: "content-type"), body)) }
    }
    func snapshot() -> [(host: String?, authorization: String?, ttl: String?, type: String?, body: Data)] { lock.withLock { requests } }
}
private final class CallbackTLSFixtureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let capture: CallbackTLSCapture
    let status: HTTPResponseStatus
    let respond: Bool
    var head: HTTPRequestHead?
    var body = Data()
    init(capture: CallbackTLSCapture, status: HTTPResponseStatus = .created, respond: Bool = true) {
        self.capture = capture; self.status = status; self.respond = respond
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let value): head = value
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head else { return }
            capture.record(head, body)
            guard respond else { return }
            let headers: HTTPHeaders = status == .found ? ["Location": "https://must-not-follow.fixture/", "Content-Length": "0"]
                : ["Retry-After": "120", "Content-Length": "0"]
            context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: headers))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}

final class JMAPCallbackTLSTests: XCTestCase {
    private struct Contexts: @unchecked Sendable {
        let server: NIOSSLContext
        let client: NIOSSLContext
        let root: URL
    }
    private func contexts() throws -> Contexts {
        let temporary = FileManager.default.temporaryDirectory
        let free = try FileManager.default.attributesOfFileSystem(forPath: temporary.path)[.systemFreeSize] as? NSNumber
        guard free?.uint64Value ?? 0 >= 10 * 1024 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Notification fixtures require10GiB free.")
        }
        let root = temporary.appendingPathComponent("jmap-callback-tls-" + Identifier.make())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            func openssl(_ args: [String]) throws {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
                process.currentDirectoryURL = root; process.arguments = args
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw TractandaError("fixtureFailure", "Ephemeral fixture PKI failed.") }
            }
            try openssl(["req", "-sha256", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve", "-nodes",
                "-keyout", "root.key", "-out", "root.pem", "-subj", "/CN=Private Fixture CA", "-days", "1",
                "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
            try openssl(["req", "-sha256", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve", "-nodes",
                "-keyout", "server.key", "-out", "server.csr", "-subj", "/CN=receiver.fixture"])
            try Data("subjectAltName=DNS:receiver.fixture\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n".utf8)
                .write(to: root.appendingPathComponent("extensions.txt"))
            try openssl(["x509", "-sha256", "-req", "-in", "server.csr", "-CA", "root.pem", "-CAkey", "root.key", "-CAcreateserial",
                "-out", "server.pem", "-days", "1", "-extfile", "extensions.txt"])
            try openssl(["x509", "-in", "server.pem", "-outform", "DER", "-out", "server.der"])
            try openssl(["x509", "-in", "root.pem", "-outform", "DER", "-out", "root.der"])
            func stage<T>(_ name: String, _ body: () throws -> T) throws -> T {
                do { return try body() } catch { throw TractandaError("fixtureFailure", "Ephemeral TLS fixture stage: " + name + ": " + String(describing: error)) }
            }
            let certs = try stage("readServerDER") { [try NIOSSLCertificate(file: root.appendingPathComponent("server.der").path, format: .der)] }
            let key = try stage("readServerKey") { try NIOSSLPrivateKey(file: root.appendingPathComponent("server.key").path, format: .pem) }
            var server = TLSConfiguration.makeServerConfiguration(certificateChain: certs.map { .certificate($0) }, privateKey: .privateKey(key))
            server.minimumTLSVersion = .tlsv12
            var client = TLSConfiguration.makeClientConfiguration()
            client.minimumTLSVersion = .tlsv12; client.certificateVerification = .fullVerification
            client.trustRoots = .certificates(try stage("readRootDER") { [try NIOSSLCertificate(file: root.appendingPathComponent("root.der").path, format: .der)] })
            let serving = try stage("serverContext") { try NIOSSLContext(configuration: server) }
            let receiving = try stage("clientContext") { try NIOSSLContext(configuration: client) }
            return .init(server: serving, client: receiving, root: root)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    private func fixture(_ group: MultiThreadedEventLoopGroup, _ contexts: Contexts, _ capture: CallbackTLSCapture,
                         status: HTTPResponseStatus = .created, respond: Bool = true) async throws -> any Channel {
        try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.addHandler(NIOSSLServerHandler(context: contexts.server)).flatMap {
                channel.pipeline.configureHTTPServerPipeline()
            }.flatMap {
                channel.pipeline.addHandler(CallbackTLSFixtureHandler(capture: capture, status: status, respond: respond))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
    }
    private func transport(_ group: MultiThreadedEventLoopGroup, _ contexts: Contexts, _ port: Int,
                           hostname: String = "receiver.fixture") -> NIOJMAPCallbackTransport {
        NIOJMAPCallbackTransport(group: group, policy: .init(privateOrigins: [.init(host: hostname, port: port)]),
            resolver: { _, selected in [try SocketAddress(ipAddress: "127.0.0.1", port: selected)] },
            installTLS: { channel, name in
                try channel.pipeline.addHandler(NIOSSLClientHandler(context: contexts.client, serverHostname: name))
            })
    }
    func testActualPrivateTLSPostOriginalHostFixedHeadersAndRedirectNotFollowed() async throws {
        let contexts = try contexts(); defer { try? FileManager.default.removeItem(at: contexts.root) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1); defer { try? await group.shutdownGracefully() }
        let capture = CallbackTLSCapture(), listener = try await fixture(group, contexts, capture, status: .found)
        defer { try? await listener.close().get() }
        let port = try XCTUnwrap(listener.localAddress?.port), transport = transport(group, contexts, port)
        let response = try await transport.post(url: "https://receiver.fixture:\(port)/push?token=private",
            body: Data("{\"@type\":\"PushVerification\"}".utf8), encrypted: false, ttlSeconds: 60, expiresAt: Date() + 60)
        XCTAssertEqual(response.status, 302)
        let requests = capture.snapshot(); XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.host, "receiver.fixture:\(port)")
        XCTAssertNil(requests.first?.authorization); XCTAssertEqual(requests.first?.ttl, "60")
        XCTAssertEqual(requests.first?.type, "application/json")
        await transport.close()
    }
    func testActualTLSHostnameMismatchRejectsBeforeHTTPBodyAndProductionSystemTrustRejectsFixtureCA() async throws {
        let contexts = try contexts(); defer { try? FileManager.default.removeItem(at: contexts.root) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1); defer { try? await group.shutdownGracefully() }
        let capture = CallbackTLSCapture(), listener = try await fixture(group, contexts, capture)
        defer { try? await listener.close().get() }
        let port = try XCTUnwrap(listener.localAddress?.port)
        let mismatch = transport(group, contexts, port, hostname: "wrong.fixture")
        do {
            _ = try await mismatch.post(url: "https://wrong.fixture:\(port)/push", body: Data("{}".utf8),
                encrypted: false, ttlSeconds: 1, expiresAt: Date() + 10)
            XCTFail("Wrong TLS name")
        } catch {}
        let system = try NIOJMAPCallbackTransport(group: group,
            policy: .init(privateOrigins: [.init(host: "receiver.fixture", port: port)]),
            resolver: { _, selected in [try SocketAddress(ipAddress: "127.0.0.1", port: selected)] })
        do {
            _ = try await system.post(url: "https://receiver.fixture:\(port)/push", body: Data("{}".utf8),
                encrypted: false, ttlSeconds: 1, expiresAt: Date() + 10)
            XCTFail("Untrusted fixture CA")
        } catch {}
        XCTAssertEqual(capture.snapshot().count, 0)
        await mismatch.close(); await system.close()
    }
    func testCancellationClosesHealthyPendingResponseWithoutBodyOperationDeadline() async throws {
        let contexts = try contexts(); defer { try? FileManager.default.removeItem(at: contexts.root) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1); defer { try? await group.shutdownGracefully() }
        let capture = CallbackTLSCapture(), listener = try await fixture(group, contexts, capture, respond: false)
        defer { try? await listener.close().get() }
        let port = try XCTUnwrap(listener.localAddress?.port), transport = transport(group, contexts, port)
        let request = Task {
            try await transport.post(url: "https://receiver.fixture:\(port)/push", body: Data("{}".utf8),
                encrypted: false, ttlSeconds: 60, expiresAt: Date() + 60)
        }
        for _ in 0..<100 where capture.snapshot().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(capture.snapshot().count, 1)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled callback") } catch {}
        await transport.close()
    }
}
