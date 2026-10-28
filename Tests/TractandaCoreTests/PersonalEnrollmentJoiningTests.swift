import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class PersonalEnrollmentJoiningTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == tractanda_uid() else {
                throw TractandaError("unresolvedPrincipal", "Fixture user missing")
            }
            return .init(uid: uid, name: "admin", primaryGroupName: "staff", groupIDs: [74001])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "admin" else { throw TractandaError("unresolvedPrincipal", "Fixture user missing") }
            return try user(forUID: tractanda_uid())
        }
        func groupID(named name: String) throws -> UInt32 { 74001 }
    }
    private var policy: ItemValue {
        .object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("admin")]),
        ])
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }

    func testUnjoinedFenceSurvivesEveryPreIdentityActivationBoundaryAndReopen() throws {
        try AttachmentFixtureCapacity.requireFree()
        for stop in ["pendingPublished", "readerFenced", "afterIdentities"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "joining-fence-" + Identifier.make())
            try PrivateConfiguration.makeDirectory(root)
            defer { try? FileManager.default.removeItem(at: root) }
            let storeID = try id()
            let lock = tractanda_lock(root.appendingPathComponent(".writer.lock").path)
            XCTAssertGreaterThanOrEqual(lock, 0)
            tractanda_unlock(lock)
            XCTAssertThrowsError(
                try CanonicalReaderRequirement.withWriterLock(root: root, ownerUID: tractanda_uid()) {
                    _ = try PersonalWorkgroupProfile.prepare(
                        root, opening: .joiningReplica(storeID: storeID, configuration: policy),
                        accounts: Accounts(),
                        boundary: { boundary in
                            if boundary == stop {
                                throw TractandaError("fixtureFault", "Interrupted activation")
                            }
                        })
                    if stop == "afterIdentities" {
                        throw TractandaError("fixtureFault", "Interrupted before active profile")
                    }
                }
            ) {
                XCTAssertEqual(
                    ($0 as? TractandaError)?.code, "fixtureFault", "Expected injected boundary \(stop)")
            }
            let pending = try XCTUnwrap(PersonalWorkgroupProfile.load(root, pending: true))
            XCTAssertEqual(pending.initialization, "freshReplicaJoining")
            var reopened: ItemStore? = try ItemStore(
                personalRoot: root, opening: .existing, accounts: Accounts())
            XCTAssertEqual(try reopened!.personalSyncIdentity().replicaID, pending.replicaID)
            XCTAssertTrue(reopened!.isPersonalBaselinePending)
            XCTAssertThrowsError(try reopened!.get(id())) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "baselinePending")
            }
            let status = try reopened!.withAccess(forUID: tractanda_uid()) {
                try reopened!.personalPeerCanonicalStatus()
            }
            XCTAssertEqual(status.readiness, .pendingActivation)
            XCTAssertNil(status.personal?.baselineSourceReplicaID)
            reopened = nil
        }
    }

    func testFreshJoiningTargetAllowsIdentityAdminAndSelectionButDeniesNormalContent() throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "joining-operations-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try ItemStore.createJoiningPersonalSyncReplica(
            root: root, storeID: id(),
            accessConfiguration: policy, accounts: Accounts())
        XCTAssertTrue(target.isPersonalBaselinePending)
        let authorization = try PersonalEnrollmentLocalAuthorization.authorize(
            store: target, forUID: tractanda_uid())
        XCTAssertEqual(authorization.identity.replicaID, try target.personalSyncIdentity().replicaID)
        XCTAssertThrowsError(
            try target.withAccess(forUID: tractanda_uid()) {
                try target.commit(
                    .init(
                        classID: "Item", changes: ["subject": .text("must stay blocked")],
                        operationID: "unjoined-write"))
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "baselinePending") }
        let source = try id()
        let selection = try target.startPersonalBaseline(sourceReplicaID: source)
        XCTAssertEqual(try target.startPersonalBaseline(sourceReplicaID: source), selection)
        XCTAssertThrowsError(try target.finishPersonalBaseline(selectionID: selection)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "baselineNotReady")
        }
    }

    func testReadinessRequiresSameSelectionProcessJobAndSourceGeneration() throws {
        let binding = try PeerExchangeBinding(
            peerID: "source", storeID: id(), localReplicaID: id(), remoteReplicaID: id(),
            pairingID: id(), localIsInitiator: true, configurationDigest: String(repeating: "a", count: 64))
        let selection = try id()
        let job = UUID()
        let first = try PersonalEnrollmentCompletedCut(
            binding: binding, selectionID: selection,
            jobGeneration: job, ordinal: 1, sourceCatalogueGeneration: "catalogue-one", cutRowID: 4)
        for (selectionID, generation, catalogue, row) in [
            (try id(), job, "catalogue-one", Int64(5)), (selection, UUID(), "catalogue-one", Int64(5)),
            (selection, job, "catalogue-two", Int64(5)), (selection, job, "catalogue-one", Int64(3)),
        ] {
            let rescan = try PersonalEnrollmentCompletedCut(
                binding: binding, selectionID: selectionID,
                jobGeneration: generation, ordinal: 2, sourceCatalogueGeneration: catalogue, cutRowID: row)
            XCTAssertThrowsError(
                try PersonalEnrollmentBaselineReadiness.observed(first: first, rescan: rescan))
        }
    }
}
