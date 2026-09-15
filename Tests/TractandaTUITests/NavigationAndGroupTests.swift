import Foundation
import TractandaCore
import XCTest

@testable import TractandaTUI

final class NavigationAndGroupTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let store: ItemStore
        let service: ItemService
        let client: ItemClient
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = try ItemStore(root: root.appendingPathComponent("store"))
            service = ItemService(store: store)
            let service = service
            let uid = store.ownerUID
            client = ItemClient(transport: { service.handle($0, peerUID: uid) })
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func item(_ name: String, _ fields: [String: ItemValue] = [:]) throws -> Revision {
            try client.commit(
                CommitRequest(
                    classID: "NoteItem", changes: fields.merging(["subject": .text(name)]) { _, new in new },
                    operationID: Identifier.make())
            ).revision
        }
        func category(_ name: String, rule: String, parent: Revision? = nil) throws -> Revision {
            var fields: [String: ItemValue] = [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text(rule),
                ])
            ]
            if let parent { fields["categoryParents"] = .list([.reference(ItemReference(parent.itemID))]) }
            return try item(name, fields)
        }
        func revise(_ item: Revision, _ fields: [String: ItemValue]) throws -> Revision {
            try client.commit(
                CommitRequest(
                    action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                    changes: fields, operationID: Identifier.make())
            ).revision
        }
        func journal() -> RecoveryJournal {
            RecoveryJournal(url: root.appendingPathComponent("pending.json"), socket: "/fixture")
        }
        func app() throws -> TerminalApplication {
            try TerminalApplication(client: client, journal: journal(), itemsOnly: true)
        }
    }

    private func screen(_ app: TerminalApplication, width: Int = 140, height: Int = 35) -> String {
        app.render(columns: width, rows: height).map(\.text).joined(separator: "\n")
    }

    private func browse(_ name: String, in app: TerminalApplication, refining: Bool = false) {
        if !refining { app.handle(.text("a")) }
        app.handle(.text("c"))
        app.handle(.control(21))
        app.handle(.text(name))
        app.handle(.modified(.enter, .option))
    }

    func testBrowsingReplacesFiltersAndRootRestoresEveryItem() throws {
        let fixture = try Fixture()
        let root = try fixture.category("Item", rule: "itemID == *")
        let family = try fixture.category("Family", rule: "family == 1", parent: root)
        let calls = try fixture.category("Calls", rule: "call == 1", parent: root)
        let first = try fixture.item("Family only", ["family": .integer(1)])
        let second = try fixture.item("Call only", ["call": .integer(1)])
        let both = try fixture.item("Both", ["family": .integer(1), "call": .integer(1)])
        let workspace = Workspace(client: fixture.client)
        try workspace.browse(path: [root, family])
        XCTAssertEqual(Set(workspace.items.map(\.itemID)), [first.itemID, both.itemID])
        try workspace.browse(path: [root, calls])
        XCTAssertEqual(Set(workspace.items.map(\.itemID)), [second.itemID, both.itemID])
        try workspace.enter(path: [root, family])
        XCTAssertEqual(workspace.items.map(\.itemID), [both.itemID])
        workspace.expression = "subject == \"Both\""
        workspace.text = "Both"
        workspace.sectionCategories = [family]
        workspace.collapsedSectionIDs = [family.itemID]
        let saved = try fixture.client.commit(workspace.viewRequest(name: "Saved selection")).revision
        try workspace.openView(saved)
        try workspace.browse(path: [root])
        XCTAssertEqual(workspace.total, 7)
        XCTAssertTrue(workspace.expression.isEmpty && workspace.text.isEmpty)
        XCTAssertTrue(workspace.sectionCategories.isEmpty && workspace.collapsedSectionIDs.isEmpty)
        XCTAssertNil(workspace.view)
        XCTAssertNil(workspace.viewToUpdate)
        XCTAssertEqual(try fixture.store.history(saved.itemID).count, 1)
        for item in [root, family, calls, first, second, both] {
            XCTAssertEqual(try fixture.store.history(item.itemID).count, 1)
        }
    }

    func testCategoryEnterRefineAndEscapeAreDistinctUIActions() throws {
        let fixture = try Fixture()
        _ = try fixture.category("Family", rule: "family == 1")
        _ = try fixture.category("Calls", rule: "call == 1")
        let first = try fixture.item("Family task", ["family": .integer(1)])
        let second = try fixture.item("Phone task", ["call": .integer(1)])
        let app = try fixture.app()
        browse("Family", in: app)
        XCTAssertTrue(screen(app).contains("Family task"))
        browse("Calls", in: app)
        XCTAssertTrue(screen(app).contains("Phone task"))
        XCTAssertFalse(screen(app).contains("Family task"))
        browse("Family", in: app, refining: true)
        XCTAssertTrue(screen(app).contains("Calls / Family"))
        XCTAssertFalse(screen(app).contains("Phone task"))
        app.handle(.text("n"))
        app.handle(.text("Canceled item"))
        app.handle(.escape)
        XCTAssertTrue(screen(app).contains("Calls / Family"))
        // Categories is retained. Explicit A clears the Views refinement; Esc focuses a selector.
        app.handle(.text("a"))
        XCTAssertTrue(screen(app).contains("All readable items"))
        XCTAssertTrue(screen(app).contains("Family task"))
        XCTAssertTrue(screen(app).contains("Phone task"))
        XCTAssertEqual(try fixture.store.candidates().count, 4)
        XCTAssertEqual(try fixture.store.history(first.itemID).count, 1)
        XCTAssertEqual(try fixture.store.history(second.itemID).count, 1)
    }

    func testWholeSectionMarkingIncludesOtherPagesAndDeduplicatesItems() throws {
        let fixture = try Fixture()
        let first = try fixture.category("First", rule: "rank >= 0")
        let second = try fixture.category("Second", rule: "rank >= 1")
        for rank in 0..<66 { _ = try fixture.item("Task \(rank)", ["rank": .integer(Int64(rank))]) }
        let workspace = Workspace(client: fixture.client)
        workspace.sectionCategories = [first, second]
        try workspace.refresh()
        XCTAssertEqual(workspace.sections[0].items.count, 64)
        var marks = MarkedItems()
        try marks.toggle(workspace.items(inSectionAt: 1))
        XCTAssertEqual(marks.items.count, 65)
        try marks.toggle(workspace.items(inSectionAt: 0))
        XCTAssertEqual(marks.items.count, 66)
        XCTAssertEqual(Set(marks.items.map(\.itemID)).count, 66)
        try marks.toggle(workspace.items(inSectionAt: 1))
        XCTAssertEqual(marks.items.count, 1)
        XCTAssertEqual(marks.items[0].fields["rank"], .integer(0))
        _ = try fixture.item("Arrived meanwhile", ["rank": .integer(100)])
        XCTAssertThrowsError(try workspace.items(inSectionAt: 0)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "stateChanged")
        }
        XCTAssertEqual(marks.items.count, 1)
    }

    func testMarkLimitRejectsAnEntireOversizedAddition() throws {
        let fixture = try Fixture()
        let original = try fixture.item("Template")
        let items = try (0..<257).map { _ -> Revision in
            var fields = original.fields
            fields["itemID"] = .text(Identifier.make())
            return try Revision(fields: fields)
        }
        var marks = MarkedItems()
        try marks.toggle(items[0])
        XCTAssertThrowsError(try marks.toggle(Array(items.dropFirst())))
        XCTAssertEqual(marks.items, [items[0]])
        try marks.toggle(Array(items.prefix(256)))
        XCTAssertEqual(marks.items.count, 256)
        XCTAssertThrowsError(try marks.toggle(items[256]))
        XCTAssertEqual(marks.items.count, 256)
        marks.clear()
        XCTAssertTrue(marks.items.isEmpty)
    }

    func testBatchReportsConflictsAndPermissionRejectionsWithoutOverwriting() throws {
        let fixture = try Fixture()
        let first = try fixture.item("Allowed", ["foreign.data": .text("retain")])
        let conflict = try fixture.item("Concurrent")
        let denied = try fixture.item("Denied")
        let completion = try fixture.category("Completed", rule: "itemID == \"\"")
        let done = try fixture.item(
            "Already done", ["categoryOverrides": .object([completion.itemID: .text("include")])])
        let changed = try fixture.revise(conflict, ["body": .text("Newer work")])
        let client = ItemClient(transport: { data in
            let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let calls = envelope["methodCalls"] as! [[Any]]
            if calls[0][0] as? String == "TractandaItem/commit",
                (calls[0][1] as? [String: Any])?["itemID"] as? String == denied.itemID
            {
                throw TractandaError("forbidden", "Access was revoked.")
            }
            return fixture.service.handle(data, peerUID: fixture.store.ownerUID)
        })
        var batch = try BatchOperation(
            action: .done, items: [first, conflict, denied, done, first], category: completion)
        XCTAssertEqual(batch.entries.count, 4)
        while !batch.isComplete { try batch.performNext(using: client) }
        XCTAssertEqual(batch.entries.map { $0.outcome?.status }, [.saved, .rejected, .rejected, .unchanged])
        let saved = try fixture.store.get(first.itemID)
        XCTAssertEqual(saved.fields["categoryOverrides"]?.map?[completion.itemID], .text("include"))
        XCTAssertNil(saved.fields["status"])
        XCTAssertNotNil(saved.fields["completedAt"])
        XCTAssertEqual(saved.fields["foreign.data"], .text("retain"))
        XCTAssertEqual(try fixture.store.get(conflict.itemID), changed)
        XCTAssertEqual(try fixture.store.get(denied.itemID), denied)
        XCTAssertEqual(try fixture.store.history(done.itemID).count, 1)
        XCTAssertEqual(batch.summary, "1 saved · 1 unchanged · 2 rejected")
    }

    func testGroupCategoryDecisionsPreserveOtherTagsAndSkipUnchangedRevisions() throws {
        let fixture = try Fixture()
        let first = try fixture.category("First", rule: "itemID == \"\"")
        let second = try fixture.category("Second", rule: "itemID == \"\"")
        let original = try fixture.item(
            "Work",
            [
                "categoryOverrides": .object([second.itemID: .text("include")]),
                "foreign.data": .integer(7),
            ])
        var item = original
        for (action, expected) in [
            (BatchOperation.Action.include, "include"), (.exclude, "exclude"), (.reset, nil),
        ] {
            var batch = try BatchOperation(action: action, items: [item], category: first)
            try batch.performNext(using: fixture.client)
            XCTAssertEqual(batch.entries[0].outcome?.status, .saved)
            item = try fixture.store.get(item.itemID)
            XCTAssertEqual(item.fields["categoryOverrides"]?.map?[first.itemID]?.string, expected)
            XCTAssertEqual(item.fields["categoryOverrides"]?.map?[second.itemID], .text("include"))
            XCTAssertEqual(item.fields["foreign.data"], .integer(7))
        }
        var unchanged = try BatchOperation(action: .reset, items: [item], category: first)
        try unchanged.performNext(using: fixture.client)
        XCTAssertEqual(unchanged.entries[0].outcome?.status, .unchanged)
        XCTAssertEqual(try fixture.store.history(item.itemID).count, 4)
    }

    func testGroupRecoveryRetainsCheckpointsAndReplaysLostResponseExactlyOnce() throws {
        let fixture = try Fixture()
        let items = try ["First", "Second", "Third"].map { try fixture.item($0) }
        let completion = try fixture.category("Completed", rule: "itemID == \"\"")
        var batch = try BatchOperation(action: .done, items: items, category: completion)
        var journal: RecoveryJournal? = fixture.journal()
        try journal!.save(batch)
        try batch.performNext(using: fixture.client)
        try journal!.save(batch)
        var loseResponse = true
        var sentOperations: [String] = []
        let client = ItemClient(transport: { data in
            let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let calls = envelope["methodCalls"] as! [[Any]]
            let isCommit = calls[0][0] as? String == "TractandaItem/commit"
            if isCommit, let operation = (calls[0][1] as? [String: Any])?["operationID"] as? String {
                sentOperations.append(operation)
            }
            let response = fixture.service.handle(data, peerUID: fixture.store.ownerUID)
            if isCommit && loseResponse {
                loseResponse = false
                throw TractandaError("transportError", "Lost the committed response")
            }
            return response
        })
        XCTAssertThrowsError(try batch.performNext(using: client))
        XCTAssertNil(batch.entries[1].outcome)
        XCTAssertEqual(try fixture.store.history(items[1].itemID).count, 2)
        journal = nil
        let reopened = fixture.journal()
        guard case .batch(let recovered) = try reopened.loadOperation() else {
            return XCTFail("Missing batch")
        }
        XCTAssertEqual(recovered, batch)
        let app = try TerminalApplication(client: client, journal: reopened, itemsOnly: true)
        XCTAssertTrue(screen(app).contains("Recovered group operation"))
        XCTAssertEqual(try fixture.store.history(items[2].itemID).count, 1, "Launch must not submit edits.")
        app.handle(.escape)
        app.handle(.text("n"))
        XCTAssertEqual(try reopened.loadOperation().map { if case .batch = $0 { true } else { false } }, true)
        app.handle(.text("r"))
        XCTAssertTrue(screen(app).contains("3 saved · 0 unchanged · 0 rejected"))
        XCTAssertNil(try reopened.loadOperation())
        XCTAssertEqual(
            sentOperations,
            [
                batch.entries[1].request!.operationID, batch.entries[1].request!.operationID,
                batch.entries[2].request!.operationID,
            ])
        for item in items { XCTAssertEqual(try fixture.store.history(item.itemID).count, 2) }
    }

    func testMarkReviewConfirmationResizeDoneAndDeleteUI() throws {
        let fixture = try Fixture()
        _ = try fixture.category("Completed", rule: "itemID == \"\"")
        let item = try fixture.item("Only task")
        let app = try fixture.app()
        app.handle(.function(7))
        XCTAssertTrue(screen(app).contains("◆ 1 marked"))
        app.handle(.text("b"))
        app.handle(.text("v"))
        XCTAssertTrue(screen(app).contains("Marked items · 1"))
        app.handle(.escape)
        app.handle(.text("d"))
        app.handle(.paste("Completed"))
        app.handle(.enter)
        app.handle(.text("apply"))
        for (width, height) in [(52, 14), (30, 8), (160, 48), (80, 25)] {
            let frame = app.render(columns: width, rows: height)
            XCTAssertEqual(frame.count, height)
            if width >= 48 { XCTAssertTrue(frame.contains { $0.text.contains("apply") }) }
        }
        app.handle(.escape)
        XCTAssertEqual(try fixture.store.history(item.itemID).count, 1)
        // F4 also offers Done for the current item, with the same explicit confirmation.
        app.handle(.function(4))
        app.handle(.paste("Completed"))
        app.handle(.enter)
        app.handle(.control(19))
        XCTAssertTrue(screen(app).contains("Type apply"))
        XCTAssertEqual(try fixture.store.history(item.itemID).count, 1)
        app.handle(.text("apply"))
        app.handle(.control(19))
        XCTAssertTrue(screen(app).contains("1 saved · 0 unchanged · 0 rejected"))
        app.handle(.escape)
        XCTAssertFalse(screen(app).contains("◆ 1 marked"))
        app.handle(.text("m"))
        app.handle(.text("M"))
        XCTAssertFalse(screen(app).contains("◆ 1 marked"))
        app.handle(.text("m"))
        app.handle(.text("b"))
        app.handle(.delete)
        app.handle(.text("delete"))
        app.handle(.control(19))
        XCTAssertTrue(screen(app).contains("1 saved · 0 unchanged · 0 rejected"))
        XCTAssertTrue(try fixture.store.get(item.itemID).isDeleted)
        XCTAssertEqual(try fixture.store.history(item.itemID).count, 3)
        XCTAssertEqual(try fixture.store.history(item.itemID).last?.fields["subject"], item.fields["subject"])
    }
}
