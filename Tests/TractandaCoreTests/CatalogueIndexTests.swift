import CSQLite
import XCTest

@testable import TractandaCore

final class CatalogueIndexTests: XCTestCase {
    func testSQLiteFailureQuarantineClassificationKeepsTransientAndCapacityFailuresLive() {
        for code in [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT, SQLITE_NOMEM, SQLITE_TOOBIG, SQLITE_FULL] {
            XCTAssertFalse(ItemIndex.shouldQuarantineSQLiteFailure(code))
        }
        XCTAssertTrue(ItemIndex.shouldQuarantineSQLiteFailure(SQLITE_CORRUPT))
        XCTAssertTrue(ItemIndex.shouldQuarantineSQLiteFailure(SQLITE_SCHEMA))
        XCTAssertTrue(ItemIndex.shouldQuarantineSQLiteFailure(SQLITE_IOERR))
    }

    private func row(
        _ id: String, parent: String? = nil, operation: String? = nil,
        actor: String = "user:test", itemID: String = "item", createdAt: String = "created",
        feedbackRevisionIDs: [String] = []
    ) -> ItemIndex.CatalogueRow {
        ItemIndex.CatalogueRow(
            revisionID: id, itemID: itemID, path: "items/2026/09/27/12/00/\(itemID)/\(id).tractanda",
            parentID: parent, actor: actor, operationID: operation ?? id,
            size: 12, inode: 5, uid: 1, mode: 0o600, modificationSeconds: 1,
            modificationNanoseconds: 0, digest: Data(repeating: 7, count: 32),
            createdAt: createdAt, feedbackRevisionIDs: feedbackRevisionIDs)
    }

    func testValidatedPagesAndIndexedPointLookups() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tractanda-catalogue-\(Identifier.make()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let index = try ItemIndex(path: path.path, create: true)
        defer { index.close() }
        try index.execute("BEGIN IMMEDIATE")
        try index.replaceCatalogue(
            identity: "store",
            rows: [
                row("rev-a"), row("rev-b", parent: "rev-a", operation: "shared", actor: "user:other"),
            ])
        try index.execute("COMMIT")

        let catalogue = try XCTUnwrap(index.validatedCatalogue(identity: "store"))
        XCTAssertNil(try index.validatedCatalogue(identity: "foreign"))
        let first = try index.cataloguePage(catalogue, limit: 1)
        XCTAssertEqual(first.count, 1)
        let second = try index.cataloguePage(catalogue, after: first[0].revisionID, limit: 1)
        XCTAssertEqual(second.map(\.revisionID), ["rev-b"])
        XCTAssertTrue(
            try index.cataloguePageQueryPlanForTesting(after: first[0].revisionID)
                .contains { $0.localizedCaseInsensitiveContains("search") })
        XCTAssertTrue(try index.cataloguePage(catalogue, after: "rev-b", limit: 1).isEmpty)
        XCTAssertEqual(try index.revision("rev-a"), row("rev-a"))
        XCTAssertEqual(
            try index.revision(itemID: "item", revisionID: "rev-b"),
            row("rev-b", parent: "rev-a", operation: "shared", actor: "user:other"))
        XCTAssertNil(try index.revision(itemID: "other", revisionID: "rev-b"))
        XCTAssertEqual(try index.successor(itemID: "item", parentID: "rev-a")?.revisionID, "rev-b")
        XCTAssertEqual(try index.receipt(actor: "user:test", operationID: "rev-a")?.revisionID, "rev-a")
        XCTAssertEqual(try index.receipts(named: "shared")?.map(\.revisionID), ["rev-b"])
    }

    func testRecoveryGraphWalkAcceptsShuffledChainAndEarlierFeedback() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tractanda-recovery-graph-\(Identifier.make()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let index = try ItemIndex(path: path.path, create: true)
        defer { index.close() }
        try index.execute("BEGIN IMMEDIATE")
        try index.insertRecoveryRow(row("child", parent: "root", operation: "child", createdAt: "created"))
        try index.insertRecoveryRow(
            row(
                "root", operation: "root", createdAt: "created", feedbackRevisionIDs: []))
        try index.insertRecoveryRow(
            row(
                "grandchild", parent: "child", operation: "grandchild", createdAt: "created",
                feedbackRevisionIDs: ["root"]))
        try index.validateRecoveryGraph()
        XCTAssertEqual(try index.recoveryHead()?.revisionID, "grandchild")
        XCTAssertNil(try index.recoveryHead(after: "item"))
        try index.execute("ROLLBACK")
    }

    func testRecoveryGraphRejectsMissingCrossItemAndDisconnectedCycle() throws {
        func invalid(_ rows: [ItemIndex.CatalogueRow]) throws {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("tractanda-invalid-graph-\(Identifier.make()).sqlite")
            defer { try? FileManager.default.removeItem(at: path) }
            let index = try ItemIndex(path: path.path, create: true)
            defer { index.close() }
            try index.execute("BEGIN IMMEDIATE")
            for row in rows { try index.insertRecoveryRow(row) }
            XCTAssertThrowsError(try index.validateRecoveryGraph()) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "recoveryError")
            }
            try index.execute("ROLLBACK")
        }

        try invalid([
            row("root", createdAt: "created"), row("missing", parent: "absent", createdAt: "created"),
        ])
        let rootA = row("root-a", createdAt: "created")
        try invalid([
            rootA, row("root-b", itemID: "other", createdAt: "created"),
            row("cross", parent: "root-a", itemID: "other", createdAt: "created"),
        ])
        try invalid([
            row("root", createdAt: "created"),
            row("cycle-a", parent: "cycle-b", createdAt: "created"),
            row("cycle-b", parent: "cycle-a", createdAt: "created"),
        ])
    }

    func testRecoveryGraphRejectsCreatedAtDriftAndFeedbackOutsideEarlierAncestor() throws {
        func invalid(_ child: ItemIndex.CatalogueRow, additional: [ItemIndex.CatalogueRow] = []) throws {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("tractanda-invalid-feedback-\(Identifier.make()).sqlite")
            defer { try? FileManager.default.removeItem(at: path) }
            let index = try ItemIndex(path: path.path, create: true)
            defer { index.close() }
            try index.execute("BEGIN IMMEDIATE")
            try index.insertRecoveryRow(row("root", createdAt: "created"))
            for row in additional { try index.insertRecoveryRow(row) }
            try index.insertRecoveryRow(child)
            XCTAssertThrowsError(try index.validateRecoveryGraph()) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "recoveryError")
            }
            try index.execute("ROLLBACK")
        }

        try invalid(row("child", parent: "root", createdAt: "drift"))
        try invalid(row("child", parent: "root", createdAt: "created", feedbackRevisionIDs: ["child"]))
        try invalid(row("child", parent: "root", createdAt: "created", feedbackRevisionIDs: ["future"]))
        try invalid(
            row("child", parent: "root", createdAt: "created", feedbackRevisionIDs: ["other-root"]),
            additional: [row("other-root", itemID: "other", createdAt: "created")])
    }

    func testEmptyValidatedCatalogueAndReceiptIntegrityFailure() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tractanda-catalogue-\(Identifier.make()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let index = try ItemIndex(path: path.path, create: true)
        defer { index.close() }
        try index.replaceCatalogue(identity: "empty", rows: EmptyCollection<ItemIndex.CatalogueRow>())
        let empty = try XCTUnwrap(index.validatedCatalogue(identity: "empty"))
        XCTAssertTrue(try index.cataloguePage(empty).isEmpty)
        try index.execute("INSERT INTO operation_receipts VALUES ('user:x','orphan','missing','item')")
        XCTAssertNotNil(try index.validatedCatalogue(identity: "empty"))
        XCTAssertNil(try index.catalogue(identity: "empty"))
    }

    func testACLPrincipalCatalogueUsesDistinctRefcountsAndBoundedDiscovery() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tractanda-catalogue-\(Identifier.make()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let index = try ItemIndex(path: path.path, create: true)
        defer { index.close() }
        try index.execute("INSERT INTO acl_core VALUES ('one','alice','staff',448,7,7,0,0)")
        try index.execute("INSERT INTO acl_core VALUES ('two','alice','staff',448,7,7,0,0)")
        try index.execute("INSERT INTO acl_named VALUES ('one','user','bob',4)")
        XCTAssertNil(try index.aclPrincipalNames(maximum: 1))
        index.resetPrincipalLookupVMInstructionsForTesting()
        try index.execute("DELETE FROM acl_named WHERE item_id='one'")
        try index.execute("DELETE FROM acl_core WHERE item_id='two'")
        let names = try XCTUnwrap(index.aclPrincipalNames(maximum: 1))
        XCTAssertEqual(names.users, ["alice"])
        XCTAssertEqual(names.groups, ["staff"])
        XCTAssertLessThan(index.principalLookupVMInstructionsForTesting, 100)
    }

    func testMissingPrincipalMaintenanceTriggerInvalidatesCatalogue() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tractanda-catalogue-\(Identifier.make()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let index = try ItemIndex(path: path.path, create: true)
        defer { index.close() }
        let noRows: [ItemIndex.CatalogueRow] = []
        try index.replaceCatalogue(identity: "store", rows: noRows)
        XCTAssertNotNil(try index.validatedCatalogue(identity: "store"))
        try index.execute("DROP TRIGGER acl_core_principal_insert")
        XCTAssertNil(try index.validatedCatalogue(identity: "store"))
    }
}
