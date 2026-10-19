import XCTest

@testable import TractandaCore

final class PeerPackageProfileTests: XCTestCase {
    private func id() throws -> String {
        try UUID.makeVersion1().uuidString.lowercased()
    }

    private func object(
        _ kind: PeerPackage.Kind, length: Int, sha256: String = String(repeating: "a", count: 64)
    ) throws -> PeerPackage.Object {
        PeerPackage.Object(kind: kind, id: try id(), length: length, sha256: sha256)
    }

    private func indexRoot() throws -> PeerPackage.Object {
        try object(.index, length: 1)
    }

    private func code(
        _ expected: String, _ body: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }

    func testIncomingV1ManifestIsRejectedWhileRetainedV1MetadataIsAccepted() throws {
        let manifest = PeerPackage.Manifest(
            packageID: try id(), storeID: try id(), root: try indexRoot(),
            profile: PeerPackage.retainedMetadataProfile)

        code("invalidPeerPackage") { try manifest.validate() }
        XCTAssertNoThrow(try manifest.validate(retained: true))
    }

    func testRetainedV1AttachmentAndNewDocumentObjectsAreRejected() throws {
        let retainedAttachment = try object(.attachment, length: 1)
        code("resourceLimit") {
            try retainedAttachment.validate(retainedProfile: PeerPackage.retainedMetadataProfile)
        }

        let document = try object(.document, length: 1)
        code("resourceLimit") { try document.validate() }
    }

    func testMetadataObjectsRequirePositiveLength() throws {
        let emptyItem = try object(.item, length: 0)
        code("resourceLimit") { try emptyItem.validate() }
    }

    func testEmptyAttachmentRequiresExactEmptyDigest() throws {
        let valid = try object(
            .attachment, length: 0, sha256: PeerPackage.emptySHA256)
        XCTAssertNoThrow(try valid.validate())

        let invalid = try object(.attachment, length: 0)
        code("invalidPeerPackage") { try invalid.validate() }
    }

    func testLargeAttachmentDescriptorAndMetadataBoundsNeedNoPayloadAllocation() throws {
        let large = try object(.attachment, length: Int(exactly: Int64.max)!)
        XCTAssertNoThrow(try large.validate())

        XCTAssertNoThrow(try object(.item, length: 8 * 1024 * 1024).validate())
        code("resourceLimit") { try object(.item, length: 8 * 1024 * 1024 + 1).validate() }
        XCTAssertNoThrow(try object(.authority, length: 128 * 1024).validate())
        code("resourceLimit") { try object(.authority, length: 128 * 1024 + 1).validate() }
    }

    func testIndexPageCannotLaunderUnsupportedObjects() throws {
        let document = try object(.document, length: 1)
        let page = PeerPackage.Page(objects: [document], children: [])
        code("resourceLimit") { try page.validate() }

        let legacyAttachment = try object(.attachment, length: 1)
        let retainedPage = PeerPackage.Page(objects: [legacyAttachment], children: [])
        code("resourceLimit") {
            try retainedPage.validate(retainedProfile: PeerPackage.retainedMetadataProfile)
        }
    }
}
