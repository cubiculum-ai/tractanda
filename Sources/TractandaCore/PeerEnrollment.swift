import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Offline preparation only. This record grants no authority, membership or opening permission.
/// A later provisioning transaction must consume it under this writer lock and retain the gate
/// until independently validated bootstrap/activation receipts exist. There is no opening bypass.
package enum PeerEnrollment {
    static let intentName = ".tractanda-enrollment.json"
    private static let lockName = ".writer.lock"
    static let maximumBytes = 4096

    package struct Preparation: Codable, Equatable, Sendable {
        package let formatVersion: Int
        package let commonStoreID: String
        package let sourceReplicaID: String
        package let targetReplicaID: String
        package let operationID: String
    }

    /// The caller supplies an existing, private, dedicated empty directory. Never adopts a store.
    package static func prepareTarget(
        root: URL, commonStoreID: String, sourceReplicaID: String
    ) throws -> Preparation {
        try prepareTarget(
            root: root, commonStoreID: commonStoreID, sourceReplicaID: sourceReplicaID,
            allocate: UUID.makeVersion1)
    }

    static func prepareTarget(
        root: URL, commonStoreID: String, sourceReplicaID: String,
        allocate: () throws -> UUID, afterLockAcquisition: (() throws -> Void)? = nil,
        beforeIntentPublication: (() throws -> Void)? = nil,
        afterIntentPublication: (() throws -> Void)? = nil
    ) throws -> Preparation {
        try requireID(commonStoreID)
        try requireID(sourceReplicaID)
        guard commonStoreID != sourceReplicaID, root.path.hasPrefix("/"), root.path != "/",
            !root.path.utf8.contains(0)
        else { throw failure() }
        // Inspect the supplied leaf before resolving system aliases such as /tmp on macOS.
        let supplied = root.standardizedFileURL
        guard try FileMetadata.read(at: supplied).type == .directory else { throw failure() }
        let root = supplied.resolvingSymlinksInPath()
        let owner = tractanda_uid()
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { _ = close(fd) }
        var rootMetadata = stat()
        guard fstat(fd, &rootMetadata) == 0, rootMetadata.st_uid == owner,
            rootMetadata.st_mode & 0o077 == 0
        else { throw failure() }
        let files = DocumentContentFiles(
            root: root, ownerUID: owner, minimumFreeBytes: 0, rootDescriptor: fd)
        // Reject foreign data before even creating a writer-lock file.
        try inspectRoot(fd, files: files, owner: owner)
        let lock = openat(fd, lockName, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw failure() }
        defer { _ = close(lock) }
        try validateLock(lock, owner: owner)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw TractandaError("storeBusy", "Cannot lock enrollment target; another writer may be running.")
        }
        defer { _ = flock(lock, LOCK_UN) }
        // Same inode and same root as ordinary Store opening, followed by a locked recheck.
        let namedRoot = try FileMetadata.read(at: root)
        var namedLock = stat()
        var heldLock = stat()
        guard namedRoot.type == .directory, namedRoot.inode == UInt64(rootMetadata.st_ino),
            namedRoot.device == UInt64(rootMetadata.st_dev),
            fstatat(fd, lockName, &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
            fstat(lock, &heldLock) == 0, namedLock.st_ino == heldLock.st_ino,
            namedLock.st_dev == heldLock.st_dev
        else { throw failure() }
        try afterLockAcquisition?()
        try inspectRoot(fd, files: files, owner: owner)
        if let old = try load(files) {
            guard old.commonStoreID == commonStoreID, old.sourceReplicaID == sourceReplicaID else {
                throw TractandaError("enrollmentConflict", "Enrollment target has a different preparation.")
            }
            // Repair the uncertain acknowledgment boundary without allocating new identities.
            try files.synchronizeDirectory([])
            return old
        }
        let target = try allocate().uuidString.lowercased()
        let operation = try allocate().uuidString.lowercased()
        for id in [target, operation] { try requireID(id) }
        guard Set([commonStoreID, sourceReplicaID, target, operation]).count == 4 else {
            throw TractandaError("identifierCollision", "Enrollment requires distinct UUIDv1 identities.")
        }
        let preparation = Preparation(
            formatVersion: 1, commonStoreID: commonStoreID,
            sourceReplicaID: sourceReplicaID, targetReplicaID: target, operationID: operation)
        try beforeIntentPublication?()
        try files.writeImmutable(JSON.encode(preparation), path: [intentName], maximumBytes: maximumBytes)
        try afterIntentPublication?()
        return preparation
    }

    /// Called inside Store's writer-lock scope, before items/index/identity/recovery initialization.
    /// Malformed, unsafe or oversized preparation is also a closed gate, never absence.
    static func requireOrdinaryOpeningAllowed(root: URL, ownerUID: UInt32) throws {
        let files = DocumentContentFiles(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
        if try PeerEnrollmentActivation.requiresTargetProof(root: root, ownerUID: ownerUID) {
            guard try files.readIfPresent(path: [intentName], maximumBytes: maximumBytes) != nil else {
                throw PeerEnrollmentActivation.failure("Target lost its required permanent preparation.")
            }
            guard try PeerEnrollmentActivation.loadReceipt(files) != nil else {
                throw TractandaError("enrollmentPending", "Target enrollment is pending; ordinary store opening is disabled.")
            }
            guard try PeerEnrollmentActivation.loadRecord(files) != nil else {
                throw PeerEnrollmentActivation.failure("Target lost its required immutable activation request.")
            }
            try PeerEnrollmentActivation.requireActivated(root: root, ownerUID: ownerUID)
        }
    }

    private static func load(_ files: DocumentContentFiles) throws -> Preparation? {
        guard let bytes = try files.readIfPresent(path: [intentName], maximumBytes: maximumBytes) else {
            return nil
        }
        let value = try JSON.decode(Preparation.self, bytes)
        guard try JSON.encode(value) == bytes, value.formatVersion == 1 else { throw failure() }
        let ids = [value.commonStoreID, value.sourceReplicaID, value.targetReplicaID, value.operationID]
        for id in ids { try requireID(id) }
        guard Set(ids).count == ids.count else { throw failure() }
        return value
    }

    private static func requireID(_ value: String) throws {
        guard let id = UUID(uuidString: value), id.version1Components != nil,
            id.uuidString.lowercased() == value
        else { throw failure() }
    }

    private static func validateLock(_ fd: Int32, owner: UInt32) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            metadata.st_uid == owner, metadata.st_mode & 0o777 == 0o600,
            metadata.st_size == 0, metadata.st_nlink == 1
        else { throw failure() }
    }

    static func inspectRoot(
        _ fd: Int32, files: DocumentContentFiles, owner: UInt32
    ) throws {
        let preparation = try load(files)
        var intent = stat()
        if preparation != nil {
            guard fstatat(fd, intentName, &intent, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure() }
        }
        let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scan >= 0 else { throw failure() }
        defer { _ = close(scan) }
        var count = 0
        var aliases = 0
        try POSIXDirectory.withEntries(descriptor: scan) { name in
            count += 1
            guard count <= 3 else { throw failure() }
            if name == intentName { return true }
            if name == lockName {
                let lock = openat(fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard lock >= 0 else { throw failure() }
                defer { _ = close(lock) }
                try validateLock(lock, owner: owner)
                return true
            }
            // writeImmutable can die after linking intent but before unlinking its temporary.
            // Only that exact sealed inode is a transaction artifact, never arbitrary temp data.
            var alias = stat()
            guard preparation != nil, name.hasPrefix(".dependency-"), name.hasSuffix(".tmp"),
                fstatat(fd, name, &alias, AT_SYMLINK_NOFOLLOW) == 0,
                alias.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                alias.st_dev == intent.st_dev, alias.st_ino == intent.st_ino
            else { throw failure() }
            aliases += 1
            guard aliases <= 1 else { throw failure() }
            return true
        }
        if preparation != nil {
            var finalIntent = stat()
            guard fstatat(fd, intentName, &finalIntent, AT_SYMLINK_NOFOLLOW) == 0,
                finalIntent.st_dev == intent.st_dev, finalIntent.st_ino == intent.st_ino,
                finalIntent.st_nlink == 1 + aliases
            else { throw failure() }
        }
    }

    private static func failure() -> TractandaError {
        TractandaError(
            "invalidEnrollmentTarget", "Enrollment requires a safe empty target or its exact preparation.")
    }
}
