import XCTest

@testable import TractandaCore

final class PeerCategoryAssignmentTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private func permissions(_ owner: String = "admin", mode: Int = 0o640) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner),
            "group": .text("staff"), "mode": .integer(Int64(mode)), "acl": .object([:]),
        ])
    }
    private func category(_ f: Fixture, mode: Int = 0o640) throws -> Revision {
        try f.source.commit(
            .init(
                classID: "Item",
                changes: [
                    "subject": .text("Read-only assignment target"),
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                    ]),
                    "permissions": permissions(mode: mode),
                ], operationID: Fixture.id())
        ).revision
    }
    private func create(_ f: Fixture, category: Revision) throws -> Revision {
        try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(
                .init(
                    classID: "Item",
                    changes: [
                        "subject": .text("Categorized original"),
                        "categoryOverrides": .object([category.itemID: .text("include")]),
                    ], operationID: Fixture.id())
            ).revision
        }
    }
    private func send(_ f: Fixture, _ revision: Revision) throws -> AuthorityStore.Result {
        try f.send(f.packet(f.source.peerMetadataObjects(revisionID: revision.revisionID)))
    }
    func testSealedRetainedIntakeUsesRecoveryBudgetButOrdinaryReplayKeepsWireBudget() throws {
        for recovery in [false, true] {
            let f = try Fixture()
            try f.bootstrap()
            let original = try f.source.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("Tiny read-budget scope fixture")],
                    operationID: Fixture.id())
            ).revision
            let packet = try f.packet(f.source.peerMetadataObjects(revisionID: original.revisionID))
            _ = try f.send(packet)
            var charged = false
            f.receiver.peerIntakeBoundaryForTesting = { boundary in
                if boundary == .applied {
                    charged = true
                    // Charge a counter only: no allocation/read/write of these bytes occurs.
                    try f.receiver.chargePeerReadBudgetForTesting(
                        Int(PeerPackage.Limits().maximumReadBytes) + 1)
                }
            }
            defer { f.receiver.peerIntakeBoundaryForTesting = nil }
            let replay = {
                try f.receiver.commitPeerIntake(
                    context: f.context, packageID: packet.manifest.packageID,
                    expectedContextToken: f.receiver.peerIntakeContextToken(), retainedRecovery: recovery)
            }
            if recovery {
                _ = try replay()
                XCTAssertTrue(f.receiver.isCanonicalTrusted)
                XCTAssertFalse(StoreCheckpoint.isDirty(root: f.receiverRoot))
                XCTAssertEqual(try f.receiver.get(original.itemID), original)
            } else {
                XCTAssertThrowsError(try replay()) {
                    XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
                }
                XCTAssertFalse(f.receiver.isCanonicalTrusted, "Ordinary resource denial remains fail closed")
            }
            XCTAssertTrue(charged, "Probe must run inside the real intake completion scope")
            try f.capacity()
        }
    }
    func testRetainedRecoveryStillRequiresAnExistingSeal() throws {
        let f = try Fixture()
        try f.bootstrap()
        let original = try f.source.commit(
            .init(
                classID: "Item", changes: ["subject": .text("Unsealed recovery cannot gain admission")],
                operationID: Fixture.id())
        ).revision
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: original.revisionID))
        _ = try f.receiver.beginPeerIntake(context: f.context, manifestBytes: JSON.encode(packet.manifest))
        for (object, bytes) in packet.objects {
            _ = try f.receiver.appendPeerObject(
                context: f.context, packageID: packet.manifest.packageID,
                object: object, offset: 0, bytes: bytes)
        }
        XCTAssertThrowsError(
            try f.receiver.commitPeerIntake(
                context: f.context, packageID: packet.manifest.packageID,
                expectedContextToken: f.receiver.peerIntakeContextToken(), retainedRecovery: true)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidPeerPackage")
        }
        XCTAssertTrue(f.receiver.isCanonicalTrusted)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.receiverRoot))
        try f.capacity()
    }
    func testCategorizedNewItemAndAssignmentRevisionUseCategoryReadNotWrite() throws {
        let f = try Fixture()
        let target = try category(f)
        try f.bootstrap()
        let original = try create(f, category: target)
        XCTAssertGreaterThan(try send(f, original).accepted, 0)
        XCTAssertEqual(
            try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.get(original.itemID)
            }, original)
        let assigned = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: f.base.itemID,
                    expectedRevisionID: f.base.revisionID,
                    changes: ["categoryOverrides": .object([target.itemID: .text("exclude")])],
                    operationID: Fixture.id())
            ).revision
        }
        XCTAssertGreaterThan(try send(f, assigned).accepted, 0)
        XCTAssertEqual(
            try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.get(assigned.itemID)
            }, assigned)
        XCTAssertTrue(RevisionMerge.protectedFields.contains("categoryOverrides"))
        let protected = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: assigned.itemID,
                    expectedRevisionID: assigned.revisionID,
                    changes: ["categoryOrder": .integer(2)], operationID: Fixture.id())
            ).revision
        }
        XCTAssertGreaterThan(try send(f, protected).held, 0)
        try f.capacity()
    }
    func testCurrentCategoryReadDenialStaysHeldOnSamePackageRetry() throws {
        let f = try Fixture()
        let target = try category(f)
        try f.bootstrap()
        let original = try create(f, category: target)
        _ = try f.receiver.commit(
            .init(
                action: .revise, itemID: target.itemID,
                expectedRevisionID: target.revisionID,
                changes: ["permissions": permissions(mode: 0o600)], operationID: Fixture.id()))
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: original.revisionID))
        XCTAssertGreaterThan(try f.send(packet).held, 0)
        let journal = f.receiverRoot.appendingPathComponent(
            "authority/assessments/" + packet.manifest.packageID + "/" + original.revisionID)
        let priorAssessment = try Data(contentsOf: journal)
        let retry = try f.receiver.commitPeerIntake(
            context: f.context, packageID: packet.manifest.packageID,
            expectedContextToken: f.receiver.peerIntakeContextToken())
        XCTAssertGreaterThan(retry.held, 0)
        XCTAssertEqual(try Data(contentsOf: journal), priorAssessment)
        XCTAssertThrowsError(
            try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.get(original.itemID)
            })
        try f.capacity()
    }
    func testUnchangedPrivateCategoryReferenceAndRemovalNeedNoNewCategoryRead() throws {
        let f = try Fixture()
        let target = try category(f)
        try f.bootstrap()
        let original = try create(f, category: target)
        _ = try send(f, original)
        _ = try f.receiver.commit(
            .init(
                action: .revise, itemID: target.itemID,
                expectedRevisionID: target.revisionID,
                changes: ["permissions": permissions(mode: 0o600)], operationID: Fixture.id()))
        let edited = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: original.itemID,
                    expectedRevisionID: original.revisionID,
                    changes: ["subject": .text("Unchanged private reference")], operationID: Fixture.id())
            ).revision
        }
        XCTAssertGreaterThan(try send(f, edited).accepted, 0)
        let removed = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: edited.itemID,
                    expectedRevisionID: edited.revisionID, unset: ["categoryOverrides"],
                    operationID: Fixture.id())
            ).revision
        }
        XCTAssertGreaterThan(try send(f, removed).accepted, 0)
        XCTAssertNil(
            try f.receiver.withAccess(forUID: f.receiverAccounts.alice) { try f.receiver.get(removed.itemID) }
                .fields["categoryOverrides"])
        try f.capacity()
    }
    func testSourceCategoryReadUsesFrozenPolicyAndSourceOnlyNeverUsesCurrentACL() throws {
        let f = try Fixture()
        let publicCategory = try category(f)
        let privateCategory = try category(f, mode: 0o600)
        try f.bootstrap()
        let original = try create(f, category: publicCategory)
        let exported = try f.source.peerMetadataObjects(revisionID: original.revisionID)
        _ = try f.send(f.packet(exported))
        let raw = try XCTUnwrap(exported.first { Fixture.isEvidence($0, for: original.revisionID) })
        let evidence = try AuthorityRecordCodec.decode(raw.1).record
        let node = try AuthorityRevision(originalBytes: RecordCodec.encode(original))
        let coordinator = PeerIntakeCoordinator(
            root: f.receiverRoot, ownerUID: f.receiver.ownerUID, storeID: f.storeID)
        let index = try ItemIndex(
            path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        try index.initializeAuthoritySchema()
        try index.initializeAuthorityControlSchema()
        let cut = try XCTUnwrap(coordinator.sourceControl(evidence))
        var evaluator = RuntimeAuthorityEvaluator(
            accounts: f.receiverAccounts, currentConfigurations: [], currentItemPolicies: [],
            ownerUID: f.receiver.ownerUID,
            loadBinding: { try coordinator.bindingAtCut($0, cut: cut, index: index) },
            categoryPoliciesAtSourceCut: { id in
                try index.authorityItemFrontierAtCut(itemID: id, cut: cut).map { revisionID in
                    let row = try XCTUnwrap(index.retainedAuthorityObject(id: revisionID))
                    return try AuthorityRevision(originalBytes: coordinator.bytes(row)).revision
                }
            },
            requireCurrentCategoryRead: { _, _ in XCTFail("Source-only/history used current category ACL") })
        XCTAssertEqual(
            try evaluator.evaluate(node, evidence: evidence, sourceOnly: true).disposition, .eligible)
        XCTAssertEqual(
            try evaluator.evaluate(node, evidence: evidence, historicalPreserved: true).disposition, .eligible
        )
        // A malicious sender's evaluated=true is not a source category-read proof.
        var fields = original.fields
        fields["categoryOverrides"] = .object([privateCategory.itemID: .text("include")])
        let forged = try AuthorityRevision(
            originalBytes: RecordCodec.encode(Revision(fields: fields, formatVersion: 2)))
        var payload = evidence.payload
        payload["target"] = try AuthorityStore.Target(
            itemID: original.itemID, revisionID: original.revisionID, sha256: forged.sha256
        ).itemValue
        let forgedEvidence = try AuthorityRecord(
            recordID: Fixture.id(), storeID: f.storeID,
            originReplicaID: evidence.originReplicaID, kind: .authoredEvidence,
            parentAuthorityIDs: evidence.parentAuthorityIDs, actorPrincipal: evidence.actorPrincipal,
            createdAt: evidence.createdAt, payload: payload)
        let denied = try evaluator.evaluate(forged, evidence: forgedEvidence, sourceOnly: true)
        XCTAssertEqual(denied.disposition, .held)
        XCTAssertTrue(denied.reason.contains("source category policy"))
        evaluator.categoryPoliciesAtSourceCut = nil
        XCTAssertEqual(
            try evaluator.evaluate(node, evidence: evidence, sourceOnly: true).disposition,
            .missingDependencies)
        var malformed = original.fields
        malformed["categoryOverrides"] = .text("invalid")
        XCTAssertThrowsError(
            try AuthorityRevision(
                originalBytes: RecordCodec.encode(Revision(fields: malformed, formatVersion: 2)))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidCategory")
        }
        try f.capacity()
    }

}
