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

// Kept identical in the three boundary-test targets; no product API or shared runtime state.
private enum GuardedFixtureDirectory {
    struct Context {
        let root: URL
        let proof: URL
    }
    static func validate(_ url: URL) throws -> stat {
        var info = stat()
        guard url.path.hasPrefix("/"), url.path == url.standardizedFileURL.resolvingSymlinksInPath().path,
            lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700
        else {
            throw TractandaError(
                "fixtureRoot", "Fixture override must be an existing private owned physical directory.")
        }
        return info
    }
    static func context() throws -> Context? {
        let env = ProcessInfo.processInfo.environment
        let guarded = env["TRACTANDA_TEST_FIXTURE_GUARDED"]
        let root = env["TRACTANDA_TEST_FIXTURE_ROOT"]
        let proof = env["TRACTANDA_TEST_FIXTURE_PROOF"]
        if guarded == nil, root == nil, proof == nil { return nil }
        guard guarded == "1", let root, let proof, !root.contains("\0"), !proof.contains("\0") else {
            throw TractandaError("fixtureRoot", "Guarded fixture overrides are incomplete.")
        }
        let result = Context(
            root: URL(fileURLWithPath: root, isDirectory: true),
            proof: URL(fileURLWithPath: proof, isDirectory: true))
        guard root.hasPrefix("/"), proof.hasPrefix("/"), result.root.path == root,
            result.proof.path == proof, result.root.path != result.proof.path,
            result.root.deletingLastPathComponent().path == result.proof.deletingLastPathComponent().path,
            try validate(result.root).st_dev == validate(result.proof).st_dev
        else {
            throw TractandaError(
                "fixtureRoot", "Fixture and proof overrides must be physical sibling directories.")
        }
        return result
    }
    static func parent() throws -> URL { try context()?.root ?? FileManager.default.temporaryDirectory }
    static func create(prefix: String, source: String, test: String, socket: String? = nil) throws -> URL {
        let context = try context()
        let parent = context?.root ?? FileManager.default.temporaryDirectory
        var capacity = statvfs()
        guard statvfs(parent.path, &capacity) == 0, capacity.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot inspect genuine fixture capacity.")
        }
        let free = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
        guard !free.overflow, free.partialValue >= 10 * 1024 * 1024 * 1024 + 16 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Tiny fixture needs 10 GiB reserve plus its 16 MiB bound.")
        }
        let root = parent.appendingPathComponent(prefix + String(UUID().uuidString.prefix(7)))
        if let socket {
            #if os(Linux)
                let limit = 108
            #else
                let limit = 104
            #endif
            guard root.appendingPathComponent(socket).path.utf8.count < limit else {
                throw TractandaError(
                    "resourceLimit", "Configured fixture root leaves no room for a Unix socket.")
            }
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        if let context {
            let actual = root.resolvingSymlinksInPath()
            _ = try validate(actual)
            guard actual.path == root.path, actual.deletingLastPathComponent().path == context.root.path,
                test.utf8.count <= 256
            else { throw TractandaError("fixtureRoot", "Fixture escaped its override.") }
            let fact: [String: Any] = [
                "profile": "tractanda.fixture-root-proof.v1", "source": source,
                "test": test, "root": actual.path, "expectedRoot": context.root.path,
                "proofRoot": context.proof.path, "uid": Int(geteuid()), "pid": Int(getpid()),
                "phase": "created",
            ]
            let bytes = try JSONSerialization.data(withJSONObject: fact, options: [.sortedKeys])
            guard bytes.count <= 2048 else {
                throw TractandaError("fixtureRoot", "Fixture proof exceeds its bound.")
            }
            let temporary = context.root.appendingPathComponent(
                ".fixture-proof-" + UUID().uuidString + ".tmp")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw TractandaError("fixtureRoot", "Cannot create fixture proof.") }
            defer { _ = close(descriptor) }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < bytes.count {
                    let count = write(
                        descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw TractandaError("fixtureRoot", "Cannot write fixture proof.")
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw TractandaError("fixtureRoot", "Cannot sync fixture proof.")
            }
            try FileManager.default.moveItem(
                at: temporary,
                to: context.proof.appendingPathComponent(source + "-" + root.lastPathComponent + ".json"))
            let directory = open(context.proof.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else {
                throw TractandaError("fixtureRoot", "Cannot open fixture proof directory.")
            }
            defer { _ = close(directory) }
            guard fsync(directory) == 0 else {
                throw TractandaError("fixtureRoot", "Cannot sync fixture proof directory.")
            }
        }
        return root
    }
}

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

    private func checkCapacity(at url: URL, beforeMetadata: ((URL) throws -> Void)? = nil) throws {
        for attempt in 0..<3 {
            do {
                try capacityAttempt(at: url, beforeMetadata: beforeMetadata)
                return
            } catch {
                let failure = error as NSError
                let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
                let missing =
                    (failure.domain == NSPOSIXErrorDomain && failure.code == ENOENT)
                    || (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError
                        && underlying.map { $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOENT) }
                            == true)
                guard attempt < 2, missing,
                    let path = failure.userInfo[NSFilePathErrorKey] as? String,
                    operationalInventoryPath(path, root: url)
                else { throw error }
            }
        }
    }

    private func operationalInventoryPath(_ path: String, root: URL) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let atomic =
            name.hasPrefix(".checkpoint-") && name.hasSuffix(".tmp")
            && UUID(uuidString: String(name.dropFirst(12).dropLast(4))) != nil
        if url.deletingLastPathComponent().path == root.appendingPathComponent("store").path {
            return name == ".tractanda-checkpoint-dirty" || atomic
        }
        let prefix = root.appendingPathComponent("store/document-jobs").path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard parts.count >= 3, UUID(uuidString: parts[0])?.version1Components != nil,
            parts[1] == "sessions", UUID(uuidString: parts[2])?.version1Components != nil
        else { return false }
        let dependency =
            name.hasPrefix(".dependency-") && name.hasSuffix(".tmp")
            && UUID(uuidString: String(name.dropFirst(12).dropLast(4))) != nil
        return parts.count == 3 || (parts.count == 4 && (parts[3] == "binding.json" || dependency))
    }

    private var temporaryDirectory: URL {
        get throws { try GuardedFixtureDirectory.parent() }
    }

    private func capacityAttempt(at url: URL, beforeMetadata: ((URL) throws -> Void)?) throws {
        var values = statvfs()
        guard statvfs(url.path, &values) == 0, values.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot inspect genuine fixture capacity.")
        }
        let free = UInt64(values.f_bavail).multipliedReportingOverflow(by: UInt64(values.f_frsize))
        let cap: UInt64 = 16 * 1024 * 1024
        guard !free.overflow, free.partialValue >= 10 * 1024 * 1024 * 1024 + cap else {
            throw TractandaError("resourceLimit", "Fixture needs a genuine 10 GiB reserve plus 16 MiB cap.")
        }
        if url.lastPathComponent.hasPrefix("m") {
            var owner = stat()
            guard lstat(url.path, &owner) == 0, owner.st_uid == getuid(),
                owner.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), owner.st_mode & 0o077 == 0
            else { throw TractandaError("resourceLimit", "Fixture inventory requires a private owned root.") }
            var bytes: UInt64 = 0
            if let files = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            {
                for case let file as URL in files {
                    try beforeMetadata?(file)
                    let metadata = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if metadata.isRegularFile == true { bytes += UInt64(metadata.fileSize ?? 0) }
                    guard bytes <= cap else {
                        throw TractandaError("resourceLimit", "Fixture exceeded its 16 MiB cap.")
                    }
                }
            }
        }
    }

    func testOperationalInventoryRetryIsBoundedAndCanonicalLossIsNotRetried() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "m", source: "DocumentJobIntegrationTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        try checkCapacity(at: root)
        try Data([1]).write(to: root.appendingPathComponent("probe"))
        let job = try UUID.makeVersion1().uuidString.lowercased()
        let session = try UUID.makeVersion1().uuidString.lowercased()
        let binding = root.appendingPathComponent(
            "store/document-jobs/" + job + "/sessions/" + session + "/binding.json"
        ).path
        var attempts = 0
        XCTAssertThrowsError(
            try checkCapacity(at: root) { _ in
                attempts += 1
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSFilePathErrorKey: binding])
            })
        XCTAssertEqual(attempts, 3)
        attempts = 0
        XCTAssertThrowsError(
            try checkCapacity(at: root) { _ in
                attempts += 1
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(ENOENT),
                    userInfo: [
                        NSFilePathErrorKey: root.appendingPathComponent("store/.tractanda/revision.json").path
                    ])
            })
        XCTAssertEqual(attempts, 1)
    }

    private func fixture() throws -> Fixture {
        try checkCapacity(at: temporaryDirectory)
        let root = try GuardedFixtureDirectory.create(
            prefix: "m", source: "DocumentJobIntegrationTests", test: name)
        let storeURL = root.appendingPathComponent("store", isDirectory: true)
        let itemID: String
        let revisionID: String
        let attachmentID: String
        let accounts = E2EAccounts()
        let body = Data([0x25, 0x50, 0x44, 0x46])
        do {
            _ = try ItemStore.initializeFresh(
                root: storeURL, accounts: accounts,
                initialAccessConfiguration: .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("alice")]),
                ]))
            let store = try ItemStore.openInitialized(root: storeURL, accounts: accounts)
            try store.setAttachmentReserveForTesting(10 * 1024 * 1024 * 1024)
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
            let store = try ItemStore.openInitialized(root: fixture.store, accounts: fixture.accounts)
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
            let store = try ItemStore.openInitialized(root: fixture.store, accounts: fixture.accounts)
            XCTAssertEqual(try store.get(fixture.itemID).itemID, fixture.itemID)
        }
        try checkCapacity(at: fixture.root)
    }

}
