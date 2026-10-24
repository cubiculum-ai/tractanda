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

    /// Reopens a selected inventory locator through the same no-follow descriptor chain.
    /// Recovery writes only the resulting derived catalogue, never the original envelope.
    static func selectedRecoveryRow(
        _ expected: PersonalRecoveryInventory.Record, path: String, root: URL, ownerUID: UInt32,
        readBudget: (Int) throws -> Void = { _ in }, activity: (() throws -> Void)? = nil
    ) throws -> (ItemIndex.CatalogueRow, Revision) {
        let descriptors = try openDescriptorChain(root: root, relativePath: path)
        defer { for descriptor in descriptors.reversed() { _ = close(descriptor) } }
        guard let descriptor = descriptors.last else { throw PooledCanonicalRecordError.invalidPath }
        let value = try readForInventory(
            path: path, descriptor: descriptor, ownerUID: ownerUID, readBudget: readBudget, progress: activity
        )
        guard value.digest == expected.sha256, value.record.metadata.size == expected.byteCount else {
            throw PooledCanonicalRecordError.digestMismatch
        }
        let revision = value.record.revision
        let metadata = value.record.metadata
        guard revision.itemID == expected.itemID, revision.revisionID == expected.revisionID,
            let actor = revision.fields["actor"]?.string,
            let operation = revision.fields["operationID"]?.string,
            let created = revision.fields["createdAt"]?.dateString
        else { throw PooledCanonicalRecordError.identityMismatch }
        let feedback =
            try revision.fields["learningFeedback"]?.map?.values.map {
                try LearningFeedback($0).revisionID
            } ?? []
        return (
            ItemIndex.CatalogueRow(
                revisionID: revision.revisionID, itemID: revision.itemID, path: path,
                parentID: revision.supersedes, actor: actor, operationID: operation,
                size: metadata.size, inode: metadata.inode, uid: metadata.uid, mode: metadata.mode,
                modificationSeconds: metadata.modificationSeconds,
                modificationNanoseconds: metadata.modificationNanoseconds, digest: value.digest,
                createdAt: created, feedbackRevisionIDs: feedback, modifiedAt: revision.modifiedAt,
                provenance: try revision.provenance), revision
        )
    }

    /// Read-only inventory of administrator-selected canonical item files, independent of an old index.
    /// This checks structural content and custody, not historical peer admission.
    static func readForInventory(
        path: String, descriptor: Int32, ownerUID: UInt32,
        readBudget: (Int) throws -> Void, progress: (() throws -> Void)? = nil
    ) throws
        -> (record: Self, digest: Data)
    {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 8, components[7].hasSuffix(".tractanda") else {
            throw PooledCanonicalRecordError.invalidPath
        }
        let itemID = String(components[6])
        let revisionID = String(components[7].dropLast(".tractanda".count))
        guard CanonicalRecordPath.validate(path, itemID: itemID, revisionID: revisionID) else {
            throw PooledCanonicalRecordError.invalidPath
        }
        let before = try metadata(for: descriptor)
        guard before.type == .regular, before.uid == ownerUID, before.mode & 0o077 == 0 else {
            throw PooledCanonicalRecordError.unsafePermissions
        }
        guard before.size <= UInt64(maximumRecordBytes) else {
            throw PooledCanonicalRecordError.sizeLimit
        }
        try readBudget(Int(before.size))
        // The enumerator lends this descriptor; never reopen a possibly replaced path.
        let bytes = try readAll(
            descriptor: descriptor, expectedSize: before.size, maximumBytes: maximumRecordBytes,
            progress: progress)
        guard try metadata(for: descriptor) == before else {
            throw PooledCanonicalRecordError.metadataChanged
        }
        let revision = try RecordCodec.decode(bytes)
        try ItemSemantics.validate(revision)
        guard revision.itemID == itemID, revision.revisionID == revisionID else {
            throw PooledCanonicalRecordError.identityMismatch
        }
        return (
            Self(revision: revision, metadata: before, archived: false, metadataDrifted: false),
            Data(SHA256.hash(data: bytes))
        )
    }

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
            revision.fields["createdAt"]?.dateString == row.createdAt,
            revision.modifiedAt == row.modifiedAt, try revision.provenance == row.provenance
        else { throw PooledCanonicalRecordError.identityMismatch }
        return Self(
            revision: revision, metadata: after, archived: archived,
            metadataDrifted: metadataDrifted)
    }

    private static func canonicalRelativePath(row: ItemIndex.CatalogueRow) -> String? {
        CanonicalRecordPath.validate(row.path, itemID: row.itemID, revisionID: row.revisionID)
            ? row.path : nil
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
                openat(descriptors[descriptors.count - 1], $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            }
            guard file >= 0 else { throw PooledCanonicalRecordError.openFailed(errno) }
            descriptors.append(file)
            return descriptors
        } catch {
            for descriptor in descriptors.reversed() { _ = close(descriptor) }
            throw error
        }
    }

    static func inventoryMetadata(for descriptor: Int32) throws -> FileMetadata {
        try metadata(for: descriptor)
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

    private static func readAll(
        descriptor: Int32, expectedSize: UInt64, maximumBytes: Int, progress: (() throws -> Void)? = nil
    ) throws -> Data {
        guard expectedSize <= UInt64(maximumBytes), expectedSize <= UInt64(Int.max) else {
            throw PooledCanonicalRecordError.sizeLimit
        }
        var data = Data()
        data.reserveCapacity(Int(expectedSize))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // Never read beyond the retained descriptor's charged size if a concurrent writer grows it.
        // The caller's final metadata comparison still rejects mutation during this bounded read.
        while data.count < Int(expectedSize) {
            let window = min(buffer.count, Int(expectedSize) - data.count)
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                #if canImport(Darwin)
                    Darwin.read(descriptor, rawBuffer.baseAddress, window)
                #else
                    Glibc.read(descriptor, rawBuffer.baseAddress, window)
                #endif
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw PooledCanonicalRecordError.readFailed(errno)
            }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else { throw PooledCanonicalRecordError.sizeLimit }
            data.append(contentsOf: buffer.prefix(count))
            try progress?()
        }
        guard UInt64(data.count) == expectedSize else { throw PooledCanonicalRecordError.metadataChanged }
        return data
    }
}
