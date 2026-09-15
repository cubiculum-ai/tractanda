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
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            .compactMap { try readReceipt($0.deletingPathExtension().lastPathComponent) }
    }

    /// One shared client entry point; each service independently pins its installed release.
    func currentClientRelease() throws -> String? {
        guard exists(clientLink) else { return nil }
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
    func setClientRelease(_ release: String?) throws {
        let link = clientLink
        guard let release else {
            if exists(link) { try FileManager.default.removeItem(at: link) }
            return
        }
        try ensureRootDirectory(link.deletingLastPathComponent())
        let pending = link.deletingLastPathComponent().appendingPathComponent(".link-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(atPath: pending.path, withDestinationPath: release)
        defer { if exists(pending) { try? FileManager.default.removeItem(at: pending) } }
        guard rename(pending.path, link.path) == 0 else {
            throw SetupError("Cannot publish the installed client link.")
        }
    }
    func removeClientLink(_ receipt: InstallationReceipt) throws {
        guard let target = try currentClientRelease(), receipt.releases[target] != nil else { return }
        let remaining = try installationReceipts().filter {
            $0.instance != receipt.instance && $0.state == .active
        }
        if remaining.contains(where: { $0.release == target }) { return }
        try setClientRelease(remaining.first?.release)
    }

    func releasesUsedByOtherInstances(_ instance: String) throws -> Set<String> {
        Set(
            try installationReceipts().filter { $0.instance != instance && $0.state != .removed }
                .flatMap { $0.releases.keys })
    }
}
