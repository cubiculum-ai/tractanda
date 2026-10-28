import Foundation
import CTractandaPlatform
import TractandaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local operator command. Never dispatches paths/programs through the client API.
func modelCommand(_ arguments: [String]) throws {
    let help = "tractanda models prefetch|status|import|run --manifest PATH --storage PATH [--artifact ID] [--from DIRECTORY | --adopt DIRECTORY] [-- EXECUTABLE ARGUMENTS...]"
    guard arguments.count >= 2, arguments[0] == "models", ["prefetch", "status", "import", "run"].contains(arguments[1]) else {
        throw TractandaError("usage", help)
    }
    let action = arguments[1]
    var options: [String: String] = [:]; var execution: [String] = []; var index = 2
    while index < arguments.count {
        let flag = arguments[index]
        if flag == "--" { execution = Array(arguments.dropFirst(index + 1)); break }
        guard ["--manifest", "--storage", "--artifact", "--from", "--adopt"].contains(flag), options[flag] == nil,
            index + 1 < arguments.count else { throw TractandaError("usage", help) }
        options[flag] = arguments[index + 1]; index += 2
    }
    guard let manifest = options["--manifest"], let storage = options["--storage"],
        storage.hasPrefix("/"), storage != "/", (action == "run") == !execution.isEmpty,
        (action == "import") == (options["--from"] != nil), options["--from"] == nil || options["--adopt"] == nil else { throw TractandaError("usage", help) }
    let catalog = try ModelProvisioningCatalog.load(manifest)
    let selected = options["--artifact"].map { id in catalog.artifacts.filter { $0.identifier == id } } ?? catalog.artifacts
    guard !selected.isEmpty, action != "run" || selected.count == 1 else { throw TractandaError("usage", help) }
    let root = URL(fileURLWithPath: storage)
    let worker = ModelProvisioner(root: root)
    if action == "status" {
        let state: [[String: Any]] = try selected.map { artifact in
            if let status = ModelProvisioner.status(artifact, root: root) {
                return try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as! [String: Any]
            }
            return ["artifact": artifact.identifier, "revision": artifact.revision,
                "phase": ModelProvisioner.activated(artifact, root: root) ? "ready" : "unavailable"]
        }
        output(try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])); return
    }
    var adoption: [String: URL] = [:]
    if let from = options["--from"] ?? options["--adopt"] {
        guard from.hasPrefix("/") else { throw TractandaError("usage", help) }
        for artifact in selected { adoption[artifact.identifier] = URL(fileURLWithPath: from).appendingPathComponent(artifact.identifier) }
    }
    guard tractanda_start_signals() == 0 else { throw TractandaError("signal", "Cannot install model provisioning shutdown signals.") }
    let cancellation = Task.detached {
        while !Task.isCancelled {
            if tractanda_stopping() != 0 { worker.cancel(); return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    defer { cancellation.cancel(); tractanda_restore_signals() }
    try worker.provision(.init(artifacts: selected), adoptionDirectories: adoption, offline: action == "import", retry: action == "run")
    guard tractanda_stopping() == 0 else { throw CancellationError() }
    if action == "run" {
        guard let executable = execution.first, executable.hasPrefix("/"), executable != "/" else { throw TractandaError("usage", help) }
        let strings = execution.map { strdup($0) }; defer { strings.forEach { free($0) } }
        var pointers = strings + [nil]
        let result = pointers.withUnsafeMutableBufferPointer { execv(executable, $0.baseAddress!) }
        throw TractandaError("modelRuntime", "Cannot execute verified model runtime (\(result)).")
    }
    output(try JSONEncoder().encode(worker.status()))
}
