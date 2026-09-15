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

    static func entries(at url: URL) throws -> [String] {
        let handle = url.path.withCString { tractanda_directory_open($0) }
        guard let handle else { throw FileMetadataError.posix(errno) }
        var entries: [String] = []
        do {
            while true {
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
                entries.append(decoded)
            }
        } catch {
            _ = tractanda_directory_close(handle)
            throw error
        }
        guard tractanda_directory_close(handle) == 0 else { throw FileMetadataError.posix(errno) }
        return entries
    }
}
