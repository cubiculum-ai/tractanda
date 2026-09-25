import CTractandaPlatform
import Crypto
import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// The macOS preview reuses daemon. It owns installation receipts and software, while
/// canonical data remains service-owned and survives uninstall. Linux packaging is deferred.
public final class SetupEngine {
    public let roots: SetupRoots
    let runner: any SetupProcessRunning
    let rootCheck: () -> Bool
    let trustedOwnership: Bool
    let readinessCheck: ((String, String, Int) throws -> Void)?
    let semanticCall: (String, String, String, [String: Any]) throws -> [String: Any]

    public init(
        roots: SetupRoots = SetupRoots(), runner: any SetupProcessRunning = FoundationProcessRunner(),
        rootCheck: @escaping () -> Bool = { getuid() == 0 }, trustedOwnership: Bool = true,
        readinessCheck: ((String, String, Int) throws -> Void)? = nil,
        semanticCall: ((String, String, String, [String: Any]) throws -> [String: Any])? = nil
    ) {
        self.roots = roots
        self.runner = runner
        self.rootCheck = rootCheck
        self.trustedOwnership = trustedOwnership
        self.readinessCheck = readinessCheck
        self.semanticCall =
            semanticCall ?? { socket, user, method, arguments in
                try SetupNativeClient(socket: socket, serverUser: user).call(method, arguments)
            }
    }

    public func plan(_ options: SetupOptions) throws -> SetupPlan {
        try options.validate()
        try ServerConnection(
            socketPath: roots.runtime.appendingPathComponent(options.name).appendingPathComponent(
                "server.sock"
            ).path
        ).validate()
        try validateRoots()
        let manifest = try verifyBundle(at: options.bundle)
        let release = releaseURL(
            options, manifest: manifest,
            digest: try sha256(options.bundle.appendingPathComponent("bundle-manifest.json")))
        return SetupPlan(
            instance: options.name, store: roots.data.appendingPathComponent(options.name).path,
            indexDirectory: roots.indexes.appendingPathComponent(options.name).path,
            socket: roots.runtime.appendingPathComponent(options.name).appendingPathComponent("server.sock")
                .path,
            definition: definitionURL(options.name).path,
            executable: release.appendingPathComponent("bin/tractanda").path,
            actions: roots.platform == .macos
                ? [
                    "Verify the release and protected parent directories",
                    "Use the existing daemon account; create no accounts",
                    "Initialize an empty store or optional owner-private sample data",
                    "Register boot-time system LaunchDaemons",
                    "Verify native/HTTP readiness before publishing client connection settings",
                ] : ["Linux installer is in development; no installation actions are supported yet"])
    }

    public func install(_ options: SetupOptions, upgrade: Bool = false) throws {
        try requireRootAndPlatform()
        try options.validate()
        try ServerConnection(
            socketPath: roots.runtime.appendingPathComponent(options.name).appendingPathComponent(
                "server.sock"
            ).path
        ).validate()
        let plannedReceipt = try readReceipt(options.name)
        let dataParent =
            plannedReceipt.map { URL(fileURLWithPath: $0.store).deletingLastPathComponent() } ?? roots.data
        let indexParent =
            plannedReceipt.map { URL(fileURLWithPath: $0.indexDirectory).deletingLastPathComponent() }
            ?? roots.indexes
        try validateRoots(data: dataParent, indexes: indexParent)
        let manifest = try verifyBundle(at: options.bundle)
        let digest = try sha256(options.bundle.appendingPathComponent("bundle-manifest.json"))
        // Inspect all ancestry before creating even the software/configuration directories.
        if trustedOwnership {
            for path in [
                roots.software, roots.configuration, roots.launchDefinitions, dataParent, indexParent,
                roots.runtime,
            ] {
                try requireTrustedAncestry(of: path)
            }
        }
        try ensureRootDirectory(roots.configuration)
        try withInstallerLock {
            let oldClientRelease = try currentClientRelease()
            let previous = try readReceipt(options.name)
            guard previous == plannedReceipt else {
                throw SetupError("Installation state changed; retry the command.")
            }
            if let previous, previous.state == .active, previous.manifestSHA256 != digest, !upgrade {
                throw SetupError("This instance already has another release. Use upgrade.")
            }
            let owner = try previous?.owner ?? resolvedOwner(options)
            if let requested = options.owner, requested != owner {
                throw SetupError("An upgrade cannot replace the initial owner.")
            }
            let account = try SystemAccountDirectory().user(named: roots.platform.serviceUser)
            guard account.uid != 0 else { throw SetupError("The server account must be unprivileged.") }
            let release = releaseURL(options, manifest: manifest, digest: digest)
            if let old = previous?.embedding, manifest.embedding != old,
                !(old == .legacyQwen && manifest.embedding == .granite)
            {
                throw SetupError(
                    "This installation needs its existing embedding payload; model changes require an explicit reconfiguration."
                )
            }
            if manifest.embedding != nil && (previous?.port ?? options.port) == 65535 {
                throw SetupError(
                    "Choose an HTTP port below 65535 so the local embedding service has a separate port.")
            }
            var receipt =
                try previous
                ?? InstallationReceipt(
                    options: options, roots: roots, owner: owner, release: release, manifestSHA256: digest)
            if previous == nil {
                for path in [
                    receipt.store, receipt.indexDirectory,
                    URL(fileURLWithPath: receipt.socket).deletingLastPathComponent().path,
                ] {
                    guard !exists(URL(fileURLWithPath: path)) else {
                        throw SetupError("Refusing to adopt an existing path: \(path)")
                    }
                }
                guard !exists(definitionURL(options.name)) else {
                    throw SetupError("A service definition already exists without an owned receipt.")
                }
                try ensureNoGlobalProfile(options.name)
            } else {
                try verifyRegistration(receipt)
                if trustedOwnership {
                    for path in [receipt.store, receipt.indexDirectory] {
                        try requireServiceDirectory(URL(fileURLWithPath: path), uid: account.uid)
                    }
                }
            }
            for path in [
                roots.software, roots.launchDefinitions, dataParent, indexParent, roots.runtime,
                roots.configuration.appendingPathComponent("logs"),
            ] { try ensureRootDirectory(path) }
            if previous == nil { try writeReceipt(receipt) }
            try installRelease(manifest, from: options.bundle, to: release, digest: digest)
            if var tracked = previous {
                tracked.releases[release.path] = digest
                try writeReceipt(tracked)
            }
            for path in [receipt.store, receipt.indexDirectory] {
                try ensureServiceDirectory(URL(fileURLWithPath: path), uid: account.uid, mode: 0o700)
            }
            try ensureServiceDirectory(
                URL(fileURLWithPath: receipt.socket).deletingLastPathComponent(), uid: account.uid,
                mode: 0o711)
            try ensureServiceLog(receipt.instance, uid: account.uid)
            if manifest.embedding != nil {
                try ensureServiceLog(receipt.instance + "-embeddings", uid: account.uid)
            }
            let embeddingUpgrade = previous?.embedding == .legacyQwen && manifest.embedding == .granite
            if embeddingUpgrade { try prepareBundledEmbeddingUpgrade(&receipt) }
            receipt.embedding = manifest.embedding
            receipt.release = release.path
            receipt.manifestSHA256 = digest
            receipt.releases[release.path] = digest
            receipt.state = .preparing
            if !receipt.initialized {
                try writeReceipt(receipt)
                let executable = release.appendingPathComponent("bin/tractanda-setup").path
                var command = ["-n", "-u", roots.platform.serviceUser, "--", "/usr/bin/env"]
                if let node = receipt.uuidNode { command.append("TRACTANDA_UUID_NODE=" + node) }
                command += [
                    executable, "--bootstrap-store", receipt.store, receipt.indexDirectory, receipt.owner,
                    receipt.instance,
                ]
                try successful("/usr/bin/sudo", command)
                receipt.initialized = true
                try writeReceipt(receipt)
            }
            let definition = definitionURL(receipt.instance)
            let oldDefinition = exists(definition) ? try Data(contentsOf: definition) : nil
            let embeddingDefinition = embeddingDefinitionURL(receipt.instance)
            let oldEmbeddingDefinition =
                exists(embeddingDefinition) ? try Data(contentsOf: embeddingDefinition) : nil
            if previous?.embedding == nil && receipt.embedding != nil && oldEmbeddingDefinition != nil {
                throw SetupError("An embedding service definition already exists without an owned receipt.")
            }
            let oldProfiles = try globalProfilesSnapshot()
            let oldSemanticConfiguration = receipt.embeddingPreviousConfiguration
            var profilesPublished = false
            var clientsPublished = false
            do {
                try replaceEmbeddingRegistration(&receipt)
                try replaceRegistration(&receipt)
                try waitUntilReady(receipt)
                if receipt.sample && !receipt.sampled {
                    receipt.board = try SetupNativeClient(
                        socket: receipt.socket, serverUser: roots.platform.serviceUser
                    )
                    .seed(owner: receipt.owner, instance: receipt.instance, release: release)
                    receipt.sampled = true
                    try writeReceipt(receipt)
                    try replaceRegistration(&receipt)
                    try waitUntilReady(receipt)
                }
                try configureEmbedding(&receipt)
                try writeGlobalProfile(receipt)
                profilesPublished = true
                try publishClientLink(receipt)
                clientsPublished = true
                try publishTUICommand()
                receipt.state = .active
                receipt.embeddingPreviousConfiguration = nil
                try writeReceipt(receipt)
            } catch {
                var semanticRollbackError: Error?
                if let oldSemanticConfiguration {
                    do {
                        // The native server owns semantic.json; restore through its compare-and-swap
                        // while it is still running. Restoring after unload would silently strand Qwen
                        // against the Granite profile.
                        if try semanticConfigurationSnapshot(receipt) != oldSemanticConfiguration {
                            try restoreSemanticConfiguration(oldSemanticConfiguration, after: receipt)
                        }
                    } catch {
                        semanticRollbackError = error
                    }
                }
                try? unload(receipt.instance)
                try? unloadEmbedding(receipt)
                if profilesPublished { try? restoreGlobalProfiles(oldProfiles) }
                if clientsPublished {
                    try? setClientRelease(oldClientRelease)
                    try? removeTUICommandIfUnused()
                }
                if let semanticRollbackError {
                    let serverDisabled = removeOwnedRegistration(
                        definition, expectedSHA256: receipt.definitionSHA256)
                    let embeddingDisabled = removeOwnedRegistration(
                        embeddingDefinition, expectedSHA256: receipt.embeddingDefinitionSHA256)
                    receipt.state = .preparing
                    receipt.embeddingConfigured = false
                    receipt.definitionSHA256 = nil
                    receipt.embeddingDefinitionSHA256 = nil
                    try writeReceipt(receipt)
                    let definitions =
                        serverDisabled && embeddingDisabled
                        ? "Installer-owned service definitions were removed."
                        : "One or more service definitions changed outside the installer and were not removed."
                    throw SetupError(
                        "Installation failed and semantic configuration rollback also failed; services were left stopped and this preparing receipt retains the recovery snapshot for an explicit retry. \(definitions) \(error.localizedDescription) \(semanticRollbackError.localizedDescription)"
                    )
                }
                if let oldDefinition {
                    try writeProtected(oldDefinition, to: definition, mode: 0o644)
                } else if exists(definition) {
                    try FileManager.default.removeItem(at: definition)
                }
                if let oldEmbeddingDefinition {
                    try writeProtected(oldEmbeddingDefinition, to: embeddingDefinition, mode: 0o644)
                } else if exists(embeddingDefinition) {
                    try FileManager.default.removeItem(at: embeddingDefinition)
                }
                if let previous, previous.state == .active {
                    var rollback = previous
                    rollback.releases[release.path] = digest
                    try writeReceipt(rollback)
                    try? loadEmbedding(previous)
                    try? load(previous.instance)
                } else {
                    receipt.state = .preparing
                    receipt.embeddingDefinitionSHA256 = oldEmbeddingDefinition.map {
                        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
                    }
                    receipt.definitionSHA256 = oldDefinition.map {
                        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
                    }
                    try writeReceipt(receipt)
                }
                throw SetupError(
                    "Installation did not become ready; registrations were rolled back and data retained. \(error.localizedDescription)"
                )
            }
        }
    }

    /// Do not delete a registration that an administrator changed while recovery was in flight.
    /// Returning false leaves the receipt preparing, so ordinary start/restart remains blocked.
    func removeOwnedRegistration(_ url: URL, expectedSHA256: String?) -> Bool {
        guard exists(url) else { return true }
        guard let expectedSHA256, (try? sha256(url)) == expectedSHA256 else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return !exists(url)
        } catch { return false }
    }

    public func start(_ options: SetupOptions) throws {
        try control(options) { receipt in
            try loadEmbedding(receipt)
            try waitForEmbedding(receipt)
            try load(receipt.instance)
            try waitUntilReady(receipt)
        }
    }
    public func stop(_ options: SetupOptions) throws {
        try control(options) { receipt in
            try unload(receipt.instance)
            try unloadEmbedding(receipt)
        }
    }
    public func restart(_ options: SetupOptions) throws {
        try control(options) { receipt in
            try unload(receipt.instance)
            try unloadEmbedding(receipt)
            try loadEmbedding(receipt)
            try waitForEmbedding(receipt)
            try load(receipt.instance)
            try waitUntilReady(receipt)
        }
    }
    public func status(_ options: SetupOptions) throws -> String {
        try options.validate()
        guard roots.platform == .macos else { throw SetupError("Linux installation is in development.") }
        return try runner.run("/bin/launchctl", ["print", label(options.name)], environment: [:]).output
    }

    public func uninstall(_ options: SetupOptions) throws {
        try requireRootAndPlatform()
        try options.validate()
        try withInstallerLock {
            guard var receipt = try readReceipt(options.name) else {
                throw SetupError("There is no owned installation receipt.")
            }
            try verifyRegistration(receipt)
            _ = try currentClientRelease()
            // Verify everything to be removed before unloading any running process.
            for (path, digest) in receipt.releases where exists(URL(fileURLWithPath: path)) {
                let url = URL(fileURLWithPath: path)
                guard
                    url.deletingLastPathComponent()
                        == roots.software.appendingPathComponent("releases"),
                    try sha256(url.appendingPathComponent("bundle-manifest.json")) == digest
                else {
                    throw SetupError("An installed release differs from its receipt; nothing was removed.")
                }
                _ = try verifyBundle(at: url)
            }
            try unload(receipt.instance)
            try unloadEmbedding(receipt)
            let definition = definitionURL(receipt.instance)
            if exists(definition) { try FileManager.default.removeItem(at: definition) }
            if receipt.embedding != nil && exists(embeddingDefinitionURL(receipt.instance)) {
                try FileManager.default.removeItem(at: embeddingDefinitionURL(receipt.instance))
            }
            try removeGlobalProfile(receipt)
            try removeClientLink(receipt)
            try removeTUICommandIfUnused()
            receipt.state = .removed
            receipt.definitionSHA256 = nil
            receipt.embeddingDefinitionSHA256 = nil
            try writeReceipt(receipt)
            let retained = try releasesUsedByOtherInstances(receipt.instance)
            for path in receipt.releases.keys
            where !retained.contains(path) && exists(URL(fileURLWithPath: path)) {
                try FileManager.default.removeItem(atPath: path)
            }
            // Retain the receipt with canonical data location/ownership for a later reinstall.
            // No account, home directory, canonical record or index is removed.
        }
    }

    func control(_ options: SetupOptions, action: (InstallationReceipt) throws -> Void) throws {
        try requireRootAndPlatform()
        try options.validate()
        try withInstallerLock {
            guard let receipt = try readReceipt(options.name), receipt.state == .active else {
                throw SetupError("This instance is not fully installed.")
            }
            try verifyRegistration(receipt)
            try action(receipt)
        }
    }

    func validateRoots(data: URL? = nil, indexes: URL? = nil) throws {
        let data = data ?? roots.data
        let indexes = indexes ?? roots.indexes
        let paths = [data, indexes, roots.software, roots.configuration, roots.runtime]
        guard paths.allSatisfy({ $0.path.hasPrefix("/") && $0.path != "/" && !$0.path.contains("\0") }) else {
            throw SetupError("Installer roots must be absolute non-root directories.")
        }
        func overlaps(_ first: URL, _ second: URL) -> Bool {
            let a = first.standardizedFileURL.path
            let b = second.standardizedFileURL.path
            return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
        }
        let reserved = [
            roots.software.appendingPathComponent("releases"), clientLink,
            roots.configuration.appendingPathComponent("receipts"),
            roots.configuration.appendingPathComponent("logs"),
            roots.configuration.appendingPathComponent("connections.json"),
            roots.configuration.appendingPathComponent("installer.lock"), roots.runtime,
        ]
        guard !overlaps(data, indexes),
            !reserved.contains(where: {
                overlaps(data, $0) || overlaps(indexes, $0)
            })
        else {
            throw SetupError(
                "Canonical data and indexes must be separate from each other and the installed software/runtime."
            )
        }
    }

    func requireRootAndPlatform() throws {
        guard rootCheck() else { throw SetupError("Run the installer through sudo.") }
        guard roots.platform == .macos else {
            throw SetupError("Linux installation is in development; the first installer targets macOS.")
        }
    }
    func resolvedOwner(_ options: SetupOptions) throws -> String {
        guard let owner = options.owner ?? ProcessInfo.processInfo.environment["SUDO_USER"] else {
            throw SetupError("Specify --owner or run through sudo.")
        }
        let identity = try SystemAccountDirectory().user(named: owner)
        guard identity.uid != 0 else {
            throw SetupError("Choose an existing human OS account as the initial owner.")
        }
        return identity.name
    }
    func releaseURL(_ options: SetupOptions, manifest: BundleManifest, digest: String) -> URL {
        roots.software.appendingPathComponent("releases")
            .appendingPathComponent(manifest.version + "-" + digest.prefix(12))
    }
    func definitionURL(_ name: String) -> URL {
        roots.launchDefinitions.appendingPathComponent("ai.tractanda.server.\(name).plist")
    }
    func label(_ name: String) -> String { "system/ai.tractanda.server." + name }
    func receiptURL(_ name: String) -> URL {
        roots.configuration.appendingPathComponent("receipts/" + name + ".json")
    }
    func successful(_ executable: String, _ arguments: [String]) throws {
        let result = try runner.run(executable, arguments, environment: [:])
        guard result.status == 0 else {
            throw SetupError("Command failed: \(executable): \(result.output.prefix(4096))")
        }
    }
    func load(_ name: String) throws {
        let current = try runner.run("/bin/launchctl", ["print", label(name)], environment: [:])
        if current.status != 0 {
            try successful("/bin/launchctl", ["bootstrap", "system", definitionURL(name).path])
        }
    }
    func unload(_ name: String) throws {
        let current = try runner.run("/bin/launchctl", ["print", label(name)], environment: [:])
        if current.status == 0 { try successful("/bin/launchctl", ["bootout", label(name)]) }
    }
    func replaceRegistration(_ receipt: inout InstallationReceipt) throws {
        let bytes = try serviceDefinition(receipt)
        try unload(receipt.instance)
        try writeProtected(bytes, to: definitionURL(receipt.instance), mode: 0o644)
        receipt.definitionSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try writeReceipt(receipt)
        try load(receipt.instance)
    }
    func serviceDefinition(_ receipt: InstallationReceipt) throws -> Data {
        var arguments = [
            URL(fileURLWithPath: receipt.release).appendingPathComponent("bin/tractanda").path,
            "daemon", receipt.store, receipt.socket, "--index-directory", receipt.indexDirectory,
            "--managed", "--http-port", String(receipt.port),
        ]
        if let project = receipt.board["projectID"], let projects = receipt.board["projectRootID"],
            let status = receipt.board["statusRootID"]
        {
            arguments += ["--project-root", projects, "--status-root", status, "--project", project]
        }
        var dictionary: [String: Any] = [
            "Label": "ai.tractanda.server." + receipt.instance, "ProgramArguments": arguments,
            "UserName": roots.platform.serviceUser, "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 5, "Umask": 0o077,
            "StandardOutPath": roots.configuration.appendingPathComponent("logs/" + receipt.instance + ".log")
                .path,
            "StandardErrorPath": roots.configuration.appendingPathComponent(
                "logs/" + receipt.instance + ".log"
            ).path,
        ]
        if let node = receipt.uuidNode { dictionary["EnvironmentVariables"] = ["TRACTANDA_UUID_NODE": node] }
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }
    func waitUntilReady(_ receipt: InstallationReceipt) throws {
        if let readinessCheck {
            try readinessCheck(receipt.socket, roots.platform.serviceUser, receipt.port)
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        var lastError = "Service did not answer."
        repeat {
            do {
                let info = try SetupNativeClient(
                    socket: receipt.socket, serverUser: roots.platform.serviceUser
                ).call("TractandaStore/info")
                let uid = try SystemAccountDirectory().user(named: roots.platform.serviceUser).uid
                guard info["ownerUID"] as? UInt32 == uid, info["accessMode"] as? String == "multi-user",
                    info["callerIsAdministrator"] as? Bool == true
                else {
                    throw SetupError("Service identity or admission policy differs from the installation.")
                }
                let http = try runner.run(
                    "/usr/bin/curl",
                    [
                        "--noproxy", "*", "--fail", "--silent", "--show-error", "--max-time", "2",
                        "http://127.0.0.1:\(receipt.port)/manual",
                    ], environment: [:])
                guard http.status == 0, http.output.contains("Tractanda") else {
                    throw SetupError("The HTTP listener is not ready.")
                }
                return
            } catch { lastError = error.localizedDescription }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw SetupError("Service readiness timed out: " + lastError)
    }
}
