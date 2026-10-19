import XCTest

@testable import TractandaCore

final class PeerDocumentCorpusAccountingTests: XCTestCase {
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func root() throws -> URL {
        // Sixty-five tiny SQL generations and one lexical head, estimated <4 MiB.
        try AttachmentFixtureCapacity.requireFree()
        let root = (try GuardedFixtureDirectory.parent()).appendingPathComponent("peer-corpus-" + (try id()))
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func revision(document: AttachmentDocumentRepresentation? = nil) throws -> Revision {
        var fields: [String: ItemValue] = [
            "itemID": .text(try id()), "revisionID": .text(try id()), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date(Timestamp.now()),
            "modifiedAt": .date(Timestamp.now()), "actor": .text("fixture"),
            "operationID": .text("fixture"), "requestIdentity": .text("fixture"),
            "body": .text("ordinary corpus"),
        ]
        if let document {
            fields["itemID"] = .text(document.source.itemID)
            fields["attachments"] = .list([
                try AttachmentDescriptor(
                    attachmentID: document.attachmentID, filename: "tiny.pdf",
                    mediaType: document.source.mediaType, byteCount: document.source.byteCount,
                    sha256: document.source.sha256
                ).itemValue
            ])
            fields["attachmentDocument"] = .list([try document.itemValue])
        }
        return try Revision(fields: fields)
    }
    private func document() throws -> AttachmentDocumentRepresentation {
        let attachment = try id()
        let source = try AttachmentDocumentSource(
            itemID: id(), revisionID: id(), attachmentID: attachment,
            sha256: String(repeating: "a", count: 64), byteCount: 1, mediaType: "application/pdf")
        return try .init(
            representationID: id(), attachmentID: attachment, source: source,
            extractedAt: "2026-10-16T00:00:00Z", identity: .init(),
            content: .init(
                contentID: id(), manifestSHA256: String(repeating: "b", count: 64),
                rootSHA256: String(repeating: "c", count: 64), pageCount: 1,
                totalEncodedBytes: 1, coverage: .init(converted: 0, failed: 1)))
    }
    func testRetiredPeerDebtDoesNotConsumeLocalSlotsAndRemainsChargedUntilGC() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try ItemIndex(path: root.appendingPathComponent("items.sqlite").path, create: true)
        try index.initializePeerDocumentSchema()
        let quota = try StagingByteQuota(root: root, ownerUID: getuid(), maximumBytes: 1024 * 1024)
        var works: [String] = []
        for _ in 0..<65 {
            try AttachmentFixtureCapacity.requireFree(at: root)
            let package = try id()
            let token = try index.beginPeerDocumentCorpus(packageID: package, document: document()) { _ in }
            try index.finishPeerDocumentCorpus(token, units: 0, bytes: 0)
            works.append(token.workID)
            let observed = try index.completePeerDocumentCorpus(packageID: package)
            XCTAssertEqual(observed.count, 1)
            XCTAssertGreaterThan(observed[0].retainedEncodedBytes, 0)
            try quota.observeDerived(
                workID: token.workID, retainedEncodedBytes: observed[0].retainedEncodedBytes)
        }
        let debt = quota.usedBytes
        XCTAssertGreaterThan(debt, 0)
        XCTAssertThrowsError(try quota.require(additionalBytes: 1024 * 1024 - debt + 1))
        let ordinary = try revision()
        try index.put(ordinary)
        let read = try id()
        XCTAssertNotNil(
            try index.captureCorpusSnapshot(
                itemID: ordinary.itemID, expectedRevisionID: ordinary.revisionID, retentionID: read))
        try index.releaseCorpusWork(read)
        XCTAssertEqual(quota.usedBytes, debt)
        for _ in 0..<8 { _ = try index.cleanupCorpus(limit: 1) }
        for work in works {
            try quota.observeDerived(workID: work, retainedEncodedBytes: index.corpusRetainedBytes(work))
        }
        XCTAssertEqual(quota.usedBytes, 0)
        XCTAssertTrue(try index.retainedCorpusWorkPage().isEmpty)
    }
    func testAcceptedReuseReleasesPriorHeldOwnerWithoutChangingHeadVisibility() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try ItemIndex(path: root.appendingPathComponent("items.sqlite").path, create: true)
        try index.initializePeerDocumentSchema()
        let document = try document()
        let heldPackage = try id()
        let held = try index.beginPeerDocumentCorpus(packageID: heldPackage, document: document) { _ in }
        try index.finishPeerDocumentCorpus(held, units: 0, bytes: 0)
        _ = try index.completePeerDocumentCorpus(packageID: heldPackage)
        XCTAssertGreaterThan(try index.corpusRetainedBytes(held.workID), 0)
        let acceptedPackage = try id()
        let reused = try index.beginPeerDocumentCorpus(packageID: acceptedPackage, document: document) { _ in
        }
        XCTAssertTrue(reused.reusable)
        XCTAssertEqual(reused.generationID, held.generationID)
        let current = try revision(document: document)
        try index.put(current)
        let observed = try index.completePeerDocumentCorpus(packageID: acceptedPackage)
        XCTAssertTrue(observed.contains { $0.workID == held.workID && $0.retainedEncodedBytes == 0 })
        XCTAssertEqual(try index.corpusRetainedBytes(held.workID), 0)
        XCTAssertEqual(try index.corpusRetainedBytes(reused.workID), 0)
        XCTAssertTrue(try index.retainedCorpusWorkPage().isEmpty)
        XCTAssertNotNil(
            try index.captureCorpusSnapshot(
                itemID: current.itemID, expectedRevisionID: current.revisionID))
        _ = try index.cleanupCorpus(limit: 1)
        XCTAssertNotNil(
            try index.captureCorpusSnapshot(
                itemID: current.itemID, expectedRevisionID: current.revisionID))
    }
    func testIdleExpiryPreservesDebtUntilGCAndRepreparesBeforeHeadVisibility() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try ItemIndex(path: root.appendingPathComponent("items.sqlite").path, create: true)
        try index.initializePeerDocumentSchema()
        let document = try document()
        let package = try id()
        let now = Date()
        let token = try index.beginPeerDocumentCorpus(packageID: package, document: document) { _ in }
        try index.touchPeerDocumentCorpus(token, now: now)
        XCTAssertTrue(
            try index.expirePeerDocumentCorpus(token.workID, now: now.addingTimeInterval(3598)).isEmpty)
        try index.touchPeerDocumentCorpus(token, now: now.addingTimeInterval(3500))
        XCTAssertTrue(
            try index.expirePeerDocumentCorpus(token.workID, now: now.addingTimeInterval(7000)).isEmpty)
        let retired = try index.expirePeerDocumentCorpus(token.workID, now: now.addingTimeInterval(7102))
        XCTAssertEqual(retired.count, 1)
        XCTAssertGreaterThan(retired[0].retainedEncodedBytes, 0)
        _ = try index.cleanupCorpus(limit: 1)
        XCTAssertEqual(try index.corpusRetainedBytes(token.workID), 0)
        let replacement = try index.beginPeerDocumentCorpus(packageID: package, document: document) { _ in }
        XCTAssertNotEqual(replacement.workID, token.workID)
        XCTAssertNotEqual(replacement.generationID, token.generationID)
        XCTAssertFalse(replacement.reusable)
        try index.finishPeerDocumentCorpus(replacement, units: 0, bytes: 0)
        let current = try revision(document: document)
        XCTAssertNil(
            try index.captureCorpusSnapshot(itemID: current.itemID, expectedRevisionID: current.revisionID))
        try index.put(current)
        _ = try index.completePeerDocumentCorpus(packageID: package)
        XCTAssertNotNil(
            try index.captureCorpusSnapshot(itemID: current.itemID, expectedRevisionID: current.revisionID))
    }
}
