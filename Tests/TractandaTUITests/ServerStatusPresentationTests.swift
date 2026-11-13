import Foundation
import Synchronization
import TractandaCore
import XCTest

@testable import TractandaTUI

final class ServerStatusPresentationTests: XCTestCase {
    func testUnavailableSectionsRemainVisibleAndReadOnly() {
        var calls = 0
        let client = ItemClient(transport: { _ in
            calls += 1
            throw TractandaError("connectionFailed", "server unavailable")
        })
        let text = ServerStatusPresentation.text(client: client)
        XCTAssertTrue(text.contains("Server info unavailable"))
        XCTAssertTrue(text.contains("Semantic index unavailable"))
        XCTAssertTrue(text.contains("Cluster status unavailable"))
        XCTAssertTrue(text.contains("R refreshes · Esc closes"))
        XCTAssertGreaterThan(calls, 0)
    }

    func testStatusIsDiscoverableInApplicationMenu() {
        let menu = CommandMenu(keymap: .standard, context: .browser)
        XCTAssertTrue(menu.groups.first(where: { $0.id == .application })!.commands.contains(.serverStatus))
    }
}

extension ServerStatusPresentationTests {
    func testLoadingRefreshCloseAndLateResult() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root.appendingPathComponent("store"))
        let service = ItemService(store: store)
        let uid = store.ownerUID
        let client = ItemClient(transport: { service.handle($0, peerUID: uid) })
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let count = Mutex(0)
        let loader = ServerStatusLoader(load: {
            let number = count.withLock {
                $0 += 1
                return $0
            }
            entered.signal()
            release.wait()
            finished.signal()
            return "STATUS RESULT \(number)"
        })
        defer { for _ in 0..<4 { release.signal() } }
        let app = try TerminalApplication(
            client: client,
            journal: RecoveryJournal(url: root.appendingPathComponent("journal"), socket: "/fixture"),
            statusLoader: loader)
        _ = app.render(columns: 80, rows: 25)
        app.showServerStatus()
        XCTAssertTrue(app.render(columns: 80, rows: 25).contains { $0.text.contains("Loading status") })
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        for _ in 0..<20 { app.handle(.text("r")) }
        XCTAssertEqual(count.withLock { $0 }, 1)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(count.withLock { $0 }, 2)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        let deadline = Date().addingTimeInterval(5)
        while !loader.hasDelivery() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        let current = app.render(columns: 80, rows: 25).map(\.text).joined(separator: "\n")
        XCTAssertTrue(current.contains("STATUS RESULT 2"))
        XCTAssertFalse(current.contains("STATUS RESULT 1"))
        app.handle(.text("r"))
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        for _ in 0..<20 { app.handle(.text("r")) }
        app.handle(.escape)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        let closed = app.render(columns: 80, rows: 25).map(\.text).joined(separator: "\n")
        XCTAssertFalse(closed.contains("STATUS RESULT"))
        XCTAssertEqual(count.withLock { $0 }, 3)
        app.showServerStatus()
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        app.handle(.function(10))
        app.handle(.left)
        app.handle(.enter)
        XCTAssertTrue(
            app.render(columns: 80, rows: 25).map(\.text).joined(separator: "\n").contains("About Tractanda"))
        app.handle(.text("r"))
        XCTAssertTrue(
            app.render(columns: 80, rows: 25).map(\.text).joined(separator: "\n").contains("About Tractanda"))
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        app.handle(.escape)
        app.showServerStatus()
        app.handle(.function(1))
        let help = app.render(columns: 80, rows: 25).map(\.text).joined(separator: "\n")
        XCTAssertTrue(help.contains("Tractanda help"))
        app.handle(.text("r"))
        XCTAssertTrue(
            app.render(columns: 80, rows: 25).map(\.text).joined(separator: "\n").contains("Tractanda help"))
        app.handle(.escape)
    }
}
