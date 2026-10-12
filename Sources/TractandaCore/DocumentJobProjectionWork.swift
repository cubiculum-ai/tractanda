import Foundation

struct DocumentJobProjectionWork: Sendable {
    let jobID: String
    let generation: Int64
    let snapshot: StoredPageCorpusSnapshot
    let contents: DocumentContentStore
    let quota: StagingByteQuota
    let indexPath: String
    let maximumBytes: Int64
    let minimumFreeBytes: Int64
    let retainedArtifact: String?

    func prepareSpool(cancellation: DocumentConversionCancellation) throws -> PreparedPageCorpus {
        try cancellation.check()
        let root = try contents.jobCorpusRoot(jobID)
        if let retainedArtifact {
            return try PageCorpusProjection.load(
                root: root, artifactName: retainedArtifact,
                expected: snapshot.input.binding, boundary: { try cancellation.check() })
        }
        let reservationID = "spool:" + jobID
        let policy = try PageCorpusSpoolPolicy(
            maximumBytes: maximumBytes,
            minimumFreeBytes: minimumFreeBytes,
            stagingBoundary: { directory, growth in
                try cancellation.check()
                if directory == root {
                    try quota.reserveDerived(workID: reservationID, estimatedAdditionalBytes: growth)
                } else {
                    let artifact = directory.lastPathComponent
                    guard directory.deletingLastPathComponent() == root,
                        artifact.hasPrefix("page-corpus-")
                    else {
                        throw TractandaError("documentIntegrity", "Corpus spool escaped its owned job.")
                    }
                    let usage = try PageCorpusAllocation.usage(at: directory)
                    try quota.observePrivateCorpus(
                        path: ["document-jobs", jobID, "corpus", artifact],
                        reservationID: reservationID, encodedBytes: usage.logicalBytes)
                    try quota.reserveDerived(workID: reservationID, estimatedAdditionalBytes: growth)
                }
            })
        return try PageCorpusProjection.prepare(
            input: snapshot.input, provider: snapshot.provider,
            root: root, policy: policy, boundary: { try cancellation.check() })
    }
}

/// Runs only after the previous producer terminated. Each step owns one bounded Index transaction.
struct DocumentJobIndexRecoveryWork: Sendable {
    let indexPath: String
    let workID: String
    func retire(boundary: () throws -> Void) throws {
        try boundary()
        let index = try ItemIndex(path: indexPath, create: false)
        try index.releaseCorpusWork(workID)
        // Caller observes committed ownership transfers before checking a later cancellation fence.
    }
    func cleanup(
        authorityBoundary: () throws -> Void, transactionBoundary: () throws -> Void = {}
    ) throws -> DocumentCorpusCleanupProgress {
        try authorityBoundary()
        let index = try ItemIndex(path: indexPath, create: false)
        let before = try index.corpusRetainedBytes(workID)
        // Authority may wait for Store. Only local cancellation/fence state can run while the
        // SQLite writer is held; Store commits/read leases may themselves wait for this writer.
        let removed = try index.cleanupCorpus(limit: 16, boundary: transactionBoundary)
        let retained = try index.corpusRetainedBytes(workID)
        return DocumentCorpusCleanupProgress(
            complete: retained == 0, madeProgress: removed > 0 || retained < before)
    }
}

struct DocumentCorpusCleanupProgress: Sendable {
    let complete: Bool
    let madeProgress: Bool
}
