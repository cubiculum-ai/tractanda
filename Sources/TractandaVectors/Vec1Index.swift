import CSQLite
import CTractandaVec1
import Crypto
import Foundation
import TractandaClient

public struct VectorRecord: Codable, Sendable, Equatable {
    public let id: String
    public let itemID: String
    public let revisionID: String
    public let contentHash: String
    public let chunkIndex: Int
    public let unitOrdinal: Int64
    public let byteStart: Int64
    public let byteEnd: Int64
    public let unitByteStart: Int64
    public let unitByteEnd: Int64
    public let text: String
    public let vector: [Float]

    public init(
        id: String, itemID: String, revisionID: String, contentHash: String,
        chunkIndex: Int, text: String, vector: [Float], unitOrdinal: Int64 = 0,
        byteStart: Int64 = 0, byteEnd: Int64? = nil, unitByteStart: Int64 = 0, unitByteEnd: Int64? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.revisionID = revisionID
        self.contentHash = contentHash
        self.chunkIndex = chunkIndex
        self.unitOrdinal = unitOrdinal
        self.byteStart = byteStart
        self.byteEnd = byteEnd ?? (byteStart.addingReportingOverflow(Int64(text.utf8.count)).partialValue)
        self.unitByteStart = unitByteStart
        self.unitByteEnd =
            unitByteEnd ?? (unitByteStart.addingReportingOverflow(Int64(text.utf8.count)).partialValue)
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
    public let unitOrdinal: Int64
    public let byteStart: Int64
    public let byteEnd: Int64
    public let unitByteStart: Int64
    public let unitByteEnd: Int64
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

/// Core supplies the hosting filesystem/shared-quota policy without a Vectors-to-Core dependency.
public struct Vec1WriteBatch: Sendable {
    public enum Phase: Sendable, Equatable {
        case beforeAppend, afterAppend, afterCommit, rollback, promotion, disposal
    }
    public let phase: Phase
    public let generationID: String
    public let estimatedAdditionalBytes: Int64
    public let recordCount: Int
    /// Normative persisted charge is exact JSON-encoded payload bytes, never filesystem allocation.
    public let encodedAdditionalBytes: Int64
    public let retainedEncodedBytes: Int64
    public init(
        phase: Phase, generationID: String, estimatedAdditionalBytes: Int64, recordCount: Int,
        encodedAdditionalBytes: Int64, retainedEncodedBytes: Int64
    ) {
        self.phase = phase
        self.generationID = generationID
        self.estimatedAdditionalBytes = estimatedAdditionalBytes
        self.recordCount = recordCount
        self.encodedAdditionalBytes = encodedAdditionalBytes
        self.retainedEncodedBytes = retainedEncodedBytes
    }
}

public struct Vec1RetainedWork: Sendable, Equatable {
    public let generationID: String
    public let encodedBytes: Int64
    public let state: String
}

/// An opaque, profile-bound staging capability. Unpublished records never participate in search.
public struct Vec1Generation: Codable, Sendable, Equatable {
    public let generationID: String
    public let itemID: String
    public let revisionID: String
    public let contentHash: String
    public let profileID: String
}

struct Vec1GCStats {
    var candidateGenerations = 0
    var rowsExamined = 0
    var rowsDeleted = 0
    var headersAcknowledged = 0
    var candidateVMSteps = 0
    var rowVMSteps = 0
    var cursor = ""
}

/// A disposable, per-profile semantic index. Instances are intentionally
/// thread-confined: use one instance from one executor at a time.
public final class Vec1Index {
    public let dimensions: Int
    public let profileID: String

    private var database: OpaquePointer?
    private let makeGenerationID: () throws -> String
    private let writeBoundary: (Vec1WriteBatch) throws -> Void
    private(set) var cleanupStatsForTesting = Vec1GCStats()

    public init(
        path: String, dimensions: Int, profileID: String, makeGenerationID: @escaping () throws -> String,
        writeBoundary: @escaping (Vec1WriteBatch) throws -> Void = { _ in }
    ) throws {
        self.writeBoundary = writeBoundary
        self.makeGenerationID = makeGenerationID
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
                "CREATE TABLE IF NOT EXISTS vector_ledger (generation_id TEXT NOT NULL, record_id TEXT NOT NULL, item_id TEXT NOT NULL, revision_id TEXT NOT NULL, content_hash TEXT NOT NULL, chunk_index INTEGER NOT NULL, unit_ordinal INTEGER NOT NULL, byte_start INTEGER NOT NULL, byte_end INTEGER NOT NULL, unit_byte_start INTEGER NOT NULL, unit_byte_end INTEGER NOT NULL, text TEXT NOT NULL, vector_rowid INTEGER NOT NULL UNIQUE, PRIMARY KEY(generation_id,record_id), UNIQUE(generation_id,chunk_index))"
            )
            try execute("CREATE INDEX IF NOT EXISTS vector_ledger_item ON vector_ledger(item_id)")
            try execute(
                "CREATE TABLE IF NOT EXISTS vector_generations (generation_id TEXT PRIMARY KEY, item_id TEXT NOT NULL, revision_id TEXT NOT NULL, content_hash TEXT NOT NULL, record_count INTEGER NOT NULL, state TEXT NOT NULL, homogeneous INTEGER NOT NULL, encoded_bytes INTEGER NOT NULL)"
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS vector_generation_state ON vector_generations(state,generation_id)"
            )
            try execute(
                "CREATE TABLE IF NOT EXISTS vector_heads (item_id TEXT PRIMARY KEY, generation_id TEXT NOT NULL UNIQUE, revision_override TEXT, hash_override TEXT)"
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS vector_ledger_gc ON vector_ledger(generation_id,chunk_index,vector_rowid)"
            )
            try execute(
                "CREATE TABLE IF NOT EXISTS vector_gc_candidate (generation_id TEXT PRIMARY KEY) WITHOUT ROWID"
            )
            try execute(
                "CREATE TABLE IF NOT EXISTS vector_gc_cursor (singleton INTEGER PRIMARY KEY CHECK(singleton=1),generation_id TEXT NOT NULL)"
            )
            try execute("INSERT OR IGNORE INTO vector_gc_cursor VALUES (1,'')")
            // Every retirement transition records a candidate; opening never scans active rows to backfill.
            try execute(
                "CREATE TRIGGER IF NOT EXISTS vector_head_deleted AFTER DELETE ON vector_heads BEGIN INSERT OR IGNORE INTO vector_gc_candidate VALUES (OLD.generation_id); END"
            )
            try execute(
                "CREATE TRIGGER IF NOT EXISTS vector_head_replaced AFTER UPDATE OF generation_id ON vector_heads WHEN OLD.generation_id!=NEW.generation_id BEGIN INSERT OR IGNORE INTO vector_gc_candidate VALUES (OLD.generation_id); END"
            )
            try execute(
                "CREATE TRIGGER IF NOT EXISTS vector_work_retired AFTER UPDATE OF state ON vector_generations WHEN NEW.state IN ('discarded','disposed') BEGIN INSERT OR IGNORE INTO vector_gc_candidate VALUES (NEW.generation_id); END"
            )
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

    /// Each append commits at most sixteen records. Publication changes only the head binding.
    public func beginGeneration(itemID: String, revisionID: String, contentHash: String) throws
        -> Vec1Generation
    {
        for (name, value) in [("itemID", itemID), ("revisionID", revisionID), ("contentHash", contentHash)] {
            try Self.validateOpaque(value, name: name, maximum: 512)
        }
        let generationID = try makeGenerationID()
        try Identifier.validate(generationID)
        guard let uuid = UUID(uuidString: generationID) else {
            throw error("invalidUUID", "Generation identity must be UUIDv1.")
        }
        var raw = uuid.uuid
        let valid = withUnsafeBytes(of: &raw) { $0[6] >> 4 == 1 && $0[8] & 0xC0 == 0x80 }
        guard valid else { throw error("invalidUUID", "Generation identity must be an RFC UUIDv1.") }
        _ = try cleanupUnpublished()
        let generation = Vec1Generation(
            generationID: generationID, itemID: itemID,
            revisionID: revisionID, contentHash: contentHash, profileID: profileID)
        let charge = Int64(try Self.encodeGeneration(generation).count)
        do {
            try writeBoundary(
                Vec1WriteBatch(
                    phase: .beforeAppend, generationID: generation.generationID,
                    estimatedAdditionalBytes: 65_536,
                    recordCount: 0, encodedAdditionalBytes: charge, retainedEncodedBytes: 0))
            try transaction {
                let pending = try withStatement(
                    "SELECT count(*) FROM (SELECT 1 FROM vector_generations WHERE state='staging' LIMIT 64)"
                ) { statement in
                    guard sqlite3_step(statement) == SQLITE_ROW else {
                        throw databaseError("vectorIndexRead")
                    }
                    return sqlite3_column_int(statement, 0)
                }
                guard pending < 64 else {
                    throw error(
                        "resourceLimit",
                        "The semantic generation work window is full; resume or discard pending work.")
                }
                try withStatement("INSERT INTO vector_generations VALUES (?1,?2,?3,?4,0,'staging',1,?5)") {
                    statement in
                    try bind(generation.generationID, to: statement, index: 1)
                    try bind(itemID, to: statement, index: 2)
                    try bind(revisionID, to: statement, index: 3)
                    try bind(contentHash, to: statement, index: 4)
                    guard sqlite3_bind_int64(statement, 5, charge) == SQLITE_OK else {
                        throw databaseError("vectorIndexWrite")
                    }
                    try stepDone(statement)
                }
                try writeBoundary(
                    Vec1WriteBatch(
                        phase: .afterAppend, generationID: generation.generationID,
                        estimatedAdditionalBytes: 0,
                        recordCount: 0, encodedAdditionalBytes: charge, retainedEncodedBytes: charge))
            }
        } catch {
            if sqlite3_get_autocommit(requireDatabase()) == 1 {
                do {
                    if try persistedCharge(generationID: generation.generationID) == nil {
                        try writeBoundary(
                            .init(
                                phase: .rollback, generationID: generation.generationID,
                                estimatedAdditionalBytes: 0, recordCount: 0, encodedAdditionalBytes: 0,
                                retainedEncodedBytes: 0))
                    }
                } catch {
                    // Unknown rollback state retains its reservation.
                }
            }
            throw error
        }
        do {
            try writeBoundary(
                .init(
                    phase: .afterCommit, generationID: generation.generationID,
                    estimatedAdditionalBytes: 0, recordCount: 0, encodedAdditionalBytes: charge,
                    retainedEncodedBytes: charge))
        } catch {
            try? discardGeneration(generation)
            throw error
        }
        return generation
    }

    public func appendGeneration(_ generation: Vec1Generation, records: [VectorRecord]) throws {
        try appendGeneration(generation, records: records, requireIdentity: true)
    }

    private func appendGeneration(
        _ generation: Vec1Generation, records: [VectorRecord], requireIdentity: Bool
    ) throws {
        guard (1...16).contains(records.count) else {
            throw error("invalidVectorRecord", "Append one through sixteen records per batch.")
        }
        for record in records {
            try validate(record)
            guard record.itemID == generation.itemID,
                !requireIdentity
                    || (record.revisionID == generation.revisionID
                        && record.contentHash == generation.contentHash)
            else { throw error("invalidVectorRecord", "A generation record has another source identity.") }
        }
        var encoded: Int64 = 0
        for record in records {
            let next = encoded.addingReportingOverflow(Int64(try Self.encodeRecord(record).count))
            guard !next.overflow else { throw error("resourceLimit", "Vector payload charge overflow.") }
            encoded = next.partialValue
        }
        let priorCharge = try generationEncodedBytes(generation)
        let nextCharge = priorCharge.addingReportingOverflow(encoded)
        guard !nextCharge.overflow else { throw error("resourceLimit", "Vector retained charge overflow.") }
        let growth = encoded.multipliedReportingOverflow(by: 4)
        let estimate = growth.partialValue.addingReportingOverflow(65_536)
        guard !growth.overflow, !estimate.overflow else {
            throw error("resourceLimit", "Vector batch estimate overflow.")
        }
        do {
            try writeBoundary(
                Vec1WriteBatch(
                    phase: .beforeAppend, generationID: generation.generationID,
                    estimatedAdditionalBytes: estimate.partialValue, recordCount: records.count,
                    encodedAdditionalBytes: encoded, retainedEncodedBytes: priorCharge))
            try transaction {
                let count = try generationCount(generation, state: "staging")
                guard count <= Int64.max - Int64(records.count) else {
                    throw error("invalidVectorRecord", "Generation record count overflow.")
                }
                for record in records { try insert(record, generationID: generation.generationID) }
                try withStatement(
                    "UPDATE vector_generations SET record_count=?1,homogeneous=MIN(homogeneous,?3),encoded_bytes=?4 WHERE generation_id=?2"
                ) {
                    statement in
                    guard sqlite3_bind_int64(statement, 1, count + Int64(records.count)) == SQLITE_OK else {
                        throw databaseError("vectorIndexWrite")
                    }
                    try bind(generation.generationID, to: statement, index: 2)
                    let homogeneous = records.allSatisfy {
                        $0.revisionID == generation.revisionID && $0.contentHash == generation.contentHash
                    }
                    guard sqlite3_bind_int(statement, 3, homogeneous ? 1 : 0) == SQLITE_OK else {
                        throw databaseError("vectorIndexWrite")
                    }
                    guard sqlite3_bind_int64(statement, 4, nextCharge.partialValue) == SQLITE_OK else {
                        throw databaseError("vectorIndexWrite")
                    }
                    try stepDone(statement)
                }
                // A failed post-write observation rolls this batch back; already staged work stays hidden.
                try writeBoundary(
                    Vec1WriteBatch(
                        phase: .afterAppend, generationID: generation.generationID,
                        estimatedAdditionalBytes: 0,
                        recordCount: records.count, encodedAdditionalBytes: encoded,
                        retainedEncodedBytes: nextCharge.partialValue))
            }
        } catch {
            if sqlite3_get_autocommit(requireDatabase()) == 1 {
                do {
                    if try persistedCharge(generationID: generation.generationID) == priorCharge {
                        try writeBoundary(
                            .init(
                                phase: .rollback, generationID: generation.generationID,
                                estimatedAdditionalBytes: 0, recordCount: 0, encodedAdditionalBytes: 0,
                                retainedEncodedBytes: priorCharge))
                    }
                } catch {
                    // Unknown rollback state retains its reservation.
                }
            }
            throw error
        }
        try writeBoundary(
            .init(
                phase: .afterCommit, generationID: generation.generationID,
                estimatedAdditionalBytes: 0, recordCount: records.count, encodedAdditionalBytes: encoded,
                retainedEncodedBytes: nextCharge.partialValue))
    }

    public func publishGeneration(_ generation: Vec1Generation, expectedRecordCount: Int64) throws {
        guard expectedRecordCount > 0 else {
            throw error("invalidVectorRecord", "Publish a nonempty complete generation.")
        }
        let charge = try generationEncodedBytes(generation)
        try transaction {
            guard try generationCount(generation, state: "staging") == expectedRecordCount else {
                throw error("invalidVectorRecord", "Generation count does not match its completed source.")
            }
            try withStatement("UPDATE vector_generations SET state='complete' WHERE generation_id=?1") {
                statement in
                try bind(generation.generationID, to: statement, index: 1)
                try stepDone(statement)
            }
            try withStatement(
                "INSERT INTO vector_heads VALUES (?1,?2,NULL,NULL) ON CONFLICT(item_id) DO UPDATE SET generation_id=excluded.generation_id,revision_override=NULL,hash_override=NULL"
            ) { statement in
                try bind(generation.itemID, to: statement, index: 1)
                try bind(generation.generationID, to: statement, index: 2)
                try stepDone(statement)
            }
        }
        try writeBoundary(
            .init(
                phase: .promotion, generationID: generation.generationID,
                estimatedAdditionalBytes: 0, recordCount: 0, encodedAdditionalBytes: 0,
                retainedEncodedBytes: charge))
    }

    /// Revokes an unpublished capability immediately; bulk disposal is separately bounded.
    public func discardGeneration(_ generation: Vec1Generation) throws {
        try transaction {
            _ = try generationCount(generation, state: "staging")
            try withStatement("UPDATE vector_generations SET state='discarded' WHERE generation_id=?1") {
                statement in
                try bind(generation.generationID, to: statement, index: 1)
                try stepDone(statement)
            }
        }
    }

    private static let cleanupCandidateSQL =
        "SELECT generation_id FROM vector_gc_candidate WHERE generation_id>?1 ORDER BY generation_id LIMIT 16"
    private static let cleanupRowSQL =
        "SELECT vector_rowid FROM vector_ledger WHERE generation_id=?1 ORDER BY chunk_index LIMIT ?2"

    /// Visits <=16 retirement candidates and deletes <=128 indexed per-generation rows.
    /// Active heads and live staging capabilities remain protected even if a stale candidate exists.
    @discardableResult
    public func cleanupUnpublished(limit: Int = 128) throws -> Int {
        guard (1...128).contains(limit) else {
            throw error("invalidVectorLimit", "Use a cleanup batch of one through128 rows.")
        }
        cleanupStatsForTesting = .init()
        var removed = 0
        var receipts: [(String, Int64)] = []  // <=16 durable disposed headers, never all generations.
        try transaction {
            var cursor = try withStatement("SELECT generation_id FROM vector_gc_cursor WHERE singleton=1") {
                statement in
                guard sqlite3_step(statement) == SQLITE_ROW, let value = columnText(statement, 0) else {
                    throw databaseError("vectorIndexRead")
                }
                return value
            }
            func candidates(after value: String) throws -> [String] {
                try withStatement(Self.cleanupCandidateSQL) { statement in
                    try bind(value, to: statement, index: 1)
                    var ids: [String] = []
                    var status = sqlite3_step(statement)
                    while status == SQLITE_ROW {
                        guard let id = columnText(statement, 0) else {
                            throw databaseError("vectorIndexRead")
                        }
                        ids.append(id)
                        status = sqlite3_step(statement)
                    }
                    cleanupStatsForTesting.candidateVMSteps += Int(
                        sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
                    guard status == SQLITE_DONE else { throw databaseError("vectorIndexRead") }
                    return ids
                }
            }
            var page = try candidates(after: cursor)
            if page.isEmpty, !cursor.isEmpty {
                cursor = ""
                page = try candidates(after: cursor)
            }
            for id in page {
                cleanupStatsForTesting.candidateGenerations += 1
                cursor = id
                let header: (String, Int64)? = try withStatement(
                    "SELECT g.state,g.encoded_bytes,EXISTS(SELECT 1 FROM vector_heads h WHERE h.generation_id=g.generation_id) FROM vector_generations g WHERE g.generation_id=?1"
                ) { statement in
                    try bind(id, to: statement, index: 1)
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { return nil }
                    guard status == SQLITE_ROW, let state = columnText(statement, 0),
                        sqlite3_column_int64(statement, 1) >= 0
                    else { throw databaseError("vectorIndexRead") }
                    if state == "staging" || sqlite3_column_int(statement, 2) != 0 { return ("protected", 0) }
                    return (state, sqlite3_column_int64(statement, 1))
                }
                guard let (state, charge) = header else {
                    try deleteRetirementCandidate(id)
                    continue
                }
                if state == "protected" { continue }
                guard ["complete", "discarded", "disposed"].contains(state) else {
                    throw error("vectorIndexCorrupt", "Retirement candidate has an invalid state.")
                }
                var rows: [Int64] = []
                let remaining = limit - removed
                if state != "disposed", remaining > 0 {
                    rows = try withStatement(Self.cleanupRowSQL) { statement in
                        try bind(id, to: statement, index: 1)
                        guard sqlite3_bind_int(statement, 2, Int32(remaining)) == SQLITE_OK else {
                            throw databaseError("vectorIndexRead")
                        }
                        var rows: [Int64] = []
                        var status = sqlite3_step(statement)
                        while status == SQLITE_ROW {
                            rows.append(sqlite3_column_int64(statement, 0))
                            status = sqlite3_step(statement)
                        }
                        cleanupStatsForTesting.rowVMSteps += Int(
                            sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
                        guard status == SQLITE_DONE else { throw databaseError("vectorIndexRead") }
                        return rows
                    }
                }
                cleanupStatsForTesting.rowsExamined += rows.count
                for row in rows {
                    try withStatement("DELETE FROM semantic_vectors WHERE rowid=?1") { statement in
                        guard sqlite3_bind_int64(statement, 1, row) == SQLITE_OK else {
                            throw databaseError("vectorIndexWrite")
                        }
                        try stepDone(statement)
                    }
                    try withStatement("DELETE FROM vector_ledger WHERE generation_id=?1 AND vector_rowid=?2")
                    { statement in
                        try bind(id, to: statement, index: 1)
                        guard sqlite3_bind_int64(statement, 2, row) == SQLITE_OK else {
                            throw databaseError("vectorIndexWrite")
                        }
                        try stepDone(statement)
                    }
                    removed += 1
                }
                let hasRows = try withStatement("SELECT 1 FROM vector_ledger WHERE generation_id=?1 LIMIT 1")
                { statement in
                    try bind(id, to: statement, index: 1)
                    let status = sqlite3_step(statement)
                    guard status == SQLITE_ROW || status == SQLITE_DONE else {
                        throw databaseError("vectorIndexRead")
                    }
                    return status == SQLITE_ROW
                }
                if !hasRows {
                    if state == "complete" {
                        _ = try deleteRetiredHeader(id, state: "complete")
                    } else {
                        // The committed header is the refund proof. Keep it until an observer ACKs.
                        try withStatement(
                            "UPDATE vector_generations SET state='disposed' WHERE generation_id=?1"
                        ) { statement in
                            try bind(id, to: statement, index: 1)
                            try stepDone(statement)
                        }
                        receipts.append((id, charge))
                    }
                }
                if removed == limit { break }
            }
            try withStatement("UPDATE vector_gc_cursor SET generation_id=?1 WHERE singleton=1") { statement in
                try bind(cursor, to: statement, index: 1)
                try stepDone(statement)
            }
            cleanupStatsForTesting.cursor = cursor
            cleanupStatsForTesting.rowsDeleted = removed
        }
        var firstFailure: Error?
        for (id, charge) in receipts {
            do {
                // All callbacks are attempted. Absolute-zero observers are idempotent after a crash
                // between their successful external observation and the short receipt-ACK commit.
                try writeBoundary(
                    .init(
                        phase: .disposal, generationID: id, estimatedAdditionalBytes: 0,
                        recordCount: 0, encodedAdditionalBytes: 0, retainedEncodedBytes: charge))
                var acknowledged = false
                try transaction { acknowledged = try deleteRetiredHeader(id, state: "disposed") }
                if acknowledged { cleanupStatsForTesting.headersAcknowledged += 1 }
            } catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
        return removed
    }

    private func deleteRetirementCandidate(_ id: String) throws {
        try withStatement("DELETE FROM vector_gc_candidate WHERE generation_id=?1") { statement in
            try bind(id, to: statement, index: 1)
            try stepDone(statement)
        }
    }
    private func deleteRetiredHeader(_ id: String, state: String) throws -> Bool {
        let deleted = try withStatement(
            "DELETE FROM vector_generations WHERE generation_id=?1 AND state=?2 AND NOT EXISTS(SELECT 1 FROM vector_heads WHERE generation_id=?1) AND NOT EXISTS(SELECT 1 FROM vector_ledger WHERE generation_id=?1)"
        ) { statement in
            try bind(id, to: statement, index: 1)
            try bind(state, to: statement, index: 2)
            try stepDone(statement)
            return sqlite3_changes(requireDatabase()) == 1
        }
        // A protected/repopulated header retains its candidate and proof.
        try withStatement(
            "DELETE FROM vector_gc_candidate WHERE generation_id=?1 AND NOT EXISTS(SELECT 1 FROM vector_generations WHERE generation_id=?1)"
        ) { statement in
            try bind(id, to: statement, index: 1)
            try stepDone(statement)
        }
        return deleted
    }
    func cleanupQueryPlansForTesting() throws -> [String] {
        try [Self.cleanupCandidateSQL, Self.cleanupRowSQL].map { sql in
            try withStatement("EXPLAIN QUERY PLAN " + sql) { statement in
                var details: [String] = []
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    if let text = columnText(statement, 3) { details.append(text) }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else { throw databaseError("vectorIndexRead") }
                return details.joined(separator: " | ")
            }
        }
    }

    public func replace(itemID: String, records: [VectorRecord]) throws {
        try Self.validateOpaque(itemID, name: "itemID", maximum: 512)
        guard let first = records.first else {
            try remove(itemID: itemID)
            return
        }
        let generation = try beginGeneration(
            itemID: itemID, revisionID: first.revisionID, contentHash: first.contentHash)
        do {
            for offset in stride(from: 0, to: records.count, by: 16) {
                try appendGeneration(
                    generation, records: Array(records[offset..<min(offset + 16, records.count)]),
                    requireIdentity: false)
            }
            try publishGeneration(generation, expectedRecordCount: Int64(records.count))
        } catch {
            try? discardGeneration(generation)
            throw error
        }
    }

    public func remove(itemID: String) throws {
        try Self.validateOpaque(itemID, name: "itemID", maximum: 512)
        try withStatement("DELETE FROM vector_heads WHERE item_id=?1") { statement in
            try bind(itemID, to: statement, index: 1)
            try stepDone(statement)
        }
    }

    /// Rebinding is a compact head update; it never rewrites a document's chunk ledger.
    public func updateRevision(itemID: String, revisionID: String, contentHash: String) throws {
        for (name, value) in [("itemID", itemID), ("revisionID", revisionID), ("contentHash", contentHash)] {
            try Self.validateOpaque(value, name: name, maximum: 512)
        }
        try withStatement("UPDATE vector_heads SET revision_override=?1,hash_override=?2 WHERE item_id=?3") {
            statement in
            try bind(revisionID, to: statement, index: 1)
            try bind(contentHash, to: statement, index: 2)
            try bind(itemID, to: statement, index: 3)
            try stepDone(statement)
        }
    }

    public func reset() throws {
        try transaction {
            try execute(
                "UPDATE vector_generations SET state='disposed' WHERE state IN ('staging','discarded')")
            try execute("DELETE FROM vector_heads")
            try execute("DELETE FROM vector_ledger")
            try execute("DELETE FROM vector_generations WHERE state!='disposed'")
            try execute("DELETE FROM semantic_vectors")
            try execute(
                "DELETE FROM vector_gc_candidate WHERE NOT EXISTS(SELECT 1 FROM vector_generations g WHERE g.generation_id=vector_gc_candidate.generation_id)"
            )
            try execute("UPDATE vector_gc_cursor SET generation_id='' WHERE singleton=1")
        }
        _ = try cleanupUnpublished()
    }

    private func generationCount(_ generation: Vec1Generation, state: String) throws -> Int64 {
        guard generation.profileID == profileID else {
            throw error("invalidVectorRecord", "Generation profile changed.")
        }
        return try withStatement(
            "SELECT item_id,revision_id,content_hash,record_count,state FROM vector_generations WHERE generation_id=?1"
        ) { statement in
            try bind(generation.generationID, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW, columnText(statement, 0) == generation.itemID,
                columnText(statement, 1) == generation.revisionID,
                columnText(statement, 2) == generation.contentHash,
                columnText(statement, 4) == state
            else { throw error("invalidVectorRecord", "Generation capability is unavailable or changed.") }
            let count = sqlite3_column_int64(statement, 3)
            guard count >= 0, sqlite3_step(statement) == SQLITE_DONE else {
                throw error("vectorIndexCorrupt", "Generation count is invalid.")
            }
            return count
        }
    }

    public func records() throws -> [VectorRecord] {
        try withStatement(
            "SELECT l.record_id, l.item_id, COALESCE(h.revision_override,l.revision_id), COALESCE(h.hash_override,l.content_hash), l.chunk_index, l.text, v.vector, l.unit_ordinal,l.byte_start,l.byte_end,l.unit_byte_start,l.unit_byte_end FROM vector_heads h JOIN vector_ledger l ON l.generation_id=h.generation_id JOIN semantic_vectors v ON v.rowid = l.vector_rowid ORDER BY l.item_id, l.chunk_index"
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
                        chunkIndex: Int(sqlite3_column_int64(statement, 4)), text: text, vector: vector,
                        unitOrdinal: sqlite3_column_int64(statement, 7),
                        byteStart: sqlite3_column_int64(statement, 8),
                        byteEnd: sqlite3_column_int64(statement, 9),
                        unitByteStart: sqlite3_column_int64(statement, 10),
                        unitByteEnd: sqlite3_column_int64(statement, 11)))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw databaseError("vectorIndexRead") }
            return result
        }
    }

    /// Identity comes from a compact completed-generation header, never a document-wide count scan.
    public func itemMetadata(itemID: String) throws -> Vec1ItemMetadata? {
        try Self.validateOpaque(itemID, name: "itemID", maximum: 512)
        return try withStatement(
            "SELECT h.item_id,COALESCE(h.revision_override,g.revision_id),COALESCE(h.hash_override,g.content_hash),g.record_count,g.state,g.homogeneous FROM vector_heads h JOIN vector_generations g ON g.generation_id=h.generation_id WHERE h.item_id=?1"
        ) { statement in
            try bind(itemID, to: statement, index: 1)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let id = columnText(statement, 0),
                let revision = columnText(statement, 1), let hash = columnText(statement, 2),
                columnText(statement, 4) == "complete", sqlite3_column_int(statement, 5) == 1,
                let count = Int(exactly: sqlite3_column_int64(statement, 3)), count > 0
            else {
                throw error(
                    "vectorIndexCorrupt", "An active generation has invalid or conflicting identities.")
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError("vectorIndexMetadata") }
            return Vec1ItemMetadata(itemID: id, revisionID: revision, contentHash: hash, recordCount: count)
        }
    }

    /// Compatibility array wrapper. Maintenance must use the bounded cursor API.
    public func itemMetadata() throws -> [Vec1ItemMetadata] {
        var values: [Vec1ItemMetadata] = []
        var cursor: String?
        while true {
            let page = try itemMetadataPage(after: cursor)
            values += page
            guard let last = page.last else { return values }
            cursor = last.itemID
        }
    }

    /// Restart recovery can enumerate capabilities in bounded windows and explicitly discard
    /// only work whose owning job has been fenced. Cleanup never guesses that another token died.
    public func stagingGenerationsPage(after generationID: String? = nil, limit: Int = 128) throws
        -> [Vec1Generation]
    {
        guard (1...128).contains(limit) else {
            throw error("invalidVectorLimit", "Use a generation page of one through 128 entries.")
        }
        return try withStatement(
            "SELECT generation_id,item_id,revision_id,content_hash FROM vector_generations WHERE state='staging' AND generation_id>?1 ORDER BY generation_id LIMIT ?2"
        ) { statement in
            try bind(generationID ?? "", to: statement, index: 1)
            guard sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else {
                throw databaseError("vectorIndexRead")
            }
            var result: [Vec1Generation] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let id = columnText(statement, 0), let item = columnText(statement, 1),
                    let revision = columnText(statement, 2), let hash = columnText(statement, 3)
                else { throw error("vectorIndexCorrupt", "A staging generation is malformed.") }
                result.append(
                    Vec1Generation(
                        generationID: id, itemID: item, revisionID: revision, contentHash: hash,
                        profileID: profileID))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw databaseError("vectorIndexRead") }
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
            "SELECT l.record_id, l.item_id, COALESCE(h.revision_override,l.revision_id), COALESCE(h.hash_override,l.content_hash), l.chunk_index, l.text, vec1_cos_distance(?1, v.vector) AS distance,l.unit_ordinal,l.byte_start,l.byte_end,l.unit_byte_start,l.unit_byte_end FROM vec1_allowed_items a JOIN vector_heads h ON h.item_id=a.item_id JOIN vector_ledger l ON l.generation_id=h.generation_id JOIN semantic_vectors v ON v.rowid = l.vector_rowid ORDER BY distance ASC, l.record_id ASC LIMIT ?2"
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
                        distance: Float(sqlite3_column_double(statement, 6)),
                        unitOrdinal: sqlite3_column_int64(statement, 7),
                        byteStart: sqlite3_column_int64(statement, 8),
                        byteEnd: sqlite3_column_int64(statement, 9),
                        unitByteStart: sqlite3_column_int64(statement, 10),
                        unitByteEnd: sqlite3_column_int64(statement, 11)))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw databaseError("vectorIndexQuery") }
            return result
        }
    }

    /// Returns at most one current passage per item. This array wrapper remains for existing callers.
    public func searchBestPerItem(
        query: [Float], allowedRecords: [Vec1RecordFilter], limit: Int
    ) throws -> [Vec1SearchHit] {
        try searchBestPerItem(query: query, limit: limit) { visit in
            for filter in allowedRecords { try visit(filter) }
        }
    }

    /// The producer visits compact current identities incrementally. SQLite, rather than a
    /// store-sized Swift Set/array, enforces uniqueness and authorization before distance/limit.
    public func searchBestPerItem(
        query: [Float], limit: Int,
        currentRecords: (_ visit: (Vec1RecordFilter) throws -> Void) throws -> Void
    ) throws -> [Vec1SearchHit] {
        try validate(vector: query)
        guard (1...256).contains(limit) else {
            throw error("invalidVectorLimit", "Search limit must be from 1 through 256.")
        }
        // TEMP state is private to this connection. Always clear partial producer output.
        try execute("DELETE FROM vec1_allowed_records")
        defer { try? execute("DELETE FROM vec1_allowed_records") }
        try withStatement("INSERT INTO vec1_allowed_records VALUES (?1,?2,?3)") { statement in
            try currentRecords { filter in
                for (name, value) in [
                    ("itemID", filter.itemID), ("revisionID", filter.revisionID),
                    ("contentHash", filter.contentHash),
                ] {
                    try Self.validateOpaque(value, name: name, maximum: 512)
                }
                try bind(filter.itemID, to: statement, index: 1)
                try bind(filter.revisionID, to: statement, index: 2)
                try bind(filter.contentHash, to: statement, index: 3)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw error("invalidVectorRecord", "Candidate item identities must be unique and valid.")
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }
        return try withStatement(
            "WITH scored AS (SELECT l.record_id, l.item_id, COALESCE(h.revision_override,l.revision_id) AS revision_id, COALESCE(h.hash_override,l.content_hash) AS content_hash, l.chunk_index, l.text,l.unit_ordinal,l.byte_start,l.byte_end,l.unit_byte_start,l.unit_byte_end, vec1_cos_distance(?1, v.vector) AS distance, ROW_NUMBER() OVER (PARTITION BY l.item_id ORDER BY vec1_cos_distance(?1, v.vector) ASC, l.record_id ASC) AS item_rank FROM vec1_allowed_records a JOIN vector_heads h ON h.item_id=a.item_id JOIN vector_ledger l ON l.generation_id=h.generation_id AND COALESCE(h.revision_override,l.revision_id) = a.revision_id AND COALESCE(h.hash_override,l.content_hash) = a.content_hash JOIN semantic_vectors v ON v.rowid = l.vector_rowid) SELECT record_id, item_id, revision_id, content_hash, chunk_index, text, distance,unit_ordinal,byte_start,byte_end,unit_byte_start,unit_byte_end FROM scored WHERE item_rank = 1 ORDER BY distance ASC, record_id ASC LIMIT ?2"
        ) { statement in
            try bind(vector: query, to: statement, index: 1)
            guard sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else {
                throw databaseError("vectorIndexQuery")
            }
            return try readHits(statement)
        }
    }

    /// A bounded scalar-ledger cursor; never reads vector blobs or all item identities.
    public func itemMetadataPage(after itemID: String? = nil, limit: Int = 128) throws -> [Vec1ItemMetadata] {
        guard (1...128).contains(limit) else {
            throw error("invalidVectorLimit", "Use a metadata page of one through 128 items.")
        }
        if let itemID { try Self.validateOpaque(itemID, name: "itemID", maximum: 512) }
        return try withStatement(
            "SELECT h.item_id FROM vector_heads h WHERE h.item_id>?1 ORDER BY h.item_id LIMIT ?2"
        ) { statement in
            try bind(itemID ?? "", to: statement, index: 1)
            guard sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else {
                throw databaseError("vectorIndexMetadata")
            }
            var result: [Vec1ItemMetadata] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let id = columnText(statement, 0), let metadata = try itemMetadata(itemID: id) else {
                    throw error("vectorIndexCorrupt", "A vector head has no complete records.")
                }
                result.append(metadata)
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw databaseError("vectorIndexMetadata") }
            return result
        }
    }

    public func retainedWorkPage(after generationID: String? = nil, limit: Int = 64) throws
        -> [Vec1RetainedWork]
    {
        guard (1...64).contains(limit) else {
            throw error("invalidVectorLimit", "Use a work page of one through64 entries.")
        }
        return try withStatement(
            "SELECT generation_id,encoded_bytes,state FROM vector_generations WHERE state IN ('staging','discarded','disposed') AND generation_id>?1 ORDER BY generation_id LIMIT ?2"
        ) { statement in
            try bind(generationID ?? "", to: statement, index: 1)
            guard sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else {
                throw databaseError("vectorIndexRead")
            }
            var result: [Vec1RetainedWork] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let id = columnText(statement, 0), let state = columnText(statement, 2),
                    sqlite3_column_int64(statement, 1) >= 0
                else { throw databaseError("vectorIndexRead") }
                result.append(
                    .init(generationID: id, encodedBytes: sqlite3_column_int64(statement, 1), state: state))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw databaseError("vectorIndexRead") }
            return result
        }
    }

    public func generationEncodedBytes(_ generation: Vec1Generation) throws -> Int64 {
        guard generation.profileID == profileID else {
            throw error("invalidVectorRecord", "Generation profile changed.")
        }
        guard let charge = try persistedCharge(generationID: generation.generationID) else {
            throw error("invalidVectorRecord", "Generation charge is unavailable.")
        }
        return charge
    }
    private func persistedCharge(generationID: String) throws -> Int64? {
        try withStatement("SELECT encoded_bytes FROM vector_generations WHERE generation_id=?1") {
            statement in
            try bind(generationID, to: statement, index: 1)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw databaseError("vectorIndexRead") }
            let value = sqlite3_column_int64(statement, 0)
            guard value >= 0, sqlite3_step(statement) == SQLITE_DONE else {
                throw error("vectorIndexCorrupt", "Invalid generation charge.")
            }
            return value
        }
    }

    private static func encodeRecord(_ value: VectorRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func encodeGeneration(_ value: Vec1Generation) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func stableContentHash(_ text: String) -> String {
        stableDataHash(Data(text.utf8))
    }

    public static func stableDataHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func configureOrVerifyMetadata() throws {
        let storedDimensions = try metadataValue("dimensions")
        let storedFormat = try metadataValue("formatVersion")
        guard storedDimensions == nil || storedFormat == "4" else {
            throw error("vectorIndexMismatch", "Semantic index source layout requires rebuilding.")
        }
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
                try setMetadata("formatVersion", value: "4")
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
                    distance: Float(sqlite3_column_double(statement, 6)),
                    unitOrdinal: sqlite3_column_int64(statement, 7),
                    byteStart: sqlite3_column_int64(statement, 8),
                    byteEnd: sqlite3_column_int64(statement, 9),
                    unitByteStart: sqlite3_column_int64(statement, 10),
                    unitByteEnd: sqlite3_column_int64(statement, 11)))
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

    private func insert(_ record: VectorRecord, generationID: String) throws {
        try withStatement("INSERT INTO semantic_vectors(vector) VALUES (?1)") { statement in
            try bind(vector: record.vector, to: statement, index: 1)
            try stepDone(statement)
        }
        let rowID = sqlite3_last_insert_rowid(requireDatabase())
        try withStatement(
            "INSERT INTO vector_ledger(record_id, item_id, revision_id, content_hash, chunk_index, text, vector_rowid,generation_id,unit_ordinal,byte_start,byte_end,unit_byte_start,unit_byte_end) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7,?8,?9,?10,?11,?12,?13)"
        ) { statement in
            try bind(generationID, to: statement, index: 8)
            guard sqlite3_bind_int64(statement, 9, record.unitOrdinal) == SQLITE_OK,
                sqlite3_bind_int64(statement, 10, record.byteStart) == SQLITE_OK,
                sqlite3_bind_int64(statement, 11, record.byteEnd) == SQLITE_OK,
                sqlite3_bind_int64(statement, 12, record.unitByteStart) == SQLITE_OK,
                sqlite3_bind_int64(statement, 13, record.unitByteEnd) == SQLITE_OK
            else { throw databaseError("vectorIndexWrite") }
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
        guard record.chunkIndex >= 0, record.unitOrdinal >= 0, record.byteStart >= 0,
            record.byteEnd >= record.byteStart,
            record.byteEnd - record.byteStart == Int64(record.text.utf8.count), record.unitByteStart >= 0,
            record.unitByteEnd >= record.unitByteStart,
            record.unitByteEnd - record.unitByteStart == Int64(record.text.utf8.count)
        else {
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
