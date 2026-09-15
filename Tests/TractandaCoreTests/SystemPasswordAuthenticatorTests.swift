import XCTest

@testable import TractandaCore

final class SystemPasswordAuthenticatorTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private func authenticator(
        uid: UInt32 = 501, after: UInt32? = nil,
        verify: @escaping @Sendable (String, String, UInt32) throws -> Void = { _, _, _ in }
    ) -> SystemPasswordAuthenticator {
        let calls = Calls()
        return SystemPasswordAuthenticator(
            resolve: { _ in
                calls.next() == 1 ? uid : (after ?? uid)
            }, verify: verify)
    }

    func testMalformedInputDoesNotReachVerifier() {
        let invoked = expectation(description: "no verifier")
        invoked.isInverted = true
        let auth = authenticator { _, _, _ in invoked.fulfill() }
        XCTAssertThrowsError(try auth.authenticate(username: "", password: "x"))
        XCTAssertThrowsError(try auth.authenticate(username: "valid", password: ""))
        XCTAssertThrowsError(try auth.authenticate(username: "valid", password: "a\0b"))
        XCTAssertThrowsError(
            try auth.authenticate(username: String(repeating: "a", count: 129), password: "x"))
        wait(for: [invoked], timeout: 0.01)
    }

    func testSuccessReturnsCanonicalUID() throws {
        XCTAssertEqual(try authenticator(uid: 77).authenticate(username: "valid", password: "secret"), 77)
    }

    func testDirectoryIdentityChangeIsRejected() {
        XCTAssertThrowsError(
            try authenticator(uid: 77, after: 78).authenticate(username: "valid", password: "secret"))
    }

    func testWrongCredentialsAndBackendFailureAreNotDisclosed() {
        let wrong = authenticator { _, _, _ in
            throw TractandaError("invalidCredentials", "Authentication failed.")
        }
        let backend = authenticator { _, _, _ in
            throw TractandaError("authenticationUnavailable", "Authentication is unavailable.")
        }
        XCTAssertThrowsError(try wrong.authenticate(username: "valid", password: "wrong")) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidCredentials")
        }
        XCTAssertThrowsError(try backend.authenticate(username: "valid", password: "wrong")) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "authenticationUnavailable")
        }
    }
}
