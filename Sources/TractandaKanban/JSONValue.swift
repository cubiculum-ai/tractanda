import Foundation
import TractandaCore

/// Lossless planning metadata, including unknown keys and JSON nulls.
/// This is an interchange value; canonical item fields still use ItemValue.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .boolean(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var booleanValue: Bool? { if case .boolean(let value) = self { value } else { nil } }
    public var integerValue: Int64? { if case .integer(let value) = self { value } else { nil } }
}

extension JSONValue {
    public init(_ value: ItemValue) {
        switch value {
        case .text(let value), .date(let value): self = .string(value)
        case .integer(let value): self = .integer(value)
        case .real(let value): self = .number(value)
        case .boolean(let value): self = .boolean(value)
        case .bytes(let value): self = .string(value.base64EncodedString())
        case .list(let values): self = .array(values.map(Self.init))
        case .object(let values): self = .object(values.mapValues(Self.init))
        case .reference(let reference): self = .string(reference.itemID)
        }
    }
}
