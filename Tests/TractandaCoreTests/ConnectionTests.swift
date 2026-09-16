import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class ConnectionTests: XCTestCase {
    func testProfileDiagnosticsDistinguishDefaultsFromLiteralNamesAndAliases() throws {
        let socket = ServerConnection(socketPath: "/tmp/shared.sock", serverUser: "daemon")
        var user = ConnectionPreferences.Document()
        user.defaultProfile = "project"
        user.profiles = ["project": socket]
        var system = ConnectionPreferences.Document()
        system.defaultProfile = "production"
        system.profiles = ["production": socket]
        let personal = try XCTUnwrap(
            ConnectionPreferences.selectProfileDetails(user: user, name: nil, global: { system }))
        XCTAssertEqual(personal.profileName, "project")
        XCTAssertEqual(personal.source, .user)
        let shared = try XCTUnwrap(
            ConnectionPreferences.selectProfileDetails(user: user, name: "production", global: { system }))
        XCTAssertEqual(shared.profileName, "production")
        XCTAssertEqual(shared.source, .system)
        XCTAssertEqual(personal.connection, shared.connection)
        XCTAssertThrowsError(
            try ConnectionPreferences.selectProfileDetails(user: user, name: "default", global: { system }))
        let fallback = try XCTUnwrap(
            ConnectionPreferences.selectProfileDetails(user: .init(), name: nil, global: { system }))
        XCTAssertEqual(fallback.profileName, "production")
    }

    func testResolvedBindingIsFrozenAndExplicitSocketBypassesBrokenProfiles() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = ConnectionPreferences(url: directory.appendingPathComponent("connections.json"))
        try preferences.update {
            $0.defaultProfile = "project"
            $0.profiles["project"] = ServerConnection(socketPath: "/tmp/old.sock", managedService: "project")
        }
        let original = try preferences.resolveDetails(startsService: false)
        XCTAssertEqual(original.profileName, "project")
        XCTAssertEqual(original.source, .user)
        XCTAssertNil(original.connection.managedService)
        try preferences.update { $0.profiles["project"] = ServerConnection(socketPath: "/tmp/new.sock") }
        XCTAssertEqual(original.connection.socketPath, "/tmp/old.sock")
        XCTAssertEqual(try preferences.resolveDetails().connection.socketPath, "/tmp/new.sock")
        try Data("broken".utf8).write(to: preferences.url)
        let explicit = try preferences.resolveDetails(socketPath: "/tmp/explicit.sock")
        XCTAssertEqual(explicit.source, .explicitSocket)
        XCTAssertNil(explicit.profileName)
    }

    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(
            "tc-" + String(Identifier.make().prefix(8)))
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    func testDefaultAndNamedProfilesWithExplicitOverrideAndNoStart() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = ConnectionPreferences(url: directory.appendingPathComponent("connections.json"))
        let first = ServerConnection(socketPath: "/tmp/first.sock", managedService: "first")
        let second = ServerConnection(socketPath: "/tmp/second.sock")
        try preferences.update {
            $0.profiles = ["first": first, "second": second]
            $0.defaultProfile = "first"
        }
        XCTAssertEqual(try preferences.resolve().socketPath, first.socketPath)
        XCTAssertEqual(try preferences.resolve(profile: "second").socketPath, second.socketPath)
        XCTAssertNil(try preferences.resolve(startsService: false).managedService)
        XCTAssertThrowsError(try preferences.resolve(socketPath: "/tmp/third", profile: "first"))
        XCTAssertThrowsError(try preferences.resolve(profile: "missing"))
        try Data("broken configuration".utf8).write(to: preferences.url)
        XCTAssertEqual(try preferences.resolve(socketPath: "/tmp/explicit").socketPath, "/tmp/explicit")
        XCTAssertThrowsError(try preferences.resolve())
    }

    func testConfigurationValidationDoesNotPublishInvalidEdits() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = ConnectionPreferences(url: directory.appendingPathComponent("connections.json"))
        XCTAssertEqual(try preferences.load(), ConnectionPreferences.Document())
        XCTAssertEqual(try preferences.resolve().socketPath, ConnectionPreferences.localSocketPath())
        XCTAssertThrowsError(try preferences.update { $0.defaultProfile = "missing" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferences.url.path))
        XCTAssertThrowsError(try preferences.update { $0.version = 9 })
        XCTAssertThrowsError(
            try preferences.update { $0.profiles["../escape"] = ServerConnection(socketPath: "/tmp/s") })
        XCTAssertThrowsError(try ServerConnection(socketPath: "relative").validate())
        XCTAssertThrowsError(
            try ServerConnection(socketPath: "/tmp/s", serverUser: "bad\naccount").validate())
        XCTAssertThrowsError(
            try ServerConnection(socketPath: "/tmp/" + String(repeating: "x", count: 103)).validate())
        try preferences.update { $0.profiles["valid"] = ServerConnection(socketPath: "/tmp/s") }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: preferences.url.path)
        XCTAssertThrowsError(try preferences.load())
    }

    func testGlobalProfilesAreReadOnlyFallbackAndCannotManageAUserService() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let global = directory.appendingPathComponent("system-connections.json")
        let preferences = ConnectionPreferences(
            url: directory.appendingPathComponent("connections.json"), globalURL: global)
        let system = ConnectionPreferences.Document()
        XCTAssertEqual(system.profiles.count, 0)
        try JSON.encode(ConnectionPreferences.Document()).write(to: global)
        // A non-root fixture must never be accepted as a system registry.
        XCTAssertThrowsError(try preferences.loadGlobal())
        // Local configuration remains private and takes precedence without reading global data.
        try preferences.update {
            $0.profiles["local"] = ServerConnection(socketPath: "/tmp/local.sock")
            $0.defaultProfile = "local"
        }
        XCTAssertEqual(try preferences.resolve().socketPath, "/tmp/local.sock")
    }

    func testLocalProfilesDoNotHideInstalledProfilesAndDefaultsCanReferToThem() throws {
        var user = ConnectionPreferences.Document()
        user.profiles["local"] = ServerConnection(socketPath: "/tmp/local.sock")
        user.defaultProfile = "local"
        var global = ConnectionPreferences.Document()
        global.profiles["installed"] = ServerConnection(
            socketPath: "/tmp/installed.sock", serverUser: "daemon")
        global.profiles["local"] = ServerConnection(socketPath: "/tmp/shadowed.sock")
        global.defaultProfile = "installed"
        XCTAssertEqual(
            try ConnectionPreferences.selectProfile(user: user, name: "installed", global: { global })?
                .serverUser, "daemon")
        XCTAssertEqual(
            try ConnectionPreferences.selectProfile(
                user: user, name: "local",
                global: {
                    XCTFail("A local override must not read the global registry")
                    return global
                })?.socketPath, "/tmp/local.sock")
        user.defaultProfile = "installed"
        XCTAssertEqual(
            try ConnectionPreferences.selectProfile(user: user, name: nil, global: { global })?.socketPath,
            "/tmp/installed.sock")
    }

    func testMissingDefaultCanBeRepairedWithoutEditingTheFileByHand() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = ConnectionPreferences(url: directory.appendingPathComponent("connections.json"))
        var stale = ConnectionPreferences.Document()
        stale.defaultProfile = "removed"
        try PrivateConfiguration.write(try JSON.encode(stale), to: preferences.url)
        XCTAssertThrowsError(try preferences.resolve())
        try preferences.update { $0.defaultProfile = nil }
        XCTAssertNil(try preferences.load().defaultProfile)
    }

    func testExplicitSocketDoesNotReadGlobalConfiguration() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let global = directory.appendingPathComponent("system-connections.json")
        try Data("not json".utf8).write(to: global)
        let preferences = ConnectionPreferences(
            url: directory.appendingPathComponent("missing.json"), globalURL: global)
        XCTAssertEqual(
            try preferences.resolve(socketPath: "/tmp/explicit.sock").socketPath, "/tmp/explicit.sock")
    }

    func testConnectionOptionsKeepCommandArgumentsIntact() throws {
        var arguments = ["--profile", "project", "--no-start", "query", "--profile"]
        var options = ConnectionOptions()
        try options.consume(&arguments)
        XCTAssertEqual(options.profile, "project")
        XCTAssertFalse(options.startsService)
        XCTAssertEqual(arguments, ["query", "--profile"])
        var missing = ["--socket"]
        XCTAssertThrowsError(try options.consume(&missing))
    }

    func testManagedCleanupRejectsLiveSocketsAndFilesButRemovesDeadSocket() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s").path
        XCTAssertEqual(tractanda_remove_stale_socket(path), 0)
        let descriptor = tractanda_listen(path)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(tractanda_remove_stale_socket(path), -1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        tractanda_close(descriptor)
        XCTAssertEqual(tractanda_remove_stale_socket(path), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let url = URL(fileURLWithPath: path)
        try Data("keep me".utf8).write(to: url)
        XCTAssertEqual(tractanda_remove_stale_socket(path), -1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep me")
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertEqual(tractanda_remove_stale_socket(link.path), -1)
    }

    func testManagedDefinitionsUseDaemonOwnedSocketsAndLiteralArguments() throws {
        let record = ManagedServer.Registration(
            name: "project", storePath: "/tmp/store with $dollar %spec \\\"quote",
            binaryPath: "/tmp/bin/tractanda",
            definitionPath: "/tmp/unused", logPath: "/tmp/log",
            connection: ServerConnection(socketPath: "/tmp/s"))
        let plist =
            try PropertyListSerialization.propertyList(
                from: ManagedServer.launchdDefinition(record), format: nil) as! [String: Any]
        XCTAssertNil(plist["Sockets"])
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual((plist["ProgramArguments"] as? [String])?[2], record.storePath)
        let unit = try ManagedServer.systemdDefinition(record)
        XCTAssertTrue(unit.contains("$$dollar %%spec"))
        XCTAssertTrue(unit.contains("Restart=always"))
        XCTAssertTrue(unit.contains("--managed"))
    }

    func testOldManagedRegistrationUsesLegacyArgumentsAndSharedRegistrationUsesDaemon() throws {
        let old = try JSON.decode(
            ManagedServer.Registration.self,
            Data(
                """
                {"name":"project","storePath":"/tmp/store","binaryPath":"/tmp/tractanda","definitionPath":"/tmp/unit","logPath":"/tmp/log","connection":{"socketPath":"/tmp/project.sock","serverUser":"user","managedService":"project"}}
                """.utf8))
        XCTAssertNil(old.nativeProgramArguments)
        XCTAssertEqual(
            try ManagedServer.nativeProgramArguments(for: old),
            ["/tmp/tractanda", "serve", "/tmp/store", "/tmp/project.sock", "--managed"])

        let identifiers = (0..<3).map { _ in Identifier.make() }
        let shared = ManagedServer.Registration(
            name: "project", storePath: "/tmp/store with spaces", binaryPath: "/tmp/tractanda",
            definitionPath: "/tmp/unit", logPath: "/tmp/log",
            connection: ServerConnection(socketPath: "/tmp/project.sock", managedService: "project"),
            nativeProgramArguments: [
                "/tmp/tractanda", "daemon", "/tmp/store with spaces", "/tmp/project.sock", "--managed",
                "--http-port", "48728", "--project-root", identifiers[0], "--status-root", identifiers[1],
                "--project", identifiers[2],
            ])
        XCTAssertEqual(try ManagedServer.nativeProgramArguments(for: shared), shared.nativeProgramArguments)
        let plist =
            try PropertyListSerialization.propertyList(
                from: ManagedServer.launchdDefinition(shared), format: nil) as! [String: Any]
        XCTAssertEqual(plist["ProgramArguments"] as? [String], shared.nativeProgramArguments)
        XCTAssertTrue(try ManagedServer.systemdDefinition(shared).contains("\"/tmp/store with spaces\""))
    }

    func testManagedRegistrationRejectsUnboundedOrConflictingNativeArguments() throws {
        let record = ManagedServer.Registration(
            name: "project", storePath: "/tmp/store", binaryPath: "/tmp/tractanda",
            definitionPath: "/tmp/unit", logPath: "/tmp/log",
            connection: ServerConnection(socketPath: "/tmp/project.sock", managedService: "project"),
            nativeProgramArguments: [
                "/bin/sh", "daemon", "/tmp/store", "/tmp/project.sock", "--managed", "-c",
            ])
        XCTAssertThrowsError(try ManagedServer.nativeProgramArguments(for: record))
        let duplicateHTTP = ManagedServer.Registration(
            name: "project", storePath: "/tmp/store", binaryPath: "/tmp/tractanda",
            definitionPath: "/tmp/unit", logPath: "/tmp/log",
            connection: ServerConnection(socketPath: "/tmp/project.sock", managedService: "project"),
            nativeProgramArguments: [
                "/tmp/tractanda", "daemon", "/tmp/store", "/tmp/project.sock", "--managed",
                "--http-port", "1", "--http-port", "2",
            ])
        XCTAssertThrowsError(try ManagedServer.nativeProgramArguments(for: duplicateHTTP))
    }

    func testUnavailableUnmanagedConnectionDoesNotCreateAStore() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ServerConnection(socketPath: directory.appendingPathComponent("missing").path)
        XCTAssertThrowsError(try ItemClient(connection: connection).state()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "connectionFailed")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
}
