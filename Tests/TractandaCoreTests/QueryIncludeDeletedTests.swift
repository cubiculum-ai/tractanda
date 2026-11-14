import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class QueryIncludeDeletedTests: XCTestCase {
    func testCurrentHeadsAndExplicitOption() throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.parent().appendingPathComponent(
            "query-deleted-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let service = ItemService(store: store)
        let item = try store.commit(
            .init(classID: "Item", changes: ["subject": .text("recoverable")], operationID: Identifier.make())
        ).revision
        let deleted = try store.commit(
            .init(
                action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                changes: ["isDeleted": .boolean(true)], operationID: Identifier.make())
        ).revision
        func query(_ filter: [String: Any]) throws -> (String, [String: Any]) {
            let request = try nativeFixtureRequest(
                method: "TractandaItem/query",
                arguments: ["filter": filter, "limit": 1, "calculateTotal": true],
                accountID: store.nativeProtocolSessionBasis.identity)
            let result = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: service.handle(request, peerUID: tractanda_uid())) as? [String: Any])
            let response = try XCTUnwrap((result["methodResponses"] as? [[Any]])?.first)
            return (try XCTUnwrap(response[0] as? String), try XCTUnwrap(response[1] as? [String: Any]))
        }
        let expression = "subject == 'recoverable'"
        let ordinary = try query(["expression": expression])
        XCTAssertEqual(ordinary.1["ids"] as? [String], [])
        let all = try query(["expression": expression, "includeDeleted": true])
        XCTAssertEqual(all.1["ids"] as? [String], [item.itemID])
        XCTAssertNotEqual(all.1["queryState"] as? String, ordinary.1["queryState"] as? String)
        XCTAssertTrue(all.1["nextCursor"] is NSNull)
        XCTAssertEqual(try store.get(item.itemID).revisionID, deleted.revisionID)
        XCTAssertEqual(try query(["expression": "isDeleted == true"]).1["ids"] as? [String], [])
        XCTAssertEqual(try query(["includeDeleted": true, "text": "recoverable"]).0, "error")
        XCTAssertEqual(try query(["includeDeleted": true, "categoryPath": []]).0, "error")
        XCTAssertEqual(try query(["includeDeleted": 1]).0, "error")
        _ = try store.commit(
            .init(
                action: .revise, itemID: item.itemID, expectedRevisionID: deleted.revisionID,
                changes: ["isDeleted": .boolean(false)], operationID: Identifier.make()))
        XCTAssertEqual(try query(["expression": expression]).1["ids"] as? [String], [item.itemID])
    }
}
