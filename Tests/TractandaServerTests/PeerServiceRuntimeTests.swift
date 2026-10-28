import CTractandaPlatform
import Foundation
import NIOCore
import NIOPosix
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport
@testable import TractandaServer

private actor PeerRefreshPause {
    var continuation: CheckedContinuation<Void, Never>?
    var used = false
    func wait(_ entered: XCTestExpectation) async {
        guard !used else { return }
        used = true
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

final class PeerServiceRuntimeTests: XCTestCase {
    private func fixture() throws -> PeerServiceFixture {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "r", source: "PeerServiceRuntimeTests", test: name)
        return try PeerServiceFixture(root: root)
    }
    private func coordinator(_ root: URL, _ accounts: PeerServiceFixture.Accounts) async throws
        -> ServiceCoordinator
    {
        try await ServiceCoordinator(
            opening: root, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
    }
    private func limits() -> PeerConnectionLimits {
        var value = PeerConnectionLimits()
        value.connectSeconds = 0.5
        value.handshakeSeconds = 2
        value.exchange.operationSeconds = 2
        value.exchange.sessionSeconds = 15
        return value
    }
    private func call(
        _ service: ServiceCoordinator, _ uid: UInt32, _ method: String,
        _ arguments: [String: Any] = [:]
    ) async throws -> [Any] {
        let bytes = try await nativeFixtureResponse(
            service, forUID: uid, method: method,
            arguments: JSONSerialization.data(withJSONObject: arguments), callID: "r")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return try XCTUnwrap((object["methodResponses"] as? [[Any]])?.first)
    }
    private func inventory(_ connection: PeerExchangeConnection) async throws {
        let bytes = try await connection.request(.init("inventory")).get()
        XCTAssertNotNil(try JSON.decode([String: ItemValue].self, bytes)["entries"])
    }

    func testActivatedPeerFallbackBidirectionalExchangeOrdinaryWriteAndShutdown() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.releaseWriter()
        let source = try await coordinator(f.sourceRoot, f.accounts)
        let target = try await coordinator(f.targetRoot, f.accounts)
        defer {
            await source.close()
            await target.close()
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let responder = try PeerServiceRuntime(
            configuration: .init(), coordinator: target, group: group, limits: limits())
        await responder.refreshNow()
        await responder.activate()
        let listener = try await DaemonListeners.peer(
            group: group, host: "127.0.0.1", port: 0,
            initialize: { responder.install(on: $0) })
        defer {
            try? await listener.close()
            await responder.close()
        }
        let port = try XCTUnwrap(listener.port)
        let partial = try await ClientBootstrap(group: group).connectTimeout(.seconds(2))
            .connect(host: "127.0.0.1", port: port).get()
        try await partial.closeFuture.get()  // Incomplete TLS owns a child only until its admission deadline.
        // First candidate has no IPv6 listener; the winning IPv4 connection must be returned.
        let resolver = PeerNameResolver(loop: group.next()) { _, port in
            [
                try SocketAddress(ipAddress: "::1", port: port),
                try SocketAddress(ipAddress: "127.0.0.1", port: port),
            ]
        }
        let initiator = try PeerServiceRuntime(
            configuration: .init(peers: [.init(alias: "target", host: "dual.example", port: port)]),
            coordinator: source, group: group, limits: limits(), resolver: resolver)
        defer { await initiator.close() }
        await initiator.activate()
        let connection = try await initiator.connect(peerID: "target")
        try await inventory(connection)
        let accepted = await responder.connectionsForTesting()
        XCTAssertEqual(accepted.count, 1)
        try await inventory(XCTUnwrap(accepted.first))
        let before = try await source.loadPeerRuntimeSnapshot()
        let commit = CommitRequest(
            classID: "Item", changes: ["subject": .text("ordinary service write")],
            operationID: "service-write")
        let arguments = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSON.encode(commit)) as? [String: Any])
        let committed = try await call(source, f.accounts.human, "TractandaItem/commit", arguments)
        XCTAssertEqual(committed.first as? String, "TractandaItem/commit")
        await initiator.refreshNow()
        let after = try await source.loadPeerRuntimeSnapshot()
        XCTAssertEqual(before.securityToken, after.securityToken)
        let reused = try await initiator.connect(peerID: "target")
        XCTAssertTrue(connection === reused)
        try await inventory(connection)
        await initiator.close()
        await responder.close()
        try await connection.closed.get()
        let drained = await responder.connectionsForTesting()
        XCTAssertTrue(drained.isEmpty)
        do {
            _ = try await initiator.connect(peerID: "target")
            XCTFail("Closed runtime connected")
        } catch {}
        try f.capacity()
    }

    func testUnknownWrongSecretRotationAndDisposalDenyCurrentAdmission() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.releaseWriter()
        let source = try await coordinator(f.sourceRoot, f.accounts)
        let target = try await coordinator(f.targetRoot, f.accounts)
        defer {
            await source.close()
            await target.close()
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let runtime = try PeerServiceRuntime(
            configuration: .init(), coordinator: target, group: group, limits: limits())
        await runtime.refreshNow()
        await runtime.activate()
        let listener = try await DaemonListeners.peer(
            group: group, host: "127.0.0.1", port: 0, initialize: { runtime.install(on: $0) })
        defer {
            try? await listener.close()
            await runtime.close()
        }
        let port = try XCTUnwrap(listener.port)
        let original = f.request.sourceCredential
        let resolver = PeerNameResolver(loop: group.next())
        defer { try? await resolver.close() }
        let binding = original.binding
        let unknown = try PeerExchangeBinding(
            peerID: binding.peerID, storeID: binding.storeID,
            localReplicaID: binding.localReplicaID, remoteReplicaID: binding.remoteReplicaID,
            pairingID: PeerServiceFixture.id(), localIsInitiator: true,
            configurationDigest: binding.configurationDigest)
        for credential in [
            try PeerCredential(binding: unknown, secret: Array(0..<32)),
            try PeerCredential(binding: binding, secret: [UInt8](repeating: 7, count: 32)),
        ] {
            do {
                _ = try await PeerConnector.connect(
                    group: group, host: "127.0.0.1", port: port,
                    pairing: PeerPairing(credential: credential), coordinator: source, resolver: resolver,
                    limits: limits())
                XCTFail("Unauthenticated client became ready")
            } catch {}
        }
        let good = try await PeerConnector.connect(
            group: group, host: "127.0.0.1", port: port,
            pairing: PeerPairing(credential: original), coordinator: source, resolver: resolver,
            limits: limits())
        try await inventory(good)
        let pause = PeerRefreshPause()
        let entered = expectation(description: "older refresh loaded before rotation")
        await runtime.setRefreshLoadedHookForTesting { await pause.wait(entered) }
        defer { await pause.release() }
        let olderRefresh = Task { await runtime.refreshNow() }
        await fulfillment(of: [entered], timeout: 3)
        let old = f.request.targetCredential.binding
        let rotatedBinding = try PeerExchangeBinding(
            peerID: old.peerID, storeID: old.storeID,
            localReplicaID: old.localReplicaID, remoteReplicaID: old.remoteReplicaID,
            pairingID: old.pairingID, localIsInitiator: false,
            configurationDigest: AuthorityRecordCodec.sha256(Data("rotated-service".utf8)))
        let token = try await target.peerCredentialRegistrationContext(forUID: f.accounts.human)
        try await target.registerPeerCredential(
            PeerCredential(binding: rotatedBinding, secret: [UInt8](repeating: 9, count: 32)),
            permittedOrigins: f.request.targetContext.permittedOrigins, expectedContextToken: token,
            operationID: PeerServiceFixture.id(), forUID: f.accounts.human)
        // No refresh has happened: the post-TLS current snapshot gate must reject the old publication.
        do {
            let stale = try await PeerConnector.connect(
                group: group, host: "127.0.0.1", port: port,
                pairing: PeerPairing(credential: original), coordinator: source, resolver: resolver,
                limits: limits())
            defer { try? await stale.close().get() }
            _ = try await stale.request(.init("inventory")).get()
            XCTFail("Stale server publication returned application success")
        } catch {}
        await runtime.setRefreshLoadedHookForTesting(nil)
        await runtime.refreshNow()
        await pause.release()
        await olderRefresh.value
        let published = await runtime.hasResponderForTesting()
        // The obsolete refresh's validation failure cannot clear the newer publication.
        XCTAssertTrue(published)
        try await good.closed.get()
        try await target.removePeerIntakeForTesting(
            peerID: old.peerID, origins: [old.remoteReplicaID], operationID: PeerServiceFixture.id(),
            forUID: f.accounts.human)
        await runtime.refreshNow()
        let ready = await runtime.hasResponderForTesting()
        XCTAssertFalse(ready)
        try f.capacity()
    }

    func testRebuildRecoversFreshSnapshotAndStaleRefreshCannotRepublishAfterStop() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.releaseWriter()
        let target = try await coordinator(f.targetRoot, f.accounts)
        defer { await target.close() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let runtime = try PeerServiceRuntime(
            configuration: .init(), coordinator: target, group: group, limits: limits())
        defer { await runtime.close() }
        await runtime.refreshNow()
        await runtime.activate()
        let before = try await target.loadPeerRuntimeSnapshot()
        let rebuilding = try await call(
            target, f.accounts.human, "TractandaStore/rebuild", ["operationID": "peer-service-rebuild"])
        XCTAssertEqual(rebuilding.first as? String, "TractandaStore/rebuild")
        var completed = false
        for _ in 0..<200 {
            let response = try await call(target, f.accounts.human, "TractandaStore/rebuildStatus")
            let status = try JSON.decode(
                StoreRebuildStatus.self, JSONSerialization.data(withJSONObject: response[1]))
            if status.isTerminal {
                XCTAssertEqual(status.state, "completed")
                completed = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(completed)
        let fresh = try await target.loadPeerRuntimeSnapshot()
        XCTAssertEqual(before.securityToken, fresh.securityToken)
        XCTAssertTrue(before.hasSameCredentials(as: fresh))
        await runtime.refreshNow()
        let recovered = await runtime.hasResponderForTesting()
        XCTAssertTrue(recovered)
        let pause = PeerRefreshPause()
        let entered = expectation(description: "stale refresh loaded")
        await runtime.setRefreshLoadedHookForTesting { await pause.wait(entered) }
        defer { await pause.release() }
        let refreshing = Task { await runtime.refreshNow() }
        await fulfillment(of: [entered], timeout: 3)
        let closing = Task { await runtime.close() }
        // A newer refresh is rejected after shutdown; the earlier loaded value cannot resurrect it.
        for _ in 0..<100 {
            if await runtime.isStoppedForTesting() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let stopped = await runtime.isStoppedForTesting()
        XCTAssertTrue(stopped)
        await runtime.refreshNow()
        await pause.release()
        await refreshing.value
        await closing.value
        let resurrected = await runtime.hasResponderForTesting()
        XCTAssertFalse(resurrected)
        try f.capacity()
    }
    func testCancelledConnectorRetainsSharedDNSBudgetAndCloseDrainsActualLookup() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.releaseWriter()
        let source = try await coordinator(f.sourceRoot, f.accounts)
        defer { await source.close() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let entered = expectation(description: "connector system lookup held")
        let release = DispatchSemaphore(value: 0)
        let resolver = PeerNameResolver(loop: group.next()) { _, port in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return [try SocketAddress(ipAddress: "127.0.0.1", port: port)]
        }
        let runtime = try PeerServiceRuntime(
            configuration: .init(peers: [.init(alias: "target", host: "held.example", port: 1234)]),
            coordinator: source, group: group, limits: limits(), resolver: resolver)
        defer {
            release.signal()
            await runtime.close()
        }
        await runtime.activate()
        let attempt = Task { try await runtime.connect(peerID: "target") }
        await fulfillment(of: [entered], timeout: 3)
        attempt.cancel()
        do {
            _ = try await attempt.value
            XCTFail("Cancelled lookup connected")
        } catch {}
        for _ in 0..<3 {
            do {
                _ = try await runtime.connect(peerID: "target")
                XCTFail("DNS budget released early")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "serviceBusy") }
        }
        let closing = Task { await runtime.close() }
        for _ in 0..<100 {
            if await runtime.isStoppedForTesting() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let held = await resolver.isResolvingForTesting()
        XCTAssertTrue(held)
        release.signal()
        await closing.value
        let children = await runtime.connectionsForTesting()
        // Late DNS completion cannot begin a connection after cancellation/stop.
        XCTAssertTrue(children.isEmpty)
        try f.capacity()
    }

}
