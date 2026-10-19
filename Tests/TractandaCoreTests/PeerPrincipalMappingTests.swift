import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class PeerPrincipalMappingTests: XCTestCase {
    /// Models independent NSS databases. Canonical account and group names match across peers,
    /// while local numeric identifiers can differ or collide with an unrelated local account.
    private final class LocalAccounts: AccountDirectory {
        let aliceUID: UInt32
        let bobUID: UInt32?
        let staffGID: UInt32
        var bobHasStaff = true
        private let unrelatedUIDs: [UInt32: String]

        init(
            aliceUID: UInt32 = 61001, bobUID: UInt32? = 61002, staffGID: UInt32 = 81001,
            unrelatedUIDs: [UInt32: String] = [:]
        ) {
            self.aliceUID = aliceUID
            self.bobUID = bobUID
            self.staffGID = staffGID
            self.unrelatedUIDs = unrelatedUIDs
        }

        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == tractanda_uid() { return identity(uid, name: "admin", groups: []) }
            if uid == aliceUID { return identity(uid, name: "alice", groups: [staffGID]) }
            if let bobUID, uid == bobUID {
                return identity(uid, name: "bob", groups: bobHasStaff ? [staffGID] : [])
            }
            if let name = unrelatedUIDs[uid] { return identity(uid, name: name, groups: []) }
            throw TractandaError("unresolvedPrincipal", "Unknown local fixture account")
        }

        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": return try user(forUID: tractanda_uid())
            case "alice": return try user(forUID: aliceUID)
            case "bob":
                guard let bobUID else {
                    throw TractandaError("unresolvedPrincipal", "The local fixture has no bob account")
                }
                return try user(forUID: bobUID)
            default:
                if let entry = unrelatedUIDs.first(where: { $0.value == name }) {
                    return identity(entry.key, name: name, groups: [])
                }
                throw TractandaError("unresolvedPrincipal", "Unknown local fixture account")
            }
        }

        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown local fixture group")
            }
            return staffGID
        }

        private func identity(_ uid: UInt32, name: String, groups: Set<UInt32>) -> AccountIdentity {
            AccountIdentity(uid: uid, name: name, primaryGroupName: "staff", groupIDs: groups)
        }
    }

    private func useReceiver(_ fixture: PeerIntakeStoreTests.Fixture, accounts: LocalAccounts) throws {
        fixture.receiver = nil
        try fixture.capacity()
        fixture.receiver = try ItemStore(
            root: fixture.receiverRoot, accounts: accounts,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true)
        try fixture.receiver.configurePeerIntake(peers: [fixture.context])
        try fixture.capacity()
    }

    func testSameCanonicalNamesMapAcrossDifferentSourceAndReceiverUIDsAndGIDs() throws {
        let fixture = try PeerIntakeStoreTests.Fixture()
        defer {
            fixture.receiver = nil
            fixture.source = nil
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let accounts = LocalAccounts()
        XCTAssertNotEqual(fixture.sourceAccounts.alice, accounts.aliceUID)
        XCTAssertNotEqual(fixture.sourceAccounts.group, accounts.staffGID)
        try useReceiver(fixture, accounts: accounts)
        try fixture.bootstrap()

        let incoming = try fixture.edit()
        let packet = try fixture.packet(fixture.source.peerMetadataObjects(revisionID: incoming.revisionID))
        XCTAssertEqual(try fixture.send(packet).accepted, 1)
        XCTAssertEqual(try fixture.receiver.get(incoming.itemID), incoming)

        let localEdit = try fixture.receiver.withAccess(forUID: accounts.aliceUID) {
            try fixture.receiver.commit(
                CommitRequest(
                    action: .revise, itemID: incoming.itemID, expectedRevisionID: incoming.revisionID,
                    changes: ["body": .text("local name-mapped write")], operationID: "mapped-local-write")
            ).revision
        }
        XCTAssertEqual(try fixture.receiver.get(localEdit.itemID), localEdit)
    }

    func testSourceNumericUIDAssignedToAnotherLocalNameGrantsNoReadOrWriteRights() throws {
        let fixture = try PeerIntakeStoreTests.Fixture()
        defer {
            fixture.receiver = nil
            fixture.source = nil
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let accounts = LocalAccounts(unrelatedUIDs: [fixture.sourceAccounts.alice: "mallory"])
        try useReceiver(fixture, accounts: accounts)
        try fixture.bootstrap()
        let incoming = try fixture.edit()
        XCTAssertEqual(
            try fixture.send(
                fixture.packet(fixture.source.peerMetadataObjects(revisionID: incoming.revisionID))
            ).accepted,
            1)

        try fixture.receiver.withAccess(forUID: accounts.aliceUID) {
            XCTAssertEqual(try fixture.receiver.get(incoming.itemID), incoming)
        }

        code("forbidden") {
            _ = try fixture.receiver.withAccess(forUID: fixture.sourceAccounts.alice) {
                try fixture.receiver.get(incoming.itemID)
            }
        }
        code("forbidden") {
            _ = try fixture.receiver.withAccess(forUID: fixture.sourceAccounts.alice) {
                try fixture.receiver.commit(
                    CommitRequest(
                        action: .revise, itemID: incoming.itemID, expectedRevisionID: incoming.revisionID,
                        changes: ["body": .text("must not write")], operationID: "numeric-collision-write")
                )
            }
        }
    }

    func testUnmappedActorIsHeldAndCannotAuthenticateLocally() throws {
        let fixture = try PeerIntakeStoreTests.Fixture()
        defer {
            fixture.receiver = nil
            fixture.source = nil
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let accounts = LocalAccounts(bobUID: nil)
        try useReceiver(fixture, accounts: accounts)
        try fixture.bootstrap()
        let incoming = try fixture.edit(uid: fixture.sourceAccounts.bob)
        let result = try fixture.send(
            fixture.packet(fixture.source.peerMetadataObjects(revisionID: incoming.revisionID)))
        XCTAssertEqual(result.accepted, 0)
        XCTAssertEqual(result.held, 1)
        XCTAssertEqual(try fixture.receiver.get(fixture.base.itemID).revisionID, fixture.base.revisionID)

        code("unresolvedPrincipal") {
            _ = try fixture.receiver.withAccess(forUID: fixture.sourceAccounts.bob) {
                try fixture.receiver.get(fixture.base.itemID)
            }
        }
    }

    func testFreshReceiverGroupRevocationDeniesReadWriteAndHoldsLaterIntake() throws {
        let fixture = try PeerIntakeStoreTests.Fixture()
        defer {
            fixture.receiver = nil
            fixture.source = nil
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let accounts = LocalAccounts()
        try useReceiver(fixture, accounts: accounts)
        try fixture.bootstrap()
        let first = try fixture.edit(uid: fixture.sourceAccounts.bob, subject: "accepted before revocation")
        XCTAssertEqual(
            try fixture.send(fixture.packet(fixture.source.peerMetadataObjects(revisionID: first.revisionID)))
                .accepted,
            1)

        accounts.bobHasStaff = false
        code("forbidden") {
            _ = try fixture.receiver.withAccess(forUID: accounts.bobUID!) {
                try fixture.receiver.get(first.itemID)
            }
        }
        code("forbidden") {
            _ = try fixture.receiver.withAccess(forUID: accounts.bobUID!) {
                try fixture.receiver.commit(
                    CommitRequest(
                        action: .revise, itemID: first.itemID, expectedRevisionID: first.revisionID,
                        changes: ["body": .text("revoked write")], operationID: "revoked-local-write")
                )
            }
        }

        let later = try fixture.edit(uid: fixture.sourceAccounts.bob, subject: "after revocation")
        let result = try fixture.send(
            fixture.packet(fixture.source.peerMetadataObjects(revisionID: later.revisionID)))
        XCTAssertEqual(result.accepted, 0)
        XCTAssertEqual(result.held, 1)
        XCTAssertEqual(try fixture.receiver.get(fixture.base.itemID).revisionID, first.revisionID)
    }

    private func code(
        _ expected: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }
}
