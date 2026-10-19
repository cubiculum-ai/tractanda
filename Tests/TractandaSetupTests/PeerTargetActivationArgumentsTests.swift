import Foundation
import TractandaCore
import XCTest
@testable import TractandaSetup

final class PeerTargetActivationArgumentsTests: XCTestCase {
    private let flag = "--activate-peer-target-stdio"
    private let source = "00000000-0000-1000-8000-000000000001"
    private let bootstrap = "00000000-0000-1000-8000-000000000002"
    private let approval = "00000000-0000-1000-8000-000000000003"
    private let bootstrapDigest = String(repeating: "a", count: 64)
    private let approvalDigest = String(repeating: "b", count: 64)

    private func arguments(root: String = "/private/target") -> [String] {
        [flag, root, source, bootstrap, bootstrapDigest, approval, approvalDigest]
    }

    func testExactPublicPinTupleAndStandardSystemAliasPaths() throws {
        for root in ["/private/target", "/tmp/pending-target", "/var/tmp/pending-target"] {
            let parsed = try XCTUnwrap(PeerTargetActivationArguments.parse(arguments(root: root)))
            XCTAssertEqual(parsed.root, root)
            XCTAssertEqual(parsed.pin.sourceReplicaID, source)
            XCTAssertEqual(parsed.pin.bootstrapID, bootstrap)
            XCTAssertEqual(parsed.pin.bootstrapSHA256, bootstrapDigest)
            XCTAssertEqual(parsed.pin.approvalID, approval)
            XCTAssertEqual(parsed.pin.approvalSHA256, approvalDigest)
        }
    }

    func testAcceptsExact4096ByteAbsoluteRootWithoutResolvingIt() throws {
        let root = "/" + String(repeating: "p", count: 4095)
        XCTAssertEqual(root.utf8.count, 4096)
        let parsed = try XCTUnwrap(PeerTargetActivationArguments.parse(arguments(root: root)))
        XCTAssertEqual(parsed.root, root)
    }

    func testNonmatchingCommandsReturnNilAndNoOtherFlagsAreAccepted() throws {
        XCTAssertNil(try PeerTargetActivationArguments.parse(["plan", "--activate-peer-target-stdio"]))
        XCTAssertNil(try PeerTargetActivationArguments.parse(["--activate-peer-target-stdio-extra"]))
        for option in ["--uid", "--deadline", "--password", "--file", "--ssh", "--lifecycle"] {
            XCTAssertThrowsError(try PeerTargetActivationArguments.parse(arguments() + [option, "value"])) {
                XCTAssertEqual(($0 as? SetupError)?.message, PeerTargetActivationArguments.usage)
            }
        }
    }

    func testMissingExtraEmptyFlagLikeAndUnsafePathsFailWithFixedUsage() {
        var invalid = [
            [flag],
            Array(arguments().dropLast()),
            arguments() + ["extra"],
            arguments(root: ""),
            arguments(root: "relative/target"),
            arguments(root: "/private/has\0nul"),
            arguments(root: "/" + String(repeating: "x", count: 4096)),
            arguments(root: "--uid"),
        ]
        for index in 2..<7 {
            var value = arguments()
            value[index] = "--unknown"
            invalid.append(value)
        }
        for arguments in invalid {
            XCTAssertThrowsError(try PeerTargetActivationArguments.parse(arguments)) {
                XCTAssertEqual(($0 as? SetupError)?.message, PeerTargetActivationArguments.usage)
            }
        }
    }

    func testUUIDsMustBeCanonicalLowercaseV1AndDigestsExactLowercaseHex() {
        var invalid = [arguments()]
        invalid[0][2] = "00000000-0000-4000-8000-000000000001" // UUIDv4
        var uppercaseUUID = arguments()
        uppercaseUUID[2] = "00000000-0000-1000-8000-00000000000A"
        invalid.append(uppercaseUUID)
        var uppercaseDigest = arguments()
        uppercaseDigest[4] = String(repeating: "A", count: 64)
        invalid.append(uppercaseDigest)
        var shortDigest = arguments()
        shortDigest[6] = String(repeating: "b", count: 63)
        invalid.append(shortDigest)
        var nonHexDigest = arguments()
        nonHexDigest[4] = String(repeating: "g", count: 64)
        invalid.append(nonHexDigest)
        for arguments in invalid {
            XCTAssertThrowsError(try PeerTargetActivationArguments.parse(arguments)) {
                XCTAssertEqual(($0 as? SetupError)?.message, PeerTargetActivationArguments.usage)
            }
        }
    }
}
