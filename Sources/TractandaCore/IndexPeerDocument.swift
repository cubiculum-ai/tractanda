import CSQLite
import Foundation

/// Disposable transfer/verification progress, not origin or item authority. One bounded cursor
/// and indexed part rows replace document-sized memory collections. A new process re-verifies.
extension ItemIndex {
    func peerMetadataIdentityExists(_ id: String) throws -> Bool {
        let statement = try corpusPrepare(
            "SELECT EXISTS(SELECT 1 FROM authority_objects WHERE id=?) OR EXISTS(SELECT 1 FROM authority_objects WHERE item=?) OR EXISTS(SELECT 1 FROM revision_catalog WHERE revision=?) OR EXISTS(SELECT 1 FROM revision_catalog WHERE item=?)",
            [id, id, id, id])
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW else { throw graphSQLiteError() }
        return sqlite3_column_int(statement, 0) != 0
    }
    func initializePeerDocumentSchema() throws {
        try requireGraphCapacity(additionalBytes: 32 * 1024)
        try execute(
            "CREATE TABLE IF NOT EXISTS peer_document_work(scope TEXT NOT NULL,content TEXT NOT NULL,state TEXT NOT NULL,PRIMARY KEY(scope,content))"
        )
        try execute(
            "CREATE TABLE IF NOT EXISTS peer_document_part(scope TEXT NOT NULL,content TEXT NOT NULL,part TEXT NOT NULL,descriptor TEXT NOT NULL,stamp TEXT NOT NULL,PRIMARY KEY(scope,content,part))"
        )
        try execute(
            "CREATE TABLE IF NOT EXISTS peer_document_corpus_owner(package TEXT NOT NULL,content TEXT NOT NULL,source_key TEXT NOT NULL,work TEXT NOT NULL,generation TEXT NOT NULL,PRIMARY KEY(package,content))"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS peer_document_corpus_work ON peer_document_corpus_owner(work)")
        var hasProgress = false
        try {
            let columns = try corpusPrepare(
                "SELECT name FROM pragma_table_info('peer_document_corpus_owner')")
            defer { sqlite3_finalize(columns) }
            var count = 0
            while true {
                let status = catalogueStep(columns)
                if status == SQLITE_DONE { break }
                count += 1
                guard status == SQLITE_ROW, count <= 8 else { throw graphSQLiteError() }
                if try documentWorkText(columns, 0) == "progressed" { hasProgress = true }
            }
        }()
        if !hasProgress {
            try execute(
                "ALTER TABLE peer_document_corpus_owner ADD COLUMN progressed TEXT NOT NULL DEFAULT ''")
        }
    }
    private func documentWorkText(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0, count <= PeerPackage.maximumPageBytes,
            let pointer = sqlite3_column_text(statement, column),
            let value = String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8),
            !value.utf8.contains(0)
        else {
            throw TractandaError("peerObjectCollision", "Invalid document work metadata.")
        }
        return value
    }
    func peerDocumentState(scope: String, content: String) throws -> Data? {
        let statement = try corpusPrepare(
            "SELECT state FROM peer_document_work WHERE scope=? AND content=?", [scope, content])
        defer { sqlite3_finalize(statement) }
        let code = catalogueStep(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw graphSQLiteError() }
        return try Data(documentWorkText(statement, 0).utf8)
    }
    func peerDocumentSave(scope: String, content: String, state: Data) throws {
        guard state.count <= PeerPackage.maximumPageBytes, let text = String(data: state, encoding: .utf8)
        else {
            throw TractandaError("resourceLimit", "Document cursor exceeds its bounded metadata window.")
        }
        try requireGraphCapacity(additionalBytes: UInt64(state.count + 8192))
        try execute(
            "INSERT INTO peer_document_work VALUES(?,?,?) ON CONFLICT(scope,content) DO UPDATE SET state=excluded.state",
            [scope, content, text])
    }
    func peerDocumentReset(scope: String, content: String) throws {
        try execute("DELETE FROM peer_document_part WHERE scope=? AND content=?", [scope, content])
        try execute("DELETE FROM peer_document_work WHERE scope=? AND content=?", [scope, content])
    }
    func peerDocumentRecord(scope: String, object: PeerPackage.Object, metadata: FileMetadata) throws {
        try object.validate()
        guard object.kind == .document, metadata.type == .regular, metadata.size == UInt64(object.length)
        else {
            throw TractandaError("invalidPeerPackage", "Expected composite document progress.")
        }
        let descriptor = try JSON.encode(object)
        let stamp = try JSON.encode(PeerOriginalTransfer.Stamp(metadata))
        if let previous = try peerDocumentPart(scope: scope, object: object) {
            guard previous.0 == object else {
                throw TractandaError("peerObjectCollision", "Document work address changed.")
            }
        }
        try requireGraphCapacity(additionalBytes: UInt64(descriptor.count + stamp.count + 8192))
        try execute(
            "INSERT INTO peer_document_part VALUES(?,?,?,?,?) ON CONFLICT(scope,content,part) DO UPDATE SET stamp=excluded.stamp",
            [
                scope, object.id, object.key, String(decoding: descriptor, as: UTF8.self),
                String(decoding: stamp, as: UTF8.self),
            ])
    }
    func peerDocumentPart(scope: String, object: PeerPackage.Object) throws -> (
        PeerPackage.Object, PeerOriginalTransfer.Stamp
    )? {
        let statement = try corpusPrepare(
            "SELECT descriptor,stamp FROM peer_document_part WHERE scope=? AND content=? AND part=?",
            [scope, object.id, object.key])
        defer { sqlite3_finalize(statement) }
        let code = catalogueStep(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw graphSQLiteError() }
        return try (
            PeerPackage.decode(PeerPackage.Object.self, Data(documentWorkText(statement, 0).utf8)),
            PeerPackage.decode(PeerOriginalTransfer.Stamp.self, Data(documentWorkText(statement, 1).utf8))
        )
    }
}
