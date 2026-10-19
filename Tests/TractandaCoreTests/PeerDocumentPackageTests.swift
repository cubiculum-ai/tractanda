import XCTest

@testable import TractandaCore

final class PeerDocumentPackageTests: XCTestCase {
    private func id() throws -> String {
        try UUID.makeVersion1().uuidString.lowercased()
    }

    private func document(
        _ part: PeerPackage.DocumentPart?, id: String? = nil, length: Int = 1
    ) throws -> PeerPackage.Object {
        PeerPackage.Object(
            kind: .document, id: try id ?? self.id(), length: length,
            sha256: String(repeating: "a", count: 64), part: part)
    }

    private func code(
        _ expected: String, _ body: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }

    /// This models the descriptor framing written before the optional `part` field existed.
    private struct RetainedObjectV2: Codable {
        let kind: PeerPackage.Kind
        let id: String
        let length: Int
        let sha256: String
    }

    func testRetainedV1AndV2ObjectBytesAndHashesSurviveDecodeAndEncode() throws {
        let legacy = RetainedObjectV2(
            kind: .item, id: try id(), length: 17, sha256: String(repeating: "b", count: 64))
        let frozenBytes = try JSON.encode(legacy)
        let frozenHash = AuthorityRecordCodec.sha256(frozenBytes)

        let retained = try PeerPackage.decode(PeerPackage.Object.self, frozenBytes)
        try retained.validate(retainedProfile: PeerPackage.retainedMetadataProfile)
        let rewritten = try JSON.encode(retained)
        XCTAssertEqual(rewritten, frozenBytes)
        XCTAssertEqual(AuthorityRecordCodec.sha256(rewritten), frozenHash)

        let oldOriginal = RetainedObjectV2(
            kind: .attachment, id: try id(), length: 19,
            sha256: String(repeating: "c", count: 64))
        let originalBytes = try JSON.encode(oldOriginal)
        let originalHash = AuthorityRecordCodec.sha256(originalBytes)
        let retainedOriginal = try PeerPackage.decode(PeerPackage.Object.self, originalBytes)
        try retainedOriginal.validate(retainedProfile: PeerPackage.retainedOriginalProfile)
        let originalRewrite = try JSON.encode(retainedOriginal)
        XCTAssertEqual(originalRewrite, originalBytes)
        XCTAssertEqual(AuthorityRecordCodec.sha256(originalRewrite), originalHash)
    }

    func testCompositePartKeysDistinguishPartsForOneCanonicalContentID() throws {
        let contentID = try id()
        let manifest = try document(.manifest, id: contentID)
        let node = try document(.init(role: .node, level: 0, ordinal: 0), id: contentID)
        let page = try document(.init(role: .page, level: 0, ordinal: 1), id: contentID)

        XCTAssertEqual(Set([manifest.key, node.key, page.key]).count, 3)
        XCTAssertEqual(manifest.id, node.id)
        XCTAssertEqual(node.id, page.id)
        XCTAssertNoThrow(try manifest.validate())
        XCTAssertNoThrow(try node.validate())
        XCTAssertNoThrow(try page.validate())
    }

    func testDocumentPartAddressesEnforceRoleRangesAndCheckedLengthBounds() throws {
        XCTAssertNoThrow(try document(.manifest, length: 64 * 1024).validate())
        XCTAssertNoThrow(
            try document(.init(role: .node, level: 8, ordinal: Int64.max), length: 64 * 1024).validate())
        XCTAssertNoThrow(
            try document(.init(role: .page, level: 0, ordinal: Int64.max), length: 2 * 1024 * 1024).validate()
        )

        code("resourceLimit") { try document(.manifest, length: 64 * 1024 + 1).validate() }
        code("resourceLimit") {
            try document(.init(role: .node, level: 0, ordinal: 0), length: 64 * 1024 + 1).validate()
        }
        code("resourceLimit") {
            try document(.init(role: .page, level: 0, ordinal: 1), length: 2 * 1024 * 1024 + 1).validate()
        }
        for part in [
            PeerPackage.DocumentPart(role: .manifest, level: 1, ordinal: 0),
            PeerPackage.DocumentPart(role: .manifest, level: 0, ordinal: 1),
            PeerPackage.DocumentPart(role: .node, level: -1, ordinal: 0),
            PeerPackage.DocumentPart(role: .node, level: 9, ordinal: 0),
            PeerPackage.DocumentPart(role: .node, level: 0, ordinal: -1),
            PeerPackage.DocumentPart(role: .page, level: 1, ordinal: 1),
            PeerPackage.DocumentPart(role: .page, level: 0, ordinal: 0),
            PeerPackage.DocumentPart(role: .page, level: 0, ordinal: -1),
        ] {
            code("invalidPeerPackage") { try document(part).validate() }
        }
        code("resourceLimit") { try document(.manifest, length: 0).validate() }
    }

    func testPartsAreForbiddenForOtherKindsAndRetainedProfiles() throws {
        let part = PeerPackage.DocumentPart.manifest
        let item = PeerPackage.Object(
            kind: .item, id: try id(), length: 1, sha256: String(repeating: "a", count: 64), part: part)
        code("invalidPeerPackage") { try item.validate() }

        let freshV2 = try PeerPackage.Manifest(
            packageID: id(), storeID: id(),
            root: PeerPackage.Object(
                kind: .index, id: id(), length: 1, sha256: String(repeating: "d", count: 64)),
            profile: PeerPackage.retainedOriginalProfile)
        code("invalidPeerPackage") { try freshV2.validate() }
        XCTAssertNoThrow(try freshV2.validate(retained: true))

        let v2Document = try document(part)
        code("invalidPeerPackage") {
            try v2Document.validate(retainedProfile: PeerPackage.retainedOriginalProfile)
        }
        code("invalidPeerPackage") {
            try v2Document.validate(retainedProfile: PeerPackage.retainedMetadataProfile)
        }
        code("resourceLimit") {
            try document(nil).validate(retainedProfile: PeerPackage.profile)
        }
    }

    func testPackageIndexCanAnchorDocumentManifestButCannotLaunderOtherParts() throws {
        let manifest = try document(.manifest)
        XCTAssertNoThrow(try PeerPackage.Page(objects: [manifest], children: []).validate())

        for part in [
            PeerPackage.DocumentPart(role: .node, level: 0, ordinal: 0),
            PeerPackage.DocumentPart(role: .page, level: 0, ordinal: 1),
        ] {
            let hiddenPart = try document(part)
            let page = PeerPackage.Page(objects: [hiddenPart], children: [])
            code("invalidPeerPackage") { try page.validate() }
        }
    }
}
