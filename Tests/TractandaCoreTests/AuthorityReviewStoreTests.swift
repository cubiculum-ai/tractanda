import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class AuthorityReviewStoreTests: XCTestCase {
    struct ReviewedFixture {
        let base: PeerIntakeStoreTests.Fixture
        let held: Revision
        let evidence: AuthorityBinding
        let reconciliation: Revision
        let descendant: Revision?
        init(withDescendant: Bool = false) throws {
            let f = try PeerIntakeStoreTests.Fixture()
            try f.bootstrap()
            let b = try f.receiver.withAccess(forUID: f.receiverAccounts.bob) {
                let parent = try f.receiver.get(f.base.itemID)
                return try f.receiver.commit(
                    .init(
                        action: .revise, itemID: parent.itemID,
                        expectedRevisionID: parent.revisionID, changes: ["subject": .text("held original")],
                        operationID: "review-held-" + PeerIntakeStoreTests.Fixture.id())
                ).revision
            }
            held = b
            let objects = try f.receiver.peerMetadataObjects(revisionID: b.revisionID)
            let raw = try XCTUnwrap(
                objects.first { PeerIntakeStoreTests.Fixture.isEvidence($0, for: b.revisionID) })
            evidence = try .init(recordID: raw.0.id, sha256: raw.0.sha256)
            if withDescendant {
                descendant = try f.receiver.withAccess(forUID: f.receiverAccounts.bob) {
                    try f.receiver.commit(
                        .init(
                            action: .revise, itemID: b.itemID, expectedRevisionID: b.revisionID,
                            changes: ["body": .text("unreviewed descendant")], operationID: "held-child")
                    ).revision
                }
            } else {
                descendant = nil
            }
            let r = try f.source.configureAccess(
                .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("admin"), .text("alice")]),
                ]), operationID: "review-revoke-" + PeerIntakeStoreTests.Fixture.id()
            ).revision
            _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: r.revisionID)))
            reconciliation = try f.receiver.get(b.itemID)
            XCTAssertEqual(try reconciliation.provenance?.mergeProfile, AuthorityStore.reconciliationProfile)
            base = f
        }
        func request(subject: String = "explicit reviewed subject", operation: String = "review-op") throws
            -> AuthorityStore.ReviewRequest
        {
            let state = try base.receiver.prepareAuthorityReview(
                itemID: held.itemID, revisionID: held.revisionID, evidence: evidence)
            return .init(
                itemID: held.itemID, revisionID: held.revisionID, evidence: evidence,
                expectedStateToken: state.stateToken, reviewedFrontier: state.decisionFrontier,
                reviewedControlHolds: state.controlHolds, changes: ["subject": .text(subject)], unset: [],
                operationID: operation)
        }
    }
    func testAtomicReviewAfterDemotionAdoptsOnlyNamedOriginalAndInstallsFreshResolution() throws {
        let f = try ReviewedFixture()
        let request = try f.request()
        let result = try f.base.receiver.resolveAuthorityReview(request)
        XCTAssertFalse(result.wasReplayed)
        XCTAssertEqual(result.disposition, .approved)
        XCTAssertEqual(result.revision.fields["subject"], .text("explicit reviewed subject"))
        XCTAssertEqual(try result.revision.provenance?.kind, .resolution)
        XCTAssertTrue(try result.revision.provenance!.parents.contains(f.held.revisionID))
        XCTAssertGreaterThan(
            try RevisionTimestamp(result.revision.modifiedAt),
            try RevisionTimestamp(f.reconciliation.modifiedAt))
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, result.revision.revisionID)
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID, revisionID: f.held.revisionID), f.held)
        let replay = try f.base.receiver.resolveAuthorityReview(request)
        XCTAssertTrue(replay.wasReplayed)
        XCTAssertEqual(replay.revision, result.revision)
        XCTAssertEqual(replay.current.representativeRevisionID, result.revision.revisionID)
        try f.base.receiver.rebuildIndex()
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, result.revision.revisionID)
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID, revisionID: f.held.revisionID), f.held)
        f.base.receiver = nil
        f.base.receiver = try PeerIntakeStoreTests.Fixture.open(f.base.receiverRoot, f.base.receiverAccounts)
        let restarted = try f.base.receiver.resolveAuthorityReview(request)
        XCTAssertTrue(restarted.wasReplayed)
        XCTAssertEqual(restarted.revision, result.revision)
        try f.base.capacity()
    }

    private func reservedIdentity(_ f: ReviewedFixture) throws -> AuthorityStore.ReviewIdentity {
        let directory = f.base.receiverRoot.appendingPathComponent("authority/local-review-identities")
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 1)
        return try JSON.decode(AuthorityStore.ReviewIdentity.self, Data(contentsOf: XCTUnwrap(entries.first)))
    }
    private func canonicalIDs(_ f: ReviewedFixture) throws -> Set<String> {
        try f.base.capacity()
        let values = try XCTUnwrap(
            FileManager.default.enumerator(at: f.base.receiverRoot, includingPropertiesForKeys: nil))
        var result: Set<String> = []
        for case let url as URL in values
        where url.pathExtension == "authority" || url.pathExtension == "tractanda" {
            result.insert(url.path + ":" + AuthorityRecordCodec.sha256(try Data(contentsOf: url)))
        }
        return result
    }
    func testPreSealFailuresRetryTheSameReservedManifestWithoutAdmittingB() throws {
        for phase in [PeerIntakeJournal.Boundary.began, .chunk, .prepared] {
            let f = try ReviewedFixture()
            let request = try f.request()
            var stopped = false
            f.base.receiver.peerIntakeBoundaryForTesting = { boundary in
                if boundary == phase && !stopped {
                    stopped = true
                    throw TractandaError("injected", "prepared")
                }
            }
            XCTAssertThrowsError(try f.base.receiver.resolveAuthorityReview(request))
            let identity = try reservedIdentity(f)
            XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, f.reconciliation.revisionID)
            XCTAssertEqual(
                try f.base.receiver.historicalDispositions(for: [f.held]), [f.held.revisionID: .demoted])
            f.base.receiver.peerIntakeBoundaryForTesting = nil
            let result = try f.base.receiver.resolveAuthorityReview(request)
            XCTAssertEqual(result.revision.revisionID, identity.revisionID)
            XCTAssertEqual(result.revision.modifiedAt, identity.modifiedAt)
        }
    }
    func testSealedAndAppliedFailuresRecoverReservedBytesAndQuiesce() throws {
        for phase in ["sealed", "original", "applied"] {
            let f = try ReviewedFixture()
            let request = try f.request()
            var stopped = false
            f.base.receiver.peerIntakeBoundaryForTesting = { current in
                if current.rawValue == phase && !stopped {
                    stopped = true
                    throw TractandaError("injected", current.rawValue)
                }
            }
            var published = 0
            f.base.receiver.peerIntakeOriginalPublicationForTesting = {
                published += 1
                if phase == "original" && published == 2 && !stopped {
                    stopped = true
                    throw TractandaError("injected", "mid original publication")
                }
            }
            XCTAssertThrowsError(try f.base.receiver.resolveAuthorityReview(request))
            XCTAssertTrue(stopped)
            XCTAssertTrue(StoreCheckpoint.isDirty(root: f.base.receiverRoot))
            let identity = try reservedIdentity(f)
            let draft = try Data(
                contentsOf: f.base.receiverRoot.appendingPathComponent(
                    "authority/review-drafts/" + identity.revisionID + ".tractanda"))
            f.base.receiver = nil
            f.base.receiver = try PeerIntakeStoreTests.Fixture.open(
                f.base.receiverRoot, f.base.receiverAccounts)
            let replay = try f.base.receiver.resolveAuthorityReview(request)
            XCTAssertTrue(replay.wasReplayed)
            XCTAssertEqual(replay.revision.revisionID, identity.revisionID)
            XCTAssertEqual(replay.revision.modifiedAt, identity.modifiedAt)
            XCTAssertEqual(replay.current.representativeRevisionID, identity.revisionID)
            XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, identity.revisionID)
            XCTAssertEqual(
                try f.base.receiver.get(f.held.itemID).fields["subject"], .text("explicit reviewed subject"))
            XCTAssertEqual(try RecordCodec.encode(replay.revision), draft)
            let before = try canonicalIDs(f)
            f.base.receiver = nil
            f.base.receiver = try PeerIntakeStoreTests.Fixture.open(
                f.base.receiverRoot, f.base.receiverAccounts)
            _ = try f.base.receiver.resolveAuthorityReview(request)
            let after = try canonicalIDs(f)
            if after != before {
                let additions = try after.subtracting(before).sorted().map { entry -> String in
                    let path = String(entry.split(separator: ":")[0])
                    if path.hasSuffix(".authority") {
                        let r = try AuthorityRecordCodec.decode(Data(contentsOf: URL(fileURLWithPath: path)))
                            .record
                        return r.kind.rawValue + " " + r.recordID
                    }
                    let r = try RecordCodec.decode(Data(contentsOf: URL(fileURLWithPath: path)))
                    return "item " + r.itemID + " " + r.revisionID + " kind="
                        + String(describing: try r.provenance?.kind) + " profile="
                        + String(describing: try r.provenance?.mergeProfile) + " parents="
                        + String(describing: try r.provenance?.parents) + " modified=" + r.modifiedAt
                        + " subject=" + String(describing: r.fields["subject"]) + " expectedC="
                        + replay.revision.revisionID + " expectedItem=" + f.held.itemID
                }
                XCTFail(
                    "Warm reopen added canonical outputs at " + phase + ": "
                        + additions.joined(separator: "\n"))
            }
        }
    }
    func testNamedOriginalApprovalDoesNotApproveItsPreviouslyHeldDescendant() throws {
        let f = try ReviewedFixture(withDescendant: true)
        let descendant = try XCTUnwrap(f.descendant)
        let c = try f.base.receiver.resolveAuthorityReview(f.request()).revision
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, c.revisionID)
        XCTAssertFalse(try c.provenance!.parents.contains(descendant.revisionID))
        XCTAssertEqual(
            try f.base.receiver.historicalDispositions(for: [descendant]), [descendant.revisionID: .demoted])
        try f.base.receiver.rebuildIndex()
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, c.revisionID)
        XCTAssertEqual(
            try f.base.receiver.historicalDispositions(for: [descendant]), [descendant.revisionID: .demoted])
    }
    func testProtectedGrantMustBeExplicitAndUsesPreReviewPolicy() throws {
        for freshGrant in [false, true] {
            let f = try PeerIntakeStoreTests.Fixture()
            try f.bootstrap()
            var permission = try XCTUnwrap(f.base.fields["permissions"]?.map)
            permission["mode"] = .integer(0o666)
            let grant = ItemValue.object(permission)
            let b = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.commit(
                    .init(
                        action: .revise, itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
                        changes: ["permissions": grant], operationID: "stale-grant")
                ).revision
            }
            let objects = try f.receiver.peerMetadataObjects(revisionID: b.revisionID)
            let raw = try XCTUnwrap(
                objects.first { PeerIntakeStoreTests.Fixture.isEvidence($0, for: b.revisionID) })
            let evidence = try AuthorityBinding(recordID: raw.0.id, sha256: raw.0.sha256)
            let r = try f.source.configureAccess(
                .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("admin"), .text("bob")]),
                ]), operationID: "revoke-alice"
            ).revision
            _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: r.revisionID)))
            let state = try f.receiver.prepareAuthorityReview(
                itemID: b.itemID, revisionID: b.revisionID, evidence: evidence)
            func request(_ changes: [String: ItemValue], _ op: String) -> AuthorityStore.ReviewRequest {
                .init(
                    itemID: b.itemID, revisionID: b.revisionID, evidence: evidence,
                    expectedStateToken: state.stateToken,
                    reviewedFrontier: state.decisionFrontier, reviewedControlHolds: state.controlHolds,
                    changes: changes, unset: [], operationID: op)
            }
            XCTAssertThrowsError(
                try f.receiver.resolveAuthorityReview(
                    request(["subject": .text("implicit grant forbidden")], "no-choice")))
            let chosen = freshGrant ? grant : f.base.fields["permissions"]!
            let c = try f.receiver.resolveAuthorityReview(request(["permissions": chosen], "explicit-choice"))
                .revision
            XCTAssertEqual(c.fields["permissions"], chosen)
            XCTAssertEqual(try f.receiver.get(b.itemID, revisionID: b.revisionID), b)
            let closure = try f.receiver.peerMetadataObjects(revisionID: c.revisionID)
            let cEvidence = try AuthorityRecordCodec.decode(
                XCTUnwrap(closure.first { PeerIntakeStoreTests.Fixture.isEvidence($0, for: c.revisionID) }).1
            ).record
            XCTAssertEqual(
                try AuthorityRecord.list(cEvidence.payload["itemPolicies"]).map {
                    try AuthorityRecord.binding($0).revisionID
                }, [f.base.revisionID])
            XCTAssertFalse(
                try AuthorityRecord.list(cEvidence.payload["itemPolicies"]).contains {
                    try AuthorityRecord.binding($0).revisionID == b.revisionID
                })
            try f.receiver.rebuildIndex()
            XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, c.revisionID)
            try f.capacity()
        }
    }

    func testReviewedRevokeOrUnsetThenRegrantDoesNotAuthorizeUnseenOfflineOriginal() throws {
        for unsetPermissions in [false, true] {
            var identities: [String: String] = [:]
            let f = try PeerIntakeStoreTests.Fixture()
            func stage<T>(_ name: String, _ body: () throws -> T) throws -> T {
                do { return try body() } catch let error as TractandaError {
                    throw TractandaError(
                        error.code,
                        "[review policy stage=" + name + " nil=" + String(unsetPermissions) + "] "
                            + error.message + " identities=" + String(describing: identities),
                        osError: error.osError)
                }
            }
            try f.bootstrap()
            // Three tiny roots are estimated at24MiB, beneath the fixture's32MiB cap.
            XCTAssertLessThanOrEqual(24 * 1024 * 1024, Int(AttachmentFixtureCapacity.fixtureCapBytes))
            try AttachmentFixtureCapacity.requireFree(at: f.directory)
            let thirdRoot = f.directory.appendingPathComponent("starlet")
            let thirdAccounts = PeerIntakeStoreTests.Accounts()
            var third: ItemStore! = try ItemStore(
                root: thirdRoot, accounts: thirdAccounts, revisionProjectionEnabled: true)
            guard try third.exportCatalogueForVerification().isEmpty else {
                throw TractandaError("fixture", "Join requires an empty fixture")
            }
            third = nil
            try FileManager.default.removeItem(at: thirdRoot.appendingPathComponent("index"))
            let storeIdentity = try Data(
                contentsOf: f.sourceRoot.appendingPathComponent(".tractanda-store-identity.json"))
            try storeIdentity.write(
                to: thirdRoot.appendingPathComponent(".tractanda-store-identity.json"), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: thirdRoot.appendingPathComponent(".tractanda-store-identity.json").path)
            third = try PeerIntakeStoreTests.Fixture.open(thirdRoot, thirdAccounts)
            defer { third = nil }
            let origins = [f.origin, try XCTUnwrap(f.receiver.replicaID), try XCTUnwrap(third.replicaID)]
                .sorted()
            func peer(_ name: String) throws -> PeerPackage.Context {
                try .init(
                    peerID: name, storeID: f.storeID,
                    configurationDigest: AuthorityRecordCodec.sha256(Data((name + "-review-three").utf8)),
                    permittedOrigins: origins)
            }
            let previous = f.context!
            f.context = try peer("raven-three")
            let starlet = try peer("starlet")
            let stash = try peer("stash")
            try f.receiver.configurePeerIntake(peers: [previous, f.context, starlet])
            try third.configurePeerIntake(peers: [f.context, stash])
            try f.bootstrap(to: third)
            let x = try third.withAccess(forUID: thirdAccounts.bob) {
                try third.commit(
                    .init(
                        action: .revise, itemID: f.base.itemID,
                        expectedRevisionID: f.base.revisionID,
                        changes: ["body": .text("unseen offline body")], operationID: "unseen-x")
                ).revision
            }
            identities["A"] = f.base.revisionID
            identities["X"] = x.revisionID
            let xPacket = try f.packet(third.peerMetadataObjects(revisionID: x.revisionID))
            var proposed = try XCTUnwrap(f.base.fields["permissions"]?.map)
            proposed["mode"] = .integer(0o666)
            let b = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.commit(
                    .init(
                        action: .revise, itemID: f.base.itemID,
                        expectedRevisionID: f.base.revisionID, changes: ["permissions": .object(proposed)],
                        operationID: "held-grant")
                ).revision
            }
            identities["B"] = b.revisionID
            let bObjects = try f.receiver.peerMetadataObjects(revisionID: b.revisionID)
            let raw = try XCTUnwrap(
                bObjects.first { PeerIntakeStoreTests.Fixture.isEvidence($0, for: b.revisionID) })
            let evidence = try AuthorityBinding(recordID: raw.0.id, sha256: raw.0.sha256)
            let r = try f.source.configureAccess(
                .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("admin"), .text("bob")]),
                ]), operationID: "review-revoke-alice"
            ).revision
            _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: r.revisionID)))
            identities["oldD"] = try f.receiver.get(b.itemID).revisionID
            let state = try f.receiver.prepareAuthorityReview(
                itemID: b.itemID, revisionID: b.revisionID, evidence: evidence)
            var revoked = try XCTUnwrap(f.base.fields["permissions"]?.map)
            revoked["mode"] = .integer(0o600)
            let request = AuthorityStore.ReviewRequest(
                itemID: b.itemID, revisionID: b.revisionID, evidence: evidence,
                expectedStateToken: state.stateToken, reviewedFrontier: state.decisionFrontier,
                reviewedControlHolds: state.controlHolds,
                changes: unsetPermissions ? [:] : ["permissions": .object(revoked)],
                unset: unsetPermissions ? ["permissions"] : [], operationID: "explicit-revocation")
            let c = try stage("review") { try f.receiver.resolveAuthorityReview(request).revision }
            identities["C"] = c.revisionID
            XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, c.revisionID)
            XCTAssertEqual(try f.receiver.get(b.itemID, revisionID: b.revisionID), b)
            XCTAssertTrue(
                try f.receiver.historicalDispositions(for: [b]).isEmpty,
                "This exact atomic C revocation must not undo named B's historical adoption.")
            if unsetPermissions { XCTAssertNil(c.fields["permissions"]) }
            let g = try stage("grant") {
                try f.receiver.commit(
                    .init(
                        action: .revise, itemID: b.itemID,
                        expectedRevisionID: c.revisionID,
                        changes: ["permissions": f.base.fields["permissions"]!],
                        operationID: "later-regrant")
                ).revision
            }
            identities["G"] = g.revisionID
            let received = try stage("late intake") { try f.send(xPacket, context: starlet) }
            XCTAssertEqual(received.accepted, 0)
            XCTAssertEqual(received.held, 1)
            XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, g.revisionID)
            XCTAssertNotEqual(try f.receiver.get(b.itemID).fields["body"], .text("unseen offline body"))
            try stage("rebuild") { try f.receiver.rebuildIndex() }
            let rebuilt = try f.receiver.get(b.itemID)
            XCTAssertEqual(rebuilt.revisionID, g.revisionID)
            _ = try stage("late retry") { try f.send(xPacket, context: starlet) }
            XCTAssertEqual(try f.receiver.get(b.itemID).revisionID, g.revisionID)
            try f.capacity()
        }
    }
}
