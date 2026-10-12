import Foundation
import MCP
import XCTest

@testable import TractandaCore
@testable import TractandaMCP

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class DocumentJobIntegrationTests: XCTestCase {
    private actor PublicationGate {
        private var arrivals = 0
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func pause() async {
            arrivals += 1
            guard !released else { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func arrived() -> Bool { arrivals > 0 }
        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }

    private struct Fixture {
        let root: URL
        let store: URL
        let converter: DocumentConverterConfiguration
        let itemID: String
        let revisionID: String
        let attachmentID: String
        let accounts: E2EAccounts
        let operationID = "mcp-document-job"
    }

    private final class E2EAccounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 80_001
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            switch uid {
            case UInt32(getuid()):
                return AccountIdentity(uid: uid, name: "admin", primaryGroupName: "staff", groupIDs: [80_003])
            case alice:
                return AccountIdentity(uid: uid, name: "alice", primaryGroupName: "staff", groupIDs: [80_003])
            default:
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user.")
            }
        }
        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": return try user(forUID: UInt32(getuid()))
            case "alice": return try user(forUID: alice)
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture user.")
            }
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group.")
            }
            return 80_003
        }
    }

    private func checkCapacity(at url: URL) throws {
        var values = statvfs()
        guard statvfs(url.path, &values) == 0, values.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot inspect genuine fixture capacity.")
        }
        let free = UInt64(values.f_bavail).multipliedReportingOverflow(by: UInt64(values.f_frsize))
        let cap: UInt64 = 16 * 1024 * 1024
        guard !free.overflow, free.partialValue >= 10 * 1024 * 1024 * 1024 + cap else {
            throw TractandaError("resourceLimit", "Fixture needs a genuine 10 GiB reserve plus 16 MiB cap.")
        }
        if url.lastPathComponent.hasPrefix("mcp-document-e2e-") {
            var bytes: UInt64 = 0
            if let files = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            {
                for case let file as URL in files {
                    let metadata = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if metadata.isRegularFile == true { bytes += UInt64(metadata.fileSize ?? 0) }
                    guard bytes <= cap else {
                        throw TractandaError("resourceLimit", "Fixture exceeded its 16 MiB cap.")
                    }
                }
            }
        }
    }

    private func fixture() throws -> Fixture {
        try checkCapacity(at: FileManager.default.temporaryDirectory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mcp-document-e2e-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let storeURL = root.appendingPathComponent("store", isDirectory: true)
        let itemID: String
        let revisionID: String
        let attachmentID: String
        let accounts = E2EAccounts()
        let body = Data([0x25, 0x50, 0x44, 0x46])
        do {
            let store = try ItemStore(root: storeURL, accounts: accounts)
            try store.setAttachmentReserveForTesting(10 * 1024 * 1024 * 1024)
            _ = try store.configureAccess(
                .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("alice")]),
                ]), operationID: "access-policy")
            let initial = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                            "group": .text("staff"), "mode": .integer(0o640), "acl": .object([:]),
                        ])
                    ], operationID: "base-item")
            ).revision
            let upload = try store.beginAttachment(
                AttachmentUploadRequest(
                    itemID: initial.itemID, expectedRevisionID: initial.revisionID,
                    operationID: "original-upload", filename: "tiny.pdf", mediaType: "application/pdf",
                    byteCount: Int64(body.count), sha256: PageCorpusInput.digest(body)))
            let uploadID = try XCTUnwrap(upload.uploadID)
            _ = try store.appendAttachment(uploadID: uploadID, offset: 0, data: body)
            let attached = try store.finishAttachment(uploadID: uploadID).revision
            itemID = attached.itemID
            revisionID = attached.revisionID
            attachmentID = try XCTUnwrap(
                AttachmentDescriptor.descriptors(in: attached.fields).first?.attachmentID)
        }
        let worker = root.appendingPathComponent("worker.py")
        let script = """
            #!/usr/bin/python3
            import json,sys
            binding=json.load(open(sys.argv[5]))
            def emit(value):
                result=dict(binding);result.update(value)
                print(json.dumps(result,separators=(',',':')),flush=True)
            emit({'type':'hello','pageCount':1,'modelLoaded':False,'modelForwardCalls':0})
            loaded=False
            for line in sys.stdin:
                request=json.loads(line)
                if request['method']=='close':
                    emit({'type':'closed','requestID':request['requestID']});break
                base={'requestID':request['requestID'],'pageNumber':request['pageNumber']}
                if not loaded:
                    emit(dict(base,type='progress',phase='modelReady',completed=0,total=0));loaded=True
                emit(dict(base,type='progress',phase='render',completed=0,total=0))
                emit(dict(base,type='page',status='unsupported',failureCode='unsupportedDocumentInput'))
            """
        try Data(script.utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let model = root.appendingPathComponent("empty-model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: model, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkCapacity(at: root)
        return Fixture(
            root: root, store: storeURL,
            converter: DocumentConverterConfiguration(
                executablePath: worker.path, modelDirectory: model.path,
                scratchDirectory: root.appendingPathComponent("scratch").path),
            itemID: itemID, revisionID: revisionID, attachmentID: attachmentID, accounts: accounts)
    }

    // The fixture owner removes its directory only after this scope has awaited shutdown.
    private func withCoordinator(
        fixture: Fixture, converter: Bool = false, gate: PublicationGate? = nil,
        body: (ServiceCoordinator) async throws -> Void
    ) async throws {
        let accounts = fixture.accounts
        let coordinator = try await ServiceCoordinator(
            opening: fixture.store, documentConverter: converter ? fixture.converter : nil,
            makeAccountDirectory: { accounts })
        if let gate {
            await coordinator.setDocumentJobPublicationHookForTesting { await gate.pause() }
        }
        do {
            try await body(coordinator)
        } catch {
            await coordinator.setDocumentJobPublicationHookForTesting(nil)
            await gate?.release()
            await coordinator.close()
            throw error
        }
        await coordinator.setDocumentJobPublicationHookForTesting(nil)
        await gate?.release()
        await coordinator.close()
    }

    private func routedGateway(_ coordinator: ServiceCoordinator, uid: UInt32) -> NativeGateway {
        NativeGateway(backend: { request in
            try await coordinator.handle(request, forUID: uid)
        })
    }

    private func definition(_ name: String) throws -> ToolDefinition {
        try XCTUnwrap(ToolCatalog.definitions().first { $0.tool.name == name })
    }

    private func call(
        _ name: String, _ arguments: [String: Value], gateway: NativeGateway
    ) async throws -> Value {
        let data = try await MCPAdapter.callNativeTool(
            definition: definition(name), supplied: arguments, gateway: gateway)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func assertForbidden(
        _ name: String, _ arguments: [String: Value], gateway: NativeGateway,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        do {
            _ = try await call(name, arguments, gateway: gateway)
            XCTFail("Expected current ACL denial for \(name).", file: file, line: line)
        } catch {
            let failure = try MCPAdapter.toolFailure(error, operationID: nil)
            XCTAssertEqual(
                failure.structuredContent?.objectValue?["code"]?.stringValue, "forbidden", file: file,
                line: line)
        }
    }

    private func waitForJob(
        _ id: String, gateway: NativeGateway, root: URL,
        until predicate: (Value) -> Bool
    ) async throws -> Value {
        for _ in 0..<600 {
            try checkCapacity(at: root)
            let status = try await call(
                "tractanda_document_job_status", ["jobID": .string(id)], gateway: gateway)
            if predicate(status) { return status }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TractandaError("testTimeout", "MCP document job did not reach its bounded fixture state.")
    }

    private func waitForPublicationGate(_ gate: PublicationGate, root: URL) async throws {
        for _ in 0..<600 {
            try checkCapacity(at: root)
            if await gate.arrived() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TractandaError("testTimeout", "Document job did not reach the publication gate.")
    }

    func testJobsRouteThroughMCPGatewayAndPublishOnlyCanonicalSavedPages() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = PublicationGate()
        var jobID = ""
        try await withCoordinator(fixture: fixture, converter: true, gate: gate) { coordinator in
            let gateway = routedGateway(coordinator, uid: fixture.accounts.alice)
            let info = try await call("tractanda_info", [:], gateway: gateway)
            XCTAssertTrue(
                info.objectValue?["features"]?.arrayValue?.contains(.string("tractanda.document-jobs.v1"))
                    == true
            )

            let startArgs: [String: Value] = [
                "itemID": .string(fixture.itemID), "expectedRevisionID": .string(fixture.revisionID),
                "attachmentID": .string(fixture.attachmentID), "operationID": .string(fixture.operationID),
            ]
            let started = try await call("tractanda_document_job_start", startArgs, gateway: gateway)
            jobID = try XCTUnwrap(started.objectValue?["jobID"]?.stringValue)
            let replay = try await call("tractanda_document_job_start", startArgs, gateway: gateway)
            XCTAssertEqual(replay.objectValue?["jobID"]?.stringValue, jobID)

            try await waitForPublicationGate(gate, root: fixture.root)
            let prepublication = try await call(
                "tractanda_document_job_status", ["jobID": .string(jobID)], gateway: gateway)
            XCTAssertEqual(prepublication.objectValue?["committed"], nil)
            let listed = try await call(
                "tractanda_document_jobs", ["limit": .int(16)], gateway: gateway)
            XCTAssertEqual(listed.objectValue?["jobs"]?.arrayValue?.count, 1)
            let provisional = try await call(
                "tractanda_document_job_page",
                ["jobID": .string(jobID), "pageNumber": .int(1)], gateway: gateway)
            XCTAssertEqual(provisional.objectValue?["provisional"]?.boolValue, true)
            XCTAssertNil(provisional.objectValue?["revisionID"])
            XCTAssertNil(provisional.objectValue?["citation"])
            await coordinator.setDocumentJobPublicationHookForTesting(nil)
            await gate.release()

            let done = try await waitForJob(jobID, gateway: gateway, root: fixture.root) {
                $0.objectValue?["state"]?.stringValue == "completed"
            }
            XCTAssertTrue(done.objectValue?["committed"]?.objectValue?["indexReady"]?.boolValue == true)

            let saved = try await call(
                "tractanda_attachment_document_page",
                [
                    "itemID": .string(fixture.itemID), "attachmentID": .string(fixture.attachmentID),
                    "pageNumber": .int(1),
                ], gateway: gateway)
            XCTAssertEqual(saved.objectValue?["itemID"]?.stringValue, fixture.itemID)
            XCTAssertEqual(saved.objectValue?["selectedPageNumber"]?.intValue, 1)
            XCTAssertNotNil(saved.objectValue?["revisionID"]?.stringValue)
            XCTAssertEqual(
                saved.objectValue?["outcomes"]?.arrayValue?.first?.objectValue?["pageNumber"]?.intValue, 1)
            XCTAssertEqual(
                saved.objectValue?["outcomes"]?.arrayValue?.first?.objectValue?["status"]?.stringValue,
                "unsupported")
        }

        do {
            let store = try ItemStore(root: fixture.store, accounts: fixture.accounts)
            _ = try store.commit(
                CommitRequest(
                    action: .revise, itemID: fixture.itemID,
                    expectedRevisionID: try XCTUnwrap(store.get(fixture.itemID).revisionID),
                    changes: [
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                            "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:]),
                        ])
                    ], operationID: "revoke-alice"))
        }
        try await withCoordinator(fixture: fixture) { afterRevocation in
            let revokedGateway = routedGateway(afterRevocation, uid: fixture.accounts.alice)
            try await assertForbidden(
                "tractanda_attachment_document_page",
                [
                    "itemID": .string(fixture.itemID), "attachmentID": .string(fixture.attachmentID),
                    "pageNumber": .int(1),
                ], gateway: revokedGateway)
            try await assertForbidden(
                "tractanda_document_job_status", ["jobID": .string(jobID)], gateway: revokedGateway)
            try await assertForbidden(
                "tractanda_document_job_page",
                ["jobID": .string(jobID), "pageNumber": .int(1)], gateway: revokedGateway)
        }
        try checkCapacity(at: fixture.root)
    }

    func testDocumentJobFeatureIsIndependentOfConverterConfiguration() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await withCoordinator(fixture: fixture) { coordinator in
            let gateway = routedGateway(coordinator, uid: fixture.accounts.alice)
            let info = try await call("tractanda_info", [:], gateway: gateway)
            XCTAssertTrue(
                info.objectValue?["features"]?.arrayValue?.contains(.string("tractanda.document-jobs.v1"))
                    == true
            )
            let listed = try await call("tractanda_document_jobs", [:], gateway: gateway)
            XCTAssertEqual(listed.objectValue?["jobs"]?.arrayValue?.count, 0)
        }
        try checkCapacity(at: fixture.root)
    }

    func testPublicationGateReleaseBeforeArrivalIsLatched() async {
        let gate = PublicationGate()
        await gate.release()
        let finished = expectation(description: "An early release permits a later arrival")
        let arrival = Task {
            await gate.pause()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        // Also release on failure so this regression test does not retain a suspended task.
        await gate.release()
        await arrival.value
    }

    func testHeldPublicationGateErrorAwaitsShutdownAndPreservesError() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = PublicationGate()
        enum InjectedFailure: Error { case heldGate }
        do {
            try await withCoordinator(fixture: fixture, converter: true, gate: gate) { coordinator in
                let gateway = routedGateway(coordinator, uid: fixture.accounts.alice)
                _ = try await call(
                    "tractanda_document_job_start",
                    [
                        "itemID": .string(fixture.itemID),
                        "expectedRevisionID": .string(fixture.revisionID),
                        "attachmentID": .string(fixture.attachmentID),
                        "operationID": .string(fixture.operationID),
                    ], gateway: gateway)
                try await waitForPublicationGate(gate, root: fixture.root)
                throw InjectedFailure.heldGate
            }
            XCTFail("Expected the injected held-gate error.")
        } catch InjectedFailure.heldGate {
            // Reopening acquires the exclusive writer lease: shutdown finished before cleanup.
            let store = try ItemStore(root: fixture.store, accounts: fixture.accounts)
            XCTAssertEqual(try store.get(fixture.itemID).itemID, fixture.itemID)
        }
        try checkCapacity(at: fixture.root)
    }

}
