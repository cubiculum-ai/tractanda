import Foundation
import XCTest
import TractandaCore
import TractandaClient
@testable import TractandaCLI

final class ClusterEnrollmentSetupTests: XCTestCase {
    private func invitation() throws -> PersonalEnrollmentInvitation {
        func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        return try .init(metadata: .init(operationID: id(), storeID: id(), issuerReplicaID: id(),
            bootstrapReplicaID: id(), pairingID: id(), endpoints: [.init(host: "source.fixture", port: 48732)],
            expiresAt: 10000, expectedMembershipDigest: nil),
            secret: .init(bytes: [UInt8](repeating: 77, count: 32)))
    }
    private final class Fixture {
        var user = ConnectionPreferences.Document()
        var system = ConnectionPreferences.Document()
        var result: Int32 = 0
        var calls = 0
        var args: [String] = []
        var environment: [String: String] = [:]
        var resolvedUID: UInt32?
        var addUserShadow = false
        var badSystemSocket = false
        var badHelper = false
        var simulatedErrorMessage: String?
        var selected: ServerConnection { .init(socketPath: "/fixture/production/server.sock", serverUser: "daemon") }
        func dependencies() -> ClusterEnrollmentSetup.Dependencies {
            .init(uid: { 501 }, accountName: { self.resolvedUID = $0; return "alice" },
                installedSetup: {
                    if self.badHelper { throw TractandaError("setupUnavailable", "fixture") }
                    return .init(helper: URL(fileURLWithPath: "/protected/bin/tractanda-setup"),
                        bundle: URL(fileURLWithPath: "/protected"))
                }, userProfiles: { self.user }, systemProfiles: { self.system },
                runSudo: { helper, args, environment in
                    self.calls += 1; self.args = args; self.environment = environment
                    if let text = self.simulatedErrorMessage { throw TractandaError("fixtureError", text) }
                    XCTAssertEqual(helper.path, "/protected/bin/tractanda-setup")
                    if self.result == 0 {
                        self.system.profiles["production"] = self.badSystemSocket
                            ? .init(socketPath: "/fixture/wrong.sock", serverUser: "daemon") : self.selected
                        if self.addUserShadow { self.user.profiles["production"] = .init(socketPath: "/fixture/shadow.sock") }
                    }
                    return self.result
                }, expectedSocket: { "/fixture/" + $0 + "/server.sock" })
        }
    }
    func testPreparationUsesOnlyPublicMetadataAndReloadsExactSharedProfile() throws {
        let fixture = Fixture(), invitation = try invitation(), code = try invitation.privateCode()
        let selected = try ClusterEnrollmentSetup.prepareNew(instance: "production", metadata: invitation.metadata,
            dependencies: fixture.dependencies())
        XCTAssertEqual(selected, fixture.selected)
        XCTAssertEqual(fixture.calls, 1)
        XCTAssertEqual(fixture.resolvedUID, 501)
        XCTAssertEqual(fixture.args, ["install", "--bundle", "/protected", "--name", "production", "--owner", "alice",
            "--empty", "--fresh-personal-target", "--store-id", invitation.metadata.storeID,
            "--new-instance-only", "--outbound-peer-sync"])
        XCTAssertEqual(fixture.environment, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        XCTAssertFalse(fixture.args.joined(separator: " ").contains(code))
        XCTAssertFalse(fixture.environment.values.joined().contains(code))
    }
    func testExistingUserOrSharedProfileIsRefusedBeforeSudo() throws {
        let invitation = try invitation()
        for userShadow in [false, true] {
            let fixture = Fixture()
            if userShadow { fixture.user.profiles["production"] = fixture.selected }
            else { fixture.system.profiles["production"] = fixture.selected }
            XCTAssertThrowsError(try ClusterEnrollmentSetup.prepareNew(instance: "production", metadata: invitation.metadata,
                dependencies: fixture.dependencies())) {
                let error = $0 as? TractandaError
                XCTAssertEqual(error?.code, "profileExists")
                if userShadow { XCTAssertTrue(error?.message.contains("shadow") == true) }
                else {
                    XCTAssertTrue(error?.message.contains("/protected/bin/tractanda' --profile production cluster join --hostname HOSTNAME") == true)
                    XCTAssertTrue(error?.message.contains("/protected/bin/tractanda' --profile production cluster resume") == true)
                }
            }
            XCTAssertEqual(fixture.calls, 0)
        }
    }
    func testFailedSetupAndPostInstallShadowOrWrongProfileFailClosed() throws {
        let invitation = try invitation(), code = try invitation.privateCode()
        for failure in ["sudo", "user-shadow", "wrong-socket"] {
            let fixture = Fixture()
            if failure == "sudo" { fixture.result = 1 }
            if failure == "user-shadow" { fixture.addUserShadow = true }
            if failure == "wrong-socket" { fixture.badSystemSocket = true }
            XCTAssertThrowsError(try ClusterEnrollmentSetup.prepareNew(instance: "production", metadata: invitation.metadata,
                dependencies: fixture.dependencies())) {
                XCTAssertEqual(($0 as? TractandaError)?.code, failure == "sudo" ? "setupFailed" : "setupProfileMismatch")
                XCTAssertFalse(String(describing: $0).contains(code))
            }
            XCTAssertEqual(fixture.calls, 1)
        }
    }
    func testProcessFailureDoesNotExposePrivateMaterial() throws {
        let invitation = try invitation(), code = try invitation.privateCode()
        let fixture = Fixture()
        fixture.simulatedErrorMessage = code
        XCTAssertThrowsError(try ClusterEnrollmentSetup.prepareNew(instance: "production", metadata: invitation.metadata,
            dependencies: fixture.dependencies())) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "setupFailed")
            XCTAssertFalse(String(describing: $0).contains(code))
        }
        XCTAssertEqual(fixture.calls, 1)
    }

    func testUntrustedHelperAndInvalidInstanceNeverInvokeSetup() throws {
        let invitation = try invitation(), fixture = Fixture()
        fixture.badHelper = true
        XCTAssertThrowsError(try ClusterEnrollmentSetup.prepareNew(instance: "production", metadata: invitation.metadata,
            dependencies: fixture.dependencies()))
        XCTAssertEqual(fixture.calls, 0)
        fixture.badHelper = false
        XCTAssertThrowsError(try ClusterEnrollmentSetup.prepareNew(instance: "../production", metadata: invitation.metadata,
            dependencies: fixture.dependencies()))
        XCTAssertThrowsError(try ClusterEnrollmentSetup.prepareNew(instance: String(repeating: "a", count: 33),
            metadata: invitation.metadata, dependencies: fixture.dependencies()))
        XCTAssertEqual(fixture.calls, 0)
    }
}
