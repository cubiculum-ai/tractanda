import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Local-only commands dispatch before connection/profile resolution or autostart.
func contentCommand(_ arguments: [String], hasConnectionOptions: Bool) throws -> Bool {
    guard let command = arguments.first, ["inspect-content", "activate-content"].contains(command) else {
        return false
    }
    guard !hasConnectionOptions, arguments.count >= 2, !arguments[1].hasPrefix("--") else {
        throw TractandaError(
            "usage",
            "Content commands require an explicit local STORE path and no connection/profile options.")
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    if command == "inspect-content" {
        var owner: UInt32?
        var destination: URL?
        var cursor = 2
        while cursor < arguments.count {
            guard cursor + 1 < arguments.count, !arguments[cursor + 1].hasPrefix("--") else {
                throw TractandaError("usage", usage)
            }
            switch arguments[cursor] {
            case "--owner":
                guard owner == nil else { throw TractandaError("usage", usage) }
                owner = try SystemAccountDirectory().user(named: arguments[cursor + 1]).uid
            case "--output":
                guard destination == nil else { throw TractandaError("usage", usage) }
                destination = URL(fileURLWithPath: arguments[cursor + 1])
            default: throw TractandaError("usage", usage)
            }
            cursor += 2
        }
        let report = try LocalContentRecovery.inspect(root: root, ownerUID: owner)
        if let destination {
            try LocalContentRecovery.write(report, to: destination)
            output(
                try JSONSerialization.data(
                    withJSONObject: [
                        "report": destination.path, "structurallyComplete": report.structurallyComplete,
                    ], options: [.sortedKeys]))
        } else {
            output(try JSON.encode(report))
        }
        if !report.structurallyComplete { exit(2) }
        return true
    }
    guard arguments.count == 5, !arguments[2].hasPrefix("--"), arguments[3] == "--index-directory",
        !arguments[4].hasPrefix("--")
    else {
        throw TractandaError("usage", "Use activate-content STORE TAGGED_CONFIG_JSON --index-directory PATH.")
    }
    let configuration = try LocalContentRecovery.configuration(at: URL(fileURLWithPath: arguments[2]))
    let activated = try LocalContentRecovery.activate(
        root: root,
        indexDirectory: URL(fileURLWithPath: arguments[4], isDirectory: true), configuration: configuration)
    output(try JSON.encode(activated))
    return true
}
