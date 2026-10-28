import XCTest

@testable import TractandaCore

final class PeerClockRuntimeTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private let config = PeerClockHealth.Configuration(minimumInterval: 4, maximumInterval: 4)

    private final class PersonalFixture {
        let directory: URL
        let root: URL
        let accounts = PeerIntakeStoreTests.Accounts()
        let identity: PersonalSyncIdentity
        let membership: PersonalMembershipConfiguration

        init(test: String, configureMembership: Bool = true) throws {
            try AttachmentFixtureCapacity.requireFree()
            directory =
                try GuardedFixtureDirectory.parent().appendingPathComponent(
                    "tractanda-peer-clock-" + UUID.makeVersion1().uuidString.lowercased())
            root = directory.appendingPathComponent("store")
            let store = try ItemStore.initializeFresh(
                root: root, accounts: accounts,
                initialAccessConfiguration: .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("admin"), .text("alice"), .text("bob")]),
                ]), initializationKey: "peer-clock-\(test)")
            identity = try store.personalSyncIdentity()
            let remoteID = try UUID.makeVersion1().uuidString.lowercased()
            membership = try PersonalMembershipConfiguration(
                storeID: identity.storeID, configurationID: UUID.makeVersion1().uuidString.lowercased(),
                members: [
                    try .init(replicaID: identity.replicaID, hostname: "local.fixture"),
                    try .init(replicaID: remoteID, hostname: "other.fixture"),
                ])
            if configureMembership { try setMembership(membership) }
            try capacity()
        }

        func setMembership(_ value: PersonalMembershipConfiguration) throws {
            try PersonalSyncConfiguration.write(
                value, root: root, name: PersonalSyncConfiguration.membershipName)
        }

        func capacity() throws {
            try AttachmentFixtureCapacity.requireFree(at: directory)
            var bytes: UInt64 = 0
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            while let file = enumerator.nextObject() as? URL {
                let metadata = try FileMetadata.read(at: file)
                if metadata.type == .regular {
                    guard bytes <= AttachmentFixtureCapacity.fixtureCapBytes,
                        metadata.size <= AttachmentFixtureCapacity.fixtureCapBytes - bytes
                    else { throw TractandaError("resourceLimit", "Fixture cap") }
                    bytes += metadata.size
                }
            }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func waitUntilPersonalClockIsReady(_ coordinator: ServiceCoordinator) async throws {
        for _ in 0..<1_000 {
            _ = try await coordinator.preparePeerClockSample(
                monotonicNow: 100, interval: 4, configuration: config)
            if try await coordinator.peerClockHealthForTesting() != nil { return }
            await Task.yield()
        }
        XCTFail("Personal peer clock did not become ready after startup recovery.")
    }

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
        let f = try PersonalFixture(test: "coordinator-single-lease")
        let coordinator = try await ServiceCoordinator(
            opening: f.root, embeddingProviderForTesting: nil, requireInitializedStore: true,
            revisionProjectionEnabledForTesting: true,
            makeAccountDirectory: { PeerIntakeStoreTests.Accounts() })
        try await waitUntilPersonalClockIsReady(coordinator)
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

        try f.capacity()
        let ordinary = try PersonalFixture(test: "coordinator-default-off", configureMembership: false)
        let disabled = try await ServiceCoordinator(
            opening: ordinary.root, makeAccountDirectory: { PeerIntakeStoreTests.Accounts() })
        let dormant = try await disabled.preparePeerClockSample(
            monotonicNow: 1_000, interval: 4, configuration: config)
        XCTAssertNil(dormant)
        let untouched = try await disabled.peerClockHealthForTesting()
        XCTAssertNil(untouched)
        await disabled.close()
        try ordinary.capacity()
    }

    func testActiveCanonicalVerificationDefersDueProbe() async throws {
        let f = try PersonalFixture(test: "canonical-verification-deferral")
        let coordinator = try await ServiceCoordinator(
            opening: f.root, embeddingProviderForTesting: nil, requireInitializedStore: true,
            revisionProjectionEnabledForTesting: true,
            makeAccountDirectory: { PeerIntakeStoreTests.Accounts() })
        try await waitUntilPersonalClockIsReady(coordinator)
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
        let untouched = try XCTUnwrap(health)
        XCTAssertEqual(untouched.assessment, .unknown)
        XCTAssertEqual(untouched.lastAttempt, .none)
        await gate.release()
        await coordinator.close()
        try f.capacity()
    }

    func testMembershipChangeAndLocalRemovalInvalidatePendingSample() async throws {
        let f = try PersonalFixture(test: "stale-membership-sample")
        let coordinator = try await ServiceCoordinator(
            opening: f.root, embeddingProviderForTesting: nil, requireInitializedStore: true,
            revisionProjectionEnabledForTesting: true,
            makeAccountDirectory: { PeerIntakeStoreTests.Accounts() })
        try await waitUntilPersonalClockIsReady(coordinator)

        let originalValue = try await coordinator.preparePeerClockSample(
            monotonicNow: 104, interval: 4, configuration: config)
        let original = try XCTUnwrap(originalValue)
        let changed = try PersonalMembershipConfiguration(
            storeID: f.identity.storeID, configurationID: UUID.makeVersion1().uuidString.lowercased(),
            members: f.membership.members)
        try f.setMembership(changed)
        try await coordinator.finishPeerClockSample(
            original, sample: .init(offset: 8, uncertainty: 1), monotonicNow: 104, nextInterval: 4)
        let afterChange = try await coordinator.peerClockHealthForTesting()
        XCTAssertEqual(afterChange?.assessment, .unknown)

        let pendingValue = try await coordinator.preparePeerClockSample(
            monotonicNow: 104, interval: 4, configuration: config)
        let pending = try XCTUnwrap(pendingValue)
        let remote = try XCTUnwrap(changed.members.first { $0.replicaID != f.identity.replicaID })
        let withoutLocal = try PersonalMembershipConfiguration(
            storeID: f.identity.storeID, configurationID: UUID.makeVersion1().uuidString.lowercased(),
            members: [
                remote,
                try .init(
                    replicaID: UUID.makeVersion1().uuidString.lowercased(), hostname: "third.fixture"),
            ])
        try f.setMembership(withoutLocal)
        try await coordinator.finishPeerClockSample(
            pending, sample: .init(offset: 9, uncertainty: 1), monotonicNow: 104, nextInterval: 4)
        let health = try await coordinator.peerClockHealthForTesting()
        XCTAssertEqual(try XCTUnwrap(health).assessment, .unknown)
        XCTAssertTrue(try XCTUnwrap(health).permitsRetirement)
        let disabledAfterRemoval = try await coordinator.preparePeerClockSample(
            monotonicNow: 108, interval: 4, configuration: config)
        XCTAssertNil(disabledAfterRemoval)
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
