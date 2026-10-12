import Crypto
import Foundation

struct AttachmentCopyPlan: Codable, Sendable {
    let actorUID: UInt32
    let request: CommitRequest
    let originals: [AttachmentDescriptor]
    let documents: [AttachmentDocumentRepresentation]
    let targetIDs: [String]
    let representationIDs: [String]
    let byteQuota: Int64
    func validate() throws {
        guard request.action == .copy, !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
            !request.operationID.contains("\0"), originals.count == targetIDs.count,
            documents.count == representationIDs.count,
            originals.count <= 128, documents.count <= 128, Set(targetIDs).count == targetIDs.count,
            Set(representationIDs).count == representationIDs.count, byteQuota > 0
        else {
            throw TractandaError("attachmentIntegrity", "Invalid bounded copy plan.")
        }
        for (index, source) in originals.enumerated() {
            guard source.attachmentID != targetIDs[index] else {
                throw TractandaError("attachmentIntegrity", "Copy identity is not independent.")
            }
            _ = try AttachmentDescriptor(
                attachmentID: targetIDs[index], filename: source.filename, mediaType: source.mediaType,
                byteCount: source.byteCount, sha256: source.sha256)
        }
        for id in representationIDs {
            guard UUID(uuidString: id)?.version1Components != nil else {
                throw TractandaError("attachmentIntegrity", "Copy representation ID is not UUIDv1.")
            }
        }
    }
    var key: String {
        SHA256.hash(data: Data((String(actorUID) + "\0" + request.operationID).utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
struct PreparedAttachmentCopy: Sendable {
    let plan: AttachmentCopyPlan
    let originals: [AttachmentDescriptor]
    let signatures: [FileMetadata]
    let documents: [PreparedDocumentContent]
}
struct AttachmentCopyWork: Sendable {
    let plan: AttachmentCopyPlan
    let payloads: AttachmentPayloadStore
    let documents: DocumentContentStore
    let files: DocumentContentFiles
    let stagingQuota: StagingByteQuota
    func perform(progress: AttachmentIntegrityProgress) throws -> PreparedAttachmentCopy {
        try plan.validate()
        let base = ["copies", plan.key]
        let intent = try JSON.encode(plan)
        if let prior = try files.readIfPresent(path: base + ["intent.json"], maximumBytes: 16 * 1024 * 1024) {
            guard prior == intent else { throw TractandaError("operationMismatch", "Copy intent changed.") }
        } else {
            try files.writeImmutable(intent, path: base + ["intent.json"], maximumBytes: 16 * 1024 * 1024)
        }
        for id in plan.targetIDs {
            stagingQuota.pin(path: ["attachments", ".staging", id + ".stage"], copyKey: plan.key)
        }
        var originals: [AttachmentDescriptor] = []
        var signatures: [FileMetadata] = []
        var copied: Int64 = 0
        for (index, source) in plan.originals.enumerated() {
            try Task.checkCancellation()
            let receipt = base + ["original-\(index).json"]
            let output: AttachmentDescriptor
            if let data = try files.readIfPresent(path: receipt, maximumBytes: 16 * 1024) {
                output = try JSON.decode(AttachmentDescriptor.self, data)
                guard output.attachmentID == plan.targetIDs[index], output.sha256 == source.sha256,
                    output.byteCount == source.byteCount
                else { throw TractandaError("attachmentIntegrity", "Prepared original copy changed.") }
                try payloads.verifyStagedOriginal(output, progress: { _ in })
            } else {
                let prior = copied
                output = try payloads.clone(
                    source: source, newID: plan.targetIDs[index], publish: false, resume: true,
                    progress: { progress.update(prior + $0) })
                try files.writeImmutable(JSON.encode(output), path: receipt)
            }
            let next = copied.addingReportingOverflow(output.byteCount)
            guard !next.overflow, next.partialValue <= plan.byteQuota else {
                throw TractandaError("resourceLimit", "Copy exceeds its staging-byte quota.")
            }
            copied = next.partialValue
            progress.update(copied)
            signatures.append(try payloads.verifyStagedOriginal(output, progress: { _ in }))
            originals.append(output)
        }
        var prepared: [PreparedDocumentContent] = []
        for (index, document) in plan.documents.enumerated() {
            try Task.checkCancellation()
            let receipt = base + ["document-\(index).json"]
            let output: PreparedDocumentContent
            if let data = try files.readIfPresent(path: receipt, maximumBytes: 64 * 1024) {
                output = try JSON.decode(PreparedDocumentContent.self, data)
                guard output.source == document.source, output.identity == document.identity,
                    output.extractedAt == document.extractedAt
                else { throw TractandaError("documentIntegrity", "Prepared document copy changed.") }
            } else {
                output = try documents.prepareClone(document, maximumWriteBytes: plan.byteQuota - copied)
                try files.writeImmutable(JSON.encode(output), path: receipt)
            }
            stagingQuota.pin(path: output.stage, copyKey: plan.key)
            stagingQuota.pin(
                path: ["documents", ".staging", output.stage.last! + ".publication.json"], copyKey: plan.key)
            try documents.revalidatePrepared(output)
            let next = copied.addingReportingOverflow(output.byteCount)
            guard !next.overflow, next.partialValue <= plan.byteQuota else {
                throw TractandaError("resourceLimit", "Copy exceeds its staging-byte quota.")
            }
            copied = next.partialValue
            progress.update(copied)
            prepared.append(output)
        }
        try files.synchronizeDirectory(base)
        return PreparedAttachmentCopy(
            plan: plan, originals: originals, signatures: signatures, documents: prepared)
    }
}
enum AttachmentCopyAdmission: Sendable {
    case replay(CommitResult)
    case prepared(AttachmentCopyWork)
}

struct PreparedCopyCall: Sendable {
    let callID: String
    let admission: AttachmentCopyAdmission
}
