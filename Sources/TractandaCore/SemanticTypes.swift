import Foundation
import TractandaVectors

/// Immutable, access-safe material handed from the serial store executor to the semantic worker.
/// It contains no `ItemStore`, SQLite handle or caller context.
struct SemanticSnapshot: Sendable, Equatable {
    let itemID: String
    let revisionID: String
    let subject: String
    let body: String
    let sourceText: String
    let profileID: String
    let contentHash: String
}

private struct SemanticContentIdentity: Codable {
    let sourceText: String
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
    /// Extraction rules participate in identity so an upgrade cannot reuse stale vectors.
    let itemTextProfile: String
}

enum SemanticSource {
    /// The exact owned-text representation used for chunking, embeddings, and passage ranges.
    static func contentHash(sourceText: String) throws -> String {
        SemanticChunker.hash(try JSON.encode(SemanticContentIdentity(sourceText: sourceText)))
    }

    static func profileID(_ configuration: SemanticConfiguration) throws -> String {
        let identity = SemanticProfileIdentity(
            formatVersion: 1,
            model: configuration.model,
            modelRevision: configuration.modelRevision,
            dimensions: configuration.dimensions,
            documentPrefix: configuration.documentPrefix,
            queryPrefix: configuration.queryPrefix,
            chunkBytes: configuration.chunkBytes,
            overlapBytes: configuration.overlapBytes,
            pooling: configuration.pooling,
            normalization: configuration.normalization,
            inputEncoding: configuration.inputEncoding,
            itemTextProfile: ItemTextContent.profile)
        return SemanticChunker.hash(try JSON.encode(identity))
    }
}

struct SemanticChunk: Sendable, Equatable {
    let ordinal: Int
    let byteRange: Range<Int>
    let text: String
    let hash: String
}

/// Byte boundaries are adjusted to Unicode scalar boundaries, preserve every byte of source text,
/// and overlap only adjacent chunks.  Token limits remain a runtime/model validation concern.
enum SemanticChunker {
    static func chunks(_ text: String, chunkBytes: Int, overlapBytes: Int) throws -> [SemanticChunk] {
        guard (32...16_384).contains(chunkBytes), (0..<chunkBytes).contains(overlapBytes) else {
            throw TractandaError("semanticChunking", "Invalid chunk size or overlap.")
        }
        guard !text.isEmpty else { return [] }
        let bytes = Array(text.utf8)
        var result: [SemanticChunk] = []
        var start = 0
        while start < bytes.count {
            var end = min(bytes.count, start + chunkBytes)
            while end > start && end < bytes.count && (bytes[end] & 0b1100_0000) == 0b1000_0000 { end -= 1 }
            guard end > start else {
                throw TractandaError("semanticChunking", "Cannot find a UTF-8 boundary.")
            }
            let data = Data(bytes[start..<end])
            guard let part = String(data: data, encoding: .utf8) else {
                throw TractandaError("semanticChunking", "Chunk is not valid UTF-8.")
            }
            result.append(
                SemanticChunk(
                    ordinal: result.count, byteRange: start..<end, text: part,
                    hash: SemanticChunker.hash(data)))
            guard end < bytes.count else { break }
            var next = end - overlapBytes
            while next > start && (bytes[next] & 0b1100_0000) == 0b1000_0000 { next -= 1 }
            guard next > start else {
                throw TractandaError("semanticChunking", "Overlap cannot make progress.")
            }
            start = next
        }
        return result
    }

    static func hash(_ data: Data) -> String {
        Vec1Index.stableDataHash(data)
    }
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
    let expiresAt: Date
    let evaluatedAt: Date
    let timeZone: String
}

struct SemanticPassage: Codable, Sendable, Equatable {
    let itemID: String
    let revisionID: String
    let byteStart: Int
    let byteEnd: Int
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
