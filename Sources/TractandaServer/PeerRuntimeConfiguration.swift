import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

extension PeerRuntimeConfiguration {
    /// Loads a strict, bounded JSON document owned by the effective service UID and mode 0600.
    public static func load(from path: String) throws -> Self {
        let data = try readPrivateConfiguration(at: path)
        return try Self.decode(data)
    }
}

private func readPrivateConfiguration(at path: String) throws -> Data {
    guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096,
        !path.contains("\0"), !path.contains("\n"), !path.contains("\r")
    else {
        throw PeerRuntimeConfiguration.invalid(
            "Peer runtime configuration path must be absolute and bounded.")
    }
    let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw PeerRuntimeConfiguration.invalid("Cannot open private peer runtime configuration.")
    }
    defer { close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
        before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        before.st_uid == geteuid(), before.st_mode & 0o7777 == 0o600,
        before.st_size > 0, before.st_size <= PeerRuntimeConfiguration.maximumFileBytes
    else {
        throw PeerRuntimeConfiguration.invalid(
            "Peer runtime configuration must be an owned private regular file under 64 KiB.")
    }

    var data = Data(capacity: Int(before.st_size))
    var buffer = [UInt8](repeating: 0, count: PeerRuntimeConfiguration.maximumFileBytes + 1)
    while data.count < buffer.count {
        let count = buffer.withUnsafeMutableBytes {
            read(descriptor, $0.baseAddress!.advanced(by: data.count), $0.count - data.count)
        }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else {
            throw PeerRuntimeConfiguration.invalid("Cannot read private peer runtime configuration.")
        }
        if count == 0 { break }
        data.append(contentsOf: buffer[data.count..<(data.count + count)])
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0 else {
        throw PeerRuntimeConfiguration.invalid("Cannot recheck private peer runtime configuration.")
    }
    #if canImport(Darwin)
        let unchangedTimes =
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    #else
        let unchangedTimes =
            before.st_mtim.tv_sec == after.st_mtim.tv_sec
            && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec
            && before.st_ctim.tv_sec == after.st_ctim.tv_sec
            && before.st_ctim.tv_nsec == after.st_ctim.tv_nsec
    #endif
    guard
        before.st_dev == after.st_dev, before.st_ino == after.st_ino,
        after.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
        after.st_uid == geteuid(), after.st_mode & 0o7777 == 0o600,
        before.st_size == after.st_size, data.count == Int(before.st_size),
        data.count <= PeerRuntimeConfiguration.maximumFileBytes, unchangedTimes
    else {
        throw PeerRuntimeConfiguration.invalid("Peer runtime configuration changed while being read.")
    }
    return data
}
