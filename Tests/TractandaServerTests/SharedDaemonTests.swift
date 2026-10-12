import Foundation
import NIOCore
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

final class SharedDaemonTests: XCTestCase {
    private func directory() throws -> URL {
        #if os(Linux)
            let base = "/tmp"
        #else
            let base = "/private/tmp"
        #endif
        let root = URL(fileURLWithPath: base)
            .appendingPathComponent("trhost-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func nativeInfo(_ socket: String) async throws -> Data {
        let request = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [["TractandaStore/info", [:], "info"]],
        ])
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    with: Result {
                        try LocalTransport.call(socket: socket, request: request)
                    })
            }
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func testCloseRequestsRebuildStopBeforeQueuedMaintenanceDrain() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeRoot = root.appendingPathComponent("store")
        do {
            let store = try ItemStore(root: storeRoot)
            _ = try store.commit(CommitRequest(classID: "Item", operationID: "item"))
        }
        let daemon = try await SharedDaemon.start(
            configuration: .init(
                storePath: storeRoot.path,
                socketPath: root.appendingPathComponent("socket").path, httpPort: nil))
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
            try JSONSerialization.data(withJSONObject: [
                "using": [ItemService.capability],
                "methodCalls": [[method, arguments, "r"]],
            ])
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
        let reopened = try ItemStore(root: storeRoot)
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
            let reopened = try ItemStore(root: store)
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
        let occupied = try await SharedDaemon.start(
            configuration: .init(
                storePath: root.appendingPathComponent("first").path,
                socketPath: root.appendingPathComponent("a").path, httpPort: 0))
        do {
            let endpoints = await occupied.endpoints()
            let port = try XCTUnwrap(URL(string: endpoints.httpURL!)?.port)
            let candidateStore = root.appendingPathComponent("second")
            let candidateSocket = root.appendingPathComponent("b")
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
            let reopened = try ItemStore(root: candidateStore)
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
        do {
            _ = try await SharedDaemon.start(
                configuration: .init(storePath: store.path, socketPath: socket.path, httpPort: 0),
                claimStartupReadiness: { false })
            XCTFail("Expected startup readiness claim rejection")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertEqual(try ItemStore(root: store).root.path, canonicalPath(store))
    }

    func testManagedDaemonAcceptsExternalIndexDirectory() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        let index = root.appendingPathComponent("derived")
        let socket = root.appendingPathComponent("s")
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
}
