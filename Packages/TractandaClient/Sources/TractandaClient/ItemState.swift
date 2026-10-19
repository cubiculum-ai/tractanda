import Foundation

/// Current, caller-authorized historical status; it never rewrites the immutable revision.
public enum HistoricalDisposition: String, Codable, Equatable, Sendable {
    case demoted
}

/// Current, caller-authorized projection status for one item.
public struct ItemState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ready
        case conflicted
        case reviewRequired
        case invariantConflict
        case unmaterializable
    }

    public let itemID: String
    public let stateToken: String
    public let status: Status
    public let representativeRevisionID: String?
    public let frontier: [String]?
    public let conflictingFields: [String]?
    public let protectedFields: [String]?
    public let detailsComplete: Bool
    public let resource: ItemStateResource?

    public init(
        itemID: String, stateToken: String, status: Status,
        representativeRevisionID: String? = nil, frontier: [String]? = nil,
        conflictingFields: [String]? = nil, protectedFields: [String]? = nil,
        detailsComplete: Bool, resource: ItemStateResource? = nil
    ) {
        self.itemID = itemID
        self.stateToken = stateToken
        self.status = status
        self.representativeRevisionID = representativeRevisionID
        self.frontier = frontier
        self.conflictingFields = conflictingFields
        self.protectedFields = protectedFields
        self.detailsComplete = detailsComplete
        self.resource = resource
    }
}

public struct ItemStateResource: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case analysis, publication }
    public let code: String
    public let phase: Phase
    public let message: String
    public let maximumBytes: Int?

    public init(code: String, phase: Phase, message: String, maximumBytes: Int? = nil) {
        self.code = code
        self.phase = phase
        self.message = message
        self.maximumBytes = maximumBytes
    }
}

public struct ItemUnresolvedState: Codable, Equatable, Sendable {
    public let itemID: String
    public let status: ItemState.Status
    public let stateToken: String
    public let resource: ItemStateResource?

    public init(
        itemID: String, status: ItemState.Status, stateToken: String, resource: ItemStateResource? = nil
    ) {
        self.itemID = itemID
        self.status = status
        self.stateToken = stateToken
        self.resource = resource
    }
}

/// Byte-bounded status batches never imply that omitted IDs were not found or resolved.
public struct ItemStateResult: Codable, Equatable, Sendable {
    public let list: [ItemState]
    public let notFound: [String]
    public let remainingIDs: [String]
    public let oversizedIDs: [String]
    public let state: String

    public init(
        list: [ItemState], notFound: [String], remainingIDs: [String] = [],
        oversizedIDs: [String] = [], state: String
    ) {
        self.list = list
        self.notFound = notFound
        self.remainingIDs = remainingIDs
        self.oversizedIDs = oversizedIDs
        self.state = state
    }

    private enum CodingKeys: String, CodingKey { case list, notFound, remainingIDs, oversizedIDs, state }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        list = try values.decode([ItemState].self, forKey: .list)
        notFound = try values.decode([String].self, forKey: .notFound)
        remainingIDs = try values.decodeIfPresent([String].self, forKey: .remainingIDs) ?? []
        oversizedIDs = try values.decodeIfPresent([String].self, forKey: .oversizedIDs) ?? []
        state = try values.decode(String.self, forKey: .state)
    }
}

/// Batch get preserves successfully read records and all unresolved/byte-limited outcomes.
public struct ItemGetResult: Codable, Equatable, Sendable {
    public let list: [Revision]
    public let notFound: [String]
    public let unresolved: [ItemUnresolvedState]
    public let state: String
    public let remainingIDs: [String]
    public let oversizedIDs: [String]
    public let historicalDispositions: [String: HistoricalDisposition]

    public init(
        list: [Revision], notFound: [String], unresolved: [ItemUnresolvedState] = [], state: String,
        remainingIDs: [String] = [], oversizedIDs: [String] = [],
        historicalDispositions: [String: HistoricalDisposition] = [:]
    ) {
        self.list = list
        self.notFound = notFound
        self.unresolved = unresolved
        self.state = state
        self.remainingIDs = remainingIDs
        self.oversizedIDs = oversizedIDs
        self.historicalDispositions = historicalDispositions
    }

    private enum CodingKeys: String, CodingKey {
        case list, notFound, unresolved, state, remainingIDs, oversizedIDs, historicalDispositions
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        list = try values.decode([Revision].self, forKey: .list)
        notFound = try values.decode([String].self, forKey: .notFound)
        unresolved = try values.decodeIfPresent([ItemUnresolvedState].self, forKey: .unresolved) ?? []
        state = try values.decode(String.self, forKey: .state)
        remainingIDs = try values.decodeIfPresent([String].self, forKey: .remainingIDs) ?? []
        oversizedIDs = try values.decodeIfPresent([String].self, forKey: .oversizedIDs) ?? []
        historicalDispositions =
            try values.decodeIfPresent(
                [String: HistoricalDisposition].self, forKey: .historicalDispositions) ?? [:]
        let revisionIDs = Set(list.map(\.revisionID))
        guard revisionIDs.count == list.count,
            Set(historicalDispositions.keys).isSubset(of: revisionIDs)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .historicalDispositions, in: values,
                debugDescription: "Get disposition map must refer only to distinct returned revisions.")
        }
    }
}

/// One current-permission-checked native history page plus status for returned revisions.
public struct ItemHistoryResult: Codable, Equatable, Sendable {
    public let list: [Revision]
    public let total: Int
    public let historicalDispositions: [String: HistoricalDisposition]

    public init(
        list: [Revision], total: Int,
        historicalDispositions: [String: HistoricalDisposition] = [:]
    ) {
        self.list = list
        self.total = total
        self.historicalDispositions = historicalDispositions
    }

    private enum CodingKeys: String, CodingKey { case list, total, historicalDispositions }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        list = try values.decode([Revision].self, forKey: .list)
        total = try values.decode(Int.self, forKey: .total)
        historicalDispositions =
            try values.decodeIfPresent(
                [String: HistoricalDisposition].self, forKey: .historicalDispositions) ?? [:]
        let revisionIDs = Set(list.map(\.revisionID))
        guard total >= list.count, revisionIDs.count == list.count,
            Set(historicalDispositions.keys).isSubset(of: revisionIDs)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .historicalDispositions, in: values,
                debugDescription: "History disposition map must refer only to returned revisions.")
        }
    }
}

/// Exact historical revision read; disposition metadata is separate from immutable revision fields.
public struct RevisionGetResult: Codable, Equatable, Sendable {
    public let revision: Revision
    public let historicalDispositions: [String: HistoricalDisposition]

    public init(
        revision: Revision,
        historicalDispositions: [String: HistoricalDisposition] = [:]
    ) {
        self.revision = revision
        self.historicalDispositions = historicalDispositions
    }

    private enum CodingKeys: String, CodingKey { case revision, historicalDispositions }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(Revision.self, forKey: .revision)
        historicalDispositions =
            try values.decodeIfPresent(
                [String: HistoricalDisposition].self, forKey: .historicalDispositions) ?? [:]
        guard historicalDispositions.keys.allSatisfy({ $0 == revision.revisionID }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .historicalDispositions, in: values,
                debugDescription: "Exact revision disposition map must name the returned revision.")
        }
    }
}

public struct ItemConflictPage: Codable, Equatable, Sendable {
    public let list: [ItemState]
    public let nextCursor: String?
    public let state: String

    public init(list: [ItemState], nextCursor: String? = nil, state: String) {
        self.list = list
        self.nextCursor = nextCursor
        self.state = state
    }
}

/// Explicit resolution is guarded by the current item state token and complete reviewed frontier.
public struct ResolveConflictRequest: Codable, Equatable, Sendable {
    public let itemID: String
    public let expectedStateToken: String
    public let reviewedFrontier: [String]
    public let changes: [String: ItemValue]
    public let unset: [String]
    public let operationID: String

    public init(
        itemID: String, expectedStateToken: String, reviewedFrontier: [String],
        changes: [String: ItemValue], unset: [String], operationID: String
    ) {
        self.itemID = itemID
        self.expectedStateToken = expectedStateToken
        self.reviewedFrontier = reviewedFrontier
        self.changes = changes
        self.unset = unset
        self.operationID = operationID
    }
}
