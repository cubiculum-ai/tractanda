import Foundation

extension SetupEngine {
    public func verifyBundle(at suppliedBundle: URL) throws -> BundleManifest {
        let bundle = suppliedBundle.resolvingSymlinksInPath()
        let manifestURL = bundle.appendingPathComponent("bundle-manifest.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            try fileSize(manifestURL) <= 4 * 1024 * 1024
        else { throw SetupError("bundle-manifest.json must be a bounded regular file.") }
        let manifest = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.validate()
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
        return manifest
    }

}
