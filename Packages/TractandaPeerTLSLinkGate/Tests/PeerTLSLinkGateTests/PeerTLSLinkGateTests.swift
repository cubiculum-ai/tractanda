// First-party synthetic dependency/link proof; governed by the repository LICENSE.
import Crypto
import CryptoExtras
import Foundation
import NIOCore
import NIOEmbedded
import Synchronization
import TractandaCore
import TractandaPeerTLS
import XCTest

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
    var errors: [Error] = []
    var received: [[UInt8]] = []
    func channelActive(context: ChannelHandlerContext) { active += 1 }
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

func profile() throws -> PeerTLSProfile {
    try .init(
        storeID: "01010101-0101-1101-8101-010101010101",
        initiatorReplicaID: "02020202-0202-1202-8202-020202020202",
        responderReplicaID: "03030303-0303-1303-8303-030303030303",
        pairingID: "04040404-0404-1404-8404-040404040404")
}
final class Pair {
    let client = EmbeddedChannel(), server = EmbeddedChannel()
    let clientCapture = Capture(), serverCapture = Capture()
    let clientSessions = Sessions(), serverSessions = Sessions()
    var wire = Wire()
    init(clientSecret: PeerTLSSecret, serverSecret: PeerTLSSecret) throws {
        let clientContext = try PeerTLSContext(profile: profile(), role: .initiator, secret: clientSecret)
        let serverContext = try PeerTLSContext(profile: profile(), role: .responder, secret: serverSecret)
        let clientSessions = self.clientSessions
        let serverSessions = self.serverSessions
        let clientInstall = clientContext.install(on: client) { clientSessions.append($0) }
        client.embeddedEventLoop.run()
        try clientInstall.wait()
        let serverInstall = serverContext.install(on: server) { serverSessions.append($0) }
        server.embeddedEventLoop.run()
        try serverInstall.wait()
        try client.pipeline.syncOperations.addHandler(clientCapture)
        try server.pipeline.syncOperations.addHandler(serverCapture)
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
        // EmbeddedChannel models connect; this creates no native socket or listener.
        _ = client.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 1))
        try pump()
    }
    func pump() throws {
        for _ in 0..<64 {
            client.embeddedEventLoop.run()
            server.embeddedEventLoop.run()
            var progressed = false
            for (source, destination, initiator) in [(client, server, true), (server, client, false)] {
                while let output = try source.readOutbound(as: IOData.self) {
                    guard case .byteBuffer(let bytes) = output else {
                        throw FixtureError.failed("file region")
                    }
                    try wire.observe(bytes, client: initiator)
                    _ = try destination.writeInbound(bytes)
                    progressed = true
                }
            }
            if !progressed { return }
        }
        throw FixtureError.failed("finite handshake pump exhausted")
    }
    func exchange(_ bytes: [UInt8]) throws {
        let sent = client.writeAndFlush(ByteBuffer(bytes: bytes))
        try pump()
        try sent.wait()
        try check(serverCapture.received == [bytes], "protected Core payload")
        let response = server.writeAndFlush(ByteBuffer(bytes: bytes.reversed()))
        try pump()
        try response.wait()
        try check(clientCapture.received == [Array(bytes.reversed())], "protected response")
        try check(!wire.bytes.windows(ofCount: bytes.count).contains(ArraySlice(bytes)), "plaintext on wire")
    }
}
extension Array {
    func windows(ofCount count: Int) -> [ArraySlice<Element>] {
        guard count > 0, self.count >= count else { return [] }
        return (0...self.count - count).map { self[$0..<$0 + count] }
    }
}
final class PeerTLSLinkGateTests: XCTestCase {
    private func canonicalBytes() throws -> Data {
        try RecordCodec.encode(
            Revision(fields: [
                "itemID": .text("05050505-0505-1505-8505-050505050505"),
                "revisionID": .text("06060606-0606-1606-8606-060606060606"),
                "classID": .text("Item"), "schemaVersion": .integer(1),
                "createdAt": .date("2026-10-14T00:00:00Z"), "modifiedAt": .date("2026-10-14T00:00:00Z"),
                "actor": .text("synthetic-link-gate"), "operationID": .text("link-proof"),
                "requestIdentity": .text("synthetic-only"), "subject": .text("Core TLS link proof"),
            ]))
    }
    func testRealCoreRecordCodec() throws {
        let bytes = try canonicalBytes()
        let decoded = try RecordCodec.decode(bytes)
        XCTAssertEqual(decoded.fields["subject"], .text("Core TLS link proof"))
        XCTAssertEqual(try RecordCodec.encode(decoded), bytes)
    }
    func testCryptoExtrasForcesCCryptoBoringSSL() throws {
        // Test control only, not a transport cipher or new cryptographic protocol.
        let key = SymmetricKey(data: [UInt8](repeating: 0x31, count: 32))
        let iv = try AES._CBC.IV(ivBytes: [UInt8](repeating: 0x52, count: 16))
        let original = Data("synthetic CryptoExtras link control".utf8)
        let sealed = try AES._CBC.encrypt(original, using: key, iv: iv)
        XCTAssertNotEqual(sealed, original)
        XCTAssertEqual(try AES._CBC.decrypt(sealed, using: key, iv: iv), original)
    }
    func testTwoFreshHybridPSKSessionsProtectCoreBytes() throws {
        let secret = try PeerTLSSecret.generate()
        var previous: (client: [UInt8], server: [UInt8])?
        for _ in 0..<2 {
            let pair = try Pair(clientSecret: secret, serverSecret: secret)
            XCTAssertEqual(pair.clientCapture.active, 0)
            try pair.start()
            XCTAssertEqual(pair.clientSessions.count, 1)
            XCTAssertEqual(pair.serverSessions.count, 1)
            XCTAssertEqual(pair.clientCapture.active, 1)
            XCTAssertEqual(pair.serverCapture.active, 1)
            let session = try XCTUnwrap(pair.clientSessions.values.withLock { $0.first })
            XCTAssertEqual(session.cipherSuite, 0x1302)
            XCTAssertEqual(session.keyExchangeGroup, 0x11ec)
            XCTAssertEqual(session.remoteReplicaID, try profile().responderReplicaID)
            XCTAssertTrue(pair.wire.selectedPSK)
            XCTAssertEqual(pair.wire.modes, [1])
            XCTAssertFalse(pair.wire.early)
            XCTAssertEqual(pair.wire.cipher, 0x1302)
            let client = try XCTUnwrap(pair.wire.clientShares.first)
            let server = try XCTUnwrap(pair.wire.serverShares.first)
            XCTAssertEqual(pair.wire.clientShares.count, 1)
            XCTAssertEqual(pair.wire.serverShares.count, 1)
            XCTAssertEqual(client.count, 1216)
            XCTAssertEqual(server.count, 1120)
            if let previous {
                XCTAssertNotEqual(client, previous.client)
                XCTAssertNotEqual(server, previous.server)
            }
            previous = (client, server)
            try pair.exchange(Array(canonicalBytes()))
            XCTAssertTrue(pair.clientCapture.errors.isEmpty && pair.serverCapture.errors.isEmpty)
        }
    }
    func testWrongSecretExplicitlyRejectsWithoutHandoff() throws {
        let pair = try Pair(clientSecret: .generate(), serverSecret: .generate())
        try pair.start()
        XCTAssertEqual(pair.clientSessions.count, 0)
        XCTAssertEqual(pair.serverSessions.count, 0)
        XCTAssertEqual(pair.clientCapture.active, 0)
        XCTAssertEqual(pair.serverCapture.active, 0)
        XCTAssertTrue(pair.clientCapture.received.isEmpty && pair.serverCapture.received.isEmpty)
        XCTAssertFalse(
            pair.clientCapture.errors.isEmpty && pair.serverCapture.errors.isEmpty,
            "A timeout/stall is not explicit rejection")
    }
}
