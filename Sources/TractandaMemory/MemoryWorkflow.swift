import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A portable locator, not a credential, authority grant, or copy of remembered content.
public struct MemoryWorkflowBinding: Codable, Equatable, Sendable {
    public var storeID: String
    public var profileItemID: String
    public var checkpointItemID: String
    public var categoryPath: [String]?
    public var viewID: String?
    public var captureCategoryIDs: [String]?
    public init(
        storeID: String, profileItemID: String, checkpointItemID: String,
        categoryPath: [String]? = nil, viewID: String? = nil, captureCategoryIDs: [String]? = nil
    ) {
        self.storeID = storeID
        self.profileItemID = profileItemID
        self.checkpointItemID = checkpointItemID
        self.categoryPath = categoryPath
        self.viewID = viewID
        self.captureCategoryIDs = captureCategoryIDs
    }
    public func validate() throws {
        guard !storeID.isEmpty, storeID.utf8.count <= 4096, !storeID.contains("\0"),
            profileItemID != checkpointItemID, !(viewID != nil && categoryPath != nil),
            (categoryPath?.count ?? 0) <= 32, (captureCategoryIDs?.count ?? 0) <= 32,
            Set(captureCategoryIDs ?? []).count == (captureCategoryIDs?.count ?? 0)
        else { throw TractandaError("memoryBinding", "Invalid or ambiguous memory binding.") }
        for id in [profileItemID, checkpointItemID] + (categoryPath ?? []) + (captureCategoryIDs ?? []) {
            try Identifier.validate(id)
        }
        if let viewID { try Identifier.validate(viewID) }
    }
}

public struct MemoryRecall: Codable, Sendable {
    public let profile: JMAPItemRecord
    public let checkpoint: JMAPItemRecord
    public let memories: [JMAPItemRecord]
    public let total: Int
    public let truncated: Bool
    public let skippedIncompleteImports: Int
    /// Observations are local to this caller and replica, not transferable checkpoints.
    public let itemState: String
    public let queryState: String?
    public let evaluatedAt: String?
}

public struct MemoryIntent: Codable, Sendable {
    public var schema = "tractanda.memory-intent.v1"
    public let binding: ImportBinding
    public let request: CommitRequest
    public let requestBytes: Data
    public init(binding: ImportBinding, request: CommitRequest) throws {
        self.binding = binding
        self.request = request
        requestBytes = try JSON.encode(request)
        try validate()
    }
    public func validate() throws {
        guard schema == "tractanda.memory-intent.v1", try JSON.encode(request) == requestBytes,
            requestBytes.count <= 1024 * 1024, !binding.storeID.isEmpty, !binding.principal.isEmpty,
            !binding.endpoint.isEmpty, !request.operationID.isEmpty,
            request.action == .create || request.action == .revise,
            request.fieldOperations == nil, request.unset.isEmpty,
            request.changes["permissions"] == nil,
            (request.action == .create && request.itemID == nil && request.expectedRevisionID == nil
                && request.classID == "Item")
                || (request.action == .revise && request.itemID != nil && request.expectedRevisionID != nil
                    && request.classID == nil)
        else { throw TractandaError("memoryIntent", "Invalid or changed exact memory intent.") }
    }
}

/// Explicit operations use ordinary native reads and commits under the authenticated account.
public final class MemoryWorkflow {
    private let client: ItemClient
    private let endpoint: String
    public init(client: ItemClient, endpoint: String) {
        self.client = client
        self.endpoint = endpoint
    }
    private func checkedBinding(_ binding: MemoryWorkflowBinding) throws -> ImportBinding {
        try binding.validate()
        let selected = try CoreImportTransport(client: client, endpoint: endpoint).binding()
        guard selected.storeID == binding.storeID else {
            throw TractandaError("memoryBinding", "Connected store differs from the configured store.")
        }
        return selected
    }
    private func state() throws -> String {
        try JSON.decode(
            JMAPItemGetResponse.self, client.call("TractandaItem/get", arguments: ["ids": [String]()])
        ).state
    }
    public func recall(
        _ binding: MemoryWorkflowBinding, limit: Int = 32,
        fields: [String] = [
            "subject", "body", "workingNotes", "referenceLabels", "collaborator", "source",
            "originalCreatedAt", "originalModifiedAt", "checkpoint", "project", "git", "artifacts",
            "okfType", "okfStatus", "okfStaleAfter", "okfDescription", "okfSources",
            "okfGeneratedClaim", "okfVerifiedClaims", "okfUsageWindow", "importLinks",
            "okfExecutionSupported", "okfExecuted", "okfAttestation",
            "importSchema", "importState", "importSourceID",
        ]
    )
        throws -> MemoryRecall
    {
        guard (0...62).contains(limit), (1...64).contains(fields.count), Set(fields).count == fields.count,
            !fields.contains("requestIdentity"), !fields.contains("revisionAncestry"),
            fields.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
        else { throw TractandaError("memoryLimits", "Invalid recall limit or field selection.") }
        // These fields are required for safe interpretation even with a custom selection.
        let selectedFields = Array(Set(fields).union(["importSchema", "importState"])).sorted()
        guard selectedFields.count <= 64 else {
            throw TractandaError("memoryLimits", "Recall field selection leaves no room for import state.")
        }
        _ = try checkedBinding(binding)
        let initialState = try state()
        let at = Timestamp.now()
        var criteria: [String: Any] = ["at": at, "limit": limit, "position": 0]
        if let viewID = binding.viewID { criteria["viewID"] = viewID }
        if let path = binding.categoryPath { criteria["categoryPath"] = path }
        let pageData = try client.query(criteria: criteria)
        guard let page = try JSONSerialization.jsonObject(with: pageData) as? [String: Any],
            let ids = page["ids"] as? [String], let total = page["total"] as? Int,
            let queryState = page["queryState"] as? String, !queryState.isEmpty,
            let evaluatedAt = page["evaluatedAt"] as? String,
            page["completeness"] as? String != "unresolvedItems", total >= ids.count,
            ids.count <= limit, Set(ids).count == ids.count
        else { throw TractandaError("memoryRecall", "Query scope is incomplete or invalid.") }
        let wanted =
            [binding.profileItemID, binding.checkpointItemID]
            + ids.filter { $0 != binding.profileItemID && $0 != binding.checkpointItemID }
        let get = try JSON.decode(
            JMAPItemGetResponse.self,
            client.call(
                "TractandaItem/getBounded",
                arguments: [
                    "ids": wanted, "fieldProperties": selectedFields, "maxBytes": 524_288,
                ]))
        guard get.state == initialState, get.notFound.isEmpty,
            get.list.allSatisfy({ $0.resolution?.status == nil || $0.resolution?.status == .ready }),
            get.list.allSatisfy({ $0.revisionID != nil && $0.fields != nil }),
            Set(get.list.map(\.id)).count == get.list.count,
            Set(get.list.map(\.id)).isSubset(of: Set(wanted)),
            Set(wanted).subtracting(get.list.map(\.id)) == Set(get.remainingIDs + get.oversizedIDs),
            Set(get.remainingIDs).isDisjoint(with: Set(get.oversizedIDs)),
            get.accountID == binding.storeID, try state() == initialState
        else {
            throw TractandaError(
                "memoryRecall", "Recall changed or contains inaccessible or unresolved Items.")
        }
        let byID = Dictionary(uniqueKeysWithValues: get.list.map { ($0.id, $0) })
        guard let profile = byID[binding.profileItemID], let checkpoint = byID[binding.checkpointItemID],
            profile.fields?["isDeleted"] != .boolean(true), checkpoint.fields?["isDeleted"] != .boolean(true)
        else {
            throw TractandaError("memoryRecall", "Profile or checkpoint is missing, unresolved or oversized.")
        }
        func isIncompleteImport(_ item: JMAPItemRecord) -> Bool {
            item.fields?["importSchema"] == .text(ImportFields.schema)
                && item.fields?["importState"] != .text("complete")
        }
        guard !isIncompleteImport(profile), !isIncompleteImport(checkpoint) else {
            throw TractandaError("memoryRecall", "Profile or checkpoint is an incomplete import.")
        }
        let selected = ids.filter { $0 != binding.profileItemID && $0 != binding.checkpointItemID }
            .compactMap { byID[$0] }
        let skipped = selected.filter(isIncompleteImport).count
        let memories = selected.filter { !isIncompleteImport($0) }
        return MemoryRecall(
            profile: profile, checkpoint: checkpoint, memories: memories, total: total,
            truncated: total > ids.count || !get.remainingIDs.isEmpty || !get.oversizedIDs.isEmpty
                || skipped > 0,
            skippedIncompleteImports: skipped,
            itemState: initialState, queryState: queryState, evaluatedAt: evaluatedAt)
    }
    public func remember(
        _ binding: MemoryWorkflowBinding, fields: [String: ItemValue], journal: MemoryIntentJournal
    )
        throws -> MutationReceipt
    {
        let destination = try checkedBinding(binding)
        try validateChanges(fields)
        var changes = fields
        guard changes["collaborator"] == nil else {
            throw TractandaError("memoryIntent", "Collaborator is bound by configuration.")
        }
        changes["collaborator"] = .reference(ItemReference(binding.profileItemID))
        var categories = changes["categoryOverrides"]?.map ?? [:]
        if changes["categoryOverrides"] != nil && changes["categoryOverrides"]?.map == nil {
            throw TractandaError("memoryIntent", "categoryOverrides must be an object.")
        }
        for id in binding.captureCategoryIDs ?? [] where categories[id] == nil {
            let result = try JSON.decode(
                JMAPItemGetResponse.self,
                client.call(
                    "TractandaItem/get",
                    arguments: [
                        "ids": [id], "fieldProperties": ["selection"],
                    ]))
            guard result.notFound.isEmpty, result.list.count == 1,
                result.list[0].resolution?.status == nil || result.list[0].resolution?.status == .ready,
                result.list[0].fields?["isDeleted"] != .boolean(true),
                result.list[0].fields?["selection"]?.map != nil
            else {
                throw TractandaError(
                    "memoryCategory", "Capture category is missing, deleted, unreadable or unresolved.")
            }
            categories[id] = .text("include")
        }
        if !categories.isEmpty { changes["categoryOverrides"] = .object(categories) }
        let request = CommitRequest(classID: "Item", changes: changes, operationID: Identifier.make())
        return try execute(MemoryIntent(binding: destination, request: request), journal: journal)
    }
    public func checkpoint(
        _ binding: MemoryWorkflowBinding, expectedRevisionID: String,
        fields: [String: ItemValue], journal: MemoryIntentJournal
    ) throws -> MutationReceipt {
        let destination = try checkedBinding(binding)
        try Identifier.validate(expectedRevisionID)
        try validateChanges(fields)
        let request = CommitRequest(
            action: .revise, itemID: binding.checkpointItemID,
            expectedRevisionID: expectedRevisionID, changes: fields, operationID: Identifier.make())
        return try execute(MemoryIntent(binding: destination, request: request), journal: journal)
    }
    private func validateChanges(_ fields: [String: ItemValue]) throws {
        let forbidden: Set<String> = [
            "itemID", "revisionID", "classID", "schemaVersion", "createdAt", "modifiedAt", "actor",
            "operationID", "requestIdentity", "revisionAncestry", "supersedes", "permissions", "attachments",
            "isDeleted",
        ]
        guard !fields.isEmpty, fields.count <= 62, fields.keys.allSatisfy({ !forbidden.contains($0) }),
            try JSON.encode(fields).count <= 512 * 1024
        else {
            throw TractandaError(
                "memoryIntent", "Memory fields are empty, oversized, or contain protected metadata.")
        }
        for value in fields.values { try value.validate() }
    }
    private func execute(_ intent: MemoryIntent, journal: MemoryIntentJournal) throws -> MutationReceipt {
        try journal.create(intent)
        return try resume(journal: journal)
    }
    public func resume(journal: MemoryIntentJournal) throws -> MutationReceipt {
        let intent = try journal.intent()
        let selected = try CoreImportTransport(client: client, endpoint: endpoint).binding()
        guard selected == intent.binding else {
            throw TractandaError("memoryBinding", "Journal belongs to another store, principal or endpoint.")
        }
        if let receipt = try journal.receipt() { return receipt }
        let receipt = try client.commit(intent.request)
        guard receipt.operationID == intent.request.operationID else {
            throw TractandaError("memoryIntent", "Receipt differs from intent.")
        }
        let names = Array(Set(intent.request.changes.keys).union(["operationID"])).sorted()
        let verified = try JSON.decode(
            JMAPRevisionGetResponse.self,
            client.call(
                "TractandaRevision/get",
                arguments: [
                    "ids": [receipt.revisionID], "fieldProperties": names,
                ]))
        guard verified.notFound.isEmpty, verified.list.count == 1, let result = verified.list.first,
            result.id == receipt.revisionID, result.itemID == receipt.itemID,
            let values = result.fields, values["operationID"] == .text(intent.request.operationID),
            intent.request.changes.allSatisfy({ values[$0.key] == $0.value })
        else {
            throw TractandaError("memoryReadback", "Acknowledged revision does not match the exact intent.")
        }
        try journal.record(receipt, verifiedFields: values)
        return receipt
    }
}

/// Single-operation private outbox. The exact request is durable before any send.
public final class MemoryIntentJournal {
    private let directoryFD: Int32
    private let lockFD: Int32
    public init(directory: URL, create: Bool = false) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw TractandaError("memoryJournal", "Journal requires an absolute directory.")
        }
        if create && mkdir(directory.path, 0o700) != 0 {
            throw TractandaError("memoryJournal", "Journal directory must be new.")
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TractandaError("memoryJournal", "Cannot open journal directory.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            _ = close(fd)
            throw TractandaError("memoryJournal", "Journal directory must be private and owned.")
        }
        let lock = openat(fd, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var lockInfo = stat()
        guard lock >= 0, fstat(lock, &lockInfo) == 0, lockInfo.st_uid == getuid(),
            lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), lockInfo.st_mode & 0o777 == 0o600,
            lockInfo.st_nlink == 1, flock(lock, LOCK_EX | LOCK_NB) == 0
        else {
            if lock >= 0 { _ = close(lock) }
            _ = close(fd)
            throw TractandaError("memoryJournal", "Journal lease unavailable.")
        }
        directoryFD = fd
        lockFD = lock
    }
    deinit {
        _ = flock(lockFD, LOCK_UN)
        _ = close(lockFD)
        _ = close(directoryFD)
    }
    public func create(_ intent: MemoryIntent) throws {
        try intent.validate()
        guard try read("intent.json") == nil, try read("receipt.json") == nil else {
            throw TractandaError("memoryJournal", "Journal already contains an operation.")
        }
        try write("intent.json", data: JSON.encode(intent))
    }
    public func intent() throws -> MemoryIntent {
        guard let data = try read("intent.json") else {
            throw TractandaError("memoryJournal", "Journal has no intent.")
        }
        let intent = try JSON.decode(MemoryIntent.self, data)
        try intent.validate()
        return intent
    }
    private struct VerifiedReceipt: Codable {
        let receipt: MutationReceipt
        let itemID: String
        let revisionID: String
        let fields: [String: ItemValue]
    }
    private func validate(_ verified: VerifiedReceipt) throws {
        let expected = try intent().request
        let receipt = verified.receipt
        guard receipt.operationID == expected.operationID, verified.itemID == receipt.itemID,
            verified.revisionID == receipt.revisionID,
            verified.fields["itemID"] == .text(receipt.itemID),
            verified.fields["revisionID"] == .text(receipt.revisionID),
            verified.fields["operationID"] == .text(expected.operationID),
            expected.changes.allSatisfy({ verified.fields[$0.key] == $0.value }),
            expected.action == .create || receipt.itemID == expected.itemID
        else { throw TractandaError("memoryJournal", "Receipt or verified revision does not match intent.") }
    }
    public func receipt() throws -> MutationReceipt? {
        guard let data = try read("receipt.json") else { return nil }
        let verified = try JSON.decode(VerifiedReceipt.self, data)
        try validate(verified)
        return verified.receipt
    }
    public func record(_ receipt: MutationReceipt, verifiedFields: [String: ItemValue]) throws {
        guard try read("receipt.json") == nil else {
            throw TractandaError("memoryJournal", "Receipt is already saved.")
        }
        let verified = VerifiedReceipt(
            receipt: receipt, itemID: receipt.itemID,
            revisionID: receipt.revisionID, fields: verifiedFields)
        try validate(verified)
        try write("receipt.json", data: JSON.encode(verified))
    }
    private func read(_ name: String) throws -> Data? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw TractandaError("memoryJournal", "Cannot open journal record.") }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size > 0,
            info.st_size <= 2 * 1024 * 1024
        else { throw TractandaError("memoryJournal", "Unsafe or oversized journal record.") }
        var data = Data(count: Int(info.st_size))
        let size = data.count
        var offset = 0
        while offset < size {
            let count = data.withUnsafeMutableBytes {
                memoryJournalRead(fd, $0.baseAddress!.advanced(by: offset), size - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw TractandaError("memoryJournal", "Journal record changed while reading.")
            }
            offset += count
        }
        return data
    }
    private func write(_ name: String, data: Data) throws {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else {
            throw TractandaError("memoryJournal", "Journal record exceeds limit.")
        }
        let temporary = ".stage-" + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TractandaError("memoryJournal", "Cannot stage journal record.") }
        defer {
            _ = close(fd)
            _ = unlinkat(directoryFD, temporary, 0)
        }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                memoryJournalWrite(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw TractandaError("memoryJournal", "Cannot persist journal record.") }
            offset += count
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, name) == 0,
            fsync(directoryFD) == 0
        else { throw TractandaError("memoryJournal", "Cannot confirm journal durability.") }
    }
}
private func memoryJournalRead(_ fd: Int32, _ bytes: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
        Darwin.read(fd, bytes, count)
    #else
        Glibc.read(fd, bytes, count)
    #endif
}
private func memoryJournalWrite(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
        Darwin.write(fd, bytes, count)
    #else
        Glibc.write(fd, bytes, count)
    #endif
}
