import Foundation

/// Compact lifecycle receipt: original transfer never returns the parent item's arbitrary body.
public struct AttachmentCommitResult: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case itemID, revisionID, supersedes, operationID, warnings
        case wasReplayed = "replayed"
        case isIndexReady = "indexReady"
    }
    public let itemID: String
    public let revisionID: String
    public let supersedes: String?
    public let operationID: String
    public let wasReplayed: Bool
    public let isIndexReady: Bool
    public let warnings: [String]
    public init(_ result: CommitResult) {
        itemID = result.revision.itemID
        revisionID = result.revision.revisionID
        supersedes = result.revision.supersedes
        operationID = result.revision.fields["operationID"]!.string!
        wasReplayed = result.wasReplayed
        isIndexReady = result.isIndexReady
        warnings = result.warnings
    }
}

/// A bounded transfer of an original into one guarded item revision.
public struct AttachmentUploadRequest: Codable, Equatable, Sendable {
    public let itemID: String
    public let expectedRevisionID: String
    public let operationID: String
    public let filename: String
    public let mediaType: String
    public let byteCount: Int64
    public let sha256: String
    public init(
        itemID: String, expectedRevisionID: String, operationID: String, filename: String,
        mediaType: String, byteCount: Int64, sha256: String
    ) {
        self.itemID = itemID
        self.expectedRevisionID = expectedRevisionID
        self.operationID = operationID
        self.filename = filename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}
public struct AttachmentUploadResult: Codable, Sendable {
    public let uploadID: String?
    public let attachment: AttachmentDescriptor
    public let offset: Int64
    public let chunkBytes: Int
    public let expiresAt: String?
    public let committed: AttachmentCommitResult?
    public init(
        uploadID: String?, attachment: AttachmentDescriptor, offset: Int64, chunkBytes: Int,
        expiresAt: String?, committed: AttachmentCommitResult?
    ) {
        self.uploadID = uploadID
        self.attachment = attachment
        self.offset = offset
        self.chunkBytes = chunkBytes
        self.expiresAt = expiresAt
        self.committed = committed
    }
}
public struct AttachmentListResult: Codable, Sendable {
    public let itemID: String
    public let revisionID: String
    public let attachments: [AttachmentDescriptor]
    public init(itemID: String, revisionID: String, attachments: [AttachmentDescriptor]) {
        self.itemID = itemID
        self.revisionID = revisionID
        self.attachments = attachments
    }
}
public struct AttachmentContentResult: Codable, Sendable {
    public let attachment: AttachmentDescriptor
    public let offset: Int64
    public let nextOffset: Int64
    public let isComplete: Bool
    public let data: Data
    public init(
        attachment: AttachmentDescriptor, offset: Int64, nextOffset: Int64,
        isComplete: Bool, data: Data
    ) {
        self.attachment = attachment
        self.offset = offset
        self.nextOffset = nextOffset
        self.isComplete = isComplete
        self.data = data
    }
}

/// Actual retained bytes and reserved bounded bookkeeping are separate resources.
public struct AttachmentStagingUsage: Codable, Equatable, Sendable {
    public let originalBytes: Int64
    public let checkpointBytes: Int64
    public let bookkeepingReservedBytes: Int64
    public let maximumStagedBytes: Int64
    public init(
        originalBytes: Int64, checkpointBytes: Int64, bookkeepingReservedBytes: Int64,
        maximumStagedBytes: Int64
    ) {
        self.originalBytes = originalBytes
        self.checkpointBytes = checkpointBytes
        self.bookkeepingReservedBytes = bookkeepingReservedBytes
        self.maximumStagedBytes = maximumStagedBytes
    }
}
/// A short status request is independent of the original's total transfer/hash duration.
public struct AttachmentIntegrityStatus: Codable, Sendable {
    public let attachmentID: String
    public let uploadID: String?
    public let phase: String
    public let verifiedBytes: Int64
    public let totalBytes: Int64
    public let retryAfterMilliseconds: Int
    public let staging: AttachmentStagingUsage?
    public init(
        attachmentID: String, uploadID: String?, phase: String, verifiedBytes: Int64, totalBytes: Int64,
        staging: AttachmentStagingUsage? = nil
    ) {
        self.attachmentID = attachmentID
        self.uploadID = uploadID
        self.staging = staging
        self.phase = phase
        self.verifiedBytes = verifiedBytes
        self.totalBytes = totalBytes
        retryAfterMilliseconds = 100
    }
}
