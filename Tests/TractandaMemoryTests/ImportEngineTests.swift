import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaMemory

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Synthetic bounded fixture shared only by this test target. No user's memory directories are read.
final class MemoryImportFixture {
    let root: URL
    let source: URL
    let store: ItemStore
    let service: ItemService
    let client: ItemClient
    let transport: CountingImportTransport
    let limits = ImportLimits(
        maximumOriginalBytes: 2 * 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024)

    init(accounts: any AccountDirectory = SystemAccountDirectory(), peerUID: UInt32? = nil) throws {
        let parent =
            ProcessInfo.processInfo.environment["TRACTANDA_TEST_FIXTURE_ROOT"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? FileManager.default.temporaryDirectory
        var space = statvfs()
        guard statvfs(parent.path, &space) == 0 else {
            throw TractandaError("fixtureCapacity", "Cannot inspect synthetic fixture free space.")
        }
        let free = UInt64(space.f_bavail).multipliedReportingOverflow(by: UInt64(space.f_frsize))
        guard !free.overflow, free.partialValue >= 10 * 1024 * 1024 * 1024 + 32 * 1024 * 1024 else {
            throw TractandaError(
                "fixtureCapacity", "Synthetic import tests require 10 GiB reserve plus a 32 MiB fixture cap.")
        }
        root = parent.appendingPathComponent("memory-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let caller = peerUID ?? getuid()
        let admittedNames = try Set([
            accounts.user(forUID: getuid()).name, accounts.user(forUID: caller).name,
        ]).sorted()
        let policy = ItemValue.object([
            "profile": .text(AccessConfiguration.profile), "users": .list(admittedNames.map(ItemValue.text)),
        ])
        var recovery = PersonalRecoveryIndex.Limits()
        recovery.maximumDerivedBytes = 32 * 1024 * 1024
        store = try ItemStore(
            personalRoot: root.appendingPathComponent("store", isDirectory: true),
            opening: .fresh(policy), accounts: accounts,
            attachmentUploadPolicy: .init(minimumFreeBytes: 10 * 1024 * 1024 * 1024), recoveryLimits: recovery
        )
        service = ItemService(store: store)
        let fixtureService = service
        client = ItemClient(transport: { fixtureService.handle($0, peerUID: caller) })
        transport = CountingImportTransport(
            CoreImportTransport(client: client, endpoint: "fixture-local-peer"))
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func record(_ id: String, body: String, links: [ImportLink] = [], metadata: [String: ItemValue] = [:])
        throws -> ImportRecord
    {
        let path = id + ".md"
        let data = Data(body.utf8)
        try data.write(to: source.appendingPathComponent(path))
        return ImportRecord(
            sourceID: id,
            original: ImportOriginal(
                relativePath: path, mediaType: "text/markdown", byteCount: Int64(data.count),
                sha256: ImportHash.bytes(data)),
            projection: ["subject": .text(id), "body": .text(body)], links: links, metadata: metadata)
    }
    func plan(
        _ records: [ImportRecord], namespace: String = "fixture-memory", renames: [String: String] = [:]
    ) -> ImportPlan {
        ImportPlan(
            namespace: namespace, adapter: "fixture-v1", sourceRoot: source.path, records: records,
            renames: renames, limits: limits)
    }
    func journal(_ name: String = UUID().uuidString) throws -> ImportJournal {
        try ImportJournal(
            directory: root.appendingPathComponent("journal-" + name), create: true, limits: limits)
    }
    func revise(_ itemID: String, _ changes: [String: ItemValue]) throws -> Revision {
        let current = try store.get(itemID)
        return try store.commit(
            CommitRequest(
                action: .revise, itemID: itemID, expectedRevisionID: current.revisionID, changes: changes,
                operationID: "fixture-" + UUID().uuidString)
        ).revision
    }
    var engine: ImportEngine { ImportEngine(transport: transport) }
}

final class CountingImportTransport: ImportTransport {
    let base: CoreImportTransport
    var commits = 0
    var discoveries = 0
    var chunks = 0
    var originals = 0
    var loseNextCommit = false
    var loseNextChunk = false
    var loseNextFinish = false
    var replacementBinding: ImportBinding?
    init(_ base: CoreImportTransport) { self.base = base }
    func binding() throws -> ImportBinding { try replacementBinding ?? base.binding() }
    func imported(namespace: String, limits: ImportLimits) throws -> [ImportItemSnapshot] {
        discoveries += 1
        return try base.imported(namespace: namespace, limits: limits)
    }
    func revision(itemID: String, revisionID: String?) throws -> ImportItemSnapshot {
        try base.revision(itemID: itemID, revisionID: revisionID)
    }
    func commit(_ request: CommitRequest) throws -> MutationReceipt {
        commits += 1
        let receipt = try base.commit(request)
        if loseNextCommit {
            loseNextCommit = false
            throw TractandaError("fixtureLostReply", "Committed reply was lost.")
        }
        return receipt
    }
    func beginAttachment(_ request: AttachmentUploadRequest) throws -> AttachmentUploadResult {
        try base.beginAttachment(request)
    }
    func appendAttachment(uploadID: String, offset: Int64, data: Data) throws -> Int64 {
        chunks += 1
        let next = try base.appendAttachment(uploadID: uploadID, offset: offset, data: data)
        if loseNextChunk {
            loseNextChunk = false
            throw TractandaError("fixtureLostReply", "Uploaded chunk reply was lost.")
        }
        return next
    }
    func finishAttachment(uploadID: String) throws -> AttachmentCommitResult {
        originals += 1
        let receipt = try base.finishAttachment(uploadID: uploadID)
        if loseNextFinish {
            loseNextFinish = false
            throw TractandaError("fixtureLostReply", "Original publication reply was lost.")
        }
        return receipt
    }
    func attachmentContent(itemID: String, revisionID: String, attachmentID: String, offset: Int64) throws
        -> AttachmentContentResult
    {
        try base.attachmentContent(
            itemID: itemID, revisionID: revisionID, attachmentID: attachmentID, offset: offset)
    }
}

final class ImportEngineTests: XCTestCase {
    func testNamespaceDiscoveryCountStaysConstantAsSelectedRecordCountGrows() throws {
        for count in [1, 6] {
            let fixture = try MemoryImportFixture()
            let records = try (0..<count).map {
                try fixture.record("record-\($0)", body: "bounded source \($0)")
            }
            let before = fixture.transport.discoveries
            let report = try fixture.engine.apply(fixture.plan(records), journal: fixture.journal())
            XCTAssertEqual(report.completeCount, count)
            XCTAssertEqual(
                fixture.transport.discoveries - before, 3,
                "Initial, pre-link and final discovery must not grow with creates.")
        }
    }

    func testDiscoveryAndExactReadbackUseSingleContentDTOUnderSmallWireBudget() throws {
        let fixture = try MemoryImportFixture()
        let records = try (0..<6).map {
            try fixture.record("record-\($0)", body: String(repeating: "x", count: 2048))
        }
        let plan = fixture.plan(records)
        let imported = try fixture.engine.apply(plan, journal: fixture.journal())
        let fixtureService = fixture.service
        var maximumIDs = 0
        var contentReads = 0
        let bounded = ItemClient(transport: { request in
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
            let calls = try XCTUnwrap(envelope["methodCalls"] as? [[Any]])
            let response = fixtureService.handle(request, peerUID: getuid())
            for call in calls
            where ["TractandaItem/get", "TractandaRevision/get"].contains(call[0] as? String ?? "") {
                let arguments = try XCTUnwrap(call[1] as? [String: Any])
                let ids = arguments["ids"] as? [String] ?? []
                maximumIDs = max(maximumIDs, ids.count)
                if !ids.isEmpty {
                    contentReads += 1
                    XCTAssertEqual(arguments["projection"] as? String, "content")
                    guard response.count <= 16_384 else {
                        throw TractandaError(
                            "fixtureWireBudget",
                            "Native response exceeds the deliberately small test wire budget.")
                    }
                }
            }
            return response
        })
        let engine = ImportEngine(client: bounded, endpoint: "fixture-local-peer")
        XCTAssertEqual(
            try engine.preview(plan).outcomes.map(\.disposition),
            Array(repeating: .unchanged, count: records.count))
        let first = try XCTUnwrap(imported.outcomes.first)
        let snapshot = try CoreImportTransport(client: bounded, endpoint: "fixture-local-peer").revision(
            itemID: XCTUnwrap(first.itemID), revisionID: first.revisionID)
        XCTAssertNil(snapshot.fields["requestIdentity"])
        XCTAssertNil(snapshot.fields["revisionAncestry"])
        XCTAssertEqual(maximumIDs, 1)
        XCTAssertEqual(contentReads, records.count + 1)
    }

    private final class OrdinaryAccounts: AccountDirectory {
        let alice: UInt32 = 51987
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == getuid() || uid == alice else {
                throw TractandaError("unresolvedPrincipal", "Unknown synthetic account.")
            }
            return AccountIdentity(
                uid: uid, name: uid == alice ? "alice" : "admin", primaryGroupName: "staff", groupIDs: [71987]
            )
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "alice" || name == "admin" else {
                throw TractandaError("unresolvedPrincipal", "Unknown synthetic account.")
            }
            return try user(forUID: name == "alice" ? alice : getuid())
        }
        func groupID(named name: String) throws -> UInt32 { 71987 }
    }

    func testOrdinaryAdmittedAccountImportsWithoutAdministratorAPI() throws {
        let accounts = OrdinaryAccounts()
        let fixture = try MemoryImportFixture(accounts: accounts, peerUID: accounts.alice)
        let info = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixture.client.call("TractandaStore/info")) as? [String: Any])
        XCTAssertEqual(info["callerIsAdministrator"] as? Bool, false)
        XCTAssertEqual(info["persistenceProfile"] as? String, "personal-workgroup")
        XCTAssertEqual(try fixture.transport.binding().principal, "alice")
        let report = try fixture.engine.apply(
            fixture.plan([fixture.record("note", body: "ordinary account memory")]),
            journal: fixture.journal())
        XCTAssertEqual(report.outcomes.first?.disposition, .create)
        let id = try XCTUnwrap(report.outcomes.first?.itemID)
        XCTAssertEqual(try fixture.client.revision(for: id).fields["actor"]?.string, "user:alice")
    }

    func testCyclicLinksOriginalBytesNoOpAndCanonicalRecoveryAfterRebuild() throws {
        let fixture = try MemoryImportFixture()
        let a = try fixture.record(
            "a", body: "[b](b.md#section)",
            links: [
                ImportLink(
                    originalTarget: "b.md#section", targetSourceID: "b", fragment: "section", sourceLine: 1,
                    sourceColumn: 1)
            ])
        let b = try fixture.record(
            "b", body: "[a](a.md)", links: [ImportLink(originalTarget: "a.md", targetSourceID: "a")])
        let plan = fixture.plan([a, b])
        let report = try fixture.engine.apply(plan, journal: fixture.journal())
        XCTAssertEqual(report.outcomes.map(\.disposition), [.create, .create])
        let aID = try XCTUnwrap(report.outcomes.first?.itemID)
        let bID = try XCTUnwrap(report.outcomes.last?.itemID)
        let savedA = try fixture.store.get(aID)
        XCTAssertEqual(savedA.fields["importState"]?.string, "complete")
        let link = try XCTUnwrap(savedA.fields["importLinks"]?.array?.first?.map)
        XCTAssertEqual(link["target"], .reference(ItemReference(bID)))
        XCTAssertEqual(link["fragment"]?.string, "section")
        XCTAssertEqual(link["sourceLine"]?.integerValue, 1)
        XCTAssertEqual(
            try fixture.store.get(bID).fields["importLinks"]?.array?.first?.map?["target"],
            .reference(ItemReference(aID)))
        let original = try XCTUnwrap(AttachmentDescriptor.descriptors(in: savedA.fields).first)
        XCTAssertEqual(
            try fixture.client.attachmentContent(
                itemID: aID, revisionID: savedA.revisionID, attachmentID: original.attachmentID
            ).data, Data(a.projection["body"]!.string!.utf8))
        let mutations = fixture.transport.commits
        try fixture.store.rebuildIndex()
        let repeated = try fixture.engine.apply(plan, journal: fixture.journal())
        XCTAssertEqual(repeated.outcomes.map(\.disposition), [.unchanged, .unchanged])
        XCTAssertEqual(fixture.transport.commits, mutations)
        try FileManager.default.removeItem(at: fixture.source)
        XCTAssertEqual(try fixture.engine.preview(plan).outcomes.map(\.itemID), [aID, bID])
    }

    func testSourceAndLocalConflictPreservesContentAndUnchangedLocalDivergenceIsInert() throws {
        let fixture = try MemoryImportFixture()
        let initial = try fixture.record("note", body: "source one")
        let plan = fixture.plan([initial])
        let imported = try fixture.engine.apply(plan, journal: fixture.journal())
        let id = try XCTUnwrap(imported.outcomes.first?.itemID)
        _ = try fixture.revise(id, ["body": .text("local correction")])
        let mutations = fixture.transport.commits
        XCTAssertEqual(
            try fixture.engine.apply(plan, journal: fixture.journal()).outcomes.first?.disposition,
            .localDivergence)
        let changed = try fixture.record("note", body: "source two")
        XCTAssertEqual(
            try fixture.engine.apply(fixture.plan([changed]), journal: fixture.journal()).outcomes.first?
                .disposition, .conflict)
        XCTAssertEqual(fixture.transport.commits, mutations)
        XCTAssertEqual(try fixture.store.get(id).fields["body"]?.string, "local correction")
        XCTAssertEqual(try AttachmentDescriptor.descriptors(in: fixture.store.get(id).fields).count, 1)
    }

    func testChangedSourceUpdatesWhileUnrelatedAnnotationsAndOriginalHistoryRemain() throws {
        let fixture = try MemoryImportFixture()
        let first = try fixture.engine.apply(
            fixture.plan([fixture.record("note", body: "old")]), journal: fixture.journal())
        let id = try XCTUnwrap(first.outcomes.first?.itemID)
        _ = try fixture.revise(id, ["localAnnotation": .text("keep this")])
        let changed = try fixture.record("note", body: "new")
        let updated = try fixture.engine.apply(fixture.plan([changed]), journal: fixture.journal())
        XCTAssertEqual(updated.outcomes.first?.disposition, .update)
        let saved = try fixture.store.get(id)
        XCTAssertEqual(saved.fields["body"]?.string, "new")
        XCTAssertEqual(saved.fields["localAnnotation"]?.string, "keep this")
        XCTAssertEqual(try AttachmentDescriptor.descriptors(in: saved.fields).count, 2)
    }

    func testLostCreateReplyResumesExactIntentWithoutSecondItem() throws {
        let fixture = try MemoryImportFixture()
        let plan = fixture.plan([try fixture.record("note", body: "original")])
        let journal = try fixture.journal()
        fixture.transport.loseNextCommit = true
        XCTAssertThrowsError(try fixture.engine.apply(plan, journal: journal))
        XCTAssertEqual(try journal.load().report.outcomes.first?.disposition, .incomplete)
        XCTAssertEqual(try journal.load().report.completeCount, 0)
        let pending = try XCTUnwrap(journal.load().records["note"]?.pendingCommit)
        XCTAssertNotNil(try journal.load().records["note"]?.pendingCommitBytes)
        XCTAssertEqual(try fixture.engine.preview(plan).outcomes.first?.disposition, .incomplete)
        let resumed = try fixture.engine.resume(journal: journal)
        XCTAssertEqual(resumed.outcomes.first?.disposition, .create)
        let found = try fixture.transport.imported(namespace: plan.namespace, limits: fixture.limits)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(
            try fixture.client.history(itemID: found[0].itemID).list.contains(where: {
                $0.fields["operationID"]?.string == pending.operationID
            }))
        XCTAssertEqual(try fixture.engine.preview(plan).outcomes.first?.disposition, .unchanged)
    }

    func testLostChunkAndFinishRepliesResumeOriginalWithoutDuplicateAttachment() throws {
        for loseChunk in [true, false] {
            let fixture = try MemoryImportFixture()
            let plan = fixture.plan([try fixture.record("note", body: String(repeating: "x", count: 300_000))]
            )
            let journal = try fixture.journal()
            fixture.transport.loseNextChunk = loseChunk
            fixture.transport.loseNextFinish = !loseChunk
            XCTAssertThrowsError(try fixture.engine.apply(plan, journal: journal))
            XCTAssertNotNil(try journal.load().records["note"]?.pendingUpload)
            let resumed = try fixture.engine.resume(journal: journal)
            let id = try XCTUnwrap(resumed.outcomes.first?.itemID)
            XCTAssertEqual(try AttachmentDescriptor.descriptors(in: fixture.store.get(id).fields).count, 1)
            XCTAssertEqual(try fixture.engine.preview(plan).outcomes.first?.disposition, .unchanged)
        }
    }

    func testLaterTargetRefreshesLinksAndMappingOnlyChangesReuseOriginalBytes() throws {
        let fixture = try MemoryImportFixture()
        let a = try fixture.record(
            "a", body: "[b](b.md)", links: [ImportLink(originalTarget: "b.md", targetSourceID: "b")])
        let first = try fixture.engine.apply(fixture.plan([a]), journal: fixture.journal())
        let aID = try XCTUnwrap(first.outcomes.first?.itemID)
        XCTAssertEqual(
            try fixture.store.get(aID).fields["importLinks"]?.array?.first?.map?["resolution"]?.string,
            "missing")
        let b = try fixture.record("b", body: "target")
        let combined = try fixture.engine.apply(fixture.plan([a, b]), journal: fixture.journal())
        let bID = try XCTUnwrap(combined.outcomes.last?.itemID)
        XCTAssertEqual(combined.outcomes.first?.disposition, .update)
        XCTAssertEqual(
            try fixture.store.get(aID).fields["importLinks"]?.array?.first?.map?["target"],
            .reference(ItemReference(bID)))
        XCTAssertEqual(try AttachmentDescriptor.descriptors(in: fixture.store.get(aID).fields).count, 1)
        var remapped = a
        remapped.metadata["adapterMappingCorrection"] = .text("retained as provenance")
        let originalPublishes = fixture.transport.originals
        XCTAssertEqual(
            try fixture.engine.apply(fixture.plan([remapped, b]), journal: fixture.journal()).outcomes.first?
                .disposition, .update)
        XCTAssertEqual(fixture.transport.originals, originalPublishes)
        let mutations = fixture.transport.commits
        XCTAssertEqual(
            try fixture.engine.apply(fixture.plan([remapped, b]), journal: fixture.journal()).outcomes.map(
                \.disposition), [.unchanged, .unchanged])
        XCTAssertEqual(fixture.transport.commits, mutations)
    }

    func testLostFinishOrFinalChunkReplyReconcilesWithoutLocalOriginalDirectory() throws {
        for lostFinish in [true, false] {
            let fixture = try MemoryImportFixture()
            let plan = fixture.plan([try fixture.record("note", body: "all selected bytes fit in one chunk")])
            let journal = try fixture.journal()
            fixture.transport.loseNextFinish = lostFinish
            fixture.transport.loseNextChunk = !lostFinish
            XCTAssertThrowsError(try fixture.engine.apply(plan, journal: journal))
            try FileManager.default.removeItem(at: fixture.source)
            let completed = try fixture.engine.resume(journal: journal)
            XCTAssertEqual(completed.outcomes.first?.disposition, .create)
            XCTAssertEqual(try fixture.engine.preview(plan).outcomes.first?.disposition, .unchanged)
        }
    }

    func testExpiredUncommittedUploadUsesFreshHandleWithSameExactIntent() throws {
        let fixture = try MemoryImportFixture()
        let now = Date()
        fixture.store.attachmentClockForTesting = { now }
        let plan = fixture.plan([try fixture.record("note", body: String(repeating: "x", count: 300_000))])
        let journal = try fixture.journal()
        fixture.transport.loseNextChunk = true
        XCTAssertThrowsError(try fixture.engine.apply(plan, journal: journal))
        let before = try XCTUnwrap(journal.load().records["note"])
        XCTAssertNotNil(before.uploadID)
        fixture.store.attachmentClockForTesting = { now.addingTimeInterval(7200) }
        let completed = try fixture.engine.resume(journal: journal)
        let id = try XCTUnwrap(completed.outcomes.first?.itemID)
        let descriptors = try AttachmentDescriptor.descriptors(in: fixture.store.get(id).fields)
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertNotEqual(descriptors.first?.attachmentID, before.uploadAttachmentID)
        XCTAssertEqual(try fixture.engine.preview(plan).outcomes.first?.disposition, .unchanged)
    }

    func testMissingExactJournalLeavesIncompleteCanonicalMappingForReconciliation() throws {
        let fixture = try MemoryImportFixture()
        let plan = fixture.plan([try fixture.record("note", body: "original")])
        fixture.transport.loseNextCommit = true
        do {
            let journal = try fixture.journal("lost")
            XCTAssertThrowsError(try fixture.engine.apply(plan, journal: journal))
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("journal-lost"))
        let mutations = fixture.transport.commits
        let result = try fixture.engine.apply(plan, journal: fixture.journal())
        XCTAssertEqual(result.outcomes.first?.disposition, .incomplete)
        XCTAssertEqual(fixture.transport.commits, mutations)
        XCTAssertEqual(
            try fixture.transport.imported(namespace: plan.namespace, limits: fixture.limits).count, 1)
    }

    func testRenameUsesExistingServerIDAndDeletedMappingIsNeverRestored() throws {
        let fixture = try MemoryImportFixture()
        let first = try fixture.engine.apply(
            fixture.plan([fixture.record("old", body: "same")]), journal: fixture.journal())
        let id = try XCTUnwrap(first.outcomes.first?.itemID)
        let renamed = fixture.plan([try fixture.record("new", body: "same")], renames: ["old": "new"])
        let result = try fixture.engine.apply(renamed, journal: fixture.journal())
        XCTAssertEqual(result.outcomes.first?.itemID, id)
        XCTAssertEqual(result.outcomes.first?.disposition, .update)
        XCTAssertEqual(try fixture.store.get(id).fields["importSourceIDAliases"]?.array, [.text("old")])
        _ = try fixture.revise(id, ["isDeleted": .boolean(true)])
        let mutations = fixture.transport.commits
        XCTAssertEqual(
            try fixture.engine.apply(renamed, journal: fixture.journal()).outcomes.first?.disposition,
            .tombstone)
        XCTAssertEqual(fixture.transport.commits, mutations)
        XCTAssertTrue(try fixture.store.get(id).isDeleted)
    }

    func testDuplicateCanonicalSourceIdentityIsReportedAndNamespacesRemainSeparate() throws {
        let fixture = try MemoryImportFixture()
        let record = try fixture.record("note", body: "source")
        let plan = fixture.plan([record])
        let first = try fixture.engine.apply(plan, journal: fixture.journal())
        let id = try XCTUnwrap(first.outcomes.first?.itemID)
        XCTAssertEqual(
            try fixture.engine.preview(fixture.plan([record], namespace: "another-source")).outcomes.first?
                .disposition, .create)
        let fields = try fixture.store.get(id).fields.filter { !ImportFields.forbidden.contains($0.key) }
        _ = try fixture.store.commit(
            CommitRequest(classID: "Item", changes: fields, operationID: "fixture-duplicate"))
        let mutations = fixture.transport.commits
        XCTAssertEqual(
            try fixture.engine.apply(plan, journal: fixture.journal()).outcomes.first?.disposition, .duplicate
        )
        XCTAssertEqual(fixture.transport.commits, mutations)
    }

    func testRetainedIntentRefusesChangedStorePrincipalOrEndpoint() throws {
        let fixture = try MemoryImportFixture()
        let plan = fixture.plan([try fixture.record("note", body: "source")])
        let journal = try fixture.journal()
        fixture.transport.loseNextCommit = true
        XCTAssertThrowsError(try fixture.engine.apply(plan, journal: journal))
        let original = try fixture.transport.binding()
        for binding in [
            ImportBinding(storeID: "other-store", principal: original.principal, endpoint: original.endpoint),
            ImportBinding(storeID: original.storeID, principal: "other-user", endpoint: original.endpoint),
            ImportBinding(storeID: original.storeID, principal: original.principal, endpoint: "other-peer"),
        ] {
            fixture.transport.replacementBinding = binding
            let attempts = fixture.transport.commits
            XCTAssertThrowsError(try fixture.engine.resume(journal: journal))
            XCTAssertEqual(fixture.transport.commits, attempts)
        }
        fixture.transport.replacementBinding = nil
        XCTAssertEqual(try fixture.engine.resume(journal: journal).outcomes.first?.disposition, .create)
    }
}
