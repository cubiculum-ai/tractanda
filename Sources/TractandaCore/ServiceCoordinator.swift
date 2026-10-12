import CTractandaPlatform
import Dispatch
import Foundation
import TractandaClient

/// Owns the one mutable store/service pair used by all transports. Store, authority and SQLite
/// work runs on a private serial GCD queue. A bounded immutable query snapshot may be evaluated
/// concurrently off-queue, then rechecked on the owner queue before delivery.
/// Closures submitted to this type must not suspend while ItemStore has an access context.
public actor ServiceCoordinator {
    private let makeAccountDirectory: @Sendable () -> any AccountDirectory
    private let rebuildJournal: RebuildJournal
    private var rebuildStatus: StoreRebuildStatus?
    private var rebuildControl: RebuildControl?
    private var rebuildTask: Task<Void, Never>?
    private var rebuildPolicy: RebuildAdministratorPolicy?
    private var rebuildSessionState = ""
    private var canonicalWorkGeneration: UInt64 = 0
    private var rebuildHookForTesting: (@Sendable () async throws -> Void)?
    private var rebuildNoProgressSeconds: Double = 120
    private let core: CoreBox
    private let readPool: SQLiteReadPool
    private var accepting = true
    private var pending = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var verificationTask: Task<Void, Never>?
    private var verificationInterval: Duration = .seconds(900)
    private var exclusiveRebuildPending = false
    private struct AttachmentIntegrityTask {
        let task: Task<Void, Never>
        let progress: AttachmentIntegrityProgress
    }
    private var attachmentIntegrityTasks: [String: AttachmentIntegrityTask] = [:]
    private var attachmentIntegrityFailures: [String: String] = [:]
    private var attachmentIntegrityHookForTesting: (@Sendable () async throws -> Void)?
    private struct AttachmentCopyTask {
        let task: Task<Void, Never>
        let progress: AttachmentIntegrityProgress
    }
    private var attachmentCopyTasks: [String: AttachmentCopyTask] = [:]
    private var attachmentCopyResults: [String: Result<PreparedAttachmentCopy, TractandaError>] = [:]
    private var attachmentCopyHookForTesting: (@Sendable () async throws -> Void)?
    private struct ExtractedUnitTask {
        let prepared: PreparedExtractedTextUnit
        let task: Task<Data, Error>
    }
    private var extractedUnitTasks: [String: ExtractedUnitTask] = [:]
    private var extractedUnitAdmissions = 0
    private var extractedUnitWaiters: [CheckedContinuation<Void, Never>] = []
    private var extractedUnitEpoch: UInt64 = 0
    private var extractedUnitDraining = false
    private var extractedUnitHookForTesting: (@Sendable () async -> Void)?
    private var semanticLifecyclePending = false
    private var semanticReaderDrainHookForTesting: (@Sendable (Int, Int64) -> Void)?
    private let documentJobBudgets: DocumentWorkerBudgets
    private var documentJobAdmissions: [DocumentJobAdmission] = []
    private var documentJobTask: Task<Void, Never>?
    private var documentJobCancellation: DocumentConversionCancellation?
    private var activeDocumentJobID: String?
    private var documentJobDraining = false
    private var documentJobPublicationHookForTesting: (@Sendable () async -> Void)?
    private var documentJobAdmissionHookForTesting: (@Sendable () async -> Void)?
    private var documentJobIndexHookForTesting: (@Sendable (IndexCorpusWriteBatch) throws -> Void)?
    private var documentJobStartupRecovery: Task<Void, Never>?
    private var documentConversionInFlight = false
    private var documentCancellation: DocumentConversionCancellation?
    private var preparedReadHookForTesting: (@Sendable () async -> Void)?
    private var pooledReadLeaseHookForTesting: (@Sendable () -> Void)?
    private var pooledReadBeforeFinishHookForTesting: (@Sendable () async -> Void)?
    private var pooledHistoryAfterSnapshotHookForTesting: (@Sendable () -> Void)?
    private var verificationScanHookForTesting: (@Sendable () async -> Void)?
    private static let maximumPending = 64

    /// Opens one exclusive store writer outside the cooperative executor.
    public init(
        opening root: URL,
        indexDirectory: URL? = nil,
        documentConverter: DocumentConverterConfiguration? = nil,
        documentJobResources: DocumentJobResources = DocumentJobResources(),
        attachmentUploadPolicy: AttachmentUploadPolicy = AttachmentUploadPolicy(),
        rebuildNoProgressTimeoutSeconds: Double = 120,
        makeAccountDirectory: @escaping @Sendable () -> any AccountDirectory = { SystemAccountDirectory() }
    ) async throws {
        try await self.init(
            opening: root, embeddingProviderForTesting: nil, indexDirectory: indexDirectory,
            documentConverter: documentConverter, documentJobResources: documentJobResources,
            attachmentUploadPolicy: attachmentUploadPolicy,
            rebuildNoProgressTimeoutSeconds: rebuildNoProgressTimeoutSeconds,
            makeAccountDirectory: makeAccountDirectory)
    }

    init(
        opening root: URL,
        embeddingProviderForTesting: (
            @Sendable (SemanticConfiguration, [String], Bool) async throws -> [[Double]]
        )?,
        indexDirectory: URL? = nil,
        documentConverter: DocumentConverterConfiguration? = nil,
        documentJobResources: DocumentJobResources = DocumentJobResources(),
        attachmentUploadPolicy: AttachmentUploadPolicy = AttachmentUploadPolicy(),
        rebuildNoProgressTimeoutSeconds: Double = 120,
        makeAccountDirectory: @escaping @Sendable () -> any AccountDirectory = { SystemAccountDirectory() }
    ) async throws {
        guard rebuildNoProgressTimeoutSeconds.isFinite, rebuildNoProgressTimeoutSeconds > 0 else {
            throw TractandaError(
                "invalidConfiguration", "Rebuild no-progress timeout must be positive and finite.")
        }
        self.documentJobBudgets = try documentJobResources.budgets()
        self.rebuildNoProgressSeconds = rebuildNoProgressTimeoutSeconds
        let opened: CoreBox = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try CoreBox(
                            root: root, indexDirectory: indexDirectory, accounts: makeAccountDirectory(),
                            documentConverter: documentConverter,
                            attachmentUploadPolicy: attachmentUploadPolicy,
                            embeddingProviderForTesting: embeddingProviderForTesting))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        core = opened
        readPool = opened.readPool
        self.makeAccountDirectory = makeAccountDirectory
        let journal = RebuildJournal(
            root: root.standardizedFileURL.resolvingSymlinksInPath(), ownerUID: tractanda_uid())
        rebuildJournal = journal
        rebuildStatus = try journal.recoverInterrupted(indexTrusted: true)
        documentJobStartupRecovery = Task { [self] in await recoverDocumentJobsAtStartup() }
    }

    /// The UID is authenticated by the in-process transport and never read from request bytes.
    public func handle(_ request: Data, forUID uid: UInt32) async throws -> Data {
        if let call = ItemService.rebuildNativeCall(request) {
            try beginWork()
            defer { finishWork() }
            return try await handleRebuild(call, uid: uid)
        }
        let acceptedGeneration = canonicalWorkGeneration
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "A store rebuild is draining accepted readers.")
        }
        try beginWork()
        defer { finishWork() }
        if let call = ItemService.extractedTextUnitCall(request) {
            return try await handleExtractedTextUnit(call, uid: uid, generation: acceptedGeneration)
        }
        if ItemService.semanticLifecycleMethod(request) != nil {
            return try await handleSemanticLifecycle(request, uid: uid, generation: acceptedGeneration)
        }
        if let call = ItemService.documentJobNativeCall(request) {
            return try await handleDocumentJob(call, uid: uid, generation: acceptedGeneration)
        }
        if ItemService.attachmentCopyCallID(request) != nil {
            return try await handleAttachmentCopy(request, uid: uid)
        }
        if ItemService.attachmentIntegrityMethod(request) != nil {
            return try await handleAttachmentIntegrity(request, uid: uid)
        }
        try requireCanonicalGeneration(acceptedGeneration)
        let pooled = try? await submit { service in
            if let prepared = try service.preparePooledQuery(request, peerUID: uid) {
                return prepared
            }
            return try service.preparePooledSavedViewQuery(request, peerUID: uid)
        }
        if let pooled {
            let pool = readPool
            let leaseHook = pooledReadLeaseHookForTesting
            let page = await evaluatePooled { cancellation in
                try pooled.evaluate(in: pool, cancellation: cancellation, afterLease: leaseHook)
            }
            try Task.checkCancellation()
            if let page {
                if let hook = pooledReadBeforeFinishHookForTesting { await hook() }
                try requireCanonicalGeneration(acceptedGeneration)
                let response = try? await submit { service in
                    try service.finishPooledQuery(pooled, page: page, peerUID: uid)
                }
                if let response { return response }
            }
        }
        try requireCanonicalGeneration(acceptedGeneration)
        let pooledGet = try? await submit { service in
            try service.preparePooledGet(request, peerUID: uid)
        }
        if let pooledGet {
            let pool = readPool
            let leaseHook = pooledReadLeaseHookForTesting
            let records = await evaluatePooled { cancellation in
                try pooledGet.evaluate(in: pool, cancellation: cancellation, afterLease: leaseHook)
            }
            try Task.checkCancellation()
            if let records {
                if let hook = pooledReadBeforeFinishHookForTesting { await hook() }
                try requireCanonicalGeneration(acceptedGeneration)
                let response = try? await submit { service in
                    try service.finishPooledGet(pooledGet, records: records, peerUID: uid)
                }
                if let response { return response }
            }
        }
        try requireCanonicalGeneration(acceptedGeneration)
        let pooledHistory = try? await submit { service in
            try service.preparePooledHistory(request, peerUID: uid)
        }
        if let pooledHistory {
            let pool = readPool
            let leaseHook = pooledReadLeaseHookForTesting
            let snapshotHook = pooledHistoryAfterSnapshotHookForTesting
            let result = await evaluatePooled { cancellation in
                try pooledHistory.evaluate(
                    in: pool, cancellation: cancellation, afterLease: leaseHook,
                    afterSnapshot: snapshotHook)
            }
            try Task.checkCancellation()
            if let result {
                if let hook = pooledReadBeforeFinishHookForTesting { await hook() }
                try requireCanonicalGeneration(acceptedGeneration)
                let response = try? await submit { service in
                    try service.finishPooledHistory(pooledHistory, result: result, peerUID: uid)
                }
                if let response { return response }
            }
        }
        try requireCanonicalGeneration(acceptedGeneration)
        let prepared: PreparedNativeRead?
        do {
            prepared = try await submit { service in
                return try service.prepareNativeRead(request, peerUID: uid)
            }
        } catch {
            prepared = nil
        }
        if let prepared {
            let hook = preparedReadHookForTesting
            let evaluated = try? await Task.detached(priority: .userInitiated) {
                if let hook { await hook() }
                return try prepared.query.evaluate(prepared.snapshot)
            }.value
            if let evaluated {
                try requireCanonicalGeneration(acceptedGeneration)
                do {
                    let response = try await submit { service -> Data? in
                        defer { service.maintainSemanticIndex() }
                        return try service.finishNativeRead(prepared, page: evaluated, peerUID: uid)
                    }
                    if let response { return response }
                } catch {
                    let failure =
                        error as? TractandaError
                        ?? TractandaError("invalidRequest", String(describing: error))
                    return (try? JSON.encode(failure)) ?? Data("{\"code\":\"serverError\"}".utf8)
                }
            }
        }
        try requireCanonicalGeneration(acceptedGeneration)
        let response = try await submit { service in service.handle(request, peerUID: uid) }
        return response
    }

    func setDocumentJobPublicationHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        documentJobPublicationHookForTesting = hook
    }
    func setDocumentJobAdmissionHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        documentJobAdmissionHookForTesting = hook
    }
    func setDocumentJobIndexHookForTesting(_ hook: (@Sendable (IndexCorpusWriteBatch) throws -> Void)?) {
        documentJobIndexHookForTesting = hook
    }
    private func handleDocumentJob(_ call: DocumentJobNativeCall, uid: UInt32, generation: UInt64)
        async throws -> Data
    {
        do {
            try requireCanonicalGeneration(generation)
            let dispatched = try await submit { try $0.dispatchDocumentJob(call, peerUID: uid) }
            if ["cancel", "resume", "rebase", "discard"].contains(
                String(call.method.dropFirst("TractandaDocumentJob/".count))),
                let args = try? JSONSerialization.jsonObject(with: call.arguments) as? [String: Any],
                let id = args["jobID"] as? String, activeDocumentJobID == id
            {
                // Durable generation fence preceded cancellation; a resumed job waits for the old owner.
                documentJobCancellation?.cancel()
            }
            if let admission = dispatched.admission { enqueueDocumentJob(admission) }
            return dispatched.response
        } catch {
            let failure =
                error as? TractandaError
                ?? TractandaError("invalidArguments", "Invalid document job request.")
            return try await submit {
                $0.documentNativeFailure(callID: call.callID, failure: failure, peerUID: uid)
            }
        }
    }
    private func recoverDocumentJobsAtStartup() async {
        guard accepting, !exclusiveRebuildPending, !documentJobDraining else { return }
        do {
            let admissions = try await submit { service in
                try service.store.recoverDocumentJobAdmissions(
                    configurationSHA256: service.documentJobRuntime()?.configurationSHA256)
            }
            for admission in admissions { enqueueDocumentJob(admission) }
        } catch {
            FileHandle.standardError.write(Data("Document job recovery paused: \(error)\n".utf8))
        }
    }
    private func enqueueDocumentJob(_ admission: DocumentJobAdmission) {
        if let index = documentJobAdmissions.firstIndex(where: { $0.jobID == admission.jobID }) {
            if admission.generation >= documentJobAdmissions[index].generation {
                documentJobAdmissions[index] = admission
            }
            return
        }
        // Canonical records enforce 64 pending slots; this mailbox contains at most one compact ID per slot.
        guard documentJobAdmissions.count < 64 else { return }
        documentJobAdmissions.append(admission)
        launchNextDocumentJob()
    }
    private func launchNextDocumentJob() {
        guard accepting, !exclusiveRebuildPending, !documentJobDraining,
            documentJobTask == nil, !documentJobAdmissions.isEmpty
        else { return }
        let admission = documentJobAdmissions.removeFirst()
        let epoch = canonicalWorkGeneration
        let cancellation = DocumentConversionCancellation()
        activeDocumentJobID = admission.jobID
        documentJobCancellation = cancellation
        documentJobTask = Task { [self] in
            await runDocumentJob(admission, epoch: epoch, cancellation: cancellation)
            documentJobTask = nil
            activeDocumentJobID = nil
            documentJobCancellation = nil
            launchNextDocumentJob()
        }
    }
    private func recoverDocumentIndexWork(
        _ admission: DocumentJobAdmission, token: Int64, epoch: UInt64,
        worker: DocumentJobProducer, cancellation: DocumentConversionCancellation
    ) async throws {
        try requireCanonicalGeneration(epoch)
        let work = try await submit { service in
            try service.store.documentJobIndexRecoveryWork(
                admission.jobID, generation: token, discard: admission.discard)
        }
        let owner = core
        let boundary: @Sendable () throws -> Void = {
            if !admission.discard { try cancellation.check() }
            try owner.synchronously { service in
                _ = try service.store.documentJobIndexRecoveryWork(
                    admission.jobID, generation: token, discard: admission.discard)
            }
        }
        let transactionBoundary: @Sendable () throws -> Void = {
            if !admission.discard { try cancellation.check() }
        }
        // The mailbox launches only after the old serial producer has closed and terminated.
        try await worker.perform { _ in try work.retire(boundary: boundary) }
        try await reconcileDocumentCorpusCharges()
        var complete = false
        repeat {
            // Durable retirement/debt survives interruption; resume authenticates saved pages again.
            let progress = try await worker.perform { _ in
                try work.cleanup(authorityBoundary: boundary, transactionBoundary: transactionBoundary)
            }
            complete = progress.complete
            try await reconcileDocumentCorpusCharges()
            try requireCanonicalGeneration(epoch)
            try boundary()
            guard complete || progress.madeProgress else {
                throw TractandaError(
                    "indexProjectionPending",
                    "Corpus cleanup parked with retained debt; resume after protected work advances.")
            }
        } while !complete
    }
    private func reconcileDocumentCorpusCharges() async throws {
        // Committed ownership/deletion observations precede cancellation/ACL checks. Each read is
        // fresh on the owner queue, serialized with newer reservations; no detached charge can win.
        for charged in [true, false] {
            var cursor: String?
            repeat {
                let after = cursor
                cursor = try await submit { service in
                    try service.store.reconcileCorpusChargePage(after: after, charged: charged)
                }
            } while cursor != nil
        }
    }
    private func runDocumentJob(
        _ admission: DocumentJobAdmission, epoch: UInt64,
        cancellation: DocumentConversionCancellation
    ) async {
        var producer: DocumentJobProducer?
        var generation: Int64?
        var inspectedPageCount: Int64?
        do {
            await documentJobAdmissionHookForTesting?()
            try requireCanonicalGeneration(epoch)
            let admitted = try await submit { service -> (DocumentJobMaterialWork, DocumentJobRuntime?) in
                if admission.discard {
                    return (
                        try service.store.documentJobDisposalWork(
                            admission.jobID, generation: admission.generation), nil
                    )
                }
                return try service.store.withAccess(forUID: admission.actorUID) {
                    guard let runtime = try service.documentJobRuntime() else {
                        throw TractandaError(
                            "documentConverterUnavailable", "Configure the native document producer.")
                    }
                    let claimed = try service.store.claimDocumentJob(
                        admission.jobID, configurationSHA256: runtime.configurationSHA256,
                        expectedGeneration: admission.generation)
                    return (
                        try service.store.documentJobMaterialWork(
                            admission.jobID,
                            generation: claimed.checkpoint.generation,
                            configurationSHA256: runtime.configurationSHA256), runtime
                    )
                }
            }
            let worker = DocumentJobProducer(
                work: admitted.0, runtime: admitted.1,
                budgets: documentJobBudgets, cancellation: cancellation)
            producer = worker
            let token = admitted.0.checkpoint.generation
            generation = token
            if admission.discard {
                try await recoverDocumentIndexWork(
                    admission, token: token, epoch: epoch, worker: worker, cancellation: cancellation)
                try await worker.perform { try $0.dispose() }
                try await submit { service in
                    try service.store.acknowledgeDocumentJobDisposal(admission.jobID, generation: token)
                }
            } else {
                let recovered = try await worker.perform { try $0.recover() }
                try await acceptDocumentStage(
                    recovered, admission: admission, epoch: epoch, cancellation: cancellation)
                let count = try await worker.perform { try $0.inspect() }
                inspectedPageCount = count
                try requireCanonicalGeneration(epoch)
                try cancellation.check()
                try await submit { service in
                    try service.store.withAccess(forUID: admission.actorUID) {
                        try service.store.inspectDocumentJob(
                            admission.jobID, generation: token, pageCount: count)
                    }
                }
                var next = try PageCorpusEmitter.add(recovered.acceptedPages, 1)
                while next <= count {
                    try cancellation.check()
                    let number = next
                    let page = try await worker.perform { try $0.convert(number) }
                    let seal = try await worker.perform { try $0.append(page, pageCount: count) }
                    try await acceptDocumentStage(
                        seal, admission: admission, epoch: epoch, cancellation: cancellation)
                    next = try PageCorpusEmitter.add(next, 1)
                }
                let prepared = try await worker.perform { try $0.prepare(pageCount: count) }
                try await acceptDocumentStage(
                    prepared, admission: admission, epoch: epoch, cancellation: cancellation)
                await documentJobPublicationHookForTesting?()
                let projection = try await submit { service in
                    try service.store.withAccess(forUID: admission.actorUID) {
                        try service.store.documentJobProjectionWork(admission.jobID, generation: token)
                    }
                }
                let spool = try await worker.perform { _ in
                    try projection.prepareSpool(cancellation: cancellation)
                }
                try requireCanonicalGeneration(epoch)
                try cancellation.check()
                try await submit { service in
                    try service.store.withAccess(forUID: admission.actorUID) {
                        try service.store.acknowledgeDocumentCorpus(
                            admission.jobID, generation: token, prepared: spool)
                    }
                }
                try await recoverDocumentIndexWork(
                    admission, token: token, epoch: epoch, worker: worker, cancellation: cancellation)
                let owner = core
                let indexHook = documentJobIndexHookForTesting
                let stage = try await worker.perform { _ in
                    try ItemIndex.stageCorpus(
                        indexPath: projection.indexPath, input: projection.snapshot.input,
                        prepared: spool, workID: admission.jobID,
                        writeBoundary: { batch in
                            if batch.phase != .afterCommit { try cancellation.check() }
                            if batch.phase == .after {
                                try indexHook?(batch)
                                return  // Inside the writer txn: local checks only.
                            }
                            try owner.synchronously { service in
                                if batch.phase == .afterCommit {
                                    try service.store.observeDocumentIndexWork(
                                        batch.workID,
                                        retainedEncodedBytes: batch.retainedEncodedBytes)
                                }
                                try service.store.withAccess(forUID: admission.actorUID) {
                                    try service.store.checkDocumentIndexBoundary(
                                        admission.jobID, generation: token,
                                        binding: projection.snapshot.input.binding,
                                        reserveBytes: batch.phase == .before
                                            ? batch.estimatedAdditionalBytes : 0)
                                }
                            }
                            try cancellation.check()
                            try indexHook?(batch)
                        }, boundary: { try cancellation.check() })
                }
                let content = try await worker.perform { worker in
                    try cancellation.check()
                    guard let sealed = prepared.prepared else { throw NativeWorkerProtocol.invalid() }
                    let content = try worker.publishContent(sealed)
                    try cancellation.check()
                    return content
                }
                try requireCanonicalGeneration(epoch)
                try cancellation.check()
                _ = try await submit { service in
                    try service.store.withAccess(forUID: admission.actorUID) {
                        try service.store.publishIndexedDocumentJob(
                            admission.jobID, generation: token,
                            content: content, corpus: stage)
                    }
                }
            }
        } catch {
            if let producer, let generation,
                let native = error as? DocumentNativeSessionFailure,
                native.failure.code == "documentTimeout", native.pageStarted,
                let number = native.requestedPage, let count = inspectedPageCount
            {
                // Cancellation and model/inspection timeouts never fabricate a page outcome.
                if !documentJobDraining, accepting, !exclusiveRebuildPending {
                    do {
                        try cancellation.check()
                        let page = try DocumentStoredPage(
                            pageNumber: number,
                            sourceSHA256: producer.work.intent.source.sha256, status: "timeout",
                            failureCode: "documentTimeout")
                        let seal = try await producer.perform { try $0.append(page, pageCount: count) }
                        try await acceptDocumentStage(
                            seal, admission: admission, epoch: epoch, cancellation: cancellation)
                    } catch {
                        // Failed/fenced timeout acceptance leaves the prior durable frontier intact.
                    }
                }
                _ = generation
            }
            if generation == nil, !admission.discard, !documentJobDraining {
                let reason = (error as? TractandaError)?.code ?? "documentWorkerFailed"
                try? await submit { try $0.store.pauseQueuedDocumentJob(admission, reasonCode: reason) }
            }
            if let generation, admission.discard {
                try? await submit { service in
                    try service.store.pauseDocumentJobDisposal(
                        admission.jobID, generation: generation,
                        reasonCode: (error as? TractandaError)?.code ?? "documentRecoveryFailed")
                }
            }
            if let generation, !admission.discard, !documentJobDraining {
                let reason =
                    (error as? DocumentNativeSessionFailure)?.failure.code
                    ?? (error as? TractandaError)?.code
                    ?? (error is CancellationError ? "producerInterrupted" : "documentWorkerFailed")
                let message = (error as? DocumentNativeSessionFailure)?.timeoutMessage
                try? await submit { service in
                    try service.store.pauseDocumentJob(
                        admission.jobID, generation: generation, reasonCode: reason, reasonMessage: message)
                }
            }
        }
        if let producer { try? await producer.perform { $0.close() } }
    }
    private func acceptDocumentStage(
        _ seal: DocumentStageSeal, admission: DocumentJobAdmission,
        epoch: UInt64, cancellation: DocumentConversionCancellation
    ) async throws {
        try requireCanonicalGeneration(epoch)
        try cancellation.check()
        _ = try await submit { service in
            try service.store.withAccess(forUID: admission.actorUID) {
                try service.store.acknowledgeDocumentStage(seal)
            }
        }
    }
    private func handleExtractedTextUnit(_ call: ExtractedTextUnitCall, uid: UInt32, generation: UInt64)
        async throws -> Data
    {
        guard accepting, !semanticLifecyclePending, !extractedUnitDraining, extractedUnitAdmissions < 64
        else {
            return try await submit {
                try $0.extractedTextUnitFailure(
                    call, error: TractandaError("serviceBusy", "Source readers are draining or at capacity."))
            }
        }
        extractedUnitAdmissions += 1
        defer {
            extractedUnitAdmissions -= 1
            if extractedUnitAdmissions == 0 {
                let waiters = extractedUnitWaiters
                extractedUnitWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        let epoch = extractedUnitEpoch
        var prepared: PreparedExtractedTextUnit?
        var readerID: String?
        do {
            try requireCanonicalGeneration(generation)
            guard accepting, !semanticLifecyclePending, !extractedUnitDraining,
                extractedUnitTasks.count < 64
            else { throw TractandaError("serviceBusy", "Source readers are draining or at capacity.") }
            let work = try await submit { try $0.prepareExtractedTextUnit(call, peerUID: uid) }
            prepared = work
            try requireCanonicalGeneration(generation)
            guard accepting, !semanticLifecyclePending, !extractedUnitDraining, epoch == extractedUnitEpoch,
                extractedUnitTasks.count < 64, let id = work.corpus.retentionID
            else { throw TractandaError("serviceBusy", "Source reader admission was fenced.") }
            readerID = id
            let hook = extractedUnitHookForTesting
            let task = Task.detached(priority: .userInitiated) {
                await hook?()
                try Task.checkCancellation()
                return try work.evaluate()
            }
            extractedUnitTasks[id] = .init(prepared: work, task: task)
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            try requireCanonicalGeneration(generation)
            guard accepting, !semanticLifecyclePending, !extractedUnitDraining, epoch == extractedUnitEpoch
            else { throw TractandaError("serviceBusy", "Source reader delivery was fenced.") }
            let response = try await submit {
                try $0.finishExtractedTextUnit(work, result: result, peerUID: uid)
            }
            try await submit { try $0.store.releaseIndexedCorpus(work.corpus) }
            prepared = nil
            extractedUnitTasks.removeValue(forKey: id)
            try Task.checkCancellation()
            try requireCanonicalGeneration(generation)
            guard accepting, !semanticLifecyclePending, !extractedUnitDraining, epoch == extractedUnitEpoch
            else { throw TractandaError("serviceBusy", "Source reader delivery was fenced.") }
            return response
        } catch {
            let failure = error
            if let readerID, let running = extractedUnitTasks[readerID] {
                running.task.cancel()
                _ = await running.task.result
                extractedUnitTasks.removeValue(forKey: readerID)
            }
            if let work = prepared {
                // The detached reader has terminated. Failure leaves charged durable retirement debt.
                try? await submit { try $0.store.releaseIndexedCorpus(work.corpus) }
            }
            return try await submit { try $0.extractedTextUnitFailure(call, error: failure) }
        }
    }
    private func drainExtractedTextUnits(retireMetadata: Bool) async throws {
        extractedUnitDraining = true
        defer { extractedUnitDraining = false }
        guard extractedUnitEpoch < .max else {
            throw TractandaError("resourceLimit", "Source reader lifecycle epoch exhausted.")
        }
        extractedUnitEpoch += 1
        let readers = extractedUnitTasks
        for reader in readers.values { reader.task.cancel() }
        for reader in readers.values { _ = await reader.task.result }
        // Includes captures awaiting Store admission and their terminal lease retirement. A
        // capture must never escape the task map simply because drain began during submit().
        while extractedUnitAdmissions > 0 {
            await withCheckedContinuation { extractedUnitWaiters.append($0) }
        }
        if retireMetadata {
            while try await submit({ try $0.store.retireOnePendingCorpusRead() }) {}
        }
    }
    func setExtractedUnitHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        extractedUnitHookForTesting = hook
    }
    private func handleSemanticLifecycle(_ request: Data, uid: UInt32, generation: UInt64) async throws
        -> Data
    {
        guard !semanticLifecyclePending else {
            throw TractandaError("serviceBusy", "Another semantic lifecycle operation is draining readers.")
        }
        semanticLifecyclePending = true
        defer { semanticLifecyclePending = false }
        try await submit { service in
            try service.store.withAccess(forUID: uid) { try service.store.requireAdministrator() }
        }
        try await drainSemanticDocumentWork()
        try requireCanonicalGeneration(generation)
        let response = try await submit { $0.handle(request, peerUID: uid) }
        if accepting, !exclusiveRebuildPending { try? await submit { $0.resumeSemanticDocumentWork() } }
        return response
    }

    private func drainSemanticDocumentWork(retireMetadata: Bool = true) async throws {
        try await drainExtractedTextUnits(retireMetadata: retireMetadata)
        let worker = try await submit { $0.cancelSemanticDocumentWork() }
        await worker?.value  // Actual detached I/O must terminate before lease disposal or replacement.
        try await submit { $0.drainSemanticDocumentTerminal() }
        if retireMetadata {
            while try await submit({ try $0.store.retireOnePendingCorpusRead() }) {}
        }
        if let hook = semanticReaderDrainHookForTesting {
            let state = try await submit { try $0.store.corpusReadStateForTesting() }
            hook(state.count, state.charge)
        }
    }
    func setSemanticReaderDrainHookForTesting(_ hook: (@Sendable (Int, Int64) -> Void)?) {
        semanticReaderDrainHookForTesting = hook
    }
    func semanticReaderStateForTesting() async throws -> (count: Int, charge: Int64, pending: Int) {
        try await submit { try $0.store.corpusReadStateForTesting() }
    }
    func setCorpusReaderReleaseFailureForTesting(_ fail: Bool) async throws {
        try await submit { service in
            service.store.beforeCorpusReadReleaseForTesting =
                fail
                ? { _ in
                    throw TractandaError("injectedReadRetirement", "Lease metadata retirement failed")
                } : nil
        }
    }

    private func drainDocumentJobs(reasonCode: String) async {
        documentJobDraining = true
        documentJobCancellation?.cancel()
        await documentJobStartupRecovery?.value
        await documentJobTask?.value
        documentJobAdmissions.removeAll()
        try? await submit { try $0.store.pauseDocumentJobs(reasonCode: reasonCode) }
    }

    func setRebuildHookForTesting(
        _ hook: (@Sendable () async throws -> Void)?, noProgressSeconds: Double = 120
    ) {
        rebuildHookForTesting = hook
        rebuildNoProgressSeconds = noProgressSeconds
    }
    func setRebuildRecordHookForTesting(_ hook: (@Sendable () throws -> Void)?) async throws {
        try await submit { service in
            service.store.afterRecoveryRecordForTesting = hook.map { action in { _ in try action() } }
        }
    }
    func setCanonicalSyncHookForTesting(_ hook: (@Sendable () throws -> Void)?) async throws {
        try await submit { service in service.store.afterCanonicalSyncEntryForTesting = hook }
    }
    private func handleRebuild(_ call: RebuildNativeCall, uid: UInt32) async throws -> Data {
        do {
            let policy: RebuildAdministratorPolicy
            var trustedBeforeAdmission = false
            if exclusiveRebuildPending, let captured = rebuildPolicy {
                policy = captured
                trustedBeforeAdmission = rebuildControl?.status.indexTrusted ?? false
            } else {
                let admission = try await submit { service in
                    try service.store.withAccess(forUID: uid) {
                        RebuildAdmission(
                            policy: try service.store.rebuildAdministratorPolicy(),
                            state: service.store.state,
                            indexTrusted: service.store.isCanonicalTrusted
                        )
                    }
                }
                policy = admission.policy
                trustedBeforeAdmission = admission.indexTrusted
                rebuildSessionState = admission.state
            }
            try policy.authorize(uid: uid, accounts: makeAccountDirectory())
            let arguments = call.arguments
            if call.method == "TractandaStore/rebuild" {
                guard Set(arguments.keys) == ["operationID"],
                    let operation = arguments["operationID"] as? String,
                    !operation.isEmpty, operation.utf8.count <= 200, !operation.contains("\0")
                else {
                    throw TractandaError("invalidArguments", "Rebuild requires one bounded operationID.")
                }
                if let current = rebuildControl?.status ?? rebuildStatus, current.operationID == operation {
                    return try rebuildResponse(call: call, status: current)
                }
                guard !exclusiveRebuildPending else {
                    throw TractandaError("serviceBusy", "An exclusive rebuild is in progress.")
                }
                guard canonicalWorkGeneration < .max else {
                    throw TractandaError("resourceLimit", "Coordinator generation exhausted.")
                }
                let status = StoreRebuildStatus(
                    jobID: try UUID.makeVersion1().uuidString.lowercased(),
                    operationID: operation, updatedAt: Timestamp.now(),
                    noProgressTimeoutSeconds: rebuildNoProgressSeconds, indexTrusted: trustedBeforeAdmission,
                    requiresRecovery: !trustedBeforeAdmission)
                let accountFactory = makeAccountDirectory
                let control = try RebuildControl(
                    status: status, journal: rebuildJournal,
                    publicationAuthority: { try policy.authorize(uid: uid, accounts: accountFactory()) })
                rebuildControl = control
                rebuildPolicy = policy
                exclusiveRebuildPending = true
                canonicalWorkGeneration += 1
                let hook = rebuildHookForTesting
                rebuildTask = Task { [self] in await performRebuild(control, uid: uid, hook: hook) }
                return try rebuildResponse(call: call, status: status)
            }
            guard Set(arguments.keys).isSubset(of: ["jobID"]),
                call.method != "TractandaStore/rebuildCancel" || arguments["jobID"] is String,
                arguments["jobID"] == nil || arguments["jobID"] is String
            else {
                throw TractandaError(
                    "invalidArguments", "Status accepts an optional jobID; cancellation requires it.")
            }
            guard let current = rebuildControl?.status ?? rebuildStatus,
                arguments["jobID"] == nil || arguments["jobID"] as? String == current.jobID
            else {
                throw TractandaError("notFound", "No matching rebuild is available.")
            }
            if call.method == "TractandaStore/rebuildCancel" { try rebuildControl?.cancel() }
            return try rebuildResponse(call: call, status: rebuildControl?.status ?? current)
        } catch {
            let error =
                error as? TractandaError ?? TractandaError("invalidArguments", String(describing: error))
            return try JSONSerialization.data(withJSONObject: [
                "methodResponses": [
                    [
                        "error",
                        ["type": error.code, "description": error.message], call.callID,
                    ]
                ], "sessionState": rebuildSessionState,
            ])
        }
    }
    private func rebuildResponse(call: RebuildNativeCall, status: StoreRebuildStatus) throws -> Data {
        let value = try JSONSerialization.jsonObject(with: JSON.encode(status))
        return try JSONSerialization.data(withJSONObject: [
            "methodResponses": [[call.method, value, call.callID]],
            "sessionState": rebuildSessionState,
        ])
    }
    private func performRebuild(
        _ control: RebuildControl, uid: UInt32,
        hook: (@Sendable () async throws -> Void)?
    ) async {
        let watchdog = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    try control.cancel(code: "rebuildNoProgress", onlyIfStalled: true)
                } catch { return }
            }
        }
        var poolExclusive = false
        var failure: Error?
        do {
            // Fence finalization first, then join every accepted producer before marking a checkpoint.
            documentCancellation?.cancel()
            await drainDocumentJobs(reasonCode: "storeMaintenance")
            try await drainSemanticDocumentWork()
            let copies = attachmentCopyTasks.values.map(\.task)
            for task in copies { task.cancel() }
            for task in copies { await task.value }
            let originals = attachmentIntegrityTasks.values.map(\.task)
            for task in originals { task.cancel() }
            for task in originals { await task.value }
            await stopCanonicalVerificationForRebuild()
            try await readPool.beginExclusiveAndDrainAsync()
            poolExclusive = true
            try control.check()
            try await hook?()
            try control.check()
            try await submit { service in
                try service.store.withAccess(forUID: uid) { try service.store.rebuildIndex(control: control) }
            }
        } catch { failure = error }
        watchdog.cancel()
        let trusted = (try? await submit { $0.store.isCanonicalTrusted }) ?? false
        if trusted {
            do { try readPool.resumeAfterRebuild() } catch { failure = error }
        }
        if poolExclusive { readPool.endExclusive() }
        do { try control.finish(error: failure, indexTrusted: trusted) } catch {
            control.noteStatusPersistenceFailure()
        }
        rebuildStatus = control.status
        rebuildControl = nil
        rebuildTask = nil
        rebuildPolicy = nil
        exclusiveRebuildPending = false
        if accepting, trusted {
            startCanonicalVerification(every: verificationInterval)
            documentJobDraining = false
            try? await submit { $0.resumeSemanticDocumentWork() }
            await recoverDocumentJobsAtStartup()
        }
    }

    func setPreparedReadHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        preparedReadHookForTesting = hook
    }

    func setPooledReadLeaseHookForTesting(_ hook: (@Sendable () -> Void)?) {
        pooledReadLeaseHookForTesting = hook
    }

    func setPooledReadBeforeFinishHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        pooledReadBeforeFinishHookForTesting = hook
    }

    func setPooledHistoryAfterSnapshotHookForTesting(_ hook: (@Sendable () -> Void)?) {
        pooledHistoryAfterSnapshotHookForTesting = hook
    }

    func pooledReadLeaseCountForTesting() -> Int { readPool.activeLeaseCount }
    func pooledExclusiveWaitingForTesting() -> Bool { readPool.isExclusiveWaiting }

    func setPooledRecordByteLimitForTesting(_ limit: Int?) async throws {
        _ = try await submit { service in
            service.store.pooledRecordByteLimitForTesting = limit
        }
    }
    func setPooledHistoryBatchLimitForTesting(_ limit: Int?) async throws {
        _ = try await submit { service in
            service.store.pooledHistoryBatchLimitForTesting = limit
        }
    }

    func setVerificationScanHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        verificationScanHookForTesting = hook
    }

    public func accountIdentity(forUID uid: UInt32) async throws -> AccountIdentity {
        try beginWork()
        defer { finishWork() }
        if exclusiveRebuildPending, let policy = rebuildPolicy {
            return try policy.accountIfAdmitted(uid: uid, accounts: makeAccountDirectory())
        }
        return try await submit { service in try service.store.accountIdentity(forUID: uid) }
    }

    /// Startup metadata for the trusted listener, without impersonating a client account.
    public func localSocketPermissions() async throws -> UInt32 {
        try beginWork()
        defer { finishWork() }
        return try await submit { service in service.store.isMultiUser ? 0o666 : 0o600 }
    }

    /// Derived semantic work has no client identity and runs only between request scopes.
    public func maintain() async throws {
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "Maintenance pauses during exclusive rebuild.")
        }
        try beginWork()
        defer { finishWork() }
        _ = try await submit { service in
            service.maintainSemanticIndex()
            return ()
        }
    }

    func queueMaintenanceForTesting() async throws {
        try beginWork()
        defer { finishWork() }
        try await submit { service in service.maintainSemanticIndex() }
    }
    /// Starts periodic auditing only after daemon readiness. The detached scanner sees an
    /// immutable Sendable snapshot; all SQLite access and finding reconciliation use `queue`.
    public func startCanonicalVerification(every interval: Duration = .seconds(900)) {
        guard accepting, !exclusiveRebuildPending, verificationTask == nil else { return }
        verificationInterval = interval
        verificationTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.verifyCanonicalOnce()
                do { try await Task.sleep(for: interval) } catch { break }
            }
        }
    }

    private func stopCanonicalVerificationForRebuild() async {
        guard let running = verificationTask else { return }
        verificationTask = nil
        running.cancel()
        _ = await running.result
    }

    private func verifyCanonicalOnce() async {
        guard accepting else { return }
        do {
            try beginWork()
            defer { finishWork() }
            let snapshot = try await submit { service in
                let snapshot = try service.store.verificationSnapshot()
                try service.store.beginVerificationScan(generation: snapshot.generation)
                return snapshot
            }
            let hook = verificationScanHookForTesting
            let worker = Task.detached(priority: .background) { [self] in
                if let hook { await hook() }
                return await CanonicalVerifier.scan(snapshot) { findings in
                    try await self.submit { service in
                        try service.store.applyVerification(
                            findings, scannedGeneration: snapshot.generation)
                    }
                }
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            try await submit { service in
                service.store.finishVerificationScan(result, scannedGeneration: snapshot.generation)
            }
        } catch {
            guard !Task.isCancelled else { return }
            let message = String(describing: error)
            try? await submit { service in
                service.store.noteVerificationFailure(message)
            }
        }
    }

    func setAttachmentIntegrityHookForTesting(_ hook: (@Sendable () async throws -> Void)?) {
        attachmentIntegrityHookForTesting = hook
    }
    private func handleAttachmentIntegrity(_ request: Data, uid: UInt32) async throws -> Data {
        let generation = canonicalWorkGeneration
        let prepared: PreparedAttachmentIntegrityCall
        do {
            prepared = try await submit { try $0.prepareAttachmentIntegrityNativeCall(request, peerUID: uid) }
        } catch {
            try requireCanonicalGeneration(generation)
            return try await submit { $0.handle(request, peerUID: uid) }
        }
        try requireCanonicalGeneration(generation)
        if prepared.method == "TractandaAttachment/abort" {
            if let running = attachmentIntegrityTasks[prepared.key] {
                running.task.cancel()
                await running.task.value
            }
            try requireCanonicalGeneration(generation)
            attachmentIntegrityFailures.removeValue(forKey: prepared.key)
            return try await submit { $0.handle(request, peerUID: uid) }
        }
        if prepared.method == "TractandaAttachment/uploadStatus"
            || prepared.method == "TractandaAttachment/integrity"
        {
            let bytes = attachmentIntegrityTasks[prepared.key]?.progress.verifiedBytes ?? 0
            let failure = attachmentIntegrityFailures[prepared.key]
            return try await submit {
                try $0.attachmentIntegrityNativeResponse(
                    request, peerUID: uid, verifiedBytes: bytes, pending: false, failure: failure)
            }
        }
        if let code = attachmentIntegrityFailures[prepared.key] {
            return try await submit {
                try $0.attachmentIntegrityNativeResponse(
                    request, peerUID: uid, verifiedBytes: 0, pending: false, failure: code)
            }
        }
        if let work = prepared.work {
            if attachmentIntegrityTasks[prepared.key] == nil, attachmentIntegrityTasks.count < 4, accepting {
                let progress = AttachmentIntegrityProgress()
                let hook = attachmentIntegrityHookForTesting
                let task = Task.detached(priority: .utility) { [self] in
                    let failureCode: String?
                    do {
                        try await hook?()
                        try work.perform(progress: progress)
                        failureCode = nil
                    } catch {
                        failureCode =
                            error is CancellationError
                            ? "cancelled" : (error as? TractandaError)?.code ?? "attachmentIntegrity"
                    }
                    await attachmentIntegrityCompleted(
                        key: prepared.key, work: work, failureCode: failureCode)
                }
                attachmentIntegrityTasks[prepared.key] = AttachmentIntegrityTask(
                    task: task, progress: progress)
            } else if attachmentIntegrityTasks[prepared.key] == nil, let id = work.uploadID {
                try await submit {
                    try $0.store.attachmentIntegrityFinished(uploadID: id, failureCode: "cancelled")
                }
            }
            let bytes = attachmentIntegrityTasks[prepared.key]?.progress.verifiedBytes ?? 0
            return try await submit {
                try $0.attachmentIntegrityNativeResponse(
                    request, peerUID: uid, verifiedBytes: bytes, pending: true)
            }
        }
        return try await submit { $0.handle(request, peerUID: uid) }
    }
    private func attachmentIntegrityCompleted(
        key: String, work: AttachmentIntegrityWork, failureCode: String?
    ) async {
        if let id = work.uploadID {
            do {
                try await submit {
                    try $0.store.attachmentIntegrityFinished(uploadID: id, failureCode: failureCode)
                }
            } catch { attachmentIntegrityFailures[key] = "attachmentRecoveryFailed" }
        } else if let failureCode, failureCode != "cancelled" {
            // Bounded negative cache prevents repeated hashing of an unchanged corrupt original.
            if attachmentIntegrityFailures.count >= 128 { attachmentIntegrityFailures.removeAll() }
            attachmentIntegrityFailures[key] = failureCode
        }
        attachmentIntegrityTasks.removeValue(forKey: key)
    }

    func setAttachmentCopyHookForTesting(_ hook: (@Sendable () async throws -> Void)?) {
        attachmentCopyHookForTesting = hook
    }
    private func handleAttachmentCopy(_ request: Data, uid: UInt32) async throws -> Data {
        let generation = canonicalWorkGeneration
        let call: PreparedCopyCall
        do { call = try await submit { try $0.prepareAttachmentCopyNativeCall(request, peerUID: uid) } } catch
        {
            try requireCanonicalGeneration(generation)
            return try await submit { $0.handle(request, peerUID: uid) }
        }
        try requireCanonicalGeneration(generation)
        switch call.admission {
        case .replay(let result):
            return try await submit {
                try $0.attachmentCopyNativeResponse(callID: call.callID, result: result, peerUID: uid)
            }
        case .prepared(let work):
            let key = work.plan.key
            if let result = attachmentCopyResults[key] {
                switch result {
                case .success(let prepared):
                    try requireCanonicalGeneration(generation)
                    return try await submit {
                        try $0.finishAttachmentCopyNativeCall(
                            callID: call.callID, prepared: prepared, peerUID: uid)
                    }
                case .failure(let error):
                    return try await submit {
                        try $0.attachmentCopyPending(
                            callID: call.callID, plan: work.plan, bytes: 0, peerUID: uid, failure: error)
                    }
                }
            }
            if attachmentCopyTasks[key] == nil {
                guard attachmentCopyTasks.isEmpty else {
                    throw TractandaError("serviceBusy", "One bounded attachment copy is already running.")
                }
                let progress = AttachmentIntegrityProgress()
                let hook = attachmentCopyHookForTesting
                let task = Task.detached(priority: .utility) { [self] in
                    let result: Result<PreparedAttachmentCopy, TractandaError>
                    do {
                        try await hook?()
                        result = .success(try work.perform(progress: progress))
                    } catch {
                        result = .failure(
                            error as? TractandaError
                                ?? TractandaError(
                                    error is CancellationError ? "cancelled" : "attachmentIntegrity",
                                    String(describing: error)))
                    }
                    await attachmentCopyCompleted(key: key, result: result)
                }
                attachmentCopyTasks[key] = AttachmentCopyTask(task: task, progress: progress)
            }
            let bytes = attachmentCopyTasks[key]?.progress.verifiedBytes ?? 0
            return try await submit {
                try $0.attachmentCopyPending(callID: call.callID, plan: work.plan, bytes: bytes, peerUID: uid)
            }
        }
    }
    private func attachmentCopyCompleted(key: String, result: Result<PreparedAttachmentCopy, TractandaError>)
    {
        attachmentCopyTasks.removeValue(forKey: key)
        if case .failure(let error) = result, error.code == "cancelled" { return }
        if attachmentCopyResults.count >= 8 { attachmentCopyResults.removeAll() }
        attachmentCopyResults[key] = result
    }

    /// Internal shutdown signal before consumers wait on Store-backed maintenance. This only
    /// requests cooperative stops; close() retains writer ownership through all accepted drains.
    public func requestBackgroundStop() {
        try? rebuildControl?.cancel()
        documentCancellation?.cancel()
        documentJobCancellation?.cancel()
        for work in extractedUnitTasks.values { work.task.cancel() }
        for work in attachmentCopyTasks.values { work.task.cancel() }
        for work in attachmentIntegrityTasks.values { work.task.cancel() }
        verificationTask?.cancel()
    }
    /// Stops future admission, drains already accepted queue entries, and releases the writer lock.
    public func close() async {
        guard accepting else { return }
        accepting = false
        documentJobDraining = true
        documentJobCancellation?.cancel()
        await documentJobStartupRecovery?.value
        await drainDocumentJobs(reasonCode: "serverShutdown")
        do {
            try await drainSemanticDocumentWork(retireMetadata: false)
        } catch {
            FileHandle.standardError.write(Data("Tractanda reader drain failed: \(error)\n".utf8))
            return
        }
        // Fenced pending lease metadata remains charged/durable for exclusive startup reclamation.
        try? rebuildControl?.cancel()
        await rebuildTask?.value
        documentCancellation?.cancel()
        let copyTasks = attachmentCopyTasks.values.map(\.task)
        for task in copyTasks { task.cancel() }
        for task in copyTasks { await task.value }
        let integrityTasks = attachmentIntegrityTasks.values.map(\.task)
        for task in integrityTasks { task.cancel() }
        for task in integrityTasks { await task.value }
        verificationTask?.cancel()
        _ = await verificationTask?.result
        verificationTask = nil
        while pending > 0 {
            await withCheckedContinuation { closeWaiters.append($0) }
        }
        do {
            try await readPool.shutdownAsync()
        } catch {
            FileHandle.standardError.write(Data(("Tractanda read-pool close failed: \(error)\n").utf8))
            return
        }
        await core.close()
    }

    private func beginWork() throws {
        guard accepting else { throw TractandaError("serviceClosed", "The shared service is closed.") }
        guard pending < Self.maximumPending else {
            throw TractandaError("serviceBusy", "The shared service request queue is full.")
        }
        pending += 1
    }

    private func finishWork() {
        pending -= 1
        guard pending == 0 else { return }
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func requireCanonicalGeneration(_ generation: UInt64) throws {
        guard !exclusiveRebuildPending, generation == canonicalWorkGeneration else {
            throw TractandaError(
                "serviceBusy", "Rebuild fenced earlier background work; retry after completion.")
        }
    }
    private func submit<T: Sendable>(_ body: @escaping @Sendable (ItemService) throws -> T) async throws -> T
    {
        try await core.submit(body)
    }

    private func evaluatePooled<T: Sendable>(
        _ work: @escaping @Sendable (SQLiteReadCancellation) throws -> T
    ) async -> T? {
        let cancellation = SQLiteReadCancellation()
        let worker = Task.detached(priority: .userInitiated) { try work(cancellation) }
        return try? await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }
}

/// The only unchecked boundary. ItemService and ItemStore never leave `queue`.
private final class CoreBox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.tractanda.service-coordinator")
    private var service: ItemService?
    let readPool: SQLiteReadPool

    init(
        root: URL, indexDirectory: URL?, accounts: any AccountDirectory,
        documentConverter: DocumentConverterConfiguration?, attachmentUploadPolicy: AttachmentUploadPolicy,
        embeddingProviderForTesting: (
            @Sendable (SemanticConfiguration, [String], Bool) async throws -> [[Double]]
        )? = nil
    ) throws {
        let store = try ItemStore(
            root: root, indexDirectory: indexDirectory, accounts: accounts,
            attachmentUploadPolicy: attachmentUploadPolicy)
        if let embeddingProviderForTesting {
            guard documentConverter == nil else {
                throw TractandaError(
                    "invalidArguments", "Semantic test injection cannot configure a document process.")
            }
            service = ItemService(
                store: store, extractedTextUnitRouting: true,
                embeddingProviderForTesting: embeddingProviderForTesting)
        } else if let documentConverter {
            service = try ItemService(
                store: store, documentConverter: documentConverter, extractedTextUnitRouting: true)
        } else {
            service = ItemService(store: store, extractedTextUnitRouting: true)
        }
        service?.requiresAsyncAttachmentIntegrity = true
        service?.requiresAsyncDocumentJobs = true
        readPool = try SQLiteReadPool(
            databaseURL: store.indexDirectory.appendingPathComponent("items.sqlite"))
    }

    func submit<T: Sendable>(_ body: @escaping @Sendable (ItemService) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let service else {
                    continuation.resume(
                        throwing: TractandaError("serviceClosed", "The shared service is closed."))
                    return
                }
                do {
                    continuation.resume(returning: try body(service))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Only detached producer boundaries outside a held SQLite transaction call this method.
    func synchronously<T>(_ body: (ItemService) throws -> T) throws -> T {
        try queue.sync {
            guard let service else { throw TractandaError("serviceClosed", "The shared service is closed.") }
            return try body(service)
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                service = nil
                continuation.resume()
            }
        }
    }
}
