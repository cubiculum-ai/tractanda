import Foundation
import TractandaClient
import XCTest

@testable import TractandaCore

private let historyAccount = "00112233-4455-6677-8899-aabbccddeeff"
private let historyLarge: Int64 = 9_007_199_254_740_993

private final class HistoryTranscript {
    var calls: [JMAPInvocation] = []
    let result: (JMAPInvocation) throws -> JMAPValue
    init(_ result: @escaping (JMAPInvocation) throws -> JMAPValue) { self.result = result }
    func send(_ bytes: Data) throws -> Data {
        let call = try JMAPRequest.decode(bytes).methodCalls[0]
        calls.append(call)
        let payload: JMAPValue
        if call.name == TractandaJMAP.discoveryMethod {
            payload = .object([
                .init("profile", .string("tractanda.local-session.v1")), .init("username", .string("owner")),
                .init("state", .string("metadata")),
                .init("capabilities", .object([.init(JMAPKernel.core, .object([])), .init(TractandaJMAP.capability, .object([]))])),
                .init("accounts", .object([.init(historyAccount, .object([
                    .init("name", .string("Fixture")), .init("isPersonal", .bool(false)), .init("isReadOnly", .bool(false)),
                    .init("accountCapabilities", .object([.init(TractandaJMAP.capability, .object([]))])),
                ]))])),
                .init("primaryAccounts", .object([.init(TractandaJMAP.capability, .string(historyAccount))])),
            ])
        } else { payload = try result(call) }
        return try JMAPValue.object([
            .init("sessionState", .string("metadata")),
            .init("methodResponses", .array([JMAPInvocation(name: call.name, arguments: payload, callID: call.callID).value])),
        ]).encoded()
    }
}

final class NativeHistoryClientTests: XCTestCase {
    private func revision(itemID: String = Identifier.make()) throws -> Revision {
        let descriptor = try attachment(historyLarge)
        return try Revision(fields: [
            "itemID": .text(itemID), "revisionID": .text(Identifier.make()), "classID": .text("SourceDoc"),
            "actor": .text("user:fixture"), "operationID": .text("history-fixture"), "requestIdentity": .text("history-fixture"),
            "schemaVersion": .integer(1), "createdAt": .date("2026-10-26T00:00:00Z"), "modifiedAt": .date("2026-10-26T00:00:00Z"),
            "attachments": .list([descriptor.itemValue]),
            "sourceDocument": .object(["byteCount": .integer(.max), "parts": .list([
                .object(["offset": .integer(historyLarge), "minimum": .integer(.min), "literal": .text(String(historyLarge))]),
            ])]),
        ])
    }
    private func attachment(_ count: Int64) throws -> AttachmentDescriptor {
        try .init(attachmentID: "11111111-1111-1111-8111-111111111111", filename: "fixture.bin",
            mediaType: "application/octet-stream", byteCount: count, sha256: String(repeating: "a", count: 64))
    }
    private func history(_ records: [JMAPRevisionRecord], total: Int, dispositions: [String: HistoricalDisposition] = [:]) throws -> JMAPValue {
        .object([
            .init("accountId", .string(historyAccount)), .init("state", .string("items")),
            .init("list", .array(try records.map { try .decode(JSON.encode($0)) })),
            .init("total", .number(try JMAPNumber(String(total)))),
            .init("historicalDispositions", try .decode(JSON.encode(dispositions))),
        ])
    }

    func testTypedHistoryConvertsNestedAttachmentAndSourceDocumentInt64WhileRawCallStaysWire() throws {
        let original = try revision(), wire = try history([JMAPRevisionRecord(original)], total: 4,
            dispositions: [original.revisionID: .demoted])
        let transcript = HistoryTranscript { _ in wire }
        let client = TractandaCore.ItemClient(transport: transcript.send)
        let raw = try client.call("TractandaItem/history", arguments: ["itemID": original.itemID])
        let fields = try XCTUnwrap(JMAPValue.decode(raw)["list"]?.elements?.first?["fields"])
        XCTAssertEqual(fields["attachments"]?["value"]?.elements?.first?["value"]?["byteCount"]?["value"]?.text, String(historyLarge))
        XCTAssertThrowsError(try JSON.decode(ItemHistoryResult.self, raw))
        let page = try client.history(itemID: original.itemID, position: 3, limit: 1)
        XCTAssertEqual(page.list, [original]); XCTAssertEqual(page.total, 4)
        XCTAssertEqual(page.historicalDispositions, [original.revisionID: .demoted])
        XCTAssertEqual(try JSON.encode(page.list[0]), try JSON.encode(original))
        XCTAssertEqual(try AttachmentDescriptor.descriptors(in: page.list[0].fields)[0].byteCount, historyLarge)
        XCTAssertEqual(transcript.calls.last?.arguments["position"], .number(try JMAPNumber("3")))
        XCTAssertEqual(transcript.calls.last?.arguments["limit"], .number(try JMAPNumber("1")))
    }

    func testTypedHistoryRejectsInvalidArgumentsPagesForeignIdentitiesAndPartialRecords() throws {
        let original = try revision(), foreign = try revision()
        let record = try JMAPRevisionRecord(original)
        let malformed = [
            try history([record], total: 0), try history([record, record], total: 2),
            try history([JMAPRevisionRecord(foreign)], total: 1),
            try history([record], total: 1, dispositions: [Identifier.make(): .demoted]),
            try history([JMAPRevisionRecord(original, properties: ["id"])], total: 1),
            try history([], total: -1),
        ]
        for wire in malformed {
            let transcript = HistoryTranscript { _ in wire }
            XCTAssertThrowsError(try TractandaCore.ItemClient(transport: transcript.send).history(itemID: original.itemID))
        }
        let transcript = HistoryTranscript { _ in try self.history([], total: 0) }
        let client = TractandaCore.ItemClient(transport: transcript.send)
        for (position, limit) in [(-1, 1), (0, 0), (0, 257)] {
            XCTAssertThrowsError(try client.history(itemID: original.itemID, position: position, limit: limit))
        }
        XCTAssertThrowsError(try client.history(itemID: "invalid"))
        XCTAssertTrue(transcript.calls.isEmpty)
    }

    func testAttachmentListAndContentRetainExactNumericInt64WithoutTaggedValueConversion() throws {
        let item = Identifier.make(), revision = Identifier.make()
        for count in [historyLarge, Int64.max] {
            let descriptor = try attachment(count)
            let listed = AttachmentListResult(itemID: item, revisionID: revision, attachments: [descriptor])
            let content = AttachmentContentResult(attachment: descriptor, offset: count - 3, nextOffset: count,
                isComplete: true, data: Data([1, 2, 3]))
            let transcript = HistoryTranscript { call in
                try .decode(JSON.encode(call.name == "TractandaAttachment/list" ? EncodableList(listed) : EncodableList(content)))
            }
            let client = TractandaCore.ItemClient(transport: transcript.send)
            XCTAssertEqual(try client.listAttachments(itemID: item).attachments[0].byteCount, count)
            let result = try client.attachmentContent(itemID: item, attachmentID: descriptor.attachmentID, offset: count - 3)
            XCTAssertEqual(result.attachment.byteCount, count); XCTAssertEqual(result.offset, count - 3)
            XCTAssertEqual(result.nextOffset, count); XCTAssertEqual(result.data, Data([1, 2, 3]))
            XCTAssertEqual(transcript.calls.last?.arguments["offset"], .number(try JMAPNumber(String(count - 3))))
        }
    }

    func testHistoryTaggedIntegerAndDirectAttachmentScalarMismatchesFailClosed() throws {
        let original = try revision(), descriptor = try attachment(historyLarge)
        for taggedValue in ["42", #""01""#, #""9223372036854775808""#] {
            let originalRecord = try JMAPValue.decode(JSON.encode(JMAPRevisionRecord(original)))
            let bad = JMAPMember("bad", .object([.init("type", .string("integer")),
                .init("value", try .decode(Data(taggedValue.utf8)))]))
            let brokenRecord = JMAPValue.object(originalRecord.members!.map { member in
                member.name == "fields" ? .init("fields", .object(member.value.members! + [bad])) : member
            })
            let wire = JMAPValue.object([.init("accountId", .string(historyAccount)), .init("state", .string("items")),
                .init("total", .number(try JMAPNumber("1"))), .init("list", .array([brokenRecord]))])
            let transcript = HistoryTranscript { _ in wire }
            XCTAssertThrowsError(try TractandaCore.ItemClient(transport: transcript.send).history(itemID: original.itemID))
        }
        let invalidDescriptor = JMAPValue.object([
            .init("attachmentID", .string(descriptor.attachmentID)), .init("filename", .string(descriptor.filename)),
            .init("mediaType", .string(descriptor.mediaType)), .init("sha256", .string(descriptor.sha256)),
            .init("byteCount", .string(String(historyLarge))),
        ])
        let transcript = HistoryTranscript { call in
            if call.name == "TractandaAttachment/list" {
                return .object([.init("itemID", .string(original.itemID)), .init("revisionID", .string(original.revisionID)),
                    .init("attachments", .array([invalidDescriptor]))])
            }
            return .object([.init("attachment", try .decode(JSON.encode(descriptor))), .init("offset", .string("0")),
                .init("nextOffset", .string("3")), .init("isComplete", .bool(true)), .init("data", .string("AQID"))])
        }
        let client = TractandaCore.ItemClient(transport: transcript.send)
        XCTAssertThrowsError(try client.listAttachments(itemID: original.itemID))
        XCTAssertThrowsError(try client.attachmentContent(itemID: original.itemID, attachmentID: descriptor.attachmentID))
    }
}

/// Test-only erasure preserves the actual direct result schema; it performs no JSON rewriting.
private struct EncodableList: Encodable {
    let encodeValue: (any Encoder) throws -> Void
    init(_ value: some Encodable) { encodeValue = value.encode }
    func encode(to encoder: any Encoder) throws { try encodeValue(encoder) }
}
