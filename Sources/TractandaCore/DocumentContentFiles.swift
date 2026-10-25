import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Descriptor-relative, owner-private canonical I/O. This layer carries no item authority.
final class DocumentContentFiles: @unchecked Sendable {
    /// Narrow test-only byte observation at successful pread; callbacks never receive data.
    private final class ReadObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var active: (root: String, callback: @Sendable ([String], Int) -> Void)?
        func withObserver<T>(
            root: URL, callback: @escaping @Sendable ([String], Int) -> Void,
            body: () throws -> T
        ) throws -> T {
            lock.lock()
            guard active == nil else {
                lock.unlock()
                throw TractandaError("testObservationBusy", "Read observation is already scoped.")
            }
            active = (root.standardizedFileURL.resolvingSymlinksInPath().path, callback)
            lock.unlock()
            defer {
                lock.lock()
                active = nil
                lock.unlock()
            }
            return try body()
        }
        func record(root: URL, path: [String], bytes: Int) {
            lock.lock()
            let current = active
            lock.unlock()
            guard let current, root.standardizedFileURL.resolvingSymlinksInPath().path == current.root else {
                return
            }
            current.callback(path, bytes)
        }
    }
    private static let readObservation = ReadObservation()
    static func observeReadsForTesting<T>(
        root: URL,
        observation: @escaping @Sendable ([String], Int) -> Void, body: () throws -> T
    ) throws -> T {
        try readObservation.withObserver(root: root, callback: observation, body: body)
    }
    /// Shared by descriptor readers; report only bytes returned by a successful read syscall.
    static func recordReadForTesting(root: URL, path: [String], bytes: Int) {
        readObservation.record(root: root, path: path, bytes: bytes)
    }
    var afterDirectoryRenameForTesting: (() throws -> Void)?
    var beforePublicationSyncForTesting: (() throws -> Void)?
    var afterPeerPartRenameForTesting: (() throws -> Void)?
    private let stagingQuota: StagingByteQuota?
    private let root: URL
    // Borrowed only within the caller's synchronous writer-lock scope. No pathname reopen.
    private let rootDescriptor: Int32?
    private let ownerUID: UInt32
    private let minimumFreeBytes: Int64
    private let availableBytes: (@Sendable () throws -> UInt64)?
    struct FrozenPeerStage: Codable, Equatable {
        let stageID: String
        let reference: DocumentContentReference
    }
    private func stageIdentity(_ path: [String]) -> String? {
        guard path.count >= 3, path.prefix(2) == ["documents", ".staging"] else { return nil }
        var id = path[2]
        for suffix in [".publication.json", ".frozen.json"] where id.hasSuffix(suffix) {
            id = String(id.dropLast(suffix.count))
        }
        guard UUID(uuidString: id)?.version1Components != nil else { return nil }
        return id
    }
    func frozenPeerStage(_ stage: [String], readBudget: ((Int) throws -> Void)? = nil) throws
        -> FrozenPeerStage?
    {
        guard let id = stageIdentity(stage) else { return nil }
        guard
            let data = try readIfPresent(
                path: ["documents", ".staging", id + ".frozen.json"], maximumBytes: 4096,
                readBudget: readBudget)
        else { return nil }
        let value = try PeerPackage.decode(FrozenPeerStage.self, data, maximum: 4096)
        try value.reference.validate()
        guard value.stageID == id else { throw failure("Frozen document stage binding differs.") }
        return value
    }
    func requireMutableDocumentPath(_ path: [String]) throws {
        try CanonicalMaintenanceContext.deny(
            root: root, path: path, operation: "mutable document/private work")
        guard stageIdentity(path) != nil else { return }
        if try frozenPeerStage(path) != nil {
            throw TractandaError(
                "peerDocumentFrozen", "The verified peer document stage is closed to mutation.")
        }
    }
    func freezePeerStage(
        _ stage: [String], reference: DocumentContentReference, readBudget: ((Int) throws -> Void)? = nil
    ) throws {
        guard stage.count == 3, let id = stageIdentity(stage), stage.last == id else {
            throw failure("Invalid frozen document stage.")
        }
        try reference.validate()
        let value = FrozenPeerStage(stageID: id, reference: reference)
        if let old = try frozenPeerStage(stage, readBudget: readBudget) {
            guard old == value else { throw failure("Frozen document reference changed.") }
            try synchronizeDirectory(["documents", ".staging"])
        } else {
            try writeImmutable(
                try JSON.encode(value), path: ["documents", ".staging", id + ".frozen.json"],
                maximumBytes: 4096)
        }
    }
    init(
        root: URL, ownerUID: UInt32, minimumFreeBytes: Int64,
        availableBytes: (@Sendable () throws -> UInt64)? = nil, stagingQuota: StagingByteQuota? = nil,
        rootDescriptor: Int32? = nil
    ) {
        self.stagingQuota = stagingQuota
        self.root = root
        self.rootDescriptor = rootDescriptor
        self.ownerUID = ownerUID
        self.minimumFreeBytes = minimumFreeBytes
        self.availableBytes = availableBytes
    }
    private func reserve(_ additional: Int, descriptor: Int32? = nil) throws {
        let free: UInt64
        if let availableBytes {
            do { free = try availableBytes() } catch {
                throw TractandaError("resourceLimit", "Cannot inspect document filesystem capacity.")
            }
        } else {
            var capacity = statvfs()
            let result = descriptor.map { fstatvfs($0, &capacity) } ?? statvfs(root.path, &capacity)
            guard result == 0, capacity.f_frsize > 0 else {
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
    /// Resolve the filesystem actually receiving this write, including external indexes.
    func requireCapacity(_ additional: UInt64, at location: URL) throws {
        guard let count = Int(exactly: additional) else {
            throw TractandaError("resourceLimit", "Document capacity request overflowed.")
        }
        var parent = location
        while true {
            let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                defer { close(fd) }
                try validateDirectory(fd)
                try reserve(count, descriptor: fd)
                return
            }
            guard errno == ENOENT, parent.path != "/" else {
                throw failure("Cannot inspect document destination filesystem.")
            }
            parent.deleteLastPathComponent()
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
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let fd = rootDescriptor.map { openat($0, ".", flags) } ?? open(root.path, flags)
        guard fd >= 0 else { throw failure("Cannot open canonical document root.") }
        var chain = [fd]
        do {
            try validateDirectory(fd)
            var walked = [String]()
            for name in components {
                walked.append(name)
                let parent = chain.last!
                var child = name.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if child < 0, errno == ENOENT, create {
                    try CanonicalMaintenanceContext.deny(
                        root: root, path: walked, operation: "directory creation")
                    try reserve(4096, descriptor: parent)
                    let result = name.withCString { mkdirat(parent, $0, 0o700) }
                    guard result == 0 || errno == EEXIST, fsync(parent) == 0 else {
                        throw failure("Cannot synchronize document directory.")
                    }
                    child = name.withCString {
                        openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                }
                guard child >= 0 else { throw failure("Document directory is missing or unsafe.") }
                try validateDirectory(
                    child, allowReadOnlyArchive: !create && components.starts(with: ["documents", "content"]))
                chain.append(child)
            }
            return chain
        } catch {
            closeAll(chain)
            throw error
        }
    }
    private func isReadOnly(_ fd: Int32) -> Bool {
        var value = statvfs()
        return fstatvfs(fd, &value) == 0 && value.f_flag & UInt(ST_RDONLY) != 0
    }
    private func validateDirectory(_ fd: Int32, allowReadOnlyArchive: Bool = false) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            (allowReadOnlyArchive && isReadOnly(fd))
                || (value.st_uid == ownerUID && value.st_mode & 0o077 == 0)
        else {
            throw TractandaError(
                "documentIntegrity", "Document directories must be private and service-owned.")
        }
    }
    private func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors.reversed() { _ = close(descriptor) }
    }
    private func samePeerCheckpointTime(_ before: stat, _ after: stat) -> Bool {
        #if canImport(Darwin)
            return before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        #else
            return before.st_mtim.tv_sec == after.st_mtim.tv_sec
                && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec
        #endif
    }
    private func validatePeerCheckpointPath(_ path: [String]) throws {
        if path.count == 4, path.prefix(2) == ["authority", "sync-work"], path.last == "checkpoint.json" {
            _ = try AuthorityRecord.persistentID(.text(path[2]))
            return
        }
        if path.count == 5, path.prefix(2) == ["authority", "payloads"], path.last == "high-water.json" {
            return
        }
        guard path.count == 9, path.prefix(2) == ["authority", "document-transfers"],
            path[4] == "parts", path.last == "high-water.json",
            let role = PeerPackage.DocumentPart.Role(rawValue: path[5]),
            let level = Int(path[6]), String(level) == path[6],
            let ordinal = Int64(path[7]), String(ordinal) == path[7]
        else { throw TractandaError("documentIntegrity", "Invalid peer checkpoint path.") }
        for id in path[2...3] { _ = try AuthorityRecord.persistentID(.text(id)) }
        try PeerPackage.DocumentPart(role: role, level: level, ordinal: ordinal).validate()
    }
    func readPeerCheckpoint(path: [String], readBudget: ((Int) throws -> Void)? = nil) throws -> Data? {
        try validatePeerCheckpointPath(path)
        let chain: [Int32]
        do { chain = try directories(Array(path.dropLast()), create: false) } catch let error
            as TractandaError where error.osError == ENOENT
        { return nil }
        defer { closeAll(chain) }
        let fd = openat(chain.last!, path.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure("Cannot open peer operational checkpoint.") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            before.st_uid == ownerUID,
            before.st_mode & 0o777 == 0o600, before.st_size > 0, before.st_size <= 16 * 1024
        else { throw TractandaError("documentIntegrity", "Unsafe peer operational checkpoint.") }
        try readBudget?(Int(before.st_size))
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pread(
                    fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("Peer checkpoint read was truncated.") }
                offset += count
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_size == after.st_size, before.st_mode == after.st_mode, before.st_uid == after.st_uid,
            samePeerCheckpointTime(before, after)
        else { throw failure("Peer checkpoint changed during read.") }
        return data
    }
    /// Atomic replacement is restricted to private acknowledgment progress, never canonical data.
    func replacePeerCheckpoint(_ data: Data, path: [String], readBudget: ((Int) throws -> Void)? = nil) throws
    {
        try CanonicalMaintenanceContext.deny(root: root, path: path, operation: "canonical file write")
        guard data.count > 0, data.count <= 16 * 1024 else {
            throw TractandaError("resourceLimit", "Peer checkpoint exceeds its window.")
        }
        let old = try readPeerCheckpoint(path: path, readBudget: readBudget)
        let chain = try directories(Array(path.dropLast()), create: false)
        defer { closeAll(chain) }
        try reserve(data.count, descriptor: chain.last!)
        try stagingQuota?.charge(data.count, path: path)
        let temporary = ".peer-checkpoint-" + (try UUID.makeVersion1().uuidString.lowercased()) + ".tmp"
        let fd = openat(chain.last!, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            stagingQuota?.refund(data.count, path: path)
            throw failure("Cannot create peer checkpoint.")
        }
        var published = false
        defer {
            close(fd)
            let removed = unlinkat(chain.last!, temporary, 0)
            if !published && removed == 0 { stagingQuota?.refund(data.count, path: path) }
            _ = fsync(chain.last!)
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                try reserve(buffer.count - offset, descriptor: fd)
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("Cannot write peer checkpoint.") }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(chain.last!, temporary, chain.last!, path.last!) == 0 else {
            throw failure("Cannot publish peer checkpoint.")
        }
        published = true
        guard fsync(chain.last!) == 0 else {
            throw failure("Cannot synchronize peer checkpoint publication.")
        }
        stagingQuota?.refund(old?.count ?? 0, path: path)
    }

    func withDirectoryEntries(path: [String], _ visit: (String) throws -> Bool) throws {
        let chain: [Int32]
        do { chain = try directories(path, create: false) } catch let error as TractandaError
            where error.osError == ENOENT
        { return }
        defer { closeAll(chain) }
        try POSIXDirectory.withEntries(descriptor: chain.last!, body: visit)
    }
    func removePeerPayloadTree(_ path: [String]) throws {
        guard
            (path.count == 4 && path.prefix(2) == ["authority", "payloads"])
                || (path.count == 3 && path.prefix(2) == ["authority", "payload-work"])
        else {
            throw TractandaError("documentIntegrity", "Invalid private peer payload cleanup path.")
        }
        for id in path.dropFirst(2) { _ = try AuthorityRecord.persistentID(.text(id)) }
        try removeTree(path)
    }
    func removePeerDocumentPart(_ path: [String]) throws {
        guard path.count == 8, path.prefix(2) == ["authority", "document-transfers"], path[4] == "parts",
            let role = PeerPackage.DocumentPart.Role(rawValue: path[5]),
            let level = Int(path[6]), String(level) == path[6],
            let ordinal = Int64(path[7]), String(ordinal) == path[7]
        else { throw failure("Invalid private document cleanup address.") }
        for id in path[2...3] { _ = try AuthorityRecord.persistentID(.text(id)) }
        try PeerPackage.DocumentPart(role: role, level: level, ordinal: ordinal).validate()
        try removeTree(path)
    }
    func removeEmptyPeerDocumentDirectory(_ path: [String]) throws -> Bool {
        try CanonicalMaintenanceContext.deny(
            root: root, path: path, operation: "directory removal", onlyIfPresent: true)
        guard (4...7).contains(path.count), path.prefix(2) == ["authority", "document-transfers"] else {
            throw failure("Invalid private document cleanup directory.")
        }
        for id in path[2...3] { _ = try AuthorityRecord.persistentID(.text(id)) }
        var occupied = false
        try withDirectoryEntries(path: path) { _ in
            occupied = true
            return false
        }
        if occupied { return false }
        let chain: [Int32]
        do { chain = try directories(Array(path.dropLast()), create: false) } catch let error
            as TractandaError where error.osError == ENOENT
        { return true }
        defer { closeAll(chain) }
        let result = path.last!.withCString { unlinkat(chain.last!, $0, AT_REMOVEDIR) }
        guard result == 0 || errno == ENOENT, fsync(chain.last!) == 0 else {
            throw failure("Cannot synchronize private document cleanup.")
        }
        return true
    }
    /// Caller proved exact applied history and canonical publication before private disposal.
    func stepAppliedPeerDocumentStage(
        _ stage: [String], reference: DocumentContentReference, maximumEntries: Int
    ) throws -> (complete: Bool, used: Int) {
        try CanonicalMaintenanceContext.deny(
            root: root, path: stage, operation: "document stage cleanup", onlyIfPresent: true)
        guard stage.count == 3, stage.last == stageIdentity(stage), (1...128).contains(maximumEntries) else {
            throw failure("Invalid bounded applied document cleanup.")
        }
        if let frozen = try frozenPeerStage(stage), frozen.reference != reference {
            throw failure("Applied document cleanup reference differs.")
        }
        var remaining = maximumEntries
        func empty(_ path: [String], depth: Int) throws -> Bool {
            guard depth <= 5 else { throw failure("Applied document stage exceeds bounded depth.") }
            try withDirectoryEntries(path: path) { name in
                guard remaining > 0 else { return false }
                try Task.checkCancellation()
                let chain = try directories(path, create: false)
                defer { closeAll(chain) }
                var info = stat()
                guard name.withCString({ fstatat(chain.last!, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
                    info.st_uid == ownerUID, info.st_mode & 0o077 == 0
                else {
                    throw failure("Unsafe applied document cleanup entry.")
                }
                let directory = info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                if directory {
                    guard try empty(path + [name], depth: depth + 1) else { return false }
                    guard remaining > 0 else { return false }
                } else if info.st_mode & mode_t(S_IFMT) != mode_t(S_IFREG) {
                    throw failure("Unexpected applied document cleanup file type.")
                }
                guard name.withCString({ unlinkat(chain.last!, $0, directory ? AT_REMOVEDIR : 0) }) == 0,
                    fsync(chain.last!) == 0
                else {
                    throw failure("Cannot synchronize bounded document cleanup.")
                }
                remaining -= 1
                return remaining > 0
            }
            var occupied = false
            try withDirectoryEntries(path: path) { _ in
                occupied = true
                return false
            }
            return !occupied
        }
        let complete = try empty(stage, depth: 0)
        return (complete, maximumEntries - remaining)
    }
    func finishAppliedPeerDocumentStage(_ stage: [String], reference: DocumentContentReference) throws {
        guard stage.count == 3, let id = stageIdentity(stage), stage.last == id else {
            throw failure("Invalid applied document stage.")
        }
        var occupied = false
        try withDirectoryEntries(path: stage) { _ in
            occupied = true
            return false
        }
        guard !occupied else { throw failure("Applied document stage has pending bounded cleanup.") }
        try removeTree(stage, completingFrozenReference: reference)
        let marker = ["documents", ".staging", id + ".frozen.json"]
        if try CanonicalMaintenanceContext.removalIsNoOp(root: root, path: marker) { return }
        let chain = try directories(Array(marker.dropLast()), create: false)
        defer { closeAll(chain) }
        let result = marker.last!.withCString { unlinkat(chain.last!, $0, 0) }
        guard result == 0 || errno == ENOENT, fsync(chain.last!) == 0 else {
            throw failure("Cannot synchronize completed document barrier cleanup.")
        }
    }
    func removeAppliedPeerDocumentBinding(_ path: [String]) throws {
        guard path.count == 4, path.prefix(2) == ["authority", "document-transfers"] else {
            throw failure("Invalid applied document binding cleanup.")
        }
        for id in path[2...3] { _ = try AuthorityRecord.persistentID(.text(id)) }
        // Parts must already be gone; binding.json is the only remaining operational record.
        var names = 0
        try withDirectoryEntries(path: path) { name in
            guard name == "binding.json" else { throw failure("Document cleanup has pending work.") }
            names += 1
            return true
        }
        guard names <= 1 else { throw failure("Ambiguous document cleanup binding.") }
        try removeTree(path)
    }

    func createUniqueDirectory(_ path: [String]) throws {
        try requireMutableDocumentPath(path)
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
        try CanonicalMaintenanceContext.deny(root: root, path: path, operation: "canonical file write")
        try requireMutableDocumentPath(path)
        guard !path.isEmpty, data.count <= maximumBytes else {
            throw TractandaError("resourceLimit", "Document write exceeds its page window.")
        }
        let chain = try directories(Array(path.dropLast()), create: true)
        defer { closeAll(chain) }
        try reserve(data.count, descriptor: chain.last!)
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
                try reserve(min(262_144, bytes.count - offset), descriptor: fd)
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
        try CanonicalMaintenanceContext.deny(root: root, path: path, operation: "canonical file write")
        guard data.count <= 16 * 1024, path == ["document-jobs", jobID, "record.json"] else {
            throw TractandaError("resourceLimit", "Invalid bounded job checkpoint path.")
        }
        let old = try readIfPresent(path: path, maximumBytes: 16 * 1024)
        // Reject file capacity before creating a new intent directory.
        try reserve(data.count)
        let chain = try directories(Array(path.dropLast()), create: true)
        defer { closeAll(chain) }
        try reserve(data.count, descriptor: chain.last!)
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
        try CanonicalMaintenanceContext.deny(
            root: root, path: ["document-jobs", id], operation: "directory removal", onlyIfPresent: true)
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
        try requireMutableDocumentPath(["documents", ".staging", id])
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
    /// Disposable derived-index workspace only. Atomic canonical originals and acceptance
    /// receipts remain under authority/intake and are never children of this private path.
    func removeAtomicAuthorityWork(_ id: String) throws {
        _ = try AuthorityRecord.persistentID(.text(id))
        try removeTree(["atomic-authority-work", id], releaseAccounting: false)
    }
    /// The preparation owner already disposed only its inode-pinned SQLite files. Remove its
    /// directory only when empty; preserve unknown/replaced entries, never sweep a mixed parent.
    func removeAtomicIntakeWork(_ id: String) throws {
        try CanonicalMaintenanceContext.deny(
            root: root, path: ["atomic-intake-work", id], operation: "private work removal",
            onlyIfPresent: true)
        _ = try AuthorityRecord.persistentID(.text(id))
        let path = ["atomic-intake-work", id]
        let chain: [Int32]
        do { chain = try directories(path, create: false) } catch let error as TractandaError
            where error.osError == ENOENT
        { return }
        defer { closeAll(chain) }
        var occupied = false
        try withDirectoryEntries(path: path) { _ in
            occupied = true
            return false
        }
        if occupied { return }
        let parent = chain[chain.count - 2]
        let result = id.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
        if result < 0, errno == ENOTEMPTY || errno == EEXIST { return }
        guard result == 0 || errno == ENOENT, fsync(parent) == 0 else {
            throw failure("Cannot synchronize empty atomic preparation directory cleanup.")
        }
    }
    /// Caller has proved this exact LOCAL packet never acquired a PREPARED/ACCEPTED seal.
    /// This removes only private proposed bytes, never an original/history publication.
    func removeUnsealedAtomicDraft(_ packageID: String) throws {
        _ = try AuthorityRecord.persistentID(.text(packageID))
        try removeTree(["authority", "intake", packageID], releaseAccounting: false)
    }
    /// Called only after the immutable receiver original and sealed receipt are synchronized.
    /// Disposal is limited to one framed peer object's private stage, never canonical history.
    func removePeerObjectStage(packageID: String, objectID: String) throws {
        _ = try AuthorityRecord.persistentID(.text(packageID))
        _ = try AuthorityRecord.persistentID(.text(objectID))
        try removeTree(["authority", "intake", packageID, "objects", objectID], releaseAccounting: false)
    }
    private func removeTree(
        _ path: [String], releaseAccounting: Bool = true,
        completingFrozenReference: DocumentContentReference? = nil
    ) throws {
        if try CanonicalMaintenanceContext.removalIsNoOp(root: root, path: path) {
            return
        }
        if let reference = completingFrozenReference {
            guard path.count == 3, path.last == stageIdentity(path) else {
                throw failure("Only a complete applied stage may release its barrier.")
            }
            if let frozen = try frozenPeerStage(path), frozen.reference != reference {
                throw failure("Applied document reference differs from its barrier.")
            }
        } else {
            try requireMutableDocumentPath(path)
        }
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
    func read(path: [String], maximumBytes: Int, readBudget: ((Int) throws -> Void)? = nil) throws -> Data {
        guard let bytes = try readIfPresent(path: path, maximumBytes: maximumBytes, readBudget: readBudget)
        else {
            throw failure("Canonical document dependency is missing.")
        }
        return bytes
    }
    func readIfPresent(path: [String], maximumBytes: Int, readBudget: ((Int) throws -> Void)? = nil) throws
        -> Data?
    {
        let chain: [Int32]
        do { chain = try directories(Array(path.dropLast()), create: false) } catch let error
            as TractandaError where error.osError == ENOENT
        { return nil }
        defer { closeAll(chain) }
        let fd = path.last!.withCString {
            openat(chain.last!, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure("Canonical document dependency is missing or unsafe.") }
        defer { _ = close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            (path.starts(with: ["documents", "content"]) && isReadOnly(fd))
                || (before.st_uid == ownerUID && before.st_mode & 0o777 == 0o400),
            before.st_size > 0, before.st_size <= maximumBytes
        else {
            throw TractandaError(
                "documentIntegrity", "Canonical document dependency is unsafe or exceeds its window.")
        }
        try readBudget?(Int(before.st_size))
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
                Self.recordReadForTesting(root: root, path: path, bytes: amount)
                offset += amount
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_mode == after.st_mode, before.st_uid == after.st_uid, before.st_size == after.st_size,
            samePeerCheckpointTime(before, after)
        else {
            throw TractandaError("documentIntegrity", "Document dependency changed while reading.")
        }
        return data
    }
    func publishDirectory(
        _ stage: [String], to destination: [String], frozenReference: DocumentContentReference? = nil,
        readBudget: ((Int) throws -> Void)? = nil
    ) throws {
        try CanonicalMaintenanceContext.deny(
            root: root, path: destination, operation: "document directory publication")
        if let frozenReference {
            guard try frozenPeerStage(stage, readBudget: readBudget)?.reference == frozenReference else {
                throw failure("Frozen publication binding changed.")
            }
        } else {
            try requireMutableDocumentPath(stage)
        }
        let source = try directories(Array(stage.dropLast()), create: false)
        defer { closeAll(source) }
        let target = try directories(Array(destination.dropLast()), create: true)
        defer { closeAll(target) }
        let staged = try directories(stage, create: false)
        defer { closeAll(staged) }
        var sourceInfo = stat()
        var targetInfo = stat()
        guard fstat(staged.last!, &sourceInfo) == 0, fstat(target.last!, &targetInfo) == 0 else {
            throw failure("Cannot inspect document publication filesystems.")
        }
        guard sourceInfo.st_dev == targetInfo.st_dev else {
            throw TractandaError(
                "documentCrossFilesystem",
                "Document publication requires staging and destination on one filesystem.",
                osError: EXDEV)
        }
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
    func peerDocumentPartFile(path: [String], maximumBytes: Int) throws -> PeerOriginalFile {
        let chain = try directories(Array(path.dropLast()), create: false)
        do {
            let fd = openat(chain.last!, path.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure("Saved document part is missing.") }
            do {
                let url = path.reduce(root) { $0.appendingPathComponent($1) }
                let metadata = try FileMetadata.read(at: url)
                guard metadata.type == .regular, metadata.size > 0, metadata.size <= maximumBytes,
                    (path.starts(with: ["documents", "content"]) && isReadOnly(fd))
                        || (metadata.uid == ownerUID && metadata.mode & 0o777 == 0o400)
                else { throw failure("Saved document part metadata is unsafe.") }
                func check() throws {
                    var value = stat()
                    guard fstat(fd, &value) == 0, UInt64(value.st_ino) == metadata.inode,
                        UInt64(value.st_dev) == metadata.device, UInt64(value.st_size) == metadata.size,
                        UInt32(value.st_mode) == metadata.mode, value.st_uid == metadata.uid,
                        value.st_gid == metadata.gid
                    else { throw TractandaError("peerObjectCollision", "Document part changed during read.") }
                    #if canImport(Darwin)
                        let time = value.st_mtimespec
                    #else
                        let time = value.st_mtim
                    #endif
                    guard time.tv_sec == metadata.modificationSeconds,
                        time.tv_nsec == metadata.modificationNanoseconds
                    else { throw TractandaError("peerObjectCollision", "Document part timestamp changed.") }
                }
                try check()
                return PeerOriginalFile(
                    metadata: metadata, descriptors: chain + [fd],
                    read: { offset, count in
                        var result = Data(count: count)
                        try result.withUnsafeMutableBytes { buffer in
                            var done = 0
                            while done < count {
                                let read = pread(
                                    fd, buffer.baseAddress!.advanced(by: done), count - done,
                                    off_t(offset) + off_t(done))
                                if read < 0 && errno == EINTR { continue }
                                guard read > 0 else { throw self.failure("Document part ended early.") }
                                done += read
                            }
                        }
                        return result
                    }, validate: check)
            } catch {
                close(fd)
                throw error
            }
        } catch {
            closeAll(chain)
            throw error
        }
    }
    /// Adopt a verified receiver-private byte stage into its exact composite tree address.
    /// The only rename is within one filesystem; no whole-page copy is made.
    func adoptPeerDocumentPart(stageID: String, to destination: [String], bytes: Int64) throws {
        try CanonicalMaintenanceContext.deny(
            root: root, path: destination, operation: "document part adoption")
        try requireMutableDocumentPath(destination)
        _ = try AuthorityRecord.persistentID(.text(stageID))
        guard destination.count >= 4, destination.prefix(2) == ["documents", ".staging"],
            bytes > 0, bytes <= Self.maximumPeerDocumentPartBytes
        else { throw failure("Invalid private document-part destination.") }
        _ = try AuthorityRecord.persistentID(.text(destination[2]))
        let sourcePath = ["attachments", ".staging", stageID + ".stage"]
        let source = try directories(Array(sourcePath.dropLast()), create: false)
        defer { closeAll(source) }
        let target = try directories(Array(destination.dropLast()), create: true)
        defer { closeAll(target) }
        let fd = openat(source.last!, sourcePath.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT {
            let existing = try peerDocumentPartFile(path: destination, maximumBytes: Int(bytes))
            guard existing.metadata.size == UInt64(bytes) else { throw failure("Adopted part size differs.") }
        } else {
            guard fd >= 0 else { throw failure("Cannot retain private document part.") }
            defer { close(fd) }
            var value = stat()
            var parent = stat()
            guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                value.st_uid == ownerUID, value.st_nlink == 1, value.st_size == bytes,
                [mode_t(0o600), mode_t(0o400)].contains(value.st_mode & 0o777),
                fstat(target.last!, &parent) == 0, value.st_dev == parent.st_dev
            else { throw failure("Private document adoption requires safe bytes on one filesystem.") }
            guard fchmod(fd, 0o400) == 0, fsync(fd) == 0,
                tractanda_publish_directory_at(
                    source.last!, sourcePath.last!, target.last!, destination.last!) == 0
            else { throw failure("Cannot adopt immutable document part without replacement.") }
            try afterPeerPartRenameForTesting?()
        }
        guard fsync(source.last!) == 0, fsync(target.last!) == 0 else {
            throw failure("Cannot synchronize document-part adoption.")
        }
        try stagingQuota?.movePrivateBytes(bytes, from: sourcePath, to: destination)
    }
    private static let maximumPeerDocumentPartBytes: Int64 = 2 * 1024 * 1024
    /// At most five live immediate-directory cursors and one pending file; no whole-tree listing.
    final class PeerTreeInspection {
        private struct Frame {
            let suffix: [String]
            let chain: [Int32]?
            let cursor: POSIXDirectory.Cursor?
            let metadata: FileMetadata
            var names: [String] = []
            var last: String?
            var exhausted = false
            let initialCount: Int64
            var pending: String?
        }
        private let files: DocumentContentFiles
        private let parkable: Bool
        let base: [String]
        let initialMetadata: FileMetadata
        private var frames: [Frame] = []
        private(set) var count: Int64 = 0
        private(set) var complete = false
        init(files: DocumentContentFiles, base: [String], parkable: Bool = false) throws {
            self.files = files
            self.parkable = parkable
            self.base = base
            initialMetadata = try FileMetadata.read(
                at: base.reduce(files.root) { $0.appendingPathComponent($1) })
            guard initialMetadata.type == .directory else {
                throw files.failure("Unsafe document inspection root.")
            }
            try descend([])
        }
        deinit { for frame in frames { if let chain = frame.chain { files.closeAll(chain) } } }
        private func descend(_ suffix: [String]) throws {
            guard suffix.count <= 3 else {
                throw files.failure("Document inspection exceeded its bounded depth.")
            }
            let chain = try files.directories(base + suffix, create: false)
            do {
                let metadata = try FileMetadata.read(
                    at: (base + suffix).reduce(files.root) { $0.appendingPathComponent($1) })
                var opened = stat()
                guard fstat(chain.last!, &opened) == 0,
                    UInt64(opened.st_ino) == metadata.inode, UInt64(opened.st_dev) == metadata.device
                else {
                    throw files.failure("Inspection directory binding changed during open.")
                }
                if parkable {
                    // Only bounded names/positions survive a fair yield; no directory descriptor.
                    frames.append(
                        .init(
                            suffix: suffix, chain: nil, cursor: nil, metadata: metadata, initialCount: count))
                    files.closeAll(chain)
                } else {
                    let cursor = try POSIXDirectory.Cursor(descriptor: chain.last!)
                    frames.append(
                        .init(
                            suffix: suffix, chain: chain, cursor: cursor, metadata: metadata,
                            initialCount: count))
                }
            } catch {
                files.closeAll(chain)
                throw error
            }
        }
        var retainedByteCount: Int {
            frames.reduce(4096) { total, frame in
                total + frame.names.reduce(0) { $0 + $1.utf8.count + 32 }
                    + frame.suffix.reduce(0) { $0 + $1.utf8.count + 32 } + 256
            }
        }
        var retainsDirectoryDescriptors: Bool { frames.contains { $0.chain != nil } }
        private func withFrame<T>(_ index: Int, _ body: (Int32) throws -> T) throws -> T {
            if let chain = frames[index].chain { return try body(chain.last!) }
            let path = base + frames[index].suffix
            guard
                try FileMetadata.read(at: path.reduce(files.root) { $0.appendingPathComponent($1) })
                    == frames[index].metadata
            else {
                throw files.failure("Parked inspection directory changed.")
            }
            let chain = try files.directories(path, create: false)
            defer { files.closeAll(chain) }
            let expected = frames[index].metadata
            var opened = stat()
            guard fstat(chain.last!, &opened) == 0,
                UInt64(opened.st_ino) == expected.inode, UInt64(opened.st_dev) == expected.device
            else {
                throw files.failure("Parked inspection opened a different directory.")
            }
            let value = try body(chain.last!)
            guard fstat(chain.last!, &opened) == 0,
                UInt64(opened.st_ino) == expected.inode, UInt64(opened.st_dev) == expected.device,
                try FileMetadata.read(at: path.reduce(files.root) { $0.appendingPathComponent($1) })
                    == frames[index].metadata
            else {
                throw files.failure("Parked inspection directory changed while reading.")
            }
            return value
        }
        private func nextName(_ top: Int, budget: PeerOriginalReadBudget) throws -> String? {
            if let cursor = frames[top].cursor { return try cursor.next() }
            if frames[top].names.isEmpty, !frames[top].exhausted {
                var names: [String] = []
                var eligible = 0
                let after = frames[top].last
                try withFrame(top) { descriptor in
                    try POSIXDirectory.withEntries(descriptor: descriptor) { name in
                        try budget.step()
                        // Legal document names are tiny ASCII scalar components. Reject corrupt
                        // names before retaining a bounded lexicographic window of128 entries.
                        guard name.utf8.count <= 32, name.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
                            throw files.failure("Invalid document inspection name.")
                        }
                        if after == nil || name > after! {
                            eligible += 1
                            let position = names.firstIndex(where: { $0 > name }) ?? names.endIndex
                            if position < 128 {
                                names.insert(name, at: position)
                                if names.count > 128 { names.removeLast() }
                            }
                        }
                        return true
                    }
                }
                frames[top].names = names
                frames[top].exhausted = eligible <= 128
            }
            guard !frames[top].names.isEmpty else { return nil }
            let name = frames[top].names.removeFirst()
            frames[top].last = name
            return name
        }
        func checkRoot() throws {
            guard
                try FileMetadata.read(at: base.reduce(files.root) { $0.appendingPathComponent($1) })
                    == initialMetadata
            else {
                throw files.failure("Document inspection root changed.")
            }
        }
        func step(
            budget: PeerOriginalReadBudget, synchronize: Bool,
            inspect: ([String], PeerOriginalFile) throws -> Void
        ) throws -> Bool {
            try checkRoot()
            for _ in 0..<128 where !frames.isEmpty {
                try budget.step()
                let top = frames.count - 1
                if frames[top].pending == nil { frames[top].pending = try nextName(top, budget: budget) }
                guard let name = frames[top].pending else {
                    let frame = frames[top]
                    guard frame.suffix.isEmpty || count > frame.initialCount else {
                        throw files.failure("Unexpected empty document subtree.")
                    }
                    if synchronize {
                        try withFrame(top) { descriptor in
                            if !(base.starts(with: ["documents", "content"]) && files.isReadOnly(descriptor)),
                                fsync(descriptor) != 0
                            {
                                throw files.failure("Cannot synchronize inspected subtree.")
                            }
                        }
                    }
                    frames.removeLast()
                    if let chain = frame.chain { files.closeAll(chain) }
                    continue
                }
                let suffix = frames[top].suffix + [name]
                var value = stat()
                try withFrame(top) { descriptor in
                    guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw files.failure("Cannot inspect document entry.")
                    }
                }
                if value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    let allowed =
                        suffix == ["pages"] || suffix == ["nodes"]
                        || ((suffix[0] == "pages" && suffix.count == 2)
                            || (suffix[0] == "nodes" && (2...3).contains(suffix.count)))
                            && !name.isEmpty && name.utf8.allSatisfy({ (48...57).contains($0) })
                    guard allowed else { throw files.failure("Unknown document subtree.") }
                    frames[top].pending = nil
                    try descend(suffix)
                } else {
                    _ = try PeerPackage.DocumentPart.from(relativePath: suffix)
                    let file = try files.peerDocumentPartFile(
                        path: base + suffix, maximumBytes: DocumentContentStore.maximumPageBytes)
                    try inspect(suffix, file)
                    if synchronize {
                        try file.synchronize(allowReadOnly: base.starts(with: ["documents", "content"]))
                    }
                    let next = count.addingReportingOverflow(1)
                    guard !next.overflow else { throw files.failure("Document inspection count overflowed.") }
                    count = next.partialValue
                    frames[top].pending = nil
                }
            }
            complete = frames.isEmpty
            try checkRoot()
            return complete
        }
    }
    func peerTreeInspection(_ base: [String], parkable: Bool = false) throws -> PeerTreeInspection {
        try PeerTreeInspection(files: self, base: base, parkable: parkable)
    }
    /// Bounded enumeration supplies the completeness count and fsyncs every retained dependency
    /// and its directory before a canonical locator can be published. No path crosses the wire.
    func inspectDocumentTree(_ base: [String], synchronize: Bool) throws -> Int64 {
        var count: Int64 = 0
        func walk(_ suffix: [String]) throws {
            try Task.checkCancellation()
            let initialCount = count
            let chain = try directories(base + suffix, create: false)
            defer { closeAll(chain) }
            let parent = chain.last!
            try POSIXDirectory.withEntries(descriptor: parent) { name in
                let path = suffix + [name]
                let expectedFile: Bool
                let expectedDirectory: Bool
                if path.count == 1 {
                    expectedFile = name == "manifest.json"
                    expectedDirectory = name == "pages" || name == "nodes"
                } else {
                    let numeric = name.utf8.allSatisfy { (48...57).contains($0) }
                    expectedDirectory =
                        numeric && !name.isEmpty
                        && ((path[0] == "pages" && path.count == 2)
                            || (path[0] == "nodes" && (2...3).contains(path.count)))
                    expectedFile =
                        name.hasSuffix(".json")
                        && !name.dropLast(5).isEmpty
                        && name.dropLast(5).utf8.allSatisfy { (48...57).contains($0) }
                        && ((path[0] == "pages" && path.count == 3)
                            || (path[0] == "nodes" && path.count == 4))
                }
                var metadata = stat()
                guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw failure("Cannot inspect complete document tree.")
                }
                if expectedDirectory && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    try walk(path)
                } else if expectedFile && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                    let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw failure("Cannot retain document dependency for durability.") }
                    defer { close(fd) }
                    var actual = stat()
                    guard fstat(fd, &actual) == 0, actual.st_dev == metadata.st_dev,
                        actual.st_ino == metadata.st_ino, actual.st_mode == metadata.st_mode,
                        actual.st_size == metadata.st_size, actual.st_size > 0,
                        (base.starts(with: ["documents", "content"]) && isReadOnly(fd))
                            || (actual.st_uid == ownerUID && actual.st_mode & 0o777 == 0o400)
                    else { throw failure("Unsafe document dependency during complete-tree inspection.") }
                    if synchronize && !isReadOnly(fd) && fsync(fd) != 0 {
                        throw failure("Cannot synchronize document dependency.")
                    }
                    let next = count.addingReportingOverflow(1)
                    guard !next.overflow else { throw failure("Document part count overflowed.") }
                    count = next.partialValue
                } else {
                    throw failure("Unknown or unsafe entry in complete document tree.")
                }
                return true
            }
            if synchronize && !isReadOnly(parent) && fsync(parent) != 0 {
                throw failure("Cannot synchronize complete document subtree.")
            }
            guard suffix.isEmpty || count > initialCount else {
                throw failure("Unexpected empty directory in complete document tree.")
            }
        }
        try walk([])
        return count
    }
    func synchronizePublication(_ stage: [String], to destination: [String]) throws {
        let source = try directories(Array(stage.dropLast()), create: false)
        defer { closeAll(source) }
        let target = try directories(Array(destination.dropLast()), create: false)
        defer { closeAll(target) }
        try beforePublicationSyncForTesting?()
        guard isReadOnly(target.last!) || fsync(target.last!) == 0, fsync(source.last!) == 0 else {
            throw failure("Cannot synchronize document tree publication.")
        }
        stagingQuota?.release(path: stage)
    }
    func synchronizeDirectory(_ path: [String]) throws {
        let chain = try directories(path, create: false)
        defer { closeAll(chain) }
        guard
            (path.starts(with: ["documents", "content"]) && isReadOnly(chain.last!))
                || fsync(chain.last!) == 0
        else { throw failure("Cannot synchronize private recovery directory.") }
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

extension DocumentContentFiles {
    /// Replace only disposable personal-sync metadata; never canonical revisions or payload bytes.
    func replacePersonalSyncMetadata(_ data: Data, path: [String]) throws {
        guard path.count == 3, path[0] == ".personal-sync", ["reviews", "work", "cursors"].contains(path[1]),
            path[2].hasSuffix(".json"), data.count <= 128 * 1024,
            path.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
            })
        else {
            throw TractandaError("invalidConfiguration", "Invalid personal private metadata path.")
        }
        let chain = try directories(Array(path.dropLast()), create: true)
        defer { closeAll(chain) }
        try reserve(data.count, descriptor: chain.last!)
        let temporary = ".metadata-" + UUID().uuidString
        let fd = openat(chain.last!, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Cannot create personal metadata replacement.") }
        defer {
            close(fd)
            _ = unlinkat(chain.last!, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw failure("Cannot write personal metadata.") }
                offset += result
            }
        }
        guard fchmod(fd, 0o400) == 0, fsync(fd) == 0,
            renameat(chain.last!, temporary, chain.last!, path.last!) == 0,
            fsync(chain.last!) == 0
        else { throw failure("Cannot durably replace personal metadata.") }
    }
}

extension DocumentContentFiles {
    /// Disposable DFS work only. No caller-selected directory or canonical object can be removed.
    func removePersonalSyncWorkFile(_ name: String) throws {
        let metadataTemporary =
            name.hasPrefix(".metadata-")
            && UUID(uuidString: String(name.dropFirst(".metadata-".count))) != nil
        guard name.hasSuffix(".json") || metadataTemporary, name.utf8.count <= 200,
            !name.contains("/"), !name.contains("\0"), name != ".", name != ".."
        else {
            throw TractandaError("invalidConfiguration", "Invalid personal work-file key.")
        }
        let chain = try directories([".personal-sync", "work"], create: false)
        defer { closeAll(chain) }
        if unlinkat(chain.last!, name, 0) != 0, errno != ENOENT {
            throw failure("Cannot remove disposable personal sync work.")
        }
        guard fsync(chain.last!) == 0 else { throw failure("Cannot synchronize personal sync work removal.") }
    }
}

extension DocumentContentFiles {
    func removePersonalSyncStageBinding(_ key: String) throws {
        try PersonalSyncValidation.sha256(key)
        try removePersonalSyncBinding(directory: "stages", name: key + ".json")
    }
    func removePersonalSyncDocumentBinding(_ contentID: String) throws {
        try PersonalSyncValidation.identifier(contentID)
        try removePersonalSyncBinding(directory: "documents", name: contentID + ".json")
    }
    private func removePersonalSyncBinding(directory: String, name: String) throws {
        let chain: [Int32]
        do { chain = try directories([".personal-sync", directory], create: false) } catch let error
            as TractandaError where error.osError == ENOENT
        { return }
        defer { closeAll(chain) }
        if unlinkat(chain.last!, name, 0) != 0, errno != ENOENT {
            throw failure("Cannot retire completed personal object metadata.")
        }
        guard fsync(chain.last!) == 0 else {
            throw failure("Cannot synchronize completed personal object cleanup.")
        }
    }
}
