import Crypto
import XCTest

@testable import TractandaCore

final class AttachmentQuotaTests: XCTestCase {
    private func directory() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "upload-quota-" + Identifier.make())
    }
    private func intent(_ revision: Revision, bytes: Data, operation: String) -> AttachmentUploadRequest {
        AttachmentUploadRequest(
            itemID: revision.itemID, expectedRevisionID: revision.revisionID,
            operationID: operation, filename: "tiny.txt", mediaType: "text/plain",
            byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    private func usage(_ root: URL) throws -> (Int64, Int64) {
        let payloads = try AttachmentPayloadStore(
            root: root, ownerUID: getuid(),
            reserveBytes: AttachmentFixtureCapacity.reserveBytes)
        let uploads = try payloads.loadUploads()
        let quota = try StagingByteQuota(
            root: root, ownerUID: getuid(), maximumBytes: .max, pendingUploads: uploads)
        return (quota.usedBytes, Int64(uploads.count) * StagingByteQuota.uploadCheckpointReservation)
    }
    func testPublishedCASConflictRetainsBudgetAcrossRestartAndAbortReleasesIt() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID: String
        let otherID: String
        let bytes = Data("retained original".utf8)
        do {
            let store = try ItemStore(root: root)
            let revision = try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
            firstID = try XCTUnwrap(
                store.beginAttachment(intent(revision, bytes: bytes, operation: "first")).uploadID)
            otherID = try XCTUnwrap(
                store.beginAttachment(intent(revision, bytes: Data([7]), operation: "other")).uploadID)
            _ = try store.appendAttachment(uploadID: firstID, offset: 0, data: bytes)
            _ = try store.commit(
                CommitRequest(
                    action: .revise, itemID: revision.itemID,
                    expectedRevisionID: revision.revisionID, changes: ["subject": .text("changed")],
                    operationID: "change"))
            XCTAssertThrowsError(try store.finishAttachment(uploadID: firstID)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "revisionConflict")
            }
            XCTAssertEqual(
                try store.withAccess(
                    forUID: getuid(), { try store.attachmentUploadStatus(uploadID: firstID) }
                ).staging?.originalBytes,
                Int64(bytes.count))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("attachments/.staging/" + firstID + ".stage").path))
        }
        let counted = try usage(root)
        let store = try ItemStore(
            root: root,
            attachmentUploadPolicy: AttachmentUploadPolicy(
                maximumStagedBytes: counted.0 + counted.1,
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
        let pending = try store.withAccess(
            forUID: getuid(), { try store.attachmentUploadStatus(uploadID: firstID) })
        XCTAssertEqual(pending.staging?.originalBytes, Int64(bytes.count))
        XCTAssertEqual(pending.staging?.bookkeepingReservedBytes, 16 * 1024)
        XCTAssertThrowsError(try store.appendAttachment(uploadID: otherID, offset: 0, data: Data([7]))) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        // Cleanup metadata spends reserved headroom even when payload budget is fully used.
        try store.abortAttachment(uploadID: firstID)
        XCTAssertEqual(try store.appendAttachment(uploadID: otherID, offset: 0, data: Data([7])), 1)
        try store.abortAttachment(uploadID: otherID)
        XCTAssertEqual(try usage(root).0, 0)
    }
    func testLoweredQuotaStillReopensAndExpiresRetainedWork() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id: String
        do {
            let store = try ItemStore(root: root)
            let revision = try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
            id = try XCTUnwrap(
                store.beginAttachment(intent(revision, bytes: Data([1, 2]), operation: "first")).uploadID)
            _ = try store.appendAttachment(uploadID: id, offset: 0, data: Data([1, 2]))
            store.afterAttachmentPayloadPublicationForTesting = {
                throw TractandaError("injected", "Before location checkpoint")
            }
            XCTAssertThrowsError(try store.finishAttachment(uploadID: id))
        }
        let store = try ItemStore(
            root: root,
            attachmentUploadPolicy: AttachmentUploadPolicy(
                maximumStagedBytes: 1,
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
        let status = try store.withAccess(
            forUID: getuid(), { try store.attachmentUploadStatus(uploadID: id) })
        XCTAssertEqual(status.staging?.originalBytes, 2)
        store.attachmentClockForTesting = { Date().addingTimeInterval(7200) }
        XCTAssertThrowsError(
            try store.withAccess(forUID: getuid(), { try store.attachmentUploadStatus(uploadID: id) })
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "uploadExpired")
        }
        XCTAssertEqual(try usage(root).0, 0)
    }
    func testCommittedLostReplyReplaysUnderLoweredQuotaAndDisposesOnlyRecoveryState() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request: AttachmentUploadRequest
        let itemID: String
        do {
            let store = try ItemStore(root: root)
            let revision = try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
            itemID = revision.itemID
            let bytes = Data("committed original".utf8)
            request = intent(revision, bytes: bytes, operation: "first")
            let id = try XCTUnwrap(store.beginAttachment(request).uploadID)
            _ = try store.appendAttachment(uploadID: id, offset: 0, data: bytes)
            store.afterAttachmentItemCommitForTesting = {
                throw TractandaError("injected", "Lost reply before recovery cleanup")
            }
            XCTAssertThrowsError(try store.finishAttachment(uploadID: id))
            XCTAssertEqual(try store.listAttachments(itemID: itemID).attachments.count, 1)
        }
        let store = try ItemStore(
            root: root,
            attachmentUploadPolicy: AttachmentUploadPolicy(
                maximumStagedBytes: 1,
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
        let replay = try store.beginAttachment(request)
        XCTAssertTrue(replay.committed?.wasReplayed == true)
        XCTAssertEqual(try usage(root).0, 0)
        let descriptor = try XCTUnwrap(store.listAttachments(itemID: itemID).attachments.first)
        XCTAssertEqual(
            try store.attachmentContent(itemID: itemID, attachmentID: descriptor.attachmentID).data,
            Data("committed original".utf8))
    }
    func testColdPublishedRetryCommitsAndReleasesRecoveryReservation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request: AttachmentUploadRequest
        let id: String
        do {
            let store = try ItemStore(root: root)
            let revision = try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
            let data = Data("same intent".utf8)
            request = intent(revision, bytes: data, operation: "first")
            id = try XCTUnwrap(store.beginAttachment(request).uploadID)
            _ = try store.appendAttachment(uploadID: id, offset: 0, data: data)
            store.beforeAttachmentCommitForTesting = {
                throw TractandaError("injected", "After canonical publication")
            }
            XCTAssertThrowsError(try store.finishAttachment(uploadID: id))
        }
        let store = try ItemStore(root: root)
        XCTAssertEqual(try store.beginAttachment(request).uploadID, id)
        let result = try store.finishAttachment(uploadID: id)
        let replay = try store.beginAttachment(request)
        XCTAssertTrue(replay.committed?.wasReplayed == true)
        XCTAssertEqual(replay.committed?.revisionID, result.revision.revisionID)
        XCTAssertEqual(try usage(root).0, 0)
        XCTAssertEqual(try store.listAttachments(itemID: result.revision.itemID).attachments.count, 1)
    }
    func testAdmissionRequiresInitialCheckpointPlusReplacementHeadroom() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(
            root: root,
            attachmentUploadPolicy: AttachmentUploadPolicy(
                maximumStagedBytes: StagingByteQuota.uploadCheckpointReservation,
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
        let revision = try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
        XCTAssertThrowsError(
            try store.beginAttachment(intent(revision, bytes: Data([1]), operation: "first"))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertEqual(try usage(root).0, 0)
        let quota = try StagingByteQuota(root: root, ownerUID: getuid(), maximumBytes: 16_884)
        try quota.retainUpload(id: "tiny", initialCheckpointBytes: 500)
        // The initial bytes are already reserved while filesystem creation is in flight.
        XCTAssertThrowsError(try quota.charge(1, path: ["copies", "racer", "intent.json"]))
        try quota.chargeCheckpoint(
            500, temporaryPath: ["attachments", ".uploads", "tiny.tmp"], uploadID: "tiny")
        quota.checkpointReplaced(temporaryPath: ["attachments", ".uploads", "tiny.tmp"], uploadID: "tiny")
        XCTAssertEqual(quota.usedBytes, 500)
        XCTAssertThrowsError(try quota.charge(1, path: ["copies", "racer", "intent.json"]))
        quota.completeUpload(id: "tiny")
        XCTAssertNoThrow(try quota.charge(1, path: ["copies", "racer", "intent.json"]))
        let failed = try StagingByteQuota(root: root, ownerUID: getuid(), maximumBytes: 16_884)
        try failed.retainUpload(id: "retry", initialCheckpointBytes: 500)
        let temporary = ["attachments", ".uploads", "retry.tmp"]
        try failed.chargeCheckpoint(500, temporaryPath: temporary, uploadID: "retry")
        failed.refund(500, path: temporary)  // Initial checkpoint creation failed before publication.
        XCTAssertThrowsError(try failed.charge(1, path: ["copies", "racer", "intent.json"]))
        try failed.chargeCheckpoint(500, temporaryPath: temporary, uploadID: "retry")
        failed.checkpointReplaced(temporaryPath: temporary, uploadID: "retry")
        XCTAssertEqual(failed.usedBytes, 500)
        failed.completeUpload(id: "retry")
    }
    func testFilesystemAdmissionFailureRefundsSlotsAndCanRetryWithoutRestart() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(
            root: root,
            attachmentUploadPolicy: AttachmentUploadPolicy(
                maximumStagedBytes: 32 * 1024,
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes))
        let revision = try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
        let parent = root.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = parent.appendingPathComponent(".staging")
        try Data([1]).write(to: stage)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.path)
        let request = intent(revision, bytes: Data([7]), operation: "retry")
        for _ in 0..<65 {
            XCTAssertThrowsError(try store.beginAttachment(request)) {
                XCTAssertNotEqual(
                    ($0 as? TractandaError)?.code, "resourceLimit",
                    "Failed creation must not consume slots or headroom")
            }
        }
        try FileManager.default.removeItem(at: stage)
        let admitted = try store.beginAttachment(request)
        let id = try XCTUnwrap(admitted.uploadID)
        XCTAssertEqual(try store.beginAttachment(request).uploadID, id)
        try store.abortAttachment(uploadID: id)
        XCTAssertEqual(try usage(root).0, 0)
    }

    func testJobAndUploadInitialAndReplacementHoldsShareOneCopyBoundary() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reservation = StagingByteQuota.uploadCheckpointReservation
        let quota = try StagingByteQuota(root: root, ownerUID: getuid(), maximumBytes: 2 * reservation + 1000)
        try quota.retainUpload(id: "upload", initialCheckpointBytes: 500)
        try quota.retainJob(id: "job", initialBytes: 500)
        let copy = ["copies", "racer", "intent.json"]
        XCTAssertThrowsError(try quota.charge(1, path: copy))
        let uploadTemporary = ["attachments", ".uploads", "upload.tmp"]
        try quota.chargeCheckpoint(500, temporaryPath: uploadTemporary, uploadID: "upload")
        quota.checkpointReplaced(temporaryPath: uploadTemporary, uploadID: "upload")
        let jobPath = ["document-jobs", "job", "record.json"]
        try quota.chargeJobCheckpoint(500, path: jobPath, id: "job")
        quota.refund(500, path: jobPath)  // Failed first job replacement preserves initial hold.
        XCTAssertThrowsError(try quota.charge(1, path: copy))
        try quota.chargeJobCheckpoint(500, path: jobPath, id: "job")
        quota.jobCheckpointReplaced(oldBytes: 0, path: jobPath)
        XCTAssertEqual(quota.usedBytes, 1000)
        XCTAssertThrowsError(try quota.charge(1, path: copy))
        quota.completeUpload(id: "upload")
        quota.release(path: jobPath)
        quota.releaseJobAdmission(id: "job")
        XCTAssertEqual(quota.usedBytes, 0)
        XCTAssertNoThrow(try quota.charge(1, path: copy))
        let exact = try StagingByteQuota(root: root, ownerUID: getuid(), maximumBytes: reservation + 500)
        try exact.retainJob(id: "single", initialBytes: 500)
        XCTAssertThrowsError(try exact.charge(1, path: copy))
        let exactPath = ["document-jobs", "single", "record.json"]
        try exact.chargeJobCheckpoint(500, path: exactPath, id: "single")
        exact.jobCheckpointReplaced(oldBytes: 0, path: exactPath)
        XCTAssertThrowsError(try exact.charge(1, path: copy))
    }

}
