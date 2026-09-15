import Foundation
import TractandaCore
import XCTest

@testable import TractandaTUI

final class NavigationHistoryTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trac-navigation-" + Identifier.make())
        let store: ItemStore
        let service: ItemService
        var client: ItemClient {
            ItemClient(transport: { self.service.handle($0, peerUID: self.store.ownerUID) })
        }
        init() throws {
            store = try ItemStore(root: root.appendingPathComponent("store"))
            service = ItemService(store: store)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func item(_ name: String, _ fields: [String: ItemValue] = [:]) throws -> Revision {
            try client.commit(
                CommitRequest(
                    classID: "NoteItem", changes: fields.merging(["subject": .text(name)]) { _, b in b },
                    operationID: Identifier.make())
            ).revision
        }
        func category(_ name: String, expression: String = "rank >= 0") throws -> Revision {
            try item(
                name,
                [
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text(expression),
                    ])
                ])
        }
        func revise(_ item: Revision, _ changes: [String: ItemValue]) throws -> Revision {
            try client.commit(
                CommitRequest(
                    action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                    changes: changes, operationID: Identifier.make())
            ).revision
        }
        func app(client: ItemClient? = nil) throws -> TerminalApplication {
            try TerminalApplication(
                client: client ?? self.client,
                journal: RecoveryJournal(
                    url: root.appendingPathComponent("pending.json"), socket: "/fixture"), itemsOnly: true
            )
        }
    }

    private func entry(_ workspace: Workspace) -> NavigationEntry {
        NavigationEntry(
            location: workspace.navigationLocation, selectedItemID: nil, selectedSectionID: nil,
            selectedRow: 0, firstVisibleRow: 0, columnOffset: 0)
    }
    private func screen(_ app: TerminalApplication) -> String {
        app.render(columns: 132, rows: 30).map(\.text).joined(separator: "\n")
    }
    private func browse(_ name: String, in app: TerminalApplication) {
        app.handle(.text("c"))
        app.handle(.control(21))
        app.handle(.paste(name))
        app.handle(.modified(.enter, .option))
    }

    func testHistoryBoundsNoOpAndForwardBranching() throws {
        let f = try Fixture()
        let workspace = Workspace(client: f.client)
        var history = NavigationHistory()
        for index in 0..<40 {
            let departure = entry(workspace)
            workspace.text = "Query \(index)"
            history.recordDeparture(departure, to: workspace.navigationLocation)
        }
        XCTAssertEqual(history.back.count, 32)
        XCTAssertEqual(history.back.first?.location.text, "Query 7")
        history.didRestore(backward: true, departing: entry(workspace))
        XCTAssertEqual(history.forward.last?.location.text, "Query 39")
        var movedPage = workspace.navigationLocation
        movedPage.positions = [64]
        history.recordDeparture(entry(workspace), to: movedPage)
        XCTAssertEqual(history.forward.count, 1, "Page/row movement does not discard Forward")
        let departure = entry(workspace)
        workspace.text = "Different route"
        history.recordDeparture(departure, to: workspace.navigationLocation)
        XCTAssertTrue(history.forward.isEmpty)
        XCTAssertEqual(history.back.count, 32)
    }

    func testRestoreRequeriesPagesSectionsAndRenamedCategories() throws {
        let f = try Fixture()
        let first = try f.category("First")
        let second = try f.category("Second")
        var items: [Revision] = []
        for rank in 0..<70 {
            items.append(try f.item("Item \(rank)", ["rank": .integer(Int64(rank))]))
        }
        let workspace = Workspace(client: f.client)
        workspace.categoryPath = [first]
        workspace.sectionCategories = [first, second]
        workspace.expression = "rank >= 0"
        workspace.sort = [try ItemSort(property: "rank")]
        workspace.columns = [try ViewColumn(property: "subject", title: "Name", width: 40)]
        try workspace.refresh()
        try workspace.loadPage(in: 0, forward: true)
        try workspace.toggleSection(1, isCollapsed: true)
        let location = workspace.navigationLocation
        _ = try f.revise(first, ["subject": .text("Renamed")])
        _ = try f.revise(items[65], ["subject": .text("Current content")])
        try workspace.allItems()
        let state = f.store.state
        XCTAssertFalse(try workspace.restore(location))
        XCTAssertEqual(workspace.sections.map(\.position), [64, 0])
        XCTAssertEqual(workspace.categoryPath.first?.fields["subject"], .text("Renamed"))
        XCTAssertEqual(workspace.sections[0].items[1].fields["subject"], .text("Current content"))
        XCTAssertEqual(workspace.collapsedSectionIDs, [second.itemID])
        XCTAssertEqual(workspace.columns.first?.title, "Name")
        XCTAssertEqual(workspace.sort, location.sort)
        XCTAssertEqual(f.store.state, state)
    }

    func testChangedNamedViewUsesCurrentDefinition() throws {
        let f = try Fixture()
        _ = try f.item("Zero", ["rank": .integer(0)])
        _ = try f.item("One", ["rank": .integer(1)])
        let workspace = Workspace(client: f.client)
        workspace.expression = "rank == 0"
        let saved = try f.client.commit(workspace.viewRequest(name: "Saved")).revision
        try workspace.openView(saved)
        let location = workspace.navigationLocation
        try workspace.allItems()
        var definition = saved.fields["viewDefinition"]!.map!
        definition["expression"] = .text("rank == 1")
        let changed = try f.revise(saved, ["viewDefinition": .object(definition)])
        XCTAssertTrue(try workspace.restore(location))
        XCTAssertEqual(workspace.items.map { $0.fields["subject"] }, [.text("One")])
        XCTAssertEqual(workspace.viewToUpdate?.revisionID, changed.revisionID)
        XCTAssertEqual(workspace.expression, "rank == 1")
    }

    func testUnsavedLayoutRetainsOriginalSaveGuardAndExtensionValues() throws {
        let f = try Fixture()
        let workspace = Workspace(client: f.client)
        let original = try f.client.commit(workspace.viewRequest(name: "Saved")).revision
        var definition = original.fields["viewDefinition"]!.map!
        definition["foreign.option"] = .text("retain")
        let saved = try f.revise(original, ["viewDefinition": .object(definition)])
        try workspace.openView(saved)
        workspace.columns = [try ViewColumn(property: "subject", title: "Draft title", width: 45)]
        workspace.view = nil
        let location = workspace.navigationLocation
        try workspace.allItems()
        let newer = try f.revise(saved, ["subject": .text("Someone else's edit")])
        XCTAssertFalse(try workspace.restore(location))
        XCTAssertEqual(workspace.columns.first?.title, "Draft title")
        let request = workspace.viewRequest(name: "Saved", replacing: true)
        XCTAssertEqual(request.expectedRevisionID, saved.revisionID)
        XCTAssertEqual(request.changes["viewDefinition"]?.map?["foreign.option"], .text("retain"))
        XCTAssertThrowsError(try f.client.commit(request)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "revisionConflict")
        }
        XCTAssertEqual(try f.store.get(saved.itemID), newer)
    }

    func testDeletedCategoryOrViewCannotRestoreCachedContent() throws {
        let f = try Fixture()
        _ = try f.item("Visible earlier", ["rank": .integer(1)])
        let category = try f.category("Later deleted")
        let workspace = Workspace(client: f.client)
        try workspace.browse(path: [category])
        let categoryLocation = workspace.navigationLocation
        let saved = try f.client.commit(workspace.viewRequest(name: "View later deleted")).revision
        try workspace.openView(saved)
        let viewLocation = workspace.navigationLocation
        try workspace.allItems()
        _ = try f.revise(category, ["isDeleted": .boolean(true)])
        _ = try f.revise(saved, ["isDeleted": .boolean(true)])
        for location in [categoryLocation, viewLocation] {
            XCTAssertThrowsError(try workspace.restore(location)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "notFound")
            }
            XCTAssertTrue(workspace.items.isEmpty)
            XCTAssertNil(workspace.queryState)
            XCTAssertNil(workspace.categoryNavigation)
        }
    }

    func testRestoringDraftRechecksCurrentAuthorizationBeforeHistoricalBase() throws {
        let f = try Fixture()
        var denied = false
        var historyReads = 0
        let client = ItemClient(transport: { data in
            let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let call = (request["methodCalls"] as! [[Any]])[0]
            if denied, call[0] as? String == "TractandaItem/get" {
                throw TractandaError("forbidden", "Simulated native authorization denial")
            }
            if call[0] as? String == "TractandaRevision/get" { historyReads += 1 }
            return f.service.handle(data, peerUID: f.store.ownerUID)
        })
        let workspace = Workspace(client: client)
        let saved = try client.commit(workspace.viewRequest(name: "Private view")).revision
        try workspace.openView(saved)
        workspace.view = nil
        let location = workspace.navigationLocation
        try workspace.allItems()
        denied = true
        XCTAssertThrowsError(try workspace.restore(location))
        XCTAssertEqual(historyReads, 0)
        XCTAssertTrue(workspace.items.isEmpty)
    }

    func testControllerBackForwardAllItemsAndFailedFilter() throws {
        let f = try Fixture()
        for (name, rank) in [("First view", 1), ("Second view", 2)] {
            _ = try f.item(
                name,
                [
                    "viewDefinition": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text("rank == \(rank)"),
                    ])
                ])
        }
        _ = try f.item("First result", ["rank": .integer(1)])
        _ = try f.item("Second result", ["rank": .integer(2)])
        let app = try f.app()
        let before = f.store.state
        for name in ["First view", "Second view"] {
            app.handle(.text("v"))
            app.handle(.paste(name))
            app.handle(.enter)
        }
        app.handle(.modified(.function(8), .option))
        XCTAssertTrue(screen(app).contains("First result"))
        XCTAssertFalse(screen(app).contains("Second result"))
        app.handle(.modified(.text("]"), .command))
        XCTAssertTrue(screen(app).contains("Second result"))
        app.handle(.modified(.left, .option))
        app.handle(.text("f"))
        app.handle(.control(21))
        app.handle(.paste("subject == ("))
        app.handle(.control(19))
        app.handle(.escape)
        app.handle(.modified(.right, .option))
        XCTAssertTrue(screen(app).contains("Second result"))
        app.handle(.text("a"))
        XCTAssertTrue(screen(app).contains("All items"))
        app.handle(.modified(.function(8), .option))
        XCTAssertFalse(screen(app).contains("First result"))
        XCTAssertTrue(screen(app).contains("Second result"))
        XCTAssertEqual(f.store.state, before)
    }

    func testUnavailableHistoryEntryIsRemovedAndEarlierViewRemainsReachable() throws {
        let f = try Fixture()
        let removed = try f.category("Will disappear")
        _ = try f.category("Still here")
        let app = try f.app()
        browse("Will disappear", in: app)
        browse("Still here", in: app)
        _ = try f.revise(removed, ["isDeleted": .boolean(true)])
        app.handle(.modified(.left, .option))
        XCTAssertTrue(screen(app).contains("history entry is unavailable"))
        app.handle(.modified(.left, .option))
        XCTAssertTrue(screen(app).contains("All items"))
        XCTAssertTrue(screen(app).contains("Returned to earlier view"))
    }

    func testNavigationBindingsKeepEditingAndFunctionKeysDistinct() {
        let map = Keymap.standard
        XCTAssertEqual(map.command(for: .modified(.text("["), .command), in: .browser), .goBack)
        XCTAssertEqual(map.command(for: .modified(.text("]"), .command), in: .browser), .goForward)
        XCTAssertEqual(map.command(for: .modified(.function(8), .option), in: .browser), .goBack)
        XCTAssertEqual(map.command(for: .function(8), in: .browser), .toggleSelector)
        XCTAssertEqual(map.command(for: .text("["), in: .browser), .previousColumn)
        XCTAssertEqual(map.command(for: .modified(.left, .option), in: .text), .wordLeft)
        XCTAssertNil(map.command(for: .modified(.left, .option), in: .pending))
    }
}
