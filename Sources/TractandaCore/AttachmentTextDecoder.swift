import Crypto
import Foundation
import TractandaClient

/// Deterministic extraction for small UTF-8 text and Markdown originals. Model conversion and
/// arbitrary document parsing remain separate versioned converters.
enum AttachmentTextDecoder {
    static func decode(
        _ data: Data, source: AttachmentTextSource, representationID: String,
        attachmentID: String, extractedAt: String
    ) throws -> AttachmentTextRepresentation {
        guard data.count <= AttachmentTextRepresentation.maximumInputBytes else {
            throw TractandaError("resourceLimit", "Attachment text extraction is limited to 512 KiB.")
        }
        guard source.attachmentID == attachmentID, source.byteCount == Int64(data.count) else {
            throw TractandaError("attachmentIntegrity", "Attachment text source identity or size changed.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == source.sha256 else {
            throw TractandaError("attachmentIntegrity", "Attachment text source digest does not match.")
        }
        guard ["text/plain", "text/markdown"].contains(source.mediaType.lowercased()) else {
            throw TractandaError(
                "unsupportedAttachmentText", "Only text/plain and text/markdown are supported.")
        }

        let bytes = Array(data.prefix(3))
        let bom = bytes == [0xEF, 0xBB, 0xBF]
        let sourceByteStart = bom ? 3 : 0
        let textBytes = bom ? Data(data.dropFirst(3)) : data
        // Foundation's data initializer can strip another BOM. Decode raw scalars and
        // reject any replacement by requiring an exact UTF8 round trip.
        let text = String(decoding: textBytes, as: UTF8.self)
        guard Data(text.utf8) == textBytes else {
            throw TractandaError("invalidAttachmentText", "Attachment is not valid UTF-8.")
        }
        let representation = try AttachmentTextRepresentation(
            representationID: representationID, attachmentID: attachmentID, source: source,
            extractedAt: extractedAt, text: text, sourceByteStart: sourceByteStart)
        try validate(representation)
        return representation
    }

    /// Rechecks retained extraction bytes without reopening the original attachment.
    static func validate(_ representation: AttachmentTextRepresentation) throws {
        var bytes = Data()
        if representation.sourceByteStart == 3 {
            bytes.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        bytes.append(contentsOf: representation.text.utf8)
        guard bytes.count <= AttachmentTextRepresentation.maximumInputBytes,
            Int64(bytes.count) == representation.source.byteCount
        else {
            throw TractandaError("attachmentIntegrity", "Attachment-text bytes do not match source size.")
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == representation.source.sha256 else {
            throw TractandaError("attachmentIntegrity", "Attachment-text bytes do not match source digest.")
        }
    }
}
