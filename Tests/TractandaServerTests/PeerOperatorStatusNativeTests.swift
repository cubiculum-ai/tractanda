import CTractandaPlatform
import Foundation
import Synchronization
import XCTest
import TractandaClient

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
    let humanUID = tractanda_uid()
    let serviceOwnerUID = PeerServiceFixture.Accounts().human
    private let demoted = Mutex(false)
    init() {}
    func demote() { demoted.withLock { $0 = true } }
    func user(forUID uid: UInt32) throws -> AccountIdentity {
        if uid == humanUID {
            return .init(
                uid: uid, name: "human", primaryGroupName: "staff",
                groupIDs: demoted.withLock({ $0 }) ? [] : [71001])
        }
        if uid == serviceOwnerUID {
            return .init(uid: uid, name: "daemon", primaryGroupName: "service", groupIDs: [71002])
        }
        throw TractandaError("unresolvedPrincipal", "Unknown personal status fixture account.")
    }
    func user(named name: String) throws -> AccountIdentity {
        switch name {
        case "human": try user(forUID: humanUID)
        case "daemon": try user(forUID: serviceOwnerUID)
        default: throw TractandaError("unresolvedPrincipal", "Unknown personal status fixture account.")
        }
    }
    func groupID(named name: String) throws -> UInt32 {
        switch name {
        case "staff": 71001
        case "service": 71002
        default: throw TractandaError("unresolvedPrincipal", "Unknown personal status fixture group.")
        }
    }
}

final class PeerOperatorStatusNativeTests: XCTestCase {
    private var accountID = "fixture-account"
    private func invocation(_ data: Data) throws -> NativeMethodInvocation {
        let request = try JMAPRequest.decode(data)
        let definitions: [String: JMAPMethodDefinition] = [
            PeerOperatorStatus.nativeMethod: .init(capability: ItemService.capability,
                effect: .readOnly, maximumResponseBytes: PeerOperatorStatus.maximumResponseBytes) { _, _ in
                    .failure(.init("serverFail"), effects: .none)
                },
        ]
        var execution = try JMAPKernel(methods: definitions, accounts: [
            .init(accountID: accountID, capabilities: [ItemService.capability], isReadOnly: false)
        ], sessionState: { try! .init("fixture") }).begin(request)
        guard let call = try execution.next() else {
            throw TractandaError("invalidArguments", "Fixture needs one yielded account-scoped invocation.")
        }
        return NativeMethodInvocation(call.invocation, context: call.context)
    }
    private func personalStore(root: URL, accounts: PeerStatusAccounts) throws -> URL {
        let access = ItemValue.object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("human")]),
            "administration": .text("system"), "administratorGroup": .text("staff"),
        ])
        let path = root.appendingPathComponent("store")
        var store: ItemStore? = try ItemStore.initializePersonalWorkgroup(
            root: path, accounts: accounts, accessConfiguration: access)
        accountID = try store!.personalSyncIdentity().storeID
        XCTAssertNil(try store!.personalSyncIdentity().membership)
        store = nil
        return path
    }

    private func runtimeConfiguration(root: URL) throws -> (URL, PersonalPeerRuntimeConfiguration) {
        let settings = try PeerRuntimeConfiguration()
        let runtime = try PersonalPeerRuntimeConfiguration(settings: settings)
        let path = root.appendingPathComponent("personal-runtime.json")
        try PrivateConfiguration.write(runtime.encoded(), to: path)
        return (path, runtime)
    }

    private func request(_ arguments: [String: Any] = [:], id: String = "status") throws -> Data {
        var selected = arguments
        selected["accountId"] = accountID
        return try JSONSerialization.data(withJSONObject: [
            "using": ["urn:ietf:params:jmap:core", ItemService.capability],
            "methodCalls": [[PeerOperatorStatus.nativeMethod, selected, id]],
        ])
    }
    private func status(_ data: Data) throws -> PeerOperatorStatus {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
        XCTAssertEqual(calls.first?.first as? String, PeerOperatorStatus.nativeMethod)
        return try JSON.decode(
            PeerOperatorStatus.self, JSONSerialization.data(withJSONObject: XCTUnwrap(calls.first?[1])))
    }
    private func assertError(
        _ data: Data, _ code: String, allowBindingDenial: Bool = false, file: StaticString = #filePath,
        line: UInt = #line
    )
        throws
    {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        if allowBindingDenial, let denied = object["code"] as? String {
            XCTAssertEqual(denied, code, file: file, line: line)
            XCTAssertNil(object["methodResponses"], file: file, line: line)
            XCTAssertNil(object["canonical"], file: file, line: line)
            return
        }
        let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]], file: file, line: line)
        XCTAssertEqual(calls.first?.first as? String, "error", file: file, line: line)
        XCTAssertEqual((calls.first?[1] as? [String: Any])?["type"] as? String, code, file: file, line: line)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("canonical"), file: file, line: line)
    }
    func testStrictNativeStatusSchemaBoundsAndNoCallerAssertion() throws {
        let valid = try request()
        XCTAssertNotNil(try PeerOperatorStatusNativeCall.parse(invocation(valid)))
        for data in [
            try request(["uid": 0]), try request(["administrator": true]),
            try request(["private": String(repeating: "x", count: 8192)]),
        ] {
            XCTAssertThrowsError(try PeerOperatorStatusNativeCall.parse(invocation(data)))
        }
        for id in ["a", String(repeating: "a", count: 128), "arbitrary-id"] {
            XCTAssertNotNil(try PeerOperatorStatusNativeCall.parse(invocation(request(id: id))))
        }
        let mixed = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [
                [PeerOperatorStatus.nativeMethod, ["accountId": accountID], "a"], ["TractandaStore/info", [:], "b"],
            ],
        ])
        XCTAssertThrowsError(try PeerOperatorStatusNativeCall.parse(invocation(mixed)))
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
        let accounts = PeerStatusAccounts()
        let store = try personalStore(root: root, accounts: accounts)
        let socket = root.appendingPathComponent("s")
        let (runtimePath, _) = try runtimeConfiguration(root: root)
        try capacity()
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: store.path, socketPath: socket.path, httpPort: nil,
                peerRuntimeConfigurationPath: runtimePath.path),
            makeAccountDirectory: { accounts })
        defer { await daemon.close() }
        try capacity()
        let bytes = try request()
        let connection = ServerConnection(socketPath: socket.path)
        let response = try await Task.detached { try connection.send(bytes) }.value
        XCTAssertLessThanOrEqual(response.count, 16 * 1024)
        let value = try status(response)
        XCTAssertEqual(value.canonical.readiness, .ready)
        XCTAssertEqual(value.runtime.state, .active)
        XCTAssertEqual(value.runtime.listenerConfigured, false)
        XCTAssertEqual(value.runtime.synchronization.state, .disabled)
        await daemon.close()
        do {
            _ = try connection.send(bytes)
            XCTFail("Status must not start a stopped service.")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "connectionFailed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        try capacity()
    }
    func testPersonalServiceOwnerCannotAssertCanonicalAdministrator() async throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "o", source: "PeerOperatorStatusNativeTests", test: name, socket: "s")
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = PeerStatusAccounts()
        let store = try personalStore(root: root, accounts: accounts)
        let (runtimePath, runtime) = try runtimeConfiguration(root: root)
        let coordinator = try await ServiceCoordinator(
            opening: store, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
        defer { await coordinator.close() }
        let app = DaemonApplication(
            coordinator: coordinator, sessions: SessionAuthority(coordinator: coordinator),
            page: Data(), manual: Data(), nonce: "status")
        defer { await app.close() }
        await app.setPeerStatusProvider {
            try .init(
                state: .unavailable, configurationPath: runtimePath.path,
                settingsDigest: runtime.settings.settingsDigest,
                synchronization: .init(state: .unavailable))
        }
        let query = try request()
        try assertError(
            await app.native(query, forUID: accounts.serviceOwnerUID), "forbidden", allowBindingDenial: true)
        let forged = try request(["uid": accounts.humanUID, "administrator": true])
        try assertError(await app.native(forged, forUID: accounts.humanUID), "invalidArguments")
        try PeerFixtureCapacity.requireFree(at: root)
    }
    func testCurrentAdminNativeOnlyRuntimeUnavailableAndPostAwaitRevocation() async throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "o", source: "PeerOperatorStatusNativeTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = PeerStatusAccounts()
        let store = try personalStore(root: root, accounts: accounts)
        let (runtimePath, runtimeConfiguration) = try runtimeConfiguration(root: root)
        let coordinator = try await ServiceCoordinator(
            opening: store, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
        defer { await coordinator.close() }
        let sessions = SessionAuthority(coordinator: coordinator)
        let app = DaemonApplication(
            coordinator: coordinator, sessions: sessions, page: Data(), manual: Data(), nonce: "status")
        defer { await app.close() }
        await app.setPeerStatusProvider {
            try .init(
                state: .unavailable, configurationPath: runtimePath.path,
                settingsDigest: runtimeConfiguration.settings.settingsDigest,
                synchronization: .init(state: .unavailable))
        }
        let query = try request()
        let unknownRuntime = try status(await app.native(query, forUID: accounts.humanUID))
        XCTAssertEqual(unknownRuntime.canonical.readiness, .ready)
        XCTAssertEqual(unknownRuntime.runtime.state, .unavailable)
        XCTAssertEqual(unknownRuntime.runtime.configurationPath, runtimePath.path)
        XCTAssertEqual(unknownRuntime.runtime.settingsDigest, runtimeConfiguration.settings.settingsDigest)
        if tractanda_uid() != 0 {
            let denied = try await app.native(query, forUID: accounts.serviceOwnerUID)
            // Service ownership supplies no canonical administrator grant.
            try assertError(denied, "forbidden", allowBindingDenial: true)
        }
        let token = try await sessions.issue(forUID: accounts.humanUID).token
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
                state: .active, configurationPath: runtimePath.path,
                settingsDigest: runtimeConfiguration.settings.settingsDigest, responderPublished: true,
                incomingConnectionCount: 0, outgoingConnectionCount: 0, pendingConnectionCount: 0,
                synchronization: .init(state: .disabled))
        }
        defer { await gate.release() }
        let loading = Task { try await app.native(query, forUID: accounts.humanUID) }
        await fulfillment(of: [entered], timeout: 5)
        accounts.demote()
        await gate.release()
        try assertError(await loading.value, "forbidden")
        try PeerFixtureCapacity.requireFree(at: root)
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
        let accounts = PeerStatusAccounts()
        let store = try personalStore(root: root, accounts: accounts)
        let socket = root.appendingPathComponent("s")
        let (path, configuration) = try runtimeConfiguration(root: root)
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: store.path, socketPath: socket.path,
                httpPort: nil, peerRuntimeConfigurationPath: path.path),
            makeAccountDirectory: { accounts })
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
        XCTAssertEqual(runtime.settingsDigest, configuration.settings.settingsDigest)
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
