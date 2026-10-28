import TractandaCore

extension ItemClient {
    /// Test setup convenience, with real content from the acknowledged immutable revision.
    func commitFixture(_ request: CommitRequest) throws -> CommitResult {
        let receipt = try commit(request)
        let revision = try revision(itemID: receipt.itemID, revisionID: receipt.revisionID)
        return CommitResult(revision: revision, wasReplayed: receipt.wasReplayed,
            isIndexReady: receipt.isIndexReady, warnings: receipt.diagnostics.map(\.rawValue))
    }
}
