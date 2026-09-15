import Foundation
import TractandaCore

enum RecoveredOperation: Codable, Sendable {
    case single(CommitRequest)
    case batch(BatchOperation)
    case learning(LearningEdit)
    private enum CodingKeys: String, CodingKey { case batch, learning }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.learning) {
            guard !container.contains(.batch) else {
                throw TractandaError("invalidRecovery", "Ambiguous recovery operation.")
            }
            let edit = try container.decode(LearningEdit.self, forKey: .learning)
            try edit.validate()
            self = .learning(edit)
        } else if container.contains(.batch) {
            let batch = try container.decode(BatchOperation.self, forKey: .batch)
            guard !batch.entries.isEmpty, batch.entries.count <= MarkedItems.limit else {
                throw TractandaError("recoveryLimit", "Invalid group recovery size.")
            }
            self = .batch(batch)
        } else {
            self = .single(try CommitRequest(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .single(let request): try request.encode(to: encoder)
        case .batch(let operation):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(operation, forKey: .batch)
        case .learning(let edit):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(edit, forKey: .learning)
        }
    }
}

/// One locked recovery file; old single-edit files keep their original wire shape.
final class RecoveryJournal {
    private static let slotCount = 16
    private let file: RecoveryFile<RecoveredOperation>
    var url: URL { file.url }
    init(
        url: URL, socket: String,
        serviceUser: String? = ProcessInfo.processInfo.environment["TRACTANDA_SERVER_USER"]
    ) {
        file = RecoveryFile(url: url, socket: socket, serviceUser: serviceUser)
    }
    func loadOperation() throws -> RecoveredOperation? { try file.load() }
    func load() throws -> CommitRequest? {
        guard let operation = try file.load() else { return nil }
        guard case .single(let request) = operation else {
            throw TractandaError("recoveryType", "Resume this operation with the updated TUI.")
        }
        return request
    }
    func save(_ request: CommitRequest) throws { try file.save(.single(request)) }
    func save(_ operation: BatchOperation) throws { try file.save(.batch(operation)) }
    func save(_ edit: LearningEdit) throws {
        try edit.validate()
        try file.save(.learning(edit))
    }
    func clear() throws { try file.clear() }
    func releaseLock() { file.releaseLock() }

    /// The primary keeps the historic path. Numbered alternatives are deterministic, bounded,
    /// and persistent so a crashed window's pending edit can be offered by a later default launch.
    static func defaultURL(socket: String, stateDirectory: URL) -> URL {
        let filename = socket.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
        return stateDirectory.appendingPathComponent(filename)
    }

    static func defaultViewPreferencesURL(for primaryURL: URL) -> URL {
        primaryURL.deletingPathExtension().appendingPathExtension("views.json")
    }

    static func claimDefault(
        primaryURL: URL, socket: String,
        serviceUser: String? = ProcessInfo.processInfo.environment["TRACTANDA_SERVER_USER"]
    ) throws -> RecoveryJournal {
        let candidates = slotURLs(primaryURL)

        // A valid pending operation is more important than an empty primary slot. Read only
        // journals that already exist; locked files are live clients and must stay untouched.
        for url in candidates where try isPresent(url) {
            let journal = RecoveryJournal(url: url, socket: socket, serviceUser: serviceUser)
            do {
                if try journal.loadOperation() != nil { return journal }
                journal.releaseLock()
            } catch let error as TractandaError where error.code == "recoveryFileBusy" {
                continue
            }
        }

        // Claiming each candidate through RecoveryFile is the atomic decision point. Do not
        // unlink locks: a process holding an older inode would no longer protect its journal.
        for url in candidates {
            let journal = RecoveryJournal(url: url, socket: socket, serviceUser: serviceUser)
            do {
                _ = try journal.loadOperation()
                return journal
            } catch let error as TractandaError where error.code == "recoveryFileBusy" {
                continue
            }
        }
        throw TractandaError(
            "recoveryFileBusy",
            "All \(Self.slotCount) recovery journal slots are in use; close another TUI window or choose --recovery-file."
        )
    }

    private static func slotURLs(_ primaryURL: URL) -> [URL] {
        let stem = primaryURL.deletingPathExtension()
        return (0..<slotCount).map { slot in
            guard slot > 0 else { return primaryURL }
            return stem.appendingPathExtension("slot-\(slot)").appendingPathExtension("json")
        }
    }

    /// Preserve RecoveryFile's no-symlink behavior while deciding which existing journals to
    /// inspect. A dangling symlink is an invalid journal, not an empty slot.
    private static func isPresent(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }
}
