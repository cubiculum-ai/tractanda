import Foundation
import XCTest

@testable import TractandaCore

final class PeerDocumentClosureIndexTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let index: ItemIndex

        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
                "peer-document-closure-" + Identifier.make())
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: true)
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            try index.initializeAuthoritySchema()
            try index.validateRecoveryGraph(requireLinearProjection: false)
        }

        deinit {
            index.close()
            try? FileManager.default.removeItem(at: root)
        }

        func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }

        func descriptor(id: String, sha: String = String(repeating: "a", count: 64), count: Int64 = 12) throws
            -> AttachmentDescriptor
        {
            try AttachmentDescriptor(
                attachmentID: id, filename: "source.pdf", mediaType: "application/pdf", byteCount: count,
                sha256: sha)
        }

        func document(
            item: String, revision: String, attachment: String, representation: String,
            sha: String = String(repeating: "a", count: 64), count: Int64 = 12,
            content: DocumentContentReference? = nil
        ) throws -> AttachmentDocumentRepresentation {
            let source = try AttachmentDocumentSource(
                itemID: item, revisionID: revision, attachmentID: attachment,
                sha256: sha, byteCount: count, mediaType: "application/pdf")
            if let content {
                return try AttachmentDocumentRepresentation(
                    representationID: representation, attachmentID: attachment,
                    source: source, extractedAt: "2026-10-16T12:00:00.000Z", identity: .init(),
                    content: content)
            }
            let parsed = try DoclingDocTagsParser.parse(Data("<doctag><text>fixture</text></doctag>".utf8))
            let geometry = try DocumentPageGeometry(
                sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint", displayWidth: 512,
                displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024, contentLeft: 0, contentTop: 0,
                contentWidth: 2048, contentHeight: 1024)
            let page = try AttachmentDocumentPage(
                pageNumber: 1, geometry: geometry, rasterSHA256: String(repeating: "c", count: 64),
                parsed: parsed, generatedTokens: 12, stopReason: "stop")
            return try AttachmentDocumentRepresentation(
                representationID: representation, attachmentID: attachment, source: source,
                extractedAt: "2026-10-16T12:00:00.000Z", identity: .init(), pages: [page])
        }

        func revision(
            item: String, revision: String, descriptor: AttachmentDescriptor?,
            documents: [AttachmentDocumentRepresentation]
        ) throws -> Revision {
            var fields: [String: ItemValue] = [
                "itemID": .text(item), "revisionID": .text(revision), "classID": .text("Item"),
                "schemaVersion": .integer(1), "createdAt": .date("2026-10-16T12:00:00.000Z"),
                "modifiedAt": .date("2026-10-16T12:00:00.000Z"), "actor": .text("fixture"),
                "operationID": .text("fixture"), "requestIdentity": .text("peer document closure fixture"),
                "subject": .text("fixture"),
            ]
            if let descriptor { fields[AttachmentDescriptor.fieldName] = .list([descriptor.itemValue]) }
            if !documents.isEmpty {
                fields[AttachmentDocumentRepresentation.fieldName] = .list(
                    try documents.map { try $0.itemValue })
            }
            return try Revision(fields: fields)
        }

        func attachmentObject(_ descriptor: AttachmentDescriptor) -> PeerPackage.Object {
            .init(
                kind: .attachment, id: descriptor.attachmentID, length: Int(descriptor.byteCount),
                sha256: descriptor.sha256)
        }

        func manifestObject(_ content: DocumentContentReference, digest: String? = nil) -> PeerPackage.Object
        {
            .init(
                kind: .document, id: content.contentID, length: 32, sha256: digest ?? content.manifestSHA256,
                part: .manifest)
        }

        func content(id: String? = nil, digest: String = String(repeating: "b", count: 64)) throws
            -> DocumentContentReference
        {
            try DocumentContentReference(
                contentID: id ?? self.id(), manifestSHA256: digest,
                rootSHA256: String(repeating: "c", count: 64), pageCount: 1,
                totalEncodedBytes: 32, coverage: try DocumentCoverage(converted: 1))
        }
    }

    private func code(
        _ expected: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }

    func testExactSourceSignatureAndManifestCloseSuccessfully() throws {
        let f = try Fixture()
        let item = try f.id()
        let revisionID = try f.id()
        let attachmentID = try f.id()
        let descriptor = try f.descriptor(id: attachmentID)
        let content = try f.content()
        let document = try f.document(
            item: item, revision: revisionID, attachment: attachmentID,
            representation: f.id(), content: content)
        try f.index.peerOriginalBegin()
        try f.index.peerOriginalRegister(
            f.revision(item: item, revision: revisionID, descriptor: descriptor, documents: [document]))
        try f.index.peerOriginalPresent(f.attachmentObject(descriptor))
        try f.index.peerDocumentPresent(f.manifestObject(content))
        try f.index.peerOriginalValidateClosure()
        let page = try f.index.peerDocumentPage(after: "", limit: 1)
        XCTAssertEqual(page.map { $0.document.representationID }, [document.representationID])
        XCTAssertEqual(page.first?.object, f.manifestObject(content))
    }

    func testMissingSourceRevisionOrManifestIsMissingDependency() throws {
        let f = try Fixture()
        let item = try f.id()
        let revisionID = try f.id()
        let attachmentID = try f.id()
        let descriptor = try f.descriptor(id: attachmentID)
        let content = try f.content()
        let document = try f.document(
            item: item, revision: try f.id(), attachment: attachmentID,
            representation: f.id(), content: content)

        try f.index.peerOriginalBegin()
        try f.index.peerOriginalRegister(
            f.revision(item: item, revision: revisionID, descriptor: descriptor, documents: [document]))
        try f.index.peerOriginalPresent(f.attachmentObject(descriptor))
        try f.index.peerDocumentPresent(f.manifestObject(content))
        code("missingDependencies") { try f.index.peerOriginalValidateClosure() }

        let sameRevisionDocument = try f.document(
            item: item, revision: revisionID, attachment: attachmentID,
            representation: f.id(), content: content)
        try f.index.peerOriginalBegin()
        try f.index.peerOriginalRegister(
            f.revision(
                item: item, revision: revisionID, descriptor: descriptor, documents: [sameRevisionDocument]))
        try f.index.peerOriginalPresent(f.attachmentObject(descriptor))
        code("missingDependencies") { try f.index.peerOriginalValidateClosure() }
    }

    func testSourceSignatureAndManifestDigestMismatchesCollide() throws {
        let f = try Fixture()
        let item = try f.id()
        let revisionID = try f.id()
        let attachmentID = try f.id()
        let descriptor = try f.descriptor(id: attachmentID)
        let content = try f.content()
        let changedSource = try f.document(
            item: item, revision: revisionID, attachment: attachmentID, representation: f.id(),
            sha: String(repeating: "d", count: 64), content: content)
        try f.index.peerOriginalBegin()
        try f.index.peerOriginalRegister(
            f.revision(item: item, revision: revisionID, descriptor: descriptor, documents: [changedSource]))
        try f.index.peerOriginalPresent(f.attachmentObject(descriptor))
        try f.index.peerDocumentPresent(f.manifestObject(content))
        code("peerObjectCollision") { try f.index.peerOriginalValidateClosure() }

        let exactSource = try f.document(
            item: item, revision: revisionID, attachment: attachmentID, representation: f.id(),
            content: content)
        try f.index.peerOriginalBegin()
        try f.index.peerOriginalRegister(
            f.revision(item: item, revision: revisionID, descriptor: descriptor, documents: [exactSource]))
        try f.index.peerOriginalPresent(f.attachmentObject(descriptor))
        try f.index.peerDocumentPresent(f.manifestObject(content, digest: String(repeating: "e", count: 64)))
        code("peerObjectCollision") { try f.index.peerOriginalValidateClosure() }
    }

    func testOrphanManifestIsInvalidPackage() throws {
        let f = try Fixture()
        let content = try f.content()
        try f.index.peerOriginalBegin()
        try f.index.peerDocumentPresent(f.manifestObject(content))
        code("invalidPeerPackage") { try f.index.peerOriginalValidateClosure() }
    }

    func testInlineV1DocumentNeedsNoManifestObject() throws {
        let f = try Fixture()
        let item = try f.id()
        let revisionID = try f.id()
        let attachmentID = try f.id()
        let descriptor = try f.descriptor(id: attachmentID)
        let document = try f.document(
            item: item, revision: revisionID, attachment: attachmentID, representation: f.id())
        try f.index.peerOriginalBegin()
        try f.index.peerOriginalRegister(
            f.revision(item: item, revision: revisionID, descriptor: descriptor, documents: [document]))
        try f.index.peerOriginalPresent(f.attachmentObject(descriptor))
        try f.index.peerOriginalValidateClosure()
        let row = try XCTUnwrap(f.index.peerDocumentPage(after: "", limit: 1).first)
        XCTAssertNil(row.object)
        XCTAssertNil(row.document.content)
    }

    func testDocumentPageLimitOneContinuesInRepresentationIDOrder() throws {
        let f = try Fixture()
        let item = try f.id()
        try f.index.peerOriginalBegin()
        let documents = try (0..<2).map { _ in
            let revisionID = try f.id()
            let attachmentID = try f.id()
            let descriptor = try f.descriptor(id: attachmentID)
            let content = try f.content()
            let document = try f.document(
                item: item, revision: revisionID, attachment: attachmentID,
                representation: f.id(), content: content)
            try f.index.peerOriginalRegister(
                f.revision(item: item, revision: revisionID, descriptor: descriptor, documents: [document]))
            try f.index.peerOriginalPresent(f.attachmentObject(descriptor))
            try f.index.peerDocumentPresent(f.manifestObject(content))
            return document
        }.sorted { $0.representationID < $1.representationID }
        try f.index.peerOriginalValidateClosure()

        let first = try f.index.peerDocumentPage(after: "", limit: 1)
        XCTAssertEqual(first.count, 1)
        let cursor = try XCTUnwrap(first.first?.document.representationID)
        let second = try f.index.peerDocumentPage(after: cursor, limit: 1)
        XCTAssertEqual(second.map { $0.document.representationID }, [documents[1].representationID])
        XCTAssertTrue(
            try f.index.peerDocumentPage(after: XCTUnwrap(second.first?.document.representationID), limit: 1)
                .isEmpty)
    }
}
