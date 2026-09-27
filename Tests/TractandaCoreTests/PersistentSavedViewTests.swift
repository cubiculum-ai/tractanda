import XCTest

@testable import TractandaCore

final class PersistentSavedViewTests: XCTestCase {
    private func create(
        _ store: ItemStore, _ fields: [String: ItemValue], classID: String = "Item"
    ) throws -> Revision {
        try store.commit(CommitRequest(classID: classID, changes: fields, operationID: Identifier.make()))
            .revision
    }

    private func edit(_ store: ItemStore, _ item: Revision, _ fields: [String: ItemValue]) throws
        -> Revision
    {
        try store.commit(
            CommitRequest(
                action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                changes: fields, operationID: Identifier.make())
        ).revision
    }

    func testScalarSavedViewMembershipPersistsAndTracksAffectedItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let matching = try create(store, ["bucket": .integer(1), "notes": .text("old")])
        var nonmatching = try create(store, ["bucket": .integer(0)])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "expression": .text("bucket == 1"),
                ])
            ])

        XCTAssertEqual(
            try Categories.page(
                store: store, expression: "bucket == 1", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
                timeZone: "UTC", savedViewID: view.itemID
            ).ids,
            [matching.itemID])
        XCTAssertEqual(try store.savedViewBaseIDsForTesting(id: view.itemID), [matching.itemID])

        nonmatching = try edit(store, nonmatching, ["notes": .text("irrelevant")])
        XCTAssertEqual(try store.savedViewBaseIDsForTesting(id: view.itemID), [matching.itemID])
        let entered = try edit(store, nonmatching, ["bucket": .integer(1)])
        XCTAssertEqual(
            try store.savedViewBaseIDsForTesting(id: view.itemID), [matching.itemID, entered.itemID])
        let left = try edit(store, entered, ["bucket": .integer(0)])
        XCTAssertEqual(try store.savedViewBaseIDsForTesting(id: view.itemID), [matching.itemID])
        XCTAssertEqual(
            try Categories.page(
                store: store, expression: "bucket == 1", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
                timeZone: "UTC", savedViewID: view.itemID
            ).ids,
            [matching.itemID])
        XCTAssertNotEqual(entered.revisionID, left.revisionID)

        try store.rebuildIndex()
        XCTAssertFalse(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertTrue(try store.savedViewBaseIDsForTesting(id: view.itemID).isEmpty)
        XCTAssertEqual(
            try Categories.page(
                store: store, expression: "bucket == 1", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
                timeZone: "UTC", savedViewID: view.itemID
            ).ids,
            [matching.itemID])
        XCTAssertTrue(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertEqual(try store.savedViewBaseIDsForTesting(id: view.itemID), [matching.itemID])
    }

    func testCategorySavedViewPersistsRuleMatchesAndKeepsExactCategoryEvaluation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let category = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 1"),
                ])
            ])
        let member = try create(store, ["bucket": .integer(1)])
        let nonmember = try create(
            store,
            [
                "bucket": .integer(1),
                "categoryOverrides": .object([category.itemID: .text("exclude")]),
            ])
        _ = try create(store, ["bucket": .integer(0)])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 1"),
                    "categoryPath": .list([.reference(ItemReference(category.itemID))]),
                ])
            ])

        let first = try Categories.page(
            store: store, expression: "bucket == 1", text: nil, categoryPath: [category.itemID],
            excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
            timeZone: "UTC", savedViewID: view.itemID)
        XCTAssertEqual(first.ids, [member.itemID])
        XCTAssertEqual(first.total, 1)
        XCTAssertTrue(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertEqual(
            try store.savedViewBaseIDsForTesting(id: view.itemID),
            [member.itemID, nonmember.itemID])

        let entered = try create(store, ["bucket": .integer(1)])
        XCTAssertEqual(
            try store.savedViewBaseIDsForTesting(id: view.itemID),
            [member.itemID, nonmember.itemID, entered.itemID])
        let refreshed = try Categories.page(
            store: store, expression: "bucket == 1", text: nil, categoryPath: [category.itemID],
            excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
            timeZone: "UTC", savedViewID: view.itemID)
        XCTAssertEqual(Set(refreshed.ids), [member.itemID, entered.itemID])
        XCTAssertEqual(refreshed.total, 2)
    }

    func testCategoryOnlySavedViewPersistsPositiveSeedsAndPersonalTargets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let category = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 1"),
                ])
            ])
        let matching = try create(store, ["bucket": .integer(1)])
        let excluded = try create(
            store,
            [
                "bucket": .integer(1),
                "categoryOverrides": .object([category.itemID: .text("exclude")]),
            ])
        let manual = try create(
            store,
            [
                "bucket": .integer(0),
                "categoryOverrides": .object([category.itemID: .text("include")]),
            ])
        let personalTarget = try create(store, ["bucket": .integer(0)])
        _ = try create(
            store,
            [
                "target": .reference(ItemReference(personalTarget.itemID)),
                "personalOverrides": .object([category.itemID: .text("include")]),
            ],
            classID: "PersonalStateItem")
        let unrelated = try create(store, ["bucket": .integer(0)])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(category.itemID))]),
                ])
            ])

        _ = try Categories.page(
            store: store, expression: nil, text: nil, categoryPath: [category.itemID],
            excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
            timeZone: "UTC", savedViewID: view.itemID)
        XCTAssertTrue(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertTrue(store.lastSavedViewBaseAppliedForTesting)
        let base = try store.savedViewBaseIDsForTesting(id: view.itemID)
        XCTAssertTrue(base.contains(matching.itemID))
        XCTAssertTrue(base.contains(excluded.itemID))
        XCTAssertTrue(base.contains(manual.itemID))
        XCTAssertFalse(base.contains(personalTarget.itemID))
        XCTAssertFalse(base.contains(unrelated.itemID))
        let lookups = store.savedViewCategoryPlanLookupsForTesting
        let laterUnrelated = try create(store, ["notes": .text("not a category candidate")])
        XCTAssertEqual(store.savedViewCategoryPlanLookupsForTesting, lookups)
        XCTAssertFalse(try store.savedViewBaseIDsForTesting(id: view.itemID).contains(laterUnrelated.itemID))
    }

    func testChildRuleEditInvalidatesRootViewAndRecoveryRebuildsPositiveBase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let root = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 9"),
                ])
            ])
        let child = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 2"),
                ]),
                "categoryParents": .list([.reference(ItemReference(root.itemID))]),
            ])
        let oldMatch = try create(store, ["bucket": .integer(2)])
        let newMatch = try create(store, ["bucket": .integer(3)])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(root.itemID))]),
                ])
            ])
        func page() throws -> ItemIndex.Page {
            try Categories.page(
                store: store, expression: nil, text: nil, categoryPath: [root.itemID],
                excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
                timeZone: "UTC", savedViewID: view.itemID)
        }
        XCTAssertEqual(try page().ids, [oldMatch.itemID])
        XCTAssertTrue(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertTrue(store.lastSavedViewBaseAppliedForTesting)
        XCTAssertEqual(try store.savedViewBaseIDsForTesting(id: view.itemID), [oldMatch.itemID])

        _ = try edit(
            store, child,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 3"),
                ])
            ])
        XCTAssertFalse(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertTrue(try store.savedViewBaseIDsForTesting(id: view.itemID).isEmpty)
        XCTAssertEqual(try page().ids, [newMatch.itemID])
        XCTAssertTrue(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertEqual(try store.savedViewBaseIDsForTesting(id: view.itemID), [newMatch.itemID])

        try store.rebuildIndex()
        XCTAssertFalse(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertEqual(try page().ids, [newMatch.itemID])
        XCTAssertTrue(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertEqual(try store.savedViewBaseIDsForTesting(id: view.itemID), [newMatch.itemID])
    }

    func testAllItemsSavedViewDoesNotDuplicateBaseIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        _ = try create(store, ["subject": .text("first")])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile)
                ])
            ])

        XCTAssertTrue(try store.savedViewBaseIDsForTesting(id: view.itemID).isEmpty)
        XCTAssertEqual(
            try Categories.page(
                store: store, expression: nil, text: nil, categoryPath: [], excludedCategoryIDs: [],
                sort: [], position: 0, limit: 10, at: Date(), timeZone: "UTC",
                savedViewID: view.itemID
            ).total,
            2)
    }

    func testRecoveryBuildHandlesViewDefinitionBeforeCandidateItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "expression": .text("bucket == 1"),
                ])
            ])
        let first = try create(store, ["bucket": .integer(1)])
        _ = try create(store, ["bucket": .integer(0)])
        try store.rebuildIndex()

        XCTAssertEqual(
            try Categories.page(
                store: store, expression: "bucket == 1", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
                timeZone: "UTC", savedViewID: view.itemID
            ).ids,
            [first.itemID])
        XCTAssertTrue(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertEqual(try store.savedViewBaseIDsForTesting(id: view.itemID), [first.itemID])
    }

    func testOversizedBuildCandidateFallsBackBeforeRetainingFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let item = try create(
            store, ["bucket": .integer(1), "notes": .text(String(repeating: "x", count: 512))])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "expression": .text("bucket == 1"),
                ])
            ])
        store.setSavedViewMaterializationByteLimitForTesting(64)

        let page = try Categories.page(
            store: store, expression: "bucket == 1", text: nil, categoryPath: [],
            excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
            timeZone: "UTC", savedViewID: view.itemID)
        XCTAssertEqual(page.ids, [item.itemID])
        XCTAssertEqual(page.total, 1)
        XCTAssertFalse(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertTrue(try store.savedViewBaseIDsForTesting(id: view.itemID).isEmpty)
        XCTAssertTrue(try store.savedViewStagedIDsForTesting(id: view.itemID).isEmpty)
    }

    func testOnDemandCatchUpKeepsUnrelatedChangesAndRestartsForRelevantChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let items = try (0..<5).map { index in
            try create(store, ["bucket": .integer(1), "notes": .text("row-\(index)")])
        }
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "expression": .text("bucket == 1"),
                ])
            ])
        store.setSavedViewMaterializationBatchLimitForTesting(2)

        func page() throws -> ItemIndex.Page {
            try Categories.page(
                store: store, expression: "bucket == 1", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
                timeZone: "UTC", savedViewID: view.itemID)
        }

        XCTAssertEqual(try page().total, 5)
        XCTAssertFalse(try store.savedViewIndexIsReady(view.itemID))
        let initialStage = try store.savedViewStagedIDsForTesting(id: view.itemID)
        XCTAssertEqual(initialStage.count, 2)

        let stagedItem = try XCTUnwrap(items.first { initialStage.contains($0.itemID) })
        _ = try edit(store, stagedItem, ["notes": .text("unrelated edit")])
        XCTAssertEqual(try store.savedViewStagedIDsForTesting(id: view.itemID), initialStage)
        let notYetScanned = try XCTUnwrap(items.first { !initialStage.contains($0.itemID) })
        _ = try edit(store, notYetScanned, ["notes": .text("changed before its build batch")])
        let newlyCreatedNonmember = try create(store, ["bucket": .integer(0)])
        XCTAssertTrue(try store.savedViewStagedIDsForTesting(id: view.itemID).isSuperset(of: initialStage))
        XCTAssertEqual(try page().total, 5)
        XCTAssertEqual(try store.savedViewStagedIDsForTesting(id: view.itemID).count, 4)

        let relevantItem = try XCTUnwrap(items.first { initialStage.contains($0.itemID) })
        let current = try XCTUnwrap(store.get(relevantItem.itemID))
        _ = try edit(store, current, ["bucket": .integer(0)])
        XCTAssertFalse(try store.savedViewStagedIDsForTesting(id: view.itemID).contains(relevantItem.itemID))
        XCTAssertFalse(try store.savedViewIndexIsReady(view.itemID))

        for _ in 0..<5 {
            if try store.savedViewIndexIsReady(view.itemID) { break }
            _ = try page()
        }
        XCTAssertTrue(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertEqual(try page().total, 4)
        XCTAssertEqual(
            try store.savedViewBaseIDsForTesting(id: view.itemID),
            Set(items.map(\.itemID).filter { $0 != relevantItem.itemID }))
        XCTAssertFalse(
            try store.savedViewBaseIDsForTesting(id: view.itemID).contains(newlyCreatedNonmember.itemID))
        let modifiedOrder = try ItemSort(property: "modifiedAt", isAscending: false)
        let oracle = try Categories.query(
            store: store, expression: "bucket == 1", sort: [modifiedOrder]
        ).map(\.itemID)
        XCTAssertEqual(try page().ids, oracle)
    }

    func testRelevantItemAddedAheadOfBuildCursorDoesNotDuplicateStagingRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let initial = try (0..<4).map { _ in try create(store, ["bucket": .integer(1)]) }
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 1"),
                ])
            ])
        store.setSavedViewMaterializationBatchLimitForTesting(1)
        func page() throws -> ItemIndex.Page {
            try Categories.page(
                store: store, expression: "bucket == 1", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
                timeZone: "UTC", savedViewID: view.itemID)
        }
        XCTAssertEqual(try page().total, initial.count)
        XCTAssertFalse(try store.savedViewIndexIsReady(view.itemID))
        let added = try create(store, ["bucket": .integer(1)])
        XCTAssertTrue(try store.savedViewStagedIDsForTesting(id: view.itemID).contains(added.itemID))
        for _ in 0..<10 {
            if try store.savedViewIndexIsReady(view.itemID) { break }
            _ = try page()
        }
        XCTAssertTrue(try store.savedViewIndexIsReady(view.itemID))
        XCTAssertEqual(try page().total, initial.count + 1)
        XCTAssertEqual(
            try store.savedViewBaseIDsForTesting(id: view.itemID),
            Set(initial.map(\.itemID) + [added.itemID]))
    }

    func testManualOnlyCategoryUsesPositiveCandidateSeeds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let category = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
                ])
            ])
        let included = try create(
            store, ["categoryOverrides": .object([category.itemID: .text("include")])])
        _ = try create(store, ["subject": .text("no manual membership")])

        XCTAssertEqual(
            try Categories.query(store: store, categoryPath: [category.itemID]).map(\.itemID),
            [included.itemID])
    }

    func testRuleCategorySavedViewUsesIndexedPositiveStreamPastArrayLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let category = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 1"),
                ])
            ])
        let matched = try (0..<4).map { _ in try create(store, ["bucket": .integer(1)]) }
        _ = try (0..<6).map { _ in try create(store, ["bucket": .integer(0)]) }
        let manual = try create(
            store, ["bucket": .integer(0), "categoryOverrides": .object([category.itemID: .text("include")])])
        let personalTarget = try create(store, ["bucket": .integer(0)])
        let includedPersonal = try create(
            store,
            [
                "target": .reference(ItemReference(personalTarget.itemID)),
                "personalOverrides": .object([category.itemID: .text("include")]),
            ],
            classID: "PersonalStateItem")
        _ = includedPersonal
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(category.itemID))]),
                ])
            ])
        let expected = try Categories.query(store: store, categoryPath: [category.itemID]).map(\.itemID)
        XCTAssertEqual(Set(expected), Set(matched.map(\.itemID) + [manual.itemID]))

        store.exactQueryCandidateLimitForTesting = 2
        let first = try Categories.page(
            store: store, expression: nil, text: nil, categoryPath: [category.itemID],
            excludedCategoryIDs: [], sort: [], position: 0, limit: 2, at: Date(),
            timeZone: "UTC", savedViewID: view.itemID)
        let second = try Categories.page(
            store: store, expression: nil, text: nil, categoryPath: [category.itemID],
            excludedCategoryIDs: [], sort: [], position: 2, limit: 8, at: Date(),
            timeZone: "UTC", savedViewID: view.itemID)
        XCTAssertEqual(first.total, expected.count)
        XCTAssertEqual(second.total, expected.count)
        XCTAssertEqual(first.ids + second.ids, expected)
        XCTAssertGreaterThan(store.lastIndexCandidateCountForTesting, expected.count)
        XCTAssertLessThan(store.lastIndexCandidateCountForTesting, matched.count + 6 + 2)
        XCTAssertTrue(try store.savedViewIndexIsReady(view.itemID))
        let base = try store.savedViewBaseIDsForTesting(id: view.itemID)
        XCTAssertTrue(Set(matched.map(\.itemID)).isSubset(of: base))
        XCTAssertTrue(base.contains(manual.itemID))
        XCTAssertFalse(base.contains(personalTarget.itemID))

        _ = try edit(store, matched[0], ["bucket": .integer(0)])
        store.exactQueryCandidateLimitForTesting = nil
        let afterEdit = try Categories.query(store: store, categoryPath: [category.itemID]).map(\.itemID)
        store.exactQueryCandidateLimitForTesting = 2
        let refreshed = try Categories.page(
            store: store, expression: nil, text: nil, categoryPath: [category.itemID],
            excludedCategoryIDs: [], sort: [], position: 0, limit: 20, at: Date(),
            timeZone: "UTC", savedViewID: view.itemID)
        XCTAssertEqual(refreshed.ids, afterEdit)
        XCTAssertEqual(refreshed.total, afterEdit.count)
        XCTAssertFalse(try store.savedViewBaseIDsForTesting(id: view.itemID).contains(matched[0].itemID))
    }

    func testExclusionsOnlyPageStreamsUnrestrictedExactCandidates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let category = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("bucket == 1"),
                ])
            ])
        _ = try (0..<4).map { _ in try create(store, ["bucket": .integer(1)]) }
        let included = try (0..<5).map { _ in try create(store, ["bucket": .integer(0)]) }
        let expected = try Categories.query(store: store, excludedCategoryIDs: [category.itemID])
            .map(\.itemID)
        XCTAssertEqual(Set(expected), Set(included.map(\.itemID) + [category.itemID]))

        store.exactQueryCandidateLimitForTesting = 1
        let page = try Categories.page(
            store: store, expression: nil, text: nil, categoryPath: [],
            excludedCategoryIDs: [category.itemID], sort: [], position: 0, limit: 20,
            at: Date(), timeZone: "UTC")
        XCTAssertEqual(page.ids, expected)
        XCTAssertEqual(page.total, expected.count)
        XCTAssertEqual(store.lastIndexCandidateCountForTesting, 10)
    }
}
