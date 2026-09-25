import Crypto
import Foundation
import TractandaCore
import XCTest

@testable import TractandaSetup

final class SetupTests: XCTestCase {
    final class Runner: SetupProcessRunning, @unchecked Sendable {
        var calls: [(String, [String])] = []
        var jobs = Set<String>()
        var loaded: Bool { !jobs.isEmpty }
        var failNextBootstrap = false
        func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws
            -> ProcessResult
        {
            calls.append((executable, arguments))
            if executable == "/bin/launchctl" {
                switch arguments.first {
                case "print":
                    return ProcessResult(
                        status: jobs.contains(arguments[1]) ? 0 : 1, output: "state = running\npid = 4242\n")
                case "bootstrap":
                    if failNextBootstrap {
                        failNextBootstrap = false
                        return ProcessResult(status: 1, output: "fixture launch failure")
                    }
                    jobs.insert(
                        "system/"
                            + URL(fileURLWithPath: arguments[2]).deletingPathExtension().lastPathComponent)
                case "bootout": jobs.remove(arguments[1])
                default: break
                }
            }
            if executable == "/usr/sbin/lsof" {
                return ProcessResult(status: 0, output: "p4242\nn127.0.0.1:48729\n")
            }
            if executable == "/usr/bin/curl" {
                return ProcessResult(
                    status: 0, output: "{\"ready\":true,\"model\":\"" + EmbeddingPayload.granite.model + "\"}"
                )
            }
            return ProcessResult(status: 0)
        }
    }

    struct Fixture {
        let root: URL
        let roots: SetupRoots
        let bundle: URL
        let owner: String
        var options: SetupOptions { SetupOptions(name: "preview", owner: owner, bundle: bundle) }
    }
    private func fixture() throws -> Fixture {
        #if !os(macOS)
            throw XCTSkip("Managed macOS installation tests; Linux installer remains in development.")
        #endif
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "tractanda-setup-\(UUID().uuidString)")
        let roots = SetupRoots(
            platform: .macos, software: root.appendingPathComponent("software"),
            configuration: root.appendingPathComponent("configuration"),
            launchDefinitions: root.appendingPathComponent("jobs"),
            runtime: root.appendingPathComponent("run"), data: root.appendingPathComponent("stores"),
            indexes: root.appendingPathComponent("indexes"), commands: root.appendingPathComponent("commands")
        )
        let bundle = root.appendingPathComponent("bundle")
        let names = [
            "bin/tractanda", "bin/tractanda-tui", "bin/tractanda-mcp", "bin/tractanda-setup",
            "lib/runtime", "templates/starter-categories.json", "docs/index.html", "licenses/LICENSE",
            "bin/Tractanda_TractandaWeb.bundle/Contents/Resources/Kanban.html",
        ]
        var files: [BundleManifest.File] = []
        for name in names {
            let url = bundle.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            let data = Data("fixture-\(name)".utf8)
            try data.write(to: url)
            let mode: UInt16 = name.hasPrefix("bin/tractanda") ? 0o755 : 0o644
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
            files.append(
                .init(
                    path: name, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    size: UInt64(data.count), mode: mode))
        }
        #if arch(arm64)
            let arch = "arm64"
        #else
            let arch = "x86_64"
        #endif
        try JSONEncoder().encode(
            BundleManifest(version: "0.1.0-preview.1", platform: "macos", arch: arch, files: files)
        )
        .write(to: bundle.appendingPathComponent("bundle-manifest.json"))
        let owner = try SystemAccountDirectory().user(forUID: getuid()).name
        return Fixture(root: root, roots: roots, bundle: bundle, owner: owner)
    }
    private func engine(_ fixture: Fixture, runner: Runner = Runner()) -> SetupEngine {
        SetupEngine(
            roots: fixture.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            readinessCheck: { _, account, _ in XCTAssertEqual(account, "daemon") })
    }

    private func addGranitePayload(to fixture: Fixture) throws {
        let manifestURL = fixture.bundle.appendingPathComponent("bundle-manifest.json")
        let original = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: manifestURL))
        var files = original.files
        for name in [
            "bin/tractanda-embeddings", "licenses/Granite/LICENSE", "licenses/Granite/README.md",
            "models/granite-embedding-311m-multilingual-r2/model.safetensors",
            "models/granite-embedding-311m-multilingual-r2/config.json",
            "models/granite-embedding-311m-multilingual-r2/1_Pooling/config.json",
            "models/granite-embedding-311m-multilingual-r2/config_sentence_transformers.json",
            "models/granite-embedding-311m-multilingual-r2/modules.json",
            "models/granite-embedding-311m-multilingual-r2/sentence_bert_config.json",
            "models/granite-embedding-311m-multilingual-r2/special_tokens_map.json",
            "models/granite-embedding-311m-multilingual-r2/tokenizer.json",
            "models/granite-embedding-311m-multilingual-r2/tokenizer_config.json",
        ] {
            let url = fixture.bundle.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data("synthetic Granite fixture".utf8)
            try data.write(to: url)
            let mode: UInt16 = name.hasPrefix("bin/") ? 0o755 : 0o644
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
            files.append(
                .init(
                    path: name, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    size: UInt64(data.count), mode: mode))
        }
        try JSONEncoder().encode(
            BundleManifest(
                version: "0.1.0-preview.2", platform: original.platform, arch: original.arch, files: files,
                embedding: .granite)
        ).write(to: manifestURL)
    }

    private func legacySemanticConfiguration(_ installer: SetupEngine, _ receipt: InstallationReceipt) throws
        -> BundledSemanticConfiguration
    {
        installer.legacyConfiguration(for: receipt)
    }

    private func recordLegacyEmbeddingRegistration(
        _ installer: SetupEngine, _ receipt: inout InstallationReceipt
    ) throws {
        let data = Data("legacy embedding registration".utf8)
        let url = installer.embeddingDefinitionURL(receipt.instance)
        try data.write(to: url)
        receipt.embeddingDefinitionSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }

    func testManifestRejectsUnsafeNamesModesMissingAndUnexpectedFiles() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let engine = engine(f)
        let manifest = try engine.verifyBundle(at: f.bundle)
        for path in ["../outside", "/absolute", "bin//tractanda", "bin/./tractanda", "bin/tractanda/"] {
            XCTAssertThrowsError(try BundleManifest.validateRelativePath(path))
        }
        let extra = f.bundle.appendingPathComponent("unlisted.txt")
        try Data("unlisted".utf8).write(to: extra)
        XCTAssertThrowsError(try engine.verifyBundle(at: f.bundle))
        try FileManager.default.removeItem(at: extra)
        let executable = f.bundle.appendingPathComponent("bin/tractanda")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: executable.path)
        XCTAssertThrowsError(try engine.verifyBundle(at: f.bundle))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(
            at: executable, withDestinationURL: f.bundle.appendingPathComponent("bin/tractanda-tui"))
        XCTAssertThrowsError(try engine.verifyBundle(at: f.bundle))
        XCTAssertEqual(manifest.platform, "macos")
    }

    func testPlanNeedsNoRootAndSeparatesCanonicalDataFromIndexes() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let engine = SetupEngine(roots: f.roots, rootCheck: { false }, trustedOwnership: false)
        let plan = try engine.plan(f.options)
        XCTAssertEqual(plan.store, f.roots.data.appendingPathComponent("preview").path)
        XCTAssertEqual(plan.indexDirectory, f.roots.indexes.appendingPathComponent("preview").path)
        XCTAssertTrue(plan.actions.contains { $0.contains("create no accounts") })
        XCTAssertThrowsError(try engine.install(f.options))
    }

    func testInstallUpgradeRollbackAndUninstallUseOwnedReceiptsAndCreateNoAccount() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runner = Runner()
        let engine = engine(f, runner: Runner())
        let installer = self.engine(f, runner: runner)
        try installer.install(f.options)
        let definition = f.roots.launchDefinitions.appendingPathComponent("ai.tractanda.server.preview.plist")
        let original = try Data(contentsOf: definition)
        let plist = try PropertyListSerialization.propertyList(from: original, format: nil) as! [String: Any]
        XCTAssertEqual(plist["UserName"] as? String, "daemon")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        let marker = f.roots.data.appendingPathComponent("preview/retain-me")
        try Data("user data".utf8).write(to: marker)
        runner.failNextBootstrap = true
        XCTAssertThrowsError(try installer.install(f.options, upgrade: true))
        XCTAssertEqual(try Data(contentsOf: definition), original)
        XCTAssertTrue(runner.loaded)
        // Control and uninstall use installed receipts even after the downloaded bundle is gone.
        try FileManager.default.removeItem(at: f.bundle)
        try installer.restart(f.options)
        try installer.uninstall(f.options)
        XCTAssertFalse(runner.loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: definition.path))
        XCTAssertEqual(try Data(contentsOf: marker), Data("user data".utf8))
        XCTAssertFalse(
            runner.calls.contains {
                $0.0.contains("dscl") || $0.0.contains("useradd") || $0.0.contains("chown")
            })
        XCTAssertTrue(
            runner.calls.contains {
                $0.0 == "/usr/bin/sudo" && $0.1.contains("daemon") && $0.1.contains("--bootstrap-store")
            })
    }

    func testUnmanagedExistingDataAndChangedDefinitionsAreNotAdoptedOrRemoved() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let installer = engine(f)
        let store = f.roots.data.appendingPathComponent("preview")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        XCTAssertThrowsError(try installer.install(f.options))
        try FileManager.default.removeItem(at: store)
        try installer.install(f.options)
        let definition = f.roots.launchDefinitions.appendingPathComponent("ai.tractanda.server.preview.plist")
        try Data("changed outside installer".utf8).write(to: definition)
        XCTAssertThrowsError(try installer.uninstall(f.options))
        XCTAssertEqual(try String(contentsOf: definition, encoding: .utf8), "changed outside installer")
    }

    func testStoreBootstrapIsRealRepeatableAndRejectsDifferentPolicy() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let store = f.root.appendingPathComponent("real-store")
        let index = f.root.appendingPathComponent("real-index")
        try StoreBootstrap.initialize(store: store, indexDirectory: index, owner: f.owner, instance: "test")
        let records = try FileManager.default.subpathsOfDirectory(atPath: store.path).filter {
            $0.hasSuffix(".tractanda")
        }
        XCTAssertEqual(records.count, 1)
        let bytes = try Data(contentsOf: store.appendingPathComponent(records[0]))
        try StoreBootstrap.initialize(store: store, indexDirectory: index, owner: f.owner, instance: "test")
        XCTAssertEqual(try Data(contentsOf: store.appendingPathComponent(records[0])), bytes)
        XCTAssertThrowsError(
            try StoreBootstrap.initialize(
                store: store, indexDirectory: index, owner: "root", instance: "test"))
        XCTAssertEqual(try Data(contentsOf: store.appendingPathComponent(records[0])), bytes)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: index.appendingPathComponent("items.sqlite").path))
    }

    func testUpgradeUsesRecordedStorageWithoutCreatingNewDefaultDirectories() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runner = Runner()
        try engine(f, runner: runner).install(f.options)
        let alternate = SetupRoots(
            platform: .macos, software: f.roots.software, configuration: f.roots.configuration,
            launchDefinitions: f.roots.launchDefinitions, runtime: f.roots.runtime,
            data: f.root.appendingPathComponent("unused-data"),
            indexes: f.root.appendingPathComponent("unused-index"), commands: f.roots.commands)
        let installer = SetupEngine(
            roots: alternate, runner: runner, rootCheck: { true }, trustedOwnership: false,
            readinessCheck: { _, _, _ in })
        try installer.install(f.options, upgrade: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.data.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.indexes.path))
        XCTAssertEqual(
            try installer.readReceipt("preview")?.store, f.roots.data.appendingPathComponent("preview").path)
    }

    func testFailureAfterEmbeddingStartupRollsBackBothJobs() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try addGranitePayload(to: f)
        let runner = Runner()
        let installer = SetupEngine(
            roots: f.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            readinessCheck: { _, _, _ in throw SetupError("Injected readiness failure") })
        XCTAssertThrowsError(try installer.install(f.options))
        XCTAssertTrue(runner.jobs.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: f.roots.launchDefinitions.appendingPathComponent("ai.tractanda.server.preview.plist")
                    .path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: f.roots.launchDefinitions.appendingPathComponent(
                    "ai.tractanda.embeddings.preview.plist"
                ).path))
        XCTAssertTrue(
            runner.calls.contains {
                $0.1.contains(where: { $0.contains("ai.tractanda.embeddings.preview.plist") })
            })
        XCTAssertEqual(try installer.readReceipt("preview")?.state, .preparing)
    }

    func testManagedQwenConfigurationUpgradesToGraniteAndIsIdempotent() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runner = Runner()
        let initial = engine(f, runner: runner)
        try initial.install(f.options)
        var receipt = try XCTUnwrap(initial.readReceipt("preview"))
        receipt.embedding = .legacyQwen
        receipt.embeddingConfigured = true
        try recordLegacyEmbeddingRegistration(initial, &receipt)
        try initial.writeReceipt(receipt)
        var semantic = try legacySemanticConfiguration(initial, receipt)
        semantic.operationID = "pilot-semantic-cutover"
        try JSONEncoder().encode(semantic).write(
            to: URL(fileURLWithPath: receipt.store).appendingPathComponent("semantic.json"))
        try addGranitePayload(to: f)
        var configureCalls = 0
        let installer = SetupEngine(
            roots: f.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            readinessCheck: { _, _, _ in },
            semanticCall: { _, _, method, arguments in
                guard runner.jobs.contains("system/ai.tractanda.server.preview") else {
                    throw SetupError("Native server is not running.")
                }
                if method == "TractandaSemantic/status" {
                    return [
                        "enabled": true, "configurationID": semantic.configurationID, "model": semantic.model,
                    ]
                }
                configureCalls += 1
                let data = try JSONSerialization.data(
                    withJSONObject: try XCTUnwrap(arguments["configuration"]))
                let candidate = try JSONDecoder().decode(BundledSemanticConfiguration.self, from: data)
                if semantic.operationID == candidate.operationID, semantic == candidate {
                    return ["enabled": true, "configurationID": semantic.configurationID]
                }
                XCTAssertEqual(arguments["expectedConfigurationID"] as? String, semantic.configurationID)
                semantic = candidate
                return ["enabled": true, "configurationID": semantic.configurationID]
            })
        try installer.install(f.options, upgrade: true)
        let upgraded = try XCTUnwrap(installer.readReceipt("preview"))
        XCTAssertEqual(upgraded.embedding, .granite)
        XCTAssertTrue(upgraded.embeddingConfigured)
        XCTAssertNil(upgraded.embeddingPreviousConfiguration)
        XCTAssertEqual(semantic, installer.graniteConfiguration(for: upgraded, payload: .granite))
        let callsAfterUpgrade = configureCalls
        try installer.install(f.options, upgrade: true)
        XCTAssertEqual(configureCalls, callsAfterUpgrade)
    }

    func testGraniteUpgradeRefusesChangedSemanticConfiguration() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runner = Runner()
        let installer = engine(f, runner: runner)
        try installer.install(f.options)
        var receipt = try XCTUnwrap(installer.readReceipt("preview"))
        receipt.embedding = .legacyQwen
        receipt.embeddingConfigured = true
        try recordLegacyEmbeddingRegistration(installer, &receipt)
        try installer.writeReceipt(receipt)
        var changed = try legacySemanticConfiguration(installer, receipt)
        changed.queryPrefix = "administrator-selected-prefix"
        try JSONEncoder().encode(changed).write(
            to: URL(fileURLWithPath: receipt.store).appendingPathComponent("semantic.json"))
        try addGranitePayload(to: f)
        XCTAssertThrowsError(try installer.install(f.options, upgrade: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("different semantic configuration"))
        }
        XCTAssertEqual(try installer.readReceipt("preview")?.embedding, .legacyQwen)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: receipt.store).appendingPathComponent("semantic.json")),
            try JSONEncoder().encode(changed))
    }

    func testPostConfigurationFailureRestoresManagedQwenConfiguration() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runner = Runner()
        let initial = engine(f, runner: runner)
        try initial.install(f.options)
        var receipt = try XCTUnwrap(initial.readReceipt("preview"))
        receipt.embedding = .legacyQwen
        receipt.embeddingConfigured = true
        try recordLegacyEmbeddingRegistration(initial, &receipt)
        try initial.writeReceipt(receipt)
        var semantic = try legacySemanticConfiguration(initial, receipt)
        let semanticURL = URL(fileURLWithPath: receipt.store).appendingPathComponent("semantic.json")
        try JSONEncoder().encode(semantic).write(to: semanticURL)
        try addGranitePayload(to: f)
        let installer = SetupEngine(
            roots: f.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            readinessCheck: { _, _, _ in },
            semanticCall: { _, _, method, arguments in
                guard runner.jobs.contains("system/ai.tractanda.server.preview") else {
                    throw SetupError("Native server is not running.")
                }
                if method == "TractandaSemantic/status" {
                    return [
                        "enabled": true, "configurationID": semantic.configurationID, "model": semantic.model,
                    ]
                }
                let data = try JSONSerialization.data(
                    withJSONObject: try XCTUnwrap(arguments["configuration"]))
                let candidate = try JSONDecoder().decode(BundledSemanticConfiguration.self, from: data)
                XCTAssertEqual(arguments["expectedConfigurationID"] as? String, semantic.configurationID)
                semantic = candidate
                try JSONEncoder().encode(semantic).write(to: semanticURL)
                return ["enabled": true, "configurationID": semantic.configurationID]
            })
        let badProfiles: [String: Any] = [
            "version": 1, "profiles": ["preview": ["socketPath": "changed", "serverUser": "daemon"]],
        ]
        try JSONSerialization.data(withJSONObject: badProfiles).write(
            to: f.roots.configuration.appendingPathComponent("connections.json"))
        XCTAssertThrowsError(try installer.install(f.options, upgrade: true))
        XCTAssertEqual(semantic, try legacySemanticConfiguration(initial, receipt))
        XCTAssertEqual(try installer.readReceipt("preview")?.embedding, .legacyQwen)
        XCTAssertTrue(runner.jobs.contains("system/ai.tractanda.server.preview"))
    }

    func testFailedSemanticRollbackLeavesServicesStopped() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runner = Runner()
        let initial = engine(f, runner: runner)
        try initial.install(f.options)
        var receipt = try XCTUnwrap(initial.readReceipt("preview"))
        receipt.embedding = .legacyQwen
        receipt.embeddingConfigured = true
        try recordLegacyEmbeddingRegistration(initial, &receipt)
        try initial.writeReceipt(receipt)
        var semantic = try legacySemanticConfiguration(initial, receipt)
        let semanticURL = URL(fileURLWithPath: receipt.store).appendingPathComponent("semantic.json")
        try JSONEncoder().encode(semantic).write(to: semanticURL)
        try addGranitePayload(to: f)
        var configureCalls = 0
        let installer = SetupEngine(
            roots: f.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            readinessCheck: { _, _, _ in },
            semanticCall: { _, _, method, arguments in
                guard runner.jobs.contains("system/ai.tractanda.server.preview") else {
                    throw SetupError("Native server is not running.")
                }
                if method == "TractandaSemantic/status" {
                    return [
                        "enabled": true, "configurationID": semantic.configurationID, "model": semantic.model,
                    ]
                }
                configureCalls += 1
                if configureCalls > 1 { throw SetupError("Injected semantic rollback failure") }
                let data = try JSONSerialization.data(
                    withJSONObject: try XCTUnwrap(arguments["configuration"]))
                semantic = try JSONDecoder().decode(BundledSemanticConfiguration.self, from: data)
                try JSONEncoder().encode(semantic).write(to: semanticURL)
                return ["enabled": true, "configurationID": semantic.configurationID]
            })
        let badProfiles: [String: Any] = [
            "version": 1, "profiles": ["preview": ["socketPath": "changed", "serverUser": "daemon"]],
        ]
        try JSONSerialization.data(withJSONObject: badProfiles).write(
            to: f.roots.configuration.appendingPathComponent("connections.json"))
        XCTAssertThrowsError(try installer.install(f.options, upgrade: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("semantic configuration rollback also failed"))
        }
        XCTAssertTrue(runner.jobs.isEmpty)
        let stalled = try XCTUnwrap(installer.readReceipt("preview"))
        XCTAssertEqual(stalled.state, .preparing)
        XCTAssertEqual(stalled.embedding, .granite)
        XCTAssertFalse(stalled.embeddingConfigured)
        XCTAssertNotNil(stalled.embeddingPreviousConfiguration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.definitionURL("preview").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: installer.embeddingDefinitionURL("preview").path))
        XCTAssertThrowsError(try installer.start(f.options))
        semantic.configurationID = "administrator-selected"
        semantic.operationID = "administrator-selected"
        try JSONEncoder().encode(semantic).write(to: semanticURL)
        XCTAssertThrowsError(try installer.install(f.options, upgrade: true))
        XCTAssertEqual(semantic.configurationID, "administrator-selected")
    }

    func testProcessRunnerDrainsBeyondPipeCapacityAndReapsTimeout() throws {
        let runner = FoundationProcessRunner(timeout: 5, maximumOutputBytes: 512 * 1024)
        let output = try runner.run(
            "/bin/sh", ["-c", "/usr/bin/yes x | /usr/bin/head -c 262144"], environment: [:])
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.output.utf8.count, 262144)
        let start = Date()
        XCTAssertThrowsError(
            try FoundationProcessRunner(timeout: 0.05).run("/bin/sleep", ["5"], environment: [:]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testTwoStoresShareClientsAndReleaseUntilLastUninstall() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let installer = engine(f)
        let second = SetupOptions(name: "second", owner: f.owner, port: 48_730, bundle: f.bundle)
        try installer.install(f.options)
        let release = try XCTUnwrap(installer.readReceipt("preview")).release
        try installer.install(second)
        XCTAssertEqual(try installer.readReceipt("second")?.release, release)
        XCTAssertEqual(try installer.currentClientRelease(), release)
        XCTAssertEqual(installer.clientLink, f.roots.software.appendingPathComponent("current"))
        XCTAssertTrue(installer.ownsTUICommand())
        try installer.uninstall(f.options)
        XCTAssertTrue(FileManager.default.fileExists(atPath: release))
        XCTAssertEqual(try installer.currentClientRelease(), release)
        XCTAssertTrue(installer.ownsTUICommand())
        try installer.uninstall(second)
        XCTAssertFalse(installer.exists(installer.clientLink))
        XCTAssertFalse(installer.exists(installer.tuiCommand))
        XCTAssertFalse(FileManager.default.fileExists(atPath: release))
    }

    func testSharedClientRetargetAndFailedUpgradePreserveOtherStore() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runner = Runner()
        let installer = engine(f, runner: runner)
        try installer.install(f.options)
        let firstRelease = try XCTUnwrap(installer.readReceipt("preview")).release
        let manifestURL = f.bundle.appendingPathComponent("bundle-manifest.json")
        let manifest = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: manifestURL))
        try JSONEncoder().encode(
            BundleManifest(
                version: "0.1.0-preview.2", platform: manifest.platform,
                arch: manifest.arch, files: manifest.files)
        ).write(to: manifestURL)
        let second = SetupOptions(name: "second", owner: f.owner, port: 48_730, bundle: f.bundle)
        try installer.install(second)
        let secondRelease = try XCTUnwrap(installer.readReceipt("second")).release
        XCTAssertNotEqual(firstRelease, secondRelease)
        runner.failNextBootstrap = true
        XCTAssertThrowsError(try installer.install(f.options, upgrade: true))
        XCTAssertEqual(try installer.currentClientRelease(), secondRelease)
        XCTAssertEqual(try installer.readReceipt("preview")?.release, firstRelease)
        try installer.uninstall(second)
        XCTAssertEqual(try installer.currentClientRelease(), firstRelease)
        XCTAssertTrue(installer.ownsTUICommand())
        try installer.uninstall(f.options)
        XCTAssertFalse(installer.exists(installer.clientLink))
        XCTAssertFalse(installer.exists(installer.tuiCommand))
    }

    func testUnrelatedCommandIsPreservedAndLongSocketRejectedBeforeInstall() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let installer = engine(f)
        try FileManager.default.createDirectory(at: f.roots.commands, withIntermediateDirectories: true)
        try Data("unrelated command".utf8).write(to: installer.tuiCommand)
        try installer.install(f.options)
        try installer.uninstall(f.options)
        XCTAssertEqual(try Data(contentsOf: installer.tuiCommand), Data("unrelated command".utf8))
        let mac = SetupEngine(rootCheck: { false })
        XCTAssertThrowsError(
            try mac.plan(SetupOptions(name: String(repeating: "x", count: 48), bundle: f.bundle)))
        let normal = try mac.plan(SetupOptions(bundle: f.bundle))
        XCTAssertTrue(
            normal.executable.hasPrefix("/Users/Shared/Library/Application Support/Tractanda/releases/"))
    }
}
