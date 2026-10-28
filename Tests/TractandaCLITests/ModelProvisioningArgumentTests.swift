import Foundation
import TractandaCore
import XCTest
@testable import TractandaCLI

final class ModelProvisioningArgumentTests: XCTestCase {
    func testProvisioningFlagsRequirePairedAbsoluteManifestAndStorage() throws {
        let base = ["daemon", "/tmp/model-store", "/tmp/model.sock"]
        XCTAssertThrowsError(try daemonConfiguration(from: base + ["--model-storage-directory", "/tmp/models"]))
        XCTAssertThrowsError(try daemonConfiguration(from: base + ["--model-provisioning-manifest", "/tmp/missing.json"]))
        XCTAssertThrowsError(try daemonConfiguration(from: base + ["--model-adoption-directory", "/tmp/models"]))
    }
    func testModelManifestPinsDoclingWithoutRequiringDirectoryAtArgumentParse() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("model-args-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = ModelArtifactManifest(identifier: "granite-docling-258m-mlx", repository: "fixture/docling", revision: String(repeating: "b", count: 40),
            files: [.init(path: "config.json", size: 2, sha256: String(repeating: "a", count: 64))])
        let manifest = root.appendingPathComponent("manifest.json"); try JSONEncoder().encode(ModelProvisioningCatalog(artifacts: [artifact])).write(to: manifest)
        let models = root.appendingPathComponent("models")
        let config = try daemonConfiguration(from: ["daemon", "/tmp/model-store", "/tmp/model.sock",
            "--model-provisioning-manifest", manifest.path, "--model-storage-directory", models.path,
            "--document-converter", "/usr/bin/true", "--document-model-directory", artifact.directory(in: models).path,
            "--document-scratch-directory", root.appendingPathComponent("scratch").path])
        XCTAssertEqual(config.documentConverter?.modelArtifact, artifact); XCTAssertFalse(config.documentConverter!.modelIsReady)
        XCTAssertEqual(config.modelProvisioning?.storageDirectory, models.path)
    }
}
