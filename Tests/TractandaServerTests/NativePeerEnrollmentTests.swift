import CTractandaPlatform
import Foundation
import NIOCore
import NIOPosix
import Synchronization
import XCTest
@testable import TractandaCore
@testable import TractandaServer

private final class EnrollmentOperatorAccounts: AccountDirectory, @unchecked Sendable {
    let administrator = Mutex(true)
    func user(forUID uid: UInt32) throws -> AccountIdentity {
        guard uid == tractanda_uid() else { throw TractandaError("unresolvedPrincipal", "Unknown isolated native user.") }
        return .init(uid: uid, name: "human", primaryGroupName: "staff", groupIDs: administrator.withLock { $0 } ? [71001] : [])
    }
    func user(named name: String) throws -> AccountIdentity {
        guard name == "human" else { throw TractandaError("unresolvedPrincipal", "Unknown isolated native user.") }
        return try user(forUID: tractanda_uid())
    }
    func groupID(named name: String) throws -> UInt32 {
        guard ["staff", "admin", "sudo"].contains(name) else { throw TractandaError("unresolvedPrincipal", "Unknown isolated group.") }
        return 71001
    }
}
private final class EnrollmentOperatorFixture {
    let root: URL, sourceRoot: URL, targetRoot: URL
    let accounts = EnrollmentOperatorAccounts()
    var source: ItemStore!
    let input: PeerEnrollmentPairInput
    let operation: String
    init(test: String) throws {
        try PeerFixtureCapacity.requireFree()
        root = try GuardedFixtureDirectory.create(prefix: "e", source: "NativePeerEnrollmentTests", test: test, socket: "s")
        sourceRoot = root.appendingPathComponent("source"); targetRoot = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        source = try ItemStore.initializeFresh(root: sourceRoot, accounts: accounts, initialAccessConfiguration: .object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("human")]),
            "administration": .text("system"), "administratorGroup": .text("staff")]))
        let storeID = try CanonicalReaderRequirement.storeIdentity(root: sourceRoot, ownerUID: tractanda_uid())
        let prep = try PeerEnrollment.prepareTarget(root: targetRoot, commonStoreID: storeID, sourceReplicaID: XCTUnwrap(source.replicaID))
        let preparation = root.appendingPathComponent("preparation"), pair = root.appendingPathComponent("pair")
        try JSON.encode(prep).write(to: preparation)
        _ = try NativePeerEnrollment.createPair(preparationPath: preparation.path, outputPath: pair.path,
            sourcePeerID: "target", targetPeerID: "source", sourceIsInitiator: true)
        input = try .capture(path: pair.path); operation = try input.operationID
        try capacity()
    }
    deinit { source = nil; try? FileManager.default.removeItem(at: root) }
    func accept() throws {
        _ = try source.nativeEnrollmentBegin(input, forUID: tractanda_uid())
        var ready = false
        for _ in 0..<1024 {
            try capacity()
            let data = try source.nativeEnrollmentCall(.init(action: "step", operationID: operation), forUID: tractanda_uid())
            if try JSON.decode(PeerEnrollmentOperatorStatus.self, data).phase == "ready" { ready = true; break }
        }
        guard ready else { throw TractandaError("testTimeout", "Finite native enrollment did not finish.") }
        _ = try source.nativeEnrollmentCall(.init(action: "accept", operationID: operation), forUID: tractanda_uid())
    }
    func capacity() throws {
        try PeerFixtureCapacity.requireFree(at: root)
        var size: UInt64 = 0, entries = 0
        let scan = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        while let file = scan.nextObject() as? URL {
            entries += 1
            guard entries <= 4096 else { throw TractandaError("resourceLimit", "Native enrollment fixture entry cap.") }
            let m = try FileMetadata.read(at: file)
            if m.type == .regular {
                guard m.size <= PeerFixtureCapacity.fixtureCapBytes - min(size, PeerFixtureCapacity.fixtureCapBytes)
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
    func release() { released = true; continuation?.resume(); continuation = nil }
}

final class NativePeerEnrollmentTests: XCTestCase {
    func testKernelNativeEnrollmentExportsOnlyAcceptedTargetBytesAndGenericRoutesDeny() async throws {
        let f = try EnrollmentOperatorFixture(test: name), accounts = f.accounts
        f.source = nil
        let socket = f.root.appendingPathComponent("s")
        let daemon = try await SharedDaemon.startForTesting(configuration: .init(storePath: f.sourceRoot.path,
            socketPath: socket.path, httpPort: nil), makeAccountDirectory: { accounts })
        defer { await daemon.close() }
        let connection = ServerConnection(socketPath: socket.path), input = f.input, operation = f.operation
        let began = try await Task.detached { try NativePeerEnrollment.begin(connection: connection, input: input) }.value
        XCTAssertEqual(try JSON.decode(PeerEnrollmentOperatorStatus.self, began).phase, "pending")
        var ready = false
        for _ in 0..<1024 {
            try f.capacity()
            let result = try await Task.detached { try NativePeerEnrollment.call(connection: connection,
                action: .step, operationID: operation) }.value
            if try JSON.decode(PeerEnrollmentOperatorStatus.self, result).phase == "ready" { ready = true; break }
        }
        XCTAssertTrue(ready)
        let accepted = try await Task.detached { try NativePeerEnrollment.call(connection: connection,
            action: .accept, operationID: operation) }.value
        XCTAssertEqual(try JSON.decode(PeerEnrollmentOperatorStatus.self, accepted).phase, "accepted")
        let output = f.root.appendingPathComponent("target.private").path
        for _ in 0..<2 {
            let exported = try await Task.detached { try NativePeerEnrollment.exportTarget(connection: connection,
                operationID: operation, outputPath: output) }.value
            XCTAssertEqual(try JSON.decode(PeerEnrollmentOperatorStatus.self, exported).phase, "exported")
        }
        let encoded = try Data(contentsOf: URL(fileURLWithPath: output))
        let (record, credential) = try PeerEnrollmentTargetOutput.decode(encoded)
        XCTAssertEqual(credential.binding.localReplicaID, try record.preparation.targetReplicaID)
        XCTAssertNotEqual(credential.binding.localReplicaID, try record.preparation.sourceReplicaID)
        let descriptor = f.root.appendingPathComponent("descriptor"), chunk = f.root.appendingPathComponent("chunk").path
        try JSON.encode(record.baseline.root).write(to: descriptor)
        _ = try await Task.detached { try NativePeerEnrollment.readObject(connection: connection, operationID: operation,
            descriptorPath: descriptor.path, offset: 0, maximumBytes: 1024, outputPath: chunk) }.value
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: chunk)).count, min(1024, record.baseline.root.length))
        let registered = try await Task.detached { try NativePeerEnrollment.call(connection: connection,
            action: .register, operationID: operation) }.value
        XCTAssertEqual(try JSON.decode(PeerEnrollmentOperatorStatus.self, registered).phase, "registered")
        await daemon.close()
        let coordinator = try await ServiceCoordinator(opening: f.sourceRoot, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
        defer { await coordinator.close() }
        let sessions = SessionAuthority(coordinator: coordinator)
        let app = DaemonApplication(coordinator: coordinator, sessions: sessions, page: Data(), manual: Data(), nonce: "enrollment")
        defer { await app.close() }
        let token = try await sessions.issue(forUID: tractanda_uid()).token
        let request = try PeerEnrollmentNativeCall(action: "status", operationID: operation).encoded()
        let generic = try await sessions.dispatch(request, token: token)
        XCTAssertTrue(String(decoding: generic, as: UTF8.self).contains("unknownMethod"))
        let http = try await app.http(.init(method: "POST", uri: "/api", headers: ["host": ["127.0.0.1:48730"],
            "content-type": ["application/json"], "authorization": ["Bearer " + token]], body: request, localPort: 48730))
        XCTAssertTrue(String(decoding: http.body, as: UTF8.self).contains("unknownMethod"))
        XCTAssertThrowsError(try ItemStore.requireInitializedRoot(f.targetRoot))
        try f.capacity()
    }
    func testExportReauthorizesActualAccountAfterPreparedAwaitBeforeAnyPrivateDelivery() async throws {
        guard tractanda_uid() != 0 else { throw XCTSkip("Root repair policy is distinct from administrator demotion.") }
        let f = try EnrollmentOperatorFixture(test: name)
        try f.accept(); f.source = nil
        let accounts = f.accounts
        let coordinator = try await ServiceCoordinator(opening: f.sourceRoot, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
        defer { await coordinator.close() }
        let sessions = SessionAuthority(coordinator: coordinator)
        let app = DaemonApplication(coordinator: coordinator, sessions: sessions, page: Data(), manual: Data(), nonce: "enrollment")
        defer { await app.close() }
        let entered = expectation(description: "output prepared before final delivery"), gate = EnrollmentOutputGate(entered)
        await coordinator.setNativeEnrollmentPreparedHookForTesting { await gate.wait() }
        defer { await gate.release(); await coordinator.setNativeEnrollmentPreparedHookForTesting(nil) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let path = f.root.appendingPathComponent("s").path
        let listener = try await DaemonListeners.unixWithPrivateCredential(group: group, socketPath: path,
            permissions: 0o600, managed: false, handler: { data, uid in try await app.native(data, forUID: uid) },
            privateBegin: { data, uid, control in try await app.makePrivateCredentialSession(NativePeerCredentialRegistration.Begin.parse(data), forUID: uid, control: control) },
            enrollmentBegin: { data, uid, control in try await app.beginPrivateEnrollment(data, forUID: uid, control: control) })
        defer { await gate.release(); try? await listener.close() }
        let operation = f.operation, output = f.root.appendingPathComponent("must-not-exist").path
        let sending = Task.detached { try NativePeerEnrollment.exportTarget(connection: ServerConnection(socketPath: path),
            operationID: operation, outputPath: output) }
        await fulfillment(of: [entered], timeout: 5)
        // Only the account directory changes. No Store write/generation invalidation can stand in for current-admin authorization.
        accounts.administrator.withLock { $0 = false }
        await gate.release()
        do { _ = try await sending.value; XCTFail("A prepared private output is not a lasting administrator grant.") }
        catch {
            XCTAssertEqual((error as? TractandaError)?.code, "forbidden")
            XCTAssertFalse(String(describing: error).contains("TPTARG01"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        accounts.administrator.withLock { $0 = true }
        let keyEntered = expectation(description: "output prepared before exact private witness changes")
        let keyGate = EnrollmentOutputGate(keyEntered)
        defer { await keyGate.release() }
        await coordinator.setNativeEnrollmentPreparedHookForTesting { await keyGate.wait() }
        let keyOutput = f.root.appendingPathComponent("changed-key-must-not-exist").path
        let keySending = Task.detached { try NativePeerEnrollment.exportTarget(connection: ServerConnection(socketPath: path),
            operationID: operation, outputPath: keyOutput) }
        await fulfillment(of: [keyEntered], timeout: 5)
        let pair = try f.input.withBytes { try PeerEnrollmentPairInput.decode($0) }
        let keyParts = try [PeerEnrollmentApproval.directory, operation, "remote"] + PeerCredentialStore.path(
            peerID: pair.targetCredential.binding.peerID, configurationDigest: pair.targetCredential.binding.configurationDigest)
        let key = keyParts.reduce(f.sourceRoot) { $0.appendingPathComponent($1) }
        let original = try Data(contentsOf: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        var changed = original; changed[changed.count - 1] ^= 1
        try changed.write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: key.path)
        await keyGate.release()
        do { _ = try await keySending.value; XCTFail("The final gate must re-read exact private bytes after the await.") }
        catch {
            XCTAssertEqual((error as? TractandaError)?.code, "enrollmentReviewRequired")
            XCTAssertFalse(String(describing: error).contains("TPTARG01"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyOutput))
        try await listener.close(); try f.capacity()
    }
    func testBinaryTargetOutputUsesActualBoundAndListenerDrainsHeldOutputAndCancel() async throws {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(prefix: "e", source: "NativePeerEnrollmentTests", test: name, socket: "s")
        defer { try? FileManager.default.removeItem(at: root) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let path = root.appendingPathComponent("s").path
        let request = try NativePeerEnrollment.PrivateRequest(operation: .exportTarget,
            operationID: UUID.makeVersion1().uuidString.lowercased(), byteCount: 0).encoded()
        let entered = expectation(description: "output held"), cancelled = expectation(description: "output cancellation held")
        let outputGate = EnrollmentOutputGate(entered), cancelGate = EnrollmentOutputGate(cancelled)
        defer { await outputGate.release(); await cancelGate.release() }
        let calls = Mutex(0)
        let listener = try await DaemonListeners.unixWithPrivateCredential(group: group, socketPath: path,
            permissions: 0o600, managed: false, connectionLimitForTesting: 3, handler: { _, _ in Data() },
            privateBegin: { _, _, _ in throw NativePeerEnrollment.failure() }, enrollmentBegin: { _, uid, _ in
                XCTAssertEqual(uid, tractanda_uid())
                let call = calls.withLock { $0 += 1; return $0 }
                return .init(operation: .exportTarget, byteCount: 0, commit: { input in
                    XCTAssertNil(input)
                    if call == 3 { await outputGate.wait() }
                    // Synthetic transport boundary bytes, deliberately not an accepted activation record.
                    return Data(repeating: 0x5a, count: NativePeerEnrollment.maximumTargetOutputBytes + (call == 2 ? 1 : 0))
                }, cancel: { if call == 3 { await cancelGate.wait() } })
            })
        defer { await outputGate.release(); await cancelGate.release(); try? await listener.close() }
        let exchange: @Sendable () async throws -> Int = {
            try await Task.detached {
                let fd = tractanda_connect(path); guard fd >= 0 else { throw NativePeerEnrollment.failure() }
                defer { tractanda_close(fd) }
                let deadline = tractanda_private_io_begin(fd)
                guard request.withUnsafeBytes({ tractanda_private_send_begin(fd, $0.baseAddress, UInt32($0.count), deadline) }) == 0
                else { throw NativePeerEnrollment.failure() }
                var pointer: UnsafeMutableRawPointer?, count: UInt32 = 0
                guard tractanda_private_receive_frame(fd, &pointer, &count, 4096, deadline) == 0, let ready = pointer else { throw NativePeerEnrollment.failure() }
                XCTAssertEqual(Data(bytes: ready, count: Int(count)), NativePeerEnrollment.ready); tractanda_private_free(ready, count)
                pointer = nil; count = 0
                guard tractanda_private_receive_frame(fd, &pointer, &count, 135184, deadline) == 0, let body = pointer else { throw NativePeerEnrollment.failure() }
                defer { tractanda_private_free(body, count) }
                return Int(count)
            }.value
        }
        let exactSize = try await exchange(), oversizedSize = try await exchange()
        XCTAssertEqual(exactSize, 135184)
        XCTAssertLessThan(oversizedSize, 135184, "An oversized callback result must become a bounded error, never a larger private body.")
        let receiving = Task { try await exchange() }
        await fulfillment(of: [entered], timeout: 5)
        await listener.closeChildrenForTesting()
        await fulfillment(of: [cancelled], timeout: 5)
        let closingStarted = expectation(description: "output listener close started"), closed = Mutex(false)
        let closing = Task { closingStarted.fulfill(); try await listener.close(); closed.withLock { $0 = true } }
        await fulfillment(of: [closingStarted], timeout: 5)
        try await Task.sleep(for: .milliseconds(100)); XCTAssertFalse(closed.withLock { $0 })
        await outputGate.release()
        try await Task.sleep(for: .milliseconds(100)); XCTAssertFalse(closed.withLock { $0 }, "Private cancellation remains part of the owned child drain.")
        await cancelGate.release(); try await closing.value
        _ = try? await receiving.value
        XCTAssertEqual(calls.withLock { $0 }, 3)
    }
}
