import CTractandaPlatform
import Foundation

/// One private, atomically replaced pending request, scoped to the socket and configured service identity.
/// Restored requests are offered for explicit retry; they are never sent automatically on launch.
public final class RecoveryFile<Payload: Codable & Sendable> {
    private struct Entry: Codable {
        let socket: String
        let serviceUser: String?
        let request: Payload
    }
    public let url: URL
    public let socket: String
    private let serviceUser: String?
    private var lockDescriptor: Int32 = -1

    public init(
        url: URL, socket: String,
        serviceUser: String? = ProcessInfo.processInfo.environment["TRACTANDA_SERVER_USER"]
    ) {
        self.url = url
        self.socket = socket
        self.serviceUser = serviceUser
    }

    deinit {
        releaseLock()
    }

    /// Used only while selecting a default journal: an inspected empty slot must not remain
    /// reserved while another persistent slot is considered.
    public func releaseLock() {
        guard lockDescriptor >= 0 else { return }
        _ = tractanda_unlock(lockDescriptor)
        lockDescriptor = -1
    }

    /// Hold an advisory lock for this client's lifetime, including when no request is pending.
    /// Keep the lock file in place: unlinking it would permit two independently locked files.
    private func acquireLock() throws {
        guard lockDescriptor < 0 else { return }
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try validate(parent, directory: true)
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = tractanda_lock(lockURL.path)
        guard descriptor >= 0 else {
            let code = tractanda_lock_was_busy() != 0 ? "recoveryFileBusy" : "recoveryFileAccess"
            let detail =
                code == "recoveryFileBusy"
                ? "Another client may be using it; close that client or choose a different --recovery-file"
                : "Check that its lock file is a private regular file owned by this user"
            throw TractandaError(
                code, "Cannot lock the recovery file. \(detail): \(url.path)"
            )
        }
        do {
            try validate(lockURL, directory: false)
            lockDescriptor = descriptor
        } catch {
            _ = tractanda_unlock(descriptor)
            throw error
        }
    }

    private func validate(_ url: URL, directory: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == tractanda_uid(),
            let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0
        else {
            throw TractandaError(
                "privateRecoveryFile",
                "The recovery file and its parent must be private and owned by this user: \(url.path)")
        }
    }

    /// `attributesOfItem` inspects a dangling final symlink, unlike `fileExists`.
    /// That keeps an unsafe recovery path from being mistaken for an empty journal.
    private func isPresent(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }

    public func load() throws -> Payload? {
        try acquireLock()
        guard try isPresent(url) else { return nil }
        try validate(url.deletingLastPathComponent(), directory: true)
        try validate(url, directory: false)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.intValue <= 1_048_576 else {
            throw TractandaError("recoveryLimit", "Recovery file is too large.")
        }
        let entry = try JSON.decode(Entry.self, Data(contentsOf: url))
        func serviceUID(_ user: String?) throws -> UInt32 {
            try user.map { try SystemAccountDirectory().user(named: $0).uid } ?? tractanda_uid()
        }
        guard entry.socket == socket, try serviceUID(entry.serviceUser) == serviceUID(serviceUser) else {
            throw TractandaError(
                "recoveryIdentity", "This pending edit belongs to a different socket or service identity.")
        }
        return entry.request
    }

    public func save(_ request: Payload) throws {
        try acquireLock()
        if try isPresent(url) { try validate(url, directory: false) }
        let data = try JSON.encode(Entry(socket: socket, serviceUser: serviceUser, request: request))
        guard data.count <= 1_048_576 else {
            throw TractandaError("recoveryLimit", "Edit exceeds the recovery limit.")
        }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        try acquireLock()
        if try isPresent(url) {
            try validate(url, directory: false)
            try FileManager.default.removeItem(at: url)
        }
    }
}
