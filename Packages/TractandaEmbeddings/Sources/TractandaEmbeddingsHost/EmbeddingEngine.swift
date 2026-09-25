import Foundation
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import MLXNN
import VMLXTokenizers

struct EmbeddingFailure: Error, Sendable {
    let status: Int
    let message: String
}

struct EmbeddingEntry: Codable, Sendable {
    var object = "embedding"
    let index: Int
    let embedding: [Float]
}

struct EmbeddingUsage: Codable, Sendable {
    let promptTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case totalTokens = "total_tokens"
    }
}

struct EmbeddingResponse: Codable, Sendable {
    var object = "list"
    var model = ModelProfile.alias
    let data: [EmbeddingEntry]
    let usage: EmbeddingUsage
    var modelRevision = ModelProfile.revision

    enum CodingKeys: String, CodingKey {
        case object, model, data, usage
        case modelRevision = "model_revision"
    }
}

protocol EmbeddingServing: Sendable {
    func embed(_ texts: [String]) async throws -> EmbeddingResponse
}

/// All model/tokenizer/MLX values stay inside the library's actor. Returning
/// evaluated Swift numbers also makes disconnected-request cancellation safe.
actor GraniteEmbedder: EmbeddingServing {
    private let container: MLXEmbedders.ModelContainer

    init(directory: URL) async throws {
        container = try await MLXEmbedders.loadModelContainer(
            from: directory, using: #huggingFaceTokenizerLoader())
        await container.perform { model, _, _ in
            model.train(false)
            // The pinned model bytes remain immutable; compute in FP32 so the
            // serving precision is explicit and independent of device defaults.
            model.update(parameters: model.parameters().mapValues { $0.asType(.float32) })
            eval(model)
        }
    }

    func embed(_ texts: [String]) async throws -> EmbeddingResponse {
        guard (1...16).contains(texts.count), texts.allSatisfy({ !$0.isEmpty }) else {
            throw EmbeddingFailure(status: 400, message: "Supply 1...16 nonempty inputs.")
        }
        return try await container.perform { model, tokenizer, pooler in
            try Task.checkCancellation()
            switch pooler.strategy {
            case .cls: break
            default:
                throw EmbeddingFailure(
                    status: 500, message: "Unexpected pooling for the pinned Granite model.")
            }
            let tokens = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
            guard tokens.allSatisfy({ !$0.isEmpty && $0.count <= ModelProfile.maximumInputTokens }),
                tokens.reduce(0, { $0 + $1.count }) <= ModelProfile.maximumBatchTokens
            else {
                throw EmbeddingFailure(
                    status: 400,
                    message: "Input or batch exceeds the pinned token limit; no truncation was performed.")
            }

            // Evaluate inputs separately so one long string cannot pad every
            // other batch member to 32k tokens and multiply peak allocation.
            var entries: [EmbeddingEntry] = []
            for (index, row) in tokens.enumerated() {
                try Task.checkCancellation()
                let ids = MLXArray(row).expandedDimensions(axis: 0)
                let mask = MLXArray.ones(like: ids)
                let output = model(
                    ids, positionIds: nil, tokenTypeIds: nil, attentionMask: mask)
                let pooled = pooler(output, mask: mask, normalize: true, applyLayerNorm: false)
                    .asType(.float32)
                pooled.eval()
                let raw = pooled.reshaped([-1]).asArray(Float.self)
                guard raw.count == ModelProfile.dimensions, raw.allSatisfy(\.isFinite) else {
                    throw EmbeddingFailure(status: 500, message: "Invalid embedding dimensions or values.")
                }
                let norm = sqrt(raw.reduce(0.0) { $0 + Double($1) * Double($1) })
                guard norm.isFinite, norm > 0 else {
                    throw EmbeddingFailure(status: 500, message: "Invalid embedding magnitude.")
                }
                let vector = raw.map { Float(Double($0) / norm) }
                entries.append(EmbeddingEntry(index: index, embedding: vector))
            }
            try Task.checkCancellation()
            let count = tokens.reduce(0) { $0 + $1.count }
            return EmbeddingResponse(
                data: entries, usage: EmbeddingUsage(promptTokens: count, totalTokens: count))
        }
    }
}
