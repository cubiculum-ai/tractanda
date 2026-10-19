import Foundation

struct SetupPeerRuntimeArguments: Equatable, Sendable {
    let remainingArguments: [String]
    let action: SetupOptions.PeerRuntimeAction

    static func parse(_ arguments: [String]) throws -> Self {
        let command = arguments.first
        var remaining: [String] = []
        var action: SetupOptions.PeerRuntimeAction = .preserve
        var seen = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--peer-runtime-configuration":
                guard !seen else {
                    throw SetupError("Specify only one peer runtime configuration action.")
                }
                try requireSupportedCommand(command)
                guard index + 1 < arguments.count else {
                    throw SetupError("Missing value for --peer-runtime-configuration.")
                }
                let path = arguments[index + 1]
                guard !path.isEmpty, !path.hasPrefix("-") else {
                    throw SetupError("--peer-runtime-configuration requires a non-flag path.")
                }
                action = .replace(URL(fileURLWithPath: path))
                seen = true
                index += 2

            case "--disable-peer-runtime":
                guard !seen else {
                    throw SetupError("Specify only one peer runtime configuration action.")
                }
                try requireSupportedCommand(command)
                action = .disable
                seen = true
                index += 1

            default:
                remaining.append(argument)
                index += 1
            }
        }

        return Self(remainingArguments: remaining, action: action)
    }

    private static func requireSupportedCommand(_ command: String?) throws {
        guard let command, ["plan", "install", "upgrade"].contains(command) else {
            throw SetupError("Peer runtime options are supported only for plan, install, or upgrade.")
        }
    }
}
