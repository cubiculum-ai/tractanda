import XCTest

@testable import TractandaCore

final class BoundedQueryIntegrationTests: XCTestCase {
    func testExactFallbackFailsClosedWhenCandidateBudgetIsExceeded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-bounded-query-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        _ = try DemoFixture.seed(store)
        store.exactQueryCandidateLimitForTesting = 2

        XCTAssertThrowsError(try store.candidates()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertThrowsError(try Categories.query(store: store)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
    }

    func testOrderedCategoryPageStreamsPastExactFallbackCandidateCap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-bounded-category-page-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let category = try store.commit(
            CommitRequest(
                classID: "CategoryItem",
                changes: [
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile),
                        "expression": .text("classID == \"Thing\""),
                    ])
                ], operationID: Identifier.make())
        ).revision
        var items: [Revision] = []
        for index in 0..<9 {
            items.append(
                try store.commit(
                    CommitRequest(
                        classID: "Thing", changes: ["subject": .text("item \(index)")],
                        operationID: Identifier.make())
                ).revision)
        }
        store.exactQueryCandidateLimitForTesting = 2
        let expected = try ItemSort.ordered(items, by: []).map(\.itemID)

        let page = try Categories.page(
            store: store, expression: nil, text: nil, categoryPath: [category.itemID],
            excludedCategoryIDs: [], sort: [], position: 7, limit: 2, at: Date(), timeZone: "UTC")
        XCTAssertEqual(page.ids, Array(expected.dropFirst(7)))
        XCTAssertEqual(page.total, 9)
        let empty = try Categories.page(
            store: store, expression: nil, text: nil, categoryPath: [category.itemID],
            excludedCategoryIDs: [], sort: [], position: 9, limit: 2, at: Date(), timeZone: "UTC")
        XCTAssertTrue(empty.ids.isEmpty)
        XCTAssertEqual(empty.total, 9)
    }

    func testDefaultOrderResidualPageStreamsPastExactFallbackCandidateCap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-bounded-residual-page-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        var matches: [Revision] = []
        for index in 0..<9 {
            matches.append(
                try store.commit(
                    CommitRequest(
                        classID: "Item", changes: ["subject": .text("item \(index)")],
                        operationID: Identifier.make())
                ).revision)
        }
        _ = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("other")],
                operationID: Identifier.make()))
        store.exactQueryCandidateLimitForTesting = 2
        let expected = try ItemSort.ordered(matches, by: []).map(\.itemID)

        let page = try Categories.page(
            store: store, expression: "subject == \"item*\"", text: nil, categoryPath: [],
            excludedCategoryIDs: [], sort: [], position: 7, limit: 2, at: Date(), timeZone: "UTC")
        XCTAssertEqual(page.ids, Array(expected.dropFirst(7)))
        XCTAssertEqual(page.total, 9)
        let empty = try Categories.page(
            store: store, expression: "subject == \"item*\"", text: nil, categoryPath: [],
            excludedCategoryIDs: [], sort: [], position: 9, limit: 2, at: Date(), timeZone: "UTC")
        XCTAssertTrue(empty.ids.isEmpty)
        XCTAssertEqual(empty.total, 9)
    }
}
