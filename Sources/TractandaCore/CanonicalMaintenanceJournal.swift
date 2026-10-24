import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Local maintenance safety only. No authority approval, ordinary Store-opening bypass, or repair API.
/// The caller owns the lifetime writer flock. The borrowed descriptor is checked, never unlocked here.
final class CanonicalMaintenanceJournal {
    static let pendingName = ".tractanda-maintenance-pending.json"
    struct Limits {
        var maximumStoredBytes: UInt64 = 128 * 1024 * 1024
        var minimumFreeBytes: UInt64 = 10 * 1024 * 1024 * 1024
        var maximumFileBytes = 1024 * 1024
        var maximumEntries = 8192
    }
    enum Role: String, Codable { case authorityOriginal, packageMetadata, locator }
    struct Edit: Codable, Equatable {
        let path: [String]
        let role: Role
        let beforeSHA256: String?
        let after: Data?
    }
    struct Plan: Codable, Equatable {
        let version: Int
        let operationID: String
        let storeID: String
        let replicaID: String
        let edits: [Edit]
    }
    private struct Stamp: Codable, Equatable {
        let inode: UInt64
        let uid: UInt32
        let gid: UInt32
        let mode: UInt32
        let size: Int64
        let sha256: String
    }
    private struct Intent: Codable, Equatable {
        let ordinal: Int
        let before: Stamp?
        let after: Stamp?
    }
    private struct Marker: Codable, Equatable {
        let version: Int
        let operationID: String
        let planSHA256: String
        let storeID: String
        let replicaID: String
    }
    private struct StoreIdentity: Codable {
        let formatVersion: Int
        let storeID: String
    }
    enum Boundary {
        case intentDurable, originalArchived, replacementPublished, completionDurable
        case rollbackIntentDurable, rollbackReplacementArchived, rollbackOriginalRestored,
            rollbackCompletionDurable
    }
    var boundaryForTesting: ((Int, Boundary) throws -> Void)?
    private let root: URL
    private let journal: URL
    private let rootFD: Int32
    private let journalFD: Int32
    private let writer: Int32
    private let journalLock: Int32
    private let rootIdentity: (UInt64, UInt64)
    private let journalIdentity: (UInt64, UInt64)
    private let limits: Limits
    private let plan: Plan
    private let marker: Data
    private let progress: (() throws -> Void)?
    private var closed = false
    private var footprint: UInt64 = 0
    private var requiresFreshResume = false
    private var inMutation = false
    private var activeParents = [Int32: URL]()

    /// This check runs before ordinary canonical recovery. It does not follow a journal supplied
    /// by the marker or infer permission to resume from a private SQLite flag.
    static func requireOrdinaryOpeningAllowed(root: URL) throws {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("Cannot inspect maintenance startup barrier.") }
        defer { close(fd) }
        var value = stat()
        if fstatat(fd, pendingName, &value, AT_SYMLINK_NOFOLLOW) == 0 {
            throw TractandaError(
                "maintenanceRequired",
                "Canonical maintenance is pending; ordinary recovery and writes are blocked.")
        }
        guard errno == ENOENT else { throw error("Cannot inspect maintenance startup barrier.") }
    }

    init(
        root: URL, journal: URL, writerDescriptor: Int32, plan: Plan,
        limits: Limits = .init(), progress: (() throws -> Void)? = nil
    ) throws {
        self.root = root
        self.journal = journal
        self.writer = writerDescriptor
        self.plan = plan
        self.limits = limits
        self.progress = progress
        try Self.validate(plan, limits: limits)
        let rPath = root.standardizedFileURL.path
        let jPath = journal.standardizedFileURL.path
        guard !jPath.hasPrefix(rPath + "/"), !rPath.hasPrefix(jPath + "/") else {
            throw Self.error("Audit journal must be outside the active canonical catalogue.")
        }
        let rootFD = tractanda_open_private_directory(root.path)
        guard rootFD >= 0 else { throw Self.error("Unsafe maintenance root.") }
        let journalFD = tractanda_open_private_directory(journal.path)
        guard journalFD >= 0 else {
            close(rootFD)
            throw Self.error("Unsafe maintenance journal.")
        }
        var r = stat()
        var j = stat()
        guard fstat(rootFD, &r) == 0, fstat(journalFD, &j) == 0,
            r.st_dev == j.st_dev, !(r.st_dev == j.st_dev && r.st_ino == j.st_ino)
        else {
            close(rootFD)
            close(journalFD)
            throw Self.error("Journal must be a separate private directory on the same filesystem.")
        }
        let lock = openat(journalFD, ".maintenance.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            close(rootFD)
            close(journalFD)
            throw Self.error("Cannot open maintenance journal lease.")
        }
        var l = stat()
        guard fstat(lock, &l) == 0, l.st_uid == tractanda_uid(), l.st_nlink == 1,
            l.st_mode & 0o777 == 0o600, flock(lock, LOCK_EX | LOCK_NB) == 0
        else {
            close(lock)
            close(rootFD)
            close(journalFD)
            throw Self.error("Maintenance journal is busy or unsafe.")
        }
        self.rootFD = rootFD
        self.journalFD = journalFD
        self.journalLock = lock
        rootIdentity = (UInt64(truncatingIfNeeded: r.st_dev), UInt64(r.st_ino))
        journalIdentity = (UInt64(truncatingIfNeeded: j.st_dev), UInt64(j.st_ino))
        let encoded = try JSON.encode(plan)
        marker = try JSON.encode(
            Marker(
                version: 1, operationID: plan.operationID,
                planSHA256: AuthorityRecordCodec.sha256(encoded), storeID: plan.storeID,
                replicaID: plan.replicaID))
        do {
            try check()
            try validateIdentity()
            try recount()
            // Freeze the exact reviewed inputs before a pending marker or target mutation exists.
            let chunks = stride(from: 0, to: encoded.count, by: limits.maximumFileBytes)
            var chunkCount = 0
            for offset in chunks {
                try put(
                    Data(encoded[offset..<min(encoded.count, offset + limits.maximumFileBytes)]),
                    at: "plan-\(chunkCount)")
                chunkCount += 1
            }
            struct PlanSeal: Codable {
                let sha256: String
                let bytes: Int
                let chunks: Int
            }
            try put(
                try JSON.encode(
                    PlanSeal(
                        sha256: AuthorityRecordCodec.sha256(encoded), bytes: encoded.count, chunks: chunkCount
                    )), at: "plan.json")
            if let old = try read(rootFD, Self.pendingName) {
                guard old == marker else { throw Self.error("Another maintenance marker is present.") }
            } else {
                // Verify every initial target before advertising the operation as pending. A resume
                // instead uses its durable intents, because some old inodes may already be archived.
                for (n, edit) in plan.edits.enumerated() where try read(journalFD, intentName(n)) == nil {
                    let old = try target(edit.path)
                    guard old?.sha256 == edit.beforeSHA256 else {
                        throw Self.error("Planned before-state differs.")
                    }
                }
                try check(additional: UInt64(marker.count) + 4096)
                try writeExact(marker, directory: rootFD, name: Self.pendingName)
            }
            try check()
        } catch {
            _ = flock(lock, LOCK_UN)
            close(lock)
            close(rootFD)
            close(journalFD)
            closed = true
            throw error
        }
    }
    deinit {
        if !closed {
            _ = flock(journalLock, LOCK_UN)
            close(journalLock)
            close(rootFD)
            close(journalFD)
        }
    }
    private static func error(_ message: String) -> TractandaError {
        .init("maintenanceConflict", message)
    }
    private static func validate(_ plan: Plan, limits: Limits) throws {
        guard plan.version == 1, limits.maximumStoredBytes > 0,
            limits.maximumStoredBytes <= UInt64(UInt32.max), limits.maximumFileBytes > 0,
            limits.maximumFileBytes <= 1024 * 1024,
            UInt64(limits.maximumFileBytes) <= limits.maximumStoredBytes,
            plan.edits.count <= limits.maximumEntries, !plan.edits.isEmpty
        else {
            throw error("Invalid maintenance plan limits.")
        }
        _ = try AuthorityRecord.persistentID(.text(plan.operationID))
        try Identifier.validate(plan.storeID)
        _ = try AuthorityRecord.persistentID(.text(plan.replicaID))
        var paths = Set<[String]>()
        for edit in plan.edits {
            try safePath(edit.path)
            guard paths.insert(edit.path).inserted,
                edit.beforeSHA256 != nil || edit.after != nil
            else { throw error("Duplicate or empty maintenance edit.") }
            if let digest = edit.beforeSHA256 { _ = try AuthorityRecord.digest(.text(digest)) }
            if let after = edit.after, after.count > limits.maximumFileBytes {
                throw error("Metadata file exceeds private plan limit.")
            }
            // These are exact paths, never a blanket authority-prefix write permission. Mixed
            // intake originals cannot be mistaken for metadata by choosing a role label.
            switch edit.role {
            case .authorityOriginal:
                guard edit.path.count == 8, edit.path.prefix(2) == ["authority", "records"],
                    edit.path.last!.hasSuffix(".authority")
                else { throw error("Invalid authority-original path.") }
                if let data = edit.after {
                    let original = try CanonicalAuthorityOriginal(data)
                    guard original.storeID == plan.storeID,
                        edit.path.last == original.recordID + ".authority"
                    else { throw error("Authority identity differs from planned path.") }
                }
            case .locator:
                guard edit.path.count == 4, edit.path.prefix(2) == ["authority", "locators"] else {
                    throw error("Invalid authority locator path.")
                }
                for id in edit.path.suffix(2) { _ = try AuthorityRecord.persistentID(.text(id)) }
            case .packageMetadata:
                guard edit.path.count >= 4, edit.path.prefix(2) == ["authority", "intake"] else {
                    throw error("Invalid package metadata path.")
                }
                _ = try AuthorityRecord.persistentID(.text(edit.path[2]))
                if edit.path.count == 4 {
                    guard
                        ["begin.json", "prepared.json", "sealed.json", "applied.json"].contains(edit.path[3])
                    else { throw error("Unplanned package artifact class.") }
                } else {
                    guard edit.path.count == 6, edit.path[3] == "objects", edit.path[5] == "0" else {
                        throw error("Payload, originals and private work are not metadata permissions.")
                    }
                    _ = try AuthorityRecord.persistentID(.text(edit.path[4]))
                    if let data = edit.after {
                        _ = try PeerPackage.decode(PeerPackage.Page.self, data).validate()
                    }
                }
            }
        }
    }
    private static func safePath(_ path: [String]) throws {
        guard !path.isEmpty, path.count <= 16,
            path.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
                    && $0.utf8.count <= 255
            })
        else { throw error("Unsafe maintenance path.") }
    }
    private func check(additional: UInt64 = 0) throws {
        guard !closed, !requiresFreshResume else {
            throw Self.error("Maintenance journal needs a fresh validated resume lease.")
        }
        try Task.checkCancellation()
        try progress?()
        try Task.checkCancellation()
        guard !closed, !requiresFreshResume else {
            throw Self.error("Maintenance journal needs a fresh validated resume lease.")
        }
        func bound(_ url: URL, _ held: Int32, _ identity: (UInt64, UInt64)) throws {
            let named = tractanda_open_private_directory(url.path)
            guard named >= 0 else { throw Self.error("Maintenance root custody changed.") }
            defer { close(named) }
            var h = stat()
            var n = stat()
            guard fstat(held, &h) == 0, fstat(named, &n) == 0, h.st_dev == n.st_dev, h.st_ino == n.st_ino,
                UInt64(truncatingIfNeeded: h.st_dev) == identity.0, UInt64(h.st_ino) == identity.1
            else { throw Self.error("Maintenance root was replaced.") }
        }
        try bound(root, rootFD, rootIdentity)
        try bound(journal, journalFD, journalIdentity)
        var held = stat()
        var named = stat()
        guard fstat(writer, &held) == 0, fstatat(rootFD, ".writer.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
            held.st_dev == named.st_dev, held.st_ino == named.st_ino, held.st_nlink == 1,
            held.st_uid == tractanda_uid(), held.st_mode & 0o777 == 0o600,
            held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { throw Self.error("Borrowed writer lease identity changed.") }
        guard fstat(journalLock, &held) == 0,
            fstatat(journalFD, ".maintenance.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
            held.st_dev == named.st_dev, held.st_ino == named.st_ino, held.st_nlink == 1
        else { throw Self.error("Journal lease was replaced.") }
        // Installed14 does not understand the safety marker. Never raise the floor here:
        // the coordinated operator must fence old writers before this executor can proceed.
        try CanonicalReaderRequirement.beforeAtomicAuthorityPublication(root: root, ownerUID: tractanda_uid())
        var capacity = statvfs()
        guard fstatvfs(journalFD, &capacity) == 0, capacity.f_frsize > 0 else {
            throw Self.error("Cannot determine maintenance filesystem capacity.")
        }
        let free = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
        let required = limits.minimumFreeBytes.addingReportingOverflow(additional)
        guard !free.overflow, !required.overflow, free.partialValue >= required.partialValue else {
            throw TractandaError("resourceLimit", "Maintenance reserve is unavailable.")
        }
    }
    private func validateIdentity() throws {
        guard let storeBytes = try read(rootFD, ".tractanda-store-identity.json", mode: 0o600),
            let replicaBytes = try read(rootFD, ReplicaIdentity.name)
        else { throw Self.error("Canonical identity proof is missing.") }
        let store = try PeerPackage.decode(StoreIdentity.self, storeBytes, maximum: 4096)
        let replica = try PeerPackage.decode(ReplicaIdentity.Record.self, replicaBytes, maximum: 4096)
        guard store.formatVersion == 1, store.storeID == plan.storeID,
            replica.formatVersion == 1, replica.storeID == plan.storeID,
            replica.replicaID == plan.replicaID, replica.replicaID != plan.storeID
        else { throw Self.error("Maintenance plan belongs to another canonical identity.") }
    }
    private func withParent<T>(_ path: [String], _ body: (Int32, String) throws -> T) throws -> T {
        try Self.safePath(path)
        var fd = dup(rootFD)
        guard fd >= 0 else { throw Self.error("Cannot borrow canonical root.") }
        defer { close(fd) }
        var currentPath = root
        for component in path.dropLast() {
            let child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else {
                throw Self.error("Planned parent directory is missing or unsafe; creation is not authorized.")
            }
            var s = stat()
            guard fstat(child, &s) == 0, s.st_uid == tractanda_uid(), s.st_mode & 0o077 == 0 else {
                close(child)
                throw Self.error("Planned parent custody differs.")
            }
            currentPath.appendPathComponent(component)
            let named = tractanda_open_private_directory(currentPath.path)
            guard named >= 0 else {
                close(child)
                throw Self.error("Planned parent ACL/custody is unsafe.")
            }
            var checked = stat()
            let matches =
                fstat(named, &checked) == 0 && s.st_dev == checked.st_dev && s.st_ino == checked.st_ino
            close(named)
            guard matches else {
                close(child)
                throw Self.error("Planned parent path was replaced.")
            }
            close(fd)
            fd = child
        }
        activeParents[fd] = currentPath
        defer { activeParents.removeValue(forKey: fd) }
        let result = try body(fd, path.last!)
        let named = tractanda_open_private_directory(currentPath.path)
        guard named >= 0 else { throw Self.error("Planned parent changed during mutation.") }
        defer { close(named) }
        var held = stat()
        var checked = stat()
        guard fstat(fd, &held) == 0, fstat(named, &checked) == 0,
            held.st_dev == checked.st_dev, held.st_ino == checked.st_ino
        else { throw Self.error("Planned parent path changed during mutation.") }
        return result
    }
    private func read(_ directory: Int32, _ name: String, maximum: Int? = nil, mode: mode_t = 0o400) throws
        -> Data?
    {
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        let result = tractanda_capture_private_artifact_at(
            directory, name, &pointer, &count, UInt32(min(1024 * 1024, maximum ?? limits.maximumFileBytes)))
        if result == 1 { return nil }
        guard result == 0, let pointer else {
            throw Self.error("Maintenance artifact is unsafe or exceeds its bound.")
        }
        defer { tractanda_private_free(pointer, count) }
        var custody = stat()
        guard fstatat(directory, name, &custody, AT_SYMLINK_NOFOLLOW) == 0,
            custody.st_mode & 0o777 == mode
        else { throw Self.error("Maintenance artifact mode differs from its exact role.") }
        return Data(bytes: pointer, count: Int(count))
    }
    private func stamp(_ directory: Int32, _ name: String) throws -> Stamp? {
        var before = stat()
        let found = fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW)
        if found != 0, errno == ENOENT { return nil }
        guard found == 0 else { throw Self.error("Cannot inspect maintenance artifact.") }
        guard let bytes = try read(directory, name) else {
            throw Self.error("Maintenance artifact vanished.")
        }
        var value = stat()
        guard fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
            value.st_nlink == 1, value.st_uid == tractanda_uid(),
            value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_size == bytes.count,
            value.st_dev == before.st_dev, value.st_ino == before.st_ino,
            value.st_uid == before.st_uid, value.st_gid == before.st_gid,
            value.st_mode == before.st_mode, value.st_size == before.st_size
        else { throw Self.error("Maintenance artifact custody differs.") }
        return Stamp(
            inode: UInt64(value.st_ino), uid: value.st_uid,
            gid: value.st_gid, mode: UInt32(value.st_mode), size: Int64(value.st_size),
            sha256: AuthorityRecordCodec.sha256(bytes))
    }
    private func target(_ path: [String]) throws -> Stamp? { try withParent(path) { try stamp($0, $1) } }
    private func intentName(_ n: Int) -> String { "intent-\(n).json" }
    private func writeExact(_ data: Data, directory: Int32, name: String) throws {
        if let old = try read(directory, name, maximum: Int(limits.maximumStoredBytes)) {
            guard old == data else { throw Self.error("Immutable maintenance retry differs.") }
            guard fsync(directory) == 0 else { throw Self.error("Cannot sync maintenance retry.") }
            return
        }
        let temporary = ".maintenance-write-" + UUID().uuidString
        let result = data.withUnsafeBytes {
            tractanda_write_private_artifact_at(directory, temporary, name, $0.baseAddress, UInt32($0.count))
        }
        guard result == 0 else { throw Self.error("Cannot durably publish maintenance artifact.") }
    }
    private func recount() throws {
        var total: UInt64 = 0
        let duplicate = openat(journalFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw Self.error("Cannot account maintenance journal.")
        }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var value = stat()
            guard fstatat(journalFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
                value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_nlink == 1,
                value.st_uid == tractanda_uid(), value.st_size >= 0
            else { throw Self.error("Unknown journal custody.") }
            let next = total.addingReportingOverflow(UInt64(value.st_size) + 4096)
            guard !next.overflow else { throw Self.error("Journal accounting overflow.") }
            total = next.partialValue
        }
        guard total <= limits.maximumStoredBytes else {
            throw TractandaError("resourceLimit", "Maintenance journal storage allowance exhausted.")
        }
        footprint = total
    }
    private func put(_ data: Data, at name: String) throws {
        try check(additional: UInt64(data.count) + 4096)
        if let old = try read(journalFD, name, maximum: Int(limits.maximumStoredBytes)) {
            guard old == data else { throw Self.error("Immutable journal artifact differs.") }
            guard fsync(journalFD) == 0 else { throw Self.error("Cannot sync journal retry.") }
            return
        }
        let added = UInt64(data.count) + 4096
        guard footprint <= limits.maximumStoredBytes, added <= limits.maximumStoredBytes - footprint else {
            throw TractandaError(
                "resourceLimit", "Maintenance journal exceeds its private storage allowance.")
        }
        try writeExact(data, directory: journalFD, name: name)
        footprint += added
    }
    private func move(
        _ source: Int32, _ name: String, _ destination: Int32, _ target: String,
        expected: Stamp
    ) throws {
        // All caller/progress callbacks run BEFORE the final exact source and parent checks.
        try check()
        for directory in [source, destination] where directory != journalFD {
            guard let location = activeParents[directory] else { throw Self.error("Unowned rename parent.") }
            let fd = tractanda_open_private_directory(location.path)
            guard fd >= 0 else { throw Self.error("Rename parent custody changed.") }
            var held = stat()
            var named = stat()
            let same =
                fstat(directory, &held) == 0 && fstat(fd, &named) == 0 && held.st_dev == named.st_dev
                && held.st_ino == named.st_ino
            close(fd)
            guard same else { throw Self.error("Rename parent identity changed.") }
        }
        guard try stamp(source, name) == expected else {
            throw Self.error("Exact rename source changed; entry preserved.")
        }
        let cost = UInt64(expected.size) + 4096
        if destination == journalFD {
            guard footprint <= limits.maximumStoredBytes, cost <= limits.maximumStoredBytes - footprint else {
                throw TractandaError("resourceLimit", "Original archive exceeds journal allowance.")
            }
        }
        // No arbitrary callback occurs between exact verification and the no-replace rename.
        guard tractanda_publish_directory_at(source, name, destination, target) == 0,
            fsync(source) == 0, fsync(destination) == 0
        else { throw Self.error("Maintenance move is incomplete; preserve the pending marker and journal.") }
        guard try stamp(destination, target) == expected else {
            throw Self.error("Renamed destination differs from exact intent.")
        }
        if destination == journalFD { footprint += cost }
        if source == journalFD { footprint -= min(footprint, cost) }
    }
    private func mutation<T>(_ body: () throws -> T) throws -> T {
        guard !inMutation else { throw Self.error("Maintenance mutation cannot reenter.") }
        inMutation = true
        defer { inMutation = false }
        try check()
        do { return try body() } catch {
            requiresFreshResume = true
            throw error
        }
    }
    /// Exact-path dispatcher: caller data cannot authorize an extra path or different bytes.
    func apply(path: [String], replacement: Data?) throws {
        guard !inMutation else { throw Self.error("Maintenance mutation cannot reenter.") }
        guard let ordinal = plan.edits.firstIndex(where: { $0.path == path }),
            plan.edits[ordinal].after == replacement
        else { throw Self.error("Unplanned canonical mutation denied before write.") }
        try mutation { try apply(ordinal: ordinal) }
    }
    func applyAll() throws {
        try mutation { for ordinal in plan.edits.indices { try apply(ordinal: ordinal) } }
    }
    private func apply(ordinal: Int) throws {
        try check()
        guard try read(journalFD, "rollback-started.json") == nil else {
            throw Self.error("Rollback has started; forward mutation is blocked.")
        }
        let edit = plan.edits[ordinal]
        let oldName = "original-\(ordinal)"
        let newName = "replacement-\(ordinal)"
        let intent: Intent
        if let bytes = try read(journalFD, intentName(ordinal)) {
            intent = try PeerPackage.decode(Intent.self, bytes)
            guard intent.ordinal == ordinal, intent.before?.sha256 == edit.beforeSHA256,
                intent.after?.sha256 == edit.after.map(AuthorityRecordCodec.sha256)
            else { throw Self.error("Intent differs from its frozen plan.") }
        } else {
            let before = try target(edit.path)
            guard before?.sha256 == edit.beforeSHA256 else {
                throw Self.error("Before-state changed; mutation refused.")
            }
            let after: Stamp?
            if let bytes = edit.after {
                try put(bytes, at: newName)
                after = try stamp(journalFD, newName)
            } else {
                guard try stamp(journalFD, newName) == nil else {
                    throw Self.error("Deletion has an unexpected replacement; entry preserved.")
                }
                after = nil
            }
            intent = Intent(ordinal: ordinal, before: before, after: after)
            guard intent.before?.sha256 == edit.beforeSHA256,
                intent.after?.sha256 == edit.after.map(AuthorityRecordCodec.sha256),
                intent.after?.size == edit.after.map({ Int64($0.count) })
            else { throw Self.error("New intent differs from its exact plan.") }
            try put(try JSON.encode(intent), at: intentName(ordinal))
            try boundaryForTesting?(ordinal, .intentDurable)
        }
        try withParent(edit.path) { parent, name in
            var current = try stamp(parent, name)
            let archived = try stamp(journalFD, oldName)
            let staged = try stamp(journalFD, newName)
            if archived == nil, current == intent.before {
                guard staged == intent.after else {
                    throw Self.error("Replacement differs before original move.")
                }
                if let expected = intent.before {
                    try move(parent, name, journalFD, oldName, expected: expected)
                    current = nil
                    try boundaryForTesting?(ordinal, .originalArchived)
                }
            } else {
                guard archived == intent.before,
                    (current == nil && staged == intent.after)
                        || (current == intent.after && staged == nil)
                else { throw Self.error("Unknown apply state; no entry moved.") }
            }
            if let expected = intent.after {
                if current == nil, staged == expected {
                    try move(journalFD, newName, parent, name, expected: expected)
                    current = try stamp(parent, name)
                    try boundaryForTesting?(ordinal, .replacementPublished)
                }
                guard current == expected, try stamp(journalFD, newName) == nil else {
                    throw Self.error("Unexpected post-publication state.")
                }
            } else {
                guard current == nil, staged == nil else { throw Self.error("Unexpected deletion state.") }
            }
        }
        try put(try JSON.encode(intent), at: "applied-\(ordinal).json")
        try boundaryForTesting?(ordinal, .completionDurable)
    }
    /// Internal filesystem capability check, not an authority/admission decision.
    func requireContextLease() throws {
        try check()
        try validateIdentity()
        guard try read(rootFD, Self.pendingName) == marker else {
            throw Self.error("Maintenance marker no longer binds this plan.")
        }
    }
    /// Cold validation cannot publish the static plan again or open on a partially applied plan.
    func requireFullyAppliedPlan() throws {
        try requireContextLease()
        guard try read(journalFD, "rollback-started.json") == nil else {
            throw Self.error("Rolled-back/in-progress rollback is not a cold-validation opening.")
        }
        for (ordinal, edit) in plan.edits.enumerated() {
            guard let raw = try read(journalFD, intentName(ordinal)),
                try read(journalFD, "applied-\(ordinal).json") == raw
            else { throw Self.error("Static metadata plan is not completely APPLIED.") }
            let intent = try PeerPackage.decode(Intent.self, raw)
            guard intent.ordinal == ordinal, intent.before?.sha256 == edit.beforeSHA256,
                intent.after?.sha256 == edit.after.map(AuthorityRecordCodec.sha256),
                try target(edit.path) == intent.after,
                try stamp(journalFD, "original-\(ordinal)") == intent.before,
                try stamp(journalFD, "replacement-\(ordinal)") == nil
            else { throw Self.error("APPLIED metadata plan custody/bytes changed before cold validation.") }
        }
    }
    func privateStoredBytes() throws -> UInt64 {
        try requireContextLease()
        return footprint
    }
    func recordDerivedAudit(_ audit: CanonicalMaintenanceContext.DerivedAudit) throws {
        guard audit.operationID == plan.operationID else {
            throw Self.error("Derived audit operation differs.")
        }
        _ = try AuthorityRecord.persistentID(.text(audit.eventID))
        try mutation {
            try requireContextLease()
            try put(
                try JSON.encode(audit), at: "derived-" + audit.eventID + "-" + audit.phase.rawValue + ".json")
        }
    }
    /// Reverses only this exact plan. New metadata remains archived; no unknown path is deleted.
    func rollback() throws { try mutation { try rollbackBody() } }
    private func rollbackBody() throws {
        try check()
        try put(marker, at: "rollback-started.json")
        try boundaryForTesting?(-1, .rollbackIntentDurable)
        for ordinal in plan.edits.indices.reversed() {
            guard let bytes = try read(journalFD, intentName(ordinal)) else { continue }
            let intent = try PeerPackage.decode(Intent.self, bytes)
            let edit = plan.edits[ordinal]
            guard intent.ordinal == ordinal, intent.before?.sha256 == edit.beforeSHA256,
                intent.after?.sha256 == edit.after.map(AuthorityRecordCodec.sha256)
            else { throw Self.error("Rollback intent differs from its exact plan.") }
            try withParent(edit.path) { parent, name in
                let current = try stamp(parent, name)
                let original = try stamp(journalFD, "original-\(ordinal)")
                let replacement = try stamp(journalFD, "replacement-\(ordinal)")
                if current == intent.before, original == nil {
                    // Includes an already restored target and a crash before its old inode moved.
                } else {
                    if let after = intent.after, current == after {
                        try move(parent, name, journalFD, "rolled-back-new-\(ordinal)", expected: after)
                        try boundaryForTesting?(ordinal, .rollbackReplacementArchived)
                    } else {
                        guard current == nil else { throw Self.error("Unknown target blocks rollback.") }
                        if let after = intent.after {
                            let archivedNew = try stamp(journalFD, "rolled-back-new-\(ordinal)")
                            guard replacement == after || archivedNew == after else {
                                throw Self.error("Unknown replacement blocks rollback.")
                            }
                        }
                    }
                    if let before = intent.before {
                        guard original == before else {
                            throw Self.error("Original custody differs; rollback stopped.")
                        }
                        try move(journalFD, "original-\(ordinal)", parent, name, expected: before)
                        try boundaryForTesting?(ordinal, .rollbackOriginalRestored)
                    } else {
                        guard original == nil else { throw Self.error("Unexpected original archive.") }
                    }
                }
                guard try stamp(parent, name) == intent.before else {
                    throw Self.error("Rollback target differs.")
                }
            }
            try put(bytes, at: "rolled-back-\(ordinal).json")
            try boundaryForTesting?(ordinal, .rollbackCompletionDurable)
        }
        try put(marker, at: "rollback-complete.json")
        // Marker deliberately retained. A journal rollback is not a healthy cold-rebuild proof.
    }
}
