import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

enum FileMetadataError: Error, Equatable {
    case invalidPath
    case posix(Int32)
}

struct FileMetadata: Equatable, Sendable {
    enum FileType: Equatable, Sendable {
        case directory
        case regular
        case symbolicLink
        case other
    }

    let mode: UInt32
    let uid: UInt32
    let gid: UInt32
    let size: UInt64
    let inode: UInt64
    let device: UInt64

    var type: FileType {
        switch mode & 0o170000 {
        case 0o040000: .directory
        case 0o100000: .regular
        case 0o120000: .symbolicLink
        default: .other
        }
    }

    static func read(at url: URL) throws -> Self {
        try read(path: url.path)
    }

    static func read(path: String) throws -> Self {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw FileMetadataError.invalidPath }
        var mode: UInt32 = 0
        var uid: UInt32 = 0
        var gid: UInt32 = 0
        var size: UInt64 = 0
        var inode: UInt64 = 0
        var device: UInt64 = 0
        let result = path.withCString {
            tractanda_file_metadata($0, &mode, &uid, &gid, &size, &inode, &device)
        }
        guard result == 0 else { throw FileMetadataError.posix(errno) }
        return Self(mode: mode, uid: uid, gid: gid, size: size, inode: inode, device: device)
    }
}
