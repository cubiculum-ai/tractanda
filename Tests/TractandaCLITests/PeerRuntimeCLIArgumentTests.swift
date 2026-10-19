import XCTest

@testable import TractandaCLI

final class PeerRuntimeCLIArgumentTests: XCTestCase {
    func testBoardProjectAndPeerRuntimePathRemainDistinctOptions() throws {
        let project = "03030303-0303-1303-8303-030303030303"
        let board = ["daemon", "/tmp/store", "/tmp/server.sock",
            "--project-root", "01010101-0101-1101-8101-010101010101",
            "--status-root", "02020202-0202-1202-8202-020202020202"]
        let existing = try daemonConfiguration(from: board + ["--project", project])
        XCTAssertEqual(existing.initialProjectID, project)
        XCTAssertNil(existing.peerRuntimeConfigurationPath)
        let onlyRuntime = try daemonConfiguration(from: board + ["--peer-runtime-config", "/tmp/peer.json"])
        XCTAssertNil(onlyRuntime.initialProjectID)
        XCTAssertEqual(onlyRuntime.peerRuntimeConfigurationPath, "/tmp/peer.json")
        let both = try daemonConfiguration(from: board + ["--project", project,
            "--peer-runtime-config", "/tmp/peer.json"])
        XCTAssertEqual(both.initialProjectID, project)
        XCTAssertEqual(both.peerRuntimeConfigurationPath, "/tmp/peer.json")
        XCTAssertThrowsError(try daemonConfiguration(from: board + ["--project", "/tmp/not-an-id"]))
        XCTAssertThrowsError(try daemonConfiguration(from: board + ["--project", project, "--project", project]))
    }

    func testDaemonOptionStoresOneAbsolutePeerRuntimeConfigPath() throws {
        let absent = try daemonConfiguration(from: ["daemon", "/tmp/store", "/tmp/server.sock"])
        XCTAssertNil(absent.peerRuntimeConfigurationPath)
        let configuration = try daemonConfiguration(from: [
            "daemon", "/tmp/store", "/tmp/server.sock", "--peer-runtime-config", "/etc/tractanda/peer.json",
        ])
        XCTAssertEqual(configuration.peerRuntimeConfigurationPath, "/etc/tractanda/peer.json")

        for arguments in [
            ["daemon", "/tmp/store", "/tmp/server.sock", "--peer-runtime-config"],
            ["daemon", "/tmp/store", "/tmp/server.sock", "--peer-runtime-config", "relative.json"],
            ["daemon", "/tmp/store", "/tmp/server.sock", "--peer-runtime-config", "/tmp/a.json",
             "--peer-runtime-config", "/tmp/b.json"],
            ["daemon", "/tmp/store", "/tmp/server.sock", "--unknown-option"],
        ] {
            XCTAssertThrowsError(try daemonConfiguration(from: arguments))
        }
    }

    func testManagedServiceOptionRejectsMissingDuplicateUnknownAndNonSharedUse() throws {
        let invalidCommands = [
            ["service", "prepare", "peer", "/tmp/store", "--shared", "--peer-runtime-config"],
            ["service", "prepare", "peer", "/tmp/store", "--shared", "--peer-runtime-config", "/tmp/a.json",
             "--peer-runtime-config", "/tmp/b.json"],
            ["service", "prepare", "peer", "/tmp/store", "--shared", "--peer-runtime-config", "relative.json"],
            ["service", "prepare", "peer", "/tmp/store", "--peer-runtime-config", "/tmp/peer.json"],
            ["service", "prepare", "peer", "/tmp/store", "--shared", "--unknown-option"],
        ]
        for command in invalidCommands {
            XCTAssertThrowsError(try handleConnectionCommand(command))
        }
    }
}
