import Dispatch
import Foundation
import TractandaClient

/// Owns the one mutable store/service pair used by all transports. Store, authority and SQLite
/// work runs on a private serial GCD queue. A bounded immutable query snapshot may be evaluated
/// concurrently off-queue, then rechecked on the owner queue before delivery.
/// Closures submitted to this type must not suspend while ItemStore has an access context.
public actor ServiceCoordinator {
    private let core: CoreBox
    private let readPool: SQLiteReadPool
    private var accepting = true
    private var pending = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var verificationTask: Task<Void, Never>?
    private var verificationInterval: Duration = .seconds(900)
    private var exclusiveRebuildPending = false
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
        makeAccountDirectory: @escaping @Sendable () -> any AccountDirectory = { SystemAccountDirectory() }
    ) async throws {
        let opened: CoreBox = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try CoreBox(
                            root: root, indexDirectory: indexDirectory, accounts: makeAccountDirectory()))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        core = opened
        readPool = opened.readPool
    }

    /// The UID is authenticated by the in-process transport and never read from request bytes.
    public func handle(_ request: Data, forUID uid: UInt32) async throws -> Data {
        guard !exclusiveRebuildPending else {
            throw TractandaError("serviceBusy", "A store rebuild is draining accepted readers.")
        }
        try beginWork()
        defer { finishWork() }
        let exclusive = try await submit { service in
            service.admittedRebuildRequest(request, peerUID: uid)
        }
        var poolExclusiveStarted = false
        if exclusive {
            guard !exclusiveRebuildPending else {
                throw TractandaError("serviceBusy", "A store rebuild is already in progress.")
            }
            exclusiveRebuildPending = true
        }
        defer {
            if exclusive {
                if poolExclusiveStarted { readPool.endExclusive() }
                exclusiveRebuildPending = false
            }
        }
        if exclusive {
            await stopCanonicalVerificationForRebuild()
            try await readPool.beginExclusiveAndDrainAsync()
            poolExclusiveStarted = true
        }
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
                let response = try? await submit { service in
                    try service.finishPooledQuery(pooled, page: page, peerUID: uid)
                }
                if let response { return response }
            }
        }
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
                let response = try? await submit { service in
                    try service.finishPooledGet(pooledGet, records: records, peerUID: uid)
                }
                if let response { return response }
            }
        }
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
                let response = try? await submit { service in
                    try service.finishPooledHistory(pooledHistory, result: result, peerUID: uid)
                }
                if let response { return response }
            }
        }
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
        let response = try await submit { service in service.handle(request, peerUID: uid) }
        if exclusive && accepting {
            let trusted = (try? await submit { $0.store.isCanonicalTrusted }) ?? false
            if trusted {
                try readPool.resumeAfterRebuild()
                readPool.endExclusive()
                poolExclusiveStarted = false
                exclusiveRebuildPending = false
                startCanonicalVerification(every: verificationInterval)
            }
        }
        return response
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
        try beginWork()
        defer { finishWork() }
        _ = try await submit { service in
            service.maintainSemanticIndex()
            return ()
        }
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

    /// Stops future admission, drains already accepted queue entries, and releases the writer lock.
    public func close() async {
        guard accepting else { return }
        accepting = false
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

    init(root: URL, indexDirectory: URL?, accounts: any AccountDirectory) throws {
        let store = try ItemStore(root: root, indexDirectory: indexDirectory, accounts: accounts)
        service = ItemService(store: store)
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

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                service = nil
                continuation.resume()
            }
        }
    }
}
