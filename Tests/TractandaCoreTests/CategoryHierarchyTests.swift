import XCTest

@testable import TractandaCore

final class CategoryHierarchyTests: XCTestCase {
    private func create(_ store: ItemStore, _ fields: [String: ItemValue] = [:]) throws -> Revision {
        try store.commit(CommitRequest(classID: "Item", changes: fields, operationID: Identifier.make()))
            .revision
    }
    private func edit(
        _ store: ItemStore, _ item: Revision, _ fields: [String: ItemValue], unset: [String] = []
    ) throws -> Revision {
        try store.commit(
            CommitRequest(
                action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                changes: fields, unset: unset, operationID: Identifier.make())
        ).revision
    }
    private func category(
        _ store: ItemStore, _ name: String, parents: [Revision] = [], rule: String = "itemID == \"\""
    ) throws -> Revision {
        try create(
            store,
            [
                "subject": .text(name),
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text(rule),
                ]),
                "categoryParents": .list(parents.map { .reference(ItemReference($0.itemID)) }),
            ])
    }
    private func fixture(_ body: (ItemStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        try body(ItemStore(root: root), root)
    }
    private func template() throws -> CategoryTemplate {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try JSON.decode(
            CategoryTemplate.self,
            Data(contentsOf: root.appendingPathComponent("templates/starter-categories.json")))
    }

    func testInheritanceMultipleParentsOverridesRenamesAndRebuild() throws {
        try fixture { store, _ in
            let root = try category(store, "Item", rule: "itemID == *")
            let who = try category(store, "Who", parents: [root])
            let project = try category(store, "Project", parents: [root])
            let dad = try category(
                store, "Dad", parents: [who, project], rule: "selection != * && subject ==[c] \"*dad*\"")
            var note = try create(store, ["subject": .text("Talk to Dad about chess")])
            let original = note.revisionID
            for parent in [root, who, project, dad] {
                XCTAssertTrue(try Categories.explain(note, category: parent, store: store).isIncluded)
            }
            XCTAssertEqual(
                try Categories.query(store: store, categoryPath: [root.itemID, who.itemID, dad.itemID]).map(
                    \.itemID), [note.itemID])
            XCTAssertTrue(
                try Categories.explain(note, category: who, store: store).reason.contains(dad.itemID))
            let renamed = try edit(store, dad, ["subject": .text("Father")])
            try store.rebuildIndex()
            XCTAssertEqual(try store.get(note.itemID).revisionID, original)
            XCTAssertTrue(try Categories.explain(note, category: who, store: store).isIncluded)
            note = try edit(store, note, ["categoryOverrides": .object([who.itemID: .text("exclude")])])
            XCTAssertFalse(try Categories.explain(note, category: who, store: store).isIncluded)
            XCTAssertTrue(try Categories.explain(note, category: renamed, store: store).isIncluded)
            XCTAssertTrue(try Categories.query(store: store, categoryPath: [who.itemID, dad.itemID]).isEmpty)
            XCTAssertEqual(
                try Categories.query(store: store, categoryPath: [project.itemID, dad.itemID]).map(\.itemID),
                [note.itemID])
        }
    }

    func testDeletionDisablingAndCycleRejectionDoNotRewriteMembers() throws {
        try fixture { store, _ in
            var parent = try category(store, "Parent")
            let child = try category(store, "Child", parents: [parent], rule: "body == *")
            let note = try create(store, ["body": .text("Keep me")])
            XCTAssertThrowsError(
                try edit(store, parent, ["categoryParents": .list([.reference(ItemReference(child.itemID))])])
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "categoryCycle")
            }
            parent = try edit(store, parent, ["isDeleted": .boolean(true)])
            XCTAssertEqual(try CategoryHierarchy(store.candidates()).roots, [child.itemID])
            XCTAssertEqual(
                try Categories.query(store: store, categoryPath: [child.itemID]).map(\.itemID), [note.itemID])
            XCTAssertEqual(try store.get(note.itemID), note)
            parent = try edit(store, parent, ["isDeleted": .boolean(false)])
            parent = try edit(store, parent, [:], unset: ["selection"])
            XCTAssertEqual(try CategoryHierarchy(store.candidates()).roots, [child.itemID])
            let selection = child.fields["selection"]!
            parent = try edit(
                store, parent, ["categoryParents": .list([.reference(ItemReference(child.itemID))])])
            XCTAssertThrowsError(try edit(store, parent, ["selection": selection]))
            try store.rebuildIndex()
            XCTAssertEqual(try store.get(note.itemID), note)
        }
    }

    func testOptionalTemplatePhoneSuggestionsAndDeletedDefaultsStayDeleted() throws {
        try fixture { store, _ in
            let template = try template()
            let ids = try template.install(in: store, timeZone: "Europe/Vienna", actorUID: store.ownerUID)
            let emptyStoreCount = try store.candidates().count
            let unknown = try create(store, ["subject": .text("Talk to Alex about the roof")])
            let short = try create(
                store,
                [
                    "subject": .text("Call Dad"), "estimatedMinutes": .integer(10), "urgency": .text("U0"),
                    "priority": .text("P1"),
                ])
            let long = try create(
                store, ["subject": .text("Phone the architect"), "estimatedMinutes": .integer(40)])
            let site = try create(
                store, ["subject": .text("Talk to Alex about the inspection"), "location": .text("building")])
            let done = try create(
                store,
                [
                    "subject": .text("Call the club"),
                    "categoryOverrides": .object([ids["status.done"]!: .text("include")]),
                ])
            let phone = try store.get(ids["means.phone"]!)
            XCTAssertEqual(
                Set(try Categories.query(store: store, categoryPath: [phone.itemID]).map(\.itemID)),
                Set([unknown, short, long, done].map(\.itemID)))
            XCTAssertEqual(
                try Categories.savedView(store: store, id: ids["phone-20-minutes"]!).map(\.itemID),
                [short.itemID, unknown.itemID])
            _ = try edit(store, site, ["categoryOverrides": .object([phone.itemID: .text("include")])])
            XCTAssertTrue(
                try Categories.query(store: store, categoryPath: [phone.itemID]).contains {
                    $0.itemID == site.itemID
                })
            _ = try edit(store, phone, ["subject": .text("Calls")])
            let root = try store.get(ids["who"]!)
            _ = try edit(store, root, ["isDeleted": .boolean(true)])
            XCTAssertEqual(try template.install(in: store, timeZone: "UTC", actorUID: store.ownerUID), ids)
            XCTAssertEqual(try store.get(phone.itemID).fields["subject"]?.string, "Calls")
            XCTAssertTrue(try store.get(root.itemID).isDeleted)
            // Every optional category and saved view can go; the unfiltered item set survives.
            for id in ids.values {
                let item = try store.get(id)
                if !item.isDeleted { _ = try edit(store, item, ["isDeleted": .boolean(true)]) }
            }
            try store.rebuildIndex()
            _ = try template.install(in: store, timeZone: "UTC", actorUID: store.ownerUID)
            XCTAssertTrue(try CategoryHierarchy(store.candidates()).items.isEmpty)
            XCTAssertEqual(try store.candidates().count, 5)
            XCTAssertEqual(try store.candidates(includeDeleted: true).count, emptyStoreCount + 5)
        }
    }

    func testTemplateUsesImplicitRootWithoutHidingUncategorizedItems() throws {
        try fixture { store, _ in
            XCTAssertTrue(try store.candidates(includeDeleted: true).isEmpty)
            XCTAssertTrue(try Categories.query(store: store, categoryPath: []).isEmpty)
            let uncategorized = try create(store, ["subject": .text("Uncategorized knowledge")])
            let ids = try template().install(in: store, timeZone: "UTC", actorUID: store.ownerUID)
            XCTAssertNil(ids["item"], "All items is the empty filter, never a starter record")
            XCTAssertEqual(ids.count, 63)
            let graph = try CategoryHierarchy(store.candidates())
            XCTAssertEqual(graph.items.count, 62)
            let axes = ["who", "what", "when", "where", "means", "priority", "urgency", "status"]
            XCTAssertEqual(Set(graph.roots), Set(axes.map { ids[$0]! }))
            for axis in axes {
                XCTAssertTrue(try CategoryHierarchy.parents(of: store.get(ids[axis]!)).isEmpty)
            }
            let all = try Categories.query(store: store)
            XCTAssertEqual(
                all.map(\.itemID), try Categories.query(store: store, categoryPath: []).map(\.itemID))
            XCTAssertTrue(all.contains { $0.itemID == uncategorized.itemID })
            XCTAssertEqual(all.count, ids.count + 1)
            for id in ids.values {
                _ = try edit(store, store.get(id), ["isDeleted": .boolean(true)])
            }
            try store.rebuildIndex()
            XCTAssertEqual(try Categories.query(store: store).map(\.itemID), [uncategorized.itemID])
            XCTAssertTrue(try CategoryHierarchy(store.candidates()).roots.isEmpty)
        }
    }

    func testCalendarWindowsDSTQuarterLeapMonthAndDateOnlyDeadlines() throws {
        try fixture { store, _ in
            let calendar = try QueryCalendar.make(timeZone: "Europe/Vienna")
            func window(_ period: String, _ offset: Int64 = 0, event: Bool = false) throws
                -> CategoryTimeWindow
            {
                var fields: [String: ItemValue] = [
                    "period": .text(period), "offset": .integer(offset), "startProperty": .text("dueAt"),
                ]
                if event { fields["endProperty"] = .text("endsAt") }
                return try CategoryTimeWindow(.object(fields))
            }
            let march = Timestamp.parse("2026-03-29T12:00:00+02:00")!
            XCTAssertEqual(try window("day").bounds(at: march, calendar: calendar)!.duration, 23 * 3600)
            let autumn = Timestamp.parse("2026-10-25T12:00:00+01:00")!
            XCTAssertEqual(try window("day").bounds(at: autumn, calendar: calendar)!.duration, 25 * 3600)
            let end = try window("rollingMonths", 1).bounds(
                at: Timestamp.parse("2024-01-31T12:00:00Z")!, calendar: calendar)!.end
            XCTAssertEqual(Timestamp.format(end), Timestamp.format(Timestamp.parse("2024-02-29T12:00:00Z")!))
            XCTAssertEqual(
                try window("quarter", 1).bounds(at: march, calendar: calendar)!.start,
                Timestamp.parse("2026-04-01T00:00:00+02:00")!)
            let day = try create(store, ["dueAt": .text("2026-03-29")])
            XCTAssertFalse(try window("past").matches(day, at: march, calendar: calendar))
            XCTAssertTrue(
                try window("past").matches(
                    day, at: Timestamp.parse("2026-03-30T00:00:00+02:00")!, calendar: calendar))
            let event = try create(
                store, ["dueAt": .date("2026-03-28T20:00:00Z"), "endsAt": .date("2026-03-29T10:00:00Z")])
            XCTAssertTrue(try window("day", event: true).matches(event, at: march, calendar: calendar))
            XCTAssertFalse(try window("day", 1, event: true).matches(event, at: march, calendar: calendar))
            let tomorrow = try create(store, ["dueAt": .date("2026-03-29T22:00:00Z")])
            let todayQuery = try SpotlightQuery("dueAt >= $time.today && dueAt < $time.today(1)")
            XCTAssertFalse(todayQuery.matches(tomorrow, at: march, calendar: calendar))
            XCTAssertTrue(
                todayQuery.matches(
                    tomorrow, at: Timestamp.parse("2026-03-30T00:00:00+02:00")!, calendar: calendar))
            for expression in [
                "dueAt > $time.now(-60)", "dueAt >= $time.this_week(1)", "dueAt < $time.this_month(3)",
                "dueAt < $time.this_year(1)", "dueAt > $time.yesterday",
            ] {
                _ = try SpotlightQuery(expression)
            }
            XCTAssertThrowsError(try SpotlightQuery("dueAt == $time.this_quarter"))
            XCTAssertThrowsError(try QueryCalendar.make(timeZone: "Bad/Zone"))
        }
    }

    func testNativeTimeSnapshotAndFullIndexLossRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let ids = try template().install(in: store!, timeZone: "UTC", actorUID: store!.ownerUID)
        let note = try create(store!, ["dueAt": .date("2026-09-10T00:00:00Z")])
        var oldState = store!.state
        func query(_ at: String) throws -> [String] {
            let service = ItemService(store: store!)
            let uid = store!.ownerUID
            let client = ItemClient(transport: { service.handle($0, peerUID: uid) })
            struct Page: Decodable {
                let ids: [String]
                let evaluatedAt: String
                let queryState: String
            }
            let result = try JSON.decode(
                Page.self,
                client.call(
                    "TractandaItem/query",
                    arguments: [
                        "categoryPath": [ids["when.deadlines.today"]!], "at": at,
                    ]))
            XCTAssertEqual(result.queryState, oldState)
            XCTAssertEqual(Timestamp.parse(result.evaluatedAt), Timestamp.parse(at))
            return result.ids
        }
        XCTAssertEqual(try query("2026-09-09T23:59:59Z"), [])
        XCTAssertEqual(try query("2026-09-10T00:00:00Z"), [note.itemID])
        store = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
        store = try ItemStore(root: root)
        oldState = store!.state
        XCTAssertEqual(try store!.get(note.itemID), note)
        XCTAssertEqual(try query("2026-09-10T00:00:00Z"), [note.itemID])
    }
}
