import Foundation
import Testing

@testable import TractandaClient

private actor ScriptedTransport: ItemTransport {
    var responses: [Data]
    var requests: [Data] = []
    var discoveryRequests: [Data] = []
    var stateRequests: [Data] = []
    let itemState: String?
    init(_ responses: [Data], itemState: String? = nil) {
        self.responses = responses
        self.itemState = itemState
    }
    func send(_ request: Data) async throws -> Data {
        let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let call = (envelope["methodCalls"] as! [[Any]])[0]
        if call[0] as? String == "TractandaSession/get" {
            discoveryRequests.append(request)
            return try discoveryReply(callID: call[2] as! String)
        }
        if let itemState, call[0] as? String == "TractandaItem/get",
            let args = call[1] as? [String: Any], let ids = args["ids"] as? [String], ids.isEmpty
        {
            stateRequests.append(request)
            return try reply(
                "TractandaItem/get", object(ItemGetResult(list: [], notFound: [], state: itemState)),
                tag: call[2] as! String)
        }
        requests.append(request)
        return responses.removeFirst()
    }
}

func revision(_ subject: String, itemID: String? = nil) throws -> Revision {
    try Revision(fields: [
        "itemID": .text(itemID ?? Identifier.make()), "revisionID": .text(Identifier.make()),
        "classID": .text("Item"), "actor": .text("user:test"), "operationID": .text("fixture"),
        "requestIdentity": .text("fixture"), "schemaVersion": .integer(1),
        "createdAt": .date("2026-09-08T00:00:00Z"), "modifiedAt": .date("2026-09-08T00:00:00Z"),
        "subject": .text(subject), "body": .text("Original body"),
        "arbitrary.key": .integer(9_007_199_254_740_993),
        "selection": .object([
            "language": .text(ItemClient.queryProfile), "expression": .text("subject == *"),
            "futureSetting": .text("preserve me"),
        ]),
    ])
}

@Test func batchGetPreservesMixedResolvedAndUnresolvedOutcomes() async throws {
    let resolved = try revision("Resolved")
    let unresolvedID = Identifier.make()
    let missingID = Identifier.make()
    let remainingID = Identifier.make()
    let oversizedID = Identifier.make()
    let unresolved = ItemUnresolvedState(
        itemID: unresolvedID, status: .reviewRequired, stateToken: "item-state-token")
    let response = ItemGetResult(
        list: [resolved], notFound: [missingID], unresolved: [unresolved], state: "store-state",
        remainingIDs: [remainingID], oversizedIDs: [oversizedID])
    let transport = try ScriptedTransport([reply("TractandaItem/getBounded", object(response))])

    let result = try await ItemClient(transport: transport).items(
        ids: [resolved.itemID, unresolvedID, missingID, remainingID, oversizedID])

    #expect(result.list == [resolved])
    #expect(result.unresolved == [unresolved])
    #expect(result.notFound == [missingID])
    #expect(result.remainingIDs == [remainingID])
    #expect(result.oversizedIDs == [oversizedID])
}

@Test func getRejectsOmittedRepeatedAndUnrequestedIDs() async throws {
    let item = try revision("Requested")
    let unrequested = try revision("Unrequested")
    let malformed = [
        ItemGetResult(list: [], notFound: [], state: "state"),
        ItemGetResult(list: [item], notFound: [item.itemID], state: "state"),
        ItemGetResult(list: [unrequested], notFound: [], state: "state"),
    ]
    for result in malformed {
        let transport = try ScriptedTransport([reply("TractandaItem/getBounded", object(result))])
        await #expect(
            throws: TractandaError("protocolError", "Read response omitted or repeated requested IDs.")
        ) {
            try await ItemClient(transport: transport).revision(for: item.itemID)
        }
    }
}

@Test func getQueryAndHistoryKeepTypedHistoricalDispositions() async throws {
    let demoted = try revision("Formerly accepted")
    let dispositions = [demoted.revisionID: HistoricalDisposition.demoted]
    let typedGet = ItemGetResult(
        list: [demoted], notFound: [], state: "store-state",
        historicalDispositions: dispositions)
    let getTransport = try ScriptedTransport([reply("TractandaItem/getBounded", object(typedGet))])
    let get = try await ItemClient(transport: getTransport).items(ids: [demoted.itemID])
    #expect(get.list == [demoted])
    #expect(get.historicalDispositions == dispositions)

    let legacyGetTransport = try ScriptedTransport([
        reply(
            "TractandaItem/getBounded",
            [
                "list": [try object(demoted)], "notFound": [], "state": "store-state",
            ])
    ])
    let legacyGet = try await ItemClient(transport: legacyGetTransport).items(ids: [demoted.itemID])
    #expect(legacyGet.historicalDispositions.isEmpty)

    let invalidGetTransport = try ScriptedTransport([
        reply(
            "TractandaItem/getBounded",
            [
                "list": [try object(demoted)], "notFound": [], "state": "store-state",
                "historicalDispositions": [Identifier.make(): "demoted"],
            ])
    ])
    await #expect(
        throws: TractandaError("protocolError", "Get disposition map names a revision not returned.")
    ) {
        try await ItemClient(transport: invalidGetTransport).items(ids: [demoted.itemID])
    }

    let pageResult = ItemHistoryResult(
        list: [demoted], total: 4, historicalDispositions: dispositions)
    let historyTransport = try ScriptedTransport([
        reply("TractandaItem/history", object(pageResult))
    ])
    let history = try await ItemClient(transport: historyTransport).history(
        itemID: demoted.itemID, position: 2, limit: 1)
    #expect(history.list == [demoted])
    #expect(history.total == 4)
    #expect(history.historicalDispositions == dispositions)
    let requests = await historyTransport.requests
    let envelope = try JSONSerialization.jsonObject(with: requests[0]) as! [String: Any]
    let call = (envelope["methodCalls"] as! [[Any]])[0]
    let arguments = call[1] as! [String: Any]
    #expect(arguments["itemID"] as? String == demoted.itemID)
    #expect(arguments["position"] as? Int == 2)
    #expect(arguments["limit"] as? Int == 1)

    let legacyHistoryTransport = try ScriptedTransport([
        reply("TractandaItem/history", ["list": [try object(demoted)], "total": 1])
    ])
    let legacyHistory = try await ItemClient(transport: legacyHistoryTransport).history(
        itemID: demoted.itemID)
    #expect(legacyHistory.historicalDispositions.isEmpty)

    let exactRevisionResult = RevisionGetResult(
        revision: demoted, historicalDispositions: dispositions)
    let exactRevisionTransport = try ScriptedTransport([
        reply("TractandaRevision/get", object(exactRevisionResult))
    ])
    let exactRevision = try await ItemClient(transport: exactRevisionTransport).call(
        "TractandaRevision/get",
        arguments: ["itemID": demoted.itemID, "revisionID": demoted.revisionID],
        returning: JMAPRevisionGetResponse.self)
    #expect(try exactRevision.list[0].canonicalRevision() == demoted)
    #expect(exactRevision.list.count == 1)

    let invalidDispositionTransport = try ScriptedTransport([
        reply(
            "TractandaItem/history",
            [
                "list": [try object(demoted)], "total": 1,
                "historicalDispositions": [Identifier.make(): "demoted"],
            ])
    ])
    await #expect(
        throws: TractandaError("protocolError", "History page contains an invalid disposition map.")
    ) {
        try await ItemClient(transport: invalidDispositionTransport).history(itemID: demoted.itemID)
    }
}

@Test func queryPageCarriesDispositionFromItsGetHydration() async throws {
    let historical = try revision("Demoted query result")
    let result = ItemGetResult(
        list: [historical], notFound: [], state: "items-token",
        historicalDispositions: [historical.revisionID: .demoted])
    let transport = try ScriptedTransport(
        [
            reply(
                "TractandaItem/query",
                [
                    "ids": [historical.itemID], "position": 0, "total": 1, "queryState": "query-token",
                ]),
            reply("TractandaItem/getBounded", object(result)),
        ], itemState: "items-token")
    let page = try await ItemClient(transport: transport).page(matching: ItemQuery(limit: 1))
    #expect(page.items == [historical])
    #expect(page.state == "query-token")
    #expect(await transport.stateRequests.count == 2)
    #expect(page.historicalDispositions == [historical.revisionID: .demoted])
}

@Test func singleRevisionReportsReadableUnresolvedState() async throws {
    let itemID = Identifier.make()
    let unresolved = ItemUnresolvedState(
        itemID: itemID, status: .conflicted, stateToken: "token")
    let result = ItemGetResult(list: [], notFound: [], unresolved: [unresolved], state: "state")
    let transport = try ScriptedTransport([reply("TractandaItem/getBounded", object(result))])
    do {
        _ = try await ItemClient(transport: transport).revision(for: itemID)
        Issue.record("Expected unresolved item error")
    } catch let error as TractandaError {
        #expect(error.code == "itemUnresolved")
    }
}

@Test func queryPageRetainsConsumedUnresolvedIDsAcrossGetChunks() async throws {
    let ids = (0..<65).map { _ in Identifier.make() }
    let resolved = try (0..<63).map { try revision("Resolved \($0)", itemID: ids[$0]) }
    let unresolved = ItemUnresolvedState(
        itemID: ids[63], status: .conflicted, stateToken: "item-token")
    let transport = try ScriptedTransport(
        [
            reply(
                "TractandaItem/query",
                [
                    "ids": ids, "position": 7, "total": 100, "queryState": "query-token",
                    "completeness": "unresolvedItems", "conflictsAvailable": true,
                ]),
            reply(
                "TractandaItem/getBounded",
                object(
                    ItemGetResult(
                        list: resolved, notFound: [], unresolved: [unresolved], state: "items-token"))),
            reply(
                "TractandaItem/getBounded",
                object(
                    ItemGetResult(
                        list: [], notFound: [ids[64]], state: "items-token"))),
        ], itemState: "items-token")

    let page = try await ItemClient(transport: transport).page(matching: ItemQuery(position: 7, limit: 256))

    #expect(page.items == resolved)
    #expect(page.unresolved == [unresolved])
    #expect(page.notFound == [ids[64]])
    #expect(page.consumedCount == 65)
    #expect(page.position == 7)
    #expect(page.hasNextPage)
    #expect(page.completeness == .unresolvedItems)
    #expect(page.conflictsAvailable)
    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(await transport.stateRequests.count == 2)
    #expect(page.state == "query-token")
    let firstGet = try JSONSerialization.jsonObject(with: requests[1]) as! [String: Any]
    let secondGet = try JSONSerialization.jsonObject(with: requests[2]) as! [String: Any]
    let firstCall = firstGet["methodCalls"] as! [[Any]]
    let secondCall = secondGet["methodCalls"] as! [[Any]]
    let firstArgs = firstCall[0][1] as! [String: Any]
    let secondArgs = secondCall[0][1] as! [String: Any]
    #expect((firstArgs["ids"] as? [String])?.count == 64)
    #expect((secondArgs["ids"] as? [String]) == [ids[64]])
}

@Test func stateAndConflictResolutionPreserveStateCASWithoutChangingOrdinaryCommitShape() async throws {
    let itemID = Identifier.make()
    let state = ItemState(
        itemID: itemID, stateToken: "state-token", status: .conflicted,
        frontier: [Identifier.make(), Identifier.make()], conflictingFields: ["subject"],
        detailsComplete: true)
    let stateResult = ItemStateResult(list: [state], notFound: [], state: "store-state")
    let resolvedRevisionBase = try revision("Resolved", itemID: itemID)
    var fields = resolvedRevisionBase.fields
    fields["operationID"] = .text("resolve-op")
    let resolvedRevision = try Revision(fields: fields)
    let commitResult = CommitResult(
        revision: resolvedRevision, wasReplayed: false, isIndexReady: true, warnings: [],
        itemState: ItemState(
            itemID: itemID, stateToken: "new-state", status: .ready,
            representativeRevisionID: resolvedRevision.revisionID, detailsComplete: true))
    let transport = try ScriptedTransport([
        reply("TractandaItem/state", object(stateResult)),
        reply("TractandaItem/resolveConflict", object(try MutationReceipt(commitResult))),
    ])
    let client = ItemClient(transport: transport)
    #expect(try await client.itemStates(ids: [itemID]) == stateResult)
    let request = ResolveConflictRequest(
        itemID: itemID, expectedStateToken: "state-token", reviewedFrontier: state.frontier!,
        changes: ["subject": .text("chosen")], unset: [], operationID: "resolve-op")
    let result = try await client.resolveConflict(request)
    #expect(result.revisionID == resolvedRevision.revisionID)
    #expect(result.itemID == resolvedRevision.itemID)
    let requests = await transport.requests
    let envelope = try JSONSerialization.jsonObject(with: requests[1]) as! [String: Any]
    let calls = envelope["methodCalls"] as! [[Any]]
    let arguments = calls[0][1] as! [String: Any]
    #expect(arguments["expectedStateToken"] as? String == "state-token")
    #expect(arguments["reviewedFrontier"] as? [String] == state.frontier)
    #expect(arguments["expectedRevisionID"] == nil)

    let ordinary = CommitRequest(
        action: .revise, itemID: itemID, expectedRevisionID: "base", operationID: "normal")
    let ordinaryObject = try JSONSerialization.jsonObject(with: JSON.encode(ordinary)) as! [String: Any]
    #expect(ordinaryObject["expectedStateToken"] == nil)
    #expect(ordinaryObject["reviewedFrontier"] == nil)
}

@Test func conflictPagesRetainOpaqueCursorAndStoreState() async throws {
    let item = ItemState(
        itemID: Identifier.make(), stateToken: "item-token", status: .invariantConflict,
        frontier: [Identifier.make()], detailsComplete: false,
        resource: ItemStateResource(code: "categoryCycle", phase: .analysis, message: "Review required"))
    let transport = try ScriptedTransport([
        reply(
            "TractandaItem/conflicts",
            object(
                ItemConflictPage(
                    list: [item], nextCursor: "opaque-next", state: "store-token")))
    ])
    let page = try await ItemClient(transport: transport).conflicts(limit: 16, cursor: "opaque-before")
    #expect(page.list == [item])
    #expect(page.nextCursor == "opaque-next")
    #expect(page.state == "store-token")
    let requests = await transport.requests
    let envelope = try JSONSerialization.jsonObject(with: requests[0]) as! [String: Any]
    let calls = envelope["methodCalls"] as! [[Any]]
    let arguments = calls[0][1] as! [String: Any]
    #expect(arguments["limit"] as? Int == 16)
    #expect(arguments["cursor"] as? String == "opaque-before")
}

func reply(_ method: String, _ value: Any, tag: String = "client") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "methodResponses": [[method, try fixtureReadPayload(method, value), tag]]
    ])
}
func object(_ value: some Encodable) throws -> Any {
    try JSONSerialization.jsonObject(with: JSON.encode(value))
}

@Test func pagesPreserveServerOrderAndIntegerPrecision() async throws {
    let first = try revision("First")
    let second = try revision("Second")
    let transport = try ScriptedTransport(
        [
            reply(
                "TractandaItem/query",
                [
                    "ids": [first.itemID, second.itemID], "position": 0, "total": 3, "queryState": "state-1",
                ]),
            reply(
                "TractandaItem/getBounded",
                ["list": object([second, first]), "notFound": [], "state": "item-state-1"]),
        ], itemState: "item-state-1")
    let page = try await ItemClient(transport: transport).page(matching: ItemQuery(limit: 2))
    #expect(page.items == [first, second])
    #expect(page.hasNextPage)
    #expect(page.items[0].fields["arbitrary.key"] == .integer(9_007_199_254_740_993))
    #expect(await transport.requests.count == 2)
    #expect(await transport.stateRequests.count == 2)
    #expect(page.state == "state-1")
}

@Test func changingOrIncompletePagesAreRejected() async throws {
    let item = try revision("Shared")
    let transport = try ScriptedTransport(
        [
            reply(
                "TractandaItem/query",
                [
                    "ids": [item.itemID], "position": 0, "total": 1, "queryState": "before",
                ]),
            reply("TractandaItem/getBounded", ["list": [], "notFound": [item.itemID], "state": "after"]),
        ], itemState: "before")
    await #expect(throws: TractandaError("stateChanged", "Items changed while loading; refresh the view.")) {
        try await ItemClient(transport: transport).page(matching: ItemQuery())
    }
}

@Test func cursorQueryOmitsRandomAccessPosition() throws {
    let query = ItemQuery(limit: 16, cursor: "opaque", at: "2026-09-27T12:34:56.123Z", timeZone: "UTC")
    let object = try JSONSerialization.jsonObject(with: JSON.encode(query)) as? [String: Any]
    #expect(object?["cursor"] as? String == "opaque")
    #expect(object?["position"] == nil)
    #expect(object?["categoryPath"] == nil)
}

@Test func nativeErrorsRetainTheirMeaningAndCheckCorrelation() async throws {
    let request = CommitRequest(operationID: "edit")
    for tag in ["client", "another-call"] {
        let transport = try ScriptedTransport([
            reply("error", ["type": "revisionConflict", "description": "Changed by someone else."], tag: tag)
        ])
        do {
            _ = try await ItemClient(transport: transport).commit(request)
            Issue.record("Expected a failure")
        } catch let error as TractandaError {
            #expect(error.code == (tag == "client" ? "revisionConflict" : "protocolError"))
        }
    }
}

@Test func draftEditsPreserveUnknownFieldsAndWholeEditSemantics() throws {
    let base = try revision("Original")
    var draft = try ItemEditorDraft(base: base)
    #expect(try draft.makeRequest() == nil)
    draft.subject = "Edited"
    draft.body = "Unicode 界 e\u{301}\nSecond line"
    draft.rule = "subject ==[c] \"*edited*\""
    draft.className = "EmailMessageItem"
    let request = try #require(try draft.makeRequest(operationID: "whole-edit"))
    #expect(request.itemID == base.itemID)
    #expect(request.expectedRevisionID == base.revisionID)
    #expect(request.operationID == "whole-edit")
    #expect(request.action == .retype)
    #expect(Set(request.changes.keys) == ["subject", "body", "selection"])
    #expect(request.changes["selection"]?.map?["futureSetting"] == .text("preserve me"))
    let restored = try JSON.decode(CommitRequest.self, JSON.encode(request))
    #expect(restored == request)
    draft.rule = ""
    #expect(try draft.makeRequest()?.unset == ["selection"])
}

@Test func captureAndLimitsAreIndependentOfUIFramework() throws {
    let category = Identifier.make()
    var draft = try ItemEditorDraft(assignedCategories: [category, category])
    draft.subject = "A new item"
    let request = try #require(try draft.makeRequest(operationID: "capture"))
    #expect(request.action == .create)
    #expect(request.changes["categoryOverrides"]?.map == [category: .text("include")])
    draft.body = String(repeating: "界", count: 30_000)
    #expect(throws: TractandaError.self) { try draft.makeRequest() }
}

@Test func attachmentClientPreservesChunkOffsetsAndMetadata() async throws {
    let descriptor = try AttachmentDescriptor(
        attachmentID: "c151fc20-bff6-11f1-8000-001122334455", filename: "notes.pdf",
        mediaType: "application/pdf", byteCount: 3,
        sha256: String(repeating: "a", count: 64))
    let transport = try ScriptedTransport([
        reply(
            "TractandaAttachment/begin",
            object(
                AttachmentUploadResult(
                    uploadID: descriptor.attachmentID, attachment: descriptor, offset: 0,
                    chunkBytes: 262_144, expiresAt: "2026-09-28T13:00:00Z", committed: nil))),
        reply("TractandaAttachment/upload", ["offset": 3]),
        reply(
            "TractandaAttachment/list",
            object(
                AttachmentListResult(
                    itemID: "item", revisionID: "revision", attachments: [descriptor]))),
        reply(
            "TractandaAttachment/content",
            object(
                AttachmentContentResult(
                    attachment: descriptor, offset: 0, nextOffset: 3, isComplete: true, data: Data("abc".utf8)
                ))),
    ])
    let client = ItemClient(transport: transport)
    let upload = try await client.beginAttachment(
        AttachmentUploadRequest(
            itemID: "item", expectedRevisionID: "revision", operationID: "attach",
            filename: descriptor.filename, mediaType: descriptor.mediaType,
            byteCount: descriptor.byteCount, sha256: descriptor.sha256))
    #expect(upload.attachment == descriptor)
    #expect(
        try await client.appendAttachment(
            uploadID: descriptor.attachmentID, offset: 0, data: Data("abc".utf8)) == 3)
    #expect(try await client.listAttachments(itemID: "item").attachments == [descriptor])
    #expect(
        try await client.attachmentContent(itemID: "item", attachmentID: descriptor.attachmentID).data
            == Data("abc".utf8))
    let requests = await transport.requests
    let envelope = try JSONSerialization.jsonObject(with: requests[1]) as! [String: Any]
    let calls = envelope["methodCalls"] as! [[Any]]
    let args = calls[0][1] as! [String: Any]
    #expect(args["offset"] as? Int == 0)
    #expect(args["data"] as? String == "YWJj")
}

@Test func attachmentFinishAndDetachDecodeCompactReceipts() async throws {
    let parent = try revision(String(repeating: "large parent", count: 1_000))
    let receipt = AttachmentCommitResult(
        CommitResult(revision: parent, wasReplayed: false, isIndexReady: true, warnings: []))
    let transport = try ScriptedTransport([
        reply("TractandaAttachment/finish", object(receipt)),
        reply("TractandaAttachment/detach", object(receipt)),
    ])
    let client = ItemClient(transport: transport)
    let finish = try await client.finishAttachment(uploadID: "upload")
    #expect(finish.itemID == parent.itemID)
    #expect(finish.revisionID == parent.revisionID)
    let detach = try await client.detachAttachment(
        itemID: parent.itemID, expectedRevisionID: parent.revisionID,
        attachmentID: "attachment", operationID: "detach")
    #expect(detach.revisionID == parent.revisionID)
    let encoded = try JSON.encode(receipt)
    #expect(encoded.count < 1_024)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("large parent"))
}

@Test func attachmentTextExtractionUsesGuardedCompactRequest() async throws {
    let item = try revision("source")
    let receipt = AttachmentCommitResult(
        CommitResult(revision: item, wasReplayed: true, isIndexReady: true, warnings: []))
    let transport = try ScriptedTransport([reply("TractandaAttachment/extractText", object(receipt))])
    let result = try await ItemClient(transport: transport).extractAttachmentText(
        itemID: item.itemID,
        expectedRevisionID: item.revisionID, attachmentID: "attachment", operationID: "extract")
    #expect(result.itemID == item.itemID)
    #expect(result.wasReplayed)
    let requests = await transport.requests
    let request = try JSONSerialization.jsonObject(with: requests[0]) as! [String: Any]
    let calls = request["methodCalls"] as! [[Any]]
    let fields = calls[0][1] as! [String: Any]
    #expect(fields["expectedRevisionID"] as? String == item.revisionID)
    #expect(fields["operationID"] as? String == "extract")
    #expect(fields["attachmentID"] as? String == "attachment")
    #expect(fields["changes"] == nil)
}

@Test func originalContentRetriesOnlyPendingIntegrityAndPreservesExactRequest() async throws {
    let id = Identifier.make()
    let descriptor = try AttachmentDescriptor(
        attachmentID: "b1023f62-c510-11f1-a9ab-842f575e6ac5", filename: "original.pdf",
        mediaType: "application/pdf", byteCount: 0, sha256: String(repeating: "0", count: 64))
    let result = AttachmentContentResult(
        attachment: descriptor, offset: 0, nextOffset: 0, isComplete: true, data: Data())
    let transport = try ScriptedTransport([
        reply(
            "error",
            [
                "type": "attachmentVerifying", "description": "Pending", "retryable": true,
                "verifiedBytes": 0, "totalBytes": 0,
            ]),
        reply("TractandaAttachment/content", object(result)),
    ])
    let content = try await ItemClient(transport: transport).attachmentContent(
        itemID: id, revisionID: id, attachmentID: descriptor.attachmentID)
    #expect(content.isComplete)
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[0] == requests[1])
    let forbidden = try ScriptedTransport([reply("error", ["type": "forbidden", "description": "Revoked"])])
    await #expect(throws: TractandaError("forbidden", "Revoked")) {
        try await ItemClient(transport: forbidden).attachmentContent(
            itemID: id, attachmentID: descriptor.attachmentID)
    }
    #expect(await forbidden.requests.count == 1)
}

@Test func pendingOriginalIntegrityRetryRemainsCancellable() async throws {
    let pending = try reply("error", ["type": "attachmentVerifying", "description": "Pending"])
    let transport = ScriptedTransport([pending])
    let task = Task {
        try await ItemClient(transport: transport).finishAttachment(uploadID: Identifier.make())
    }
    while await transport.requests.isEmpty { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.requests.count == 1)
}

@Test func copyPendingRetriesPreserveTheGuardedIntent() async throws {
    let copied = try revision("Copied")
    let request = CommitRequest(
        action: .copy, itemID: copied.itemID, expectedRevisionID: copied.revisionID, operationID: "fixture")
    let result = CommitResult(revision: copied, wasReplayed: false, isIndexReady: true, warnings: [])
    let transport = try ScriptedTransport([
        reply("error", ["type": "attachmentCopyPending", "description": "Copying", "retryable": true]),
        reply("TractandaItem/commit", object(try MutationReceipt(result))),
    ])
    #expect(try await ItemClient(transport: transport).commit(request).revisionID == copied.revisionID)
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[0] == requests[1])
}

@Test func storeRebuildCallsKeepIntentAndBoundedInt64Progress() async throws {
    let status = StoreRebuildStatus(
        jobID: "70863dec-b0ea-11f1-ae72-842f575e6ac5", operationID: "rebuild-intent",
        state: "running", phase: "verifyingCanonicalClosure", recordsVerified: 1 << 33,
        originalBytesVerified: 1 << 48, documentPagesVerified: 1 << 34,
        updatedAt: "2026-10-11T18:00:00Z")
    let bytes = try JSON.encode(status)
    #expect(bytes.count < 4096)
    let value = try JSONSerialization.jsonObject(with: bytes)
    let transport = ScriptedTransport([
        try reply("TractandaStore/rebuild", value), try reply("TractandaStore/rebuildStatus", value),
        try reply("TractandaStore/rebuildCancel", value),
    ])
    let client = ItemClient(transport: transport)
    #expect(try await client.beginStoreRebuild(operationID: "rebuild-intent") == status)
    #expect(try await client.storeRebuildStatus(jobID: status.jobID) == status)
    #expect(try await client.cancelStoreRebuild(jobID: status.jobID) == status)
    let sent = await transport.requests
    let begin = try JSONSerialization.jsonObject(with: sent[0]) as! [String: Any]
    let args = (begin["methodCalls"] as! [[Any]])[0][1] as! [String: String]
    #expect(args == ["operationID": "rebuild-intent", "accountId": "00112233-4455-6677-8899-aabbccddeeff"])
}

@Test func documentJobsUseCompactLifecycleAndPreserveInt64PageOrdinals() async throws {
    let id = "f37f6680-a69d-11f1-8d84-842f575e6ac5"
    let status = DocumentJobStatus(
        jobID: id, itemID: id, attachmentID: id, sourceRevisionID: id,
        expectedRevisionID: id, state: "running", reasonCode: nil, pageCount: Int64.max,
        acceptedPages: 0, coverage: try DocumentCoverage(converted: 0), discarded: false, committed: nil)
    let page = DocumentJobPage(
        jobID: id,
        outcome: try DocumentStoredPage(
            pageNumber: Int64.max,
            sourceSHA256: String(repeating: "a", count: 64), status: "unsupported", failureCode: "explicit"))
    let methods = ["start", "status", "cancel", "resume", "rebase", "page", "list", "discard"]
    let responses = try methods.map { method in
        let value: Any
        if method == "page" {
            value = try object(page)
        } else if method == "list" {
            value = try object(DocumentJobList(jobs: [status], nextJobID: nil))
        } else {
            value = try object(status)
        }
        return try reply("TractandaDocumentJob/" + method, value)
    }
    let transport = ScriptedTransport(responses)
    let client = ItemClient(transport: transport)
    _ = try await client.startDocumentJob(
        DocumentJobStart(itemID: id, expectedRevisionID: id, attachmentID: id, operationID: "job"))
    _ = try await client.documentJob(id)
    _ = try await client.cancelDocumentJob(id)
    _ = try await client.resumeDocumentJob(id)
    _ = try await client.rebaseDocumentJob(id, expectedRevisionID: id)
    #expect(try await client.documentJobPage(id, pageNumber: Int64.max).outcome.pageNumber == Int64.max)
    _ = try await client.documentJobs(afterJobID: id, limit: 1)
    _ = try await client.discardDocumentJob(id)
    let requests = await transport.requests
    #expect(requests.count == 8)
    let wire = try #require(String(data: requests[5], encoding: .utf8)).filter { !$0.isWhitespace }
    #expect(wire.contains("\"pageNumber\":" + String(Int64.max)))
    #expect(try JSON.encode(page).count < 512)
}
@Test func documentJobProvisionalFlagAndCountsCannotMasqueradeAsCanonical() async throws {
    let id = "f37f6680-a69d-11f1-8d84-842f575e6ac5"
    let outcome = try DocumentStoredPage(
        pageNumber: 1, sourceSHA256: String(repeating: "a", count: 64), status: "failed",
        failureCode: "explicit")
    let transport = ScriptedTransport([
        try reply(
            "TractandaDocumentJob/page", ["jobID": id, "provisional": false, "outcome": object(outcome)])
    ])
    await #expect(throws: (any Error).self) {
        try await ItemClient(transport: transport).documentJobPage(id, pageNumber: 1)
    }
    let malformed = DocumentJobStatus(
        jobID: id, itemID: id, attachmentID: id, sourceRevisionID: id,
        expectedRevisionID: id, state: "completed", reasonCode: nil, pageCount: 100, acceptedPages: 1,
        coverage: try DocumentCoverage(converted: 1), discarded: false, committed: nil)
    #expect(throws: (any Error).self) { try malformed.validate() }
}

@Test func acknowledgedRevisionReadPinsTheImmutableID() async throws {
    let saved = try revision("Saved")
    let transport = try ScriptedTransport([
        reply("TractandaRevision/get", ["revision": object(saved)])
    ])
    let loaded = try await ItemClient(transport: transport).revision(
        itemID: saved.itemID, revisionID: saved.revisionID)
    #expect(loaded == saved)
    let request = try JSONSerialization.jsonObject(with: await transport.requests[0]) as! [String: Any]
    let args = (request["methodCalls"] as! [[Any]])[0][1] as! [String: Any]
    #expect(args["ids"] as? [String] == [saved.revisionID])
}

@Test func oldFullCommitWireResultIsRejected() async throws {
    let saved = try revision("Old wire")
    let transport = try ScriptedTransport([
        reply(
            "TractandaItem/commit",
            object(
                CommitResult(
                    revision: saved, wasReplayed: false, isIndexReady: true, warnings: [])))
    ])
    do {
        _ = try await ItemClient(transport: transport).commit(
            CommitRequest(classID: "Item", operationID: "fixture"))
        Issue.record("Old full wire DTO was accepted")
    } catch { #expect(error is TractandaError) }
}

@Test func requestProblemsAreTranslatedAcrossBothNativeClients() async throws {
    for code in ["notJSON", "notRequest", "unknownCapability", "limit"] {
        let problem = try JSONSerialization.data(withJSONObject: [
            "type": "urn:ietf:params:jmap:error:" + code, "status": 400,
        ])
        let transport = ScriptedTransport([problem])
        do {
            let _: [String: String] = try await ItemClient(transport: transport).call(
                "Core/echo", arguments: ["value": "echo"], returning: [String: String].self)
            Issue.record("Request problem accepted")
        } catch let error as TractandaError { #expect(error.code == code) }
        do {
            _ = try NativeMethodResult.unwrap(problem, method: "Core/echo")
            Issue.record("Native unwrapping accepted a request problem")
        } catch let error as TractandaError { #expect(error.code == code) }
        let request = try JSONSerialization.jsonObject(with: await transport.requests[0]) as! [String: Any]
        #expect((request["using"] as? [String])?.contains("urn:ietf:params:jmap:core") == true)
    }
}
