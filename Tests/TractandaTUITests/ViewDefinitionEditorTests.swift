import TractandaCore
import XCTest

@testable import TractandaTUI

final class ViewDefinitionEditorTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let store: ItemStore
        let client: ItemClient

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "trac-view-form-" + Identifier.make())
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = try ItemStore(root: root.appendingPathComponent("store"))
            let service = ItemService(store: store)
            let ownerUID = store.ownerUID
            client = ItemClient(transport: { service.handle($0, peerUID: ownerUID) })
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func item(_ fields: [String: ItemValue]) throws -> Revision {
            try client.commit(
                CommitRequest(classID: "NoteItem", changes: fields, operationID: Identifier.make())
            ).revision
        }

        func category(_ name: String) throws -> Revision {
            try item([
                "subject": .text(name),
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
                ]),
            ])
        }

        func app() throws -> TerminalApplication {
            try TerminalApplication(
                client: client,
                journal: RecoveryJournal(url: root.appendingPathComponent("pending.json"), socket: "/fixture")
            )
        }
    }

    private func screen(_ app: TerminalApplication, _ size: (Int, Int) = (132, 35)) -> String {
        app.render(columns: size.0, rows: size.1).map(\.text).joined(separator: "\n")
    }

    private func newView(_ app: TerminalApplication) {
        app.handle(.modified(.text("n"), .command))
        XCTAssertTrue(screen(app).contains("View definition"))
    }

    private func tab(_ app: TerminalApplication, _ count: Int = 1) {
        for _ in 0..<count { app.handle(.tab) }
    }

    func testDirectFormStagesFieldsCriteriaColumnsAndOneGuardedSave() throws {
        let fixture = try Fixture()
        let included = try fixture.category("Included")
        let section = try fixture.category("Section")
        let app = try fixture.app()
        newView(app)
        app.handle(.paste("Project focus"))
        tab(app)
        app.handle(.paste("A multiline\ndescription"))
        tab(app)
        app.handle(.paste("subject == *"))
        tab(app)
        app.handle(.paste("focus"))
        tab(app)
        app.handle(.enter)
        app.handle(.paste("Included"))
        app.handle(.enter)
        app.handle(.control(19))
        tab(app, 2)
        app.handle(.enter)
        app.handle(.paste("Section"))
        app.handle(.enter)
        app.handle(.control(19))
        tab(app)
        app.handle(.paste("subject"))
        tab(app)
        app.handle(.right)
        tab(app, 3)
        app.handle(.control(21))
        app.handle(.paste("rank"))
        tab(app)
        app.handle(.control(21))
        app.handle(.paste("Rank"))
        tab(app)
        app.handle(.control(21))
        app.handle(.paste("36"))
        XCTAssertEqual(try fixture.client.revisions(matching: "viewDefinition == *").count, 0)
        app.handle(.function(8))
        let saved = try XCTUnwrap(fixture.client.revisions(matching: "subject == \"Project focus\"").first)
        XCTAssertEqual(try fixture.store.history(saved.itemID).count, 1)
        let definition = try SavedViewDefinition(XCTUnwrap(saved.fields["viewDefinition"]))
        XCTAssertEqual(definition.categoryPath, [included.itemID])
        XCTAssertEqual(definition.presentation.sectionIDs, [section.itemID])
        XCTAssertEqual(definition.expression, "subject == *")
        XCTAssertEqual(definition.text, "focus")
        XCTAssertEqual(definition.presentation.columns.first?.property, "rank")
        XCTAssertEqual(definition.presentation.columns.first?.width, 36)
        XCTAssertEqual(definition.sort, [try ItemSort(property: "subject", isAscending: false)])
    }

    func testModalPreservesBackgroundMouseFocusCompactScrollAndCancel() throws {
        let fixture = try Fixture()
        _ = try fixture.item(["subject": .text("Background report")])
        let app = try fixture.app()
        let before = screen(app)
        newView(app)
        app.handle(.function(1))
        XCTAssertTrue(screen(app).contains("Tractanda help"))
        app.handle(.escape)
        XCTAssertTrue(screen(app).contains("View definition"))
        XCTAssertTrue(screen(app, (47, 11)).contains("Enlarge terminal"))
        let normal = app.render(columns: 80, rows: 25)
        XCTAssertTrue(normal.contains { $0.text.contains("Tractanda") })
        let hitLine = try XCTUnwrap(
            normal.enumerated().first { _, line in
                line.hits.contains { $0.target == .viewDefinitionControl(0) }
            })
        let hit = try XCTUnwrap(hitLine.element.hits.first { $0.target == .viewDefinitionControl(0) })
        app.handle(
            .mouse(
                TerminalMouseEvent(
                    kind: .press, button: .left, column: hit.columns.lowerBound, row: hitLine.offset,
                    modifiers: [])))
        app.handle(
            .mouse(
                TerminalMouseEvent(
                    kind: .release, button: .left, column: hit.columns.lowerBound, row: hitLine.offset,
                    modifiers: [])))
        app.handle(.paste("Transient"))
        for _ in 0..<12 { app.handle(.tab) }
        XCTAssertTrue(screen(app, (48, 12)).contains("F8 Save"))
        app.handle(.escape)
        XCTAssertTrue(screen(app).contains("View definition canceled; prior report restored."))
        XCTAssertTrue(before.contains("Background report"))
        XCTAssertEqual(try fixture.client.revisions(matching: "viewDefinition == *").count, 0)
    }

    func testConflictRetainsDirectDraftAndUnknownFields() throws {
        let fixture = try Fixture()
        let original = try fixture.item([
            "subject": .text("Shared"),
            "viewDefinition": .object([
                "language": .text(SpotlightQuery.profile), "foreign.query": .text("keep"),
                "presentation": .object([
                    "profile": .text(ViewPresentation.profile), "foreign.layout": .text("keep"),
                ]),
            ]),
        ])
        let app = try fixture.app()
        app.handle(.down)
        app.handle(.modified(.text("e"), .command))
        app.handle(.control(21))
        app.handle(.paste("Local name"))
        _ = try fixture.client.commit(
            CommitRequest(
                action: .revise, itemID: original.itemID, expectedRevisionID: original.revisionID,
                changes: ["subject": .text("Elsewhere")], operationID: Identifier.make()))
        app.handle(.function(8))
        XCTAssertTrue(screen(app).contains("revisionConflict"))
        XCTAssertTrue(screen(app).contains("Local name"))
        app.handle(.escape)
        XCTAssertEqual(try fixture.store.history(original.itemID).count, 2)
    }

    func testCompactReportHidesPreviewAndRestoresItWhenEnlarged() throws {
        let fixture = try Fixture()
        _ = try fixture.item(["subject": .text("Short report"), "body": .text("Visible preview body")])
        let app = try fixture.app()
        app.handle(.function(8))
        let lines = screen(app, (60, 16))
        XCTAssertTrue(lines.contains("Views ·"))
        XCTAssertTrue(lines.contains("Short report"))
        XCTAssertFalse(lines.contains("Visible preview body"))
        XCTAssertTrue(screen(app, (80, 25)).contains("Visible preview body"))
    }

    func testSelectorMouseClickLoadsTheClickedView() throws {
        let fixture = try Fixture()
        _ = try fixture.item([
            "subject": .text("Legacy"),
            "viewDefinition": .object(["language": .text(SpotlightQuery.profile)]),
        ])
        let role = try fixture.item([
            "subject": .text("Role"), "viewDefinition": .object(["language": .text(SpotlightQuery.profile)]),
        ])
        let app = try fixture.app()
        let frame = app.render(columns: 100, rows: 30)
        let clicked = try XCTUnwrap(
            frame.enumerated().first { _, line in
                line.hits.contains {
                    if case .viewWorkspaceRow(_, let key) = $0.target { return key.hasPrefix(role.itemID) }
                    return false
                }
            })
        let hit = try XCTUnwrap(
            clicked.element.hits.first {
                if case .viewWorkspaceRow(_, let key) = $0.target { return key.hasPrefix(role.itemID) }
                return false
            })
        let press = TerminalMouseEvent(
            kind: .press, button: .left, column: hit.columns.lowerBound + 1, row: clicked.offset,
            modifiers: [])
        app.handle(.mouse(press))
        app.handle(
            .mouse(
                TerminalMouseEvent(
                    kind: .release, button: .none, column: press.column, row: press.row, modifiers: [])))
        XCTAssertTrue(screen(app).contains("selected: Role"))
        XCTAssertTrue(screen(app).contains("Opened Role"))
    }

    func testEmptyViewKeepsSelectorRowsAndAllItemsMouseHit() throws {
        let fixture = try Fixture()
        let empty = try fixture.item([
            "subject": .text("Empty view"),
            "viewDefinition": .object([
                "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
            ]),
        ])
        let app = try fixture.app()
        app.handle(.down)
        for size in [(80, 25), (132, 35)] {
            let frame = app.render(columns: size.0, rows: size.1)
            XCTAssertTrue(frame.contains { $0.text.contains("No items.") })
            XCTAssertTrue(frame.flatMap(\.hits).contains { $0.target == .viewWorkspaceAllItems })
            XCTAssertTrue(
                frame.flatMap(\.hits).contains {
                    if case .viewWorkspaceRow(_, let key) = $0.target { return key.hasPrefix(empty.itemID) }
                    return false
                })
        }
    }

    func testCompactSplitKeepsReportRowsVisibleForEitherPaneFocus() throws {
        let fixture = try Fixture()
        _ = try fixture.item(["subject": .text("Split visible item")])
        let app = try fixture.app()
        for _ in 0..<2 {
            let frame = app.render(columns: 48, rows: 12)
            XCTAssertTrue(frame.contains { $0.text.contains("Split visible item") })
            XCTAssertTrue(frame.contains { $0.text.contains("Views ·") })
            app.handle(.tab)
        }
    }

    func testSelectingCataloguedViewRereadsDefinitionAndClearsStaleReportOnFailure() throws {
        let fixture = try Fixture()
        let view = try fixture.item([
            "subject": .text("Revoked definition"),
            "viewDefinition": .object(["language": .text(SpotlightQuery.profile)]),
        ])
        let app = try fixture.app()
        _ = try fixture.client.commit(
            CommitRequest(
                action: .revise, itemID: view.itemID, expectedRevisionID: view.revisionID,
                unset: ["viewDefinition"], operationID: Identifier.make()))
        app.handle(.down)
        XCTAssertTrue(screen(app).contains("notView"))
        XCTAssertTrue(screen(app).contains("0 items"))
    }

    func testSavedViewIsImmediatelyCataloguedAndEditUsesCurrentHead() throws {
        let fixture = try Fixture()
        let app = try fixture.app()
        newView(app)
        app.handle(.paste("Immediate view"))
        app.handle(.tab)
        app.handle(.paste("description"))
        app.handle(.function(8))
        XCTAssertTrue(screen(app).contains("Immediate view"))
        app.handle(.text("Immediate"))
        app.handle(.function(2))
        XCTAssertTrue(screen(app).contains("View definition · Immediate view"))
        app.handle(.escape)
        let saved = try XCTUnwrap(fixture.client.revisions(matching: "subject == \"Immediate view\"").first)
        _ = try fixture.client.commit(
            CommitRequest(
                action: .revise, itemID: saved.itemID, expectedRevisionID: saved.revisionID,
                changes: ["subject": .text("Fresh head")], operationID: Identifier.make()))
        app.handle(.function(2))
        XCTAssertTrue(screen(app).contains("View definition · Fresh head"))
    }

    func testExplicitRefreshReloadsRenamedViewIntoTheSameSelectorFilter() throws {
        let fixture = try Fixture()
        let view = try fixture.item([
            "subject": .text("Old name"),
            "viewDefinition": .object(["language": .text(SpotlightQuery.profile)]),
        ])
        let app = try fixture.app()
        app.handle(.down)
        app.handle(.enter)
        _ = try fixture.client.commit(
            CommitRequest(
                action: .revise, itemID: view.itemID, expectedRevisionID: view.revisionID,
                changes: ["subject": .text("New name")], operationID: Identifier.make()))
        app.handle(.text("r"))
        app.handle(.tab)
        app.handle(.text("New name"))
        XCTAssertTrue(screen(app).contains("New name"))
        XCTAssertFalse(screen(app).contains("No saved views"))
    }

    func testHelpAndUndersizeTemporarilyCoverButDoNotDiscardDirectDraft() throws {
        let fixture = try Fixture()
        let app = try fixture.app()
        newView(app)
        app.handle(.paste("Kept through help"))
        app.handle(.function(1))
        XCTAssertTrue(screen(app).contains("Tractanda help"))
        app.handle(.escape)
        XCTAssertTrue(screen(app).contains("Kept through help"))
        XCTAssertTrue(screen(app, (47, 11)).contains("Enlarge terminal"))
        XCTAssertTrue(screen(app, (80, 25)).contains("Kept through help"))
        app.handle(.escape)
        XCTAssertEqual(try fixture.client.revisions(matching: "viewDefinition == *").count, 0)
    }

    func testSaveAsCreatesNewIdentityWithoutRevisingOriginal() throws {
        let fixture = try Fixture()
        let original = try fixture.item([
            "subject": .text("Original view"),
            "viewDefinition": .object(["language": .text(SpotlightQuery.profile)]),
        ])
        let app = try fixture.app()
        app.handle(.down)
        app.handle(.modified(.text("e"), .command))
        app.handle(.control(21))
        app.handle(.paste("Copied view"))
        XCTAssertTrue(
            app.render(columns: 80, rows: 25).last?.hits.contains { $0.target == .function(3) } == true)
        app.handle(.function(3))
        let copied = try XCTUnwrap(fixture.client.revisions(matching: "subject == \"Copied view\"").first)
        XCTAssertNotEqual(copied.itemID, original.itemID)
        XCTAssertEqual(try fixture.store.history(original.itemID).count, 1)
        XCTAssertEqual(try fixture.store.history(copied.itemID).count, 1)
    }

    func testContextualFunctionKeysReorderAnInlineColumnWithoutLosingItsEdit() throws {
        let fixture = try Fixture()
        let app = try fixture.app()
        newView(app)
        app.handle(.paste("Ordered columns"))
        app.handle(.modified(.function(5), .option))  // Add a third column, which receives direct focus.
        app.handle(.paste("rank"))
        app.handle(.tab)
        app.handle(.control(21))
        app.handle(.paste("Rank"))
        app.handle(.tab)
        app.handle(.control(21))
        app.handle(.paste("18"))
        app.handle(.modified(.function(7), .option))  // Earlier: third -> second.
        app.handle(.function(8))
        let saved = try XCTUnwrap(fixture.client.revisions(matching: "subject == \"Ordered columns\"").first)
        let definition = try SavedViewDefinition(XCTUnwrap(saved.fields["viewDefinition"]))
        XCTAssertEqual(definition.presentation.columns.map(\.property), ["subject", "rank", "classID"])
        XCTAssertEqual(definition.presentation.columns[1].title, "Rank")
        XCTAssertEqual(definition.presentation.columns[1].width, 18)
    }

    func testCancelReleasesDraftWhenOriginalSavedViewDisappears() throws {
        let fixture = try Fixture()
        let original = try fixture.item([
            "subject": .text("Deleted while editing"),
            "viewDefinition": .object(["language": .text(SpotlightQuery.profile)]),
        ])
        let app = try fixture.app()
        app.handle(.down)
        app.handle(.modified(.text("e"), .command))
        app.handle(.paste(" local"))
        _ = try fixture.client.commit(
            CommitRequest(
                action: .revise, itemID: original.itemID, expectedRevisionID: original.revisionID,
                changes: ["isDeleted": .boolean(true)], operationID: Identifier.make()))
        app.handle(.escape)
        XCTAssertTrue(screen(app).contains("prior report is unavailable"))
        XCTAssertFalse(screen(app).contains("View definition ·"))
    }
}
