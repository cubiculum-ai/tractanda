import Foundation
import Testing

@testable import TractandaClient

private struct LegacyCommit: Encodable {
    let action: CommitRequest.Action
    let itemID: String?
    let expectedRevisionID: String?
    let classID: String?
    let changes: [String: ItemValue]
    let unset: [String]
    let operationID: String
}

@Test func fieldOperationsPreserveLegacyRetryBytesAndRoundTrip() throws {
    let request = CommitRequest(
        action: .revise, itemID: "item", expectedRevisionID: "revision",
        changes: ["subject": .text("x")], operationID: "operation")
    let old = LegacyCommit(
        action: request.action, itemID: request.itemID,
        expectedRevisionID: request.expectedRevisionID, classID: request.classID,
        changes: request.changes, unset: request.unset, operationID: request.operationID)
    #expect(try JSON.encode(request) == JSON.encode(old))
    var partial = request
    partial.fieldOperations = [
        .init(op: .append, field: "notes", value: .text("one")),
        .init(op: .setKey, field: "metadata", key: "x.y", value: .integer(2)),
        .init(op: .removeKey, field: "metadata", key: "z"),
    ]
    #expect(try JSON.decode(CommitRequest.self, JSON.encode(partial)) == partial)
}

@Test func fieldOperationRejectsUnknownOrInapplicableMembers() throws {
    let invalid = [
        #"{"op":"append","field":"a","value":{"type":"text","value":"x"},"key":null}"#,
        #"{"op":"append","field":"a","value":{"type":"text","value":"x"},"extra":1}"#,
        #"{"op":"append","field":"a"}"#,
        #"{"op":"setKey","field":"a","key":"b"}"#,
        #"{"op":"removeKey","field":"a","key":"b","value":null}"#,
    ]
    for text in invalid {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ItemFieldOperation.self, from: Data(text.utf8))
        }
    }
}

@Test func fieldOperationAndListTailWireConvertTaggedIntegers() throws {
    let request = CommitRequest(
        action: .revise, itemID: "item", expectedRevisionID: "revision", operationID: "op",
        fieldOperations: [.init(op: .append, field: "notes", value: .integer(Int64.max))])
    let domain = try JMAPValue.decode(JSON.encode(request))
    let wire = try TractandaJMAPCodec.argumentsToWire(method: "TractandaItem/commit", arguments: domain)
    #expect(wire["fieldOperations"]?.elements?.first?["value"]?["value"]?.text == String(Int64.max))
    #expect(
        try TractandaJMAPCodec.argumentsFromWire(method: "TractandaItem/commit", arguments: wire) == domain)
    let tail = try JMAPValue.decode(
        Data(#"{"values":[{"type":"integer","value":9223372036854775807}]}"#.utf8))
    let wireTail = try TractandaJMAPCodec.extensionResultToWire(
        method: "TractandaItem/listTail", result: tail)
    #expect(wireTail["values"]?.elements?.first?["value"]?.text == String(Int64.max))
    #expect(
        try TractandaJMAPCodec.extensionResultFromWire(method: "TractandaItem/listTail", result: wireTail)
            == tail)
}

private actor TailScriptedTransport: ItemTransport {
    let result: [String: JMAPValue]
    init(_ result: [String: JMAPValue]) { self.result = result }
    func send(_ request: Data) async throws -> Data {
        let call = try JMAPValue.decode(request)["methodCalls"]!.elements![0].elements!
        let method = call[0].text!
        if method == "TractandaSession/get" {
            let id = "00112233-4455-6677-8899-aabbccddeeff"
            let cap = "https://tractanda.ai/ns/jmap/1"
            return try JSONSerialization.data(withJSONObject: [
                "sessionState": "state",
                "methodResponses": [
                    [
                        method,
                        [
                            "profile": "tractanda.local-session.v1", "username": "test", "state": "state",
                            "capabilities": [
                                "urn:ietf:params:jmap:core": [
                                    "maxSizeUpload": 0, "maxConcurrentUpload": 1,
                                    "maxSizeRequest": 8_388_608, "maxConcurrentRequests": 4,
                                    "maxCallsInRequest": 8,
                                    "maxObjectsInGet": 64, "maxObjectsInSet": 64,
                                    "collationAlgorithms": ["i;unicode-casemap"],
                                ],
                                cap: ["integerEncoding": "tagged-int64-decimal-v1"],
                            ],
                            "accounts": [
                                id: [
                                    "name": "Test", "isPersonal": false, "isReadOnly": false,
                                    "accountCapabilities": [cap: [:] as [String: String]],
                                ]
                            ],
                            "primaryAccounts": [cap: id],
                        ], call[2].text!,
                    ]
                ],
            ])
        }
        return try JMAPValue.object([
            .init(
                "methodResponses",
                .array([.array([call[0], .object(result.map { .init($0.key, $0.value) }), call[2]])])),
            .init("sessionState", .string("state")),
        ]).encoded()
    }
}

@Test func listTailSDKDecodesInt64AndRejectsMalformedResults() async throws {
    let good: [String: JMAPValue] = [
        "itemId": .string("item"), "revisionId": .string("revision"), "state": .string("state"),
        "field": .string("notes"), "fieldPresent": .bool(true), "total": .number(try JMAPNumber("1")),
        "start": .number(try JMAPNumber("0")),
        "values": .array([
            .object([.init("type", .string("integer")), .init("value", .string(String(Int64.max)))])
        ]),
    ]
    let request = ItemListTailRequest(itemID: "item", field: "notes", limit: 1)
    let result = try await ItemClient(transport: TailScriptedTransport(good)).listTail(request)
    #expect(result.values == [.integer(Int64.max)])
    var malformed = good
    malformed["values"] = .array([
        .object([.init("type", .string("integer")), .init("value", .string("9223372036854775808"))])
    ])
    await #expect(throws: (any Error).self) {
        try await ItemClient(transport: TailScriptedTransport(malformed)).listTail(request)
    }
    malformed = good
    malformed["total"] = .number(try JMAPNumber("2"))
    await #expect(throws: (any Error).self) {
        try await ItemClient(transport: TailScriptedTransport(malformed)).listTail(request)
    }
}
