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

extension SetupAccountClientTests {
    private func sampleRelease() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "setup-receipt-" + UUID().uuidString)
        let templates = directory.appendingPathComponent("templates")
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["entries": [["fields": [String: Any]()]]])
        try data.write(to: templates.appendingPathComponent("starter-categories.json"))
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func compactReceipt(operationID: String, index: Int, replayed: Bool = false) throws
        -> [String: Any]
    {
        let itemID = String(format: "%08x-0000-1000-8000-001122334455", index)
        let revisionID = String(format: "%08x-0000-1000-8000-001122334455", index + 100)
        let revision = try Revision(fields: [
            "itemID": .text(itemID), "revisionID": .text(revisionID), "classID": .text("Item"),
            "actor": .text("uid:0"), "operationID": .text(operationID), "schemaVersion": .integer(1),
            "createdAt": .date("2026-11-07T12:00:00.000000Z"),
            "modifiedAt": .date("2026-11-07T12:00:00.000000Z"),
        ])
        let receipt = try MutationReceipt(
            CommitResult(revision: revision, wasReplayed: replayed, isIndexReady: false, warnings: []))
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
    }

    private func sampleClient(receipt: @escaping ([String: Any]) throws -> [String: Any])
        -> SetupNativeClient
    {
        let capability = "https://tractanda.ai/ns/jmap/1"
        let account = "00112233-4455-6677-8899-aabbccddeeff"
        return SetupNativeClient(
            socket: "/private/tmp/setup-sample.sock", serverUser: "daemon",
            sendForTesting: { request, wait in
                let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
                let call = (envelope["methodCalls"] as! [[Any]])[0]
                let method = call[0] as! String
                let arguments = call[1] as! [String: Any]
                let result: [String: Any]
                switch method {
                case "TractandaSession/get":
                    result = [
                        "profile": "tractanda.local-session.v1", "username": "root", "state": "metadata",
                        "capabilities": ["urn:ietf:params:jmap:core": [:], capability: [:]],
                        "accounts": [account: ["accountCapabilities": [capability: [:]]]],
                        "primaryAccounts": [capability: account],
                    ]
                case "TractandaCategory/installTemplate":
                    result = [
                        "items": [
                            "status": "000000a0-0000-1000-8000-001122334455",
                            "status.ready": "000000a1-0000-1000-8000-001122334455",
                            "status.doing": "000000a2-0000-1000-8000-001122334455",
                            "status.done": "000000a3-0000-1000-8000-001122334455",
                        ]
                    ]
                default:
                    XCTAssertEqual(method, "TractandaItem/commit")
                    if case .untilCompletion = wait {
                    } else {
                        XCTFail("Sample writes require completion wait")
                    }
                    result = try receipt(arguments)
                }
                return try JSONSerialization.data(withJSONObject: [
                    "sessionState": "metadata", "methodResponses": [[method, result, call[2]]],
                ])
            })
    }

    func testSampleSeedConsumesCurrentReceiptsAndRetainsExactRetryIntent() throws {
        let release = try sampleRelease()
        var published: [String: (intent: Data, index: Int)] = [:]
        var operations: [String] = []
        let client = sampleClient { arguments in
            let operationID = arguments["operationID"] as! String
            operations.append(operationID)
            let intent = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            if let previous = published[operationID] {
                XCTAssertEqual(intent, previous.intent)
                return try self.compactReceipt(
                    operationID: operationID, index: previous.index, replayed: true)
            }
            let index = published.count + 1
            published[operationID] = (intent, index)
            let fields = arguments["changes"] as! [String: Any]
            let permissions = (fields["permissions"] as! [String: Any])["value"] as! [String: Any]
            XCTAssertEqual((permissions["owner"] as! [String: Any])["value"] as? String, "root")
            XCTAssertEqual((permissions["mode"] as! [String: Any])["value"] as? String, "384")
            return try self.compactReceipt(operationID: operationID, index: index)
        }
        let first = try client.seed(owner: "root", instance: "fixture", release: release)
        let second = try client.seed(owner: "root", instance: "fixture", release: release)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first["projectRootID"], "00000001-0000-1000-8000-001122334455")
        XCTAssertEqual(first["projectID"], "00000002-0000-1000-8000-001122334455")
        XCTAssertEqual(published.count, 4)
        let expected = ["projects", "project", "welcome", "view"].map { "setup-sample-v1-fixture-" + $0 }
        XCTAssertEqual(operations, expected + expected)
    }

    func testSampleSeedRejectsReceiptForAnotherOperation() throws {
        let release = try sampleRelease()
        var attempts = 0
        let client = sampleClient { _ in
            attempts += 1
            return try self.compactReceipt(operationID: "another-operation", index: 1)
        }
        XCTAssertThrowsError(try client.seed(owner: "root", instance: "fixture", release: release)) {
            XCTAssertTrue(String(describing: $0).contains("another operation"))
        }
        XCTAssertEqual(attempts, 1)
    }

    func testSampleSeedRejectsMalformedAndLegacyMutationResponses() throws {
        let release = try sampleRelease()
        for legacy in [false, true] {
            let client = sampleClient { arguments in
                if legacy {
                    return ["revision": ["fields": ["itemID": ["type": "text", "value": "unvalidated"]]]]
                }
                var result = try self.compactReceipt(
                    operationID: arguments["operationID"] as! String, index: 1)
                result["itemId"] = "unvalidated"
                return result
            }
            XCTAssertThrowsError(try client.seed(owner: "root", instance: "fixture", release: release))
        }
    }
}
