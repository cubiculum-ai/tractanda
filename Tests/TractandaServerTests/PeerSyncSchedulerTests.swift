import CTractandaPlatform
import Foundation
import NIOCore
import NIOPosix
import Synchronization
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

private final class CurrentSchedulerAccounts: AccountDirectory, @unchecked Sendable {
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

private struct CurrentSchedulerFixture {
    let roots: [URL]
    let replicas: [String]
    let credentials: [[PeerCredential]]
    let accounts: CurrentSchedulerAccounts
    init(root: URL) throws {
        // Four tiny current stores/full mesh credentials; no owned payloads or history scale.
        let policy: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("owner")]),
        ])
        let accounts = CurrentSchedulerAccounts()
        let roots = (0..<4).map { root.appendingPathComponent("n\($0)") }
        var stores: [ItemStore] = [
            try ItemStore.initializePersonalWorkgroup(
                root: roots[0], accounts: accounts, accessConfiguration: policy)
        ]
        let identity = try stores[0].personalSyncIdentity()
        for path in roots.dropFirst() {
            stores.append(
                try ItemStore.createPersonalSyncReplica(
                    root: path, storeID: identity.storeID, accessConfiguration: policy, accounts: accounts))
        }
        let replicas = try stores.map { try $0.personalSyncIdentity().replicaID }
        let config = try PersonalMembershipConfiguration(
            storeID: identity.storeID, configurationID: UUID.makeVersion1().uuidString.lowercased(),
            members: try replicas.enumerated().map {
                try .init(replicaID: $0.element, hostname: "n\($0.offset).fixture")
            })
        let nonce = try UUID.makeVersion1().uuidString.lowercased()
        let preparations = try stores.map {
            try $0.preparePersonalMembershipChange(configuration: config, expectedDigest: nil, nonce: nonce)
        }
        let digest = try config.digest
        var keys = [[PeerCredential]](repeating: [], count: 4)
        for first in 0..<4 {
            for second in (first + 1)..<4 {
                let pairing = try UUID.makeVersion1().uuidString.lowercased()
                for (local, remote) in [(first, second), (second, first)] {
                    let binding = try PeerExchangeBinding(
                        peerID: replicas[remote] + "-dial", storeID: identity.storeID,
                        localReplicaID: replicas[local], remoteReplicaID: replicas[remote],
                        pairingID: pairing, localIsInitiator: local > remote, configurationDigest: digest)
                    keys[local].append(
                        try PeerCredential(
                            binding: binding,
                            secret: [UInt8](repeating: UInt8(first * 4 + second + 1), count: 32)))
                }
            }
        }
        for index in 0..<4 {
            try stores[index].registerPersonalPeerCredentials(keys[index], configuration: config)
        }
        for index in 0..<4 {
            var acks: [PersonalMembershipOnlineAcknowledgement] = []
            for remote in 0..<4 where remote != index {
                let localKey = try XCTUnwrap(
                    keys[index].first { $0.binding.remoteReplicaID == replicas[remote] })
                let remoteKey = try XCTUnwrap(
                    keys[remote].first { $0.binding.remoteReplicaID == replicas[index] })
                let ready = try stores[remote].personalMembershipReady(
                    session: remoteKey.binding, preparation: preparations[index])
                acks.append(
                    try .init(binding: localKey.binding, response: ready, control: .commitCompletion()))
            }
            _ = try stores[index].commitPersonalMembershipChange(
                preparation: preparations[index], acknowledgements: acks)
            if index > 0 {
                _ = try stores[index].withAccess(forUID: tractanda_uid()) {
                    try stores[index].commit(
                        .init(
                            classID: "Item", changes: ["subject": .text("source-\(index)")],
                            operationID: "scheduler-source-\(index)"))
                }
            }
        }
        self.accounts = accounts
        self.roots = roots
        self.replicas = replicas
        credentials = keys
        try Self.capacity(root)
    }
    static func capacity(_ root: URL) throws {
        try PeerFixtureCapacity.requireFree(at: root)
        let scan = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var bytes: UInt64 = 0
        var entries = 0
        for case let file as URL in scan {
            entries += 1
            let info = try FileMetadata.read(at: file)
            guard entries <= 8192 else {
                throw TractandaError("resourceLimit", "Current scheduler fixture entry cap")
            }
            if info.type == .regular {
                let cap = PeerFixtureCapacity.fixtureCapBytes
                guard info.size <= cap - min(bytes, cap) else {
                    throw TractandaError("resourceLimit", "Current scheduler fixture byte cap")
                }
                bytes += info.size
            }
        }
    }
}

private actor CurrentSchedulerCuts {
    struct Entry: Sendable {
        let id: UUID
        let replica: String
        let revisions: Int
    }
    private var entries: [Entry] = []
    private var pending: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var holdEvery = false
    private var draining = false
    func completed(_ binding: PeerExchangeBinding, report: PersonalSyncReport) async {
        let hold = !draining && (entries.count < 2 || holdEvery)
        let entry = Entry(id: UUID(), replica: binding.remoteReplicaID, revisions: report.revisions)
        entries.append(entry)
        if hold {
            await withCheckedContinuation { pending[entry.id] = $0 }
        }
    }
    func log() -> [Entry] { entries }
    func held() -> Int { pending.count }
    func holdSubsequent() { holdEvery = true }
    func release(_ id: UUID) { pending.removeValue(forKey: id)?.resume() }
    func releaseAll() {
        draining = true
        let values = Array(pending.values)
        pending = [:]
        for value in values { value.resume() }
    }
}

private final class CurrentSchedulerConnections: Sendable {
    let values = Mutex<[PersonalPeerConnection]>([])
    func add(_ connection: PersonalPeerConnection) { values.withLock { $0.append(connection) } }
    var snapshot: [PersonalPeerConnection] { values.withLock { $0 } }
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

    func testCurrentPersonalRuntimeBoundsHeldPullsDrainsCloseAndRejectsOldCompletion() async throws {
        try PeerFixtureCapacity.requireFree()
        XCTAssertLessThanOrEqual(64 * 1024 * 1024, PeerFixtureCapacity.fixtureCapBytes)
        let root = try GuardedFixtureDirectory.create(
            prefix: "pq", source: "PeerSyncSchedulerTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try CurrentSchedulerFixture(root: root)
        let accounts = fixture.accounts
        var owners: [ServiceCoordinator] = []
        defer { for owner in owners { await owner.close() } }
        for path in fixture.roots {
            owners.append(
                try await ServiceCoordinator(
                    opening: path, embeddingProviderForTesting: nil, requireInitializedStore: true,
                    makeAccountDirectory: { accounts }))
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let settings = try PeerRuntimeConfiguration(
            synchronization: .init(enabled: true, intervalSeconds: 300))
        let runtime = try PersonalPeerRuntime(
            configuration: settings, configurationPath: root.appendingPathComponent("runtime.json").path,
            coordinator: owners[0], group: group)
        let cuts = CurrentSchedulerCuts()
        defer {
            await cuts.releaseAll()
            await runtime.close()
        }
        await runtime.setEnrollmentBridge(
            material: { .init() }, validate: { _, _ in }, handle: { _, _, _ in Data("{}".utf8) },
            completedCut: { binding, report in await cuts.completed(binding, report: report) })
        await runtime.refreshNow()
        await runtime.activate()
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            runtime.install(on: channel)
        }.bind(host: "127.0.0.1", port: 0).get()
        let clients = CurrentSchedulerConnections()
        defer {
            try? await listener.close().get()
            for connection in clients.snapshot { try? await connection.close().get() }
        }
        let port = try XCTUnwrap(listener.localAddress?.port)
        let currentOwners = owners
        let credentials = fixture.credentials
        let replicas = fixture.replicas
        @Sendable func connect(_ index: Int) async throws -> PersonalPeerConnection {
            let credential = try XCTUnwrap(
                credentials[index].first {
                    $0.binding.remoteReplicaID == replicas[0]
                })
            let pairing = try PeerPairing(credential: credential)
            let owner = currentOwners[index]
            let operations = PersonalPeerOperations(
                validate: { try await owner.personalPeerValidate($0) },
                handle: { try await owner.personalPeerRequest($0, request: $1) })
            let installed = CurrentSchedulerConnections()
            _ = try await ClientBootstrap(group: group).connectTimeout(.seconds(3))
                .channelInitializer { channel in
                    PersonalPeerConnection.install(on: channel, pairing: pairing, operations: operations)
                        .map {
                            installed.add($0)
                            clients.add($0)
                        }
                }.connect(host: "127.0.0.1", port: port).get()
            let connection = try XCTUnwrap(installed.snapshot.first)
            _ = try await connection.ready.get()
            return connection
        }
        let first = try await connect(1)
        let firstHeld = await waitUntil { await cuts.held() == 1 }
        XCTAssertTrue(firstHeld)
        _ = try await connect(2)
        let bothHeld = await waitUntil { await cuts.held() == 2 }
        XCTAssertTrue(bothHeld)
        _ = try await connect(3)
        let allConnected = await waitUntil {
            await runtime.hasConnectionForTesting(remoteReplicaID: replicas[3])
        }
        XCTAssertTrue(allConnected)
        for _ in 0..<3 { await runtime.tick() }
        let full = try await runtime.operatorStatus()
        XCTAssertEqual(full.synchronization.activeJobCount, 2)
        XCTAssertEqual(full.synchronization.eligibleEdgeCount, 3)
        let initial = await cuts.log()
        XCTAssertEqual(initial.count, 2, "Third eligible peer cannot bypass held lifetime owners")
        XCTAssertEqual(Set(initial.map(\.replica)), Set([replicas[1], replicas[2]]))
        let oldFirst = try XCTUnwrap(initial.first { $0.replica == replicas[1] })
        let oldSecond = try XCTUnwrap(initial.first { $0.replica == replicas[2] })
        XCTAssertEqual(oldFirst.revisions, 1)
        try await first.close().get()
        let removed = await waitUntil {
            !(await runtime.hasConnectionForTesting(remoteReplicaID: replicas[1]))
        }
        XCTAssertTrue(removed)
        await cuts.release(oldSecond.id)
        let oneHeld = await waitUntil {
            (try? await runtime.operatorStatus().synchronization.activeJobCount) == 1
        }
        XCTAssertTrue(oneHeld)
        _ = try await connect(1)
        let replacementFinished = await waitUntil {
            await runtime.completedCutsForTesting(remoteReplicaID: replicas[1]) == 2
        }
        XCTAssertTrue(replacementFinished)
        let replacementValue = await runtime.lastReportForTesting(remoteReplicaID: replicas[1])
        let replacement = try XCTUnwrap(replacementValue)
        XCTAssertEqual(replacement.revisions, 0, "Replacement resumes the exact already consumed finite cut")
        let replacementBytes = try JSON.encode(replacement)
        await cuts.release(oldFirst.id)
        let oldDrained = await waitUntil {
            (try? await runtime.operatorStatus().synchronization.activeJobCount) == 0
        }
        XCTAssertTrue(oldDrained)
        let afterOldValue = await runtime.lastReportForTesting(remoteReplicaID: replicas[1])
        let afterOld = try XCTUnwrap(afterOldValue)
        XCTAssertEqual(
            try JSON.encode(afterOld), replacementBytes,
            "Old suspended completion cannot publish its report over the replacement")
        let completed = await runtime.completedCutsForTesting(remoteReplicaID: replicas[1])
        XCTAssertEqual(completed, 2)
        let stillConnected = await runtime.hasConnectionForTesting(remoteReplicaID: replicas[1])
        XCTAssertTrue(stillConnected)
        // Hold two new actual completed cuts and prove close retains both lifetime slots
        // until the synchronous/callback owners return, even after cancellation/transport close.
        await cuts.holdSubsequent()
        for replica in replicas.dropFirst() { await runtime.requestPullForTesting(remoteReplicaID: replica) }
        await runtime.tick()
        let closingHeld = await waitUntil { await cuts.held() == 2 }
        XCTAssertTrue(closingHeld)
        let beforeClose = try await runtime.operatorStatus()
        XCTAssertEqual(beforeClose.synchronization.activeJobCount, 2)
        let closeProbe = PeerSyncSchedulerCloseProbe()
        let closing = Task {
            await runtime.close()
            await closeProbe.markClosed()
        }
        let stopped = await waitUntil { (try? await runtime.operatorStatus().state) == .stopped }
        XCTAssertTrue(stopped)
        let closedWhileHeld = await closeProbe.isClosed()
        XCTAssertFalse(closedWhileHeld, "Close returned while actual cut owners were still held")
        let duringClose = try await runtime.operatorStatus()
        XCTAssertEqual(duringClose.synchronization.activeJobCount, 2)
        await cuts.releaseAll()
        await closing.value
        let didClose = await closeProbe.isClosed()
        XCTAssertTrue(didClose)
        let closed = try await runtime.operatorStatus()
        XCTAssertEqual(closed.synchronization.activeJobCount, 0)
        let finalCount = await cuts.log().count
        await runtime.tick(now: ProcessInfo.processInfo.systemUptime + 10_000)
        let afterTickCount = await cuts.log().count
        XCTAssertEqual(afterTickCount, finalCount, "Closed runtime cannot start later work")
        try CurrentSchedulerFixture.capacity(root)
    }

}
