import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class SharedAuthorityExportTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture

    private func third(_ f: Fixture) throws -> ItemStore {
        // Three tiny metadata stores estimate24MiB, within the configured fixture cap.
        guard AttachmentFixtureCapacity.fixtureCapBytes >= 24 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Three-store fixture estimate")
        }
        try f.capacity()
        let root = f.directory.appendingPathComponent("export-third")
        let store = try f.openFreshSharedReplica(root, f.receiverAccounts)
        try store.configurePeerIntake(peers: [f.context])
        try f.bootstrap(to: store)
        return store
    }

    private func exported(
        _ store: ItemStore, revisionID: String, context: PeerPackage.Context,
        fixture f: Fixture
    ) throws -> PeerIntakeStoreTests.Packet {
        let boundary = try store.capturePeerInventory(context: context)
        let handle = try store.beginPeerExport(
            context: context, planID: Fixture.id(),
            packageID: Fixture.id(), boundary: boundary)
        var cursor: PeerInventory.Cursor?
        var selected: PeerInventory.Entry?
        repeat {
            let page = try store.peerInventoryPage(context: context, boundary: boundary, cursor: cursor)
            selected = selected ?? page.entries.first { $0.descriptor.id == revisionID }
            cursor = page.nextCursor
        } while cursor != nil
        _ = try store.selectPeerExport(
            context: context, handle: handle,
            entries: [XCTUnwrap(selected)], finish: true)
        var manifest: PeerPackage.Manifest?
        for _ in 0..<512 {
            try f.capacity()
            let status = try store.stepPeerExport(
                context: context, handle: handle,
                window: .init(maximumUnits: 8, maximumEdges: 16))
            XCTAssertEqual(status.unsupported, 0)
            XCTAssertEqual(status.missing, 0)
            manifest = status.manifest
            if manifest != nil { break }
        }
        let sealed = try XCTUnwrap(manifest)
        var pending = [sealed.root]
        var seen: Set<String> = []
        var objects: [(PeerPackage.Object, Data)] = []
        var byteCount = 0
        while let descriptor = pending.popLast() {
            if !seen.insert(descriptor.id).inserted { continue }
            let bytes = try store.readPeerExport(
                context: context, handle: handle, object: descriptor,
                offset: 0
            ).bytes
            XCTAssertEqual(bytes.count, descriptor.length)
            byteCount += bytes.count
            guard byteCount < 8 * 1024 * 1024 else {
                throw TractandaError("resourceLimit", "Tiny exported metadata cap")
            }
            objects.append((descriptor, bytes))
            if descriptor.kind == .index {
                let page = try PeerPackage.decode(PeerPackage.Page.self, bytes)
                pending += page.objects + page.children
            }
        }
        return .init(manifest: sealed, objects: objects)
    }

    func testCurrentExporterClosesExactReviewAndRelayPreservesOriginalAuthority() throws {
        let reviewed = try AuthorityReviewStoreTests.ReviewedFixture()
        let f = reviewed.base
        var recipient: ItemStore? = try third(f)  // Pin baseline BEFORE the later reviewed originals arrive.
        defer { recipient = nil }
        let reviewOrigin = try XCTUnwrap(f.receiver.replicaID)
        let context = try PeerPackage.Context(
            peerID: "shared-export-relay", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("shared-export-relay".utf8)),
            permittedOrigins: [f.origin, reviewOrigin].sorted())
        try f.receiver.configurePeerIntake(peers: [f.context, context])
        try f.source.configurePeerIntake(peers: [context])
        try recipient!.configurePeerIntake(peers: [f.context, context])
        let result = try f.receiver.resolveAuthorityReview(reviewed.request())
        let direct = try exported(
            f.receiver, revisionID: result.revision.revisionID, context: context, fixture: f)
        let ids = Set(direct.objects.map { $0.0.id })
        for id in [
            reviewed.held.revisionID, result.revision.revisionID, result.decision.recordID,
            reviewed.evidence.recordID, f.configuration.revisionID,
        ] {
            XCTAssertTrue(ids.contains(id), "Exporter omitted exact review dependency \(id)")
        }
        _ = try f.send(direct, context: context, to: f.source)
        XCTAssertEqual(try f.source.get(reviewed.held.itemID), result.revision)
        let relayed = try exported(
            f.source, revisionID: result.revision.revisionID, context: context, fixture: f)
        for id in [reviewed.held.revisionID, result.revision.revisionID, result.decision.recordID] {
            XCTAssertEqual(
                try XCTUnwrap(relayed.objects.first { $0.0.id == id }).1,
                try XCTUnwrap(direct.objects.first { $0.0.id == id }).1)
        }
        _ = try f.send(relayed, context: context, to: recipient!)
        XCTAssertEqual(try recipient!.get(reviewed.held.itemID), result.revision)
        XCTAssertEqual(
            try recipient!.get(reviewed.held.itemID, revisionID: reviewed.held.revisionID), reviewed.held)
        XCTAssertThrowsError(
            try recipient!.withAccess(forUID: f.receiverAccounts.bob) {
                try recipient!.get(reviewed.held.itemID)
            })
        try recipient!.rebuildIndex()
        XCTAssertEqual(try recipient!.get(reviewed.held.itemID), result.revision)
        try f.capacity()
    }
}
