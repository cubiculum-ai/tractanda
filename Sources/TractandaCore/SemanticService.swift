import Foundation

protocol SemanticVectorStorage: AnyObject {
    func hasCurrent(itemID: String, profileID: String, contentHash: String) throws -> Bool
    func rebind(_ snapshot: SemanticSnapshot) throws
    func replace(_ snapshot: SemanticSnapshot, chunks: [SemanticChunk], vectors: [[Double]]) throws
    func prune(profileID: String, keeping itemIDs: Set<String>) throws
    func search(
        vector: [Double], profileID: String, current: [SemanticSnapshot], limit: Int
    ) throws -> [SemanticIndexedPassage]
    func reset() throws
}

struct SemanticIndexedPassage: Sendable, Equatable {
    let itemID: String
    let revisionID: String
    let profileID: String
    let contentHash: String
    let ordinal: Int
    let byteRange: Range<Int>
    let vector: [Double]
    let score: Double?
}

final class SemanticMemoryStorage: SemanticVectorStorage {
    private var values: [String: [SemanticIndexedPassage]] = [:]

    func hasCurrent(itemID: String, profileID: String, contentHash: String) throws -> Bool {
        values[itemID]?.first.map {
            $0.profileID == profileID && $0.contentHash == contentHash
        } ?? false
    }

    func rebind(_ snapshot: SemanticSnapshot) throws {
        guard let prior = values[snapshot.itemID],
            prior.first?.profileID == snapshot.profileID,
            prior.first?.contentHash == snapshot.contentHash
        else { return }
        values[snapshot.itemID] = prior.map {
            SemanticIndexedPassage(
                itemID: $0.itemID,
                revisionID: snapshot.revisionID,
                profileID: $0.profileID,
                contentHash: $0.contentHash,
                ordinal: $0.ordinal,
                byteRange: $0.byteRange,
                vector: $0.vector,
                score: nil)
        }
    }

    func replace(_ snapshot: SemanticSnapshot, chunks: [SemanticChunk], vectors: [[Double]]) throws {
        guard chunks.count == vectors.count else {
            throw TractandaError("semanticIndex", "Chunk/vector count mismatch.")
        }
        values[snapshot.itemID] = zip(chunks, vectors).map { chunk, vector in
            SemanticIndexedPassage(
                itemID: snapshot.itemID,
                revisionID: snapshot.revisionID,
                profileID: snapshot.profileID,
                contentHash: snapshot.contentHash,
                ordinal: chunk.ordinal,
                byteRange: chunk.byteRange,
                vector: vector,
                score: nil)
        }
    }

    func prune(profileID: String, keeping itemIDs: Set<String>) throws {
        values = values.filter { itemID, passages in
            passages.first?.profileID != profileID || itemIDs.contains(itemID)
        }
    }

    func search(
        vector: [Double], profileID: String, current: [SemanticSnapshot], limit: Int
    ) throws -> [SemanticIndexedPassage] {
        let allowed = Dictionary(uniqueKeysWithValues: current.map { ($0.itemID, $0) })
        var best: [String: SemanticIndexedPassage] = [:]
        for passage in values.values.flatMap({ $0 }) {
            guard passage.profileID == profileID,
                let snapshot = allowed[passage.itemID],
                passage.revisionID == snapshot.revisionID,
                passage.contentHash == snapshot.contentHash
            else { continue }
            let score = cosine(vector, passage.vector)
            let candidate = SemanticIndexedPassage(
                itemID: passage.itemID,
                revisionID: passage.revisionID,
                profileID: passage.profileID,
                contentHash: passage.contentHash,
                ordinal: passage.ordinal,
                byteRange: passage.byteRange,
                vector: passage.vector,
                score: score)
            if best[passage.itemID].map({ ($0.score ?? -.infinity) < score }) ?? true {
                best[passage.itemID] = candidate
            }
        }
        return best.values.sorted { lhs, rhs in
            let left = lhs.score ?? -.infinity
            let right = rhs.score ?? -.infinity
            return left == right ? lhs.itemID < rhs.itemID : left > right
        }.prefix(limit).map { $0 }
    }

    func reset() throws {
        values.removeAll()
    }
}

private struct CompletedSemanticWork: Sendable {
    let epoch: Int
    let jobID: String
    let snapshot: SemanticSnapshot?
    let queryID: String?
    let vectors: [[Double]]?
    let failed: Bool
}

private final class SemanticMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CompletedSemanticWork] = []

    func append(_ value: CompletedSemanticWork) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func take() -> [CompletedSemanticWork] {
        lock.lock()
        defer { lock.unlock() }
        let result = values
        values.removeAll(keepingCapacity: true)
        return result
    }
}

/// The ItemStore serial executor owns this service. `maintain()` is called
/// outside caller access scopes; asynchronous tasks receive only value
/// snapshots and report through the mailbox.
final class SemanticService {
    private let store: ItemStore
    private let configurations: SemanticConfigurationStore
    private var storage: SemanticVectorStorage
    private let embed: @Sendable (SemanticConfiguration, [String], Bool) async throws -> [[Double]]
    private let mailbox = SemanticMailbox()
    private var queries: [String: SemanticQuery] = [:]
    private var queryVectors: [String: [Double]] = [:]
    private var queryFailures: Set<String> = []
    private var documentJobs: [String: String] = [:]
    private var queryJobs: [String: String] = [:]
    private var documentTasks: [String: Task<Void, Never>] = [:]
    private var queryTasks: [String: Task<Void, Never>] = [:]
    private var retryAfter: [String: Date] = [:]
    private var storageProfile: String?
    private var storageProblem: TractandaError?
    private var epoch = 0

    private let queryLifetime: TimeInterval = 120
    private let retryDelay: TimeInterval = 5
    private let maximumQueries = 64

    init(
        store: ItemStore,
        storage: SemanticVectorStorage = SemanticMemoryStorage(),
        embed: @escaping @Sendable (SemanticConfiguration, [String], Bool) async throws -> [[Double]] =
            SemanticService.defaultEmbed
    ) {
        self.store = store
        self.storage = storage
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
                "coverage": "disabled",
            ]
        }
        let profile = try SemanticSource.profileID(configuration)
        let snapshots = try readableSnapshots(configuration: configuration, profileID: profile)
        let indexed: Int
        if storageProfile == profile, storageProblem == nil {
            do {
                indexed = try snapshots.filter {
                    try storage.hasCurrent(itemID: $0.itemID, profileID: profile, contentHash: $0.contentHash)
                }.count
            } catch let error as TractandaError {
                storageProblem = error
                indexed = 0
            } catch {
                storageProblem = TractandaError("semanticIndex", "Semantic index is unavailable.")
                indexed = 0
            }
        } else {
            indexed = 0
        }
        return [
            "enabled": true,
            "configurationID": configuration.configurationID,
            "model": configuration.model,
            "profileID": profile,
            "inputEncoding": configuration.inputEncoding.rawValue,
            "itemTextProfile": ItemTextContent.profile,
            "indexableItems": snapshots.count,
            "indexedItems": indexed,
            "coverage": indexed == snapshots.count && storageProblem == nil ? "complete" : "partial",
        ]
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
        let createdAt = Date()
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
            expiresAt: createdAt.addingTimeInterval(queryLifetime),
            evaluatedAt: evaluatedAt,
            timeZone: timeZone)
        _ = try eligibleSnapshots(query, configuration: configuration)
        queries[query.queryID] = query
        return [
            "queryID": query.queryID, "state": "pending", "profileID": profile,
            "evaluatedAt": Timestamp.format(evaluatedAt), "timeZone": timeZone,
        ]
    }

    func results(queryID: String) throws -> [String: Any] {
        guard let query = queries[queryID], query.callerScope == store.accessScope,
            query.expiresAt > Date()
        else {
            throw TractandaError("notFound", "Semantic query is unavailable.")
        }
        guard let configuration = try configurations.load(),
            try SemanticSource.profileID(configuration) == query.profileID
        else {
            throw TractandaError("notFound", "Semantic query is unavailable.")
        }
        if queryFailures.contains(queryID) {
            return queryState(query, state: "failed", results: [])
        }
        guard let vector = queryVectors[queryID] else {
            return queryState(query, state: "pending", results: [])
        }
        let current = try eligibleSnapshots(query, configuration: configuration)
        let missingCurrent: Bool
        do {
            missingCurrent = try current.contains {
                try !storage.hasCurrent(
                    itemID: $0.itemID, profileID: query.profileID, contentHash: $0.contentHash)
            }
        } catch let error as TractandaError {
            storageProblem = error
            missingCurrent = true
        } catch {
            storageProblem = TractandaError("semanticIndex", "Semantic index is unavailable.")
            missingCurrent = true
        }
        let partial = storageProblem != nil || missingCurrent
        guard storageProfile == query.profileID, storageProblem == nil else {
            return [
                "queryID": queryID, "state": "ready", "profileID": query.profileID,
                "evaluatedAt": Timestamp.format(query.evaluatedAt), "timeZone": query.timeZone,
                "partialCoverage": true, "results": [],
            ]
        }
        let hits: [SemanticIndexedPassage]
        do {
            hits = try storage.search(
                vector: vector, profileID: query.profileID, current: current, limit: query.limit)
        } catch let error as TractandaError {
            storageProblem = error
            return [
                "queryID": queryID, "state": "ready", "profileID": query.profileID,
                "evaluatedAt": Timestamp.format(query.evaluatedAt), "timeZone": query.timeZone,
                "partialCoverage": true, "results": [],
            ]
        } catch {
            storageProblem = TractandaError("semanticIndex", "Semantic index is unavailable.")
            return [
                "queryID": queryID, "state": "ready", "profileID": query.profileID,
                "evaluatedAt": Timestamp.format(query.evaluatedAt), "timeZone": query.timeZone,
                "partialCoverage": true, "results": [],
            ]
        }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.itemID, $0) })
        let result = try hits.compactMap { hit -> [String: Any]? in
            guard let snapshot = currentByID[hit.itemID], snapshot.revisionID == hit.revisionID,
                snapshot.contentHash == hit.contentHash
            else { return nil }
            let chunks = try SemanticChunker.chunks(
                snapshot.sourceText, chunkBytes: configuration.chunkBytes,
                overlapBytes: configuration.overlapBytes)
            guard let chunk = chunks.first(where: { $0.ordinal == hit.ordinal }) else { return nil }
            let bytes = Array(snapshot.sourceText.utf8)
            guard chunk.byteRange.lowerBound >= 0, chunk.byteRange.upperBound <= bytes.count else {
                return nil
            }
            return [
                "itemID": snapshot.itemID,
                "revisionID": snapshot.revisionID,
                "byteStart": chunk.byteRange.lowerBound,
                "byteEnd": chunk.byteRange.upperBound,
                "passage": String(data: Data(bytes[chunk.byteRange]), encoding: .utf8) ?? "",
                "similarity": hit.score ?? cosine(vector, hit.vector),
            ]
        }
        return [
            "queryID": queryID,
            "state": "ready",
            "profileID": query.profileID,
            "evaluatedAt": Timestamp.format(query.evaluatedAt),
            "timeZone": query.timeZone,
            "partialCoverage": partial,
            "results": result,
        ]
    }

    private func queryState(_ query: SemanticQuery, state: String, results: [Any]) -> [String: Any] {
        [
            "queryID": query.queryID,
            "state": state,
            "profileID": query.profileID,
            "evaluatedAt": Timestamp.format(query.evaluatedAt),
            "timeZone": query.timeZone,
            "results": results,
        ]
    }

    private func drain(_ configuration: SemanticConfiguration?) throws {
        for work in mailbox.take() {
            if let itemID = work.snapshot?.itemID, documentJobs[itemID] == work.jobID {
                documentJobs.removeValue(forKey: itemID)
                documentTasks.removeValue(forKey: itemID)
            }
            if let queryID = work.queryID, queryJobs[queryID] == work.jobID {
                queryJobs.removeValue(forKey: queryID)
                queryTasks.removeValue(forKey: queryID)
            }
            guard work.epoch == epoch else { continue }
            if work.failed {
                if let itemID = work.snapshot?.itemID {
                    retryAfter[itemID] = Date().addingTimeInterval(retryDelay)
                }
                if let queryID = work.queryID { queryFailures.insert(queryID) }
                continue
            }
            if let queryID = work.queryID, let vector = work.vectors?.first, let configuration {
                let activeProfile = try SemanticSource.profileID(configuration)
                guard queries[queryID]?.profileID == activeProfile else { continue }
                try SemanticVectorValidation.validate(vector, dimensions: configuration.dimensions)
                queryVectors[queryID] = vector
                continue
            }
            guard let snapshot = work.snapshot, let vectors = work.vectors, let configuration else {
                continue
            }
            let activeProfile = try SemanticSource.profileID(configuration)
            guard snapshot.profileID == activeProfile,
                let current = try self.snapshot(
                    id: snapshot.itemID, configuration: configuration, profileID: snapshot.profileID),
                current.contentHash == snapshot.contentHash
            else { continue }
            let chunks = try SemanticChunker.chunks(
                current.sourceText, chunkBytes: configuration.chunkBytes,
                overlapBytes: configuration.overlapBytes)
            guard vectors.count == chunks.count else {
                retryAfter[current.itemID] = Date().addingTimeInterval(retryDelay)
                continue
            }
            for vector in vectors {
                try SemanticVectorValidation.validate(vector, dimensions: configuration.dimensions)
            }
            // A metadata-only revision keeps the source content hash. Rebind
            // the completed vectors to the latest head instead of discarding
            // useful work and embedding the same passage again.
            try storage.replace(current, chunks: chunks, vectors: vectors)
            retryAfter.removeValue(forKey: current.itemID)
        }
    }

    private func reconcile(_ configuration: SemanticConfiguration, profileID: String) throws {
        let snapshots = try allSnapshots(configuration: configuration, profileID: profileID)
        try storage.prune(profileID: profileID, keeping: Set(snapshots.map(\.itemID)))
        guard documentJobs.isEmpty, documentTasks.isEmpty else { return }
        for snapshot in snapshots {
            if try storage.hasCurrent(
                itemID: snapshot.itemID, profileID: profileID, contentHash: snapshot.contentHash)
            {
                try storage.rebind(snapshot)
            } else if retryAfter[snapshot.itemID, default: .distantPast] <= Date() {
                scheduleDocument(snapshot, configuration)
                break
            }
        }
    }

    private func scheduleDocument(_ snapshot: SemanticSnapshot, _ configuration: SemanticConfiguration) {
        guard documentJobs[snapshot.itemID] == nil,
            let chunks = try? SemanticChunker.chunks(
                snapshot.sourceText, chunkBytes: configuration.chunkBytes,
                overlapBytes: configuration.overlapBytes)
        else { return }
        let jobID = Identifier.make()
        documentJobs[snapshot.itemID] = jobID
        let currentEpoch = epoch
        let provider = embed
        let mailbox = mailbox
        let task = Task.detached {
            do {
                try Task.checkCancellation()
                let inputs = chunks.map(\.text)
                var vectors: [[Double]] = []
                var position = 0
                while position < inputs.count {
                    try Task.checkCancellation()
                    let end = min(position + 16, inputs.count)
                    vectors += try await provider(configuration, Array(inputs[position..<end]), false)
                    position = end
                }
                try Task.checkCancellation()
                mailbox.append(
                    CompletedSemanticWork(
                        epoch: currentEpoch, jobID: jobID, snapshot: snapshot, queryID: nil,
                        vectors: vectors, failed: false))
            } catch is CancellationError {
                return
            } catch {
                mailbox.append(
                    CompletedSemanticWork(
                        epoch: currentEpoch, jobID: jobID, snapshot: snapshot, queryID: nil,
                        vectors: nil, failed: true))
            }
        }
        documentTasks[snapshot.itemID] = task
    }

    private func scheduleOneQuery(_ configuration: SemanticConfiguration, profileID: String) {
        guard queryJobs.isEmpty, queryTasks.isEmpty else { return }
        guard
            let query = queries.values.sorted(by: { $0.createdAt < $1.createdAt }).first(where: {
                $0.profileID == profileID && $0.expiresAt > Date() && queryVectors[$0.queryID] == nil
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
                        epoch: currentEpoch, jobID: jobID, snapshot: nil, queryID: query.queryID,
                        vectors: vectors, failed: false))
            } catch is CancellationError {
                return
            } catch {
                mailbox.append(
                    CompletedSemanticWork(
                        epoch: currentEpoch, jobID: jobID, snapshot: nil, queryID: query.queryID,
                        vectors: nil, failed: true))
            }
        }
        queryTasks[query.queryID] = task
    }

    private func readableSnapshots(configuration: SemanticConfiguration, profileID: String) throws
        -> [SemanticSnapshot]
    {
        try store.candidates().compactMap {
            try snapshot($0, configuration: configuration, profileID: profileID)
        }
    }

    private func allSnapshots(configuration: SemanticConfiguration, profileID: String) throws
        -> [SemanticSnapshot]
    {
        try store.candidates().compactMap {
            try snapshot($0, configuration: configuration, profileID: profileID)
        }
    }

    private func snapshot(id: String, configuration: SemanticConfiguration, profileID: String) throws
        -> SemanticSnapshot?
    {
        try snapshot(store.get(id), configuration: configuration, profileID: profileID)
    }

    private func snapshot(_ revision: Revision, configuration: SemanticConfiguration, profileID: String)
        throws
        -> SemanticSnapshot?
    {
        guard !revision.isDeleted else { return nil }
        let corpus = ItemTextContent.corpus(for: revision)
        let sourceText = corpus.sourceText
        guard !sourceText.isEmpty else { return nil }
        let contentHash = try SemanticSource.contentHash(sourceText: sourceText)
        return SemanticSnapshot(
            itemID: revision.itemID,
            revisionID: revision.revisionID,
            subject: corpus.subject,
            body: corpus.body,
            sourceText: sourceText,
            profileID: profileID,
            contentHash: contentHash)
    }

    private func eligibleSnapshots(_ query: SemanticQuery, configuration: SemanticConfiguration) throws
        -> [SemanticSnapshot]
    {
        let revisions: [Revision]
        if let viewID = query.viewID {
            guard query.expression == nil, query.categoryPath.isEmpty, query.excludedCategoryIDs.isEmpty
            else {
                throw TractandaError(
                    "invalidArguments", "Use either a saved view or inline semantic criteria.")
            }
            revisions = try Categories.savedView(
                store: store, id: viewID, sectionID: nil, at: query.evaluatedAt, timeZone: query.timeZone)
        } else {
            revisions = try Categories.query(
                store: store,
                expression: query.expression,
                text: nil,
                categoryPath: query.categoryPath,
                excludedCategoryIDs: query.excludedCategoryIDs,
                sort: [],
                at: query.evaluatedAt,
                timeZone: query.timeZone)
        }
        return try revisions.compactMap {
            try snapshot($0, configuration: configuration, profileID: query.profileID)
        }
    }

    private func ensureStorage(_ configuration: SemanticConfiguration, profileID: String) throws {
        guard storageProfile != profileID || storageProblem != nil || storage is SemanticMemoryStorage else {
            return
        }
        storage = SemanticMemoryStorage()
        storageProfile = nil
        do {
            storage = try SemanticVec1Storage(
                path: semanticIndexURL.path, dimensions: configuration.dimensions, profileID: profileID)
            storageProfile = profileID
            storageProblem = nil
        } catch {
            try quarantineDerivedIndex()
            storage = try SemanticVec1Storage(
                path: semanticIndexURL.path, dimensions: configuration.dimensions, profileID: profileID)
            storageProfile = profileID
            storageProblem = nil
        }
    }

    private var semanticIndexURL: URL {
        store.indexDirectory.appendingPathComponent("semantic.sqlite")
    }

    private func discardDerivedIndex() throws {
        storage = SemanticMemoryStorage()
        storageProfile = nil
        storageProblem = nil
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = URL(fileURLWithPath: semanticIndexURL.path + suffix)
            if fileManager.fileExists(atPath: path.path) { try fileManager.removeItem(at: path) }
        }
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
        for task in documentTasks.values { task.cancel() }
        for task in queryTasks.values { task.cancel() }
        epoch += 1
        queries.removeAll()
        queryVectors.removeAll()
        queryFailures.removeAll()
        documentJobs.removeAll()
        queryJobs.removeAll()
        documentTasks.removeAll()
        queryTasks.removeAll()
        retryAfter.removeAll()
    }

    private func expireQueries() {
        let now = Date()
        for (queryID, task) in queryTasks where queries[queryID]?.expiresAt ?? .distantPast <= now {
            task.cancel()
        }
        queries = queries.filter { $0.value.expiresAt > now }
        queryVectors = queryVectors.filter { queries[$0.key] != nil }
        queryFailures = queryFailures.filter { queries[$0] != nil }
        queryJobs = queryJobs.filter { queries[$0.key] != nil }
        queryTasks = queryTasks.filter { queries[$0.key] != nil }
    }
}

private func cosine(_ left: [Double], _ right: [Double]) -> Double {
    guard left.count == right.count, !left.isEmpty else { return -.infinity }
    var dot = 0.0
    var leftMagnitude = 0.0
    var rightMagnitude = 0.0
    for (a, b) in zip(left, right) {
        dot += a * b
        leftMagnitude += a * a
        rightMagnitude += b * b
    }
    guard leftMagnitude.isFinite, rightMagnitude.isFinite, leftMagnitude > 0, rightMagnitude > 0 else {
        return -.infinity
    }
    return dot / (sqrt(leftMagnitude) * sqrt(rightMagnitude))
}
