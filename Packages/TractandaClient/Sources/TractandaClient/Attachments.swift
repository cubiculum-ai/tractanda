import Foundation

/// Public description of an immutable attachment payload. `filename` is presentation metadata;
/// it is never used to construct a storage path.
public struct AttachmentDescriptor: Codable, Equatable, Sendable {
    public static let fieldName = "attachments"
    public static let maximumAttachments = 128
    /// File offsets and byte counts use checked signed 64-bit arithmetic.
    public static let maximumPayloadBytes: Int64 = .max

    public let attachmentID: String
    public let filename: String
    public let mediaType: String
    public let byteCount: Int64
    public let sha256: String

    public init(
        attachmentID: String, filename: String, mediaType: String, byteCount: Int64, sha256: String
    ) throws {
        try Self.validateVersion1ID(attachmentID)
        guard !filename.isEmpty, filename.utf8.count <= 1_024,
            !filename.unicodeScalars.contains(where: {
                $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F
            })
        else {
            throw TractandaError("invalidAttachment", "Attachment filename must be a safe display name.")
        }
        guard mediaType.utf8.count <= 255, Self.isMediaType(mediaType) else {
            throw TractandaError("invalidAttachment", "Attachment mediaType must be a bare type/subtype.")
        }
        guard byteCount >= 0 else {
            throw TractandaError("invalidAttachment", "Attachment byteCount must be nonnegative.")
        }
        guard Self.isSHA256(sha256) else {
            throw TractandaError("invalidAttachment", "Attachment sha256 must be 64 lowercase hex digits.")
        }
        self.attachmentID = attachmentID
        self.filename = filename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public init(_ value: ItemValue) throws {
        guard let fields = value.map,
            Set(fields.keys) == ["attachmentID", "filename", "mediaType", "byteCount", "sha256"],
            let attachmentID = fields["attachmentID"]?.string,
            let filename = fields["filename"]?.string,
            let mediaType = fields["mediaType"]?.string,
            let byteCount = fields["byteCount"]?.integerValue,
            let sha256 = fields["sha256"]?.string
        else {
            throw TractandaError("invalidAttachment", "Attachment descriptor has invalid tagged fields.")
        }
        try self.init(
            attachmentID: attachmentID, filename: filename, mediaType: mediaType,
            byteCount: byteCount, sha256: sha256)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let expected: Set<String> = ["attachmentID", "filename", "mediaType", "byteCount", "sha256"]
        guard Set(container.allKeys.map(\.stringValue)) == expected else {
            throw TractandaError(
                "invalidAttachment", "Attachment descriptor contains unknown or missing keys.")
        }
        try self.init(
            attachmentID: container.decode(String.self, forKey: AnyCodingKey("attachmentID")),
            filename: container.decode(String.self, forKey: AnyCodingKey("filename")),
            mediaType: container.decode(String.self, forKey: AnyCodingKey("mediaType")),
            byteCount: container.decode(Int64.self, forKey: AnyCodingKey("byteCount")),
            sha256: container.decode(String.self, forKey: AnyCodingKey("sha256")))
    }

    public var itemValue: ItemValue {
        .object([
            "attachmentID": .text(attachmentID),
            "filename": .text(filename),
            "mediaType": .text(mediaType),
            "byteCount": .integer(byteCount),
            "sha256": .text(sha256),
        ])
    }

    public static func descriptors(in fields: [String: ItemValue]) throws -> [Self] {
        guard let value = fields[fieldName] else { return [] }
        guard let entries = value.array, entries.count <= maximumAttachments else {
            throw TractandaError(
                "invalidAttachment", "attachments must be a list of at most 128 descriptors.")
        }
        let descriptors = try entries.map(Self.init)
        guard Set(descriptors.map(\.attachmentID)).count == descriptors.count else {
            throw TractandaError("invalidAttachment", "Attachment IDs must be unique within an item.")
        }
        return descriptors
    }

    private static func validateVersion1ID(_ value: String) throws {
        try Identifier.validate(value)
        guard let uuid = UUID(uuidString: value) else {
            throw TractandaError("invalidAttachment", "Attachment ID must be a canonical UUIDv1.")
        }
        var raw = uuid.uuid
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        guard bytes[6] >> 4 == 1, bytes[8] & 0xC0 == 0x80 else {
            throw TractandaError("invalidAttachment", "Attachment ID must be a canonical UUIDv1.")
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func isMediaType(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty
                && part.utf8.allSatisfy { byte in
                    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                        || "!#$&^_.+-".utf8.contains(byte)
                }
        }
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?
        init(_ string: String) {
            stringValue = string
            intValue = nil
        }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
}
