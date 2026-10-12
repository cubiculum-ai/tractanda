import Foundation

private struct LocationKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// One citation surface distinguishes exact original bytes from estimated document
/// regions. A document location never carries an original-byte offset.
public enum AttachmentSourceLocation: Codable, Equatable, Sendable {
    case originalBytes(byteStart: Int, byteEnd: Int)
    case document(
        pageNumber: Int, blockIndex: Int, rasterSHA256: String,
        geometry: DocumentPageGeometry, box: DoclingBoundingBox?)

    private enum CodingKeys: String, CodingKey {
        case kind, byteStart, byteEnd, pageNumber, blockIndex, rasterSHA256, geometry, box
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let actual = try decoder.container(keyedBy: LocationKey.self)
        let keys = Set(actual.allKeys.map(\.stringValue))
        switch try c.decode(String.self, forKey: .kind) {
        case "originalBytes":
            guard keys == ["kind", "byteStart", "byteEnd"] else {
                throw TractandaError("invalidAttachmentSource", "Original-byte locator has foreign fields.")
            }
            let start = try c.decode(Int.self, forKey: .byteStart)
            let end = try c.decode(Int.self, forKey: .byteEnd)
            guard start >= 0, end >= start else {
                throw TractandaError("invalidAttachmentSource", "Invalid original-byte locator.")
            }
            self = .originalBytes(byteStart: start, byteEnd: end)
        case "document":
            guard keys.isSubset(of: ["kind", "pageNumber", "blockIndex", "rasterSHA256", "geometry", "box"]),
                keys.isSuperset(of: ["kind", "pageNumber", "blockIndex", "rasterSHA256", "geometry"])
            else { throw TractandaError("invalidAttachmentSource", "Document locator has foreign fields.") }
            let page = try c.decode(Int.self, forKey: .pageNumber)
            let block = try c.decode(Int.self, forKey: .blockIndex)
            let hash = try c.decode(String.self, forKey: .rasterSHA256)
            let geometry = try c.decode(DocumentPageGeometry.self, forKey: .geometry)
            let box = try c.decodeIfPresent(DoclingBoundingBox.self, forKey: .box)
            guard page > 0, (0..<DoclingParsedPage.maximumBlocks).contains(block),
                hash.utf8.count == 64,
                hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw TractandaError("invalidAttachmentSource", "Invalid document locator.") }
            try geometry.validate()
            try box?.validate()
            self = .document(
                pageNumber: page, blockIndex: block, rasterSHA256: hash, geometry: geometry, box: box)
        default:
            throw TractandaError("invalidAttachmentSource", "Unsupported attachment locator kind.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .originalBytes(let start, let end):
            try c.encode("originalBytes", forKey: .kind)
            try c.encode(start, forKey: .byteStart)
            try c.encode(end, forKey: .byteEnd)
        case .document(let page, let block, let hash, let geometry, let box):
            try c.encode("document", forKey: .kind)
            try c.encode(page, forKey: .pageNumber)
            try c.encode(block, forKey: .blockIndex)
            try c.encode(hash, forKey: .rasterSHA256)
            try c.encode(geometry, forKey: .geometry)
            try c.encodeIfPresent(box, forKey: .box)
        }
    }

    /// Exact overlap adjusts byte locations only. A partial OCR-text overlap retains
    /// the whole estimated block region, without pretending to locate its glyphs.
    func overlap(offset: Int, length: Int) -> Self {
        switch self {
        case .originalBytes(let start, _):
            return .originalBytes(byteStart: start + offset, byteEnd: start + offset + length)
        case .document:
            return self
        }
    }
}
