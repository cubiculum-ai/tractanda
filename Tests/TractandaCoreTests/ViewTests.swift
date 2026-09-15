import XCTest

@testable import TractandaCore

final class ViewTests: XCTestCase {
    private func create(_ store: ItemStore, _ fields: [String: ItemValue]) throws -> Revision {
        try store.commit(CommitRequest(classID: "NoteItem", changes: fields, operationID: Identifier.make()))
            .revision
    }

    func testDefaultOrderUsesModificationInstantsAndStableIdentityTies() throws {
        func item(_ suffix: String, modified: String, created: String) throws -> Revision {
            let fields: [String: ItemValue] = [
                "itemID": .text("00000000-0000-4000-8000-00000000000" + suffix),
                "revisionID": .text(Identifier.make()), "classID": .text("NoteItem"),
                "actor": .text("test"), "operationID": .text("test"), "requestIdentity": .text("test"),
                "schemaVersion": .integer(1), "createdAt": .date(created), "modifiedAt": .date(modified),
            ]
            return try Revision(fields: fields)
        }
        let old = try item("1", modified: "2026-09-10T07:00:00Z", created: "2026-09-10T07:00:00Z")
        let edited = try item("2", modified: "2026-09-10T10:00:00+02:00", created: "2020-01-01T00:00:00Z")
        let tied = try item("3", modified: "2026-09-10T08:00:00Z", created: "2026-09-10T08:00:00Z")
        let unordered = [tied, old, edited]
        XCTAssertEqual(
            try ItemSort.ordered(unordered, by: []).map(\.itemID), [edited, tied, old].map(\.itemID))
        XCTAssertEqual(
            try ItemSort.ordered(unordered, by: [ItemSort(property: "itemID")]).map(\.itemID),
            [old, edited, tied].map(\.itemID))
    }

    func testDefaultNativeOrderAppliesBeforePagingSearchAndSavedViews() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        var items: [Revision] = []
        for index in 0..<70 {
            items.append(
                try create(
                    store,
                    [
                        "subject": .text("Row \(index)"), "rank": .integer(Int64(index)),
                        "sortFixture": .text("yes"), "body": .text("chronological marker"),
                    ]))
        }
        let category = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("sortFixture == \"yes\""),
                ])
            ])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(category.itemID))]), "sort": .list([]),
                ])
            ])
        let rankView = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("sortFixture == \"yes\""),
                    "sort": .list([try ItemSort(property: "rank").value]),
                ])
            ])
        // The timestamp codec has millisecond precision; ensure the subsequent edit is later.
        Thread.sleep(forTimeInterval: 0.002)
        items[0] = try store.commit(
            CommitRequest(
                action: .revise, itemID: items[0].itemID, expectedRevisionID: items[0].revisionID,
                changes: ["subject": .text("Older item edited now")], operationID: Identifier.make())
        ).revision
        let dated = try items.map { item -> (item: Revision, date: Date) in
            guard case .date(let timestamp) = item.fields["modifiedAt"] else {
                throw TractandaError("test", "Missing modification timestamp")
            }
            return (item, try XCTUnwrap(Timestamp.parse(timestamp)))
        }
        let expected = dated.sorted {
            $0.date == $1.date ? $0.item.itemID < $1.item.itemID : $0.date > $1.date
        }.map { $0.item.itemID }
        XCTAssertEqual(expected.first, items[0].itemID)
        struct Page: Decodable {
            let ids: [String]
            let total: Int
        }
        func query(_ arguments: [String: Any]) throws -> Page {
            try JSON.decode(Page.self, client.call("TractandaItem/query", arguments: arguments))
        }
        let base: [String: Any] = ["expression": "sortFixture == \"yes\"", "limit": 64]
        XCTAssertEqual(try query(base).ids, Array(expected.prefix(64)))
        XCTAssertEqual(
            try query(base.merging(["position": 64]) { _, new in new }).ids, Array(expected.suffix(6)))
        XCTAssertEqual(
            try query(["categoryPath": [category.itemID], "sort": [], "limit": 64]).ids,
            Array(expected.prefix(64)))
        XCTAssertEqual(
            try query(["text": "chronological marker", "limit": 64]).ids, Array(expected.prefix(64)))
        XCTAssertEqual(try query(["viewID": view.itemID, "limit": 64]).ids, Array(expected.prefix(64)))
        XCTAssertEqual(
            try query(["viewID": rankView.itemID, "limit": 64]).ids, Array(items.prefix(64).map(\.itemID)))
        let before = try store.get(items[0].itemID)
        try store.rebuildIndex()
        XCTAssertEqual(
            try query(["viewID": view.itemID, "position": 64, "limit": 64]).ids, Array(expected.suffix(6)))
        XCTAssertEqual(try store.get(items[0].itemID), before)
    }

    func testNativeSortPrecedesPaginationAndSurvivesRebuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        var items: [Revision] = []
        for index in (0..<70).reversed() {
            items.append(try create(store, ["subject": .text("Row"), "rank": .integer(Int64(index))]))
        }
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("rank == *"),
                    "sort": .list([try ItemSort(property: "rank").value]),
                ])
            ])
        struct Page: Decodable {
            let ids: [String]
            let total: Int
        }
        func query(_ position: Int) throws -> Page {
            try JSON.decode(
                Page.self,
                client.call(
                    "TractandaItem/query",
                    arguments: [
                        "viewID": view.itemID, "position": position, "limit": 64,
                    ]))
        }
        let ascending = items.reversed().map(\.itemID)
        XCTAssertEqual(try query(0).ids, Array(ascending.prefix(64)))
        XCTAssertEqual(try query(64).ids, Array(ascending.suffix(6)))
        XCTAssertEqual(try query(64).total, 70)
        let descending = try JSON.decode(
            Page.self,
            client.call(
                "TractandaItem/query",
                arguments: [
                    "expression": "rank == *", "sort": [["property": "rank", "isAscending": false]],
                    "limit": 3,
                ]))
        XCTAssertEqual(descending.ids, items.prefix(3).map(\.itemID))
        try store.rebuildIndex()
        XCTAssertEqual(try query(64).ids, Array(ascending.suffix(6)))
        for arguments: [String: Any] in [
            ["sort": [["property": "rank", "isAscending": "no"]]],
            ["sort": [["property": ""]]], ["sort": [["property": "rank"], ["property": "rank"]]],
            ["sort": NSNull()], ["viewID": view.itemID, "sort": []], ["sectionID": view.itemID],
        ] {
            XCTAssertThrowsError(try client.call("TractandaItem/query", arguments: arguments))
        }
    }

    func testTypedOrderingIsExactStableAndDoesNotFollowReferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let integer = try create(store, ["value": .integer(9_007_199_254_740_993)])
        let real = try create(store, ["value": .real(9_007_199_254_740_992)])
        let negative = try create(store, ["value": .integer(-9_223_372_036_854_775_808)])
        let dateA = try create(store, ["value": .date("2026-09-08T11:00:00+02:00")])
        let dateB = try create(store, ["value": .date("2026-09-08T10:00:00Z")])
        let text = try create(store, ["value": .text("value")])
        let flag = try create(store, ["value": .boolean(false)])
        let absent = try create(store, [:])
        let compound = try create(store, ["value": .reference(ItemReference(integer.itemID))])
        let all = [integer, dateB, absent, flag, real, negative, compound, text, dateA]
        let missing = [absent, compound].sorted { $0.itemID < $1.itemID }
        let expected = [negative, real, integer, dateA, dateB, text, flag]
        XCTAssertEqual(
            try ItemSort.ordered(all, by: [ItemSort(property: "value")]).map(\.itemID),
            (expected + missing).map(\.itemID))
        XCTAssertEqual(
            try ItemSort.ordered(all, by: [ItemSort(property: "value", isAscending: false)]).map(\.itemID),
            (expected.reversed() + missing).map(\.itemID))
        XCTAssertEqual(
            try ItemSort.ordered(all, by: [ItemSort(property: "value.secret")]).map(\.itemID),
            all.map(\.itemID).sorted())
        let maximum = try create(store, ["value": .integer(Int64.max)])
        let larger = try create(store, ["value": .real(9_223_372_036_854_775_808)])
        XCTAssertEqual(
            try ItemSort.ordered([larger, maximum], by: [ItemSort(property: "value")]).first?.itemID,
            maximum.itemID)
        let first = try create(store, ["subject": .text("Alpha"), "rank": .integer(1)])
        let second = try create(store, ["subject": .text("Beta"), "rank": .integer(1)])
        XCTAssertEqual(
            try ItemSort.ordered(
                [second, first],
                by: [
                    ItemSort(property: "rank"), ItemSort(property: "kMDItemTitle"),
                ]
            ).map(\.itemID), [first.itemID, second.itemID])
    }

    func testSavedSectionsIntersectFiltersAndHonorManualDecisions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let category = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("subject == \"match\""),
                ])
            ])
        let included = try create(
            store,
            [
                "subject": .text("exception"), "body": .text("chess"),
                "deadline": .date("2026-09-08T10:00:00Z"),
                "categoryOverrides": .object([category.itemID: .text("include")]),
            ])
        _ = try create(
            store,
            [
                "subject": .text("match"), "body": .text("chess"),
                "deadline": .date("2026-09-08T10:00:00Z"),
                "categoryOverrides": .object([category.itemID: .text("exclude")]),
            ])
        _ = try create(
            store,
            [
                "subject": .text("match"), "body": .text("football"),
                "deadline": .date("2026-09-08T10:00:00Z"),
            ])
        var definition: [String: ItemValue] = [
            "language": .text(SpotlightQuery.profile), "text": .text("chess"),
            "expression": .text("deadline >= $time.iso(\"2026-09-08T00:00:00Z\")"),
            "presentation": .object([
                "profile": .text(ViewPresentation.profile),
                "sections": .list([.reference(ItemReference(category.itemID))]),
            ]),
        ]
        let view = try create(store, ["viewDefinition": .object(definition)])
        XCTAssertEqual(
            try Categories.savedView(store: store, id: view.itemID, sectionID: category.itemID).map(\.itemID),
            [included.itemID])
        XCTAssertEqual(
            try Categories.savedView(store: store, id: view.itemID).count, 2,
            "Presentation sections must not narrow a plain view query used by another client.")
        XCTAssertThrowsError(
            try Categories.savedView(store: store, id: view.itemID, sectionID: Identifier.make()))
        definition["presentation"] = .object([
            "profile": .text(ViewPresentation.profile),
            "collapsedSections": .list([.reference(ItemReference(category.itemID))]),
        ])
        XCTAssertThrowsError(try SavedViewDefinition(.object(definition)))
        definition["presentation"] = .object([
            "profile": .text(ViewPresentation.profile), "columns": .list([]),
        ])
        XCTAssertThrowsError(try SavedViewDefinition(.object(definition)))
    }
}
