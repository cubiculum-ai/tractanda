import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class AuthorityReviewDenialTests: XCTestCase {
    private typealias Fixture = AuthorityReviewStoreTests.ReviewedFixture

    private final class DynamicReviewDirectory: AccountDirectory {
        let alice: UInt32 = 51_001
        let bob: UInt32 = 51_002
        let staff: UInt32 = 71_001
        let reviewers: UInt32 = 71_002
        var aliceIsReviewer = true
        var staffResolvable = true

        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            let groups: Set<UInt32>
            if uid == tractanda_uid() {
                name = "admin"
                groups = []
            } else if uid == alice {
                name = "alice"
                groups = aliceIsReviewer ? [reviewers] : []
            } else if uid == bob {
                name = "bob"
                groups = [staff]
            } else {
                throw TractandaError("unresolvedPrincipal", "Unknown test account")
            }
            return AccountIdentity(uid: uid, name: name, primaryGroupName: "staff", groupIDs: groups)
        }

        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": try user(forUID: tractanda_uid())
            case "alice": try user(forUID: alice)
            case "bob": try user(forUID: bob)
            default: throw TractandaError("unresolvedPrincipal", "Unknown test account")
            }
        }

        func groupID(named name: String) throws -> UInt32 {
            switch name {
            case "staff":
                guard staffResolvable else {
                    throw TractandaError("unresolvedPrincipal", "The test staff group disappeared.")
                }
                return staff
            case "reviewers": return reviewers
            default: throw TractandaError("unresolvedPrincipal", "Unknown test group")
            }
        }
    }

    private func canonicalRevisionIDs(_ store: ItemStore) throws -> Set<String> {
        Set(try store.exportCatalogueForVerification().map(\.revisionID))
    }

    private func itemBytes(_ fixture: Fixture) throws -> Data {
        let original = try fixture.base.receiver.peerMetadataObjects(revisionID: fixture.held.revisionID)
        return try XCTUnwrap(original.first { $0.0.kind == .item && $0.0.id == fixture.held.revisionID }?.1)
    }

    private func assertNoCanonicalPublication(
        _ fixture: Fixture, revisionIDs: Set<String>, original: Data,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(try canonicalRevisionIDs(fixture.base.receiver), revisionIDs, file: file, line: line)
        XCTAssertEqual(try itemBytes(fixture), original, file: file, line: line)
    }

    private func assertCode(
        _ expected: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }

    func testAdmittedNonAdministratorCannotPrepareReview() throws {
        let f = try Fixture()
        let revisions = try canonicalRevisionIDs(f.base.receiver)
        let original = try itemBytes(f)
        XCTAssertFalse(
            try f.base.receiver.withAccess(forUID: f.base.receiverAccounts.alice) {
                f.base.receiver.isAdministrator
            })

        assertCode("forbidden") {
            _ = try f.base.receiver.withAccess(forUID: f.base.receiverAccounts.alice) {
                try f.base.receiver.prepareAuthorityReview(
                    itemID: f.held.itemID, revisionID: f.held.revisionID,
                    evidence: f.evidence, actorUID: f.base.receiverAccounts.alice)
            }
        }
        try assertNoCanonicalPublication(f, revisionIDs: revisions, original: original)
        try f.base.capacity()
    }

    func testWrongEvidenceBindingAndStaleReviewedTokenCannotPublishResolution() throws {
        let f = try Fixture()
        let revisions = try canonicalRevisionIDs(f.base.receiver)
        let original = try itemBytes(f)
        let wrong = try AuthorityBinding(
            recordID: f.evidence.recordID, sha256: String(repeating: "0", count: 64))
        assertCode("operationReviewRequired") {
            _ = try f.base.receiver.prepareAuthorityReview(
                itemID: f.held.itemID, revisionID: f.held.revisionID, evidence: wrong)
        }

        let valid = try f.request(operation: "stale-state-review")
        let stale = AuthorityStore.ReviewRequest(
            itemID: valid.itemID, revisionID: valid.revisionID, evidence: valid.evidence,
            expectedStateToken: "stale-" + valid.expectedStateToken,
            reviewedFrontier: valid.reviewedFrontier, reviewedControlHolds: valid.reviewedControlHolds,
            changes: valid.changes, unset: valid.unset, operationID: valid.operationID)
        assertCode("stateConflict") { _ = try f.base.receiver.resolveAuthorityReview(stale) }
        try assertNoCanonicalPublication(f, revisionIDs: revisions, original: original)
        try f.base.capacity()
    }

    func testReviewCannotOmitExplicitHeldWrittenFieldChoice() throws {
        let f = try Fixture()
        let state = try f.base.receiver.prepareAuthorityReview(
            itemID: f.held.itemID, revisionID: f.held.revisionID, evidence: f.evidence)
        let revisions = try canonicalRevisionIDs(f.base.receiver)
        let original = try itemBytes(f)
        let incomplete = AuthorityStore.ReviewRequest(
            itemID: f.held.itemID, revisionID: f.held.revisionID, evidence: f.evidence,
            expectedStateToken: state.stateToken, reviewedFrontier: state.decisionFrontier,
            reviewedControlHolds: state.controlHolds, changes: [:], unset: [],
            operationID: "omitted-held-field")

        assertCode("invalidArguments") { _ = try f.base.receiver.resolveAuthorityReview(incomplete) }
        try assertNoCanonicalPublication(f, revisionIDs: revisions, original: original)
        try f.base.capacity()
    }

    func testUnresolvedPermissionGroupAfterPreviewPreventsCanonicalPublication() throws {
        let f = try Fixture()
        f.base.receiver = nil
        let directory = DynamicReviewDirectory()
        // Preserve this explicitly historical fixture's writer format during the directory swap.
        // Default current support would require a separate atomic transition before the tested denial.
        f.base.receiver = try ItemStore(
            root: f.base.receiverRoot, accounts: directory,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true,
            canonicalFormatSupport: PeerIntakeStoreTests.Fixture.historical14Support)
        _ = try f.base.receiver.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice")]),
                "administration": .text("system"), "administratorGroup": .text("reviewers"),
            ]), operationID: "reviewer-group-transition")
        let store = f.base.receiver!
        XCTAssertEqual(
            try store.withAccess(forUID: directory.alice) { store.isAdministrator }, true)
        let prepared = try store.prepareAuthorityReview(
            itemID: f.held.itemID, revisionID: f.held.revisionID,
            evidence: f.evidence, actorUID: directory.alice)
        XCTAssertEqual(prepared.original.revisionID, f.held.revisionID)
        let request = AuthorityStore.ReviewRequest(
            itemID: f.held.itemID, revisionID: f.held.revisionID, evidence: f.evidence,
            expectedStateToken: prepared.stateToken,
            reviewedFrontier: prepared.decisionFrontier, reviewedControlHolds: prepared.controlHolds,
            changes: ["subject": .text("explicit reviewed subject")], unset: [],
            operationID: "administrator-revoked-before-seal")
        let revisions = try canonicalRevisionIDs(store)
        let original = try itemBytes(f)
        store.beforeProjectionCommitAuthorityForTesting = { directory.staffResolvable = false }
        defer { store.beforeProjectionCommitAuthorityForTesting = nil }

        assertCode("unresolvedPrincipal") {
            _ = try store.resolveAuthorityReview(request, actorUID: directory.alice)
        }
        XCTAssertTrue(try store.withAccess(forUID: directory.alice) { store.isAdministrator })
        try assertNoCanonicalPublication(f, revisionIDs: revisions, original: original)
        try f.base.capacity()
    }

    func testAdministratorLossBetweenPreviewAndSealPreventsCanonicalPublication() throws {
        let f = try Fixture()
        f.base.receiver = nil
        let directory = DynamicReviewDirectory()
        // Preserve this explicitly historical fixture's writer format during the directory swap.
        // Default current support would require a separate atomic transition before the tested denial.
        f.base.receiver = try ItemStore(
            root: f.base.receiverRoot, accounts: directory,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true,
            canonicalFormatSupport: PeerIntakeStoreTests.Fixture.historical14Support)
        _ = try f.base.receiver.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice")]),
                "administration": .text("system"), "administratorGroup": .text("reviewers"),
            ]), operationID: "reviewer-group-transition")
        let store = f.base.receiver!
        XCTAssertTrue(try store.withAccess(forUID: directory.alice) { store.isAdministrator })
        let prepared = try store.prepareAuthorityReview(
            itemID: f.held.itemID, revisionID: f.held.revisionID,
            evidence: f.evidence, actorUID: directory.alice)
        XCTAssertEqual(prepared.original.revisionID, f.held.revisionID)
        let request = AuthorityStore.ReviewRequest(
            itemID: f.held.itemID, revisionID: f.held.revisionID, evidence: f.evidence,
            expectedStateToken: prepared.stateToken,
            reviewedFrontier: prepared.decisionFrontier, reviewedControlHolds: prepared.controlHolds,
            changes: ["subject": .text("explicit reviewed subject")], unset: [],
            operationID: "administrator-revoked-before-seal")
        let revisions = try canonicalRevisionIDs(store)
        let original = try itemBytes(f)
        store.beforeProjectionCommitAuthorityForTesting = { directory.aliceIsReviewer = false }
        defer { store.beforeProjectionCommitAuthorityForTesting = nil }

        assertCode("forbidden") {
            _ = try store.resolveAuthorityReview(request, actorUID: directory.alice)
        }
        XCTAssertFalse(try store.withAccess(forUID: directory.alice) { store.isAdministrator })
        try assertNoCanonicalPublication(f, revisionIDs: revisions, original: original)
        try f.base.capacity()
    }
}
