import CSQLite
import Foundation

final class ItemIndex {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(path: String, create: Bool) throws {
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else {
            if let database { sqlite3_close(database) }
            database = nil
            throw TractandaError("indexError", "Cannot open disposable SQLite index.")
        }
        sqlite3_busy_timeout(database, 3000)
        if create {
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute(
                """
                CREATE TABLE items (id TEXT PRIMARY KEY, revision TEXT NOT NULL,
                class TEXT NOT NULL, deleted INTEGER NOT NULL, fields TEXT NOT NULL);
                """)
            try execute("CREATE INDEX item_class ON items(class)")
            try execute(
                "CREATE VIRTUAL TABLE text_index USING fts5(id UNINDEXED, subject, body, metadata, tokenize='unicode61')"
            )
        }
    }
    deinit { if let database { sqlite3_close(database) } }
    func close() {
        if let database { sqlite3_close(database) }
        database = nil
    }
    private func prepare(_ sql: String, _ bindings: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        for (offset, value) in bindings.enumerated() {
            let result = value.withCString {
                sqlite3_bind_text(statement, Int32(offset + 1), $0, Int32(value.utf8.count), transient)
            }
            if result != SQLITE_OK {
                sqlite3_finalize(statement)
                throw error()
            }
        }
        return statement
    }
    private func error() -> TractandaError {
        TractandaError("indexError", database.map { String(cString: sqlite3_errmsg($0)) } ?? "Index closed.")
    }
    func execute(_ sql: String, _ bindings: [String] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw error() }
    }
    func put(_ revision: Revision) throws {
        let fields = String(decoding: try JSON.encode(revision.fields), as: UTF8.self)
        let corpus = ItemTextContent.corpus(for: revision)
        try execute(
            "INSERT OR REPLACE INTO items VALUES (?, ?, ?, ?, ?)",
            [
                revision.itemID, revision.revisionID, revision.classID, revision.isDeleted ? "1" : "0",
                fields,
            ])
        try execute("DELETE FROM text_index WHERE id = ?", [revision.itemID])
        try execute(
            "INSERT INTO text_index (id, subject, body, metadata) VALUES (?, ?, ?, ?)",
            [
                revision.itemID, corpus.subject, corpus.body, corpus.metadata,
            ])
    }
    func ids(lexicalText: String? = nil) throws -> [String] {
        let sql: String
        let args: [String]
        if let lexicalText {
            // A literal phrase, not arbitrary executable SQL or an accidental FTS expression.
            let phrase = "\"" + lexicalText.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sql = "SELECT id FROM text_index WHERE text_index MATCH ? ORDER BY rank, id"
            args = [phrase]
        } else {
            sql = "SELECT id FROM items ORDER BY id"
            args = []
        }
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw error() }
            result.append(String(cString: text))
        }
    }
}
