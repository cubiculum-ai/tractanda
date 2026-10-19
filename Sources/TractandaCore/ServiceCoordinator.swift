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
    private let privateCredentialOwner = UUID()
    private var privateCredentialAdmissions: [UUID: PeerExchangeControl] = [:]
    private var privateCredentialCommitting = Set<UUID>()
    private let privateEnrollmentOwner = UUID()
    private var privateEnrollmentAdmissions: [UUID: PeerExchangeControl] = [:]
    private var privateEnrollmentCommitting = Set<UUID>()
    private var privateEnrollmentCompleted = Set<UUID>()
    private var privateEnrollmentPreparedHookForTesting: (@Sendable () async -> Void)?
    private let peerRuntimeSnapshotOwner = UUID()
    private var peerRuntimeStopped = false
    private var peerRuntimeSnapshotDeliveryHookForTesting: (@Sendable () async -> Void)?
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
    private let documentRuntimeVerifier: DocumentRuntimeVerifier
    private var documentJobAdmissions: [DocumentJobAdmission] = []
    private var documentJobTask: Task<Void, Never>?
    private var documentJobCancellation: DocumentConversionCancellation?
    private var activeDocumentJobID: String?
    private var documentJobDraining = false
    private var documentJobPublicationHookForTesting: (@Sendable () async -> Void)?
    private var documentJobAdmissionHookForTesting: (@Sendable () async -> Void)?
    private var documentJobIndexHookForTesting: (@Sendable (IndexCorpusWriteBatch) throws -> Void)?
    private var rebuildAdmissionHookForTesting: (@Sendable () async -> Void)?
    private var documentJobStartupRecovery: Task<Void, Never>?
    private var documentJobStartupRecoveryFinished = false
    private var peerClockLease: PeerClockRuntimeLease?
    private var peerClockStopped = false
    private let peerClockIntakeEnabled: Bool
    private var preparedReadHookForTesting: (@Sendable () async -> Void)?
    private var pooledReadLeaseHookForTesting: (@Sendable () -> Void)?
    private var pooledReadBeforeFinishHookForTesting: (@Sendable () async -> Void)?
    private var pooledHistoryAfterSnapshotHookForTesting: (@Sendable () -> Void)?
    private var verificationScanHookForTesting: (@Sendable () async -> Void)?
    private var peerExchangeFailureHookForTesting: (@Sendable (TractandaError) -> Void)?
    private var peerExchangeAuthorizationHookForTesting: (@Sendable () async -> Void)?
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
            opening: root, embeddingProviderForTesting: nil, requireInitializedStore: true,
            indexDirectory: indexDirectory,
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
        requireInitializedStore: Bool = false,
        indexDirectory: URL? = nil,
        documentRuntimeVerifierForTesting: DocumentRuntimeVerifier? = nil,
        documentConverter: DocumentConverterConfiguration? = nil,
        documentJobResources: DocumentJobResources = DocumentJobResources(),
        attachmentUploadPolicy: AttachmentUploadPolicy = AttachmentUploadPolicy(),
        rebuildNoProgressTimeoutSeconds: Double = 120,
        revisionProjectionEnabledForTesting: Bool = false,
        authorityIntakeEnabledForTesting: Bool = false,
        makeAccountDirectory: @escaping @Sendable () -> any AccountDirectory = { SystemAccountDirectory() }
    ) async throws {
        guard rebuildNoProgressTimeoutSeconds.isFinite, rebuildNoProgressTimeoutSeconds > 0 else {
            throw TractandaError(
                "invalidConfiguration", "Rebuild no-progress timeout must be positive and finite.")
        }
        self.documentJobBudgets = try documentJobResources.budgets()
        self.documentRuntimeVerifier =
            documentRuntimeVerifierForTesting ?? DocumentNativeSession.verifyRuntime
        self.rebuildNoProgressSeconds = rebuildNoProgressTimeoutSeconds
        let opened: CoreBox = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try CoreBox(
                            root: root, indexDirectory: indexDirectory, accounts: makeAccountDirectory(),
                            documentConverter: documentConverter,
                            attachmentUploadPolicy: attachmentUploadPolicy,
                            embeddingProviderForTesting: embeddingProviderForTesting,
                            revisionProjectionEnabled: revisionProjectionEnabledForTesting,
                            authorityIntakeEnabled: authorityIntakeEnabledForTesting,
                            requireInitializedStore: requireInitializedStore))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        peerClockIntakeEnabled = requireInitializedStore || authorityIntakeEnabledForTesting
        core = opened
        readPool = opened.readPool
        self.makeAccountDirectory = makeAccountDirectory
        let journal = RebuildJournal(
            root: root.standardizedFileURL.resolvingSymlinksInPath(), ownerUID: tractanda_uid())
        rebuildJournal = journal
        rebuildStatus = try journal.recoverInterrupted(indexTrusted: true)
        documentJobStartupRecovery = Task { [self] in
            await recoverDocumentJobsAtStartup()
            documentJobStartupRecoveryFinished = true
        }
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
                budgets: documentJobBudgets, cancellation: cancellation,
                runtimeVerifier: documentRuntimeVerifier)
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

    func waitForDocumentProducerForTesting() async {
        await documentJobTask?.value
    }

    func setRebuildAdmissionHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        rebuildAdmissionHookForTesting = hook
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
                // Pause producer failure publication atomically with the generation fence.
                // Otherwise a producer can persist serviceBusy before the async drain starts.
                exclusiveRebuildPending = true
                for control in privateCredentialAdmissions.values { control.cancel() }
                for control in privateEnrollmentAdmissions.values { control.cancel() }
                documentJobDraining = true
                documentJobCancellation?.cancel()
                canonicalWorkGeneration += 1
                await rebuildAdmissionHookForTesting?()
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
    func setRebuildGraphProgressHookForTesting(_ hook: (@Sendable () throws -> Void)?) async throws {
        try await submit { service in service.store.revisionGraphProgressForTesting = hook }
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

    /// Runtime-only bridge; no native request or daemon option exposes cluster enablement.
    public struct PeerClockRuntimeLease: Sendable {
        public let configuration: PeerClockHealth.Configuration
        fileprivate let id: UUID
        fileprivate let context: String
        fileprivate let control: PeerClockRuntimeControl

        /// Invalid for any real coordinator; permits local monitor tests without Store authority.
        static func forTesting(configuration: PeerClockHealth.Configuration) -> Self {
            Self(
                configuration: configuration, id: UUID(), context: "test-only",
                control: PeerClockRuntimeControl())
        }
    }

    private var peerClockIsIdle: Bool {
        accepting && !peerClockStopped && pending == 0 && !exclusiveRebuildPending
            && rebuildTask == nil && documentJobStartupRecoveryFinished
            && documentJobAdmissions.isEmpty && documentJobTask == nil && !documentJobDraining
            && !semanticLifecyclePending && extractedUnitAdmissions == 0
            && extractedUnitTasks.isEmpty && extractedUnitWaiters.isEmpty && !extractedUnitDraining
            && attachmentCopyTasks.isEmpty && attachmentIntegrityTasks.isEmpty
    }

    /// Tick admission is cheap when intake is disabled. Queue-owned configuration and health
    /// never escape; a second idle check after the queue hop is the probe launch boundary.
    public func preparePeerClockSample(
        monotonicNow: Double, interval: Double,
        configuration: PeerClockHealth.Configuration = .init()
    ) async throws -> PeerClockRuntimeLease? {
        guard peerClockIntakeEnabled, peerClockLease == nil, peerClockIsIdle else { return nil }
        let prepared = try await submit { service in
            try service.store.preparePeerClockSample(
                monotonicNow: monotonicNow, interval: interval, configuration: configuration)
        }
        guard peerClockLease == nil, peerClockIsIdle, let prepared else { return nil }
        let lease = PeerClockRuntimeLease(
            configuration: prepared.1, id: UUID(), context: prepared.0, control: PeerClockRuntimeControl())
        peerClockLease = lease
        return lease
    }

    public func finishPeerClockSample(
        _ lease: PeerClockRuntimeLease, sample: PeerClockHealth.Sample?,
        monotonicNow: Double, nextInterval: Double
    ) async throws {
        guard accepting, !peerClockStopped, peerClockLease?.id == lease.id else { return }
        defer { if peerClockLease?.id == lease.id { peerClockLease = nil } }
        // This queue hop is sequenced before close's final queue drain. The Store rechecks
        // actual eligibility/configuration; an ordinary concurrent request need not cancel it.
        try await submit { service in
            try lease.control.withActive {
                try service.store.finishPeerClockSample(
                    context: lease.context, sample: sample, monotonicNow: monotonicNow,
                    nextInterval: nextInterval)
            }
        }
    }

    func peerClockHealthForTesting() async throws -> PeerClockHealth? {
        try await submit { $0.store.peerClockHealth }
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
        peerRuntimeStopped = true
        peerClockStopped = true
        peerClockLease?.control.cancel()
        peerClockLease = nil
        try? rebuildControl?.cancel()
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
        for control in privateCredentialAdmissions.values { control.cancel() }
        for control in privateEnrollmentAdmissions.values { control.cancel() }
        peerRuntimeStopped = true
        peerClockStopped = true
        peerClockLease?.control.cancel()
        peerClockLease = nil
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

    /// Called only by the OS-authenticated native status adapter, never generic method dispatch.
    package func peerOperatorCanonicalStatus(forUID uid: UInt32) async throws -> PeerCanonicalStatus {
        try Task.checkCancellation()
        let generation = canonicalWorkGeneration
        try requireCanonicalGeneration(generation)
        try beginWork()
        defer { finishWork() }
        let result = try await submit { service in
            try service.store.withAccess(forUID: uid) { try service.store.peerOperatorCanonicalStatus() }
        }
        try requireCanonicalGeneration(generation)
        try Task.checkCancellation()
        return result
    }

    /// Host-only, package-internal seams; no service/CLI route or default activation.
    package func beginNativeCredentialRegistration(
        _ request: NativePeerCredentialRegistration.Begin,
        forUID uid: UInt32, control: PeerExchangeControl
    ) async throws -> PeerCredentialRegistrationAdmission {
        try control.check()
        try Task.checkCancellation()
        let generation = canonicalWorkGeneration
        try requireCanonicalGeneration(generation)
        guard privateCredentialAdmissions.count + privateEnrollmentAdmissions.count < Self.maximumPending
        else {
            throw TractandaError("serviceBusy", "Private credential admission is full.")
        }
        try beginWork()
        defer { finishWork() }
        let id = UUID()
        privateCredentialAdmissions[id] = control
        do {
            let token = try await submit { service in
                try control.check()
                return try service.store.withAccess(forUID: uid) {
                    try service.store.nativeCredentialRegistrationContext()
                }
            }
            guard accepting else { throw TractandaError("serviceClosed", "The service is closed.") }
            try requireCanonicalGeneration(generation)
            try control.check()
            try Task.checkCancellation()
            return .init(
                id: id, owner: privateCredentialOwner, uid: uid, generation: generation,
                context: token, request: request, control: control)
        } catch {
            privateCredentialAdmissions.removeValue(forKey: id)
            control.cancel()
            throw error
        }
    }
    package func cancelNativeCredentialRegistration(_ admission: PeerCredentialRegistrationAdmission) {
        guard admission.owner == privateCredentialOwner else { return }
        privateCredentialAdmissions[admission.id]?.cancel()
        if !privateCredentialCommitting.contains(admission.id) {
            privateCredentialAdmissions.removeValue(forKey: admission.id)
        }
    }
    package func finishNativeCredentialRegistration(
        _ admission: PeerCredentialRegistrationAdmission,
        input: PeerPrivateCredentialInput
    ) async throws -> Data {
        guard admission.owner == privateCredentialOwner,
            privateCredentialAdmissions[admission.id] === admission.control,
            !privateCredentialCommitting.contains(admission.id)
        else {
            throw TractandaError("privateCredentialProtocol", "Private admission is no longer current.")
        }
        try requireCanonicalGeneration(admission.generation)
        try admission.control.check()
        try Task.checkCancellation()
        try beginWork()
        privateCredentialCommitting.insert(admission.id)
        defer {
            privateCredentialAdmissions.removeValue(forKey: admission.id)
            privateCredentialCommitting.remove(admission.id)
            finishWork()
        }
        return try await withTaskCancellationHandler {
            try await submit { service in
                try admission.control.check()
                return try service.store.withAccess(forUID: admission.uid) {
                    _ = try service.store.nativeCredentialRegistrationContext()
                    guard input.count == admission.request.byteCount else {
                        throw NativePeerCredentialRegistration.protocolFailure()
                    }
                    let credential = try input.withBytes { data in
                        do { return try PeerCredential.decode(data) } catch {
                            throw TractandaError("invalidPeerCredential", "Private credential is invalid.")
                        }
                    }
                    try admission.control.check()  // Last cancellation boundary before synchronous mutation.
                    try service.store.registerNativePeerCredential(
                        credential,
                        permittedOrigins: admission.request.permittedOrigins,
                        expectedContextToken: admission.context, operationID: admission.request.operationID)
                    return try JSON.encode(NativePeerCredentialRegistration.Result(registered: true))
                }
            }
        } onCancel: {
            admission.control.cancel()
        }
    }

    package func peerCredentialRegistrationContext(forUID uid: UInt32) async throws -> String {
        try beginWork()
        defer { finishWork() }
        return try await submit { service in
            try service.store.withAccess(forUID: uid) {
                try service.store.requirePeerCredentialAdministrator()
                return try service.store.peerIntakeContextToken()
            }
        }
    }
    package func registerPeerCredential(
        _ credential: PeerCredential, permittedOrigins: [String], expectedContextToken: String,
        operationID: String, forUID uid: UInt32
    ) async throws {
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "Store rebuild is pending.")
        }
        try beginWork()
        defer { finishWork() }
        try await submit { service in
            try service.store.withAccess(forUID: uid) {
                let binding = credential.binding
                let context = try PeerPackage.Context(
                    peerID: binding.peerID, storeID: binding.storeID,
                    configurationDigest: binding.configurationDigest, permittedOrigins: permittedOrigins)
                try service.store.registerPeerCredential(
                    credential, context: context,
                    expectedContextToken: expectedContextToken, operationID: operationID)
            }
        }
    }
    package func loadPeerCredential(peerID: String) async throws -> PeerCredential {
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "Store rebuild is pending.")
        }
        try beginWork()
        defer { finishWork() }
        return try await submit { try $0.store.loadPeerCredential(peerID: peerID) }
    }

    /// Host-private runtime bridge. A snapshot must be validated again before later admission.
    package func loadPeerRuntimeSnapshot() async throws -> PeerRuntimeSnapshot {
        try await preparePeerRuntimeSnapshot(expected: nil)
    }
    package func validatePeerRuntimeSnapshot(_ snapshot: PeerRuntimeSnapshot) async throws {
        _ = try await preparePeerRuntimeSnapshot(expected: snapshot)
    }
    private func preparePeerRuntimeSnapshot(expected: PeerRuntimeSnapshot?) async throws
        -> PeerRuntimeSnapshot
    {
        guard accepting, !peerRuntimeStopped else {
            throw TractandaError("serviceClosed", "The peer runtime is stopped.")
        }
        let generation = canonicalWorkGeneration
        if let expected {
            try expected.requireOwner(peerRuntimeSnapshotOwner)
            try requireCanonicalGeneration(expected.canonicalGeneration)
        }
        try requireCanonicalGeneration(generation)
        try beginWork()
        defer { finishWork() }
        let control = try PeerExchangeControl()
        return try await withTaskCancellationHandler {
            let loaded = try await submit { try $0.store.peerRuntimeMaterial(progress: control.check) }
            await peerRuntimeSnapshotDeliveryHookForTesting?()
            guard accepting, !peerRuntimeStopped else {
                throw TractandaError("serviceClosed", "The peer runtime is stopped.")
            }
            try requireCanonicalGeneration(generation)
            try control.check()
            let material = expected?.material ?? loaded
            // A queued policy/credential change can precede result delivery. Revalidate the
            // exact private bytes and security state, never just cached metadata possession.
            try await submit { try $0.store.validatePeerRuntimeMaterial(material, progress: control.check) }
            guard accepting, !peerRuntimeStopped else {
                throw TractandaError("serviceClosed", "The peer runtime is stopped.")
            }
            try requireCanonicalGeneration(generation)
            try control.check()
            return PeerRuntimeSnapshot(
                material: material, owner: peerRuntimeSnapshotOwner,
                canonicalGeneration: generation)
        } onCancel: {
            control.cancel()
        }
    }
    func setPeerRuntimeSnapshotDeliveryHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        peerRuntimeSnapshotDeliveryHookForTesting = hook
    }

    func peerSyncWork(
        state: PeerExchangeState, replacement: PeerSyncWork?,
        control: PeerExchangeControl
    ) async throws -> PeerSyncWork {
        let generation = canonicalWorkGeneration
        try requireCanonicalGeneration(generation)
        try beginWork()
        defer { finishWork() }
        let result = try await submit { service in
            try service.store.withPeerExchange(
                binding: state.binding,
                expectedSecurity: state.securityBinding,
                progress: {
                    try control.check()
                    try state.compatibility.requireLifetime()
                }
            ) { _, security in
                try state.compatibility.requireAdmission(store: service.store, storeID: state.binding.storeID)
                return try service.store.peerSyncWork(
                    binding: state.binding, security: security, replacement: replacement)
            }
        }
        try requireCanonicalGeneration(generation)
        try control.check()
        try state.compatibility.requireLifetime()
        return result
    }

    func openPeerExchange(_ binding: PeerExchangeBinding, control: PeerExchangeControl) async throws
        -> PeerExchangeState
    {
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "A store rebuild is draining accepted work.")
        }
        try beginWork()
        defer { finishWork() }
        return try await submit { service in
            try service.store.withPeerExchange(binding: binding, progress: control.check) { _, security in
                PeerExchangeState(binding: binding, securityBinding: security)
            }
        }
    }

    func adoptPeerCompatibility(
        _ admission: PeerCompatibilityAdmission, expectedBinding: PeerExchangeBinding,
        state: PeerExchangeState, control: PeerExchangeControl
    ) async throws -> PeerExchangeState {
        try admission.requireBinding(expectedBinding)
        guard expectedBinding == state.binding, state.compatibility.local == nil,
            state.compatibility.remote == nil, !state.compatibility.acknowledged
        else { throw PeerExchangeCompatibility.invalid() }
        await peerExchangeAuthorizationHookForTesting?()
        let generation = canonicalWorkGeneration
        try requireCanonicalGeneration(generation)
        try control.check()
        try admission.checkLifetime()
        try beginWork()
        defer { finishWork() }
        let next = try await submit { service in
            try service.store.withPeerExchange(
                binding: state.binding, expectedSecurity: state.securityBinding,
                progress: {
                    try control.check()
                    try admission.checkLifetime()
                }
            ) { _, _ in
                try admission.compatibility.requireAdmission(
                    store: service.store, storeID: state.binding.storeID)
                var next = state
                next.compatibility = admission.compatibility
                return next
            }
        }
        try requireCanonicalGeneration(generation)
        try control.check()
        try admission.checkLifetime()
        return next
    }
    func advancePeerCompatibility(
        _ action: PeerCompatibilityAction, state: PeerExchangeState,
        control: PeerExchangeControl
    ) async throws -> PeerExchangeStep {
        let generation = canonicalWorkGeneration
        try requireCanonicalGeneration(generation)
        try control.check()
        try beginWork()
        defer { finishWork() }
        let result = try await submit { service in
            try service.store.withPeerExchange(
                binding: state.binding,
                expectedSecurity: state.securityBinding, progress: control.check
            ) { _, _ in
                var next = state
                let response = try next.compatibility.advance(
                    action, store: service.store, storeID: state.binding.storeID)
                try control.check()
                return PeerExchangeStep(state: next, response: response)
            }
        }
        try requireCanonicalGeneration(generation)
        try control.check()
        return result
    }
    func authorizePeerExchange(_ state: PeerExchangeState, control: PeerExchangeControl) async throws {
        await peerExchangeAuthorizationHookForTesting?()
        let generation = canonicalWorkGeneration
        try requireCanonicalGeneration(generation)
        try beginWork()
        defer { finishWork() }
        try await submit { service in
            try service.store.withPeerExchange(
                binding: state.binding, expectedSecurity: state.securityBinding,
                progress: {
                    try control.check()
                    try state.compatibility.requireLifetime()
                }
            ) { _, _ in
                try state.compatibility.requireAdmission(store: service.store, storeID: state.binding.storeID)
            }
        }
        try requireCanonicalGeneration(generation)
        try control.check()
        try state.compatibility.requireLifetime()
    }

    func releasePeerLogicalVerification(_ owner: String) async {
        _ = try? await submit { $0.store.releasePeerLogicalVerification(owner) }
    }
    func performPeerExchange(
        _ request: Data, state: PeerExchangeState, control: PeerExchangeControl, scanLimit: Int = 128
    ) async throws -> PeerExchangeStep {
        let generation = canonicalWorkGeneration
        try requireCanonicalGeneration(generation)
        try beginWork()
        defer { finishWork() }
        let result: PeerExchangeStep
        do {
            result = try await submit { service in
                try control.check()
                return try service.store.withPeerExchange(
                    binding: state.binding, expectedSecurity: state.securityBinding,
                    progress: {
                        try control.check()
                        try state.compatibility.requireLifetime()
                    }
                ) { context, _ in
                    var next = state
                    let decoded = try PeerPackage.decode(
                        PeerExchangeRequest.self, request, maximum: 2 * 1024 * 1024)
                    let slot =
                        decoded.operation == "needsTransfer"
                        ? "comparison"
                        : decoded.operation.hasPrefix("export") ? "export" : "intake"
                    let owner = state.logicalOwner.map { $0 + ":" + slot }
                    let response = try service.store.withPeerLogicalVerification(owner) {
                        try next.perform(
                            request, store: service.store, context: context, control: control,
                            scanLimit: scanLimit)
                    }
                    return PeerExchangeStep(state: next, response: response)
                }
            }
        } catch {
            if let error = error as? TractandaError { peerExchangeFailureHookForTesting?(error) }
            throw error
        }
        try requireCanonicalGeneration(generation)
        try control.check()
        try state.compatibility.requireLifetime()
        return result
    }
    func setPeerExchangeFailureHookForTesting(_ hook: (@Sendable (TractandaError) -> Void)?) {
        peerExchangeFailureHookForTesting = hook
    }
    func setPeerExchangeAuthorizationHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        peerExchangeAuthorizationHookForTesting = hook
    }
    func removePeerIntakeForTesting(
        peerID: String, origins: [String], operationID: String,
        forUID uid: UInt32? = nil
    ) async throws {
        try await submit { service in
            try service.store.withAccess(forUID: uid ?? service.store.ownerUID) {
                try service.store.removePeerIntake(
                    peerID: peerID, retiredOriginIDs: origins, operationID: operationID)
            }
        }
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

/// A tiny synchronous fence shared with the Store owner, invalidated before shutdown drains.
private final class PeerClockRuntimeControl: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func cancel() {
        lock.lock()
        active = false
        lock.unlock()
    }
    func withActive(_ body: () throws -> Void) rethrows {
        lock.lock()
        defer { lock.unlock() }
        if active { try body() }
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
        )? = nil, revisionProjectionEnabled: Bool = false, authorityIntakeEnabled: Bool = false,
        requireInitializedStore: Bool = false
    ) throws {
        let store: ItemStore
        if requireInitializedStore {
            store = try ItemStore.openInitialized(
                root: root, indexDirectory: indexDirectory, accounts: accounts,
                attachmentUploadPolicy: attachmentUploadPolicy)
        } else {
            store = try ItemStore(
                root: root, indexDirectory: indexDirectory, accounts: accounts,
                attachmentUploadPolicy: attachmentUploadPolicy,
                revisionProjectionEnabled: revisionProjectionEnabled,
                authorityIntakeEnabled: authorityIntakeEnabled)
        }
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

extension ServiceCoordinator {
    /// Trusted host-only enrollment seams. The real caller's UID is resolved on the serial owner;
    /// no wire request, listener or ordinary peer registration route invokes these operations.
    func beginPeerEnrollment(_ request: PeerEnrollmentApproval.Request, forUID uid: UInt32) async throws
        -> PeerEnrollmentApproval.Handle
    {
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "Store rebuild is pending.")
        }
        try beginWork()
        defer { finishWork() }
        return try await submit { try $0.store.beginPeerEnrollment(request, forUID: uid) }
    }
    func stepPeerEnrollment(_ handle: PeerEnrollmentApproval.Handle, forUID uid: UInt32) async throws
        -> PeerEnrollmentApproval.Status
    {
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "Store rebuild is pending.")
        }
        try beginWork()
        defer { finishWork() }
        return try await submit { try $0.store.stepPeerEnrollment(handle, forUID: uid) }
    }
    func acceptPeerEnrollment(_ handle: PeerEnrollmentApproval.Handle, forUID uid: UInt32) async throws
        -> PeerEnrollmentApproval.Status
    {
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "Store rebuild is pending.")
        }
        try beginWork()
        defer { finishWork() }
        return try await submit { try $0.store.acceptPeerEnrollment(handle, forUID: uid) }
    }
    func readPeerEnrollment(
        _ handle: PeerEnrollmentApproval.Handle, object: PeerPackage.Object,
        offset: Int, maximumBytes: Int, forUID uid: UInt32
    ) async throws -> PeerExportPlan.Chunk {
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "Store rebuild is pending.")
        }
        try beginWork()
        defer { finishWork() }
        return try await submit {
            try $0.store.readPeerEnrollment(
                handle, object: object,
                offset: offset, maximumBytes: maximumBytes, forUID: uid)
        }
    }
}

extension ServiceCoordinator {
    func peerEnrollmentActivationMaterial(_ handle: PeerEnrollmentApproval.Handle, forUID uid: UInt32)
        async throws
        -> PeerEnrollmentActivation.Material
    {
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "Store rebuild is pending.")
        }
        try beginWork()
        defer { finishWork() }
        return try await submit { try $0.store.peerEnrollmentActivationMaterial(handle, forUID: uid) }
    }
    func registerAcceptedPeerEnrollment(_ handle: PeerEnrollmentApproval.Handle, forUID uid: UInt32)
        async throws
    {
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "Store rebuild is pending.")
        }
        try beginWork()
        defer { finishWork() }
        try await submit { try $0.store.registerAcceptedPeerEnrollment(handle, forUID: uid) }
    }
}

extension ServiceCoordinator {
    func setNativeEnrollmentPreparedHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        privateEnrollmentPreparedHookForTesting = hook
    }
    package func beginNativeEnrollment(
        _ request: NativePeerEnrollment.PrivateRequest,
        forUID uid: UInt32, control: PeerExchangeControl
    ) async throws -> PeerNativeEnrollmentAdmission {
        try control.check()
        try Task.checkCancellation()
        let generation = canonicalWorkGeneration
        try requireCanonicalGeneration(generation)
        guard privateCredentialAdmissions.count + privateEnrollmentAdmissions.count < Self.maximumPending
        else {
            throw TractandaError("serviceBusy", "Private operator admission is full.")
        }
        try beginWork()
        defer { finishWork() }
        let id = UUID()
        privateEnrollmentAdmissions[id] = control
        do {
            let output: PeerEnrollmentTargetOutput? = try await submit { service in
                try control.check()
                if request.operation == .exportTarget {
                    return try service.store.nativeEnrollmentExport(request.operationID, forUID: uid)
                }
                try service.store.nativeEnrollmentPreflight(forUID: uid)
                return nil
            }
            guard accepting else { throw TractandaError("serviceClosed", "The service is closed.") }
            try requireCanonicalGeneration(generation)
            try control.check()
            try Task.checkCancellation()
            return .init(
                id: id, owner: privateEnrollmentOwner, uid: uid, generation: generation,
                request: request, control: control, output: output)
        } catch {
            privateEnrollmentAdmissions.removeValue(forKey: id)
            control.cancel()
            throw error
        }
    }
    package func cancelNativeEnrollment(_ admission: PeerNativeEnrollmentAdmission) {
        guard admission.owner == privateEnrollmentOwner else { return }
        privateEnrollmentAdmissions[admission.id]?.cancel()
        if !privateEnrollmentCommitting.contains(admission.id) {
            privateEnrollmentAdmissions.removeValue(forKey: admission.id)
            privateEnrollmentCompleted.remove(admission.id)
        }
    }
    package func finishNativeEnrollment(
        _ admission: PeerNativeEnrollmentAdmission,
        input: PeerEnrollmentPairInput?
    ) async throws -> Data {
        guard admission.owner == privateEnrollmentOwner,
            privateEnrollmentAdmissions[admission.id] === admission.control,
            !privateEnrollmentCommitting.contains(admission.id),
            !privateEnrollmentCompleted.contains(admission.id)
        else { throw NativePeerEnrollment.failure() }
        try requireCanonicalGeneration(admission.generation)
        try admission.control.check()
        try Task.checkCancellation()
        try beginWork()
        privateEnrollmentCommitting.insert(admission.id)
        var completed = false
        defer {
            privateEnrollmentCommitting.remove(admission.id)
            if completed, admission.request.operation == .exportTarget,
                (try? admission.control.check()) != nil
            {
                // Retained until the actual native child closes.
                privateEnrollmentCompleted.insert(admission.id)
            } else {
                privateEnrollmentAdmissions.removeValue(forKey: admission.id)
                privateEnrollmentCompleted.remove(admission.id)
            }
            finishWork()
        }
        return try await withTaskCancellationHandler {
            let result: Data = try await submit { service in
                try admission.control.check()
                if admission.request.operation == .begin {
                    guard let input, input.count == admission.request.byteCount,
                        try input.operationID == admission.request.operationID
                    else { throw NativePeerEnrollment.failure() }
                    return try JSON.encode(service.store.nativeEnrollmentBegin(input, forUID: admission.uid))
                }
                guard input == nil, let output = admission.output else {
                    throw NativePeerEnrollment.failure()
                }
                // Current author/security/private bytes are rehydrated after waiting, not a cached grant.
                let fresh = try service.store.nativeEnrollmentExport(
                    admission.request.operationID, forUID: admission.uid)
                guard output.withBytes({ previous in fresh.withBytes { $0 == previous } }) else {
                    throw NativePeerEnrollment.failure()
                }
                try admission.control.check()
                return output.withBytes { $0 }
            }
            if admission.request.operation == .exportTarget {
                await privateEnrollmentPreparedHookForTesting?()
            }
            try requireCanonicalGeneration(admission.generation)
            try admission.control.check()
            try Task.checkCancellation()
            if admission.request.operation == .begin {
                try await submit { service in
                    try admission.control.check()
                    try service.store.nativeEnrollmentValidateDelivery(
                        admission.request.operationID, forUID: admission.uid)
                }
                try requireCanonicalGeneration(admission.generation)
                try admission.control.check()
            }
            completed = true
            return result
        } onCancel: {
            admission.control.cancel()
        }
    }
    package func validateNativeEnrollmentExportDelivery(_ admission: PeerNativeEnrollmentAdmission)
        async throws
    {
        guard admission.owner == privateEnrollmentOwner,
            privateEnrollmentAdmissions[admission.id] === admission.control,
            privateEnrollmentCompleted.contains(admission.id), let previous = admission.output
        else { throw NativePeerEnrollment.failure() }
        try requireCanonicalGeneration(admission.generation)
        try admission.control.check()
        try Task.checkCancellation()
        try beginWork()
        defer { finishWork() }
        try await submit { service in
            try admission.control.check()
            let current = try service.store.nativeEnrollmentExport(
                admission.request.operationID, forUID: admission.uid)
            guard previous.withBytes({ before in current.withBytes { $0 == before } }) else {
                throw NativePeerEnrollment.failure()
            }
        }
        try requireCanonicalGeneration(admission.generation)
        try admission.control.check()
        try Task.checkCancellation()
    }
    package func nativeEnrollmentCall(_ call: PeerEnrollmentNativeCall, forUID uid: UInt32) async throws
        -> Data
    {
        try Task.checkCancellation()
        let generation = canonicalWorkGeneration
        try requireCanonicalGeneration(generation)
        try beginWork()
        defer { finishWork() }
        let result = try await submit { service in try service.store.nativeEnrollmentCall(call, forUID: uid) }
        try requireCanonicalGeneration(generation)
        try Task.checkCancellation()
        // Historical accepted acknowledgments retain Core's exact author/global-admin rule.
        if call.action != "accept" && call.action != "register" {
            try await submit { service in
                try service.store.nativeEnrollmentValidateDelivery(call.operationID, forUID: uid)
            }
            try requireCanonicalGeneration(generation)
            try Task.checkCancellation()
        }
        return result
    }
}
