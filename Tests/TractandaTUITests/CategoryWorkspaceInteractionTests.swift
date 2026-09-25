import Foundation
import TractandaCore
import XCTest

@testable import TractandaTUI

final class CategoryWorkspaceInteractionTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        let store: ItemStore
        let service: ItemService
        let client: ItemClient
        init() throws {
            store = try ItemStore(root: root.appendingPathComponent("store"))
            service = ItemService(store: store)
            let service = service
            let uid = store.ownerUID
            client = ItemClient(transport: { service.handle($0, peerUID: uid) })
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func category(_ subject: String, body: String = "") throws -> Revision {
            try client.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text(subject), "body": .text(body),
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text("rank == *"),
                        ]),
                        "unrecognized": .object(["retain": .text("yes")]),
                    ], operationID: Identifier.make())
            ).revision
        }
        func application(itemsOnly: Bool = true, viewPreferencesURL: URL? = nil) throws -> TerminalApplication
        {
            try TerminalApplication(
                client: client,
                journal: RecoveryJournal(
                    url: root.appendingPathComponent("pending.json"), socket: "/fixture"),
                itemsOnly: itemsOnly, viewPreferencesURL: viewPreferencesURL)
        }
    }

    private func text(_ app: TerminalApplication) -> String {
        app.render(columns: 132, rows: 35).map(\.text).joined(separator: "\n")
    }

    private func openCategoryPreferences(_ app: TerminalApplication) {
        app.handle(.function(10))
        app.handle(.left)
        app.handle(.down)  // About -> Appearance.
        app.handle(.down)
        app.handle(.enter)
    }

    func testDirtySearchStayRetainsNavigatorAndDraftAndDiscardAppliesProposedSearch() throws {
        let fixture = try Fixture()
        let alpha = try fixture.category("Alpha")
        _ = try fixture.category("Beta")
        let app = try fixture.application()
        app.handle(.function(9))
        app.handle(.paste("Alpha"))
        app.handle(.function(2))
        app.handle(.paste(" unsaved"))
        app.handle(.backTab)
        let before = text(app)
        app.handle(.control(21))
        XCTAssertTrue(text(app).contains("Unsaved category draft"))
        app.handle(.enter)
        let stayed = text(app)
        XCTAssertTrue(stayed.contains("Find: Alpha"))
        XCTAssertTrue(stayed.contains("Alpha unsaved"))
        XCTAssertEqual(
            before.components(separatedBy: "\n").first { $0.contains("Find:") },
            stayed.components(separatedBy: "\n").first { $0.contains("Find:") })
        XCTAssertEqual(try fixture.store.history(alpha.itemID).count, 1)
        app.handle(.control(21))
        app.handle(.left)  // Default Stay -> Discard; Enter activates the highlighted action.
        XCTAssertTrue(
            app.render(columns: 132, rows: 35).flatMap(\.segments).contains {
                $0.style == .menuSelection && $0.text.contains("F9 Discard")
            })
        app.handle(.enter)
        XCTAssertFalse(text(app).contains("Alpha unsaved"))
        app.handle(.paste("Beta"))
        app.handle(.function(2))
        XCTAssertTrue(text(app).contains("Subject:         Beta"))
        XCTAssertEqual(try fixture.store.history(alpha.itemID).count, 1)
    }

    func testCancelReopenAndControlledClassFieldPreserveUnknownProperties() throws {
        let fixture = try Fixture()
        let alpha = try fixture.category("Alpha")
        let app = try fixture.application()
        app.handle(.function(9))
        app.handle(.paste("Alpha"))
        app.handle(.function(2))
        app.handle(.paste(" canceled"))
        app.handle(.function(9))
        app.handle(.function(2))
        app.handle(.paste(" saved"))
        app.handle(.tab)
        app.handle(.tab)  // Controlled Class field.
        app.handle(.paste("MadeUpItem"))
        XCTAssertFalse(text(app).contains("MadeUpItem"))
        app.handle(.function(8))
        let saved = try fixture.store.get(alpha.itemID)
        XCTAssertEqual(saved.fields["subject"], .text("Alpha saved"))
        XCTAssertEqual(saved.classID, "Item")
        XCTAssertEqual(saved.fields["unrecognized"], alpha.fields["unrecognized"])
        XCTAssertEqual(try fixture.store.history(alpha.itemID).count, 2)
    }

    func testInlineEmacsKeysPreserveBodyFocusForLegacyAndExtendedControlEvents() throws {
        for useExtendedEvents in [false, true] {
            let fixture = try Fixture()
            let alpha = try fixture.category("Alpha", body: "ab\ncd")
            let app = try fixture.application()
            app.handle(.function(9))
            app.handle(.paste("Alpha"))
            app.handle(.function(5))
            app.handle(.control(1))
            app.handle(useExtendedEvents ? .modified(.text("e"), .control) : .control(5))
            app.handle(.paste("!"))
            app.handle(useExtendedEvents ? .modified(.text("t"), .control) : .control(20))
            app.handle(.function(8))
            let saved = try fixture.store.get(alpha.itemID)
            XCTAssertEqual(saved.fields["body"], .text("ab\nc!d"))
            XCTAssertEqual(saved.fields["subject"], .text("Alpha"))
            XCTAssertFalse(text(app).contains("Connected tree"))
        }
    }

    func testItemsOnlyStartupRestoresCategoryLayoutWithoutErasingViewPins() throws {
        let fixture = try Fixture()
        _ = try fixture.category("Alpha")
        let preferencesURL = fixture.root.appendingPathComponent("pending.views.json")
        let pinned = [Identifier.make()]
        let preferences = ViewWorkspacePreferences(
            pinnedViewIDs: pinned, categoryConnectedTree: true, categoryRightMode: "category",
            categorySplitWidth: 0.45)
        try preferences.save(to: preferencesURL)
        let app = try fixture.application()
        app.handle(.function(9))
        XCTAssertTrue(text(app).contains("Connected tree"))
        XCTAssertTrue(text(app).contains("[Category]"))
        app.handle(.control(20))
        let saved = try ViewWorkspacePreferences.load(from: preferencesURL)
        XCTAssertEqual(saved.pinnedViewIDs, pinned)
        XCTAssertEqual(saved.categorySplitWidth, 0.45)
        XCTAssertFalse(saved.categoryConnectedTree)
    }

    func testCategoryPreferencesSavePreservesOtherPrivateViewSettings() throws {
        let fixture = try Fixture()
        let preferencesURL = fixture.root.appendingPathComponent("pending.views.json")
        let pins = [Identifier.make()]
        let original = ViewWorkspacePreferences(
            pinnedViewIDs: pins, categoryConnectedTree: false, categoryRightMode: "category",
            categorySplitWidth: 0.45, selectorSplitWidth: 0.51, previewVisible: false,
            previewContentHeight: 7)
        try original.save(to: preferencesURL)
        let app = try fixture.application()

        openCategoryPreferences(app)
        XCTAssertTrue(text(app).contains("Settings / Categories"))
        XCTAssertTrue(text(app).contains("> Outline"))
        app.handle(.paste("not a choice"))
        XCTAssertTrue(text(app).contains("> Outline"))
        app.handle(.text(" "))
        XCTAssertTrue(text(app).contains("> Connected tree"))
        app.handle(.function(8))

        let saved = try ViewWorkspacePreferences.load(from: preferencesURL)
        XCTAssertTrue(saved.categoryConnectedTree)
        XCTAssertEqual(saved.pinnedViewIDs, pins)
        XCTAssertEqual(saved.categoryRightMode, "category")
        XCTAssertEqual(saved.categorySplitWidth, 0.45)
        XCTAssertEqual(saved.selectorSplitWidth, 0.51)
        XCTAssertFalse(saved.previewVisible)
        XCTAssertEqual(saved.previewContentHeight, 7)
    }

    func testViewsSettingsAreTheDefaultForTheNextCategoriesWorkspace() throws {
        let fixture = try Fixture()
        _ = try fixture.category("Alpha")
        let app = try fixture.application(itemsOnly: false)

        openCategoryPreferences(app)
        XCTAssertTrue(text(app).contains("> Outline"))
        app.handle(.right)
        app.handle(.function(8))
        app.handle(.function(9))
        XCTAssertTrue(text(app).contains("Connected tree"))
    }

    func testCategoryPreferencesSaveFailureKeepsTheDraftAvailableForCancel() throws {
        let fixture = try Fixture()
        _ = try fixture.category("Alpha")
        let blocker = fixture.root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blocker)
        let app = try fixture.application(viewPreferencesURL: blocker.appendingPathComponent("views.json"))

        openCategoryPreferences(app)
        app.handle(.right)
        app.handle(.function(8))
        XCTAssertTrue(text(app).contains("Settings / Categories"))
        XCTAssertTrue(text(app).contains("> Connected tree"))
        app.handle(.function(9))
        app.handle(.function(9))
        XCTAssertTrue(text(app).contains("Outline"))
    }

    func testCategoryPreferencesTracksCtrlTAndCancelRestoresInlineDraft() throws {
        let fixture = try Fixture()
        _ = try fixture.category("Alpha")
        let app = try fixture.application()
        app.handle(.function(9))
        app.handle(.control(20))
        app.handle(.function(9))

        openCategoryPreferences(app)
        XCTAssertTrue(text(app).contains("> Connected tree"))
        app.handle(.text(" "))
        XCTAssertTrue(text(app).contains("> Outline"))
        app.handle(.function(9))
        app.handle(.function(9))
        app.handle(.paste("Alpha"))
        app.handle(.modified(.function(2), .shift))
        app.handle(.paste(" draft"))
        let draft = text(app)

        openCategoryPreferences(app)
        XCTAssertTrue(text(app).contains("Settings / Categories"))
        app.handle(.text(" "))
        app.handle(.function(9))
        XCTAssertTrue(text(app).contains("Alpha draft"))
        XCTAssertTrue(text(app).contains("[Category]"))
        XCTAssertEqual(
            draft.components(separatedBy: "\n").first { $0.contains("Alpha draft") },
            text(app).components(separatedBy: "\n").first { $0.contains("Alpha draft") })
    }

    func testInspectorTabCycleAndKeyboardModeToggleRetainDraft() throws {
        let fixture = try Fixture()
        _ = try fixture.category("Alpha")
        let app = try fixture.application()
        app.handle(.function(9))
        app.handle(.paste("Alpha"))
        app.handle(.modified(.function(2), .shift))
        XCTAssertTrue(text(app).contains("[Category]"))
        app.handle(.paste(" draft"))
        // Four editor fields, preview, and navigator cycle forever without dropping the draft.
        for _ in 0..<12 { app.handle(.tab) }
        XCTAssertTrue(text(app).contains("Alpha draft"))
        app.handle(.modified(.text("i"), .option))
        XCTAssertTrue(text(app).contains("[Items]"))
        app.handle(.modified(.text("i"), .option))
        XCTAssertTrue(text(app).contains("Alpha draft"))
        for _ in 0..<12 { app.handle(.backTab) }
        XCTAssertTrue(text(app).contains("Alpha draft"))
    }

    func testPreviewKeepsGlobalF9AndMakesContextualFunctionKeysInert() throws {
        let fixture = try Fixture()
        let alpha = try fixture.category("Alpha")
        let app = try fixture.application()
        app.handle(.function(9))
        app.handle(.tab)  // navigator -> item report
        app.handle(.tab)  // item report -> preview
        let preview = app.render(columns: 132, rows: 35)
        XCTAssertTrue(preview.contains { $0.text.contains("Preview · focused") })
        XCTAssertFalse(preview.last?.text.contains("2Edit") == true)
        app.handle(.function(2))
        app.handle(.function(4))
        app.handle(.function(7))
        XCTAssertEqual(try fixture.store.history(alpha.itemID).count, 1)
        app.handle(.function(9))
        XCTAssertTrue(text(app).contains("Views workspace"))
        app.handle(.function(9))
        XCTAssertTrue(text(app).contains("Category manager"))
        XCTAssertEqual(try fixture.store.history(alpha.itemID).count, 1)
    }
}
