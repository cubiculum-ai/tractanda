import Foundation

/// A JSON number retains its spelling: arbitrary JSON is not a declared JMAP Int.
public struct JMAPNumber: Equatable, Sendable {
    public let token: String
    public init(_ token: String) throws {
        var parser = JMAPJSONParser(Data(token.utf8), maximumDepth: 1)
        guard case .number(let parsed) = try parser.parse(), parsed.token == token else {
            throw JMAPJSONError.invalidJSON
        }
        self = parsed
    }
    fileprivate init(validated token: String) { self.token = token }

    /// Use only for fields whose protocol schema declares Int/UnsignedInt.
    public func protocolInt(unsigned: Bool = false) throws -> Int64 {
        let exponentParts = token.split(whereSeparator: { $0 == "e" || $0 == "E" })
        let negative = exponentParts[0].first == "-"
        let magnitude = negative ? exponentParts[0].dropFirst() : exponentParts[0][...]
        let decimalParts = magnitude.split(separator: ".", omittingEmptySubsequences: false)
        var digits = String(decimalParts.joined().drop(while: { $0 == "0" }))
        if digits.isEmpty { return 0 }
        guard let exponent = exponentParts.count == 1 ? 0 : Int(exponentParts[1]) else {
            throw JMAPJSONError.invalidProtocolInteger
        }
        let places = decimalParts.count == 2 ? decimalParts[1].count : 0
        let (scale, overflow) = exponent.subtractingReportingOverflow(places)
        guard !overflow else { throw JMAPJSONError.invalidProtocolInteger }
        if scale >= 0 {
            guard scale <= 16, digits.count <= 16 - scale else { throw JMAPJSONError.invalidProtocolInteger }
            digits += String(repeating: "0", count: scale)
        } else {
            guard scale != Int.min, -scale <= digits.count,
                digits.suffix(-scale).allSatisfy({ $0 == "0" })
            else { throw JMAPJSONError.invalidProtocolInteger }
            digits.removeLast(-scale)
        }
        guard let value = Int64((negative ? "-" : "") + digits),
            value >= (unsigned ? 0 : -9_007_199_254_740_991), value <= 9_007_199_254_740_991
        else { throw JMAPJSONError.invalidProtocolInteger }
        return value
    }
}

/// Object members use exact UTF-8 equality, rather than Swift String's canonical equivalence.
public struct JMAPMember: Equatable, Sendable {
    public let name: String
    public let value: JMAPValue
    public init(_ name: String, _ value: JMAPValue) {
        self.name = name
        self.value = value
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.value == rhs.value
    }
}

public indirect enum JMAPValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(JMAPNumber)
    case string(String)
    case array([JMAPValue])
    case object([JMAPMember])

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): a.utf8.elementsEqual(b.utf8)
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)):
            a.count == b.count
                && a.allSatisfy { member in
                    b.contains { $0 == member }
                }
        default: false
        }
    }
    public subscript(_ name: String) -> JMAPValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.name.utf8.elementsEqual(name.utf8) }?.value
    }
    public var text: String? { if case .string(let value) = self { value } else { nil } }
    public var elements: [JMAPValue]? { if case .array(let value) = self { value } else { nil } }
    public var members: [JMAPMember]? { if case .object(let value) = self { value } else { nil } }

    public static func decode(_ data: Data, maximumDepth: Int = 64) throws -> Self {
        var parser = JMAPJSONParser(data, maximumDepth: maximumDepth)
        return try parser.parse()
    }
    public func encoded(maximumDepth: Int = 64) throws -> Data {
        func encode(_ value: Self, depth: Int) throws -> String {
            guard depth <= maximumDepth else { throw JMAPJSONError.tooDeep }
            func quoted(_ text: String) throws -> String {
                guard text.unicodeScalars.allSatisfy({ !JMAPJSONParser.isNoncharacter($0.value) }) else {
                    throw JMAPJSONError.invalidUnicode
                }
                return String(
                    decoding: try JSONSerialization.data(
                        withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                    as: UTF8.self)
            }
            switch value {
            case .null: return "null"
            case .bool(let flag): return flag ? "true" : "false"
            case .number(let number): return number.token
            case .string(let text): return try quoted(text)
            case .array(let values):
                return "[" + (try values.map { try encode($0, depth: depth + 1) }).joined(separator: ",")
                    + "]"
            case .object(let members):
                var names: Set<Data> = []
                return "{"
                    + (try members.map { member in
                        guard names.insert(Data(member.name.utf8)).inserted else {
                            throw JMAPJSONError.duplicateKey
                        }
                        return try quoted(member.name) + ":" + encode(member.value, depth: depth + 1)
                    }).joined(separator: ",") + "}"
            }
        }
        return Data(try encode(self, depth: 0).utf8)
    }
}

public enum JMAPJSONError: Error, Equatable, Sendable {
    case invalidJSON, invalidUnicode, duplicateKey, tooDeep, invalidProtocolInteger
}

private struct JMAPJSONParser {
    let bytes: [UInt8]
    let maximumDepth: Int
    var position = 0
    init(_ data: Data, maximumDepth: Int) {
        bytes = Array(data)
        self.maximumDepth = maximumDepth
    }
    static func isNoncharacter(_ scalar: UInt32) -> Bool {
        (0xfdd0...0xfdef).contains(scalar) || scalar & 0xffff == 0xfffe || scalar & 0xffff == 0xffff
    }
    mutating func parse() throws -> JMAPValue {
        guard String(bytes: bytes, encoding: .utf8) != nil else { throw JMAPJSONError.invalidUnicode }
        let result = try value(depth: 0)
        whitespace()
        guard position == bytes.count else { throw JMAPJSONError.invalidJSON }
        return result
    }
    mutating func whitespace() {
        while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
    }
    mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }
    mutating func value(depth: Int) throws -> JMAPValue {
        guard depth <= maximumDepth else { throw JMAPJSONError.tooDeep }
        whitespace()
        guard position < bytes.count else { throw JMAPJSONError.invalidJSON }
        switch bytes[position] {
        case 34: return .string(try string())
        case 123:
            position += 1
            whitespace()
            var members: [JMAPMember] = []
            var names: Set<Data> = []
            if consume(125) { return .object(members) }
            while true {
                whitespace()
                let name = try string()
                guard names.insert(Data(name.utf8)).inserted else { throw JMAPJSONError.duplicateKey }
                whitespace()
                guard consume(58) else { throw JMAPJSONError.invalidJSON }
                members.append(.init(name, try value(depth: depth + 1)))
                whitespace()
                if consume(125) { return .object(members) }
                guard consume(44) else { throw JMAPJSONError.invalidJSON }
            }
        case 91:
            position += 1
            whitespace()
            var values: [JMAPValue] = []
            if consume(93) { return .array(values) }
            while true {
                values.append(try value(depth: depth + 1))
                whitespace()
                if consume(93) { return .array(values) }
                guard consume(44) else { throw JMAPJSONError.invalidJSON }
            }
        case 116:
            try literal("true")
            return .bool(true)
        case 102:
            try literal("false")
            return .bool(false)
        case 110:
            try literal("null")
            return .null
        default: return .number(try number())
        }
    }
    mutating func literal(_ token: String) throws {
        for byte in token.utf8 {
            guard consume(byte) else { throw JMAPJSONError.invalidJSON }
        }
    }
    mutating func string() throws -> String {
        guard consume(34) else { throw JMAPJSONError.invalidJSON }
        var output: [UInt8] = []
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if byte == 34 {
                guard String(bytes: output, encoding: .utf8) != nil else {
                    throw JMAPJSONError.invalidUnicode
                }
                // Foundation's encoding initializer consumes a leading/sole UTF8 BOM. JSON
                // string contents and member names must retain that legitimate Unicode scalar.
                let text = String(decoding: output, as: UTF8.self)
                guard text.unicodeScalars.allSatisfy({ !Self.isNoncharacter($0.value) }) else {
                    throw JMAPJSONError.invalidUnicode
                }
                return text
            }
            guard byte >= 32 else { throw JMAPJSONError.invalidJSON }
            if byte != 92 {
                output.append(byte)
                continue
            }
            guard position < bytes.count else { throw JMAPJSONError.invalidJSON }
            let escaped = bytes[position]
            position += 1
            switch escaped {
            case 34, 47, 92: output.append(escaped)
            case 98: output.append(8)
            case 102: output.append(12)
            case 110: output.append(10)
            case 114: output.append(13)
            case 116: output.append(9)
            case 117:
                var scalar = try hex()
                if (0xd800...0xdbff).contains(scalar) {
                    guard consume(92), consume(117) else { throw JMAPJSONError.invalidUnicode }
                    let low = try hex()
                    guard (0xdc00...0xdfff).contains(low) else { throw JMAPJSONError.invalidUnicode }
                    scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00
                }
                guard !(0xd800...0xdfff).contains(scalar), let unicode = UnicodeScalar(scalar),
                    !Self.isNoncharacter(scalar)
                else { throw JMAPJSONError.invalidUnicode }
                output.append(contentsOf: String(unicode).utf8)
            default: throw JMAPJSONError.invalidJSON
            }
        }
        throw JMAPJSONError.invalidJSON
    }
    mutating func hex() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard position < bytes.count else { throw JMAPJSONError.invalidJSON }
            let byte = bytes[position]
            position += 1
            let digit: UInt32
            switch byte {
            case 48...57: digit = UInt32(byte - 48)
            case 65...70: digit = UInt32(byte - 55)
            case 97...102: digit = UInt32(byte - 87)
            default: throw JMAPJSONError.invalidJSON
            }
            value = value * 16 + digit
        }
        return value
    }
    mutating func number() throws -> JMAPNumber {
        let start = position
        _ = consume(45)
        if !consume(48) {
            guard position < bytes.count, (49...57).contains(bytes[position]) else {
                throw JMAPJSONError.invalidJSON
            }
            position += 1
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
        }
        if consume(46) { try digits() }
        if consume(101) || consume(69) {
            if !consume(43) { _ = consume(45) }
            try digits()
        }
        return JMAPNumber(validated: String(decoding: bytes[start..<position], as: UTF8.self))
    }
    mutating func digits() throws {
        let start = position
        while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
        guard position > start else { throw JMAPJSONError.invalidJSON }
    }
}
