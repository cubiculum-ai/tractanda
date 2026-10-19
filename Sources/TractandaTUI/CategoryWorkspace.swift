import Foundation
import Synchronization
import TractandaClient
import TractandaCore

/// Private presentation state for the category navigator.  The report `Workspace` never owns
/// this state, which keeps inspection from changing filters or navigation history.
struct CategoryWorkspace {
    enum RightMode: String, Codable, Sendable { case items, category }
    enum Focus: Sendable { case navigator, right }

    var rightMode: RightMode = .items
    var focus: Focus = .navigator
    var selectedAllItems = true
    var splitWidth = 0.333
    var connectedTree = false
    var preview = CategoryPreviewState()
    var previewIndex = 0
    var previewFirstVisible = 0
    /// nil follows the text caret; an explicit offset is set only by wheel scrolling.
    var inspectorScroll: Int?
    var isMaximized = false
    var inspector: CategoryInspectorDraft?

    init(preferences: ViewWorkspacePreferences) {
        rightMode = RightMode(rawValue: preferences.categoryRightMode) ?? .items
        splitWidth = preferences.categorySplitWidth
        connectedTree = preferences.categoryConnectedTree
    }

    var selectedPath: [Revision] { selectedAllItems ? [] : preview.path }
    var hasDirtyInspector: Bool { inspector?.isDirty == true }
}

/// A single native query/get page.  It deliberately does not call `ItemClient.revisions`, whose
/// convenience API follows every page and would make a preview unexpectedly expensive.
struct CategoryPreviewPage: Sendable {
    let rows: [Revision]
    let position: Int
    let total: Int
    let queryState: String
    let consumedCount: Int
    let unresolvedCount: Int
    let unhydratedCount: Int
    let incomplete: Bool
    let conflictsAvailable: Bool

    static func load(
        using client: TractandaCore.ItemClient, path: [String], position: Int, sort: [ItemSort]
    ) throws -> CategoryPreviewPage {
        struct QueryResult: Decodable {
            let ids: [String]
            let total: Int
            let queryState: String
            let completeness: String?
            let conflictsAvailable: Bool?
        }
        struct GetResult: Decodable {
            let list: [Revision]
            let notFound: [String]
            let unresolved: [ItemUnresolvedState]?
            let remainingIDs: [String]?
            let oversizedIDs: [String]?
            let state: String
        }
        let sortValue = try JSONSerialization.jsonObject(with: JSON.encode(sort))
        let page = try JSON.decode(
            QueryResult.self,
            client.call(
                "TractandaItem/query",
                arguments: [
                    "categoryPath": path, "position": position, "limit": 64, "sort": sortValue,
                    "at": Timestamp.now(),
                ]))
        guard !page.ids.isEmpty || position >= page.total else {
            throw TractandaError("protocolError", "Empty non-final category preview page.")
        }
        guard !page.ids.isEmpty else {
            return CategoryPreviewPage(
                rows: [], position: position, total: page.total, queryState: page.queryState,
                consumedCount: 0, unresolvedCount: 0, unhydratedCount: 0,
                incomplete: page.completeness == "unresolvedItems",
                conflictsAvailable: page.conflictsAvailable ?? false)
        }
        let got = try JSON.decode(
            GetResult.self, client.call("TractandaItem/get", arguments: ["ids": page.ids]))
        guard got.notFound.isEmpty, got.state == page.queryState else {
            throw TractandaError("stateChanged", "Refresh the changing board.")
        }
        let unresolved = got.unresolved ?? []
        let classifiedIDs =
            got.list.map(\.itemID) + unresolved.map(\.itemID)
            + (got.remainingIDs ?? []) + (got.oversizedIDs ?? [])
        guard Set(classifiedIDs).count == classifiedIDs.count, Set(classifiedIDs) == Set(page.ids) else {
            throw TractandaError("protocolError", "Category preview omitted or repeated query IDs.")
        }
        return CategoryPreviewPage(
            rows: got.list, position: position, total: page.total, queryState: page.queryState,
            consumedCount: page.ids.count, unresolvedCount: unresolved.count,
            unhydratedCount: (got.remainingIDs ?? []).count + (got.oversizedIDs ?? []).count,
            incomplete: page.completeness == "unresolvedItems" || !unresolved.isEmpty
                || !(got.remainingIDs ?? []).isEmpty || !(got.oversizedIDs ?? []).isEmpty,
            conflictsAvailable: page.conflictsAvailable ?? !unresolved.isEmpty)
    }
}

/// The live TUI path uses the typed asynchronous client.  Its mailbox is a narrowly scoped
/// mutex-protected value (rather than making the UI or its synchronous ItemClient Sendable).
struct CategoryPreviewLoader: Sendable {
    enum Outcome: Sendable {
        case success(CategoryPreviewPage)
        case failure(String)
    }
    private struct Delivered: Sendable {
        let generation: Int
        let result: Outcome
    }
    private struct Request: Sendable {
        let path: [String]
        let position: Int
        let sort: [ItemSort]
        let generation: Int
    }
    private struct State: Sendable {
        var pending: Request?
        var delivered: Delivered?
        var isRunning = false
    }
    /// A checked mutex retains only the newest request/result.  Selection changes coalesce while
    /// a socket read is in flight, and a late earlier generation cannot replace a newer delivery.
    private final class Mailbox: Sendable {
        private let state = Mutex(State())
        func enqueue(_ request: Request) -> Bool {
            state.withLock { state in
                state.pending = request
                guard !state.isRunning else { return false }
                state.isRunning = true
                return true
            }
        }
        func next() -> Request? {
            state.withLock { state in
                guard let request = state.pending else {
                    state.isRunning = false
                    return nil
                }
                state.pending = nil
                return request
            }
        }
        func publish(_ delivery: Delivered) {
            state.withLock { state in
                if let pending = state.pending, pending.generation > delivery.generation { return }
                if let prior = state.delivered, prior.generation > delivery.generation { return }
                state.delivered = delivery
            }
        }
        func take() -> Delivered? {
            state.withLock { state in
                defer { state.delivered = nil }
                return state.delivered
            }
        }
        func hasValue() -> Bool { state.withLock { $0.delivered != nil } }
    }
    private let mailbox = Mailbox()
    private let client: TractandaClient.ItemClient

    init(connection: ServerConnection) {
        client = TractandaClient.ItemClient(transport: LocalItemTransport(connection: connection))
    }

    func request(path: [String], position: Int, sort: [ItemSort], generation: Int) {
        let request = Request(path: path, position: position, sort: sort, generation: generation)
        guard mailbox.enqueue(request) else { return }
        let client = client
        let mailbox = mailbox
        Task.detached(priority: .userInitiated) {
            while let request = mailbox.next() {
                do {
                    let page = try await client.page(
                        matching: ItemQuery(
                            categoryPath: request.path, position: request.position, limit: 64,
                            sort: request.sort))
                    mailbox.publish(
                        Delivered(
                            generation: request.generation,
                            result: .success(
                                CategoryPreviewPage(
                                    rows: page.items, position: page.position, total: page.total,
                                    queryState: page.state, consumedCount: page.consumedCount,
                                    unresolvedCount: page.unresolved.count,
                                    unhydratedCount: page.remainingIDs.count + page.oversizedIDs.count,
                                    incomplete: page.completeness == .unresolvedItems
                                        || !page.remainingIDs.isEmpty || !page.oversizedIDs.isEmpty,
                                    conflictsAvailable: page.conflictsAvailable))))
                } catch {
                    mailbox.publish(
                        Delivered(generation: request.generation, result: .failure(String(describing: error)))
                    )
                }
            }
        }
    }

    func take() -> (generation: Int, result: Outcome)? {
        mailbox.take().map { ($0.generation, $0.result) }
    }

    func hasDelivery() -> Bool { mailbox.hasValue() }
}

struct CategoryPreviewState {
    enum Status: Equatable {
        case idle, loading, loaded
        case failed(String)
    }
    var path: [Revision] = []
    var rows: [Revision] = []
    var position = 0
    var total = 0
    var consumedCount = 0
    var unresolvedCount = 0
    var unhydratedCount = 0
    var projectionNotice = false
    var generation = 0
    var status: Status = .idle

    mutating func begin(path: [Revision], position: Int = 0, generation: Int? = nil) -> Int {
        self.generation = generation ?? self.generation + 1
        self.path = path
        self.position = position
        rows = []  // Never render rows from an earlier category while loading the next one.
        total = 0
        consumedCount = 0
        unresolvedCount = 0
        unhydratedCount = 0
        projectionNotice = false
        status = .loading
        return self.generation
    }

    mutating func accept(_ page: CategoryPreviewPage, generation: Int) {
        guard generation == self.generation else { return }
        rows = page.rows
        position = page.position
        total = page.total
        consumedCount = page.consumedCount
        unresolvedCount = page.unresolvedCount
        unhydratedCount = page.unhydratedCount
        projectionNotice = page.incomplete || page.conflictsAvailable
        status = .loaded
    }

    mutating func fail(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        rows = []
        total = 0
        status = .failed(String(describing: error))
    }
}

/// The exact same buffers and request construction as the normal item editor, kept apart so a
/// mode switch does not create a revision or mutate the report's form state.
struct CategoryInspectorDraft {
    let base: Revision
    var fields: [TextBuffer]
    var focus = 0

    func isMultiline(_ field: Int) -> Bool { [1, 3, 4].contains(field) }

    init(base: Revision) throws {
        let draft = try ItemDraft(base: base, isCategory: true)
        self.base = base
        fields = [
            draft.subject, draft.body, draft.className, draft.rule,
            draft.captureAliases, draft.captureDateProperty, draft.captureDateOffset,
            draft.captureDateTimeZone,
        ]
    }

    var isDirty: Bool {
        fields[0].text != base.fields["subject"]?.string ?? ""
            || fields[1].text != base.fields["body"]?.string ?? ""
            || fields[2].text != base.classID
            || fields[3].text != (base.fields["selection"]?.map?["expression"]?.string ?? "")
            || fields[4].text
                != (base.fields["captureAliases"]?.array ?? []).compactMap(\.string).joined(separator: "\n")
            || fields[5].text != (base.fields["captureDate"]?.map?["property"]?.string ?? "")
            || fields[6].text != String(base.fields["captureDate"]?.map?["dayOffset"]?.integerValue ?? 1)
            || fields[7].text != (base.fields["captureDate"]?.map?["timeZone"]?.string ?? "UTC")
    }

    mutating func request() throws -> CommitRequest? {
        if !fields[5].text.isEmpty {
            guard let offset = Int64(fields[6].text), (-1200...1200).contains(offset),
                TimeZone(identifier: fields[7].text.isEmpty ? "UTC" : fields[7].text) != nil
            else {
                throw TractandaError(
                    "invalidCapture",
                    "Capture date configuration needs a day offset from -1200 to 1200 and a named IANA timezone."
                )
            }
        }
        var draft = try ItemDraft(base: base, isCategory: true)
        draft.subject = fields[0]
        draft.body = fields[1]
        draft.className = fields[2]
        draft.rule = fields[3]
        draft.captureAliases = fields[4]
        draft.captureDateProperty = fields[5]
        draft.captureDateOffset = fields[6]
        draft.captureDateTimeZone = fields[7]
        return draft.request()
    }
}

/// Async bridge for the shared server capture interpreter. The terminal thread only consumes
/// immutable results; it never parses hashtags or evaluates dates itself.
struct CaptureActionLoader: Sendable {
    struct Failure: Sendable {
        let code: String
        let message: String
    }
    enum Outcome: Sendable {
        case prepared(TractandaCore.CapturePlan)
        case committed(TractandaCore.CommitResult)
        case failure(Failure)
    }
    private struct Delivery: Sendable {
        let generation: Int
        let outcome: Outcome
    }
    private struct State: Sendable {
        var generation = 0
        var delivery: Delivery?
    }
    private final class Mailbox: Sendable {
        private let state = Mutex(State())
        func begin() -> Int {
            state.withLock {
                $0.generation += 1
                $0.delivery = nil
                return $0.generation
            }
        }
        func publish(_ delivery: Delivery, operation: Int) {
            state.withLock { state in if operation == state.generation { state.delivery = delivery }
            }
        }
        func take() -> Delivery? {
            state.withLock { state in
                defer { state.delivery = nil }
                return state.delivery
            }
        }
        func hasValue() -> Bool { state.withLock { $0.delivery != nil } }
    }
    private let mailbox = Mailbox()
    private let client: TractandaClient.ItemClient
    init(connection: ServerConnection) {
        client = TractandaClient.ItemClient(transport: LocalItemTransport(connection: connection))
    }
    init(transport: any TractandaClient.ItemTransport) {
        client = TractandaClient.ItemClient(transport: transport)
    }
    func prepare(_ request: TractandaCore.CommitRequest, generation: Int) {
        let operation = mailbox.begin()
        let client = client
        let mailbox = mailbox
        Task.detached(priority: .userInitiated) {
            do {
                mailbox.publish(
                    Delivery(
                        generation: generation,
                        outcome: .prepared(
                            try await client.prepareCapture(
                                TractandaCore.CapturePreparation(request: request)))), operation: operation)
            } catch {
                mailbox.publish(
                    Delivery(
                        generation: generation,
                        outcome: .failure(
                            Failure(
                                code: (error as? TractandaError)?.code ?? "transport",
                                message: String(describing: error)))), operation: operation)
            }
        }
    }
    func commit(_ plan: TractandaCore.CapturePlan, generation: Int) {
        let operation = mailbox.begin()
        let client = client
        let mailbox = mailbox
        Task.detached(priority: .userInitiated) {
            do {
                mailbox.publish(
                    Delivery(
                        generation: generation,
                        outcome: .committed(try await client.commitCapture(plan))), operation: operation)
            } catch {
                mailbox.publish(
                    Delivery(
                        generation: generation,
                        outcome: .failure(
                            Failure(
                                code: (error as? TractandaError)?.code ?? "transport",
                                message: String(describing: error)))), operation: operation)
            }
        }
    }
    func cancel() { _ = mailbox.begin() }
    func take() -> (generation: Int, outcome: Outcome)? { mailbox.take().map { ($0.generation, $0.outcome) } }
    func hasDelivery() -> Bool { mailbox.hasValue() }
}

struct CapturePreviewGate {
    private(set) var generation = 0
    private(set) var isPreparing = false

    mutating func begin() -> Int {
        generation += 1
        isPreparing = true
        return generation
    }

    mutating func invalidate() {
        generation += 1
        isPreparing = false
    }

    mutating func accept(_ resultGeneration: Int) -> Bool {
        guard isPreparing, resultGeneration == generation else { return false }
        isPreparing = false
        return true
    }
}

enum CaptureReviewPresentation {
    static func text(for plan: TractandaCore.CapturePlan) -> String {
        let mentions = plan.mentions.map { mention in
            var line = "\(mention.token): "
            if let id = mention.categoryID { line += "category \(id)" }
            if !mention.candidates.isEmpty {
                line += " candidates [\(mention.candidates.joined(separator: ", "))]"
            }
            if mention.reusedBinding {
                line += " · prior capture (no change)"
                if let property = mention.dateProperty, let value = mention.dateValue {
                    line += " · historical \(property)=\(value), unchanged"
                }
            } else if let property = mention.dateProperty, let value = mention.dateValue {
                line += " · proposed \(property)=\(value)"
            }
            return line
        }
        let issues = plan.issues.map { "\($0.token) [\($0.code)]: \($0.message)" }
        let details = (issues.isEmpty ? mentions : issues + mentions).joined(separator: "\n")
        let body =
            plan.commitRequest.changes["body"]?.string ?? plan.request.changes["body"]?.string
            ?? "(body unchanged)"
        return (details.isEmpty ? "No hashtag assignments were resolved." : details)
            + "\n\nLiteral body retained; assignments and configured dates are listed above. No categories are created.\n\n"
            + body
    }
}
