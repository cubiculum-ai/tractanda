import XCTest

@testable import TractandaCLI
@testable import TractandaCore

final class PeerCredentialCommandTests: XCTestCase {
    private let operationID = "00000000-0000-1000-8000-000000000100"

    private func origin(_ value: Int) -> String {
        String(format: "00000000-0000-1000-8000-%012x", value)
    }

    private func command(origins: [String], operationID: String? = nil) -> [String] {
        var arguments = ["peer", "credential", "register", "--file", "/private/peer-credential.json"]
        for value in origins { arguments += ["--origin", value] }
        arguments += ["--operation-id", operationID ?? self.operationID]
        return arguments
    }

    func testRegistrationSortsUniqueCanonicalOriginsAndNeverStartsService() throws {
        var profile = ConnectionOptions()
        profile.profile = "production"
        let parsed = try XCTUnwrap(
            peerCredentialRegistrationOptions(
                arguments: command(origins: [origin(3), origin(1), origin(2)]), options: profile))
        XCTAssertEqual(parsed.filePath, "/private/peer-credential.json")
        XCTAssertEqual(parsed.permittedOrigins, [origin(1), origin(2), origin(3)])
        XCTAssertEqual(parsed.operationID, operationID)
        XCTAssertEqual(parsed.connection.profile, "production")
        XCTAssertFalse(parsed.connection.startsService)

        var socket = ConnectionOptions()
        socket.socketPath = "/tmp/peer-command.sock"
        let explicit = try XCTUnwrap(
            peerCredentialRegistrationOptions(
                arguments: command(origins: [origin(1)]), options: socket))
        XCTAssertEqual(explicit.connection.socketPath, socket.socketPath)
        XCTAssertFalse(explicit.connection.startsService)
    }

    func testRegistrationRequiresExactFlagsAndExplicitCanonicalV1IDs() throws {
        let valid = command(origins: [origin(1)])
        let invalidCommands: [[String]] = [
            ["peer", "credential", "register"],
            ["peer", "credential", "register", "--file", "/private/credential", "--origin", origin(1)],
            [
                "peer", "credential", "register", "--file", "/private/credential", "--origin", origin(1),
                "--operation-id", "not-a-uuid",
            ],
            [
                "peer", "credential", "register", "--file", "/private/credential", "--origin", origin(1),
                "--operation-id", "00000000-0000-4000-8000-000000000100",
            ],
            valid + ["--unknown", "value"],
            valid + ["--file", "/private/second.json"],
            valid + ["--operation-id", operationID],
            command(origins: [origin(1), origin(1)]),
            command(origins: [origin(0xab).uppercased()]),
            command(origins: ["00000000-0000-4000-8000-000000000001"]),
            [
                "peer", "credential", "register", "--file", "--origin", origin(1), "--operation-id",
                operationID,
            ],
        ]
        for arguments in invalidCommands {
            XCTAssertThrowsError(
                try peerCredentialRegistrationOptions(arguments: arguments, options: .init()), "\(arguments)"
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "usage")
            }
        }
    }

    func testRegistrationBoundsOriginsAt256AndAcceptsNonPeerCommandsWithoutClaimingThem() throws {
        let origins = (1...256).map(origin)
        let accepted = try XCTUnwrap(
            peerCredentialRegistrationOptions(
                arguments: command(origins: origins), options: .init()))
        XCTAssertEqual(accepted.permittedOrigins.count, 256)
        XCTAssertEqual(accepted.permittedOrigins, origins.sorted())
        XCTAssertThrowsError(
            try peerCredentialRegistrationOptions(
                arguments: command(origins: (1...257).map(origin)), options: .init()))

        XCTAssertNil(
            try peerCredentialRegistrationOptions(arguments: ["info", "/tmp/socket"], options: .init()))
        XCTAssertNil(try peerCredentialRegistrationOptions(arguments: ["peer", "status"], options: .init()))
        XCTAssertThrowsError(
            try peerCredentialRegistrationOptions(
                arguments: ["peer", "credential", "rotate"], options: .init())
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "usage")
        }
    }
}
