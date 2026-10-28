import Foundation
import TractandaCore

extension SetupEngine {
    /// Release bytes were verified before registration. No network work is performed by Setup.
    func modelCatalog(_ release: URL) throws -> ModelProvisioningCatalog? {
        let manifest = try JSONDecoder().decode(
            BundleManifest.self,
            from: Data(contentsOf: release.appendingPathComponent("bundle-manifest.json")))
        guard let path = manifest.modelProvisioningManifestPath,
            let hash = manifest.modelProvisioningManifestSHA256
        else { return nil }
        guard path == "models/manifest.json", try sha256(release.appendingPathComponent(path)) == hash else {
            throw SetupError("Model provisioning manifest differs from its release.")
        }
        return try ModelProvisioningCatalog.load(release.appendingPathComponent(path).path)
    }
    /// Full/offline packages may import only their current bundle. Migration of a prior
    /// unpublished bundled-model layout is a private operator step, never a shipped search.
    func modelAdoptionDirectory(_ receipt: InstallationReceipt) throws -> String? {
        let release = URL(fileURLWithPath: receipt.release)
        let expectedParent = roots.software.appendingPathComponent("releases")
        guard !isLink(release),
            roots.platform == .linux
                ? release.path == roots.software.appendingPathComponent("current").path
                : release.deletingLastPathComponent().path == expectedParent.path
        else { throw SetupError("Model adoption must use the current owned bundle.") }
        let models = release.appendingPathComponent("models")
        if exists(models.appendingPathComponent("granite-embedding-311m-multilingual-r2/model.safetensors"))
            || exists(models.appendingPathComponent("granite-docling-258m-mlx/model.safetensors"))
        {
            return models.path
        }
        return nil
    }
    func modelArtifact(_ identifier: String, release: URL) throws -> ModelArtifactManifest? {
        guard let catalog = try modelCatalog(release) else { return nil }
        guard let artifact = catalog.artifacts.first(where: { $0.identifier == identifier }) else {
            throw SetupError("Configured model artifact is missing from the release catalog.")
        }
        return artifact
    }
}
