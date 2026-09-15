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

    static func load(
        using client: TractandaCore.ItemClient, path: [String], position: Int, sort: [ItemSort]
    ) throws -> CategoryPreviewPage {
        struct QueryResult: Decodable {
            let ids: [String]
            let total: Int
            let queryState: String
        }
        struct GetResult: Decodable {
            let list: [Revision]
            let notFound: [String]
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
                rows: [], position: position, total: page.total, queryState: page.queryState)
        }
        let got = try JSON.decode(
            GetResult.self, client.call("TractandaItem/get", arguments: ["ids": page.ids]))
        guard got.notFound.isEmpty, got.state == page.queryState else {
            throw TractandaError("stateChanged", "Refresh the changing board.")
        }
        return CategoryPreviewPage(
            rows: got.list, position: position, total: page.total, queryState: page.queryState)
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
                                    queryState: page.state))))
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
    var generation = 0
    var status: Status = .idle

    mutating func begin(path: [Revision], position: Int = 0, generation: Int? = nil) -> Int {
        self.generation = generation ?? self.generation + 1
        self.path = path
        self.position = position
        rows = []  // Never render rows from an earlier category while loading the next one.
        total = 0
        status = .loading
        return self.generation
    }

    mutating func accept(_ page: CategoryPreviewPage, generation: Int) {
        guard generation == self.generation else { return }
        rows = page.rows
        position = page.position
        total = page.total
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

    init(base: Revision) throws {
        let draft = try ItemDraft(base: base)
        self.base = base
        fields = [draft.subject, draft.body, draft.className, draft.rule]
    }

    var isDirty: Bool {
        fields[0].text != base.fields["subject"]?.string ?? ""
            || fields[1].text != base.fields["body"]?.string ?? ""
            || fields[2].text != base.classID
            || fields[3].text != (base.fields["selection"]?.map?["expression"]?.string ?? "")
    }

    mutating func request() throws -> CommitRequest? {
        var draft = try ItemDraft(base: base)
        draft.subject = fields[0]
        draft.body = fields[1]
        draft.className = fields[2]
        draft.rule = fields[3]
        return draft.request()
    }
}
