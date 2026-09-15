import XCTest

@testable import TractandaCore

final class SessionAuthorityTests: XCTestCase {
    private actor Signal {
        private var count = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func signal() { if let waiter = waiters.popLast() { waiter.resume() } else { count += 1 } }
        func wait() async {
            if count > 0 { count -= 1 } else { await withCheckedContinuation { waiters.append($0) } }
        }
    }

    private actor Gate {
        let entered = Signal()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func block() async {
            await entered.signal()
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private final class BlockingAuthenticator: @unchecked Sendable, PasswordAuthenticating {
        let entered = Signal()
        let release = DispatchSemaphore(value: 0)
        func authenticate(username: String, password: String) throws -> UInt32 {
            Task { await entered.signal() }
            release.wait()
            throw TractandaError("invalidCredentials", "Authentication failed.")
        }
    }
    private struct FakeAuthenticator: PasswordAuthenticating {
        let uid: UInt32
        func authenticate(username: String, password: String) throws -> UInt32 {
            guard password == "ok" else {
                throw TractandaError("invalidCredentials", "Authentication failed.")
            }
            return uid
        }
    }
    private static func account(_ uid: UInt32) -> AccountIdentity {
        .init(uid: uid, name: uid == 1 ? "alice" : "bob", primaryGroupName: "staff", groupIDs: [20])
    }
    func testDistinctSessionsAuthorizeCurrentIdentity() async throws {
        let authority = SessionAuthority(
            authenticator: FakeAuthenticator(uid: 1), identity: { Self.account($0) },
            handle: { data, _ in data })
        let first = try await authority.signIn(username: "alice", password: "ok")
        let second = try await authority.issue(forUID: 2)
        XCTAssertNotEqual(first.token, second.token)
        let firstAccount = try await authority.authorize(first.token)
        let secondAccount = try await authority.authorize(second.token)
        XCTAssertEqual(firstAccount.uid, 1)
        XCTAssertEqual(secondAccount.uid, 2)
    }
    func testLogoutAndChangedIdentityInvalidate() async throws {
        let authority = SessionAuthority(
            authenticator: FakeAuthenticator(uid: 1), identity: { uid in Self.account(uid) },
            handle: { data, _ in data })
        let session = try await authority.signIn(username: "alice", password: "ok")
        await authority.signOut(session.token)
        await assertThrowsErrorAsync(try await authority.authorize(session.token))
    }

    func testFailedWorkersRemainBoundedAndThirdIsRefused() async {
        let verifier = BlockingAuthenticator()
        let authority = SessionAuthority(
            authenticator: verifier, identity: { Self.account($0) }, handle: { data, _ in data })
        async let first: Void = assertThrowsErrorAsync(
            try await authority.signIn(username: "alice", password: "wrong"))
        async let second: Void = assertThrowsErrorAsync(
            try await authority.signIn(username: "alice", password: "wrong"))
        await verifier.entered.wait()
        await verifier.entered.wait()
        await assertThrowsErrorAsync(try await authority.signIn(username: "alice", password: "wrong"))
        verifier.release.signal()
        verifier.release.signal()
        _ = await (first, second)
        async let third: Void = assertThrowsErrorAsync(
            try await authority.signIn(username: "alice", password: "wrong"))
        await verifier.entered.wait()
        verifier.release.signal()
        _ = await third
    }

    func testCloseDuringSuspendedIssueCannotMintAndIdentityRemainsUsable() async throws {
        let gate = Gate()
        let authority = SessionAuthority(
            authenticator: FakeAuthenticator(uid: 1),
            identity: { uid in
                await gate.block()
                return Self.account(uid)
            }, handle: { data, _ in data })
        let task = Task { try await authority.issue(forUID: 1) }
        await gate.entered.wait()
        await authority.close()
        await gate.open()
        await assertThrowsErrorAsync(try await task.value)
        XCTAssertEqual(Self.account(1).name, "alice")
    }
}

private func assertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T) async {
    do {
        _ = try await expression()
        XCTFail("Expected error")
    } catch {}
}
