import CSQLite
import XCTest

@testable import TractandaCore

final class RevisionPublicationTests: XCTestCase {
    private func revision(
        itemID: String? = nil, parent: Revision? = nil, subject: String = "base", body: String = "body",
        at: String = "2026-10-13T12:00:00.000Z"
    ) throws -> Revision {
        let item = try itemID ?? parent?.itemID ?? UUID.makeVersion1().uuidString.lowercased()
        let id = try UUID.makeVersion1().uuidString.lowercased()
        var fields: [String: ItemValue] = [
            "itemID": .text(item), "revisionID": .text(id), "classID": .text("Item"),
            "schemaVersion": .integer(1),
            "createdAt": parent?.fields["createdAt"] ?? .date("2026-10-13T12:00:00.000Z"),
            "modifiedAt": .date(at), "actor": .text("user:fixture"), "operationID": .text(id),
            "requestIdentity": .text("fixture"), "subject": .text(subject), "body": .text(body),
        ]
        if let parent { fields["supersedes"] = .text(parent.revisionID) }
        return try Revision(fields: fields)
    }

    private func materialization(_ draft: RevisionMerge.Draft, like source: Revision) throws
        -> RevisionGraph.Node
    {
        var fields = source.fields
        fields.removeValue(forKey: "supersedes")
        fields["revisionID"] = .text(draft.revisionID)
        fields["modifiedAt"] = .date(draft.modifiedAt)
        fields["operationID"] = .text(draft.revisionID)
        for (field, value) in draft.fields { fields[field] = value }
        return .init(
            revision: try Revision(fields: fields), parents: draft.parents,
            kind: .automaticMerge(profile: draft.profile, frontier: draft.frontier))
    }

    func testPublicationClockUsesTrueNegativeFloorRuntimePrecisionAndCheckedUpperBound() throws {
        XCTAssertEqual(
            try RevisionPublicationClock.after(
                ["1969-12-31T23:59:59.9999999Z"], now: { "1960-01-01T00:00:00Z" }), "1970-01-01T00:00:00.001Z"
        )
        let parent = "2026-10-13T12:00:00.0009999Z"
        let next = try RevisionPublicationClock.after([parent], now: { "2020-01-01T00:00:00Z" })
        XCTAssertEqual(next, "2026-10-13T12:00:00.002Z")
        XCTAssertGreaterThan(try XCTUnwrap(Timestamp.parse(next)), try XCTUnwrap(Timestamp.parse(parent)))
        XCTAssertEqual(
            try RevisionPublicationClock.after([parent], now: { "2027-01-01T00:00:00.0039Z" }),
            "2027-01-01T00:00:00.003Z")
        XCTAssertEqual(
            try RevisionPublicationClock.after(
                ["9999-12-31T23:59:59.9979999Z"], now: { parent }),
            "9999-12-31T23:59:59.999Z")
        XCTAssertThrowsError(
            try RevisionPublicationClock.after(["9999-12-31T23:59:59.9999999Z"], now: { parent }))
    }

    func testSinglePhysicalHeadClockRegressionUsesRealHistoricalWitnessWithoutLoops() throws {
        let root = try revision(at: "2026-10-13T12:05:00Z")
        let edit = try revision(parent: root, subject: "edited", at: "2026-10-13T12:01:00Z")
        let inputs = [
            try RevisionMerge.legacyNode(root, parent: nil), try RevisionMerge.legacyNode(edit, parent: root),
        ]
        let graph = try RevisionGraph(nodes: inputs)
        XCTAssertEqual(try graph.analyze().frontier, [edit.revisionID])
        let draft = try XCTUnwrap(
            graph.draft(
                now: { "2026-10-13T12:00:00Z" },
                allocateRevisionID: { try UUID.makeVersion1().uuidString.lowercased() }))
        XCTAssertEqual(Set(draft.parents), [root.revisionID, edit.revisionID])
        XCTAssertEqual(draft.frontier, [edit.revisionID])
        XCTAssertEqual(draft.modifiedAt, "2026-10-13T12:05:00.002Z")
        let reconciled = try materialization(draft, like: edit)
        let final = try RevisionGraph(nodes: inputs + [reconciled])
        XCTAssertEqual(try final.analyze().representativeRevisionID, draft.revisionID)
        XCTAssertFalse(try final.analyze().needsMaterialization)
        XCTAssertNil(
            try final.draft(
                now: { "2099-01-01T00:00:00Z" },
                allocateRevisionID: {
                    XCTFail("No equivalent-triggered allocation")
                    return draft.revisionID
                }))
        var repeated = draft
        repeated = .init(
            itemID: draft.itemID, revisionID: try UUID.makeVersion1().uuidString.lowercased(),
            parents: [draft.revisionID, root.revisionID].sorted(), frontier: draft.frontier,
            profile: draft.profile, fields: draft.fields, modifiedAt: "2026-10-13T12:05:00.004Z")
        XCTAssertThrowsError(
            try RevisionGraph(nodes: inputs + [reconciled, materialization(repeated, like: edit)]))
    }

    func testLateObsoleteEquivalentRaisesClockButNeverBecomesCurrent() throws {
        let root = try revision()
        let a = try revision(parent: root, subject: "A")
        let b = try revision(parent: root, body: "B")
        let frontier = [a.revisionID, b.revisionID].sorted()
        let m = try revision(itemID: root.itemID, subject: "A", body: "B", at: "2026-10-13T12:00:00.002Z")
        let mNode = RevisionGraph.Node(
            revision: m, parents: frontier,
            kind: .automaticMerge(profile: RevisionMerge.profile, frontier: frontier))
        let e = try revision(parent: m, subject: "E", body: "B", at: "2026-10-13T12:01:00Z")
        let n = try revision(itemID: root.itemID, subject: "A", body: "B", at: "2026-10-13T12:05:00Z")
        let nNode = RevisionGraph.Node(
            revision: n, parents: frontier,
            kind: .automaticMerge(profile: RevisionMerge.profile, frontier: frontier))
        let inputs = [
            try RevisionMerge.legacyNode(root, parent: nil), try RevisionMerge.legacyNode(a, parent: root),
            try RevisionMerge.legacyNode(b, parent: root), mNode, try RevisionMerge.legacyNode(e, parent: m),
            nNode,
        ]
        let graph = try RevisionGraph(nodes: inputs)
        XCTAssertEqual(try graph.analyze().representativeRevisionID, e.revisionID)
        XCTAssertEqual(try graph.analyze().values["subject"], .set(.text("E")))
        let first = try XCTUnwrap(
            graph.draft(
                now: { "2020-01-01T00:00:00Z" },
                allocateRevisionID: { try UUID.makeVersion1().uuidString.lowercased() }))
        let second = try XCTUnwrap(
            graph.draft(
                now: { "2026-10-13T12:06:00Z" },
                allocateRevisionID: { try UUID.makeVersion1().uuidString.lowercased() }))
        for order in [[first, second], [second, first]] {
            let combined = try RevisionGraph(nodes: inputs + order.map { try materialization($0, like: e) })
            XCTAssertEqual(try combined.analyze().representativeRevisionID, second.revisionID)
            XCTAssertFalse(try combined.analyze().needsMaterialization)
        }
        let late = try revision(itemID: root.itemID, subject: "A", body: "B", at: "2026-10-13T12:07:00Z")
        let lateNode = RevisionGraph.Node(
            revision: late, parents: frontier,
            kind: .automaticMerge(profile: RevisionMerge.profile, frontier: frontier))
        let prior = try inputs + [materialization(second, like: e), lateNode]
        let raised = try RevisionGraph(nodes: prior)
        XCTAssertEqual(try raised.analyze().representativeRevisionID, second.revisionID)
        let third = try XCTUnwrap(
            raised.draft(
                now: { "2020-01-01T00:00:00Z" },
                allocateRevisionID: { try UUID.makeVersion1().uuidString.lowercased() }))
        XCTAssertEqual(Set(third.parents), [second.revisionID, late.revisionID])
        XCTAssertEqual(third.modifiedAt, "2026-10-13T12:07:00.002Z")
        XCTAssertFalse(
            try RevisionGraph(nodes: prior + [materialization(third, like: e)])
                .analyze().needsMaterialization)
    }

    func testPlannerReportsUnmaterializablePayloadSeparatelyAndPreservesUUIDIssuanceTime() throws {
        let root = try revision(subject: String(repeating: "large", count: 80), at: "2099-01-01T00:00:00Z")
        let edit = try revision(
            parent: root, subject: String(repeating: "large", count: 80), at: "2098-01-01T00:00:00Z")
        let analysis = try RevisionGraph(nodes: [
            RevisionMerge.legacyNode(root, parent: nil), RevisionMerge.legacyNode(edit, parent: root),
        ]).analyze()
        let snapshot = RevisionProjection.Snapshot(
            itemID: root.itemID, analysis: analysis,
            representative: .init(revisionID: edit.revisionID, modifiedAt: edit.modifiedAt),
            clockFloor: .init(revisionID: root.revisionID, modifiedAt: root.modifiedAt),
            physicalHeads: [edit.revisionID])
        guard
            case .blocked(.payloadLimit) = try RevisionProjection.plan(
                snapshot, maximumPayloadBytes: 128, now: { root.modifiedAt })
        else { return XCTFail("Expected explicit payload block") }
        guard case .ready(let plan) = try RevisionProjection.plan(snapshot, now: { "2026-10-13T12:00:00Z" })
        else { return XCTFail("Expected bounded plan") }
        let issued = try UUID.makeVersion1()
        let draft = try RevisionProjection.draft(
            plan, itemID: root.itemID, allocate: { issued }, isAvailable: { _ in true })
        XCTAssertEqual(draft.revisionID, issued.uuidString.lowercased())
        XCTAssertEqual(UUID(uuidString: draft.revisionID)?.version1Components, issued.version1Components)
        XCTAssertEqual(draft.modifiedAt, "2099-01-01T00:00:00.002Z")
    }

    func testPureAdapterCannotOverrideCanonicalAppliedWrites() throws {
        let root = try revision()
        let child = try revision(parent: root, subject: "changed")
        var fields = child.fields
        fields["revisionAncestry"] = try RevisionProvenance(
            kind: .authored,
            originReplicaID: UUID.makeVersion1().uuidString.lowercased(), parents: [root.revisionID],
            writtenFields: ["body"], unsetFields: [], frontier: []
        ).itemValue
        let modern = try Revision(fields: fields, formatVersion: 2)
        let inconsistent = RevisionGraph.Node(
            revision: modern, parents: [root.revisionID],
            kind: .authored(writes: ["subject": .set(.text("changed"))]))
        XCTAssertThrowsError(
            try RevisionGraph(nodes: [
                RevisionMerge.legacyNode(root, parent: nil), inconsistent,
            ])
        ) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "invalidRevisionGraph")
        }
    }

    func testPortableProfileAcceptsWitnessShapeButRejectsUnsupportedOrSingleParentMetadata() throws {
        let origin = try UUID.makeVersion1().uuidString.lowercased()
        let first = try UUID.makeVersion1().uuidString.lowercased()
        let second = try UUID.makeVersion1().uuidString.lowercased()
        let metadata = try RevisionProvenance(
            kind: .automaticMerge, originReplicaID: origin,
            parents: [first, second].sorted(), writtenFields: [], unsetFields: [], frontier: [second],
            mergeProfile: RevisionMerge.profile)
        XCTAssertEqual(try RevisionProvenance(value: metadata.itemValue), metadata)
        XCTAssertThrowsError(
            try RevisionProvenance(
                kind: .automaticMerge, originReplicaID: origin,
                parents: [second], writtenFields: [], unsetFields: [], frontier: [second],
                mergeProfile: RevisionMerge.profile))
        XCTAssertThrowsError(
            try RevisionProvenance(
                kind: .automaticMerge, originReplicaID: origin,
                parents: [first, second].sorted(), writtenFields: [], unsetFields: [], frontier: [second],
                mergeProfile: "unsupported"))
    }

    func testRuntimeIndexedOrderingAndDateFilterSeeAdvancedMillisecondClock() throws {
        try AttachmentFixtureCapacity.requireFree()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-publication-" + Identifier.make())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try ItemIndex(path: directory.appendingPathComponent("index.sqlite").path, create: true)
        defer { index.close() }
        let parent = try revision(at: "2026-10-13T12:00:00.0009999Z")
        let advanced = try RevisionPublicationClock.after(
            [parent.modifiedAt], now: { "2020-01-01T00:00:00Z" })
        let child = try revision(parent: parent, subject: "changed", at: advanced)
        let control = try revision(at: parent.modifiedAt)
        try index.put(control)
        try index.put(parent)
        try index.put(child)
        let prior = try XCTUnwrap(Timestamp.parse(parent.modifiedAt)).timeIntervalSinceReferenceDate
        let statement = try index.corpusPrepare(
            "SELECT id FROM items WHERE modified>CAST(? AS REAL) ORDER BY modified DESC,id", [String(prior)])
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0))), child.itemID)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        let scalar = try index.corpusPrepare(
            "SELECT item_id FROM scalar_value WHERE field='modifiedAt' AND date_value>CAST(? AS REAL)",
            [String(prior)])
        defer { sqlite3_finalize(scalar) }
        XCTAssertEqual(sqlite3_step(scalar), SQLITE_ROW)
        XCTAssertEqual(String(cString: try XCTUnwrap(sqlite3_column_text(scalar, 0))), child.itemID)
        XCTAssertEqual(sqlite3_step(scalar), SQLITE_DONE)
    }
}
