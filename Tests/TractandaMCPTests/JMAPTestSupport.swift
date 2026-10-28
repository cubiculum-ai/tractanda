import Foundation
import XCTest

/// Independent local Session fixture for MCP's real account-discovering native client.
/// Domain mocks handle only the requested operation; discovery has its own response and call ID.
func mcpFixtureDiscoveryReply(_ request: Data) throws -> Data? {
    let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: request) as? [String: Any])
    let calls = try XCTUnwrap(envelope["methodCalls"] as? [[Any]])
    let call = try XCTUnwrap(calls.first)
    guard call.count == 3, call[0] as? String == "TractandaSession/get" else { return nil }
    let accountID = "00112233-4455-6677-8899-aabbccddeeff"
    let capability = "https://tractanda.ai/ns/jmap/1"
    let state = "mcp-fixture-session"
    let payload: [String: Any] = [
        "profile": "tractanda.local-session.v1", "username": "test", "state": state,
        "capabilities": [
            "urn:ietf:params:jmap:core": [
                "maxSizeUpload": 0, "maxConcurrentUpload": 1,
                "maxSizeRequest": 8_388_608, "maxConcurrentRequests": 4, "maxCallsInRequest": 8,
                "maxObjectsInGet": 64, "maxObjectsInSet": 64,
                "collationAlgorithms": ["i;unicode-casemap"],
            ],
            capability: ["integerEncoding": "tagged-int64-decimal-v1"],
        ],
        "accounts": [
            accountID: [
                "name": "Test", "isPersonal": false, "isReadOnly": false,
                "accountCapabilities": [capability: [:] as [String: String]],
            ]
        ],
        "primaryAccounts": [capability: accountID],
    ]
    return try JSONSerialization.data(withJSONObject: [
        "sessionState": state, "methodResponses": [[call[0], payload, call[2]]],
    ])
}
