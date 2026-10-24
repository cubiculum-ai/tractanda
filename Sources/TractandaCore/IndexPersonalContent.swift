import Foundation

extension ItemIndex {
    /// Ordinary authored append after the Store's current ACL and canonical publication checks.
    /// No historical authority witness, retirement ledger or policy-frontier materialization applies.
    func appendPersonalContent(
        row: CatalogueRow, revision: Revision, parent: Revision?, corpus: IndexedCorpusStage?
    ) throws {
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
    }

    /// Canonical receipt lookup across retained origins. Ambiguity is rejected by the Store;
    /// origin labels and old admission facts neither authorize a replay nor create another edit.
    func personalOperationRows(_ operation: String) throws -> [CatalogueRow] {
        try execute(
            "CREATE INDEX IF NOT EXISTS personal_operation_receipts ON revision_catalog(operation,actor,revision)"
        )
        let rows = try graphCatalogueRows(
            where: "WHERE operation=? ORDER BY actor,revision", bindings: [operation], limit: 1024)
        guard rows.count < 1024 else {
            throw TractandaError("resourceLimit", "Operation receipt scope exceeds its bound.")
        }
        return rows.filter { $0.provenance == nil || $0.provenance?.kind == .authored }
    }
}
