import CTractandaPlatform
import Crypto
import Foundation

/// Immutable, caller-scoped input that can be handed to CPU-only query work. The byte
/// count is the encoded Revision JSON size, excluding collection punctuation.
struct ImmutableReadSnapshot: Sendable {
    let revisions: [Revision]
    let state: String
    let serializedBytes: Int
}

/// Current caller authority captured on the owner queue for one isolated SQL read.
/// Names and group membership are resolved before a worker receives a pool lease.
struct PooledReadAuthority: Sendable, Equatable {
    let principals: ReadPrincipalContext
    let administrator: Bool
    let state: String
}

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A request-scoped, bounded LRU of target-specific personal overlay decisions.
final class CategoryOverrideIndex {
    private let store: ItemStore
    private let ownerNames: Set<String>
    private let uid: UInt32
    private let resolver: PrincipalResolver
    private let targetLimit: Int
    private let byteLimit: Int
    private let overlayLimit: Int
    private var scope: String
    private var overlaysByTargetID: [String: (overlay: Revision?, bytes: Int)] = [:]
    private var targetOrder: [String] = []
    private var cachedBytes = 0

    init(
        store: ItemStore, ownerNames: Set<String>, uid: UInt32, resolver: PrincipalResolver,
        targetLimit: Int, byteLimit: Int, overlayLimit: Int
    ) {
        self.store = store
        self.ownerNames = ownerNames
        self.uid = uid
        self.resolver = resolver
        self.targetLimit = max(1, targetLimit)
        self.byteLimit = max(1, byteLimit)
        self.overlayLimit = max(1, overlayLimit)
        scope = store.personalOverlayCacheScope
    }

    func decision(for item: Revision, categoryID: String) throws -> (decision: String, origin: String)? {
        let overlay = try overlay(forTargetID: item.itemID)
        if let overlay,
            let decision = overlay.fields["personalOverrides"]?.map?[categoryID]?.string
        {
            return (decision, "personal:\(overlay.revisionID)")
        }
        return item.fields["categoryOverrides"]?.map?[categoryID]?.string.map { ($0, "manual") }
    }

    private func overlay(forTargetID targetID: String) throws -> Revision? {
        let currentScope = store.personalOverlayCacheScope
        if currentScope != scope {
            overlaysByTargetID.removeAll()
            targetOrder.removeAll()
            cachedBytes = 0
            scope = currentScope
        }
        if let cached = overlaysByTargetID[targetID] {
            targetOrder.removeAll { $0 == targetID }
            targetOrder.append(targetID)
            return cached.overlay
        }
        let loaded = try store.readablePersonalOverlay(
            targetID: targetID, ownerNames: ownerNames, resolver: resolver, uid: uid,
            overlayLimit: overlayLimit, byteLimit: byteLimit)
        guard loaded.bytes <= byteLimit else {
            throw TractandaError("resourceLimit", "Personal overlays for one target exceed the byte budget.")
        }
        while overlaysByTargetID.count >= targetLimit || loaded.bytes > byteLimit - cachedBytes {
            guard let oldest = targetOrder.first, let removed = overlaysByTargetID.removeValue(forKey: oldest)
            else { break }
            targetOrder.removeFirst()
            cachedBytes -= removed.bytes
        }
        overlaysByTargetID[targetID] = loaded
        targetOrder.append(targetID)
        cachedBytes += loaded.bytes
        return loaded.overlay
    }
}

/// Single synchronous coordinator. A lifetime flock excludes other writers.
/// Raw storage is private to the service. Client access is scoped to one synchronous request.
public final class ItemStore {
    public let root: URL
    /// Reconstructible FTS, vector, and learning-cache files. Durable records and operational
    /// configuration always remain below `root`.
    public let indexDirectory: URL
    public let ownerUID: UInt32
    private var generation = Identifier.make()
    private var accessContext: StoreAccessContext?
    private var accessConfiguration: AccessConfiguration?
    private let accounts: any AccountDirectory
    private struct VisibleStateEntry {
        var token: String
        let account: AccountIdentity
        var userMappings: [String: UInt32]
        var groupMappings: [String: UInt32]
    }
    private var visibleStates: [String: VisibleStateEntry] = [:]
    private var visibleStateOrder: [String] = []
    private var exactScopedStates: [String: (fingerprint: String, token: String)] = [:]
    private var accessPolicyEpoch: UInt64 = 0
    fileprivate var personalOverlayCacheScope: String {
        "\(generation):\(accessPolicyEpoch):\(accessContext?.uid ?? ownerUID)"
    }
    private(set) var stateFullHeadScanCountForTesting = 0
    private var savedViewPages: [String: [String]] = [:]
    private var savedViewPageDependencies: [String: Set<String>] = [:]
    private var savedViewPageOrder: [String] = []
    private var savedViewPageIDs = 0
    private var hasLivePersonalStateMemo: Bool?
    private var clockDependentCategories = false
    private(set) var aclSwiftReadCheckCount = 0
    public var isMultiUser: Bool { accessConfiguration != nil }
    var cursorActorUID: UInt32 { accessContext?.uid ?? UInt32.max }
    var cursorStoreIdentity: String {
        get throws {
            let identity = try canonicalStoreIdentity(creatingIfMissing: false)
            let location = root.standardizedFileURL.resolvingSymlinksInPath().path
            return identity + "\0" + location
        }
    }
    func cursorSortValue(itemID: String, field: String) throws -> Double {
        guard field == "createdAt" || field == "modifiedAt", let head = try currentHead(itemID),
            case .date(let value) = head.fields[field]
        else { throw TractandaError("invalidCursor", "The cursor boundary is no longer available.") }
        guard let timestamp = Timestamp.parse(value)?.timeIntervalSinceReferenceDate, timestamp.isFinite
        else {
            throw TractandaError("invalidCursor", "The cursor boundary is no longer available.")
        }
        return timestamp
    }
    func pooledReadAuthority() throws -> PooledReadAuthority? {
        guard isCanonicalReady, let index else { return nil }
        let uid = accessContext?.uid ?? ownerUID
        if isAdministrator {
            return .init(
                principals: .init(actorUID: uid, users: [:], groups: [:]),
                administrator: true, state: state)
        }
        guard let context = accessContext, let account = context.account,
            account.groupIDs.count <= 1024,
            let names = try index.aclPrincipalNames(maximum: 1024),
            names.users.count + names.groups.count <= 1024,
            context.resolver.cachedPrincipalCount + names.users.count + names.groups.count <= 1024
        else { return nil }
        do {
            var users: [String: UInt32] = [:]
            for name in names.users { users[name] = try context.resolver.userID(name) }
            var groups: [String: (gid: UInt32, member: Bool)] = [:]
            for name in names.groups {
                let gid = try context.resolver.groupID(name)
                groups[name] = (gid, account.groupIDs.contains(gid))
            }
            return .init(
                principals: .init(actorUID: uid, users: users, groups: groups),
                administrator: false, state: state)
        } catch {
            return nil
        }
    }

    func pooledQuerySource(
        classEquals: String?, candidatePlan: SpotlightQuery.IndexCandidatePlan,
        authority: PooledReadAuthority
    ) throws
        -> (sql: String, arguments: [String])
    {
        guard let index, isCanonicalReady else {
            throw TractandaError("indexUnavailable", "The current index is unavailable.")
        }
        return index.pooledQuerySource(
            classEquals: classEquals, candidatePlan: candidatePlan,
            aclUserID: authority.administrator ? nil : authority.principals.actorUID)
    }

    func canReadCurrentItemForPooledQuery(_ id: String) throws -> Bool {
        guard isCanonicalReady, let head = try currentHead(id), !head.isDeleted else { return false }
        return canRead(head)
    }

    func verifyPooledCategorySelection(
        _ selection: PooledCategorySelection?, authority: PooledReadAuthority
    ) throws -> Bool {
        guard let selection else { return true }
        guard
            try pooledApplicablePersonalOwnerNames(authority: authority).sorted()
                == selection.ownerNames
        else {
            return false
        }
        let current = try readableCategoryDefinitions(
            requestedCategoryIDs: Set(selection.path + selection.excluded))
        guard current.count == selection.definitions.count else { return false }
        let revisions = Dictionary(uniqueKeysWithValues: current.map { ($0.itemID, $0.revisionID) })
        return selection.definitions.allSatisfy { revisions[$0.itemID] == $0.revisionID }
    }

    func pooledApplicablePersonalOwnerNames(authority: PooledReadAuthority) throws -> Set<String> {
        if !authority.administrator {
            return Set(
                authority.principals.users.compactMap { name, uid in
                    uid == authority.principals.actorUID ? name : nil
                })
        }
        guard let index, let names = try index.aclPrincipalNames(maximum: 1024) else {
            throw TractandaError("resourceLimit", "Personal owner names exceed the read budget.")
        }
        let resolver =
            accessContext?.resolver
            ?? PrincipalResolver(directory: accounts, configuration: accessConfiguration)
        var applicable: Set<String> = []
        for name in names.users where try resolver.userID(name) == authority.principals.actorUID {
            applicable.insert(name)
        }
        return applicable
    }

    func preparePooledGet(_ ids: [String]) throws
        -> (rows: [ItemIndex.CatalogueRow], notFound: [String])
    {
        guard isCanonicalReady, let index else {
            throw TractandaError("recoveryRequired", "The current catalogue is unavailable.")
        }
        var rows: [ItemIndex.CatalogueRow] = []
        var notFound: [String] = []
        for id in ids {
            try Identifier.validate(id)
            guard let head = try currentHead(id), canRead(head) else {
                notFound.append(id)
                continue
            }
            guard let row = try index.revision(head.revisionID), row.itemID == id else {
                throw TractandaError("recoveryError", "A current indexed revision is missing.")
            }
            rows.append(row)
        }
        return (rows, notFound)
    }

    func verifyPooledGet(_ records: [PooledCanonicalRecord], rows: [ItemIndex.CatalogueRow]) throws
        -> Bool
    {
        guard isCanonicalReady, let index, records.count == rows.count else { return false }
        for (record, row) in zip(records, rows) {
            guard let head = try currentHead(row.itemID), head.revisionID == row.revisionID,
                canRead(head), try index.revision(row.revisionID) == row,
                let currentMetadata = try? FileMetadata.read(at: root.appendingPathComponent(row.path)),
                currentMetadata == record.metadata
            else { return false }
        }
        return true
    }

    func preparePooledHistory(_ id: String) throws -> String {
        guard isCanonicalReady else {
            throw TractandaError("recoveryRequired", "The current catalogue is unavailable.")
        }
        try Identifier.validate(id)
        guard let head = try currentHead(id) else {
            throw TractandaError("notFound", "Item or revision is unavailable.")
        }
        guard canRead(head) else { throw TractandaError("forbidden", "Item access is denied.") }
        return head.revisionID
    }

    func verifyPooledHistory(_ result: PooledHistoryResult, itemID: String, headRevisionID: String)
        throws -> Bool
    {
        guard isCanonicalReady, let index, result.records.count == result.rows.count,
            let head = try currentHead(itemID), head.revisionID == headRevisionID,
            canRead(head)
        else { return false }
        for (record, row) in zip(result.records, result.rows) {
            guard row.itemID == itemID, record.revision.itemID == itemID,
                let current = try index.revision(row.revisionID),
                current.path == row.path, current.digest == row.digest,
                current.parentID == row.parentID, current.createdAt == row.createdAt,
                let metadata = try? FileMetadata.read(at: root.appendingPathComponent(row.path)),
                metadata == record.metadata
            else { return false }
        }
        return true
    }
    /// Internal maintenance has no client context and remains privileged. Client contexts
    /// carry the policy result evaluated from a fresh OS account snapshot.
    public var isAdministrator: Bool { accessContext == nil || accessContext?.isAdministrator == true }
    public var accessScope: String {
        guard isMultiUser else { return "single-user" }
        return accessContext?.account.map { "user:\($0.name)" } ?? "service"
    }
    private var savedViewAuthorizationKey: String {
        guard isMultiUser else { return "single-user" }
        guard let context = accessContext else { return "internal" }
        let groups = context.account?.groupIDs.sorted().map(String.init).joined(separator: ",") ?? ""
        return "\(context.uid):\(context.account?.name ?? "uid"):\(groups):\(context.isAdministrator)"
    }
    /// A private edit must not change another caller's synchronization token.
    public var state: String {
        guard !isAdministrator, let context = accessContext else { return generation }
        if isMultiUser, let account = context.account, let index,
            let names = try? index.aclPrincipalNames(maximum: 1024),
            names.users.count + names.groups.count <= 1024,
            context.resolver.cachedPrincipalCount + names.users.count + names.groups.count <= 1024
        {
            do {
                var users: [String: UInt32] = [:]
                var groups: [String: UInt32] = [:]
                for name in names.users { users[name] = try context.resolver.userID(name) }
                for name in names.groups { groups[name] = try context.resolver.groupID(name) }
                let groupList = account.groupIDs.sorted().map(String.init).joined(separator: ",")
                let key = "\(context.uid):\(account.name):\(groupList):\(accessPolicyEpoch)"
                if var entry = visibleStates[key] {
                    let changedUsers = entry.userMappings.contains { name, old in
                        users[name].map { $0 != old } ?? true
                    }
                    let changedGroups = entry.groupMappings.contains { name, old in
                        groups[name].map { $0 != old } ?? true
                    }
                    if changedUsers || changedGroups { entry.token = Identifier.make() }
                    entry.userMappings = users
                    entry.groupMappings = groups
                    visibleStates[key] = entry
                    visibleStateOrder.removeAll { $0 == key }
                    visibleStateOrder.append(key)
                    return entry.token
                }
                if visibleStates.count >= 64, let evicted = visibleStateOrder.first {
                    visibleStates.removeValue(forKey: evicted)
                    visibleStateOrder.removeFirst()
                }
                let token = Identifier.make()
                visibleStates[key] = VisibleStateEntry(
                    token: token, account: account,
                    userMappings: users, groupMappings: groups)
                visibleStateOrder.append(key)
                return token
            } catch {
                // An incomplete principal snapshot uses the exact serial state calculation below.
            }
        }
        stateFullHeadScanCountForTesting += 1
        var hasher = SHA256()
        do {
            try forEachCurrentHead { head in
                guard head.canRead(accessContext, administrator: isAdministrator) else { return }
                hasher.update(data: Data((head.itemID + ":" + head.revisionID + "\n").utf8))
                if head.classID == "PersonalStateItem",
                    let owner = head.fields["permissions"]?.map?["owner"]?.string
                {
                    let resolved = try? context.resolver.userID(owner)
                    let ownerState =
                        head.itemID + ":" + owner + ":" + (resolved.map(String.init) ?? "unresolved") + "\n"
                    hasher.update(data: Data(ownerState.utf8))
                }
            }
        } catch {
            // Incomplete index/resolver state must invalidate rather than reuse an old token.
            return Identifier.make()
        }
        let groupState = context.account?.groupIDs.sorted().map(String.init).joined(separator: ",") ?? ""
        hasher.update(data: Data(groupState.utf8))
        hasher.update(data: Data((context.account.map { "\($0.uid):\($0.name)" } ?? "").utf8))
        let fingerprint = Data(hasher.finalize()).base64EncodedString()
        if let previous = exactScopedStates[accessScope], previous.fingerprint == fingerprint {
            return previous.token
        }
        if exactScopedStates.count >= 256 { exactScopedStates.removeAll() }
        let token = Identifier.make()
        exactScopedStates[accessScope] = (fingerprint, token)
        return token
    }
    private func updateVisibleStates(old: ResidentHead?, new: ResidentHead) {
        guard !visibleStates.isEmpty else { return }
        for key in visibleStateOrder {
            guard var entry = visibleStates[key] else { continue }
            let resolver = PrincipalResolver(directory: accounts, configuration: accessConfiguration)
            if let value = new.fields["permissions"], let permissions = try? ItemPermissions(value) {
                // Record the current binding even for a hidden newly named principal. A later
                // remap can make this formerly hidden head visible before the next query.
                for name in [permissions.owner] + permissions.users.keys.sorted() {
                    if entry.userMappings[name] == nil, let id = try? resolver.userID(name) {
                        entry.userMappings[name] = id
                    }
                }
                for name in [permissions.group] + permissions.groups.keys.sorted() {
                    if entry.groupMappings[name] == nil, let id = try? resolver.groupID(name) {
                        entry.groupMappings[name] = id
                    }
                }
            }
            func readable(_ head: ResidentHead?) throws -> Bool {
                guard let head, !head.isDeleted, head.classID != AccessConfiguration.classID,
                    let value = head.fields["permissions"]
                else { return false }
                return try ItemPermissions(value).allows(4, for: entry.account, using: resolver)
            }
            do {
                if try readable(old) || readable(new) { entry.token = Identifier.make() }
            } catch {
                // A changed head whose current authority cannot be resolved invalidates safely.
                entry.token = Identifier.make()
            }
            visibleStates[key] = entry
        }
    }
    public private(set) var recoveryWarnings: [String] = []
    public private(set) var startupRecovery: [String: String] = ["mode": "pending"]
    private var writer: Int32 = -1
    private var indexWriter: Int32 = -1
    private let usesExternalIndexDirectory: Bool
    private var index: ItemIndex?
    private var indexRebuildInProgress = false
    /// Full recovery validates every immutable file, then keeps only locations for history.
    /// Current heads remain resident; old bodies are loaded through the bounded cache below.
    private struct RevisionLocation {
        let itemID: String
        let relativePath: String
        let actor: String
        let operationID: String
        let parentID: String?
        let metadata: FileMetadata
        let digest: Data
        let createdAt: String
        let feedbackRevisionIDs: [String]

        init(
            itemID: String, relativePath: String, actor: String, operationID: String,
            parentID: String?, metadata: FileMetadata, digest: Data,
            createdAt: String = "", feedbackRevisionIDs: [String] = []
        ) {
            self.itemID = itemID
            self.relativePath = relativePath
            self.actor = actor
            self.operationID = operationID
            self.parentID = parentID
            self.metadata = metadata
            self.digest = digest
            self.createdAt = createdAt
            self.feedbackRevisionIDs = feedbackRevisionIDs
        }

        func url(root: URL) -> URL { root.appendingPathComponent(relativePath) }

        init(_ row: ItemIndex.CatalogueRow) {
            itemID = row.itemID
            relativePath = row.path
            actor = row.actor
            operationID = row.operationID
            parentID = row.parentID
            metadata = FileMetadata(
                mode: row.mode, uid: row.uid, gid: 0, size: row.size, inode: row.inode,
                device: 0, modificationSeconds: row.modificationSeconds,
                modificationNanoseconds: row.modificationNanoseconds)
            digest = row.digest
            createdAt = row.createdAt
            feedbackRevisionIDs = row.feedbackRevisionIDs
        }

        func catalogueRow(revisionID: String) -> ItemIndex.CatalogueRow {
            ItemIndex.CatalogueRow(
                revisionID: revisionID, itemID: itemID,
                path: relativePath, parentID: parentID,
                actor: actor, operationID: operationID, size: metadata.size,
                inode: metadata.inode, uid: metadata.uid,
                mode: metadata.mode, modificationSeconds: metadata.modificationSeconds,
                modificationNanoseconds: metadata.modificationNanoseconds, digest: digest,
                createdAt: createdAt, feedbackRevisionIDs: feedbackRevisionIDs)
        }
    }
    /// A current head is either a complete value or a typed summary whose omitted payload
    /// must be loaded from its canonical revision before any Revision API can observe it.
    private struct ResidentHead {
        let itemID: String
        let revisionID: String
        let classID: String
        let isDeleted: Bool
        let fields: [String: ItemValue]
        let full: Revision?

        init(_ revision: Revision, evictContent: Bool = false) {
            itemID = revision.itemID
            revisionID = revision.revisionID
            classID = revision.classID
            isDeleted = revision.isDeleted
            if evictContent {
                fields = Self.compactFields(revision.fields)
                full = nil
            } else {
                fields = revision.fields
                full = revision
            }
        }

        init(
            itemID: String,
            summary: (revisionID: String, classID: String, isDeleted: Bool, fields: [String: ItemValue])
        ) {
            self.itemID = itemID
            revisionID = summary.revisionID
            classID = summary.classID
            isDeleted = summary.isDeleted
            fields = Self.compactFields(summary.fields)
            full = nil
        }

        private static func compactFields(_ source: [String: ItemValue]) -> [String: ItemValue] {
            source.filter { ItemIndex.headSummaryFieldNames.contains($0.key) }
        }

        var needsHydration: Bool { full == nil }
        func canRead(_ context: StoreAccessContext?, administrator: Bool) -> Bool {
            if administrator { return true }
            guard classID != AccessConfiguration.classID,
                let context, let account = context.account,
                let value = fields["permissions"]
            else { return false }
            return (try? ItemPermissions(value).allows(4, for: account, using: context.resolver)) == true
        }
    }
    private struct RecoveryRevision {
        let revisionID: String
        let itemID: String
        let createdAt: ItemValue
        let supersedes: String?
        let actor: String
        let operationID: String
        let feedback: [ItemValue]
        let contentDigest: Data
    }
    private struct RecoveryPhaseMetrics {
        let enumerationStart: TimeInterval
        let enumerationEnd: TimeInterval
        let chainStart: TimeInterval
        let chainEnd: TimeInterval
        let finalizationStart: TimeInterval
        let finalizationEnd: TimeInterval
        let recordReadDecodeSeconds: TimeInterval
        let recordReadSeconds: TimeInterval
        let recordDecodeSeconds: TimeInterval
        let recordHashSeconds: TimeInterval
        let semanticValidationSeconds: TimeInterval
    }
    private var revisionLocations: [String: RevisionLocation] = [:]
    private var historicalCache: [String: (revision: Revision, bytes: Int)] = [:]
    private var historicalOrder: [String] = []
    private var historicalCacheBytes = 0
    private static let historicalCacheLimit = 16 * 1024 * 1024
    private var heads: [String: ResidentHead] = [:]
    private var headCacheOrder: [String] = []
    private var headCacheBytes = 0
    private static let headCacheEntryLimit = 128
    private static let headCacheByteLimit = 4 * 1024 * 1024
    private static let categoryWorkingSetLimit = 4_096
    private static let personalOverlayWorkingSetLimit = 512
    private static let categoryWorkingSetByteLimit = 2 * 1024 * 1024
    private static let personalOverlayWorkingSetByteLimit = 2 * 1024 * 1024
    static let exactQueryCandidateLimit = 512
    // A single valid canonical revision may approach 8 MiB; exact fallback must
    // still serve one such item after the 2 MiB immutable parallel path declines it.
    static let exactQueryByteLimit = 16 * 1024 * 1024
    var exactQueryCandidateLimitForTesting: Int?
    var pooledRecordByteLimitForTesting: Int?
    var pooledHistoryBatchLimitForTesting: Int?
    var pooledRecordByteLimit: Int {
        min(8 * 1024 * 1024, max(1, pooledRecordByteLimitForTesting ?? 8 * 1024 * 1024))
    }
    var pooledHistoryBatchLimit: Int {
        min(512, max(1, pooledHistoryBatchLimitForTesting ?? 128))
    }
    var personalOverlayWorkingSetLimitForTesting: Int?
    var personalOverlayTargetCacheLimitForTesting: Int?
    var currentHeadCacheEntryLimitForTesting: Int?
    var categoryGraphClosureLimitForTesting: Int?
    private(set) var lastIndexCandidateCountForTesting = 0
    private(set) var lastSavedViewBaseAppliedForTesting = false
    var currentHeadCacheEntriesForTesting: Int { heads.count }
    func holdIndexStatementForTesting() throws -> OpaquePointer {
        guard let index else { throw TractandaError("indexUnavailable", "Index is unavailable.") }
        return try index.holdStatementForTesting()
    }
    var currentHeadCacheBytesForTesting: Int { headCacheBytes }
    var evictedCurrentHeadCount: Int { max(0, ((try? index?.currentHeadCount()) ?? 0) - heads.count) }
    var historicalCacheBytesForTesting: Int { historicalCacheBytes }
    var currentHeadHydrationsForTesting = 0
    var onCurrentHeadHydrationForTesting: ((String) -> Void)?
    private var operations: [String: String] = [:]
    private var operationIDs: [String: [String]] = [:]

    private func residentByteCount(_ head: ResidentHead) throws -> Int {
        try JSON.encode(head.fields).count + head.itemID.utf8.count + head.revisionID.utf8.count
            + head.classID.utf8.count
    }

    private func rememberHead(_ head: ResidentHead) throws {
        if let previous = heads.removeValue(forKey: head.itemID) {
            headCacheBytes -= try residentByteCount(previous)
            headCacheOrder.removeAll { $0 == head.itemID }
        }
        let bytes = try residentByteCount(head)
        guard bytes <= Self.headCacheByteLimit else { return }
        while heads.count >= (currentHeadCacheEntryLimitForTesting ?? Self.headCacheEntryLimit)
            || headCacheBytes + bytes > Self.headCacheByteLimit
        {
            guard let oldest = headCacheOrder.first, let evicted = heads.removeValue(forKey: oldest) else {
                break
            }
            headCacheOrder.removeFirst()
            headCacheBytes -= try residentByteCount(evicted)
        }
        heads[head.itemID] = head
        headCacheOrder.append(head.itemID)
        headCacheBytes += bytes
    }

    private func currentHead(_ itemID: String) throws -> ResidentHead? {
        if let cached = heads[itemID] {
            headCacheOrder.removeAll { $0 == itemID }
            headCacheOrder.append(itemID)
            return cached
        }
        guard let index, let summary = try index.currentHeadSummary(itemID) else { return nil }
        let head = ResidentHead(itemID: itemID, summary: summary)
        try rememberHead(head)
        return head
    }

    private func forEachCurrentHead(classID: String? = nil, _ body: (ResidentHead) throws -> Void) throws {
        guard let index else {
            throw TractandaError("indexUnavailable", "The current-head index is unavailable.")
        }
        var cursor: String?
        while let itemID = try index.currentHeadID(after: cursor, classID: classID) {
            cursor = itemID
            guard let head = try currentHead(itemID) else {
                throw TractandaError("indexError", "A current-head summary disappeared during iteration.")
            }
            try body(head)
        }
    }

    private func forEachCategoryHead(_ body: (ResidentHead) throws -> Void) throws {
        guard let index else {
            throw TractandaError("indexUnavailable", "The category index is unavailable.")
        }
        var cursor: String?
        while let itemID = try index.currentCategoryHeadID(after: cursor) {
            cursor = itemID
            guard let head = try currentHead(itemID) else {
                throw TractandaError("indexError", "An indexed category summary disappeared.")
            }
            try body(head)
        }
    }

    private func canonicalSize(for head: ResidentHead) throws -> Int {
        guard let row = try index?.revision(head.revisionID), row.size <= 8 * 1024 * 1024 else {
            throw TractandaError("recoveryError", "Current revision location is unavailable.")
        }
        return Int(row.size)
    }

    private func currentRevision(_ itemID: String) throws -> Revision? {
        guard let resident = try currentHead(itemID) else { return nil }
        if let full = resident.full { return full }
        currentHeadHydrationsForTesting += 1
        onCurrentHeadHydrationForTesting?(itemID)
        guard let revision = try loadRevision(resident.revisionID) else {
            throw TractandaError("recoveryError", "Current revision location is unavailable.")
        }
        return revision
    }

    private func retainedCategoryRevisions(excluding itemID: String) throws -> [Revision] {
        var revisions: [Revision] = []
        var retainedBytes = 0
        try forEachCategoryHead { head in
            guard head.itemID != itemID,
                head.fields["selection"] != nil || head.fields["categoryParents"] != nil
            else { return }
            guard revisions.count < Self.categoryWorkingSetLimit else {
                throw TractandaError("resourceLimit", "Category graph exceeds the bounded working set.")
            }
            let bytes = try canonicalSize(for: head)
            guard bytes <= Self.categoryWorkingSetByteLimit - retainedBytes else {
                throw TractandaError("resourceLimit", "Category definitions exceed the bounded byte budget.")
            }
            retainedBytes += bytes
            guard let revision = try currentRevision(head.itemID) else {
                throw TractandaError("recoveryError", "Category head needs canonical hydration.")
            }
            revisions.append(revision)
        }
        return revisions
    }

    private func retainedConfigurationRevisions(excluding itemID: String) throws -> [Revision] {
        guard let summary = try index?.currentHeadSummary(classID: AccessConfiguration.classID),
            summary.itemID != itemID
        else { return [] }
        guard let revision = try currentRevision(summary.itemID) else {
            throw TractandaError("recoveryError", "Access configuration head is incomplete.")
        }
        return [revision]
    }

    private static func residentHead(_ revision: Revision) -> ResidentHead {
        ResidentHead(revision, evictContent: true)
    }

    private func installIndexFailureHandler(_ candidate: ItemIndex) {
        candidate.onPersistentFailure = { [weak self] in self?.quarantineCheckpoint() }
    }

    private func quarantineCheckpoint() {
        guard isCanonicalReady else { return }
        isCanonicalReady = false
        canonicalVerificationStatus = ["state": "recoveryRequired", "reason": "indexFailure"]
        do {
            try beforeIndexQuarantineMarkerForTesting?()
            try StoreCheckpoint.markDirty(root: root)
        } catch {
            canonicalVerificationStatus["state"] = "fatalRecoverySignalFailure"
            canonicalVerificationStatus["markerError"] = String(describing: error)
            canonicalVerificationStatus["restartMayReuseCheckpoint"] = true
        }
    }

    private var isCanonicalReady = false
    private struct VerificationAccumulation {
        let generation: String
        var observedFindings = 0
        var confirmedFindings = 0
        var metadataIndicators = 0
        var details: [[String: String]] = []
    }
    private var verificationAccumulation: VerificationAccumulation?
    var verificationDetailLimitForTesting: Int?
    private var verificationDetailLimit: Int {
        min(100, max(0, verificationDetailLimitForTesting ?? 100))
    }
    private(set) var checkpointHeadRowsLoadedForTesting = 0
    private(set) var checkpointCatalogueRowsLoadedForTesting = 0
    private(set) var checkpointCanonicalHeadReadsForTesting = 0
    var isCanonicalTrusted: Bool { isCanonicalReady }
    private(set) var canonicalVerificationStatus: [String: Any] = ["state": "pending"]
    // Failure injection at the file/index boundary, available to core tests only.
    var beforeIndexUpdate: (() throws -> Void)?
    var beforeCheckpointClear: (() throws -> Void)?
    var beforeCanonicalDurabilitySync: (() throws -> Void)?
    var publishResultOverrideForTesting: Int32?
    var beforeCategoryGraphValidation: (() -> Void)?
    var beforeCategoryOverlayScan: (() -> Void)?
    var afterRecoveryRecordForTesting: ((URL) throws -> Void)?
    var beforeIndexQuarantineMarkerForTesting: (() throws -> Void)?
    // Deterministic collision injection in tests; production uses the UUIDv1 generator.
    var makePersistentUUID: () throws -> UUID = { try UUID.makeVersion1() }
    private static let managed: Set<String> = [
        "itemID", "revisionID", "classID", "schemaVersion",
        "createdAt", "modifiedAt", "supersedes", "actor", "operationID", "requestIdentity",
    ]

    public init(
        root: URL, indexDirectory requestedIndexDirectory: URL? = nil,
        accounts: any AccountDirectory = SystemAccountDirectory()
    ) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.accounts = accounts
        ownerUID = tractanda_uid()
        guard self.root.path != "/" else {
            throw TractandaError("invalidStore", "Choose a dedicated store directory.")
        }
        let defaultIndexDirectory = self.root.appendingPathComponent("index")
        if let requestedIndexDirectory {
            guard requestedIndexDirectory.path.hasPrefix("/") else {
                throw TractandaError("invalidIndexDirectory", "Choose an absolute index directory.")
            }
            // Preserve the caller's lexical root relationship as well as the later physical-path
            // check. On macOS Foundation can normalize an existing `/private/tmp` root and an
            // absent descendant at different times.
            let suppliedPath = requestedIndexDirectory.standardizedFileURL.path
            let itemPath = root.standardizedFileURL.appendingPathComponent("items").path
            guard suppliedPath != itemPath && !suppliedPath.hasPrefix(itemPath + "/") else {
                throw TractandaError(
                    "invalidIndexDirectory", "Index files cannot be stored inside canonical items.")
            }
            let supplied = URL(fileURLWithPath: requestedIndexDirectory.path, isDirectory: true)
            // Detect a supplied leaf link before canonicalizing ordinary system aliases such as
            // `/tmp` on macOS. The resolved directory below is then checked component by component.
            if let metadata = try? FileMetadata.read(at: supplied), metadata.type == .symbolicLink {
                throw TractandaError(
                    "unsafeIndexDirectory", "Index directory cannot be a symbolic link: \(supplied.path)")
            }
            self.indexDirectory = supplied.resolvingSymlinksInPath()
        } else {
            self.indexDirectory = defaultIndexDirectory
        }
        usesExternalIndexDirectory = self.indexDirectory.path != defaultIndexDirectory.path
        guard !Self.isDescendant(self.indexDirectory, of: self.root.appendingPathComponent("items")) else {
            throw TractandaError(
                "invalidIndexDirectory", "Index files cannot be stored inside canonical items.")
        }
        try ensureDirectory(self.root)
        writer = tractanda_lock(self.root.appendingPathComponent(".writer.lock").path)
        guard writer >= 0 else {
            throw TractandaError("storeBusy", "Cannot lock store; another writer may be running.")
        }
        do {
            try ensureDirectory(self.root.appendingPathComponent("items"))
            try rejectIndexInsideCanonicalItems()
            try ensureDirectory(indexDirectory)
            if usesExternalIndexDirectory {
                try bindExternalIndexDirectory()
            } else {
                _ = try canonicalStoreIdentity(creatingIfMissing: true)
            }
            if StoreCheckpoint.isDirty(root: self.root) {
                startupRecovery = ["mode": "fullRecovery", "reason": "dirtyMarker"]
                try rebuildIndex()
            } else if (try? loadFromCheckpoint()) == true {
                startupRecovery = ["mode": "checkpoint"]
            } else {
                let database = indexDirectory.appendingPathComponent("items.sqlite")
                startupRecovery = [
                    "mode": "fullRecovery",
                    "reason": FileManager.default.fileExists(atPath: database.path)
                        ? "checkpointInvalidOrIncompatible" : "checkpointMissing",
                ]
                try rebuildIndex()
            }
        } catch {
            if indexWriter >= 0 { tractanda_unlock(indexWriter) }
            tractanda_unlock(writer)
            writer = -1
            throw error
        }
    }
    deinit {
        if indexWriter >= 0 { tractanda_unlock(indexWriter) }
        if writer >= 0 { tractanda_unlock(writer) }
    }

    private struct IndexBinding: Codable, Equatable {
        let formatVersion: Int
        let canonicalPath: String
        let storeID: String
        let canonicalDevice: UInt64
        let canonicalInode: UInt64

        func identifiesSameStore(as other: Self) -> Bool {
            formatVersion == other.formatVersion && storeID == other.storeID
        }
    }

    private struct LegacyIndexBinding: Codable, Equatable {
        let formatVersion: Int
        let canonicalPath: String
        let canonicalDevice: UInt64
        let canonicalInode: UInt64

        func identifiesSameStore(as root: URL, metadata: FileMetadata) -> Bool {
            formatVersion == 1 && canonicalPath == root.path && canonicalDevice == metadata.device
                && canonicalInode == metadata.inode
        }
    }

    private struct CanonicalStoreIdentity: Codable, Equatable {
        let formatVersion: Int
        let storeID: String
    }

    private static let indexBindingName = ".tractanda-index-binding.json"
    private static let indexLockName = ".tractanda-index.writer.lock"
    private static let canonicalIdentityName = ".tractanda-store-identity.json"

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        // Resolve existing parent aliases (notably macOS `/tmp`) before comparing. A supplied
        // path may have an absent leaf while its canonical `items` ancestor already exists.
        let candidatePath = candidate.resolvingSymlinksInPath().path
        let parentPath = parent.resolvingSymlinksInPath().path
        return candidatePath == parentPath || candidatePath.hasPrefix(parentPath + "/")
    }

    /// Compare directory identities while walking an existing external-path ancestor. String
    /// prefixes alone are unsafe here because macOS can render `/tmp` and `/private/tmp`
    /// differently when an index leaf has not been created yet.
    private func rejectIndexInsideCanonicalItems() throws {
        let canonicalItems = try FileMetadata.read(at: root.appendingPathComponent("items"))
        var ancestor = indexDirectory
        while ancestor.path != "/" {
            if let metadata = try? FileMetadata.read(at: ancestor),
                metadata.type == .directory, metadata.device == canonicalItems.device,
                metadata.inode == canonicalItems.inode
            {
                throw TractandaError(
                    "invalidIndexDirectory", "Index files cannot be stored inside canonical items.")
            }
            ancestor.deleteLastPathComponent()
        }
    }

    private func bindExternalIndexDirectory() throws {
        let lockURL = indexDirectory.appendingPathComponent(Self.indexLockName)
        indexWriter = tractanda_lock(lockURL.path)
        guard indexWriter >= 0 else {
            throw TractandaError("indexBusy", "Derived index directory is in use by another store.")
        }
        do {
            try PrivateConfiguration.validate(lockURL, directory: false)
            let markerURL = indexDirectory.appendingPathComponent(Self.indexBindingName)
            var hasUnexpectedEntry = false
            try POSIXDirectory.withEntries(at: indexDirectory) { name in
                hasUnexpectedEntry = name != Self.indexLockName && name != Self.indexBindingName
                return !hasUnexpectedEntry
            }
            let rootMetadata = try FileMetadata.read(at: root)
            if FileManager.default.fileExists(atPath: markerURL.path) {
                try PrivateConfiguration.validate(markerURL, directory: false)
                let marker = try Data(contentsOf: markerURL)
                let formatVersion = try JSON.decode(BindingFormat.self, marker).formatVersion
                switch formatVersion {
                case 1:
                    let legacy = try JSON.decode(LegacyIndexBinding.self, marker)
                    guard legacy.identifiesSameStore(as: root, metadata: rootMetadata) else {
                        throw TractandaError(
                            "indexBindingMismatch",
                            "Derived index directory has a legacy binding mismatch; rebuild the derived index directory."
                        )
                    }
                    let binding = try currentIndexBinding(rootMetadata: rootMetadata, creatingIdentity: true)
                    try PrivateConfiguration.write(try JSON.encode(binding), to: markerURL)
                case 2:
                    let binding = try currentIndexBinding(rootMetadata: rootMetadata, creatingIdentity: false)
                    let existing = try JSON.decode(IndexBinding.self, marker)
                    guard existing.identifiesSameStore(as: binding) else {
                        throw TractandaError(
                            "indexBindingMismatch",
                            "Derived index directory belongs to another canonical store.")
                    }
                    if existing != binding {
                        try PrivateConfiguration.write(try JSON.encode(binding), to: markerURL)
                    }
                default:
                    throw TractandaError(
                        "indexBindingMismatch", "Derived index directory has an unsupported binding format.")
                }
            } else {
                guard !hasUnexpectedEntry else {
                    throw TractandaError(
                        "indexBindingRequired", "Refusing an unbound nonempty derived index directory.")
                }
                let binding = try currentIndexBinding(rootMetadata: rootMetadata, creatingIdentity: true)
                try PrivateConfiguration.write(try JSON.encode(binding), to: markerURL)
            }
        } catch {
            tractanda_unlock(indexWriter)
            indexWriter = -1
            throw error
        }
    }

    private struct BindingFormat: Decodable {
        let formatVersion: Int
    }

    private func currentIndexBinding(rootMetadata: FileMetadata, creatingIdentity: Bool) throws
        -> IndexBinding
    {
        IndexBinding(
            formatVersion: 2, canonicalPath: root.path,
            storeID: try canonicalStoreIdentity(creatingIfMissing: creatingIdentity),
            canonicalDevice: rootMetadata.device, canonicalInode: rootMetadata.inode)
    }

    /// This identity belongs to canonical storage, never to a disposable index. The root writer
    /// lock is held before this method can run, so creation cannot race another store process.
    private func canonicalStoreIdentity(creatingIfMissing: Bool) throws -> String {
        let identityURL = root.appendingPathComponent(Self.canonicalIdentityName)
        do {
            _ = try FileMetadata.read(at: identityURL)
            try PrivateConfiguration.validate(identityURL, directory: false)
            let identity = try JSON.decode(CanonicalStoreIdentity.self, Data(contentsOf: identityURL))
            guard identity.formatVersion == 1, let uuid = UUID(uuidString: identity.storeID),
                uuid.version1Components != nil
            else {
                throw TractandaError("invalidStoreIdentity", "Canonical store identity is invalid.")
            }
            return uuid.uuidString.lowercased()
        } catch FileMetadataError.posix(let code) where code == ENOENT {
            // A missing identity is handled below. Any other lstat failure remains fatal.
        } catch {
            throw error
        }
        guard creatingIfMissing else {
            throw TractandaError(
                "indexBindingMismatch",
                "Canonical store identity is missing; rebuild the derived index directory.")
        }
        let identity = CanonicalStoreIdentity(
            formatVersion: 1, storeID: try UUID.makeVersion1().uuidString.lowercased())
        try PrivateConfiguration.write(try JSON.encode(identity), to: identityURL)
        return identity.storeID
    }

    private func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let metadata = try FileMetadata.read(at: url)
        guard metadata.type == .directory, metadata.uid == ownerUID, metadata.mode & 0o077 == 0
        else {
            throw TractandaError(
                "unsafeStore",
                "Store directories must be owned by the service user and private (0700): \(url.path)")
        }
    }
    private func operationKey(actor: String, id: String) -> String { actor + "\0" + id }

    /// No suspension is permitted inside this scope; ItemService runs on the store's serial executor.
    public func withAccess<T>(forUID uid: UInt32, _ body: () throws -> T) throws -> T {
        let resolver = PrincipalResolver(directory: accounts, configuration: accessConfiguration)
        let account: AccountIdentity?
        let administrator: Bool
        if let configuration = accessConfiguration {
            if configuration.administration == .system && uid == 0 {
                // Root must be able to repair a stale administrator-group name.
                account = try? accounts.user(forUID: uid)
                administrator = true
            } else {
                account = try accounts.user(forUID: uid)
                switch configuration.administration {
                case .serviceOwner:
                    administrator = uid == ownerUID
                case .system:
                    let administratorGroup = try accounts.groupID(
                        named: configuration.administratorGroup
                            ?? AccessConfiguration.defaultAdministratorGroup)
                    administrator = account!.groupIDs.contains(administratorGroup)
                }
            }
            if !administrator {
                try configuration.validate(using: resolver)
                let admittedUser = try configuration.users.contains { try resolver.userID($0) == uid }
                let admittedGroup = try configuration.groups.contains {
                    try account!.groupIDs.contains(resolver.groupID($0))
                }
                guard admittedUser || admittedGroup else {
                    throw TractandaError("forbidden", "This account is not admitted to the store.")
                }
            }
        } else {
            guard uid == ownerUID else {
                throw TractandaError("forbidden", "This store admits only its owning OS user.")
            }
            // Legacy single-user containers need not have a passwd entry for their numeric UID.
            account = nil
            administrator = true
        }
        let previous = accessContext
        accessContext = StoreAccessContext(
            uid: uid, account: account, resolver: resolver, isAdministrator: administrator)
        defer { accessContext = previous }
        return try body()
    }

    /// Returns a directory-backed identity only after the same admission policy used for requests.
    public func accountIdentity(forUID uid: UInt32) throws -> AccountIdentity {
        try withAccess(forUID: uid) {
            if let account = accessContext?.account { return account }
            return try accounts.user(forUID: uid)
        }
    }

    public func requireAdministrator() throws {
        guard isAdministrator else {
            throw TractandaError("forbidden", "Store administration requires an authorized administrator.")
        }
    }

    private func canRead(_ head: Revision) -> Bool {
        if isAdministrator { return true }
        aclSwiftReadCheckCount += 1
        guard head.classID != AccessConfiguration.classID,
            let context = accessContext, let account = context.account,
            let value = head.fields["permissions"]
        else { return false }
        return (try? ItemPermissions(value).allows(4, for: account, using: context.resolver)) == true
    }

    private func canRead(_ head: ResidentHead) -> Bool {
        if !isAdministrator { aclSwiftReadCheckCount += 1 }
        return head.canRead(accessContext, administrator: isAdministrator)
    }

    private func requireRead(_ head: Revision) throws {
        guard canRead(head) else { throw TractandaError("forbidden", "Item access is denied.") }
    }

    private func requireEdit(_ head: Revision, changesPermissions: Bool = false) throws {
        if isAdministrator { return }
        guard head.classID != AccessConfiguration.classID,
            let context = accessContext, let account = context.account,
            let value = head.fields["permissions"]
        else { throw TractandaError("forbidden", "Item editing is denied.") }
        let permissions = try ItemPermissions(value)
        guard try permissions.allows(6, for: account, using: context.resolver),
            try !changesPermissions || context.resolver.userID(permissions.owner) == account.uid
        else {
            throw TractandaError(
                "forbidden", "Only an authorized editor may edit, and only the owner may change sharing.")
        }
    }

    private func priorOperation(_ id: String, uid: UInt32) throws -> Revision? {
        guard let index, let receipts = try index.receipts(named: id) else {
            throw TractandaError(
                "indexUnavailable",
                "Operation receipt candidates exceed the safe bound or index is unavailable.")
        }
        let matches = receipts.compactMap { row -> String? in
            let actor = row.actor
            if actor == "uid:\(uid)", uid == ownerUID { return row.revisionID }
            if actor.hasPrefix("uid:"), let legacyUID = UInt32(actor.dropFirst(4)),
                let legacyUser = accessConfiguration?.legacyUsers[legacyUID], let context = accessContext
            {
                // Preserve receipt bytes and old actor identity, but only replay after an
                // explicit canonical mapping resolves to this caller on this request.
                return (try? context.resolver.userID(legacyUser)) == uid ? row.revisionID : nil
            }
            guard actor.hasPrefix("user:"), let context = accessContext else { return nil }
            return (try? context.resolver.userID(String(actor.dropFirst(5)))) == uid ? row.revisionID : nil
        }
        guard matches.count <= 1 else {
            throw TractandaError("operationMismatch", "Aliases merge conflicting operation receipts.")
        }
        guard let revisionID = matches.first else { return nil }
        guard let location = try index.revision(revisionID), let current = try currentHead(location.itemID)
        else {
            throw TractandaError("recoveryError", "Operation receipt points to an unavailable revision.")
        }
        guard canRead(current) else { throw TractandaError("forbidden", "Item access is denied.") }
        return try loadRevision(revisionID)
    }

    public func configureAccess(_ value: ItemValue, operationID: String) throws -> CommitResult {
        try requireAdministrator()
        let configurationSummary = try index?.currentHeadSummary(classID: AccessConfiguration.classID)
        let previous = try configurationSummary.flatMap { try currentRevision($0.itemID) }
        return try commit(
            CommitRequest(
                action: previous == nil ? .create : .revise,
                itemID: previous?.itemID, expectedRevisionID: previous?.revisionID,
                classID: previous == nil ? AccessConfiguration.classID : nil,
                changes: ["accessConfiguration": value, "subject": .text("Store access configuration")],
                operationID: operationID))
    }

    private func configuration(in values: [Revision]) throws -> AccessConfiguration? {
        let configurations = values.filter { $0.classID == AccessConfiguration.classID }
        guard configurations.count <= 1 else {
            throw TractandaError(
                "invalidAccessConfiguration", "Only one access configuration item is permitted.")
        }
        return try configurations.first.map { try AccessConfiguration($0.fields["accessConfiguration"]!) }
    }

    /// Personal decisions belong to their own immutable meta-item, not the shared target.
    public func categoryOverride(for item: Revision, categoryID: String) throws -> (
        decision: String, origin: String
    )? {
        try categoryOverrideIndex(categoryIDs: [categoryID]).decision(for: item, categoryID: categoryID)
    }

    /// Capture applicable aliases for this request. Overlay records are hydrated lazily,
    /// after current ACL checks, for each target whose category decision is evaluated.
    func categoryOverrideIndex(categoryIDs: Set<String>) throws -> CategoryOverrideIndex {
        beforeCategoryOverlayScan?()
        let uid = accessContext?.uid ?? ownerUID
        let resolver =
            accessContext?.resolver
            ?? PrincipalResolver(directory: accounts, configuration: accessConfiguration)
        let limit = personalOverlayWorkingSetLimitForTesting ?? Self.personalOverlayWorkingSetLimit
        let applicableOwners = try applicablePersonalOwnerNames(
            resolver: resolver, limit: limit)
        _ = categoryIDs  // Target lookup validates every category in each overlay.
        return CategoryOverrideIndex(
            store: self, ownerNames: applicableOwners, uid: uid, resolver: resolver,
            targetLimit: personalOverlayTargetCacheLimitForTesting ?? 64,
            byteLimit: Self.personalOverlayWorkingSetByteLimit, overlayLimit: limit)
    }

    fileprivate func readablePersonalOverlay(
        targetID: String, ownerNames: Set<String>, resolver: PrincipalResolver, uid: UInt32,
        overlayLimit: Int, byteLimit: Int
    ) throws -> (overlay: Revision?, bytes: Int) {
        var overlay: Revision?
        var bytes = 0
        var scanned = 0
        try index?.forEachPersonalOverlayID(targetID: targetID, ownerNames: ownerNames) { overlayID in
            scanned += 1
            guard scanned <= overlayLimit else {
                throw TractandaError(
                    "resourceLimit", "Personal overlays for one target exceed the target limit.")
            }
            guard let head = try currentHead(overlayID), head.classID == "PersonalStateItem",
                !head.isDeleted, canRead(head)
            else { return }
            let size = try canonicalSize(for: head)
            guard size <= byteLimit - bytes else {
                throw TractandaError(
                    "resourceLimit", "Personal overlays for one target exceed the byte budget.")
            }
            bytes += size
            guard let record = try currentRevision(head.itemID), canRead(record),
                let owner = record.fields["permissions"]?.map?["owner"]?.string,
                (try? resolver.userID(owner)) == uid,
                record.fields["target"]?.link?.itemID == targetID
            else { return }
            guard overlay == nil else {
                throw TractandaError(
                    "invalidPersonalState", "Several personal overlays target the same item.")
            }
            overlay = record
        }
        return (overlay, bytes)
    }

    private func applicablePersonalOwnerNames(
        resolver: PrincipalResolver, limit: Int
    ) throws -> Set<String> {
        var names = Set<String>()
        try index?.forEachPersonalOwnerName { name in
            guard !name.isEmpty, let uid = try? resolver.userID(name), uid == (accessContext?.uid ?? ownerUID)
            else {
                return
            }
            names.insert(name)
            guard names.count <= limit else {
                throw TractandaError(
                    "resourceLimit", "Personal owner aliases exceed the bounded working set.")
            }
        }
        return names
    }

    func categoryPersonalCandidateIDs(categoryIDs: Set<String>) throws -> Set<String> {
        let resolver =
            accessContext?.resolver
            ?? PrincipalResolver(directory: accounts, configuration: accessConfiguration)
        let names = try applicablePersonalOwnerNames(
            resolver: resolver,
            limit: personalOverlayWorkingSetLimitForTesting ?? Self.personalOverlayWorkingSetLimit)
        var targets = Set<String>()
        try index?.forEachPersonalDeltaTarget(categoryIDs: categoryIDs, ownerNames: names) { target in
            targets.insert(target)
            guard
                targets.count
                    <= (personalOverlayWorkingSetLimitForTesting ?? Self.personalOverlayWorkingSetLimit)
            else {
                throw TractandaError(
                    "resourceLimit", "Personal overlay targets exceed the bounded working set.")
            }
        }
        return targets
    }

    // Convenience operations may skip current-state checks on a retry. commit still
    // verifies the complete immutable intent and the caller's authority before replaying it.
    func hasCommittedOperation(_ id: String, actorUID: UInt32) -> Bool {
        (try? priorOperation(id, uid: actorUID)) != nil
    }

    /// Restore runtime history metadata from a clean, integrity-checked disposable catalogue.
    /// Any uncertainty returns false so the caller performs complete canonical recovery.
    private func loadFromCheckpoint() throws -> Bool {
        let database = indexDirectory.appendingPathComponent("items.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return false }
        let candidate: ItemIndex
        do { candidate = try ItemIndex(path: database.path, create: false) } catch { return false }
        guard let identity = try? canonicalStoreIdentity(creatingIfMissing: false),
            (try? candidate.validatedCatalogue(identity: identity)) != nil
        else {
            candidate.close()
            return false
        }
        checkpointHeadRowsLoadedForTesting = 0
        checkpointCatalogueRowsLoadedForTesting = 0
        checkpointCanonicalHeadReadsForTesting = 0
        do {
            index = candidate
            heads.removeAll(keepingCapacity: false)
            headCacheOrder.removeAll(keepingCapacity: false)
            headCacheBytes = 0
            guard try candidate.currentHeadCount(classID: AccessConfiguration.classID) <= 1 else {
                candidate.close()
                index = nil
                return false
            }
            if let configurationHead = try candidate.currentHeadSummary(classID: AccessConfiguration.classID)
            {
                guard (try? Identifier.validate(configurationHead.itemID)) != nil,
                    (try? Identifier.validate(configurationHead.revisionID)) != nil,
                    let value = configurationHead.fields["accessConfiguration"]
                else {
                    candidate.close()
                    index = nil
                    return false
                }
                checkpointCanonicalHeadReadsForTesting += 1
                guard let canonicalConfiguration = try loadRevision(configurationHead.revisionID),
                    canonicalConfiguration.itemID == configurationHead.itemID,
                    canonicalConfiguration.revisionID == configurationHead.revisionID,
                    canonicalConfiguration.classID == AccessConfiguration.classID,
                    !canonicalConfiguration.isDeleted,
                    canonicalConfiguration.fields["accessConfiguration"] == value
                else {
                    candidate.close()
                    index = nil
                    return false
                }
                accessConfiguration = try AccessConfiguration(
                    canonicalConfiguration.fields["accessConfiguration"]!)
                try accessConfiguration?.validate(
                    using: PrincipalResolver(
                        directory: accounts, configuration: accessConfiguration))
            } else {
                accessConfiguration = nil
            }
            clockDependentCategories = try candidate.hasClockDependentCategories()
            isCanonicalReady = true
            installIndexFailureHandler(candidate)
            clearSavedViewPages()
            operations.removeAll(keepingCapacity: false)
            operationIDs.removeAll(keepingCapacity: false)
            return true
        } catch {
            candidate.close()
            index = nil
            return false
        }
    }

    private static func validCanonicalRecordPath(_ path: String, itemID: String, revisionID: String) -> Bool {
        let components = path.split(separator: "/")
        guard components.count == 8, components[0] == "items",
            components[1].count == 4, components[2].count == 2, components[3].count == 2,
            components[4].count == 2, components[5].count == 2,
            components[1...5].allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
            String(components[6]) == itemID, String(components[7]) == revisionID + ".tractanda"
        else { return false }
        return true
    }

    /// Snapshot the compact immutable-file inventory for a bounded background verifier.
    func exportCatalogueForVerification() throws -> [ItemIndex.CatalogueRow] {
        guard let index,
            let identity = try? canonicalStoreIdentity(creatingIfMissing: false),
            let rows = try index.catalogue(identity: identity)
        else { throw TractandaError("indexUnavailable", "A validated checkpoint is unavailable.") }
        return rows
    }

    func verificationSnapshot() throws -> CanonicalVerifier.Snapshot {
        guard isCanonicalReady else {
            throw TractandaError("recoveryRequired", "Resolve canonical recovery errors before verification.")
        }
        guard let index else {
            throw TractandaError("indexUnavailable", "Validated catalogue is unavailable.")
        }
        let identity = try canonicalStoreIdentity(creatingIfMissing: false)
        guard try index.validatedCatalogue(identity: identity) != nil
        else { throw TractandaError("indexUnavailable", "Catalogue identity or integrity check failed.") }
        return CanonicalVerifier.Snapshot(
            rootPath: root.path, ownerUID: ownerUID,
            indexPath: indexDirectory.appendingPathComponent("items.sqlite").path,
            storeIdentity: identity, generation: generation,
            catalogueWatermark: try index.catalogueWatermark())
    }

    func beginVerificationScan(generation: String) throws {
        guard isCanonicalReady else {
            throw TractandaError("recoveryRequired", "Resolve canonical recovery errors before verification.")
        }
        verificationAccumulation = VerificationAccumulation(generation: generation)
        canonicalVerificationStatus = ["state": "scanning", "generation": generation]
    }

    func finishVerificationScan(_ result: CanonicalVerifier.Result, scannedGeneration: String) {
        guard let progress = verificationAccumulation, progress.generation == scannedGeneration else {
            return
        }
        verificationAccumulation = nil
        if canonicalVerificationStatus["state"] as? String == "inconsistent" || !isCanonicalReady { return }
        let completed = ISO8601DateFormatter().string(from: Date())
        guard result.status == .complete else {
            canonicalVerificationStatus = [
                "state": result.status.rawValue, "completedAt": completed,
                "message": result.detail ?? "Canonical inventory scan did not complete.",
                "observedFindingCount": progress.observedFindings,
            ]
            return
        }
        canonicalVerificationStatus = [
            "state": "clean", "completedAt": completed,
            "snapshotWasStale": scannedGeneration != generation,
            "metadataIndicatorCount": progress.metadataIndicators,
            "catalogueRowCount": result.exactCatalogueCount ?? 0,
            "scope":
                "Hashes records only when catalogue filesystem metadata changed; unchanged metadata is not byte proof.",
        ]
    }

    /// Reconcile an asynchronous scan on the store queue. A stale scan finding is ignored only
    /// after the current catalogue and current bytes establish that the path is now consistent.
    func applyVerification(_ findings: [CanonicalVerifier.Finding], scannedGeneration: String) throws {
        guard isCanonicalReady else {
            throw TractandaError("recoveryRequired", "Resolve canonical recovery errors before verification.")
        }
        // Canonical record names carry their immutable revision ID. Resolve only findings;
        // a clean background scan no longer copies the entire catalogue on this queue.
        func currentRow(for path: String) -> ItemIndex.CatalogueRow? {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            guard filename.hasSuffix(".tractanda") else { return nil }
            let revisionID = String(filename.dropLast(".tractanda".count))
            guard let index, let row = try? index.revision(revisionID) else { return nil }
            return row.path == path ? row : nil
        }
        var confirmed: [CanonicalVerifier.Finding] = []
        var metadataIndicators = 0
        for finding in findings {
            if let row = currentRow(for: finding.path) {
                let url = root.appendingPathComponent(row.path)
                if finding.kind == .missing {
                    if let metadata = try? FileMetadata.read(at: url), metadata.type == .regular,
                        metadata.size <= 8 * 1024 * 1024,
                        tractanda_path_read_only(url.path) == 1
                            || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0),
                        metadata.size == row.size, metadata.inode == row.inode,
                        metadata.uid == row.uid, metadata.mode == row.mode,
                        metadata.modificationSeconds == row.modificationSeconds,
                        metadata.modificationNanoseconds == row.modificationNanoseconds,
                        let bytes = try? Data(contentsOf: url), Data(SHA256.hash(data: bytes)) == row.digest
                    {
                        continue
                    }
                    let exists = (try? FileMetadata.read(at: url)) != nil
                    confirmed.append(
                        exists
                            ? .init(
                                kind: .changed, path: finding.path, revisionID: row.revisionID,
                                detail: "Current path contains a replacement that differs from the catalogue")
                            : finding)
                    continue
                }
                guard let metadata = try? FileMetadata.read(at: url), metadata.type == .regular else {
                    confirmed.append(finding)
                    continue
                }
                let safe =
                    tractanda_path_read_only(url.path) == 1
                    || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0)
                guard safe, metadata.size <= 8 * 1024 * 1024,
                    let bytes = try? Data(contentsOf: url),
                    Data(SHA256.hash(data: bytes)) == row.digest
                else {
                    confirmed.append(
                        finding.kind == .metadataChanged
                            ? .init(
                                kind: .changed, path: finding.path, revisionID: row.revisionID,
                                detail: "Current canonical bytes differ from the catalogue digest")
                            : finding)
                    continue
                }
                let metadataMatches =
                    metadata.size == row.size && metadata.inode == row.inode
                    && metadata.uid == row.uid && metadata.mode == row.mode
                    && metadata.modificationSeconds == row.modificationSeconds
                    && metadata.modificationNanoseconds == row.modificationNanoseconds
                if metadataMatches { continue }
                if finding.kind == .metadataChanged || finding.kind == .changed {
                    metadataIndicators += 1
                    continue
                }
                if finding.kind == .unsafe {
                    metadataIndicators += 1
                    continue
                }
            } else if finding.kind == .missing {
                continue
            } else if finding.kind == .unexpected,
                !FileManager.default.fileExists(atPath: root.appendingPathComponent(finding.path).path)
            {
                continue
            }
            confirmed.append(finding)
        }
        if var progress = verificationAccumulation, progress.generation == scannedGeneration {
            progress.observedFindings += findings.count
            progress.confirmedFindings += confirmed.count
            progress.metadataIndicators += metadataIndicators
            for finding in confirmed where progress.details.count < verificationDetailLimit {
                progress.details.append([
                    "kind": finding.kind.rawValue, "path": finding.path, "detail": finding.detail,
                ])
            }
            verificationAccumulation = progress
            if confirmed.isEmpty { return }
        }
        let completed = ISO8601DateFormatter().string(from: Date())
        if confirmed.isEmpty {
            canonicalVerificationStatus = [
                "state": "clean", "completedAt": completed,
                "snapshotWasStale": scannedGeneration != generation,
                "metadataIndicatorCount": metadataIndicators,
                "scope":
                    "Hashes records only when catalogue filesystem metadata changed; unchanged metadata is not byte proof.",
            ]
        } else {
            canonicalVerificationStatus = [
                "state": "inconsistent", "completedAt": completed,
                "snapshotWasStale": scannedGeneration != generation,
                "findingCount": verificationAccumulation?.confirmedFindings ?? confirmed.count,
                "findings": verificationAccumulation?.details
                    ?? confirmed.prefix(verificationDetailLimit).map {
                        ["kind": $0.kind.rawValue, "path": $0.path, "detail": $0.detail]
                    },
            ]
            isCanonicalReady = false
            do {
                try StoreCheckpoint.markDirty(root: root)
            } catch let markerFailure {
                canonicalVerificationStatus["state"] = "fatalRecoverySignalFailure"
                canonicalVerificationStatus["markerError"] = String(describing: markerFailure)
                canonicalVerificationStatus["restartMayReuseCheckpoint"] = true
            }
            if let index {
                do {
                    try index.closeChecked()
                    self.index = nil
                } catch {
                    // Keep the owner handle reachable until statements unwind. Separate
                    // verifier/reader leases are drained before any later rebuild or swap.
                    canonicalVerificationStatus["indexCloseError"] = String(describing: error)
                }
            }
        }
    }

    func noteVerificationFailure(_ message: String) {
        if canonicalVerificationStatus["state"] as? String == "inconsistent" {
            canonicalVerificationStatus["markerError"] = message
            return
        }
        canonicalVerificationStatus = [
            "state": "failed", "completedAt": ISO8601DateFormatter().string(from: Date()),
            "message": message,
        ]
    }

    private func recover(
        staging: ItemIndex, statements: ItemIndex.RebuildStatements, measurePhases: Bool = false
    ) throws -> RecoveryPhaseMetrics? {
        let enumerationStart = ProcessInfo.processInfo.systemUptime
        var recordReadSeconds: TimeInterval = 0
        var recordDecodeSeconds: TimeInterval = 0
        var recordHashSeconds: TimeInterval = 0
        var semanticValidationSeconds: TimeInterval = 0
        func scan(_ directory: URL, depth: Int) throws {
            guard depth <= 16 else {
                throw TractandaError("recoveryError", "Canonical directory depth exceeded.")
            }
            try POSIXDirectory.withEntries(at: directory) { name in
                let url = directory.appendingPathComponent(name, isDirectory: false)
                let metadata = try FileMetadata.read(at: url)
                let archiveState = tractanda_path_read_only(url.path)
                guard archiveState >= 0 else {
                    throw TractandaError(
                        "recoveryError", "Cannot inspect canonical filesystem state: \(url.path)")
                }
                let archived = archiveState == 1
                if metadata.type == .directory {
                    guard archived || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0) else {
                        throw TractandaError(
                            "recoveryError", "Unexpected directory ownership or permissions: \(url.path)")
                    }
                    if !archived { try ensureDirectory(url) }
                    try scan(url, depth: depth + 1)
                    return true
                }
                guard metadata.type == .regular,
                    archived || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0)
                else {
                    throw TractandaError(
                        "recoveryError", "Unexpected file ownership or permissions: \(url.path)")
                }
                if url.pathExtension != "tractanda" {
                    let parts = url.lastPathComponent.components(separatedBy: ".tractanda.")
                    if parts.count == 2, UUID(uuidString: parts[0]) != nil,
                        parts[1].count == 6,
                        parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
                    {
                        if recoveryWarnings.count < 100 {
                            recoveryWarnings.append(
                                "Unpublished staging file retained: \(url.lastPathComponent)")
                        }
                        return true
                    }
                    throw TractandaError(
                        "recoveryError", "Unrecognized file in canonical item tree: \(url.path)")
                }
                guard metadata.size <= 8 * 1024 * 1024 else {
                    throw TractandaError("recoveryError", "Record exceeds the prototype size limit.")
                }
                let start = ProcessInfo.processInfo.systemUptime
                let bytes = try Data(contentsOf: url)
                recordReadSeconds += ProcessInfo.processInfo.systemUptime - start
                let decodeStart = ProcessInfo.processInfo.systemUptime
                let revision = try RecordCodec.decode(bytes)
                recordDecodeSeconds += ProcessInfo.processInfo.systemUptime - decodeStart
                let hashStart = ProcessInfo.processInfo.systemUptime
                let digest = Data(SHA256.hash(data: bytes))
                recordHashSeconds += ProcessInfo.processInfo.systemUptime - hashStart
                let semanticsStart = ProcessInfo.processInfo.systemUptime
                try ItemSemantics.validate(revision)
                try Identifier.validate(revision.itemID)
                try Identifier.validate(revision.revisionID)
                semanticValidationSeconds += ProcessInfo.processInfo.systemUptime - semanticsStart
                guard url.deletingPathExtension().lastPathComponent == revision.revisionID,
                    Self.validCanonicalRecordPath(
                        String(url.path.dropFirst(root.path.count + 1)),
                        itemID: revision.itemID, revisionID: revision.revisionID),
                    let actor = revision.fields["actor"]?.string,
                    let operation = revision.fields["operationID"]?.string,
                    let createdAt = revision.fields["createdAt"]?.dateString,
                    !actor.isEmpty, !operation.isEmpty
                else {
                    throw TractandaError(
                        "recoveryError", "Canonical filename or record identity mismatch: \(url.path)")
                }
                var feedbackIDs: [String] = []
                if let feedback = revision.fields["learningFeedback"]?.map {
                    for value in feedback.values {
                        feedbackIDs.append(try LearningFeedback(value).revisionID)
                    }
                }
                let row = ItemIndex.CatalogueRow(
                    revisionID: revision.revisionID, itemID: revision.itemID,
                    path: String(url.path.dropFirst(root.path.count + 1)), parentID: revision.supersedes,
                    actor: actor, operationID: operation, size: metadata.size, inode: metadata.inode,
                    uid: metadata.uid, mode: metadata.mode, modificationSeconds: metadata.modificationSeconds,
                    modificationNanoseconds: metadata.modificationNanoseconds, digest: digest,
                    createdAt: createdAt, feedbackRevisionIDs: feedbackIDs)
                do { try staging.insertRecoveryRow(row) } catch {
                    throw TractandaError(
                        "recoveryError", "Duplicate canonical revision, path or receipt: \(error)")
                }
                try afterRecoveryRecordForTesting?(url)
                return true
            }
        }
        do { try scan(root.appendingPathComponent("items"), depth: 0) } catch {
            throw TractandaError("recoveryError", "Cannot enumerate or validate canonical records: \(error)")
        }
        let enumerationEnd = ProcessInfo.processInfo.systemUptime
        do { try staging.validateRecoveryGraph() } catch {
            throw TractandaError("recoveryError", "Canonical revision graph is invalid: \(error)")
        }
        let chainEnd = ProcessInfo.processInfo.systemUptime
        heads.removeAll(keepingCapacity: false)
        headCacheOrder.removeAll(keepingCapacity: false)
        headCacheBytes = 0
        var categoryHeads: [Revision] = []
        var categoryBytes = 0
        var recoveredConfiguration: AccessConfiguration?
        var clockDependent = false
        var cursor: String?
        while let head = try staging.recoveryHead(after: cursor) {
            guard let row = try staging.revision(itemID: head.itemID, revisionID: head.revisionID) else {
                throw TractandaError("recoveryError", "Current revision catalogue row is missing.")
            }
            let url = root.appendingPathComponent(row.path)
            let metadata = try FileMetadata.read(at: url)
            let archiveState = tractanda_path_read_only(url.path)
            guard archiveState >= 0 else {
                throw TractandaError("recoveryError", "Cannot inspect current revision filesystem state.")
            }
            let archived = archiveState == 1
            guard metadata.type == .regular, metadata.size == row.size, metadata.uid == row.uid,
                metadata.mode == row.mode, metadata.inode == row.inode,
                archived || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0)
            else {
                throw TractandaError("recoveryError", "Current revision permissions changed during recovery.")
            }
            let bytes = try Data(contentsOf: url)
            guard Data(SHA256.hash(data: bytes)) == row.digest else {
                throw TractandaError("recoveryError", "Current revision changed during recovery.")
            }
            let revision = try RecordCodec.decode(bytes)
            try ItemSemantics.validate(revision)
            guard revision.itemID == head.itemID, revision.revisionID == head.revisionID,
                revision.supersedes == row.parentID, revision.fields["createdAt"]?.dateString == row.createdAt
            else {
                throw TractandaError(
                    "recoveryError", "Current revision body or indexed text is inconsistent.")
            }
            try staging.putForRebuild(revision, using: statements)
            guard try staging.textMatches(revision) else {
                throw TractandaError("recoveryError", "Current revision indexing failed during rebuild.")
            }
            try rememberHead(Self.residentHead(revision))
            if revision.fields["selection"] != nil || revision.fields["categoryParents"] != nil {
                guard categoryHeads.count < Self.categoryWorkingSetLimit,
                    Int(row.size) <= Self.categoryWorkingSetByteLimit - categoryBytes
                else {
                    throw TractandaError(
                        "resourceLimit", "Recovered category graph exceeds its bounded working set.")
                }
                categoryBytes += Int(row.size)
                categoryHeads.append(revision)
            }
            if revision.classID == AccessConfiguration.classID {
                guard recoveredConfiguration == nil else {
                    throw TractandaError("recoveryError", "Multiple access configuration heads exist.")
                }
                recoveredConfiguration = try AccessConfiguration(revision.fields["accessConfiguration"]!)
            }
            clockDependent = clockDependent || Self.categoryUsesClock(revision)
            cursor = head.itemID
        }
        historicalCache.removeAll(keepingCapacity: true)
        historicalOrder.removeAll(keepingCapacity: true)
        historicalCacheBytes = 0
        _ = try CategoryHierarchy(categoryHeads)
        clockDependentCategories = clockDependent
        clearSavedViewPages()
        revisionLocations.removeAll(keepingCapacity: false)
        operations.removeAll(keepingCapacity: false)
        operationIDs.removeAll(keepingCapacity: false)
        accessConfiguration = recoveredConfiguration
        let finalizationEnd = ProcessInfo.processInfo.systemUptime
        guard measurePhases else { return nil }
        return RecoveryPhaseMetrics(
            enumerationStart: enumerationStart, enumerationEnd: enumerationEnd,
            chainStart: enumerationEnd, chainEnd: chainEnd,
            finalizationStart: chainEnd, finalizationEnd: finalizationEnd,
            recordReadDecodeSeconds: recordReadSeconds + recordDecodeSeconds,
            recordReadSeconds: recordReadSeconds, recordDecodeSeconds: recordDecodeSeconds,
            recordHashSeconds: recordHashSeconds, semanticValidationSeconds: semanticValidationSeconds)
    }
    private static func categoryUsesClock(_ item: Revision) -> Bool {
        categoryUsesClock(item.fields, isDeleted: item.isDeleted)
    }
    private static func categoryUsesClock(_ fields: [String: ItemValue], isDeleted: Bool) -> Bool {
        guard !isDeleted, let selection = fields["selection"]?.map else { return false }
        return selection["timeWindow"] != nil
            || selection["expression"]?.string?.contains("$time.") == true
    }
    private func loadRevision(_ revisionID: String) throws -> Revision? {
        do { return try loadRevisionUnchecked(revisionID) } catch {
            let code = (error as? TractandaError)?.code
            if code != "indexTransient" && code != "indexResource", isCanonicalReady {
                quarantineCheckpoint()
            }
            throw error
        }
    }

    private func loadRevisionUnchecked(_ revisionID: String) throws -> Revision? {
        let location: RevisionLocation
        if let index {
            guard let row = try index.revision(revisionID) else {
                throw TractandaError("recoveryError", "Indexed canonical revision is missing: \(revisionID)")
            }
            location = RevisionLocation(row)
        } else if indexRebuildInProgress, let recovered = revisionLocations[revisionID] {
            location = recovered
        } else {
            throw TractandaError("indexUnavailable", "Historical catalogue lookup is unavailable.")
        }
        let url = location.url(root: root)
        if let cached = historicalCache[revisionID] {
            historicalOrder.removeAll { $0 == revisionID }
            historicalOrder.append(revisionID)
            return cached.revision
        }
        let metadata = try FileMetadata.read(at: url)
        let isArchived = tractanda_path_read_only(url.path) == 1
        guard metadata.type == .regular, metadata.size <= 8 * 1024 * 1024,
            metadata.size == location.metadata.size,
            metadata.inode == location.metadata.inode, metadata.uid == location.metadata.uid,
            metadata.mode == location.metadata.mode,
            metadata.modificationSeconds == location.metadata.modificationSeconds,
            metadata.modificationNanoseconds == location.metadata.modificationNanoseconds,
            isArchived || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0)
        else { throw TractandaError("recoveryError", "Historical record changed: \(url.path)") }
        let data = try Data(contentsOf: url)
        let revision = try RecordCodec.decode(data)
        try ItemSemantics.validate(revision)
        guard Data(SHA256.hash(data: data)) == location.digest,
            url.deletingPathExtension().lastPathComponent == revisionID,
            revision.revisionID == revisionID, revision.itemID == location.itemID,
            revision.supersedes == location.parentID,
            revision.fields["actor"]?.string == location.actor,
            revision.fields["operationID"]?.string == location.operationID
        else {
            throw TractandaError("recoveryError", "Historical record identity changed: \(url.path)")
        }
        if let head = try currentHead(revision.itemID), head.revisionID == revisionID, let full = head.full {
            return full
        }
        if data.count <= Self.historicalCacheLimit {
            while historicalCacheBytes + data.count > Self.historicalCacheLimit,
                let oldest = historicalOrder.first
            {
                historicalOrder.removeFirst()
                historicalCacheBytes -= historicalCache.removeValue(forKey: oldest)?.bytes ?? 0
            }
            historicalCache[revisionID] = (revision, data.count)
            historicalOrder.append(revisionID)
            historicalCacheBytes += data.count
        }
        return revision
    }
    var savedViewRulesUseClock: Bool { clockDependentCategories }
    private func clearSavedViewPages() {
        savedViewPages.removeAll(keepingCapacity: true)
        savedViewPageDependencies.removeAll(keepingCapacity: true)
        savedViewPageOrder.removeAll(keepingCapacity: true)
        savedViewPageIDs = 0
    }
    func cachedSavedViewPage(key: String, position: Int, limit: Int) throws -> ItemIndex.Page? {
        guard let ids = savedViewPages[key] else { return nil }
        let page = Array(ids.dropFirst(position).prefix(limit))
        // Current authority is checked even for a matching snapshot. Any discrepancy discards
        // the cache, including its count, and triggers the exact query path.
        for id in page {
            if (try? get(id)) == nil {
                clearSavedViewPages()
                return nil
            }
        }
        return .init(ids: page, total: ids.count)
    }
    func saveViewPageIDs(_ ids: [String], key: String, dependencies: Set<String> = []) {
        guard ids.count <= 8_192 else { return }
        if let previous = savedViewPages[key] {
            savedViewPageIDs -= previous.count
            savedViewPageOrder.removeAll { $0 == key }
            savedViewPageDependencies.removeValue(forKey: key)
        }
        while savedViewPageOrder.count >= 16 || savedViewPageIDs + ids.count > 65_536 {
            guard let oldest = savedViewPageOrder.first else { break }
            savedViewPageOrder.removeFirst()
            savedViewPageIDs -= savedViewPages.removeValue(forKey: oldest)?.count ?? 0
            savedViewPageDependencies.removeValue(forKey: oldest)
        }
        savedViewPages[key] = ids
        savedViewPageDependencies[key] = dependencies
        savedViewPageOrder.append(key)
        savedViewPageIDs += ids.count
    }
    func savedViewPageKey(
        _ viewID: String, selectionKey: String, timeKey: String, reusableAcrossCommits: Bool = false
    ) -> String {
        // Reusable entries still bind to the current caller and group snapshot. Their item
        // dependencies are invalidated at commit; all other queries retain generation scoping.
        let mayReuseAcrossCommits = reusableAcrossCommits && (!isMultiUser || isAdministrator)
        return viewID + "\0" + selectionKey + "\0" + accessScope + "\0"
            + savedViewAuthorizationKey + "\0"
            + (mayReuseAcrossCommits ? "stable" : state) + "\0" + timeKey
    }

    private func invalidateSavedViewPages(
        changedFields: Set<String>, itemID: String, base: Revision?, revision: Revision, broad: Bool
    ) {
        guard !savedViewPages.isEmpty else { return }
        if broad {
            clearSavedViewPages()
            return
        }
        let hasCorpusDependency = savedViewPageDependencies.values.contains {
            $0.contains("text:corpus")
        }
        let corpusChanged =
            hasCorpusDependency
            && base.map { ItemTextContent.corpus(for: $0) != ItemTextContent.corpus(for: revision) } == true
        let invalid = savedViewPageDependencies.compactMap { key, dependencies in
            let isCachedMember = savedViewPages[key]?.contains(itemID) == true
            let changed = dependencies.contains { dependency in
                if dependency == "text:corpus" { return corpusChanged }
                if dependency.hasPrefix("filter:") {
                    return changedFields.contains(String(dependency.dropFirst("filter:".count)))
                }
                if dependency.hasPrefix("sort:") {
                    return isCachedMember
                        && changedFields.contains(String(dependency.dropFirst("sort:".count)))
                }
                if dependency.hasPrefix("field:") {
                    return changedFields.contains(dependency)
                }
                return false
            }
            return changed ? key : nil
        }
        for key in invalid {
            savedViewPages.removeValue(forKey: key)
            savedViewPageDependencies.removeValue(forKey: key)
            savedViewPageOrder.removeAll { $0 == key }
        }
        savedViewPageIDs = savedViewPages.values.reduce(0) { $0 + $1.count }
    }

    public func get(_ itemID: String, revisionID: String? = nil) throws -> Revision {
        guard isCanonicalReady else {
            throw TractandaError(
                "recoveryRequired", "Resolve canonical recovery errors before reading or writing.")
        }
        try Identifier.validate(itemID)
        guard let head = try currentHead(itemID) else {
            throw TractandaError("notFound", "Item or revision is unavailable.")
        }
        guard canRead(head) else { throw TractandaError("forbidden", "Item access is denied.") }
        let revision: Revision?
        if let revisionID {
            guard let index, try index.revision(itemID: itemID, revisionID: revisionID) != nil else {
                throw TractandaError("notFound", "Item or revision is unavailable.")
            }
            revision = try loadRevision(revisionID)
        } else {
            revision = try currentRevision(itemID)
        }
        guard let revision, revision.itemID == itemID else {
            throw TractandaError("notFound", "Item or revision is unavailable.")
        }
        return revision
    }
    func ftsTextRow(for itemID: String) throws -> ItemIndex.TextRow? {
        _ = try get(itemID)
        guard let index else { throw TractandaError("indexUnavailable", "The text index is unavailable.") }
        return try index.textRow(id: itemID)
    }
    public func history(_ itemID: String) throws -> [Revision] {
        var current = try get(itemID)
        var result = [current]
        var seen: Set<String> = [current.revisionID]
        while let previous = current.supersedes {
            guard let index, try index.revision(itemID: itemID, revisionID: previous) != nil,
                seen.insert(previous).inserted
            else {
                throw TractandaError("recoveryError", "Historical chain is incomplete or cyclic.")
            }
            guard let prior = try loadRevision(previous), prior.itemID == itemID else {
                throw TractandaError("recoveryError", "Historical chain is incomplete.")
            }
            current = prior
            result.append(current)
        }
        return result
    }
    func historyPageBounded(_ itemID: String, position: Int, limit: Int) throws
        -> (list: [Revision], total: Int)
    {
        guard position >= 0, (1...256).contains(limit) else {
            throw TractandaError("invalidArguments", "Invalid history page.")
        }
        let headID = try preparePooledHistory(itemID)
        guard let index else { throw TractandaError("indexUnavailable", "History catalogue is unavailable.") }
        func parent(of revisionID: String?) throws -> String? {
            guard let revisionID else { return nil }
            guard let row = try index.revision(itemID: itemID, revisionID: revisionID) else {
                throw TractandaError("recoveryError", "Historical parent is unavailable.")
            }
            return row.parentID
        }
        var current: String? = headID
        var slow: String? = headID
        var fast: String? = headID
        var list: [Revision] = []
        var retainedBytes = 0
        var total = 0
        while let revisionID = current {
            if total >= position && list.count < limit {
                guard let row = try index.revision(itemID: itemID, revisionID: revisionID) else {
                    throw TractandaError("recoveryError", "Historical page row is unavailable.")
                }
                guard row.size <= UInt64(pooledRecordByteLimit - retainedBytes) else {
                    throw TractandaError("resourceLimit", "History page exceeds its byte window.")
                }
                guard let revision = try loadRevision(revisionID), revision.itemID == itemID else {
                    throw TractandaError("recoveryError", "Historical page record is unavailable.")
                }
                let size = try JSON.encode(revision).count
                guard size <= pooledRecordByteLimit - retainedBytes else {
                    throw TractandaError("resourceLimit", "History page exceeds its byte window.")
                }
                retainedBytes += size
                list.append(revision)
            }
            guard total < Int.max else { throw TractandaError("resourceLimit", "History count overflowed.") }
            total += 1
            current = try parent(of: revisionID)
            slow = try parent(of: slow)
            fast = try parent(of: try parent(of: fast))
            if let slow, slow == fast {
                throw TractandaError("recoveryError", "Historical chain contains a cycle.")
            }
        }
        guard try index.revisionCount(itemID: itemID) == total else {
            throw TractandaError("recoveryError", "Historical catalogue has disconnected rows.")
        }
        return (list, total)
    }
    public func candidates(text: String? = nil, includeDeleted: Bool = false) throws -> [Revision] {
        try candidates(text: text, includeDeleted: includeDeleted, restrictedTo: nil, candidatePlan: .all)
    }

    /// Captures a strictly bounded set of readable current heads without hydrating any
    /// revision until both limits have been checked against resident metadata. A nil result
    /// means the caller must use the ordinary serial query path.
    func immutableReadSnapshot(
        maximumCandidates: Int = 512, maximumSerializedBytes: Int = 2 * 1024 * 1024,
        candidateRestrictions: [SpotlightQuery.IndexCandidateRestriction] = []
    ) throws -> ImmutableReadSnapshot? {
        precondition(maximumCandidates >= 0 && maximumSerializedBytes >= 0)
        guard isCanonicalReady, isCanonicalTrusted, index != nil else { return nil }
        guard let index else { return nil }
        var ids: [String] = []
        var estimatedBytes = 0
        if !candidateRestrictions.isEmpty {
            guard
                let selected = try index.boundedCandidateIDs(
                    restrictions: candidateRestrictions, maximumReadable: maximumCandidates,
                    accepts: { id in
                        guard let head = try self.currentHead(id) else {
                            throw TractandaError("indexError", "Indexed candidate has no current head.")
                        }
                        return !head.isDeleted && self.canRead(head)
                    })
            else { return nil }
            ids = selected
            for id in ids {
                guard let head = try currentHead(id), !head.isDeleted, canRead(head),
                    let location = try index.revision(head.revisionID),
                    location.size <= UInt64(maximumSerializedBytes - estimatedBytes)
                else { return nil }
                estimatedBytes += Int(location.size)
            }
        } else {
            var withinBudget = true
            try forEachCurrentHead { head in
                guard withinBudget, !head.isDeleted, canRead(head) else { return }
                guard ids.count < maximumCandidates,
                    let location = try index.revision(head.revisionID),
                    location.size <= UInt64(maximumSerializedBytes - estimatedBytes)
                else {
                    withinBudget = false
                    return
                }
                estimatedBytes += Int(location.size)
                ids.append(head.itemID)
            }
            guard withinBudget else { return nil }
        }
        var revisions: [Revision] = []
        revisions.reserveCapacity(ids.count)
        var serializedBytes = 0
        for id in ids {
            guard let revision = try currentRevision(id) else {
                throw TractandaError("recoveryError", "Current head is unavailable during snapshot capture.")
            }
            let bytes = try JSON.encode(revision).count
            guard bytes <= maximumSerializedBytes - serializedBytes else { return nil }
            serializedBytes += bytes
            revisions.append(revision)
        }
        return ImmutableReadSnapshot(
            revisions: revisions, state: state, serializedBytes: serializedBytes)
    }

    /// Rechecks a prepared read under fresh caller authority before its result is delivered.
    /// The bounded input also permits a canonical digest check for every captured candidate.
    func verifyImmutableReadSnapshot(_ snapshot: ImmutableReadSnapshot) throws -> Bool {
        guard isCanonicalReady, state == snapshot.state else { return false }
        for revision in snapshot.revisions {
            guard let head = try currentHead(revision.itemID), head.revisionID == revision.revisionID,
                canRead(head), let index, let row = try index.revision(revision.revisionID)
            else { return false }
            let location = RevisionLocation(row)
            let url = location.url(root: root)
            let metadata: FileMetadata
            let bytes: Data
            do {
                metadata = try FileMetadata.read(at: url)
                bytes = try Data(contentsOf: url)
            } catch {
                throw TractandaError("recoveryError", "Prepared read cannot verify canonical content.")
            }
            let archived = tractanda_path_read_only(url.path) == 1
            guard metadata.type == .regular, metadata.size <= 8 * 1024 * 1024,
                metadata.size == location.metadata.size, metadata.inode == location.metadata.inode,
                metadata.uid == location.metadata.uid, metadata.mode == location.metadata.mode,
                metadata.modificationSeconds == location.metadata.modificationSeconds,
                metadata.modificationNanoseconds == location.metadata.modificationNanoseconds,
                archived || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0),
                Data(SHA256.hash(data: bytes)) == location.digest
            else {
                throw TractandaError("recoveryError", "Prepared read found changed canonical content.")
            }
        }
        return true
    }

    func candidates(text: String?, restrictedTo ids: Set<String>) throws -> [Revision] {
        try candidates(text: text, includeDeleted: false, restrictedTo: ids)
    }
    func candidates(
        text: String?, restrictedTo ids: Set<String>?,
        candidatePlan: SpotlightQuery.IndexCandidatePlan
    ) throws -> [Revision] {
        try candidates(text: text, includeDeleted: false, restrictedTo: ids, candidatePlan: candidatePlan)
    }

    /// Streams readable live revisions one at a time. Optional exact-sort budgets are
    /// charged before a candidate reaches the caller's accumulator.
    func forEachReadableCandidate(
        text: String?, restrictedTo ids: Set<String>? = nil,
        candidatePlan: SpotlightQuery.IndexCandidatePlan = .all,
        order: ItemIndex.IndexedOrder? = nil,
        savedViewID: String? = nil,
        maximumCandidates: Int? = nil, maximumSerializedBytes: Int? = nil,
        _ body: (Revision) throws -> Void
    ) throws {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        var count = 0
        var bytes = 0
        lastIndexCandidateCountForTesting = 0
        lastSavedViewBaseAppliedForTesting = candidatePlan.containsSavedViewBase
        try index.forEachCandidateID(
            lexicalText: text, restrictingTo: ids, candidatePlan: candidatePlan, order: order,
            savedViewID: savedViewID
        ) { id in
            lastIndexCandidateCountForTesting += 1
            guard let head = try currentHead(id), !head.isDeleted, canRead(head) else { return }
            count += 1
            if let maximumCandidates, count > maximumCandidates {
                throw TractandaError(
                    "resourceLimit", "Exact query candidates exceed the bounded working set.")
            }
            guard let revision = try currentRevision(id) else {
                throw TractandaError("recoveryError", "Current query candidate is unavailable.")
            }
            if let maximumSerializedBytes {
                let size = try JSON.encode(revision).count
                guard size <= maximumSerializedBytes - bytes else {
                    throw TractandaError(
                        "resourceLimit", "Exact query candidates exceed the bounded byte budget.")
                }
                bytes += size
            }
            try body(revision)
        }
    }
    private func candidates(
        text: String?, includeDeleted: Bool, restrictedTo ids: Set<String>?,
        candidatePlan: SpotlightQuery.IndexCandidatePlan = .all
    ) throws
        -> [Revision]
    {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        var visible: [Revision] = []
        var bytes = 0
        var count = 0
        try index.forEachCandidateID(
            lexicalText: text, restrictingTo: ids, candidatePlan: candidatePlan,
            includeDeleted: includeDeleted
        ) { id in
            guard let head = try currentHead(id), includeDeleted || !head.isDeleted, canRead(head) else {
                return
            }
            count += 1
            guard count <= (exactQueryCandidateLimitForTesting ?? Self.exactQueryCandidateLimit),
                let revision = try currentRevision(id)
            else {
                throw TractandaError(
                    "resourceLimit", "Exact query candidates exceed the bounded working set.")
            }
            let size = try JSON.encode(revision).count
            guard size <= Self.exactQueryByteLimit - bytes else {
                throw TractandaError(
                    "resourceLimit", "Exact query candidates exceed the bounded byte budget.")
            }
            bytes += size
            visible.append(revision)
        }
        // Global FTS rank depends on hidden documents. Shared clients get stable ID ordering.
        return isMultiUser && !isAdministrator ? visible.sorted { $0.itemID < $1.itemID } : visible
    }
    func readableCategoryHeads(requestedCategoryIDs: Set<String>? = nil) throws -> [Revision] {
        var summaries: [String: ResidentHead] = [:]
        var summaryBytes = 0
        guard let index else {
            throw TractandaError("indexUnavailable", "The category index is unavailable.")
        }
        var requested: Set<String>
        if let requestedCategoryIDs {
            requested = try index.relatedCategoryIDs(startingAt: requestedCategoryIDs)
        } else {
            requested = []
            var cursor: String?
            while let id = try index.currentCategoryHeadID(after: cursor) {
                cursor = id
                requested.insert(id)
            }
        }
        for id in requested {
            guard let head = try currentHead(id), !head.isDeleted, head.fields["selection"] != nil,
                canRead(head)
            else { continue }
            guard summaries.count < Self.categoryWorkingSetLimit else {
                throw TractandaError("resourceLimit", "Category graph exceeds the bounded working set.")
            }
            let bytes = try residentByteCount(head)
            guard bytes <= Self.categoryWorkingSetByteLimit - summaryBytes else {
                throw TractandaError("resourceLimit", "Category summaries exceed the bounded byte budget.")
            }
            summaryBytes += bytes
            summaries[head.itemID] = head
        }
        var children: [String: [String]] = [:]
        var exclusions: [String: [String]] = [:]
        for head in summaries.values {
            let rawParents = head.fields["categoryParents"]?.array ?? []
            guard rawParents.count <= 32 else {
                throw TractandaError("invalidCategory", "categoryParents must contain at most 32 references.")
            }
            for value in rawParents {
                guard let link = value.link, link.revisionID == nil, link.itemID != head.itemID else {
                    throw TractandaError(
                        "invalidCategory", "Category parents must be distinct current item references.")
                }
                children[link.itemID, default: []].append(head.itemID)
            }
            let excluded = try CategoryHierarchy.excludedCategories(
                head.fields["selection"]?.map?["excludedCategoryIDs"])
            exclusions[head.itemID] = excluded
        }
        let selected = requested.compactMap { summaries[$0] }
        var revisions: [Revision] = []
        var bytesRetained = 0
        for head in selected {
            let bytes = try canonicalSize(for: head)
            guard bytes <= Self.categoryWorkingSetByteLimit - bytesRetained else {
                throw TractandaError("resourceLimit", "Category definitions exceed the bounded byte budget.")
            }
            bytesRetained += bytes
            guard let revision = try currentRevision(head.itemID), canRead(revision) else {
                throw TractandaError("forbidden", "Category access changed during evaluation.")
            }
            revisions.append(revision)
        }
        return revisions
    }

    func readableCategoryDefinitions(requestedCategoryIDs: Set<String>) throws -> [CategoryDefinition] {
        guard let index else {
            throw TractandaError("indexUnavailable", "The category index is unavailable.")
        }
        let ids = try index.relatedCategoryIDs(
            startingAt: requestedCategoryIDs,
            limit: categoryGraphClosureLimitForTesting ?? Self.categoryWorkingSetLimit)
        var definitions: [CategoryDefinition] = []
        var bytes = 0
        for id in ids {
            guard let head = try currentHead(id), !head.isDeleted,
                head.fields["selection"] != nil, canRead(head)
            else { continue }
            let projectionFields = head.fields.filter {
                ["selection", "categoryParents", "categoryOrder", "subject"].contains($0.key)
            }
            let projectionSize =
                try JSON.encode(projectionFields).count + id.utf8.count + head.revisionID.utf8.count
            guard definitions.count < Self.categoryWorkingSetLimit,
                projectionSize <= Self.categoryWorkingSetByteLimit - bytes
            else {
                throw TractandaError(
                    "resourceLimit", "Category definitions exceed the bounded relevant projection.")
            }
            bytes += projectionSize
            // Current ACL was checked from this exact disposable head summary. The definition
            // retains only typed category fields, never a partial or body-bearing Revision.
            definitions.append(
                CategoryDefinition(
                    itemID: id, revisionID: head.revisionID, fields: projectionFields))
        }
        return definitions
    }

    func categoryGraphIsFullyReadable(requestedCategoryIDs: Set<String>) throws -> Bool {
        guard let index else {
            throw TractandaError("indexUnavailable", "The category index is unavailable.")
        }
        for id in try index.relatedCategoryIDs(
            startingAt: requestedCategoryIDs, limit: Self.categoryWorkingSetLimit)
        {
            guard let head = try currentHead(id), !head.isDeleted,
                head.fields["selection"] != nil, canRead(head)
            else { return false }
        }
        return true
    }
    func hasLivePersonalStateItems() -> Bool {
        if let hasLivePersonalStateMemo { return hasLivePersonalStateMemo }
        let present = (try? index?.hasActiveHead(classID: "PersonalStateItem")) ?? true
        hasLivePersonalStateMemo = present
        return present
    }
    /// Returns an internal safe superset for categories whose complete readable
    /// branch is manual-only. Exact membership and access checks still run in Query.
    func categoryIncludeCandidates(categoryIDs: Set<String>) throws -> Set<String> {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        return try index.categoryIncludeCandidateIDs(categoryIDs: categoryIDs)
    }

    func categoryDecisionCandidates(categoryIDs: Set<String>) throws -> Set<String> {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        return try index.categoryDecisionCandidateIDs(categoryIDs: categoryIDs)
    }
    func savedViewBaseIDsForTesting(id: String) throws -> Set<String> {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        return try index.savedViewBaseIDsForTesting(id: id)
    }
    var savedViewCategoryPlanLookupsForTesting: Int {
        index?.savedViewCategoryPlanLookupsForTesting ?? 0
    }
    func savedViewStagedIDsForTesting(id: String) throws -> Set<String> {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        return try index.savedViewStagedIDsForTesting(id: id)
    }
    func advanceSavedViewMaterialization(id: String) throws {
        try index?.advanceSavedViewMaterialization(id: id)
    }
    func savedViewCategorySelectionMatches(
        id: String, expression: String?, text: String?, categoryPath: [String],
        excludedCategoryIDs: [String], sort: [ItemSort]
    ) throws -> Bool {
        try index?.savedViewCategorySelectionMatches(
            id: id, expression: expression, text: text, categoryPath: categoryPath,
            excludedCategoryIDs: excludedCategoryIDs, sort: sort) ?? false
    }
    func setSavedViewMaterializationBatchLimitForTesting(_ limit: Int?) {
        index?.savedViewMaterializationBatchLimitForTesting = limit
    }
    func setSavedViewMaterializationByteLimitForTesting(_ limit: Int?) {
        index?.savedViewMaterializationByteLimitForTesting = limit
    }
    func indexedPage(
        text: String?, classEquals: String?, order: ItemIndex.IndexedOrder,
        position: Int, limit: Int,
        exactIndexPredicate: Bool,
        needsFullRevision: Bool,
        candidatePlan: SpotlightQuery.IndexCandidatePlan = .all,
        savedViewID: String? = nil,
        accepts: (Revision) throws -> Bool
    ) throws -> ItemIndex.Page {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        var aclUserID: UInt32?
        if !isAdministrator, let context = accessContext, let account = context.account,
            account.groupIDs.count <= 1024,
            let names = try index.aclPrincipalNames(maximum: 1024),
            names.users.count + names.groups.count <= 1024,
            context.resolver.cachedPrincipalCount + names.users.count + names.groups.count <= 1024
        {
            do {
                var userIDs: [String: UInt32] = [:]
                for name in names.users { userIDs[name] = try context.resolver.userID(name) }
                var groupIDs: [String: (id: UInt32, member: Bool)] = [:]
                for name in names.groups {
                    let id = try context.resolver.groupID(name)
                    groupIDs[name] = (id, account.groupIDs.contains(id))
                }
                try index.setRequestPrincipals(actorUID: context.uid, users: userIDs, groups: groupIDs)
                aclUserID = context.uid
            } catch {
                // Current OS names and aliases can change between requests. If any indexed
                // name cannot be resolved now, retain the serial exact evaluator.
                aclUserID = nil
            }
        }
        defer {
            if aclUserID != nil { try? index.clearRequestPrincipals() }
        }
        let page = try index.orderedPage(
            lexicalText: text, classEquals: classEquals, order: order,
            position: position, limit: limit,
            fastCount: (isAdministrator && exactIndexPredicate)
                || (aclUserID != nil && !needsFullRevision && exactIndexPredicate),
            candidatePlan: candidatePlan, aclUserID: aclUserID, savedViewID: savedViewID
        ) { id in
            guard let head = try currentHead(id), !head.isDeleted else { return false }
            if aclUserID == nil, !canRead(head) { return false }
            guard needsFullRevision else { return true }
            guard let revision = try currentRevision(id) else { return false }
            return try accepts(revision)
        }
        if aclUserID != nil {
            for id in page.ids {
                guard let head = try currentHead(id), !head.isDeleted, canRead(head) else {
                    throw TractandaError("indexError", "Indexed authorization changed during a request.")
                }
            }
        }
        return page
    }
    func indexedSeekPage(
        order: ItemIndex.IndexedOrder, classEquals: String?, boundary: Double, boundaryID: String,
        previous: Bool, limit: Int, knownTotal: Int, candidatePlan: SpotlightQuery.IndexCandidatePlan,
        needsFullRevision: Bool, accepts: (Revision) throws -> Bool
    ) throws -> ItemIndex.SeekPage {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        var aclUserID: UInt32?
        if !isAdministrator, let context = accessContext, let account = context.account,
            account.groupIDs.count <= 1024,
            let names = try index.aclPrincipalNames(maximum: 1024),
            names.users.count + names.groups.count <= 1024,
            context.resolver.cachedPrincipalCount + names.users.count + names.groups.count <= 1024
        {
            do {
                var userIDs: [String: UInt32] = [:]
                for name in names.users { userIDs[name] = try context.resolver.userID(name) }
                var groupIDs: [String: (id: UInt32, member: Bool)] = [:]
                for name in names.groups {
                    let id = try context.resolver.groupID(name)
                    groupIDs[name] = (id, account.groupIDs.contains(id))
                }
                try index.setRequestPrincipals(actorUID: context.uid, users: userIDs, groups: groupIDs)
                aclUserID = context.uid
            } catch { aclUserID = nil }
        }
        defer { if aclUserID != nil { try? index.clearRequestPrincipals() } }
        return try index.orderedSeekPage(
            lexicalText: nil, classEquals: classEquals, order: order, boundary: boundary,
            boundaryID: boundaryID, previous: previous, limit: limit,
            fastCount: isAdministrator || aclUserID != nil,
            knownTotal: knownTotal, exactPredicate: !needsFullRevision, candidatePlan: candidatePlan,
            aclUserID: aclUserID,
            accepts: { id in
                guard let head = try self.currentHead(id), !head.isDeleted else { return false }
                guard self.isAdministrator || self.canRead(head) else { return false }
                guard needsFullRevision else { return true }
                guard let revision = try self.currentRevision(id) else { return false }
                return try accepts(revision)
            })
    }
    func cursorSeekQueryPlanForTesting(
        order: ItemIndex.IndexedOrder, classEquals: String?,
        candidatePlan: SpotlightQuery.IndexCandidatePlan
    ) throws -> [String] {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        return try index.seekQueryPlan(order: order, classEquals: classEquals, candidatePlan: candidatePlan)
    }
    var cursorSeekVMInstructionsForTesting: Int { index?.seekVMInstructionsForTesting ?? 0 }
    func resetCursorSeekVMInstructionsForTesting() { index?.resetSeekVMInstructionsForTesting() }
    func savedViewIndexIsReady(_ id: String) throws -> Bool {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        return try index.savedViewIsReady(id: id)
    }

    public func commit(_ request: CommitRequest, actorUID: UInt32? = nil) throws -> CommitResult {
        if accessContext == nil {
            return try withAccess(forUID: actorUID ?? ownerUID) { try commit(request, actorUID: actorUID) }
        }
        guard isCanonicalReady else {
            throw TractandaError(
                "recoveryRequired", "Resolve canonical recovery errors before reading or writing.")
        }
        let context = accessContext!
        let uid = actorUID ?? context.uid
        guard uid == context.uid else {
            throw TractandaError("forbidden", "The actor must match the authenticated request.")
        }
        let actor = context.account.map { "user:\($0.name)" } ?? "uid:\(uid)"
        guard !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
            !request.operationID.contains("\0")
        else {
            throw TractandaError("invalidArguments", "Supply a nonempty operationID of at most 200 bytes.")
        }
        // Canonical request bytes are retained rather than relying on a disposable receipt table.
        let identity = try JSON.encode(request).base64EncodedString()
        if let previous = try priorOperation(request.operationID, uid: uid) {
            guard let previousHead = try currentHead(previous.itemID), canRead(previousHead) else {
                throw TractandaError("forbidden", "Item access is denied.")
            }
            guard previous.fields["requestIdentity"]?.string == identity else {
                throw TractandaError(
                    "operationMismatch", "This operationID already committed a different edit.")
            }
            return CommitResult(
                revision: previous, wasReplayed: true, isIndexReady: index != nil, warnings: [])
        }
        guard Set(request.unset).count == request.unset.count,
            Set(request.changes.keys).isDisjoint(with: request.unset),
            Self.managed.isDisjoint(with: request.changes.keys), Self.managed.isDisjoint(with: request.unset)
        else {
            throw TractandaError(
                "invalidArguments", "Conflicting edits or writes to server-managed properties.")
        }
        for name in Array(request.changes.keys) + request.unset {
            guard !name.isEmpty, !name.contains("\0") else {
                throw TractandaError("invalidKey", "Empty/NUL property key.")
            }
        }
        var base: Revision?
        if request.action == .create {
            guard request.itemID == nil, request.expectedRevisionID == nil, request.classID != nil else {
                throw TractandaError(
                    "invalidArguments", "Create needs classID; IDs are allocated by the server.")
            }
        } else {
            guard let id = request.itemID, let expected = request.expectedRevisionID else {
                throw TractandaError("invalidArguments", "Edits require itemID and expectedRevisionID.")
            }
            base = try get(id)
            if request.action != .copy {
                try requireEdit(
                    base!,
                    changesPermissions: request.changes["permissions"] != nil
                        || request.unset.contains("permissions"))
            }
            guard base!.revisionID == expected else {
                throw TractandaError("revisionConflict", "The item changed; fetch it and reconcile the edit.")
            }
            if request.action == .retype {
                guard request.classID != nil else {
                    throw TractandaError("invalidArguments", "Retype needs classID.")
                }
            } else if request.classID != nil {
                throw TractandaError(
                    "invalidArguments", "Use retype to change the class of an existing item.")
            }
        }
        var fields = base?.fields ?? [:]
        let isNew = request.action == .create || request.action == .copy
        if isNew { for name in Self.managed { fields.removeValue(forKey: name) } }
        if request.action == .copy {
            fields["isDeleted"] = .boolean(false)
            // Feedback's content revision belongs to the original identity. Manual
            // assignments remain ordinary copied state; suggestion feedback starts afresh.
            fields.removeValue(forKey: "learningFeedback")
            fields.removeValue(forKey: "permissions")
            fields.removeValue(forKey: "templateKey")
        }
        let now = Timestamp.now()
        let itemID = isNew ? try makePersistentUUID().uuidString.lowercased() : base!.itemID
        let revisionID = try makePersistentUUID().uuidString.lowercased()
        let existingItem = try currentHead(itemID)
        let existingRevision = try currentHead(revisionID)
        let existingRevisionLocation = try index?.revision(revisionID)
        guard !isNew || existingItem == nil, existingRevisionLocation == nil,
            existingRevision == nil, itemID != revisionID
        else {
            throw TractandaError(
                "identifierCollision",
                "UUID generation repeated an existing identity; no revision was published.")
        }
        fields["itemID"] = .text(itemID)
        fields["revisionID"] = .text(revisionID)
        fields["classID"] = .text(request.classID ?? base!.classID)
        fields["schemaVersion"] =
            request.action == .retype ? .integer(1) : base?.fields["schemaVersion"] ?? .integer(1)
        fields["createdAt"] = isNew ? .date(now) : base!.fields["createdAt"]!
        fields["modifiedAt"] = .date(now)
        fields["actor"] = .text(actor)
        fields["operationID"] = .text(request.operationID)
        fields["requestIdentity"] = .text(identity)
        if !isNew { fields["supersedes"] = .text(base!.revisionID) }
        for (name, value) in request.changes { fields[name] = value }
        for name in request.unset { fields.removeValue(forKey: name) }
        let isConfiguration = fields["classID"]?.string == AccessConfiguration.classID
        if isConfiguration || base?.classID == AccessConfiguration.classID {
            try requireAdministrator()
            guard request.action != .copy, request.action != .retype else {
                throw TractandaError(
                    "invalidAccessConfiguration", "The access configuration cannot be copied or retyped.")
            }
        }
        if isMultiUser, !isConfiguration {
            if isNew, fields["permissions"] == nil, let account = context.account {
                fields["permissions"] = ItemPermissions.privateValue(for: account)
            }
            guard let value = fields["permissions"] else {
                throw TractandaError(
                    "invalidPermissions", "Shared-store records require a permission descriptor.")
            }
            let permissions = try ItemPermissions(value)
            try permissions.validate(using: context.resolver)
            if !isAdministrator, let account = context.account {
                if isNew, try context.resolver.userID(permissions.owner) != uid {
                    throw TractandaError("forbidden", "New items must belong to their authenticated creator.")
                }
                guard try permissions.allows(4, for: account, using: context.resolver) else {
                    throw TractandaError(
                        "invalidPermissions", "A committed edit must remain readable to its editor.")
                }
            }
        }
        let revision = try Revision(fields: fields)
        try ItemSemantics.validate(revision)
        let previousParents = try base.map(CategoryHierarchy.parents) ?? []
        for id in try CategoryHierarchy.parents(of: revision) where !previousParents.contains(id) {
            _ = try Categories.rule(get(id))
        }
        // Deleting/disabling a parent leaves its children usable as roots. Restoring it
        // must revalidate the entire graph, including links made while it was disabled.
        let isCategoryRecord =
            base?.fields["selection"] != nil || revision.fields["selection"] != nil
            || base?.fields["categoryParents"] != nil || revision.fields["categoryParents"] != nil
        if isCategoryRecord
            && (base?.fields["categoryParents"] != revision.fields["categoryParents"]
                || base?.fields["selection"] != revision.fields["selection"]
                || (base?.isDeleted ?? false) != revision.isDeleted)
        {
            beforeCategoryGraphValidation?()
            _ = try CategoryHierarchy(
                retainedCategoryRevisions(excluding: revision.itemID) + [revision])
        }
        var updatedConfiguration = accessConfiguration
        if isConfiguration {
            updatedConfiguration = try configuration(
                in: retainedConfigurationRevisions(excluding: revision.itemID) + [revision])
            let resolver = PrincipalResolver(directory: accounts, configuration: updatedConfiguration)
            try updatedConfiguration!.validate(using: resolver)
            try forEachCurrentHead { head in
                guard head.itemID != revision.itemID else { return }
                if let value = head.fields["permissions"] {
                    try ItemPermissions(value).validate(using: resolver)
                }
            }
        }
        if revision.classID == "PersonalStateItem", let target = revision.fields["target"]?.link {
            _ = try get(target.itemID, revisionID: target.revisionID)
            if let owner = revision.fields["permissions"]?.map?["owner"]?.string {
                let ownerUID = try context.resolver.userID(owner)
                try forEachCurrentHead(classID: "PersonalStateItem") { other in
                    guard other.itemID != revision.itemID, !other.isDeleted,
                        other.fields["target"]?.link?.itemID == target.itemID
                    else { return }
                    if let otherOwner = other.fields["permissions"]?.map?["owner"]?.string,
                        try context.resolver.userID(otherOwner) == ownerUID
                    {
                        throw TractandaError(
                            "invalidPersonalState", "This user already has an overlay for that item.")
                    }
                }
            }
        }
        // New manual decisions require access to the category; unchanged private references may remain.
        for field in ["categoryOverrides", "personalOverrides"] {
            for (id, value) in revision.fields[field]?.map ?? [:] where base?.fields[field]?.map?[id] != value
            {
                if isMultiUser { _ = try get(id) }
            }
        }
        for value in revision.fields["learningFeedback"]?.map?.values ?? [:].values {
            let feedback = try LearningFeedback(value)
            guard try loadRevision(feedback.revisionID)?.itemID == revision.itemID else {
                throw TractandaError(
                    "invalidLearningFeedback", "Feedback must refer to an earlier revision of this item.")
            }
        }
        // Type and reference validity is checked at commit, but later missing targets remain errors.
        let previousHolders = try base.map { try RoleSemantics.holdings($0).map(\.holder) } ?? []
        for holding in try RoleSemantics.holdings(revision) where !previousHolders.contains(holding.holder) {
            let holder = try get(holding.holder.itemID, revisionID: holding.holder.revisionID)
            guard ItemTypes.ancestry(holder.classID).contains("PersonItem"), holder.classID != "RoleItem",
                !holder.isDeleted
            else {
                throw TractandaError(
                    "invalidHolder", "A holder must reference an available, concrete non-role person.")
            }
        }
        let data = try RecordCodec.encode(revision)
        guard data.count <= 8 * 1024 * 1024 else {
            throw TractandaError("limit", "Record exceeds 8 MiB, including metadata and retry intent.")
        }
        let summaryBytes = try JSON.encode(
            revision.fields.filter {
                ItemIndex.headSummaryFieldNames.contains($0.key)
            }
        ).count
        guard summaryBytes <= 2 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Current-head summary exceeds its byte budget.")
        }
        let date = Timestamp.parse(now)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let folder = root.appendingPathComponent(
            String(
                format: "items/%04d/%02d/%02d/%02d/%02d/%@", c.year!, c.month!, c.day!, c.hour!, c.minute!,
                revision.itemID))
        try ensureDirectory(folder)
        let path = folder.appendingPathComponent(revision.revisionID + ".tractanda").path
        let markerPreviouslyDirty = StoreCheckpoint.isDirty(root: root)
        try StoreCheckpoint.markDirty(root: root)
        let actualPublish = data.withUnsafeBytes { tractanda_publish(path, $0.baseAddress, $0.count) }
        let published = publishResultOverrideForTesting ?? actualPublish
        guard published >= 0 else {
            throw TractandaError(
                "writeFailed", "Revision publication failed: \(String(cString: strerror(errno)))")
        }
        let publishedURL = URL(fileURLWithPath: path)
        let publishedMetadata = try FileMetadata.read(at: publishedURL)
        let newLocation = RevisionLocation(
            itemID: revision.itemID,
            relativePath: String(publishedURL.path.dropFirst(root.path.count + 1)), actor: actor,
            operationID: request.operationID, parentID: revision.supersedes,
            metadata: publishedMetadata, digest: Data(SHA256.hash(data: data)),
            createdAt: revision.fields["createdAt"]?.dateString ?? "",
            feedbackRevisionIDs: (revision.fields["learningFeedback"]?.map?.values.compactMap {
                try? LearningFeedback($0).revisionID
            } ?? []))
        let previousResident = try currentHead(revision.itemID)
        let nextResident = Self.residentHead(revision)
        if isConfiguration {
            accessPolicyEpoch &+= 1
            visibleStates.removeAll()
            visibleStateOrder.removeAll()
        } else {
            updateVisibleStates(old: previousResident, new: nextResident)
        }
        try rememberHead(nextResident)
        hasLivePersonalStateMemo = nil
        accessConfiguration = updatedConfiguration
        if isConfiguration {
            accessContext = StoreAccessContext(
                uid: context.uid, account: context.account ?? (try? accounts.user(forUID: context.uid)),
                resolver: PrincipalResolver(directory: accounts, configuration: updatedConfiguration),
                isAdministrator: context.isAdministrator)
        }
        let changedFields = Set(request.changes.keys).union(request.unset)
        let broadSavedViewInvalidation =
            request.action == .create
            || request.action == .copy
            || request.action == .retype
            || changedFields.contains("permissions")
            || changedFields.contains("categoryOverrides")
            || changedFields.contains("isDeleted")
            || revision.isDeleted != (base?.isDeleted ?? false)
            || isConfiguration
            || isCategoryRecord
            || revision.classID == "CategoryItem"
            || revision.classID == "PersonalStateItem"
            || base?.classID == "CategoryItem"
            || base?.classID == "PersonalStateItem"
        let committedFields = changedFields.union([
            "revisionID", "modifiedAt", "actor", "operationID", "requestIdentity", "supersedes",
            "schemaVersion",
        ])
        invalidateSavedViewPages(
            changedFields: Set(committedFields.map { "field:" + metadataKey($0) }),
            itemID: revision.itemID, base: base, revision: revision,
            broad: broadSavedViewInvalidation)
        generation = Identifier.make()
        var warnings = published == 1 ? ["Committed; directory durability could not be confirmed."] : []
        // Persist the new date-directory entries as well as the leaf publication.
        // This is fsync-based durability; actual power-loss behavior still needs hardware testing.
        var directoryDurabilityConfirmed = published == 0
        var directory = folder
        while directory.path.hasPrefix(root.path + "/") || directory == root {
            let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if descriptor < 0 || fsync(descriptor) != 0 {
                warnings.append("Committed; an ancestor directory could not be synchronized.")
                directoryDurabilityConfirmed = false
            }
            if descriptor >= 0 { close(descriptor) }
            directory.deleteLastPathComponent()
        }
        do {
            try beforeIndexUpdate?()
            guard let index else { throw TractandaError("indexUnavailable", "Index requires rebuilding.") }
            try index.execute("BEGIN IMMEDIATE")
            do {
                try index.put(revision)
                try index.upsertCatalogue(newLocation.catalogueRow(revisionID: revision.revisionID))
                try index.execute("COMMIT")
                if Self.categoryUsesClock(revision) || base.map(Self.categoryUsesClock) == true {
                    clockDependentCategories = try index.hasClockDependentCategories()
                }
            } catch {
                try? index.execute("ROLLBACK")
                throw error
            }
            revisionLocations.removeAll(keepingCapacity: false)
            operations.removeAll(keepingCapacity: false)
            operationIDs.removeAll(keepingCapacity: false)
        } catch {
            if let index {
                do {
                    try index.closeChecked()
                    self.index = nil
                } catch {
                    // Keep the live handle reachable until SQLite permits a checked close.
                }
            }
            isCanonicalReady = false
            warnings.append("Committed to files; index update failed. Rebuild before querying.")
        }
        if index != nil, isCanonicalReady, directoryDurabilityConfirmed, !markerPreviouslyDirty {
            do {
                try beforeCheckpointClear?()
                try StoreCheckpoint.clear(root: root)
            } catch {
                warnings.append("Committed; checkpoint marker remains and startup will recover fully.")
            }
        }
        return CommitResult(
            revision: revision, wasReplayed: false, isIndexReady: index != nil && isCanonicalReady,
            warnings: warnings)
    }

    public func rebuildIndex() throws {
        try requireAdministrator()
        indexRebuildInProgress = true
        defer { indexRebuildInProgress = false }
        var rebuildPublished = false
        defer {
            if !rebuildPublished {
                isCanonicalReady = false
                if let index {
                    do {
                        try index.closeChecked()
                        self.index = nil
                    } catch {
                        // A busy connection stays attached so no sidecars can be mistaken for stale files.
                    }
                }
            }
        }
        let priorVerificationState = canonicalVerificationStatus["state"] as? String
        let priorFindingCount = canonicalVerificationStatus["findingCount"] as? Int ?? 0
        // A caller may request this after an offline restore. If the process stops before the
        // replacement catalogue is durable, the previous clean catalogue must not be reused.
        try StoreCheckpoint.markDirty(root: root)
        isCanonicalReady = false
        if let index { try index.closeChecked() }
        index = nil
        hasLivePersonalStateMemo = nil
        recoveryWarnings = []
        let measureStartup = ProcessInfo.processInfo.environment["TRACTANDA_STARTUP_METRICS"] == "1"
        let recoveryStarted = ProcessInfo.processInfo.systemUptime
        let temporary = indexDirectory.appendingPathComponent("rebuild-\(Identifier.make()).sqlite")
        let destination = indexDirectory.appendingPathComponent("items.sqlite")
        var temporaryIsClosed = false
        defer {
            if temporaryIsClosed { try? FileManager.default.removeItem(at: temporary) }
        }
        let fresh = try ItemIndex(path: temporary.path, create: true)
        try fresh.execute("BEGIN IMMEDIATE")
        let statements = try fresh.makeRebuildStatements()
        defer { statements.close() }
        let recoveryPhases = try recover(
            staging: fresh, statements: statements, measurePhases: measureStartup)
        try fresh.finalizeSavedViewMaterializations()
        let recoveryEnded = ProcessInfo.processInfo.systemUptime
        isCanonicalReady = false
        let recoveredRecordCount = try fresh.catalogueCount()
        let recoveredHeadCount = try fresh.currentHeadCount()
        let insertStarted = ProcessInfo.processInfo.systemUptime
        let identity = try canonicalStoreIdentity(creatingIfMissing: false)
        try fresh.sealCatalogue(identity: identity)
        let insertEnded = ProcessInfo.processInfo.systemUptime
        try syncCanonicalForCheckpoint(index: fresh)
        let commitStarted = ProcessInfo.processInfo.systemUptime
        try fresh.execute("COMMIT")
        let commitEnded = ProcessInfo.processInfo.systemUptime
        statements.close()
        try fresh.checkpoint(path: temporary.path)
        try fresh.closeChecked()
        temporaryIsClosed = true
        try index?.closeChecked()
        index = nil
        let publicationStarted = ProcessInfo.processInfo.systemUptime
        // Old rollback/WAL state belongs to the discarded database. SQLite
        // must not recover it against the newly rebuilt file at the same path.
        for suffix in ["-journal", "-wal", "-shm"] {
            let companion = URL(fileURLWithPath: destination.path + suffix)
            if FileManager.default.fileExists(atPath: companion.path) {
                try FileManager.default.removeItem(at: companion)
            }
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw TractandaError("indexError", "Cannot replace disposable index.")
        }
        index = try ItemIndex(path: destination.path, create: false)
        if let index { installIndexFailureHandler(index) }
        try StoreCheckpoint.syncDirectory(indexDirectory)
        if StoreCheckpoint.isDirty(root: root) {
            try beforeCheckpointClear?()
            try StoreCheckpoint.clear(root: root)
        }
        isCanonicalReady = true
        revisionLocations.removeAll(keepingCapacity: false)
        operations.removeAll(keepingCapacity: false)
        operationIDs.removeAll(keepingCapacity: false)
        let publicationEnded = ProcessInfo.processInfo.systemUptime
        generation = Identifier.make()
        exactScopedStates.removeAll()
        visibleStates.removeAll()
        visibleStateOrder.removeAll()
        canonicalVerificationStatus = [
            "state": "rebuilt", "completedAt": ISO8601DateFormatter().string(from: Date()),
            "recoveredRecordCount": recoveredRecordCount,
            "priorVerificationState": priorVerificationState ?? "unknown",
            "priorFindingCount": priorFindingCount,
        ]
        if measureStartup {
            let stats: [String: Any] = [
                "recoveryStartUptime": recoveryStarted, "recoveryEndUptime": recoveryEnded,
                "insertStartUptime": insertStarted, "insertEndUptime": insertEnded,
                "commitStartUptime": commitStarted, "commitEndUptime": commitEnded,
                "publicationStartUptime": publicationStarted,
                "publicationEndUptime": publicationEnded,
                "recoverySeconds": recoveryEnded - recoveryStarted,
                "recoveryEnumerationStartUptime": recoveryPhases?.enumerationStart ?? recoveryStarted,
                "recoveryEnumerationEndUptime": recoveryPhases?.enumerationEnd ?? recoveryEnded,
                "recoveryEnumerationSeconds": (recoveryPhases?.enumerationEnd ?? recoveryEnded)
                    - (recoveryPhases?.enumerationStart ?? recoveryStarted),
                "recoveryRecordReadDecodeSeconds": recoveryPhases?.recordReadDecodeSeconds ?? 0,
                "recoveryRecordReadSeconds": recoveryPhases?.recordReadSeconds ?? 0,
                "recoveryRecordDecodeSeconds": recoveryPhases?.recordDecodeSeconds ?? 0,
                "recoveryRecordHashSeconds": recoveryPhases?.recordHashSeconds ?? 0,
                "recoverySemanticValidationSeconds": recoveryPhases?.semanticValidationSeconds ?? 0,
                "recoveryValidationStartUptime": recoveryPhases?.chainStart ?? recoveryEnded,
                "recoveryValidationEndUptime": recoveryPhases?.chainEnd ?? recoveryEnded,
                "recoveryValidationSeconds": (recoveryPhases?.chainEnd ?? recoveryEnded)
                    - (recoveryPhases?.chainStart ?? recoveryEnded),
                "recoveryFinalizationStartUptime": recoveryPhases?.finalizationStart ?? recoveryEnded,
                "recoveryFinalizationEndUptime": recoveryPhases?.finalizationEnd ?? recoveryEnded,
                "recoveryFinalizationSeconds": (recoveryPhases?.finalizationEnd ?? recoveryEnded)
                    - (recoveryPhases?.finalizationStart ?? recoveryEnded),
                "sqliteInsertSeconds": insertEnded - insertStarted,
                "sqliteCommitSeconds": commitEnded - commitStarted,
                "publicationSeconds": publicationEnded - publicationStarted,
                "headCount": recoveredHeadCount,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys]),
                let line = String(data: data, encoding: .utf8)
            {
                FileHandle.standardError.write(Data(("TRACTANDA_STARTUP_METRICS " + line + "\n").utf8))
            }
        }
        rebuildPublished = true
    }

    /// A full rebuild may follow uncertain publication or an explicit offline restore. Validate
    /// and synchronize writable canonical bytes and ancestor entries before sealing a clean
    /// checkpoint. Read-only archive paths retain their existing recovery exemption.
    private func syncCanonicalForCheckpoint(index: ItemIndex) throws {
        try beforeCanonicalDurabilitySync?()
        let itemsRoot = root.appendingPathComponent("items")
        var cursor: String?
        while true {
            let rows = try index.recoveryRowPage(after: cursor, limit: 128)
            if rows.isEmpty { break }
            for row in rows {
                let locationURL = root.appendingPathComponent(row.path)
                let archiveState = tractanda_path_read_only(locationURL.path)
                guard archiveState >= 0 else {
                    throw TractandaError("recoveryError", "Cannot inspect canonical filesystem state.")
                }
                if archiveState != 1 {
                    let descriptor = open(locationURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard descriptor >= 0 else {
                        throw TractandaError(
                            "recoveryError", "Cannot open canonical record for synchronization.")
                    }
                    let result = fsync(descriptor)
                    _ = close(descriptor)
                    guard result == 0 else {
                        throw TractandaError("recoveryError", "Cannot synchronize canonical record.")
                    }
                }
                var directory = locationURL.deletingLastPathComponent()
                while directory.path.hasPrefix(itemsRoot.path + "/") {
                    if tractanda_path_read_only(directory.path) != 1 {
                        try StoreCheckpoint.syncDirectory(directory)
                    }
                    directory.deleteLastPathComponent()
                }
                cursor = row.revisionID
            }
        }
        if tractanda_path_read_only(itemsRoot.path) != 1 { try StoreCheckpoint.syncDirectory(itemsRoot) }
        if tractanda_path_read_only(root.path) != 1 { try StoreCheckpoint.syncDirectory(root) }
    }
}
