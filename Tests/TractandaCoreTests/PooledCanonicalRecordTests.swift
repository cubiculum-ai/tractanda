import XCTest

@testable import TractandaCore

final class PooledCanonicalRecordTests: XCTestCase {
    private func fixture() throws -> (URL, ItemStore, Revision, ItemIndex.CatalogueRow) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        let store = try ItemStore(root: root)
        let revision = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("pooled record")],
                operationID: Identifier.make())
        )
        .revision
        let row = try XCTUnwrap(
            store.exportCatalogueForVerification().first { $0.revisionID == revision.revisionID })
        return (store.root, store, revision, row)
    }

    private func replacing(
        _ row: ItemIndex.CatalogueRow, path: String? = nil, digest: Data? = nil,
        size: UInt64? = nil, inode: UInt64? = nil, uid: UInt32? = nil, mode: UInt32? = nil,
        modificationSeconds: Int64? = nil, modificationNanoseconds: Int32? = nil,
        actor: String? = nil, operationID: String? = nil
    ) -> ItemIndex.CatalogueRow {
        ItemIndex.CatalogueRow(
            revisionID: row.revisionID, itemID: row.itemID, path: path ?? row.path,
            parentID: row.parentID, actor: actor ?? row.actor, operationID: operationID ?? row.operationID,
            size: size ?? row.size, inode: inode ?? row.inode, uid: uid ?? row.uid,
            mode: mode ?? row.mode, modificationSeconds: modificationSeconds ?? row.modificationSeconds,
            modificationNanoseconds: modificationNanoseconds ?? row.modificationNanoseconds,
            digest: digest ?? row.digest, createdAt: row.createdAt,
            feedbackRevisionIDs: row.feedbackRevisionIDs)
    }

    func testReadsAndVerifiesCanonicalRevision() throws {
        let (root, store, expected, row) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: store.ownerUID)
        XCTAssertEqual(record.revision, expected)
        XCTAssertEqual(record.metadata.size, row.size)
        XCTAssertFalse(record.archived)
    }

    func testReadsHistoricalRevisionByItsCatalogueRow() throws {
        let (root, store, original, row) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: original.itemID, expectedRevisionID: original.revisionID,
                changes: ["subject": .text("new head")], operationID: Identifier.make()))

        let historical = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: store.ownerUID)
        XCTAssertEqual(historical.revision, original)
    }

    func testRejectsWrongDigestAndReconcilesIndexedMetadataDrift() throws {
        let (root, store, _, row) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let wrongDigest = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(
            try PooledCanonicalRecord.read(
                row: replacing(row, digest: wrongDigest), root: root, ownerUID: store.ownerUID)
        ) {
            XCTAssertEqual($0 as? PooledCanonicalRecordError, .digestMismatch)
        }
        let drifted = try PooledCanonicalRecord.read(
            row: replacing(row, modificationSeconds: row.modificationSeconds + 1),
            root: root, ownerUID: store.ownerUID)
        XCTAssertTrue(drifted.metadataDrifted)
        XCTAssertThrowsError(
            try PooledCanonicalRecord.read(
                row: replacing(row, actor: "uid:999"), root: root, ownerUID: store.ownerUID)
        ) {
            XCTAssertEqual($0 as? PooledCanonicalRecordError, .identityMismatch)
        }
    }

    func testRejectsWrongOrTraversingCataloguePathAndSmallReadCap() throws {
        let (root, store, _, row) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        for path in ["elsewhere/\(row.path)", "../\(row.path)", row.path + "/../record"] {
            XCTAssertThrowsError(
                try PooledCanonicalRecord.read(
                    row: replacing(row, path: path), root: root, ownerUID: store.ownerUID)
            ) {
                XCTAssertEqual($0 as? PooledCanonicalRecordError, .invalidPath)
            }
        }
        XCTAssertThrowsError(
            try PooledCanonicalRecord.read(
                row: row, root: root, ownerUID: store.ownerUID, maximumBytes: 1)
        ) {
            XCTAssertEqual($0 as? PooledCanonicalRecordError, .sizeLimit)
        }
    }

    func testDoesNotFollowSymlinkInCanonicalDescriptorChain() throws {
        let (root, store, _, row) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let linkRoot = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: linkRoot) }
        let components = row.path.split(separator: "/").map(String.init)
        let itemDirectory = linkRoot.appendingPathComponent(components.dropLast().joined(separator: "/"))
        try FileManager.default.createDirectory(
            at: itemDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let actualItemDirectory = root.appendingPathComponent(components.dropLast().joined(separator: "/"))
        try FileManager.default.createSymbolicLink(
            at: itemDirectory, withDestinationURL: actualItemDirectory)

        XCTAssertThrowsError(
            try PooledCanonicalRecord.read(row: row, root: linkRoot, ownerUID: store.ownerUID))
    }
}
