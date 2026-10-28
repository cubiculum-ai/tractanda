import CTractandaPlatform
import Foundation
import NIOCore
import NIOPosix
import Synchronization
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport
@testable import TractandaServer

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PersonalPeerDaemonTests: XCTestCase, @unchecked Sendable {
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == tractanda_uid() else {
                throw TractandaError("unresolvedPrincipal", "Fixture user missing.")
            }
            return .init(uid: uid, name: "owner", primaryGroupName: "staff", groupIDs: [72001])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "owner" else {
                throw TractandaError("unresolvedPrincipal", "Fixture user missing.")
            }
            return try user(forUID: tractanda_uid())
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Fixture group missing.")
            }
            return 72001
        }
    }
    private actor ProgressCapture {
        var value: PersonalPullProgress?
        var delivery: (@Sendable (PersonalPullProgress) async -> Void)?
        func record(
            _ value: PersonalPullProgress, delivery: (@Sendable (PersonalPullProgress) async -> Void)?
        ) {
            if self.value == nil {
                self.value = value
                self.delivery = delivery
            }
        }
        func captured() -> (PersonalPullProgress?, (@Sendable (PersonalPullProgress) async -> Void)?) {
            (value, delivery)
        }
    }
    private actor CutCapture {
        private var values: [PersonalSyncReport] = []
        func record(_ report: PersonalSyncReport) { values.append(report) }
        func snapshot() -> [PersonalSyncReport] { values }
    }
    private actor ChunkProgress {
        private var first: (PersonalObjectDescriptor, Int64)?
        func record(_ descriptor: PersonalObjectDescriptor, offset: Int64) -> Bool {
            guard first == nil else { return false }
            first = (descriptor, offset)
            return true
        }
        func snapshot() -> (PersonalObjectDescriptor, Int64)? { first }
    }
    private var activeFixtureRoot: URL?
    private func capacity() throws {
        guard let root = activeFixtureRoot else { return }
        try PeerFixtureCapacity.requireFree(at: root)
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw TractandaError("resourceLimit", "Cannot measure personal daemon fixture.")
        }
        var bytes: UInt64 = 0
        for case let file as URL in entries {
            let metadata: FileMetadata
            do { metadata = try FileMetadata.read(at: file) } catch FileMetadataError.posix(let code)
                where code == ENOENT
            { continue }
            if metadata.type == .regular {
                guard metadata.size <= PeerFixtureCapacity.fixtureCapBytes - bytes else {
                    throw TractandaError("resourceLimit", "Personal daemon fixture crossed128MiB cap.")
                }
                bytes += metadata.size
            }
        }
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func unusedPort() async throws -> Int {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let listener = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(listener.localAddress?.port)
        try await listener.close().get()
        return port
    }
    private func eventually(_ description: String, _ condition: () async throws -> Bool) async throws {
        let seconds =
            Double(
                ProcessInfo.processInfo.environment["TRACTANDA_PERSONAL_DAEMON_TEST_WAIT_SECONDS"] ?? "300")
            ?? 300
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            try capacity()
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TractandaError("fixtureWait", description)
    }
    private func admin(_ socket: String, _ operation: String, _ fields: [String: ItemValue] = [:])
        async throws -> Data
    {
        let bytes = try JSON.encode(PeerExchangeRequest(operation, fields))
        return try await Task.detached {
            let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            return try ItemClient(socketPath: socket).call(
                "TractandaPeerPersonal/admin", arguments: arguments)
        }.value
    }
    private func item(_ socket: String, _ itemID: String) async throws -> Revision {
        try await Task.detached { try ItemClient(socketPath: socket).revision(for: itemID) }.value
    }

    func testConfiguredSourceWithoutMembershipStartsAndPreparesRegistersWhileServing() async throws {
        // Two tiny factory stores, one ordinary item and four small key files: below16MiB.
        try PeerFixtureCapacity.requireFree(at: FileManager.default.temporaryDirectory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tes-" + String(UUID().uuidString.prefix(8)))
        try PrivateConfiguration.makeDirectory(root)
        activeFixtureRoot = root
        defer {
            activeFixtureRoot = nil
            try? FileManager.default.removeItem(at: root)
        }
        let accounts = Accounts()
        let access = ItemValue.object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("owner")]),
        ])
        let permissions = ItemValue.object([
            "profile": .text(ItemPermissions.profile), "owner": .text("owner"),
            "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:]),
        ])
        let sourceRoot = root.appendingPathComponent("source")
        let socket = root.appendingPathComponent("s").path
        let runtimeFile = root.appendingPathComponent("runtime.json")
        let sourceID: String
        let targetID: String
        let membership: PersonalMembershipConfiguration
        do {
            let source = try ItemStore.initializePersonalWorkgroup(
                root: sourceRoot, accounts: accounts, accessConfiguration: access)
            let identity = try source.personalSyncIdentity()
            sourceID = identity.replicaID
            XCTAssertNil(identity.membership)
            XCTAssertTrue(try source.loadPersonalPeerCredentials(includePending: true).isEmpty)
            let target = try ItemStore.createPersonalSyncReplica(
                root: root.appendingPathComponent("target"),
                storeID: identity.storeID, accessConfiguration: access, accounts: accounts)
            targetID = try target.personalSyncIdentity().replicaID
            membership = try PersonalMembershipConfiguration(
                storeID: identity.storeID, configurationID: id(),
                members: [
                    .init(replicaID: sourceID, hostname: "source.example.invalid"),
                    .init(replicaID: targetID, hostname: "target.example.invalid"),
                ])
        }
        let sourcePort = try await unusedPort()
        var offlineTargetPort = try await unusedPort()
        while offlineTargetPort == sourcePort { offlineTargetPort = try await unusedPort() }
        let runtime = try PersonalPeerRuntimeConfiguration(
            settings: PeerRuntimeConfiguration(
                listen: .init(host: "127.0.0.1", port: sourcePort),
                peers: [.init(alias: targetID + "-dial", host: "localhost", port: offlineTargetPort)],
                synchronization: .init(enabled: true, intervalSeconds: 15)))
        try PrivateConfiguration.write(runtime.encoded(), to: runtimeFile)
        let configuration = DaemonConfiguration(
            storePath: sourceRoot.path, socketPath: socket, httpPort: nil,
            attachmentUploadPolicy: .init(
                maximumStagedBytes: 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024),
            peerRuntimeConfigurationPath: runtimeFile.path)
        let daemon = try await SharedDaemon.startForTesting(
            configuration: configuration, makeAccountDirectory: { accounts })
        do {
            let endpoints = await daemon.endpoints()
            let optionalNetwork = await daemon.personalPeerRuntimeForTesting()
            let network = try XCTUnwrap(optionalNetwork)
            let statusBefore = try JSON.decode(
                PeerOperatorStatus.self,
                await Task.detached {
                    try ItemClient(socketPath: socket).call(PeerOperatorStatus.nativeMethod)
                }.value)
            XCTAssertEqual(statusBefore.runtime.state, .active)
            XCTAssertEqual(statusBefore.runtime.configurationPath, runtimeFile.path)
            XCTAssertEqual(statusBefore.runtime.settingsDigest, runtime.settings.settingsDigest)
            XCTAssertEqual(statusBefore.runtime.responderPublished, false)
            XCTAssertTrue(statusBefore.runtime.synchronizationEnabled)
            XCTAssertEqual(statusBefore.runtime.synchronization.state, .active)
            XCTAssertEqual(statusBefore.runtime.synchronization.eligibleEdgeCount, 0)
            let infoBefore =
                try JSONSerialization.jsonObject(
                    with: await Task.detached {
                        try ItemClient(socketPath: socket).call("TractandaStore/info")
                    }.value) as? [String: Any]
            XCTAssertEqual((infoBefore?["clustering"] as? [String: Any])?["state"] as? String, "standalone")
            let created = try await Task.detached {
                try ItemClient(socketPath: socket).commitFixture(
                    .init(
                        classID: "Item",
                        changes: [
                            "subject": .text("available-before-pairing"),
                            "body": .text("ordinary source content"), "permissions": permissions,
                        ], operationID: "empty-source-create"))
            }.value
            let originalRead = try await item(socket, created.revision.itemID)
            XCTAssertEqual(originalRead.fields["subject"], .text("available-before-pairing"))
            let prepared = try JSON.decode(
                PersonalMembershipPreparation.self,
                await admin(
                    socket, "membership.prepare",
                    [
                        "configuration": .bytes(JSON.encode(membership)), "nonce": .text(id()),
                    ]))
            XCTAssertEqual(prepared.configuration, membership)
            let leftKeys = root.appendingPathComponent("source-keys")
            let rightKeys = root.appendingPathComponent("target-keys")
            try PrivateConfiguration.makeDirectory(leftKeys)
            try PrivateConfiguration.makeDirectory(rightKeys)
            try PersonalPairingFiles.create(
                configuration: membership, leftReplicaID: sourceID, rightReplicaID: targetID,
                leftDirectory: leftKeys, rightDirectory: rightKeys)
            let localFiles = try FileManager.default.contentsOfDirectory(
                at: leftKeys, includingPropertiesForKeys: nil
            ).map(\.path)
            let registered = try JSON.decode(
                [String: Int].self,
                await admin(
                    socket, "credentials.register",
                    [
                        "configuration": .bytes(JSON.encode(membership)),
                        "paths": .list(localFiles.map(ItemValue.text)),
                    ]))
            XCTAssertEqual(registered["registered"], 2)
            await network.refreshNow()
            try await eventually(
                "Online native registration must refresh the pending responder without restarting the source"
            ) {
                let status = try await network.operatorStatus()
                return status.state == .active && status.responderPublished == true
                    && status.synchronization.eligibleEdgeCount == 1
            }
            let identityAfter = try JSON.decode(PersonalSyncIdentity.self, await admin(socket, "identity"))
            XCTAssertNil(
                identityAfter.membership, "Preparing credentials must not silently commit membership")
            let updated = try await Task.detached {
                try ItemClient(socketPath: socket).commitFixture(
                    .init(
                        action: .revise, itemID: created.revision.itemID,
                        expectedRevisionID: created.revision.revisionID,
                        changes: ["subject": .text("available-after-registration")],
                        operationID: "empty-source-update"))
            }.value
            let removed = try await Task.detached {
                try ItemClient(socketPath: socket).commitFixture(
                    .init(
                        action: .revise, itemID: updated.revision.itemID,
                        expectedRevisionID: updated.revision.revisionID,
                        changes: ["isDeleted": .boolean(true)], operationID: "empty-source-delete"))
            }.value
            XCTAssertTrue(removed.revision.isDeleted)
            let restored = try await Task.detached {
                try ItemClient(socketPath: socket).commitFixture(
                    .init(
                        action: .revise, itemID: removed.revision.itemID,
                        expectedRevisionID: removed.revision.revisionID,
                        changes: ["isDeleted": .boolean(false)], operationID: "empty-source-restore"))
            }.value
            let finalRead = try await item(socket, restored.revision.itemID)
            XCTAssertEqual(finalRead.fields["subject"], .text("available-after-registration"))
            XCTAssertFalse(finalRead.isDeleted)
            let infoAfter =
                try JSONSerialization.jsonObject(
                    with: await Task.detached {
                        try ItemClient(socketPath: socket).call("TractandaStore/info")
                    }.value) as? [String: Any]
            XCTAssertEqual((infoAfter?["clustering"] as? [String: Any])?["state"] as? String, "standalone")
            let endpointsAfter = await daemon.endpoints()
            XCTAssertEqual(endpointsAfter.processID, endpoints.processID)
            XCTAssertEqual(endpointsAfter.socketPath, endpoints.socketPath)
            try capacity()
            await daemon.close()
        } catch {
            await daemon.close()
            throw error
        }
    }

    func testActualDaemonPairFreshEnrollmentBidirectionalWriteAndRestart() async throws {
        try await daemonPairFixture(revisionCount: 2_209)
    }
    func testCompactClusterStatusReportsActualProgressAndRejectsLateJobCallbacks() async throws {
        try await daemonPairFixture(revisionCount: 8, observeProgress: true)
    }
    func testHotEnrollmentBridgePreservesCurrentDataButNotRevokedPeersAndReportsRealCuts() async throws {
        try await daemonPairFixture(revisionCount: 8, hotEnrollment: true)
    }
    private func daemonPairFixture(
        revisionCount: Int, observeProgress: Bool = false, hotEnrollment: Bool = false
    ) async throws {
        // A 2,209-revision chain, two indexes, disk DFS frames and one600KiB owned
        // payload are conservatively estimated below96MiB. Never enlarge the cap or consume the genuine10GiB reserve.
        XCTAssertLessThanOrEqual(96 * 1024 * 1024, PeerFixtureCapacity.fixtureCapBytes)
        try PeerFixtureCapacity.requireFree(at: FileManager.default.temporaryDirectory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tpd-" + String(UUID().uuidString.prefix(8)))
        try PrivateConfiguration.makeDirectory(root)
        activeFixtureRoot = root
        defer {
            activeFixtureRoot = nil
            try? FileManager.default.removeItem(at: root)
        }
        let accounts = Accounts()
        let access = ItemValue.object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("owner")]),
        ])
        let permissions = ItemValue.object([
            "profile": .text(ItemPermissions.profile), "owner": .text("owner"),
            "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:]),
        ])
        let leftRoot = root.appendingPathComponent("l")
        let rightRoot = root.appendingPathComponent("r")
        let leftSocket = root.appendingPathComponent("ls").path
        let rightSocket = root.appendingPathComponent("rs").path
        let leftPort = try await unusedPort()
        var rightPort = try await unusedPort()
        while rightPort == leftPort { rightPort = try await unusedPort() }
        let leftRuntime = root.appendingPathComponent("left-runtime.json")
        let rightRuntime = root.appendingPathComponent("right-runtime.json")
        let seed: Revision
        let leftID: String
        let rightID: String
        let baseline: String
        let leftPlan: PersonalMembershipPreparation
        let rightPlan: PersonalMembershipPreparation
        do {
            let left = try ItemStore.initializePersonalWorkgroup(
                root: leftRoot, accounts: accounts, accessConfiguration: access)
            let identity = try left.personalSyncIdentity()
            leftID = identity.replicaID
            let right = try ItemStore.createPersonalSyncReplica(
                root: rightRoot, storeID: identity.storeID,
                accessConfiguration: access, accounts: accounts)
            rightID = try right.personalSyncIdentity().replicaID
            XCTAssertNotEqual(leftID, rightID)
            let config = try PersonalMembershipConfiguration(
                storeID: identity.storeID, configurationID: id(),
                members: [
                    .init(replicaID: leftID, hostname: "source.example.invalid"),
                    .init(replicaID: rightID, hostname: "target.example.invalid"),
                ])
            let nonce = try id()
            leftPlan = try left.preparePersonalMembershipChange(
                configuration: config, expectedDigest: nil, nonce: nonce)
            rightPlan = try right.preparePersonalMembershipChange(
                configuration: config, expectedDigest: nil, nonce: nonce)
            let leftKeys = root.appendingPathComponent("lk")
            let rightKeys = root.appendingPathComponent("rk")
            try PrivateConfiguration.makeDirectory(leftKeys)
            try PrivateConfiguration.makeDirectory(rightKeys)
            try PersonalPairingFiles.create(
                configuration: config, leftReplicaID: leftID, rightReplicaID: rightID,
                leftDirectory: leftKeys, rightDirectory: rightKeys)
            for (store, directory) in [(left, leftKeys), (right, rightKeys)] {
                let files = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                ).map(\.path)
                try PersonalPairingFiles.register(
                    store: store, paths: files, configuration: config, actorUID: tractanda_uid())
            }
            // A 2,209-revision ordinary chain has decreasing UUID-low fields while
            // actual UUID time increases through low-field rollover. Rebuilt catalogue
            // order is therefore reverse causal order, exercising the disk DFS stack.
            let count = revisionCount
            let ticksPerDay: UInt64 = 864_000_000_000
            let currentTicks = try UUIDVersion1Components(UUID(uuidString: id())!).timestamp
            let base = (currentTicks - 14 * ticksPerDay) & ~UInt64(0xffff_ffff)
            let itemID = try id()
            var previous: Revision?
            let files = DocumentContentFiles(
                root: leftRoot, ownerUID: tractanda_uid(), minimumFreeBytes: 10 * 1024 * 1024 * 1024)
            for index in 0..<count {
                if index % 32 == 0 { try capacity() }
                let components = try UUIDVersion1Components(
                    timestamp: base + UInt64(index) * 0x1_0000_0000 + UInt64(0xffff_ff00 - index),
                    clockSequence: 1, node: 1)
                let revisionID = components.uuid.uuidString.lowercased()
                var fields: [String: ItemValue] = [
                    "itemID": .text(itemID), "revisionID": .text(revisionID),
                    "classID": .text("Item"), "schemaVersion": .integer(1), "subject": .text("seed"),
                    "body": .text("revision " + String(index)), "permissions": permissions,
                    "isDeleted": .boolean(false),
                    "createdAt": previous?.fields["createdAt"] ?? .date(components.timestampUTC),
                    "modifiedAt": .date(components.timestampUTC), "actor": .text("user:owner"),
                    "operationID": .text("private-reverse-" + String(index)),
                    "requestIdentity": .text("private bounded history fixture"),
                ]
                if let previous { fields["supersedes"] = .text(previous.revisionID) }
                let revision = try Revision(fields: fields)
                let bytes = try RecordCodec.encode(revision)
                guard bytes.count <= 4096 else {
                    throw TractandaError("resourceLimit", "Reverse fixture exceeded its estimate.")
                }
                try files.writeImmutable(
                    bytes,
                    path: ["items", "2026", "10", "25", "10", "00", itemID, revisionID + ".tractanda"],
                    maximumBytes: 4096)
                previous = revision
            }
            seed = try XCTUnwrap(previous)
            try left.rebuildIndex()
            // Exact orphan patterns are disposable; unaccepted staging is preserved.
            let orphan = try id() + "-frame-1.json"
            try files.replacePersonalSyncMetadata(
                JSON.encode(["temporary": true]), path: [".personal-sync", "work", orphan])
            try files.replacePersonalSyncMetadata(
                JSON.encode(["keep": true]), path: [".personal-sync", "work", "keep.json"])
            baseline = try right.startPersonalBaseline(sourceReplicaID: leftID)
            func runtime(local: String, remote: String, port: Int, remotePort: Int) throws -> Data {
                try PersonalPeerRuntimeConfiguration(
                    settings: PeerRuntimeConfiguration(
                        listen: .init(host: "127.0.0.1", port: port),
                        peers: [
                            .init(
                                alias: remote + "-dial", host: "roaming.unreachable.invalid",
                                port: remotePort,
                                fallbackEndpoints: [.init(host: "localhost", port: remotePort)])
                        ],
                        synchronization: .init(enabled: true, intervalSeconds: 15))
                ).encoded()
            }
            try PrivateConfiguration.write(
                runtime(local: leftID, remote: rightID, port: leftPort, remotePort: rightPort),
                to: leftRuntime)
            try PrivateConfiguration.write(
                runtime(local: rightID, remote: leftID, port: rightPort, remotePort: leftPort),
                to: rightRuntime)
        }
        let leftConfig = DaemonConfiguration(
            storePath: leftRoot.path, socketPath: leftSocket, httpPort: nil,
            attachmentUploadPolicy: .init(
                maximumStagedBytes: 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024),
            peerRuntimeConfigurationPath: leftRuntime.path)
        let rightConfig = DaemonConfiguration(
            storePath: rightRoot.path, socketPath: rightSocket, httpPort: nil,
            attachmentUploadPolicy: .init(
                maximumStagedBytes: 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024),
            peerRuntimeConfigurationPath: rightRuntime.path)
        var left: SharedDaemon? = try await SharedDaemon.startForTesting(
            configuration: leftConfig, makeAccountDirectory: { accounts })
        var right: SharedDaemon?
        do {
            right = try await SharedDaemon.startForTesting(
                configuration: rightConfig, makeAccountDirectory: { accounts })
            let nativeIdentity = try JSON.decode(
                PersonalSyncIdentity.self, await admin(leftSocket, "identity"))
            XCTAssertEqual(nativeIdentity.replicaID, leftID)
            let workNames = try FileManager.default.contentsOfDirectory(
                atPath: leftRoot.appendingPathComponent(".personal-sync/work").path)
            XCTAssertEqual(workNames, ["keep.json"])
            let loadedLeftNetwork = await left!.personalPeerRuntimeForTesting()
            let loadedRightNetwork = await right!.personalPeerRuntimeForTesting()
            let leftNetwork = try XCTUnwrap(loadedLeftNetwork)
            let rightNetwork = try XCTUnwrap(loadedRightNetwork)
            let brokenEnrollmentProvider = Mutex(false)
            let enrollmentCalls = Mutex(0)
            let cutCapture = CutCapture()
            if hotEnrollment {
                let material = PersonalEnrollmentRuntimeMaterial(
                    routes: .init(
                        operationID: try id(),
                        configurationDigest: try rightPlan.configuration.digest,
                        endpoints: [rightID: [try .init(host: "route-only.invalid", port: 65534)]]))
                await rightNetwork.setEnrollmentBridge(
                    material: {
                        if brokenEnrollmentProvider.withLock({ $0 }) {
                            throw TractandaError("private-value", "private-value")
                        }
                        return material
                    }, validate: { _, purpose in XCTAssertEqual(purpose, .memberControl) },
                    handle: { _, _, request in
                        XCTAssertEqual(request.operation, "enrollment.member.inspect")
                        enrollmentCalls.withLock { $0 += 1 }
                        return Data("{\"supported\":true}".utf8)
                    }, completedCut: { _, report in await cutCapture.record(report) })
                await leftNetwork.setEnrollmentBridge(
                    material: { .init() },
                    validate: { _, purpose in
                        XCTAssertEqual(purpose, .memberControl)
                    }, handle: { _, _, _ in Data("{}".utf8) })
            }
            try await eventually("Both actual daemons must authenticate pending control-only pairing") {
                let leftReady = await leftNetwork.hasConnectionForTesting(remoteReplicaID: rightID)
                let rightReady = await rightNetwork.hasConnectionForTesting(remoteReplicaID: leftID)
                return leftReady && rightReady
            }
            let precommitCuts = await rightNetwork.completedCutsForTesting(remoteReplicaID: leftID)
            XCTAssertEqual(precommitCuts, 0)
            let pendingObservation = try await rightNetwork.operatorStatus().personalPeers
            let pendingPeer = try XCTUnwrap(pendingObservation?.first { $0.replicaID == leftID })
            XCTAssertTrue(pendingPeer.connected)
            XCTAssertEqual(pendingPeer.controlOnly, true)
            XCTAssertNotNil(pendingPeer.lastConnectedAt)
            XCTAssertNil(pendingPeer.lastPullStartedAt)
            XCTAssertNil(pendingPeer.lastPullFinishedAt)
            _ = try await admin(
                leftSocket, "membership.commit", ["preparation": .bytes(JSON.encode(leftPlan))])
            _ = try await admin(
                rightSocket, "membership.commit", ["preparation": .bytes(JSON.encode(rightPlan))])
            try await eventually(
                "Initial finite baseline and fresh rescan must finish while source remains available"
            ) {
                await rightNetwork.completedCutsForTesting(remoteReplicaID: leftID) >= 2
            }
            let completedObservation = try await rightNetwork.operatorStatus().personalPeers
            let completedPeer = try XCTUnwrap(completedObservation?.first { $0.replicaID == leftID })
            XCTAssertEqual(completedPeer.incomingConnectionCount + completedPeer.outgoingConnectionCount, 1)
            XCTAssertEqual(completedPeer.controlOnly, false)
            XCTAssertEqual(completedPeer.lastOutcome, .complete)
            XCTAssertNotNil(completedPeer.lastPullStartedAt)
            XCTAssertNotNil(completedPeer.lastPullFinishedAt)
            XCTAssertGreaterThanOrEqual(completedPeer.completedCuts, 2)
            let noChangeBaselineReport = await rightNetwork.lastReportForTesting(remoteReplicaID: leftID)
            XCTAssertEqual(
                noChangeBaselineReport?.revisions, 0,
                "Second unchanged cut must use the completed rowid watermark")
            _ = try await admin(rightSocket, "baseline.finish", ["selectionID": .text(baseline)])
            let copiedSeed = try await item(rightSocket, seed.itemID)
            XCTAssertEqual(copiedSeed.fields["subject"], .text("seed"))
            let reverse = try await Task.detached {
                try ItemClient(socketPath: rightSocket).commitFixture(
                    .init(
                        classID: "Item",
                        changes: [
                            "subject": .text("from-target"),
                            "permissions": permissions,
                        ], operationID: "personal-daemon-reverse"))
            }.value
            try await eventually("A write on the fresh target must reach source through the same mesh") {
                (try? await self.item(leftSocket, reverse.revision.itemID).fields["subject"])
                    == .text("from-target")
            }
            if hotEnrollment {
                let baselineReport = try XCTUnwrap(noChangeBaselineReport)
                let generation = try XCTUnwrap(baselineReport.sourceCatalogueGeneration)
                let cut = try XCTUnwrap(baselineReport.cutRowID)
                let between = try await Task.detached {
                    try ItemClient(socketPath: leftSocket).commitFixture(
                        .init(
                            classID: "Item",
                            changes: [
                                "subject": .text("source-write-between-cuts"), "permissions": permissions,
                            ], operationID: "hot-runtime-between-cuts"))
                }.value
                await rightNetwork.requestPullForTesting(remoteReplicaID: leftID)
                try await eventually(
                    "A new finite cut includes a source write without changing catalogue epoch"
                ) {
                    let report = await rightNetwork.lastReportForTesting(remoteReplicaID: leftID)
                    let copied = try? await self.item(rightSocket, between.revision.itemID)
                    return report?.sourceCatalogueGeneration == generation && (report?.cutRowID ?? -1) > cut
                        && copied != nil
                }
                let cuts = await cutCapture.snapshot()
                XCTAssertGreaterThanOrEqual(cuts.count, 2)
                XCTAssertTrue(cuts.allSatisfy { $0.sourceCatalogueGeneration != nil && $0.cutRowID != nil })
                let selectedDigest = try rightPlan.configuration.digest
                try await eventually(
                    "Actual finished cut permits a finalization fence without starting a third pull"
                ) {
                    do {
                        try await rightNetwork.withEnrollmentFinalization(
                            remoteReplicaID: leftID,
                            configurationDigest: selectedDigest
                        ) {
                            await rightNetwork.requestPullForTesting(remoteReplicaID: leftID)
                            await rightNetwork.tick()
                            let fenced = try await rightNetwork.operatorStatus()
                            XCTAssertEqual(fenced.synchronization.activeJobCount, 0)
                        }
                        return true
                    } catch let error as TractandaError where error.code == "baselineNotReady" {
                        return false
                    }
                }
                await leftNetwork.setDialingSuspendedForTesting(true)
                await rightNetwork.setDialingSuspendedForTesting(true)
                await rightNetwork.setChunkObserverForTesting { _, _ in
                    throw TractandaError("fixtureCutFailure", "An intentionally interrupted later finite cut")
                }
                _ = try await Task.detached {
                    try ItemClient(socketPath: leftSocket).commitFixture(
                        .init(
                            classID: "Item",
                            changes: [
                                "subject": .text("later-failed-cut"), "permissions": permissions,
                            ], operationID: "hot-runtime-failed-cut"))
                }.value
                await rightNetwork.requestPullForTesting(remoteReplicaID: leftID)
                try await eventually(
                    "A later failed actual cut invalidates previously successful baseline observation"
                ) {
                    let status = try await rightNetwork.operatorStatus()
                    return status.personalPeers?.first(where: { $0.replicaID == leftID })?.lastOutcome
                        == .failed
                }
                do {
                    try await rightNetwork.withEnrollmentFinalization(
                        remoteReplicaID: leftID,
                        configurationDigest: selectedDigest
                    ) { XCTFail("Stale successful cut permitted finalization") }
                    XCTFail("A later failed cut did not block finalization")
                } catch { XCTAssertEqual((error as? TractandaError)?.code, "baselineNotReady") }
                await rightNetwork.setChunkObserverForTesting(nil)
                try await eventually("A new clean actual cut restores finalization eligibility") {
                    if !(await rightNetwork.hasConnectionForTesting(remoteReplicaID: leftID)) {
                        try? await rightNetwork.connectForTesting(remoteReplicaID: leftID)
                    }
                    do {
                        try await rightNetwork.withEnrollmentFinalization(
                            remoteReplicaID: leftID,
                            configurationDigest: selectedDigest
                        ) {}
                        return true
                    } catch let error as TractandaError where error.code == "baselineNotReady" {
                        return false
                    }
                }
                await leftNetwork.setDialingSuspendedForTesting(false)
                await rightNetwork.setDialingSuspendedForTesting(false)
                let request = PeerExchangeRequest(
                    "enrollment.member.inspect", ["operationID": .text(try id())])
                _ = try await leftNetwork.controlRequest(
                    remoteReplicaID: rightID,
                    configurationDigest: rightPlan.configuration.digest, request: request)
                XCTAssertEqual(enrollmentCalls.withLock { $0 }, 1)
                let ownEndpoints = try await rightNetwork.effectiveOwnEndpoints(hostname: "127.0.0.1")
                XCTAssertEqual(ownEndpoints, [try .init(host: "127.0.0.1", port: rightPort)])
                let before = try await rightNetwork.operatorStatus()
                brokenEnrollmentProvider.withLock { $0 = true }
                await rightNetwork.refreshNow()
                let after = try await rightNetwork.operatorStatus()
                XCTAssertEqual(before.settingsDigest, after.settingsDigest)
                XCTAssertEqual(after.responderPublished, true)
                XCTAssertEqual(after.lastErrorCode, "enrollmentRuntimeUnavailable")
                let currentStillConnected = await rightNetwork.hasConnectionForTesting(
                    remoteReplicaID: leftID)
                XCTAssertTrue(currentStillConnected)
                let readable = try await item(rightSocket, seed.itemID)
                XCTAssertEqual(readable.fields["subject"], .text("seed"))
                do {
                    _ = try await leftNetwork.controlRequest(
                        remoteReplicaID: rightID,
                        configurationDigest: rightPlan.configuration.digest, request: request)
                    XCTFail("Corrupt enrollment provider still admitted enrollment")
                } catch { XCTAssertEqual(enrollmentCalls.withLock { $0 }, 1) }
                // Ordinary current membership is still authoritative under the same bad
                // overlay. Revoking the peer must remove its data session as usual.
                let retained = try PersonalMembershipConfiguration(
                    storeID: rightPlan.configuration.storeID,
                    configurationID: id(),
                    members: [.init(replicaID: rightID, hostname: "target.example.invalid")])
                let removal = try JSON.decode(
                    PersonalMembershipPreparation.self,
                    await admin(
                        rightSocket,
                        "membership.prepare",
                        [
                            "configuration": .bytes(JSON.encode(retained)),
                            "expectedDigest": .text(try rightPlan.configuration.digest), "nonce": .text(id()),
                        ]))
                _ = try await admin(
                    rightSocket, "membership.commit", ["preparation": .bytes(JSON.encode(removal))])
                await rightNetwork.refreshNow()
                let revokedStillConnected = await rightNetwork.hasConnectionForTesting(
                    remoteReplicaID: leftID)
                XCTAssertFalse(revokedStillConnected)
                let readableAfterRevocation = try await item(rightSocket, seed.itemID)
                XCTAssertEqual(readableAfterRevocation.fields["subject"], .text("seed"))
                await right!.close()
                right = nil
                await left!.close()
                left = nil
                return
            }
            let beforeEmptyCut = await rightNetwork.completedCutsForTesting(remoteReplicaID: leftID)
            await rightNetwork.requestPullForTesting(remoteReplicaID: leftID)
            try await eventually(
                "Unchanged steady-state poll must not enumerate the full2209-revision history"
            ) {
                let cuts = await rightNetwork.completedCutsForTesting(remoteReplicaID: leftID)
                let report = await rightNetwork.lastReportForTesting(remoteReplicaID: leftID)
                return cuts > beforeEmptyCut && report?.revisions == 0
            }
            let progressCapture = ProgressCapture()
            if observeProgress {
                await rightNetwork.setChunkObserverForTesting { descriptor, _ in
                    guard descriptor.kind == .original, descriptor.byteCount == 600 * 1024 else { return }
                    try await self.eventually(
                        "Active native status must expose acknowledged transfer progress"
                    ) {
                        let bytes = try await Task.detached {
                            try ItemClient(socketPath: rightSocket).call(PeerOperatorStatus.nativeMethod)
                        }.value
                        let value = try JSON.decode(PeerOperatorStatus.self, bytes)
                        guard
                            let progress = value.runtime.personalPeers?.first(where: {
                                $0.replicaID == leftID
                            })?.currentPull,
                            progress.transferredBytes >= 256 * 1024
                        else { return false }
                        XCTAssertEqual(progress.phase, .transferring)
                        XCTAssertNotNil(progress.lastProgressAt)
                        await progressCapture.record(
                            progress,
                            delivery: rightNetwork.progressDeliveryForTesting(remoteReplicaID: leftID))
                        return true
                    }
                }
            }
            let payload = Data(repeating: 0x53, count: 600 * 1024)
            let original = root.appendingPathComponent("owned.bin")
            try PrivateConfiguration.write(payload, to: original)
            let attached = try await Task.detached {
                try AttachmentFiles.attach(
                    client: ItemClient(socketPath: leftSocket), source: original,
                    itemID: seed.itemID, expectedRevisionID: seed.revisionID,
                    operationID: "personal-daemon-owned", mediaType: "application/octet-stream")
            }.value
            try await eventually(
                "Owned original must transfer in bounded chunks with its exact referencing revision"
            ) {
                (try? await self.item(rightSocket, seed.itemID).revisionID)
                    == attached.revisionID
            }
            try await eventually("A new source revision must transfer only the incremental tail") {
                let report = await rightNetwork.lastReportForTesting(remoteReplicaID: leftID)
                return report?.outcomes["accepted", default: 0] == 1 && (report?.revisions ?? Int.max) <= 2
            }
            if observeProgress {
                let (observed, oldDelivery) = await progressCapture.captured()
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(observed).transferredBytes, 256 * 1024)
                let deliver = try XCTUnwrap(oldDelivery)
                await deliver(
                    try .init(
                        phase: .transferring, revisionCount: Int.max, transferredBytes: Int64.max,
                        lastProgressAt: "2026-10-26T12:34:56Z"))
                let current = try await rightNetwork.operatorStatus().personalPeers?.first {
                    $0.replicaID == leftID
                }
                XCTAssertNotEqual(
                    current?.currentPull?.transferredBytes, Int64.max,
                    "A completed job's late callback cannot overwrite an idle or newer pull")
                await rightNetwork.setChunkObserverForTesting(nil)
            }
            // An extra opposite-direction dial must not tear down the shared chosen
            // socket or livelock. Then let the other endpoint be the only dialer.
            try await rightNetwork.connectForTesting(remoteReplicaID: leftID)
            try await eventually("Concurrent opposite-direction dial must retain an admitted duplex session")
            {
                let a = await leftNetwork.hasConnectionForTesting(remoteReplicaID: rightID)
                let b = await rightNetwork.hasConnectionForTesting(remoteReplicaID: leftID)
                return a && b
            }
            await leftNetwork.setDialingSuspendedForTesting(true)
            await rightNetwork.setDialingSuspendedForTesting(true)
            await leftNetwork.closeConnectionsForTesting(remoteReplicaID: rightID)
            await rightNetwork.closeConnectionsForTesting(remoteReplicaID: leftID)
            try await rightNetwork.connectForTesting(remoteReplicaID: leftID)
            try await eventually(
                "The opposite endpoint must initiate and both ends retain incoming/outgoing access"
            ) {
                let a = try await leftNetwork.operatorStatus()
                let b = try await rightNetwork.operatorStatus()
                return a.incomingConnectionCount == 1 && b.outgoingConnectionCount == 1
            }
            await leftNetwork.setDialingSuspendedForTesting(false)
            await rightNetwork.setDialingSuspendedForTesting(false)
            let interrupted = ChunkProgress()
            await rightNetwork.setChunkObserverForTesting { descriptor, offset in
                if descriptor.kind == .original, descriptor.byteCount == 700 * 1024,
                    await interrupted.record(descriptor, offset: offset)
                {
                    await rightNetwork.interruptForTesting(remoteReplicaID: leftID)
                }
            }
            let secondPayload = Data(repeating: 0x76, count: 700 * 1024)
            let secondOriginal = root.appendingPathComponent("second.bin")
            try PrivateConfiguration.write(secondPayload, to: secondOriginal)
            let secondAttached = try await Task.detached {
                try AttachmentFiles.attach(
                    client: ItemClient(socketPath: leftSocket), source: secondOriginal,
                    itemID: seed.itemID, expectedRevisionID: attached.revisionID,
                    operationID: "personal-daemon-interrupted", mediaType: "application/octet-stream")
            }.value
            await rightNetwork.requestPullForTesting(remoteReplicaID: leftID)
            try await eventually("Actual TLS transfer must disconnect after one acknowledged256KiB chunk") {
                await interrupted.snapshot() != nil
            }
            let recordedInterruption = await interrupted.snapshot()
            let interruptedObject = try XCTUnwrap(recordedInterruption)
            XCTAssertEqual(interruptedObject.1, 256 * 1024)
            let duringInterruption = try await item(rightSocket, seed.itemID)
            XCTAssertEqual(
                duringInterruption.revisionID, attached.revisionID,
                "Partial original must not promote its referencing revision")
            await right!.close()
            right = nil
            do {
                let retained = try ItemStore.openInitialized(root: rightRoot, accounts: accounts)
                let credential = try XCTUnwrap(retained.loadPersonalPeerCredentials().first)
                let progress = try retained.preparePersonalObject(
                    session: credential.binding, descriptor: interruptedObject.0)
                XCTAssertEqual(progress.nextOffset, 256 * 1024)
                XCTAssertFalse(progress.complete)
            }
            let resumed = ChunkProgress()
            right = try await SharedDaemon.startForTesting(
                configuration: rightConfig, makeAccountDirectory: { accounts },
                personalChunkObserverForTesting: { descriptor, offset in
                    if descriptor.kind == .original, descriptor.byteCount == 700 * 1024 {
                        _ = await resumed.record(descriptor, offset: offset)
                    }
                })
            try await eventually(
                "Restart must resume the retained stage and publish only after complete hash verification"
            ) {
                (try? await self.item(rightSocket, seed.itemID).revisionID) == secondAttached.revisionID
            }
            let recordedResume = await resumed.snapshot()
            XCTAssertEqual(
                recordedResume?.1, 512 * 1024, "First resumed append must begin after retained256KiB")
            let restartedReverse = try await item(rightSocket, reverse.revision.itemID)
            let restartedSeed = try await item(rightSocket, seed.itemID)
            XCTAssertEqual(restartedReverse.fields["subject"], .text("from-target"))
            XCTAssertEqual(restartedSeed.revisionID, secondAttached.revisionID)
            let actual = try await Task.detached {
                try ItemClient(socketPath: rightSocket).listAttachments(itemID: seed.itemID)
            }.value
            XCTAssertEqual(
                Set(actual.attachments.map(\.byteCount)), [Int64(payload.count), Int64(secondPayload.count)])
            let receivedPayload = try await Task.detached {
                let client = ItemClient(socketPath: rightSocket)
                let attachment = try XCTUnwrap(
                    client.listAttachments(itemID: seed.itemID).attachments.first(where: {
                        $0.byteCount == 600 * 1024
                    }))
                var output = Data()
                var offset: Int64 = 0
                while offset < attachment.byteCount {
                    let chunk = try client.attachmentContent(
                        itemID: seed.itemID, attachmentID: attachment.attachmentID, offset: offset)
                    output.append(chunk.data)
                    guard chunk.nextOffset > offset else {
                        throw TractandaError("fixtureRead", "Payload read made no progress.")
                    }
                    offset = chunk.nextOffset
                }
                return output
            }.value
            XCTAssertEqual(receivedPayload, payload)
            try capacity()
            await right!.close()
            right = nil
            await left!.close()
            left = nil
        } catch {
            await right?.close()
            await left?.close()
            throw error
        }
    }
}
