import Foundation

/// A known backend descriptor, never an executable installation recipe supplied by a model.
public struct EmbeddingPayload: Codable, Equatable, Sendable {
    public let backend: String
    public let modelDirectory: String
    public let model: String
    public let modelRevision: String
    public let dimensions: Int

    public static let qwen = EmbeddingPayload(
        backend: "vmlx-qwen3-f32-v1", modelDirectory: "models/qwen3-embedding-0.6b",
        model: "tractanda-qwen3-embedding-0.6b-vmlx-fp32-97b0c614",
        modelRevision:
            "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3:weights-bf16:compute-f32:0437e45c94563b09e13cb7a64478fc406947a93cb34a7e05870fc8dcd48e23fd:vmlx-d47c8d0dad91d8c0628a24a5a2c4cada082dc2ee",
        dimensions: 1024)

    func validate(files: [BundleManifest.File]) throws {
        guard self == Self.qwen else {
            throw SetupError("This preview does not support the bundled embedding descriptor.")
        }
        let names = Set(files.map(\.path))
        for path in [
            "bin/tractanda-embeddings", "licenses/Qwen3/LICENSE", "licenses/Qwen3/README.md",
            modelDirectory + "/model.safetensors", modelDirectory + "/tokenizer.json",
            modelDirectory + "/manifest.json",
        ] {
            guard names.contains(path) else { throw SetupError("Missing embedding payload file: \(path)") }
        }
    }
}
