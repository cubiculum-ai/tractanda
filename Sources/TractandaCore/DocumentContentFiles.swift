import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Descriptor-relative, owner-private canonical I/O. This layer carries no item authority.
final class DocumentContentFiles: @unchecked Sendable {
    var afterDirectoryRenameForTesting: (() throws -> Void)?
    var beforePublicationSyncForTesting: (() throws -> Void)?
    private let stagingQuota: StagingByteQuota?
    private let root: URL
    private let ownerUID: UInt32
    private let minimumFreeBytes: Int64
    private let availableBytes: (@Sendable () throws -> UInt64)?
    init(
        root: URL, ownerUID: UInt32, minimumFreeBytes: Int64,
        availableBytes: (@Sendable () throws -> UInt64)? = nil, stagingQuota: StagingByteQuota? = nil
    ) {
        self.stagingQuota = stagingQuota
        self.root = root
        self.ownerUID = ownerUID
        self.minimumFreeBytes = minimumFreeBytes
        self.availableBytes = availableBytes
    }
    private func reserve(_ additional: Int) throws {
        let free: UInt64
        if let availableBytes {
            do { free = try availableBytes() } catch {
                throw TractandaError("resourceLimit", "Cannot inspect document filesystem capacity.")
            }
        } else {
            var capacity = statvfs()
            guard statvfs(root.path, &capacity) == 0, capacity.f_frsize > 0 else {
                throw TractandaError("resourceLimit", "Cannot inspect document filesystem capacity.")
            }
            let product = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
            guard !product.overflow else {
                throw TractandaError("resourceLimit", "Document filesystem capacity overflowed.")
            }
            free = product.partialValue
        }
        guard minimumFreeBytes >= 0 else {
            throw TractandaError("resourceLimit", "Invalid document capacity reserve.")
        }
        let required = UInt64(minimumFreeBytes).addingReportingOverflow(UInt64(additional))
        guard !required.overflow, free >= required.partialValue else {
            throw TractandaError(
                "resourceLimit", "Document write would cross its configured filesystem-available reserve.")
        }
    }
    private func directories(_ components: [String], create: Bool) throws -> [Int32] {
        guard root.path.hasPrefix("/"), root.path != "/",
            components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
            })
        else {
            throw TractandaError("documentIntegrity", "Unsafe document path.")
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Cannot open canonical document root.") }
        var chain = [fd]
        do {
            try validateDirectory(fd)
            for name in components {
                let parent = chain.last!
                var child = name.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if child < 0, errno == ENOENT, create {
                    try reserve(4096)
                    let result = name.withCString { mkdirat(parent, $0, 0o700) }
                    guard result == 0 || errno == EEXIST, fsync(parent) == 0 else {
                        throw failure("Cannot synchronize document directory.")
                    }
                    child = name.withCString {
                        openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                }
                guard child >= 0 else { throw failure("Document directory is missing or unsafe.") }
                try validateDirectory(child)
                chain.append(child)
            }
            return chain
        } catch {
            closeAll(chain)
            throw error
        }
    }
    private func validateDirectory(_ fd: Int32) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            value.st_uid == ownerUID, value.st_mode & 0o077 == 0
        else {
            throw TractandaError(
                "documentIntegrity", "Document directories must be private and service-owned.")
        }
    }
    private func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors.reversed() { _ = close(descriptor) }
    }
    func createUniqueDirectory(_ path: [String]) throws {
        let chain = try directories(Array(path.dropLast()), create: true)
        defer { closeAll(chain) }
        let name = path.last!
        let result = name.withCString { mkdirat(chain.last!, $0, 0o700) }
        guard result == 0, fsync(chain.last!) == 0 else {
            throw failure("Cannot create unique document stage.")
        }
    }
    func writeImmutable(
        _ data: Data, path: [String], maximumBytes: Int = DocumentContentStore.maximumPageBytes
    ) throws {
        guard !path.isEmpty, data.count <= maximumBytes else {
            throw TractandaError("resourceLimit", "Document write exceeds its page window.")
        }
        let chain = try directories(Array(path.dropLast()), create: true)
        defer { closeAll(chain) }
        try reserve(data.count)
        try stagingQuota?.charge(data.count, path: path)
        var dependencyPublished = false
        let temporary = ".dependency-" + UUID().uuidString + ".tmp"
        let fd = temporary.withCString {
            openat(chain.last!, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else {
            stagingQuota?.refund(data.count, path: path)
            throw failure("Cannot create immutable document dependency.")
        }
        defer {
            _ = close(fd)
            let removed = temporary.withCString { unlinkat(chain.last!, $0, 0) }
            if !dependencyPublished, removed == 0 { stagingQuota?.refund(data.count, path: path) }
            _ = fsync(chain.last!)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                try reserve(min(262_144, bytes.count - offset))
                let written = write(
                    fd, bytes.baseAddress!.advanced(by: offset), min(262_144, bytes.count - offset))
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw failure("Cannot write document dependency.") }
                offset += written
            }
        }
        guard fchmod(fd, 0o400) == 0, fsync(fd) == 0 else {
            throw failure("Cannot seal document dependency.")
        }
        let published = temporary.withCString { source in
            path.last!.withCString { linkat(chain.last!, source, chain.last!, $0, 0) }
        }
        dependencyPublished = published == 0
        guard published == 0, fsync(chain.last!) == 0 else {
            throw failure("Cannot publish sealed document dependency without replacement.")
        }
    }
    /// Atomically replaces one bounded operational checkpoint; canonical dependencies stay immutable.
    func replaceJobCheckpoint(_ data: Data, path: [String], jobID: String) throws {
        guard data.count <= 16 * 1024, path == ["document-jobs", jobID, "record.json"] else {
            throw TractandaError("resourceLimit", "Invalid bounded job checkpoint path.")
        }
        let old = try readIfPresent(path: path, maximumBytes: 16 * 1024)
        // Reject file capacity before creating a new intent directory.
        try reserve(data.count)
        let chain = try directories(Array(path.dropLast()), create: true)
        defer { closeAll(chain) }
        try stagingQuota?.chargeJobCheckpoint(data.count, path: path, id: jobID)
        let temporary = ".checkpoint-" + UUID().uuidString + ".tmp"
        let fd = temporary.withCString {
            openat(chain.last!, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else {
            stagingQuota?.refund(data.count, path: path)
            throw failure("Cannot create job checkpoint.")
        }
        var replaced = false
        defer {
            _ = close(fd)
            let removed = temporary.withCString { unlinkat(chain.last!, $0, 0) }
            if !replaced, removed == 0, fsync(chain.last!) == 0 {
                stagingQuota?.refund(data.count, path: path)
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure("Cannot write job checkpoint.") }
                offset += count
            }
        }
        guard fchmod(fd, 0o400) == 0, fsync(fd) == 0,
            temporary.withCString({ source in
                path.last!.withCString { renameat(chain.last!, source, chain.last!, $0) }
            }) == 0
        else { throw failure("Cannot replace job checkpoint.") }
        replaced = true
        guard fsync(chain.last!) == 0 else { throw failure("Cannot synchronize job checkpoint.") }
        stagingQuota?.jobCheckpointReplaced(oldBytes: old?.count ?? 0, path: path)
    }
    /// Missing first-write metadata is disposable only when its owned directory is provably empty.
    /// A race adding any entry causes ENOTEMPTY and preserves that recovery material.
    func removeEmptyJobDirectory(id: String) throws -> Bool {
        guard UUID(uuidString: id)?.version1Components != nil else {
            throw TractandaError("documentIntegrity", "Invalid empty job directory identity.")
        }
        let chain: [Int32]
        do { chain = try directories(["document-jobs", id], create: false) } catch let error as TractandaError
            where error.osError == ENOENT
        { return true }
        defer { closeAll(chain) }
        let duplicate = dup(chain.last!)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { _ = close(duplicate) }
            throw failure("Cannot inspect failed job directory.")
        }
        defer { _ = closedir(stream) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw failure("Cannot inspect failed job directory.") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { return false }
        }
        let parent = chain[chain.count - 2]
        let removed = id.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
        if removed < 0, errno == ENOTEMPTY || errno == EEXIST { return false }
        guard removed == 0 || errno == ENOENT, fsync(parent) == 0 else {
            throw failure("Cannot synchronize failed empty job directory removal.")
        }
        stagingQuota?.release(path: ["document-jobs", id, "record.json"])
        return true
    }
    func removeJobSession(jobID: String, sessionID: String, chargedBytes: Int) throws {
        guard UUID(uuidString: jobID)?.version1Components != nil,
            UUID(uuidString: sessionID)?.version1Components != nil, chargedBytes >= 0
        else {
            throw TractandaError("documentIntegrity", "Invalid private native session disposal.")
        }
        let path = ["document-jobs", jobID, "sessions", sessionID]
        try removeTree(path)
        stagingQuota?.release(path: path + ["binding.json"])
    }
    func removeUncommittedContent(_ path: [String]) throws {
        guard path.count == 8, path.prefix(2) == ["documents", "content"],
            UUID(uuidString: path.last!)?.version1Components != nil
        else {
            throw TractandaError("documentIntegrity", "Refusing invalid uncommitted content disposal.")
        }
        try removeTree(path)
    }
    func removeJobPublicationReceipt(id: String) throws {
        guard UUID(uuidString: id)?.version1Components != nil else {
            throw TractandaError("documentIntegrity", "Invalid job publication receipt identity.")
        }
        let path = ["documents", ".staging", id + ".publication.json"]
        let chain = try directories(Array(path.dropLast()), create: false)
        defer { closeAll(chain) }
        let result = path.last!.withCString { unlinkat(chain.last!, $0, 0) }
        guard result == 0 || errno == ENOENT, fsync(chain.last!) == 0 else {
            throw failure("Cannot dispose job publication receipt.")
        }
        stagingQuota?.release(path: path)
    }
    /// Descriptor-relative, bounded-depth deletion of explicitly discarded private work.
    func removePrivateTree(_ path: [String]) throws {
        guard
            (path.count == 3 && path.prefix(2) == ["documents", ".staging"])
                || (path.count == 2 && path[0] == "document-jobs"),
            UUID(uuidString: path.last!)?.version1Components != nil
        else {
            throw TractandaError("documentIntegrity", "Refusing non-stage disposal.")
        }
        try removeTree(path)
    }
    private func removeTree(_ path: [String], releaseAccounting: Bool = true) throws {
        let chain: [Int32]
        do { chain = try directories(Array(path.dropLast()), create: false) } catch let error
            as TractandaError where error.osError == ENOENT
        { return }
        defer { closeAll(chain) }
        func remove(_ parent: Int32, _ name: String, depth: Int) throws {
            guard depth <= 8 else { throw failure("Stage disposal exceeds bounded depth.") }
            var info = stat()
            let result = name.withCString { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
            if result < 0, errno == ENOENT { return }
            guard result == 0, info.st_uid == ownerUID, info.st_mode & 0o077 == 0 else {
                throw failure("Unsafe stage disposal entry.")
            }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let child = name.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw failure("Cannot open discarded stage.") }
                defer { _ = close(child) }
                let duplicate = dup(child)
                guard duplicate >= 0, let stream = fdopendir(duplicate) else {
                    if duplicate >= 0 { _ = close(duplicate) }
                    throw failure("Cannot enumerate discarded stage.")
                }
                defer { _ = closedir(stream) }
                while true {
                    errno = 0
                    guard let entry = readdir(stream) else {
                        guard errno == 0 else { throw failure("Cannot enumerate discarded stage.") }
                        break
                    }
                    let component = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                            String(cString: $0)
                        }
                    }
                    if component == "." || component == ".." { continue }
                    try Task.checkCancellation()
                    try remove(child, component, depth: depth + 1)
                }
                guard fsync(child) == 0, name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else {
                    throw failure("Cannot remove discarded stage directory.")
                }
            } else {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                    name.withCString({ unlinkat(parent, $0, 0) }) == 0
                else {
                    throw failure("Cannot remove discarded stage file.")
                }
            }
            guard fsync(parent) == 0 else { throw failure("Cannot synchronize stage disposal.") }
        }
        try remove(chain.last!, path.last!, depth: 0)
        if releaseAccounting { stagingQuota?.release(path: path) }
    }
    func read(path: [String], maximumBytes: Int) throws -> Data {
        guard let bytes = try readIfPresent(path: path, maximumBytes: maximumBytes) else {
            throw failure("Canonical document dependency is missing.")
        }
        return bytes
    }
    func readIfPresent(path: [String], maximumBytes: Int) throws -> Data? {
        let chain: [Int32]
        do { chain = try directories(Array(path.dropLast()), create: false) } catch let error
            as TractandaError where error.osError == ENOENT
        { return nil }
        defer { closeAll(chain) }
        let fd = path.last!.withCString { openat(chain.last!, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure("Canonical document dependency is missing or unsafe.") }
        defer { _ = close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            before.st_uid == ownerUID,
            before.st_mode & 0o777 == 0o400, before.st_size > 0, before.st_size <= maximumBytes
        else {
            throw TractandaError(
                "documentIntegrity", "Canonical document dependency is unsafe or exceeds its window.")
        }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let amount = pread(
                    fd, bytes.baseAddress!.advanced(by: offset), min(262_144, bytes.count - offset),
                    off_t(offset))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw failure("Document dependency ended early.") }
                offset += amount
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_mode == after.st_mode, before.st_uid == after.st_uid, before.st_size == after.st_size
        else {
            throw TractandaError("documentIntegrity", "Document dependency changed while reading.")
        }
        return data
    }
    func publishDirectory(_ stage: [String], to destination: [String]) throws {
        let source = try directories(Array(stage.dropLast()), create: false)
        defer { closeAll(source) }
        let target = try directories(Array(destination.dropLast()), create: true)
        defer { closeAll(target) }
        let staged = try directories(stage, create: false)
        defer { closeAll(staged) }
        guard fsync(staged.last!) == 0 else { throw failure("Cannot synchronize complete document stage.") }
        let result = stage.last!.withCString { old in
            destination.last!.withCString {
                tractanda_publish_directory_at(source.last!, old, target.last!, $0)
            }
        }
        guard result == 0 else {
            throw failure("Cannot publish immutable document tree without replacement.")
        }
        try afterDirectoryRenameForTesting?()
        try synchronizePublication(stage, to: destination)
    }
    func synchronizePublication(_ stage: [String], to destination: [String]) throws {
        let source = try directories(Array(stage.dropLast()), create: false)
        defer { closeAll(source) }
        let target = try directories(Array(destination.dropLast()), create: false)
        defer { closeAll(target) }
        try beforePublicationSyncForTesting?()
        guard fsync(target.last!) == 0, fsync(source.last!) == 0 else {
            throw failure("Cannot synchronize document tree publication.")
        }
        stagingQuota?.release(path: stage)
    }
    func synchronizeDirectory(_ path: [String]) throws {
        let chain = try directories(path, create: false)
        defer { closeAll(chain) }
        guard fsync(chain.last!) == 0 else { throw failure("Cannot synchronize private recovery directory.") }
    }
    private func failure(_ message: String) -> TractandaError {
        TractandaError("documentIntegrity", "\(message) \(String(cString: strerror(errno)))", osError: errno)
    }
}

extension DocumentContentFiles {
    func ensurePrivateDirectory(_ path: [String]) throws {
        let chain = try directories(path, create: true)
        defer { closeAll(chain) }
        try synchronizeDirectory(path)
    }
}

extension DocumentContentFiles {
    func removeOfflineCorpus(_ id: String) throws {
        guard UUID(uuidString: id)?.version1Components != nil else {
            throw TractandaError("documentIntegrity", "Invalid offline corpus work identity.")
        }
        // Only this independently accounted derived spool is removed/refunded after parent sync.
        try removeTree(["documents", ".staging", "corpus-" + id])
    }
}
