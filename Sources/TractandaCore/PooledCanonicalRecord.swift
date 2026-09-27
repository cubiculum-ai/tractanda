import CTractandaPlatform
import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

enum PooledCanonicalRecordError: Error, Equatable, Sendable {
    case invalidPath
    case openFailed(Int32)
    case metadataUnavailable(Int32)
    case metadataChanged
    case sizeLimit
    case readFailed(Int32)
    case digestMismatch
    case identityMismatch
    case unsafePermissions
}

/// A verified immutable record plus descriptor metadata for the caller's final recheck.
/// This helper does not consult caller access state; callers must authorize before reading.
struct PooledCanonicalRecord: Sendable {
    let revision: Revision
    let metadata: FileMetadata
    let archived: Bool
    let metadataDrifted: Bool

    static let maximumRecordBytes = 8 * 1024 * 1024

    static func read(
        row: ItemIndex.CatalogueRow, root: URL, ownerUID: UInt32,
        maximumBytes: Int = maximumRecordBytes
    ) throws -> Self {
        guard maximumBytes > 0, maximumBytes <= maximumRecordBytes,
            let relativePath = canonicalRelativePath(row: row),
            relativePath == row.path
        else { throw PooledCanonicalRecordError.invalidPath }

        let descriptors = try openDescriptorChain(root: root, relativePath: relativePath)
        defer { for descriptor in descriptors.reversed() { _ = close(descriptor) } }
        guard let descriptor = descriptors.last else { throw PooledCanonicalRecordError.invalidPath }

        let before = try metadata(for: descriptor)
        guard before.type == .regular else { throw PooledCanonicalRecordError.metadataChanged }
        guard before.size <= UInt64(maximumBytes) else {
            throw PooledCanonicalRecordError.sizeLimit
        }
        let metadataDrifted = !matches(before, row: row)

        let absolutePath = root.standardizedFileURL.appendingPathComponent(relativePath).path
        let archiveStatus = absolutePath.withCString { tractanda_path_read_only($0) }
        guard archiveStatus >= 0 else {
            throw PooledCanonicalRecordError.metadataUnavailable(errno)
        }
        let archived = archiveStatus == 1
        guard archived || (before.uid == ownerUID && before.mode & 0o077 == 0) else {
            throw PooledCanonicalRecordError.unsafePermissions
        }

        let bytes = try readAll(descriptor: descriptor, expectedSize: before.size, maximumBytes: maximumBytes)
        let after = try metadata(for: descriptor)
        guard after == before else { throw PooledCanonicalRecordError.metadataChanged }
        guard Data(SHA256.hash(data: bytes)) == row.digest else {
            throw PooledCanonicalRecordError.digestMismatch
        }
        let revision = try RecordCodec.decode(bytes)
        try ItemSemantics.validate(revision)
        try Identifier.validate(revision.itemID)
        try Identifier.validate(revision.revisionID)
        guard revision.itemID == row.itemID, revision.revisionID == row.revisionID,
            revision.supersedes == row.parentID,
            revision.fields["actor"]?.string == row.actor,
            revision.fields["operationID"]?.string == row.operationID,
            revision.fields["createdAt"]?.dateString == row.createdAt
        else { throw PooledCanonicalRecordError.identityMismatch }
        return Self(
            revision: revision, metadata: after, archived: archived,
            metadataDrifted: metadataDrifted)
    }

    private static func canonicalRelativePath(row: ItemIndex.CatalogueRow) -> String? {
        guard (try? Identifier.validate(row.itemID)) != nil,
            (try? Identifier.validate(row.revisionID)) != nil,
            let created = Timestamp.parse(row.createdAt)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: created)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
            let hour = parts.hour, let minute = parts.minute
        else { return nil }
        return String(
            format: "items/%04d/%02d/%02d/%02d/%02d/%@/%@.tractanda",
            year, month, day, hour, minute, row.itemID, row.revisionID)
    }

    /// Opens the canonical root and every record path component without following symlinks.
    private static func openDescriptorChain(root: URL, relativePath: String) throws -> [Int32] {
        let rootPath = root.standardizedFileURL.path
        guard rootPath.hasPrefix("/"), !rootPath.utf8.contains(0) else {
            throw PooledCanonicalRecordError.invalidPath
        }
        let recordComponents = relativePath.split(separator: "/").map(String.init)
        guard rootPath != "/", recordComponents.count == 8,
            recordComponents[0] == "items",
            recordComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw PooledCanonicalRecordError.invalidPath }

        let rootDescriptor = rootPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else { throw PooledCanonicalRecordError.openFailed(errno) }
        var descriptors: [Int32] = [rootDescriptor]
        do {
            for component in recordComponents.dropLast() {
                let next = component.withCString {
                    openat(
                        descriptors[descriptors.count - 1], $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw PooledCanonicalRecordError.openFailed(errno) }
                descriptors.append(next)
            }
            guard let filename = recordComponents.last else {
                throw PooledCanonicalRecordError.invalidPath
            }
            let file = filename.withCString {
                openat(descriptors[descriptors.count - 1], $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard file >= 0 else { throw PooledCanonicalRecordError.openFailed(errno) }
            descriptors.append(file)
            return descriptors
        } catch {
            for descriptor in descriptors.reversed() { _ = close(descriptor) }
            throw error
        }
    }

    private static func metadata(for descriptor: Int32) throws -> FileMetadata {
        var raw = stat()
        guard fstat(descriptor, &raw) == 0 else {
            throw PooledCanonicalRecordError.metadataUnavailable(errno)
        }
        #if canImport(Darwin)
            let seconds = Int64(raw.st_mtimespec.tv_sec)
            let nanoseconds = Int32(raw.st_mtimespec.tv_nsec)
        #else
            let seconds = Int64(raw.st_mtim.tv_sec)
            let nanoseconds = Int32(raw.st_mtim.tv_nsec)
        #endif
        guard raw.st_size >= 0 else { throw PooledCanonicalRecordError.metadataChanged }
        return FileMetadata(
            mode: UInt32(raw.st_mode), uid: UInt32(raw.st_uid), gid: UInt32(raw.st_gid),
            size: UInt64(raw.st_size), inode: UInt64(raw.st_ino), device: UInt64(raw.st_dev),
            modificationSeconds: seconds, modificationNanoseconds: nanoseconds)
    }

    private static func matches(_ metadata: FileMetadata, row: ItemIndex.CatalogueRow) -> Bool {
        metadata.size == row.size && metadata.inode == row.inode && metadata.uid == row.uid
            && metadata.mode == row.mode
            && metadata.modificationSeconds == row.modificationSeconds
            && metadata.modificationNanoseconds == row.modificationNanoseconds
    }

    private static func readAll(descriptor: Int32, expectedSize: UInt64, maximumBytes: Int) throws -> Data {
        guard expectedSize <= UInt64(maximumBytes), expectedSize <= UInt64(Int.max) else {
            throw PooledCanonicalRecordError.sizeLimit
        }
        var data = Data()
        data.reserveCapacity(Int(expectedSize))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                #if canImport(Darwin)
                    Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
                #else
                    Glibc.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
                #endif
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw PooledCanonicalRecordError.readFailed(errno)
            }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else { throw PooledCanonicalRecordError.sizeLimit }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard UInt64(data.count) == expectedSize else { throw PooledCanonicalRecordError.metadataChanged }
        return data
    }
}
