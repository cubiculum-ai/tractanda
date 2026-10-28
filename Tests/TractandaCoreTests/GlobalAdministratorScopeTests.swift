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

    func testUnpermittedOriginAndNonadministratorCannotCreateSharedAuthority() throws {
        let f = try Fixture()
        try f.bootstrap()
        let sourceOrigin = try replicaID(f.sourceRoot, storeID: f.storeID)
        let receiverOrigin = try replicaID(f.receiverRoot, storeID: f.storeID)
        let outbound = try PeerPackage.Context(
            peerID: "retirement-destination", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("retirement destination".utf8)),
            permittedOrigins: [receiverOrigin])
        try f.source.configurePeerIntake(peers: [outbound])
        XCTAssertThrowsError(
            try f.source.withAccess(forUID: f.sourceAccounts.bob) {
                try f.source.removePeerIntake(
                    peerID: outbound.peerID, retiredOriginIDs: [receiverOrigin], operationID: try Fixture.id()
                )
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }

        let relay = try PeerPackage.Context(
            peerID: "configured-relay", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("relay origin proof".utf8)),
            permittedOrigins: [receiverOrigin])
        try f.receiver.configurePeerIntake(peers: [f.context, relay])
        // A genuine third issuer has no receiver-side enrollment/admission. Sharing a
        // StoreID and knowing the canonical administrator policy cannot manufacture it.
        guard AttachmentFixtureCapacity.fixtureCapBytes >= 24 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Three-store authority fixture estimates24MiB")
        }
        let thirdRoot = f.directory.appendingPathComponent("unadmitted-issuer")
        let third = try f.openFreshSharedReplica(thirdRoot, f.sourceAccounts)
        try third.configurePeerIntake(peers: [f.context])
        try f.bootstrap(to: third)
        let thirdOrigin = try replicaID(thirdRoot, storeID: f.storeID)
        XCTAssertNotEqual(thirdOrigin, sourceOrigin)
        XCTAssertNotEqual(thirdOrigin, receiverOrigin)
        try third.configurePeerIntake(peers: [f.context, outbound])
        try third.removePeerIntake(
            peerID: outbound.peerID, retiredOriginIDs: [receiverOrigin], operationID: try Fixture.id())
        let untrustedRows = try canonicalObjects(thirdRoot, fixture: f)
        let untrustedRetirement = try XCTUnwrap(
            untrustedRows.first {
                $0.0.kind == .authority
                    && (try? AuthorityRecordCodec.decode($0.1).record.kind) == .originRetirement
            })
        XCTAssertEqual(
            try AuthorityRecordCodec.decode(untrustedRetirement.1).record.originReplicaID, thirdOrigin)
        _ = try f.send(f.packet(untrustedRows), context: relay, to: f.receiver)
        let diagnostic = try ItemIndex(
            path: f.receiver.indexDirectory.appendingPathComponent("items.sqlite").path, create: false)
        defer { diagnostic.close() }
        XCTAssertFalse(
            try diagnostic.peerRetirementIsActive(
                AuthorityBinding(recordID: untrustedRetirement.0.id, sha256: untrustedRetirement.0.sha256)))
        XCTAssertFalse(try diagnostic.peerOriginRetired(receiverOrigin))
        let write = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                .init(
                    action: .revise, itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
                    changes: ["subject": .text("unadmitted retirement did not fence")],
                    operationID: "unadmitted-retirement-no-grant"))
        }
        XCTAssertEqual(write.revision.fields["subject"], .text("unadmitted retirement did not fence"))

        // The bootstrap source is already admitted. Its authenticated administrator
        // decision remains cluster-wide even when carried by this other configured relay.
        try f.source.removePeerIntake(
            peerID: outbound.peerID, retiredOriginIDs: [receiverOrigin], operationID: try Fixture.id())
        _ = try f.send(f.packet(canonicalObjects(f.sourceRoot, fixture: f)), context: relay, to: f.receiver)
        XCTAssertTrue(try diagnostic.peerOriginRetired(receiverOrigin))
        XCTAssertEqual(try f.receiver.get(f.base.itemID), write.revision)
        XCTAssertThrowsError(
            try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.commit(
                    .init(
                        action: .revise, itemID: f.base.itemID, expectedRevisionID: write.revision.revisionID,
                        changes: ["subject": .text("retired local write")],
                        operationID: "admitted-retirement-fence"))
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "localOriginRetired") }
        try f.capacity()
    }
}
