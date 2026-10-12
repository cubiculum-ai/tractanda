import Foundation
import TractandaVectors

/// Serial semantic-executor bridge. Its writer policy is supplied by the owning Store.
final class SemanticVec1Storage: SemanticVectorStorage {
    private let index: Vec1Index
    init(
        path: String, dimensions: Int, profileID: String,
        writeBoundary: @escaping (Vec1WriteBatch) throws -> Void = { _ in }
    ) throws {
        index = try Vec1Index(
            path: path, dimensions: dimensions, profileID: profileID,
            makeGenerationID: { try UUID.makeVersion1().uuidString.lowercased() },
            writeBoundary: writeBoundary)
        var debtCursor: String?
        while true {
            let page = try index.retainedWorkPage(after: debtCursor)
            guard let last = page.last else { break }
            for work in page {
                try writeBoundary(
                    .init(
                        phase: .afterCommit, generationID: work.generationID,
                        estimatedAdditionalBytes: 0, recordCount: 0, encodedAdditionalBytes: 0,
                        retainedEncodedBytes: work.encodedBytes))
            }
            debtCursor = last.generationID
        }
        // Opening occurs only after the preceding executor has been fenced. Never inherit live jobs.
        var cursor: String?
        while true {
            let page = try index.stagingGenerationsPage(after: cursor)
            guard let last = page.last else { break }
            for generation in page { try index.discardGeneration(generation) }
            cursor = last.generationID
        }
    }
    func identity(itemID: String, profileID: String) throws -> SemanticIndexedIdentity? {
        guard index.profileID == profileID, let metadata = try index.itemMetadata(itemID: itemID) else {
            return nil
        }
        return .init(
            revisionID: metadata.revisionID, profileID: profileID, contentHash: metadata.contentHash,
            count: metadata.recordCount)
    }
    func hasCurrent(itemID: String, profileID: String, contentHash: String) throws -> Bool {
        guard index.profileID == profileID else { return false }
        return try index.itemMetadata(itemID: itemID)?.contentHash == contentHash
    }
    func rebind(_ snapshot: SemanticSnapshot) throws {
        try index.updateRevision(
            itemID: snapshot.itemID, revisionID: snapshot.revisionID, contentHash: snapshot.contentHash)
    }
    func begin(_ snapshot: SemanticSnapshot) throws -> Vec1Generation {
        try index.beginGeneration(
            itemID: snapshot.itemID, revisionID: snapshot.revisionID, contentHash: snapshot.contentHash)
    }
    func append(_ generation: Vec1Generation, chunks: [SemanticChunk], vectors: [[Double]]) throws {
        guard chunks.count == vectors.count, (1...16).contains(chunks.count) else {
            throw TractandaError("semanticIndex", "Invalid bounded chunk/vector batch.")
        }
        let records = try zip(chunks, vectors).map { chunk, vector in
            try SemanticVectorValidation.validate(vector, dimensions: index.dimensions)
            return VectorRecord(
                id: generation.itemID + ":" + String(chunk.ordinal), itemID: generation.itemID,
                revisionID: generation.revisionID, contentHash: generation.contentHash,
                chunkIndex: chunk.ordinal, text: chunk.text, vector: vector.map(Float.init),
                unitOrdinal: chunk.unitOrdinal, byteStart: Int64(chunk.byteRange.lowerBound),
                byteEnd: Int64(chunk.byteRange.upperBound),
                unitByteStart: Int64(chunk.unitByteRange.lowerBound),
                unitByteEnd: Int64(chunk.unitByteRange.upperBound))
        }
        try index.appendGeneration(generation, records: records)
    }
    func publish(_ generation: Vec1Generation, count: Int64) throws {
        try index.publishGeneration(generation, expectedRecordCount: count)
    }
    func discard(_ generation: Vec1Generation) throws { try index.discardGeneration(generation) }
    func prune(profileID: String, current: (String) throws -> Bool) throws {
        guard index.profileID == profileID else { return }
        var cursor: String?
        while true {
            let page = try index.itemMetadataPage(after: cursor)
            guard let last = page.last else { break }
            for metadata in page where try !current(metadata.itemID) {
                try index.remove(itemID: metadata.itemID)
            }
            cursor = last.itemID
        }
    }
    func metadataPage(after itemID: String?) throws -> [Vec1ItemMetadata] {
        try index.itemMetadataPage(after: itemID)
    }
    func remove(itemID: String) throws { try index.remove(itemID: itemID) }
    func cleanup() throws { _ = try index.cleanupUnpublished() }
    func retainedWorkPage(after id: String?) throws -> [Vec1RetainedWork] {
        try index.retainedWorkPage(after: id)
    }
    func search(
        vector: [Double], profileID: String, limit: Int,
        current: (_ visit: (SemanticSnapshot) throws -> Void) throws -> Void
    ) throws -> [SemanticIndexedPassage] {
        guard index.profileID == profileID else { return [] }
        return try index.searchBestPerItem(query: vector.map(Float.init), limit: limit) { visit in
            try withoutActuallyEscaping(visit) { emit in
                try current { snapshot in
                    try emit(
                        .init(
                            itemID: snapshot.itemID, revisionID: snapshot.revisionID,
                            contentHash: snapshot.contentHash))
                }
            }
        }.map { hit in
            guard let start = Int(exactly: hit.byteStart), let end = Int(exactly: hit.byteEnd),
                let localStart = Int(exactly: hit.unitByteStart), let localEnd = Int(exactly: hit.unitByteEnd)
            else {
                throw TractandaError("semanticIndex", "Passage offsets exceed the platform range.")
            }
            return .init(
                itemID: hit.itemID, revisionID: hit.revisionID, profileID: profileID,
                contentHash: hit.contentHash, ordinal: hit.chunkIndex, unitOrdinal: hit.unitOrdinal,
                byteRange: start..<end, unitByteRange: localStart..<localEnd, text: hit.text,
                score: 1 - Double(hit.distance))
        }
    }
    func reset() throws { try index.reset() }
}
