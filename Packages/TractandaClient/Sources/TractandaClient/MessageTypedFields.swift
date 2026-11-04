import Foundation

struct MessageHeader {
    let name: String
    let value: String
}

typealias MessageHeaderEmitter = (String, String) throws -> Void

/// Tagged field headers form a bounded tree. Object children carry literal quoted keys and
/// list children are anonymous. Explicit End headers keep empty collections unambiguous.
enum MessageTypedFields {
    static func sortedKeys(_ fields: [String: ItemValue]) -> [String] {
        fields.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    static func write(
        _ fields: [String: ItemValue], prefix: String = "X-Field-", emit: MessageHeaderEmitter
    ) throws {
        for key in sortedKeys(fields) {
            try write(fields[key]!, key: key, prefix: prefix, emit: emit)
        }
    }

    private static func write(
        _ value: ItemValue, key: String?, prefix: String, emit: MessageHeaderEmitter
    ) throws {
        let name = key.map { MessageHeaderText.escaped($0, quoted: true) }
        func scalar(_ type: String, _ text: String) throws {
            try emit(prefix + type, name.map { $0 + " " + text } ?? text)
        }
        switch value {
        case .text(let text): try scalar("Text", MessageHeaderText.escaped(text))
        case .date(let date): try scalar("Date", MessageHeaderText.escaped(date))
        case .integer(let number): try scalar("Integer", String(number))
        case .real(let number): try scalar("Real", String(number))
        case .boolean(let value): try scalar("Boolean", String(value))
        case .reference(let reference): try scalar("Reference", referenceText(reference))
        case .bytes(let bytes): try scalar("Bytes", bytes.base64EncodedString())
        case .list(let values):
            try emit(prefix + "List", name ?? "")
            for child in values { try write(child, key: nil, prefix: prefix, emit: emit) }
            try emit(prefix + "End", "")
        case .object(let fields):
            try emit(prefix + "Object", name ?? "")
            try write(fields, prefix: prefix, emit: emit)
            try emit(prefix + "End", "")
        }
    }

    static func read(_ headers: [MessageHeader], prefix: String = "x-field-") throws -> [String: ItemValue] {
        var reader = Reader(headers: headers, prefix: prefix)
        return try reader.readContainer(object: true, depth: -1).map!
    }

    static func referenceText(_ reference: ItemReference) -> String {
        reference.itemID + (reference.revisionID.map { "/" + $0 } ?? "")
    }

    static func reference(_ text: String) throws -> ItemReference {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { throw MessageHeaderText.invalid("Invalid item reference.") }
        let id = String(parts[0])
        let revision = parts.count == 2 ? String(parts[1]) : nil
        try Identifier.validate(id)
        if let revision { try Identifier.validate(revision) }
        return ItemReference(id, revisionID: revision)
    }

    private struct Reader {
        let headers: [MessageHeader]
        let prefix: String
        var index = 0

        mutating func readContainer(object: Bool, depth: Int) throws -> ItemValue {
            var fields: [String: ItemValue] = [:]
            var values: [ItemValue] = []
            while index < headers.count {
                let row = headers[index]
                index += 1
                guard row.name.hasPrefix(prefix) else { throw MessageHeaderText.invalid("Invalid field header family.") }
                let type = row.name.dropFirst(prefix.count)
                if type == "end" {
                    guard depth >= 0, row.value.utf8.allSatisfy(MessageHeaderText.isWhitespace) else { throw MessageHeaderText.invalid("Unexpected field container end.") }
                    return object ? .object(fields) : .list(values)
                }
                guard depth + 1 < 32 else { throw TractandaError("limit", "Values are nested too deeply.") }
                var tokens = MessageHeaderTokens(row.value)
                let key = object ? try tokens.takeQuoted() : nil
                let child: ItemValue
                if type == "object" || type == "list" {
                    try tokens.requireEnd()
                    child = try readContainer(object: type == "object", depth: depth + 1)
                } else {
                    if object { try tokens.takeSeparator() }
                    child = try Self.readScalar(type, text: tokens.takeText())
                }
                if let key {
                    guard fields.updateValue(child, forKey: key) == nil else {
                        throw MessageHeaderText.invalid("Duplicate object field.")
                    }
                } else { values.append(child) }
            }
            guard depth == -1 else { throw MessageHeaderText.invalid("Unclosed field container.") }
            return .object(fields)
        }

        private static func readScalar(_ type: Substring, text: String) throws -> ItemValue {
            switch type {
            case "text": return .text(text)
            case "date": return .date(text)
            case "integer":
                if let number = Int64(text) { return .integer(number) }
            case "real":
                if let number = Double(text), number.isFinite { return .real(number) }
            case "boolean":
                if text == "true" { return .boolean(true) }
                if text == "false" { return .boolean(false) }
            case "reference": return .reference(try reference(text))
            case "bytes":
                if let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text { return .bytes(bytes) }
            default: break
            }
            throw MessageHeaderText.invalid("Unknown or malformed typed field.")
        }
    }
}
