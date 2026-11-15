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
    private func attachedSource(_ store: ItemStore) throws -> (Revision, AttachmentDescriptor) {
        let item = try source(store)
        let bytes = Data([1, 2, 3])
        let upload = try store.beginAttachment(
            .init(
                itemID: item.itemID, expectedRevisionID: item.revisionID,
                operationID: "lifecycle-original", filename: "tiny.pdf", mediaType: "application/pdf",
                byteCount: 3, sha256: PageCorpusInput.digest(bytes)))
        let uploadID = try XCTUnwrap(upload.uploadID)
        _ = try store.appendAttachment(uploadID: uploadID, offset: 0, data: bytes)
        return (try store.finishAttachment(uploadID: uploadID).revision, upload.attachment)
    }
    private func stageOrphan(_ store: ItemStore, revision: Revision, workID: String, root: URL) throws {
        let current = try store.capturePageCorpus(itemID: revision.itemID)
        var fields = revision.fields
        fields["revisionID"] = .text(try UUID.makeVersion1().uuidString.lowercased())
        fields["body"] = .text("unpublished private source")
        let input = try PageCorpusInput(
            storeID: current.input.binding.storeID,
            revision: Revision(fields: fields, formatVersion: revision.formatVersion))
        let spools = root.appendingPathComponent("spools")
        try FileManager.default.createDirectory(
            at: spools, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let spool = try PageCorpusProjection.prepare(
            input: input, provider: current.provider, root: spools,
            policy: .init(maximumBytes: cap, minimumFreeBytes: reserve))
        _ = try ItemIndex.stageCorpus(
            indexPath: store.indexDirectory.appendingPathComponent("items.sqlite").path,
            input: input, prepared: spool, workID: workID,
            writeBoundary: { _ in try self.check(root) }, boundary: { try self.check(root) })
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

    func testPersonalReopenRebuildsDisposableWorkAndPreservesCurrentCanonicalGeneration() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision: Revision
        let stale: IndexedCorpusSnapshot
        let state: String
        let canonicalBefore: [String: Data]
        func canonical(_ store: ItemStore) throws -> [String: Data] {
            var result: [String: Data] = [:]
            for row in try store.exportCatalogueForVerification() {
                result[row.path] = try Data(contentsOf: store.root.appendingPathComponent(row.path))
            }
            return result
        }
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
            state = try store.requireProtocolState()
            canonicalBefore = try canonical(store)
        }
        let store = try store(root)
        let index = try index(root)
        XCTAssertEqual(store.startupRecovery["reason"], "validatedCheckpoint")
        XCTAssertEqual(try store.requireProtocolState(), state)
        let changes = try store.itemChanges(sinceState: state)
        XCTAssertTrue(changes.created.isEmpty)
        XCTAssertTrue(changes.updated.isEmpty)
        XCTAssertTrue(changes.destroyed.isEmpty)
        XCTAssertTrue(try index.corpusReadWorkPage().isEmpty)
        XCTAssertEqual(try store.corpusReadStateForTesting().charge, 0)
        let kinds = Dictionary(uniqueKeysWithValues: try index.corpusWorkPage().map { ($0.workID, $0.kind) })
        // These rows were inserted directly, without a document-job or peer-transfer journal.
        // Validated reuse must retire this unowned work without inventing a durable journal.
        XCTAssertNil(kinds[stageID])
        XCTAssertNil(kinds[discardID])
        XCTAssertEqual(try index.corpusRetainedBytes(discardID), 0)
        XCTAssertEqual(try canonical(store), canonicalBefore)
        // Journal-owned staging/restart is covered by DocumentJobCoordinatorTests'
        // restart/resume and rebuild-fences-producer cases, not these orphan index rows.
        XCTAssertTrue(try index.corpusMatches(store.get(revision.itemID)))
        XCTAssertThrowsError(try store.revalidateIndexedCorpus(stale))
        let live = try XCTUnwrap(store.captureIndexedCorpus(itemID: revision.itemID))
        XCTAssertEqual(live.indexIdentity, stale.indexIdentity)
        XCTAssertEqual(live.links.map(\.component.generationID), stale.links.map(\.component.generationID))
        XCTAssertEqual(try store.corpusReadStateForTesting().count, 1)
        _ = try index.cleanupCorpus(limit: 1)
        try store.revalidateIndexedCorpus(live)
        try store.releaseIndexedCorpus(live)
        try check(root)
    }

    func testPersonalReusePreservesActiveSlotTerminalJournalAndPeerStaging() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let journals: [String: Data]
        let charges: [String: Int64]
        do {
            let store = try store(root)
            let (attached, attachment) = try attachedSource(store)
            var jobs: [String] = []
            let config = String(repeating: "a", count: 64)
            for operation in ["queued", "discarded-slot"] {
                let job = try store.startDocumentJob(
                    .init(
                        itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                        attachmentID: attachment.attachmentID, operationID: operation),
                    identity: .init(), configurationSHA256: config)
                jobs.append(job.jobID)
            }
            let current = try store.capturePageCorpus(itemID: attached.itemID)
            let spools = root.appendingPathComponent("spools")
            try FileManager.default.createDirectory(
                at: spools, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for id in jobs {
                let spool = try PageCorpusProjection.prepare(
                    input: current.input, provider: current.provider, root: spools,
                    policy: .init(maximumBytes: cap, minimumFreeBytes: reserve))
                _ = try ItemIndex.stageCorpus(
                    indexPath: store.indexDirectory.appendingPathComponent("items.sqlite").path,
                    input: current.input, prepared: spool, workID: id,
                    writeBoundary: { _ in try self.check(root) }, boundary: { try self.check(root) })
            }
            _ = try store.controlDocumentJob(
                jobs[1], action: "discard", configurationSHA256: config, deferMaterialWork: true)
            let index = try index(root)
            try index.initializePeerDocumentSchema()
            let source = try AttachmentDocumentSource(
                itemID: attached.itemID, revisionID: attached.revisionID,
                attachmentID: attachment.attachmentID, sha256: attachment.sha256,
                byteCount: 3, mediaType: "application/pdf")
            let document = try AttachmentDocumentRepresentation(
                representationID: UUID.makeVersion1().uuidString.lowercased(),
                attachmentID: source.attachmentID, source: source, extractedAt: Timestamp.now(),
                identity: .init(),
                content: .init(
                    contentID: UUID.makeVersion1().uuidString.lowercased(),
                    manifestSHA256: String(repeating: "b", count: 64),
                    rootSHA256: String(repeating: "c", count: 64), pageCount: 1, totalEncodedBytes: 1,
                    coverage: .init(converted: 0, failed: 1)))
            let peer = try index.beginPeerDocumentCorpus(
                packageID: UUID.makeVersion1().uuidString.lowercased(), document: document
            ) { _ in }
            try index.finishPeerDocumentCorpus(peer, units: 0, bytes: 0)
            try index.touchPeerDocumentCorpus(peer)
            journals = try Dictionary(
                uniqueKeysWithValues: jobs.map { id in
                    (id, try Data(contentsOf: root.appendingPathComponent("document-jobs/\(id)/record.json")))
                })
            charges = try Dictionary(
                uniqueKeysWithValues: (jobs + [peer.workID]).map { id in
                    (id, try index.corpusRetainedBytes(id))
                })
            XCTAssertTrue(charges.values.allSatisfy { $0 > 0 })
            try check(root)
        }
        let store = try store(root)
        let index = try index(root)
        XCTAssertEqual(store.startupRecovery["reason"], "validatedCheckpoint")
        XCTAssertEqual(try store.startupOrphanCorpusStateForTesting().count, 0)
        for (id, bytes) in journals {
            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent("document-jobs/\(id)/record.json")), bytes)
        }
        for (id, retained) in charges { XCTAssertEqual(try index.corpusRetainedBytes(id), retained) }
        try check(root)
    }

    func testTerminalHistoryRemainsExactWhenItsResidualIndexWorkIsRetired() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id: String
        let history: URL
        let bytes: Data
        do {
            let store = try store(root)
            let (revision, attachment) = try attachedSource(store)
            let job = try store.startDocumentJob(
                .init(
                    itemID: revision.itemID, expectedRevisionID: revision.revisionID,
                    attachmentID: attachment.attachmentID, operationID: "terminal-residue"),
                identity: .init(), configurationSHA256: String(repeating: "a", count: 64))
            id = job.jobID
            try stageOrphan(store, revision: revision, workID: id, root: root)
            let recordPath = root.appendingPathComponent("document-jobs/\(id)/record.json")
            var record = try JSON.decode(DocumentJobRecord.self, Data(contentsOf: recordPath))
            record.checkpoint.state = "cancelled"
            record.checkpoint.discarded = true
            // Durable terminal history is authoritative; this models residual derived debt
            // after its active-slot tree was already removed, not a runnable producer.
            let files = DocumentContentFiles(root: root, ownerUID: getuid(), minimumFreeBytes: reserve)
            try DocumentJobRecords(root: root, files: files).archive(record)
            history = root.appendingPathComponent("document-job-history/\(id.prefix(2))/\(id).json")
            bytes = try Data(contentsOf: history)
        }
        let store = try store(root)
        XCTAssertEqual(store.startupRecovery["reason"], "validatedCheckpoint")
        XCTAssertEqual(try index(root).corpusRetainedBytes(id), 0)
        XCTAssertEqual(try Data(contentsOf: history), bytes)
        try check(root)
    }

    func testMalformedHistoryCannotBeMistakenForAnUnjournaledOrphan() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try UUID.makeVersion1().uuidString.lowercased()
        let debt: Int64
        do {
            let store = try store(root)
            try stageOrphan(store, revision: source(store), workID: id, root: root)
            debt = try index(root).corpusRetainedBytes(id)
        }
        let directory = root.appendingPathComponent("document-job-history/\(id.prefix(2))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let history = directory.appendingPathComponent(id + ".json")
        try Data("{".utf8).write(to: history)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: history.path)
        XCTAssertThrowsError(try store(root))
        XCTAssertEqual(try index(root).corpusRetainedBytes(id), debt)
        XCTAssertEqual(try Data(contentsOf: history), Data("{".utf8))
        try check(root)
    }

    func testOrphanDebtIsBoundedAcrossReopenAndDrainsWithoutDocumentJobs() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let workID = try UUID.makeVersion1().uuidString.lowercased()
        let revision: Revision
        let state: String
        do {
            let store = try store(root)
            revision = try source(store)
            let current = try store.capturePageCorpus(itemID: revision.itemID)
            var fields = revision.fields
            fields["revisionID"] = .text(try UUID.makeVersion1().uuidString.lowercased())
            let privateFields = (0..<40).map { "private\($0)" }
            for (number, name) in privateFields.enumerated() { fields[name] = .text("orphan text \(number)") }
            let ancestry = try XCTUnwrap(revision.provenance)
            fields["revisionAncestry"] = try RevisionProvenance(
                kind: ancestry.kind, originReplicaID: ancestry.originReplicaID, parents: ancestry.parents,
                writtenFields: Array(Set(ancestry.writtenFields + privateFields)).sorted(),
                unsetFields: ancestry.unsetFields, frontier: ancestry.frontier,
                mergeProfile: ancestry.mergeProfile, authorityWitness: ancestry.authorityWitness
            ).itemValue
            let input = try PageCorpusInput(
                storeID: current.input.binding.storeID,
                revision: Revision(fields: fields, formatVersion: revision.formatVersion))
            let spools = root.appendingPathComponent("spools")
            try FileManager.default.createDirectory(
                at: spools, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let spool = try PageCorpusProjection.prepare(
                input: input, provider: current.provider, root: spools,
                policy: .init(maximumBytes: cap, minimumFreeBytes: reserve))
            _ = try ItemIndex.stageCorpus(
                indexPath: store.indexDirectory.appendingPathComponent("items.sqlite").path,
                input: input, prepared: spool, workID: workID,
                writeBoundary: { _ in try self.check(root) }, boundary: { try self.check(root) })
            state = try store.requireProtocolState()
        }
        do {
            let store = try store(root)
            let pending = try store.startupOrphanCorpusStateForTesting()
            XCTAssertEqual(store.startupRecovery["reason"], "validatedCheckpoint")
            XCTAssertEqual(pending.count, 1)
            XCTAssertGreaterThan(pending.charge, 0, "Fencing is not a refund of retained bytes")
            XCTAssertLessThanOrEqual(pending.lastUnits, 16)
            XCTAssertEqual(try store.requireProtocolState(), state)
            try check(root)
        }
        let store = try store(root)
        let service = ItemService(store: store)
        XCTAssertEqual(store.startupRecovery["reason"], "validatedCheckpoint")
        XCTAssertGreaterThan(try store.startupOrphanCorpusStateForTesting().charge, 0)
        for _ in 0..<16 {
            if try store.startupOrphanCorpusStateForTesting().count == 0 { break }
            service.maintainSemanticIndex()
            XCTAssertLessThanOrEqual(try store.startupOrphanCorpusStateForTesting().lastUnits, 16)
            try check(root)
        }
        XCTAssertEqual(try store.startupOrphanCorpusStateForTesting().count, 0)
        XCTAssertEqual(try store.startupOrphanCorpusStateForTesting().charge, 0)
        XCTAssertEqual(try index(root).corpusRetainedBytes(workID), 0)
        XCTAssertEqual(try store.get(revision.itemID), revision)
        XCTAssertEqual(try store.requireProtocolState(), state)
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
        func contains(_ event: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return events.contains(event)
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
                    },
                    onCancel: {
                        gate.mark("cancelled")
                        gate.mark("cancelled-or-finished")
                    })
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
                defer {
                    evidence.finish()
                    gate.mark("cancelled-or-finished")
                }
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
            await gate.wait("cancelled-or-finished")
            if evidence.isFinished(), !gate.contains("cancelled") {
                gate.mark("released")
                try await operation.value
                throw TractandaError(
                    "fixtureLifecycleEarlyCompletion",
                    "Lifecycle completed before requesting the held reader's cancellation.")
            }
            XCTAssertTrue(gate.contains("cancelled"))
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
                } catch { XCTAssertEqual((error as? TractandaError)?.code, "serverPartialFail") }
                XCTAssertEqual(
                    try SemanticConfigurationStore(storeRoot: root).load()?.configurationID,
                    configuration.configurationID,
                    "Failed retirement must not replace the active configuration.")
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
