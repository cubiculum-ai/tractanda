import XCTest

@testable import TractandaCore

final class RevisionGraphTests: XCTestCase {
    private func revision(
        itemID: String? = nil, parent: Revision? = nil,
        fields: [String: ItemValue] = ["subject": .text("initial")],
        at: String = "2026-10-13T12:00:00.000Z"
    ) throws -> Revision {
        let revisionID = try UUID.makeVersion1().uuidString.lowercased()
        let resolvedItemID = try parent?.itemID ?? itemID ?? UUID.makeVersion1().uuidString.lowercased()
        var values =
            parent?.fields ?? [
                "itemID": .text(resolvedItemID),
                "classID": .text("Item"), "schemaVersion": .integer(1),
                "createdAt": .date("2026-10-13T12:00:00.000Z"),
            ]
        values["revisionID"] = .text(revisionID)
        values["modifiedAt"] = .date(at)
        values["actor"] = .text("user:fixture")
        values["operationID"] = .text(revisionID)
        values["requestIdentity"] = .text("fixture")
        if let parent { values["supersedes"] = .text(parent.revisionID) }
        values.merge(fields) { _, new in new }
        return try Revision(fields: values)
    }

    private func assertCode(_ code: String, _ action: () throws -> Void) {
        XCTAssertThrowsError(try action()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, code, "\($0)")
        }
    }

    func testLegacyLinearSnapshotsProduceAppliedDeltasWithoutChangingOriginals() throws {
        let root = try revision()
        let edit = try revision(parent: root, fields: ["body": .text("applied")])
        let originalBytes = try JSON.encode(edit)
        let first = try RevisionMerge.legacyNode(root, parent: nil)
        let next = try RevisionMerge.legacyNode(edit, parent: root)
        XCTAssertEqual(next.kind.writes, ["body": .set(.text("applied"))])
        let analysis = try RevisionGraph(nodes: [next, first]).analyze()
        XCTAssertEqual(analysis.frontier, [edit.revisionID])
        XCTAssertEqual(analysis.representativeRevisionID, edit.revisionID)
        XCTAssertFalse(analysis.needsMaterialization)
        XCTAssertEqual(try JSON.encode(edit), originalBytes)
    }

    func testExactDuplicateIsInertButConflictingSameIdentityIsRejected() throws {
        let root = try revision()
        let node = try RevisionMerge.legacyNode(root, parent: nil)
        XCTAssertEqual(
            try RevisionGraph(nodes: [node, node]).analyze(), try RevisionGraph(nodes: [node]).analyze())
        var fields = root.fields
        fields["subject"] = .text("tampered")
        let changed = try RevisionMerge.legacyNode(Revision(fields: fields), parent: nil)
        assertCode("invalidRevisionGraph") { _ = try RevisionGraph(nodes: [node, changed]) }
    }

    func testProtectedChangeCannotBeMergedWithConcurrentOrdinaryChange() throws {
        let root = try revision(fields: ["subject": .text("initial"), "isDeleted": .boolean(false)])
        let deletion = try revision(parent: root, fields: ["isDeleted": .boolean(true)])
        let edit = try revision(parent: root, fields: ["subject": .text("edited")])
        let analysis = try RevisionGraph(nodes: [
            RevisionMerge.legacyNode(root, parent: nil),
            RevisionMerge.legacyNode(deletion, parent: root),
            RevisionMerge.legacyNode(edit, parent: root),
        ]).analyze()
        XCTAssertTrue(analysis.protectedFields.contains("isDeleted"))
        XCTAssertFalse(analysis.isResolved)
        XCTAssertFalse(analysis.needsMaterialization)
        XCTAssertNil(analysis.representativeRevisionID)
    }

    func testMalformedGraphAndAppliedSnapshotFailClosed() throws {
        let root = try revision()
        let edit = try revision(parent: root, fields: ["body": .text("added")])
        let first = try RevisionMerge.legacyNode(root, parent: nil)
        let next = try RevisionMerge.legacyNode(edit, parent: root)
        assertCode("invalidRevisionGraph") { _ = try RevisionGraph(nodes: [next]) }
        assertCode("invalidRevisionGraph") {
            _ = try RevisionGraph(nodes: [
                first, .init(revision: edit, parents: [root.revisionID], kind: .authored(writes: [:])),
            ])
        }
        let other = try RevisionMerge.legacyNode(revision(), parent: nil)
        assertCode("invalidRevisionGraph") { _ = try RevisionGraph(nodes: [first, other]) }
        assertCode("resourceLimit") {
            _ = try RevisionGraph(nodes: [first, next], limits: .init(maximumWork: 1))
        }
        assertCode("resourceLimit") {
            _ = try RevisionGraph(nodes: [first], limits: .init(maximumEncodedBytes: 64))
        }
    }

    func testNewExplicitSameValueWriteHasAuthoredCausality() throws {
        let root = try revision()
        let first = try revision(parent: root, fields: ["subject": .text("changed")])
        let same = try revision(parent: first, fields: ["subject": .text("changed")])
        let sameNode = RevisionGraph.Node(
            revision: same, parents: [first.revisionID],
            kind: .authored(writes: ["subject": .set(.text("changed"))]))
        let graph = try RevisionGraph(nodes: [
            RevisionMerge.legacyNode(root, parent: nil), RevisionMerge.legacyNode(first, parent: root),
            sameNode,
        ])
        XCTAssertEqual(try graph.analyze().frontier, [same.revisionID])
        XCTAssertEqual(sameNode.kind.writes["subject"], .set(.text("changed")))
        XCTAssertEqual(try RevisionMerge.legacyNode(same, parent: first).kind.writes, [:])
    }

    func testDomainInvalidSnapshotsAndOversizedClaimedFrontierAreRejected() throws {
        let invalid = try revision(fields: [
            "classID": .text("AccessConfigurationItem"), "isDeleted": .boolean(true),
        ])
        assertCode("invalidAccessConfiguration") {
            _ = try RevisionGraph(nodes: [RevisionMerge.legacyNode(invalid, parent: nil)])
        }
        let root = try revision()
        let next = try revision(parent: root)
        assertCode("resourceLimit") {
            _ = try RevisionGraph(
                nodes: [
                    RevisionMerge.legacyNode(root, parent: nil),
                    .init(
                        revision: next, parents: [root.revisionID],
                        kind: .resolution(
                            reviewedFrontier: Array(repeating: root.revisionID, count: 5), writes: [:])),
                ], limits: .init(maximumNodes: 4))
        }
    }

    func testDraftAllocatesRealUUIDOnlyForEligibleMergeAfterValidatedTimestamp() throws {
        let root = try revision()
        let a = try revision(parent: root, fields: ["subject": .text("A")])
        let b = try revision(parent: root, fields: ["body": .text("B")])
        let graph = try RevisionGraph(nodes: [
            RevisionMerge.legacyNode(root, parent: nil), RevisionMerge.legacyNode(a, parent: root),
            RevisionMerge.legacyNode(b, parent: root),
        ])
        var allocations = 0
        let draft = try XCTUnwrap(
            graph.draft(now: { "2020-01-01T00:00:00Z" }) {
                allocations += 1
                return try UUID.makeVersion1().uuidString.lowercased()
            })
        XCTAssertEqual(allocations, 1)
        XCTAssertEqual(Set(draft.parents), [a.revisionID, b.revisionID])
        XCTAssertEqual(draft.fields["subject"], .text("A"))
        XCTAssertEqual(draft.fields["body"], .text("B"))
        XCTAssertEqual(draft.modifiedAt, "2026-10-13T12:00:00.002Z")
        XCTAssertNotNil(UUID(uuidString: draft.revisionID)?.version1Components)
        assertCode("identifierCollision") {
            _ = try graph.draft(now: { "2026-10-13T12:00:00Z" }, allocateRevisionID: { a.revisionID })
        }
        assertCode("invalidMergeTimestamp") {
            _ = try graph.draft(now: { "bad" }) {
                allocations += 1
                return draft.revisionID
            }
        }
        XCTAssertEqual(allocations, 1)
        let singleton = try RevisionGraph(nodes: [RevisionMerge.legacyNode(root, parent: nil)])
        XCTAssertNil(
            try singleton.draft(now: { "bad" }) {
                XCTFail("No merge allocation expected")
                return draft.revisionID
            })
    }

    func testTimestampExactPrecisionOffsetRolloverAndExhaustion() throws {
        XCTAssertEqual(
            try RevisionMerge.timestamp(
                after: ["2026-10-13T23:59:59.9999999Z"], now: { "2020-01-01T00:00:00Z" }),
            "2026-10-14T00:00:00.0000000Z")
        XCTAssertEqual(
            try RevisionTimestamp("2026-10-13T12:00:00+02:00"), try RevisionTimestamp("2026-10-13T10:00:00Z"))
        XCTAssertEqual(
            try RevisionTimestamp("1969-12-31T23:59:59.9999999Z").formatted(), "1969-12-31T23:59:59.9999999Z")
        for input in ["2026-02-30T00:00:00Z", "2026-10-13T12:00:00.12345678Z", "0001-01-01T00:00:00+01:00"] {
            assertCode("invalidMergeTimestamp") { _ = try RevisionTimestamp(input) }
        }
        assertCode("invalidMergeTimestamp") {
            _ = try RevisionMerge.timestamp(
                after: ["9999-12-31T23:59:59.9999999Z"], now: { "2026-10-13T12:00:00Z" })
        }
    }

    func testTimestampUsesProlepticGregorianCalendarAndBoundedInput() throws {
        for input in ["0001-01-01T00:00:00Z", "1582-10-10T00:00:00Z", "2000-02-29T00:00:00Z"] {
            XCTAssertEqual(try RevisionTimestamp(input).formatted(), String(input.dropLast()) + ".0000000Z")
        }
        XCTAssertEqual(try RevisionTimestamp("1970-01-01T00:00:00Z").ticks, 0)
        for input in ["1500-02-29T00:00:00Z", String(repeating: "x", count: 1000)] {
            assertCode("invalidMergeTimestamp") { _ = try RevisionTimestamp(input) }
        }
        assertCode("invalidMergeTimestamp") {
            _ = try RevisionMerge.timestamp(
                after: Array(repeating: "2026-10-13T12:00:00Z", count: 4097), now: { "2026-10-13T12:00:00Z" })
        }
    }
}
