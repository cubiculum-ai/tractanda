import CTractandaPlatform
import Foundation

/// User-level launchd/systemd registration. The daemon binds its own socket to retain its peer UID.
public enum ManagedServer {
    /// Options for a managed instance of the native daemon.  Core deliberately records only
    /// native executable arguments; it does not depend on the server implementation.
    public struct SharedDaemonOptions: Equatable, Sendable {
        public let httpPort: Int?
        public let viewItemID: String?
        public let projectRootID: String?
        public let statusRootID: String?
        public let initialProjectID: String?

        public init(
            httpPort: Int? = 48_728, viewItemID: String? = nil, projectRootID: String? = nil,
            statusRootID: String? = nil, initialProjectID: String? = nil
        ) {
            self.httpPort = httpPort
            self.viewItemID = viewItemID
            self.projectRootID = projectRootID
            self.statusRootID = statusRootID
            self.initialProjectID = initialProjectID
        }

        func validate() throws {
            guard httpPort == nil || (0...65_535).contains(httpPort!) else {
                throw TractandaError("invalidService", "HTTP port is invalid.")
            }
            guard (projectRootID == nil) == (statusRootID == nil),
                initialProjectID == nil || projectRootID != nil,
                !(viewItemID != nil && projectRootID != nil)
            else {
                throw TractandaError("invalidService", "Board mode configuration is inconsistent.")
            }
            for value in [viewItemID, projectRootID, statusRootID, initialProjectID].compactMap({ $0 }) {
                try Identifier.validate(value)
            }
        }
    }

    public struct Registration: Codable, Equatable {
        public let name: String
        public let storePath: String
        public let binaryPath: String
        public let definitionPath: String
        public let logPath: String
        public let connection: ServerConnection
        /// Nil is the original, compatible `serve` launch form.
        public let nativeProgramArguments: [String]?

        public init(
            name: String, storePath: String, binaryPath: String, definitionPath: String,
            logPath: String, connection: ServerConnection, nativeProgramArguments: [String]? = nil
        ) {
            self.name = name
            self.storePath = storePath
            self.binaryPath = binaryPath
            self.definitionPath = definitionPath
            self.logPath = logPath
            self.connection = connection
            self.nativeProgramArguments = nativeProgramArguments
        }
    }

    static var stateDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["TRACTANDA_STATE_DIRECTORY"] {
            return URL(fileURLWithPath: path)
        }
        #if os(macOS)
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Tractanda/services")
        #else
            let base =
                ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
            return base.appendingPathComponent("tractanda/services")
        #endif
    }

    static var definitionDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["TRACTANDA_SERVICE_DIRECTORY"] {
            return URL(fileURLWithPath: path)
        }
        #if os(macOS)
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/LaunchAgents")
        #else
            let base =
                ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
            return base.appendingPathComponent("systemd/user")
        #endif
    }

    static func label(_ name: String) -> String { "ai.tractanda.server.\(name)" }
    static func unit(_ name: String) -> String { "tractanda-\(name).service" }
    static func recordURL(_ name: String) -> URL {
        stateDirectory.appendingPathComponent(name).appendingPathComponent("registration.json")
    }

    public static func registration(name: String) throws -> Registration {
        try ConnectionPreferences.validateName(name)
        let url = recordURL(name)
        try PrivateConfiguration.validate(url, directory: false)
        let record = try JSON.decode(Registration.self, Data(contentsOf: url))
        let installedBinary = stateDirectory.appendingPathComponent(name).appendingPathComponent("tractanda")
            .standardizedFileURL.path
        guard record.name == name, record.connection.managedService == name,
            record.binaryPath == installedBinary
        else {
            throw TractandaError("invalidService", "Service registration does not match its name.")
        }
        try record.connection.validate()
        _ = try nativeProgramArguments(for: record)
        return record
    }

    /// Prepare reviewable, private artifacts before registering anything with the OS.
    public static func prepare(
        name: String, store: URL, executable: URL, socketPath: String? = nil,
        sharedDaemon: SharedDaemonOptions? = nil
    )
        throws -> Registration
    {
        try ConnectionPreferences.validateName(name)
        try sharedDaemon?.validate()
        let directory = stateDirectory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: recordURL(name).path) else {
            throw TractandaError(
                "serviceExists", "Service already exists; inspect or uninstall it before replacing it.")
        }
        let store = store.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: store.appendingPathComponent("items").path),
            !store.path.hasPrefix(directory.standardizedFileURL.path + "/")
        else {
            throw TractandaError(
                "invalidStore", "Choose an initialized store outside the service installation directory.")
        }
        let account = try SystemAccountDirectory().user(forUID: tractanda_uid())
        let connection = ServerConnection(
            socketPath: socketPath ?? ConnectionPreferences.localSocketPath(name: name),
            serverUser: account.name, managedService: name)
        try connection.validate()
        let parent = URL(fileURLWithPath: connection.socketPath).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try PrivateConfiguration.makeDirectory(parent)
        }
        try PrivateConfiguration.makeDirectory(directory)
        let binary = directory.appendingPathComponent("tractanda")
        let sourceExecutable = executable.standardizedFileURL.resolvingSymlinksInPath()
        try PrivateConfiguration.write(Data(contentsOf: sourceExecutable), to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        if sharedDaemon?.httpPort != nil {
            try copySharedWebResources(from: sourceExecutable.deletingLastPathComponent(), to: directory)
        }
        #if os(macOS)
            let filename = label(name) + ".plist"
        #else
            let filename = unit(name)
        #endif
        let definition = definitionDirectory.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: definition.path) else {
            throw TractandaError("serviceExists", "A service definition already exists: \(definition.path)")
        }
        let record = Registration(
            name: name, storePath: store.path, binaryPath: binary.path,
            definitionPath: definition.path, logPath: directory.appendingPathComponent("server.log").path,
            connection: connection,
            nativeProgramArguments: try sharedDaemon.map {
                try daemonProgramArguments(
                    binary: binary.path, store: store.path, socket: connection.socketPath, options: $0)
            })
        try FileManager.default.createDirectory(at: definitionDirectory, withIntermediateDirectories: true)
        let metadata = try FileMetadata.read(at: definitionDirectory)
        guard metadata.type == .directory, metadata.uid == tractanda_uid(), metadata.mode & 0o022 == 0
        else {
            throw TractandaError(
                "privateConfiguration", "Service definitions need an owned, non-writable-by-others directory."
            )
        }
        #if os(macOS)
            let bytes = try launchdDefinition(record)
        #else
            let bytes = Data(try systemdDefinition(record).utf8)
        #endif
        try bytes.write(to: definition, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: definition.path)
        try PrivateConfiguration.write(try JSON.encode(record), to: recordURL(name))
        return record
    }

    static func launchdDefinition(_ record: Registration) throws -> Data {
        let arguments = try nativeProgramArguments(for: record)
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": label(record.name),
                "ProgramArguments": arguments,
                "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 2,
                "ProcessType": "Background", "WorkingDirectory": "/", "Umask": 0o077,
                "StandardOutPath": record.logPath, "StandardErrorPath": record.logPath,
            ], format: .xml, options: 0)
    }

    static func systemdDefinition(_ record: Registration) throws -> String {
        func quote(_ value: String) throws -> String {
            guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
                throw TractandaError("invalidService", "Service paths cannot contain control characters.")
            }
            return "\""
                + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "$", with: "$$") + "\""
        }
        let arguments = try nativeProgramArguments(for: record).map(quote).joined(separator: " ")
        return """
            [Unit]
            Description=Tractanda item server (\(record.name))

            [Service]
            Type=exec
            ExecStart=\(arguments)
            Restart=always
            RestartSec=2
            TimeoutStopSec=20
            WorkingDirectory=/
            UMask=0077

            [Install]
            WantedBy=default.target

            """
    }

    /// Resolves the legacy record shape and rejects records that could cause a service manager
    /// to execute anything other than this exact installed `serve` or `daemon` invocation.
    static func nativeProgramArguments(for record: Registration) throws -> [String] {
        let arguments =
            record.nativeProgramArguments
            ?? [record.binaryPath, "serve", record.storePath, record.connection.socketPath, "--managed"]
        guard arguments.count <= 13, arguments.count >= 5, arguments[0] == record.binaryPath,
            arguments[2] == record.storePath, arguments[3] == record.connection.socketPath,
            arguments[4] == "--managed", ["serve", "daemon"].contains(arguments[1])
        else {
            throw TractandaError(
                "invalidService", "Service registration has invalid native program arguments.")
        }
        guard !arguments.contains(where: { $0.contains("\0") || $0.contains("\n") || $0.contains("\r") })
        else {
            throw TractandaError("invalidService", "Service arguments cannot contain control characters.")
        }
        if arguments[1] == "serve" {
            guard arguments.count == 5 else {
                throw TractandaError(
                    "invalidService", "The legacy server accepts no additional managed arguments.")
            }
            return arguments
        }

        var index = 5
        guard index < arguments.count else {
            throw TractandaError("invalidService", "Managed daemon registration is missing its HTTP mode.")
        }
        switch arguments[index] {
        case "--no-http": index += 1
        case "--http-port":
            guard index + 1 < arguments.count, let port = Int(arguments[index + 1]),
                (0...65_535).contains(port)
            else {
                throw TractandaError(
                    "invalidService", "Managed daemon registration has an invalid HTTP port.")
            }
            index += 2
        default:
            throw TractandaError("invalidService", "Managed daemon registration has an invalid HTTP mode.")
        }
        if index == arguments.count { return arguments }
        if arguments[index] == "--view" {
            guard index + 2 == arguments.count else {
                throw TractandaError(
                    "invalidService", "Managed daemon registration has invalid view arguments.")
            }
            try Identifier.validate(arguments[index + 1])
            return arguments
        }
        guard arguments[index] == "--project-root", index + 3 < arguments.count,
            arguments[index + 2] == "--status-root"
        else {
            throw TractandaError("invalidService", "Managed daemon registration has invalid board arguments.")
        }
        try Identifier.validate(arguments[index + 1])
        try Identifier.validate(arguments[index + 3])
        index += 4
        if index == arguments.count { return arguments }
        guard index + 2 == arguments.count, arguments[index] == "--project" else {
            throw TractandaError(
                "invalidService", "Managed daemon registration has invalid project arguments.")
        }
        try Identifier.validate(arguments[index + 1])
        return arguments
    }

    private static func daemonProgramArguments(
        binary: String, store: String, socket: String, options: SharedDaemonOptions
    ) throws -> [String] {
        try options.validate()
        var arguments = [binary, "daemon", store, socket, "--managed"]
        if let port = options.httpPort {
            arguments += ["--http-port", String(port)]
        } else {
            arguments.append("--no-http")
        }
        if let view = options.viewItemID {
            arguments += ["--view", view]
        } else if let projectRoot = options.projectRootID, let statusRoot = options.statusRootID {
            arguments += ["--project-root", projectRoot, "--status-root", statusRoot]
            if let project = options.initialProjectID { arguments += ["--project", project] }
        }
        return try nativeProgramArguments(
            for: Registration(
                name: "managed", storePath: store, binaryPath: binary, definitionPath: "/unused",
                logPath: "/unused", connection: ServerConnection(socketPath: socket),
                nativeProgramArguments: arguments))
    }

    /// SwiftPM places module resources beside the executable. Copy whole bundles, rather than
    /// individual files, because the bundle's internal layout is part of `Bundle.module` lookup.
    private static func copySharedWebResources(from sourceDirectory: URL, to destinationDirectory: URL) throws
    {
        let manager = FileManager.default
        for name in [
            "Tractanda_TractandaWeb.bundle", "Tractanda_TractandaWeb.resources",
            "swift-nio_NIOPosix.bundle", "swift-nio_NIOPosix.resources",
        ] {
            let source = sourceDirectory.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            guard try FileMetadata.read(at: source).type == .directory else {
                throw TractandaError("invalidService", "Required resource bundle is not a directory: \(name)")
            }
            let destination = destinationDirectory.appendingPathComponent(name)
            try manager.copyItem(at: source, to: destination)
            try makePrivateResourceTree(destination)
        }
    }

    private static func makePrivateResourceTree(_ url: URL) throws {
        let metadata = try FileMetadata.read(at: url)
        switch metadata.type {
        case .directory:
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            {
                try makePrivateResourceTree(child)
            }
        case .regular:
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        default:
            throw TractandaError(
                "invalidService", "Resource bundles may contain only regular files and directories.")
        }
    }

    public static func install(name: String, makeDefault: Bool = false) throws {
        let record = try registration(name: name)
        try PrivateConfiguration.validate(URL(fileURLWithPath: record.definitionPath), directory: false)
        #if os(Linux)
            _ = try command("/usr/bin/systemctl", ["--user", "daemon-reload"])
            _ = try command("/usr/bin/systemctl", ["--user", "enable", unit(name)])
        #endif
        try start(name: name)
        try ConnectionPreferences().update {
            $0.profiles[name] = record.connection
            if makeDefault || $0.defaultProfile == nil { $0.defaultProfile = name }
        }
    }

    public static func start(name: String) throws {
        let record = try registration(name: name)
        #if os(macOS)
            let domain = "gui/\(tractanda_uid())"
            if (try? command("/bin/launchctl", ["print", "\(domain)/\(label(name))"])) == nil {
                try PrivateConfiguration.validate(
                    URL(fileURLWithPath: record.definitionPath), directory: false)
                _ = try command("/bin/launchctl", ["bootstrap", domain, record.definitionPath])
            }
            _ = try command("/bin/launchctl", ["kickstart", "\(domain)/\(label(name))"])
        #else
            _ = record
            _ = try command("/usr/bin/systemctl", ["--user", "start", unit(name)])
        #endif
    }

    public static func stop(name: String) throws {
        _ = try registration(name: name)
        #if os(macOS)
            _ = try command("/bin/launchctl", ["bootout", "gui/\(tractanda_uid())/\(label(name))"])
        #else
            _ = try command("/usr/bin/systemctl", ["--user", "stop", unit(name)])
        #endif
    }

    public static func status(name: String) throws -> String {
        _ = try registration(name: name)
        #if os(macOS)
            return try command("/bin/launchctl", ["print", "gui/\(tractanda_uid())/\(label(name))"])
        #else
            return try command(
                "/usr/bin/systemctl",
                ["--user", "show", unit(name), "--property=ActiveState,SubState,MainPID"])
        #endif
    }

    /// Removes only the registration and profile. Canonical store, installed executable and logs are retained.
    public static func uninstall(name: String) throws {
        let record = try registration(name: name)
        #if os(macOS)
            if (try? status(name: name)) != nil { try stop(name: name) }
        #else
            _ = try command("/usr/bin/systemctl", ["--user", "disable", "--now", unit(name)])
        #endif
        let definition = URL(fileURLWithPath: record.definitionPath)
        try PrivateConfiguration.validate(definition, directory: false)
        try FileManager.default.removeItem(at: definition)
        #if os(Linux)
            _ = try command("/usr/bin/systemctl", ["--user", "daemon-reload"])
        #endif
        try ConnectionPreferences().update {
            if $0.profiles[name]?.managedService == name { $0.profiles.removeValue(forKey: name) }
            if $0.defaultProfile == name { $0.defaultProfile = nil }
        }
        try FileManager.default.removeItem(at: recordURL(name))
    }

    /// Runs a fixed OS service-manager executable without a shell, with a bounded wait.
    private static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            throw TractandaError("serviceManagerTimeout", "Service manager did not finish within 20 seconds.")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw TractandaError("serviceManagerError", String(output.prefix(2048)))
        }
        return output
    }
}
