import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

extension SetupEngine {
    var clientLink: URL { roots.software.appendingPathComponent("current") }

    func installationReceipts() throws -> [InstallationReceipt] {
        let directory = roots.configuration.appendingPathComponent("receipts")
        guard exists(directory) else { return [] }
        try requireOwned(directory, uid: 0, directory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        if roots.platform == .linux {
            guard entries.count <= 1024, entries.allSatisfy({
                $0.pathExtension == "json" && SetupPackageState.validInstance($0.deletingPathExtension().lastPathComponent)
            }) else { throw SetupError("Unknown or excessive Linux installation receipt inventory.") }
        }
        return try entries
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            .compactMap { try readReceipt($0.deletingPathExtension().lastPathComponent) }
    }

    /// One shared client entry point; each service independently pins its installed release.
    func currentClientRelease() throws -> String? {
        guard exists(clientLink) else { return nil }
        if roots.platform == .linux {
            guard !isLink(clientLink) else { throw SetupError("Linux active package payload must be a protected real directory.") }
            try requireOwned(clientLink, uid: 0, directory: true)
            _ = try verifyBundle(at: clientLink)
            return clientLink.path
        }
        guard isLink(clientLink) else { throw SetupError("The shared client entry is not a symbolic link.") }
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: clientLink.path)
        guard
            URL(fileURLWithPath: target).deletingLastPathComponent()
                == roots.software.appendingPathComponent("releases"),
            let receipt = try installationReceipts().first(where: {
                $0.state != .removed && $0.releases[target] != nil
            })
        else { throw SetupError("The shared client link does not identify an owned release.") }
        let release = URL(fileURLWithPath: target)
        try requireOwned(release, uid: 0, directory: true)
        guard try sha256(release.appendingPathComponent("bundle-manifest.json")) == receipt.releases[target]
        else {
            throw SetupError("The shared client release differs from its receipt.")
        }
        return target
    }
    func publishClientLink(_ receipt: InstallationReceipt) throws {
        try setClientRelease(receipt.release)
    }
    func setClientRelease(_ release: String?, excludingStoppedInstance: String? = nil) throws {
        let link = clientLink
        if roots.platform == .linux {
            guard let release, release == clientLink.path,
                try currentClientRelease() == release else {
                throw SetupError("Linux active program files belong to dpkg; Setup cannot retarget or remove them.")
            }
            // There is no Linux client retarget: dpkg already replaced the one shared payload.
            // The package transaction admits every store before restart; old receipt digests may
            // still be pending while the same fixed payload is configured instance by instance.
            return
        }
        guard let release else {
            if exists(link) { try FileManager.default.removeItem(at: link) }
            return
        }
        try requireSharedClientReader(release, excludingStoppedInstance: excludingStoppedInstance)
        try ensureRootDirectory(link.deletingLastPathComponent())
        let pending = link.deletingLastPathComponent().appendingPathComponent(".link-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(atPath: pending.path, withDestinationPath: release)
        defer { if exists(pending) { try? FileManager.default.removeItem(at: pending) } }
        guard rename(pending.path, link.path) == 0 else {
            throw SetupError("Cannot publish the installed client link.")
        }
    }
    func removeClientLink(_ receipt: InstallationReceipt) throws {
        if roots.platform == .linux { return } // dpkg owns the real active payload directory.
        guard let target = try currentClientRelease(), receipt.releases[target] != nil else { return }
        let remaining = try installationReceipts().filter {
            $0.instance != receipt.instance && $0.state == .active
        }
        if remaining.contains(where: { $0.release == target }) { return }
        try setClientRelease(remaining.first?.release, excludingStoppedInstance: receipt.instance)
    }

    func releasesUsedByOtherInstances(_ instance: String) throws -> Set<String> {
        Set(
            try installationReceipts().filter { $0.instance != instance && $0.state != .removed }
                .flatMap { $0.releases.keys })
    }
}
