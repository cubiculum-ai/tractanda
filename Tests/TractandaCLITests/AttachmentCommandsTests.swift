import Foundation
import TractandaCore
import XCTest

@testable import TractandaCLI

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class AttachmentCommandsTests: XCTestCase {
    private var root: URL!
    private var store: AttachmentReceiptStore!
    private let item = "11111111-1111-1111-8111-111111111111"
    private let revision = "22222222-2222-1222-8222-222222222222"

    override func setUpWithError() throws {
        #if os(Linux)
            let temporary = URL(fileURLWithPath: "/tmp")
        #else
            let temporary = URL(fileURLWithPath: "/private/tmp")
        #endif
        try FixtureCapacity.require(at: temporary, planned: 16 * 1024 * 1024)
        root = temporary.appendingPathComponent(try UUID.makeVersion1().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        store = AttachmentReceiptStore(
            directory: root.appendingPathComponent("receipts"), endpoint: "/test/one.sock")
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    private func run(_ args: [String], _ transport: FakeTransport, _ source: FakeSource, output: inout [Data])
        throws
    {
        try AttachmentCommand.run(
            args, transport: transport, source: source, receipts: store, emit: { output.append($0) })
    }
    private func begin(_ transport: FakeTransport, _ source: FakeSource, output: inout [Data]) throws
        -> AttachmentUploadReceipt
    {
        try run(
            ["attachment", "begin", item, revision, "op-stable", "/source/file.pdf"], transport, source,
            output: &output)
        return try JSON.decode(AttachmentUploadReceipt.self, XCTUnwrap(output.last))
    }
    private func retained() throws -> AttachmentUploadReceipt {
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
                .first)
        return try JSON.decode(AttachmentUploadReceipt.self, Data(contentsOf: file))
    }

    func testLostBeginPersistsAndPrintsIntentBeforeCallAndReplaysReceivedOffset() throws {
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        transport.beginFailure = "connectionLost"
        XCTAssertThrowsError(try begin(transport, source, output: &output))
        let receipt = try retained()
        XCTAssertEqual(receipt.operationID, "op-stable")
        XCTAssertNil(receipt.uploadID)
        XCTAssertEqual(
            try JSON.decode(AttachmentUploadReceipt.self, XCTUnwrap(output.first)).receiptID,
            receipt.receiptID)
        transport.beginFailure = nil
        transport.offset = 2
        transport.integrityProgress = 0
        XCTAssertThrowsError(
            try run(["attachment", "resume", receipt.receiptID], transport, source, output: &output))
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0], transport.requests[1])
        XCTAssertEqual(transport.appendOffsets, [2])
        XCTAssertEqual(transport.appended, [Data("llo".utf8)])
        XCTAssertEqual(try store.load(receipt.receiptID).lastAcknowledgedOffset, 5)
        XCTAssertEqual(transport.finishCalls, 1)
        let beforeData = try JSON.decode(AttachmentUploadReceipt.self, output[1])
        XCTAssertEqual(beforeData.uploadID, transport.upload)
    }
    func testLostFinishReconcilesCommittedReplyWithoutLocalFile() throws {
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        let receipt = try begin(transport, source, output: &output)
        XCTAssertThrowsError(
            try run(["attachment", "resume", receipt.receiptID], transport, source, output: &output))
        transport.committedReplay = true
        transport.statusExpired = true
        source.unavailable = true
        let opens = source.opens
        try run(["attachment", "resume", receipt.receiptID], transport, source, output: &output)
        XCTAssertEqual(source.opens, opens)
        XCTAssertFalse(try store.contains(receipt.receiptID))
        XCTAssertEqual(transport.events.suffix(2), ["status", "begin"])
    }
    func testVerifyingPhaseMakesOneFinishCallWithoutRehashOrPolling() throws {
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        let receipt = try begin(transport, source, output: &output)
        source.unavailable = true
        transport.phase = "verifying"
        transport.offset = 5
        let opens = source.opens
        XCTAssertThrowsError(
            try run(["attachment", "resume", receipt.receiptID], transport, source, output: &output))
        XCTAssertEqual(source.opens, opens)
        XCTAssertEqual(transport.statusCalls, 1)
        XCTAssertEqual(transport.finishCalls, 1)
        XCTAssertTrue(transport.appended.isEmpty)
        XCTAssertTrue(try store.contains(receipt.receiptID))
    }
    func testExpiredAndBetweenStatusBeginRestartRetainSameIntentBeforeData() throws {
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        let receipt = try begin(transport, source, output: &output)
        transport.statusExpired = true
        transport.upload = "55555555-5555-1555-8555-555555555555"
        XCTAssertThrowsError(
            try run(["attachment", "resume", receipt.receiptID], transport, source, output: &output))
        XCTAssertEqual(try store.load(receipt.receiptID).uploadID, transport.upload)
        XCTAssertEqual(try store.load(receipt.receiptID).operationID, "op-stable")
        XCTAssertTrue(transport.requests.allSatisfy { $0 == transport.requests[0] })
        XCTAssertTrue(output.contains { String(decoding: $0, as: UTF8.self).contains("restarted") })
        // A server expiry can also occur after the first status reply.
        transport.upload = "66666666-6666-1666-8666-666666666666"
        transport.offset = 0
        let oldAppends = transport.appended.count
        XCTAssertThrowsError(
            try run(["attachment", "resume", receipt.receiptID], transport, source, output: &output))
        XCTAssertEqual(try store.load(receipt.receiptID).uploadID, transport.upload)
        XCTAssertEqual(transport.appended.count, oldAppends + 1)
    }

    func testNewHandlePersistenceFailureAbortsOnlyNewStageAndKeepsPriorReceipt() throws {
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        let receipt = try begin(transport, source, output: &output)
        let oldUpload = receipt.uploadID
        transport.upload = "77777777-7777-1777-8777-777777777777"
        transport.onBegin = { XCTAssertEqual(chmod(self.store.directory.path, 0o500), 0) }
        XCTAssertThrowsError(
            try run(["attachment", "resume", receipt.receiptID], transport, source, output: &output))
        XCTAssertEqual(transport.abortedUploads, [transport.upload])
        XCTAssertTrue(transport.appended.isEmpty)
        XCTAssertEqual(chmod(store.directory.path, 0o700), 0)
        XCTAssertEqual(try store.load(receipt.receiptID).uploadID, oldUpload)
    }

    func testChangedSourceFailsAfterReconciliationBeforeTransfer() throws {
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        let receipt = try begin(transport, source, output: &output)
        source.data = Data("other".utf8)
        XCTAssertThrowsError(
            try run(["attachment", "resume", receipt.receiptID], transport, source, output: &output))
        XCTAssertEqual(transport.statusCalls, 1)
        XCTAssertTrue(transport.appended.isEmpty)
        XCTAssertTrue(try store.contains(receipt.receiptID))
    }
    func testUnexpectedAckAndConflictRetainExactIntent() throws {
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        let receipt = try begin(transport, source, output: &output)
        transport.badAck = true
        XCTAssertThrowsError(
            try run(["attachment", "resume", receipt.receiptID], transport, source, output: &output))
        XCTAssertEqual(try store.load(receipt.receiptID).lastAcknowledgedOffset, 0)
        transport.badAck = false
        transport.beginFailure = "revisionConflict"
        XCTAssertThrowsError(
            try run(["attachment", "resume", receipt.receiptID], transport, source, output: &output))
        XCTAssertEqual(try store.load(receipt.receiptID).operationID, "op-stable")
        XCTAssertTrue(transport.requests.allSatisfy { $0 == transport.requests[0] })
    }
    func testRevisionConflictCanExplicitlyAbortExistingHandleWithoutBegin() throws {
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        let receipt = try begin(transport, source, output: &output)
        transport.beginFailure = "revisionConflict"
        try run(["attachment", "abort", receipt.receiptID], transport, source, output: &output)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.abortedUploads, [receipt.uploadID!])
        XCTAssertFalse(try store.contains(receipt.receiptID))
    }

    func testChangedDescriptorRejectedBeforeTransfer() throws {
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        let receipt = try begin(transport, source, output: &output)
        transport.badDigest = true
        XCTAssertThrowsError(
            try run(["attachment", "resume", receipt.receiptID], transport, source, output: &output))
        XCTAssertTrue(transport.appended.isEmpty)
    }
    func testStrictArgumentsAndBoundedJobCalls() throws {
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        for args in [
            ["document-job", "page", item], ["document-job", "page", item, "0"],
            ["document-job", "list", "-", "65"],
            ["attachment", "begin", item, revision, "op", "/path", "pdf", "extra"],
        ] {
            XCTAssertThrowsError(try run(args, transport, source, output: &output))
        }
        XCTAssertTrue(transport.documentCalls.isEmpty)
        try run(["document-job", "page", item, "10000000000"], transport, source, output: &output)
        try run(["document-job", "list", "-", "64"], transport, source, output: &output)
        XCTAssertEqual(transport.documentCalls.count, 2)
        XCTAssertEqual(transport.documentCalls[0].0, "TractandaDocumentJob/page")
        XCTAssertEqual(transport.documentCalls[0].1["pageNumber"] as? Int64, 10_000_000_000)
        XCTAssertEqual(transport.documentCalls[1].1["limit"] as? Int, 64)
        XCTAssertEqual(output.count, 2)
    }
    func testReceiptPermissionsEndpointAndBoundedReads() throws {
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        let receipt = try begin(transport, source, output: &output)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
                .first)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?
                .intValue, 0o600)
        let changed = AttachmentReceiptStore(directory: store.directory, endpoint: "/test/two.sock")
        XCTAssertThrowsError(try changed.load(receipt.receiptID))
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try store.load(receipt.receiptID))
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        try write(Data(repeating: 0, count: 16_385), to: file)
        XCTAssertThrowsError(try store.load(receipt.receiptID))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try store.load(receipt.receiptID))
    }
    func testReceiptDirectoryAndFileSymlinksRejected() throws {
        let target = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: target)
        let source = FakeSource()
        let transport = FakeTransport()
        var output: [Data] = []
        XCTAssertThrowsError(try begin(transport, source, output: &output))
        XCTAssertTrue(transport.requests.isEmpty)
        try FileManager.default.removeItem(at: store.directory)
        let receipt = try begin(transport, source, output: &output)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
                .first)
        try FileManager.default.removeItem(at: file)
        let outside = root.appendingPathComponent("outside")
        try write(Data("untouched".utf8), to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try store.load(receipt.receiptID))
        XCTAssertThrowsError(try store.save(receipt))
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
    }
    func testRegularSourceBoundariesZeroAndNonregularFiles() throws {
        let file = root.appendingPathComponent("source")
        try write(Data("hello".utf8), to: file)
        let source = try AttachmentFiles.Source(url: file)
        XCTAssertEqual(source.byteCount, 5)
        XCTAssertEqual(source.sha256, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(try source.chunk(offset: 2, limit: 2), Data("ll".utf8))
        XCTAssertEqual(try source.chunk(offset: 5), Data())
        XCTAssertThrowsError(try source.chunk(offset: -1))
        XCTAssertThrowsError(try source.chunk(offset: Int64.max))
        XCTAssertThrowsError(try source.chunk(offset: 0, limit: 262_145))
        let zero = root.appendingPathComponent("zero")
        try write(Data(), to: zero)
        let empty = try AttachmentFiles.Source(url: zero)
        XCTAssertEqual(empty.byteCount, 0)
        XCTAssertEqual(try empty.chunk(offset: 0), Data())
        let link = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try AttachmentFiles.Source(url: link))
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        // O_NONBLOCK makes this terminate without a writer.
        XCTAssertThrowsError(try AttachmentFiles.Source(url: fifo))
        XCTAssertThrowsError(try AttachmentFiles.Source(url: root))
    }
    func testRetainedSourceRejectsGrowthAndSameSizeMutation() throws {
        let file = root.appendingPathComponent("source")
        try write(Data("hello".utf8), to: file)
        let source = try AttachmentFiles.Source(url: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("!".utf8))
        try handle.close()
        XCTAssertThrowsError(try source.chunk(offset: 0))
        XCTAssertThrowsError(try source.verifyUnchanged())
        try write(Data("hello".utf8), to: file)
        let sameSize = try AttachmentFiles.Source(url: file)
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: Data("j".utf8))
        try writer.close()
        XCTAssertThrowsError(try sameSize.verifyUnchanged())
    }
    func testCancelledTaskRejectsSourceHash() async throws {
        let file = root.appendingPathComponent("cancelled-source")
        try write(Data("hello".utf8), to: file)
        let gate = AsyncStream<Void>.makeStream()
        let work = Task.detached {
            for await _ in gate.stream { break }
            return try AttachmentFiles.Source(url: file).byteCount
        }
        work.cancel()
        gate.continuation.finish()
        do {
            _ = try await work.value
            XCTFail("Cancelled source work must not hash or return a source proof.")
        } catch is CancellationError {}
    }

    func testFixtureCapacityFailsClosedAndCapsAllocations() throws {
        XCTAssertThrowsError(try FixtureCapacity.validate(available: nil, planned: 1))
        XCTAssertThrowsError(
            try FixtureCapacity.validate(available: UInt64.max, planned: 16 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try FixtureCapacity.validate(available: 10 * 1024 * 1024 * 1024, planned: 1))
        try FixtureCapacity.validate(available: UInt64.max, planned: 16 * 1024 * 1024)
    }
    private func write(_ data: Data, to url: URL) throws {
        try FixtureCapacity.require(at: root, planned: Int64(data.count))
        try data.write(to: url)
    }
}

private enum FixtureCapacity {
    static func validate(available: UInt64?, planned: Int64) throws {
        guard planned >= 0, planned <= 16 * 1024 * 1024,
            let available, available >= 10 * 1024 * 1024 * 1024 + UInt64(planned)
        else {
            throw TractandaError(
                "resourceLimit", "CLI fixtures require a genuine 10 GiB reserve and 16 MiB cap.")
        }
    }
    static func require(at directory: URL, planned: Int64) throws {
        var capacity = statvfs()
        guard statvfs(directory.path, &capacity) == 0, capacity.f_frsize > 0 else {
            try validate(available: nil, planned: planned)
            return
        }
        let bytes = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
        try validate(available: bytes.overflow ? nil : bytes.partialValue, planned: planned)
    }
}
private final class FakeSource: AttachmentCommandSource, AttachmentSourceHandle {
    var data = Data("hello".utf8)
    var unavailable = false
    var opens = 0
    func open(path: String) throws -> any AttachmentSourceHandle {
        opens += 1
        if unavailable { throw TractandaError("fileReadFailed", "Original removed") }
        return self
    }
    var proof: AttachmentSourceProof {
        .init(
            byteCount: Int64(data.count),
            sha256: String(repeating: data == Data("other".utf8) ? "b" : "a", count: 64))
    }
    var filename: String { "file.pdf" }
    func chunk(offset: Int64, limit: Int) throws -> Data {
        Data(data[Int(offset)..<min(data.count, Int(offset) + limit)])
    }
    func verifyUnchanged() throws {}
}
private final class FakeTransport: AttachmentCommandTransport {
    var upload = "33333333-3333-1333-8333-333333333333"
    let attachment = "44444444-4444-1444-8444-444444444444"
    var onBegin: (() -> Void)?
    var abortedUploads: [String] = []
    var beginFailure: String?
    var offset: Int64 = 0
    var integrityProgress: Int64 = 0
    var phase = "uploading"
    var committedReplay = false
    var badAck = false
    var badDigest = false
    var requests: [AttachmentUploadRequest] = []
    var appendOffsets: [Int64] = []
    var appended: [Data] = []
    var statusExpired = false
    var statusCalls = 0
    var finishCalls = 0
    var events: [String] = []
    var documentCalls: [(String, [String: Any])] = []
    func beginAttachment(_ request: AttachmentUploadRequest) throws -> AttachmentUploadResult {
        events.append("begin")
        requests.append(request)
        onBegin?()
        if let beginFailure { throw TractandaError(beginFailure, "simulated failure") }
        let descriptor = try AttachmentDescriptor(
            attachmentID: attachment, filename: request.filename,
            mediaType: request.mediaType, byteCount: request.byteCount,
            sha256: badDigest ? String(repeating: "c", count: 64) : request.sha256)
        let committed: AttachmentCommitResult? =
            committedReplay
            ? try JSON.decode(
                AttachmentCommitResult.self,
                JSONSerialization.data(withJSONObject: [
                    "itemID": request.itemID, "revisionID": request.expectedRevisionID,
                    "operationID": request.operationID, "replayed": true, "indexReady": true, "warnings": [],
                ])) : nil
        return AttachmentUploadResult(
            uploadID: upload, attachment: descriptor, offset: offset,
            chunkBytes: AttachmentCommand.chunkBytes, expiresAt: nil, committed: committed)
    }
    func appendAttachment(uploadID: String, offset: Int64, data: Data) throws -> Int64 {
        events.append("append")
        appendOffsets.append(offset)
        appended.append(data)
        self.offset = offset + Int64(data.count)
        return self.offset + (badAck ? 1 : 0)
    }
    func finishAttachmentOnce(uploadID: String) throws -> AttachmentCommitResult {
        events.append("finish")
        finishCalls += 1
        throw TractandaError("attachmentVerifying", "retained for one later explicit resume")
    }
    func attachmentUploadStatus(uploadID: String) throws -> AttachmentIntegrityStatus {
        events.append("status")
        statusCalls += 1
        if statusExpired {
            statusExpired = false
            throw TractandaError("uploadExpired", "simulated completion/expiry")
        }
        return AttachmentIntegrityStatus(
            attachmentID: attachment, uploadID: uploadID,
            phase: phase, verifiedBytes: integrityProgress, totalBytes: 5)
    }
    func abortAttachment(uploadID: String) throws {
        events.append("abort")
        abortedUploads.append(uploadID)
    }
    func documentJobCall(_ method: String, arguments: [String: Any]) throws -> Data {
        documentCalls.append((method, arguments))
        return Data("{\"provisional\":true}".utf8)
    }
}
