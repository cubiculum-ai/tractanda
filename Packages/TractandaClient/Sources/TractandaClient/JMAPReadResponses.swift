import Foundation

/// Wire collections retain selected DTO properties; domain conversion is an explicit full-content step.
public struct JMAPItemGetResponse: Decodable, Sendable {
    public let accountID: String
    public let state: String
    public let list: [JMAPItemRecord]
    public let notFound: [String]
    public let remainingIDs: [String]
    public let oversizedIDs: [String]
    public let historicalDispositions: [String: HistoricalDisposition]
    private enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case state, list, notFound, remainingIDs, oversizedIDs, historicalDispositions
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(String.self, forKey: .accountID)
        state = try c.decode(String.self, forKey: .state)
        list = try c.decode([JMAPItemRecord].self, forKey: .list)
        notFound = try c.decode([String].self, forKey: .notFound)
        remainingIDs = try c.decodeIfPresent([String].self, forKey: .remainingIDs) ?? []
        oversizedIDs = try c.decodeIfPresent([String].self, forKey: .oversizedIDs) ?? []
        historicalDispositions =
            try c.decodeIfPresent([String: HistoricalDisposition].self, forKey: .historicalDispositions)
            ?? [:]
    }
    public func canonicalResult() throws -> ItemGetResult {
        var revisions: [Revision] = []
        var unresolved: [ItemUnresolvedState] = []
        for item in list {
            if let resolution = item.resolution, resolution.status != .ready {
                unresolved.append(
                    ItemUnresolvedState(
                        itemID: item.id, status: resolution.status, stateToken: resolution.stateToken,
                        resource: resolution.resource))
            } else {
                revisions.append(try item.canonicalRevision())
            }
        }
        return ItemGetResult(
            list: revisions, notFound: notFound, unresolved: unresolved, state: state,
            remainingIDs: remainingIDs, oversizedIDs: oversizedIDs,
            historicalDispositions: historicalDispositions)
    }
}

public struct JMAPRevisionGetResponse: Decodable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case state, list, notFound
    }
    public let accountID: String
    public let state: String
    public let list: [JMAPRevisionRecord]
    public let notFound: [String]
}

public struct JMAPHistoryResponse: Decodable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case state, list, total, historicalDispositions
    }
    public let accountID: String
    public let state: String
    public let list: [JMAPRevisionRecord]
    public let total: Int
    public let historicalDispositions: [String: HistoricalDisposition]?
    public func canonicalResult() throws -> ItemHistoryResult {
        ItemHistoryResult(
            list: try list.map { try $0.canonicalRevision() }, total: total,
            historicalDispositions: historicalDispositions ?? [:])
    }
    /// Checked full-content conversion shared by synchronous Core and asynchronous SDK
    /// clients. Selected/partial wire DTOs never become fabricated canonical revisions.
    public func canonicalResult(itemID: String, position: Int = 0, limit: Int = 100) throws
        -> ItemHistoryResult
    {
        try Identifier.validate(itemID)
        guard position >= 0, (1...256).contains(limit) else {
            throw TractandaError("invalidArguments", "Invalid history page or fields selection.")
        }
        let page = try canonicalResult()
        let revisionIDs = page.list.map(\.revisionID)
        guard page.total >= 0, position <= page.total, page.list.count <= page.total - position,
            page.list.count <= limit, page.list.allSatisfy({ $0.itemID == itemID }),
            Set(revisionIDs).count == revisionIDs.count,
            Set(page.historicalDispositions.keys).isSubset(of: Set(revisionIDs))
        else {
            throw TractandaError("protocolError", "History page contains an invalid disposition map.")
        }
        return page
    }
}

/// Validate dataset selection without altering the returned wire data or its DTO codec.
public enum JMAPReadResponseValidator {
    public static let methods: Set<String> = [
        "TractandaItem/get", "TractandaItem/getBounded", "TractandaRevision/get", "TractandaItem/history",
        "TractandaItem/query",
    ]
    public static func validate(_ response: Data, calls: [JMAPInvocation], discoveredAccountID: String? = nil)
        throws
    {
        let envelope = try JMAPValue.decode(response)
        guard let results = envelope["methodResponses"]?.elements else { return }
        for call in calls where methods.contains(call.name) {
            guard let result = results.first(where: { $0.elements?[2].text == call.callID })?.elements,
                result.count == 3, result[0].text == call.name
            else { continue }
            if ["TractandaItem/get", "TractandaRevision/get"].contains(call.name),
                result[1]["remainingIDs"] != nil || result[1]["oversizedIDs"] != nil
                    || result[1]["unresolved"] != nil
            {
                throw TractandaError(
                    "protocolError", "Standard get returned unsupported continuation fields.")
            }
            if ["TractandaItem/get", "TractandaItem/getBounded", "TractandaRevision/get"].contains(call.name),
                let ids = call.arguments["ids"]?.elements?.compactMap(\.text),
                let records = result[1]["list"]?.elements, let missing = result[1]["notFound"]?.elements
            {
                let classified =
                    records.compactMap { $0["id"]?.text } + missing.compactMap(\.text)
                    + (result[1]["remainingIDs"]?.elements?.compactMap(\.text) ?? [])
                    + (result[1]["oversizedIDs"]?.elements?.compactMap(\.text) ?? [])
                guard
                    records.count + missing.count + (result[1]["remainingIDs"]?.elements?.count ?? 0)
                        + (result[1]["oversizedIDs"]?.elements?.count ?? 0) == classified.count,
                    Set(classified).count == classified.count, Set(classified) == Set(ids)
                else {
                    throw TractandaError("protocolError", "Read response omitted or repeated requested IDs.")
                }
            }
            guard let expected = call.arguments["accountId"]?.text ?? discoveredAccountID,
                result[1]["accountId"]?.text == expected
            else {
                throw TractandaError(
                    "protocolError", "Read response account does not match the selected account.")
            }
        }
    }
}
