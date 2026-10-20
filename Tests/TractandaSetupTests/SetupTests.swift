import CTractandaPlatform
import Crypto
import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaSetup

final class SetupTests: XCTestCase {
    final class Runner: SetupProcessRunning, @unchecked Sendable {
        var calls: [(String, [String])] = []
        var jobs = Set<String>()
        var loaded: Bool { !jobs.isEmpty }
        var failNextBootstrap = false
        var beforeRun: ((String, [String]) throws -> Void)?
        func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws
            -> ProcessResult
        {
            calls.append((executable, arguments))
            try beforeRun?(executable, arguments)
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
            if let bootstrap = arguments.firstIndex(of: "--bootstrap-store") {
                // Real tiny canonical root; privileged process/service calls remain mocked.
                do {
                    try StoreBootstrap.initialize(
                        store: URL(fileURLWithPath: arguments[bootstrap + 1]),
                        indexDirectory: URL(fileURLWithPath: arguments[bootstrap + 2]),
                        owner: arguments[bootstrap + 3], instance: arguments[bootstrap + 4])
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
    private var guardedRoot: URL?
    private var fixtureNumber = 0
    override func tearDownWithError() throws {
        if let guardedRoot {
            defer { try? FileManager.default.removeItem(at: guardedRoot) }
            var total: UInt64 = 0
            let scan = try XCTUnwrap(
                FileManager.default.enumerator(at: guardedRoot, includingPropertiesForKeys: nil))
            while let url = scan.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { total += UInt64(values.fileSize ?? 0) }
            }
            XCTAssertLessThanOrEqual(total, 16 * 1024 * 1024)
        }
        try super.tearDownWithError()
    }
    private func fixture() throws -> Fixture {
        #if !os(macOS)
            throw XCTSkip("Managed macOS installation tests; Linux installer remains in development.")
        #endif
        if guardedRoot == nil {
            guardedRoot = try GuardedFixtureDirectory.create(
                prefix: "u", source: "SetupTests", test: name
            ).resolvingSymlinksInPath()
        }
        let root = try XCTUnwrap(guardedRoot).appendingPathComponent("c" + String(fixtureNumber))
        fixtureNumber += 1
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
        let owner = try SystemAccountDirectory().user(forUID: tractanda_uid()).name
        return Fixture(root: root, roots: roots, bundle: bundle, owner: owner)
    }
    private func engine(_ fixture: Fixture, runner: Runner = Runner()) -> SetupEngine {
        SetupEngine(
            roots: fixture.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            peerStatusCall: { _, _ in try .init(state: .disabled, synchronization: .init(state: .disabled)) },
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
                embedding: .granite, canonicalFormats: original.canonicalFormats)
        ).write(to: manifestURL)
    }

    private func legacySemanticConfiguration(_ installer: SetupEngine, _ receipt: InstallationReceipt) throws
        -> BundledSemanticConfiguration
    {
        installer.legacyConfiguration(for: receipt)
    }

    private func poc11GranitePayload() -> EmbeddingPayload {
        EmbeddingPayload(
            backend: "vmlx-granite-embedding-f32-v1",
            modelDirectory: "models/granite-embedding-311m-multilingual-r2",
            model: "tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559",
            modelRevision:
                "44399559930365213510b1ee2eb15ded83374f0e:weights-bf16:compute-f32:dcb6431bfa6e817fe100a2b0521360cec3383963b03fa966b685de18ca310d31:vmlx-b7a2b97efc2d8ed44ddf3c4b7af25766b372339f",
            dimensions: 768)
    }

    private func poc11GraniteConfiguration(_ receipt: InstallationReceipt, payload: EmbeddingPayload)
        -> BundledSemanticConfiguration
    {
        BundledSemanticConfiguration(
            formatVersion: 2, configurationID: receipt.embeddingConfigurationID,
            operationID: "setup-embedding-v2-" + receipt.instance,
            endpoint: "http://127.0.0.1:\(receipt.port + 1)/v1/embeddings",
            model: payload.model, modelRevision: payload.modelRevision, dimensions: payload.dimensions,
            documentPrefix: "", queryPrefix: "", chunkBytes: 384, overlapBytes: 64,
            pooling: "cls", normalization: "l2", inputEncoding: "item-text-utf8-v2")
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
        try rewriteCanonicalSupport(f, support: .current)
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
        try rewriteCanonicalSupport(f, support: .current)
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

    private struct HandoffAccounts: AccountDirectory {
        let ownerUID: UInt32 = 51001
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == tractanda_uid() {
                return .init(uid: uid, name: "daemon", primaryGroupName: "service", groupIDs: [71002])
            }
            if uid == ownerUID {
                return .init(uid: uid, name: "human", primaryGroupName: "staff", groupIDs: [71001])
            }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
        }
        func user(named name: String) throws -> AccountIdentity {
            if name == "daemon" { return try user(forUID: tractanda_uid()) }
            if name == "human" { return try user(forUID: ownerUID) }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
        }
        func groupID(named name: String) throws -> UInt32 {
            if ["admin", "sudo", "staff"].contains(name) { return 71001 }
            if name == "service" { return 71002 }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
        }
    }
    func testStoreBootstrapUsesServiceIdentityAndHandsAdministrationToSelectedHuman() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let root = f.root.appendingPathComponent("handoff")
        let index = f.root.appendingPathComponent("handoff-index")
        let accounts = HandoffAccounts()
        for _ in 0..<2 {
            try StoreBootstrap.initialize(
                store: root, indexDirectory: index, owner: "human", instance: "handoff",
                accounts: accounts)
        }
        let store = try ItemStore.openInitialized(root: root, indexDirectory: index, accounts: accounts)
        XCTAssertThrowsError(
            try store.withAccess(forUID: tractanda_uid()) { try store.requireAdministrator() })
        try store.withAccess(forUID: accounts.ownerUID) { try store.requireAdministrator() }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".tractanda-first-source-complete.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".tractanda-replica-identity.json").path))
    }
    func testStoreBootstrapRejectsLegacyRootAndChangedInitializationKey() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let legacy = f.root.appendingPathComponent("legacy")
        let index = f.root.appendingPathComponent("legacy-index")
        do { _ = try ItemStore(root: legacy, indexDirectory: index) }
        XCTAssertThrowsError(
            try StoreBootstrap.initialize(
                store: legacy, indexDirectory: index,
                owner: f.owner, instance: "legacy"))
        let root = f.root.appendingPathComponent("fresh")
        let freshIndex = f.root.appendingPathComponent("fresh-index")
        try StoreBootstrap.initialize(
            store: root, indexDirectory: freshIndex, owner: f.owner, instance: "original")
        XCTAssertThrowsError(
            try StoreBootstrap.initialize(
                store: root, indexDirectory: freshIndex,
                owner: f.owner, instance: "different"))
    }

    func testUpgradeUsesRecordedStorageWithoutCreatingNewDefaultDirectories() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        try engine(f, runner: runner).install(f.options)
        let alternate = SetupRoots(
            platform: .macos, software: f.roots.software, configuration: f.roots.configuration,
            launchDefinitions: f.roots.launchDefinitions, runtime: f.roots.runtime,
            data: f.root.appendingPathComponent("unused-data"),
            indexes: f.root.appendingPathComponent("unused-index"), commands: f.roots.commands)
        let installer = SetupEngine(
            roots: alternate, runner: runner, rootCheck: { true }, trustedOwnership: false,
            peerStatusCall: { _, _ in try .init(state: .disabled, synchronization: .init(state: .disabled)) },
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
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let installer = SetupEngine(
            roots: f.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            peerStatusCall: { _, _ in try .init(state: .disabled, synchronization: .init(state: .disabled)) },
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

    func testManagedPoc11GraniteConfigurationUpgradesAndRetriesIdempotently() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let initial = engine(f, runner: runner)
        let options = SetupOptions(name: "production", owner: f.owner, bundle: f.bundle)
        try initial.install(options)
        var receipt = try XCTUnwrap(initial.readReceipt("production"))
        let poc11Payload = poc11GranitePayload()
        receipt.embedding = poc11Payload
        receipt.embeddingConfigured = true
        try recordLegacyEmbeddingRegistration(initial, &receipt)
        try initial.writeReceipt(receipt)
        var semantic = poc11GraniteConfiguration(receipt, payload: poc11Payload)
        let oldSemantic = semantic
        let semanticURL = URL(fileURLWithPath: receipt.store).appendingPathComponent("semantic.json")
        try JSONEncoder().encode(semantic).write(to: semanticURL)
        try addGranitePayload(to: f)
        var configureCalls = 0
        let installer = SetupEngine(
            roots: f.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            peerStatusCall: { _, _ in try .init(state: .disabled, synchronization: .init(state: .disabled)) },
            readinessCheck: { _, _, _ in },
            semanticCall: { _, _, method, arguments in
                guard runner.jobs.contains("system/ai.tractanda.server.production") else {
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
                if semantic == candidate {
                    return ["enabled": true, "configurationID": semantic.configurationID]
                }
                if semantic.operationID == candidate.operationID {
                    throw SetupError("operationMismatch")
                }
                XCTAssertEqual(arguments["expectedConfigurationID"] as? String, semantic.configurationID)
                semantic = candidate
                try JSONEncoder().encode(semantic).write(to: semanticURL)
                return ["enabled": true, "configurationID": semantic.configurationID]
            })
        try installer.install(options, upgrade: true)
        let upgraded = try XCTUnwrap(installer.readReceipt("production"))
        XCTAssertEqual(upgraded.embedding, .granite)
        XCTAssertTrue(upgraded.embeddingConfigured)
        XCTAssertNil(upgraded.embeddingPreviousConfiguration)
        XCTAssertEqual(semantic, installer.graniteConfiguration(for: upgraded, payload: .granite))
        XCTAssertNotEqual(semantic.operationID, oldSemantic.operationID)
        XCTAssertTrue(semantic.operationID.hasSuffix(upgraded.embeddingConfigurationID))
        let callsAfterUpgrade = configureCalls
        var retry = upgraded
        retry.state = .preparing
        retry.embeddingConfigured = false
        retry.embeddingPreviousConfiguration = oldSemantic
        try installer.writeReceipt(retry)
        try installer.install(options, upgrade: true)
        XCTAssertEqual(configureCalls, callsAfterUpgrade)
        XCTAssertEqual(try installer.readReceipt("production")?.state, .active)
        XCTAssertTrue(try XCTUnwrap(installer.readReceipt("production")).embeddingConfigured)
        XCTAssertNil(try XCTUnwrap(installer.readReceipt("production")).embeddingPreviousConfiguration)
        try installer.install(options, upgrade: true)
        XCTAssertEqual(configureCalls, callsAfterUpgrade)
    }

    func testGraniteRuntimeUpgradeRefusesChangedSemanticConfiguration() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let installer = engine(f, runner: runner)
        try installer.install(f.options)
        var receipt = try XCTUnwrap(installer.readReceipt("preview"))
        let poc11Payload = poc11GranitePayload()
        receipt.embedding = poc11Payload
        receipt.embeddingConfigured = true
        try recordLegacyEmbeddingRegistration(installer, &receipt)
        try installer.writeReceipt(receipt)
        var changed = poc11GraniteConfiguration(receipt, payload: poc11Payload)
        changed.queryPrefix = "administrator-selected-prefix"
        let semanticURL = URL(fileURLWithPath: receipt.store).appendingPathComponent("semantic.json")
        let changedBytes = try JSONEncoder().encode(changed)
        try changedBytes.write(to: semanticURL)
        try addGranitePayload(to: f)
        XCTAssertThrowsError(try installer.install(f.options, upgrade: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("different semantic configuration"))
        }
        XCTAssertEqual(try installer.readReceipt("preview")?.embedding, poc11Payload)
        XCTAssertEqual(try Data(contentsOf: semanticURL), changedBytes)
    }

    func testPostConfigurationFailureRestoresManagedPoc11GraniteConfiguration() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let initial = engine(f, runner: runner)
        try initial.install(f.options)
        var receipt = try XCTUnwrap(initial.readReceipt("preview"))
        let poc11Payload = poc11GranitePayload()
        receipt.embedding = poc11Payload
        receipt.embeddingConfigured = true
        try recordLegacyEmbeddingRegistration(initial, &receipt)
        try initial.writeReceipt(receipt)
        var semantic = poc11GraniteConfiguration(receipt, payload: poc11Payload)
        let semanticURL = URL(fileURLWithPath: receipt.store).appendingPathComponent("semantic.json")
        try JSONEncoder().encode(semantic).write(to: semanticURL)
        try addGranitePayload(to: f)
        let installer = SetupEngine(
            roots: f.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            peerStatusCall: { _, _ in try .init(state: .disabled, synchronization: .init(state: .disabled)) },
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
        XCTAssertEqual(semantic, poc11GraniteConfiguration(receipt, payload: poc11Payload))
        XCTAssertEqual(try installer.readReceipt("preview")?.embedding, poc11Payload)
        XCTAssertTrue(runner.jobs.contains("system/ai.tractanda.server.preview"))
    }

    func testFailedSemanticRollbackLeavesServicesStopped() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
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
        try rewriteCanonicalSupport(f, support: .current)
        var configureCalls = 0
        let installer = SetupEngine(
            roots: f.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            peerStatusCall: { _, _ in try .init(state: .disabled, synchronization: .init(state: .disabled)) },
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
        try rewriteCanonicalSupport(f, support: .current)
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
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let installer = engine(f, runner: runner)
        try installer.install(f.options)
        let firstRelease = try XCTUnwrap(installer.readReceipt("preview")).release
        let manifestURL = f.bundle.appendingPathComponent("bundle-manifest.json")
        let manifest = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: manifestURL))
        try JSONEncoder().encode(
            BundleManifest(
                version: "0.1.0-preview.2", platform: manifest.platform,
                arch: manifest.arch, files: manifest.files, canonicalFormats: manifest.canonicalFormats)
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
        try rewriteCanonicalSupport(f, support: .current)
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
    private func rewriteCanonicalSupport(_ fixture: Fixture, support: CanonicalFormatSupport) throws {
        let path = fixture.bundle.appendingPathComponent("bundle-manifest.json")
        let original = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: path))
        let updated = BundleManifest(
            version: original.version + "-reader2", platform: original.platform,
            arch: original.arch, files: original.files, embedding: original.embedding,
            documentExtraction: original.documentExtraction, canonicalFormats: support)
        try JSONEncoder().encode(updated).write(to: path)
    }
    private func publishFormat2Fixture(_ receipt: InstallationReceipt) throws -> (URL, Data) {
        let store = try ItemStore.openInitialized(
            root: URL(fileURLWithPath: receipt.store),
            indexDirectory: URL(fileURLWithPath: receipt.indexDirectory))
        let revision = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("newer canonical content")],
                operationID: "reader-floor2")
        ).revision
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: URL(fileURLWithPath: receipt.store).appendingPathComponent("items"),
                includingPropertiesForKeys: nil))
        let path = try XCTUnwrap(
            enumerator.allObjects.compactMap { $0 as? URL }.first(where: {
                $0.lastPathComponent == revision.revisionID + ".tractanda"
            }))
        return (path, try Data(contentsOf: path))
    }
    private func capturedSupport(_ requirement: CanonicalReaderRequirement) -> CanonicalFormatSupport {
        CanonicalFormatSupport(
            readerLevel: requirement.minimumReaderLevel, writerLevel: requirement.minimumReaderLevel,
            read: requirement.recordFormats, write: requirement.recordFormats,
            capabilities: requirement.capabilities, writeCapabilities: requirement.capabilities)
    }

    func testFailedCandidateCannotReloadPriorReaderAfterDurableRequirementAdvance() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let initial = engine(f, runner: runner)
        try initial.install(f.options)
        let fresh = try XCTUnwrap(initial.readReceipt("preview"))
        let root = URL(fileURLWithPath: fresh.store).resolvingSymlinksInPath()
        let before = try XCTUnwrap(CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
        XCTAssertLessThan(before.minimumReaderLevel, 12)
        let previousSupport = capturedSupport(before)
        XCTAssertNoThrow(try previousSupport.require(before))
        try rewriteCanonicalSupport(f, support: previousSupport)
        try initial.install(f.options, upgrade: true)
        let previous = try XCTUnwrap(initial.readReceipt("preview"))
        let canonical = try publishFormat2Fixture(previous)
        try rewriteCanonicalSupport(f, support: .current)
        var raised: CanonicalReaderRequirement?
        let candidate = SetupEngine(
            roots: f.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            peerStatusCall: { _, _ in try .init(state: .disabled, synchronization: .init(state: .disabled)) },
            readinessCheck: { _, _, _ in
                try CanonicalReaderRequirement.withWriterLock(root: root, ownerUID: tractanda_uid()) {
                    try CanonicalReaderRequirement.beforeEnrollmentApprovalPublication(
                        root: root, ownerUID: tractanda_uid())
                }
                raised = try CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid())
                throw SetupError("candidate health failed after actual requirement advance")
            })
        XCTAssertThrowsError(try candidate.install(f.options, upgrade: true)) {
            XCTAssertTrue($0.localizedDescription.contains("canonical compatibility blocks rollback"))
        }
        XCTAssertTrue(runner.jobs.isEmpty)
        let stopped = try XCTUnwrap(candidate.readReceipt("preview"))
        XCTAssertEqual(stopped.state, .preparing)
        XCTAssertNotNil(stopped.recoveryReason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.definitionURL("preview").path))
        XCTAssertEqual(try Data(contentsOf: canonical.0), canonical.1)
        let persisted = try XCTUnwrap(CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
        XCTAssertEqual(persisted, raised)
        XCTAssertEqual(persisted.minimumReaderLevel, 12)
        XCTAssertEqual(persisted.storeID, before.storeID)
        XCTAssertThrowsError(try previousSupport.require(persisted)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "incompatibleCanonicalReader")
        }
        XCTAssertNoThrow(try CanonicalFormatSupport.current.require(persisted))
    }

    func testCapturedFloorPreviousReaderCanRollbackWithAndWithoutExtraFormat2Content() throws {
        for extraContent in [false, true] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            try rewriteCanonicalSupport(f, support: .current)
            let runner = Runner()
            let initial = engine(f, runner: runner)
            try initial.install(f.options)
            let fresh = try XCTUnwrap(initial.readReceipt("preview"))
            let root = URL(fileURLWithPath: fresh.store).resolvingSymlinksInPath()
            let before = try XCTUnwrap(CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
            let previousSupport = capturedSupport(before)
            try rewriteCanonicalSupport(f, support: previousSupport)
            try initial.install(f.options, upgrade: true)
            let previous = try XCTUnwrap(initial.readReceipt("preview"))
            let canonical = extraContent ? try publishFormat2Fixture(previous) : nil
            let admitted = try XCTUnwrap(
                CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
            XCTAssertNoThrow(try previousSupport.require(admitted))
            try rewriteCanonicalSupport(f, support: .current)
            let candidate = SetupEngine(
                roots: f.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
                peerStatusCall: { _, _ in
                    try .init(state: .disabled, synchronization: .init(state: .disabled))
                },
                readinessCheck: { _, _, _ in
                    throw SetupError("candidate health failed without requirement advance")
                })
            XCTAssertThrowsError(try candidate.install(f.options, upgrade: true))
            let restored = try XCTUnwrap(candidate.readReceipt("preview"))
            XCTAssertEqual(restored.state, .active)
            XCTAssertEqual(restored.release, previous.release)
            XCTAssertTrue(runner.jobs.contains("system/ai.tractanda.server.preview"))
            XCTAssertEqual(
                try CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()), admitted)
            if let canonical { XCTAssertEqual(try Data(contentsOf: canonical.0), canonical.1) }
        }
    }

    func testSharedClientRollbackChecksRegisteredWriterFutureLevelAndRuntimeDeclaration() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let installer = engine(f, runner: runner)
        try installer.install(f.options)
        let fresh = try XCTUnwrap(installer.readReceipt("preview"))
        let root = URL(fileURLWithPath: fresh.store).resolvingSymlinksInPath()
        let before = try XCTUnwrap(CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
        let previousSupport = capturedSupport(before)
        try rewriteCanonicalSupport(f, support: previousSupport)
        try installer.install(f.options, upgrade: true)
        let previous = try XCTUnwrap(installer.readReceipt("preview"))
        try rewriteCanonicalSupport(f, support: .current)
        try installer.install(f.options, upgrade: true)
        let current = try XCTUnwrap(installer.readReceipt("preview"))
        let marker = try XCTUnwrap(CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
        XCTAssertEqual(marker, before, "The mocked writer has published no new requirement")
        XCTAssertNoThrow(try previousSupport.require(marker))
        XCTAssertThrowsError(try previousSupport.requireWriter(.current))
        XCTAssertThrowsError(
            try installer.setClientRelease(previous.release),
            "Registered writer may raise the floor after this check")
        XCTAssertEqual(try installer.currentClientRelease(), current.release)
        XCTAssertThrowsError(try installer.verifyCanonicalReadiness(current, info: [:]))
        let matching = try JSONSerialization.jsonObject(with: JSON.encode(CanonicalFormatSupport.current))
        XCTAssertNoThrow(
            try installer.verifyCanonicalReadiness(current, info: ["canonicalFormats": matching]))
    }

}

extension SetupTests {
    private final class LoadedPeerStatus {
        var value = try! PeerOperatorRuntimeStatus(state: .disabled, synchronization: .init(state: .disabled))
    }
    private func peerInstaller(
        _ f: Fixture, runner: Runner, loaded: LoadedPeerStatus,
        readiness: @escaping () throws -> Void = {}
    ) -> SetupEngine {
        runner.beforeRun = { executable, arguments in
            guard executable == "/bin/launchctl", arguments.first == "bootstrap" else { return }
            let object = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: URL(fileURLWithPath: arguments[2])), format: nil)
            let plist = try XCTUnwrap(object as? [String: Any])
            let argv = try XCTUnwrap(plist["ProgramArguments"] as? [String])
            if let index = argv.firstIndex(of: "--peer-runtime-configuration") {
                let path = argv[index + 1]
                let config = try PeerRuntimeConfiguration.decode(Data(contentsOf: URL(fileURLWithPath: path)))
                loaded.value = try .init(
                    state: .active, configurationPath: path, settingsDigest: config.settingsDigest,
                    synchronizationEnabled: config.synchronization.enabled,
                    listenerConfigured: config.listen != nil,
                    synchronization: .init(state: config.synchronization.enabled ? .active : .disabled))
            } else {
                loaded.value = try .init(state: .disabled, synchronization: .init(state: .disabled))
            }
        }
        return SetupEngine(
            roots: f.roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
            peerStatusCall: { _, _ in loaded.value }, readinessCheck: { _, _, _ in try readiness() })
    }
    private func peerOptions(_ f: Fixture, _ action: SetupOptions.PeerRuntimeAction) -> SetupOptions {
        .init(name: "preview", owner: f.owner, bundle: f.bundle, peerRuntime: action)
    }
    private func peerInput(_ f: Fixture, listen: Bool = false) throws -> URL {
        let input = f.root.appendingPathComponent("operator-input.json")
        try PeerRuntimeConfiguration(listen: listen ? .init(host: "127.0.0.1", port: 48730) : nil).encoded()
            .write(to: input)
        return input
    }
    func testManagedPeerFreshDisabledReplacePreserveDisableAndOmittedUpgrade() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let loaded = LoadedPeerStatus()
        let installer = peerInstaller(f, runner: runner, loaded: loaded)
        try installer.install(f.options)
        let target = installer.peerConfigurationURL("preview")
        XCTAssertNil(try installer.readReceipt("preview")?.peerRuntimeConfiguration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let input = try peerInput(f)
        try installer.install(peerOptions(f, .replace(input)), upgrade: true)
        let configured = try XCTUnwrap(installer.readReceipt("preview"))
        XCTAssertNotNil(configured.peerRuntimeConfiguration)
        XCTAssertNil(configured.peerRuntimePrevious)
        XCTAssertEqual(
            loaded.value.state, .active,
            "Explicit no-listener/sync-off remains a configured on-demand runtime")
        let exact = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: input)
        try installer.install(f.options, upgrade: true)
        XCTAssertEqual(
            try installer.readReceipt("preview")?.peerRuntimeConfiguration,
            configured.peerRuntimeConfiguration)
        XCTAssertEqual(try Data(contentsOf: target), exact)
        let plist =
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: installer.definitionURL("preview")), format: nil) as? [String: Any]
        let argv = try XCTUnwrap(plist?["ProgramArguments"] as? [String])
        XCTAssertEqual(Array(argv.suffix(2)), ["--peer-runtime-configuration", target.path])
        XCTAssertFalse(argv.contains(input.path))
        try installer.install(peerOptions(f, .disable), upgrade: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNil(try installer.readReceipt("preview")?.peerRuntimePrevious)
        try installer.install(f.options, upgrade: true)
        XCTAssertNil(try installer.readReceipt("preview")?.peerRuntimeConfiguration)
        XCTAssertEqual(loaded.value.state, .disabled)
        XCTAssertFalse(
            runner.calls.contains {
                ["/usr/sbin/dscl", "/usr/sbin/sysadminctl", "/usr/sbin/useradd"].contains($0.0)
            })
    }
    func testManagedPeerFailureBeforeAndAfterPublicationRestoresExactConfiguration() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let loaded = LoadedPeerStatus()
        var failReadiness = false
        let installer = peerInstaller(f, runner: runner, loaded: loaded) {
            if failReadiness { throw SetupError("fixture readiness failure") }
        }
        let input = try peerInput(f)
        try installer.install(peerOptions(f, .replace(input)))
        let old = try XCTUnwrap(installer.readReceipt("preview"))
        let bytes = try Data(contentsOf: installer.peerConfigurationURL("preview"))
        let definition = try Data(contentsOf: installer.definitionURL("preview"))
        _ = try peerInput(f, listen: true)
        let originalHook = runner.beforeRun
        var failUnload = true
        runner.beforeRun = { executable, arguments in
            if executable == "/bin/launchctl", arguments.first == "bootout", failUnload {
                failUnload = false
                throw SetupError("fixture before publication")
            }
            try originalHook?(executable, arguments)
        }
        XCTAssertThrowsError(try installer.install(peerOptions(f, .replace(input)), upgrade: true))
        XCTAssertEqual(try Data(contentsOf: installer.peerConfigurationURL("preview")), bytes)
        XCTAssertEqual(
            try installer.readReceipt("preview")?.peerRuntimeConfiguration, old.peerRuntimeConfiguration)
        failReadiness = true
        XCTAssertThrowsError(try installer.install(peerOptions(f, .replace(input)), upgrade: true))
        XCTAssertEqual(try Data(contentsOf: installer.peerConfigurationURL("preview")), bytes)
        XCTAssertEqual(try Data(contentsOf: installer.definitionURL("preview")), definition)
        XCTAssertEqual(try installer.readReceipt("preview")?.state, .active)
        XCTAssertNil(try installer.readReceipt("preview")?.peerRuntimePrevious)
        XCTAssertTrue(runner.loaded)
    }
    func testManagedPeerLoadedThenDiskDriftCannotCommitOrAutostartAndStopIgnoresDrift() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let loaded = LoadedPeerStatus()
        var drift = false
        var installer: SetupEngine!
        installer = peerInstaller(f, runner: runner, loaded: loaded) {
            if drift {
                try Data("administrator drift".utf8).write(to: installer.peerConfigurationURL("preview"))
            }
        }
        let input = try peerInput(f)
        try installer.install(peerOptions(f, .replace(input)))
        _ = try peerInput(f, listen: true)
        drift = true
        XCTAssertThrowsError(try installer.install(peerOptions(f, .replace(input)), upgrade: true))
        let stopped = try XCTUnwrap(installer.readReceipt("preview"))
        XCTAssertEqual(stopped.state, .preparing)
        XCTAssertNotNil(stopped.peerRuntimePrevious)
        XCTAssertNotNil(stopped.recoveryReason)
        XCTAssertFalse(runner.loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.definitionURL("preview").path))
        XCTAssertEqual(
            try Data(contentsOf: installer.peerConfigurationURL("preview")), Data("administrator drift".utf8))
    }
    func testManagedPeerStartRefusesDriftWithoutBootstrapAndUninstallRemovesOnlyOwnedSettings() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let loaded = LoadedPeerStatus()
        let installer = peerInstaller(f, runner: runner, loaded: loaded)
        let input = try peerInput(f)
        try installer.install(peerOptions(f, .replace(input)))
        let target = installer.peerConfigurationURL("preview")
        let original = try Data(contentsOf: target)
        try Data("changed".utf8).write(to: target)
        XCTAssertNoThrow(try installer.stop(f.options), "Stopping remains available when config has drifted")
        let before = runner.calls.filter { $0.1.first == "bootstrap" }.count
        XCTAssertThrowsError(try installer.start(f.options))
        XCTAssertEqual(runner.calls.filter { $0.1.first == "bootstrap" }.count, before)
        XCTAssertFalse(runner.loaded)
        // A second fresh owned instance exercises uninstall without bypassing stopped recovery.
        let f2 = try fixture()
        defer { try? FileManager.default.removeItem(at: f2.root) }
        try rewriteCanonicalSupport(f2, support: .current)
        let r2 = Runner()
        let l2 = LoadedPeerStatus()
        let i2 = peerInstaller(f2, runner: r2, loaded: l2)
        let input2 = try peerInput(f2)
        try i2.install(peerOptions(f2, .replace(input2)))
        let store = try XCTUnwrap(i2.readReceipt("preview")).store
        try i2.uninstall(f2.options)
        XCTAssertFalse(FileManager.default.fileExists(atPath: i2.peerConfigurationURL("preview").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store))
        XCTAssertFalse(original.isEmpty)
    }
    func testManagedPeerCanonicalIncompatibleRollbackKeepsSnapshotAndServicesStopped() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let loaded = LoadedPeerStatus()
        let initial = peerInstaller(f, runner: runner, loaded: loaded)
        let input = try peerInput(f)
        try initial.install(peerOptions(f, .replace(input)))
        let first = try XCTUnwrap(initial.readReceipt("preview"))
        let store = URL(fileURLWithPath: first.store).resolvingSymlinksInPath()
        let before = try XCTUnwrap(CanonicalReaderRequirement.load(root: store, ownerUID: tractanda_uid()))
        XCTAssertLessThan(before.minimumReaderLevel, 12)
        let older = CanonicalFormatSupport(
            readerLevel: before.minimumReaderLevel, writerLevel: before.minimumReaderLevel,
            read: before.recordFormats, write: before.recordFormats,
            capabilities: before.capabilities, writeCapabilities: before.capabilities)
        XCTAssertNoThrow(try older.require(before))
        // Register a simulated older reader at the actual captured floor.
        try rewriteCanonicalSupport(f, support: older)
        try initial.install(f.options, upgrade: true)
        let previous = try XCTUnwrap(initial.readReceipt("preview"))
        let old = try Data(contentsOf: initial.peerConfigurationURL("preview"))
        try rewriteCanonicalSupport(f, support: .current)
        _ = try peerInput(f, listen: true)
        var raised: CanonicalReaderRequirement?
        let candidate = peerInstaller(f, runner: runner, loaded: loaded) {
            try CanonicalReaderRequirement.withWriterLock(root: store, ownerUID: tractanda_uid()) {
                try CanonicalReaderRequirement.beforeEnrollmentApprovalPublication(
                    root: store, ownerUID: tractanda_uid())
            }
            raised = try CanonicalReaderRequirement.load(root: store, ownerUID: tractanda_uid())
            throw SetupError("fixture candidate health failed after actual publication-intent floor advance")
        }
        XCTAssertThrowsError(try candidate.install(peerOptions(f, .replace(input)), upgrade: true)) {
            XCTAssertTrue($0.localizedDescription.contains("canonical compatibility blocks rollback"))
        }
        let persisted = try XCTUnwrap(CanonicalReaderRequirement.load(root: store, ownerUID: tractanda_uid()))
        XCTAssertEqual(persisted, raised)
        XCTAssertEqual(persisted.storeID, before.storeID)
        XCTAssertEqual(persisted.recordFormats, before.recordFormats)
        XCTAssertEqual(
            persisted.capabilities,
            Set(
                before.capabilities + [
                    AuthorityStore.capability, "tractanda.shared-authority.v1",
                    AuthorityStore.causalCapability, PeerEnrollmentApproval.capability,
                ]
            ).sorted())
        XCTAssertEqual(persisted.minimumReaderLevel, 12)
        XCTAssertThrowsError(try older.require(persisted)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "incompatibleCanonicalReader")
        }
        XCTAssertNoThrow(try CanonicalFormatSupport.current.require(persisted))
        let stopped = try XCTUnwrap(candidate.readReceipt("preview"))
        XCTAssertEqual(stopped.state, .preparing)
        XCTAssertEqual(stopped.peerRuntimePrevious?.bytes, old)
        XCTAssertEqual(stopped.store, previous.store)
        XCTAssertFalse(runner.loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.definitionURL("preview").path))
    }
}

extension SetupTests {
    func testManagedPeerDisabledRetryAfterLeafRemovalCommitsWithoutReactivation() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try rewriteCanonicalSupport(f, support: .current)
        let runner = Runner()
        let loaded = LoadedPeerStatus()
        let installer = peerInstaller(f, runner: runner, loaded: loaded)
        let input = try peerInput(f)
        try installer.install(peerOptions(f, .replace(input)))
        var interrupted = try XCTUnwrap(installer.readReceipt("preview"))
        let old = try Data(contentsOf: installer.peerConfigurationURL("preview"))
        interrupted.peerRuntimePrevious = .init(
            configuration: interrupted.peerRuntimeConfiguration, bytes: old)
        interrupted.peerRuntimeConfiguration = nil
        interrupted.state = .preparing
        let disabledDefinition = try installer.serviceDefinition(interrupted)
        try installer.writeProtected(disabledDefinition, to: installer.definitionURL("preview"), mode: 0o644)
        interrupted.definitionSHA256 = ManagedPeerConfiguration.digest(disabledDefinition)
        try installer.writeReceipt(interrupted)
        try installer.publishPeerBytes(nil, replacing: old, instance: "preview", uid: tractanda_uid())
        // Exact durable state after disable publication, before active receipt commit.
        try installer.install(f.options, upgrade: true)
        let committed = try XCTUnwrap(installer.readReceipt("preview"))
        XCTAssertEqual(committed.state, .active)
        XCTAssertNil(committed.peerRuntimeConfiguration)
        XCTAssertNil(committed.peerRuntimePrevious)
        XCTAssertEqual(loaded.value.state, .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.peerConfigurationURL("preview").path))
    }
}
