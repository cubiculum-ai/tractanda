import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Caller-private disk framing, never a canonical seal or an authorization decision.
/// Original bytes stay with the caller; only descriptors, allocations and index pages live here.
final class PeerLocalPackageArchive {
    struct Limits {
        let maximumStoredBytes: UInt64
        var maximumObjects = PeerPackage.Limits().maximumObjects
        var maximumWork = PeerPackage.Limits().maximumWork
        var maximumDepth = PeerPackage.Limits().maximumDepth
        var minimumFreeBytes: Int64 = 10 * 1024 * 1024 * 1024
    }
    private struct Reservation: Codable, Equatable {
        let profile: String
        let storeID: String
        let packageID: String
        let inputIdentity: String
    }
    private struct Address: Codable, Equatable {
        let level: Int
        let ordinal: Int
    }
    private struct Seal: Codable, Equatable {
        let manifest: PeerPackage.Manifest
        let inputIdentity: String
        let inputCount: Int
        // One count per tree height, never a level's descriptors.
        let levelCounts: [Int]
    }
    private let files: Files
    private let limits: Limits
    private let progress: (() throws -> Void)?
    private var work = 0

    init(root: URL, limits: Limits, progress: (() throws -> Void)? = nil) throws {
        guard limits.maximumStoredBytes >= 8192,
            (1...PeerPackage.Limits().maximumObjects).contains(limits.maximumObjects),
            (1...PeerPackage.Limits().maximumWork).contains(limits.maximumWork),
            (1...PeerPackage.Limits().maximumDepth).contains(limits.maximumDepth),
            limits.minimumFreeBytes >= 0
        else { throw Self.failure("Invalid private package budgets.") }
        self.limits = limits
        self.progress = progress
        files = try Files(root: root, limits: limits)
    }
    private static func failure(_ text: String) -> TractandaError {
        .init("invalidPeerPackage", text)
    }
    private func tick() throws {
        try Task.checkCancellation()
        guard work < limits.maximumWork else {
            throw TractandaError("resourceLimit", "Private package work allowance exhausted.")
        }
        work += 1
        try progress?()
        try files.checkLease()
    }
    private func inputPath(_ ordinal: Int) -> [String] {
        ["inputs", String(ordinal / 128), String(ordinal) + ".json"]
    }
    private func addressPath(_ address: Address, _ suffix: String) -> [String] {
        ["levels", String(address.level), String(address.ordinal / 128), String(address.ordinal) + suffix]
    }
    private func decode<T: Codable>(_ type: T.Type, _ path: [String]) throws -> T {
        try PeerPackage.decode(type, files.read(path))
    }
    private func write<T: Encodable>(_ value: T, _ path: [String]) throws {
        try files.put(JSON.encode(value), at: path)
    }
    private func requireInput(_ object: PeerPackage.Object, after previous: String?) throws {
        try object.validate()
        guard [.item, .authority].contains(object.kind), object.part == nil,
            previous.map({ $0 < object.id }) ?? true
        else { throw Self.failure("Local inputs must be ordered unique item/authority descriptors.") }
    }
    private func page(_ address: Address) throws -> (PeerPackage.Object, Data, PeerPackage.Page) {
        let object = try decode(PeerPackage.Object.self, addressPath(address, ".descriptor"))
        try object.validate()
        guard object.kind == .index,
            try decode(Address.self, ["page-ids", object.id]) == address,
            try decode(String.self, addressPath(address, ".id")) == object.id
        else { throw Self.failure("Private page allocation binding differs.") }
        let bytes = try files.read(addressPath(address, ".page"))
        guard bytes.count == object.length, AuthorityRecordCodec.sha256(bytes) == object.sha256 else {
            throw Self.failure("Private page bytes differ from their descriptor.")
        }
        let value = try PeerPackage.decode(PeerPackage.Page.self, bytes)
        try value.validate()
        return (object, bytes, value)
    }
    private func putPage(_ value: PeerPackage.Page, address: Address) throws -> PeerPackage.Object {
        try tick()
        try value.validate()
        let bytes = try JSON.encode(value)
        guard bytes.count <= PeerPackage.maximumPageBytes else {
            throw TractandaError("resourceLimit", "Complete encoded package page exceeds its byte window.")
        }
        let allocation = addressPath(address, ".id")
        let id: String
        if let old = try files.optional(allocation) {
            id = try PeerPackage.decode(String.self, old)
            _ = try AuthorityRecord.persistentID(.text(id))
        } else {
            id = try UUID.makeVersion1().uuidString.lowercased()
            try write(id, allocation)
        }
        guard try files.optional(["input-ids", id]) == nil else {
            throw Self.failure("Index allocation collides with an original identity.")
        }
        try write(address, ["page-ids", id])
        let object = PeerPackage.Object(
            kind: .index, id: id, length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes))
        try object.validate()
        try files.put(bytes, at: addressPath(address, ".page"))
        try write(object, addressPath(address, ".descriptor"))
        return object
    }
    private func fits(_ references: [PeerPackage.Object], leaf: Bool) throws -> Bool {
        guard references.count <= 256 else { return false }
        return try JSON.encode(
            PeerPackage.Page(objects: leaf ? references : [], children: leaf ? [] : references)
        ).count <= PeerPackage.maximumPageBytes
    }

    /// Exact retries replay the complete ordered input and compare every durable prefix witness.
    /// A failed or interrupted attempt cannot publish a new root.
    func build(
        storeID: String, packageID: String, inputIdentity: String,
        objects: () throws -> PeerPackage.Object?
    ) throws -> PeerPackage.Manifest {
        _ = try AuthorityRecord.persistentID(.text(storeID))
        _ = try AuthorityRecord.persistentID(.text(packageID))
        _ = try AuthorityRecord.digest(.text(inputIdentity))
        let lease = try files.lock()
        defer { files.unlock(lease) }
        work = 0
        try tick()
        try write(
            Reservation(
                profile: PeerPackage.profile, storeID: storeID, packageID: packageID,
                inputIdentity: inputIdentity), ["reservation.json"])
        let completed = try files.optional(["root.json"]).map { try PeerPackage.decode(Seal.self, $0) }
        var inputCount = 0
        var previous: String?
        var buffer: [PeerPackage.Object] = []
        var leafCount = 0
        while let object = try objects() {
            try tick()
            if let completed, inputCount >= completed.inputCount {
                throw Self.failure("Completed private package input was extended.")
            }
            guard inputCount < limits.maximumObjects else {
                throw TractandaError("resourceLimit", "Private package original count exceeded.")
            }
            try requireInput(object, after: previous)
            guard try files.optional(["page-ids", object.id]) == nil else {
                throw Self.failure("Original identity collides with an index allocation.")
            }
            try write(object, inputPath(inputCount))
            try write(inputCount, ["input-ids", object.id])
            previous = object.id
            inputCount += 1
            if !(try fits(buffer + [object], leaf: true)) {
                guard !buffer.isEmpty else {
                    throw TractandaError("resourceLimit", "One descriptor cannot fit a package page.")
                }
                _ = try putPage(
                    .init(objects: buffer, children: []), address: .init(level: 0, ordinal: leafCount))
                leafCount += 1
                buffer.removeAll(keepingCapacity: true)
            }
            buffer.append(object)
        }
        try tick()
        guard inputCount > 0, try files.optional(inputPath(inputCount)) == nil else {
            throw Self.failure("Empty input or shortened immutable input prefix.")
        }
        _ = try putPage(.init(objects: buffer, children: []), address: .init(level: 0, ordinal: leafCount))
        leafCount += 1
        var counts = [leafCount]
        var level = 0
        while counts[level] > 1 {
            guard level + 1 < limits.maximumDepth else {
                throw TractandaError("resourceLimit", "Private package depth exceeded.")
            }
            var nextCount = 0
            buffer.removeAll(keepingCapacity: true)
            for ordinal in 0..<counts[level] {
                try tick()
                let child = try page(.init(level: level, ordinal: ordinal)).0
                if !(try fits(buffer + [child], leaf: false)) {
                    guard !buffer.isEmpty else {
                        throw TractandaError("resourceLimit", "One index descriptor cannot fit a page.")
                    }
                    _ = try putPage(
                        .init(objects: [], children: buffer),
                        address: .init(level: level + 1, ordinal: nextCount))
                    nextCount += 1
                    buffer.removeAll(keepingCapacity: true)
                }
                buffer.append(child)
            }
            _ = try putPage(
                .init(objects: [], children: buffer), address: .init(level: level + 1, ordinal: nextCount))
            nextCount += 1
            guard nextCount < counts[level] else {
                throw TractandaError("resourceLimit", "Package envelope cannot reduce its tree width.")
            }
            counts.append(nextCount)
            level += 1
        }
        let root = try page(.init(level: level, ordinal: 0)).0
        let manifest = PeerPackage.Manifest(packageID: packageID, storeID: storeID, root: root)
        try manifest.validate()
        let seal = Seal(
            manifest: manifest, inputIdentity: inputIdentity, inputCount: inputCount, levelCounts: counts)
        try validate(seal)
        try tick()
        // All page/witness/allocation publications and parent directories are durable first.
        try write(seal, ["root.json"])
        return manifest
    }

    private func validate(_ seal: Seal) throws {
        try seal.manifest.validate()
        let reservation = try decode(Reservation.self, ["reservation.json"])
        _ = try AuthorityRecord.digest(.text(reservation.inputIdentity))
        guard reservation.profile == seal.manifest.profile,
            reservation.storeID == seal.manifest.storeID, reservation.packageID == seal.manifest.packageID,
            reservation.inputIdentity == seal.inputIdentity,
            (1...limits.maximumObjects).contains(seal.inputCount),
            !seal.levelCounts.isEmpty, seal.levelCounts.count <= limits.maximumDepth,
            seal.levelCounts.last == 1,
            seal.levelCounts.allSatisfy({ (1...limits.maximumObjects).contains($0) })
        else { throw Self.failure("Private root/source/count binding differs.") }
        var remainingObjects = limits.maximumObjects - seal.inputCount
        for count in seal.levelCounts {
            guard count <= remainingObjects else {
                throw TractandaError(
                    "resourceLimit",
                    "Originals and generated indexes exceed the physical package object ceiling.")
            }
            remainingObjects -= count
        }
        var previous: String?
        for level in seal.levelCounts.indices {
            var offset = 0
            for ordinal in 0..<seal.levelCounts[level] {
                try tick()
                let (descriptor, _, value) = try page(.init(level: level, ordinal: ordinal))
                guard try files.optional(["input-ids", descriptor.id]) == nil else {
                    throw Self.failure("Generated index collides with an input identity.")
                }
                if level == 0 {
                    guard value.children.isEmpty else { throw Self.failure("Leaf has child indexes.") }
                    for object in value.objects {
                        try tick()
                        guard offset < seal.inputCount,
                            try decode(PeerPackage.Object.self, inputPath(offset)) == object,
                            try decode(Int.self, ["input-ids", object.id]) == offset
                        else { throw Self.failure("Leaf/input prefix differs.") }
                        try requireInput(object, after: previous)
                        previous = object.id
                        offset += 1
                    }
                } else {
                    guard value.objects.isEmpty else { throw Self.failure("Index node contains originals.") }
                    for child in value.children {
                        try tick()
                        guard offset < seal.levelCounts[level - 1],
                            try page(.init(level: level - 1, ordinal: offset)).0 == child
                        else { throw Self.failure("Index children differ from the preceding disk level.") }
                        offset += 1
                    }
                }
            }
            let expected = level == 0 ? seal.inputCount : seal.levelCounts[level - 1]
            guard offset == expected,
                try files.optional(addressPath(.init(level: level, ordinal: seal.levelCounts[level]), ".id"))
                    == nil
            else { throw Self.failure("Private level was shortened or its count differs.") }
            if level > 0, seal.levelCounts[level] >= seal.levelCounts[level - 1] {
                throw Self.failure("Private tree width does not reduce.")
            }
        }
        guard try files.optional(inputPath(seal.inputCount)) == nil,
            try files.optional(addressPath(.init(level: seal.levelCounts.count, ordinal: 0), ".id")) == nil,
            try page(.init(level: seal.levelCounts.count - 1, ordinal: 0)).0 == seal.manifest.root
        else { throw Self.failure("Private root or final input differs.") }
    }

    /// Validates the complete source-bound disk plan before yielding any generated index bytes.
    /// Uses the same exclusive custody lease as build; no reader scratch or mutation is needed.
    func forEachIndexObject(
        _ manifest: PeerPackage.Manifest, body: (PeerPackage.Object, Data) throws -> Void
    ) throws {
        let lease = try files.lock()
        defer { files.unlock(lease) }
        work = 0
        let sealBytes = try files.read(["root.json"])
        let reservationBytes = try files.read(["reservation.json"])
        let seal = try PeerPackage.decode(Seal.self, sealBytes)
        guard seal.manifest == manifest else {
            throw Self.failure("Requested manifest differs from durable root.")
        }
        try validate(seal)
        func requireSnapshot() throws {
            guard try files.read(["root.json"]) == sealBytes,
                try files.read(["reservation.json"]) == reservationBytes
            else { throw Self.failure("Private root/source binding changed during enumeration.") }
        }
        func emit(_ expected: PeerPackage.Object, at address: Address) throws {
            try tick()
            try requireSnapshot()
            let (descriptor, data, value) = try page(address)
            // Expectations come only from the caller's fixed root and its hash-verified ancestors.
            // A replaced local descriptor/page pair must never authenticate itself.
            guard descriptor == expected else {
                throw Self.failure("Generated page differs from the fixed root's committed reference.")
            }
            for child in value.children {
                let next = try decode(Address.self, ["page-ids", child.id])
                guard address.level > 0, next.level == address.level - 1,
                    next.ordinal >= 0, next.ordinal < seal.levelCounts[next.level]
                else { throw Self.failure("Root-directed child address differs from its sealed level.") }
                try emit(child, at: next)
            }
            try requireSnapshot()
            try body(descriptor, data)
            try requireSnapshot()
            try files.checkLease()
        }
        try emit(manifest.root, at: .init(level: seal.levelCounts.count - 1, ordinal: 0))
    }

    /// All paths are internal; native artifact helpers supply ACL/nofollow/nlink/stamp/fsync checks.
    /// Every operation binds the held lease and directory chain back to their current names.
    private final class Files {
        let root: URL
        let limits: Limits
        let capacity: DocumentContentFiles
        private let identity: (UInt64, UInt64)
        private var held: Int32?
        private var footprint: UInt64 = 0
        init(root: URL, limits: Limits) throws {
            self.root = root
            self.limits = limits
            let fd = root.path.withCString { tractanda_open_private_directory($0) }
            guard fd >= 0 else { throw failure("Package root must be caller-private/no-follow.") }
            defer { close(fd) }
            var s = stat()
            guard fstat(fd, &s) == 0 else { throw failure("Cannot inspect package root.") }
            identity = (UInt64(truncatingIfNeeded: s.st_dev), UInt64(s.st_ino))
            capacity = DocumentContentFiles(
                root: root, ownerUID: tractanda_uid(), minimumFreeBytes: limits.minimumFreeBytes)
            try capacity.requireCapacity(0, at: root)
        }
        private func rootDescriptor() throws -> Int32 {
            let fd = root.path.withCString { tractanda_open_private_directory($0) }
            guard fd >= 0 else { throw failure("Package root custody changed.") }
            do {
                var s = stat()
                guard fstat(fd, &s) == 0, UInt64(truncatingIfNeeded: s.st_dev) == identity.0,
                    UInt64(s.st_ino) == identity.1
                else { throw failure("Package root was replaced.") }
                if let held {
                    var a = stat()
                    var b = stat()
                    guard fstat(held, &a) == 0,
                        fstatat(fd, ".package.lock", &b, AT_SYMLINK_NOFOLLOW) == 0,
                        a.st_dev == b.st_dev, a.st_ino == b.st_ino,
                        a.st_nlink == 1, b.st_nlink == 1, a.st_uid == tractanda_uid(),
                        a.st_mode & 0o777 == 0o600, a.st_mode == b.st_mode
                    else { throw failure("Package lease inode was replaced.") }
                    var pointer: UnsafeMutableRawPointer?
                    var count: UInt32 = 0
                    let result = tractanda_capture_private_artifact_at(
                        fd, ".package.lock", &pointer, &count, 1)
                    defer { if let pointer { tractanda_private_free(pointer, count) } }
                    guard result == 0, pointer != nil, count == 0 else {
                        throw failure("Package lease ACL or bytes changed.")
                    }
                }
                return fd
            } catch {
                close(fd)
                throw error
            }
        }
        func checkLease() throws {
            guard held != nil else { throw failure("Private package lease is absent.") }
            let fd = try rootDescriptor()
            close(fd)
        }
        private func parent<T>(_ path: [String], create: Bool = false, _ body: (Int32, String) throws -> T)
            throws -> T
        {
            guard !path.isEmpty, path.count <= 8,
                path.allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
                })
            else { throw failure("Unsafe internal package path.") }
            let fd = try rootDescriptor()
            var chain = [fd]
            defer { for descriptor in chain.reversed() { close(descriptor) } }
            var location = root
            for name in path.dropLast() {
                let prior = chain.last!
                var child = openat(prior, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT, create {
                    guard mkdirat(prior, name, 0o700) == 0, fsync(prior) == 0 else {
                        throw failure("Cannot durably create private package directory.")
                    }
                    child = openat(prior, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw FileMetadataError.posix(errno) }
                chain.append(child)
                location.appendPathComponent(name)
                try requireDirectory(location, held: child)
            }
            let value = try body(chain.last!, path.last!)
            location = root
            for (index, name) in path.dropLast().enumerated() {
                location.appendPathComponent(name)
                var named = stat()
                var actual = stat()
                guard fstatat(chain[index], name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                    fstat(chain[index + 1], &actual) == 0,
                    named.st_dev == actual.st_dev, named.st_ino == actual.st_ino
                else { throw failure("Private package directory was replaced.") }
                try requireDirectory(location, held: chain[index + 1])
            }
            let checked = try rootDescriptor()
            close(checked)
            return value
        }
        private func requireDirectory(_ location: URL, held: Int32) throws {
            let fd = location.path.withCString { tractanda_open_private_directory($0) }
            guard fd >= 0 else { throw failure("Package directory is not private.") }
            defer { close(fd) }
            var a = stat()
            var b = stat()
            guard fstat(fd, &a) == 0, fstat(held, &b) == 0,
                a.st_dev == b.st_dev, a.st_ino == b.st_ino
            else { throw failure("Package directory custody differs.") }
        }
        func optional(_ path: [String]) throws -> Data? {
            try Task.checkCancellation()
            do {
                return try parent(path) { fd, name in
                    var pointer: UnsafeMutableRawPointer?
                    var count: UInt32 = 0
                    let result = name.withCString {
                        tractanda_capture_private_artifact_at(
                            fd, $0, &pointer, &count, UInt32(PeerPackage.maximumPageBytes))
                    }
                    if result == 1 { return nil }
                    guard result == 0, let pointer else { throw failure("Package artifact custody changed.") }
                    defer { tractanda_private_free(pointer, count) }
                    var s = stat()
                    guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_mode & 0o777 == 0o400 else {
                        throw failure("Private package artifact is not sealed0400.")
                    }
                    return Data(bytes: pointer, count: Int(count))
                }
            } catch FileMetadataError.posix(let code) where code == ENOENT { return nil }
        }
        func read(_ path: [String]) throws -> Data {
            guard let data = try optional(path) else { throw failure("Private package artifact is missing.") }
            return data
        }
        private func charge(_ cost: UInt64) throws {
            guard cost <= limits.maximumStoredBytes - min(footprint, limits.maximumStoredBytes) else {
                throw TractandaError("resourceLimit", "Private package disk allowance exhausted.")
            }
            try capacity.requireCapacity(cost, at: root)
            footprint += cost
        }
        func put(_ data: Data, at path: [String]) throws {
            try Task.checkCancellation()
            guard data.count <= PeerPackage.maximumPageBytes else {
                throw TractandaError("resourceLimit", "Private package artifact exceeds its byte window.")
            }
            if let old = try optional(path) {
                guard old == data else { throw failure("Immutable private package retry bytes differ.") }
                try parent(path) { fd, _ in
                    guard fsync(fd) == 0 else { throw failure("Cannot synchronize package retry.") }
                }
                return
            }
            try charge(UInt64(data.count) + UInt64(4096 * (path.count + 2)))
            try parent(path, create: true) { fd, name in
                let temporary = ".peer-artifact-" + UUID().uuidString + ".tmp"
                let result = data.withUnsafeBytes { raw in
                    temporary.withCString { source in
                        name.withCString { target in
                            tractanda_write_private_artifact_at(
                                fd, source, target, raw.baseAddress, UInt32(raw.count))
                        }
                    }
                }
                guard result == 0 else { throw failure("Cannot durably publish private package artifact.") }
            }
            guard try optional(path) == data else { throw failure("Private package publication differs.") }
        }
        func lock() throws -> Int32 {
            guard held == nil else { throw failure("Private package instance is busy.") }
            let fd = try rootDescriptor()
            defer { close(fd) }
            var old = stat()
            if fstatat(fd, ".package.lock", &old, AT_SYMLINK_NOFOLLOW) < 0 {
                guard errno == ENOENT else { throw failure("Cannot inspect private package lease.") }
                try recount()
                try charge(4096)
            }
            let lock = openat(fd, ".package.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw failure("Cannot open private package lease.") }
            var s = stat()
            guard fstat(lock, &s) == 0, s.st_uid == tractanda_uid(), s.st_nlink == 1,
                s.st_mode & 0o777 == 0o600, flock(lock, LOCK_EX | LOCK_NB) == 0
            else {
                close(lock)
                throw failure("Private package lease is busy or unsafe.")
            }
            held = lock
            do {
                var pointer: UnsafeMutableRawPointer?
                var count: UInt32 = 0
                let result = tractanda_capture_private_artifact_at(fd, ".package.lock", &pointer, &count, 1)
                defer { if let pointer { tractanda_private_free(pointer, count) } }
                guard result == 0, pointer != nil, count == 0, fsync(fd) == 0 else {
                    throw failure("Private package lease ACL or bytes differ.")
                }
                try checkLease()
                try recount()
                return lock
            } catch {
                unlock(lock)
                throw error
            }
        }
        func unlock(_ descriptor: Int32) {
            held = nil
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        private func recount() throws {
            let fd = try rootDescriptor()
            defer { close(fd) }
            var total: UInt64 = 4096
            var entries = 0
            func visit(_ directory: Int32, location: URL, depth: Int) throws {
                guard depth <= 8 else { throw failure("Private package inventory depth exceeded.") }
                try POSIXDirectory.withEntries(descriptor: directory) { name in
                    try Task.checkCancellation()
                    guard entries < limits.maximumWork else {
                        throw TractandaError("resourceLimit", "Private package inventory work exceeded.")
                    }
                    entries += 1
                    var s = stat()
                    guard fstatat(directory, name, &s, AT_SYMLINK_NOFOLLOW) == 0,
                        s.st_uid == tractanda_uid(), s.st_mode & 0o077 == 0, s.st_size >= 0
                    else { throw failure("Unsafe private package inventory entry.") }
                    let cost = UInt64(s.st_size).addingReportingOverflow(4096)
                    guard !cost.overflow,
                        cost.partialValue <= limits.maximumStoredBytes - min(total, limits.maximumStoredBytes)
                    else {
                        throw TractandaError(
                            "resourceLimit", "Existing private package exceeds disk allowance.")
                    }
                    total += cost.partialValue
                    if s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                        let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard child >= 0 else { throw failure("Unsafe package inventory directory.") }
                        defer { close(child) }
                        let url = location.appendingPathComponent(name)
                        try requireDirectory(url, held: child)
                        try visit(child, location: url, depth: depth + 1)
                        try requireDirectory(url, held: child)
                    } else {
                        guard s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), s.st_nlink == 1 else {
                            throw failure("Linked/special private package inventory entry.")
                        }
                    }
                    return true
                }
            }
            try visit(fd, location: root, depth: 0)
            let checked = try rootDescriptor()
            close(checked)
            footprint = total
        }
    }
}
