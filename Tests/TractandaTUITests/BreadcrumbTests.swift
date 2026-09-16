import Foundation
import TractandaCore
import XCTest

@testable import TractandaTUI

final class BreadcrumbTests: XCTestCase {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trac-breadcrumb-" + Identifier.make())
        let store: ItemStore
        let service: ItemService
        var client: ItemClient {
            ItemClient(transport: { self.service.handle($0, peerUID: self.store.ownerUID) })
        }
        init() throws {
            store = try ItemStore(root: directory.appendingPathComponent("store"))
            service = ItemService(store: store)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func item(_ title: String, _ fields: [String: ItemValue] = [:]) throws -> Revision {
            try client.commit(
                CommitRequest(
                    classID: "Item", changes: fields.merging(["subject": .text(title)]) { _, new in new },
                    operationID: Identifier.make())
            ).revision
        }
        func category(_ title: String, rule: String = "itemID == *", parent: Revision? = nil) throws
            -> Revision
        {
            var fields: [String: ItemValue] = [
                "selection": .object(["language": .text(SpotlightQuery.profile), "expression": .text(rule)])
            ]
            if let parent { fields["categoryParents"] = .list([.reference(ItemReference(parent.itemID))]) }
            return try item(title, fields)
        }
        func app() throws -> TerminalApplication {
            try TerminalApplication(
                client: client,
                journal: RecoveryJournal(
                    url: directory.appendingPathComponent("pending.json"), socket: "/fixture"),
                itemsOnly: true)
        }
    }
    private func frame(_ app: TerminalApplication, width: Int = 132) -> [ScreenLine] {
        app.render(columns: width, rows: 30)
    }
    private func browse(_ name: String, in app: TerminalApplication) {
        app.handle(.text("c"))
        app.handle(.paste(name))
        app.handle(.enter)
    }
    private func click(_ app: TerminalApplication, hit: MouseHit, row: Int? = nil) {
        let x = hit.columns.lowerBound
        let actualRow = row ?? frame(app).firstIndex(where: { $0.hits.contains(hit) }) ?? 0
        app.handleMouse(.init(kind: .press, button: .left, column: x, row: actualRow, modifiers: []), at: 1)
        app.handleMouse(
            .init(kind: .release, button: .left, column: x, row: actualRow, modifiers: []), at: 1.01)
    }

    func testClickingAncestorsDropsLaterCategoriesAndRootRestoresNativeResults() throws {
        let f = try Fixture()
        let root = try f.category("Item")
        let family = try f.category("Family", rule: "family == 1", parent: root)
        _ = try f.category("Dad", rule: "dad == 1", parent: family)
        _ = try f.item("Family only", ["family": .integer(1)])
        _ = try f.item("Dad task", ["dad": .integer(1)])
        _ = try f.item("Unrelated")
        let before = f.store.state
        let app = try f.app()
        browse("Dad", in: app)
        var displayed = frame(app)
        XCTAssertTrue(displayed.map(\.text).joined().contains("Item ▾ / Family ▾ / Dad"))
        XCTAssertFalse(displayed.map(\.text).joined().contains("Family only"))
        click(
            app,
            hit: try XCTUnwrap(
                displayed.flatMap(\.hits).first {
                    if case .categoryBreadcrumb(1, _) = $0.target { true } else { false }
                }))
        displayed = frame(app)
        XCTAssertTrue(displayed.map(\.text).joined().contains("Item ▾ / Family ▾"))
        XCTAssertTrue(displayed.map(\.text).joined().contains("Family only"))
        XCTAssertTrue(displayed.map(\.text).joined().contains("Dad task"))
        click(
            app,
            hit: try XCTUnwrap(
                displayed.flatMap(\.hits).first {
                    if case .categoryBreadcrumb(0, _) = $0.target { true } else { false }
                }))
        XCTAssertTrue(frame(app).map(\.text).joined().contains("Item ▾"))
        XCTAssertTrue(frame(app).map(\.text).joined().contains("Unrelated"))
        XCTAssertEqual(f.store.state, before)
    }

    func testPrefixNavigationClearsExtraFiltersAndSavedViewTargetButRetainsLayout() throws {
        let f = try Fixture()
        let root = try f.category("Item")
        let parent = try f.category("Parent", parent: root)
        let child = try f.category("Child", parent: parent)
        let workspace = Workspace(client: f.client)
        try workspace.browse(path: [root, parent, child])
        workspace.expression = "subject == \"Child\""
        workspace.text = "Child"
        workspace.sectionCategories = [child]
        workspace.collapsedSectionIDs = [child.itemID]
        workspace.columns = [try ViewColumn(property: "subject", title: "Name", width: 32)]
        workspace.sort = [try ItemSort(property: "subject", isAscending: false)]
        let saved = try f.client.commit(workspace.viewRequest(name: "Narrow saved view")).revision
        try workspace.openView(saved)
        let before = f.store.state
        try workspace.browse(toCategoryAt: 1, expectedPath: [root.itemID, parent.itemID, child.itemID])
        XCTAssertEqual(workspace.categoryPath.map(\.itemID), [root.itemID, parent.itemID])
        XCTAssertTrue(workspace.expression.isEmpty && workspace.text.isEmpty)
        XCTAssertTrue(workspace.sectionCategories.isEmpty && workspace.collapsedSectionIDs.isEmpty)
        XCTAssertNil(workspace.view)
        XCTAssertNil(workspace.viewToUpdate)
        XCTAssertEqual(workspace.columns.first?.title, "Name")
        XCTAssertEqual(workspace.sort.first?.isAscending, false)
        XCTAssertEqual(f.store.state, before)
        XCTAssertEqual(try f.store.get(saved.itemID), saved)
    }

    func testUnicodeAndSlashNamesHaveSeparateCellBasedTargetsAndOverflowChooser() throws {
        let f = try Fixture()
        let root = try f.category("Item")
        let parent = try f.category("Famille / 家族 👩🏽‍💻", parent: root)
        let namesake = try f.category("Famille / 家族 👩🏽‍💻", parent: parent)
        let leaf = try f.category(
            "A very long leaf category whose name cannot fit on a narrow terminal", parent: namesake)
        let path = [root, parent, namesake, leaf]
        for width in [1, 20, 47, 79, 131] {
            let line = Breadcrumbs.line(path: path, width: width)
            XCTAssertEqual(line.text.reduce(0) { $0 + TerminalText.width($1) }, width)
            XCTAssertTrue(
                line.hits.allSatisfy { $0.columns.lowerBound >= 0 && $0.columns.upperBound <= width })
        }
        let wide = Breadcrumbs.line(path: Array(path.prefix(3)), width: 131)
        let links = wide.hits.filter { if case .breadcrumb = $0.target { true } else { false } }
        XCTAssertEqual(links.count, 3, "Literal slashes and duplicate names are labels, not path delimiters")
        let prefix = " Item / Famille / 家族 👩🏽‍💻 / "
        XCTAssertEqual(links[2].columns.lowerBound, prefix.reduce(0) { $0 + TerminalText.width($1) })
        let app = try f.app()
        browse("A very long leaf category", in: app)
        let narrow = frame(app, width: 48)
        click(
            app,
            hit: try XCTUnwrap(
                narrow.flatMap(\.hits).first {
                    if case .categoryBreadcrumbChooser = $0.target { true } else { false }
                }),
            row: try XCTUnwrap(
                narrow.firstIndex { line in
                    line.hits.contains {
                        if case .categoryBreadcrumbChooser = $0.target { true } else { false }
                    }
                }))
        XCTAssertTrue(frame(app, width: 48).map(\.text).joined().contains("Category path"))
        app.handle(.down)
        app.handle(.down)
        app.handle(.enter)
        let selected = try XCTUnwrap(
            frame(app).first { line in
                line.hits.contains { if case .categoryBreadcrumb = $0.target { true } else { false } }
            })
        XCTAssertFalse(selected.text.contains("A very long leaf"))
        XCTAssertEqual(
            selected.hits.filter { if case .categoryBreadcrumb = $0.target { true } else { false } }.count, 3)
        XCTAssertTrue(selected.text.contains("Famille / 家族 👩🏽‍💻 ▾ / Famille / 家族 👩🏽‍💻"))
    }

    func testRenamedCategoriesResolveByIDAndStalePathsOrUnavailablePrefixesFailSafely() throws {
        let f = try Fixture()
        let root = try f.category("Item")
        let parent = try f.category("Old name", parent: root)
        let child = try f.category("Child", parent: parent)
        var denied = false
        let client = ItemClient(transport: { data in
            let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let call = (envelope["methodCalls"] as! [[Any]])[0]
            if denied, call[0] as? String == "TractandaItem/get",
                (call[1] as? [String: Any])?["ids"] as? [String] == [parent.itemID]
            {
                throw TractandaError("notFound", "Category is unavailable")
            }
            return f.service.handle(data, peerUID: f.store.ownerUID)
        })
        let workspace = Workspace(client: client)
        let ids = [root.itemID, parent.itemID, child.itemID]
        try workspace.browse(path: [root, parent, child])
        _ = try f.client.commit(
            CommitRequest(
                action: .revise, itemID: parent.itemID, expectedRevisionID: parent.revisionID,
                changes: ["subject": .text("Renamed")], operationID: Identifier.make()))
        try workspace.browse(toCategoryAt: 1, expectedPath: ids)
        XCTAssertEqual(workspace.categoryPath.last?.fields["subject"], .text("Renamed"))
        XCTAssertThrowsError(try workspace.browse(toCategoryAt: 0, expectedPath: ids)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "stateChanged")
        }
        denied = true
        XCTAssertThrowsError(
            try workspace.browse(toCategoryAt: 1, expectedPath: [root.itemID, parent.itemID]))
        XCTAssertTrue(
            workspace.items.isEmpty, "Do not retain a stale result page after the navigation read fails")
        XCTAssertEqual(workspace.categoryPath.count, 2)
    }

    func testAllItemsLabelClearsFiltersAndMenusDoNotExposeUnderlyingBreadcrumbHits() throws {
        let f = try Fixture()
        _ = try f.item("First")
        _ = try f.item("Second")
        let app = try f.app()
        app.handle(.text("f"))
        app.handle(.paste("subject == \"First\""))
        app.handle(.control(19))
        var displayed = frame(app)
        XCTAssertFalse(displayed.map(\.text).joined().contains("Second"))
        click(app, hit: try XCTUnwrap(displayed[1].hits.first))
        XCTAssertTrue(frame(app).map(\.text).joined().contains("Second"))
        let root = try f.category("Item")
        _ = try f.category("Child", parent: root)
        browse("Child", in: app)
        app.handle(.function(10))
        displayed = frame(app)
        XCTAssertFalse(
            displayed.flatMap(\.hits).contains { if case .breadcrumb = $0.target { true } else { false } })
        app.handle(.escape)
        XCTAssertTrue(frame(app).map(\.text).joined().contains("Item ▾ / Child"))
    }
}
