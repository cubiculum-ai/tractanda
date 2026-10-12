import Foundation

/// A transport owns framing, connection identity and cancellation for one native request.
/// Browser and local clients use the same method contract above this boundary.
public protocol ItemTransport: Sendable {
    func send(_ request: Data) async throws -> Data
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

    public init(
        expression: String? = nil, text: String? = nil, categoryPath: [String] = [],
        position: Int = 0, limit: Int = 64, sort: [ItemSort] = [], excludedCategoryIDs: [String] = [],
        cursor: String? = nil, at: String? = nil, timeZone: String? = nil
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
    }

    private enum CodingKeys: String, CodingKey {
        case expression, text, categoryPath, excludedCategoryIDs, position, limit, sort, cursor, at, timeZone
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(expression, forKey: .expression)
        try container.encodeIfPresent(text, forKey: .text)
        if !categoryPath.isEmpty { try container.encode(categoryPath, forKey: .categoryPath) }
        if !excludedCategoryIDs.isEmpty {
            try container.encode(excludedCategoryIDs, forKey: .excludedCategoryIDs)
        }
        if cursor == nil { try container.encode(position, forKey: .position) }
        try container.encode(limit, forKey: .limit)
        if !sort.isEmpty { try container.encode(sort, forKey: .sort) }
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encodeIfPresent(at, forKey: .at)
        try container.encodeIfPresent(timeZone, forKey: .timeZone)
    }
}

public struct ItemPage: Sendable, Equatable {
    public let items: [Revision]
    public let position: Int
    public let total: Int
    public let state: String
    public let nextCursor: String?
    public let previousCursor: String?
    public var hasNextPage: Bool { position + items.count < total }
}

/// Typed, asynchronous access to the existing native protocol. No database or OS-account dependency.
public struct ItemClient: Sendable {
    public static let capability = "https://tractanda.ai/ns/local-prototype/4"
    public static let queryProfile = "tractanda.spotlight.v0"
    public static let maximumMessageBytes = 8 * 1024 * 1024
    private let transport: any ItemTransport

    public init(transport: any ItemTransport) { self.transport = transport }

    public func call<Arguments: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, arguments: Arguments, returning: Result.Type
    ) async throws -> Result {
        try Task.checkCancellation()
        let request = try JSON.encode(MethodRequest(method: method, arguments: arguments))
        guard request.count <= Self.maximumMessageBytes else {
            throw TractandaError("requestLimit", "Request exceeds the native message limit.")
        }
        let data = try await transport.send(request)
        try Task.checkCancellation()
        guard data.count <= Self.maximumMessageBytes else {
            throw TractandaError("responseLimit", "Response exceeds the native message limit.")
        }
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
        let result: GetResult = try await call(
            "TractandaItem/get", arguments: GetRequest(ids: [itemID]), returning: GetResult.self)
        guard result.notFound.isEmpty, result.list.count == 1,
            result.list[0].itemID == itemID
        else { throw TractandaError("notFound", "Item is unavailable.") }
        return result.list[0]
    }

    /// Query and get are checked against the same authorized store state; partial pages are rejected.
    public func page(matching query: ItemQuery, requiring state: String? = nil) async throws -> ItemPage {
        guard query.position >= 0, (1...256).contains(query.limit), query.categoryPath.count <= 32,
            query.excludedCategoryIDs.count <= 32
        else {
            throw TractandaError("invalidArguments", "Invalid query page or category path.")
        }
        try ItemSort.validate(query.sort)
        let page: QueryResult = try await call(
            "TractandaItem/query", arguments: query, returning: QueryResult.self)
        guard query.cursor != nil || page.position == query.position, page.total >= 0,
            !page.queryState.isEmpty,
            page.ids.count <= query.limit, Set(page.ids).count == page.ids.count,
            page.ids.isEmpty || (page.position <= page.total && page.ids.count <= page.total - page.position),
            !page.ids.isEmpty || page.position >= page.total
        else { throw TractandaError("protocolError", "Invalid query result page.") }
        if let state, state != page.queryState {
            throw TractandaError("stateChanged", "Items changed; refresh from the first page.")
        }
        let result: GetResult = try await call(
            "TractandaItem/get", arguments: GetRequest(ids: page.ids), returning: GetResult.self)
        guard result.state == page.queryState, result.notFound.isEmpty else {
            throw TractandaError("stateChanged", "Items changed while loading; refresh the view.")
        }
        guard result.list.count == page.ids.count,
            Set(result.list.map(\.itemID)) == Set(page.ids)
        else { throw TractandaError("protocolError", "Missing or duplicate item in query results.") }
        let byID = Dictionary(uniqueKeysWithValues: result.list.map { ($0.itemID, $0) })
        return ItemPage(
            items: page.ids.compactMap { byID[$0] }, position: page.position, total: page.total,
            state: page.queryState, nextCursor: page.nextCursor, previousCursor: page.previousCursor)
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
    public func commit(_ request: CommitRequest) async throws -> CommitResult {
        let result: CommitResult
        while true {
            try Task.checkCancellation()
            do {
                result = try await call(
                    "TractandaItem/commit", arguments: request, returning: CommitResult.self)
                break
            } catch let error as TractandaError where error.code == "attachmentCopyPending" {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard result.revision.fields["operationID"]?.string == request.operationID,
            request.action == .create || request.action == .copy || result.revision.itemID == request.itemID
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
    public func extractAttachmentDocument(
        itemID: String, expectedRevisionID: String, attachmentID: String, operationID: String
    ) async throws -> AttachmentCommitResult {
        try await call(
            "TractandaAttachment/extractDocument",
            arguments: AttachmentDocumentExtractRequest(
                itemID: itemID, expectedRevisionID: expectedRevisionID,
                attachmentID: attachmentID, operationID: operationID),
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

private struct GetRequest: Encodable, Sendable { let ids: [String] }
private struct GetResult: Decodable, Sendable {
    let list: [Revision]
    let notFound: [String]
    let state: String
}
private struct QueryResult: Decodable, Sendable {
    let ids: [String]
    let position: Int
    let total: Int
    let queryState: String
    let nextCursor: String?
    let previousCursor: String?
}

private struct MethodRequest<Arguments: Encodable>: Encodable {
    let method: String
    let arguments: Arguments
    private enum CodingKeys: String, CodingKey { case using, methodCalls }
    func encode(to encoder: any Encoder) throws {
        var envelope = encoder.container(keyedBy: CodingKeys.self)
        try envelope.encode([ItemClient.capability], forKey: .using)
        var calls = envelope.nestedUnkeyedContainer(forKey: .methodCalls)
        var call = calls.nestedUnkeyedContainer()
        try call.encode(method)
        try call.encode(arguments)
        try call.encode("client")
    }
}

private struct MethodResponse<Result: Decodable>: Decodable {
    let method: String
    let result: Result
    let callID: String
    private enum CodingKeys: String, CodingKey { case methodResponses, code, message }
    private struct Failure: Decodable {
        let type: String
        let description: String
    }
    init(from decoder: any Decoder) throws {
        let envelope = try decoder.container(keyedBy: CodingKeys.self)
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
            throw TractandaError(failure.type, failure.description)
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
private struct AttachmentDocumentExtractRequest: Encodable, Sendable {
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
