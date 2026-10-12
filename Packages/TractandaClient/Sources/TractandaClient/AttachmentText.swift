import Foundation

private struct AttachmentTextCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ value: String) {
        stringValue = value
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

/// Immutable identity and byte-integrity facts for the exact attachment revision parsed.
public struct AttachmentTextSource: Codable, Equatable, Sendable {
    public let itemID: String
    public let revisionID: String
    public let attachmentID: String
    public let sha256: String
    public let byteCount: Int64
    public let mediaType: String

    public init(
        itemID: String, revisionID: String, attachmentID: String, sha256: String,
        byteCount: Int64, mediaType: String
    ) throws {
        try Self.validateID(itemID)
        try Self.validateID(revisionID)
        try Self.validateID(attachmentID)
        guard ["text/plain", "text/markdown"].contains(mediaType.lowercased()) else {
            throw TractandaError(
                "unsupportedAttachmentText", "Only text/plain and text/markdown are supported.")
        }
        guard byteCount <= AttachmentTextRepresentation.maximumInputBytes else {
            throw TractandaError("resourceLimit", "Attachment text extraction is limited to 512 KiB.")
        }
        guard Self.isSHA256(sha256), byteCount >= 0 else {
            throw TractandaError("invalidAttachmentText", "Invalid attachment-text source metadata.")
        }
        self.itemID = itemID
        self.revisionID = revisionID
        self.attachmentID = attachmentID
        self.sha256 = sha256
        self.byteCount = byteCount
        self.mediaType = mediaType
    }

    public init(_ value: ItemValue) throws {
        let fields = try Self.fields(value)
        try self.init(
            itemID: fields.itemID, revisionID: fields.revisionID, attachmentID: fields.attachmentID,
            sha256: fields.sha256, byteCount: fields.byteCount, mediaType: fields.mediaType)
    }

    public var itemValue: ItemValue {
        .object([
            "itemID": .text(itemID), "revisionID": .text(revisionID),
            "attachmentID": .text(attachmentID), "sha256": .text(sha256),
            "byteCount": .integer(byteCount), "mediaType": .text(mediaType),
        ])
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AttachmentTextCodingKey.self)
        let expected: Set<String> = [
            "itemID", "revisionID", "attachmentID", "sha256", "byteCount", "mediaType",
        ]
        guard Set(container.allKeys.map(\.stringValue)) == expected else {
            throw TractandaError(
                "invalidAttachmentText", "Attachment-text source has unknown or missing fields.")
        }
        try self.init(
            itemID: container.decode(String.self, forKey: AttachmentTextCodingKey("itemID")),
            revisionID: container.decode(String.self, forKey: AttachmentTextCodingKey("revisionID")),
            attachmentID: container.decode(String.self, forKey: AttachmentTextCodingKey("attachmentID")),
            sha256: container.decode(String.self, forKey: AttachmentTextCodingKey("sha256")),
            byteCount: container.decode(Int64.self, forKey: AttachmentTextCodingKey("byteCount")),
            mediaType: container.decode(String.self, forKey: AttachmentTextCodingKey("mediaType")))
    }

    fileprivate static func validateID(_ value: String) throws {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value,
            let uuid = UUID(uuidString: value)
        else {
            throw TractandaError("invalidAttachmentText", "Attachment-text identities must be UUIDv1.")
        }
        var raw = uuid.uuid
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        guard bytes[6] >> 4 == 1, bytes[8] & 0xC0 == 0x80 else {
            throw TractandaError("invalidAttachmentText", "Attachment-text identities must be UUIDv1.")
        }
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func fields(_ value: ItemValue) throws -> (
        itemID: String, revisionID: String, attachmentID: String, sha256: String,
        byteCount: Int64, mediaType: String
    ) {
        guard let map = value.map,
            Set(map.keys) == ["itemID", "revisionID", "attachmentID", "sha256", "byteCount", "mediaType"],
            let itemID = map["itemID"]?.string, let revisionID = map["revisionID"]?.string,
            let attachmentID = map["attachmentID"]?.string, let sha256 = map["sha256"]?.string,
            let byteCount = map["byteCount"]?.integerValue, let mediaType = map["mediaType"]?.string
        else {
            throw TractandaError("invalidAttachmentText", "Attachment-text source has invalid tagged fields.")
        }
        return (itemID, revisionID, attachmentID, sha256, byteCount, mediaType)
    }
}

/// A bounded complete UTF-8 extraction. `attachmentID` is the current local locator; `source`
/// remains provenance and may identify an earlier source after an item copy remaps the locator.
public struct AttachmentTextRepresentation: Codable, Equatable, Sendable {
    public static let fieldName = "attachmentText"
    public static let schema = "tractanda.attachment-text.v1"
    public static let converter = "utf8-v1"
    public static let maximumInputBytes = 512 * 1024
    public static let maximumAggregateEncodedBytes = 2 * 1024 * 1024
    public static let maximumRepresentations = 128

    public let representationID: String
    public let attachmentID: String
    public let source: AttachmentTextSource
    public let extractedAt: String
    public let text: String
    public let sourceByteStart: Int

    public init(
        representationID: String, attachmentID: String, source: AttachmentTextSource,
        extractedAt: String, text: String, sourceByteStart: Int
    ) throws {
        try AttachmentTextSource.validateID(representationID)
        try AttachmentTextSource.validateID(attachmentID)
        guard Timestamp.parse(extractedAt) != nil else {
            throw TractandaError("invalidAttachmentText", "extractedAt must be an ISO 8601 date.")
        }
        guard sourceByteStart == 0 || sourceByteStart == 3,
            source.byteCount >= Int64(sourceByteStart),
            Int64(text.utf8.count) == source.byteCount - Int64(sourceByteStart)
        else {
            throw TractandaError("invalidAttachmentText", "Extracted text does not map to its source bytes.")
        }
        self.representationID = representationID
        self.attachmentID = attachmentID
        self.source = source
        self.extractedAt = extractedAt
        self.text = text
        self.sourceByteStart = sourceByteStart
    }

    public init(_ value: ItemValue) throws {
        let fields = try Self.fields(value)
        try self.init(
            representationID: fields.representationID, attachmentID: fields.attachmentID,
            source: AttachmentTextSource(.object(fields.source)), extractedAt: fields.extractedAt,
            text: fields.text, sourceByteStart: fields.sourceByteStart)
        guard fields.schema == Self.schema, fields.converter == Self.converter,
            fields.state == "complete"
        else { throw TractandaError("invalidAttachmentText", "Unsupported attachment-text schema or state.") }
    }

    public var itemValue: ItemValue {
        .object([
            "schema": .text(Self.schema), "converter": .text(Self.converter), "state": .text("complete"),
            "representationID": .text(representationID), "attachmentID": .text(attachmentID),
            "source": source.itemValue, "extractedAt": .date(extractedAt), "text": .text(text),
            "sourceByteStart": .integer(Int64(sourceByteStart)),
        ])
    }

    public func remapping(attachmentID: String, representationID: String) throws -> Self {
        try Self(
            representationID: representationID, attachmentID: attachmentID, source: source,
            extractedAt: extractedAt, text: text, sourceByteStart: sourceByteStart)
    }

    public static func representations(in fields: [String: ItemValue]) throws -> [Self] {
        guard let value = fields[fieldName] else { return [] }
        guard let values = value.array, values.count <= maximumRepresentations else {
            throw TractandaError("resourceLimit", "attachmentText allows at most 128 representations.")
        }
        let representations = try values.map(Self.init)
        guard Set(representations.map(\.representationID)).count == representations.count,
            Set(representations.map(\.attachmentID)).count == representations.count
        else {
            throw TractandaError("invalidAttachmentText", "Representation and attachment IDs must be unique.")
        }
        guard !representations.isEmpty else { return [] }
        let prefixBytes = "{\n  \"type\" : \"list\",\n  \"value\" : [\n".utf8.count
        let suffixBytes = "\n  ]\n}".utf8.count
        var aggregateBytes = prefixBytes + suffixBytes
        for (index, representation) in representations.enumerated() {
            let encoded = try JSON.encode(representation.itemValue)
            let lineCount = encoded.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
            // Each encoded object is top-level JSON; inside the tagged list it is indented
            // two nesting levels (four extra spaces on every line).
            let (indentationBytes, indentationOverflow) = lineCount.multipliedReportingOverflow(by: 4)
            let (nestedSize, nestingOverflow) = encoded.count.addingReportingOverflow(indentationBytes)
            let separatorBytes = index == 0 ? 0 : 2  // comma and newline; indentation is counted above
            let (entrySize, separatorOverflow) = nestedSize.addingReportingOverflow(separatorBytes)
            let (withEntry, aggregateOverflow) = aggregateBytes.addingReportingOverflow(entrySize)
            guard !indentationOverflow, !nestingOverflow, !separatorOverflow, !aggregateOverflow,
                withEntry <= maximumAggregateEncodedBytes
            else {
                throw TractandaError("resourceLimit", "attachmentText exceeds its 2 MiB encoded budget.")
            }
            aggregateBytes = withEntry
        }
        return representations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AttachmentTextCodingKey.self)
        let expected: Set<String> = [
            "representationID", "attachmentID", "source", "extractedAt", "text", "sourceByteStart",
        ]
        guard Set(container.allKeys.map(\.stringValue)) == expected else {
            throw TractandaError(
                "invalidAttachmentText", "Attachment-text representation has unknown or missing fields.")
        }
        try self.init(
            representationID: container.decode(
                String.self, forKey: AttachmentTextCodingKey("representationID")),
            attachmentID: container.decode(String.self, forKey: AttachmentTextCodingKey("attachmentID")),
            source: container.decode(AttachmentTextSource.self, forKey: AttachmentTextCodingKey("source")),
            extractedAt: container.decode(String.self, forKey: AttachmentTextCodingKey("extractedAt")),
            text: container.decode(String.self, forKey: AttachmentTextCodingKey("text")),
            sourceByteStart: container.decode(Int.self, forKey: AttachmentTextCodingKey("sourceByteStart")))
    }

    private static func fields(_ value: ItemValue) throws -> (
        schema: String, converter: String, state: String, representationID: String, attachmentID: String,
        source: [String: ItemValue], extractedAt: String, text: String, sourceByteStart: Int
    ) {
        guard let map = value.map,
            Set(map.keys) == [
                "schema", "converter", "state", "representationID", "attachmentID", "source",
                "extractedAt", "text", "sourceByteStart",
            ],
            let schema = map["schema"]?.string, let converter = map["converter"]?.string,
            let state = map["state"]?.string, let representationID = map["representationID"]?.string,
            let attachmentID = map["attachmentID"]?.string, let source = map["source"]?.map,
            let extractedAt = map["extractedAt"]?.dateString, let text = map["text"]?.string,
            let sourceByteStart = map["sourceByteStart"]?.integerValue,
            let sourceByteStartInt = Int(exactly: sourceByteStart)
        else {
            throw TractandaError(
                "invalidAttachmentText", "Attachment-text representation has invalid tagged fields.")
        }
        return (
            schema, converter, state, representationID, attachmentID, source, extractedAt, text,
            sourceByteStartInt
        )
    }
}
