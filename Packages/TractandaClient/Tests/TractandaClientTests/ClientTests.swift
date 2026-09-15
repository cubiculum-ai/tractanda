import Foundation
import Testing

@testable import TractandaClient

private actor ScriptedTransport: ItemTransport {
    var responses: [Data]
    var requests: [Data] = []
    init(_ responses: [Data]) { self.responses = responses }
    func send(_ request: Data) async throws -> Data {
        requests.append(request)
        return responses.removeFirst()
    }
}

func revision(_ subject: String) throws -> Revision {
    try Revision(fields: [
        "itemID": .text(Identifier.make()), "revisionID": .text(Identifier.make()),
        "classID": .text("NoteItem"), "actor": .text("user:test"), "operationID": .text("fixture"),
        "requestIdentity": .text("fixture"), "schemaVersion": .integer(1),
        "createdAt": .date("2026-09-08T00:00:00Z"), "modifiedAt": .date("2026-09-08T00:00:00Z"),
        "subject": .text(subject), "body": .text("Original body"),
        "arbitrary.key": .integer(9_007_199_254_740_993),
        "selection": .object([
            "language": .text(ItemClient.queryProfile), "expression": .text("subject == *"),
            "futureSetting": .text("preserve me"),
        ]),
    ])
}

func reply(_ method: String, _ value: Any, tag: String = "client") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["methodResponses": [[method, value, tag]]])
}
func object(_ value: some Encodable) throws -> Any {
    try JSONSerialization.jsonObject(with: JSON.encode(value))
}

@Test func pagesPreserveServerOrderAndIntegerPrecision() async throws {
    let first = try revision("First")
    let second = try revision("Second")
    let transport = try ScriptedTransport([
        reply(
            "TractandaItem/query",
            [
                "ids": [first.itemID, second.itemID], "position": 0, "total": 3, "queryState": "state-1",
            ]),
        reply("TractandaItem/get", ["list": object([second, first]), "notFound": [], "state": "state-1"]),
    ])
    let page = try await ItemClient(transport: transport).page(matching: ItemQuery(limit: 2))
    #expect(page.items == [first, second])
    #expect(page.hasNextPage)
    #expect(page.items[0].fields["arbitrary.key"] == .integer(9_007_199_254_740_993))
    #expect(await transport.requests.count == 2)
}

@Test func changingOrIncompletePagesAreRejected() async throws {
    let item = try revision("Shared")
    let transport = try ScriptedTransport([
        reply(
            "TractandaItem/query",
            [
                "ids": [item.itemID], "position": 0, "total": 1, "queryState": "before",
            ]),
        reply("TractandaItem/get", ["list": [], "notFound": [item.itemID], "state": "after"]),
    ])
    await #expect(throws: TractandaError("stateChanged", "Items changed while loading; refresh the view.")) {
        try await ItemClient(transport: transport).page(matching: ItemQuery())
    }
}

@Test func nativeErrorsRetainTheirMeaningAndCheckCorrelation() async throws {
    let request = CommitRequest(operationID: "edit")
    for tag in ["client", "another-call"] {
        let transport = try ScriptedTransport([
            reply("error", ["type": "revisionConflict", "description": "Changed by someone else."], tag: tag)
        ])
        do {
            _ = try await ItemClient(transport: transport).commit(request)
            Issue.record("Expected a failure")
        } catch let error as TractandaError {
            #expect(error.code == (tag == "client" ? "revisionConflict" : "protocolError"))
        }
    }
}

@Test func draftEditsPreserveUnknownFieldsAndWholeEditSemantics() throws {
    let base = try revision("Original")
    var draft = try ItemEditorDraft(base: base)
    #expect(try draft.makeRequest() == nil)
    draft.subject = "Edited"
    draft.body = "Unicode 界 e\u{301}\nSecond line"
    draft.rule = "subject ==[c] \"*edited*\""
    draft.className = "EmailMessageItem"
    let request = try #require(try draft.makeRequest(operationID: "whole-edit"))
    #expect(request.itemID == base.itemID)
    #expect(request.expectedRevisionID == base.revisionID)
    #expect(request.operationID == "whole-edit")
    #expect(request.action == .retype)
    #expect(Set(request.changes.keys) == ["subject", "body", "selection"])
    #expect(request.changes["selection"]?.map?["futureSetting"] == .text("preserve me"))
    let restored = try JSON.decode(CommitRequest.self, JSON.encode(request))
    #expect(restored == request)
    draft.rule = ""
    #expect(try draft.makeRequest()?.unset == ["selection"])
}

@Test func captureAndLimitsAreIndependentOfUIFramework() throws {
    let category = Identifier.make()
    var draft = try ItemEditorDraft(assignedCategories: [category, category])
    draft.subject = "A new item"
    let request = try #require(try draft.makeRequest(operationID: "capture"))
    #expect(request.action == .create)
    #expect(request.changes["categoryOverrides"]?.map == [category: .text("include")])
    draft.body = String(repeating: "界", count: 30_000)
    #expect(throws: TractandaError.self) { try draft.makeRequest() }
}
