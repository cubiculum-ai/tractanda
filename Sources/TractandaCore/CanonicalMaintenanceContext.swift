import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Explicit lifetime-writer-owned filesystem capability. It never grants item authority and is
/// not constructible from peer/client payloads. Missing propagation remains deny-by-marker.
final class CanonicalMaintenanceContext {
    struct Opening {
        let journalRoot: URL
        let plan: CanonicalMaintenanceJournal.Plan
        let expectedPendingSHA256: String
        var maximumPrivateWorkBytes: UInt64 = 128 * 1024 * 1024
        var minimumFreeBytes: UInt64 = 10 * 1024 * 1024 * 1024
        /// Optional downward-only suballowance for the private historical archive tree.
        var maximumHistoricalScratchBytes: UInt64? = nil
    }
    enum DerivedKind: String, Codable {
        case checkpointDirty, checkpointClear, indexOpening, indexRebuild, placement, historicalAtomicScratch
    }
    enum DerivedPhase: String, Codable { case intent, completed, failed }
    enum ScratchAllocationState: String, Codable { case reserved, refused }
    private struct ScratchAllocation {
        let requested: UInt64
        let reserved: UInt64
        let state: ScratchAllocationState
    }
    struct DerivedSnapshot: Codable {
        let path: String
        let exists: Bool
        let mode: UInt32?
        let uid: UInt32?
        let gid: UInt32?
        let bytes: UInt64?
        let sha256: String?
    }
    struct DerivedAudit: Codable {
        let operationID: String
        let eventID: String
        let kind: DerivedKind
        let phase: DerivedPhase
        let snapshot: DerivedSnapshot
        let canonicalRoot: AuthorityBinding?
        let acceptedReceiptSHA256: String?
        let mutation: String?
        let requestedScratchBytes: UInt64?
        let reservedScratchBytes: UInt64?
        let scratchAllocationState: ScratchAllocationState?
        init(
            operationID: String, eventID: String, kind: DerivedKind, phase: DerivedPhase,
            snapshot: DerivedSnapshot, canonicalRoot: AuthorityBinding? = nil,
            acceptedReceiptSHA256: String? = nil, mutation: String? = nil,
            requestedScratchBytes: UInt64? = nil, reservedScratchBytes: UInt64? = nil,
            scratchAllocationState: ScratchAllocationState? = nil
        ) {
            self.operationID = operationID
            self.eventID = eventID
            self.kind = kind
            self.phase = phase
            self.snapshot = snapshot
            self.canonicalRoot = canonicalRoot
            self.acceptedReceiptSHA256 = acceptedReceiptSHA256
            self.mutation = mutation
            self.requestedScratchBytes = requestedScratchBytes
            self.reservedScratchBytes = reservedScratchBytes
            self.scratchAllocationState = scratchAllocationState
        }
    }
    private let root: URL
    private let indexDirectory: URL
    private let opening: Opening
    private var journal: CanonicalMaintenanceJournal?
    private var active = true
    private var derivedEvents = [String: DerivedKind]()
    private var historicalStoredBytes: UInt64?
    private var scratchEvents = [
        String: (HistoricalScratch, [String], String, DerivedSnapshot, ScratchAllocation)
    ]()
    init(root: URL, indexDirectory: URL, writer: Int32, opening: Opening) throws {
        self.root = try Self.physical(root)
        if FileManager.default.fileExists(atPath: indexDirectory.path) {
            self.indexDirectory = try Self.physical(indexDirectory)
        } else {
            self.indexDirectory = try Self.physical(indexDirectory.deletingLastPathComponent())
                .appendingPathComponent(indexDirectory.lastPathComponent)
        }
        self.opening = opening
        _ = try AuthorityRecord.digest(.text(opening.expectedPendingSHA256))
        guard opening.maximumPrivateWorkBytes > 0, opening.maximumPrivateWorkBytes <= 128 * 1024 * 1024,
            opening.minimumFreeBytes >= 10 * 1024 * 1024 * 1024
        else { throw Self.failure("Invalid private maintenance allowance.") }
        guard let marker = try Self.markerBytes(self.root),
            AuthorityRecordCodec.sha256(marker) == opening.expectedPendingSHA256
        else { throw Self.failure("Maintenance opening lost its exact existing marker.") }
        var limits = CanonicalMaintenanceJournal.Limits()
        limits.maximumStoredBytes = opening.maximumPrivateWorkBytes
        limits.maximumFileBytes = min(limits.maximumFileBytes, Int(opening.maximumPrivateWorkBytes))
        limits.minimumFreeBytes = opening.minimumFreeBytes
        journal = try .init(
            root: self.root, journal: Self.physical(opening.journalRoot), writerDescriptor: writer,
            plan: opening.plan,
            limits: limits)
        try session().requireFullyAppliedPlan()
        try requireBound(to: root)
    }
    private static func physical(_ url: URL) throws -> URL {
        // Foundation may turn /private/var back into the symlink /var. Resolve the Store's
        // already selected root, then retain strict no-follow opens and writer-inode binding.
        guard let name = realpath(url.path, nil) else {
            throw failure("Cannot resolve maintenance filesystem identity.")
        }
        defer { free(name) }
        return URL(fileURLWithPath: String(cString: name), isDirectory: true)
    }
    static func preflight(root: URL, opening: Opening) throws {
        guard let marker = try markerBytes(root),
            AuthorityRecordCodec.sha256(marker) == opening.expectedPendingSHA256
        else { throw failure("Maintenance requires its exact pre-existing marker before opening.") }
    }
    func close() {
        active = false
        scratchEvents.removeAll()
        journal = nil
    }
    private func session() throws -> CanonicalMaintenanceJournal {
        guard active, let journal else { throw Self.failure("Maintenance context is closed.") }
        return journal
    }
    private static func failure(_ message: String) -> TractandaError { .init("maintenanceConflict", message) }
    private static func proposed(_ operation: String, _ path: [String]) -> TractandaError {
        .init(
            "maintenanceProposedMutation",
            "Maintenance stopped before unplanned \(operation): \(path.joined(separator: "/"))")
    }
    static func pending(root: URL) throws -> Bool {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return false }
        guard fd >= 0 else { throw failure("Cannot inspect maintenance boundary.") }
        defer { tractanda_close(fd) }
        var s = stat()
        if fstatat(fd, CanonicalMaintenanceJournal.pendingName, &s, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw failure("Cannot inspect maintenance marker.") }
        return false
    }
    private static func markerBytes(_ root: URL) throws -> Data? {
        let fd = tractanda_open_private_directory(root.path)
        guard fd >= 0 else { throw failure("Unsafe maintenance root.") }
        defer { tractanda_close(fd) }
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        let result = tractanda_capture_private_artifact_at(
            fd, CanonicalMaintenanceJournal.pendingName, &pointer, &count, 16384)
        if result == 1 { return nil }
        guard result == 0, let pointer else { throw failure("Unsafe maintenance marker.") }
        defer { tractanda_private_free(pointer, count) }
        return Data(bytes: pointer, count: Int(count))
    }
    func requireBound(to suppliedRoot: URL) throws {
        guard active, try Self.physical(suppliedRoot).path == root.path,
            let marker = try Self.markerBytes(root),
            AuthorityRecordCodec.sha256(marker) == opening.expectedPendingSHA256
        else { throw Self.failure("Maintenance context/root/marker changed.") }
        try session().requireContextLease()
        try checkDerivedCapacity()
    }
    private static func exists(root: URL, path: [String]) throws -> Bool {
        guard !path.isEmpty, path.count <= 32,
            path.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
            })
        else { throw failure("Unsafe maintenance mutation path.") }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Cannot inspect maintenance path.") }
        defer { tractanda_close(fd) }
        for component in path.dropLast() {
            let child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0, errno == ENOENT { return false }
            guard child >= 0 else { throw failure("Unsafe maintenance mutation ancestor.") }
            tractanda_close(fd)
            fd = child
        }
        var value = stat()
        if fstatat(fd, path.last!, &value, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw failure("Cannot inspect maintenance mutation target.") }
        return false
    }
    static func deny(root: URL, path: [String], operation: String, onlyIfPresent: Bool = false) throws {
        if try pending(root: root) {
            if onlyIfPresent, try !exists(root: root, path: path) { return }
            throw proposed(operation, path)
        }
    }
    /// Missing cleanup targets are true no-ops. Existing canonical data is never removed
    /// during cold validation, including data whose bytes appeared in the applied static plan.
    static func removalIsNoOp(root: URL, path: [String]) throws -> Bool {
        guard try pending(root: root) else { return false }
        if try !exists(root: root, path: path) { return true }
        throw proposed("canonical file/directory removal", path)
    }
    private func checkpointSnapshot() throws -> DerivedSnapshot {
        let path = root.appendingPathComponent(StoreCheckpoint.name)
        let s: FileMetadata
        do { s = try FileMetadata.read(at: path) } catch FileMetadataError.posix(ENOENT) {
            return .init(
                path: StoreCheckpoint.name, exists: false, mode: nil, uid: nil, gid: nil, bytes: nil,
                sha256: nil)
        }
        guard s.type == .regular, s.uid == tractanda_uid(), s.mode & 0o777 == 0o600, s.size <= 4096 else {
            throw Self.failure("Unsafe derived checkpoint marker.")
        }
        let fd = tractanda_open_private_directory(root.path)
        guard fd >= 0 else { throw Self.failure("Cannot inspect derived checkpoint root.") }
        defer { tractanda_close(fd) }
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        guard tractanda_capture_private_artifact_at(fd, StoreCheckpoint.name, &pointer, &count, 4096) == 0,
            let pointer
        else { throw Self.failure("Derived checkpoint custody changed.") }
        defer { tractanda_private_free(pointer, count) }
        return .init(
            path: StoreCheckpoint.name, exists: true, mode: s.mode, uid: s.uid, gid: s.gid,
            bytes: UInt64(count), sha256: AuthorityRecordCodec.sha256(Data(bytes: pointer, count: Int(count)))
        )
    }
    /// The caller selects only a fixed dirty/clear primitive, never an arbitrary write closure.
    func beginCheckpoint(_ kind: DerivedKind, suppliedRoot: URL) throws -> String {
        guard kind == .checkpointDirty || kind == .checkpointClear else {
            throw Self.failure("Invalid derived checkpoint action.")
        }
        try requireBound(to: suppliedRoot)
        try checkDerivedCapacity(reserving: 16 * 1024)
        let event = try UUID.makeVersion1().uuidString.lowercased()
        try session().recordDerivedAudit(
            .init(
                operationID: opening.plan.operationID,
                eventID: event, kind: kind, phase: .intent, snapshot: checkpointSnapshot()))
        derivedEvents[event] = kind
        return event
    }
    func finishCheckpoint(_ event: String, suppliedRoot: URL, failed: Bool = false) throws {
        try requireBound(to: suppliedRoot)
        guard let kind = derivedEvents[event], kind == .checkpointDirty || kind == .checkpointClear else {
            throw Self.failure("Unowned checkpoint completion.")
        }
        let after = try checkpointSnapshot()
        if !failed {
            if kind == .checkpointDirty {
                guard after.sha256 == AuthorityRecordCodec.sha256(Data("dirty-v1\n".utf8)) else {
                    throw Self.failure("Dirty checkpoint result differs.")
                }
            } else {
                guard !after.exists else { throw Self.failure("Checkpoint clear did not complete.") }
            }
        }
        try session().recordDerivedAudit(
            .init(
                operationID: opening.plan.operationID,
                eventID: event, kind: kind, phase: failed ? .failed : .completed, snapshot: after))
        derivedEvents.removeValue(forKey: event)
    }
    /// Placement connections must carry this exact Store-owned capability even if their lock
    /// already exists. No canonical output is permitted by this derived-storage binding.
    func requireDerivedStorage(root suppliedRoot: URL, index suppliedIndex: URL) throws {
        try requireBound(to: suppliedRoot)
        let resolved: URL
        if FileManager.default.fileExists(atPath: suppliedIndex.path) {
            resolved = try Self.physical(suppliedIndex)
        } else {
            resolved = try Self.physical(suppliedIndex.deletingLastPathComponent())
                .appendingPathComponent(suppliedIndex.lastPathComponent)
        }
        guard resolved.path == indexDirectory.path else {
            throw Self.failure("Placement index differs from the bound maintenance index.")
        }
    }
    private func indexSnapshot() throws -> DerivedSnapshot {
        let metadata: FileMetadata?
        do { metadata = try FileMetadata.read(at: indexDirectory) } catch FileMetadataError.posix(ENOENT) {
            metadata = nil
        }
        return .init(
            path: indexDirectory.path, exists: metadata != nil, mode: metadata?.mode, uid: metadata?.uid,
            gid: metadata?.gid, bytes: metadata?.size, sha256: nil)
    }
    func beginDerived(_ kind: DerivedKind) throws -> String {
        guard [.indexOpening, .indexRebuild, .placement].contains(kind) else {
            throw Self.failure("Unexpected derived phase.")
        }
        try requireBound(to: root)
        let event = try UUID.makeVersion1().uuidString.lowercased()
        try session().recordDerivedAudit(
            .init(
                operationID: opening.plan.operationID, eventID: event, kind: kind, phase: .intent,
                snapshot: indexSnapshot()))
        derivedEvents[event] = kind
        return event
    }
    func finishDerived(_ event: String, failed: Bool = false) throws {
        guard let kind = derivedEvents[event] else { throw Self.failure("Unowned derived phase completion.") }
        try requireBound(to: root)
        try session().recordDerivedAudit(
            .init(
                operationID: opening.plan.operationID, eventID: event, kind: kind,
                phase: failed ? .failed : .completed, snapshot: indexSnapshot()))
        derivedEvents.removeValue(forKey: event)
    }
    /// This object is minted only from a retained exact canonical ACCEPTED attestation.
    /// Its permission is confined to disposable filesystem work; validators still own authority.
    final class HistoricalScratch {
        fileprivate weak var context: CanonicalMaintenanceContext?
        fileprivate let binding: AuthorityBinding
        fileprivate let receiptSHA256: String
        fileprivate let indexFD: Int32
        fileprivate var directories = [String: FileMetadata]()
        fileprivate var closed = false
        let root: URL
        let control: URL
        fileprivate init(
            context: CanonicalMaintenanceContext, binding: AuthorityBinding,
            receiptSHA256: String, indexFD: Int32
        ) {
            self.context = context
            self.binding = binding
            self.receiptSHA256 = receiptSHA256
            self.indexFD = indexFD
            root = context.indexDirectory.appendingPathComponent("atomic-authority-work")
                .appendingPathComponent(binding.recordID)
            control = root.appendingPathComponent("control")
        }
        deinit { tractanda_close(indexFD) }
        fileprivate func requireOwner() throws -> CanonicalMaintenanceContext {
            guard !closed, let context else {
                throw CanonicalMaintenanceContext.failure("Historical scratch owner closed.")
            }
            try context.requireBound(to: context.root)
            let named = tractanda_open_private_directory(context.indexDirectory.path)
            guard named >= 0 else {
                throw CanonicalMaintenanceContext.failure("Historical index custody changed.")
            }
            defer { tractanda_close(named) }
            var held = stat()
            var current = stat()
            guard fstat(indexFD, &held) == 0, fstat(named, &current) == 0,
                held.st_dev == current.st_dev, held.st_ino == current.st_ino
            else {
                throw CanonicalMaintenanceContext.failure("Historical index was replaced.")
            }
            for (relative, expected) in directories {
                let path = context.indexDirectory.appendingPathComponent(relative)
                let fd = tractanda_open_private_directory(path.path)
                guard fd >= 0 else {
                    throw CanonicalMaintenanceContext.failure("Historical directory custody changed.")
                }
                defer { tractanda_close(fd) }
                var actual = stat()
                guard fstat(fd, &actual) == 0, UInt64(actual.st_ino) == expected.inode,
                    UInt64(truncatingIfNeeded: actual.st_dev) == expected.device
                else {
                    throw CanonicalMaintenanceContext.failure("Historical directory was replaced.")
                }
            }
            return context
        }
        var storageHooks: AtomicAuthorityArchive.StorageHooks {
            .init(
                begin: { [self] operation, path, additional in
                    let owner = try requireOwner()
                    let allowed: Bool
                    switch operation {
                    case .immutableWrite:
                        allowed =
                            path == ["root"]
                            || (path.count == 3 && path[0] == "read-work"
                                && Self.uuid(path[1]) && Self.uuid(path[2]))
                    case .lease: allowed = path == [".archive.lock"]
                    case .removeFile:
                        allowed =
                            path.count == 3 && path[0] == "read-work" && Self.uuid(path[1])
                            && (Self.uuid(path[2]) || Self.temporary(path[2]))
                    case .removeDirectory:
                        allowed = path.count == 2 && path[0] == "read-work" && Self.uuid(path[1])
                    }
                    guard allowed else {
                        throw CanonicalMaintenanceContext.failure(
                            "Historical archive attempted producer/package work.")
                    }
                    return try owner.beginScratchMutation(
                        self, path: ["control"] + path,
                        operation: operation.rawValue, additional: additional)
                },
                finish: { [self] ticket, failed in
                    try requireOwner().finishScratchMutation(ticket, failed: failed)
                })
        }
        fileprivate static func uuid(_ name: String) -> Bool {
            (try? AuthorityRecord.persistentID(.text(name))) != nil
        }
        fileprivate static func temporary(_ name: String) -> Bool {
            guard name.hasPrefix(".peer-artifact-"), name.hasSuffix(".tmp") else { return false }
            let token = String(name.dropFirst(15).dropLast(4))
            return UUID(uuidString: token)?.uuidString == token
        }
        func cleanup() throws {
            let owner = try requireOwner()
            try owner.cleanupScratch(self)
            closed = true
        }
    }
    func prepareHistoricalScratch(
        _ attestation: AtomicAuthorityHistoricalAcceptance,
        coordinator: PeerIntakeCoordinator
    ) throws -> HistoricalScratch {
        try requireBound(to: coordinator.root)
        let receipt = attestation.sealed.receipt
        guard coordinator.storeID == opening.plan.storeID, receipt.storeID == opening.plan.storeID,
            receipt.receiverReplicaID == opening.plan.replicaID,
            attestation.original.descriptor.id == receipt.root.recordID,
            attestation.original.descriptor.sha256 == receipt.root.sha256
        else {
            throw Self.failure("Historical scratch attestation belongs to another replica/root.")
        }
        try attestation.requireStableCanonicalBinding(coordinator: coordinator)
        let raw = try CanonicalAuthorityOriginal(coordinator.bytes(attestation.original))
        guard case .atomic(let record) = raw.payload, record.kind == .atomicControl,
            raw.recordID == receipt.root.recordID, raw.sha256 == receipt.root.sha256,
            raw.storeID == opening.plan.storeID
        else { throw Self.failure("Historical scratch lost canonical root bytes.") }
        historicalStoredBytes = try historicalCensus()
        try checkDerivedCapacity()
        let fd = tractanda_open_private_directory(indexDirectory.path)
        guard fd >= 0 else { throw Self.failure("Cannot retain historical index directory.") }
        let scope = HistoricalScratch(
            context: self, binding: receipt.root,
            receiptSHA256: attestation.sealed.bytesSHA256, indexFD: fd)
        do {
            for path in [[String](), ["control"]] {
                // The fixed shared base is created separately; no generic ensureDirectory grant.
                if path.isEmpty { try createScratchDirectory(scope, full: ["atomic-authority-work"]) }
                try createScratchDirectory(
                    scope, full: ["atomic-authority-work", receipt.root.recordID] + path)
            }
            try requireExactScratchRoot(scope)
            return scope
        } catch {
            // A partial exact known derived prefix is retained for a fresh validated owner.
            throw error
        }
    }
    private func scratchPath(_ scope: HistoricalScratch, _ path: [String]) -> [String] {
        ["atomic-authority-work", scope.binding.recordID] + path
    }
    private func historicalSnapshot(_ full: [String]) throws -> DerivedSnapshot {
        let url = full.reduce(indexDirectory) { $0.appendingPathComponent($1) }
        let metadata: FileMetadata
        do { metadata = try FileMetadata.read(at: url) } catch FileMetadataError.posix(ENOENT) {
            return .init(
                path: "index/" + full.joined(separator: "/"), exists: false,
                mode: nil, uid: nil, gid: nil, bytes: nil, sha256: nil)
        }
        let digest: String?
        if metadata.type == .regular {
            guard metadata.size <= UInt64(AtomicAuthorityFormat.maximumEnvelopeBytes) else {
                throw Self.failure("Historical audit object exceeds its native envelope bound.")
            }
            let parent = tractanda_open_private_directory(url.deletingLastPathComponent().path)
            guard parent >= 0 else { throw Self.failure("Historical audit parent changed.") }
            defer { tractanda_close(parent) }
            var pointer: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            guard
                tractanda_capture_private_artifact_at(
                    parent, url.lastPathComponent, &pointer, &count,
                    UInt32(AtomicAuthorityFormat.maximumEnvelopeBytes)) == 0, let pointer
            else {
                throw Self.failure("Historical audit bytes/custody changed.")
            }
            defer { tractanda_private_free(pointer, count) }
            digest = AuthorityRecordCodec.sha256(Data(bytes: pointer, count: Int(count)))
        } else {
            digest = nil
        }
        return .init(
            path: "index/" + full.joined(separator: "/"), exists: true,
            mode: metadata.mode, uid: metadata.uid, gid: metadata.gid, bytes: metadata.size, sha256: digest)
    }
    private func recordScratch(
        _ event: String, scope: HistoricalScratch, full: [String],
        operation: String, phase: DerivedPhase, allocation: ScratchAllocation,
        captured: DerivedSnapshot? = nil
    ) throws {
        try session().recordDerivedAudit(
            .init(
                operationID: opening.plan.operationID, eventID: event,
                kind: .historicalAtomicScratch, phase: phase, snapshot: captured ?? historicalSnapshot(full),
                canonicalRoot: scope.binding, acceptedReceiptSHA256: scope.receiptSHA256, mutation: operation,
                requestedScratchBytes: allocation.requested, reservedScratchBytes: allocation.reserved,
                scratchAllocationState: allocation.state)
        )
    }
    private func beginScratchMutation(
        _ scope: HistoricalScratch, path: [String], operation: String,
        additional: UInt64, fullOverride: [String]? = nil
    ) throws -> String {
        _ = try scope.requireOwner()
        try checkDerivedCapacity(reserving: 16 * 1024)
        let full = fullOverride ?? scratchPath(scope, path)
        let event = try UUID.makeVersion1().uuidString.lowercased()
        let before = try historicalSnapshot(full)
        let retained = historicalStoredBytes ?? 0
        var refusal: Error?
        do {
            let limit = min(
                opening.maximumPrivateWorkBytes,
                opening.maximumHistoricalScratchBytes ?? opening.maximumPrivateWorkBytes)
            guard additional <= limit - min(retained, limit) else {
                throw TractandaError(
                    "resourceLimit", "Next historical archive write exceeds its downward-only allowance.")
            }
            let requested = additional.addingReportingOverflow(16 * 1024)
            guard !requested.overflow else { throw Self.failure("Historical allocation overflow.") }
            try checkDerivedCapacity(reserving: requested.partialValue)
        } catch { refusal = error }
        let allocation = ScratchAllocation(
            requested: additional,
            reserved: refusal == nil ? additional : 0, state: refusal == nil ? .reserved : .refused)
        if refusal == nil {
            // Charge before the durable reserved intent. A failed/uncertain audit does not
            // refund this reservation; a fresh exact census/owned cleanup reconciles it.
            historicalStoredBytes = retained + additional
        }
        try recordScratch(
            event, scope: scope, full: full, operation: operation, phase: .intent,
            allocation: allocation, captured: before)
        scratchEvents[event] = (scope, full, operation, before, allocation)
        if let refusal {
            try? finishScratchMutation(event, failed: true)
            throw refusal
        }
        return event
    }
    private func finishScratchMutation(_ event: String, failed: Bool) throws {
        guard let (scope, full, operation, before, allocation) = scratchEvents[event] else {
            throw Self.failure("Unowned historical mutation result.")
        }
        _ = try scope.requireOwner()
        let after = try historicalSnapshot(full)
        let removal = ["removeFile", "removeDirectory", "unlink", "rmdir"].contains(operation)
        if removal && !failed && after.exists {
            throw Self.failure("Historical cleanup did not remove its owned target.")
        }
        try recordScratch(
            event, scope: scope, full: full, operation: operation,
            phase: failed ? .failed : .completed, allocation: allocation, captured: after)
        if removal && !failed && before.exists {
            let directory = (before.mode ?? 0) & 0o170000 == 0o040000
            let released = (directory ? 0 : (before.bytes ?? 0)) + 4096
            historicalStoredBytes = (historicalStoredBytes ?? 0) - min(historicalStoredBytes ?? 0, released)
        }
        scratchEvents.removeValue(forKey: event)
    }
    private func createScratchDirectory(_ scope: HistoricalScratch, full: [String]) throws {
        let url = full.reduce(indexDirectory) { $0.appendingPathComponent($1) }
        if FileManager.default.fileExists(atPath: url.path) {
            let checked = tractanda_open_private_directory(url.path)
            guard checked >= 0 else { throw Self.failure("Historical directory is unsafe.") }
            tractanda_close(checked)
            scope.directories[full.joined(separator: "/")] = try FileMetadata.read(at: url)
            return
        }
        let event = try beginScratchMutation(
            scope, path: [], operation: "mkdir", additional: 4096, fullOverride: full)
        do {
            let parentURL = url.deletingLastPathComponent()
            let parent = tractanda_open_private_directory(parentURL.path)
            guard parent >= 0 else { throw Self.failure("Historical parent is unsafe.") }
            defer { tractanda_close(parent) }
            guard mkdirat(parent, full.last!, 0o700) == 0, fsync(parent) == 0 else {
                throw Self.failure("Cannot durably create historical directory.")
            }
            let child = tractanda_open_private_directory(url.path)
            guard child >= 0 else { throw Self.failure("Historical directory custody changed.") }
            tractanda_close(child)
            scope.directories[full.joined(separator: "/")] = try FileMetadata.read(at: url)
            try finishScratchMutation(event, failed: false)
        } catch {
            try? finishScratchMutation(event, failed: true)
            throw error
        }
    }
    private func requireExactScratchRoot(_ scope: HistoricalScratch) throws {
        let snapshot = try historicalSnapshot(scratchPath(scope, ["control", "root"]))
        guard !snapshot.exists || snapshot.sha256 == scope.binding.sha256 else {
            throw Self.failure("Historical scratch root differs from its exact canonical attestation.")
        }
    }
    private func cleanupScratch(_ scope: HistoricalScratch) throws {
        _ = try scope.requireOwner()
        historicalStoredBytes = try historicalCensus()  // complete unknown-path check BEFORE deletion
        try requireExactScratchRoot(scope)
        let base = ["atomic-authority-work", scope.binding.recordID]
        func remove(_ path: [String]) throws {
            let url = path.reduce(indexDirectory) { $0.appendingPathComponent($1) }
            var metadata = try FileMetadata.read(at: url)
            if metadata.type == .directory {
                let fd = tractanda_open_private_directory(url.path)
                guard fd >= 0 else { throw Self.failure("Historical cleanup directory changed.") }
                defer { tractanda_close(fd) }
                try POSIXDirectory.withEntries(descriptor: fd) { name in
                    try remove(path + [name])
                    return true
                }
                metadata = try FileMetadata.read(at: url)
            }
            let event = try beginScratchMutation(
                scope, path: [],
                operation: metadata.type == .directory ? "rmdir" : "unlink", additional: 0, fullOverride: path
            )
            do {
                let parent = tractanda_open_private_directory(url.deletingLastPathComponent().path)
                guard parent >= 0 else { throw Self.failure("Historical cleanup parent changed.") }
                defer { tractanda_close(parent) }
                guard try FileMetadata.read(at: url) == metadata,
                    unlinkat(parent, path.last!, metadata.type == .directory ? AT_REMOVEDIR : 0) == 0,
                    fsync(parent) == 0
                else { throw Self.failure("Historical cleanup target changed.") }
                scope.directories.removeValue(forKey: path.joined(separator: "/"))
                try finishScratchMutation(event, failed: false)
            } catch {
                try? finishScratchMutation(event, failed: true)
                throw error
            }
        }
        try remove(base)
        historicalStoredBytes = try historicalCensus()
        try checkDerivedCapacity()
    }
    private func historicalCensus() throws -> UInt64 {
        let base = indexDirectory.appendingPathComponent("atomic-authority-work")
        do {
            guard try FileMetadata.read(at: base).type == .directory else {
                throw Self.failure("Historical namespace is not a directory.")
            }
        } catch FileMetadataError.posix(ENOENT) { return 0 }
        var total: UInt64 = 0
        var entries: UInt64 = 0
        func valid(_ path: [String], directory: Bool) -> Bool {
            if directory {
                return path.isEmpty || (path.count == 1 && HistoricalScratch.uuid(path[0]))
                    || (path.count == 2 && HistoricalScratch.uuid(path[0]) && path[1] == "control")
                    || (path.count == 3 && HistoricalScratch.uuid(path[0])
                        && Array(path.dropFirst()) == ["control", "read-work"])
                    || (path.count == 4 && HistoricalScratch.uuid(path[0]) && path[1] == "control"
                        && path[2] == "read-work" && HistoricalScratch.uuid(path[3]))
            }
            return
                (path.count == 3 && HistoricalScratch.uuid(path[0]) && path[1] == "control"
                && (["root", ".archive.lock"].contains(path[2]) || HistoricalScratch.temporary(path[2])))
                || (path.count == 5 && HistoricalScratch.uuid(path[0]) && path[1] == "control"
                    && path[2] == "read-work" && HistoricalScratch.uuid(path[3])
                    && (HistoricalScratch.uuid(path[4]) || HistoricalScratch.temporary(path[4])))
        }
        func visit(_ path: [String]) throws {
            try Task.checkCancellation()
            let url = path.reduce(base) { $0.appendingPathComponent($1) }
            let metadata = try FileMetadata.read(at: url)
            let directory = metadata.type == .directory
            guard metadata.uid == tractanda_uid(), valid(path, directory: directory) else {
                throw Self.failure("Unrecognized historical scratch path: " + path.joined(separator: "/"))
            }
            entries += 1
            let cost = (directory ? UInt64(0) : metadata.size).addingReportingOverflow(4096)
            guard !cost.overflow, entries <= opening.maximumPrivateWorkBytes / 4096,
                cost.partialValue <= opening.maximumPrivateWorkBytes
                    - min(total, opening.maximumPrivateWorkBytes)
            else {
                throw TractandaError("resourceLimit", "Historical scratch census exceeds combined allowance.")
            }
            total += cost.partialValue
            if directory {
                let fd = tractanda_open_private_directory(url.path)
                guard fd >= 0 else { throw Self.failure("Historical scratch directory custody changed.") }
                defer { tractanda_close(fd) }
                try POSIXDirectory.withEntries(descriptor: fd) { name in
                    try visit(path + [name])
                    return true
                }
            } else {
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw Self.failure("Historical scratch file custody changed.") }
                defer { tractanda_close(fd) }
                var value = stat()
                let lock = path.last == ".archive.lock"
                let temporary = HistoricalScratch.temporary(path.last!)
                guard metadata.type == .regular, fstat(fd, &value) == 0, value.st_nlink == 1,
                    value.st_ino == metadata.inode,
                    UInt64(truncatingIfNeeded: value.st_dev) == metadata.device,
                    tractanda_peer_configuration_no_mutation_acl(fd) == 0,
                    lock
                        ? metadata.mode & 0o7777 == 0o600
                        : (temporary
                            ? [UInt32(0o400), UInt32(0o600)].contains(metadata.mode & 0o7777)
                            : metadata.mode & 0o7777 == 0o400),
                    metadata.size
                        <= (lock
                            ? 0 : (path.count == 5 ? 1 : UInt64(AtomicAuthorityFormat.maximumEnvelopeBytes)))
                else { throw Self.failure("Unsafe historical scratch file.") }
                var contents = Data(count: Int(metadata.size))
                try contents.withUnsafeMutableBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        try Task.checkCancellation()
                        let count = pread(
                            fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset)
                        )
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw Self.failure("Historical scratch read ended early.") }
                        offset += count
                    }
                }
                var after = stat()
                guard fstat(fd, &after) == 0, after.st_nlink == 1,
                    after.st_size >= 0, UInt64(after.st_size) == metadata.size,
                    try FileMetadata.read(at: url) == metadata
                else {
                    throw Self.failure("Historical scratch changed during census.")
                }
                if path.count == 5 {
                    guard contents == Data([1]) || (temporary && contents.isEmpty) else {
                        throw Self.failure("Unknown historical reader-marker contents.")
                    }
                } else if path.last == "root" {
                    let record = try AtomicAuthorityFormat.Codec.decode(contents)
                    guard record.kind == .atomicControl, record.recordID == path[0],
                        record.storeID == opening.plan.storeID
                    else {
                        throw Self.failure("Historical scratch root shape/identity changed.")
                    }
                }
            }
        }
        try visit([])
        return total
    }
    func checkDerivedCapacity(reserving additional: UInt64 = 0) throws {
        var total = try session().privateStoredBytes()
        let path = indexDirectory.path
        guard !path.hasPrefix(root.path + "/") || path == root.appendingPathComponent("index").path else {
            throw Self.failure("Maintenance derived work is not a canonical namespace.")
        }
        guard path != root.path,
            !["items", "attachments", "documents", "authority", ".peer-credentials"].contains(where: {
                path == root.appendingPathComponent($0).path
                    || path.hasPrefix(root.appendingPathComponent($0).path + "/")
            })
        else { throw Self.failure("Derived work overlaps canonical data.") }
        if FileManager.default.fileExists(atPath: path) {
            let fd = tractanda_open_private_directory(path)
            guard fd >= 0 else { throw Self.failure("Unsafe derived maintenance directory.") }
            defer { tractanda_close(fd) }
            try POSIXDirectory.withEntries(descriptor: fd) { name in
                if name == "atomic-authority-work" {
                    if historicalStoredBytes == nil { historicalStoredBytes = try historicalCensus() }
                    let size = historicalStoredBytes!
                    guard
                        size <= opening.maximumPrivateWorkBytes - min(total, opening.maximumPrivateWorkBytes)
                    else {
                        throw TractandaError("resourceLimit", "Historical scratch exceeds shared allowance.")
                    }
                    total += size
                    return true
                }
                let suffixes = ["", "-wal", "-shm", "-journal"]
                let database = ["items.sqlite", "payloads.sqlite", "documents.sqlite"].contains { base in
                    suffixes.contains { name == base + $0 }
                }
                let rebuild = suffixes.contains { suffix in
                    let end = ".sqlite" + suffix
                    guard name.hasPrefix("rebuild-"), name.hasSuffix(end) else { return false }
                    let token = String(name.dropFirst(8).dropLast(end.count))
                    return UUID(uuidString: token) != nil
                }
                let allowed =
                    [".tractanda-index-binding.json", ".tractanda-index.writer.lock"].contains(name)
                    || database || rebuild
                guard allowed else { throw Self.failure("Unrecognized derived work path: \(name)") }
                var s = stat()
                // SQLite inherits its existing creation umask (commonly 0600 or 0644).
                // This directory was freshly checked as owner-only0700/no-ACL above; permit
                // only read bits outside the owner, never non-owner write/execute or set-ID.
                guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0,
                    s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), s.st_uid == tractanda_uid(),
                    s.st_mode & 0o600 == 0o600,
                    (s.st_mode & 0o7777) & ~mode_t(0o644) == 0, s.st_nlink == 1, s.st_size >= 0
                else {
                    throw Self.failure(
                        "Unsafe derived work file: \(name), mode=\(String(s.st_mode, radix: 8)), uid=\(s.st_uid), nlink=\(s.st_nlink), bytes=\(s.st_size), errno=\(errno)."
                    )
                }
                let size = UInt64(s.st_size)
                guard size <= opening.maximumPrivateWorkBytes - min(total, opening.maximumPrivateWorkBytes)
                else {
                    throw TractandaError(
                        "resourceLimit", "Combined maintenance journal/index allowance exhausted.")
                }
                total += size
                return true
            }
        }
        guard additional <= opening.maximumPrivateWorkBytes - min(total, opening.maximumPrivateWorkBytes)
        else {
            throw TractandaError(
                "resourceLimit", "Next maintenance write exceeds the combined private allowance.")
        }
        for directory in [root, indexDirectory.deletingLastPathComponent()] {
            var fs = statvfs()
            guard statvfs(directory.path, &fs) == 0, fs.f_frsize > 0 else {
                throw Self.failure("Cannot determine maintenance filesystem capacity.")
            }
            let free = UInt64(fs.f_bavail).multipliedReportingOverflow(by: UInt64(fs.f_frsize))
            guard !free.overflow, free.partialValue >= opening.minimumFreeBytes,
                additional <= free.partialValue - opening.minimumFreeBytes
            else {
                throw TractandaError("resourceLimit", "Maintenance free-space reserve unavailable.")
            }
        }
    }
}
