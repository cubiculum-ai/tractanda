import Foundation
import NIOCore
import NIOPosix
import TractandaPeerTransport
import XCTest

@testable import TractandaCore
@testable import TractandaServer

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

// Boundary-test fixture ownership only; no product API or shared runtime state.
enum GuardedFixtureDirectory {
    struct Context {
        let root: URL
        let proof: URL
    }
    static func physical(_ url: URL) throws -> URL {
        guard url.path.hasPrefix("/"), !url.path.contains("\0"),
            let path = realpath(url.path, nil)
        else { throw TractandaError("fixtureRoot", "Cannot resolve physical fixture path.") }
        defer { free(path) }
        // Foundation resolution can rewrite /private/var back to the symlink /var.
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    static func relativePath(_ url: URL, beneath root: URL) throws -> String {
        let prefix = root.path + "/"
        var info = stat()
        guard try physical(root).path == root.path,
            lstat(root.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
            url.path.hasPrefix(prefix),
            try physical(url.deletingLastPathComponent()).path == url.deletingLastPathComponent().path
        else { throw TractandaError("fixtureRoot", "Enumerated fixture escaped its physical owned root.") }
        let relative = String(url.path.dropFirst(prefix.count))
        guard !relative.isEmpty,
            relative.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw TractandaError("fixtureRoot", "Invalid relative fixture path.") }
        return relative
    }
    static func validate(_ url: URL) throws -> stat {
        var info = stat()
        guard url.path.hasPrefix("/"), try physical(url).path == url.path,
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
    static func parent() throws -> URL {
        try context()?.root ?? physical(FileManager.default.temporaryDirectory)
    }
    static func create(prefix: String, source: String, test: String, socket: String? = nil) throws -> URL {
        let context = try context()
        let parent = try context?.root ?? physical(FileManager.default.temporaryDirectory)
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
            let actual = try physical(root)
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

final class SharedDaemonTests: XCTestCase {
    private struct TestAuthenticator: PasswordAuthenticating {
        let uid: UInt32
        func authenticate(username: String, password: String) throws -> UInt32 { uid }
    }

    private func directory() throws -> URL {
        try GuardedFixtureDirectory.create(prefix: "t", source: "SharedDaemonTests", test: name, socket: "s")
    }

    private func nativeInfo(_ socket: String) async throws -> Data {
        let context = NativeAsyncClientContext { request in
            try await Task.detached { try LocalTransport.call(socket: socket, request: request) }.value
        }
        return try await context.send(
            method: "TractandaStore/info", arguments: Data("{}".utf8), callID: "info")
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func testHTTPRequestProblemsAndMethodFailuresKeepDistinctShapes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeRoot = root.appendingPathComponent("store")
        _ = try ItemStore.initializeFresh(root: storeRoot)
        let coordinator = try await ServiceCoordinator(opening: storeRoot)
        let uid = getuid()
        let sessions = SessionAuthority(
            coordinator: coordinator, authenticator: TestAuthenticator(uid: uid))
        let token = try await sessions.issue(forUID: uid).token
        let app = DaemonApplication(
            coordinator: coordinator, sessions: sessions, page: Data(), manual: Data(), nonce: "test")
        defer {
            Task {
                await app.close()
                await coordinator.close()
            }
        }

        func api(_ body: Data, contentType: String = "application/json") -> DaemonHTTPRequest {
            DaemonHTTPRequest(
                method: "POST", uri: "/api",
                headers: [
                    "host": ["127.0.0.1:48730"], "authorization": ["Bearer " + token],
                    "content-type": [contentType],
                ], body: body, localPort: 48730)
        }
        let malformed = try await app.http(api(Data("not-json".utf8)))
        XCTAssertEqual(malformed.status, 400)
        XCTAssertEqual(malformed.headers["Content-Type"], "application/problem+json")
        let malformedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: malformed.body) as? [String: Any])
        XCTAssertEqual(malformedObject["type"] as? String, "urn:ietf:params:jmap:error:notJSON")
        XCTAssertEqual(malformedObject["status"] as? Int, 400)

        let unsupportedMedia = try await app.http(api(Data("{}".utf8), contentType: "text/plain"))
        XCTAssertEqual(unsupportedMedia.status, 415)
        XCTAssertEqual(unsupportedMedia.headers["Content-Type"], "application/problem+json")
        let mediaObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: unsupportedMedia.body) as? [String: Any])
        XCTAssertEqual(mediaObject["type"] as? String, "urn:ietf:params:jmap:error:notJSON")
        XCTAssertEqual(mediaObject["status"] as? Int, 415)

        let methodFailure = try JSONSerialization.data(withJSONObject: [
            "using": ["urn:ietf:params:jmap:core"],
            "methodCalls": [["Unknown/method", [:], "failure"]],
        ])
        let methodResponse = try await app.http(api(methodFailure))
        XCTAssertEqual(methodResponse.status, 200)
        XCTAssertEqual(methodResponse.headers["Content-Type"], "application/json")
        let responseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: methodResponse.body) as? [String: Any])
        let calls = try XCTUnwrap(responseObject["methodResponses"] as? [[Any]])
        XCTAssertEqual(calls.first?.first as? String, "error")
        XCTAssertEqual((calls.first?[1] as? [String: Any])?["type"] as? String, "unknownMethod")
    }

    func testCloseRequestsRebuildStopBeforeQueuedMaintenanceDrain() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeRoot = root.appendingPathComponent("store")
        do {
            let store = try ItemStore.initializeFresh(root: storeRoot)
            _ = try store.commit(CommitRequest(classID: "Item", operationID: "item"))
        }
        let daemon = try await SharedDaemon.start(
            configuration: .init(
                storePath: storeRoot.path,
                socketPath: root.appendingPathComponent("s").path, httpPort: nil))
        let coordinator = await daemon.coordinatorForTesting()
        let entered = expectation(description: "Store queue is held inside durability loop")
        let released = DispatchSemaphore(value: 0)
        let lock = NSLock()
        nonisolated(unsafe) var once = false
        try await coordinator.setCanonicalSyncHookForTesting {
            lock.lock()
            let first = !once
            once = true
            lock.unlock()
            if first {
                entered.fulfill()
                _ = released.wait(timeout: .now() + 5)
            }
        }
        func request(_ method: String, _ arguments: [String: String] = [:]) throws -> Data {
            try nativeFixtureRequest(
                method: method, arguments: arguments, accountID: nativeFixtureAccountID(storeRoot),
                callID: "r")
        }
        _ = try await coordinator.handle(
            request("TractandaStore/rebuild", ["operationID": "close"]), forUID: getuid())
        await fulfillment(of: [entered], timeout: 3)
        // Reproduce an already accepted maintenance continuation queued behind rebuild.
        let maintenance = Task { try? await coordinator.queueMaintenanceForTesting() }
        let joinedMaintenance = Task<Void, Never> { _ = await maintenance.value }
        await daemon.setMaintenanceForTesting(joinedMaintenance)
        try await Task.sleep(for: .milliseconds(10))
        let closing = Task { await daemon.close() }
        var stopping = false
        for _ in 0..<100 {
            let data = try await coordinator.handle(request("TractandaStore/rebuildStatus"), forUID: getuid())
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let status = ((object["methodResponses"] as? [[Any]])?.first?[1]) as? [String: Any]
            stopping = status?["state"] as? String == "stopping"
            if stopping { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(stopping, "Shutdown must request cancellation before awaiting queued maintenance")
        released.signal()
        await closing.value
        let journal = RebuildJournal(root: storeRoot, ownerUID: getuid())
        XCTAssertEqual(try journal.load()?.state, "cancelled")
        let reopened = try ItemStore.openInitialized(root: storeRoot)
        XCTAssertTrue(reopened.isCanonicalTrusted)
    }
    func testRebuildNoProgressConfigurationRejectsInvalidIntervals() throws {
        for timeout in [0.0, -1, .infinity, .nan] {
            let configuration = DaemonConfiguration(
                storePath: "/private/tmp/test-store", socketPath: "/private/tmp/test-socket",
                rebuildNoProgressTimeoutSeconds: timeout)
            XCTAssertThrowsError(try configuration.validate())
        }
        try DaemonConfiguration(
            storePath: "/private/tmp/test-store", socketPath: "/private/tmp/test-socket",
            rebuildNoProgressTimeoutSeconds: 120
        ).validate()
    }
    func testStartEndpointsConcurrentCloseAndWriterRelease() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        let socket = root.appendingPathComponent("s")
        do { _ = try ItemStore.initializeFresh(root: store) }
        let daemon = try await SharedDaemon.start(
            configuration: .init(storePath: store.path, socketPath: socket.path, httpPort: 0))
        do {
            let endpoints = await daemon.endpoints()
            let address = try XCTUnwrap(endpoints.httpURL)
            XCTAssertGreaterThan(try XCTUnwrap(URL(string: address)?.port), 0)
            XCTAssertEqual(endpoints.socketPath, socket.path)
            XCTAssertEqual(endpoints.mcpURL, address + "/mcp")
            let (manual, response) = try await URLSession.shared.data(from: URL(string: address + "/manual")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(response.mimeType, "text/html")
            XCTAssertTrue(
                String(decoding: manual, as: UTF8.self).localizedCaseInsensitiveContains("user guide"))
            let reply = try await nativeInfo(socket.path)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
            let methods = try XCTUnwrap(object["methodResponses"] as? [[Any]])
            XCTAssertEqual(methods.first?.first as? String, "TractandaStore/info")
            XCTAssertNotNil((methods.first?[1] as? [String: Any])?["ownerUID"])
            async let first: Void = daemon.close()
            async let second: Void = daemon.close()
            _ = await (first, second)
            XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
            let reopened = try ItemStore.openInitialized(root: store)
            XCTAssertEqual(reopened.root.path, canonicalPath(store))
            do {
                _ = try await URLSession.shared.data(from: URL(string: address + "/manual")!)
                XCTFail("HTTP listener remained open after close")
            } catch {}
        } catch {
            await daemon.close()
            throw error
        }
    }

    func testFailedHTTPBindReleasesWriterAndPreservesOtherFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        do { _ = try ItemStore.initializeFresh(root: root.appendingPathComponent("first")) }
        let occupied = try await SharedDaemon.start(
            configuration: .init(
                storePath: root.appendingPathComponent("first").path,
                socketPath: root.appendingPathComponent("a").path, httpPort: 0))
        do {
            let endpoints = await occupied.endpoints()
            let port = try XCTUnwrap(URL(string: endpoints.httpURL!)?.port)
            let candidateStore = root.appendingPathComponent("second")
            let candidateSocket = root.appendingPathComponent("b")
            do { _ = try ItemStore.initializeFresh(root: candidateStore) }
            do {
                let unexpected = try await SharedDaemon.start(
                    configuration: .init(
                        storePath: candidateStore.path, socketPath: candidateSocket.path, httpPort: port))
                await unexpected.close()
                XCTFail("Expected the still-occupied HTTP port to reject startup")
            } catch let error as IOError {
                XCTAssertEqual(error.errnoCode, EADDRINUSE)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: candidateSocket.path))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
            let reopened = try ItemStore.openInitialized(root: candidateStore)
            XCTAssertEqual(reopened.root.path, canonicalPath(candidateStore))
            _ = try await nativeInfo(endpoints.socketPath)
            await occupied.close()
        } catch {
            await occupied.close()
            throw error
        }
    }

    func testStartupReadinessClaimRejectsBeforeEndpointPublication() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        let socket = root.appendingPathComponent("s")
        do { _ = try ItemStore.initializeFresh(root: store) }
        do {
            _ = try await SharedDaemon.start(
                configuration: .init(storePath: store.path, socketPath: socket.path, httpPort: 0),
                claimStartupReadiness: { false })
            XCTFail("Expected startup readiness claim rejection")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertEqual(try ItemStore.openInitialized(root: store).root.path, canonicalPath(store))
    }

    func testManagedDaemonAcceptsExternalIndexDirectory() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        let index = root.appendingPathComponent("derived")
        let socket = root.appendingPathComponent("s")
        do { _ = try ItemStore.initializeFresh(root: store, indexDirectory: index) }
        let daemon = try await SharedDaemon.start(
            configuration: .init(
                storePath: store.path, indexDirectory: index.path, socketPath: socket.path,
                httpPort: nil, managed: true))
        defer { Task { await daemon.close() } }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: index.appendingPathComponent("items.sqlite").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.appendingPathComponent("index/items.sqlite").path))
        await daemon.close()
    }

    func testManagedDaemonAcceptsValidatedDocumentRuntime() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("converter")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false)
        let scratch = root.appendingPathComponent("scratch")
        let socket = root.appendingPathComponent("s")
        do {
            _ = try ItemStore.initializeFresh(
                root: root.appendingPathComponent("store"),
                indexDirectory: root.appendingPathComponent("index"))
        }
        let daemon = try await SharedDaemon.start(
            configuration: .init(
                storePath: root.appendingPathComponent("store").path,
                indexDirectory: root.appendingPathComponent("index").path, socketPath: socket.path,
                httpPort: nil, managed: true,
                documentConverter: .init(
                    executablePath: executable.path, modelDirectory: model.path,
                    scratchDirectory: scratch.path)))
        do {
            let reply = try await nativeInfo(socket.path)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: reply) as? [String: Any])
            let info = try XCTUnwrap((object["methodResponses"] as? [[Any]])?.first?[1] as? [String: Any])
            let document = try XCTUnwrap(info["documentExtraction"] as? [String: Any])
            XCTAssertEqual(document["state"] as? String, "configured")
            XCTAssertEqual(document["requiresPreparedInput"] as? Bool, false)
            XCTAssertEqual(
                document["executableSHA256"] as? String, try DocumentProcess.executableSHA256(executable.path)
            )
            XCTAssertEqual(
                document["identity"] as? [String: String],
                try JSONDecoder().decode(
                    [String: String].self, from: JSONEncoder().encode(DocumentConverterIdentity())))
            let permissions =
                try FileManager.default.attributesOfItem(atPath: scratch.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o700)
        } catch {
            await daemon.close()
            throw error
        }
        await daemon.close()

        // Managed startup must still apply the existing executable/path/permission gates.
        for invalid in [
            DocumentConverterConfiguration(
                executablePath: "relative", modelDirectory: model.path, scratchDirectory: scratch.path),
            DocumentConverterConfiguration(
                executablePath: executable.path, modelDirectory: model.path,
                scratchDirectory: root.appendingPathComponent("store").path),
        ] {
            do {
                _ = try await SharedDaemon.start(
                    configuration: .init(
                        storePath: root.appendingPathComponent("store").path,
                        indexDirectory: root.appendingPathComponent("index").path, socketPath: socket.path,
                        httpPort: nil, managed: true, documentConverter: invalid))
                XCTFail("Invalid managed document configuration must be rejected")
            } catch let error as TractandaError {
                XCTAssertEqual(error.code, "invalidDocumentConfiguration")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: executable.path)
        XCTAssertThrowsError(
            try DocumentConverterConfiguration(
                executablePath: executable.path, modelDirectory: model.path, scratchDirectory: scratch.path
            ).validate(
                storeRoot: root.appendingPathComponent("store"),
                indexDirectory: root.appendingPathComponent("index")))
    }
    func testStrictStartupRejectsMissingLegacyPendingUnsupportedAndUnsafeStores() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        let legacy = root.appendingPathComponent("legacy")
        do { _ = try ItemStore(root: legacy) }
        let pending = root.appendingPathComponent("pending")
        let user = try SystemAccountDirectory().user(forUID: getuid()).name
        XCTAssertThrowsError(
            try ItemStore.createInitialized(
                root: pending,
                initialAccessConfiguration: .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text(user)]),
                ]), actorUID: getuid(),
                operationID: UUID.makeVersion1().uuidString.lowercased(),
                progress: { if $0 == "beforePin" { throw CancellationError() } }))
        let unsupported = root.appendingPathComponent("unsupported")
        do { _ = try ItemStore.initializeFresh(root: unsupported) }
        let declaration = unsupported.appendingPathComponent("canonical-reader.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: declaration)) as? [String: Any])
        object["minimumReaderLevel"] = 999
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: declaration.path)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: declaration)
        let unsafe = root.appendingPathComponent("unsafe")
        try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: unsupported)
        for candidate in [missing, legacy, pending, unsupported, unsafe] {
            let socket = root.appendingPathComponent("r")
            do {
                let daemon = try await SharedDaemon.start(
                    configuration: .init(
                        storePath: candidate.path, socketPath: socket.path, httpPort: nil))
                await daemon.close()
                XCTFail("Daemon adopted invalid store \(candidate.lastPathComponent)")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

}

extension SharedDaemonTests {
    private func writePeerConfiguration(_ configuration: PeerRuntimeConfiguration, root: URL) throws -> String
    {
        let file = root.appendingPathComponent("peer.json")
        try JSONEncoder().encode(configuration).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file.path
    }
    private func availablePeerPort(_ group: MultiThreadedEventLoopGroup) async throws -> Int {
        let listener = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(listener.localAddress?.port)
        try await listener.close().get()
        return port
    }

    func testPeerRuntimeDefaultOffAndExplicitSynchronizationRequiresExistingStore() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        do { _ = try ItemStore.initializeFresh(root: store) }
        let daemon = try await SharedDaemon.start(
            configuration: .init(
                storePath: store.path,
                socketPath: root.appendingPathComponent("s").path, httpPort: nil))
        let endpoints = await daemon.endpoints()
        XCTAssertNil(endpoints.peerHost)
        XCTAssertNil(endpoints.peerPort)
        let runtime = await daemon.peerRuntimeForTesting()
        XCTAssertNil(runtime)
        await daemon.close()
        let path = try writePeerConfiguration(.init(synchronization: .init(enabled: true)), root: root)
        let missing = root.appendingPathComponent("must-not-create")
        do {
            _ = try await SharedDaemon.start(
                configuration: .init(
                    storePath: missing.path,
                    socketPath: root.appendingPathComponent("s").path, httpPort: nil,
                    peerRuntimeConfigurationPath: path))
            XCTFail("Synchronization implicitly created a store")
        } catch { XCTAssertNotEqual((error as? TractandaError)?.code, "peerSynchronizationUnavailable") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let configured = try await SharedDaemon.start(
            configuration: .init(
                storePath: store.path,
                socketPath: root.appendingPathComponent("s").path, httpPort: nil,
                peerRuntimeConfigurationPath: path))
        let synchronization = await configured.synchronizationForTesting()
        XCTAssertNotNil(synchronization)
        await configured.close()
    }

    func testConfiguredEmptyResponderBindsDeniesAndShutdownReleasesEndpoint() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        do { _ = try ItemStore.initializeFresh(root: store) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let port = try await availablePeerPort(group)
        let path = try writePeerConfiguration(.init(listen: .init(host: "127.0.0.1", port: port)), root: root)
        let daemon = try await SharedDaemon.start(
            configuration: .init(
                storePath: store.path,
                socketPath: root.appendingPathComponent("s").path, httpPort: nil,
                peerRuntimeConfigurationPath: path))
        defer { await daemon.close() }
        let endpoints = await daemon.endpoints()
        XCTAssertEqual(endpoints.peerPort, port)
        let loadedRuntime = await daemon.peerRuntimeForTesting()
        let runtime = try XCTUnwrap(loadedRuntime)
        let ready = await runtime.hasResponderForTesting()
        XCTAssertFalse(ready)
        let child = try await ClientBootstrap(group: group).connectTimeout(.seconds(2))
            .connect(host: "127.0.0.1", port: port).get()
        try await child.closeFuture.get()  // Bound socket alone grants no TLS/application admission.
        let children = await runtime.connectionsForTesting()
        XCTAssertTrue(children.isEmpty)
        await daemon.close()
        do {
            let unexpected = try await ClientBootstrap(group: group).connectTimeout(.seconds(1))
                .connect(host: "127.0.0.1", port: port).get()
            try await unexpected.close().get()
            XCTFail("Closed peer listener still accepts connections")
        } catch {}
        // Match the production listener option: a completed TCP close can leave TIME_WAIT.
        let rebound = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: port).get()
        try await rebound.close().get()
        XCTAssertEqual(try ItemStore.openInitialized(root: store).root.path, canonicalPath(store))
    }

    func testPeerBindFailureAndLateStartupClaimUnwindAllOwnedResources() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        do { _ = try ItemStore.initializeFresh(root: store) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let occupied = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(occupied.localAddress?.port)
        let path = try writePeerConfiguration(.init(listen: .init(host: "127.0.0.1", port: port)), root: root)
        let configuration = DaemonConfiguration(
            storePath: store.path, socketPath: root.appendingPathComponent("s").path,
            httpPort: nil, peerRuntimeConfigurationPath: path)
        do {
            _ = try await SharedDaemon.start(configuration: configuration)
            XCTFail("Expected bind failure")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.socketPath))
        do { _ = try ItemStore.openInitialized(root: store) }
        try await occupied.close().get()
        do {
            _ = try await SharedDaemon.start(configuration: configuration, claimStartupReadiness: { false })
            XCTFail("Expected late readiness rejection")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.socketPath))
        let daemon = try await SharedDaemon.start(configuration: configuration)
        await daemon.close()
        let rebound = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: port).get()
        try await rebound.close().get()
    }

    func testSharedDaemonActivatedPeersOwnListenerConnectorAndChildren() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try PeerServiceFixture(root: root)
        f.releaseWriter()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let port = try await availablePeerPort(group)
        let targetPath = try writePeerConfiguration(
            .init(listen: .init(host: "127.0.0.1", port: port)), root: root)
        let accounts = f.accounts
        let target = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: f.targetRoot.path,
                socketPath: root.appendingPathComponent("s").path, httpPort: nil,
                peerRuntimeConfigurationPath: targetPath), makeAccountDirectory: { accounts })
        defer { await target.close() }
        // The first daemon already loaded immutable settings; a separate node-local document now configures source.
        let sourcePath = try writePeerConfiguration(
            .init(peers: [.init(alias: "target", host: "127.0.0.1", port: port)]), root: root)
        let source = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: f.sourceRoot.path,
                socketPath: root.appendingPathComponent("r").path, httpPort: nil,
                peerRuntimeConfigurationPath: sourcePath), makeAccountDirectory: { accounts })
        defer { await source.close() }
        let connection = try await source.connectPeer(peerID: "target")
        let response = try await connection.request(.init("inventory")).get()
        let inventory = try JSON.decode([String: TractandaCore.ItemValue].self, response)
        XCTAssertNotNil(inventory["entries"])
        do {
            _ = try await target.connectPeer(peerID: "source")
            XCTFail("Responder opened outbound transport")
        } catch {}
        await target.close()
        try await connection.closed.get()
        await source.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("s").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("r").path))
        try f.capacity()
    }
}
