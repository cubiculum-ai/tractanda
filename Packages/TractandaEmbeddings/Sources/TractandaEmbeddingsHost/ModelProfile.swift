import Crypto
import Foundation

enum ModelProfile {
    static let alias = "tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559"
    static let modelRevision = "44399559930365213510b1ee2eb15ded83374f0e"
    static let vmlxRevision = "b7a2b97efc2d8ed44ddf3c4b7af25766b372339f"
    static let revision =
        "\(modelRevision):weights-bf16:compute-f32:dcb6431bfa6e817fe100a2b0521360cec3383963b03fa966b685de18ca310d31:vmlx-\(vmlxRevision)"
    static let dimensions = 768
    static let pooling = "cls"
    static let normalization = "l2"
    static let maximumInputTokens = 32_768
    static let maximumBatchTokens = 32_768

    static let assets: [String: String] = [
        "1_Pooling/config.json": "781299da695e58439d70d491840da22ea0935d1d57d9646eb9725f1f19754e89",
        "config.json": "e1e3fc842a8e0537e25d6e4c93879698b92ae96722e8c162bef334b57978a3b0",
        "config_sentence_transformers.json":
            "f09adf93fcf868bb2fc3976a435d810b2ecdffa953d1da091d2a91168abab44b",
        "model.safetensors": "dcb6431bfa6e817fe100a2b0521360cec3383963b03fa966b685de18ca310d31",
        "modules.json": "84e40c8e006c9b1d6c122e02cba9b02458120b5fb0c87b746c41e0207cf642cf",
        "sentence_bert_config.json": "967ef958285e4a7a37d8ff1832473d967edd913b4e48572f31c3d3ea361d5327",
        "special_tokens_map.json": "cb9e60dcf4d8d314315cb3e761fe4c2e664fda8dbf66d7815372b2639e381182",
        "tokenizer.json": "0087c868b33bad550a78a08d19798cfd7f713cde4f020803b8f51f405503e15f",
        "tokenizer_config.json": "7947bdf0378520e69ca412b8c4dacd1cffa8aef099f851fdd5c65aa27c6b36a0",
    ]

    struct Descriptor: Encodable {
        let alias: String
        let revision: String
        let modelRevision: String
        let vmlxRevision: String
        let dimensions: Int
        let pooling: String
        let normalization: String
        let maximumInputTokens: Int
        let maximumBatchTokens: Int
        let assets: [String: String]
    }

    static let descriptor = Descriptor(
        alias: alias, revision: revision, modelRevision: modelRevision, vmlxRevision: vmlxRevision,
        dimensions: dimensions, pooling: pooling, normalization: normalization,
        maximumInputTokens: maximumInputTokens, maximumBatchTokens: maximumBatchTokens, assets: assets)

    static func validate(directory: URL) throws {
        let manager = FileManager.default
        guard
            let enumerator = manager.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else {
            throw EmbeddingFailure(status: 500, message: "Pinned model directory cannot be read.")
        }
        var files = Set<String>()
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw EmbeddingFailure(
                    status: 500, message: "Pinned model assets must not be symbolic links.")
            }
            guard values.isRegularFile == true else { continue }
            let path = file.path.replacingOccurrences(of: directory.path + "/", with: "")
            files.insert(path)
            guard let expected = assets[path], try digest(file) == expected else {
                throw EmbeddingFailure(status: 500, message: "Pinned model asset verification failed.")
            }
        }
        guard files == Set(assets.keys) else {
            throw EmbeddingFailure(status: 500, message: "Model directory differs from the pinned asset set.")
        }
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
