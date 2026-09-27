import CSQLite
import Foundation

/// Owns an isolated, read-only main catalogue connection for one verifier scan.
/// All mutable scan state lives in this connection's TEMP schema.
final class CanonicalCatalogueReader {
    struct Row: Sendable {
        let rowID: Int64
        let revisionID: String
        let path: String
        let size: UInt64
        let inode: UInt64
        let uid: UInt32
        let mode: UInt32
        let modificationSeconds: Int64
        let modificationNanoseconds: Int32
        let digest: Data
    }

    struct Page: Sendable {
        let rows: [Row]
        let nextRowID: Int64?
    }

    enum ReaderError: Error {
        case open
        case sqlite(Int32)
        case identity
        case schema
        case tempCap
    }

    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let watermark: Int64
    let maxSeenBytes: Int
    private(set) var seenBytes = 0
    private(set) var catalogueRowsRead = 0
    private(set) var maxPageRows = 0
    private(set) var maxStatementRows = 0
    private(set) var tempPageLimit = 0

    init(
        path: String, identity: String, watermark: Int64,
        maxSeenBytes: Int = 16 * 1024 * 1024
    ) throws {
        guard maxSeenBytes > 0 else { throw ReaderError.tempCap }
        self.maxSeenBytes = maxSeenBytes
        self.watermark = watermark
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            database = nil
            throw ReaderError.open
        }
        sqlite3_busy_timeout(database, 1500)
        do {
            try validate(identity: identity)
            try execute("PRAGMA temp_store=FILE")
            try execute("PRAGMA temp.page_size=4096")
            let pages = max(1, (maxSeenBytes + 4095) / 4096)
            guard try scalarInt("PRAGMA temp.max_page_count=\(pages)") == Int64(pages) else {
                throw ReaderError.tempCap
            }
            tempPageLimit = pages
            try execute("CREATE TEMP TABLE verifier_seen(path TEXT PRIMARY KEY) WITHOUT ROWID")
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        if let database { sqlite3_close(database) }
        database = nil
    }

    func row(path: String) throws -> Row? {
        guard let database else { throw ReaderError.open }
        let statement = try prepare(
            "SELECT rowid,revision,path,size,inode,uid,mode,mtime_seconds,mtime_nanoseconds,digest "
                + "FROM main.revision_catalog WHERE path=? AND rowid<=? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, to: statement)
        sqlite3_bind_int64(statement, 2, watermark)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let row = decode(statement) else { throw ReaderError.sqlite(status) }
        return row
    }

    func markSeen(_ path: String) throws {
        guard let database else { throw ReaderError.open }
        let cost = path.utf8.count + 96
        guard seenBytes <= maxSeenBytes - cost else { throw ReaderError.tempCap }
        let statement = try prepare("INSERT OR IGNORE INTO temp.verifier_seen(path) VALUES (?)")
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, to: statement)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw status == SQLITE_FULL ? ReaderError.tempCap : ReaderError.sqlite(status)
        }
        if sqlite3_changes(database) > 0 { seenBytes += cost }
    }

    func wasSeen(_ path: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM temp.verifier_seen WHERE path=? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return false }
        guard status == SQLITE_ROW else { throw ReaderError.sqlite(status) }
        return true
    }

    func page(after rowID: Int64, limit: Int) throws -> Page {
        guard (1...256).contains(limit) else { throw ReaderError.tempCap }
        let statement = try prepare(
            "SELECT rowid,revision,path,size,inode,uid,mode,mtime_seconds,mtime_nanoseconds,digest "
                + "FROM main.revision_catalog WHERE rowid>? AND rowid<=? ORDER BY rowid LIMIT ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, rowID)
        sqlite3_bind_int64(statement, 2, watermark)
        sqlite3_bind_int64(statement, 3, Int64(limit))
        var rows: [Row] = []
        rows.reserveCapacity(limit)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let row = decode(statement) else { throw ReaderError.sqlite(status) }
            rows.append(row)
        }
        catalogueRowsRead += rows.count
        maxPageRows = max(maxPageRows, rows.count)
        maxStatementRows = max(maxStatementRows, rows.count)
        return Page(rows: rows, nextRowID: rows.last?.rowID)
    }

    private func validate(identity: String) throws {
        let database = try requireDatabase()
        for (key, expected) in [
            ("identity", identity), ("schema", "11"), ("engine", "tractanda-sqlite-catalogue-v11"),
        ] {
            let statement = try prepare("SELECT value FROM main.checkpoint_meta WHERE key=?")
            defer { sqlite3_finalize(statement) }
            try bind(key, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW,
                sqlite3_column_text(statement, 0).map({ String(cString: $0) }) == expected,
                sqlite3_step(statement) == SQLITE_DONE
            else { throw ReaderError.identity }
        }
        let columns = try prepare(
            "SELECT revision,item,path,parent,actor,operation,size,inode,uid,mode,mtime_seconds,"
                + "mtime_nanoseconds,digest,created_at FROM main.revision_catalog LIMIT 0")
        defer { sqlite3_finalize(columns) }
        guard sqlite3_step(columns) == SQLITE_DONE else { throw ReaderError.schema }
        _ = database
    }

    private func requireDatabase() throws -> OpaquePointer {
        guard let database else { throw ReaderError.open }
        return database
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw ReaderError.open }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw ReaderError.sqlite(status) }
        return statement
    }

    private func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw ReaderError.sqlite(status) }
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else { throw ReaderError.sqlite(status) }
        return sqlite3_column_int64(statement, 0)
    }

    private func bind(_ string: String, at index: Int32, to statement: OpaquePointer) throws {
        let status = string.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        guard status == SQLITE_OK else { throw ReaderError.sqlite(status) }
    }

    private func decode(_ statement: OpaquePointer) -> Row? {
        func text(_ column: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, column) else { return nil }
            return String(
                bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))),
                encoding: .utf8)
        }
        guard let revision = text(1), let path = text(2), let hex = text(9), hex.count == 64 else {
            return nil
        }
        var digest = Data()
        var index = hex.startIndex
        for _ in 0..<32 {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            digest.append(byte)
            index = end
        }
        return Row(
            rowID: sqlite3_column_int64(statement, 0), revisionID: revision, path: path,
            size: UInt64(sqlite3_column_int64(statement, 3)),
            inode: UInt64(sqlite3_column_int64(statement, 4)),
            uid: UInt32(sqlite3_column_int64(statement, 5)), mode: UInt32(sqlite3_column_int64(statement, 6)),
            modificationSeconds: sqlite3_column_int64(statement, 7),
            modificationNanoseconds: Int32(sqlite3_column_int64(statement, 8)), digest: digest)
    }
}
