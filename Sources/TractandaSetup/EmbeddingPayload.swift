import Foundation

/// A known backend descriptor, never an executable installation recipe supplied by a model.
public struct EmbeddingPayload: Codable, Equatable, Sendable {
    public let backend: String
    public let modelDirectory: String
    public let model: String
    public let modelRevision: String
    public let dimensions: Int

    /// Retained solely to recognize the installer-owned pilot configuration during upgrade.
    /// New bundles must use `granite`.
    static let legacyQwen = EmbeddingPayload(
        backend: "vmlx-qwen3-f32-v1", modelDirectory: "models/qwen3-embedding-0.6b",
        model: "tractanda-qwen3-embedding-0.6b-vmlx-fp32-97b0c614",
        modelRevision:
            "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3:weights-bf16:compute-f32:0437e45c94563b09e13cb7a64478fc406947a93cb34a7e05870fc8dcd48e23fd:vmlx-d47c8d0dad91d8c0628a24a5a2c4cada082dc2ee",
        dimensions: 1024)

    public static let granite = EmbeddingPayload(
        backend: "vmlx-granite-embedding-f32-v1",
        modelDirectory: "models/granite-embedding-311m-multilingual-r2",
        model: "tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559",
        modelRevision:
            "44399559930365213510b1ee2eb15ded83374f0e:weights-bf16:compute-f32:dcb6431bfa6e817fe100a2b0521360cec3383963b03fa966b685de18ca310d31:vmlx-b7a2b97efc2d8ed44ddf3c4b7af25766b372339f",
        dimensions: 768)

    func validate(files: [BundleManifest.File]) throws {
        guard self == Self.granite else {
            throw SetupError("This preview does not support the bundled embedding descriptor.")
        }
        let names = Set(files.map(\.path))
        let required = [
            "bin/tractanda-embeddings", "licenses/Granite/LICENSE", "licenses/Granite/README.md",
            modelDirectory + "/model.safetensors", modelDirectory + "/config.json",
            modelDirectory + "/1_Pooling/config.json", modelDirectory + "/config_sentence_transformers.json",
            modelDirectory + "/modules.json", modelDirectory + "/sentence_bert_config.json",
            modelDirectory + "/special_tokens_map.json", modelDirectory + "/tokenizer.json",
            modelDirectory + "/tokenizer_config.json",
        ]
        for path in required {
            guard names.contains(path) else { throw SetupError("Missing embedding payload file: \(path)") }
        }
    }
}
