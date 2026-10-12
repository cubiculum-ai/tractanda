import Crypto
import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class DocumentJobMaterialTests: XCTestCase {
    private let config = String(repeating: "c", count: 64)
    private func fixture(_ root: URL) throws -> (ItemStore, DocumentJobRecord, AttachmentDescriptor) {
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let item = try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
        let data = Data([1, 2, 3])
        let upload = try store.beginAttachment(
            AttachmentUploadRequest(
                itemID: item.itemID, expectedRevisionID: item.revisionID,
                operationID: "original", filename: "tiny.pdf", mediaType: "application/pdf", byteCount: 3,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        let id = try XCTUnwrap(upload.uploadID)
        _ = try store.appendAttachment(uploadID: id, offset: 0, data: data)
        let attached = try store.finishAttachment(uploadID: id).revision
        let job = try store.startDocumentJob(
            DocumentJobStart(
                itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                attachmentID: upload.attachment.attachmentID, operationID: "job"), identity: .init(),
            configurationSHA256: config)
        return (store, try store.claimDocumentJob(job.jobID, configurationSHA256: config), upload.attachment)
    }
    private func root() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "document-material-" + Identifier.make())
    }
    func testVerifiedOriginalUsesRetainedDescriptorAndRejectsPathReplacement() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, record, _) = try fixture(root)
        let work = try store.documentJobMaterialWork(
            record.intent.jobID, generation: record.checkpoint.generation, configurationSHA256: config)
        let original = try await Task.detached { try work.verifyOriginal(cancellation: .init()) }.value
        XCTAssertEqual(original.file.byteCount, 3)
        XCTAssertEqual(original.file.mode & 0o222, 0)
        XCTAssertNoThrow(try original.check())
        let url = URL(fileURLWithPath: original.path)
        let saved = url.appendingPathExtension("owned-test-original")
        try FileManager.default.moveItem(at: url, to: saved)
        try Data([1, 2, 3]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        XCTAssertThrowsError(try original.check()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "documentOriginalChanged")
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: saved, to: url)
        XCTAssertNoThrow(try original.check())
    }
    func testDetachedStageSealsAckOnePageAndFenceBeforePublication() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, record, descriptor) = try fixture(root)
        let id = record.intent.jobID
        let generation = record.checkpoint.generation
        try store.inspectDocumentJob(id, generation: generation, pageCount: 2)
        let work = try store.documentJobMaterialWork(id, generation: generation, configurationSHA256: config)
        let seals = try await Task.detached {
            () throws -> (DocumentStageSeal, DocumentStageSeal, DocumentStageSeal) in
            let stage = work.stage()
            let recovered = try stage.recover()
            let first = try stage.append(
                DocumentStoredPage(
                    pageNumber: 1, sourceSHA256: descriptor.sha256,
                    status: "unsupported", failureCode: "fixtureUnsupported"), pageCount: 2)
            let second = try stage.append(
                DocumentStoredPage(
                    pageNumber: 2, sourceSHA256: descriptor.sha256,
                    status: "unsupported", failureCode: "fixtureUnsupported"), pageCount: 2)
            return (recovered, first, second)
        }.value
        XCTAssertEqual(try store.acknowledgeDocumentStage(seals.0).acceptedPages, 0)
        XCTAssertThrowsError(
            try store.acknowledgeDocumentStage(seals.2),
            "A producer cannot skip per-page checkpoint acknowledgement")
        XCTAssertEqual(try store.acknowledgeDocumentStage(seals.1).acceptedPages, 1)
        _ = try store.controlDocumentJob(id, action: "cancel", configurationSHA256: config)
        XCTAssertThrowsError(
            try store.acknowledgeDocumentStage(seals.2), "Cancellation fences a detached accepted-page result"
        )
    }
    func testOriginalCancellationAndDigestCorruptionNeverCreatePageOutcomes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, record, _) = try fixture(root)
        let work = try store.documentJobMaterialWork(
            record.intent.jobID, generation: record.checkpoint.generation, configurationSHA256: config)
        let cancelled = DocumentConversionCancellation()
        cancelled.cancel()
        do {
            _ = try await Task.detached { try work.verifyOriginal(cancellation: cancelled) }.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let original = try await Task.detached { try work.verifyOriginal(cancellation: .init()) }.value
        let url = URL(fileURLWithPath: original.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Data([9, 9, 9]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        do {
            _ = try await Task.detached { try work.verifyOriginal(cancellation: .init()) }.value
            XCTFail("Expected digest mismatch")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "attachmentIntegrity") }
        XCTAssertEqual(try store.documentJobStatus(record.intent.jobID).acceptedPages, 0)
        XCTAssertNil(try store.documentJobStatus(record.intent.jobID).pageCount)
    }
    func testCurrentPreparedCandidateDiscardAfterPhysicalPublicationBeforeCAS() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, record, descriptor) = try fixture(root)
        try store.inspectDocumentJob(
            record.intent.jobID, generation: record.checkpoint.generation, pageCount: 1)
        let work = try store.documentJobMaterialWork(
            record.intent.jobID, generation: record.checkpoint.generation, configurationSHA256: config)
        let stage = work.stage()
        _ = try stage.recover()
        _ = try stage.append(
            DocumentStoredPage(
                pageNumber: 1, sourceSHA256: descriptor.sha256,
                status: "unsupported", failureCode: "fixtureUnsupported"), pageCount: 1)
        let prepared = try XCTUnwrap(stage.prepare(pageCount: 1).prepared)
        let content = try work.contents.publishPrepared(prepared)
        let candidate = try work.contents.directory(content.contentID).reduce(store.root) {
            $0.appendingPathComponent($1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertNil(try store.documentJobStatus(record.intent.jobID).committed)
        try stage.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.root.appendingPathComponent(
                    "documents/.staging/" + record.intent.jobID + ".publication.json"
                ).path))
        XCTAssertNil(try store.documentJobStatus(record.intent.jobID).committed)
    }

}
