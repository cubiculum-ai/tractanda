import Foundation

public struct DocumentJobStart: Codable, Equatable, Sendable {
    public let itemID: String
    public let expectedRevisionID: String
    public let attachmentID: String
    public let operationID: String
    public init(itemID: String, expectedRevisionID: String, attachmentID: String, operationID: String) {
        self.itemID = itemID
        self.expectedRevisionID = expectedRevisionID
        self.attachmentID = attachmentID
        self.operationID = operationID
    }
}

/// Durable processing coverage describes visited pages; it makes no OCR accuracy claim.
public struct DocumentJobStatus: Codable, Sendable {
    public let jobID: String
    public let itemID: String
    public let attachmentID: String
    public let sourceRevisionID: String
    public let expectedRevisionID: String
    public let state: String
    public let reasonCode: String?
    /// Safe operational timeout context; no document content or worker stderr.
    public let reasonMessage: String?
    public let pageCount: Int64?
    public let acceptedPages: Int64
    public let coverage: DocumentCoverage
    public let discarded: Bool
    public let committed: AttachmentCommitResult?
    public init(
        jobID: String, itemID: String, attachmentID: String, sourceRevisionID: String,
        expectedRevisionID: String, state: String, reasonCode: String?, reasonMessage: String? = nil,
        pageCount: Int64?,
        acceptedPages: Int64, coverage: DocumentCoverage, discarded: Bool,
        committed: AttachmentCommitResult?
    ) {
        self.jobID = jobID
        self.itemID = itemID
        self.attachmentID = attachmentID
        self.sourceRevisionID = sourceRevisionID
        self.expectedRevisionID = expectedRevisionID
        self.state = state
        self.reasonCode = reasonCode
        self.reasonMessage = reasonMessage
        self.pageCount = pageCount
        self.acceptedPages = acceptedPages
        self.coverage = coverage
        self.discarded = discarded
        self.committed = committed
    }
    public func validate() throws {
        for id in [jobID, itemID, attachmentID, sourceRevisionID, expectedRevisionID] {
            try DocumentValue.validateID(id)
        }
        guard
            [
                "queued", "verifyingOriginal", "inspecting", "running", "paused", "cancelled",
                "readyToPublish", "completed", "failed",
            ].contains(state),
            acceptedPages >= 0, try coverage.processedPageCount() == acceptedPages,
            pageCount.map({ $0 > 0 && acceptedPages <= $0 }) ?? (acceptedPages == 0),
            reasonCode.map({ !$0.isEmpty && $0.utf8.count <= 200 && !$0.contains("\0") }) ?? true,
            reasonMessage.map({
                reasonCode == "documentTimeout" && !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0")
            }) ?? true,
            !discarded || ["cancelled", "completed"].contains(state),
            (state == "completed") == (committed != nil),
            !["readyToPublish", "completed"].contains(state) || pageCount == acceptedPages
        else {
            throw TractandaError("protocolError", "Invalid durable document job status.")
        }
        if let committed {
            try DocumentValue.validateID(committed.revisionID)
            guard committed.itemID == itemID else {
                throw TractandaError("protocolError", "Document job receipt changed item identity.")
            }
        }
    }
}

public struct DocumentJobList: Codable, Sendable {
    public let jobs: [DocumentJobStatus]
    public let nextJobID: String?
    public init(jobs: [DocumentJobStatus], nextJobID: String?) {
        self.jobs = jobs
        self.nextJobID = nextJobID
    }
}

/// Private stage output has no canonical content identity, revision, or citation.
public struct DocumentJobPage: Codable, Sendable {
    public let jobID: String
    public let provisional: Bool
    public let outcome: DocumentStoredPage
    public init(jobID: String, outcome: DocumentStoredPage) {
        self.jobID = jobID
        provisional = true
        self.outcome = outcome
    }
}

extension ItemClient {
    public func startDocumentJob(_ request: DocumentJobStart) async throws -> DocumentJobStatus {
        for id in [request.itemID, request.expectedRevisionID, request.attachmentID] {
            try DocumentValue.validateID(id)
        }
        guard !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
            !request.operationID.contains("\0")
        else {
            throw TractandaError("invalidArguments", "Supply a bounded document operation identity.")
        }
        let result = try await call(
            "TractandaDocumentJob/start", arguments: request, returning: DocumentJobStatus.self)
        try result.validate()
        guard result.itemID == request.itemID, result.attachmentID == request.attachmentID else {
            throw TractandaError("protocolError", "Document job admission binding changed.")
        }
        return result
    }
    public func documentJob(_ jobID: String) async throws -> DocumentJobStatus {
        try await documentJobControl("status", jobID: jobID)
    }
    public func cancelDocumentJob(_ jobID: String) async throws -> DocumentJobStatus {
        try await documentJobControl("cancel", jobID: jobID)
    }
    public func resumeDocumentJob(_ jobID: String) async throws -> DocumentJobStatus {
        try await documentJobControl("resume", jobID: jobID)
    }
    public func discardDocumentJob(_ jobID: String) async throws -> DocumentJobStatus {
        try await documentJobControl("discard", jobID: jobID)
    }
    public func rebaseDocumentJob(_ jobID: String, expectedRevisionID: String) async throws
        -> DocumentJobStatus
    {
        try DocumentValue.validateID(jobID)
        try DocumentValue.validateID(expectedRevisionID)
        let result = try await call(
            "TractandaDocumentJob/rebase",
            arguments: JobRebase(jobID: jobID, expectedRevisionID: expectedRevisionID),
            returning: DocumentJobStatus.self)
        try validateJobReply(result, jobID: jobID)
        return result
    }
    public func documentJobPage(_ jobID: String, pageNumber: Int64) async throws -> DocumentJobPage {
        try DocumentValue.validateID(jobID)
        guard pageNumber > 0 else {
            throw TractandaError("invalidArguments", "Use a positive document page ordinal.")
        }
        let result = try await call(
            "TractandaDocumentJob/page", arguments: JobPageRequest(jobID: jobID, pageNumber: pageNumber),
            returning: DocumentJobPage.self)
        try result.outcome.validate()
        guard result.jobID == jobID, result.provisional, result.outcome.pageNumber == pageNumber else {
            throw TractandaError("protocolError", "Provisional page binding changed.")
        }
        return result
    }
    public func documentJobs(afterJobID: String? = nil, limit: Int = 32) async throws -> DocumentJobList {
        if let afterJobID { try DocumentValue.validateID(afterJobID) }
        guard (1...64).contains(limit) else {
            throw TractandaError("invalidArguments", "Use a job discovery limit of1...64.")
        }
        let result = try await call(
            "TractandaDocumentJob/list", arguments: JobListRequest(afterJobID: afterJobID, limit: limit),
            returning: DocumentJobList.self)
        guard result.jobs.count <= limit else {
            throw TractandaError("protocolError", "Job discovery exceeded its window.")
        }
        for job in result.jobs { try job.validate() }
        if let next = result.nextJobID { try DocumentValue.validateID(next) }
        return result
    }
    private func validateJobReply(_ result: DocumentJobStatus, jobID: String) throws {
        try result.validate()
        guard result.jobID == jobID else {
            throw TractandaError("protocolError", "Document job response identity changed.")
        }
    }
    private func documentJobControl(_ action: String, jobID: String) async throws -> DocumentJobStatus {
        try DocumentValue.validateID(jobID)
        let result = try await call(
            "TractandaDocumentJob/" + action, arguments: JobID(jobID: jobID),
            returning: DocumentJobStatus.self)
        try validateJobReply(result, jobID: jobID)
        return result
    }
}

private struct JobID: Encodable, Sendable { let jobID: String }
private struct JobRebase: Encodable, Sendable {
    let jobID: String
    let expectedRevisionID: String
}
private struct JobPageRequest: Encodable, Sendable {
    let jobID: String
    let pageNumber: Int64
}
private struct JobListRequest: Encodable, Sendable {
    let afterJobID: String?
    let limit: Int
}
