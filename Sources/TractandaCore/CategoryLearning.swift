import Foundation
import TractandaLearning

public struct CategoryLearningState: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case off, insufficientEvidence, untrained, staleModel, invalidCache, noSignal, ready
    }
    public let categoryID: String
    public let categoryRevisionID: String
    public let settings: CategoryLearningSettings
    public let tokenizerProfile: String
    public let modelProfile: String
    public let status: Status
    public let modelID: String?
    public let trainedAt: String?
    public let positiveExamples: Int
    public let negativeExamples: Int
    public let omittedExamples: Int
    public let unknownItems: Int
    public let emptyExamples: Int
    public let vocabularySize: Int?
    public let retainedDimensions: Int?
    public let queryState: String
}

public struct CategorySuggestion: Codable, Sendable {
    public let itemID: String
    public let revisionID: String
    public let categoryID: String
    public let categoryRevisionID: String
    public let modelID: String
    public let modelProfile: String
    public let tokenizerProfile: String
    public let score: Double
    public let matchedTokens: Int
    public let totalTokens: Int
}

public struct CategorySuggestions: Codable, Sendable {
    public let learning: CategoryLearningState
    public let list: [CategorySuggestion]
    public let position: Int
    public let total: Int
    public let unavailableItems: Int
}

public struct SuggestedCategories: Codable, Sendable {
    public let itemID: String
    public let revisionID: String
    public let list: [CategorySuggestion]
    public let learning: [CategoryLearningState]
    public let position: Int
    public let totalCategories: Int
    public let queryState: String
}

/// Shares ItemStore's synchronous executor and captures one authenticated user's scope.
/// Each category owns an independent derived model; no prediction becomes training or membership.
public final class CategoryLearning {
    private let store: ItemStore
    private let scope: String
    private var memory: [String: LoadedModel] = [:]
    private let cacheProfile = "tractanda.category-cache.v1"
    private var generation = Identifier.make()
    public var queryState: String { store.state + "." + generation }

    private struct Source: Codable, Equatable {
        let itemID: String
        let revisionID: String
        let isPositive: Bool
        let origin: String
    }
    private struct Input {
        let category: Revision
        let settings: CategoryLearningSettings
        let sources: [Source]
        let examples: [LSMExample]
        let positives: Int
        let negatives: Int
        let omitted: Int
        let unknown: Int
        let empty: Int
    }
    private struct Cache: Codable {
        let profile: String
        let tokenizerProfile: String
        let modelProfile: String
        let categoryRevisionID: String
        let settings: CategoryLearningSettings
        let sources: [Source]
        let modelID: String
        let trainedAt: String
        let recipe: Data
    }
    private struct LoadedModel {
        let cache: Cache
        let model: LSMModel?
    }

    public init(store: ItemStore) {
        self.store = store
        scope = store.accessScope
    }

    private func category(_ id: String) throws -> Revision {
        guard store.accessScope == scope else {
            throw TractandaError("forbidden", "Learning models cannot be reused across account scopes.")
        }
        let item = try store.get(id)
        _ = try Categories.rule(item)
        return item
    }

    /// Feedback follows the referenced content until subject/body change. Missing history is an error.
    private func feedback(on item: Revision, categoryID: String) throws -> LearningFeedback? {
        guard let value = item.fields["learningFeedback"]?.map?[categoryID] else { return nil }
        let feedback = try LearningFeedback(value)
        let base = try store.get(item.itemID, revisionID: feedback.revisionID)
        guard base.fields["subject"] == item.fields["subject"], base.fields["body"] == item.fields["body"]
        else {
            return nil
        }
        return feedback
    }

    private func input(for id: String, at date: Date) throws -> Input {
        let category = try category(id)
        let settings = try CategoryLearningSettings(category.fields["learningSettings"])
        let rule = try Categories.rule(category)
        var sources: [Source] = []
        var examples: [LSMExample] = []
        var positives = 0
        var negatives = 0
        var omitted = 0
        var unknown = 0
        var empty = 0
        for item in try store.candidates().sorted(by: { $0.itemID < $1.itemID }) where item.itemID != id {
            let manual = try store.categoryOverride(for: item, categoryID: id)
            var label: Bool?
            var origin = "manual"
            if let manual {
                label = manual.decision == "include"
                origin = manual.origin
            } else if try feedback(on: item, categoryID: id)?.action == .negative {
                label = false
                origin = "feedback"
            } else if settings.usesRuleMatches && rule.matches(item, at: date) {
                label = true
                origin = "rule"
            }
            guard let label else {
                unknown += 1
                continue
            }
            let tokens = LearningText.tokens(in: item)
            guard !tokens.isEmpty else {
                empty += 1
                continue
            }
            guard (label ? positives : negatives) < settings.maximumExamplesPerLabel else {
                omitted += 1
                continue
            }
            if label { positives += 1 } else { negatives += 1 }
            sources.append(
                Source(itemID: item.itemID, revisionID: item.revisionID, isPositive: label, origin: origin))
            examples.append(LSMExample(id: item.itemID, tokens: tokens, isPositive: label))
        }
        return Input(
            category: category, settings: settings, sources: sources, examples: examples,
            positives: positives, negatives: negatives, omitted: omitted, unknown: unknown, empty: empty)
    }

    private func cacheURL(_ id: String) throws -> URL {
        try Identifier.validate(id)
        let folder =
            scope == "single-user"
            ? "learning"
            : "learning/scopes/" + scope.utf8.map { String(format: "%02x", $0) }.joined()
        return store.indexDirectory.appendingPathComponent("\(folder)/\(id).json")
    }

    private func matches(_ cache: Cache, _ input: Input) -> Bool {
        cache.profile == cacheProfile && cache.tokenizerProfile == LearningText.profile
            && cache.modelProfile == LSMModel.profile && cache.categoryRevisionID == input.category.revisionID
            && cache.settings == input.settings && cache.sources == input.sources
    }

    private func makeMap(_ input: Input) throws -> BinaryLSM {
        let map = try BinaryLSM(configuration: input.settings.configuration)
        for example in input.examples { try map.setExample(example) }
        return map
    }

    private func compile(_ map: BinaryLSM) throws -> LSMModel? {
        do { return try map.compile() } catch LSMError.noSignal { return nil }
    }

    private func remember(_ loaded: LoadedModel, for id: String) {
        // Bounded memoization. Disk recipes remain disposable and independently addressable.
        if memory[id] == nil && memory.count >= 8, let first = memory.keys.sorted().first {
            memory.removeValue(forKey: first)
        }
        memory[id] = loaded
    }

    private func load(_ input: Input) throws -> (CategoryLearningState.Status, LoadedModel?) {
        if input.settings.mode == .off { return (.off, nil) }
        if min(input.positives, input.negatives) < input.settings.minimumExamplesPerLabel {
            return (.insufficientEvidence, nil)
        }
        let id = input.category.itemID
        let url = try cacheURL(id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            memory.removeValue(forKey: id)
            return (.untrained, nil)
        }
        if let saved = memory[id] {
            guard matches(saved.cache, input) else { return (.staleModel, nil) }
            return (saved.model == nil ? .noSignal : .ready, saved)
        }
        do {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 96 * 1024 * 1024
            else {
                return (.invalidCache, nil)
            }
            let cache = try JSON.decode(Cache.self, Data(contentsOf: url))
            try Identifier.validate(cache.modelID)
            guard Timestamp.parse(cache.trainedAt) != nil else { return (.invalidCache, nil) }
            guard matches(cache, input) else { return (.staleModel, nil) }
            // The canonical source revisions determine the recipe, even if cache bytes are corrupted.
            let expected = try makeMap(input)
            guard cache.recipe == (try expected.encodedCache()) else { return (.invalidCache, nil) }
            let saved = LoadedModel(cache: cache, model: try compile(expected))
            remember(saved, for: id)
            return (saved.model == nil ? .noSignal : .ready, saved)
        } catch {
            return (.invalidCache, nil)
        }
    }

    private func state(_ input: Input, status: CategoryLearningState.Status, saved: LoadedModel?)
        -> CategoryLearningState
    {
        CategoryLearningState(
            categoryID: input.category.itemID, categoryRevisionID: input.category.revisionID,
            settings: input.settings, tokenizerProfile: LearningText.profile, modelProfile: LSMModel.profile,
            status: status, modelID: saved?.cache.modelID, trainedAt: saved?.cache.trainedAt,
            positiveExamples: input.positives, negativeExamples: input.negatives,
            omittedExamples: input.omitted,
            unknownItems: input.unknown, emptyExamples: input.empty,
            vocabularySize: saved?.model?.vocabulary.count,
            retainedDimensions: saved?.model?.singularValues.count, queryState: queryState)
    }

    public func status(for categoryID: String, at date: Date = Date()) throws -> CategoryLearningState {
        let input = try input(for: categoryID, at: date)
        let (status, saved) = try load(input)
        return state(input, status: status, saved: saved)
    }

    /// Explicit training never commits an item. Identical inputs reuse the existing model identity.
    public func train(categoryID: String, at date: Date = Date()) throws -> CategoryLearningState {
        let input = try input(for: categoryID, at: date)
        let (status, previous) = try load(input)
        if [.off, .insufficientEvidence, .ready, .noSignal].contains(status) {
            return state(input, status: status, saved: previous)
        }
        let map = try makeMap(input)
        let model = try compile(map)
        let cache = Cache(
            profile: cacheProfile, tokenizerProfile: LearningText.profile, modelProfile: LSMModel.profile,
            categoryRevisionID: input.category.revisionID, settings: input.settings, sources: input.sources,
            modelID: Identifier.make(), trainedAt: Timestamp.now(), recipe: try map.encodedCache())
        let url = try cacheURL(categoryID)
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSON.encode(cache).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        generation = Identifier.make()
        let saved = LoadedModel(cache: cache, model: model)
        remember(saved, for: categoryID)
        return state(input, status: model == nil ? .noSignal : .ready, saved: saved)
    }

    /// Reset discards only this category's derived model, preserving assignments, feedback and settings.
    public func reset(categoryID: String) throws -> CategoryLearningState {
        _ = try category(categoryID)
        let url = try cacheURL(categoryID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            generation = Identifier.make()
        }
        memory.removeValue(forKey: categoryID)
        return try status(for: categoryID)
    }

    private func suggestion(for item: Revision, input: Input, saved: LoadedModel, at date: Date) throws
        -> (CategorySuggestion?, Bool)
    {
        guard !item.isDeleted, item.itemID != input.category.itemID,
            try store.categoryOverride(for: item, categoryID: input.category.itemID) == nil,
            !(try Categories.rule(input.category)).matches(item, at: date)
        else { return (nil, false) }
        if let feedback = try feedback(on: item, categoryID: input.category.itemID) {
            if feedback.action == .negative || feedback.action == .dismiss { return (nil, false) }
        }
        guard let model = saved.model else { return (nil, true) }
        let prediction = try model.predict(tokens: LearningText.tokens(in: item))
        guard let score = prediction.score else { return (nil, true) }
        guard score > input.settings.threshold else { return (nil, false) }
        return (
            CategorySuggestion(
                itemID: item.itemID, revisionID: item.revisionID,
                categoryID: input.category.itemID, categoryRevisionID: input.category.revisionID,
                modelID: saved.cache.modelID, modelProfile: LSMModel.profile,
                tokenizerProfile: LearningText.profile,
                score: score, matchedTokens: prediction.matchedTokens, totalTokens: prediction.totalTokens),
            false
        )
    }

    public func suggestions(
        categoryID: String, expression: String? = nil, position: Int = 0, limit: Int = 100,
        at date: Date = Date()
    ) throws -> CategorySuggestions {
        try validatePage(position, limit)
        let filter = try expression.map(SpotlightQuery.init)
        let input = try input(for: categoryID, at: date)
        let (status, saved) = try load(input)
        var list: [CategorySuggestion] = []
        var unavailable = 0
        if status == .ready, let saved {
            for item in try store.candidates() where filter?.matches(item, at: date) != false {
                let (suggestion, isUnavailable) = try suggestion(
                    for: item, input: input, saved: saved, at: date)
                if let suggestion { list.append(suggestion) }
                if isUnavailable { unavailable += 1 }
            }
        }
        list.sort { $0.score == $1.score ? $0.itemID < $1.itemID : $0.score > $1.score }
        return CategorySuggestions(
            learning: state(input, status: status, saved: saved),
            list: Array(list.dropFirst(position).prefix(limit)), position: position,
            total: list.count, unavailableItems: unavailable)
    }

    /// Pagination scans categories by stable ID; each page includes unavailable model states as well.
    public func categories(
        for itemID: String, categoryIDs: [String]? = nil, position: Int = 0, limit: Int = 100,
        at date: Date = Date()
    ) throws -> SuggestedCategories {
        try validatePage(position, limit)
        let item = try store.get(itemID)
        guard !item.isDeleted else {
            throw TractandaError("itemDeleted", "Cannot suggest categories for a deleted item.")
        }
        let ids: [String]
        if let categoryIDs {
            guard categoryIDs.count <= 256, Set(categoryIDs).count == categoryIDs.count else {
                throw TractandaError("invalidArguments", "Supply at most 256 distinct category IDs.")
            }
            ids = categoryIDs.sorted()
        } else {
            ids = try store.candidates().filter { $0.fields["selection"] != nil }.map(\.itemID).sorted()
        }
        var states: [CategoryLearningState] = []
        var list: [CategorySuggestion] = []
        for id in ids.dropFirst(position).prefix(limit) {
            let input = try input(for: id, at: date)
            let (status, saved) = try load(input)
            states.append(state(input, status: status, saved: saved))
            if status == .ready, let saved,
                let suggestion = try suggestion(for: item, input: input, saved: saved, at: date).0
            {
                list.append(suggestion)
            }
        }
        list.sort { $0.score == $1.score ? $0.categoryID < $1.categoryID : $0.score > $1.score }
        return SuggestedCategories(
            itemID: itemID, revisionID: item.revisionID, list: list, learning: states,
            position: position, totalCategories: ids.count, queryState: queryState)
    }

    private func validatePage(_ position: Int, _ limit: Int) throws {
        guard position >= 0, (1...256).contains(limit) else {
            throw TractandaError(
                "invalidArguments", "Use a nonnegative position and limit from 1 through 256.")
        }
    }

    public func setSettings(
        categoryID: String, expectedRevisionID: String, operationID: String,
        settings: ItemValue, actorUID: UInt32
    ) throws -> CommitResult {
        let value = try CategoryLearningSettings(settings)
        let base = try store.get(categoryID, revisionID: expectedRevisionID)
        _ = try Categories.rule(base)
        return try store.commit(
            CommitRequest(
                action: .revise, itemID: categoryID,
                expectedRevisionID: expectedRevisionID, changes: ["learningSettings": value.itemValue],
                operationID: operationID), actorUID: actorUID)
    }

    /// Build the edit from the immutable base so a lost-response retry has identical canonical intent.
    public func recordFeedback(
        itemID: String, categoryID: String, expectedRevisionID: String,
        action: LearningFeedbackAction, operationID: String, modelID: String? = nil,
        actorUID: UInt32
    ) throws -> CommitResult {
        try Identifier.validate(categoryID)
        if let modelID { try Identifier.validate(modelID) }
        let base = try store.get(itemID, revisionID: expectedRevisionID)
        guard !base.isDeleted else {
            throw TractandaError("itemDeleted", "Restore an item before giving feedback.")
        }
        if !store.hasCommittedOperation(operationID, actorUID: actorUID) { _ = try category(categoryID) }
        var feedback = base.fields["learningFeedback"]?.map ?? [:]
        if action == .clear {
            feedback.removeValue(forKey: categoryID)
        } else {
            var entry: [String: ItemValue] = [
                "action": .text(action.rawValue), "revisionID": .text(expectedRevisionID),
            ]
            if let modelID { entry["modelID"] = .text(modelID) }
            feedback[categoryID] = .object(entry)
        }
        var changes: [String: ItemValue] = ["learningFeedback": .object(feedback)]
        if action == .accept || action == .exclude {
            var overrides = base.fields["categoryOverrides"]?.map ?? [:]
            overrides[categoryID] = .text(action == .accept ? "include" : "exclude")
            changes["categoryOverrides"] = .object(overrides)
        }
        return try store.commit(
            CommitRequest(
                action: .revise, itemID: itemID,
                expectedRevisionID: expectedRevisionID, changes: changes, operationID: operationID),
            actorUID: actorUID)
    }
}
