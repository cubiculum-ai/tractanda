import Foundation
import XCTest

@testable import TractandaCore

final class CategoryExclusionTests: XCTestCase {
    func testCategoryAndViewExclusionsUseMembershipAndRejectDependencyCycles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        func create(_ fields: [String: ItemValue]) throws -> Revision {
            try store.commit(
                CommitRequest(classID: "Item", changes: fields, operationID: Identifier.make())
            ).revision
        }
        func selection(_ expression: String, excluding: [Revision] = []) -> ItemValue {
            .object([
                "language": .text(SpotlightQuery.profile), "expression": .text(expression),
                "excludedCategoryIDs": .list(excluding.map { .reference(ItemReference($0.itemID)) }),
            ])
        }
        let complete = try create(["subject": .text("Completed"), "selection": selection("itemID == \"\"")])
        let open = try create([
            "subject": .text("Open work"), "selection": selection("work == true", excluding: [complete]),
        ])
        let available = try create(["subject": .text("Available"), "work": .boolean(true)])
        let completed = try create([
            "subject": .text("Finished"), "work": .boolean(true),
            "categoryOverrides": .object([complete.itemID: .text("include")]),
        ])
        XCTAssertEqual(
            try Categories.query(store: store, categoryPath: [open.itemID]).map(\.itemID), [available.itemID])
        XCTAssertEqual(
            try Categories.query(
                store: store, expression: "work == true", excludedCategoryIDs: [complete.itemID]
            ).map(\.itemID), [available.itemID])
        let view = try create([
            "viewDefinition": .object([
                "language": .text(SpotlightQuery.profile), "expression": .text("work == true"),
                "excludedCategoryIDs": .list([.reference(ItemReference(complete.itemID))]),
            ])
        ])
        XCTAssertEqual(
            try Categories.savedView(store: store, id: view.itemID).map(\.itemID), [available.itemID])
        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: completed.itemID, expectedRevisionID: completed.revisionID,
                changes: [
                    "categoryOverrides": .object([
                        complete.itemID: .text("include"), open.itemID: .text("include"),
                    ])
                ], operationID: Identifier.make()))
        XCTAssertEqual(
            Set(try Categories.query(store: store, categoryPath: [open.itemID]).map(\.itemID)),
            [available.itemID, completed.itemID])
        XCTAssertEqual(
            try Categories.savedView(store: store, id: view.itemID).map(\.itemID), [available.itemID])
        XCTAssertThrowsError(
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: complete.itemID, expectedRevisionID: complete.revisionID,
                    changes: ["selection": selection("work == true", excluding: [open])],
                    operationID: Identifier.make()))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "categoryCycle")
        }
        try store.rebuildIndex()
        XCTAssertEqual(
            try Categories.savedView(store: store, id: view.itemID).map(\.itemID), [available.itemID])
    }

    func testOldNativeCapabilityCannotSubmitWritesAfterTheDevelopmentCutover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let service = ItemService(store: store)
        let request: [String: Any] = [
            "using": ["https://tractanda.ai/ns/local-prototype"],
            "methodCalls": [
                [
                    "TractandaItem/commit",
                    [
                        "action": "create", "classID": "Item",
                        "changes": ["subject": ["type": "text", "value": "Stale client"]],
                        "operationID": "stale-client",
                    ], "test",
                ]
            ],
        ]
        let response = service.handle(
            try JSONSerialization.data(withJSONObject: request), peerUID: store.ownerUID)
        let result = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        XCTAssertEqual(result["code"] as? String, "unsupportedCapability")
        XCTAssertTrue(try store.candidates().isEmpty)
    }
}
