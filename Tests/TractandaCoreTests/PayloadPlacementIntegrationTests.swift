import Crypto
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PayloadPlacementIntegrationTests: XCTestCase {
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }

    private func attach(_ store: ItemStore) throws -> (Revision, AttachmentDescriptor) {
        let revision = try store.commit(CommitRequest(classID: "Item", operationID: "base")).revision
        let bytes = Data("arrival-original".utf8)
        let upload = try store.beginAttachment(
            AttachmentUploadRequest(
                itemID: revision.itemID, expectedRevisionID: revision.revisionID, operationID: "attach",
                filename: "opaque.zip", mediaType: "application/zip", byteCount: Int64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
        let id = try XCTUnwrap(upload.uploadID)
        _ = try store.appendAttachment(uploadID: id, offset: 0, data: bytes)
        return (try store.finishAttachment(uploadID: id).revision, upload.attachment)
    }

    func testOrdinaryStoreReopensAndItemRebuildReusesValidPlacementLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "placement-integration-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let revision: Revision
        let descriptor: AttachmentDescriptor
        do {
            let store = try AttachmentFixtureCapacity.makeStore(root: root)
            (revision, descriptor) = try attach(store)
            let required = try XCTUnwrap(
                CanonicalReaderRequirement.load(root: root, ownerUID: UInt32(getuid())))
            XCTAssertEqual(required.minimumReaderLevel, 8)
            XCTAssertTrue(required.capabilities.contains(PayloadPlacement.capability))
            XCTAssertFalse(required.capabilities.contains(AuthorityStore.capability))
        }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        XCTAssertEqual(store.payloadPlacementRecoveryScansForTesting, 0)
        XCTAssertEqual(
            try store.attachmentContent(itemID: revision.itemID, attachmentID: descriptor.attachmentID).data,
            Data("arrival-original".utf8))
        try store.rebuildIndex()
        XCTAssertEqual(
            store.payloadPlacementRecoveryScansForTesting, 0,
            "Independent item catalogue rebuilding must not enumerate payload archives.")
        XCTAssertEqual(try store.get(revision.itemID).revisionID, revision.revisionID)
        XCTAssertEqual(
            try store.attachmentContent(itemID: revision.itemID, attachmentID: descriptor.attachmentID).data,
            Data("arrival-original".utf8))
    }

    func testExternalLookupBindingBeforeUploadRecoveryAndStandaloneWrongRootRefuses() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
            "placement-external-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("canonical")
        let external = fixture.appendingPathComponent("derived")
        let revision: Revision
        let descriptor: AttachmentDescriptor
        do {
            let store = try ItemStore(
                root: root, indexDirectory: external,
                attachmentUploadPolicy: AttachmentUploadPolicy(
                    minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
            (revision, descriptor) = try attach(store)
        }
        do {
            let store = try ItemStore(
                root: root, indexDirectory: external,
                attachmentUploadPolicy: AttachmentUploadPolicy(
                    minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
            XCTAssertEqual(
                try store.attachmentContent(itemID: revision.itemID, attachmentID: descriptor.attachmentID)
                    .data, Data("arrival-original".utf8))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: external.appendingPathComponent("payloads.sqlite").path))
        }
        let otherRoot = fixture.appendingPathComponent("other")
        do { _ = try AttachmentFixtureCapacity.makeStore(root: otherRoot) }
        let wrong = try AttachmentPayloadStore(
            root: otherRoot, ownerUID: UInt32(getuid()), reserveBytes: 0, indexDirectory: external)
        XCTAssertThrowsError(try wrong.resolvedPayloadPath(descriptor.attachmentID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "unsafeAttachmentStore")
        }
        let correct = try AttachmentPayloadStore(
            root: root, ownerUID: UInt32(getuid()), reserveBytes: 0, indexDirectory: external)
        XCTAssertEqual(
            try correct.read(descriptor: descriptor, offset: 0, limit: 32), Data("arrival-original".utf8))
    }

    func testConverterRetainsActualArrivalPathAndValidatesSameFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "placement-converter-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try AttachmentPayloadStore(root: root, ownerUID: UInt32(getuid()), reserveBytes: 0)
        storage.placementArrivalMinuteForTesting = { "2026/10/16/02/00" }
        let components = try XCTUnwrap(UUID.makeVersion1().version1Components)
        let id = try UUIDVersion1Components(
            timestamp: components.timestamp - 365 * 24 * 60 * 60 * 10_000_000,
            clockSequence: components.clockSequence, node: components.node
        ).uuid.uuidString.lowercased()
        let bytes = Data("source".utf8)
        let descriptor = try AttachmentDescriptor(
            attachmentID: id, filename: "source.pdf", mediaType: "application/pdf",
            byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try storage.createStaging(id: id)
        _ = try storage.append(id: id, offset: 0, data: bytes)
        try storage.publish(descriptor: descriptor)
        let source = try storage.prepareDocumentOriginal(
            descriptor: descriptor, cancellation: DocumentConversionCancellation(), progress: { _ in })
        XCTAssertEqual(
            source.path,
            root.appendingPathComponent("attachments/payloads/2026/10/16/02/00/" + id + ".payload").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source.path)), bytes)
        try source.check()
    }

    func testStoreDoesNotMintReplacementIdentityForRetainedOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "placement-missing-identity-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try AttachmentFixtureCapacity.makeStore(root: root)
            _ = try attach(store)
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".tractanda-store-identity.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("canonical-reader.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
        XCTAssertThrowsError(try AttachmentFixtureCapacity.makeStore(root: root)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidStoreIdentity")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".tractanda-store-identity.json").path))
    }
}
