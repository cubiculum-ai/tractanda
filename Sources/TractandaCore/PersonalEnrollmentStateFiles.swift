import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Bounded current runtime/job state only. The Store coordinator serializes calls. Lost or
/// invalid state disables enrollment; it is never a prerequisite for ordinary item reads.
package struct PersonalEnrollmentStateFiles {
    private let root: URL
    private static let names: Set<String> = [
        "target.bin", "replacement.bin", "renewal.bin", "job.bin", "member.bin", "routes.json", "keys.bin",
    ]
    private static let maximum = PersonalEnrollmentPrivateCodec.operationHeaderBytes + 68
    package init(root: URL) { self.root = root }
    private func directory(create: Bool) throws -> Int32? {
        let owner = tractanda_open_private_directory(root.path)
        guard owner >= 0 else { throw PersonalEnrollmentError.invalid() }
        defer { close(owner) }
        var directory = openat(owner, ".personal-enrollment", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0, errno == ENOENT {
            if !create { return nil }
            try capacity(owner, additional: 4096)
            guard mkdirat(owner, ".personal-enrollment", 0o700) == 0 || errno == EEXIST,
                fsync(owner) == 0
            else { throw PersonalEnrollmentError.invalid() }
            directory = openat(owner, ".personal-enrollment", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        var metadata = stat()
        guard directory >= 0, fstat(directory, &metadata) == 0, metadata.st_uid == tractanda_uid(),
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), metadata.st_mode & 0o7777 == 0o700,
            tractanda_secret_file_no_acl(directory) == 0
        else {
            if directory >= 0 { close(directory) }
            throw PersonalEnrollmentError.invalid()
        }
        return directory
    }
    private func capacity(_ descriptor: Int32, additional: Int) throws {
        var fs = statvfs()
        guard fstatvfs(descriptor, &fs) == 0, fs.f_frsize > 0 else { throw PersonalEnrollmentError.invalid() }
        let available = UInt64(fs.f_bavail).multipliedReportingOverflow(by: UInt64(fs.f_frsize))
        guard !available.overflow, available.partialValue >= UInt64(10 * 1024 * 1024 * 1024 + additional)
        else {
            throw TractandaError("resourceLimit", "Enrollment state would cross its filesystem reserve.")
        }
    }
    private func capture(_ name: String, parent: Int32) throws -> Data? {
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        let result = tractanda_capture_private_artifact_at(
            parent, name, &pointer, &count, UInt32(Self.maximum))
        if result == 1 { return nil }
        guard result == 0, let pointer else { throw PersonalEnrollmentError.invalid() }
        defer { tractanda_private_free(pointer, count) }
        return Data(bytes: pointer, count: Int(count))
    }
    package func read(_ name: String) throws -> Data? {
        guard Self.names.contains(name) else { throw PersonalEnrollmentError.invalid() }
        guard let parent = try directory(create: false) else { return nil }
        defer { close(parent) }
        return try capture(name, parent: parent)
    }
    package func replace(
        _ name: String, bytes: Data, expected: Data?, beforePublication: () throws -> Void = {}
    ) throws {
        guard Self.names.contains(name), !bytes.isEmpty, bytes.count <= Self.maximum,
            let parent = try directory(create: true)
        else { throw PersonalEnrollmentError.invalid() }
        defer { close(parent) }
        guard try capture(name, parent: parent) == expected else { throw PersonalEnrollmentError.conflict() }
        try capacity(parent, additional: bytes.count)
        let temporary = ".operation-" + UUID().uuidString.lowercased()
        let staged = ".staged-" + UUID().uuidString.lowercased()
        let result = bytes.withUnsafeBytes {
            tractanda_write_private_artifact_at(parent, temporary, staged, $0.baseAddress, UInt32($0.count))
        }
        defer { _ = unlinkat(parent, staged, 0) }
        guard result == 0 else {
            throw TractandaError(
                "enrollmentPersistenceUncertain",
                "Resume the exact enrollment operation after checking its protected state.")
        }
        let durable = openat(parent, staged, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard durable >= 0 else { throw PersonalEnrollmentError.invalid() }
        defer { close(durable) }
        guard tractanda_durable_sync(durable) == 0 else {
            throw TractandaError(
                "enrollmentPersistenceUncertain", "Resume the exact protected enrollment state.")
        }
        guard try capture(name, parent: parent) == expected else { throw PersonalEnrollmentError.conflict() }
        try beforePublication()
        guard renameat(parent, staged, parent, name) == 0, fsync(parent) == 0,
            tractanda_durable_sync(durable) == 0
        else {
            throw TractandaError(
                "enrollmentPersistenceUncertain",
                "Resume the exact enrollment operation after checking its protected state.")
        }
    }
    package func remove(_ name: String, expected: Data) throws {
        guard Self.names.contains(name), let parent = try directory(create: false) else {
            throw PersonalEnrollmentError.conflict()
        }
        defer { close(parent) }
        guard let current = try capture(name, parent: parent) else { return }
        guard current == expected else { throw PersonalEnrollmentError.conflict() }
        let durable = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard durable >= 0 else { throw PersonalEnrollmentError.invalid() }
        defer { close(durable) }
        guard unlinkat(parent, name, 0) == 0, fsync(parent) == 0, tractanda_durable_sync(durable) == 0 else {
            throw TractandaError(
                "enrollmentPersistenceUncertain", "Resume the exact protected enrollment cleanup.")
        }
    }
}
