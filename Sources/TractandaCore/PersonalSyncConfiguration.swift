import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

enum PersonalSyncConfiguration {
    static let membershipName = ".personal-membership.json"
    static let pendingName = ".personal-membership.pending.json"
    static let baselineName = ".personal-baseline.json"
    static func read<T: Decodable>(
        _ type: T.Type, root: URL, name: String, ownerUID: UInt32,
        maximumBytes: Int = 128 * 1024
    ) throws -> T? {
        guard
            let bytes = try CanonicalReaderRequirement.localConfigurationBytes(
                root: root, name: name, ownerUID: ownerUID, maximumBytes: maximumBytes)
        else { return nil }
        return try JSON.decode(type, bytes)
    }
    static func membership(root: URL, ownerUID: UInt32) throws -> PersonalMembershipConfiguration? {
        let value = try read(
            PersonalMembershipConfiguration.self, root: root, name: membershipName, ownerUID: ownerUID)
        try value?.validate()
        return value
    }
    /// Current operational replacement, not an append-only history or item-authority certificate.
    static func write<T: Encodable>(_ value: T, root: URL, name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            throw TractandaError("invalidConfiguration", "Invalid local configuration key.")
        }
        let bytes = try JSON.encode(value)
        guard bytes.count <= 128 * 1024 else {
            throw TractandaError("resourceLimit", "Local configuration exceeds its bound.")
        }
        try PrivateConfiguration.write(bytes, to: root.appendingPathComponent(name))
        let fd = open(root.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FileMetadataError.posix(errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw FileMetadataError.posix(errno) }
        try StoreCheckpoint.syncDirectory(root)
    }
    static func remove(root: URL, name: String) throws {
        guard !name.contains("/"), !name.contains("\0") else {
            throw TractandaError("invalidConfiguration", "Invalid local configuration key.")
        }
        if unlink(root.appendingPathComponent(name).path) != 0, errno != ENOENT {
            throw FileMetadataError.posix(errno)
        }
        try StoreCheckpoint.syncDirectory(root)
    }
}
