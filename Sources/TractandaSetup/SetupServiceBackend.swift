import Foundation

/// The system manager is a platform detail; canonical admission and readiness stay in SetupEngine.
/// This is deliberately not the development user-service installer.
enum SetupServiceRole: String, Sendable {
    case server, embeddings, authentication
}

struct SetupSystemdState: Equatable {
    let loadState: String
    let activeState: String
    let fragmentPath: String
    let dropInPaths: String
    let needsReload: Bool
    let mainPID: Int32
    let unitFileState: String

    init(output: String) throws {
        let required: Set<String> = [
            "LoadState", "ActiveState", "FragmentPath", "DropInPaths",
            "NeedDaemonReload", "MainPID", "UnitFileState",
        ]
        guard output.utf8.count <= 16_384 else {
            throw SetupError("System service status exceeds its bound.")
        }
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else {
                throw SetupError("Malformed system service status.")
            }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard required.contains(key), fields.updateValue(value, forKey: key) == nil,
                !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw SetupError("Unexpected or duplicate system service status field.") }
        }
        guard Set(fields.keys) == required,
            let pid = Int32(fields["MainPID"]!), pid >= 0,
            ["yes", "no"].contains(fields["NeedDaemonReload"]!)
        else { throw SetupError("Incomplete system service status.") }
        loadState = fields["LoadState"]!
        activeState = fields["ActiveState"]!
        fragmentPath = fields["FragmentPath"]!
        dropInPaths = fields["DropInPaths"]!
        needsReload = fields["NeedDaemonReload"] == "yes"
        mainPID = pid
        unitFileState = fields["UnitFileState"]!
    }

    var running: Bool { activeState == "active" && mainPID > 1 }

    func requireOwned(fragment: URL) throws {
        guard loadState == "loaded", fragmentPath == fragment.path, dropInPaths.isEmpty,
            !needsReload,
            ["enabled", "disabled", "static", "indirect", "enabled-runtime"].contains(unitFileState),
            ["active", "inactive", "failed", "activating", "deactivating"].contains(activeState)
        else {
            throw SetupError(
                "System service definition, overrides or loaded state differ from the owned registration.")
        }
        guard activeState != "active" || mainPID > 1 else {
            throw SetupError("Active system service has no verifiable main process.")
        }
        guard !["inactive", "failed"].contains(activeState) || mainPID == 0 else {
            throw SetupError("Stopped system service still reports a main process.")
        }
    }
}

struct SetupServiceBackend {
    let roots: SetupRoots
    let runner: any SetupProcessRunning
    var allowFixtureRuntimeRoot = false

    func name(_ instance: String, role: SetupServiceRole = .server) -> String {
        if roots.platform == .macos {
            let component = role == .authentication ? "authentication" : role.rawValue
            return "ai.tractanda." + component + "." + instance
        }
        return "tractanda-" + role.rawValue + "-" + instance + ".service"
    }

    func definitionURL(_ instance: String, role: SetupServiceRole = .server) -> URL {
        let suffix = roots.platform == .macos ? ".plist" : ""
        return roots.launchDefinitions.appendingPathComponent(name(instance, role: role) + suffix)
    }

    func label(_ instance: String, role: SetupServiceRole = .server) -> String {
        roots.platform == .macos ? "system/" + name(instance, role: role) : name(instance, role: role)
    }

    private func run(_ arguments: [String]) throws -> ProcessResult {
        try runner.run(
            roots.platform == .macos ? "/bin/launchctl" : "/usr/bin/systemctl",
            arguments, environment: [:])
    }

    private func successful(_ arguments: [String]) throws {
        let result = try run(arguments)
        guard result.status == 0 else {
            throw SetupError("System service command failed: " + result.output.prefix(4096))
        }
    }

    func systemdState(_ instance: String, role: SetupServiceRole = .server) throws -> SetupSystemdState {
        guard roots.platform == .linux else { throw SetupError("Systemd status requires Linux.") }
        let result = try run([
            "show", name(instance, role: role), "--no-pager",
            "--property=LoadState,ActiveState,FragmentPath,DropInPaths,NeedDaemonReload,MainPID,UnitFileState",
        ])
        // systemctl show may return nonzero for not-found. Parse the explicit state rather than
        // treating arbitrary manager errors as evidence that the unit is stopped.
        let state = try SetupSystemdState(output: result.output)
        guard
            result.status == 0
                || state.loadState == "not-found" && state.activeState == "inactive"
                    && state.mainPID == 0 && state.fragmentPath.isEmpty && state.dropInPaths.isEmpty
        else {
            throw SetupError("Cannot establish system service state.")
        }
        return state
    }

    func isRunning(_ instance: String, role: SetupServiceRole = .server) throws -> Bool {
        if roots.platform == .macos {
            return try run(["print", label(instance, role: role)]).status == 0
        }
        let state = try systemdState(instance, role: role)
        if state.loadState == "not-found" {
            guard state.activeState == "inactive", state.mainPID == 0, state.fragmentPath.isEmpty,
                state.dropInPaths.isEmpty
            else { throw SetupError("Missing system service has conflicting state.") }
            return false
        }
        try state.requireOwned(fragment: definitionURL(instance, role: role))
        // Transitional states cannot establish a quiescent writer or a ready daemon.
        guard state.activeState != "activating", state.activeState != "deactivating" else {
            throw SetupError("System service is still changing state.")
        }
        return state.running
    }

    func status(_ instance: String, role: SetupServiceRole = .server) throws -> String {
        if roots.platform == .macos { return try run(["print", label(instance, role: role)]).output }
        let state = try systemdState(instance, role: role)
        try state.requireOwned(fragment: definitionURL(instance, role: role))
        return
            "LoadState=\(state.loadState)\nActiveState=\(state.activeState)\nMainPID=\(state.mainPID)\nUnitFileState=\(state.unitFileState)\n"
    }

    func mainPID(_ instance: String, role: SetupServiceRole) throws -> Int32? {
        if roots.platform == .linux {
            let state = try systemdState(instance, role: role)
            try state.requireOwned(fragment: definitionURL(instance, role: role))
            return state.running ? state.mainPID : nil
        }
        let result = try run(["print", label(instance, role: role)])
        guard result.status == 0,
            let line = result.output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix("pid = ") }),
            let pid = Int32(line.dropFirst(6)), pid > 1
        else { return nil }
        return pid
    }

    func reload() throws {
        if roots.platform == .linux { try successful(["daemon-reload"]) }
    }

    func load(_ instance: String, role: SetupServiceRole = .server, enableAtBoot: Bool = true) throws {
        if roots.platform == .macos {
            if try !isRunning(instance, role: role) {
                try successful(["bootstrap", "system", definitionURL(instance, role: role).path])
            }
            return
        }
        try reload()
        let before = try systemdState(instance, role: role)
        try before.requireOwned(fragment: definitionURL(instance, role: role))
        do {
            if enableAtBoot { try successful(["enable", name(instance, role: role)]) }
            try successful(["start", name(instance, role: role)])
            let after = try systemdState(instance, role: role)
            try after.requireOwned(fragment: definitionURL(instance, role: role))
            guard after.running, after.unitFileState == (enableAtBoot ? "enabled" : "disabled") else {
                throw SetupError("System service did not enter its owned enabled/running state.")
            }
        } catch {
            // This never claims old-program rollback. Do not conceal failure to remove boot startup.
            let startupError = error
            do { try disable(instance, role: role) } catch {
                throw SetupError(
                    "System service startup failed and boot disablement could not be verified; administrator recovery is required. "
                        + startupError.localizedDescription + " " + error.localizedDescription)
            }
            throw startupError
        }
    }

    func unload(_ instance: String, role: SetupServiceRole = .server) throws {
        if roots.platform == .macos {
            if try isRunning(instance, role: role) {
                try successful(["bootout", label(instance, role: role)])
            }
            return
        }
        let before = try systemdState(instance, role: role)
        if before.loadState == "not-found" {
            guard try !isRunning(instance, role: role) else {
                throw SetupError("Unowned system service is running.")
            }
            return
        }
        try before.requireOwned(fragment: definitionURL(instance, role: role))
        try successful(["stop", name(instance, role: role)])
        let after = try systemdState(instance, role: role)
        try after.requireOwned(fragment: definitionURL(instance, role: role))
        guard after.mainPID == 0, ["inactive", "failed"].contains(after.activeState) else {
            throw SetupError("System service did not stop; writer quiescence is unproved.")
        }
    }

    func enable(_ instance: String, role: SetupServiceRole = .server) throws {
        guard roots.platform == .linux else { return }
        let before = try systemdState(instance, role: role)
        try before.requireOwned(fragment: definitionURL(instance, role: role))
        try successful(["enable", name(instance, role: role)])
        let after = try systemdState(instance, role: role)
        try after.requireOwned(fragment: definitionURL(instance, role: role))
        guard after.unitFileState == "enabled" else { throw SetupError("Owned boot enablement was not established.") }
    }

    /// Used for failed/pending configuration: stopped must persist over a subsequent boot.
    /// Disk definition/receipt ownership is checked by SetupEngine before this operation.
    func disable(_ instance: String, role: SetupServiceRole = .server) throws {
        guard roots.platform == .linux else { return }
        let before = try systemdState(instance, role: role)
        try before.requireOwned(fragment: definitionURL(instance, role: role))
        try successful(["disable", "--now", name(instance, role: role)])
        let after = try systemdState(instance, role: role)
        try after.requireOwned(fragment: definitionURL(instance, role: role))
        guard after.unitFileState == "disabled", after.mainPID == 0,
            ["inactive", "failed"].contains(after.activeState)
        else {
            throw SetupError("System service boot startup could not be disabled.")
        }
    }

    /// Encode a literal systemd item. ExecStart expands both specifiers and dollars; Environment
    /// expands specifiers only. No shell is involved, and control characters are rejected.
    static func quoted(_ value: String, executableArgument: Bool = false) throws -> String {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SetupError("System service arguments must not contain control characters.")
        }
        var result = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "%", with: "%%")
        if executableArgument { result = result.replacingOccurrences(of: "$", with: "$$") }
        return "\"" + result + "\""
    }

    func authenticationDefinition(instance: String) throws -> Data {
        let arguments = [
            roots.software.appendingPathComponent("current/bin/tractanda-auth-helper").path,
            "--socket", "/run/tractanda-auth-" + instance + "/auth.sock",
            "--allowed-user", roots.platform.serviceUser,
        ]
        return try systemdDefinition(instance: instance, role: .authentication, arguments: arguments)
    }

    func systemdDefinition(
        instance: String, role: SetupServiceRole, arguments: [String],
        environment: [String: String] = [:]
    ) throws -> Data {
        guard roots.platform == .linux, !instance.isEmpty,
            instance.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || "-_".utf8.contains($0)
            }),
            let executable = arguments.first, executable.hasPrefix("/"), !executable.contains("%"),
            arguments.count <= 128
        else { throw SetupError("Invalid system service definition.") }
        let runtime = roots.runtime.appendingPathComponent(instance)
        let service = role == .authentication ? "root" : roots.platform.serviceUser
        var lines = [
            "[Unit]", "Description=Tractanda " + role.rawValue + " (" + instance + ")",
            "After=network.target", "", "[Service]", "Type=exec", "User=" + service, "UMask=0077",
            "ExecStart="
                + (try arguments.map { try Self.quoted($0, executableArgument: true) }.joined(separator: " ")),
            "Restart=on-failure", "RestartSec=5s", "TimeoutStopSec=45s", "KillMode=control-group",
            "ExecStartPre=+" + (try Self.quoted(roots.software.appendingPathComponent("current/bin/tractanda-setup").path, executableArgument: true))
                + " --package-runtime-guard " + instance,
        ]
        if role == .server {
            // RuntimeDirectory is relative to /run. Explicit roots let fixtures avoid host paths;
            // systemd boot recreation is supported only for the approved application-scoped root.
            guard roots.runtime.path == "/run/tractanda" || allowFixtureRuntimeRoot else {
                throw SetupError("Linux system units require the approved /run/tractanda runtime root.")
            }
            lines += [
                "RuntimeDirectory=tractanda/" + instance, "RuntimeDirectoryMode=0711",
                "RuntimeDirectoryPreserve=no",
            ]
            guard runtime.path == "/run/tractanda/" + instance || allowFixtureRuntimeRoot else {
                throw SetupError("Invalid runtime directory.")
            }
        }
        if role == .authentication {
            lines += [
                "RuntimeDirectory=tractanda-auth-" + instance, "RuntimeDirectoryMode=0755",
                "LimitCORE=0",
            ]
        }
        for key in environment.keys.sorted() {
            guard !key.isEmpty,
                key.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }),
                key.first?.isNumber != true
            else { throw SetupError("Invalid system service environment name.") }
            lines.append("Environment=" + (try Self.quoted(key + "=" + environment[key]!)))
        }
        lines += [
            "StandardOutput=journal", "StandardError=journal", "", "[Install]", "WantedBy=multi-user.target",
            "",
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }
}
