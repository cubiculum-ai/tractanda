import Foundation

/// The canonical message encoding is independent of the logical revision and API JSON formats.
public enum MessageRecordCodec {
    public static let encoding = "message-v1"
    public static let capability = "tractanda.message-items.v1"
    public static let minimumReaderLevel = 20
    public static let maximumRecordBytes = 8 * 1024 * 1024
    private static let bodyMediaTypes: Set<String> = ["text/plain", "text/markdown", "text/html"]
    private static let textHeaders = [
        ("itemID", "X-Item-ID"), ("revisionID", "X-Revision-ID"), ("classID", "X-IsA"),
        ("supersedes", "X-Supersedes"), ("actor", "X-Actor"), ("operationID", "X-Operation-ID"),
        ("requestIdentity", "X-Request-Identity"),
        ("subject", "Subject"),
    ]
    private static let dateHeaders = [("createdAt", "X-Created-At"), ("modifiedAt", "X-Modified-At")]

    public static func encode(_ revision: Revision) throws -> Data {
        try revision.validate()
        var fields = revision.fields
        let body = fields.removeValue(forKey: "body")?.string
        let bodyBytes = Data((body ?? "").utf8)
        guard bodyBytes.count <= maximumRecordBytes - 2 else { throw sizeError() }
        let mediaType = fields["bodyMediaType"]?.string.flatMap { bodyMediaTypes.contains($0) ? $0 : nil }
        if mediaType != nil { fields.removeValue(forKey: "bodyMediaType") }
        var output = Data()
        func emit(_ name: String, _ value: String) throws {
            let bytes = name.utf8.count + 4 + value.utf8.count
            guard bytes <= maximumRecordBytes - 2 - bodyBytes.count - output.count else { throw sizeError() }
            output.append(contentsOf: name.utf8)
            output.append(contentsOf: [58, 32])
            output.append(contentsOf: value.utf8)
            output.append(contentsOf: [13, 10])
        }
        try emit("MIME-Version", "1.0")
        try emit("Content-Type", (mediaType ?? "text/plain") + "; charset=utf-8")
        try emit("Content-Transfer-Encoding", "binary")
        try emit("X-Tractanda-Encoding", encoding)
        try emit("X-Tractanda-Format-Version", String(revision.formatVersion))
        try emit("X-Body-Present", String(body != nil))
        try emit("X-Body-Media-Type-Present", String(mediaType != nil))
        for (field, header) in textHeaders {
            if let value = fields[field]?.string, MessageHeaderText.isLiteral(value) {
                try emit(header, value)
                fields[field] = nil
            }
        }
        for (field, header) in dateHeaders {
            if let value = fields[field]?.dateString, MessageHeaderText.isLiteral(value),
                !value.utf8.contains(where: MessageHeaderText.isWhitespace) {
                try emit(header, value)
                fields[field] = nil
            }
        }
        try emit("X-Schema-Version", String(fields.removeValue(forKey: "schemaVersion")!.integerValue!))
        if let deleted = fields.removeValue(forKey: "isDeleted")?.booleanValue {
            try emit("X-Is-Deleted", String(deleted))
        }
        try MessageKnownFields.write(&fields, emit: emit)
        if let view = fields["viewDefinition"] { fields["viewDefinition"] = try MessageViewFields.write(view, emit: emit) }
        for key in MessageTypedFields.sortedKeys(fields)
        where key.hasPrefix("x-") && key == key.lowercased() && MessageHeaderReader.isExtensionName(key) {
            guard let value = fields[key] else { continue }
            if let text = value.string, MessageHeaderText.isLiteral(text) {
                try emit(key, text)
                fields[key] = nil
            } else if let values = value.array, values.count > 1 {
                let texts = values.compactMap(\.string)
                if texts.count == values.count, texts.allSatisfy(MessageHeaderText.isLiteral) {
                    for text in texts { try emit(key, text) }
                    fields[key] = nil
                }
            }
        }
        try MessageTypedFields.write(fields, emit: emit)
        output.append(contentsOf: [13, 10])
        output.append(bodyBytes)
        return output
    }

    public static func decode(_ data: Data) throws -> Revision {
        guard data.count <= maximumRecordBytes else { throw MessageHeaderText.invalid("Oversized message record.") }
        let envelope = try splitEnvelope(data)
        var headers = try MessageHeaderReader(envelope.lines)
        guard try MessageHeaderText.word(headers.required("x-tractanda-encoding")) == encoding,
            try MessageHeaderText.word(headers.required("mime-version")) == "1.0",
            try MessageHeaderText.word(headers.required("content-transfer-encoding")).lowercased() == "binary",
            let version = try Int(MessageHeaderText.word(headers.required("x-tractanda-format-version")))
        else { throw MessageHeaderText.invalid("Unsupported message record header values.") }
        let mediaType = try readContentType(headers.required("content-type"))
        let bodyPresent = try boolean(headers.required("x-body-present"))
        let mediaPresent = try boolean(headers.required("x-body-media-type-present"))
        guard mediaPresent || mediaType == "text/plain" else {
            throw MessageHeaderText.invalid("Absent body media type must use the plain-text default.")
        }
        var fields = try headers.typed()
        let reserved = Set(textHeaders.map(\.0) + dateHeaders.map(\.0) + ["schemaVersion", "isDeleted", "body"])
        guard fields["body"] == nil else { throw MessageHeaderText.invalid("Body belongs in the raw message bytes.") }
        if let value = try headers.single("x-schema-version") {
            guard let schema = try Int64(MessageHeaderText.word(value)) else {
                throw MessageHeaderText.invalid("Invalid schema version header.")
            }
            try insert(.integer(schema), key: "schemaVersion", into: &fields)
        }
        for (field, header) in textHeaders {
            if let value = try headers.single(header.lowercased()) {
                try insert(.text(MessageHeaderText.literal(value)), key: field, into: &fields)
            }
        }
        for (field, header) in dateHeaders {
            if let value = try headers.single(header.lowercased()) {
                try insert(.date(MessageHeaderText.word(value)), key: field, into: &fields)
            }
        }
        if let value = try headers.single("x-is-deleted") {
            try insert(.boolean(boolean(value)), key: "isDeleted", into: &fields)
        }
        let rawBody = data[envelope.bodyStart...]
        if bodyPresent {
            guard let body = decodeUTF8(rawBody) else {
                throw MessageHeaderText.invalid("Message body is not UTF-8.")
            }
            fields["body"] = .text(body)
        } else if !rawBody.isEmpty {
            throw MessageHeaderText.invalid("Body bytes are present without a body field.")
        }
        if mediaPresent {
            try insert(.text(mediaType), key: "bodyMediaType", into: &fields)
        } else if let explicit = fields["bodyMediaType"]?.string, bodyMediaTypes.contains(explicit) {
            throw MessageHeaderText.invalid("Recognized body media type requires a content type declaration.")
        }
        try MessageKnownFields.read(&headers, into: &fields)
        fields["viewDefinition"] = try MessageViewFields.read(&headers, remaining: fields["viewDefinition"])
        try headers.readExtensions(into: &fields, reservedFields: reserved.union(["bodyMediaType"]))
        return try Revision(fields: fields, formatVersion: version)
    }

    private static func splitEnvelope(_ data: Data) throws -> (lines: [String], bodyStart: Data.Index) {
        var lines: [String] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 10) {
            let end = newline > start && data[newline - 1] == 13 ? newline - 1 : newline
            let bytes = data[start..<end]
            start = newline + 1
            if bytes.isEmpty { return (lines, start) }
            guard !bytes.contains(13), let line = decodeUTF8(bytes) else {
                throw MessageHeaderText.invalid("Invalid UTF-8 or bare CR in message headers.")
            }
            lines.append(line)
        }
        throw MessageHeaderText.invalid("Message headers require a blank line before the body.")
    }

    private static func readContentType(_ value: String) throws -> String {
        let whitespace = CharacterSet(charactersIn: " \t")
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw MessageHeaderText.invalid("Unsupported message body content type.") }
        let media = parts[0].trimmingCharacters(in: whitespace).lowercased()
        let charset = parts[1].split(separator: "=", omittingEmptySubsequences: false)
        guard bodyMediaTypes.contains(media), charset.count == 2,
            charset[0].trimmingCharacters(in: whitespace).lowercased() == "charset"
        else { throw MessageHeaderText.invalid("Unsupported message body content type.") }
        let encoding = charset[1].trimmingCharacters(in: whitespace).lowercased()
        guard encoding == "utf-8" || encoding == "\"utf-8\"" else {
            throw MessageHeaderText.invalid("Unsupported message body charset.")
        }
        return media
    }

    private static func decodeUTF8(_ bytes: Data) -> String? {
        let value = String(decoding: bytes, as: UTF8.self)
        return value.utf8.elementsEqual(bytes) ? value : nil
    }

    static func boolean(_ value: String) throws -> Bool {
        let word = try MessageHeaderText.word(value)
        if word == "true" { return true }
        if word == "false" { return false }
        throw MessageHeaderText.invalid("Invalid Boolean header value.")
    }

    static func insert(_ value: ItemValue, key: String, into fields: inout [String: ItemValue]) throws {
        guard fields[key] == nil else { throw MessageHeaderText.invalid("Duplicate field representation.") }
        fields[key] = value
    }

    private static func sizeError() -> TractandaError {
        TractandaError("resourceLimit", "Message record exceeds its byte window.")
    }
}

struct MessageHeaderReader {
    private let lines: [MessageHeader]
    private var values: [String: [String]] = [:]

    init(_ physicalLines: [String]) throws {
        var headers: [MessageHeader] = []
        var name: String?
        var value = ""
        for line in physicalLines {
            if let first = line.utf8.first, MessageHeaderText.isWhitespace(first) {
                guard name != nil else { throw MessageHeaderText.invalid("Header continuation has no field.") }
                // Remove the CRLF, retaining the continuation's leading whitespace.
                value.append(contentsOf: line)
                continue
            }
            if let name { headers.append(MessageHeader(name: name, value: value)) }
            guard let colon = line.utf8.firstIndex(of: 58), colon != line.utf8.startIndex,
                line.utf8[..<colon].allSatisfy(Self.isNameByte)
            else { throw MessageHeaderText.invalid("Malformed message header.") }
            name = String(decoding: line.utf8[..<colon], as: UTF8.self).lowercased()
            var start = line.utf8.index(after: colon)
            if start != line.utf8.endIndex, MessageHeaderText.isWhitespace(line.utf8[start]) {
                start = line.utf8.index(after: start)
            }
            value = String(decoding: line.utf8[start...], as: UTF8.self)
        }
        if let name { headers.append(MessageHeader(name: name, value: value)) }
        lines = headers
        for line in lines { values[line.name, default: []].append(line.value) }
    }

    mutating func single(_ name: String) throws -> String? {
        let matches = many(name)
        guard matches.count <= 1 else { throw MessageHeaderText.invalid("Duplicate scalar message header.") }
        return matches.first
    }

    mutating func required(_ name: String) throws -> String {
        guard let value = try single(name) else { throw MessageHeaderText.invalid("Required message header is missing.") }
        return value
    }

    mutating func many(_ name: String) -> [String] { values.removeValue(forKey: name) ?? [] }

    mutating func typed(prefix: String = "x-field-") throws -> [String: ItemValue] {
        let matches = lines.filter { $0.name.hasPrefix(prefix) }
        for line in matches { values[line.name] = nil }
        return try MessageTypedFields.read(matches, prefix: prefix)
    }

    static func isExtensionName(_ name: String) -> Bool {
        let reserved = ["x-tractanda-", "x-field-", "x-view-", "x-ancestry-", "x-permissions-", "x-acl-",
            "x-category-", "x-body-", "x-request-", "content-", "mime-"]
        return !name.isEmpty && name.utf8.allSatisfy(isNameByte)
            && !reserved.contains(where: { name.hasPrefix($0) })
            && !["x-item-id", "x-revision-id", "x-isa", "x-supersedes", "x-actor", "x-operation-id",
                "x-created-at", "x-modified-at", "x-schema-version", "x-is-deleted", "x-attachment"].contains(name)
    }

    func readExtensions(into fields: inout [String: ItemValue], reservedFields: Set<String>) throws {
        for (name, entries) in values {
            guard Self.isExtensionName(name), !reservedFields.contains(name) else {
                throw MessageHeaderText.invalid("Unknown reserved message record header.")
            }
            let texts = try entries.map { ItemValue.text(try MessageHeaderText.literal($0)) }
            let value = texts.count == 1 ? texts[0] : .list(texts)
            try MessageRecordCodec.insert(value, key: name, into: &fields)
        }
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (33...126).contains(byte) && byte != 58
    }
}
