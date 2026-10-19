import Crypto
import Foundation
import XCTest

@testable import TractandaCore

final class DocumentPlacementTests: XCTestCase {
    private func fixture() throws -> (URL, DocumentContentStore, AttachmentDocumentSource) {
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "document-placement-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = try UUID.makeVersion1().uuidString.lowercased()
        let source = try AttachmentDocumentSource(
            itemID: id, revisionID: id, attachmentID: id,
            sha256: String(repeating: "a", count: 64), byteCount: 128, mediaType: "application/pdf")
        let store = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        return (root, store, source)
    }

    private func failedPage(_ number: Int, source: AttachmentDocumentSource) throws -> DocumentStoredPage {
        try DocumentStoredPage(
            pageNumber: Int64(number), sourceSHA256: source.sha256,
            status: "failed", failureCode: "syntheticFixture")
    }

    func testNewContentUsesArrivalMinuteAndPreservesExactManifestAndPageBytes() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let arrivalMinute = "2031/04/05/06/07"
        store.placementArrivalMinuteForTesting = { arrivalMinute }
        let writer = try store.begin(
            source: source, identity: .init(), extractedAt: "2020-01-02T03:04:05Z")
        try writer.append(failedPage(1, source: source))
        try writer.append(failedPage(2, source: source))

        let reference = try writer.publish()
        let relative = try store.directory(reference.contentID).joined(separator: "/")
        XCTAssertEqual(relative, "documents/content/\(arrivalMinute)/\(reference.contentID)")
        XCTAssertNotEqual(relative, "documents/content/2020/01/02/03/04/\(reference.contentID)")

        let manifestBytes = try Data(
            contentsOf: root.appendingPathComponent(relative).appendingPathComponent("manifest.json"))
        let manifest = try store.manifest(reference)
        XCTAssertEqual(manifestBytes, try JSON.encode(manifest))
        XCTAssertEqual(manifest.source, source)
        XCTAssertEqual(manifest.extractedAt, "2020-01-02T03:04:05Z")
        XCTAssertEqual(
            SHA256.hash(data: manifestBytes).map { String(format: "%02x", $0) }.joined(),
            reference.manifestSHA256)

        let page = try store.readPage(reference, pageNumber: 1)
        let pageBytes = try Data(
            contentsOf: root.appendingPathComponent(relative)
                .appendingPathComponent("pages/0/1.json"))
        XCTAssertEqual(pageBytes, try JSON.encode(page))
        XCTAssertEqual(page, try failedPage(1, source: source))
    }

    func testValidLookupAndMissDoNotRescanCanonicalArchives() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try store.begin(source: source, identity: .init())
        try writer.append(failedPage(1, source: source))
        let reference = try writer.publish()
        try store.preparePlacement()
        let scansAfterPreparation = store.placementRecoveryScansForTesting
        XCTAssertGreaterThan(scansAfterPreparation, 0)

        XCTAssertEqual(try store.directory(reference.contentID).last, reference.contentID)
        XCTAssertEqual(try store.readPage(reference, pageNumber: 1).pageNumber, 1)
        XCTAssertThrowsError(try store.directory(UUID.makeVersion1().uuidString.lowercased()))
        XCTAssertEqual(
            store.placementRecoveryScansForTesting, scansAfterPreparation,
            "A valid derived lookup or final miss must not enumerate canonical document archives")
    }

    func testPlacementPublicationAdvancesReaderFloorAndGatesOldReader() throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try store.begin(source: source, identity: .init())
        try writer.append(failedPage(1, source: source))

        let storeID = try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: getuid())
        let oldReader = CanonicalFormatSupport(
            readerLevel: 9, writerLevel: 9, read: [1, 2], write: [2],
            capabilities: CanonicalFormatSupport.current.capabilities.filter {
                $0 != "tractanda.document-placement.v1"
            },
            writeCapabilities: CanonicalFormatSupport.current.writeCapabilities.filter {
                $0 != "tractanda.document-placement.v1"
            })
        let requirement = CanonicalReaderRequirement(
            storeID: storeID, minimumReaderLevel: oldReader.readerLevel,
            recordFormats: oldReader.read, capabilities: oldReader.capabilities)
        try PrivateConfiguration.write(
            JSON.encode(requirement), to: root.appendingPathComponent(CanonicalReaderRequirement.fileName))

        store.beforeDirectoryPublicationForTesting = {
            let raised = try XCTUnwrap(CanonicalReaderRequirement.load(root: root, ownerUID: getuid()))
            XCTAssertGreaterThanOrEqual(raised.minimumReaderLevel, 10)
            XCTAssertTrue(raised.capabilities.contains("tractanda.document-placement.v1"))
            XCTAssertThrowsError(try oldReader.require(raised)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "incompatibleCanonicalReader")
            }
        }

        let reference = try writer.publish()
        let retained = try XCTUnwrap(CanonicalReaderRequirement.load(root: root, ownerUID: getuid()))
        XCTAssertGreaterThanOrEqual(retained.minimumReaderLevel, 10)
        XCTAssertTrue(retained.capabilities.contains("tractanda.document-placement.v1"))
        XCTAssertEqual(try store.readPage(reference, pageNumber: 1).pageNumber, 1)
    }

    func testSourceDescriptorAboveEightMiBNeedsNoSourcePayloadAllocation() throws {
        let (root, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try UUID.makeVersion1().uuidString.lowercased()
        let largeSource = try AttachmentDocumentSource(
            itemID: id, revisionID: id, attachmentID: id,
            sha256: String(repeating: "c", count: 64), byteCount: 8 * 1024 * 1024 + 1,
            mediaType: "application/pdf")
        let writer = try store.begin(source: largeSource, identity: .init())
        try writer.append(failedPage(1, source: largeSource))
        try writer.append(failedPage(2, source: largeSource))

        let reference = try writer.publish()
        XCTAssertEqual(try store.manifest(reference).source.byteCount, 8 * 1024 * 1024 + 1)
        XCTAssertEqual(reference.pageCount, 2)
        XCTAssertEqual(reference.coverage.failed, 2)
    }
}
