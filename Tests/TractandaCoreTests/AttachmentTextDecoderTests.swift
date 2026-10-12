import Crypto
import XCTest

@testable import TractandaCore

final class AttachmentTextDecoderTests: XCTestCase {
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }

    private func id(_ offset: UInt64 = 0) throws -> String {
        let fields = try UUID.makeVersion1().version1Components!
        return try UUIDVersion1Components(
            timestamp: fields.timestamp + offset, clockSequence: fields.clockSequence, node: fields.node
        )
        .uuid.uuidString.lowercased()
    }

    private func source(_ data: Data, mediaType: String = "text/plain", attachmentID: String? = nil) throws
        -> AttachmentTextSource
    {
        try AttachmentTextSource(
            itemID: id(), revisionID: id(), attachmentID: attachmentID ?? id(),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(data.count), mediaType: mediaType)
    }

    private func decode(_ data: Data, mediaType: String = "text/plain") throws
        -> AttachmentTextRepresentation
    {
        let source = try source(data, mediaType: mediaType)
        return try AttachmentTextDecoder.decode(
            data, source: source, representationID: id(), attachmentID: source.attachmentID,
            extractedAt: "2026-09-29T10:00:00Z")
    }

    private func assertCode<T>(
        _ code: String, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> T
    ) {
        do {
            _ = try operation()
            XCTFail("Expected error code \(code)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? TractandaError)?.code, code, "\(error)", file: file, line: line)
        }
    }

    func testDecoderPreservesUTF8AndStripsOnlyOneLeadingBOM() throws {
        let bytes =
            Data([0xEF, 0xBB, 0xBF]) + Data("café\r\n\0".utf8)
            + Data([0xEF, 0xBB, 0xBF]) + Data("tail".utf8)
        let representation = try decode(bytes, mediaType: "text/markdown")
        XCTAssertEqual(representation.text, "café\r\n\0\u{FEFF}tail")
        XCTAssertEqual(representation.sourceByteStart, 3)
        XCTAssertEqual(representation.text.utf8.count, bytes.count - 3)

        let doubleBOM = try decode(Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF]) + Data("x".utf8))
        XCTAssertEqual(doubleBOM.text, "\u{FEFF}x")
        XCTAssertEqual(doubleBOM.sourceByteStart, 3)
        let noBOM = try decode(Data("a\r\nb".utf8))
        XCTAssertEqual(noBOM.text, "a\r\nb")
        XCTAssertEqual(noBOM.sourceByteStart, 0)
    }

    func testDecoderEnforcesInputAndSourceIntegrity() throws {
        let limit = AttachmentTextRepresentation.maximumInputBytes
        let boundary = Data(repeating: 0x61, count: limit)
        XCTAssertEqual(try decode(boundary).text.utf8.count, limit)
        assertCode("resourceLimit") { try decode(Data(repeating: 0x61, count: limit + 1)) }
        assertCode("invalidAttachmentText") { try decode(Data([0xC3, 0x28])) }

        let bytes = Data("valid".utf8)
        let validSource = try source(bytes)
        let wrongDigest = try AttachmentTextSource(
            itemID: validSource.itemID, revisionID: validSource.revisionID,
            attachmentID: validSource.attachmentID, sha256: String(repeating: "0", count: 64),
            byteCount: validSource.byteCount, mediaType: validSource.mediaType)
        assertCode("attachmentIntegrity") {
            try AttachmentTextDecoder.decode(
                bytes, source: wrongDigest, representationID: id(), attachmentID: wrongDigest.attachmentID,
                extractedAt: "2026-09-29T10:00:00Z")
        }
        assertCode("attachmentIntegrity") {
            try AttachmentTextDecoder.decode(
                bytes, source: validSource, representationID: id(), attachmentID: id(),
                extractedAt: "2026-09-29T10:00:00Z")
        }
        let wrongSize = try AttachmentTextSource(
            itemID: validSource.itemID, revisionID: validSource.revisionID,
            attachmentID: validSource.attachmentID, sha256: validSource.sha256,
            byteCount: 4, mediaType: validSource.mediaType)
        assertCode("attachmentIntegrity") {
            try AttachmentTextDecoder.decode(
                bytes, source: wrongSize, representationID: id(), attachmentID: wrongSize.attachmentID,
                extractedAt: "2026-09-29T10:00:00Z")
        }
        assertCode("unsupportedAttachmentText") {
            _ = try AttachmentTextSource(
                itemID: id(), revisionID: id(), attachmentID: id(), sha256: validSource.sha256,
                byteCount: validSource.byteCount, mediaType: "application/pdf")
        }
        let caseVariant = try AttachmentTextSource(
            itemID: validSource.itemID, revisionID: validSource.revisionID,
            attachmentID: validSource.attachmentID, sha256: validSource.sha256,
            byteCount: validSource.byteCount, mediaType: "TEXT/PLAIN")
        XCTAssertEqual(caseVariant.mediaType, "TEXT/PLAIN")
    }

    func testRepresentationTaggedAndCodableRoundTripsAndRemapsOnlyLocalIDs() throws {
        let original = try decode(Data("source text".utf8))
        let tagged = try AttachmentTextRepresentation(original.itemValue)
        XCTAssertEqual(tagged, original)
        XCTAssertEqual(try JSON.decode(AttachmentTextRepresentation.self, JSON.encode(original)), original)
        XCTAssertEqual(original.itemValue.map?["extractedAt"]?.dateString, original.extractedAt)
        XCTAssertEqual(original.itemValue.map?["state"]?.string, "complete")

        let clone = try original.remapping(attachmentID: id(), representationID: id())
        XCTAssertNotEqual(clone.attachmentID, original.attachmentID)
        XCTAssertNotEqual(clone.representationID, original.representationID)
        XCTAssertEqual(clone.source, original.source)
        XCTAssertEqual(clone.text, original.text)
        try AttachmentTextDecoder.validate(clone)
        let altered = try AttachmentTextRepresentation(
            representationID: id(), attachmentID: id(), source: original.source,
            extractedAt: original.extractedAt, text: "changedtext", sourceByteStart: 0)
        assertCode("attachmentIntegrity") { try AttachmentTextDecoder.validate(altered) }

        var unknown = try JSON.encode(original)
        unknown.removeLast()
        unknown.append(contentsOf: Data(",\"unexpected\":true}".utf8))
        assertCode("invalidAttachmentText") {
            try JSON.decode(AttachmentTextRepresentation.self, unknown)
        }
        var malformed = original.itemValue.map!
        malformed["state"] = .text("partial")
        assertCode("invalidAttachmentText") {
            try AttachmentTextRepresentation(.object(malformed))
        }
    }

    func testRepresentationListCapsCountAndEncodedAggregateBytes() throws {
        let first = try decode(Data("x".utf8))
        XCTAssertEqual(
            try AttachmentTextRepresentation.representations(
                in: [AttachmentTextRepresentation.fieldName: .list([first.itemValue])]), [first])
        assertCode("invalidAttachmentText") {
            try AttachmentTextRepresentation.representations(
                in: [AttachmentTextRepresentation.fieldName: .list([first.itemValue, first.itemValue])])
        }

        let many = try (0..<129).map { _ in try decode(Data("".utf8)) }
        assertCode("resourceLimit") {
            try AttachmentTextRepresentation.representations(
                in: [AttachmentTextRepresentation.fieldName: .list(many.map(\.itemValue))])
        }

        let largeText = String(repeating: "\u{1}", count: 44_000)
        let largeData = Data(largeText.utf8)
        let largeSource = try source(largeData)
        let largeEntries = try (0..<8).map { offset in
            try AttachmentTextRepresentation(
                representationID: id(UInt64(offset)), attachmentID: id(UInt64(offset + 100)),
                source: largeSource, extractedAt: "2026-09-29T10:00:00Z", text: largeText,
                sourceByteStart: 0)
        }
        XCTAssertLessThan(largeText.utf8.count, AttachmentTextRepresentation.maximumInputBytes)
        XCTAssertGreaterThan(
            try JSON.encode(ItemValue.list(largeEntries.map(\.itemValue))).count,
            AttachmentTextRepresentation.maximumAggregateEncodedBytes)
        assertCode("resourceLimit") {
            try AttachmentTextRepresentation.representations(
                in: [AttachmentTextRepresentation.fieldName: .list(largeEntries.map(\.itemValue))])
        }
    }
}
