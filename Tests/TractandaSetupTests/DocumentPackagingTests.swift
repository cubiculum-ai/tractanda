import Crypto
import Foundation
import TractandaCore
import XCTest

@testable import TractandaSetup

#if canImport(Darwin)
    import Darwin
#endif

final class DocumentPackagingTests: XCTestCase {
    private func inventory() throws -> [BundleManifest.File] {
        let pinned = DocumentExtractionPayload.pinned
        var records: [BundleManifest.File] = []
        for path in [pinned.converterPath] + pinned.noticePaths {
            records.append(
                .init(
                    path: path, sha256: String(repeating: "1", count: 64), size: 10,
                    mode: path == pinned.converterPath ? 0o755 : 0o644))
        }
        for (path, hash) in [
            (pinned.modelManifestPath, pinned.modelManifestSHA256),
            (pinned.runtimePatchManifestPath, pinned.runtimePatchManifestSHA256),
            (pinned.runtimePatchPath, pinned.runtimePatchSHA256),
            (
                "bin/TractandaDocuments_TractandaDocumentConverter.bundle/ModelAssets.json",
                pinned.modelManifestSHA256
            ),
        ] {
            records.append(.init(path: path, sha256: hash, size: 100, mode: 0o644))
        }
        for name in DocumentExtractionPayload.assetNames {
            records.append(
                .init(
                    path: pinned.modelDirectory + "/" + name,
                    sha256: String(repeating: "2", count: 64), size: 10, mode: 0o644))
        }
        return records
    }

    func testPinnedDescriptorRequiresExactAssetsAndResourceIdentity() throws {
        let records = try inventory()
        XCTAssertNoThrow(try DocumentExtractionPayload.pinned.validate(files: records))
        for missing in [
            "model.safetensors", "ModelAssets.json", "Pillow-LICENSE", "tractanda-document-converter",
        ] {
            XCTAssertThrowsError(
                try DocumentExtractionPayload.pinned.validate(
                    files: records.filter {
                        !$0.path.hasSuffix("/" + missing)
                    }))
        }
        var extra = records
        extra.append(
            .init(
                path: DocumentExtractionPayload.pinned.modelDirectory + "/extra",
                sha256: String(repeating: "2", count: 64), size: 1, mode: 0o644))
        XCTAssertThrowsError(try DocumentExtractionPayload.pinned.validate(files: extra))
    }

    func testDescriptorRejectsChangedProtocolAndManifestHash() throws {
        let bytes = try JSONEncoder().encode(DocumentExtractionPayload.pinned)
        for (field, value) in [
            ("workerProtocol", "invented-protocol"),
            ("modelManifestSHA256", String(repeating: "0", count: 64)),
        ] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            json[field] = value
            let payload = try JSONDecoder().decode(
                DocumentExtractionPayload.self,
                from: JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try payload.validate(files: inventory()))
        }
    }

    private func fixture(_ body: (SetupEngine, InstallationReceipt, URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "tdpkg-" + UUID().uuidString)
        // Tiny fixture: one converter marker and receipt metadata, no weights or native process.
        #if canImport(Darwin)
            var filesystem = statfs()
            guard statfs(root.deletingLastPathComponent().path, &filesystem) == 0,
                UInt64(filesystem.f_bavail) * UInt64(filesystem.f_bsize) >= 10 * 1024 * 1024 * 1024 + 1024
                    * 1024
            else { throw XCTSkip("Genuine available-space reserve unavailable for tiny fixture.") }
        #else
            throw XCTSkip("macOS document packaging fixture.")
        #endif
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = SetupRoots(
            platform: .macos, software: root.appendingPathComponent("software"),
            configuration: root.appendingPathComponent("configuration"),
            launchDefinitions: root.appendingPathComponent("jobs"),
            runtime: root.appendingPathComponent("run"), data: root.appendingPathComponent("store"),
            indexes: root.appendingPathComponent("index"), commands: root.appendingPathComponent("commands"))
        let release = roots.software.appendingPathComponent("releases/test")
        let converter = release.appendingPathComponent(DocumentExtractionPayload.pinned.converterPath)
        try FileManager.default.createDirectory(
            at: converter.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("tiny fixture converter".utf8).write(to: converter)
        var receipt = try InstallationReceipt(
            options: SetupOptions(name: "preview", bundle: release), roots: roots,
            owner: "owner", release: release, manifestSHA256: String(repeating: "1", count: 64))
        receipt.documentExtraction = .pinned
        receipt.documentScratchDirectory =
            roots.configuration.appendingPathComponent("document-state/preview/scratch").path
        receipt.documentPreparationDirectory =
            roots.configuration.appendingPathComponent("document-state/preview/prepared").path
        let engine = SetupEngine(roots: roots, rootCheck: { true }, trustedOwnership: false)
        try body(engine, receipt, converter)
    }

    func testReceiptServiceFlagsAndPrivatePathsAreBoundToInstance() throws {
        try fixture { engine, receipt, _ in
            let dictionary = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: engine.serviceDefinition(receipt), format: nil)
                    as? [String: Any])
            let arguments = try XCTUnwrap(dictionary["ProgramArguments"] as? [String])
            let descriptor = DocumentExtractionPayload.pinned
            for (flag, path) in [
                (
                    "--document-converter",
                    URL(fileURLWithPath: receipt.release).appendingPathComponent(descriptor.converterPath)
                        .path
                ),
                (
                    "--document-model-directory",
                    URL(fileURLWithPath: receipt.release).appendingPathComponent(descriptor.modelDirectory)
                        .path
                ),
                ("--document-scratch-directory", receipt.documentScratchDirectory!),
                ("--document-preparation-directory", receipt.documentPreparationDirectory!),
            ] {
                let index = try XCTUnwrap(arguments.firstIndex(of: flag))
                XCTAssertEqual(arguments[index + 1], path)
            }
            var invalid = receipt
            invalid.documentScratchDirectory = receipt.store
            XCTAssertThrowsError(try engine.serviceDefinition(invalid))
            invalid = receipt
            invalid.documentPreparationDirectory = receipt.release
            XCTAssertThrowsError(try engine.serviceDefinition(invalid))
        }
    }

    func testConfiguredReadinessUsesOnlyActualDaemonFields() throws {
        try fixture { engine, receipt, converter in
            let identity = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(DocumentConverterIdentity()))
            let hash = SHA256.hash(data: try Data(contentsOf: converter)).map { String(format: "%02x", $0) }
                .joined()
            let extraction: [String: Any] = [
                "state": "configured", "identity": identity,
                "executableSHA256": hash, "requiresPreparedInput": true,
            ]
            let info: [String: Any] = [
                "documentExtraction": extraction,
                "documentJobs": ["protocol": DocumentExtractionPayload.pinned.workerProtocol],
            ]
            XCTAssertNoThrow(try engine.verifyDocumentReadiness(receipt, info: info))
            for (key, value) in [
                ("state", "unavailable" as Any), ("executableSHA256", "wrong" as Any),
                ("requiresPreparedInput", false as Any),
            ] {
                var bad = extraction
                bad[key] = value
                XCTAssertThrowsError(
                    try engine.verifyDocumentReadiness(
                        receipt, info: ["documentExtraction": bad, "documentJobs": info["documentJobs"]!]))
            }
            XCTAssertThrowsError(
                try engine.verifyDocumentReadiness(receipt, info: ["documentExtraction": extraction]))
        }
    }

    func testOptionalDocumentReceiptDecodesOlderReceiptWithoutInventedConfiguration() throws {
        try fixture { _, receipt, _ in
            var json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
            for field in ["documentExtraction", "documentScratchDirectory", "documentPreparationDirectory"] {
                json.removeValue(forKey: field)
            }
            let decoded = try JSONDecoder().decode(
                InstallationReceipt.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertNil(decoded.documentExtraction)
            XCTAssertNil(decoded.documentScratchDirectory)
            XCTAssertNil(decoded.documentPreparationDirectory)
        }
    }
    final class LifecycleRunner: SetupProcessRunning, @unchecked Sendable {
        var jobs = Set<String>()
        var failNextBootstrap = false
        func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws
            -> ProcessResult
        {
            guard executable == "/bin/launchctl" else { return ProcessResult(status: 0) }
            switch arguments.first {
            case "print": return ProcessResult(status: jobs.contains(arguments[1]) ? 0 : 1)
            case "bootstrap":
                if failNextBootstrap {
                    failNextBootstrap = false
                    return ProcessResult(status: 1, output: "fixture startup failure")
                }
                jobs.insert(
                    "system/" + URL(fileURLWithPath: arguments[2]).deletingPathExtension().lastPathComponent)
            case "bootout": jobs.remove(arguments[1])
            default: break
            }
            return ProcessResult(status: 0)
        }
    }

    private func lifecycle(_ body: (SetupEngine, SetupOptions, LifecycleRunner) throws -> Void) throws {
        try fixture { originalEngine, _, _ in
            let roots = originalEngine.roots
            let bundle = roots.software.deletingLastPathComponent().appendingPathComponent("bundle")
            var files: [BundleManifest.File] = []
            for name in [
                "bin/tractanda", "bin/tractanda-tui", "bin/tractanda-mcp", "bin/tractanda-setup",
                "lib/runtime", "templates/starter-categories.json", "docs/index.html", "licenses/LICENSE",
                "bin/Tractanda_TractandaWeb.bundle/Contents/Resources/Kanban.html",
            ] {
                let path = bundle.appendingPathComponent(name)
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755])
                let data = Data(("tiny fixture " + name).utf8)
                try data.write(to: path)
                let mode: UInt16 = name.hasPrefix("bin/tractanda") ? 0o755 : 0o644
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path.path)
                files.append(
                    .init(
                        path: name,
                        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                        size: UInt64(data.count), mode: mode))
            }
            #if arch(arm64)
                let arch = "arm64"
            #else
                let arch = "x86_64"
            #endif
            try JSONEncoder().encode(
                BundleManifest(version: "0.1.0-package-test", platform: "macos", arch: arch, files: files)
            )
            .write(to: bundle.appendingPathComponent("bundle-manifest.json"))
            let owner = try SystemAccountDirectory().user(forUID: getuid()).name
            let options = SetupOptions(name: "preview", owner: owner, bundle: bundle)
            let runner = LifecycleRunner()
            let installer = SetupEngine(
                roots: roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
                readinessCheck: { _, _, _ in })
            try installer.install(options)
            try body(installer, options, runner)
        }
    }

    func testWorkspacePreparationCreatesPrivateDistinctDirectoriesAndRetainsMarkers() throws {
        try fixture { engine, supplied, _ in
            var first = supplied
            first.documentScratchDirectory = nil
            first.documentPreparationDirectory = nil
            try engine.prepareDocumentState(&first, uid: getuid())
            let paths = try engine.documentStatePaths(first)
            for path in [paths.scratch, paths.preparation] {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
                for reserved in [first.store, first.indexDirectory, first.release] {
                    XCTAssertFalse(path.hasPrefix(reserved + "/"))
                    XCTAssertFalse(reserved.hasPrefix(path + "/"))
                }
            }
            let marker = URL(fileURLWithPath: paths.preparation).appendingPathComponent("retained-job")
            try Data("prepared job".utf8).write(to: marker)
            try engine.prepareDocumentState(&first, uid: getuid())
            XCTAssertEqual(try Data(contentsOf: marker), Data("prepared job".utf8))
            var second = try InstallationReceipt(
                options: SetupOptions(name: "second", bundle: URL(fileURLWithPath: first.release)),
                roots: engine.roots, owner: first.owner, release: URL(fileURLWithPath: first.release),
                manifestSHA256: first.manifestSHA256)
            second.documentExtraction = .pinned
            try engine.prepareDocumentState(&second, uid: getuid())
            XCTAssertNotEqual(first.documentScratchDirectory, second.documentScratchDirectory)
            XCTAssertNotEqual(first.documentPreparationDirectory, second.documentPreparationDirectory)
            let unsafe = URL(fileURLWithPath: second.documentScratchDirectory!)
            try FileManager.default.removeItem(at: unsafe)
            try Data("unexpected file".utf8).write(to: unsafe)
            XCTAssertThrowsError(try engine.prepareDocumentState(&second, uid: getuid()))
        }
    }

    func testFailedCandidateRegistrationRestoresDocumentReceiptOrPriorAbsence() throws {
        for hadDocuments in [false, true] {
            try lifecycle { installer, options, runner in
                var previous = try XCTUnwrap(installer.readReceipt(options.name))
                if hadDocuments {
                    previous.documentExtraction = .pinned
                    try installer.prepareDocumentState(&previous, uid: getuid())
                    try installer.replaceRegistration(&previous)
                }
                let definition = installer.definitionURL(options.name)
                let previousDefinition = try Data(contentsOf: definition)
                let canonical = URL(fileURLWithPath: previous.store).appendingPathComponent(
                    "canonical-marker")
                try Data("canonical retained".utf8).write(to: canonical)
                var candidate = previous
                candidate.release = installer.roots.software.appendingPathComponent("releases/candidate").path
                candidate.manifestSHA256 = String(repeating: "a", count: 64)
                candidate.releases[candidate.release] = candidate.manifestSHA256
                candidate.documentExtraction = .pinned
                try installer.prepareDocumentState(&candidate, uid: getuid())
                let prepared = URL(fileURLWithPath: candidate.documentPreparationDirectory!)
                    .appendingPathComponent("prepared-job")
                let job = URL(fileURLWithPath: candidate.documentScratchDirectory!).appendingPathComponent(
                    "job-state")
                try Data("prepared retained".utf8).write(to: prepared)
                try Data("operational retained".utf8).write(to: job)
                runner.failNextBootstrap = true
                XCTAssertThrowsError(try installer.replaceRegistration(&candidate))
                XCTAssertNotEqual(try Data(contentsOf: definition), previousDefinition)
                try installer.restoreRegistrationSnapshot(
                    &candidate, previous: previous,
                    release: URL(fileURLWithPath: candidate.release), digest: candidate.manifestSHA256,
                    oldDefinition: previousDefinition, oldEmbeddingDefinition: nil)
                let restored = try XCTUnwrap(installer.readReceipt(options.name))
                XCTAssertEqual(restored.documentExtraction, previous.documentExtraction)
                XCTAssertEqual(restored.documentScratchDirectory, previous.documentScratchDirectory)
                XCTAssertEqual(restored.documentPreparationDirectory, previous.documentPreparationDirectory)
                XCTAssertEqual(restored.definitionSHA256, previous.definitionSHA256)
                XCTAssertEqual(restored.release, previous.release)
                XCTAssertEqual(restored.releases[candidate.release], candidate.manifestSHA256)
                XCTAssertEqual(try Data(contentsOf: definition), previousDefinition)
                XCTAssertEqual(try Data(contentsOf: canonical), Data("canonical retained".utf8))
                XCTAssertEqual(try Data(contentsOf: prepared), Data("prepared retained".utf8))
                XCTAssertEqual(try Data(contentsOf: job), Data("operational retained".utf8))
                XCTAssertTrue(runner.jobs.contains(installer.label(options.name)))
            }
        }
    }

    func testUninstallPreservesDocumentJobWorkspacesAndNormalSharedReleaseProtection() throws {
        try lifecycle { installer, options, _ in
            let other = SetupOptions(name: "second", owner: options.owner, bundle: options.bundle)
            try installer.install(other)
            var receipt = try XCTUnwrap(installer.readReceipt(options.name))
            receipt.documentExtraction = .pinned
            try installer.prepareDocumentState(&receipt, uid: getuid())
            try installer.replaceRegistration(&receipt)
            let canonical = URL(fileURLWithPath: receipt.store).appendingPathComponent("canonical-marker")
            let prepared = URL(fileURLWithPath: receipt.documentPreparationDirectory!).appendingPathComponent(
                "prepared-job")
            let job = URL(fileURLWithPath: receipt.documentScratchDirectory!).appendingPathComponent(
                "job-state")
            let index = URL(fileURLWithPath: receipt.indexDirectory).appendingPathComponent(
                "durable-job-metadata")
            for marker in [canonical, prepared, job, index] {
                try Data(marker.lastPathComponent.utf8).write(to: marker)
            }
            try installer.uninstall(options)
            XCTAssertFalse(installer.exists(installer.definitionURL(options.name)))
            let removed = try XCTUnwrap(installer.readReceipt(options.name))
            XCTAssertEqual(removed.state, .removed)
            XCTAssertEqual(removed.documentExtraction, receipt.documentExtraction)
            XCTAssertEqual(removed.documentScratchDirectory, receipt.documentScratchDirectory)
            XCTAssertTrue(installer.exists(URL(fileURLWithPath: receipt.release)))
            for marker in [canonical, prepared, job, index] {
                XCTAssertEqual(try Data(contentsOf: marker), Data(marker.lastPathComponent.utf8))
            }
            try installer.uninstall(other)
            XCTAssertFalse(installer.exists(URL(fileURLWithPath: receipt.release)))
            for marker in [canonical, prepared, job, index] { XCTAssertTrue(installer.exists(marker)) }
        }
    }
}
