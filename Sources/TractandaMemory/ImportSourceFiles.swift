import Crypto
import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Every descendant is opened relative to the selected directory descriptor without symlink traversal.
public final class ImportSourceFiles {
    private let rootFD: Int32
    public let root: URL
    public let limits: ImportLimits

    public init(root: URL, limits: ImportLimits = ImportLimits()) throws {
        try limits.validate()
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0") else {
            throw TractandaError("importPath", "Source root must be an absolute local directory.")
        }
        #if canImport(Darwin)
            let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #else
            let descriptor = Glibc.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #endif
        guard descriptor >= 0 else { throw Self.failure("Cannot open selected source directory.") }
        self.rootFD = descriptor
        self.root = root
        self.limits = limits
    }

    deinit { _ = close(rootFD) }

    public static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
        else { throw TractandaError("importPath", "Source path must remain inside its selected directory.") }
        return parts
    }

    public func list() throws -> [String] {
        var result: [String] = []
        var entries = 0
        var selectedBytes: Int64 = 0
        func visit(_ descriptor: Int32, prefix: [String]) throws {
            guard prefix.count <= 64 else {
                throw TractandaError("importLimits", "Source directory nesting exceeds limit.")
            }
            let duplicate = dup(descriptor)
            guard duplicate >= 0, let directory = fdopendir(duplicate) else {
                if duplicate >= 0 { _ = close(duplicate) }
                throw Self.failure("Cannot enumerate selected source directory.")
            }
            defer { _ = closedir(directory) }
            // A duplicated descriptor shares its directory offset: rewind for repeated inventories.
            rewinddir(directory)
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let entry = readdir(directory) else {
                    guard errno == 0 else { throw Self.failure("Source directory enumeration failed.") }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                entries += 1
                guard entries <= limits.maximumRecords * 8 + 1024 else {
                    throw TractandaError("importLimits", "Selected source directory has too many entries.")
                }
                var metadata = stat()
                guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw Self.failure("Source entry changed while enumerating.")
                }
                let path = prefix + [name]
                switch metadata.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFDIR):
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw Self.failure("Cannot open source subdirectory.") }
                    defer { _ = close(child) }
                    try visit(child, prefix: path)
                case mode_t(S_IFREG):
                    let total = selectedBytes.addingReportingOverflow(Int64(metadata.st_size))
                    guard metadata.st_size >= 0, !total.overflow,
                        total.partialValue <= limits.maximumOriginalBytes
                    else {
                        throw TractandaError(
                            "importLimits", "Selected source originals exceed their total byte budget.")
                    }
                    selectedBytes = total.partialValue
                    guard result.count < limits.maximumRecords else {
                        throw TractandaError("importLimits", "Selected source contains too many files.")
                    }
                    result.append(path.joined(separator: "/"))
                default:
                    throw TractandaError(
                        "importPath",
                        "Source contains a symlink or nonregular file: " + path.joined(separator: "/"))
                }
            }
        }
        try visit(rootFD, prefix: [])
        return result.sorted()
    }

    public func open(relativePath: String) throws -> Source {
        let parts = try Self.components(relativePath)
        var directory = dup(rootFD)
        guard directory >= 0 else { throw Self.failure("Cannot retain source directory.") }
        defer { _ = close(directory) }
        for component in parts.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Self.failure("Source path is unavailable or unsafe.") }
            _ = close(directory)
            directory = next
        }
        let descriptor = openat(directory, parts.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure("Cannot open regular selected source.") }
        return try Source(descriptor: descriptor, maximumBytes: limits.maximumOriginalBytes)
    }

    public func read(relativePath: String, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw TractandaError("importLimits", "Invalid source read budget.") }
        let source = try open(relativePath: relativePath)
        guard source.byteCount <= Int64(maximumBytes) else {
            throw TractandaError("importLimits", "Source exceeds bounded parser read budget.")
        }
        var result = Data()
        var offset: Int64 = 0
        while offset < source.byteCount {
            let bytes = try source.chunk(offset: offset)
            result.append(bytes)
            offset += Int64(bytes.count)
        }
        try source.verifyUnchanged()
        return result
    }

    public func original(relativePath: String, mediaType: String = "application/octet-stream") throws
        -> ImportOriginal
    {
        let source = try open(relativePath: relativePath)
        return ImportOriginal(
            relativePath: relativePath, mediaType: mediaType, byteCount: source.byteCount,
            sha256: source.sha256)
    }

    public final class Source {
        private let descriptor: Int32
        private let metadata: stat
        public let byteCount: Int64
        public let sha256: String

        fileprivate init(descriptor: Int32, maximumBytes: Int64) throws {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                metadata.st_size >= 0, metadata.st_size <= maximumBytes
            else {
                _ = close(descriptor)
                throw TractandaError("importOriginal", "Source is not a bounded regular file.")
            }
            do {
                var hash = SHA256()
                var offset: Int64 = 0
                while offset < Int64(metadata.st_size) {
                    let bytes = try Self.read(descriptor, metadata: metadata, offset: offset, limit: 262_144)
                    hash.update(data: bytes)
                    offset += Int64(bytes.count)
                }
                try Self.check(descriptor, metadata: metadata)
                self.descriptor = descriptor
                self.metadata = metadata
                byteCount = Int64(metadata.st_size)
                sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
            } catch {
                _ = close(descriptor)
                throw error
            }
        }

        deinit { _ = close(descriptor) }
        public func chunk(offset: Int64, limit: Int = 262_144) throws -> Data {
            try Self.read(descriptor, metadata: metadata, offset: offset, limit: limit)
        }
        public func verifyUnchanged() throws { try Self.check(descriptor, metadata: metadata) }

        private static func check(_ descriptor: Int32, metadata: stat) throws {
            try Task.checkCancellation()
            var current = stat()
            guard fstat(descriptor, &current) == 0,
                current.st_dev == metadata.st_dev, current.st_ino == metadata.st_ino,
                current.st_size == metadata.st_size, current.st_mode == metadata.st_mode,
                current.st_uid == metadata.st_uid, current.st_gid == metadata.st_gid
            else { throw TractandaError("importSourceChanged", "Source changed during import.") }
            #if canImport(Darwin)
                let sameTime =
                    current.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec
                    && current.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec
                    && current.st_ctimespec.tv_sec == metadata.st_ctimespec.tv_sec
                    && current.st_ctimespec.tv_nsec == metadata.st_ctimespec.tv_nsec
            #else
                let sameTime =
                    current.st_mtim.tv_sec == metadata.st_mtim.tv_sec
                    && current.st_mtim.tv_nsec == metadata.st_mtim.tv_nsec
                    && current.st_ctim.tv_sec == metadata.st_ctim.tv_sec
                    && current.st_ctim.tv_nsec == metadata.st_ctim.tv_nsec
            #endif
            guard sameTime else {
                throw TractandaError("importSourceChanged", "Source bytes changed during import.")
            }
        }

        private static func read(_ descriptor: Int32, metadata: stat, offset: Int64, limit: Int) throws
            -> Data
        {
            guard offset >= 0, offset <= Int64(metadata.st_size), (1...262_144).contains(limit) else {
                throw TractandaError("importOriginal", "Invalid bounded source chunk.")
            }
            try check(descriptor, metadata: metadata)
            let expected = Int(min(Int64(limit), Int64(metadata.st_size) - offset))
            var data = Data(count: expected)
            var count = 0
            while count < expected {
                let amount = data.withUnsafeMutableBytes {
                    pread(
                        descriptor, $0.baseAddress!.advanced(by: count), expected - count,
                        off_t(offset + Int64(count)))
                }
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else {
                    throw TractandaError("importSourceChanged", "Source ended before its selected size.")
                }
                count += amount
            }
            try check(descriptor, metadata: metadata)
            return data
        }
    }

    private static func failure(_ message: String) -> TractandaError {
        TractandaError("importSourceRead", message, osError: errno)
    }
}
