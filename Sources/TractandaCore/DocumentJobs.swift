import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Immutable admission. Publication CAS can change without rewriting extraction provenance.
struct DocumentJobIntent: Codable, Sendable {
    let jobID: String
    let actorUID: UInt32
    let actorPrincipal: String
    let request: DocumentJobStart
    let descriptor: AttachmentDescriptor
    let source: AttachmentDocumentSource
    let identity: DocumentConverterIdentity
    let configurationSHA256: String
    let extractedAt: String
    var stage: [String] { ["documents", ".staging", jobID] }
    func validate() throws {
        for id in [jobID, request.itemID, request.expectedRevisionID, request.attachmentID] {
            try Identifier.validate(id)
        }
        guard UUID(uuidString: jobID)?.version1Components != nil,
            actorPrincipal == "uid:\(actorUID)"
                || (actorPrincipal.hasPrefix("user:") && actorPrincipal.utf8.count > 5
                    && actorPrincipal.utf8.count <= 256 && !actorPrincipal.contains("\0")),
            !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
            !request.operationID.contains("\0"), DocumentHashNode.isDigest(configurationSHA256),
            Timestamp.parse(extractedAt) != nil,
            source.itemID == request.itemID, source.revisionID == request.expectedRevisionID,
            source.attachmentID == request.attachmentID, descriptor.attachmentID == request.attachmentID,
            descriptor.sha256 == source.sha256, descriptor.byteCount == source.byteCount,
            descriptor.mediaType == source.mediaType
        else { throw TractandaError("documentIntegrity", "Invalid immutable job intent.") }
        try source.validate()
        try identity.validate()
        _ = try AttachmentDescriptor(
            attachmentID: descriptor.attachmentID, filename: descriptor.filename,
            mediaType: descriptor.mediaType, byteCount: descriptor.byteCount, sha256: descriptor.sha256)
    }
}
struct DocumentJobCheckpoint: Codable, Sendable {
    var expectedRevisionID: String
    var state: String = "queued"
    var reasonCode: String? {
        didSet { reasonMessage = nil }
    }
    var reasonMessage: String?
    var pageCount: Int64?
    var acceptedPages: Int64 = 0
    var coverage: DocumentCoverage = try! DocumentCoverage(converted: 0)
    var generation: Int64 = 0
    var prepared: PreparedDocumentContent?
    var corpusArtifactName: String?
    var committed: AttachmentCommitResult?
    var discarded = false
    mutating func fence() throws {
        let next = generation.addingReportingOverflow(1)
        guard !next.overflow else { throw TractandaError("resourceLimit", "Job generation exhausted.") }
        generation = next.partialValue
    }
}
struct DocumentJobRecord: Codable, Sendable {
    let schema: String
    let intent: DocumentJobIntent
    var checkpoint: DocumentJobCheckpoint
    init(intent: DocumentJobIntent) {
        schema = "tractanda.document-job.v1"
        self.intent = intent
        checkpoint = DocumentJobCheckpoint(expectedRevisionID: intent.request.expectedRevisionID)
    }
    func validate() throws {
        try intent.validate()
        try Identifier.validate(checkpoint.expectedRevisionID)
        guard schema == "tractanda.document-job.v1", checkpoint.generation >= 0,
            [
                "queued", "verifyingOriginal", "inspecting", "running", "paused", "cancelled",
                "readyToPublish", "completed", "failed",
            ].contains(checkpoint.state),
            checkpoint.acceptedPages >= 0,
            try checkpoint.coverage.processedPageCount() == checkpoint.acceptedPages,
            checkpoint.pageCount.map({ $0 > 0 && checkpoint.acceptedPages <= $0 })
                ?? (checkpoint.acceptedPages == 0),
            checkpoint.reasonCode.map({ !$0.isEmpty && $0.utf8.count <= 200 && !$0.contains("\0") }) ?? true,
            checkpoint.reasonMessage.map({
                checkpoint.reasonCode == "documentTimeout" && !$0.isEmpty && $0.utf8.count <= 512
                    && !$0.contains("\0")
            }) ?? true,
            !checkpoint.discarded || ["completed", "cancelled"].contains(checkpoint.state),
            checkpoint.state != "completed" || checkpoint.committed != nil,
            checkpoint.committed == nil || checkpoint.state == "completed",
            !["readyToPublish", "completed"].contains(checkpoint.state)
                || checkpoint.pageCount == checkpoint.acceptedPages
        else { throw TractandaError("documentIntegrity", "Invalid bounded job checkpoint.") }
        if let artifact = checkpoint.corpusArtifactName {
            guard artifact.hasPrefix("page-corpus-"),
                UUID(uuidString: String(artifact.dropFirst("page-corpus-".count)))?.version1Components != nil
            else {
                throw TractandaError("documentIntegrity", "Invalid retained corpus artifact identity.")
            }
        }
        if let prepared = checkpoint.prepared {
            guard prepared.stage == intent.stage, prepared.source == intent.source,
                prepared.identity == intent.identity, prepared.extractedAt == intent.extractedAt,
                prepared.rootEntry.lastPage == checkpoint.acceptedPages,
                prepared.coverage == checkpoint.coverage
            else { throw TractandaError("documentIntegrity", "Job prepared frontier binding changed.") }
        }
        if let receipt = checkpoint.committed {
            try Identifier.validate(receipt.revisionID)
            guard receipt.itemID == intent.source.itemID, receipt.operationID == intent.request.operationID,
                receipt.supersedes == checkpoint.expectedRevisionID
            else {
                throw TractandaError("documentIntegrity", "Job commit receipt changed.")
            }
        }
    }
    var status: DocumentJobStatus {
        DocumentJobStatus(
            jobID: intent.jobID, itemID: intent.source.itemID, attachmentID: intent.source.attachmentID,
            sourceRevisionID: intent.source.revisionID, expectedRevisionID: checkpoint.expectedRevisionID,
            state: checkpoint.state, reasonCode: checkpoint.reasonCode,
            reasonMessage: checkpoint.reasonMessage, pageCount: checkpoint.pageCount,
            acceptedPages: checkpoint.acceptedPages, coverage: checkpoint.coverage,
            discarded: checkpoint.discarded, committed: checkpoint.committed)
    }
}

/// Bounded private records. Lifecycle mutations run on the Store owner queue.
final class DocumentJobRecords {
    var afterHistoryWriteForTesting: (() throws -> Void)?
    var afterLookupWriteForTesting: (() throws -> Void)?
    private let root: URL
    let files: DocumentContentFiles
    init(root: URL, files: DocumentContentFiles) {
        self.root = root
        self.files = files
    }
    func load() throws -> [String: DocumentJobRecord] {
        let directory = root.appendingPathComponent("document-jobs")
        do { _ = try FileMetadata.read(at: directory) } catch FileMetadataError.posix(ENOENT) { return [:] }
        var records: [String: DocumentJobRecord] = [:]
        try POSIXDirectory.withEntries(at: directory) { id in
            try Task.checkCancellation()
            guard UUID(uuidString: id)?.version1Components != nil else {
                throw TractandaError("documentIntegrity", "Job discovery exceeds its bounded identity slots.")
            }
            // A failed first atomic write may leave an empty private directory.
            guard
                let bytes = try self.files.readIfPresent(
                    path: ["document-jobs", id, "record.json"], maximumBytes: 16 * 1024)
            else {
                // One descriptor-relative entry at a time; never remove uncertain/nonempty files.
                _ = try self.files.removeEmptyJobDirectory(id: id)
                return true
            }
            guard records.count < 64 else {
                throw TractandaError("documentIntegrity", "Active job records exceed bounded recovery slots.")
            }
            let record = try DocumentValue.strictDecode(DocumentJobRecord.self, data: bytes)
            try record.validate()
            guard record.intent.jobID == id else {
                throw TractandaError("documentIntegrity", "Job directory binding changed.")
            }
            records[id] = record
            return true
        }
        return records
    }
    private func historyPath(_ id: String) throws -> [String] {
        try Identifier.validate(id)
        guard UUID(uuidString: id)?.version1Components != nil else {
            throw TractandaError("documentIntegrity", "Invalid historical job identity.")
        }
        return ["document-job-history", String(id.prefix(2)), id + ".json"]
    }
    private func operationPath(actorUID: UInt32, operationID: String) -> [String] {
        let key = SHA256.hash(data: Data((String(actorUID) + "\0" + operationID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return ["document-job-operations", String(key.prefix(2)), key + ".json"]
    }
    func archived(_ id: String) throws -> DocumentJobRecord? {
        guard let bytes = try files.readIfPresent(path: historyPath(id), maximumBytes: 16 * 1024) else {
            return nil
        }
        let record = try DocumentValue.strictDecode(DocumentJobRecord.self, data: bytes)
        try record.validate()
        guard record.intent.jobID == id, record.checkpoint.state == "completed" || record.checkpoint.discarded
        else {
            throw TractandaError("documentIntegrity", "Historical job binding changed.")
        }
        return record
    }
    func archived(actorUID: UInt32, operationID: String) throws -> DocumentJobRecord? {
        guard
            let bytes = try files.readIfPresent(
                path: operationPath(actorUID: actorUID, operationID: operationID), maximumBytes: 128),
            let id = String(data: bytes, encoding: .utf8)
        else { return nil }
        guard let record = try archived(id), record.intent.actorUID == actorUID,
            record.intent.request.operationID == operationID
        else {
            throw TractandaError("documentIntegrity", "Historical operation lookup binding changed.")
        }
        return record
    }
    func archive(_ record: DocumentJobRecord) throws {
        try record.validate()
        guard record.checkpoint.state == "completed" || record.checkpoint.discarded else {
            throw TractandaError("documentIntegrity", "Only terminal jobs can release active slots.")
        }
        let id = record.intent.jobID
        let path = try historyPath(id)
        if let existing = try archived(id) {
            guard existing.intent.request == record.intent.request,
                existing.intent.source == record.intent.source,
                existing.checkpoint.committed?.revisionID == record.checkpoint.committed?.revisionID,
                existing.checkpoint.discarded == record.checkpoint.discarded
            else {
                throw TractandaError("documentIntegrity", "Historical terminal job changed.")
            }
            try files.synchronizeDirectory(Array(path.dropLast()))
        } else {
            try files.writeImmutable(try JSON.encode(record), path: path, maximumBytes: 16 * 1024)
        }
        try afterHistoryWriteForTesting?()
        let operation = operationPath(
            actorUID: record.intent.actorUID, operationID: record.intent.request.operationID)
        if let existing = try files.readIfPresent(path: operation, maximumBytes: 128) {
            guard existing == Data(id.utf8) else {
                throw TractandaError("operationMismatch", "Terminal operation names another job.")
            }
            try files.synchronizeDirectory(Array(operation.dropLast()))
        } else {
            try files.writeImmutable(Data(id.utf8), path: operation, maximumBytes: 128)
        }
        try afterLookupWriteForTesting?()
        try files.removePrivateTree(["document-jobs", id])
    }
    func save(_ record: DocumentJobRecord) throws {
        try record.validate()
        try files.replaceJobCheckpoint(
            try JSON.encode(record), path: ["document-jobs", record.intent.jobID, "record.json"],
            jobID: record.intent.jobID)
    }
}
