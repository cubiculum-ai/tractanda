import Foundation
import TractandaCore
import XCTest
@testable import TractandaSetup

final class ModelProvisioningSetupTests: XCTestCase {
    private func inventory() -> [BundleManifest.File] {
        let paths = ["bin/tractanda", "bin/tractanda-tui", "bin/tractanda-mcp", "bin/tractanda-setup", "bin/tractanda-auth-helper",
            "bin/Tractanda_TractandaWeb.bundle/index.html", "lib/closure.json", "templates/test.json", "docs/test.md", "licenses/test.txt", "models/manifest.json"]
        return paths.map { .init(path: $0, sha256: String(repeating: "1", count: 64), size: 2, mode: $0.hasPrefix("bin/tractanda") ? 0o755 : 0o644) }
    }
    func testDigestBoundCatalogAllowsSlimBundleAndRejectsIncompleteDescriptor() throws {
        let files = inventory()
        let valid = BundleManifest(version: "test", platform: "linux", arch: "x86_64", files: files,
            modelProvisioningManifestPath: "models/manifest.json", modelProvisioningManifestSHA256: String(repeating: "1", count: 64))
        XCTAssertNoThrow(try valid.validate())
        let roundtrip = try JSONDecoder().decode(BundleManifest.self, from: JSONEncoder().encode(valid))
        XCTAssertEqual(roundtrip, valid)
        for path in ["../models/manifest.json", "models/other.json"] {
            XCTAssertThrowsError(try BundleManifest(version: "test", platform: "linux", arch: "x86_64", files: files,
                modelProvisioningManifestPath: path, modelProvisioningManifestSHA256: String(repeating: "1", count: 64)).validate())
        }
        XCTAssertThrowsError(try BundleManifest(version: "test", platform: "linux", arch: "x86_64", files: files,
            modelProvisioningManifestPath: "models/manifest.json").validate())
        XCTAssertThrowsError(try BundleManifest(version: "test", platform: "linux", arch: "x86_64", files: files,
            modelProvisioningManifestPath: "models/manifest.json", modelProvisioningManifestSHA256: String(repeating: "2", count: 64)).validate())
    }
    func testEmbeddingSlimStillRequiresNativeRuntimeAndLicenses() throws {
        let files: [BundleManifest.File] = ["bin/tractanda-embeddings", "licenses/Granite/LICENSE", "licenses/Granite/README.md"].map {
            .init(path: $0, sha256: String(repeating: "1", count: 64), size: 2, mode: 0o755)
        }
        XCTAssertNoThrow(try EmbeddingPayload.granite.validate(files: files, provisioned: true))
        XCTAssertThrowsError(try EmbeddingPayload.granite.validate(files: files))
        XCTAssertThrowsError(try EmbeddingPayload.granite.validate(files: Array(files.dropFirst()), provisioned: true))
    }
    func testPreUnpackDescriptorExcludesPrivateCatalogFields() throws {
        let descriptor = SetupPackageCompatibility(manifestSHA256: String(repeating: "1", count: 64),
            version: "test", arch: "x86_64", canonicalFormats: .current)
        let encoded = try descriptor.encoded()
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for field in ["modelProvisioningManifestPath", "modelProvisioningManifestSHA256", "modelProvisioningManifest"] {
            XCTAssertNil(value[field])
            var unknown = value
            unknown[field] = "unsupported"
            let data = try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys, .withoutEscapingSlashes])
            XCTAssertThrowsError(try SetupPackageCompatibility.decode(data))
        }
    }
    func testDurableModelRootsOutsideReleasesOnBothPlatforms() {
        XCTAssertEqual(SetupRoots(platform: .macos).models.path, "/Library/Tractanda/Models")
        XCTAssertEqual(SetupRoots(platform: .linux).models.path, "/opt/tractanda/var/lib/tractanda/Models")
        XCTAssertEqual(SetupRoots(configuration: URL(fileURLWithPath: "/private/tmp/model-setup")).models.path, "/private/tmp/model-setup/models")
    }
}
