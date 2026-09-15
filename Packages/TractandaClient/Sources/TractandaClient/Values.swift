import Foundation

public struct TractandaError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "\(code): \(message)" }
}

public struct ItemReference: Codable, Equatable, Sendable {
    public let itemID: String
    public let revisionID: String?
    public init(_ itemID: String, revisionID: String? = nil) {
        self.itemID = itemID
        self.revisionID = revisionID
    }
}

/// Tagged values make dates, numbers and references recoverable without an index.
public indirect enum ItemValue: Codable, Equatable, Sendable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case boolean(Bool)
    case date(String)
    case list([ItemValue])
    case object([String: ItemValue])
    case reference(ItemReference)
    case bytes(Data)

    private enum CodingKeys: String, CodingKey { case type, value }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .value))
        case "integer": self = .integer(try c.decode(Int64.self, forKey: .value))
        case "real": self = .real(try c.decode(Double.self, forKey: .value))
        case "boolean": self = .boolean(try c.decode(Bool.self, forKey: .value))
        case "date": self = .date(try c.decode(String.self, forKey: .value))
        case "list": self = .list(try c.decode([ItemValue].self, forKey: .value))
        case "object": self = .object(try c.decode([String: ItemValue].self, forKey: .value))
        case "reference": self = .reference(try c.decode(ItemReference.self, forKey: .value))
        case "bytes": self = .bytes(try c.decode(Data.self, forKey: .value))
        default:
            throw TractandaError(
                "unsupportedValueType", "Unknown value encoding; retain the original record.")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func tag(_ type: String) throws { try c.encode(type, forKey: .type) }
        switch self {
        case .text(let v):
            try tag("text")
            try c.encode(v, forKey: .value)
        case .integer(let v):
            try tag("integer")
            try c.encode(v, forKey: .value)
        case .real(let v):
            try tag("real")
            try c.encode(v, forKey: .value)
        case .boolean(let v):
            try tag("boolean")
            try c.encode(v, forKey: .value)
        case .date(let v):
            try tag("date")
            try c.encode(v, forKey: .value)
        case .list(let v):
            try tag("list")
            try c.encode(v, forKey: .value)
        case .object(let v):
            try tag("object")
            try c.encode(v, forKey: .value)
        case .reference(let v):
            try tag("reference")
            try c.encode(v, forKey: .value)
        case .bytes(let v):
            try tag("bytes")
            try c.encode(v, forKey: .value)
        }
    }
    public var string: String? {
        if case .text(let s) = self { return s }
        return nil
    }
    public var map: [String: ItemValue]? {
        if case .object(let m) = self { return m }
        return nil
    }
    public var array: [ItemValue]? {
        if case .list(let a) = self { return a }
        return nil
    }
    public var booleanValue: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }
    public var integerValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }
    public var link: ItemReference? {
        if case .reference(let r) = self { return r }
        return nil
    }
    /// Extracts text recursively; time and space grow with the value tree.
    public var textForIndex: String {
        switch self {
        case .text(let s): return s
        case .list(let a): return a.map(\.textForIndex).joined(separator: " ")
        case .object(let m): return m.keys.sorted().compactMap { m[$0]?.textForIndex }.joined(separator: " ")
        default: return ""
        }
    }
    public func validate(depth: Int = 0) throws {
        guard depth < 32 else { throw TractandaError("limit", "Values are nested too deeply.") }
        switch self {
        case .real(let n) where !n.isFinite: throw TractandaError("invalidValue", "Numbers must be finite.")
        case .date(let s) where Timestamp.parse(s) == nil:
            throw TractandaError("invalidValue", "Dates must be ISO 8601 timestamps with a timezone.")
        case .reference(let r):
            try Identifier.validate(r.itemID)
            if let id = r.revisionID { try Identifier.validate(id) }
        case .list(let a): for v in a { try v.validate(depth: depth + 1) }
        case .object(let m):
            for (key, v) in m {
                guard !key.isEmpty, !key.contains("\0") else {
                    throw TractandaError("invalidKey", "Empty/NUL key.")
                }
                try v.validate(depth: depth + 1)
            }
        default: break
        }
    }
}

public enum Timestamp {
    public static func now() -> String { format(Date()) }
    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    public static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
public enum Identifier {
    public static func make() -> String { UUID().uuidString.lowercased() }
    public static func validate(_ id: String) throws {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else {
            throw TractandaError("invalidID", "Expected a canonical lowercase UUID.")
        }
    }
}
public enum JSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
