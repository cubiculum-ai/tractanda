import Foundation
import XCTest

@testable import TractandaCLI
@testable import TractandaCore

final class PersonalPeerResponseWaitTests: XCTestCase {
    private func answer(_ method: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["methodResponses": [[method, ["ok": true], "cli"]]])
    }
    private func discoveryAnswer(_ request: Data) throws -> Data? {
        let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let call = (envelope["methodCalls"] as! [[Any]])[0]
        guard call[0] as? String == "TractandaSession/get" else { return nil }
        let capability = "https://tractanda.ai/ns/jmap/1"
        let account = "00112233-4455-6677-8899-aabbccddeeff"
        let document: [String: Any] = [
            "profile": "tractanda.local-session.v1", "username": "alice", "state": "metadata",
            "capabilities": ["urn:ietf:params:jmap:core": [:], capability: [:]],
            "accounts": [account: ["accountCapabilities": [capability: [:]]]],
            "primaryAccounts": [capability: account],
        ]
        return try JSONSerialization.data(withJSONObject: [
            "methodResponses": [["TractandaSession/get", document, call[2]]]
        ])
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
                        if let discovery = try self.discoveryAnswer(request) { return discovery }
                        sent += 1
                        guard case .untilCompletion = wait else {
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
                        XCTAssertEqual(fields["accountId"] as? String, "00112233-4455-6677-8899-aabbccddeeff")
                        return try self.answer("TractandaPeerPersonal/admin")
                    }))
            XCTAssertEqual(sent, 1)
        }
    }
    func testGenericCallWaitsUntilCompletionAndForwardsExplicitProbeMode() throws {
        let connection = ServerConnection(socketPath: "/private/tmp/call-wait.sock", serverUser: "daemon")
        var seen: [String] = []
        let sender: CLIRequestSender = { selected, request, wait in
            if let discovery = try self.discoveryAnswer(request) { return discovery }
            XCTAssertEqual(selected.serverUser, "daemon")
            switch wait {
            case .bounded: seen.append("bounded")
            case .untilCompletion: seen.append("untilCompletion")
            }
            return try self.answer("TractandaStore/info")
        }
        _ = try call(connection, "TractandaStore/info", [:], sendForTesting: sender)
        _ = try call(
            connection, "TractandaStore/info", [:], responseWait: .bounded, sendForTesting: sender)
        XCTAssertEqual(seen, ["untilCompletion", "bounded"])
    }
    func testRawCallWireModeAndTypedCommandCanonicalModeRemainExplicit() throws {
        let connection = ServerConnection(socketPath: "/private/tmp/wire-mode.sock", serverUser: "daemon")
        var values: [String] = []
        let sender: CLIRequestSender = { _, request, _ in
            if let discovery = try self.discoveryAnswer(request) { return discovery }
            let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
            let call = (envelope["methodCalls"] as! [[Any]])[0]
            let changes = (call[1] as! [String: Any])["changes"] as! [String: Any]
            values.append((changes["n"] as! [String: Any])["value"] as! String)
            return try self.answer("TractandaItem/commit")
        }
        _ = try call(
            connection, "TractandaItem/commit", ["changes": ["n": ["type": "integer", "value": Int64.min]]],
            sendForTesting: sender)
        _ = try call(
            connection, "TractandaItem/commit",
            ["changes": ["n": ["type": "integer", "value": String(Int64.min)]]], sendForTesting: sender,
            argumentsAreWire: true)
        XCTAssertEqual(values, [String(Int64.min), String(Int64.min)])
    }

}
