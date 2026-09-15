import TractandaCore
import XCTest

@testable import TractandaWeb

final class BrowserAuthenticationTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var timestamp = 1_800_000_000.0
        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return Date(timeIntervalSince1970: timestamp)
        }
        func advance(_ seconds: Double) {
            lock.lock()
            defer { lock.unlock() }
            timestamp += seconds
        }
    }
    private let launchToken = String(repeating: "a", count: 64)
    private func makeAuthentication(clock: Clock = Clock()) -> BrowserAuthentication {
        BrowserAuthentication(
            username: "alice", launchToken: launchToken, lifetime: 120, idleTimeout: 60, now: { clock.now() },
            verifyPassword: { name, password in name == "alice" && password == "fixture-password" })
    }
    private func assertCode(_ code: String, _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) { XCTAssertEqual(($0 as? TractandaError)?.code, code) }
    }

    func testSignInIssuesIndependentRevocableSessionsAndKeepsLaunchCompatibility() throws {
        let authentication = makeAuthentication()
        XCTAssertTrue(authentication.authorize(launchToken))
        XCTAssertFalse(authentication.authorize(nil))
        XCTAssertFalse(authentication.authorize("wrong"))
        let first = try authentication.signIn(username: "alice", password: "fixture-password")
        let second = try authentication.signIn(username: "alice", password: "fixture-password")
        XCTAssertEqual(first.token.count, 64)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertNotEqual(first.token, launchToken)
        XCTAssertTrue(authentication.profile(for: first.token).isAuthenticated)
        authentication.signOut(first.token)
        XCTAssertFalse(authentication.authorize(first.token))
        XCTAssertTrue(authentication.authorize(second.token))
        authentication.signOut(launchToken)
        XCTAssertFalse(authentication.authorize(launchToken))
        XCTAssertFalse(makeAuthentication().authorize(second.token), "Restart invalidates earlier sessions")
    }

    func testWrongAccountAndPasswordAreRejectedAndFailuresAreRateLimited() throws {
        let clock = Clock()
        let authentication = makeAuthentication(clock: clock)
        assertCode("invalidCredentials") {
            _ = try authentication.signIn(username: "bob", password: "fixture-password")
        }
        for _ in 0..<4 {
            assertCode("invalidCredentials") {
                _ = try authentication.signIn(username: "alice", password: "wrong")
            }
        }
        assertCode("signInLimited") {
            _ = try authentication.signIn(username: "alice", password: "fixture-password")
        }
        clock.advance(61)
        XCTAssertTrue(
            authentication.authorize(
                try authentication.signIn(username: "alice", password: "fixture-password").token))
    }

    func testIdleAndAbsoluteExpiryCannotBeExtendedByProfileReads() throws {
        let clock = Clock()
        let authentication = makeAuthentication(clock: clock)
        clock.advance(59)
        XCTAssertTrue(authentication.profile(for: launchToken).isAuthenticated)
        clock.advance(1)
        XCTAssertFalse(
            authentication.authorize(launchToken), "Profile lookup must not silently renew idle lifetime")
        let session = try authentication.signIn(username: "alice", password: "fixture-password")
        clock.advance(59)
        XCTAssertTrue(authentication.authorize(session.token))
        clock.advance(59)
        XCTAssertTrue(authentication.authorize(session.token))
        clock.advance(2)
        XCTAssertFalse(authentication.authorize(session.token), "Activity must not extend absolute lifetime")
    }

    func testInvalidInputsNeverReachPasswordVerifierAndNoAccountKeepsTokenAccess() throws {
        let authentication = BrowserAuthentication(username: "alice", launchToken: launchToken) { _, _ in
            throw TractandaError("unexpectedVerification", "Invalid input reached OS authentication")
        }
        for password in ["", "abc\0def", String(repeating: "x", count: 4097)] {
            assertCode("invalidCredentials") {
                _ = try authentication.signIn(username: "alice", password: password)
            }
        }
        assertCode("invalidCredentials") {
            _ = try authentication.signIn(username: "someone-else", password: "fixture")
        }
        let unnamed = BrowserAuthentication(username: nil, launchToken: launchToken) { _, _ in true }
        XCTAssertFalse(unnamed.profile(for: nil).isPasswordSignInAvailable)
        XCTAssertTrue(unnamed.authorize(launchToken))
        assertCode("authenticationUnavailable") {
            _ = try unnamed.signIn(username: "alice", password: "fixture")
        }
    }

    func testRenderedSignInAndSnapshotRemainSeparateAndCredentialFree() throws {
        let live = String(decoding: try KanbanPage.render(viewItemID: Identifier.make()), as: UTF8.self)
        XCTAssertTrue(live.contains("class=\"needs-login\""))
        XCTAssertTrue(live.contains("autocomplete=\"current-password\""))
        XCTAssertTrue(live.contains("id=\"sign-out\""))
        XCTAssertFalse(live.contains("@@"))
        let snapshot = String(decoding: try KanbanPage.render(snapshot: ["tasks": .array([])]), as: UTF8.self)
        XCTAssertTrue(snapshot.contains("<body class=\"\">"))
        XCTAssertFalse(snapshot.contains("class=\"needs-login\""))
        XCTAssertFalse(snapshot.contains("fixture-password"))
    }
}
