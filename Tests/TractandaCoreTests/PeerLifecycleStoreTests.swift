import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class PeerLifecycleStoreTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private func code(
        _ expected: String, _ body: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }
    private func rotated(_ context: PeerPackage.Context, _ name: String) throws -> PeerPackage.Context {
        try .init(
            peerID: context.peerID, storeID: context.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data(name.utf8)),
            permittedOrigins: context.permittedOrigins)
    }
    private func canonical(_ root: URL) throws -> [String: String] {
        try AttachmentFixtureCapacity.requireFree(at: root)
        var result: [String: String] = [:]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let file as URL in files where ["tractanda", "authority"].contains(file.pathExtension) {
            result[file.path] = AuthorityRecordCodec.sha256(try Data(contentsOf: file))
        }
        return result
    }
    private func configuration(_ f: Fixture) throws -> AuthorityStore.Configuration {
        try XCTUnwrap(
            AuthorityStore.configuration(
                root: f.receiverRoot,
                files: DocumentContentFiles(
                    root: f.receiverRoot, ownerUID: tractanda_uid(),
                    minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)))
    }
    func testTwoRotationsPreserveAcceptedControlsHistoryAndExactRetryAcrossColdRebuild() throws {
        let f = try Fixture()
        try f.bootstrap()
        let accepted = try f.edit(subject: "accepted before rotation")
        _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: accepted.revisionID)))
        let bytes = try canonical(f.receiverRoot)
        let original = f.context!
        let second = try rotated(original, "lifecycle-second")
        let third = try rotated(original, "lifecycle-third")
        let operation = try Fixture.id()
        try f.receiver.rotatePeerIntakeCredential(
            peerID: original.peerID, replacement: second,
            operationID: operation)
        try f.receiver.rotatePeerIntakeCredential(
            peerID: original.peerID, replacement: third,
            operationID: Fixture.id())
        let after = try configuration(f)
        try f.receiver.rotatePeerIntakeCredential(
            peerID: original.peerID, replacement: second,
            operationID: operation)
        XCTAssertEqual(try configuration(f), after)
        XCTAssertEqual(try f.receiver.peerIntakeContext(peerID: original.peerID), third)
        XCTAssertEqual(try f.receiver.get(accepted.itemID).revisionID, accepted.revisionID)
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(accepted.itemID, revisionID: f.base.revisionID), f.base)
        XCTAssertEqual(try f.receiver.get(accepted.itemID).revisionID, accepted.revisionID)
        f.receiver = nil
        try FileManager.default.removeItem(at: f.receiverRoot.appendingPathComponent("index"))
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(accepted.itemID).revisionID, accepted.revisionID)
        for (path, digest) in bytes { XCTAssertEqual(try canonical(f.receiverRoot)[path], digest) }
        code("operationMismatch") {
            try f.receiver.rotatePeerIntakeCredential(
                peerID: original.peerID, replacement: third,
                operationID: operation)
        }
        code("invalidPeerLifecycle") {
            try f.receiver.rotatePeerIntakeCredential(
                peerID: original.peerID, replacement: original,
                operationID: Fixture.id())
        }
        try f.capacity()
    }
    func testRotationRejectsStaleSessionsResumeAndInventoryAndRaisesReaderGuard() throws {
        let f = try Fixture()
        try f.bootstrap()
        let old = f.context!
        let boundary = try f.receiver.capturePeerInventory(context: old)
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: f.base.revisionID))
        _ = try f.receiver.beginPeerIntake(context: old, manifestBytes: JSON.encode(packet.manifest))
        let updated = try rotated(old, "new-authentication-generation")
        try f.receiver.rotatePeerIntakeCredential(
            peerID: old.peerID, replacement: updated,
            operationID: Fixture.id())
        code("peerConfigurationChanged") {
            _ = try f.receiver.beginPeerIntake(context: old, manifestBytes: JSON.encode(packet.manifest))
        }
        code("peerConfigurationChanged") {
            _ = try f.receiver.inspectPeerIntake(context: old, packageID: packet.manifest.packageID)
        }
        code("peerConfigurationChanged") {
            _ = try f.receiver.resumePeerIntake(context: old, packageID: packet.manifest.packageID)
        }
        code("peerConfigurationChanged") {
            _ = try f.receiver.peerInventoryPage(context: old, boundary: boundary)
        }
        let requirement = try XCTUnwrap(
            CanonicalReaderRequirement.load(
                root: f.receiverRoot,
                ownerUID: tractanda_uid()))
        XCTAssertEqual(requirement.minimumReaderLevel, 11)
        XCTAssertTrue(requirement.capabilities.contains(PeerLifecycle.capability))
        let previousReader = CanonicalFormatSupport(
            readerLevel: 5, writerLevel: 5, read: [1, 2],
            write: [2],
            capabilities: [
                AuthorityStore.capability, AuthorityStore.causalCapability,
                AuthorityStore.reviewCapability,
            ].sorted())
        XCTAssertThrowsError(try previousReader.require(requirement))
        code("managedPeerLifecycleRequired") { try f.receiver.configurePeerIntake(peers: [old]) }
    }
    func testRetirementAdmitsUnseenPreCutoffAndHoldsPostCutoffThroughEveryRelay() throws {
        let f = try Fixture()
        try f.bootstrap()
        let offline = try f.edit(subject: "unseen but issued before removal")
        let relay = try PeerPackage.Context(
            peerID: "alternate", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("alternate relay".utf8)),
            permittedOrigins: [f.origin])
        try f.receiver.configurePeerIntake(peers: [f.context, relay])
        let before = try canonical(f.receiverRoot)
        try f.receiver.removePeerIntake(
            peerID: f.context.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())
        XCTAssertEqual(
            try f.send(f.packet(f.source.peerMetadataObjects(revisionID: offline.revisionID)), context: relay)
                .accepted, 1)
        XCTAssertEqual(try f.receiver.get(offline.itemID), offline)
        let late = try f.edit(subject: "issued after removal")
        XCTAssertGreaterThanOrEqual(
            try f.send(f.packet(f.source.peerMetadataObjects(revisionID: late.revisionID)), context: relay)
                .held, 1)
        code("notFound") { _ = try f.receiver.get(late.itemID, revisionID: late.revisionID) }
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(offline.itemID), offline)
        let after = try canonical(f.receiverRoot)
        for (path, digest) in before { XCTAssertEqual(after[path], digest) }
        try f.capacity()
    }

    func testPreparedAndCommittedRotationFailuresRecoverAndNeverReapplyOldConfiguration() throws {
        for boundary in [PeerLifecycle.Boundary.prepared, .committed] {
            let f = try Fixture()
            try f.bootstrap()
            let updated = try rotated(f.context, "rotation-failure-\(boundary)")
            let operation = try Fixture.id()
            f.receiver.peerLifecycleBoundaryForTesting = {
                if $0 == boundary { throw TractandaError("injectedLifecycleFailure", "simulated crash") }
            }
            code("injectedLifecycleFailure") {
                try f.receiver.rotatePeerIntakeCredential(
                    peerID: f.context.peerID, replacement: updated,
                    operationID: operation)
            }
            f.receiver = nil
            f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
            XCTAssertEqual(try f.receiver.peerIntakeContext(peerID: updated.peerID), updated)
            XCTAssertEqual(try f.receiver.get(f.base.itemID), f.base)
            let later = try rotated(updated, "later-rotation-\(boundary)")
            try f.receiver.rotatePeerIntakeCredential(
                peerID: updated.peerID, replacement: later,
                operationID: Fixture.id())
            try f.receiver.rotatePeerIntakeCredential(
                peerID: updated.peerID, replacement: updated,
                operationID: operation)
            XCTAssertEqual(try f.receiver.peerIntakeContext(peerID: updated.peerID), later)
            try f.capacity()
        }
    }
    func testPreparedAndCommittedRetirementFailuresRecoverExactCanonicalDecision() throws {
        for boundary in [PeerLifecycle.Boundary.prepared, .committed] {
            let f = try Fixture()
            try f.bootstrap()
            let operation = try Fixture.id()
            f.receiver.peerLifecycleBoundaryForTesting = {
                if $0 == boundary { throw TractandaError("injectedLifecycleFailure", "simulated crash") }
            }
            code("injectedLifecycleFailure") {
                try f.receiver.removePeerIntake(
                    peerID: f.context.peerID, retiredOriginIDs: [f.origin],
                    operationID: operation)
            }
            f.receiver = nil
            f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
            XCTAssertEqual(try f.receiver.get(f.base.itemID), f.base)
            XCTAssertTrue(try configuration(f).peers.isEmpty)
            let before = try canonical(f.receiverRoot)
            try f.receiver.removePeerIntake(
                peerID: f.context.peerID, retiredOriginIDs: [f.origin],
                operationID: operation)
            XCTAssertEqual(try canonical(f.receiverRoot), before)
            XCTAssertEqual(try configuration(f).lifecycle?.retirements.count, 1)
            try f.capacity()
        }
    }
    func testRetirementRejectsUnknownOriginsAndMissingCanonicalRootFailsClosed() throws {
        let f = try Fixture()
        try f.bootstrap()
        code("invalidPeerLifecycle") {
            try f.receiver.removePeerIntake(
                peerID: f.context.peerID, retiredOriginIDs: [Fixture.id()], operationID: Fixture.id())
        }
        try f.receiver.removePeerIntake(
            peerID: f.context.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())
        let activation = try XCTUnwrap(configuration(f).lifecycle?.retirements.first)
        f.receiver = nil
        try FileManager.default.removeItem(at: f.receiverRoot.appendingPathComponent("index"))
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(f.base.itemID), f.base)
        let original = try XCTUnwrap(
            try canonical(f.receiverRoot).keys.first { $0.hasSuffix(activation.root.recordID + ".authority") }
        )
        f.receiver = nil
        try FileManager.default.removeItem(atPath: original)
        XCTAssertThrowsError(try Fixture.open(f.receiverRoot, f.receiverAccounts))
    }

    func testPreparedReservationCannotBeOvertakenByPeerAdditionOrBootstrapPin() throws {
        let f = try Fixture()
        try f.bootstrap()
        let pin = try XCTUnwrap(configuration(f).bootstrap)
        let updated = try rotated(f.context, "reserved rotation")
        let operation = try Fixture.id()
        f.receiver.peerLifecycleBoundaryForTesting = { boundary in
            if boundary == .prepared { throw TractandaError("injectedLifecycleFailure", "prepared") }
        }
        code("injectedLifecycleFailure") {
            try f.receiver.rotatePeerIntakeCredential(
                peerID: f.context.peerID, replacement: updated,
                operationID: operation)
        }
        f.receiver.peerLifecycleBoundaryForTesting = nil
        let additional = try PeerPackage.Context(
            peerID: "other", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("other credential".utf8)),
            permittedOrigins: [f.origin])
        code("peerLifecycleRecoveryRequired") {
            try f.receiver.configurePeerIntake(peers: [f.context, additional])
        }
        XCTAssertThrowsError(
            try f.receiver.pinAuthorityBootstrap(
                rootID: pin.recordID,
                sha256: pin.sha256, expectedContextToken: f.receiver.peerIntakeContextToken()))
        try f.receiver.rotatePeerIntakeCredential(
            peerID: f.context.peerID, replacement: updated,
            operationID: operation)
        XCTAssertEqual(try f.receiver.peerIntakeContext(peerID: updated.peerID), updated)
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.peerIntakeContext(peerID: updated.peerID), updated)
        XCTAssertEqual(try f.receiver.get(f.base.itemID), f.base)
        try f.capacity()
    }
    func testHeldOriginalCanBeExplicitlyReviewedAfterItsLastCredentialEndpointIsRemoved() throws {
        let f = try Fixture()
        try f.bootstrap()
        let held = try f.edit(uid: f.sourceAccounts.bob)
        let objects = try f.source.peerMetadataObjects(revisionID: held.revisionID)
        let testimony = try XCTUnwrap(objects.first { Fixture.isEvidence($0, for: held.revisionID) })
        let evidence = try AuthorityBinding(recordID: testimony.0.id, sha256: testimony.0.sha256)
        f.receiverAccounts.bobHasGroup = false
        XCTAssertEqual(try f.send(f.packet(objects)).held, 1)
        try f.receiver.removePeerIntake(
            peerID: f.context.peerID, retiredOriginIDs: [f.origin],
            operationID: Fixture.id())
        let relay = try PeerPackage.Context(
            peerID: "review-relay", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("review relay".utf8)),
            permittedOrigins: [f.origin])
        try f.receiver.configurePeerIntake(peers: [relay])
        XCTAssertEqual(try f.send(f.packet(objects), context: relay).accepted, 0)
        code("notFound") { _ = try f.receiver.get(held.itemID, revisionID: held.revisionID) }
        // Removing the temporary alternate route again still leaves exact retained proof reviewable.
        try f.receiver.removePeerIntake(peerID: relay.peerID, retiredOriginIDs: [], operationID: Fixture.id())
        let state = try f.receiver.prepareAuthorityReview(
            itemID: held.itemID,
            revisionID: held.revisionID, evidence: evidence)
        let request = try AuthorityStore.ReviewRequest(
            itemID: held.itemID, revisionID: held.revisionID,
            evidence: evidence, expectedStateToken: state.stateToken,
            reviewedFrontier: state.decisionFrontier, reviewedControlHolds: state.controlHolds,
            changes: ["subject": .text("fresh explicit administrator review")], unset: [],
            operationID: Fixture.id())
        let result = try f.receiver.resolveAuthorityReview(request)
        XCTAssertEqual(result.disposition, .approved)
        XCTAssertEqual(try f.receiver.get(held.itemID).revisionID, result.revision.revisionID)
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(held.itemID).revisionID, result.revision.revisionID)
        XCTAssertTrue(try f.receiver.resolveAuthorityReview(request).wasReplayed)
        try f.capacity()
        let decisionPath = try XCTUnwrap(
            try canonical(f.receiverRoot).keys.first {
                $0.hasSuffix(result.decision.recordID + ".authority")
            })
        f.receiver = nil
        try FileManager.default.removeItem(atPath: decisionPath)
        try FileManager.default.removeItem(at: f.receiverRoot.appendingPathComponent("index"))
        XCTAssertThrowsError(
            try Fixture.open(f.receiverRoot, f.receiverAccounts),
            "Missing LOCAL review D must never let C bypass strict recovery closure.")
    }
    func testForeignRetirementStaysHeldAndRaisesReaderBeforeCanonicalRetention() throws {
        let f = try Fixture()
        try f.bootstrap()
        let page = try AuthorityRecord(
            recordID: Fixture.id(), storeID: f.storeID,
            originReplicaID: f.origin, kind: .originRetirementPage, actorPrincipal: "admin",
            createdAt: Timestamp.now(),
            payload: [
                "operationID": .text(Fixture.id()),
                "previous": .list([]), "members": .list([]),
            ])
        let bytes = try AuthorityRecordCodec.encode(page)
        let packet = try f.packet([
            (
                .init(
                    kind: .authority, id: page.recordID,
                    length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes)), bytes
            )
        ])
        let before = try f.receiver.get(f.base.itemID)
        _ = try f.send(packet)
        XCTAssertEqual(try f.receiver.get(f.base.itemID), before)
        XCTAssertNil(try configuration(f).lifecycle)
        let requirement = try XCTUnwrap(
            CanonicalReaderRequirement.load(
                root: f.receiverRoot,
                ownerUID: tractanda_uid()))
        XCTAssertEqual(requirement.minimumReaderLevel, 11)
        XCTAssertTrue(requirement.capabilities.contains(PeerLifecycle.capability))
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(f.base.itemID), before)
        try f.capacity()
    }

    func testRetirementRootBindsExactlyItsOwnUUIDIssuanceTime() throws {
        let f = try Fixture()
        try f.bootstrap()
        try f.receiver.removePeerIntake(
            peerID: f.context.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())
        let activation = try XCTUnwrap(configuration(f).lifecycle?.retirements.last)
        let coordinator = PeerIntakeCoordinator(
            root: f.receiverRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let root = try coordinator.lifecycleRecord(activation.root).record
        XCTAssertEqual(
            root.payload["effectiveAt"]?.dateString,
            try UUIDVersion1Components(XCTUnwrap(UUID(uuidString: root.recordID))).timestampUTC)
        XCTAssertNil(root.payload["pages"])
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(f.base.itemID), f.base)
        try f.capacity()
    }

}
