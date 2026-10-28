import Foundation
import CTractandaPlatform
import TractandaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Strict custody boundary for enrollment codes. Keep returned invitations out of normal
/// command output; this type exposes only the Core invitation's redacted description/metadata.
enum ClusterEnrollmentPrivateInput {
    static let maximumBytes = 12 * 1024
    private static func invalid() -> TractandaError {
        TractandaError("invalidEnrollmentInput", "Private enrollment input is unavailable or unsafe.")
    }
    static func validateNewPrivateOutputFile(_ path: String) throws {
        let (parent, name) = try openParent(path)
        defer { close(parent) }
        var existing = stat()
        let result = name.withCString { fstatat(parent, $0, &existing, AT_SYMLINK_NOFOLLOW) }
        guard result < 0, errno == ENOENT else { throw invalid() }
    }
    static func validateTerminalOutput() throws {
        let fd = open("/dev/tty", O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw invalid() }
        defer { close(fd) }
        guard isatty(fd) == 1 else { throw invalid() }
    }

    static func readInvitation(fromPrivateFile path: String) throws -> PersonalEnrollmentInvitation {
        let (parent, name) = try openParent(path)
        defer { close(parent) }
        let fd = name.withCString { openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw invalid() }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_uid == getuid(), before.st_nlink == 1,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_mode & 0o7777 == 0o600,
              before.st_size > 0, before.st_size <= maximumBytes,
              tractanda_secret_file_no_acl(fd) == 0 else { throw invalid() }
        var namedBefore = stat()
        guard name.withCString({ fstatat(parent, $0, &namedBefore, AT_SYMLINK_NOFOLLOW) }) == 0,
              same(before, namedBefore) else { throw invalid() }
        let data = try readAll(fd, maximum: maximumBytes)
        var after = stat()
        var namedAfter = stat()
        guard fstat(fd, &after) == 0, same(before, after),
              name.withCString({ fstatat(parent, $0, &namedAfter, AT_SYMLINK_NOFOLLOW) }) == 0,
              same(before, namedAfter), data.count == before.st_size else { throw invalid() }
        let code = try strictCode(data)
        do { return try PersonalEnrollmentInvitation.parsePrivateCode(code) }
        catch { throw invalid() }
    }

    static func readInvitationFromTerminal() throws -> PersonalEnrollmentInvitation {
        let fd = open("/dev/tty", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw invalid() }
        defer { close(fd) }
        try writeAll(fd, Array("Pairing code (input hidden): ".utf8))
        return try readInvitation(terminalFD: fd)
    }
    /// The production caller opens only its controlling terminal. This FD seam supports a PTY fixture.
    static func readInvitation(terminalFD fd: Int32) throws -> PersonalEnrollmentInvitation {
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var count = 0
        let result = bytes.withUnsafeMutableBytes {
            tractanda_private_terminal_line(fd, $0.baseAddress, $0.count, &count)
        }
        guard result == 0, count > 0, let code = String(bytes: bytes.prefix(count), encoding: .utf8) else { throw invalid() }
        do { return try PersonalEnrollmentInvitation.parsePrivateCode(code) }
        catch { throw invalid() }
    }

    static func writeInvitation(_ invitation: PersonalEnrollmentInvitation, toPrivateFile path: String) throws {
        let (parent, name) = try openParent(path)
        defer { close(parent) }
        let fd = name.withCString { openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw invalid() }
        var owned = stat()
        guard fstat(fd, &owned) == 0, owned.st_uid == getuid(), owned.st_nlink == 1,
              owned.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), owned.st_mode & 0o777 == 0o600,
              tractanda_secret_file_no_acl(fd) == 0 else {
            close(fd); removeCreated(parent, name, expected: owned); throw invalid()
        }
        let created = owned
        do {
            let bytes = Array((try invitation.privateCode() + "\n").utf8)
            try writeAll(fd, bytes)
            var named = stat()
            guard fsync(fd) == 0, fstat(fd, &owned) == 0, owned.st_nlink == 1,
                  owned.st_uid == getuid(), owned.st_mode & 0o777 == 0o600,
                  owned.st_size == bytes.count,
                  tractanda_secret_file_no_acl(fd) == 0,
                  name.withCString({ fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
                  named.st_dev == created.st_dev, named.st_ino == created.st_ino,
                  same(owned, named), fsync(parent) == 0 else { throw invalid() }
            close(fd)
        } catch {
            close(fd); removeCreated(parent, name, expected: created); throw invalid()
        }
    }

    static func writeInvitationToTerminal(_ invitation: PersonalEnrollmentInvitation) throws {
        let fd = open("/dev/tty", O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw invalid() }
        defer { close(fd) }
        guard isatty(fd) == 1 else { throw invalid() }
        try writeAll(fd, Array((try invitation.privateCode() + "\n").utf8))
    }

    private static func strictCode(_ data: Data) throws -> String {
        var bytes = Array(data)
        if bytes.last == 10 { bytes.removeLast() }
        guard !bytes.isEmpty, bytes.count <= maximumBytes, !bytes.contains(10), !bytes.contains(13),
              let value = String(bytes: bytes, encoding: .utf8) else { throw invalid() }
        return value
    }
    private static func readAll(_ fd: Int32, maximum: Int) throws -> Data {
        var result = [UInt8](); result.reserveCapacity(min(maximum, 1024))
        var buffer = [UInt8](repeating: 0, count: min(maximum + 1, 4096))
        while result.count <= maximum {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, min($0.count, maximum + 1 - result.count)) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { if n == 0 { break }; throw invalid() }
            result.append(contentsOf: buffer.prefix(n))
        }
        guard result.count <= maximum else { throw invalid() }
        return Data(result)
    }
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw invalid() }
            offset += n
        }
    }
    private static func openParent(_ path: String) throws -> (Int32, String) {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid() }
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last, name != ".", name != "..", !name.isEmpty else { throw invalid() }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw invalid() }
        for part in parts.dropLast() {
            guard part != ".", part != ".." else { close(fd); throw invalid() }
            let next = part.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { close(fd); throw invalid() }
            close(fd); fd = next
        }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700,
              st.st_mode & 0o7000 == 0,
              tractanda_secret_file_no_acl(fd) == 0 else { close(fd); throw invalid() }
        return (fd, name)
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink &&
        timestampSame(a, b)
    }
    private static func timestampSame(_ a: stat, _ b: stat) -> Bool {
        #if canImport(Darwin)
        return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        #else
        return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
            a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec
        #endif
    }
    private static func removeCreated(_ parent: Int32, _ name: String, expected: stat) {
        var current = stat()
        guard name.withCString({ fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
              current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
              current.st_uid == getuid(), current.st_nlink == 1 else { return }
        _ = name.withCString { unlinkat(parent, $0, 0) }; _ = fsync(parent)
    }
}
