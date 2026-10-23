import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class PeerAtomicPublicationTests: XCTestCase {
    private func frame(_ fixture: PeerIntakeStoreTests.Fixture) throws -> PeerLocalPackageArchive {
        try fixture.capacity()
        let root = fixture.directory.appendingPathComponent(
            "frame-" + (try PeerIntakeStoreTests.Fixture.id()))
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return try .init(root: root, limits: .init(maximumStoredBytes: 4 * 1024 * 1024))
    }
    private func values(_ f: PeerIntakeStoreTests.Fixture) throws -> [(PeerPackage.Object, Data)] {
        try f.source.peerMetadataObjects(revisionID: f.base.revisionID).sorted { $0.0.id < $1.0.id }
    }

    func testStreamedJournalStagesFrozenManifestAndBytesWithoutCanonicalSeal() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        let archive = try frame(f)
        let coordinator = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let context = try coordinator.context(peerID: "local")
        let packageID = try PeerIntakeStoreTests.Fixture.id()
        let originals = try values(f)
        let manifest = try coordinator.stageStreamedObjects(
            archive: archive, context: context,
            packageID: packageID, inputIdentity: String(repeating: "a", count: 64),
            makeObjects: {
                var iterator = originals.makeIterator()
                return { iterator.next() }
            })
        var received: [(PeerPackage.Object, Data)] = []
        try coordinator.journal.walk(packageID) { object, bytes in
            received.append((object, try XCTUnwrap(bytes)))
        }
        XCTAssertEqual(received.map(\.0), originals.map(\.0))
        XCTAssertEqual(received.map(\.1), originals.map(\.1))
        XCTAssertNil(
            try coordinator.journal.publication(packageID),
            "Private staging is not a physical or accepted seal")
        XCTAssertEqual(
            try coordinator.stageStreamedObjects(
                archive: archive, context: context,
                packageID: packageID, inputIdentity: String(repeating: "a", count: 64),
                makeObjects: {
                    var iterator = originals.makeIterator()
                    return { iterator.next() }
                }), manifest)
        XCTAssertEqual(try f.source.get(f.base.itemID).revisionID, f.base.revisionID)
        try f.capacity()
    }

    func testSecondPassChangedBytesCannotPublishOrAcquireAcceptance() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        let archive = try frame(f)
        let coordinator = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let context = try coordinator.context(peerID: "local")
        let packageID = try PeerIntakeStoreTests.Fixture.id()
        let originals = try values(f)
        var pass = 0
        XCTAssertThrowsError(
            try coordinator.stageStreamedObjects(
                archive: archive, context: context,
                packageID: packageID, inputIdentity: String(repeating: "b", count: 64),
                makeObjects: {
                    pass += 1
                    let current = pass
                    var iterator = originals.makeIterator()
                    return {
                        guard let pair = iterator.next() else { return nil }
                        return current == 2 ? (pair.0, Data("changed".utf8)) : pair
                    }
                }))
        XCTAssertNil(try coordinator.journal.publication(packageID))
        XCTAssertEqual(try f.source.get(f.base.itemID).revisionID, f.base.revisionID)
        try f.capacity()
    }

    func testInterruptedSecondPassResumesExactPackageWithoutNewIdentityOrSeal() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        let archive = try frame(f)
        let coordinator = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let context = try coordinator.context(peerID: "local")
        let packageID = try PeerIntakeStoreTests.Fixture.id()
        let originals = try values(f)
        var pass = 0
        XCTAssertThrowsError(
            try coordinator.stageStreamedObjects(
                archive: archive, context: context,
                packageID: packageID, inputIdentity: String(repeating: "c", count: 64),
                makeObjects: {
                    pass += 1
                    let current = pass
                    var iterator = originals.makeIterator()
                    var seen = 0
                    return {
                        if current == 2 && seen == 1 { throw CancellationError() }
                        seen += 1
                        return iterator.next()
                    }
                }))
        XCTAssertNil(try coordinator.journal.publication(packageID))
        let manifest = try coordinator.stageStreamedObjects(
            archive: archive, context: context,
            packageID: packageID, inputIdentity: String(repeating: "c", count: 64),
            makeObjects: {
                var iterator = originals.makeIterator()
                return { iterator.next() }
            })
        XCTAssertEqual(manifest.packageID, packageID)
        var count = 0
        try coordinator.journal.walk(packageID) { _, bytes in
            XCTAssertNotNil(bytes)
            count += 1
        }
        XCTAssertEqual(count, originals.count)
        XCTAssertNil(try coordinator.journal.publication(packageID))
        try f.capacity()
    }
    func testUnacceptedContextOnAppliedPacketIsActuallyChargedAndReconstructed() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let index = try ItemIndex(
            path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let initial = PeerIntakeCoordinator(
            root: f.receiverRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let pin = try XCTUnwrap(initial.configuration()?.bootstrap)
        let raw = try XCTUnwrap(index.retainedAuthorityObject(id: pin.recordID))
        let pageBytes = try JSON.encode(PeerPackage.Page(objects: [raw.descriptor], children: []))
        var limits = PeerPackage.Limits()
        limits.maximumStagedBytes = UInt64(pageBytes.count * 2 - 1)
        let coordinator = PeerIntakeCoordinator(
            root: f.receiverRoot, ownerUID: tractanda_uid(), storeID: f.storeID, limits: limits)
        let rootID = try PeerIntakeStoreTests.Fixture.id()
        func page(_ id: String) -> PeerPackage.Object {
            .init(
                kind: .index, id: id, length: pageBytes.count,
                sha256: AuthorityRecordCodec.sha256(pageBytes))
        }
        let first = page(try PeerIntakeStoreTests.Fixture.id())
        try coordinator.journal.stageAtomicContextPage(
            packageID: raw.packageID, rootID: rootID, object: first, bytes: pageBytes)
        XCTAssertEqual(try coordinator.journal.stagedBytesForTesting(), UInt64(pageBytes.count))
        try coordinator.journal.stageAtomicContextPage(
            packageID: raw.packageID, rootID: rootID, object: first, bytes: pageBytes)
        XCTAssertEqual(try coordinator.journal.stagedBytesForTesting(), UInt64(pageBytes.count))
        let second = page(try PeerIntakeStoreTests.Fixture.id())
        XCTAssertThrowsError(
            try coordinator.journal.stageAtomicContextPage(
                packageID: raw.packageID, rootID: rootID, object: second, bytes: pageBytes)
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
        XCTAssertNil(
            try coordinator.journal.files.readIfPresent(
                path: ["authority", "intake", raw.packageID, "atomic-context", rootID, "pages", second.id],
                maximumBytes: PeerPackage.maximumPageBytes))
        let reopened = PeerIntakeCoordinator(
            root: f.receiverRoot, ownerUID: tractanda_uid(), storeID: f.storeID, limits: limits)
        XCTAssertEqual(try reopened.journal.stagedBytesForTesting(), UInt64(pageBytes.count))
        XCTAssertNil(
            try reopened.journal.atomicAcceptance(
                packageID: raw.packageID, root: .init(recordID: rootID, sha256: first.sha256)))
        try f.capacity()
    }

}
