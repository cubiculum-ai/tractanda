import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public struct ImportRecordProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case planned, admitted, originalStored, complete, skipped }
    public var phase: Phase = .planned
    public var itemID: String?
    public var revisionID: String?
    public var originalAttachmentID: String?
    public var outcome: ImportOutcome?
    public var pendingCommit: CommitRequest?
    public var pendingCommitBytes: Data?
    public var pendingUpload: AttachmentUploadRequest?
    public var pendingUploadBytes: Data?
    public var uploadID: String?
    public var uploadAttachmentID: String?
    public var acknowledgedOffset: Int64 = 0
    public var originalDisposition: ImportDisposition = .create
    public var aliases: [String] = []
    public var previousManagedFields: [String] = []
    public var events: [ImportDiagnostic] = []
    public init() {}

    func validate() throws {
        guard (pendingCommit == nil) == (pendingCommitBytes == nil),
            (pendingUpload == nil) == (pendingUploadBytes == nil),
            acknowledgedOffset >= 0, events.count <= 32, try JSON.encode(events).count <= 65_536
        else { throw TractandaError("importJournal", "Incomplete or oversized journal request identity.") }
        if let request = pendingCommit {
            guard try JSON.encode(request) == pendingCommitBytes,
                request.action == .create || request.action == .revise,
                request.action != .create || (request.classID == "Item" && request.itemID == nil),
                request.changes["permissions"] == nil, !request.unset.contains("permissions"),
                request.fieldOperations?.isEmpty != false,
                !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
                !request.operationID.contains("\0")
            else { throw TractandaError("importJournal", "Exact pending commit request changed.") }
        }
        if let request = pendingUpload {
            guard try JSON.encode(request) == pendingUploadBytes, request.itemID == itemID,
                request.expectedRevisionID == revisionID, request.byteCount >= acknowledgedOffset
            else { throw TractandaError("importJournal", "Exact pending original request changed.") }
        }
        for identifier in [itemID, revisionID, originalAttachmentID, uploadID, uploadAttachmentID].compactMap(
            { $0 })
        {
            try Identifier.validate(identifier)
        }
    }
}

public struct ImportJournalState: Codable, Equatable, Sendable {
    public var schema = "tractanda.import-journal.v1"
    public var plan: ImportPlan
    public var planSHA256: String
    public var binding: ImportBinding
    public var records: [String: ImportRecordProgress]
    public var report: ImportReport
    public init(plan: ImportPlan, binding: ImportBinding) throws {
        try plan.validate()
        self.plan = plan
        planSHA256 = try plan.sha256
        self.binding = binding
        records = Dictionary(uniqueKeysWithValues: plan.records.map { ($0.sourceID, ImportRecordProgress()) })
        report = ImportReport(namespace: plan.namespace)
        refreshReport()
    }
    public func validate() throws {
        try plan.validate()
        guard schema == "tractanda.import-journal.v1", try plan.sha256 == planSHA256,
            Set(records.keys) == Set(plan.records.map(\.sourceID)), report.namespace == plan.namespace,
            ImportHash.validIdentity(binding.storeID), ImportHash.validIdentity(binding.principal),
            ImportHash.validIdentity(binding.endpoint)
        else { throw TractandaError("importJournal", "Import plan or destination identity changed.") }
        for progress in records.values { try progress.validate() }
    }
    mutating func refreshReport() {
        let unselected = report.outcomes.filter { records[$0.sourceID] == nil }
        let events = plan.records.flatMap { records[$0.sourceID]?.events ?? [] }
        let eventSet = Set(events)
        report.diagnostics = report.diagnostics.filter { !eventSet.contains($0) } + events
        report.outcomes =
            plan.records.map { record in
                let progress = records[record.sourceID]!
                if progress.phase == .complete || progress.phase == .skipped, let outcome = progress.outcome {
                    return outcome
                }
                return ImportOutcome(
                    sourceID: record.sourceID, disposition: .incomplete, itemID: progress.itemID,
                    revisionID: progress.revisionID,
                    diagnostics: [
                        ImportDiagnostic(
                            "incompleteImport",
                            "Exact journal retains pending import phase: " + progress.phase.rawValue)
                    ])
            } + unselected
    }

}

/// A private, bounded exact-intent outbox. It is operational state, not the canonical mapping.
/// The process-scoped lease prevents two resumes of this journal; it is not a cross-peer lease.
public final class ImportJournal {
    private struct Header: Codable {
        var schema = "tractanda.import-directory.v1"
        let planSHA256: String
        let binding: ImportBinding
        let diagnostics: [ImportDiagnostic]
        let unselectedOutcomes: [ImportOutcome]
    }
    private struct RecordFile: Codable {
        let sourceID: String
        let planSHA256: String
        let progress: ImportRecordProgress
    }
    public let directory: URL
    private let directoryFD: Int32
    private let lockFD: Int32
    private let maximumBytes: Int
    private let minimumFreeBytes: Int64
    private var header: Header?
    private var selectedIDs: Set<String> = []
    private var fileBytes: [String: Int] = [:]
    private var totalBytes = 0
    private var selectedMaximumBytes: Int?
    // Payload write accounting makes linear retained-state work observable in focused tests.
    private(set) var bytesWrittenForTesting: Int64 = 0
    private(set) var recordWritesForTesting = 0
    private(set) var planWritesForTesting = 0

    public init(directory: URL, create: Bool = false, limits: ImportLimits = ImportLimits()) throws {
        try limits.validate()
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0") else {
            throw TractandaError("importJournal", "Journal must be an absolute private directory.")
        }
        if create {
            guard mkdir(directory.path, 0o700) == 0 else {
                throw Self.failure("New import journal directory must not already exist.")
            }
        }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure("Cannot open private import journal.") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
        else {
            _ = close(descriptor)
            throw TractandaError(
                "importJournal", "Journal directory must be private and owned by the current account.")
        }
        let lock = openat(descriptor, ".import.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            _ = close(descriptor)
            throw Self.failure("Cannot open import journal lease.")
        }
        var lockMetadata = stat()
        guard fstat(lock, &lockMetadata) == 0, lockMetadata.st_uid == getuid(),
            lockMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            lockMetadata.st_mode & 0o777 == 0o600, lockMetadata.st_nlink == 1,
            flock(lock, LOCK_EX | LOCK_NB) == 0
        else {
            _ = close(lock)
            _ = close(descriptor)
            throw TractandaError("importJournalBusy", "Import journal is busy or its lease is unsafe.")
        }
        self.directory = directory
        directoryFD = descriptor
        lockFD = lock
        maximumBytes = limits.maximumJournalBytes
        minimumFreeBytes = limits.minimumFreeBytes
    }
    deinit {
        _ = flock(lockFD, LOCK_UN)
        _ = close(lockFD)
        _ = close(directoryFD)
    }
    public var exists: Bool {
        var metadata = stat()
        return fstatat(directoryFD, "state.json", &metadata, AT_SYMLINK_NOFOLLOW) == 0
    }

    public func load() throws -> ImportJournalState {
        header = nil
        selectedIDs = []
        selectedMaximumBytes = nil
        fileBytes = [:]
        totalBytes = 0
        let loaded = try JSON.decode(Header.self, readFile("state.json"))
        guard loaded.schema == "tractanda.import-directory.v1" else {
            throw TractandaError("importJournal", "Unsupported import journal directory format.")
        }
        let plan = try JSON.decode(ImportPlan.self, readFile("plan.json"))
        try plan.validate()
        guard try plan.sha256 == loaded.planSHA256 else {
            throw TractandaError("importJournal", "Immutable selected import plan changed.")
        }
        selectedIDs = Set(plan.records.map(\.sourceID))
        selectedMaximumBytes = plan.limits.maximumJournalBytes
        try inspectRetainedFiles(maximum: min(maximumBytes, plan.limits.maximumJournalBytes))
        var state = try ImportJournalState(plan: plan, binding: loaded.binding)
        state.report = ImportReport(
            namespace: plan.namespace, outcomes: loaded.unselectedOutcomes, diagnostics: loaded.diagnostics)
        for sourceID in selectedIDs {
            let record = try JSON.decode(RecordFile.self, readFile(recordName(sourceID)))
            guard record.sourceID == sourceID, record.planSHA256 == loaded.planSHA256 else {
                throw TractandaError("importJournal", "Record progress belongs to another source or plan.")
            }
            try record.progress.validate()
            state.records[sourceID] = record.progress
        }
        guard totalBytes <= plan.limits.maximumJournalBytes else {
            throw TractandaError("importLimits", "Retained import journal exceeds selected budget.")
        }
        state.refreshReport()
        try state.validate()
        header = loaded
        return state
    }

    /// Initial publication writes the immutable plan once. Header is published last, before
    /// the engine can issue any native request. A partial initialization is never a valid outbox.
    public func save(_ state: ImportJournalState) throws {
        try state.validate()
        if exists {
            if header == nil { _ = try load() }
            guard let header, header.planSHA256 == state.planSHA256, header.binding == state.binding else {
                throw TractandaError(
                    "importJournal", "An initialized journal cannot change its plan or destination.")
            }
            // Compatibility facade for explicit callers. The engine's hot path uses saveRecord.
            for sourceID in state.plan.records.map(\.sourceID) {
                try saveRecord(sourceID: sourceID, progress: state.records[sourceID]!)
            }
            return
        }
        let existing = try ImportSourceFiles(
            root: directory,
            limits: ImportLimits(maximumRecords: 2, maximumOriginalBytes: Int64(maximumBytes))
        ).list()
        guard existing == [".import.lock"] else {
            throw TractandaError(
                "importJournal", "Partially initialized journal requires explicit reconciliation.")
        }
        selectedIDs = Set(state.records.keys)
        selectedMaximumBytes = state.plan.limits.maximumJournalBytes
        let context = Header(
            planSHA256: state.planSHA256, binding: state.binding,
            diagnostics: state.report.diagnostics,
            unselectedOutcomes: state.report.outcomes.filter { !selectedIDs.contains($0.sourceID) })
        let planData = try JSON.encode(state.plan)
        // Preflight total retained bytes and one atomic replacement before any publication.
        let records = try state.plan.records.map { record -> (String, Data) in
            (
                recordName(record.sourceID),
                try JSON.encode(
                    RecordFile(
                        sourceID: record.sourceID, planSHA256: state.planSHA256,
                        progress: state.records[record.sourceID]!))
            )
        }
        let headerData = try JSON.encode(context)
        let sum = records.reduce(planData.count + headerData.count) { $0 + $1.1.count }
        guard sum <= min(maximumBytes, state.plan.limits.maximumJournalBytes) else {
            throw TractandaError("importLimits", "Initial import outbox exceeds its aggregate byte budget.")
        }
        try writeFile(planData, name: "plan.json", selectedMaximum: state.plan.limits.maximumJournalBytes)
        planWritesForTesting += 1
        for (name, data) in records {
            try writeFile(data, name: name, selectedMaximum: state.plan.limits.maximumJournalBytes)
            recordWritesForTesting += 1
        }
        try writeFile(headerData, name: "state.json", selectedMaximum: state.plan.limits.maximumJournalBytes)
        header = context
    }

    /// One changed record is persisted before its next native effect; no plan/other-record bytes
    /// are serialized, hashed or rewritten here. No aggregate report is written per phase/chunk.
    public func saveRecord(sourceID: String, progress: ImportRecordProgress) throws {
        if header == nil { _ = try load() }
        guard let header, selectedIDs.contains(sourceID) else {
            throw TractandaError("importJournal", "Progress source is not in this immutable plan.")
        }
        try progress.validate()
        let data = try JSON.encode(
            RecordFile(sourceID: sourceID, planSHA256: header.planSHA256, progress: progress))
        try writeFile(data, name: recordName(sourceID), selectedMaximum: selectedMaximumBytes ?? maximumBytes)
        recordWritesForTesting += 1
    }

    private func recordName(_ sourceID: String) -> String {
        "record-" + ImportHash.bytes(Data(sourceID.utf8)) + ".json"
    }
    /// One inventory on reopen accounts for every retained byte. A recognized atomic staging
    /// file was never a published intent, so with the exclusive lease it can be retired safely.
    /// Unexpected files are never ignored or removed. No inventory runs per progress update.
    private func inspectRetainedFiles(maximum: Int) throws {
        let expected = Set(selectedIDs.map(recordName)).union(["state.json", "plan.json", ".import.lock"])
        let duplicate = dup(directoryFD)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { _ = close(duplicate) }
            throw Self.failure("Cannot inventory retained journal components.")
        }
        defer { _ = closedir(stream) }
        rewinddir(stream)
        var count = 0
        var bytes = 0
        var staged: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Self.failure("Cannot finish retained journal inventory.") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            count += 1
            var metadata = stat()
            guard count <= expected.count + 16,
                fstatat(directoryFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == getuid(),
                metadata.st_mode & 0o777 == 0o600, metadata.st_nlink == 1,
                metadata.st_size >= 0, metadata.st_size <= maximum,
                bytes <= maximum - Int(metadata.st_size)
            else {
                throw TractandaError("importJournal", "Unsafe or over-budget retained journal inventory.")
            }
            bytes += Int(metadata.st_size)
            if !expected.contains(name) {
                let prefix = ".import-state-"
                guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
                else {
                    throw TractandaError(
                        "importJournal", "Unexpected retained journal component requires reconciliation.")
                }
                staged.append(name)
            } else if name == ".import.lock", metadata.st_size != 0 {
                throw TractandaError("importJournal", "Journal lease file must not contain payload bytes.")
            }
        }
        for name in staged {
            guard unlinkat(directoryFD, name, 0) == 0 else {
                throw Self.failure("Cannot retire unpublished journal staging.")
            }
        }
        if !staged.isEmpty, fsync(directoryFD) != 0 {
            throw Self.failure("Cannot synchronize retired journal staging.")
        }
    }
    private func readFile(_ name: String) throws -> Data {
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure("Cannot read retained import journal component.") }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_mode & 0o777 == 0o600,
            metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= maximumBytes,
            totalBytes <= maximumBytes - Int(metadata.st_size)
        else { throw TractandaError("importJournal", "Unsafe or oversized import journal component.") }
        let expected = Int(metadata.st_size)
        var data = Data(count: expected)
        var offset = 0
        while offset < expected {
            let count = data.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress!.advanced(by: offset), expected - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Self.failure("Import journal changed while reading.") }
            offset += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == metadata.st_size,
            after.st_ino == metadata.st_ino, after.st_dev == metadata.st_dev
        else { throw TractandaError("importJournal", "Import journal changed while reading.") }
        fileBytes[name] = expected
        totalBytes += expected
        return data
    }
    private func writeFile(_ data: Data, name: String, selectedMaximum: Int) throws {
        let limit = min(maximumBytes, selectedMaximum)
        guard data.count <= limit, totalBytes <= limit - data.count else {
            throw TractandaError(
                "importLimits",
                "Import outbox including its atomic staging file exceeds the aggregate byte budget.")
        }
        let previous = fileBytes[name] ?? 0
        var current = stat()
        let status = fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW)
        guard
            (previous == 0 && status < 0 && errno == ENOENT)
                || (previous > 0 && status == 0 && current.st_uid == getuid() && current.st_size == previous
                    && current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && current.st_mode & 0o777 == 0o600
                    && current.st_nlink == 1)
        else {
            throw TractandaError("importJournal", "Retained journal component changed outside its writer.")
        }
        var capacity = statvfs()
        guard fstatvfs(directoryFD, &capacity) == 0 else {
            throw Self.failure("Cannot inspect journal free space.")
        }
        let available = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
        let reserve = UInt64(minimumFreeBytes).addingReportingOverflow(UInt64(data.count))
        guard !available.overflow, !reserve.overflow, available.partialValue >= reserve.partialValue else {
            throw TractandaError("importCapacity", "Import journal would cross its free-space reserve.")
        }
        let temporary = ".import-state-" + UUID().uuidString
        let descriptor = openat(
            directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.failure("Cannot stage exact import intent.") }
        defer {
            _ = close(descriptor)
            _ = unlinkat(directoryFD, temporary, 0)
        }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Self.failure("Cannot persist exact import intent.") }
            offset += count
        }
        guard fsync(descriptor) == 0, renameat(directoryFD, temporary, directoryFD, name) == 0,
            fsync(directoryFD) == 0
        else { throw Self.failure("Cannot confirm exact import journal durability.") }
        totalBytes += data.count - previous
        fileBytes[name] = data.count
        bytesWrittenForTesting += Int64(data.count)
    }
    private static func failure(_ message: String) -> TractandaError {
        TractandaError("importJournal", message, osError: errno)
    }
}
