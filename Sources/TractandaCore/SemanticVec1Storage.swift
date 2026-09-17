import Foundation
import TractandaVectors

/// Thread-confined Vec1 bridge. SemanticService's serial maintenance executor
/// is its only caller.
final class SemanticVec1Storage: SemanticVectorStorage {
    private let index: Vec1Index

    init(path: String, dimensions: Int, profileID: String) throws {
        index = try Vec1Index(path: path, dimensions: dimensions, profileID: profileID)
    }

    func identity(itemID: String, profileID: String) throws -> SemanticIndexedIdentity? {
        guard index.profileID == profileID, let metadata = try index.itemMetadata(itemID: itemID),
            metadata.recordCount > 0
        else { return nil }
        return SemanticIndexedIdentity(
            revisionID: metadata.revisionID, profileID: profileID, contentHash: metadata.contentHash,
            count: metadata.recordCount)
    }

    func hasCurrent(itemID: String, profileID: String, contentHash: String) throws -> Bool {
        try index.itemMetadata(itemID: itemID)?.contentHash == contentHash
    }

    func rebind(_ snapshot: SemanticSnapshot) throws {
        try index.updateRevision(
            itemID: snapshot.itemID,
            revisionID: snapshot.revisionID,
            contentHash: snapshot.contentHash)
    }

    func replace(_ snapshot: SemanticSnapshot, chunks: [SemanticChunk], vectors: [[Double]]) throws {
        guard chunks.count == vectors.count else {
            throw TractandaError("semanticIndex", "Chunk/vector count mismatch.")
        }
        let records = try zip(chunks, vectors).map { chunk, vector in
            try SemanticVectorValidation.validate(vector, dimensions: vector.count)
            return VectorRecord(
                id: snapshot.itemID + ":" + String(chunk.ordinal),
                itemID: snapshot.itemID,
                revisionID: snapshot.revisionID,
                contentHash: snapshot.contentHash,
                chunkIndex: chunk.ordinal,
                text: chunk.text,
                vector: vector.map(Float.init))
        }
        try index.replace(itemID: snapshot.itemID, records: records)
    }

    func prune(profileID: String, keeping itemIDs: Set<String>) throws {
        let indexed = Set(try index.itemMetadata().map(\.itemID))
        for itemID in indexed.subtracting(itemIDs) {
            try index.remove(itemID: itemID)
        }
    }

    func search(
        vector: [Double], profileID: String, current: [SemanticSnapshot], limit: Int
    ) throws -> [SemanticIndexedPassage] {
        let filters = current.map {
            Vec1RecordFilter(itemID: $0.itemID, revisionID: $0.revisionID, contentHash: $0.contentHash)
        }
        return try index.searchBestPerItem(
            query: vector.map(Float.init), allowedRecords: filters, limit: limit
        ).map {
            SemanticIndexedPassage(
                itemID: $0.itemID,
                revisionID: $0.revisionID,
                profileID: profileID,
                contentHash: $0.contentHash,
                ordinal: $0.chunkIndex,
                byteRange: 0..<0,
                vector: [],
                score: 1 - Double($0.distance))
        }
    }

    func reset() throws {
        try index.reset()
    }
}
