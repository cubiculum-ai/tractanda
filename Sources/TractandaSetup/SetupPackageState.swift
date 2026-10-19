import CTractandaPlatform
import Crypto
import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Root-owned operational state, separate from canonical identity/policy and dpkg's own database.
/// No program payload is retained here. Original intent survives old-prerm/new-preinst double entry.
struct SetupPackageState: Codable, Equatable {
    static let profileName = "tractanda.package-transaction.v1"
    static let maximumBytes = 1_048_576
    enum Phase: String, Codable {
        case quiescing, quiesced, awaitingUnpack, configuring, failed, committed, removed
    }
    struct Instance: Codable, Equatable {
        let name: String
        let originalManifestSHA256: String
        let wasRunning: Bool
        let wasEnabled: Bool
        let embeddingWasRunning: Bool
        let authenticationWasRunning: Bool
    }
    let profile: String
    let operationID: String
    let original: SetupPackageCompatibility?
    var incoming: SetupPackageCompatibility?
    /// Last verified bytes actually on disk, independently of a later rejected incoming target.
    var observed: SetupPackageCompatibility?
    var phase: Phase
    var instances: [Instance]
    var startupPermitted: [String]
    var owner: SetupPackageOwner?
    var recoveryReason: String?

    init(original: SetupPackageCompatibility?, instances: [Instance]) throws {
        profile = Self.profileName
        operationID = try UUID.makeVersion1().uuidString.lowercased()
        self.original = original
        incoming = nil
        observed = original
        phase = .quiescing
        self.instances = instances
        startupPermitted = []
        owner = nil
        recoveryReason = nil
    }

    var pending: Bool { phase != .committed && phase != .removed }
    func validate() throws {
        guard profile == Self.profileName, let uuid = UUID(uuidString: operationID),
            uuid.version1Components != nil,
            uuid.uuidString.lowercased() == operationID, instances.count <= 1024,
            Set(instances.map(\.name)).count == instances.count,
            instances.allSatisfy({
                Self.validInstance($0.name) && SetupPackageCompatibility.isDigest($0.originalManifestSHA256)
            }),
            startupPermitted == Array(Set(startupPermitted)).sorted(),
            Set(startupPermitted).isSubset(of: Set(instances.map(\.name))),
            recoveryReason.map({ $0.utf8.count <= 4096 }) ?? true
        else {
            throw SetupError("Invalid protected Linux package transaction state.")
        }
        guard instances.isEmpty || original != nil else {
            throw SetupError("Configured instances lack their original package commitment.")
        }
        if [.awaitingUnpack, .configuring, .committed].contains(phase) {
            guard incoming != nil else { throw SetupError("Package phase lacks its incoming commitment.") }
        }
        try original?.validate()
        try incoming?.validate()
        try observed?.validate()
        try owner?.validate()
        if phase == .configuring {
            guard incoming != nil, owner != nil else {
                throw SetupError("Configuring package lacks its payload/live-owner commitment.")
            }
        } else if !startupPermitted.isEmpty || owner != nil {
            throw SetupError("Package startup permit exists outside its configuring operation.")
        }
    }
    static func validInstance(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.first != "-" && value.last != "-"
            && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }
    }
}

/// Linux kernel identity of the finite configure owner. PID alone is never a live authorization.
/// A hard-killed configure cannot authorize a later start, but this witness does not stop a daemon
/// that already started. Normal observed failure explicitly stops units in the transaction code.
struct SetupPackageOwner: Codable, Equatable {
    let pid: Int32
    let startTicks: UInt64
    let bootID: String
    func validate() throws {
        guard pid > 1, startTicks > 0, let boot = UUID(uuidString: bootID),
            boot.uuidString.lowercased() == bootID
        else { throw SetupError("Invalid package configure owner identity.") }
    }
    static func current() throws -> Self {
        try read(pid: getpid())
    }
    func isLive() -> Bool { (try? Self.read(pid: pid)) == self }
    static func read(pid: Int32) throws -> Self {
        #if os(Linux)
            guard pid > 1 else { throw SetupError("Invalid package configure PID.") }
            func bounded(_ path: String, limit: Int) throws -> String {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit, let text = String(data: data, encoding: .utf8) else {
                    throw SetupError("Kernel process identity exceeds its bound.")
                }
                return text
            }
            func birth(_ text: String) throws -> UInt64 {
                guard let end = text.lastIndex(of: ")"), let start = text.firstIndex(of: "("),
                    text[..<start].trimmingCharacters(in: .whitespaces) == String(pid)
                else {
                    throw SetupError("Kernel process PID differs.")
                }
                let fields = text[text.index(after: end)...].split(whereSeparator: { $0 == " " || $0 == "\n" }
                )
                guard fields.count > 19, fields[0] != "Z", let ticks = UInt64(fields[19]), ticks > 0 else {
                    throw SetupError("Cannot establish package configure process birth.")
                }
                return ticks
            }
            let path = "/proc/" + String(pid) + "/"
            let before = try birth(bounded(path + "stat", limit: 16_384))
            let status = try bounded(path + "status", limit: 65_536)
            let after = try birth(bounded(path + "stat", limit: 16_384))
            guard before == after,
                let uid = status.split(separator: "\n").first(where: { $0.hasPrefix("Uid:") })
            else {
                throw SetupError("Package configure owner changed during observation.")
            }
            let uids = uid.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst()
            guard uids.count == 4, uids.allSatisfy({ $0 == "0" }) else {
                throw SetupError("Package configure owner is not a root process.")
            }
            let ticks = before
            let boot = try bounded("/proc/sys/kernel/random/boot_id", limit: 128).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let value = Self(pid: pid, startTicks: ticks, bootID: boot)
            try value.validate()
            return value
        #else
            throw SetupError("Linux kernel process identity is unavailable on this platform.")
        #endif
    }
}

extension SetupEngine {
    var packageStateURL: URL { roots.configuration.appendingPathComponent("package-transaction.json") }

    func readPackageState() throws -> SetupPackageState? {
        guard exists(packageStateURL) else { return nil }
        try requireOwned(packageStateURL, uid: 0, directory: false)
        guard try fileSize(packageStateURL) <= SetupPackageState.maximumBytes else {
            throw SetupError("Protected package transaction exceeds its bound.")
        }
        let bytes = try Data(contentsOf: packageStateURL)
        let required: Set<String> = ["profile", "operationID", "phase", "instances", "startupPermitted"]
        let allowed = required.union(["original", "incoming", "observed", "owner", "recoveryReason"])
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowed),
            let instances = object["instances"] as? [[String: Any]],
            instances.allSatisfy({
                Set($0.keys) == [
                    "name", "originalManifestSHA256", "wasRunning", "wasEnabled", "embeddingWasRunning",
                    "authenticationWasRunning",
                ]
            })
        else {
            throw SetupError("Unknown protected package transaction fields.")
        }
        if let owner = object["owner"], !(owner is NSNull) {
            guard let fields = owner as? [String: Any], Set(fields.keys) == ["pid", "startTicks", "bootID"]
            else {
                throw SetupError("Unknown package configure owner fields.")
            }
        }
        for key in ["original", "incoming", "observed"] {
            if let descriptor = object[key], !(descriptor is NSNull) {
                _ = try SetupPackageCompatibility.decode(
                    JSONSerialization.data(
                        withJSONObject: descriptor, options: [.sortedKeys, .withoutEscapingSlashes]))
            }
        }
        let state = try JSONDecoder().decode(SetupPackageState.self, from: bytes)
        try state.validate()
        return state
    }
    func writePackageState(_ state: SetupPackageState) throws {
        try state.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(state)
        guard bytes.count <= SetupPackageState.maximumBytes else {
            throw SetupError("Package transaction exceeds its bound.")
        }
        try writeProtected(bytes, to: packageStateURL, mode: 0o600)
        try syncPeerReceipt(packageStateURL)
    }
    func requireNoPendingPackageMutation() throws {
        if roots.platform == .linux, let state = try readPackageState(), state.pending {
            throw SetupError(
                "Package transaction is pending; finish package configuration or guarded package recovery before this mutation."
            )
        }
    }
    func capturePackageDescriptor(_ url: URL) throws -> SetupPackageCompatibility {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SetupError("Cannot open package compatibility descriptor safely.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            info.st_size > 0, info.st_size <= SetupPackageCompatibility.maximumBytes,
            info.st_nlink == 1, !trustedOwnership || info.st_uid == 0 && info.st_mode & 0o077 == 0
        else {
            throw SetupError("Package descriptor must be a bounded protected regular file.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + count <= SetupPackageCompatibility.maximumBytes else {
                throw SetupError("Cannot capture bounded package descriptor.")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, info.st_dev == after.st_dev, info.st_ino == after.st_ino,
            info.st_size == after.st_size, info.st_uid == after.st_uid, info.st_mode == after.st_mode,
            info.st_nlink == after.st_nlink, data.count == Int(info.st_size),
            ManagedPeerFile(bytes: data, metadata: info).same(ManagedPeerFile(bytes: data, metadata: after)),
            tractanda_peer_configuration_no_mutation_acl(fd) == 0
        else {
            throw SetupError("Package descriptor changed during capture.")
        }
        return try SetupPackageCompatibility.decode(data)
    }
}
