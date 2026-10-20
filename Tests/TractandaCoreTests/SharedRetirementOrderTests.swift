import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class SharedRetirementOrderTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture

    private func originals(_ root: URL, fixture f: Fixture) throws -> [(PeerPackage.Object, Data)] {
        try f.capacity()
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [(PeerPackage.Object, Data)] = []
        var bytes = 0
        for case let path as URL in walk {
            let authority = path.pathExtension == "authority"
            guard authority || (path.pathExtension == "tractanda" && path.path.contains("/items/")) else {
                continue
            }
            let data = try Data(contentsOf: path)
            bytes += data.count
            guard bytes <= 8 * 1024 * 1024 else { throw TractandaError("resourceLimit", "Tiny metadata cap") }
            let id =
                authority
                ? try AuthorityRecordCodec.decode(data).record.recordID
                : try RecordCodec.decode(data).revisionID
            result.append(
                (
                    .init(
                        kind: authority ? .authority : .item, id: id, length: data.count,
                        sha256: AuthorityRecordCodec.sha256(data)), data
                ))
        }
        return result.sorted { $0.0.id < $1.0.id }
    }
    private func third(_ f: Fixture) throws -> (ItemStore, URL) {
        guard AttachmentFixtureCapacity.fixtureCapBytes >= 24 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Three stores estimate24MiB")
        }
        let root = f.directory.appendingPathComponent("third-retirement")
        let store = try f.openFreshSharedReplica(root, f.receiverAccounts)
        try store.configurePeerIntake(peers: [f.context])
        try f.bootstrap(to: store)
        return (store, root)
    }
    private func context(_ f: Fixture, peer: String, origins: [String]) throws -> PeerPackage.Context {
        try .init(
            peerID: peer, storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data(peer.utf8)),
            permittedOrigins: origins.sorted())
    }

    func testEarlierRemovalInvalidatesLaterIssuerRootInBothArrivalOrdersAndColdRecovery() throws {
        for reverse in [false, true] {
            let f = try Fixture()
            try f.bootstrap()
            let (third, thirdRoot) = try third(f)
            let b = try XCTUnwrap(f.receiver.replicaID)
            let c = try XCTUnwrap(third.replicaID)
            let relay = try context(f, peer: "all-origins", origins: [f.origin, b, c])
            let endpointB = try context(f, peer: "remove-b", origins: [b])
            try third.configurePeerIntake(peers: [f.context, relay, endpointB])
            try f.receiver.configurePeerIntake(peers: [f.context, relay])
            try f.source.configurePeerIntake(peers: [relay])
            // Actual issued event C@10 precedes actual B@20; no retroactive test clock.
            try third.removePeerIntake(
                peerID: endpointB.peerID, retiredOriginIDs: [b], operationID: Fixture.id())
            let earlier = try f.packet(originals(thirdRoot, fixture: f))
            try f.receiver.removePeerIntake(
                peerID: f.context.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())
            let later = try f.packet(originals(f.receiverRoot, fixture: f))
            for packet in reverse ? [earlier, later] : [later, earlier] {
                _ = try f.send(packet, context: relay, to: f.source)
            }
            // Invalid B@20 no longer retires A; still-valid C@10 remains effective.
            let next = try f.edit(subject: "active after issuer removal")
            XCTAssertEqual(try f.source.get(next.itemID), next)
            _ = try f.send(later, context: relay, to: f.source)
            XCTAssertEqual(try f.source.get(next.itemID), next)
            try f.source.rebuildIndex()
            XCTAssertEqual(try f.source.get(next.itemID), next)
            f.source = nil
            try FileManager.default.removeItem(at: f.sourceRoot.appendingPathComponent("index"))
            f.source = try Fixture.open(f.sourceRoot, f.sourceAccounts)
            XCTAssertEqual(try f.source.get(next.itemID), next)
            _ = try f.edit(subject: "active after cold root replay")
            try f.capacity()
        }
    }

    func testDelayedRetirementPreservesExactSourcePolicyProofWithoutGrantingCurrentUserRights() throws {
        let f = try Fixture()
        try f.bootstrap()
        let (third, thirdRoot) = try third(f)
        let b = try XCTUnwrap(f.receiver.replicaID)
        let c = try XCTUnwrap(third.replicaID)
        let relay = try context(f, peer: "policy-proof-relay", origins: [f.origin, b, c])
        let endpointB = try context(f, peer: "retire-policy-author", origins: [b])
        try third.configurePeerIntake(peers: [f.context, relay, endpointB])
        try f.receiver.configurePeerIntake(peers: [f.context, relay])
        try f.source.configurePeerIntake(peers: [relay, endpointB])
        try third.removePeerIntake(peerID: endpointB.peerID, retiredOriginIDs: [b], operationID: Fixture.id())
        let independent = try third.withAccess(forUID: f.receiverAccounts.bob) {
            try third.commit(
                .init(
                    classID: "Item",
                    changes: [
                        "subject": .text("independent current Bob intent"),
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("bob"),
                            "group": .text("staff"), "mode": .integer(0o660), "acl": .object([:]),
                        ]),
                    ], operationID: "same-packet-independent-bob")
            ).revision
        }
        let earlier = try f.packet(originals(thirdRoot, fixture: f))
        let policy = try f.receiver.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice")]),
            ]), operationID: "source-pre-policy"
        ).revision
        var body = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                .init(
                    action: .revise, itemID: f.base.itemID,
                    expectedRevisionID: f.base.revisionID,
                    changes: ["subject": .text("policy author body")], operationID: "policy-author-body")
            ).revision
        }
        _ = try f.send(f.packet(originals(f.receiverRoot, fixture: f)), context: relay, to: f.source)
        XCTAssertEqual(try f.source.get(body.itemID), body)
        // A's later genuine root has exact PRE policy P from B, which C's delayed root will demote.
        try f.source.removePeerIntake(
            peerID: endpointB.peerID, retiredOriginIDs: [b], operationID: Fixture.id())
        let prior = body
        body = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                .init(
                    action: .revise, itemID: prior.itemID, expectedRevisionID: prior.revisionID,
                    changes: ["subject": .text("issued after both real removals")],
                    operationID: "post-removals-body")
            ).revision
        }
        _ = try f.send(f.packet(originals(f.receiverRoot, fixture: f)), context: relay, to: f.source)
        XCTAssertThrowsError(
            try f.source.withAccess(forUID: f.sourceAccounts.bob) {
                try f.source.get(f.base.itemID)
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        _ = try f.send(earlier, context: relay, to: f.source)
        XCTAssertEqual(
            try f.source.withAccess(forUID: f.sourceAccounts.bob) {
                try f.source.get(independent.itemID)
            }, independent,
            "Same-intake ordinary admission uses surviving current policies, never retired P's cache.")
        XCTAssertEqual(try f.source.get(policy.itemID, revisionID: policy.revisionID), policy)
        XCTAssertNotEqual(try f.source.get(body.itemID).revisionID, body.revisionID)
        let evidenceObject = try XCTUnwrap(
            originals(f.receiverRoot, fixture: f).first { Fixture.isEvidence($0, for: body.revisionID) })
        let evidence = try AuthorityBinding(recordID: evidenceObject.0.id, sha256: evidenceObject.0.sha256)
        let state = try f.source.prepareAuthorityReview(
            itemID: body.itemID, revisionID: body.revisionID, evidence: evidence)
        XCTAssertEqual(
            state.retirements.count, 2,
            "Both source-proven roots survive; mutable current policy is not source proof.")
        _ = try f.source.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("bob")]),
            ]), operationID: "current-denies-alice")
        XCTAssertThrowsError(
            try f.source.withAccess(forUID: f.sourceAccounts.alice) { try f.source.get(body.itemID) })
        try f.source.rebuildIndex()
        f.source = nil
        try FileManager.default.removeItem(at: f.sourceRoot.appendingPathComponent("index"))
        f.source = try Fixture.open(f.sourceRoot, f.sourceAccounts)
        XCTAssertEqual(
            try f.source.prepareAuthorityReview(
                itemID: body.itemID, revisionID: body.revisionID, evidence: evidence
            ).retirements.count, 2)
        XCTAssertThrowsError(
            try f.source.withAccess(forUID: f.sourceAccounts.alice) { try f.source.get(body.itemID) })
        try f.capacity()
    }
}
