import Foundation
import NIOPosix
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport
@testable import TractandaServer

private actor PeerSyncSchedulerGate {
    struct Call: Sendable {
        let id: UUID
        let peerID: String
        let securityToken: String
    }

    private var calls: [Call] = []
    private var pending: [UUID: CheckedContinuation<PeerSyncDriver.Report, Never>] = [:]
    private var cancelled = Set<UUID>()
    private var overflowCount = 0
    private var shuttingDown = false

    func hold(peerID: String, snapshot: PeerRuntimeSnapshot) async throws -> PeerSyncDriver.Report {
        if shuttingDown { return .init() }
        guard calls.count < 32, pending.count < 2 else {
            overflowCount += 1
            throw TractandaError("resourceLimit", "Scheduler test gate bound exceeded.")
        }
        let id = UUID()
        let report = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                calls.append(.init(id: id, peerID: peerID, securityToken: snapshot.securityToken))
                pending[id] = continuation
            }
        } onCancel: {
            Task { await self.noteCancellation(id) }
        }
        try Task.checkCancellation()
        return report
    }

    private func noteCancellation(_ id: UUID) { cancelled.insert(id) }
    func callLog() -> [Call] { calls }
    func cancellationCount() -> Int { cancelled.count }
    func overflows() -> Int { overflowCount }
    func release(_ id: UUID, with report: PeerSyncDriver.Report) {
        pending.removeValue(forKey: id)?.resume(returning: report)
    }
    func releaseAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(returning: .init()) }
    }
    func shutdown() {
        shuttingDown = true
        releaseAll()
    }
}

private actor PeerSyncSchedulerCloseProbe {
    private var closed = false
    func markClosed() { closed = true }
    func isClosed() -> Bool { closed }
}

final class PeerSyncSchedulerTests: XCTestCase {
    private func waitUntil(
        attempts: Int = 250,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func yieldedReport(marker: Int) -> PeerSyncDriver.Report {
        var report = PeerSyncDriver.Report()
        report.status = .yielded
        report.packagesCreated = marker
        return report
    }

    private func call(
        at index: Int, in calls: [PeerSyncSchedulerGate.Call], file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PeerSyncSchedulerGate.Call {
        try XCTUnwrap(
            calls.indices.contains(index) ? calls[index] : nil,
            "Expected scheduler call at bounded index \(index).", file: file, line: line)
    }

    func testBoundedFairSchedulingReplacementAndDrainedClose() async throws {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "q", source: "PeerSyncSchedulerTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try PeerServiceFixture(root: root)
        defer { fixture.releaseWriter() }
        let original = fixture.request.sourceCredential.binding

        // Register three distinct source-initiator pairings to the already admitted target.
        // The scheduler test never opens a socket or fabricates a snapshot or trust record.
        try fixture.source.withAccess(forUID: fixture.accounts.human) {
            for (index, alias) in ["edge-a", "edge-b", "edge-c"].enumerated() {
                let digest = AuthorityRecordCodec.sha256(Data(("scheduler-" + alias).utf8))
                let binding = try PeerExchangeBinding(
                    peerID: alias, storeID: original.storeID,
                    localReplicaID: original.localReplicaID, remoteReplicaID: original.remoteReplicaID,
                    pairingID: PeerServiceFixture.id(), localIsInitiator: true,
                    configurationDigest: digest)
                let credential = try PeerCredential(
                    binding: binding,
                    secret: [UInt8](repeating: UInt8(index + 1), count: 32))
                let context = try PeerPackage.Context(
                    peerID: alias, storeID: binding.storeID,
                    configurationDigest: digest, permittedOrigins: [binding.remoteReplicaID])
                try fixture.source.registerPeerCredential(
                    credential, context: context,
                    expectedContextToken: fixture.source.peerIntakeContextToken(),
                    operationID: PeerServiceFixture.id())
            }
        }
        fixture.releaseWriter()

        let accounts = fixture.accounts
        let coordinator = try await ServiceCoordinator(
            opening: fixture.sourceRoot,
            embeddingProviderForTesting: nil, requireInitializedStore: true,
            makeAccountDirectory: { accounts })
        defer { await coordinator.close() }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let gate = PeerSyncSchedulerGate()
        let peers = try ["edge-a", "edge-b", "edge-c"].map {
            try PeerRuntimeConfiguration.Peer(alias: $0, host: "127.0.0.1", port: 1)
        }
        let synchronization = try PeerRuntimeConfiguration.Synchronization(enabled: true, intervalSeconds: 15)
        let configuration = try PeerRuntimeConfiguration(peers: peers, synchronization: synchronization)
        let network = try PeerServiceRuntime(
            configuration: configuration, coordinator: coordinator, group: group)
        defer { await network.close() }
        let runtime = try PeerSyncRuntime(
            configuration: configuration, coordinator: coordinator, network: network,
            synchronizeForTesting: { peerID, snapshot in
                try await gate.hold(peerID: peerID, snapshot: snapshot)
            })
        defer {
            await gate.shutdown()
            await runtime.close()
        }
        let closeProbe = PeerSyncSchedulerCloseProbe()

        let base = ProcessInfo.processInfo.systemUptime + 1
        await runtime.activate()
        await runtime.tick(now: base)

        let firstTwoStarted = await waitUntil {
            await gate.callLog().count == 2
        }
        XCTAssertTrue(firstTwoStarted, "Two finite jobs should start after the real snapshot refresh.")
        var calls = await gate.callLog()
        XCTAssertEqual(Set(calls.map(\.peerID)), Set(["edge-a", "edge-b"]))
        let firstCall = try XCTUnwrap(calls.first { $0.peerID == "edge-a" })
        let secondCall = try XCTUnwrap(calls.first { $0.peerID == "edge-b" })
        let initialActiveJobs = await runtime.activeJobsForTesting()
        let initialMaximumJobs = await runtime.maximumObservedJobs
        XCTAssertEqual(initialActiveJobs, 2)
        XCTAssertEqual(initialMaximumJobs, 2)

        for offset in 1...4 { await runtime.tick(now: base + Double(offset)) }
        try await Task.sleep(for: .milliseconds(40))
        let heldCallCount = await gate.callLog().count
        XCTAssertEqual(
            heldCallCount, 2,
            "Held jobs occupy both slots; repeated ticks cannot start the third edge.")

        await gate.release(firstCall.id, with: yieldedReport(marker: 41))
        let thirdStarted = await waitUntil { await gate.callLog().count == 3 }
        XCTAssertTrue(thirdStarted, "The unserved edge should use the freed slot before edge-a repeats.")
        calls = await gate.callLog()
        XCTAssertEqual(Set(calls.prefix(2).map(\.peerID)), Set(["edge-a", "edge-b"]))
        XCTAssertEqual(calls.last?.peerID, "edge-c")

        let thirdCall = try call(at: 2, in: calls)
        await gate.release(thirdCall.id, with: PeerSyncDriver.Report())
        let oneJobRemains = await waitUntil {
            await runtime.activeJobsForTesting() == 1
        }
        XCTAssertTrue(oneJobRemains)
        await runtime.tick(now: base + 5)
        let edgeARescheduled = await waitUntil { await gate.callLog().count == 4 }
        XCTAssertTrue(edgeARescheduled)
        calls = await gate.callLog()
        let fourthCall = try call(at: 3, in: calls)
        XCTAssertEqual(fourthCall.peerID, "edge-a")

        // Replacing one real credential changes the current snapshot and retires the old edge set.
        let oldA = try await coordinator.loadPeerCredential(peerID: "edge-a")
        let oldBinding = oldA.binding
        let rotatedDigest = AuthorityRecordCodec.sha256(Data("scheduler-edge-a-rotated".utf8))
        let rotatedBinding = try PeerExchangeBinding(
            peerID: oldBinding.peerID, storeID: oldBinding.storeID,
            localReplicaID: oldBinding.localReplicaID, remoteReplicaID: oldBinding.remoteReplicaID,
            pairingID: oldBinding.pairingID, localIsInitiator: true,
            configurationDigest: rotatedDigest)
        let rotated = try PeerCredential(binding: rotatedBinding, secret: [UInt8](repeating: 9, count: 32))
        let registrationContext = try await coordinator.peerCredentialRegistrationContext(
            forUID: fixture.accounts.human)
        try await coordinator.registerPeerCredential(
            rotated, permittedOrigins: [rotatedBinding.remoteReplicaID],
            expectedContextToken: registrationContext, operationID: PeerServiceFixture.id(),
            forUID: fixture.accounts.human)

        await runtime.tick(now: base + 6)
        let oldJobsCancelled = await waitUntil {
            await gate.cancellationCount() == 2
        }
        XCTAssertTrue(oldJobsCancelled, "Snapshot replacement cancels both outstanding old jobs.")
        let cancelledJobsStillOccupySlots = await runtime.activeJobsForTesting()
        let callsBeforeOldReturn = await gate.callLog().count
        XCTAssertEqual(
            cancelledJobsStillOccupySlots, 2,
            "A cancelled job retains its slot until its synchronization call actually returns.")
        XCTAssertEqual(
            callsBeforeOldReturn, 4,
            "Replacement edges cannot start while cancelled old calls still occupy both slots.")

        // Return stale success-shaped results. Edge identity and cancellation must prevent publication.
        await gate.release(secondCall.id, with: yieldedReport(marker: 82))
        await gate.release(fourthCall.id, with: yieldedReport(marker: 83))
        let replacementCallsStarted = await waitUntil { await gate.callLog().count == 6 }
        XCTAssertTrue(replacementCallsStarted)
        let replacementReports = await runtime.reportsForTesting()
        XCTAssertTrue(
            replacementReports.isEmpty,
            "Neither stale completion may populate a report on a replacement edge.")
        calls = await gate.callLog()
        let replacementCall = try call(at: 4, in: calls)
        XCTAssertNotEqual(replacementCall.securityToken, firstCall.securityToken)
        let replacementActiveJobs = await runtime.activeJobsForTesting()
        XCTAssertEqual(replacementActiveJobs, 2)

        let closeTask = Task {
            await runtime.close()
            await closeProbe.markClosed()
        }
        let replacementsCancelled = await waitUntil { await gate.cancellationCount() == 4 }
        XCTAssertTrue(replacementsCancelled)
        let closedBeforeRelease = await closeProbe.isClosed()
        let activeWhileClosing = await runtime.activeJobsForTesting()
        XCTAssertFalse(closedBeforeRelease, "Close must wait for held synchronization calls to finish.")
        XCTAssertEqual(activeWhileClosing, 2)
        let startCountAtClose = (await gate.callLog()).count
        await gate.releaseAll()
        await closeTask.value
        let didClose = await closeProbe.isClosed()
        let activeAfterClose = await runtime.activeJobsForTesting()
        XCTAssertTrue(didClose)
        XCTAssertEqual(activeAfterClose, 0)
        await runtime.tick(now: base + 10_000)
        let startsAfterClose = await gate.callLog().count
        XCTAssertEqual(
            startsAfterClose, startCountAtClose,
            "A closed scheduler starts no later work.")
        let maximumObservedJobs = await runtime.maximumObservedJobs
        XCTAssertEqual(maximumObservedJobs, 2)
        let gateOverflows = await gate.overflows()
        XCTAssertEqual(gateOverflows, 0)
        try fixture.capacity()
    }
}
