import Foundation
import MLX

@main enum Main {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var modelDirectory: URL?
        var port = 48730
        var offset = 0
        while offset < arguments.count {
            guard offset + 1 < arguments.count else { throw usageError() }
            switch arguments[offset] {
            case "--model":
                guard modelDirectory == nil else { throw usageError() }
                modelDirectory = URL(fileURLWithPath: arguments[offset + 1], isDirectory: true)
            case "--port":
                guard let value = Int(arguments[offset + 1]), (1024...65535).contains(value) else {
                    throw usageError()
                }
                port = value
            default:
                throw usageError()
            }
            offset += 2
        }
        guard let modelDirectory else { throw usageError() }
        try ModelProfile.validate(directory: modelDirectory)

        #if os(Linux)
            // The pinned vmlx runtime has no GPU backend on Linux but retains its
            // cross-platform GPU default. Keep the CPU selection scoped to this
            // host's lifetime; macOS continues to use its existing Metal default.
            try await Device.withDefaultDevice(.cpu) {
                try await run(modelDirectory: modelDirectory, port: port)
            }
        #else
            try await run(modelDirectory: modelDirectory, port: port)
        #endif
    }

    private static func run(modelDirectory: URL, port: Int) async throws {
        // Configure before loading any model or starting concurrent requests.
        // These constrain MLX allocations/cache, not the process's entire RSS.
        Memory.memoryLimit = 8 * 1024 * 1024 * 1024
        Memory.cacheLimit = 128 * 1024 * 1024
        let embedder = try await QwenEmbedder(directory: modelDirectory)
        _ = try await embedder.embed(["Tractanda embedding runtime readiness."])
        try await serveEmbeddings(engine: embedder, port: port)
    }

    private static func usageError() -> EmbeddingFailure {
        EmbeddingFailure(status: 400, message: "Use --model PATH [--port 48730].")
    }
}
