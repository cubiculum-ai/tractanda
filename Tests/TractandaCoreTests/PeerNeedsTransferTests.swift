import CTractandaPlatform
import XCTest

@testable import TractandaCore

/// Real retained bytes and receipts; knownComplete means byte continuity, never authority.
final class PeerNeedsTransferTests: XCTestCase {
    private typealias Fixture = AtomicAuthorityStoreFixture
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func setup() throws -> (Fixture, ItemIndex, PeerIntakeCoordinator, AuthorityStore.RetainedObject)
    {
        let f = try Fixture()
        try f.activateAndOpen()
        let result = try f.source.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("transfer compare")],
                operationID: "atomic-transfer-source"))
        XCTAssertTrue(result.isIndexReady, result.warnings.joined(separator: "\n"))
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        do {
            let coordinator = PeerIntakeCoordinator(
                root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
            let head = try XCTUnwrap(index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)))
            let row = try XCTUnwrap(index.retainedAuthorityObject(id: head.recordID))
            return (f, index, coordinator, row)
        } catch {
            index.close()
            throw error
        }
    }
    private func physical(
        _ row: AuthorityStore.RetainedObject, coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws -> AuthorityStore.RetainedObject {
        var current = row
        for _ in 0..<10 {
            let original = try CanonicalAuthorityOriginal(coordinator.bytes(current))
            if case .atomic(let record) = original.payload, record.kind == .atomicControlPart {
                return current
            }
            let child = try XCTUnwrap(original.physicalChildren().first)
            current = try XCTUnwrap(index.retainedAuthorityObject(id: child.binding.recordID))
            XCTAssertEqual(current.descriptor.sha256, child.binding.sha256)
        }
        throw TractandaError("fixture", "Tiny atomic fixture has no bounded physical part")
    }
    func testAtomicRootAndPartAreKnownBytesWithoutPromotingPartToCutOrWritingOriginals() throws {
        let (f, index, coordinator, root) = try setup()
        defer { index.close() }
        let part = try physical(root, coordinator: coordinator, index: index)
        let rootBytes = try coordinator.bytes(root)
        let partBytes = try coordinator.bytes(part)
        let beforeHead = try index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID))
        let beforePart = try index.authorityDisposition(id: part.descriptor.id)?.disposition
        let binding = try AuthorityBinding(recordID: part.descriptor.id, sha256: part.descriptor.sha256)
        XCTAssertFalse(try index.hasValidatedAuthorityControl(binding))
        let page = try PeerNeedsTransfer.compare(
            [root.descriptor, part.descriptor], coordinator: coordinator, index: index, progress: {})
        XCTAssertEqual(page.objects.map(\.state), [.knownComplete, .knownComplete])
        XCTAssertEqual(page.objects.last?.disposition, beforePart)
        XCTAssertTrue(page.complete)
        XCTAssertEqual(page.nextOffset, 2)
        XCTAssertEqual(try index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)), beforeHead)
        XCTAssertFalse(try index.hasValidatedAuthorityControl(binding))
        XCTAssertEqual(try coordinator.bytes(root), rootBytes)
        XCTAssertEqual(try coordinator.bytes(part), partBytes)
        try f.capacity()
    }
    func testConflictingDigestAndTinyReadBudgetCannotClaimCompletion() throws {
        let (f, index, coordinator, root) = try setup()
        defer { index.close() }
        let wrong = PeerPackage.Object(
            kind: .authority, id: root.descriptor.id, length: root.descriptor.length,
            sha256: String(repeating: "f", count: 64))
        XCTAssertThrowsError(
            try PeerNeedsTransfer.compare([wrong], coordinator: coordinator, index: index, progress: {})
        ) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "peerObjectCollision")
        }
        let page = try PeerNeedsTransfer.compare(
            [root.descriptor], coordinator: coordinator, index: index, limits: .init(maximumReadBytes: 1),
            progress: {})
        XCTAssertEqual(page.objects.map(\.state), [.deferred])
        XCTAssertEqual(page.nextOffset, 1)
        XCTAssertTrue(page.complete, "Descriptor observation completed, not byte/authority acceptance")
        try f.capacity()
    }
    func testRetainedAuthorityWithForeignStoreIdentityFailsBeforeReceiptContinuity() throws {
        let (f, index, coordinator, _) = try setup()
        defer { index.close() }
        let record = try AuthorityRecord(
            recordID: id(), storeID: id(), originReplicaID: XCTUnwrap(f.source.replicaID),
            kind: .controlCommit, actorPrincipal: "user:admin", createdAt: Timestamp.now(),
            payload: [
                "controls": .list([]), "localParent": .list([]), "deltas": .list([]), "bootstrap": .list([]),
            ])
        let bytes = try AuthorityRecordCodec.encode(record)
        let object = PeerPackage.Object(
            kind: .authority, id: record.recordID, length: bytes.count,
            sha256: AuthorityRecordCodec.sha256(bytes))
        let context = try coordinator.context(peerID: "local")
        let manifest = try coordinator.stageObjects([(object, bytes)], context: context, packageID: id())
        let publication = PeerIntakeJournal.Publication(
            packageID: manifest.packageID,
            manifestDigest: AuthorityRecordCodec.sha256(try JSON.encode(manifest)), context: context,
            contextToken: "fixture-raw-only", arrivalMinute: "2026/10/23/16/00")
        try coordinator.journal.prepare(publication)
        try coordinator.journal.seal(manifest.packageID)
        let path = try coordinator.journal.publishOriginal(object, bytes: bytes, publication: publication)
        // Raw retained metadata is deliberately inconsistent. This does not accept any control.
        try index.retainAuthorityObject(
            .init(
                descriptor: object, path: path, packageID: manifest.packageID,
                peerID: context.peerID, configurationDigest: context.configurationDigest,
                permittedOrigin: true),
            revision: nil, authority: AuthorityRecordCodec.decode(bytes))
        XCTAssertThrowsError(
            try PeerNeedsTransfer.compare([object], coordinator: coordinator, index: index, progress: {})
        ) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "peerObjectCollision")
        }
        XCTAssertFalse(
            try index.hasValidatedAuthorityControl(.init(recordID: object.id, sha256: object.sha256)))
        try f.capacity()
    }
}
