import CTractandaPlatform
import Foundation
import XCTest
@testable import TractandaCore

final class PeerEnrollmentSSHTests: XCTestCase {
    private func pin() throws -> PeerTargetEnrollmentPin {
        try .init(sourceReplicaID: "00000000-0000-1000-8000-000000000001",
            bootstrapID: "00000000-0000-1000-8000-000000000002", bootstrapSHA256: String(repeating: "a", count: 64),
            approvalID: "00000000-0000-1000-8000-000000000003", approvalSHA256: String(repeating: "b", count: 64))
    }
    func testFixedHybridOnlyArgvAndBothManagedRemotePaths() throws {
        for platform in [PeerEnrollmentSSHPlatform.macOS, .linux] {
            let destination = try PeerEnrollmentSSHDestination(host: "stash.example", login: "rcfa", platform: platform)
            let arguments = try PeerEnrollmentSSH.arguments(destination: destination, root: "/pending target", pin: pin(),
                custody: .current, remainingNanoseconds: 30_000_000_000)
            XCTAssertEqual(arguments.count, 16)
            XCTAssertEqual(Array(arguments.prefix(15)), ["-F/dev/null", "-T", "-Snone", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
                "-oUpdateHostKeys=no", "-oClearAllForwardings=yes", "-oForwardAgent=no", "-oCompression=no",
                "-oKexAlgorithms=mlkem768x25519-sha256,sntrup761x25519-sha512", "-oConnectTimeout=10", "-l", "rcfa", "--", "stash.example"])
            XCTAssertTrue(arguments[15].hasPrefix(try PeerEnrollmentSSH.quoted(PeerEnrollmentSSH.helper(platform).path) + " '--activate-peer-target-stdio' "))
            XCTAssertFalse(arguments.contains { $0.contains("KexAlgorithms=+") || $0.contains("KexAlgorithms=^") })
            let short = try PeerEnrollmentSSH.arguments(destination: destination, root: "/pending", pin: pin(), custody: .current, remainingNanoseconds: 1)
            XCTAssertEqual(short[10], "-oConnectTimeout=1")
            XCTAssertThrowsError(try PeerEnrollmentSSH.arguments(destination: destination, root: "/pending", pin: pin(), custody: .current, remainingNanoseconds: 0))
        }
    }
    func testStrictDestinationGrammarAndRemoteCustodyDoesNotResolveLocalAccounts() throws {
        for host in ["example.org", "127.0.0.1", "::1", "2001:db8::1", "host.example."] {
            XCTAssertNoThrow(try PeerEnrollmentSSHDestination(host: host, login: "user-1.name", platform: .linux))
        }
        for host in ["", "-option", "user@host", "ssh://host", "host:22", "[::1]", "a b", "a\nb", "a;id", "x..y", "x/y", "x%z", ".", String(repeating: "a", count: 64), "h\0ost", "::1\0suffix"] {
            XCTAssertThrowsError(try PeerEnrollmentSSHDestination(host: host, login: "user", platform: .linux), host)
        }
        for user in ["", "-option", "user@host", "x y", "x'", "x\n", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try PeerEnrollmentSSHDestination(host: "host", login: user, platform: .linux))
        }
        let destination = try PeerEnrollmentSSHDestination(host: "host", login: "remote", platform: .linux)
        let argv = try PeerEnrollmentSSH.arguments(destination: destination, root: "/pending", pin: pin(),
            custody: .existingUser("nonexistent-remote-only-user"), remainingNanoseconds: 1)
        XCTAssertTrue(argv[15].hasPrefix("'/usr/bin/sudo' '-n' '-u' 'nonexistent-remote-only-user' '--' '/opt/tractanda/current/bin/tractanda-setup'"))
        XCTAssertThrowsError(try PeerEnrollmentSSH.arguments(destination: destination, root: "/pending", pin: pin(), custody: .existingUser("root"), remainingNanoseconds: 1))
    }
    func testPOSIXQuotingPreservesPublicMetacharactersAndBoundsCompletedCommand() throws {
        XCTAssertEqual(try PeerEnrollmentSSH.quoted("/a b/'雪';$(touch nope)`id`\n"), "'/a b/'\\''雪'\\'';$(touch nope)`id`\n'")
        XCTAssertEqual(try PeerEnrollmentSSH.quoted(""), "''")
        XCTAssertThrowsError(try PeerEnrollmentSSH.quoted("bad\0value"))
        let destination = try PeerEnrollmentSSHDestination(host: "host", login: "user", platform: .macOS)
        XCTAssertThrowsError(try PeerEnrollmentSSH.arguments(destination: destination, root: "/" + String(repeating: "'", count: 1100), pin: pin(), custody: .current, remainingNanoseconds: 1))
        XCTAssertThrowsError(try PeerEnrollmentSSH.arguments(destination: destination, root: "relative", pin: pin(), custody: .current, remainingNanoseconds: 1))
    }
    func testFixedTrustedLocalSSHLaunchAlwaysHasIndirectCustody() throws {
        // This checks the fixed local executable admission; it makes no connection or negotiation claim.
        guard FileManager.default.fileExists(atPath: "/usr/bin/ssh") else { throw XCTSkip("Fixed SSH client is unavailable on this test host") }
        XCTAssertEqual(tractanda_validate_enrollment_ssh(), 0)
        let destination = try PeerEnrollmentSSHDestination(host: "host", login: "remote", platform: .linux)
        let job = try PeerEnrollmentSupervisor.Job(seconds: 1, cancelled: { false })
        let launch = try PeerEnrollmentSSH.launch(destination: destination, root: "/pending", pin: pin(), custody: .current, job: job)
        XCTAssertEqual(launch.executable.path, "/usr/bin/ssh"); XCTAssertTrue(launch.indirectCustody)
        XCTAssertEqual(launch.arguments.count, 16)
    }
}
