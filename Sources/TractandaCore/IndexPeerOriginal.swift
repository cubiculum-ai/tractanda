import CSQLite
import Foundation

extension ItemIndex {
    struct PeerOriginalRequirement {
        let descriptor: AttachmentDescriptor
        let object: PeerPackage.Object
    }
    struct PeerDocumentRequirement {
        let document: AttachmentDocumentRepresentation
        let object: PeerPackage.Object?
    }
    func peerOriginalBegin() throws {
        for table in [
            "peer_original_required", "peer_original_present", "peer_original_revision", "peer_original_text",
            "peer_original_document", "peer_original_document_present",
            "peer_original_item",
        ] {
            try execute("DROP TABLE IF EXISTS temp." + table)
        }
        try execute(
            "CREATE TEMP TABLE peer_original_required(id TEXT PRIMARY KEY,item TEXT NOT NULL,descriptor TEXT NOT NULL)"
        )
        try execute("CREATE TEMP TABLE peer_original_present(id TEXT PRIMARY KEY,descriptor TEXT NOT NULL)")
        try execute(
            "CREATE TEMP TABLE peer_original_revision(revision TEXT NOT NULL,attachment TEXT NOT NULL,item TEXT NOT NULL,descriptor TEXT NOT NULL,PRIMARY KEY(revision,attachment))"
        )
        try execute("CREATE TEMP TABLE peer_original_text(id TEXT PRIMARY KEY,source TEXT NOT NULL)")
        try execute("CREATE TEMP TABLE peer_original_item(revision TEXT PRIMARY KEY,item TEXT NOT NULL)")
        try execute(
            "CREATE TEMP TABLE peer_original_document(id TEXT PRIMARY KEY,content TEXT NOT NULL,document TEXT NOT NULL)"
        )
        try execute(
            "CREATE TEMP TABLE peer_original_document_present(id TEXT PRIMARY KEY,descriptor TEXT NOT NULL)"
        )
    }
    private func originalText(_ statement: OpaquePointer, _ column: Int32, maximum: Int = 16 * 1024) throws
        -> String
    {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0, count <= maximum,
            let pointer = sqlite3_column_text(statement, column),
            let value = String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8),
            !value.utf8.contains(0)
        else {
            throw TractandaError("peerObjectCollision", "Invalid original dependency metadata.")
        }
        return value
    }
    private func originalScalar(_ sql: String, _ values: [String], maximum: Int = 16 * 1024) throws -> String?
    {
        let s = try corpusPrepare(sql, values)
        defer { sqlite3_finalize(s) }
        let code = catalogueStep(s)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw graphSQLiteError() }
        return try originalText(s, 0, maximum: maximum)
    }
    func peerOriginalRequire(_ descriptor: AttachmentDescriptor, itemID: String) throws {
        let json = String(decoding: try JSON.encode(descriptor), as: UTF8.self)
        if let old = try originalScalar(
            "SELECT descriptor FROM peer_original_required WHERE id=?", [descriptor.attachmentID])
        {
            guard old == json,
                try originalScalar(
                    "SELECT item FROM peer_original_required WHERE id=?", [descriptor.attachmentID]) == itemID
            else {
                throw TractandaError(
                    "peerObjectCollision", "One original identity has different canonical owners/descriptors."
                )
            }
        } else {
            try requireGraphCapacity(additionalBytes: UInt64(json.utf8.count + 8192))
            try execute(
                "INSERT INTO peer_original_required VALUES(?,?,?)", [descriptor.attachmentID, itemID, json])
        }
    }
    func peerOriginalRegister(_ revision: Revision) throws {
        try execute("INSERT INTO peer_original_item VALUES(?,?)", [revision.revisionID, revision.itemID])
        for descriptor in try AttachmentDescriptor.descriptors(in: revision.fields) {
            try peerOriginalRequire(descriptor, itemID: revision.itemID)
            try execute(
                "INSERT INTO peer_original_revision VALUES(?,?,?,?)",
                [
                    revision.revisionID, descriptor.attachmentID, revision.itemID,
                    String(decoding: try JSON.encode(descriptor), as: UTF8.self),
                ])
        }
        for text in try AttachmentTextRepresentation.representations(in: revision.fields) {
            let json = String(decoding: try JSON.encode(text.source), as: UTF8.self)
            if let old = try originalScalar(
                "SELECT source FROM peer_original_text WHERE id=?", [text.representationID])
            {
                guard old == json else {
                    throw TractandaError("peerObjectCollision", "Saved text source identity differs.")
                }
            } else {
                try execute("INSERT INTO peer_original_text VALUES(?,?)", [text.representationID, json])
            }
        }
        for document in try AttachmentDocumentRepresentation.representations(in: revision.fields) {
            let json = String(decoding: try JSON.encode(document), as: UTF8.self)
            if let old = try originalScalar(
                "SELECT document FROM peer_original_document WHERE id=?", [document.representationID],
                maximum: 8 * 1024 * 1024)
            {
                guard old == json else {
                    throw TractandaError("peerObjectCollision", "Saved document identity/provenance differs.")
                }
            } else {
                try requireGraphCapacity(additionalBytes: UInt64(json.utf8.count + 8192))
                try execute(
                    "INSERT INTO peer_original_document VALUES(?,?,?)",
                    [document.representationID, document.content?.contentID ?? "", json])
            }
        }
    }
    func peerDocumentPresent(_ object: PeerPackage.Object) throws {
        try object.validate()
        guard object.kind == .document, object.part == .manifest else {
            throw TractandaError("invalidPeerPackage", "Only a manifest may anchor document closure.")
        }
        try execute(
            "INSERT INTO peer_original_document_present VALUES(?,?)",
            [object.id, String(decoding: try JSON.encode(object), as: UTF8.self)])
    }
    private func validateDocumentSources() throws {
        var cursor = ""
        while true {
            let page = try peerDocumentPage(after: cursor)
            if page.isEmpty { break }
            for row in page {
                try checkCatalogueScanProgress()
                let source = row.document.source
                guard
                    let json = try originalScalar(
                        "SELECT descriptor FROM peer_original_revision WHERE revision=? AND attachment=? AND item=?",
                        [source.revisionID, source.attachmentID, source.itemID])
                else {
                    throw TractandaError(
                        "missingDependencies", "Saved document source revision/original is missing.")
                }
                let descriptor = try JSON.decode(AttachmentDescriptor.self, Data(json.utf8))
                guard descriptor.byteCount == source.byteCount, descriptor.sha256 == source.sha256,
                    descriptor.mediaType == source.mediaType
                else {
                    throw TractandaError("peerObjectCollision", "Saved document source signature differs.")
                }
                if let content = row.document.content {
                    guard let object = row.object else {
                        throw TractandaError("missingDependencies", "Saved document manifest is missing.")
                    }
                    guard object.id == content.contentID, object.sha256 == content.manifestSHA256 else {
                        throw TractandaError("peerObjectCollision", "Saved document manifest anchor differs.")
                    }
                }
                cursor = row.document.representationID
            }
        }
        guard
            try originalScalar(
                "SELECT p.id FROM peer_original_document_present p LEFT JOIN peer_original_document d ON d.content=p.id WHERE d.id IS NULL LIMIT 1",
                []) == nil
        else {
            throw TractandaError("invalidPeerPackage", "Document manifest has no canonical revision witness.")
        }
    }
    func peerOriginalPresent(_ object: PeerPackage.Object) throws {
        try object.validate()
        try execute(
            "INSERT INTO peer_original_present VALUES(?,?)",
            [object.id, String(decoding: try JSON.encode(object), as: UTF8.self)])
    }
    func peerOriginalValidateClosure() throws {
        guard
            try originalScalar(
                "SELECT p.id FROM peer_original_document_present p JOIN peer_original_item i ON i.item=p.id LIMIT 1",
                []) == nil,
            try originalScalar(
                "SELECT p.id FROM peer_original_present p JOIN peer_original_item i ON i.item=p.id LIMIT 1",
                []) == nil
        else {
            throw TractandaError(
                "peerObjectCollision", "Payload identity collides with a package item identity.")
        }
        try validateDocumentSources()
        var cursor = ""
        while true {
            let s = try corpusPrepare(
                "SELECT id,source FROM peer_original_text WHERE id>? ORDER BY id LIMIT 128", [cursor])
            var found = false
            do {
                while true {
                    let code = catalogueStep(s)
                    if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW else { throw graphSQLiteError() }
                    try checkCatalogueScanProgress()
                    found = true
                    cursor = try originalText(s, 0)
                    let source = try JSON.decode(AttachmentTextSource.self, Data(try originalText(s, 1).utf8))
                    guard
                        let json = try originalScalar(
                            "SELECT descriptor FROM peer_original_revision WHERE revision=? AND attachment=? AND item=?",
                            [source.revisionID, source.attachmentID, source.itemID])
                    else {
                        throw TractandaError(
                            "missingDependencies", "Saved text source revision/original is missing.")
                    }
                    let descriptor = try JSON.decode(AttachmentDescriptor.self, Data(json.utf8))
                    guard descriptor.byteCount == source.byteCount, descriptor.sha256 == source.sha256,
                        descriptor.mediaType == source.mediaType
                    else {
                        throw TractandaError("peerObjectCollision", "Saved text source signature differs.")
                    }
                }
                sqlite3_finalize(s)
            } catch {
                sqlite3_finalize(s)
                throw error
            }
            if !found { break }
        }
        guard
            try originalScalar(
                "SELECT r.id FROM peer_original_required r LEFT JOIN peer_original_present p ON p.id=r.id WHERE p.id IS NULL LIMIT 1",
                []) == nil
        else {
            throw TractandaError("missingDependencies", "Referenced original lacks its manifest descriptor.")
        }
        guard
            try originalScalar(
                "SELECT p.id FROM peer_original_present p LEFT JOIN peer_original_required r ON r.id=p.id WHERE r.id IS NULL LIMIT 1",
                []) == nil
        else {
            throw TractandaError(
                "invalidPeerPackage", "An original object has no canonical descriptor witness.")
        }
    }
    func peerDocumentPage(after: String, limit: Int = 128) throws -> [PeerDocumentRequirement] {
        guard (1...128).contains(limit) else {
            throw TractandaError("resourceLimit", "Invalid document closure window.")
        }
        let statement = try corpusPrepare(
            "SELECT d.document,p.descriptor FROM peer_original_document d LEFT JOIN peer_original_document_present p ON p.id=d.content WHERE d.id>? ORDER BY d.id LIMIT ?",
            [after, String(limit)])
        defer { sqlite3_finalize(statement) }
        var result: [PeerDocumentRequirement] = []
        var windowBytes = 0
        while true {
            let code = catalogueStep(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw graphSQLiteError() }
            let rowBytes = Int(sqlite3_column_bytes(statement, 0))
            // One historical inline representation is bounded by its canonical item format.
            // Paged representations remain small; never collect a page of large inline rows.
            if !result.isEmpty,
                rowBytes > PeerPackage.maximumPageBytes - min(windowBytes, PeerPackage.maximumPageBytes)
            {
                return result
            }
            let document = try JSON.decode(
                AttachmentDocumentRepresentation.self,
                Data(try originalText(statement, 0, maximum: 8 * 1024 * 1024).utf8))
            let object =
                try sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? nil
                : PeerPackage.decode(PeerPackage.Object.self, Data(originalText(statement, 1).utf8))
            result.append(.init(document: document, object: object))
            windowBytes += rowBytes
        }
    }
    func peerOriginalPage(after: String, limit: Int = 128) throws -> [PeerOriginalRequirement] {
        guard (1...128).contains(limit) else {
            throw TractandaError("resourceLimit", "Invalid original closure window.")
        }
        let s = try corpusPrepare(
            "SELECT r.descriptor,p.descriptor FROM peer_original_required r JOIN peer_original_present p ON p.id=r.id WHERE r.id>? ORDER BY r.id LIMIT ?",
            [after, String(limit)])
        defer { sqlite3_finalize(s) }
        var result: [PeerOriginalRequirement] = []
        while true {
            let code = catalogueStep(s)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw graphSQLiteError() }
            let descriptor = try JSON.decode(AttachmentDescriptor.self, Data(try originalText(s, 0).utf8))
            let object = try PeerPackage.decode(PeerPackage.Object.self, Data(try originalText(s, 1).utf8))
            guard object.kind == .attachment, object.id == descriptor.attachmentID,
                object.length == Int(exactly: descriptor.byteCount), object.sha256 == descriptor.sha256
            else {
                throw TractandaError(
                    "peerObjectCollision", "Manifest original signature differs from canonical descriptor.")
            }
            result.append(.init(descriptor: descriptor, object: object))
        }
    }
}
