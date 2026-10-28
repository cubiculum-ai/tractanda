import Foundation

/// A transport owns framing, connection identity and cancellation for one native request.
/// Browser and local clients use the same method contract above this boundary.
public protocol ItemTransport: Sendable {
    func send(_ request: Data) async throws -> Data
    /// Change this value whenever endpoint selection or authentication changes.
    func discoveryContext() async throws -> String
}

extension ItemTransport {
    public func discoveryContext() async throws -> String { "transport" }
}

public struct ItemQuery: Codable, Equatable, Sendable {
    public var expression: String?
    public var text: String?
    public var categoryPath: [String]
    public var excludedCategoryIDs: [String]
    public var position: Int
    public var limit: Int
    public var sort: [ItemSort]
    public var cursor: String?
    public var at: String?
    public var timeZone: String?
    public var anchor: String?
    public var anchorOffset: Int

    public init(
        expression: String? = nil, text: String? = nil, categoryPath: [String] = [],
        position: Int = 0, limit: Int = 64, sort: [ItemSort] = [], excludedCategoryIDs: [String] = [],
        cursor: String? = nil, at: String? = nil, timeZone: String? = nil,
        anchor: String? = nil, anchorOffset: Int = 0
    ) {
        self.expression = expression
        self.text = text
        self.categoryPath = categoryPath
        self.excludedCategoryIDs = excludedCategoryIDs
        self.position = position
        self.limit = limit
        self.sort = sort
        self.cursor = cursor
        self.at = at
        self.timeZone = timeZone
        self.anchor = anchor
        self.anchorOffset = anchorOffset
    }

    private enum CodingKeys: String, CodingKey {
        case filter, position, limit, sort, cursor, calculateTotal, anchor, anchorOffset
    }
    private struct Filter: Codable {
        let expression: String?
        let text: String?
        let categoryPath: [String]?
        let excludedCategoryIDs: [String]?
        let at: String?
        let timeZone: String?
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let filter = try c.decodeIfPresent(Filter.self, forKey: .filter)
        try self.init(
            expression: filter?.expression, text: filter?.text, categoryPath: filter?.categoryPath ?? [],
            position: c.decodeIfPresent(Int.self, forKey: .position) ?? 0,
            limit: c.decodeIfPresent(Int.self, forKey: .limit) ?? 64,
            sort: c.decodeIfPresent([JMAPReadComparator].self, forKey: .sort)?.map {
                try $0.itemSort(supportedCollations: ["i;unicode-casemap"])
            } ?? [],
            excludedCategoryIDs: filter?.excludedCategoryIDs ?? [],
            cursor: c.decodeIfPresent(String.self, forKey: .cursor),
            at: filter?.at, timeZone: filter?.timeZone,
            anchor: c.decodeIfPresent(String.self, forKey: .anchor),
            anchorOffset: c.decodeIfPresent(Int.self, forKey: .anchorOffset) ?? 0)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(
            Filter(
                expression: expression, text: text, categoryPath: categoryPath.isEmpty ? nil : categoryPath,
                excludedCategoryIDs: excludedCategoryIDs.isEmpty ? nil : excludedCategoryIDs, at: at,
                timeZone: timeZone), forKey: .filter)
        if cursor == nil && anchor == nil { try c.encode(position, forKey: .position) }
        try c.encodeIfPresent(anchor, forKey: .anchor)
        if anchor != nil { try c.encode(anchorOffset, forKey: .anchorOffset) }
        try c.encode(limit, forKey: .limit)
        try c.encode(true, forKey: .calculateTotal)
        if !sort.isEmpty { try c.encode(sort.map(JMAPReadComparator.init), forKey: .sort) }
        try c.encodeIfPresent(cursor, forKey: .cursor)
    }

}

public struct ItemPage: Sendable, Equatable {
    public let items: [Revision]
    public let position: Int
    /// Number of query IDs consumed, independent of how many current revisions were hydrated.
    public let consumedCount: Int
    public let total: Int
    public let state: String
    public let nextCursor: String?
    public let previousCursor: String?
    public let unresolved: [ItemUnresolvedState]
    public let notFound: [String]
    public let remainingIDs: [String]
    public let oversizedIDs: [String]
    public let historicalDispositions: [String: HistoricalDisposition]
    public let completeness: Completeness
    public let conflictsAvailable: Bool
    public enum Completeness: String, Codable, Sendable { case complete, unresolvedItems }
    public var hasNextPage: Bool { position + consumedCount < total }
}

/// Typed, asynchronous access to the existing native protocol. No database or OS-account dependency.
public struct ItemClient: Sendable {
    public static let capability = TractandaJMAP.capability
    public static let queryProfile = "tractanda.spotlight.v0"
    public static let maximumMessageBytes = 8 * 1024 * 1024
    private let context: JMAPClientContext

    public init(transport: any ItemTransport) { context = JMAPClientContext(transport: transport) }

    /// Required when a transport changes authentication without a discoveryContext implementation.
    public func invalidateSession() async { await context.invalidate() }

    public func call<Arguments: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, arguments: Arguments, returning: Result.Type
    ) async throws -> Result {
        try Task.checkCancellation()
        let wireData = try await context.send(
            method: method, arguments: JMAPValue.decode(JSON.encode(arguments)))
        let envelope = try JMAPValue.decode(wireData)
        let normalized = try JMAPValue.object(
            (envelope.members ?? []).map { member in
                guard member.name == "methodResponses", let calls = member.value.elements else {
                    return member
                }
                return JMAPMember(
                    member.name,
                    .array(
                        try calls.map { call in
                            guard let values = call.elements, values.count == 3, values[0].text == method
                            else { return call }
                            return .array([
                                values[0],
                                try TractandaJMAPCodec.extensionResultFromWire(
                                    method: method, result: values[1]), values[2],
                            ])
                        }))
            })
        let data = try normalized.encoded()
        try Task.checkCancellation()
        let response: MethodResponse<Result>
        do {
            response = try JSON.decode(MethodResponse<Result>.self, data)
        } catch let error as TractandaError {
            throw error
        } catch {
            throw TractandaError("protocolError", "The server returned an invalid native response.")
        }
        guard response.method == method, response.callID == "client" else {
            throw TractandaError("protocolError", "Native response does not match the request.")
        }
        return response.result
    }

    public func revision(for itemID: String) async throws -> Revision {
        let result = try await items(ids: [itemID])
        if result.unresolved.contains(where: { $0.itemID == itemID }) {
            throw TractandaError("itemUnresolved", "Item has no current representative; inspect its state.")
        }
        if result.oversizedIDs.contains(itemID) {
            throw TractandaError("responseTooLarge", "Use a narrower item projection.")
        }
        if result.remainingIDs.contains(itemID) {
            throw TractandaError("itemIncomplete", "Item remains unprocessed; continue the bounded get.")
        }
        if result.notFound.contains(itemID) { throw TractandaError("notFound", "Item is unavailable.") }
        guard result.list.count == 1, result.list[0].itemID == itemID else {
            throw TractandaError("protocolError", "Single-item get returned no classified result.")
        }
        return result.list[0]
    }

    public func revision(itemID: String, revisionID: String) async throws -> Revision {
        try Identifier.validate(itemID)
        try Identifier.validate(revisionID)
        let result = try await call(
            "TractandaRevision/get", arguments: ["ids": [revisionID]], returning: JMAPRevisionGetResponse.self
        )
        guard result.notFound.isEmpty, result.list.count == 1 else {
            throw TractandaError("notFound", "Revision is unavailable.")
        }
        let revision = try result.list[0].canonicalRevision()
        guard revision.itemID == itemID, revision.revisionID == revisionID else {
            throw TractandaError("protocolError", "Exact revision response does not match its request.")
        }
        return revision
    }

    /// Query/get share one caller-visible state; unresolved and byte-limited outcomes remain explicit.
    public func page(matching query: ItemQuery, requiring state: String? = nil) async throws -> ItemPage {
        guard (0...256).contains(query.limit), query.categoryPath.count <= 32,
            query.excludedCategoryIDs.count <= 32
        else {
            throw TractandaError("invalidArguments", "Invalid query page or category path.")
        }
        try ItemSort.validate(query.sort)
        let itemState = try await itemRecords(ids: []).state
        let page: QueryResult = try await call(
            "TractandaItem/query", arguments: query, returning: QueryResult.self)
        guard page.total >= 0,
            query.cursor != nil || query.anchor != nil
                || page.position
                    == (query.position < 0 ? max(0, page.total + query.position) : query.position),
            !page.queryState.isEmpty,
            page.ids.count <= query.limit, Set(page.ids).count == page.ids.count,
            page.ids.isEmpty || (page.position <= page.total && page.ids.count <= page.total - page.position),
            query.limit == 0 || !page.ids.isEmpty || page.position >= page.total
        else { throw TractandaError("protocolError", "Invalid query result page.") }
        if let state, state != page.queryState {
            throw TractandaError("stateChanged", "Items changed; refresh from the first page.")
        }
        let chunks = stride(from: 0, to: page.ids.count, by: 64).map {
            Array(page.ids[$0..<min($0 + 64, page.ids.count)])
        }
        var fetched: [ItemGetResult] = []
        for ids in chunks {
            let result = try await items(ids: ids)
            guard result.state == itemState else {
                throw TractandaError("stateChanged", "Items changed while loading; refresh the view.")
            }
            fetched.append(result)
        }
        let list = fetched.flatMap(\.list)
        let unresolved = fetched.flatMap(\.unresolved)
        let notFound = fetched.flatMap(\.notFound)
        let remainingIDs = fetched.flatMap(\.remainingIDs)
        let oversizedIDs = fetched.flatMap(\.oversizedIDs)
        let dispositionPairs = fetched.flatMap { Array($0.historicalDispositions) }
        let historicalDispositions = Dictionary(
            dispositionPairs,
            uniquingKeysWith: { first, second in
                first
            })
        guard historicalDispositions.count == dispositionPairs.count else {
            throw TractandaError("protocolError", "Duplicate historical disposition revision ID.")
        }
        let seenIDs = list.map(\.itemID) + unresolved.map(\.itemID) + notFound + remainingIDs + oversizedIDs
        guard Set(seenIDs).count == seenIDs.count, Set(seenIDs) == Set(page.ids) else {
            throw TractandaError("protocolError", "Missing, duplicate, or unclassified query result ID.")
        }
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.itemID, $0) })
        let unresolvedByID = Dictionary(uniqueKeysWithValues: unresolved.map { ($0.itemID, $0) })
        let completeness: ItemPage.Completeness =
            unresolved.isEmpty && page.completeness != .unresolvedItems ? .complete : .unresolvedItems
        guard try await itemRecords(ids: []).state == itemState else {
            throw TractandaError("stateChanged", "Items changed while loading; refresh the view.")
        }
        return ItemPage(
            items: page.ids.compactMap { byID[$0] }, position: page.position,
            consumedCount: page.ids.count, total: page.total, state: page.queryState,
            nextCursor: page.nextCursor, previousCursor: page.previousCursor,
            unresolved: page.ids.compactMap { unresolvedByID[$0] }, notFound: notFound,
            remainingIDs: remainingIDs, oversizedIDs: oversizedIDs,
            historicalDispositions: historicalDispositions, completeness: completeness,
            conflictsAvailable: page.conflictsAvailable ?? !unresolved.isEmpty)
    }

    public func itemStates(ids: [String], maxBytes: Int = 65_536) async throws -> ItemStateResult {
        try Self.validateIDs(ids)
        guard (8_192...524_288).contains(maxBytes) else {
            throw TractandaError("invalidArguments", "maxBytes must be 8192 through 524288.")
        }
        let result = try await call(
            "TractandaItem/state", arguments: StateRequest(ids: ids, maxBytes: maxBytes),
            returning: ItemStateResult.self)
        try result.validate(requestedIDs: ids)
        return result
    }

    /// Full-content convenience API. Partial DTO selections remain explicit in itemRecords().
    public func items(ids: [String], maxBytes: Int = 524_288) async throws -> ItemGetResult {
        let wire = try await itemRecords(ids: ids, maxBytes: maxBytes)
        let result = try wire.canonicalResult()
        try result.validate(requestedIDs: Array(Set(ids)))
        return result
    }

    /// Standard get is complete; supplying maxBytes selects the named bounded extension.
    public func itemRecords(
        ids: [String], properties: [String]? = nil, fieldProperties: [String]? = nil,
        projection: String? = nil, maxBytes: Int? = nil
    ) async throws -> JMAPItemGetResponse {
        _ = try JMAPGetIDs.normalize(ids, maximum: 64)
        _ = try JMAPReadProperties(properties, record: .item)
        guard !(projection != nil && fieldProperties != nil),
            maxBytes.map({ (8_192...524_288).contains($0) }) ?? true
        else {
            throw TractandaError("invalidArguments", "Invalid fields selection or maxBytes.")
        }
        return try await call(
            maxBytes == nil ? "TractandaItem/get" : "TractandaItem/getBounded",
            arguments: GetRequest(
                ids: ids, projection: projection, properties: properties,
                fieldProperties: fieldProperties, maxBytes: maxBytes), returning: JMAPItemGetResponse.self)
    }

    public func history(itemID: String, position: Int = 0, limit: Int = 100) async throws -> ItemHistoryResult
    {
        let wire = try await historyRecords(itemID: itemID, position: position, limit: limit)
        return try wire.canonicalResult(itemID: itemID, position: position, limit: limit)
    }

    public func historyRecords(
        itemID: String, position: Int = 0, limit: Int = 100,
        properties: [String]? = nil, fieldProperties: [String]? = nil, projection: String? = nil
    ) async throws -> JMAPHistoryResponse {
        try Identifier.validate(itemID)
        guard position >= 0, (1...256).contains(limit), !(projection != nil && fieldProperties != nil) else {
            throw TractandaError("invalidArguments", "Invalid history page or fields selection.")
        }
        _ = try JMAPReadProperties(properties, record: .revision)
        return try await call(
            "TractandaItem/history",
            arguments: HistoryRequest(
                itemID: itemID,
                position: position, limit: limit, projection: projection, properties: properties,
                fieldProperties: fieldProperties),
            returning: JMAPHistoryResponse.self)
    }

    public func conflicts(limit: Int = 64, cursor: String? = nil) async throws -> ItemConflictPage {
        guard (1...256).contains(limit), (cursor?.utf8.count ?? 0) <= 8_192 else {
            throw TractandaError("invalidArguments", "Invalid conflict page limit or cursor.")
        }
        let page = try await call(
            "TractandaItem/conflicts", arguments: ConflictPageRequest(limit: limit, cursor: cursor),
            returning: ItemConflictPage.self)
        guard !page.state.isEmpty, page.list.count <= limit, (page.nextCursor?.utf8.count ?? 0) <= 8_192,
            Set(page.list.map(\.itemID)).count == page.list.count,
            page.list.allSatisfy({ !$0.stateToken.isEmpty })
        else { throw TractandaError("protocolError", "Invalid conflict page result.") }
        return page
    }

    public func resolveConflict(_ request: ResolveConflictRequest) async throws -> MutationReceipt {
        try Identifier.validate(request.itemID)
        guard !request.expectedStateToken.isEmpty, request.expectedStateToken.utf8.count <= 8_192,
            !request.reviewedFrontier.isEmpty, request.reviewedFrontier.count <= 1024,
            Set(request.reviewedFrontier).count == request.reviewedFrontier.count,
            !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
            !request.operationID.contains("\0"), Set(request.unset).count == request.unset.count,
            Set(request.changes.keys).isDisjoint(with: request.unset)
        else { throw TractandaError("invalidArguments", "Invalid conflict resolution request.") }
        for id in request.reviewedFrontier { try Identifier.validate(id) }
        let result = try await call(
            "TractandaItem/resolveConflict", arguments: request, returning: MutationReceipt.self)
        guard result.itemID == request.itemID,
            result.operationID == request.operationID
        else {
            throw TractandaError("protocolError", "Conflict resolution receipt does not match its request.")
        }
        return result
    }

    private static func validateIDs(_ ids: [String]) throws {
        guard (1...64).contains(ids.count), Set(ids).count == ids.count else {
            throw TractandaError("invalidArguments", "Supply 1 through 64 distinct item IDs.")
        }
        for id in ids { try Identifier.validate(id) }
    }

    public func beginStoreRebuild(operationID: String) async throws -> StoreRebuildStatus {
        let status = try await call(
            "TractandaStore/rebuild", arguments: ["operationID": operationID],
            returning: StoreRebuildStatus.self)
        try status.validate()
        guard status.operationID == operationID else {
            throw TractandaError("protocolError", "Rebuild intent changed.")
        }
        return status
    }
    public func storeRebuildStatus(jobID: String? = nil) async throws -> StoreRebuildStatus {
        let status = try await call(
            "TractandaStore/rebuildStatus", arguments: jobID.map { ["jobID": $0] } ?? [:],
            returning: StoreRebuildStatus.self)
        try status.validate()
        guard jobID == nil || status.jobID == jobID else {
            throw TractandaError("protocolError", "Rebuild identity changed.")
        }
        return status
    }
    public func cancelStoreRebuild(jobID: String) async throws -> StoreRebuildStatus {
        let status = try await call(
            "TractandaStore/rebuildCancel", arguments: ["jobID": jobID], returning: StoreRebuildStatus.self)
        try status.validate()
        guard status.jobID == jobID else {
            throw TractandaError("protocolError", "Rebuild identity changed.")
        }
        return status
    }
    public func commit(_ request: CommitRequest) async throws -> MutationReceipt {
        let result: MutationReceipt
        while true {
            try Task.checkCancellation()
            do {
                result = try await call(
                    "TractandaItem/commit", arguments: request, returning: MutationReceipt.self)
                break
            } catch let error as TractandaError where error.code == "attachmentCopyPending" {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard result.operationID == request.operationID,
            request.action == .create || request.action == .copy || result.itemID == request.itemID
        else { throw TractandaError("protocolError", "Commit receipt does not match the pending edit.") }
        return result
    }
    public func extractAttachmentText(
        itemID: String, expectedRevisionID: String,
        attachmentID: String, operationID: String
    ) async throws -> AttachmentCommitResult {
        try await call(
            "TractandaAttachment/extractText",
            arguments: AttachmentDetachRequest(
                itemID: itemID,
                expectedRevisionID: expectedRevisionID, attachmentID: attachmentID, operationID: operationID),
            returning: AttachmentCommitResult.self)
    }
    public func attachmentDocument(
        itemID: String, attachmentID: String, revisionID: String? = nil,
        pageNumber: Int? = nil, maxBytes: Int = 1_048_576
    ) async throws -> AttachmentDocumentReadResult {
        try await call(
            "TractandaAttachment/document",
            arguments: AttachmentDocumentReadRequest(
                itemID: itemID, attachmentID: attachmentID, revisionID: revisionID,
                pageNumber: pageNumber, maxBytes: maxBytes),
            returning: AttachmentDocumentReadResult.self)
    }
    public func documentContentPart(
        itemID: String, attachmentID: String, revisionID: String? = nil,
        kind: String, level: Int = 0, index: Int64 = 0, offset: Int64 = 0, limit: Int = 262_144
    ) async throws -> DocumentContentPart {
        try await call(
            "TractandaAttachment/documentContent",
            arguments: DocumentContentPartRequest(
                itemID: itemID,
                attachmentID: attachmentID, revisionID: revisionID, kind: kind, level: level, index: index,
                offset: offset, limit: limit),
            returning: DocumentContentPart.self)
    }
    public func beginAttachment(_ request: AttachmentUploadRequest) async throws -> AttachmentUploadResult {
        try await call(
            "TractandaAttachment/begin", arguments: request, returning: AttachmentUploadResult.self)
    }
    public func appendAttachment(uploadID: String, offset: Int64, data: Data) async throws -> Int64 {
        guard data.count <= 262_144 else {
            throw TractandaError("invalidArguments", "Chunk exceeds 256 KiB.")
        }
        let result = try await call(
            "TractandaAttachment/upload",
            arguments: AttachmentChunkRequest(uploadID: uploadID, offset: offset, data: data),
            returning: AttachmentChunkResult.self)
        return result.offset
    }
    public func finishAttachment(uploadID: String) async throws -> AttachmentCommitResult {
        while true {
            try Task.checkCancellation()
            do {
                return try await call(
                    "TractandaAttachment/finish", arguments: AttachmentUploadID(uploadID: uploadID),
                    returning: AttachmentCommitResult.self)
            } catch let error as TractandaError where error.code == "attachmentVerifying" {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    public func attachmentUploadStatus(uploadID: String) async throws -> AttachmentIntegrityStatus {
        try await call(
            "TractandaAttachment/uploadStatus", arguments: AttachmentUploadID(uploadID: uploadID),
            returning: AttachmentIntegrityStatus.self)
    }
    public func attachmentIntegrityStatus(itemID: String, revisionID: String? = nil, attachmentID: String)
        async throws -> AttachmentIntegrityStatus
    {
        try await call(
            "TractandaAttachment/integrity",
            arguments: AttachmentListRequestWithID(
                itemID: itemID, revisionID: revisionID, attachmentID: attachmentID),
            returning: AttachmentIntegrityStatus.self)
    }
    public func abortAttachment(uploadID: String) async throws {
        _ = try await call(
            "TractandaAttachment/abort", arguments: AttachmentUploadID(uploadID: uploadID),
            returning: AttachmentAbortResult.self)
    }
    public func listAttachments(itemID: String, revisionID: String? = nil) async throws
        -> AttachmentListResult
    {
        try await call(
            "TractandaAttachment/list",
            arguments: AttachmentListRequest(itemID: itemID, revisionID: revisionID),
            returning: AttachmentListResult.self)
    }
    public func attachmentContent(
        itemID: String, revisionID: String? = nil, attachmentID: String, offset: Int64 = 0,
        limit: Int = 262_144
    ) async throws -> AttachmentContentResult {
        while true {
            try Task.checkCancellation()
            do {
                return try await call(
                    "TractandaAttachment/content",
                    arguments: AttachmentContentRequest(
                        itemID: itemID, revisionID: revisionID, attachmentID: attachmentID, offset: offset,
                        limit: limit), returning: AttachmentContentResult.self)
            } catch let error as TractandaError where error.code == "attachmentVerifying" {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    public func detachAttachment(
        itemID: String, expectedRevisionID: String, attachmentID: String, operationID: String
    ) async throws -> AttachmentCommitResult {
        try await call(
            "TractandaAttachment/detach",
            arguments: AttachmentDetachRequest(
                itemID: itemID, expectedRevisionID: expectedRevisionID, attachmentID: attachmentID,
                operationID: operationID), returning: AttachmentCommitResult.self)
    }

}

private struct GetRequest: Encodable, Sendable {
    let ids: [String]
    let projection: String?
    let properties: [String]?
    let fieldProperties: [String]?
    let maxBytes: Int?
}
private struct HistoryRequest: Encodable, Sendable {
    let itemID: String
    let position: Int
    let limit: Int
    let projection: String?
    let properties: [String]?
    let fieldProperties: [String]?
}
private struct StateRequest: Encodable, Sendable {
    let ids: [String]
    let maxBytes: Int
}
private struct ConflictPageRequest: Encodable, Sendable {
    let limit: Int
    let cursor: String?
}
private struct QueryResult: Decodable, Sendable {
    let ids: [String]
    let position: Int
    let total: Int
    let queryState: String
    let nextCursor: String?
    let previousCursor: String?
    let completeness: ItemPage.Completeness?
    let conflictsAvailable: Bool?
}

extension ItemGetResult {
    fileprivate func validate(requestedIDs: [String]) throws {
        guard !state.isEmpty else { throw TractandaError("protocolError", "Missing get state token.") }
        let returned = list.map(\.itemID)
        let unresolvedIDs = unresolved.map(\.itemID)
        let all = returned + unresolvedIDs + notFound + remainingIDs + oversizedIDs
        guard all.allSatisfy(requestedIDs.contains), Set(all).count == all.count,
            Set(all) == Set(requestedIDs)
        else { throw TractandaError("protocolError", "Get result omitted or repeated requested IDs.") }
        let returnedRevisionIDs = Set(list.map(\.revisionID))
        guard Set(historicalDispositions.keys).isSubset(of: returnedRevisionIDs) else {
            throw TractandaError("protocolError", "Get disposition map names a revision not returned.")
        }
        guard unresolved.allSatisfy({ !$0.stateToken.isEmpty }) else {
            throw TractandaError("protocolError", "Unresolved item state lacks a token.")
        }
    }
}

extension ItemStateResult {
    fileprivate func validate(requestedIDs: [String]) throws {
        guard !state.isEmpty else { throw TractandaError("protocolError", "Missing item state token.") }
        let returned = list.map(\.itemID)
        let all = returned + notFound + remainingIDs + oversizedIDs
        guard all.allSatisfy(requestedIDs.contains), Set(all).count == all.count,
            Set(all) == Set(requestedIDs), list.allSatisfy({ !$0.stateToken.isEmpty })
        else { throw TractandaError("protocolError", "State result omitted or repeated requested IDs.") }
    }
}

private struct MethodResponse<Result: Decodable>: Decodable {
    let method: String
    let result: Result
    let callID: String
    private enum CodingKeys: String, CodingKey { case methodResponses, code, message, type, status }
    private struct Failure: Decodable {
        let type: String
        let description: String?
    }
    init(from decoder: any Decoder) throws {
        let envelope = try decoder.container(keyedBy: CodingKeys.self)
        if let type = try envelope.decodeIfPresent(String.self, forKey: .type),
            type.hasPrefix("urn:ietf:params:jmap:error:"),
            let status = try envelope.decodeIfPresent(Int.self, forKey: .status), (400...599).contains(status)
        {
            let code = String(type.dropFirst("urn:ietf:params:jmap:error:".count))
            guard ["notJSON", "notRequest", "unknownCapability", "limit"].contains(code) else {
                throw TractandaError("protocolError", "Unknown JMAP request problem.")
            }
            throw TractandaError(code, "JMAP request rejected: " + code)
        }
        if envelope.contains(.code) {
            throw TractandaError(
                try envelope.decode(String.self, forKey: .code),
                try envelope.decodeIfPresent(String.self, forKey: .message) ?? "")
        }
        var calls = try envelope.nestedUnkeyedContainer(forKey: .methodResponses)
        guard calls.count == 1 else { throw TractandaError("protocolError", "Expected one response.") }
        var call = try calls.nestedUnkeyedContainer()
        guard call.count == 3 else { throw TractandaError("protocolError", "Invalid method response.") }
        method = try call.decode(String.self)
        if method == "error" {
            let failure = try call.decode(Failure.self)
            guard try call.decode(String.self) == "client" else {
                throw TractandaError("protocolError", "Error response does not match the request.")
            }
            throw TractandaError(failure.type, failure.description ?? "")
        }
        result = try call.decode(Result.self)
        callID = try call.decode(String.self)
    }
}

private struct AttachmentUploadID: Encodable, Sendable { let uploadID: String }
private struct AttachmentChunkRequest: Encodable, Sendable {
    let uploadID: String
    let offset: Int64
    let data: Data
}
private struct AttachmentChunkResult: Decodable, Sendable { let offset: Int64 }
private struct AttachmentAbortResult: Decodable, Sendable { let aborted: Bool }
private struct AttachmentListRequest: Encodable, Sendable {
    let itemID: String
    let revisionID: String?
}
private struct AttachmentContentRequest: Encodable, Sendable {
    let itemID: String
    let revisionID: String?
    let attachmentID: String
    let offset: Int64
    let limit: Int
}
private struct AttachmentDetachRequest: Encodable, Sendable {
    let itemID: String
    let expectedRevisionID: String
    let attachmentID: String
    let operationID: String
}
private struct AttachmentDocumentReadRequest: Encodable, Sendable {
    let itemID: String
    let attachmentID: String
    let revisionID: String?
    let pageNumber: Int?
    let maxBytes: Int
}

private struct AttachmentListRequestWithID: Encodable {
    let itemID: String
    let revisionID: String?
    let attachmentID: String
}

private struct DocumentContentPartRequest: Encodable {
    let itemID: String
    let attachmentID: String
    let revisionID: String?
    let kind: String
    let level: Int
    let index: Int64
    let offset: Int64
    let limit: Int
}
