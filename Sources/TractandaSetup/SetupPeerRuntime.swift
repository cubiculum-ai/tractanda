import CTractandaPlatform
import Crypto
import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Nonsecret commitments; nil on old receipts means explicitly disabled.
struct ManagedPeerConfiguration: Codable, Equatable {
    let path: String
    let rawSHA256: String
    let settingsDigest: String
    let listenerConfigured: Bool
    let synchronizationEnabled: Bool

    init(path: String, bytes: Data) throws {
        let value = try PeerRuntimeConfiguration.decode(bytes)
        self.path = path
        rawSHA256 = Self.digest(bytes)
        settingsDigest = value.settingsDigest
        listenerConfigured = value.listen != nil
        synchronizationEnabled = value.synchronization.enabled
    }
    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    func validate(path expected: String, bytes: Data? = nil) throws {
        func digestValid(_ s: String) -> Bool {
            s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard path == expected, digestValid(rawSHA256), digestValid(settingsDigest) else {
            throw SetupError("Invalid managed peer configuration commitment.")
        }
        if let bytes, try Self(path: path, bytes: bytes) != self {
            throw SetupError("Managed peer configuration differs from its receipt.")
        }
    }
}

/// One old snapshot only, separate from desired state. Kept until active commit.
struct ManagedPeerConfigurationSnapshot: Codable, Equatable {
    let configuration: ManagedPeerConfiguration?
    let bytes: Data?
    func validate(path: String) throws {
        guard (configuration == nil) == (bytes == nil),
            bytes.map({ !$0.isEmpty && $0.count <= PeerRuntimeConfiguration.maximumFileBytes }) ?? true
        else {
            throw SetupError("Invalid peer configuration recovery snapshot.")
        }
        try configuration?.validate(path: path, bytes: bytes)
    }
}

struct ManagedPeerFile {
    let bytes: Data
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modified: Int64
    let changed: Int64
    let modifiedNanos: Int64
    let changedNanos: Int64
    init(bytes: Data, metadata: stat) {
        self.bytes = bytes
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        size = Int64(metadata.st_size)
        #if canImport(Darwin)
            modified = Int64(metadata.st_mtimespec.tv_sec)
            modifiedNanos = Int64(metadata.st_mtimespec.tv_nsec)
            changed = Int64(metadata.st_ctimespec.tv_sec)
            changedNanos = Int64(metadata.st_ctimespec.tv_nsec)
        #else
            modified = Int64(metadata.st_mtim.tv_sec)
            modifiedNanos = Int64(metadata.st_mtim.tv_nsec)
            changed = Int64(metadata.st_ctim.tv_sec)
            changedNanos = Int64(metadata.st_ctim.tv_nsec)
        #endif
    }
    func same(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && size == other.size && modified == other.modified
            && changed == other.changed && modifiedNanos == other.modifiedNanos
            && changedNanos == other.changedNanos && bytes == other.bytes
    }
}

extension SetupEngine {
    func peerConfigurationURL(_ instance: String) -> URL {
        roots.configuration.appendingPathComponent("peer-runtime").appendingPathComponent(instance + ".json")
    }
    func peerFileUID(_ serviceUID: UInt32) -> UInt32 { trustedOwnership ? serviceUID : getuid() }

    /// Explicit operator input is nonsecret, but still bounded, regular, no-follow and stable.
    func capturePeerConfiguration(_ input: URL) throws -> Data {
        let path = input.path
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw SetupError("Invalid peer configuration input path.")
        }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SetupError("Cannot open peer configuration input safely.") }
        defer { close(fd) }
        return try PeerRuntimeConfiguration.decode(readPeerFile(fd, uid: nil).bytes).encoded()
    }

    func readPeerFile(_ fd: Int32, uid: UInt32?) throws -> ManagedPeerFile {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            before.st_size > 0, before.st_size <= PeerRuntimeConfiguration.maximumFileBytes
        else {
            throw SetupError("Peer configuration must be a bounded regular file.")
        }
        if let uid {
            guard before.st_uid == uid, before.st_mode & 0o7777 == 0o600, before.st_nlink == 1,
                tractanda_peer_configuration_no_mutation_acl(fd) == 0
            else {
                throw SetupError("Peer configuration custody or permissions differ.")
            }
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SetupError("Cannot read peer configuration.") }
            if count == 0 { break }
            guard bytes.count + count <= PeerRuntimeConfiguration.maximumFileBytes else {
                throw SetupError("Peer configuration exceeds its bound.")
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_uid == after.st_uid, before.st_mode == after.st_mode,
            before.st_nlink == after.st_nlink, bytes.count == Int(before.st_size)
        else {
            throw SetupError("Peer configuration changed during capture.")
        }
        let first = ManagedPeerFile(bytes: bytes, metadata: before)
        guard first.same(ManagedPeerFile(bytes: bytes, metadata: after)) else {
            throw SetupError("Peer configuration changed during capture.")
        }
        return first
    }

    /// Open each parent from its already checked descriptor, retaining the final directory.
    /// The existing untrustedOwnership test seam permits same-UID fixture parents only.
    func peerParent(_ instance: String, create: Bool) throws -> Int32 {
        let configuration: URL
        if trustedOwnership {
            configuration = roots.configuration
        } else {
            // Foundation can rewrite the physical /private/var spelling back to /var on
            // macOS. Keep the POSIX physical parent for the fixture seam; the configuration
            // leaf and every subsequent component still pass the no-follow custody walk.
            guard let parent = realpath(roots.configuration.deletingLastPathComponent().path, nil)
            else { throw SetupError("Cannot resolve peer configuration fixture parent (errno \(errno)).") }
            defer { free(parent) }
            configuration = URL(fileURLWithPath: String(cString: parent))
                .appendingPathComponent(roots.configuration.lastPathComponent)
        }
        let path = configuration.appendingPathComponent("peer-runtime").path
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw SetupError("Cannot inspect configuration parents.") }
        do {
            var current = ""
            for component in path.split(separator: "/") {
                current += "/" + component
                var next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create,
                    current == configuration.path || current.hasPrefix(configuration.path + "/")
                {
                    guard mkdirat(fd, String(component), 0o755) == 0, fsync(fd) == 0 else {
                        throw SetupError("Cannot create/sync protected configuration parent.")
                    }
                    next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else {
                    throw SetupError("Unsafe peer configuration parent at \(current) (errno \(errno)).")
                }
                close(fd)
                fd = next
                var metadata = stat()
                let shared = [
                    "/Users/Shared", "/Users/Shared/Library", "/Users/Shared/Library/Application Support",
                ].contains(current)
                let fixtureTemporary =
                    !trustedOwnership && ["/tmp", "/private/tmp", "/var/tmp"].contains(current)
                guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                    metadata.st_uid == 0 || (!trustedOwnership && metadata.st_uid == getuid()),
                    metadata.st_mode & 0o022 == 0
                        || ((shared || fixtureTemporary) && metadata.st_uid == 0
                            && metadata.st_mode & mode_t(S_ISVTX) != 0),
                    tractanda_peer_configuration_no_mutation_acl(fd) == 0
                else {
                    throw SetupError("Unprotected peer configuration parent.")
                }
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
    func readPeerLeaf(parent: Int32, instance: String, uid: UInt32) throws -> ManagedPeerFile? {
        let fd = openat(parent, instance + ".json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw SetupError("Cannot inspect owned peer configuration.") }
        defer { close(fd) }
        return try readPeerFile(fd, uid: uid)
    }
    func ownedPeerBytes(_ configuration: ManagedPeerConfiguration?, instance: String, uid: UInt32) throws
        -> Data?
    {
        let parentURL = peerConfigurationURL(instance).deletingLastPathComponent()
        if !exists(parentURL) {
            guard configuration == nil else { throw SetupError("Owned peer configuration is missing.") }
            return nil
        }
        let parent = try peerParent(instance, create: false)
        defer { close(parent) }
        let file = try readPeerLeaf(parent: parent, instance: instance, uid: peerFileUID(uid))
        guard (file == nil) == (configuration == nil) else {
            throw SetupError("Unowned or missing peer configuration leaf.")
        }
        if let file {
            try configuration?.validate(path: peerConfigurationURL(instance).path, bytes: file.bytes)
        }
        return file?.bytes
    }

    /// Expected state is checked again immediately before atomic publication/removal.
    func publishPeerBytes(_ bytes: Data?, replacing expected: Data?, instance: String, uid: UInt32) throws {
        if bytes == nil && expected == nil {
            _ = try ownedPeerBytes(nil, instance: instance, uid: uid)
            return
        }
        let parent = try peerParent(instance, create: bytes != nil)
        defer { close(parent) }
        let actualUID = peerFileUID(uid)
        let before = try readPeerLeaf(parent: parent, instance: instance, uid: actualUID)
        guard before?.bytes == expected else {
            throw SetupError("Peer configuration drift blocks publication.")
        }
        let temporary = ".peer-" + UUID().uuidString.lowercased()
        var tempCreated = false
        defer { if tempCreated { _ = unlinkat(parent, temporary, 0) } }
        if let bytes {
            _ = try ManagedPeerConfiguration(path: peerConfigurationURL(instance).path, bytes: bytes)
            let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SetupError("Cannot create private peer configuration temporary.") }
            tempCreated = true
            do {
                guard fchmod(fd, 0o600) == 0, !trustedOwnership || fchown(fd, actualUID, gid_t.max) == 0,
                    tractanda_peer_configuration_no_mutation_acl(fd) == 0
                else { throw SetupError("Cannot protect peer configuration temporary.") }
                try bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else {
                            throw SetupError("Cannot write peer configuration temporary.")
                        }
                        offset += count
                    }
                }
                guard fsync(fd) == 0 else { throw SetupError("Cannot sync peer configuration temporary.") }
                close(fd)
            } catch {
                close(fd)
                throw error
            }
        }
        let immediatelyBefore = try readPeerLeaf(parent: parent, instance: instance, uid: actualUID)
        guard
            (before == nil && immediatelyBefore == nil)
                || (before.map { first in immediatelyBefore.map { first.same($0) } ?? false } ?? false)
        else {
            throw SetupError("Peer configuration changed before publication.")
        }
        if let bytes {
            let check = openat(parent, temporary, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard check >= 0 else { throw SetupError("Cannot verify peer configuration temporary.") }
            do {
                let staged = try readPeerFile(check, uid: actualUID)
                guard staged.bytes == bytes else {
                    throw SetupError("Peer configuration temporary changed before publication.")
                }
                close(check)
            } catch {
                close(check)
                throw error
            }
        }
        let result =
            bytes == nil
            ? unlinkat(parent, instance + ".json", 0)
            : renameat(parent, temporary, parent, instance + ".json")
        guard result == 0, fsync(parent) == 0 else {
            throw SetupError("Cannot commit peer configuration publication.")
        }
        tempCreated = false
    }

    func verifyPeerReadiness(_ receipt: InstallationReceipt, status: PeerOperatorRuntimeStatus) throws {
        if let expected = receipt.peerRuntimeConfiguration {
            guard status.state == .active, status.configurationPath == expected.path,
                status.settingsDigest == expected.settingsDigest,
                status.listenerConfigured == expected.listenerConfigured,
                status.synchronizationEnabled == expected.synchronizationEnabled,
                status.synchronization.state == (expected.synchronizationEnabled ? .active : .disabled)
            else {
                throw SetupError("Running peer configuration differs from the owned installation.")
            }
        } else {
            guard status.state == .disabled, status.configurationPath == nil, status.settingsDigest == nil,
                !status.synchronizationEnabled, status.listenerConfigured != true,
                status.synchronization.state == .disabled
            else {
                throw SetupError("Peer runtime is not disabled as configured.")
            }
        }
    }
}

struct ManagedPeerTransition {
    let desired: ManagedPeerConfiguration?
    let previous: ManagedPeerConfigurationSnapshot
    let bytes: Data?
    let currentBytes: Data?
}

extension SetupEngine {
    func requireNoPeerConfigurationAction(_ options: SetupOptions) throws {
        guard options.peerRuntime == .preserve else {
            throw SetupError("Peer configuration options require plan, install or upgrade.")
        }
    }
    func preparePeerTransition(
        previous: InstallationReceipt?, options: SetupOptions, captured: Data?, uid: UInt32
    ) throws -> ManagedPeerTransition {
        let path = peerConfigurationURL(options.name).path
        let snapshot: ManagedPeerConfigurationSnapshot
        let current: Data?
        if let recovery = previous?.peerRuntimePrevious {
            try recovery.validate(path: path)
            snapshot = recovery
            current = try peerRecoveryCurrent(previous!, snapshot: recovery, uid: uid)
        } else {
            current = try ownedPeerBytes(previous?.peerRuntimeConfiguration, instance: options.name, uid: uid)
            snapshot = ManagedPeerConfigurationSnapshot(
                configuration: previous?.peerRuntimeConfiguration, bytes: current)
        }
        let desired: ManagedPeerConfiguration?
        let bytes: Data?
        switch options.peerRuntime {
        case .preserve:
            desired = previous?.peerRuntimeConfiguration
            if let desired {
                if let current, (try? desired.validate(path: path, bytes: current)) != nil {
                    bytes = current
                } else if let old = snapshot.bytes, (try? desired.validate(path: path, bytes: old)) != nil {
                    bytes = old
                } else {
                    throw SetupError(
                        "Resupply the exact replacement input to resume peer configuration recovery.")
                }
            } else {
                bytes = nil
            }
        case .replace:
            guard let captured else { throw SetupError("Peer configuration input was not captured.") }
            desired = try ManagedPeerConfiguration(path: path, bytes: captured)
            bytes = captured
        case .disable:
            desired = nil
            bytes = nil
        }
        if previous?.peerRuntimePrevious != nil, desired != previous?.peerRuntimeConfiguration {
            throw SetupError(
                "A preparing peer configuration transaction requires its exact desired state; finish recovery before changing it."
            )
        }
        return ManagedPeerTransition(
            desired: desired, previous: snapshot, bytes: bytes, currentBytes: current)
    }

    /// A restart may observe either side of the one atomic publication, never arbitrary bytes.
    func peerRecoveryCurrent(
        _ receipt: InstallationReceipt, snapshot: ManagedPeerConfigurationSnapshot, uid: UInt32
    ) throws -> Data? {
        if !exists(peerConfigurationURL(receipt.instance).deletingLastPathComponent()) {
            guard snapshot.configuration == nil else { throw SetupError("Peer recovery file is missing.") }
            return nil
        }
        let parent = try peerParent(receipt.instance, create: false)
        defer { close(parent) }
        let bytes = try readPeerLeaf(parent: parent, instance: receipt.instance, uid: peerFileUID(uid))?.bytes
        if let bytes {
            if let desired = receipt.peerRuntimeConfiguration,
                (try? desired.validate(path: peerConfigurationURL(receipt.instance).path, bytes: bytes))
                    != nil
            {
                return bytes
            }
            if bytes == snapshot.bytes { return bytes }
        } else if snapshot.configuration == nil || receipt.peerRuntimeConfiguration == nil {
            return nil
        }
        throw SetupError("Peer configuration drift blocks recovery.")
    }
    func restorePeerConfiguration(_ receipt: InstallationReceipt, uid: UInt32) throws {
        guard let snapshot = receipt.peerRuntimePrevious else {
            throw SetupError("Peer configuration recovery snapshot is missing.")
        }
        try snapshot.validate(path: peerConfigurationURL(receipt.instance).path)
        let current = try peerRecoveryCurrent(receipt, snapshot: snapshot, uid: uid)
        if current != snapshot.bytes {
            try publishPeerBytes(snapshot.bytes, replacing: current, instance: receipt.instance, uid: uid)
        }
    }
    func peerPlanAction(_ options: SetupOptions) throws -> String {
        switch options.peerRuntime {
        case .replace(let input):
            _ = try capturePeerConfiguration(input)
            return "Replace peer runtime configuration at " + peerConfigurationURL(options.name).path
        case .disable: return "Disable peer runtime; preserve canonical pairings and private credentials"
        case .preserve:
            let receipt = try readReceipt(options.name)
            if let receipt {
                let account = try SystemAccountDirectory().user(named: roots.platform.serviceUser)
                if let snapshot = receipt.peerRuntimePrevious {
                    _ = try peerRecoveryCurrent(receipt, snapshot: snapshot, uid: account.uid)
                } else {
                    _ = try ownedPeerBytes(
                        receipt.peerRuntimeConfiguration, instance: receipt.instance, uid: account.uid)
                }
            }
            return receipt?.peerRuntimeConfiguration.map {
                "Preserve peer runtime configuration at " + $0.path
            }
                ?? "Keep peer runtime disabled"
        }
    }
}

extension SetupEngine {
    func verifyPeerConfigurationForLoad(_ receipt: InstallationReceipt) throws {
        let uid = try SystemAccountDirectory().user(named: roots.platform.serviceUser).uid
        if receipt.peerRuntimeConfiguration == nil, receipt.state == .preparing,
            let prior = receipt.peerRuntimePrevious
        {
            try prior.validate(path: peerConfigurationURL(receipt.instance).path)
            _ = try peerRecoveryCurrent(receipt, snapshot: prior, uid: uid)
        } else {
            _ = try ownedPeerBytes(receipt.peerRuntimeConfiguration, instance: receipt.instance, uid: uid)
        }
    }
    @discardableResult
    func blockPeerConfigurationRecovery(_ receipt: inout InstallationReceipt) throws -> String {
        let serverRemoved = removeOwnedRegistration(
            definitionURL(receipt.instance), expectedSHA256: receipt.definitionSHA256)
        let embeddingRemoved = removeOwnedRegistration(
            embeddingDefinitionURL(receipt.instance), expectedSHA256: receipt.embeddingDefinitionSHA256)
        receipt.state = .preparing
        if serverRemoved { receipt.definitionSHA256 = nil }
        if embeddingRemoved { receipt.embeddingDefinitionSHA256 = nil }
        receipt.recoveryReason =
            serverRemoved && embeddingRemoved
            ? "Peer configuration recovery blocked; services are stopped and owned boot registrations removed."
            : "Peer configuration recovery blocked; services were stopped, but foreign boot registrations were retained and require administrator recovery."
        try writeReceipt(receipt)
        return receipt.recoveryReason!
    }
}

extension SetupEngine {
    /// Preparing commitments reach disk before the service-owned leaf can change.
    func syncPeerReceipt(_ url: URL) throws {
        let file = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw SetupError("Cannot sync installation receipt.") }
        defer { close(file) }
        let parent = open(
            url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw SetupError("Cannot sync receipt directory.") }
        defer { close(parent) }
        guard fsync(file) == 0, fsync(parent) == 0 else {
            throw SetupError("Cannot durably commit installation receipt.")
        }
    }
}
