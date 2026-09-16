import Foundation
import TractandaCore
import XCTest

@testable import TractandaTUI

final class MouseTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let store: ItemStore
        let service: ItemService
        var client: ItemClient {
            ItemClient(transport: { self.service.handle($0, peerUID: self.store.ownerUID) })
        }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "trac-mouse-" + Identifier.make())
            store = try ItemStore(root: root.appendingPathComponent("store"))
            service = ItemService(store: store)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func item(_ title: String, fields: [String: ItemValue] = [:]) throws -> Revision {
            try client.commit(
                CommitRequest(
                    classID: "Item", changes: fields.merging(["subject": .text(title)]) { _, new in new },
                    operationID: Identifier.make())
            ).revision
        }
        func category(_ title: String, parent: Revision? = nil) throws -> Revision {
            var fields: [String: ItemValue] = [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("subject == \"work\""),
                ])
            ]
            if let parent { fields["categoryParents"] = .list([.reference(ItemReference(parent.itemID))]) }
            return try item(title, fields: fields)
        }
        func app(mouse: Bool = true, client: ItemClient? = nil) throws -> TerminalApplication {
            try TerminalApplication(
                client: client ?? self.client,
                journal: RecoveryJournal(
                    url: root.appendingPathComponent("pending.json"), socket: "/fixture"), itemsOnly: true,
                mouseEnabled: mouse
            )
        }
    }
    private func frame(_ app: TerminalApplication, width: Int = 132, height: Int = 30) -> [ScreenLine] {
        app.render(columns: width, rows: height)
    }
    private func screen(_ app: TerminalApplication) -> String {
        frame(app).map(\.text).joined(separator: "\n")
    }
    private func point(_ frame: [ScreenLine], matching predicate: (MouseTarget) -> Bool) throws -> (Int, Int)
    {
        for (row, line) in frame.enumerated() {
            if let hit = line.hits.last(where: { predicate($0.target) }), !hit.columns.isEmpty {
                return (hit.columns.lowerBound + (hit.columns.count > 8 ? 7 : 0), row)
            }
        }
        XCTFail("Missing mouse target")
        throw TractandaError("test", "Missing target")
    }
    private func event(
        _ app: TerminalApplication, _ kind: TerminalMouseEvent.Kind, at point: (Int, Int),
        time: Double = 1, modifiers: KeyModifiers = [], button: TerminalMouseEvent.Button = .left
    ) {
        app.handleMouse(
            .init(kind: kind, button: button, column: point.0, row: point.1, modifiers: modifiers), at: time)
    }
    private func click(
        _ app: TerminalApplication, at point: (Int, Int), time: Double = 1, modifiers: KeyModifiers = []
    ) {
        event(app, .press, at: point, time: time, modifiers: modifiers)
        event(app, .release, at: point, time: time + 0.01, modifiers: modifiers)
    }
    private func control(_ app: TerminalApplication, _ command: TUICommand, time: Double = 1) throws {
        let location = try point(frame(app)) { $0 == .command(command) || $0 == .menuCommand(command) }
        click(app, at: location, time: time)
    }

    func testSGRAndLegacyMouseAreIncrementalBoundedAndNeverBecomeTyping() {
        let bytes = Array("\u{1b}[<0;400;200M\u{1b}[<0;400;200m".utf8)
        for split in 1..<bytes.count {
            var input = TerminalInput()
            let decoded = input.receive(Array(bytes[..<split])) + input.receive(Array(bytes[split...]))
            XCTAssertEqual(
                decoded,
                [
                    .mouse(.init(kind: .press, button: .left, column: 399, row: 199, modifiers: [])),
                    .mouse(.init(kind: .release, button: .left, column: 399, row: 199, modifiers: [])),
                ])
        }
        var input = TerminalInput()
        XCTAssertEqual(input.receive([27, 91, 77, 32]), [])
        XCTAssertFalse(input.isAwaitingEscape)
        XCTAssertEqual(input.receive([], expireEscape: true), [])
        XCTAssertEqual(
            input.receive([110, 113]),
            [.mouse(.init(kind: .press, button: .left, column: 77, row: 80, modifiers: []))])
        XCTAssertEqual(
            input.receive([27, 27, 91, 77, 35, 110, 113]),
            [.escape, .mouse(.init(kind: .release, button: .none, column: 77, row: 80, modifiers: []))])
        XCTAssertEqual(
            input.receive(Array("\u{1b}[<28;1;1M\u{1b}[<32;2;2M\u{1b}[<64;3;3M\u{1b}[<67;3;3M".utf8)),
            [
                .mouse(
                    .init(
                        kind: .press, button: .left, column: 0, row: 0,
                        modifiers: [.shift, .option, .control])),
                .mouse(.init(kind: .drag, button: .left, column: 1, row: 1, modifiers: [])),
                .mouse(.init(kind: .scrollUp, button: .left, column: 2, row: 2, modifiers: [])),
                .mouse(.init(kind: .scrollRight, button: .none, column: 2, row: 2, modifiers: [])),
            ])
        for value in [
            "<0;0;1M", "<0;1;-1M", "<128;1;1M", "<64;1;1m", "<96;1;1M", "<0;99999999999999999999;1M",
        ] {
            XCTAssertEqual(input.receive(Array(("\u{1b}[" + value).utf8)), [.ignored])
        }
        let report = "\u{1b}[<0;5;5M"
        XCTAssertEqual(input.receive(Array(("\u{1b}[200~" + report + "\u{1b}[201~").utf8)), [.paste(report)])
        XCTAssertEqual(input.receive(Array("\u{1b}[<0;12;".utf8)), [])
        XCTAssertEqual(input.receive([], expireEscape: true), [])
        XCTAssertEqual(input.receive(Array("12Mq".utf8)).last, .text("q"))
    }

    func testSingleClickSelectsDoubleClickReadsAndMarkingDoesNotWrite() throws {
        let f = try Fixture()
        let items = try (0..<4).map { try f.item("Mouse item \($0)") }
        let app = try f.app()
        let original = f.store.state
        let location = try point(frame(app)) {
            if case .browserRow(_, let key) = $0 { key.hasPrefix(items[2].itemID) } else { false }
        }
        click(app, at: location)
        XCTAssertFalse(screen(app).contains("Item / immutable revision"))
        click(app, at: location, time: 1.2)
        XCTAssertTrue(screen(app).contains(items[2].itemID))
        app.handle(.escape)
        let marker = try point(frame(app)) {
            if case .browserMark(_, let key) = $0 { key.hasPrefix(items[2].itemID) } else { false }
        }
        click(app, at: marker, time: 2)
        XCTAssertTrue(screen(app).contains("1 marked"))
        click(app, at: marker, time: 3)
        XCTAssertTrue(screen(app).contains("0 marked"))
        XCTAssertEqual(f.store.state, original)
    }

    func testSelectingInsideScrolledListKeepsRowUnderMouseAndWheelLoadsPages() throws {
        let f = try Fixture()
        for index in 0..<80 { _ = try f.item(String(format: "Item %03d", index)) }
        let app = try f.app()
        app.handle(.end)
        var displayed = frame(app, width: 80, height: 25)
        let row = 7
        let target = try XCTUnwrap(displayed[row].hits.first?.target)
        guard case .browserRow = target else { return XCTFail("Expected a scrolled item row") }
        click(app, at: (12, row))
        displayed = frame(app, width: 80, height: 25)
        XCTAssertEqual(displayed[row].hits.first?.target, target, "Clicking must not realign the viewport")
        click(app, at: (12, row), time: 1.2)
        XCTAssertTrue(screen(app).contains("Item / immutable revision"))
        app.handle(.escape)
        app.handle(.end)
        _ = frame(app)
        event(app, .scrollDown, at: (15, 6))
        XCTAssertTrue(screen(app).contains("Previous page"))
        XCTAssertEqual(try f.store.candidates().count, 80)
    }

    func testMenusAndFunctionBarUseCommandsAndDoNotClickThroughOverlays() throws {
        let f = try Fixture()
        let app = try f.app()
        click(app, at: try point(frame(app)) { $0 == .function(10) })
        XCTAssertTrue(screen(app).contains("Command menu"))
        // Clicking where the underlying list would be only dismisses the popup.
        click(app, at: (110, 8), time: 2)
        XCTAssertFalse(screen(app).contains("Command menu"))
        click(app, at: try point(frame(app)) { $0 == .function(10) }, time: 3)
        try control(app, .newItem, time: 4)
        XCTAssertTrue(screen(app).contains("New item"))
        app.handle(.text("Created by menu"))
        let save = try point(frame(app)) { $0 == .command(.save) }
        click(app, at: save, time: 5)
        click(app, at: save, time: 5.2)  // No intervening display; ignore stale geometry after saving.
        XCTAssertEqual(try f.store.candidates().count, 1)
        XCTAssertEqual(try f.store.history(f.store.candidates()[0].itemID).count, 1)
    }

    func testDisabledMenuActionsAndMouseOffAreInertAndCanBeReenabledByKeyboard() throws {
        let f = try Fixture()
        let app = try f.app(mouse: false)
        let location = try point(frame(app)) { $0 == .function(10) }
        click(app, at: location)
        XCTAssertFalse(screen(app).contains("Command menu"))
        app.handle(.function(10))
        app.handle(.right)
        app.handle(.right)  // View
        _ = frame(app)
        // Mouse is still off, so choose Mouse On through the existing menu keyboard path.
        app.handle(.home)
        var attempts = 0
        while !screen(app).contains(">  Mouse: On") && attempts < 20 {
            app.handle(.down)
            attempts += 1
        }
        app.handle(.enter)
        click(app, at: try point(frame(app)) { $0 == .function(10) }, time: 2)
        let itemMenu = try point(frame(app)) { $0 == .menuGroup(5) }
        click(app, at: itemMenu, time: 3)
        let menuFrame = frame(app)
        XCTAssertTrue(menuFrame.contains { $0.text.contains("Mark done") })
        XCTAssertFalse(menuFrame.flatMap(\.hits).contains { $0.target == .menuCommand(.done) })
        XCTAssertTrue(try f.store.candidates().isEmpty)
    }

    func testMouseCaretAndDragRespectUnicodeAndWholeEditSave() throws {
        let f = try Fixture()
        let app = try f.app()
        app.handle(.text("n"))
        app.handle(.tab)
        app.handle(.paste("café 文 👩🏽‍💻"))
        app.handle(.modified(.up, .command))
        var displayed = frame(app)
        let body = try point(displayed) { if case .fieldText(1, _) = $0 { true } else { false } }
        let hit = try XCTUnwrap(displayed[body.1].hits.last)
        guard case .fieldText(_, let offsets) = hit.target else { return XCTFail() }
        let from = (hit.columns.lowerBound, body.1)
        let to = (hit.columns.lowerBound + (try XCTUnwrap(offsets.firstIndex(of: 4))), body.1)
        event(app, .press, at: from)
        event(app, .drag, at: to)
        event(app, .release, at: to)
        XCTAssertTrue(screen(app).contains("café"))
        app.handle(.control(3))
        displayed = frame(app)
        click(app, at: try point(displayed) { $0 == .field(0) }, time: 2)
        app.handle(.control(22))
        try control(app, .save, time: 3)
        let item = try XCTUnwrap(f.store.candidates().first)
        XCTAssertEqual(item.fields["subject"], .text("café"))
        XCTAssertEqual(item.fields["body"], .text("café 文 👩🏽‍💻"))
        XCTAssertEqual(try f.store.history(item.itemID).count, 1)
    }

    func testEditorWheelScrollsWithoutMovingCaretAndKeyboardRestoresCaretView() throws {
        let f = try Fixture()
        let app = try f.app()
        app.handle(.text("n"))
        app.handle(.text("Scroll draft"))
        app.handle(.tab)
        app.handle(.paste((0..<60).map { "Line \($0)" }.joined(separator: "\n")))
        app.handle(.modified(.up, .command))
        _ = frame(app, width: 80, height: 25)
        for _ in 0..<3 { event(app, .scrollDown, at: (20, 8)) }
        let after = frame(app, width: 80, height: 25).map(\.text).joined(separator: "\n")
        XCTAssertFalse(after.contains("Line 0"))
        XCTAssertTrue(
            after.contains("Line 9"), "Wheel events accumulated before repaint must all advance the viewport")
        app.handle(.text("X"))
        XCTAssertTrue(screen(app).contains("X Line 0"))
        app.handle(.control(19))
        XCTAssertTrue(try f.store.candidates()[0].fields["body"]!.string!.hasPrefix("XLine 0"))
    }

    func testCategoryExpandersDoubleClickAndSectionCheckboxesUseExistingSemantics() throws {
        let f = try Fixture()
        let parent = try f.category("Parent")
        let child = try f.category("Child", parent: parent)
        _ = try f.item("work")
        let app = try f.app()
        let before = f.store.state
        app.handle(.text("c"))
        let disclosure = try point(frame(app)) {
            if case .pickerDisclosure(_, let key) = $0 {
                key.contains(parent.itemID) && !key.contains(child.itemID)
            } else {
                false
            }
        }
        click(app, at: disclosure)
        XCTAssertFalse(screen(app).contains("Child"))
        click(app, at: disclosure, time: 2)
        let location = try point(frame(app)) {
            if case .pickerRow(_, let key) = $0 { key.contains(child.itemID) } else { false }
        }
        click(app, at: location, time: 3)
        _ = frame(app)
        click(app, at: location, time: 3.2)
        XCTAssertTrue(screen(app).contains("Parent ▾ / Child"))
        app.handle(.modified(.enter, .option))
        app.handle(.text("g"))
        click(app, at: try point(frame(app)) { if case .pickerToggle = $0 { true } else { false } }, time: 4)
        app.handle(.control(19))
        let triangle = try point(frame(app)) { if case .browserDisclosure = $0 { true } else { false } }
        click(app, at: triangle, time: 5)
        XCTAssertTrue(screen(app).contains("[+]"))
        XCTAssertEqual(f.store.state, before)
    }

    func testReleaseWithoutPressAndResizeDuringClickCannotActivateControls() throws {
        let f = try Fixture()
        let app = try f.app()
        let menu = try point(frame(app)) { $0 == .function(10) }
        event(app, .release, at: menu)
        XCTAssertFalse(screen(app).contains("Command menu"))
        event(app, .press, at: menu)
        _ = frame(app, width: 80, height: 25)
        event(app, .release, at: menu)
        XCTAssertFalse(screen(app).contains("Command menu"))
        for point in [(-1, 0), (9999, 1), (1, 9999)] { click(app, at: point) }
        _ = frame(app, width: 30, height: 8)
        click(app, at: (1, 7))
        XCTAssertTrue(try f.store.candidates().isEmpty)
    }

    func testMouseCannotBypassUnconfirmedEditRecovery() throws {
        let f = try Fixture()
        var sends = 0
        let client = ItemClient(transport: { data in
            let response = f.service.handle(data, peerUID: f.store.ownerUID)
            let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            if (request["methodCalls"] as! [[Any]])[0][0] as? String == "TractandaItem/commit" {
                sends += 1
                throw TractandaError("transportError", "Lost committed response")
            }
            return response
        })
        let app = try f.app(client: client)
        app.handle(.text("n"))
        app.handle(.text("Once"))
        app.handle(.control(19))
        XCTAssertTrue(screen(app).contains("Unconfirmed edit"))
        let save = try point(frame(app)) { $0 == .command(.save) }
        click(app, at: save)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(try f.store.candidates().count, 1)
    }

    func testDisplayMappingNeverSplitsEmojiOrCrashesOnSanitizedGraphemes() {
        var buffer = TextBuffer("café 文 👩🏽‍💻\n\u{0600}ع")
        for width in [1, 7, 20] {
            for line in buffer.displayLines(columns: width) {
                XCTAssertTrue(line.offsets.allSatisfy { (0...buffer.text.count).contains($0) })
                XCTAssertFalse(line.text.contains("\u{0600}"))
            }
        }
        let emojiIndex = Array(buffer.text).firstIndex(of: "👩🏽‍💻")!
        buffer.placeCursor(at: emojiIndex)
        buffer.handle(.text("X"), multiline: true)
        XCTAssertTrue(buffer.text.contains("X👩🏽‍💻"))
    }

    func testLearningMouseControlsUseGuardedFeedbackAndDoNotRepeatBufferedClicks() throws {
        let f = try Fixture()
        let category = try f.category("Club")
        for (text, label) in [
            ("chess board players", "include"), ("chess players tournament", "include"),
            ("garden vegetables soil", "exclude"), ("garden flowers soil", "exclude"),
        ] {
            _ = try f.item(text, fields: ["categoryOverrides": .object([category.itemID: .text(label)])])
        }
        let candidate = try f.item("chess tournament board")
        let app = try f.app()
        app.handle(.modified(.text("l"), .option))
        app.handle(.enter)
        try control(app, .trainLearning)
        XCTAssertTrue(screen(app).contains("ready"))
        let row = try point(frame(app)) {
            if case .learningRow(_, let key) = $0 { key.hasPrefix(candidate.itemID) } else { false }
        }
        click(app, at: row, time: 2)
        _ = frame(app)
        click(app, at: row, time: 2.2)
        XCTAssertTrue(screen(app).contains("Item / immutable revision"))
        XCTAssertEqual(try f.store.get(candidate.itemID), candidate)
        app.handle(.escape)
        let accept = try point(frame(app)) { $0 == .command(.acceptLearning) }
        click(app, at: accept, time: 3)
        click(app, at: accept, time: 3.2)
        XCTAssertEqual(try f.store.history(candidate.itemID).count, 2)
        XCTAssertEqual(
            try f.store.get(candidate.itemID).fields["categoryOverrides"]?.map?[category.itemID],
            .text("include"))
    }

    func testHoverReportsDecodeWithoutButtonsAndTrackingCanFollowMenuVisibility() {
        var input = TerminalInput()
        XCTAssertEqual(input.receive(Array("\u{1b}[<35;15;".utf8)), [])
        XCTAssertEqual(
            input.receive(Array("8M".utf8)),
            [
                .mouse(.init(kind: .hover, button: .none, column: 14, row: 7, modifiers: []))
            ])
        XCTAssertEqual(
            input.receive([27, 91, 77, 67, 47, 40]),
            [
                .mouse(.init(kind: .hover, button: .none, column: 14, row: 7, modifiers: []))
            ])
        XCTAssertEqual(
            input.receive(Array("\u{1b}[<39;15;8M\u{1b}[<35;15;8m".utf8)),
            [
                .mouse(.init(kind: .hover, button: .none, column: 14, row: 7, modifiers: .shift)), .ignored,
            ])
        XCTAssertTrue(TerminalMouseReporting.configure(enabled: true, hover: true).hasSuffix("\u{1b}[?1003h"))
        XCTAssertTrue(TerminalMouseReporting.configure(enabled: true).hasSuffix("\u{1b}[?1002h"))
        XCTAssertEqual(
            TerminalMouseReporting.configure(enabled: false, hover: true), TerminalMouseReporting.disable)
    }

    func testMenuHoverHighlightsWithoutExecutingAndEnterUsesHoveredEntry() throws {
        let f = try Fixture()
        let app = try f.app()
        let before = f.store.state
        app.handle(.function(10))
        let location = try point(frame(app)) { $0 == .menuCommand(.saveAs) }
        event(app, .hover, at: location, button: .none)
        XCTAssertTrue(screen(app).contains(">  Save view as"))
        XCTAssertTrue(screen(app).contains("Command menu"))
        XCTAssertEqual(f.store.state, before)
        app.handle(.enter)
        XCTAssertTrue(screen(app).contains("View name"))
        XCTAssertFalse(screen(app).contains("Command menu"))
        XCTAssertEqual(f.store.state, before, "Hover and opening a draft must not write an item")
    }

    func testHoverSwitchesMenuNamesWhileDisabledEntriesAndOutsideMotionStayInert() throws {
        let f = try Fixture()
        let app = try f.app()
        app.handle(.function(10))
        event(app, .hover, at: try point(frame(app)) { $0 == .menuGroup(5) }, button: .none)
        let displayed = frame(app)
        XCTAssertTrue(displayed[2].text.contains("Item"))
        let disabledRow = try XCTUnwrap(displayed.firstIndex { $0.text.contains("Mark done") })
        let disabledColumn = try XCTUnwrap(displayed[disabledRow].hits.first?.columns.lowerBound) + 5
        let before = displayed.map(\.text)
        event(app, .hover, at: (disabledColumn, disabledRow), button: .none)
        XCTAssertEqual(frame(app).map(\.text), before)
        event(app, .hover, at: (110, 20), button: .none)
        XCTAssertEqual(frame(app).map(\.text), before)
        event(app, .hover, at: try point(frame(app)) { $0 == .menuGroup(3) }, button: .none)
        app.handle(.end)
        event(app, .hover, at: try point(frame(app)) { $0 == .menuCommand(.mouseOff) }, button: .none)
        XCTAssertTrue(screen(app).contains(">  Mouse: Off"))
        event(app, .hover, at: try point(frame(app)) { $0 == .menuGroup(3) }, button: .none)
        XCTAssertTrue(
            screen(app).contains(">  Mouse: Off"), "Hovering the same menu name must not reset its selection")
        app.handle(.escape)
        let browser = frame(app).map(\.text)
        event(app, .hover, at: (20, 6), button: .none)
        XCTAssertEqual(frame(app).map(\.text), browser)
        click(app, at: try point(frame(app)) { $0 == .function(10) })
        XCTAssertTrue(screen(app).contains("Command menu"), "Hovering Mouse Off must not turn it off")
        XCTAssertTrue(try f.store.candidates().isEmpty)

        let disabledFixture = try Fixture()
        let disabledApp = try disabledFixture.app(mouse: false)
        disabledApp.handle(.function(10))
        let unchanged = frame(disabledApp).map(\.text)
        event(
            disabledApp, .hover, at: try point(frame(disabledApp)) { $0 == .menuCommand(.saveAs) },
            button: .none)
        XCTAssertEqual(frame(disabledApp).map(\.text), unchanged)
    }

    func testHoverKeepsScrolledMenuRowsUnderPointerAndDoesNotActivateOnDragRelease() throws {
        let f = try Fixture()
        let app = try f.app()
        app.handle(.function(10))
        app.handle(.right)
        app.handle(.right)
        app.handle(.end)
        let displayed = frame(app, width: 48, height: 12)
        let location = try point(displayed) { $0 == .menuCommand(.functionKeysAutomatic) }
        event(app, .hover, at: location, button: .none)
        var after = frame(app, width: 48, height: 12)
        XCTAssertTrue(after[location.1].text.contains(">✓ Function keys: Automatic"))
        XCTAssertEqual(try point(after) { $0 == .menuCommand(.functionKeysAutomatic) }.1, location.1)
        let twelve = try point(after) { $0 == .menuCommand(.functionKeysTwelve) }
        event(app, .press, at: twelve)
        event(app, .drag, at: location)
        after = frame(app, width: 48, height: 12)
        event(app, .release, at: location)
        XCTAssertTrue(screen(app).contains("Command menu"))
        app.handle(.escape)
        XCTAssertEqual(frame(app, width: 80).last?.segments.count, 20)
        XCTAssertTrue(try f.store.candidates().isEmpty)
    }
}
