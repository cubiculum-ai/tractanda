import XCTest
@testable import TractandaCore

final class PersonalEnrollmentRouteTests: XCTestCase {
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    func testRetainedLocalAlternativesSurvivePublicationRetryWithoutLeakingToNewMember() throws {
        try AttachmentFixtureCapacity.requireFree()
        #if os(macOS)
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        #else
        let parent = URL(fileURLWithPath: "/tmp", isDirectory: true)
        #endif
        let root = parent.appendingPathComponent("enrollment-routes-" + Identifier.make())
        try PrivateConfiguration.makeDirectory(root); defer { try? FileManager.default.removeItem(at: root) }
        let members = try (0..<3).map { try PersonalMember(replicaID: id(), hostname: "node\($0).fixture") }
        let storeID = try id()
        let old = try PersonalMembershipConfiguration(storeID: storeID, configurationID: id(), members: Array(members.prefix(2)))
        let next = try PersonalMembershipConfiguration(storeID: storeID, configurationID: id(), members: members)
        let policy = try PersonalEnrollmentAdmission(configuration: AccessConfiguration(.object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("alice")]),
        ])))
        let planned = try Dictionary(uniqueKeysWithValues: members.map {
            ($0.replicaID, [try PeerRuntimeConfiguration.Endpoint(host: $0.hostname, port: 48732)])
        })
        let plan = PersonalEnrollmentPlan(operationID: try id(), issuerReplicaID: members[0].replicaID,
            administrator: "alice", nonce: try id(), previousMembership: old, configuration: next,
            admission: policy, endpoints: planned)
        let retained = [try PeerRuntimeConfiguration.Endpoint(host: "retained.lan", port: 48732),
            try PeerRuntimeConfiguration.Endpoint(host: "retained.tailnet", port: 48733)]
        let unrelated = [try PeerRuntimeConfiguration.Endpoint(host: "unrelated.route", port: 48734)]
        let files = PersonalEnrollmentStateFiles(root: root)
        let before = PersonalEnrollmentRouteState(operationID: try id(), configurationDigest: try old.digest,
            endpoints: [members[1].replicaID: retained, members[2].replicaID: unrelated])
        try files.replace("routes.json", bytes: JSON.encode(before), expected: nil)
        let registry = PersonalEnrollmentMemberRegistry(root: root)
        try registry.publishRoutes(plan: plan)
        try registry.publishRoutes(plan: plan)
        XCTAssertEqual(try registry.routes()?.endpoints[members[1].replicaID], retained)
        XCTAssertEqual(try registry.routes()?.endpoints[members[2].replicaID], planned[members[2].replicaID])
        let current = try files.read("routes.json")
        let foreign = PersonalEnrollmentRouteState(operationID: try id(), configurationDigest: try next.digest,
            endpoints: [members[1].replicaID: unrelated])
        try files.replace("routes.json", bytes: JSON.encode(foreign), expected: current)
        try registry.publishRoutes(plan: plan)
        XCTAssertEqual(try registry.routes()?.endpoints[members[1].replicaID], planned[members[1].replicaID])
    }
}
