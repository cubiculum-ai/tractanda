import Foundation
import Observation

public struct PendingEdit: Codable, Equatable, Sendable {
    public let request: CommitRequest
    public let draft: ItemEditorDraft

    public init(request: CommitRequest, draft: ItemEditorDraft) throws {
        guard try draft.makeRequest(operationID: request.operationID) == request else {
            throw TractandaError("invalidRecovery", "The pending request does not match its draft.")
        }
        self.request = request
        self.draft = draft
    }
    private enum CodingKeys: String, CodingKey { case request, draft }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            request: fields.decode(CommitRequest.self, forKey: .request),
            draft: fields.decode(ItemEditorDraft.self, forKey: .draft))
    }
}

/// Each implementation scopes recovery to its server and caller; load never submits an edit.
public protocol PendingEditStore: Sendable {
    func load() async throws -> PendingEdit?
    func save(_ edit: PendingEdit) async throws
    func clear() async throws
}

/// Shared presentation behavior. Views own focus/layout; the service owns membership and permissions.
@MainActor @Observable
public final class ItemWorkspace {
    public private(set) var items: [Revision] = []
    public private(set) var categories: [Revision] = []
    public private(set) var categoryPath: [Revision] = []
    public private(set) var selectedItemID: String?
    public private(set) var position = 0
    public private(set) var total = 0
    public private(set) var categoryPosition = 0
    public private(set) var categoryTotal = 0
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var message = "Ready"
    public var draft: ItemEditorDraft?
    public private(set) var pendingEdit: PendingEdit?
    public private(set) var lastError: TractandaError?
    @ObservationIgnored public var onChange: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private let client: ItemClient
    @ObservationIgnored private let journal: any PendingEditStore
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var state: String?
    public static let pageSize = 32

    public init(client: ItemClient, journal: any PendingEditStore) {
        self.client = client
        self.journal = journal
    }
    public var selectedItem: Revision? { items.first { $0.itemID == selectedItemID } }
    public var hasNextPage: Bool { position + items.count < total }
    public var hasNextCategoryPage: Bool { categoryPosition + categories.count < categoryTotal }
    public var isDraftLocked: Bool { pendingEdit != nil || isSaving }
    public var canCancel: Bool { !isSaving && (pendingEdit == nil || isDefinitivelyRejected) }
    public var pathTitle: String {
        (["All items"] + categoryPath.map { $0.fields["subject"]?.string ?? $0.itemID }).joined(
            separator: " / ")
    }
    private var isDefinitivelyRejected: Bool {
        guard let code = lastError?.code else { return false }
        return [
            "revisionConflict", "invalidArguments", "invalidValue", "invalidKey", "invalidQuery",
            "unsupportedQuery", "unknownClass", "abstractClass", "invalidClass", "invalidSelection",
        ].contains(code)
    }

    public func start() async {
        do {
            pendingEdit = try await journal.load()
            // Authorize referenced content before publishing a recovered draft.
            // Queries can succeed while silently omitting a newly private item.
            if let itemID = pendingEdit?.request.itemID {
                _ = try await client.revision(for: itemID)
            }
        } catch {
            record(error)
            return
        }
        await refresh()
        if let pendingEdit, lastError == nil {
            draft = pendingEdit.draft
            message = "Pending edit recovered. Retry the same edit to confirm its outcome."
        }
        onChange?()
    }

    public func select(_ itemID: String) {
        guard draft == nil, items.contains(where: { $0.itemID == itemID }) else { return }
        selectedItemID = itemID
        onChange?()
    }

    public func refresh() async { await load(position: position, requiring: nil) }

    private func load(position requestedPosition: Int, requiring expectedState: String?) async {
        generation += 1
        let ticket = generation
        let requestedPath = categoryPath
        let editingItemID = draft?.base?.itemID
        isLoading = true
        onChange?()
        defer {
            if generation == ticket {
                isLoading = false
                onChange?()
            }
        }
        do {
            if let editingItemID { _ = try await client.revision(for: editingItemID) }
            var currentPath: [Revision] = []
            for category in requestedPath {
                currentPath.append(try await client.revision(for: category.itemID))
            }
            let order = try [ItemSort(property: "subject")]
            var query = ItemQuery(
                categoryPath: currentPath.map(\.itemID), position: requestedPosition,
                limit: Self.pageSize, sort: order)
            var page = try await client.page(matching: query, requiring: expectedState)
            if page.items.isEmpty, requestedPosition > 0, expectedState == nil {
                query.position = 0
                page = try await client.page(matching: query)
            }
            let categoryPage = try await client.page(
                matching: ItemQuery(
                    expression: "selection == *", position: categoryPosition,
                    limit: Self.pageSize, sort: order))
            guard generation == ticket else { return }
            items = page.items
            position = page.position
            total = page.total
            state = page.state
            categoryPath = currentPath
            categories = categoryPage.items
            categoryTotal = categoryPage.total
            if !items.contains(where: { $0.itemID == selectedItemID }) {
                selectedItemID = items.first?.itemID
            }
            message = "\(total) items"
            if pendingEdit == nil { lastError = nil }
        } catch {
            guard generation == ticket else { return }
            items = []
            categories = []
            selectedItemID = nil
            state = nil
            if let error = error as? TractandaError, ["notFound", "accessDenied"].contains(error.code) {
                categoryPath = []
                // Local pending recovery is retained, but revoked content is removed from the visible editor.
                draft = nil
            }
            record(error)
        }
    }

    public func changePage(forward: Bool) async {
        guard !isLoading, draft == nil, forward ? hasNextPage : position > 0 else { return }
        await load(position: max(0, position + (forward ? Self.pageSize : -Self.pageSize)), requiring: state)
    }

    public func changeCategoryPage(forward: Bool) async {
        guard !isLoading, draft == nil, forward ? hasNextCategoryPage : categoryPosition > 0 else { return }
        categoryPosition = max(0, categoryPosition + (forward ? Self.pageSize : -Self.pageSize))
        await refresh()
    }

    public func enterCategory(_ itemID: String) async {
        guard draft == nil, !isLoading,
            let category = categories.first(where: { $0.itemID == itemID }),
            categoryPath.count < 32, !categoryPath.contains(where: { $0.itemID == itemID })
        else { return }
        categoryPath.append(category)
        await load(position: 0, requiring: nil)
    }

    public func leaveCategory() async {
        guard draft == nil, !isLoading, !categoryPath.isEmpty else { return }
        categoryPath.removeLast()
        await load(position: 0, requiring: nil)
    }

    public func capture() {
        guard draft == nil, pendingEdit == nil, !isLoading else { return }
        do {
            draft = try ItemEditorDraft(assignedCategories: categoryPath.map(\.itemID))
            lastError = nil
            message = "New item"
        } catch { record(error) }
        onChange?()
    }

    public func editSelection() async {
        guard draft == nil, pendingEdit == nil, !isLoading, let selectedItemID else { return }
        generation += 1
        let ticket = generation
        do {
            let current = try await client.revision(for: selectedItemID)
            guard generation == ticket, draft == nil, self.selectedItemID == selectedItemID else { return }
            draft = try ItemEditorDraft(base: current)
            lastError = nil
            message = "Editing \(current.fields["subject"]?.string ?? "item")"
        } catch {
            if generation == ticket { record(error) }
        }
        onChange?()
    }

    public func cancelEdit() async {
        guard canCancel else { return }
        do {
            try await journal.clear()
            draft = nil
            pendingEdit = nil
            lastError = nil
            await refresh()
        } catch { record(error) }
        onChange?()
    }

    public func save() async {
        guard !isSaving, pendingEdit == nil, let draft else { return }
        do {
            guard let request = try draft.makeRequest() else {
                self.draft = nil
                message = "No changes"
                onChange?()
                return
            }
            pendingEdit = try PendingEdit(request: request, draft: draft)
            await sendPendingEdit()
        } catch { record(error) }
    }

    public func retry() async {
        guard !isSaving, pendingEdit != nil, !isDefinitivelyRejected else { return }
        await sendPendingEdit()
    }

    private func sendPendingEdit() async {
        guard let pendingEdit else { return }
        isSaving = true
        message = "Saving…"
        onChange?()
        defer {
            isSaving = false
            onChange?()
        }
        do {
            // If recovery cannot be recorded, nothing is sent.
            try await journal.save(pendingEdit)
            let result = try await client.commit(pendingEdit.request)
            try await journal.clear()
            self.pendingEdit = nil
            draft = nil
            lastError = nil
            selectedItemID = result.revision.itemID
            if result.isIndexReady {
                await refresh()
                if lastError == nil { message = result.wasReplayed ? "Save confirmed by retry" : "Saved" }
            } else {
                message = "Saved; the server index needs rebuilding before refreshing."
            }
        } catch {
            record(error)
            if isDefinitivelyRejected {
                message += " Draft retained; cancel and reopen to reconcile."
            } else {
                message += " Pending edit retained for an explicit retry."
            }
        }
    }

    private func record(_ error: any Error) {
        lastError = error as? TractandaError ?? TractandaError("transportError", String(describing: error))
        message = lastError!.message
        if ["notFound", "accessDenied", "authenticationRequired", "unauthorized"].contains(lastError!.code) {
            // The last visible snapshot must not survive a known authorization failure.
            // Recovery remains local and never implies permission to submit or redisplay it.
            items = []
            categories = []
            categoryPath = []
            selectedItemID = nil
            total = 0
            categoryTotal = 0
            state = nil
            draft = nil
        }
        onChange?()
    }
}
