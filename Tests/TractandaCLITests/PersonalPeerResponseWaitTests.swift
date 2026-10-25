import Foundation
import XCTest

@testable import TractandaCLI
@testable import TractandaCore

final class PersonalPeerResponseWaitTests: XCTestCase {
    private func answer(_ method: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["methodResponses": [[method, ["ok": true], "cli"]]])
    }
    func testPersonalPeerNativeCommandsUseQualifiedLongWaitAndKeepExistingConnectionIdentity() throws {
        var options = ConnectionOptions()
        options.socketPath = "/private/tmp/personal-peer-wait.sock"
        for (arguments, operation) in [
            (["personal-peer", "identity"], "identity"),
            (
                ["personal-peer", "baseline-finish", "01010101-0101-1101-8101-010101010101"],
                "baseline.finish"
            ),
        ] {
            var sent = 0
            XCTAssertTrue(
                try personalPeerCommand(
                    arguments, options: options, hasConnectionOptions: true,
                    sendForTesting: { connection, request, wait in
                        sent += 1
                        guard case .installerMutation = wait else {
                            XCTFail(
                                "Personal peer operations must use the qualified long-response receive path")
                            return try self.answer("TractandaPeerPersonal/admin")
                        }
                        XCTAssertEqual(connection.socketPath, options.socketPath)
                        XCTAssertNil(
                            connection.managedService, "Enrollment must not autostart/replay a daemon")
                        let envelope = try XCTUnwrap(
                            JSONSerialization.jsonObject(with: request) as? [String: Any])
                        let calls = try XCTUnwrap(envelope["methodCalls"] as? [[Any]])
                        XCTAssertEqual(calls.count, 1)
                        XCTAssertEqual(calls[0][0] as? String, "TractandaPeerPersonal/admin")
                        let fields = try XCTUnwrap(calls[0][1] as? [String: Any])
                        XCTAssertEqual(fields["operation"] as? String, operation)
                        return try self.answer("TractandaPeerPersonal/admin")
                    }))
            XCTAssertEqual(sent, 1)
        }
    }
    func testGenericCallKeepsBoundedDefaultAndForwardsExplicitLongWait() throws {
        let connection = ServerConnection(socketPath: "/private/tmp/call-wait.sock", serverUser: "daemon")
        var seen: [String] = []
        let sender: CLIRequestSender = { selected, _, wait in
            XCTAssertEqual(selected.serverUser, "daemon")
            switch wait {
            case .bounded: seen.append("bounded")
            case .installerMutation: seen.append("installerMutation")
            }
            return try self.answer("TractandaStore/info")
        }
        _ = try call(connection, "TractandaStore/info", [:], sendForTesting: sender)
        _ = try call(
            connection, "TractandaStore/info", [:], responseWait: .installerMutation, sendForTesting: sender)
        XCTAssertEqual(seen, ["bounded", "installerMutation"])
    }
}
