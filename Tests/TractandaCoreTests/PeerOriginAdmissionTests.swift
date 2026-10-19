import CTractandaPlatform
import Foundation
import XCTest
@testable import TractandaCore

final class PeerOriginAdmissionTests: XCTestCase {
    typealias Fixture = PeerEnrollmentApprovalTests.Fixture
    private func accepted(_ f: Fixture) throws -> (PeerEnrollmentApproval.Handle, PeerPackage.Manifest, AuthorityBinding) {
        let handle = try f.begin(), manifest = try f.ready(handle)
        let result = try f.source.acceptPeerEnrollment(handle, forUID: f.uid)
        return (handle, manifest, try XCTUnwrap(result.approval))
    }
    private func coordinator(_ f: Fixture) -> PeerIntakeCoordinator {
        PeerIntakeCoordinator(root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.request.sourceContext.storeID)
    }
    private func target(_ f: Fixture) -> String { f.request.sourceCredential.binding.remoteReplicaID }
    private func replace(_ value: some Encodable, at path: URL) throws {
        try FileManager.default.removeItem(at: path)
        try JSON.encode(value).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
    }
    private func originals(_ f: Fixture, root supplied: URL? = nil) throws -> [(PeerPackage.Object, Data)] {
        try f.capacity()
        var result: [(PeerPackage.Object, Data)] = [], total = 0
        for directory in ["items", "authority/records"] {
            let scan = try XCTUnwrap(FileManager.default.enumerator(at: (supplied ?? f.sourceRoot).appendingPathComponent(directory), includingPropertiesForKeys: nil))
            for case let path as URL in scan where ["tractanda", "authority"].contains(path.pathExtension) {
                let bytes = try Data(contentsOf: path)
                total += bytes.count
                guard total <= 8 * 1024 * 1024, result.count < 256 else {
                    throw TractandaError("resourceLimit", "Tiny admission metadata estimate exceeded")
                }
                let kind: PeerPackage.Kind = path.pathExtension == "authority" ? .authority : .item
                let id = kind == .authority ? try AuthorityRecordCodec.decode(bytes).record.recordID : try RecordCodec.decode(bytes).revisionID
                result.append((.init(kind: kind, id: id, length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes)), bytes))
            }
        }
        return result.sorted { $0.0.id < $1.0.id }
    }
    @discardableResult
    private func send(_ objects: [(PeerPackage.Object, Data)], to store: ItemStore,
                      context: PeerPackage.Context, fixture: Fixture) throws -> String {
        try fixture.capacity()
        let page = try JSON.encode(PeerPackage.Page(objects: objects.map(\.0), children: []))
        let leaf = PeerPackage.Object(kind: .index, id: try Fixture.id(), length: page.count, sha256: AuthorityRecordCodec.sha256(page))
        let manifest = PeerPackage.Manifest(packageID: try Fixture.id(), storeID: context.storeID, root: leaf)
        _ = try store.beginPeerIntake(context: context, manifestBytes: JSON.encode(manifest))
        for (object, bytes) in [(leaf, page)] + objects {
            for offset in stride(from: 0, to: bytes.count, by: object.chunkBytes) {
                try fixture.capacity()
                _ = try store.appendPeerObject(context: context, packageID: manifest.packageID, object: object,
                    offset: offset, bytes: Data(bytes[offset..<min(bytes.count, offset + object.chunkBytes)]))
            }
        }
        _ = try store.commitPeerIntake(context: context, packageID: manifest.packageID,
                                     expectedContextToken: store.peerIntakeContextToken())
        return manifest.packageID
    }
    /// Established-peer fixture only; actual prepared-target provisioning is covered separately.
    private func emptyReceiver(_ root: URL, fixture f: Fixture, replicaID: String) throws -> ItemStore {
        try f.capacity()
        var empty: ItemStore? = try ItemStore(root: root, accounts: f.accounts, revisionProjectionEnabled: true)
        empty = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".tractanda-store-identity.json"))
        try FileManager.default.copyItem(at: f.sourceRoot.appendingPathComponent(".tractanda-store-identity.json"),
                                        to: root.appendingPathComponent(".tractanda-store-identity.json"))
        let files = InitialAuthorityBootstrap.files(root)
        try files.writeImmutable(JSON.encode(ReplicaIdentity.Record(formatVersion: 1,
            storeID: f.request.sourceContext.storeID, replicaID: replicaID)), path: [ReplicaIdentity.name], maximumBytes: 4096)
        return try ItemStore(root: root, accounts: f.accounts, revisionProjectionEnabled: true, authorityIntakeEnabled: true)
    }
    private final class Mesh {
        let owner: PeerOriginAdmissionTests
        let f: Fixture
        let stashRoot: URL
        var stash: ItemStore!
        let ravenContext: PeerPackage.Context
        let relayContext: PeerPackage.Context
        let initial: [(PeerPackage.Object, Data)]
        var firstApproval: AuthorityBinding!
        var admittedTargets: [String] = []
        var stashID: String { f.request.sourceCredential.binding.remoteReplicaID }
        var ravenID: String { f.request.sourceCredential.binding.localReplicaID }
        init(_ owner: PeerOriginAdmissionTests, freshPolicy: Bool = false) throws {
            self.owner = owner
            f = try Fixture(capturedPolicySource: !freshPolicy)
            let handle = try f.begin()
            let manifest = try f.ready(handle)
            if freshPolicy {
                // Public source baseline only: no source operation/capture/identity/key files.
                firstApproval = try XCTUnwrap(f.source.acceptPeerEnrollment(handle, forUID: f.uid).approval)
                let fixture = f
                initial = try fixture.objects(handle, manifest: manifest).filter { $0.kind != .index }.map { object in
                    (object, try fixture.source.readPeerEnrollment(handle, object: object, offset: 0, forUID: fixture.uid).bytes)
                }
            } else {
                initial = try owner.originals(f)
            }
            stashRoot = f.root.appendingPathComponent("established-stash")
            ravenContext = try PeerPackage.Context(peerID: "raven", storeID: f.request.sourceContext.storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data("established-raven".utf8)),
                permittedOrigins: [f.request.sourceCredential.binding.localReplicaID])
            relayContext = try PeerPackage.Context(peerID: "existing-relay", storeID: f.request.sourceContext.storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data("unchanged-relay-generation".utf8)),
                permittedOrigins: [f.request.sourceCredential.binding.localReplicaID])
            stash = try owner.emptyReceiver(stashRoot, fixture: f, replicaID: f.request.sourceCredential.binding.remoteReplicaID)
            // Before any global policy is pinned, only this fixture root's OS owner is admitted.
            try stash.configurePeerIntake(peers: [ravenContext])
            try owner.send(initial, to: stash, context: ravenContext, fixture: f)
            if freshPolicy {
                let founding = try XCTUnwrap(InitialAuthorityBootstrap.load(root: f.sourceRoot)?.foundingPolicy)
                XCTAssertThrowsError(try stash.get(founding.original.itemID))
                XCTAssertThrowsError(try stash.withAccess(forUID: f.uid) { try stash.requireAdministrator() })
            }
            let pin = try XCTUnwrap(owner.coordinator(f).configuration()?.bootstrap)
            try stash.pinAuthorityBootstrap(rootID: pin.recordID, sha256: pin.sha256,
                expectedContextToken: stash.peerIntakeContextToken())
            if !freshPolicy {
                firstApproval = try XCTUnwrap(f.source.acceptPeerEnrollment(handle, forUID: f.uid).approval)
            }
            try owner.send(owner.originals(f), to: stash, context: ravenContext, fixture: f)
            try f.source.withAccess(forUID: f.uid) { try f.source.configurePeerIntake(peers: [relayContext]) }
        }
        deinit { stash = nil }
        func approveNext() throws -> (String, PeerEnrollmentApproval.Handle, AuthorityBinding) {
            let root = f.root.appendingPathComponent("starlet-" + (try Fixture.id()))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let prep = try PeerEnrollment.prepareTarget(root: root, commonStoreID: ravenContext.storeID, sourceReplicaID: stashID)
            let local = try PeerPackage.Context(peerID: "starlet", storeID: ravenContext.storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data(prep.targetReplicaID.utf8)), permittedOrigins: [prep.targetReplicaID])
            let origins = Array(Set([ravenID, stashID] + admittedTargets)).sorted()
            for origin in origins { _ = try XCTUnwrap(stash.peerOriginMembership(origin)) }
            let remote = try PeerPackage.Context(peerID: "stash", storeID: ravenContext.storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data(prep.operationID.utf8)), permittedOrigins: origins)
            let pairing = try Fixture.id()
            let request = try PeerEnrollmentApproval.Request(operationID: Fixture.id(), preparationBytes: JSON.encode(prep),
                sourceContext: local, targetContext: remote,
                sourceCredential: .init(binding: .init(peerID: local.peerID, storeID: local.storeID, localReplicaID: stashID,
                    remoteReplicaID: prep.targetReplicaID, pairingID: pairing, localIsInitiator: true,
                    configurationDigest: local.configurationDigest), secret: Array(repeating: 41, count: 32)),
                targetCredential: .init(binding: .init(peerID: remote.peerID, storeID: remote.storeID, localReplicaID: prep.targetReplicaID,
                    remoteReplicaID: stashID, pairingID: pairing, localIsInitiator: false,
                    configurationDigest: remote.configurationDigest), secret: Array(repeating: 41, count: 32)))
            let handle = try stash.beginPeerEnrollment(request, forUID: f.uid)
            for _ in 0..<1024 {
                try f.capacity()
                if try stash.stepPeerEnrollment(handle, forUID: f.uid,
                    window: .init(maximumUnits: 4, maximumEdges: 8)).manifest != nil {
                    let approval = try XCTUnwrap(stash.acceptPeerEnrollment(handle, forUID: f.uid).approval)
                    admittedTargets.append(prep.targetReplicaID)
                    return (prep.targetReplicaID, handle, approval)
                }
            }
            throw TractandaError("testTimeout", "Tiny non-root approval did not finish")
        }
        func relay() throws {
            try owner.send(owner.originals(f, root: stashRoot), to: f.source, context: relayContext, fixture: f)
        }
        func author() throws -> Revision {
            try stash.withAccess(forUID: f.uid) {
                try stash.commit(CommitRequest(classID: "Item", changes: ["subject": .text("real Stash original")],
                    operationID: Fixture.id())).revision
            }
        }
        func publicApproval(_ handle: PeerEnrollmentApproval.Handle) throws -> AuthorityRecordCodec.Verified {
            try AuthorityRecordCodec.decode(stash.peerEnrollmentApprovalBytes(handle, forUID: f.uid))
        }
        func forged(_ record: AuthorityRecord, payload: [String: ItemValue], target: String) throws -> (PeerPackage.Object, Data) {
            var payload = payload
            payload["targetReplicaID"] = .text(target)
            let changed = try AuthorityRecord(recordID: Fixture.id(), storeID: record.storeID,
                originReplicaID: record.originReplicaID, kind: record.kind, parentAuthorityIDs: record.parentAuthorityIDs,
                actorPrincipal: record.actorPrincipal, createdAt: record.createdAt, payload: payload)
            let bytes = try AuthorityRecordCodec.encode(changed)
            return (.init(kind: .authority, id: changed.recordID, length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes)), bytes)
        }
    }
    private final class ReadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let selected: Set<String>
        private var total: UInt64 = 0
        private var originals: UInt64 = 0
        init(_ ids: [String]) { selected = Set(ids) }
        func record(_ path: [String], _ bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            total += UInt64(bytes)
            if let leaf = path.last, selected.contains(where: { leaf == $0 + ".tractanda" }) {
                originals += UInt64(bytes) // Successful reads of selected canonical item bodies only.
            }
        }
        var snapshot: (total: UInt64, originals: UInt64) {
            lock.lock(); defer { lock.unlock() }; return (total, originals)
        }
    }
    private func largeOrdinaryOriginals(_ mesh: Mesh) throws -> [Revision] {
        let items = try (0..<2).map { number in
            try mesh.f.source.withAccess(forUID: mesh.f.uid) {
                try mesh.f.source.commit(CommitRequest(classID: "Item",
                    changes: ["subject": .text("bounded original " + String(number)),
                        "notes": .text(String(repeating: number == 0 ? "a" : "b", count: 64 * 1024))],
                    operationID: Fixture.id())).revision
            }
        }
        try send(originals(mesh.f), to: mesh.stash, context: mesh.ravenContext, fixture: mesh.f)
        for item in items {
            XCTAssertEqual(try mesh.stash.withAccess(forUID: mesh.f.uid) { try mesh.stash.get(item.itemID) }, item)
        }
        return items
    }
    func testWarmOriginReplayUsesTypedMetadataWithoutReadingTwoLargeUserOriginals() throws {
        let mesh = try Mesh(self), items = try largeOrdinaryOriginals(mesh)
        try mesh.stash.rebuildIndex()
        mesh.stash = nil
        let reads = ReadProbe(items.map(\.revisionID))
        try DocumentContentFiles.observeReadsForTesting(root: mesh.stashRoot,
            observation: { reads.record($0, $1) }) {
            mesh.stash = try ItemStore.openInitialized(root: mesh.stashRoot, accounts: mesh.f.accounts)
        }
        XCTAssertEqual(mesh.stash.startupRecovery["mode"], "checkpoint")
        XCTAssertEqual(reads.snapshot.originals, 0)
        XCTAssertGreaterThan(reads.snapshot.total, 0, "Canonical control/publication/policy proof still performs real reads")
        let index = try ItemIndex(path: mesh.stashRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        var limits = PeerPackage.Limits(); limits.maximumReadBytes = 96 * 1024
        let c = PeerIntakeCoordinator(root: mesh.stashRoot, ownerUID: tractanda_uid(), storeID: mesh.ravenContext.storeID, limits: limits)
        let replayReads = ReadProbe(items.map(\.revisionID))
        try DocumentContentFiles.observeReadsForTesting(root: mesh.stashRoot,
            observation: { replayReads.record($0, $1) }) {
            XCTAssertFalse(try c.replayOriginReceipts(index: index, create: false))
        }
        XCTAssertEqual(replayReads.snapshot.originals, 0)
        XCTAssertGreaterThan(c.operationReadBytesForTesting, 0)
        XCTAssertLessThanOrEqual(c.operationReadBytesForTesting, limits.maximumReadBytes)
        XCTAssertLessThan(c.operationReadBytesForTesting, 128 * 1024)
        print("OriginWarmReplayEvidence warmOriginalBytes=\(reads.snapshot.originals) warmTotalBytes=\(reads.snapshot.total) replayOriginalBytes=\(replayReads.snapshot.originals) owningBudgetUsed=\(c.operationReadBytesForTesting) limit=\(limits.maximumReadBytes)")
        try mesh.f.capacity()
    }
    func testFullDirtyAndMissingIndexRecoveryStillReadOriginalsAndPreserveMembership() throws {
        let mesh = try Mesh(self), items = try largeOrdinaryOriginals(mesh)
        let membership = try XCTUnwrap(mesh.stash.peerOriginMembership(mesh.stashID))
        let explicit = ReadProbe(items.map(\.revisionID))
        try DocumentContentFiles.observeReadsForTesting(root: mesh.stashRoot,
            observation: { explicit.record($0, $1) }) { try mesh.stash.rebuildIndex() }
        XCTAssertGreaterThanOrEqual(explicit.snapshot.originals, 128 * 1024)
        print("OriginWarmReplayEvidence recovery=explicit originalBytes=\(explicit.snapshot.originals) totalBytes=\(explicit.snapshot.total)")
        for missingIndex in [false, true] {
            mesh.stash = nil
            if missingIndex { try FileManager.default.removeItem(at: mesh.stashRoot.appendingPathComponent("index")) }
            else { try StoreCheckpoint.markDirty(root: mesh.stashRoot) }
            let recovery = ReadProbe(items.map(\.revisionID))
            try DocumentContentFiles.observeReadsForTesting(root: mesh.stashRoot,
                observation: { recovery.record($0, $1) }) {
                mesh.stash = try ItemStore.openInitialized(root: mesh.stashRoot, accounts: mesh.f.accounts)
            }
            XCTAssertEqual(mesh.stash.startupRecovery["mode"], "fullRecovery")
            XCTAssertGreaterThanOrEqual(recovery.snapshot.originals, 128 * 1024)
            print("OriginWarmReplayEvidence recovery=\(missingIndex ? "missing-index" : "dirty") originalBytes=\(recovery.snapshot.originals) totalBytes=\(recovery.snapshot.total)")
            XCTAssertEqual(try mesh.stash.peerOriginMembership(mesh.stashID), membership)
            for item in items {
                XCTAssertEqual(try mesh.stash.withAccess(forUID: mesh.f.uid) { try mesh.stash.get(item.itemID) }, item)
            }
        }
        try mesh.f.capacity()
    }
    func testMissingAdmittedOriginProofCannotBeResealedByWarmOrColdReplay() throws {
        let mesh = try Mesh(self), item = try mesh.author()
        try mesh.relay()
        let index = try ItemIndex(path: mesh.f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        let row = try XCTUnwrap(index.retainedAuthorityObject(id: item.revisionID))
        XCTAssertTrue(row.permittedOrigin)
        let proof = mesh.f.sourceRoot.appendingPathComponent("authority/intake/" + row.packageID + "/origin-admissions/" + mesh.stashID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: proof.path))
        try FileManager.default.removeItem(at: proof)
        let c = PeerIntakeCoordinator(root: mesh.f.sourceRoot, ownerUID: tractanda_uid(), storeID: mesh.ravenContext.storeID)
        XCTAssertThrowsError(try c.replayOriginReceipts(index: index, create: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path), "A derived permitted bit cannot recreate missing canonical proof")
        index.close(); mesh.f.source = nil
        XCTAssertThrowsError(try ItemStore.openInitialized(root: mesh.f.sourceRoot, accounts: mesh.f.accounts))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path))
        try FileManager.default.removeItem(at: mesh.f.sourceRoot.appendingPathComponent("index"))
        XCTAssertThrowsError(try ItemStore.openInitialized(root: mesh.f.sourceRoot, accounts: mesh.f.accounts))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proof.path))
    }
    func testMissingRetainedPackageSealFailsBeforeConfiguredOriginOrLocalSkip() throws {
        for remote in [false, true] {
            let mesh = try Mesh(self), item = try mesh.f.commit("ordinary publication seal loss")
            if remote {
                try send(mesh.f.source.peerMetadataObjects(revisionID: item.revisionID),
                    to: mesh.stash, context: mesh.ravenContext, fixture: mesh.f)
            }
            var store: ItemStore? = remote ? mesh.stash : mesh.f.source
            let root = remote ? mesh.stashRoot : mesh.f.sourceRoot
            try store!.rebuildIndex() // The loss is after a genuine accepted clean checkpoint.
            let index = try ItemIndex(path: root.appendingPathComponent("index/items.sqlite").path, create: false)
            let row = try XCTUnwrap(index.retainedAuthorityObject(id: item.revisionID))
            XCTAssertEqual(row.peerID, remote ? mesh.ravenContext.peerID : "local")
            let seal = root.appendingPathComponent("authority/intake/" + row.packageID + "/sealed.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: seal.path))
            try FileManager.default.removeItem(at: seal)
            let c = PeerIntakeCoordinator(root: root, ownerUID: tractanda_uid(), storeID: mesh.ravenContext.storeID)
            XCTAssertThrowsError(try c.replayOriginReceipts(index: index, create: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: seal.path))
            index.close(); store = nil
            if remote { mesh.stash = nil } else { mesh.f.source = nil }
            XCTAssertThrowsError(try ItemStore.openInitialized(root: root, accounts: mesh.f.accounts))
            try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
            XCTAssertThrowsError(try ItemStore.openInitialized(root: root, accounts: mesh.f.accounts))
            XCTAssertFalse(FileManager.default.fileExists(atPath: seal.path))
        }
    }
    func testOriginReplayProjectionRejectsMalformedOrMissingVerifiedMetadata() throws {
        let f = try Fixture(), c = coordinator(f)
        let index = try ItemIndex(path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let boundary = try index.capturePeerInventory()
        let first = try XCTUnwrap(index.peerOriginReplayReceiptPage(epoch: boundary.epoch,
            afterSequence: 0, throughSequence: boundary.maximumSequence).first)
        try index.execute("UPDATE authority_objects SET origin=? WHERE id=?", ["not-a-uuid", first.retained.descriptor.id])
        XCTAssertThrowsError(try index.peerOriginReplayReceiptPage(epoch: boundary.epoch,
            afterSequence: 0, throughSequence: boundary.maximumSequence))
        try index.execute("DELETE FROM authority_objects WHERE id=?", [first.retained.descriptor.id])
        XCTAssertThrowsError(try c.replayOriginReceipts(index: index, create: false))
    }
    func testAcceptedExplicitTargetPreservesSealedBaselineAndExactKeys() throws {
        let f = try Fixture()
        let before = try Data(contentsOf: f.sourceRoot.appendingPathComponent(".tractanda-replica-identity.json"))
        XCTAssertNil(try f.source.peerOriginMembership(target(f)))
        let (handle, manifest, approval) = try accepted(f)
        let key = try Data(contentsOf: f.keyPath())
        XCTAssertEqual(try f.source.peerOriginMembership(target(f)), approval)
        XCTAssertEqual(try f.source.readPeerEnrollment(handle, object: manifest.root, offset: 0, forUID: f.uid).bytes.count,
                       manifest.root.length)
        XCTAssertEqual(try f.source.finishAcceptedPeerEnrollment(handle).approval, approval)
        XCTAssertEqual(try Data(contentsOf: f.keyPath()), key)
        XCTAssertEqual(try Data(contentsOf: f.sourceRoot.appendingPathComponent(".tractanda-replica-identity.json")), before)
        XCTAssertEqual(try coordinator(f).configuration()?.peers, [])
        XCTAssertNil(try f.source.peerOriginMembership(Fixture.id()))
    }
    func testPublicMembershipRebuildDoesNotRequireOriginalPrivateSecret() throws {
        let f = try Fixture(), (_, _, approval) = try accepted(f)
        try FileManager.default.removeItem(at: f.keyPath())
        try f.reopen(removeIndex: true)
        XCTAssertEqual(try f.source.peerOriginMembership(target(f)), approval)
        XCTAssertThrowsError(try f.source.loadPeerCredential(peerID: f.request.sourceContext.peerID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try f.keyPath().path))
    }
    func testOnlyCanonicalExplicitTargetIsAdmittedAndTamperedIssuerFailsClosed() throws {
        let f = try Fixture(), (_, _, approval) = try accepted(f)
        let c = coordinator(f), decision = try XCTUnwrap(c.originDecision(target(f)))
        let path = f.sourceRoot.appendingPathComponent(PeerOriginAdmission.directory).appendingPathComponent(target(f))
        let forged = PeerOriginAdmission.Decision(profile: decision.profile, target: decision.target,
            approval: decision.approval, packageID: decision.packageID,
            issuerAdmission: try .init(recordID: Fixture.id(), sha256: String(repeating: "0", count: 64)))
        try replace(forged, at: path)
        XCTAssertThrowsError(try f.source.peerOriginMembership(target(f)))
        try replace(decision, at: path)
        XCTAssertEqual(try f.source.peerOriginMembership(target(f)), approval)
        let extra = try Fixture.id()
        XCTAssertNil(try f.source.peerOriginMembership(extra))
        let redirected = PeerOriginAdmission.Decision(profile: decision.profile, target: extra,
            approval: decision.approval, packageID: decision.packageID, issuerAdmission: decision.issuerAdmission)
        try c.journal.files.writeImmutable(JSON.encode(redirected), path: [PeerOriginAdmission.directory, extra], maximumBytes: PeerPackage.maximumPageBytes)
        XCTAssertThrowsError(try f.source.peerOriginMembership(extra))
    }
    func testAdmissionFrontierFencesOldInventoryCompletionWithoutInvalidatingOwnBaseline() throws {
        let f = try Fixture(), relayOrigin = try Fixture.id()
        let relay = try PeerPackage.Context(peerID: "stash", storeID: f.request.sourceContext.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("existing-stash-generation".utf8)), permittedOrigins: [relayOrigin])
        try f.source.withAccess(forUID: f.uid) { try f.source.configurePeerIntake(peers: [relay]) }
        let boundary = try f.source.capturePeerInventory(context: relay)
        let page = try f.source.peerInventoryPage(context: relay, boundary: boundary)
        let checkpoint = try XCTUnwrap(page.completionCheckpoint)
        let (handle, manifest, _) = try accepted(f)
        XCTAssertThrowsError(try f.source.capturePeerInventory(context: relay, after: checkpoint))
        XCTAssertThrowsError(try f.source.peerInventoryPage(context: relay, boundary: boundary))
        XCTAssertEqual(try f.source.readPeerEnrollment(handle, object: manifest.root, offset: 0, forUID: f.uid).bytes.count, manifest.root.length)
        let fresh = try f.source.capturePeerInventory(context: relay)
        XCTAssertFalse(try f.source.peerInventoryPage(context: relay, boundary: fresh).entries.isEmpty)
    }
    func testOwnAdmissionExceptionDoesNotPermitUnrelatedConfigurationChange() throws {
        let f = try Fixture(), (handle, manifest, _) = try accepted(f)
        let other = try PeerPackage.Context(peerID: "other", storeID: f.request.sourceContext.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("other".utf8)), permittedOrigins: [Fixture.id()])
        try f.source.withAccess(forUID: f.uid) { try f.source.configurePeerIntake(peers: [other]) }
        XCTAssertThrowsError(try f.source.readPeerEnrollment(handle, object: manifest.root, offset: 0, forUID: f.uid))
        XCTAssertNotNil(try f.source.peerOriginMembership(target(f)))
    }
    func testMissingPublicPublicationCannotBeReplacedByPrivateAcceptedMarker() throws {
        let f = try Fixture(), (_, _, _) = try accepted(f)
        let decision = try XCTUnwrap(coordinator(f).originDecision(target(f)))
        let path = f.sourceRoot.appendingPathComponent("authority/intake/" + decision.packageID + "/sealed.json")
        try FileManager.default.removeItem(at: path)
        XCTAssertThrowsError(try f.source.peerOriginMembership(target(f)))
        XCTAssertThrowsError(try f.reopen(removeIndex: true))
    }
    func testAdmissionRequiresBoundedCanonicalReads() throws {
        let f = try Fixture(), _ = try accepted(f)
        var reads = 0
        XCTAssertThrowsError(try f.source.peerOriginMembership(target(f), readBudget: { bytes in
            reads += bytes
            throw TractandaError("resourceLimit", "Injected tiny read window")
        }))
        XCTAssertGreaterThan(reads, 0)
    }
    func testCanonicalApprovalPublicationMetadataSharesTheActualReadBudget() throws {
        let f = try Fixture(), _ = try accepted(f)
        let c = coordinator(f), decision = try XCTUnwrap(c.originDecision(target(f)))
        var bytes = 0
        XCTAssertThrowsError(try c.journal.object(decision.approval, packageID: decision.packageID, readBudget: { count in
            bytes += count
            if bytes > decision.approval.length { throw TractandaError("resourceLimit", "Original-only allowance excludes required metadata") }
        }))
        XCTAssertGreaterThan(bytes, decision.approval.length)
        var complete = 0
        XCTAssertNotNil(try c.journal.object(decision.approval, packageID: decision.packageID, readBudget: { complete += $0 }))
        XCTAssertGreaterThan(complete, decision.approval.length)
    }
    func testDerivedReceiptAdmissionPreservesHeldRejectedAndQueuesOnlyUnknown() throws {
        let f = try Fixture()
        let original = try XCTUnwrap(originals(f).first { $0.0.kind == .item })
        let revision = try AuthorityRevision(originalBytes: original.1)
        for state in [AuthorityStore.Disposition.held, .rejected, .unknownOrigin] {
            try f.capacity()
            let index = try ItemIndex(path: f.root.appendingPathComponent("admission-" + state.rawValue + ".sqlite").path, create: true)
            try index.initializeAuthoritySchema()
            let row = AuthorityStore.RetainedObject(descriptor: original.0, path: "authority/fixture-original",
                packageID: try Fixture.id(), peerID: "raven", configurationDigest: f.request.sourceContext.configurationDigest,
                permittedOrigin: false)
            try index.retainAuthorityObject(row, revision: revision, authority: nil)
            try index.setAuthorityDisposition(id: original.0.id, evaluation: .init(disposition: state, reason: "Retained prior decision"))
            try index.admitOriginReceipt(row)
            XCTAssertEqual(try index.authorityDisposition(id: original.0.id)?.disposition, state == .unknownOrigin ? .pending : state)
            XCTAssertEqual(try index.originReconsiderationPage(), state == .unknownOrigin ? [row.packageID] : [])
        }
        try f.capacity()
    }
    func testFreshFactoryPublicPolicyBaselineSupportsRealNonRootAuthorityAndRebuild() throws {
        let mesh = try Mesh(self, freshPolicy: true)
        let initialization = try XCTUnwrap(InitialAuthorityBootstrap.load(root: mesh.f.sourceRoot))
        let founding = try XCTUnwrap(initialization.foundingPolicy)
        XCTAssertTrue(mesh.initial.contains { $0.0.id == founding.original.revisionID && $0.1 == founding.bytes })
        XCTAssertNil(try InitialAuthorityBootstrap.load(root: mesh.stashRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mesh.stashRoot.appendingPathComponent(
            "authority/initial-history/" + founding.original.revisionID).path))
        XCTAssertNotEqual(mesh.stash.replicaID, mesh.f.source.replicaID)
        XCTAssertThrowsError(try mesh.stash.withAccess(forUID: tractanda_uid()) { try mesh.stash.requireAdministrator() })
        try mesh.stash.withAccess(forUID: mesh.f.uid) { try mesh.stash.requireAdministrator() }
        XCTAssertEqual(try mesh.stash.peerOriginMembership(mesh.stashID), mesh.firstApproval)
        let item = try mesh.author()
        let (next, handle, approval) = try mesh.approveNext()
        let publicApproval = try mesh.publicApproval(handle)
        XCTAssertEqual(try AuthorityRecord.list(publicApproval.record.payload["issuerAdmission"]).map(AuthorityBinding.init(value:)), [mesh.firstApproval])
        try mesh.relay()
        XCTAssertEqual(try mesh.f.source.peerOriginMembership(next), approval)
        XCTAssertEqual(try mesh.f.source.withAccess(forUID: mesh.f.uid) { try mesh.f.source.get(item.itemID) }, item)
        mesh.stash = nil
        try FileManager.default.removeItem(at: mesh.stashRoot.appendingPathComponent("index"))
        mesh.stash = try ItemStore.openInitialized(root: mesh.stashRoot, accounts: mesh.f.accounts)
        XCTAssertEqual(try mesh.stash.peerOriginMembership(next), approval)
        XCTAssertEqual(try mesh.stash.withAccess(forUID: mesh.f.uid) { try mesh.stash.get(item.itemID) }, item)
        try mesh.f.reopen(removeIndex: true)
        XCTAssertEqual(try mesh.f.source.peerOriginMembership(next), approval)
        XCTAssertEqual(try mesh.f.source.withAccess(forUID: mesh.f.uid) { try mesh.f.source.get(item.itemID) }, item)
        try mesh.f.capacity()
    }
    func testAnchoredNonRootDecisionAndRealAuthoredRelayExportSurviveCanonicalRebuild() throws {
        let mesh = try Mesh(self)
        let item = try mesh.author()
        let (starlet, handle, approval) = try mesh.approveNext()
        let original = try mesh.publicApproval(handle)
        XCTAssertEqual(try AuthorityRecord.list(original.record.payload["issuerAdmission"]).map(AuthorityBinding.init(value:)), [mesh.firstApproval])
        let before = try coordinator(mesh.f).configuration()
        try mesh.relay()
        XCTAssertEqual(try mesh.f.source.peerOriginMembership(starlet), approval)
        XCTAssertEqual(try mesh.f.source.withAccess(forUID: mesh.f.uid) { try mesh.f.source.get(item.itemID) }, item)
        XCTAssertEqual(try coordinator(mesh.f).configuration(), before)
        let boundary = try mesh.f.source.capturePeerInventory(context: mesh.relayContext)
        let entry = try XCTUnwrap(mesh.f.source.peerInventoryPage(context: mesh.relayContext, boundary: boundary).entries.first { $0.descriptor.id == item.revisionID })
        XCTAssertThrowsError(try mesh.f.source.peerInventoryPage(context: mesh.relayContext, boundary: boundary,
            limits: .init(maximumReadBytes: 1))) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
        let export = try mesh.f.source.beginPeerExport(context: mesh.relayContext, planID: Fixture.id(), packageID: Fixture.id(), boundary: boundary)
        _ = try mesh.f.source.selectPeerExport(context: mesh.relayContext, handle: export, entries: [entry], finish: true)
        XCTAssertThrowsError(try mesh.f.source.stepPeerExport(context: mesh.relayContext, handle: export,
            window: .init(maximumUnits: 1, maximumEdges: 1, maximumReadBytes: 1))) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        var manifest: PeerPackage.Manifest?
        for _ in 0..<1024 {
            try mesh.f.capacity()
            let status = try mesh.f.source.stepPeerExport(context: mesh.relayContext, handle: export,
                window: .init(maximumUnits: 4, maximumEdges: 8))
            manifest = status.manifest
            if manifest != nil { break }
            XCTAssertEqual(status.missing, 0)
            XCTAssertEqual(status.unsupported, 0)
        }
        XCTAssertNotNil(manifest)
        let selected = try mesh.f.source.peerExportObjectPage(context: mesh.relayContext, handle: export).objects
        XCTAssertTrue(selected.contains { $0.id == mesh.firstApproval.recordID })
        let witnesses = try mesh.stash.peerMetadataObjects(revisionID: item.revisionID).filter {
            $0.0.kind == .authority && (try? AuthorityRecordCodec.decode($0.1).record.kind) == .authoredEvidence
        }
        XCTAssertFalse(witnesses.isEmpty)
        for witness in witnesses { XCTAssertTrue(selected.contains { $0.id == witness.0.id }) }
        try mesh.f.reopen(removeIndex: true)
        XCTAssertEqual(try mesh.f.source.peerOriginMembership(starlet), approval)
        XCTAssertEqual(try mesh.f.source.withAccess(forUID: mesh.f.uid) { try mesh.f.source.get(item.itemID) }, item)
    }
    func testNonRootWrongMissingIssuerAndForgedHistoricalAdministratorNeverAdmit() throws {
        let mesh = try Mesh(self)
        let (_, handle, _) = try mesh.approveNext()
        let original = try mesh.publicApproval(handle)
        try mesh.relay()
        var forged: [(PeerPackage.Object, Data)] = [], targets: [String] = []
        for variant in ["missing", "wrong", "administrator"] {
            var payload = original.record.payload
            if variant == "missing" { payload.removeValue(forKey: "issuerAdmission") }
            if variant == "wrong" {
                payload["issuerAdmission"] = .list([try AuthorityBinding(recordID: Fixture.id(), sha256: String(repeating: "0", count: 64)).itemValue])
            }
            if variant == "administrator" { payload["groups"] = .object([:]) }
            let target = try Fixture.id()
            targets.append(target)
            forged.append(try mesh.forged(original.record, payload: payload, target: target))
        }
        try send(forged, to: mesh.f.source, context: mesh.relayContext, fixture: mesh.f)
        for target in targets { XCTAssertNil(try mesh.f.source.peerOriginMembership(target)) }
        try mesh.f.reopen(removeIndex: true)
        for target in targets { XCTAssertNil(try mesh.f.source.peerOriginMembership(target)) }
    }
    func testEarlierUnanchoredNonRootDecisionStaysInertAfterIssuerAdmission() throws {
        let mesh = try Mesh(self)
        let (_, handle, _) = try mesh.approveNext()
        let original = try mesh.publicApproval(handle)
        var payload = original.record.payload
        payload.removeValue(forKey: "issuerAdmission")
        let target = try Fixture.id(), forged = try mesh.forged(original.record, payload: payload, target: target)
        let root = mesh.f.root.appendingPathComponent("earlier-observer")
        var observer: ItemStore? = try emptyReceiver(root, fixture: mesh.f, replicaID: Fixture.id())
        defer { observer = nil }
        let store = try XCTUnwrap(observer)
        try store.configurePeerIntake(peers: [mesh.ravenContext])
        try send(mesh.initial, to: store, context: mesh.ravenContext, fixture: mesh.f)
        let pin = try XCTUnwrap(coordinator(mesh.f).configuration()?.bootstrap)
        try store.pinAuthorityBootstrap(rootID: pin.recordID, sha256: pin.sha256,
            expectedContextToken: store.peerIntakeContextToken())
        try send([forged], to: store, context: mesh.ravenContext, fixture: mesh.f)
        XCTAssertNil(try store.peerOriginMembership(mesh.stashID))
        try send(originals(mesh.f, root: mesh.stashRoot) + [forged], to: store, context: mesh.ravenContext, fixture: mesh.f)
        XCTAssertEqual(try store.peerOriginMembership(mesh.stashID), mesh.firstApproval)
        XCTAssertNil(try store.peerOriginMembership(target))
    }
    func testSelfTrustAndConfiguredDepthLimitFailClosed() throws {
        let mesh = try Mesh(self)
        let (starlet, handle, _) = try mesh.approveNext()
        let original = try mesh.publicApproval(handle)
        try mesh.relay()
        let c = coordinator(mesh.f), selfID = try Fixture.id()
        let selfRecord = try AuthorityRecord(recordID: Fixture.id(), storeID: original.record.storeID,
            originReplicaID: selfID, kind: .enrollmentApproval, parentAuthorityIDs: original.record.parentAuthorityIDs,
            actorPrincipal: original.record.actorPrincipal, createdAt: original.record.createdAt,
            payload: original.record.payload.merging(["targetReplicaID": .text(selfID)]) { _, new in new })
        let bytes = try AuthorityRecordCodec.encode(selfRecord)
        let object = PeerPackage.Object(kind: .authority, id: selfRecord.recordID, length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes))
        let package = try send([(object, bytes)], to: mesh.f.source, context: mesh.relayContext, fixture: mesh.f)
        XCTAssertNil(try mesh.f.source.peerOriginMembership(selfID))
        let decision = PeerOriginAdmission.Decision(profile: PeerOriginAdmission.capability, target: selfID,
            approval: object, packageID: package, issuerAdmission: mesh.firstApproval)
        try c.journal.files.writeImmutable(JSON.encode(decision), path: [PeerOriginAdmission.directory, selfID], maximumBytes: PeerPackage.maximumPageBytes)
        XCTAssertThrowsError(try mesh.f.source.peerOriginMembership(selfID))
        try FileManager.default.removeItem(at: mesh.f.sourceRoot.appendingPathComponent(PeerOriginAdmission.directory).appendingPathComponent(selfID))
        var limits = PeerPackage.Limits()
        limits.maximumDepth = 1
        let limited = PeerIntakeCoordinator(root: mesh.f.sourceRoot, ownerUID: tractanda_uid(), storeID: mesh.ravenContext.storeID, limits: limits)
        // A one-level reader may inspect the root; it cannot hydrate a real two-admission chain.
        let index = try ItemIndex(path: mesh.f.root.appendingPathComponent("depth-read.sqlite").path, create: true)
        try index.initializeAuthoritySchema()
        let pin = try XCTUnwrap(c.configuration()?.bootstrap)
        let rootObject = try XCTUnwrap(originals(mesh.f).first { $0.0.id == pin.recordID })
        let initial = try XCTUnwrap(InitialAuthorityBootstrap.load(root: mesh.f.sourceRoot))
        let publication = try XCTUnwrap(c.journal.publication(initial.packageID))
        let locator = try c.journal.files.read(path: c.journal.canonicalPath(rootObject.0, publication: publication), maximumBytes: 512)
        let path = try XCTUnwrap(String(data: locator, encoding: .utf8))
        try index.retainAuthorityObject(.init(descriptor: rootObject.0, path: path,
            packageID: initial.packageID, peerID: "local",
            configurationDigest: AuthorityRecordCodec.sha256(Data(("local:" + mesh.ravenID).utf8)), permittedOrigin: true),
            revision: nil, authority: AuthorityRecordCodec.decode(rootObject.1))
        XCTAssertThrowsError(try limited.originAdmission(starlet, index: index))
    }
    func testAncestorChannelRevocationAndLaterDisposalPreserveEarlierDescendantMembership() throws {
        let mesh = try Mesh(self)
        let (starlet, _, approval) = try mesh.approveNext()
        try mesh.relay()
        try mesh.f.source.withAccess(forUID: mesh.f.uid) {
            try mesh.f.source.removePeerIntake(peerID: mesh.relayContext.peerID, retiredOriginIDs: [], operationID: Fixture.id())
            let disposal = try PeerPackage.Context(peerID: "stash-disposal", storeID: mesh.ravenContext.storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data("disposal-only-fixture".utf8)), permittedOrigins: [mesh.stashID])
            try mesh.f.source.configurePeerIntake(peers: [disposal])
            try mesh.f.source.removePeerIntake(peerID: disposal.peerID, retiredOriginIDs: [mesh.stashID], operationID: Fixture.id())
        }
        XCTAssertEqual(try mesh.f.source.peerOriginMembership(starlet), approval)
        try mesh.f.reopen(removeIndex: true)
        XCTAssertEqual(try mesh.f.source.peerOriginMembership(starlet), approval)
        let binding = try PeerExchangeBinding(peerID: mesh.relayContext.peerID, storeID: mesh.ravenContext.storeID,
            localReplicaID: mesh.ravenID, remoteReplicaID: mesh.stashID, pairingID: Fixture.id(), localIsInitiator: true,
            configurationDigest: mesh.relayContext.configurationDigest)
        XCTAssertThrowsError(try mesh.f.source.withPeerExchange(binding: binding, progress: {}) { _, _ in true })
    }
    func testUnrelatedAdmissionFencesPreviouslyAcceptedSourceBaseline() throws {
        let mesh = try Mesh(self)
        let (_, handle, _) = try mesh.approveNext()
        let manifest = try XCTUnwrap(mesh.stash.finishAcceptedPeerEnrollment(handle).manifest)
        XCTAssertEqual(try mesh.stash.readPeerEnrollment(handle, object: manifest.root, offset: 0, forUID: mesh.f.uid).bytes.count, manifest.root.length)
        _ = try mesh.approveNext()
        XCTAssertThrowsError(try mesh.stash.readPeerEnrollment(handle, object: manifest.root, offset: 0, forUID: mesh.f.uid))
    }

    func testInterruptedRemoteAdmissionReplaysCanonicalProofAndDuplicateIsIdempotent() throws {
        let mesh = try Mesh(self)
        let item = try mesh.author()
        let (starlet, _, approval) = try mesh.approveNext()
        mesh.f.source.originAdmissionBoundaryForTesting = { _ in throw TractandaError("interrupted", "After durable admission proof") }
        XCTAssertThrowsError(try mesh.relay())
        mesh.f.source.originAdmissionBoundaryForTesting = nil
        try mesh.f.reopen(removeIndex: true)
        XCTAssertEqual(try mesh.f.source.peerOriginMembership(starlet), approval)
        XCTAssertEqual(try mesh.f.source.withAccess(forUID: mesh.f.uid) { try mesh.f.source.get(item.itemID) }, item)
        let frontier = try coordinator(mesh.f).originAdmissionFrontier()
        try mesh.relay()
        XCTAssertEqual(try coordinator(mesh.f).originAdmissionFrontier(), frontier)
    }

    func testRavenAdmissionReconsidersStarletReceiptAtStashWithoutRePairing() throws {
        let f = try Fixture(capturedPolicySource: true), handle = try f.begin(), _ = try f.ready(handle)
        let stashRoot = f.root.appendingPathComponent("stash")
        var stash: ItemStore? = try ItemStore(root: stashRoot, accounts: f.accounts, revisionProjectionEnabled: true)
        stash = nil
        // A dedicated empty fixture receives the common StoreID; no target activation is claimed.
        try FileManager.default.removeItem(at: stashRoot.appendingPathComponent("index"))
        try FileManager.default.removeItem(at: stashRoot.appendingPathComponent(".tractanda-store-identity.json"))
        try FileManager.default.copyItem(at: f.sourceRoot.appendingPathComponent(".tractanda-store-identity.json"),
                                        to: stashRoot.appendingPathComponent(".tractanda-store-identity.json"))
        stash = try ItemStore(root: stashRoot, accounts: f.accounts, revisionProjectionEnabled: true, authorityIntakeEnabled: true)
        defer { stash = nil }
        let receiver = try XCTUnwrap(stash)
        let context = try PeerPackage.Context(peerID: "raven", storeID: f.request.sourceContext.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("existing-raven-channel".utf8)),
            permittedOrigins: [f.request.sourceCredential.binding.localReplicaID])
        try receiver.configurePeerIntake(peers: [context])
        let initial = try originals(f)
        try send(initial, to: receiver, context: context, fixture: f)
        let pin = try XCTUnwrap(coordinator(f).configuration()?.bootstrap)
        try receiver.pinAuthorityBootstrap(rootID: pin.recordID, sha256: pin.sha256,
            expectedContextToken: receiver.peerIntakeContextToken())
        try send(initial, to: receiver, context: context, fixture: f)
        let plain = try f.source.withAccess(forUID: f.uid) {
            try f.source.commit(CommitRequest(classID: "Item", changes: ["subject": .text("fixture template")], operationID: Fixture.id())).revision
        }
        var fields = plain.fields
        fields["itemID"] = .text(try Fixture.id())
        fields["revisionID"] = .text(try Fixture.id())
        let ancestry = try XCTUnwrap(plain.provenance)
        fields["revisionAncestry"] = try RevisionProvenance(kind: .authored, originReplicaID: target(f), parents: [],
            writtenFields: ancestry.writtenFields, unsetFields: [], frontier: []).itemValue
        let observed = try RecordCodec.encode(Revision(fields: fields, formatVersion: 2))
        let object = PeerPackage.Object(kind: .item, id: try XCTUnwrap(fields["revisionID"]?.string),
            length: observed.count, sha256: AuthorityRecordCodec.sha256(observed))
        let package = try send([(object, observed)], to: receiver, context: context, fixture: f)
        let old = try receiver.capturePeerInventory(context: context)
        let completion = try XCTUnwrap(receiver.peerInventoryPage(context: context, boundary: old).completionCheckpoint)
        let before = try AuthorityStore.configuration(root: stashRoot, files: InitialAuthorityBootstrap.files(stashRoot))
        XCTAssertNil(try receiver.peerOriginMembership(target(f)))
        let approval = try XCTUnwrap(f.source.acceptPeerEnrollment(handle, forUID: f.uid).approval)
        try send(originals(f), to: receiver, context: context, fixture: f)
        XCTAssertEqual(try receiver.peerOriginMembership(target(f)), approval)
        XCTAssertEqual(try AuthorityStore.configuration(root: stashRoot, files: InitialAuthorityBootstrap.files(stashRoot)), before)
        XCTAssertThrowsError(try receiver.capturePeerInventory(context: context, after: completion))
        let c = PeerIntakeCoordinator(root: stashRoot, ownerUID: tractanda_uid(), storeID: context.storeID)
        XCTAssertEqual(try c.originReceipt(packageID: package, origin: target(f))?.admission, approval)
        let fresh = try receiver.capturePeerInventory(context: context)
        let entry = try XCTUnwrap(receiver.peerInventoryPage(context: context, boundary: fresh).entries.first { $0.descriptor == object })
        XCTAssertNotEqual(entry.disposition, .unknownOrigin)
        XCTAssertNotEqual(entry.disposition, .eligible, "Membership does not fabricate absent authored evidence")
        let frontier = try c.originAdmissionFrontier()
        try send(originals(f), to: receiver, context: context, fixture: f)
        XCTAssertEqual(try c.originAdmissionFrontier(), frontier)
        try f.capacity()
    }
}
