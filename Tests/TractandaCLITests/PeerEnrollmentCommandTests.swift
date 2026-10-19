import XCTest
@testable import TractandaCLI
@testable import TractandaCore

final class PeerEnrollmentCommandTests: XCTestCase {
    private let operationID = "00000000-0000-1000-8000-000000000100"

    private func options() -> ConnectionOptions {
        var result = ConnectionOptions()
        result.profile = "production"
        result.startsService = true
        return result
    }

    private func parse(_ command: [String], options: ConnectionOptions? = nil) throws -> PeerEnrollmentOptions {
        try XCTUnwrap(peerEnrollmentOptions(arguments: command, options: options ?? self.options()))
    }

    private func base(_ subcommand: String) -> [String] { ["peer", "enrollment", subcommand] }

    func testPairAndBeginGrammarPreserveConnectionWithoutResolvingIt() throws {
        let pair = try parse(base("pair") + [
            "--preparation", "/private/preparation.json", "--out", "/private/pair.json",
            "--source-peer", "nœud-β", "--target-peer", "target-π", "--source-role", "responder",
        ])
        XCTAssertEqual(pair.connection.profile, "production")
        XCTAssertFalse(pair.connection.startsService)
        guard case let .pair(preparation, output, source, target, isInitiator) = pair.command else {
            return XCTFail("Expected local pair command.")
        }
        XCTAssertEqual(preparation, "/private/preparation.json")
        XCTAssertEqual(output, "/private/pair.json")
        XCTAssertEqual(source, "nœud-β")
        XCTAssertEqual(target, "target-π")
        XCTAssertFalse(isInitiator)

        var socket = ConnectionOptions()
        socket.socketPath = "/tmp/enrollment.sock"
        let begin = try parse(base("begin") + ["--file", "/private/pair-input.json"], options: socket)
        XCTAssertEqual(begin.connection.socketPath, socket.socketPath)
        XCTAssertFalse(begin.connection.startsService)
        guard case let .begin(file) = begin.command else { return XCTFail("Expected begin command.") }
        XCTAssertEqual(file, "/private/pair-input.json")
    }

    func testPairAcceptsInitiatorAndExactAliasAndPathBounds() throws {
        let alias = String(repeating: "é", count: 126) + "Aßx"
        let path = "/" + String(repeating: "p", count: 4095)
        XCTAssertEqual(alias.utf8.count, 256)
        XCTAssertEqual(path.utf8.count, 4096)
        let parsed = try parse(base("pair") + [
            "--preparation", path, "--out", path, "--source-peer", alias,
            "--target-peer", "Other-ø", "--source-role", "initiator",
        ])
        guard case let .pair(preparation, output, source, target, isInitiator) = parsed.command else {
            return XCTFail("Expected local pair command.")
        }
        XCTAssertEqual(preparation, path)
        XCTAssertEqual(output, path)
        XCTAssertEqual(source, alias)
        XCTAssertEqual(target, "Other-ø")
        XCTAssertTrue(isInitiator)
    }

    func testOperationCommandsMapOnlyBoundedValues() throws {
        for (name, action) in [("step", NativePeerEnrollment.Action.step),
            ("status", .status), ("accept", .accept), ("register", .register)] {
            let parsed = try parse(base(name) + ["--operation-id", operationID])
            XCTAssertFalse(parsed.connection.startsService)
            guard case let .action(actual, operation) = parsed.command else {
                return XCTFail("Expected action for \(name).")
            }
            XCTAssertEqual(actual, action)
            XCTAssertEqual(operation, operationID)
        }

        let exported = try parse(base("export-target") + ["--operation-id", operationID, "--out", "/private/target.json"])
        guard case let .exportTarget(exportID, exportPath) = exported.command else {
            return XCTFail("Expected export-target command.")
        }
        XCTAssertEqual(exportID, operationID)
        XCTAssertEqual(exportPath, "/private/target.json")

        let defaultRead = try parse(base("read") + [
            "--operation-id", operationID, "--descriptor", "/private/descriptor.json",
            "--offset", "0", "--out", "/private/chunk.bin",
        ])
        guard case let .read(readID, descriptor, offset, maximum, output) = defaultRead.command else {
            return XCTFail("Expected read command.")
        }
        XCTAssertEqual(readID, operationID)
        XCTAssertEqual(descriptor, "/private/descriptor.json")
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(maximum, 1_048_576)
        XCTAssertEqual(output, "/private/chunk.bin")

        let boundedRead = try parse(base("read") + [
            "--operation-id", operationID, "--descriptor", "/private/descriptor.json",
            "--offset", String(Int.max), "--maximum-bytes", "1048576", "--out", "/private/chunk.bin",
        ])
        guard case let .read(_, _, boundedOffset, boundedMaximum, _) = boundedRead.command else {
            return XCTFail("Expected bounded read command.")
        }
        XCTAssertEqual(boundedOffset, Int.max)
        XCTAssertEqual(boundedMaximum, 1_048_576)
    }

    func testRejectsUnknownDuplicateMissingAndPrivilegedOrLifecycleOptions() {
        let validPair = base("pair") + ["--preparation", "/private/p.json", "--out", "/private/o.json",
            "--source-peer", "source", "--target-peer", "target", "--source-role", "initiator"]
        let validBegin = base("begin") + ["--file", "/private/pair.json"]
        let validAction = base("register") + ["--operation-id", operationID]
        let invalid: [[String]] = [
            ["peer", "enrollment"],
            ["peer", "enrollment", "other"],
            base("pair") + ["--preparation", "/private/p.json", "--out", "/private/o.json",
                "--source-peer", "source", "--target-peer", "target"],
            validPair + ["--out", "/private/again.json"],
            validPair + ["positional"],
            base("pair") + ["--preparation", "", "--out", "/private/o.json",
                "--source-peer", "source", "--target-peer", "target", "--source-role", "initiator"],
            base("pair") + ["--preparation", "/private/p.json", "--out", "/private/o.json",
                "--source-peer", "local", "--target-peer", "target", "--source-role", "initiator"],
            base("pair") + ["--preparation", "/private/p.json", "--out", "/private/o.json",
                "--source-peer", "source\u{1}", "--target-peer", "target", "--source-role", "initiator"],
            base("pair") + ["--preparation", "/private/p.json", "--out", "/private/o.json",
                "--source-peer", String(repeating: "é", count: 129), "--target-peer", "target", "--source-role", "initiator"],
            base("pair") + ["--preparation", "/private/p.json", "--out", "/private/o.json",
                "--source-peer", "source", "--target-peer", "target", "--source-role", "leader"],
            validBegin + ["--file", "/private/again.json"],
            base("begin") + ["--file", "--uid"],
            base("pair") + ["--preparation", "--out", "/private/o.json", "--source-peer", "source",
                "--target-peer", "target", "--source-role", "initiator"],
            base("pair") + ["--preparation", "/private/p.json", "--out", "/private/o.json",
                "--source-peer", "--target-peer", "target", "--source-role", "initiator"],
            validBegin + ["--uid", "1000"],
            validAction + ["--administrator", "true"],
            validAction + ["--origin", "00000000-0000-1000-8000-000000000001"],
            validAction + ["--target-activate", "true"],
            validAction + ["--ssh", "host"],
            validAction + ["--lifecycle", "retire"],
            base("step") + ["--operation-id", "00000000-0000-4000-8000-000000000100"],
            base("step") + ["--operation-id", "00000000-0000-1000-8000-00000000010A"],
            base("step") + ["--operation-id", "not-a-uuid"],
            base("export-target") + ["--operation-id", operationID],
            base("read") + ["--operation-id", operationID, "--descriptor", "/private/d.json", "--offset", "-1", "--out", "/private/o"],
            base("read") + ["--operation-id", operationID, "--descriptor", "/private/d.json", "--offset", "999999999999999999999999999999", "--out", "/private/o"],
            base("read") + ["--operation-id", operationID, "--descriptor", "/private/d.json", "--offset", "0", "--maximum-bytes", "0", "--out", "/private/o"],
            base("read") + ["--operation-id", operationID, "--descriptor", "/private/d.json", "--offset", "0", "--maximum-bytes", "1048577", "--out", "/private/o"],
            base("read") + ["--operation-id", operationID, "--descriptor", "/private/d.json", "--offset", "0", "--maximum-bytes", "many", "--out", "/private/o"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try peerEnrollmentOptions(arguments: arguments, options: .init()), "\(arguments)") {
                XCTAssertEqual(($0 as? TractandaError)?.code, "usage")
            }
        }
    }

    func testRejectsEveryPathOutsideTheBoundedNonNulGrammarAndIgnoresOtherCommands() throws {
        let path = String(repeating: "x", count: 4097)
        let invalidPaths = ["", "/private/with\0nul", path]
        for value in invalidPaths {
            XCTAssertThrowsError(try peerEnrollmentOptions(
                arguments: base("begin") + ["--file", value], options: .init()))
        }
        XCTAssertThrowsError(try peerEnrollmentOptions(
            arguments: base("read") + ["--operation-id", operationID, "--descriptor", "/private/d.json",
                "--offset", "0", "--out", "/private/with\0nul"], options: .init()))
        XCTAssertThrowsError(try peerEnrollmentOptions(
            arguments: base("export-target") + ["--operation-id", operationID, "--out", path], options: .init()))

        XCTAssertNil(try peerEnrollmentOptions(arguments: ["info", "/tmp/socket"], options: .init()))
        XCTAssertNil(try peerEnrollmentOptions(arguments: ["peer", "status"], options: .init()))
        XCTAssertNil(try peerEnrollmentOptions(arguments: ["peer", "credential", "register"], options: .init()))
    }
}
