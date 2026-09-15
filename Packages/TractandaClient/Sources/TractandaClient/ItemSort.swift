import Foundation

/// A direct metadata sort key. References are never followed while sorting.
public struct ItemSort: Codable, Equatable, Sendable {
    public let property: String
    public let isAscending: Bool

    public init(property: String, isAscending: Bool = true) throws {
        guard !property.isEmpty, property.utf8.count <= 256, !property.contains("\0") else {
            throw TractandaError("invalidArguments", "A sort property must contain 1–256 bytes, without NUL.")
        }
        self.property = property
        self.isAscending = isAscending
    }

    private enum CodingKeys: String, CodingKey { case property, isAscending }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            property: container.decode(String.self, forKey: .property),
            isAscending: container.decodeIfPresent(Bool.self, forKey: .isAscending) ?? true)
    }

    public var value: ItemValue {
        .object(["property": .text(property), "isAscending": .boolean(isAscending)])
    }

    public static func validate(_ order: [ItemSort]) throws {
        guard order.count <= 4, Set(order.map(\.property)).count == order.count else {
            throw TractandaError("invalidArguments", "Use at most four distinct sort properties.")
        }
    }

}
