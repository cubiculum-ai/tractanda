import Foundation
import MLX

@main enum Main {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--describe"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(ModelProfile.descriptor), as: UTF8.self))
            return
        }
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
            try await runOnLinux(modelDirectory: modelDirectory, port: port)
        #else
            try await run(modelDirectory: modelDirectory, port: port)
        #endif
    }

    nonisolated private static func run(modelDirectory: URL, port: Int) async throws {
        // Configure before loading any model or starting concurrent requests.
        // These constrain MLX allocations/cache, not the process's entire RSS.
        Memory.memoryLimit = 8 * 1024 * 1024 * 1024
        Memory.cacheLimit = 128 * 1024 * 1024
        let embedder = try await GraniteEmbedder(directory: modelDirectory)
        _ = try await embedder.embed(["Tractanda embedding runtime readiness."])
        try await serveEmbeddings(engine: embedder, port: port)
    }

    #if os(Linux)
        nonisolated private static func runOnLinux(modelDirectory: URL, port: Int) async throws {
            // Select the portable CPU device for this Linux host. Keep that
            // process-local choice separate from macOS's Metal default.
            try await Device.withDefaultDevice(.cpu) {
                try await run(modelDirectory: modelDirectory, port: port)
            }
        }
    #endif

    private static func usageError() -> EmbeddingFailure {
        EmbeddingFailure(status: 400, message: "Use --model PATH [--port 48730].")
    }
}
