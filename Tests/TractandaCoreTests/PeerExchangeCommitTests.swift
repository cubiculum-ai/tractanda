import XCTest

@testable import TractandaCore

final class PeerExchangeCommitTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private func fixture() throws -> Fixture {
        try Fixture(
            directory: GuardedFixtureDirectory.create(
                prefix: "c", source: "PeerExchangeCommitTests", test: name))
    }
    private func state(_ f: Fixture) throws -> PeerExchangeState {
        let binding = try PeerExchangeBinding(
            peerID: f.context.peerID, storeID: f.storeID,
            localReplicaID: XCTUnwrap(f.receiver.replicaID), remoteReplicaID: f.origin,
            pairingID: Fixture.id(), localIsInitiator: false,
            configurationDigest: f.context.configurationDigest)
        return try f.receiver.withPeerExchange(
            binding: binding, progress: {},
            { _, security in
                var state = PeerExchangeState(binding: binding, securityBinding: security)
                let declaration = try state.compatibility.advance(
                    .declare, store: f.receiver, storeID: binding.storeID)
                let ack = try state.compatibility.advance(
                    .accept(declaration), store: f.receiver, storeID: binding.storeID)
                _ = try state.compatibility.advance(
                    .acknowledge(ack), store: f.receiver, storeID: binding.storeID)
                return state
            })
    }
    func testGlobalPolicyChangeBetweenBeginAndCommitInvalidatesSession() throws {
        let f = try fixture()
        try f.bootstrap()
        let child = try f.edit()
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: child.revisionID))
        var state = try self.state(f)
        _ = try f.receiver.beginPeerIntake(context: f.context, manifestBytes: JSON.encode(packet.manifest))
        for (descriptor, bytes) in packet.objects {
            _ = try f.receiver.appendPeerObject(
                context: f.context, packageID: packet.manifest.packageID,
                object: descriptor, offset: 0, bytes: bytes)
        }
        _ = try f.receiver.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice")]),
            ]), operationID: "changed-current-global-policy")
        XCTAssertThrowsError(
            try f.receiver.withPeerExchange(
                binding: state.binding, expectedSecurity: state.securityBinding, progress: {},
                { context, _ in
                    try state.perform(
                        JSON.encode(
                            PeerExchangeRequest("commit", ["packageID": .text(packet.manifest.packageID)])),
                        store: f.receiver, context: context, control: PeerExchangeControl())
                })
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerConfigurationChanged")
        }
        XCTAssertEqual(
            try f.receiver.inspectPeerIntake(context: f.context, packageID: packet.manifest.packageID).phase,
            .staged)
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
        try f.capacity()
    }
    func testRemovedPeerInvalidatesSessionWithoutErasingAcceptedHistory() throws {
        let f = try fixture()
        try f.bootstrap()
        let state = try self.state(f)
        try f.receiver.removePeerIntake(
            peerID: f.context.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())
        XCTAssertThrowsError(
            try f.receiver.withPeerExchange(
                binding: state.binding, expectedSecurity: state.securityBinding, progress: {},
                { _, _ in true }))
        XCTAssertEqual(try f.receiver.get(f.base.itemID), f.base)
        try f.capacity()
    }
    private func exported(_ f: Fixture, revisionID: String, store suppliedStore: ItemStore? = nil) throws
        -> PeerIntakeStoreTests.Packet
    {
        let source = suppliedStore ?? f.source!
        let boundary = try source.capturePeerInventory(context: f.context)
        let handle = try source.beginPeerExport(
            context: f.context, planID: Fixture.id(), packageID: Fixture.id(), boundary: boundary)
        var cursor: PeerInventory.Cursor?
        var selected: PeerInventory.Entry?
        repeat {
            let page = try source.peerInventoryPage(context: f.context, boundary: boundary, cursor: cursor)
            selected = selected ?? page.entries.first { $0.descriptor.id == revisionID }
            cursor = page.nextCursor
        } while cursor != nil
        _ = try source.selectPeerExport(
            context: f.context, handle: handle, entries: [XCTUnwrap(selected)], finish: true)
        var manifest: PeerPackage.Manifest?
        for _ in 0..<256 {
            manifest = try source.stepPeerExport(context: f.context, handle: handle).manifest
            if manifest != nil { break }
        }
        let root = try XCTUnwrap(manifest)
        var pending = [root.root]
        var objects: [(PeerPackage.Object, Data)] = []
        while let descriptor = pending.popLast() {
            let bytes = try source.readPeerExport(
                context: f.context, handle: handle, object: descriptor, offset: 0
            ).bytes
            objects.append((descriptor, bytes))
            if descriptor.kind == .index {
                let page = try PeerPackage.decode(PeerPackage.Page.self, bytes)
                pending += page.objects + page.children
            }
        }
        return .init(manifest: root, objects: objects)
    }
    func testOrdinaryPublicationBetweenBeginAndCommitUsesFreshAuthorityToken() throws {
        let f = try fixture()
        try f.bootstrap()
        let child = try f.edit()
        try f.source.configurePeerIntake(peers: [f.context])
        let packet = try exported(f, revisionID: child.revisionID)
        let binding = try PeerExchangeBinding(
            peerID: f.context.peerID, storeID: f.storeID,
            localReplicaID: XCTUnwrap(f.receiver.replicaID), remoteReplicaID: f.origin,
            pairingID: Fixture.id(), localIsInitiator: false,
            configurationDigest: f.context.configurationDigest)
        var state = try f.receiver.withPeerExchange(
            binding: binding, progress: {},
            { _, security in
                var state = PeerExchangeState(binding: binding, securityBinding: security)
                let declaration = try state.compatibility.advance(
                    .declare, store: f.receiver, storeID: binding.storeID)
                let ack = try state.compatibility.advance(
                    .accept(declaration), store: f.receiver, storeID: binding.storeID)
                _ = try state.compatibility.advance(
                    .acknowledge(ack), store: f.receiver, storeID: binding.storeID)
                return state
            })
        func call(_ operation: String, _ fields: [String: ItemValue]) throws -> [String: ItemValue] {
            try f.receiver.withPeerExchange(
                binding: binding, expectedSecurity: state.securityBinding, progress: {},
                { context, _ in
                    try JSON.decode(
                        [String: ItemValue].self,
                        state.perform(
                            JSON.encode(PeerExchangeRequest(operation, fields)), store: f.receiver,
                            context: context, control: PeerExchangeControl()))
                })
        }
        _ = try call("begin", ["manifest": .bytes(JSON.encode(packet.manifest))])
        for (descriptor, bytes) in packet.objects {
            _ = try call(
                "append",
                [
                    "packageID": .text(packet.manifest.packageID),
                    "descriptor": PeerExchangeState.descriptor(descriptor), "offset": .integer(0),
                    "bytes": .bytes(bytes),
                ])
        }
        _ = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("unrelated ordinary write")],
                    operationID: "ordinary-between"))
        }
        let committed = try call("commit", ["packageID": .text(packet.manifest.packageID)])
        XCTAssertGreaterThan(committed["accepted"]?.integerValue ?? 0, 0)
        XCTAssertEqual(try f.receiver.get(child.itemID), child)
        try f.capacity()
    }
    func testReverseSealedClosureRetainsCurrentPolicyProof() throws {
        let f = try fixture()
        try f.bootstrap()
        let context = try PeerPackage.Context(
            peerID: "two-way", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("two-way".utf8)),
            permittedOrigins: [f.origin, XCTUnwrap(f.receiver.replicaID)].sorted())
        try f.receiver.configurePeerIntake(peers: [f.context, context])
        try f.source.configurePeerIntake(peers: [context])
        f.context = context
        let child = try f.edit()
        f.source = nil
        f.receiver = nil
        f.source = try Fixture.open(f.sourceRoot, f.sourceAccounts)
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        _ = try f.send(exported(f, revisionID: child.revisionID))
        _ = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("ordinary intervening write")],
                    operationID: "ordinary-before-reverse"))
        }
        let reverse = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("reverse original")], operationID: "reverse"))
        }.revision
        let packet = try exported(f, revisionID: reverse.revisionID, store: f.receiver)
        let result = try f.send(packet, to: f.source)
        XCTAssertGreaterThan(result.accepted, 0)
        XCTAssertEqual(try f.source.get(reverse.itemID), reverse)
        try f.capacity()
    }
    func testDirtyAndMissingExistingProjectionNeverUseNewRootPolicy() throws {
        for remove in [false, true] {
            let f = try fixture()
            try f.bootstrap()
            let child = try f.edit()
            let packet = try f.packet(f.source.peerMetadataObjects(revisionID: child.revisionID))
            let index = try ItemIndex(
                path: f.receiver.indexDirectory.appendingPathComponent("items.sqlite").path, create: false)
            defer { index.close() }
            XCTAssertFalse(try index.peerItemRootHasNoLocalPolicyHistory(itemID: child.itemID))
            if remove {
                try index.execute("DELETE FROM current_projection WHERE item=?", [child.itemID])
            } else {
                try index.execute("UPDATE current_projection SET dirty=1 WHERE item=?", [child.itemID])
            }
            XCTAssertFalse(try index.peerItemRootHasNoLocalPolicyHistory(itemID: child.itemID))
            XCTAssertThrowsError(try f.send(packet)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "projectionRequired")
            }
            try f.capacity()
        }
    }
    func testGenuinelyNewRootStillHoldsAuthorOwnerMismatch() throws {
        let f = try fixture()
        try f.bootstrap()
        let root = try f.source.withAccess(forUID: f.sourceAccounts.user(named: "admin").uid) {
            try f.source.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text("admin-authored root for another owner"),
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("bob"),
                            "group": .text("staff"), "mode": .integer(0o660), "acl": .object([:]),
                        ]),
                    ], operationID: "wrong-owner-root"))
        }.revision
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: root.revisionID))
        let result = try f.send(packet)
        XCTAssertGreaterThan(result.held, 0)
        XCTAssertEqual(result.accepted, 0)
        XCTAssertThrowsError(try f.receiver.get(root.itemID))
        try f.capacity()
    }
}
