import XCTest

@testable import TractandaCore

final class PeerClockRuntimeTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private let config = PeerClockHealth.Configuration(minimumInterval: 4, maximumInterval: 4)

    func testActualStoreEligibilityAndHealthLatchAcrossUnavailableAndInconclusive() throws {
        let f = try Fixture()
        try f.bootstrap()
        // Enabled alone is insufficient: the source has no configured peers.
        XCTAssertNil(
            try f.source.preparePeerClockSample(monotonicNow: 100, interval: 4, configuration: config))
        XCTAssertNil(f.source.peerClockHealth)
        XCTAssertNil(
            try f.receiver.preparePeerClockSample(monotonicNow: 100, interval: 4, configuration: config))
        let due = try XCTUnwrap(
            f.receiver.preparePeerClockSample(monotonicNow: 104, interval: 4, configuration: config))
        try f.receiver.finishPeerClockSample(
            context: due.0, sample: .init(offset: 8, uncertainty: 1), monotonicNow: 104, nextInterval: 4)
        XCTAssertFalse(try XCTUnwrap(f.receiver.peerClockHealth).permitsRetirement)
        try f.receiver.finishPeerClockSample(context: due.0, sample: nil, monotonicNow: 108, nextInterval: 4)
        XCTAssertFalse(try XCTUnwrap(f.receiver.peerClockHealth).permitsRetirement)
        try f.receiver.finishPeerClockSample(
            context: due.0, sample: .init(offset: 7, uncertainty: 2), monotonicNow: 112, nextInterval: 4)
        XCTAssertFalse(try XCTUnwrap(f.receiver.peerClockHealth).permitsRetirement)
        try f.receiver.finishPeerClockSample(
            context: "stale", sample: .init(offset: 0, uncertainty: 0.1), monotonicNow: 116, nextInterval: 4)
        XCTAssertFalse(try XCTUnwrap(f.receiver.peerClockHealth).permitsRetirement)
        try f.receiver.finishPeerClockSample(
            context: due.0, sample: .init(offset: 0, uncertainty: 0.1), monotonicNow: 116, nextInterval: 4)
        XCTAssertTrue(try XCTUnwrap(f.receiver.peerClockHealth).permitsRetirement)
        try f.capacity()
    }

    func testCoordinatorSingleLeaseShutdownFenceAndDefaultOff() async throws {
        let f = try Fixture()
        try f.bootstrap()
        f.receiver = nil
        let coordinator = try await ServiceCoordinator(
            opening: f.receiverRoot, embeddingProviderForTesting: nil, requireInitializedStore: true,
            revisionProjectionEnabledForTesting: true, authorityIntakeEnabledForTesting: true,
            makeAccountDirectory: { PeerIntakeStoreTests.Accounts() })
        // Startup recovery must finish before scheduling; yielding is bounded and needs no timer.
        for _ in 0..<1_000 {
            _ = try await coordinator.preparePeerClockSample(
                monotonicNow: 100, interval: 4, configuration: config)
            if try await coordinator.peerClockHealthForTesting() != nil { break }
            await Task.yield()
        }
        let leaseValue = try await coordinator.preparePeerClockSample(
            monotonicNow: 104, interval: 4, configuration: config)
        let lease = try XCTUnwrap(leaseValue)
        let duplicate = try await coordinator.preparePeerClockSample(
            monotonicNow: 104, interval: 4, configuration: config)
        XCTAssertNil(duplicate)
        try await coordinator.finishPeerClockSample(
            lease, sample: .init(offset: 8, uncertainty: 1), monotonicNow: 104, nextInterval: 4)
        let nextValue = try await coordinator.preparePeerClockSample(
            monotonicNow: 108, interval: 4, configuration: config)
        let next = try XCTUnwrap(nextValue)
        await coordinator.requestBackgroundStop()
        try await coordinator.finishPeerClockSample(
            next, sample: .init(offset: 0, uncertainty: 0.1), monotonicNow: 108, nextInterval: 4)
        let health = try await coordinator.peerClockHealthForTesting()
        XCTAssertFalse(try XCTUnwrap(health).permitsRetirement)
        await coordinator.close()

        // The two-store fixture estimates16MiB; one empty ordinary store adds at most8MiB.
        // Check genuine capacity again before this bounded extra fixture, retaining the32MiB cap.
        try f.capacity()
        _ = try ItemStore.initializeFresh(
            root: f.directory.appendingPathComponent("ordinary"),
            accounts: PeerIntakeStoreTests.Accounts())
        let disabled = try await ServiceCoordinator(
            opening: f.directory.appendingPathComponent("ordinary"),
            makeAccountDirectory: { PeerIntakeStoreTests.Accounts() })
        let dormant = try await disabled.preparePeerClockSample(
            monotonicNow: 1_000, interval: 4, configuration: config)
        XCTAssertNil(dormant)
        let untouched = try await disabled.peerClockHealthForTesting()
        XCTAssertNil(untouched)
        await disabled.close()
        try f.capacity()
    }

    func testActiveCanonicalVerificationDefersDueProbe() async throws {
        let f = try Fixture()
        try f.bootstrap()
        f.receiver = nil
        let coordinator = try await ServiceCoordinator(
            opening: f.receiverRoot, embeddingProviderForTesting: nil, requireInitializedStore: true,
            revisionProjectionEnabledForTesting: true, authorityIntakeEnabledForTesting: true,
            makeAccountDirectory: { PeerIntakeStoreTests.Accounts() })
        let entered = expectation(description: "canonical scan active")
        let gate = Gate()
        await coordinator.setVerificationScanHookForTesting {
            entered.fulfill()
            await gate.wait()
        }
        await coordinator.startCanonicalVerification()
        await fulfillment(of: [entered], timeout: 3)
        let busy = try await coordinator.preparePeerClockSample(
            monotonicNow: 104, interval: 4, configuration: config)
        XCTAssertNil(busy)
        let health = try await coordinator.peerClockHealthForTesting()
        XCTAssertNil(health)
        await gate.release()
        await coordinator.close()
        try f.capacity()
    }

    private actor Gate {
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if !released { await withCheckedContinuation { waiter = $0 } }
        }
        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }
}
