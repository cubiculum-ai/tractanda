import Foundation
import TractandaCore

/// One category's authorized, bounded review page. The server owns training and membership.
final class LearningWorkspace {
    enum Mode { case suggestions, examples }
    struct Row {
        let item: Revision
        let suggestion: CategorySuggestion?
    }
    static let pageSize = 32
    private let client: ItemClient
    let categoryID: String
    private(set) var category: Revision?
    private(set) var state: CategoryLearningState?
    private(set) var mode = Mode.suggestions
    private(set) var expression = ""
    private(set) var rows: [Row] = []
    private(set) var position = 0
    private(set) var total = 0
    var index = 0
    var firstVisibleIndex = 0
    var current: Row? { rows.indices.contains(index) ? rows[index] : nil }
    var hasNextPage: Bool { position + rows.count < total }
    var title: String { category?.fields["subject"]?.string ?? "Category unavailable" }

    init(client: ItemClient, categoryID: String) {
        self.client = client
        self.categoryID = categoryID
    }

    private struct GetResult: Decodable {
        let list: [Revision]
        let notFound: [String]
        let state: String
    }

    private func status() throws -> CategoryLearningState {
        try JSON.decode(
            CategoryLearningState.self,
            client.call("TractandaLearning/status", arguments: ["categoryID": categoryID]))
    }

    private func items(_ ids: [String], requiring state: String? = nil) throws -> [Revision] {
        let response = try JSON.decode(
            GetResult.self, client.call("TractandaItem/get", arguments: ["ids": ids]))
        guard response.notFound.isEmpty, response.list.count == ids.count,
            Set(response.list.map(\.itemID)) == Set(ids), Set(ids).count == ids.count,
            state == nil || response.state == state
        else { throw TractandaError("stateChanged", "Items changed or became unavailable. R refreshes.") }
        let byID = Dictionary(uniqueKeysWithValues: response.list.map { ($0.itemID, $0) })
        return ids.compactMap { byID[$0] }
    }

    func invalidate() {
        rows = []
        state = nil
        category = nil
        total = 0
        position = 0
        index = 0
    }

    func refresh(
        mode: Mode? = nil, expression: String? = nil, position: Int = 0, requiring token: String? = nil
    )
        throws
    {
        let nextMode = mode ?? self.mode
        let nextExpression = expression ?? self.expression
        let selected = current?.item.itemID
        do {
            let category = try client.revision(for: categoryID)
            let state: CategoryLearningState
            let loaded: [Row]
            let total: Int
            if nextMode == .suggestions {
                var arguments: [String: Any] = [
                    "categoryID": categoryID, "position": position, "limit": Self.pageSize,
                ]
                if !nextExpression.isEmpty { arguments["expression"] = nextExpression }
                if let token { arguments["ifInState"] = token }
                let result = try JSON.decode(
                    CategorySuggestions.self, client.call("TractandaLearning/suggest", arguments: arguments))
                state = result.learning
                guard result.position == position, result.list.count <= Self.pageSize,
                    result.total >= position + result.list.count,
                    result.list.allSatisfy({
                        $0.categoryID == categoryID && $0.categoryRevisionID == state.categoryRevisionID
                            && $0.modelID == state.modelID && $0.score.isFinite
                    })
                else { throw TractandaError("protocolError", "Invalid suggestion page.") }
                let revisions = try items(result.list.map(\.itemID))
                guard zip(revisions, result.list).allSatisfy({ $0.revisionID == $1.revisionID }) else {
                    throw TractandaError("stateChanged", "A suggested item changed. R refreshes.")
                }
                loaded = zip(revisions, result.list).map { Row(item: $0, suggestion: $1) }
                total = result.total
            } else {
                state = try status()
                if let token, token != state.queryState {
                    throw TractandaError("stateChanged", "Training examples changed. R refreshes.")
                }
                let filter =
                    "itemID != \"\(categoryID)\""
                    + (nextExpression.isEmpty ? "" : " && (\(nextExpression))")
                let page = try JSON.decode(
                    ItemPage.self,
                    client.call(
                        "TractandaItem/query",
                        arguments: [
                            "expression": filter, "position": position, "limit": Self.pageSize,
                        ]))
                guard page.position == position, page.ids.count <= Self.pageSize,
                    page.total >= position + page.ids.count
                else { throw TractandaError("protocolError", "Invalid example page.") }
                loaded = try items(page.ids, requiring: page.queryState).map {
                    Row(item: $0, suggestion: nil)
                }
                total = page.total
            }
            // Treat tokens as opaque. Recheck after hydration instead of parsing the store-state prefix.
            let final = try status()
            guard state.categoryID == categoryID, state.categoryRevisionID == category.revisionID,
                final.queryState == state.queryState,
                final.categoryRevisionID == state.categoryRevisionID, final.modelID == state.modelID,
                final.status == state.status
            else { throw TractandaError("stateChanged", "Learning changed while loading. R refreshes.") }
            self.category = category
            self.state = final
            self.mode = nextMode
            self.expression = nextExpression
            self.position = position
            self.total = total
            self.rows = loaded
            index = loaded.firstIndex { $0.item.itemID == selected } ?? min(index, max(0, loaded.count - 1))
        } catch {
            invalidate()
            throw error
        }
    }

    func loadPage(forward: Bool) throws {
        guard let state, forward ? hasNextPage : position > 0 else { return }
        try refresh(
            position: max(0, position + (forward ? Self.pageSize : -Self.pageSize)),
            requiring: state.queryState)
        index = 0
    }

    /// Check the displayed state before making a new decision; saved retries skip this preflight.
    func validateCurrent() throws -> Row {
        do {
            guard let row = current, let state else {
                throw TractandaError("selection", "Select an item first.")
            }
            let current = try client.revision(for: row.item.itemID)
            let latest = try status()
            guard current.revisionID == row.item.revisionID,
                latest.queryState == state.queryState, latest.categoryRevisionID == state.categoryRevisionID,
                row.suggestion == nil
                    || (latest.status == .ready && latest.modelID == row.suggestion?.modelID)
            else {
                throw TractandaError(
                    "stateChanged", "The item or learning state changed. R refreshes before feedback.")
            }
            if row.suggestion != nil {
                // Relative-time rules can change eligibility without changing a revision/state token.
                let eligible = try JSON.decode(
                    CategorySuggestions.self,
                    client.call(
                        "TractandaLearning/suggest",
                        arguments: [
                            "categoryID": categoryID, "expression": "itemID == \"\(current.itemID)\"",
                            "limit": 1, "ifInState": state.queryState,
                        ]))
                guard eligible.list.first?.revisionID == current.revisionID,
                    eligible.list.first?.modelID == row.suggestion?.modelID
                else {
                    throw TractandaError(
                        "stateChanged", "This suggestion is no longer available. R refreshes.")
                }
            }
            return row
        } catch {
            invalidate()
            throw error
        }
    }

    func feedback(_ action: LearningFeedbackAction) throws -> LearningEdit {
        let row = try validateCurrent()
        return .feedback(
            .init(
                categoryID: categoryID, itemID: row.item.itemID, expectedRevisionID: row.item.revisionID,
                operationID: Identifier.make(), action: action, modelID: row.suggestion?.modelID))
    }

    func train() throws {
        do {
            _ = try client.call("TractandaLearning/train", arguments: ["categoryID": categoryID])
            try refresh()
        } catch {
            invalidate()
            throw error
        }
    }

    func reset() throws {
        do {
            _ = try client.call("TractandaLearning/reset", arguments: ["categoryID": categoryID])
            try refresh()
        } catch {
            invalidate()
            throw error
        }
    }

    var explanation: String {
        guard let state else { return "Learning is unavailable. R refreshes; Esc returns." }
        switch state.status {
        case .off: return "Learning is off. Settings can enable suggestions."
        case .insufficientEvidence:
            return
                "Needs at least \(state.settings.minimumExamplesPerLabel) usable examples of each label. E opens teaching items."
        case .untrained: return "T trains from the current examples."
        case .staleModel: return "Examples or settings changed. T retrains before suggestions."
        case .invalidCache: return "The model cache cannot be used. T rebuilds it."
        case .noSignal: return "Examples do not separate this category yet. Teach more varied items."
        case .ready: return "Suggestions are ready. Scores rank similarity; they are not probabilities."
        }
    }
}
