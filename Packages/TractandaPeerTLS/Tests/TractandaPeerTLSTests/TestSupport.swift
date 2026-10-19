import CNIOBoringSSL
import Foundation
import NIOCore
import NIOEmbedded
import NIOTLS
import Synchronization

@testable import NIOSSL
@testable import TractandaPeerTLS

enum FixtureError: Error { case failed(String) }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw FixtureError.failed(message) }
}
final class Sessions: Sendable {
    let values = Mutex<[PeerTLSSession]>([])
    func append(_ session: PeerTLSSession) { values.withLock { $0.append(session) } }
    var count: Int { values.withLock { $0.count } }
}
final class Capture: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var active = 0
    var handshakes = 0
    var errors: [Error] = []
    var received: [[UInt8]] = []
    func channelActive(context: ChannelHandlerContext) {
        active += 1
        context.fireChannelActive()
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { handshakes += 1 }
        context.fireUserInboundEventTriggered(event)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received.append(Array(unwrapInboundIn(data).readableBytesView))
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { errors.append(error) }
}
struct Cursor {
    let bytes: [UInt8]
    var offset = 0
    mutating func take(_ count: Int) throws -> [UInt8] {
        try check(count >= 0 && offset + count <= bytes.count, "truncated public TLS structure")
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
    mutating func number(_ count: Int) throws -> Int { try take(count).reduce(0) { ($0 << 8) | Int($1) } }
    mutating func vector(_ count: Int) throws -> [UInt8] { try take(number(count)) }
}
struct Wire {
    var clientShares: [[UInt8]] = []
    var serverShares: [[UInt8]] = []
    var selectedPSK = false
    var early = false
    var modes: [UInt8] = []
    var cipher: Int?
    var bytes: [UInt8] = []
    mutating func observe(_ buffer: ByteBuffer, client: Bool) throws {
        let output = Array(buffer.readableBytesView)
        try check(bytes.count + output.count <= 131072, "fixture wire budget exceeded")
        bytes += output
        var records = Cursor(bytes: output)
        while records.offset < records.bytes.count {
            let type = try records.number(1)
            _ = try records.number(2)
            let payload = try records.vector(2)
            guard type == 22 else { continue }
            var messages = Cursor(bytes: payload)
            while messages.offset < messages.bytes.count {
                let kind = try messages.number(1)
                let body = try messages.vector(3)
                guard kind == (client ? 1 : 2) else { continue }
                var hello = Cursor(bytes: body)
                _ = try hello.take(34)
                _ = try hello.vector(1)
                if client {
                    _ = try hello.vector(2)
                    _ = try hello.vector(1)
                } else {
                    cipher = try hello.number(2)
                    _ = try hello.take(1)
                }
                var extensions = Cursor(bytes: try hello.vector(2))
                while extensions.offset < extensions.bytes.count {
                    let id = try extensions.number(2)
                    let value = try extensions.vector(2)
                    if id == 51 {
                        var shares = Cursor(bytes: value)
                        if client { shares = Cursor(bytes: try shares.vector(2)) }
                        while shares.offset < shares.bytes.count {
                            let group = try shares.number(2)
                            let share = try shares.vector(2)
                            if group == 0x11ec {
                                if client { clientShares.append(share) } else { serverShares.append(share) }
                            }
                        }
                    } else if id == 41 && !client {
                        selectedPSK = true
                    } else if id == 42 && client {
                        early = true
                    } else if id == 45 && client {
                        modes = Array(value.dropFirst())
                    }
                }
            }
        }
    }
}

func fixtureProfile(
    store: String = "01010101-0101-1101-8101-010101010101",
    initiator: String = "02020202-0202-1202-8202-020202020202",
    responder: String = "03030303-0303-1303-8303-030303030303",
    pairing: String = "04040404-0404-1404-8404-040404040404"
) throws -> PeerTLSProfile {
    try .init(
        storeID: store, initiatorReplicaID: initiator, responderReplicaID: responder, pairingID: pairing)
}
func context(_ role: PeerTLSRole, _ secret: PeerTLSSecret, _ profile: PeerTLSProfile? = nil) throws
    -> PeerTLSContext
{
    try .init(profile: profile ?? fixtureProfile(), role: role, secret: secret)
}

// Certificate fixtures are generated in memory through BoringSSL, never stored private keys.
func certificateConfiguration() throws -> TLSConfiguration {
    guard let key = EVP_PKEY_new(), let ec = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1),
        let cert = X509_new()
    else {
        throw FixtureError.failed("certificate allocation")
    }
    defer {
        EVP_PKEY_free(key)
        EC_KEY_free(ec)
        X509_free(cert)
    }
    try check(
        EC_KEY_generate_key(ec) == 1 && EVP_PKEY_set1_EC_KEY(key, ec) == 1, "certificate key generation")
    try check(
        X509_set_version(cert, 2) == 1 && ASN1_INTEGER_set(X509_get_serialNumber(cert), 1) == 1,
        "certificate serial")
    try check(
        X509_gmtime_adj(X509_getm_notBefore(cert), -60) != nil
            && X509_gmtime_adj(X509_getm_notAfter(cert), 3600) != nil, "certificate dates")
    try check(X509_set_pubkey(cert, key) == 1, "certificate public key")
    let name = X509_get_subject_name(cert)
    let commonName = Array("localhost".utf8)
    let nameResult = commonName.withUnsafeBufferPointer {
        X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, $0.baseAddress, $0.count, -1, 0)
    }
    try check(
        nameResult == 1 && X509_set_issuer_name(cert, name) == 1 && X509_sign(cert, key, EVP_sha256()) > 0,
        "certificate signing")
    var certBytes = [UInt8](repeating: 0, count: Int(i2d_X509(cert, nil)))
    var keyBytes = [UInt8](repeating: 0, count: Int(i2d_PrivateKey(key, nil)))
    _ = certBytes.withUnsafeMutableBufferPointer { buffer in
        var pointer = buffer.baseAddress
        return i2d_X509(cert, &pointer)
    }
    _ = keyBytes.withUnsafeMutableBufferPointer { buffer in
        var pointer = buffer.baseAddress
        return i2d_PrivateKey(key, &pointer)
    }
    defer { keyBytes.withUnsafeMutableBytes { OPENSSL_cleanse($0.baseAddress, $0.count) } }
    return TLSConfiguration.makeServerConfiguration(
        certificateChain: [.certificate(try NIOSSLCertificate(bytes: certBytes, format: .der))],
        privateKey: .privateKey(try NIOSSLPrivateKey(bytes: keyBytes, format: .der)))
}
func rawServer(
    secret: PeerTLSSecret?, profile value: PeerTLSProfile? = nil,
    classical: Bool = false, oldTLS: Bool = false, noALPN: Bool = false,
    importerContext: [UInt8]? = nil, certificate: Bool = false
) throws -> NIOSSLContext {
    let selected = try value ?? fixtureProfile()
    var config = certificate ? try certificateConfiguration() : TLSConfiguration.makeClientConfiguration()
    config.minimumTLSVersion = oldTLS ? .tlsv12 : .tlsv13
    config.maximumTLSVersion = oldTLS ? .tlsv12 : .tlsv13
    config.certificateVerification = .none
    config.trustRoots = .certificates([])
    config.curves = classical ? [.x25519] : [.x25519_MLKEM768]
    config.applicationProtocols = noALPN ? [] : [PeerTLSProfile.alpn]
    let native = try NIOSSLContext(configuration: config)
    if let secret {
        try secret.withBytes {
            try native.tractandaInstallPSK(
                key: $0, identity: selected.identity, context: importerContext ?? selected.importerContext)
        }
    }
    return native
}

final class Pair {
    let client = EmbeddedChannel(), server = EmbeddedChannel()
    let clientCapture = Capture(), serverCapture = Capture()
    let clientSessions = Sessions(), serverSessions = Sessions()
    var wire = Wire()
    var corruptServerCipher = false
    var corruptNextCiphertext = false
    private var cipherCorrupted = false
    init(
        client context: PeerTLSContext?, server: PeerTLSContext? = nil,
        rawClient: NIOSSLContext? = nil, rawServer: NIOSSLContext? = nil,
        responder: PeerTLSResponderContext? = nil
    ) throws {
        if let context {
            let sessions = clientSessions
            let future = context.install(on: client) { sessions.append($0) }
            client.embeddedEventLoop.run()
            try future.wait()
        } else {
            try client.pipeline.syncOperations.addHandler(
                NIOSSLClientHandler(context: rawClient!, serverHostname: nil))
        }
        if let responder {
            let sessions = serverSessions
            let future = responder.install(on: self.server) { sessions.append($0) }
            self.server.embeddedEventLoop.run()
            try future.wait()
        } else if let server {
            let sessions = serverSessions
            let future = server.install(on: self.server) { sessions.append($0) }
            self.server.embeddedEventLoop.run()
            try future.wait()
        } else {
            try self.server.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: rawServer!))
        }
        try client.pipeline.syncOperations.addHandler(clientCapture)
        try self.server.pipeline.syncOperations.addHandler(serverCapture)
    }
    deinit {
        client.close(promise: nil)
        server.close(promise: nil)
        client.embeddedEventLoop.advanceTime(by: .hours(1))
        server.embeddedEventLoop.advanceTime(by: .hours(1))
        _ = try? client.finish(acceptAlreadyClosed: true)
        _ = try? server.finish(acceptAlreadyClosed: true)
    }
    func start() throws {
        server.pipeline.fireChannelActive()
        _ = client.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 1))
        try pump()
    }
    func pump() throws {
        for _ in 0..<64 {
            client.embeddedEventLoop.run()
            server.embeddedEventLoop.run()
            var progressed = false
            for (source, destination, isClient) in [(client, server, true), (server, client, false)] {
                while let output = try source.readOutbound(as: IOData.self) {
                    guard case .byteBuffer(var buffer) = output else {
                        throw FixtureError.failed("file region")
                    }
                    if !isClient && corruptServerCipher && !cipherCorrupted {
                        var bytes = Array(buffer.readableBytesView)
                        if bytes.count > 44 && bytes[0] == 22 && bytes[5] == 2 {
                            let offset = 44 + Int(bytes[43])
                            try check(offset + 2 <= bytes.count, "server hello cipher offset")
                            bytes[offset] = 0x13
                            bytes[offset + 1] = 0x01
                            buffer = ByteBuffer(bytes: bytes)
                            cipherCorrupted = true
                        }
                    }
                    if isClient && corruptNextCiphertext {
                        var bytes = Array(buffer.readableBytesView)
                        try check(bytes.count > 21 && bytes[0] == 23, "expected protected application record")
                        bytes[bytes.count - 1] ^= 1
                        buffer = ByteBuffer(bytes: bytes)
                        corruptNextCiphertext = false
                    }
                    try wire.observe(buffer, client: isClient)
                    _ = try destination.writeInbound(buffer)
                    progressed = true
                }
            }
            if !progressed { return }
        }
        throw FixtureError.failed("finite handshake pump exhausted")
    }
    func payload() throws {
        let request = Array("synthetic package protected payload".utf8)
        let reply = Array("synthetic protected reply".utf8)
        let sent = client.writeAndFlush(ByteBuffer(bytes: request))
        try pump()
        try sent.wait()
        try check(serverCapture.received == [request], "client payload")
        let response = server.writeAndFlush(ByteBuffer(bytes: reply))
        try pump()
        try response.wait()
        try check(clientCapture.received == [reply], "server payload")
        try check(
            !wire.bytes.windows(count: request.count).contains(ArraySlice(request)), "plaintext on wire")
    }
}
extension Array where Element: Equatable {
    func windows(count: Int) -> [ArraySlice<Element>] {
        guard count > 0 && self.count >= count else { return [] }
        return (0...self.count - count).map { self[$0..<$0 + count] }
    }
}
