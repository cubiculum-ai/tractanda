import XCTest

@testable import TractandaCLI
@testable import TractandaCore

final class PeerEnrollmentActivateCommandTests: XCTestCase {
    private let operationID = "00000000-0000-1000-8000-00000000010a"
    private let sourceID = "00000000-0000-1000-8000-000000000102"
    private let bootstrapID = "00000000-0000-1000-8000-000000000103"
    private let approvalID = "00000000-0000-1000-8000-000000000104"
    private let digest = String(repeating: "a", count: 64)

    private func command(user: String? = nil) -> [String] {
        var result = [
            "peer", "enrollment", "activate",
            "--operation-id", operationID,
            "--file", "relative/target-enrollment.bin",
            "--root", "/var/lib/tractanda",
            "--source-replica", sourceID,
            "--bootstrap-id", bootstrapID,
            "--bootstrap-sha256", digest,
            "--approval-id", approvalID,
            "--approval-sha256", digest,
        ]
        if let user { result += ["--target-user", user] }
        return result
    }

    private func ssh(_ host: String = "stash.example.net", login: String = "rcfa", platform: String = "linux")
        -> [String]
    {
        ["--ssh-host", host, "--ssh-login", login, "--ssh-platform", platform]
    }

    private func parse(_ args: [String], options: ConnectionOptions? = nil) throws
        -> PeerEnrollmentActivateOptions
    {
        try XCTUnwrap(peerEnrollmentActivateOptions(arguments: args, options: options ?? .init()))
    }

    func testCurrentAndExistingUserCustodyPreserveConnectionAndNeverStartService() throws {
        var profile = ConnectionOptions()
        profile.profile = "production"
        profile.startsService = true
        let current = try parse(command(), options: profile)
        XCTAssertEqual(current.connection.profile, "production")
        XCTAssertFalse(current.connection.startsService)
        XCTAssertEqual(current.operationID, operationID)
        XCTAssertEqual(current.filePath, "relative/target-enrollment.bin")
        XCTAssertEqual(current.targetRoot, "/var/lib/tractanda")
        XCTAssertEqual(current.pin.sourceReplicaID, sourceID)
        XCTAssertEqual(current.pin.bootstrapID, bootstrapID)
        XCTAssertEqual(current.pin.bootstrapSHA256, digest)
        XCTAssertEqual(current.pin.approvalID, approvalID)
        XCTAssertEqual(current.pin.approvalSHA256, digest)
        guard case .current = current.custody else { return XCTFail("Expected current-user custody.") }

        var socket = ConnectionOptions()
        socket.socketPath = "/tmp/tractanda.sock"
        socket.startsService = true
        let existing = try parse(command(user: "tractanda_service-2"), options: socket)
        XCTAssertEqual(existing.connection.socketPath, socket.socketPath)
        XCTAssertFalse(existing.connection.startsService)
        guard case .existingUser(let name) = existing.custody else {
            return XCTFail("Expected explicitly selected existing-user custody.")
        }
        XCTAssertEqual(name, "tractanda_service-2")
    }

    func testExactGrammarRejectsMissingDuplicateUnknownAndPrivilegedOptions() {
        let valid = command()
        XCTAssertNotEqual(operationID.uppercased(), operationID)
        let invalid: [[String]] = [
            ["peer", "enrollment", "activate"],
            valid + ["--file", "/another/input"],
            valid + ["--unknown", "value"],
            valid + ["--uid", "0"],
            valid + ["--ssh", "host"],
            valid + ["--command", "helper"],
            valid + ["--password", "secret"],
            valid + ["--deadline", "30"],
            valid + ["--ssh-host", "stash.example.net"],
            valid + ssh() + ["--ssh-host", "other.example.net"],
            Array(valid.dropLast(2)),
            Array(valid.dropLast(1)) + ["--approval-sha256", "--target-user", "name"],
            valid.map { $0 == operationID ? operationID.uppercased() : $0 },
            valid.map { $0 == bootstrapID ? "00000000-0000-4000-8000-000000000103" : $0 },
            valid.map { $0 == digest ? String(repeating: "A", count: 64) : $0 },
            valid.map { $0 == "/var/lib/tractanda" ? "relative/root" : $0 },
            valid.map { $0 == "relative/target-enrollment.bin" ? "" : $0 },
            valid.map { $0 == "relative/target-enrollment.bin" ? "/private/input\0tail" : $0 },
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try peerEnrollmentActivateOptions(arguments: arguments, options: .init())) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "usage")
            }
        }
    }

    func testSSHRemoteDestinationsRequireTheCompleteTripleAndKeepIndependentPins() throws {
        for platform in ["macos", "linux"] {
            let parsed = try parse(
                command() + ssh("stash.example.net", login: "remote_user-2", platform: platform))
            XCTAssertEqual(parsed.ssh?.host, "stash.example.net")
            XCTAssertEqual(parsed.ssh?.login, "remote_user-2")
            XCTAssertEqual(parsed.ssh?.platform.rawValue, platform)
            XCTAssertFalse(parsed.connection.startsService)
            XCTAssertEqual(parsed.pin.sourceReplicaID, sourceID)
            XCTAssertEqual(parsed.pin.bootstrapID, bootstrapID)
            XCTAssertEqual(parsed.pin.bootstrapSHA256, digest)
            XCTAssertEqual(parsed.pin.approvalID, approvalID)
            XCTAssertEqual(parsed.pin.approvalSHA256, digest)
        }

        XCTAssertNil(try parse(command()).ssh)
        let remoteWithTargetUser = try parse(command(user: "remote_service") + ssh())
        guard case .existingUser(let remoteUser) = remoteWithTargetUser.custody else {
            return XCTFail("Expected the optional target user to remain explicit remote custody.")
        }
        XCTAssertEqual(remoteUser, "remote_service")
        for partial in [
            ["--ssh-host", "stash.example.net"],
            ["--ssh-login", "rcfa"],
            ["--ssh-platform", "linux"],
            ["--ssh-host", "stash.example.net", "--ssh-login", "rcfa"],
            ["--ssh-host", "stash.example.net", "--ssh-platform", "linux"],
            ["--ssh-login", "rcfa", "--ssh-platform", "linux"],
        ] {
            XCTAssertThrowsError(
                try peerEnrollmentActivateOptions(
                    arguments: command() + partial, options: .init())
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "usage")
            }
        }
    }

    func testSSHHostLoginAndPlatformUseStrictDestinationGrammar() {
        let invalid: [[String]] = [
            ssh("-oProxyCommand=evil"), ssh("user@host"), ssh("ssh://host"), ssh("bad host"),
            ssh("bad..example"), ssh("host", login: "-root"), ssh("host", login: "remote user"),
            ssh("host", login: "remote", platform: "Linux"), ssh("host", login: "remote", platform: "darwin"),
            ssh("host", login: "remote", platform: "linux") + ["--ssh-command", "anything"],
        ]
        for destination in invalid {
            XCTAssertThrowsError(
                try peerEnrollmentActivateOptions(
                    arguments: command() + destination, options: .init()), destination.description
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "usage")
            }
        }
    }

    func testRejectsInvalidCustodyNamesAndAcceptsExactByteBounds() throws {
        for user in ["", "-user", "name with space", "useré", String(repeating: "u", count: 129)] {
            XCTAssertThrowsError(
                try peerEnrollmentActivateOptions(
                    arguments: command(user: user), options: .init()), user)
        }

        let file = String(repeating: "f", count: 4096)
        let root = "/" + String(repeating: "r", count: 4095)
        let maximumUser = String(repeating: "u", count: 128)
        var bounded = command(user: maximumUser)
        bounded[bounded.firstIndex(of: "relative/target-enrollment.bin")!] = file
        bounded[bounded.firstIndex(of: "/var/lib/tractanda")!] = root
        let parsed = try parse(bounded)
        XCTAssertEqual(parsed.filePath.utf8.count, 4096)
        XCTAssertEqual(parsed.targetRoot.utf8.count, 4096)
        guard case .existingUser(let parsedUser) = parsed.custody else {
            return XCTFail("Expected exact 128-byte user name to parse.")
        }
        XCTAssertEqual(parsedUser, maximumUser)
    }

    func testOtherCommandsAreNotClaimedAndParserDoesNotReadTheInputFile() throws {
        XCTAssertNil(try peerEnrollmentActivateOptions(arguments: ["info", "/tmp/socket"], options: .init()))
        XCTAssertNil(try peerEnrollmentActivateOptions(arguments: ["peer", "status"], options: .init()))
        XCTAssertNil(
            try peerEnrollmentActivateOptions(arguments: ["peer", "enrollment", "status"], options: .init()))

        var nonexistent = command()
        nonexistent[nonexistent.firstIndex(of: "relative/target-enrollment.bin")!] =
            "/missing/no-read-during-parse"
        XCTAssertEqual(try parse(nonexistent).filePath, "/missing/no-read-during-parse")
        var remoteNonexistent = command() + ssh()
        remoteNonexistent[remoteNonexistent.firstIndex(of: "relative/target-enrollment.bin")!] =
            "/missing/no-read-during-parse"
        let remote = try parse(remoteNonexistent)
        XCTAssertEqual(remote.filePath, "/missing/no-read-during-parse")
        XCTAssertEqual(remote.ssh?.host, "stash.example.net")
    }
}
