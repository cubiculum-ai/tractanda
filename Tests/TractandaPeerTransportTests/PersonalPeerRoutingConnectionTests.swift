import Foundation
import NIOCore
import NIOPosix
import Synchronization
import TractandaPeerTLS
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport

private actor RoutingReservation {
    private var channel: (any Channel)?
    private var allowed = true
    func reserve(_ candidate: any Channel) throws {
        guard allowed else { throw TractandaError("untrustedPeer", "Removed member.") }
        guard channel?.isActive != true else { throw TractandaError("duplicatePeer", "Already reserved.") }
        channel = candidate
    }
    func remove() { allowed = false }
    func disconnect() async {
        if let channel { try? await channel.close().get() }
        channel = nil
    }
    func active() -> Bool { channel?.isActive == true }
}

/// Speaks the previous v2 capability over real authenticated TLS, without the new reservation.
private final class LegacyRoutingHello: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let session = event as? PeerTLSSession else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        do {
            let hello = [
                "capability": "tractanda.personal-sync.v2", "storeID": session.profile.storeID,
                "senderReplicaID": session.localReplicaID, "receiverReplicaID": session.remoteReplicaID,
                "pairingID": session.profile.pairingID,
                "configurationDigest": String(repeating: "b", count: 64),
            ]
            let bytes = try PeerExchangeCodec.encode(
                .init(
                    version: PersonalPeerJMAP.wireVersion, requestID: 0, kind: .declaration,
                    body: JSON.encode(hello)),
                allocator: context.channel.allocator)
            context.writeAndFlush(NIOAny(bytes), promise: nil)
        } catch { context.close(promise: nil) }
    }
}

final class PersonalPeerRoutingConnectionTests: XCTestCase {
    private func pairings() throws -> (PeerPairing, PeerExchangeResponder) {
        let store = try UUID.makeVersion1().uuidString.lowercased()
        let left = try UUID.makeVersion1().uuidString.lowercased()
        let right = try UUID.makeVersion1().uuidString.lowercased()
        let pair = try UUID.makeVersion1().uuidString.lowercased()
        func pairing(initiator: Bool) throws -> PeerPairing {
            try PeerPairing(
                credential: PeerCredential(
                    binding: PeerExchangeBinding(
                        peerID: initiator ? "right-out" : "left-in", storeID: store,
                        localReplicaID: initiator ? left : right, remoteReplicaID: initiator ? right : left,
                        pairingID: pair, localIsInitiator: initiator,
                        configurationDigest: String(repeating: "b", count: 64)),
                    secret: Array(repeating: 0x68, count: 32)))
        }
        return try (pairing(initiator: true), PeerExchangeResponder(pairings: [pairing(initiator: false)]))
    }
    func testStalledDNSAndTLSDoNotBlockValidAliasRaceAndEstablishedChannelSurvives() async throws {
        // No filesystem fixture. All payloads are tiny; blocked libc substitute is released explicitly.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let (pairing, responder) = try pairings()
        let gate = RoutingReservation()
        let channels = Mutex<[any Channel]>([])
        let calls = Mutex<[String]>([])
        let releaseDNS = DispatchSemaphore(value: 0)
        let operations = PersonalPeerOperations(
            validate: { _ in }, handle: { _, _ in try JSON.encode(["ready": true]) })
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channels.withLock { $0.append(channel) }
            let server = PersonalPeerOperations(
                validate: { _ in }, handle: { _, _ in try JSON.encode(["ready": true]) },
                beforeReady: { _ in try await gate.reserve(channel) })
            return PersonalPeerConnection.install(on: channel, responder: responder, operations: server).map {
                _ in
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        let stalled = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channels.withLock { $0.append(channel) }
            return channel.eventLoop.makeSucceededVoidFuture()
        }.bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(listener.localAddress?.port)
        let stalledPort = try XCTUnwrap(stalled.localAddress?.port)
        let resolver = PeerNameResolver(loop: group.next(), maximumConcurrentLookups: 8) { host, port in
            calls.withLock { $0.append(host) }
            if host == "blocked.example" { _ = releaseDNS.wait(timeout: .now() + 10) }
            return [try SocketAddress(ipAddress: "127.0.0.1", port: port)]
        }
        defer {
            releaseDNS.signal()
            try? await resolver.close()
            try? await listener.close().get()
            try? await stalled.close().get()
            for channel in channels.withLock({ $0 }) { try? await channel.close().get() }
        }
        let endpoints = try [
            PeerRuntimeConfiguration.Endpoint(host: "blocked.example", port: port),
            .init(host: "stalled.example", port: stalledPort),
            .init(host: "lan.example", port: port),
            .init(host: "tail.example", port: port),
        ]
        print("ROUTING_STAGE initial-race")
        let connection = try await PersonalPeerConnector.connect(
            group: group, endpoints: endpoints, pairing: pairing, operations: operations,
            resolver: resolver, connectSeconds: 1, staggerSeconds: 0)
        defer { try? await connection.close().get() }
        XCTAssertTrue(connection.isActive)
        let active = await gate.active()
        XCTAssertTrue(active)
        print("ROUTING_STAGE first-rpc")
        let first = try await connection.request(.init("personal.sync.ready")).get()
        XCTAssertEqual(first, try JSON.encode(["ready": true]))
        // The stagger is not a connection lifetime: a usable channel stays active afterward.
        try await Task.sleep(for: .milliseconds(50))
        print("ROUTING_STAGE second-rpc")
        let second = try await connection.request(.init("personal.sync.ready")).get()
        XCTAssertEqual(second, try JSON.encode(["ready": true]))
        XCTAssertTrue(calls.withLock { $0 }.contains("lan.example"))
        XCTAssertTrue(calls.withLock { $0 }.contains("tail.example"))
        // Explicit disconnect and reconnect must perform fresh DNS, never reuse a durable IP.
        try? await connection.close().get()
        _ = try? await connection.closed.get()
        await gate.disconnect()
        print("ROUTING_STAGE reconnect")
        let reconnected = try await PersonalPeerConnector.connect(
            group: group, endpoints: [endpoints[2]], pairing: pairing, operations: operations,
            resolver: resolver, connectSeconds: 1, staggerSeconds: 0)
        defer { try? await reconnected.close().get() }
        XCTAssertEqual(calls.withLock { $0.filter { $0 == "lan.example" }.count }, 2)
        print("ROUTING_STAGE membership-removal")
        await gate.remove()
        try? await reconnected.close().get()
        _ = try? await reconnected.closed.get()
        await gate.disconnect()
        do {
            _ = try await PersonalPeerConnector.connect(
                group: group, endpoints: [endpoints[2], endpoints[3]], pairing: pairing,
                operations: operations,
                resolver: resolver, connectSeconds: 1, staggerSeconds: 0)
            XCTFail("Removed peer acquired a ready connection")
        } catch {
            let active = await gate.active()
            XCTAssertFalse(active)
        }
    }
    func testExplicitCancellationClosesRacingTLSCandidatesWithoutLateReady() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let (pairing, _) = try pairings()
        let accepted = expectation(description: "both stalled candidates started")
        accepted.expectedFulfillmentCount = 2
        let channels = Mutex<[any Channel]>([])
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channels.withLock { $0.append(channel) }
            accepted.fulfill()
            return channel.eventLoop.makeSucceededVoidFuture()
        }.bind(host: "127.0.0.1", port: 0).get()
        let resolver = PeerNameResolver(loop: group.next(), maximumConcurrentLookups: 8) { _, port in
            [try SocketAddress(ipAddress: "127.0.0.1", port: port)]
        }
        defer {
            try? await resolver.close()
            try? await listener.close().get()
            for channel in channels.withLock({ $0 }) { try? await channel.close().get() }
        }
        let port = try XCTUnwrap(listener.localAddress?.port)
        let endpoints = try ["lan.example", "tail.example"].map {
            try PeerRuntimeConfiguration.Endpoint(host: $0, port: port)
        }
        let task = Task {
            try await PersonalPeerConnector.connect(
                group: group, endpoints: endpoints, pairing: pairing,
                operations: PersonalPeerOperations(validate: { _ in }, handle: { _, _ in Data() }),
                resolver: resolver, staggerSeconds: 0)
        }
        await fulfillment(of: [accepted], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled race returned a connection")
        } catch { XCTAssertTrue(error is CancellationError) }
        for channel in channels.withLock({ $0 }) { try await channel.closeFuture.get() }
    }
    func testOldCapabilityIsRejectedAfterAuthenticatedTLSWithoutCanonicalMigration() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let (pairing, responder) = try pairings()
        let channels = Mutex<[any Channel]>([])
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channels.withLock { $0.append(channel) }
            return responder.tls.install(on: channel) { _ in }.flatMap {
                channel.pipeline.addHandler(LegacyRoutingHello())
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        let resolver = PeerNameResolver(loop: group.next()) { _, port in
            [try SocketAddress(ipAddress: "127.0.0.1", port: port)]
        }
        defer {
            try? await resolver.close()
            try? await listener.close().get()
            for channel in channels.withLock({ $0 }) { try? await channel.close().get() }
        }
        do {
            _ = try await PersonalPeerConnector.connect(
                group: group, host: "legacy.example", port: XCTUnwrap(listener.localAddress?.port),
                pairing: pairing,
                operations: PersonalPeerOperations(validate: { _ in }, handle: { _, _ in Data() }),
                resolver: resolver, connectSeconds: 1)
            XCTFail("Old responder without readiness reservation was admitted")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "incompatiblePeer") }
    }

}
