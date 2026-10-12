import Foundation

/// Bounded current source read. All offsets count UTF8 bytes, never Swift characters.
public struct ExtractedTextUnitResult: Codable, Sendable {
    public struct Identity: Codable, Sendable {
        public let itemID: String
        public let revisionID: String
        public let layout: String
        public let contentHash: String
        public let unitCount: Int64
        public let utf8Bytes: Int64
    }
    public struct Origin: Codable, Sendable {
        public let kind: String
        public let fieldPath: String?
        public let attachmentID: String?
        public let representationID: String?
        public let contentID: String?
        public let documentSource: AttachmentDocumentSource?
        public let textSource: AttachmentTextSource?
        public let pageNumber: Int64?
        public let sourceByteStart: Int64?
        public let sourceByteEnd: Int64?
        public let rasterSHA256: String?
        public let geometry: DocumentPageGeometry?
    }
    public struct Span: Codable, Sendable {
        public let blockIndex: Int64
        public let unitByteStart: Int64
        public let unitByteEnd: Int64
        public let box: DoclingBoundingBox?
    }
    public struct Unit: Codable, Sendable {
        public let ordinal: Int64
        public let corpusByteStart: Int64
        public let utf8Bytes: Int64
        public let offset: Int64
        public let nextOffset: Int64
        public let text: String
        public let origin: Origin
        public let spans: [Span]
        public let coverage: DocumentCoverage?
    }
    public struct Continuation: Codable, Sendable {
        public let unit: Int64
        public let offset: Int64
    }
    public struct Verification: Codable, Sendable {
        public let status: String
        public let scope: String
    }
    public let itemID: String
    public let revisionID: String
    public let sourceIdentity: Identity
    public let unit: Unit
    public let next: Continuation?
    public let indexConsistency: Verification
    public let canonicalVerification: Verification
    public let globalPlacementVerified: Bool
    public let wholeDocumentVerified: Bool
}

extension ItemClient {
    /// Requires freshly declared tractanda.extracted-text-units.v1 support. A continuation is
    /// pinned to expectedRevisionID; a changed head requires a fresh current read.
    public func extractedTextUnit(
        itemID: String, expectedRevisionID: String, unit: Int64, offset: Int64 = 0,
        limit: Int = 65_536, maxBytes: Int = 524_288
    ) async throws -> ExtractedTextUnitResult {
        struct Arguments: Encodable, Sendable {
            let itemID: String
            let expectedRevisionID: String
            let unit: Int64
            let offset: Int64
            let limit: Int
            let maxBytes: Int
        }
        guard unit >= 0, unit < Int64.max, offset >= 0, offset < Int64.max,
            (1...262_144).contains(limit), (8_192...524_288).contains(maxBytes)
        else { throw TractandaError("invalidArguments", "Use a bounded UTF8 source unit window.") }
        return try await call(
            "TractandaItem/extractedTextUnit",
            arguments: Arguments(
                itemID: itemID, expectedRevisionID: expectedRevisionID, unit: unit,
                offset: offset, limit: limit, maxBytes: maxBytes), returning: ExtractedTextUnitResult.self)
    }
}
