import Foundation

/// Escapes header text without trimming whitespace or normalizing Unicode. Body bytes use
/// a separate raw UTF-8 channel and never pass through this escaping.
enum MessageHeaderText {
    static func escaped(_ value: String, quoted: Bool = false) -> String {
        var result = quoted ? "\"" : ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"" where quoted: result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{8}": result += "\\b"
            case "\u{c}": result += "\\f"
            default:
                if requiresEscape(scalar) {
                    result += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        if quoted { result += "\"" }
        return result
    }

    static func unescaped(_ value: String) throws -> String {
        var input = value.unicodeScalars.makeIterator()
        var result = ""
        while let scalar = input.next() {
            guard scalar == "\\" else {
                guard scalar == "\t" || !requiresEscape(scalar) else { throw invalid("Unescaped header control character.") }
                result.unicodeScalars.append(scalar)
                continue
            }
            switch input.next() {
            case "\\": result += "\\"
            case "\"": result += "\""
            case "n": result += "\n"
            case "r": result += "\r"
            case "t": result += "\t"
            case "b": result += "\u{8}"
            case "f": result += "\u{c}"
            case "u":
                guard input.next() == "{" else { throw invalid("Malformed header scalar escape.") }
                var hex = ""
                var digit = input.next()
                while let scalar = digit, scalar != "}" {
                    guard hex.utf8.count < 6, isHex(scalar) else { throw invalid("Malformed header scalar escape.") }
                    hex.unicodeScalars.append(scalar)
                    digit = input.next()
                }
                guard digit == "}", let number = UInt32(hex, radix: 16), let escaped = UnicodeScalar(number) else {
                    throw invalid("Invalid escaped Unicode scalar.")
                }
                result.unicodeScalars.append(escaped)
            default: throw invalid("Unknown or incomplete header escape.")
            }
        }
        return result
    }

    static func isLiteral(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0 == "\t" || !requiresEscape($0) }
    }

    static func literal(_ value: String) throws -> String {
        guard isLiteral(value) else { throw invalid("Forbidden control character in a literal header.") }
        return value
    }

    static func word(_ value: String) throws -> String {
        var tokens = MessageHeaderTokens(value)
        let word = try tokens.takeWord()
        try tokens.requireEnd()
        return word
    }

    static func isWhitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 }

    private static func requiresEscape(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return value < 0x20 || (0x7f...0x9f).contains(value) || value == 0x2028 || value == 0x2029
    }

    private static func isHex(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
    }

    static func invalid(_ message: String) -> TractandaError { TractandaError("invalidRecord", message) }
}

/// A cursor for structured header values. ASCII separators are scanned as bytes so a
/// combining mark next to a quote cannot change the token boundaries.
struct MessageHeaderTokens {
    private let bytes: [UInt8]
    private var index = 0

    init(_ value: String) { bytes = Array(value.utf8) }

    private var isAtEnd: Bool { index == bytes.count }
    var hasToken: Bool { bytes[index...].contains { !MessageHeaderText.isWhitespace($0) } }

    mutating func takeQuoted() throws -> String {
        skipWhitespace()
        guard !isAtEnd, bytes[index] == 34 else { throw MessageHeaderText.invalid("Expected a quoted header value.") }
        index += 1
        let start = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                let raw = String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return try MessageHeaderText.unescaped(raw)
            }
            index += byte == 92 ? 2 : 1
        }
        throw MessageHeaderText.invalid("Unterminated quoted header value.")
    }

    mutating func takeWord(until separator: UInt8? = nil) throws -> String {
        skipWhitespace()
        let start = index
        while index < bytes.count, !MessageHeaderText.isWhitespace(bytes[index]), bytes[index] != separator {
            index += 1
        }
        guard index > start else { throw MessageHeaderText.invalid("Missing header token.") }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    mutating func parameters(afterValue: Bool = false) throws -> [String: String] {
        var parameters: [String: String] = [:]
        skipWhitespace()
        if afterValue, !isAtEnd { try takeDelimiter(59) }
        while !isAtEnd {
            let name = try takeWord(until: 61).lowercased()
            guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                throw MessageHeaderText.invalid("Invalid view header parameter name.")
            }
            try takeDelimiter(61)
            let value = !isAtEnd && bytes[index] == 34 ? try takeQuoted() : try takeWord(until: 59)
            guard parameters.updateValue(value, forKey: name) == nil else {
                throw MessageHeaderText.invalid("Duplicate view header parameter.")
            }
            skipWhitespace()
            if !isAtEnd { try takeDelimiter(59) }
        }
        return parameters
    }

    private mutating func takeDelimiter(_ byte: UInt8) throws {
        skipWhitespace()
        guard !isAtEnd, bytes[index] == byte else {
            throw MessageHeaderText.invalid("Invalid view header parameter separator.")
        }
        index += 1
        skipWhitespace()
        guard !isAtEnd else { throw MessageHeaderText.invalid("Missing view header parameter.") }
    }

    mutating func takeSpace() throws {
        try takeSeparator()
        skipWhitespace()
    }

    /// Text after a field key keeps leading whitespace beyond its one separator.
    mutating func takeSeparator() throws {
        guard !isAtEnd, MessageHeaderText.isWhitespace(bytes[index]) else {
            throw MessageHeaderText.invalid("Missing header token separator.")
        }
        index += 1
    }

    private mutating func skipWhitespace() {
        while !isAtEnd, MessageHeaderText.isWhitespace(bytes[index]) { index += 1 }
    }

    mutating func takeText() throws -> String {
        let raw = String(decoding: bytes[index...], as: UTF8.self)
        index = bytes.count
        return try MessageHeaderText.unescaped(raw)
    }

    func requireEnd() throws {
        guard !hasToken else { throw MessageHeaderText.invalid("Unexpected trailing header token.") }
    }
}
