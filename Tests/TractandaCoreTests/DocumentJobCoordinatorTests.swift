import Crypto
import Foundation
import TractandaClient
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class DocumentJobCoordinatorTests: XCTestCase {
    private struct Transport: TractandaClient.ItemTransport {
        let coordinator: ServiceCoordinator
        var uid: UInt32 = UInt32(getuid())
        func send(_ request: Data) async throws -> Data {
            try await coordinator.handle(request, forUID: uid)
        }
    }
    private struct Fixture {
        let root: URL
        let store: URL
        let configuration: DocumentConverterConfiguration
        let request: DocumentJobStart
    }
    private func capacity(_ root: URL) throws {
        var status = statvfs()
        guard statvfs(root.path, &status) == 0, status.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot inspect genuine fixture capacity.")
        }
        let available = UInt64(status.f_bavail).multipliedReportingOverflow(by: UInt64(status.f_frsize))
        let cap: UInt64 = 16 * 1024 * 1024
        guard !available.overflow, available.partialValue >= 10 * 1024 * 1024 * 1024 + cap else {
            throw TractandaError("resourceLimit", "Fixture requires genuine 10 GiB reserve plus 16 MiB cap.")
        }
        guard root.lastPathComponent.hasPrefix("job-coordinator-") else { return }
        var bytes: UInt64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        {
            for case let url as URL in enumerator {
                let value = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if value.isRegularFile == true { bytes += UInt64(value.fileSize ?? 0) }
                guard bytes <= cap else {
                    throw TractandaError("resourceLimit", "Fixture exceeded 16 MiB cap.")
                }
            }
        }
    }
    private func fixture(delay: Double = 0, pages: Int = 129, heldPage: Int? = nil) throws -> Fixture {
        try capacity(FileManager.default.temporaryDirectory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "job-coordinator-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let storeURL = root.appendingPathComponent("store")
        let request: DocumentJobStart = try {
            let store = try ItemStore(root: storeURL)
            try store.setAttachmentReserveForTesting(10 * 1024 * 1024 * 1024)
            let item = try store.commit(CommitRequest(classID: "Item", operationID: "item")).revision
            let bytes = Data([1, 2, 3])
            let upload = try store.beginAttachment(
                AttachmentUploadRequest(
                    itemID: item.itemID,
                    expectedRevisionID: item.revisionID, operationID: "original", filename: "tiny.pdf",
                    mediaType: "application/pdf", byteCount: 3, sha256: PageCorpusInput.digest(bytes)))
            let id = try XCTUnwrap(upload.uploadID)
            _ = try store.appendAttachment(uploadID: id, offset: 0, data: bytes)
            let attached = try store.finishAttachment(uploadID: id).revision
            return DocumentJobStart(
                itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                attachmentID: upload.attachment.attachmentID, operationID: "document-job")
        }()
        let executable = root.appendingPathComponent("worker.py")
        let script = """
            #!/usr/bin/python3
            import sys,json,time,pathlib
            binding=json.load(open(sys.argv[5]))
            def emit(value):
                result=dict(binding);result.update(value)
                print(json.dumps(result,separators=(',',':')),flush=True)
            emit({'type':'hello','pageCount':\(pages),'modelLoaded':False,'modelForwardCalls':0})
            open(\(String(reflecting: root.appendingPathComponent("worker-pid").path)), 'w').write(str(__import__('os').getpid()))
            loaded=False
            for line in sys.stdin:
                request=json.loads(line)
                if request['method']=='close':
                    emit({'type':'closed','requestID':request['requestID']});break
                with open(\(String(reflecting: root.appendingPathComponent("page-calls").path)), 'a') as calls:
                    calls.write(str(request['pageNumber'])+'\\n')
                base={'requestID':request['requestID'],'pageNumber':request['pageNumber']}
                if not loaded:
                    emit(dict(base,type='progress',phase='modelReady',completed=0,total=0));loaded=True
                emit(dict(base,type='progress',phase='render',completed=0,total=0))
                if request['pageNumber']==\(heldPage ?? -1):
                    pathlib.Path(\(String(reflecting: root.appendingPathComponent("held-page").path))).write_text(str(request['pageNumber']))
                    deadline=time.monotonic()+8
                    while not pathlib.Path(\(String(reflecting: root.appendingPathComponent("release-page").path))).exists():
                        if time.monotonic()>deadline: raise RuntimeError('bounded held-page deadline')
                        time.sleep(0.01)
                time.sleep(\(delay))
                emit(dict(base,type='page',status='unsupported',failureCode='unsupportedDocumentInput'))
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = root.appendingPathComponent("empty-model")
        try FileManager.default.createDirectory(
            at: model, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration = DocumentConverterConfiguration(
            executablePath: executable.path,
            modelDirectory: model.path, scratchDirectory: root.appendingPathComponent("scratch").path)
        try capacity(root)
        return Fixture(root: root, store: storeURL, configuration: configuration, request: request)
    }
    private func client(_ coordinator: ServiceCoordinator, uid: UInt32 = UInt32(getuid()))
        -> TractandaClient.ItemClient
    {
        TractandaClient.ItemClient(transport: Transport(coordinator: coordinator, uid: uid))
    }
    private func wait(
        _ client: TractandaClient.ItemClient, id: String, root: URL,
        until predicate: (DocumentJobStatus) -> Bool
    ) async throws -> DocumentJobStatus {
        var last: DocumentJobStatus?
        for _ in 0..<600 {
            try capacity(root)
            let status = try await client.documentJob(id)
            last = status
            if predicate(status) { return status }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TractandaError(
            "testTimeout",
            "Bounded fake-worker completion was not observed: \(last?.state ?? "unknown")/\(last?.reasonCode ?? "none") pages=\(last?.acceptedPages ?? -1)."
        )
    }
    func testPartialIndexImportRestartReusesSavedPagesWithoutConverterReplay() async throws {
        // Three outcomes + all store/index/spool copies are estimated below2MiB under16MiB.
        let fixture = try fixture(pages: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        await first.setDocumentJobIndexHookForTesting { batch in
            if batch.phase == .afterCommit {
                throw TractandaError("indexProjectionPending", "Stopped after durable partial import")
            }
        }
        let admitted = try await client(first).startDocumentJob(fixture.request)
        let paused = try await wait(client(first), id: admitted.jobID, root: fixture.root) {
            $0.state == "paused"
        }
        XCTAssertEqual(paused.acceptedPages, 3)
        await first.close()
        let calls = try String(contentsOf: fixture.root.appendingPathComponent("page-calls"), encoding: .utf8)
        let second = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        let completed = try await wait(client(second), id: admitted.jobID, root: fixture.root) {
            $0.state == "completed"
        }
        XCTAssertTrue(completed.committed?.isIndexReady == true)
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appendingPathComponent("page-calls"), encoding: .utf8), calls)
        await second.close()
        try capacity(fixture.root)
    }
    func testPartialIndexRebaseRefreshesFieldsAndDiscardCleansDurableDebt() async throws {
        let fixture = try fixture(pages: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        await first.setDocumentJobIndexHookForTesting { batch in
            if batch.phase == .afterCommit { throw TractandaError("testPaused", "Retained partial index") }
        }
        let admitted = try await client(first).startDocumentJob(fixture.request)
        _ = try await wait(client(first), id: admitted.jobID, root: fixture.root) { $0.state == "paused" }
        await first.close()
        let calls = try String(contentsOf: fixture.root.appendingPathComponent("page-calls"), encoding: .utf8)
        let changedID: String
        do {
            let store = try ItemStore(root: fixture.store)
            let changed = try store.commit(
                CommitRequest(
                    action: .revise, itemID: fixture.request.itemID,
                    expectedRevisionID: fixture.request.expectedRevisionID,
                    changes: ["subject": .text("fresh rebase field")], operationID: "rebase-field")
            ).revision
            changedID = changed.revisionID
            let runtime = try XCTUnwrap(
                ItemService(store: store, documentConverter: fixture.configuration).documentJobRuntime())
            _ = try store.controlDocumentJob(
                admitted.jobID, action: "rebase", expectedRevisionID: changedID,
                configurationSHA256: runtime.configurationSHA256, deferMaterialWork: true)
        }
        let second = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        let done = try await wait(client(second), id: admitted.jobID, root: fixture.root) {
            $0.state == "completed"
        }
        XCTAssertEqual(done.sourceRevisionID, fixture.request.expectedRevisionID)
        XCTAssertEqual(done.expectedRevisionID, changedID)
        await second.close()
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appendingPathComponent("page-calls"), encoding: .utf8), calls)
        do {
            let store = try ItemStore(root: fixture.store)
            let saved = try store.get(fixture.request.itemID)
            XCTAssertEqual(saved.fields["subject"], .text("fresh rebase field"))
            XCTAssertEqual(
                try AttachmentDocumentRepresentation.representations(in: saved.fields).first?.source
                    .revisionID,
                fixture.request.expectedRevisionID)
        }
        try capacity(fixture.root)
    }
    func testPartialIndexDiscardRetiresBeforeArchivedPhysicalDisposal() async throws {
        let fixture = try fixture(pages: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        await first.setDocumentJobIndexHookForTesting { batch in
            if batch.phase == .afterCommit { throw TractandaError("testPaused", "Retained partial index") }
        }
        let admitted = try await client(first).startDocumentJob(fixture.request)
        _ = try await wait(client(first), id: admitted.jobID, root: fixture.root) { $0.state == "paused" }
        _ = try await client(first).discardDocumentJob(admitted.jobID)
        await first.close()
        let second = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        await second.close()
        let store = try ItemStore(root: fixture.store)
        XCTAssertTrue(try store.documentJobStatus(admitted.jobID).discarded)
        let index = try ItemIndex(
            path: store.indexDirectory.appendingPathComponent("items.sqlite").path, create: false)
        XCTAssertEqual(try index.corpusRetainedBytes(admitted.jobID), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.store.appendingPathComponent("document-jobs/" + admitted.jobID).path))
        try capacity(fixture.root)
    }
    func testActualRouter129PagesCompleteOnlyAfterIndexPromotion() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        let gate = AdmissionGate()
        await coordinator.setDocumentJobPublicationHookForTesting { await gate.pause() }
        let client = client(coordinator)
        let admitted = try await client.startDocumentJob(fixture.request)
        try await waitForGate(gate, maximumAttempts: 1200)
        let status = try await client.documentJob(admitted.jobID)
        XCTAssertEqual(status.acceptedPages, 129)
        XCTAssertEqual(status.coverage.unsupported, 129)
        XCTAssertNil(status.committed)
        let page = try await client.documentJobPage(status.jobID, pageNumber: 129)
        XCTAssertTrue(page.provisional)
        XCTAssertEqual(page.outcome.pageNumber, 129)
        await coordinator.setDocumentJobPublicationHookForTesting(nil)
        await gate.release()
        let completed = try await wait(client, id: admitted.jobID, root: fixture.root) {
            $0.state == "completed"
        }
        XCTAssertTrue(completed.committed?.isIndexReady == true)
        let canonical = try await client.attachmentDocument(
            itemID: fixture.request.itemID,
            attachmentID: fixture.request.attachmentID, pageNumber: 129)
        XCTAssertEqual(canonical.outcomes?.first?.pageNumber, 129)
        let replay = try await client.startDocumentJob(fixture.request)
        XCTAssertEqual(replay.jobID, admitted.jobID)
        await coordinator.close()
        try capacity(fixture.root)
    }
    func testQueuedJobKeepsReadsAndExactAdmissionReplayAvailable() async throws {
        let fixture = try fixture(pages: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        let gate = AdmissionGate()
        await coordinator.setDocumentJobAdmissionHookForTesting { await gate.pause() }
        let client = client(coordinator)
        let admitted = try await client.startDocumentJob(fixture.request)
        try await waitForGate(gate)
        let info = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": [["TractandaStore/info", [:], "read"]],
        ])
        let response = try await coordinator.handle(info, forUID: getuid())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertNil(root["code"])
        XCTAssertNotNil(root["methodResponses"])
        let replay = try await client.startDocumentJob(fixture.request)
        XCTAssertEqual(replay.jobID, admitted.jobID)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("worker-pid").path))
        await coordinator.setDocumentJobAdmissionHookForTesting(nil)
        await gate.release()
        let completed = try await wait(client, id: admitted.jobID, root: fixture.root) {
            $0.state == "completed"
        }
        XCTAssertEqual(completed.acceptedPages, 3)
        let calls = try String(contentsOf: fixture.root.appendingPathComponent("page-calls"), encoding: .utf8)
        XCTAssertEqual(calls.split(separator: "\n"), ["1", "2", "3"])
        await coordinator.close()
    }

    func testRetainedJobsAccessibleWithoutConfiguredConverter() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id: String = try {
            let store = try ItemStore(root: fixture.store)
            let runtime = try XCTUnwrap(
                ItemService(store: store, documentConverter: fixture.configuration).documentJobRuntime())
            return try store.startDocumentJob(
                fixture.request, identity: .init(), configurationSHA256: runtime.configurationSHA256
            ).jobID
        }()
        let coordinator = try await ServiceCoordinator(opening: fixture.store)
        let client = client(coordinator)
        let retained = try await client.documentJob(id)
        let listed = try await client.documentJobs()
        XCTAssertEqual(retained.jobID, id)
        XCTAssertEqual(listed.jobs.count, 1)
        do {
            _ = try await client.resumeDocumentJob(id)
            XCTFail("Unconfigured producer must not resume")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "documentConverterUnavailable") }
        let cancelled = try await client.cancelDocumentJob(id)
        let discarded = try await client.discardDocumentJob(id)
        XCTAssertEqual(cancelled.state, "cancelled")
        XCTAssertTrue(discarded.discarded)
        for _ in 0..<100 {
            if try await client.documentJobs().jobs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let afterDisposal = try await client.documentJobs()
        XCTAssertTrue(afterDisposal.jobs.isEmpty)
        await coordinator.close()
    }
    func testCloseDrainsProducerAndStartupResumesAcknowledgedFrontier() async throws {
        let fixture = try fixture(delay: 0.002)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        let admitted = try await client(first).startDocumentJob(fixture.request)
        _ = try await wait(client(first), id: admitted.jobID, root: fixture.root) { $0.acceptedPages >= 2 }
        await first.close()
        let paused: DocumentJobStatus = try {
            let store = try ItemStore(root: fixture.store)
            return try store.documentJobStatus(admitted.jobID)
        }()
        XCTAssertEqual(paused.state, "paused")
        XCTAssertEqual(paused.reasonCode, "serverShutdown")
        let second = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        let resumed = try await wait(client(second), id: admitted.jobID, root: fixture.root) {
            $0.state == "completed"
        }
        XCTAssertEqual(resumed.acceptedPages, 129)
        XCTAssertGreaterThanOrEqual(resumed.acceptedPages, paused.acceptedPages)
        await second.close()
    }
    func testOutstandingPageTimeoutIsDurableAndDistinctFromCancellation() async throws {
        let fixture = try fixture(delay: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resources = DocumentJobResources(
            inspectSeconds: 5, modelLoadSeconds: 5,
            pageSeconds: 0.05, noProgressSeconds: 1, terminationGraceSeconds: 0.05)
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store,
            documentConverter: fixture.configuration, documentJobResources: resources)
        let client = client(coordinator)
        let admitted = try await client.startDocumentJob(fixture.request)
        let paused = try await wait(client, id: admitted.jobID, root: fixture.root) { $0.state == "paused" }
        XCTAssertEqual(paused.reasonCode, "documentTimeout")
        XCTAssertTrue(
            paused.reasonMessage?.contains("phase=render; timeout=page; budgetSeconds=0.05;") == true)
        let pidText = try String(
            contentsOf: fixture.root.appendingPathComponent("worker-pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        XCTAssertEqual(paused.acceptedPages, 1)
        XCTAssertEqual(paused.coverage.timedOut, 1)
        let page = try await client.documentJobPage(paused.jobID, pageNumber: 1)
        XCTAssertEqual(page.outcome.status, "timeout")
        await coordinator.close()
        let reopened = try ItemStore(root: fixture.store)
        let persisted = try reopened.documentJobStatus(paused.jobID)
        XCTAssertEqual(persisted.reasonMessage, paused.reasonMessage)
        let recordPath = fixture.store.appendingPathComponent("document-jobs/\(paused.jobID)/record.json")
        XCTAssertLessThanOrEqual(try Data(contentsOf: recordPath).count, 16 * 1024)
        let cancelled = try reopened.controlDocumentJob(
            paused.jobID, action: "cancel", configurationSHA256: "unused")
        XCTAssertNil(cancelled.reasonMessage)
    }
    func testRebuildFencesAndJoinsProducerBeforeIndexMaintenance() async throws {
        struct Start: Encodable, Sendable { let operationID: String }
        struct Job: Encodable, Sendable { let jobID: String }
        let fixture = try fixture(pages: 3, heldPage: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        let client = client(coordinator)
        let admitted = try await client.startDocumentJob(fixture.request)
        let active = try await wait(client, id: admitted.jobID, root: fixture.root) {
            $0.acceptedPages == 1 && $0.state == "running"
        }
        XCTAssertNil(active.committed)
        let held = fixture.root.appendingPathComponent("held-page")
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: held.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try String(contentsOf: held, encoding: .utf8), "2")
        let pidText = try String(
            contentsOf: fixture.root.appendingPathComponent("worker-pid"), encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(kill(pid, 0), 0, "The held-page producer must be alive before rebuild admission")
        let gate = AdmissionGate()
        await coordinator.setRebuildAdmissionHookForTesting { await gate.pause() }
        let started = Task {
            try await client.call(
                "TractandaStore/rebuild", arguments: Start(operationID: "rebuild"),
                returning: StoreRebuildStatus.self)
        }
        try await waitForGate(gate)
        // Hold the exact admission-to-perform window until the original producer has joined.
        await coordinator.waitForDocumentProducerForTesting()
        var childStatus: Int32 = 0
        XCTAssertEqual(waitpid(pid, &childStatus, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        let record = fixture.store.appendingPathComponent("document-jobs/\(admitted.jobID)/record.json")
        let bytes = try Data(contentsOf: record)
        let persisted = try JSONDecoder().decode(DocumentJobRecord.self, from: bytes)
        XCTAssertEqual(persisted.checkpoint.acceptedPages, 1)
        XCTAssertNotEqual(persisted.checkpoint.state, "completed")
        XCTAssertFalse(
            String(decoding: bytes, as: UTF8.self).contains("serviceBusy"),
            "Admission fencing must retain the lifecycle-resumable checkpoint")
        try Data().write(to: fixture.root.appendingPathComponent("release-page"))
        await coordinator.setRebuildAdmissionHookForTesting(nil)
        await gate.release()
        var rebuild = try await started.value
        for _ in 0..<600 {
            try capacity(fixture.root)
            if rebuild.isTerminal { break }
            try await Task.sleep(for: .milliseconds(20))
            rebuild = try await client.call(
                "TractandaStore/rebuildStatus", arguments: Job(jobID: rebuild.jobID),
                returning: StoreRebuildStatus.self)
        }
        XCTAssertEqual(rebuild.state, "completed")
        XCTAssertTrue(rebuild.indexTrusted)
        let resumed = try await wait(client, id: admitted.jobID, root: fixture.root) {
            $0.state == "completed"
        }
        XCTAssertEqual(resumed.acceptedPages, 3)
        await coordinator.close()
        let reopened = try ItemStore(root: fixture.store)
        XCTAssertEqual(try reopened.documentJobStatus(admitted.jobID).state, "completed")
        XCTAssertEqual(try reopened.documentJobStatus(admitted.jobID).acceptedPages, 3)
    }

    private actor AdmissionGate {
        private var arrivals = 0
        private var waiter: CheckedContinuation<Void, Never>?
        func pause() async {
            arrivals += 1
            await withCheckedContinuation { waiter = $0 }
        }
        func count() -> Int { arrivals }
        func release() {
            waiter?.resume()
            waiter = nil
        }
    }
    private func waitForGate(_ gate: AdmissionGate, maximumAttempts: Int = 100) async throws {
        for _ in 0..<maximumAttempts {
            if await gate.count() > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TractandaError("testTimeout", "Queued admission gate was not reached.")
    }
    func testChangedOriginalBeforeClaimPausesRatherThanStrandingQueuedJob() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        let gate = AdmissionGate()
        await coordinator.setDocumentJobAdmissionHookForTesting { await gate.pause() }
        let client = client(coordinator)
        let admitted = try await client.startDocumentJob(fixture.request)
        try await waitForGate(gate)
        _ = try await client.detachAttachment(
            itemID: fixture.request.itemID,
            expectedRevisionID: fixture.request.expectedRevisionID,
            attachmentID: fixture.request.attachmentID, operationID: "detach-before-claim")
        await coordinator.setDocumentJobAdmissionHookForTesting(nil)
        await gate.release()
        let paused = try await wait(client, id: admitted.jobID, root: fixture.root) { $0.state == "paused" }
        XCTAssertEqual(paused.reasonCode, "documentOriginalChanged")
        XCTAssertEqual(paused.acceptedPages, 0)
        XCTAssertNil(paused.pageCount)
        await coordinator.close()
    }
    func testStaleQueuedAdmissionCannotStopExplicitResume() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration)
        let gate = AdmissionGate()
        await coordinator.setDocumentJobAdmissionHookForTesting { await gate.pause() }
        let client = client(coordinator)
        let admitted = try await client.startDocumentJob(fixture.request)
        try await waitForGate(gate)
        _ = try await client.cancelDocumentJob(admitted.jobID)
        let resumed = try await client.resumeDocumentJob(admitted.jobID)
        XCTAssertEqual(resumed.state, "queued")
        await coordinator.setDocumentJobAdmissionHookForTesting(nil)
        await gate.release()
        let ready = try await wait(client, id: admitted.jobID, root: fixture.root) {
            $0.state == "completed"
        }
        XCTAssertEqual(ready.acceptedPages, 129)
        await coordinator.close()
    }

    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 61313
        private let lock = NSLock()
        private var deleted = false
        private var admitted = true
        func revokeGroup() {
            lock.lock()
            admitted = false
            lock.unlock()
        }
        func removeAlice() {
            lock.lock()
            deleted = true
            lock.unlock()
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            lock.lock()
            let removed = deleted
            let groups: Set<UInt32> = uid != alice || admitted ? [71313] : []
            lock.unlock()
            guard uid == getuid() || (uid == alice && !removed) else {
                throw TractandaError("unresolvedPrincipal", "Fixture account disappeared.")
            }
            return AccountIdentity(
                uid: uid, name: uid == alice ? "alice" : "admin",
                primaryGroupName: "staff", groupIDs: groups)
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "alice" || name == "admin" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture account.")
            }
            return try user(forUID: name == "alice" ? alice : getuid())
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group.")
            }
            return 71313
        }
    }
    func testFreshGroupRevocationPreventsOffQueueJobPublication() async throws {
        let fixture = try fixture(pages: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let accounts = Accounts()
        let request: DocumentJobStart = try {
            let store = try ItemStore(root: fixture.store, accounts: accounts)
            _ = try store.configureAccess(
                .object(["profile": .text(AccessConfiguration.profile), "groups": .list([.text("staff")])]),
                operationID: "access")
            let shared = try store.commit(
                CommitRequest(
                    action: .revise, itemID: fixture.request.itemID,
                    expectedRevisionID: fixture.request.expectedRevisionID,
                    changes: [
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                            "group": .text("staff"), "mode": .integer(0o660), "acl": .object([:]),
                        ])
                    ], operationID: "share")
            ).revision
            return DocumentJobStart(
                itemID: shared.itemID, expectedRevisionID: shared.revisionID,
                attachmentID: fixture.request.attachmentID, operationID: "fresh-group")
        }()
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: fixture.configuration,
            makeAccountDirectory: { accounts })
        let gate = AdmissionGate()
        await coordinator.setDocumentJobPublicationHookForTesting { await gate.pause() }
        let alice = client(coordinator, uid: accounts.alice)
        let admin = client(coordinator)
        let admitted = try await alice.startDocumentJob(request)
        try await waitForGate(gate)
        accounts.revokeGroup()
        await coordinator.setDocumentJobPublicationHookForTesting(nil)
        await gate.release()
        let paused = try await wait(admin, id: admitted.jobID, root: fixture.root) { $0.state == "paused" }
        XCTAssertEqual(paused.reasonCode, "forbidden")
        XCTAssertNil(paused.committed)
        do {
            _ = try await alice.documentJob(admitted.jobID)
            XCTFail("Revoked account must not read retained job status")
        } catch {
            XCTAssertEqual((error as? TractandaClient.TractandaError)?.code, "forbidden")
        }
        await coordinator.close()
        let store = try ItemStore(root: fixture.store, accounts: accounts)
        XCTAssertNil(try store.get(request.itemID).fields["attachmentDocument"])
        XCTAssertEqual(try store.get(request.itemID).revisionID, request.expectedRevisionID)
    }

    func testQueuedDiscardAndRunningFailureFinishAfterOriginalAccountRemoval() async throws {
        let fixture = try fixture(delay: 0.05)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let accounts = Accounts()
        let request: DocumentJobStart = try {
            let store = try ItemStore(root: fixture.store, accounts: accounts)
            _ = try store.configureAccess(
                .object([
                    "profile": .text(AccessConfiguration.profile),
                    "groups": .list([.text("staff")]),
                ]), operationID: "access")
            let shared = try store.commit(
                CommitRequest(
                    action: .revise, itemID: fixture.request.itemID,
                    expectedRevisionID: fixture.request.expectedRevisionID,
                    changes: [
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile),
                            "owner": .text("admin"), "group": .text("staff"),
                            "mode": .integer(0o660), "acl": .object([:]),
                        ])
                    ], operationID: "share")
            ).revision
            return DocumentJobStart(
                itemID: shared.itemID, expectedRevisionID: shared.revisionID,
                attachmentID: fixture.request.attachmentID, operationID: "active-A")
        }()
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store,
            documentConverter: fixture.configuration, makeAccountDirectory: { accounts })
        let alice = client(coordinator, uid: accounts.alice)
        let admin = client(coordinator)
        let active = try await alice.startDocumentJob(request)
        _ = try await wait(admin, id: active.jobID, root: fixture.root) { $0.acceptedPages >= 1 }
        let queued = try await alice.startDocumentJob(
            DocumentJobStart(
                itemID: request.itemID,
                expectedRevisionID: request.expectedRevisionID, attachmentID: request.attachmentID,
                operationID: "queued-B"))
        let discarded = try await alice.discardDocumentJob(queued.jobID)
        XCTAssertTrue(discarded.discarded)
        accounts.removeAlice()
        let paused = try await wait(admin, id: active.jobID, root: fixture.root) { $0.state == "paused" }
        XCTAssertEqual(paused.reasonCode, "unresolvedPrincipal")
        XCTAssertLessThan(paused.acceptedPages, 129)
        let history = fixture.store.appendingPathComponent("document-job-history")
            .appendingPathComponent(String(queued.jobID.prefix(2))).appendingPathComponent(
                queued.jobID + ".json")
        for _ in 0..<200 {
            try capacity(fixture.root)
            if FileManager.default.fileExists(atPath: history.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.store
                    .appendingPathComponent("document-jobs").appendingPathComponent(queued.jobID).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.store
                    .appendingPathComponent("documents/.staging").appendingPathComponent(queued.jobID).path))
        await coordinator.close()
    }

}
