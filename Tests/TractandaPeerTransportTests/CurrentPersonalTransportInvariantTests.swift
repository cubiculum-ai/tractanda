import Foundation
import NIOCore
import NIOEmbedded
import Synchronization
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport

private actor PersonalOperationGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class PersonalFutureResult<Value: Sendable>: Sendable {
    let value = Mutex<Result<Value, TractandaError>?>(nil)
}

/// Real PSK-protected current frames, without a Store or historical authority genesis.
private final class CurrentPersonalPair {
    let client = NIOAsyncTestingChannel(), server = NIOAsyncTestingChannel()
    let a: PersonalPeerConnection, b: PersonalPeerConnection
    let binding: PeerExchangeBinding
    private var wireBytes = 0
    init(operations: PersonalPeerOperations, limits: PersonalPeerLimits = .init()) async throws {
        let store = try UUID.makeVersion1().uuidString.lowercased()
        let left = try UUID.makeVersion1().uuidString.lowercased()
        let right = try UUID.makeVersion1().uuidString.lowercased()
        let pairing = try UUID.makeVersion1().uuidString.lowercased()
        binding = try .init(
            peerID: "right", storeID: store, localReplicaID: left, remoteReplicaID: right,
            pairingID: pairing, localIsInitiator: true, configurationDigest: String(repeating: "b", count: 64)
        )
        let reverse = try PeerExchangeBinding(
            peerID: "left", storeID: store, localReplicaID: right, remoteReplicaID: left,
            pairingID: pairing, localIsInitiator: false, configurationDigest: binding.configurationDigest)
        let secret = [UInt8](repeating: 0x71, count: 32)
        a = try await PersonalPeerConnection.install(
            on: client, pairing: PeerPairing(credential: PeerCredential(binding: binding, secret: secret)),
            operations: operations, limits: limits
        ).get()
        b = try await PersonalPeerConnection.install(
            on: server, pairing: PeerPairing(credential: PeerCredential(binding: reverse, secret: secret)),
            operations: operations, limits: limits
        ).get()
        client.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 1), promise: nil)
        server.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 1), promise: nil)
        _ = try await value(a.ready)
        _ = try await value(b.ready)
    }
    func pump() async throws {
        for _ in 0..<64 {
            await client.testingEventLoop.run()
            await server.testingEventLoop.run()
            var progressed = false
            for (source, target) in [(client, server), (server, client)] {
                while let output = try await source.readOutbound(as: IOData.self) {
                    guard case .byteBuffer(let bytes) = output else {
                        throw TractandaError("testFixture", "Unexpected file region")
                    }
                    wireBytes += bytes.readableBytes
                    guard wireBytes <= 8 * 1024 * 1024 else {
                        throw TractandaError("testFixture", "Current frame fixture wire bound")
                    }
                    if target.isActive { _ = try await target.writeInbound(bytes) }
                    progressed = true
                }
            }
            if !progressed { return }
        }
        throw TractandaError("testFixture", "Current frame pump did not quiesce")
    }
    func value<Value: Sendable>(_ future: EventLoopFuture<Value>) async throws -> Value {
        let completed = PersonalFutureResult<Value>()
        future.whenComplete { result in
            completed.value.withLock {
                $0 = result.mapError {
                    $0 as? TractandaError ?? TractandaError("testFixture", String(describing: $0))
                }
            }
        }
        for _ in 0..<4096 {
            if let result = completed.value.withLock({ $0 }) { return try result.get() }
            do { try await pump() } catch {
                if let result = completed.value.withLock({ $0 }) { return try result.get() }
                throw error
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        throw TractandaError("testFixture", "Tiny current frame completion did not arrive")
    }
    func entered(_ gate: PersonalOperationGate) async throws {
        for _ in 0..<1000 {
            try await pump()
            if await gate.entered { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw TractandaError("testFixture", "Current operation did not enter its gate")
    }
    func close() async {
        client.close(promise: nil)
        server.close(promise: nil)
        try? await pump()
        _ = try? await client.finish(acceptAlreadyClosed: true)
        _ = try? await server.finish(acceptAlreadyClosed: true)
    }
}

final class CurrentPersonalTransportInvariantTests: XCTestCase {
    private func operations() -> PersonalPeerOperations {
        .init(validate: { _ in }, handle: { _, _ in try JSON.encode(["ready": true]) })
    }

    func testCurrentIncrementalHeadersOrderingAndUnsolicitedRepliesCloseTheActualHandler() async throws {
        // Header fragmentation and coalescing exercise the current live parser, not just its codec.
        for declared in [UInt32(0), UInt32(PeerExchangeCodec.maximumFrameBytes + 1)] {
            let pair = try await CurrentPersonalPair(operations: operations())
            var header = ByteBufferAllocator().buffer(capacity: 4)
            header.writeInteger(declared)
            pair.client.writeAndFlush(try XCTUnwrap(header.readSlice(length: 3)), promise: nil)
            try await pair.pump()
            XCTAssertTrue(pair.server.isActive)
            pair.client.writeAndFlush(try XCTUnwrap(header.readSlice(length: 1)), promise: nil)
            try? await pair.pump()
            XCTAssertFalse(pair.server.isActive)
            await pair.close()
        }
        for scenario in 0..<4 {
            let pair = try await CurrentPersonalPair(operations: operations())
            let body = try PersonalPeerJMAP.request(
                .init("personal.sync.ready"), binding: pair.binding,
                maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes())
            let frames: [PeerExchangeCodec.Frame]
            switch scenario {
            case 0:
                frames = [
                    .init(version: PersonalPeerJMAP.wireVersion, requestID: 2, kind: .request, body: body)
                ]
            case 1:
                frames = [
                    .init(version: PersonalPeerJMAP.wireVersion, requestID: 99, kind: .response, body: Data())
                ]
            default:
                frames = [
                    .init(version: PersonalPeerJMAP.wireVersion, requestID: 1, kind: .request, body: body),
                    .init(
                        version: PersonalPeerJMAP.wireVersion, requestID: scenario == 2 ? 1 : 2,
                        kind: .request, body: body),
                ]
            }
            var coalesced = ByteBufferAllocator().buffer(capacity: 2048)
            for frame in frames {
                var encoded = try PeerExchangeCodec.encode(frame, allocator: ByteBufferAllocator())
                coalesced.writeBuffer(&encoded)
            }
            pair.client.writeAndFlush(coalesced, promise: nil)
            try? await pair.pump()
            XCTAssertFalse(pair.server.isActive)
            await pair.close()
        }
    }

    func testCurrentSuspendedReplyRechecksMembershipAndDisconnectNeverReturnsSuccess() async throws {
        for disconnect in [false, true] {
            let gate = PersonalOperationGate()
            let admitted = Mutex(true)
            let calls = Mutex(0)
            let operation = PersonalPeerOperations(
                validate: { _ in
                    guard admitted.withLock({ $0 }) else {
                        throw TractandaError("untrustedPeer", "Removed member")
                    }
                },
                handle: { _, _ in
                    calls.withLock { $0 += 1 }
                    await gate.pause()
                    return try JSON.encode(["ready": true])
                })
            let pair = try await CurrentPersonalPair(operations: operation)
            let pending = pair.a.request(.init("personal.sync.ready"))
            try await pair.entered(gate)
            XCTAssertEqual(calls.withLock { $0 }, 1)
            if disconnect { _ = pair.a.close() } else { admitted.withLock { $0 = false } }
            try? await pair.pump()
            await gate.release()
            do {
                _ = try await pair.value(pending)
                XCTFail("A suspended reply escaped current revocation or disconnect")
            } catch let error as TractandaError {
                XCTAssertEqual(error.code, disconnect ? "connectionClosed" : "untrustedPeer")
            }
            await pair.close()
        }
    }

    func testDefaultHealthyWaitSurvivesVirtualDaysAndOnlyExplicitLimitExpiresIt() async throws {
        for explicit in [false, true] {
            let gate = PersonalOperationGate()
            let operation = PersonalPeerOperations(
                validate: { _ in },
                handle: { _, _ in
                    await gate.pause()
                    return try JSON.encode(["ready": true])
                })
            var limits = PersonalPeerLimits()
            if explicit { limits.operationSeconds = 1 }
            let pair = try await CurrentPersonalPair(operations: operation, limits: limits)
            let pending = pair.a.request(.init("personal.sync.ready"))
            try await pair.entered(gate)
            await pair.client.testingEventLoop.advanceTime(by: .seconds(explicit ? 2 : 172_800))
            await pair.server.testingEventLoop.advanceTime(by: .seconds(explicit ? 2 : 172_800))
            try? await pair.pump()
            if !explicit {
                XCTAssertTrue(pair.client.isActive)
                XCTAssertTrue(pair.server.isActive)
            }
            await gate.release()
            if explicit {
                do {
                    _ = try await pair.value(pending)
                    XCTFail("An explicitly configured operation limit was ignored")
                } catch let error as TractandaError { XCTAssertEqual(error.code, "deadlineExceeded") }
            } else {
                let reply = try await pair.value(pending)
                XCTAssertEqual(try JSON.decode([String: Bool].self, reply)["ready"], true)
            }
            await pair.close()
        }
    }
}
