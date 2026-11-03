import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Physical placement only. The installer owns physical conversion; normal runtime
/// never discovers, translates or publishes a legacy pathname.
enum CanonicalPhysicalLayout {
    static let fileName = "canonical-layout.json"
    static let pendingFileName = "canonical-layout.pending.json"
    static let capability = "tractanda.physical-layout.flat-items.v1"
    static let minimumReaderLevel = 19
    private struct Marker: Codable, Equatable {
        let profile: String
        let layout: String
    }
    private static let current = Marker(
        profile: "tractanda.physical-layout.v1", layout: "flat-items-visible-attachments.v1")

    static func requireNoMigration(_ root: URL) throws {
        do {
            _ = try FileMetadata.read(at: root.appendingPathComponent(pendingFileName))
        } catch FileMetadataError.posix(let code) where code == ENOENT { return }
        throw TractandaError("canonicalLayoutMigrationRequired",
            "The installer must finish the pending physical-layout transition before opening this store.")
    }

    /// Caller owns the lifetime writer. Only a genuinely empty root can acquire its initial
    /// marker here. Existing raw content uses the explicit selected-content validation path.
    static func prepareOpening(_ root: URL, ownerUID: UInt32) throws {
        try requireNoMigration(root)
        try recoverInitialMarker(root, ownerUID: ownerUID)
        if try load(root, ownerUID: ownerUID) { return }
        var populated = false
        try POSIXDirectory.withEntries(at: root) { name in
            if name != ".writer.lock" { populated = true }
            return !populated
        }
        guard !populated else { throw migrationRequired() }
        try publishMarker(root, ownerUID: ownerUID)
    }

    /// Use only after a complete structural inventory passed, including all item paths. This
    /// preserves recovery from raw items and owned payloads without an old runtime database.
    static func completeSelectedContent(_ root: URL, ownerUID: UInt32) throws {
        try requireNoMigration(root)
        try recoverInitialMarker(root, ownerUID: ownerUID, validatedSelectedContent: true)
        if try !load(root, ownerUID: ownerUID) { try publishMarker(root, ownerUID: ownerUID) }
    }

    static func migrationRequired() -> TractandaError {
        TractandaError("canonicalLayoutMigrationRequired",
            "This nonempty store lacks the current physical layout. Use the .17 installer migration; never initialize it as an empty store.")
    }

    private static func load(_ root: URL, ownerUID: UInt32) throws -> Bool {
        guard let bytes = try CanonicalReaderRequirement.localConfigurationBytes(
            root: root, name: fileName, ownerUID: ownerUID, maximumBytes: 4096)
        else { return false }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(object.keys) == ["profile", "layout"],
            try JSON.decode(Marker.self, bytes) == current
        else { throw migrationRequired() }
        return true
    }

    /// Resume only our bounded initial constant metadata, before any canonical content exists.
    /// Every byte of an interrupted write must be a prefix of the exact current marker. Other
    /// files, links, names, custody or content never authorize repair or deletion.
    static func isInitialMarkerStage(_ name: String) -> Bool {
        guard name.hasPrefix(".physical-layout-"), name.hasSuffix(".stage") else { return false }
        let id = String(name.dropFirst(".physical-layout-".count).dropLast(".stage".count))
        return (try? Identifier.validate(id)) != nil
    }

    private static func recoverInitialMarker(
        _ root: URL, ownerUID: UInt32, validatedSelectedContent: Bool = false
    ) throws {
        var stage: String?
        var otherEntries = false
        try POSIXDirectory.withEntries(at: root) { name in
            if name == ".writer.lock" { return true }
            if isInitialMarkerStage(name) {
                guard stage == nil else { throw migrationRequired() }
                stage = name
                return true
            }
            otherEntries = true
            return true
        }
        guard let name = stage else { return }
        let committed = try load(root, ownerUID: ownerUID)
        guard committed || !otherEntries || validatedSelectedContent else { throw migrationRequired() }
        let expected = try JSON.encode(current)
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw FileMetadataError.posix(errno) }
        defer { close(directory) }
        let descriptor = openat(directory, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw migrationRequired() }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
            before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_uid == ownerUID,
            before.st_mode & 0o7777 == 0o600, before.st_nlink == 1,
            before.st_size >= 0, before.st_size <= expected.count,
            tractanda_peer_configuration_no_mutation_acl(descriptor) == 0
        else { throw migrationRequired() }
        var bytes = Data(count: Int(before.st_size))
        try bytes.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = read(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw migrationRequired() }
                offset += count
            }
        }
        var named = stat(), after = stat()
        guard expected.prefix(bytes.count) == bytes,
            !committed || bytes == expected,
            fstat(descriptor, &after) == 0,
            fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_size == after.st_size, before.st_mode == after.st_mode,
            before.st_uid == after.st_uid, after.st_nlink == 1,
            named.st_dev == after.st_dev, named.st_ino == after.st_ino,
            named.st_size == after.st_size, named.st_mode == after.st_mode,
            named.st_uid == after.st_uid, named.st_nlink == 1
        else { throw migrationRequired() }
        if committed {
            guard unlinkat(directory, name, 0) == 0, fsync(directory) == 0 else {
                throw FileMetadataError.posix(errno)
            }
            return
        }
        // The descriptor offset is the validated prefix length. A second interruption leaves
        // another validated prefix, and exclusive rename never replaces an existing marker.
        try expected.withUnsafeBytes { raw in
            var offset = bytes.count
            while offset < raw.count {
                let count = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw FileMetadataError.posix(errno) }
                offset += count
            }
        }
        guard tractanda_durable_sync(descriptor) == 0,
            tractanda_publish_directory_at(directory, name, directory, fileName) == 0,
            fsync(directory) == 0
        else { throw FileMetadataError.posix(errno) }
    }

    private static func publishMarker(_ root: URL, ownerUID: UInt32) throws {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw FileMetadataError.posix(errno) }
        defer { close(directory) }
        let temporary = ".physical-layout-" + Identifier.make() + ".stage"
        let descriptor = openat(directory, temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FileMetadataError.posix(errno) }
        defer {
            close(descriptor)
            _ = unlinkat(directory, temporary, 0)
        }
        guard fchown(descriptor, ownerUID, gid_t.max) == 0, fchmod(descriptor, 0o600) == 0 else {
            throw FileMetadataError.posix(errno)
        }
        let bytes = try JSON.encode(current)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw FileMetadataError.posix(errno) }
                offset += count
            }
        }
        guard tractanda_durable_sync(descriptor) == 0,
            tractanda_publish_directory_at(directory, temporary, directory, fileName) == 0,
            fsync(directory) == 0
        else { throw FileMetadataError.posix(errno) }
    }
}
