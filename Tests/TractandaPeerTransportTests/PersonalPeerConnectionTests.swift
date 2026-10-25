import Foundation
import NIOCore
import NIOPosix
import Synchronization
import TractandaPeerTLS
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport

private final class PersonalTestConnections: Sendable {
    let values = Mutex<[PersonalPeerConnection]>([])
    func add(_ value: PersonalPeerConnection) { values.withLock { $0.append(value) } }
    var snapshot: [PersonalPeerConnection] { values.withLock { $0 } }
}
private final class PersonalTestAdmission: Sendable {
    let admitted = Mutex(true)
    let requests = Mutex(0)
    func validate() throws {
        guard admitted.withLock({ $0 }) else { throw TractandaError("untrustedPeer", "Removed member.") }
    }
}

final class PersonalPeerConnectionTests: XCTestCase {
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
        let operations = PersonalPeerOperations(
            validate: { _ in try admission.validate() },
            handle: { _, request in
                admission.requests.withLock { $0 += 1 }
                return try JSON.encode(request.fields)
            })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let accepted = PersonalTestConnections()
        let installed = PersonalTestConnections()
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            PersonalPeerConnection.install(on: channel, responder: responder, operations: operations)
                .map { accepted.add($0) }
        }.bind(host: "127.0.0.1", port: 0).get()
        defer {
            try? await listener.close().get()
            for connection in installed.snapshot + accepted.snapshot { try? await connection.close().get() }
        }
        let port = try XCTUnwrap(listener.localAddress?.port)
        _ = try await ClientBootstrap(group: group).channelInitializer { channel in
            PersonalPeerConnection.install(on: channel, pairing: clientPairing, operations: operations)
                .map { installed.add($0) }
        }.connect(host: "127.0.0.1", port: port).get()
        let left = try XCTUnwrap(installed.snapshot.first)
        let readyLeft = try await left.ready.get()
        XCTAssertEqual(readyLeft.remoteReplicaID, rightID)
        let right = try XCTUnwrap(accepted.snapshot.first)
        let readyRight = try await right.ready.get()
        XCTAssertEqual(readyRight.remoteReplicaID, leftID)
        let bytes = Data(repeating: 0x81, count: 256 * 1024)
        async let outbound = left.request(.init("personal.test", ["bytes": .bytes(bytes)])).get()
        async let inbound = right.request(.init("personal.test", ["label": .text("reverse")])).get()
        let results = try await (outbound, inbound)
        XCTAssertEqual(try JSON.decode([String: ItemValue].self, results.0)["bytes"], .bytes(bytes))
        XCTAssertEqual(try JSON.decode([String: ItemValue].self, results.1)["label"], .text("reverse"))
        XCTAssertEqual(admission.requests.withLock { $0 }, 2)
        admission.admitted.withLock { $0 = false }
        do {
            _ = try await left.request(.init("personal.test")).get()
            XCTFail("Removed member executed an operation")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "untrustedPeer") }
        XCTAssertEqual(admission.requests.withLock { $0 }, 2)
    }

    func testPersonalBudgetsAreGenerousConfigurableAndRejectInvalidOverrides() throws {
        XCTAssertEqual(try PersonalPeerLimits.configured(environment: [:]).handshakeSeconds, 86_400)
        XCTAssertEqual(try PersonalPeerLimits.configured(environment: [:]).operationSeconds, 86_400)
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
        }
    }

    func testPersonalWireRejectsHistoricalVersionAndOversizedFrames() throws {
        let frame = PeerExchangeCodec.Frame(version: 2, requestID: 0, kind: .declaration, body: Data())
        XCTAssertThrowsError(try PeerExchangeCodec.decode(JSON.encode(frame), expectedVersion: 3))
        let personal = PeerExchangeCodec.Frame(version: 3, requestID: 0, kind: .declaration, body: Data())
        XCTAssertNoThrow(try PeerExchangeCodec.decode(JSON.encode(personal), expectedVersion: 3))
        XCTAssertThrowsError(try PeerExchangeCodec.decode(JSON.encode(personal)))
        let oversized = PeerExchangeCodec.Frame(
            version: 3, requestID: 1, kind: .request,
            body: Data(repeating: 0, count: PeerExchangeCodec.maximumFrameBytes))
        XCTAssertThrowsError(try PeerExchangeCodec.encode(oversized, allocator: ByteBufferAllocator()))
    }
}
