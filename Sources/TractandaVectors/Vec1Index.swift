import CSQLite
import CTractandaVec1
import Crypto
import Foundation
import TractandaClient

public struct VectorRecord: Sendable, Equatable {
    public let id: String
    public let itemID: String
    public let revisionID: String
    public let contentHash: String
    public let chunkIndex: Int
    public let text: String
    public let vector: [Float]

    public init(
        id: String, itemID: String, revisionID: String, contentHash: String,
        chunkIndex: Int, text: String, vector: [Float]
    ) {
        self.id = id
        self.itemID = itemID
        self.revisionID = revisionID
        self.contentHash = contentHash
        self.chunkIndex = chunkIndex
        self.text = text
        self.vector = vector
    }
}

public struct Vec1SearchHit: Sendable, Equatable {
    public let id: String
    public let itemID: String
    public let revisionID: String
    public let contentHash: String
    public let chunkIndex: Int
    public let text: String
    public let distance: Float
}

/// Current canonical identity required for a candidate to participate in a
/// query. This prevents stale cached rows from affecting ranking.
public struct Vec1RecordFilter: Sendable, Equatable {
    public let itemID: String
    public let revisionID: String
    public let contentHash: String

    public init(itemID: String, revisionID: String, contentHash: String) {
        self.itemID = itemID
        self.revisionID = revisionID
        self.contentHash = contentHash
    }
}

/// Ledger-only state for reconciliation. Reading it never touches vector blobs.
public struct Vec1ItemMetadata: Sendable, Equatable {
    public let itemID: String
    public let revisionID: String
    public let contentHash: String
    public let recordCount: Int
}

/// A disposable, per-profile semantic index. Instances are intentionally
/// thread-confined: use one instance from one executor at a time.
public final class Vec1Index {
    public let dimensions: Int
    public let profileID: String

    private var database: OpaquePointer?

    public init(path: String, dimensions: Int, profileID: String) throws {
        guard (1...4096).contains(dimensions) else {
            throw error("invalidVectorDimensions", "Vector dimensions must be from 1 through 4096.")
        }
        try Self.validateOpaque(profileID, name: "profileID", maximum: 512)

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &opened, flags, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw error("vectorIndexOpen", "Cannot open the semantic index.")
        }
        database = opened
        self.dimensions = dimensions
        self.profileID = profileID

        do {
            var registrationError: UnsafeMutablePointer<CChar>?
            guard tractanda_vec1_register(opened, &registrationError) == SQLITE_OK else {
                let detail = registrationError.map { String(cString: $0) } ?? "Vec1 registration failed."
                sqlite3_free(registrationError)
                throw error("vectorIndexUnsupported", detail)
            }
            try execute("PRAGMA foreign_keys = ON")
            try execute(
                "CREATE TABLE IF NOT EXISTS vector_index_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID"
            )
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS semantic_vectors USING vec1(vector)")
            try execute(
                "CREATE TABLE IF NOT EXISTS vector_ledger (record_id TEXT PRIMARY KEY, item_id TEXT NOT NULL, revision_id TEXT NOT NULL, content_hash TEXT NOT NULL, chunk_index INTEGER NOT NULL, text TEXT NOT NULL, vector_rowid INTEGER NOT NULL UNIQUE)"
            )
            try execute("CREATE INDEX IF NOT EXISTS vector_ledger_item ON vector_ledger(item_id)")
            try execute(
                "CREATE TEMP TABLE IF NOT EXISTS vec1_allowed_items (item_id TEXT PRIMARY KEY) WITHOUT ROWID")
            try execute(
                "CREATE TEMP TABLE IF NOT EXISTS vec1_allowed_records (item_id TEXT PRIMARY KEY, revision_id TEXT NOT NULL, content_hash TEXT NOT NULL) WITHOUT ROWID"
            )
            try configureOrVerifyMetadata()
        } catch {
            sqlite3_close_v2(opened)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    public func replace(itemID: String, records: [VectorRecord]) throws {
        try Self.validateOpaque(itemID, name: "itemID", maximum: 512)
        var identifiers = Set<String>()
        var chunks = Set<Int>()
        for record in records {
            guard record.itemID == itemID else {
                throw error(
                    "invalidVectorRecord", "Each replacement record must belong to the supplied item.")
            }
            guard identifiers.insert(record.id).inserted, chunks.insert(record.chunkIndex).inserted else {
                throw error("invalidVectorRecord", "Record IDs and chunk indexes must be unique per item.")
            }
            try validate(record)
        }

        try transaction {
            try deleteItem(itemID)
            for record in records { try insert(record) }
        }
    }

    public func remove(itemID: String) throws {
        try Self.validateOpaque(itemID, name: "itemID", maximum: 512)
        try transaction { try deleteItem(itemID) }
    }

    /// Relabels records after a non-semantic revision without touching Vec1 data.
    public func updateRevision(itemID: String, revisionID: String, contentHash: String) throws {
        try Self.validateOpaque(itemID, name: "itemID", maximum: 512)
        try Self.validateOpaque(revisionID, name: "revisionID", maximum: 512)
        try Self.validateOpaque(contentHash, name: "contentHash", maximum: 512)
        try withStatement(
            "UPDATE vector_ledger SET revision_id = ?1, content_hash = ?2 WHERE item_id = ?3 AND (revision_id != ?1 OR content_hash != ?2)"
        ) { statement in
            try bind(revisionID, to: statement, index: 1)
            try bind(contentHash, to: statement, index: 2)
            try bind(itemID, to: statement, index: 3)
            try stepDone(statement)
        }
    }

    public func reset() throws {
        try transaction {
            try execute("DELETE FROM vector_ledger")
            try execute("DELETE FROM semantic_vectors")
        }
    }

    public func records() throws -> [VectorRecord] {
        try withStatement(
            "SELECT l.record_id, l.item_id, l.revision_id, l.content_hash, l.chunk_index, l.text, v.vector FROM vector_ledger l JOIN semantic_vectors v ON v.rowid = l.vector_rowid ORDER BY l.item_id, l.chunk_index"
        ) { statement in
            var result: [VectorRecord] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let id = columnText(statement, 0), let itemID = columnText(statement, 1),
                    let revisionID = columnText(statement, 2), let contentHash = columnText(statement, 3),
                    let text = columnText(statement, 5), let vector = columnVector(statement, 6)
                else {
                    throw error("vectorIndexCorrupt", "A stored vector record is malformed.")
                }
                result.append(
                    VectorRecord(
                        id: id, itemID: itemID, revisionID: revisionID, contentHash: contentHash,
                        chunkIndex: Int(sqlite3_column_int64(statement, 4)), text: text, vector: vector))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw databaseError("vectorIndexRead") }
            return result
        }
    }

    /// Returns item identity from the scalar ledger, without reading Vec1 data.
    public func itemMetadata(itemID: String) throws -> Vec1ItemMetadata? {
        try Self.validateOpaque(itemID, name: "itemID", maximum: 512)
        return try withStatement(
            "SELECT item_id, revision_id, content_hash, count(*) FROM vector_ledger WHERE item_id = ?1 GROUP BY item_id, revision_id, content_hash"
        ) { statement in
            try bind(itemID, to: statement, index: 1)
            let first = sqlite3_step(statement)
            if first == SQLITE_DONE { return nil }
            guard first == SQLITE_ROW,
                let storedItemID = columnText(statement, 0),
                let revisionID = columnText(statement, 1),
                let contentHash = columnText(statement, 2)
            else { throw databaseError("vectorIndexMetadata") }
            let recordCount = Int(sqlite3_column_int64(statement, 3))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw error("vectorIndexCorrupt", "An item has conflicting vector ledger identities.")
            }
            return Vec1ItemMetadata(
                itemID: storedItemID,
                revisionID: revisionID,
                contentHash: contentHash,
                recordCount: recordCount)
        }
    }

    public func itemMetadata() throws -> [Vec1ItemMetadata] {
        try withStatement(
            "SELECT item_id, revision_id, content_hash, count(*) FROM vector_ledger GROUP BY item_id, revision_id, content_hash ORDER BY item_id"
        ) { statement in
            var result: [Vec1ItemMetadata] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let itemID = columnText(statement, 0), let revisionID = columnText(statement, 1),
                    let contentHash = columnText(statement, 2)
                else {
                    throw error("vectorIndexCorrupt", "A vector ledger record is malformed.")
                }
                result.append(
                    Vec1ItemMetadata(
                        itemID: itemID,
                        revisionID: revisionID,
                        contentHash: contentHash,
                        recordCount: Int(sqlite3_column_int64(statement, 3))))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw databaseError("vectorIndexMetadata") }
            var seen = Set<String>()
            guard result.allSatisfy({ seen.insert($0.itemID).inserted }) else {
                throw error("vectorIndexCorrupt", "An item has conflicting vector ledger identities.")
            }
            return result
        }
    }

    /// Authorization is materialized before distance calculation, so hidden
    /// records cannot consume the caller's result limit.
    public func search(query: [Float], allowedItemIDs: Set<String>, limit: Int) throws -> [Vec1SearchHit] {
        try validate(vector: query)
        guard (1...256).contains(limit) else {
            throw error("invalidVectorLimit", "Search limit must be from 1 through 256.")
        }
        if allowedItemIDs.isEmpty { return [] }
        for itemID in allowedItemIDs { try Self.validateOpaque(itemID, name: "itemID", maximum: 512) }

        try transaction {
            try execute("DELETE FROM vec1_allowed_items")
            try withStatement("INSERT INTO vec1_allowed_items(item_id) VALUES (?1)") { statement in
                for itemID in allowedItemIDs {
                    try bind(itemID, to: statement, index: 1)
                    try stepDone(statement)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }
        }

        return try withStatement(
            "SELECT l.record_id, l.item_id, l.revision_id, l.content_hash, l.chunk_index, l.text, vec1_cos_distance(?1, v.vector) AS distance FROM vec1_allowed_items a JOIN vector_ledger l ON l.item_id = a.item_id JOIN semantic_vectors v ON v.rowid = l.vector_rowid ORDER BY distance ASC, l.record_id ASC LIMIT ?2"
        ) { statement in
            try bind(vector: query, to: statement, index: 1)
            guard sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else {
                throw databaseError("vectorIndexQuery")
            }
            var result: [Vec1SearchHit] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let id = columnText(statement, 0), let itemID = columnText(statement, 1),
                    let revisionID = columnText(statement, 2), let contentHash = columnText(statement, 3),
                    let text = columnText(statement, 5)
                else {
                    throw error("vectorIndexCorrupt", "A stored vector record is malformed.")
                }
                result.append(
                    Vec1SearchHit(
                        id: id, itemID: itemID, revisionID: revisionID, contentHash: contentHash,
                        chunkIndex: Int(sqlite3_column_int64(statement, 4)), text: text,
                        distance: Float(sqlite3_column_double(statement, 6))))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw databaseError("vectorIndexQuery") }
            return result
        }
    }

    /// Returns at most one current passage per item. Candidate identity is
    /// joined before cosine distance is calculated and before the result limit.
    public func searchBestPerItem(
        query: [Float], allowedRecords: [Vec1RecordFilter], limit: Int
    ) throws -> [Vec1SearchHit] {
        try validate(vector: query)
        guard (1...256).contains(limit) else {
            throw error("invalidVectorLimit", "Search limit must be from 1 through 256.")
        }
        if allowedRecords.isEmpty { return [] }
        var itemIDs = Set<String>()
        for filter in allowedRecords {
            try Self.validateOpaque(filter.itemID, name: "itemID", maximum: 512)
            try Self.validateOpaque(filter.revisionID, name: "revisionID", maximum: 512)
            try Self.validateOpaque(filter.contentHash, name: "contentHash", maximum: 512)
            guard itemIDs.insert(filter.itemID).inserted else {
                throw error("invalidVectorRecord", "Candidate item identities must be unique.")
            }
        }
        try transaction {
            try execute("DELETE FROM vec1_allowed_records")
            try withStatement(
                "INSERT INTO vec1_allowed_records(item_id, revision_id, content_hash) VALUES (?1, ?2, ?3)"
            ) { statement in
                for filter in allowedRecords {
                    try bind(filter.itemID, to: statement, index: 1)
                    try bind(filter.revisionID, to: statement, index: 2)
                    try bind(filter.contentHash, to: statement, index: 3)
                    try stepDone(statement)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }
        }
        return try withStatement(
            "WITH scored AS (SELECT l.record_id, l.item_id, l.revision_id, l.content_hash, l.chunk_index, l.text, vec1_cos_distance(?1, v.vector) AS distance, ROW_NUMBER() OVER (PARTITION BY l.item_id ORDER BY vec1_cos_distance(?1, v.vector) ASC, l.record_id ASC) AS item_rank FROM vec1_allowed_records a JOIN vector_ledger l ON l.item_id = a.item_id AND l.revision_id = a.revision_id AND l.content_hash = a.content_hash JOIN semantic_vectors v ON v.rowid = l.vector_rowid) SELECT record_id, item_id, revision_id, content_hash, chunk_index, text, distance FROM scored WHERE item_rank = 1 ORDER BY distance ASC, record_id ASC LIMIT ?2"
        ) { statement in
            try bind(vector: query, to: statement, index: 1)
            guard sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else {
                throw databaseError("vectorIndexQuery")
            }
            return try readHits(statement)
        }
    }

    public static func stableContentHash(_ text: String) -> String {
        stableDataHash(Data(text.utf8))
    }

    public static func stableDataHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func configureOrVerifyMetadata() throws {
        let storedDimensions = try metadataValue("dimensions")
        let storedProfile = try metadataValue("profileID")
        if let storedDimensions, storedDimensions != String(dimensions) {
            throw error("vectorIndexMismatch", "Semantic index dimensions do not match this profile.")
        }
        if let storedProfile, storedProfile != profileID {
            throw error("vectorIndexMismatch", "Semantic index profile does not match this profile.")
        }
        guard (storedDimensions == nil) == (storedProfile == nil) else {
            throw error("vectorIndexCorrupt", "Semantic index metadata is incomplete.")
        }
        if storedDimensions == nil {
            try transaction {
                try setMetadata("dimensions", value: String(dimensions))
                try setMetadata("profileID", value: profileID)
                try execute(
                    #"INSERT INTO semantic_vectors(cmd, arg) VALUES ('rebuild', '{"index":"flat","distance":"cos"}')"#
                )
            }
        }
    }

    private func metadataValue(_ key: String) throws -> String? {
        try withStatement("SELECT value FROM vector_index_metadata WHERE key = ?1") { statement in
            try bind(key, to: statement, index: 1)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let value = columnText(statement, 0) else {
                throw databaseError("vectorIndexMetadata")
            }
            return value
        }
    }

    private func readHits(_ statement: OpaquePointer) throws -> [Vec1SearchHit] {
        var result: [Vec1SearchHit] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let id = columnText(statement, 0), let itemID = columnText(statement, 1),
                let revisionID = columnText(statement, 2), let contentHash = columnText(statement, 3),
                let text = columnText(statement, 5)
            else {
                throw error("vectorIndexCorrupt", "A stored vector record is malformed.")
            }
            result.append(
                Vec1SearchHit(
                    id: id, itemID: itemID, revisionID: revisionID, contentHash: contentHash,
                    chunkIndex: Int(sqlite3_column_int64(statement, 4)), text: text,
                    distance: Float(sqlite3_column_double(statement, 6))))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw databaseError("vectorIndexQuery") }
        return result
    }

    private func setMetadata(_ key: String, value: String) throws {
        try withStatement("INSERT INTO vector_index_metadata(key, value) VALUES (?1, ?2)") { statement in
            try bind(key, to: statement, index: 1)
            try bind(value, to: statement, index: 2)
            try stepDone(statement)
        }
    }

    private func deleteItem(_ itemID: String) throws {
        try withStatement(
            "DELETE FROM semantic_vectors WHERE rowid IN (SELECT vector_rowid FROM vector_ledger WHERE item_id = ?1)"
        ) { statement in
            try bind(itemID, to: statement, index: 1)
            try stepDone(statement)
        }
        try withStatement("DELETE FROM vector_ledger WHERE item_id = ?1") { statement in
            try bind(itemID, to: statement, index: 1)
            try stepDone(statement)
        }
    }

    private func insert(_ record: VectorRecord) throws {
        try withStatement("INSERT INTO semantic_vectors(vector) VALUES (?1)") { statement in
            try bind(vector: record.vector, to: statement, index: 1)
            try stepDone(statement)
        }
        let rowID = sqlite3_last_insert_rowid(requireDatabase())
        try withStatement(
            "INSERT INTO vector_ledger(record_id, item_id, revision_id, content_hash, chunk_index, text, vector_rowid) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)"
        ) { statement in
            try bind(record.id, to: statement, index: 1)
            try bind(record.itemID, to: statement, index: 2)
            try bind(record.revisionID, to: statement, index: 3)
            try bind(record.contentHash, to: statement, index: 4)
            guard sqlite3_bind_int64(statement, 5, Int64(record.chunkIndex)) == SQLITE_OK else {
                throw databaseError("vectorIndexWrite")
            }
            try bind(record.text, to: statement, index: 6)
            guard sqlite3_bind_int64(statement, 7, rowID) == SQLITE_OK else {
                throw databaseError("vectorIndexWrite")
            }
            try stepDone(statement)
        }
    }

    private func validate(_ record: VectorRecord) throws {
        try Self.validateOpaque(record.id, name: "recordID", maximum: 512)
        try Self.validateOpaque(record.itemID, name: "itemID", maximum: 512)
        try Self.validateOpaque(record.revisionID, name: "revisionID", maximum: 512)
        try Self.validateOpaque(record.contentHash, name: "contentHash", maximum: 512)
        guard record.chunkIndex >= 0 else {
            throw error("invalidVectorRecord", "Chunk index must not be negative.")
        }
        guard record.text.utf8.count <= 1_048_576, !record.text.utf8.contains(0) else {
            throw error("invalidVectorRecord", "Chunk text must be at most 1 MiB and contain no NUL.")
        }
        try validate(vector: record.vector)
    }

    private func validate(vector: [Float]) throws {
        guard vector.count == dimensions else {
            throw error("invalidVectorDimensions", "Vector dimensions do not match this index.")
        }
        var squaredNorm = 0.0
        for value in vector {
            guard value.isFinite else { throw error("invalidVector", "Vectors must contain finite values.") }
            squaredNorm += Double(value) * Double(value)
        }
        guard squaredNorm.isFinite, squaredNorm > 0 else {
            throw error("invalidVector", "Vectors must have a nonzero finite norm.")
        }
    }

    private static func validateOpaque(_ value: String, name: String, maximum: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximum, !value.utf8.contains(0) else {
            throw error("invalidVectorRecord", "\(name) must be nonempty, bounded text without NUL.")
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(requireDatabase(), sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "SQLite operation failed."
            sqlite3_free(message)
            throw error("vectorIndexDatabase", detail)
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(requireDatabase(), sql, -1, &statement, nil) == SQLITE_OK, let statement
        else {
            throw databaseError("vectorIndexPrepare")
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, transientDestructor) == SQLITE_OK else {
            throw databaseError("vectorIndexBind")
        }
    }

    private func bind(vector: [Float], to statement: OpaquePointer, index: Int32) throws {
        let status = vector.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transientDestructor)
        }
        guard status == SQLITE_OK else { throw databaseError("vectorIndexBind") }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError("vectorIndexWrite") }
    }

    private func requireDatabase() -> OpaquePointer {
        guard let database else { fatalError("Vec1Index used after deinitialization") }
        return database
    }

    private func databaseError(_ code: String) -> TractandaError {
        let database = requireDatabase()
        return error(code, String(cString: sqlite3_errmsg(database)))
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func columnVector(_ statement: OpaquePointer, _ index: Int32) -> [Float]? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount == dimensions * MemoryLayout<Float>.size else { return nil }
        return Array(UnsafeRawBufferPointer(start: pointer, count: byteCount).bindMemory(to: Float.self))
    }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func error(_ code: String, _ description: String) -> TractandaError {
    TractandaError(code, description)
}
