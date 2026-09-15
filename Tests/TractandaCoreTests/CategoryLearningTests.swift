import XCTest

@testable import TractandaCore

final class CategoryLearningTests: XCTestCase {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-learning-\(Identifier.make())")
    }
    private func create(_ store: ItemStore, _ text: String, category: String? = nil, label: String? = nil)
        throws -> Revision
    {
        var fields: [String: ItemValue] = ["subject": .text(text)]
        if let category, let label { fields["categoryOverrides"] = .object([category: .text(label)]) }
        return try store.commit(
            CommitRequest(classID: "NoteItem", changes: fields, operationID: Identifier.make())
        ).revision
    }
    private func edit(_ store: ItemStore, _ item: Revision, _ fields: [String: ItemValue]) throws -> Revision
    {
        try store.commit(
            CommitRequest(
                action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                changes: fields, operationID: Identifier.make())
        ).revision
    }
    private func seed(_ store: ItemStore) throws -> (
        category: Revision, positives: [Revision], negatives: [Revision], candidate: Revision
    ) {
        let category = try store.commit(
            CommitRequest(
                classID: "NoteItem",
                changes: [
                    "subject": .text("Club"),
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile),
                        "expression": .text("subject == \"a rule that matches no sample\""),
                    ]),
                ], operationID: Identifier.make())
        ).revision
        let positives = try ["chess tournament players", "chess players board"].map {
            try create(store, $0, category: category.itemID, label: "include")
        }
        let negatives = try ["garden vegetables soil", "garden soil flowers"].map {
            try create(store, $0, category: category.itemID, label: "exclude")
        }
        return (category, positives, negatives, try create(store, "chess tournament board"))
    }

    func testCanonicalTrainingSuggestionsAndDisposableCache() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let data = try seed(store!)
        var learner: CategoryLearning? = CategoryLearning(store: store!)
        let before = store!.state
        XCTAssertEqual(try learner!.status(for: data.category.itemID).status, .untrained)
        XCTAssertEqual(try learner!.suggestions(categoryID: data.category.itemID).list.count, 0)
        let trained = try learner!.train(categoryID: data.category.itemID)
        XCTAssertEqual(trained.status, .ready)
        XCTAssertEqual(trained.positiveExamples, 2)
        XCTAssertEqual(trained.negativeExamples, 2)
        XCTAssertEqual(trained.unknownItems, 1)
        XCTAssertEqual(store!.state, before, "Training must not revise canonical items")
        XCTAssertEqual(try learner!.train(categoryID: data.category.itemID).modelID, trained.modelID)
        let suggestions = try learner!.suggestions(categoryID: data.category.itemID)
        XCTAssertEqual(suggestions.list.map(\.itemID), [data.candidate.itemID])
        XCTAssertEqual(suggestions.list.first?.revisionID, data.candidate.revisionID)
        XCTAssertEqual(suggestions.list.first?.modelID, trained.modelID)
        XCTAssertGreaterThan(suggestions.list.first!.score, 0.1)
        XCTAssertEqual(
            try learner!.categories(for: data.candidate.itemID).list.first?.categoryID, data.category.itemID)
        XCTAssertEqual(
            try learner!.suggestions(categoryID: data.category.itemID, expression: "subject == \"absent\"")
                .total, 0)
        XCTAssertEqual(
            try learner!.suggestions(categoryID: data.category.itemID, position: 1, limit: 1).list.count, 0)
        XCTAssertEqual(try store!.get(data.category.itemID), data.category)
        XCTAssertNil(try store!.get(data.candidate.itemID).fields["categoryOverrides"])

        learner = nil
        store = nil
        store = try ItemStore(root: root)
        learner = CategoryLearning(store: store!)
        XCTAssertEqual(
            try learner!.status(for: data.category.itemID).modelID, trained.modelID,
            "Cache reopens against canonical revisions")
        _ = try learner!.reset(categoryID: data.category.itemID)
        XCTAssertEqual(try learner!.status(for: data.category.itemID).status, .untrained)
        XCTAssertEqual(try store!.get(data.positives[0].itemID), data.positives[0])
        XCTAssertNotEqual(try learner!.train(categoryID: data.category.itemID).modelID, trained.modelID)
        learner = nil
        store = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
        store = try ItemStore(root: root)
        learner = CategoryLearning(store: store!)
        XCTAssertEqual(try learner!.train(categoryID: data.category.itemID).status, .ready)
        XCTAssertEqual(
            try learner!.suggestions(categoryID: data.category.itemID).list.map(\.itemID),
            [data.candidate.itemID])
    }

    func testContentAssignmentDeletionAndRuleChangesInvalidateModels() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let data = try seed(store)
        let learner = CategoryLearning(store: store)
        let first = try learner.train(categoryID: data.category.itemID)
        let source = try edit(store, data.positives[0], ["body": .text("club chess")])
        XCTAssertEqual(try learner.status(for: data.category.itemID).status, .staleModel)
        XCTAssertTrue(try learner.suggestions(categoryID: data.category.itemID).list.isEmpty)
        XCTAssertNotEqual(try learner.train(categoryID: data.category.itemID).modelID, first.modelID)
        _ = try edit(store, source, ["isDeleted": .boolean(true)])
        XCTAssertEqual(try learner.status(for: data.category.itemID).status, .insufficientEvidence)
        var settings = CategoryLearningSettings()
        settings.minimumExamplesPerLabel = 1
        settings.usesRuleMatches = true
        let category = try edit(
            store, data.category,
            [
                "learningSettings": settings.itemValue,
                "selection": .object([
                    "language": .text(SpotlightQuery.profile),
                    "expression": .text("subject == \"chess tournament board\""),
                ]),
            ])
        XCTAssertEqual(try learner.train(categoryID: category.itemID).positiveExamples, 2)
        XCTAssertFalse(
            try learner.suggestions(categoryID: category.itemID).list.contains {
                $0.itemID == data.candidate.itemID
            })
        let excluded = try edit(
            store, data.candidate, ["categoryOverrides": .object([category.itemID: .text("exclude")])])
        let changed = try learner.train(categoryID: category.itemID)
        XCTAssertEqual(changed.positiveExamples, 1)
        XCTAssertEqual(changed.negativeExamples, 3, "Manual exclusion wins over a matching selection rule")
        XCTAssertEqual(try store.get(excluded.itemID).revisionID, excluded.revisionID)
    }

    func testFeedbackDistinguishesAcceptanceNegativeDismissalAndManualAuthority() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let data = try seed(store)
        let learner = CategoryLearning(store: store)
        let model = try learner.train(categoryID: data.category.itemID)
        func feedback(_ item: Revision, _ action: LearningFeedbackAction, _ operation: String) throws
            -> CommitResult
        {
            try learner.recordFeedback(
                itemID: item.itemID, categoryID: data.category.itemID,
                expectedRevisionID: item.revisionID, action: action, operationID: operation,
                modelID: model.modelID, actorUID: store.ownerUID)
        }
        let dismissed = try feedback(data.candidate, .dismiss, "dismiss").revision
        XCTAssertNil(dismissed.fields["categoryOverrides"])
        XCTAssertEqual(try learner.status(for: data.category.itemID).modelID, model.modelID)
        XCTAssertEqual(try learner.suggestions(categoryID: data.category.itemID).list.count, 0)
        let negative = try feedback(dismissed, .negative, "negative").revision
        XCTAssertNil(negative.fields["categoryOverrides"])
        XCTAssertEqual(try learner.train(categoryID: data.category.itemID).negativeExamples, 3)
        let cleared = try feedback(negative, .clear, "clear").revision
        XCTAssertEqual(try learner.train(categoryID: data.category.itemID).negativeExamples, 2)
        XCTAssertEqual(
            try learner.suggestions(categoryID: data.category.itemID).list.map(\.itemID), [cleared.itemID])
        let accepted = try feedback(cleared, .accept, "accept").revision
        XCTAssertEqual(accepted.fields["categoryOverrides"]?.map?[data.category.itemID], .text("include"))
        XCTAssertTrue(try Categories.explain(accepted, category: data.category).isIncluded)
        let count = try store.history(accepted.itemID).count
        _ = try learner.reset(categoryID: data.category.itemID)
        XCTAssertTrue(try feedback(cleared, .accept, "accept").wasReplayed)
        XCTAssertEqual(try store.history(accepted.itemID).count, count)
        XCTAssertThrowsError(try feedback(cleared, .exclude, "accept")) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "operationMismatch")
        }
        let contradictory = try feedback(accepted, .negative, "negative-after-include").revision
        XCTAssertEqual(
            try learner.train(categoryID: data.category.itemID).positiveExamples, 3,
            "Manual assignment retains authority")
        let excluded = try feedback(contradictory, .exclude, "exclude").revision
        XCTAssertFalse(try Categories.explain(excluded, category: data.category).isIncluded)
        let deletedCategory = try edit(store, data.category, ["isDeleted": .boolean(true)])
        XCTAssertTrue(
            try feedback(contradictory, .exclude, "exclude").wasReplayed,
            "Category deletion must not prevent receipt replay")
        XCTAssertTrue(deletedCategory.isDeleted)
    }

    func testFeedbackExpiresOnContentChangeAndCanonicalStateSurvivesModelReset() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let data = try seed(store)
        let learner = CategoryLearning(store: store)
        let negative = try learner.recordFeedback(
            itemID: data.candidate.itemID, categoryID: data.category.itemID,
            expectedRevisionID: data.candidate.revisionID, action: .negative, operationID: "negative",
            actorUID: store.ownerUID
        ).revision
        XCTAssertEqual(try learner.train(categoryID: data.category.itemID).negativeExamples, 3)
        let metadataEdit = try edit(store, negative, ["priority": .integer(1)])
        XCTAssertEqual(try learner.train(categoryID: data.category.itemID).negativeExamples, 3)
        let contentEdit = try edit(store, metadataEdit, ["body": .text("new chess tournament")])
        XCTAssertEqual(try learner.train(categoryID: data.category.itemID).negativeExamples, 2)
        XCTAssertTrue(
            try learner.suggestions(categoryID: data.category.itemID).list.contains {
                $0.itemID == contentEdit.itemID
            })
        _ = try learner.reset(categoryID: data.category.itemID)
        XCTAssertEqual(
            try store.get(contentEdit.itemID).fields["learningFeedback"], negative.fields["learningFeedback"])
        XCTAssertEqual(try learner.train(categoryID: data.category.itemID).negativeExamples, 2)
    }

    func testEmptyEvidenceLimitsCacheCorruptionAndSettingsValidation() throws {
        let root = temporaryRoot()
        let externalIndex = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tractanda-learning-index-\(Identifier.make())")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalIndex)
        }
        let store = try ItemStore(root: root, indexDirectory: externalIndex)
        let data = try seed(store)
        let learner = CategoryLearning(store: store)
        let blank = try create(store, "", category: data.category.itemID, label: "include")
        XCTAssertEqual(try learner.train(categoryID: data.category.itemID).emptyExamples, 1)
        let url = externalIndex.appendingPathComponent("learning/\(data.category.itemID).json")
        try Data("broken cache".utf8).write(to: url)
        let reopened = CategoryLearning(store: store)
        XCTAssertEqual(try reopened.status(for: data.category.itemID).status, .invalidCache)
        XCTAssertEqual(try reopened.train(categoryID: data.category.itemID).status, .ready)
        var settings = CategoryLearningSettings()
        settings.minimumExamplesPerLabel = 1
        settings.maximumExamplesPerLabel = 1
        var category = try edit(store, data.category, ["learningSettings": settings.itemValue])
        let limited = try learner.train(categoryID: category.itemID)
        XCTAssertEqual(limited.positiveExamples, 1)
        XCTAssertEqual(limited.negativeExamples, 1)
        XCTAssertEqual(limited.omittedExamples, 2)
        settings.mode = .off
        category = try edit(store, category, ["learningSettings": settings.itemValue])
        XCTAssertEqual(try learner.train(categoryID: category.itemID).status, .off)
        XCTAssertEqual(try learner.suggestions(categoryID: category.itemID).list.count, 0)
        let before = store.state
        XCTAssertThrowsError(
            try edit(store, category, ["learningSettings": .object(["profile": .text("future")])]))
        XCTAssertThrowsError(try edit(store, blank, ["learningFeedback": .text("invalid")]))
        XCTAssertEqual(store.state, before)
        XCTAssertThrowsError(try learner.suggestions(categoryID: category.itemID, limit: 0))
        XCTAssertThrowsError(
            try learner.categories(
                for: data.candidate.itemID, categoryIDs: [category.itemID, category.itemID]))
    }

    func testVersionedUnicodeTokenizationAndBounds() {
        XCTAssertEqual(
            LearningText.tokens(in: "Frédéric CHESS\n123 café ＡＢＣ"),
            ["frederic", "chess", "__number__", "cafe", "abc"])
        XCTAssertEqual(LearningText.tokens(in: "Ärger über Straße"), ["arger", "uber", "strasse"])
        XCTAssertEqual(LearningText.tokens(in: String(repeating: "x", count: 100) + " valid"), ["valid"])
        XCTAssertEqual(LearningText.tokens(in: String(repeating: "word ", count: 5000)).count, 4096)
    }

    func testFeedbackReferencesAndCopiedIdentity() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let data = try seed(store)
        let learner = CategoryLearning(store: store)
        let accepted = try learner.recordFeedback(
            itemID: data.candidate.itemID, categoryID: data.category.itemID,
            expectedRevisionID: data.candidate.revisionID, action: .accept, operationID: "accept",
            actorUID: store.ownerUID
        ).revision
        let copy = try store.commit(
            CommitRequest(
                action: .copy, itemID: accepted.itemID,
                expectedRevisionID: accepted.revisionID, operationID: "copy")
        ).revision
        XCTAssertNil(copy.fields["learningFeedback"])
        XCTAssertEqual(copy.fields["categoryOverrides"], accepted.fields["categoryOverrides"])
        XCTAssertThrowsError(
            try edit(store, copy, ["learningFeedback": accepted.fields["learningFeedback"]!])
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidLearningFeedback")
        }
        try store.rebuildIndex()
        XCTAssertEqual(try learner.train(categoryID: data.category.itemID).positiveExamples, 4)
    }
}
