import Foundation

public struct CommitRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case create, revise, retype, copy }
    public var action: Action
    public var itemID: String?
    public var expectedRevisionID: String?
    public var classID: String?
    public var changes: [String: ItemValue]
    public var unset: [String]
    public var operationID: String
    public init(
        action: Action = .create, itemID: String? = nil, expectedRevisionID: String? = nil,
        classID: String? = nil, changes: [String: ItemValue] = [:], unset: [String] = [],
        operationID: String
    ) {
        self.action = action
        self.itemID = itemID
        self.expectedRevisionID = expectedRevisionID
        self.classID = classID
        self.changes = changes
        self.unset = unset
        self.operationID = operationID
    }
}

public struct CommitResult: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case revision, warnings
        case wasReplayed = "replayed"
        case isIndexReady = "indexReady"
    }
    public let revision: Revision
    public let wasReplayed: Bool
    public let isIndexReady: Bool
    public let warnings: [String]

    public init(revision: Revision, wasReplayed: Bool, isIndexReady: Bool, warnings: [String]) {
        self.revision = revision
        self.wasReplayed = wasReplayed
        self.isIndexReady = isIndexReady
        self.warnings = warnings
    }
}
