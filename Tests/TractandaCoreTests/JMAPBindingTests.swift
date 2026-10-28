import Foundation
import TractandaClient
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private final class BindingDirectory: AccountDirectory, @unchecked Sendable {
    let uid = UInt32(geteuid())
    private let lock = NSLock()
    private var name = "alice"
    func rename() { lock.withLock { name = "bob" } }
    func user(forUID uid: UInt32) throws -> AccountIdentity {
        guard uid == self.uid else { throw TractandaError("unresolvedPrincipal", "Unknown fixture uid") }
        return lock.withLock { .init(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [20, 80]) }
    }
    func user(named name: String) throws -> AccountIdentity {
        let value = try user(forUID: uid)
        guard value.name == name else { throw TractandaError("unresolvedPrincipal", "Unknown fixture name") }
        return value
    }
    func groupID(named name: String) throws -> UInt32 {
        guard let id: UInt32 = ["staff": 20, "admin": 80, "operators": 80][name] else {
            throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
        }
        return id
    }
    func auth() -> JMAPHTTPAuthentication {
        .init(
            credentialID: "test-bearer-a", uid: uid, principalName: "alice", expiresAt: Date() + 3600,
            revalidate: { try self.user(forUID: self.uid) })
    }
}
private actor BindingBarrier {
    var released = false
    var waiting: CheckedContinuation<Void, Never>?
    func block() async { if !released { await withCheckedContinuation { waiting = $0 } } }
    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}
final class JMAPBindingTests: XCTestCase {
    private func root() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "jmap-binding-" + Identifier.make())
    }
    private func store(_ root: URL, _ directory: BindingDirectory) throws -> ItemStore {
        try ItemStore(
            personalRoot: root,
            opening: .fresh(
                .object([
                    "profile": .text(AccessConfiguration.profile), "groups": .list([.text("staff")]),
                    "administration": .text("system"), "administratorGroup": .text("admin"),
                ])), accounts: directory,
            attachmentUploadPolicy: .init(minimumFreeBytes: Int64(AttachmentFixtureCapacity.reserveBytes)))
    }
    private func request(_ method: String, _ args: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "using": TractandaJMAP.using, "methodCalls": [[method, args, "call"]],
        ])
    }
    private func reply(_ data: Data) throws -> JMAPValue {
        let value = try JMAPValue.decode(data)
        return try XCTUnwrap(value["methodResponses"]?.elements?.first?.elements?[1])
    }
    func testQueuedBearerCannotBecomeReplacementUserBeforeMutation() async throws {
        let root = try root()
        let directory = BindingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account: String
        do {
            let seed = try store(root, directory)
            account = try seed.nativeProtocolSessionBasis.identity
        }
        let owner = try await ServiceCoordinator(opening: root, makeAccountDirectory: { directory })
        let entered = expectation(description: "request authenticated before queue admission")
        let barrier = BindingBarrier()
        await owner.setNativeAdmissionHookForTesting { method in
            if method == "TractandaItem/commit" {
                entered.fulfill()
                await barrier.block()
            }
        }
        let auth = directory.auth()
        let commit = CommitRequest(
            classID: "Item", changes: ["subject": .text("old bearer")], operationID: Identifier.make())
        var args = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(commit)) as? [String: Any])
        args["accountId"] = account
        let bytes = try request("TractandaItem/commit", args)
        let task = Task {
            try await owner.handleAuthenticatedJMAP(bytes, authentication: auth, additionalMethods: [:])
        }
        await fulfillment(of: [entered], timeout: 120)
        directory.rename()
        await barrier.release()
        do {
            let denied = try await task.value
            XCTAssertEqual(try reply(denied)["type"]?.text, "forbidden")
            await owner.setNativeAdmissionHookForTesting(nil)
            // A fresh local OS request may use Bob, but the old bearer produced no Item.
            let query = try await owner.handle(
                request(
                    "TractandaItem/query",
                    ["accountId": account, "filter": ["expression": "classID == \"Item\""]]),
                forUID: directory.uid)
            XCTAssertEqual(try reply(query)["ids"]?.elements?.count, 0)
            await owner.close()
        } catch {
            await barrier.release()
            await owner.close()
            throw error
        }
    }
    func testPreparedReadRechecksPinnedNameBeforeDeliveryAndFallback() async throws {
        let root = try root()
        let directory = BindingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account: String
        let itemID: String
        do {
            let seed = try store(root, directory)
            account = try seed.nativeProtocolSessionBasis.identity
            itemID = try seed.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("alice secret")],
                    operationID: Identifier.make()), actorUID: directory.uid
            ).revision.itemID
        }
        let owner = try await ServiceCoordinator(opening: root, makeAccountDirectory: { directory })
        let entered = expectation(description: "pooled read outside owner queue")
        let barrier = BindingBarrier()
        await owner.setPooledReadBeforeFinishHookForTesting {
            entered.fulfill()
            await barrier.block()
        }
        let bytes = try request("TractandaItem/get", ["accountId": account, "ids": [itemID]])
        let task = Task {
            try await owner.handleAuthenticatedJMAP(
                bytes, authentication: directory.auth(), additionalMethods: [:])
        }
        await fulfillment(of: [entered], timeout: 120)
        directory.rename()
        await barrier.release()
        do {
            let denied = try await task.value
            XCTAssertEqual(try reply(denied)["type"]?.text, "forbidden")
            XCTAssertNil(try reply(denied)["list"])
            await owner.close()
        } catch {
            await barrier.release()
            await owner.close()
            throw error
        }
    }
    func testNestedOwnerScopeInheritsPinAndDisposesItAfterFailure() throws {
        let root = try root()
        let directory = BindingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root, directory)
        var entered = false
        XCTAssertThrowsError(
            try store.withExpectedPrincipal(forUID: directory.uid, name: "alice") {
                directory.rename()
                try store.withAccess(forUID: directory.uid, recoverPublication: false) { entered = true }
            })
        XCTAssertFalse(entered)
        let current = try store.withAccess(forUID: directory.uid, recoverPublication: false) {
            try store.accountIdentity(forUID: directory.uid).name
        }
        XCTAssertEqual(current, "bob")
    }
}

extension JMAPBindingTests {
    func testLocalSetLimitReflectsRegisteredMethodsWithoutChangingPublicSnapshot() async throws {
        let root = try root()
        let directory = BindingDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try store(root, directory) }
        let owner = try await ServiceCoordinator(opening: root, makeAccountDirectory: { directory })
        do {
            let bytes = try request(TractandaJMAP.discoveryMethod, [:])
            let native = try await owner.handle(bytes, forUID: directory.uid)
            XCTAssertEqual(
                try reply(native)["capabilities"]?[JMAPKernel.core]?["maxObjectsInSet"],
                .number(try JMAPNumber("0")))
            let definition = JMAPMethodDefinition(
                capability: JMAPKernel.core, effect: .readOnly, scope: .session, maximumResponseBytes: 4096
            ) { _, _ in .success([]) }
            let methods = ["PushSubscription/set": definition]
            let bearer = try await owner.handle(
                JMAPRequest.decode(bytes), forUID: directory.uid, additionalMethods: methods)
            XCTAssertEqual(
                try reply(bearer)["capabilities"]?[JMAPKernel.core]?["maxObjectsInSet"],
                .number(try JMAPNumber(String(TractandaJMAP.maximumObjectsInSet))))
            let exposure = try JMAPHTTPSExposure(
                baseURL: "https://localhost:9443",
                resources: .init(api: true, upload: true, download: true, eventSource: true))
            let binding = try JMAPPublicBinding(
                exposure: exposure,
                limits: .init(
                    maxSizeUpload: 1_000_000, maxConcurrentUpload: 8, maxSizeRequest: 8_388_608,
                    maxConcurrentRequests: 64, maxCallsInRequest: 32,
                    maxObjectsInGet: Int64(TractandaJMAP.maximumObjectsInGet),
                    maxObjectsInSet: Int64(TractandaJMAP.maximumObjectsInSet), collationAlgorithms: []))
            let auth = directory.auth()
            let snapshot = try await owner.publicJMAPSession(authentication: auth, binding: binding)
            let api = try await owner.handlePublicJMAP(
                bytes, authentication: auth, binding: binding, additionalMethods: methods)
            XCTAssertEqual(try JMAPValue.decode(api)["sessionState"]?.text, snapshot.state.value)
            XCTAssertEqual(try reply(api)["state"]?.text, snapshot.state.value)
            await owner.close()
        } catch {
            await owner.close()
            throw error
        }
    }
}
