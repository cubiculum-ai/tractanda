import CSQLite
import Foundation

extension ItemIndex {
    /// Ordinary authored append after the Store's current ACL and canonical publication checks.
    /// No historical authority witness, retirement ledger or policy-frontier materialization applies.
    func appendPersonalContent(
        row: CatalogueRow, revision: Revision, parent: Revision?, corpus: IndexedCorpusStage?
    ) throws {
        guard personalContentProjectionMode else {
            throw TractandaError("personalProfileRequired", "Ordinary append requires its personal index.")
        }
        let provenance = try revision.provenance
        guard provenance?.kind == .authored,
            provenance?.parents == (parent.map({ [$0.revisionID] }) ?? []),
            revision.itemID == row.itemID, revision.revisionID == row.revisionID,
            revision.supersedes == row.parentID, revision.modifiedAt == row.modifiedAt,
            revision.fields["actor"]?.string == row.actor,
            revision.fields["operationID"]?.string == row.operationID,
            row.digest.count == 32, try self.revision(row.revisionID) == nil
        else {
            throw TractandaError(
                "invalidRevisionGraph", "Ordinary append does not bind its canonical revision.")
        }
        try revision.validate()
        try ItemSemantics.validate(revision)
        let head = try currentHeadSummary(revision.itemID)
        if let parent {
            guard parent.itemID == revision.itemID, head?.revisionID == parent.revisionID,
                parent.fields["createdAt"] == revision.fields["createdAt"],
                try RevisionTimestamp(revision.modifiedAt) > RevisionTimestamp(parent.modifiedAt)
            else { throw TractandaError("revisionConflict", "Ordinary current parent changed.") }
        } else {
            guard head == nil, try revisionCount(itemID: revision.itemID) == 0 else {
                throw TractandaError("identifierCollision", "Ordinary creation repeats an item identity.")
            }
        }
        try insertGraphCatalogueRow(row, graphFields: revision.fields)
        try put(revision, corpus: corpus)
        try replacePersonalProjection(
            itemID: revision.itemID, analysis: nil, representative: revision,
            permissions: revision.fields["permissions"], physicalHeads: [revision.revisionID])
    }

    /// Canonical receipt lookup across retained origins. Ambiguity is rejected by the Store;
    /// origin labels and old admission facts neither authorize a replay nor create another edit.
    func personalOperationRows(_ operation: String, kind: RevisionProvenance.Kind = .authored) throws
        -> [CatalogueRow]
    {
        try execute(
            "CREATE INDEX IF NOT EXISTS personal_operation_receipts ON revision_catalog(operation,actor,revision)"
        )
        let rows = try graphCatalogueRows(
            where: "WHERE operation=? ORDER BY actor,revision", bindings: [operation], limit: 1024)
        guard rows.count < 1024 else {
            throw TractandaError("resourceLimit", "Operation receipt scope exceeds its bound.")
        }
        return rows.filter { ($0.provenance == nil && kind == .authored) || $0.provenance?.kind == kind }
    }
}

extension ItemIndex {
    /// Derived personal state only. This path is fed by verified raw content, never authority
    /// acceptance tables. A consolidated policy need not equal any individual head's ACL.
    func replacePersonalProjection(
        itemID: String, analysis: RevisionMerge.Analysis?, representative: Revision?,
        permissions: ItemValue?, physicalHeads: [String], resourceCode: String? = nil
    ) throws {
        guard personalContentProjectionMode else {
            throw TractandaError(
                "personalProfileRequired", "Personal projection requires a raw-content index.")
        }
        let frontier = analysis?.frontier ?? physicalHeads
        let status: ItemState.Status
        if resourceCode != nil {
            status = .unmaterializable
        } else if let analysis, !analysis.isResolved {
            status = .conflicted
        } else if representative == nil {
            status = .unmaterializable
        } else {
            status = .ready
        }
        let token = try Self.graphValueDigest(
            .object([
                "profile": .text(RevisionMerge.personalProfile),
                "heads": .list(physicalHeads.sorted().map(ItemValue.text)),
                "permissions": permissions ?? .object([:]),
            ]))
        let state = ItemState(
            itemID: itemID, stateToken: token, status: status,
            representativeRevisionID: representative?.revisionID, frontier: frontier,
            conflictingFields: analysis?.conflicts.keys.sorted() ?? [],
            protectedFields: analysis?.protectedFields.sorted() ?? [], detailsComplete: resourceCode == nil,
            resource: status == .unmaterializable
                ? .init(
                    code: resourceCode ?? "personalMergePending", phase: .publication,
                    message: resourceCode == nil
                        ? "A writable personal store must materialize this recoverable merge."
                        : "The personal DAG needs a larger bounded analysis window.") : nil)
        let encoded = try JSON.encode(state)
        guard encoded.count <= Self.projectionMetadataByteWindow, let policyID = frontier.first else {
            throw TractandaError("resourceLimit", "Personal projection metadata exceeded its bound.")
        }
        let policyClass =
            representative?.classID ?? analysis?.fields["classID"]?.string
            ?? AccessConfiguration.classID
        try execute("DELETE FROM projection_acl_named WHERE item=?", [itemID])
        try execute("DELETE FROM projection_acl WHERE item=?", [itemID])
        try execute("DELETE FROM current_policy WHERE item=?", [itemID])
        try execute(
            "INSERT INTO current_policy VALUES(?,?,?,?)",
            [
                itemID, policyID, policyClass,
                try permissions.map { String(decoding: try JSON.encode($0), as: UTF8.self) } ?? "",
            ])
        if let permissions {
            try insertProjectionACL(itemID: itemID, revisionID: policyID, value: permissions)
        }
        let digest = try representative.flatMap { try revision($0.revisionID)?.digest }
        try execute(
            "INSERT OR REPLACE INTO current_projection VALUES(?,?,?,?,?,?,?,0)",
            [
                itemID, status.rawValue, String(decoding: encoded, as: UTF8.self),
                digest?.map { String(format: "%02x", $0) }.joined() ?? "", "", "",
                permissions != nil || representative?.classID == AccessConfiguration.classID ? "1" : "0",
            ])
        if status != .ready { try removeCurrentContentProjection(itemID: itemID) }
    }
}

extension ItemIndex {
    /// SQLite rowids are local disposable enumeration positions, never remote authority cursors.
    /// Ordinary canonical catalogue insertion is append-only; rebuild invalidates the Store cut.
    func personalInventoryGeneration() throws -> String {
        let statement = try corpusPrepare("SELECT id FROM corpus_index_identity")
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
            throw graphSQLiteError()
        }
        let value = String(cString: raw)
        guard catalogueStep(statement) == SQLITE_DONE else { throw graphSQLiteError() }
        return value
    }
    func personalInventoryHighWater() throws -> Int64 {
        let statement = try corpusPrepare("SELECT COALESCE(MAX(rowid),0) FROM revision_catalog")
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW else { throw graphSQLiteError() }
        return sqlite3_column_int64(statement, 0)
    }
    func personalInventoryRows(afterRowID: Int64, through: Int64, limit: Int) throws -> [(
        Int64, CatalogueRow
    )] {
        guard afterRowID >= 0, through >= afterRowID, (1...128).contains(limit) else {
            throw TractandaError("invalidArguments", "Invalid finite catalogue page.")
        }
        let statement = try corpusPrepare(
            "SELECT rowid,revision FROM revision_catalog WHERE rowid>? AND rowid<=? ORDER BY rowid LIMIT ?",
            [String(afterRowID), String(through), String(limit)])
        defer { sqlite3_finalize(statement) }
        var result: [(Int64, CatalogueRow)] = []
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(statement, 1),
                let row = try revision(String(cString: text))
            else { throw graphSQLiteError() }
            result.append((sqlite3_column_int64(statement, 0), row))
        }
    }
    func personalItemIDs(after: String?, limit: Int) throws -> [String] {
        guard (1...128).contains(limit) else {
            throw TractandaError("invalidArguments", "Invalid personal item page.")
        }
        let statement = try corpusPrepare(
            "SELECT DISTINCT item FROM revision_catalog" + (after == nil ? "" : " WHERE item>?")
                + " ORDER BY item LIMIT ?",
            (after.map { [$0] } ?? []) + [String(limit)])
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
                throw graphSQLiteError()
            }
            values.append(String(cString: raw))
        }
    }

}
