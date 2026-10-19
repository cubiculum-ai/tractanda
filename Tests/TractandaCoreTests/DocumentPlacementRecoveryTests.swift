import Crypto
import XCTest

@testable import TractandaCore

final class DocumentPlacementRecoveryTests: XCTestCase {
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }

    private func root() throws -> URL {
        // Each fixture contains at most three tiny page outcomes, two trees and bounded SQLite.
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(
            "document-placement-recovery-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: result, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return result
    }
    private func contents(_ root: URL, index: URL? = nil) -> DocumentContentStore {
        DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes,
            indexDirectory: index)
    }
    private func source() throws -> AttachmentDocumentSource {
        let id = try UUID.makeVersion1().uuidString.lowercased()
        return try AttachmentDocumentSource(
            itemID: id, revisionID: id, attachmentID: id,
            sha256: String(repeating: "a", count: 64), byteCount: 12, mediaType: "application/pdf")
    }
    private func prepared(_ contents: DocumentContentStore) throws -> PreparedDocumentContent {
        let source = try source()
        let writer = try contents.begin(source: source, identity: .init())
        for (number, status) in ["failed", "unsupported"].enumerated() {
            try writer.append(
                DocumentStoredPage(
                    pageNumber: Int64(number + 1), sourceSHA256: source.sha256,
                    status: status, failureCode: "fixture"))
        }
        return try writer.preparePublication()
    }
    private func removeIndex(_ root: URL) throws {
        for name in ["documents.sqlite", "documents.sqlite-journal"] {
            let path = root.appendingPathComponent("index/" + name)
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
        }
    }
    private func privateDirectory(_ root: URL, path: String) throws -> URL {
        var result = root
        for name in path.split(separator: "/") {
            result.appendPathComponent(String(name))
            try FileManager.default.createDirectory(
                at: result, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return result
    }

    func testInterruptedIntentSupersedesClosedPeriodWithoutWritingIt() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = contents(root)
        let prepared = try prepared(store)
        let old = try privateDirectory(root, path: "documents/content/2020/01/02/03/04")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: old.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: old.path) }
        store.placementArrivalMinuteForTesting = { "2020/01/02/03/04" }
        store.afterPlacementIntentForTesting = { throw TractandaError("injected", "After durable intent") }
        XCTAssertThrowsError(try store.publishPrepared(prepared))
        store.afterPlacementIntentForTesting = nil
        store.placementArrivalMinuteForTesting = { "2030/05/06/07/08" }
        let reference = try store.publishPrepared(prepared)
        XCTAssertEqual(
            try store.directory(reference.contentID).joined(separator: "/"),
            "documents/content/2030/05/06/07/08/" + reference.contentID)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: old.path).isEmpty)
        let intent = root.appendingPathComponent("documents/.placements/" + reference.contentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: intent.appendingPathComponent("0.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: intent.appendingPathComponent("1.json").path))
    }

    func testRenameOrphanRebuildWithoutIntentsPreservesExactPublishedBytes() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: DocumentContentStore? = contents(root)
        let prepared = try prepared(XCTUnwrap(store))
        store?.placementArrivalMinuteForTesting = { "2030/01/02/03/04" }
        store?.afterDirectoryRenameForTesting = { throw TractandaError("injected", "Before parent sync") }
        XCTAssertThrowsError(try XCTUnwrap(store).publishPrepared(prepared))
        let receiptPath = root.appendingPathComponent(
            "documents/.staging/" + prepared.stage[2] + ".publication.json")
        let receipt = try JSON.decode(DocumentPublicationReceipt.self, Data(contentsOf: receiptPath))
        let base = root.appendingPathComponent(
            "documents/content/2030/01/02/03/04/" + receipt.manifest.contentID)
        let original = try Data(contentsOf: base.appendingPathComponent("manifest.json"))
        store = nil
        try removeIndex(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("documents/.placements"))
        let reopened = contents(root)
        let reference = try reopened.publishPrepared(prepared)
        XCTAssertEqual(try reopened.manifest(reference), receipt.manifest)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("manifest.json")), original)
        XCTAssertEqual(try reopened.readPage(reference, pageNumber: 2).status, "unsupported")
        XCTAssertEqual(reopened.placementRecoveryScansForTesting, 1)
    }

    func testCorruptIndexRecoversAndMissingPageFailsClosed() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: DocumentContentStore? = contents(root)
        let reference = try XCTUnwrap(store).publishPrepared(prepared(XCTUnwrap(store)))
        let pagePath = try XCTUnwrap(store).pageURLForTesting(reference, number: 2)
        store = nil
        try removeIndex(root)
        let index = root.appendingPathComponent("index/documents.sqlite")
        try Data("corrupt SQLite bytes".utf8).write(to: index)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        var reopened: DocumentContentStore? = contents(root)
        try XCTUnwrap(reopened).preparePlacement()
        XCTAssertEqual(try XCTUnwrap(reopened).readPage(reference, pageNumber: 1).status, "failed")
        reopened = nil
        try FileManager.default.removeItem(at: pagePath)
        try removeIndex(root)
        XCTAssertThrowsError(try contents(root).preparePlacement())
    }

    func testDuplicateAndSymlinkArchiveEntriesFailWithoutSelectingOne() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = contents(root)
        let reference = try store.publishPrepared(prepared(store))
        let original = try store.directory(reference.contentID).reduce(root) { $0.appendingPathComponent($1) }
        let minute = try privateDirectory(root, path: "documents/content/2031/01/01/01/01")
        let duplicate = minute.appendingPathComponent(reference.contentID)
        try FileManager.default.copyItem(at: original, to: duplicate)
        XCTAssertThrowsError(try store.rebuildPlacement())
        try FileManager.default.removeItem(at: duplicate)
        try FileManager.default.createSymbolicLink(at: duplicate, withDestinationURL: original)
        XCTAssertThrowsError(try store.rebuildPlacement())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: original.appendingPathComponent("manifest.json").path))
    }

    func testMissingStoreIdentityNeverMintsOverRetainedDocuments() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = contents(root)
            _ = try store.publishPrepared(prepared(store))
        }
        let identity = root.appendingPathComponent(".tractanda-store-identity.json")
        try FileManager.default.removeItem(at: identity)
        XCTAssertThrowsError(try contents(root).preparePlacement())
        XCTAssertThrowsError(try ItemStore(root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: identity.path))
    }

    func testExternalBindingIsCheckedBeforeAnyAlternateLookupWrites() throws {
        let fixture = try root()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("canonical")
        let index = fixture.appendingPathComponent("derived")
        do { _ = try ItemStore(root: root, indexDirectory: index) }
        do {
            let store = contents(root, index: index)
            let reference = try store.publishPrepared(prepared(store))
            XCTAssertEqual(try store.readPage(reference, pageNumber: 2).status, "unsupported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("index").path))
        let database = try Data(contentsOf: index.appendingPathComponent("documents.sqlite"))
        let other = fixture.appendingPathComponent("other")
        let otherIndex = fixture.appendingPathComponent("other-derived")
        do { _ = try ItemStore(root: other, indexDirectory: otherIndex) }
        XCTAssertThrowsError(try contents(other, index: index).preparePlacement())
        XCTAssertEqual(try Data(contentsOf: index.appendingPathComponent("documents.sqlite")), database)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("index").path))
        do { _ = try ItemStore(root: root, indexDirectory: index) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("index").path))
    }

    func testExactPublicationPreservesRawFormattingIDsAndPartialOutcomes() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = contents(root)
        store.placementArrivalMinuteForTesting = { "2030/01/02/03/04" }
        try store.preparePlacement()
        let source = try source()
        let content = try UUID.makeVersion1().uuidString.lowercased()
        let publication = try UUID.makeVersion1().uuidString.lowercased()
        let privateStage = try UUID.makeVersion1().uuidString.lowercased()
        let stage = ["documents", ".staging", privateStage]
        let files = DocumentContentFiles(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        try files.createUniqueDirectory(stage)
        func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        var entries: [DocumentHashEntry] = []
        var rawPages: [Data] = []
        for (index, status) in ["failed", "timeout"].enumerated() {
            let number = Int64(index + 1)
            var bytes = try JSON.encode(
                DocumentStoredPage(
                    pageNumber: number, sourceSHA256: source.sha256, status: status, failureCode: "fixture"))
            bytes.append(Data("\n".utf8))
            rawPages.append(bytes)
            entries.append(
                .init(
                    ordinal: number, firstPage: number, lastPage: number,
                    byteCount: Int64(bytes.count), sha256: hash(bytes)))
            try files.writeImmutable(bytes, path: stage + ["pages", "0", "\(number).json"])
        }
        var node = try JSON.encode(
            DocumentHashNode(schema: "tractanda.document-node.v2", level: 0, ordinal: 0, entries: entries))
        node.append(Data("\n".utf8))
        let coverage = try DocumentCoverage(converted: 0, timedOut: 1, failed: 1)
        let total = rawPages.reduce(Int64(0)) { $0 + Int64($1.count) }
        let manifest = DocumentManifest(
            schema: "tractanda.document-manifest.v2", contentID: content, publicationID: publication,
            source: source, identity: .init(), extractedAt: "2020-01-02T03:04:05Z", rootLevel: 0,
            rootByteCount: Int64(node.count), rootSHA256: hash(node), pageCount: 2, totalEncodedBytes: total,
            coverage: coverage)
        var rawManifest = try JSON.encode(manifest)
        rawManifest.append(Data("\n".utf8))
        let reference = try DocumentContentReference(
            contentID: content, manifestSHA256: hash(rawManifest),
            rootSHA256: hash(node), pageCount: 2, totalEncodedBytes: total, coverage: coverage)
        try files.writeImmutable(node, path: stage + ["nodes", "0", "0", "0.json"])
        try files.writeImmutable(rawManifest, path: stage + ["manifest.json"])
        try store.publishExact(stage: stage, reference: reference, manifestBytes: rawManifest)
        let base = try store.directory(content).reduce(root) { $0.appendingPathComponent($1) }
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("manifest.json")), rawManifest)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("nodes/0/0/0.json")), node)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("pages/0/2.json")), rawPages[1])
        XCTAssertEqual(try store.manifest(reference).publicationID, publication)
        XCTAssertNotEqual(publication, privateStage)
        XCTAssertEqual(reference.coverage.state, "partial")
        try store.validate(reference, source: source, identity: .init(), extractedAt: manifest.extractedAt)
        try store.publishExact(stage: stage, reference: reference, manifestBytes: rawManifest)
        try store.rebuildPlacement()
        XCTAssertEqual(try store.readPage(reference, pageNumber: 2).status, "timeout")
    }

    func testExtraEmptySubtreeAndCorruptPagePreventPublication() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = contents(root)
        let prepared = try prepared(store)
        let base = prepared.stage.reduce(root) { $0.appendingPathComponent($1) }
        let extra = try privateDirectory(base, path: "pages/99")
        XCTAssertThrowsError(try store.publishPrepared(prepared))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("documents/content").path))
        try FileManager.default.removeItem(at: extra)
        let page = base.appendingPathComponent("pages/0/1.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: page.path)
        try Data("changed bytes".utf8).write(to: page)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: page.path)
        XCTAssertThrowsError(try store.publishPrepared(prepared))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("documents/content").path))
    }
}
