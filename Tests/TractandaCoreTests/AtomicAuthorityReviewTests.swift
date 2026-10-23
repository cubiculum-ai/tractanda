import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class AtomicAuthorityReviewTests: XCTestCase {
    private func canonicalHashes(_ root: URL) throws -> [String: String] {
        try AttachmentFixtureCapacity.requireFree(at: root)
        var result: [String: String] = [:]
        var total: UInt64 = 0
        for case let file as URL in try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        {
            let metadata = try FileMetadata.read(at: file)
            guard metadata.type == .regular else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if relative == StoreCheckpoint.name { continue }
            if [
                "index/items.sqlite", "index/items.sqlite-wal", "index/items.sqlite-shm",
                "index/items.sqlite-journal",
            ].contains(relative) {
                continue
            }
            if relative.hasPrefix("index/rebuild-"), !relative.dropFirst(6).contains("/") {
                var name = String(relative.dropFirst("index/rebuild-".count))
                for suffix in ["-wal", "-shm", "-journal"] where name.hasSuffix(suffix) {
                    name.removeLast(suffix.count)
                    break
                }
                if name.hasSuffix(".sqlite") {
                    name.removeLast(".sqlite".count)
                    if UUID(uuidString: name) != nil { continue }
                }
            }
            guard
                metadata.size <= AttachmentFixtureCapacity.fixtureCapBytes
                    - min(total, AttachmentFixtureCapacity.fixtureCapBytes)
            else {
                throw TractandaError("resourceLimit", "Tiny review canonical hash cap")
            }
            total += metadata.size
            result[relative] = AuthorityRecordCodec.sha256(try Data(contentsOf: file))
        }
        XCTAssertTrue(result.keys.contains { $0.contains("/atomic-accepted/") })
        XCTAssertTrue(result.keys.contains { $0.hasPrefix(".peer-configuration/") })
        return result
    }
    private func assertCanonicalHashes(
        _ root: URL, expected: [String: String], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let actual = try canonicalHashes(root)
        let changed = Set(actual.keys).union(expected.keys).filter { actual[$0] != expected[$0] }.sorted()
        XCTAssertTrue(
            changed.isEmpty,
            "Canonical changed paths (\(changed.count)): " + changed.prefix(48).joined(separator: ", "),
            file: file, line: line)
    }
    private func removeDerivedIndex(_ root: URL) throws {
        for name in ["items.sqlite", "items.sqlite-wal", "items.sqlite-shm", "items.sqlite-journal"] {
            let file = root.appendingPathComponent("index").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    func testRealHeldReviewPublishesOneAtomicPairAndExactRetryThenUnrelatedWrite() throws {
        let f = try AuthorityReviewStoreTests.ReviewedFixture()
        defer {
            f.base.receiver = nil
            f.base.source = nil
            if let files = FileManager.default.enumerator(
                at: f.base.directory, includingPropertiesForKeys: nil)
            {
                for case let file as URL in files {
                    if let metadata = try? FileMetadata.read(at: file), metadata.type == .regular {
                        _ = chmod(file.path, 0o600)
                    }
                }
            }
        }
        f.base.source = nil
        f.base.receiver = nil
        try AtomicAuthorityStoreFixture.transition(f.base.sourceRoot)
        try AtomicAuthorityStoreFixture.transition(f.base.receiverRoot)
        f.base.source = try AtomicAuthorityStoreFixture.open(
            f.base.sourceRoot, accounts: f.base.sourceAccounts)
        f.base.receiver = try AtomicAuthorityStoreFixture.open(
            f.base.receiverRoot, accounts: f.base.receiverAccounts)
        let request = try f.request(operation: "real-atomic-reviewed-pair")
        let result: AuthorityStore.ReviewResult
        do { result = try f.base.receiver.resolveAuthorityReview(request) } catch {
            FileHandle.standardError.write(
                Data(("ATOMIC_REVIEW_FIRST_ERROR " + String(reflecting: error) + "\n").utf8))
            throw error
        }
        XCTAssertFalse(result.wasReplayed)
        XCTAssertEqual(result.disposition, .approved)
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, result.revision.revisionID)
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID, revisionID: f.held.revisionID), f.held)
        let replay = try f.base.receiver.resolveAuthorityReview(request)
        XCTAssertTrue(replay.wasReplayed)
        XCTAssertEqual(replay.revision, result.revision)
        let index = try ItemIndex(
            path: f.base.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let origin = try XCTUnwrap(f.base.receiver.replicaID)
        let root = try XCTUnwrap(index.authorityControlHead(originID: origin))
        XCTAssertTrue(try index.isAcceptedAtomicControl(root))
        XCTAssertEqual(try index.eligibilityAtCut(revisionID: f.held.revisionID, cut: root), .eligible)
        XCTAssertEqual(
            try index.eligibilityAtCut(revisionID: result.revision.revisionID, cut: root), .eligible)
        let coordinator = PeerIntakeCoordinator(
            root: f.base.receiverRoot, ownerUID: tractanda_uid(), storeID: f.base.storeID)
        let raw = try XCTUnwrap(index.retainedAuthorityObject(id: root.recordID))
        let stage = try AtomicControlStage(rootBytes: coordinator.bytes(raw))
        XCTAssertEqual(stage.effects.entryCount, 2)
        XCTAssertEqual(stage.effects.targetCount, 2)
        XCTAssertEqual(stage.parents.entryCount, 1)
        XCTAssertNotNil(try coordinator.journal.atomicAcceptance(packageID: raw.packageID, root: root))
        index.close()
        let unrelated = try f.base.receiver.commit(
            .init(
                classID: "Item",
                changes: ["subject": .text("unrelated after valid review")],
                operationID: "atomic-review-unrelated"))
        XCTAssertTrue(unrelated.isIndexReady, unrelated.warnings.joined(separator: "\n"))
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, result.revision.revisionID)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.base.receiverRoot))
        f.base.receiver = nil
        let canonical = try canonicalHashes(f.base.receiverRoot)
        try removeDerivedIndex(f.base.receiverRoot)
        f.base.receiver = try AtomicAuthorityStoreFixture.open(
            f.base.receiverRoot, accounts: f.base.receiverAccounts)
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, result.revision.revisionID)
        XCTAssertEqual(
            try f.base.receiver.get(unrelated.revision.itemID).revisionID, unrelated.revision.revisionID)
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID, revisionID: f.held.revisionID), f.held)
        XCTAssertTrue(try f.base.receiver.resolveAuthorityReview(request).wasReplayed)
        f.base.receiver = nil
        try assertCanonicalHashes(f.base.receiverRoot, expected: canonical)
        try f.base.capacity()
    }
    func testSharedAdministratorAtomicReviewReplicatesActualResolutionWithoutNewLocalOpinion() throws {
        let f = try AtomicAuthorityReplicationTests.Fixture(nonAdministratorWriter: true)
        let revision = try f.source.withAccess(forUID: f.enrolled.source.accounts.contributor) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: f.enrolled.revision.itemID,
                    expectedRevisionID: f.enrolled.revision.revisionID,
                    changes: ["subject": .text("reviewed current mapping drift")],
                    operationID: "atomic-reviewed-original")
            ).revision
        }
        f.targetAccounts.contributorHasWriterGroup = false
        let (firstHandle, firstManifest) = try f.packet(revision.revisionID)
        XCTAssertGreaterThanOrEqual(try f.send(firstHandle, manifest: firstManifest).held, 1)
        let sourceIndex = try ItemIndex(
            path: f.enrolled.source.sourceRoot.appendingPathComponent("index/items.sqlite").path,
            create: false)
        let evidence = try XCTUnwrap(sourceIndex.authorityEvidence(revisionID: revision.revisionID))
        let binding = try AuthorityBinding(
            recordID: evidence.descriptor.id, sha256: evidence.descriptor.sha256)
        sourceIndex.close()
        let state = try f.target.prepareAuthorityReview(
            itemID: revision.itemID, revisionID: revision.revisionID,
            evidence: binding, actorUID: f.enrolled.source.uid)
        let request = AuthorityStore.ReviewRequest(
            itemID: revision.itemID, revisionID: revision.revisionID,
            evidence: binding, expectedStateToken: state.stateToken, reviewedFrontier: state.decisionFrontier,
            reviewedControlHolds: state.controlHolds,
            changes: ["subject": .text("globally reviewed resolution")],
            unset: [], operationID: "atomic-global-reviewed-resolution",
            reviewedRetirements: state.retirements)
        var checkedForeignPolicy = false
        f.target.beforeProjectionCommitAuthorityForTesting = { [weak f] in
            let f = try XCTUnwrap(f)
            let index = try ItemIndex(
                path: f.enrolled.source.targetRoot.appendingPathComponent("index/items.sqlite").path,
                create: false)
            defer { index.close() }
            let cut = try XCTUnwrap(index.authorityControlHead(originID: XCTUnwrap(f.target.replicaID)))
            XCTAssertEqual(try index.eligibilityAtCut(revisionID: revision.revisionID, cut: cut), .eligible)
            XCTAssertNil(try index.localAuthorityAcceptanceControl(revisionID: revision.revisionID))
            XCTAssertFalse(try index.authorityHasLocalHistoryAdmission(revisionID: revision.revisionID))
            let policy = try index.authorityItemFrontierAtCut(itemID: revision.itemID, cut: cut)
            XCTAssertEqual(policy, state.policyFrontier.map(\.revisionID).sorted())
            XCTAssertFalse(policy.contains(revision.revisionID))
            print(
                "ATOMIC_REVIEW_POLICY cut=\(cut.recordID) foreign=\(revision.revisionID) actual=\(policy) expected=\(state.policyFrontier.map(\.revisionID))"
            )
            checkedForeignPolicy = true
        }
        let reviewed = try f.target.resolveAuthorityReview(request, actorUID: f.enrolled.source.uid)
        f.target.beforeProjectionCommitAuthorityForTesting = nil
        XCTAssertTrue(checkedForeignPolicy)
        XCTAssertEqual(reviewed.disposition, .approved)
        let (handle, manifest) = try f.packet(
            reviewed.revision.revisionID, from: f.target,
            context: f.enrolled.material.targetContext)
        let received = try f.send(
            handle, manifest: manifest, from: f.target, to: f.source,
            outgoing: f.enrolled.material.targetContext, incoming: f.enrolled.material.sourceContext,
            binding: f.enrolled.source.request.sourceCredential.binding)
        XCTAssertEqual(received.missing, 0)
        XCTAssertEqual(received.held, 0)
        XCTAssertEqual(
            try f.source.withAccess(forUID: f.enrolled.source.uid) {
                try f.source.get(revision.itemID).revisionID
            }, reviewed.revision.revisionID)
        XCTAssertEqual(
            try f.source.withAccess(forUID: f.enrolled.source.uid) {
                try f.source.get(revision.itemID, revisionID: revision.revisionID)
            }, revision)
        XCTAssertTrue(
            try f.target.resolveAuthorityReview(request, actorUID: f.enrolled.source.uid).wasReplayed)
        let follow = try f.source.withAccess(forUID: f.enrolled.source.uid) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: revision.itemID,
                    expectedRevisionID: reviewed.revision.revisionID,
                    changes: ["subject": .text("ordinary after shared review")],
                    operationID: "atomic-after-shared-review"))
        }
        XCTAssertTrue(follow.isIndexReady, follow.warnings.joined(separator: "\n"))
        let (followHandle, followManifest) = try f.packet(follow.revision.revisionID)
        let followed = try f.send(followHandle, manifest: followManifest)
        XCTAssertEqual(followed.missing, 0)
        XCTAssertEqual(followed.held, 0)
        XCTAssertEqual(
            try f.target.withAccess(forUID: f.enrolled.source.uid) {
                try f.target.get(revision.itemID).revisionID
            }, follow.revision.revisionID)
        XCTAssertThrowsError(
            try f.target.withAccess(forUID: f.targetAccounts.contributor) {
                try f.target.get(revision.itemID, revisionID: revision.revisionID)
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.enrolled.source.sourceRoot))
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.enrolled.source.targetRoot))
        f.enrolled.target = nil
        f.enrolled.source.source = nil
        let sourceBytes = try canonicalHashes(f.enrolled.source.sourceRoot)
        let targetBytes = try canonicalHashes(f.enrolled.source.targetRoot)
        try removeDerivedIndex(f.enrolled.source.sourceRoot)
        try removeDerivedIndex(f.enrolled.source.targetRoot)
        f.enrolled.source.source = try AtomicAuthorityStoreFixture.open(
            f.enrolled.source.sourceRoot, accounts: f.enrolled.source.accounts)
        f.enrolled.target = try AtomicAuthorityStoreFixture.open(
            f.enrolled.source.targetRoot, accounts: f.targetAccounts)
        XCTAssertEqual(
            try f.source.withAccess(forUID: f.enrolled.source.uid) {
                try f.source.get(revision.itemID).revisionID
            }, follow.revision.revisionID)
        XCTAssertEqual(
            try f.target.withAccess(forUID: f.enrolled.source.uid) {
                try f.target.get(revision.itemID).revisionID
            }, follow.revision.revisionID)
        XCTAssertThrowsError(
            try f.target.withAccess(forUID: f.targetAccounts.contributor) {
                try f.target.get(revision.itemID, revisionID: revision.revisionID)
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        f.enrolled.target = nil
        f.enrolled.source.source = nil
        try assertCanonicalHashes(f.enrolled.source.sourceRoot, expected: sourceBytes)
        try assertCanonicalHashes(f.enrolled.source.targetRoot, expected: targetBytes)
        try f.enrolled.source.capacity()
    }

}
