import Crypto
import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class DocumentNativeSessionTests: XCTestCase {
    private let configID = String(repeating: "c", count: 64)
    private func fixture(mode: String) throws -> (
        URL, ItemStore, DocumentJobMaterialWork, DocumentConverterConfiguration, DocumentContentFiles
    ) {
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "native-session-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try AttachmentFixtureCapacity.makeStore(root: root.appendingPathComponent("store"))
        let item = try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
        let data = Data([1, 2, 3])
        let upload = try store.beginAttachment(
            AttachmentUploadRequest(
                itemID: item.itemID, expectedRevisionID: item.revisionID,
                operationID: "original", filename: "tiny.pdf", mediaType: "application/pdf", byteCount: 3,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        let uploadID = try XCTUnwrap(upload.uploadID)
        _ = try store.appendAttachment(uploadID: uploadID, offset: 0, data: data)
        let attached = try store.finishAttachment(uploadID: uploadID).revision
        let job = try store.startDocumentJob(
            DocumentJobStart(
                itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                attachmentID: upload.attachment.attachmentID, operationID: "job"), identity: .init(),
            configurationSHA256: configID)
        let claim = try store.claimDocumentJob(job.jobID, configurationSHA256: configID)
        let work = try store.documentJobMaterialWork(
            job.jobID, generation: claim.checkpoint.generation, configurationSHA256: configID)
        let executable = root.appendingPathComponent("fake-worker.py")
        let script = """
            #!/usr/bin/python3
            import sys,json,time
            binding=json.load(open(sys.argv[5]))
            def emit(value):
                result=dict(binding);result.update(value)
                print(json.dumps(result,separators=(',',':')),flush=True)
            emit({'type':'hello','pageCount':129,'modelLoaded':False,'modelForwardCalls':0})
            open('\(root.appendingPathComponent("worker-pid").path)','w').write(str(__import__('os').getpid()))
            loaded=False
            for line in sys.stdin:
                request=json.loads(line)
                if request['method']=='close':
                    emit({'type':'closed','requestID':request['requestID']});break
                base={'requestID':request['requestID'],'pageNumber':request['pageNumber']}
                if '\(mode)'=='reported-timeout':
                    emit({'type':'error','failureCode':'documentTimeout'});continue
                if '\(mode)'=='load-timeout':
                    emit(dict(base,type='progress',phase='modelLoad',completed=0,total=0));time.sleep(10)
                if not loaded:
                    emit(dict(base,type='progress',phase='modelReady',completed=0,total=0));loaded=True
                emit(dict(base,type='progress',phase='render',completed=0,total=0))
                if '\(mode)'=='page-timeout':time.sleep(10)
                if '\(mode)'=='failed':
                    emit(dict(base,type='page',status='failed',failureCode='nativePageFailed'));raise SystemExit(1)
                emit(dict(base,type='page',status='unsupported',failureCode='unsupportedDocumentInput'))
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = root.appendingPathComponent("empty-model")
        let scratch = root.appendingPathComponent("scratch")
        for path in [model, scratch] {
            try FileManager.default.createDirectory(
                at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let configuration = DocumentConverterConfiguration(
            executablePath: executable.path, modelDirectory: model.path, scratchDirectory: scratch.path)
        let files = DocumentContentFiles(
            root: store.root, ownerUID: store.ownerUID,
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        return (root, store, work, configuration, files)
    }
    private func session(
        _ fixture: (
            URL, ItemStore, DocumentJobMaterialWork, DocumentConverterConfiguration, DocumentContentFiles
        ), budgets: DocumentWorkerBudgets? = nil
    ) throws -> DocumentNativeSession {
        let original = try fixture.2.verifyOriginal(cancellation: .init())
        return try DocumentNativeSession(
            intent: fixture.2.intent, original: original, configuration: fixture.3,
            expectedExecutableSHA256: DocumentProcess.executableSHA256(fixture.3.executablePath),
            files: fixture.4,
            root: fixture.1.root, budgets: budgets ?? DocumentWorkerBudgets(), cancellation: .init())
    }
    func test129PageInspectionAndSequentialOutcomesUseOneLazyContext() throws {
        let fixture = try fixture(mode: "normal")
        defer { try? FileManager.default.removeItem(at: fixture.0) }
        let session = try session(fixture)
        XCTAssertEqual(session.pageCount, 129)
        for number in 1...129 { XCTAssertEqual(try session.convert(Int64(number)).status, "unsupported") }
        XCTAssertFalse(session.ended)
        try session.close()
        XCTAssertTrue(session.ended)
    }
    func testFailedTerminalRequiresEndedContextAndFreshSession() throws {
        let fixture = try fixture(mode: "failed")
        defer { try? FileManager.default.removeItem(at: fixture.0) }
        let failed = try session(fixture)
        XCTAssertEqual(try failed.convert(1).status, "failed")
        XCTAssertTrue(failed.ended)
        XCTAssertThrowsError(try failed.convert(2))
        let fresh = try session(fixture)
        XCTAssertEqual(try fresh.convert(2).pageNumber, 2)
        XCTAssertTrue(fresh.ended)
    }
    func testTimeoutBeforeModelReadyIsDistinctFromPageSpecificTimeout() throws {
        for (mode, expectedStarted) in [("load-timeout", false), ("page-timeout", true)] {
            let fixture = try fixture(mode: mode)
            defer { try? FileManager.default.removeItem(at: fixture.0) }
            let session = try session(
                fixture,
                budgets: DocumentWorkerBudgets(
                    inspect: 5, modelLoad: 0.05,
                    page: 0.05, noProgress: 1, terminationGrace: 0.02))
            XCTAssertThrowsError(try session.convert(1)) {
                let failure = $0 as? DocumentNativeSessionFailure
                XCTAssertEqual(failure?.failure.code, "documentTimeout")
                XCTAssertEqual(failure?.pageStarted, expectedStarted)
                XCTAssertEqual(failure?.requestedPage, 1)
                let phase = expectedStarted ? "render" : "modelLoad"
                let kind = expectedStarted ? "page" : "modelLoad"
                XCTAssertTrue(failure?.failure.message.contains("phase=\(phase); timeout=\(kind)") == true)
                XCTAssertTrue(failure?.failure.message.contains("budgetSeconds=0.05;") == true)
                let pidText = try! String(
                    contentsOf: fixture.0.appendingPathComponent("worker-pid"), encoding: .utf8)
                let pid = Int32(pidText)!
                var status: Int32 = 0
                XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
                XCTAssertEqual(errno, ECHILD, "Session must have reaped the failed worker")
            }
            XCTAssertTrue(session.ended)
            XCTAssertEqual(try fixture.1.documentJobStatus(fixture.2.intent.jobID).acceptedPages, 0)
        }
    }
    func testReportedTimeoutAndCallbackCrossingDeadlineDoNotBecomeWatchdogDiagnostics() throws {
        for mode in ["reported-timeout", "normal"] {
            let fixture = try fixture(mode: mode)
            defer { try? FileManager.default.removeItem(at: fixture.0) }
            let session = try session(
                fixture,
                budgets: DocumentWorkerBudgets(
                    inspect: 5, modelLoad: 5, page: 0.005, noProgress: 1, terminationGrace: 0.02))
            var crossedDeadline = false
            XCTAssertThrowsError(
                try session.convert(1) { _, _, _ in
                    // The modelReady phase/page deadline is already set before this callback.
                    // Wait on a tiny monotonic gate guaranteed later than that deadline.
                    let gate = ContinuousClock.now.advanced(by: .milliseconds(10))
                    while ContinuousClock.now < gate { Thread.sleep(forTimeInterval: 0.001) }
                    crossedDeadline = true
                    throw TractandaError("documentTimeout", "Callback reported timeout.")
                }
            ) {
                let failure = $0 as? DocumentNativeSessionFailure
                XCTAssertEqual(failure?.failure.code, "documentTimeout")
                XCTAssertNil(failure?.timeoutMessage)
                XCTAssertEqual(
                    failure?.failure.message,
                    mode == "normal" ? "Callback reported timeout." : "Native worker invalidated its session."
                )
            }
            XCTAssertEqual(crossedDeadline, mode == "normal")
            XCTAssertTrue(session.ended)
        }
    }
    func testSessionQuotaReleaseDoesNotReleaseCheckpointBytes() throws {
        let fixture = try fixture(mode: "normal")
        defer { try? FileManager.default.removeItem(at: fixture.0) }
        let baseline = try StagingByteQuota(
            root: fixture.1.root, ownerUID: fixture.1.ownerUID, maximumBytes: .max
        ).usedBytes
        let quota = try StagingByteQuota(
            root: fixture.1.root, ownerUID: fixture.1.ownerUID, maximumBytes: .max)
        let files = DocumentContentFiles(
            root: fixture.1.root, ownerUID: fixture.1.ownerUID,
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes, stagingQuota: quota)
        do {
            let original = try fixture.2.verifyOriginal(cancellation: .init())
            let current = try DocumentNativeSession(
                intent: fixture.2.intent, original: original, configuration: fixture.3,
                expectedExecutableSHA256: DocumentProcess.executableSHA256(fixture.3.executablePath),
                files: files,
                root: fixture.1.root, budgets: DocumentWorkerBudgets(), cancellation: .init())
            XCTAssertGreaterThan(quota.usedBytes, baseline)
            try current.close()
        }
        XCTAssertEqual(quota.usedBytes, baseline)
        XCTAssertEqual(try fixture.1.documentJobStatus(fixture.2.intent.jobID).state, "verifyingOriginal")
    }
}
