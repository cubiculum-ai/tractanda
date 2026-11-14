import XCTest

@testable import TractandaCore

final class AgentMemoryPresetTests: XCTestCase {
    private func fixture(_ body: (ItemStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        try body(ItemStore(root: root))
    }

    private func revise(
        _ store: ItemStore, _ item: Revision, _ changes: [String: ItemValue], unset: [String] = []
    ) throws -> Revision {
        try store.commit(
            CommitRequest(
                action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                changes: changes, unset: unset, operationID: Identifier.make())
        ).revision
    }

    private func template() throws -> CategoryTemplate {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try JSON.decode(
            CategoryTemplate.self,
            Data(contentsOf: root.appendingPathComponent("templates/starter-categories.json")))
    }

    func testKnowledgeViewsAndTimeBoundaries() throws {
        try fixture { store in
            let ids = try template().install(in: store, timeZone: "UTC", actorUID: store.ownerUID)
            let note = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text("Decision"),
                        "categoryOverrides": .object([ids["what.knowledge.decisions"]!: .text("include")]),
                    ], operationID: Identifier.make())
            ).revision
            for key in ["view.knowledge", "view.knowledge.decisions"] {
                XCTAssertTrue(
                    try Categories.savedView(store: store, id: ids[key]!).contains {
                        $0.itemID == note.itemID
                    })
            }
            XCTAssertFalse(
                try Categories.savedView(store: store, id: ids["view.knowledge.questions"]!).contains {
                    $0.itemID == note.itemID
                })
            let changed = try Categories.savedView(store: store, id: ids["view.changed-today"]!)
            XCTAssertTrue(changed.contains { $0.itemID == ids["what.knowledge"]! })
            XCTAssertTrue(changed.contains { $0.itemID == ids["view.knowledge"]! })
            let now = Timestamp.parse("2026-03-29T12:00:00Z")!
            let calendar = try QueryCalendar.make(timeZone: "UTC")
            func matches(_ key: String, _ date: String) throws -> Bool {
                let view = try SavedViewDefinition(store.get(ids[key]!).fields["viewDefinition"]!)
                var fields = note.fields
                fields["createdAt"] = .date("2026-01-01T00:00:00Z")
                fields["modifiedAt"] = .date(date)
                return try SpotlightQuery(view.expression!).matches(
                    Revision(fields: fields, formatVersion: note.formatVersion), at: now, calendar: calendar)
            }
            XCTAssertTrue(try matches("view.changed-today", "2026-03-29T00:00:00Z"))
            XCTAssertFalse(try matches("view.changed-today", "2026-03-30T00:00:00Z"))
            XCTAssertTrue(try matches("view.recent-changes", "2026-03-23T00:00:00Z"))
            XCTAssertFalse(try matches("view.recent-changes", "2026-03-22T23:59:59Z"))
            XCTAssertFalse(try matches("view.recent-changes", "2026-03-29T12:00:01Z"))
            let today = try SavedViewDefinition(
                store.get(ids["view.changed-today"]!).fields["viewDefinition"]!)
            var creationOnly = note.fields
            creationOnly["createdAt"] = .date("2026-03-29T00:00:00Z")
            creationOnly["modifiedAt"] = .date("2026-01-01T00:00:00Z")
            XCTAssertTrue(
                try SpotlightQuery(today.expression!).matches(
                    Revision(fields: creationOnly, formatVersion: note.formatVersion), at: now,
                    calendar: calendar))
            let view = try SavedViewDefinition(
                store.get(ids["view.recent-changes"]!).fields["viewDefinition"]!)
            XCTAssertEqual(view.presentation.columns.map(\.property), ["subject", "modifiedAt"])
            XCTAssertFalse(view.sort[0].isAscending)
        }
    }

    func testPresetEditsAndDeletedViewSurviveReapplication() throws {
        try fixture { store in
            let preset = try template()
            let ids = try preset.install(in: store, timeZone: "UTC", actorUID: store.ownerUID)
            let edited = try revise(
                store, store.get(ids["view.knowledge.decisions"]!), ["subject": .text("My decisions")])
            let deleted = try revise(
                store, store.get(ids["view.knowledge.questions"]!), ["isDeleted": .boolean(true)])
            XCTAssertEqual(try preset.install(in: store, timeZone: "UTC", actorUID: store.ownerUID), ids)
            XCTAssertEqual(try store.get(edited.itemID), edited)
            XCTAssertEqual(try store.get(deleted.itemID), deleted)
        }
    }

    func testReapplySkipsUnavailableDependenciesWithoutChangingExistingItems() throws {
        try fixture { store in
            let selection: ItemValue = .object([
                "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
            ])
            let categoryFields: [String: ItemValue] = ["subject": .text("Category"), "selection": selection]
            let viewFields: [String: ItemValue] = [
                "subject": .text("View"),
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "sort": .list([.object(["property": .text("modifiedAt"), "isAscending": .boolean(true)])]
                    ),
                    "presentation": .object([
                        "profile": .text(ViewPresentation.profile),
                        "columns": .list([
                            .object([
                                "property": .text("subject"), "title": .text("Category"),
                                "width": .integer(20),
                            ])
                        ]),
                    ]),
                ]),
            ]
            func entry(
                _ key: String, _ fields: [String: ItemValue], parents: [String] = [], path: [String]? = nil,
                excluded: [String]? = nil, sort: [String?]? = nil, columns: [String?]? = nil
            ) -> CategoryTemplate.Entry {
                .init(
                    key: key, classID: "Item", parents: parents, fields: fields, viewCategoryKeys: path,
                    excludedCategoryKeys: excluded, viewSortCategoryKeys: sort,
                    viewColumnCategoryKeys: columns)
            }
            let base = [
                entry("deleted", categoryFields), entry("converted", categoryFields),
                entry("edited", categoryFields),
            ]
            let initial = CategoryTemplate(identifier: "dependency-test", entries: base)
            let first = try initial.install(in: store, timeZone: "UTC", actorUID: store.ownerUID)
            let deleted = try revise(store, store.get(first["deleted"]!), ["isDeleted": .boolean(true)])
            let converted = try revise(store, store.get(first["converted"]!), [:], unset: ["selection"])
            let edited = try revise(store, store.get(first["edited"]!), ["subject": .text("My name")])
            let extended = CategoryTemplate(
                identifier: "dependency-test",
                entries: base + [
                    entry("child", categoryFields, parents: ["deleted"]),
                    entry("grandchild", categoryFields, parents: ["child"]),
                    entry("converted-child", categoryFields, parents: ["converted"]),
                    entry("path", viewFields, path: ["deleted"], sort: [nil], columns: [nil]),
                    entry("excluded", viewFields, excluded: ["deleted"], sort: [nil], columns: [nil]),
                    entry("sort", viewFields, sort: ["deleted"], columns: [nil]),
                    entry("columns", viewFields, sort: [nil], columns: ["converted"]),
                    entry("independent", categoryFields),
                ])
            let result = try extended.install(in: store, timeZone: "UTC", actorUID: store.ownerUID)
            for key in ["child", "grandchild", "converted-child", "path", "excluded", "sort", "columns"] {
                XCTAssertNil(result[key], key)
            }
            XCTAssertNotNil(result["independent"])
            XCTAssertEqual(try store.get(deleted.itemID), deleted)
            XCTAssertEqual(try store.get(converted.itemID), converted)
            XCTAssertEqual(try store.get(edited.itemID), edited)
            XCTAssertEqual(try extended.install(in: store, timeZone: "UTC", actorUID: store.ownerUID), result)
        }
    }
}
