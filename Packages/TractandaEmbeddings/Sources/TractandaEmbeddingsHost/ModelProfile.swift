import Crypto
import Foundation

enum ModelProfile {
    static let alias = "tractanda-qwen3-embedding-0.6b-vmlx-fp32-97b0c614"
    static let revision =
        "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3:weights-bf16:compute-f32:0437e45c94563b09e13cb7a64478fc406947a93cb34a7e05870fc8dcd48e23fd:vmlx-d47c8d0dad91d8c0628a24a5a2c4cada082dc2ee"
    static let maximumInputTokens = 32_768
    static let maximumBatchTokens = 32_768

    // The original frozen public model, including tokenizer/configuration
    // inputs. A mutable tokenizer must not silently retain the same profile.
    static let assets: [String: String] = [
        "config.json": "b5bf1f51fc45be473a54718cef92448d90a1be001bf9b9a44b8c7f10a19feaa9",
        "config_sentence_transformers.json":
            "10667c72ddb772627bf1780cb7f86af8e2ae0032b8c243c731172064105c6961",
        "manifest.json": "c278eabca829cc702380a5b82abf0d37098612a976111da340ca5486f751506a",
        "merges.txt": "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
        "model.safetensors": "0437e45c94563b09e13cb7a64478fc406947a93cb34a7e05870fc8dcd48e23fd",
        "tokenizer.json": "def76fb086971c7867b829c23a26261e38d9d74e02139253b38aeb9df8b4b50a",
        "tokenizer_config.json": "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0",
        "vocab.json": "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
    ]

    static func validate(directory: URL) throws {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard Set(files.map(\.lastPathComponent)) == Set(assets.keys) else {
            throw EmbeddingFailure(status: 500, message: "Model directory differs from the pinned asset set.")
        }
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                try digest(file) == assets[file.lastPathComponent]
            else {
                throw EmbeddingFailure(status: 500, message: "Pinned model asset verification failed.")
            }
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
