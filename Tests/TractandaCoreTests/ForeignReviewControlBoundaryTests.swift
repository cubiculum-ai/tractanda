import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class ForeignReviewControlBoundaryTests: XCTestCase {
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

    private func context(_ f: Fixture) throws -> PeerPackage.Context {
        let recipient = try XCTUnwrap(
            ReplicaIdentity.load(root: f.receiverRoot, storeID: f.storeID, ownerUID: tractanda_uid())
        ).replicaID
        return try .init(
            peerID: "foreign-review-boundary", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("foreign-review-boundary".utf8)),
            permittedOrigins: [f.origin, recipient].sorted())
    }

    private func controlPublishing(
        _ decision: AuthorityBinding, in values: [(PeerPackage.Object, Data)]
    ) throws -> (PeerPackage.Object, AuthorityRecord) {
        for (descriptor, bytes) in values where descriptor.kind == .authority {
            let record = try AuthorityRecordCodec.decode(bytes).record
            guard record.kind == .controlCommit else { continue }
            let deltas = try AuthorityRecord.list(record.payload["deltas"]).map(
                AuthorityStore.DispositionDelta.init(value:))
            if deltas.contains(where: { $0.causes.contains(decision) }) {
                return (descriptor, record)
            }
        }
        throw TractandaError("notFound", "Review decision publisher control is missing")
    }

    private func privateActivationExists(_ f: Fixture, decisionID: String) -> Bool {
        FileManager.default.fileExists(
            atPath: f.sourceRoot.appendingPathComponent(".peer-review-activations/" + decisionID).path)
    }

    func testIncompleteForeignReviewControlHasNoEffectsUntilExactValidControlArrives() throws {
        let reviewed = try AuthorityReviewStoreTests.ReviewedFixture()
        let f = reviewed.base
        let result = try f.receiver.resolveAuthorityReview(reviewed.request())
        let validObjects = try objects(f.receiverRoot, fixture: f)
        let (validDescriptor, publisher) = try controlPublishing(result.decision, in: validObjects)

        // Preserve the source PRE cut and all deltas byte-for-byte at the field level, but
        // publish the same-origin control under a fresh UUIDv1 with an absent baseline anchor.
        var malformedPayload = publisher.payload
        malformedPayload["localParent"] = .list([])
        let missingBootstrapID = try Fixture.id()
        malformedPayload["bootstrap"] = .list([
            try AuthorityBinding(recordID: missingBootstrapID, sha256: String(repeating: "a", count: 64))
                .itemValue
        ])
        let malformed = try AuthorityRecord(
            recordID: try Fixture.id(), storeID: publisher.storeID,
            originReplicaID: publisher.originReplicaID, kind: .controlCommit,
            parentAuthorityIDs: publisher.parentAuthorityIDs, actorPrincipal: publisher.actorPrincipal,
            createdAt: publisher.createdAt, payload: malformedPayload)
        let malformedBytes = try AuthorityRecordCodec.encode(malformed)
        let malformedDescriptor = PeerPackage.Object(
            kind: .authority, id: malformed.recordID, length: malformedBytes.count,
            sha256: AuthorityRecordCodec.sha256(malformedBytes))
        let incompleteObjects =
            (validObjects.filter { $0.0.id != validDescriptor.id }
            + [(malformedDescriptor, malformedBytes)]).sorted { $0.0.id < $1.0.id }
        let inbound = try context(f)
        try f.source.configurePeerIntake(peers: [inbound])
        let incompletePacket = try f.packet(incompleteObjects)

        let before = try f.source.get(f.base.itemID)
        XCTAssertEqual(before.revisionID, f.base.revisionID)
        XCTAssertThrowsError(try f.source.get(reviewed.held.itemID, revisionID: reviewed.held.revisionID))
        XCTAssertThrowsError(try f.source.get(result.revision.itemID, revisionID: result.revision.revisionID))
        XCTAssertFalse(privateActivationExists(f, decisionID: result.decision.recordID))

        _ = try f.send(incompletePacket, context: inbound, to: f.source)

        XCTAssertNotEqual(try f.source.get(f.base.itemID).revisionID, result.revision.revisionID)
        XCTAssertThrowsError(try f.source.get(reviewed.held.itemID, revisionID: reviewed.held.revisionID))
        XCTAssertThrowsError(try f.source.get(result.revision.itemID, revisionID: result.revision.revisionID))
        XCTAssertFalse(privateActivationExists(f, decisionID: result.decision.recordID))

        // A later complete source proof remains applicable and keeps the original exact bytes.
        let completePacket = try f.packet(validObjects)
        _ = try f.send(completePacket, context: inbound, to: f.source)
        XCTAssertEqual(try f.source.get(reviewed.held.itemID).revisionID, result.revision.revisionID)
        XCTAssertEqual(
            try f.source.get(reviewed.held.itemID, revisionID: reviewed.held.revisionID), reviewed.held)
        XCTAssertTrue(privateActivationExists(f, decisionID: result.decision.recordID))
        for id in [reviewed.held.revisionID, result.revision.revisionID, result.decision.recordID] {
            XCTAssertEqual(
                try XCTUnwrap(objects(f.sourceRoot, fixture: f).first { $0.0.id == id }).1,
                try XCTUnwrap(validObjects.first { $0.0.id == id }).1)
        }
        try f.capacity()
    }
}
