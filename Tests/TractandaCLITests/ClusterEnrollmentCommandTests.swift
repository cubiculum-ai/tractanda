import Foundation
import TractandaClient
import TractandaCore
import XCTest

@testable import TractandaCLI

final class ClusterEnrollmentCommandTests: XCTestCase {
    private func invitation() throws -> PersonalEnrollmentInvitation {
        func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        return try .init(
            metadata: .init(
                operationID: id(), storeID: id(), issuerReplicaID: id(), bootstrapReplicaID: id(),
                pairingID: id(), endpoints: [.init(host: "source.fixture", port: 48732)], expiresAt: 20_000,
                expectedMembershipDigest: nil), secret: .init(bytes: [UInt8](repeating: 77, count: 32)))
    }
    private func options() -> ConnectionOptions {
        var options = ConnectionOptions()
        options.socketPath = "/tmp/trac121-cli-private-fixture.sock"
        return options
    }
    private func directory() throws -> URL {
        #if os(macOS)
            let parent = URL(fileURLWithPath: "/private/tmp")
        #else
            let parent = URL(fileURLWithPath: "/tmp")
        #endif
        let root = parent.appendingPathComponent("enrollment-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func reply(_ name: String, _ value: JMAPValue) throws -> Data {
        try JMAPValue.object([
            .init("sessionState", .string("private-fixture")),
            .init(
                "methodResponses",
                .array([JMAPInvocation(name: name, arguments: value, callID: "cluster").value])),
        ]).encoded()
    }
    func testInvalidInviteSinkAndJSONAloneNeverSendOrIssue() throws {
        var calls = 0
        let sender: CLIPrivateEnrollmentSender = { _, _ in
            calls += 1
            return Data()
        }
        XCTAssertThrowsError(
            try clusterEnrollmentCommand(
                arguments: ["cluster", "invite", "--json"], options: options(), sendForTesting: sender))
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = root.appendingPathComponent("existing")
        let original = Data("preserved operator file".utf8)
        try original.write(to: occupied)
        XCTAssertThrowsError(
            try clusterEnrollmentCommand(
                arguments: ["cluster", "invite", "--out", occupied.path], options: options(),
                sendForTesting: sender))
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try Data(contentsOf: occupied) == original, "An occupied output must not change.")
    }
    func testPrivateInviteJSONContainsMetadataOnlyAndUsesPrivateCapability() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("code")
        let invitation = try invitation()
        let code = try invitation.privateCode()
        var outputs: [Data] = []
        let sender: CLIPrivateEnrollmentSender = { _, data in
            let request = try JMAPRequest.decode(data)
            XCTAssertEqual(request.using, [NativePersonalEnrollment.capability])
            XCTAssertEqual(request.methodCalls[0].name, "TractandaEnrollmentLocal/invite")
            return try self.reply(
                "TractandaEnrollmentLocal/invite",
                .object([
                    .init("code", .string(code)),
                    .init("invitation", try .decode(JSON.encode(invitation.metadata))),
                ]))
        }
        XCTAssertTrue(
            try clusterEnrollmentCommand(
                arguments: [
                    "cluster", "invite", "--hostname", "source.fixture", "--out", file.path, "--json",
                ],
                options: options(), output: { outputs.append($0) }, sendForTesting: sender))
        XCTAssertEqual(outputs.count, 1)
        XCTAssertFalse(String(decoding: outputs[0], as: UTF8.self).contains(code))
        XCTAssertEqual(
            try JSON.decode(PersonalEnrollmentInvitationMetadata.self, outputs[0]), invitation.metadata)
        XCTAssertTrue(
            try ClusterEnrollmentPrivateInput.readInvitation(fromPrivateFile: file.path).privateCode() == code
        )
    }
    func testJoinWatchFollowsExactFamilyWhenAcceptedOlderOperationWins() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("code")
        let invitation = try invitation()
        try ClusterEnrollmentPrivateInput.writeInvitation(invitation, toPrivateFile: file.path)
        let family = invitation.metadata.familyID
        let accepted = try UUID.makeVersion1().uuidString.lowercased()
        var calls = 0
        var outputData = Data()
        let sender: CLIPrivateEnrollmentSender = { _, data in
            calls += 1
            let call = try XCTUnwrap(JMAPRequest.decode(data).methodCalls.first)
            if calls == 1 {
                XCTAssertEqual(call.name, "TractandaEnrollmentLocal/join")
                return try self.reply(
                    call.name,
                    .object([
                        .init("phase", .string("authenticatingUnusedRenewal")),
                        .init("operationID", .string(invitation.metadata.operationID)),
                        .init("familyID", .string(family)),
                    ]))
            }
            XCTAssertEqual(call.name, "TractandaEnrollmentLocal/status")
            XCTAssertEqual(call.arguments["familyID"]?.text, family)
            XCTAssertNil(call.arguments["operationID"])
            return try self.reply(
                call.name,
                .object([
                    .init("phase", .string("complete")),
                    .init("operationID", .string(accepted)), .init("familyID", .string(family)),
                ]))
        }
        XCTAssertTrue(
            try clusterEnrollmentCommand(
                arguments: [
                    "cluster", "join", "--replace-expired", "--hostname", "target.fixture",
                    "--code-file", file.path, "--json",
                ], options: options(), output: { outputData.append($0) }, sendForTesting: sender))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try JMAPValue.decode(outputData)["operationID"]?.text, accepted)
        XCTAssertFalse(String(decoding: outputData, as: UTF8.self).contains(try invitation.privateCode()))
    }
    func testOutputRacePreservesUnknownFileAndExactPrivateResumeRecoversSameCode() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("raced")
        let recovered = root.appendingPathComponent("recovered")
        let invitation = try invitation()
        let code = try invitation.privateCode()
        let original = Data("concurrently created operator file".utf8)
        var count = 0
        let sender: CLIPrivateEnrollmentSender = { _, data in
            let request = try JMAPRequest.decode(data)
            count += 1
            if count == 1 {
                try original.write(to: first)
            } else {
                XCTAssertEqual(request.methodCalls[0].arguments["resume"], .bool(true))
            }
            return try self.reply(
                "TractandaEnrollmentLocal/invite",
                .object([
                    .init("code", .string(code)),
                    .init("invitation", try .decode(JSON.encode(invitation.metadata))),
                ]))
        }
        XCTAssertThrowsError(
            try clusterEnrollmentCommand(
                arguments: ["cluster", "invite", "--hostname", "source.fixture", "--out", first.path],
                options: options(), output: { _ in XCTFail("Private code must not become ordinary output") },
                sendForTesting: sender)
        ) {
            XCTAssertFalse(String(describing: $0).contains(code))
            XCTAssertTrue((($0 as? TractandaError)?.message ?? "").contains("--resume"))
        }
        XCTAssertTrue(
            try Data(contentsOf: first) == original, "A concurrently created output must not change.")
        XCTAssertTrue(
            try clusterEnrollmentCommand(
                arguments: ["cluster", "invite", "--resume", "--out", recovered.path, "--json"],
                options: options(), output: { _ in }, sendForTesting: sender))
        XCTAssertEqual(count, 2)
        XCTAssertTrue(
            try ClusterEnrollmentPrivateInput.readInvitation(fromPrivateFile: recovered.path).privateCode()
                == code)
    }
    func testExplicitPrepareParsesOnceBeforeProfileLookupAndSubmitsSameCodePrivately() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("code")
        let invitation = try invitation()
        let code = try invitation.privateCode()
        try ClusterEnrollmentPrivateInput.writeInvitation(invitation, toPrivateFile: file.path)
        var selected = ConnectionOptions()
        selected.profile = "fresh-fixture-missing-profile"
        var prepared = false
        var sent = false
        let prepare: (String, PersonalEnrollmentInvitationMetadata) throws -> ServerConnection = {
            instance, metadata in
            XCTAssertEqual(instance, "fresh-fixture-missing-profile")
            XCTAssertEqual(metadata, invitation.metadata)
            XCTAssertFalse(sent)
            prepared = true
            return .init(socketPath: "/tmp/fresh-prepared-fixture.sock", serverUser: "daemon")
        }
        let sender: CLIPrivateEnrollmentSender = { connection, data in
            XCTAssertTrue(prepared)
            XCTAssertEqual(connection.socketPath, "/tmp/fresh-prepared-fixture.sock")
            let request = try JMAPRequest.decode(data)
            XCTAssertEqual(request.methodCalls[0].name, "TractandaEnrollmentLocal/join")
            XCTAssertTrue(
                request.methodCalls[0].arguments["code"]?.text == code,
                "The same private code must reach the accepted target.")
            sent = true
            return try self.reply(
                "TractandaEnrollmentLocal/join",
                .object([
                    .init("phase", .string("claiming")),
                    .init("operationID", .string(invitation.metadata.operationID)),
                ]))
        }
        var outputData = Data()
        XCTAssertTrue(
            try clusterEnrollmentCommand(
                arguments: [
                    "cluster", "join", "--prepare-new", "fresh-fixture-missing-profile",
                    "--hostname", "target.fixture", "--code-file", file.path, "--no-wait", "--json",
                ], options: selected,
                output: { outputData = $0 }, sendForTesting: sender, prepareNewForTesting: prepare))
        XCTAssertTrue(prepared && sent)
        XCTAssertFalse(String(decoding: outputData, as: UTF8.self).contains(code))
    }
    func testPrepareRejectsConflictingConnectionAndMalformedCodeBeforeSetup() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("malformed")
        try Data("malformed-private-code".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var prepared = false
        var sent = false
        let prepare: (String, PersonalEnrollmentInvitationMetadata) throws -> ServerConnection = { _, _ in
            prepared = true
            return .init(socketPath: "/tmp/never-prepared.sock")
        }
        let sender: CLIPrivateEnrollmentSender = { _, _ in
            sent = true
            return Data()
        }
        let arguments = [
            "cluster", "join", "--prepare-new", "fresh-fixture", "--hostname", "target.fixture",
            "--code-file", file.path, "--no-wait",
        ]
        XCTAssertThrowsError(
            try clusterEnrollmentCommand(
                arguments: arguments, options: options(), sendForTesting: sender,
                prepareNewForTesting: prepare))
        var selected = ConnectionOptions()
        selected.profile = "fresh-fixture"
        XCTAssertThrowsError(
            try clusterEnrollmentCommand(
                arguments: arguments, options: selected, sendForTesting: sender, prepareNewForTesting: prepare
            )
        ) {
            XCTAssertFalse(String(describing: $0).contains("malformed-private-code"))
        }
        XCTAssertFalse(prepared || sent)
    }
    func testPrepareFailureNeverSubmitsJoinOrPrintsCode() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("code")
        let invitation = try invitation()
        let code = try invitation.privateCode()
        try ClusterEnrollmentPrivateInput.writeInvitation(invitation, toPrivateFile: file.path)
        var selected = ConnectionOptions()
        selected.profile = "fresh-fixture"
        var prepared = false
        var sent = false
        var outputSeen = false
        XCTAssertThrowsError(
            try clusterEnrollmentCommand(
                arguments: [
                    "cluster", "join", "--prepare-new", "fresh-fixture",
                    "--hostname", "target.fixture", "--code-file", file.path, "--no-wait",
                ], options: selected,
                output: { _ in outputSeen = true },
                sendForTesting: { _, _ in
                    sent = true
                    return Data()
                },
                prepareNewForTesting: { _, _ in
                    prepared = true
                    throw TractandaError("setupFailed", "Explicit target preparation failed.")
                })
        ) {
            XCTAssertFalse(String(describing: $0).contains(code))
        }
        XCTAssertTrue(prepared)
        XCTAssertFalse(sent || outputSeen)
    }
}
