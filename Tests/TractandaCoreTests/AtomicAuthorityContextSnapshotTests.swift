import CSQLite
import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class AtomicAuthorityContextSnapshotTests: XCTestCase {
    private let expected = String(repeating: "a", count: 64)
    private typealias Fixture = PeerIntakeStoreTests.Fixture
    private func setup(_ f: Fixture) throws -> (ItemIndex, PeerIntakeCoordinator, String) {
        try f.bootstrap()
        let index = try ItemIndex(
            path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        let coordinator = PeerIntakeCoordinator(
            root: f.receiverRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let pin = try XCTUnwrap(coordinator.configuration()?.bootstrap)
        let packageID = try XCTUnwrap(index.retainedAuthorityObject(id: pin.recordID)).packageID
        return (index, coordinator, packageID)
    }
    private func privateRoot(_ directory: URL) throws -> URL {
        try AttachmentFixtureCapacity.requireFree(at: directory)
        let result = directory.appendingPathComponent("context-" + (try Fixture.id()))
        try FileManager.default.createDirectory(
            at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return result
    }
    private func walkCount(_ index: ItemIndex) throws -> Int64 {
        let s = try index.corpusPrepare(
            "SELECT COUNT(*) FROM authority_walk WHERE token LIKE 'atomic-context:%'")
        defer { sqlite3_finalize(s) }
        guard index.catalogueStep(s) == SQLITE_ROW else { throw index.graphSQLiteError() }
        return sqlite3_column_int64(s, 0)
    }
    private func capture(
        _ index: ItemIndex, _ coordinator: PeerIntakeCoordinator, _ packageID: String, _ directory: URL,
        rootID: String, current: (() throws -> String)? = nil, progress: (() throws -> Void)? = nil
    ) throws -> AtomicAuthorityAcceptance.Context {
        try AtomicAuthorityContextSnapshot.prepare(
            index: index, coordinator: coordinator, rootID: rootID, packageID: packageID,
            privateRoot: directory, maximumStoredBytes: 4 * 1024 * 1024, requestPrincipal: "user:admin",
            expectedContextSHA256: expected, currentContext: current ?? { self.expected }, progress: progress)
    }
    private func originals(
        _ context: AtomicAuthorityAcceptance.Context, coordinator: PeerIntakeCoordinator, packageID: String,
        rootID: String
    ) throws -> [PeerPackage.Object] {
        let publication = try XCTUnwrap(coordinator.journal.publication(packageID))
        let identity = try XCTUnwrap(
            ReplicaIdentity.load(
                root: coordinator.root, storeID: coordinator.storeID, ownerUID: tractanda_uid()))
        let receipt = try AtomicAuthorityAcceptance.Receipt(
            storeID: coordinator.storeID, receiverReplicaID: identity.replicaID,
            root: .init(recordID: rootID, sha256: expected), packageID: packageID,
            manifestSHA256: publication.manifestDigest, validationContextSHA256: expected, context: context)
        var result: [PeerPackage.Object] = []
        try coordinator.journal.walkUntrustedAtomicContext(receipt) { result.append($0) }
        return result
    }

    func testCapturedContextIsOrderedDeduplicatedStagedAndExactlyRetryableWithoutAcceptance() throws {
        let f = try Fixture()
        let (index, coordinator, packageID) = try setup(f)
        defer { index.close() }
        let rootID = try Fixture.id()
        let directory = try privateRoot(f.directory)
        let before = try index.acceptedControlHeadFrontierSHA256()
        let context = try capture(index, coordinator, packageID, directory, rootID: rootID)
        let values = try originals(context, coordinator: coordinator, packageID: packageID, rootID: rootID)
        XCTAssertEqual(values.map(\.id), Array(Set(values.map(\.id))).sorted())
        XCTAssertEqual(context.authorityCount, Int64(values.count))
        XCTAssertEqual(context.authorities.packageID, rootID)
        XCTAssertNotEqual(context.authorities.packageID, packageID)
        XCTAssertEqual(context.requestPrincipal, "user:admin")
        let bootstrap = try XCTUnwrap(coordinator.configuration()?.bootstrap)
        XCTAssertTrue(values.contains { $0.id == bootstrap.recordID && $0.sha256 == bootstrap.sha256 })
        for head in try index.atomicCurrentHeadPage() {
            XCTAssertTrue(values.contains { $0.id == head.recordID && $0.sha256 == head.sha256 })
        }
        let configuration = try coordinator.journal.files.read(
            path: [".peer-configuration", context.configuration.fileName],
            maximumBytes: PeerPackage.maximumPageBytes)
        XCTAssertEqual(context.configuration.sha256, AuthorityRecordCodec.sha256(configuration))
        XCTAssertEqual(try capture(index, coordinator, packageID, directory, rootID: rootID), context)
        XCTAssertEqual(try index.acceptedControlHeadFrontierSHA256(), before)
        XCTAssertNil(
            try coordinator.journal.atomicAcceptance(
                packageID: packageID, root: .init(recordID: rootID, sha256: expected)))
        XCTAssertEqual(try walkCount(index), 0)
        try f.capacity()
    }

    func testRealCanonicalAdmissionAndRetirementRootsAreCapturedWithoutCredentialExport() throws {
        let f = try PeerEnrollmentApprovalTests.Fixture()
        let handle = try f.begin()
        _ = try f.ready(handle)
        let accepted = try f.source.acceptPeerEnrollment(handle, forUID: f.uid)
        let approval = try XCTUnwrap(accepted.approval)
        let target = f.request.sourceCredential.binding.remoteReplicaID
        try f.source.withAccess(forUID: f.uid) {
            try f.source.configurePeerIntake(peers: [f.request.sourceContext])
            try f.source.removePeerIntake(
                peerID: f.request.sourceContext.peerID, retiredOriginIDs: [target], operationID: Fixture.id())
        }
        let storeID = f.request.sourceContext.storeID
        let coordinator = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: storeID)
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let packageID = try XCTUnwrap(index.retainedAuthorityObject(id: approval.recordID)).packageID
        let rootID = try Fixture.id()
        let directory = try privateRoot(f.root)
        let context = try capture(index, coordinator, packageID, directory, rootID: rootID)
        let values = try originals(context, coordinator: coordinator, packageID: packageID, rootID: rootID)
        XCTAssertTrue(values.contains { $0.id == approval.recordID && $0.sha256 == approval.sha256 })
        let retirement = try XCTUnwrap(coordinator.configuration()?.lifecycle?.retirements.last?.root)
        XCTAssertTrue(values.contains { $0.id == retirement.recordID && $0.sha256 == retirement.sha256 })
        XCTAssertTrue(values.allSatisfy { $0.kind == .authority && $0.part == nil })
        XCTAssertEqual(try walkCount(index), 0)
        try f.capacity()
    }

    func testConflictingCanonicalAdmissionHashFailsAndCleansOwnedWalk() throws {
        let f = try Fixture()
        let (index, coordinator, packageID) = try setup(f)
        defer { index.close() }
        let pin = try XCTUnwrap(coordinator.configuration()?.bootstrap)
        let retained = try XCTUnwrap(index.retainedAuthorityObject(id: pin.recordID))
        let target = try Fixture.id()
        let conflict = PeerPackage.Object(
            kind: .authority, id: pin.recordID, length: retained.descriptor.length, sha256: expected)
        let decision = try PeerOriginAdmission.Decision(
            profile: PeerOriginAdmission.capability, target: target, approval: conflict,
            packageID: packageID, issuerAdmission: .init(recordID: pin.recordID, sha256: pin.sha256))
        try coordinator.journal.files.writeImmutable(
            JSON.encode(decision), path: [PeerOriginAdmission.directory, target],
            maximumBytes: PeerPackage.maximumPageBytes)
        let directory = try privateRoot(f.directory)
        XCTAssertThrowsError(try capture(index, coordinator, packageID, directory, rootID: Fixture.id()))
        XCTAssertEqual(try walkCount(index), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("root.json").path))
        try f.capacity()
    }

    func testContextDriftAfterFramingReturnsNoContextAndCleansOwnedWalk() throws {
        let f = try Fixture()
        let (index, coordinator, packageID) = try setup(f)
        defer { index.close() }
        var checks = 0
        let directory = try privateRoot(f.directory)
        XCTAssertThrowsError(
            try capture(
                index, coordinator, packageID, directory, rootID: Fixture.id(),
                current: {
                    checks += 1
                    return checks < 3 ? self.expected : String(repeating: "b", count: 64)
                }))
        XCTAssertGreaterThanOrEqual(checks, 3)
        XCTAssertEqual(try walkCount(index), 0)
        try f.capacity()
    }

    func testSameValueNewCanonicalConfigurationSequenceInvalidatesCapture() throws {
        let f = try Fixture()
        let (index, coordinator, packageID) = try setup(f)
        defer { index.close() }
        let configured = try XCTUnwrap(coordinator.configuration())
        let next = try AuthorityStore.configurationSequence(root: f.receiverRoot) + 1
        var changed = false
        let directory = try privateRoot(f.directory)
        XCTAssertThrowsError(
            try capture(
                index, coordinator, packageID, directory, rootID: Fixture.id(),
                progress: {
                    guard !changed, try self.walkCount(index) > 0 else { return }
                    changed = true
                    try coordinator.journal.files.writeImmutable(
                        JSON.encode(configured),
                        path: [".peer-configuration", String(format: "%020llu.json", next)],
                        maximumBytes: PeerPackage.maximumPageBytes)
                }))
        XCTAssertTrue(changed)
        XCTAssertEqual(try walkCount(index), 0)
        try f.capacity()
    }

    func testProgressCancellationCleansWalkAndAllowsFreshPrivateRetry() throws {
        let f = try Fixture()
        let (index, coordinator, packageID) = try setup(f)
        defer { index.close() }
        var cancelled = false
        let directory = try privateRoot(f.directory)
        let rootID = try Fixture.id()
        XCTAssertThrowsError(
            try capture(
                index, coordinator, packageID, directory, rootID: rootID,
                progress: {
                    guard !cancelled, try self.walkCount(index) > 0 else { return }
                    cancelled = true
                    throw CancellationError()
                }))
        XCTAssertTrue(cancelled)
        XCTAssertEqual(try walkCount(index), 0)
        _ = try capture(index, coordinator, packageID, directory, rootID: rootID)
        XCTAssertEqual(try walkCount(index), 0)
        try f.capacity()
    }

    func testIncompletePhysicalPackageAndUnsafeConfigurationFailBeforeContextPublication() throws {
        let f = try Fixture()
        let (index, coordinator, packageID) = try setup(f)
        defer { index.close() }
        let directory = try privateRoot(f.directory)
        XCTAssertThrowsError(try capture(index, coordinator, Fixture.id(), directory, rootID: Fixture.id()))
        try coordinator.journal.files.writeImmutable(
            Data([1]), path: [".peer-configuration", "unexpected"], maximumBytes: 1)
        XCTAssertThrowsError(try capture(index, coordinator, packageID, directory, rootID: Fixture.id()))
        XCTAssertEqual(try walkCount(index), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("root.json").path))
        try f.capacity()
    }
}
