import Crypto
import XCTest

@testable import TractandaCore

final class AttachmentDocumentIntegrationTests: XCTestCase {
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }

    private func fixture(_ store: ItemStore) throws -> (Revision, AttachmentDescriptor, Data) {
        let base = try store.commit(
            CommitRequest(classID: "Item", changes: ["body": .text("owned body")], operationID: "create")
        ).revision
        let data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let upload = try store.beginAttachment(
            AttachmentUploadRequest(
                itemID: base.itemID, expectedRevisionID: base.revisionID, operationID: "attach",
                filename: "hidden-filename-noise.png", mediaType: "image/png", byteCount: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        let uploadID = try XCTUnwrap(upload.uploadID)
        _ = try store.appendAttachment(uploadID: uploadID, offset: 0, data: data)
        return (try store.finishAttachment(uploadID: uploadID).revision, upload.attachment, data)
    }

    private func snapshot(_ store: ItemStore, _ attached: Revision, _ id: String, op: String = "extract")
        throws
        -> DocumentExtractionSnapshot
    {
        let admission = try store.prepareAttachmentDocument(
            itemID: attached.itemID, expectedRevisionID: attached.revisionID,
            attachmentID: id, operationID: op, identity: .init())
        guard case .prepared(let snapshot) = admission else {
            throw TractandaError("test", "Expected new admission")
        }
        return snapshot
    }

    private func page(
        raw: String = "<doctag><text><loc_10><loc_20><loc_100><loc_80>document needle α</text></doctag>"
    ) throws
        -> AttachmentDocumentPage
    {
        let geometry = try DocumentPageGeometry(
            sourceWidth: 512, sourceHeight: 256, sourceUnit: "pixel",
            displayWidth: 512, displayHeight: 256,
            canvasWidth: 2048, canvasHeight: 1024,
            contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024)
        return try AttachmentDocumentPage(
            pageNumber: 1, geometry: geometry, rasterSHA256: String(repeating: "b", count: 64),
            parsed: DoclingDocTagsParser.parse(Data(raw.utf8)), generatedTokens: 40, stopReason: "stop")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "attachment-document-" + Identifier.make())
    }

    /// The fixture has one tiny page; production readers return bounded units instead of aggregates.
    private func authenticatedCorpus(_ store: ItemStore, revision: Revision) throws -> (
        sourceText: String, sourceSegments: [AttachmentSourceSegment]
    ) {
        let snapshot = try store.capturePageCorpus(itemID: revision.itemID)
        var text = ""
        var segments: [AttachmentSourceSegment] = []
        _ = try PageCorpusEmitter.emit(snapshot.input, provider: snapshot.provider) { unit in
            guard text.utf8.count + unit.text.utf8.count <= 262_144 else {
                throw TractandaError("resourceLimit", "Tiny corpus fixture exceeded its bounded window.")
            }
            text += unit.text
            if let attachmentID = unit.origin.attachmentID,
                let representationID = unit.origin.representationID,
                let source = unit.origin.documentSource, let page = unit.origin.pageNumber,
                let geometry = unit.origin.geometry, let raster = unit.origin.rasterSHA256
            {
                for span in unit.spans {
                    segments.append(
                        AttachmentSourceSegment(
                            itemID: revision.itemID,
                            revisionID: revision.revisionID, attachmentID: attachmentID,
                            representationID: representationID, sourceSHA256: source.sha256,
                            corpusByteStart: Int(unit.byteStart + span.unitByteStart),
                            corpusByteEnd: Int(unit.byteStart + span.unitByteEnd),
                            location: .document(
                                pageNumber: Int(page), blockIndex: Int(span.blockIndex),
                                rasterSHA256: raster, geometry: geometry, box: span.box)))
                }
            }
        }
        return (text, segments)
    }

    func testSavedCorpusCitationsReplayCopyDetachAndRebuild() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let (attached, original, originalData) = try fixture(store)
        let prepared = try snapshot(store, attached, original.attachmentID)
        XCTAssertEqual(prepared.input, originalData)
        XCTAssertTrue(try store.candidates(text: "document needle").isEmpty)
        let receipt = try store.finishAttachmentDocument(prepared, pages: [page()])
        let saved = try store.get(receipt.itemID)
        let document = try XCTUnwrap(AttachmentDocumentRepresentation.representations(in: saved.fields).first)
        XCTAssertEqual(document.source.revisionID, attached.revisionID)
        XCTAssertEqual(try store.candidates(text: "document needle").map(\.itemID), [saved.itemID])
        let corpus = try authenticatedCorpus(store, revision: saved)
        XCTAssertEqual(corpus.sourceText.components(separatedBy: "document needle").count, 2)
        XCTAssertFalse(corpus.sourceText.contains("hidden-filename-noise"))
        XCTAssertFalse(corpus.sourceText.contains("loc_"))
        let locator = try XCTUnwrap(corpus.sourceSegments.first)
        XCTAssertEqual(locator.itemID, saved.itemID)
        XCTAssertEqual(locator.revisionID, saved.revisionID)
        XCTAssertNil(locator.sourceByteStart)
        guard case .document(let number, let block, _, _, let box) = locator.location else {
            return XCTFail("Document text must cite a document location")
        }
        XCTAssertEqual(number, 1)
        XCTAssertEqual(block, 0)
        XCTAssertNotNil(box)
        XCTAssertEqual(
            locator.overlap(with: (locator.corpusByteStart + 1)..<locator.corpusByteEnd)?.location,
            locator.location)
        guard
            case .replay(let replay) = try store.prepareAttachmentDocument(
                itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                attachmentID: original.attachmentID, operationID: "extract", identity: .init())
        else { return XCTFail("Expected canonical replay") }
        XCTAssertEqual(replay.revisionID, receipt.revisionID)
        XCTAssertEqual(try store.finishAttachmentDocument(prepared, pages: []).revisionID, receipt.revisionID)
        let copy = try store.commit(
            CommitRequest(
                action: .copy, itemID: saved.itemID, expectedRevisionID: saved.revisionID, operationID: "copy"
            )
        ).revision
        let copied = try XCTUnwrap(AttachmentDocumentRepresentation.representations(in: copy.fields).first)
        let copyOriginal = try XCTUnwrap(AttachmentDescriptor.descriptors(in: copy.fields).first)
        XCTAssertEqual(copied.source, document.source)
        XCTAssertNotEqual(copied.representationID, document.representationID)
        XCTAssertEqual(copied.attachmentID, copyOriginal.attachmentID)
        XCTAssertEqual(
            try authenticatedCorpus(store, revision: copy).sourceSegments.first?.itemID, copy.itemID)
        _ = try store.detachAttachment(
            itemID: saved.itemID, expectedRevisionID: saved.revisionID,
            attachmentID: original.attachmentID, operationID: "detach")
        XCTAssertTrue(
            try authenticatedCorpus(store, revision: store.get(saved.itemID)).sourceSegments.isEmpty)
        XCTAssertEqual(
            try store.get(saved.itemID, revisionID: saved.revisionID).fields["attachmentDocument"],
            saved.fields["attachmentDocument"])
        try store.rebuildIndex()
        XCTAssertEqual(try store.candidates(text: "document needle").map(\.itemID), [copy.itemID])
        let currentBytes = try store.attachmentContent(
            itemID: copy.itemID, attachmentID: copyOriginal.attachmentID, offset: 0, limit: 100)
        XCTAssertEqual(currentBytes.data, originalData)
    }

    func testConflictsUnsupportedMediaAndGenericForgeryCommitNothing() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let (attached, original, _) = try fixture(store)
        let prepared = try snapshot(store, attached, original.attachmentID)
        let changed = try store.commit(
            CommitRequest(
                action: .revise, itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                changes: ["body": .text("changed")], operationID: "concurrent"))
        XCTAssertThrowsError(try store.finishAttachmentDocument(prepared, pages: [page()])) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "revisionConflict")
        }
        XCTAssertEqual(try store.get(attached.itemID).revisionID, changed.revision.revisionID)
        XCTAssertNil(try store.get(attached.itemID).fields["attachmentDocument"])
        for request in [
            CommitRequest(
                action: .revise, itemID: attached.itemID, expectedRevisionID: changed.revision.revisionID,
                changes: ["attachmentDocument": .list([])], operationID: "forge"),
            CommitRequest(
                action: .revise, itemID: attached.itemID, expectedRevisionID: changed.revision.revisionID,
                unset: ["attachmentDocument"], operationID: "clear"),
        ] { XCTAssertThrowsError(try store.commit(request)) }
        XCTAssertThrowsError(
            try AttachmentDocumentSource(
                itemID: attached.itemID, revisionID: attached.revisionID,
                attachmentID: original.attachmentID, sha256: original.sha256, byteCount: 1,
                mediaType: "text/plain"))
    }

    func testCanonicalValidationReparsesRawAndRejectsInconsistentStructures() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let (attached, original, _) = try fixture(store)
        let prepared = try snapshot(store, attached, original.attachmentID)
        let valid = try page()
        let invented = try DoclingBlock(kind: .text, text: "invented", textByteStart: 0, textByteEnd: 8)
        let inconsistent = try DoclingParsedPage(
            rawDocTags: valid.parsed.rawDocTags, blocks: [invented], text: "invented")
        let forged = try AttachmentDocumentPage(
            pageNumber: 1, geometry: valid.geometry,
            rasterSHA256: valid.rasterSHA256, parsed: inconsistent, generatedTokens: 10, stopReason: "stop")
        XCTAssertThrowsError(try store.finishAttachmentDocument(prepared, pages: [forged])) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidDocumentOutput")
        }
        XCTAssertEqual(try store.history(attached.itemID).count, 2)
        XCTAssertNil(try store.get(attached.itemID).fields["attachmentDocument"])
    }
}
