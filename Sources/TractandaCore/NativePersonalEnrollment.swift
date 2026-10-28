import CTractandaPlatform
import Foundation

/// The existing marked private Unix-session boundary carries one bounded private JMAP
/// request. These methods are never installed on ordinary native, MCP or HTTP dispatch.
package enum NativePersonalEnrollment {
    package static let prefix = Data("TRACTANDA/PERSONAL-PRIVATE/1\0".utf8)
    package static let ready = Data("TRACTANDA/PERSONAL-PRIVATE/READY/1".utf8)
    package static let capability = "https://tractanda.ai/ns/private-enrollment-local/1"
    package static let maximumInput = 16 * 1024
    package static let maximumReply = 64 * 1024
    package struct Begin: Codable, Sendable {
        package let byteCount: Int
        package init(byteCount: Int) throws {
            guard (1...maximumInput).contains(byteCount) else { throw failure() }
            self.byteCount = byteCount
        }
        package func encoded() throws -> Data { prefix + (try JSON.encode(self)) }
        package static func parse(_ data: Data) throws -> Self {
            guard data.count <= 4096, data.starts(with: prefix) else { throw failure() }
            let header = Data(data.dropFirst(prefix.count))
            let value = try JSON.decode(Self.self, header)
            _ = try Self(byteCount: value.byteCount)
            guard try JSON.encode(value) == header else { throw failure() }
            return value
        }
    }
    package static func failure() -> TractandaError {
        .init("privateEnrollmentUnavailable", "Private enrollment could not complete; inspect current job status and resume its exact operation.")
    }
    package static func failureData(_ error: any Error) -> Data {
        let allowed: Set<String> = ["forbidden", "serviceBusy", "serviceClosed", "cancelled", "resourceLimit",
            "enrollmentConflict", "configurationDrift", "peerRuntimeUnavailable", "invitationExpired", "invalidEnrollmentTarget",
            "enrollmentCapacityUnsupported", "enrollmentTopologyUnsupported", "enrollmentPersistenceUncertain"]
        let code = (error as? TractandaError)?.code
        return (try? JSON.encode(TractandaError(code.flatMap { allowed.contains($0) ? $0 : nil } ?? "privateEnrollmentUnavailable",
            "Private enrollment could not complete; inspect current job status and resume its exact operation."))) ?? Data()
    }
    package static func call(connection: ServerConnection, request: Data) throws -> Data {
        try connection.validate()
        let begin = try Begin(byteCount: request.count)
        let fd = tractanda_connect(connection.socketPath)
        guard fd >= 0 else { throw failure() }
        defer { tractanda_close(fd) }
        let expected = try (connection.serverUser ?? ProcessInfo.processInfo.environment["TRACTANDA_SERVER_USER"])
            .map { try SystemAccountDirectory().user(named: $0).uid } ?? tractanda_uid()
        var uid: UInt32 = .max
        guard tractanda_peer_uid(fd, &uid) == 0, uid == expected else {
            throw TractandaError("forbidden", "Daemon OS identity differs from the selected private connection.")
        }
        let deadline = tractanda_private_io_begin(fd)
        guard deadline != 0 else { throw failure() }
        func receive() throws -> Data {
            var pointer: UnsafeMutableRawPointer?, count: UInt32 = 0
            guard tractanda_private_receive_frame(fd, &pointer, &count, UInt32(maximumReply), deadline) == 0,
                let pointer else { throw failure() }
            defer { tractanda_private_free(pointer, count) }
            return Data(bytes: pointer, count: Int(count))
        }
        let header = try begin.encoded()
        guard header.withUnsafeBytes({ tractanda_private_send_begin(fd, $0.baseAddress, UInt32($0.count), deadline) }) == 0 else {
            throw failure()
        }
        let acknowledgement = try receive()
        guard acknowledgement == ready else {
            if let error = try? JSON.decode(TractandaError.self, acknowledgement) {
                throw (try? JSON.decode(TractandaError.self, failureData(error))) ?? failure()
            }
            throw failure()
        }
        guard request.withUnsafeBytes({ tractanda_private_send_frame(fd, $0.baseAddress, UInt32($0.count), deadline) }) == 0 else {
            throw failure()
        }
        let response = try receive()
        if let error = try? JSON.decode(TractandaError.self, response) {
            throw (try? JSON.decode(TractandaError.self, failureData(error))) ?? failure()
        }
        return response
    }
}
