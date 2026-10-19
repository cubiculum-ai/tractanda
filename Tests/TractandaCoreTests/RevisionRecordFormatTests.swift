import XCTest

@testable import TractandaCore

final class RevisionRecordFormatTests: XCTestCase {
    private func fields() throws -> [String: ItemValue] {
        [
            "itemID": .text(try UUID.makeVersion1().uuidString.lowercased()),
            "revisionID": .text(try UUID.makeVersion1().uuidString.lowercased()),
            "classID": .text("Item"), "schemaVersion": .integer(1),
            "createdAt": .date("2026-10-13T12:00:00Z"), "modifiedAt": .date("2026-10-13T12:00:00Z"),
            "actor": .text("user:fixture"), "operationID": .text("fixture"),
            "requestIdentity": .text("fixture"), "subject": .text("content"),
        ]
    }

    private func modernFields() throws -> [String: ItemValue] {
        var fields = try fields()
        let legacy = try Revision(fields: fields)
        fields["revisionAncestry"] = try RevisionProvenance(
            kind: .authored, originReplicaID: UUID.makeVersion1().uuidString.lowercased(), parents: [],
            writtenFields: RevisionMerge.semanticFields(legacy).keys.sorted(), unsetFields: [], frontier: []
        ).itemValue
        return fields
    }

    func testLegacyFormatOneCodecRoundTripPreservesEnvelopeBytes() throws {
        let record = try Revision(fields: fields())
        let bytes = try RecordCodec.encode(record)
        XCTAssertEqual(record.formatVersion, 1)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("X-Tractanda-Format-Version: 1\r\n"))
        XCTAssertEqual(try RecordCodec.decode(bytes), record)
        XCTAssertEqual(try RecordCodec.encode(RecordCodec.decode(bytes)), bytes)
    }

    func testModernFormatTwoRoundTripAndHeaderBodyMismatchRejection() throws {
        let record = try Revision(fields: modernFields(), formatVersion: 2)
        let bytes = try RecordCodec.encode(record)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("X-Tractanda-Format-Version: 2\r\n"))
        XCTAssertEqual(try RecordCodec.decode(bytes), record)
        XCTAssertEqual(try JSON.decode(Revision.self, JSON.encode(record)), record)
        XCTAssertThrowsError(
            try RecordCodec.decode(
                Data(
                    text.replacingOccurrences(
                        of: "X-Tractanda-Format-Version: 2", with: "X-Tractanda-Format-Version: 1"
                    ).utf8)))
    }

    func testLegacyWithAncestryAndModernWithoutAncestryFailClosed() throws {
        XCTAssertThrowsError(try Revision(fields: modernFields(), formatVersion: 1))
        XCTAssertThrowsError(try Revision(fields: fields(), formatVersion: 2))
        XCTAssertThrowsError(try Revision(fields: fields(), formatVersion: 3))
    }
}
