import Crypto
import Foundation
import TractandaCore

extension SetupEngine {
    func runtimeDefinitionURL(_ instance: String) -> URL {
        roots.launchDefinitions.appendingPathComponent("ai.tractanda.runtime." + instance + ".plist")
    }

    /// A separate root LaunchDaemon creates only the transient daemon-owned IPC directory.
    /// The content server always runs under the existing unprivileged service account.
    func runtimeDefinition(_ receipt: InstallationReceipt) throws -> Data {
        guard roots.platform == .macos else { throw SetupError("Runtime preparer is macOS-only.") }
        return try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "ai.tractanda.runtime." + receipt.instance,
                "ProgramArguments": [
                    URL(fileURLWithPath: receipt.release).appendingPathComponent("bin/tractanda-setup").path,
                    "--prepare-managed-runtime", receipt.instance,
                ],
                "UserName": "root", "RunAtLoad": true, "Umask": 0o022,
                "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 5,
            ], format: .xml, options: 0)
    }

    func replaceRuntimeRegistration(_ receipt: inout InstallationReceipt) throws {
        let bytes = try runtimeDefinition(receipt)
        let path = runtimeDefinitionURL(receipt.instance)
        if exists(path) {
            try requireOwned(path, uid: 0, directory: false)
            guard let expected = receipt.runtimeDefinitionSHA256, try sha256(path) == expected else {
                throw SetupError("Unowned runtime preparer was not replaced.")
            }
            _ = try runner.run(
                "/bin/launchctl", ["bootout", "system/ai.tractanda.runtime." + receipt.instance],
                environment: [:])
        }
        try writeProtected(bytes, to: path, mode: 0o644)
        receipt.runtimeDefinitionSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try writeReceipt(receipt)
        try successful("/bin/launchctl", ["bootstrap", "system", path.path])
    }

    func prepareManagedRuntime(_ instance: String) throws {
        try requireRootAndPlatform()
        guard SetupPackageState.validInstance(instance), let receipt = try readReceipt(instance),
            receipt.state != .removed, let expected = receipt.runtimeDefinitionSHA256
        else {
            throw SetupError("Runtime preparation requires an owned managed instance.")
        }
        let definition = runtimeDefinitionURL(instance)
        try requireOwned(definition, uid: 0, directory: false)
        guard try sha256(definition) == expected,
            try Data(contentsOf: definition) == runtimeDefinition(receipt)
        else {
            throw SetupError("Runtime preparation definition differs from its receipt.")
        }
        let release = URL(fileURLWithPath: receipt.release)
        let helper = release.appendingPathComponent("bin/tractanda-setup")
        let manifestURL = release.appendingPathComponent("bundle-manifest.json")
        guard
            release.deletingLastPathComponent().path
                == roots.software.appendingPathComponent("releases").path,
            !isLink(release), !isLink(helper), try fileSize(manifestURL) <= 4 * 1024 * 1024
        else {
            throw SetupError("Runtime preparer release is not the owned instance release.")
        }
        try requireOwned(release, uid: 0, directory: true)
        try requireOwned(manifestURL, uid: 0, directory: false)
        try requireOwned(helper, uid: 0, directory: false)
        guard try sha256(manifestURL) == receipt.manifestSHA256 else {
            throw SetupError("Runtime preparer manifest differs from its receipt.")
        }
        let manifest = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.validate()
        guard manifest.platform == roots.platform.rawValue,
            let selected = manifest.files.first(where: { $0.path == "bin/tractanda-setup" }),
            (try FileManager.default.attributesOfItem(atPath: helper.path)[.posixPermissions] as? NSNumber)?
                .uint16Value == selected.mode,
            selected.mode & 0o111 != 0, try fileSize(helper) == selected.size,
            try sha256(helper) == selected.sha256
        else {
            throw SetupError("Runtime preparer bytes differ from the owned manifest.")
        }
        try ensureRootDirectory(roots.runtime)
        let account = try SystemAccountDirectory().user(named: roots.platform.serviceUser)
        guard account.uid != 0 else { throw SetupError("The content service must be unprivileged.") }
        try ensureServiceDirectory(
            roots.runtime.appendingPathComponent(instance), uid: account.uid, mode: 0o711)
    }
}
