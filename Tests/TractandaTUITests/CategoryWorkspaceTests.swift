import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaTUI

final class CategoryWorkspaceTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trac-category-workspace-" + Identifier.make())
        let store: ItemStore
        let service: ItemService
        lazy var client = ItemClient(transport: { [unowned self] in
            service.handle($0, peerUID: store.ownerUID)
        })
        init() throws {
            store = try ItemStore(root: root.appendingPathComponent("store"))
            service = ItemService(store: store)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func category(_ name: String, parents: [Revision] = []) throws -> Revision {
            try client.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text(name),
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                        ]),
                        "categoryParents": .list(parents.map { .reference(ItemReference($0.itemID)) }),
                    ], operationID: Identifier.make())
            ).revision
        }
        func item(_ subject: String, categories: [Revision] = []) throws -> Revision {
            try client.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text(subject),
                        "categories": .list(categories.map { .reference(ItemReference($0.itemID)) }),
                    ],
                    operationID: Identifier.make())
            ).revision
        }
    }

    func testPreviewPageUsesNativePathAndNeverRetrievesMoreThanOnePage() throws {
        let fixture = try Fixture()
        let a = try fixture.category("A")
        let b = try fixture.category("B", parents: [a])
        for number in 0..<70 { _ = try fixture.item("item \(number)", categories: [a, b]) }
        _ = try fixture.item("excluded", categories: [a])
        let first = try CategoryPreviewPage.load(
            using: fixture.client, path: [a.itemID, b.itemID], position: 0,
            sort: [try ItemSort(property: "modifiedAt", isAscending: false)])
        // Categories remain ordinary items, so A/B and the category whose own rule matches are
        // present too.  The native path semantics—not a UI-side filter—decide the result.
        XCTAssertEqual(first.total, 73)
        XCTAssertEqual(first.rows.count, 64)
        let second = try CategoryPreviewPage.load(
            using: fixture.client, path: [a.itemID, b.itemID], position: 64,
            sort: [try ItemSort(property: "modifiedAt", isAscending: false)])
        XCTAssertEqual(second.rows.count, 9)
        XCTAssertTrue(second.rows.allSatisfy { $0.fields["subject"]?.string != "excluded" })
    }

    func testPreviewGenerationDropsLateRowsAndFailureClearsPreviousRows() throws {
        var state = CategoryPreviewState()
        let first = state.begin(path: [], position: 0)
        let second = state.begin(path: [], position: 0)
        let page = CategoryPreviewPage(rows: [], position: 0, total: 0, queryState: "state")
        state.accept(page, generation: first)
        XCTAssertEqual(state.status, .loading)
        state.fail(TractandaError("offline", "down"), generation: second)
        XCTAssertTrue(state.rows.isEmpty)
        guard case .failed = state.status else { return XCTFail("failure was not retained") }
    }

    func testVersionOnePreferencesMigrateWithoutChangingSharedData() throws {
        let data = Data(#"{"version":1,"pinnedViewIDs":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(ViewWorkspacePreferences.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertFalse(decoded.categoryConnectedTree)
        XCTAssertEqual(decoded.categoryRightMode, "items")
    }

    func testInlineInspectorUsesCategoryBuffersAndCancelsWithoutRevision() throws {
        let fixture = try Fixture()
        let category = try fixture.category("Alpha")
        let journal = RecoveryJournal(
            url: fixture.root.appendingPathComponent("pending.json"), socket: "/fixture")
        let app = try TerminalApplication(client: fixture.client, journal: journal, itemsOnly: true)
        app.handle(.function(9))
        app.handle(.paste("Alpha"))
        app.handle(.function(2))
        let editing = app.render(columns: 132, rows: 35)
        XCTAssertTrue(editing.contains { $0.text.contains("Edit item / Category") })
        XCTAssertTrue(editing.contains { $0.text.contains("Category rule") })
        XCTAssertTrue(editing.contains { $0.cursorColumn != nil })
        app.handle(.function(5))
        app.handle(.paste(" note"))
        app.handle(.function(9))
        XCTAssertEqual(try fixture.store.get(category.itemID), category)
    }
}
