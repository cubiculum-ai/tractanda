import Crypto
import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaSetup

final class SetupLinuxPayloadTests: XCTestCase {
    private var root: URL?
    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }
    private func fixture() throws -> (SetupEngine, BundleManifest, InstallationReceipt, URL) {
        let root = try GuardedFixtureDirectory.create(
            prefix: "linux-setup", source: "SetupLinuxPayloadTests", test: name)
        self.root = root
        let roots = SetupRoots(
            platform: .linux, software: root.appendingPathComponent("software"),
            configuration: root.appendingPathComponent("configuration"),
            launchDefinitions: root.appendingPathComponent("units"),
            data: root.appendingPathComponent("stores"), indexes: root.appendingPathComponent("indexes"),
            commands: root.appendingPathComponent("commands"))
        let payload = roots.software.appendingPathComponent("current")
        var files: [BundleManifest.File] = []
        for name in [
            "bin/tractanda", "bin/tractanda-setup", "bin/tractanda-tui", "bin/tractanda-mcp",
            "bin/tractanda-auth-helper", "lib/runtime", "templates/example", "docs/example",
            "licenses/example",
            "bin/Tractanda_TractandaWeb.resources/Kanban.html",
        ] {
            let path = payload.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data("tiny package fixture".utf8)
            try bytes.write(to: path)
            let mode: UInt16 = name.hasPrefix("bin/tractanda") ? 0o755 : 0o644
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path.path)
            files.append(.init(path: name, sha256: digest(bytes), size: UInt64(bytes.count), mode: mode))
        }
        #if arch(arm64)
            let arch = "arm64"
        #else
            let arch = "x86_64"
        #endif
        let manifest = BundleManifest(
            version: "0.1.0-poc.15", platform: "linux", arch: arch, files: files, canonicalFormats: .current)
        let bytes = try JSONEncoder().encode(manifest)
        try bytes.write(to: payload.appendingPathComponent("bundle-manifest.json"))
        let options = SetupOptions(name: "production", owner: "fixture-owner", bundle: payload)
        let receipt = try InstallationReceipt(
            options: options, roots: roots, owner: "fixture-owner",
            release: payload, manifestSHA256: digest(bytes))
        return (
            SetupEngine(
                roots: roots, runner: SetupServiceBackendTests.Runner(), rootCheck: { true },
                trustedOwnership: false),
            manifest, receipt, payload
        )
    }
    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func testLinuxReleaseIsFixedPackageDirectoryAndVerificationDoesNotCopy() throws {
        let (engine, manifest, receipt, payload) = try fixture()
        let options = SetupOptions(name: "production", bundle: payload)
        XCTAssertEqual(
            engine.releaseURL(options, manifest: manifest, digest: receipt.manifestSHA256).path, payload.path)
        let directoryURL = URL(fileURLWithPath: payload.path, isDirectory: true)
        let fileURL = URL(fileURLWithPath: payload.path, isDirectory: false)
        try engine.installRelease(manifest, from: fileURL, to: directoryURL, digest: receipt.manifestSHA256)
        try engine.installRelease(manifest, from: directoryURL, to: fileURL, digest: receipt.manifestSHA256)
        XCTAssertFalse(engine.exists(engine.roots.software.appendingPathComponent("releases")))
        XCTAssertEqual(try engine.currentClientRelease(), payload.path)
    }

    func testLinuxRefusesExternalBundleCopyAndAlternateReleaseDestination() throws {
        let (engine, manifest, receipt, payload) = try fixture()
        let other = payload.deletingLastPathComponent().appendingPathComponent("other")
        XCTAssertThrowsError(
            try engine.installRelease(manifest, from: other, to: payload, digest: receipt.manifestSHA256))
        XCTAssertThrowsError(
            try engine.installRelease(manifest, from: payload, to: other, digest: receipt.manifestSHA256))
        XCTAssertFalse(engine.exists(other))
        XCTAssertEqual(
            try engine.sha256(payload.appendingPathComponent("bundle-manifest.json")), receipt.manifestSHA256)
    }

    func testLinuxNeverRetargetsDeletesOrPublishesPackageOwnedEntryPoints() throws {
        let (engine, _, receipt, payload) = try fixture()
        try FileManager.default.createDirectory(at: engine.roots.commands, withIntermediateDirectories: true)
        let command = engine.roots.commands.appendingPathComponent("tractanda-tui")
        let bytes = Data("dpkg-owned wrapper".utf8)
        try bytes.write(to: command)
        XCTAssertThrowsError(try engine.setClientRelease(nil))
        XCTAssertThrowsError(
            try engine.setClientRelease(
                payload.deletingLastPathComponent().appendingPathComponent("old").path))
        try engine.removeClientLink(receipt)
        try engine.publishTUICommand()
        try engine.removeTUICommandIfUnused()
        XCTAssertTrue(engine.exists(payload))
        XCTAssertFalse(engine.isLink(payload))
        XCTAssertEqual(try Data(contentsOf: command), bytes)
    }

    func testLinuxPackagePayloadCannotBeSymlinkedToAnUntrackedRelease() throws {
        let (engine, _, _, payload) = try fixture()
        let moved = payload.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.moveItem(at: payload, to: moved)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: moved)
        XCTAssertThrowsError(try engine.currentClientRelease())
    }

    func testLinuxMacStyleBinaryRollbackIsRefusedWithDurablePreparingReason() throws {
        let (engine, _, original, payload) = try fixture()
        var receipt = original
        var previous = original
        previous.state = .active
        let program = payload.appendingPathComponent("bin/tractanda")
        let installedBytes = try Data(contentsOf: program)
        XCTAssertThrowsError(
            try engine.restoreRegistrationSnapshot(
                &receipt, previous: previous,
                release: payload, digest: original.manifestSHA256,
                oldDefinition: Data("old unit".utf8), oldEmbeddingDefinition: nil))
        let retained = try XCTUnwrap(engine.readReceipt("production"))
        XCTAssertEqual(retained.state, .preparing)
        XCTAssertTrue(retained.recoveryReason?.contains("dpkg-owned") == true)
        XCTAssertEqual(try Data(contentsOf: program), installedBytes)
        XCTAssertFalse(engine.exists(engine.definitionURL("production")))
    }

    func testPublicLinuxInstallAndMacUninstallRemainGatedWithoutMutations() throws {
        let (engine, _, receipt, payload) = try fixture()
        let options = SetupOptions(name: "production", owner: "fixture-owner", bundle: payload)
        XCTAssertThrowsError(try engine.install(options))
        XCTAssertThrowsError(try engine.uninstall(options))
        XCTAssertFalse(engine.exists(engine.roots.configuration))
        XCTAssertFalse(engine.exists(URL(fileURLWithPath: receipt.store)))
        XCTAssertTrue(engine.exists(payload.appendingPathComponent("bin/tractanda")))
    }

    func testLinuxLoadReloadsOwnedPublicationBeforeManagerStateProbeAndRefusesChangedHash() throws {
        let (engine, _, original, _) = try fixture()
        let runner = try XCTUnwrap(engine.runner as? SetupServiceBackendTests.Runner)
        runner.fragment = engine.definitionURL("production").path
        runner.activeState = "active"
        runner.pid = 4242
        var receipt = original
        receipt.state = .active
        let bytes = try engine.serviceDefinition(receipt)
        try engine.writeProtected(bytes, to: engine.definitionURL("production"), mode: 0o644)
        receipt.definitionSHA256 = digest(bytes)
        try engine.writeReceipt(receipt)
        runner.needsReload = true  // The trusted write is newer than the manager's loaded fragment.
        try engine.load("production")
        XCTAssertEqual(runner.calls.first?.1, ["daemon-reload"])
        XCTAssertFalse(runner.needsReload)
        let count = runner.calls.count
        try Data("foreign edit".utf8).write(to: engine.definitionURL("production"))
        runner.needsReload = true
        XCTAssertThrowsError(try engine.load("production"))
        XCTAssertEqual(runner.calls.count, count)  // Hash drift must be refused even before reload.
    }

    func testLinuxReceiptAndBothUnitGeneratorsRejectAlternateProgramRelease() throws {
        let (engine, _, original, payload) = try fixture()
        var receipt = original
        receipt.release = payload.deletingLastPathComponent().appendingPathComponent("older").path
        receipt.embedding = .granite
        XCTAssertThrowsError(try engine.serviceDefinition(receipt))
        XCTAssertThrowsError(try engine.replaceEmbeddingRegistration(&receipt))
        try engine.writeReceipt(receipt)
        XCTAssertThrowsError(try engine.readReceipt("production"))
        XCTAssertFalse(engine.exists(engine.definitionURL("production")))
        XCTAssertFalse(engine.exists(engine.embeddingDefinitionURL("production")))
    }

    func testLinuxServerDefinitionUsesPackageProgramAndPrivateLoadedPeerPath() throws {
        let (engine, _, receipt, payload) = try fixture()
        let text = String(decoding: try engine.serviceDefinition(receipt), as: UTF8.self)
        XCTAssertTrue(
            text.contains("\"" + payload.appendingPathComponent("bin/tractanda").path + "\" \"daemon\""))
        XCTAssertTrue(text.contains("User=daemon\n"))
        XCTAssertTrue(
            text.contains("Environment=\"TRACTANDA_AUTH_SOCKET=/run/tractanda-auth-production/auth.sock\""))
        XCTAssertTrue(text.contains("\"--index-directory\""))
        XCTAssertFalse(text.contains("--peer-runtime-configuration"))
        XCTAssertEqual(
            engine.definitionURL("production").lastPathComponent, "tractanda-server-production.service")
        XCTAssertEqual(
            engine.embeddingDefinitionURL("production").lastPathComponent,
            "tractanda-embeddings-production.service")
    }
}
