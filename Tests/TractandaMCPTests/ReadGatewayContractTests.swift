import Foundation
import MCP
import XCTest

@testable import TractandaMCP

final class ReadGatewayContractTests: XCTestCase {
    private actor WireTranscript {
        var taggedIntegers: [String] = []
        var changesArguments: [[String: Any]] = []
        func send(_ request: Data) throws -> Data {
            let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
            let call = (envelope["methodCalls"] as! [[Any]])[0]
            let method = call[0] as! String
            let args = call[1] as! [String: Any]
            let capability = "https://tractanda.ai/ns/jmap/1"
            let account = "00112233-4455-6677-8899-aabbccddeeff"
            let payload: [String: Any]
            if method == "TractandaSession/get" {
                payload = [
                    "profile": "tractanda.local-session.v1", "username": "alice", "state": "metadata",
                    "capabilities": ["urn:ietf:params:jmap:core": [:], capability: [:]],
                    "accounts": [account: ["accountCapabilities": [capability: [:]]]],
                    "primaryAccounts": [capability: account],
                ]
            } else if method == "TractandaStore/info" {
                payload = ["features": ["tractanda.item-changes.v1"]]
            } else if method == "TractandaItem/changes" {
                changesArguments.append(args)
                payload = [
                    "accountId": account, "oldState": args["sinceState"]!,
                    "newState": (args["sinceState"] as? String) == "initial" ? "continuation / +" : "done",
                    "hasMoreChanges": (args["sinceState"] as? String) == "initial", "created": [],
                    "updated": [], "destroyed": [],
                ]
            } else if method == "TractandaItem/get" {
                payload = ["accountId": account, "state": "items", "list": [["id": account]], "notFound": []]
            } else {
                let changes = args["changes"] as! [String: Any]
                taggedIntegers.append((changes["n"] as! [String: Any])["value"] as! String)
                payload = ["ok": true]
            }
            return try JSONSerialization.data(withJSONObject: [
                "sessionState": "metadata", "methodResponses": [[method, payload, call[2]]],
            ])
        }
        func values() -> [String] { taggedIntegers }
        func changesStates() -> [String] { changesArguments.compactMap { $0["sinceState"] as? String } }
    }

    func testMCPAlreadyWireArgumentsAndSelectedDTOResponseRemainUntouched() async throws {
        let transcript = WireTranscript()
        let gateway = NativeGateway(backend: { try await transcript.send($0) })
        _ = try await gateway.call(
            "TractandaItem/commit",
            arguments: [
                "changes": .object([
                    "n": .object(["type": .string("integer"), "value": .string(String(Int64.min))])
                ])
            ])
        let data = try await gateway.call(
            "TractandaItem/get",
            arguments: [
                "ids": .array([.string("00112233-4455-6677-8899-aabbccddeeff")]),
                "properties": .array([.string("id")]),
            ])
        let response = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let item = (response["list"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(item.keys), ["id"])
        let integers = await transcript.values()
        XCTAssertEqual(integers, [String(Int64.min)])
    }

    func testItemChangesToolForwardsContinuation() async throws {
        let transcript = WireTranscript()
        let gateway = NativeGateway(backend: { try await transcript.send($0) })
        let tool = try XCTUnwrap(ToolCatalog.definitions().first { $0.tool.name == "tractanda_changes" })
        let first = try await MCPAdapter.callNativeTool(
            definition: tool, supplied: ["sinceState": .string("initial"), "maxChanges": .int(1)],
            gateway: gateway)
        let result = try JSONSerialization.jsonObject(with: first) as! [String: Any]
        let next = try XCTUnwrap(result["newState"] as? String)
        _ = try await MCPAdapter.callNativeTool(
            definition: tool, supplied: ["sinceState": .string(next)], gateway: gateway)
        let states = await transcript.changesStates()
        XCTAssertEqual(states, ["initial", "continuation / +"])
    }

    func testItemChangesToolContractAndFeatureGate() throws {
        let tool = try XCTUnwrap(ToolCatalog.definitions().first { $0.tool.name == "tractanda_changes" })
        XCTAssertEqual(tool.nativeMethod, "TractandaItem/changes")
        XCTAssertEqual(tool.requiredFeature, "tractanda.item-changes.v1")
        XCTAssertTrue(tool.readOnly)
        let args = try tool.arguments(from: ["sinceState": .string("next:≠"), "maxChanges": .int(2)])
        XCTAssertEqual(args["sinceState"], .string("next:≠"))
        XCTAssertEqual(args["maxChanges"], .int(2))
        XCTAssertNil(args["limit"])
        XCTAssertThrowsError(try tool.arguments(from: [:]))
        XCTAssertThrowsError(try tool.arguments(from: ["sinceState": .int(1)]))
        XCTAssertThrowsError(try tool.arguments(from: ["sinceState": .string("x"), "maxChanges": .int(0)]))
        XCTAssertThrowsError(
            try tool.arguments(from: ["sinceState": .string("x"), "operationID": .string("x")]))
        XCTAssertThrowsError(
            try MCPAdapter.requireFeature(
                "tractanda.item-changes.v1", serverInfoData: Data(#"{"features":[]}"#.utf8)))
        XCTAssertNoThrow(
            try MCPAdapter.requireFeature(
                "tractanda.item-changes.v1",
                serverInfoData: Data(#"{"features":["tractanda.item-changes.v1"]}"#.utf8)))
    }

    func testCatalogUsesStandardReadSelectorsAndCollectionRevisionIDs() throws {
        let definitions = Dictionary(
            uniqueKeysWithValues: ToolCatalog.definitions().map { ($0.tool.name, $0) })
        let query = try XCTUnwrap(definitions["tractanda_query"])
        let args = try query.arguments(from: [
            "filter": .object(["text": .string("needle")]), "limit": .int(0), "calculateTotal": .bool(false),
        ])
        XCTAssertEqual(args["limit"], .int(0))
        XCTAssertNil(args["position"])
        let get = try XCTUnwrap(definitions["tractanda_get"])
        _ = try get.arguments(from: [
            "ids": .array([]), "properties": .array([.string("id")]),
            "fieldProperties": .array([.string("subject")]),
        ])
        XCTAssertThrowsError(try get.arguments(from: ["ids": .array([]), "maxBytes": .int(8192)]))
        XCTAssertNotNil(definitions["tractanda_get_bounded"])
        let revision = try XCTUnwrap(definitions["tractanda_revision"])
        XCTAssertEqual(revision.required, ["ids"])
        let item = "00112233-4455-6677-8899-aabbccddeeff"
        let historical = "11112233-4455-6677-8899-aabbccddeeff"
        let request = try ResourceCatalog.itemRequest(
            for: "tractanda://items/\(item)/revisions/\(historical)")
        XCTAssertEqual(request.arguments["ids"], .array([.string(historical)]))
        XCTAssertNil(request.arguments["itemID"])
        XCTAssertNil(request.arguments["revisionID"])
    }
}
