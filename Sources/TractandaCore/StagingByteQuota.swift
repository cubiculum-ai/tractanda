import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Shared actual-byte budget for private recovery work, independent of filesystem reserve.
/// The ledger holds one counter per stage/intent, never one entry per document page.
/// Startup reconstructs it by streaming private filesystem metadata, without reading payloads.
final class StagingByteQuota: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int64
    private var groups: [String: Int64] = [:]
    static let uploadCheckpointReservation: Int64 = 16 * 1024
    private var uploads: Set<String> = []
    private var initialUploadBytes: [String: Int64] = [:]
    private var total: Int64 = 0
    private var derivedReservations: [String: Int64] = [:]
    private var jobs: Set<String> = []
    private var initialJobBytes: [String: Int64] = [:]
    private var copyGroups: [String: Set<String>] = [:]
    private var completedGroups: Set<String> = []
    init(
        root: URL, ownerUID: UInt32, maximumBytes: Int64,
        pendingUploads: [String: AttachmentUploadState] = [:]
    ) throws {
        self.maximumBytes = maximumBytes
        try restoreCopyBindings(root: root, ownerUID: ownerUID)
        try restoreJobBindings(root: root, ownerUID: ownerUID)
        for (id, upload) in pendingUploads {
            try retainUpload(id: id, recovering: true)
            let stage = ["attachments", ".staging", id + ".stage"]
            if upload.location == "published",
                (try? FileMetadata.read(at: stage.reduce(root) { $0.appendingPathComponent($1) })) == nil
            {
                let canonical = try AttachmentPayloadStore.payloadRelativePath(id).split(separator: "/").map(
                    String.init)
                try scan(
                    root: root, path: canonical, ownerUID: ownerUID, depth: 0,
                    accountingGroup: Self.group(stage))
            }
        }
        for prefix in [
            ["attachments", ".staging"], ["attachments", ".uploads"], ["documents", ".staging"], ["copies"],
            ["document-jobs"],
        ] {
            try scan(root: root, path: prefix, ownerUID: ownerUID, depth: 0)
        }
    }
    private func scan(root: URL, path: [String], ownerUID: UInt32, depth: Int, accountingGroup: String? = nil)
        throws
    {
        guard depth <= 32 else {
            throw TractandaError("unsafeAttachmentStore", "Private staging is too deep.")
        }
        if accountingGroup == nil, let group = Self.group(path), completedGroups.contains(group) { return }
        let url = path.reduce(root) { $0.appendingPathComponent($1) }
        let metadata: FileMetadata
        do { metadata = try FileMetadata.read(at: url) } catch FileMetadataError.posix(ENOENT) { return }
        guard metadata.uid == ownerUID, metadata.mode & 0o077 == 0 else {
            throw TractandaError(
                "unsafeAttachmentStore", "Private staging must be service-owned and private.")
        }
        if metadata.type == .directory {
            try POSIXDirectory.withEntries(at: url) { name in
                try self.scan(
                    root: root, path: path + [name], ownerUID: ownerUID, depth: depth + 1,
                    accountingGroup: accountingGroup)
                return true
            }
        } else {
            guard metadata.type == .regular, let bytes = Int64(exactly: metadata.size),
                let group = accountingGroup ?? Self.group(path)
            else {
                throw TractandaError("unsafeAttachmentStore", "Private staging contains an unsafe entry.")
            }
            try add(bytes, group: group, enforcingLimit: false)
        }
    }
    private func restoreCopyBindings(root: URL, ownerUID: UInt32) throws {
        let copies = root.appendingPathComponent("copies")
        do { _ = try FileMetadata.read(at: copies) } catch FileMetadataError.posix(ENOENT) { return }
        let files = DocumentContentFiles(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
        let documents = DocumentContentStore(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
        try POSIXDirectory.withEntries(at: copies) { key in
            let base = ["copies", key]
            guard
                let bytes = try files.readIfPresent(
                    path: base + ["intent.json"], maximumBytes: 16 * 1024 * 1024)
            else {
                // Failed intent writes may leave a private directory; its bytes remain counted.
                return true
            }
            let plan = try JSON.decode(AttachmentCopyPlan.self, bytes)
            try plan.validate()
            guard plan.key == key else {
                throw TractandaError("attachmentIntegrity", "Copy staging key changed.")
            }
            let completed = try files.readIfPresent(path: base + ["completed.json"], maximumBytes: 256)
            if let completed {
                guard completed == Data(key.utf8) else {
                    throw TractandaError("attachmentIntegrity", "Copy completion changed.")
                }
                self.completedGroups.insert(base.joined(separator: "/"))
            }
            for id in plan.targetIDs {
                let path = ["attachments", ".staging", id + ".stage"]
                if completed == nil {
                    self.pin(path: path, copyKey: key)
                    let stageURL = path.reduce(root) { $0.appendingPathComponent($1) }
                    if (try? FileMetadata.read(at: stageURL)) == nil {
                        let canonical = try AttachmentPayloadStore.payloadRelativePath(id).split(
                            separator: "/"
                        ).map(String.init)
                        try self.scan(
                            root: root, path: canonical, ownerUID: ownerUID, depth: 0,
                            accountingGroup: Self.group(path))
                    }
                }
            }
            for index in plan.documents.indices {
                guard
                    let data = try files.readIfPresent(
                        path: base + ["document-\(index).json"], maximumBytes: 64 * 1024)
                else { continue }
                let prepared = try JSON.decode(PreparedDocumentContent.self, data)
                guard prepared.stage.count == 3, prepared.stage.prefix(2) == ["documents", ".staging"],
                    UUID(uuidString: prepared.stage[2])?.version1Components != nil,
                    prepared.source == plan.documents[index].source
                else {
                    throw TractandaError("documentIntegrity", "Copy stage binding changed.")
                }
                let receiptPath = ["documents", ".staging", prepared.stage[2] + ".publication.json"]
                if completed != nil {
                    self.completedGroups.insert(receiptPath.joined(separator: "/"))
                } else {
                    self.pin(path: prepared.stage, copyKey: key)
                    self.pin(path: receiptPath, copyKey: key)
                    let stageURL = prepared.stage.reduce(root) { $0.appendingPathComponent($1) }
                    if (try? FileMetadata.read(at: stageURL)) == nil,
                        let receiptBytes = try files.readIfPresent(path: receiptPath, maximumBytes: 64 * 1024)
                    {
                        let receipt = try JSON.decode(DocumentPublicationReceipt.self, receiptBytes)
                        guard receipt.manifest.publicationID == prepared.stage[2],
                            receipt.manifest.source == prepared.source
                        else {
                            throw TractandaError("documentIntegrity", "Copy publication binding changed.")
                        }
                        try self.scan(
                            root: root, path: documents.directory(receipt.manifest.contentID),
                            ownerUID: ownerUID, depth: 0, accountingGroup: Self.group(prepared.stage))
                    }
                }
            }
            return true
        }
    }
    private func restoreJobBindings(root: URL, ownerUID: UInt32) throws {
        let files = DocumentContentFiles(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
        let documents = DocumentContentStore(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
        let records = try DocumentJobRecords(root: root, files: files).load()
        for record in records.values {
            let id = record.intent.jobID
            try retainJob(id: id, initialBytes: 0, recovering: true)
            if record.checkpoint.state == "completed" {
                completedGroups.insert(record.intent.stage.joined(separator: "/"))
                completedGroups.insert(
                    (record.intent.stage.prefix(2) + [id + ".publication.json"]).joined(separator: "/"))
                continue
            }
            pin(path: record.intent.stage, copyKey: "job:" + id)
            let receiptPath = ["documents", ".staging", id + ".publication.json"]
            pin(path: receiptPath, copyKey: "job:" + id)
            if let bytes = try files.readIfPresent(path: receiptPath, maximumBytes: 64 * 1024) {
                let receipt = try DocumentValue.strictDecode(DocumentPublicationReceipt.self, data: bytes)
                guard receipt.manifest.publicationID == id, receipt.manifest.source == record.intent.source,
                    receipt.manifest.identity == record.intent.identity
                else { throw TractandaError("documentIntegrity", "Job publication binding changed.") }
                if (try? FileMetadata.read(
                    at: record.intent.stage.reduce(root) { $0.appendingPathComponent($1) })) == nil
                {
                    try scan(
                        root: root, path: documents.directory(receipt.manifest.contentID), ownerUID: ownerUID,
                        depth: 0, accountingGroup: Self.group(record.intent.stage))
                }
            }
        }
    }
    func retainJob(id: String, initialBytes: Int64, recovering: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !jobs.contains(id) else { return }
        guard jobs.count < 64, recovering || (1...Self.uploadCheckpointReservation).contains(initialBytes)
        else {
            throw TractandaError("resourceLimit", "Durable job slots or metadata window are full.")
        }
        if !recovering {
            try check(initialBytes + Self.uploadCheckpointReservation)
            initialJobBytes[id] = initialBytes
        }
        jobs.insert(id)
        copyGroups["job:" + id] = [
            "documents/.staging/" + id, "documents/.staging/" + id + ".publication.json",
        ]
    }
    func chargeJobCheckpoint(_ bytes: Int, path: [String], id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard jobs.contains(id), bytes <= Self.uploadCheckpointReservation, let group = Self.group(path)
        else {
            throw TractandaError("resourceLimit", "Job metadata exceeds reserved replacement headroom.")
        }
        if let initial = initialJobBytes[id] {
            guard Int64(bytes) <= initial else {
                throw TractandaError("resourceLimit", "Initial job metadata exceeds admission.")
            }
        }
        try add(Int64(bytes), group: group, enforcingLimit: false)
    }
    func jobCheckpointReplaced(oldBytes: Int, path: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard path.count == 3, let group = Self.group(path) else { return }
        initialJobBytes.removeValue(forKey: path[1])
        let amount = min(Int64(oldBytes), groups[group] ?? 0)
        total -= amount
        groups[group] = (groups[group] ?? 0) - amount
    }
    func finishJob(id: String) {
        complete(copyKey: "job:" + id)
    }
    func releaseJobAdmission(id: String) {
        finishJob(id: id)
        lock.lock()
        defer { lock.unlock() }
        jobs.remove(id)
        initialJobBytes.removeValue(forKey: id)
        let prefixes = ["document-jobs/" + id + "/sessions/", "document-jobs/" + id + "/corpus/"]
        for group in groups.keys.filter({ key in prefixes.contains { key.hasPrefix($0) } }) {
            total -= groups.removeValue(forKey: group) ?? 0
        }
    }
    func pin(path: [String], copyKey: String) {
        guard let group = Self.group(path) else { return }
        lock.lock()
        defer { lock.unlock() }
        copyGroups[copyKey, default: []].insert(group)
    }
    func complete(copyKey: String) {
        lock.lock()
        defer { lock.unlock() }
        for group in copyGroups.removeValue(forKey: copyKey) ?? [] {
            total -= groups.removeValue(forKey: group) ?? 0
        }
        total -= groups.removeValue(forKey: "copies/" + copyKey) ?? 0
    }
    static func group(_ path: [String]) -> String? {
        if path.count >= 3, path[0] == "attachments", [".staging", ".uploads"].contains(path[1]) {
            return path.prefix(3).joined(separator: "/")
        }
        if path.count >= 3, path[0] == "documents", path[1] == ".staging" {
            return path.prefix(3).joined(separator: "/")
        }
        if path.count >= 4, path[0] == "document-jobs", ["sessions", "corpus"].contains(path[2]) {
            return path.prefix(4).joined(separator: "/")
        }
        if path.count >= 3, ["copies", "document-jobs"].contains(path[0]) {
            return path.prefix(2).joined(separator: "/")
        }
        return nil
    }
    func require(additionalBytes: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        try check(additionalBytes)
    }
    /// Every kind of retained checkpoint spends independent replacement and initial headroom.
    /// Caller holds lock; admission and ordinary data charges share this exact aggregate.
    private func reservedBytes() throws -> Int64 {
        let slots = Int64(uploads.count).addingReportingOverflow(Int64(jobs.count))
        let base = slots.partialValue.multipliedReportingOverflow(by: Self.uploadCheckpointReservation)
        guard !slots.overflow, !base.overflow else {
            throw TractandaError("resourceLimit", "Private checkpoint reservation count overflowed.")
        }
        var reserved = base.partialValue
        for holds in [initialUploadBytes, initialJobBytes, derivedReservations] {
            for bytes in holds.values {
                let sum = reserved.addingReportingOverflow(bytes)
                guard bytes >= 0, !sum.overflow else {
                    throw TractandaError(
                        "resourceLimit", "Private initial checkpoint reservations overflowed.")
                }
                reserved = sum.partialValue
            }
        }
        return reserved
    }
    private func check(_ additional: Int64) throws {
        let used = total.addingReportingOverflow(try reservedBytes())
        guard !used.overflow, additional >= 0, additional <= maximumBytes,
            used.partialValue <= maximumBytes - additional
        else {
            throw TractandaError(
                "resourceLimit", "Private recovery work exceeds the shared actual staging-byte quota.")
        }
    }
    private func add(_ bytes: Int64, group: String, enforcingLimit: Bool) throws {
        if enforcingLimit { try check(bytes) }
        let sum = total.addingReportingOverflow(bytes)
        let groupSum = (groups[group] ?? 0).addingReportingOverflow(bytes)
        guard bytes >= 0, !sum.overflow, !groupSum.overflow else {
            throw TractandaError("resourceLimit", "Private staging byte count overflowed.")
        }
        total = sum.partialValue
        groups[group] = groupSum.partialValue
    }
    func retainUpload(id: String, initialCheckpointBytes: Int64 = 0, recovering: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !uploads.contains(id) else { return }
        guard uploads.count < 64 else {
            throw TractandaError("resourceLimit", "Upload checkpoint slots are full.")
        }
        let stage = "attachments/.staging/" + id + ".stage"
        if !recovering, groups[stage] != nil || copyGroups.values.contains(where: { $0.contains(stage) }) {
            throw TractandaError("identifierCollision", "Original recovery identity is already retained.")
        }
        if !recovering {
            guard (1...Self.uploadCheckpointReservation).contains(initialCheckpointBytes) else {
                throw TractandaError(
                    "resourceLimit", "Initial upload checkpoint must fit its bounded window.")
            }
            try check(Self.uploadCheckpointReservation + initialCheckpointBytes)
            initialUploadBytes[id] = initialCheckpointBytes
        }
        uploads.insert(id)
        copyGroups["upload:" + id] = [
            "attachments/.staging/" + id + ".stage", "attachments/.uploads/" + id + ".json",
        ]
    }
    /// One bounded atomic replacement spends its already reserved checkpoint headroom.
    /// This remains available for tombstones when an operator lowers quota below retained work.
    func chargeCheckpoint(_ bytes: Int, temporaryPath: [String], uploadID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard uploads.contains(uploadID), bytes <= Self.uploadCheckpointReservation,
            let group = Self.group(temporaryPath)
        else {
            throw TractandaError(
                "resourceLimit", "Upload checkpoint exceeds its reserved bookkeeping window.")
        }
        if let initial = initialUploadBytes[uploadID] {
            guard Int64(bytes) <= initial else {
                throw TractandaError(
                    "resourceLimit", "Initial checkpoint exceeded its atomic admission budget.")
            }
        }
        try add(Int64(bytes), group: group, enforcingLimit: false)
    }
    func checkpointReplaced(temporaryPath: [String], uploadID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let temporary = Self.group(temporaryPath) else { return }
        initialUploadBytes.removeValue(forKey: uploadID)
        let destination = "attachments/.uploads/" + uploadID + ".json"
        let size = groups.removeValue(forKey: temporary) ?? 0
        total -= groups.removeValue(forKey: destination) ?? 0
        groups[destination] = size
    }
    func completeUpload(id: String) {
        lock.lock()
        defer { lock.unlock() }
        for group in copyGroups.removeValue(forKey: "upload:" + id) ?? [] {
            total -= groups.removeValue(forKey: group) ?? 0
        }
        uploads.remove(id)
        initialUploadBytes.removeValue(forKey: id)
    }
    func uploadUsage(id: String) -> AttachmentStagingUsage {
        lock.lock()
        defer { lock.unlock() }
        return AttachmentStagingUsage(
            originalBytes: groups["attachments/.staging/" + id + ".stage"] ?? 0,
            checkpointBytes: groups["attachments/.uploads/" + id + ".json"] ?? 0,
            bookkeepingReservedBytes: uploads.contains(id) ? Self.uploadCheckpointReservation : 0,
            maximumStagedBytes: maximumBytes)
    }
    func charge(_ bytes: Int, path: [String]) throws {
        guard let group = Self.group(path) else { return }
        lock.lock()
        defer { lock.unlock() }
        try add(Int64(bytes), group: group, enforcingLimit: true)
    }
    func refund(_ bytes: Int, path: [String]) {
        guard let group = Self.group(path) else { return }
        lock.lock()
        defer { lock.unlock() }
        let amount = min(Int64(bytes), groups[group] ?? 0)
        total -= amount
        groups[group] = (groups[group] ?? 0) - amount
    }
    /// Called only after the filesystem publication/removal transition has been synchronized.
    func release(path: [String]) {
        guard let group = Self.group(path) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !copyGroups.values.contains(where: { $0.contains(group) }) else { return }
        total -= groups.removeValue(forKey: group) ?? 0
    }
    var usedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

extension StagingByteQuota {
    /// Reserve before a bounded write; this transient estimate is never called physical allocation.
    func reserveDerived(workID: String, estimatedAdditionalBytes: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard estimatedAdditionalBytes >= 0 else {
            throw TractandaError("resourceLimit", "Invalid derived-work reservation.")
        }
        let prior = derivedReservations[workID] ?? 0
        let hold = max(prior, estimatedAdditionalBytes)
        try check(hold - prior)
        derivedReservations[workID] = hold
    }
    /// Absolute normative encoded payload/metadata is committed in the Index ledger first.
    /// Observed bytes remain charged even when a post-commit budget check rejects the operation.
    func observeDerived(workID: String, retainedEncodedBytes: Int64, recovering: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard retainedEncodedBytes >= 0 else {
            throw TractandaError("resourceLimit", "Invalid retained derived-work charge.")
        }
        let group = "index-corpus/" + workID
        let prior = groups[group] ?? 0
        let rest = total.subtractingReportingOverflow(prior)
        let observed = rest.partialValue.addingReportingOverflow(retainedEncodedBytes)
        guard !rest.overflow, !observed.overflow, observed.partialValue >= 0 else {
            throw TractandaError("resourceLimit", "Derived recovery accounting overflowed.")
        }
        total = observed.partialValue
        if retainedEncodedBytes == 0 {
            groups.removeValue(forKey: group)
        } else {
            groups[group] = retainedEncodedBytes
        }
        derivedReservations.removeValue(forKey: workID)
        if !recovering { try check(0) }
    }
    /// Compact charged metadata cursor; never traverses document units or assembles all work IDs.
    func chargedCorpusWorkPage(after: String? = nil, limit: Int = 64) throws -> [String] {
        guard (1...64).contains(limit) else {
            throw TractandaError("invalidArguments", "Use a bounded charged-work cursor.")
        }
        lock.lock()
        defer { lock.unlock() }
        var page: [String] = []
        for key in groups.keys where key.hasPrefix("index-corpus/") {
            let id = String(key.dropFirst("index-corpus/".count))
            guard after.map({ id > $0 }) ?? true else { continue }
            let offset = page.firstIndex(where: { $0 > id }) ?? page.count
            if offset < limit {
                page.insert(id, at: offset)
                if page.count > limit { page.removeLast() }
            }
        }
        return page
    }
    /// A confirmed rollback has no new encoded rows; caller must prove it before clearing a hold.
    func releaseDerivedReservation(workID: String) {
        lock.lock()
        derivedReservations.removeValue(forKey: workID)
        lock.unlock()
    }
}

extension StagingByteQuota {
    func observePrivateCorpus(path: [String], reservationID: String, encodedBytes: Int64) throws {
        guard let group = Self.group(path),
            (path.count == 4 && path[0] == "document-jobs" && path[2] == "corpus")
                || (path.count == 3 && path[0] == "documents" && path[1] == ".staging"
                    && path[2].hasPrefix("corpus-"))
        else {
            throw TractandaError("documentIntegrity", "Invalid owned corpus staging group.")
        }
        lock.lock()
        defer { lock.unlock() }
        guard encodedBytes >= 0 else { throw TractandaError("resourceLimit", "Invalid spool byte count.") }
        let old = groups[group] ?? 0
        let rest = total.subtractingReportingOverflow(old)
        let observed = rest.partialValue.addingReportingOverflow(encodedBytes)
        guard !rest.overflow, !observed.overflow else {
            throw TractandaError("resourceLimit", "Spool recovery accounting overflowed.")
        }
        total = observed.partialValue
        groups[group] = encodedBytes
        derivedReservations.removeValue(forKey: reservationID)
        try check(0)
    }
}

extension StagingByteQuota {
    func releaseDerivedNamespace(prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        for group in groups.keys.filter({ $0.hasPrefix("index-corpus/" + prefix) }) {
            total -= groups.removeValue(forKey: group) ?? 0
        }
        for key in derivedReservations.keys.filter({ $0.hasPrefix(prefix) }) {
            derivedReservations.removeValue(forKey: key)
        }
    }
}

extension StagingByteQuota {
    func corpusCharge(_ id: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return groups["index-corpus/" + id] ?? 0
    }
}
