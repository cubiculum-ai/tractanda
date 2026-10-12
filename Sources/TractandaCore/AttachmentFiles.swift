import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Native clients stream caller-selected files; the server never receives filesystem paths.
public enum AttachmentFiles {
    public static let chunkBytes = 262_144
    public static let maximumFileBytes: Int64 = .max
    private static func openSource(_ url: URL) throws -> (FileHandle, stat) {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw TractandaError(
                "fileReadFailed", "Cannot open a regular source file without following a symlink.")
        }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            metadata.st_size >= 0, metadata.st_size <= maximumFileBytes
        else {
            close(fd)
            throw TractandaError(
                "invalidAttachment", "Source must be a regular file with an addressable byte count.")
        }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), metadata)
    }
    /// Caller-local retained regular source; its receipt persists hash/size, never device/inode.
    public final class Source {
        public let byteCount: Int64
        public let sha256: String
        public let filename: String
        private let file: FileHandle
        private let metadata: stat
        public init(url: URL) throws {
            let (file, metadata) = try AttachmentFiles.openSource(url)
            do {
                var hash = SHA256()
                var offset: Int64 = 0
                let count = Int64(metadata.st_size)
                while offset < count {
                    let bytes = try Self.readChunk(
                        file: file, metadata: metadata, offset: offset,
                        limit: Int(min(Int64(AttachmentFiles.chunkBytes), count - offset)))
                    hash.update(data: bytes)
                    offset += Int64(bytes.count)
                }
                try Self.check(file: file, metadata: metadata, sentinel: true)
                self.file = file
                self.metadata = metadata
                byteCount = count
                sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
                filename = url.lastPathComponent
            } catch {
                try? file.close()
                throw error
            }
        }
        deinit { try? file.close() }
        public func chunk(offset: Int64, limit: Int = AttachmentFiles.chunkBytes) throws -> Data {
            try Self.readChunk(file: file, metadata: metadata, offset: offset, limit: limit)
        }
        public func verifyUnchanged() throws {
            try Self.check(file: file, metadata: metadata, sentinel: true)
        }
        private static func same(_ lhs: stat, _ rhs: stat) -> Bool {
            #if canImport(Darwin)
                let sameTime =
                    lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                    && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
                    && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                    && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
            #else
                let sameTime =
                    lhs.st_mtim.tv_sec == rhs.st_mtim.tv_sec
                    && lhs.st_mtim.tv_nsec == rhs.st_mtim.tv_nsec
                    && lhs.st_ctim.tv_sec == rhs.st_ctim.tv_sec
                    && lhs.st_ctim.tv_nsec == rhs.st_ctim.tv_nsec
            #endif
            return sameTime && lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
                && lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode
                && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid
        }
        private static func check(file: FileHandle, metadata: stat, sentinel: Bool = false) throws {
            try Task.checkCancellation()
            var current = stat()
            guard fstat(file.fileDescriptor, &current) == 0, same(current, metadata) else {
                throw TractandaError("fileChanged", "Source changed during a bounded hash/read.")
            }
            if sentinel {
                var byte: UInt8 = 0
                while true {
                    let read = pread(file.fileDescriptor, &byte, 1, metadata.st_size)
                    if read < 0, errno == EINTR {
                        try Task.checkCancellation()
                        continue
                    }
                    guard read == 0 else {
                        throw TractandaError("fileChanged", "Source EOF differs from its initial size.")
                    }
                    break
                }
            }
        }
        private static func readChunk(file: FileHandle, metadata: stat, offset: Int64, limit: Int) throws
            -> Data
        {
            guard offset >= 0, offset <= Int64(metadata.st_size),
                (1...AttachmentFiles.chunkBytes).contains(limit)
            else {
                throw TractandaError("invalidArguments", "Use an addressable bounded source chunk.")
            }
            try check(file: file, metadata: metadata)
            let expected = Int(min(Int64(limit), Int64(metadata.st_size) - offset))
            var bytes = [UInt8](repeating: 0, count: expected)
            var count = 0
            while count < expected {
                try Task.checkCancellation()
                let next = bytes.withUnsafeMutableBytes {
                    pread(
                        file.fileDescriptor, $0.baseAddress!.advanced(by: count), expected - count,
                        off_t(offset + Int64(count)))
                }
                if next < 0, errno == EINTR { continue }
                guard next > 0 else {
                    throw TractandaError("fileChanged", "Source ended before its initial size.")
                }
                count += next
            }
            try check(file: file, metadata: metadata)
            return Data(bytes)
        }
    }
    public static func attach(
        client: ItemClient, source: URL, itemID: String, expectedRevisionID: String,
        operationID: String, mediaType: String = "application/octet-stream", filename: String? = nil
    ) throws -> AttachmentCommitResult {
        let input = try Source(url: source)
        let count = input.byteCount
        let digest = input.sha256
        let upload = try client.beginAttachment(
            AttachmentUploadRequest(
                itemID: itemID, expectedRevisionID: expectedRevisionID, operationID: operationID,
                filename: filename ?? source.lastPathComponent, mediaType: mediaType, byteCount: count,
                sha256: digest))
        if let result = upload.committed { return result }
        guard let id = upload.uploadID, upload.chunkBytes == chunkBytes,
            upload.offset >= 0, upload.offset <= count
        else {
            throw TractandaError("protocolError", "Invalid upload continuation.")
        }
        var offset = upload.offset
        while offset < count {
            let bytes = try input.chunk(offset: offset)
            let next = try client.appendAttachment(uploadID: id, offset: offset, data: bytes)
            guard next == offset + Int64(bytes.count) else {
                throw TractandaError("protocolError", "Invalid upload offset.")
            }
            offset = next
        }
        try input.verifyUnchanged()
        return try client.finishAttachment(uploadID: id)
    }
    private static func requireCapacity(at directory: URL, bytes: Int) throws {
        var capacity = statvfs()
        guard statvfs(directory.path, &capacity) == 0 else {
            throw TractandaError("resourceLimit", "Cannot determine filesystem-available bytes.")
        }
        let block = UInt64(capacity.f_frsize)
        let blocks = UInt64(capacity.f_bavail)
        let available = blocks.multipliedReportingOverflow(by: block)
        guard !available.overflow, available.partialValue >= 1024 * 1024 * 1024 + UInt64(bytes) else {
            throw TractandaError("resourceLimit", "Export requires a 1 GiB filesystem-available reserve.")
        }
    }
    public static func export(
        client: ItemClient, itemID: String, attachmentID: String, destination: URL, revisionID: String? = nil
    ) throws -> AttachmentDescriptor {
        let list = try client.listAttachments(itemID: itemID, revisionID: revisionID)
        guard let descriptor = list.attachments.first(where: { $0.attachmentID == attachmentID }) else {
            throw TractandaError("notFound", "Attachment is unavailable.")
        }
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".tractanda-export-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw TractandaError("fileWriteFailed", "Cannot create private export staging.")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: temporary)
        }
        var hash = SHA256()
        var offset: Int64 = 0
        repeat {
            let result = try client.attachmentContent(
                itemID: itemID, revisionID: list.revisionID,
                attachmentID: attachmentID, offset: offset, limit: chunkBytes)
            guard result.attachment == descriptor, result.offset == offset,
                result.data.count <= chunkBytes, result.nextOffset == offset + Int64(result.data.count),
                result.nextOffset <= descriptor.byteCount,
                result.isComplete == (result.nextOffset == descriptor.byteCount),
                !result.data.isEmpty || result.isComplete
            else {
                throw TractandaError("protocolError", "Invalid original content continuation.")
            }
            try requireCapacity(at: parent, bytes: result.data.count)
            try file.write(contentsOf: result.data)
            hash.update(data: result.data)
            offset = result.nextOffset
            if result.isComplete { break }
        } while true
        guard offset == descriptor.byteCount,
            hash.finalize().map({ String(format: "%02x", $0) }).joined() == descriptor.sha256
        else {
            throw TractandaError(
                "attachmentIntegrity", "Export digest or byte count mismatch; destination was not published.")
        }
        guard fsync(fd) == 0, link(temporary.path, destination.path) == 0 else {
            throw TractandaError(
                "fileWriteFailed", "Cannot publish export; destination must not already exist.")
        }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { if parentFD >= 0 { close(parentFD) } }
        guard parentFD >= 0, fsync(parentFD) == 0 else {
            throw TractandaError(
                "fileWriteFailed", "Export was published but directory durability is uncertain.")
        }
        return descriptor
    }
}
