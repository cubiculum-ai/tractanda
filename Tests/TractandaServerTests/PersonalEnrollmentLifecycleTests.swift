import CTractandaPlatform
import Foundation
import NIOPosix
import TractandaClient
import XCTest

@testable import TractandaCore
@testable import TractandaServer

final class PersonalEnrollmentLifecycleTests: XCTestCase, @unchecked Sendable {
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == tractanda_uid() else { throw PersonalEnrollmentError.invalid() }
            return .init(uid: uid, name: "owner", primaryGroupName: "staff", groupIDs: [72001])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "owner" else { throw PersonalEnrollmentError.invalid() }
            return try user(forUID: tractanda_uid())
        }
        func groupID(named name: String) throws -> UInt32 { 72001 }
    }
    private final class Barrier: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CheckedContinuation<Void, Never>] = []
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return values.count
        }
        func enter() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                values.append(continuation)
                lock.unlock()
            }
        }
        func release() {
            lock.lock()
            let waiting = values
            values = []
            lock.unlock()
            for continuation in waiting { continuation.resume() }
        }
    }
    private func fixture(
        _ body: (PersonalEnrollmentRuntime, ServiceCoordinator, Barrier) async throws -> Void
    ) async throws {
        try PeerFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "enrollment-lifecycle-" + Identifier.make())
        try PrivateConfiguration.makeDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeRoot = root.appendingPathComponent("store")
        let accounts = Accounts()
        do {
            let store = try ItemStore.initializePersonalWorkgroup(
                root: storeRoot, accounts: accounts,
                accessConfiguration: .object([
                    "profile": .text(AccessConfiguration.profile), "users": .list([.text("owner")]),
                ]))
            _ = try store.personalEnrollmentIssue(
                forUID: tractanda_uid(), endpoints: [.init(host: "localhost", port: 48732)], now: 10_000)
        }
        let coordinator = try await ServiceCoordinator(opening: storeRoot, makeAccountDirectory: { accounts })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let runtime = try PersonalPeerRuntime(
            configuration: .init(), configurationPath: root.appendingPathComponent("unused.json").path,
            coordinator: coordinator, group: group)
        let owner = PersonalEnrollmentRuntime(coordinator: coordinator, runtime: runtime)
        let barrier = Barrier()
        await owner.setBeforeDriverStartForTesting { await barrier.enter() }
        do { try await body(owner, coordinator, barrier) } catch {
            barrier.release()
            await owner.beginClose()
            await runtime.close()
            await owner.finishClose()
            await coordinator.close()
            try? await group.shutdownGracefully()
            throw error
        }
        barrier.release()
        await owner.beginClose()
        await runtime.close()
        await owner.finishClose()
        await coordinator.close()
        try await group.shutdownGracefully()
    }
    private func waitForArrivals(_ count: Int, barrier: Barrier) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 2
        while barrier.count < count && ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(barrier.count, count)
    }
    private func request() throws -> Data {
        try JMAPValue.object([
            .init("using", .array([.string(NativePersonalEnrollment.capability)])),
            .init(
                "methodCalls",
                .array([
                    JMAPInvocation(
                        name: "TractandaEnrollmentLocal/resume", arguments: .object([]), callID: "resume"
                    ).value
                ])),
        ]).encoded()
    }
    func testConcurrentResumeCreatesOneDaemonDriver() async throws {
        try await fixture { owner, coordinator, barrier in
            let data = try request()
            let pin = NativePrincipalPin(
                try await coordinator.localJMAPAuthentication(forUID: tractanda_uid()))
            async let first = owner.native(data, forUID: tractanda_uid(), principal: pin)
            async let second = owner.native(data, forUID: tractanda_uid(), principal: pin)
            try await waitForArrivals(2, barrier: barrier)
            barrier.release()
            _ = try await (first, second)
            let starts = await owner.driverStartsForTesting()
            XCTAssertEqual(starts, 1)
        }
    }
    func testShutdownDuringStateReadCannotStartDriverAfterClose() async throws {
        try await fixture { owner, coordinator, barrier in
            let data = try request()
            let pin = NativePrincipalPin(
                try await coordinator.localJMAPAuthentication(forUID: tractanda_uid()))
            async let pending = owner.native(data, forUID: tractanda_uid(), principal: pin)
            try await waitForArrivals(1, barrier: barrier)
            await owner.beginClose()
            barrier.release()
            _ = try await pending
            let starts = await owner.driverStartsForTesting()
            XCTAssertEqual(starts, 0)
        }
    }
    private func recoveryBinding() throws -> PeerExchangeBinding {
        func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        return try .init(
            peerID: "retained-continuation", storeID: id(), localReplicaID: id(),
            remoteReplicaID: id(), pairingID: id(), localIsInitiator: true,
            configurationDigest: String(repeating: "a", count: 64))
    }
    func testRetainedRecoveryCancelsAndReapsBlockedRenewalWithoutCachedSession() async throws {
        let binding = try recoveryBinding()
        let entered = expectation(description: "probe entered")
        let reaped = expectation(description: "probe reaped")
        let result = try await PersonalEnrollmentRuntime.raceRenewalRecovery(
            retained: [
                {
                    await self.fulfillment(of: [entered], timeout: 2)
                    return .continuation(binding)
                }
            ],
            probe: {
                entered.fulfill()
                defer { reaped.fulfill() }
                try await Task.sleep(for: .seconds(3600))
                return .claimSent
            })
        guard case .continuation(let actual) = result else {
            return XCTFail("Accepted retained continuation did not win.")
        }
        XCTAssertEqual(actual, binding)
        await fulfillment(of: [reaped], timeout: 2)
    }
    func testActualRetainedReplyWinsDuringRenewalCancellationDrain() async throws {
        let binding = try recoveryBinding()
        let entered = expectation(description: "retained request entered")
        let result = try await PersonalEnrollmentRuntime.raceRenewalRecovery(
            retained: [
                {
                    entered.fulfill()
                    do { try await Task.sleep(for: .seconds(3600)) } catch {
                        // Models an already delivered authenticated reply.
                    }
                    return .continuation(binding)
                }
            ],
            probe: {
                await self.fulfillment(of: [entered], timeout: 2)
                return .claimSent
            })
        guard case .continuation(let actual) = result else {
            return XCTFail("Actual continuation reply lost precedence.")
        }
        XCTAssertEqual(actual, binding)
    }
    func testNativeStatusFamilyPinRefusesAnUnrelatedCurrentOperation() async throws {
        try await fixture { owner, coordinator, _ in
            let state = try await coordinator.personalEnrollmentHostState()
            let family = try XCTUnwrap(state.sourceJob?.invitation.familyID)
            let pin = NativePrincipalPin(
                try await coordinator.localJMAPAuthentication(forUID: tractanda_uid()))
            func request(_ family: String) throws -> Data {
                try JMAPValue.object([
                    .init("using", .array([.string(NativePersonalEnrollment.capability)])),
                    .init(
                        "methodCalls",
                        .array([
                            JMAPInvocation(
                                name: "TractandaEnrollmentLocal/status",
                                arguments: .object([.init("familyID", .string(family))]), callID: "family"
                            ).value
                        ])),
                ]).encoded()
            }
            let accepted = try await owner.native(request(family), forUID: tractanda_uid(), principal: pin)
            let summary = try NativeMethodResult.unwrap(
                accepted, method: "TractandaEnrollmentLocal/status", callID: "family")
            XCTAssertEqual(try JMAPValue.decode(summary)["familyID"]?.text, family)
            let unrelated = try UUID.makeVersion1().uuidString.lowercased()
            let rejected = try await owner.native(request(unrelated), forUID: tractanda_uid(), principal: pin)
            XCTAssertThrowsError(
                try NativeMethodResult.unwrap(
                    rejected, method: "TractandaEnrollmentLocal/status", callID: "family")
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "enrollmentConflict")
            }
        }
    }
}
