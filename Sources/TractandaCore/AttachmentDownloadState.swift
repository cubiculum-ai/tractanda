import CTractandaPlatform
import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Caller-local retained download quota; independent of the server's upload quota.
public struct AttachmentDownloadPolicy: Sendable {
    public var maximumStagedBytes: Int64
    public var minimumFreeBytes: Int64
    public init(
        maximumStagedBytes: Int64 = 8 * 1024 * 1024 * 1024,
        minimumFreeBytes: Int64 = 1024 * 1024 * 1024
    ) {
        self.maximumStagedBytes = maximumStagedBytes
        self.minimumFreeBytes = minimumFreeBytes
    }
}

/// No transport credentials or operation receipts: this is only an immutable byte binding.
struct DownloadBinding: Codable, Equatable {
    let storeID: String
    let objectIdentity: Data
    let byteCount: Int64
    let sha256: String
    let destination: String
}

/// One private payload and constant-size checkpoint, reusable by other immutable object adapters.
enum ResumableByteDownload {
    static let chunkBytes = 262_144
    static let bookkeepingBytes: Int64 = 64 * 1024
    struct Part {
        let storeID: String
        let offset: Int64
        let data: Data
    }
    struct Progress: Codable {
        let version: Int
        let binding: DownloadBinding
        let offset: Int64
        let prefixSHA256: String
    }
    struct Hooks {
        var availableBytes: (() throws -> UInt64)?
        var afterCheckpoint: ((Int64) throws -> Void)?
        var afterPublication: (() throws -> Void)?
        var beforeCheckpointRename: ((Int64) throws -> Void)?
        var beforeInitializationPublication: (() throws -> Void)?
    }

    static func run(
        binding: DownloadBinding, stage: URL, destination: URL, policy: AttachmentDownloadPolicy,
        hooks: Hooks = Hooks(), authorize: () throws -> Void, read: (Int64, Int) throws -> Part
    ) throws {
        guard UUID(uuidString: binding.storeID)?.version1Components != nil,
            binding.objectIdentity.count <= 8192, binding.byteCount >= 0,
            binding.sha256.count == 64,
            binding.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
            binding.destination == destination.standardizedFileURL.path,
            stage.standardizedFileURL != destination.standardizedFileURL,
            policy.minimumFreeBytes >= 0
        else { throw error("downloadBinding", "Invalid download binding or staging quota.") }
        guard policy.maximumStagedBytes >= bookkeepingBytes,
            binding.byteCount <= policy.maximumStagedBytes - bookkeepingBytes
        else { throw error("resourceLimit", "Original and download bookkeeping exceed the staging quota.") }
        try authorize()  // Includes already-published retries.
        let stageParent = try directory(stage.deletingLastPathComponent())
        defer { close(stageParent) }
        let stageName = try component(stage.lastPathComponent)
        try capacity(stageParent, additional: Int(bookkeepingBytes), policy: policy, hooks: hooks)
        var existing = stat()
        if fstatat(stageParent, stageName, &existing, AT_SYMLINK_NOFOLLOW) < 0 {
            guard errno == ENOENT else { throw failure("Cannot inspect download stage.") }
            try initialize(parent: stageParent, name: stageName, binding: binding, hooks: hooks)
        }
        let stageFD = openat(stageParent, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw failure("Cannot open private download stage.") }
        defer { close(stageFD) }
        try validate(stageFD, directory: true)
        let lock = openat(stageFD, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw failure("Cannot open download lock.") }
        defer { close(lock) }
        try validate(lock)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw error("downloadBusy", "Another process owns this download stage.")
        }
        // Unknown material is never adopted or deleted.
        try POSIXDirectory.withEntries(at: stage) { name in
            guard ["lock", "payload", "checkpoint.json", "checkpoint.next"].contains(name) else {
                throw error("downloadIntegrity", "Download stage contains unknown retained material.")
            }
            return true
        }
        let destinationParent = try directory(destination.deletingLastPathComponent(), privateMode: false)
        defer { close(destinationParent) }
        let destinationName = try component(destination.lastPathComponent)
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC
        let payload = openat(stageFD, "payload", flags, 0o600)
        guard payload >= 0 else { throw failure("Cannot open retained download payload.") }
        defer { close(payload) }
        try validate(payload)
        var hash = SHA256()
        var offset: Int64 = 0
        do {
            let progress = try loadProgress(stageFD)
            guard progress.version == 1, progress.binding == binding,
                progress.offset >= 0, progress.offset <= binding.byteCount
            else {
                throw error("downloadBinding", "Retained download belongs to another source or destination.")
            }
            var metadata = stat()
            guard fstat(payload, &metadata) == 0, metadata.st_size >= progress.offset,
                metadata.st_size <= policy.maximumStagedBytes - bookkeepingBytes
            else {
                throw error(
                    "downloadIntegrity", "Retained payload is shorter than its checkpoint or over quota.")
            }
            while offset < progress.offset {
                let bytes = try localChunk(
                    payload, offset: offset, count: min(chunkBytes, Int(progress.offset - offset)))
                hash.update(data: bytes)
                offset += Int64(bytes.count)
            }
            guard digest(hash) == progress.prefixSHA256 else {
                throw error("downloadIntegrity", "Retained download prefix differs from its checkpoint.")
            }
            if metadata.st_size > progress.offset {
                guard ftruncate(payload, off_t(progress.offset)) == 0, fsync(payload) == 0 else {
                    throw failure("Cannot discard uncheckpointed owned payload tail.")
                }
            }
            try discardCheckpointTemporary(stageFD, binding: binding)
        }
        while offset < binding.byteCount {
            try Task.checkCancellation()
            let part = try read(offset, Int(min(Int64(chunkBytes), binding.byteCount - offset)))
            guard part.storeID == binding.storeID, part.offset == offset,
                !part.data.isEmpty, part.data.count <= chunkBytes,
                Int64(part.data.count) <= binding.byteCount - offset
            else { throw error("downloadIntegrity", "Invalid immutable byte continuation.") }
            try capacity(
                stageFD, additional: part.data.count + Int(bookkeepingBytes), policy: policy, hooks: hooks)
            try writeAll(part.data, descriptor: payload, offset: offset)
            hash.update(data: part.data)
            offset += Int64(part.data.count)
            guard fsync(payload) == 0 else { throw failure("Cannot synchronize download bytes.") }
            try checkpoint(
                Progress(version: 1, binding: binding, offset: offset, prefixSHA256: digest(hash)),
                directory: stageFD, beforeRename: hooks.beforeCheckpointRename)
            try hooks.afterCheckpoint?(offset)
        }
        guard digest(hash) == binding.sha256 else {
            throw error("downloadIntegrity", "Complete original differs from its expected digest.")
        }
        try Task.checkCancellation()
        // Hash the actual retained bytes, not only the bytes returned by the transport.
        // Cooperative transfer locks do not make caller-owned storage immutable.
        var finalMetadata = stat()
        guard fstat(payload, &finalMetadata) == 0, finalMetadata.st_size == binding.byteCount else {
            throw error("downloadIntegrity", "Complete retained payload length changed.")
        }
        var finalHash = SHA256()
        var verified: Int64 = 0
        while verified < binding.byteCount {
            let bytes = try localChunk(
                payload, offset: verified, count: Int(min(Int64(chunkBytes), binding.byteCount - verified)))
            finalHash.update(data: bytes)
            verified += Int64(bytes.count)
        }
        var afterHash = stat()
        guard digest(finalHash) == binding.sha256, fstat(payload, &afterHash) == 0,
            unchanged(finalMetadata, afterHash)
        else { throw error("downloadIntegrity", "Complete retained payload changed during verification.") }
        try authorize()  // Current ACL immediately before caller-local publication or completed retry.
        guard fstat(payload, &afterHash) == 0, unchanged(finalMetadata, afterHash) else {
            throw error("downloadIntegrity", "Verified retained payload changed before publication.")
        }
        var namedPayload = stat()
        guard fstatat(stageFD, "payload", &namedPayload, AT_SYMLINK_NOFOLLOW) == 0,
            namedPayload.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            namedPayload.st_dev == afterHash.st_dev, namedPayload.st_ino == afterHash.st_ino,
            unchanged(afterHash, namedPayload)
        else { throw error("downloadIntegrity", "Retained payload pathname changed before publication.") }
        if linkat(stageFD, "payload", destinationParent, destinationName, 0) != 0 {
            guard errno == EEXIST else { throw failure("Cannot publish download without replacement.") }
            // Recover only our own previously published hard link, not an unrelated matching file.
            var source = stat()
            var target = stat()
            guard fstat(payload, &source) == 0,
                fstatat(destinationParent, destinationName, &target, AT_SYMLINK_NOFOLLOW) == 0,
                target.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                source.st_dev == target.st_dev, source.st_ino == target.st_ino
            else { throw error("downloadCollision", "Destination already exists and is not this download.") }
        }
        try hooks.afterPublication?()
        guard fsync(destinationParent) == 0 else {
            throw failure("Published download durability is uncertain.")
        }
    }

    private static func error(_ code: String, _ message: String) -> TractandaError {
        TractandaError(code, message)
    }
    private static func failure(_ message: String) -> TractandaError {
        TractandaError("downloadIO", message, osError: errno)
    }
    private static func component(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw error("downloadBinding", "Unsafe download path component.")
        }
        return name
    }
    private static func directory(_ url: URL, privateMode: Bool = true) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Cannot open download parent directory.") }
        do { try validate(fd, directory: true, privateMode: privateMode) } catch {
            close(fd)
            throw error
        }
        return fd
    }
    private static func validate(_ fd: Int32, directory: Bool = false, privateMode: Bool = true) throws {
        var value = stat()
        guard fstat(fd, &value) == 0,
            value.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG),
            value.st_uid == getuid(), !privateMode || value.st_mode & 0o077 == 0
        else {
            throw error("downloadIntegrity", "Download storage must have safe type, owner and permissions.")
        }
    }
    private static func capacity(
        _ fd: Int32, additional: Int, policy: AttachmentDownloadPolicy, hooks: Hooks
    ) throws {
        let free: UInt64
        if let available = hooks.availableBytes {
            free = try available()
        } else {
            var value = statvfs()
            guard fstatvfs(fd, &value) == 0, value.f_frsize > 0 else {
                throw error("resourceLimit", "Cannot determine filesystem-available download capacity.")
            }
            let count = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_frsize))
            guard !count.overflow else { throw error("resourceLimit", "Download capacity overflowed.") }
            free = count.partialValue
        }
        let required = UInt64(policy.minimumFreeBytes).addingReportingOverflow(UInt64(additional))
        guard !required.overflow, free >= required.partialValue else {
            throw error("resourceLimit", "Download would cross the filesystem-available reserve.")
        }
    }
    private static func digest(_ hash: SHA256) -> String {
        hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func unchanged(_ before: stat, _ after: stat) -> Bool {
        #if canImport(Darwin)
            let timestamps =
                before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
                && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
                && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        #else
            let timestamps =
                before.st_mtim.tv_sec == after.st_mtim.tv_sec
                && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec
                && before.st_ctim.tv_sec == after.st_ctim.tv_sec
                && before.st_ctim.tv_nsec == after.st_ctim.tv_nsec
        #endif
        return before.st_size == after.st_size && before.st_mode == after.st_mode && timestamps
    }
    private static func localChunk(_ fd: Int32, offset: Int64, count: Int) throws -> Data {
        try Task.checkCancellation()
        var bytes = [UInt8](repeating: 0, count: count)
        var consumed = 0
        while consumed < count {
            let read = bytes.withUnsafeMutableBytes {
                pread(
                    fd, $0.baseAddress!.advanced(by: consumed), count - consumed,
                    off_t(offset + Int64(consumed)))
            }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { throw error("downloadIntegrity", "Retained download read ended early.") }
            consumed += read
        }
        return Data(bytes)
    }
    private static func writeAll(_ data: Data, descriptor: Int32, offset: Int64) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                try Task.checkCancellation()
                let count = pwrite(
                    descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written,
                    off_t(offset + Int64(written)))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure("Cannot write download bytes.") }
                written += count
            }
        }
    }
    private static func loadProgress(_ directory: Int32) throws -> Progress {
        let fd = openat(directory, "checkpoint.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw failure("Retained stage has no valid checkpoint; preserve it for recovery.")
        }
        defer { close(fd) }
        try validate(fd)
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_size > 0, value.st_size <= 16 * 1024 else {
            throw error("downloadIntegrity", "Invalid download checkpoint size.")
        }
        return try JSON.decode(Progress.self, localChunk(fd, offset: 0, count: Int(value.st_size)))
    }
    private static func initialize(parent: Int32, name: String, binding: DownloadBinding, hooks: Hooks) throws
    {
        let temporary = ".download-init-" + UUID().uuidString
        guard mkdirat(parent, temporary, 0o700) == 0, fsync(parent) == 0 else {
            throw failure("Cannot create private download initializer.")
        }
        let fd = openat(parent, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Cannot open private download initializer.") }
        defer { close(fd) }
        let payload = openat(fd, "payload", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard payload >= 0 else { throw failure("Cannot initialize download payload.") }
        defer { close(payload) }
        guard fsync(payload) == 0 else { throw failure("Cannot synchronize initial download payload.") }
        try checkpoint(
            Progress(version: 1, binding: binding, offset: 0, prefixSHA256: digest(SHA256())), directory: fd)
        try hooks.beforeInitializationPublication?()
        guard tractanda_publish_directory_at(parent, temporary, parent, name) == 0, fsync(parent) == 0 else {
            throw failure("Cannot publish initialized download stage without replacement.")
        }
    }
    private static func discardCheckpointTemporary(_ directory: Int32, binding: DownloadBinding) throws {
        let fd = openat(directory, "checkpoint.next", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return }
        guard fd >= 0 else { throw failure("Cannot inspect retained checkpoint temporary.") }
        defer { close(fd) }
        try validate(fd)
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_size >= 0, value.st_size <= 16 * 1024 else {
            throw error("downloadIntegrity", "Checkpoint temporary exceeds its reserved bound.")
        }
        if value.st_size > 0,
            let progress = try? JSON.decode(
                Progress.self, localChunk(fd, offset: 0, count: Int(value.st_size))),
            progress.binding != binding
        {
            throw error("downloadBinding", "Checkpoint temporary belongs to another download.")
        }
        guard unlinkat(directory, "checkpoint.next", 0) == 0, fsync(directory) == 0 else {
            throw failure("Cannot retire proven checkpoint temporary.")
        }
    }
    private static func checkpoint(
        _ progress: Progress, directory: Int32, beforeRename: ((Int64) throws -> Void)? = nil
    ) throws {
        let bytes = try JSON.encode(progress)
        guard bytes.count <= 16 * 1024 else {
            throw error("resourceLimit", "Download checkpoint exceeds its bound.")
        }
        let name = "checkpoint.next"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Cannot create download checkpoint.") }
        defer { close(fd) }
        try writeAll(bytes, descriptor: fd, offset: 0)
        guard fsync(fd) == 0 else { throw failure("Cannot synchronize checkpoint temporary.") }
        try beforeRename?(progress.offset)
        guard
            renameat(directory, name, directory, "checkpoint.json") == 0,
            fsync(directory) == 0
        else { throw failure("Cannot synchronize download checkpoint.") }
    }
}
