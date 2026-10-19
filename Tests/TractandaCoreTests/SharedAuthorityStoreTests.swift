import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class SharedAuthorityStoreTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture

    private func objects(_ root: URL, fixture: Fixture) throws -> [(PeerPackage.Object, Data)] {
        try fixture.capacity()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [(PeerPackage.Object, Data)] = []
        var total = 0
        for case let url as URL in files {
            let authority = url.pathExtension == "authority"
            let item = url.pathExtension == "tractanda" && url.path.contains("/items/")
            guard authority || item else { continue }
            let bytes = try Data(contentsOf: url)
            total += bytes.count
            guard total <= 8 * 1024 * 1024 else {
                throw TractandaError("resourceLimit", "Tiny fixture metadata cap")
            }
            let id =
                authority
                ? try AuthorityRecordCodec.decode(bytes).record.recordID
                : try RecordCodec.decode(bytes).revisionID
            result.append(
                (
                    .init(
                        kind: authority ? .authority : .item, id: id, length: bytes.count,
                        sha256: AuthorityRecordCodec.sha256(bytes)), bytes
                ))
        }
        return result.sorted { $0.0.id < $1.0.id }
    }

    private func send(
        _ packet: PeerIntakeStoreTests.Packet, to store: ItemStore, context: PeerPackage.Context
    ) throws -> AuthorityStore.Result {
        _ = try store.beginPeerIntake(context: context, manifestBytes: JSON.encode(packet.manifest))
        for (object, bytes) in packet.objects {
            _ = try store.appendPeerObject(
                context: context, packageID: packet.manifest.packageID,
                object: object, offset: 0, bytes: bytes)
        }
        return try store.commitPeerIntake(
            context: context, packageID: packet.manifest.packageID,
            expectedContextToken: store.peerIntakeContextToken())
    }

    private func origin(_ fixture: Fixture) throws -> String {
        try XCTUnwrap(
            ReplicaIdentity.load(
                root: fixture.receiverRoot, storeID: fixture.storeID, ownerUID: tractanda_uid())
        ).replicaID
    }

    private func third(_ f: Fixture) throws -> (ItemStore, URL) {
        guard AttachmentFixtureCapacity.fixtureCapBytes >= 24 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Three-store fixture estimates24MiB")
        }
        try f.capacity()
        let root = f.directory.appendingPathComponent("third")
        var store: ItemStore? = try ItemStore(
            root: root, accounts: f.receiverAccounts, revisionProjectionEnabled: true)
        store = nil
        let name = ".tractanda-store-identity.json"
        try Data(contentsOf: f.sourceRoot.appendingPathComponent(name)).write(
            to: root.appendingPathComponent(name), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path)
        store = try Fixture.open(root, f.receiverAccounts)
        try store!.configurePeerIntake(peers: [f.context])
        try f.bootstrap(to: store)
        try f.capacity()
        return (store!, root)
    }

    func testDelayedRemovalDemotesAlreadyAcceptedPostEventWorkAndExactReviewSurvivesColdRebuild() throws {
        let f = try Fixture()
        try f.bootstrap()
        var created: (ItemStore, URL)? = try third(f)
        var heldTarget: ItemStore? = created!.0
        let targetRoot = created!.1
        created = nil
        var target: ItemStore { heldTarget! }
        let rOrigin = try origin(f)
        let relay = try PeerPackage.Context(
            peerID: "removal-relay", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("delayed removal".utf8)),
            permittedOrigins: [f.origin, rOrigin].sorted())
        try target.configurePeerIntake(peers: [f.context, relay])
        try f.receiver.removePeerIntake(
            peerID: f.context.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())
        let later = try f.edit(subject: "accepted elsewhere after removal event")
        let laterObjects = try f.source.peerMetadataObjects(revisionID: later.revisionID)
        _ = try f.send(f.packet(laterObjects), to: target)
        XCTAssertEqual(try target.get(later.itemID), later)
        _ = try send(f.packet(objects(f.receiverRoot, fixture: f)), to: target, context: relay)
        XCTAssertNotEqual(try target.get(later.itemID).revisionID, later.revisionID)
        XCTAssertEqual(try target.get(later.itemID, revisionID: later.revisionID), later)
        _ = try f.send(f.packet(laterObjects), to: target)
        XCTAssertNotEqual(
            try target.get(later.itemID).revisionID, later.revisionID,
            "Exact receipt replay must not turn historical eligibility into current authority.")
        let witness = try XCTUnwrap(laterObjects.first { Fixture.isEvidence($0, for: later.revisionID) })
        let evidence = try AuthorityBinding(recordID: witness.0.id, sha256: witness.0.sha256)
        let state = try target.prepareAuthorityReview(
            itemID: later.itemID, revisionID: later.revisionID, evidence: evidence)
        XCTAssertEqual(state.retirements.count, 1)
        let reviewed = try target.resolveAuthorityReview(
            .init(
                itemID: later.itemID, revisionID: later.revisionID,
                evidence: evidence, expectedStateToken: state.stateToken,
                reviewedFrontier: state.decisionFrontier,
                reviewedControlHolds: state.controlHolds,
                changes: ["subject": .text("reviewed after timestamp removal")], unset: [],
                operationID: Fixture.id(), reviewedRetirements: state.retirements))
        XCTAssertEqual(try target.get(later.itemID).revisionID, reviewed.revision.revisionID)
        _ = try f.send(f.packet(laterObjects), to: target)
        XCTAssertEqual(
            try target.get(later.itemID).revisionID, reviewed.revision.revisionID,
            "An old receipt cannot overwrite the exact completed review's current eligibility.")
        XCTAssertEqual(try target.get(later.itemID, revisionID: later.revisionID), later)
        try target.rebuildIndex()
        XCTAssertEqual(try target.get(later.itemID).revisionID, reviewed.revision.revisionID)
        // Force a genuinely cold disposable-index rebuild; no canonical byte is rewritten.
        heldTarget = nil
        try FileManager.default.removeItem(at: targetRoot.appendingPathComponent("index"))
        heldTarget = try Fixture.open(targetRoot, f.receiverAccounts)
        XCTAssertEqual(try target.get(later.itemID).revisionID, reviewed.revision.revisionID)
        try f.capacity()
    }

    func testIncompleteRetirementStaysInertThenFullProofFencesOwnOriginAndPreservesReadOnlyRetry() throws {
        let f = try Fixture()
        try f.bootstrap()
        let rOrigin = try origin(f)
        let inbound = try PeerPackage.Context(
            peerID: "receiver", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("reverse authority".utf8)),
            permittedOrigins: [f.origin, rOrigin].sorted())
        try f.source.configurePeerIntake(peers: [inbound])
        let request = CommitRequest(
            action: .revise, itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
            changes: ["body": .text("already committed")], operationID: "before-own-retirement")
        let committed = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(request).revision
        }
        try f.receiver.removePeerIntake(
            peerID: f.context.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())
        let all = try objects(f.receiverRoot, fixture: f)
        let root = try XCTUnwrap(
            all.first { entry in
                entry.0.kind == .authority
                    && (try? AuthorityRecordCodec.decode(entry.1).record.kind) == .originRetirement
            })
        _ = try send(f.packet([root]), to: f.source, context: inbound)
        // Missing PRE cut/policy proof is an inert observation, so unrelated local work still succeeds.
        let afterObservation = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: committed.itemID,
                    expectedRevisionID: committed.revisionID,
                    changes: ["body": .text("offline work remains possible")],
                    operationID: "after-inert-observation")
            ).revision
        }
        _ = try send(f.packet(all), to: f.source, context: inbound)
        XCTAssertEqual(try f.source.get(f.base.itemID, revisionID: f.base.revisionID), f.base)
        XCTAssertThrowsError(
            try f.source.withAccess(forUID: f.sourceAccounts.alice) {
                try f.source.commit(
                    .init(
                        action: .revise, itemID: afterObservation.itemID,
                        expectedRevisionID: afterObservation.revisionID,
                        changes: ["body": .text("must not publish")], operationID: "after-fence"))
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "localOriginRetired") }
        XCTAssertTrue(
            try f.source.withAccess(forUID: f.sourceAccounts.alice) {
                try f.source.commit(request).wasReplayed
            })
        try f.source.rebuildIndex()
        XCTAssertEqual(try f.source.get(f.base.itemID, revisionID: f.base.revisionID), f.base)
        try f.capacity()
    }

    func testNewReviewCannotPublishFromRetiredOrigin() throws {
        let review = try AuthorityReviewStoreTests.ReviewedFixture()
        let f = review.base
        let pending = try review.request(operation: "not-allowed-after-own-removal")
        let rOrigin = try origin(f)
        let endpoint = try PeerPackage.Context(
            peerID: "retire-reviewer", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("reviewer origin".utf8)),
            permittedOrigins: [rOrigin])
        try f.source.configurePeerIntake(peers: [endpoint])
        try f.source.removePeerIntake(
            peerID: endpoint.peerID, retiredOriginIDs: [rOrigin], operationID: Fixture.id())
        _ = try f.send(f.packet(objects(f.sourceRoot, fixture: f)))
        XCTAssertThrowsError(try f.receiver.resolveAuthorityReview(pending)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "localOriginRetired")
        }
        XCTAssertEqual(try f.receiver.get(f.base.itemID, revisionID: f.base.revisionID), f.base)
        try f.capacity()
    }

    func testUnknownClockAllowsRetirementKnownBadRefusesWithoutMutation() throws {
        let f = try Fixture()
        try f.bootstrap()
        var health = try PeerClockHealth()
        _ = health.recordSample(monotonicNow: 1, offset: 30, uncertainty: 0.1, nextInterval: 1800)
        f.receiver.peerClockHealth = health
        let before = try objects(f.receiverRoot, fixture: f).map { $0.0 }
        XCTAssertThrowsError(
            try f.receiver.removePeerIntake(
                peerID: f.context.peerID,
                retiredOriginIDs: [f.origin], operationID: Fixture.id())
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "clockUnhealthy")
        }
        XCTAssertEqual(try objects(f.receiverRoot, fixture: f).map { $0.0 }, before)
        f.receiver.peerClockHealth = try PeerClockHealth()
        try f.receiver.removePeerIntake(
            peerID: f.context.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())
        try f.capacity()
    }
}
