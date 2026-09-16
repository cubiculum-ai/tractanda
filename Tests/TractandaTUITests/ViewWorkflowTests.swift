import TractandaCore
import XCTest

@testable import TractandaTUI

final class ViewWorkflowTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let store: ItemStore
        let client: ItemClient
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            store = try ItemStore(root: root.appendingPathComponent("store"))
            let service = ItemService(store: store)
            let uid = store.ownerUID
            client = ItemClient(transport: { service.handle($0, peerUID: uid) })
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func item(_ fields: [String: ItemValue]) throws -> Revision {
            try client.commit(
                CommitRequest(classID: "Item", changes: fields, operationID: Identifier.make())
            ).revision
        }
        func category(_ name: String, rule: String = "rank == *") throws -> Revision {
            try item([
                "subject": .text(name),
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text(rule),
                ]),
            ])
        }
        func application(viewID: String? = nil) throws -> TerminalApplication {
            try TerminalApplication(
                client: client,
                journal: RecoveryJournal(
                    url: root.appendingPathComponent("pending.json"), socket: "/fixture"),
                viewID: viewID, itemsOnly: true)
        }
    }

    func testSectionPagesOverlapAndExpansionRechecksServer() throws {
        let fixture = try Fixture()
        let first = try fixture.category("First")
        let second = try fixture.category("Second")
        for rank in (0..<66).reversed() { _ = try fixture.item(["rank": .integer(Int64(rank))]) }
        let workspace = Workspace(client: fixture.client)
        workspace.sectionCategories = [first, second]
        workspace.sort = [try ItemSort(property: "rank")]
        try workspace.refresh()
        XCTAssertEqual(workspace.sections.map(\.total), [66, 66])
        XCTAssertEqual(workspace.sections[0].items, workspace.sections[1].items)
        XCTAssertEqual(workspace.sections[0].items.first?.fields["rank"], .integer(0))
        try workspace.loadPage(in: 0, forward: true)
        XCTAssertEqual(workspace.sections[0].items.map { $0.fields["rank"] }, [.integer(64), .integer(65)])
        XCTAssertEqual(workspace.sections[1].position, 0)
        try workspace.toggleSection(0, isCollapsed: true)
        XCTAssertEqual(workspace.rows.filter { $0.sectionIndex == 0 }.count, 1)
        let last = try XCTUnwrap(workspace.sections[0].items.last)
        _ = try fixture.client.commit(workspace.assignment("exclude", item: last, category: first))
        try workspace.toggleSection(0, isCollapsed: false)
        XCTAssertEqual(workspace.sections.map(\.total), [65, 66])
        XCTAssertEqual(workspace.sections[0].items.map { $0.fields["rank"] }, [.integer(64)])
        // A change between page fetches invalidates pagination instead of silently skipping items.
        _ = try fixture.item(["rank": .integer(-1)])
        XCTAssertThrowsError(try workspace.loadPage(in: 1, forward: true)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "stateChanged")
        }
        XCTAssertTrue(workspace.rows.isEmpty)
    }

    func testDefaultViewWorkspaceUsesPrivatePinnedPreferences() throws {
        let fixture = try Fixture()
        let first = try fixture.item([
            "subject": .text("Zulu view"),
            "viewDefinition": .object(["language": .text(SpotlightQuery.profile)]),
        ])
        _ = try fixture.item([
            "subject": .text("Alpha view"),
            "viewDefinition": .object(["language": .text(SpotlightQuery.profile)]),
        ])
        let preferences = fixture.root.appendingPathComponent("private/views.json")
        let app = try TerminalApplication(
            client: fixture.client,
            journal: RecoveryJournal(
                url: fixture.root.appendingPathComponent("pending-default.json"), socket: "/fixture"),
            viewPreferencesURL: preferences)
        let initial = app.render(columns: 100, rows: 30).map(\.text).joined(separator: "\n")
        XCTAssertTrue(initial.contains("[Views]"))
        XCTAssertTrue(initial.contains("All items · implicit"))
        app.handle(.down)
        app.handle(.down)
        app.handle(.modified(.text("m"), .command))
        XCTAssertEqual(try ViewWorkspacePreferences.load(from: preferences).pinnedViewIDs, [first.itemID])
        let reloaded = try TerminalApplication(
            client: fixture.client,
            journal: RecoveryJournal(
                url: fixture.root.appendingPathComponent("pending-reloaded.json"), socket: "/fixture"),
            viewPreferencesURL: preferences)
        let pinned = reloaded.render(columns: 100, rows: 30).map(\.text).joined(separator: "\n")
        XCTAssertTrue(pinned.contains("★ Zulu view"))
        reloaded.handle(.down)
        reloaded.handle(.enter)
        XCTAssertTrue(
            reloaded.render(columns: 100, rows: 30).contains { $0.text.contains("Opened Zulu view") })
    }

    func testCategoryTreeNavigationChildCreationMovementAndDeletion() throws {
        let fixture = try Fixture()
        let root = try fixture.category("Item", rule: "itemID == *")
        func child(_ title: String, _ parents: [Revision], _ rule: String = "itemID == \"\"") throws
            -> Revision
        {
            try fixture.item([
                "subject": .text(title),
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text(rule),
                ]),
                "categoryParents": .list(parents.map { .reference(ItemReference($0.itemID)) }),
            ])
        }
        let means = try child("Means", [root])
        let phone = try child("Phone", [means], "subject == \"Talk to Pat\"")
        let note = try fixture.item(["subject": .text("Talk to Pat")])
        let app = try fixture.application()
        func findCategory(_ name: String) throws {
            let lines = app.render(columns: 100, rows: 24)
            for (row, line) in lines.enumerated() {
                if let hit = line.hits.first(where: {
                    if case .pickerText = $0.target { true } else { false }
                }) {
                    let column = hit.columns.lowerBound
                    app.handleMouse(
                        .init(kind: .press, button: .left, column: column, row: row, modifiers: []))
                    app.handleMouse(
                        .init(kind: .release, button: .left, column: column, row: row, modifiers: []))
                    app.handle(.control(21))
                    app.handle(.paste(name))
                    return
                }
            }
            XCTFail("Category Find field is unavailable")
        }
        app.handle(.function(9))
        // All items previews category items too; inspect only the navigator's rendered column.
        let initial = app.render(columns: 100, rows: 24).map {
            String($0.text.split(separator: "│", maxSplits: 1, omittingEmptySubsequences: false)[0])
        }.joined(separator: "\n")
        XCTAssertTrue(initial.contains("Means"))
        XCTAssertFalse(initial.contains("Phone"))
        app.handle(.down)
        app.handle(.down)
        app.handle(.right)
        XCTAssertTrue(
            app.render(columns: 100, rows: 24).map(\.text).joined(separator: "\n").contains("Phone"))
        app.handle(.text("Phone"))
        app.handle(.enter)
        let view = app.render(columns: 100, rows: 24).map(\.text).joined(separator: "\n")
        XCTAssertTrue(
            view.components(separatedBy: "\n").contains {
                $0.replacingOccurrences(of: " ▾", with: "").trimmingCharacters(in: .whitespaces)
                    == "Item / Means / Phone"
            })
        XCTAssertTrue(view.contains("Talk to Pat"))
        app.handle(.function(8))
        try findCategory("Means")
        app.handle(.modified(.text("n"), .option))
        app.handle(.text("Video"))
        app.handle(.control(19))
        let video = try XCTUnwrap(
            fixture.store.candidates().first { $0.fields["subject"]?.string == "Video" })
        XCTAssertEqual(try CategoryHierarchy.parents(of: video), [means.itemID])
        XCTAssertTrue(
            app.render(columns: 100, rows: 24).map(\.text).joined(separator: "\n").contains(
                "Category manager"))
        app.handle(.function(9))  // Switch away and return to the retained manager.
        app.handle(.function(9))
        try findCategory("Video")
        app.handle(.modified(.text("M"), .option))
        XCTAssertEqual(try CategoryHierarchy.parents(of: fixture.store.get(video.itemID)), [])
        XCTAssertTrue(app.render(columns: 100, rows: 24).map(\.text).joined().contains("Category manager"))
        try findCategory("Means")
        app.handle(.modified(.function(4), .option))
        app.handle(.text("delete"))
        app.handle(.control(19))
        XCTAssertTrue(
            try fixture.store.get(means.itemID).isDeleted,
            app.render(columns: 100, rows: 24).map(\.text).joined(separator: "\n"))
        XCTAssertEqual(try fixture.store.get(note.itemID), note)
        XCTAssertTrue(try CategoryHierarchy(fixture.store.candidates()).roots.contains(phone.itemID))
    }

    func testCategoryTreeMultiplePlacementsAndDeduplicatedSearch() throws {
        let fixture = try Fixture()
        let left = try fixture.category("People")
        let right = try fixture.category("Projects")
        let shared = try fixture.item([
            "subject": .text("Dad"), "selection": left.fields["selection"]!,
            "categoryParents": .list([left, right].map { .reference(ItemReference($0.itemID)) }),
        ])
        let tree = try CategoryTree(fixture.store.candidates())
        let rows = tree.rows(filter: "", expanded: tree.initialExpansion)
        XCTAssertEqual(rows.filter { $0.item.itemID == shared.itemID }.count, 2)
        let matches = tree.rows(filter: "Dad", expanded: [])
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.last?.path.map(\.itemID), [left.itemID, shared.itemID])
        XCTAssertEqual(tree.rows(filter: "", expanded: []).count, 2)
    }

    func testCategoryPickerRevealsSearchBranchAndRetainsChosenParent() throws {
        let fixture = try Fixture()
        let left = try fixture.category("People")
        let right = try fixture.category("Projects")
        let shared = try fixture.item([
            "subject": .text("Shared"), "selection": left.fields["selection"]!,
            "categoryParents": .list([left, right].map { .reference(ItemReference($0.itemID)) }),
        ])
        _ = try fixture.item([
            "subject": .text("Hidden leaf"), "selection": left.fields["selection"]!,
            "categoryParents": .list([.reference(ItemReference(shared.itemID))]),
        ])
        let app = try fixture.application()
        func lines() -> [ScreenLine] { app.render(columns: 100, rows: 24) }
        app.handle(.function(9))
        app.handle(.down)
        app.handle(.down)
        app.handle(.down)  // All items precedes the category placements.
        app.handle(.down)
        app.handle(.right)
        XCTAssertEqual(lines().filter { $0.text.contains("Hidden leaf") }.count, 1)
        app.handle(.enter)
        XCTAssertTrue(lines().map(\.text).joined().contains("Projects ▾ / Shared"))
        app.handle(.function(8))
        app.handle(.control(21))
        app.handle(.paste("Shared"))
        XCTAssertEqual(lines().filter { $0.text.contains("Shared") && $0.text.contains(">") }.count, 1)
        app.handle(.right)  // Clear search and open the selected placement, retaining its selection.
        XCTAssertEqual(lines().filter { $0.text.contains("Hidden leaf") }.count, 1)
        app.handle(.enter)
        XCTAssertTrue(lines().map(\.text).joined().contains("Projects ▾ / Shared"))
        XCTAssertEqual(try fixture.store.history(shared.itemID).count, 1)
    }

    func testColumnsAreStagedResizableAndSavedWithoutLosingExtensions() throws {
        let fixture = try Fixture()
        _ = try fixture.item(["subject": .text("Example"), "custom.priority": .integer(42)])
        let initialColumn = try ViewColumn(
            property: "subject", title: "Subject", width: 30,
            preserving: .object(["foreign.column": .text("retain")]))
        let original = try fixture.item([
            "subject": .text("Existing view"), "foreign.item": .text("retain"),
            "viewDefinition": .object([
                "language": .text(SpotlightQuery.profile), "expression": .text("subject == \"Example\""),
                "foreign.query": .text("retain"),
                "presentation": .object([
                    "profile": .text(ViewPresentation.profile), "columns": .list([initialColumn.value]),
                    "foreign.layout": .text("retain"),
                ]),
            ]),
        ])
        let app = try fixture.application(viewID: original.itemID)
        app.handle(.text("l"))
        app.handle(.text("e"))
        app.handle(.tab)
        app.handle(.control(21))
        app.handle(.text("Renamed"))
        app.handle(.control(19))
        app.handle(.escape)
        XCTAssertTrue(app.render(columns: 80, rows: 25).contains { $0.text.contains("Subject") })
        XCTAssertEqual(try fixture.store.history(original.itemID).count, 1)
        app.handle(.text("l"))
        app.handle(.text("n"))
        app.handle(.text("custom.priority"))
        app.handle(.tab)
        app.handle(.text("Priority 文"))
        for (width, height) in [(52, 14), (30, 8), (160, 48), (80, 25)] {
            let screen = app.render(columns: width, rows: height)
            XCTAssertEqual(screen.count, height)
            if width >= 48 { XCTAssertTrue(screen.contains { $0.text.contains("Priority 文") }) }
        }
        app.handle(.tab)
        app.handle(.control(21))
        app.handle(.text("12"))
        app.handle(.control(19))
        app.handle(.left)  // Move the new column ahead of Subject.
        app.handle(.control(19))
        XCTAssertEqual(
            try fixture.store.history(original.itemID).count, 1, "Applying a layout is not a durable edit.")
        app.handle(.text("s"))
        app.handle(.control(19))
        let saved = try fixture.client.revision(for: original.itemID)
        XCTAssertEqual(try fixture.store.history(original.itemID).count, 2)
        let definition = try SavedViewDefinition(XCTUnwrap(saved.fields["viewDefinition"]))
        XCTAssertEqual(definition.presentation.columns.map(\.property), ["custom.priority", "subject"])
        XCTAssertEqual(definition.presentation.columns.first?.width, 12)
        XCTAssertEqual(saved.fields["foreign.item"], .text("retain"))
        XCTAssertEqual(saved.fields["viewDefinition"]?.map?["foreign.query"], .text("retain"))
        XCTAssertEqual(
            saved.fields["viewDefinition"]?.map?["presentation"]?.map?["foreign.layout"], .text("retain"))
        XCTAssertEqual(definition.presentation.columns[1].value.map?["foreign.column"], .text("retain"))
        app.handle(.text("s"))
        app.handle(.control(19))
        XCTAssertEqual(try fixture.store.history(original.itemID).count, 2, "Unchanged save must be a no-op.")
        try fixture.store.rebuildIndex()
        let reopened = Workspace(client: fixture.client)
        try reopened.openView(fixture.client.revision(for: saved.itemID))
        XCTAssertEqual(reopened.columns.map(\.property), ["custom.priority", "subject"])
    }

    func testSectionPickerCaptureAndSortSaveUseNativeSemantics() throws {
        let fixture = try Fixture()
        let first = try fixture.category("First", rule: "itemID == \"\"")
        let second = try fixture.category("Second", rule: "itemID == \"\"")
        let app = try fixture.application()
        app.handle(.text("g"))
        app.handle(.text("First"))
        app.handle(.text(" "))
        app.handle(.control(21))
        app.handle(.text("Second"))
        app.handle(.enter)
        app.handle(.control(19))
        app.handle(.home)
        app.handle(.left)
        app.handle(.down)
        app.handle(.text("n"))
        app.handle(.text("Captured under Second"))
        app.handle(.control(19))
        let item = try XCTUnwrap(
            fixture.client.revisions(matching: "subject == \"Captured under Second\"").first)
        XCTAssertEqual(item.fields["categoryOverrides"], .object([second.itemID: .text("include")]))
        let screen = app.render(columns: 120, rows: 30).map(\.text).joined(separator: "\n")
        XCTAssertTrue(screen.contains("[+] First"))
        XCTAssertTrue(screen.contains("[-] Second"))
        app.handle(.text("o"))
        app.handle(.text("subject"))
        app.handle(.tab)
        app.handle(.control(21))
        app.handle(.text("descending"))
        app.handle(.control(19))
        app.handle(.text("s"))
        app.handle(.text("Section view"))
        app.handle(.control(19))
        let view = try XCTUnwrap(fixture.client.revisions(matching: "viewDefinition == *").first)
        let definition = try SavedViewDefinition(XCTUnwrap(view.fields["viewDefinition"]))
        XCTAssertEqual(definition.sort, [try ItemSort(property: "subject", isAscending: false)])
        XCTAssertEqual(definition.presentation.sectionIDs, [first.itemID, second.itemID])
        XCTAssertEqual(definition.presentation.collapsedSectionIDs, [first.itemID])
        // A concurrent edit rejects Save and keeps the user's pending name editable.
        _ = try fixture.client.commit(
            CommitRequest(
                action: .revise, itemID: view.itemID,
                expectedRevisionID: view.revisionID, changes: ["subject": .text("Changed elsewhere")],
                operationID: Identifier.make()))
        app.handle(.text("s"))
        app.handle(.text(" local change"))
        app.handle(.control(19))
        let conflicted = app.render(columns: 160, rows: 40).map(\.text).joined(separator: "\n")
        XCTAssertTrue(conflicted.contains("revisionConflict"))
        XCTAssertTrue(conflicted.contains("local change"))
        XCTAssertEqual(try fixture.store.history(view.itemID).count, 2)
    }
}
