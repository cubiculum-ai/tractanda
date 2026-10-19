import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class SourceAdministrationEmissionTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 51001
        let bob: UInt32 = 51002
        let staff: UInt32 = 71001
        let administrators: UInt32 = 71002
        let ownerIsAdministrator: Bool
        var administratorAliasIsAligned = true

        init(ownerIsAdministrator: Bool = true) {
            self.ownerIsAdministrator = ownerIsAdministrator
        }

        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            switch uid {
            case tractanda_uid(): name = "admin"
            case alice: name = "alice"
            case bob: name = "bob"
            default: throw TractandaError("unresolvedPrincipal", "Unknown test account")
            }
            let groups: [UInt32] =
                uid == tractanda_uid()
                ? (ownerIsAdministrator ? [administrators] : [staff]) : [staff]
            return .init(uid: uid, name: name, primaryGroupName: "staff", groupIDs: Set(groups))
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
            if name == "staff" { return staff }
            if name == AccessConfiguration.defaultAdministratorGroup {
                return administratorAliasIsAligned ? staff : administrators
            }
            throw TractandaError("unresolvedPrincipal", "Unknown test group")
        }
    }

    private struct Scenario {
        let fixture: PeerIntakeStoreTests.Fixture
        let accounts: Accounts
        let policy: ItemValue

        init(ownerIsAdministrator: Bool = true) throws {
            try AttachmentFixtureCapacity.requireFree()
            fixture = try PeerIntakeStoreTests.Fixture()
            accounts = Accounts(ownerIsAdministrator: ownerIsAdministrator)
            fixture.source = nil
            fixture.source = try ItemStore(
                root: fixture.sourceRoot, accounts: accounts,
                revisionProjectionEnabled: true, authorityIntakeEnabled: true)
            fixture.receiver = nil
            fixture.receiver = try ItemStore(
                root: fixture.receiverRoot, accounts: accounts,
                revisionProjectionEnabled: true, authorityIntakeEnabled: true)
            policy = Self.policy(users: ["admin", "alice", "bob"])
        }

        static var administratorGroup: String { AccessConfiguration.defaultAdministratorGroup }

        static func policy(users: [String]) -> ItemValue {
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list(users.map(ItemValue.text)),
                "administration": .text("serviceOwner"),
                "groupAliases": .object([administratorGroup: .text("staff")]),
            ])
        }

        func configure(_ users: [String], operation: String) throws -> Revision {
            let revision = try fixture.source.configureAccess(
                Self.policy(users: users), operationID: operation
            )
            .revision
            try fixture.capacity()
            return revision
        }

        func evidence(in store: ItemStore, for revision: Revision) throws -> AuthorityRecord {
            let objects = try store.peerMetadataObjects(revisionID: revision.revisionID)
            let pair = try XCTUnwrap(
                objects.first {
                    guard $0.0.kind == .authority,
                        let record = try? AuthorityRecordCodec.decode($0.1).record,
                        record.kind == .authoredEvidence,
                        let target = try? AuthorityRecord.binding(record.payload["target"])
                    else { return false }
                    return target.revisionID == revision.revisionID
                })
            return try AuthorityRecordCodec.decode(pair.1).record
        }

    }

    func testOrdinaryEmissionUsesActualAdministratorGroupAcrossAlias() throws {
        let scenario = try Scenario()
        _ = try scenario.configure(["admin", "alice", "bob"], operation: "alias-admin-config")
        scenario.accounts.administratorAliasIsAligned = false
        try scenario.fixture.capacity()
        let revision = try scenario.fixture.source.withAccess(forUID: tractanda_uid()) {
            let parent = try scenario.fixture.source.get(scenario.fixture.base.itemID)
            return try scenario.fixture.source.commit(
                .init(
                    action: .revise, itemID: parent.itemID, expectedRevisionID: parent.revisionID,
                    changes: ["subject": .text("administrator publication")], operationID: "alias-admin-write"
                )
            ).revision
        }
        try scenario.fixture.capacity()
        let record = try scenario.evidence(in: scenario.fixture.source, for: revision)

        XCTAssertEqual(record.payload["aliases"]?.map?[Scenario.administratorGroup], .text("staff"))
        XCTAssertEqual(record.payload["groups"]?.map?[Scenario.administratorGroup], .integer(71002))
        XCTAssertNil(record.payload["groups"]?.map?["staff"])
        XCTAssertEqual(
            record.payload["sourceAdministration"]?.map?["defaultAdministratorGroup"],
            .text(Scenario.administratorGroup))
    }

    func testStaffMembershipAliasCannotCreateSystemAdministratorTestimony() throws {
        let scenario = try Scenario(ownerIsAdministrator: false)
        _ = try scenario.configure(["admin", "alice", "bob"], operation: "staff-alias-config")
        scenario.accounts.administratorAliasIsAligned = false
        let revision = try scenario.fixture.source.withAccess(forUID: tractanda_uid()) {
            let parent = try scenario.fixture.source.get(scenario.fixture.base.itemID)
            return try scenario.fixture.source.commit(
                .init(
                    action: .revise, itemID: parent.itemID,
                    expectedRevisionID: parent.revisionID, changes: ["body": .text("staff-only owner")],
                    operationID: "staff-only-emission")
            ).revision
        }
        let record = try scenario.evidence(in: scenario.fixture.source, for: revision)
        let policy = try AccessConfiguration(
            .object([
                "profile": .text(AccessConfiguration.profile), "administration": .text("system"),
                "administratorGroup": .text(Scenario.administratorGroup),
                "groupAliases": .object([Scenario.administratorGroup: .text("staff")]),
            ]))

        XCTAssertEqual(record.payload["groups"]?.map?["staff"], .integer(Int64(scenario.accounts.staff)))
        XCTAssertNil(record.payload["groups"]?.map?[Scenario.administratorGroup])
        XCTAssertEqual(policy.groupAliases[Scenario.administratorGroup], "staff")
        XCTAssertGreaterThan(try XCTUnwrap(record.payload["sourceUID"]?.integerValue), 0)
        XCTAssertFalse(try SourceAdministration.administrator(policy, evidence: record))
    }

    func testProtectedReviewEmissionUsesActualAdministratorGroupAcrossAlias() throws {
        let scenario = try Scenario()
        _ = try scenario.configure(["admin", "alice", "bob"], operation: "review-alias-config")
        try scenario.fixture.bootstrap()

        let held = try scenario.fixture.receiver.withAccess(forUID: scenario.accounts.bob) {
            let parent = try scenario.fixture.receiver.get(scenario.fixture.base.itemID)
            return try scenario.fixture.receiver.commit(
                .init(
                    action: .revise, itemID: parent.itemID, expectedRevisionID: parent.revisionID,
                    changes: ["subject": .text("held by policy change")], operationID: "review-held-alias"
                )
            ).revision
        }
        try scenario.fixture.capacity()
        let evidenceObject = try XCTUnwrap(
            try scenario.fixture.receiver.peerMetadataObjects(revisionID: held.revisionID).first {
                PeerIntakeStoreTests.Fixture.isEvidence($0, for: held.revisionID)
            })
        let binding = try AuthorityBinding(recordID: evidenceObject.0.id, sha256: evidenceObject.0.sha256)
        let revoked = try scenario.configure(["admin", "alice"], operation: "review-alias-revoke")
        _ = try scenario.fixture.send(
            scenario.fixture.packet(
                scenario.fixture.source.peerMetadataObjects(revisionID: revoked.revisionID)))

        scenario.accounts.administratorAliasIsAligned = false
        let state = try scenario.fixture.receiver.prepareAuthorityReview(
            itemID: held.itemID, revisionID: held.revisionID, evidence: binding)
        let result = try scenario.fixture.receiver.resolveAuthorityReview(
            .init(
                itemID: held.itemID, revisionID: held.revisionID, evidence: binding,
                expectedStateToken: state.stateToken, reviewedFrontier: state.decisionFrontier,
                reviewedControlHolds: state.controlHolds,
                changes: ["subject": .text("reviewed subject")], unset: [],
                operationID: "review-alias-approve",
                reviewedRetirements: state.retirements))
        try scenario.fixture.capacity()
        let record = try scenario.evidence(in: scenario.fixture.receiver, for: result.revision)

        XCTAssertEqual(record.payload["aliases"]?.map?[Scenario.administratorGroup], .text("staff"))
        XCTAssertEqual(record.payload["groups"]?.map?[Scenario.administratorGroup], .integer(71002))
        XCTAssertNil(record.payload["groups"]?.map?["staff"])
        XCTAssertEqual(
            record.payload["sourceAdministration"]?.map?["defaultAdministratorGroup"],
            .text(Scenario.administratorGroup))
    }
}
