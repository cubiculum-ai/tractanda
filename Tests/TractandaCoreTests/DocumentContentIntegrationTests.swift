import Crypto
import TractandaClient
import XCTest

@testable import TractandaCore

final class DocumentContentIntegrationTests: XCTestCase, @unchecked Sendable {
    private struct Transport: ItemTransport {
        let coordinator: ServiceCoordinator
        let uid: UInt32
        func send(_ request: Data) async throws -> Data { try await coordinator.handle(request, forUID: uid) }
    }
    private actor Gate {
        var entered = false
        var open = false
        func wait() async throws {
            entered = true
            while !open { try await Task.sleep(for: .milliseconds(5)) }
        }
        func awaitEntry() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !entered {
                guard ContinuousClock.now < deadline else {
                    throw TractandaError("testTimeout", "Copy gate did not open")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func release() { open = true }
    }
    private func directory() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "content-integration-" + Identifier.make())
    }
    private func freshStore(_ root: URL) throws -> ItemStore {
        _ = try ItemStore.initializeFresh(root: root)
        let store = try ItemStore(
            root: root,
            attachmentUploadPolicy: .init(minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes),
            revisionProjectionEnabled: true, authorityIntakeEnabled: true)
        try store.setAttachmentReserveForTesting(AttachmentFixtureCapacity.reserveBytes)
        return store
    }
    private func original(_ store: ItemStore, base: Revision, operation: String = "original") throws -> (
        Revision, AttachmentDescriptor
    ) {
        let data = Data("%PDF-1.4\n% synthetic storage fixture; no inference\n".utf8)
        let upload = try store.beginAttachment(
            AttachmentUploadRequest(
                itemID: base.itemID, expectedRevisionID: base.revisionID,
                operationID: operation, filename: "fixture.pdf", mediaType: "application/pdf",
                byteCount: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        _ = try store.appendAttachment(uploadID: XCTUnwrap(upload.uploadID), offset: 0, data: data)
        return (try store.finishAttachment(uploadID: XCTUnwrap(upload.uploadID)).revision, upload.attachment)
    }
    private func page(_ number: Int, source: AttachmentDocumentSource, text: String) throws
        -> DocumentStoredPage
    {
        let parsed = try DoclingDocTagsParser.parse(Data(("<doctag><text>" + text + "</text></doctag>").utf8))
        let geometry = try DocumentPageGeometry(
            sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint", displayWidth: 512,
            displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024, contentLeft: 0, contentTop: 0,
            contentWidth: 2048, contentHeight: 1024)
        return try DocumentStoredPage(
            pageNumber: Int64(number), sourceSHA256: source.sha256,
            page: AttachmentDocumentPage(
                pageNumber: number, geometry: geometry, rasterSHA256: String(repeating: "b", count: 64),
                parsed: parsed, generatedTokens: 512, stopReason: "stop"))
    }
    private func save(
        _ store: ItemStore, root: URL, attached: Revision, descriptor: AttachmentDescriptor, pages: Int = 2,
        text: String = "saved fixture", operation: String = "extract"
    ) throws -> Revision {
        guard
            case .prepared(let snapshot) = try store.prepareAttachmentDocument(
                itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                attachmentID: descriptor.attachmentID, operationID: operation, identity: .init())
        else { throw TractandaError("fixture", "Expected preparation") }
        let contents = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let writer = try contents.begin(
            source: snapshot.source, identity: .init(), maximumWriteBytes: 12 * 1024 * 1024)
        for number in 1...pages { try writer.append(page(number, source: snapshot.source, text: text)) }
        return try store.get(
            {
                let prepared = try writer.preparePublication()
                let corpus = try store.prepareAttachmentDocumentCorpus(snapshot, prepared: prepared)
                return try store.finishAttachmentDocument(snapshot, prepared: prepared, corpus: corpus).itemID
            }())
    }
    private func create(_ store: ItemStore) throws -> Revision {
        try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("storage fixture")], operationID: "item")
        ).revision
    }
    private func request(_ method: String, _ args: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": [[method, args, "test"]],
        ])
    }
    private func object(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSON.encode(value))
    }
    func testLargeCanonicalReferenceHistoryByteAccessAndRebuild() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let (attached, descriptor) = try original(store, base: create(store))
        // Separate large fixture; no duplicate large-copy tree. Expected footprint < 16MiB.
        let saved = try save(
            store, root: root, attached: attached, descriptor: descriptor, pages: 104,
            text: String(repeating: "x", count: 30_000))
        let document = try XCTUnwrap(AttachmentDocumentRepresentation.representations(in: saved.fields).first)
        let reference = try XCTUnwrap(document.content)
        XCTAssertGreaterThan(reference.totalEncodedBytes, 8 * 1024 * 1024)
        XCTAssertLessThan(try JSON.encode(saved).count, 64 * 1024)
        XCTAssertEqual(
            try store.readAttachmentDocument(itemID: saved.itemID, attachmentID: descriptor.attachmentID)
                .totalPageCount, 104)
        let selected = try store.readAttachmentDocument(
            itemID: saved.itemID, attachmentID: descriptor.attachmentID, pageNumber: 97)
        XCTAssertEqual(selected.outcomes?.first?.pageNumber, 97)
        let part = try store.documentContentPart(
            itemID: saved.itemID, attachmentID: descriptor.attachmentID, kind: "page", index: 97, limit: 17)
        XCTAssertEqual(part.data.count, 17)
        let contents = DocumentContentStore(root: root, ownerUID: getuid())
        XCTAssertEqual(
            part.data, try Data(contentsOf: contents.pageURLForTesting(reference, number: 97)).prefix(17))
        let updated = try store.commit(
            CommitRequest(
                action: .revise, itemID: saved.itemID, expectedRevisionID: saved.revisionID,
                changes: ["subject": .text("later")], operationID: "later")
        ).revision
        XCTAssertEqual(
            try store.readAttachmentDocument(
                itemID: saved.itemID, revisionID: saved.revisionID, attachmentID: descriptor.attachmentID,
                pageNumber: 104
            ).outcomes?.first?.pageNumber, 104)
        try store.rebuildIndex()
        XCTAssertEqual(try store.get(saved.itemID).revisionID, updated.revisionID)
        try FileManager.default.removeItem(at: contents.pageURLForTesting(reference, number: 104))
        XCTAssertThrowsError(try store.rebuildIndex())
        XCTAssertThrowsError(try store.get(saved.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "recoveryRequired")
        }
    }
    func testShareCopyDropsInactiveOutputAndNewExtractionPrunesCurrentList() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let (attached, descriptor) = try original(store, base: create(store))
        let saved = try save(store, root: root, attached: attached, descriptor: descriptor)
        let old = try XCTUnwrap(
            AttachmentDocumentRepresentation.representations(in: saved.fields).first?.content)
        let detached = try store.detachAttachment(
            itemID: saved.itemID, expectedRevisionID: saved.revisionID, attachmentID: descriptor.attachmentID,
            operationID: "detach"
        ).revision
        let copy = try store.commit(
            CommitRequest(
                action: .copy, itemID: detached.itemID, expectedRevisionID: detached.revisionID,
                operationID: "share")
        ).revision
        XCTAssertNil(copy.fields["attachmentDocument"])
        XCTAssertFalse(String(decoding: try JSON.encode(copy.fields), as: UTF8.self).contains(old.contentID))
        XCTAssertNotNil(
            try store.get(saved.itemID, revisionID: saved.revisionID).fields["attachmentDocument"])
        let (next, nextDescriptor) = try original(store, base: detached, operation: "next-original")
        let nextSaved = try save(
            store, root: root, attached: next, descriptor: nextDescriptor, operation: "next-extract")
        let documents = try AttachmentDocumentRepresentation.representations(in: nextSaved.fields)
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?.attachmentID, nextDescriptor.attachmentID)
    }
    func testAsynchronousCopyJoinsAndKeepsIndependentCurrentPayloads() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved: Revision
        let originalDescriptor: AttachmentDescriptor
        do {
            let store = try freshStore(root)
            let (attached, descriptor) = try original(store, base: create(store))
            originalDescriptor = descriptor
            saved = try save(store, root: root, attached: attached, descriptor: descriptor)
        }
        let coordinator = try await ServiceCoordinator(opening: root)
        let gate = Gate()
        await coordinator.setAttachmentCopyHookForTesting { try await gate.wait() }
        let operation = CommitRequest(
            action: .copy, itemID: saved.itemID, expectedRevisionID: saved.revisionID, operationID: "copy")
        let raw = try request("TractandaItem/commit", object(operation))
        _ = try await coordinator.handle(raw, forUID: getuid())
        try await gate.awaitEntry()
        _ = try await coordinator.handle(raw, forUID: getuid())
        _ = try await coordinator.handle(request("TractandaStore/info", [:]), forUID: getuid())
        await gate.release()
        let client = TractandaClient.ItemClient(transport: Transport(coordinator: coordinator, uid: getuid()))
        let copied = try await client.commit(operation)
        let descriptor = try XCTUnwrap(AttachmentDescriptor.descriptors(in: copied.revision.fields).first)
        let document = try XCTUnwrap(
            AttachmentDocumentRepresentation.representations(in: copied.revision.fields).first)
        let source = try XCTUnwrap(AttachmentDocumentRepresentation.representations(in: saved.fields).first)
        XCTAssertNotEqual(descriptor.attachmentID, originalDescriptor.attachmentID)
        XCTAssertNotEqual(document.content?.contentID, source.content?.contentID)
        XCTAssertEqual(document.source, source.source)
        let replay = try await client.commit(operation)
        XCTAssertEqual(replay.revision.revisionID, copied.revision.revisionID)
        XCTAssertTrue(replay.wasReplayed)
        let read = try await client.attachmentDocument(
            itemID: copied.revision.itemID, attachmentID: descriptor.attachmentID, pageNumber: 2)
        XCTAssertEqual(read.outcomes?.first?.pageNumber, 2)
        await coordinator.close()
    }
    func testPreparedCopyResumesReceiptsAndCASRefusesChangedSource() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let (attached, descriptor) = try original(store, base: create(store))
        let saved = try save(store, root: root, attached: attached, descriptor: descriptor)
        let operation = CommitRequest(
            action: .copy, itemID: saved.itemID, expectedRevisionID: saved.revisionID, operationID: "copy")
        guard
            case .prepared(let work) = try store.withAccess(
                forUID: getuid(), { try store.prepareAttachmentCopy(operation) })
        else { return XCTFail("Expected copy work") }
        let prepared = try work.perform(progress: AttachmentIntegrityProgress())
        let repeated = try work.perform(progress: AttachmentIntegrityProgress())
        XCTAssertEqual(prepared.originals, repeated.originals)
        XCTAssertEqual(prepared.documents.map(\.stage), repeated.documents.map(\.stage))
        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: saved.itemID, expectedRevisionID: saved.revisionID,
                changes: ["subject": .text("changed")], operationID: "change"))
        XCTAssertThrowsError(
            try store.withAccess(forUID: getuid(), { try store.finishAttachmentCopy(repeated) })
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "revisionConflict")
        }
    }
    func testAbandonedPreparedCopyCountsAgainstNewCopyAndUploadAfterRestart() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var sourceID = ""
        var sourceRevision = ""
        var retainedBytes: Int64 = 0
        do {
            let store = try ItemStore(root: root)
            let (attached, descriptor) = try original(store, base: create(store))
            let saved = try save(store, root: root, attached: attached, descriptor: descriptor)
            sourceID = saved.itemID
            sourceRevision = saved.revisionID
            let request = CommitRequest(
                action: .copy, itemID: saved.itemID, expectedRevisionID: saved.revisionID,
                operationID: "abandoned-copy")
            guard
                case .prepared(let work) = try store.withAccess(
                    forUID: getuid(), { try store.prepareAttachmentCopy(request) })
            else { return XCTFail("Expected copy work") }
            _ = try work.perform(progress: AttachmentIntegrityProgress())
            let measured = try StagingByteQuota(root: root, ownerUID: getuid(), maximumBytes: .max)
            retainedBytes = measured.usedBytes
            XCTAssertGreaterThan(retainedBytes, descriptor.byteCount)
        }
        let store = try ItemStore(
            root: root,
            attachmentUploadPolicy: AttachmentUploadPolicy(
                maximumStagedBytes: retainedBytes + 1,
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
        let another = CommitRequest(
            action: .copy, itemID: sourceID, expectedRevisionID: sourceRevision, operationID: "another-copy")
        XCTAssertThrowsError(
            try store.withAccess(forUID: getuid(), { try store.prepareAttachmentCopy(another) })
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        let data = Data([1, 2])
        XCTAssertThrowsError(
            try store.beginAttachment(
                AttachmentUploadRequest(
                    itemID: sourceID, expectedRevisionID: sourceRevision, operationID: "another-upload",
                    filename: "tiny", mediaType: "application/octet-stream", byteCount: 2,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
    }
    func testPublishedCopyBeforeFinalCASRemainsQuotaChargedAcrossRestart() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var request: CommitRequest!
        var retainedBytes: Int64 = 0
        do {
            let store = try ItemStore(root: root)
            let (attached, descriptor) = try original(store, base: create(store))
            let saved = try save(store, root: root, attached: attached, descriptor: descriptor)
            request = CommitRequest(
                action: .copy, itemID: saved.itemID,
                expectedRevisionID: saved.revisionID, operationID: "published-copy")
            guard
                case .prepared(let work) = try store.withAccess(
                    forUID: getuid(), { try store.prepareAttachmentCopy(request) })
            else { return XCTFail("Expected copy work") }
            let prepared = try work.perform(progress: AttachmentIntegrityProgress())
            store.beforeAttachmentCopyCommitForTesting = {
                throw TractandaError("injected", "Canonical dependencies published before final item CAS")
            }
            XCTAssertThrowsError(
                try store.withAccess(forUID: getuid(), { try store.finishAttachmentCopy(prepared) }))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath:
                        root.appendingPathComponent(
                            "attachments/.staging/" + prepared.originals[0].attachmentID + ".stage"
                        ).path))
            let measured = try StagingByteQuota(root: root, ownerUID: getuid(), maximumBytes: .max)
            retainedBytes = measured.usedBytes
            XCTAssertGreaterThan(retainedBytes, prepared.documents[0].byteCount)
        }
        let store = try ItemStore(
            root: root,
            attachmentUploadPolicy: AttachmentUploadPolicy(
                maximumStagedBytes: retainedBytes + 1,
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
        let another = CommitRequest(
            action: .copy, itemID: request.itemID,
            expectedRevisionID: request.expectedRevisionID, operationID: "another-copy")
        XCTAssertThrowsError(
            try store.withAccess(forUID: getuid(), { try store.prepareAttachmentCopy(another) })
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        guard
            case .prepared(let work) = try store.withAccess(
                forUID: getuid(), { try store.prepareAttachmentCopy(request) })
        else { return XCTFail("Expected retained copy retry") }
        let prepared = try work.perform(progress: AttachmentIntegrityProgress())
        let result = try store.withAccess(forUID: getuid(), { try store.finishAttachmentCopy(prepared) })
        XCTAssertFalse(result.wasReplayed)
        let measured = try StagingByteQuota(root: root, ownerUID: getuid(), maximumBytes: .max)
        XCTAssertLessThan(
            measured.usedBytes, retainedBytes, "Completed CAS releases its retained copy budget")
    }
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 61992
        private let lock = NSLock()
        private var allowed = true
        func revoke() {
            lock.lock()
            allowed = false
            lock.unlock()
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == getuid() || uid == alice else {
                throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            lock.lock()
            let groups: Set<UInt32> = uid == getuid() || allowed ? [71992] : []
            lock.unlock()
            return AccountIdentity(
                uid: uid, name: uid == alice ? "alice" : "admin", primaryGroupName: "staff", groupIDs: groups)
        }
        func user(named name: String) throws -> AccountIdentity {
            guard ["admin", "alice"].contains(name) else {
                throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return try user(forUID: name == "alice" ? alice : getuid())
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Unknown group") }
            return 71992
        }
    }
    func testFreshReadPermissionPreventsCopyPublicationAndHistoricalPartDisclosure() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try ItemStore(
            root: root, accounts: accounts,
            attachmentUploadPolicy: AttachmentUploadPolicy(
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
        _ = try store.configureAccess(
            .object(["profile": .text(AccessConfiguration.profile), "groups": .list([.text("staff")])]),
            operationID: "access")
        let base = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: [
                    "permissions": .object([
                        "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                        "group": .text("staff"), "mode": .integer(0o640), "acl": .object([:]),
                    ])
                ], operationID: "item")
        ).revision
        let (attached, descriptor) = try original(store, base: base)
        let saved = try save(store, root: root, attached: attached, descriptor: descriptor)
        let operation = CommitRequest(
            action: .copy, itemID: saved.itemID, expectedRevisionID: saved.revisionID, operationID: "copy")
        guard
            case .prepared(let work) = try store.withAccess(
                forUID: accounts.alice, { try store.prepareAttachmentCopy(operation) })
        else { return XCTFail("Expected preparation") }
        let prepared = try work.perform(progress: AttachmentIntegrityProgress())
        accounts.revoke()
        XCTAssertThrowsError(
            try store.withAccess(forUID: accounts.alice, { try store.finishAttachmentCopy(prepared) })
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        XCTAssertThrowsError(
            try store.withAccess(
                forUID: accounts.alice,
                {
                    try store.documentContentPart(
                        itemID: saved.itemID, revisionID: saved.revisionID,
                        attachmentID: descriptor.attachmentID, kind: "manifest")
                })
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        let payloads = try AttachmentPayloadStore(root: root, ownerUID: getuid())
        XCTAssertNil(try payloads.resolvedPayloadPath(prepared.originals[0].attachmentID))
        XCTAssertEqual(try store.get(saved.itemID).revisionID, saved.revisionID)
    }

    func testCopyReceiptsSurviveActualStoreRestart() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation: CommitRequest
        let expectedIDs: [String]
        do {
            let store = try AttachmentFixtureCapacity.makeStore(root: root)
            let (attached, descriptor) = try original(store, base: create(store))
            let saved = try save(store, root: root, attached: attached, descriptor: descriptor)
            operation = CommitRequest(
                action: .copy, itemID: saved.itemID, expectedRevisionID: saved.revisionID, operationID: "copy"
            )
            guard
                case .prepared(let work) = try store.withAccess(
                    forUID: getuid(), { try store.prepareAttachmentCopy(operation) })
            else { return XCTFail("Expected work") }
            let prepared = try work.perform(progress: AttachmentIntegrityProgress())
            expectedIDs = prepared.originals.map(\.attachmentID)
        }
        let reopened = try AttachmentFixtureCapacity.makeStore(root: root)
        guard
            case .prepared(let work) = try reopened.withAccess(
                forUID: getuid(), { try reopened.prepareAttachmentCopy(operation) })
        else { return XCTFail("Expected resumed work") }
        let prepared = try work.perform(progress: AttachmentIntegrityProgress())
        XCTAssertEqual(prepared.originals.map(\.attachmentID), expectedIDs)
        let committed = try reopened.withAccess(
            forUID: getuid(), { try reopened.finishAttachmentCopy(prepared) })
        let descriptor = try XCTUnwrap(AttachmentDescriptor.descriptors(in: committed.revision.fields).first)
        XCTAssertEqual(
            try reopened.readAttachmentDocument(
                itemID: committed.revision.itemID, attachmentID: descriptor.attachmentID, pageNumber: 2
            ).outcomes?.first?.pageNumber, 2)
    }

}
