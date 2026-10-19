import TractandaClient
import XCTest

@testable import TractandaCore

final class RevisionMergeAdversarialTests: XCTestCase {
    private let profile = RevisionMerge.profile

    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }

    private func revision(
        itemID: String, revisionID: String? = nil,
        at: String = "2026-10-13T12:00:00.000Z", fields: [String: ItemValue] = [:],
        supersedes: String? = nil
    ) throws -> Revision {
        let resolvedRevisionID: String
        if let revisionID { resolvedRevisionID = revisionID } else { resolvedRevisionID = try id() }
        var values: [String: ItemValue] = [
            "itemID": .text(itemID), "revisionID": .text(resolvedRevisionID), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date("2026-10-13T12:00:00.000Z"),
            "modifiedAt": .date(at), "actor": .text("user:fixture"), "operationID": .text(resolvedRevisionID),
            "requestIdentity": .text("fixture-" + resolvedRevisionID),
        ]
        values.merge(fields) { _, new in new }
        if let supersedes { values["supersedes"] = .text(supersedes) }
        return try Revision(fields: values)
    }

    private func node(
        _ revision: Revision, parents: [String] = [], writes: [String: RevisionFieldWrite] = [:]
    ) -> RevisionGraph.Node {
        let applied =
            parents.isEmpty
            ? RevisionMerge.semanticFields(revision).mapValues(RevisionFieldWrite.set)
            : writes
        return .init(revision: revision, parents: parents, kind: .authored(writes: applied))
    }

    private func branchFixture() throws -> (
        String, RevisionGraph.Node, RevisionGraph.Node, RevisionGraph.Node, RevisionGraph.Node
    ) {
        let itemID = try id()
        let root = try revision(
            itemID: itemID,
            fields: [
                "subject": .text("base"), "body": .text("base body"), "dueDate": .text("none"),
            ])
        let subject = try revision(
            itemID: itemID,
            fields: [
                "subject": .text("from-A"), "body": .text("base body"), "dueDate": .text("none"),
            ], supersedes: root.revisionID)
        let body = try revision(
            itemID: itemID,
            fields: [
                "subject": .text("base"), "body": .text("from-B"), "dueDate": .text("none"),
            ], supersedes: root.revisionID)
        let date = try revision(
            itemID: itemID,
            fields: [
                "subject": .text("base"), "body": .text("base body"), "dueDate": .text("from-C"),
            ], supersedes: root.revisionID)
        return (
            itemID, node(root),
            node(subject, parents: [root.revisionID], writes: ["subject": .set(.text("from-A"))]),
            node(body, parents: [root.revisionID], writes: ["body": .set(.text("from-B"))]),
            node(date, parents: [root.revisionID], writes: ["dueDate": .set(.text("from-C"))])
        )
    }

    func testThreePeerArrivalPermutationsHaveSameAuthoredFrontierAndProjection() throws {
        let (itemID, root, a, b, c) = try branchFixture()
        let variants = [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
        var expectedFrontier: Set<String>?
        var expectedValues: [String: RevisionFieldWrite]?
        for permutation in variants {
            let analysis = try RevisionGraph(nodes: [root] + permutation, profile: profile).analyze()
            XCTAssertEqual(Set(analysis.frontier), Set(permutation.map { $0.revision.revisionID }))
            XCTAssertEqual(analysis.values["subject"], .set(.text("from-A")))
            XCTAssertEqual(analysis.values["body"], .set(.text("from-B")))
            XCTAssertEqual(analysis.values["dueDate"], .set(.text("from-C")))
            XCTAssertTrue(analysis.conflicts.isEmpty)
            if let expectedFrontier { XCTAssertEqual(Set(analysis.frontier), expectedFrontier) }
            if let expectedValues { XCTAssertEqual(analysis.values, expectedValues) }
            expectedFrontier = Set(analysis.frontier)
            expectedValues = analysis.values
        }
        XCTAssertEqual(root.revision.itemID, itemID)
    }

    func testIndependentEquivalentMergeMaterializationsDoNotCreateAnotherMerge() throws {
        let (itemID, root, a, b, _) = try branchFixture()
        let frontier = [a.revision.revisionID, b.revision.revisionID].sorted()
        let mergedFields: [String: ItemValue] = [
            "subject": .text("from-A"), "body": .text("from-B"), "dueDate": .text("none"),
        ]
        let first = try revision(itemID: itemID, at: "2026-10-13T12:00:01.000Z", fields: mergedFields)
        let second = try revision(itemID: itemID, at: "2026-10-13T12:00:02.000Z", fields: mergedFields)
        let m1 = RevisionGraph.Node(
            revision: first, parents: frontier,
            kind: .automaticMerge(profile: profile, frontier: frontier))
        let m2 = RevisionGraph.Node(
            revision: second, parents: frontier,
            kind: .automaticMerge(profile: profile, frontier: frontier))
        let analysis = try RevisionGraph(nodes: [root, a, b, m1, m2], profile: profile).analyze()
        XCTAssertEqual(Set(analysis.frontier), Set(frontier))
        XCTAssertFalse(analysis.needsMaterialization)
        XCTAssertEqual(analysis.representativeRevisionID, second.revisionID)
        XCTAssertEqual(analysis.values["subject"], .set(.text("from-A")))
        XCTAssertEqual(analysis.values["body"], .set(.text("from-B")))
    }

    func testDescendantsOfEquivalentMergesShareContextAndLateOldMergeCannotDominateThem() throws {
        let (itemID, root, a, b, _) = try branchFixture()
        let frontier = [a.revision.revisionID, b.revision.revisionID].sorted()
        let baseFields: [String: ItemValue] = [
            "subject": .text("from-A"), "body": .text("from-B"), "dueDate": .text("none"),
        ]
        let m1Revision = try revision(itemID: itemID, at: "2026-10-13T12:00:01.000Z", fields: baseFields)
        let m2Revision = try revision(itemID: itemID, at: "2026-10-13T12:00:02.000Z", fields: baseFields)
        let m1 = RevisionGraph.Node(
            revision: m1Revision, parents: frontier,
            kind: .automaticMerge(profile: profile, frontier: frontier))
        let m2 = RevisionGraph.Node(
            revision: m2Revision, parents: frontier,
            kind: .automaticMerge(profile: profile, frontier: frontier))
        let dRevision = try revision(
            itemID: itemID, at: "2026-10-13T12:00:03.000Z",
            fields: ["subject": .text("from-D"), "body": .text("from-B"), "dueDate": .text("none")],
            supersedes: m1Revision.revisionID)
        let eRevision = try revision(
            itemID: itemID, at: "2026-10-13T12:00:04.000Z",
            fields: ["subject": .text("from-A"), "body": .text("from-E"), "dueDate": .text("none")],
            supersedes: m2Revision.revisionID)
        let d = node(dRevision, parents: [m1Revision.revisionID], writes: ["subject": .set(.text("from-D"))])
        let e = node(eRevision, parents: [m2Revision.revisionID], writes: ["body": .set(.text("from-E"))])
        let stale = try revision(
            itemID: itemID, at: "2099-01-01T00:00:00.000Z", fields: baseFields)
        let staleMerge = RevisionGraph.Node(
            revision: stale, parents: frontier,
            kind: .automaticMerge(profile: profile, frontier: frontier))

        for input in [[root, a, b, m1, m2, d, e], [root, e, m2, b, d, a, m1, staleMerge]] {
            let analysis = try RevisionGraph(nodes: input, profile: profile).analyze()
            XCTAssertEqual(
                Set(analysis.frontier),
                Set([dRevision.revisionID, eRevision.revisionID]))
            XCTAssertEqual(analysis.values["subject"], .set(.text("from-D")))
            XCTAssertEqual(analysis.values["body"], .set(.text("from-E")))
            XCTAssertTrue(analysis.conflicts.isEmpty)
        }
    }

    func testConcurrentDifferentValuesConflictButEqualValuesAndUnsetsCoalesce() throws {
        let itemID = try id()
        let root = try revision(itemID: itemID, fields: ["subject": .text("base"), "body": .text("body")])
        let left = try revision(
            itemID: itemID, fields: ["subject": .text("same"), "body": .text("body")],
            supersedes: root.revisionID)
        let right = try revision(
            itemID: itemID, fields: ["subject": .text("other"), "body": .text("body")],
            supersedes: root.revisionID)
        let equal = try revision(
            itemID: itemID, fields: ["subject": .text("same"), "body": .text("body")],
            supersedes: root.revisionID)
        let leftNode = node(left, parents: [root.revisionID], writes: ["subject": .set(.text("same"))])
        let rightNode = node(right, parents: [root.revisionID], writes: ["subject": .set(.text("other"))])
        let equalNode = node(equal, parents: [root.revisionID], writes: ["subject": .set(.text("same"))])

        let conflict = try RevisionGraph(nodes: [node(root), leftNode, rightNode], profile: profile).analyze()
        let conflictWrites = conflict.conflicts["subject", default: []].map(\.write)
        XCTAssertEqual(conflictWrites.count, 2)
        XCTAssertTrue(conflictWrites.contains(.set(.text("same"))))
        XCTAssertTrue(conflictWrites.contains(.set(.text("other"))))
        let coalesced = try RevisionGraph(nodes: [node(root), leftNode, equalNode], profile: profile)
            .analyze()
        XCTAssertNil(coalesced.conflicts["subject"])
        XCTAssertEqual(coalesced.values["subject"], .set(.text("same")))
    }

    func testMapsAndListsAreAtomicTopLevelValues() throws {
        let itemID = try id()
        let root = try revision(
            itemID: itemID,
            fields: [
                "settings": .object(["a": .integer(1)]),
                "tags": .list([.text("one")]),
            ])
        let left = try revision(
            itemID: itemID,
            fields: [
                "settings": .object(["a": .integer(2)]),
                "tags": .list([.text("one")]),
            ], supersedes: root.revisionID)
        let right = try revision(
            itemID: itemID,
            fields: [
                "settings": .object(["a": .integer(1), "b": .integer(2)]),
                "tags": .list([.text("one"), .text("two")]),
            ],
            supersedes: root.revisionID)
        let graph = try RevisionGraph(
            nodes: [
                node(root),
                node(
                    left, parents: [root.revisionID], writes: ["settings": .set(.object(["a": .integer(2)]))]),
                node(
                    right, parents: [root.revisionID],
                    writes: [
                        "settings": .set(.object(["a": .integer(1), "b": .integer(2)])),
                        "tags": .set(.list([.text("one"), .text("two")])),
                    ]),
            ], profile: profile)
        let analysis = try graph.analyze()
        XCTAssertEqual(Set(analysis.conflicts.keys), Set(["settings"]))
        XCTAssertEqual(analysis.values["tags"], .set(.list([.text("one"), .text("two")])))
    }

    func testUnsetConflictsWithConcurrentValueWrite() throws {
        let itemID = try id()
        let root = try revision(itemID: itemID, fields: ["label": .text("old")])
        let removed = try revision(itemID: itemID, fields: [:], supersedes: root.revisionID)
        let replaced = try revision(
            itemID: itemID, fields: ["label": .text("new")], supersedes: root.revisionID)
        let removal = node(removed, parents: [root.revisionID], writes: ["label": .unset])
        let replacement = node(replaced, parents: [root.revisionID], writes: ["label": .set(.text("new"))])
        let analysis = try RevisionGraph(nodes: [node(root), removal, replacement], profile: profile)
            .analyze()
        XCTAssertEqual(analysis.conflicts["label"]?.count, 2)
        XCTAssertNil(analysis.values["label"])
    }

    func testExplicitResolutionConsumesTheReviewedFrontier() throws {
        let itemID = try id()
        let root = try revision(itemID: itemID, fields: ["subject": .text("base")])
        let a = try revision(itemID: itemID, fields: ["subject": .text("A")], supersedes: root.revisionID)
        let b = try revision(itemID: itemID, fields: ["subject": .text("B")], supersedes: root.revisionID)
        let an = node(a, parents: [root.revisionID], writes: ["subject": .set(.text("A"))])
        let bn = node(b, parents: [root.revisionID], writes: ["subject": .set(.text("B"))])
        let reviewed = [a.revisionID, b.revisionID].sorted()
        let resolution = try revision(
            itemID: itemID, at: "2026-10-13T12:00:01.000Z", fields: ["subject": .text("chosen")])
        let rn = RevisionGraph.Node(
            revision: resolution, parents: reviewed,
            kind: .resolution(reviewedFrontier: reviewed, writes: ["subject": .set(.text("chosen"))]))
        let analysis = try RevisionGraph(nodes: [node(root), an, bn, rn], profile: profile).analyze()
        XCTAssertEqual(analysis.frontier, [resolution.revisionID])
        XCTAssertEqual(analysis.values["subject"], .set(.text("chosen")))
        XCTAssertTrue(analysis.conflicts.isEmpty)
    }

    func testForgedProfileAndOverBudgetGraphsFailClosed() throws {
        let (itemID, root, a, b, _) = try branchFixture()
        let frontier = [a.revision.revisionID, b.revision.revisionID].sorted()
        let mergeRevision = try revision(
            itemID: itemID,
            fields: [
                "subject": .text("from-A"), "body": .text("from-B"),
                "dueDate": .text("none"),
            ])
        let forged = RevisionGraph.Node(
            revision: mergeRevision, parents: frontier,
            kind: .automaticMerge(profile: "unknown.profile", frontier: frontier))
        XCTAssertThrowsError(try RevisionGraph(nodes: [root, a, b, forged], profile: profile).analyze())
        XCTAssertThrowsError(
            try RevisionGraph(
                nodes: [root, a, b], profile: profile,
                limits: .init(maximumNodes: 2, maximumEdges: 8, maximumEncodedBytes: 4096, maximumWork: 100)
            ).analyze())
    }

    func testMergeSnapshotAndDeclaredFrontierMustMatchActualParents() throws {
        let (itemID, root, a, b, _) = try branchFixture()
        let actualFrontier = [a.revision.revisionID, b.revision.revisionID].sorted()
        let incorrectSnapshot = try revision(
            itemID: itemID, at: "2026-10-13T12:00:01.000Z",
            fields: [
                "subject": .text("from-A"), "body": .text("base body"), "dueDate": .text("none"),
            ])
        let wrongPayload = RevisionGraph.Node(
            revision: incorrectSnapshot, parents: actualFrontier,
            kind: .automaticMerge(profile: profile, frontier: actualFrontier))
        XCTAssertThrowsError(
            try RevisionGraph(nodes: [root, a, b, wrongPayload], profile: profile).analyze())

        let forgedSubject = try revision(
            itemID: itemID, at: "2026-10-13T12:00:01.000Z",
            fields: [
                "subject": .text("from-A"), "body": .text("from-B"), "dueDate": .text("none"),
            ])
        let forgedContext = RevisionGraph.Node(
            revision: forgedSubject, parents: actualFrontier,
            kind: .automaticMerge(profile: profile, frontier: [a.revision.revisionID]))
        XCTAssertThrowsError(
            try RevisionGraph(nodes: [root, a, b, forgedContext], profile: profile).analyze())
    }

    func testResolutionCannotClaimIncompleteReviewedFrontier() throws {
        let itemID = try id()
        let root = try revision(itemID: itemID, fields: ["subject": .text("base")])
        let a = try revision(itemID: itemID, fields: ["subject": .text("A")], supersedes: root.revisionID)
        let b = try revision(itemID: itemID, fields: ["subject": .text("B")], supersedes: root.revisionID)
        let resolution = try revision(itemID: itemID, fields: ["subject": .text("chosen")])
        let actualParents = [a.revisionID, b.revisionID].sorted()
        let forged = RevisionGraph.Node(
            revision: resolution, parents: actualParents,
            kind: .resolution(reviewedFrontier: [a.revisionID], writes: ["subject": .set(.text("chosen"))]))
        XCTAssertThrowsError(
            try RevisionGraph(
                nodes: [
                    node(root), node(a, parents: [root.revisionID], writes: ["subject": .set(.text("A"))]),
                    node(b, parents: [root.revisionID], writes: ["subject": .set(.text("B"))]), forged,
                ],
                profile: profile
            ).analyze())
    }

    func testResolutionTimestampMustExceedEveryParentAtExact100NanosecondPrecision() throws {
        let itemID = try id()
        let root = try revision(itemID: itemID, fields: ["subject": .text("base")])
        let a = try revision(
            itemID: itemID, at: "2026-10-13T12:00:00.0049999Z",
            fields: ["subject": .text("A")], supersedes: root.revisionID)
        let b = try revision(
            itemID: itemID, at: "2026-10-13T12:00:00.0050000Z",
            fields: ["subject": .text("B")], supersedes: root.revisionID)
        let parents = [a.revisionID, b.revisionID].sorted()
        let graphNodes = [
            node(root),
            node(a, parents: [root.revisionID], writes: ["subject": .set(.text("A"))]),
            node(b, parents: [root.revisionID], writes: ["subject": .set(.text("B"))]),
        ]

        for timestamp in [
            "2026-10-13T12:00:00.0050000Z",  // equal to newest parent
            "2026-10-13T12:00:00.0049999Z",  // earlier
            "2026-10-13T13:00:00.0050000+01:00",  // same instant in another offset
        ] {
            let resolution = try revision(itemID: itemID, at: timestamp, fields: ["subject": .text("chosen")])
            let node = RevisionGraph.Node(
                revision: resolution, parents: parents,
                kind: .resolution(reviewedFrontier: parents, writes: ["subject": .set(.text("chosen"))]))
            XCTAssertThrowsError(
                try RevisionGraph(nodes: graphNodes + [node], profile: profile).analyze(), timestamp)
        }

        let valid = try revision(
            itemID: itemID, at: "2026-10-13T12:00:00.0050001Z", fields: ["subject": .text("chosen")])
        let validNode = RevisionGraph.Node(
            revision: valid, parents: parents,
            kind: .resolution(reviewedFrontier: parents, writes: ["subject": .set(.text("chosen"))]))
        _ = try RevisionGraph(nodes: graphNodes + [validNode], profile: profile).analyze()
        XCTAssertGreaterThan(try RevisionTimestamp(valid.modifiedAt), try RevisionTimestamp(b.modifiedAt))
    }

    func testTimestampSuccessorIsStrictAfterEveryInputAndRejectsUnparseableInput() throws {
        let inputs = ["2026-10-13T12:00:00.001Z", "2026-10-13T12:00:00.005Z"]
        let result = try RevisionMerge.timestamp(after: inputs, now: { "2026-10-13T12:00:00.002Z" })
        XCTAssertGreaterThan(
            try RevisionTimestamp(result), try RevisionTimestamp(inputs[1]))
        XCTAssertThrowsError(
            try RevisionMerge.timestamp(after: ["not-a-time"], now: { "2026-10-13T12:00:00Z" }))
    }
}
