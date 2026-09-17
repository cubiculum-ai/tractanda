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
        guard let decoded = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw TractandaError("protocolError", "Invalid native response.")
        }
        if let code = decoded["code"] as? String {
            throw TractandaError(code, decoded["message"] as? String ?? "")
        }
        guard let calls = decoded["methodResponses"] as? [[Any]], calls.count == 1,
            calls[0].count == 3, calls[0][2] as? String == "client",
            let result = calls[0][1] as? [String: Any]
        else {
            throw TractandaError("protocolError", "Missing native method response.")
        }
        if calls[0][0] as? String == "error" {
            throw TractandaError(result["type"] as? String ?? "error", result["description"] as? String ?? "")
        }
        guard calls[0][0] as? String == method else {
            throw TractandaError("protocolError", "Unexpected method result.")
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    public func revision(for itemID: String) throws -> Revision {
        struct Result: Decodable { let list: [Revision] }
        let result = try JSON.decode(Result.self, call("TractandaItem/get", arguments: ["ids": [itemID]]))
        guard let revision = result.list.first else {
            throw TractandaError("notFound", "Item is unavailable.")
        }
        return revision
    }

    public func commit(_ request: CommitRequest) throws -> CommitResult {
        let arguments = try JSONSerialization.jsonObject(with: JSON.encode(request)) as! [String: Any]
        return try JSON.decode(CommitResult.self, call("TractandaItem/commit", arguments: arguments))
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
