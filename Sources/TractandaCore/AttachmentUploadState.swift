import Foundation

/// Operator resources, independent of the attachment format and original byte count.
public struct AttachmentUploadPolicy: Codable, Sendable {
    public let idleRetentionSeconds: Double
    public let maximumStagedBytes: Int64
    public let minimumFreeBytes: Int64
    public init(
        idleRetentionSeconds: Double = 3600, maximumStagedBytes: Int64 = 8 * 1024 * 1024 * 1024,
        minimumFreeBytes: Int64 = 1024 * 1024 * 1024
    ) {
        self.idleRetentionSeconds = idleRetentionSeconds
        self.maximumStagedBytes = maximumStagedBytes
        self.minimumFreeBytes = minimumFreeBytes
    }
    func validate() throws {
        guard idleRetentionSeconds.isFinite, idleRetentionSeconds > 0, maximumStagedBytes > 0,
            minimumFreeBytes >= 0
        else {
            throw TractandaError(
                "invalidAttachmentPolicy", "Upload retention and staging quota must be positive.")
        }
    }
}

/// Mutable operational recovery data. Originals and committed revisions remain immutable.
struct AttachmentUploadState: Codable, Sendable {
    let uid: UInt32
    let request: AttachmentUploadRequest
    let descriptor: AttachmentDescriptor
    var expiresAt: Date
    var phase: String = "uploading"
    var location: String? = "staged"
    var failureCode: String?
    func validate() throws {
        try Identifier.validate(request.itemID)
        try Identifier.validate(request.expectedRevisionID)
        let expected = try AttachmentDescriptor(
            attachmentID: descriptor.attachmentID, filename: request.filename, mediaType: request.mediaType,
            byteCount: request.byteCount, sha256: request.sha256)
        guard expected == descriptor, !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
            !request.operationID.contains("\0"), expiresAt.timeIntervalSince1970.isFinite,
            ["uploading", "verifying", "verified", "published", "paused", "failed", "discarding"].contains(
                phase),
            location == nil || ["staged", "published"].contains(location!),
            failureCode.map({ !$0.isEmpty && $0.utf8.count <= 200 }) ?? true
        else { throw TractandaError("unsafeAttachmentStore", "Upload recovery intent is invalid.") }
    }
}

struct AttachmentIntegrityWork: Sendable {
    let payloads: AttachmentPayloadStore
    let descriptor: AttachmentDescriptor
    let uploadID: String?
    func perform(progress: AttachmentIntegrityProgress) throws {
        try Task.checkCancellation()
        if uploadID != nil {
            try payloads.verifyStagedOriginal(descriptor, progress: { progress.update($0) })
        } else {
            try payloads.validate(descriptor: descriptor, progress: { progress.update($0) })
        }
    }
}

final class AttachmentIntegrityProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    func update(_ value: Int64) {
        lock.lock()
        bytes = value
        lock.unlock()
    }
    var verifiedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

struct PreparedAttachmentIntegrityCall: Sendable {
    let key: String
    let callID: String
    let method: String
    let work: AttachmentIntegrityWork?
}
