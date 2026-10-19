import Foundation
import TractandaVectors

/// The immutable source identity and a bounded, leased handle; no source text or store crosses executors.
struct SemanticSnapshot: Sendable, Equatable {
    let corpus: IndexedCorpusSnapshot
    let profileID: String
    let dimensions: Int
    var itemID: String { corpus.identity.itemID }
    var revisionID: String { corpus.identity.revisionID }
    var contentHash: String { corpus.identity.contentHash }
}

struct SemanticProfileIdentity: Codable {
    let formatVersion: Int
    let model: String
    let modelRevision: String
    let dimensions: Int
    let documentPrefix: String
    let queryPrefix: String
    let chunkBytes: Int
    let overlapBytes: Int
    let pooling: SemanticPooling
    let normalization: SemanticNormalization
    let inputEncoding: SemanticInputEncoding
    let itemTextProfile: String
}

private struct SemanticContentIdentity: Codable { let sourceText: String }

enum SemanticSource {
    static func passageSources(
        _ snapshot: SemanticSnapshot, window: IndexedCorpusUnitWindow, range: Range<Int>, unitStart: Int64 = 0
    ) throws -> [AttachmentPassageSource] {
        let origin = window.origin
        let contentStart = try PageCorpusEmitter.add(unitStart, Int64(prefix(origin).utf8.count))
        guard let attachmentID = origin.attachmentID, let representationID = origin.representationID else {
            return []
        }
        if let source = origin.textSource, let sourceStart = origin.sourceByteStart {
            let localStart = max(0, Int64(range.lowerBound) - contentStart)
            let localEnd = min(window.byteCount, Int64(range.upperBound) - contentStart)
            guard localStart < localEnd else { return [] }
            guard localStart >= 0, localEnd >= localStart else {
                throw TractandaError("semanticIndex", "Citation range is outside its unit.")
            }
            guard let start = Int(exactly: try PageCorpusEmitter.add(sourceStart, localStart)),
                let end = Int(exactly: try PageCorpusEmitter.add(sourceStart, localEnd))
            else { throw TractandaError("semanticIndex", "Citation byte range overflow.") }
            guard let lower = Int(exactly: try PageCorpusEmitter.add(contentStart, localStart)),
                let upper = Int(exactly: try PageCorpusEmitter.add(contentStart, localEnd))
            else { throw TractandaError("semanticIndex", "Citation corpus range overflow.") }
            let segment = AttachmentSourceSegment(
                itemID: snapshot.itemID, revisionID: snapshot.revisionID, attachmentID: attachmentID,
                representationID: representationID, sourceSHA256: source.sha256,
                corpusByteStart: lower, corpusByteEnd: upper,
                location: .originalBytes(byteStart: start, byteEnd: end))
            return segment.overlap(with: lower..<upper).map { [$0] } ?? []
        }
        guard let source = origin.documentSource, let page = origin.pageNumber,
            let pageNumber = Int(exactly: page), let raster = origin.rasterSHA256,
            let geometry = origin.geometry
        else { return [] }
        return try window.spans.compactMap { span -> AttachmentPassageSource? in
            let start = max(
                Int64(range.lowerBound), try PageCorpusEmitter.add(contentStart, span.unitByteStart))
            let end = min(
                Int64(range.upperBound), try PageCorpusEmitter.add(contentStart, span.unitByteEnd))
            guard start < end, let lower = Int(exactly: start), let upper = Int(exactly: end),
                let block = Int(exactly: span.blockIndex)
            else { return nil }
            let location = AttachmentSourceLocation.document(
                pageNumber: pageNumber, blockIndex: block,
                rasterSHA256: raster, geometry: geometry, box: span.box)
            let segment = AttachmentSourceSegment(
                itemID: snapshot.itemID, revisionID: snapshot.revisionID, attachmentID: attachmentID,
                representationID: representationID, sourceSHA256: source.sha256,
                corpusByteStart: lower, corpusByteEnd: upper, location: location)
            return segment.overlap(with: lower..<upper)
        }
    }

    static func prefix(_ origin: PageCorpusOrigin) -> String {
        switch origin.kind {
        case "field":
            if origin.fieldPath == "field[\"subject\"]" { return "subject:\n" }
            if origin.fieldPath == "field[\"body\"]" { return "body:\n" }
            return "metadata:\n" + (origin.fieldPath ?? "field") + ":\n"
        case "originalBytes": return "metadata:\nattachment:\n"
        case "document": return "metadata:\nattachment page:\n"
        default: return ""
        }
    }
    static func readUnitWindow(
        _ snapshot: IndexedCorpusSnapshot, ordinal: Int64, offset: Int64, limit: Int,
        boundary: () throws -> Void = {}
    ) throws -> SemanticUnitWindow {
        guard offset >= 0, (1...16_384).contains(limit) else {
            throw TractandaError("semanticChunking", "Invalid semantic source window.")
        }
        try boundary()
        let header = try ItemIndex.readCorpusUnit(
            snapshot, ordinal: ordinal, offset: 0, limit: 4, boundary: boundary)
        let label = Data(prefix(header.origin).utf8)
        let prefixCount = Int64(label.count)
        let total = try PageCorpusEmitter.add(prefixCount, header.byteCount)
        guard offset < total else {
            throw TractandaError("semanticChunking", "Semantic offset is past its source unit.")
        }
        var data = Data()
        if offset < prefixCount {
            guard let start = Int(exactly: offset) else {
                throw TractandaError("resourceLimit", "Prefix offset is not addressable.")
            }
            data.append(label[start..<min(label.count, start + limit)])
        }
        var raw = header
        let remaining = limit - data.count
        if remaining > 0 {
            let sourceOffset = max(0, offset - prefixCount)
            // Read a scalar even when only1-3 bytes remain after a label; trim the combined window.
            raw = try ItemIndex.readCorpusUnit(
                snapshot, ordinal: ordinal, offset: sourceOffset, limit: max(4, remaining), boundary: boundary
            )
            data.append(raw.data)
            if data.count > limit { data = Data(data.prefix(limit)) }
        }
        if String(data: data, encoding: .utf8) == nil {
            var valid = false
            for trim in 1...min(3, data.count) {
                let candidate = data.dropLast(trim)
                if !candidate.isEmpty, String(data: candidate, encoding: .utf8) != nil {
                    data = Data(candidate)
                    valid = true
                    break
                }
            }
            guard valid else {
                throw TractandaError("semanticChunking", "Semantic window is not valid UTF-8.")
            }
        }
        guard !data.isEmpty, data.count <= limit else {
            throw TractandaError("semanticChunking", "Semantic window cannot make progress.")
        }
        return .init(
            raw: raw, data: data, nextOffset: try PageCorpusEmitter.add(offset, Int64(data.count)),
            byteCount: total, prefixBytes: label.count)
    }

    /// Hash for the separate bounded text-extraction API; semantic indexing uses authenticated corpus identity.
    static func contentHash(sourceText: String) throws -> String {
        SemanticChunker.hash(try JSON.encode(SemanticContentIdentity(sourceText: sourceText)))
    }
    static func profileID(_ configuration: SemanticConfiguration) throws -> String {
        let identity = SemanticProfileIdentity(
            formatVersion: 2, model: configuration.model, modelRevision: configuration.modelRevision,
            dimensions: configuration.dimensions, documentPrefix: configuration.documentPrefix,
            queryPrefix: configuration.queryPrefix, chunkBytes: configuration.chunkBytes,
            overlapBytes: configuration.overlapBytes, pooling: configuration.pooling,
            normalization: configuration.normalization, inputEncoding: configuration.inputEncoding,
            itemTextProfile: ItemTextContent.profile)
        return SemanticChunker.hash(try JSON.encode(identity))
    }
}

struct SemanticChunk: Sendable, Equatable {
    let ordinal: Int
    let unitOrdinal: Int64
    let byteRange: Range<Int>
    let unitByteRange: Range<Int>
    let text: String
    let hash: String
}

struct SemanticUnitWindow {
    let raw: IndexedCorpusUnitWindow
    let data: Data
    let nextOffset: Int64
    let byteCount: Int64
    let prefixBytes: Int
}

/// Reads one labeled chunk at a time. Overlap never crosses a page/owned-value boundary.
struct SemanticChunkCursor: Sendable {
    let snapshot: IndexedCorpusSnapshot
    let chunkBytes: Int
    let overlapBytes: Int
    private(set) var unitOrdinal: Int64 = 0
    private(set) var offset: Int64 = 0
    private(set) var ordinal: Int = 0
    private var unitStart: Int64 = 0
    init(snapshot: IndexedCorpusSnapshot, chunkBytes: Int, overlapBytes: Int) throws {
        guard (32...16_384).contains(chunkBytes), (0..<chunkBytes).contains(overlapBytes) else {
            throw TractandaError("semanticChunking", "Invalid chunk size or overlap.")
        }
        self.snapshot = snapshot
        self.chunkBytes = chunkBytes
        self.overlapBytes = overlapBytes
    }
    mutating func next(boundary: () throws -> Void = {}) throws -> SemanticChunk? {
        guard unitOrdinal < snapshot.identity.unitCount else { return nil }
        let window = try SemanticSource.readUnitWindow(
            snapshot, ordinal: unitOrdinal, offset: offset, limit: chunkBytes, boundary: boundary)
        let text = String(decoding: window.data, as: UTF8.self)
        guard window.nextOffset > offset, window.nextOffset <= window.byteCount,
            Data(text.utf8) == window.data, let localStart = Int(exactly: offset),
            let localEnd = Int(exactly: window.nextOffset),
            let start = Int(exactly: try PageCorpusEmitter.add(unitStart, offset)),
            let end = Int(exactly: try PageCorpusEmitter.add(unitStart, window.nextOffset))
        else { throw TractandaError("semanticChunking", "Invalid labeled corpus window.") }
        let chunk = SemanticChunk(
            ordinal: ordinal, unitOrdinal: unitOrdinal, byteRange: start..<end,
            unitByteRange: localStart..<localEnd, text: text, hash: SemanticChunker.hash(window.data))
        guard ordinal < Int.max else { throw TractandaError("resourceLimit", "Chunk count overflow.") }
        ordinal += 1
        if window.nextOffset == window.byteCount {
            unitOrdinal += 1
            unitStart = try PageCorpusEmitter.add(unitStart, window.byteCount)
            offset = 0
        } else {
            var relative = window.data.count - overlapBytes
            while relative > 0 && relative < window.data.count && (window.data[relative] & 0xC0) == 0x80 {
                relative -= 1
            }
            guard relative > 0 else {
                throw TractandaError("semanticChunking", "Overlap cannot make progress.")
            }
            offset = try PageCorpusEmitter.add(offset, Int64(relative))
        }
        return chunk
    }
}

enum SemanticChunker {
    /// Bounded value utility used by source-window callers; maintenance uses SemanticChunkCursor.
    static func chunks(_ text: String, chunkBytes: Int, overlapBytes: Int) throws -> [SemanticChunk] {
        guard text.utf8.count <= 262_144, (32...16_384).contains(chunkBytes),
            (0..<chunkBytes).contains(overlapBytes)
        else { throw TractandaError("semanticChunking", "Invalid bounded source window.") }
        let bytes = Array(text.utf8)
        var result: [SemanticChunk] = []
        var start = 0
        while start < bytes.count {
            var end = min(bytes.count, start + chunkBytes)
            while end < bytes.count && end > start && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
            guard end > start else { throw TractandaError("semanticChunking", "Invalid UTF-8 boundary.") }
            let data = Data(bytes[start..<end])
            let part = String(decoding: data, as: UTF8.self)
            guard Data(part.utf8) == data else {
                throw TractandaError("semanticChunking", "Invalid UTF-8 text.")
            }
            result.append(
                .init(
                    ordinal: result.count, unitOrdinal: 0, byteRange: start..<end, unitByteRange: start..<end,
                    text: part,
                    hash: hash(data)))
            if end == bytes.count { break }
            var next = end - overlapBytes
            while next > start && (bytes[next] & 0xC0) == 0x80 { next -= 1 }
            guard next > start else {
                throw TractandaError("semanticChunking", "Overlap cannot make progress.")
            }
            start = next
        }
        return result
    }
    static func hash(_ data: Data) -> String { Vec1Index.stableDataHash(data) }
}

struct SemanticQuery: Sendable, Equatable {
    let queryID: String
    let callerScope: String
    let profileID: String
    let text: String
    let expression: String?
    let categoryPath: [String]
    let excludedCategoryIDs: [String]
    let viewID: String?
    let limit: Int
    let createdAt: Date
    var expiresAt: Date
    let evaluatedAt: Date
    let timeZone: String
}

struct SemanticPassage: Codable, Sendable, Equatable {
    let itemID: String
    let revisionID: String
    let byteStart: Int64
    let byteEnd: Int64
    let similarity: Double
}

enum SemanticVectorValidation {
    static func validate(_ vector: [Double], dimensions: Int) throws {
        guard vector.count == dimensions, vector.allSatisfy(\.isFinite) else {
            throw TractandaError("semanticProvider", "Embedding dimensions or values are invalid.")
        }
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude.isFinite, magnitude > 0 else {
            throw TractandaError("semanticProvider", "Embedding vector has zero or invalid magnitude.")
        }
    }
}
