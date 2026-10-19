import Foundation
import TractandaClient
import TractandaCore
import XCTest

@testable import TractandaTUI

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@MainActor
final class CaptureApplicationTests: XCTestCase {
    private actor Transport: ItemTransport {
        var isReleased = false
        var continuation: CheckedContinuation<Void, Never>?
        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
        func send(_ data: Data) async throws -> Data {
            let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let call = (envelope["methodCalls"] as! [[Any]])[0]
            let method = call[0] as! String
            let args = try JSONSerialization.data(withJSONObject: call[1])
            guard method == "TractandaItem/prepareCapture" else {
                throw TractandaCore.TractandaError("testUnexpectedWrite", "Read-only tests must not commit")
            }
            let preparation = try TractandaCore.JSON.decode(TractandaCore.CapturePreparation.self, args)
            if !isReleased { await withCheckedContinuation { continuation = $0 } }
            let plan = TractandaCore.CapturePlan(
                request: preparation.request, evaluatedAt: "2026-10-13T12:00:00Z",
                commitRequest: preparation.request, categoryRevisionIDs: [:],
                mentions: (0..<64).map {
                    TractandaCore.CaptureMention(token: "#tag-\($0)", categoryID: "category-\($0)")
                },
                issues: [
                    TractandaCore.CaptureIssue(
                        token: "#unknown", code: "unknown", message: "Correct before saving")
                ])
            let result = try JSONSerialization.jsonObject(with: TractandaCore.JSON.encode(plan))
            return try JSONSerialization.data(withJSONObject: [
                "methodResponses": [[method, result, "client"]]
            ])
        }
    }
    private final class Fixture {
        let root: URL
        let store: ItemStore
        let client: TractandaCore.ItemClient
        init() throws {
            let parent = FileManager.default.temporaryDirectory
            var capacity = statvfs()
            guard statvfs(parent.path, &capacity) == 0,
                UInt64(capacity.f_bavail) * UInt64(capacity.f_frsize) >= 10 * 1024 * 1024 * 1024 + 4 * 1024
                    * 1024
            else {
                throw TractandaCore.TractandaError(
                    "fixtureCapacity", "Tiny UI fixture requires 10GiB reserve plus 4MiB cap")
            }
            root = parent.appendingPathComponent("capture-ui-\(TractandaCore.Identifier.make())")
            store = try ItemStore(root: root.appendingPathComponent("store"))
            let service = ItemService(store: store)
            let uid = store.ownerUID
            client = TractandaCore.ItemClient(transport: { service.handle($0, peerUID: uid) })
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func app(_ transport: Transport? = nil, keymap: Keymap = .standard) throws -> TerminalApplication {
            try TerminalApplication(
                client: client,
                journal: RecoveryJournal(
                    url: root.appendingPathComponent(TractandaCore.Identifier.make() + ".json"),
                    socket: "/fixture"),
                itemsOnly: true, keymap: keymap,
                captureActionLoader: transport.map { CaptureActionLoader(transport: $0) })
        }
        func category() throws -> TractandaCore.Revision {
            try client.commit(
                TractandaCore.CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text("Alpha"),
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                        ]),
                    ],
                    operationID: "category")
            ).revision
        }
    }
    private func screen(_ app: TerminalApplication, rows: Int = 30) -> String {
        app.render(columns: 100, rows: rows).map(\.text).joined(separator: "\n")
    }
    private func beginCapture(_ app: TerminalApplication) {
        _ = screen(app)
        app.handle(.text("n"))
        app.handle(.paste("Draft"))
        app.handle(.tab)
        app.handle(.paste("#unknown " + String(repeating: "w", count: 181) + "Ω"))
        for _ in 0..<3 { app.handle(.tab) }
        app.handle(.right)
        app.handle(.control(19))
    }
    private func waitFor(_ text: String, app: TerminalApplication) async throws {
        for _ in 0..<100 {
            if screen(app).contains(text) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Missing UI state: \(text)")
    }

    func testActualReviewRepeatedScrollReadonlyAndMenuNavigation() async throws {
        let fixture = try Fixture()
        let transport = Transport()
        let app = try fixture.app(transport)
        beginCapture(app)
        await transport.release()
        try await waitFor("Capture needs correction", app: app)
        let initial = screen(app)
        app.handle(.down)
        let first = screen(app)
        app.handle(.down)
        let second = screen(app)
        XCTAssertNotEqual(initial, first)
        XCTAssertNotEqual(first, second, "Repeated arrows retain the prior offset")
        app.handle(.pageDown)
        XCTAssertNotEqual(second, screen(app))
        app.handle(.end)
        XCTAssertTrue(screen(app).contains("Ω"), "The last wrapped line must remain reachable")
        let beforeTyping = screen(app)
        app.handle(.paste("SHOULD_NOT_CHANGE"))
        app.handle(.text("x"))
        app.handle(.delete)
        XCTAssertEqual(screen(app), beforeTyping)
        app.handle(.function(10))
        let menu = screen(app)
        app.handle(.down)
        XCTAssertNotEqual(screen(app), menu, "Menu arrows must not scroll the underlying review")
        app.handle(.escape)
        app.handle(.home)
        XCTAssertTrue(screen(app).contains("#tag-0"))
        app.handle(.escape)
        XCTAssertTrue(screen(app).contains("Draft"))
        XCTAssertTrue(try fixture.store.candidates().isEmpty)
    }

    func testDeferredPreviewPreservesNestedSettingsAndLateCancelPreservesNewDraft() async throws {
        let fixture = try Fixture()
        let transport = Transport()
        let keymap = try Keymap(
            bindings: Keymap.standard.bindings + [
                KeyBinding(context: .form, chord: KeyChord(.function(6), .command), command: .appearance)
            ])
        let app = try fixture.app(transport, keymap: keymap)
        beginCapture(app)
        app.handle(.modified(.function(6), .command))
        XCTAssertTrue(screen(app).contains("Appearance"))
        await transport.release()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(screen(app).contains("Appearance"), "Late preview must not replace nested settings")
        app.handle(.escape)
        try await waitFor("Capture needs correction", app: app)
        app.handle(.escape)
        app.handle(.escape)
        let delayed = Transport()
        let second = try fixture.app(delayed)
        beginCapture(second)
        second.handle(.escape)
        second.handle(.escape)
        second.handle(.text("n"))
        second.handle(.paste("New draft"))
        await delayed.release()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(screen(second).contains("New draft"))
        XCTAssertFalse(screen(second).contains("Capture needs correction"))
    }

    func testActualInspectorAliasNewlinesAndOverlaySmallScreenFocusStayVisible() async throws {
        let fixture = try Fixture()
        let category = try fixture.category()
        let app = try fixture.app()
        _ = screen(app)
        app.handle(.function(9))
        app.handle(.paste("Alpha"))
        app.handle(.function(2))
        for _ in 0..<4 { app.handle(.tab) }
        app.handle(.paste("first\nsecond\nthird"))
        app.handle(.enter)
        app.handle(.paste("fourth"))
        let frame = app.render(columns: 100, rows: 30)
        XCTAssertTrue(frame.contains { $0.cursorColumn != nil && $0.text.contains("fourth") })
        app.handle(.control(19))
        XCTAssertEqual(
            try fixture.store.get(category.itemID).fields["captureAliases"],
            .list([.text("first"), .text("second"), .text("third"), .text("fourth")]))
        app.handle(.escape)
        app.handle(.modified(.text("N"), .control))
        for _ in 0..<7 { app.handle(.tab) }
        for rows in [13, 14, 15] {
            let small = app.render(columns: 100, rows: rows)
            XCTAssertTrue(
                small.contains { $0.cursorColumn != nil && $0.text.contains("UTC") },
                "Timezone focus hidden at rows \(rows)")
        }
    }
}
