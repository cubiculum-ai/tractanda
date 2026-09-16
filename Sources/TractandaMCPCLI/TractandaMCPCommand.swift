import Foundation
import TractandaCore
import TractandaMCP

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@main
struct TractandaMCPCommand {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print(
                """
                Usage: tractanda-mcp [SOCKET | --profile NAME | --socket PATH] [--no-start] [--result-format both|text|structured]
                MCP 2025-11-25 over stdio. Run under the intended human or agent OS account.
                For a different service owner, set TRACTANDA_SERVER_USER to that account's name.
                Standard output is reserved for MCP messages during service; no login token is used.
                Result format defaults to both (JSON text content plus structuredContent) for compatibility.
                text emits one compact JSON text content item and tools/list omits outputSchema.
                structured emits structuredContent with empty content; it requires a structured-capable client.
                """)
            return
        }
        signal(SIGPIPE, SIG_IGN)
        do {
            var connection = ConnectionOptions()
            var resultFormat: MCPResultFormat = .both
            while !arguments.isEmpty {
                let option = arguments.removeFirst()
                switch option {
                case "--result-format":
                    guard let raw = arguments.first, let format = MCPResultFormat(rawValue: raw) else {
                        throw TractandaError("usage", "--result-format requires both, text, or structured.")
                    }
                    resultFormat = format
                    arguments.removeFirst()
                case "--no-start":
                    connection.startsService = false
                case "--default":
                    break
                case "--socket", "--profile":
                    guard let value = arguments.first, !value.isEmpty, !value.hasPrefix("-") else {
                        throw TractandaError("usage", "Missing value for \(option).")
                    }
                    arguments.removeFirst()
                    if option == "--socket" {
                        guard connection.socketPath == nil else {
                            throw TractandaError("usage", "Use one socket or --profile NAME.")
                        }
                        connection.socketPath = value
                    } else {
                        guard connection.profile == nil else {
                            throw TractandaError("usage", "Use one profile.")
                        }
                        connection.profile = value
                    }
                default:
                    guard !option.hasPrefix("-"), connection.socketPath == nil else {
                        throw TractandaError("usage", "Use one socket or --profile NAME.")
                    }
                    connection.socketPath = option
                }
            }
            try await MCPAdapter.serve(resolution: connection.resolveDetails(), resultFormat: resultFormat)
        } catch {
            FileHandle.standardError.write(Data("tractanda-mcp: \(error)\n".utf8))
            exit(1)
        }
    }
}
