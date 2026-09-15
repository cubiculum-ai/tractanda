import Foundation

public struct AuthenticationSession: Codable, Sendable {
    public let token: String
    public let username: String
    public let expiresAt: String
}

public struct AuthenticationProfile: Codable, Sendable {
    public let username: String?
    public let isPasswordSignInAvailable: Bool
    public let isAuthenticated: Bool
    public let expiresAt: String?
}

public actor SessionAuthority {
    private struct Grant: Sendable {
        let uid: UInt32
        let username: String
        let expires: Date
        var idle: Date
    }
    private let authenticator: any PasswordAuthenticating
    private let identity: @Sendable (UInt32) async throws -> AccountIdentity
    private let handle: @Sendable (Data, UInt32) async throws -> Data
    private let now: @Sendable () -> Date
    private let token: @Sendable () -> String
    private var grants: [String: Grant] = [:]
    private var closed = false
    private var authenticationCalls = 0
    private var failures: [String: [Date]] = [:]
    private var globalFailures: [Date] = []

    public init(
        coordinator: ServiceCoordinator,
        authenticator: any PasswordAuthenticating = SystemPasswordAuthenticator()
    ) {
        self.authenticator = authenticator
        identity = { try await coordinator.accountIdentity(forUID: $0) }
        handle = { try await coordinator.handle($0, forUID: $1) }
        now = { Date() }
        token = Self.makeToken
    }

    init(
        authenticator: any PasswordAuthenticating,
        identity: @escaping @Sendable (UInt32) async throws -> AccountIdentity,
        handle: @escaping @Sendable (Data, UInt32) async throws -> Data,
        now: @escaping @Sendable () -> Date = { Date() },
        token: @escaping @Sendable () -> String = SessionAuthority.makeToken
    ) {
        self.authenticator = authenticator
        self.identity = identity
        self.handle = handle
        self.now = now
        self.token = token
    }

    public func signIn(username: String, password: String) async throws -> AuthenticationSession {
        do { try PrincipalNames.validate(username) } catch {
            throw TractandaError("invalidCredentials", "Authentication failed.")
        }
        guard !password.isEmpty, password.utf8.count <= 4096, !password.utf8.contains(0) else {
            throw TractandaError("invalidCredentials", "Authentication failed.")
        }
        try beginAuthentication(username)
        let uid: UInt32
        do { uid = try await verifyOffActor(username: username, password: password) } catch {
            recordFailure(username)
            throw error
        }
        let account = try await identity(uid)
        guard !closed, account.uid == uid else {
            throw TractandaError("serviceClosed", "Session authority is closed.")
        }
        return try issue(account)
    }

    public func issue(forUID uid: UInt32) async throws -> AuthenticationSession {
        guard !closed else { throw TractandaError("serviceClosed", "Session authority is closed.") }
        let account = try await identity(uid)
        guard account.uid == uid else { throw TractandaError("invalidSession", "Session is invalid.") }
        return try issue(account)
    }

    public func authorize(_ token: String) async throws -> AccountIdentity {
        guard token.utf8.count == 64 else { throw TractandaError("invalidSession", "Session is invalid.") }
        let snapshot = try active(token)
        let account = try await identity(snapshot.uid)
        guard !closed, account.uid == snapshot.uid, account.name == snapshot.username,
            var current = grants[token], current.uid == snapshot.uid, current.username == snapshot.username,
            current.expires > now(), current.idle.addingTimeInterval(3600) > now()
        else {
            grants.removeValue(forKey: token)
            throw TractandaError("invalidSession", "Session is invalid.")
        }
        current.idle = now()
        grants[token] = current
        return account
    }

    public func dispatch(_ request: Data, token: String) async throws -> Data {
        let account = try await authorize(token)
        return try await handle(request, account.uid)
    }

    public func profile(for token: String?) async -> AuthenticationProfile {
        guard let token else {
            return .init(
                username: nil, isPasswordSignInAvailable: !closed, isAuthenticated: false, expiresAt: nil)
        }
        guard let account = try? await authorize(token), let grant = grants[token],
            account.name == grant.username
        else {
            return .init(
                username: nil, isPasswordSignInAvailable: !closed, isAuthenticated: false, expiresAt: nil)
        }
        return .init(
            username: account.name, isPasswordSignInAvailable: !closed, isAuthenticated: true,
            expiresAt: Timestamp.format(grant.expires))
    }

    public func signOut(_ token: String) { grants.removeValue(forKey: token) }
    public func close() async {
        closed = true
        grants.removeAll()
    }

    private func issue(_ account: AccountIdentity) throws -> AuthenticationSession {
        guard !closed else { throw TractandaError("serviceClosed", "Session authority is closed.") }
        reclaim()
        guard grants.count < 128, grants.values.filter({ $0.uid == account.uid }).count < 8 else {
            throw TractandaError("sessionBusy", "Session capacity is full.")
        }
        let value = token()
        guard grants[value] == nil else { throw TractandaError("sessionBusy", "Session token collision.") }
        let expiry = now().addingTimeInterval(12 * 3600)
        grants[value] = .init(uid: account.uid, username: account.name, expires: expiry, idle: now())
        return .init(token: value, username: account.name, expiresAt: Timestamp.format(expiry))
    }
    private func active(_ value: String) throws -> Grant {
        reclaim()
        guard !closed, let grant = grants[value], grant.expires > now(),
            grant.idle.addingTimeInterval(3600) > now()
        else { throw TractandaError("invalidSession", "Session is invalid.") }
        return grant
    }
    private func reclaim() {
        let instant = now()
        grants = grants.filter {
            $0.value.expires > instant && $0.value.idle.addingTimeInterval(3600) > instant
        }
    }
    private func beginAuthentication(_ username: String) throws {
        reclaimFailures()
        guard !closed, authenticationCalls < 2, (failures[username] ?? []).count < 5,
            globalFailures.count < 30
        else { throw TractandaError("signInLimited", "Sign-in is temporarily limited.") }
        authenticationCalls += 1
    }
    private func recordFailure(_ username: String) {
        let instant = now()
        failures[username, default: []].append(instant)
        globalFailures.append(instant)
    }
    private func reclaimFailures() {
        let cutoff = now().addingTimeInterval(-60)
        failures = failures.compactMapValues {
            let kept = $0.filter { $0 > cutoff }
            return kept.isEmpty ? nil : kept
        }
        if failures.count > 256 {
            failures = Dictionary(
                uniqueKeysWithValues: failures.sorted { $0.value.last! > $1.value.last! }.prefix(256).map {
                    ($0.key, $0.value)
                })
        }
        globalFailures.removeAll { $0 <= cutoff }
    }
    private func verifyOffActor(username: String, password: String) async throws -> UInt32 {
        defer { authenticationCalls -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        try self.authenticator.authenticate(username: username, password: password)
                    })
            }
        }
    }
    private static func makeToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}
