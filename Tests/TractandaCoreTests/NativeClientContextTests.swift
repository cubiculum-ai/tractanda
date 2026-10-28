import Foundation
import XCTest

@testable import TractandaCore

final class NativeClientContextTests: XCTestCase {
    private final class Transcript {
        let account = "00112233-4455-6677-8899-aabbccddeeff"
        let capability = "https://tractanda.ai/ns/jmap/1"
        var metadata = "metadata-1"
        var requests: [Data] = []
        func send(_ request: Data) throws -> Data {
            requests.append(request)
            let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
            let calls = object["methodCalls"] as! [[Any]]
            let responses: [[Any]] = calls.map { call in
                let method = call[0] as! String
                let payload: [String: Any]
                if method == "TractandaSession/get" {
                    payload = [
                        "profile": "tractanda.local-session.v1", "state": metadata,
                        "username": "alice",
                        "capabilities": ["urn:ietf:params:jmap:core": [:], capability: [:]],
                        "accounts": [
                            account: [
                                "name": "Store", "isPersonal": false, "isReadOnly": false,
                                "accountCapabilities": [capability: [:]],
                            ]
                        ], "primaryAccounts": [capability: account],
                    ]
                } else {
                    payload = call[1] as! [String: Any]
                }
                return [method, payload, call[2]]
            }
            return try JSONSerialization.data(withJSONObject: [
                "sessionState": metadata, "methodResponses": responses,
            ])
        }
        func calls() throws -> [[Any]] {
            try requests.flatMap {
                (try JSONSerialization.jsonObject(with: $0) as! [String: Any])["methodCalls"] as! [[Any]]
            }
        }
    }

    func testFacadeDiscoversOncePreservesExplicitAccountAndRefreshesWithoutReplay() throws {
        let transcript = Transcript()
        let client = ItemClient(transport: transcript.send)
        _ = try client.call("TractandaStore/info")
        _ = try client.call("TractandaStore/info", arguments: ["accountId": "foreign"])
        transcript.metadata = "metadata-2"
        _ = try client.call("TractandaItem/commit", arguments: ["operationID": "one-effect"])
        _ = try client.call("TractandaStore/info")
        let calls = try transcript.calls()
        XCTAssertEqual(
            calls.map { $0[0] as! String },
            [
                "TractandaSession/get", "TractandaStore/info", "TractandaStore/info", "TractandaItem/commit",
                "TractandaSession/get", "TractandaStore/info",
            ])
        XCTAssertEqual((calls[1][1] as! [String: Any])["accountId"] as? String, transcript.account)
        XCTAssertEqual((calls[2][1] as! [String: Any])["accountId"] as? String, "foreign")
    }

    func testPairedQueryAndGetBothUseDiscoveredAccountAndRetainReference() throws {
        let transcript = Transcript()
        _ = try ItemClient(transport: transcript.send).queryThenGet(arguments: ["limit": 1])
        let calls = try transcript.calls()
        XCTAssertEqual(calls.count, 3)
        for call in calls.dropFirst() {
            XCTAssertEqual((call[1] as! [String: Any])["accountId"] as? String, transcript.account)
        }
        let reference = (calls[2][1] as! [String: Any])["#ids"] as? [String: String]
        XCTAssertEqual(reference, ["resultOf": "query", "name": "TractandaItem/query", "path": "/ids"])
    }

    func testCheckedExportTransportBorrowsOuterDiscoveryAndForwardsExactEnvelope() throws {
        let transcript = Transcript()
        let parent = ItemClient(transport: transcript.send)
        _ = try parent.call("TractandaStore/info")
        transcript.metadata = "metadata-2"
        _ = try parent.call("TractandaStore/info")  // Invalidate for the next request.
        var checkedRequests: [Data] = []
        let pinned = parent.checkedForwarding { request in
            let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
            let call = (object["methodCalls"] as! [[Any]])[0]
            XCTAssertEqual(call[0] as? String, "TractandaAttachment/list")
            let args = call[1] as! [String: Any]
            XCTAssertEqual(args["itemID"] as? String, "item")
            XCTAssertEqual(args["revisionID"] as? String, "revision")
            checkedRequests.append(request)
            return try parent.sendNativeEnvelope(request)
        }
        _ = try pinned.call(
            "TractandaAttachment/list", arguments: ["itemID": "item", "revisionID": "revision"])
        XCTAssertEqual(checkedRequests.count, 1)
        XCTAssertEqual(checkedRequests[0], transcript.requests.last)
        XCTAssertEqual(try transcript.calls().filter { $0[0] as? String == "TractandaSession/get" }.count, 2)
    }
}
