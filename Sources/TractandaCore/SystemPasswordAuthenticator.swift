import CTractandaPlatform
import Foundation

#if os(macOS)
    import OpenDirectory
#endif

public protocol PasswordAuthenticating: Sendable {
    func authenticate(username: String, password: String) throws -> UInt32
}

public struct SystemPasswordAuthenticator: PasswordAuthenticating {
    private let resolve: @Sendable (String) throws -> UInt32
    private let verify: @Sendable (String, String, UInt32) throws -> Void

    public init() {
        resolve = { try SystemAccountDirectory().user(named: $0).uid }
        #if os(Linux)
            let brokerSocket = ProcessInfo.processInfo.environment["TRACTANDA_AUTH_SOCKET"]
            verify = { username, password, expectedUID in
                try Self.systemVerify(
                    username: username, password: password, expectedUID: expectedUID,
                    brokerSocket: brokerSocket)
            }
        #else
            verify = { username, password, expectedUID in
                try Self.systemVerify(
                    username: username, password: password, expectedUID: expectedUID, brokerSocket: nil)
            }
        #endif
    }

    init(
        resolve: @escaping @Sendable (String) throws -> UInt32,
        verify: @escaping @Sendable (String, String, UInt32) throws -> Void
    ) {
        self.resolve = resolve
        self.verify = verify
    }

    public func authenticate(username: String, password: String) throws -> UInt32 {
        do { try PrincipalNames.validate(username) } catch {
            throw TractandaError("invalidCredentials", "Authentication failed.")
        }
        guard !password.isEmpty, password.utf8.count <= 4096, !password.utf8.contains(0) else {
            throw TractandaError("invalidCredentials", "Authentication failed.")
        }
        let initial = try resolving(username)
        try verify(username, password, initial)
        let final = try resolving(username)
        guard final == initial else {
            throw TractandaError("authenticationUnavailable", "Authentication identity changed.")
        }
        return initial
    }

    private func resolving(_ username: String) throws -> UInt32 {
        do { return try resolve(username) } catch {
            throw TractandaError("invalidCredentials", "Authentication failed.")
        }
    }

    private static func systemVerify(
        username: String, password: String, expectedUID: UInt32, brokerSocket: String?
    ) throws {
        #if os(macOS)
            let session: ODSession
            let node: ODNode
            let record: ODRecord
            do {
                session = try ODSession(options: nil)
                node = try ODNode(session: session, type: ODNodeType(kODNodeTypeAuthentication))
                record = try node.record(
                    withRecordType: kODRecordTypeUsers, name: username, attributes: [kODAttributeTypeUniqueID]
                )
            } catch {
                throw TractandaError("authenticationUnavailable", "Authentication is unavailable.")
            }
            do {
                let values = try record.values(forAttribute: kODAttributeTypeUniqueID)
                guard let value = values.first as? String, UInt32(value) == expectedUID else {
                    throw TractandaError("invalidCredentials", "Authentication failed.")
                }
                try record.verifyPassword(password)
            } catch let error as TractandaError { throw error } catch {
                throw TractandaError("invalidCredentials", "Authentication failed.")
            }
        #else
            var uid: UInt32 = 0
            #if os(Linux)
                if tractanda_uid() != 0, expectedUID != tractanda_uid(), let brokerSocket {
                    let result = brokerSocket.withCString { socket in
                        username.withCString { name in
                            password.withCString { secret in
                                tractanda_authenticate_password_broker(socket, name, secret, expectedUID)
                            }
                        }
                    }
                    if result == 1 { return }
                    if result == 0 { throw TractandaError("invalidCredentials", "Authentication failed.") }
                    throw TractandaError("authenticationUnavailable", "Authentication is unavailable.")
                }
            #endif
            let result = username.withCString { name in
                password.withCString { secret in tractanda_authenticate_password(name, secret, &uid) }
            }
            if result == 1 && uid == expectedUID { return }
            if result == -2 {
                throw TractandaError(
                    "authenticationUnavailable", "A privileged PAM verifier is required for this account.")
            }
            if result < 0 {
                throw TractandaError("authenticationUnavailable", "Authentication is unavailable.")
            }
            throw TractandaError("invalidCredentials", "Authentication failed.")
        #endif
    }
}
