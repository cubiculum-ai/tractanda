import XCTest
@testable import TractandaCore

final class PersonalEnrollmentAdmissionTests: XCTestCase {
    private struct Accounts: AccountDirectory {
        let users: [String: UInt32]
        let groups: [String: UInt32]
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard let name = users.first(where: { $0.value == uid })?.key else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user.")
            }
            return .init(uid: uid, name: name, primaryGroupName: "family", groupIDs: [])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard let uid = users[name] else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user.")
            }
            return .init(uid: uid, name: name, primaryGroupName: "family", groupIDs: [])
        }
        func groupID(named name: String) throws -> UInt32 {
            guard let gid = groups[name] else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group.")
            }
            return gid
        }
    }
    private let source: ItemValue = .object([
        "profile": .text(AccessConfiguration.profile),
        "users": .list([.text("alice")]), "groups": .list([.text("family")]),
        "userAliases": .object(["al": .text("alice")]),
        "groupAliases": .object(["kin": .text("family")]),
        "administration": .text("system"), "administratorGroup": .text("sourceadmins"),
        "legacyUsers": .object(["uid:123": .text("alice")]),
    ])
    private let target: ItemValue = .object([
        "profile": .text(AccessConfiguration.profile),
        "users": .list([.text("owner")]), "groups": .list([]),
        "administration": .text("system"), "administratorGroup": .text("targetadmins"),
        "legacyUsers": .object(["uid:999": .text("owner")]),
    ])
    private let sourceDirectory = Accounts(
        users: ["alice": 101], groups: ["family": 201, "sourceadmins": 202])
    private let targetDirectory = Accounts(
        users: ["alice": 501, "owner": 502], groups: ["family": 601, "targetadmins": 602])

    func testLogicalNamesMapAcrossDifferentNumericIDsAndPreserveLocalAuthority() throws {
        let sourcePolicy = try AccessConfiguration(source)
        try sourcePolicy.validate(using: PrincipalResolver(directory: sourceDirectory, configuration: sourcePolicy))
        let admission = try PersonalEnrollmentAdmission(configuration: sourcePolicy)
        let result = try admission.applying(to: target, accounts: targetDirectory)
        let adopted = try AccessConfiguration(result)
        try admission.requireSameLogicalPolicy(adopted)
        let sourceResolver = PrincipalResolver(directory: sourceDirectory, configuration: sourcePolicy)
        let targetResolver = PrincipalResolver(directory: targetDirectory, configuration: adopted)
        XCTAssertEqual(try sourceResolver.userID("al"), 101)
        XCTAssertEqual(try targetResolver.userID("al"), 501)
        XCTAssertEqual(try sourceResolver.groupID("kin"), 201)
        XCTAssertEqual(try targetResolver.groupID("kin"), 601)
        XCTAssertEqual(adopted.administration, .system)
        XCTAssertEqual(adopted.administratorGroup, "targetadmins")
        XCTAssertEqual(adopted.legacyUsers, [999: "owner"])
        XCTAssertEqual(target.map?["users"], .list([.text("owner")]))
        XCTAssertEqual(source.map?["administratorGroup"], .text("sourceadmins"))
    }

    func testMissingAndAmbiguousMappingsFailWithoutChangingEitherPolicy() throws {
        let admission = try PersonalEnrollmentAdmission(configuration: AccessConfiguration(source))
        let originalSource = source, originalTarget = target
        let candidates = [
            Accounts(users: ["owner": 502], groups: ["family": 601, "targetadmins": 602]),
            Accounts(users: ["alice": 501, "owner": 502], groups: ["targetadmins": 602]),
            Accounts(users: ["alice": 501, "owner": 502, "al": 503], groups: ["family": 601, "targetadmins": 602]),
            Accounts(users: ["alice": 501, "owner": 502], groups: ["family": 601, "kin": 603, "targetadmins": 602]),
        ]
        for directory in candidates {
            XCTAssertThrowsError(try admission.applying(to: target, accounts: directory)) { error in
                XCTAssertEqual((error as? TractandaError)?.code, "configurationDrift")
            }
            XCTAssertEqual(source, originalSource)
            XCTAssertEqual(target, originalTarget)
        }
    }

    func testRetainedMemberLogicalPolicyDriftIsReported() throws {
        let admission = try PersonalEnrollmentAdmission(configuration: AccessConfiguration(source))
        let adopted = try admission.applying(to: target, accounts: targetDirectory)
        try admission.requireSameLogicalPolicy(AccessConfiguration(adopted))
        XCTAssertThrowsError(try admission.requireSameLogicalPolicy(AccessConfiguration(target))) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "configurationDrift")
        }
        XCTAssertEqual(target.map?["users"], .list([.text("owner")]))
    }
}
