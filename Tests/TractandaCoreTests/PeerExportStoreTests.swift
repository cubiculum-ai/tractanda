import XCTest

@testable import TractandaCore

final class PeerExportStoreTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private func selected(_ f: Fixture, revision: Revision? = nil) throws -> PeerExportPlan.Handle {
        try f.source.configurePeerIntake(peers: [f.context])
        let boundary = try f.source.capturePeerInventory(context: f.context)
        let handle = try f.source.beginPeerExport(
            context: f.context, planID: Fixture.id(), packageID: Fixture.id(), boundary: boundary)
        var cursor: PeerInventory.Cursor?
        var selected: PeerInventory.Entry?
        repeat {
            let page = try f.source.peerInventoryPage(context: f.context, boundary: boundary, cursor: cursor)
            selected = selected ?? page.entries.first { $0.descriptor.id == (revision ?? f.base).revisionID }
            cursor = page.nextCursor
        } while cursor != nil
        _ = try f.source.selectPeerExport(
            context: f.context, handle: handle, entries: [XCTUnwrap(selected)], finish: true)
        return handle
    }
    private func finish(_ f: Fixture, _ handle: PeerExportPlan.Handle) throws -> PeerPackage.Manifest {
        for _ in 0..<1024 {
            try f.capacity()
            let status = try f.source.stepPeerExport(
                context: f.context, handle: handle, window: .init(maximumUnits: 3, maximumEdges: 2))
            if let manifest = status.manifest { return manifest }
            XCTAssertEqual(status.missing, 0)
            XCTAssertEqual(status.unsupported, 0)
        }
        throw TractandaError("testTimeout", "Tiny export did not close.")
    }
    private func packet(_ f: Fixture, handle: PeerExportPlan.Handle, manifest: PeerPackage.Manifest) throws
        -> PeerIntakeStoreTests.Packet
    {
        var pending = [manifest.root]
        var seen: Set<String> = []
        var objects: [(PeerPackage.Object, Data)] = []
        while let descriptor = pending.popLast() {
            if !seen.insert(descriptor.id).inserted { continue }
            let chunk = try f.source.readPeerExport(
                context: f.context, handle: handle, object: descriptor, offset: 0)
            XCTAssertEqual(chunk.bytes.count, descriptor.length)
            objects.append((descriptor, chunk.bytes))
            if descriptor.kind == .index {
                let page = try PeerPackage.decode(PeerPackage.Page.self, chunk.bytes)
                pending += page.objects + page.children
            }
        }
        return .init(manifest: manifest, objects: objects)
    }
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected) }
    }
    func testActualMetadataClosureContainsExactParentsPoliciesAndSelectedEvidence() throws {
        let f = try Fixture()
        try f.bootstrap()
        let child = try f.edit(subject: "outbound child")
        let handle = try selected(f, revision: child)
        let manifest = try finish(f, handle)
        let packet = try packet(f, handle: handle, manifest: manifest)
        let ids = Set(packet.objects.map { $0.0.id })
        XCTAssertTrue(ids.contains(child.revisionID))
        XCTAssertTrue(ids.contains(f.base.revisionID))
        XCTAssertTrue(ids.contains(f.configuration.revisionID))
        XCTAssertTrue(packet.objects.contains { Fixture.isEvidence($0, for: child.revisionID) })
        let result = try f.send(packet)
        XCTAssertGreaterThanOrEqual(result.accepted, 1)
        XCTAssertEqual(try f.receiver.get(child.itemID).fields["subject"], .text("outbound child"))
        XCTAssertEqual(
            try JSON.encode(f.source.peerExportManifest(context: f.context, handle: handle)),
            try JSON.encode(manifest as PeerPackage.Manifest?))
    }
    func testJournaledCrashReopensAndSealedRetryUsesIdenticalPageAndManifestBytes() throws {
        let f = try Fixture()
        let handle = try selected(f)
        var interrupted = false
        f.source.peerExportBoundaryForTesting = { boundary in
            if boundary == .journaled, !interrupted {
                interrupted = true
                throw TractandaError("injectedCrash", "After durable export intent")
            }
        }
        code("injectedCrash") { _ = try f.source.stepPeerExport(context: f.context, handle: handle) }
        f.source.peerExportBoundaryForTesting = nil
        f.source = nil
        f.source = try Fixture.open(f.sourceRoot, f.sourceAccounts)
        let reopened = try f.source.reopenPeerExport(
            context: f.context, planID: handle.planID, packageID: handle.packageID)
        let manifest = try finish(f, reopened)
        let original = try JSON.encode(manifest)
        let bytes = try f.source.readPeerExport(
            context: f.context, handle: reopened, object: manifest.root, offset: 0
        ).bytes
        f.source = nil
        f.source = try Fixture.open(f.sourceRoot, f.sourceAccounts)
        XCTAssertEqual(
            try JSON.encode(f.source.peerExportManifest(context: f.context, handle: handle)),
            try JSON.encode(manifest as PeerPackage.Manifest?))
        XCTAssertEqual(
            try JSON.encode(XCTUnwrap(f.source.stepPeerExport(context: f.context, handle: handle).manifest)),
            original)
        XCTAssertEqual(
            try f.source.readPeerExport(context: f.context, handle: handle, object: manifest.root, offset: 0)
                .bytes, bytes)
    }
    func testResourcePauseCancellationAndTamperedDescriptorPreserveOriginals() throws {
        let f = try Fixture()
        let handle = try selected(f)
        let before = try f.source.exportCatalogueForVerification().map(\.revisionID)
        code("resourceLimit") {
            _ = try f.source.stepPeerExport(
                context: f.context, handle: handle, window: .init(maximumReadBytes: 1))
        }
        code("cancelled") {
            _ = try f.source.stepPeerExport(
                context: f.context, handle: handle,
                progress: { throw TractandaError("cancelled", "Test cancellation") })
        }
        let manifest = try finish(f, handle)
        let wrong = PeerPackage.Object(
            kind: .index, id: manifest.root.id, length: manifest.root.length,
            sha256: String(repeating: "a", count: 64))
        code("peerObjectCollision") {
            _ = try f.source.readPeerExport(context: f.context, handle: handle, object: wrong, offset: 0)
        }
        XCTAssertEqual(try f.source.exportCatalogueForVerification().map(\.revisionID), before)
    }
    func testDirectManifestAndReadRejectValidJSONManifestTampering() throws {
        let f = try Fixture()
        let handle = try selected(f)
        let manifest = try finish(f, handle)
        let wrongRoot = PeerPackage.Object(
            kind: .index, id: manifest.root.id, length: manifest.root.length,
            sha256: String(repeating: "0", count: 64))
        let tampered = PeerPackage.Manifest(
            packageID: manifest.packageID, storeID: manifest.storeID, root: wrongRoot)
        try tampered.validate()
        let file = f.sourceRoot.appendingPathComponent("authority/export/" + handle.planID + "/manifest.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try JSON.encode(tampered).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        code("invalidPeerExport") { _ = try f.source.peerExportManifest(context: f.context, handle: handle) }
        code("invalidPeerExport") {
            _ = try f.source.readPeerExport(
                context: f.context, handle: handle, object: manifest.root, offset: 0)
        }
        code("invalidPeerExport") { _ = try f.source.stepPeerExport(context: f.context, handle: handle) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("{".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        XCTAssertThrowsError(try f.source.peerExportManifest(context: f.context, handle: handle))
        XCTAssertThrowsError(
            try f.source.readPeerExport(context: f.context, handle: handle, object: manifest.root, offset: 0))
        try f.capacity()
    }
    func testOriginalDependencyIsIncludedInSealedPlan() throws {
        let f = try Fixture()
        let bytes = Data("tiny attachment".utf8)
        let attached = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            let upload = try f.source.beginAttachment(
                .init(
                    itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
                    operationID: Fixture.id(), filename: "tiny.txt", mediaType: "text/plain",
                    byteCount: Int64(bytes.count), sha256: AuthorityRecordCodec.sha256(bytes)))
            let id = try XCTUnwrap(upload.uploadID)
            _ = try f.source.appendAttachment(uploadID: id, offset: 0, data: bytes)
            return try f.source.finishAttachment(uploadID: id).revision
        }
        let handle = try selected(f, revision: attached)
        let manifest = try finish(f, handle)
        let packet = try packet(f, handle: handle, manifest: manifest)
        XCTAssertTrue(packet.objects.contains { $0.0.kind == .attachment && $0.1 == bytes })
        try f.capacity()
    }

    func testDecodedFutureInventoryCutoffIsRejectedAtBegin() throws {
        let f = try Fixture()
        try f.source.configurePeerIntake(peers: [f.context])
        let boundary = try f.source.capturePeerInventory(context: f.context)
        var fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSON.encode(boundary)) as? [String: Any])
        let maximum = try XCTUnwrap(fields["maximumSequence"] as? NSNumber).int64Value
        fields["maximumSequence"] = NSNumber(value: maximum + 1)
        let future = try JSON.decode(
            PeerInventory.Boundary.self, JSONSerialization.data(withJSONObject: fields))
        code("peerExportChanged") {
            _ = try f.source.beginPeerExport(
                context: f.context, planID: Fixture.id(), packageID: Fixture.id(), boundary: future)
        }
        _ = try f.edit(subject: "later ordinary publication")
        _ = try f.source.beginPeerExport(
            context: f.context, planID: Fixture.id(), packageID: Fixture.id(), boundary: boundary)
        try f.capacity()
    }
    func testPageArtifactCrashResumesReservedExactIndexIdentity() throws {
        let f = try Fixture()
        let handle = try selected(f)
        for _ in 0..<512 {
            if try f.source.inspectPeerExport(context: f.context, handle: handle).phase == .leaves { break }
            _ = try f.source.stepPeerExport(
                context: f.context, handle: handle, window: .init(maximumUnits: 1))
        }
        XCTAssertEqual(try f.source.inspectPeerExport(context: f.context, handle: handle).phase, .leaves)
        f.source.peerExportBoundaryForTesting = { boundary in
            if boundary == .artifactsPersisted {
                throw TractandaError("injectedPageCrash", "Reserved index page persisted")
            }
        }
        code("injectedPageCrash") {
            _ = try f.source.stepPeerExport(
                context: f.context, handle: handle, window: .init(maximumUnits: 1))
        }
        let pages = f.sourceRoot.appendingPathComponent("authority/export/" + handle.planID + "/pages")
        let before = try FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil)
        XCTAssertEqual(before.count, 1)
        let pageBytes = try Data(contentsOf: XCTUnwrap(before.first))
        f.source.peerExportBoundaryForTesting = nil
        f.source = nil
        f.source = try Fixture.open(f.sourceRoot, f.sourceAccounts)
        let manifest = try finish(f, handle)
        XCTAssertEqual(manifest.root.id + ".json", before.first?.lastPathComponent)
        XCTAssertEqual(
            try f.source.readPeerExport(context: f.context, handle: handle, object: manifest.root, offset: 0)
                .bytes, pageBytes)
        let after = try FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(after.map(\.lastPathComponent)), Set(before.map(\.lastPathComponent)))
        try f.capacity()
    }

}
