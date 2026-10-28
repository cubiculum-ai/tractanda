import CTractandaPlatform
import Foundation
import NIOCore
import NIOPosix
import Synchronization
import XCTest

@testable import TractandaCore
@testable import TractandaServer

private final class EnrollmentOperatorAccounts: AccountDirectory, @unchecked Sendable {
    let base = PeerServiceFixture.Accounts()
    let administrator = Mutex(true)
    func user(forUID uid: UInt32) throws -> AccountIdentity {
        let identity = try base.user(forUID: uid)
        guard uid == base.human, !administrator.withLock({ $0 }) else { return identity }
        return .init(
            uid: uid, name: identity.name, primaryGroupName: identity.primaryGroupName, groupIDs: [])
    }
    func user(named name: String) throws -> AccountIdentity { try user(forUID: base.user(named: name).uid) }
    func groupID(named name: String) throws -> UInt32 { try base.groupID(named: name) }
}
private final class PersonalEnrollmentFixture {
    let root: URL, sourceRoot: URL
    let accounts = EnrollmentOperatorAccounts()
    var source: ItemStore?
    let configuration: PersonalMembershipConfiguration
    let credentialPaths: [String]
    init(test: String) throws {
        try PeerFixtureCapacity.requireFree()
        root = try GuardedFixtureDirectory.create(
            prefix: "e", source: "NativePeerEnrollmentTests", test: test, socket: "s")
        sourceRoot = root.appendingPathComponent("source")
        let access = ItemValue.object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("human")]),
            "administration": .text("system"), "administratorGroup": .text("staff"),
        ])
        source = try ItemStore.initializePersonalWorkgroup(
            root: sourceRoot, accounts: accounts, accessConfiguration: access)
        let identity = try source!.personalSyncIdentity()
        let target = try ItemStore.createPersonalSyncReplica(
            root: root.appendingPathComponent("target"), storeID: identity.storeID,
            accessConfiguration: access, accounts: accounts)
        configuration = try PersonalMembershipConfiguration(
            storeID: identity.storeID, configurationID: PeerServiceFixture.id(),
            members: [
                .init(replicaID: identity.replicaID, hostname: "source.example.invalid"),
                .init(replicaID: target.personalSyncIdentity().replicaID, hostname: "target.example.invalid"),
            ])
        let sourceKeys = root.appendingPathComponent("source-keys")
        let targetKeys = root.appendingPathComponent("target-keys")
        try PrivateConfiguration.makeDirectory(sourceKeys)
        try PrivateConfiguration.makeDirectory(targetKeys)
        try PersonalPairingFiles.create(
            configuration: configuration, leftReplicaID: identity.replicaID,
            rightReplicaID: target.personalSyncIdentity().replicaID,
            leftDirectory: sourceKeys, rightDirectory: targetKeys)
        credentialPaths = try FileManager.default.contentsOfDirectory(
            at: sourceKeys, includingPropertiesForKeys: nil
        ).map(\.path).sorted()
        try capacity()
    }
    func releaseWriter() { source = nil }
    func capacity() throws {
        try PeerFixtureCapacity.requireFree(at: root)
        var size: UInt64 = 0
        var entries = 0
        let scan = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        while let file = scan.nextObject() as? URL {
            entries += 1
            guard entries <= 4096 else {
                throw TractandaError("resourceLimit", "Native enrollment fixture entry cap.")
            }
            let m = try FileMetadata.read(at: file)
            if m.type == .regular {
                guard
                    m.size <= PeerFixtureCapacity.fixtureCapBytes
                        - min(size, PeerFixtureCapacity.fixtureCapBytes)
                else { throw TractandaError("resourceLimit", "Native enrollment fixture byte cap.") }
                size += m.size
            }
        }
    }
}
private actor EnrollmentOutputGate {
    let entered: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        entered.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class NativePeerEnrollmentTests: XCTestCase {
    private func personalAdminRequest(_ request: PeerExchangeRequest, id: String = "admin") throws -> Data {
        let arguments = try JSONSerialization.jsonObject(with: JSON.encode(request)) as! [String: Any]
        return try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [[PersonalPeerAdminCall.method, arguments, id]],
        ])
    }

    private func methodResult(_ data: Data, method: String = PersonalPeerAdminCall.method) throws
        -> [String: Any]
    {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
        XCTAssertEqual(calls.first?.first as? String, method)
        return try XCTUnwrap(calls.first?[1] as? [String: Any])
    }

    func testCurrentPersonalNativeCredentialEnrollmentAndGenericRoutesDeny() async throws {
        let f = try PersonalEnrollmentFixture(test: name)
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.releaseWriter()
        let accounts = f.accounts
        let coordinator = try await ServiceCoordinator(
            opening: f.sourceRoot, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
        defer { await coordinator.close() }
        let sessions = SessionAuthority(coordinator: coordinator)
        let app = DaemonApplication(
            coordinator: coordinator, sessions: sessions, page: Data(), manual: Data(), nonce: "enrollment")
        defer { await app.close() }
        await app.setPersonalPeerAdminProvider { request, uid in
            try await coordinator.personalPeerLocalRequest(request, forUID: uid)
        }

        let preparedRequest = try personalAdminRequest(
            .init(
                "membership.prepare",
                [
                    "configuration": .bytes(try JSON.encode(f.configuration)),
                    "nonce": .text(try PeerServiceFixture.id()),
                ]))
        let prepared = try methodResult(await app.native(preparedRequest, forUID: accounts.base.human))
        XCTAssertNotNil(prepared["configuration"])

        let registrationRequest = try personalAdminRequest(
            .init(
                "credentials.register",
                [
                    "configuration": .bytes(try JSON.encode(f.configuration)),
                    "paths": .list(f.credentialPaths.map(ItemValue.text)),
                ]), id: "register")
        let registeredData = try await app.native(registrationRequest, forUID: accounts.base.human)
        let registered = try methodResult(registeredData)
        XCTAssertEqual(registered["registered"] as? Int, f.credentialPaths.count)
        let replyText = String(decoding: registeredData, as: UTF8.self)
        for path in f.credentialPaths {
            XCTAssertFalse(
                replyText.contains(try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()))
        }
        let loadedCredentials = try await coordinator.loadPersonalPeerCredentials(includePending: true)
        XCTAssertEqual(loadedCredentials.count, f.credentialPaths.count)

        let token = try await sessions.issue(forUID: accounts.base.human).token
        let generic = try await sessions.dispatch(registrationRequest, token: token)
        XCTAssertTrue(String(decoding: generic, as: UTF8.self).contains("unknownMethod"))
        let http = try await app.http(
            .init(
                method: "POST", uri: "/api",
                headers: [
                    "host": ["127.0.0.1:48730"],
                    "content-type": ["application/json"], "authorization": ["Bearer " + token],
                ], body: registrationRequest, localPort: 48730))
        XCTAssertEqual(http.status, 200)
        XCTAssertTrue(String(decoding: http.body, as: UTF8.self).contains("unknownMethod"))
        try f.capacity()
    }
    func testPrivateOutputReauthorizesCurrentPersonalAdminAfterAwait() async throws {
        guard tractanda_uid() != 0 else {
            throw XCTSkip("Root repair policy is distinct from administrator demotion.")
        }
        let f = try PersonalEnrollmentFixture(test: name)
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.releaseWriter()
        let accounts = f.accounts
        let coordinator = try await ServiceCoordinator(
            opening: f.sourceRoot, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
        defer { await coordinator.close() }
        let entered = expectation(description: "output prepared before final delivery")
        let gate = EnrollmentOutputGate(entered)
        defer { await gate.release() }
        let privateBytes = Data("synthetic-private-enrollment-output".utf8)
        let output = f.root.appendingPathComponent("must-not-be-delivered")
        let session = NativePeerEnrollmentSession(
            operation: .exportTarget, byteCount: privateBytes.count,
            commit: { input in
                guard input == nil else { throw NativePeerEnrollment.failure() }
                return privateBytes
            }, cancel: {},
            validateBeforeDelivery: {
                await gate.wait()
                _ = try await coordinator.peerOperatorCanonicalStatus(forUID: accounts.base.human)
            })
        let sending = Task {
            let data = try await session.commit(nil)
            try await session.validateBeforeDelivery()
            try data.write(to: output)
        }
        await fulfillment(of: [entered], timeout: 5)
        // Only the current account mapping changes; no Store write is used as an authorization proxy.
        accounts.administrator.withLock { $0 = false }
        await gate.release()
        do {
            _ = try await sending.value
            XCTFail("A prepared private output is not a lasting personal administrator grant.")
        } catch {
            XCTAssertEqual((error as? TractandaError)?.code, "forbidden")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try f.capacity()
    }
    func testBinaryTargetOutputUsesActualBoundAndListenerDrainsHeldOutputAndCancel() async throws {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "e", source: "NativePeerEnrollmentTests", test: name, socket: "s")
        defer { try? FileManager.default.removeItem(at: root) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let path = root.appendingPathComponent("s").path
        let request = try NativePeerEnrollment.PrivateRequest(
            operation: .exportTarget,
            operationID: UUID.makeVersion1().uuidString.lowercased(), byteCount: 0
        ).encoded()
        let entered = expectation(description: "output held")
        let cancelled = expectation(description: "output cancellation held")
        let outputGate = EnrollmentOutputGate(entered)
        let cancelGate = EnrollmentOutputGate(cancelled)
        defer {
            await outputGate.release()
            await cancelGate.release()
        }
        let calls = Mutex(0)
        let listener = try await DaemonListeners.unixWithPrivateCredential(
            group: group, socketPath: path,
            permissions: 0o600, managed: false, connectionLimitForTesting: 3, handler: { _, _ in Data() },
            privateBegin: { _, _, _ in throw NativePeerEnrollment.failure() },
            enrollmentBegin: { _, uid, _ in
                XCTAssertEqual(uid, tractanda_uid())
                let call = calls.withLock {
                    $0 += 1
                    return $0
                }
                return .init(
                    operation: .exportTarget, byteCount: 0,
                    commit: { input in
                        XCTAssertNil(input)
                        if call == 3 { await outputGate.wait() }
                        // Synthetic transport boundary bytes, deliberately not an accepted activation record.
                        return Data(
                            repeating: 0x5a,
                            count: NativePeerEnrollment.maximumTargetOutputBytes + (call == 2 ? 1 : 0))
                    }, cancel: { if call == 3 { await cancelGate.wait() } })
            })
        defer {
            await outputGate.release()
            await cancelGate.release()
            try? await listener.close()
        }
        let exchange: @Sendable () async throws -> Int = {
            try await Task.detached {
                let fd = tractanda_connect(path)
                guard fd >= 0 else { throw NativePeerEnrollment.failure() }
                defer { tractanda_close(fd) }
                let deadline = tractanda_private_io_begin(fd)
                guard
                    request.withUnsafeBytes({
                        tractanda_private_send_begin(fd, $0.baseAddress, UInt32($0.count), deadline)
                    }) == 0
                else { throw NativePeerEnrollment.failure() }
                var pointer: UnsafeMutableRawPointer?
                var count: UInt32 = 0
                guard tractanda_private_receive_frame(fd, &pointer, &count, 4096, deadline) == 0,
                    let ready = pointer
                else { throw NativePeerEnrollment.failure() }
                XCTAssertEqual(Data(bytes: ready, count: Int(count)), NativePeerEnrollment.ready)
                tractanda_private_free(ready, count)
                pointer = nil
                count = 0
                guard tractanda_private_receive_frame(fd, &pointer, &count, 135184, deadline) == 0,
                    let body = pointer
                else { throw NativePeerEnrollment.failure() }
                defer { tractanda_private_free(body, count) }
                return Int(count)
            }.value
        }
        let exactSize = try await exchange()
        let oversizedSize = try await exchange()
        XCTAssertEqual(exactSize, 135184)
        XCTAssertLessThan(
            oversizedSize, 135184,
            "An oversized callback result must become a bounded error, never a larger private body.")
        let receiving = Task { try await exchange() }
        await fulfillment(of: [entered], timeout: 5)
        await listener.closeChildrenForTesting()
        await fulfillment(of: [cancelled], timeout: 5)
        let closingStarted = expectation(description: "output listener close started")
        let closed = Mutex(false)
        let closing = Task {
            closingStarted.fulfill()
            try await listener.close()
            closed.withLock { $0 = true }
        }
        await fulfillment(of: [closingStarted], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(closed.withLock { $0 })
        await outputGate.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(closed.withLock { $0 }, "Private cancellation remains part of the owned child drain.")
        await cancelGate.release()
        try await closing.value
        _ = try? await receiving.value
        XCTAssertEqual(calls.withLock { $0 }, 3)
    }
}
