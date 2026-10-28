import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class PeerOriginAdmissionTests: XCTestCase {
    typealias Fixture = PeerEnrollmentApprovalTests.Fixture
    private func accepted(_ f: Fixture) throws -> (
        PeerEnrollmentApproval.Handle, PeerPackage.Manifest, AuthorityBinding
    ) {
        let handle = try f.begin()
        let manifest = try f.ready(handle)
        let result = try f.source.acceptPeerEnrollment(handle, forUID: f.uid)
        return (handle, manifest, try XCTUnwrap(result.approval))
    }
    private func coordinator(_ f: Fixture) -> PeerIntakeCoordinator {
        PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.request.sourceContext.storeID)
    }
    private func target(_ f: Fixture) -> String { f.request.sourceCredential.binding.remoteReplicaID }
    private func replace(_ value: some Encodable, at path: URL) throws {
        try FileManager.default.removeItem(at: path)
        try JSON.encode(value).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
    }
    private func originals(_ f: Fixture, root supplied: URL? = nil) throws -> [(PeerPackage.Object, Data)] {
        try f.capacity()
        var result: [(PeerPackage.Object, Data)] = []
        var total = 0
        for directory in ["items", "authority/records"] {
            let scan = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: (supplied ?? f.sourceRoot).appendingPathComponent(directory),
                    includingPropertiesForKeys: nil))
            for case let path as URL in scan where ["tractanda", "authority"].contains(path.pathExtension) {
                let bytes = try Data(contentsOf: path)
                total += bytes.count
                guard total <= 8 * 1024 * 1024, result.count < 256 else {
                    throw TractandaError("resourceLimit", "Tiny admission metadata estimate exceeded")
                }
                let kind: PeerPackage.Kind = path.pathExtension == "authority" ? .authority : .item
                let id =
                    kind == .authority
                    ? try AuthorityRecordCodec.decode(bytes).record.recordID
                    : try RecordCodec.decode(bytes).revisionID
                result.append(
                    (
                        .init(
                            kind: kind, id: id, length: bytes.count,
                            sha256: AuthorityRecordCodec.sha256(bytes)), bytes
                    ))
            }
        }
        return result.sorted { $0.0.id < $1.0.id }
    }
    @discardableResult
    private func send(
        _ objects: [(PeerPackage.Object, Data)], to store: ItemStore,
        context: PeerPackage.Context, fixture: Fixture
    ) throws -> String {
        try fixture.capacity()
        let page = try JSON.encode(PeerPackage.Page(objects: objects.map(\.0), children: []))
        let leaf = PeerPackage.Object(
            kind: .index, id: try Fixture.id(), length: page.count, sha256: AuthorityRecordCodec.sha256(page))
        let manifest = PeerPackage.Manifest(packageID: try Fixture.id(), storeID: context.storeID, root: leaf)
        _ = try store.beginPeerIntake(context: context, manifestBytes: JSON.encode(manifest))
        for (object, bytes) in [(leaf, page)] + objects {
            for offset in stride(from: 0, to: bytes.count, by: object.chunkBytes) {
                try fixture.capacity()
                _ = try store.appendPeerObject(
                    context: context, packageID: manifest.packageID, object: object,
                    offset: offset, bytes: Data(bytes[offset..<min(bytes.count, offset + object.chunkBytes)]))
            }
        }
        _ = try store.commitPeerIntake(
            context: context, packageID: manifest.packageID,
            expectedContextToken: store.peerIntakeContextToken())
        return manifest.packageID
    }
    /// Established-peer fixture only; actual prepared-target provisioning is covered separately.
    private func emptyReceiver(_ root: URL, fixture f: Fixture, replicaID: String) throws -> ItemStore {
        try f.capacity()
        var empty: ItemStore? = try ItemStore(
            root: root, accounts: f.accounts, revisionProjectionEnabled: true)
        empty = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".tractanda-store-identity.json"))
        try FileManager.default.copyItem(
            at: f.sourceRoot.appendingPathComponent(".tractanda-store-identity.json"),
            to: root.appendingPathComponent(".tractanda-store-identity.json"))
        let files = InitialAuthorityBootstrap.files(root)
        try files.writeImmutable(
            JSON.encode(
                ReplicaIdentity.Record(
                    formatVersion: 1,
                    storeID: f.request.sourceContext.storeID, replicaID: replicaID)),
            path: [ReplicaIdentity.name], maximumBytes: 4096)
        return try ItemStore(
            root: root, accounts: f.accounts, revisionProjectionEnabled: true, authorityIntakeEnabled: true)
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
                initial = try fixture.objects(handle, manifest: manifest).filter { $0.kind != .index }.map {
                    object in
                    (
                        object,
                        try fixture.source.readPeerEnrollment(
                            handle, object: object, offset: 0, forUID: fixture.uid
                        ).bytes
                    )
                }
            } else {
                initial = try owner.originals(f)
            }
            stashRoot = f.root.appendingPathComponent("established-stash")
            ravenContext = try PeerPackage.Context(
                peerID: "raven", storeID: f.request.sourceContext.storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data("established-raven".utf8)),
                permittedOrigins: [f.request.sourceCredential.binding.localReplicaID])
            relayContext = try PeerPackage.Context(
                peerID: "existing-relay", storeID: f.request.sourceContext.storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data("unchanged-relay-generation".utf8)),
                permittedOrigins: [f.request.sourceCredential.binding.localReplicaID])
            stash = try owner.emptyReceiver(
                stashRoot, fixture: f, replicaID: f.request.sourceCredential.binding.remoteReplicaID)
            // Before any global policy is pinned, only this fixture root's OS owner is admitted.
            try stash.configurePeerIntake(peers: [ravenContext])
            try owner.send(initial, to: stash, context: ravenContext, fixture: f)
            if freshPolicy {
                let founding = try XCTUnwrap(
                    InitialAuthorityBootstrap.load(root: f.sourceRoot)?.foundingPolicy)
                XCTAssertThrowsError(try stash.get(founding.original.itemID))
                XCTAssertThrowsError(try stash.withAccess(forUID: f.uid) { try stash.requireAdministrator() })
            }
            let pin = try XCTUnwrap(owner.coordinator(f).configuration()?.bootstrap)
            try stash.pinAuthorityBootstrap(
                rootID: pin.recordID, sha256: pin.sha256,
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
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let prep = try PeerEnrollment.prepareTarget(
                root: root, commonStoreID: ravenContext.storeID, sourceReplicaID: stashID)
            let local = try PeerPackage.Context(
                peerID: "starlet", storeID: ravenContext.storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data(prep.targetReplicaID.utf8)),
                permittedOrigins: [prep.targetReplicaID])
            let origins = Array(Set([ravenID, stashID] + admittedTargets)).sorted()
            for origin in origins { _ = try XCTUnwrap(stash.peerOriginMembership(origin)) }
            let remote = try PeerPackage.Context(
                peerID: "stash", storeID: ravenContext.storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data(prep.operationID.utf8)),
                permittedOrigins: origins)
            let pairing = try Fixture.id()
            let request = try PeerEnrollmentApproval.Request(
                operationID: Fixture.id(), preparationBytes: JSON.encode(prep),
                sourceContext: local, targetContext: remote,
                sourceCredential: .init(
                    binding: .init(
                        peerID: local.peerID, storeID: local.storeID, localReplicaID: stashID,
                        remoteReplicaID: prep.targetReplicaID, pairingID: pairing, localIsInitiator: true,
                        configurationDigest: local.configurationDigest),
                    secret: Array(repeating: 41, count: 32)),
                targetCredential: .init(
                    binding: .init(
                        peerID: remote.peerID, storeID: remote.storeID, localReplicaID: prep.targetReplicaID,
                        remoteReplicaID: stashID, pairingID: pairing, localIsInitiator: false,
                        configurationDigest: remote.configurationDigest),
                    secret: Array(repeating: 41, count: 32)))
            let handle = try stash.beginPeerEnrollment(request, forUID: f.uid)
            for _ in 0..<1024 {
                try f.capacity()
                if try stash.stepPeerEnrollment(
                    handle, forUID: f.uid,
                    window: .init(maximumUnits: 4, maximumEdges: 8)
                ).manifest != nil {
                    let approval = try XCTUnwrap(stash.acceptPeerEnrollment(handle, forUID: f.uid).approval)
                    admittedTargets.append(prep.targetReplicaID)
                    return (prep.targetReplicaID, handle, approval)
                }
            }
            throw TractandaError("testTimeout", "Tiny non-root approval did not finish")
        }
        func relay() throws {
            try owner.send(
                owner.originals(f, root: stashRoot), to: f.source, context: relayContext, fixture: f)
        }
        func author() throws -> Revision {
            try stash.withAccess(forUID: f.uid) {
                try stash.commit(
                    CommitRequest(
                        classID: "Item", changes: ["subject": .text("real Stash original")],
                        operationID: Fixture.id())
                ).revision
            }
        }
        func publicApproval(_ handle: PeerEnrollmentApproval.Handle) throws -> AuthorityRecordCodec.Verified {
            try AuthorityRecordCodec.decode(stash.peerEnrollmentApprovalBytes(handle, forUID: f.uid))
        }
        func forged(_ record: AuthorityRecord, payload: [String: ItemValue], target: String) throws -> (
            PeerPackage.Object, Data
        ) {
            var payload = payload
            payload["targetReplicaID"] = .text(target)
            let changed = try AuthorityRecord(
                recordID: Fixture.id(), storeID: record.storeID,
                originReplicaID: record.originReplicaID, kind: record.kind,
                parentAuthorityIDs: record.parentAuthorityIDs,
                actorPrincipal: record.actorPrincipal, createdAt: record.createdAt, payload: payload)
            let bytes = try AuthorityRecordCodec.encode(changed)
            return (
                .init(
                    kind: .authority, id: changed.recordID, length: bytes.count,
                    sha256: AuthorityRecordCodec.sha256(bytes)), bytes
            )
        }
    }
    private final class ReadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let selected: Set<String>
        private var total: UInt64 = 0
        private var originals: UInt64 = 0
        init(_ ids: [String]) { selected = Set(ids) }
        func record(_ path: [String], _ bytes: Int) {
            lock.lock()
            defer { lock.unlock() }
            total += UInt64(bytes)
            if let leaf = path.last, selected.contains(where: { leaf == $0 + ".tractanda" }) {
                originals += UInt64(bytes)  // Successful reads of selected canonical item bodies only.
            }
        }
        var snapshot: (total: UInt64, originals: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            return (total, originals)
        }
    }
    private func largeOrdinaryOriginals(_ mesh: Mesh) throws -> [Revision] {
        let items = try (0..<2).map { number in
            try mesh.f.source.withAccess(forUID: mesh.f.uid) {
                try mesh.f.source.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: [
                            "subject": .text("bounded original " + String(number)),
                            "notes": .text(String(repeating: number == 0 ? "a" : "b", count: 64 * 1024)),
                        ],
                        operationID: Fixture.id())
                ).revision
            }
        }
        try send(originals(mesh.f), to: mesh.stash, context: mesh.ravenContext, fixture: mesh.f)
        for item in items {
            XCTAssertEqual(
                try mesh.stash.withAccess(forUID: mesh.f.uid) { try mesh.stash.get(item.itemID) }, item)
        }
        return items
    }

}
