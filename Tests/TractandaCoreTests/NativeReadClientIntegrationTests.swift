import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class NativeReadClientIntegrationTests: XCTestCase {
    func testFacadeReadModifyLostReceiptRetryPreservesInt64CanonicalIntentAndHistory() throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-read-client-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let original = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: [
                    "subject": .text("before"), "min": .integer(Int64.min), "max": .integer(Int64.max),
                    "literal./~key": .object(["nested": .list([.integer(Int64.min), .integer(Int64.max)])]),
                ], operationID: "fixture-create")
        ).revision
        let originalBytes = try JSON.encode(original)
        let service = ItemService(store: store)
        var dropReceipt = true
        var commits: [Data] = []
        let client = ItemClient(transport: { request in
            let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
            let call = (envelope["methodCalls"] as! [[Any]])[0]
            let method = call[0] as! String
            if method == "TractandaItem/commit" { commits.append(request) }
            let response = service.handle(request, peerUID: tractanda_uid())
            if method == "TractandaItem/commit", dropReceipt {
                dropReceipt = false
                throw TractandaError("connectionClosed", "Fixture loses the committed receipt.")
            }
            return response
        })
        let loaded = try client.revision(for: original.itemID)
        XCTAssertEqual(loaded, original)
        let request = CommitRequest(
            action: .revise, itemID: loaded.itemID, expectedRevisionID: loaded.revisionID,
            changes: [
                "subject": .text("after"), "min": loaded.fields["min"]!, "max": loaded.fields["max"]!,
                "literal./~key": loaded.fields["literal./~key"]!,
            ], operationID: "same-wire-intent")
        XCTAssertThrowsError(try client.commit(request)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "connectionClosed")
        }
        let receipt = try client.commit(request)
        XCTAssertTrue(receipt.wasReplayed)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0], commits[1])
        let sent = try JSONSerialization.jsonObject(with: commits[0]) as! [String: Any]
        let fields = ((sent["methodCalls"] as! [[Any]])[0][1] as! [String: Any])["changes"] as! [String: Any]
        XCTAssertEqual((fields["min"] as! [String: Any])["value"] as? String, String(Int64.min))
        XCTAssertEqual((fields["max"] as! [String: Any])["value"] as? String, String(Int64.max))
        let saved = try client.revision(itemID: receipt.itemID, revisionID: receipt.revisionID)
        XCTAssertEqual(saved.fields["min"], .integer(Int64.min))
        XCTAssertEqual(saved.fields["max"], .integer(Int64.max))
        XCTAssertEqual(saved.fields["literal./~key"], original.fields["literal./~key"])
        XCTAssertEqual(
            saved.fields["requestIdentity"]?.string, try JSON.encode(request).base64EncodedString())
        XCTAssertEqual(
            try JSON.encode(client.revision(itemID: original.itemID, revisionID: original.revisionID)),
            originalBytes)
        let canonical = try JSONSerialization.jsonObject(with: JSON.encode(saved)) as! [String: Any]
        let canonicalFields = canonical["fields"] as! [String: Any]
        let minimum = (canonicalFields["min"] as! [String: Any])["value"]
        let maximum = (canonicalFields["max"] as! [String: Any])["value"]
        XCTAssertEqual((minimum as? NSNumber)?.stringValue, String(Int64.min))
        XCTAssertEqual((maximum as? NSNumber)?.stringValue, String(Int64.max))
        XCTAssertFalse(minimum is String)
        XCTAssertFalse(maximum is String)
    }
}
