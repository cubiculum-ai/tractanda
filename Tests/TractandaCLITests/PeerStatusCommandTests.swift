import XCTest

@testable import TractandaCLI
@testable import TractandaCore

final class PeerStatusCommandTests: XCTestCase {
    func testStatusUsesExistingSelectionAndDisablesServiceStartup() throws {
        var options = ConnectionOptions()
        options.profile = "production"
        let selected = try XCTUnwrap(peerStatusOptions(arguments: ["peer", "status"], options: options))
        XCTAssertEqual(selected.profile, "production")
        XCTAssertFalse(selected.startsService)
        var explicit = ConnectionOptions()
        explicit.socketPath = "/tmp/peer-status.sock"
        let socket = try XCTUnwrap(peerStatusOptions(arguments: ["peer", "status"], options: explicit))
        XCTAssertEqual(socket.socketPath, explicit.socketPath)
        XCTAssertFalse(socket.startsService)
        XCTAssertNil(try socket.resolve().managedService)
        XCTAssertNil(try peerStatusOptions(arguments: ["info"], options: options))
    }
    func testStatusAcceptsNoIdentityFlagsArgumentsOrMutationCommands() throws {
        for arguments in [
            ["peer"], ["peer", "status", "/tmp/store"],
            ["peer", "status", "--uid", "0"], ["peer", "status", "--admin"],
            ["peer", "rotate"], ["peer", "status", "status"],
        ] {
            XCTAssertThrowsError(try peerStatusOptions(arguments: arguments, options: .init())) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "usage")
            }
        }
    }
}
