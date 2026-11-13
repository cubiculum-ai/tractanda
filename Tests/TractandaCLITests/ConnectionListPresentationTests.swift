import Foundation
import TractandaCore
import XCTest

@testable import TractandaCLI

final class ConnectionListPresentationTests: XCTestCase {
    func testProfilesAreClearlyConfigurationAndSortedWithDefault() {
        var document = ConnectionPreferences.Document()
        document.defaultProfile = "work"
        document.profiles = [
            "work": ServerConnection(
                socketPath: "/tmp/work.sock", serverUser: "alice", managedService: "work"),
            "home": ServerConnection(socketPath: "/tmp/home.sock"),
        ]
        let text = connectionListText(document)
        XCTAssertTrue(text.contains("service state not checked"))
        XCTAssertTrue(
            text.contains("* work  Unix socket: /tmp/work.sock  server user: alice  managed service: work"))
        XCTAssertTrue(text.contains("  home  Unix socket: /tmp/home.sock"))
        XCTAssertLessThan(text.range(of: "home")!.lowerBound, text.range(of: "work")!.lowerBound)
    }

    func testEmptyProfilesAreExplicit() {
        XCTAssertTrue(connectionListText(.init()).contains("(none)"))
    }
}
