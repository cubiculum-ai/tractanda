import Foundation
import TractandaVectors

protocol SemanticVectorStorage: AnyObject {
    func identity(itemID: String, profileID: String) throws -> SemanticIndexedIdentity?
    func hasCurrent(itemID: String, profileID: String, contentHash: String) throws -> Bool
    func rebind(_ snapshot: SemanticSnapshot) throws
    func begin(_ snapshot: SemanticSnapshot) throws -> Vec1Generation
    func append(_ generation: Vec1Generation, chunks: [SemanticChunk], vectors: [[Double]]) throws
    func publish(_ generation: Vec1Generation, count: Int64) throws
    func discard(_ generation: Vec1Generation) throws
    func prunePage(profileID: String, after: String?, current: (String) throws -> Bool) throws -> String?
    func cleanup() throws
    func search(
        vector: [Double], profileID: String, limit: Int,
        current: (_ visit: (SemanticSnapshot) throws -> Void) throws -> Void
    ) throws -> [SemanticIndexedPassage]
    func reset() throws
}
struct SemanticIndexedIdentity {
    let revisionID: String
    let profileID: String
    let contentHash: String
    let count: Int
}
struct SemanticIndexedPassage: Sendable, Equatable {
    let itemID: String
    let revisionID: String
    let profileID: String
    let contentHash: String
    let ordinal: Int
    let unitOrdinal: Int64
    let byteRange: Range<Int>
    let unitByteRange: Range<Int>
    let text: String
    let score: Double
}

/// Injectable test backend uses the same SQLite generation/filter contracts, including bounded cursors.
final class SemanticMemoryStorage: SemanticVectorStorage {
    private var backing: SemanticVec1Storage?
    func identity(itemID: String, profileID: String) throws -> SemanticIndexedIdentity? {
        try backing?.identity(itemID: itemID, profileID: profileID)
    }
    func hasCurrent(itemID: String, profileID: String, contentHash: String) throws -> Bool {
        try backing?.hasCurrent(itemID: itemID, profileID: profileID, contentHash: contentHash) ?? false
    }
    func rebind(_ snapshot: SemanticSnapshot) throws { try backing?.rebind(snapshot) }
    func begin(_ snapshot: SemanticSnapshot) throws -> Vec1Generation {
        if backing == nil {
            backing = try SemanticVec1Storage(
                path: ":memory:", dimensions: snapshot.dimensions, profileID: snapshot.profileID)
        }
        return try backing!.begin(snapshot)
    }
    func append(_ generation: Vec1Generation, chunks: [SemanticChunk], vectors: [[Double]]) throws {
        try backing?.append(generation, chunks: chunks, vectors: vectors)
    }
    func publish(_ generation: Vec1Generation, count: Int64) throws {
        try backing?.publish(generation, count: count)
    }
    func discard(_ generation: Vec1Generation) throws { try backing?.discard(generation) }
    func prunePage(profileID: String, after: String?, current: (String) throws -> Bool) throws -> String? {
        try backing?.prunePage(profileID: profileID, after: after, current: current)
    }
    func cleanup() throws { try backing?.cleanup() }
    func search(
        vector: [Double], profileID: String, limit: Int,
        current: (_ visit: (SemanticSnapshot) throws -> Void) throws -> Void
    ) throws -> [SemanticIndexedPassage] {
        try backing?.search(vector: vector, profileID: profileID, limit: limit, current: current) ?? []
    }
    func reset() throws { backing = nil }
}

private final class SemanticAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
    func resolve(_ result: Bool) {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return
        }
        value = result
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
private struct SemanticBatch: Sendable {
    let epoch: Int
    let jobID: String
    let chunks: [SemanticChunk]  // <=16
    let vectors: [[Double]]  // <=16
    let acknowledgement: SemanticAcknowledgement
}
private struct CompletedSemanticWork: Sendable {
    let epoch: Int
    let jobID: String
    let queryID: String?
    let vector: [Double]?
    let count: Int64
    let failed: Bool
}
private final class SemanticMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var batch: SemanticBatch?
    private var document: CompletedSemanticWork?
    private var query: CompletedSemanticWork?
    private var cancelledJobID: String?
    func append(_ value: SemanticBatch) {
        lock.lock()
        if cancelledJobID == value.jobID {
            lock.unlock()
            value.acknowledgement.resolve(false)
            return
        }
        precondition(batch == nil)
        batch = value
        lock.unlock()
    }
    func append(_ value: CompletedSemanticWork) {
        lock.lock()
        if value.queryID == nil {
            precondition(document == nil)
            document = value
        } else {
            precondition(query == nil)
            query = value
        }
        lock.unlock()
    }
    func takeBatch() -> SemanticBatch? {
        lock.lock()
        defer { lock.unlock() }
        let result = batch
        batch = nil
        return result
    }
    func takeCompleted() -> [CompletedSemanticWork] {
        lock.lock()
        defer { lock.unlock() }
        let result = [document, query].compactMap { $0 }
        document = nil
        query = nil
        return result
    }
    func cancelDocument(jobID: String?) {
        lock.lock()
        cancelledJobID = jobID
        let current = batch
        batch = nil
        lock.unlock()
        current?.acknowledgement.resolve(false)
    }
}
private struct SemanticDocumentWork {
    let epoch: Int
    let jobID: String
    let snapshot: SemanticSnapshot
    let generation: Vec1Generation
    let storage: SemanticVectorStorage
    let task: Task<Void, Never>
    var acceptedCount: Int64 = 0
    var failed = false
}

/// Store executor owns state; detached work sees only a leased corpus and one acknowledged batch.
final class SemanticService {
    private let store: ItemStore
    private let configurations: SemanticConfigurationStore
    private var storage: SemanticVectorStorage
    private let hasInjectedStorage: Bool
    private let embed: @Sendable (SemanticConfiguration, [String], Bool) async throws -> [[Double]]
    private let mailbox = SemanticMailbox()
    private var queries: [String: SemanticQuery] = [:]
    private var queryVectors: [String: [Double]] = [:]
    private var queryFailures: Set<String> = []
    private var queryJobs: [String: String] = [:]
    private var documentWork: SemanticDocumentWork?
    private var documentWorkSuspended = false
    private var queryTasks: [String: Task<Void, Never>] = [:]
    private var retryAfter: [String: Date] = [:]
    private var providerRetryAfter = Date.distantPast
    private var storageProfile: String?
    private var storageProblem: TractandaError?
    /// `ItemStore.state` is the service-wide generation while maintenance has
    /// no caller context. It changes after every published head or index
    /// rebuild, so an idle request must not rescan every canonical item.
    private var reconciledStoreState: String?
    private var scanCursor: String?
    private var scanActive = false
    private var scanAgain = false
    private var pruneCursor: String?
    private var pruneActive = false
    private var pruneAgain = false
    private let reconciliationPageSize = 32
    private var epoch = 0

    private let pendingQueryLifetimeForTesting: TimeInterval?
    private let queryLifetimeClock: @Sendable () -> Date
    private let retryDelay: TimeInterval
    private let maximumQueries = SemanticConfiguration.maximumPendingQueries

    init(
        store: ItemStore,
        storage: SemanticVectorStorage? = nil,
        retryDelayForTesting: TimeInterval = 5,
        embed: @escaping @Sendable (SemanticConfiguration, [String], Bool) async throws -> [[Double]] =
            SemanticService.defaultEmbed
    ) {
        self.store = store
        self.storage = storage ?? SemanticMemoryStorage()
        hasInjectedStorage = storage != nil
        queryLifetimeClock = { Date() }
        pendingQueryLifetimeForTesting = nil
        retryDelay = retryDelayForTesting
        self.embed = embed
        configurations = SemanticConfigurationStore(storeRoot: store.root)
    }

    init(
        store: ItemStore,
        storage: SemanticVectorStorage? = nil,
        queryLifetimeClock: @escaping @Sendable () -> Date,
        pendingQueryLifetimeForTesting: TimeInterval? = nil,
        retryDelayForTesting: TimeInterval = 5,
        embed: @escaping @Sendable (SemanticConfiguration, [String], Bool) async throws -> [[Double]] =
            SemanticService.defaultEmbed
    ) {
        self.store = store
        self.storage = storage ?? SemanticMemoryStorage()
        hasInjectedStorage = storage != nil
        self.queryLifetimeClock = queryLifetimeClock
        self.pendingQueryLifetimeForTesting = pendingQueryLifetimeForTesting
        retryDelay = retryDelayForTesting
        self.embed = embed
        configurations = SemanticConfigurationStore(storeRoot: store.root)
    }

    private static func defaultEmbed(
        _ configuration: SemanticConfiguration, _ inputs: [String], _ query: Bool
    ) async throws -> [[Double]] {
        try await SemanticEmbeddingProvider(configuration: configuration).embed(inputs, query: query)
    }

    /// Must be invoked with no caller access context. Failures in a derived
    /// cache are retained as availability state and never fail ordinary calls.
    func maintain() {
        do {
            let configuration = try configurations.load()
            try drain(configuration)
            guard let configuration else {
                expireQueries()
                return
            }
            let profile = try SemanticSource.profileID(configuration)
            guard documentWork == nil || storageProfile == profile else {
                expireQueries()
                return
            }
            try ensureStorage(configuration, profileID: profile)
            try reconcile(configuration, profileID: profile)
            scheduleOneQuery(configuration, profileID: profile)
            expireQueries()
        } catch let error as TractandaError {
            storageProblem = error
            expireQueries()
        } catch {
            storageProblem = TractandaError("semanticIndex", "Semantic maintenance is unavailable.")
            expireQueries()
        }
    }

    /// Pure schema bound for reply admission. Do not call status(): its corpus scan owns
    /// durable reader leases and may incur retirement work before a mutator is admitted.
    func statusReplyByteCountBound() throws -> Int {
        let configuration = try configurations.load()
        let profile: Any
        if let configuration {
            profile = try SemanticSource.profileID(configuration)
        } else {
            profile = NSNull()
        }
        let payload: [String: Any] = [
            "enabled": false,  // false has the longer JSON spelling.
            "configurationID": configuration?.configurationID as Any? ?? NSNull(),
            "model": configuration?.model as Any? ?? NSNull(),
            "profileID": profile,
            "inputEncoding": configuration?.inputEncoding.rawValue as Any? ?? NSNull(),
            "itemTextProfile": ItemTextContent.profile,
            // Actual counts are nonnegative Ints; use their longest possible decimal form.
            "indexableItems": Int.max, "indexedItems": Int.max, "pendingItems": Int.max,
            "coverage": "complete",  // complete and disabled are the longest declared variants.
        ]
        return try JSONSerialization.data(withJSONObject: payload).count
    }

    func status() throws -> [String: Any] {
        let configuration = try configurations.load()
        guard let configuration else {
            return [
                "enabled": false,
                "configurationID": NSNull(),
                "model": NSNull(),
                "profileID": NSNull(),
                "inputEncoding": NSNull(),
                "itemTextProfile": ItemTextContent.profile,
                "indexableItems": 0,
                "indexedItems": 0,
                "pendingItems": 0,
                "coverage": "disabled",
            ]
        }
        let profile = try SemanticSource.profileID(configuration)
        var indexable = 0
        var indexed = 0
        try store.forEachReadableCandidate(text: nil) { revision in
            guard let snapshot = try snapshot(revision, configuration: configuration, profileID: profile)
            else { return }
            defer { try? store.releaseIndexedCorpus(snapshot.corpus) }
            indexable += 1
            if storageProfile == profile, storageProblem == nil {
                do {
                    if try storage.hasCurrent(
                        itemID: snapshot.itemID, profileID: profile, contentHash: snapshot.contentHash)
                    {
                        indexed += 1
                    }
                } catch {
                    storageProblem = TractandaError("semanticIndex", "Semantic index is unavailable.")
                }
            }
        }
        return [
            "enabled": true,
            "configurationID": configuration.configurationID,
            "model": configuration.model,
            "profileID": profile,
            "inputEncoding": configuration.inputEncoding.rawValue,
            "itemTextProfile": ItemTextContent.profile,
            "indexableItems": indexable,
            "indexedItems": indexed,
            "pendingItems": indexable - indexed,
            "coverage": indexed == indexable && storageProblem == nil ? "complete" : "partial",
        ]
    }

    /// Cheap, local per-item diagnostic. It never schedules work or changes index state.
    func textDiagnostics(for revision: Revision, corpus: ItemTextContent.Corpus) -> [String: Any] {
        do {
            guard let configuration = try configurations.load() else {
                return [
                    "status": "disabled", "enabled": false, "configurationID": NSNull(),
                    "profileID": NSNull(),
                ]
            }
            let profileID = try SemanticSource.profileID(configuration)
            var result: [String: Any] = [
                "enabled": true, "configurationID": configuration.configurationID, "profileID": profileID,
                "inputEncoding": configuration.inputEncoding.rawValue, "model": configuration.model,
                "chunkBytes": configuration.chunkBytes, "overlapBytes": configuration.overlapBytes,
                "documentPrefixApplied": !configuration.documentPrefix.isEmpty,
            ]
            guard !revision.isDeleted,
                let snapshot = try snapshot(revision, configuration: configuration, profileID: profileID)
            else {
                result["status"] = "notIndexable"
                return result
            }
            defer { try? store.releaseIndexedCorpus(snapshot.corpus) }
            if storageProblem != nil {
                result["status"] = "unavailable"
                return result
            }
            let hash = snapshot.contentHash
            guard storageProfile == profileID else {
                result["status"] = "pending"
                return result
            }
            let identity: SemanticIndexedIdentity?
            do { identity = try storage.identity(itemID: revision.itemID, profileID: profileID) } catch {
                result["status"] = "unavailable"
                return result
            }
            guard let identity else {
                result["status"] = "missing"
                return result
            }
            result["indexedRevisionID"] = identity.revisionID
            result["recordCount"] = identity.count
            result["status"] =
                identity.count > 0 && identity.revisionID == revision.revisionID
                    && identity.contentHash == hash ? "current" : "stale"
            return result
        } catch { return ["enabled": NSNull(), "status": "unavailable"] }
    }

    func configure(_ configuration: SemanticConfiguration, expectedConfigurationID: String?) throws
        -> [String: Any]
    {
        try store.requireAdministrator()
        let previous = try configurations.load()
        let saved = try configurations.configure(
            configuration, expectedConfigurationID: expectedConfigurationID)
        if previous != saved { invalidate() }
        return [
            "enabled": true,
            "configurationID": saved.configurationID,
            "model": saved.model,
            "profileID": try SemanticSource.profileID(saved),
            "inputEncoding": saved.inputEncoding.rawValue,
            "itemTextProfile": ItemTextContent.profile,
            "coverage": "partial",
        ]
    }

    func rebuild(expectedConfigurationID: String, operationID: String) throws -> [String: Any] {
        try maintenance(
            expectedConfigurationID: expectedConfigurationID, operationID: operationID, action: "rebuild")
    }

    func reset(expectedConfigurationID: String, operationID: String) throws -> [String: Any] {
        try maintenance(
            expectedConfigurationID: expectedConfigurationID, operationID: operationID, action: "reset")
    }

    private func maintenance(
        expectedConfigurationID: String, operationID: String, action: String
    ) throws -> [String: Any] {
        try store.requireAdministrator()
        guard !operationID.isEmpty,
            let configuration = try configurations.load(),
            configuration.configurationID == expectedConfigurationID
        else {
            throw TractandaError(
                "configurationConflict", "Semantic configuration changed; read status and retry.")
        }
        guard documentWork == nil else {
            throw TractandaError(
                "semanticBusy", "Drain active semantic document work before resetting its index.")
        }
        if try configurations.performMaintenance(
            configurationID: configuration.configurationID,
            operationID: operationID,
            action: action,
            operation: { try discardDerivedIndex() }
        ) {
            invalidate()
        }
        return [
            "configurationID": configuration.configurationID,
            "operationID": operationID,
            "action": action,
            "coverage": "partial",
        ]
    }

    func search(
        text: String, expression: String?, categoryPath: [String], excludedCategoryIDs: [String],
        viewID: String?, limit: Int, evaluatedAt: Date = Date(), timeZone: String = "UTC"
    ) throws -> [String: Any] {
        guard let configuration = try configurations.load() else {
            throw TractandaError("semanticDisabled", "Configure a local semantic endpoint before searching.")
        }
        guard !text.isEmpty, text.utf8.count <= 8_192, (1...64).contains(limit),
            queries.count < maximumQueries
        else {
            throw TractandaError("semanticQuery", "Invalid or excessive semantic query.")
        }
        _ = try QueryCalendar.make(timeZone: timeZone)
        let createdAt = queryLifetimeClock()
        let profile = try SemanticSource.profileID(configuration)
        let query = SemanticQuery(
            queryID: Identifier.make(),
            callerScope: store.accessScope,
            profileID: profile,
            text: text,
            expression: expression,
            categoryPath: categoryPath,
            excludedCategoryIDs: excludedCategoryIDs,
            viewID: viewID,
            limit: limit,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(
                pendingQueryLifetimeForTesting ?? configuration.pendingQueryLifetimeSeconds),
            evaluatedAt: evaluatedAt,
            timeZone: timeZone)
        try forEachEligibleSnapshot(query, configuration: configuration) { _ in }
        queries[query.queryID] = query
        return queryResponse(query, state: "pending")
    }

    func results(queryID: String) throws -> [String: Any] {
        guard let query = queries[queryID], query.callerScope == store.accessScope,
            query.expiresAt > queryLifetimeClock()
        else {
            throw TractandaError(
                "notFound", "This semantic query may have expired or been invalidated; start a new search.")
        }
        guard let configuration = try configurations.load(),
            try SemanticSource.profileID(configuration) == query.profileID
        else {
            throw TractandaError(
                "notFound", "This semantic query may have expired or been invalidated; start a new search.")
        }
        if queryFailures.contains(queryID) {
            return queryResponse(query, state: "failed", results: [])
        }
        guard let vector = queryVectors[queryID] else {
            return queryResponse(query, state: "pending", results: [])
        }
        var partial = storageProblem != nil
        guard storageProfile == query.profileID, storageProblem == nil else {
            return queryResponse(query, state: "ready", results: [], partialCoverage: true)
        }
        let hits: [SemanticIndexedPassage]
        do {
            hits = try storage.search(vector: vector, profileID: query.profileID, limit: query.limit) {
                visit in
                try withoutActuallyEscaping(visit) { emit in
                    try forEachEligibleSnapshot(query, configuration: configuration) { snapshot in
                        let indexed = try storage.identity(
                            itemID: snapshot.itemID, profileID: query.profileID)
                        if indexed?.revisionID != snapshot.revisionID
                            || indexed?.contentHash != snapshot.contentHash
                        {
                            partial = true
                        }
                        try emit(snapshot)
                    }
                }
            }
        } catch {
            storageProblem = TractandaError("semanticIndex", "Semantic index is unavailable.")
            return queryResponse(query, state: "ready", results: [], partialCoverage: true)
        }
        let result = try hits.compactMap { hit -> [String: Any]? in
            guard
                let snapshot = try self.snapshot(
                    id: hit.itemID, configuration: configuration, profileID: query.profileID)
            else { return nil }
            defer { try? store.releaseIndexedCorpus(snapshot.corpus) }
            guard snapshot.revisionID == hit.revisionID, snapshot.contentHash == hit.contentHash else {
                return nil
            }
            let length = hit.byteRange.count
            guard (1...configuration.chunkBytes).contains(length), hit.unitByteRange.count == length else {
                return nil
            }
            let window = try SemanticSource.readUnitWindow(
                snapshot.corpus, ordinal: hit.unitOrdinal,
                offset: Int64(hit.unitByteRange.lowerBound), limit: length)
            guard window.data.count == length, String(decoding: window.data, as: UTF8.self) == hit.text else {
                return nil
            }
            let unitStart = Int64(hit.byteRange.lowerBound) - Int64(hit.unitByteRange.lowerBound)
            guard unitStart >= 0 else { return nil }
            try store.revalidateIndexedCorpus(snapshot.corpus)
            return [
                "itemID": snapshot.itemID, "revisionID": snapshot.revisionID,
                "unitOrdinal": hit.unitOrdinal, "unitByteStart": hit.unitByteRange.lowerBound,
                "unitByteEnd": hit.unitByteRange.upperBound, "byteStart": hit.byteRange.lowerBound,
                "byteEnd": hit.byteRange.upperBound, "passage": hit.text, "similarity": hit.score,
                "sources": try JSONSerialization.jsonObject(
                    with: JSON.encode(
                        try SemanticSource.passageSources(
                            snapshot, window: window.raw, range: hit.byteRange, unitStart: unitStart))),
            ]
        }
        return queryResponse(query, state: "ready", results: result, partialCoverage: partial)
    }

    static func completedQueryExpiry(pendingExpiry: Date, consumedAt: Date) -> Date? {
        guard pendingExpiry > consumedAt else { return nil }
        return consumedAt.addingTimeInterval(SemanticConfiguration.completedQueryRetentionSeconds)
    }

    private func queryResponse(
        _ query: SemanticQuery, state: String, results: [Any]? = nil, partialCoverage: Bool? = nil
    ) -> [String: Any] {
        var response: [String: Any] = [
            "queryID": query.queryID,
            "state": state,
            "profileID": query.profileID,
            "evaluatedAt": Timestamp.format(query.evaluatedAt),
            "timeZone": query.timeZone,
            "createdAt": Timestamp.format(query.createdAt),
            "expiresAt": Timestamp.format(query.expiresAt),
        ]
        if state == "pending" { response["retryAfterMilliseconds"] = 500 }
        if let partialCoverage { response["partialCoverage"] = partialCoverage }
        if let results { response["results"] = results }
        return response
    }

    private func drain(_ configuration: SemanticConfiguration?) throws {
        if let batch = mailbox.takeBatch() {
            var accepted = false
            defer { batch.acknowledgement.resolve(accepted) }
            if var work = documentWork, work.jobID == batch.jobID, work.epoch == batch.epoch,
                batch.epoch == epoch, !work.failed, let configuration,
                try SemanticSource.profileID(configuration) == work.snapshot.profileID
            {
                do {
                    guard
                        let current = try snapshot(
                            id: work.snapshot.itemID, configuration: configuration,
                            profileID: work.snapshot.profileID)
                    else { throw CancellationError() }
                    defer { try? store.releaseIndexedCorpus(current.corpus) }
                    guard current.contentHash == work.snapshot.contentHash else { throw CancellationError() }
                    try store.revalidateIndexedCorpus(current.corpus)
                    try work.storage.append(work.generation, chunks: batch.chunks, vectors: batch.vectors)
                    work.acceptedCount = try PageCorpusEmitter.add(
                        work.acceptedCount, Int64(batch.chunks.count))
                    accepted = true
                } catch { work.failed = true }
                documentWork = work
            }
        }
        for completed in mailbox.takeCompleted() {
            if let queryID = completed.queryID {
                guard queryJobs[queryID] == completed.jobID else { continue }
                queryJobs.removeValue(forKey: queryID)
                queryTasks.removeValue(forKey: queryID)
                let consumedAt = queryLifetimeClock()
                guard completed.epoch == epoch, var query = queries[queryID],
                    let expiry = Self.completedQueryExpiry(
                        pendingExpiry: query.expiresAt, consumedAt: consumedAt)
                else { continue }
                // Retention starts when this completion is consumed, not when
                // the asynchronous provider returned. Never revive expired pending work.
                query.expiresAt = expiry
                queries[queryID] = query
                if completed.failed {
                    queryFailures.insert(queryID)
                    continue
                }
                if let vector = completed.vector, let configuration,
                    queries[queryID]?.profileID == (try SemanticSource.profileID(configuration))
                {
                    try SemanticVectorValidation.validate(vector, dimensions: configuration.dimensions)
                    queryVectors[queryID] = vector
                }
                continue
            }
            guard let work = documentWork, work.jobID == completed.jobID else { continue }
            documentWork = nil
            defer { try? store.releaseIndexedCorpus(work.snapshot.corpus) }
            var published = false
            defer {
                if !published { try? work.storage.discard(work.generation) }
                try? work.storage.cleanup()
            }
            guard completed.epoch == epoch else { continue }
            guard !completed.failed, !work.failed,
                completed.count == work.acceptedCount, completed.count > 0,
                let configuration, try SemanticSource.profileID(configuration) == work.snapshot.profileID,
                let current = try snapshot(
                    id: work.snapshot.itemID, configuration: configuration, profileID: work.snapshot.profileID
                )
            else {
                retryAfter[work.snapshot.itemID] = Date().addingTimeInterval(retryDelay)
                if completed.failed && !work.failed {
                    providerRetryAfter = Date().addingTimeInterval(retryDelay)
                }
                continue
            }
            defer { try? store.releaseIndexedCorpus(current.corpus) }
            guard current.contentHash == work.snapshot.contentHash else { continue }
            try store.revalidateIndexedCorpus(current.corpus)
            try work.storage.publish(work.generation, count: completed.count)
            published = true
            providerRetryAfter = .distantPast
            if current.revisionID != work.snapshot.revisionID { try work.storage.rebind(current) }
            retryAfter.removeValue(forKey: current.itemID)
        }
    }

    private func reconcile(_ configuration: SemanticConfiguration, profileID: String) throws {
        try storage.cleanup()
        guard !documentWorkSuspended else { return }
        let storeState = store.state
        if reconciledStoreState != storeState {
            let starting = reconciledStoreState == nil
            reconciledStoreState = storeState
            if starting || !scanActive {
                scanCursor = nil
                scanActive = true
                scanAgain = false
            } else {
                scanAgain = true
            }
            if starting || !pruneActive {
                pruneCursor = nil
                pruneActive = true
                pruneAgain = false
            } else {
                pruneAgain = true
            }
        }
        if pruneActive {
            pruneCursor = try storage.prunePage(profileID: profileID, after: pruneCursor) { itemID in
                guard
                    let current = try snapshot(id: itemID, configuration: configuration, profileID: profileID)
                else { return false }
                defer { try? store.releaseIndexedCorpus(current.corpus) }
                return true
            }
            if pruneCursor == nil {
                pruneActive = pruneAgain
                pruneAgain = false
            }
        }
        guard documentWork == nil else { return }
        guard providerRetryAfter <= Date() else { return }
        if !scanActive && hasDueDocumentRetry {
            scanCursor = nil
            scanActive = true
        }
        guard scanActive else { return }
        for _ in 0..<reconciliationPageSize {
            guard let revision = try store.semanticCurrentRevision(after: scanCursor) else {
                scanCursor = nil
                scanActive = scanAgain
                scanAgain = false
                return
            }
            scanCursor = revision.itemID
            guard let current = try snapshot(revision, configuration: configuration, profileID: profileID)
            else {
                retryAfter.removeValue(forKey: revision.itemID)
                continue
            }
            var transferred = false
            defer { if !transferred { try? store.releaseIndexedCorpus(current.corpus) } }
            if let indexed = try storage.identity(itemID: current.itemID, profileID: profileID),
                indexed.contentHash == current.contentHash
            {
                retryAfter.removeValue(forKey: current.itemID)
                if indexed.revisionID != current.revisionID { try storage.rebind(current) }
            } else if retryAfter[current.itemID, default: .distantPast] <= Date() {
                try scheduleDocument(current, configuration)
                transferred = true
                return
            }
        }
    }
    private var hasDueDocumentRetry: Bool { retryAfter.values.contains { $0 <= Date() } }

    private func scheduleDocument(_ snapshot: SemanticSnapshot, _ configuration: SemanticConfiguration) throws
    {
        guard documentWork == nil else { return }
        let generation = try storage.begin(snapshot)
        let jobID = Identifier.make()
        let currentEpoch = epoch
        let provider = embed
        let mailbox = mailbox
        let task = Task.detached {
            var count: Int64 = 0
            var failed = false
            do {
                var cursor = try SemanticChunkCursor(
                    snapshot: snapshot.corpus, chunkBytes: configuration.chunkBytes,
                    overlapBytes: configuration.overlapBytes)
                var done = false
                while !done {
                    try Task.checkCancellation()
                    var chunks: [SemanticChunk] = []
                    while chunks.count < 16 {
                        guard let chunk = try cursor.next(boundary: { try Task.checkCancellation() }) else {
                            done = true
                            break
                        }
                        chunks.append(chunk)
                    }
                    guard !chunks.isEmpty else { break }
                    let vectors = try await provider(configuration, chunks.map(\.text), false)
                    try Task.checkCancellation()
                    guard vectors.count == chunks.count else {
                        throw TractandaError("semanticProvider", "Embedding response count mismatch.")
                    }
                    for vector in vectors {
                        try SemanticVectorValidation.validate(vector, dimensions: configuration.dimensions)
                    }
                    let acknowledgement = SemanticAcknowledgement()
                    mailbox.append(
                        .init(
                            epoch: currentEpoch, jobID: jobID, chunks: chunks, vectors: vectors,
                            acknowledgement: acknowledgement))
                    guard await acknowledgement.wait() else { throw CancellationError() }
                    count = try PageCorpusEmitter.add(count, Int64(chunks.count))
                }
                try Task.checkCancellation()
            } catch { failed = true }
            // This is the last operation: all reader work is finished before lease disposal can be acknowledged.
            mailbox.append(
                CompletedSemanticWork(
                    epoch: currentEpoch, jobID: jobID, queryID: nil, vector: nil, count: count, failed: failed
                ))
        }
        documentWork = .init(
            epoch: currentEpoch, jobID: jobID, snapshot: snapshot, generation: generation, storage: storage,
            task: task)
    }

    @discardableResult
    func cancelDocumentWork() -> Task<Void, Never>? {
        documentWorkSuspended = true
        documentWork?.task.cancel()
        mailbox.cancelDocument(jobID: documentWork?.jobID)
        return documentWork?.task
    }
    var hasPendingDocumentWork: Bool { documentWork != nil }
    func resumeDocumentWork() {
        documentWorkSuspended = false
        reconciledStoreState = nil
    }

    private func scheduleOneQuery(_ configuration: SemanticConfiguration, profileID: String) {
        guard queryJobs.isEmpty, queryTasks.isEmpty else { return }
        guard
            let query = queries.values.sorted(by: { $0.createdAt < $1.createdAt }).first(where: {
                $0.profileID == profileID && $0.expiresAt > queryLifetimeClock()
                    && queryVectors[$0.queryID] == nil
                    && !queryFailures.contains($0.queryID)
            })
        else { return }
        let jobID = Identifier.make()
        queryJobs[query.queryID] = jobID
        let currentEpoch = epoch
        let provider = embed
        let mailbox = mailbox
        let task = Task.detached {
            do {
                try Task.checkCancellation()
                let vectors = try await provider(configuration, [query.text], true)
                try Task.checkCancellation()
                mailbox.append(
                    CompletedSemanticWork(
                        epoch: currentEpoch, jobID: jobID, queryID: query.queryID,
                        vector: vectors.count == 1 ? vectors.first : nil, count: 0, failed: vectors.count != 1
                    ))
            } catch {
                mailbox.append(
                    CompletedSemanticWork(
                        epoch: currentEpoch, jobID: jobID, queryID: query.queryID,
                        vector: nil, count: 0, failed: true))
            }
        }
        queryTasks[query.queryID] = task
    }

    private func snapshot(id: String, configuration: SemanticConfiguration, profileID: String) throws
        -> SemanticSnapshot?
    {
        do {
            return try snapshot(store.get(id), configuration: configuration, profileID: profileID)
        } catch let error as TractandaError where error.code == "notFound" || error.code == "forbidden" {
            return nil
        }
    }
    private func snapshot(_ revision: Revision, configuration: SemanticConfiguration, profileID: String)
        throws -> SemanticSnapshot?
    {
        guard !revision.isDeleted,
            let corpus = try store.captureIndexedCorpus(
                itemID: revision.itemID, expectedRevisionID: revision.revisionID)
        else { return nil }
        return .init(corpus: corpus, profileID: profileID, dimensions: configuration.dimensions)
    }
    private func forEachEligibleSnapshot(
        _ query: SemanticQuery, configuration: SemanticConfiguration,
        visit: (SemanticSnapshot) throws -> Void
    ) throws {
        var expression = query.expression
        var text: String?
        var categoryPath = query.categoryPath
        var excluded = query.excludedCategoryIDs
        if let id = query.viewID {
            guard expression == nil, categoryPath.isEmpty, excluded.isEmpty else {
                throw TractandaError(
                    "invalidArguments", "Use either a saved view or inline semantic criteria.")
            }
            let view = try store.get(id)
            guard !view.isDeleted, let value = view.fields["viewDefinition"] else {
                throw TractandaError("notView", "Item has no available saved view definition.")
            }
            let definition = try SavedViewDefinition(value)
            expression = definition.expression
            text = definition.text
            categoryPath = definition.categoryPath
            excluded = definition.excludedCategoryIDs
        }
        guard categoryPath.count <= 32, excluded.count <= 32 else {
            throw TractandaError("limit", "Category path exceeds32levels.")
        }
        let predicate = try expression.map(SpotlightQuery.init)
        let calendar = try QueryCalendar.make(timeZone: query.timeZone)
        for id in categoryPath + excluded { _ = try Categories.rule(store.get(id)) }
        let evaluator =
            try categoryPath.isEmpty && excluded.isEmpty
            ? nil
            : CategoryEvaluator(
                definitions: store.readableCategoryDefinitions(
                    requestedCategoryIDs: Set(categoryPath + excluded)), store: store, at: query.evaluatedAt)
        try store.forEachReadableCandidate(
            text: text,
            candidatePlan: predicate?.boundedIndexCandidatePlan(at: query.evaluatedAt, calendar: calendar)
                ?? .all
        ) { revision in
            guard predicate?.matches(revision, at: query.evaluatedAt, calendar: calendar) ?? true else {
                return
            }
            var cache: [String: Membership] = [:]
            for id in categoryPath
            where try evaluator?.membership(revision, categoryID: id, cache: &cache).isIncluded != true {
                return
            }
            for id in excluded
            where try evaluator?.membership(revision, categoryID: id, cache: &cache).isIncluded == true {
                return
            }
            guard
                let current = try snapshot(revision, configuration: configuration, profileID: query.profileID)
            else { return }
            defer { try? store.releaseIndexedCorpus(current.corpus) }
            try visit(current)
        }
    }

    private func ensureStorage(_ configuration: SemanticConfiguration, profileID: String) throws {
        let requiresReconciliation = storageProfile != profileID || storageProblem != nil
        if hasInjectedStorage {
            if let storageProfile, storageProfile != profileID { try storage.reset() }
            storageProfile = profileID
            storageProblem = nil
            if requiresReconciliation { reconciledStoreState = nil }
            return
        }
        guard storageProfile != profileID || storageProblem != nil || storage is SemanticMemoryStorage else {
            return
        }
        storage = SemanticMemoryStorage()
        storageProfile = nil
        reconciledStoreState = nil
        try store.requireIndexFilesystemCapacity(additionalBytes: 131_072)
        do {
            storage = try SemanticVec1Storage(
                path: semanticIndexURL.path, dimensions: configuration.dimensions, profileID: profileID,
                writeBoundary: { [unowned store] batch in try store.semanticVectorWriteBoundary(batch) })
            storageProfile = profileID
            storageProblem = nil
        } catch let error as TractandaError
            where error.code == "resourceLimit" || error.code == "forbidden" || error.code == "notFound"
        {
            throw error
        } catch {
            try quarantineDerivedIndex()
            storage = try SemanticVec1Storage(
                path: semanticIndexURL.path, dimensions: configuration.dimensions, profileID: profileID,
                writeBoundary: { [unowned store] batch in try store.semanticVectorWriteBoundary(batch) })
            storageProfile = profileID
            storageProblem = nil
        }
    }

    private var semanticIndexURL: URL {
        store.indexDirectory.appendingPathComponent("semantic.sqlite")
    }

    private func discardDerivedIndex() throws {
        if hasInjectedStorage { try storage.reset() } else { storage = SemanticMemoryStorage() }
        storageProfile = nil
        storageProblem = nil
        reconciledStoreState = nil
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = URL(fileURLWithPath: semanticIndexURL.path + suffix)
            if fileManager.fileExists(atPath: path.path) { try fileManager.removeItem(at: path) }
        }
        try store.semanticVectorIndexDisposed()
    }

    private func quarantineDerivedIndex() throws {
        storage = SemanticMemoryStorage()
        storageProfile = nil
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: semanticIndexURL.path) else { return }
        let destination = semanticIndexURL.deletingLastPathComponent().appendingPathComponent(
            "semantic.quarantine." + Identifier.make() + ".sqlite")
        try fileManager.moveItem(at: semanticIndexURL, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: semanticIndexURL.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) { try fileManager.removeItem(at: sidecar) }
        }
    }

    private func invalidate() {
        documentWork?.task.cancel()
        mailbox.cancelDocument(jobID: documentWork?.jobID)
        for task in queryTasks.values { task.cancel() }
        epoch += 1
        queries.removeAll()
        queryVectors.removeAll()
        queryFailures.removeAll()
        retryAfter.removeAll()
        providerRetryAfter = .distantPast
        reconciledStoreState = nil
    }

    private func expireQueries() {
        let now = queryLifetimeClock()
        for (queryID, task) in queryTasks where queries[queryID]?.expiresAt ?? .distantPast <= now {
            task.cancel()
        }
        queries = queries.filter { $0.value.expiresAt > now }
        queryVectors = queryVectors.filter { queries[$0.key] != nil }
        queryFailures = queryFailures.filter { queries[$0] != nil }
    }
}
