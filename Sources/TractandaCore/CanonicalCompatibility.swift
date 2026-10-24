import CTractandaPlatform
import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// The implementation declaration is distinct from each Store's durable activation. Existing
/// initialized14 stores remain read-only until an explicit coordinated15 transition.
enum AtomicAuthorityCompatibility {
    static let capability = AtomicAuthorityFormat.profile
    static let minimumReaderLevel = 15
    private static let retainedCapabilities = [
        "tractanda.peer-enrollment-approval.v1", "tractanda.peer-origin-admission.v1",
        "tractanda.peer-enrollment-activation.v1", "tractanda.peer-enrollment-target.v1",
        "tractanda.authority.v1", "tractanda.authority-causal.v1", "tractanda.authority-review.v1",
        "tractanda.peer-lifecycle.v1", "tractanda.shared-authority.v1", "tractanda.payload-placement.v1",
        "tractanda.peer-originals.v1", "tractanda.document-placement.v1", "tractanda.peer-documents.v1",
    ]
    static let support = CanonicalFormatSupport(
        readerLevel: minimumReaderLevel, writerLevel: minimumReaderLevel, read: [1, 2], write: [2],
        capabilities: (retainedCapabilities + [capability]).sorted(),
        writeCapabilities: (retainedCapabilities + [capability]).sorted())
    static func requireWriter(_ support: CanonicalFormatSupport) throws {
        try support.validate()
        guard support.readerLevel >= minimumReaderLevel, support.writerLevel >= minimumReaderLevel,
            support.capabilities.contains(capability), support.writeCapabilities.contains(capability)
        else {
            throw TractandaError(
                "incompatibleCanonicalReader",
                "Atomic publication requires explicit floor15 reader/writer support and capability.")
        }
    }
}

/// Canonical semantics, independent of wire/API versions. Future authority persistence needs a
/// new level/capability even when its item MIME version remains 2.
public struct CanonicalFormatSupport: Codable, Equatable, Sendable {
    public static let profileName = "tractanda.canonical-formats.v1"
    public static let current = Self(
        readerLevel: 15, writerLevel: 15, read: [1, 2], write: [2],
        capabilities: [
            AtomicAuthorityFormat.profile,
            "tractanda.peer-enrollment-approval.v1", "tractanda.peer-origin-admission.v1",
            "tractanda.peer-enrollment-activation.v1", "tractanda.peer-enrollment-target.v1",
            "tractanda.authority.v1", "tractanda.authority-causal.v1", "tractanda.authority-review.v1",
            "tractanda.peer-lifecycle.v1", "tractanda.shared-authority.v1", "tractanda.payload-placement.v1",
            "tractanda.peer-originals.v1", "tractanda.document-placement.v1", "tractanda.peer-documents.v1",
        ].sorted(),
        writeCapabilities: [
            AtomicAuthorityFormat.profile,
            "tractanda.peer-enrollment-approval.v1", "tractanda.peer-origin-admission.v1",
            "tractanda.peer-enrollment-activation.v1", "tractanda.peer-enrollment-target.v1",
            "tractanda.authority.v1", "tractanda.authority-causal.v1", "tractanda.authority-review.v1",
            "tractanda.peer-lifecycle.v1", "tractanda.shared-authority.v1", "tractanda.payload-placement.v1",
            "tractanda.peer-originals.v1", "tractanda.document-placement.v1", "tractanda.peer-documents.v1",
        ].sorted())
    public static let legacy = Self(readerLevel: 1, writerLevel: 1, read: [1], write: [1])
    public let profile: String
    public let readerLevel: Int
    public let writerLevel: Int
    public let read: [Int]
    public let write: [Int]
    public let capabilities: [String]
    public let writeCapabilities: [String]
    public init(
        readerLevel: Int, writerLevel: Int, read: [Int], write: [Int], capabilities: [String] = [],
        writeCapabilities: [String] = []
    ) {
        profile = Self.profileName
        self.readerLevel = readerLevel
        self.writerLevel = writerLevel
        self.read = read
        self.write = write
        self.capabilities = capabilities
        self.writeCapabilities = writeCapabilities
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case profile, readerLevel, writerLevel, read, write, capabilities, writeCapabilities
    }
    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: CanonicalCompatibilityKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw TractandaError("unknownCanonicalCompatibility", "Unknown format declaration keys.")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decode(String.self, forKey: .profile)
        readerLevel = try c.decode(Int.self, forKey: .readerLevel)
        writerLevel = try c.decode(Int.self, forKey: .writerLevel)
        read = try c.decode([Int].self, forKey: .read)
        write = try c.decode([Int].self, forKey: .write)
        capabilities = try c.decode([String].self, forKey: .capabilities)
        writeCapabilities = try c.decode([String].self, forKey: .writeCapabilities)
        try validate()
    }
    public func validate() throws {
        guard profile == Self.profileName, (1...1024).contains(readerLevel),
            (1...readerLevel).contains(writerLevel),
            !read.isEmpty, !write.isEmpty, read == Array(Set(read)).sorted(),
            write == Array(Set(write)).sorted(),
            read.allSatisfy({ (1...1024).contains($0) }), Set(write).isSubset(of: read),
            capabilities == Array(Set(capabilities)).sorted(),
            writeCapabilities == Array(Set(writeCapabilities)).sorted(),
            capabilities.count <= 64, capabilities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
            Set(writeCapabilities).isSubset(of: capabilities),
            !capabilities.contains(AtomicAuthorityCompatibility.capability)
                || readerLevel >= AtomicAuthorityCompatibility.minimumReaderLevel,
            !writeCapabilities.contains(AtomicAuthorityCompatibility.capability)
                || writerLevel >= AtomicAuthorityCompatibility.minimumReaderLevel
        else {
            throw TractandaError(
                "unknownCanonicalCompatibility", "Invalid or unknown canonical format declaration.")
        }
    }
    public func require(_ requirement: CanonicalReaderRequirement) throws {
        try validate()
        try requirement.validate()
        guard readerLevel >= requirement.minimumReaderLevel,
            Set(requirement.recordFormats).isSubset(of: read),
            Set(requirement.capabilities).isSubset(of: capabilities)
        else {
            throw TractandaError(
                "incompatibleCanonicalReader",
                "Reader cannot open retained canonical data. Keep services stopped and use a reader supporting the required compatibility level; never restore a backup over newer writes."
            )
        }
    }
    /// A running writer can advance its marker after another store's shared-client check.
    public func requireWriter(_ writer: Self) throws {
        try writer.validate()
        try validate()
        guard readerLevel >= writer.writerLevel, Set(writer.write).isSubset(of: read),
            Set(writer.writeCapabilities).isSubset(of: capabilities)
        else {
            throw TractandaError(
                "incompatibleCanonicalReader",
                "Shared client cannot read formats/semantics the registered writer may publish.")
        }
    }
}

public struct CanonicalReaderRequirement: Codable, Equatable, Sendable {
    public static let fileName = "canonical-reader.json"
    public static let profileName = "tractanda.canonical-reader.v1"
    public let profile: String
    public let storeID: String
    public let minimumReaderLevel: Int
    public let recordFormats: [Int]
    public let capabilities: [String]
    public init(storeID: String, minimumReaderLevel: Int, recordFormats: [Int], capabilities: [String] = []) {
        profile = Self.profileName
        self.storeID = storeID
        self.minimumReaderLevel = minimumReaderLevel
        self.recordFormats = recordFormats
        self.capabilities = capabilities
    }
    public func validate() throws {
        guard profile == Self.profileName, let id = UUID(uuidString: storeID), id.version1Components != nil,
            id.uuidString.lowercased() == storeID, (1...1024).contains(minimumReaderLevel),
            !recordFormats.isEmpty, recordFormats == Array(Set(recordFormats)).sorted(),
            recordFormats.allSatisfy({ (1...minimumReaderLevel).contains($0) }),
            capabilities == Array(Set(capabilities)).sorted(), capabilities.count <= 64,
            capabilities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
            !capabilities.contains(AtomicAuthorityCompatibility.capability)
                || minimumReaderLevel >= AtomicAuthorityCompatibility.minimumReaderLevel
        else {
            throw TractandaError(
                "unknownCanonicalCompatibility",
                "Invalid canonical reader requirement; services must remain stopped.")
        }
    }
    /// Internal persistence primitive only. Store must already own the actual lifetime flock and
    /// fresh authenticated administrator/all-active-node maintenance proof. An inode comparison
    /// cannot prove portable kernel flock ownership; this API does not manufacture that evidence.
    /// The borrowed descriptor is neither acquired nor unlocked here.
    static func transitionToAtomicAuthority(
        root: URL, ownerUID: UInt32, writerDescriptor: Int32,
        expectedRequirement: Self, expectedRequirementSHA256: String,
        support: CanonicalFormatSupport
    ) throws -> Self {
        try expectedRequirement.validate()
        _ = try AuthorityRecord.digest(.text(expectedRequirementSHA256))
        try AtomicAuthorityCompatibility.requireWriter(support)
        let custody = try AtomicWriterCustody(root: root, ownerUID: ownerUID, writer: writerDescriptor)
        defer { close(custody.directory) }
        let priorIdentity = try storeIdentity(root: root, ownerUID: ownerUID)
        guard
            let bytes = try privateMetadata(
                root: root, name: fileName, ownerUID: ownerUID, maximumBytes: 16 * 1024),
            AuthorityRecordCodec.sha256(bytes) == expectedRequirementSHA256,
            let prior = try load(root: root, ownerUID: ownerUID), prior == expectedRequirement,
            try JSON.encode(prior) == bytes,
            prior.storeID == priorIdentity
        else {
            throw TractandaError(
                "unknownCanonicalCompatibility", "Atomic transition lost its exact prior requirement/StoreID."
            )
        }
        let target = Self(
            storeID: prior.storeID,
            minimumReaderLevel: max(
                prior.minimumReaderLevel, AtomicAuthorityCompatibility.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(prior.capabilities + [AtomicAuthorityCompatibility.capability]).sorted())
        try target.validate()
        try support.require(target)
        guard try JSON.encode(target).count <= 16 * 1024 else {
            throw TractandaError(
                "resourceLimit", "Raised atomic requirement exceeds its existing metadata window.")
        }
        try custody.requireUnchanged()
        guard try storeIdentity(root: root, ownerUID: ownerUID) == priorIdentity,
            try privateMetadata(root: root, name: fileName, ownerUID: ownerUID, maximumBytes: 16 * 1024)
                == bytes,
            try load(root: root, ownerUID: ownerUID) == prior
        else {
            throw TractandaError("unknownCanonicalCompatibility", "Atomic transition's prior marker changed.")
        }
        if target != prior {
            try target.persistAtomicTransition(directory: custody.directory, ownerUID: ownerUID)
        } else {
            // A prior attempt may have renamed successfully but failed to acknowledge parent
            // durability. Exact retry must synchronize again even when no bytes need rewriting.
            let marker = openat(custody.directory, fileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard marker >= 0 else {
                throw TractandaError(
                    "canonicalCompatibilityWriteFailed", "Cannot reopen atomic requirement for durable retry."
                )
            }
            defer { close(marker) }
            guard fsync(marker) == 0, fsync(custody.directory) == 0 else {
                throw TractandaError(
                    "canonicalCompatibilityWriteFailed",
                    "Atomic retry durability is uncertain; do not publish.")
            }
        }
        try custody.requireUnchanged()
        guard try storeIdentity(root: root, ownerUID: ownerUID) == priorIdentity,
            try load(root: root, ownerUID: ownerUID) == target
        else {
            throw TractandaError(
                "canonicalCompatibilityWriteFailed",
                "Atomic requirement readback/StoreID is uncertain; do not publish.")
        }
        return target
    }

    /// Guard only: ordinary publication cannot activate or repair a missing atomic floor.
    static func beforeAtomicAuthorityPublication(
        root: URL, ownerUID: UInt32, support: CanonicalFormatSupport = .current
    ) throws {
        try AtomicAuthorityCompatibility.requireWriter(support)
        guard let prior = try load(root: root, ownerUID: ownerUID),
            prior.minimumReaderLevel >= AtomicAuthorityCompatibility.minimumReaderLevel,
            prior.capabilities.contains(AtomicAuthorityCompatibility.capability)
        else {
            throw TractandaError(
                "atomicAuthorityTransitionRequired",
                "Explicit coordinated atomic activation is required before publication.")
        }
        try support.require(prior)
    }

    private struct AtomicWriterCustody {
        let directory: Int32
        let root: URL
        let ownerUID: UInt32
        let writer: Int32
        let device: dev_t
        let inode: ino_t
        init(root: URL, ownerUID: UInt32, writer: Int32) throws {
            self.root = root
            self.ownerUID = ownerUID
            self.writer = writer
            directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else {
                throw TractandaError("storeBusy", "Atomic transition cannot open its private root.")
            }
            var value = stat()
            guard fstat(directory, &value) == 0 else {
                close(directory)
                throw TractandaError("storeBusy", "Atomic transition cannot inspect its root.")
            }
            device = value.st_dev
            inode = value.st_ino
            do { try requireUnchanged() } catch {
                close(directory)
                throw error
            }
        }
        func requireUnchanged() throws {
            let namedRoot = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard namedRoot >= 0 else {
                throw TractandaError("storeBusy", "Atomic transition root was replaced.")
            }
            defer { close(namedRoot) }
            var heldRoot = stat()
            var currentRoot = stat()
            var heldWriter = stat()
            var namedWriter = stat()
            guard fstat(directory, &heldRoot) == 0, fstat(namedRoot, &currentRoot) == 0,
                heldRoot.st_dev == device, heldRoot.st_ino == inode,
                currentRoot.st_dev == device, currentRoot.st_ino == inode,
                heldRoot.st_uid == ownerUID, heldRoot.st_mode & 0o7777 == 0o700,
                currentRoot.st_uid == ownerUID, currentRoot.st_mode == heldRoot.st_mode,
                tractanda_peer_configuration_no_mutation_acl(directory) == 0,
                tractanda_peer_configuration_no_mutation_acl(namedRoot) == 0,
                fstat(writer, &heldWriter) == 0,
                fstatat(directory, ".writer.lock", &namedWriter, AT_SYMLINK_NOFOLLOW) == 0,
                heldWriter.st_dev == namedWriter.st_dev, heldWriter.st_ino == namedWriter.st_ino,
                heldWriter.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                heldWriter.st_mode & 0o7777 == 0o600, namedWriter.st_mode == heldWriter.st_mode,
                heldWriter.st_uid == ownerUID, namedWriter.st_uid == ownerUID,
                heldWriter.st_nlink == 1, namedWriter.st_nlink == 1,
                tractanda_peer_configuration_no_mutation_acl(writer) == 0
            else {
                throw TractandaError(
                    "storeBusy", "Atomic transition lost private root/writer descriptor custody.")
            }
            for name in [CanonicalReaderRequirement.fileName, ".tractanda-store-identity.json"] {
                let file = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard file >= 0 else {
                    throw TractandaError("storeBusy", "Atomic transition metadata is missing or unsafe.")
                }
                defer { close(file) }
                var held = stat()
                var named = stat()
                guard fstat(file, &held) == 0,
                    fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                    held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                    held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), held.st_mode & 0o7777 == 0o600,
                    held.st_uid == ownerUID, named.st_uid == ownerUID,
                    held.st_nlink == 1, named.st_nlink == 1, named.st_mode == held.st_mode,
                    tractanda_peer_configuration_no_mutation_acl(file) == 0
                else {
                    throw TractandaError("storeBusy", "Atomic transition lost protected metadata custody.")
                }
            }
        }
    }

    private func persistAtomicTransition(directory: Int32, ownerUID: UInt32) throws {
        let temporary = ".atomic-reader-" + (try UUID.makeVersion1().uuidString.lowercased()) + ".stage"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw TractandaError(
                "canonicalCompatibilityWriteFailed", "Cannot stage atomic reader requirement.")
        }
        defer {
            var held = stat()
            var named = stat()
            if fstat(fd, &held) == 0,
                fstatat(directory, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
                held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                unlinkat(directory, temporary, 0) == 0
            {
                _ = fsync(directory)
            }
            close(fd)
        }
        guard fchown(fd, ownerUID, gid_t.max) == 0, fchmod(fd, 0o600) == 0,
            tractanda_peer_configuration_no_mutation_acl(fd) == 0
        else {
            throw TractandaError(
                "canonicalCompatibilityWriteFailed", "Cannot retain private atomic requirement custody.")
        }
        let bytes = try JSON.encode(self)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try Task.checkCancellation()
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw TractandaError(
                        "canonicalCompatibilityWriteFailed", "Cannot write atomic requirement.")
                }
                offset += count
            }
        }
        var held = stat()
        var named = stat()
        guard fsync(fd) == 0, fstat(fd, &held) == 0,
            fstatat(directory, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
            held.st_dev == named.st_dev, held.st_ino == named.st_ino, held.st_nlink == 1,
            held.st_uid == ownerUID, held.st_mode & 0o7777 == 0o600,
            held.st_size == bytes.count, tractanda_peer_configuration_no_mutation_acl(fd) == 0,
            renameat(directory, temporary, directory, Self.fileName) == 0, fsync(directory) == 0
        else {
            throw TractandaError(
                "canonicalCompatibilityWriteFailed",
                "Atomic requirement durability is uncertain; do not publish.")
        }
    }

    public static func withWriterLock<T>(root: URL, ownerUID: UInt32, _ body: () throws -> T) throws -> T {
        let path = root.appendingPathComponent(".writer.lock")
        let before = try FileMetadata.read(at: path)
        guard before.type == .regular, before.uid == ownerUID, before.mode & 0o077 == 0 else {
            throw TractandaError(
                "unknownCanonicalCompatibility",
                "Existing private writer lock is required for inventory admission.")
        }
        let lock = tractanda_lock(path.path)
        guard lock >= 0 else {
            throw TractandaError("storeBusy", "Writer must stop before canonical reader admission.")
        }
        defer { tractanda_unlock(lock) }
        var metadata = stat()
        guard fstat(lock, &metadata) == 0, metadata.st_ino == before.inode, metadata.st_nlink == 1,
            try FileMetadata.read(at: path) == before
        else {
            throw TractandaError("unknownCanonicalCompatibility", "Writer lock identity changed.")
        }
        return try body()
    }
    public static func storeIdentity(root: URL, ownerUID: UInt32) throws -> String {
        guard
            let data = try privateMetadata(
                root: root, name: ".tractanda-store-identity.json", ownerUID: ownerUID, maximumBytes: 4096)
        else {
            throw TractandaError("unknownCanonicalCompatibility", "Canonical StoreID proof is missing.")
        }
        struct Identity: Decodable {
            let formatVersion: Int
            let storeID: String
        }
        let identity = try JSON.decode(Identity.self, data)
        guard identity.formatVersion == 1, let uuid = UUID(uuidString: identity.storeID),
            uuid.version1Components != nil,
            uuid.uuidString.lowercased() == identity.storeID
        else {
            throw TractandaError(
                "unknownCanonicalCompatibility", "Canonical StoreID proof is missing or invalid.")
        }
        return identity.storeID
    }
    public static func load(root: URL, ownerUID: UInt32) throws -> Self? {
        guard
            let bytes = try privateMetadata(
                root: root, name: fileName, ownerUID: ownerUID, maximumBytes: 16 * 1024)
        else { return nil }
        guard let keys = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(keys.keys) == ["profile", "storeID", "minimumReaderLevel", "recordFormats", "capabilities"]
        else {
            throw TractandaError("unknownCanonicalCompatibility", "Unknown reader requirement keys.")
        }
        let object = try JSON.decode(Self.self, bytes)
        try object.validate()
        guard object.storeID == (try storeIdentity(root: root, ownerUID: ownerUID)) else {
            throw TractandaError(
                "unknownCanonicalCompatibility", "Reader requirement belongs to another store.")
        }
        return object
    }
    /// Caller has stopped the writer and holds this root's writer lock. Streaming inventory is
    /// bounded in work/bytes; it never collects history snapshots or follows record-tree links.
    public static func admitQuiescent(
        root: URL, ownerUID: UInt32, maximumRecords: Int = 1_000_000,
        maximumBytes: UInt64 = 256 * 1024 * 1024 * 1024, persist: Bool = true
    ) throws -> Self {
        guard (1...1_000_000).contains(maximumRecords), maximumBytes > 0 else {
            throw TractandaError("resourceLimit", "Invalid canonical inventory bounds.")
        }
        let identity = try storeIdentity(root: root, ownerUID: ownerUID)
        let prior = try load(root: root, ownerUID: ownerUID)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("authority").path),
            (prior?.minimumReaderLevel ?? 1) < 3
        {
            throw TractandaError(
                "unknownCanonicalCompatibility",
                "Authority data without its durable reader floor requires stopped recovery; item MIME inventory is insufficient."
            )
        }
        var formats = Set(prior?.recordFormats ?? [1])
        var count = 0
        var visited = 0
        var bytes: UInt64 = 0
        func walk(_ directory: URL, depth: Int) throws {
            guard depth <= 7 else {
                throw TractandaError("unknownCanonicalCompatibility", "Unrecognized canonical record tree.")
            }
            try POSIXDirectory.withEntries(at: directory) { name in
                visited += 1
                guard visited <= maximumRecords * 8 else {
                    throw TractandaError(
                        "resourceLimit", "Canonical compatibility inventory exceeds its entry window.")
                }
                let path = directory.appendingPathComponent(name)
                let before = try FileMetadata.read(at: path)
                if before.type == .directory {
                    guard
                        (before.uid == ownerUID && before.mode & 0o077 == 0)
                            || tractanda_path_read_only(path.path) == 1
                    else {
                        throw TractandaError(
                            "unknownCanonicalCompatibility", "Unsafe canonical inventory directory.")
                    }
                    try walk(path, depth: depth + 1)
                    return true
                }
                guard before.type == .regular else {
                    throw TractandaError(
                        "unknownCanonicalCompatibility",
                        "Links/special files cannot prove canonical compatibility.")
                }
                if !name.hasSuffix(".tractanda") {
                    let pieces = name.components(separatedBy: ".tractanda.")
                    if pieces.count == 2, UUID(uuidString: pieces[0]) != nil, pieces[1].count == 6,
                        pieces[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
                    {
                        return true
                    }
                    throw TractandaError(
                        "unknownCanonicalCompatibility", "Unknown canonical file prevents reader admission.")
                }
                count += 1
                guard count <= maximumRecords, before.size <= 8 * 1024 * 1024,
                    before.size <= maximumBytes - bytes,
                    (before.uid == ownerUID && before.mode & 0o077 == 0)
                        || tractanda_path_read_only(path.path) == 1
                else {
                    throw TractandaError(
                        "resourceLimit",
                        "Canonical compatibility inventory cannot safely read this record within its window.")
                }
                bytes += before.size
                let data = try Data(contentsOf: path)
                let revision = try RecordCodec.decode(data)
                guard try FileMetadata.read(at: path) == before, UInt64(data.count) == before.size,
                    CanonicalRecordPath.validate(
                        String(path.path.dropFirst(root.path.count + 1)), itemID: revision.itemID,
                        revisionID: revision.revisionID)
                else {
                    throw TractandaError(
                        "unknownCanonicalCompatibility", "Canonical inventory file identity/path changed.")
                }
                formats.insert(revision.formatVersion)
                return true
            }
        }
        try walk(root.appendingPathComponent("items"), depth: 0)
        let result = Self(
            storeID: identity, minimumReaderLevel: max(prior?.minimumReaderLevel ?? 1, formats.max() ?? 1),
            recordFormats: formats.sorted(), capabilities: prior?.capabilities ?? [])
        try result.validate()
        if persist, prior != result { try result.persist(root: root, ownerUID: ownerUID) }
        return result
    }
    /// Caller owns the Store root lock. Complete this fsync before immutable record publication.
    public static func beforePublication(
        root: URL, ownerUID: UInt32, format: Int, beforePersist: (() throws -> Void)? = nil
    ) throws {
        var previous = try load(root: root, ownerUID: ownerUID)
        if previous == nil || previous!.minimumReaderLevel < format {
            previous = try admitQuiescent(root: root, ownerUID: ownerUID, persist: false)
        }
        let old = previous!
        let raised = Self(
            storeID: old.storeID, minimumReaderLevel: max(old.minimumReaderLevel, format),
            recordFormats: Set(old.recordFormats + [format]).sorted(), capabilities: old.capabilities)
        try CanonicalFormatSupport.current.require(raised)
        if raised != (try load(root: root, ownerUID: ownerUID)) {
            try beforePersist?()
            try raised.persist(root: root, ownerUID: ownerUID)
        }
    }
    /// Authority-aware callers hold the writer lock and enforce sealed controls before serving.
    /// Persist this monotonic capability floor before a bootstrap or sealed control has effects.
    static func beforePeerOriginalPublication(
        root: URL, ownerUID: UInt32, support: CanonicalFormatSupport = .current
    ) throws {
        let prior =
            try load(root: root, ownerUID: ownerUID)
            ?? admitQuiescent(root: root, ownerUID: ownerUID, persist: false)
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(9, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(prior.capabilities + ["tractanda.peer-originals.v1"]).sorted())
        try support.require(raised)
        if raised != prior { try raised.persist(root: root, ownerUID: ownerUID) }
    }
    static func beforePayloadPlacementPublication(root: URL, ownerUID: UInt32) throws {
        let prior =
            try load(root: root, ownerUID: ownerUID)
            ?? admitQuiescent(root: root, ownerUID: ownerUID, persist: false)
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(8, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(prior.capabilities + [PayloadPlacement.capability]).sorted())
        try CanonicalFormatSupport.current.require(raised)
        if raised != prior { try raised.persist(root: root, ownerUID: ownerUID) }
    }
    static func beforeDocumentPlacementPublication(root: URL, ownerUID: UInt32) throws {
        let prior =
            try load(root: root, ownerUID: ownerUID)
            ?? admitQuiescent(root: root, ownerUID: ownerUID, persist: false)
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(10, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(prior.capabilities + [DocumentPlacement.capability]).sorted())
        try CanonicalFormatSupport.current.require(raised)
        if raised != prior { try raised.persist(root: root, ownerUID: ownerUID) }
    }
    static func beforePeerDocumentPublication(
        root: URL, ownerUID: UInt32, support: CanonicalFormatSupport = .current
    ) throws {
        try beforePeerOriginalPublication(root: root, ownerUID: ownerUID, support: support)
        guard let prior = try load(root: root, ownerUID: ownerUID) else {
            throw TractandaError("unknownCanonicalCompatibility", "Missing peer reader requirement.")
        }
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(11, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(prior.capabilities + ["tractanda.peer-documents.v1"]).sorted())
        try support.require(raised)
        if raised != prior { try raised.persist(root: root, ownerUID: ownerUID) }
    }
    static func beforeAuthorityPublication(
        root: URL, ownerUID: UInt32, support: CanonicalFormatSupport = .current
    ) throws {
        let prior =
            try load(root: root, ownerUID: ownerUID)
            ?? admitQuiescent(root: root, ownerUID: ownerUID, persist: false)
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(7, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(
                prior.capabilities + [AuthorityStore.capability, "tractanda.shared-authority.v1"]
            ).sorted())
        try support.require(raised)
        if try prior != raised || load(root: root, ownerUID: ownerUID) == nil {
            try raised.persist(root: root, ownerUID: ownerUID)
        }
    }
    static func beforeControlPublication(
        root: URL, ownerUID: UInt32, support: CanonicalFormatSupport = .current
    ) throws {
        try beforeAuthorityPublication(root: root, ownerUID: ownerUID, support: support)
        guard let prior = try load(root: root, ownerUID: ownerUID) else {
            throw TractandaError("unknownCanonicalCompatibility", "Missing authority reader requirement.")
        }
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(4, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(prior.capabilities + [AuthorityStore.causalCapability]).sorted())
        try support.require(raised)
        if raised != prior { try raised.persist(root: root, ownerUID: ownerUID) }
    }
    static func beforeReviewPublication(
        root: URL, ownerUID: UInt32, support: CanonicalFormatSupport = .current
    ) throws {
        try beforeControlPublication(root: root, ownerUID: ownerUID, support: support)
        guard let prior = try load(root: root, ownerUID: ownerUID) else {
            throw TractandaError("unknownCanonicalCompatibility", "Missing causal reader requirement.")
        }
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(5, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(prior.capabilities + [AuthorityStore.reviewCapability]).sorted())
        try support.require(raised)
        if raised != prior { try raised.persist(root: root, ownerUID: ownerUID) }
    }
    static func beforePeerLifecyclePublication(
        root: URL, ownerUID: UInt32, support: CanonicalFormatSupport = .current
    ) throws {
        try beforeReviewPublication(root: root, ownerUID: ownerUID, support: support)
        guard let prior = try load(root: root, ownerUID: ownerUID) else {
            throw TractandaError("unknownCanonicalCompatibility", "Missing lifecycle reader requirement.")
        }
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(7, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(
                prior.capabilities + [PeerLifecycle.capability, "tractanda.shared-authority.v1"]
            ).sorted())
        try support.require(raised)
        if raised != prior { try raised.persist(root: root, ownerUID: ownerUID) }
    }
    static func beforeEnrollmentApprovalPublication(
        root: URL, ownerUID: UInt32, support: CanonicalFormatSupport = .current
    ) throws {
        try beforeControlPublication(root: root, ownerUID: ownerUID, support: support)
        guard let prior = try load(root: root, ownerUID: ownerUID) else {
            throw TractandaError("unknownCanonicalCompatibility", "Missing authority reader requirement.")
        }
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(12, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(prior.capabilities + [PeerEnrollmentApproval.capability]).sorted())
        try support.require(raised)
        if raised != prior { try raised.persist(root: root, ownerUID: ownerUID) }
    }
    static func beforeOriginAdmissionPublication(
        root: URL, ownerUID: UInt32, support: CanonicalFormatSupport = .current
    ) throws {
        try beforeEnrollmentApprovalPublication(root: root, ownerUID: ownerUID, support: support)
        guard let prior = try load(root: root, ownerUID: ownerUID) else {
            throw TractandaError("unknownCanonicalCompatibility", "Missing admission reader requirement.")
        }
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(13, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(prior.capabilities + [PeerOriginAdmission.capability]).sorted())
        try support.require(raised)
        if raised != prior { try raised.persist(root: root, ownerUID: ownerUID) }
    }
    static func beforeEnrollmentActivationPublication(
        root: URL, ownerUID: UInt32, support: CanonicalFormatSupport = .current
    ) throws {
        try beforeOriginAdmissionPublication(root: root, ownerUID: ownerUID, support: support)
        guard let prior = try load(root: root, ownerUID: ownerUID) else {
            throw TractandaError("unknownCanonicalCompatibility", "Missing activation reader requirement.")
        }
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(14, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(prior.capabilities + [PeerEnrollmentActivation.capability]).sorted())
        try support.require(raised)
        if raised != prior { try raised.persist(root: root, ownerUID: ownerUID) }
    }
    static func beforeTargetEnrollmentPublication(
        root: URL, ownerUID: UInt32, support: CanonicalFormatSupport = .current
    ) throws {
        try beforeEnrollmentActivationPublication(root: root, ownerUID: ownerUID, support: support)
        guard let prior = try load(root: root, ownerUID: ownerUID) else {
            throw TractandaError("unknownCanonicalCompatibility", "Missing required target role marker.")
        }
        let raised = Self(
            storeID: prior.storeID, minimumReaderLevel: max(14, prior.minimumReaderLevel),
            recordFormats: prior.recordFormats,
            capabilities: Set(prior.capabilities + [PeerEnrollmentActivation.targetCapability]).sorted())
        try support.require(raised)
        if raised != prior { try raised.persist(root: root, ownerUID: ownerUID) }
    }
    private static func privateMetadata(root: URL, name: String, ownerUID: UInt32, maximumBytes: Int) throws
        -> Data?
    {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            throw TractandaError("unknownCanonicalCompatibility", "Cannot open private canonical root.")
        }
        defer { close(directory) }
        var parent = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == ownerUID, parent.st_mode & 0o077 == 0 else {
            throw TractandaError(
                "unknownCanonicalCompatibility", "Canonical root ownership/privacy is invalid.")
        }
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw TractandaError("unknownCanonicalCompatibility", "Private reader metadata is unsafe.")
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            before.st_nlink == 1,
            before.st_uid == ownerUID, before.st_mode & 0o777 == 0o600, before.st_size > 0,
            before.st_size <= maximumBytes
        else {
            throw TractandaError(
                "unknownCanonicalCompatibility", "Private reader metadata must retain bounded 0600 ownership."
            )
        }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let amount = read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else {
                    throw TractandaError(
                        "unknownCanonicalCompatibility", "Private reader metadata changed during reading.")
                }
                offset += amount
            }
        }
        var after = stat()
        var current = stat()
        guard fstat(descriptor, &after) == 0,
            name.withCString({ fstatat(directory, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0
        else {
            throw TractandaError(
                "unknownCanonicalCompatibility", "Cannot recheck private reader metadata identity.")
        }
        #if canImport(Darwin)
            let unchangedTime =
                before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        #else
            let unchangedTime =
                before.st_mtim.tv_sec == after.st_mtim.tv_sec
                && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec
        #endif
        guard unchangedTime, before.st_ino == after.st_ino, before.st_size == after.st_size,
            before.st_uid == after.st_uid,
            before.st_mode == after.st_mode, before.st_ino == current.st_ino, after.st_nlink == 1,
            current.st_mode == before.st_mode, current.st_uid == ownerUID, current.st_size == before.st_size
        else {
            throw TractandaError("unknownCanonicalCompatibility", "Private reader metadata identity changed.")
        }
        return data
    }

    private func persist(root: URL, ownerUID: UInt32) throws {
        try CanonicalMaintenanceContext.deny(
            root: root, path: [Self.fileName], operation: "canonical reader capability publication")
        try validate()
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            throw TractandaError(
                "canonicalCompatibilityWriteFailed", "Cannot open canonical requirement root.")
        }
        defer { close(directory) }
        let temporary = ".reader-requirement-" + UUID().uuidString + ".stage"
        let descriptor = temporary.withCString {
            openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            throw TractandaError("canonicalCompatibilityWriteFailed", "Cannot create requirement stage.")
        }
        defer {
            close(descriptor)
            _ = temporary.withCString { unlinkat(directory, $0, 0) }
        }
        guard fchown(descriptor, ownerUID, gid_t.max) == 0 else {
            throw TractandaError(
                "canonicalCompatibilityWriteFailed", "Cannot retain private requirement ownership.")
        }
        let data = try JSON.encode(self)
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let written = write(
                    descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw TractandaError(
                        "canonicalCompatibilityWriteFailed", "Cannot write reader requirement.")
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw TractandaError(
                "canonicalCompatibilityWriteFailed", "Cannot synchronize reader requirement.")
        }
        let renamed = temporary.withCString { source in
            Self.fileName.withCString { renameat(directory, source, directory, $0) }
        }
        guard renamed == 0, fsync(directory) == 0 else {
            throw TractandaError(
                "canonicalCompatibilityWriteFailed",
                "Requirement durability is uncertain; no newer record may be published.")
        }
    }
}

private struct CanonicalCompatibilityKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
