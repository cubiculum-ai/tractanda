import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaTUI

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ChildCategoryTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trac-child-menu-" + Identifier.make())
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
        func category(_ name: String, parents: [Revision] = [], order: Int64 = 0) throws -> Revision {
            try client.commit(
                CommitRequest(
                    classID: "NoteItem",
                    changes: [
                        "subject": .text(name),
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                        ]),
                        "categoryParents": .list(parents.map { .reference(ItemReference($0.itemID)) }),
                        "categoryOrder": .integer(order),
                    ], operationID: Identifier.make())
            ).revision
        }
        func app() throws -> TerminalApplication {
            try TerminalApplication(
                client: client,
                journal: RecoveryJournal(
                    url: root.appendingPathComponent("pending.json"), socket: "/fixture"), itemsOnly: true
            )
        }
    }
    private func frame(_ app: TerminalApplication, width: Int = 132, height: Int = 30) -> [ScreenLine] {
        app.render(columns: width, rows: height)
    }
    private func point(_ frame: [ScreenLine], _ matching: (MouseTarget) -> Bool) throws -> (Int, Int) {
        for (row, line) in frame.enumerated() {
            if let hit = line.hits.last(where: { matching($0.target) }) {
                return (hit.columns.lowerBound, row)
            }
        }
        throw TractandaError("test", "No matching hit region")
    }
    private func click(_ app: TerminalApplication, _ point: (Int, Int)) {
        app.handleMouse(
            .init(kind: .press, button: .left, column: point.0, row: point.1, modifiers: []), at: 1)
        app.handleMouse(
            .init(kind: .release, button: .left, column: point.0, row: point.1, modifiers: []), at: 1.01)
    }
    private func open(_ name: String, in app: TerminalApplication) {
        app.handle(.text("c"))
        app.handle(.paste(name))
        app.handle(.enter)
    }

    func testAllItemsLoadsOnePageAndDefersCategoryDiscovery() throws {
        let f = try Fixture()
        _ = try f.category("Root")
        for index in 0..<70 {
            _ = try f.client.commit(
                CommitRequest(
                    classID: "NoteItem", changes: ["subject": .text("Item \(index)")],
                    operationID: Identifier.make()))
        }
        var calls: [(String, [String: Any])] = []
        let client = ItemClient(transport: { data in
            let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            for call in request["methodCalls"] as! [[Any]] {
                calls.append((call[0] as! String, call[1] as! [String: Any]))
            }
            return f.service.handle(data, peerUID: f.store.ownerUID)
        })
        let workspace = Workspace(client: client)
        try workspace.refresh()
        let result = try Categories.query(store: f.store)
        let expected = result.map(\.itemID)
        let dates = try result.map { item -> Date in
            guard case .date(let timestamp) = item.fields["modifiedAt"] else {
                throw TractandaError("test", "Missing modification timestamp")
            }
            return try XCTUnwrap(Timestamp.parse(timestamp))
        }
        XCTAssertEqual(dates, dates.sorted(by: >), "Default ordering is most recently modified first")
        XCTAssertEqual(workspace.total, 71)
        XCTAssertEqual(workspace.items.map(\.itemID), Array(expected.prefix(64)))
        XCTAssertNil(workspace.categoryNavigation)
        XCTAssertEqual(calls.filter { $0.0 == "TractandaItem/query" }.count, 1)
        XCTAssertFalse(calls.contains { $0.1["expression"] as? String == "selection == *" })
        XCTAssertEqual(
            calls.first { $0.0 == "TractandaItem/get" }?.1["ids"] as? [String], Array(expected.prefix(64)))
        try workspace.loadPage(in: 0, forward: true)
        XCTAssertEqual(workspace.items.map(\.itemID), Array(expected.dropFirst(64)))
        XCTAssertEqual(workspace.sections[0].position, 64)
        XCTAssertFalse(calls.contains { $0.1["expression"] as? String == "selection == *" })
        XCTAssertEqual(try workspace.childCategories(at: nil, expectedPath: []).count, 1)
        XCTAssertTrue(calls.contains { $0.1["expression"] as? String == "selection == *" })
    }

    func testAllItemsDropdownOpensOnlyRootsAndThenTheirChildren() throws {
        let f = try Fixture()
        let later = try f.category("A later", order: 10)
        let first = try f.category("Z first 家族", order: -1)
        let child = try f.category("Immediate child", parents: [first])
        let app = try f.app()
        let before = f.store.state
        let displayed = frame(app)
        XCTAssertEqual(displayed[1].text.trimmingCharacters(in: .whitespaces), "All items ▾")
        click(app, try point(displayed) { if case .breadcrumbChildren(nil, []) = $0 { true } else { false } })
        let popup = frame(app)
        XCTAssertTrue(popup[2].text.contains("Top-level─categories"))
        XCTAssertEqual(
            popup.flatMap(\.hits).compactMap {
                if case .childCategory(_, let id) = $0.target { id } else { nil }
            }, [first.itemID, later.itemID])
        for (width, height) in [(48, 12), (80, 25), (132, 30)] {
            let resized = frame(app, width: width, height: height)
            XCTAssertTrue(resized[2].text.contains("Top-level─categories"))
        }
        let target = try point(frame(app)) {
            if case .childCategory(_, let id) = $0 { id == first.itemID } else { false }
        }
        app.handleMouse(.init(kind: .hover, button: .none, column: target.0, row: target.1, modifiers: []))
        click(app, target)
        XCTAssertTrue(frame(app).map(\.text).joined().contains("Z first 家族"))
        app.handle(.modified(.down, .command))
        XCTAssertEqual(
            frame(app).flatMap(\.hits).compactMap {
                if case .childCategory(_, let id) = $0.target { id } else { nil }
            }, [child.itemID])
        app.handle(.enter)
        XCTAssertTrue(frame(app).map(\.text).joined().contains("Z first 家族 ▾ / Immediate child"))
        app.handle(.escape)
        _ = frame(app)
        app.handle(.modified(.down, .option))
        app.handle(.end)
        app.handle(.enter)
        XCTAssertTrue(frame(app).map(\.text).joined().contains("A later"))
        XCTAssertEqual(f.store.state, before)
    }

    func testRootSelectionRechecksParentsAndRejectsStalePath() throws {
        let f = try Fixture()
        let root = try f.category("Root")
        let moved = try f.category("Moving root")
        let workspace = Workspace(client: f.client)
        try workspace.refresh()
        XCTAssertEqual(try workspace.childCategories(at: nil, expectedPath: []).count, 2)
        _ = try f.client.commit(
            CommitRequest(
                action: .revise, itemID: moved.itemID, expectedRevisionID: moved.revisionID,
                changes: ["categoryParents": .list([.reference(ItemReference(root.itemID))])],
                operationID: Identifier.make()))
        XCTAssertThrowsError(try workspace.browse(childID: moved.itemID, at: nil, expectedPath: []))
        XCTAssertTrue(workspace.items.isEmpty && workspace.categoryPath.isEmpty)
        workspace.columns = [try ViewColumn(property: "subject", title: "Name", width: 28)]
        workspace.sort = [try ItemSort(property: "modifiedAt", isAscending: false)]
        workspace.expression = "subject == \"nothing\""
        try workspace.browse(childID: root.itemID, at: nil, expectedPath: [])
        XCTAssertEqual(workspace.categoryPath.map(\.itemID), [root.itemID])
        XCTAssertTrue(workspace.expression.isEmpty)
        XCTAssertEqual(workspace.columns.first?.title, "Name")
        XCTAssertEqual(workspace.sort.first?.property, "modifiedAt")
        XCTAssertThrowsError(try workspace.childCategories(at: nil, expectedPath: []))
        XCTAssertThrowsError(try workspace.childCategories(at: nil, expectedPath: [root.itemID]))
    }

    func testRootMenuHandlesEmptyStoreAndLateCategoryCreation() throws {
        let f = try Fixture()
        let app = try f.app()
        click(
            app, try point(frame(app)) { if case .breadcrumbChildren(nil, []) = $0 { true } else { false } })
        XCTAssertTrue(frame(app).contains { $0.text.contains("No readable categories are available") })
        _ = try f.category("Added later")
        let before = f.store.state
        app.handle(.modified(.down, .command))
        XCTAssertTrue(frame(app)[2].text.contains("Top-level─categories"))
        app.handle(.escape)
        XCTAssertEqual(frame(app)[1].text.trimmingCharacters(in: .whitespaces), "All items ▾")
        app.handle(.modified(.down, .option))
        app.handle(.enter)
        XCTAssertEqual(frame(app)[1].text.trimmingCharacters(in: .whitespaces), "Added later")
        XCTAssertEqual(f.store.state, before)
    }

    func testOnlyImmediateChildrenAreListedInCategoryOrder() throws {
        let f = try Fixture()
        let parent = try f.category("Parent")
        let later = try f.category("A later", parents: [parent], order: 10)
        let first = try f.category("Z first", parents: [parent], order: -1)
        _ = try f.category("Grandchild", parents: [first])
        _ = try f.category("Independent category matching the same rule")
        let workspace = Workspace(client: f.client)
        try workspace.browse(path: [parent])
        let before = f.store.state
        XCTAssertEqual(
            try workspace.childCategories(at: 0, expectedPath: [parent.itemID]).map(\.itemID),
            [first.itemID, later.itemID])
        XCTAssertTrue(workspace.categoriesWithChildren.contains(parent.itemID))
        XCTAssertFalse(workspace.categoriesWithChildren.contains(later.itemID))
        XCTAssertEqual(f.store.state, before)
    }

    func testChoosingSiblingReplacesLaterBranchClearsFiltersAndKeepsLayout() throws {
        let f = try Fixture()
        let root = try f.category("Item")
        let parent = try f.category("Parent", parents: [root])
        let a = try f.category("A", parents: [parent])
        let deep = try f.category("Deep", parents: [a])
        let b = try f.category("B", parents: [parent])
        let workspace = Workspace(client: f.client)
        try workspace.browse(path: [root, parent, a, deep])
        workspace.expression = "subject == \"Deep\""
        workspace.text = "Deep"
        workspace.sectionCategories = [a]
        workspace.collapsedSectionIDs = [a.itemID]
        workspace.columns = [try ViewColumn(property: "subject", title: "Name", width: 28)]
        workspace.sort = [try ItemSort(property: "subject", isAscending: false)]
        let saved = try f.client.commit(workspace.viewRequest(name: "Saved branch")).revision
        try workspace.openView(saved)
        let before = f.store.state
        try workspace.browse(childID: b.itemID, at: 1, expectedPath: [root, parent, a, deep].map(\.itemID))
        XCTAssertEqual(workspace.categoryPath.map(\.itemID), [root, parent, b].map(\.itemID))
        XCTAssertTrue(
            workspace.expression.isEmpty && workspace.text.isEmpty && workspace.sectionCategories.isEmpty)
        XCTAssertNil(workspace.viewToUpdate)
        XCTAssertEqual(workspace.columns.first?.title, "Name")
        XCTAssertEqual(workspace.sort.first?.isAscending, false)
        XCTAssertEqual(try f.store.get(saved.itemID), saved)
        XCTAssertEqual(f.store.state, before)
    }

    func testSharedChildKeepsTheChosenParentAndRejectsAReparentedSelection() throws {
        let f = try Fixture()
        let a = try f.category("A")
        let b = try f.category("B")
        let shared = try f.category("Shared", parents: [a, b])
        let workspace = Workspace(client: f.client)
        try workspace.browse(path: [b])
        try workspace.browse(childID: shared.itemID, at: 0, expectedPath: [b.itemID])
        XCTAssertEqual(workspace.categoryPath.map(\.itemID), [b.itemID, shared.itemID])
        try workspace.browse(path: [a])
        XCTAssertEqual(try workspace.childCategories(at: 0, expectedPath: [a.itemID]).count, 1)
        _ = try f.client.commit(
            CommitRequest(
                action: .revise, itemID: shared.itemID, expectedRevisionID: shared.revisionID,
                changes: ["categoryParents": .list([.reference(ItemReference(b.itemID))])],
                operationID: Identifier.make()))
        XCTAssertThrowsError(try workspace.browse(childID: shared.itemID, at: 0, expectedPath: [a.itemID]))
        XCTAssertEqual(workspace.categoryPath.map(\.itemID), [a.itemID])
        XCTAssertTrue(workspace.items.isEmpty)
    }

    func testBreadcrumbButtonsDropdownHoverAndSingleClickNavigateWithoutWrites() throws {
        let f = try Fixture()
        let root = try f.category("Item")
        let parent = try f.category("Family / 家族", parents: [root])
        let a = try f.category("A", parents: [parent])
        let b = try f.category("B", parents: [parent])
        let grandchild = try f.category("Deep unique", parents: [a])
        let app = try f.app()
        open("Deep unique", in: app)
        let before = f.store.state
        let displayed = frame(app)
        XCTAssertEqual(
            displayed.flatMap(\.hits).filter {
                if case .categoryBreadcrumbChildren = $0.target { true } else { false }
            }
            .count, 3)
        click(
            app,
            try point(displayed) { if case .categoryBreadcrumbChildren(1, _) = $0 { true } else { false } })
        let popup = frame(app)
        XCTAssertTrue(popup[2].text.contains("Children─of─Family"))
        let childIDs = popup.flatMap(\.hits).compactMap {
            if case .childCategory(_, let id) = $0.target { id } else { nil }
        }
        XCTAssertEqual(Set(childIDs), [a.itemID, b.itemID])
        XCTAssertFalse(childIDs.contains(grandchild.itemID))
        let target = try point(popup) {
            if case .childCategory(_, let id) = $0 { id == b.itemID } else { false }
        }
        app.handleMouse(.init(kind: .hover, button: .none, column: target.0, row: target.1, modifiers: []))
        XCTAssertTrue(frame(app).contains { $0.text.contains(">  B") })
        XCTAssertEqual(f.store.state, before)
        click(app, target)
        XCTAssertTrue(frame(app).map(\.text).joined().contains("Family / 家族 ▾ / B"))
        XCTAssertFalse(frame(app)[1].text.contains("Deep unique"))
        XCTAssertEqual(f.store.state, before)
    }

    func testLongChildListsScrollResizeCancelAndHaveKeyboardAccess() throws {
        let f = try Fixture()
        let parent = try f.category("Parent unique")
        for index in 0..<18 { _ = try f.category(String(format: "Child %02d 文", index), parents: [parent]) }
        let app = try f.app()
        open("Parent unique", in: app)
        let before = f.store.state
        app.handle(.modified(.down, .command))
        for (width, height) in [(48, 12), (80, 25), (132, 40)] {
            let lines = frame(app, width: width, height: height)
            XCTAssertTrue(lines[2].text.contains("Children─of─Parent"))
            for line in lines where !line.segments.isEmpty {
                XCTAssertEqual(line.text.reduce(0) { $0 + TerminalText.width($1) }, width - 1)
            }
        }
        _ = frame(app, width: 48, height: 12)
        app.handle(.end)
        XCTAssertTrue(frame(app, width: 48, height: 12).contains { $0.text.contains("Child 17 文") })
        app.handle(.escape)
        XCTAssertTrue(frame(app).map(\.text).joined().contains("Parent unique"))
        app.handle(.modified(.down, .option))
        app.handle(.end)
        app.handle(.enter)
        XCTAssertTrue(frame(app).map(\.text).joined().contains("Parent unique ▾ / Child 17 文"))
        XCTAssertEqual(f.store.state, before)
    }

    private final class Accounts: AccountDirectory {
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name = uid == getuid() ? "admin" : uid == 51001 ? "alice" : "bob"
            return AccountIdentity(uid: uid, name: name, primaryGroupName: "team", groupIDs: [71001])
        }
        func user(named name: String) throws -> AccountIdentity {
            try user(forUID: name == "admin" ? getuid() : name == "alice" ? 51001 : 51002)
        }
        func groupID(named name: String) throws -> UInt32 { 71001 }
    }

    func testUnreadableChildrenDoNotCreateIndicatorsAndRevocationIsRechecked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trac-child-acl-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root, accounts: Accounts())
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]), operationID: Identifier.make())
        func permissions(_ mode: Int64) -> ItemValue {
            .object([
                "profile": .text(ItemPermissions.profile), "owner": .text("alice"), "group": .text("team"),
                "mode": .integer(mode), "acl": .object([:]),
            ])
        }
        func create(_ title: String, _ mode: Int64, parent: Revision? = nil) throws -> Revision {
            try store.withAccess(forUID: 51001) {
                try store.commit(
                    CommitRequest(
                        classID: "NoteItem",
                        changes: [
                            "subject": .text(title), "permissions": permissions(mode),
                            "selection": .object([
                                "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                            ]),
                            "categoryParents": .list(
                                parent.map { [.reference(ItemReference($0.itemID))] } ?? []),
                        ], operationID: Identifier.make())
                ).revision
            }
        }
        let parent = try create("Shared parent", 0o640)
        var child = try create("Private child", 0o600, parent: parent)
        let service = ItemService(store: store)
        let bob = ItemClient(transport: { service.handle($0, peerUID: 51002) })
        let workspace = Workspace(client: bob)
        try workspace.refresh()
        XCTAssertEqual(
            try workspace.childCategories(at: nil, expectedPath: []).map(\.itemID), [parent.itemID])
        try workspace.browse(path: [parent])
        XCTAssertFalse(workspace.categoriesWithChildren.contains(parent.itemID))
        XCTAssertTrue(try workspace.childCategories(at: 0, expectedPath: [parent.itemID]).isEmpty)
        child = try store.withAccess(forUID: 51001) {
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: child.itemID, expectedRevisionID: child.revisionID,
                    changes: ["permissions": permissions(0o640)], operationID: Identifier.make())
            ).revision
        }
        try workspace.refresh()
        XCTAssertTrue(workspace.categoriesWithChildren.contains(parent.itemID))
        XCTAssertEqual(
            try workspace.childCategories(at: 0, expectedPath: [parent.itemID]).map(\.itemID), [child.itemID])
        _ = try store.withAccess(forUID: 51001) {
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: child.itemID, expectedRevisionID: child.revisionID,
                    changes: ["permissions": permissions(0o600)], operationID: Identifier.make()))
        }
        XCTAssertThrowsError(
            try workspace.browse(childID: child.itemID, at: 0, expectedPath: [parent.itemID]))
        XCTAssertFalse(workspace.categoriesWithChildren.contains(parent.itemID))
        XCTAssertTrue(workspace.items.isEmpty)
        try workspace.allItems()
        XCTAssertEqual(
            try workspace.childCategories(at: nil, expectedPath: []).map(\.itemID), [parent.itemID])
        _ = try store.withAccess(forUID: 51001) {
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: parent.itemID, expectedRevisionID: parent.revisionID,
                    changes: ["permissions": permissions(0o600)], operationID: Identifier.make()))
        }
        XCTAssertThrowsError(try workspace.browse(childID: parent.itemID, at: nil, expectedPath: []))
        XCTAssertTrue(workspace.items.isEmpty)
        XCTAssertTrue(try workspace.childCategories(at: nil, expectedPath: []).isEmpty)
    }
}
