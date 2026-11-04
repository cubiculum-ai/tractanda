import Foundation
import TractandaClient
import XCTest
@testable import TractandaLayout17

final class LegacyRecordCodecTests: XCTestCase {
    private func revision(_ version: Int) throws -> Revision {
        var fields: [String: ItemValue] = [
            "itemID": .text("00000000-0000-1000-8000-000000000001"),
            "revisionID": .text("00000000-0000-1000-8000-000000000002"),
            "classID": .text("Note"), "actor": .text("user:test"),
            "operationID": .text("old-op"), "requestIdentity": .text("opaque-exact-retry"),
            "createdAt": .date("2026-11-03T10:00:00.000Z"),
            "modifiedAt": .date("2026-11-03T10:01:00.000Z"),
            "schemaVersion": .integer(1), "subject": .text("Original"),
            "body": .text("line one\nline two"),
        ]
        if version == 2 {
            let ancestry = try RevisionProvenance(kind: .authored,
                originReplicaID: "00000000-0000-1000-8000-000000000003", parents: [],
                writtenFields: ["body", "classID", "schemaVersion", "subject"], unsetFields: [], frontier: [])
            fields["revisionAncestry"] = ancestry.itemValue
        }
        return try Revision(fields: fields, formatVersion: version)
    }

    private func oldEnvelope(_ value: Revision) throws -> Data {
        let headers = ["MIME-Version: 1.0", "Content-Type: application/vnd.tractanda.item+json; charset=utf-8",
            "X-Tractanda-Format-Version: \(value.formatVersion)", "X-IsA: \(value.classID)",
            "X-Item-ID: \(value.itemID)", "X-Revision-ID: \(value.revisionID)"]
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + (try JSON.encode(value)) + Data([10])
    }

    func testLegacyVersionsRemainDistinctAndPreserveEveryField() throws {
        for version in [1, 2] {
            let original = try revision(version)
            let decoded = try LegacyRecordCodec.decode(oldEnvelope(original))
            XCTAssertEqual(decoded, original)
            XCTAssertEqual(decoded.formatVersion, version)
            XCTAssertEqual(decoded.fields["requestIdentity"], .text("opaque-exact-retry"))
            XCTAssertEqual(decoded.fields["revisionAncestry"] == nil, version == 1)
        }
    }

    func testMalformedAndMismatchedEnvelopesAreRejected() throws {
        let original = try revision(1)
        let text = String(decoding: try oldEnvelope(original), as: UTF8.self)
        let wrongID = text.replacingOccurrences(of: "X-Item-ID: \(original.itemID)",
            with: "X-Item-ID: 00000000-0000-1000-8000-000000000004")
        XCTAssertThrowsError(try LegacyRecordCodec.decode(Data(wrongID.utf8)))
        let duplicate = text.replacingOccurrences(of: "MIME-Version: 1.0",
            with: "MIME-Version: 1.0\r\nMIME-Version: 1.0")
        XCTAssertThrowsError(try LegacyRecordCodec.decode(Data(duplicate.utf8)))
        XCTAssertThrowsError(try LegacyRecordCodec.decode(Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1)))
    }
}
