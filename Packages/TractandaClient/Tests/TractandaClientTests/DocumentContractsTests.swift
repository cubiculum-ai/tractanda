import Foundation
import XCTest

@testable import TractandaClient

final class DocumentContractsTests: XCTestCase {
    private let id = "70863dec-b0ea-11f1-ae72-842f575e6ac5"
    private let sourceDigest = String(repeating: "a", count: 64)

    private func geometry() throws -> DocumentPageGeometry {
        try DocumentPageGeometry(
            sourceWidth: 512, sourceHeight: 256, sourceUnit: "pixel",
            displayWidth: 512, displayHeight: 256,
            canvasWidth: 2048, canvasHeight: 1024,
            contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024)
    }

    func testByteOverlapIsExactAndDocumentOverlapHasNoOriginalBytes() throws {
        let bytes = AttachmentSourceSegment(
            itemID: id, revisionID: id, attachmentID: id, representationID: id,
            sourceSHA256: sourceDigest, corpusByteStart: 20, corpusByteEnd: 40,
            sourceByteStart: 3, sourceByteEnd: 23)
        let overlap = try XCTUnwrap(bytes.overlap(with: 25..<30))
        XCTAssertEqual(overlap.byteStart, 8)
        XCTAssertEqual(overlap.byteEnd, 13)
        let byteWire = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSON.encode(overlap)) as? [String: Any])
        XCTAssertNil(byteWire["byteStart"])
        XCTAssertEqual((byteWire["location"] as? [String: Any])?["kind"] as? String, "originalBytes")

        let box = try DoclingBoundingBox(left: 10, top: 20, right: 100, bottom: 200)
        let document = AttachmentSourceSegment(
            itemID: id, revisionID: id, attachmentID: id, representationID: id,
            sourceSHA256: sourceDigest, corpusByteStart: 20, corpusByteEnd: 40,
            location: .document(
                pageNumber: 1, blockIndex: 0, rasterSHA256: sourceDigest, geometry: try geometry(), box: box))
        let region = try XCTUnwrap(document.overlap(with: 25..<30))
        XCTAssertNil(region.byteStart)
        XCTAssertNil(region.byteEnd)
        XCTAssertEqual(region.location, document.location)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(region)) as? [String: Any])
        let location = try XCTUnwrap(wire["location"] as? [String: Any])
        XCTAssertEqual(location["kind"] as? String, "document")
        XCTAssertNil(location["byteStart"])
        XCTAssertEqual(try JSON.decode(AttachmentPassageSource.self, JSON.encode(region)), region)
    }

    func testLocatorDecoderRejectsMixedAndUnknownVariants() throws {
        for json in [
            #"{"kind":"originalBytes","byteStart":0,"byteEnd":5,"pageNumber":1}"#,
            #"{"kind":"originalBytes","byteStart":0,"byteEnd":5,"invented":1}"#,
            #"{"kind":"originalBytes","byteStart":5,"byteEnd":0}"#,
            #"{"kind":"other","byteStart":0,"byteEnd":5}"#,
        ] {
            XCTAssertThrowsError(try JSON.decode(AttachmentSourceLocation.self, Data(json.utf8)))
        }
    }

    func testCanonicalDocumentRoundTripAndImmutableCopyProvenance() throws {
        let block = try DoclingBlock(kind: .text, text: "α", textByteStart: 0, textByteEnd: 2)
        let parsed = try DoclingParsedPage(
            rawDocTags: "<doctag><text>α</text></doctag>", blocks: [block], text: "α")
        let source = try AttachmentDocumentSource(
            itemID: id, revisionID: id, attachmentID: id, sha256: sourceDigest, byteCount: 100,
            mediaType: "image/png")
        let page = try AttachmentDocumentPage(
            pageNumber: 1, geometry: geometry(), rasterSHA256: sourceDigest, parsed: parsed,
            generatedTokens: 10, stopReason: "stop")
        let document = try AttachmentDocumentRepresentation(
            representationID: id, attachmentID: id, source: source,
            extractedAt: "2026-10-07T12:00:00Z", identity: .init(), pages: [page])
        let value = try document.itemValue
        XCTAssertEqual(value.map?["extractedAt"], .date(document.extractedAt))
        XCTAssertEqual(try AttachmentDocumentRepresentation(value), document)
        let copyID = "70863ded-b0ea-11f1-ae72-842f575e6ac5"
        let copy = try document.remapping(attachmentID: copyID, representationID: copyID)
        XCTAssertEqual(copy.source, source)
        XCTAssertEqual(copy.attachmentID, copyID)
        var oldWire = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSON.encode(document)) as? [String: Any])
        var oldIdentity = try XCTUnwrap(oldWire["identity"] as? [String: Any])
        oldIdentity["preprocessing"] = "opaque-rgb2048-17tiles-v1"
        oldIdentity["converter"] = "tractanda.docling-native.v1"
        oldWire["identity"] = oldIdentity
        var oldPages = try XCTUnwrap(oldWire["pages"] as? [[String: Any]])
        var oldGeometry = try XCTUnwrap(oldPages[0]["geometry"] as? [String: Any])
        oldGeometry["canvasHeight"] = 2048
        oldGeometry["contentTop"] = 512
        oldPages[0]["geometry"] = oldGeometry
        oldWire["pages"] = oldPages
        let historical = try DocumentValue.strictDecode(
            AttachmentDocumentRepresentation.self,
            data: JSONSerialization.data(withJSONObject: oldWire))
        try historical.validate()
        XCTAssertEqual(try AttachmentDocumentRepresentation(historical.itemValue), historical)
        XCTAssertEqual(
            try historical.remapping(attachmentID: copyID, representationID: copyID).identity,
            historical.identity)
        XCTAssertThrowsError(try historical.identity.validateCurrent())
        XCTAssertNotEqual(historical.identity, DocumentConverterIdentity())
        try DocumentConverterIdentity().validateCurrent()
        var unknown = oldIdentity
        unknown["converter"] = "tractanda.docling-native.v2-unknown-patch"
        let unknownIdentity = try JSON.decode(
            DocumentConverterIdentity.self, JSONSerialization.data(withJSONObject: unknown))
        XCTAssertThrowsError(try unknownIdentity.validate())
        XCTAssertThrowsError(try unknownIdentity.validateCurrent())
        var forged = try XCTUnwrap(value.map)
        forged["unrecognized"] = .text("hidden")
        XCTAssertThrowsError(try AttachmentDocumentRepresentation(.object(forged)))
    }

    func testGeometryAndTruncationAreAdmissionFailures() throws {
        XCTAssertThrowsError(
            try DocumentPageGeometry(
                sourceWidth: 512, sourceHeight: 256, sourceUnit: "pixel",
                displayWidth: 512, displayHeight: 256,
                contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 2048))
        let parsed = try DoclingParsedPage(rawDocTags: "<doctag></doctag>", blocks: [], text: "")
        XCTAssertThrowsError(
            try AttachmentDocumentPage(
                pageNumber: 1, geometry: geometry(), rasterSHA256: sourceDigest, parsed: parsed,
                generatedTokens: 1024, stopReason: "length"))
    }

    func testCroppedGeometryPreservesFractionalMarginsAndUniformSourceScale() throws {
        let portrait = try DocumentPageGeometry(
            sourceWidth: 612, sourceHeight: 792, sourceUnit: "pdfPoint",
            displayWidth: 612, displayHeight: 792, canvasWidth: 1584, canvasHeight: 2048,
            contentLeft: 8.0 / 11, contentTop: 0, contentWidth: 17_408.0 / 11, contentHeight: 2048)
        XCTAssertEqual(portrait.scale, 2048.0 / 792, accuracy: 0.000001)
        let box = try DoclingBoundingBox(left: 125, top: 125, right: 375, bottom: 375)
        let rasterX = Double(box.left) / 500 * Double(portrait.canvasWidth)
        let rasterY = Double(box.top) / 500 * Double(portrait.canvasHeight)
        XCTAssertEqual((rasterX - portrait.contentLeft) / portrait.scale, 152.859375, accuracy: 0.000001)
        XCTAssertEqual((rasterY - portrait.contentTop) / portrait.scale, 198, accuracy: 0.000001)
        try portrait.validateContentCrop()
        let syntheticSquare = try DocumentPageGeometry(
            sourceWidth: 512, sourceHeight: 256, sourceUnit: "pixel",
            displayWidth: 512, displayHeight: 256,
            contentLeft: 0, contentTop: 512, contentWidth: 2048, contentHeight: 1024)
        XCTAssertThrowsError(try syntheticSquare.validateContentCrop())
        XCTAssertThrowsError(
            try DocumentPageGeometry(
                sourceWidth: 612, sourceHeight: 792, sourceUnit: "pdfPoint",
                displayWidth: 612, displayHeight: 792, canvasWidth: 2049, canvasHeight: 2048,
                contentLeft: 0, contentTop: 0, contentWidth: 17_408.0 / 11, contentHeight: 2048))
    }
    func testStoredReferenceRoundTripIsIndependentOfAggregateContentSize() throws {
        let source = try AttachmentDocumentSource(
            itemID: id, revisionID: id, attachmentID: id,
            sha256: sourceDigest, byteCount: 1_073_741_825, mediaType: "application/pdf")
        let coverage = try DocumentCoverage(converted: 1_000_000)
        let reference = try DocumentContentReference(
            contentID: id, manifestSHA256: sourceDigest, rootSHA256: sourceDigest,
            pageCount: 1_000_000, totalEncodedBytes: 100_000_000, coverage: coverage)
        let document = try AttachmentDocumentRepresentation(
            representationID: id, attachmentID: id, source: source,
            extractedAt: "2026-10-11T12:00:00Z", identity: .init(), content: reference)
        XCTAssertTrue(document.pages.isEmpty)
        XCTAssertLessThan(try JSON.encode(document).count, 4096)
        XCTAssertEqual(try AttachmentDocumentRepresentation(document.itemValue), document)
        XCTAssertThrowsError(try DocumentCoverage(converted: .max, failed: 1))
    }

    func testBoundedJobTimeoutMessageRoundTripsAndAbsentFieldIsNil() throws {
        let status = DocumentJobStatus(
            jobID: id, itemID: id, attachmentID: id, sourceRevisionID: id,
            expectedRevisionID: id, state: "paused", reasonCode: "documentTimeout",
            reasonMessage: "phase=unknown; timeout=noProgress; budgetSeconds=60.0; elapsedSeconds=61.0",
            pageCount: nil, acceptedPages: 0, coverage: try DocumentCoverage(converted: 0),
            discarded: false, committed: nil)
        try status.validate()
        let bytes = try JSON.encode(status)
        let decoded = try JSON.decode(DocumentJobStatus.self, bytes)
        XCTAssertEqual(decoded.reasonCode, "documentTimeout")
        XCTAssertEqual(decoded.reasonMessage, status.reasonMessage)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "reasonMessage")
        let absent = try JSON.decode(
            DocumentJobStatus.self, JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(absent.reasonMessage)
        try absent.validate()
        object["reasonMessage"] = String(repeating: "x", count: 513)
        XCTAssertThrowsError(
            try JSON.decode(DocumentJobStatus.self, JSONSerialization.data(withJSONObject: object))
                .validate())
        object["reasonMessage"] = "phase=unknown"
        object["reasonCode"] = "userCancelled"
        XCTAssertThrowsError(
            try JSON.decode(DocumentJobStatus.self, JSONSerialization.data(withJSONObject: object))
                .validate())
    }

}
