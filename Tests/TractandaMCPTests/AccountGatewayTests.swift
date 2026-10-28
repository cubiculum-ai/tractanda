import Foundation
import XCTest

@testable import TractandaMCP

final class AccountGatewayTests: XCTestCase {
    private actor Transcript {
        var methods: [String] = []
        var accounts: [String?] = []
        func send(_ request: Data) throws -> Data {
            let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
            let call = (envelope["methodCalls"] as! [[Any]])[0]
            let method = call[0] as! String
            methods.append(method)
            let arguments = call[1] as! [String: Any]
            accounts.append(arguments["accountId"] as? String)
            let capability = "https://tractanda.ai/ns/jmap/1"
            let account = "00112233-4455-6677-8899-aabbccddeeff"
            let payload: [String: Any] =
                method == "TractandaSession/get"
                ? [
                    "profile": "tractanda.local-session.v1", "username": "alice", "state": "metadata",
                    "capabilities": ["urn:ietf:params:jmap:core": [:], capability: [:]],
                    "accounts": [account: ["accountCapabilities": [capability: [:]]]],
                    "primaryAccounts": [capability: account],
                ] : ["ok": true]
            return try JSONSerialization.data(withJSONObject: [
                "sessionState": "metadata", "methodResponses": [[method, payload, call[2]]],
            ])
        }
        func snapshot() -> ([String], [String?]) { (methods, accounts) }
    }

    func testBackendGatewayRetainsDiscoveryAndPreservesExplicitAccount() async throws {
        let transcript = Transcript()
        let gateway = NativeGateway(backend: { try await transcript.send($0) })
        _ = try await gateway.call("TractandaStore/info", arguments: [:])
        _ = try await gateway.call("TractandaStore/info", arguments: ["accountId": .string("foreign")])
        let (methods, accounts) = await transcript.snapshot()
        XCTAssertEqual(methods, ["TractandaSession/get", "TractandaStore/info", "TractandaStore/info"])
        XCTAssertEqual(accounts, [nil, "00112233-4455-6677-8899-aabbccddeeff", "foreign"])
    }
}
