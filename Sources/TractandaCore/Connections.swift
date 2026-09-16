import CTractandaPlatform
import Foundation

/// Ephemeral selection details; profile aliases are client configuration, not database identities.
public struct ResolvedConnection: Sendable {
    public enum Source: String, Sendable {
        case user, system, explicitSocket, automaticSocket
    }
    public var connection: ServerConnection
    public let profileName: String?
    public let source: Source
}

/// A local connection description. Names and paths are machine configuration, not canonical item data.
public struct ServerConnection: Codable, Equatable, Sendable {
    public var socketPath: String
    public var serverUser: String?
    public var managedService: String?

    public init(socketPath: String, serverUser: String? = nil, managedService: String? = nil) {
        self.socketPath = socketPath
        self.serverUser = serverUser
        self.managedService = managedService
    }

    public func validate() throws {
        guard socketPath.hasPrefix("/"), socketPath.utf8.count <= 103,
            !socketPath.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else {
            throw TractandaError(
                "invalidConnection", "Use an absolute socket path of at most 103 UTF-8 bytes.")
        }
        if let serverUser,
            serverUser.isEmpty || serverUser.utf8.count > 255
                || serverUser.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        {
            throw TractandaError("invalidConnection", "The service account name is invalid.")
        }
        if let managedService { try ConnectionPreferences.validateName(managedService) }
    }

    /// Start only after connect failed before any request bytes were sent. Never replay an uncertain write.
    public func send(_ request: Data) throws -> Data {
        do {
            return try LocalTransport.call(socket: socketPath, request: request, serverUser: serverUser)
        } catch let error as TractandaError where error.code == "connectionFailed" {
            guard let managedService else {
                throw TractandaError(
                    "connectionFailed",
                    "Cannot connect to \(socketPath). Start its server or configure a connection with tractanda connections add."
                )
            }
            let expected =
                try serverUser.map { try SystemAccountDirectory().user(named: $0).uid }
                ?? tractanda_uid()
            guard expected == tractanda_uid() else {
                throw TractandaError(
                    "connectionFailed", "The service must be started by its owning OS account.")
            }
            try ManagedServer.start(name: managedService)
            let deadline = Date().addingTimeInterval(10)
            repeat {
                do {
                    return try LocalTransport.call(
                        socket: socketPath, request: request, serverUser: serverUser)
                } catch let retryError as TractandaError where retryError.code == "connectionFailed" {
                    if Date() >= deadline { throw retryError }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            } while true
        }
    }
}

/// Shared by the TUI, JSON CLI and MCP adapter. Explicit endpoints bypass unrelated configuration errors.
public struct ConnectionPreferences {
    public struct Document: Codable, Equatable {
        public var version = 1
        public var defaultProfile: String?
        public var profiles: [String: ServerConnection] = [:]
        public init() {}
    }

    public let url: URL
    /// `globalURL` is injectable for installers and tests. It is read-only fallback configuration;
    /// user configuration is never merged into it or written back to it.
    public let globalURL: URL?
    public init(url: URL? = nil, globalURL: URL? = nil) {
        self.url = url ?? Self.configurationURL()
        // Explicit configuration locations are isolated unless a global source is also supplied.
        self.globalURL =
            globalURL
            ?? (url == nil && ProcessInfo.processInfo.environment["TRACTANDA_CONFIG"] == nil
                ? Self.globalConfigurationURL() : nil)
    }

    public static func configurationURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["TRACTANDA_CONFIG"] {
            return URL(fileURLWithPath: path)
        }
        #if os(macOS)
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Tractanda/connections.json")
        #else
            let base =
                ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
            return base.appendingPathComponent("tractanda/connections.json")
        #endif
    }

    public static func globalConfigurationURL() -> URL {
        #if os(macOS)
            return URL(
                fileURLWithPath: "/Users/Shared/Library/Application Support/Tractanda/connections.json")
        #else
            return URL(fileURLWithPath: "/etc/tractanda/connections.json")
        #endif
    }

    public static func localSocketPath(name: String = "default") -> String {
        #if os(macOS)
            let base = FileManager.default.temporaryDirectory
        #else
            let base =
                ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: "/tmp", isDirectory: true)
        #endif
        return base.appendingPathComponent("tractanda-\(tractanda_uid())")
            .appendingPathComponent("\(name).sock").path
    }

    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 48,
            name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
            name.first != "-", name.last != "-"
        else {
            throw TractandaError(
                "invalidProfile", "Profile names use 1–48 lowercase letters, digits and internal hyphens.")
        }
    }

    public func load() throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return Document() }
        try PrivateConfiguration.validate(url, directory: false)
        guard try FileMetadata.read(at: url).size <= 65_536 else {
            throw TractandaError("invalidConnection", "Connection configuration exceeds 64 KiB.")
        }
        let document = try JSON.decode(Document.self, Data(contentsOf: url))
        try validate(document)
        return document
    }

    /// Read an installer-owned profile registry. It must be exactly root-owned 0644: a looser
    /// file would let another local user redirect clients to an attacker-controlled socket.
    public func loadGlobal() throws -> Document {
        guard let globalURL, FileManager.default.fileExists(atPath: globalURL.path) else {
            return Document()
        }
        let metadata = try FileMetadata.read(at: globalURL)
        guard metadata.type == .regular, metadata.uid == 0, metadata.mode & 0o777 == 0o644 else {
            throw TractandaError(
                "globalConnectionConfiguration",
                "Global connection configuration must be a root-owned 0644 regular file: \(globalURL.path)")
        }
        guard metadata.size <= 65_536 else {
            throw TractandaError("invalidConnection", "Global connection configuration exceeds 64 KiB.")
        }
        let document = try JSON.decode(Document.self, Data(contentsOf: globalURL))
        try validate(document)
        if let name = document.defaultProfile, document.profiles[name] == nil {
            throw TractandaError("unknownProfile", "System default profile does not exist: \(name)")
        }
        // A system daemon has no user-managed LaunchAgent. Keeping this invariant here also
        // protects manually provisioned system profiles.
        guard document.profiles.values.allSatisfy({ $0.managedService == nil }) else {
            throw TractandaError(
                "globalConnectionConfiguration",
                "Global profiles cannot set managedService.")
        }
        return document
    }

    private func validate(_ document: Document) throws {
        guard document.version == 1, document.profiles.count <= 64 else {
            throw TractandaError(
                "invalidConnection", "Unsupported connection configuration version or profile count.")
        }
        for (name, connection) in document.profiles {
            try Self.validateName(name)
            try connection.validate()
        }
        if let name = document.defaultProfile { try Self.validateName(name) }
    }

    public func update(_ edit: (inout Document) throws -> Void) throws {
        try PrivateConfiguration.withLock(url) {
            var document = try load()
            try edit(&document)
            try validate(document)
            if let name = document.defaultProfile, document.profiles[name] == nil,
                try loadGlobal().profiles[name] == nil
            {
                throw TractandaError("unknownProfile", "Default connection profile does not exist: \(name)")
            }
            try PrivateConfiguration.write(try JSON.encode(document), to: url)
        }
    }

    /// A combined read-only listing. Updating preferences still changes only the user's document.
    public func loadEffective() throws -> Document {
        let user = try load()
        var result = try loadGlobal()
        result.profiles.merge(user.profiles) { _, local in local }
        result.defaultProfile = user.defaultProfile ?? result.defaultProfile
        return result
    }

    /// Resolve each name independently. A local override does not hide unrelated system profiles,
    /// and a usable local selection does not depend on the health of the global registry.
    static func selectProfile(user: Document, name: String?, global: () throws -> Document) throws
        -> ServerConnection?
    {
        try selectProfileDetails(user: user, name: name, global: global)?.connection
    }

    static func selectProfileDetails(user: Document, name: String?, global: () throws -> Document) throws
        -> ResolvedConnection?
    {
        let requested = name ?? user.defaultProfile
        if let requested, let local = user.profiles[requested] {
            return ResolvedConnection(connection: local, profileName: requested, source: .user)
        }
        let shared = try global()
        guard let selectedName = requested ?? shared.defaultProfile else { return nil }
        guard let selected = shared.profiles[selectedName] else {
            throw TractandaError("unknownProfile", "Unknown connection profile: \(selectedName)")
        }
        return ResolvedConnection(connection: selected, profileName: selectedName, source: .system)
    }

    public func resolve(socketPath: String? = nil, profile: String? = nil, startsService: Bool = true)
        throws -> ServerConnection
    {
        try resolveDetails(socketPath: socketPath, profile: profile, startsService: startsService).connection
    }

    public func resolveDetails(socketPath: String? = nil, profile: String? = nil, startsService: Bool = true)
        throws -> ResolvedConnection
    {
        guard socketPath == nil || profile == nil else {
            throw TractandaError("usage", "Choose either an explicit socket or a connection profile.")
        }
        var resolution: ResolvedConnection
        if let socketPath {
            resolution = ResolvedConnection(
                connection: ServerConnection(
                    socketPath: URL(fileURLWithPath: socketPath).standardizedFileURL.path),
                profileName: nil, source: .explicitSocket)
        } else {
            resolution =
                try Self.selectProfileDetails(user: load(), name: profile, global: loadGlobal)
                ?? ResolvedConnection(
                    connection: ServerConnection(socketPath: Self.localSocketPath()),
                    profileName: nil, source: .automaticSocket)
        }
        if let account = ProcessInfo.processInfo.environment["TRACTANDA_SERVER_USER"] {
            resolution.connection.serverUser = account
        }
        if !startsService { resolution.connection.managedService = nil }
        try resolution.connection.validate()
        return resolution
    }
}

/// Common client options; callers keep their own operation arguments out of this parser.
public struct ConnectionOptions {
    public var socketPath: String?
    public var profile: String?
    public var startsService = true
    public init() {}

    public mutating func consume(_ arguments: inout [String]) throws {
        while let flag = arguments.first, ["--socket", "--profile", "--no-start", "--default"].contains(flag)
        {
            arguments.removeFirst()
            switch flag {
            case "--no-start": startsService = false
            case "--default": break
            default:
                guard let value = arguments.first, !value.isEmpty else {
                    throw TractandaError("usage", "Missing value for \(flag).")
                }
                arguments.removeFirst()
                if flag == "--socket" { socketPath = value } else { profile = value }
            }
        }
    }

    public func resolve() throws -> ServerConnection {
        try ConnectionPreferences().resolve(
            socketPath: socketPath, profile: profile, startsService: startsService)
    }

    public func resolveDetails() throws -> ResolvedConnection {
        try ConnectionPreferences().resolveDetails(
            socketPath: socketPath, profile: profile, startsService: startsService)
    }
}

enum PrivateConfiguration {
    static func validate(_ url: URL, directory: Bool) throws {
        let metadata = try FileMetadata.read(at: url)
        guard metadata.type == (directory ? .directory : .regular), metadata.uid == tractanda_uid(),
            metadata.mode & 0o077 == 0
        else {
            throw TractandaError(
                "privateConfiguration", "Use a private, owned configuration path: \(url.path)")
        }
    }

    static func makeDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try validate(url, directory: true)
    }

    static func write(_ data: Data, to url: URL) throws {
        try makeDirectory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) { try validate(url, directory: false) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func withLock<T>(_ url: URL, _ operation: () throws -> T) throws -> T {
        try makeDirectory(url.deletingLastPathComponent())
        let path = url.appendingPathExtension("lock")
        let descriptor = tractanda_lock(path.path)
        guard descriptor >= 0 else {
            throw TractandaError("configurationBusy", "Connection configuration is in use.")
        }
        defer { _ = tractanda_unlock(descriptor) }
        try validate(path, directory: false)
        return try operation()
    }
}
