import CTractandaPlatform
import CTractandaSetupMetadata
import Crypto
import Foundation

extension SetupEngine {
    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
    func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
    func fileSize(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }
    func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func requireOwned(_ url: URL, uid: UInt32, directory: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
            !trustedOwnership
                || ((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == uid && mode & 0o022 == 0)
        else { throw SetupError("Untrusted existing path: \(url.path)") }
    }
    func requireTrustedAncestry(of url: URL) throws {
        if usesAnchoredMacRuntime, url.path == roots.runtime.path {
            try withAnchoredMacRuntime { _ in }
            return
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.path.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            guard exists(current) else { break }
            guard !isLink(current) else {
                throw SetupError("Refusing symbolic-link ancestor: \(current.path)")
            }
            let metadata = try FileManager.default.attributesOfItem(atPath: current.path)
            let owner = (metadata[.ownerAccountID] as? NSNumber)?.uint32Value
            let mode = (metadata[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard metadata[.type] as? FileAttributeType == .typeDirectory,
                owner == 0 && mode & 0o022 == 0
            else {
                throw SetupError(
                    "Protect this parent directory before installation: \(current.path). Its permissions were not changed."
                )
            }
        }
    }
    func ensureRootDirectory(_ url: URL) throws {
        if usesAnchoredMacRuntime, url.path == roots.runtime.path {
            try withAnchoredMacRuntime { _ in }
            return
        }
        if trustedOwnership { try requireTrustedAncestry(of: url) }
        if exists(url) {
            try requireOwned(url, uid: 0, directory: true)
        } else {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        }
    }
    func requireServiceDirectory(_ url: URL, uid: UInt32) throws {
        try requireOwned(url, uid: uid, directory: true)
    }
    func ensureServiceDirectory(_ url: URL, uid: UInt32, mode: Int) throws {
        if usesAnchoredMacRuntime, url.deletingLastPathComponent().path == roots.runtime.path {
            guard mode == 0o711 else { throw SetupError("Unexpected managed runtime mode.") }
            try prepareAnchoredMacRuntime(instance: url.lastPathComponent, uid: uid)
            return
        }
        if exists(url) {
            try requireServiceDirectory(url, uid: uid)
            if trustedOwnership {
                let actual =
                    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                    as? NSNumber)?.intValue
                guard actual == mode else {
                    throw SetupError("Existing service directory permissions differ: \(url.path)")
                }
            }
            return
        }
        try ensureRootDirectory(url.deletingLastPathComponent())
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: mode])
        if trustedOwnership {
            // This directory was just created. Never recursively chown an existing data tree.
            try FileManager.default.setAttributes(
                [.ownerAccountID: NSNumber(value: uid)], ofItemAtPath: url.path)
        }
    }
    func ensureServiceLog(_ name: String, uid: UInt32) throws {
        let url = roots.logs.appendingPathComponent(name + ".log")
        if exists(url) {
            try requireOwned(url, uid: uid, directory: false)
            return
        }
        try Data().write(to: url, options: .withoutOverwriting)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if trustedOwnership { attributes[.ownerAccountID] = NSNumber(value: uid) }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    func writeProtected(_ data: Data, to url: URL, mode: Int) throws {
        try ensureRootDirectory(url.deletingLastPathComponent())
        if exists(url) { try requireOwned(url, uid: 0, directory: false) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    func withInstallerLock(_ body: () throws -> Void) throws {
        try ensureRootDirectory(roots.installation)
        if usesAnchoredMacRuntime {
            try withAnchoredMacRuntime { context in
                let descriptor = tractanda_setup_runtime_lock(context)
                guard descriptor >= 0 else {
                    throw SetupError("Another installer may hold the protected runtime lock.")
                }
                defer { tractanda_unlock(descriptor) }
                try body()
            }
            return
        }
        try ensureRootDirectory(roots.runtime)
        let lockURL = roots.runtime.appendingPathComponent("installer.lock")
        if exists(lockURL) { try requireOwned(lockURL, uid: 0, directory: false) }
        let handle = tractanda_lock(lockURL.path)
        guard handle >= 0 else {
            throw SetupError("Another installer may be running, or its lock is not accessible.")
        }
        defer { tractanda_unlock(handle) }
        try body()
    }
    func readReceipt(_ name: String) throws -> InstallationReceipt? {
        let url = receiptURL(name)
        guard exists(url) else { return nil }
        try requireOwned(url, uid: 0, directory: false)
        guard try fileSize(url) < 1024 * 1024 else { throw SetupError("Installation receipt is oversized.") }
        let receipt = try JSONDecoder().decode(InstallationReceipt.self, from: Data(contentsOf: url))
        guard receipt.version == 1, receipt.instance == name,
            receipt.manifestSHA256.count == 64, (1...65535).contains(receipt.port),
            receipt.socket
                == roots.runtime.appendingPathComponent(name).appendingPathComponent("server.sock").path,
            [receipt.store, receipt.indexDirectory].allSatisfy({ path in
                let url = URL(fileURLWithPath: path)
                return path.hasPrefix("/") && url.standardizedFileURL.path == path
                    && url.lastPathComponent == name
            })
        else { throw SetupError("Invalid installation receipt.") }
        try receipt.packageSetupOwner?.validate()
        if let changes = receipt.packageDefinitions, !changes.isEmpty {
            guard roots.platform == .linux, receipt.state == .preparing, changes.count <= 3,
                changes.allSatisfy({ role, change in
                    ["server", "embeddings", "authentication"].contains(role)
                        && change.old != change.desired
                        && [change.old, change.desired].compactMap { $0 }.allSatisfy(
                            SetupPackageCompatibility.isDigest)
                })
            else { throw SetupError("Invalid pending package definition commitments.") }
        }
        if let storeID = receipt.freshTargetStoreID {
            guard receipt.preparedStoreID == nil, !receipt.sample,
                !receipt.initialized || receipt.freshTargetReplicaID != nil
            else {
                throw SetupError("Invalid fresh target receipt.")
            }
            try SetupOptions(
                name: name, bundle: packagePayload,
                storeSelection: .freshPersonalTarget(storeID: storeID)
            ).validate()
            if let replicaID = receipt.freshTargetReplicaID {
                try SetupOptions(
                    name: name, bundle: packagePayload,
                    storeSelection: .prepared(storeID: storeID, replicaID: replicaID)
                ).validate()
            }
        } else if receipt.freshTargetReplicaID != nil {
            throw SetupError("Fresh target replica has no store pin.")
        }
        guard (receipt.preparedStoreID == nil) == (receipt.preparedReplicaID == nil) else {
            throw SetupError("Prepared instance identity pins are incomplete.")
        }
        if let store = receipt.preparedStoreID, let replica = receipt.preparedReplicaID {
            try SetupOptions(
                name: name, bundle: packagePayload,
                storeSelection: .prepared(storeID: store, replicaID: replica)
            ).validate()
        }
        guard receipt.state == .preparing || receipt.packageSetupOwner == nil else {
            throw SetupError("Live setup permission exists outside a preparing receipt.")
        }
        try requirePackageRelease(receipt.release)
        if roots.platform == .linux {
            guard
                receipt.releases.keys.allSatisfy({
                    $0 == roots.software.appendingPathComponent("current").path
                })
            else {
                throw SetupError("Linux receipt contains a program release not owned by the active package.")
            }
        }
        try receipt.peerRuntimeConfiguration?.validate(path: peerConfigurationURL(name).path)
        try receipt.peerRuntimePrevious?.validate(path: peerConfigurationURL(name).path)
        guard receipt.state == .preparing || receipt.peerRuntimePrevious == nil else {
            throw SetupError("Peer configuration snapshot outside a preparing transaction.")
        }
        return receipt
    }
    func writeReceipt(_ receipt: InstallationReceipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(receipt)
        guard bytes.count < 1024 * 1024 else { throw SetupError("Installation receipt is oversized.") }
        try writeProtected(bytes, to: receiptURL(receipt.instance), mode: 0o600)
        try syncPeerReceipt(receiptURL(receipt.instance))
    }
    func verifyRegistration(_ receipt: InstallationReceipt) throws {
        if let expected = receipt.runtimeDefinitionSHA256 {
            let definition = runtimeDefinitionURL(receipt.instance)
            try requireOwned(definition, uid: 0, directory: false)
            guard try sha256(definition) == expected else {
                throw SetupError("Runtime preparer differs from the owned receipt.")
            }
        }
        let definition = definitionURL(receipt.instance)
        if exists(definition) {
            try requireOwned(definition, uid: 0, directory: false)
            guard try sha256(definition) == receipt.definitionSHA256 else {
                throw SetupError("The service definition differs from the owned receipt; it was not changed.")
            }
        } else if receipt.state == .active {
            throw SetupError("The registered service definition is missing.")
        }
        if roots.platform == .linux, let expected = receipt.authenticationDefinitionSHA256 {
            let definition = authenticationDefinitionURL(receipt.instance)
            try requireOwned(definition, uid: 0, directory: false)
            guard try sha256(definition) == expected else {
                throw SetupError("The authentication service definition differs from its receipt.")
            }
        }
        if receipt.embedding != nil {
            let definition = embeddingDefinitionURL(receipt.instance)
            if exists(definition) {
                try requireOwned(definition, uid: 0, directory: false)
                guard try sha256(definition) == receipt.embeddingDefinitionSHA256 else {
                    throw SetupError("The embedding definition differs from the owned receipt.")
                }
            } else if receipt.state == .active {
                throw SetupError("The registered embedding definition is missing.")
            }
        }
    }
    func installRelease(_ manifest: BundleManifest, from bundle: URL, to release: URL, digest: String) throws
    {
        if roots.platform == .linux {
            let active = roots.software.appendingPathComponent("current")
            guard release.path == active.path, release.standardizedFileURL.path == active.path,
                bundle.path == active.path, bundle.standardizedFileURL.path == active.path,
                !isLink(active), try sha256(active.appendingPathComponent("bundle-manifest.json")) == digest,
                try verifyBundle(at: active) == manifest
            else {
                throw SetupError(
                    "Linux program payload is dpkg-owned; Setup cannot copy or replace a package release.")
            }
            try requireOwned(active, uid: 0, directory: true)
            return
        }
        try ensureRootDirectory(release.deletingLastPathComponent())
        if exists(release) {
            try requireOwned(release, uid: 0, directory: true)
            guard try sha256(release.appendingPathComponent("bundle-manifest.json")) == digest else {
                throw SetupError("An existing release has different manifest bytes.")
            }
            _ = try verifyBundle(at: release)
            return
        }
        let temporary = release.deletingLastPathComponent().appendingPathComponent(
            ".install-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { if exists(temporary) { try? FileManager.default.removeItem(at: temporary) } }
        for file in manifest.files {
            let target = temporary.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try FileManager.default.copyItem(at: bundle.appendingPathComponent(file.path), to: target)
            guard try fileSize(target) == file.size, try sha256(target) == file.sha256.lowercased() else {
                throw SetupError("Copied release file failed verification: \(file.path)")
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: file.mode)], ofItemAtPath: target.path)
        }
        let manifestTarget = temporary.appendingPathComponent("bundle-manifest.json")
        try FileManager.default.copyItem(
            at: bundle.appendingPathComponent("bundle-manifest.json"), to: manifestTarget)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestTarget.path)
        guard try sha256(manifestTarget) == digest else {
            throw SetupError("Bundle manifest changed while copying.")
        }
        _ = try verifyBundle(at: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: release)
    }
}
