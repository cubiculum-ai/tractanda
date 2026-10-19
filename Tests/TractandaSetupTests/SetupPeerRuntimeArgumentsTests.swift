import Foundation
import XCTest
@testable import TractandaSetup

final class SetupPeerRuntimeArgumentsTests: XCTestCase {
    func testDefaultPreservesActionAndAllArguments() throws {
        let arguments = ["status", "--name", "production"]
        let parsed = try SetupPeerRuntimeArguments.parse(arguments)
        XCTAssertEqual(parsed.remainingArguments, arguments)
        XCTAssertEqual(parsed.action, .preserve)

        let empty = try SetupPeerRuntimeArguments.parse([])
        XCTAssertTrue(empty.remainingArguments.isEmpty)
        XCTAssertEqual(empty.action, .preserve)
    }

    func testConfigurationActionStripsOnlyItsFlagAndPassesThroughOtherArguments() throws {
        let path = "/tmp/nonexistent-peer-runtime.json"
        for command in ["plan", "install", "upgrade"] {
            let parsed = try SetupPeerRuntimeArguments.parse([
                command, "--name", "preview", "--peer-runtime-configuration", path, "--owner", "daemon",
            ])
            XCTAssertEqual(parsed.remainingArguments, [command, "--name", "preview", "--owner", "daemon"])
            XCTAssertEqual(parsed.action, .replace(URL(fileURLWithPath: path)))
        }
    }

    func testDisableActionIsExplicitAndWorksOnlyForSupportedCommands() throws {
        for command in ["plan", "install", "upgrade"] {
            let parsed = try SetupPeerRuntimeArguments.parse([command, "--disable-peer-runtime"])
            XCTAssertEqual(parsed.remainingArguments, [command])
            XCTAssertEqual(parsed.action, .disable)
        }
    }

    func testRuntimeOptionsRejectUnsupportedCommandsIncludingDryRun() {
        for command in ["dry-run", "status", "start", "stop", "restart", "uninstall", "unknown"] {
            XCTAssertThrowsError(try SetupPeerRuntimeArguments.parse([command, "--disable-peer-runtime"]))
            XCTAssertThrowsError(try SetupPeerRuntimeArguments.parse([
                command, "--peer-runtime-configuration", "/tmp/config.json",
            ]))
        }
    }

    func testDuplicateContradictoryMissingAndFlagLikeValuesAreRejected() {
        let invalid: [[String]] = [
            ["plan", "--peer-runtime-configuration"],
            ["install", "--peer-runtime-configuration", "--name"],
            ["upgrade", "--peer-runtime-configuration", "--disable-peer-runtime"],
            ["plan", "--disable-peer-runtime", "--disable-peer-runtime"],
            ["install", "--peer-runtime-configuration", "/tmp/a.json", "--peer-runtime-configuration", "/tmp/b.json"],
            ["upgrade", "--peer-runtime-configuration", "/tmp/a.json", "--disable-peer-runtime"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try SetupPeerRuntimeArguments.parse(arguments), arguments.description)
        }
    }
}
