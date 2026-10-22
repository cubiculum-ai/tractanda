import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Raw originals only, owned by one synchronous coordinator operation. No authority decision
/// or missing dependency is memoized. Every reuse reopens the lexical path and checks custody.
final class PeerVerifiedOriginalCache {
    private struct Key: Hashable {
        let kind: String
        let id: String
        let length: Int
        let sha256: String
        let path: String
        init(_ row: AuthorityStore.RetainedObject) {
            kind = row.descriptor.kind.rawValue
            id = row.descriptor.id
            length = row.descriptor.length
            sha256 = row.descriptor.sha256
            path = row.path
        }
    }
    private struct Stamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let uid: UInt32
        let gid: UInt32
        let mode: UInt32
        let links: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let flags: UInt32
        init(_ value: stat) {
            device = UInt64(truncatingIfNeeded: value.st_dev)
            inode = UInt64(value.st_ino)
            uid = UInt32(value.st_uid)
            gid = UInt32(value.st_gid)
            mode = UInt32(value.st_mode)
            links = UInt64(value.st_nlink)
            size = Int64(value.st_size)
            #if canImport(Darwin)
                modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
                modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
                changedSeconds = Int64(value.st_ctimespec.tv_sec)
                changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
                flags = UInt32(value.st_flags)
            #else
                modifiedSeconds = Int64(value.st_mtim.tv_sec)
                modifiedNanoseconds = Int64(value.st_mtim.tv_nsec)
                changedSeconds = Int64(value.st_ctim.tv_sec)
                changedNanoseconds = Int64(value.st_ctim.tv_nsec)
                flags = 0
            #endif
        }
    }
    private enum Entry {
        case verified(Stamp, Data)
        case invalidated
    }
    private let root: URL
    private let ownerUID: UInt32
    private let maximumBytes: Int
    private let maximumEntries: Int
    private var entries: [Key: Entry] = [:]
    private(set) var residentBytes = 0
    var entryCount: Int { entries.count }
    init(root: URL, ownerUID: UInt32, maximumBytes: Int, maximumEntries: Int = 4096) {
        self.root = root
        self.ownerUID = ownerUID
        self.maximumBytes = max(0, maximumBytes)
        self.maximumEntries = max(0, maximumEntries)
    }
    private func failure() -> TractandaError {
        TractandaError("peerObjectCollision", "Verified original path, bytes or custody changed.")
    }
    private func withDescriptor<T>(
        _ row: AuthorityStore.RetainedObject, _ body: (Int32, Stamp) throws -> T
    ) throws -> T {
        let parts = row.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard root.path.hasPrefix("/"), root.path != "/", !root.path.utf8.contains(0), !parts.isEmpty,
            parts.count <= 32, row.path.utf8.count <= 4096,
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
            row.descriptor.length > 0
        else { throw failure() }
        if row.descriptor.kind == .item {
            guard parts.count == 8,
                CanonicalRecordPath.validate(
                    row.path, itemID: parts[6], revisionID: row.descriptor.id)
            else { throw failure() }
        }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw failure() }
        func validateDirectory(_ fd: Int32) throws {
            if row.descriptor.kind != .item {
                var value = stat()
                guard fstat(fd, &value) == 0, value.st_uid == ownerUID,
                    value.st_mode & 0o077 == 0
                else { throw failure() }
            }
        }
        var opened = [rootFD]
        defer { for fd in opened.reversed() { _ = close(fd) } }
        try validateDirectory(rootFD)
        for part in parts.dropLast() {
            let fd = openat(opened.last!, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure() }
            opened.append(fd)
            try validateDirectory(fd)
        }
        // Item originals retain historical private 0600/0400 custody. Authority blobs retain
        // their existing exact0400 rule. Neither kind may be replaced with a linked original.
        let fd = openat(opened.last!, parts.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        opened.append(fd)
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            value.st_uid == ownerUID, value.st_mode & 0o077 == 0, value.st_nlink == 1,
            value.st_size == row.descriptor.length,
            row.descriptor.kind == .item || value.st_mode & 0o777 == 0o400
        else { throw failure() }
        return try body(fd, Stamp(value))
    }
    /// A miss uses the existing custody/hash reader and its unchanged hydration charge.
    /// A hit returns the same immutable Data value; it performs no new hydration.
    func read(_ row: AuthorityStore.RetainedObject, load: () throws -> Data) throws -> Data {
        // This optimization is only for positive-length metadata originals. Other kinds
        // and empty payloads keep their existing reader and validation semantics.
        guard row.descriptor.length > 0,
            row.descriptor.kind == .item || row.descriptor.kind == .authority
        else { return try load() }
        try Task.checkCancellation()
        let key = Key(row)
        if case .invalidated? = entries[key] { throw failure() }
        do {
            return try withDescriptor(row) { fd, before in
                if case .verified(let stamp, let data)? = entries[key] {
                    guard stamp == before else { throw failure() }
                    var after = stat()
                    guard fstat(fd, &after) == 0, Stamp(after) == before else { throw failure() }
                    try withDescriptor(row) { _, current in
                        guard current == before else { throw failure() }
                    }
                    try Task.checkCancellation()
                    return data
                }
                let data = try load()
                guard data.count == row.descriptor.length,
                    AuthorityRecordCodec.sha256(data) == row.descriptor.sha256
                else { throw failure() }
                var after = stat()
                guard fstat(fd, &after) == 0, Stamp(after) == before else { throw failure() }
                // A path swap during the independent reader cannot seed a stale entry.
                try withDescriptor(row) { _, current in
                    guard current == before else { throw failure() }
                }
                if entries.count < maximumEntries, data.count <= maximumBytes - residentBytes {
                    entries[key] = .verified(before, data)
                    residentBytes += data.count
                }
                return data
            }
        } catch {
            if case .verified(_, let data)? = entries[key] {
                residentBytes -= data.count
                entries[key] = .invalidated
            }
            throw error
        }
    }
}
