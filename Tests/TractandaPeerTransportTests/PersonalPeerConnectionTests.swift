import Foundation
import NIOCore
import NIOPosix
import Synchronization
import TractandaPeerTLS
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private final class PersonalTestConnections: Sendable {
    typealias Installed = (connection: PersonalPeerConnection, channel: any Channel)
    let values = Mutex<[Installed]>([])
    func add(_ connection: PersonalPeerConnection, on channel: any Channel) {
        values.withLock { $0.append((connection, channel)) }
    }
    var snapshot: [Installed] { values.withLock { $0 } }
}
private final class PersonalTestAdmission: Sendable {
    let admitted = Mutex(true)
    let requests = Mutex(0)
    func validate() throws {
        guard admitted.withLock({ $0 }) else { throw TractandaError("untrustedPeer", "Removed member.") }
    }
}

private final class PersonalDroppedReply: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = IOData
    let dropped: EventLoopPromise<Void>
    init(loop: any EventLoop) { dropped = loop.makePromise() }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
        dropped.succeed(())
        context.close(promise: nil)
    }
}

final class PersonalPeerConnectionTests: XCTestCase {
    private func assertKeepalive(on channel: any Channel) async throws {
        #if canImport(Darwin)
            let idleOption = TCP_KEEPALIVE
        #else
            let idleOption = TCP_KEEPIDLE
        #endif
        let enabled = try await channel.getOption(.socketOption(.so_keepalive)).get()
        let idle = try await channel.getOption(.tcpOption(.init(rawValue: idleOption))).get()
        let interval = try await channel.getOption(.tcpOption(.init(rawValue: TCP_KEEPINTVL))).get()
        let probes = try await channel.getOption(.tcpOption(.init(rawValue: TCP_KEEPCNT))).get()
        XCTAssertNotEqual(enabled, 0)
        XCTAssertEqual(idle, 60)
        XCTAssertEqual(interval, 30)
        XCTAssertEqual(probes, 9)
    }

    func testActualTLSLoopbackIsBidirectionalAndRechecksMembershipForEachOperation() async throws {
        // No filesystem fixture. Wire memory is less than 2MiB and payloads below 256KiB.
        let store = try UUID.makeVersion1().uuidString.lowercased()
        let leftID = try UUID.makeVersion1().uuidString.lowercased()
        let rightID = try UUID.makeVersion1().uuidString.lowercased()
        let pairingID = try UUID.makeVersion1().uuidString.lowercased()
        let digest = String(repeating: "a", count: 64)
        func pairing(local: String, remote: String, initiator: Bool) throws -> PeerPairing {
            try PeerPairing(
                credential: PeerCredential(
                    binding: PeerExchangeBinding(
                        peerID: initiator ? "right-out" : "left-in", storeID: store,
                        localReplicaID: local, remoteReplicaID: remote, pairingID: pairingID,
                        localIsInitiator: initiator, configurationDigest: digest),
                    secret: Array(repeating: 0x67, count: 32)))
        }
        let clientPairing = try pairing(local: leftID, remote: rightID, initiator: true)
        let serverPairing = try pairing(local: rightID, remote: leftID, initiator: false)
        let responder = try PeerExchangeResponder(pairings: [serverPairing])
        let admission = PersonalTestAdmission()
        let bytes = Data(repeating: 0x81, count: 256 * 1024)
        let descriptor = try PersonalObjectDescriptor(
            kind: .revision, id: UUID.makeVersion1().uuidString.lowercased(), byteCount: Int64(bytes.count),
            sha256: String(repeating: "a", count: 64), itemID: UUID.makeVersion1().uuidString.lowercased())
        let readFields: [String: ItemValue] = [
            "descriptor": .bytes(try JSON.encode(descriptor)), "offset": .integer(0),
            "limit": .integer(Int64(bytes.count)),
        ]
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let operations = PersonalPeerOperations(
            validate: { _ in try admission.validate() },
            handle: { _, request in
                admission.requests.withLock { $0 += 1 }
                if request.operation == "personal.sync.ready" {
                    return try JSON.encode(["ready": true])
                }
                return bytes
            })
        let accepted = PersonalTestConnections()
        let installed = PersonalTestConnections()
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            PersonalPeerConnection.install(on: channel, responder: responder, operations: operations)
                .map { accepted.add($0, on: channel) }
        }.bind(host: "127.0.0.1", port: 0).get()
        defer {
            try? await listener.close().get()
            for entry in installed.snapshot + accepted.snapshot { try? await entry.connection.close().get() }
        }
        let port = try XCTUnwrap(listener.localAddress?.port)
        let initializedBeforeConnect = Mutex(false)
        _ = try await ClientBootstrap(group: group).channelInitializer { channel in
            initializedBeforeConnect.withLock { $0 = channel.remoteAddress == nil }
            return PersonalPeerConnection.install(on: channel, pairing: clientPairing, operations: operations)
                .map { installed.add($0, on: channel) }
        }.connect(host: "127.0.0.1", port: port).get()
        XCTAssertTrue(initializedBeforeConnect.withLock { $0 })
        let (left, leftSocket) = try XCTUnwrap(installed.snapshot.first)
        let readyLeft = try await left.ready.get()
        XCTAssertEqual(readyLeft.remoteReplicaID, rightID)
        let (right, rightSocket) = try XCTUnwrap(accepted.snapshot.first)
        let readyRight = try await right.ready.get()
        XCTAssertEqual(readyRight.remoteReplicaID, leftID)
        try await assertKeepalive(on: leftSocket)
        try await assertKeepalive(on: rightSocket)
        async let outbound = left.request(.init("personal.read", readFields)).get()
        async let inbound = right.request(.init("personal.read", readFields)).get()
        let results = try await (outbound, inbound)
        XCTAssertEqual(results.0, bytes)
        XCTAssertEqual(results.1, bytes)
        XCTAssertEqual(admission.requests.withLock { $0 }, 2)
        admission.admitted.withLock { $0 = false }
        do {
            _ = try await left.request(.init("personal.sync.ready")).get()
            XCTFail("Removed member executed an operation")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "untrustedPeer") }
        XCTAssertEqual(admission.requests.withLock { $0 }, 2)

        admission.admitted.withLock { $0 = true }
        // Drop the next encrypted reply and close the underlying socket while the
        // initiator still has a pending RPC.
        let droppedReply = PersonalDroppedReply(loop: rightSocket.eventLoop)
        try await rightSocket.pipeline.addHandler(droppedReply, position: .first).get()
        let pending = left.request(.init("personal.sync.ready"))
        try await droppedReply.dropped.futureResult.get()
        try await right.closed.get()
        let reply = try? await pending.get()
        XCTAssertNil(reply, "A disconnected peer returned a successful pending reply.")
        try await left.closed.get()
    }

    func testActualUnixDomainTLSAndBidirectionalRequestsDoNotApplyTCPKeepalive() async throws {
        let directory = URL(fileURLWithPath: "/tmp/trac-peer-uds-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try UUID.makeVersion1().uuidString.lowercased()
        let leftID = try UUID.makeVersion1().uuidString.lowercased()
        let rightID = try UUID.makeVersion1().uuidString.lowercased()
        let pairingID = try UUID.makeVersion1().uuidString.lowercased()
        func pairing(local: String, remote: String, initiator: Bool) throws -> PeerPairing {
            try PeerPairing(
                credential: PeerCredential(
                    binding: PeerExchangeBinding(
                        peerID: initiator ? "right-out" : "left-in", storeID: store,
                        localReplicaID: local, remoteReplicaID: remote, pairingID: pairingID,
                        localIsInitiator: initiator, configurationDigest: String(repeating: "a", count: 64)),
                    secret: Array(repeating: 0x67, count: 32)))
        }
        let clientPairing = try pairing(local: leftID, remote: rightID, initiator: true)
        let responder = try PeerExchangeResponder(
            pairings: [pairing(local: rightID, remote: leftID, initiator: false)])
        let response = Data("{\"ready\":true}".utf8)
        let operations = PersonalPeerOperations(validate: { _ in }, handle: { _, _ in response })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let accepted = PersonalTestConnections()
        let installed = PersonalTestConnections()
        let socket = directory.appendingPathComponent("peer.sock").path
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            PersonalPeerConnection.install(on: channel, responder: responder, operations: operations)
                .map { accepted.add($0, on: channel) }
        }.bind(unixDomainSocketPath: socket).get()
        defer {
            try? await listener.close().get()
            for entry in installed.snapshot + accepted.snapshot { try? await entry.connection.close().get() }
        }
        _ = try await ClientBootstrap(group: group).channelInitializer { channel in
            PersonalPeerConnection.install(on: channel, pairing: clientPairing, operations: operations)
                .map { installed.add($0, on: channel) }
        }.connect(unixDomainSocketPath: socket).get()
        let (left, leftSocket) = try XCTUnwrap(installed.snapshot.first)
        let readyLeft = try await left.ready.get()
        XCTAssertEqual(readyLeft.remoteReplicaID, rightID)
        let (right, rightSocket) = try XCTUnwrap(accepted.snapshot.first)
        let readyRight = try await right.ready.get()
        XCTAssertEqual(readyRight.remoteReplicaID, leftID)
        XCTAssertEqual(leftSocket.remoteAddress?.protocol, .unix)
        XCTAssertEqual(rightSocket.localAddress?.protocol, .unix)
        async let outbound = left.request(.init("personal.sync.ready")).get()
        async let inbound = right.request(.init("personal.sync.ready")).get()
        let replies = try await (outbound, inbound)
        XCTAssertEqual(try JSON.decode([String: Bool].self, replies.0), ["ready": true])
        XCTAssertEqual(try JSON.decode([String: Bool].self, replies.1), ["ready": true])
    }

    func testPersonalOperationDeadlineIsOptInAndOtherBudgetsRemainConfigurable() throws {
        XCTAssertEqual(try PersonalPeerLimits.configured(environment: [:]).handshakeSeconds, 86_400)
        XCTAssertNil(try PersonalPeerLimits.configured(environment: [:]).operationSeconds)
        XCTAssertEqual(try PersonalPeerLimits.configured(environment: [:]).partialFrameSeconds, 86_400)
        let configured = try PersonalPeerLimits.configured(environment: [
            "TRACTANDA_PERSONAL_PEER_HANDSHAKE_SECONDS": "172800",
            "TRACTANDA_PERSONAL_PEER_OPERATION_SECONDS": "259200",
        ])
        XCTAssertEqual(configured.handshakeSeconds, 172_800)
        XCTAssertEqual(configured.operationSeconds, 259_200)
        for value in ["0", "-1", "nan", "inf", "604801", "bad"] {
            XCTAssertThrowsError(
                try PersonalPeerLimits.configured(environment: [
                    "TRACTANDA_PERSONAL_PEER_HANDSHAKE_SECONDS": value
                ]))
            XCTAssertThrowsError(
                try PersonalPeerLimits.configured(environment: [
                    "TRACTANDA_PERSONAL_PEER_OPERATION_SECONDS": value
                ]))
        }
    }

    func testPersonalWireRejectsHistoricalVersionAndOversizedFrames() throws {
        let frame = PeerExchangeCodec.Frame(version: 2, requestID: 0, kind: .declaration, body: Data())
        XCTAssertThrowsError(
            try PeerExchangeCodec.decode(JSON.encode(frame), expectedVersion: PersonalPeerJMAP.wireVersion))
        let personal = PeerExchangeCodec.Frame(
            version: PersonalPeerJMAP.wireVersion, requestID: 0, kind: .declaration, body: Data())
        XCTAssertNoThrow(
            try PeerExchangeCodec.decode(JSON.encode(personal), expectedVersion: PersonalPeerJMAP.wireVersion)
        )
        XCTAssertThrowsError(try PeerExchangeCodec.decode(JSON.encode(personal)))
        let oversized = PeerExchangeCodec.Frame(
            version: PersonalPeerJMAP.wireVersion, requestID: 1, kind: .request,
            body: Data(repeating: 0, count: PeerExchangeCodec.maximumFrameBytes))
        XCTAssertThrowsError(try PeerExchangeCodec.encode(oversized, allocator: ByteBufferAllocator()))
    }
}
