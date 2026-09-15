import Foundation
import Testing

@testable import TractandaClient

private actor MemoryJournal: PendingEditStore {
    var edit: PendingEdit?
    var failsSaving = false
    func load() -> PendingEdit? { edit }
    func save(_ edit: PendingEdit) throws {
        if failsSaving { throw TractandaError("diskFull", "Cannot record recovery.") }
        self.edit = edit
    }
    func clear() { edit = nil }
    func setFailure(_ fails: Bool) { failsSaving = fails }
}

/// Small independent wire fixture: applies one guarded revision, then can lose its response.
private actor ScenarioTransport: ItemTransport {
    var current: Revision?
    var commitRequests: [Data] = []
    var uniqueCommits = 0
    var accessIsRevoked = false
    var hidesCurrent = false
    func hideCurrentItem() { hidesCurrent = true }
    func revokeAccess() { accessIsRevoked = true }
    private var receipts: [String: CommitResult] = [:]
    private var holdsFirstCommit: Bool
    private var losesFirstReply: Bool
    private var commitEntered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(current: Revision? = nil, holdsFirstCommit: Bool = false, losesFirstReply: Bool = false) {
        self.current = current
        self.holdsFirstCommit = holdsFirstCommit
        self.losesFirstReply = losesFirstReply
    }
    func waitForCommit() async {
        if commitEntered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func releaseCommit() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
    func externalEdit() throws {
        var fields = current!.fields
        fields["revisionID"] = .text(Identifier.make())
        fields["body"] = .text("Someone else's edit")
        current = try Revision(fields: fields)
    }

    func send(_ data: Data) async throws -> Data {
        if accessIsRevoked {
            return try reply("error", ["type": "accessDenied", "description": "Access was revoked."])
        }
        let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let call = (envelope["methodCalls"] as! [[Any]])[0]
        let method = call[0] as! String
        let args = call[1] as! [String: Any]
        let state = "state-\(current?.revisionID ?? "empty")"
        switch method {
        case "TractandaItem/query":
            let items = args["expression"] == nil && !hidesCurrent ? current.map { [$0.itemID] } ?? [] : []
            return try reply(
                method, ["ids": items, "position": 0, "total": items.count, "queryState": state])
        case "TractandaItem/get":
            let ids = args["ids"] as! [String]
            let list = current.flatMap { ids.contains($0.itemID) && !hidesCurrent ? [$0] : nil } ?? []
            return try reply(method, ["list": object(list), "notFound": [], "state": state])
        case "TractandaItem/commit":
            commitRequests.append(data)
            if holdsFirstCommit {
                holdsFirstCommit = false
                commitEntered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
                await withCheckedContinuation { releaseWaiter = $0 }
            }
            let request = try JSON.decode(CommitRequest.self, JSONSerialization.data(withJSONObject: args))
            if let receipt = receipts[request.operationID] {
                return try reply(
                    method,
                    object(
                        CommitResult(
                            revision: receipt.revision, wasReplayed: true, isIndexReady: true, warnings: [])))
            }
            if request.action == .revise, request.expectedRevisionID != current?.revisionID {
                return try reply("error", ["type": "revisionConflict", "description": "Item changed."])
            }
            var fields = try (current ?? revision("Captured")).fields
            for (key, value) in request.changes { fields[key] = value }
            for key in request.unset { fields.removeValue(forKey: key) }
            fields["operationID"] = .text(request.operationID)
            fields["revisionID"] = .text(Identifier.make())
            if let classID = request.classID { fields["classID"] = .text(classID) }
            let committed = try Revision(fields: fields)
            current = committed
            uniqueCommits += 1
            let receipt = CommitResult(
                revision: committed, wasReplayed: false, isIndexReady: true, warnings: [])
            receipts[request.operationID] = receipt
            if losesFirstReply {
                losesFirstReply = false
                throw TractandaError("connectionClosed", "Reply lost after committing.")
            }
            return try reply(method, object(receipt))
        default: throw TractandaError("unexpectedCall", method)
        }
    }
}

@MainActor @Test
func savingFreezesOneIntentAndRestartDoesNotReplayAutomatically() async throws {
    let transport = ScenarioTransport(holdsFirstCommit: true, losesFirstReply: true)
    let journal = MemoryJournal()
    let workspace = ItemWorkspace(client: ItemClient(transport: transport), journal: journal)
    await workspace.start()
    workspace.capture()
    workspace.draft?.subject = "Frozen subject"
    workspace.draft?.body = "Original draft 界"
    let firstSave = Task { await workspace.save() }
    await transport.waitForCommit()
    #expect(workspace.isSaving)
    #expect(await journal.load() == workspace.pendingEdit)
    await workspace.save()
    workspace.draft?.subject = "An incidental UI change must not alter the frozen request"
    await transport.releaseCommit()
    await firstSave.value
    #expect(workspace.pendingEdit?.request.changes["subject"] == .text("Frozen subject"))
    #expect(await transport.commitRequests.count == 1)

    let reopened = ItemWorkspace(client: ItemClient(transport: transport), journal: journal)
    await reopened.start()
    #expect(reopened.draft?.subject == "Frozen subject")
    #expect(await transport.commitRequests.count == 1)
    await reopened.retry()
    let requests = await transport.commitRequests
    #expect(requests.count == 2)
    #expect(requests[0] == requests[1])
    #expect(await transport.uniqueCommits == 1)
    #expect(await journal.load() == nil)
    #expect(reopened.pendingEdit == nil)
    #expect(reopened.draft == nil)
}

@MainActor @Test
func recoveryWriteFailurePreventsSendingAndAllowsExactRetry() async throws {
    let transport = ScenarioTransport()
    let journal = MemoryJournal()
    await journal.setFailure(true)
    let workspace = ItemWorkspace(client: ItemClient(transport: transport), journal: journal)
    workspace.capture()
    workspace.draft?.subject = "Keep this draft"
    await workspace.save()
    let pending = workspace.pendingEdit
    #expect(pending != nil)
    #expect(await transport.commitRequests.isEmpty)
    await journal.setFailure(false)
    await workspace.retry()
    #expect(await transport.current?.fields["operationID"]?.string == pending?.request.operationID)
    #expect(await transport.uniqueCommits == 1)
}

@MainActor @Test
func conflictsRetainDraftAndRequireExplicitReconciliation() async throws {
    let base = try revision("Original")
    let transport = ScenarioTransport(current: base)
    let workspace = ItemWorkspace(client: ItemClient(transport: transport), journal: MemoryJournal())
    await workspace.start()
    await workspace.editSelection()
    workspace.draft?.body = "My edit"
    try await transport.externalEdit()
    await workspace.save()
    #expect(workspace.lastError?.code == "revisionConflict")
    #expect(workspace.draft?.body == "My edit")
    #expect(workspace.draft?.base?.revisionID == base.revisionID)
    #expect(workspace.canCancel)
    await workspace.retry()
    #expect(await transport.commitRequests.count == 1)
    await workspace.cancelEdit()
    #expect(workspace.draft == nil)
    #expect(workspace.selectedItem?.fields["body"] == .text("Someone else's edit"))
    #expect(await transport.uniqueCommits == 0)
}

@Test func recoveryRejectsTamperedDraftRequestPairs() throws {
    var draft = try ItemEditorDraft()
    draft.subject = "Original intent"
    let request = try #require(try draft.makeRequest())
    let entry = try PendingEdit(request: request, draft: draft)
    #expect(try JSON.decode(PendingEdit.self, JSON.encode(entry)) == entry)
    draft.subject = "Changed after freezing"
    #expect(throws: TractandaError.self) { try PendingEdit(request: request, draft: draft) }
}

@MainActor @Test
func authorizationFailuresClearVisibleContentAndRetainOnlyPendingRecovery() async throws {
    let transport = ScenarioTransport(current: try revision("Private item"))
    let journal = MemoryJournal()
    let workspace = ItemWorkspace(client: ItemClient(transport: transport), journal: journal)
    await workspace.start()
    await workspace.editSelection()
    workspace.draft?.body = "An edit in flight"
    await transport.revokeAccess()
    await workspace.save()
    #expect(workspace.lastError?.code == "accessDenied")
    #expect(workspace.draft == nil)
    #expect(workspace.items.isEmpty)
    #expect(workspace.categories.isEmpty)
    #expect(workspace.selectedItemID == nil)
    #expect(workspace.pendingEdit != nil)
    #expect(await journal.load() == workspace.pendingEdit)
    #expect(await transport.uniqueCommits == 0)
}

@MainActor @Test
func refreshPreservesUnsavedDraftAndRevisionGuard() async throws {
    let transport = ScenarioTransport(current: try revision("Original"))
    let workspace = ItemWorkspace(client: ItemClient(transport: transport), journal: MemoryJournal())
    await workspace.start()
    await workspace.editSelection()
    workspace.draft?.body = "Local draft"
    let base = workspace.draft?.base?.revisionID
    try await transport.externalEdit()
    await workspace.refresh()
    #expect(workspace.draft?.body == "Local draft")
    #expect(workspace.draft?.base?.revisionID == base)
    await workspace.save()
    #expect(workspace.lastError?.code == "revisionConflict")
}

@MainActor @Test
func restoredDraftRechecksItemAccessEvenWhenQueriesSucceed() async throws {
    let base = try revision("Later private")
    let transport = ScenarioTransport(current: base, losesFirstReply: true)
    let journal = MemoryJournal()
    let original = ItemWorkspace(client: ItemClient(transport: transport), journal: journal)
    await original.start()
    await original.editSelection()
    original.draft?.body = "Pending change"
    await original.save()
    #expect(original.pendingEdit != nil)
    await transport.hideCurrentItem()
    let reopened = ItemWorkspace(client: ItemClient(transport: transport), journal: journal)
    await reopened.start()
    #expect(reopened.lastError?.code == "notFound")
    #expect(reopened.draft == nil)
    #expect(reopened.items.isEmpty)
    #expect(reopened.pendingEdit != nil)
    #expect(await transport.commitRequests.count == 1)
}

@MainActor @Test
func refreshRechecksAnOpenDraftsAccessWithoutReplacingItsBase() async throws {
    let transport = ScenarioTransport(current: try revision("Later private"))
    let workspace = ItemWorkspace(client: ItemClient(transport: transport), journal: MemoryJournal())
    await workspace.start()
    await workspace.editSelection()
    workspace.draft?.body = "Unsaved"
    await transport.hideCurrentItem()
    await workspace.refresh()
    #expect(workspace.lastError?.code == "notFound")
    #expect(workspace.draft == nil)
    #expect(workspace.items.isEmpty)
}
