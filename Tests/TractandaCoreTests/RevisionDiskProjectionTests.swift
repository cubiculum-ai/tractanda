import CSQLite
import CTractandaPlatform
import Crypto
import XCTest

@testable import TractandaCore

final class RevisionDiskProjectionTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let index: ItemIndex
        let itemID: String
        let origin: String
        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "tractanda-projection-" + Identifier.make())
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: true)
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            itemID = try UUID.makeVersion1().uuidString.lowercased()
            origin = try UUID.makeVersion1().uuidString.lowercased()
        }
        deinit {
            index.close()
            try? FileManager.default.removeItem(at: root)
        }
        func record(
            parents: [Revision] = [], kind: RevisionProvenance.Kind = .authored,
            writes: [String: ItemValue] = [:], unset: [String] = [], snapshot: [String: ItemValue]? = nil,
            frontier: [String] = [], at: String = "2026-10-13T12:00:00.000Z", legacy: Bool = false
        ) throws -> Revision {
            let id = try UUID.makeVersion1().uuidString.lowercased()
            var fields =
                parents.first?.fields ?? [
                    "classID": .text("Item"), "schemaVersion": .integer(1),
                    "createdAt": .date("2026-10-13T12:00:00.000Z"), "subject": .text("initial"),
                ]
            fields.removeValue(forKey: "revisionAncestry")
            fields.removeValue(forKey: "supersedes")
            if let snapshot {
                fields = fields.filter { RevisionMerge.managedFields.contains($0.key) }
                fields.merge(snapshot) { _, new in new }
            }
            fields["itemID"] = .text(itemID)
            fields["revisionID"] = .text(id)
            fields["actor"] = .text("uid:\(tractanda_uid())")
            fields["operationID"] = .text(id)
            fields["requestIdentity"] = .text("fixture")
            fields["modifiedAt"] = .date(at)
            if parents.count == 1 { fields["supersedes"] = .text(parents[0].revisionID) }
            for (field, value) in writes { fields[field] = value }
            for field in unset { fields.removeValue(forKey: field) }
            let provenance: RevisionProvenance?
            if !legacy {
                provenance = try .init(
                    kind: kind, originReplicaID: origin, parents: parents.map(\.revisionID).sorted(),
                    writtenFields: kind == .automaticMerge
                        ? []
                        : (parents.isEmpty
                            ? fields.keys.filter { !RevisionMerge.managedFields.contains($0) }.sorted()
                            : writes.keys.sorted()),
                    unsetFields: unset.sorted(), frontier: frontier.sorted(),
                    mergeProfile: kind == .automaticMerge ? RevisionMerge.profile : nil)
                fields["revisionAncestry"] = provenance!.itemValue
            } else {
                provenance = nil
            }
            let value = try Revision(fields: fields, formatVersion: legacy ? 1 : 2)
            let bytes = try RecordCodec.encode(value)
            let directory = root.appendingPathComponent("items/2026/10/13/12/00/" + itemID)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(id + ".tractanda")
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            let metadata = try FileMetadata.read(at: file)
            let row = ItemIndex.CatalogueRow(
                revisionID: id, itemID: itemID, path: String(file.path.dropFirst(root.path.count + 1)),
                parentID: value.supersedes,
                actor: value.fields["actor"]!.string!, operationID: id, size: metadata.size,
                inode: metadata.inode, uid: metadata.uid, mode: metadata.mode,
                modificationSeconds: metadata.modificationSeconds,
                modificationNanoseconds: metadata.modificationNanoseconds,
                digest: Data(SHA256.hash(data: bytes)), createdAt: value.fields["createdAt"]!.dateString!,
                modifiedAt: at, provenance: provenance)
            try index.insertRecoveryRow(row, graphFields: value.fields)
            return value
        }
        func analyze(_ limits: RevisionProjection.Limits = .init(), progress: (() throws -> Void)? = nil)
            throws -> RevisionProjection.Snapshot
        {
            var limits = limits
            limits.minimumFreeBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            return try index.analyzeRevisionProjection(
                itemID: itemID,
                loadVerified: { row in
                    try PooledCanonicalRecord.read(row: row, root: self.root, ownerUID: tractanda_uid())
                }, limits: limits, progress: progress)
        }
        func checkCapacity() throws {
            try AttachmentFixtureCapacity.requireFree(at: root)
            var bytes: UInt64 = 0
            guard
                let walk = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.fileSizeKey], options: [])
            else {
                throw TractandaError("resourceLimit", "Cannot inspect fixture storage.")
            }
            while let file = walk.nextObject() as? URL {
                if let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    bytes += UInt64(size)
                }
            }
            guard bytes <= AttachmentFixtureCapacity.fixtureCapBytes else {
                throw TractandaError("resourceLimit", "Tiny projection fixture exceeded its cap.")
            }
        }
    }
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected, "\($0)") }
    }

    func testLinearHistoryAboveReferenceLimitUsesIndexedChainLookupsAndOneCurrentHead() throws {
        let f = try Fixture()
        XCTAssertLessThan(301 * 16_384, Int(AttachmentFixtureCapacity.fixtureCapBytes))
        var current = try f.record()
        for number in 1...300 {
            if number % 32 == 0 { try f.checkCapacity() }
            current = try f.record(parents: [current], writes: ["body": .text(String(number))])
        }
        let result = try f.analyze()
        XCTAssertEqual(result.analysis.frontier, [current.revisionID])
        XCTAssertEqual(result.analysis.values["body"], .set(.text("300")))
        XCTAssertEqual(result.representative?.revisionID, current.revisionID)
        XCTAssertEqual(result.physicalHeads, [current.revisionID])
        XCTAssertEqual(try RevisionProjection.plan(result, now: { "2020-01-01T00:00:00Z" }), .unchanged)
        try f.checkCapacity()
        for sql in [
            "SELECT writer FROM rp_writes WHERE segment='x' AND field='subject' AND position<=1 ORDER BY position DESC LIMIT 1",
            "SELECT revision FROM rp_lookup ORDER BY ordinal,revision LIMIT 1",
            "SELECT r.revision,o.ordinal FROM recovery_ordinals o JOIN revision_catalog r ON r.revision=o.revision AND r.item=o.item WHERE o.item='x' AND o.ordinal>0 ORDER BY o.ordinal LIMIT 1",
        ] {
            let statement = try f.index.corpusPrepare("EXPLAIN QUERY PLAN " + sql)
            defer { sqlite3_finalize(statement) }
            var details = ""
            while f.index.catalogueStep(statement) == SQLITE_ROW {
                details += String(cString: sqlite3_column_text(statement, 3)!)
            }
            XCTAssertTrue(details.contains("INDEX"), details)
            XCTAssertFalse(details.contains("TEMP B-TREE"), details)
        }
    }

    func testThreePeersIndependentFieldsAndEquivalentMaterializationsConverge() throws {
        let f = try Fixture()
        let root = try f.record()
        let a = try f.record(parents: [root], writes: ["subject": .text("A")])
        let b = try f.record(parents: [root], writes: ["body": .text("B")])
        let c = try f.record(parents: [root], writes: ["due": .text("C")])
        let frontier = [a.revisionID, b.revisionID, c.revisionID].sorted()
        let fields: [String: ItemValue] = [
            "classID": .text("Item"), "schemaVersion": .integer(1), "subject": .text("A"), "body": .text("B"),
            "due": .text("C"),
        ]
        let first = try f.record(
            parents: [a, b, c], kind: .automaticMerge, snapshot: fields, frontier: frontier,
            at: "2026-10-13T12:00:00.001Z")
        let second = try f.record(
            parents: [a, b, c], kind: .automaticMerge, snapshot: fields, frontier: frontier,
            at: "2026-10-13T12:00:00.002Z")
        let result = try f.analyze()
        XCTAssertEqual(result.analysis.frontier, frontier)
        XCTAssertEqual(result.analysis.values["due"], .set(.text("C")))
        XCTAssertEqual(result.representative?.revisionID, second.revisionID)
        XCTAssertFalse(result.analysis.needsMaterialization)
        let laterA = try f.record(parents: [first], writes: ["subject": .text("later A")])
        let laterB = try f.record(parents: [second], writes: ["body": .text("later B")])
        let descendants = try f.analyze()
        XCTAssertEqual(descendants.analysis.frontier, [laterA.revisionID, laterB.revisionID].sorted())
        XCTAssertTrue(descendants.analysis.isResolved)
        XCTAssertEqual(descendants.analysis.values["subject"], .set(.text("later A")))
        XCTAssertEqual(descendants.analysis.values["body"], .set(.text("later B")))
    }

    func testConflictEqualValuesUnsetsAndAtomicMapsPreserveAuthoredCauses() throws {
        let f = try Fixture()
        let root = try f.record(writes: ["settings": .object(["a": .integer(1)]), "label": .text("old")])
        let a = try f.record(
            parents: [root], writes: ["subject": .text("same"), "settings": .object(["a": .integer(2)])],
            unset: ["label"])
        let b = try f.record(
            parents: [root],
            writes: ["subject": .text("same"), "settings": .object(["a": .integer(1), "b": .integer(2)])],
            unset: ["label"])
        let result = try f.analyze()
        XCTAssertEqual(result.analysis.values["subject"], .set(.text("same")))
        XCTAssertEqual(result.analysis.values["label"], .unset)
        XCTAssertEqual(result.analysis.conflicts["settings"]?.count, 2)
        XCTAssertEqual(Set(result.analysis.frontier), Set([a.revisionID, b.revisionID]))
        XCTAssertNil(result.representative)
    }

    func testHistoricalResolutionOwnContextRemainsValidWithLaterConcurrency() throws {
        let f = try Fixture()
        let root = try f.record()
        let a = try f.record(parents: [root], writes: ["subject": .text("A")])
        let b = try f.record(parents: [root], writes: ["subject": .text("B")])
        let resolved = try f.record(
            parents: [a, b], kind: .resolution, writes: ["subject": .text("resolved")],
            frontier: [a.revisionID, b.revisionID], at: "2026-10-13T12:00:00.001Z")
        let c = try f.record(parents: [root], writes: ["subject": .text("C")])
        let result = try f.analyze()
        XCTAssertEqual(Set(result.analysis.frontier), Set([resolved.revisionID, c.revisionID]))
        XCTAssertEqual(result.analysis.conflicts["subject"]?.count, 2)
    }

    func testLegacyBackwardClockReconciliationHasRealWitnessAndDoesNotLoop() throws {
        let f = try Fixture()
        let root = try f.record(at: "2030-01-01T00:00:00Z", legacy: true)
        let edit = try f.record(parents: [root], writes: ["body": .text("new")], legacy: true)
        let before = try f.analyze()
        XCTAssertEqual(before.representative?.revisionID, edit.revisionID)
        XCTAssertEqual(before.clockFloor.revisionID, root.revisionID)
        guard case .ready(let plan) = try RevisionProjection.plan(before, now: { "2020-01-01T00:00:00Z" })
        else { return XCTFail("Expected clock reconciliation") }
        let reconciled = try f.record(
            parents: [edit, root], kind: .automaticMerge, snapshot: plan.fields, frontier: [edit.revisionID],
            at: plan.modifiedAt)
        let after = try f.analyze()
        XCTAssertEqual(after.representative?.revisionID, reconciled.revisionID)
        XCTAssertEqual(try RevisionProjection.plan(after, now: { "2020-01-01T00:00:00Z" }), .unchanged)
    }

    func testDishonestPayloadAndProtectedDeleteCannotAutoMaterialize() throws {
        do {
            let f = try Fixture()
            let root = try f.record()
            let a = try f.record(parents: [root], writes: ["subject": .text("A")])
            let b = try f.record(parents: [root], writes: ["body": .text("B")])
            _ = try f.record(
                parents: [a, b], kind: .automaticMerge,
                snapshot: ["classID": .text("Item"), "schemaVersion": .integer(1), "subject": .text("A")],
                frontier: [a.revisionID, b.revisionID], at: "2026-10-13T12:00:00.001Z")
            code("invalidRevisionGraph") { _ = try f.analyze() }
        }
        do {
            let f = try Fixture()
            let root = try f.record(writes: ["isDeleted": .boolean(false)])
            _ = try f.record(parents: [root], writes: ["isDeleted": .boolean(true)])
            _ = try f.record(parents: [root], writes: ["subject": .text("edit")])
            let result = try f.analyze()
            XCTAssertTrue(result.analysis.protectedFields.contains("isDeleted"))
            XCTAssertEqual(try RevisionProjection.plan(result, now: { "2026-10-13T12:00:00Z" }), .conflicted)
        }
    }

    func testOneWorkAllowanceAndValidatedSessionAvoidRepeatedGlobalAdmission() throws {
        let f = try Fixture()
        var current = try f.record()
        for number in 1...8 {
            current = try f.record(parents: [current], writes: ["body": .text(String(number))])
        }
        _ = try f.analyze()
        XCTAssertEqual(f.index.graphValidationPassesForTesting, 1)
        _ = try f.analyze()
        XCTAssertEqual(f.index.graphValidationPassesForTesting, 1)
        f.index.invalidateRevisionGraphValidation()
        try f.index.validateRecoveryGraph(requireLinearProjection: false)
        let admission = f.index.lastCatalogueScanWorkForTesting
        _ = try f.analyze()
        let scan = f.index.lastCatalogueScanWorkForTesting
        XCTAssertGreaterThan(admission, 0)
        XCTAssertGreaterThan(scan, 0)
        var limits = RevisionProjection.Limits()
        limits.maximumVMInstructions = max(admission, scan) + min(admission, scan) / 2
        f.index.invalidateRevisionGraphValidation()
        code("resourceLimit") { _ = try f.analyze(limits) }
        _ = try f.analyze()
        let passes = f.index.graphValidationPassesForTesting
        _ = try f.record(parents: [current], writes: ["subject": .text("new")])
        _ = try f.analyze()
        XCTAssertEqual(f.index.graphValidationPassesForTesting, passes + 1)
        let beforeDirect = f.index.graphValidationPassesForTesting
        try f.index.execute("UPDATE revision_catalog SET actor=actor WHERE revision=?", [current.revisionID])
        _ = try f.analyze()
        XCTAssertEqual(f.index.graphValidationPassesForTesting, beforeDirect + 1)
        let beforeUnsupported = f.index.graphValidationPassesForTesting
        try f.index.execute(
            "WITH marker AS (SELECT 1) UPDATE revision_catalog SET actor=actor WHERE revision=?",
            [current.revisionID])
        _ = try f.analyze()
        XCTAssertEqual(f.index.graphValidationPassesForTesting, beforeUnsupported + 1)
    }

    func testAggregateSnapshotBudgetAndTightenedCachedStagingCapFailClosed() throws {
        let f = try Fixture()
        let root = try f.record()
        XCTAssertLessThan(try JSON.encode(RevisionMerge.semanticFields(root)).count, 768)
        var limits = RevisionProjection.Limits()
        limits.maximumResultBytes = 768
        code("resourceLimit") { _ = try f.analyze(limits) }
        _ = try f.analyze()
        let passes = f.index.graphValidationPassesForTesting
        f.index.graphMaximumTemporaryBytes = 1
        code("resourceLimit") { _ = try f.analyze() }
        XCTAssertEqual(f.index.graphValidationPassesForTesting, passes)
        f.index.graphMaximumTemporaryBytes = 256 * 1024 * 1024
        XCTAssertEqual(try f.analyze().representative?.revisionID, root.revisionID)
    }

    func testCanonicalHydrationRejectsForgedNormalizedFingerprint() throws {
        let f = try Fixture()
        let root = try f.record()
        let forged = String(repeating: "0", count: 64)
        try f.index.execute(
            "UPDATE revision_field_values SET digest=? WHERE revision=? AND field='subject'",
            [forged, root.revisionID])
        try f.index.execute(
            "UPDATE revision_field_writes SET digest=? WHERE revision=? AND field='subject'",
            [forged, root.revisionID])
        code("invalidRevisionGraph") { _ = try f.analyze() }
    }

    func testProjectionBudgetsCancellationAndSerializedOwnershipFailClosed() throws {
        let f = try Fixture()
        let root = try f.record(writes: ["body": .text(String(repeating: "x", count: 4096))])
        var limits = RevisionProjection.Limits()
        limits.maximumHydratedBytes = 1
        code("resourceLimit") { _ = try f.analyze(limits) }
        limits = .init()
        limits.maximumResultBytes = 128
        code("resourceLimit") { _ = try f.analyze(limits) }
        code("cancelled") { _ = try f.analyze(progress: { throw TractandaError("cancelled", "controlled") }) }
        f.index.revisionProjectionActive = true
        code("indexTransient") { _ = try f.analyze() }
        f.index.revisionProjectionActive = false
        XCTAssertEqual(try f.analyze().representative?.revisionID, root.revisionID)
    }
}
