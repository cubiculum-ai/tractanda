import Foundation
import TractandaCore

/// Diagnostics never start a stopped managed daemon. Unload is enforced by server authorization.
@discardableResult
func documentRuntimeCommand(
    arguments: [String], options: ConnectionOptions,
    output: (Data) -> Void = { print(String(decoding: $0, as: UTF8.self)) },
    sendForTesting: CLIRequestSender? = nil
) throws -> Bool {
    guard arguments.first == "document-runtime" else { return false }
    guard arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--json"),
        ["status", "unload"].contains(arguments[1])
    else {
        throw TractandaError(
            "usage", "Use tractanda [--profile NAME | --socket PATH] document-runtime status|unload [--json]."
        )
    }
    var selected = options
    selected.startsService = false
    let method = "TractandaDocumentRuntime/" + arguments[1]
    let bytes = try call(selected.resolve(), method, [:], sendForTesting: sendForTesting)
    let status = try JSON.decode(DocumentWorkerPoolStatus.self, bytes)
    if arguments.count == 3 {
        output(try JSON.encode(status))
    } else {
        let lines = [
            "Document worker process: \(status.workerRunning ? "running" : "not running")",
            "Document active: \(status.documentActive ? "yes" : "no")",
            "Unload pending: \(status.unloadPending ? "yes" : "no")",
            "A running process does not establish that model weights are loaded.",
        ]
        output(Data(lines.joined(separator: "\n").utf8))
    }
    return true
}
