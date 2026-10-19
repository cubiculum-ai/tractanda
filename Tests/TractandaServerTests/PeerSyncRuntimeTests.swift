import Foundation
import NIOCore
import NIOPosix
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport
@testable import TractandaServer

private final class PeerSocketCloseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    func mark() {
        lock.lock()
        closed = true
        lock.unlock()
    }
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

private actor PeerLeasePause {
    private var continuation: CheckedContinuation<Void, Never>?
    private var used = false
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

final class PeerSyncRuntimeTests: XCTestCase {
    private func fixture() throws -> PeerServiceFixture {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(prefix: "s", source: "PeerSyncRuntimeTests", test: name)
        return try PeerServiceFixture(root: root)
    }
    private func coordinator(_ root: URL, _ accounts: PeerServiceFixture.Accounts) async throws
        -> ServiceCoordinator
    {
        try await ServiceCoordinator(
            opening: root, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
    }
    private func admit(_ lease: PeerLogicalExchange.Lease) async throws {
        let control = try PeerExchangeControl(maximumSeconds: 5)
        let declaration = try await lease.advanceCompatibility(.declare, control: control)
        let acknowledgement = try await lease.advanceCompatibility(.accept(declaration), control: control)
        _ = try await lease.advanceCompatibility(.acknowledge(acknowledgement), control: control)
    }
    private func execute(_ lease: PeerLogicalExchange.Lease, _ request: PeerExchangeRequest) async throws
        -> Data
    {
        try await lease.execute(JSON.encode(request), control: PeerExchangeControl(maximumSeconds: 5))
    }
    func testOverlappingTakeoverCannotInvalidateNewLeaseOrLoseUnacknowledgedPage() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.releaseWriter()
        let target = try await coordinator(f.targetRoot, f.accounts)
        defer { await target.close() }
        let snapshot = try await target.loadPeerRuntimeSnapshot()
        let context = try await PeerLogicalExchange(
            coordinator: target, binding: f.request.targetCredential.binding,
            snapshot: snapshot, maximumScanEntries: 1)
        defer { await context.invalidate() }
        let pause = PeerLeasePause()
        let entered = expectation(description: "old socket closer held")
        defer { await pause.release() }
        let original = try await context.attach(close: { await pause.wait(entered) })
        try await admit(original)
        let round = UUID().uuidString.lowercased()
        let first = PeerExchangeRequest("syncInventory", ["round": .text(round), "ordinal": .integer(0)])
        let page = try await execute(original, first)
        let older = Task { try await context.attach(close: {}) }
        await fulfillment(of: [entered], timeout: 5)
        let current = try await context.attach(close: {})
        do {
            _ = try await execute(current, first)
            XCTFail("A replacement lease reused prior admission")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "peerCompatibilityRequired") }
        try await admit(current)
        let replay = try await execute(current, first)
        XCTAssertEqual(replay, page, "Lost reply replays the same finite page.")
        await pause.release()
        do {
            _ = try await older.value
            XCTFail("Superseded attach succeeded")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "peerLeaseChanged") }
        await original.detach()
        let stillCurrent = try await execute(current, first)
        XCTAssertEqual(stillCurrent, page)
        let next = try await execute(
            current, .init("syncInventory", ["round": .text(round), "ordinal": .integer(1)]))
        XCTAssertNotEqual(next, page, "Acknowledgement advances rather than restarts the scan.")
        do {
            _ = try await execute(original, .init("syncContext"))
            XCTFail("Old socket retained authority")
        } catch {}
        try await target.removePeerIntakeForTesting(
            peerID: f.request.targetContext.peerID,
            origins: [f.request.sourceCredential.binding.localReplicaID],
            operationID: PeerServiceFixture.id(), forUID: f.accounts.human)
        do {
            _ = try await execute(current, first)
            XCTFail("Revoked cached page was returned")
        } catch {}
        await current.detach()
        await current.detach()
        let detached = await context.isIdle(before: .infinity)
        XCTAssertTrue(detached, "Detach is idempotent and releases only its own lease.")
        try f.capacity()
    }

    func testCancelledOlderServerFactoryDoesNotDiscardReplacementContext() async throws {
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
        var limits = PeerConnectionLimits()
        limits.handshakeSeconds = 5
        limits.exchange.operationSeconds = 5
        let runtime = try PeerServiceRuntime(
            configuration: .init(), coordinator: target, group: group, limits: limits)
        await runtime.refreshNow()
        await runtime.activate()
        defer { await runtime.close() }
        let pause = PeerLeasePause()
        let entered = expectation(description: "server factory acquired older lease")
        await runtime.setLogicalAttachedHookForTesting { await pause.wait(entered) }
        defer { await pause.release() }
        let listener = try await DaemonListeners.peer(
            group: group, host: "127.0.0.1", port: 0,
            initialize: { runtime.install(on: $0) })
        defer { try? await listener.close() }
        let resolver = PeerNameResolver(loop: group.next())
        defer { try? await resolver.close() }
        let port = try XCTUnwrap(listener.port)
        let pairing = try PeerPairing(credential: f.request.sourceCredential)
        // Mutual READY cannot complete while the old server factory is deliberately held.
        let older = Task {
            try await PeerConnector.connect(
                group: group, host: "127.0.0.1", port: port,
                pairing: pairing, coordinator: source, resolver: resolver, limits: limits)
        }
        await fulfillment(of: [entered], timeout: 5)
        let accepted = await runtime.connectionsForTesting()
        XCTAssertEqual(accepted.count, 1)
        let oldAccepted = try XCTUnwrap(accepted.first)
        older.cancel()
        do {
            _ = try await older.value
            XCTFail("Cancelled pending old connection completed")
        } catch {}
        // Close both owned transports before starting a new handshake budget. The old
        // factory still holds its suspended lease until release below, after new-page assertions.
        _ = try? await oldAccepted.close().get()
        try await oldAccepted.closed.get()
        let current = try await PeerConnector.connect(
            group: group, host: "127.0.0.1", port: port,
            pairing: pairing, coordinator: source, resolver: resolver, limits: limits)
        defer { try? await current.close().get() }
        let identity = try await current.request(.init("syncContext")).get()
        let scan = PeerExchangeRequest(
            "syncInventory", ["round": .text(UUID().uuidString.lowercased()), "ordinal": .integer(0)])
        let page = try await current.request(scan).get()
        await pause.release()
        // Old cancellation/error cleanup runs while the new socket owns the same registry entry.
        let replay = try await current.request(scan).get()
        let retainedIdentity = try await current.request(.init("syncContext")).get()
        XCTAssertEqual(replay, page)
        XCTAssertEqual(retainedIdentity, identity)
        try f.capacity()
    }

    private func canonicalFacts(_ root: URL) throws -> [String: String] {
        var facts: [String: String] = [:]
        var bytes = 0
        for directory in ["items", "authority/records"] {
            guard
                let scan = FileManager.default.enumerator(
                    at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in scan where ["tractanda", "authority"].contains(file.pathExtension) {
                let metadata = try FileMetadata.read(at: file)
                guard facts.count < 256, metadata.size <= UInt64(8 * 1024 * 1024 - bytes) else {
                    throw TractandaError("resourceLimit", "Tiny canonical facts estimate exceeded.")
                }
                let raw = try Data(contentsOf: file)
                bytes += raw.count
                let id: String
                let kind: String
                if file.pathExtension == "authority" {
                    let record = try AuthorityRecordCodec.decode(raw).record
                    id = record.recordID
                    kind = record.kind.rawValue
                } else {
                    id = try RecordCodec.decode(raw).revisionID
                    kind = "item"
                }
                facts[id] = kind + ":" + AuthorityRecordCodec.sha256(raw)
            }
        }
        return facts
    }

    func testFiniteJobsReconnectAcrossMorePagesThanOneSocketAndQuiesceWithoutNewPackages() async throws {
        var phase = "fixture"
        do {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            var revisions: [Revision] = []
            for index in 0..<4 {
                revisions.append(
                    try f.source.withAccess(forUID: f.accounts.human) {
                        try f.source.commit(
                            .init(
                                classID: "Item", changes: ["subject": .text("tail-\(index)")],
                                operationID: PeerServiceFixture.id())
                        ).revision
                    })
            }
            f.releaseWriter()
            let source = try await coordinator(f.sourceRoot, f.accounts)
            let target = try await coordinator(f.targetRoot, f.accounts)
            defer {
                await source.close()
                await target.close()
            }
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { try? await group.shutdownGracefully() }
            var transport = PeerConnectionLimits()
            transport.connectSeconds = 1
            transport.handshakeSeconds = 5
            // Three compatibility controls plus the original four ordinary requests.
            transport.exchange.maximumRequests = 7
            transport.exchange.maximumWireBytes = 256 * 1024
            transport.exchange.operationSeconds = 5
            transport.exchange.sessionSeconds = 20
            let responder = try PeerServiceRuntime(
                configuration: .init(), coordinator: target, group: group,
                limits: transport, logicalScanEntriesForTesting: 2)
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
            var observedWALCount = 0
            var maximumObservedWAL: UInt64 = 0
            func observeFixtureWALs() throws {
                for root in [f.sourceRoot, f.targetRoot] {
                    let path = root.appendingPathComponent("index/items.sqlite-wal")
                    if FileManager.default.fileExists(atPath: path.path) {
                        let bytes = try FileMetadata.read(at: path).size
                        observedWALCount += 1
                        maximumObservedWAL = max(maximumObservedWAL, bytes)
                    }
                }
            }
            let initiator = try PeerServiceRuntime(
                configuration: .init(peers: [.init(alias: "target", host: "127.0.0.1", port: port)]),
                coordinator: source, group: group, limits: transport)
            await initiator.activate()
            defer { await initiator.close() }
            var limits = PeerSyncLimits()
            limits.maximumRequests = 16
            limits.maximumPages = 2
            limits.maximumChunks = 1
            limits.maximumSeconds = 10
            let driver = try PeerSyncDriver(
                coordinator: source, binding: f.request.sourceCredential.binding, limits: limits)
            defer { await driver.close() }
            var created = 0
            var jobs = 0
            var rollovers = 0
            var complete = false
            for _ in 0..<256 {
                jobs += 1
                phase = "connect"
                let socket = try await initiator.connect(peerID: "target")
                let closeFlag = PeerSocketCloseFlag()
                socket.closed.whenComplete { _ in closeFlag.mark() }
                phase = "synchronize"
                let report = try await initiator.synchronize(peerID: "target", driver: driver)
                XCTAssertFalse(socket.isActive)
                let closedBeforeReturn = try await socket.closed.eventLoop.submit { closeFlag.value }.get()
                XCTAssertTrue(closedBeforeReturn)
                let remainingConnections = await initiator.connectionsForTesting()
                XCTAssertTrue(
                    remainingConnections.isEmpty,
                    "Finite synchronization must await actual close before releasing its slot.")
                created += report.packagesCreated
                rollovers += report.sessionRollovers
                // Force every fair yield through a real new TLS socket.
                await initiator.closeSynchronizationConnection(peerID: "target")
                try observeFixtureWALs()
                try f.capacity()
                if report.status == .complete {
                    complete = true
                    break
                }
                XCTAssertEqual(report.status, .yielded)
            }
            XCTAssertTrue(complete)
            XCTAssertGreaterThan(jobs, 2)
            XCTAssertGreaterThan(created, 0)
            XCTAssertGreaterThan(
                rollovers, 0, "Driver allowance must actually cross transport quota boundaries.")
            // Acceptance/visibility originals can be authored after the reverse finite cut.
            // Drain only genuinely unseen canonical roots before asserting a stable fresh epoch.
            var stabilized = false
            for _ in 0..<128 {
                let sourceBefore = try canonicalFacts(f.sourceRoot)
                let targetBefore = try canonicalFacts(f.targetRoot)
                phase = "connect"
                let socket = try await initiator.connect(peerID: "target")
                let closeFlag = PeerSocketCloseFlag()
                socket.closed.whenComplete { _ in closeFlag.mark() }
                phase = "synchronize"
                let report = try await initiator.synchronize(peerID: "target", driver: driver)
                XCTAssertFalse(socket.isActive)
                let closedBeforeReturn = try await socket.closed.eventLoop.submit { closeFlag.value }.get()
                XCTAssertTrue(closedBeforeReturn)
                let remainingConnections = await initiator.connectionsForTesting()
                XCTAssertTrue(
                    remainingConnections.isEmpty,
                    "Finite synchronization must await actual close before releasing its slot.")
                if report.packagesCreated > 0 {
                    XCTAssertEqual(
                        report.packagesCreated, 1,
                        "One bounded latest-root observation must account for every allocated package.")
                    let observed = await driver.createdRootsForTesting()
                    let created = try XCTUnwrap(observed)
                    let sender = created.direction == "outbound" ? sourceBefore : targetBefore
                    let receiver = created.direction == "outbound" ? targetBefore : sourceBefore
                    for id in created.roots {
                        XCTAssertNotNil(sender[id])
                        XCTAssertNil(
                            receiver[id],
                            "Already-known canonical root was repackaged: \(id), \(sender[id] ?? "missing")")
                    }
                }
                await initiator.closeSynchronizationConnection(peerID: "target")
                try observeFixtureWALs()
                let sourceAfter = try canonicalFacts(f.sourceRoot)
                let targetAfter = try canonicalFacts(f.targetRoot)
                if report.status == .complete, sourceAfter == targetAfter {
                    stabilized = true
                    break
                }
                XCTAssertNotEqual(report.status, .repairRequired)
            }
            XCTAssertTrue(stabilized)
            let stableSource = try canonicalFacts(f.sourceRoot)
            let stableTarget = try canonicalFacts(f.targetRoot)
            var quiet = false
            for _ in 0..<128 {
                phase = "connect"
                let socket = try await initiator.connect(peerID: "target")
                let closeFlag = PeerSocketCloseFlag()
                socket.closed.whenComplete { _ in closeFlag.mark() }
                phase = "synchronize"
                let report = try await initiator.synchronize(peerID: "target", driver: driver)
                XCTAssertFalse(socket.isActive)
                let closedBeforeReturn = try await socket.closed.eventLoop.submit { closeFlag.value }.get()
                XCTAssertTrue(closedBeforeReturn)
                let remainingConnections = await initiator.connectionsForTesting()
                XCTAssertTrue(
                    remainingConnections.isEmpty,
                    "Finite synchronization must await actual close before releasing its slot.")
                XCTAssertEqual(
                    report.packagesCreated, 0, "Unchanged complete bytes must not allocate duplicate exports."
                )
                await initiator.closeSynchronizationConnection(peerID: "target")
                try observeFixtureWALs()
                XCTAssertEqual(try canonicalFacts(f.sourceRoot), stableSource)
                XCTAssertEqual(try canonicalFacts(f.targetRoot), stableTarget)
                if report.status == .complete {
                    quiet = true
                    break
                }
                XCTAssertEqual(report.status, .yielded)
            }
            XCTAssertTrue(quiet)
            XCTAssertGreaterThan(observedWALCount, 0)
            print("Fixture writer WAL observations=\(observedWALCount), maxBytes=\(maximumObservedWAL)")
            await driver.close()
            await initiator.close()
            await responder.close()
            try? await listener.close()
            await source.close()
            await target.close()
            let reopened = try ItemStore.openInitialized(root: f.targetRoot, accounts: f.accounts)
            for revision in revisions {
                XCTAssertEqual(
                    try reopened.withAccess(forUID: f.accounts.human) { try reopened.get(revision.itemID) }
                        .revisionID,
                    revision.revisionID)
            }
            try f.capacity()
        } catch {
            let code: String
            if let known = error as? TractandaError {
                code = known.code
            } else if case .alreadyClosed? = error as? ChannelError {
                code = "alreadyClosed"
            } else {
                code = "untyped"
            }
            let safe =
                code.utf8.count <= 64
                    && code.utf8.allSatisfy({
                        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    }) ? code : "unclassified"
            print(
                "C1-RUNTIME-BOUNDARY phase=\(phase) code=\(safe) type=\(String(reflecting: type(of: error)))")
            throw error
        }
    }
}
