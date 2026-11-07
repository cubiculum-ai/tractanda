import Foundation

public struct ItemListTailRequest: Codable, Equatable, Sendable {
    public let itemID: String
    public let field: String
    public let limit: Int
    public init(itemID: String, field: String, limit: Int = 10) {
        self.itemID = itemID
        self.field = field
        self.limit = limit
    }
}

public struct ItemListTailResult: Codable, Equatable, Sendable {
    public let itemId: String
    public let revisionId: String
    public let state: String
    public let field: String
    public let fieldPresent: Bool
    public let total: Int
    public let start: Int
    public let values: [ItemValue]
}
