import Foundation
import XCTest

@testable import TractandaSetup

final class SetupPackageArgumentsTests: XCTestCase {
    func testParsesFiniteLifecycleActionsAndDescriptorActions() throws {
        XCTAssertEqual(try SetupPackageArguments.parse(["--package-lifecycle", "prerm-upgrade"])?.action, .prermUpgrade)
        XCTAssertEqual(try SetupPackageArguments.parse(["--package-lifecycle", "abort-upgrade"])?.action, .abortUpgrade)
        XCTAssertEqual(try SetupPackageArguments.parse(["--package-lifecycle", "remove"])?.action, .remove)

        let descriptor = "/run/tractanda/incoming-descriptor.json"
        for action in ["preinst", "configure"] {
            let parsed = try XCTUnwrap(SetupPackageArguments.parse([
                "--package-lifecycle", action, "--descriptor", descriptor,
            ]))
            XCTAssertEqual(parsed.action.rawValue, action)
            XCTAssertEqual(parsed.descriptor?.path, descriptor)
            XCTAssertNil(parsed.instance)
        }
    }

    func testRuntimeGuardIsSeparateAndValidatesInstance() throws {
        let parsed = try XCTUnwrap(SetupPackageArguments.parse(["--package-runtime-guard", "store-1"]))
        XCTAssertEqual(parsed.action, .runtimeGuard)
        XCTAssertEqual(parsed.instance, "store-1")
        XCTAssertNil(parsed.descriptor)
        XCTAssertEqual(try SetupPackageArguments.parse(["--package-runtime-guard", "A0"])?.instance, "A0")
    }

    func testOrdinarySetupGrammarIsNotCaptured() throws {
        XCTAssertNil(try SetupPackageArguments.parse([]))
        XCTAssertNil(try SetupPackageArguments.parse(["plan", "--name", "production"]))
        XCTAssertNil(try SetupPackageArguments.parse(["--profile", "production", "status"]))
    }

    func testRejectsMalformedLifecycleAndDescriptorArguments() {
        let bad: [[String]] = [
            ["--package-lifecycle"],
            ["--package-lifecycle", "unknown"],
            ["--package-lifecycle", "runtime-guard"],
            ["--package-lifecycle", "remove", "extra"],
            ["--package-lifecycle", "preinst"],
            ["--package-lifecycle", "configure", "--other", "/run/incoming.json"],
            ["--package-lifecycle", "preinst", "--descriptor", "relative.json"],
            ["--package-lifecycle", "preinst", "--descriptor", "/"],
            ["--package-lifecycle", "preinst", "--descriptor", "/run/../etc/incoming.json"],
            ["--package-lifecycle", "configure", "--descriptor", "/run/incoming\n.json"],
            ["--package-lifecycle", "configure", "--descriptor", "/" + String(repeating: "a", count: 4_096)],
        ]
        for arguments in bad {
            XCTAssertThrowsError(try SetupPackageArguments.parse(arguments), "accepted \(arguments)")
        }
    }

    func testRejectsMalformedRuntimeGuardArguments() {
        let bad: [[String]] = [
            ["--package-runtime-guard"],
            ["--package-runtime-guard", "store", "extra"],
            ["--package-runtime-guard", "-store"],
            ["--package-runtime-guard", "store-"],
            ["--package-runtime-guard", "a_b"],
            ["--package-runtime-guard", "stör"],
            ["--package-runtime-guard", String(repeating: "a", count: 33)],
        ]
        for arguments in bad {
            XCTAssertThrowsError(try SetupPackageArguments.parse(arguments), "accepted \(arguments)")
        }
    }

    func testDescriptorParsingDoesNotRequireThePathToExist() throws {
        let path = "/run/tractanda/nonexistent-descriptor.json"
        let parsed = try XCTUnwrap(SetupPackageArguments.parse([
            "--package-lifecycle", "preinst", "--descriptor", path,
        ]))
        XCTAssertEqual(parsed.descriptor?.path, path)
    }
}
