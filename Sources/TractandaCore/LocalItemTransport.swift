import Dispatch
import Foundation
import TractandaClient

/// Blocking POSIX I/O runs on a dispatch worker, outside the UI actor and Swift task executors.
/// Cancellation after dispatch cannot undo a committed write; callers retain the guarded request.
public struct LocalItemTransport: ItemTransport {
    public let connection: ServerConnection
    public var socketPath: String { connection.socketPath }

    public init(socketPath: String) { connection = ServerConnection(socketPath: socketPath) }
    public init(connection: ServerConnection) { self.connection = connection }

    public func send(_ request: Data) async throws -> Data {
        try Task.checkCancellation()
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result { try connection.send(request) })
            }
        }
        try Task.checkCancellation()
        return result
    }
}
