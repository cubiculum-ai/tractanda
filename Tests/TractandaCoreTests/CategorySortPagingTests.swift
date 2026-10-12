import XCTest

@testable import TractandaCore

final class CategorySortPagingTests: XCTestCase {
    private func fixture(_ body: (ItemStore, Revision, Revision, Revision, Revision) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        func category(_ name: String, parents: [Revision] = [], order: Int64 = 0) throws -> Revision {
            try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text(name), "categoryOrder": .integer(order),
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
                        ]),
                        "categoryParents": .list(parents.map { .reference(ItemReference($0.itemID)) }),
                    ], operationID: Identifier.make())
            ).revision
        }
        let priority = try category("Priority")
        let high = try category("High", parents: [priority])
        let low = try category("Low", parents: [priority], order: 1)
        let excluded = try category("Excluded")
        try body(store, priority, high, low, excluded)
    }

    func testSmallWindowMatchesBulkOrderBeyondExactMatchCap() throws {
        try fixture { store, priority, high, low, excluded in
            var items: [Revision] = []
            for index in 0..<17 {
                let rank = index % 3 == 0 ? priority : index % 3 == 1 ? high : low
                items.append(
                    try store.commit(
                        CommitRequest(
                            classID: "Item",
                            changes: [
                                "subject": .text("Card \(index)"), "work": .boolean(true),
                                "value": index == 5
                                    ? .real(9_007_199_254_740_992) : .integer(Int64(index % 4)),
                                // Non-sort content must never consume retained window bytes.
                                "body": .text(String(repeating: "content", count: 500)),
                                "categoryOverrides": .object([
                                    rank.itemID: .text("include"),
                                    excluded.itemID: .text(index == 2 ? "include" : "exclude"),
                                ]),
                            ], operationID: Identifier.make())
                    ).revision)
            }
            for ascending in [true, false] {
                let sort = [
                    try ItemSort(categoryRootID: priority.itemID, isAscending: ascending),
                    try ItemSort(property: "value", isAscending: !ascending),
                ]
                let reference = try Categories.query(
                    store: store, expression: "work == true", excludedCategoryIDs: [excluded.itemID],
                    sort: sort
                ).map(\.itemID)
                store.exactQueryCandidateLimitForTesting = 3
                XCTAssertThrowsError(
                    try Categories.query(
                        store: store, expression: "work == true", excludedCategoryIDs: [excluded.itemID],
                        sort: sort))
                for position in [0, 4, 15, 20] {
                    let page = try Categories.page(
                        store: store, expression: "work == true", text: nil, categoryPath: [],
                        excludedCategoryIDs: [excluded.itemID], sort: sort, position: position, limit: 2,
                        at: Date(), timeZone: "UTC")
                    XCTAssertEqual(page.ids, Array(reference.dropFirst(position).prefix(2)))
                    XCTAssertEqual(page.total, reference.count)
                }
                let compactPage = try Categories.categorySortedPage(
                    store: store, expression: "work == true", text: nil, categoryPath: [],
                    excludedCategoryIDs: [excluded.itemID], sort: sort, position: 4, limit: 2,
                    at: Date(), timeZone: "UTC", maximumRetainedBytes: 2048)
                XCTAssertEqual(compactPage.ids, Array(reference.dropFirst(4).prefix(2)))
                store.exactQueryCandidateLimitForTesting = nil
            }
            let savedSort = [
                try ItemSort(categoryRootID: priority.itemID), try ItemSort(property: "subject"),
            ]
            let savedReference = try Categories.query(
                store: store, expression: "work == true",
                excludedCategoryIDs: [excluded.itemID], sort: savedSort
            ).map(\.itemID)
            let view = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "viewDefinition": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text("work == true"),
                            "excludedCategoryIDs": .list([.reference(ItemReference(excluded.itemID))]),
                            "sort": .list(savedSort.map(\.value)),
                        ])
                    ], operationID: Identifier.make())
            ).revision
            store.exactQueryCandidateLimitForTesting = 3
            let savedPage = try Categories.savedViewPage(
                store: store, id: view.itemID, sectionID: nil,
                position: 5, limit: 2, at: Date(), timeZone: "UTC")
            XCTAssertEqual(savedPage.total, savedReference.count)
            XCTAssertEqual(savedPage.ids, Array(savedReference.dropFirst(5).prefix(2)))

        }
    }

    func testCountOnlyByteBudgetOverflowAndZeroMatchCancellation() throws {
        try fixture { store, priority, high, _, excluded in
            for index in 0..<6 {
                _ = try store.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: [
                            "subject": .text("Card \(index)"), "work": .boolean(true),
                            "categoryOverrides": .object([high.itemID: .text("include")]),
                        ], operationID: Identifier.make()))
            }
            let sort = [try ItemSort(categoryRootID: priority.itemID)]
            func page(_ position: Int, _ limit: Int, _ budget: Int) throws -> ItemIndex.Page {
                try Categories.categorySortedPage(
                    store: store, expression: "work == true", text: nil, categoryPath: [],
                    excludedCategoryIDs: [], sort: sort, position: position, limit: limit, at: Date(),
                    timeZone: "UTC", maximumRetainedBytes: budget)
            }
            let count = try page(10, 0, 0)
            XCTAssertEqual(count.total, 6)
            XCTAssertTrue(count.ids.isEmpty)
            XCTAssertThrowsError(try page(0, 1, 1)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
            }
            XCTAssertThrowsError(try page(Int.max, 1, 1024)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
            }
            XCTAssertThrowsError(try page(-1, 1, 1024)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "invalidArguments")
            }
            XCTAssertThrowsError(
                try Categories.categorySortedPage(
                    store: store, expression: "work == true", text: nil, categoryPath: [],
                    excludedCategoryIDs: [], sort: [ItemSort(categoryRootID: Identifier.make())], position: 0,
                    limit: 0, at: Date(), timeZone: "UTC"))
            var checks = 0
            XCTAssertThrowsError(
                try Categories.categorySortedPage(
                    store: store, expression: nil, text: nil, categoryPath: [excluded.itemID],
                    excludedCategoryIDs: [], sort: sort, position: 0, limit: 1, at: Date(), timeZone: "UTC",
                    isCancelled: {
                        checks += 1
                        return checks > 2
                    })
            ) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertGreaterThan(checks, 2)
        }
    }
}
