import Foundation
import TractandaCore
import XCTest

@testable import TractandaTUI

final class TUITests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trac-tui-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    func testEmptyClipboardPasteRetainsSelectionAndText() {
        let clipboard = TextClipboard()
        var field = TextBuffer("Keep this")
        field.handle(command: .selectText, multiline: false, columns: 80, clipboard: clipboard)
        field.handle(command: .paste, multiline: false, columns: 80, clipboard: clipboard)
        XCTAssertEqual(field.text, "Keep this")
        XCTAssertNotNil(field.selection)
        clipboard.text = "Replacement"
        field.handle(command: .paste, multiline: false, columns: 80, clipboard: clipboard)
        XCTAssertEqual(field.text, "Replacement")
    }

    func testANSISelectionIsSemanticAndStopsAtSplitPaneBoundary() throws {
        let line = ScreenLine(
            text: "selected │ preview",
            segments: [
                ScreenSegment(text: "selected", style: .activeSelection),
                ScreenSegment(text: " │ ", style: .normal),
                ScreenSegment(text: "preview", style: .dimmed),
            ])
        let cells = TerminalANSI.cells(line, columns: 18)
        XCTAssertTrue(cells.prefix(8).allSatisfy { $0.style == .activeSelection })
        XCTAssertEqual(cells[8].style, .normal)
        XCTAssertTrue(cells.dropFirst(11).prefix(7).allSatisfy { $0.style == .dimmed })
        let rendered = TerminalANSI.line(line, columns: 18, appearance: .preset("blue"))
        XCTAssertTrue(rendered.contains("[0;97;44m"))
        XCTAssertFalse(rendered.contains("[7m"))
        XCTAssertTrue(rendered.hasSuffix("\u{1b}[0m\u{1b}[K"))
    }

    func testActivePaneRoleAndShadowSpansAreCellAccurate() {
        var appearance = TerminalAppearance.preset("blue")
        appearance.roles[.activePane] = AppearancePair(foreground: .brightCyan, background: .black)
        let active = ScreenLine(text: "body", style: .activePane)
        XCTAssertTrue(
            TerminalANSI.line(active, columns: 6, appearance: appearance).contains("[0;96;40m"))
        XCTAssertTrue(TerminalANSI.cells(active, columns: 6).allSatisfy { $0.style == .activePane })

        let shadow = ScreenLine(text: "literal", style: .activePane, shadowColumns: [2..<5])
        let cells = TerminalANSI.cells(shadow, columns: 7)
        XCTAssertEqual(
            cells.map(\.style),
            [.activePane, .activePane, .shadow, .shadow, .shadow, .activePane, .activePane])
        XCTAssertTrue(TerminalANSI.line(shadow, columns: 7, appearance: appearance).contains("[0;2;30;40m"))
        let paddedShadow = ScreenLine(text: "x", style: .activePane, shadowColumns: [4..<6])
        XCTAssertEqual(TerminalANSI.cells(paddedShadow, columns: 6)[4].style, .shadow)
    }

    func testAppearanceVersionThreeMigratesOnlyTheNewActivePaneRole() throws {
        var old = TerminalAppearance.preset("blue")
        old.version = 3
        old.roles.removeValue(forKey: .activePane)
        old.customRoles = old.roles
        old.preset = TerminalAppearance.customPresetID
        old.savedPalettes = old.savedPalettes.map { palette in
            var roles = palette.roles
            roles.removeValue(forKey: .activePane)
            return AppearancePalette(id: palette.id, name: palette.name, roles: roles)
        }
        let data = try JSONEncoder().encode(old)
        let migrated = try JSONDecoder().decode(TerminalAppearance.self, from: data)
        XCTAssertEqual(migrated.version, 4)
        XCTAssertEqual(migrated.roles[.activePane], AppearanceRole.activePaneDefault)
        XCTAssertEqual(migrated.customRoles?[.activePane], AppearanceRole.activePaneDefault)
        XCTAssertTrue(
            migrated.savedPalettes.allSatisfy { $0.roles[.activePane] == AppearanceRole.activePaneDefault })
        XCTAssertEqual(migrated.roles[.passivePane]?.dim, true)
    }

    func testDropShadowsAreIndependentAndPersistThroughTheAppearanceForm() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let file = directory.appendingPathComponent("appearance.json")
        let app = try TerminalApplication(
            client: client,
            journal: RecoveryJournal(
                url: directory.appendingPathComponent("pending.json"), socket: "/fixture"),
            itemsOnly: true, appearanceURL: file)
        XCTAssertFalse(try TerminalAppearance.load(from: file).showsDropShadows)
        let beforePreset = try TerminalAppearance.load(from: file).preset
        app.handle(.modified(.text(","), .command))
        for _ in 0..<5 { app.handle(.tab) }
        app.handle(.down)
        app.handle(.control(19))
        let saved = try TerminalAppearance.load(from: file)
        XCTAssertTrue(saved.showsDropShadows)
        XCTAssertEqual(saved.preset, beforePreset)

        let reopened = try TerminalApplication(
            client: client,
            journal: RecoveryJournal(
                url: directory.appendingPathComponent("pending-2.json"), socket: "/fixture"),
            itemsOnly: true, appearanceURL: file)
        reopened.handle(.function(10))
        let frame = reopened.render(columns: 80, rows: 25)
        XCTAssertTrue(frame.flatMap { TerminalANSI.cells($0, columns: 79) }.contains { $0.style == .shadow })
        reopened.handle(.escape)
        XCTAssertFalse(
            reopened.render(columns: 80, rows: 25).flatMap {
                TerminalANSI.cells($0, columns: 79)
            }.contains { $0.style == .shadow })
    }

    func testShadowsReserveCompactAndNormalSettingsSpaceAndRespectNestedPanels() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let file = directory.appendingPathComponent("appearance.json")
        var appearance = TerminalAppearance.initial()
        appearance.showsDropShadows = true
        try appearance.save(to: file)
        let app = try TerminalApplication(
            client: client,
            journal: RecoveryJournal(
                url: directory.appendingPathComponent("pending.json"), socket: "/fixture"),
            itemsOnly: true, appearanceURL: file)
        app.handle(.modified(.text(","), .command))
        for (columns, rows) in [(80, 25), (48, 12)] {
            let frame = app.render(columns: columns, rows: rows)
            XCTAssertTrue(
                frame.flatMap { TerminalANSI.cells($0, columns: columns - 1) }.contains {
                    $0.style == .shadow
                })
            let footer = try XCTUnwrap(frame.first { $0.text.contains("F5 Save as") })
            XCTAssertTrue(footer.text.contains("F6 Delete"))
            XCTAssertTrue(footer.text.contains("F8 Save"))
            XCTAssertTrue(footer.text.contains("F9 Cancel"))
        }

        app.handle(.function(5))
        let nested = app.render(columns: 80, rows: 25)
        // The named popup masks the parent only within its own rectangle: the parent right arm
        // remains visible beside it, and the frontmost named border itself is never shadowed.
        XCTAssertEqual(TerminalANSI.cells(nested[9], columns: 79)[77].style, .shadow)
        XCTAssertEqual(TerminalANSI.cells(nested[9], columns: 79)[10].style, .menu)
    }

    func testPassiveReportBlankCellsStayPassiveWhenViewsOwnFocus() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let app = try TerminalApplication(
            client: client,
            journal: RecoveryJournal(
                url: directory.appendingPathComponent("pending.json"), socket: "/fixture"),
            appearanceURL: directory.appendingPathComponent("appearance.json"))
        let displayed = app.render(columns: 80, rows: 25)
        XCTAssertTrue(displayed.flatMap(\.segments).contains { $0.style == .link && $0.text == "All items" })
        let blank = try XCTUnwrap(
            displayed.first {
                $0.segments.count == 3 && $0.segments[2].text.trimmingCharacters(in: .whitespaces).isEmpty
            })
        let leftWidth = blank.segments[0].text.reduce(0) { $0 + TerminalText.width($1) } + 1
        XCTAssertTrue(
            TerminalANSI.cells(blank, columns: 79).dropFirst(leftWidth).allSatisfy { $0.style == .dimmed })
    }

    func testAppearancePresetsAndPrivateAtomicStorage() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("appearance.json")
        XCTAssertEqual(try TerminalAppearance.load(from: file).preset, "blue")
        try TerminalAppearance.preset("amber").save(to: file)
        XCTAssertEqual(try TerminalAppearance.load(from: file).preset, "amber")
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber)
                .intValue & 0o077, 0)
        XCTAssertNotEqual(
            TerminalAppearance.preset("blue").sgr(for: .activeSelection),
            TerminalAppearance.preset("amber").sgr(for: .activeSelection))
        var custom = TerminalAppearance.preset("blue")
        custom.preset = TerminalAppearance.customPresetID
        custom.roles[.functionKeyLabel] = AppearancePair(foreground: .brightCyan, background: .black)
        custom.roles[.menuSelection] = AppearancePair(foreground: .brightWhite, background: .magenta)
        XCTAssertNotEqual(custom.sgr(for: .functionKeyLabel), custom.sgr(for: .menuSelection))
        XCTAssertTrue(
            TerminalANSI.line(
                ScreenLine(text: "F1", style: .functionKeyLabel), columns: 2, appearance: custom
            ).contains("[0;96;40m"))
        XCTAssertTrue(
            TerminalANSI.line(
                ScreenLine(text: "menu", style: .menuSelection), columns: 4, appearance: custom
            ).contains("[0;97;45m"))
    }

    func testAppearanceLibraryRetainsCustomAndSupportsOrdinaryDataPalettes() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("appearance.json")
        var value = TerminalAppearance.initial()
        XCTAssertEqual(value.savedPalettes.map(\.name), ["Blue", "Amber"])
        var customRoles = value.roles
        customRoles[.activeSelection]?.foreground = .red
        value.preset = TerminalAppearance.customPresetID
        value.roles = customRoles
        value.customRoles = customRoles
        let blue = try XCTUnwrap(value.palette(namedOrID: "Blue"))
        value.preset = blue.id
        value.roles = blue.roles
        XCTAssertEqual(value.customRoles?[.activeSelection]?.foreground, .red)
        let moss = AppearancePalette(id: Identifier.make(), name: "Moss", roles: customRoles)
        value.savedPalettes.append(moss)
        value.preset = moss.id
        value.roles = moss.roles
        try value.save(to: file)
        let restored = try TerminalAppearance.load(from: file)
        XCTAssertEqual(restored.presetDisplayName, "Moss")
        XCTAssertEqual(restored.customRoles?[.activeSelection]?.foreground, .red)
        XCTAssertEqual(restored.palette(namedOrID: "Moss")?.id, moss.id)
    }

    func testAppearanceRejectsUnsafeOrInvalidFilesWithoutReplacingSavedTheme() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("appearance.json")
        try TerminalAppearance.preset("amber").save(to: file)
        let original = try Data(contentsOf: file)
        for invalid in [
            #"{"version":3,"preset":"blue","roles":{}}"#,
            String(repeating: "x", count: 16_385),
        ] {
            try Data(invalid.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertThrowsError(try TerminalAppearance.load(from: file))
            try original.write(to: file)
        }
        let link = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try TerminalAppearance.load(from: link))
        XCTAssertThrowsError(try TerminalAppearance.preset("blue").save(to: link))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAppearanceOverlayStagesSavesAndReopensAnIsolatedAppearance() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let journal = RecoveryJournal(
            url: directory.appendingPathComponent("pending.json"), socket: "/fixture")
        let file = directory.appendingPathComponent("appearance.json")
        let app = try TerminalApplication(
            client: client, journal: journal, itemsOnly: true, appearanceURL: file)
        app.handle(.modified(.text(","), .command))
        XCTAssertTrue(
            app.render(columns: 48, rows: 12).contains { $0.text.contains("Settings / Appearance") })
        app.handle(.down)
        app.handle(.control(19))
        XCTAssertEqual(try TerminalAppearance.load(from: file).preset, "amber")
        let reopened = try TerminalApplication(
            client: client, journal: journal, itemsOnly: true, appearanceURL: file)
        reopened.handle(.modified(.text(","), .command))
        XCTAssertTrue(reopened.render(columns: 48, rows: 12).contains { $0.text.contains("Amber") })
        for _ in 0..<6 { reopened.handle(.tab) }
        reopened.handle(.down)
        reopened.handle(.control(19))
        XCTAssertEqual(try TerminalAppearance.load(from: file).preset, "amber")
        XCTAssertEqual(
            try TerminalAppearance.load(from: file).roles[.activeSelection]?.foreground, .red)
    }

    func testNamedPaletteEditsSaveAsAndDeletionRemainDrafted() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let file = directory.appendingPathComponent("appearance.json")
        let app = try TerminalApplication(
            client: client,
            journal: RecoveryJournal(
                url: directory.appendingPathComponent("pending.json"), socket: "/fixture"),
            itemsOnly: true, appearanceURL: file)

        app.handle(.modified(.text(","), .command))
        for _ in 0..<6 { app.handle(.tab) }
        app.handle(.control(21))
        app.handle(.text("red"))
        XCTAssertTrue(app.render(columns: 80, rows: 25).contains { $0.text.contains("modified") })
        app.handle(.function(5))
        app.handle(.text("Moss"))
        app.handle(.function(8))
        let copied = try TerminalAppearance.load(from: file)
        XCTAssertEqual(copied.palette(namedOrID: "Blue")?.roles[.activeSelection]?.foreground, .brightWhite)
        XCTAssertEqual(copied.palette(namedOrID: "Moss")?.roles[.activeSelection]?.foreground, .red)

        let deleting = try TerminalApplication(
            client: client,
            journal: RecoveryJournal(
                url: directory.appendingPathComponent("pending-2.json"), socket: "/fixture"),
            itemsOnly: true, appearanceURL: file)
        deleting.handle(.modified(.text(","), .command))
        deleting.handle(.function(6))
        XCTAssertTrue(deleting.render(columns: 48, rows: 12).contains { $0.text.contains("Custom") })
        deleting.handle(.escape)
        XCTAssertEqual(
            try TerminalAppearance.load(from: file).preset,
            try XCTUnwrap(copied.palette(namedOrID: "Moss")).id)

        deleting.handle(.modified(.text(","), .command))
        deleting.handle(.function(6))
        deleting.handle(.control(19))
        let removed = try TerminalAppearance.load(from: file)
        XCTAssertEqual(removed.preset, TerminalAppearance.customPresetID)
        XCTAssertNil(removed.palette(namedOrID: "Moss"))
    }

    func testPopupFramesRemainNeutralWhenInteriorIsSelected() {
        var popup = ScreenLine.popup(
            "│focused│", over: String(repeating: " ", count: 16), column: 3, boxWidth: 9, width: 16,
            style: .menuSelection)
        popup.selectionColumns = [3..<12]
        let cells = TerminalANSI.cells(popup, columns: 16)
        XCTAssertEqual(cells[3].style, .menu)
        XCTAssertEqual(cells[11].style, .menu)
        XCTAssertEqual(cells[4].style, .textSelection)
        let ansi = TerminalANSI.line(popup, columns: 16, appearance: .preset("amber"))
        XCTAssertTrue(ansi.contains(TerminalAppearance.preset("amber").sgr(for: .menuSurface)))
    }

    func testAppearanceGroupsCursorFieldsBeforeRolesAndKeepsCompactControls() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let journal = RecoveryJournal(
            url: directory.appendingPathComponent("pending.json"), socket: "/fixture")
        let file = directory.appendingPathComponent("appearance.json")
        let app = try TerminalApplication(
            client: client, journal: journal, itemsOnly: true, appearanceURL: file)

        app.handle(.modified(.text(","), .command))
        let originalForeground = try TerminalAppearance.load(from: file).roles[.activeSelection]?.foreground
        let compact = app.render(columns: 48, rows: 12).map(\.text).joined(separator: "\n")
        XCTAssertTrue(compact.contains("Appearance preset"))
        XCTAssertTrue(compact.contains("F5 Save as"))
        XCTAssertTrue(compact.contains("F8 Save"))
        XCTAssertTrue(compact.contains("F9 Cancel"))

        let regular = app.render(columns: 80, rows: 25).map(\.text).joined(separator: "\n")
        XCTAssertTrue(regular.contains("Cursor"))
        XCTAssertTrue(regular.contains("Effects"))
        XCTAssertTrue(regular.contains("Drop shadows"))
        XCTAssertTrue(regular.contains("Interface colors"))
        XCTAssertLessThan(
            try XCTUnwrap(regular.range(of: "Cursor blink")?.lowerBound),
            try XCTUnwrap(regular.range(of: "Active selection")?.lowerBound))

        // Preset, layout, shape and cursor colour precede blink; Effects then precedes roles.
        for _ in 0..<4 { app.handle(.tab) }
        app.handle(.down)
        app.handle(.control(19))
        let blinkOnly = try TerminalAppearance.load(from: file)
        XCTAssertTrue(blinkOnly.cursor.blink)
        XCTAssertEqual(blinkOnly.roles[.activeSelection]?.foreground, originalForeground)

        app.handle(.modified(.text(","), .command))
        for _ in 0..<6 { app.handle(.tab) }
        let colorCompact = app.render(columns: 48, rows: 12).map(\.text).joined(separator: "\n")
        XCTAssertTrue(colorCompact.contains("#RRGGBB"))
        app.handle(.control(21))
        app.handle(.text("red"))
        app.handle(.control(19))
        let grouped = try TerminalAppearance.load(from: file)
        XCTAssertTrue(grouped.cursor.blink)
        XCTAssertEqual(grouped.roles[.activeSelection]?.foreground, .red)
    }

    func testAppearanceSectionHeadersIgnoreMouseAndColorHexRoundTrips() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let journal = RecoveryJournal(
            url: directory.appendingPathComponent("pending.json"), socket: "/fixture")
        let file = directory.appendingPathComponent("appearance.json")
        let app = try TerminalApplication(
            client: client, journal: journal, itemsOnly: true, appearanceURL: file)

        app.handle(.modified(.text(","), .command))
        _ = app.render(columns: 80, rows: 25)
        let cursorSection = TerminalMouseEvent(
            kind: .press, button: .left, column: 4, row: 4, modifiers: [])
        app.handleMouse(cursorSection)
        app.handleMouse(.init(kind: .release, button: .left, column: 4, row: 4, modifiers: []))
        app.handle(.down)
        app.handle(.control(19))
        XCTAssertEqual(try TerminalAppearance.load(from: file).preset, "amber")

        let editor = try TerminalApplication(
            client: client, journal: journal, itemsOnly: true, appearanceURL: file)
        editor.handle(.modified(.text(","), .command))
        _ = editor.render(columns: 80, rows: 25)
        // At 80×25 the first role foreground begins at column 27.  Click the first glyph,
        // rather than the label separator, so this catches a one-cell hit/caret mismatch.
        editor.handleMouse(.init(kind: .press, button: .left, column: 27, row: 11, modifiers: []))
        editor.handleMouse(.init(kind: .release, button: .left, column: 27, row: 11, modifiers: []))
        let clicked = try XCTUnwrap(
            editor.render(columns: 80, rows: 25).first { $0.text.contains("Active selection") })
        XCTAssertEqual(clicked.cursorColumn, 27)
        let colored = editor.render(columns: 80, rows: 25).map(\.text).joined(separator: "\n")
        XCTAssertTrue(colored.contains("Name or #RRGGBB"))
        editor.handle(.control(21))
        editor.handle(.text("#12AbEF"))
        let hexLine = try XCTUnwrap(
            editor.render(columns: 80, rows: 25).first { $0.text.contains("#12AbEF") })
        let hexRange = try XCTUnwrap(hexLine.text.range(of: "#12AbEF"))
        XCTAssertEqual(
            hexLine.cursorColumn,
            hexLine.text.distance(from: hexLine.text.startIndex, to: hexRange.upperBound))
        editor.handle(.control(19))
        let value = try TerminalAppearance.load(from: file)
        XCTAssertEqual(value.roles[.activeSelection]?.foreground.rawValue, "#12abef")
        XCTAssertTrue(value.sgr(for: .activeSelection).contains("38;2;18;171;239"))
    }

    func testTypingPresetNamesRetainsCustomAcrossSaveAndRestart() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let journal = RecoveryJournal(
            url: directory.appendingPathComponent("pending.json"), socket: "/fixture")
        let file = directory.appendingPathComponent("appearance.json")
        let app = try TerminalApplication(
            client: client, journal: journal, itemsOnly: true, appearanceURL: file)
        app.handle(.modified(.text(","), .command))
        for _ in 0..<6 { app.handle(.tab) }
        app.handle(.control(21))
        app.handle(.text("red"))
        for _ in 0..<6 { app.handle(.backTab) }
        app.handle(.control(21))
        app.handle(.text("Blue"))
        app.handle(.control(19))
        XCTAssertEqual(try TerminalAppearance.load(from: file).preset, "blue")

        let reopened = try TerminalApplication(
            client: client, journal: journal, itemsOnly: true, appearanceURL: file)
        reopened.handle(.modified(.text(","), .command))
        reopened.handle(.control(21))
        reopened.handle(.text("Custom"))
        reopened.handle(.control(19))
        let restored = try TerminalAppearance.load(from: file)
        XCTAssertEqual(restored.preset, TerminalAppearance.customPresetID)
        XCTAssertEqual(restored.roles[.activeSelection]?.foreground, .red)
    }

    func testViewSelectorMenuRoutesColorsToTheSameLocalAppearanceForm() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let app = try TerminalApplication(
            client: client,
            journal: RecoveryJournal(
                url: directory.appendingPathComponent("pending.json"), socket: "/fixture"),
            appearanceURL: directory.appendingPathComponent("appearance.json"))
        app.handle(.function(10))
        app.handle(.left)  // File -> Tractanda
        app.handle(.enter)  // Settings / Colors…
        XCTAssertTrue(
            app.render(columns: 80, rows: 25).contains { $0.text.contains("Settings / Appearance") })
    }

    func testItemEditorIsModalAndUsesItsOwnSaveCancelFunctionKeys() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let original = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("Background item")], operationID: "seed")
        )
        .revision
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let app = try TerminalApplication(
            client: client,
            journal: RecoveryJournal(
                url: directory.appendingPathComponent("pending.json"), socket: "/fixture"),
            itemsOnly: true)
        app.handle(.function(2))
        let modal = app.render(columns: 80, rows: 25)
        XCTAssertTrue(modal.contains { $0.text.contains("Edit item") })
        XCTAssertTrue(modal.contains { $0.text.contains("Background item") })
        XCTAssertTrue(modal.contains { $0.text.contains("F8 Save") && $0.text.contains("F9 Cancel") })
        app.handle(.text(" changed"))
        app.handle(.function(9))
        XCTAssertEqual(try store.get(original.itemID).revisionID, original.revisionID)
        app.handle(.function(2))
        app.handle(.text(" saved"))
        app.handle(.function(8))
        XCTAssertEqual(try store.history(original.itemID).count, 2)
        XCTAssertEqual(try store.get(original.itemID).fields["subject"], .text("Background item saved"))
    }

    func testItemBodyCaretRemainsVisibleAfterShrinkingThePanel() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        _ = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: [
                    "subject": .text("Long note"),
                    "body": .text((0..<50).map { "Line \($0)" }.joined(separator: "\n")),
                ],
                operationID: "seed"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let app = try TerminalApplication(
            client: client,
            journal: RecoveryJournal(
                url: directory.appendingPathComponent("pending.json"), socket: "/fixture"),
            itemsOnly: true)
        app.handle(.function(2))
        app.handle(.tab)
        for (width, height) in [(80, 25), (48, 12), (132, 35)] {
            let screen = app.render(columns: width, rows: height).map(\.text).joined(separator: "\n")
            XCTAssertTrue(screen.contains("Line 49 "), "\(width)×\(height): \(screen)")
            XCTAssertTrue(screen.contains("F8 Save") && screen.contains("F9 Cancel"))
        }
    }

    func testFragmentedKeysUnicodeAndPasteAreNotCommands() {
        var input = TerminalInput()
        XCTAssertEqual(input.receive([27]), [])
        XCTAssertEqual(input.receive([91]), [])
        XCTAssertEqual(input.receive([65]), [.up])
        let unicode = Array("文🙂".utf8)
        XCTAssertEqual(input.receive(Array(unicode.prefix(2))), [])
        XCTAssertEqual(input.receive(Array(unicode.dropFirst(2))), [.text("文"), .text("🙂")])
        XCTAssertEqual(input.receive(Array("\u{1b}[200~n\r\u{13}q\u{1b}[20".utf8)), [])
        XCTAssertEqual(input.receive(Array("1~".utf8)), [.paste("n\r\u{13}q")])
        XCTAssertEqual(input.receive([27]), [])
        XCTAssertEqual(input.receive([], expireEscape: true), [.escape])
        XCTAssertEqual(input.receive(Array("\u{1b}[200~".utf8)), [])
        for _ in 0..<17 { XCTAssertEqual(input.receive(Array(repeating: 113, count: 4096)), []) }
        XCTAssertEqual(input.receive(Array("\u{1b}[201~r".utf8)), [.ignored, .text("r")])
    }

    func testCursorLayoutsKeepGlyphsStableAndMapGapCells() {
        var buffer = TextBuffer("ab🙂")
        buffer.placeCursor(at: 1)
        let native = buffer.displayLines(columns: 12, cursorLayout: .native).first!
        XCTAssertEqual(native.text, "ab🙂")
        XCTAssertEqual(native.cursorColumn, 1)
        XCTAssertEqual(native.offsets, [0, 1, 2, 2, 3])
        let gap = buffer.displayLines(columns: 12, cursorLayout: .gap).first!
        XCTAssertEqual(gap.text, "a b🙂")
        XCTAssertEqual(gap.cursorColumn, 1)
        XCTAssertEqual(gap.offsets, [0, 1, 1, 2, 2, 3])
        buffer = TextBuffer("abc")
        buffer.placeCursor(at: 3)
        XCTAssertEqual(buffer.displayLines(columns: 3, cursorLayout: .native).map(\.cursorColumn), [nil, 0])
        buffer = TextBuffer("ab🙂")
        buffer.placeCursor(at: 2)
        XCTAssertEqual(
            buffer.displayLines(columns: 3, cursorLayout: .native).map(\.text), ["ab", "🙂"])
        XCTAssertEqual(buffer.displayLines(columns: 3, cursorLayout: .native).map(\.cursorColumn), [nil, 0])
        buffer = TextBuffer("abc\nx")
        buffer.placeCursor(at: 3)
        XCTAssertEqual(
            buffer.displayLines(columns: 3, cursorLayout: .native).map(\.text), ["abc", "x"])
    }

    func testCursorProtocolRepliesAreConsumedAndAppearanceLegacyDefaults() throws {
        var input = TerminalInput()
        XCTAssertEqual(input.receive(Array("\u{1b}]12;rgb:1111/2222/3333\u{07}".utf8)), [])
        XCTAssertEqual(input.takeTerminalReplies().count, 1)
        XCTAssertEqual(input.receive(Array("\u{1b}]12;rgb:1/2/3\u{1b}\\x".utf8)), [.text("x")])
        XCTAssertEqual(input.takeTerminalReplies().count, 1)
        XCTAssertEqual(input.receive(Array("\u{1b}]12;rgb:1/2/3\u{1b}".utf8)), [])
        XCTAssertEqual(input.receive(Array("\\y".utf8)), [.text("y")])
        XCTAssertEqual(input.takeTerminalReplies().count, 1)
        XCTAssertEqual(input.receive(Array("\u{1b}]12;".utf8) + Array(repeating: 120, count: 1_025)), [])
        XCTAssertEqual(input.receive([7, 122]), [.text("z")])
        XCTAssertTrue(input.takeTerminalReplies().isEmpty)
        XCTAssertEqual(
            TerminalCursorProtocol.parse("\u{1b}P1$r6 q\u{1b}\\"),
            .init(style: 6, color: nil))
        XCTAssertEqual(TerminalCursorProtocol.parse("\u{1b}P1$r99 q\u{1b}\\").style, nil)
        XCTAssertEqual(TerminalCursorProtocol.parse("\u{1b}]12;unsafe\u{07}").color, nil)
        XCTAssertTrue(TerminalCursorProtocol.apply(.init()).contains("[6 q"))
        XCTAssertTrue(TerminalCursorProtocol.restore(style: nil, color: nil).contains("]112"))
        var legacy = TerminalAppearance.preset("blue")
        legacy.version = 1
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "cursor")
        let appearance = try JSONDecoder().decode(
            TerminalAppearance.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(appearance.cursor, CursorPreferences())
    }

    func testGraphemeEditsAndControlSanitization() {
        var buffer = TextBuffer("Cafe")
        buffer.handle(.text("\u{301}"))
        XCTAssertEqual(buffer.cursor, 4)
        buffer.handle(.backspace)
        XCTAssertEqual(buffer.text, "Caf")
        buffer.handle(.text("👩🏽‍💻"))
        buffer.handle(.backspace)
        XCTAssertEqual(buffer.text, "Caf")
        XCTAssertFalse(TerminalText.safe("\u{1b}]52;c;secret\u{7}").contains("\u{1b}"))
        XCTAssertFalse(TerminalText.safe("\u{9b}31m\u{202e}evil").contains("\u{202e}"))
        buffer = TextBuffer("one\ntwo\nthree")
        buffer.handle(.home)
        buffer.handle(.up, multiline: true)
        buffer.handle(.text("X"), multiline: true)
        XCTAssertEqual(buffer.text, "one\nXtwo\nthree")
        XCTAssertEqual(TerminalText.width("👩🏽‍💻"), 2)
        XCTAssertEqual(TerminalText.fit("Hello", columns: 3), "Hel")
    }

    func testDraftPreservesUnknownFieldsAndUsesOneGuardedRevision() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let original = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: ["subject": .text("Original"), "foreign.metadata": .integer(Int64.max)],
                operationID: "seed")
        ).revision
        var draft = try ItemDraft(base: original)
        XCTAssertNil(draft.request())
        draft.subject = TextBuffer("Edited")
        draft.body = TextBuffer("Body changed too")
        draft.className = TextBuffer("EmailMessageItem")
        let request = try XCTUnwrap(draft.request())
        XCTAssertEqual(request.expectedRevisionID, original.revisionID)
        XCTAssertEqual(request.action, .retype)
        XCTAssertNil(request.changes["foreign.metadata"])
        let changed = try store.commit(request).revision
        XCTAssertEqual(changed.itemID, original.itemID)
        XCTAssertEqual(changed.fields["foreign.metadata"], .integer(Int64.max))
        XCTAssertEqual(try store.history(original.itemID).count, 2)
        var concurrent = request
        concurrent.operationID = "other-edit"
        XCTAssertThrowsError(try store.commit(concurrent)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "revisionConflict")
        }
        XCTAssertTrue(try store.commit(request).wasReplayed)
    }

    func testClassPickerOnlyOffersConcretePublicTypesAndPreservesUnknownExistingClass() throws {
        XCTAssertTrue(ItemDraft.supportedClassIDs.contains("Item"))
        XCTAssertFalse(ItemDraft.supportedClassIDs.contains("PersonalStateItem"))
        XCTAssertFalse(ItemDraft.supportedClassIDs.contains("AccessConfigurationItem"))
        XCTAssertFalse(ItemDraft.supportedClassIDs.contains("NoteItem"))
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let unknown = try store.commit(
            CommitRequest(
                classID: "org.example.FutureItem", changes: ["subject": .text("Future")],
                operationID: "future")
        ).revision
        var draft = try ItemDraft(base: unknown)
        XCTAssertEqual(draft.className.text, "org.example.FutureItem")
        XCTAssertNil(draft.request())
        draft.cycleClass(forward: true)
        XCTAssertTrue(ItemDraft.supportedClassIDs.contains(draft.className.text))
        XCTAssertEqual(draft.request()?.action, .retype)
        var category = try ItemDraft(isCategory: true)
        category.cycleClass(forward: true)
        XCTAssertEqual(category.className.text, "Item")
    }

    func testResizingPreservesDraftFocusSelectionAndNativeWorkflow() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        let journal = RecoveryJournal(
            url: directory.appendingPathComponent("pending.json"), socket: "/fixture")
        let app = try TerminalApplication(client: client, journal: journal, itemsOnly: true)
        app.handle(.text("n"))
        app.handle(.text("Resized café 文"))
        app.handle(.tab)
        app.handle(.paste("A multiline\ndraft 👩🏽‍💻"))
        for (width, height) in [(80, 25), (132, 40), (52, 14), (30, 8), (160, 48), (80, 25)] {
            let frame = app.render(columns: width, rows: height)
            XCTAssertEqual(frame.count, height)
            if width >= 48 && height >= 12 {
                XCTAssertTrue(frame.contains { $0.text.contains("Body / note") })
                XCTAssertTrue(frame.contains { $0.text.contains("draft 👩🏽‍💻") })
            } else {
                app.handle(.text("SHOULD NOT EDIT"))
            }
        }
        app.handle(.control(19))
        let items = try store.candidates()
        XCTAssertEqual(items.count, 1)
        let saved = try XCTUnwrap(items.first)
        XCTAssertEqual(saved.fields["subject"], .text("Resized café 文"))
        XCTAssertEqual(saved.fields["body"], .text("A multiline\ndraft 👩🏽‍💻"))
        XCTAssertEqual(try store.history(saved.itemID).count, 1)
        XCTAssertNil(try journal.load())
        app.handle(.function(2))
        app.handle(.text(" revised"))
        _ = app.render(columns: 140, rows: 40)
        app.handle(.control(19))
        XCTAssertEqual(try store.history(saved.itemID).count, 2)
        XCTAssertEqual(try store.get(saved.itemID).fields["subject"], .text("Resized café 文 revised"))
    }

    func testLostResponseRecoverySurvivesClientRestart() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        var loseNextCommit = true
        let client = ItemClient(transport: { data in
            let response = service.handle(data, peerUID: store.ownerUID)
            let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let calls = envelope["methodCalls"] as! [[Any]]
            if calls[0][0] as? String == "TractandaItem/commit" && loseNextCommit {
                loseNextCommit = false
                throw TractandaError("transportError", "Lost response after commit")
            }
            return response
        })
        let journal = RecoveryJournal(
            url: directory.appendingPathComponent("pending.json"), socket: "/fixture")
        var app: TerminalApplication? = try TerminalApplication(
            client: client, journal: journal, itemsOnly: true)
        app!.handle(.text("n"))
        app!.handle(.text("Saved once"))
        app!.handle(.control(19))
        let request = try XCTUnwrap(journal.load())
        XCTAssertEqual(try store.candidates().count, 1)
        app = nil
        app = try TerminalApplication(client: client, journal: journal, itemsOnly: true)
        _ = app!.render(columns: 120, rows: 40)
        XCTAssertEqual(try journal.load(), request)
        app!.handle(.text("r"))
        XCTAssertNil(try journal.load())
        XCTAssertEqual(try store.candidates().count, 1)
        XCTAssertEqual(try store.history(store.candidates()[0].itemID).count, 1)
    }

    func testRecoveryFileExcludesConcurrentClientsAndUnlocksOnExit() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pending.json")
        var first: RecoveryJournal? = RecoveryJournal(url: url, socket: "/fixture")
        XCTAssertNil(try first!.load())
        let second = RecoveryJournal(url: url, socket: "/fixture")
        XCTAssertThrowsError(try second.load()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "recoveryFileBusy")
        }
        let separate = RecoveryJournal(
            url: directory.appendingPathComponent("separate.json"), socket: "/fixture")
        XCTAssertNil(try separate.load())
        let request = CommitRequest(
            classID: "Item", changes: ["subject": .text("Recover me")], operationID: "recover")
        try first!.save(request)
        XCTAssertThrowsError(try second.save(request))
        XCTAssertEqual(try first!.load(), request)
        first = nil
        XCTAssertEqual(try second.load(), request)
        try second.clear()
        XCTAssertNil(try second.load())
    }

    func testDefaultRecoveryJournalsUsePersistentExclusiveSlotsAndRecoverAlternates() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = RecoveryJournal.defaultURL(socket: "/fixture", stateDirectory: directory)
        XCTAssertEqual(
            RecoveryJournal.defaultViewPreferencesURL(for: primary).path,
            primary.deletingPathExtension().appendingPathExtension("views.json").path)

        var first: RecoveryJournal? = try RecoveryJournal.claimDefault(
            primaryURL: primary, socket: "/fixture")
        XCTAssertEqual(first!.url, primary)
        XCTAssertNil(try first!.load())

        var alternate: RecoveryJournal? = try RecoveryJournal.claimDefault(
            primaryURL: primary, socket: "/fixture")
        XCTAssertNotEqual(alternate!.url, primary)
        XCTAssertEqual(alternate!.url.lastPathComponent, "2f66697874757265.slot-1.json")
        let request = CommitRequest(
            classID: "Item", changes: ["subject": .text("Recover alternate")], operationID: "alternate")
        try alternate!.save(request)
        alternate = nil

        // The still-live primary keeps its lock, so a later default launch locates the
        // unlocked alternate's pending operation instead of allocating another empty slot.
        let recovered = try RecoveryJournal.claimDefault(primaryURL: primary, socket: "/fixture")
        XCTAssertEqual(recovered.url.lastPathComponent, "2f66697874757265.slot-1.json")
        XCTAssertEqual(try recovered.load(), request)
        try recovered.clear()
        first = nil
    }

    func testUnsafeRecoveryLockIsNotReportedAsBusy() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pending.json")
        try FileManager.default.createSymbolicLink(
            atPath: url.appendingPathExtension("lock").path, withDestinationPath: "missing-lock")
        let journal = RecoveryJournal(url: url, socket: "/fixture")
        XCTAssertThrowsError(try journal.load()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "recoveryFileAccess")
        }
    }

    func testDefaultRecoveryJournalReportsExistingIdentityMismatch() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = RecoveryJournal.defaultURL(socket: "/fixture", stateDirectory: directory)
        let alternate = primary.deletingPathExtension().appendingPathExtension("slot-1")
            .appendingPathExtension(
                "json")
        let mismatched = RecoveryJournal(url: alternate, socket: "/different")
        try mismatched.save(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("Wrong connection")], operationID: "mismatch")
        )
        mismatched.releaseLock()

        XCTAssertThrowsError(try RecoveryJournal.claimDefault(primaryURL: primary, socket: "/fixture")) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "recoveryIdentity")
        }
    }

    func testCumulativeCategoriesDecisionsAndSavedView() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        func category(_ name: String, _ rule: String) throws -> Revision {
            try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text(name),
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text(rule),
                        ]),
                    ], operationID: Identifier.make())
            ).revision
        }
        let family = try category("Family", "subject ==[c] \"*family*\"")
        let chess = try category("Chess", "subject ==[c] \"*chess*\"")
        let workspace = Workspace(client: client)
        try workspace.enter(family)
        try workspace.enter(chess)
        XCTAssertThrowsError(try workspace.enter(family))
        var draft = try ItemDraft(categories: workspace.categoryPath.map(\.itemID))
        draft.subject = TextBuffer("An explicit exception")
        let item = try client.commit(XCTUnwrap(draft.request())).revision
        try workspace.refresh(position: 0)
        XCTAssertEqual(workspace.items.map(\.itemID), [item.itemID])
        let view = try client.commit(workspace.viewRequest(name: "Family chess")).revision
        // A saved-view item is still an item: its own title can match the category rules.
        XCTAssertEqual(
            Set(try client.revisions(viewID: view.itemID).map(\.itemID)), [item.itemID, view.itemID])
        let excluded = try client.commit(workspace.assignment("exclude", item: item, category: chess))
            .revision
        XCTAssertEqual(try client.revisions(viewID: view.itemID).map(\.itemID), [view.itemID])
        _ = try client.commit(workspace.assignment(nil, item: excluded, category: chess))
        XCTAssertEqual(try client.revisions(viewID: view.itemID).map(\.itemID), [view.itemID])
        let opened = Workspace(client: client)
        try opened.openView(view)
        XCTAssertEqual(opened.categoryPath.map(\.itemID), [family.itemID, chess.itemID])
        let journal = RecoveryJournal(
            url: directory.appendingPathComponent("view-pending.json"), socket: "/fixture")
        let app = try TerminalApplication(
            client: client, journal: journal, viewID: view.itemID, itemsOnly: true)
        app.handle(.text("n"))
        app.handle(.text("Captured in saved view"))
        app.handle(.control(19))
        XCTAssertEqual(try client.revisions(viewID: view.itemID).count, 2)
        try opened.leaveCategory()
        XCTAssertNil(opened.view)
        XCTAssertEqual(opened.categoryPath.map(\.itemID), [family.itemID])
        XCTAssertTrue(opened.items.contains { $0.itemID == item.itemID })
    }
}
