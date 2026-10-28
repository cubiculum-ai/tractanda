import Foundation
import Testing

@testable import TractandaClient

private actor ReadTranscript: ItemTransport {
    var requests: [Data] = []
    let response: @Sendable (JMAPInvocation) throws -> JMAPValue
    init(response: @escaping @Sendable (JMAPInvocation) throws -> JMAPValue) { self.response = response }
    func send(_ request: Data) async throws -> Data {
        requests.append(request)
        let call = try JMAPRequest.decode(request).methodCalls[0]
        if call.name == "TractandaSession/get" { return try discoveryReply(callID: call.callID) }
        return try JMAPValue.object([
            .init(
                "methodResponses",
                .array([
                    .array([
                        .string(call.name), try response(call), .string(call.callID),
                    ])
                ]))
        ]).encoded()
    }
    func calls() throws -> [JMAPInvocation] {
        try requests.flatMap { try JMAPRequest.decode($0).methodCalls }
    }
}
private let readAccount = "00112233-4455-6677-8899-aabbccddeeff"

@Test func standardReadDTOSelectionDoesNotBecomeAFakeRevision() async throws {
    let itemID = Identifier.make()
    let transport = ReadTranscript { _ in
        .object([
            .init("accountId", .string(readAccount)), .init("state", .string("items")),
            .init("list", .array([.object([.init("id", .string(itemID))])])), .init("notFound", .array([])),
        ])
    }
    let records = try await ItemClient(transport: transport).itemRecords(ids: [itemID], properties: ["id"])
    #expect(records.list[0].id == itemID)
    #expect(records.list[0].fields == nil)
    #expect(throws: (any Error).self) { try records.list[0].canonicalRevision() }
    let calls = try await transport.calls()
    #expect(calls.last?.name == "TractandaItem/get")
    #expect(calls.last?.arguments["properties"]?.elements == [.string("id")])
    #expect(calls.last?.arguments["maxBytes"] == nil)
}

@Test func queryConvenienceWrapsCriteriaAndUsesStandardCategoryComparator() throws {
    let root = Identifier.make()
    let query = ItemQuery(
        expression: "subject == *", categoryPath: [root], position: 4,
        sort: [try ItemSort(categoryRootID: root, isAscending: false)])
    let wire = try JMAPValue.decode(JSON.encode(query))
    #expect(wire["expression"] == nil)
    #expect(wire["filter"]?["expression"]?.text == "subject == *")
    #expect(wire["calculateTotal"] == .bool(true))
    #expect(wire["sort"]?.elements?[0]["property"]?.text == "categoryMembership")
    #expect(wire["sort"]?.elements?[0]["categoryRootId"]?.text == root)
}

@Test func accountMismatchReadIsRejectedBeforeExposingDTO() async throws {
    let transport = ReadTranscript { _ in
        .object([
            .init("accountId", .string("wrong")), .init("state", .string("s")),
            .init("list", .array([])), .init("notFound", .array([])),
        ])
    }
    await #expect(
        throws: TractandaError("protocolError", "Read response account does not match the selected account.")
    ) {
        try await ItemClient(transport: transport).itemRecords(ids: [])
    }
}

@Test func outgoingArgumentsAreExplicitlyCanonicalOrAlreadyWire() async throws {
    let transport = ReadTranscript { call in call.arguments }
    let context = JMAPClientContext(transport: transport)
    let canonical = try JMAPValue.decode(
        Data(
            #"{"changes":{"min":{"type":"integer","value":-9223372036854775808},"max":{"type":"integer","value":9223372036854775807}}}"#
                .utf8))
    _ = try await context.send(method: "TractandaItem/commit", arguments: canonical)
    let wire = try #require(try await transport.calls().last?.arguments)
    #expect(wire["changes"]?["min"]?["value"]?.text == String(Int64.min))
    #expect(wire["changes"]?["max"]?["value"]?.text == String(Int64.max))
    _ = try await context.send(method: "TractandaItem/commit", arguments: wire, argumentEncoding: .wire)
    await #expect(throws: (any Error).self) {
        try await context.send(method: "TractandaItem/commit", arguments: wire)
    }
    let echo = try JMAPValue.decode(
        Data(#"{"value":{"type":"integer","value":9223372036854775807},"ordinary":1.25}"#.utf8))
    _ = try await context.send(method: "Core/echo", arguments: echo)
    #expect(try await transport.calls().last?.arguments == echo)
}

@Test func standardGetRejectsBoundedContinuationFields() async throws {
    let transport = ReadTranscript { _ in
        .object([
            .init("accountId", .string(readAccount)), .init("state", .string("items")),
            .init("list", .array([])), .init("notFound", .array([])), .init("remainingIDs", .array([])),
        ])
    }
    await #expect(
        throws: TractandaError("protocolError", "Standard get returned unsupported continuation fields.")
    ) {
        try await ItemClient(transport: transport).itemRecords(ids: [])
    }
}

@Test func zeroLimitNegativePositionAndAnchorStayValidInQueryConvenience() async throws {
    let transport = ReadTranscript { call in
        if call.name == "TractandaItem/get" {
            #expect(call.arguments["ids"]?.elements?.isEmpty == true)
            return .object([
                .init("accountId", .string(readAccount)), .init("state", .string("item-state")),
                .init("list", .array([])), .init("notFound", .array([])),
            ])
        }
        return .object([
            .init("accountId", .string(readAccount)), .init("queryState", .string("items")),
            .init("canCalculateChanges", .bool(false)), .init("position", .number(try JMAPNumber("4"))),
            .init("ids", .array([])), .init("total", .number(try JMAPNumber("5"))),
        ])
    }
    let client = ItemClient(transport: transport)
    let page = try await client.page(matching: ItemQuery(position: -1, limit: 0))
    #expect(page.position == 4)
    #expect(page.consumedCount == 0)
    #expect(page.total == 5)
    let anchor = Identifier.make()
    _ = try await client.page(matching: ItemQuery(position: 99, limit: 0, anchor: anchor, anchorOffset: -1))
    let calls = try await transport.calls()
    #expect(calls.filter { $0.name == "TractandaItem/get" }.count == 4)
    let args = try #require(calls.last { $0.name == "TractandaItem/query" }?.arguments)
    #expect(args["anchor"]?.text == anchor)
    #expect(args["position"] == nil)
    #expect(args["anchorOffset"] == .number(try JMAPNumber("-1")))
}
