import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class PeerMaterializationExchangeTests: XCTestCase {
    private func contexts(for f: PeerIntakeStoreTests.Fixture) throws -> (
        PeerPackage.Context, PeerPackage.Context, PeerPackage.Context
    ) {
        let sourceID = try XCTUnwrap(f.source.replicaID)
        let receiverID = try XCTUnwrap(
            ReplicaIdentity.load(root: f.receiverRoot, storeID: f.storeID, ownerUID: tractanda_uid())?
                .replicaID)
        let origins = [sourceID, receiverID].sorted()
        let raven = try PeerPackage.Context(
            peerID: "raven-exchange", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("raven-exchange-2".utf8)),
            permittedOrigins: origins)
        let stash = try PeerPackage.Context(
            peerID: "stash", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("stash-exchange-1".utf8)),
            permittedOrigins: origins)
        try f.receiver.configurePeerIntake(peers: [f.context, raven, stash])
        f.context = raven
        try f.source.configurePeerIntake(peers: [stash])
        return (raven, stash, try f.source.peerIntakeContext(peerID: "stash"))
    }

    private func editBody(_ f: PeerIntakeStoreTests.Fixture, value: String) throws -> Revision {
        try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            let current = try f.receiver.get(f.base.itemID)
            return try f.receiver.commit(
                CommitRequest(
                    action: .revise, itemID: current.itemID,
                    expectedRevisionID: current.revisionID, changes: ["body": .text(value)],
                    operationID: "receiver-body-" + (try PeerIntakeStoreTests.Fixture.id()))
            ).revision
        }
    }

    private func revisionIDs(_ store: ItemStore) throws -> Set<String> {
        Set(try store.exportCatalogueForVerification().map(\.revisionID))
    }

    private func controlCommitIDs(_ root: URL, origin: String) throws -> Set<String> {
        let directory = root.appendingPathComponent("authority/records")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        else { throw TractandaError("resourceLimit", "Authority fixture inventory is unavailable.") }
        var result: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            try AttachmentFixtureCapacity.requireFree(at: root)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, url.pathExtension == "authority" else { continue }
            let record = try AuthorityRecordCodec.decode(Data(contentsOf: url)).record
            if record.originReplicaID == origin && record.kind == .controlCommit {
                result.insert(record.recordID)
            }
        }
        return result
    }

    func testConcurrentAuthoredOriginalsConvergeWithoutReplacingOriginalsOrGrowingMerges() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let (_, _, sourceContext) = try contexts(for: f)
        let sourceRevision = try f.edit(subject: "source subject")
        let receiverRevision = try editBody(f, value: "receiver body")

        let sourcePacket = try f.packet(f.source.peerMetadataObjects(revisionID: sourceRevision.revisionID))
        let receiverPacket = try f.packet(
            f.receiver.peerMetadataObjects(revisionID: receiverRevision.revisionID))
        XCTAssertEqual(try f.send(sourcePacket, context: f.context).accepted, 1)
        XCTAssertEqual(try f.send(receiverPacket, context: sourceContext, to: f.source).accepted, 1)

        let receiverState = try f.receiver.itemState(f.base.itemID)
        let sourceState = try f.source.itemState(f.base.itemID)
        XCTAssertEqual(receiverState.status, .ready)
        XCTAssertEqual(sourceState.status, .ready)
        XCTAssertEqual(
            receiverState.frontier, [sourceRevision.revisionID, receiverRevision.revisionID].sorted())
        XCTAssertEqual(sourceState.frontier, receiverState.frontier)

        let receiverMerge = try f.receiver.get(f.base.itemID)
        let sourceMerge = try f.source.get(f.base.itemID)
        XCTAssertNotEqual(receiverMerge.revisionID, sourceMerge.revisionID)
        XCTAssertEqual(receiverMerge.fields["subject"], .text("source subject"))
        XCTAssertEqual(receiverMerge.fields["body"], .text("receiver body"))
        XCTAssertEqual(sourceMerge.fields["subject"], receiverMerge.fields["subject"])
        XCTAssertEqual(sourceMerge.fields["body"], receiverMerge.fields["body"])
        XCTAssertEqual(
            try f.receiver.get(f.base.itemID, revisionID: sourceRevision.revisionID), sourceRevision)
        XCTAssertEqual(
            try f.receiver.get(f.base.itemID, revisionID: receiverRevision.revisionID), receiverRevision)
        XCTAssertEqual(try f.source.get(f.base.itemID, revisionID: sourceRevision.revisionID), sourceRevision)
        XCTAssertEqual(
            try f.source.get(f.base.itemID, revisionID: receiverRevision.revisionID), receiverRevision)

        let receiverBeforeRetry = try revisionIDs(f.receiver)
        let sourceBeforeRetry = try revisionIDs(f.source)
        _ = try f.send(sourcePacket, context: f.context)
        _ = try f.send(receiverPacket, context: sourceContext, to: f.source)
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, receiverMerge.revisionID)
        XCTAssertEqual(try f.source.get(f.base.itemID).revisionID, sourceMerge.revisionID)
        XCTAssertEqual(try revisionIDs(f.receiver), receiverBeforeRetry)
        XCTAssertEqual(try revisionIDs(f.source), sourceBeforeRetry)
        try f.capacity()
    }

    func testAuthorityOnlyOriginalExchangeDoesNotMintLocalControlCommitsOrRevisions() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let (_, _, sourceContext) = try contexts(for: f)
        let sourceOrigin = try XCTUnwrap(f.source.replicaID)
        let receiverOrigin = try XCTUnwrap(
            ReplicaIdentity.load(root: f.receiverRoot, storeID: f.storeID, ownerUID: tractanda_uid())?
                .replicaID)
        let sourceControls = try controlCommitIDs(f.sourceRoot, origin: sourceOrigin)
        let receiverControls = try controlCommitIDs(f.receiverRoot, origin: receiverOrigin)
        let sourceRevisions = try revisionIDs(f.source)
        let receiverRevisions = try revisionIDs(f.receiver)
        let sourceReady = try f.source.itemState(f.base.itemID)
        let receiverReady = try f.receiver.itemState(f.base.itemID)

        func authorityObjects(_ root: URL) throws -> [(PeerPackage.Object, Data)] {
            let directory = root.appendingPathComponent("authority/records")
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            else { throw TractandaError("resourceLimit", "Authority fixture inventory is unavailable.") }
            var objects: [(PeerPackage.Object, Data)] = []
            while let url = enumerator.nextObject() as? URL {
                try f.capacity()
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                    url.pathExtension == "authority"
                else { continue }
                let bytes = try Data(contentsOf: url)
                let record = try AuthorityRecordCodec.decode(bytes).record
                objects.append(
                    (
                        .init(
                            kind: .authority, id: record.recordID, length: bytes.count,
                            sha256: AuthorityRecordCodec.sha256(bytes)), bytes
                    ))
                guard objects.count < 256 else {
                    throw TractandaError("resourceLimit", "Tiny authority exchange exceeded its cap.")
                }
            }
            return objects.sorted { $0.0.id < $1.0.id }
        }

        for _ in 0..<3 {
            _ = try f.send(f.packet(authorityObjects(f.sourceRoot)), context: f.context)
            _ = try f.send(
                f.packet(authorityObjects(f.receiverRoot)), context: sourceContext, to: f.source)
        }
        XCTAssertEqual(try controlCommitIDs(f.sourceRoot, origin: sourceOrigin), sourceControls)
        XCTAssertEqual(try controlCommitIDs(f.receiverRoot, origin: receiverOrigin), receiverControls)
        XCTAssertEqual(try revisionIDs(f.source), sourceRevisions)
        XCTAssertEqual(try revisionIDs(f.receiver), receiverRevisions)
        XCTAssertEqual(try f.source.itemState(f.base.itemID).status, sourceReady.status)
        XCTAssertEqual(try f.receiver.itemState(f.base.itemID).status, receiverReady.status)
        XCTAssertEqual(sourceReady.status, .ready)
        XCTAssertEqual(receiverReady.status, .ready)
        try f.capacity()
    }
}
