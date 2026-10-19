import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

/// Verifies that authenticated shared administrator decisions are cluster-wide facts while
/// ordinary authentication and item permissions continue to use the receiving directory.
final class GlobalAdministratorScopeTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture

    /// The receiving host has different numeric mappings and can lose its local `admin` NSS
    /// name lookup without changing the source principal carried by canonical records.
    private final class ReceiverAccounts: AccountDirectory {
        let aliceUID: UInt32 = 62_001
        let bobUID: UInt32 = 62_002
        let adminUID: UInt32 = 63_003
        let staffGID: UInt32 = 82_001
        var adminNameAvailable = true
        var adminIsNonadmin = false
        private(set) var adminNameLookups = 0

        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            switch uid {
            case tractanda_uid(): name = adminIsNonadmin ? "service" : "admin"
            case aliceUID: name = "alice"
            case bobUID: name = "bob"
            case adminUID: name = "admin"
            default: throw TractandaError("unresolvedPrincipal", "Unknown receiver fixture account")
            }
            let groups: Set<UInt32> = uid == adminUID ? [] : [staffGID]
            return .init(uid: uid, name: name, primaryGroupName: "staff", groupIDs: groups)
        }

        func user(named name: String) throws -> AccountIdentity {
            if name == "admin" {
                adminNameLookups += 1
                guard adminNameAvailable else {
                    throw TractandaError("unresolvedPrincipal", "Receiver NSS has no admin name")
                }
                return try user(forUID: adminIsNonadmin ? adminUID : tractanda_uid())
            }
            switch name {
            case "alice": return try user(forUID: aliceUID)
            case "bob": return try user(forUID: bobUID)
            case "service": return try user(forUID: tractanda_uid())
            default: throw TractandaError("unresolvedPrincipal", "Unknown receiver fixture account")
            }
        }

        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" || name == AccessConfiguration.defaultAdministratorGroup else {
                throw TractandaError("unresolvedPrincipal", "Unknown receiver fixture group")
            }
            return staffGID
        }

        func resetAdminNameLookups() { adminNameLookups = 0 }
    }

    private func canonicalObjects(_ root: URL, fixture: Fixture) throws -> [(PeerPackage.Object, Data)] {
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
                throw TractandaError("resourceLimit", "Shared authority test metadata cap")
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
        try fixture.capacity()
        return result.sorted { $0.0.id < $1.0.id }
    }

    private func installReceiverDirectory(
        _ directory: ReceiverAccounts, in fixture: Fixture
    ) throws {
        fixture.receiver = nil
        try fixture.capacity()
        fixture.receiver = try ItemStore(
            root: fixture.receiverRoot, accounts: directory,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true)
        try fixture.capacity()
    }

    private func installSourceDirectory(
        _ directory: ReceiverAccounts, in fixture: Fixture
    ) throws {
        fixture.source = nil
        try fixture.capacity()
        fixture.source = try ItemStore(
            root: fixture.sourceRoot, accounts: directory,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true)
        try fixture.capacity()
    }

    private func replicaID(_ root: URL, storeID: String) throws -> String {
        try XCTUnwrap(
            ReplicaIdentity.load(root: root, storeID: storeID, ownerUID: tractanda_uid())?.replicaID)
    }

    func testSourceValidatedRetirementAppliesWithoutRecipientAdministratorLookup() throws {
        let f = try Fixture()
        try f.bootstrap()
        let sourceOrigin = try replicaID(f.sourceRoot, storeID: f.storeID)
        let receiverOrigin = try replicaID(f.receiverRoot, storeID: f.storeID)
        let outbound = try PeerPackage.Context(
            peerID: "retirement-destination", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("retirement destination".utf8)),
            permittedOrigins: [receiverOrigin])
        try f.source.configurePeerIntake(peers: [outbound])
        try f.source.removePeerIntake(
            peerID: outbound.peerID, retiredOriginIDs: [receiverOrigin], operationID: try Fixture.id())

        let directory = ReceiverAccounts()
        XCTAssertNotEqual(directory.aliceUID, f.sourceAccounts.alice)
        XCTAssertNotEqual(directory.staffGID, f.sourceAccounts.group)
        try installReceiverDirectory(directory, in: f)
        directory.resetAdminNameLookups()
        directory.adminNameAvailable = false
        let rows = try canonicalObjects(f.sourceRoot, fixture: f)
        let retirement = try XCTUnwrap(
            rows.first { row in
                row.0.kind == .authority
                    && (try? AuthorityRecordCodec.decode(row.1).record.kind) == .originRetirement
            })
        let sourceRecord = try AuthorityRecordCodec.decode(retirement.1).record
        XCTAssertEqual(sourceRecord.actorPrincipal, "admin")
        XCTAssertEqual(sourceRecord.originReplicaID, sourceOrigin)
        let effectiveAt = try XCTUnwrap(sourceRecord.payload["effectiveAt"]?.dateString)
        let effectiveTicks = try RevisionTimestamp(effectiveAt).ticks
        XCTAssertEqual(try PeerLifecycle.revisionTicks(sourceRecord.recordID), effectiveTicks)

        _ = try f.send(f.packet(rows), context: f.context, to: f.receiver)
        XCTAssertEqual(directory.adminNameLookups, 0)
        XCTAssertEqual(try f.receiver.get(f.base.itemID, revisionID: f.base.revisionID), f.base)
        directory.adminNameAvailable = true
        XCTAssertThrowsError(
            try f.receiver.withAccess(forUID: directory.aliceUID) {
                try f.receiver.commit(
                    .init(
                        action: .revise, itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
                        changes: ["subject": .text("retired local write")],
                        operationID: "global-admin-retirement-fence"))
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "localOriginRetired") }
        let received = try XCTUnwrap(
            canonicalObjects(f.receiverRoot, fixture: f).first { $0.0.id == retirement.0.id })
        XCTAssertEqual(received.1, retirement.1)
        try f.capacity()
    }

    func testForeignProtectedReviewUsesSourceDecisionAndPreservesCurrentACL() throws {
        let reviewed = try AuthorityReviewStoreTests.ReviewedFixture()
        let f = reviewed.base
        let reviewerOrigin = try replicaID(f.receiverRoot, storeID: f.storeID)
        let destinationOrigin = try replicaID(f.sourceRoot, storeID: f.storeID)
        let inbound = try PeerPackage.Context(
            peerID: "global-reviewer", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("global reviewer".utf8)),
            permittedOrigins: [destinationOrigin, reviewerOrigin].sorted())
        try f.source.configurePeerIntake(peers: [inbound])
        let decision = try f.receiver.resolveAuthorityReview(reviewed.request())
        let reviewerRows = try canonicalObjects(f.receiverRoot, fixture: f)
        let sourceDecision = try XCTUnwrap(
            reviewerRows.first { row in
                row.0.kind == .authority
                    && (try? AuthorityRecordCodec.decode(row.1).record.kind) == .reviewDecision
            })
        XCTAssertEqual(try AuthorityRecordCodec.decode(sourceDecision.1).record.actorPrincipal, "admin")
        XCTAssertEqual(try decision.revision.itemID, reviewed.held.itemID)

        let directory = ReceiverAccounts()
        directory.adminIsNonadmin = true
        XCTAssertNotEqual(directory.adminUID, tractanda_uid())
        XCTAssertNotEqual(directory.staffGID, f.receiverAccounts.group)
        try installSourceDirectory(directory, in: f)
        directory.resetAdminNameLookups()
        let intake = try f.send(f.packet(reviewerRows), context: inbound, to: f.source)
        XCTAssertGreaterThan(intake.accepted, 0)
        XCTAssertEqual(try f.source.get(reviewed.held.itemID).revisionID, decision.revision.revisionID)
        XCTAssertEqual(
            try f.source.get(reviewed.held.itemID, revisionID: reviewed.held.revisionID), reviewed.held)
        let receivedDecision = try XCTUnwrap(
            canonicalObjects(f.sourceRoot, fixture: f).first { $0.0.id == sourceDecision.0.id })
        XCTAssertEqual(receivedDecision.1, sourceDecision.1)

        XCTAssertEqual(try directory.user(named: "admin").uid, directory.adminUID)
        XCTAssertThrowsError(
            try f.source.withAccess(forUID: directory.adminUID) {
                try f.source.configurePeerIntake(peers: [inbound])
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }

        XCTAssertThrowsError(
            try f.source.withAccess(forUID: directory.bobUID) {
                try f.source.get(reviewed.held.itemID)
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        try f.capacity()
    }

    func testUnpermittedOriginAndNonadministratorCannotCreateSharedAuthority() throws {
        let f = try Fixture()
        try f.bootstrap()
        let sourceOrigin = try replicaID(f.sourceRoot, storeID: f.storeID)
        let receiverOrigin = try replicaID(f.receiverRoot, storeID: f.storeID)
        let outbound = try PeerPackage.Context(
            peerID: "retirement-destination", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("untrusted destination".utf8)),
            permittedOrigins: [receiverOrigin])
        try f.source.configurePeerIntake(peers: [outbound])

        XCTAssertThrowsError(
            try f.source.withAccess(forUID: f.sourceAccounts.bob) {
                try f.source.removePeerIntake(
                    peerID: outbound.peerID, retiredOriginIDs: [receiverOrigin], operationID: try Fixture.id()
                )
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }

        try f.source.removePeerIntake(
            peerID: outbound.peerID, retiredOriginIDs: [receiverOrigin], operationID: try Fixture.id())
        let unauthorizedOrigin = try PeerPackage.Context(
            peerID: "spoofed-origin", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("wrong origin".utf8)),
            permittedOrigins: [receiverOrigin])
        try f.receiver.configurePeerIntake(peers: [f.context, unauthorizedOrigin])
        let rows = try canonicalObjects(f.sourceRoot, fixture: f)
        do {
            _ = try f.send(f.packet(rows), context: unauthorizedOrigin, to: f.receiver)
        } catch {
            XCTAssertTrue(error is TractandaError)
        }

        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
        let write = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                .init(
                    action: .revise, itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
                    changes: ["subject": .text("unauthorized retirement did not fence")],
                    operationID: "unauthorized-retirement-no-grant"))
        }
        XCTAssertEqual(write.revision.fields["subject"], .text("unauthorized retirement did not fence"))
        XCTAssertNotEqual(sourceOrigin, receiverOrigin)
        try f.capacity()
    }
}
