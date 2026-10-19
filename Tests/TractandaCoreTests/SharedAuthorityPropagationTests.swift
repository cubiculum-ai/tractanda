import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class SharedAuthorityPropagationTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture

    private func objects(_ root: URL, fixture: Fixture) throws -> [(PeerPackage.Object, Data)] {
        try fixture.capacity()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var values: [(PeerPackage.Object, Data)] = []
        var bytes = 0
        for case let file as URL in files {
            let authority = file.pathExtension == "authority"
            guard authority || (file.pathExtension == "tractanda" && file.path.contains("/items/")) else {
                continue
            }
            let data = try Data(contentsOf: file)
            bytes += data.count
            guard bytes <= 8 * 1024 * 1024 else {
                throw TractandaError("resourceLimit", "Tiny canonical metadata fixture cap")
            }
            let id =
                authority
                ? try AuthorityRecordCodec.decode(data).record.recordID
                : try RecordCodec.decode(data).revisionID
            values.append(
                (
                    .init(
                        kind: authority ? .authority : .item, id: id, length: data.count,
                        sha256: AuthorityRecordCodec.sha256(data)), data
                ))
        }
        return values.sorted { $0.0.id < $1.0.id }
    }

    private func context(_ f: Fixture, name: String = "review-relay") throws -> PeerPackage.Context {
        let r = try XCTUnwrap(
            ReplicaIdentity.load(root: f.receiverRoot, storeID: f.storeID, ownerUID: tractanda_uid())
        ).replicaID
        return try .init(
            peerID: name, storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data(name.utf8)),
            permittedOrigins: [f.origin, r].sorted())
    }

    private func receive(
        _ reviewed: AuthorityReviewStoreTests.ReviewedFixture,
        result: AuthorityStore.ReviewResult, context inbound: PeerPackage.Context
    ) throws -> PeerIntakeStoreTests.Packet {
        let f = reviewed.base
        try f.source.configurePeerIntake(peers: [inbound])
        let packet = try f.packet(objects(f.receiverRoot, fixture: f))
        _ = try f.send(packet, context: inbound, to: f.source)
        XCTAssertEqual(try f.source.get(reviewed.held.itemID).revisionID, result.revision.revisionID)
        XCTAssertEqual(
            try f.source.get(reviewed.held.itemID, revisionID: reviewed.held.revisionID), reviewed.held)
        return packet
    }

    private func originalPath(_ root: URL, id: String) throws -> URL {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.lastPathComponent == id + ".authority" { return file }
        throw TractandaError("notFound", "Fixture canonical original missing")
    }

    func testForeignReviewPreservesExactOriginalsExcludesUnnamedDescendantAndAllowsSubsequentWrite() throws {
        let reviewed = try AuthorityReviewStoreTests.ReviewedFixture(withDescendant: true)
        let f = reviewed.base
        let result = try f.receiver.resolveAuthorityReview(reviewed.request())
        let expected = try objects(f.receiverRoot, fixture: f)
        let inbound = try context(f)
        let packet = try receive(reviewed, result: result, context: inbound)
        if let descendant = reviewed.descendant {
            XCTAssertThrowsError(try f.source.get(descendant.itemID, revisionID: descendant.revisionID))
        }
        let before = try objects(f.sourceRoot, fixture: f)
        _ = try f.send(packet, context: inbound, to: f.source)
        XCTAssertEqual(try objects(f.sourceRoot, fixture: f).map { $0.0 }, before.map { $0.0 })
        XCTAssertEqual(try f.source.get(reviewed.held.itemID).revisionID, result.revision.revisionID)
        XCTAssertEqual(
            try f.source.get(reviewed.held.itemID, revisionID: reviewed.held.revisionID), reviewed.held)
        for id in [reviewed.held.revisionID, result.revision.revisionID, result.decision.recordID] {
            XCTAssertEqual(
                try XCTUnwrap(objects(f.sourceRoot, fixture: f).first { $0.0.id == id }).1,
                try XCTUnwrap(expected.first { $0.0.id == id }).1)
        }
        XCTAssertThrowsError(
            try f.source.withAccess(forUID: f.sourceAccounts.bob) { try f.source.get(reviewed.held.itemID) })
        let next = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: reviewed.held.itemID,
                    expectedRevisionID: result.revision.revisionID,
                    changes: ["body": .text("ordinary edit after shared review")],
                    operationID: "after-global-review")
            ).revision
        }
        XCTAssertEqual(next.fields["subject"], result.revision.fields["subject"])
        try f.source.rebuildIndex()
        XCTAssertEqual(try f.source.get(next.itemID), next)
        try f.capacity()
    }

    func testForeignReviewKeepsConcurrentReceiverBranchAndMergesOnlyThroughExistingGraph() throws {
        let reviewed = try AuthorityReviewStoreTests.ReviewedFixture()
        let f = reviewed.base
        let result = try f.receiver.resolveAuthorityReview(reviewed.request())
        let local = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: f.base.itemID,
                    expectedRevisionID: f.base.revisionID,
                    changes: ["body": .text("receiver concurrent body")],
                    operationID: "concurrent-with-global-review")
            ).revision
        }
        let inbound = try context(f)
        try f.source.configurePeerIntake(peers: [inbound])
        _ = try f.send(f.packet(objects(f.receiverRoot, fixture: f)), context: inbound, to: f.source)
        let current = try f.source.get(f.base.itemID)
        XCTAssertEqual(current.fields["subject"], result.revision.fields["subject"])
        XCTAssertEqual(current.fields["body"], local.fields["body"])
        XCTAssertEqual(try f.source.get(local.itemID, revisionID: local.revisionID), local)
        XCTAssertEqual(
            try f.source.get(result.revision.itemID, revisionID: result.revision.revisionID), result.revision)
        XCTAssertGreaterThan(
            try RevisionTimestamp(current.modifiedAt), try RevisionTimestamp(result.revision.modifiedAt))
        XCTAssertGreaterThan(
            try RevisionTimestamp(current.modifiedAt), try RevisionTimestamp(local.modifiedAt))
        XCTAssertFalse(try result.revision.provenance!.parents.contains(local.revisionID))
        try f.source.rebuildIndex()
        XCTAssertEqual(try f.source.get(f.base.itemID), current)
        try f.capacity()
    }

    func testMissingActivatedForeignDecisionFailsColdRecoveryWithoutInventingApproval() throws {
        let reviewed = try AuthorityReviewStoreTests.ReviewedFixture()
        let f = reviewed.base
        let result = try f.receiver.resolveAuthorityReview(reviewed.request())
        _ = try receive(reviewed, result: result, context: context(f))
        let path = try originalPath(f.sourceRoot, id: result.decision.recordID)
        f.source = nil
        try FileManager.default.removeItem(at: path)
        try FileManager.default.removeItem(at: f.sourceRoot.appendingPathComponent("index"))
        XCTAssertThrowsError(try Fixture.open(f.sourceRoot, f.sourceAccounts))
        try f.capacity()
    }

    func testTamperedForeignReviewAdmissionSealFailsColdRecovery() throws {
        let reviewed = try AuthorityReviewStoreTests.ReviewedFixture()
        let f = reviewed.base
        let result = try f.receiver.resolveAuthorityReview(reviewed.request())
        _ = try receive(reviewed, result: result, context: context(f))
        let path = f.sourceRoot.appendingPathComponent(".peer-review-activations/" + result.decision.recordID)
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        var control = value["control"] as! [String: Any]
        control["sha256"] = String(repeating: "f", count: 64)
        value["control"] = control
        f.source = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: path)
        try FileManager.default.removeItem(at: f.sourceRoot.appendingPathComponent("index"))
        XCTAssertThrowsError(try Fixture.open(f.sourceRoot, f.sourceAccounts))
        try f.capacity()
    }
}
