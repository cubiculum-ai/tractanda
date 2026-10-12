import Foundation

/// A synchronous client for the existing native method envelope.
/// Each instance is confined to its caller; it does not own or bypass an ItemStore.
public final class ItemClient {
    private let transport: (Data) throws -> Data

    public init(socketPath: String) {
        transport = { try LocalTransport.call(socket: socketPath, request: $0) }
    }

    public init(connection: ServerConnection) {
        transport = { try connection.send($0) }
    }

    public init(transport: @escaping (Data) throws -> Data) { self.transport = transport }

    public func call(_ method: String, arguments: [String: Any] = [:]) throws -> Data {
        let envelope: [String: Any] = [
            "using": [ItemService.capability], "methodCalls": [[method, arguments, "client"]],
        ]
        let response = try transport(JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]))
        return try NativeMethodResult.unwrap(response, method: method)
    }

    /// Runs a query and its matching get serially in one native request.
    /// The service resolves `#ids` from the successful query result under the same caller context.
    public func queryThenGet(arguments: [String: Any]) throws -> (query: Data, get: Data) {
        let envelope: [String: Any] = [
            "using": [ItemService.capability],
            "methodCalls": [
                ["TractandaItem/query", arguments, "query"],
                [
                    "TractandaItem/get",
                    ["#ids": ["resultOf": "query", "name": "TractandaItem/query", "path": "/ids"]],
                    "get",
                ],
            ],
        ]
        let response = try transport(JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]))
        guard let decoded = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw TractandaError("protocolError", "Invalid native response.")
        }
        if let code = decoded["code"] as? String {
            throw TractandaError(code, decoded["message"] as? String ?? "")
        }
        guard let calls = decoded["methodResponses"] as? [[Any]], calls.count == 2 else {
            throw TractandaError("protocolError", "Missing paired query/get response.")
        }
        func result(_ call: [Any], method: String, callID: String) throws -> Data {
            guard call.count == 3, call[2] as? String == callID,
                let value = call[1] as? [String: Any]
            else { throw TractandaError("protocolError", "Malformed paired query/get response.") }
            if call[0] as? String == "error" {
                throw TractandaError(
                    value["type"] as? String ?? "error", value["description"] as? String ?? "")
            }
            guard call[0] as? String == method else {
                throw TractandaError("protocolError", "Unexpected paired query/get result.")
            }
            return try JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys])
        }
        return (
            try result(calls[0], method: "TractandaItem/query", callID: "query"),
            try result(calls[1], method: "TractandaItem/get", callID: "get")
        )
    }

    public func revision(for itemID: String) throws -> Revision {
        struct Result: Decodable { let list: [Revision] }
        let result = try JSON.decode(Result.self, call("TractandaItem/get", arguments: ["ids": [itemID]]))
        guard let revision = result.list.first else {
            throw TractandaError("notFound", "Item is unavailable.")
        }
        return revision
    }

    public func beginStoreRebuild(operationID: String) throws -> StoreRebuildStatus {
        let status = try JSON.decode(
            StoreRebuildStatus.self, call("TractandaStore/rebuild", arguments: ["operationID": operationID]))
        try status.validate()
        guard status.operationID == operationID else {
            throw TractandaError("protocolError", "Rebuild intent changed.")
        }
        return status
    }
    public func storeRebuildStatus(jobID: String? = nil) throws -> StoreRebuildStatus {
        let status = try JSON.decode(
            StoreRebuildStatus.self,
            call("TractandaStore/rebuildStatus", arguments: jobID.map { ["jobID": $0] } ?? [:]))
        try status.validate()
        guard jobID == nil || status.jobID == jobID else {
            throw TractandaError("protocolError", "Rebuild identity changed.")
        }
        return status
    }
    public func cancelStoreRebuild(jobID: String) throws -> StoreRebuildStatus {
        let status = try JSON.decode(
            StoreRebuildStatus.self, call("TractandaStore/rebuildCancel", arguments: ["jobID": jobID]))
        try status.validate()
        guard status.jobID == jobID else {
            throw TractandaError("protocolError", "Rebuild identity changed.")
        }
        return status
    }
    public func commit(_ request: CommitRequest) throws -> CommitResult {
        let arguments = try JSONSerialization.jsonObject(with: JSON.encode(request)) as! [String: Any]
        while true {
            try Task.checkCancellation()
            do {
                return try JSON.decode(CommitResult.self, call("TractandaItem/commit", arguments: arguments))
            } catch let error as TractandaError where error.code == "attachmentCopyPending" {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    public func extractAttachmentText(
        itemID: String, expectedRevisionID: String,
        attachmentID: String, operationID: String
    ) throws -> AttachmentCommitResult {
        try JSON.decode(
            AttachmentCommitResult.self,
            call(
                "TractandaAttachment/extractText",
                arguments: [
                    "itemID": itemID, "expectedRevisionID": expectedRevisionID,
                    "attachmentID": attachmentID, "operationID": operationID,
                ]))
    }
    public func documentContentPart(
        itemID: String, attachmentID: String, revisionID: String? = nil,
        kind: String, level: Int = 0, index: Int64 = 0, offset: Int64 = 0, limit: Int = 262_144
    ) throws -> DocumentContentPart {
        var args: [String: Any] = [
            "itemID": itemID, "attachmentID": attachmentID, "kind": kind, "level": level,
            "index": index, "offset": offset, "limit": limit,
        ]
        if let revisionID { args["revisionID"] = revisionID }
        return try JSON.decode(
            DocumentContentPart.self, call("TractandaAttachment/documentContent", arguments: args))
    }
    public func beginAttachment(_ request: AttachmentUploadRequest) throws -> AttachmentUploadResult {
        let args = try JSONSerialization.jsonObject(with: JSON.encode(request)) as! [String: Any]
        return try JSON.decode(
            AttachmentUploadResult.self, call("TractandaAttachment/begin", arguments: args))
    }
    public func appendAttachment(uploadID: String, offset: Int64, data: Data) throws -> Int64 {
        guard data.count <= 262_144 else {
            throw TractandaError("invalidArguments", "Chunk exceeds 256 KiB.")
        }
        struct Result: Decodable { let offset: Int64 }
        return try JSON.decode(
            Result.self,
            call(
                "TractandaAttachment/upload",
                arguments: [
                    "uploadID": uploadID, "offset": offset, "data": data.base64EncodedString(),
                ])
        ).offset
    }
    public func finishAttachment(uploadID: String) throws -> AttachmentCommitResult {
        while true {
            try Task.checkCancellation()
            do {
                return try JSON.decode(
                    AttachmentCommitResult.self,
                    call("TractandaAttachment/finish", arguments: ["uploadID": uploadID]))
            } catch let error as TractandaError where error.code == "attachmentVerifying" {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
    public func attachmentUploadStatus(uploadID: String) throws -> AttachmentIntegrityStatus {
        try JSON.decode(
            AttachmentIntegrityStatus.self,
            call("TractandaAttachment/uploadStatus", arguments: ["uploadID": uploadID]))
    }
    public func attachmentIntegrityStatus(itemID: String, revisionID: String? = nil, attachmentID: String)
        throws -> AttachmentIntegrityStatus
    {
        var args: [String: Any] = ["itemID": itemID, "attachmentID": attachmentID]
        if let revisionID { args["revisionID"] = revisionID }
        return try JSON.decode(
            AttachmentIntegrityStatus.self, call("TractandaAttachment/integrity", arguments: args))
    }
    public func abortAttachment(uploadID: String) throws {
        _ = try call("TractandaAttachment/abort", arguments: ["uploadID": uploadID])
    }
    public func listAttachments(itemID: String, revisionID: String? = nil) throws -> AttachmentListResult {
        var args: [String: Any] = ["itemID": itemID]
        if let revisionID { args["revisionID"] = revisionID }
        return try JSON.decode(AttachmentListResult.self, call("TractandaAttachment/list", arguments: args))
    }
    public func attachmentContent(
        itemID: String, revisionID: String? = nil, attachmentID: String, offset: Int64 = 0,
        limit: Int = 262_144
    ) throws -> AttachmentContentResult {
        var args: [String: Any] = [
            "itemID": itemID, "attachmentID": attachmentID, "offset": offset, "limit": limit,
        ]
        if let revisionID { args["revisionID"] = revisionID }
        while true {
            try Task.checkCancellation()
            do {
                return try JSON.decode(
                    AttachmentContentResult.self, call("TractandaAttachment/content", arguments: args))
            } catch let error as TractandaError where error.code == "attachmentVerifying" {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
    public func detachAttachment(
        itemID: String, expectedRevisionID: String, attachmentID: String, operationID: String
    ) throws -> AttachmentCommitResult {
        try JSON.decode(
            AttachmentCommitResult.self,
            call(
                "TractandaAttachment/detach",
                arguments: [
                    "itemID": itemID, "expectedRevisionID": expectedRevisionID,
                    "attachmentID": attachmentID, "operationID": operationID,
                ]))
    }

    public func state() throws -> String {
        struct Result: Decodable { let state: String }
        return try JSON.decode(Result.self, call("TractandaStore/info")).state
    }

    public func categoryMemberships(
        ids: [String], categoryRootIDs: [String], at: Date = Date()
    ) throws -> CategoryMembershipProjection {
        var uniqueIDs: [String] = []
        for id in ids where !uniqueIDs.contains(id) { uniqueIDs.append(id) }
        guard !categoryRootIDs.isEmpty else {
            throw TractandaError("invalidArguments", "Supply at least one category root.")
        }
        let batches =
            uniqueIDs.isEmpty
            ? [[categoryRootIDs[0]]]
            : stride(
                from: 0, to: uniqueIDs.count, by: 64
            ).map { Array(uniqueIDs[$0..<min($0 + 64, uniqueIDs.count)]) }
        var expectedState: String?
        var roots: [CategoryMembershipRoot] = []
        var memberships: [String: [String: [String]]] = [:]
        var notFound: [String] = []
        for (index, batch) in batches.enumerated() {
            let result = try JSON.decode(
                CategoryMembershipProjection.self,
                call(
                    "TractandaCategory/memberships",
                    arguments: [
                        "ids": batch, "categoryRootIDs": categoryRootIDs, "at": Timestamp.format(at),
                    ]))
            if let expectedState, expectedState != result.state {
                throw TractandaError("stateChanged", "Categories changed while loading memberships.")
            }
            expectedState = result.state
            if index == 0 { roots = result.roots }
            memberships.merge(result.memberships) { _, newer in newer }
            notFound.append(contentsOf: result.notFound)
        }
        if uniqueIDs.isEmpty {
            memberships.removeValue(forKey: categoryRootIDs[0])
            notFound.removeAll { $0 == categoryRootIDs[0] }
        }
        return CategoryMembershipProjection(
            state: expectedState!, roots: roots, memberships: memberships, notFound: notFound)
    }

    public func revisions(matching expression: String? = nil, viewID: String? = nil, sectionID: String? = nil)
        throws -> [Revision]
    {
        var arguments: [String: Any] = [:]
        if let expression { arguments["expression"] = expression }
        if let viewID { arguments["viewID"] = viewID }
        if let sectionID { arguments["sectionID"] = sectionID }
        return try revisions(query: arguments)
    }

    public func revisions(query arguments: [String: Any]) throws -> [Revision] {
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
        var position = 0
        let queryDate = Timestamp.now()
        var revisions: [Revision] = []
        var initialState: String?
        repeat {
            var arguments = arguments
            arguments["position"] = position
            arguments["limit"] = 64
            arguments["at"] = queryDate
            let page = try JSON.decode(QueryResult.self, call("TractandaItem/query", arguments: arguments))
            if let initialState, initialState != page.queryState {
                throw TractandaError("stateChanged", "Refresh the changing board.")
            }
            initialState = page.queryState
            if !page.ids.isEmpty {
                let result = try JSON.decode(
                    GetResult.self, call("TractandaItem/get", arguments: ["ids": page.ids]))
                guard result.state == page.queryState, result.notFound.isEmpty else {
                    throw TractandaError("stateChanged", "Refresh the changing board.")
                }
                revisions.append(contentsOf: result.list)
            }
            position += page.ids.count
            if position >= page.total { return revisions }
            guard !page.ids.isEmpty else {
                throw TractandaError("protocolError", "Empty non-final query page.")
            }
        } while true
    }
}
