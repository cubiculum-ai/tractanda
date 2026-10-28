import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

/// Core state-machine fixtures use the explicit trusted-host continuation seam below.
/// They do not claim an actual authenticated socket or network pairing proof.
final class PersonalEnrollmentReplacementTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == tractanda_uid() else { throw PersonalEnrollmentError.invalid() }
            return .init(uid: uid, name: "admin", primaryGroupName: "staff", groupIDs: [74001])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "admin" else { throw PersonalEnrollmentError.invalid() }
            return try user(forUID: tractanda_uid())
        }
        func groupID(named name: String) throws -> UInt32 { 74001 }
    }
    private var policy: ItemValue { .object([
        "profile": .text(AccessConfiguration.profile), "users": .list([.text("admin")]),
    ]) }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func fixture(_ body: (URL, Accounts) throws -> Void) throws {
        try AttachmentFixtureCapacity.requireFree()
        let parent = try GuardedFixtureDirectory.create(prefix: "enrollment-replacement-",
            source: "PersonalEnrollmentReplacementTests", test: name)
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(parent, Accounts())
        var bytes: UInt64 = 0
        let files = try XCTUnwrap(FileManager.default.enumerator(at: parent,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { bytes += UInt64(values.fileSize ?? 0) }
        }
        XCTAssertLessThanOrEqual(bytes, AttachmentFixtureCapacity.fixtureCapBytes)
        try AttachmentFixtureCapacity.requireFree()
    }
    private func makeSource(_ parent: URL, accounts: Accounts) throws -> ItemStore {
        try ItemStore.initializePersonalWorkgroup(root: parent.appendingPathComponent("source"),
            accounts: accounts, accessConfiguration: policy)
    }
    private func makeTarget(_ parent: URL, accounts: Accounts, storeID: String) throws -> ItemStore {
        try ItemStore.createJoiningPersonalSyncReplica(root: parent.appendingPathComponent("target"),
            indexDirectory: parent.appendingPathComponent("target-index"), storeID: storeID,
            accessConfiguration: policy, accounts: accounts)
    }
    private func authorize(_ store: ItemStore) throws -> PersonalEnrollmentLocalAuthorization {
        try .authorize(store: store, forUID: tractanda_uid())
    }
    private func issue(_ registry: PersonalEnrollmentRegistry, _ authorization: PersonalEnrollmentLocalAuthorization,
        at now: Int64) throws -> PersonalEnrollmentInvitation {
        try registry.issue(authorization: authorization,
            endpoints: [.init(host: "issuer.fixture", port: 48732)], now: now, lifetimeSeconds: 10)
    }
    private func changedInvitation(_ original: PersonalEnrollmentInvitation, storeID: String? = nil,
        issuerID: String? = nil, familyID: String? = nil) throws -> PersonalEnrollmentInvitation {
        let old = original.metadata
        return try .init(metadata: .init(operationID: id(), storeID: storeID ?? old.storeID,
            issuerReplicaID: issuerID ?? old.issuerReplicaID, bootstrapReplicaID: id(), pairingID: id(),
            endpoints: old.endpoints, expiresAt: old.expiresAt + 100,
            expectedMembershipDigest: old.expectedMembershipDigest, unusedFamilyID: familyID ?? old.familyID),
            secret: .generate())
    }
    /// Fingerprints allow unchanged-private-file assertions without printing private blobs.
    private func fingerprints(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let directory = root.appendingPathComponent(".personal-enrollment")
        if FileManager.default.fileExists(atPath: directory.path) {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    result[file.lastPathComponent] = PersonalSyncValidation.digest(try Data(contentsOf: file))
                }
            }
        }
        for name in [PersonalSyncConfiguration.membershipName, PersonalSyncConfiguration.pendingName,
            PersonalSyncConfiguration.baselineName] {
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                result[name] = PersonalSyncValidation.digest(try Data(contentsOf: file))
            }
        }
        return result
    }
    private func continuationFingerprint(_ claim: PersonalEnrollmentClaim) -> String {
        claim.continuationSecret.withBytes { PersonalSyncValidation.digest(Data($0)) }
    }
    /// Models the host's explicit successful-authentication input, not a network event.
    private func authorizedContinuation(_ metadata: PersonalEnrollmentInvitationMetadata,
        claim: PersonalEnrollmentClaim) throws -> PeerExchangeBinding {
        try PersonalEnrollmentPeerMaterial.continuation(invitation: metadata, claim: claim,
            localIsIssuer: false).binding
    }
    private func rejectUnchanged(_ store: ItemStore, _ body: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try fingerprints(store.root)
        XCTAssertThrowsError(try body(), file: file, line: line)
        XCTAssertEqual(try fingerprints(store.root), before, file: file, line: line)
    }

    private final class RenewalFixture {
        let parent: URL
        let accounts: Accounts
        let source: ItemStore
        var target: ItemStore?
        let issuer: PersonalEnrollmentRegistry
        let authorization: PersonalEnrollmentLocalAuthorization
        let invitations: [PersonalEnrollmentInvitation]
        let registry: PersonalEnrollmentTargetRegistry
        init(parent: URL, accounts: Accounts, source: ItemStore, target: ItemStore,
            issuer: PersonalEnrollmentRegistry, authorization: PersonalEnrollmentLocalAuthorization,
            invitations: [PersonalEnrollmentInvitation]) {
            self.parent = parent; self.accounts = accounts; self.source = source; self.target = target
            self.issuer = issuer; self.authorization = authorization; self.invitations = invitations
            registry = .init(root: target.root)
        }
    }
    private func renewalFixture(_ body: (RenewalFixture) throws -> Void) throws {
        try fixture { parent, accounts in
            let source = try makeSource(parent, accounts: accounts), authorization = try authorize(source)
            let issuer = PersonalEnrollmentRegistry(root: source.root, ownerUID: tractanda_uid())
            let first = try issue(issuer, authorization, at: 1_000)
            var target: ItemStore? = try makeTarget(parent, accounts: accounts, storeID: first.metadata.storeID)
            let registry = PersonalEnrollmentTargetRegistry(root: target!.root)
            _ = try registry.begin(store: target!, forUID: tractanda_uid(), invitation: first, hostname: "target.fixture")
            let second = try issue(issuer, authorization, at: 1_010)
            _ = try registry.beginReplacement(store: target!, forUID: tractanda_uid(), invitation: second,
                hostname: "target.fixture", now: 1_011)
            let third = try issue(issuer, authorization, at: 1_020)
            _ = try registry.beginReplacement(store: target!, forUID: tractanda_uid(), invitation: third,
                hostname: "target.fixture", now: 1_021)
            let values = RenewalFixture(parent: parent, accounts: accounts, source: source, target: target!,
                issuer: issuer, authorization: authorization, invitations: [first, second, third])
            target = nil
            try body(values)
        }
    }
    /// This is a labelled Core host-proof seam. Real TLS proof construction/consumption
    /// is covered by PersonalEnrollmentRenewalRuntimeTests, not by this binding factory.
    private func modelledRenewalBinding(_ invitation: PersonalEnrollmentInvitation) throws -> PeerExchangeBinding {
        try PersonalEnrollmentPeerMaterial.invitation(invitation, localIsIssuer: false).binding
    }
    private func seedCanonicalContent(_ root: URL) throws {
        let record = try Revision(fields: ["itemID": .text(id()), "revisionID": .text(id()),
            "classID": .text("Item"), "schemaVersion": .integer(1), "actor": .text("user:admin"),
            "operationID": .text(id()), "requestIdentity": .text("occupied renewal fixture"),
            "createdAt": .date("2026-10-26T00:00:00Z"), "modifiedAt": .date("2026-10-26T00:00:00Z"),
            "permissions": .object(["profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:])]), "subject": .text("retain content")])
        try DocumentContentFiles(root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 10 * 1024 * 1024 * 1024)
            .writeImmutable(RecordCodec.encode(record), path: ["items", "2026", "10", "26", "00", "00",
                record.itemID, record.revisionID + ".tractanda"], maximumBytes: 1024 * 1024)
    }

    func testSuccessiveExpiredUnusedInvitationsKeepStableFamilyAndFreshOperationMetadata() throws {
        try fixture { parent, accounts in
            let store = try makeSource(parent, accounts: accounts), authorization = try authorize(store)
            let registry = PersonalEnrollmentRegistry(root: store.root, ownerUID: tractanda_uid())
            let first = try issue(registry, authorization, at: 1_000)
            let firstMetadata = first.metadata
            let second = try issue(registry, authorization, at: 1_010)
            let third = try issue(registry, authorization, at: 1_020)
            XCTAssertEqual(first.metadata, firstMetadata)
            XCTAssertEqual(second.metadata.familyID, first.metadata.familyID)
            XCTAssertEqual(third.metadata.familyID, first.metadata.familyID)
            XCTAssertEqual(Set([first.metadata.operationID, second.metadata.operationID, third.metadata.operationID]).count, 3)
            XCTAssertEqual(Set([first.metadata.pairingID, second.metadata.pairingID, third.metadata.pairingID]).count, 3)
            XCTAssertEqual(Set([first.metadata.bootstrapReplicaID, second.metadata.bootstrapReplicaID, third.metadata.bootstrapReplicaID]).count, 3)
            XCTAssertFalse(first.secret.withBytes { $0 } == second.secret.withBytes { $0 }, "Renewal must generate a fresh private key.")
            XCTAssertFalse(second.secret.withBytes { $0 } == third.secret.withBytes { $0 }, "Renewal must generate a fresh private key.")
            XCTAssertEqual(try registry.runtimeStatus()?.invitation, third.metadata)
        }
    }

    func testClaimPreparedAndCommittedIssuerRefuseRenewalThenCompletionStartsFreshFamily() throws {
        try fixture { parent, accounts in
            let source = try makeSource(parent, accounts: accounts), authorization = try authorize(source)
            let registry = PersonalEnrollmentRegistry(root: source.root, ownerUID: tractanda_uid())
            let invitation = try issue(registry, authorization, at: 1_000)
            let target = try makeTarget(parent, accounts: accounts, storeID: invitation.metadata.storeID)
            let targetID = try target.personalSyncIdentity().replicaID
            let selection = try target.startPersonalBaseline(sourceReplicaID: invitation.metadata.issuerReplicaID)
            let claim = PersonalEnrollmentClaim(metadata: .init(operationID: invitation.metadata.operationID,
                targetReplicaID: targetID, targetHostname: "target.fixture", continuationPairingID: try id()),
                continuationSecret: try .generate())
            _ = try registry.claim(claim, authenticatedInvitation: invitation.metadata, authorization: authorization, now: 1_001)
            try rejectUnchanged(source) { _ = try issue(registry, authorization, at: 2_000) }
            let config = try PersonalMembershipConfiguration(storeID: invitation.metadata.storeID,
                configurationID: id(), members: [
                    .init(replicaID: invitation.metadata.issuerReplicaID, hostname: "issuer.fixture"),
                    .init(replicaID: targetID, hostname: "target.fixture"),
                ])
            try registry.stageMembershipProposal(authorization: authorization, configuration: config)
            let nonce = try id(), pairing = try id(), digest = try config.digest
            let sourcePreparation = try source.preparePersonalMembershipChange(configuration: config, expectedDigest: nil, nonce: nonce)
            let targetPreparation = try target.preparePersonalMembershipChange(configuration: config, expectedDigest: nil, nonce: nonce)
            try rejectUnchanged(source) { _ = try issue(registry, authorization, at: 2_000) }
            let outward = try PeerExchangeBinding(peerID: "target", storeID: config.storeID,
                localReplicaID: invitation.metadata.issuerReplicaID, remoteReplicaID: targetID, pairingID: pairing,
                localIsInitiator: true, configurationDigest: digest)
            let inward = try PeerExchangeBinding(peerID: "source", storeID: config.storeID,
                localReplicaID: targetID, remoteReplicaID: invitation.metadata.issuerReplicaID, pairingID: pairing,
                localIsInitiator: false, configurationDigest: digest)
            let syntheticKey = [UInt8](repeating: 0x67, count: 32)
            try source.registerPersonalPeerCredentials([.init(binding: outward, secret: syntheticKey)], configuration: config)
            try target.registerPersonalPeerCredentials([.init(binding: inward, secret: syntheticKey)], configuration: config)
            // Explicit Core online-ack seams; these are state-machine unit inputs, not TLS claims.
            _ = try source.commitPersonalMembershipChange(preparation: sourcePreparation, acknowledgements: [
                .init(binding: outward, response: target.personalMembershipReady(session: inward, preparation: sourcePreparation),
                    control: .commitCompletion()),
            ])
            _ = try target.commitPersonalMembershipChange(preparation: targetPreparation, acknowledgements: [
                .init(binding: inward, response: source.personalMembershipReady(session: outward, preparation: targetPreparation),
                    control: .commitCompletion()),
            ])
            let jobGeneration = UUID()
            let initial = try PersonalEnrollmentCompletedCut(binding: inward, selectionID: selection,
                jobGeneration: jobGeneration, ordinal: 1, sourceCatalogueGeneration: "replacement-empty-fixture", cutRowID: 0)
            let rescan = try PersonalEnrollmentCompletedCut(binding: inward, selectionID: selection,
                jobGeneration: jobGeneration, ordinal: 2, sourceCatalogueGeneration: "replacement-empty-fixture", cutRowID: 0)
            // These explicit bounded Core completion inputs are not a network/cut certification.
            try target.finishPersonalBaseline(selectionID: selection, actorUID: tractanda_uid(),
                readiness: .observed(first: initial, rescan: rescan))
            XCTAssertFalse(target.isPersonalBaselinePending)
            let committedAuthorization = try authorize(source)
            try rejectUnchanged(source) { _ = try issue(registry, committedAuthorization, at: 2_000) }
            XCTAssertEqual(try registry.runtimeStatus()?.invitation, invitation.metadata)
            try registry.finish(authorization: committedAuthorization, operationID: invitation.metadata.operationID, cancelled: false)
            let next = try issue(registry, committedAuthorization, at: 2_000)
            XCTAssertNotEqual(next.metadata.familyID, invitation.metadata.familyID)
            XCTAssertEqual(next.metadata.familyID, next.metadata.operationID)
        }
    }

    func testStagedCandidatePreservesOldContinuationAndReopenOrValidationNeverPromotes() throws {
        try fixture { parent, accounts in
            let source = try makeSource(parent, accounts: accounts), authorization = try authorize(source)
            let issuer = PersonalEnrollmentRegistry(root: source.root, ownerUID: tractanda_uid())
            let first = try issue(issuer, authorization, at: 1_000), second = try issue(issuer, authorization, at: 1_010)
            var target: ItemStore? = try makeTarget(parent, accounts: accounts, storeID: first.metadata.storeID)
            let root = target!.root, registry = PersonalEnrollmentTargetRegistry(root: root)
            let old = try registry.begin(store: target!, forUID: tractanda_uid(), invitation: first, hostname: "target.fixture")
            let oldMaterial = try XCTUnwrap(registry.runtimeMaterial(store: target!))
            let oldFingerprint = continuationFingerprint(try XCTUnwrap(oldMaterial.2))
            let targetFingerprint = try fingerprints(root)["target.bin"]
            let staged = try registry.beginReplacement(store: target!, forUID: tractanda_uid(), invitation: second,
                hostname: "target.fixture", now: 1_011)
            let candidate = try XCTUnwrap(registry.replacementRuntimeMaterial(store: target!))
            let candidateFingerprint = continuationFingerprint(try XCTUnwrap(candidate.2))
            XCTAssertNotEqual(oldFingerprint, candidateFingerprint)
            XCTAssertEqual(try fingerprints(root)["target.bin"], targetFingerprint)
            XCTAssertEqual(try registry.runtimeMaterial(store: target!)?.0, old)
            let beforeLoad = try fingerprints(root)
            _ = try registry.replacementStatus(store: target!)
            _ = try registry.replacementRuntimeMaterial(store: target!)
            try target!.personalEnrollmentValidateTransport(authorizedContinuation(second.metadata,
                claim: XCTUnwrap(candidate.2)), purpose: .continuation, now: 1_011)
            XCTAssertEqual(try fingerprints(root), beforeLoad)
            XCTAssertEqual(try registry.status(store: target!, forUID: tractanda_uid())?.phase, .claiming)
            target = nil
            target = try ItemStore.openInitialized(root: root, indexDirectory: parent.appendingPathComponent("target-index"), accounts: accounts)
            let reopened = PersonalEnrollmentTargetRegistry(root: root)
            XCTAssertEqual(try reopened.runtimeMaterial(store: target!)?.0, old)
            XCTAssertTrue(try XCTUnwrap(reopened.runtimeMaterial(store: target!)?.1).secret.withBytes { $0 }
                == first.secret.withBytes { $0 }, "Staging and reopen must retain the original private invitation.")
            XCTAssertEqual(try reopened.replacementRuntimeMaterial(store: target!)?.0, staged)
            XCTAssertEqual(continuationFingerprint(try XCTUnwrap(reopened.runtimeMaterial(store: target!)?.2)), oldFingerprint)
            XCTAssertEqual(continuationFingerprint(try XCTUnwrap(reopened.replacementRuntimeMaterial(store: target!)?.2)), candidateFingerprint)
            XCTAssertEqual(try fingerprints(root), beforeLoad)
        }
    }

    func testWrongFamilyStoreIssuerAndHostnameRefuseWithoutChangingPrivateFiles() throws {
        try fixture { parent, accounts in
            let source = try makeSource(parent, accounts: accounts), authorization = try authorize(source)
            let issuer = PersonalEnrollmentRegistry(root: source.root, ownerUID: tractanda_uid())
            let first = try issue(issuer, authorization, at: 1_000), second = try issue(issuer, authorization, at: 1_010)
            let target = try makeTarget(parent, accounts: accounts, storeID: first.metadata.storeID)
            let registry = PersonalEnrollmentTargetRegistry(root: target.root)
            _ = try registry.begin(store: target, forUID: tractanda_uid(), invitation: first, hostname: "target.fixture")
            for invalid in [try changedInvitation(second, familyID: id()), try changedInvitation(second, storeID: id()),
                try changedInvitation(second, issuerID: id())] {
                try rejectUnchanged(target) { _ = try registry.beginReplacement(store: target, forUID: tractanda_uid(),
                    invitation: invalid, hostname: "target.fixture", now: 1_011) }
            }
            try rejectUnchanged(target) { _ = try registry.beginReplacement(store: target, forUID: tractanda_uid(),
                invitation: second, hostname: "different.fixture", now: 1_011) }
            try rejectUnchanged(target) { _ = try registry.beginReplacement(store: target, forUID: tractanda_uid(),
                invitation: second, hostname: "target.fixture", now: 1_009) }
        }
    }

    func testAcceptedPlanPendingMembershipBaselineAndContentRefuseReplacementUnchanged() throws {
        for occupied in ["acceptedPlan", "pending", "membership", "baseline", "content"] {
            try fixture { parent, accounts in
                let source = try makeSource(parent, accounts: accounts), authorization = try authorize(source)
                let issuer = PersonalEnrollmentRegistry(root: source.root, ownerUID: tractanda_uid())
                let first = try issue(issuer, authorization, at: 1_000), second = try issue(issuer, authorization, at: 1_010)
                var target: ItemStore? = try makeTarget(parent, accounts: accounts, storeID: first.metadata.storeID)
                let root = target!.root, registry = PersonalEnrollmentTargetRegistry(root: root)
                let original = try registry.begin(store: target!, forUID: tractanda_uid(), invitation: first, hostname: "target.fixture")
                let config = try PersonalMembershipConfiguration(storeID: first.metadata.storeID, configurationID: id(), members: [
                    .init(replicaID: first.metadata.issuerReplicaID, hostname: "issuer.fixture"),
                    .init(replicaID: original.claim.targetReplicaID, hostname: "target.fixture"),
                ])
                switch occupied {
                case "acceptedPlan":
                    let claim = try XCTUnwrap(registry.runtimeMaterial(store: target!)?.2)
                    let proof = try authorizedContinuation(first.metadata, claim: claim)
                    try registry.continuationAccepted(store: target!, binding: proof)
                    let admission = try PersonalEnrollmentAdmission(configuration: AccessConfiguration(policy))
                    let plan = PersonalEnrollmentPlan(operationID: first.metadata.operationID,
                        issuerReplicaID: first.metadata.issuerReplicaID, administrator: "admin", nonce: try id(),
                        previousMembership: nil, configuration: config, admission: admission,
                        endpoints: [first.metadata.issuerReplicaID: first.metadata.endpoints,
                            original.claim.targetReplicaID: [try .init(host: "target.fixture", port: 48732)]])
                    try registry.acceptRuntimePlan(store: target!, binding: proof, plan: plan)
                case "pending":
                    _ = try target!.preparePersonalMembershipChange(configuration: config, expectedDigest: nil, nonce: id())
                case "membership":
                    try PersonalSyncConfiguration.write(config, root: root, name: PersonalSyncConfiguration.membershipName)
                case "baseline":
                    _ = try target!.startPersonalBaseline(sourceReplicaID: first.metadata.issuerReplicaID)
                default:
                    // Deliberately seed one canonical fixture record while closed, then
                    // rebuild on reopen. This is not an enrollment/content admission path.
                    target = nil
                    let record = try Revision(fields: ["itemID": .text(id()), "revisionID": .text(id()),
                        "classID": .text("Item"), "schemaVersion": .integer(1),
                        "actor": .text("user:admin"), "operationID": .text(id()), "requestIdentity": .text("occupied fixture"),
                        "createdAt": .date("2026-10-26T00:00:00Z"), "modifiedAt": .date("2026-10-26T00:00:00Z"),
                        "subject": .text("must not adopt"), "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("admin"), "group": .text("staff"),
                            "mode": .integer(0o600), "acl": .object([:]),
                        ])])
                    try DocumentContentFiles(root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 10 * 1024 * 1024 * 1024)
                        .writeImmutable(RecordCodec.encode(record), path: ["items", "2026", "10", "26", "00", "00",
                            record.itemID, record.revisionID + ".tractanda"], maximumBytes: 1024 * 1024)
                    target = try ItemStore.openInitialized(root: root, indexDirectory: parent.appendingPathComponent("target-index"), accounts: accounts)
                }
                try rejectUnchanged(target!) { _ = try registry.beginReplacement(store: target!, forUID: tractanda_uid(),
                    invitation: second, hostname: "target.fixture", now: 1_011) }
            }
        }
    }

    func testLostNewClaimReplyResumesSameCandidateContinuation() throws {
        try fixture { parent, accounts in
            let source = try makeSource(parent, accounts: accounts), authorization = try authorize(source)
            let issuer = PersonalEnrollmentRegistry(root: source.root, ownerUID: tractanda_uid())
            let first = try issue(issuer, authorization, at: 1_000), second = try issue(issuer, authorization, at: 1_010)
            var target: ItemStore? = try makeTarget(parent, accounts: accounts, storeID: first.metadata.storeID)
            let root = target!.root, registry = PersonalEnrollmentTargetRegistry(root: root)
            _ = try registry.begin(store: target!, forUID: tractanda_uid(), invitation: first, hostname: "target.fixture")
            let candidate = try registry.beginReplacement(store: target!, forUID: tractanda_uid(), invitation: second,
                hostname: "target.fixture", now: 1_011)
            let claim = try XCTUnwrap(registry.replacementRuntimeMaterial(store: target!)?.2)
            let fingerprint = continuationFingerprint(claim)
            _ = try issuer.claim(claim, authenticatedInvitation: second.metadata, authorization: authorization, now: 1_011)
            let before = try fingerprints(root)
            target = nil
            target = try ItemStore.openInitialized(root: root, indexDirectory: parent.appendingPathComponent("target-index"), accounts: accounts)
            XCTAssertEqual(try registry.beginReplacement(store: target!, forUID: tractanda_uid(), invitation: second,
                hostname: "target.fixture", now: 1_012), candidate)
            XCTAssertEqual(continuationFingerprint(try XCTUnwrap(registry.replacementRuntimeMaterial(store: target!)?.2)), fingerprint)
            XCTAssertEqual(continuationFingerprint(try XCTUnwrap(issuer.continuationCredential())), fingerprint)
            XCTAssertEqual(try fingerprints(root), before)
            XCTAssertEqual(try registry.status(store: target!, forUID: tractanda_uid())?.phase, .claiming)
        }
    }

    func testExpiredPendingCandidateStagesProbeWithoutDiscardingUncertainContinuation() throws {
        try fixture { parent, accounts in
            let source = try makeSource(parent, accounts: accounts), authorization = try authorize(source)
            let issuer = PersonalEnrollmentRegistry(root: source.root, ownerUID: tractanda_uid())
            let first = try issue(issuer, authorization, at: 1_000), second = try issue(issuer, authorization, at: 1_010)
            let target = try makeTarget(parent, accounts: accounts, storeID: first.metadata.storeID)
            let registry = PersonalEnrollmentTargetRegistry(root: target.root)
            _ = try registry.begin(store: target, forUID: tractanda_uid(), invitation: first, hostname: "target.fixture")
            let pending = try registry.beginReplacement(store: target, forUID: tractanda_uid(), invitation: second,
                hostname: "target.fixture", now: 1_011)
            let before = try fingerprints(target.root)
            let oldKey = continuationFingerprint(try XCTUnwrap(registry.runtimeMaterial(store: target)?.2))
            let pendingKey = continuationFingerprint(try XCTUnwrap(registry.replacementRuntimeMaterial(store: target)?.2))
            let premature = try changedInvitation(second)
            try rejectUnchanged(target) { _ = try registry.beginReplacement(store: target, forUID: tractanda_uid(),
                invitation: premature, hostname: "target.fixture", now: 1_019) }
            let third = try issue(issuer, authorization, at: 1_020)
            XCTAssertEqual(try registry.beginReplacement(store: target, forUID: tractanda_uid(), invitation: third,
                hostname: "target.fixture", now: 1_021), pending)
            XCTAssertEqual(try registry.renewalStatus(store: target)?.invitation, third.metadata)
            let after = try fingerprints(target.root)
            XCTAssertEqual(after["target.bin"], before["target.bin"])
            XCTAssertEqual(after["replacement.bin"], before["replacement.bin"])
            XCTAssertNotNil(after["renewal.bin"])
            XCTAssertEqual(continuationFingerprint(try XCTUnwrap(registry.runtimeMaterial(store: target)?.2)), oldKey)
            XCTAssertEqual(continuationFingerprint(try XCTUnwrap(registry.replacementRuntimeMaterial(store: target)?.2)), pendingKey)
        }
    }

    func testPublicationFaultReplaysCleanupWithoutDuplicatePrivateContexts() throws {
        try fixture { parent, accounts in
            let source = try makeSource(parent, accounts: accounts), authorization = try authorize(source)
            let issuer = PersonalEnrollmentRegistry(root: source.root, ownerUID: tractanda_uid())
            let first = try issue(issuer, authorization, at: 1_000), second = try issue(issuer, authorization, at: 1_010)
            var target: ItemStore? = try makeTarget(parent, accounts: accounts, storeID: first.metadata.storeID)
            let root = target!.root, registry = PersonalEnrollmentTargetRegistry(root: root)
            _ = try registry.begin(store: target!, forUID: tractanda_uid(), invitation: first, hostname: "target.fixture")
            let candidate = try registry.beginReplacement(store: target!, forUID: tractanda_uid(), invitation: second,
                hostname: "target.fixture", now: 1_011)
            let claim = try XCTUnwrap(registry.replacementRuntimeMaterial(store: target!)?.2)
            _ = try issuer.claim(claim, authenticatedInvitation: second.metadata, authorization: authorization, now: 1_011)
            let proof = try authorizedContinuation(second.metadata, claim: claim)
            XCTAssertThrowsError(try registry.promoteReplacement(store: target!, binding: proof,
                afterPublication: { throw TractandaError("fixtureFault", "After target publication, before candidate cleanup") })) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "fixtureFault")
            }
            XCTAssertEqual(try registry.runtimeMaterial(store: target!)?.0.invitation, candidate.invitation)
            XCTAssertEqual(try registry.runtimeMaterial(store: target!)?.0.phase, .claimed)
            XCTAssertNotNil(try registry.replacementStatus(store: target!))
            let afterPublication = try fingerprints(root)
            XCTAssertNil(try registry.replacementRuntimeMaterial(store: target!))
            XCTAssertEqual(try fingerprints(root), afterPublication)
            let material = try target!.personalEnrollmentRuntimeMaterial(now: 1_012)
            XCTAssertEqual(material.privatePeers.filter { $0.purpose == .continuation }.count, 1)
            XCTAssertEqual(Set(material.privatePeers.map { $0.binding.pairingID }).count, material.privatePeers.count)
            target = nil
            target = try ItemStore.openInitialized(root: root, indexDirectory: parent.appendingPathComponent("target-index"), accounts: accounts)
            XCTAssertTrue(try registry.cleanupAcceptedReplacement(store: target!))
            try registry.continuationAccepted(store: target!, binding: proof)
            XCTAssertFalse(try registry.cleanupAcceptedReplacement(store: target!))
            XCTAssertNil(try registry.replacementStatus(store: target!))
            XCTAssertEqual(continuationFingerprint(try XCTUnwrap(registry.runtimeMaterial(store: target!)?.2)), continuationFingerprint(claim))
            let replayed = try target!.personalEnrollmentRuntimeMaterial(now: 1_012)
            XCTAssertEqual(replayed.privatePeers.filter { $0.purpose == .continuation }.count, 1)
        }
    }

    func testMalformedOrForeignCandidateCannotOverrideAnAcceptedCurrentRecord() throws {
        try fixture { parent, accounts in
            let source = try makeSource(parent, accounts: accounts), authorization = try authorize(source)
            let issuer = PersonalEnrollmentRegistry(root: source.root, ownerUID: tractanda_uid())
            let first = try issue(issuer, authorization, at: 1_000)
            let target = try makeTarget(parent, accounts: accounts, storeID: first.metadata.storeID)
            let registry = PersonalEnrollmentTargetRegistry(root: target.root)
            _ = try registry.begin(store: target, forUID: tractanda_uid(), invitation: first, hostname: "target.fixture")
            let acceptedClaim = try XCTUnwrap(registry.runtimeMaterial(store: target)?.2)
            try registry.continuationAccepted(store: target, binding: authorizedContinuation(first.metadata, claim: acceptedClaim))
            let acceptedFingerprint = try fingerprints(target.root)["target.bin"]
            let files = PersonalEnrollmentStateFiles(root: target.root)
            try files.replace("replacement.bin", bytes: Data("malformed candidate".utf8), expected: nil)
            XCTAssertThrowsError(try registry.replacementRuntimeMaterial(store: target))
            XCTAssertEqual(try fingerprints(target.root)["target.bin"], acceptedFingerprint)
            let foreign = try changedInvitation(first, familyID: id())
            let status = PersonalEnrollmentTargetStatus(invitation: foreign.metadata,
                claim: .init(operationID: foreign.metadata.operationID, targetReplicaID: acceptedClaim.metadata.targetReplicaID,
                    targetHostname: "target.fixture", continuationPairingID: try id()), administrator: "admin", phase: .claiming,
                provisionalAdmissionDigest: try XCTUnwrap(registry.runtimeMaterial(store: target)?.0.provisionalAdmissionDigest))
            let secret = try PersonalEnrollmentSecret.generate()
            let encoded = try PersonalEnrollmentPrivateCodec.encode(status, secret: nil,
                maximumHeaderBytes: PersonalEnrollmentPrivateCodec.operationHeaderBytes)
                + foreign.secret.withBytes { Data($0) } + secret.withBytes { Data($0) }
            try files.replace("replacement.bin", bytes: encoded, expected: files.read("replacement.bin"))
            let forged = PersonalEnrollmentClaim(metadata: status.claim, continuationSecret: secret)
            let before = try fingerprints(target.root)
            XCTAssertThrowsError(try registry.promoteReplacement(store: target,
                binding: authorizedContinuation(foreign.metadata, claim: forged)))
            XCTAssertEqual(try fingerprints(target.root), before)
            XCTAssertEqual(try fingerprints(target.root)["target.bin"], acceptedFingerprint)
            XCTAssertEqual(try registry.runtimeMaterial(store: target)?.0.phase, .claimed)
            // Even identical invitation metadata cannot hide a different candidate
            // claim as though it were the accepted publication's cleanup duplicate.
            let substituted = PersonalEnrollmentTargetStatus(invitation: first.metadata,
                claim: .init(operationID: first.metadata.operationID, targetReplicaID: acceptedClaim.metadata.targetReplicaID,
                    targetHostname: "target.fixture", continuationPairingID: try id()), administrator: "admin", phase: .claiming,
                provisionalAdmissionDigest: status.provisionalAdmissionDigest)
            let substitutedBytes = try PersonalEnrollmentPrivateCodec.encode(substituted, secret: nil,
                maximumHeaderBytes: PersonalEnrollmentPrivateCodec.operationHeaderBytes)
                + first.secret.withBytes { Data($0) } + secret.withBytes { Data($0) }
            try files.replace("replacement.bin", bytes: substitutedBytes, expected: files.read("replacement.bin"))
            let beforeSubstitution = try fingerprints(target.root)
            XCTAssertThrowsError(try registry.replacementRuntimeMaterial(store: target))
            XCTAssertFalse(try registry.cleanupAcceptedReplacement(store: target))
            XCTAssertEqual(try fingerprints(target.root), beforeSubstitution)
            XCTAssertEqual(try fingerprints(target.root)["target.bin"], acceptedFingerprint)
        }
    }
    func testRepeatedRenewalProbeRotationAndPureReadsKeepOnlyOldContinuations() throws {
        try renewalFixture { f in
            let root = f.target!.root
            let originalKey = continuationFingerprint(try XCTUnwrap(f.registry.runtimeMaterial(store: f.target!)?.2))
            let pendingKey = continuationFingerprint(try XCTUnwrap(f.registry.replacementRuntimeMaterial(store: f.target!)?.2))
            let retainedFiles = try fingerprints(root)
            for (time, sequence) in [(Int64(1_030), 4), (Int64(1_040), 5)] {
                let invitation = try issue(f.issuer, f.authorization, at: time)
                _ = try f.registry.beginReplacement(store: f.target!, forUID: tractanda_uid(), invitation: invitation,
                    hostname: "target.fixture", now: time + 1)
                XCTAssertEqual(try f.registry.renewalStatus(store: f.target!)?.invitation, invitation.metadata)
                let beforeRead = try fingerprints(root)
                _ = try f.registry.renewalRuntimeMaterial(store: f.target!)
                _ = try f.registry.replacementRuntimeMaterial(store: f.target!)
                try f.target!.personalEnrollmentValidateTransport(modelledRenewalBinding(invitation), purpose: .invitation, now: time + 1)
                XCTAssertEqual(try fingerprints(root), beforeRead)
                XCTAssertEqual(beforeRead["target.bin"], retainedFiles["target.bin"])
                XCTAssertEqual(beforeRead["replacement.bin"], retainedFiles["replacement.bin"])
                XCTAssertEqual(continuationFingerprint(try XCTUnwrap(f.registry.runtimeMaterial(store: f.target!)?.2)), originalKey)
                XCTAssertEqual(continuationFingerprint(try XCTUnwrap(f.registry.replacementRuntimeMaterial(store: f.target!)?.2)), pendingKey)
                let runtime = try f.target!.personalEnrollmentRuntimeMaterial(now: time + 1)
                XCTAssertEqual(runtime.privatePeers.count, 3)
                XCTAssertEqual(runtime.privatePeers.filter { $0.purpose == .continuation }.count, 2)
                XCTAssertEqual(runtime.privatePeers.filter { $0.purpose == .invitation }.count, 1)
                XCTAssertEqual(Set(runtime.privatePeers.map { $0.binding.pairingID }).count, 3)
                let bytes = try XCTUnwrap(PersonalEnrollmentStateFiles(root: root).read("renewal.bin"))
                let (_, suffix) = try PersonalEnrollmentPrivateCodec.decodeHeader(PersonalEnrollmentRenewalStatus.self,
                    bytes: bytes, secretCount: 32)
                XCTAssertEqual(suffix.count, 32, "A probe stores one invitation secret, not a continuation chain.")
                XCTAssertLessThanOrEqual(beforeRead.count, 3, "Probe rotation must not grow durable history (rotation \(sequence)).")
            }
        }
    }

    func testOnlyModelledAuthenticatedRenewalCreatesFreshCandidateAndCancelledControlDoesNot() throws {
        try renewalFixture { f in
            let root = f.target!.root, probe = f.invitations[2]
            let binding = try modelledRenewalBinding(probe)
            let before = try fingerprints(root)
            let original = continuationFingerprint(try XCTUnwrap(f.registry.runtimeMaterial(store: f.target!)?.2))
            let previous = continuationFingerprint(try XCTUnwrap(f.registry.replacementRuntimeMaterial(store: f.target!)?.2))
            let cancelled = PeerExchangeControl.commitCompletion(); cancelled.cancel()
            try rejectUnchanged(f.target!) {
                try f.registry.acceptAuthenticatedRenewal(store: f.target!, binding: binding, control: cancelled)
            }
            XCTAssertEqual(try fingerprints(root), before)
            // Explicit synthetic Core authorization input; this is not an actual ready proof.
            try f.registry.acceptAuthenticatedRenewal(store: f.target!, binding: binding, control: .commitCompletion())
            XCTAssertEqual(try f.registry.replacementStatus(store: f.target!)?.invitation, probe.metadata)
            XCTAssertNil(try f.registry.renewalStatus(store: f.target!))
            XCTAssertEqual(continuationFingerprint(try XCTUnwrap(f.registry.runtimeMaterial(store: f.target!)?.2)), original)
            XCTAssertNotEqual(continuationFingerprint(try XCTUnwrap(f.registry.replacementRuntimeMaterial(store: f.target!)?.2)), previous)
            XCTAssertEqual(try fingerprints(root)["target.bin"], before["target.bin"])
        }
    }

    func testRenewalPublicationFaultReopensAndCleansWithoutRegeneratingCandidate() throws {
        try renewalFixture { f in
            let root = f.target!.root, probe = f.invitations[2]
            let before = try fingerprints(root)
            let binding = try modelledRenewalBinding(probe)
            XCTAssertThrowsError(try f.registry.acceptAuthenticatedRenewal(store: f.target!, binding: binding,
                control: .commitCompletion(), afterPublication: { throw TractandaError("fixtureFault", "After candidate publication") })) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "fixtureFault")
            }
            let acceptedKey = continuationFingerprint(try XCTUnwrap(f.registry.replacementRuntimeMaterial(store: f.target!)?.2))
            XCTAssertEqual(try f.registry.replacementStatus(store: f.target!)?.invitation, probe.metadata)
            XCTAssertNotNil(try f.registry.renewalStatus(store: f.target!))
            let afterPublication = try fingerprints(root)
            _ = try f.registry.renewalRuntimeMaterial(store: f.target!)
            XCTAssertEqual(try fingerprints(root), afterPublication)
            XCTAssertEqual(afterPublication["target.bin"], before["target.bin"])
            f.target = nil
            f.target = try ItemStore.openInitialized(root: root, indexDirectory: f.parent.appendingPathComponent("target-index"), accounts: f.accounts)
            XCTAssertNotNil(try f.registry.renewalStatus(store: f.target!))
            XCTAssertEqual(continuationFingerprint(try XCTUnwrap(f.registry.replacementRuntimeMaterial(store: f.target!)?.2)), acceptedKey)
            XCTAssertTrue(try f.registry.cleanupConfirmedRenewal(store: f.target!))
            XCTAssertFalse(try f.registry.cleanupConfirmedRenewal(store: f.target!))
            XCTAssertNil(try f.registry.renewalStatus(store: f.target!))
            XCTAssertEqual(continuationFingerprint(try XCTUnwrap(f.registry.replacementRuntimeMaterial(store: f.target!)?.2)), acceptedKey)
            let runtime = try f.target!.personalEnrollmentRuntimeMaterial(now: 1_022)
            XCTAssertEqual(runtime.privatePeers.count, 3)
            XCTAssertEqual(Set(runtime.privatePeers.map { $0.binding.pairingID }).count, 3)
        }
    }

    func testWrongBindingForeignRenewalAndOccupiedTargetCannotPublish() throws {
        for invalid in ["binding", "family", "issuer", "store", "pending", "membership", "baseline", "content"] {
            try renewalFixture { f in
                let root = f.target!.root
                var probe = f.invitations[2]
                if ["family", "issuer", "store"].contains(invalid) {
                    probe = try changedInvitation(probe, storeID: invalid == "store" ? id() : nil,
                        issuerID: invalid == "issuer" ? id() : nil, familyID: invalid == "family" ? id() : nil)
                    let status = PersonalEnrollmentRenewalStatus(invitation: probe.metadata, administrator: "admin", hostname: "target.fixture")
                    let files = PersonalEnrollmentStateFiles(root: root)
                    try files.replace("renewal.bin", bytes: PersonalEnrollmentPrivateCodec.encode(status, secret: probe.secret),
                        expected: files.read("renewal.bin"))
                }
                let targetID = try f.target!.personalSyncIdentity().replicaID
                let config = try PersonalMembershipConfiguration(storeID: f.invitations[0].metadata.storeID,
                    configurationID: id(), members: [
                        .init(replicaID: f.invitations[0].metadata.issuerReplicaID, hostname: "issuer.fixture"),
                        .init(replicaID: targetID, hostname: "target.fixture"),
                    ])
                switch invalid {
                case "pending": _ = try f.target!.preparePersonalMembershipChange(configuration: config, expectedDigest: nil, nonce: id())
                case "membership": try PersonalSyncConfiguration.write(config, root: root, name: PersonalSyncConfiguration.membershipName)
                case "baseline": _ = try f.target!.startPersonalBaseline(sourceReplicaID: f.invitations[0].metadata.issuerReplicaID)
                case "content":
                    f.target = nil; try seedCanonicalContent(root)
                    f.target = try ItemStore.openInitialized(root: root, indexDirectory: f.parent.appendingPathComponent("target-index"), accounts: f.accounts)
                default: break
                }
                var binding = try modelledRenewalBinding(probe)
                if invalid == "binding" {
                    binding = try .init(peerID: binding.peerID, storeID: binding.storeID,
                        localReplicaID: binding.localReplicaID, remoteReplicaID: binding.remoteReplicaID,
                        pairingID: id(), localIsInitiator: binding.localIsInitiator, configurationDigest: binding.configurationDigest)
                }
                try rejectUnchanged(f.target!) {
                    try f.registry.acceptAuthenticatedRenewal(store: f.target!, binding: binding, control: .commitCompletion())
                }
            }
        }
    }

    func testConfirmedOriginalOrPendingGrantWinsAndCleansOnlyUnacceptedProbeState() throws {
        for winner in ["original", "pending"] {
            try fixture { parent, accounts in
                let source = try makeSource(parent, accounts: accounts), authorization = try authorize(source)
                let issuer = PersonalEnrollmentRegistry(root: source.root, ownerUID: tractanda_uid())
                let first = try issue(issuer, authorization, at: 1_000)
                let target = try makeTarget(parent, accounts: accounts, storeID: first.metadata.storeID)
                let registry = PersonalEnrollmentTargetRegistry(root: target.root)
                _ = try registry.begin(store: target, forUID: tractanda_uid(), invitation: first, hostname: "target.fixture")
                let originalClaim = try XCTUnwrap(registry.runtimeMaterial(store: target)?.2)
                let second: PersonalEnrollmentInvitation
                if winner == "original" {
                    _ = try issuer.claim(originalClaim, authenticatedInvitation: first.metadata, authorization: authorization, now: 1_001)
                    // A source cannot legitimately renew after this accepted grant; these
                    // synthetic same-family inputs model bad user-supplied newer codes.
                    second = try changedInvitation(first)
                } else { second = try issue(issuer, authorization, at: 1_010) }
                _ = try registry.beginReplacement(store: target, forUID: tractanda_uid(), invitation: second,
                    hostname: "target.fixture", now: 1_011)
                let pendingClaim = try XCTUnwrap(registry.replacementRuntimeMaterial(store: target)?.2)
                if winner == "pending" {
                    _ = try issuer.claim(pendingClaim, authenticatedInvitation: second.metadata, authorization: authorization, now: 1_011)
                }
                let badProbe = try changedInvitation(second)
                _ = try registry.beginReplacement(store: target, forUID: tractanda_uid(), invitation: badProbe,
                    hostname: "target.fixture", now: second.metadata.expiresAt + 1)
                let accepted = winner == "original" ? originalClaim : pendingClaim
                let invitation = winner == "original" ? first.metadata : second.metadata
                let proof = try authorizedContinuation(invitation, claim: accepted)
                try registry.confirmRetainedContinuation(store: target, binding: proof)
                XCTAssertEqual(try registry.runtimeMaterial(store: target)?.0.invitation, invitation)
                XCTAssertEqual(try registry.runtimeMaterial(store: target)?.0.phase, .claimed)
                XCTAssertEqual(continuationFingerprint(try XCTUnwrap(registry.runtimeMaterial(store: target)?.2)), continuationFingerprint(accepted))
                XCTAssertNil(try registry.replacementStatus(store: target)); XCTAssertNil(try registry.renewalStatus(store: target))
                let beforeReplay = try fingerprints(target.root)
                try registry.confirmRetainedContinuation(store: target, binding: proof)
                XCTAssertEqual(try fingerprints(target.root), beforeReplay)
            }
        }
    }

}
