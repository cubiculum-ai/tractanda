import Crypto
import XCTest

@testable import TractandaCore

final class DocumentContentStorageTests: XCTestCase {
    private func fixture() throws -> (URL, DocumentContentStore, AttachmentDocumentSource) {
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "document-content-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = try UUID.makeVersion1().uuidString.lowercased()
        let source = try AttachmentDocumentSource(
            itemID: id, revisionID: id, attachmentID: id,
            sha256: String(repeating: "a", count: 64), byteCount: 100, mediaType: "application/pdf")
        return (
            root,
            DocumentContentStore(
                root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes),
            source
        )
    }
    private func page(_ number: Int, source: AttachmentDocumentSource, text: String = "synthetic saved page")
        throws -> DocumentStoredPage
    {
        let parsed = try DoclingDocTagsParser.parse(Data(("<doctag><text>" + text + "</text></doctag>").utf8))
        let geometry = try DocumentPageGeometry(
            sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint",
            displayWidth: 512, displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024,
            contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024)
        let page = try AttachmentDocumentPage(
            pageNumber: number, geometry: geometry,
            rasterSHA256: String(repeating: "b", count: 64), parsed: parsed, generatedTokens: 512,
            stopReason: "stop")
        return try DocumentStoredPage(pageNumber: Int64(number), sourceSHA256: source.sha256, page: page)
    }
    func testMoreThan100PagesAnd8MiBAggregateStayInBoundedFiles() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Estimate 104 * 100KiB + 1MiB metadata below the 16MiB complete fixture cap.
        let writer = try store.begin(source: source, identity: .init(), maximumWriteBytes: 12 * 1024 * 1024)
        let text = String(repeating: "x", count: 30_000)
        for number in 1...104 { try writer.append(page(number, source: source, text: text)) }
        let prepared = try writer.preparePublication()
        let reference = try store.publishPrepared(prepared)
        XCTAssertEqual(reference.pageCount, 104)
        XCTAssertGreaterThan(reference.totalEncodedBytes, 8 * 1024 * 1024)
        XCTAssertLessThan(reference.totalEncodedBytes, 12 * 1024 * 1024)
        XCTAssertEqual(try store.readPage(reference, pageNumber: 97).page?.parsed.text, text)
        XCTAssertEqual(store.pageReadsForTesting, 1, "Random access must not scan other page payloads")
        var visited: Int64 = 0
        try store.validate(
            reference, source: source, identity: .init(), extractedAt: prepared.extractedAt,
            progress: {
                visited = $0
            })
        XCTAssertEqual(visited, 104)
        let representation = try AttachmentDocumentRepresentation(
            representationID: UUID.makeVersion1().uuidString.lowercased(), attachmentID: source.attachmentID,
            source: source, extractedAt: prepared.extractedAt, identity: .init(), content: reference)
        XCTAssertLessThan(try JSON.encode(representation.itemValue).count, 16 * 1024)
        XCTAssertTrue(representation.pages.isEmpty)
    }
    func testHierarchicalProofAndExplicitPartialCoverage() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try store.begin(source: source, identity: .init(), maximumWriteBytes: 1024 * 1024)
        for number in 1...129 {
            if number == 73 {
                try writer.append(
                    DocumentStoredPage(
                        pageNumber: 73, sourceSHA256: source.sha256, status: "unsupported",
                        failureCode: "unsupportedStructure"))
            } else {
                try writer.append(page(number, source: source))
            }
        }
        let reference = try writer.publish()
        XCTAssertEqual(try store.manifest(reference).rootLevel, 1)
        XCTAssertEqual(reference.coverage.converted, 128)
        XCTAssertEqual(reference.coverage.unsupported, 1)
        XCTAssertEqual(reference.coverage.state, "partial")
        XCTAssertEqual(try store.readPage(reference, pageNumber: 129).pageNumber, 129)
        XCTAssertEqual(try store.readPage(reference, pageNumber: 73).status, "unsupported")
        XCTAssertNil(try store.readPage(reference, pageNumber: 73).page)
    }
    func testPublicationRetryUsesRetainedCandidateWithoutRegeneratingPages() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try store.begin(source: source, identity: .init())
        try writer.append(page(1, source: source))
        let prepared = try writer.preparePublication()
        store.beforeDirectoryPublicationForTesting = {
            throw TractandaError("injected", "After manifest seal")
        }
        XCTAssertThrowsError(try store.publishPrepared(prepared))
        let restarted = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let restored = try JSON.decode(PreparedDocumentContent.self, JSON.encode(prepared))
        let reference = try restarted.publishPrepared(restored)
        XCTAssertEqual(try restarted.readPage(reference, pageNumber: 1).pageNumber, 1)
        XCTAssertEqual(
            try restarted.publishPrepared(restored), reference,
            "An uncertain reply must retain the immutable candidate")
    }
    func testRenameBeforeSynchronizationRetryMustRepairBothParents() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try store.begin(source: source, identity: .init())
        try writer.append(page(1, source: source))
        let prepared = try writer.preparePublication()
        store.afterDirectoryRenameForTesting = {
            throw TractandaError("injected", "Rename completed before parent synchronization")
        }
        XCTAssertThrowsError(try store.publishPrepared(prepared))
        let restarted = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        var syncAttempts = 0
        restarted.beforePublicationSyncForTesting = {
            syncAttempts += 1
            throw TractandaError("injected", "Synchronization still unavailable")
        }
        XCTAssertThrowsError(try restarted.publishPrepared(prepared))
        XCTAssertEqual(syncAttempts, 1, "Existing manifest must not acknowledge the unsynchronized move")
        restarted.beforePublicationSyncForTesting = { syncAttempts += 1 }
        let reference = try restarted.publishPrepared(prepared)
        XCTAssertEqual(syncAttempts, 2)
        XCTAssertEqual(try restarted.readPage(reference, pageNumber: 1).pageNumber, 1)
    }
    func testSharedQuotaChargesProofNodesAndRetainedPartialDocumentAfterRestart() throws {
        let (root, _, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let savedPage = try page(1, source: source)
        let pageBytes = try JSON.encode(savedPage).count
        let limit = Int64(pageBytes + 1)
        let quota = try StagingByteQuota(root: root, ownerUID: getuid(), maximumBytes: limit)
        let contents = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes,
            stagingQuota: quota)
        let writer = try contents.begin(source: source, identity: .init())
        try writer.append(savedPage)
        XCTAssertThrowsError(try writer.preparePublication()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertEqual(quota.usedBytes, Int64(pageBytes))
        let restored = try StagingByteQuota(root: root, ownerUID: getuid(), maximumBytes: limit)
        XCTAssertEqual(restored.usedBytes, quota.usedBytes)
        let files = DocumentContentFiles(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes,
            stagingQuota: restored)
        XCTAssertThrowsError(
            try files.writeImmutable(Data([1, 2]), path: ["copies", "other", "intent.json"])
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        // Receipts and nodes share the same byte budget; a failed reservation writes no payload.
        XCTAssertEqual(restored.usedBytes, Int64(pageBytes))
    }
    func testIndependentCopyCorruptionAndMissingDependencyFailClosed() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try store.begin(source: source, identity: .init())
        try writer.append(page(1, source: source))
        let reference = try writer.publish()
        let document = try AttachmentDocumentRepresentation(
            representationID: UUID.makeVersion1().uuidString.lowercased(), attachmentID: source.attachmentID,
            source: source, extractedAt: store.manifest(reference).extractedAt, identity: .init(),
            content: reference)
        let copyID = try UUID.makeVersion1().uuidString.lowercased()
        let copy = try store.clone(document, attachmentID: copyID, representationID: copyID)
        let copiedReference = try XCTUnwrap(copy.content)
        XCTAssertNotEqual(reference.contentID, copiedReference.contentID)
        XCTAssertEqual(copy.source, document.source)
        let original = try store.pageURLForTesting(reference, number: 1)
        let copied = try store.pageURLForTesting(copiedReference, number: 1)
        XCTAssertNotEqual(try FileMetadata.read(at: original).inode, try FileMetadata.read(at: copied).inode)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        var bytes = try Data(contentsOf: original)
        bytes[bytes.count / 2] ^= 1
        try bytes.write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: original.path)
        XCTAssertThrowsError(try store.readPage(reference, pageNumber: 1))
        XCTAssertEqual(try store.readPage(copiedReference, pageNumber: 1).pageNumber, 1)
        try FileManager.default.removeItem(at: original)
        XCTAssertThrowsError(
            try store.validate(
                reference, source: source, identity: .init(), extractedAt: document.extractedAt))
    }
    func testCapacityUnknownAndReserveRefusalUseOnlyTinyMocks() throws {
        let (root, _, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let low = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: 1234, availableBytes: { 1233 })
        XCTAssertThrowsError(try low.begin(source: source, identity: .init())) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        let unknown = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: 1234,
            availableBytes: { throw TractandaError("injected", "No capacity") })
        XCTAssertThrowsError(try unknown.begin(source: source, identity: .init()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("documents").path))
    }
}
