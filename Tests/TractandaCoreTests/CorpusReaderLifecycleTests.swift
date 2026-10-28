import Foundation
import TractandaClient
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class CorpusReaderLifecycleTests: XCTestCase {
    private let reserve: Int64 = 10 * 1024 * 1024 * 1024
    private let cap: Int64 = 16 * 1024 * 1024
    private func root() throws -> URL {
        // All canonical/Index/vector/metadata copies of one tiny source are estimated below2MiB.
        try PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve).check(
            at: FileManager.default.temporaryDirectory, additionalBytes: 2 * 1024 * 1024)
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "corpus-reader-" + UUID().uuidString)
    }
    private func check(_ root: URL) throws {
        try PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve).check(
            at: root, additionalBytes: 0)
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw TractandaError("resourceLimit", "Reader fixture allocation is unknown")
        }
        var total: Int64 = 0
        for case let url as URL in iterator {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_blocks >= 0 else {
                throw TractandaError("resourceLimit", "Reader fixture allocation is unknown")
            }
            let bytes = Int64(info.st_blocks).multipliedReportingOverflow(by: 512)
            let sum = total.addingReportingOverflow(bytes.partialValue)
            guard !bytes.overflow, !sum.overflow, sum.partialValue <= cap else {
                throw TractandaError("resourceLimit", "Reader fixture exceeded16MiB cap")
            }
            total = sum.partialValue
        }
    }
    private func store(_ root: URL, maximum: Int64 = 16 * 1024 * 1024) throws -> ItemStore {
        if !FileManager.default.fileExists(atPath: root.path) {
            _ = try ItemStore.initializeFresh(root: root)
        }
        return try ItemStore.openInitialized(
            root: root, attachmentUploadPolicy: .init(maximumStagedBytes: maximum, minimumFreeBytes: reserve))
    }
    private func source(_ store: ItemStore) throws -> Revision {
        try store.commit(
            .init(
                classID: "Item", changes: ["body": .text("held corpus reader")], operationID: "reader-source")
        ).revision
    }
    private func index(_ root: URL) throws -> ItemIndex {
        try ItemIndex(path: root.appendingPathComponent("index/items.sqlite").path, create: false)
    }
    func testCaptureChargesBeforeDeliveryAndReleasedLeaseCannotDeliver() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        let revision = try source(store)
        let snapshot = try XCTUnwrap(store.captureIndexedCorpus(itemID: revision.itemID))
        let state = try store.corpusReadStateForTesting()
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state.charge, try index(root).corpusRetainedBytes(try XCTUnwrap(snapshot.retentionID)))
        XCTAssertGreaterThan(state.charge, 0)
        try store.revalidateIndexedCorpus(snapshot)
        try store.releaseIndexedCorpus(snapshot)
        XCTAssertEqual(try store.corpusReadStateForTesting().charge, 0)
        XCTAssertThrowsError(try store.revalidateIndexedCorpus(snapshot))
        try check(root)
    }
    func testAdmissionRejectsBeforePersistentLeaseAndPostcommitFailureRetainsActualDebt() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision: Revision
        let encoded: Int64
        do {
            let store = try store(root)
            revision = try source(store)
            let snapshot = try XCTUnwrap(
                index(root).captureCorpusSnapshot(
                    itemID: revision.itemID, expectedRevisionID: revision.revisionID))
            encoded = try ItemIndex.corpusReadLeaseCharge(
                UUID.makeVersion1().uuidString.lowercased(), identity: snapshot.identity)
        }
        do {
            let limited = try store(root, maximum: encoded - 1)
            XCTAssertThrowsError(try limited.captureIndexedCorpus(itemID: revision.itemID)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
            }
            XCTAssertTrue(try index(root).corpusReadWorkPage().isEmpty)
            XCTAssertEqual(try limited.corpusReadStateForTesting().charge, 0)
        }
        let store = try store(root)
        store.afterCorpusReadCaptureForTesting = {
            throw TractandaError("injectedCaptureReply", "After lease COMMIT")
        }
        store.beforeCorpusReadReleaseForTesting = { _ in
            throw TractandaError("injectedRetirement", "Retirement unavailable")
        }
        XCTAssertThrowsError(try store.captureIndexedCorpus(itemID: revision.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "injectedCaptureReply")
        }
        let retained = try store.corpusReadStateForTesting()
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.pending, 1)
        XCTAssertEqual(retained.charge, encoded)
        store.beforeCorpusReadReleaseForTesting = nil
        store.afterCorpusReadCaptureForTesting = nil
        XCTAssertTrue(try store.retireOnePendingCorpusRead())
        XCTAssertEqual(try store.corpusReadStateForTesting().count, 0)
        XCTAssertEqual(try store.corpusReadStateForTesting().charge, 0)
        XCTAssertNotNil(try store.captureIndexedCorpus(itemID: revision.itemID))
        try check(root)
    }
    func testFullLeaseWindowDoesNotCreateUnpersistedDisposalProofs() throws {
        //64 compact metadata leases plus SQLite WAL are estimated below4MiB; no page bulk.
        try PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve).check(
            at: FileManager.default.temporaryDirectory, additionalBytes: 4 * 1024 * 1024)
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        let revision = try source(store)
        var readers: [IndexedCorpusSnapshot] = []
        for offset in 0..<64 {
            if offset % 8 == 0 { try check(root) }
            readers.append(try XCTUnwrap(store.captureIndexedCorpus(itemID: revision.itemID)))
        }
        store.beforeCorpusReadReleaseForTesting = { _ in
            throw TractandaError("injectedRetirement", "Writer unavailable")
        }
        XCTAssertThrowsError(try store.captureIndexedCorpus(itemID: revision.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        let state = try store.corpusReadStateForTesting()
        XCTAssertEqual(state.count, 64)
        XCTAssertEqual(state.pending, 0, "An absent lease must not consume pending disposal memory")
        store.beforeCorpusReadReleaseForTesting = nil
        for reader in readers { try store.releaseIndexedCorpus(reader) }
        XCTAssertEqual(try store.corpusReadStateForTesting().charge, 0)
        try check(root)
    }

    func testStartupReclaimsOnlyFencedReadersAndKeepsStageDiscardAndCurrentGenerations() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision: Revision
        let stale: IndexedCorpusSnapshot
        let stageID = try UUID.makeVersion1().uuidString.lowercased()
        let discardID = try UUID.makeVersion1().uuidString.lowercased()
        do {
            let store = try store(root)
            revision = try source(store)
            let current = try store.capturePageCorpus(itemID: revision.itemID)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("spools"),
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let currentSpool = try PageCorpusProjection.prepare(
                input: current.input, provider: current.provider,
                root: root.appendingPathComponent("spools"),
                policy: .init(maximumBytes: cap, minimumFreeBytes: reserve))
            _ = try ItemIndex.stageCorpus(
                indexPath: store.indexDirectory.appendingPathComponent("items.sqlite").path,
                input: current.input, prepared: currentSpool, workID: stageID, writeBoundary: { _ in },
                boundary: {})
            var fields = revision.fields
            fields["revisionID"] = .text(try UUID.makeVersion1().uuidString.lowercased())
            fields["body"] = .text("private retired source")
            let input = try PageCorpusInput(
                storeID: current.input.binding.storeID,
                revision: Revision(fields: fields, formatVersion: revision.formatVersion))
            let orphan = try PageCorpusProjection.prepare(
                input: input, provider: current.provider,
                root: root.appendingPathComponent("spools"),
                policy: .init(maximumBytes: cap, minimumFreeBytes: reserve))
            _ = try ItemIndex.stageCorpus(
                indexPath: store.indexDirectory.appendingPathComponent("items.sqlite").path,
                input: input, prepared: orphan, workID: discardID, writeBoundary: { _ in }, boundary: {})
            try index(root).releaseCorpusWork(discardID)
            stale = try XCTUnwrap(store.captureIndexedCorpus(itemID: revision.itemID))
        }
        let store = try store(root)
        let index = try index(root)
        XCTAssertTrue(try index.corpusReadWorkPage().isEmpty)
        XCTAssertEqual(try store.corpusReadStateForTesting().charge, 0)
        let kinds = Dictionary(uniqueKeysWithValues: try index.corpusWorkPage().map { ($0.workID, $0.kind) })
        XCTAssertEqual(kinds[stageID], "stage")
        XCTAssertEqual(kinds[discardID], "discard")
        XCTAssertGreaterThan(try index.corpusRetainedBytes(discardID), 0)
        XCTAssertTrue(try index.corpusMatches(store.get(revision.itemID)))
        XCTAssertThrowsError(try store.revalidateIndexedCorpus(stale))
        let live = try XCTUnwrap(store.captureIndexedCorpus(itemID: revision.itemID))
        XCTAssertEqual(try store.corpusReadStateForTesting().count, 1)
        _ = try index.cleanupCorpus(limit: 1)
        try store.revalidateIndexedCorpus(live)
        try store.releaseIndexedCorpus(live)
        try check(root)
    }
    func testMissingReadyComponentIsExplicitAndOldReaderProtectsSupersededUnits() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        let revision = try source(store)
        let reader = try XCTUnwrap(store.captureIndexedCorpus(itemID: revision.itemID))
        _ = try store.commit(
            .init(
                action: .revise, itemID: revision.itemID, expectedRevisionID: revision.revisionID,
                changes: ["body": .text("new corpus text")], operationID: "change-head"))
        XCTAssertThrowsError(try store.revalidateIndexedCorpus(reader)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "revisionConflict")
        }
        let index = try index(root)
        XCTAssertEqual(try index.cleanupCorpus(limit: 1), 0)
        let unit = try ItemIndex.readCorpusUnit(reader, ordinal: 0, limit: 256)
        XCTAssertTrue(String(decoding: unit.data, as: UTF8.self).contains("held corpus reader"))
        try store.releaseIndexedCorpus(reader)
        XCTAssertEqual(try index.cleanupCorpus(limit: 1), 1)
        try index.execute(
            "UPDATE corpus_generation SET state='writing' WHERE id IN (SELECT generation_id FROM corpus_link WHERE item_id=?)",
            [revision.itemID])
        XCTAssertThrowsError(try store.captureIndexedCorpus(itemID: revision.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "indexProjectionPending")
        }
        try check(root)
    }

    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 61313
        var admitted = true
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == alice || uid == getuid() else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture account")
            }
            return .init(
                uid: uid, name: uid == alice ? "alice" : "admin",
                primaryGroupName: "staff", groupIDs: uid == getuid() || admitted ? [71313] : [])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "alice" || name == "admin" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture account")
            }
            return try user(forUID: name == "alice" ? alice : getuid())
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
            }
            return 71313
        }
    }
    func testDeliveryRechecksCurrentACLAndReleaseStillWorksAfterRevocation() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try ItemStore(
            root: root, accounts: accounts,
            attachmentUploadPolicy: .init(maximumStagedBytes: cap, minimumFreeBytes: reserve))
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "groups": .list([.text("staff")]),
            ]), operationID: "access")
        let initial = try source(store)
        let shared = try store.commit(
            .init(
                action: .revise, itemID: initial.itemID,
                expectedRevisionID: initial.revisionID,
                changes: [
                    "permissions": .object([
                        "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                        "group": .text("staff"), "mode": .integer(0o660), "acl": .object([:]),
                    ])
                ], operationID: "share")
        ).revision
        let snapshot = try XCTUnwrap(
            store.withAccess(forUID: accounts.alice) {
                try store.captureIndexedCorpus(itemID: shared.itemID)
            })
        accounts.admitted = false
        XCTAssertThrowsError(
            try store.withAccess(forUID: accounts.alice) { try store.revalidateIndexedCorpus(snapshot) }
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
        }
        try store.releaseIndexedCorpus(snapshot)
        XCTAssertEqual(try store.corpusReadStateForTesting().charge, 0)
        try check(root)
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var events: Set<String> = []
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
        func mark(_ event: String) {
            lock.lock()
            events.insert(event)
            let pending = waiters.removeValue(forKey: event) ?? []
            lock.unlock()
            for waiter in pending { waiter.resume() }
        }
        func wait(_ event: String) async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if events.contains(event) {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[event, default: []].append(continuation)
                    lock.unlock()
                }
            }
        }
    }
    private final class Evidence: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var states: [(Int, Int64)] = []
        func finish() {
            lock.lock()
            finished = true
            lock.unlock()
        }
        func isFinished() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
        func drained(_ count: Int, _ charge: Int64) {
            lock.lock()
            states.append((count, charge))
            lock.unlock()
        }
        func value() -> [(Int, Int64)] {
            lock.lock()
            defer { lock.unlock() }
            return states
        }
    }
    private struct Transport: TractandaClient.ItemTransport {
        let coordinator: ServiceCoordinator
        func send(_ request: Data) async throws -> Data {
            try await coordinator.handle(request, forUID: UInt32(getuid()))
        }
    }
    private struct Configure: Encodable, Sendable {
        let configuration: SemanticConfiguration
        let expectedConfigurationID: String?
    }
    private struct Maintenance: Encodable, Sendable {
        let expectedConfigurationID: String
        let operationID: String
    }
    private struct SemanticReply: Decodable, Sendable { let configurationID: String }
    private struct Start: Encodable, Sendable { let operationID: String }
    private struct Job: Encodable, Sendable { let jobID: String }
    private func heldEndpoint(_ endpoint: String, failRetirement: Bool = false) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try source(store(root)) }
        let gate = Gate()
        let evidence = Evidence()
        let configuration = SemanticConfiguration(
            operationID: "held-config", endpoint: "http://127.0.0.1:1/v1/embeddings",
            model: "fake", modelRevision: "fake", dimensions: 2, documentPrefix: "", queryPrefix: "")
        let coordinator = try await ServiceCoordinator(
            opening: root,
            embeddingProviderForTesting: { _, inputs, _ in
                await withTaskCancellationHandler(
                    operation: {
                        gate.mark("started")
                        await gate.wait("released")
                    }, onCancel: { gate.mark("cancelled") })
                return inputs.map { _ in [1, 0] }
            }, requireInitializedStore: true,
            attachmentUploadPolicy: .init(maximumStagedBytes: cap, minimumFreeBytes: reserve))
        await coordinator.setSemanticReaderDrainHookForTesting { evidence.drained($0, $1) }
        let client = TractandaClient.ItemClient(transport: Transport(coordinator: coordinator))
        do {
            let _: SemanticReply = try await client.call(
                "TractandaSemantic/configure",
                arguments: Configure(configuration: configuration, expectedConfigurationID: nil),
                returning: SemanticReply.self)
            try await coordinator.maintain()
            await gate.wait("started")
            let held = try await coordinator.semanticReaderStateForTesting()
            XCTAssertEqual(held.count, 1)
            XCTAssertGreaterThan(held.charge, 0)
            if failRetirement { try await coordinator.setCorpusReaderReleaseFailureForTesting(true) }
            let operation = Task {
                defer { evidence.finish() }
                if endpoint == "close" {
                    await coordinator.close()
                    return
                }
                if endpoint == "storeRebuild" {
                    var result: StoreRebuildStatus = try await client.call(
                        "TractandaStore/rebuild", arguments: Start(operationID: "reader-rebuild"),
                        returning: StoreRebuildStatus.self)
                    for _ in 0..<600 where !result.isTerminal {
                        try await Task.sleep(for: .milliseconds(10))
                        result = try await client.call(
                            "TractandaStore/rebuildStatus", arguments: Job(jobID: result.jobID),
                            returning: StoreRebuildStatus.self)
                    }
                    XCTAssertEqual(result.state, "completed")
                    XCTAssertTrue(result.indexTrusted)
                } else if endpoint == "configure" {
                    var replacement = configuration
                    replacement.configurationID = Identifier.make()
                    replacement.operationID = "replacement-config"
                    replacement.documentPrefix = "new prefix"
                    let _: SemanticReply = try await client.call(
                        "TractandaSemantic/configure",
                        arguments: Configure(
                            configuration: replacement, expectedConfigurationID: configuration.configurationID
                        ), returning: SemanticReply.self)
                } else {
                    let _: SemanticReply = try await client.call(
                        "TractandaSemantic/" + endpoint,
                        arguments: Maintenance(
                            expectedConfigurationID: configuration.configurationID,
                            operationID: "reader-" + endpoint), returning: SemanticReply.self)
                }
            }
            await gate.wait("cancelled")
            XCTAssertFalse(evidence.isFinished(), "Lifecycle cannot finish while an owned reader is held")
            let stillHeld = try await coordinator.semanticReaderStateForTesting()
            XCTAssertEqual(stillHeld.count, 1)
            if endpoint == "reset", !failRetirement {
                do {
                    let _: SemanticReply = try await client.call(
                        "TractandaSemantic/configure",
                        arguments: Configure(
                            configuration: configuration,
                            expectedConfigurationID: configuration.configurationID),
                        returning: SemanticReply.self)
                    XCTFail("A second lifecycle cannot bypass the held reader drain")
                } catch { XCTAssertEqual((error as? TractandaError)?.code, "serviceBusy") }
            }
            gate.mark("released")
            if failRetirement && endpoint != "close" {
                do {
                    try await operation.value
                    XCTFail("Replacement must refuse failed metadata retirement")
                } catch { XCTAssertEqual((error as? TractandaError)?.code, "injectedReadRetirement") }
                let pending = try await coordinator.semanticReaderStateForTesting()
                XCTAssertGreaterThan(pending.charge, 0)
                XCTAssertEqual(pending.pending, 1)
                try await coordinator.setCorpusReaderReleaseFailureForTesting(false)
                let _: SemanticReply = try await client.call(
                    "TractandaSemantic/" + endpoint,
                    arguments: Maintenance(
                        expectedConfigurationID: configuration.configurationID,
                        operationID: "reader-retry-" + endpoint), returning: SemanticReply.self)
            } else {
                try await operation.value
            }
            if endpoint != "close" { await coordinator.close() }
            if failRetirement && endpoint == "close" {
                XCTAssertEqual(
                    try index(root).corpusReadWorkPage().count, 1,
                    "Close releases ownership after I/O ends even if metadata retirement failed")
                let reopened = try store(root)
                XCTAssertEqual(try reopened.corpusReadStateForTesting().count, 0)
            } else {
                XCTAssertTrue(try index(root).corpusReadWorkPage().isEmpty)
                XCTAssertTrue(evidence.value().contains { $0.0 == 0 && $0.1 == 0 })
            }
            try check(root)
        } catch {
            gate.mark("released")
            try? await coordinator.setCorpusReaderReleaseFailureForTesting(false)
            await coordinator.close()
            throw error
        }
    }
    func testActualCoordinatorCloseWaitsForHeldReader() async throws { try await heldEndpoint("close") }
    func testActualCoordinatorStoreRebuildWaitsForHeldReader() async throws {
        try await heldEndpoint("storeRebuild")
    }
    func testActualCoordinatorSemanticResetWaitsForHeldReader() async throws {
        try await heldEndpoint("reset")
    }
    func testActualCoordinatorSemanticRebuildWaitsForHeldReader() async throws {
        try await heldEndpoint("rebuild")
    }
    func testActualCoordinatorConfigureWaitsForHeldReader() async throws {
        try await heldEndpoint("configure")
    }
    func testMetadataFailureBlocksResetAndRetainsDebt() async throws {
        try await heldEndpoint("reset", failRetirement: true)
    }
    func testCloseWithFencedMetadataFailureReleasesOwnershipAndStartupReclaims() async throws {
        try await heldEndpoint("close", failRetirement: true)
    }
}
