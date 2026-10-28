import CTractandaPlatform
import Foundation
import XCTest
@testable import TractandaCore

final class PersonalEnrollmentTargetTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        var aliceAvailable = true
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == tractanda_uid() {
                return .init(uid: uid, name: "admin", primaryGroupName: "staff", groupIDs: [74001])
            }
            if uid == 64001 && aliceAvailable {
                return .init(uid: uid, name: "alice", primaryGroupName: "family", groupIDs: [74002])
            }
            throw TractandaError("unresolvedPrincipal", "Fixture user missing")
        }
        func user(named name: String) throws -> AccountIdentity {
            if name == "admin" { return try user(forUID: tractanda_uid()) }
            if name == "alice" { return try user(forUID: 64001) }
            throw TractandaError("unresolvedPrincipal", "Fixture user missing")
        }
        func groupID(named name: String) throws -> UInt32 {
            if name == "targetadmins" || name == "staff" { return 74001 }
            if name == "family" { return 74002 }
            throw TractandaError("unresolvedPrincipal", "Fixture group missing")
        }
    }
    private var localPolicy: ItemValue { .object([
        "profile": .text(AccessConfiguration.profile), "users": .list([.text("admin")]),
        "groups": .list([]), "administration": .text("system"),
        "administratorGroup": .text("targetadmins"),
        "legacyUsers": .object(["uid:123": .text("admin")]),
    ]) }
    private var sourcePolicy: ItemValue { .object([
        "profile": .text(AccessConfiguration.profile),
        "users": .list([.text("admin"), .text("alice")]), "groups": .list([.text("family")]),
    ]) }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func invitation(storeID: String) throws -> PersonalEnrollmentInvitation {
        let metadata = try PersonalEnrollmentInvitationMetadata(operationID: id(), storeID: storeID,
            issuerReplicaID: id(), bootstrapReplicaID: id(), pairingID: id(),
            endpoints: [.init(host: "issuer.fixture", port: 48732)], expiresAt: 99_999,
            expectedMembershipDigest: nil)
        return try .init(metadata: metadata, secret: .init(bytes: [UInt8](repeating: 73, count: 32)))
    }
    private func config(_ invitation: PersonalEnrollmentInvitation, targetID: String,
        issuerID: String? = nil) throws -> PersonalMembershipConfiguration {
        try .init(storeID: invitation.metadata.storeID, configurationID: id(), members: [
            .init(replicaID: issuerID ?? invitation.metadata.issuerReplicaID, hostname: "issuer.fixture"),
            .init(replicaID: targetID, hostname: "target.fixture"),
        ])
    }
    private func fixture(_ body: (URL, Accounts, String) throws -> Void) throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "enrollment-target-", source: "PersonalEnrollmentTargetTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, Accounts(), id())
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        var total: UInt64 = 0
        while let file = enumerator.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { total += UInt64(values.fileSize ?? 0) }
        }
        XCTAssertLessThanOrEqual(total, 128 * 1024 * 1024)
        try AttachmentFixtureCapacity.requireFree()
    }
    private func joining(_ root: URL, accounts: Accounts, storeID: String) throws -> ItemStore {
        try ItemStore.createJoiningPersonalSyncReplica(root: root, indexDirectory: root.deletingLastPathComponent().appendingPathComponent("index"),
            storeID: storeID, accessConfiguration: localPolicy, accounts: accounts)
    }
    private func bytes(_ root: URL) throws -> Data? {
        try PersonalEnrollmentStateFiles(root: root).read("target.bin")
    }
    private func reject(_ body: () throws -> Void) {
        XCTAssertThrowsError(try body())
    }

    func testLostClaimReplyReopensExactContinuationWithoutLeakingStatus() throws {
        try fixture { parent, accounts, storeID in
            let root = parent.appendingPathComponent("target")
            let invite = try invitation(storeID: storeID)
            var store: ItemStore? = try joining(root, accounts: accounts, storeID: storeID)
            let registry = PersonalEnrollmentTargetRegistry(root: root)
            let first = try registry.begin(store: store!, forUID: tractanda_uid(), invitation: invite, hostname: "target.fixture")
            let material = try XCTUnwrap(registry.material(store: store!, forUID: tractanda_uid()))
            let claim = try XCTUnwrap(material.2)
            let privateClaim = try claim.privateEncodedBytes()
            let encodedStatus = try JSON.encode(first)
            XCTAssertFalse(String(decoding: encodedStatus, as: UTF8.self).contains(try invite.privateCode()))
            XCTAssertFalse(String(decoding: encodedStatus, as: UTF8.self).contains("secret"))
            XCTAssertFalse(String(decoding: encodedStatus, as: UTF8.self).contains(Data(invite.secret.withBytes { $0 }).base64EncodedString()))
            XCTAssertFalse(String(decoding: encodedStatus, as: UTF8.self).contains(Data(claim.continuationSecret.withBytes { $0 }).base64EncodedString()))
            XCTAssertEqual(first.claim.targetReplicaID, try store!.personalSyncIdentity().replicaID)
            XCTAssertTrue(store!.isPersonalBaselinePending)
            let saved = try bytes(root)
            let otherInvite = try invitation(storeID: storeID)
            reject { _ = try registry.begin(store: store!, forUID: tractanda_uid(), invitation: otherInvite, hostname: "target.fixture") }
            reject { _ = try registry.begin(store: store!, forUID: tractanda_uid(), invitation: invite, hostname: "different.fixture") }
            XCTAssertTrue(try bytes(root) == saved, "Private enrollment state must remain unchanged.")
            store = nil
            store = try ItemStore.openInitialized(root: root, indexDirectory: parent.appendingPathComponent("index"), accounts: accounts)
            let resumed = try XCTUnwrap(PersonalEnrollmentTargetRegistry(root: root).material(store: store!, forUID: tractanda_uid()))
            XCTAssertEqual(resumed.0, first)
            XCTAssertTrue(try XCTUnwrap(resumed.1).privateCode() == invite.privateCode(), "Invitation must resume exactly.")
            XCTAssertTrue(try XCTUnwrap(resumed.2).privateEncodedBytes() == privateClaim, "Continuation must resume exactly.")
            XCTAssertEqual(try registry.begin(store: store!, forUID: tractanda_uid(), invitation: invite, hostname: "target.fixture"), first)
            XCTAssertTrue(store!.isPersonalBaselinePending)
        }
    }

    func testOnlyExactContinuationAcknowledgementConsumesInvitation() throws {
        try fixture { parent, accounts, storeID in
            let root = parent.appendingPathComponent("target"), invite = try invitation(storeID: storeID)
            let store = try joining(root, accounts: accounts, storeID: storeID)
            let registry = PersonalEnrollmentTargetRegistry(root: root)
            let status = try registry.begin(store: store, forUID: tractanda_uid(), invitation: invite, hostname: "target.fixture")
            let initial = try bytes(root)
            for (issuer, pairing, operation) in [
                (try id(), status.claim.continuationPairingID, invite.metadata.operationID),
                (invite.metadata.issuerReplicaID, try id(), invite.metadata.operationID),
                (invite.metadata.issuerReplicaID, status.claim.continuationPairingID, try id()),
            ] {
                reject { try registry.continuationAccepted(store: store, forUID: tractanda_uid(),
                    issuerReplicaID: issuer, pairingID: pairing, operationID: operation) }
                XCTAssertTrue(try bytes(root) == initial, "Private enrollment state must remain unchanged.")
            }
            let claimBefore = try XCTUnwrap(registry.material(store: store, forUID: tractanda_uid())?.2).privateEncodedBytes()
            try registry.continuationAccepted(store: store, forUID: tractanda_uid(),
                issuerReplicaID: invite.metadata.issuerReplicaID, pairingID: status.claim.continuationPairingID,
                operationID: invite.metadata.operationID)
            let accepted = try XCTUnwrap(registry.material(store: store, forUID: tractanda_uid()))
            XCTAssertEqual(accepted.0.phase, .claimed)
            XCTAssertNil(accepted.1)
            XCTAssertTrue(try XCTUnwrap(accepted.2).privateEncodedBytes() == claimBefore, "Continuation must survive acknowledgement.")
            let retained = try XCTUnwrap(bytes(root))
            XCTAssertNil(retained.range(of: invite.secret.withBytes { Data($0) }))
            try registry.continuationAccepted(store: store, forUID: tractanda_uid(),
                issuerReplicaID: invite.metadata.issuerReplicaID, pairingID: status.claim.continuationPairingID,
                operationID: invite.metadata.operationID)
            XCTAssertTrue(try bytes(root) == retained, "Private enrollment state must remain unchanged.")
            XCTAssertTrue(store.isPersonalBaselinePending)
        }
    }

    func testAcceptedPlanPersistsBeforePolicyAdoptionAndResumesExactly() throws {
        try fixture { parent, accounts, storeID in
            let root = parent.appendingPathComponent("target"), invite = try invitation(storeID: storeID)
            var store: ItemStore? = try joining(root, accounts: accounts, storeID: storeID)
            let registry = PersonalEnrollmentTargetRegistry(root: root)
            let status = try registry.begin(store: store!, forUID: tractanda_uid(), invitation: invite, hostname: "target.fixture")
            let admission = try PersonalEnrollmentAdmission(configuration: AccessConfiguration(sourcePolicy))
            let membership = try config(invite, targetID: status.claim.targetReplicaID)
            try registry.continuationAccepted(store: store!, forUID: tractanda_uid(),
                issuerReplicaID: invite.metadata.issuerReplicaID, pairingID: status.claim.continuationPairingID,
                operationID: invite.metadata.operationID)
            accounts.aliceAvailable = false
            reject { try registry.acceptPlan(store: store!, forUID: tractanda_uid(), operationID: invite.metadata.operationID,
                admission: admission, configuration: membership) }
            let saved = try XCTUnwrap(registry.status(store: store!, forUID: tractanda_uid()))
            XCTAssertEqual(saved.admission, admission)
            XCTAssertEqual(saved.configuration, membership)
            XCTAssertEqual(try store!.personalEnrollmentAdmission(forUID: tractanda_uid()),
                try PersonalEnrollmentAdmission(configuration: AccessConfiguration(localPolicy)))
            accounts.aliceAvailable = true
            store = nil
            store = try ItemStore.openInitialized(root: root, indexDirectory: parent.appendingPathComponent("index"), accounts: accounts)
            try registry.acceptPlan(store: store!, forUID: tractanda_uid(), operationID: invite.metadata.operationID,
                admission: admission, configuration: membership)
            XCTAssertEqual(try store!.personalEnrollmentAdmission(forUID: tractanda_uid()), admission)
            let profile = try XCTUnwrap(PersonalWorkgroupProfile.load(root))
            let policy = try AccessConfiguration(profile.accessConfiguration)
            XCTAssertEqual(policy.administratorGroup, "targetadmins")
            XCTAssertEqual(policy.legacyUsers, [123: "admin"])
            let accepted = try bytes(root)
            try registry.acceptPlan(store: store!, forUID: tractanda_uid(), operationID: invite.metadata.operationID,
                admission: admission, configuration: membership)
            XCTAssertTrue(try bytes(root) == accepted, "Private enrollment state must remain unchanged.")
            let alternate = try config(invite, targetID: status.claim.targetReplicaID, issuerID: id())
            reject { try registry.acceptPlan(store: store!, forUID: tractanda_uid(), operationID: invite.metadata.operationID,
                admission: admission, configuration: alternate) }
            reject { try registry.acceptPlan(store: store!, forUID: tractanda_uid(), operationID: try id(),
                admission: admission, configuration: membership) }
            let otherAdmission = try PersonalEnrollmentAdmission(configuration: AccessConfiguration(localPolicy))
            reject { try registry.acceptPlan(store: store!, forUID: tractanda_uid(), operationID: invite.metadata.operationID,
                admission: otherAdmission, configuration: membership) }
            XCTAssertTrue(try bytes(root) == accepted, "Private enrollment state must remain unchanged.")
            XCTAssertTrue(store!.isPersonalBaselinePending)
            store = nil
            store = try ItemStore.openInitialized(root: root, indexDirectory: parent.appendingPathComponent("index"), accounts: accounts)
            XCTAssertEqual(try store!.personalEnrollmentAdmission(forUID: tractanda_uid()), admission)
            XCTAssertEqual(try registry.status(store: store!, forUID: tractanda_uid())?.configuration, membership)
            XCTAssertTrue(store!.isPersonalBaselinePending)
        }
    }

    func testUnacknowledgedClaimCannotAdoptSourcePlan() throws {
        try fixture { parent, accounts, storeID in
            let root = parent.appendingPathComponent("target"), invite = try invitation(storeID: storeID)
            let store = try joining(root, accounts: accounts, storeID: storeID)
            let registry = PersonalEnrollmentTargetRegistry(root: root)
            let status = try registry.begin(store: store, forUID: tractanda_uid(), invitation: invite, hostname: "target.fixture")
            let admission = try PersonalEnrollmentAdmission(configuration: AccessConfiguration(sourcePolicy))
            let membership = try config(invite, targetID: status.claim.targetReplicaID)
            let before = try bytes(root)
            reject { try registry.acceptPlan(store: store, forUID: tractanda_uid(), operationID: invite.metadata.operationID,
                admission: admission, configuration: membership) }
            XCTAssertTrue(try bytes(root) == before, "Private enrollment state must remain unchanged.")
            XCTAssertEqual(try store.personalEnrollmentAdmission(forUID: tractanda_uid()),
                try PersonalEnrollmentAdmission(configuration: AccessConfiguration(localPolicy)))
            XCTAssertTrue(store.isPersonalBaselinePending)
        }
    }

    func testOldReplicaAndExistingBaselineOrMembershipAreRefused() throws {
        try fixture { parent, accounts, storeID in
            let invite = try invitation(storeID: storeID)
            let oldRoot = parent.appendingPathComponent("old")
            let old = try ItemStore.createPersonalSyncReplica(root: oldRoot, storeID: storeID,
                accessConfiguration: localPolicy, accounts: accounts)
            reject { _ = try PersonalEnrollmentTargetRegistry(root: oldRoot).begin(
                store: old, forUID: tractanda_uid(), invitation: invite, hostname: "target.fixture") }
            XCTAssertTrue(try bytes(oldRoot) == nil, "Refusal must not create private state.")
            let baselineRoot = parent.appendingPathComponent("baseline")
            let baseline = try ItemStore.createJoiningPersonalSyncReplica(root: baselineRoot, storeID: storeID,
                accessConfiguration: localPolicy, accounts: accounts)
            _ = try baseline.startPersonalBaseline(sourceReplicaID: invite.metadata.issuerReplicaID)
            reject { _ = try PersonalEnrollmentTargetRegistry(root: baselineRoot).begin(
                store: baseline, forUID: tractanda_uid(), invitation: invite, hostname: "target.fixture") }
            XCTAssertTrue(try bytes(baselineRoot) == nil, "Refusal must not create private state.")
            let memberRoot = parent.appendingPathComponent("member")
            let member = try ItemStore.createJoiningPersonalSyncReplica(root: memberRoot, storeID: storeID,
                accessConfiguration: localPolicy, accounts: accounts)
            let identity = try member.personalSyncIdentity()
            let membership = try PersonalMembershipConfiguration(storeID: storeID, configurationID: id(),
                members: [.init(replicaID: identity.replicaID, hostname: "target.fixture")])
            try PersonalSyncConfiguration.write(membership, root: memberRoot, name: PersonalSyncConfiguration.membershipName)
            reject { _ = try PersonalEnrollmentTargetRegistry(root: memberRoot).begin(
                store: member, forUID: tractanda_uid(), invitation: invite, hostname: "target.fixture") }
            XCTAssertTrue(try bytes(memberRoot) == nil, "Refusal must not create private state.")
        }
    }

    func testCorruptEnrollmentStateDoesNotGateStandaloneContent() throws {
        try fixture { parent, accounts, _ in
            let root = parent.appendingPathComponent("standalone")
            var store: ItemStore? = try ItemStore.initializePersonalWorkgroup(root: root,
                accounts: accounts, accessConfiguration: localPolicy)
            let created = try store!.withAccess(forUID: tractanda_uid()) {
                try store!.commit(.init(classID: "Item", changes: ["subject": .text("preserve")], operationID: "standalone-fixture"))
            }
            let occupiedID = try store!.personalSyncIdentity().storeID
            let occupiedInvite = try invitation(storeID: occupiedID)
            reject { _ = try PersonalEnrollmentTargetRegistry(root: root).begin(
                store: store!, forUID: tractanda_uid(), invitation: occupiedInvite, hostname: "target.fixture") }
            XCTAssertTrue(try bytes(root) == nil, "Refusal must not create private state.")
            try PersonalEnrollmentStateFiles(root: root).replace("target.bin", bytes: Data("broken".utf8), expected: nil)
            reject { _ = try PersonalEnrollmentTargetRegistry(root: root).status(store: store!, forUID: tractanda_uid()) }
            XCTAssertEqual(try store!.withAccess(forUID: tractanda_uid()) { try store!.get(created.revision.itemID).fields["subject"] }, .text("preserve"))
            store = nil
            store = try ItemStore.openInitialized(root: root, accounts: accounts)
            XCTAssertEqual(try store!.withAccess(forUID: tractanda_uid()) { try store!.get(created.revision.itemID).fields["subject"] }, .text("preserve"))
        }
    }
}
