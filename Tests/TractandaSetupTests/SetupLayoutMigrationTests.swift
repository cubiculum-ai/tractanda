import CTractandaPlatform
import CTractandaSetupMetadata
import Foundation
import XCTest
@testable import TractandaCore
@testable import TractandaSetup

final class SetupLayoutMigrationTests: XCTestCase {
    private var temporary: URL?
    override func tearDownWithError() throws {
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }
    private func fixture(platform: SetupPlatform = .macos) throws -> (SetupEngine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tractanda-layout-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        temporary = root
        let config = root.appendingPathComponent("configuration")
        let roots = SetupRoots(platform: platform, software: root.appendingPathComponent("software"), configuration: config,
            launchDefinitions: root.appendingPathComponent("definitions"), runtime: root.appendingPathComponent("runtime"),
            data: root.appendingPathComponent("durable/Stores"), indexes: root.appendingPathComponent("durable/StoreIndices"),
            commands: root.appendingPathComponent("commands"), installation: root.appendingPathComponent("installation"),
            work: root.appendingPathComponent("work"), logs: root.appendingPathComponent("logs"))
        return (SetupEngine(roots: roots, runner: SetupTests.Runner(), rootCheck: { true }, trustedOwnership: false), root)
    }
    private func setFixtureAttribute(_ path: URL, value: String) throws {
        #if os(macOS)
        let result = try FoundationProcessRunner().run("/usr/bin/xattr", ["-w", "user.tractanda.layout-proof", value, path.path], environment: [:])
        #else
        let result = try FoundationProcessRunner().run("/usr/bin/python3", ["-c",
            "import os,sys; os.setxattr(sys.argv[1], 'user.tractanda.layout-proof', sys.argv[2].encode(), follow_symlinks=False)",
            path.path, value], environment: [:])
        #endif
        guard result.status == 0 else { throw SetupError("Private extended metadata fixture failed: " + result.output) }
    }
    func testExactHostDefaultsSeparateDurableIndexesAndTransientState() {
        let mac = SetupRoots(platform: .macos), linux = SetupRoots(platform: .linux)
        XCTAssertEqual(mac.data.path, "/Library/Tractanda/Stores")
        XCTAssertEqual(mac.indexes.path, "/Library/Tractanda/StoreIndices")
        XCTAssertEqual(mac.configuration.path, "/Library/Tractanda/Configuration")
        XCTAssertEqual(mac.software.path, "/Library/Tractanda/Software")
        XCTAssertEqual(mac.runtime.path, "/private/var/run/tractanda")
        XCTAssertEqual(mac.installation.path, "/Library/Tractanda/Installation")
        XCTAssertEqual(mac.logs.path, "/Library/Logs/Tractanda")
        XCTAssertEqual(mac.work.path, "/Library/Tractanda/Work")
        XCTAssertEqual(linux.data.path, "/opt/tractanda/var/lib/tractanda/Stores")
        XCTAssertEqual(linux.indexes.path, "/opt/tractanda/var/lib/tractanda/StoreIndices")
        XCTAssertEqual(linux.installation.path, "/opt/tractanda/var/lib/tractanda/Installation")
        XCTAssertEqual(linux.configuration.path, "/opt/tractanda/etc/tractanda")
        XCTAssertEqual(linux.runtime.path, "/run/tractanda")
        XCTAssertEqual(linux.logs.path, "/var/log/tractanda")
    }
    func testPathTranslationPreservesOrdinaryIdentityAndDictionaryKeys() {
        let migration = SetupLayoutMigration(engine: SetupEngine(roots: .init(platform: .macos)))
        let identity = "0f3052ae-d1d7-11f1-85fe-842f575e6ac5"
        let old = "/Users/Shared/Library/Application Support/Tractanda/releases/build"
        let result = migration.translatedJSON(["storeID": identity, "releases": [old: "digest"],
            "socket": "/Users/Shared/Library/Application Support/Tractanda/runtime/production/server.sock"]) as! [String: Any]
        XCTAssertEqual(result["storeID"] as? String, identity)
        XCTAssertEqual((result["releases"] as? [String: String])?["/Library/Tractanda/Software/releases/build"], "digest")
        XCTAssertEqual(result["socket"] as? String, "/private/var/run/tractanda/production/server.sock")
        XCTAssertEqual(migration.translated("/Users/Shared/Library/Application Support/Tractanda-other/file"),
            "/Users/Shared/Library/Application Support/Tractanda-other/file")
    }
    func testSameFilesystemRelocationAndReplayPreserveInodeBytesModesAndLinks() throws {
        let (engine, root) = try fixture()
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("canonical identity and revision bytes".utf8).write(to: source.appendingPathComponent("item"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "item")
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
        let migration = SetupLayoutMigration(engine: engine)
        var journal = SetupLayoutMigration.Journal(version: 1, platform: "macos", phase: "preparing",
            sourceConfig: migration.legacy.configuration.path, targetConfig: engine.roots.configuration.path,
            moves: [.init(source: source.path, target: target.path)], originalFiles: [:])
        let digest = try migration.inventory(source)
        try migration.relocate(&journal, index: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try migration.inventory(target), digest)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber, before)
        XCTAssertTrue(journal.moves[0].complete)
        // Simulate the rename completing before the move-completed journal write.
        journal.moves[0].complete = false
        try migration.relocate(&journal, index: 0)
        XCTAssertEqual(try migration.inventory(target), digest)
    }
    func testAmbiguousDestinationAndChangedSourceFailWithoutMutation() throws {
        let (engine, root) = try fixture()
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data("original".utf8).write(to: source)
        try Data("unrelated".utf8).write(to: target)
        let migration = SetupLayoutMigration(engine: engine)
        var journal = SetupLayoutMigration.Journal(version: 1, platform: "macos", phase: "preparing",
            sourceConfig: "old", targetConfig: "new", moves: [.init(source: source.path, target: target.path)], originalFiles: [:])
        XCTAssertThrowsError(try migration.relocate(&journal, index: 0))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unrelated")
        try FileManager.default.removeItem(at: target)
        journal.moves[0].digest = try migration.inventory(source)
        try Data("offline changed".utf8).write(to: source)
        XCTAssertThrowsError(try migration.relocate(&journal, index: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testRuntimePreparerIsRootOnlyAndNeverRunsContentServer() throws {
        let (engine, root) = try fixture()
        let receipt = try InstallationReceipt(options: .init(name: "production", owner: "rcfa", bundle: root),
            roots: engine.roots, owner: "rcfa", release: engine.roots.software.appendingPathComponent("releases/build"),
            manifestSHA256: String(repeating: "a", count: 64))
        let data = try engine.runtimeDefinition(receipt)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
        XCTAssertEqual(object["UserName"] as? String, "root")
        XCTAssertEqual(object["ProgramArguments"] as? [String], [URL(fileURLWithPath: receipt.release).appendingPathComponent("bin/tractanda-setup").path,
            "--prepare-managed-runtime", "production"])
        XCTAssertNil(object["WorkingDirectory"])
        XCTAssertThrowsError(try engine.prepareManagedRuntime("../other"))
        XCTAssertThrowsError(try engine.prepareManagedRuntime("production"))
    }
    func testRuntimeDirectoryRecreatedAndTamperedDefinitionRejected() throws {
        let (migration, _, root) = try wholeFixture(platform: .macos)
        _ = try migration.run()
        let engine = migration.engine
        var receipt = try XCTUnwrap(engine.readReceipt("production"))
        try engine.replaceRuntimeRegistration(&receipt)
        let helper = URL(fileURLWithPath: receipt.release).appendingPathComponent("bin/tractanda-setup")
        let definition = try PropertyListSerialization.propertyList(from: engine.runtimeDefinition(receipt), options: [], format: nil) as! [String: Any]
        XCTAssertEqual((definition["ProgramArguments"] as? [String])?.first, helper.path)
        let client = engine.roots.software.appendingPathComponent("current")
        try FileManager.default.removeItem(at: client)
        try engine.prepareManagedRuntime("production") // first-install/power-loss window: no current client alias
        try FileManager.default.createSymbolicLink(atPath: client.path, withDestinationPath: root.appendingPathComponent("obsolete-client").path)
        try engine.prepareManagedRuntime("production") // an old client alias never selects the root helper
        let runtime = engine.roots.runtime.appendingPathComponent("production")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: runtime.path)[.posixPermissions] as? NSNumber, 0o711)
        try FileManager.default.removeItem(at: engine.roots.runtime)
        try engine.prepareManagedRuntime("production")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.path))
        let original = try Data(contentsOf: helper)
        try Data("changed helper".utf8).write(to: helper)
        XCTAssertThrowsError(try engine.prepareManagedRuntime("production"))
        try original.write(to: helper)
        try Data("tampered".utf8).write(to: engine.runtimeDefinitionURL("production"))
        XCTAssertThrowsError(try engine.prepareManagedRuntime("production"))
    }

    func testLinuxVerifiedCopyRetainsLegacyProofAndResumesPinnedTemporary() throws {
        #if !os(Linux)
        throw XCTSkip("Actual GNU archive copy is qualified natively on Linux.")
        #else
        let (fixture, root) = try fixture(platform: .linux)
        let engine = SetupEngine(roots: fixture.roots, rootCheck: { true }, trustedOwnership: false)
        let migration = SetupLayoutMigration(engine: engine)
        let source = root.appendingPathComponent("receipts"), target = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("private receipt".utf8).write(to: source.appendingPathComponent("production.json"))
        try setFixtureAttribute(source.appendingPathComponent("production.json"), value: "copy-preserves-this")
        let temporary = URL(fileURLWithPath: target.path + ".layout-copy")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("partial".utf8).write(to: temporary.appendingPathComponent("production.json"))
        let metadata = try FileManager.default.attributesOfItem(atPath: temporary.path)
        var move = SetupLayoutMigration.Move(source: source.path, target: target.path)
        move.digest = try migration.inventory(source)
        move.temporaryInode = (metadata[.systemFileNumber] as? NSNumber)?.uint64Value
        move.temporaryDevice = ((metadata[.systemNumber] as? NSNumber)?.uint64Value ?? 0) + 999 // simulated remount numbering
        var journal = SetupLayoutMigration.Journal(version: 1, platform: "linux", phase: "preparing",
            sourceConfig: "old", targetConfig: "new", moves: [move], originalFiles: [:])
        try migration.relocate(&journal, index: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try migration.inventory(target), move.digest)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("production.json"), encoding: .utf8), "private receipt")
        journal.moves[0].complete = false
        try migration.relocate(&journal, index: 0)
        XCTAssertTrue(journal.moves[0].complete)
        #endif
    }
    func testLinuxCopyRejectsAnUnownedTemporaryWithoutTouchingIt() throws {
        #if !os(Linux)
        throw XCTSkip("Actual GNU archive copy is qualified natively on Linux.")
        #else
        let (fixture, root) = try fixture(platform: .linux)
        let migration = SetupLayoutMigration(engine: SetupEngine(roots: fixture.roots, rootCheck: { true }, trustedOwnership: false))
        let source = root.appendingPathComponent("receipts"), target = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let temporary = URL(fileURLWithPath: target.path + ".layout-copy")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        try Data("unrelated".utf8).write(to: temporary.appendingPathComponent("keep"))
        var journal = SetupLayoutMigration.Journal(version: 1, platform: "linux", phase: "preparing",
            sourceConfig: "old", targetConfig: "new", moves: [.init(source: source.path, target: target.path)], originalFiles: [:])
        XCTAssertThrowsError(try migration.relocate(&journal, index: 0))
        XCTAssertEqual(try String(contentsOf: temporary.appendingPathComponent("keep"), encoding: .utf8), "unrelated")
        #endif
    }

    func testDurabilityPrecedesCompletedJournalAndCrashReplaysRename() throws {
        let (engine, root) = try fixture()
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data("durable canonical bytes".utf8).write(to: source)
        var migration = SetupLayoutMigration(engine: engine)
        var journal = SetupLayoutMigration.Journal(version: 1, platform: "macos", phase: "preparing",
            sourceConfig: "old", targetConfig: "new", moves: [.init(source: source.path, target: target.path)], originalFiles: [:])
        var phases: [String] = []
        migration.phaseBoundaryForTesting = { phase in
            phases.append(phase)
            if phase == "parentsDurable" { throw SetupError("fixture crash before completed journal") }
        }
        XCTAssertThrowsError(try migration.relocate(&journal, index: 0))
        XCTAssertEqual(phases, ["destinationDurable", "parentsDurable"])
        var persisted = try JSONDecoder().decode(SetupLayoutMigration.Journal.self, from: Data(contentsOf: migration.marker))
        XCTAssertFalse(persisted.moves[0].complete)
        migration.phaseBoundaryForTesting = { phases.append($0) }
        try migration.relocate(&persisted, index: 0)
        XCTAssertEqual(Array(phases.suffix(3)), ["destinationDurable", "parentsDurable", "moveCommitted"])
        XCTAssertTrue(persisted.moves[0].complete)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "durable canonical bytes")
    }
    func testOwnedReleaseLeafRelocatesBesideStagedCandidateAndIdenticalCollisionReplays() throws {
        let (engine, root) = try fixture()
        let legacy = SetupRoots(platform: .macos, software: root.appendingPathComponent("legacy-software"),
            configuration: root.appendingPathComponent("legacy-configuration"))
        let migration = SetupLayoutMigration(engine: engine, legacyForTesting: legacy)
        let source = legacy.software.appendingPathComponent("releases/active")
        let target = engine.roots.software.appendingPathComponent("releases/active")
        let candidate = engine.roots.software.appendingPathComponent("releases/new-candidate")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("owned active".utf8).write(to: source.appendingPathComponent("binary"))
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try Data("staged candidate".utf8).write(to: candidate.appendingPathComponent("binary"))
        var journal = SetupLayoutMigration.Journal(version: 1, platform: "macos", phase: "preparing",
            sourceConfig: "old", targetConfig: "new", moves: [.init(source: source.path, target: target.path)], originalFiles: [:])
        try migration.relocate(&journal, index: 0)
        XCTAssertEqual(try String(contentsOf: candidate.appendingPathComponent("binary"), encoding: .utf8), "staged candidate")
        try FileManager.default.copyItem(at: target, to: source)
        journal.moves = [.init(source: source.path, target: target.path)]
        try migration.relocate(&journal, index: 0)
        XCTAssertTrue(journal.moves[0].complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testJournalRejectsCorruptPathsAndUnexpectedCapturedFiles() throws {
        let (engine, _) = try fixture()
        let migration = SetupLayoutMigration(engine: engine)
        let corrupt = SetupLayoutMigration.Journal(version: 1, platform: "macos", phase: "preparing",
            sourceConfig: "old", targetConfig: "new", moves: [.init(source: "/etc/passwd", target: "/Library/Tractanda/passwd")], originalFiles: [:])
        XCTAssertThrowsError(try migration.validate(corrupt))
        let captured = SetupLayoutMigration.Journal(version: 1, platform: "macos", phase: "preparing",
            sourceConfig: "old", targetConfig: "new", moves: [], originalFiles: ["/etc/passwd": Data("unowned".utf8)])
        XCTAssertThrowsError(try migration.validate(captured))
    }

    func testPublicAliasesResumeAfterSourceRenameAndRejectWrongAlias() throws {
        let (engine, root) = try fixture(platform: .linux)
        let legacy = SetupRoots(platform: .linux, configuration: root.appendingPathComponent("legacy-etc"),
            data: root.appendingPathComponent("legacy-var/stores"))
        let migration = SetupLayoutMigration(engine: engine, legacyForTesting: legacy)
        try FileManager.default.createDirectory(at: engine.roots.configuration, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine.roots.data, withIntermediateDirectories: true)
        let retained = URL(fileURLWithPath: legacy.configuration.path + ".layout-pre20261027")
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
        try Data("retained original".utf8).write(to: retained.appendingPathComponent("private"))
        try FileManager.default.createDirectory(at: legacy.data.deletingLastPathComponent(), withIntermediateDirectories: true)
        var journal = SetupLayoutMigration.Journal(version: 1, platform: "linux", phase: "relocated",
            sourceConfig: legacy.configuration.path, targetConfig: engine.roots.configuration.path, moves: [], originalFiles: [:])
        _ = try migration.completeRelocation(&journal)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: legacy.configuration.path), engine.roots.configuration.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: legacy.data.deletingLastPathComponent().path), engine.roots.data.deletingLastPathComponent().path)
        XCTAssertEqual(try String(contentsOf: retained.appendingPathComponent("private"), encoding: .utf8), "retained original")
        try FileManager.default.removeItem(at: legacy.configuration)
        try FileManager.default.createSymbolicLink(atPath: legacy.configuration.path, withDestinationPath: root.appendingPathComponent("wrong").path)
        journal.phase = "relocated"
        XCTAssertThrowsError(try migration.completeRelocation(&journal))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.appendingPathComponent("private").path))
    }
    func testLinuxEmptyPlaceholderCutResumesFromDurableMoveIntent() throws {
        #if !os(Linux)
        throw XCTSkip("Actual GNU archive copy is qualified natively on Linux.")
        #else
        let (fixture, root) = try fixture(platform: .linux)
        let migration = SetupLayoutMigration(engine: SetupEngine(roots: fixture.roots, rootCheck: { true }, trustedOwnership: false))
        let source = root.appendingPathComponent("receipts"), target = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("receipt".utf8).write(to: source.appendingPathComponent("production.json"))
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: target.path + ".layout-copy"), withIntermediateDirectories: false)
        var move = SetupLayoutMigration.Move(source: source.path, target: target.path)
        move.digest = try migration.inventory(source) // intent persisted before placeholder creation
        var journal = SetupLayoutMigration.Journal(version: 1, platform: "linux", phase: "preparing",
            sourceConfig: "old", targetConfig: "new", moves: [move], originalFiles: [:])
        try migration.relocate(&journal, index: 0)
        XCTAssertTrue(journal.moves[0].complete)
        XCTAssertEqual(try migration.inventory(target), move.digest)
        #endif
    }

    private func wholeFixture(platform: SetupPlatform) throws -> (SetupLayoutMigration, InstallationReceipt, URL) {
        let (initial, root) = try fixture(platform: platform)
        let legacy = SetupRoots(platform: platform,
            software: platform == .macos ? root.appendingPathComponent("legacy-software") : initial.roots.software,
            configuration: root.appendingPathComponent("legacy-etc"), launchDefinitions: initial.roots.launchDefinitions,
            runtime: platform == .macos ? root.appendingPathComponent("legacy-run") : initial.roots.runtime,
            data: root.appendingPathComponent("legacy-var/stores"), indexes: root.appendingPathComponent("legacy-cache/indexes"),
            commands: initial.roots.commands)
        let runner: any SetupProcessRunning = platform == .macos ? SetupTests.Runner() :
            SetupServiceBackendTests.Runner(fragment: initial.roots.launchDefinitions.appendingPathComponent("tractanda-server-production.service").path)
        // Real GNU cp on Linux; service manager calls only are mocked.
        final class Router: SetupProcessRunning, @unchecked Sendable {
            let services: any SetupProcessRunning
            init(_ services: any SetupProcessRunning) { self.services = services }
            func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> ProcessResult {
                if executable == "/bin/cp" { return try FoundationProcessRunner().run(executable, arguments, environment: environment) }
                return try services.run(executable, arguments, environment: environment)
            }
        }
        let engine = SetupEngine(roots: initial.roots, runner: Router(runner), rootCheck: { true }, trustedOwnership: false)
        let old = SetupEngine(roots: legacy, runner: Router(runner), rootCheck: { true }, trustedOwnership: false)
        let release = legacy.software.appendingPathComponent(platform == .macos ? "releases/active" : "current")
        var files: [BundleManifest.File] = []
        var names = ["bin/tractanda", "bin/tractanda-tui", "bin/tractanda-mcp", "bin/tractanda-setup", "lib/runtime",
            "templates/starter-categories.json", "docs/index.html", "licenses/LICENSE",
            "bin/Tractanda_TractandaWeb.bundle/Contents/Resources/Kanban.html"]
        if platform == .linux { names.append("bin/tractanda-auth-helper") }
        for name in names {
            let url = release.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data("fixture-\(name)".utf8)
            try bytes.write(to: url)
            let mode: UInt16 = name.hasPrefix("bin/tractanda") ? 0o755 : 0o644
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
            files.append(.init(path: name, sha256: ManagedPeerConfiguration.digest(bytes), size: UInt64(bytes.count), mode: mode))
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let manifest = BundleManifest(version: "0.1.0-layout-fixture", platform: platform.rawValue, arch: architecture,
            files: files, canonicalFormats: .current)
        let manifestBytes = try JSONEncoder().encode(manifest)
        try manifestBytes.write(to: release.appendingPathComponent("bundle-manifest.json"))
        let owner = try SystemAccountDirectory().user(forUID: tractanda_uid()).name
        var receipt = try InstallationReceipt(options: .init(name: "production", owner: owner, bundle: release),
            roots: legacy, owner: owner, release: release, manifestSHA256: ManagedPeerConfiguration.digest(manifestBytes))
        try StoreBootstrap.initialize(store: URL(fileURLWithPath: receipt.store), indexDirectory: URL(fileURLWithPath: receipt.indexDirectory), owner: owner, instance: "production")
        let ordinary = try { () throws -> (String, String, String) in
            let store = try ItemStore.openInitialized(root: URL(fileURLWithPath: receipt.store), indexDirectory: URL(fileURLWithPath: receipt.indexDirectory))
            let revision = try store.withAccess(forUID: tractanda_uid()) {
                try store.commit(.init(classID: "Item", changes: ["subject": .text("relocation keeps ordinary history")], operationID: "layout-fixture-create"))
            }.revision
            return (revision.itemID, revision.revisionID, try store.personalSyncIdentity().replicaID)
        }()
        receipt.board["layoutFixtureItemID"] = ordinary.0
        receipt.board["layoutFixtureRevisionID"] = ordinary.1
        receipt.board["layoutFixtureReplicaID"] = ordinary.2
        receipt.initialized = true; receipt.state = .active
        let definition = try old.serviceDefinition(receipt)
        receipt.definitionSHA256 = ManagedPeerConfiguration.digest(definition)
        try old.writeProtected(definition, to: old.definitionURL("production"), mode: 0o644)
        try old.writeReceipt(receipt)
        if platform == .linux {
            let descriptor = SetupPackageCompatibility(manifestSHA256: receipt.manifestSHA256, version: manifest.version,
                arch: architecture, canonicalFormats: .current)
            var state = try SetupPackageState(original: descriptor, instances: [.init(name: "production",
                originalManifestSHA256: receipt.manifestSHA256, wasRunning: true, wasEnabled: true,
                embeddingWasRunning: false, authenticationWasRunning: false)])
            state.incoming = descriptor; state.phase = .awaitingUnpack
            try old.writePackageState(state)
        }
        var profiles = ConnectionPreferences.Document()
        profiles.defaultProfile = "production"
        profiles.profiles["production"] = ServerConnection(socketPath: receipt.socket, serverUser: "daemon")
        try old.writeProtected(JSONEncoder().encode(profiles), to: legacy.configuration.appendingPathComponent("connections.json"), mode: 0o644)
        if platform == .macos {
            try FileManager.default.createSymbolicLink(atPath: legacy.software.appendingPathComponent("current").path, withDestinationPath: release.path)
            let candidate = engine.roots.software.appendingPathComponent("releases/staged-candidate")
            try FileManager.default.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: release, to: candidate)
        }
        return (SetupLayoutMigration(engine: engine, legacyForTesting: legacy), receipt, root)
    }
    private func verifyRelocatedOrdinaryContent(_ migration: SetupLayoutMigration, receipt: InstallationReceipt) throws {
        let store = try ItemStore.openInitialized(root: URL(fileURLWithPath: receipt.store), indexDirectory: URL(fileURLWithPath: receipt.indexDirectory))
        let itemID = try XCTUnwrap(receipt.board["layoutFixtureItemID"])
        let revisionID = try XCTUnwrap(receipt.board["layoutFixtureRevisionID"])
        try store.withAccess(forUID: tractanda_uid()) {
            XCTAssertEqual(try store.get(itemID).revisionID, revisionID)
            XCTAssertEqual(try store.get(itemID).fields["subject"], .text("relocation keeps ordinary history"))
            XCTAssertEqual(try store.history(itemID).map(\.revisionID), [revisionID])
            XCTAssertTrue(try store.candidates().contains(where: { $0.itemID == itemID && $0.revisionID == revisionID }))
        }
        XCTAssertEqual(try store.personalSyncIdentity().replicaID, receipt.board["layoutFixtureReplicaID"])
    }
    func testWholeMacTransitionReplaysAfterDataRenameAndKeepsStagedCandidate() throws {
        var (migration, receipt, _) = try wholeFixture(platform: .macos)
        let owner = tractanda_uid()
        let storeID = try CanonicalReaderRequirement.storeIdentity(root: URL(fileURLWithPath: receipt.store), ownerUID: owner)
        var crashed = false
        migration.phaseBoundaryForTesting = { phase in
            if phase == "moveCommitted", !crashed { crashed = true; throw SetupError("fixture crash after durable move") }
        }
        XCTAssertThrowsError(try migration.run())
        migration.phaseBoundaryForTesting = nil
        _ = try migration.run()
        let rewritten = try XCTUnwrap(migration.engine.readReceipt("production"))
        XCTAssertEqual(rewritten.store, migration.engine.roots.data.appendingPathComponent("production").path)
        XCTAssertEqual(rewritten.socket, migration.engine.roots.runtime.appendingPathComponent("production/server.sock").path)
        XCTAssertEqual(try CanonicalReaderRequirement.storeIdentity(root: URL(fileURLWithPath: rewritten.store), ownerUID: owner), storeID)
        try migration.engine.verifyRegistration(rewritten)
        try verifyRelocatedOrdinaryContent(migration, receipt: rewritten)
        let profiles = try JSONDecoder().decode(ConnectionPreferences.Document.self,
            from: Data(contentsOf: migration.engine.roots.configuration.appendingPathComponent("connections.json")))
        XCTAssertEqual(profiles.profiles["production"]?.socketPath, rewritten.socket)
        XCTAssertTrue(FileManager.default.fileExists(atPath: migration.engine.roots.software.appendingPathComponent("releases/staged-candidate/bundle-manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.store))
        XCTAssertTrue(try migration.run().contains("already committed"))
    }
    func testWholeLinuxTransitionReplaysCopyAndAliasGapPreservingIdentity() throws {
        #if !os(Linux)
        throw XCTSkip("Actual GNU archive copy and Linux whole transition run natively on Linux.")
        #else
        var (migration, receipt, _) = try wholeFixture(platform: .linux)
        let owner = tractanda_uid()
        let identity = try CanonicalReaderRequirement.storeIdentity(root: URL(fileURLWithPath: receipt.store), ownerUID: owner)
        let transaction = try Data(contentsOf: migration.legacy.configuration.appendingPathComponent("package-transaction.json"))
        let oldOperation = try JSONDecoder().decode(SetupPackageState.self, from: transaction).operationID
        var crashed = false
        migration.phaseBoundaryForTesting = { phase in
            if phase == "parentsDurable", !crashed { crashed = true; throw SetupError("fixture interrupted copied publication") }
        }
        XCTAssertThrowsError(try migration.run())
        migration.phaseBoundaryForTesting = nil
        _ = try migration.run()
        let rewritten = try XCTUnwrap(migration.engine.readReceipt("production"))
        XCTAssertEqual(try CanonicalReaderRequirement.storeIdentity(root: URL(fileURLWithPath: rewritten.store), ownerUID: owner), identity)
        try migration.engine.verifyRegistration(rewritten)
        try verifyRelocatedOrdinaryContent(migration, receipt: rewritten)
        XCTAssertEqual(try Data(contentsOf: migration.engine.packageStateURL), transaction)
        XCTAssertEqual(try migration.engine.readPackageState()?.operationID, oldOperation)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: migration.legacy.configuration.path), migration.engine.roots.configuration.path)
        let retained = URL(fileURLWithPath: migration.legacy.configuration.path + ".layout-pre20261027")
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.appendingPathComponent("receipts/production.json").path))
        // Replay the exact old-root-renamed / public-alias-not-yet-created window.
        try FileManager.default.removeItem(at: migration.legacy.configuration)
        var journal = try JSONDecoder().decode(SetupLayoutMigration.Journal.self, from: Data(contentsOf: migration.marker))
        journal.phase = "relocated"; try migration.save(journal)
        _ = try migration.run()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: migration.legacy.configuration.path), migration.engine.roots.configuration.path)
        #endif
    }

    func testWholeTransitionRefusesConcurrentOldAndNewInstallerLocks() throws {
        let (migration, receipt, _) = try wholeFixture(platform: .macos)
        let oldLock = migration.legacy.configuration.appendingPathComponent("installer.lock")
        let oldDescriptor = tractanda_lock(oldLock.path)
        XCTAssertGreaterThanOrEqual(oldDescriptor, 0)
        XCTAssertThrowsError(try migration.run())
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migration.marker.path))
        tractanda_unlock(oldDescriptor)
        let newDescriptor = tractanda_lock(migration.engine.roots.runtime.appendingPathComponent("installer.lock").path)
        XCTAssertGreaterThanOrEqual(newDescriptor, 0)
        XCTAssertThrowsError(try migration.run())
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.store))
        tractanda_unlock(newDescriptor)
        _ = try migration.run()
        XCTAssertNotNil(try migration.engine.readReceipt("production"))
    }

    func testInventoryIncludesPresentExtendedAttributeValues() throws {
        let (engine, root) = try fixture()
        let path = root.appendingPathComponent("file")
        try Data("same bytes".utf8).write(to: path)
        let migration = SetupLayoutMigration(engine: engine)
        try setFixtureAttribute(path, value: "before")
        let before = try migration.inventory(path)
        try setFixtureAttribute(path, value: "after")
        XCTAssertNotEqual(try migration.inventory(path), before)
        XCTAssertNotNil(try migration.extendedMetadata(path)["xattr:user.tractanda.layout-proof"])
    }

    func testAnchoredRuntimeRefusesReplacedRootEntryWithoutTouchingSymlinkTarget() throws {
        let (_, root) = try fixture()
        let parent = root.appendingPathComponent("run"), victim = root.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o775])
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let owner = tractanda_uid()
        let group = (try FileManager.default.attributesOfItem(atPath: parent.path)[.groupOwnerAccountID] as! NSNumber).uint32Value
        let context = try XCTUnwrap(tractanda_setup_runtime_open(parent.path, owner, group))
        defer { tractanda_setup_runtime_close(context) }
        let application = parent.appendingPathComponent("tractanda")
        try FileManager.default.moveItem(at: application, to: root.appendingPathComponent("held-original"))
        try FileManager.default.createSymbolicLink(atPath: application.path, withDestinationPath: victim.path)
        XCTAssertEqual(tractanda_setup_runtime_prepare(context, "production", owner), -1)
        XCTAssertEqual(tractanda_setup_runtime_lock(context), -1)
        XCTAssertNil(tractanda_setup_runtime_open(parent.path, owner, group))
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.appendingPathComponent("production").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.appendingPathComponent("installer.lock").path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: victim.path)[.posixPermissions] as? NSNumber, 0o700)
    }
    func testAnchoredRuntimeRejectsInstanceAndLockSymlinksAndUsesOwnedDescriptors() throws {
        let (_, root) = try fixture()
        let parent = root.appendingPathComponent("run"), victim = root.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o775])
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let owner = tractanda_uid()
        let group = (try FileManager.default.attributesOfItem(atPath: parent.path)[.groupOwnerAccountID] as! NSNumber).uint32Value
        let context = try XCTUnwrap(tractanda_setup_runtime_open(parent.path, owner, group))
        defer { tractanda_setup_runtime_close(context) }
        let application = parent.appendingPathComponent("tractanda")
        try FileManager.default.createSymbolicLink(atPath: application.appendingPathComponent("production").path, withDestinationPath: victim.path)
        XCTAssertEqual(tractanda_setup_runtime_prepare(context, "production", owner), -1)
        try FileManager.default.removeItem(at: application.appendingPathComponent("production"))
        XCTAssertEqual(tractanda_setup_runtime_prepare(context, "production", owner), 0)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: application.appendingPathComponent("production").path)[.posixPermissions] as? NSNumber, 0o711)
        let target = victim.appendingPathComponent("untouched")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: application.appendingPathComponent("installer.lock").path, withDestinationPath: target.path)
        XCTAssertEqual(tractanda_setup_runtime_lock(context), -1)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        try FileManager.default.removeItem(at: application.appendingPathComponent("installer.lock"))
        let lock = tractanda_setup_runtime_lock(context)
        XCTAssertGreaterThanOrEqual(lock, 0)
        XCTAssertEqual(tractanda_setup_runtime_lock(context), -1)
        tractanda_unlock(lock)
        XCTAssertEqual(tractanda_setup_runtime_validate(context), 0)
    }

    func testPackagePreparedActiveDiagnosticMigratesAndConfiguresWithOriginalIntent() throws {
        #if !os(Linux)
        throw XCTSkip("Actual GNU archive copy and Linux package lifecycle integration.")
        #else
        let (_, root) = try fixture(platform: .linux)
        let package = try SetupPackageLifecycleTests.Fixture(root: root.appendingPathComponent("p"),
            dataRoot: root.appendingPathComponent("v/stores"))
        try package.configureFresh()
        try package.install("production")
        try package.engine.stop(package.options("production"))
        let (stoppedDeclaration, stoppedManifest) = try package.next("0.1.0-poc.16")
        _ = try package.hook(.prermUpgrade)
        _ = try package.hook(.preinst, stoppedDeclaration)
        try stoppedManifest.write(to: package.manifestURL)
        _ = try package.hook(.configure, stoppedDeclaration)
        let stopped = try XCTUnwrap(package.engine.readReceipt("production"))
        XCTAssertEqual(stopped.state, .active)
        XCTAssertNotNil(stopped.recoveryReason)
        try package.engine.start(package.options("production"))
        XCTAssertEqual(try package.engine.readReceipt("production")?.recoveryReason, stopped.recoveryReason)
        let original = try { () throws -> (String, String, String, String) in
            let store = try ItemStore.openInitialized(root: URL(fileURLWithPath: stopped.store), indexDirectory: URL(fileURLWithPath: stopped.indexDirectory))
            let revision = try store.withAccess(forUID: tractanda_uid()) {
                try store.commit(.init(classID: "Item", changes: ["subject": .text("package transition preserves immutable history")], operationID: "layout-package-create"))
            }.revision
            let identity = try store.personalSyncIdentity()
            return (revision.itemID, revision.revisionID, identity.storeID, identity.replicaID)
        }()
        let (incoming, incomingManifest) = try package.next("0.1.0-poc.17")
        _ = try package.hook(.prermUpgrade)
        _ = try package.hook(.preinst, incoming)
        try incomingManifest.write(to: package.manifestURL)
        let before = try Data(contentsOf: package.engine.packageStateURL)
        let transaction = try XCTUnwrap(package.engine.readPackageState())
        XCTAssertEqual(transaction.phase, .awaitingUnpack)
        XCTAssertEqual(transaction.instances.map(\.wasRunning), [true])
        XCTAssertEqual(transaction.instances.map(\.authenticationWasRunning), [true])
        XCTAssertEqual(try package.engine.readReceipt("production")?.state, .active)
        final class CopyRouter: SetupProcessRunning, @unchecked Sendable {
            let manager: SetupPackageLifecycleTests.Runner
            init(_ manager: SetupPackageLifecycleTests.Runner) { self.manager = manager }
            func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> ProcessResult {
                if executable == "/bin/cp" { return try FoundationProcessRunner().run(executable, arguments, environment: environment) }
                return try manager.run(executable, arguments, environment: environment)
            }
        }
        let roots = SetupRoots(platform: .linux, software: package.engine.roots.software,
            configuration: root.appendingPathComponent("new-etc"), launchDefinitions: package.engine.roots.launchDefinitions,
            runtime: package.engine.roots.runtime, data: root.appendingPathComponent("new-state/Stores"),
            indexes: root.appendingPathComponent("new-state/StoreIndices"), commands: package.engine.roots.commands,
            installation: root.appendingPathComponent("new-state/Installation"), work: root.appendingPathComponent("new-state/Work"),
            logs: root.appendingPathComponent("new-logs"))
        let engine = SetupEngine(roots: roots, runner: CopyRouter(package.runner), rootCheck: { true }, trustedOwnership: false,
            peerStatusCall: { _, _ in try .init(state: .disabled, synchronization: .init(state: .disabled)) }, readinessCheck: { _, _, _ in })
        engine.packageOwnerIdentity = package.engine.packageOwnerIdentity
        engine.packageOwnerIsLive = package.engine.packageOwnerIsLive
        engine.packageAuthenticationReadiness = package.engine.packageAuthenticationReadiness
        engine.packageStartPolicy = package.engine.packageStartPolicy
        package.runner.foreignUnit = "tractanda-server-production.service"
        XCTAssertThrowsError(try engine.packageLifecycle(.init(action: .prermUpgrade, descriptor: nil, instance: nil)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.packageStateURL.path))
        XCTAssertEqual(try Data(contentsOf: package.engine.packageStateURL), before)
        package.runner.foreignUnit = nil
        let migration = SetupLayoutMigration(engine: engine, legacyForTesting: package.engine.roots)
        _ = try migration.run()
        XCTAssertEqual(try Data(contentsOf: engine.packageStateURL), before)
        XCTAssertEqual(try engine.readPackageState()?.operationID, transaction.operationID)
        XCTAssertEqual(try engine.readReceipt("production")?.recoveryReason, stopped.recoveryReason)
        let bootstraps = package.runner.bootstraps
        _ = try engine.configurePackage(incoming)
        let committed = try XCTUnwrap(engine.readPackageState())
        XCTAssertEqual(committed.operationID, transaction.operationID)
        XCTAssertEqual(committed.phase, .committed)
        XCTAssertEqual(committed.instances, transaction.instances)
        XCTAssertEqual(package.runner.bootstraps, bootstraps)
        let receipt = try XCTUnwrap(engine.readReceipt("production"))
        XCTAssertEqual(receipt.state, .active)
        let store = try ItemStore.openInitialized(root: URL(fileURLWithPath: receipt.store), indexDirectory: URL(fileURLWithPath: receipt.indexDirectory))
        try store.withAccess(forUID: tractanda_uid()) {
            XCTAssertEqual(try store.get(original.0).revisionID, original.1)
            XCTAssertEqual(try store.history(original.0).map(\.revisionID), [original.1])
        }
        let identity = try store.personalSyncIdentity()
        XCTAssertEqual(identity.storeID, original.2)
        XCTAssertEqual(identity.replicaID, original.3)
        XCTAssertTrue(package.runner.running.contains("tractanda-server-production.service"))
        XCTAssertTrue(package.runner.running.contains("tractanda-authentication-production.service"))
        #endif
    }

    func testTypedPendingReceiptStillBlocksMigrationDespiteInformationalDiagnostic() throws {
        let (migration, original, _) = try wholeFixture(platform: .macos)
        let old = SetupEngine(roots: migration.legacy, rootCheck: { true }, trustedOwnership: false)
        var pending = original
        pending.state = .preparing
        pending.recoveryReason = "Package configured without starting this previously stopped or policy-blocked instance."
        try old.writeReceipt(pending)
        XCTAssertThrowsError(try migration.run())
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migration.marker.path))
        pending = original
        pending.recoveryReason = "Retained diagnostic does not cancel a semantic rollback snapshot."
        pending.embeddingPreviousConfiguration = .init(formatVersion: 1,
            configurationID: original.embeddingConfigurationID, operationID: original.embeddingConfigurationID,
            endpoint: "http://127.0.0.1:1", model: "fixture", modelRevision: "fixture", dimensions: 1,
            documentPrefix: "", queryPrefix: "", chunkBytes: 1, overlapBytes: 0,
            pooling: "mean", normalization: "none", inputEncoding: "utf8")
        try old.writeReceipt(pending)
        XCTAssertThrowsError(try migration.run())
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migration.marker.path))
    }

}
