import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Precise old operational credential disposal after every member committed. No canonical
/// revision/payload path is accepted, and a current or pending digest is never removed.
enum PersonalEnrollmentCredentialCleanup {
    static func remove(
        root: URL, ownerUID: UInt32, old: PersonalMembershipConfiguration,
        current: PersonalMembershipConfiguration, pending: PersonalMembershipConfiguration?
    ) throws {
        let digest = try old.digest
        let currentDigest = try current.digest
        let pendingDigest = try pending?.digest
        guard currentDigest != digest, pendingDigest != digest else {
            throw PersonalEnrollmentError.conflict()
        }
        let name = ".personal-credentials-" + digest + ".json"
        guard
            let aliases = try PersonalSyncConfiguration.read(
                PersonalCredentialAliases.self, root: root,
                name: name, ownerUID: ownerUID)
        else { return }
        guard aliases.configurationDigest == digest, aliases.aliases.count <= 512,
            aliases.aliases == Array(Set(aliases.aliases)).sorted()
        else { throw PersonalEnrollmentError.invalid() }
        let parent = tractanda_open_private_directory(root.path)
        guard parent >= 0 else { throw PersonalEnrollmentError.invalid() }
        defer { close(parent) }
        let keys = openat(parent, ".peer-credentials", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if keys < 0, errno != ENOENT { throw PersonalEnrollmentError.invalid() }
        if keys >= 0 {
            defer { close(keys) }
            var directory = stat()
            guard fstat(keys, &directory) == 0, directory.st_uid == ownerUID,
                directory.st_mode & 0o7777 == 0o700,
                tractanda_secret_file_no_acl(keys) == 0
            else { throw PersonalEnrollmentError.invalid() }
            for alias in aliases.aliases {
                let component = try PeerCredentialStore.path(peerID: alias, configurationDigest: digest)[1]
                let fd = openat(keys, component, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0, errno == ENOENT { continue }
                guard fd >= 0 else { throw PersonalEnrollmentError.invalid() }
                defer { close(fd) }
                var held = stat()
                var named = stat()
                guard fstat(fd, &held) == 0, held.st_uid == ownerUID, held.st_nlink == 1,
                    held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), held.st_mode & 0o7777 == 0o400,
                    tractanda_secret_file_no_acl(fd) == 0,
                    fstatat(keys, component, &named, AT_SYMLINK_NOFOLLOW) == 0,
                    named.st_dev == held.st_dev, named.st_ino == held.st_ino
                else { throw PersonalEnrollmentError.invalid() }
                guard unlinkat(keys, component, 0) == 0, fsync(keys) == 0, tractanda_durable_sync(fd) == 0
                else {
                    throw TractandaError(
                        "enrollmentPersistenceUncertain", "Resume exact old credential cleanup.")
                }
            }
        }
        try PersonalSyncConfiguration.remove(root: root, name: name)
    }
}
