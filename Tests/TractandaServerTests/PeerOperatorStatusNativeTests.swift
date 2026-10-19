import CTractandaPlatform
import Foundation
import Synchronization
import XCTest

@testable import TractandaCore
@testable import TractandaServer

private actor PeerStatusPause {
    private var continuation: CheckedContinuation<Void, Never>?
    private var used = false
    func wait(_ entered: XCTestExpectation) async {
        guard !used else { return }
        used = true
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
private final class PeerStatusAccounts: AccountDirectory, @unchecked Sendable {
    let base: PeerServiceFixture.Accounts
    private let demoted = Mutex(false)
    init(_ base: PeerServiceFixture.Accounts) { self.base = base }
    func demote() { demoted.withLock { $0 = true } }
    func user(forUID uid: UInt32) throws -> AccountIdentity {
        let value = try base.user(forUID: uid)
        guard uid == base.human, demoted.withLock({ $0 }) else { return value }
        return .init(uid: uid, name: value.name, primaryGroupName: value.primaryGroupName, groupIDs: [])
    }
    func user(named name: String) throws -> AccountIdentity { try user(forUID: base.user(named: name).uid) }
    func groupID(named name: String) throws -> UInt32 { try base.groupID(named: name) }
}

final class PeerOperatorStatusNativeTests: XCTestCase {
    private func request(_ arguments: [String: Any] = [:], id: String = "status") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [[PeerOperatorStatus.nativeMethod, arguments, id]],
        ])
    }
    private func status(_ data: Data) throws -> PeerOperatorStatus {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
        XCTAssertEqual(calls.first?.first as? String, PeerOperatorStatus.nativeMethod)
        return try JSON.decode(
            PeerOperatorStatus.self, JSONSerialization.data(withJSONObject: XCTUnwrap(calls.first?[1])))
    }
    private func assertError(_ data: Data, _ code: String, file: StaticString = #filePath, line: UInt = #line)
        throws
    {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]], file: file, line: line)
        XCTAssertEqual(calls.first?.first as? String, "error", file: file, line: line)
        XCTAssertEqual((calls.first?[1] as? [String: Any])?["type"] as? String, code, file: file, line: line)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("canonical"), file: file, line: line)
    }
    func testStrictNativeStatusSchemaBoundsAndNoCallerAssertion() throws {
        let valid = try request()
        XCTAssertNotNil(try PeerOperatorStatusNativeCall.parse(valid))
        for data in [
            try request(["uid": 0]), try request(["administrator": true]),
            try request(id: String(repeating: "a", count: 129)), try request(id: "bad\nid"),
            try request(["private": String(repeating: "x", count: 8192)]),
        ] {
            XCTAssertThrowsError(try PeerOperatorStatusNativeCall.parse(data))
        }
        let mixed = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [
                [PeerOperatorStatus.nativeMethod, [:], "a"], ["TractandaStore/info", [:], "b"],
            ],
        ])
        XCTAssertThrowsError(try PeerOperatorStatusNativeCall.parse(mixed))
    }
    func testKernelAuthenticatedNativeStatusDisabledAndConnectionDown() async throws {
        try PeerFixtureCapacity.requireFree()
        // One fresh store with its derived index/WAL is estimated below 8 MiB.
        guard UInt64(8 * 1024 * 1024) <= PeerFixtureCapacity.fixtureCapBytes else {
            throw TractandaError("resourceLimit", "Status fixture estimate exceeds its cap.")
        }
        let root = try GuardedFixtureDirectory.create(
            prefix: "o", source: "PeerOperatorStatusNativeTests", test: name, socket: "s")
        defer { try? FileManager.default.removeItem(at: root) }
        func capacity() throws {
            try PeerFixtureCapacity.requireFree(at: root)
            var bytes: UInt64 = 0
            let scan = try XCTUnwrap(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            while let file = scan.nextObject() as? URL {
                let metadata = try FileMetadata.read(at: file)
                if metadata.type == .regular {
                    guard
                        metadata.size <= PeerFixtureCapacity.fixtureCapBytes
                            - min(bytes, PeerFixtureCapacity.fixtureCapBytes)
                    else { throw TractandaError("resourceLimit", "Tiny status fixture exceeded its cap.") }
                    bytes += metadata.size
                }
            }
        }
        let store = root.appendingPathComponent("store")
        let socket = root.appendingPathComponent("s")
        do { _ = try ItemStore.initializeFresh(root: store) }
        try capacity()
        let daemon = try await SharedDaemon.start(
            configuration: .init(storePath: store.path, socketPath: socket.path, httpPort: nil))
        defer { await daemon.close() }
        try capacity()
        let bytes = try request()
        let connection = ServerConnection(socketPath: socket.path)
        let response = try await Task.detached { try connection.send(bytes) }.value
        XCTAssertLessThanOrEqual(response.count, 16 * 1024)
        let value = try status(response)
        XCTAssertEqual(value.canonical.readiness, .ready)
        XCTAssertEqual(value.runtime.state, .disabled)
        XCTAssertEqual(value.runtime.synchronization.state, .disabled)
        await daemon.close()
        do {
            _ = try connection.send(bytes)
            XCTFail("Status must not start a stopped service.")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "connectionFailed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        try capacity()
    }
    func testKernelUIDServiceOwnerCannotAssertCanonicalAdministrator() async throws {
        guard tractanda_uid() != 0 else {
            throw XCTSkip("Existing explicit host-root repair authority is a separate policy path.")
        }
        let root = try GuardedFixtureDirectory.create(
            prefix: "o", source: "PeerOperatorStatusNativeTests", test: name, socket: "s")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try PeerServiceFixture(root: root)
        let accounts = fixture.accounts
        fixture.releaseWriter()
        let socket = root.appendingPathComponent("s")
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: fixture.sourceRoot.path,
                socketPath: socket.path, httpPort: nil), makeAccountDirectory: { accounts })
        defer { await daemon.close() }
        let connection = ServerConnection(socketPath: socket.path)
        let query = try request()
        let denied = try await Task.detached { try connection.send(query) }.value
        try assertError(denied, "forbidden")
        let forged = try request(["uid": accounts.human, "administrator": true])
        let reply = try await Task.detached { try connection.send(forged) }.value
        let error = try JSON.decode(TractandaError.self, reply)
        XCTAssertEqual(error.code, "invalidArguments")
        XCTAssertFalse(String(decoding: reply, as: UTF8.self).contains("storeID"))
        try fixture.capacity()
    }
    func testCurrentAdminNativeOnlyRuntimeUnavailableAndPostAwaitRevocation() async throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "o", source: "PeerOperatorStatusNativeTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try PeerServiceFixture(root: root)
        let accounts = PeerStatusAccounts(fixture.accounts)
        fixture.releaseWriter()
        let coordinator = try await ServiceCoordinator(
            opening: fixture.sourceRoot, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
        defer { await coordinator.close() }
        let sessions = SessionAuthority(coordinator: coordinator)
        let app = DaemonApplication(
            coordinator: coordinator, sessions: sessions, page: Data(), manual: Data(), nonce: "status")
        defer { await app.close() }
        let query = try request()
        let unknownRuntime = try status(await app.native(query, forUID: accounts.base.human))
        XCTAssertEqual(unknownRuntime.canonical.readiness, .ready)
        XCTAssertEqual(unknownRuntime.runtime.state, .unavailable)
        if tractanda_uid() != 0 {
            let denied = try await app.native(query, forUID: tractanda_uid())
            // Service ownership supplies no canonical administrator grant.
            try assertError(denied, "forbidden")
        }
        let token = try await sessions.issue(forUID: accounts.base.human).token
        try assertError(await sessions.dispatch(query, token: token), "unknownMethod")
        let http = try await app.http(
            .init(
                method: "POST", uri: "/api",
                headers: [
                    "host": ["127.0.0.1:48730"], "content-type": ["application/json"],
                    "authorization": ["Bearer " + token],
                ], body: query, localPort: 48730))
        XCTAssertEqual(http.status, 200)
        try assertError(http.body, "unknownMethod")
        let gate = PeerStatusPause()
        let entered = expectation(description: "runtime status awaits")
        await app.setPeerStatusProvider {
            await gate.wait(entered)
            return try .init(
                state: .active, responderPublished: true,
                incomingConnectionCount: 0, outgoingConnectionCount: 0, pendingConnectionCount: 0,
                synchronization: .init(state: .disabled))
        }
        defer { await gate.release() }
        let loading = Task { try await app.native(query, forUID: accounts.base.human) }
        await fulfillment(of: [entered], timeout: 5)
        accounts.demote()
        await gate.release()
        try assertError(await loading.value, "forbidden")
        try fixture.capacity()
    }
}

extension PeerOperatorStatusNativeTests {
    func testStatusReportsImmutableActuallyLoadedOnDemandConfiguration() async throws {
        try PeerFixtureCapacity.requireFree()
        guard UInt64(8 * 1024 * 1024) <= PeerFixtureCapacity.fixtureCapBytes else {
            throw TractandaError("resourceLimit", "Tiny status fixture exceeds cap.")
        }
        let root = try GuardedFixtureDirectory.create(
            prefix: "o", source: "PeerOperatorStatusNativeTests", test: name, socket: "s")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store")
        let socket = root.appendingPathComponent("s")
        do { _ = try ItemStore.initializeFresh(root: store) }
        let configuration = try PeerRuntimeConfiguration()
        let path = root.appendingPathComponent("peer.json")
        try configuration.encoded().write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let daemon = try await SharedDaemon.start(
            configuration: .init(
                storePath: store.path, socketPath: socket.path,
                httpPort: nil, peerRuntimeConfigurationPath: path.path))
        defer { await daemon.close() }
        // Later file edits are not facts about the running process's immutable load.
        try Data("invalid later contents".utf8).write(to: path)
        let query = try request()
        let connection = ServerConnection(socketPath: socket.path)
        let response = try await Task.detached { try connection.send(query) }.value
        XCTAssertLessThanOrEqual(response.count, 16 * 1024)
        let runtime = try status(response).runtime
        XCTAssertEqual(runtime.state, .active)
        XCTAssertEqual(runtime.configurationPath, path.path)
        XCTAssertEqual(runtime.settingsDigest, configuration.settingsDigest)
        XCTAssertEqual(runtime.listenerConfigured, false)
        XCTAssertFalse(runtime.synchronizationEnabled)
        XCTAssertEqual(runtime.synchronization.state, .disabled)
        await daemon.close()
        try PeerFixtureCapacity.requireFree(at: root)
        var size: UInt64 = 0
        let scan = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        while let file = scan.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { size += UInt64(values.fileSize ?? 0) }
        }
        XCTAssertLessThanOrEqual(size, 8 * 1024 * 1024)
    }
}
