import XCTest

@testable import TractandaCore

final class ResponseBudgetTests: XCTestCase {
    private func request(_ calls: [[Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": calls,
        ])
    }

    private func firstCall(_ response: Data) throws -> [Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
        return try XCTUnwrap(calls.first)
    }

    private func encodedSize(_ call: [Any]) throws -> Int {
        try JSONSerialization.data(withJSONObject: call).count
    }

    func testMixedReadEnvelopeRetainsEarlierReferenceAndRejectsLaterOverflowWhole() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let body = String(repeating: "x", count: 256)
        var item = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("budget target"), "body": .text(body)],
                operationID: Identifier.make())
        )
        .revision
        for revision in 1...3 {
            item = try store.commit(
                CommitRequest(
                    action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                    changes: ["body": .text("r\(revision)-" + body)], operationID: Identifier.make())
            )
            .revision
        }
        let service = ItemService(store: store)
        let queryRequest = try request([
            ["TractandaItem/query", ["expression": "subject == \"budget target\"", "limit": 1], "query"]
        ])
        let getRequest = try request([
            ["TractandaItem/get", ["ids": [item.itemID]], "get"]
        ])
        let historyRequest = try request([
            ["TractandaItem/history", ["itemID": item.itemID, "limit": 4], "history"]
        ])
        let queryBytes = try encodedSize(firstCall(service.handle(queryRequest, peerUID: store.ownerUID)))
        let getBytes = try encodedSize(firstCall(service.handle(getRequest, peerUID: store.ownerUID)))
        let historyBytes = try encodedSize(firstCall(service.handle(historyRequest, peerUID: store.ownerUID)))
        let historyStorageBytes = try store.history(item.itemID)
            .map { try JSON.encode($0).count }
            .reduce(0, +)
        let canonicalHistoryBytes = try store.exportCatalogueForVerification()
            .filter { $0.itemID == item.itemID }
            .reduce(0) { $0 + Int($1.size) }
        let budget =
            max(
                queryBytes, getBytes, historyBytes, historyStorageBytes,
                canonicalHistoryBytes) + 128
        XCTAssertLessThan(budget, 16 * 1024, "Fixture should keep the pooled response budget small.")
        var extraQueries = 0
        while queryBytes + getBytes + extraQueries * queryBytes + historyBytes <= budget {
            extraQueries += 1
            guard extraQueries <= 20 else {
                return XCTFail("Small fixture cannot exercise aggregate budget.")
            }
        }
        let prefixBytes = queryBytes + getBytes + extraQueries * queryBytes
        XCTAssertLessThan(prefixBytes, budget)
        XCTAssertGreaterThan(prefixBytes + historyBytes, budget)
        XCTAssertGreaterThan(budget - prefixBytes, 256)

        store.pooledRecordByteLimitForTesting = budget
        var calls: [[Any]] = [
            ["TractandaItem/query", ["expression": "subject == \"budget target\"", "limit": 1], "q"],
            [
                "TractandaItem/get",
                ["#ids": ["resultOf": "q", "name": "TractandaItem/query", "path": "/ids"]],
                "g",
            ],
        ]
        for number in 0..<extraQueries {
            calls.append([
                "TractandaItem/query",
                ["expression": "subject == \"budget target\"", "limit": 1],
                "extra-\(number)",
            ])
        }
        calls.append(["TractandaItem/history", ["itemID": item.itemID, "limit": 4], "h"])
        let mixed = try request(calls)
        let response = service.handle(mixed, peerUID: store.ownerUID)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let results = try XCTUnwrap(object["methodResponses"] as? [[Any]])
        XCTAssertEqual(results.count, extraQueries + 3)
        XCTAssertEqual(results[0][0] as? String, "TractandaItem/query")
        let query = try XCTUnwrap(results[0][1] as? [String: Any])
        XCTAssertEqual(query["ids"] as? [String], [item.itemID])
        XCTAssertEqual(results[1][0] as? String, "TractandaItem/get")
        let get = try XCTUnwrap(results[1][1] as? [String: Any])
        XCTAssertEqual((get["list"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(
            results[2..<(results.count - 1)].allSatisfy {
                $0[0] as? String == "TractandaItem/query"
            })
        XCTAssertEqual(results.last?[0] as? String, "error")
        let failure = try XCTUnwrap(results.last?[1] as? [String: Any])
        XCTAssertEqual(failure["type"] as? String, "responseTooLarge")
        XCTAssertNil(failure["total"])
        XCTAssertNil(failure["list"])
        XCTAssertLessThanOrEqual(
            try JSONSerialization.data(withJSONObject: results).count, budget + 64,
            "Retained method responses must remain within the measured aggregate budget.")
    }
}
