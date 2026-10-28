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
        guard tractanda_durable_sync(fd) == 0 else { throw FileMetadataError.posix(errno) }
        try StoreCheckpoint.syncDirectory(root)
        guard tractanda_durable_sync(fd) == 0 else { throw FileMetadataError.posix(errno) }
    }
    static func remove(root: URL, name: String, afterUnlink: () throws -> Void = {}) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            throw TractandaError("invalidConfiguration", "Invalid local configuration key.")
        }
        let owner = tractanda_uid()
        _ = try ItemStore.personalWorkgroupUpgradeRequirement(root: root, ownerUID: owner)
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw FileMetadataError.posix(errno) }
        defer { close(directory) }
        let fence = openat(directory, CanonicalReaderRequirement.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fence >= 0 else { throw FileMetadataError.posix(errno) }
        defer { close(fence) }
        var rootMetadata = stat()
        var fenceMetadata = stat()
        guard fstat(directory, &rootMetadata) == 0, fstat(fence, &fenceMetadata) == 0,
            rootMetadata.st_uid == owner, rootMetadata.st_mode & 0o777 == 0o700,
            fenceMetadata.st_uid == owner, fenceMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            fenceMetadata.st_mode & 0o777 == 0o600, fenceMetadata.st_nlink == 1,
            fenceMetadata.st_dev == rootMetadata.st_dev
        else {
            throw TractandaError(
                "invalidPersonalProfile",
                "Cleanup requires the retained same-filesystem private reader fence.")
        }
        if unlinkat(directory, name, 0) != 0, errno != ENOENT {
            throw FileMetadataError.posix(errno)
        }
        guard fsync(directory) == 0 else { throw FileMetadataError.posix(errno) }
        try afterUnlink()
        // Even ENOENT may follow an uncertain earlier unlink. Flush the actual root
        // filesystem through its retained regular fence file before acknowledging cleanup.
        guard tractanda_durable_sync(fence) == 0 else { throw FileMetadataError.posix(errno) }
    }
}
