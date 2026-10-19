import CSQLite
import XCTest

@testable import TractandaCore

final class PeerInventoryIndexTests: XCTestCase {
    private struct Object {
        let retained: AuthorityStore.RetainedObject
        let authority: AuthorityRecordCodec.Verified?
        let revision: AuthorityRevision?
    }
    private final class Fixture {
        let root: URL
        let index: ItemIndex
        let origin = try! UUID.makeVersion1().uuidString.lowercased()
        let store = try! UUID.makeVersion1().uuidString.lowercased()
        static let cap: UInt64 = 8 * 1024 * 1024
        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
                "peer-inventory-" + Identifier.make())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: true)
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            try index.initializeAuthoritySchema()
            try index.validateRecoveryGraph(requireLinearProjection: false)
        }
        deinit {
            index.close()
            try? FileManager.default.removeItem(at: root)
        }
        func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        func write(_ bytes: Data, path: String) throws {
            try AttachmentFixtureCapacity.requireFree(at: root)
            var estimate = UInt64(bytes.count + 8192)
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
            else { throw TractandaError("resourceLimit", "Fixture storage unavailable.") }
            while let u = e.nextObject() as? URL {
                estimate += UInt64(try u.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            guard estimate < Self.cap else {
                throw TractandaError("resourceLimit", "Fixture estimate exceeds cap.")
            }
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        }
        func authority(
            _ kind: AuthorityRecord.Kind = .controlCommit, payload: [String: ItemValue]? = nil,
            permitted: Bool = true, recordID: String? = nil
        ) throws -> Object {
            let rid = try recordID ?? id()
            let r = try AuthorityRecord(
                recordID: rid, storeID: store, originReplicaID: origin, kind: kind,
                actorPrincipal: "fixture", createdAt: "2026-10-14T12:00:00.000Z",
                payload: payload ?? [
                    "controls": .list([]), "localParent": .list([]), "deltas": .list([]),
                    "bootstrap": .list([]),
                ])
            let verified = try AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(r))
            let path = "authority/" + r.recordID + ".tractanda"
            try write(verified.originalBytes, path: path)
            return try .init(
                retained: .init(
                    descriptor: .init(
                        kind: .authority, id: r.recordID, length: verified.originalBytes.count,
                        sha256: verified.sha256), path: path, packageID: id(), peerID: "fixture",
                    configurationDigest: String(repeating: "a", count: 64), permittedOrigin: permitted),
                authority: verified, revision: nil)
        }
        func retain(_ object: Object) throws {
            try index.retainAuthorityObject(
                object.retained, revision: object.revision, authority: object.authority)
        }
        func relay(_ object: Object, permitted: Bool = true) throws -> Object {
            let old = object.retained
            return try .init(
                retained: .init(
                    descriptor: old.descriptor, path: old.path, packageID: id(), peerID: "relay",
                    configurationDigest: String(repeating: "b", count: 64), permittedOrigin: permitted),
                authority: object.authority, revision: object.revision)
        }
        func legacy() throws -> Object {
            let rid = try id()
            let item = try id()
            let value = try Revision(fields: [
                "itemID": .text(item), "revisionID": .text(rid), "classID": .text("Item"),
                "schemaVersion": .integer(1), "createdAt": .date("2026-10-14T12:00:00.000Z"),
                "modifiedAt": .date("2026-10-14T12:00:00.000Z"), "actor": .text("user:fixture"),
                "operationID": .text(id()), "requestIdentity": .text("legacy inventory"),
                "subject": .text("baseline"),
            ])
            let original = try AuthorityRevision(originalBytes: RecordCodec.encode(value))
            let path = "items/2026/10/14/12/00/" + item + "/" + rid + ".tractanda"
            try write(original.originalBytes, path: path)
            return try .init(
                retained: .init(
                    descriptor: .init(
                        kind: .item, id: rid, length: original.originalBytes.count, sha256: original.sha256),
                    path: path, packageID: id(), peerID: "fixture",
                    configurationDigest: String(repeating: "a", count: 64), permittedOrigin: false),
                authority: nil, revision: original)
        }
    }
    private func code(
        _ expected: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }
    func testFiniteLimitOnePassCompletesDuringContinuousNewReceipts() throws {
        let f = try Fixture()
        var initial: [Object] = []
        for _ in 0..<3 {
            let o = try f.authority()
            try f.retain(o)
            initial.append(o)
        }
        let boundary = try f.index.capturePeerInventory()
        var last: Int64 = 0
        var ids: [String] = []
        for _ in 0..<3 {
            let page = try f.index.peerInventoryReceiptPage(
                epoch: boundary.epoch, afterSequence: last, throughSequence: boundary.maximumSequence,
                limit: 1)
            XCTAssertEqual(page.count, 1)
            ids += page.map { $0.retained.descriptor.id }
            last = try XCTUnwrap(page.last?.sequence)
            try f.retain(f.authority())
        }
        XCTAssertEqual(ids, initial.map { $0.retained.descriptor.id })
        XCTAssertTrue(
            try f.index.peerInventoryReceiptPage(
                epoch: boundary.epoch, afterSequence: last, throughSequence: boundary.maximumSequence,
                limit: 1
            ).isEmpty)
        let later = try f.index.capturePeerInventory()
        XCTAssertEqual(later.epoch, boundary.epoch)
        XCTAssertGreaterThan(later.maximumSequence, boundary.maximumSequence)
        XCTAssertEqual(
            try f.index.peerInventoryReceiptPage(
                epoch: later.epoch, afterSequence: 0, throughSequence: later.maximumSequence
            ).count, 6)
        XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
    }
    func testExactRetryKeepsSequenceAndRelayRetainsOriginalWithoutDeduplication() throws {
        let f = try Fixture()
        let original = try f.authority(permitted: false)
        try f.retain(original)
        let before = try f.index.capturePeerInventory()
        try f.retain(original)
        let retry = try f.index.capturePeerInventory()
        XCTAssertEqual(before.maximumSequence, retry.maximumSequence)
        let first = try XCTUnwrap(
            f.index.peerInventoryReceiptPage(
                epoch: before.epoch, afterSequence: 0, throughSequence: before.maximumSequence
            ).first)
        let relay = try f.relay(original)
        try f.retain(relay)
        let current = try f.index.capturePeerInventory()
        let rows = try f.index.peerInventoryReceiptPage(
            epoch: current.epoch, afterSequence: 0, throughSequence: current.maximumSequence)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.sequence, first.sequence)
        XCTAssertEqual(
            rows.map { $0.retained.descriptor.id },
            [original.retained.descriptor.id, original.retained.descriptor.id])
        XCTAssertEqual(rows.map { $0.retained.path }, [original.retained.path, original.retained.path])
        XCTAssertEqual(rows.map { $0.retained.permittedOrigin }, [false, true])
        XCTAssertEqual(
            try f.index.peerInventoryReceiptPage(
                epoch: before.epoch, afterSequence: 0, throughSequence: before.maximumSequence
            ).count, 1, "A later permitted receipt cannot replace the captured unknown one.")
    }
    func testFilteredEmptyPageStillAdvancesUnderlyingSequence() throws {
        let f = try Fixture()
        let unknown = try f.authority(permitted: false)
        let known = try f.authority()
        try f.retain(unknown)
        try f.retain(known)
        let captured = try f.index.capturePeerInventory()
        let first = try f.index.peerInventoryReceiptPage(
            epoch: captured.epoch, afterSequence: 0, throughSequence: captured.maximumSequence, limit: 1)
        XCTAssertTrue(first.filter { $0.retained.permittedOrigin }.isEmpty)
        let lastScanned = try XCTUnwrap(first.last?.sequence)
        let next = try f.index.peerInventoryReceiptPage(
            epoch: captured.epoch, afterSequence: lastScanned, throughSequence: captured.maximumSequence,
            limit: 1)
        XCTAssertEqual(next.first?.retained.descriptor.id, known.retained.descriptor.id)
    }
    func testRebuildChangesEpochAndNeverReusesCommittedSequence() throws {
        let f = try Fixture()
        let original = try f.authority()
        try f.retain(original)
        let before = try f.index.capturePeerInventory()
        try f.index.clearAuthorityDerivedState()
        let reset = try f.index.capturePeerInventory()
        XCTAssertNotEqual(reset.epoch, before.epoch)
        XCTAssertEqual(reset.maximumSequence, 0)
        code("peerInventoryChanged") {
            _ = try f.index.peerInventoryReceiptPage(
                epoch: before.epoch, afterSequence: 0, throughSequence: before.maximumSequence)
        }
        try f.retain(original)
        let after = try f.index.capturePeerInventory()
        XCTAssertEqual(after.epoch, reset.epoch)
        XCTAssertGreaterThan(after.maximumSequence, before.maximumSequence)
        let rows = try f.index.peerInventoryReceiptPage(
            epoch: after.epoch, afterSequence: 0, throughSequence: after.maximumSequence)
        XCTAssertEqual(rows.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(rows.first?.sequence), before.maximumSequence)
    }
    func testFailedReceiptAssignmentRollsBackOriginalAndMembershipTogether() throws {
        let f = try Fixture()
        let original = try f.authority()
        try f.index.execute(
            "CREATE TRIGGER peer_inventory_fixture_fail BEFORE INSERT ON peer_inventory_receipt BEGIN SELECT RAISE(ABORT,'inventory fixture'); END"
        )
        XCTAssertThrowsError(try f.retain(original))
        XCTAssertNil(try f.index.retainedAuthorityObject(id: original.retained.descriptor.id))
        XCTAssertNil(
            try f.index.authorityReceipt(
                objectID: original.retained.descriptor.id, packageID: original.retained.packageID))
        XCTAssertEqual(try f.index.capturePeerInventory().maximumSequence, 0)
        try f.index.execute("DROP TRIGGER peer_inventory_fixture_fail")
        try f.index.validateRecoveryGraph(requireLinearProjection: false)
        try f.retain(original)
        XCTAssertEqual(try f.index.capturePeerInventory().maximumSequence, 1)
        XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
    }
    func testCursorLimitsBytePrefixesAndNativeCancellationRemainBounded() throws {
        let f = try Fixture()
        for _ in 0..<3 { try f.retain(f.authority()) }
        let capture = try f.index.capturePeerInventory()
        code("invalidPeerCursor") {
            _ = try f.index.peerInventoryReceiptPage(
                epoch: capture.epoch, afterSequence: -1, throughSequence: capture.maximumSequence)
        }
        code("invalidPeerCursor") {
            _ = try f.index.peerInventoryReceiptPage(
                epoch: capture.epoch, afterSequence: 2, throughSequence: 1)
        }
        code("invalidPeerCursor") {
            _ = try f.index.peerInventoryReceiptPage(
                epoch: capture.epoch, afterSequence: 0, throughSequence: capture.maximumSequence + 1)
        }
        code("peerInventoryChanged") {
            _ = try f.index.peerInventoryReceiptPage(
                epoch: "another epoch", afterSequence: 0, throughSequence: capture.maximumSequence)
        }
        f.index.graphMaximumPageBytes = 1000
        let prefix = try f.index.peerInventoryReceiptPage(
            epoch: capture.epoch, afterSequence: 0, throughSequence: capture.maximumSequence)
        XCTAssertEqual(prefix.count, 1)
        XCTAssertFalse(
            try f.index.peerInventoryReceiptPage(
                epoch: capture.epoch, afterSequence: XCTUnwrap(prefix.last?.sequence),
                throughSequence: capture.maximumSequence
            ).isEmpty)
        f.index.graphMaximumPageBytes = 1
        code("resourceLimit") {
            _ = try f.index.peerInventoryReceiptPage(
                epoch: capture.epoch, afterSequence: 0, throughSequence: capture.maximumSequence)
        }
        f.index.graphMaximumPageBytes = 8 * 1024 * 1024
        code("inventoryCancelled") {
            try f.index.withCatalogueScanBudget(progress: {
                throw TractandaError("inventoryCancelled", "fixture")
            }) {
                _ = try f.index.peerInventoryReceiptPage(
                    epoch: capture.epoch, afterSequence: 0, throughSequence: capture.maximumSequence)
            }
        }
        f.index.graphMaximumVMInstructions = 1
        code("resourceLimit") {
            _ = try f.index.peerInventoryReceiptPage(
                epoch: capture.epoch, afterSequence: 0, throughSequence: capture.maximumSequence)
        }
    }
    func testReceiptRangeUsesRowIDIndexWithoutSortAndLegacyNeedsPrivatePin() throws {
        let f = try Fixture()
        let legacy = try f.legacy()
        try f.retain(legacy)
        XCTAssertNil(
            try f.index.peerInventoryLegacyPin(
                revisionID: legacy.retained.descriptor.id, sha256: legacy.retained.descriptor.sha256))
        try f.index.initializeAuthorityControlSchema()
        let pinID = try f.id()
        let page = try f.authority(
            .bootstrapPage,
            payload: [
                "manifestID": .text(pinID),
                "entries": .list([
                    .object([
                        "target": .object([
                            "itemID": .text(legacy.revision!.revision.itemID),
                            "revisionID": .text(legacy.retained.descriptor.id),
                            "sha256": .text(legacy.retained.descriptor.sha256),
                        ]), "frontier": .list([.text(legacy.retained.descriptor.id)]),
                    ])
                ]),
            ])
        try f.retain(page)
        let rootIndex = try f.authority(
            .bootstrapIndex,
            payload: [
                "manifestID": .text(pinID),
                "children": .list([
                    .object([
                        "recordID": .text(page.retained.descriptor.id),
                        "sha256": .text(page.retained.descriptor.sha256),
                    ])
                ]),
            ])
        try f.retain(rootIndex)
        let pin = try f.authority(
            .bootstrap,
            payload: [
                "pages": .list([
                    .object([
                        "recordID": .text(rootIndex.retained.descriptor.id),
                        "sha256": .text(rootIndex.retained.descriptor.sha256),
                    ])
                ]), "initial": .boolean(true), "administrationPolicies": .list([]),
            ], recordID: pinID)
        try f.retain(pin)
        // These two rows represent the explicit typed administrator/private-pin proof;
        // Main's integration fixtures exercise its actual sealed bootstrap validator.
        try f.index.execute(
            "INSERT INTO authority_dependencies VALUES(?,'bootstrap',?,?,'')",
            [legacy.retained.descriptor.id, pin.retained.descriptor.id, pin.retained.descriptor.sha256])
        XCTAssertNil(
            try f.index.peerInventoryLegacyPin(
                revisionID: legacy.retained.descriptor.id, sha256: legacy.retained.descriptor.sha256))
        try f.index.execute(
            "INSERT INTO authority_local_bootstrap VALUES(?,?)",
            [pin.retained.descriptor.id, pin.retained.descriptor.sha256])
        XCTAssertEqual(
            try f.index.peerInventoryLegacyPin(
                revisionID: legacy.retained.descriptor.id, sha256: legacy.retained.descriptor.sha256)?
                .recordID, pin.retained.descriptor.id)
        XCTAssertNil(
            try f.index.peerInventoryLegacyPin(
                revisionID: legacy.retained.descriptor.id, sha256: String(repeating: "0", count: 64)))
        XCTAssertNotEqual(
            try f.index.authorityDisposition(id: legacy.retained.descriptor.id)?.disposition, .eligible)
        let statement = try f.index.corpusPrepare(
            "EXPLAIN QUERY PLAN SELECT i.sequence FROM peer_inventory_receipt i LEFT JOIN authority_packages p ON p.package=i.package AND p.object=i.object LEFT JOIN authority_objects o ON o.id=i.object WHERE i.sequence>? AND i.sequence<=? ORDER BY i.sequence LIMIT ?",
            ["0", "3", "1"])
        defer { sqlite3_finalize(statement) }
        var plan = ""
        while f.index.catalogueStep(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 3) { plan += String(cString: text) }
        }
        XCTAssertTrue(plan.uppercased().contains("INTEGER PRIMARY KEY"))
        XCTAssertFalse(plan.uppercased().contains("TEMP B-TREE"))
    }
}
