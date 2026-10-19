import CTractandaPlatform
import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A bounded captured input, never Codable, reflected, logged or an authority grant.
package final class PeerPrivateCredentialInput: @unchecked Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let bytes: Mutex<Data>
    package init(bytes: Data) throws {
        guard (36...4096).contains(bytes.count) else { throw Self.failure() }
        self.bytes = Mutex(bytes)
    }
    package var count: Int { bytes.withLock { $0.count } }
    package var description: String { "PeerPrivateCredentialInput(<redacted>)" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
    package func withBytes<T>(_ body: (Data) throws -> T) rethrows -> T { try bytes.withLock { try body($0) } }
    deinit { bytes.withLock { $0.resetBytes(in: 0..<$0.count); $0.removeAll(keepingCapacity: false) } }
    private static func failure() -> TractandaError {
        .init("invalidPeerCredentialInput", "Use a bounded, private, owned regular credential file without symlinks or extra ACLs.")
    }
    static func checkedPath(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.utf8.contains(0), !path.hasSuffix("/") else { throw failure() }
        var absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        #if os(macOS)
        // Only the standard root-owned system aliases are normalized. Other symlinks fail
        // in the descriptor-relative traversal, including the final input component.
        for name in ["tmp", "var"] where absolute.hasPrefix("/" + name + "/") {
            var metadata = stat()
            let alias = "/" + name
            guard lstat(alias, &metadata) == 0 else { throw failure() }
            if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                // Inspect the literal system link. Foundation may render a resolved
                // directory using its short alias again, so it is not an identity test.
                let target = try? FileManager.default.destinationOfSymbolicLink(atPath: alias)
                guard metadata.st_uid == 0, target == "private/" + name || target == "/private/" + name
                else { throw failure() }
                absolute = "/private/" + name + absolute.dropFirst(alias.count)
            }
        }
        #endif
        return absolute
    }
    package static func capture(path: String) throws -> PeerPrivateCredentialInput {
        let absolute = try checkedPath(path)
        var pointer: UnsafeMutableRawPointer?, count: UInt32 = 0
        guard absolute.withCString({ tractanda_capture_private_credential($0, &pointer, &count) }) == 0,
            let pointer else { throw failure() }
        defer { tractanda_private_free(pointer, count) }
        let data = Data(bytes: pointer, count: Int(count))
        do {
            _ = try PeerCredential.decode(data)
            return try .init(bytes: data)
        } catch { throw failure() } // Decoder details must never reflect private input.
    }
}

package enum NativePeerCredentialRegistration {
    package static let prefix = Data("TRACTANDA-PEER-CREDENTIAL/1\n".utf8)
    package static let ready = Data("TRACTANDA-PEER-CREDENTIAL-READY/1".utf8)
    package static let maximumBegin = 16 * 1024
    package static let maximumResult = 4096
    package struct Begin: Codable, Sendable {
        package let operationID: String
        package let permittedOrigins: [String]
        package let byteCount: Int
        package init(operationID: String, permittedOrigins: [String], byteCount: Int) throws {
            _ = try AuthorityRecord.persistentID(.text(operationID))
            guard !permittedOrigins.isEmpty, permittedOrigins.count <= 256,
                permittedOrigins == Array(Set(permittedOrigins)).sorted(), (36...4096).contains(byteCount)
            else { throw protocolFailure() }
            for id in permittedOrigins { _ = try AuthorityRecord.persistentID(.text(id)) }
            self.operationID = operationID; self.permittedOrigins = permittedOrigins; self.byteCount = byteCount
        }
        package func encoded() throws -> Data {
            let data = NativePeerCredentialRegistration.prefix + (try JSON.encode(self))
            guard data.count <= maximumBegin else { throw protocolFailure() }
            return data
        }
        package static func parse(_ data: Data) throws -> Self {
            do {
                guard data.count <= maximumBegin, data.starts(with: prefix) else { throw protocolFailure() }
                let body = Data(data.dropFirst(prefix.count)), value = try JSON.decode(Self.self, body)
                _ = try Self(operationID: value.operationID, permittedOrigins: value.permittedOrigins, byteCount: value.byteCount)
                guard try JSON.encode(value) == body else { throw protocolFailure() }
                return value
            } catch { throw protocolFailure() }
        }
    }
    package struct Result: Codable, Sendable { package let registered: Bool }
    package static func protocolFailure() -> TractandaError {
        .init("privateCredentialProtocol", "Private credential registration could not complete; no private details are returned.")
    }
    package static func failure(_ error: any Error) -> Data {
        let allowed: Set<String> = ["forbidden", "serviceBusy", "serviceClosed", "cancelled", "deadlineExceeded",
            "operationReviewRequired", "invalidPeerCredential", "managedPeerLifecycleRequired", "peerIntakeDisabled",
            "recoveryRequired", "localReplicaRetired", "peerRetired", "authorityBootstrapRequired", "privateCredentialProtocol"]
        let code = (error as? TractandaError)?.code
        let safe = code.flatMap { allowed.contains($0) ? $0 : nil } ?? "privateCredentialProtocol"
        return (try? JSON.encode(TractandaError(safe, "Private credential registration was not completed or its result is unavailable."))) ?? Data()
    }
    package static func register(connection: ServerConnection, input: PeerPrivateCredentialInput,
        permittedOrigins: [String], operationID: String) throws -> Data {
        let begin = try Begin(operationID: operationID, permittedOrigins: permittedOrigins, byteCount: input.count)
        let request = try begin.encoded()
        try connection.validate()
        let fd = tractanda_connect(connection.socketPath)
        guard fd >= 0 else { throw LocalTransport.connectionFailure(socket: connection.socketPath, errorCode: errno) }
        defer { tractanda_close(fd) }
        let expected = try (connection.serverUser ?? ProcessInfo.processInfo.environment["TRACTANDA_SERVER_USER"])
            .map { try SystemAccountDirectory().user(named: $0).uid } ?? tractanda_uid()
        var peer: UInt32 = .max
        guard tractanda_peer_uid(fd, &peer) == 0, peer == expected else {
            throw TractandaError("forbidden", "Server identity differs from the expected OS user.")
        }
        let deadline = tractanda_private_io_begin(fd)
        guard deadline != 0 else { throw protocolFailure() }
        func send(_ data: Data) throws {
            guard data.withUnsafeBytes({ tractanda_private_send_frame(fd, $0.baseAddress, UInt32($0.count), deadline) }) == 0
            else { throw protocolFailure() }
        }
        func receive() throws -> Data {
            var pointer: UnsafeMutableRawPointer?, count: UInt32 = 0
            guard tractanda_private_receive_frame(fd, &pointer, &count, UInt32(maximumResult), deadline) == 0,
                let pointer else { throw protocolFailure() }
            defer { tractanda_private_free(pointer, count) }
            return Data(bytes: pointer, count: Int(count))
        }
        func requireResult(_ data: Data) throws -> Data {
            if let result = try? JSON.decode(Result.self, data), result.registered,
                (try? JSON.encode(result)) == data { return data }
            if let error = try? JSON.decode(TractandaError.self, data) {
                let safe = failure(error)
                throw (try? JSON.decode(TractandaError.self, safe)) ?? protocolFailure()
            }
            throw protocolFailure()
        }
        guard request.withUnsafeBytes({ tractanda_private_send_begin(fd, $0.baseAddress, UInt32($0.count), deadline) }) == 0
        else { throw protocolFailure() }
        let response = try receive()
        guard response == ready else {
            if let error = try? JSON.decode(TractandaError.self, response) {
                throw (try? JSON.decode(TractandaError.self, failure(error))) ?? protocolFailure()
            }
            throw protocolFailure()
        }
        try input.withBytes { try send($0) }
        return try requireResult(receive())
    }
}

/// Host-only admission: no caller-supplied UID/context and no serial owner held while waiting.
package struct PeerCredentialRegistrationAdmission: Sendable {
    let id: UUID
    let owner: UUID
    let uid: UInt32
    let generation: UInt64
    let context: String
    let request: NativePeerCredentialRegistration.Begin
    let control: PeerExchangeControl
}
