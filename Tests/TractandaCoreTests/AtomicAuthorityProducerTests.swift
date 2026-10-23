import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class AtomicAuthorityProducerTests: XCTestCase {
    func testEnrollmentCapturesAcceptedAtomicPREWithoutLegacyControlDraft() throws {
        let f = try PeerEnrollmentApprovalTests.Fixture()
        f.source = nil
        try AtomicAuthorityStoreFixture.transition(f.sourceRoot)
        f.source = try AtomicAuthorityStoreFixture.open(f.sourceRoot, accounts: f.accounts)
        let fresh = try f.source.withAccess(forUID: f.uid) {
            try f.source.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("atomic enrollment cut")],
                    operationID: "atomic-enrollment-source-write"))
        }
        XCTAssertTrue(fresh.isIndexReady, fresh.warnings.joined(separator: "\n"))
        let handle = try f.begin()
        let manifest = try f.ready(handle)
        XCTAssertEqual(
            manifest.storeID,
            try CanonicalReaderRequirement.storeIdentity(
                root: f.sourceRoot, ownerUID: tractanda_uid()))
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let cut = try XCTUnwrap(index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)))
        XCTAssertTrue(try index.isAcceptedAtomicControl(cut))
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.sourceRoot))
        XCTAssertEqual(try f.ready(handle), manifest)
        try f.capacity()
    }

    func testRetirementUsesAtomicPREAndPreservesExactLifecycleRetryAfterColdRebuild() throws {
        let f = try AtomicAuthorityReplicationTests.Fixture()
        let targetRoot = f.enrolled.source.targetRoot
        let targetOrigin = try XCTUnwrap(f.target.replicaID)
        let sourceOrigin = try XCTUnwrap(f.source.replicaID)
        let operation = try UUID.makeVersion1().uuidString.lowercased()
        try f.target.withAccess(forUID: f.enrolled.source.uid) {
            try f.target.removePeerIntake(
                peerID: f.enrolled.material.targetContext.peerID,
                retiredOriginIDs: [sourceOrigin], operationID: operation)
        }
        func verify() throws {
            let index = try ItemIndex(
                path: targetRoot.appendingPathComponent("index/items.sqlite").path, create: false)
            defer { index.close() }
            let cut = try XCTUnwrap(index.authorityControlHead(originID: targetOrigin))
            XCTAssertTrue(try index.isAcceptedAtomicControl(cut))
            XCTAssertTrue(try index.peerOriginRetired(sourceOrigin))
            XCTAssertFalse(try index.peerOriginRetired(targetOrigin))
            print("ATOMIC_RETIREMENT_SOURCE " + sourceOrigin + " TARGET " + targetOrigin)
            print("ATOMIC_RETIREMENT_CUTOFFS " + String(describing: try index.peerRetirementOriginPage()))
            if let sourceHead = try index.authorityControlHead(originID: sourceOrigin) {
                print("ATOMIC_RETIREMENT_SOURCE_HEAD " + sourceHead.recordID)
            }
            for retirement in try index.peerRetirementActiveBindings() {
                print(
                    "ATOMIC_RETIREMENT_EVENT " + retirement.recordID + " TICKS "
                        + String(try PeerLifecycle.revisionTicks(retirement.recordID)))
            }
            let coordinator = PeerIntakeCoordinator(
                root: targetRoot, ownerUID: tractanda_uid(),
                storeID: try CanonicalReaderRequirement.storeIdentity(
                    root: targetRoot, ownerUID: tractanda_uid()))
            for row in try index.authorityKindPage(kind: "atomicControl", after: nil) {
                let binding = try AuthorityBinding(recordID: row.descriptor.id, sha256: row.descriptor.sha256)
                guard
                    let receipt = try coordinator.journal.atomicAcceptance(
                        packageID: row.packageID, root: binding)
                else { continue }
                let header = try AtomicControlStage(rootBytes: coordinator.bytes(row)).header
                print(
                    "ATOMIC_RETIREMENT_ACCEPTED_ROOT " + header.binding.recordID + " ORIGIN " + header.origin
                        + " TICKS " + String(try PeerLifecycle.revisionTicks(header.binding.recordID))
                        + " CONFIG " + receipt.receipt.context.configuration.fileName)
            }
            print(
                "ATOMIC_RETIREMENT_CURRENT_CONFIG "
                    + String(try AuthorityStore.configurationSequence(root: targetRoot)))
        }
        try verify()
        // This source has not learned the receiver's disposal. Its genuine later authored
        // contribution still requires review; historical restore is not a current grant.
        let postCut = try f.source.withAccess(forUID: f.enrolled.source.uid) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: f.enrolled.revision.itemID,
                    expectedRevisionID: f.enrolled.revision.revisionID,
                    changes: ["subject": .text("post-disposal private contribution")],
                    operationID: "atomic-retirement-post-cut"))
        }
        XCTAssertTrue(postCut.isIndexReady, postCut.warnings.joined(separator: "\n"))
        let postIndex = try ItemIndex(
            path: targetRoot.appendingPathComponent("index/items.sqlite").path,
            create: false)
        do {
            let coordinator = PeerIntakeCoordinator(
                root: targetRoot, ownerUID: tractanda_uid(),
                storeID: try CanonicalReaderRequirement.storeIdentity(
                    root: targetRoot, ownerUID: tractanda_uid()))
            let node = try AuthorityRevision(originalBytes: RecordCodec.encode(postCut.revision))
            XCTAssertTrue(try coordinator.retirementBlocks(node, index: postIndex))
            XCTAssertFalse(
                try postIndex.peerRetirementCauses(
                    revisionID: postCut.revision.revisionID, origin: sourceOrigin
                ).isEmpty)
            let previous = try XCTUnwrap(postIndex.authorityControlHead(originID: sourceOrigin))
            let bootstrap = try coordinator.logicalControlHeader(previous, index: postIndex).bootstrap
            let directory = f.enrolled.source.root.appendingPathComponent("post-cut-private-root")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let archive = try AtomicAuthorityArchive(
                root: directory,
                limits: .init(maximumStoredBytes: 1024 * 1024, maximumParts: 128))
            var parents = [previous.itemValue].makeIterator()
            let handle = try archive.build(
                context: .init(
                    rootID: UUID.makeVersion1().uuidString.lowercased(), storeID: coordinator.storeID,
                    origin: sourceOrigin, actor: "human", createdAt: Timestamp.now(),
                    inputIdentity: String(repeating: "a", count: 64), previous: previous, bootstrap: bootstrap
                ),
                parents: { parents.next() }, effects: { nil as ItemValue? })
            do {
                let unexpected = try f.target.withAccess(forUID: f.enrolled.source.uid) {
                    try f.target.beginAtomicAuthorityValidation(archive: archive, handle: handle)
                }
                try unexpected.close()
                XCTFail("A newly issued retired-origin root must not start semantic validation.")
            } catch let error as TractandaError {
                XCTAssertEqual(error.code, "untrustedPeer")
            }
            XCTAssertEqual(try postIndex.authorityControlHead(originID: sourceOrigin), previous)
            try postIndex.closeChecked()
        } catch {
            postIndex.close()
            throw error
        }
        f.enrolled.target = nil
        try FileManager.default.removeItem(at: targetRoot.appendingPathComponent("index"))
        f.enrolled.target = try AtomicAuthorityStoreFixture.open(targetRoot, accounts: f.targetAccounts)
        try verify()
        try f.target.withAccess(forUID: f.enrolled.source.uid) {
            try f.target.removePeerIntake(
                peerID: f.enrolled.material.targetContext.peerID,
                retiredOriginIDs: [sourceOrigin], operationID: operation)
        }
        XCTAssertFalse(StoreCheckpoint.isDirty(root: targetRoot))
        try f.enrolled.source.capacity()
    }

    func testDescriptorSpoolRetainsFullRootBoundDescriptorAndLexicalOrder() throws {
        let f = try AtomicAuthorityStoreFixture()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        try index.installAtomicAuthorityIndexSchema(.publication)
        let token = "publication-fixture"
        defer { try? index.execute("DELETE FROM authority_atomic_publication_spool WHERE token=?", [token]) }
        let ids = try (0..<3).map { _ in try UUID.makeVersion1().uuidString.lowercased() }.sorted()
        let descriptors = ids.map {
            PeerPackage.Object(
                kind: .authority, id: $0, length: 32, sha256: String(repeating: "a", count: 64))
        }
        try index.withAtomicPublicationSpool {
            var bytes: UInt64 = 0
            for object in descriptors.reversed() {
                XCTAssertTrue(
                    try index.spoolAtomicPublicationDescriptor(object, token: token, storedBytes: &bytes))
            }
            XCTAssertEqual(
                try index.atomicPublicationDescriptorPage(token: token, afterID: nil, limit: 2),
                Array(descriptors.prefix(2)))
            XCTAssertEqual(
                try index.atomicPublicationDescriptorPage(token: token, afterID: ids[1], limit: 2),
                [descriptors[2]])
            XCTAssertFalse(
                try index.spoolAtomicPublicationDescriptor(descriptors[0], token: token, storedBytes: &bytes))
            XCTAssertThrowsError(try index.withAtomicPublicationSpool { () })
        }
        XCTAssertEqual(try index.atomicPublicationDescriptorPage(token: token, afterID: nil, limit: 2), [])
        try f.capacity()
    }
    func testActualSequentialWriterOriginalPREWorkAt16And32Operations() throws {
        let f = try AtomicAuthorityStoreFixture()
        try f.activateAndOpen()
        var operationUnits: [Int64] = []
        var units: Int64 = 0
        f.source.atomicOriginalPREWorkForTesting = { units += $0 }
        defer { f.source.atomicOriginalPREWorkForTesting = nil }
        for ordinal in 1...32 {
            units = 0
            let result = try f.source.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("bounded PRE measurement")],
                    operationID: "atomic-pre-measure-\(ordinal)"))
            XCTAssertTrue(result.isIndexReady, result.warnings.joined(separator: "\n"))
            operationUnits.append(units)
            if ordinal % 4 == 0 { try f.capacity() }
            if ordinal == 16 || ordinal == 32 {
                print(
                    "ATOMIC_ACTUAL_WRITER_PRE operations=\(ordinal) perOperationUnits=\(operationUnits) total=\(operationUnits.reduce(0,+))"
                )
            }
        }
        XCTAssertEqual(operationUnits.count, 32)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.sourceRoot))
    }

}
