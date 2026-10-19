import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A deliberately small immediate-directory wrapper. Recovery validates each child with lstat
/// before it elects to descend, so this type never follows a child symlink on the caller's behalf.
enum POSIXDirectory {
    private static let maximumNameBytes = 1024
    /// Process-local continuation. The retained no-follow descriptor pins this directory; no
    /// opaque seek offset is persisted as canonical identity or supplied by a remote caller.
    final class Cursor {
        private let handle: UnsafeMutableRawPointer
        init(descriptor: Int32) throws {
            guard let handle = tractanda_directory_open_fd(descriptor) else {
                throw FileMetadataError.posix(errno)
            }
            self.handle = handle
        }
        deinit { _ = tractanda_directory_close(handle) }
        func next() throws -> String? {
            try Task.checkCancellation()
            var name = [CChar](repeating: 0, count: maximumNameBytes)
            let result = name.withUnsafeMutableBufferPointer {
                tractanda_directory_next(handle, $0.baseAddress, $0.count)
            }
            if result == 0 { return nil }
            guard result == 1 else { throw FileMetadataError.posix(errno) }
            let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            guard let decoded = String(bytes: bytes, encoding: .utf8) else {
                throw FileMetadataError.invalidPath
            }
            return decoded
        }
    }

    /// Visits each immediate child name while keeping only the current name in Swift memory.
    /// Return `false` from the body to stop early. Child entries are names only; callers remain
    /// responsible for using lstat when they need to inspect or descend into a child.
    static func withEntries(
        at url: URL,
        body: (String) throws -> Bool
    ) throws {
        let handle = url.path.withCString { tractanda_directory_open($0) }
        guard let handle else { throw FileMetadataError.posix(errno) }

        try entries(handle, body: body)
    }

    static func withEntries(descriptor: Int32, body: (String) throws -> Bool) throws {
        guard let handle = tractanda_directory_open_fd(descriptor) else {
            throw FileMetadataError.posix(errno)
        }
        try entries(handle, body: body)
    }

    private static func entries(_ handle: UnsafeMutableRawPointer, body: (String) throws -> Bool) throws {
        do {
            while true {
                try Task.checkCancellation()
                var name = [CChar](repeating: 0, count: maximumNameBytes)
                let result = name.withUnsafeMutableBufferPointer {
                    tractanda_directory_next(handle, $0.baseAddress, $0.count)
                }
                if result == 0 { break }
                guard result == 1 else { throw FileMetadataError.posix(errno) }

                let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                guard let decoded = String(bytes: bytes, encoding: .utf8) else {
                    throw FileMetadataError.invalidPath
                }
                guard try body(decoded) else { break }
            }
        } catch {
            _ = tractanda_directory_close(handle)
            throw error
        }

        guard tractanda_directory_close(handle) == 0 else {
            throw FileMetadataError.posix(errno)
        }
    }
}
