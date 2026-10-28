import CTractandaPlatform
import XCTest
@testable import TractandaCore

final class PersonalEnrollmentAuthorizationTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let source: Bool
        var aliceIsAdministrator: Bool
        init(source: Bool) { self.source = source; aliceIsAdministrator = source }
        var aliceUID: UInt32 { source ? 54001 : 64001 }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == tractanda_uid() {
                return .init(uid: uid, name: "admin", primaryGroupName: "staff", groupIDs: [74001, 74002])
            }
            guard uid == aliceUID else { throw TractandaError("unresolvedPrincipal", "Fixture user missing") }
            return .init(uid: uid, name: "alice", primaryGroupName: "staff",
                groupIDs: aliceIsAdministrator ? [74001, 74002] : [74001])
        }
        func user(named name: String) throws -> AccountIdentity {
            if name == "admin" { return try user(forUID: tractanda_uid()) }
            if name == "alice" { return try user(forUID: aliceUID) }
            throw TractandaError("unresolvedPrincipal", "Fixture user missing")
        }
        func groupID(named name: String) throws -> UInt32 {
            if name == "staff" { return 74001 }
            if name == "admins" { return 74002 }
            throw TractandaError("unresolvedPrincipal", "Fixture group missing")
        }
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private var policy: ItemValue { .object([
        "profile": .text(AccessConfiguration.profile), "users": .list([.text("admin"), .text("alice")]),
        "administration": .text("system"), "administratorGroup": .text("admins"),
    ]) }
    private struct Pair {
        let source: ItemStore
        let target: ItemStore
        let sourceAccounts: Accounts
        let targetAccounts: Accounts
        let sourceBinding: PeerExchangeBinding
        let targetBinding: PeerExchangeBinding
        let membership: PersonalMembershipConfiguration
    }
    private func pair(_ body: (Pair) throws -> Void) throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enrollment-authorization-" + Identifier.make())
        try PrivateConfiguration.makeDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceAccounts = Accounts(source: true), targetAccounts = Accounts(source: false)
        var limits = PersonalRecoveryIndex.Limits(); limits.maximumDerivedBytes = AttachmentFixtureCapacity.fixtureCapBytes
        let source = try ItemStore(personalRoot: root.appendingPathComponent("source"), opening: .fresh(policy),
            accounts: sourceAccounts, recoveryLimits: limits)
        let sourceID = try source.personalSyncIdentity()
        let target = try ItemStore.createPersonalSyncReplica(root: root.appendingPathComponent("target"),
            storeID: sourceID.storeID, accessConfiguration: policy, accounts: targetAccounts)
        let targetID = try target.personalSyncIdentity()
        let config = try PersonalMembershipConfiguration(storeID: sourceID.storeID, configurationID: id(), members: [
            .init(replicaID: sourceID.replicaID, hostname: "source.fixture"),
            .init(replicaID: targetID.replicaID, hostname: "target.fixture"),
        ])
        let nonce = try id(), pairing = try id(), digest = try config.digest
        let pa = try source.preparePersonalMembershipChange(configuration: config, expectedDigest: nil, nonce: nonce)
        let pb = try target.preparePersonalMembershipChange(configuration: config, expectedDigest: nil, nonce: nonce)
        let a = try PeerExchangeBinding(peerID: "target", storeID: sourceID.storeID, localReplicaID: sourceID.replicaID,
            remoteReplicaID: targetID.replicaID, pairingID: pairing, localIsInitiator: true, configurationDigest: digest)
        let b = try PeerExchangeBinding(peerID: "source", storeID: sourceID.storeID, localReplicaID: targetID.replicaID,
            remoteReplicaID: sourceID.replicaID, pairingID: pairing, localIsInitiator: false, configurationDigest: digest)
        try source.registerPersonalPeerCredentials([.init(binding: a, secret: [UInt8](repeating: 42, count: 32))], configuration: config)
        try target.registerPersonalPeerCredentials([.init(binding: b, secret: [UInt8](repeating: 42, count: 32))], configuration: config)
        _ = try source.commitPersonalMembershipChange(preparation: pa, acknowledgements: [
            .init(binding: a, response: target.personalMembershipReady(session: b, preparation: pa), control: .commitCompletion()),
        ])
        _ = try target.commitPersonalMembershipChange(preparation: pb, acknowledgements: [
            .init(binding: b, response: source.personalMembershipReady(session: a, preparation: pb), control: .commitCompletion()),
        ])
        try body(.init(source: source, target: target, sourceAccounts: sourceAccounts, targetAccounts: targetAccounts,
            sourceBinding: a, targetBinding: b, membership: config))
    }

    func testTrustedSourceDecisionMapsAliceWithoutReceiverLocalAdministratorVeto() throws {
        try pair { pair in
            XCTAssertThrowsError(try PersonalEnrollmentLocalAuthorization.authorize(store: pair.target, forUID: pair.targetAccounts.aliceUID))
            let sourceAuthorization = try PersonalEnrollmentLocalAuthorization.authorize(store: pair.source, forUID: pair.sourceAccounts.aliceUID)
            let proposed = try PersonalMembershipConfiguration(storeID: pair.membership.storeID, configurationID: id(),
                members: pair.membership.members + [.init(replicaID: id(), hostname: "joining.fixture")])
            let decision = try PersonalEnrollmentAdminDecision.issue(authorization: sourceAuthorization,
                operationID: id(), configuration: proposed, nonce: id())
            let scoped = try PersonalEnrollmentScopedAuthorization.receive(store: pair.target, binding: pair.targetBinding, decision: decision)
            XCTAssertEqual(scoped.localName, "alice")
            XCTAssertEqual(scoped.localUID, pair.targetAccounts.aliceUID)
            try scoped.require(configuration: proposed, nonce: decision.nonce,
                expectedDigest: pair.membership.digest, administrator: "alice")
            let prepared = try pair.target.preparePersonalMembershipChange(authorization: scoped)
            XCTAssertEqual(prepared.administrator, "alice")
            XCTAssertEqual(prepared.configuration, proposed)
            // It authorizes only the membership operation, never normal local admin calls.
            XCTAssertThrowsError(try PersonalEnrollmentLocalAuthorization.authorize(store: pair.target, forUID: scoped.localUID))
        }
    }

    func testScopedDecisionRejectsWrongSenderDigestAndOperationSubstitution() throws {
        try pair { pair in
            let local = try PersonalEnrollmentLocalAuthorization.authorize(store: pair.source, forUID: pair.sourceAccounts.aliceUID)
            let proposed = try PersonalMembershipConfiguration(storeID: pair.membership.storeID, configurationID: id(),
                members: pair.membership.members + [.init(replicaID: id(), hostname: "joining.fixture")])
            let decision = try PersonalEnrollmentAdminDecision.issue(authorization: local,
                operationID: id(), configuration: proposed, nonce: id())
            let scoped = try PersonalEnrollmentScopedAuthorization.receive(store: pair.target, binding: pair.targetBinding, decision: decision)
            XCTAssertThrowsError(try scoped.require(configuration: proposed, nonce: id(),
                expectedDigest: decision.expectedMembershipDigest, administrator: "alice"))
            let wrong = PersonalEnrollmentAdminDecision(operationID: decision.operationID,
                authorizingReplicaID: pair.targetBinding.localReplicaID, administrator: "alice",
                expectedMembershipDigest: decision.expectedMembershipDigest, configuration: proposed, nonce: decision.nonce)
            XCTAssertThrowsError(try PersonalEnrollmentScopedAuthorization.receive(store: pair.target, binding: pair.targetBinding, decision: wrong))
            let stale = PersonalEnrollmentAdminDecision(operationID: decision.operationID,
                authorizingReplicaID: decision.authorizingReplicaID, administrator: "alice",
                expectedMembershipDigest: String(repeating: "a", count: 64), configuration: proposed, nonce: decision.nonce)
            XCTAssertThrowsError(try PersonalEnrollmentScopedAuthorization.receive(store: pair.target, binding: pair.targetBinding, decision: stale))
        }
    }

    func testSourceMustRecheckAdministratorBeforeIssuingNextTransition() throws {
        try pair { pair in
            _ = try PersonalEnrollmentLocalAuthorization.authorize(store: pair.source, forUID: pair.sourceAccounts.aliceUID)
            pair.sourceAccounts.aliceIsAdministrator = false
            XCTAssertThrowsError(try PersonalEnrollmentLocalAuthorization.authorize(store: pair.source, forUID: pair.sourceAccounts.aliceUID))
        }
    }
}
