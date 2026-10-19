import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct RebuildAdministratorPolicy: Sendable {
    let ownerUID: UInt32
    let configuration: AccessConfiguration?
    func authorize(uid: UInt32, accounts: any AccountDirectory) throws {
        guard let configuration else {
            guard uid == ownerUID else {
                throw TractandaError("forbidden", "Only the store owner may rebuild.")
            }
            return
        }
        if configuration.administration == .system, uid == 0 { return }
        let account = try accounts.user(forUID: uid)
        let permitted: Bool
        if configuration.administration == .serviceOwner {
            permitted = uid == ownerUID
        } else {
            permitted = try account.groupIDs.contains(
                accounts.groupID(
                    named: configuration.administratorGroup ?? AccessConfiguration.defaultAdministratorGroup))
        }
        guard permitted else { throw TractandaError("forbidden", "A current OS administrator is required.") }
    }
    func accountIfAdmitted(uid: UInt32, accounts: any AccountDirectory) throws -> AccountIdentity {
        guard let configuration else {
            guard uid == ownerUID else {
                throw TractandaError("forbidden", "This store admits only its owner.")
            }
            return try accounts.user(forUID: uid)
        }
        let account = try accounts.user(forUID: uid)
        let administrator: Bool
        if configuration.administration == .system, uid == 0 {
            administrator = true
        } else if configuration.administration == .serviceOwner {
            administrator = uid == ownerUID
        } else {
            let group = try accounts.groupID(
                named: configuration.administratorGroup ?? AccessConfiguration.defaultAdministratorGroup)
            administrator = account.groupIDs.contains(group)
        }
        if administrator { return account }
        let resolver = PrincipalResolver(directory: accounts, configuration: configuration)
        try configuration.validate(using: resolver)
        let admittedUser = try configuration.users.contains { try resolver.userID($0) == uid }
        let admittedGroup = try configuration.groups.contains {
            try account.groupIDs.contains(resolver.groupID($0))
        }
        guard admittedUser || admittedGroup else {
            throw TractandaError("forbidden", "This account is not admitted to the store.")
        }
        return account
    }

}

/// Private operational status is always bounded and atomically replaced after file/parent sync.
final class RebuildJournal: @unchecked Sendable {
    private let root: URL
    private let ownerUID: UInt32
    private static let name = ".rebuild-status.json"
    init(root: URL, ownerUID: UInt32) {
        self.root = root
        self.ownerUID = ownerUID
    }
    private func openRoot() throws -> Int32 {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var metadata = stat()
        guard fd >= 0 else {
            throw TractandaError("rebuildStatusIO", "Cannot open private rebuild journal root.")
        }
        guard fstat(fd, &metadata) == 0, metadata.st_uid == ownerUID,
            metadata.st_mode & 0o077 == 0
        else {
            close(fd)
            throw TractandaError("rebuildStatusIO", "Unsafe rebuild journal root.")
        }
        return fd
    }
    func load() throws -> StoreRebuildStatus? {
        let parent = try openRoot()
        defer { close(parent) }
        let fd = Self.name.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw TractandaError("rebuildStatusIO", "Cannot open rebuild status.") }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            metadata.st_uid == ownerUID, metadata.st_mode & 0o777 == 0o400,
            metadata.st_size > 0, metadata.st_size <= 16 * 1024
        else {
            throw TractandaError("rebuildStatusIO", "Unsafe or oversized rebuild status.")
        }
        let data =
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 16 * 1024 + 1) ?? Data()
        guard data.count == metadata.st_size else {
            throw TractandaError("rebuildStatusIO", "Rebuild status changed.")
        }
        let status = try JSON.decode(StoreRebuildStatus.self, data)
        try status.validate()
        guard UUID(uuidString: status.jobID)?.version1Components != nil, status.operationID.utf8.count <= 200,
            status.recordsVerified >= 0, status.itemsProjected >= 0, status.originalBytesVerified >= 0,
            status.documentPagesVerified >= 0,
            status.noProgressTimeoutSeconds.isFinite, status.noProgressTimeoutSeconds > 0
        else {
            throw TractandaError("rebuildStatusIO", "Invalid rebuild status.")
        }
        return status
    }
    func save(_ status: StoreRebuildStatus) throws {
        let data = try JSON.encode(status)
        guard data.count <= 16 * 1024 else {
            throw TractandaError("rebuildStatusIO", "Rebuild status exceeds its window.")
        }
        let parent = try openRoot()
        defer { close(parent) }
        let temporary = ".rebuild-status-" + UUID().uuidString
        let fd = temporary.withCString {
            openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { throw TractandaError("rebuildStatusIO", "Cannot stage rebuild status.") }
        defer {
            close(fd)
            _ = temporary.withCString { unlinkat(parent, $0, 0) }
        }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fchmod(fd, 0o400) == 0, fsync(fd) == 0,
            temporary.withCString({ source in Self.name.withCString { renameat(parent, source, parent, $0) } }
            ) == 0,
            fsync(parent) == 0
        else { throw TractandaError("rebuildStatusIO", "Cannot synchronize rebuild status.") }
    }
    func recoverInterrupted(indexTrusted: Bool) throws -> StoreRebuildStatus? {
        guard var status = try load() else { return nil }
        if !status.isTerminal || status.requiresRecovery && indexTrusted {
            if !status.isTerminal { status.state = "interruptedRecovered" }
            status.phase = "startupRecoveryCompleted"
            status.indexTrusted = indexTrusted
            status.requiresRecovery = !indexTrusted
            status.updatedAt = Timestamp.now()
            if status.errorCode == nil { status.errorCode = "interrupted" }
            try save(status)
        }
        return status
    }
}

/// GCD closures cannot observe the parent Swift Task's cancellation. This explicit control is
/// checked at record, 256KiB original-hash and bounded document-node/page boundaries.
final class RebuildControl: @unchecked Sendable {
    private let lock = NSLock()
    private let journal: RebuildJournal
    private let publicationAuthority: @Sendable () throws -> Void
    private var value: StoreRebuildStatus
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var lastPersistence = ProcessInfo.processInfo.systemUptime
    private var cancellation: String?
    init(
        status: StoreRebuildStatus, journal: RebuildJournal,
        publicationAuthority: @escaping @Sendable () throws -> Void = {}
    ) throws {
        value = status
        self.journal = journal
        self.publicationAuthority = publicationAuthority
        try journal.save(status)
    }
    var status: StoreRebuildStatus {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    private func checkLocked() throws {
        if let cancellation {
            throw TractandaError(
                cancellation, "Rebuild stopped; incomplete indexes require completed recovery.")
        }
        if ProcessInfo.processInfo.systemUptime - lastProgress > value.noProgressTimeoutSeconds {
            cancellation = "rebuildNoProgress"
            throw TractandaError("rebuildNoProgress", "Rebuild exceeded its configured no-progress interval.")
        }
    }
    func authorizePublication() throws {
        try check()
        try publicationAuthority()
    }
    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkLocked()
    }
    /// Actual graph VM/page/queue work advances liveness without pretending it projected items.
    func graphProgress() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkLocked()
        let now = ProcessInfo.processInfo.systemUptime
        lastProgress = now
        if now - lastPersistence >= 1 {
            value.updatedAt = Timestamp.now()
            try journal.save(value)
            lastPersistence = now
        }
    }
    func pulse(
        phase: String? = nil, records: Int64 = 0, originalBytes: Int64 = 0, pages: Int64 = 0,
        items: Int64 = 0, durabilityEntries: Int64 = 0
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkLocked()
        let advanced =
            (phase != nil && phase != value.phase) || records > 0 || originalBytes > 0 || pages > 0
            || items > 0 || durabilityEntries > 0
        if let phase { value.phase = phase }
        if phase == "verifyingCanonicalClosure" {
            value.indexTrusted = false
            value.requiresRecovery = true
        }
        for (current, delta) in [
            (value.recordsVerified, records), (value.originalBytesVerified, originalBytes),
            (value.documentPagesVerified, pages), (value.itemsProjected, items),
            (value.durabilityEntriesChecked, durabilityEntries),
        ] {
            guard delta >= 0, !current.addingReportingOverflow(delta).overflow else {
                throw TractandaError("resourceLimit", "Rebuild progress count overflowed.")
            }
        }
        value.durabilityEntriesChecked += durabilityEntries
        value.itemsProjected += items
        value.recordsVerified += records
        value.originalBytesVerified += originalBytes
        value.documentPagesVerified += pages
        value.updatedAt = Timestamp.now()
        if advanced { lastProgress = ProcessInfo.processInfo.systemUptime }
        if value.state == "queued", phase != nil { value.state = "running" }
        if phase != nil || lastProgress - lastPersistence >= 1 {
            try journal.save(value)
            lastPersistence = lastProgress
        }
    }
    func cancel(code: String = "cancelled", onlyIfStalled: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !value.isTerminal else { return }
        if onlyIfStalled,
            ProcessInfo.processInfo.systemUptime - lastProgress <= value.noProgressTimeoutSeconds
        {
            return
        }
        cancellation = code
        value.state = "stopping"
        value.errorCode = code
        value.updatedAt = Timestamp.now()
        try journal.save(value)
    }
    func noteStatusPersistenceFailure() {
        lock.lock()
        defer { lock.unlock() }
        value.state = "failed"
        value.phase = "statusPersistenceFailed"
        value.errorCode = "rebuildStatusIO"
    }
    func finish(error: Error?, indexTrusted: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        value.state =
            error == nil
            ? "completed" : ((error as? TractandaError)?.code == "cancelled" ? "cancelled" : "failed")
        value.phase =
            error == nil ? "complete" : (indexTrusted ? "stoppedWithTrustedIndex" : "recoveryRequired")
        value.indexTrusted = indexTrusted
        value.requiresRecovery = !indexTrusted
        value.errorCode = error.map { ($0 as? TractandaError)?.code ?? "rebuildFailed" }
        value.updatedAt = Timestamp.now()
        try journal.save(value)
    }
}

struct RebuildNativeCall {
    let method: String
    let callID: String
    let arguments: [String: Any]
}
struct RebuildAdmission: Sendable {
    let policy: RebuildAdministratorPolicy
    let state: String
    let indexTrusted: Bool
}
