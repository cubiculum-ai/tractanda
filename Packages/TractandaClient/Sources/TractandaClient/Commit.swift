import Foundation

/// One literal top-level collection edit. Values use the ordinary native tagged encoding.
public struct ItemFieldOperation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case append, setKey, removeKey }
    public var op: Kind
    public var field: String
    public var key: String?
    public var value: ItemValue?

    public init(op: Kind, field: String, key: String? = nil, value: ItemValue? = nil) {
        self.op = op
        self.field = field
        self.key = key
        self.value = value
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private enum CodingKeys: String, CodingKey { case op, field, key, value }

    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["op", "field", "key", "value"]) else {
            throw TractandaError("invalidArguments", "Unknown field operation key.")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = try c.decode(Kind.self, forKey: .op)
        field = try c.decode(String.self, forKey: .field)
        switch op {
        case .append:
            guard !c.contains(.key), c.contains(.value) else {
                throw TractandaError("invalidArguments", "append requires value and forbids key.")
            }
            key = nil
            value = try c.decode(ItemValue.self, forKey: .value)
        case .setKey:
            guard c.contains(.key), c.contains(.value) else {
                throw TractandaError("invalidArguments", "setKey requires key and value.")
            }
            key = try c.decode(String.self, forKey: .key)
            value = try c.decode(ItemValue.self, forKey: .value)
        case .removeKey:
            guard c.contains(.key), !c.contains(.value) else {
                throw TractandaError("invalidArguments", "removeKey requires key and forbids value.")
            }
            key = try c.decode(String.self, forKey: .key)
            value = nil
        }
    }
}

public struct CommitRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case create, revise, retype, copy }
    public var action: Action
    public var itemID: String?
    public var expectedRevisionID: String?
    public var classID: String?
    public var changes: [String: ItemValue]
    public var unset: [String]
    public var operationID: String
    public var fieldOperations: [ItemFieldOperation]?
    public init(
        action: Action = .create, itemID: String? = nil, expectedRevisionID: String? = nil,
        classID: String? = nil, changes: [String: ItemValue] = [:], unset: [String] = [],
        operationID: String, fieldOperations: [ItemFieldOperation]? = nil
    ) {
        self.action = action
        self.itemID = itemID
        self.expectedRevisionID = expectedRevisionID
        self.classID = classID
        self.changes = changes
        self.unset = unset
        self.operationID = operationID
        self.fieldOperations = fieldOperations
    }
}

public struct CommitResult: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case revision, warnings, itemState
        case wasReplayed = "replayed"
        case isIndexReady = "indexReady"
    }
    public let revision: Revision
    public let wasReplayed: Bool
    public let isIndexReady: Bool
    public let warnings: [String]
    /// Absent when canonical acceptance precedes derived-index projection readiness.
    public let itemState: ItemState?

    public init(
        revision: Revision, wasReplayed: Bool, isIndexReady: Bool, warnings: [String],
        itemState: ItemState? = nil
    ) {
        self.revision = revision
        self.wasReplayed = wasReplayed
        self.isIndexReady = isIndexReady
        self.warnings = warnings
        self.itemState = itemState
    }
}
