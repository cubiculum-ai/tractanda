import Foundation
import Testing

@testable import TractandaClient

private let historyWireLarge: Int64 = 9_007_199_254_740_993
private actor HistoryWireTransport: ItemTransport {
    let result: @Sendable (JMAPInvocation) throws -> JMAPValue
    var calls: [JMAPInvocation] = []
    init(_ result: @escaping @Sendable (JMAPInvocation) throws -> JMAPValue) { self.result = result }
    func send(_ data: Data) async throws -> Data {
        let call = try JMAPRequest.decode(data).methodCalls[0]
        calls.append(call)
        if call.name == TractandaJMAP.discoveryMethod { return try discoveryReply(callID: call.callID) }
        return try JMAPValue.object([
            .init("sessionState", .string("metadata-1")),
            .init("methodResponses", .array([JMAPInvocation(name: call.name, arguments: result(call), callID: call.callID).value])),
        ]).encoded()
    }
}
private func historyWireAttachment(_ count: Int64) throws -> AttachmentDescriptor {
    try .init(attachmentID: "11111111-1111-1111-8111-111111111111", filename: "fixture.bin",
        mediaType: "application/octet-stream", byteCount: count, sha256: String(repeating: "a", count: 64))
}
private func historyWireRevision(itemID: String? = nil) throws -> Revision {
    var fields = try revision("history", itemID: itemID).fields
    fields["classID"] = .text("SourceDoc")
    fields["attachments"] = .list([try historyWireAttachment(historyWireLarge).itemValue])
    fields["sourceDocument"] = .object(["byteCount": .integer(.max), "parts": .list([
        .object(["offset": .integer(historyWireLarge), "minimum": .integer(.min), "literal": .text(String(historyWireLarge))]),
    ])])
    return try .init(fields: fields)
}
private func historyWirePage(_ records: [JMAPRevisionRecord], total: Int,
    dispositions: [String: HistoricalDisposition] = [:]) throws -> JMAPValue {
    .object([
        .init("accountId", .string("00112233-4455-6677-8899-aabbccddeeff")), .init("state", .string("items")),
        .init("list", .array(try records.map { try .decode(JSON.encode($0)) })),
        .init("total", .number(try JMAPNumber(String(total)))),
        .init("historicalDispositions", try .decode(JSON.encode(dispositions))),
    ])
}

@Test func typedHistoryPreservesAttachmentAndNestedSourceDocumentEntireInt64Domain() async throws {
    let original = try historyWireRevision(), record = try JMAPRevisionRecord(original)
    let wire = try historyWirePage([record], total: 4, dispositions: [original.revisionID: .demoted])
    let transport = HistoryWireTransport { _ in wire }
    let page = try await ItemClient(transport: transport).history(itemID: original.itemID, position: 3, limit: 1)
    #expect(page.list == [original]); #expect(page.total == 4)
    #expect(page.historicalDispositions == [original.revisionID: .demoted])
    #expect(try JSON.encode(page.list[0]) == JSON.encode(original))
    #expect(try AttachmentDescriptor.descriptors(in: page.list[0].fields)[0].byteCount == historyWireLarge)
    #expect(try TractandaJMAPCodec.extensionResultFromWire(method: "TractandaItem/history", result: wire) == wire)
    #expect(throws: (any Error).self) { try JSON.decode(ItemHistoryResult.self, wire.encoded()) }
}

@Test func historyCheckedCanonicalConversionRejectsUnsupportedPagesAndPartialProjection() async throws {
    let original = try historyWireRevision(), record = try JMAPRevisionRecord(original), foreign = try historyWireRevision()
    for wire in [
        try historyWirePage([record], total: 0), try historyWirePage([record, record], total: 2),
        try historyWirePage([JMAPRevisionRecord(foreign)], total: 1),
        try historyWirePage([record], total: 1, dispositions: [Identifier.make(): .demoted]),
        try historyWirePage([JMAPRevisionRecord(original, properties: ["id"])], total: 1),
        try historyWirePage([], total: -1),
    ] {
        let transport = HistoryWireTransport { _ in wire }
        await #expect(throws: (any Error).self) { try await ItemClient(transport: transport).history(itemID: original.itemID) }
    }
    let empty = try historyWirePage([], total: 4)
    let result = try JSON.decode(JMAPHistoryResponse.self, empty.encoded()).canonicalResult(itemID: original.itemID, position: 4, limit: 1)
    #expect(result.list.isEmpty)
    #expect(throws: (any Error).self) { try JSON.decode(JMAPHistoryResponse.self, empty.encoded()).canonicalResult(itemID: original.itemID, position: 5, limit: 1) }
}

@Test func typedAttachmentScalarsStayNumericAndExactAboveDoublePrecision() async throws {
    for count in [historyWireLarge, Int64.max] {
        let descriptor = try historyWireAttachment(count), itemID = Identifier.make(), revisionID = Identifier.make()
        let listed = try JMAPValue.decode(JSON.encode(AttachmentListResult(itemID: itemID, revisionID: revisionID, attachments: [descriptor])))
        let content = try JMAPValue.decode(JSON.encode(AttachmentContentResult(attachment: descriptor,
            offset: count - 3, nextOffset: count, isComplete: true, data: Data([1, 2, 3]))))
        let transport = HistoryWireTransport { $0.name == "TractandaAttachment/list" ? listed : content }
        let client = ItemClient(transport: transport)
        #expect(try await client.listAttachments(itemID: itemID).attachments[0].byteCount == count)
        let value = try await client.attachmentContent(itemID: itemID, attachmentID: descriptor.attachmentID, offset: count - 3)
        #expect(value.offset == count - 3); #expect(value.nextOffset == count)
        #expect(value.attachment.byteCount == count); #expect(value.data == Data([1, 2, 3]))
        let calls = await transport.calls
        #expect(calls.last?.arguments["offset"] == .number(try JMAPNumber(String(count - 3))))
    }
}

@Test func typedHistoryAndAttachmentScalarSchemaMismatchesFailClosed() async throws {
    let original = try historyWireRevision(), descriptor = try historyWireAttachment(historyWireLarge)
    let record = try JMAPValue.decode(JSON.encode(JMAPRevisionRecord(original)))
    for badValue in [JMAPValue.number(try JMAPNumber("42")), .string("01"), .string("9223372036854775808")] {
        let broken = JMAPValue.object(record.members!.map { member in
            member.name == "fields" ? .init("fields", .object(member.value.members! + [
                .init("bad", .object([.init("type", .string("integer")), .init("value", badValue)])),
            ])) : member
        })
        let wire = JMAPValue.object([.init("accountId", .string("00112233-4455-6677-8899-aabbccddeeff")),
            .init("state", .string("items")), .init("total", .number(try JMAPNumber("1"))), .init("list", .array([broken]))])
        let transport = HistoryWireTransport { _ in wire }
        await #expect(throws: (any Error).self) { try await ItemClient(transport: transport).history(itemID: original.itemID) }
    }
    let badDescriptor = JMAPValue.object([
        .init("attachmentID", .string(descriptor.attachmentID)), .init("filename", .string(descriptor.filename)),
        .init("mediaType", .string(descriptor.mediaType)), .init("sha256", .string(descriptor.sha256)),
        .init("byteCount", .string(String(historyWireLarge))),
    ])
    let transport = HistoryWireTransport { call in
        if call.name == "TractandaAttachment/list" {
            return .object([.init("itemID", .string(original.itemID)), .init("revisionID", .string(original.revisionID)),
                .init("attachments", .array([badDescriptor]))])
        }
        return .object([.init("attachment", try .decode(JSON.encode(descriptor))), .init("offset", .string("0")),
            .init("nextOffset", .string("3")), .init("isComplete", .bool(true)), .init("data", .string("AQID"))])
    }
    let client = ItemClient(transport: transport)
    await #expect(throws: (any Error).self) { try await client.listAttachments(itemID: original.itemID) }
    await #expect(throws: (any Error).self) { try await client.attachmentContent(itemID: original.itemID, attachmentID: descriptor.attachmentID) }
}
