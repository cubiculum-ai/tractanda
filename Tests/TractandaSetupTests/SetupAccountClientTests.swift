import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaSetup

final class SetupAccountClientTests: XCTestCase {
    func testSetupDiscoversOnceAndRetainsWaitModeAndExplicitAccount() throws {
        let capability = "https://tractanda.ai/ns/jmap/1"
        let account = "00112233-4455-6677-8899-aabbccddeeff"
        var methods: [String] = []
        var waits: [String] = []
        var accountIDs: [String?] = []
        let client = SetupNativeClient(
            socket: "/private/tmp/setup-account.sock", serverUser: "daemon",
            sendForTesting: { request, wait in
                let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
                let call = (envelope["methodCalls"] as! [[Any]])[0]
                let method = call[0] as! String
                methods.append(method)
                switch wait {
                case .bounded: waits.append("bounded")
                case .untilCompletion: waits.append("untilCompletion")
                }
                accountIDs.append((call[1] as! [String: Any])["accountId"] as? String)
                let result: [String: Any] =
                    method == "TractandaSession/get"
                    ? [
                        "profile": "tractanda.local-session.v1", "username": "alice", "state": "metadata",
                        "capabilities": ["urn:ietf:params:jmap:core": [:], capability: [:]],
                        "accounts": [account: ["accountCapabilities": [capability: [:]]]],
                        "primaryAccounts": [capability: account],
                    ] : ["ok": true]
                return try JSONSerialization.data(withJSONObject: [
                    "sessionState": "metadata", "methodResponses": [[method, result, call[2]]],
                ])
            })
        _ = try client.call("TractandaStore/info")
        _ = try client.call("TractandaItem/commit", ["accountId": "foreign"], waitForMutation: true)
        XCTAssertEqual(methods, ["TractandaSession/get", "TractandaStore/info", "TractandaItem/commit"])
        XCTAssertEqual(accountIDs, [nil, account, "foreign"])
        XCTAssertEqual(waits, ["bounded", "bounded", "untilCompletion"])
    }
}
