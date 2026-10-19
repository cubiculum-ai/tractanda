import XCTest

@testable import TractandaCore

final class PeerExportBoundaryTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture

    private func code(
        _ expected: String, _ body: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }

    private func begin(_ fixture: Fixture) throws -> (PeerExportPlan.Handle, PeerInventory.Entry) {
        try fixture.source.configurePeerIntake(peers: [fixture.context])
        let boundary = try fixture.source.capturePeerInventory(context: fixture.context)
        var cursor: PeerInventory.Cursor?
        var selected: PeerInventory.Entry?
        var calls = 0
        repeat {
            let page = try fixture.source.peerInventoryPage(
                context: fixture.context, boundary: boundary, cursor: cursor, limit: 16)
            if let root = page.entries.first(where: { $0.descriptor.id == fixture.base.revisionID }) {
                selected = root
            }
            cursor = page.nextCursor
            calls += 1
            XCTAssertLessThan(calls, 64, "Finite inventory scan must advance.")
        } while cursor != nil
        let root = try XCTUnwrap(selected, "Fixture base must appear in its actual finite inventory.")
        let handle = try fixture.source.beginPeerExport(
            context: fixture.context, planID: Fixture.id(), packageID: Fixture.id(), boundary: boundary)
        _ = try fixture.source.selectPeerExport(
            context: fixture.context, handle: handle, entries: [root], finish: true)
        try fixture.capacity()
        return (handle, root)
    }

    private func seal(_ fixture: Fixture, handle: PeerExportPlan.Handle) throws -> PeerPackage.Manifest {
        var status = try fixture.source.inspectPeerExport(context: fixture.context, handle: handle)
        var calls = 0
        while status.phase != .sealed {
            status = try fixture.source.stepPeerExport(
                context: fixture.context, handle: handle,
                window: .init(
                    maximumUnits: 16, maximumEdges: 64,
                    maximumReadBytes: 32 * 1024 * 1024, maximumJournalBytes: 1024 * 1024))
            calls += 1
            try fixture.capacity()
            XCTAssertLessThan(calls, 1024, "Bounded export steps must reach a terminal phase.")
            if status.phase != .sealed {
                XCTAssertTrue(
                    status.pending > 0 || status.phase == .leaves || status.phase == .indexes,
                    "A nonsealed export must report work or a construction phase.")
            }
        }
        return try XCTUnwrap(try fixture.source.peerExportManifest(context: fixture.context, handle: handle))
    }

    private func sourceBytes(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for directory in ["items", "authority/records"] {
            let folder = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
            else {
                continue
            }
            while let file = walker.nextObject() as? URL {
                guard file.pathExtension == "tractanda" || file.pathExtension == "authority" else { continue }
                result[file.path] = try Data(contentsOf: file)
            }
        }
        return result
    }

    private func slot(
        _ fixture: Fixture, handle: PeerExportPlan.Handle, id: String
    ) throws -> PeerExportPlan.Slot {
        let page = try fixture.source.peerExportObjectPage(
            context: fixture.context, handle: handle, limit: 128)
        return try XCTUnwrap(page.objects.first(where: { $0.id == id }))
    }

    func testPublicationAfterClosedRootsCannotWidenPlanAndPlanningDoesNotPublishCanonicalRecords() throws {
        let fixture = try Fixture()
        let before = try sourceBytes(fixture.sourceRoot)
        let (handle, root) = try begin(fixture)
        XCTAssertEqual(
            try sourceBytes(fixture.sourceRoot), before,
            "Boundary capture, root selection and private plan journals do not publish canonical records.")
        let later = try fixture.edit(subject: "published after root selection")
        let afterPublication = try sourceBytes(fixture.sourceRoot)
        XCTAssertGreaterThan(Set(afterPublication.keys).subtracting(before.keys).count, 0)
        XCTAssertTrue(before.allSatisfy { afterPublication[$0.key] == $0.value })
        XCTAssertEqual(try fixture.source.get(later.itemID), later)
        let manifest = try seal(fixture, handle: handle)
        XCTAssertEqual(try slot(fixture, handle: handle, id: root.descriptor.id).root, true)
        XCTAssertNil(
            try fixture.source.peerExportObjectPage(context: fixture.context, handle: handle)
                .objects.first(where: { $0.id == later.revisionID }))
        XCTAssertEqual(manifest.packageID, handle.packageID)
        try fixture.capacity()
    }

    func testPolicyChangeAndCredentialRotationRejectExistingPlanAndReadHandles() throws {
        do {
            let fixture = try Fixture()
            let (handle, root) = try begin(fixture)
            let manifest = try seal(fixture, handle: handle)
            _ = try fixture.source.readPeerExport(
                context: fixture.context, handle: handle, object: root.descriptor, offset: 0)
            _ = try fixture.source.configureAccess(
                .object(["profile": .text(AccessConfiguration.profile), "users": .list([.text("admin")])]),
                operationID: try Fixture.id())
            code("peerExportChanged") {
                _ = try fixture.source.inspectPeerExport(context: fixture.context, handle: handle)
            }
            code("peerExportChanged") {
                _ = try fixture.source.readPeerExport(
                    context: fixture.context, handle: handle, object: manifest.root, offset: 0)
            }
            try fixture.capacity()
        }
        do {
            let fixture = try Fixture()
            let (handle, root) = try begin(fixture)
            _ = try seal(fixture, handle: handle)
            let replacement = try PeerPackage.Context(
                peerID: fixture.context.peerID, storeID: fixture.context.storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data("rotated-config".utf8)),
                permittedOrigins: fixture.context.permittedOrigins)
            try fixture.source.rotatePeerIntakeCredential(
                peerID: fixture.context.peerID, replacement: replacement, operationID: try Fixture.id())
            code("peerConfigurationChanged") {
                _ = try fixture.source.readPeerExport(
                    context: fixture.context, handle: handle, object: root.descriptor, offset: 0)
            }
            code("peerExportChanged") {
                _ = try fixture.source.readPeerExport(
                    context: replacement, handle: handle, object: root.descriptor, offset: 0)
            }
            try fixture.capacity()
        }
    }

    func testSealedArtifactsSurviveReopenAndIndexRebuildWhileUnfinishedPlanInvalidates() throws {
        let fixture = try Fixture()
        let (sealedHandle, root) = try begin(fixture)
        let manifest = try seal(fixture, handle: sealedHandle)
        let (unfinishedHandle, _) = try begin(fixture)
        XCTAssertEqual(
            try fixture.source.inspectPeerExport(context: fixture.context, handle: unfinishedHandle).phase,
            .closure)

        fixture.source = nil
        fixture.source = try Fixture.open(fixture.sourceRoot, fixture.sourceAccounts)
        try fixture.source.rebuildIndex()
        let reopened = try fixture.source.reopenPeerExport(
            context: fixture.context, planID: sealedHandle.planID, packageID: sealedHandle.packageID)
        XCTAssertEqual(
            try fixture.source.peerExportManifest(context: fixture.context, handle: reopened), manifest)
        let read = try fixture.source.readPeerExport(
            context: fixture.context, handle: reopened, object: root.descriptor, offset: 0)
        let canonical = try XCTUnwrap(
            try fixture.source.peerMetadataObjects(revisionID: root.descriptor.id)
                .first(where: { $0.0 == root.descriptor })?.1)
        XCTAssertEqual(read.bytes, Data(canonical.prefix(PeerPackage.maximumChunkBytes)))
        XCTAssertEqual(read.descriptor, root.descriptor)
        code("peerExportChanged") {
            _ = try fixture.source.inspectPeerExport(context: fixture.context, handle: unfinishedHandle)
        }
        try fixture.capacity()
    }

    func testReceiverKnownDescriptorSuppressesOnlyBytesAndCannotForgePossession() throws {
        let fixture = try Fixture()
        let (handle, root) = try begin(fixture)
        _ = try seal(fixture, handle: handle)
        let exact = try fixture.source.readPeerExport(
            context: fixture.context, handle: handle, object: root.descriptor, offset: 0,
            receiverKnown: root.descriptor)
        XCTAssertTrue(exact.receiverKnown)
        XCTAssertTrue(exact.bytes.isEmpty)
        let retransmitted = try fixture.source.readPeerExport(
            context: fixture.context, handle: handle, object: root.descriptor, offset: 0)
        XCTAssertFalse(retransmitted.receiverKnown)
        XCTAssertEqual(retransmitted.bytes.count, root.descriptor.length)
        XCTAssertEqual(AuthorityRecordCodec.sha256(retransmitted.bytes), root.descriptor.sha256)
        XCTAssertEqual(
            retransmitted.bytes,
            try fixture.source.readPeerExport(
                context: fixture.context, handle: handle, object: root.descriptor, offset: 0
            ).bytes)

        let mismatched = PeerPackage.Object(
            kind: root.descriptor.kind, id: root.descriptor.id, length: root.descriptor.length,
            sha256: String(repeating: "0", count: 64))
        code("peerObjectCollision") {
            _ = try fixture.source.readPeerExport(
                context: fixture.context, handle: handle, object: root.descriptor, offset: 0,
                receiverKnown: mismatched)
        }
        try fixture.capacity()
    }
}
