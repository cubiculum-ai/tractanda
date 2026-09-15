import Foundation
import TractandaCore
import XCTest

@testable import TractandaTUI

final class MenuTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let store: ItemStore
        let client: ItemClient
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "trac-menu-" + Identifier.make())
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = try ItemStore(root: root.appendingPathComponent("store"))
            let service = ItemService(store: store)
            let uid = store.ownerUID
            client = ItemClient(transport: { service.handle($0, peerUID: uid) })
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func item(_ subject: String, fields: [String: ItemValue] = [:]) throws -> Revision {
            try client.commit(
                CommitRequest(
                    classID: "NoteItem",
                    changes: fields.merging(["subject": .text(subject)]) { _, new in new },
                    operationID: Identifier.make())
            ).revision
        }
        func app(display: FunctionKeyDisplay = .automatic) throws -> TerminalApplication {
            try TerminalApplication(
                client: client,
                journal: RecoveryJournal(
                    url: root.appendingPathComponent("pending.json"), socket: "/fixture"), itemsOnly: true,
                functionKeys: display)
        }
    }
    private func frame(_ app: TerminalApplication, width: Int = 132, height: Int = 30) -> [ScreenLine] {
        app.render(columns: width, rows: height)
    }
    private func screen(_ app: TerminalApplication) -> String {
        frame(app).map(\.text).joined(separator: "\n")
    }

    func testExtraFunctionKeysDecodeAndAlwaysHaveNonFunctionAlternatives() {
        var input = TerminalInput()
        XCTAssertEqual(input.receive(Array("\u{1b}[23".utf8)), [])
        XCTAssertEqual(
            input.receive(Array("~\u{1b}[24~\u{1b}[57374u\u{1b}[57375u".utf8)),
            [.function(11), .function(12), .function(11), .function(12)])
        XCTAssertEqual(input.receive(Array("\u{1b}[24;9:3u".utf8)), [.ignored])
        let map = Keymap.standard
        for (number, expected) in [(11, TUICommand.togglePreview), (12, .refresh)] {
            XCTAssertEqual(map.command(for: .function(number), in: .browser), expected)
            XCTAssertTrue(
                map.keys(for: expected, in: .browser).contains {
                    if case .function = $0.key { false } else { true }
                })
            XCTAssertNil(map.command(for: .function(number), in: .editor))
            XCTAssertNil(map.command(for: .function(number), in: .pending))
        }
    }

    func testFunctionKeyDisplayIsOptionalAndDoesNotReassignTheFirstTen() throws {
        for (display, narrow, wide) in [
            (FunctionKeyDisplay.automatic, 10, 12), (.ten, 10, 10), (.twelve, 12, 12),
        ] {
            let fixture = try Fixture()
            let app = try fixture.app(display: display)
            for (width, expected) in [(80, narrow), (132, wide)] {
                let bar = try XCTUnwrap(frame(app, width: width).last)
                XCTAssertEqual(bar.segments.count, expected * 2)
                XCTAssertEqual(bar.text.reduce(0) { $0 + TerminalText.width($1) }, width - 1)
                XCTAssertFalse(bar.text.contains("2Edit"))  // No selected item: inactive slots stay blank.
                XCTAssertTrue(bar.text.contains("1Help"))
                XCTAssertTrue(bar.text.contains("10Menu"))
                XCTAssertEqual(bar.text.contains("11"), expected == 12)
            }
            XCTAssertTrue(try fixture.store.candidates().isEmpty)
        }
    }

    func testMenuGroupsCoverEveryCommandAndPreserveContext() {
        let map = Keymap.standard
        for context in KeyContext.allCases {
            let menu = CommandMenu(keymap: map, context: context)
            let commands = menu.groups.flatMap(\.commands)
            XCTAssertEqual(commands, CommandMenu.definitions.flatMap(\.commands), context.rawValue)
            XCTAssertEqual(Set(commands).count, commands.count, "One menu placement per command")
            for group in menu.groups {
                XCTAssertNotEqual(group.rows.first, .separator)
                XCTAssertNotEqual(group.rows.last, .separator)
            }
        }
        let editor = CommandMenu(keymap: map, context: .editor)
        XCTAssertTrue(editor.groups.flatMap(\.commands).contains(.newItem))
        XCTAssertTrue(editor.groups.flatMap(\.commands).contains(.undo))
        XCTAssertEqual(
            editor.groups.map(\.title),
            ["Tractanda", "File", "Edit", "View", "Window", "Item", "Category", "Help"])
    }

    func testMenuNavigationSkipsDisabledCommandsAndEmptyGroups() throws {
        var menu = CommandMenu(keymap: .standard, context: .browser)
        XCTAssertEqual(menu.group.id, .file)
        menu.moveGroup(1) { [.editNote, .unmarkAll].contains($0) }
        XCTAssertEqual(menu.group.id, .edit)
        XCTAssertEqual(menu.command, .editNote)
        menu.moveCommand(1) { [.editNote, .unmarkAll].contains($0) }
        XCTAssertEqual(menu.command, .unmarkAll)
        menu.selectBoundary(last: false) { [.editNote, .unmarkAll].contains($0) }
        XCTAssertEqual(menu.command, .editNote)
        let minimal = try Keymap(bindings: [
            KeyBinding(context: .browser, chord: KeyChord(.function(1)), command: .help)
        ])
        menu = CommandMenu(keymap: minimal, context: .browser)
        menu.moveGroup(-1) { _ in true }
        XCTAssertEqual(menu.group.id, .application)
        menu.moveGroup(1) { _ in true }
        XCTAssertEqual(menu.group.id, .file)
    }

    func testMenuOverlayPreservesDraftAndSelectionAcrossResize() throws {
        let fixture = try Fixture()
        let app = try fixture.app()
        app.handle(.text("n"))
        app.handle(.text("Menu draft"))
        app.handle(.tab)
        app.handle(.paste("A note with café and 文 and 👩🏽‍💻"))
        app.handle(.function(10))
        app.handle(.right)  // Edit; Undo is available.
        for (width, height) in [(48, 12), (80, 25), (30, 8), (132, 40)] {
            let result = frame(app, width: width, height: height)
            XCTAssertEqual(result.count, height)
            if width >= 48 {
                XCTAssertTrue(result[2].text.contains("Edit"))
                XCTAssertTrue(result.contains { $0.text.contains("Undo text edit") })
                for line in result where !line.segments.isEmpty {
                    XCTAssertEqual(line.text.reduce(0) { $0 + TerminalText.width($1) }, width - 1)
                }
            } else {
                app.handle(.text("qIGNORED"))
            }
        }
        app.handle(.enter)  // Undo from the menu, without sending an item operation.
        XCTAssertTrue(screen(app).contains("Body / note"))
        XCTAssertTrue(try fixture.store.candidates().isEmpty)
        app.handle(.function(10))
        app.handle(.right)
        app.handle(.enter)  // Redo is now first enabled.
        XCTAssertTrue(screen(app).contains("café and 文"))
        app.handle(.function(10))
        app.handle(.enter)  // File -> Save.
        let item = try XCTUnwrap(fixture.store.candidates().first)
        XCTAssertEqual(item.fields["subject"], .text("Menu draft"))
        XCTAssertEqual(item.fields["body"], .text("A note with café and 文 and 👩🏽‍💻"))
        XCTAssertEqual(try fixture.store.history(item.itemID).count, 1)
    }

    func testViewMenuChangesFunctionDisplayWithoutSavingOrLosingDraft() throws {
        let fixture = try Fixture()
        let app = try fixture.app(display: .ten)
        app.handle(.text("n"))
        app.handle(.text("Retain me"))
        app.handle(.function(10))
        app.handle(.right)
        app.handle(.right)  // View
        app.handle(.end)
        app.handle(.enter)  // Twelve keys.
        XCTAssertEqual(frame(app, width: 80).last?.segments.count, 24)
        XCTAssertTrue(screen(app).contains("Retain me"))
        XCTAssertTrue(try fixture.store.candidates().isEmpty)
        app.handle(.function(10))
        app.handle(.right)
        app.handle(.right)
        app.handle(.end)
        app.handle(.up)
        app.handle(.up)
        app.handle(.enter)  // Automatic.
        XCTAssertEqual(frame(app, width: 80).last?.segments.count, 20)
        XCTAssertEqual(frame(app, width: 132).last?.segments.count, 24)
        app.handle(.control(7))
        XCTAssertTrue(try fixture.store.candidates().isEmpty)
    }

    func testMenuItemActionsStillRequireGuardedConfirmation() throws {
        let fixture = try Fixture()
        let item = try fixture.item("Keep until confirmed")
        let app = try fixture.app()
        app.handle(.function(10))
        app.handle(.right)
        app.handle(.right)
        app.handle(.right)
        app.handle(.right)  // Item
        app.handle(.end)
        app.handle(.enter)  // Delete.
        XCTAssertTrue(screen(app).contains("Type delete"))
        XCTAssertEqual(try fixture.store.get(item.itemID), item)
        app.handle(.escape)
        XCTAssertEqual(try fixture.store.get(item.itemID), item)
        app.handle(.function(10))
        app.handle(.right)
        app.handle(.right)
        app.handle(.right)
        app.handle(.right)
        app.handle(.end)
        app.handle(.enter)
        app.handle(.text("delete"))
        app.handle(.control(19))
        XCTAssertTrue(try fixture.store.get(item.itemID).isDeleted)
        XCTAssertEqual(try fixture.store.history(item.itemID).count, 2)
    }

    func testDisabledMenuActionsAndNarrowBarDoNotChangeData() throws {
        let fixture = try Fixture()
        let app = try fixture.app()
        app.handle(.function(10))
        app.handle(.right)
        app.handle(.right)
        app.handle(.right)
        app.handle(.right)  // Item, no item.
        app.handle(.enter)
        XCTAssertTrue(screen(app).contains("Command menu"))
        XCTAssertTrue(
            frame(app).contains {
                $0.segments.contains { $0.style == .disabled && $0.text.contains("Mark done") }
            })
        app.handle(.right)
        app.handle(.right)  // Help on narrow screen, bar scrolls to retain it.
        let narrow = frame(app, width: 48, height: 12)
        XCTAssertEqual(narrow.count, 12)
        XCTAssertTrue(narrow[1].text.contains("Help"))
        XCTAssertTrue(narrow[1].text.contains("‹"))
        app.handle(.escape)
        XCTAssertFalse(screen(app).contains("Command menu"))
        XCTAssertTrue(try fixture.store.candidates().isEmpty)
    }

    func testConvenienceKeysRefreshAndRestoreAllItemsWithoutEditing() throws {
        let fixture = try Fixture()
        let item = try fixture.item("Before refresh")
        let app = try fixture.app(display: .ten)
        let revised = try fixture.client.commit(
            CommitRequest(
                action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                changes: ["subject": .text("After refresh")], operationID: Identifier.make())
        ).revision
        app.handle(.function(12))
        XCTAssertTrue(screen(app).contains("After refresh"))
        app.handle(.text("f"))
        app.handle(.text("subject == \"Nobody\""))
        app.handle(.control(19))
        XCTAssertTrue(screen(app).contains("0 items"))
        app.handle(.text("a"))
        XCTAssertTrue(screen(app).contains("After refresh"))
        XCTAssertTrue(screen(app).contains("No expression filter"))
        XCTAssertEqual(try fixture.store.get(item.itemID), revised)
    }
}
