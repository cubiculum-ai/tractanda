import CSQLite
import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Disposable local placement, never canonical authority. The canonical StoreID binds external
/// indexes. An OS lock also serializes standalone storage users and pending publication recovery.
final class DocumentPlacement: @unchecked Sendable {
    static let capability = "tractanda.document-placement.v1"
    private let root: URL
    private let indexDirectory: URL
    private let maintenance: CanonicalMaintenanceContext?
    private let ownerUID: UInt32
    private let capacityCheck: (UInt64, URL) throws -> Void
    private let lock = NSLock()
    private var database: OpaquePointer?
    private var databaseMetadata: FileMetadata?
    private(set) var recoveryScans = 0
    var arrivalMinute: () throws -> String = { try PeerIntakeJournal.currentArrivalMinute() }
    var afterIntent: (() throws -> Void)?
    var afterFile: (() throws -> Void)?

    init(
        root: URL, indexDirectory: URL?, ownerUID: UInt32, maintenance: CanonicalMaintenanceContext? = nil,
        reserve: @escaping (UInt64, URL) throws -> Void
    ) {
        self.maintenance = maintenance
        self.root = root
        self.indexDirectory = (indexDirectory ?? root.appendingPathComponent("index"))
            .standardizedFileURL.resolvingSymlinksInPath()
        self.ownerUID = ownerUID
        self.capacityCheck = reserve
    }
    deinit { if let database { sqlite3_close(database) } }

    static func validate(_ path: String, id: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 8, parts.prefix(2) == ["documents", "content"],
            parts.last == id, let uuid = UUID(uuidString: id), uuid.version1Components != nil,
            uuid.uuidString.lowercased() == id,
            parts[2].count == 4, parts[3...6].allSatisfy({ $0.count == 2 }),
            parts[2...6].allSatisfy({ $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
            (try? RevisionTimestamp("\(parts[2])-\(parts[3])-\(parts[4])T\(parts[5]):\(parts[6]):00Z")) != nil
        else { throw error("Unsafe saved document placement.") }
    }

    /// A lookup miss is final. Only an absent/incomplete database starts canonical enumeration.
    func path(
        id: String, recover: (_ visit: (String, String) throws -> Void) throws -> Void,
        reconcile: (DocumentContentReference, String) throws -> Bool
    ) throws -> String? {
        try exclusive {
            try ready(recover: recover, reconcile: reconcile)
            return try scalar("SELECT path FROM placements WHERE id=?", [id])
        }
    }

    func publish(
        _ descriptor: DocumentContentReference,
        recover: (_ visit: (String, String) throws -> Void) throws -> Void,
        reconcile: (DocumentContentReference, String) throws -> Bool,
        write: (String, Bool) throws -> Void
    ) throws {
        try exclusive {
            try ready(recover: recover, reconcile: reconcile)
            if let existing = try scalar("SELECT path FROM placements WHERE id=?", [descriptor.contentID]) {
                try Self.validate(existing, id: descriptor.contentID)
                try write(existing, true)
                return
            }
            let path = try publicationIntent(descriptor)
            // FULL-synchronous pending identity precedes any canonical filesystem publication.
            try reserve(16 * 1024)
            try execute(
                "INSERT INTO pending(id,path,descriptor) VALUES(?,?,?)",
                [
                    descriptor.contentID, path,
                    String(decoding: try JSON.encode(descriptor), as: UTF8.self),
                ])
            try afterIntent?()
            try write(path, false)
            try afterFile?()
            try retain(id: descriptor.contentID, path: path)
            try execute("DELETE FROM pending WHERE id=?", [descriptor.contentID])
        }
    }

    func prepare(
        recover: (_ visit: (String, String) throws -> Void) throws -> Void,
        reconcile: (DocumentContentReference, String) throws -> Bool
    ) throws {
        try exclusive { try ready(recover: recover, reconcile: reconcile) }
    }

    private func reserve(_ bytes: UInt64, canonical: Bool = false) throws {
        if let maintenance {
            try maintenance.requireDerivedStorage(root: root, index: indexDirectory)
            let amount = bytes.addingReportingOverflow(16 * 1024)  // terminal audit headroom
            guard !amount.overflow else { throw Self.error("Placement allocation overflow.") }
            try maintenance.checkDerivedCapacity(reserving: amount.partialValue)
        } else {
            try CanonicalMaintenanceContext.deny(
                root: root, path: ["index", "documents.sqlite"],
                operation: "placement mutation without a context")
        }
        try capacityCheck(bytes, canonical ? root : indexDirectory)
    }

    func rebuild(
        recover: (_ visit: (String, String) throws -> Void) throws -> Void,
        reconcile: (DocumentContentReference, String) throws -> Bool
    ) throws {
        try exclusive {
            _ = try boundStoreID()
            if let database {
                sqlite3_close(database)
                self.database = nil
            }
            for name in ["documents.sqlite", "documents.sqlite-journal"] {
                let url = indexDirectory.appendingPathComponent(name)
                do {
                    let metadata = try FileMetadata.read(at: url)
                    guard metadata.type == .regular, metadata.uid == ownerUID, metadata.mode & 0o077 == 0
                    else {
                        throw Self.error("Unsafe disposable index prevents rebuild.")
                    }
                    guard unlink(url.path) == 0 else {
                        throw Self.error("Cannot discard disposable document index.")
                    }
                } catch FileMetadataError.posix(ENOENT) {}
            }
            try ready(recover: recover, reconcile: reconcile)
        }
    }

    private func exclusive<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if let maintenance {
            try maintenance.requireDerivedStorage(root: root, index: indexDirectory)
        } else {
            try CanonicalMaintenanceContext.deny(
                root: root, path: ["index", "documents.sqlite"],
                operation: "placement opening without a context")
        }
        if !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".document-placement.lock").path)
        {
            try CanonicalMaintenanceContext.deny(
                root: root, path: [".document-placement.lock"], operation: "unplanned placement lock creation"
            )
        }
        let fileLock = tractanda_lock(root.appendingPathComponent(".document-placement.lock").path)
        guard fileLock >= 0 else { throw Self.error("Document placement is busy or unsafe.") }
        defer { tractanda_unlock(fileLock) }
        var held = stat()
        let url = root.appendingPathComponent(".document-placement.lock")
        guard fstat(fileLock, &held) == 0, held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            held.st_uid == ownerUID, held.st_mode & 0o777 == 0o600, held.st_nlink == 1,
            let named = try? FileMetadata.read(at: url), named.type == .regular,
            named.inode == UInt64(held.st_ino), named.device == UInt64(held.st_dev)
        else { throw Self.error("Unsafe document placement lock.") }
        let event = try maintenance?.beginDerived(.placement)
        do {
            _ = try boundStoreID()
            let value = try body()
            if let event { try maintenance?.finishDerived(event) }
            return value
        } catch {
            if let event { try? maintenance?.finishDerived(event, failed: true) }
            throw error
        }
    }

    private func ready(
        recover: (_ visit: (String, String) throws -> Void) throws -> Void,
        reconcile: (DocumentContentReference, String) throws -> Bool
    ) throws {
        try openIndex()
        if try scalar("SELECT value FROM state WHERE key='ready'") != "1" {
            try reserve(64 * 1024)
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM placements")
                recoveryScans += 1
                try recover { id, path in try self.retain(id: id, path: path) }
                try execute("INSERT OR REPLACE INTO state(key,value) VALUES('ready','1')")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
        // One bounded row at a time; no unbounded array and no archive enumeration.
        while let id = try scalar("SELECT id FROM pending ORDER BY id LIMIT 1") {
            try Task.checkCancellation()
            guard let path = try scalar("SELECT path FROM pending WHERE id=?", [id]),
                let json = try scalar("SELECT descriptor FROM pending WHERE id=?", [id])
            else { throw Self.error("Incomplete pending document publication.") }
            let descriptor = try DocumentValue.strictDecode(
                DocumentContentReference.self, data: Data(json.utf8))
            try descriptor.validate()
            guard descriptor.contentID == id else { throw Self.error("Pending document identity differs.") }
            try Self.validate(path, id: id)
            if try reconcile(descriptor, path) { try retain(id: id, path: path) }
            try execute("DELETE FROM pending WHERE id=?", [id])
        }
    }

    private func openIndex() throws {
        let path = indexDirectory.appendingPathComponent("documents.sqlite")
        if let database {
            if let current = try? FileMetadata.read(at: path), let databaseMetadata,
                current.inode == databaseMetadata.inode, current.device == databaseMetadata.device,
                current.type == .regular, current.uid == ownerUID, current.mode & 0o077 == 0
            {
                return
            }
            sqlite3_close(database)
            self.database = nil
        }
        let storeID = try boundStoreID()
        if indexDirectory == root.appendingPathComponent("index") {
            let files = DocumentContentFiles(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
            try reserve(64 * 1024, canonical: true)
            try files.ensurePrivateDirectory(["index"])
        }
        try PrivateConfiguration.validate(indexDirectory, directory: true)
        do {
            let metadata = try FileMetadata.read(at: path)
            guard metadata.type == .regular, metadata.uid == ownerUID, metadata.mode & 0o077 == 0 else {
                throw Self.error("Unsafe document placement index.")
            }
        } catch FileMetadataError.posix(ENOENT) {}
        try reserve(64 * 1024)
        // Foundation preserves standard macOS /var aliases even after resolvingSymlinks.
        // Resolve only the validated retained index directory, then keep SQLite NOFOLLOW for
        // the actual open. Device/inode equality is a local race check, not store authority.
        let parent = open(indexDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Self.error("Cannot retain document index directory.") }
        defer { close(parent) }
        var retained = stat()
        guard fstat(parent, &retained) == 0, retained.st_uid == ownerUID,
            retained.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), retained.st_mode & 0o077 == 0,
            let resolved = realpath(indexDirectory.path, nil)
        else { throw Self.error("Cannot resolve validated document index directory.") }
        defer { free(resolved) }
        let resolvedParent = String(cString: resolved)
        let actual = try FileMetadata.read(at: URL(fileURLWithPath: resolvedParent))
        guard actual.type == .directory, actual.inode == UInt64(retained.st_ino),
            actual.device == UInt64(retained.st_dev)
        else {
            throw Self.error("Document index directory changed during resolution.")
        }
        let sqlitePath = resolvedParent + "/documents.sqlite"
        var connection: OpaquePointer?
        let openResult = sqlite3_open_v2(
            sqlitePath, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW, nil)
        guard openResult == SQLITE_OK, let connection else {
            let detail = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            let extended = connection.map { sqlite3_extended_errcode($0) } ?? openResult
            if let connection { sqlite3_close(connection) }
            throw Self.error(
                "Cannot open disposable document placement index (SQLite \(openResult)/\(extended): \(detail); \(path.path))."
            )
        }
        database = connection
        sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, 16 * 1024)
        sqlite3_limit(connection, SQLITE_LIMIT_SQL_LENGTH, 16 * 1024)
        sqlite3_limit(connection, SQLITE_LIMIT_COLUMN, 8)
        do {
            guard chmod(path.path, 0o600) == 0 else { throw Self.error("Cannot protect placement index.") }
            databaseMetadata = try FileMetadata.read(at: path)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA cache_size=-256")
            try execute("CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            try execute(
                "CREATE TABLE IF NOT EXISTS placements(id TEXT PRIMARY KEY,path TEXT NOT NULL UNIQUE)")
            try execute(
                "CREATE TABLE IF NOT EXISTS pending(id TEXT PRIMARY KEY,path TEXT NOT NULL,descriptor TEXT NOT NULL)"
            )
            if let bound = try scalar("SELECT value FROM state WHERE key='storeID'") {
                guard bound == storeID else {
                    throw Self.error("Document index belongs to another canonical StoreID.")
                }
            } else {
                try execute("INSERT INTO state(key,value) VALUES('storeID',?)", [storeID])
            }
            guard try scalar("PRAGMA quick_check(1)") == "ok" else {
                throw TractandaError(
                    "documentIndexRecoveryRequired", "Document placement index requires recovery.")
            }
            try StoreCheckpoint.syncDirectory(indexDirectory)
        } catch {
            sqlite3_close(connection)
            database = nil
            throw error
        }
    }

    private func boundStoreID() throws -> String {
        for name in ["items", "attachments", "documents"] {
            let path = root.appendingPathComponent(name).standardizedFileURL.path
            guard indexDirectory.path != path, !indexDirectory.path.hasPrefix(path + "/") else {
                throw Self.error("Document index cannot be inside canonical data.")
            }
        }
        let storeID = try canonicalIdentity()
        if indexDirectory.standardizedFileURL.path
            != root.appendingPathComponent("index").standardizedFileURL.path
        {
            struct Binding: Decodable {
                let formatVersion: Int
                let storeID: String
            }
            let marker = indexDirectory.appendingPathComponent(".tractanda-index-binding.json")
            try PrivateConfiguration.validate(marker, directory: false)
            let before = try FileMetadata.read(at: marker)
            guard before.size > 0, before.size <= 16 * 1024 else {
                throw Self.error("External index binding exceeds its window.")
            }
            let bytes = try Data(contentsOf: marker)
            guard bytes.count <= 16 * 1024, try FileMetadata.read(at: marker) == before else {
                throw Self.error("External index binding changed.")
            }
            let binding = try JSON.decode(Binding.self, bytes)
            guard binding.formatVersion == 2, binding.storeID == storeID else {
                throw Self.error("External placement index lacks this canonical StoreID binding.")
            }
        }
        return storeID
    }

    private func canonicalIdentity() throws -> String {
        let identity = root.appendingPathComponent(".tractanda-store-identity.json")
        do { _ = try FileMetadata.read(at: identity) } catch FileMetadataError.posix(ENOENT) {
            guard
                indexDirectory.standardizedFileURL.path
                    == root.appendingPathComponent("index").standardizedFileURL.path,
                (try? FileMetadata.read(at: root.appendingPathComponent("index"))) == nil,
                (try? FileMetadata.read(at: root.appendingPathComponent("attachments/payloads"))) == nil,
                (try? FileMetadata.read(at: root.appendingPathComponent("documents"))) == nil,
                (try? FileMetadata.read(at: root.appendingPathComponent("canonical-reader.json"))) == nil,
                (try? FileMetadata.read(at: root.appendingPathComponent("authority"))) == nil
            else { throw Self.error("Missing canonical StoreID cannot be recreated from retained data.") }
            if (try? FileMetadata.read(at: root.appendingPathComponent("items"))) != nil {
                var occupied = false
                try POSIXDirectory.withEntries(at: root.appendingPathComponent("items")) { _ in
                    occupied = true
                    return false
                }
                guard !occupied else { throw Self.error("Missing canonical StoreID on a populated store.") }
            }
            let writer = tractanda_lock(root.appendingPathComponent(".writer.lock").path)
            guard writer >= 0 else {
                throw Self.error("Canonical StoreID must be initialized by its writer.")
            }
            defer { tractanda_unlock(writer) }
            if (try? FileMetadata.read(at: identity)) == nil {
                struct Identity: Codable {
                    let formatVersion: Int
                    let storeID: String
                }
                try reserve(4096, canonical: true)
                try PrivateConfiguration.write(
                    try JSON.encode(
                        Identity(formatVersion: 1, storeID: try UUID.makeVersion1().uuidString.lowercased())),
                    to: identity)
                let files = DocumentContentFiles(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
                try files.ensurePrivateDirectory(["items"])
            }
        }
        return try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: ownerUID)
    }

    private struct Intent: Codable, Equatable {
        let descriptor: DocumentContentReference
        let path: String
    }
    private func publicationIntent(_ descriptor: DocumentContentReference) throws -> String {
        let files = DocumentContentFiles(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
        let base = ["documents", ".placements", descriptor.contentID]
        let current =
            "documents/content/" + (try arrivalMinute()) + "/" + descriptor.contentID
        try Self.validate(current, id: descriptor.contentID)
        for sequence in 0..<1024 {
            let path = base + [String(sequence) + ".json"]
            if let bytes = try files.readIfPresent(path: path, maximumBytes: 4096) {
                let intent = try JSON.decode(Intent.self, bytes)
                try intent.descriptor.validate()
                guard intent.descriptor == descriptor else {
                    throw Self.error("Document publication intent differs.")
                }
                try Self.validate(intent.path, id: descriptor.contentID)
                // Prior unpublished periods are never written into after arrival advances.
                if intent.path == current { return current }
                continue
            }
            try reserve(8192, canonical: true)
            try files.writeImmutable(
                try JSON.encode(Intent(descriptor: descriptor, path: current)), path: path, maximumBytes: 4096
            )
            return current
        }
        throw Self.error("Document arrival intent continuation limit reached.")
    }

    func forget(id: String, path: String) throws {
        try exclusive {
            try Self.validate(path, id: id)
            try openIndex()
            try execute("DELETE FROM placements WHERE id=? AND path=?", [id, path])
            try execute("DELETE FROM pending WHERE id=? AND path=?", [id, path])
        }
    }

    private func retain(id: String, path: String) throws {
        try Self.validate(path, id: id)
        if let old = try scalar("SELECT path FROM placements WHERE id=?", [id]) {
            guard old == path else {
                throw Self.error("Ambiguous duplicate document identity; recovery stopped.")
            }
            return
        }
        try reserve(16 * 1024)
        try execute("INSERT INTO placements(id,path) VALUES(?,?)", [id, path])
    }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else {
            throw indexError("Invalid disposable document index; rebuild required.")
        }
        for (offset, value) in values.enumerated() {
            let status = value.withCString {
                sqlite3_bind_text(
                    result, Int32(offset + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard status == SQLITE_OK else {
                sqlite3_finalize(result)
                throw Self.error("Cannot bind document index operation.")
            }
        }
        return result
    }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        let prepared = try statement(sql, values)
        defer { sqlite3_finalize(prepared) }
        if maintenance != nil {
            if sql == "ROLLBACK" {
                // Rollback is always available to release an already reserved transaction.
                try maintenance?.requireDerivedStorage(root: root, index: indexDirectory)
            } else if sqlite3_stmt_readonly(prepared) == 0 {
                var allocation: UInt64 = 64 * 1024
                if sql == "DELETE FROM placements" {
                    let bytes = try FileMetadata.read(
                        at: indexDirectory.appendingPathComponent("documents.sqlite")
                    ).size
                    let doubled = bytes.multipliedReportingOverflow(by: 2)
                    let sum = doubled.partialValue.addingReportingOverflow(allocation)
                    guard !doubled.overflow, !sum.overflow else {
                        throw Self.error("Placement allocation overflow.")
                    }
                    allocation = sum.partialValue
                }
                try reserve(allocation)
            } else {
                try maintenance?.requireDerivedStorage(root: root, index: indexDirectory)
            }
        }
        let code = sqlite3_step(prepared)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw indexError("Document index operation failed.")
        }
    }
    private func scalar(_ sql: String, _ values: [String] = []) throws -> String? {
        let prepared = try statement(sql, values)
        defer { sqlite3_finalize(prepared) }
        let code = sqlite3_step(prepared)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, sqlite3_column_bytes(prepared, 0) <= 16 * 1024,
            let text = sqlite3_column_text(prepared, 0)
        else {
            throw indexError("Invalid document index result.")
        }
        let count = Int(sqlite3_column_bytes(prepared, 0))
        let bytes = Data(bytes: text, count: count)
        guard !bytes.contains(0), let value = String(data: bytes, encoding: .utf8) else {
            throw TractandaError("documentIndexRecoveryRequired", "Invalid document index text bytes.")
        }
        return value
    }
    private func indexError(_ message: String) -> TractandaError {
        let code = sqlite3_errcode(database)
        let recoverable = [SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_SCHEMA, SQLITE_ERROR, SQLITE_TOOBIG]
            .contains(code)
        return TractandaError(recoverable ? "documentIndexRecoveryRequired" : "documentIntegrity", message)
    }
    private static func error(_ message: String) -> TractandaError {
        TractandaError("documentIntegrity", message)
    }
}
