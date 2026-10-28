import XCTest
@testable import TractandaCore

final class PersonalEnrollmentCapacityTests: XCTestCase {
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    func testMaximumQualifiedTransitionReservesOldNextBootstrapAndDialCapacity() throws {
        let members = try (0..<16).map { try PersonalMember(replicaID: id(), hostname: "node\($0).fixture") }
        let storeID = try id()
        let old = try PersonalMembershipConfiguration(storeID: storeID, configurationID: id(), members: Array(members.prefix(15)))
        let next = try PersonalMembershipConfiguration(storeID: storeID, configurationID: id(), members: members)
        let result = try PersonalEnrollmentCapacity.preflight(current: old, proposed: next,
            initiatingReplicaID: members[0].replicaID, runtimeSocketLimit: 64, tlsContextLimit: 256, credentialRoleLimit: 512)
        XCTAssertEqual(result.maximumOverlappingSockets, 33)
        XCTAssertEqual(result.maximumResponderContexts, 31)
        XCTAssertEqual(result.maximumCredentialRoles, 58)
        XCTAssertThrowsError(try PersonalEnrollmentCapacity.preflight(current: old, proposed: next,
            initiatingReplicaID: members[0].replicaID, runtimeSocketLimit: 32, tlsContextLimit: 256, credentialRoleLimit: 512))
    }
    func testLargerCanonicalMembershipRemainsValidButNativeWorkflowRefusesBeforeMutation() throws {
        let members = try (0..<17).map { try PersonalMember(replicaID: id(), hostname: "node\($0).fixture") }
        let storeID = try id()
        let old = try PersonalMembershipConfiguration(storeID: storeID, configurationID: id(), members: Array(members.prefix(16)))
        let next = try PersonalMembershipConfiguration(storeID: storeID, configurationID: id(), members: members)
        XCTAssertNoThrow(try next.validate())
        XCTAssertThrowsError(try PersonalEnrollmentCapacity.preflight(current: old, proposed: next,
            initiatingReplicaID: members[0].replicaID, runtimeSocketLimit: 64, tlsContextLimit: 256, credentialRoleLimit: 512)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "enrollmentCapacityUnsupported")
        }
    }
    func testSixteenMemberBinaryKeyRegistryFitsAndReopensAll480ExactRoles() throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("enrollment-key-capacity-" + Identifier.make())
        try PrivateConfiguration.makeDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let members = try (0..<16).map { try PersonalMember(replicaID: id(), hostname: "node\($0).fixture") }
        let storeID = try id()
        let old = try PersonalMembershipConfiguration(storeID: storeID, configurationID: id(), members: Array(members.prefix(15)))
        let configuration = try PersonalMembershipConfiguration(storeID: storeID, configurationID: id(), members: members)
        let admission = try PersonalEnrollmentAdmission(configuration: AccessConfiguration(.object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("alice")]),
        ])))
        let endpoints = try Dictionary(uniqueKeysWithValues: members.map {
            ($0.replicaID, [try PeerRuntimeConfiguration.Endpoint(host: $0.hostname, port: 48732)])
        })
        let plan = try PersonalEnrollmentPlan(operationID: id(), issuerReplicaID: members[0].replicaID, administrator: "alice",
            nonce: id(), previousMembership: old, configuration: configuration, admission: admission,
            endpoints: endpoints)
        let registry = PersonalEnrollmentJobRegistry(root: root)
        let keys = try registry.credentials(plan: plan)
        XCTAssertEqual(keys.count, 480)
        let bytes = try Data(contentsOf: root.appendingPathComponent(".personal-enrollment/keys.bin"))
        XCTAssertLessThanOrEqual(bytes.count, PersonalEnrollmentPrivateCodec.operationHeaderBytes + 68)
        let reopened = try PersonalEnrollmentJobRegistry(root: root).credentials(plan: plan)
        XCTAssertEqual(reopened.count, keys.count)
        for member in members {
            let packet = try PersonalEnrollmentStagePacket(plan: plan, credentials: reopened, localReplicaID: member.replicaID)
            XCTAssertEqual(try packet.credentials(localReplicaID: member.replicaID).count, 30)
        }
    }
}
