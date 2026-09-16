import Foundation
import TractandaCore
import XCTest

@testable import TractandaTUI

final class KeymapTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let store: ItemStore
        let client: ItemClient
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "trac-keys-" + Identifier.make())
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = try ItemStore(root: root.appendingPathComponent("store"))
            let service = ItemService(store: store)
            let uid = store.ownerUID
            client = ItemClient(transport: { service.handle($0, peerUID: uid) })
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func item(_ name: String, fields: [String: ItemValue] = [:]) throws -> Revision {
            try client.commit(
                CommitRequest(
                    classID: "Item", changes: fields.merging(["subject": .text(name)]) { _, new in new },
                    operationID: Identifier.make())
            ).revision
        }
        func app(keymap: Keymap = .standard) throws -> TerminalApplication {
            try TerminalApplication(
                client: client,
                journal: RecoveryJournal(
                    url: root.appendingPathComponent("pending.json"), socket: "/fixture"), itemsOnly: true,
                keymap: keymap)
        }
    }
    private func screen(_ app: TerminalApplication, width: Int = 120, height: Int = 35) -> String {
        app.render(columns: width, rows: height).map(\.text).joined(separator: "\n")
    }

    func testModifiedInputIsIncrementalAndReleasesNeverExecute() {
        var input = TerminalInput()
        XCTAssertEqual(input.receive([27]), [])
        let accented = Array("é".utf8)
        XCTAssertEqual(input.receive([accented[0]]), [])
        XCTAssertEqual(input.receive([accented[1]]), [.modified(.text("é"), .option)])
        XCTAssertEqual(input.receive(Array("\u{1b}[115;".utf8)), [])
        XCTAssertEqual(input.receive(Array("9u".utf8)), [.modified(.text("s"), .command)])
        XCTAssertEqual(
            input.receive(Array("\u{1b}[115;10u\u{1b}[115;9:3u".utf8)),
            [.modified(.text("s"), [.command, .shift]), .ignored])
        XCTAssertEqual(input.receive(Array("\u{1b}[115;5:2u".utf8)), [.modified(.text("s"), .control)])
        XCTAssertEqual(
            input.receive(Array("\u{1b}[1;2D\u{1b}[18;3~\u{1b}[1;3S".utf8)),
            [.modified(.left, .shift), .modified(.function(7), .option), .modified(.function(4), .option)])
        XCTAssertEqual(
            input.receive(Array("\u{1b}\u{1b}[18~\u{1b}\r".utf8)),
            [.modified(.function(7), .option), .modified(.enter, .option)])
        XCTAssertEqual(input.receive(Array("\u{1b}[57365;1u\u{1b}[9;2u".utf8)), [.function(2), .backTab])
        XCTAssertEqual(
            input.receive(Array("\u{1b}[115;999u\u{1b}[57360u\u{1b}[1;17A".utf8)),
            [.ignored, .ignored, .ignored])
        XCTAssertEqual(
            input.receive(Array("\u{1b}[200~\u{1b}[115;9u\u{13}\u{1b}[201~".utf8)),
            [.paste("\u{1b}[115;9u\u{13}")])
    }

    func testKeymapHasUnambiguousSerializableBindingsAndWorkspaceContexts() throws {
        let bindings = Keymap.standard.bindings
        let decoded = try JSONDecoder().decode([KeyBinding].self, from: JSONEncoder().encode(bindings))
        XCTAssertEqual(decoded, bindings)
        let map = try Keymap(bindings: decoded)
        XCTAssertThrowsError(try Keymap(bindings: bindings + [bindings[0]]))
        let functions: [TUICommand] = [
            .help, .editItem, .include, .done, .editNote, .properties, .mark, .toggleSelector,
            .switchWorkspace,
            .commands,
        ]
        for (index, command) in functions.enumerated() {
            XCTAssertEqual(map.command(for: .function(index + 1), in: .browser), command)
        }
        XCTAssertEqual(map.command(for: .function(2), in: .editor), .paste)
        XCTAssertEqual(map.command(for: .function(3), in: .editor), .copy)
        XCTAssertEqual(map.command(for: .function(4), in: .editor), .cut)
        XCTAssertEqual(map.command(for: .function(7), in: .editor), .setMark)
        XCTAssertEqual(map.command(for: .function(6), in: .categories), .properties)
        XCTAssertEqual(map.command(for: .function(9), in: .categories), .switchWorkspace)
        for context: KeyContext in [.picker, .sections, .history, .columns, .reader, .help, .group] {
            XCTAssertEqual(map.command(for: .function(9), in: context), .cancel)
        }
        XCTAssertEqual(map.command(for: .function(4), in: .categories), .done)
        XCTAssertEqual(map.command(for: .function(8), in: .categories), .toggleSelector)
        XCTAssertEqual(map.command(for: .modified(.enter, .option), in: .categories), .refineCategory)
        XCTAssertEqual(map.command(for: .control(14), in: .viewWorkspace), .newView)
        XCTAssertEqual(map.command(for: .control(5), in: .viewWorkspace), .editView)
        XCTAssertEqual(map.command(for: .modified(.text("n"), .command), in: .viewWorkspace), .newView)
        XCTAssertEqual(map.command(for: .modified(.text("e"), .command), in: .viewWorkspace), .editView)
        XCTAssertEqual(map.command(for: .control(14), in: .categories), .newItem)
        XCTAssertEqual(map.command(for: .modified(.text("N"), .control), in: .categories), .newRoot)
        XCTAssertEqual(map.command(for: .control(5), in: .browser), .editItem)
        XCTAssertNil(map.command(for: .control(6), in: .categories))
        XCTAssertEqual(map.command(for: .control(6), in: .text), .moveRight)
        XCTAssertEqual(map.command(for: .control(1), in: .text), .lineStart)
        XCTAssertEqual(map.command(for: .control(1), in: .browser), .selectAll)
        XCTAssertEqual(map.command(for: .modified(.text("S"), .command), in: .browser), .saveAs)
        XCTAssertEqual(map.command(for: .control(19), in: .browser), .save)
        XCTAssertNil(map.command(for: .paste("q"), in: .browser))
        XCTAssertNil(map.command(for: .text("q"), in: .smallScreen))
        XCTAssertEqual(map.command(for: .control(17), in: .smallScreen), .quit)
        XCTAssertEqual(map.preferredKeys(for: .newView, in: .viewWorkspace).first?.label, "Ctrl-N")
        XCTAssertEqual(map.preferredKeys(for: .newRoot, in: .categories).first?.label, "Meta-Shift-N")
        XCTAssertEqual(map.preferredKeys(for: .pinView, in: .viewWorkspace).first?.label, "Meta-M")
        XCTAssertEqual(map.preferredKeys(for: .saveAs, in: .viewDefinition).first?.label, "F3")
        let viewHelp = map.help(in: .viewWorkspace)
        XCTAssertTrue(viewHelp.contains("Ctrl-N") && viewHelp.contains("Cmd-N"))
    }

    func testEditingMovementUsesMacAndEmacsKeys() {
        var buffer = TextBuffer("first\nabc\nlast")
        buffer.handle(.control(1), multiline: true)
        XCTAssertEqual(buffer.cursor, 10)
        buffer.handle(.control(16), multiline: true)
        XCTAssertEqual(buffer.cursor, 6)
        buffer.handle(.control(6), multiline: true)
        buffer.handle(.control(6), multiline: true)
        buffer.handle(.control(2), multiline: true)
        XCTAssertEqual(buffer.cursor, 7)
        buffer.handle(.control(14), multiline: true)
        XCTAssertEqual(buffer.cursor, 11)
        buffer.handle(.control(5), multiline: true)
        XCTAssertEqual(buffer.cursor, 14)
        buffer.handle(.modified(.up, .command), multiline: true)
        XCTAssertEqual(buffer.cursor, 0)
        buffer.handle(.modified(.text("f"), .option), multiline: true)
        XCTAssertEqual(buffer.cursor, 5)
        buffer.handle(.modified(.text("f"), .option), multiline: true)
        XCTAssertEqual(buffer.cursor, 9)
        buffer.handle(.modified(.left, .option), multiline: true)
        XCTAssertEqual(buffer.cursor, 6)
        buffer.handle(.control(14))  // A single-line field does not change field or item.
        XCTAssertEqual(buffer.cursor, 6)
    }

    func testLocalClipboardSelectionUndoAndCrossFieldPaste() {
        let clipboard = TextClipboard()
        var first = TextBuffer("café 👩🏽‍💻")
        first.handle(.control(1))
        first.handle(.control(0))
        for _ in 0..<4 { first.handle(.control(6)) }
        XCTAssertEqual(first.selection, 0..<4)
        XCTAssertTrue(first.markedText.contains("⟦café⟧"))
        first.handle(command: .copy, clipboard: clipboard)
        XCTAssertEqual(clipboard.text, "café")
        first.handle(command: .cut, clipboard: clipboard)
        XCTAssertEqual(first.text, " 👩🏽‍💻")
        first.handle(.control(26))
        XCTAssertEqual(first.text, "café 👩🏽‍💻")
        first.handle(.modified(.text("z"), [.command, .shift]))
        XCTAssertEqual(first.text, " 👩🏽‍💻")
        var second = TextBuffer()
        second.handle(command: .paste, clipboard: clipboard)
        XCTAssertEqual(second.text, "café")
        second.handle(.modified(.left, .shift))
        XCTAssertEqual(second.selection, 3..<4)
        second.handle(.text("e"))
        XCTAssertEqual(second.text, "cafe")
        clipboard.text = "one\ntwo\u{1b}[31m"
        second.handle(command: .selectText)
        second.handle(command: .paste, clipboard: clipboard)
        XCTAssertFalse(second.text.contains("\n"))
        XCTAssertFalse(second.text.contains("\u{1b}"))
    }

    func testKillYankOpenLineAndTransposeStayInTheDraft() {
        let clipboard = TextClipboard()
        var buffer = TextBuffer("alpha\nbeta")
        buffer.handle(.control(1), multiline: true)
        buffer.handle(.control(11), multiline: true, clipboard: clipboard)
        XCTAssertEqual(buffer.text, "alpha\n")
        XCTAssertEqual(clipboard.text, "beta")
        buffer.handle(.control(25), multiline: true, clipboard: clipboard)
        XCTAssertEqual(buffer.text, "alpha\nbeta")
        buffer.handle(.control(20), multiline: true)
        XCTAssertEqual(buffer.text, "alpha\nbeat")
        buffer.handle(.control(1), multiline: true)
        buffer.handle(.control(15), multiline: true)
        XCTAssertEqual(buffer.text, "alpha\n\nbeat")
        XCTAssertEqual(buffer.cursor, 6)
        buffer.handle(.control(11), multiline: true, clipboard: clipboard)
        XCTAssertEqual(buffer.text, "alpha\nbeat")
        XCTAssertEqual(clipboard.text, "\n")
        buffer.handle(.modified(.text("d"), .option), multiline: true, clipboard: clipboard)
        XCTAssertEqual(buffer.text, "alpha\n")
        XCTAssertEqual(clipboard.text, "beat")
    }

    func testForwardedCommandAndControlFallbackSaveOneEditAndCancel() throws {
        let fixture = try Fixture()
        let app = try fixture.app()
        app.handle(.modified(.text("n"), .command))
        app.handle(.text("Key fixture"))
        app.handle(.control(1))
        app.handle(.control(6))
        app.handle(.control(2))
        app.handle(.control(5))
        app.handle(.tab)
        app.handle(.paste("alpha\nbeta"))
        app.handle(.control(1))
        app.handle(.control(16))
        app.handle(.control(14))
        app.handle(.modified(.text("s"), .command))
        let item = try XCTUnwrap(fixture.store.candidates().first)
        XCTAssertEqual(item.fields["subject"], .text("Key fixture"))
        XCTAssertEqual(item.fields["body"], .text("alpha\nbeta"))
        XCTAssertEqual(try fixture.store.candidates().count, 1)
        XCTAssertEqual(try fixture.store.history(item.itemID).count, 1)
        app.handle(.function(2))
        app.handle(.text(" canceled"))
        app.handle(.modified(.text("w"), .command))
        XCTAssertEqual(try fixture.store.get(item.itemID), item)
        app.handle(.control(14))
        app.handle(.text("Another"))
        app.handle(.control(7))
        XCTAssertEqual(try fixture.store.candidates().count, 1)
        app.handle(.function(5))
        app.handle(.text(" edited"))
        app.handle(.control(19))
        XCTAssertEqual(try fixture.store.get(item.itemID).fields["body"], .text("alpha\nbeta edited"))
        XCTAssertEqual(try fixture.store.history(item.itemID).count, 2)
    }

    func testFunctionBarMatchesContextAndResizingAndMenuKeepsDraft() throws {
        let fixture = try Fixture()
        let app = try fixture.app()
        _ = try fixture.item("Existing")
        app.handle(.text("r"))
        for (width, height) in [(48, 12), (80, 25), (132, 40), (400, 200)] {
            let frame = app.render(columns: width, rows: height)
            XCTAssertEqual(frame.count, height)
            let bar = try XCTUnwrap(frame.last)
            XCTAssertEqual(bar.segments.count, width >= 110 ? 24 : 20)
            XCTAssertEqual(bar.text.reduce(0) { $0 + TerminalText.width($1) }, width - 1)
            XCTAssertEqual(bar.segments.map(\.text).joined(), bar.text)
        }
        XCTAssertTrue(screen(app).contains("2Edit"))
        app.handle(.function(2))
        XCTAssertFalse(screen(app).contains("2Paste"), "An empty clipboard cannot be pasted")
        app.handle(.control(1))
        app.handle(.function(7))
        for _ in 0..<8 { app.handle(.control(6)) }
        app.handle(.function(3))
        XCTAssertTrue(screen(app).contains("2Paste"))
        app.handle(.tab)
        app.handle(.function(2))
        XCTAssertTrue(screen(app).contains("Existing "))
        app.handle(.function(10))
        XCTAssertTrue(screen(app).contains("Command menu"))
        XCTAssertTrue(screen(app).contains("Save / apply"))
        app.handle(.escape)
        XCTAssertTrue(screen(app).contains("Body / note"))
        app.handle(.function(4))  // No selection: must not mark the item Done.
        app.handle(.control(19))
        let item = try XCTUnwrap(fixture.store.candidates().first)
        XCTAssertEqual(item.fields["body"], .text("Existing"))
        XCTAssertNil(item.fields["status"])
    }

    func testCategoryFunctionKeysNeverCreateMoveOrDeleteUnexpectedly() throws {
        let fixture = try Fixture()
        let category = try fixture.item(
            "Root",
            fields: [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                ])
            ])
        let app = try fixture.app()
        app.handle(.function(9))
        app.handle(.text("Root"))
        app.handle(.function(4))
        app.handle(.function(8))
        XCTAssertEqual(try fixture.store.get(category.itemID), category)
        XCTAssertTrue(screen(app).contains("Category manager"))
        app.handle(.control(1))
        app.handle(.control(6))
        XCTAssertTrue(screen(app).contains("Find: Root"))
        app.handle(.function(6))
        XCTAssertTrue(screen(app).contains("Category rule"))
        app.handle(.escape)
        app.handle(.function(9))
        app.handle(.text("Root"))
        app.handle(.function(5))
        XCTAssertTrue(screen(app).contains("Body / note"))
        XCTAssertEqual(try fixture.store.candidates().count, 1)
        app.handle(.control(7))
        app.handle(.function(9))
        app.handle(.function(9))
        XCTAssertFalse(screen(app).contains("Category manager ·"))
        XCTAssertEqual(try fixture.store.get(category.itemID), category)
    }

    func testSaveAndSaveAsHaveDistinctItemIdentity() throws {
        let fixture = try Fixture()
        let app = try fixture.app()
        app.handle(.control(19))
        app.handle(.text("First view"))
        app.handle(.control(19))
        let first = try XCTUnwrap(fixture.store.candidates().first)
        app.handle(.control(19))
        app.handle(.text(" renamed"))
        app.handle(.control(19))
        XCTAssertEqual(try fixture.store.candidates().count, 1)
        XCTAssertEqual(try fixture.store.history(first.itemID).count, 2)
        app.handle(.modified(.text("s"), [.command, .shift]))
        app.handle(.text("Second view"))
        app.handle(.modified(.text("s"), .command))
        XCTAssertEqual(try fixture.store.candidates().count, 2)
        XCTAssertEqual(try fixture.store.history(first.itemID).count, 2)
    }

    func testReplacingBindingUpdatesDispatchHelpMenuAndFunctionBar() throws {
        var bindings = Keymap.standard.bindings.filter {
            !($0.context == .browser && $0.chord == KeyChord(.function(2)))
        }
        bindings.append(KeyBinding(context: .browser, chord: KeyChord(.function(2)), command: .editNote))
        let map = try Keymap(bindings: bindings)
        let fixture = try Fixture()
        let item = try fixture.item("Remap fixture")
        let app = try fixture.app(keymap: map)
        XCTAssertTrue(screen(app).contains("2Note"))
        XCTAssertFalse(screen(app).contains("2Edit"))
        XCTAssertTrue(map.help(in: .browser).contains("F5, F2  Edit note"))
        app.handle(.function(10))
        app.handle(.function(2))  // Forward the same mapped command through the menu.
        XCTAssertTrue(screen(app).contains("Body / note"))
        app.handle(.text("Saved through remapped key"))
        app.handle(.control(19))
        XCTAssertEqual(try fixture.store.get(item.itemID).fields["body"], .text("Saved through remapped key"))
        XCTAssertEqual(try fixture.store.get(item.itemID).fields["subject"], item.fields["subject"])
    }
}
