import CTractandaPlatform
import Foundation
import TractandaCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Explicit new-target preparation. The caller parses the private invitation first and
/// passes only its public metadata; this helper never reads or serializes the code.
struct ClusterEnrollmentSetup {
    struct InstalledSetup: Equatable {
        let helper: URL
        let bundle: URL
    }
    struct Dependencies {
        var uid: () -> UInt32
        var accountName: (UInt32) throws -> String
        var installedSetup: () throws -> InstalledSetup
        var userProfiles: () throws -> ConnectionPreferences.Document
        var systemProfiles: () throws -> ConnectionPreferences.Document
        var runSudo: (URL, [String], [String: String]) throws -> Int32
        var expectedSocket: (String) -> String

        static func live() -> Self {
            let preferences = ConnectionPreferences(url: ConnectionPreferences.configurationURL(),
                globalURL: ConnectionPreferences.globalConfigurationURL())
            return .init(uid: { getuid() }, accountName: { try SystemAccountDirectory().user(forUID: $0).name },
                installedSetup: { try ClusterEnrollmentSetup.installedSetup() },
                userProfiles: { try preferences.load() }, systemProfiles: { try preferences.loadGlobal() },
                runSudo: { helper, arguments, environment in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                    process.arguments = ["--", helper.path] + arguments
                    // The invitation is never put into the environment; use a minimal fixed one.
                    process.environment = environment
                    process.standardInput = FileHandle.standardInput
                    process.standardOutput = FileHandle.standardOutput
                    process.standardError = FileHandle.standardError
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus
                }, expectedSocket: { name in
                    #if os(macOS)
                    return "/private/var/run/tractanda/" + name + "/server.sock"
                    #else
                    return "/run/tractanda/" + name + "/server.sock"
                    #endif
                })
        }
    }

    static func prepareNew(instance: String, metadata: PersonalEnrollmentInvitationMetadata,
        dependencies: Dependencies = .live()) throws -> ServerConnection {
        try ConnectionPreferences.validateName(instance)
        guard instance.utf8.count <= 32 else { throw failure("invalidProfile") }
        try metadata.validate()
        let uid = dependencies.uid()
        guard uid != 0 else { throw failure("invalidOwner") }
        let owner = try dependencies.accountName(uid)
        guard !owner.isEmpty, !owner.hasPrefix("-"), owner.utf8.count <= 128,
            owner.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || [45, 46, 95].contains($0) }) else {
            throw failure("invalidOwner")
        }
        let installed = try dependencies.installedSetup()
        guard try dependencies.userProfiles().profiles[instance] == nil else {
            throw TractandaError("profileExists", "A user profile already uses this name. Resolve the shadow before selecting a target; no setup was run.")
        }
        if let existing = try dependencies.systemProfiles().profiles[instance] {
            guard existing.socketPath == dependencies.expectedSocket(instance), existing.serverUser == "daemon",
                existing.managedService == nil else {
                throw TractandaError("profileExists", "An existing shared profile differs from the expected managed target. Inspect it before proceeding; no setup was run.")
            }
            let commandPath = installed.bundle.appendingPathComponent("bin/tractanda").path
            let command = "'" + commandPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            throw TractandaError("profileExists", "A shared target profile already exists. If setup is complete, use " + command
                + " --profile " + instance + " cluster join --hostname HOSTNAME, or " + command
                + " --profile " + instance + " cluster resume for an existing operation. If setup is incomplete, recover its exact local Setup transaction first.")
        }
        let arguments = ["install", "--bundle", installed.bundle.path, "--name", instance,
            "--owner", owner, "--empty", "--fresh-personal-target", "--store-id", metadata.storeID,
            "--new-instance-only", "--outbound-peer-sync"]
        let result: Int32
        do { result = try dependencies.runSudo(installed.helper, arguments, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]) }
        catch { throw failure("setupFailed") }
        guard result == 0 else { throw failure("setupFailed") }
        // Read the root-owned system registry directly. A user alias cannot redirect this join.
        guard try dependencies.userProfiles().profiles[instance] == nil,
            var selected = try dependencies.systemProfiles().profiles[instance],
            selected.socketPath == dependencies.expectedSocket(instance), selected.serverUser == "daemon",
            selected.managedService == nil else { throw failure("setupProfileMismatch") }
        selected.managedService = nil
        try selected.validate()
        return selected
    }

    private static func installedSetup() throws -> InstalledSetup {
        guard getuid() == geteuid(), getuid() != 0 else { throw failure("invalidOwner") }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard tractanda_current_executable(&buffer, UInt32(buffer.count)) == 0,
            let image = String(validatingUTF8: buffer), image.hasPrefix("/"), !image.hasSuffix(" (deleted)")
        else { throw failure("setupUnavailable") }
        let executable = URL(fileURLWithPath: image)
        let bin = executable.deletingLastPathComponent(), bundle = bin.deletingLastPathComponent()
        guard executable.lastPathComponent == "tractanda", bin.lastPathComponent == "bin" else {
            throw failure("setupUnavailable")
        }
        #if os(macOS)
        let releaseParent = "/Library/Tractanda/Software/releases"
        guard bundle.deletingLastPathComponent().path == releaseParent else { throw failure("setupUnavailable") }
        #else
        guard bundle.path == "/opt/tractanda/current" else { throw failure("setupUnavailable") }
        #endif
        let helper = bin.appendingPathComponent("tractanda-setup")
        guard tractanda_validate_enrollment_helper(helper.path, 1) == 0 else {
            throw failure("setupUnavailable")
        }
        return .init(helper: helper, bundle: bundle)
    }
    private static func failure(_ code: String) -> TractandaError {
        .init(code, "New target preparation stopped. Existing data was not adopted; inspect the local Setup state.")
    }
}
