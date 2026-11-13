import Foundation
import TractandaCore

extension SetupEngine {
    public func verifyBundle(at suppliedBundle: URL) throws -> BundleManifest {
        try verifyBundleContents(at: suppliedBundle, validation: .current)
    }

    private enum BundleValidation { case current, historicalInstalled, layout17Original }

    /// Historical validation is available only for the installed root, anchored by the
    /// protected package transaction and every existing installation receipt.
    func verifyHistoricalInstalledBundle() throws -> BundleManifest {
        guard roots.platform == .linux, let state = try readPackageState(),
            let committed = state.phase == .committed ? state.incoming : state.original
        else { throw SetupError("Installed package lacks a protected historical commitment.") }
        let receipts = try installationReceipts()
        // A failed configure can have receipts already updated to a verified incoming or
        // observed payload while dpkg restores original bytes. Admit only these three
        // exact protected transaction commitments, with each receipt's own full recipe.
        let receiptCommitments =
            state.pending
            ? [state.original, state.incoming, state.observed].compactMap { $0 }
            : [committed]
        guard !receipts.isEmpty || state.instances.isEmpty,
            !state.pending || Set(receipts.map(\.instance)) == Set(state.instances.map(\.name)),
            receipts.allSatisfy({ receipt in
                receipt.state == .removed
                    || receipt.release == packagePayload.path
                        && receiptCommitments.contains(where: {
                            receipt.manifestSHA256 == $0.manifestSHA256 && receipt.embedding == $0.embedding
                                && receipt.documentExtraction?.compatibilityTransport == $0.documentExtraction
                                && (receipt.documentExtraction?.workerPoolProtocol == nil
                                    || receipt.documentExtraction?.workerPoolProtocol
                                        == "tractanda.native-document-pool.v1")
                        })
            }),
            try sha256(packagePayload.appendingPathComponent("bundle-manifest.json"))
                == committed.manifestSHA256
        else { throw SetupError("Historical installed manifest differs from protected receipts.") }
        try requirePackageRelease(packagePayload.path)
        if trustedOwnership { try requireTrustedAncestry(of: packagePayload) }
        let manifest = try verifyBundleContents(at: packagePayload, validation: .historicalInstalled)
        try committed.requirePayload(manifest, digest: committed.manifestSHA256)
        guard
            receipts.allSatisfy({ receipt in
                receipt.state == .removed || receipt.manifestSHA256 != committed.manifestSHA256
                    || receipt.documentExtraction == manifest.documentExtraction
            })
        else { throw SetupError("Historical installed manifest differs from its full receipt.") }
        return manifest
    }

    /// An old Mac execution profile is provenance, not permission to execute an arbitrary
    /// candidate. Only this exact receipt-owned immutable16.2 root can use this finite lane.
    func verifyLayout17OwnedMacOriginal(
        _ receipt: InstallationReceipt, release: URL, expectedDigest: String
    ) throws -> BundleManifest {
        guard roots.platform == .macos, try readReceipt(receipt.instance) == receipt,
            receipt.releases[release.path] == expectedDigest,
            release.path.hasPrefix(roots.software.appendingPathComponent("releases").path + "/"),
            try sha256(release.appendingPathComponent("bundle-manifest.json")) == expectedDigest
        else {
            throw SetupError("The .17 historical source lacks its exact protected owned-release commitment.")
        }
        try requirePackageRelease(release.path)
        if trustedOwnership {
            try requireTrustedAncestry(of: release)
            try requireOwned(release, uid: 0, directory: true)
        }
        return try verifyBundleContents(at: release, validation: .layout17Original)
    }

    private func verifyBundleContents(at suppliedBundle: URL, validation: BundleValidation) throws
        -> BundleManifest
    {
        let bundle = suppliedBundle.resolvingSymlinksInPath()
        let manifestURL = bundle.appendingPathComponent("bundle-manifest.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            try fileSize(manifestURL) <= 4 * 1024 * 1024
        else { throw SetupError("bundle-manifest.json must be a bounded regular file.") }
        let manifest = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: manifestURL))
        switch validation {
        case .current: try manifest.validate()
        case .historicalInstalled: try manifest.validateHistoricalInstalledLinux()
        case .layout17Original: try manifest.validateHistoricalLayout17Original()
        }
        guard manifest.platform == roots.platform.rawValue else {
            throw SetupError("Bundle platform does not match this host.")
        }
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "x86_64"
        #endif
        guard manifest.arch == architecture else {
            throw SetupError("Bundle architecture does not match this host.")
        }
        let expected = Set(manifest.files.map(\.path)).union(["bundle-manifest.json"])
        var found = Set<String>()
        guard let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil)
        else {
            throw SetupError("Cannot enumerate the release bundle.")
        }
        for case let path as URL in enumerator {
            let physical = path.resolvingSymlinksInPath()
            guard physical.pathComponents.starts(with: bundle.pathComponents) else {
                throw SetupError("Release entry resolves outside its bundle: \(path.path)")
            }
            let relative = physical.pathComponents.dropFirst(bundle.pathComponents.count).joined(
                separator: "/")
            try BundleManifest.validateRelativePath(relative)
            let metadata = try FileManager.default.attributesOfItem(atPath: path.path)
            let mode = (metadata[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard mode & 0o022 == 0 else { throw SetupError("Writable release payload: \(relative)") }
            switch metadata[.type] as? FileAttributeType {
            case .typeDirectory: break
            case .typeRegular:
                guard expected.contains(relative) else {
                    throw SetupError("Unlisted release file: \(relative)")
                }
                found.insert(relative)
            default: throw SetupError("Release payload must not contain links or special files: \(relative)")
            }
        }
        guard found == expected else { throw SetupError("Release payload differs from its manifest.") }
        for file in manifest.files {
            let source = bundle.appendingPathComponent(file.path)
            guard try fileSize(source) == file.size, try sha256(source) == file.sha256.lowercased() else {
                throw SetupError("Bundle verification failed: \(file.path)")
            }
        }
        // Historical bytes are receipt-anchored and fully inventoried above. Current
        // runtime/model admission below applies only to the candidate/current bundle.
        switch validation {
        case .historicalInstalled, .layout17Original: return manifest
        case .current: break
        }
        let catalog = try manifest.modelProvisioningManifestPath.map {
            try ModelProvisioningCatalog.load(bundle.appendingPathComponent($0).path)
        }
        if let catalog {
            let expectedIDs = [
                manifest.embedding.map { _ in "granite-embedding-311m-multilingual-r2" },
                manifest.documentExtraction.map { _ in "granite-docling-258m-mlx" },
            ].compactMap { $0 }
            guard Set(catalog.artifacts.map(\.identifier)) == Set(expectedIDs) else {
                throw SetupError("Model catalog differs from configured artifacts.")
            }
            for artifact in catalog.artifacts {
                let expectedRevision =
                    artifact.identifier == "granite-docling-258m-mlx"
                    ? manifest.documentExtraction!.identity.modelRevision
                    : "44399559930365213510b1ee2eb15ded83374f0e"
                guard artifact.revision == expectedRevision else {
                    throw SetupError("Model revision differs from the configured model.")
                }
                let bundled = manifest.files.filter {
                    $0.path.hasPrefix("models/" + artifact.identifier + "/")
                }
                guard bundled.isEmpty || bundled.count == artifact.files.count else {
                    throw SetupError("Partial bundled model is unsupported.")
                }
                for file in bundled {
                    guard
                        artifact.files.contains(where: {
                            "models/" + artifact.identifier + "/" + $0.path == file.path
                                && UInt64($0.size) == file.size && $0.sha256 == file.sha256
                        })
                    else {
                        throw SetupError("Bundled model differs from its pinned catalog.")
                    }
                }
            }
        }
        if let document = manifest.documentExtraction {
            struct Assets: Decodable {
                struct Asset: Decodable {
                    let file: String
                    let bytes: UInt64
                    let sha256: String
                }
                let revision: String
                let files: [Asset]
            }
            let assets = try JSONDecoder().decode(
                Assets.self, from: Data(contentsOf: bundle.appendingPathComponent(document.modelManifestPath))
            )
            guard assets.revision == document.identity.modelRevision, assets.files.count == 14,
                Set(assets.files.map(\.file)) == DocumentExtractionPayload.assetNames
            else { throw SetupError("Pinned document asset manifest differs.") }
            for asset in assets.files {
                if let artifact = catalog?.artifacts.first(where: {
                    $0.identifier == "granite-docling-258m-mlx"
                }) {
                    guard
                        artifact.files.contains(where: {
                            $0.path == asset.file && UInt64($0.size) == asset.bytes
                                && $0.sha256 == asset.sha256
                        })
                    else { throw SetupError("Document artifact differs from pinned model assets.") }
                    continue
                }
                guard
                    manifest.files.contains(where: {
                        $0.path == document.modelDirectory + "/" + asset.file
                            && $0.size == asset.bytes && $0.sha256 == asset.sha256
                    })
                else { throw SetupError("Document inventory differs from pinned model assets.") }
            }
        }
        return manifest
    }

}
