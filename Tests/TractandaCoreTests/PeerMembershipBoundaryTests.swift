import XCTest

@testable import TractandaCore

final class PeerMembershipBoundaryTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture

    private func code(
        _ expected: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }

    private func allMetadata(_ root: URL, fixture: Fixture) throws -> [(PeerPackage.Object, Data)] {
        try fixture.capacity()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [(PeerPackage.Object, Data)] = []
        var total = 0
        for case let url as URL in files {
            let authority = url.pathExtension == "authority"
            let item = url.pathExtension == "tractanda" && url.path.contains("/items/")
            guard authority || item else { continue }
            let bytes = try Data(contentsOf: url)
            total += bytes.count
            guard total <= 8 * 1024 * 1024 else {
                throw TractandaError("resourceLimit", "Tiny fixture metadata cap")
            }
            let id =
                authority
                ? try AuthorityRecordCodec.decode(bytes).record.recordID
                : try RecordCodec.decode(bytes).revisionID
            result.append(
                (
                    .init(
                        kind: authority ? .authority : .item, id: id, length: bytes.count,
                        sha256: AuthorityRecordCodec.sha256(bytes)), bytes
                ))
        }
        return result.sorted { $0.0.id < $1.0.id }
    }

    func testAuthenticatedReplicaIdentityControlsGateWhileNicknameAndRelayOriginsDoNot() throws {
        let f = try Fixture()
        try f.bootstrap()
        let local = try XCTUnwrap(f.receiver.replicaID)
        let lifecycleEndpoint = try PeerPackage.Context(
            peerID: "lifecycle-endpoint", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("lifecycle endpoint".utf8)),
            permittedOrigins: [f.origin])
        try f.receiver.configurePeerIntake(peers: [f.context, lifecycleEndpoint])
        try f.receiver.removePeerIntake(
            peerID: lifecycleEndpoint.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())

        // A retained pairing and a newly named pairing both identify the same retired remote.
        // The peer label is only a lookup key; the private binding's ReplicaID is the decision input.
        let nickname = try PeerPackage.Context(
            peerID: "friendly-relay-name", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("nickname".utf8)),
            permittedOrigins: [f.origin])
        try f.receiver.configurePeerIntake(peers: [f.context, nickname])
        let bindings = try [f.context, nickname].map { context in
            try PeerExchangeBinding(
                peerID: context.peerID, storeID: f.storeID, localReplicaID: local,
                remoteReplicaID: f.origin, pairingID: Fixture.id(), localIsInitiator: false,
                configurationDigest: context.configurationDigest)
        }
        for binding in bindings {
            code("peerRetired") {
                _ = try f.receiver.withPeerExchange(binding: binding, progress: {}) { _, _ in true }
            }
        }

        // A live relay may advertise retired-origin evidence in its separate allowlist. Its
        // authenticated immediate ReplicaID remains eligible for a normal exchange.
        let relayOrigin = try Fixture.id()
        let relay = try PeerPackage.Context(
            peerID: "relay-label", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("relay".utf8)),
            permittedOrigins: [f.origin, relayOrigin].sorted())
        try f.receiver.configurePeerIntake(peers: [f.context, nickname, relay])
        let relayBinding = try PeerExchangeBinding(
            peerID: relay.peerID, storeID: f.storeID, localReplicaID: local,
            remoteReplicaID: relayOrigin, pairingID: Fixture.id(), localIsInitiator: false,
            configurationDigest: relay.configurationDigest)
        XCTAssertTrue(
            try f.receiver.withPeerExchange(binding: relayBinding, progress: {}) { _, _ in true })
        try f.capacity()
    }

    func testIncompleteRetirementIsInertThenFullRootFencesSameExchangeAndPreservesLocalRetry() throws {
        let f = try Fixture()
        try f.bootstrap()
        let receiverOrigin = try XCTUnwrap(f.receiver.replicaID)
        let inbound = try PeerPackage.Context(
            peerID: "receiver", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("reverse authority".utf8)),
            permittedOrigins: [f.origin, receiverOrigin].sorted())
        try f.source.configurePeerIntake(peers: [inbound])

        let request = CommitRequest(
            action: .revise, itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
            changes: ["body": .text("already committed")], operationID: "membership-exact-retry")
        let committed = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(request).revision
        }
        try f.receiver.removePeerIntake(
            peerID: f.context.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())

        let complete = try allMetadata(f.receiverRoot, fixture: f)
        let root = try XCTUnwrap(
            complete.first { entry in
                entry.0.kind == .authority
                    && (try? AuthorityRecordCodec.decode(entry.1).record.kind) == .originRetirement
            })
        _ = try f.send(f.packet([root]), context: inbound, to: f.source)

        // An observed but incomplete root does not retire the local ReplicaID.
        let local = try XCTUnwrap(f.source.replicaID)
        let binding = try PeerExchangeBinding(
            peerID: inbound.peerID, storeID: f.storeID, localReplicaID: local,
            remoteReplicaID: receiverOrigin, pairingID: Fixture.id(), localIsInitiator: false,
            configurationDigest: inbound.configurationDigest)
        XCTAssertTrue(try f.source.withPeerExchange(binding: binding, progress: {}) { _, _ in true })
        let runtimeSnapshot = try f.source.peerRuntimeMaterial()
        XCTAssertTrue(runtimeSnapshot.credentials.isEmpty)

        // Full canonical proof arrives inside this authorized operation. Durable import completes,
        // but the post-body membership check suppresses the ordinary response.
        code("localReplicaRetired") {
            _ = try f.source.withPeerExchange(binding: binding, progress: {}) { _, _ in
                try f.send(f.packet(complete), context: inbound, to: f.source)
            }
        }
        code("localReplicaRetired") { _ = try f.source.peerRuntimeMaterial() }
        code("localReplicaRetired") {
            try f.source.validatePeerRuntimeMaterial(runtimeSnapshot, progress: {})
        }
        XCTAssertEqual(try f.source.get(f.base.itemID, revisionID: f.base.revisionID), f.base)
        XCTAssertTrue(
            try f.source.withAccess(forUID: f.sourceAccounts.alice) {
                try f.source.commit(request).wasReplayed
            })
        XCTAssertEqual(try f.source.get(committed.itemID, revisionID: committed.revisionID), committed)
        XCTAssertThrowsError(
            try f.source.withAccess(forUID: f.sourceAccounts.alice) {
                try f.source.commit(
                    .init(
                        action: .revise, itemID: committed.itemID,
                        expectedRevisionID: committed.revisionID,
                        changes: ["body": .text("publication remains fenced")],
                        operationID: "membership-fresh-local-write"))
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "localOriginRetired") }
        try f.source.rebuildIndex()
        XCTAssertEqual(try f.source.get(committed.itemID, revisionID: committed.revisionID), committed)
        XCTAssertThrowsError(
            try f.source.withPeerExchange(binding: binding, progress: {}) { _, _ in true }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "localReplicaRetired") }
        code("localReplicaRetired") { _ = try f.source.peerRuntimeMaterial() }
        code("localReplicaRetired") {
            try f.source.validatePeerRuntimeMaterial(runtimeSnapshot, progress: {})
        }
        try f.capacity()
    }
}
