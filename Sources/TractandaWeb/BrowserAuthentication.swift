import CTractandaPlatform
import Foundation
import TractandaCore

/// One web adapter's browser sessions. Mutable state is protected across its I/O and password workers.
/// A successful OS password check never changes the process identity or the native caller's scope.
final class BrowserAuthentication: @unchecked Sendable {
    struct Profile: Encodable {
        let username: String?
        let isPasswordSignInAvailable: Bool
        let isAuthenticated: Bool
        let expiresAt: String?
    }
    struct Session: Encodable {
        let token: String
        let username: String?
        let expiresAt: String
    }

    private struct Grant {
        let createdAt: TimeInterval
        var lastUsedAt: TimeInterval
    }
    let username: String?
    private let lock = NSLock()
    private let verifyPassword: @Sendable (String, String) throws -> Bool
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval
    private let idleTimeout: TimeInterval
    private var grants: [String: Grant] = [:]
    private var failedAttempts: [TimeInterval] = []
    private var isAuthenticating = false

    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    convenience init(launchToken: String) {
        let username = try? SystemAccountDirectory().user(forUID: tractanda_uid()).name
        self.init(username: username, launchToken: launchToken) { name, password in
            let result = tractanda_verify_local_password(name, password)
            if result < 0 {
                throw TractandaError("authenticationUnavailable", "OS sign-in is unavailable on this server.")
            }
            return result == 1
        }
    }

    /// The injectable verifier and clock are internal test seams; no CLI or request can select them.
    init(
        username: String?, launchToken: String, lifetime: TimeInterval = 12 * 60 * 60,
        idleTimeout: TimeInterval = 60 * 60, now: @escaping @Sendable () -> Date = { Date() },
        verifyPassword: @escaping @Sendable (String, String) throws -> Bool
    ) {
        self.username = username
        self.verifyPassword = verifyPassword
        self.now = now
        self.lifetime = lifetime
        self.idleTimeout = idleTimeout
        let timestamp = now().timeIntervalSince1970
        grants[launchToken] = Grant(createdAt: timestamp, lastUsedAt: timestamp)
    }

    private func removeExpired(at timestamp: TimeInterval) {
        grants = grants.filter {
            timestamp - $0.value.createdAt < lifetime && timestamp - $0.value.lastUsedAt < idleTimeout
        }
    }

    func authorize(_ token: String?) -> Bool {
        guard let token, token.utf8.count == 64 else { return false }
        lock.lock()
        defer { lock.unlock() }
        let timestamp = now().timeIntervalSince1970
        removeExpired(at: timestamp)
        guard var grant = grants[token] else { return false }
        grant.lastUsedAt = timestamp
        grants[token] = grant
        return true
    }

    func profile(for token: String?) -> Profile {
        lock.lock()
        defer { lock.unlock() }
        removeExpired(at: now().timeIntervalSince1970)
        let grant = token.flatMap { grants[$0] }
        return Profile(
            username: username, isPasswordSignInAvailable: username != nil,
            isAuthenticated: grant != nil,
            expiresAt: grant.map { Timestamp.format(Date(timeIntervalSince1970: $0.createdAt + lifetime)) })
    }

    func signIn(username suppliedName: String, password: String) throws -> Session {
        guard !suppliedName.isEmpty, suppliedName.utf8.count <= 128, !suppliedName.contains("\0"),
            !password.isEmpty, password.utf8.count <= 4096, !password.contains("\0")
        else { throw TractandaError("invalidCredentials", "Enter your account name and password.") }
        lock.lock()
        let timestamp = now().timeIntervalSince1970
        failedAttempts.removeAll { timestamp - $0 >= 60 }
        guard !isAuthenticating, failedAttempts.count < 5 else {
            lock.unlock()
            throw TractandaError("signInLimited", "Sign-in is temporarily limited. Try again in a minute.")
        }
        isAuthenticating = true
        lock.unlock()
        var succeeded = false
        defer {
            lock.lock()
            isAuthenticating = false
            if !succeeded { failedAttempts.append(now().timeIntervalSince1970) }
            lock.unlock()
        }
        guard let username else {
            throw TractandaError(
                "authenticationUnavailable",
                "Run the web session under a named OS account to use password sign-in.")
        }
        guard suppliedName == username, try verifyPassword(username, password) else {
            throw TractandaError("invalidCredentials", "Sign-in failed. Check the account name and password.")
        }
        let token = Self.makeToken()
        lock.lock()
        let issuedAt = now().timeIntervalSince1970
        removeExpired(at: issuedAt)
        if grants.count >= 64, let oldest = grants.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            grants.removeValue(forKey: oldest)
        }
        grants[token] = Grant(createdAt: issuedAt, lastUsedAt: issuedAt)
        failedAttempts.removeAll()
        lock.unlock()
        succeeded = true
        return Session(
            token: token, username: username,
            expiresAt: Timestamp.format(Date(timeIntervalSince1970: issuedAt + lifetime)))
    }

    func signOut(_ token: String?) {
        guard let token else { return }
        lock.lock()
        defer { lock.unlock() }
        grants.removeValue(forKey: token)
    }
}
