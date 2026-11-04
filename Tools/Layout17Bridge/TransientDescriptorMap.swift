import CSQLite
import Foundation
import TractandaClient

/// Disposable preflight index, never an item store or an authority ledger.
/// It holds only bounded descriptor keys and identities, not canonical record bytes.
final class TransientDescriptorMap {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        // SQLite's empty filename selects a private temporary database. Its file is
        // delete-on-close, including process exit, and pages spill to disk as needed.
        guard sqlite3_open_v2("", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(database); database = nil
            throw TractandaError("preflightResource", "Cannot open temporary descriptor index.")
        }
        do {
            try execute("PRAGMA journal_mode=MEMORY")
            try execute("PRAGMA synchronous=OFF")
            try execute("CREATE TABLE canonical_identity (revision TEXT PRIMARY KEY, path TEXT NOT NULL)")
            try execute("CREATE TABLE canonical (old_key TEXT PRIMARY KEY, new_key TEXT NOT NULL UNIQUE, revision TEXT NOT NULL UNIQUE, path TEXT NOT NULL, new_descriptor BLOB NOT NULL)")
            try execute("CREATE TABLE staged (new_key TEXT PRIMARY KEY, old_key TEXT NOT NULL, revision TEXT NOT NULL, stage TEXT NOT NULL, new_descriptor BLOB NOT NULL)")
            try execute("CREATE INDEX staged_old ON staged(old_key)")
            try execute("CREATE TABLE reviews (new_key TEXT PRIMARY KEY, old_key TEXT NOT NULL, review TEXT NOT NULL)")
            try execute("CREATE TABLE work (seq INTEGER PRIMARY KEY, priority INTEGER NOT NULL, payload BLOB NOT NULL)")
            try execute("CREATE INDEX work_order ON work(priority, seq)")
        } catch {
            sqlite3_close(database); database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer? {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK else { throw failure() }
        return result
    }
    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else { throw failure() }
    }
    private func bind(_ value: Data, to statement: OpaquePointer?, at index: Int32) throws {
        guard !value.isEmpty && value.count <= 128 * 1024 else {
            throw TractandaError("preflightResource", "Descriptor metadata exceeds its bound.")
        }
        let status = value.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), transient)
        }
        guard status == SQLITE_OK else { throw failure() }
    }
    private func failure() -> TractandaError {
        TractandaError("preflightResource", "Temporary descriptor index failed: " + String(cString: sqlite3_errmsg(database)))
    }

    func canonicalIdentity(revision: String, path: String) throws {
        let query = try statement("SELECT path FROM canonical_identity WHERE revision=?")
        defer { sqlite3_finalize(query) }
        try bind(revision, to: query, at: 1)
        let status = sqlite3_step(query)
        if status == SQLITE_ROW {
            let previous = sqlite3_column_text(query, 0).map { String(cString: $0) } ?? "unknown"
            throw TractandaError("peerObjectCollision", "Duplicate canonical revision \(revision): \(previous) and \(path).")
        }
        guard status == SQLITE_DONE else { throw failure() }
        let insert = try statement("INSERT INTO canonical_identity VALUES(?,?)")
        defer { sqlite3_finalize(insert) }
        try bind(revision, to: insert, at: 1); try bind(path, to: insert, at: 2)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
    }

    func canonical(oldKey: String, newKey: String, revision: String, path: String, newDescriptor: Data) throws {
        let query = try statement("SELECT path FROM canonical WHERE revision=?")
        defer { sqlite3_finalize(query) }
        try bind(revision, to: query, at: 1)
        let status = sqlite3_step(query)
        if status == SQLITE_ROW {
            let previous = sqlite3_column_text(query, 0).map { String(cString: $0) } ?? "unknown"
            throw TractandaError("peerObjectCollision", "Duplicate canonical revision \(revision): \(previous) and \(path).")
        }
        guard status == SQLITE_DONE else { throw failure() }
        let reverse = try statement("SELECT old_key, revision FROM canonical WHERE new_key=?")
        defer { sqlite3_finalize(reverse) }
        try bind(newKey, to: reverse, at: 1)
        let reverseStatus = sqlite3_step(reverse)
        if reverseStatus == SQLITE_ROW {
            let priorKey = sqlite3_column_text(reverse, 0).map { String(cString: $0) } ?? "unknown"
            let priorRevision = sqlite3_column_text(reverse, 1).map { String(cString: $0) } ?? "unknown"
            throw TractandaError("peerObjectCollision", "Converted revision collision: revision \(priorRevision), descriptor \(priorKey); revision \(revision), descriptor \(oldKey).")
        }
        guard reverseStatus == SQLITE_DONE else { throw failure() }
        let insert = try statement("INSERT INTO canonical VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(insert) }
        try bind(oldKey, to: insert, at: 1); try bind(newKey, to: insert, at: 2); try bind(revision, to: insert, at: 3)
        try bind(path, to: insert, at: 4); try bind(newDescriptor, to: insert, at: 5)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
    }

    func staged(oldKey: String, newKey: String, revision: String, stage: String, newDescriptor: Data) throws {
        let canonicalQuery = try statement("SELECT old_key, revision FROM canonical WHERE new_key=?")
        defer { sqlite3_finalize(canonicalQuery) }
        try bind(newKey, to: canonicalQuery, at: 1)
        let canonicalStatus = sqlite3_step(canonicalQuery)
        if canonicalStatus == SQLITE_ROW {
            let previousKey = sqlite3_column_text(canonicalQuery, 0).map { String(cString: $0) } ?? "unknown"
            let previousRevision = sqlite3_column_text(canonicalQuery, 1).map { String(cString: $0) } ?? "unknown"
            // During resumable migration, a stage can already contain message bytes
            // while the matching canonical revision is still in its old encoding.
            guard previousKey == oldKey || oldKey == newKey else {
                throw TractandaError("peerObjectCollision", "Converted stage/canonical collision: revision \(previousRevision), descriptor \(previousKey); revision \(revision), stage \(stage), descriptor \(oldKey).")
            }
        } else if canonicalStatus != SQLITE_DONE { throw failure() }
        let query = try statement("SELECT old_key, revision, stage FROM staged WHERE new_key=?")
        defer { sqlite3_finalize(query) }
        try bind(newKey, to: query, at: 1)
        let status = sqlite3_step(query)
        if status == SQLITE_ROW {
            let old = sqlite3_column_text(query, 0).map { String(cString: $0) } ?? "unknown"
            let previousRevision = sqlite3_column_text(query, 1).map { String(cString: $0) } ?? "unknown"
            let previousStage = sqlite3_column_text(query, 2).map { String(cString: $0) } ?? "unknown"
            throw TractandaError("peerObjectCollision", "Converted stage collision: revision \(previousRevision), stage \(previousStage), descriptor \(old); revision \(revision), stage \(stage), descriptor \(oldKey).")
        }
        guard status == SQLITE_DONE else { throw failure() }
        let insert = try statement("INSERT INTO staged VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(insert) }
        try bind(newKey, to: insert, at: 1); try bind(oldKey, to: insert, at: 2)
        try bind(revision, to: insert, at: 3); try bind(stage, to: insert, at: 4)
        try bind(newDescriptor, to: insert, at: 5)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
    }

    func newKey(oldKey: String, staged: Bool) throws -> String? {
        let query = try statement(staged ? "SELECT new_key FROM staged WHERE old_key=?" : "SELECT new_key FROM canonical WHERE old_key=?")
        defer { sqlite3_finalize(query) }
        try bind(oldKey, to: query, at: 1)
        let status = sqlite3_step(query)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw failure() }
        guard status == SQLITE_ROW, let raw = sqlite3_column_text(query, 0) else { return nil }
        return String(cString: raw)
    }

    func hasCanonicalNewKey(_ key: String) throws -> Bool {
        let query = try statement("SELECT 1 FROM canonical WHERE new_key=?")
        defer { sqlite3_finalize(query) }
        try bind(key, to: query, at: 1)
        let status = sqlite3_step(query)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw failure() }
        return status == SQLITE_ROW
    }

    func descriptor(oldKey: String, staged: Bool, byNewKey: Bool = false) throws -> PersonalRevisionDescriptor? {
        let table = staged ? "staged" : "canonical"
        let column = byNewKey ? "new_key" : "old_key"
        let query = try statement("SELECT new_descriptor FROM \(table) WHERE \(column)=?")
        defer { sqlite3_finalize(query) }
        try bind(oldKey, to: query, at: 1)
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { throw failure() }
        let count = Int(sqlite3_column_bytes(query, 0))
        guard count > 0 && count <= 128 * 1024 else { throw TractandaError("preflightResource", "Invalid mapped descriptor.") }
        let value = try JSON.decode(PersonalRevisionDescriptor.self, Data(bytes: bytes, count: count))
        try value.validate()
        return value
    }

    func review(oldKey: String, newKey: String, review: String) throws {
        let query = try statement("SELECT old_key, review FROM reviews WHERE new_key=?")
        defer { sqlite3_finalize(query) }
        try bind(newKey, to: query, at: 1)
        let status = sqlite3_step(query)
        if status == SQLITE_ROW {
            let previous = sqlite3_column_text(query, 1).map { String(cString: $0) } ?? "unknown"
            let old = sqlite3_column_text(query, 0).map { String(cString: $0) } ?? "unknown"
            throw TractandaError("peerObjectCollision", "Converted review collision: review \(previous), descriptor \(old); review \(review), descriptor \(oldKey).")
        }
        guard status == SQLITE_DONE else { throw failure() }
        let insert = try statement("INSERT INTO reviews VALUES(?,?,?)")
        defer { sqlite3_finalize(insert) }
        try bind(newKey, to: insert, at: 1); try bind(oldKey, to: insert, at: 2); try bind(review, to: insert, at: 3)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
    }

    func enqueue(priority: Int32, payload: Data) throws {
        guard !payload.isEmpty, payload.count <= 512 * 1024 else {
            throw TractandaError("preflightResource", "Migration work item exceeds its bound.")
        }
        let insert = try statement("INSERT INTO work(priority,payload) VALUES(?,?)")
        defer { sqlite3_finalize(insert) }
        guard sqlite3_bind_int(insert, 1, priority) == SQLITE_OK else { throw failure() }
        let status = payload.withUnsafeBytes { raw in
            sqlite3_bind_blob(insert, 2, raw.baseAddress, Int32(raw.count), transient)
        }
        guard status == SQLITE_OK, sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
    }

    func nextWork() throws -> (Int64, Data)? {
        let query = try statement("SELECT seq,payload FROM work ORDER BY priority,seq LIMIT 1")
        defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 1) else { throw failure() }
        let count = Int(sqlite3_column_bytes(query, 1))
        guard count > 0, count <= 512 * 1024 else {
            throw TractandaError("preflightResource", "Stored migration work item is invalid.")
        }
        return (sqlite3_column_int64(query, 0), Data(bytes: bytes, count: count))
    }

    func removeWork(_ sequence: Int64) throws {
        let command = try statement("DELETE FROM work WHERE seq=?")
        defer { sqlite3_finalize(command) }
        guard sqlite3_bind_int64(command, 1, sequence) == SQLITE_OK,
            sqlite3_step(command) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw failure() }
    }
}
