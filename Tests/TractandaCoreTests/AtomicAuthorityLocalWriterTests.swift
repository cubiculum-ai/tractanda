import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class AtomicAuthorityLocalWriterTests: XCTestCase {
    private typealias Fixture = AtomicAuthorityStoreFixture
    func testActualStoreAtomicCreateReviseAndExactOperationRetry() throws {
        print("ATOMIC_WRITER_PHASE initialized-factory")
        let f = try Fixture()
        let existing = try f.source.exportCatalogueForVerification().map(\.revisionID)
        let coordinatorBefore = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        XCTAssertNotNil(try coordinatorBefore.configuration()?.bootstrap)
        f.source = nil
        // The entire one-node private cluster is quiescent for the explicit transition.
        print("ATOMIC_WRITER_PHASE explicit-quiescent-transition")
        try Fixture.transition(f.sourceRoot)
        print("ATOMIC_WRITER_PHASE named-support-open")
        f.source = try Fixture.open(f.sourceRoot, accounts: f.sourceAccounts)
        XCTAssertEqual(try f.source.exportCatalogueForVerification().map(\.revisionID), existing)
        let create = CommitRequest(
            classID: "Item", changes: ["subject": .text("atomic local writer")],
            operationID: "atomic-local-create")
        print("ATOMIC_WRITER_PHASE ordinary-create")
        let first = try f.source.commit(create)
        XCTAssertTrue(first.isIndexReady, first.warnings.joined(separator: "\n"))
        XCTAssertFalse(first.wasReplayed)
        XCTAssertEqual(try f.source.get(first.revision.itemID).revisionID, first.revision.revisionID)
        let retry = try f.source.commit(create)
        XCTAssertTrue(retry.wasReplayed)
        XCTAssertEqual(retry.revision.revisionID, first.revision.revisionID)
        let revise = CommitRequest(
            action: .revise, itemID: first.revision.itemID,
            expectedRevisionID: first.revision.revisionID,
            changes: ["subject": .text("atomic revised")], operationID: "atomic-local-revise")
        print("ATOMIC_WRITER_PHASE ordinary-revise")
        let second = try f.source.commit(revise)
        XCTAssertTrue(second.isIndexReady, second.warnings.joined(separator: "\n"))
        XCTAssertEqual(try f.source.get(first.revision.itemID).revisionID, second.revision.revisionID)
        let repeated = try f.source.commit(revise)
        XCTAssertTrue(repeated.wasReplayed)
        XCTAssertEqual(repeated.revision.revisionID, second.revision.revisionID)
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let origin = try XCTUnwrap(f.source.replicaID)
        let head = try XCTUnwrap(index.authorityControlHead(originID: origin))
        XCTAssertTrue(try index.isAcceptedAtomicControl(head))
        let coordinator = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let raw = try XCTUnwrap(index.retainedAuthorityObject(id: head.recordID))
        XCTAssertNotNil(try coordinator.journal.atomicAcceptance(packageID: raw.packageID, root: head))
        XCTAssertEqual(
            try index.eligibilityAtCut(revisionID: second.revision.revisionID, cut: head), .eligible)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.sourceRoot))
        try f.capacity()
    }
    func testLateDerivedActivationFailureRollsBackBeforeResidentVisibilityAndRecoversExactReceipt() throws {
        let f = try Fixture()
        try f.activateAndOpen()
        let first = try f.source.commit(
            .init(
                classID: "Item", changes: ["subject": .text("before late failure")],
                operationID: "atomic-late-base"))
        XCTAssertTrue(first.isIndexReady, first.warnings.joined(separator: "\n"))
        _ = try f.source.get(first.revision.itemID)
        let before = f.source.atomicResidentIdentityForTesting
        let origin = try XCTUnwrap(f.source.replicaID)
        var failedRoot: AuthorityBinding?
        f.source.beforeAtomicDerivedCommitForTesting = { stage in
            guard stage.effects.entryCount > 0 else { return }
            failedRoot = stage.header.binding
            XCTAssertEqual(f.source.atomicResidentIdentityForTesting, before)
            throw TractandaError("injectedAtomicCommitFailure", "Private failure after SQL activation")
        }
        let request = CommitRequest(
            action: .revise, itemID: first.revision.itemID,
            expectedRevisionID: first.revision.revisionID,
            changes: ["subject": .text("after exact recovery")], operationID: "atomic-late-revise")
        let failed = try f.source.commit(request)
        XCTAssertFalse(failed.isIndexReady)
        XCTAssertEqual(f.source.atomicResidentIdentityForTesting, before)
        XCTAssertTrue(StoreCheckpoint.isDirty(root: f.sourceRoot))
        let root = try XCTUnwrap(failedRoot)
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        XCTAssertFalse(try index.hasValidatedAuthorityControl(root))
        XCTAssertEqual(try index.revision(first.revision.revisionID)?.revisionID, first.revision.revisionID)
        XCTAssertNil(try index.revision(failed.revision.revisionID))
        XCTAssertNotEqual(try index.authorityControlHead(originID: origin), root)
        let raw = try XCTUnwrap(index.retainedAuthorityObject(id: root.recordID))
        let coordinator = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let sealed = try XCTUnwrap(coordinator.journal.atomicAcceptance(packageID: raw.packageID, root: root))
        index.close()
        f.source.beforeAtomicDerivedCommitForTesting = nil
        f.source = nil
        f.source = try Fixture.open(f.sourceRoot, accounts: f.sourceAccounts)
        XCTAssertEqual(try f.source.get(first.revision.itemID).revisionID, failed.revision.revisionID)
        let retry = try f.source.commit(request)
        XCTAssertTrue(retry.wasReplayed)
        XCTAssertTrue(retry.isIndexReady)
        XCTAssertEqual(retry.revision.revisionID, failed.revision.revisionID)
        XCTAssertEqual(
            try coordinator.journal.atomicAcceptance(packageID: raw.packageID, root: root)?.bytesSHA256,
            sealed.bytesSHA256)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.sourceRoot))
        try f.capacity()
    }

}
