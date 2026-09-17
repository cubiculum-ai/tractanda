import Foundation

/// Sort by owned metadata or effective membership under a category root.
public struct ItemSort: Codable, Equatable, Sendable {
    public let property: String?
    public let categoryRootID: String?
    public let isAscending: Bool

    public init(property: String, isAscending: Bool = true) throws {
        guard !property.isEmpty, property.utf8.count <= 256, !property.contains("\0") else {
            throw TractandaError("invalidArguments", "A sort property must contain 1–256 bytes, without NUL.")
        }
        self.property = property
        categoryRootID = nil
        self.isAscending = isAscending
    }

    /// Orders by the first matching immediate child of this readable category root.
    public init(categoryRootID: String, isAscending: Bool = true) throws {
        try Identifier.validate(categoryRootID)
        property = nil
        self.categoryRootID = categoryRootID
        self.isAscending = isAscending
    }

    private enum CodingKeys: String, CodingKey { case property, categoryRootID, isAscending }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let property = try container.decodeIfPresent(String.self, forKey: .property)
        let categoryRootID = try container.decodeIfPresent(String.self, forKey: .categoryRootID)
        let ascending = try container.decodeIfPresent(Bool.self, forKey: .isAscending) ?? true
        guard !(container.contains(.property) && property == nil),
            !(container.contains(.categoryRootID) && categoryRootID == nil)
        else {
            throw TractandaError("invalidArguments", "A sort target cannot be null.")
        }
        switch (property, categoryRootID) {
        case (.some(let property), nil): try self.init(property: property, isAscending: ascending)
        case (nil, .some(let categoryRootID)):
            try self.init(categoryRootID: categoryRootID, isAscending: ascending)
        default:
            throw TractandaError(
                "invalidArguments", "A sort comparator requires exactly one property or categoryRootID.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let property { try container.encode(property, forKey: .property) }
        if let categoryRootID { try container.encode(categoryRootID, forKey: .categoryRootID) }
        try container.encode(isAscending, forKey: .isAscending)
    }

    public var value: ItemValue {
        var result: [String: ItemValue] = ["isAscending": .boolean(isAscending)]
        if let property { result["property"] = .text(property) }
        if let categoryRootID { result["categoryRootID"] = .reference(ItemReference(categoryRootID)) }
        return .object(result)
    }

    public static func validate(_ order: [ItemSort]) throws {
        let keys = order.compactMap { sort -> String? in
            if let property = sort.property { return "property:\(property)" }
            if let categoryRootID = sort.categoryRootID { return "category:\(categoryRootID)" }
            return nil
        }
        guard order.count <= 4, keys.count == order.count, Set(keys).count == order.count else {
            throw TractandaError("invalidArguments", "Use at most four distinct sort keys.")
        }
    }

}
