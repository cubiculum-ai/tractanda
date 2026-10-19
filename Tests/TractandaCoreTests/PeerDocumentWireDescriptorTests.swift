import XCTest

@testable import TractandaCore

final class PeerDocumentWireDescriptorTests: XCTestCase {
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }

    private func wire(
        id: String, role: String, level: Int64, ordinal: Int64, length: Int64 = 1
    ) -> ItemValue {
        .object([
            "kind": .text("document"), "id": .text(id), "length": .integer(length),
            "sha256": .text(String(repeating: "a", count: 64)),
            "part": .object([
                "role": .text(role), "level": .integer(level), "ordinal": .integer(ordinal),
            ]),
        ])
    }

    private func assertRejected(_ value: ItemValue, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PeerExchangeState.decodeDescriptor(value), file: file, line: line)
    }

    func testManifestNodeAndPageRoundTripWithOneContentIdentity() throws {
        let contentID = try id()
        let values = [
            wire(id: contentID, role: "manifest", level: 0, ordinal: 0, length: 64 * 1024),
            wire(id: contentID, role: "node", level: 8, ordinal: 127, length: 64 * 1024),
            wire(id: contentID, role: "page", level: 0, ordinal: 1, length: 2 * 1024 * 1024),
        ]

        for value in values {
            let decoded = try PeerExchangeState.decodeDescriptor(value)
            XCTAssertEqual(PeerExchangeState.descriptor(decoded), value)
            XCTAssertEqual(decoded.kind, .document)
            XCTAssertEqual(decoded.id, contentID)
        }
    }

    func testDescriptorRequiresExactFieldsAndRejectsSenderPaths() throws {
        let valid = wire(id: try id(), role: "manifest", level: 0, ordinal: 0)
        guard case .object(let fields) = valid else { return XCTFail("Expected object") }

        var missing = fields
        missing.removeValue(forKey: "sha256")
        assertRejected(.object(missing))

        var extra = fields
        extra["path"] = .text("manifest.json")
        assertRejected(.object(extra))

        var extraPart = fields
        if case .object(var part) = extraPart["part"] {
            part["path"] = .text("manifest.json")
            extraPart["part"] = .object(part)
        }
        assertRejected(.object(extraPart))
        assertRejected(.object(["kind": .text("document")]))
    }

    func testPartRoleAndCoordinatesMustBeCanonical() throws {
        let contentID = try id()
        for value in [
            wire(id: contentID, role: "unknown", level: 0, ordinal: 0),
            wire(id: contentID, role: "manifest", level: 1, ordinal: 0),
            wire(id: contentID, role: "manifest", level: 0, ordinal: 1),
            wire(id: contentID, role: "node", level: -1, ordinal: 0),
            wire(id: contentID, role: "node", level: 9, ordinal: 0),
            wire(id: contentID, role: "node", level: 0, ordinal: -1),
            wire(id: contentID, role: "page", level: 1, ordinal: 1),
            wire(id: contentID, role: "page", level: 0, ordinal: 0),
        ] {
            assertRejected(value)
        }
    }

    func testDocumentPartLengthsAreBoundedWithoutPayloadAllocation() throws {
        let contentID = try id()
        assertRejected(wire(id: contentID, role: "manifest", level: 0, ordinal: 0, length: 64 * 1024 + 1))
        assertRejected(wire(id: contentID, role: "node", level: 0, ordinal: 0, length: 64 * 1024 + 1))
        assertRejected(
            wire(id: contentID, role: "page", level: 0, ordinal: 1, length: 2 * 1024 * 1024 + 1))
        assertRejected(wire(id: contentID, role: "page", level: 0, ordinal: 1, length: 0))
    }

    func testOnlyV3DocumentsCanCarryPartsAndEmptyOriginalRemainsValid() throws {
        let contentID = try id()
        guard
            case .object(let documentFields) = wire(
                id: contentID, role: "manifest", level: 0, ordinal: 0)
        else { return XCTFail("Expected object") }

        var item = documentFields
        item["kind"] = .text("item")
        assertRejected(.object(item))

        var attachment = documentFields
        attachment["kind"] = .text("attachment")
        assertRejected(.object(attachment))

        let emptyOriginal = ItemValue.object([
            "kind": .text("attachment"), "id": .text(try id()), "length": .integer(0),
            "sha256": .text(PeerPackage.emptySHA256),
        ])
        let decoded = try PeerExchangeState.decodeDescriptor(emptyOriginal)
        XCTAssertEqual(decoded.length, 0)
        XCTAssertNil(decoded.part)
        XCTAssertEqual(PeerExchangeState.descriptor(decoded), emptyOriginal)
    }
}
