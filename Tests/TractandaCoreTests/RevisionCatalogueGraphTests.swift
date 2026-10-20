import CSQLite
import Crypto
import XCTest

@testable import TractandaCore

final class RevisionCatalogueGraphTests: XCTestCase {
    private struct Record {
        let row: ItemIndex.CatalogueRow
        let fields: [String: ItemValue]
    }

    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }

    private func record(
        item: String, revision: String? = nil, origin: String? = nil, parents: [String] = [],
        kind: RevisionProvenance.Kind = .authored, frontier: [String] = [],
        values: [String: ItemValue] = ["subject": .text("fixture")], writes: [String]? = nil,
        unset: [String] = [], operation: String? = nil,
        at: String = "2026-10-13T12:00:00.000Z", feedback: [String] = [], retainParentPointer: Bool = true,
        actor: String = "user:fixture"
    ) throws -> Record {
        let revision = try revision ?? id()
        var fields: [String: ItemValue] = [
            "itemID": .text(item), "revisionID": .text(revision), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date("2026-10-13T12:00:00.000Z"),
            "modifiedAt": .date(at), "actor": .text(actor),
            "operationID": .text(operation ?? revision), "requestIdentity": .text("fixture-" + revision),
        ]
        fields.merge(values) { _, new in new }
        let parent = parents.count == 1 && retainParentPointer ? parents[0] : nil
        if let parent { fields["supersedes"] = .text(parent) }
        let provenance: RevisionProvenance?
        if let origin {
            provenance = try RevisionProvenance(
                kind: kind, originReplicaID: origin, parents: parents.sorted(),
                writtenFields: kind == .automaticMerge
                    ? []
                    : (writes ?? fields.keys.filter { !RevisionMerge.managedFields.contains($0) }.sorted()),
                unsetFields: unset.sorted(), frontier: frontier.sorted(),
                mergeProfile: kind == .automaticMerge ? RevisionMerge.profile : nil)
            fields["revisionAncestry"] = provenance!.itemValue
            try provenance!.validate(in: fields)
        } else {
            provenance = nil
        }
        let data = try JSON.encode(Revision(fields: fields, formatVersion: origin == nil ? 1 : 2))
        let row = ItemIndex.CatalogueRow(
            revisionID: revision, itemID: item, path: "items/" + revision + ".tractanda",
            parentID: parent, actor: actor, operationID: operation ?? revision,
            size: UInt64(data.count), inode: 1, uid: 1, mode: 0o600,
            modificationSeconds: 1, modificationNanoseconds: 0,
            digest: Data(SHA256.hash(data: data)), createdAt: "2026-10-13T12:00:00.000Z",
            feedbackRevisionIDs: feedback, modifiedAt: at, provenance: provenance)
        return Record(row: row, fields: fields)
    }

    private func insert(_ record: Record, into index: ItemIndex) throws {
        try index.insertRecoveryRow(record.row, graphFields: record.fields)
    }

    private func fixture(_ action: (ItemIndex, URL) throws -> Void) throws {
        try AttachmentFixtureCapacity.requireFree()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-index-graph-" + Identifier.make())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try ItemIndex(path: directory.appendingPathComponent("index.sqlite").path, create: true)
        index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
        defer { index.close() }
        try action(index, directory)
        try assertFixtureCapacity(directory)
    }

    private func assertFixtureCapacity(_ directory: URL) throws {
        try AttachmentFixtureCapacity.requireFree(at: directory)
        var bytes: UInt64 = 0
        for file in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        {
            guard let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            else {
                throw TractandaError("resourceLimit", "Cannot determine tiny catalogue fixture size.")
            }
            bytes += size.uint64Value
        }
        guard bytes <= AttachmentFixtureCapacity.fixtureCapBytes else {
            throw TractandaError("resourceLimit", "Tiny catalogue fixture cap exceeded.")
        }
    }

    private func scalar(_ index: ItemIndex, _ sql: String, _ bindings: [String] = []) throws -> Int64 {
        let statement = try index.corpusPrepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard index.catalogueStep(statement) == SQLITE_ROW else { throw index.graphSQLiteError() }
        return sqlite3_column_int64(statement, 0)
    }

    private func code(_ expected: String, _ action: () throws -> Void) {
        XCTAssertThrowsError(try action()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, "\($0)")
        }
    }

    func testDiskBackedHistoryAboveReferenceGraphLimitReopensWithBoundedIndexedPages() throws {
        try fixture { index, directory in
            // 301 metadata-only rows estimated below 5 MiB, capped at 32 MiB with 10 GiB genuine reserve.
            XCTAssertLessThan(301 * 16_384, Int(AttachmentFixtureCapacity.fixtureCapBytes))
            let item = try id()
            let origin = try id()
            let root = try record(item: item, origin: origin)
            try insert(root, into: index)
            var previous = root.row.revisionID
            for number in 1...300 {
                if number % 32 == 0 { try assertFixtureCapacity(directory) }
                let next = try record(
                    item: item, origin: origin, parents: [previous],
                    values: ["subject": .text("fixture"), "body": .text(String(number))], writes: ["body"])
                try insert(next, into: index)
                previous = next.row.revisionID
            }
            try index.validateRecoveryGraph()
            XCTAssertEqual(try index.recoveryHead()?.revisionID, previous)
            XCTAssertEqual(try index.catalogueCount(), 301)
            try index.sealCatalogue(identity: "fixture")
            try index.checkpoint(path: index.corpusIndexPath)
            let reopened = try ItemIndex(path: index.corpusIndexPath, create: false)
            defer { reopened.close() }
            XCTAssertNotNil(try reopened.validatedCatalogue(identity: "fixture"))
            XCTAssertTrue(try reopened.hasModernRevisionOrigins())
            XCTAssertEqual(try reopened.revision(previous)?.provenance?.originReplicaID, origin)
            var cursor: String?
            var count = 0
            while true {
                let page = try reopened.historyRowPage(
                    itemID: item,
                    afterModifiedTicks: cursor == nil ? nil : RevisionTimestamp(root.row.modifiedAt).ticks,
                    afterRevisionID: cursor, limit: 17)
                if page.isEmpty { break }
                XCTAssertLessThanOrEqual(page.count, 17)
                for row in page {
                    if let cursor { XCTAssertGreaterThan(row.revisionID, cursor) }
                    cursor = row.revisionID
                    count += 1
                }
            }
            XCTAssertEqual(count, 301)
            for sql in [
                "SELECT item,revision FROM recovery_ready ORDER BY item,revision LIMIT 1",
                "SELECT child FROM revision_parents WHERE parent='fixture'",
                "SELECT revision FROM revision_catalog WHERE item='fixture' ORDER BY modified_ticks,revision LIMIT 17",
            ] {
                let statement = try index.corpusPrepare("EXPLAIN QUERY PLAN " + sql)
                defer { sqlite3_finalize(statement) }
                var indexed = false
                while index.catalogueStep(statement) == SQLITE_ROW {
                    indexed =
                        indexed
                        || sqlite3_column_text(statement, 3).map {
                            String(cString: $0).lowercased().contains("index")
                        } == true
                }
                XCTAssertTrue(indexed, sql)
            }
        }
    }

    func testValidMergedDagRetainsPhysicalHeadButDefaultRuntimeProjectionStaysClosed() throws {
        try fixture { index, _ in
            let item = try id()
            let origin = try id()
            let root = try record(item: item, origin: origin)
            let a = try record(
                item: item, origin: origin, parents: [root.row.revisionID], values: ["subject": .text("A")],
                writes: ["subject"])
            let b = try record(
                item: item, origin: try id(), parents: [root.row.revisionID],
                values: ["subject": .text("fixture"), "body": .text("B")], writes: ["body"])
            let heads = [a.row.revisionID, b.row.revisionID]
            let merged = try record(
                item: item, origin: origin, parents: heads, kind: .automaticMerge, frontier: heads,
                values: ["subject": .text("A"), "body": .text("B")], at: "2026-10-13T12:00:00.0000001Z",
                feedback: [a.row.revisionID])
            for record in [merged, b, root, a] { try insert(record, into: index) }
            try index.validateRecoveryGraph(requireLinearProjection: false)
            XCTAssertEqual(
                try index.graphHeadPage(itemID: item, limit: 1).map(\.revisionID), [merged.row.revisionID])
            XCTAssertNil(try index.recoveryHead())
            XCTAssertEqual(try index.historyRowPage(itemID: item, limit: 8).count, 4)
            code("revisionProjectionRequired") { try index.validateRecoveryGraph() }
            XCTAssertNil(try index.recoveryHead())
        }
    }

    func testFeedbackToEarlierSiblingIsRejectedByReachability() throws {
        try fixture { index, _ in
            let item = try id()
            let origin = try id()
            let root = try record(item: item, origin: origin)
            let a = try record(
                item: item, origin: origin, parents: [root.row.revisionID], values: ["subject": .text("A")],
                writes: ["subject"], at: "2025-01-01T00:00:00Z")
            let b = try record(
                item: item, origin: origin, parents: [root.row.revisionID], values: ["subject": .text("B")],
                writes: ["subject"], feedback: [a.row.revisionID])
            for record in [root, a, b] { try insert(record, into: index) }
            code("recoveryError") { try index.validateRecoveryGraph(requireLinearProjection: false) }
        }
    }

    func testDefaultRuntimeGateRejectsModernHistoryKindsOrMissingOrdinaryPointer() throws {
        for resolution in [false, true] {
            try fixture { index, _ in
                let item = try id()
                let origin = try id()
                let root = try record(item: item, origin: origin)
                let child = try record(
                    item: item, origin: origin, parents: [root.row.revisionID],
                    kind: resolution ? .resolution : .authored,
                    frontier: resolution ? [root.row.revisionID] : [], writes: [],
                    at: "2026-10-13T12:00:00.001Z", retainParentPointer: resolution)
                try insert(root, into: index)
                try insert(child, into: index)
                try index.validateRecoveryGraph(requireLinearProjection: false)
                XCTAssertTrue(try index.acceptedGraphProofIsCurrent())
                code("revisionProjectionRequired") { try index.validateRecoveryGraph() }
                // A failed savepoint may retain the earlier physical-head table. It must
                // invalidate admission proof, so strict recovery cannot serve those rows.
                XCTAssertFalse(try index.acceptedGraphProofIsCurrent())
            }
        }
    }

    func testReceiptScopesSeparateForeignOriginsKindsAndLegacyFallback() throws {
        try fixture { index, _ in
            let item = try id()
            let originA = try id()
            let originB = try id()
            let root = try record(item: item)
            let legacy = try record(item: item, parents: [root.row.revisionID], operation: "shared")
            let a = try record(
                item: item, origin: originA, parents: [root.row.revisionID], writes: [], operation: "shared")
            let b = try record(
                item: item, origin: originB, parents: [root.row.revisionID], writes: [], operation: "shared")
            let resolution = try record(
                item: item, origin: originA, parents: [a.row.revisionID, b.row.revisionID], kind: .resolution,
                frontier: [a.row.revisionID, b.row.revisionID], writes: [], operation: "shared",
                at: "2026-10-13T12:00:00.001Z")
            for record in [root, legacy, a, b, resolution] { try insert(record, into: index) }
            XCTAssertEqual(try index.receipts(named: "shared")?.map(\.revisionID), [legacy.row.revisionID])
            XCTAssertEqual(
                try index.receipts(named: "shared", localReplicaID: originA)?.map(\.revisionID),
                [a.row.revisionID])
            XCTAssertEqual(
                try index.receipts(named: "shared", localReplicaID: originB)?.map(\.revisionID),
                [b.row.revisionID])
            let collision = try record(item: try id(), origin: originA, operation: "shared")
            XCTAssertThrowsError(try insert(collision, into: index))
            XCTAssertNil(try index.revision(collision.row.revisionID))
            try index.validateRecoveryGraph(requireLinearProjection: false)
            try index.sealCatalogue(identity: "fixture")
            let roundtrip = try XCTUnwrap(index.catalogue(identity: "fixture"))
            XCTAssertEqual(
                roundtrip.first { $0.revisionID == a.row.revisionID }?.provenance, a.row.provenance)
        }
    }

    func testLegacySemanticFingerprintsPreserveSignedZeroUnicodeEqualityAndTaggedTypes() throws {
        try fixture { index, _ in
            let item = try id()
            let root = try record(
                item: item, values: ["subject": .text("Café"), "settings": .object(["value": .real(0)])])
            let same = try record(
                item: item, parents: [root.row.revisionID],
                values: ["subject": .text("Cafe\u{301}"), "settings": .object(["value": .real(-0.0)])])
            let differentTag = try record(
                item: item, parents: [same.row.revisionID],
                values: ["subject": .text("Café"), "settings": .object(["value": .integer(0)])])
            let before = try JSON.encode(Revision(fields: same.fields))
            for record in [differentTag, same, root] { try insert(record, into: index) }
            try index.validateRecoveryGraph()
            XCTAssertEqual(
                try scalar(
                    index, "SELECT COUNT(*) FROM revision_field_writes WHERE revision=?",
                    [same.row.revisionID]), 0)
            XCTAssertEqual(
                try scalar(
                    index, "SELECT COUNT(*) FROM revision_field_writes WHERE revision=? AND field='settings'",
                    [differentTag.row.revisionID]), 1)
            XCTAssertEqual(try JSON.encode(Revision(fields: same.fields)), before)
        }
    }

    func testMalformedEdgesCyclesAndNormalizedMetadataFailClosed() throws {
        try fixture { index, _ in
            let item = try id()
            let origin = try id()
            let root = try record(item: item, origin: origin)
            try insert(root, into: index)
            let missing = try record(item: item, origin: origin, parents: [try id()], writes: [])
            try insert(missing, into: index)
            code("recoveryError") { try index.validateRecoveryGraph(requireLinearProjection: false) }
        }
        try fixture { index, _ in
            let item = try id()
            let origin = try id()
            let root = try record(item: item, origin: origin)
            let aID = try id()
            let bID = try id()
            for record in [
                root, try record(item: item, revision: aID, origin: origin, parents: [bID], writes: []),
                try record(item: item, revision: bID, origin: origin, parents: [aID], writes: []),
            ] { try insert(record, into: index) }
            code("recoveryError") { try index.validateRecoveryGraph(requireLinearProjection: false) }
        }
        try fixture { index, _ in
            let item = try id()
            let origin = try id()
            let root = try record(item: item, origin: origin)
            let child = try record(item: item, origin: origin, parents: [root.row.revisionID], writes: [])
            try insert(root, into: index)
            try insert(child, into: index)
            try index.execute("DELETE FROM revision_parents WHERE child=?", [child.row.revisionID])
            code("recoveryError") { try index.validateRecoveryGraph(requireLinearProjection: false) }
        }
    }

    func testDuplicateIdentityAndCorruptedReceiptOrTimestampCannotHydrate() throws {
        try fixture { index, _ in
            let item = try id()
            let origin = try id()
            let root = try record(item: item, origin: origin)
            try insert(root, into: index)
            try insert(root, into: index)
            XCTAssertEqual(try index.catalogueCount(), 1)
            let changed = try record(
                item: item, revision: root.row.revisionID, origin: origin,
                values: ["subject": .text("changed")])
            code("recoveryError") { try insert(changed, into: index) }
            try index.execute(
                "UPDATE scoped_operation_receipts SET origin=? WHERE revision=?",
                [try id(), root.row.revisionID])
            code("recoveryError") { _ = try index.revision(root.row.revisionID) }
            try index.execute(
                "UPDATE scoped_operation_receipts SET origin=? WHERE revision=?",
                [origin, root.row.revisionID])
            try index.execute(
                "UPDATE revision_catalog SET modified_ticks=modified_ticks+1 WHERE revision=?",
                [root.row.revisionID])
            code("recoveryError") { _ = try index.historyRowPage(itemID: item) }
        }
    }

    func testWorkAndDiskBudgetsReturnResourceLimitWithoutCorruptingValidRows() throws {
        try fixture { index, _ in
            let item = try id()
            let origin = try id()
            let root = try record(item: item, origin: origin)
            try insert(root, into: index)
            var previous = root.row.revisionID
            for _ in 0..<20 {
                let child = try record(item: item, origin: origin, parents: [previous], writes: [])
                try insert(child, into: index)
                previous = child.row.revisionID
            }
            index.graphMaximumVMInstructions = 1
            code("resourceLimit") { try index.validateRecoveryGraph() }
            index.graphMaximumVMInstructions = 200_000_000
            index.graphMaximumTemporaryBytes = 1
            code("resourceLimit") { try index.validateRecoveryGraph() }
            index.graphMaximumTemporaryBytes = 256 * 1024 * 1024
            let denied = try record(item: item, origin: origin, parents: [previous], writes: [])
            index.graphReserveBytes = UInt64.max
            code("resourceLimit") { try insert(denied, into: index) }
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            XCTAssertEqual(try index.catalogueCount(), 21)
            try index.validateRecoveryGraph()
            XCTAssertEqual(try index.recoveryHead()?.revisionID, previous)
        }
    }

    func testModernAuthoredSnapshotDeltaCannotOmitChangedAddedOrRemovedFields() throws {
        for mode in 0..<3 {
            try fixture { index, _ in
                let item = try id()
                let origin = try id()
                let root = try record(
                    item: item, origin: origin, values: ["subject": .text("original"), "label": .text("old")])
                var values: [String: ItemValue] = ["subject": .text("original"), "label": .text("old")]
                if mode == 0 { values["subject"] = .text("undocumented") }
                if mode == 1 { values["body"] = .text("undocumented") }
                if mode == 2 { values.removeValue(forKey: "label") }
                let child = try record(
                    item: item, origin: origin, parents: [root.row.revisionID], values: values, writes: [])
                try insert(child, into: index)
                try insert(root, into: index)
                code("recoveryError") { try index.validateRecoveryGraph() }
            }
        }
    }

    func testCompleteDeltaAllowsExplicitSameValueSetAndAbsentKeyUnset() throws {
        try fixture { index, _ in
            let item = try id()
            let origin = try id()
            let root = try record(
                item: item, origin: origin, values: ["subject": .text("original"), "label": .text("old")])
            let child = try record(
                item: item, origin: origin, parents: [root.row.revisionID],
                values: ["subject": .text("original"), "body": .text("new")],
                writes: ["body", "subject"], unset: ["absent", "label"])
            try insert(child, into: index)
            try insert(root, into: index)
            try index.validateRecoveryGraph()
            XCTAssertEqual(try index.recoveryHead()?.revisionID, child.row.revisionID)
        }
    }

    func testPageBytePrefixRetainsCursorAndOversizedRowFailsBeforeDecode() throws {
        try fixture { index, _ in
            let item = try id()
            let origin = try id()
            let root = try record(item: item, origin: origin)
            let child = try record(item: item, origin: origin, parents: [root.row.revisionID], writes: [])
            try insert(root, into: index)
            try insert(child, into: index)
            // A single ordinary metadata row fits; two do not. No large fixture is written.
            index.graphMaximumPageBytes = 1800
            let first = try index.recoveryRowPage(limit: 128)
            XCTAssertEqual(first.count, 1)
            let second = try index.recoveryRowPage(after: first[0].revisionID, limit: 128)
            XCTAssertEqual(second.count, 1)
            XCTAssertNotEqual(first[0].revisionID, second[0].revisionID)
            XCTAssertTrue(try index.recoveryRowPage(after: second[0].revisionID).isEmpty)
            index.graphMaximumPageBytes = 128
            // Corrupt only derived JSON; a raw-byte window must reject before JSON decoding.
            try index.execute(
                "UPDATE revision_catalog SET provenance='not-json' || replace(hex(zeroblob(256)),'00','x') WHERE revision=?",
                [root.row.revisionID])
            code("resourceLimit") { _ = try index.recoveryRowPage(limit: 1) }
        }
    }

    func testVariableLocatorAndReceiptBytesParticipateInStorageEstimate() throws {
        try fixture { index, _ in
            let small = try record(item: try id())
            index.graphMaximumTemporaryBytes = 1024 * 1024 + 96 * 1024
            try insert(small, into: index)
            let wide = try record(item: try id(), actor: String(repeating: "a", count: 16 * 1024))
            code("resourceLimit") { try insert(wide, into: index) }
            XCTAssertNil(try index.revision(wide.row.revisionID))
            index.graphMaximumTemporaryBytes = 256 * 1024 * 1024
            try insert(wide, into: index)
            XCTAssertEqual(try index.revision(wide.row.revisionID)?.actor, wide.row.actor)
        }
    }

    func testNativeProgressCallbackReasonSurvivesSQLiteInterrupt() throws {
        try fixture { index, _ in
            var callbacks = 0
            code("nativeReviewStop") {
                try index.withCatalogueScanBudget(progress: {
                    callbacks += 1
                    if callbacks > 1 {
                        throw TractandaError("nativeReviewStop", "retain this original control reason")
                    }
                }) {
                    _ = try scalar(
                        index,
                        "WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM n WHERE value<1000) SELECT SUM(value) FROM n"
                    )
                }
            }
            XCTAssertGreaterThan(callbacks, 1)
            XCTAssertEqual(try scalar(index, "SELECT 1"), 1, "Progress handler is removed after interruption")
        }
    }

    func testShortStatementsConsumeCumulativeWorkBudgetAndTinyLimitFails() throws {
        try fixture { index, _ in
            index.graphMaximumVMInstructions = 1
            code("resourceLimit") {
                try index.withCatalogueScanBudget { _ = try scalar(index, "SELECT 1") }
            }
            index.graphMaximumVMInstructions = 100
            try index.withCatalogueScanBudget {
                for _ in 0..<8 { XCTAssertEqual(try scalar(index, "SELECT 1"), 1) }
            }
            index.graphMaximumVMInstructions = 10
            code("resourceLimit") {
                try index.withCatalogueScanBudget {
                    for _ in 0..<8 { _ = try scalar(index, "SELECT 1") }
                }
            }
            index.graphMaximumVMInstructions = 200_000_000
            XCTAssertEqual(try scalar(index, "SELECT 1"), 1)
        }
    }

    func testVmAccountingHandlesRowStepsAndCounterResetsBetweenSteps() throws {
        try fixture { index, _ in
            index.graphMaximumVMInstructions = 1000
            try index.withCatalogueScanBudget {
                let statement = try index.corpusPrepare("SELECT 1 UNION ALL SELECT 2")
                defer { sqlite3_finalize(statement) }
                XCTAssertEqual(index.catalogueStep(statement), SQLITE_ROW)
                _ = sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1)
                XCTAssertEqual(index.catalogueStep(statement), SQLITE_ROW)
                XCTAssertEqual(index.catalogueStep(statement), SQLITE_DONE)
                XCTAssertEqual(sqlite3_reset(statement), SQLITE_OK)
                _ = sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1)
                XCTAssertEqual(index.catalogueStep(statement), SQLITE_ROW)
            }
        }
    }
}
