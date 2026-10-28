import Crypto
import Foundation
import TractandaClient

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// The public Session and HTTP body admission use the same limits. Actual bytes, not a declared
/// Content-Length, spend quota. Completed unreferenced stages expire after at least one hour;
/// quota pressure may evict the oldest completed stages earlier. Active streams have no age limit.
public struct JMAPBlobLimits: Sendable {
    public let maxSizeUpload: Int64
    public let maxConcurrentUpload: Int
    public let maximumStagedBytesPerUser: Int64
    public let minimumFreeBytes: Int64
    public init(
        maxSizeUpload: Int64, maxConcurrentUpload: Int = 8,
        maximumStagedBytesPerUser: Int64 = 1024 * 1024 * 1024,
        minimumFreeBytes: Int64 = 1024 * 1024 * 1024
    ) throws {
        guard maxSizeUpload >= 0, maxSizeUpload <= 9_007_199_254_740_991,
            maxSizeUpload <= AttachmentDescriptor.maximumPayloadBytes,
            (1...8).contains(maxConcurrentUpload), maximumStagedBytesPerUser > 0, minimumFreeBytes >= 0
        else { throw TractandaError("invalidArguments", "Invalid JMAP blob limits.") }
        self.maxSizeUpload = maxSizeUpload
        self.maxConcurrentUpload = maxConcurrentUpload
        self.maximumStagedBytesPerUser = maximumStagedBytesPerUser
        self.minimumFreeBytes = minimumFreeBytes
    }
}

public struct JMAPBlobReceipt: Codable, Sendable, Equatable {
    public let accountId: String
    public let blobId: String
    public let type: String
    public let size: Int64
    public var value: JMAPValue {
        .object([
            .init("accountId", .string(accountId)), .init("blobId", .string(blobId)),
            .init("type", .string(type)), .init("size", .number(try! JMAPNumber(String(size)))),
        ])
    }
}
public struct JMAPBlobUploadHandle: Sendable {
    public let uploadID: String
    public let chunkBytes: Int
}
public struct JMAPBlobDownloadHandle: Sendable {
    public let downloadID: String
    public let blobID: String
    public let mediaType: String
    public let size: Int64
    /// Verification and bounded reads run off the Store/event-loop queues. The caller must freshly
    /// authorize the handle before each read and must verify it before sending response headers.
    public let source: JMAPBlobPinnedSource
}
public struct JMAPAttachBlobRequest: Sendable {
    public let accountID: String
    public let itemID: String
    public let expectedRevisionID: String
    public let blobID: String
    public let filename: String
    public let mediaType: String
    public let operationID: String
    public init(
        accountID: String, itemID: String, expectedRevisionID: String, blobID: String,
        filename: String, mediaType: String, operationID: String
    ) {
        self.accountID = accountID
        self.itemID = itemID
        self.expectedRevisionID = expectedRevisionID
        self.blobID = blobID
        self.filename = filename
        self.mediaType = mediaType
        self.operationID = operationID
    }
}

/// Private operational upload receipts. These are never accepted Item content or authority history.
/// The sole Store executor owns this object; no independent writer or content database is opened.
final class JMAPBlobStore {
    struct Intent: Codable {
        let id: String
        let accountID: String
        let uid: UInt32
        let principalName: String
        let mediaType: String
        let declaredSize: Int64?
        let createdAt: Date
    }
    struct Completion: Codable {
        let receipt: JMAPBlobReceipt
        let completedAt: Date
    }
    struct Stage {
        let intent: Intent
        let limits: JMAPBlobLimits?
        var count: Int64
        var hash: SHA256
        var completion: Completion?
    }
    struct Download {
        let uid: UInt32
        let principalName: String
        let itemID: String?
        let revisionID: String?
        let attachmentID: String?
        let stageID: String?
        let handle: JMAPBlobDownloadHandle
    }
    let files: DocumentContentFiles
    let payloads: AttachmentPayloadStore
    let quota: StagingByteQuota
    var stages: [String: Stage] = [:]
    var downloads: [String: Download] = [:]
    var clock: () -> Date = Date.init
    init(
        root: URL, ownerUID: UInt32, payloads: AttachmentPayloadStore, quota: StagingByteQuota,
        minimumFreeBytes: Int64, availableBytes: (@Sendable () throws -> UInt64)?
    ) throws {
        self.payloads = payloads
        self.quota = quota
        files = DocumentContentFiles(
            root: root, ownerUID: ownerUID, minimumFreeBytes: minimumFreeBytes,
            availableBytes: availableBytes, stagingQuota: quota)
        try files.withDirectoryEntries(path: ["jmap-blobs"]) { id in
            try Identifier.validate(id)
            let prefix = ["jmap-blobs", id]
            guard let raw = try self.files.readIfPresent(path: prefix + ["intent.json"], maximumBytes: 4096)
            else {
                // Interrupted intent publication is unaccepted operational debris.
                try self.files.removeJMAPBlobStage(id)
                return true
            }
            let intent = try JSON.decode(Intent.self, raw)
            guard intent.id == id, !intent.principalName.isEmpty else {
                throw TractandaError("unsafeAttachmentStore", "Blob stage identity differs.")
            }
            guard
                let complete = try self.files.readIfPresent(
                    path: prefix + ["complete.json"], maximumBytes: 4096)
            else {
                try self.discardPayload(id)
                try self.files.removeJMAPBlobStage(id)
                return true
            }
            let completion = try JSON.decode(Completion.self, complete)
            try Self.validateBlobID(completion.receipt.blobId)
            guard completion.receipt.accountId == intent.accountID,
                completion.receipt.type == intent.mediaType,
                completion.receipt.size >= 0,
                completion.receipt.size <= AttachmentDescriptor.maximumPayloadBytes,
                try self.payloads.stagedSize(id: id) == completion.receipt.size
            else {
                throw TractandaError("attachmentIntegrity", "Completed blob stage differs from its receipt.")
            }
            self.stages[id] = Stage(
                intent: intent, limits: nil, count: completion.receipt.size,
                hash: SHA256(), completion: completion)
            guard self.stages.count <= 4096 else {
                throw TractandaError("resourceLimit", "Too many retained blob stages.")
            }
            return true
        }
        try expire()
    }
    static func validateBlobID(_ value: String) throws {
        // Unknown opaque identifiers are not found, including valid non-digest JMAP Id strings.
        guard value.utf8.count == 64,
            value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw TractandaError("notFound", "Blob is unavailable.") }
    }
    static func validateMediaType(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 255,
            value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }), value.contains("/")
        else { throw TractandaError("invalidArguments", "Supply a bounded printable media type.") }
    }
    func requireOwner(_ stage: Stage, _ principal: AccountIdentity) throws {
        guard stage.intent.uid == principal.uid, stage.intent.principalName == principal.name else {
            throw TractandaError("notFound", "Blob is unavailable.")
        }
    }
    func expire() throws {
        let cutoff = clock().addingTimeInterval(-3600)
        for (id, stage) in stages where stage.completion.map({ $0.completedAt <= cutoff }) == true {
            try discard(id)
        }
    }
    private func discardPayload(_ id: String) throws {
        do { try payloads.discardStaging(id: id) } catch let error as TractandaError
            where error.osError == ENOENT
        {}
    }
    func discard(_ id: String) throws {
        try discardPayload(id)
        try files.removeJMAPBlobStage(id)
        stages.removeValue(forKey: id)
    }
    func makeRoom(bytes: Int64, principal: AccountIdentity, limits: JMAPBlobLimits) throws {
        func userBytes() -> Int64 {
            stages.values.filter {
                $0.intent.uid == principal.uid && $0.intent.principalName == principal.name
            }.reduce(0) { $0 + $1.count + 8192 }
        }
        let completed = stages.filter { $0.value.completion != nil }.sorted {
            $0.value.completion!.completedAt == $1.value.completion!.completedAt
                ? $0.key < $1.key : $0.value.completion!.completedAt < $1.value.completion!.completedAt
        }
        for (id, stage) in completed {
            let perUser = userBytes() > limits.maximumStagedBytesPerUser - bytes
            let global = (try? quota.require(additionalBytes: bytes)) == nil
            let countFull = stages.count >= 4096
            if !perUser && !global && !countFull { break }
            // Per-user pressure can evict only that uploader's data. Global pressure is oldest-first.
            if perUser && !global && !countFull
                && (stage.intent.uid != principal.uid || stage.intent.principalName != principal.name)
            {
                continue
            }
            try discard(id)
        }
        guard bytes <= limits.maximumStagedBytesPerUser,
            userBytes() <= limits.maximumStagedBytesPerUser - bytes, stages.count < 4096
        else {
            throw TractandaError("resourceLimit", "Blob staging quota exceeded.")
        }
        try quota.require(additionalBytes: bytes)
    }
    func begin(
        accountID: String, principal: AccountIdentity, mediaType: String, declaredSize: Int64?,
        limits: JMAPBlobLimits, id: String
    ) throws -> JMAPBlobUploadHandle {
        try Self.validateMediaType(mediaType)
        guard declaredSize.map({ $0 >= 0 && $0 <= limits.maxSizeUpload }) ?? true else {
            throw TractandaError("resourceLimit", "Upload exceeds the Session limit.")
        }
        try expire()
        guard stages.values.filter({ $0.completion == nil }).count < 64,
            stages.values.filter({
                $0.completion == nil && $0.intent.uid == principal.uid
                    && $0.intent.principalName == principal.name
            }).count < limits.maxConcurrentUpload
        else {
            throw TractandaError("resourceLimit", "Too many concurrent blob uploads.")
        }
        try makeRoom(bytes: 8192, principal: principal, limits: limits)
        let intent = Intent(
            id: id, accountID: accountID, uid: principal.uid, principalName: principal.name,
            mediaType: mediaType, declaredSize: declaredSize, createdAt: clock())
        try files.writeImmutable(
            try JSON.encode(intent), path: ["jmap-blobs", id, "intent.json"], maximumBytes: 4096)
        do { try payloads.createStaging(id: id) } catch {
            try? files.removeJMAPBlobStage(id)
            throw error
        }
        stages[id] = Stage(intent: intent, limits: limits, count: 0, hash: SHA256(), completion: nil)
        return JMAPBlobUploadHandle(uploadID: id, chunkBytes: 262_144)
    }
    func append(id: String, principal: AccountIdentity, offset: Int64, data: Data) throws -> Int64 {
        guard var stage = stages[id] else { throw TractandaError("notFound", "Upload is unavailable.") }
        try requireOwner(stage, principal)
        guard stage.completion == nil, let limits = stage.limits, offset == stage.count,
            data.count <= 262_144,
            Int64(data.count) <= limits.maxSizeUpload - stage.count,
            stage.intent.declaredSize.map({ Int64(data.count) <= $0 - stage.count }) ?? true
        else {
            throw TractandaError("invalidArguments", "Invalid blob chunk offset or size.")
        }
        try makeRoom(bytes: Int64(data.count), principal: principal, limits: limits)
        do {
            let next = try payloads.append(id: id, offset: offset, data: data)
            stage.hash.update(data: data)
            stage.count = next
            stages[id] = stage
            return next
        } catch {
            // A partial syscall must never become a completed blob with a stale streaming hash.
            try? discard(id)
            throw error
        }
    }
    func finish(id: String, principal: AccountIdentity) throws -> JMAPBlobReceipt {
        guard var stage = stages[id] else { throw TractandaError("notFound", "Upload is unavailable.") }
        try requireOwner(stage, principal)
        if let completed = stage.completion { return completed.receipt }
        guard stage.intent.declaredSize.map({ $0 == stage.count }) ?? true,
            try payloads.stagedSize(id: id) == stage.count
        else {
            try? discard(id)
            throw TractandaError("uploadMismatch", "Body ended before its declared size.")
        }
        try Task.checkCancellation()
        let digest = stage.hash.finalize().map { String(format: "%02x", $0) }.joined()
        let receipt = JMAPBlobReceipt(
            accountId: stage.intent.accountID, blobId: digest,
            type: stage.intent.mediaType, size: stage.count)
        let completion = Completion(receipt: receipt, completedAt: clock())
        try files.writeImmutable(
            try JSON.encode(completion), path: ["jmap-blobs", id, "complete.json"], maximumBytes: 4096)
        stage.completion = completion
        stages[id] = stage
        return receipt
    }
    func ownStage(accountID: String, blobID: String, principal: AccountIdentity) throws -> (String, Stage)? {
        try Self.validateBlobID(blobID)
        try expire()
        return stages.first { _, stage in
            stage.intent.accountID == accountID && stage.intent.uid == principal.uid
                && stage.intent.principalName == principal.name && stage.completion?.receipt.blobId == blobID
        }.map { ($0.key, $0.value) }
    }
}

/// HTTP and standard-method adapter over the existing serialized Store owner. File digest work and
/// bounded reads use detached tasks; every chunk first revalidates the credential and current ACL.
public struct JMAPBlobService: JMAPBlobHTTPProvider, Sendable {
    private let coordinator: ServiceCoordinator
    private let limits: JMAPBlobLimits
    public var maximumUploadBytes: Int64 { limits.maxSizeUpload }
    public var maximumConcurrentUploads: Int64 { Int64(limits.maxConcurrentUpload) }
    public init(coordinator: ServiceCoordinator, limits: JMAPBlobLimits) {
        self.coordinator = coordinator
        self.limits = limits
    }
    public func beginUpload(
        accountID: String, type: String, expectedSize: Int64?,
        authentication: JMAPHTTPAuthentication
    ) async throws -> any JMAPBlobUpload {
        let limits = self.limits
        let handle = try await coordinator.withJMAPAccess(authentication: authentication) { store in
            try store.beginBlobUpload(
                accountID: accountID, mediaType: type, declaredSize: expectedSize, limits: limits)
        }
        return Upload(coordinator: coordinator, authentication: authentication, id: handle.uploadID)
    }
    public func openDownload(accountID: String, blobID: String, authentication: JMAPHTTPAuthentication)
        async throws -> JMAPBlobDownload
    {
        let handle = try await coordinator.withJMAPAccess(authentication: authentication) { store in
            try store.beginBlobDownload(accountID: accountID, blobID: blobID)
        }
        do {
            let verification = Task.detached { try handle.source.verify() }
            try await withTaskCancellationHandler(
                operation: { try await verification.value }, onCancel: { verification.cancel() })
            try await authorize(handle, authentication)
        } catch {
            await close(handle, authentication)
            throw error
        }
        return JMAPBlobDownload(
            size: handle.size,
            read: { offset, limit in
                try await authorize(handle, authentication)
                let result = try await Task.detached { try handle.source.read(offset: offset, limit: limit) }
                    .value
                try await authorize(handle, authentication)
                return result
            }, close: { await close(handle, authentication) })
    }
    private func authorize(_ handle: JMAPBlobDownloadHandle, _ authentication: JMAPHTTPAuthentication)
        async throws
    {
        try await coordinator.withJMAPAccess(authentication: authentication) { store in
            try store.authorizeBlobDownload(downloadID: handle.downloadID)
        }
    }
    private func close(_ handle: JMAPBlobDownloadHandle, _ authentication: JMAPHTTPAuthentication) async {
        // Closing pinned descriptors remains unconditional even after credential revocation.
        handle.source.close()
        await coordinator.closeJMAPBlobDownload(id: handle.downloadID, authentication: authentication)
    }
    public func attachBlob(
        _ request: JMAPAttachBlobRequest, authentication: JMAPHTTPAuthentication,
        replyBudget: JMAPReplyBudget? = nil
    ) async throws -> AttachmentCommitResult {
        let prepared = try await coordinator.withJMAPAccess(
            authentication: authentication, replyBudget: replyBudget
        ) { store in
            replyBudget?.markDomainOperationBegan()
            return try store.prepareBlobAttachment(request)
        }
        if let committed = prepared.committed { return committed }
        guard let id = prepared.uploadID else {
            throw TractandaError("serverFail", "Attachment intake returned no transfer identity.")
        }
        let source = try await openDownload(
            accountID: request.accountID, blobID: request.blobID, authentication: authentication)
        do {
            var offset = prepared.offset
            while offset < source.size {
                try Task.checkCancellation()
                let data = try await source.read(offset: offset, limit: 262_144)
                guard !data.isEmpty else {
                    throw TractandaError("attachmentIntegrity", "Blob ended before its receipt size.")
                }
                let current = offset
                offset = try await coordinator.withJMAPAccess(
                    authentication: authentication, replyBudget: replyBudget
                ) { store in
                    try store.appendAttachment(uploadID: id, offset: current, data: data)
                }
            }
            await source.close()
            let work = try await coordinator.withJMAPAccess(
                authentication: authentication, replyBudget: replyBudget
            ) { store in
                try store.prepareAttachmentIntegrity(uploadID: id)
            }
            if let work {
                let verification = Task.detached { try work.perform(progress: AttachmentIntegrityProgress()) }
                try await withTaskCancellationHandler(
                    operation: { try await verification.value }, onCancel: { verification.cancel() })
                try await coordinator.withJMAPAccess(authentication: authentication, replyBudget: replyBudget)
                { store in
                    try store.attachmentIntegrityFinished(uploadID: id, failureCode: nil)
                }
            }
            return try await coordinator.withJMAPAccess(
                authentication: authentication, replyBudget: replyBudget
            ) { store in
                AttachmentCommitResult(try store.finishAttachment(uploadID: id, requireVerified: true))
            }
        } catch {
            await source.close()
            // Preserve native upload intent/operationID after an uncertain publication. Exact retry
            // either resumes it or returns the canonical receipt; aborting here could lose evidence.
            throw error
        }
    }
    public func methods(authentication: JMAPHTTPAuthentication) async throws -> [String: JMAPMethodDefinition]
    {
        _ = try await authentication.revalidate()
        return [
            "TractandaAttachment/attachBlob": .init(
                capability: TractandaJMAP.capability, effect: .mayMutate,
                requiresWritableAccount: true, maximumResponseBytes: 16_384, requiresMutationAdmission: true
            ) { args, context in
                guard let account = context.accountID, let members = args.members,
                    Set(members.map(\.name)) == [
                        "accountId", "itemID", "expectedRevisionID", "blobId", "filename", "mediaType",
                        "operationID",
                    ],
                    let item = args["itemID"]?.text, let revision = args["expectedRevisionID"]?.text,
                    let blob = args["blobId"]?.text, let filename = args["filename"]?.text,
                    let mediaType = args["mediaType"]?.text, let operation = args["operationID"]?.text
                else {
                    return .failure(.init("invalidArguments"), effects: .none)
                }
                // Exact schema bound includes worst-case operationID escaping plus finite warnings.
                let tupleOverhead = try JMAPInvocation(
                    name: "TractandaAttachment/attachBlob", arguments: .object([]), callID: context.callID
                ).value.encoded().count
                try context.replyBudget.reserveMutationResponse(maximumResponseBytes: tupleOverhead + 8192)
                do {
                    let result = try await attachBlob(
                        .init(
                            accountID: account, itemID: item, expectedRevisionID: revision,
                            blobID: blob, filename: filename, mediaType: mediaType, operationID: operation),
                        authentication: authentication, replyBudget: context.replyBudget)
                    return try .nativeEncodedSuccess("TractandaAttachment/attachBlob", result)
                } catch {
                    return .failure(
                        Self.methodError(error),
                        effects: context.replyBudget.provesNoEffects ? .none : .unknown)
                }
            },
            "Blob/copy": .init(
                capability: JMAPKernel.core, effect: .mayMutate,
                requiresWritableAccount: true, maximumResponseBytes: 512 * 1024,
                requiresMutationAdmission: true
            ) { args, context in
                guard let account = context.accountID, let members = args.members,
                    Set(members.map(\.name)) == ["accountId", "fromAccountId", "blobIds"],
                    let from = args["fromAccountId"]?.text, JMAPRequest.validID(from),
                    let blobs = args["blobIds"]?.elements,
                    blobs.allSatisfy({ $0.text.map(JMAPRequest.validID) ?? false })
                else {
                    return .failure(.init("invalidArguments"), effects: .none)
                }
                var seen: Set<String> = []
                let ids = blobs.compactMap(\.text).filter { seen.insert($0).inserted }
                guard ids.count <= TractandaJMAP.maximumBlobIDsInCopy else {
                    return .failure(.init("requestTooLarge"), effects: .none)
                }
                let bound = try JMAPInvocation(
                    name: "Blob/copy",
                    arguments: .object([
                        .init("accountId", .string(account)), .init("fromAccountId", .string(from)),
                        .init(
                            "copied",
                            .object(ids.map { .init($0, .string(String(repeating: "f", count: 64))) })),
                        .init(
                            "notCopied",
                            .object(ids.map { .init($0, .object([.init("type", .string("notFound"))])) })),
                    ]), callID: context.callID
                ).value.encoded().count
                try context.replyBudget.reserveMutationResponse(maximumResponseBytes: bound)
                do {
                    // Both accounts are checked once before per-blob errors, even for an empty list.
                    try await coordinator.withJMAPAccess(authentication: authentication) { store in
                        try store.validateBlobCopyAccounts(accountID: account, fromAccountID: from)
                    }
                    var copied: [JMAPMember] = []
                    var notCopied: [JMAPMember] = []
                    for id in ids {
                        do {
                            let source = try await openDownload(
                                accountID: from, blobID: id, authentication: authentication)
                            await source.close()
                            copied.append(.init(id, .string(id)))
                        } catch let error as TractandaError
                            where ["notFound", "forbidden"].contains(error.code)
                        {
                            notCopied.append(.init(id, .object([.init("type", .string("notFound"))])))
                        }
                    }
                    return .success([
                        .init(
                            "Blob/copy",
                            .object([
                                .init("accountId", .string(account)),
                                .init("fromAccountId", .string(from)),
                                .init("copied", copied.isEmpty ? .null : .object(copied)),
                                .init("notCopied", notCopied.isEmpty ? .null : .object(notCopied)),
                            ]))
                    ])
                } catch { return .failure(Self.methodError(error), effects: .none) }
            },
        ]
    }
    private static func methodError(_ error: Error) -> JMAPMethodError {
        if let error = error as? JMAPMethodError { return error }
        let code = (error as? TractandaError)?.code ?? "serverFail"
        return .init(code)
    }
    private actor Upload: JMAPBlobUpload {
        let coordinator: ServiceCoordinator
        let authentication: JMAPHTTPAuthentication
        let id: String
        var offset: Int64 = 0
        var completed: JMAPBlobReceipt?
        var cancelled = false
        var busy = false
        init(coordinator: ServiceCoordinator, authentication: JMAPHTTPAuthentication, id: String) {
            self.coordinator = coordinator
            self.authentication = authentication
            self.id = id
        }
        func append(_ data: Data) async throws {
            guard !cancelled, completed == nil else { throw TractandaError("notFound", "Upload is closed.") }
            guard !busy else { throw TractandaError("uploadBusy", "A body operation is already active.") }
            busy = true
            defer { busy = false }
            let current = offset
            let id = self.id
            offset = try await coordinator.withJMAPAccess(authentication: authentication) { store in
                try store.appendBlobUpload(uploadID: id, offset: current, data: data)
            }
        }
        func finish() async throws -> JMAPValue {
            guard !cancelled else { throw TractandaError("notFound", "Upload is closed.") }
            guard !busy else { throw TractandaError("uploadBusy", "A body operation is already active.") }
            busy = true
            defer { busy = false }
            _ = try await authentication.revalidate()
            if let completed { return completed.value }
            let id = self.id
            let receipt = try await coordinator.withJMAPAccess(authentication: authentication) { store in
                try store.finishBlobUpload(uploadID: id)
            }
            completed = receipt
            return receipt.value
        }
        func cancel() async {
            if completed != nil || cancelled { return }
            cancelled = true
            let id = self.id
            await coordinator.cancelJMAPBlobUpload(id: id, authentication: authentication)
        }
    }
}
