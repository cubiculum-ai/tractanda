import XCTest

@testable import TractandaCore

final class CheckpointTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-checkpoint-\(Identifier.make())")
    }

    func testCleanCheckpointRestoresHistoryAndCreateRetryReceipt() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let request = CommitRequest(
            classID: "Item", changes: ["body": .text("checkpoint body")],
            operationID: "checkpoint-create-révision-🧪")
        let original = try XCTUnwrap(store).commit(request).revision
        let reviseRequest = CommitRequest(
            action: .revise, itemID: original.itemID, expectedRevisionID: original.revisionID,
            changes: ["subject": .text("edited")], operationID: "checkpoint-revise")
        let edited = try XCTUnwrap(store).commit(reviseRequest).revision
        store = nil

        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "checkpoint")
        XCTAssertEqual(try XCTUnwrap(store).get(original.itemID), edited)
        XCTAssertEqual(
            try XCTUnwrap(store).history(original.itemID).map(\.revisionID),
            [edited.revisionID, original.revisionID])
        XCTAssertTrue(try XCTUnwrap(store).commit(request).wasReplayed)
        XCTAssertTrue(try XCTUnwrap(store).commit(reviseRequest).wasReplayed)
    }

    func testIndexFailureLeavesDirtyMarkerAndStartupRecoversCanonicalDelete() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let item = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("to delete")], operationID: "checkpoint-item")
        ).revision
        let deleteRequest = CommitRequest(
            action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
            changes: ["isDeleted": .boolean(true)], operationID: "checkpoint-delete")
        _ = try XCTUnwrap(store).commit(deleteRequest)
        store?.beforeIndexUpdate = { throw TractandaError("injected", "index transaction fault") }
        let retry = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("survives")], operationID: "checkpoint-fault"))
        XCTAssertFalse(retry.isIndexReady)
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        store = nil

        store = try ItemStore(root: root)
        XCTAssertTrue(try XCTUnwrap(store).get(item.itemID).isDeleted)
        XCTAssertTrue(try XCTUnwrap(store).commit(deleteRequest).wasReplayed)
        XCTAssertEqual(try XCTUnwrap(store).candidates().count, 1)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
    }

    func testCleanStartDefersHistoricalFileInspectionUntilRead() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let initial = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("initial")],
                operationID: "historical-initial")
        ).revision
        let latest = try XCTUnwrap(store).commit(
            CommitRequest(
                action: .revise, itemID: initial.itemID, expectedRevisionID: initial.revisionID,
                changes: ["subject": .text("latest")], operationID: "historical-latest")
        ).revision
        let row = try XCTUnwrap(
            XCTUnwrap(store).exportCatalogueForVerification().first {
                $0.revisionID == initial.revisionID
            })
        XCTAssertTrue(row.path.hasPrefix("items/"))
        XCTAssertFalse(row.path.hasPrefix("/"))
        XCTAssertFalse(row.path.split(separator: "/").contains(".."))
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
        store = nil
        let historicalURL = root.appendingPathComponent(row.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historicalURL.path)

        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "checkpoint")
        XCTAssertEqual(try XCTUnwrap(store).get(initial.itemID), latest)
        XCTAssertThrowsError(try XCTUnwrap(store).history(initial.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "recoveryError")
        }
    }

    func testUncertainPublicationKeepsMarkerUntilFullRecovery() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        store?.publishResultOverrideForTesting = 1
        let committed = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("uncertain")], operationID: "uncertain-publish"))
        XCTAssertTrue(committed.warnings.contains { $0.contains("durability") })
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        store = nil

        store = try ItemStore(root: root)
        XCTAssertEqual(try XCTUnwrap(store).get(committed.revision.itemID), committed.revision)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
    }

    func testMissingOrCorruptCatalogueFallsBackToFullRecovery() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let item = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("recover me")], operationID: "catalogue-item")
        ).revision
        store = nil
        let database = root.appendingPathComponent("index/items.sqlite")
        try FileManager.default.removeItem(at: database)

        store = try ItemStore(root: root)
        XCTAssertEqual(try XCTUnwrap(store).get(item.itemID), item)
        XCTAssertEqual(try XCTUnwrap(store).candidates(text: "recover me").map(\.itemID), [item.itemID])
        store = nil
        try Data("not sqlite".utf8).write(to: database)
        store = try ItemStore(root: root)
        XCTAssertEqual(try XCTUnwrap(store).get(item.itemID), item)
    }

    func testCatalogueFromAnotherStoreIsRebuiltAgainstCanonicalIdentity() throws {
        let firstRoot = root()
        let secondRoot = root()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        var first: ItemStore? = try ItemStore(root: firstRoot)
        _ = try XCTUnwrap(first).commit(
            CommitRequest(
                classID: "Item", changes: [:], operationID: "first-store"))
        var second: ItemStore? = try ItemStore(root: secondRoot)
        let expected = try XCTUnwrap(second).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("second store")], operationID: "second-store")
        ).revision
        first = nil
        second = nil
        let firstDatabase = firstRoot.appendingPathComponent("index/items.sqlite")
        let secondDatabase = secondRoot.appendingPathComponent("index/items.sqlite")
        try FileManager.default.removeItem(at: secondDatabase)
        try FileManager.default.copyItem(at: firstDatabase, to: secondDatabase)

        second = try ItemStore(root: secondRoot)
        XCTAssertEqual(try XCTUnwrap(second).get(expected.itemID), expected)
        XCTAssertEqual(try XCTUnwrap(second).candidates().map(\.itemID), [expected.itemID])
    }

    func testV3CatalogueWithMissingCreatedColumnForcesFullRecovery() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let item = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("schema probe")],
                operationID: "missing-created-column")
        ).revision
        store = nil

        let database = root.appendingPathComponent("index/items.sqlite")
        let index = try ItemIndex(path: database.path, create: false)
        try index.execute("ALTER TABLE items RENAME TO items_with_created")
        try index.execute(
            "CREATE TABLE items (id TEXT PRIMARY KEY, revision TEXT NOT NULL, class TEXT NOT NULL, "
                + "deleted INTEGER NOT NULL, modified REAL NOT NULL, fields TEXT NOT NULL)")
        try index.execute(
            "INSERT INTO items (id,revision,class,deleted,modified,fields) "
                + "SELECT id,revision,class,deleted,modified,fields FROM items_with_created")
        try index.execute("DROP TABLE items_with_created")
        index.close()

        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "fullRecovery")
        XCTAssertEqual(store?.startupRecovery["reason"], "checkpointInvalidOrIncompatible")
        XCTAssertEqual(try XCTUnwrap(store).get(item.itemID), item)
        XCTAssertEqual(try XCTUnwrap(store).candidates().map(\.itemID), [item.itemID])
    }

    func testExplicitRebuildStillScansCanonicalFiles() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let item = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("canonical")], operationID: "explicit-scan")
        ).revision
        let file = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root.appendingPathComponent("items"), includingPropertiesForKeys: nil)?.allObjects
                .compactMap { $0 as? URL }.first { $0.lastPathComponent == item.revisionID + ".tractanda" })
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try store.rebuildIndex())
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
    }

    func testConfigurationCommitKeepsCheckpointValid() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let configuration = ItemValue.object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([]), "userAliases": .object([:]),
        ])
        let configurationRequest = CommitRequest(
            classID: AccessConfiguration.classID,
            changes: ["accessConfiguration": configuration, "subject": .text("Store access configuration")],
            operationID: "checkpoint-config")
        _ = try XCTUnwrap(store).configureAccess(configuration, operationID: "checkpoint-config")
        store = nil
        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "checkpoint")
        XCTAssertTrue(try XCTUnwrap(store).isMultiUser)
        XCTAssertTrue(try XCTUnwrap(store).commit(configurationRequest).wasReplayed)
        XCTAssertEqual(try XCTUnwrap(store).candidates().count, 1)
    }

    func testMarkerClearFailureLeavesStartupRecoverySignal() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        store?.beforeCheckpointClear = { throw TractandaError("injected", "clear boundary") }
        let committed = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("clear boundary")], operationID: "clear-boundary")
        )
        XCTAssertTrue(committed.warnings.contains { $0.contains("marker remains") })
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        store = nil
        store = try ItemStore(root: root)
        XCTAssertEqual(try XCTUnwrap(store).get(committed.revision.itemID), committed.revision)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
    }

    func testFailedCanonicalDurabilitySyncRetainsDirtyMarker() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let item = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("durable")],
                operationID: "durability-boundary")
        ).revision
        store?.beforeCanonicalDurabilitySync = {
            throw TractandaError("injected", "canonical sync failed")
        }
        XCTAssertThrowsError(try store?.rebuildIndex())
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        store = nil

        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["reason"], "dirtyMarker")
        XCTAssertEqual(try XCTUnwrap(store).get(item.itemID), item)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
    }
}
