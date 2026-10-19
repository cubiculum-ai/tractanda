import Foundation
import XCTest

@testable import TractandaCore

/// Cold restores use an independent retained-file allowlist, never a copied store/index tree.
final class ClusterCanonicalRestoreTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture

    private func restore(
        _ source: URL, fixture: Fixture, payloads: Bool = false,
        credentials: Bool = false
    ) throws -> URL {
        // Two original stores plus one restored tiny store are predicted below 24 MiB.
        guard 24 * 1024 * 1024 <= AttachmentFixtureCapacity.fixtureCapBytes else {
            throw TractandaError("resourceLimit", "Restore fixture estimate exceeds its cap")
        }
        try fixture.capacity()
        let destination = fixture.directory.appendingPathComponent("canonical-restore-" + (try Fixture.id()))
        var paths = [
            "items", "authority", ".tractanda-store-identity.json", ".tractanda-replica-identity.json",
            "canonical-reader.json", ".authority-initial-capture.json", ".authority-initial-state.json",
            ".authority-initial-state-sealed.json", ".authority-initial-visibility",
            ".peer-configuration", ".peer-lifecycle-operations", ".peer-retirement-activations",
            ".peer-review-activations", ".tractanda-first-source.json",
            ".tractanda-first-source-complete.json",
        ]
        if payloads {
            paths += [
                "attachments/payloads", "attachments/.placements", "documents/content",
                "documents/.placements",
            ]
        }
        if credentials { paths += [".peer-credentials"] }
        var copied: UInt64 = 0
        let canonicalCap: UInt64 = 8 * 1024 * 1024
        func copy(_ from: URL, _ to: URL) throws {
            try AttachmentFixtureCapacity.requireFree(at: fixture.directory)
            let metadata = try FileMetadata.read(at: from)
            switch metadata.type {
            case .directory:
                try FileManager.default.createDirectory(
                    at: to, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                for child in try FileManager.default.contentsOfDirectory(
                    at: from, includingPropertiesForKeys: nil)
                {
                    try copy(child, to.appendingPathComponent(child.lastPathComponent))
                }
            case .regular:
                let name = from.lastPathComponent
                guard !name.contains(".sqlite"), !name.hasSuffix("-wal"), !name.hasSuffix("-shm"),
                    !name.hasSuffix("-journal"), metadata.size <= canonicalCap - min(copied, canonicalCap)
                else { throw TractandaError("fixture", "Unexpected derived file or canonical size excess") }
                let bytes = try Data(contentsOf: from)
                guard !bytes.starts(with: Data("SQLite format 3\0".utf8)) else {
                    throw TractandaError("fixture", "SQLite bytes cannot enter the canonical backup")
                }
                copied += metadata.size
                try FileManager.default.createDirectory(
                    at: to.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: from, to: to)
                XCTAssertEqual(try Data(contentsOf: to), bytes)
            default:
                throw TractandaError("fixture", "Canonical fixture contains an unsafe file type")
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: metadata.mode & 0o7777], ofItemAtPath: to.path)
            XCTAssertEqual(try FileMetadata.read(at: to).mode & 0o7777, metadata.mode & 0o7777)
            try fixture.capacity()
        }
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        for path in paths
        where FileManager.default.fileExists(atPath: source.appendingPathComponent(path).path) {
            try copy(source.appendingPathComponent(path), destination.appendingPathComponent(path))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("index").path))
        for name in [".tractanda-store-identity.json", ".tractanda-replica-identity.json"] {
            XCTAssertEqual(
                try Data(contentsOf: destination.appendingPathComponent(name)),
                try Data(contentsOf: source.appendingPathComponent(name)))
        }
        return destination
    }

    func testReviewedOriginalAndUnreviewedDescendantSurviveCanonicalOnlyRestore() throws {
        let reviewed = try AuthorityReviewStoreTests.ReviewedFixture(withDescendant: true)
        let f = reviewed.base
        let child = try XCTUnwrap(reviewed.descendant)
        let request = try reviewed.request(operation: "restore-review")
        let accepted = try f.receiver.resolveAuthorityReview(request).revision
        let replica = f.receiver.replicaID
        f.receiver = nil
        let root = try restore(f.receiverRoot, fixture: f)
        let store = try Fixture.open(root, f.receiverAccounts)
        XCTAssertEqual(store.replicaID, replica)
        XCTAssertEqual(try store.get(accepted.itemID), accepted)
        XCTAssertEqual(
            try store.get(reviewed.held.itemID, revisionID: reviewed.held.revisionID), reviewed.held)
        XCTAssertTrue(try store.historicalDispositions(for: [reviewed.held]).isEmpty)
        XCTAssertEqual(try store.historicalDispositions(for: [child]), [child.revisionID: .demoted])
        let replay = try store.resolveAuthorityReview(request)
        XCTAssertTrue(replay.wasReplayed)
        XCTAssertEqual(replay.revision, accepted)
        XCTAssertThrowsError(
            try store.withAccess(forUID: f.receiverAccounts.bob) { try store.get(accepted.itemID) })
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("index/items.sqlite").path))
        try f.capacity()
    }

    func testConcurrentAuthoredConflictSurvivesCanonicalOnlyRestore() throws {
        let f = try Fixture()
        try f.bootstrap()
        let left = try f.edit(subject: "source branch")
        let right = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                .init(
                    action: .revise, itemID: f.base.itemID,
                    expectedRevisionID: f.base.revisionID, changes: ["subject": .text("receiver branch")],
                    operationID: "restore-conflict")
            ).revision
        }
        _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: left.revisionID)))
        let before = try f.receiver.itemState(f.base.itemID)
        XCTAssertEqual(before.status, .conflicted)
        let replica = f.receiver.replicaID
        f.receiver = nil
        let root = try restore(f.receiverRoot, fixture: f)
        let store = try Fixture.open(root, f.receiverAccounts)
        XCTAssertEqual(store.replicaID, replica)
        let after = try store.itemState(f.base.itemID)
        XCTAssertEqual(after.status, .conflicted)
        XCTAssertEqual(after.frontier, before.frontier)
        XCTAssertEqual(after.conflictingFields, before.conflictingFields)
        XCTAssertEqual(try store.get(left.itemID, revisionID: left.revisionID), left)
        XCTAssertEqual(try store.get(right.itemID, revisionID: right.revisionID), right)
        XCTAssertThrowsError(try store.get(f.base.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "itemUnresolved")
        }
        try f.capacity()
    }

    func testDisposalFenceAndExactRemovalRetrySurviveCanonicalOnlyRestore() throws {
        let f = try Fixture()
        try f.bootstrap()
        let replica = try XCTUnwrap(f.receiver.replicaID)
        let operation = try Fixture.id()
        // Keep a distinct existing pairing for the same remote so the membership fence,
        // rather than a missing endpoint, must reject it after restore.
        let removed = try PeerPackage.Context(
            peerID: "restore-removal-target", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("restore-removal-target".utf8)),
            permittedOrigins: [f.origin])
        try f.receiver.configurePeerIntake(peers: [f.context, removed])
        try f.receiver.removePeerIntake(
            peerID: removed.peerID, retiredOriginIDs: [f.origin], operationID: operation)
        let binding = try PeerExchangeBinding(
            peerID: f.context.peerID, storeID: f.storeID,
            localReplicaID: replica, remoteReplicaID: f.origin, pairingID: Fixture.id(),
            localIsInitiator: false, configurationDigest: f.context.configurationDigest)
        f.receiver = nil
        let root = try restore(f.receiverRoot, fixture: f)
        let store = try Fixture.open(root, f.receiverAccounts)
        XCTAssertEqual(store.replicaID, replica)
        XCTAssertEqual(try store.get(f.base.itemID, revisionID: f.base.revisionID), f.base)
        try store.removePeerIntake(
            peerID: removed.peerID, retiredOriginIDs: [f.origin], operationID: operation)
        // Restore must not silently readmit a retired remote, even under its old trusted pairing.
        XCTAssertThrowsError(try store.withPeerExchange(binding: binding, progress: {}) { _, _ in true }) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerRetired")
        }
        try f.capacity()
    }

    func testSavedDocumentOriginalAndBoundCredentialSurviveWithoutDerivedCaches() throws {
        let f = try Fixture()
        try f.bootstrap()
        var store: ItemStore! = f.receiver
        try store.setAttachmentReserveForTesting(AttachmentFixtureCapacity.reserveBytes)
        let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let upload = try store.beginAttachment(
            .init(
                itemID: f.base.itemID,
                expectedRevisionID: f.base.revisionID, operationID: "restore-payload",
                filename: "fixture.png",
                mediaType: "image/png", byteCount: Int64(bytes.count),
                sha256: AuthorityRecordCodec.sha256(bytes)))
        _ = try store.appendAttachment(uploadID: XCTUnwrap(upload.uploadID), offset: 0, data: bytes)
        let attached = try store.finishAttachment(uploadID: XCTUnwrap(upload.uploadID)).revision
        guard
            case .prepared(let snapshot) = try store.prepareAttachmentDocument(
                itemID: attached.itemID,
                expectedRevisionID: attached.revisionID, attachmentID: upload.attachment.attachmentID,
                operationID: "restore-saved-page", identity: .init())
        else {
            return XCTFail("Expected fresh saved-page preparation")
        }
        let geometry = try DocumentPageGeometry(
            sourceWidth: 8, sourceHeight: 8, sourceUnit: "pixel",
            displayWidth: 8, displayHeight: 8, canvasWidth: 2048, canvasHeight: 2048,
            contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 2048)
        let page = try AttachmentDocumentPage(
            pageNumber: 1, geometry: geometry,
            rasterSHA256: String(repeating: "b", count: 64),
            parsed: DoclingDocTagsParser.parse(
                Data("<doctag><text>canonical saved page</text></doctag>".utf8)),
            generatedTokens: 4, stopReason: "stop")
        let saved = try store.finishAttachmentDocument(snapshot, pages: [page])
        let originalRead = try store.readAttachmentDocument(
            itemID: saved.itemID,
            attachmentID: upload.attachment.attachmentID, pageNumber: 1)
        let binding = try PeerExchangeBinding(
            peerID: f.context.peerID, storeID: f.storeID,
            localReplicaID: XCTUnwrap(store.replicaID), remoteReplicaID: f.origin, pairingID: Fixture.id(),
            localIsInitiator: false, configurationDigest: f.context.configurationDigest)
        let credential = try PeerCredential(binding: binding, secret: Array(repeating: 23, count: 32))
        try store.registerPeerCredential(
            credential, context: f.context,
            expectedContextToken: store.peerIntakeContextToken(), operationID: Fixture.id())
        let replica = store.replicaID
        f.receiver = nil
        store = nil
        // The source writer is closed before copying; no derivative state enters the restored root.
        let root = try restore(f.receiverRoot, fixture: f, payloads: true, credentials: true)
        var restored: ItemStore? = try Fixture.open(root, f.receiverAccounts)
        XCTAssertEqual(restored!.replicaID, replica)
        XCTAssertEqual(
            try restored!.attachmentContent(
                itemID: saved.itemID,
                attachmentID: upload.attachment.attachmentID, offset: 0, limit: 100
            ).data, bytes)
        XCTAssertEqual(
            try JSON.encode(
                restored!.readAttachmentDocument(
                    itemID: saved.itemID,
                    attachmentID: upload.attachment.attachmentID, pageNumber: 1)),
            try JSON.encode(originalRead))
        XCTAssertEqual(
            try restored!.loadPeerCredential(peerID: f.context.peerID).commitment, try credential.commitment)
        try restored!.loadPeerCredential(peerID: f.context.peerID).withTLSInput { _, secret in
            XCTAssertEqual(secret, Array(repeating: 23, count: 32))
        }
        restored = nil
        let key = try PeerCredentialStore.path(
            peerID: binding.peerID, configurationDigest: binding.configurationDigest
        )
        .reduce(root) { $0.appendingPathComponent($1) }
        try FileManager.default.removeItem(at: key)
        try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
        restored = try Fixture.open(root, f.receiverAccounts)
        XCTAssertThrowsError(try restored!.loadPeerCredential(peerID: f.context.peerID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidPeerCredential")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: key.path))
        XCTAssertEqual(try restored!.get(saved.itemID).revisionID, saved.revisionID)
        XCTAssertEqual(
            try restored!.attachmentContent(
                itemID: saved.itemID,
                attachmentID: upload.attachment.attachmentID, offset: 0, limit: 100
            ).data, bytes)
        try f.capacity()
    }
}
