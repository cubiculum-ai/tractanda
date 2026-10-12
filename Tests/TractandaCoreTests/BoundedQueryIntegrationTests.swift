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

    func testCategorySortedBoardCapsMatchesAfterExactSelection() throws {
        // Tiny fixture: 20 small records, comfortably below 64 KiB of canonical data.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-bounded-sorted-board-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        func create(_ fields: [String: ItemValue]) throws -> Revision {
            try store.commit(
                CommitRequest(classID: "Item", changes: fields, operationID: Identifier.make())
            ).revision
        }
        func category(_ name: String, parents: [Revision] = [], order: Int64 = 0) throws -> Revision {
            try create([
                "subject": .text(name), "categoryOrder": .integer(order),
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
                ]),
                "categoryParents": .list(parents.map { .reference(ItemReference($0.itemID)) }),
            ])
        }
        let projects = try category("Projects")
        let alpha = try category("Alpha", parents: [projects])
        let beta = try category("Beta", parents: [projects])
        let status = try category("Status")
        let ready = try category("Ready", parents: [status])
        let priority = try category("Priority")
        let high = try category("High", parents: [priority])
        let low = try category("Low", parents: [priority], order: 1)
        func card(_ name: String, rank: Revision) throws -> Revision {
            try create([
                "subject": .text(name),
                "categoryOverrides": .object([
                    alpha.itemID: .text("include"), beta.itemID: .text("include"),
                    ready.itemID: .text("include"), rank.itemID: .text("include"),
                ]),
            ])
        }
        let lowCard = try card("Low", rank: low)
        let highFirst = try card("High first", rank: high)
        let highLatest = try card("High latest", rank: high)
        for index in 0..<8 { _ = try create(["subject": .text("Unrelated \(index)")]) }
        store.exactQueryCandidateLimitForTesting = 3
        let sort = [
            try ItemSort(categoryRootID: priority.itemID),
            try ItemSort(property: "modifiedAt", isAscending: false),
        ]
        let expected = [highLatest, highFirst, lowCard].map(\.itemID)
        for selected in [alpha, beta, projects] {
            let page = try Categories.page(
                store: store, expression: nil, text: nil,
                categoryPath: [selected.itemID, status.itemID], excludedCategoryIDs: [],
                sort: sort, position: 1, limit: 2, at: Date(), timeZone: "UTC")
            XCTAssertEqual(page.total, 3)
            XCTAssertEqual(page.ids, Array(expected.dropFirst()))
            XCTAssertGreaterThan(store.lastIndexCandidateCountForTesting, 3)
        }
        _ = try card("Fourth actual match", rank: low)
        XCTAssertThrowsError(
            try Categories.query(
                store: store, categoryPath: [alpha.itemID, status.itemID], sort: sort)
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
        let largerPage = try Categories.page(
            store: store, expression: nil, text: nil,
            categoryPath: [alpha.itemID, status.itemID], excludedCategoryIDs: [],
            sort: sort, position: 3, limit: 2, at: Date(), timeZone: "UTC")
        XCTAssertEqual(largerPage.total, 4)
        XCTAssertEqual(largerPage.ids.count, 1)
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
