import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

private final class RuntimeAccounts: AccountDirectory, @unchecked Sendable {
    let base: any AccountDirectory
    init(_ base: any AccountDirectory) { self.base = base }
    func user(forUID uid: UInt32) throws -> AccountIdentity { try base.user(forUID: uid) }
    func user(named name: String) throws -> AccountIdentity { try base.user(named: name) }
    func groupID(named name: String) throws -> UInt32 { try base.groupID(named: name) }
}

private actor RuntimeDeliveryPause {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(entered: XCTestExpectation) async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class PeerRuntimeSnapshotTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private let secret = Array("private-test-key-never-exported!".utf8)

    private func credential(_ f: Fixture, context: PeerPackage.Context? = nil) throws -> PeerCredential {
        let context = context ?? f.context!
        return try PeerCredential(
            binding: .init(
                peerID: context.peerID, storeID: f.storeID,
                localReplicaID: XCTUnwrap(f.receiver.replicaID), remoteReplicaID: f.origin,
                pairingID: Fixture.id(), localIsInitiator: false,
                configurationDigest: context.configurationDigest), secret: secret)
    }
    private func register(_ f: Fixture, context: PeerPackage.Context? = nil) throws -> PeerCredential {
        let value = try credential(f, context: context)
        try f.receiver.registerPeerCredential(
            value, context: context ?? f.context,
            expectedContextToken: f.receiver.peerIntakeContextToken(), operationID: Fixture.id())
        return value
    }
    private func coordinator(_ f: Fixture) async throws -> ServiceCoordinator {
        let accounts = RuntimeAccounts(f.receiverAccounts)
        f.receiver = nil
        return try await ServiceCoordinator(
            opening: f.receiverRoot, embeddingProviderForTesting: nil,
            revisionProjectionEnabledForTesting: true, authorityIntakeEnabledForTesting: true,
            makeAccountDirectory: { accounts })
    }
    private func keyPath(_ f: Fixture, _ value: PeerCredential) throws -> URL {
        try PeerCredentialStore.path(
            peerID: value.binding.peerID,
            configurationDigest: value.binding.configurationDigest
        ).reduce(f.receiverRoot) {
            $0.appendingPathComponent($1)
        }
    }
    private func expect(
        _ code: String, _ body: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected " + code, file: file, line: line)
        } catch {
            XCTAssertEqual((error as? TractandaError)?.code, code, file: file, line: line)
            XCTAssertFalse(
                String(reflecting: error).contains(String(decoding: secret, as: UTF8.self)),
                file: file, line: line)
        }
    }

    func testCommittedOnlySortedUnattendedSnapshotAndRedaction() async throws {
        let f = try Fixture()
        try f.bootstrap()
        XCTAssertTrue(try f.receiver.peerRuntimeMaterial().credentials.isEmpty)
        let alpha = try PeerPackage.Context(
            peerID: "alpha", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("runtime-alpha".utf8)),
            permittedOrigins: f.context.permittedOrigins)
        try f.receiver.configurePeerIntake(peers: [f.context, alpha])
        _ = try register(f)
        _ = try register(f, context: alpha)
        let stagedContext = try PeerPackage.Context(
            peerID: "staged-only", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("runtime-staged".utf8)),
            permittedOrigins: f.context.permittedOrigins)
        let staged = try credential(f, context: stagedContext)
        try PeerCredentialStore(
            files: DocumentContentFiles(
                root: f.receiverRoot,
                ownerUID: tractanda_uid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        ).stage(staged)
        let service = try await coordinator(f)
        defer { await service.close() }
        // No UID, login or registration request is supplied to either runtime operation.
        let snapshot = try await service.loadPeerRuntimeSnapshot()
        XCTAssertEqual(snapshot.credentials.map(\.binding.peerID), ["alpha", f.context.peerID])
        XCTAssertEqual(snapshot.credentials.map(\.binding.localIsInitiator), [false, false])
        XCTAssertEqual(String(reflecting: snapshot), "PeerRuntimeSnapshot(<redacted>)")
        XCTAssertEqual(Mirror(reflecting: snapshot).children.count, 0)
        XCTAssertFalse(snapshot.securityToken.contains(String(decoding: secret, as: UTF8.self)))
        try await service.validatePeerRuntimeSnapshot(snapshot)
        try f.capacity()
    }

    func testOrdinaryWritePreservesSecurityButPolicyAndRotationFenceIt() throws {
        let f = try Fixture()
        try f.bootstrap()
        _ = try register(f)
        let before = try f.receiver.peerRuntimeMaterial()
        _ = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                .init(
                    action: .revise, itemID: f.base.itemID,
                    expectedRevisionID: f.base.revisionID,
                    changes: ["subject": .text("ordinary runtime write")],
                    operationID: "runtime-ordinary"))
        }
        try before.requireCurrent(f.receiver.peerRuntimeMaterial())
        _ = try f.receiver.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice")]),
            ]), operationID: "runtime-policy")
        XCTAssertThrowsError(try before.requireCurrent(f.receiver.peerRuntimeMaterial()))
        let afterPolicy = try f.receiver.peerRuntimeMaterial()
        let rotated = try PeerPackage.Context(
            peerID: f.context.peerID, storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("runtime-rotation".utf8)),
            permittedOrigins: f.context.permittedOrigins)
        _ = try register(f, context: rotated)
        XCTAssertThrowsError(try afterPolicy.requireCurrent(f.receiver.peerRuntimeMaterial()))
        XCTAssertEqual(
            try f.receiver.peerRuntimeMaterial().credentials.first?.binding.configurationDigest,
            rotated.configurationDigest)
        try f.capacity()
    }

    func testDisposedRemoteIsOmittedWithoutAdmittingRetainedSnapshot() throws {
        let f = try Fixture()
        try f.bootstrap()
        _ = try register(f)
        let local = try XCTUnwrap(f.receiver.replicaID)
        let retirement = try PeerPackage.Context(
            peerID: "runtime-isolation", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("runtime-isolation".utf8)),
            permittedOrigins: [local, f.origin].sorted())
        try f.receiver.configurePeerIntake(peers: [f.context, retirement])
        let before = try f.receiver.peerRuntimeMaterial()
        try f.receiver.removePeerIntake(
            peerID: retirement.peerID, retiredOriginIDs: [f.origin],
            operationID: Fixture.id())
        XCTAssertTrue(try f.receiver.peerRuntimeMaterial().credentials.isEmpty)
        XCTAssertThrowsError(try before.requireCurrent(f.receiver.peerRuntimeMaterial()))
        try f.capacity()
    }

    func testRetainedSnapshotRejectsMissingMalformedAndSubstitutedPrivateBytesWithoutRepair() async throws {
        let f = try Fixture()
        try f.bootstrap()
        let value = try register(f)
        let path = try keyPath(f, value)
        let original = try Data(contentsOf: path)
        let service = try await coordinator(f)
        defer { await service.close() }
        let snapshot = try await service.loadPeerRuntimeSnapshot()
        try FileManager.default.removeItem(at: path)
        await expect("invalidPeerCredential") { try await service.validatePeerRuntimeSnapshot(snapshot) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        try Data([0xff]).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        await expect("invalidPeerCredential") { try await service.validatePeerRuntimeSnapshot(snapshot) }
        try FileManager.default.removeItem(at: path)
        var substituted = original
        substituted[substituted.count - 1] ^= 1
        try substituted.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        await expect("peerConfigurationChanged") { try await service.validatePeerRuntimeSnapshot(snapshot) }
        XCTAssertEqual(try Data(contentsOf: path), substituted)
        // Exact explicit fixture restoration is separate from runtime validation.
        try FileManager.default.removeItem(at: path)
        try original.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        try await service.validatePeerRuntimeSnapshot(snapshot)
        try f.capacity()
    }

    func testCoordinatorRestartCannotAcceptPreviousInstanceSnapshot() async throws {
        let f = try Fixture()
        try f.bootstrap()
        _ = try register(f)
        let initial = try await coordinator(f)
        let snapshot = try await initial.loadPeerRuntimeSnapshot()
        await initial.close()
        let restarted = try await coordinator(f)
        defer { await restarted.close() }
        await expect("peerConfigurationChanged") { try await restarted.validatePeerRuntimeSnapshot(snapshot) }
        _ = try await restarted.loadPeerRuntimeSnapshot()
        try f.capacity()
    }

    func testCancellationAndShutdownFenceCapturedSnapshotDelivery() async throws {
        let f = try Fixture()
        try f.bootstrap()
        _ = try register(f)
        let service = try await coordinator(f)
        let cancelledGate = RuntimeDeliveryPause()
        let cancelled = expectation(description: "cancellable snapshot")
        defer {
            await cancelledGate.release()
            await service.close()
        }
        await service.setPeerRuntimeSnapshotDeliveryHookForTesting {
            await cancelledGate.wait(entered: cancelled)
        }
        let cancellation = Task { try await service.loadPeerRuntimeSnapshot() }
        await fulfillment(of: [cancelled], timeout: 5)
        cancellation.cancel()
        await cancelledGate.release()
        await expect("cancelled") { _ = try await cancellation.value }
        let closingGate = RuntimeDeliveryPause()
        let closing = expectation(description: "closing snapshot")
        defer { await closingGate.release() }
        await service.setPeerRuntimeSnapshotDeliveryHookForTesting {
            await closingGate.wait(entered: closing)
        }
        let loading = Task { try await service.loadPeerRuntimeSnapshot() }
        await fulfillment(of: [closing], timeout: 5)
        await service.requestBackgroundStop()
        await expect("serviceClosed") { _ = try await service.loadPeerRuntimeSnapshot() }
        let shutdown = Task { await service.close() }
        var fenced = false
        for _ in 0..<100 {
            do { _ = try await service.loadPeerCredential(peerID: f.context.peerID) } catch let error
                as TractandaError where error.code == "serviceClosed"
            {
                fenced = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(fenced)
        await closingGate.release()
        await expect("serviceClosed") { _ = try await loading.value }
        await shutdown.value
        try f.capacity()
    }

}
