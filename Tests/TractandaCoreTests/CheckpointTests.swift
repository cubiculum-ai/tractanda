import CSQLite
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class CheckpointTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-checkpoint-\(Identifier.make())")
    }

    private func assertRecoveryRequired(_ expression: () throws -> Any) {
        XCTAssertThrowsError(try expression()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "recoveryRequired")
        }
    }

    func testStartupMetricsCanReadHeadCountBeforeClosingTemporaryWALIndex() throws {
        let previous = getenv("TRACTANDA_STARTUP_METRICS").map { String(cString: $0) }
        _ = setenv("TRACTANDA_STARTUP_METRICS", "1", 1)
        defer {
            if let previous {
                _ = setenv("TRACTANDA_STARTUP_METRICS", previous, 1)
            } else {
                _ = unsetenv("TRACTANDA_STARTUP_METRICS")
            }
        }
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let item = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("metrics")],
                operationID: "startup-metrics-item")
        ).revision
        try store?.rebuildIndex()
        XCTAssertEqual(try store?.get(item.itemID), item)
        store = nil
        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "checkpoint")
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

    func testWALWriterKeepsOrdinaryCommitForReplayAndReopensHistoryAndReceipt() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let request = CommitRequest(
            classID: "Item", changes: ["body": .text("WAL replay")], operationID: "wal-replay")
        let committed = try XCTUnwrap(store).commit(request).revision
        let writer = try ItemIndex(
            path: root.appendingPathComponent("index/items.sqlite").path, create: false)
        XCTAssertEqual(try writer.synchronousModeForTesting(), 2)
        try writer.closeChecked()
        let database = root.appendingPathComponent("index/items.sqlite")
        let wal = URL(fileURLWithPath: database.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))
        let initialWALSize = try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(initialWALSize, 0)

        // Hold a read snapshot while releasing the writer. This preserves the committed,
        // nonempty WAL on disk until the simulated restart opens it.
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(connection, "SELECT count(*) FROM items", -1, &statement, nil), SQLITE_OK)
        let readStatement = try XCTUnwrap(statement)
        XCTAssertEqual(sqlite3_step(readStatement), SQLITE_ROW)
        sqlite3_finalize(readStatement)
        store = nil
        let retainedWALSize = try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(retainedWALSize, 0)

        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "checkpoint")
        XCTAssertEqual(try XCTUnwrap(store).get(committed.itemID), committed)
        XCTAssertEqual(
            try XCTUnwrap(store).history(committed.itemID).map(\.revisionID), [committed.revisionID])
        XCTAssertTrue(try XCTUnwrap(store).commit(request).wasReplayed)
        sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
        sqlite3_close_v2(connection)
        connection = nil
    }

    func testBusyIndexCloseAfterPublishedWriteCannotClearDirtyMarker() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        var held: OpaquePointer? = try store.holdIndexStatementForTesting()
        defer { if let held { sqlite3_finalize(held) } }
        store.beforeIndexUpdate = { throw TractandaError("injected", "index update stopped") }
        let result = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("durable file")],
                operationID: "busy-close-marker"))
        XCTAssertFalse(result.isIndexReady)
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        XCTAssertThrowsError(try store.get(result.revision.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "recoveryRequired")
        }
        sqlite3_finalize(held)
        held = nil
        store.beforeIndexUpdate = nil
        try store.rebuildIndex()
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
        XCTAssertEqual(try store.get(result.revision.itemID), result.revision)
    }

    func testExplicitRebuildPublishesCheckpointedWALDatabase() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let request = CommitRequest(
            classID: "Item", changes: ["subject": .text("before rebuild")], operationID: "rebuild-wal")
        let original = try XCTUnwrap(store).commit(request).revision
        try XCTUnwrap(store).rebuildIndex()
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
        XCTAssertEqual(try XCTUnwrap(store).get(original.itemID), original)
        store = nil
        let database = root.appendingPathComponent("index/items.sqlite")
        let wal = URL(fileURLWithPath: database.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int, 0)
        }
        store = try ItemStore(root: root)
        XCTAssertEqual(try XCTUnwrap(store).get(original.itemID), original)
        XCTAssertTrue(try XCTUnwrap(store).commit(request).wasReplayed)
    }

    func testCleanCheckpointLoadsOnlyCurrentHeadsAndNoCatalogueRows() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let initial = try XCTUnwrap(store).commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("v0")], operationID: "bounded-0")
        ).revision
        var current = initial
        for number in 1...12 {
            current = try XCTUnwrap(store).commit(
                CommitRequest(
                    action: .revise, itemID: initial.itemID, expectedRevisionID: current.revisionID,
                    changes: ["subject": .text("v\(number)")], operationID: "bounded-\(number)")
            ).revision
        }
        store = nil

        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "checkpoint")
        XCTAssertEqual(store?.checkpointHeadRowsLoadedForTesting, 0)
        XCTAssertEqual(store?.checkpointCatalogueRowsLoadedForTesting, 0)
        XCTAssertEqual(store?.checkpointCanonicalHeadReadsForTesting, 0)
        XCTAssertEqual(try XCTUnwrap(store).get(initial.itemID), current)
    }

    func testEmptyCleanCheckpointHasNoHeadOrCatalogueScan() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        store = nil

        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "checkpoint")
        XCTAssertEqual(store?.checkpointHeadRowsLoadedForTesting, 0)
        XCTAssertEqual(store?.checkpointCatalogueRowsLoadedForTesting, 0)
        XCTAssertEqual(store?.checkpointCanonicalHeadReadsForTesting, 0)
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

    func testFailedRebuildAfterRecoveryAndAfterIndexOpenStaysNotReady() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let item = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["body": .text("preserve")], operationID: "rebuild-failure")
        ).revision

        store.beforeCanonicalDurabilitySync = { throw TractandaError("injected", "before index creation") }
        XCTAssertThrowsError(try store.rebuildIndex())
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        assertRecoveryRequired { try store.get(item.itemID) }
        assertRecoveryRequired {
            _ = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "blocked-write"))
        }

        store.beforeCanonicalDurabilitySync = nil
        store.beforeCheckpointClear = { throw TractandaError("injected", "after index reopen") }
        XCTAssertThrowsError(try store.rebuildIndex())
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        assertRecoveryRequired { try store.get(item.itemID) }
        assertRecoveryRequired {
            _ = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "blocked-write-2"))
        }

        store.beforeCheckpointClear = nil
        try store.rebuildIndex()
        XCTAssertEqual(try store.get(item.itemID), item)
    }

    func testMidEnumerationFailureKeepsStagedCatalogueUnpublishedAndRetryable() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let first = try store.commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("one")], operationID: "enum-one")
        ).revision
        let second = try store.commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("two")], operationID: "enum-two")
        ).revision
        let rows = try store.exportCatalogueForVerification()
        let canonicalBefore = try rows.map { row in
            (row.path, try Data(contentsOf: root.appendingPathComponent(row.path)))
        }
        store.afterRecoveryRecordForTesting = { url in
            throw TractandaError("injected", "enumeration fault at \(url.lastPathComponent)")
        }

        XCTAssertThrowsError(try store.rebuildIndex()) { error in
            XCTAssertTrue(String(describing: error).contains("enumeration fault at"))
        }
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        XCTAssertFalse(store.isCanonicalTrusted)
        assertRecoveryRequired { try store.get(first.itemID) }
        assertRecoveryRequired {
            _ = try store.commit(
                CommitRequest(classID: "Item", changes: [:], operationID: "blocked-enumeration-write"))
        }
        for (path, bytes) in canonicalBefore {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        }

        store.afterRecoveryRecordForTesting = nil
        try store.rebuildIndex()
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
        XCTAssertEqual(try store.get(first.itemID), first)
        XCTAssertEqual(try store.get(second.itemID), second)
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

    func testMissingRequiredHeadSchemaForcesCanonicalRecovery() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let item = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("recover head")], operationID: "head-schema")
        ).revision
        store = nil
        let database = root.appendingPathComponent("index/items.sqlite")
        let index = try ItemIndex(path: database.path, create: false)
        try index.execute("DROP TABLE items")
        index.close()

        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "fullRecovery")
        XCTAssertEqual(try XCTUnwrap(store).get(item.itemID), item)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
    }

    func testReadyStoreQuarantinesAfterPersistentIndexReadFailure() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let item = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("index fault")], operationID: "ready-index")
        ).revision
        let database = root.appendingPathComponent("index/items.sqlite")
        let damaged = try ItemIndex(path: database.path, create: false)
        try damaged.execute("DROP TABLE revision_catalog")

        XCTAssertThrowsError(try store.get(item.itemID))
        XCTAssertFalse(store.isCanonicalTrusted)
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        assertRecoveryRequired { try store.get(item.itemID) }
        assertRecoveryRequired {
            _ = try store.commit(
                CommitRequest(classID: "Item", changes: [:], operationID: "blocked-after-index-fault"))
        }
        XCTAssertNotNil(store.canonicalVerificationStatus["state"])
        damaged.close()
    }

    func testMarkerFailureGatesProcessWithoutUnlinkingLiveIndex() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let item = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("marker fault")], operationID: "marker-fault")
        ).revision
        let database = root.appendingPathComponent("index/items.sqlite")
        let damaged = try ItemIndex(path: database.path, create: false)
        try damaged.execute(
            "UPDATE revision_catalog SET digest='bad' WHERE revision=?", [item.revisionID])
        store?.beforeIndexQuarantineMarkerForTesting = {
            throw TractandaError("injected", "marker fault")
        }

        XCTAssertThrowsError(try XCTUnwrap(store).get(item.itemID))
        XCTAssertFalse(try XCTUnwrap(store).isCanonicalTrusted)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        XCTAssertEqual(
            store?.canonicalVerificationStatus["state"] as? String, "fatalRecoverySignalFailure")
        XCTAssertNotNil(store?.canonicalVerificationStatus["markerError"])
        XCTAssertEqual(store?.canonicalVerificationStatus["restartMayReuseCheckpoint"] as? Bool, true)
        assertRecoveryRequired { try XCTUnwrap(store).get(item.itemID) }
        assertRecoveryRequired {
            _ = try XCTUnwrap(store).commit(
                CommitRequest(classID: "Item", changes: [:], operationID: "blocked-marker-fault"))
        }

        damaged.close()
        store = nil
        store = try ItemStore(root: root)
        XCTAssertEqual(
            store?.startupRecovery["mode"], "checkpoint",
            "Without a durable marker, the next process may trust the old checkpoint.")
        XCTAssertThrowsError(try XCTUnwrap(store).get(item.itemID))
        XCTAssertFalse(try XCTUnwrap(store).isCanonicalTrusted)
        try store?.rebuildIndex()
        XCTAssertEqual(try XCTUnwrap(store).get(item.itemID), item)
    }

    func testReadyStoreQuarantinesAfterCurrentHeadDigestMismatch() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let item = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("head fault")], operationID: "ready-head")
        ).revision
        let row = try XCTUnwrap(
            store.exportCatalogueForVerification().first { $0.revisionID == item.revisionID })
        let url = root.appendingPathComponent(row.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var bytes = try Data(contentsOf: url)
        bytes.append(0x20)
        try bytes.write(to: url)

        XCTAssertThrowsError(try store.get(item.itemID))
        XCTAssertFalse(store.isCanonicalTrusted)
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        assertRecoveryRequired { try store.get(item.itemID) }
        assertRecoveryRequired {
            _ = try store.commit(
                CommitRequest(classID: "Item", changes: [:], operationID: "blocked-after-head-fault"))
        }
        XCTAssertNotNil(store.canonicalVerificationStatus["state"])
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

    func testV4CatalogueWithoutACLRowsForcesFullRecovery() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let item = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("ACL schema probe")],
                operationID: "missing-acl-index"))
        store = nil

        let database = root.appendingPathComponent("index/items.sqlite")
        let index = try ItemIndex(path: database.path, create: false)
        try index.execute(
            "UPDATE checkpoint_meta SET value='tractanda-sqlite-catalogue-v4' WHERE key='engine'")
        try index.execute("DROP TABLE acl_named")
        try index.execute("DROP TABLE acl_core")
        index.close()

        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "fullRecovery")
        XCTAssertEqual(store?.startupRecovery["reason"], "checkpointInvalidOrIncompatible")
        XCTAssertEqual(try XCTUnwrap(store).get(item.revision.itemID), item.revision)
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
        let configured = try XCTUnwrap(store).configureAccess(configuration, operationID: "checkpoint-config")
        store = nil
        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "checkpoint")
        XCTAssertEqual(store?.checkpointHeadRowsLoadedForTesting, 0)
        XCTAssertEqual(store?.checkpointCanonicalHeadReadsForTesting, 1)
        XCTAssertTrue(try XCTUnwrap(store).isMultiUser)
        XCTAssertTrue(try XCTUnwrap(store).commit(configurationRequest).wasReplayed)
        XCTAssertEqual(try XCTUnwrap(store).candidates().count, 1)
    }

    func testCorruptAccessConfigurationHeadBlocksCleanCheckpointStartup() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let configuration = ItemValue.object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([]), "userAliases": .object([:]),
        ])
        let configured = try XCTUnwrap(store).configureAccess(
            configuration, operationID: "checkpoint-corrupt-config")
        store = nil
        let file = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root.appendingPathComponent("items"), includingPropertiesForKeys: nil)?.allObjects
                .compactMap { $0 as? URL }.first {
                    $0.lastPathComponent == configured.revision.revisionID + ".tractanda"
                })
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("corrupt configuration".utf8).write(to: file)

        XCTAssertThrowsError(try ItemStore(root: root))
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
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
