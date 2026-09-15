import Foundation
import TractandaClient

/// Serial ownership of a private recovery file; the same scope checks serve old and new clients.
public actor LocalPendingEditStore: PendingEditStore {
    private let file: RecoveryFile<PendingEdit>

    public init(url: URL, socketPath: String) {
        file = RecoveryFile(url: url, socket: socketPath)
    }
    public init(url: URL, connection: ServerConnection) {
        file = RecoveryFile(url: url, socket: connection.socketPath, serviceUser: connection.serverUser)
    }
    public func load() throws -> PendingEdit? { try file.load() }
    public func save(_ edit: PendingEdit) throws { try file.save(edit) }
    public func clear() throws { try file.clear() }
}
