import CSQLite
import CTractandaPlatform
import Crypto
import Foundation
import TractandaVectors

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
    /// Explicit source/test gate. Foreign intake is a separate, unavailable capability.
    public let revisionProjectionEnabled: Bool
    /// Internal source/test gate. Public intake and listeners remain unavailable until 2C2B.
    public let authorityIntakeEnabled: Bool
    private var peerIntake: PeerIntakeCoordinator?
    var peerClockHealth: PeerClockHealth?
    var peerExportBoundaryForTesting: ((PeerExportPlan.Boundary) throws -> Void)?
    private var authorityExistingHistoryAdmitted = false
    var authorityAfterAcceptanceSealForTesting: (() throws -> Void)?
    var authorityControlInspectedForTesting: ((String) -> Void)?
    private var authorityBootstrapPending = false
    // Only the exact fresh operation may keep its not-yet-admitted founding policy out of
    // serving projections. Converted pre-existing policy retains ordinary maintenance semantics.
    private var pendingFoundingPolicy: InitialAuthorityBootstrap.Original?
    private var authorityCatchupActive = false
    var peerIntakeBoundaryForTesting: ((PeerIntakeJournal.Boundary) throws -> Void)? {
        didSet { peerIntake?.journal.afterBoundaryForTesting = peerIntakeBoundaryForTesting }
    }
    var peerIntakeOriginalPublicationForTesting: (() throws -> Void)? {
        didSet {
            peerIntake?.journal.afterOriginalPublicationForTesting = peerIntakeOriginalPublicationForTesting
        }
    }
    var revisionProjectionLimits = RevisionProjection.Limits()
    var publicationClockForTesting: () -> String = { Timestamp.now() }
    var canonicalRecordByteLimitForTesting = 8 * 1024 * 1024
    var beforeProjectionCommitAuthorityForTesting: (() throws -> Void)?
    var beforeCombinationIndexUpdateForTesting: (() throws -> Void)?
    var beforeCanonicalReaderRequirementForTesting: (() throws -> Void)?
    private var combinationPublicationAwaitingIndex = false
    private var generation = Identifier.make()
    private var accessContext: StoreAccessContext?
    private var accessConfiguration: AccessConfiguration?
    private var currentAccessConfigurations: [AccessConfiguration] = []
    private var accessConfigurationProofUnavailable = false
    private var accessConfigurationAmbiguous: Bool { currentAccessConfigurations.count > 1 }
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
    public var isMultiUser: Bool {
        accessConfiguration != nil || accessConfigurationAmbiguous || accessConfigurationProofUnavailable
    }
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
        -> (
            rows: [ItemIndex.CatalogueRow], notFound: [String],
            unresolved: [ItemUnresolvedState], stateTokens: [String: String]
        )
    {
        guard isCanonicalReady, let index else {
            throw TractandaError("recoveryRequired", "The current catalogue is unavailable.")
        }
        var rows: [ItemIndex.CatalogueRow] = []
        var notFound: [String] = []
        var unresolved: [ItemUnresolvedState] = []
        var tokens: [String: String] = [:]
        for id in ids {
            try Identifier.validate(id)
            if revisionProjectionEnabled {
                do {
                    let state = try itemState(id)
                    tokens[id] = state.stateToken
                    if state.status != .ready {
                        unresolved.append(
                            ItemUnresolvedState(
                                itemID: id, status: state.status,
                                stateToken: state.stateToken, resource: state.resource))
                        continue
                    }
                } catch let error as TractandaError
                    where error.code == "notFound" || error.code == "forbidden"
                {
                    notFound.append(id)
                    continue
                }
            }
            guard let head = try currentHead(id), canRead(head) else {
                notFound.append(id)
                continue
            }
            guard let row = try index.revision(head.revisionID), row.itemID == id else {
                throw TractandaError("recoveryError", "A current indexed revision is missing.")
            }
            rows.append(row)
        }
        return (rows, notFound, unresolved, tokens)
    }

    func verifyPooledGet(
        _ records: [PooledCanonicalRecord], rows: [ItemIndex.CatalogueRow],
        stateTokens: [String: String]
    ) throws
        -> Bool
    {
        guard isCanonicalReady, let index, records.count == rows.count else { return false }
        for (id, token) in stateTokens {
            guard let current = try? itemState(id), current.stateToken == token else { return false }
        }
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
        if revisionProjectionEnabled { return try itemState(id).stateToken }
        guard let head = try currentHead(id) else {
            throw TractandaError("notFound", "Item or revision is unavailable.")
        }
        guard canRead(head) else { throw TractandaError("forbidden", "Item access is denied.") }
        return try index?.currentProjection(itemID: id)?.state.stateToken ?? head.revisionID
    }

    func verifyPooledHistory(_ result: PooledHistoryResult, itemID: String, stateToken: String)
        throws -> Bool
    {
        guard isCanonicalReady, let index, result.records.count == result.rows.count else { return false }
        guard try preparePooledHistory(itemID) == stateToken else { return false }
        for (record, row) in zip(result.records, result.rows) {
            guard row.itemID == itemID, record.revision.itemID == itemID,
                let current = try index.revision(row.revisionID),
                current.path == row.path, current.digest == row.digest,
                current.parentID == row.parentID, current.createdAt == row.createdAt,
                current.modifiedAt == row.modifiedAt, current.provenance == row.provenance,
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
    /// Local, nonsecret replica identity. Legacy read-only opens need not allocate one.
    public private(set) var replicaID: String?
    var beforeRevisionGraphValidationForTesting: ((ItemIndex) throws -> Void)?
    var recoveryCatalogueForTesting: ((ItemIndex) throws -> Void)?
    var revisionGraphProgressForTesting: (() throws -> Void)?
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
        let modifiedAt: String
        let provenance: RevisionProvenance?

        init(
            itemID: String, relativePath: String, actor: String, operationID: String,
            parentID: String?, metadata: FileMetadata, digest: Data,
            createdAt: String = "", feedbackRevisionIDs: [String] = [],
            modifiedAt: String = "", provenance: RevisionProvenance? = nil
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
            self.modifiedAt = modifiedAt
            self.provenance = provenance
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
            modifiedAt = row.modifiedAt
            provenance = row.provenance
        }

        func catalogueRow(revisionID: String) -> ItemIndex.CatalogueRow {
            ItemIndex.CatalogueRow(
                revisionID: revisionID, itemID: itemID,
                path: relativePath, parentID: parentID,
                actor: actor, operationID: operationID, size: metadata.size,
                inode: metadata.inode, uid: metadata.uid,
                mode: metadata.mode, modificationSeconds: metadata.modificationSeconds,
                modificationNanoseconds: metadata.modificationNanoseconds, digest: digest,
                createdAt: createdAt, feedbackRevisionIDs: feedbackRevisionIDs,
                modifiedAt: modifiedAt, provenance: provenance)
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
        if revisionProjectionEnabled {
            guard let projection = try index?.currentProjection(itemID: itemID),
                projection.state.status == .ready,
                let representative = projection.state.representativeRevisionID
            else { return nil }
            if heads[itemID]?.revisionID != representative {
                if let removed = heads.removeValue(forKey: itemID) {
                    headCacheBytes -= try residentByteCount(removed)
                    headCacheOrder.removeAll { $0 == itemID }
                }
            }
        }
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

    private var rebuildControl: RebuildControl?
    func rebuildAdministratorPolicy() throws -> RebuildAdministratorPolicy {
        try requireAdministrator()
        return RebuildAdministratorPolicy(ownerUID: ownerUID, configuration: accessConfiguration)
    }
    private var isCanonicalReady = false
    private var targetProvisioningScope: PeerEnrollmentActivation.Scope?
    private var targetEnrollmentPageLimitForTesting: Int?
    private var targetEnrollmentControlActive = false
    private var targetProvisioningPending = false
    private var targetProvisioningProgress: ((String) throws -> Void)?
    private enum TargetEnrollmentValidation { case committedControls, fullReplay }
    private final class TargetEnrollmentReadMetrics {
        private let lock = NSLock()
        private var count = 0
        private var lastOriginalID: String?
        func record(_ id: String) {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            lastOriginalID = id
        }
        var snapshot: (count: Int, lastOriginalID: String?) {
            lock.lock()
            defer { lock.unlock() }
            return (count, lastOriginalID)
        }
    }
    private let targetEnrollmentReadMetrics = TargetEnrollmentReadMetrics()
    /// Actual non-administration item hydrations in this validator's full baseline traversal.
    /// This does not count bounded policy proof or other subsystems' startup replay reads.
    var targetEnrollmentBaselineTraversalReadsForTesting: (count: Int, lastOriginalID: String?) {
        targetEnrollmentReadMetrics.snapshot
    }
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
    var afterCanonicalSyncEntryForTesting: (() throws -> Void)?
    var beforeCanonicalDurabilitySync: (() throws -> Void)?
    var publishResultOverrideForTesting: Int32?
    var beforeCategoryGraphValidation: (() -> Void)?
    var beforeCategoryOverlayScan: (() -> Void)?
    var afterRecoveryRecordForTesting: ((URL) throws -> Void)?
    var beforeIndexQuarantineMarkerForTesting: (() throws -> Void)?
    // Deterministic collision injection in tests; production uses the UUIDv1 generator.
    var makePersistentUUID: () throws -> UUID = { try UUID.makeVersion1() }
    private var stagingByteQuota: StagingByteQuota!
    private var pendingCorpusReadReleases: Set<String> = []
    var beforeCorpusReadReleaseForTesting: ((String) throws -> Void)?
    var afterCorpusReadCaptureForTesting: (() throws -> Void)? {
        get { index?.afterCorpusReadCommitForTesting }
        set { index?.afterCorpusReadCommitForTesting = newValue }
    }
    private var attachmentPayloads: AttachmentPayloadStore!
    var payloadPlacementRecoveryScansForTesting: Int { attachmentPayloads.placementRecoveryScansForTesting }
    private var documentContents: DocumentContentStore!
    private var documentJobRecords: DocumentJobRecords!
    private var documentJobs: [String: DocumentJobRecord] = [:]
    private var documentJobWriters: [String: DocumentContentWriter] = [:]
    var beforeDocumentJobCommitForTesting: (() throws -> Void)?
    var afterDocumentJobHistoryForTesting: (() throws -> Void)? {
        get { documentJobRecords.afterHistoryWriteForTesting }
        set { documentJobRecords.afterHistoryWriteForTesting = newValue }
    }
    var afterDocumentJobLookupForTesting: (() throws -> Void)? {
        get { documentJobRecords.afterLookupWriteForTesting }
        set { documentJobRecords.afterLookupWriteForTesting = newValue }
    }
    private let attachmentCapacityProvider: (@Sendable () throws -> UInt64)?
    func setAttachmentReserveForTesting(_ bytes: Int64) throws {
        attachmentPayloads = try AttachmentPayloadStore(
            root: root, ownerUID: ownerUID, reserveBytes: bytes, availableBytes: attachmentCapacityProvider,
            stagingQuota: stagingByteQuota, indexDirectory: indexDirectory)
        documentContents = DocumentContentStore(
            root: root, ownerUID: ownerUID, minimumFreeBytes: bytes,
            availableBytes: attachmentCapacityProvider, stagingQuota: stagingByteQuota,
            indexDirectory: indexDirectory)
        documentJobRecords = DocumentJobRecords(
            root: root,
            files: DocumentContentFiles(
                root: root, ownerUID: ownerUID, minimumFreeBytes: bytes,
                availableBytes: attachmentCapacityProvider, stagingQuota: stagingByteQuota))
        try configurePeerOriginals(reserveBytes: bytes)
    }
    private func configurePeerOriginals(reserveBytes: Int64) throws {
        guard let peerIntake else { return }
        let bridge = try PeerOriginalTransfer(
            root: root, ownerUID: ownerUID, payloads: attachmentPayloads,
            quota: stagingByteQuota, reserveBytes: reserveBytes, availableBytes: attachmentCapacityProvider)
        try bridge.cleanupOldVerificationWork()
        peerIntake.journal.originals = bridge
        peerIntake.journal.documents = PeerDocumentTransfer(
            root: root, ownerUID: ownerUID, contents: documentContents, originals: bridge,
            quota: stagingByteQuota, reserveBytes: reserveBytes, availableBytes: attachmentCapacityProvider)
        peerIntake.documentVerification = try PeerDocumentVerification(
            contents: documentContents, originals: bridge)
        peerIntake.documentVerification?.corpusBoundary = { [weak self] batch in
            guard let self else {
                throw TractandaError("serviceClosed", "Store closed during peer corpus work.")
            }
            if batch.phase == .before {
                try self.requireIndexFilesystemCapacity(additionalBytes: batch.estimatedAdditionalBytes)
                try self.stagingByteQuota.reserveDerived(
                    workID: batch.workID,
                    estimatedAdditionalBytes: batch.estimatedAdditionalBytes)
            } else if batch.phase == .afterCommit {
                try self.stagingByteQuota.observeDerived(
                    workID: batch.workID,
                    retainedEncodedBytes: batch.retainedEncodedBytes)
            }
        }
        peerIntake.journal.beforeSealForProfile = { [weak self] profile in
            guard let self else { throw TractandaError("serviceClosed", "Store closed before sealing.") }
            if profile == PeerPackage.profile {
                try CanonicalReaderRequirement.beforePeerDocumentPublication(
                    root: self.root, ownerUID: self.ownerUID)
            } else if profile == PeerPackage.retainedOriginalProfile {
                try CanonicalReaderRequirement.beforePeerOriginalPublication(
                    root: self.root, ownerUID: self.ownerUID)
            }
        }
    }
    let attachmentUploadPolicy: AttachmentUploadPolicy
    var attachmentClockForTesting: () -> Date = { Date() }
    private var attachmentUploads: [String: AttachmentUploadState] = [:]
    private(set) var attachmentRecoveryValidationsForTesting = 0
    var beforeAttachmentCopyCommitForTesting: (() throws -> Void)?
    var beforeAttachmentCommitForTesting: (() throws -> Void)?
    var afterAttachmentItemCommitForTesting: (() throws -> Void)?
    var afterAttachmentPayloadPublicationForTesting: (() throws -> Void)?
    var afterAttachmentStageDiscardForTesting: (() throws -> Void)?
    private static let managed: Set<String> = [
        "itemID", "revisionID", "classID", "schemaVersion",
        "createdAt", "modifiedAt", "supersedes", "actor", "operationID", "requestIdentity",
        "revisionAncestry",
    ]

    public convenience init(
        root: URL, indexDirectory: URL? = nil,
        accounts: any AccountDirectory = SystemAccountDirectory(),
        attachmentUploadPolicy: AttachmentUploadPolicy = AttachmentUploadPolicy(),
        attachmentAvailableBytes: (@Sendable () throws -> UInt64)? = nil,
        revisionProjectionEnabled: Bool = false, authorityIntakeEnabled: Bool = false
    ) throws {
        try self.init(
            root: root, indexDirectory: indexDirectory, accounts: accounts,
            attachmentUploadPolicy: attachmentUploadPolicy,
            attachmentAvailableBytes: attachmentAvailableBytes,
            revisionProjectionEnabled: revisionProjectionEnabled,
            authorityIntakeEnabled: authorityIntakeEnabled,
            firstSourceOperation: nil)
    }

    // Internal opening capability is bound to the immutable first-source operation receipt.
    init(
        root: URL, indexDirectory requestedIndexDirectory: URL? = nil,
        accounts: any AccountDirectory = SystemAccountDirectory(),
        attachmentUploadPolicy: AttachmentUploadPolicy = AttachmentUploadPolicy(),
        attachmentAvailableBytes: (@Sendable () throws -> UInt64)? = nil,
        revisionProjectionEnabled: Bool = false, authorityIntakeEnabled: Bool = false,
        firstSourceOperation: InitialAuthorityBootstrap.Request?,
        requireInitializedStore: Bool = false,
        firstSourceProgress: ((String) throws -> Void)? = nil,
        targetProvisioning: PeerEnrollmentActivation.Opening? = nil,
        targetProvisioningProgress: ((String) throws -> Void)? = nil,
        targetProvisioningControl: (() throws -> Void)? = nil
    ) throws {
        guard targetProvisioning != nil || targetProvisioningControl == nil else {
            throw TractandaError(
                "invalidTargetProtocol", "Only a finite target owner installs opening control.")
        }
        try targetProvisioningControl?()
        try attachmentUploadPolicy.validate()
        if targetProvisioning != nil {
            let supplied = try FileMetadata.read(at: root.standardizedFileURL)
            guard supplied.type == .directory, supplied.uid == tractanda_uid(), supplied.mode & 0o077 == 0
            else {
                throw PeerEnrollmentActivation.failure(
                    "Target provisioning requires its existing private lexical root.")
            }
        }
        self.attachmentUploadPolicy = attachmentUploadPolicy
        self.attachmentCapacityProvider = attachmentAvailableBytes
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.accounts = accounts
        self.revisionProjectionEnabled = revisionProjectionEnabled
        self.authorityIntakeEnabled = authorityIntakeEnabled
        guard !authorityIntakeEnabled || revisionProjectionEnabled else {
            throw TractandaError(
                "authorityModeRequired", "Authority intake requires current projection enforcement.")
        }
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
            let attachmentPath = root.standardizedFileURL.appendingPathComponent("attachments").path
            guard suppliedPath != itemPath && !suppliedPath.hasPrefix(itemPath + "/"),
                suppliedPath != attachmentPath && !suppliedPath.hasPrefix(attachmentPath + "/")
            else {
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
        guard !Self.isDescendant(self.indexDirectory, of: self.root.appendingPathComponent("items")),
            !Self.isDescendant(self.indexDirectory, of: self.root.appendingPathComponent("attachments")),
            !Self.isDescendant(self.indexDirectory, of: self.root.appendingPathComponent("documents"))
        else {
            throw TractandaError(
                "invalidIndexDirectory", "Index files cannot be stored inside canonical items.")
        }
        try ensureDirectory(self.root)
        writer = tractanda_lock(self.root.appendingPathComponent(".writer.lock").path)
        guard writer >= 0 else {
            throw TractandaError("storeBusy", "Cannot lock store; another writer may be running.")
        }
        var openingProgress: (() throws -> Void)?
        do {
            defer { if targetProvisioningControl != nil { peerIntake?.progress = openingProgress } }
            // The lifetime writer is owned before this cancellable boundary.
            try targetProvisioningControl?()
            if requireInitializedStore { try Self.requireInitializedRoot(self.root) }
            if let targetProvisioning {
                guard firstSourceOperation == nil, authorityIntakeEnabled, revisionProjectionEnabled else {
                    throw PeerEnrollmentActivation.failure(
                        "Target provisioning cannot run first-source initialization.")
                }
                targetProvisioningScope = try PeerEnrollmentActivation.prepareUnderLock(
                    root: self.root,
                    suppliedRoot: root, ownerUID: ownerUID, writer: writer, opening: targetProvisioning)
                try targetProvisioningControl?()
                targetProvisioningPending =
                    try PeerEnrollmentActivation.loadReceipt(targetProvisioningScope!.files) == nil
                self.targetProvisioningProgress = targetProvisioningProgress
                if !targetProvisioningPending {
                    try PeerEnrollmentActivation.requireActivated(root: self.root, ownerUID: ownerUID)
                }
            } else {
                try PeerEnrollment.requireOrdinaryOpeningAllowed(root: self.root, ownerUID: ownerUID)
            }
            try InitialAuthorityBootstrap.requireOpeningAllowed(
                root: self.root, ownerUID: ownerUID, request: firstSourceOperation, accounts: accounts)
            if let scope = targetProvisioningScope {
                let prep = try scope.record.preparation
                let files = scope.files
                let expected = CanonicalStoreIdentity(formatVersion: 1, storeID: prep.commonStoreID)
                let storeName = Self.canonicalIdentityName
                let retainedStoreID: String?
                do {
                    _ = try FileMetadata.read(at: self.root.appendingPathComponent(storeName))
                    retainedStoreID = try CanonicalReaderRequirement.storeIdentity(
                        root: self.root, ownerUID: ownerUID)
                } catch FileMetadataError.posix(let code) where code == ENOENT { retainedStoreID = nil }
                if let retainedStoreID {
                    guard retainedStoreID == prep.commonStoreID else {
                        throw PeerEnrollmentActivation.failure("Target common identity differs.")
                    }
                } else {
                    guard (try? FileMetadata.read(at: self.root.appendingPathComponent("items"))) == nil,
                        (try? FileMetadata.read(at: self.root.appendingPathComponent(ReplicaIdentity.name)))
                            == nil
                    else {
                        throw PeerEnrollmentActivation.failure(
                            "Target lost its previously committed common identity.")
                    }
                    try PrivateConfiguration.write(
                        JSON.encode(expected), to: self.root.appendingPathComponent(storeName))
                }
                if let identity = try ReplicaIdentity.load(
                    root: self.root, storeID: prep.commonStoreID, ownerUID: ownerUID)
                {
                    guard identity.replicaID == prep.targetReplicaID else {
                        throw PeerEnrollmentActivation.failure("Target replica identity differs.")
                    }
                } else {
                    guard (try? FileMetadata.read(at: self.root.appendingPathComponent("items"))) == nil
                    else {
                        throw PeerEnrollmentActivation.failure(
                            "Target lost its reserved replica identity after initialization.")
                    }
                    try files.writeImmutable(
                        JSON.encode(
                            ReplicaIdentity.Record(
                                formatVersion: 1,
                                storeID: prep.commonStoreID, replicaID: prep.targetReplicaID)),
                        path: [ReplicaIdentity.name], maximumBytes: 4096)
                }
                try ensureDirectory(self.root.appendingPathComponent("items"))
                try CanonicalReaderRequirement.beforeTargetEnrollmentPublication(
                    root: self.root, ownerUID: ownerUID)
                try targetProvisioningProgress?("identitiesCommitted")
            }
            try ensureDirectory(self.root.appendingPathComponent("items"))
            try rejectIndexInsideCanonicalSubtrees()
            try ensureDirectory(indexDirectory)
            try rejectIndexInsideCanonicalSubtrees()
            if let required = try CanonicalReaderRequirement.load(root: self.root, ownerUID: ownerUID) {
                try CanonicalFormatSupport.current.require(required)
                if required.capabilities.contains(AuthorityStore.capability) {
                    guard authorityIntakeEnabled else {
                        throw TractandaError(
                            "authorityModeRequired",
                            "This store requires authority-aware eligibility enforcement; linear fallback is forbidden."
                        )
                    }
                }
            }
            if let planned = firstSourceOperation?.freshStoreID {
                _ = try canonicalStoreIdentity(
                    creatingIfMissing: true, allocate: { UUID(uuidString: planned)! })
            }
            if usesExternalIndexDirectory {
                try bindExternalIndexDirectory()
            } else {
                _ = try canonicalStoreIdentity(creatingIfMissing: true)
            }
            try targetProvisioningControl?()
            // Recover bounded upload intents/cleanup first, then rebuild shared accounting.
            let recoveryPayloads = try AttachmentPayloadStore(
                root: self.root, ownerUID: ownerUID,
                reserveBytes: attachmentUploadPolicy.minimumFreeBytes,
                availableBytes: attachmentAvailableBytes, indexDirectory: indexDirectory)
            try recoveryPayloads.preparePlacement()
            let recoveryDocuments = DocumentContentStore(
                root: self.root, ownerUID: ownerUID,
                minimumFreeBytes: attachmentUploadPolicy.minimumFreeBytes,
                availableBytes: attachmentAvailableBytes, indexDirectory: indexDirectory)
            try recoveryDocuments.preparePlacement()
            attachmentUploads = try recoveryPayloads.loadUploads()
            stagingByteQuota = try StagingByteQuota(
                root: self.root, ownerUID: ownerUID, maximumBytes: attachmentUploadPolicy.maximumStagedBytes,
                pendingUploads: attachmentUploads, payloads: recoveryPayloads, documents: recoveryDocuments)
            attachmentPayloads = try AttachmentPayloadStore(
                root: self.root, ownerUID: ownerUID, reserveBytes: attachmentUploadPolicy.minimumFreeBytes,
                availableBytes: attachmentAvailableBytes, stagingQuota: stagingByteQuota,
                indexDirectory: indexDirectory)
            documentContents = DocumentContentStore(
                root: self.root, ownerUID: ownerUID,
                minimumFreeBytes: attachmentUploadPolicy.minimumFreeBytes,
                availableBytes: attachmentAvailableBytes, stagingQuota: stagingByteQuota,
                indexDirectory: indexDirectory)
            documentJobRecords = DocumentJobRecords(
                root: self.root,
                files: DocumentContentFiles(
                    root: self.root, ownerUID: ownerUID,
                    minimumFreeBytes: attachmentUploadPolicy.minimumFreeBytes,
                    availableBytes: attachmentAvailableBytes, stagingQuota: stagingByteQuota))
            documentJobs = try documentJobRecords.load()
            if authorityIntakeEnabled {
                peerIntake = PeerIntakeCoordinator(
                    root: self.root, ownerUID: ownerUID,
                    storeID: try canonicalStoreIdentity(creatingIfMissing: false),
                    stagingQuota: stagingByteQuota)
                peerIntake?.provisioningScope = targetProvisioningScope
                try configurePeerOriginals(reserveBytes: attachmentUploadPolicy.minimumFreeBytes)
                peerIntake?.progress = { [weak self] in try self?.rebuildControl?.graphProgress() }
                openingProgress = peerIntake?.progress
                if let targetProvisioningControl {
                    let previous = openingProgress
                    peerIntake?.progress = {
                        try targetProvisioningControl()
                        try previous?()
                    }
                }
                try peerIntake?.recoverLifecycleOperations()
                if let request = firstSourceOperation {
                    try InitialAuthorityBootstrap.stageFoundingPolicy(
                        root: self.root, ownerUID: ownerUID,
                        request: request, accounts: accounts, progress: firstSourceProgress)
                }
                let initial = try AuthorityStore.initialState(
                    root: self.root, storeID: canonicalStoreIdentity(creatingIfMissing: false),
                    ownerUID: ownerUID, files: peerIntake!.journal.files,
                    allocateReplica: {
                        if let planned = firstSourceOperation?.freshReplicaID {
                            return UUID(uuidString: planned)!
                        }
                        return try UUID.makeVersion1()
                    })
                if firstSourceOperation?.foundingPolicy != nil {
                    try firstSourceProgress?("afterInitialCapture")
                }
                authorityBootstrapPending =
                    try initial.mode == .requiresBootstrap
                    && peerIntake!.configuration()?.bootstrap == nil
                if authorityBootstrapPending {
                    pendingFoundingPolicy = firstSourceOperation?.foundingPolicy?.original
                }
                authorityExistingHistoryAdmitted = !authorityBootstrapPending
            } else if FileManager.default.fileExists(
                atPath: self.root.appendingPathComponent("authority").path)
            {
                throw TractandaError(
                    "authorityModeRequired", "Retained authority controls cannot be ignored by disabled mode."
                )
            }
            // Replay must know THIS replica before reconstructing covered negative effects.
            // This validates existing private identity only; it never creates/invents one.
            replicaID = try ReplicaIdentity.load(
                root: self.root,
                storeID: canonicalStoreIdentity(creatingIfMissing: false), ownerUID: ownerUID)?.replicaID
            try targetProvisioningControl?()
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
            try targetProvisioningControl?()
            try restoreCorpusRecoveryCharges()
            try reclaimStartupCorpusReaders()
            if replicaID == nil, try index?.hasModernRevisionOrigins() == true {
                throw TractandaError(
                    "missingReplicaIdentity", "Modern history requires the retained private replica identity."
                )
            }
            if let peerIntake, let index {
                try index.initializeAuthoritySchema()
                try index.initializeAuthorityControlSchema()
                try index.initializeAuthorityReviewSchema()
                try peerIntake.loadPeerRetirements(index: index)
                try peerIntake.validatePeerRetirementCuts(index: index)
                try validateActivatedRetirements(coordinator: peerIntake, index: index)
                try validateForeignReviewSeals(coordinator: peerIntake, index: index)
                try validateSourceEnrollmentApprovals(coordinator: peerIntake, index: index)
                try peerIntake.withOperation(recovery: true) {
                    try index.withCatalogueScanBudget(reusingActiveBudget: true) {
                        _ = try activateOriginAdmissions(coordinator: peerIntake, index: index)
                        try validateOriginAdmissions(coordinator: peerIntake, index: index)
                        try validateTargetEnrollment(coordinator: peerIntake, index: index)
                        try validateSourceRegistrations(coordinator: peerIntake)
                        try reconsiderOriginObservations(coordinator: peerIntake, index: index)
                    }
                }
                try peerIntake.withOperation(recovery: true) {
                    try finishAuthorityDispositionEffects(coordinator: peerIntake, index: index)
                }
                try ensureInitialAuthorityVisibility(coordinator: peerIntake, index: index)
                try resumePendingPeerIntakes(using: peerIntake, index: index)
                try drainAuthorityVisibility(coordinator: peerIntake, index: index)
                try peerIntake.journal.originals?.cleanupApplied()
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
    private func rejectIndexInsideCanonicalSubtrees() throws {
        let canonicalDirectories = try ["items", "attachments", "documents"].compactMap {
            name -> FileMetadata? in
            do {
                return try FileMetadata.read(at: root.appendingPathComponent(name))
            } catch FileMetadataError.posix(let code) where code == ENOENT { return nil }
        }
        var ancestor = indexDirectory.resolvingSymlinksInPath()
        while ancestor.path != "/" {
            if let metadata = try? FileMetadata.read(at: ancestor),
                metadata.type == .directory,
                canonicalDirectories.contains(where: {
                    $0.device == metadata.device && $0.inode == metadata.inode
                })
            {
                throw TractandaError(
                    "invalidIndexDirectory",
                    "Index files cannot be stored inside canonical item or attachment subtrees.")
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
    private func canonicalStoreIdentity(
        creatingIfMissing: Bool,
        allocate: () throws -> UUID = UUID.makeVersion1
    ) throws -> String {
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
        // Missing canonical identity is not permission to reinterpret retained originals as a
        // new store. This also protects the initialization path before payload lookup is opened.
        for name in ["attachments/payloads", "documents", "canonical-reader.json", "authority"] {
            if (try? FileMetadata.read(at: root.appendingPathComponent(name))) != nil {
                throw TractandaError(
                    "invalidStoreIdentity", "Retained canonical data requires its original StoreID.")
            }
        }
        var populated = false
        try POSIXDirectory.withEntries(at: root.appendingPathComponent("items")) { _ in
            populated = true
            return false
        }
        guard !populated else {
            throw TractandaError("invalidStoreIdentity", "Retained items require their original StoreID.")
        }
        let identity = CanonicalStoreIdentity(
            formatVersion: 1, storeID: try allocate().uuidString.lowercased())
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
        if revisionProjectionEnabled && (accessConfigurationAmbiguous || accessConfigurationProofUnavailable)
        {
            let account = try? accounts.user(forUID: uid)
            let administrator: Bool
            if accessConfigurationProofUnavailable {
                // Deliberate host-root maintenance route; uncertainty never falls back to owner admission.
                administrator = uid == 0
            } else {
                administrator = try currentAccessConfigurations.allSatisfy { configuration in
                    if configuration.administration == .serviceOwner { return uid == ownerUID }
                    if uid == 0 { return true }
                    let group = try accounts.groupID(
                        named: configuration.administratorGroup
                            ?? AccessConfiguration.defaultAdministratorGroup)
                    return account?.groupIDs.contains(group) == true
                }
            }
            guard administrator else {
                throw TractandaError("forbidden", "Current store authority requires administrator repair.")
            }
            let previous = accessContext
            accessContext = StoreAccessContext(
                uid: uid, account: account, resolver: resolver, isAdministrator: true)
            defer { accessContext = previous }
            return try body()
        }
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
        guard !authorityBootstrapPending || administrator else {
            throw TractandaError(
                "authorityBootstrapRequired",
                "Existing history requires an explicit administrator bootstrap pin.")
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
        if revisionProjectionEnabled { return canReadProjection(head.itemID) }
        if isAdministrator { return true }
        aclSwiftReadCheckCount += 1
        guard head.classID != AccessConfiguration.classID,
            let context = accessContext, let account = context.account,
            let value = head.fields["permissions"]
        else { return false }
        return (try? ItemPermissions(value).allows(4, for: account, using: context.resolver)) == true
    }

    private func canRead(_ head: ResidentHead) -> Bool {
        if revisionProjectionEnabled { return canReadProjection(head.itemID) }
        if !isAdministrator { aclSwiftReadCheckCount += 1 }
        return head.canRead(accessContext, administrator: isAdministrator)
    }

    private func requireRead(_ head: Revision) throws {
        guard canRead(head) else { throw TractandaError("forbidden", "Item access is denied.") }
    }

    private func requireEdit(_ head: Revision, changesPermissions: Bool = false) throws {
        if revisionProjectionEnabled {
            try requireProjectionEdit(head.itemID, changesPermissions: changesPermissions)
            return
        }
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

    private func refreshCurrentAccessConfigurations(using index: ItemIndex) throws {
        var configurations: [AccessConfiguration] = []
        var unavailable = false
        var cursor: String?
        var inspected = 0
        let digest = try ItemIndex.graphValueDigest(.text(AccessConfiguration.classID))
        try index.withCatalogueScanBudget(reusingActiveBudget: true) {
            while true {
                let condition = cursor == nil ? "" : " AND r.item>?"
                let statement = try index.corpusPrepare(
                    "SELECT r.item FROM revision_catalog r WHERE EXISTS(SELECT 1 FROM revision_field_values v WHERE v.revision=r.revision AND v.field='classID' AND v.digest=?)\(condition) ORDER BY r.item LIMIT 1",
                    [digest] + (cursor.map { [$0] } ?? []))
                let status = index.catalogueStep(statement)
                if status == SQLITE_DONE {
                    sqlite3_finalize(statement)
                    break
                }
                guard status == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
                    sqlite3_finalize(statement)
                    throw TractandaError("indexError", "Current access policy catalogue is unavailable.")
                }
                let id = String(cString: raw)
                sqlite3_finalize(statement)
                cursor = id
                inspected += 1
                guard inspected <= 64 else {
                    throw TractandaError(
                        "resourceLimit", "Current access configuration set exceeds its window.")
                }
                guard let projection = try index.currentProjection(itemID: id), projection.policiesComplete
                else {
                    unavailable = true
                    continue
                }
                for witness in try index.currentPolicyWitnesses(itemID: id) {
                    guard witness.classID == AccessConfiguration.classID,
                        let row = try index.revision(witness.revisionID)
                    else {
                        unavailable = true
                        continue
                    }
                    let record = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: ownerUID)
                        .revision
                    guard let value = record.fields["accessConfiguration"] else {
                        unavailable = true
                        continue
                    }
                    let candidate = try AccessConfiguration(value)
                    let same = configurations.contains { existing in
                        Set(existing.users) == Set(candidate.users)
                            && Set(existing.groups) == Set(candidate.groups)
                            && existing.userAliases == candidate.userAliases
                            && existing.groupAliases == candidate.groupAliases
                            && existing.administration == candidate.administration
                            && existing.administratorGroup == candidate.administratorGroup
                            && existing.legacyUsers == candidate.legacyUsers
                    }
                    if !same { configurations.append(candidate) }
                }
            }
        }
        currentAccessConfigurations = configurations
        accessConfigurationProofUnavailable = unavailable
        // A single effective configuration is safe; divergence never selects one for ordinary serving.
        if configurations.count == 1 {
            accessConfiguration = configurations[0]
        } else if configurations.isEmpty {
            accessConfiguration = nil
        }
    }

    private func nextProjectionStateToken() -> String {
        Data(SHA256.hash(data: Data(Identifier.make().utf8))).map { String(format: "%02x", $0) }.joined()
    }

    private func readyProjectionState(_ revision: Revision) -> ItemState {
        ItemState(
            itemID: revision.itemID, stateToken: nextProjectionStateToken(), status: .ready,
            representativeRevisionID: revision.revisionID, frontier: [revision.revisionID],
            conflictingFields: [], protectedFields: [], detailsComplete: true)
    }

    private func projectionState(
        for snapshot: RevisionProjection.Snapshot,
        representativeID: String? = nil, status: ItemState.Status? = nil,
        resource: ItemStateResource? = nil
    ) throws -> ItemState {
        let selected = status ?? (snapshot.analysis.isResolved ? .ready : .conflicted)
        let token = nextProjectionStateToken()
        let result = ItemState(
            itemID: snapshot.itemID, stateToken: token, status: selected,
            representativeRevisionID: representativeID ?? snapshot.representative?.revisionID,
            frontier: snapshot.analysis.frontier,
            conflictingFields: snapshot.analysis.conflicts.keys.sorted(),
            protectedFields: snapshot.analysis.protectedFields.sorted(), detailsComplete: true,
            resource: resource)
        if try JSON.encode(result).count <= 384 * 1024 { return result }
        return ItemState(
            itemID: snapshot.itemID, stateToken: token, status: selected,
            representativeRevisionID: result.representativeRevisionID,
            detailsComplete: false,
            resource: resource
                ?? ItemStateResource(
                    code: "resourceLimit",
                    phase: .analysis, message: "Current state details exceed the response window.",
                    maximumBytes: 384 * 1024))
    }

    private func publishAutomaticProjection(
        _ plan: RevisionProjection.Plan,
        snapshot: RevisionProjection.Snapshot, policies: [RevisionProjection.PolicyWitness],
        using index: ItemIndex
    ) throws -> Revision {
        combinationPublicationAwaitingIndex = false
        guard writer >= 0, isAdministrator, tractanda_path_read_only(root.path) == 0 else {
            throw TractandaError("forbidden", "Canonical maintenance needs writable store authority.")
        }
        let draft = try RevisionProjection.draft(
            plan, itemID: snapshot.itemID,
            allocate: { try self.makePersistentUUID() },
            isAvailable: {
                try index.revision($0) == nil && index.revisionCount(itemID: $0) == 0
            })
        let identity = try ReplicaIdentity.initialize(
            root: root,
            storeID: canonicalStoreIdentity(creatingIfMissing: false), ownerUID: ownerUID,
            hasModernOrigins: index.hasModernRevisionOrigins())
        replicaID = identity.replicaID
        guard let parent = try index.revision(draft.parents[0]) else {
            throw TractandaError("invalidRevisionGraph", "Materialization parent is unavailable.")
        }
        let provenance = try RevisionProvenance(
            kind: .automaticMerge, originReplicaID: identity.replicaID,
            parents: draft.parents, writtenFields: [], unsetFields: [], frontier: draft.frontier,
            mergeProfile: draft.profile)
        var fields = draft.fields
        fields["itemID"] = .text(draft.itemID)
        fields["revisionID"] = .text(draft.revisionID)
        fields["createdAt"] = .date(parent.createdAt)
        fields["modifiedAt"] = .date(draft.modifiedAt)
        fields["actor"] = .text("replica:" + identity.replicaID)
        fields["operationID"] = .text(draft.revisionID)
        fields["requestIdentity"] = .text(try JSON.encode(provenance.itemValue).base64EncodedString())
        fields["revisionAncestry"] = provenance.itemValue
        let revision = try Revision(fields: fields, formatVersion: 2)
        try ItemSemantics.validate(revision)
        return try publishVerifiedCombination(revision, snapshot: snapshot, policies: policies, using: index)
    }

    private func publishVerifiedCombination(
        _ revision: Revision, snapshot: RevisionProjection.Snapshot,
        policies: [RevisionProjection.PolicyWitness], using index: ItemIndex,
        authorityControls: [AuthorityRecord] = []
    ) throws -> Revision {
        try requireActivePublishingOrigin()
        combinationPublicationAwaitingIndex = false
        guard try index.acceptedGraphProofIsCurrent() else {
            throw TractandaError(
                "projectionRequired", "Accepted graph proof must be rebuilt before publication.")
        }
        let fields = revision.fields
        let data = try RecordCodec.encode(revision)
        guard data.count <= min(8 * 1024 * 1024, canonicalRecordByteLimitForTesting),
            try JSON.encode(fields.filter { ItemIndex.headSummaryFieldNames.contains($0.key) }).count <= 2
                * 1024 * 1024
        else {
            throw TractandaError("resourceLimit", "Complete materialization record exceeds its byte window.")
        }
        let utc = try RevisionTimestamp(Timestamp.now()).formatted()
        let stamp = Array(utc.utf8)
        func part(_ range: Range<Int>) -> String { String(decoding: stamp[range], as: UTF8.self) }
        let folder = root.appendingPathComponent(
            "items/" + part(0..<4) + "/" + part(5..<7) + "/"
                + part(8..<10) + "/" + part(11..<13) + "/" + part(14..<16) + "/" + revision.itemID)
        try ensureDirectory(folder)
        let file = folder.appendingPathComponent(revision.revisionID + ".tractanda")
        let localAuthorityPackage = try sealLocalAuthority(
            revision, data: data, path: file.path, index: index, additionalControls: authorityControls,
            onSealed: { self.combinationPublicationAwaitingIndex = true })
        try CanonicalReaderRequirement.beforePublication(
            root: root, ownerUID: ownerUID, format: revision.formatVersion,
            beforePersist: beforeCanonicalReaderRequirementForTesting)
        try StoreCheckpoint.markDirty(root: root)
        let published = data.withUnsafeBytes { tractanda_publish(file.path, $0.baseAddress, $0.count) }
        guard published >= 0 else {
            throw TractandaError("writeFailed", "Materialization publication failed.")
        }
        combinationPublicationAwaitingIndex = true
        var completed = false
        defer { if !completed { quarantineCheckpoint() } }
        var directory = folder
        while directory.path.hasPrefix(root.path + "/") || directory == root {
            let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw TractandaError("writeFailed", "Cannot synchronize materialization directories.")
            }
            let synchronized = fsync(descriptor)
            close(descriptor)
            guard synchronized == 0 else {
                throw TractandaError("writeFailed", "Cannot synchronize materialization directories.")
            }
            directory.deleteLastPathComponent()
        }
        let metadata = try FileMetadata.read(at: file)
        let row = ItemIndex.CatalogueRow(
            revisionID: revision.revisionID, itemID: revision.itemID,
            path: String(file.path.dropFirst(root.path.count + 1)), parentID: nil,
            actor: fields["actor"]!.string!, operationID: fields["operationID"]!.string!, size: metadata.size,
            inode: metadata.inode, uid: metadata.uid, mode: metadata.mode,
            modificationSeconds: metadata.modificationSeconds,
            modificationNanoseconds: metadata.modificationNanoseconds,
            digest: Data(SHA256.hash(data: data)), createdAt: revision.fields["createdAt"]!.dateString!,
            feedbackRevisionIDs: fields["learningFeedback"]?.map?.values.compactMap {
                try? LearningFeedback($0).revisionID
            } ?? [], modifiedAt: revision.modifiedAt, provenance: try revision.provenance)
        let state =
            try revision.provenance?.kind == .resolution
            ? readyProjectionState(revision)
            : projectionState(for: snapshot, representativeID: revision.revisionID, status: .ready)
        try beforeCombinationIndexUpdateForTesting?()
        try finishLocalAuthority(localAuthorityPackage, index: index)
        let input = try PageCorpusInput(
            storeID: canonicalStoreIdentity(creatingIfMissing: false), revision: revision)
        let provider = StoredPageCorpusProvider(contents: documentContents, incoming: nil)
        try index.installCorpusForRebuild(
            input: input, provider: provider,
            boundary: {
                try self.rebuildControl?.graphProgress()
                try self.requireIndexFilesystemCapacity(additionalBytes: 0)
            })
        try index.appendValidatedLocal(
            row: row, revision: revision, parent: nil,
            expectedRepresentativeID: snapshot.representative?.revisionID, state: state,
            policies: policies, corpus: nil, snapshot: snapshot)
        completed = true
        combinationPublicationAwaitingIndex = false
        generation = Identifier.make()
        return revision
    }

    private var projectionPolicyByteWindow: UInt64 {
        min(64 * 1024 * 1024, max(1, revisionProjectionLimits.maximumHydratedBytes / 8))
    }

    private func prepareRecoveredProjection(
        _ itemID: String, using index: ItemIndex,
        deferCategory: Bool = false, verifiedSnapshot: RevisionProjection.Snapshot? = nil,
        deferMaterialization: Bool = false
    ) throws -> (revision: Revision?, categoryParents: Set<String>?, activeCategory: Bool) {
        let snapshot: RevisionProjection.Snapshot
        do {
            if let verifiedSnapshot {
                guard verifiedSnapshot.itemID == itemID else {
                    throw TractandaError(
                        "invalidRevisionGraph", "Verified projection belongs to another item.")
                }
                snapshot = verifiedSnapshot
            } else {
                var limits = revisionProjectionLimits
                limits.maximumHydratedBytes = max(
                    1,
                    limits.maximumHydratedBytes
                        - min(limits.maximumHydratedBytes, projectionPolicyByteWindow * 2)
                )
                snapshot = try analyzeCurrentProjection(
                    itemID, using: index, limits: limits,
                    progress: { try self.rebuildControl?.graphProgress() })
            }
        } catch let error as TractandaError where error.code == "resourceLimit" {
            let state = ItemState(
                itemID: itemID, stateToken: nextProjectionStateToken(), status: .unmaterializable,
                detailsComplete: false,
                resource: .init(
                    code: "resourceLimit", phase: .analysis,
                    message: "Current projection exceeds its resource window."))
            try index.replaceCurrentProjection(
                snapshot: nil, state: state, policies: [], policiesComplete: false)
            return (nil, nil, false)
        }
        let policies: [RevisionProjection.PolicyWitness]
        do { policies = try projectionPolicies(snapshot, using: index) } catch let error as TractandaError
            where error.code == "resourceLimit"
        {
            let state = try projectionState(
                for: snapshot, status: .unmaterializable,
                resource: .init(
                    code: "resourceLimit", phase: .analysis,
                    message: "Current policy proof exceeds its resource window."))
            try index.replaceCurrentProjection(
                snapshot: snapshot, state: state, policies: [], policiesComplete: false)
            return (nil, nil, false)
        }
        var parents: Set<String> = []
        var category = false
        var active = false
        var categoryBytes: UInt64 = 0
        for id in snapshot.analysis.frontier {
            guard let row = try index.revision(id) else {
                throw TractandaError("invalidRevisionGraph", "Current frontier is missing.")
            }
            guard row.size <= projectionPolicyByteWindow - categoryBytes else {
                throw TractandaError("resourceLimit", "Category witness hydration exceeds its window.")
            }
            categoryBytes += row.size
            let value = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: ownerUID).revision
            if value.fields["selection"] != nil || value.fields["categoryParents"] != nil {
                category = true
                if !value.isDeleted, value.fields["selection"] != nil {
                    active = true
                    parents.formUnion(try CategoryHierarchy.parents(of: value))
                }
            }
        }
        if deferCategory && category {
            let status: ItemState.Status = snapshot.analysis.isResolved ? .unmaterializable : .conflicted
            let state = try projectionState(
                for: snapshot, status: status,
                resource: snapshot.analysis.isResolved
                    ? .init(
                        code: "projectionPending", phase: .analysis,
                        message: "Current category invariants are being checked.") : nil)
            try index.replaceCurrentProjection(
                snapshot: snapshot, state: state, policies: policies, policiesComplete: true)
            return (nil, parents, active)
        }
        let plan = try RevisionProjection.plan(
            snapshot, maximumPayloadBytes: canonicalRecordByteLimitForTesting,
            now: publicationClockForTesting)
        let revision: Revision?
        switch plan {
        case .conflicted:
            let state = try projectionState(for: snapshot, status: .conflicted)
            try index.replaceCurrentProjection(
                snapshot: snapshot, state: state, policies: policies, policiesComplete: true)
            return (nil, category ? parents : nil, active)
        case .blocked:
            let state = try projectionState(
                for: snapshot, status: .unmaterializable,
                resource: .init(
                    code: "resourceLimit", phase: .publication,
                    message: "Current merge cannot fit the canonical publication window.",
                    maximumBytes: canonicalRecordByteLimitForTesting))
            try index.replaceCurrentProjection(
                snapshot: snapshot, state: state, policies: policies, policiesComplete: true)
            return (nil, category ? parents : nil, active)
        case .ready(let plan):
            if deferMaterialization {
                let state = try projectionState(
                    for: snapshot, status: .reviewRequired,
                    resource: .init(
                        code: "authorityCatchupPending", phase: .analysis,
                        message: "Current authority effects are being reconciled."))
                try index.replaceCurrentProjection(
                    snapshot: snapshot, state: state, policies: policies, policiesComplete: true)
                return (nil, category ? parents : nil, active)
            }
            do {
                revision = try publishAutomaticProjection(
                    plan, snapshot: snapshot, policies: policies, using: index)
            } catch let error as TractandaError
                where error.code == "resourceLimit" && !combinationPublicationAwaitingIndex
            {
                let state = try projectionState(
                    for: snapshot, status: .unmaterializable,
                    resource: .init(
                        code: "resourceLimit", phase: .publication,
                        message: "Complete merge record exceeds its publication window.",
                        maximumBytes: canonicalRecordByteLimitForTesting))
                try index.replaceCurrentProjection(
                    snapshot: snapshot, state: state, policies: policies, policiesComplete: true)
                return (nil, category ? parents : nil, active)
            }
        case .unchanged:
            guard let id = snapshot.representative?.revisionID, let row = try index.revision(id) else {
                throw TractandaError("invalidRevisionGraph", "Resolved current representative is missing.")
            }
            revision = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: ownerUID).revision
            let state = try projectionState(for: snapshot)
            try index.replaceCurrentProjection(
                snapshot: snapshot, state: state, policies: policies, policiesComplete: true)
        }
        return (revision, category ? parents : nil, active)
    }

    private func analyzeCurrentProjection(
        _ itemID: String, using index: ItemIndex,
        limits: RevisionProjection.Limits, progress: (() throws -> Void)? = nil
    ) throws -> RevisionProjection.Snapshot {
        try index.withCatalogueScanBudget(progress: progress, reusingActiveBudget: true) {
            try index.withAuthorityPeerWorkAllowance(maximum: limits.maximumVMInstructions) {
                try index.analyzeRevisionProjection(
                    itemID: itemID,
                    loadVerified: { row in
                        try PooledCanonicalRecord.read(row: row, root: self.root, ownerUID: self.ownerUID)
                    }, limits: limits, progress: progress, reusingActiveBudget: true)
            }
        }
    }

    private func projectionPolicies(_ snapshot: RevisionProjection.Snapshot, using index: ItemIndex) throws
        -> [RevisionProjection.PolicyWitness]
    {
        var bytes: UInt64 = 0
        var encoded = 0
        var output: [RevisionProjection.PolicyWitness] = []
        for id in snapshot.analysis.frontier {
            guard let row = try index.revision(itemID: snapshot.itemID, revisionID: id),
                row.size <= projectionPolicyByteWindow - bytes
            else {
                throw TractandaError("resourceLimit", "Policy witness hydration exceeds its window.")
            }
            bytes += row.size
            let record = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: ownerUID)
            let value = record.revision.fields["permissions"]
            if let value { _ = try ItemPermissions(value) }
            let count = try value.map { try JSON.encode($0).count } ?? 0
            guard count + 256 <= 8 * 1024 * 1024 - encoded else {
                throw TractandaError("resourceLimit", "Policy summaries exceed their window.")
            }
            encoded += count + 256
            output.append(.init(revisionID: id, classID: record.revision.classID, permissions: value))
        }
        return output
    }

    private func canReadProjection(_ itemID: String) -> Bool {
        if isAdministrator { return true }
        guard let index, let projection = try? index.currentProjection(itemID: itemID),
            projection.policiesComplete, let context = accessContext, let account = context.account,
            let policies = try? index.currentPolicyWitnesses(itemID: itemID), !policies.isEmpty
        else { return false }
        return policies.allSatisfy { policy in
            guard policy.classID != AccessConfiguration.classID, let value = policy.permissions else {
                return false
            }
            return (try? ItemPermissions(value).allows(4, for: account, using: context.resolver)) == true
        }
    }

    private func requireProjectionEdit(_ itemID: String, changesPermissions: Bool) throws {
        guard let index, let projection = try index.currentProjection(itemID: itemID),
            projection.state.status == .ready
        else { throw TractandaError("itemUnresolved", "Current item projection is unresolved.") }
        try requireProjectionAuthority(itemID, changesPermissions: changesPermissions)
    }

    private func requireProjectionAuthority(_ itemID: String, changesPermissions: Bool) throws {
        if isAdministrator { return }
        guard let index, let projection = try index.currentProjection(itemID: itemID),
            projection.policiesComplete, let context = accessContext, let account = context.account
        else {
            throw TractandaError("forbidden", "Item editing is denied.")
        }
        let policies = try index.currentPolicyWitnesses(itemID: itemID)
        guard !policies.isEmpty else { throw TractandaError("forbidden", "Item policy is unavailable.") }
        for policy in policies {
            guard policy.classID != AccessConfiguration.classID, let value = policy.permissions else {
                throw TractandaError("forbidden", "Item editing is denied.")
            }
            let permission = try ItemPermissions(value)
            guard try permission.allows(6, for: account, using: context.resolver),
                try !changesPermissions || context.resolver.userID(permission.owner) == account.uid
            else {
                throw TractandaError("forbidden", "All current policies must authorize this edit.")
            }
        }
    }

    func queryProjectionCompleteness() throws -> (completeness: String, conflictsAvailable: Bool) {
        guard revisionProjectionEnabled else { return ("complete", false) }
        guard let index, isCanonicalReady else {
            throw TractandaError("recoveryRequired", "Current projection is unavailable.")
        }
        let present: Bool
        if isAdministrator {
            present = try !index.unresolvedProjectionPage(limit: 1).isEmpty
        } else if let authority = try pooledReadAuthority() {
            try index.setRequestPrincipals(
                actorUID: authority.principals.actorUID,
                users: authority.principals.users,
                groups: authority.principals.groups.mapValues { (id: $0.gid, member: $0.member) })
            defer { try? index.clearRequestPrincipals() }
            present = try index.hasReadableUnresolvedProjection(aclUserID: authority.principals.actorUID)
        } else {
            // A bounded exact fallback cannot silently omit readable conflict status.
            present = try !readableUnresolvedStates(limit: 1).isEmpty
        }
        return (present ? "unresolvedItems" : "complete", present)
    }

    func readableUnresolvedStates(after: String? = nil, limit: Int = 128) throws -> [ItemState] {
        guard revisionProjectionEnabled, isCanonicalReady, let index,
            (1...256).contains(limit)
        else {
            throw TractandaError("unsupportedFeature", "Revision projection is not enabled.")
        }
        if let after { try Identifier.validate(after) }
        var cursor = after
        var output: [ItemState] = []
        var inspected = 0
        var bytes = 0
        while output.count < limit {
            let page = try index.unresolvedProjectionPage(after: cursor, limit: min(128, limit))
            guard !page.isEmpty else { break }
            for projection in page {
                inspected += 1
                guard inspected <= 10_000 else {
                    throw TractandaError("resourceLimit", "Readable conflict scan exceeds its window.")
                }
                cursor = projection.state.itemID
                if canReadProjection(projection.state.itemID) {
                    let count = try JSON.encode(projection.state).count
                    guard count <= pooledRecordByteLimit - bytes else {
                        throw TractandaError("resourceLimit", "Conflict summaries exceed their byte window.")
                    }
                    bytes += count
                    output.append(projection.state)
                    if output.count == limit { break }
                }
            }
        }
        return output
    }

    private func knownCategoryConstraintConflicts(replacing replacement: Revision? = nil) throws -> Set<
        String
    > {
        guard let index else {
            throw TractandaError("indexUnavailable", "Category constraint catalogue is unavailable.")
        }
        var edges: [String: Set<String>] = [:]
        var active: Set<String> = []
        var cursor: String?
        var bytes: UInt64 = 0
        try index.withCatalogueScanBudget(reusingActiveBudget: true) {
            while true {
                let condition = cursor == nil ? "" : " AND r.item>?"
                let statement = try index.corpusPrepare(
                    "SELECT r.item FROM revision_catalog r WHERE EXISTS(SELECT 1 FROM revision_field_values v WHERE v.revision=r.revision AND v.field IN('selection','categoryParents'))\(condition) ORDER BY r.item LIMIT 1",
                    cursor.map { [$0] } ?? [])
                let status = index.catalogueStep(statement)
                if status == SQLITE_DONE {
                    sqlite3_finalize(statement)
                    break
                }
                guard status == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
                    sqlite3_finalize(statement)
                    throw TractandaError("indexError", "Category constraint lookup failed.")
                }
                let id = String(cString: raw)
                sqlite3_finalize(statement)
                cursor = id
                if id == replacement?.itemID { continue }
                guard edges.count < Self.categoryWorkingSetLimit,
                    let projection = try index.currentProjection(itemID: id), projection.policiesComplete
                else {
                    throw TractandaError("resourceLimit", "Known category constraints are incomplete.")
                }
                var parents: Set<String> = []
                for witness in try index.currentPolicyWitnesses(itemID: id) {
                    guard let row = try index.revision(witness.revisionID),
                        row.size <= projectionPolicyByteWindow - bytes
                    else {
                        throw TractandaError(
                            "resourceLimit", "Category constraint witnesses exceed their window.")
                    }
                    bytes += row.size
                    let record = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: ownerUID)
                        .revision
                    if !record.isDeleted, record.fields["selection"] != nil {
                        active.insert(id)
                        parents.formUnion(try CategoryHierarchy.parents(of: record))
                    }
                }
                edges[id] = parents
            }
        }
        if let replacement {
            edges[replacement.itemID] = Set(try CategoryHierarchy.parents(of: replacement))
            if !replacement.isDeleted, replacement.fields["selection"] != nil {
                active.insert(replacement.itemID)
            }
        }
        var remaining = active
        var depths: [String: Int] = [:]
        var invalid: Set<String> = []
        while !remaining.isEmpty {
            let ready = remaining.filter {
                (edges[$0] ?? []).intersection(active).isDisjoint(with: remaining)
            }
            if ready.isEmpty {
                invalid.formUnion(remaining)
                break
            }
            for id in ready {
                let parents = (edges[id] ?? []).intersection(active)
                let depth = 1 + (parents.compactMap { depths[$0] }.max() ?? 0)
                depths[id] = depth
                if depth > 32 || !parents.isDisjoint(with: invalid) { invalid.insert(id) }
                remaining.remove(id)
            }
        }
        return invalid
    }

    public func resolveConflict(_ request: ResolveConflictRequest, actorUID: UInt32? = nil) throws
        -> CommitResult
    {
        if accessContext == nil {
            return try withAccess(forUID: actorUID ?? ownerUID) {
                try resolveConflict(request, actorUID: actorUID)
            }
        }
        guard revisionProjectionEnabled, isCanonicalReady, let index, let context = accessContext else {
            throw TractandaError("unsupportedFeature", "Revision projection is not enabled.")
        }
        let uid = actorUID ?? context.uid
        guard uid == context.uid, !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
            !request.operationID.contains("\0")
        else {
            throw TractandaError("invalidArguments", "Invalid authenticated resolution operation.")
        }
        let identity = try JSON.encode(request).base64EncodedString()
        if let prior = try priorOperation(request.operationID, uid: uid, kind: .resolution) {
            guard prior.fields["requestIdentity"]?.string == identity else {
                throw TractandaError(
                    "operationMismatch", "This resolution operation already has another intent.")
            }
            return CommitResult(
                revision: prior, wasReplayed: true, isIndexReady: true, warnings: [],
                itemState: try itemState(request.itemID))
        }
        let state = try itemState(request.itemID)
        guard state.stateToken == request.expectedStateToken else {
            throw TractandaError("stateConflict", "Reviewed current state changed.")
        }
        guard state.status == .conflicted || state.status == .invariantConflict else {
            throw TractandaError(
                "itemUnresolved", "This state cannot be resolved by ordinary conflict resolution.")
        }
        let forbidden = RevisionMerge.managedFields
        guard Set(request.changes.keys).isDisjoint(with: request.unset),
            Set(request.changes.keys).union(request.unset).isDisjoint(with: forbidden),
            !request.reviewedFrontier.isEmpty,
            request.reviewedFrontier == Array(Set(request.reviewedFrontier)).sorted()
        else {
            throw TractandaError(
                "invalidArguments", "Supply exact frontier and explicit ordinary/protected choices.")
        }
        try requireProjectionAuthority(
            request.itemID,
            changesPermissions: request.changes["permissions"] != nil || request.unset.contains("permissions")
        )
        let snapshot = try index.analyzeRevisionProjection(
            itemID: request.itemID,
            loadVerified: {
                try PooledCanonicalRecord.read(row: $0, root: self.root, ownerUID: self.ownerUID)
            },
            limits: revisionProjectionLimits)
        let required = Set(snapshot.analysis.conflicts.keys).union(snapshot.analysis.protectedFields)
            .union(state.status == .invariantConflict ? ["categoryParents"] : [])
        guard request.reviewedFrontier == snapshot.analysis.frontier,
            required.isSubset(of: Set(request.changes.keys).union(request.unset))
        else {
            throw TractandaError(
                "stateConflict", "Resolution must consume every reviewed conflict and protected choice.")
        }
        let parents = Array(Set(snapshot.physicalHeads + [snapshot.clockFloor.revisionID])).sorted()
        guard let source = try index.revision(parents[0]) else {
            throw TractandaError("invalidRevisionGraph", "Resolution parent is unavailable.")
        }
        var fields = snapshot.analysis.fields
        for (key, value) in request.changes { fields[key] = value }
        for key in request.unset { fields.removeValue(forKey: key) }
        let currentPolicies = try index.currentPolicyWitnesses(itemID: request.itemID)
        if currentPolicies.contains(where: { $0.classID == AccessConfiguration.classID }) {
            guard fields["classID"]?.string == AccessConfiguration.classID else {
                throw TractandaError("invalidAccessConfiguration", "Access configuration cannot be retyped.")
            }
        }
        if fields["classID"]?.string == AccessConfiguration.classID {
            try requireAdministrator()
            guard currentPolicies.contains(where: { $0.classID == AccessConfiguration.classID }) else {
                throw TractandaError(
                    "invalidAccessConfiguration",
                    "Conflict resolution cannot retype another item into an access configuration.")
            }
        }
        let local = try ReplicaIdentity.initialize(
            root: root,
            storeID: canonicalStoreIdentity(creatingIfMissing: false), ownerUID: ownerUID,
            hasModernOrigins: index.hasModernRevisionOrigins())
        replicaID = local.replicaID
        let id = try makePersistentUUID().uuidString.lowercased()
        guard try index.revision(id) == nil, try index.revisionCount(itemID: id) == 0, id != request.itemID
        else {
            throw TractandaError("identifierCollision", "Resolution allocation repeated an identity.")
        }
        let provenance = try RevisionProvenance(
            kind: .resolution, originReplicaID: local.replicaID,
            parents: parents, writtenFields: request.changes.keys.sorted(),
            unsetFields: request.unset.sorted(),
            frontier: request.reviewedFrontier)
        fields["itemID"] = .text(request.itemID)
        fields["revisionID"] = .text(id)
        fields["createdAt"] = .date(source.createdAt)
        fields["modifiedAt"] = .date(
            try RevisionPublicationClock.after(
                [snapshot.clockFloor.modifiedAt], now: publicationClockForTesting))
        fields["actor"] = .text(context.account.map { "user:" + $0.name } ?? "uid:" + String(uid))
        fields["operationID"] = .text(request.operationID)
        fields["requestIdentity"] = .text(identity)
        fields["revisionAncestry"] = provenance.itemValue
        let revision = try Revision(fields: fields, formatVersion: 2)
        try ItemSemantics.validate(revision)
        if revision.fields["selection"] != nil || revision.fields["categoryParents"] != nil
            || state.status == .invariantConflict
        {
            guard try !knownCategoryConstraintConflicts(replacing: revision).contains(revision.itemID) else {
                throw TractandaError(
                    "categoryCycle", "Resolution must repair this item's category constraints.")
            }
        }
        try beforeProjectionCommitAuthorityForTesting?()
        try withAccess(forUID: uid) {
            guard try itemState(request.itemID).stateToken == request.expectedStateToken,
                accessContext?.account?.name == context.account?.name
            else {
                throw TractandaError(
                    "stateConflict", "Current reviewed authority/state changed before publication.")
            }
            try requireProjectionAuthority(
                request.itemID,
                changesPermissions: request.changes["permissions"] != nil
                    || request.unset.contains("permissions"))
            if revision.classID == AccessConfiguration.classID {
                try requireAdministrator()
                let configuration = try AccessConfiguration(revision.fields["accessConfiguration"]!)
                try configuration.validate(
                    using: PrincipalResolver(directory: accounts, configuration: configuration))
            }
            if let value = revision.fields["permissions"], let fresh = accessContext {
                let permission = try ItemPermissions(value)
                try permission.validate(using: fresh.resolver)
                if !isAdministrator, let account = fresh.account {
                    guard try permission.allows(4, for: account, using: fresh.resolver) else {
                        throw TractandaError(
                            "invalidPermissions", "Resolution must remain readable to its editor.")
                    }
                }
            }
            for holding in try RoleSemantics.holdings(revision) {
                let holder = try get(holding.holder.itemID, revisionID: holding.holder.revisionID)
                guard ItemTypes.ancestry(holder.classID).contains("PersonItem"), holder.classID != "RoleItem",
                    !holder.isDeleted
                else {
                    throw TractandaError("invalidHolder", "Resolution holder is not an available person.")
                }
            }
            try validateResolutionReferences(revision, snapshot: snapshot, using: index)
        }
        let policies: [RevisionProjection.PolicyWitness] = [
            .init(
                revisionID: id, classID: revision.classID,
                permissions: revision.fields["permissions"])
        ]
        _ = try publishVerifiedCombination(revision, snapshot: snapshot, policies: policies, using: index)
        try rememberHead(Self.residentHead(revision))
        if revision.fields["selection"] != nil || state.status == .invariantConflict {
            try refreshRepairedCategoryProjections(using: index)
        }
        if revision.classID == AccessConfiguration.classID {
            try refreshCurrentAccessConfigurations(using: index)
        }
        accessPolicyEpoch &+= 1
        visibleStates.removeAll()
        visibleStateOrder.removeAll()
        hasLivePersonalStateMemo = nil
        clearSavedViewPages()
        generation = Identifier.make()
        return CommitResult(
            revision: revision, wasReplayed: false, isIndexReady: true, warnings: [],
            itemState: try itemState(request.itemID))
    }

    private func refreshRepairedCategoryProjections(using index: ItemIndex) throws {
        let invalid = try knownCategoryConstraintConflicts()
        var cursor: String?
        var repaired = 0
        while true {
            let page = try index.unresolvedProjectionPage(after: cursor, limit: 128)
            guard !page.isEmpty else { break }
            for current in page {
                cursor = current.state.itemID
                guard current.state.status == .invariantConflict,
                    !invalid.contains(current.state.itemID)
                else { continue }
                repaired += 1
                guard repaired <= Self.categoryWorkingSetLimit else {
                    throw TractandaError("resourceLimit", "Category reconciliation exceeds its working set.")
                }
                if let value = try prepareRecoveredProjection(current.state.itemID, using: index).revision {
                    try index.put(value)
                    try rememberHead(Self.residentHead(value))
                }
            }
        }
    }

    /// Resolution may select an intact retained attachment state; lifecycle/extraction APIs remain
    /// the only routes for creating new attachment identities or generated document representations.
    private func validateResolutionReferences(
        _ revision: Revision, snapshot: RevisionProjection.Snapshot, using index: ItemIndex
    ) throws {
        let chosenParents = try CategoryHierarchy.parents(of: revision)
        if !chosenParents.isEmpty {
            var retainedParents: Set<String> = []
            var bytes: UInt64 = 0
            for id in snapshot.analysis.frontier {
                guard let row = try index.revision(id), row.size <= projectionPolicyByteWindow - bytes else {
                    throw TractandaError(
                        "resourceLimit", "Resolution category witnesses exceed their window.")
                }
                bytes += row.size
                let parent = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: ownerUID).revision
                retainedParents.formUnion(try CategoryHierarchy.parents(of: parent))
            }
            for id in chosenParents where !retainedParents.contains(id) { _ = try Categories.rule(get(id)) }
        }
        let attachmentFields = ["attachments", "attachmentText", "attachmentDocument"]
        if attachmentFields.contains(where: { revision.fields[$0] != nil }) {
            var bytes: UInt64 = 0
            var retained = false
            for id in snapshot.analysis.frontier {
                guard let row = try index.revision(id), row.size <= projectionPolicyByteWindow - bytes else {
                    throw TractandaError(
                        "resourceLimit", "Resolution attachment witnesses exceed their window.")
                }
                bytes += row.size
                let parent = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: ownerUID).revision
                if attachmentFields.allSatisfy({ parent.fields[$0] == revision.fields[$0] }) {
                    retained = true
                    break
                }
            }
            guard retained else {
                throw TractandaError(
                    "invalidAttachment",
                    "Select one intact retained attachment state before using lifecycle operations.")
            }
            for descriptor in try AttachmentDescriptor.descriptors(in: revision.fields) {
                try attachmentPayloads.validate(descriptor: descriptor)
            }
        }
        if revision.classID == "PersonalStateItem", let target = revision.fields["target"]?.link,
            let owner = revision.fields["permissions"]?.map?["owner"]?.string, let context = accessContext
        {
            _ = try get(target.itemID, revisionID: target.revisionID)
            let uid = try context.resolver.userID(owner)
            try forEachCurrentHead(classID: "PersonalStateItem") { other in
                if other.itemID != revision.itemID, !other.isDeleted,
                    other.fields["target"]?.link?.itemID == target.itemID,
                    let otherOwner = other.fields["permissions"]?.map?["owner"]?.string,
                    try context.resolver.userID(otherOwner) == uid
                {
                    throw TractandaError(
                        "invalidPersonalState", "This owner already has an overlay for that item.")
                }
            }
        }
        for value in revision.fields["learningFeedback"]?.map?.values ?? [:].values {
            let target = try LearningFeedback(value).revisionID
            var earlier = false
            for parent in snapshot.physicalHeads {
                if target == parent {
                    earlier = true
                    break
                }
                let ancestor = try index.withCatalogueScanBudget {
                    try index.graphHasProperAncestor(source: parent, target: target, progress: nil)
                }
                if ancestor {
                    earlier = true
                    break
                }
            }
            guard earlier else {
                throw TractandaError(
                    "invalidLearningFeedback", "Feedback must name a causal input of the resolution.")
            }
        }
        for field in ["categoryOverrides", "personalOverrides"] {
            for id in revision.fields[field]?.map?.keys ?? [:].keys { if isMultiUser { _ = try get(id) } }
        }
    }

    public func itemState(_ itemID: String) throws -> ItemState {
        try Identifier.validate(itemID)
        guard revisionProjectionEnabled, isCanonicalReady, let index else {
            throw TractandaError("unsupportedFeature", "Revision projection is not enabled for this store.")
        }
        guard let projection = try index.currentProjection(itemID: itemID) else {
            throw TractandaError("notFound", "Item is unavailable.")
        }
        guard canReadProjection(itemID) else { throw TractandaError("forbidden", "Item access is denied.") }
        return projection.state
    }

    private func requireLocalLegacyReceipt(_ row: ItemIndex.CatalogueRow) throws {
        guard let coordinator = peerIntake else { return }
        let identity = try canonicalStoreIdentity(creatingIfMissing: false)
        guard let replica = try ReplicaIdentity.load(root: root, storeID: identity, ownerUID: ownerUID),
            try AuthorityStore.isLocalLegacyReceipt(
                row, root: root, storeID: identity,
                replicaID: replica.replicaID, files: coordinator.journal.files)
        else {
            throw TractandaError(
                "operationOriginRequired", "An imported legacy receipt cannot replay a local operation.")
        }
    }
    private func priorOperation(
        _ id: String, uid: UInt32,
        kind: RevisionProvenance.Kind = .authored
    ) throws -> Revision? {
        guard let index else {
            throw TractandaError(
                "indexUnavailable",
                "Operation receipt candidates exceed the safe bound or index is unavailable.")
        }
        func matchesCaller(_ row: ItemIndex.CatalogueRow) -> Bool {
            let actor = row.actor
            if actor == "uid:\(uid)", uid == ownerUID { return true }
            if actor.hasPrefix("uid:"), let legacyUID = UInt32(actor.dropFirst(4)),
                let legacyUser = accessConfiguration?.legacyUsers[legacyUID], let context = accessContext
            {
                // Preserve receipt bytes and old actor identity, but only replay after an
                // explicit canonical mapping resolves to this caller on this request.
                return (try? context.resolver.userID(legacyUser)) == uid
            }
            guard actor.hasPrefix("user:"), let context = accessContext else { return false }
            return (try? context.resolver.userID(String(actor.dropFirst(5)))) == uid
        }
        func candidates(_ origin: String?) throws -> [ItemIndex.CatalogueRow] {
            guard let rows = try index.receipts(named: id, localReplicaID: origin, kind: kind) else {
                throw TractandaError(
                    "indexUnavailable", "Operation receipt candidates exceed this scope's safe bound.")
            }
            let matches = rows.filter(matchesCaller)
            if origin == nil { for row in matches { try requireLocalLegacyReceipt(row) } }
            return matches
        }
        let local = try replicaID.map { try candidates($0) } ?? []
        if local.isEmpty, kind == .authored, let origin = replicaID, let coordinator = peerIntake {
            var bytes: UInt64 = 0
            for raw in try index.authorityHeldReceipts(operationID: id, originID: origin) {
                guard UInt64(raw.descriptor.length) <= 64 * 1024 * 1024 - min(bytes, 64 * 1024 * 1024) else {
                    throw TractandaError("resourceLimit", "Held receipt candidates exceed their byte window.")
                }
                bytes += UInt64(raw.descriptor.length)
                let node = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
                let row = try authorityCatalogueRow(raw, node: node)
                if matchesCaller(row) {
                    guard canReadProjection(row.itemID) else {
                        throw TractandaError("forbidden", "Current item access is denied.")
                    }
                    throw TractandaError(
                        "operationReviewRequired",
                        "This exact local operation is held for authority review; it cannot replay as success."
                    )
                }
            }
        }
        let matches = try local.isEmpty && kind == .authored ? candidates(nil) : local
        guard matches.count <= 1 else {
            throw TractandaError("operationMismatch", "Aliases merge conflicting operation receipts.")
        }
        guard let revisionID = matches.first?.revisionID else { return nil }
        guard let location = try index.revision(revisionID) else {
            throw TractandaError("recoveryError", "Operation receipt points to an unavailable revision.")
        }
        if revisionProjectionEnabled {
            guard canReadProjection(location.itemID) else {
                throw TractandaError("forbidden", "Item access is denied.")
            }
        } else {
            guard let current = try currentHead(location.itemID), canRead(current) else {
                throw TractandaError("forbidden", "Item access is denied.")
            }
        }
        return try loadRevision(revisionID)
    }

    public func configureAccess(_ value: ItemValue, operationID: String) throws -> CommitResult {
        if revisionProjectionEnabled && (accessConfigurationAmbiguous || accessConfigurationProofUnavailable)
        {
            throw TractandaError(
                "configurationConflict", "Use explicit resolution for current access divergence.")
        }
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
            let validated = try? candidate.validatedCatalogue(identity: identity)
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
            guard try candidate.hasCompleteCurrentProjectionCheckpoint() else {
                candidate.close()
                index = nil
                return false
            }
            guard
                try candidate.resumeAcceptedGraphProofFromCheckpoint(
                    validated: validated, requireLinearProjection: !revisionProjectionEnabled)
            else {
                candidate.close()
                index = nil
                return false
            }
            if !revisionProjectionEnabled {
                let combined = try candidate.corpusPrepare(
                    "SELECT 1 FROM scoped_operation_receipts WHERE kind!='authored' LIMIT 1")
                let found = candidate.catalogueStep(combined) == SQLITE_ROW
                sqlite3_finalize(combined)
                if found {
                    candidate.close()
                    index = nil
                    return false
                }
            }
            guard
                try revisionProjectionEnabled
                    || candidate.currentHeadCount(classID: AccessConfiguration.classID) <= 1
            else {
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
            if revisionProjectionEnabled { try refreshCurrentAccessConfigurations(using: candidate) }
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
        CanonicalRecordPath.validate(path, itemID: itemID, revisionID: revisionID)
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
            catalogueWatermark: try index.catalogueWatermark(), authorityEnforced: authorityIntakeEnabled)
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
            if let coordinator = peerIntake, currentRow(for: finding.path) == nil, let index {
                let name = URL(fileURLWithPath: finding.path).deletingPathExtension().lastPathComponent
                if let retained = try index.retainedAuthorityObject(id: name), retained.path == finding.path,
                    retained.descriptor.kind == .item
                {
                    if (try? coordinator.bytes(retained)) != nil { continue }
                    confirmed.append(finding)
                    continue
                }
            }
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
        if let peerIntake {
            try peerIntake.withOperation(recovery: true) {
                try staging.withCatalogueScanBudget(reusingActiveBudget: true) {
                    try peerIntake.recoverInventory(index: staging, validateClosure: false)
                    try staging.initializeAuthorityControlSchema()
                    try staging.initializeAuthorityReviewSchema()
                    try validateForeignReviewSeals(coordinator: peerIntake, index: staging)
                    if let pin = try peerIntake.configuration()?.bootstrap {
                        try staging.retainLocalBootstrapAcceptance(pin)
                    }
                    try validateAuthorityControls(
                        packageID: nil, coordinator: peerIntake, index: staging, recovering: true)
                    // Actual sealed LOCAL protected-review units now restore their exact
                    // provisional B/C through the existing engine before closure is checked.
                    // Recovery remains quarantined; this check precedes all graph serving.
                    try staging.validateRestoredAuthorityClosure()
                    try peerIntake.validatePeerRetirementCuts(index: staging)
                    try validateActivatedRetirements(coordinator: peerIntake, index: staging)
                    try validateSourceEnrollmentApprovals(coordinator: peerIntake, index: staging)
                    _ = try activateOriginAdmissions(coordinator: peerIntake, index: staging)
                    try validateOriginAdmissions(coordinator: peerIntake, index: staging)
                    try validateTargetEnrollment(
                        coordinator: peerIntake, index: staging, validation: .fullReplay)
                    try validateSourceRegistrations(coordinator: peerIntake)
                    try reduceRetainedAuthorityInventory(coordinator: peerIntake, index: staging)
                    _ = try reducePeerRetirements(coordinator: peerIntake, index: staging)
                }
            }
        }
        let authorityEnforced =
            try peerIntake != nil
            && (CanonicalReaderRequirement.load(root: root, ownerUID: ownerUID)?.minimumReaderLevel ?? 1) >= 3
        attachmentRecoveryValidationsForTesting = 0
        try staging.execute(
            "CREATE TEMP TABLE attachment_owners (id TEXT PRIMARY KEY, item TEXT NOT NULL, descriptor TEXT NOT NULL)"
        )
        try staging.execute(
            "CREATE TEMP TABLE document_owners (id TEXT PRIMARY KEY, item TEXT NOT NULL, descriptor TEXT NOT NULL)"
        )
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
                try self.rebuildControl?.check()
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
                if authorityEnforced, authorityBootstrapPending, let pending = pendingFoundingPolicy,
                    revision.revisionID == pending.revisionID
                {
                    guard revision.itemID == pending.itemID,
                        String(url.path.dropFirst(root.path.count + 1)) == pending.path,
                        bytes.count == pending.length, AuthorityRecordCodec.sha256(bytes) == pending.sha256,
                        metadata.mode == pending.mode, metadata.uid == pending.uid
                    else {
                        throw InitialAuthorityBootstrap.failure(
                            "Pending founding policy differs from its exact reserved original.")
                    }
                    // Retention/capture still supplies the real original to bootstrap admission.
                    // Until its pin is durable it neither grants admission nor removes creator rights.
                    return true
                }
                if authorityEnforced {
                    if let retained = try staging.retainedAuthorityObject(id: revision.revisionID) {
                        guard retained.descriptor.sha256 == AuthorityRecordCodec.sha256(bytes),
                            retained.path == String(url.path.dropFirst(root.path.count + 1))
                        else {
                            throw TractandaError(
                                "invalidAuthority",
                                "Sealed receiver locator/digest differs from canonical file.")
                        }
                        if try staging.authorityDisposition(id: revision.revisionID)?.disposition != .eligible
                        {
                            return true
                        }
                        guard try staging.authorityParentsAreEligible(revisionID: revision.revisionID) else {
                            throw TractandaError(
                                "invalidAuthority", "Eligible history is not ancestor closed.")
                        }
                    } else if !authorityBootstrapPending {
                        throw TractandaError(
                            "unsealedAuthorityObject",
                            "A canonical item has no sealed publication or pinned baseline: \(revision.revisionID)"
                        )
                    }
                    // Before the initial pin, old canonical history is loaded solely for
                    // administrator maintenance. It cannot authorize ordinary requests/publication.
                }
                recordDecodeSeconds += ProcessInfo.processInfo.systemUptime - decodeStart
                let hashStart = ProcessInfo.processInfo.systemUptime
                let digest = Data(SHA256.hash(data: bytes))
                recordHashSeconds += ProcessInfo.processInfo.systemUptime - hashStart
                let semanticsStart = ProcessInfo.processInfo.systemUptime
                try ItemSemantics.validate(revision)
                for attachment in try AttachmentDescriptor.descriptors(in: revision.fields) {
                    if try staging.registerRecoveryAttachment(attachment, itemID: revision.itemID) {
                        let control = rebuildControl
                        let startingBytes = control?.status.originalBytesVerified ?? 0
                        try attachmentPayloads.validate(
                            descriptor: attachment,
                            progress: { verified in
                                let prior = control?.status.originalBytesVerified ?? startingBytes
                                let total = startingBytes.addingReportingOverflow(verified)
                                guard !total.overflow else {
                                    throw TractandaError("resourceLimit", "Rebuild byte progress overflowed.")
                                }
                                try control?.pulse(originalBytes: total.partialValue - prior)
                            })
                        attachmentRecoveryValidationsForTesting += 1
                    }
                }
                for document in try AttachmentDocumentRepresentation.representations(in: revision.fields) {
                    if let content = document.content,
                        try staging.registerRecoveryDocument(document, itemID: revision.itemID)
                    {
                        try documentContents.validate(
                            content, source: document.source, identity: document.identity,
                            extractedAt: document.extractedAt, boundary: { try self.rebuildControl?.check() },
                            progress: { _ in try self.rebuildControl?.pulse(pages: 1) })
                    }
                }
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
                    createdAt: createdAt, feedbackRevisionIDs: feedbackIDs,
                    modifiedAt: revision.modifiedAt, provenance: try revision.provenance)
                do { try staging.insertRecoveryRow(row, graphFields: revision.fields) } catch {
                    throw Self.classifyRecoveryFailure(
                        error, message: "Duplicate canonical revision, path or receipt")
                }
                try rebuildControl?.pulse(records: 1)
                try afterRecoveryRecordForTesting?(url)
                return true
            }
        }
        do { try scan(root.appendingPathComponent("items"), depth: 0) } catch {
            throw Self.classifyRecoveryFailure(
                error, message: "Cannot enumerate or validate canonical records")
        }
        let enumerationEnd = ProcessInfo.processInfo.systemUptime
        try rebuildControl?.pulse(phase: "validatingRevisionGraph")
        do {
            try beforeRevisionGraphValidationForTesting?(staging)
            try staging.validateRecoveryGraph(
                requireLinearProjection: !revisionProjectionEnabled,
                progress: {
                    try self.revisionGraphProgressForTesting?()
                    try self.rebuildControl?.graphProgress()
                })
        } catch {
            throw Self.classifyRecoveryFailure(error, message: "Canonical revision graph is invalid")
        }
        if let peerIntake {
            try finishRecoveryAuthorityReviews(coordinator: peerIntake, index: staging)
            try reduceRetainedAuthorityInventory(coordinator: peerIntake, index: staging)
            _ = try reducePeerRetirements(coordinator: peerIntake, index: staging)
        }
        let chainEnd = ProcessInfo.processInfo.systemUptime
        heads.removeAll(keepingCapacity: false)
        headCacheOrder.removeAll(keepingCapacity: false)
        headCacheBytes = 0
        var categoryHeads: [Revision] = []
        var categoryBytes = 0
        var categoryEdges: [String: Set<String>] = [:]
        var activeCategories: Set<String> = []
        var deferredCategories: [String] = []
        var recoveredConfiguration: AccessConfiguration?
        var clockDependent = false
        var cursor: String?
        try rebuildControl?.pulse(phase: "projectingCurrentItems")
        while true {
            let linearHead = revisionProjectionEnabled ? nil : try staging.recoveryHead(after: cursor)
            let nextItem =
                revisionProjectionEnabled ? try staging.recoveryItem(after: cursor) : linearHead?.itemID
            guard let itemID = nextItem else { break }
            try rebuildControl?.pulse(items: 1)
            let row: ItemIndex.CatalogueRow
            if revisionProjectionEnabled {
                let projected = try prepareRecoveredProjection(
                    itemID, using: staging, deferCategory: true)
                if let parents = projected.categoryParents {
                    guard deferredCategories.count < Self.categoryWorkingSetLimit,
                        parents.count <= Self.categoryWorkingSetLimit
                    else {
                        throw TractandaError(
                            "resourceLimit", "Known category constraints exceed their working set.")
                    }
                    deferredCategories.append(itemID)
                    categoryEdges[itemID] = parents
                    if projected.activeCategory { activeCategories.insert(itemID) }
                }
                guard let revision = projected.revision,
                    let located = try staging.revision(revision.revisionID)
                else {
                    cursor = itemID
                    continue
                }
                row = located
            } else {
                guard let linearHead,
                    let located = try staging.revision(itemID: itemID, revisionID: linearHead.revisionID)
                else {
                    throw TractandaError("recoveryError", "Current revision catalogue row is missing.")
                }
                row = located
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
            guard revision.itemID == itemID, revision.revisionID == row.revisionID,
                revision.supersedes == row.parentID,
                revision.fields["createdAt"]?.dateString == row.createdAt,
                revision.modifiedAt == row.modifiedAt, try revision.provenance == row.provenance
            else {
                throw TractandaError(
                    "recoveryError", "Current revision body or indexed text is inconsistent.")
            }
            let input = try PageCorpusInput(
                storeID: canonicalStoreIdentity(creatingIfMissing: false), revision: revision)
            let provider = StoredPageCorpusProvider(contents: documentContents, incoming: nil)
            // A newly published automatic record was already indexed atomically by append.
            // Cold retained records still use the prepared insertion path exactly once.
            if try staging.currentHeadSummary(revision.itemID)?.revisionID != revision.revisionID {
                try staging.putForRebuild(
                    revision, using: statements, corpusInput: input,
                    pageProvider: provider,
                    corpusBoundary: {
                        try self.rebuildControl?.check()
                        try self.rebuildControl?.pulse(phase: "indexingAuthenticatedPages")
                        try self.requireIndexFilesystemCapacity(additionalBytes: 0)
                    })
            }
            guard try staging.textMatches(revision) else {
                throw TractandaError("recoveryError", "Current revision indexing failed during rebuild.")
            }
            if !revisionProjectionEnabled {
                let linear = try staging.verifiedLinearProjectionSnapshot(
                    row: row, revision: revision,
                    progress: { try self.rebuildControl?.graphProgress() })
                guard !linear.analysis.needsMaterialization else {
                    throw TractandaError(
                        "revisionProjectionRequired",
                        "Linear recovery needs clock reconciliation; use a reader with revision projection enabled."
                    )
                }
                let ready = try projectionState(for: linear)
                try staging.replaceCurrentProjection(
                    snapshot: linear, state: ready,
                    policies: [
                        .init(
                            revisionID: revision.revisionID, classID: revision.classID,
                            permissions: revision.fields["permissions"])
                    ], policiesComplete: true)
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
                guard revisionProjectionEnabled || recoveredConfiguration == nil else {
                    throw TractandaError("recoveryError", "Multiple access configuration heads exist.")
                }
                recoveredConfiguration = try AccessConfiguration(revision.fields["accessConfiguration"]!)
            }
            clockDependent = clockDependent || Self.categoryUsesClock(revision)
            cursor = itemID
        }
        if revisionProjectionEnabled {
            var remaining = activeCategories
            var depth: [String: Int] = [:]
            var invalid: Set<String> = []
            while !remaining.isEmpty {
                let ready = remaining.filter {
                    (categoryEdges[$0] ?? []).intersection(activeCategories).isDisjoint(with: remaining)
                }
                if ready.isEmpty {
                    invalid.formUnion(remaining)
                    break
                }
                for id in ready {
                    let parents = (categoryEdges[id] ?? []).intersection(activeCategories)
                    let level = 1 + (parents.compactMap { depth[$0] }.max() ?? 0)
                    depth[id] = level
                    if level > 32 || !parents.isDisjoint(with: invalid) { invalid.insert(id) }
                    remaining.remove(id)
                }
            }
            for id in deferredCategories {
                if invalid.contains(id) {
                    let snapshot = try staging.analyzeRevisionProjection(
                        itemID: id,
                        loadVerified: {
                            try PooledCanonicalRecord.read(row: $0, root: self.root, ownerUID: self.ownerUID)
                        },
                        limits: revisionProjectionLimits,
                        progress: { try self.rebuildControl?.graphProgress() })
                    let policies = try projectionPolicies(snapshot, using: staging)
                    let state = try projectionState(
                        for: snapshot, status: .invariantConflict,
                        resource: .init(
                            code: "categoryCycle", phase: .analysis,
                            message: "Known category-parent constraints require explicit resolution."))
                    try staging.replaceCurrentProjection(
                        snapshot: snapshot, state: state,
                        policies: policies, policiesComplete: true)
                    continue
                }
                let projected = try prepareRecoveredProjection(id, using: staging)
                guard let revision = projected.revision else { continue }
                let input = try PageCorpusInput(
                    storeID: canonicalStoreIdentity(creatingIfMissing: false), revision: revision)
                if try staging.currentHeadSummary(revision.itemID)?.revisionID != revision.revisionID {
                    try staging.putForRebuild(
                        revision, using: statements, corpusInput: input,
                        pageProvider: StoredPageCorpusProvider(contents: documentContents, incoming: nil),
                        corpusBoundary: { try self.rebuildControl?.graphProgress() })
                }
                guard try staging.textMatches(revision) else {
                    throw TractandaError(
                        "recoveryError", "Recovered category content does not match its canonical revision.")
                }
                try rememberHead(Self.residentHead(revision))
                let size = try JSON.encode(revision).count
                guard categoryHeads.count < Self.categoryWorkingSetLimit,
                    size <= Self.categoryWorkingSetByteLimit - categoryBytes
                else {
                    throw TractandaError("resourceLimit", "Recovered category graph exceeds its working set.")
                }
                categoryBytes += size
                categoryHeads.append(revision)
                clockDependent = clockDependent || Self.categoryUsesClock(revision)
            }
        }
        if peerIntake != nil {
            var after: String?
            while true {
                let ids = try staging.authorityRetiredItemPage(after: after, limit: 128)
                if ids.isEmpty { break }
                for id in ids {
                    after = id
                    try staging.replaceCurrentProjection(
                        snapshot: nil,
                        state: ItemState(
                            itemID: id, stateToken: nextProjectionStateToken(), status: .reviewRequired,
                            detailsComplete: false,
                            resource: .init(
                                code: "authorityReviewRequired", phase: .analysis,
                                message:
                                    "No eligible current policy remains; administrator review is required.")),
                        policies: [], policiesComplete: false)
                }
            }
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
        if revisionProjectionEnabled { try refreshCurrentAccessConfigurations(using: staging) }
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
    private static func classifyRecoveryFailure(_ error: Error, message: String) -> Error {
        if error is CancellationError {
            return TractandaError("cancelled", "Canonical recovery was cancelled.")
        }
        if let failure = error as? TractandaError,
            ["resourceLimit", "cancelled", "rebuildNoProgress", "revisionProjectionRequired"].contains(
                failure.code)
        {
            return failure
        }
        return TractandaError("recoveryError", "\(message): \(error)")
    }
    private static func categoryUsesClock(_ fields: [String: ItemValue], isDeleted: Bool) -> Bool {
        guard !isDeleted, let selection = fields["selection"]?.map else { return false }
        return selection["timeWindow"] != nil
            || selection["expression"]?.string?.contains("$time.") == true
    }
    private func loadRevision(_ revisionID: String) throws -> Revision? {
        do { return try loadRevisionUnchecked(revisionID) } catch {
            let code = (error as? TractandaError)?.code
            if ![
                "indexTransient", "indexResource", "resourceLimit", "cancelled", "rebuildNoProgress",
                "revisionProjectionRequired", "projectionRequired",
            ].contains(code ?? ""), isCanonicalReady {
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
            revision.fields["operationID"]?.string == location.operationID,
            revision.modifiedAt == location.modifiedAt, try revision.provenance == location.provenance
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
            && (base.map { previous in
                guard let old = try? IndexCorpusPlan.current(previous).map(\.sourceKey),
                    let new = try? IndexCorpusPlan.current(revision).map(\.sourceKey)
                else { return true }
                return old != new
            } ?? true)
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

    private func retainedHistoricalRow(_ itemID: String, revisionID: String, index: ItemIndex) throws
        -> ItemIndex.CatalogueRow?
    {
        if let row = try index.revision(itemID: itemID, revisionID: revisionID) { return row }
        guard authorityIntakeEnabled, try index.authorityHasLocalHistoryAdmission(revisionID: revisionID),
            let coordinator = peerIntake, let raw = try index.retainedAuthorityObject(id: revisionID),
            raw.descriptor.kind == .item
        else { return nil }
        let node = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
        guard node.revision.itemID == itemID else { return nil }
        return try authorityCatalogueRow(raw, node: node)
    }
    private func physicalHistoryCount(_ itemID: String, index: ItemIndex) throws -> Int {
        if authorityIntakeEnabled && !authorityBootstrapPending {
            return try index.authorityHistoricalCount(itemID: itemID)
        }
        return try index.revisionCount(itemID: itemID)
    }
    func historicalDispositions(for revisions: [Revision]) throws -> [String: HistoricalDisposition] {
        guard authorityIntakeEnabled else { return [:] }
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) { try historicalDispositions(for: revisions) }
        }
        guard revisions.count <= 512, isCanonicalReady, let index else {
            throw TractandaError("resourceLimit", "Historical disposition envelope exceeds its window.")
        }
        var result: [String: HistoricalDisposition] = [:]
        for revision in revisions {
            if try index.currentProjection(itemID: revision.itemID)?.policiesComplete != true {
                try requireAdministrator()
            } else {
                let policies = try index.currentPolicyWitnesses(itemID: revision.itemID)
                if policies.isEmpty {
                    try requireAdministrator()
                } else if !canReadProjection(revision.itemID) {
                    throw TractandaError("forbidden", "Current item access is denied.")
                }
            }
            if try index.authorityHasLocalHistoryAdmission(revisionID: revision.revisionID),
                try index.authorityDisposition(id: revision.revisionID)?.disposition != .eligible
            {
                result[revision.revisionID] = .demoted
            }
        }
        return result
    }
    public func get(_ itemID: String, revisionID: String? = nil) throws -> Revision {
        guard isCanonicalReady else {
            throw TractandaError(
                "recoveryRequired", "Resolve canonical recovery errors before reading or writing.")
        }
        try Identifier.validate(itemID)
        if revisionProjectionEnabled {
            let projection = try itemState(itemID)
            if revisionID == nil, projection.status != .ready {
                throw TractandaError("itemUnresolved", "Current item projection is unresolved.")
            }
        } else {
            guard let head = try currentHead(itemID) else {
                throw TractandaError("notFound", "Item or revision is unavailable.")
            }
            guard canRead(head) else { throw TractandaError("forbidden", "Item access is denied.") }
        }
        let revision: Revision?
        if let revisionID {
            guard let index, let row = try retainedHistoricalRow(itemID, revisionID: revisionID, index: index)
            else {
                throw TractandaError("notFound", "Item or revision is unavailable.")
            }
            revision = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: ownerUID).revision
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
    private func walkPhysicalHistory(
        _ itemID: String, using index: ItemIndex,
        _ consume: (ItemIndex.CatalogueRow) throws -> Bool
    ) throws {
        if authorityIntakeEnabled && !authorityBootstrapPending {
            var after: String?
            while true {
                let rows = try index.authorityHistoricalPage(
                    itemID: itemID, afterRevisionID: after, limit: 128)
                if rows.isEmpty { return }
                for raw in rows {
                    after = raw.descriptor.id
                    guard
                        let row = try retainedHistoricalRow(
                            itemID, revisionID: raw.descriptor.id, index: index)
                    else {
                        throw TractandaError(
                            "invalidAuthority", "Previously visible history original is missing.")
                    }
                    if try !consume(row) { return }
                }
            }
        }
        var cursor: (Int64, String)?
        while true {
            let condition = cursor == nil ? "" : " AND (modified_ticks,revision)<(CAST(? AS INTEGER),?)"
            let bindings = [itemID] + (cursor.map { [String($0.0), $0.1] } ?? [])
            let rows = try index.graphCatalogueRows(
                where: "WHERE item=?\(condition) ORDER BY modified_ticks DESC,revision DESC",
                bindings: bindings, limit: 128)
            guard !rows.isEmpty else { return }
            for row in rows {
                guard try consume(row) else { return }
                cursor = (try RevisionTimestamp(row.modifiedAt).ticks, row.revisionID)
            }
        }
    }

    public func history(_ itemID: String) throws -> [Revision] {
        _ = try preparePooledHistory(itemID)
        guard let index else { throw TractandaError("indexUnavailable", "History catalogue is unavailable.") }
        let maximumBytes = 64 * 1024 * 1024
        guard try physicalHistoryCount(itemID, index: index) <= 4096 else {
            throw TractandaError("resourceLimit", "Use bounded history pages for this item.")
        }
        var output: [Revision] = []
        var bytes = 0
        try index.withCatalogueScanBudget {
            try walkPhysicalHistory(itemID, using: index) { row in
                guard row.size <= UInt64(maximumBytes - bytes),
                    case let revision = try PooledCanonicalRecord.read(
                        row: row, root: root, ownerUID: ownerUID
                    ).revision, revision.itemID == itemID
                else {
                    throw TractandaError("resourceLimit", "Use bounded history pages for this item.")
                }
                let size = try JSON.encode(revision).count
                guard size <= maximumBytes - bytes else {
                    throw TractandaError("resourceLimit", "Use bounded history pages for this item.")
                }
                bytes += size
                output.append(revision)
                return true
            }
        }
        return output
    }
    func historyPageBounded(_ itemID: String, position: Int, limit: Int) throws
        -> (list: [Revision], total: Int)
    {
        guard position >= 0, (1...256).contains(limit) else {
            throw TractandaError("invalidArguments", "Invalid history page.")
        }
        _ = try preparePooledHistory(itemID)
        guard let index else { throw TractandaError("indexUnavailable", "History catalogue is unavailable.") }
        let total = try physicalHistoryCount(itemID, index: index)
        if position >= total { return ([], total) }
        var inspected = 0
        var output: [Revision] = []
        var bytes = 0
        try index.withCatalogueScanBudget {
            try walkPhysicalHistory(itemID, using: index) { row in
                defer { inspected += 1 }
                if inspected < position { return true }
                guard output.count < limit else { return false }
                guard row.size <= UInt64(pooledRecordByteLimit - bytes),
                    case let revision = try PooledCanonicalRecord.read(
                        row: row, root: root, ownerUID: ownerUID
                    ).revision, revision.itemID == itemID
                else {
                    throw TractandaError("resourceLimit", "History page exceeds its byte window.")
                }
                let size = try JSON.encode(revision).count
                guard size <= pooledRecordByteLimit - bytes else {
                    throw TractandaError("resourceLimit", "History page exceeds its byte window.")
                }
                bytes += size
                output.append(revision)
                return output.count < limit
            }
        }
        return (output, total)
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
        isCancelled: (() -> Bool)? = nil,
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
            if isCancelled?() == true { throw CancellationError() }
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

    private func attachmentStagedOffset(_ upload: AttachmentUploadState) throws -> Int64 {
        if upload.location == "published" { return upload.descriptor.byteCount }
        if try attachmentPayloads.publishedMetadataMatches(upload.descriptor) {
            return upload.descriptor.byteCount
        }
        return try attachmentPayloads.stagedSize(id: upload.descriptor.attachmentID)
    }
    @discardableResult
    private func renewAttachmentUpload(_ id: String, upload: AttachmentUploadState, phase: String? = nil)
        throws -> AttachmentUploadState
    {
        var renewed = upload
        renewed.expiresAt = attachmentClockForTesting().addingTimeInterval(
            attachmentUploadPolicy.idleRetentionSeconds)
        if let phase {
            renewed.phase = phase
            renewed.failureCode = nil
            if phase == "published" { renewed.location = "published" }
        }
        try attachmentPayloads.saveUpload(renewed)
        attachmentUploads[id] = renewed
        return renewed
    }
    private func requireAttachmentStagingCapacity(additionalBytes: Int64) throws {
        try stagingByteQuota.require(additionalBytes: additionalBytes)
    }
    func prepareAttachmentIntegrity(uploadID: String) throws -> AttachmentIntegrityWork? {
        try requireActivePublishingOrigin()
        let upload = try attachmentUpload(uploadID)
        if let code = upload.failureCode {
            throw TractandaError(code, "Upload integrity verification failed; abort and begin again.")
        }
        if try attachmentPayloads.isStagedVerified(upload.descriptor) { return nil }
        guard try attachmentStagedOffset(upload) == upload.descriptor.byteCount else {
            throw TractandaError(
                "uploadMismatch", "Upload is incomplete; resume sending the remaining bytes.")
        }
        if upload.phase != "verifying" {
            _ = try renewAttachmentUpload(uploadID, upload: upload, phase: "verifying")
        }
        return AttachmentIntegrityWork(
            payloads: attachmentPayloads, descriptor: upload.descriptor, uploadID: uploadID)
    }
    func attachmentIntegrityFinished(uploadID: String, failureCode: String?) throws {
        guard let upload = attachmentUploads[uploadID] else { return }
        var next = upload
        next.phase = failureCode == nil ? "verified" : (failureCode == "cancelled" ? "paused" : "failed")
        next.failureCode = failureCode == "cancelled" ? nil : failureCode
        _ = try renewAttachmentUpload(uploadID, upload: next)
    }
    func attachmentUploadStatus(uploadID: String, verifiedBytes: Int64 = 0) throws
        -> AttachmentIntegrityStatus
    {
        let upload = try attachmentUpload(uploadID)
        let verified =
            try (upload.phase == "verified" || upload.phase == "published")
            && attachmentPayloads.isStagedVerified(upload.descriptor)
        return AttachmentIntegrityStatus(
            attachmentID: upload.descriptor.attachmentID, uploadID: uploadID,
            phase: upload.phase,
            verifiedBytes: verified
                ? upload.descriptor.byteCount : min(verifiedBytes, upload.descriptor.byteCount),
            totalBytes: upload.descriptor.byteCount, staging: stagingByteQuota.uploadUsage(id: uploadID))
    }
    func prepareAttachmentReadIntegrity(itemID: String, revisionID: String?, attachmentID: String) throws
        -> AttachmentIntegrityWork?
    {
        let descriptor = try attachmentReadDescriptor(
            itemID: itemID, revisionID: revisionID, attachmentID: attachmentID)
        if try attachmentPayloads.isVerified(descriptor) { return nil }
        return AttachmentIntegrityWork(payloads: attachmentPayloads, descriptor: descriptor, uploadID: nil)
    }
    private func attachmentReadDescriptor(itemID: String, revisionID: String?, attachmentID: String) throws
        -> AttachmentDescriptor
    {
        let revision = try get(itemID, revisionID: revisionID)
        guard
            let descriptor = try AttachmentDescriptor.descriptors(in: revision.fields).first(where: {
                $0.attachmentID == attachmentID
            })
        else {
            throw TractandaError("notFound", "Attachment is unavailable on this item revision.")
        }
        return descriptor
    }
    func attachmentReadIntegrityStatus(
        itemID: String, revisionID: String?, attachmentID: String, verifiedBytes: Int64 = 0
    ) throws -> AttachmentIntegrityStatus {
        let descriptor = try attachmentReadDescriptor(
            itemID: itemID, revisionID: revisionID, attachmentID: attachmentID)
        let verified = try attachmentPayloads.isVerified(descriptor)
        return AttachmentIntegrityStatus(
            attachmentID: attachmentID, uploadID: nil, phase: verified ? "verified" : "verifying",
            verifiedBytes: verified ? descriptor.byteCount : min(verifiedBytes, descriptor.byteCount),
            totalBytes: descriptor.byteCount)
    }

    private func expireAttachmentUploads() throws {
        let now = attachmentClockForTesting()
        for (id, upload) in attachmentUploads where upload.expiresAt <= now && upload.phase != "verifying" {
            _ = try renewAttachmentUpload(id, upload: upload, phase: "discarding")
            try attachmentPayloads.discardStaging(id: id)
            try afterAttachmentStageDiscardForTesting?()
            try attachmentPayloads.removeUpload(id: id)
            attachmentUploads.removeValue(forKey: id)
        }
    }
    private func attachmentUpload(_ id: String) throws -> AttachmentUploadState {
        try expireAttachmentUploads()
        guard let upload = attachmentUploads[id], upload.uid == accessContext!.uid else {
            throw TractandaError("uploadExpired", "Upload is unavailable; begin again with the same intent.")
        }
        let current = try get(upload.request.itemID)
        try requireEdit(current, changesPermissions: false)
        return upload
    }
    private func attachmentCommitRequest(
        _ request: AttachmentUploadRequest, descriptor: AttachmentDescriptor
    ) throws -> CommitRequest {
        let base = try get(request.itemID, revisionID: request.expectedRevisionID)
        var descriptors = try AttachmentDescriptor.descriptors(in: base.fields)
        guard descriptors.count < 128 else {
            throw TractandaError("resourceLimit", "An item permits at most 128 attachments.")
        }
        descriptors.append(descriptor)
        return CommitRequest(
            action: .revise, itemID: request.itemID, expectedRevisionID: request.expectedRevisionID,
            changes: ["attachments": .list(descriptors.map(\.itemValue))], operationID: request.operationID)
    }
    public func beginAttachment(_ request: AttachmentUploadRequest) throws -> AttachmentUploadResult {
        if accessContext == nil { return try withAccess(forUID: ownerUID) { try beginAttachment(request) } }
        try Identifier.validate(request.itemID)
        try Identifier.validate(request.expectedRevisionID)
        guard !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
            !request.operationID.contains("\0")
        else {
            throw TractandaError("invalidArguments", "Supply a nonempty operationID of at most 200 bytes.")
        }
        let current = try get(request.itemID)
        // Replay survives a lost reply and restart; intent includes exact source bytes and base revision.
        if let prior = try priorOperation(request.operationID, uid: accessContext!.uid) {
            guard let encoded = prior.fields["requestIdentity"]?.string,
                let bytes = Data(base64Encoded: encoded),
                let original = try? JSON.decode(CommitRequest.self, bytes),
                original.itemID == request.itemID,
                original.expectedRevisionID == request.expectedRevisionID,
                original.action == .revise, original.unset.isEmpty,
                Set(original.changes.keys) == ["attachments"],
                let descriptor = try AttachmentDescriptor.descriptors(in: original.changes).last,
                descriptor.filename == request.filename, descriptor.mediaType == request.mediaType,
                descriptor.byteCount == request.byteCount, descriptor.sha256 == request.sha256
            else {
                throw TractandaError("operationMismatch", "Operation already committed a different intent.")
            }
            let replay = try commitInternal(attachmentCommitRequest(request, descriptor: descriptor))
            try attachmentPayloads.removeUpload(id: descriptor.attachmentID)
            attachmentUploads.removeValue(forKey: descriptor.attachmentID)
            return AttachmentUploadResult(
                uploadID: nil, attachment: descriptor, offset: descriptor.byteCount,
                chunkBytes: 262_144, expiresAt: nil, committed: AttachmentCommitResult(replay))
        }
        try requireActivePublishingOrigin()
        try requireEdit(current, changesPermissions: false)
        guard current.revisionID == request.expectedRevisionID else {
            throw TractandaError("revisionConflict", "The item changed; reconcile before beginning upload.")
        }
        try expireAttachmentUploads()
        if let (id, upload) = attachmentUploads.first(where: {
            $0.value.uid == accessContext!.uid && $0.value.request.operationID == request.operationID
        }) {
            guard upload.request == request else {
                throw TractandaError("operationMismatch", "Upload operation already has a different intent.")
            }
            let renewed = try renewAttachmentUpload(id, upload: upload)
            return AttachmentUploadResult(
                uploadID: id, attachment: renewed.descriptor,
                offset: try attachmentStagedOffset(renewed),
                chunkBytes: 262_144, expiresAt: Timestamp.format(renewed.expiresAt), committed: nil)
        }
        let id = try makePersistentUUID().uuidString.lowercased()
        let descriptor = try AttachmentDescriptor(
            attachmentID: id, filename: request.filename, mediaType: request.mediaType,
            byteCount: request.byteCount, sha256: request.sha256)
        guard attachmentUploads.count < 64,
            attachmentUploads.values.filter({ $0.uid == accessContext!.uid }).count < 8
        else {
            throw TractandaError(
                "resourceLimit",
                "Staging permits eight uploads per caller and 64 total.")
        }
        _ = try attachmentCommitRequest(request, descriptor: descriptor)
        let expiration = attachmentClockForTesting().addingTimeInterval(
            attachmentUploadPolicy.idleRetentionSeconds)
        let upload = AttachmentUploadState(
            uid: accessContext!.uid, request: request, descriptor: descriptor, expiresAt: expiration)
        try stagingByteQuota.retainUpload(
            id: id, initialCheckpointBytes: Int64(try JSON.encode(upload).count))
        var stageOwned = false
        do {
            try attachmentPayloads.createStaging(id: id, onCreated: { stageOwned = true })
        } catch {
            let admissionError = error
            if stageOwned {
                do { try attachmentPayloads.discardStaging(id: id) } catch {
                    // Uncertain cleanup retains the intent and reservation for retry/disposal.
                    attachmentUploads[id] = upload
                    try? attachmentPayloads.saveUpload(upload)
                    throw admissionError
                }
            }
            stagingByteQuota.completeUpload(id: id)
            throw admissionError
        }
        // Keep an admitted intent discoverable in memory even after an uncertain checkpoint reply.
        attachmentUploads[id] = upload
        try attachmentPayloads.saveUpload(upload)
        return AttachmentUploadResult(
            uploadID: id, attachment: descriptor, offset: 0, chunkBytes: 262_144,
            expiresAt: Timestamp.format(expiration), committed: nil)
    }
    public func appendAttachment(uploadID: String, offset: Int64, data: Data) throws -> Int64 {
        try requireActivePublishingOrigin()
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try appendAttachment(uploadID: uploadID, offset: offset, data: data)
            }
        }
        let upload = try attachmentUpload(uploadID)
        guard offset >= 0, offset <= upload.descriptor.byteCount,
            data.count <= 262_144, Int64(data.count) <= upload.descriptor.byteCount - offset
        else {
            throw TractandaError(
                "invalidArguments", "Chunk exceeds the declared original or 256 KiB ceiling.")
        }
        guard upload.phase == "uploading" || upload.phase == "paused" else {
            throw TractandaError("uploadBusy", "Upload is being finalized or has already been published.")
        }
        let currentSize = try attachmentPayloads.stagedSize(id: uploadID)
        if offset == currentSize { try requireAttachmentStagingCapacity(additionalBytes: Int64(data.count)) }
        let next = try attachmentPayloads.append(id: uploadID, offset: offset, data: data)
        _ = try renewAttachmentUpload(uploadID, upload: upload, phase: "uploading")
        return next
    }
    public func finishAttachment(uploadID: String, requireVerified: Bool = false) throws -> CommitResult {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try finishAttachment(uploadID: uploadID, requireVerified: requireVerified)
            }
        }
        let upload = try attachmentUpload(uploadID)
        if let prior = try priorOperation(upload.request.operationID, uid: accessContext!.uid) {
            let request = try attachmentCommitRequest(upload.request, descriptor: upload.descriptor)
            guard prior.fields["requestIdentity"]?.string == (try JSON.encode(request).base64EncodedString())
            else {
                throw TractandaError("operationMismatch", "Committed upload differs from exact retry.")
            }
            return try commitInternal(request)
        }
        try requireActivePublishingOrigin()
        if let code = upload.failureCode {
            throw TractandaError(code, "Upload integrity verification failed; abort and begin again.")
        }
        let request = try attachmentCommitRequest(upload.request, descriptor: upload.descriptor)
        // Once publication is durable, failure may leave unreachable bytes but never a dangling revision.
        try attachmentPayloads.publish(descriptor: upload.descriptor, requireVerifiedStage: requireVerified)
        try afterAttachmentPayloadPublicationForTesting?()
        _ = try renewAttachmentUpload(uploadID, upload: upload, phase: "published")
        try beforeAttachmentCommitForTesting?()
        let result = try commitInternal(request)
        try afterAttachmentItemCommitForTesting?()
        try attachmentPayloads.removeUpload(id: uploadID)
        attachmentUploads.removeValue(forKey: uploadID)
        return result
    }
    public func abortAttachment(uploadID: String) throws {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) { try abortAttachment(uploadID: uploadID) }
        }
        let upload = try attachmentUpload(uploadID)
        _ = try renewAttachmentUpload(uploadID, upload: upload, phase: "discarding")
        try attachmentPayloads.discardStaging(id: uploadID)
        try afterAttachmentStageDiscardForTesting?()
        try attachmentPayloads.removeUpload(id: uploadID)
        attachmentUploads.removeValue(forKey: uploadID)
    }
    public func listAttachments(itemID: String, revisionID: String? = nil) throws -> AttachmentListResult {
        let revision = try get(itemID, revisionID: revisionID)
        return AttachmentListResult(
            itemID: itemID, revisionID: revision.revisionID,
            attachments: try AttachmentDescriptor.descriptors(in: revision.fields),
            storeID: try canonicalStoreIdentity(creatingIfMissing: false))
    }
    public func attachmentContent(
        itemID: String, revisionID: String? = nil, attachmentID: String, offset: Int64 = 0,
        limit: Int = 262_144, requireVerified: Bool = false
    ) throws -> AttachmentContentResult {
        // Resolve current permissions before any payload path/metadata/read, including history.
        let revision = try get(itemID, revisionID: revisionID)
        guard
            let descriptor = try AttachmentDescriptor.descriptors(in: revision.fields).first(where: {
                $0.attachmentID == attachmentID
            })
        else { throw TractandaError("notFound", "Attachment is unavailable on this item revision.") }
        let bytes = try attachmentPayloads.read(
            descriptor: descriptor, offset: offset, limit: limit, requireVerified: requireVerified)
        let next = offset + Int64(bytes.count)
        return AttachmentContentResult(
            attachment: descriptor, offset: offset, nextOffset: next,
            isComplete: next == descriptor.byteCount, data: bytes,
            storeID: try canonicalStoreIdentity(creatingIfMissing: false))
    }
    public func detachAttachment(
        itemID: String, expectedRevisionID: String, attachmentID: String, operationID: String
    ) throws -> CommitResult {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try detachAttachment(
                    itemID: itemID, expectedRevisionID: expectedRevisionID,
                    attachmentID: attachmentID, operationID: operationID)
            }
        }
        let base = try get(itemID, revisionID: expectedRevisionID)
        let descriptors = try AttachmentDescriptor.descriptors(in: base.fields)
        guard descriptors.contains(where: { $0.attachmentID == attachmentID }) else {
            throw TractandaError("notFound", "Attachment is unavailable on the expected item revision.")
        }
        return try commitInternal(
            CommitRequest(
                action: .revise, itemID: itemID, expectedRevisionID: expectedRevisionID,
                changes: [
                    "attachments": .list(
                        descriptors.filter { $0.attachmentID != attachmentID }.map(\.itemValue))
                ],
                operationID: operationID))
    }

    private func documentExtractionReplay(
        itemID: String, expectedRevisionID: String, attachmentID: String, operationID: String,
        identity: DocumentConverterIdentity
    ) throws -> AttachmentCommitResult? {
        guard let prior = try priorOperation(operationID, uid: accessContext!.uid) else { return nil }
        guard let encoded = prior.fields["requestIdentity"]?.string,
            let data = Data(base64Encoded: encoded),
            let original = try? JSON.decode(CommitRequest.self, data),
            original.action == .revise, original.itemID == itemID,
            original.expectedRevisionID == expectedRevisionID, original.unset.isEmpty,
            Set(original.changes.keys) == [AttachmentDocumentRepresentation.fieldName],
            let representation = try AttachmentDocumentRepresentation.representations(in: original.changes)
                .first(where: { $0.attachmentID == attachmentID }),
            representation.source.itemID == itemID,
            representation.source.revisionID == expectedRevisionID,
            representation.source.attachmentID == attachmentID, representation.identity == identity
        else {
            throw TractandaError(
                "operationMismatch", "This operation committed a different document extraction.")
        }
        return AttachmentCommitResult(try commitInternal(original))
    }

    /// Current authority is scoped to this synchronous admission only. The snapshot
    /// contains immutable original bytes and no Store, access context or file handles.
    func prepareAttachmentDocument(
        itemID: String, expectedRevisionID: String, attachmentID: String, operationID: String,
        identity: DocumentConverterIdentity, unavailableCode: String? = nil
    ) throws -> DocumentExtractionAdmission {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try prepareAttachmentDocument(
                    itemID: itemID, expectedRevisionID: expectedRevisionID,
                    attachmentID: attachmentID, operationID: operationID, identity: identity,
                    unavailableCode: unavailableCode)
            }
        }
        for id in [itemID, expectedRevisionID, attachmentID] { try Identifier.validate(id) }
        try identity.validateCurrent()
        guard !operationID.isEmpty, operationID.utf8.count <= 200, !operationID.contains("\0") else {
            throw TractandaError(
                "invalidArguments", "Supply a document extraction operationID of at most 200 bytes.")
        }
        let current = try get(itemID)
        if let replay = try documentExtractionReplay(
            itemID: itemID, expectedRevisionID: expectedRevisionID, attachmentID: attachmentID,
            operationID: operationID, identity: identity)
        {
            return .replay(replay)
        }
        try requireEdit(current, changesPermissions: false)
        if let unavailableCode {
            throw TractandaError(unavailableCode, "Document conversion is unavailable or busy.")
        }
        guard current.revisionID == expectedRevisionID else {
            throw TractandaError("revisionConflict", "The item changed; reconcile before extracting.")
        }
        guard
            let descriptor = try AttachmentDescriptor.descriptors(in: current.fields)
                .first(where: { $0.attachmentID == attachmentID })
        else { throw TractandaError("notFound", "Attachment is unavailable on this item revision.") }
        guard descriptor.byteCount <= AttachmentDocumentRepresentation.maximumInputBytes else {
            throw TractandaError(
                "resourceLimit",
                "The current converter bridge still requires a bounded original; the paged bridge is pending."
            )
        }
        let source = try AttachmentDocumentSource(
            itemID: itemID, revisionID: expectedRevisionID, attachmentID: attachmentID,
            sha256: descriptor.sha256, byteCount: descriptor.byteCount, mediaType: descriptor.mediaType)
        var input = Data()
        input.reserveCapacity(Int(source.byteCount))
        var offset: Int64 = 0
        while offset < source.byteCount {
            try Task.checkCancellation()
            let chunk = try attachmentPayloads.read(descriptor: descriptor, offset: offset, limit: 262_144)
            guard !chunk.isEmpty, Int64(chunk.count) <= source.byteCount - offset else {
                throw TractandaError(
                    "attachmentIntegrity", "Original content changed during document admission.")
            }
            input.append(chunk)
            offset += Int64(chunk.count)
        }
        return .prepared(
            DocumentExtractionSnapshot(
                source: source, operationID: operationID, actorUID: accessContext!.uid,
                identity: identity, input: input))
    }

    /// Must be called in a newly resolved authority scope after off-queue conversion.
    func finishAttachmentDocument(
        _ snapshot: DocumentExtractionSnapshot, pages: [AttachmentDocumentPage],
        cancellation: DocumentConversionCancellation? = nil
    ) throws -> AttachmentCommitResult {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try finishAttachmentDocument(snapshot, pages: pages, cancellation: cancellation)
            }
        }
        guard accessContext!.uid == snapshot.actorUID else {
            throw TractandaError("forbidden", "Document extraction caller changed.")
        }
        let source = snapshot.source
        try cancellation?.check()
        let current = try get(source.itemID)
        if let replay = try documentExtractionReplay(
            itemID: source.itemID, expectedRevisionID: source.revisionID,
            attachmentID: source.attachmentID, operationID: snapshot.operationID, identity: snapshot.identity)
        {
            return replay
        }
        try requireEdit(current, changesPermissions: false)
        guard current.revisionID == source.revisionID else {
            throw TractandaError("revisionConflict", "The item changed during document conversion.")
        }
        guard
            let descriptor = try AttachmentDescriptor.descriptors(in: current.fields)
                .first(where: { $0.attachmentID == source.attachmentID }),
            descriptor.sha256 == source.sha256, descriptor.byteCount == source.byteCount,
            descriptor.mediaType == source.mediaType
        else { throw TractandaError("attachmentIntegrity", "Document original changed during conversion.") }
        let writer = try documentContents.begin(source: source, identity: snapshot.identity)
        for page in pages {
            try writer.append(
                DocumentStoredPage(
                    pageNumber: Int64(page.pageNumber), sourceSHA256: source.sha256, page: page))
        }
        let prepared = try writer.preparePublication()
        let corpus = try prepareAttachmentDocumentCorpus(
            snapshot, prepared: prepared, cancellation: cancellation)
        return try finishAttachmentDocument(
            snapshot, prepared: prepared, corpus: corpus, cancellation: cancellation)
    }

    func finishAttachmentDocument(
        _ snapshot: DocumentExtractionSnapshot, prepared: PreparedDocumentContent,
        corpus: IndexedCorpusStage? = nil, cancellation: DocumentConversionCancellation? = nil
    ) throws -> AttachmentCommitResult {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try finishAttachmentDocument(
                    snapshot, prepared: prepared, corpus: corpus, cancellation: cancellation)
            }
        }
        guard accessContext!.uid == snapshot.actorUID else {
            throw TractandaError("forbidden", "Document actor changed.")
        }
        let source = snapshot.source
        if let replay = try documentExtractionReplay(
            itemID: source.itemID, expectedRevisionID: source.revisionID,
            attachmentID: source.attachmentID, operationID: snapshot.operationID, identity: snapshot.identity)
        {
            return replay
        }
        let current = try get(source.itemID)
        try requireEdit(current, changesPermissions: false)
        guard current.revisionID == source.revisionID, prepared.source == source,
            prepared.identity == snapshot.identity
        else {
            throw TractandaError(
                "revisionConflict", "Document source changed; preserve prepared pages and reconcile.")
        }
        guard
            try AttachmentDescriptor.descriptors(in: current.fields).contains(where: {
                $0.attachmentID == source.attachmentID && $0.sha256 == source.sha256
                    && $0.byteCount == source.byteCount && $0.mediaType == source.mediaType
            })
        else {
            throw TractandaError("attachmentIntegrity", "Document original binding changed.")
        }
        try cancellation?.check()
        guard let corpus else {
            throw TractandaError(
                "indexProjectionPending", "Prepare the authenticated offline corpus before finalization.")
        }
        let content = try documentContents.publishPrepared(prepared)
        let representation = try AttachmentDocumentRepresentation(
            representationID: makePersistentUUID().uuidString.lowercased(), attachmentID: source.attachmentID,
            source: source, extractedAt: prepared.extractedAt, identity: snapshot.identity, content: content)
        try AttachmentDocumentValidator.validate(representation)
        var documents = try activeDocuments(
            in: current.fields, originals: AttachmentDescriptor.descriptors(in: current.fields))
        documents.removeAll { $0.attachmentID == source.attachmentID }
        documents.append(representation)
        let changes = [
            AttachmentDocumentRepresentation.fieldName: ItemValue.list(try documents.map { try $0.itemValue })
        ]
        _ = try AttachmentDocumentRepresentation.representations(in: changes)
        try Task.checkCancellation()
        try cancellation?.check()
        let result = try commitInternal(
            CommitRequest(
                action: .revise, itemID: source.itemID,
                expectedRevisionID: source.revisionID, changes: changes, operationID: snapshot.operationID),
            indexedCorpus: corpus)
        if result.isIndexReady {
            try stagingByteQuota.observeDerived(
                workID: corpus.workID,
                retainedEncodedBytes: index?.corpusRetainedBytes(corpus.workID) ?? 0, recovering: true)
        }
        return AttachmentCommitResult(result)
    }

    public func readAttachmentDocument(
        itemID: String, revisionID: String? = nil, attachmentID: String, pageNumber: Int? = nil
    ) throws -> AttachmentDocumentReadResult {
        let revision = try get(itemID, revisionID: revisionID)
        let descriptor = try attachmentReadDescriptor(
            itemID: itemID, revisionID: revisionID, attachmentID: attachmentID)
        guard
            let document = try AttachmentDocumentRepresentation.representations(in: revision.fields).first(
                where: { $0.attachmentID == attachmentID }),
            document.source.sha256 == descriptor.sha256, document.source.byteCount == descriptor.byteCount,
            document.source.mediaType == descriptor.mediaType
        else { throw TractandaError("notFound", "Saved document is unavailable on this revision.") }
        if let content = document.content {
            let manifest = try documentContents.manifest(content)
            guard manifest.source == document.source, manifest.identity == document.identity,
                manifest.extractedAt == document.extractedAt
            else {
                throw TractandaError("documentIntegrity", "Saved document provenance changed.")
            }
            let page = try pageNumber.map { try documentContents.readPage(content, pageNumber: Int64($0)) }
            return try AttachmentDocumentReadResult(
                revision: revision, document: document, pageNumber: pageNumber, savedPage: page)
        }
        return try AttachmentDocumentReadResult(
            revision: revision, document: document, pageNumber: pageNumber)
    }

    public func documentContentPart(
        itemID: String, revisionID: String? = nil, attachmentID: String,
        kind: String, level: Int = 0, index: Int64 = 0, offset: Int64 = 0, limit: Int = 262_144
    ) throws -> DocumentContentPart {
        let revision = try get(itemID, revisionID: revisionID)
        let descriptor = try attachmentReadDescriptor(
            itemID: itemID, revisionID: revisionID, attachmentID: attachmentID)
        guard
            let document = try AttachmentDocumentRepresentation.representations(in: revision.fields).first(
                where: { $0.attachmentID == attachmentID }),
            let content = document.content, document.source.sha256 == descriptor.sha256,
            document.source.byteCount == descriptor.byteCount,
            document.source.mediaType == descriptor.mediaType
        else { throw TractandaError("notFound", "Current saved document content is unavailable.") }
        return try documentContents.part(
            content, kind: kind, level: level, index: index, offset: offset, limit: limit)
    }

    var beforeAttachmentTextCommitForTesting: (() throws -> Void)?
    public func extractAttachmentText(
        itemID: String, expectedRevisionID: String, attachmentID: String, operationID: String
    ) throws -> AttachmentCommitResult {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try extractAttachmentText(
                    itemID: itemID, expectedRevisionID: expectedRevisionID,
                    attachmentID: attachmentID, operationID: operationID)
            }
        }
        try Identifier.validate(itemID)
        try Identifier.validate(expectedRevisionID)
        try Identifier.validate(attachmentID)
        guard !operationID.isEmpty, operationID.utf8.count <= 200, !operationID.contains("\0") else {
            throw TractandaError("invalidArguments", "Supply a nonempty operationID of at most 200 bytes.")
        }
        let current = try get(itemID)
        if let prior = try priorOperation(operationID, uid: accessContext!.uid) {
            guard let identity = prior.fields["requestIdentity"]?.string,
                let data = Data(base64Encoded: identity),
                let original = try? JSON.decode(CommitRequest.self, data),
                original.action == .revise, original.itemID == itemID,
                original.expectedRevisionID == expectedRevisionID, original.unset.isEmpty,
                Set(original.changes.keys) == ["attachmentText"],
                let representation = try AttachmentTextRepresentation.representations(in: original.changes)
                    .first(where: { $0.attachmentID == attachmentID }),
                representation.source.itemID == itemID,
                representation.source.revisionID == expectedRevisionID,
                representation.source.attachmentID == attachmentID
            else {
                throw TractandaError(
                    "operationMismatch", "This operation already committed a different extraction intent.")
            }
            return AttachmentCommitResult(try commitInternal(original))
        }
        try requireEdit(current, changesPermissions: false)
        guard current.revisionID == expectedRevisionID else {
            throw TractandaError("revisionConflict", "The item changed; reconcile before extracting.")
        }
        guard
            let descriptor = try AttachmentDescriptor.descriptors(in: current.fields)
                .first(where: { $0.attachmentID == attachmentID })
        else {
            throw TractandaError("notFound", "Attachment is unavailable on this item revision.")
        }
        guard descriptor.byteCount <= 524_288 else {
            throw TractandaError(
                "resourceLimit", "Deterministic UTF8 extraction is limited to 512 KiB originals.")
        }
        let source = try AttachmentTextSource(
            itemID: itemID, revisionID: expectedRevisionID,
            attachmentID: attachmentID, sha256: descriptor.sha256, byteCount: descriptor.byteCount,
            mediaType: descriptor.mediaType)
        var input = Data()
        var offset: Int64 = 0
        repeat {
            let bytes = try attachmentPayloads.read(descriptor: descriptor, offset: offset, limit: 262_144)
            input.append(bytes)
            offset += Int64(bytes.count)
            guard input.count <= 524_288, !bytes.isEmpty || offset == descriptor.byteCount else {
                throw TractandaError("attachmentIntegrity", "Original content changed during extraction.")
            }
        } while offset < descriptor.byteCount
        let representation = try AttachmentTextDecoder.decode(
            input, source: source,
            representationID: makePersistentUUID().uuidString.lowercased(), attachmentID: attachmentID,
            extractedAt: Timestamp.now())
        var representations = try AttachmentTextRepresentation.representations(in: current.fields)
        representations.removeAll { $0.attachmentID == attachmentID }
        representations.append(representation)
        let values: [String: ItemValue] = ["attachmentText": .list(representations.map(\.itemValue))]
        _ = try AttachmentTextRepresentation.representations(in: values)
        let request = CommitRequest(
            action: .revise, itemID: itemID,
            expectedRevisionID: expectedRevisionID, changes: values, operationID: operationID)
        try beforeAttachmentTextCommitForTesting?()
        return AttachmentCommitResult(try commitInternal(request))
    }

    private func activeDocuments(in fields: [String: ItemValue], originals: [AttachmentDescriptor]) throws
        -> [AttachmentDocumentRepresentation]
    {
        try AttachmentDocumentRepresentation.representations(in: fields).filter { document in
            originals.contains {
                $0.attachmentID == document.attachmentID && $0.sha256 == document.source.sha256
                    && $0.byteCount == document.source.byteCount && $0.mediaType == document.source.mediaType
            }
        }
    }

    private func completeAttachmentCopyQuota(key: String) throws {
        let files = DocumentContentFiles(
            root: root, ownerUID: ownerUID,
            minimumFreeBytes: attachmentUploadPolicy.minimumFreeBytes,
            availableBytes: attachmentCapacityProvider)
        let path = ["copies", key, "completed.json"]
        if let existing = try files.readIfPresent(path: path, maximumBytes: 256) {
            guard existing == Data(key.utf8) else {
                throw TractandaError("attachmentIntegrity", "Copy completion changed.")
            }
        } else {
            try files.writeImmutable(Data(key.utf8), path: path)
        }
        try files.synchronizeDirectory(Array(path.dropLast()))
        stagingByteQuota.complete(copyKey: key)
    }
    func prepareAttachmentCopy(_ request: CommitRequest) throws -> AttachmentCopyAdmission {
        guard request.action == .copy, let itemID = request.itemID,
            let revisionID = request.expectedRevisionID
        else { throw TractandaError("invalidArguments", "Copy requires an item and expected revision.") }
        guard request.changes["attachments"] == nil, request.changes["attachmentText"] == nil,
            request.changes["attachmentDocument"] == nil,
            Set(request.unset).isDisjoint(with: ["attachments", "attachmentText", "attachmentDocument"])
        else {
            throw TractandaError("invalidArguments", "Reserved attachment fields cannot be forged.")
        }
        guard !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
            !request.operationID.contains("\0"),
            Set(request.unset).count == request.unset.count,
            Set(request.changes.keys).isDisjoint(with: request.unset),
            Self.managed.isDisjoint(with: request.changes.keys), Self.managed.isDisjoint(with: request.unset)
        else { throw TractandaError("invalidArguments", "Invalid copy intent.") }
        let uid = accessContext!.uid
        if try priorOperation(request.operationID, uid: uid) != nil {
            let result = try commit(request, allowBlockingAttachmentCopy: false)
            let key = AttachmentCopyPlan(
                actorUID: uid, request: request, originals: [], documents: [],
                targetIDs: [], representationIDs: [], byteQuota: 1
            ).key
            // Replay still authorizes the current target before operational cleanup.
            if (try? FileMetadata.read(at: root.appendingPathComponent("copies/" + key + "/intent.json")))
                != nil
            {
                try completeAttachmentCopyQuota(key: key)
            }
            return .replay(result)
        }
        let source = try get(itemID)
        guard source.revisionID == revisionID else {
            throw TractandaError("revisionConflict", "Copy source changed; reconcile before copying.")
        }
        let originals = try AttachmentDescriptor.descriptors(in: source.fields)
        let documents = try activeDocuments(in: source.fields, originals: originals)
        if originals.isEmpty { return .replay(try commit(request, allowBlockingAttachmentCopy: false)) }
        var estimate: Int64 = 0
        for amount in originals.map(\.byteCount)
            + documents.map({ $0.content?.totalEncodedBytes ?? Int64((try? JSON.encode($0).count) ?? 0) })
        {
            let next = estimate.addingReportingOverflow(amount)
            guard !next.overflow else { throw TractandaError("resourceLimit", "Copy byte count overflowed.") }
            estimate = next.partialValue
        }
        let files = DocumentContentFiles(
            root: root, ownerUID: ownerUID, minimumFreeBytes: attachmentUploadPolicy.minimumFreeBytes,
            availableBytes: attachmentCapacityProvider, stagingQuota: stagingByteQuota)
        var plan = AttachmentCopyPlan(
            actorUID: uid, request: request, originals: originals, documents: documents,
            targetIDs: try originals.map { _ in try makePersistentUUID().uuidString.lowercased() },
            representationIDs: try documents.map { _ in try makePersistentUUID().uuidString.lowercased() },
            byteQuota: attachmentUploadPolicy.maximumStagedBytes)
        var isResuming = false
        if let bytes = try files.readIfPresent(
            path: ["copies", plan.key, "intent.json"], maximumBytes: 16 * 1024 * 1024)
        {
            let prior = try JSON.decode(AttachmentCopyPlan.self, bytes)
            guard prior.actorUID == uid, try JSON.encode(prior.request) == JSON.encode(request),
                prior.originals == originals, prior.documents == documents
            else { throw TractandaError("operationMismatch", "Copy intent changed.") }
            plan = prior
            isResuming = true
        }
        try requireAttachmentStagingCapacity(additionalBytes: isResuming ? 0 : estimate)
        try plan.validate()
        return .prepared(
            AttachmentCopyWork(
                plan: plan, payloads: attachmentPayloads, documents: documentContents, files: files,
                stagingQuota: stagingByteQuota))
    }
    func finishAttachmentCopy(_ prepared: PreparedAttachmentCopy) throws -> CommitResult {
        let plan = prepared.plan
        guard plan.actorUID == accessContext!.uid else {
            throw TractandaError("forbidden", "Copy actor changed.")
        }
        if try priorOperation(plan.request.operationID, uid: plan.actorUID) != nil {
            return try commit(plan.request, allowBlockingAttachmentCopy: false)
        }
        let source = try get(plan.request.itemID!)
        guard source.revisionID == plan.request.expectedRevisionID else {
            throw TractandaError("revisionConflict", "Copy source changed; prepared bytes are retained.")
        }
        guard try AttachmentDescriptor.descriptors(in: source.fields) == plan.originals,
            try activeDocuments(in: source.fields, originals: plan.originals) == plan.documents,
            prepared.originals.count == plan.originals.count, prepared.documents.count == plan.documents.count
        else { throw TractandaError("attachmentIntegrity", "Prepared copy bindings changed.") }
        guard prepared.signatures.count == prepared.originals.count else {
            throw TractandaError("attachmentIntegrity", "Prepared copy proof count changed.")
        }
        for (index, original) in prepared.originals.enumerated() {
            try Task.checkCancellation()
            _ = try withAccess(forUID: plan.actorUID) { try get(plan.request.itemID!) }
            try attachmentPayloads.restoreVerifiedSignature(original, expected: prepared.signatures[index])
            try attachmentPayloads.publish(descriptor: original, requireVerifiedStage: true)
        }
        var copiedDocuments: [AttachmentDocumentRepresentation] = []
        for (index, document) in plan.documents.enumerated() {
            guard
                let original = plan.originals.firstIndex(where: { $0.attachmentID == document.attachmentID })
            else { throw TractandaError("documentIntegrity", "Document original disappeared from its copy.") }
            let content = try documentContents.publishPrepared(prepared.documents[index])
            copiedDocuments.append(
                try AttachmentDocumentRepresentation(
                    representationID: plan.representationIDs[index],
                    attachmentID: prepared.originals[original].attachmentID,
                    source: document.source, extractedAt: document.extractedAt, identity: document.identity,
                    content: content))
        }
        try beforeAttachmentCopyCommitForTesting?()
        let result = try withAccess(forUID: plan.actorUID) {
            _ = try get(plan.request.itemID!)
            return try commitInternal(
                plan.request, preparedCopyOriginals: prepared.originals,
                preparedCopyDocuments: copiedDocuments)
        }
        try completeAttachmentCopyQuota(key: plan.key)
        return result
    }

    public func prepareCapture(_ preparation: CapturePreparation, actorUID: UInt32? = nil) throws
        -> CapturePlan
    {
        if accessContext == nil {
            return try withAccess(forUID: actorUID ?? ownerUID) {
                try prepareCapture(preparation, actorUID: actorUID)
            }
        }
        let request = preparation.request
        let base: Revision?
        if request.action == .create {
            guard request.itemID == nil, request.expectedRevisionID == nil, request.classID != nil else {
                throw TractandaError("invalidArguments", "Create needs classID and server-allocated IDs.")
            }
            base = nil
        } else {
            guard let id = request.itemID, let expected = request.expectedRevisionID else {
                throw TractandaError(
                    "invalidArguments", "Capture edits require itemID and expectedRevisionID.")
            }
            let current = try get(id)
            try requireEdit(
                current,
                changesPermissions: request.changes["permissions"] != nil
                    || request.unset.contains("permissions"))
            guard current.revisionID == expected else {
                throw TractandaError("revisionConflict", "The item changed; reconcile the capture edit.")
            }
            base = current
        }
        let at = preparation.at ?? Timestamp.now()
        let categories = try readableCategoryHeads()
        let decisions = try categoryOverrideIndex(categoryIDs: Set(categories.map(\.itemID)))
        return try InlineCapture.prepare(
            request, base: base, categories: categories, at: at,
            isExcluded: { id in
                guard let base else { return false }
                return try decisions.decision(for: base, categoryID: id)?.decision == "exclude"
            })
    }

    public func commitCapture(_ plan: CapturePlan, actorUID: UInt32? = nil) throws -> CommitResult {
        guard try JSON.encode(plan).count <= InlineCapture.maximumPlanBytes else {
            throw TractandaError("captureLimit", "Capture plan exceeds its transport budget.")
        }
        if accessContext == nil {
            return try withAccess(forUID: actorUID ?? ownerUID) {
                try commitCapture(plan, actorUID: actorUID)
            }
        }
        let uid = actorUID ?? accessContext!.uid
        guard uid == accessContext!.uid else {
            throw TractandaError("forbidden", "Capture actor must match the authenticated request.")
        }
        // Canonical receipt is checked before source/category guards: retries never reanchor.
        if try priorOperation(plan.commitRequest.operationID, uid: uid) != nil {
            return try commit(plan.commitRequest, actorUID: uid)
        }
        guard plan.canCommit else {
            throw TractandaError("captureReviewRequired", "Resolve every capture issue before committing.")
        }
        for (id, revisionID) in plan.categoryRevisionIDs {
            let category = try get(id)
            guard !category.isDeleted, category.fields["selection"] != nil,
                category.revisionID == revisionID
            else {
                throw TractandaError("captureChanged", "A captured category changed; prepare again.")
            }
        }
        let current = try prepareCapture(
            CapturePreparation(request: plan.request, at: plan.evaluatedAt), actorUID: uid)
        guard current == plan else {
            throw TractandaError(
                "captureChanged", "Capture resolution or permissions changed; prepare again.")
        }
        return try commit(plan.commitRequest, actorUID: uid)
    }

    public func commit(
        _ request: CommitRequest, actorUID: UInt32? = nil, allowBlockingAttachmentCopy: Bool = true
    ) throws -> CommitResult {
        guard !targetProvisioningPending else {
            throw PeerEnrollmentActivation.failure("Pending target cannot author ordinary content.")
        }
        guard request.changes["attachments"] == nil, !request.unset.contains("attachments") else {
            throw TractandaError(
                "invalidAttachment", "Use attachment lifecycle operations to change originals.")
        }
        guard request.changes["attachmentText"] == nil, !request.unset.contains("attachmentText") else {
            throw TractandaError(
                "invalidAttachmentText", "Use guarded extraction to change saved attachment representations.")
        }
        guard request.changes["attachmentDocument"] == nil, !request.unset.contains("attachmentDocument")
        else {
            throw TractandaError(
                "invalidDocumentOutput", "Use guarded extraction to change saved document representations.")
        }
        return try commitInternal(
            request, actorUID: actorUID, allowBlockingAttachmentCopy: allowBlockingAttachmentCopy)
    }

    private func commitInternal(
        _ request: CommitRequest, actorUID: UInt32? = nil, allowBlockingAttachmentCopy: Bool = true,
        preparedCopyOriginals: [AttachmentDescriptor]? = nil,
        preparedCopyDocuments: [AttachmentDocumentRepresentation]? = nil,
        indexedCorpus: IndexedCorpusStage? = nil
    ) throws -> CommitResult {
        if accessContext == nil {
            return try withAccess(forUID: actorUID ?? ownerUID) {
                try commitInternal(
                    request, actorUID: actorUID, allowBlockingAttachmentCopy: allowBlockingAttachmentCopy,
                    preparedCopyOriginals: preparedCopyOriginals,
                    preparedCopyDocuments: preparedCopyDocuments,
                    indexedCorpus: indexedCorpus
                )
            }
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
            if revisionProjectionEnabled {
                guard canReadProjection(previous.itemID) else {
                    throw TractandaError("forbidden", "Item access is denied.")
                }
            } else {
                guard let previousHead = try currentHead(previous.itemID), canRead(previousHead) else {
                    throw TractandaError("forbidden", "Item access is denied.")
                }
            }
            guard previous.fields["requestIdentity"]?.string == identity else {
                throw TractandaError(
                    "operationMismatch", "This operationID already committed a different edit.")
            }
            return CommitResult(
                revision: previous, wasReplayed: true, isIndexReady: index != nil, warnings: [],
                itemState: revisionProjectionEnabled ? (try? itemState(previous.itemID)) : nil)
        }
        try requireActivePublishingOrigin()
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
            fields.removeValue(forKey: "attachmentText")
            fields.removeValue(forKey: "attachmentDocument")
            // Copy owns independent originals; never share private source attachment identities.
            let originals = try AttachmentDescriptor.descriptors(in: base!.fields)
            guard allowBlockingAttachmentCopy || originals.isEmpty else {
                throw TractandaError(
                    "attachmentCopyRequiresJob",
                    "Attached-item copies require the forthcoming bounded copy job path.")
            }
            let copies =
                try preparedCopyOriginals
                ?? originals.map {
                    try attachmentPayloads.clone(
                        source: $0, newID: makePersistentUUID().uuidString.lowercased())
                }
            if !copies.isEmpty { fields["attachments"] = .list(copies.map(\.itemValue)) }
            let clonedByID = Dictionary(
                uniqueKeysWithValues: zip(originals, copies).map { ($0.attachmentID, $1) })
            let representations = try AttachmentTextRepresentation.representations(in: base!.fields)
            let remapped = try representations.filter { representation in
                originals.contains {
                    $0.attachmentID == representation.attachmentID
                        && $0.sha256 == representation.source.sha256
                        && $0.byteCount == representation.source.byteCount
                        && $0.mediaType == representation.source.mediaType
                }
            }.map { representation in
                guard let clone = clonedByID[representation.attachmentID],
                    clone.sha256 == representation.source.sha256,
                    clone.byteCount == representation.source.byteCount,
                    clone.mediaType == representation.source.mediaType
                else { return representation }
                return try representation.remapping(
                    attachmentID: clone.attachmentID,
                    representationID: makePersistentUUID().uuidString.lowercased())
            }
            if !remapped.isEmpty { fields["attachmentText"] = .list(remapped.map(\.itemValue)) }
            let documents = try activeDocuments(in: base!.fields, originals: originals)
            let remappedDocuments =
                try preparedCopyDocuments
                ?? documents.map { document in
                    guard let clone = clonedByID[document.attachmentID],
                        clone.sha256 == document.source.sha256, clone.byteCount == document.source.byteCount,
                        clone.mediaType == document.source.mediaType
                    else { return document }
                    return try documentContents.clone(
                        document, attachmentID: clone.attachmentID,
                        representationID: makePersistentUUID().uuidString.lowercased())
                }
            if !remappedDocuments.isEmpty {
                fields["attachmentDocument"] = .list(try remappedDocuments.map { try $0.itemValue })
            }
        }
        let now = publicationClockForTesting()
        let modifiedAt: String
        if let base, !isNew {
            let knownFloor = try index?.graphCatalogueRows(
                where: "WHERE item=? ORDER BY modified_ticks DESC,revision DESC",
                bindings: [base.itemID], limit: 1
            ).first?.modifiedAt
            modifiedAt = try RevisionPublicationClock.after(
                [base.modifiedAt] + (knownFloor.map { [$0] } ?? []), now: { now })
        } else {
            modifiedAt = now
        }
        let itemID = isNew ? try makePersistentUUID().uuidString.lowercased() : base!.itemID
        let revisionID = try makePersistentUUID().uuidString.lowercased()
        let existingItem = try currentHead(itemID)
        let existingItemCount = try index?.revisionCount(itemID: itemID) ?? 0
        let revisionItemCount = try index?.revisionCount(itemID: revisionID) ?? 0
        let existingRevision = try currentHead(revisionID)
        let existingRevisionLocation = try index?.revision(revisionID)
        guard !isNew || (existingItem == nil && existingItemCount == 0), existingRevisionLocation == nil,
            existingRevision == nil, revisionItemCount == 0, itemID != revisionID
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
        fields["modifiedAt"] = .date(modifiedAt)
        fields["actor"] = .text(actor)
        fields["operationID"] = .text(request.operationID)
        fields["requestIdentity"] = .text(identity)
        fields.removeValue(forKey: "revisionAncestry")
        if !isNew { fields["supersedes"] = .text(base!.revisionID) }
        for (name, value) in request.changes { fields[name] = value }
        for name in request.unset { fields.removeValue(forKey: name) }
        let isConfiguration = fields["classID"]?.string == AccessConfiguration.classID
        if revisionProjectionEnabled && accessConfigurationProofUnavailable {
            throw TractandaError(
                "configurationConflict", "Establish current store authority before publishing edits.")
        }
        if revisionProjectionEnabled && accessConfigurationAmbiguous && !isConfiguration
            && (isNew || request.changes["permissions"] != nil || request.unset.contains("permissions"))
        {
            throw TractandaError(
                "configurationConflict", "Resolve access divergence before creating or changing sharing.")
        }
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
        var revision = try Revision(fields: fields)
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
            if revisionProjectionEnabled, let base {
                guard
                    try feedback.revisionID == base.revisionID
                        || (try index?.withCatalogueScanBudget {
                            try index!.graphHasProperAncestor(
                                source: base.revisionID,
                                target: feedback.revisionID, progress: nil)
                        }) == true
                else {
                    throw TractandaError(
                        "invalidLearningFeedback",
                        "Feedback must refer to a causally earlier revision of this item.")
                }
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
        let localIdentity = try ReplicaIdentity.initialize(
            root: root, storeID: canonicalStoreIdentity(creatingIfMissing: false), ownerUID: ownerUID,
            hasModernOrigins: index?.hasModernRevisionOrigins() ?? false)
        replicaID = localIdentity.replicaID
        let semantic = RevisionMerge.semanticFields(revision)
        let oldSemantic = isNew ? [:] : base.map(RevisionMerge.semanticFields) ?? [:]
        let addressed = Set(request.changes.keys).union(request.unset)
        let changed = Set(semantic.keys).union(oldSemantic.keys).filter { semantic[$0] != oldSemantic[$0] }
        let normalized = isNew ? Set(semantic.keys) : Set(changed).union(addressed)
        let ancestry = try RevisionProvenance(
            kind: .authored, originReplicaID: localIdentity.replicaID,
            parents: isNew ? [] : [base!.revisionID],
            writtenFields: normalized.filter { semantic[$0] != nil }.sorted(),
            unsetFields: normalized.filter { semantic[$0] == nil }.sorted(), frontier: [])
        var emittedFields = revision.fields
        emittedFields["revisionAncestry"] = ancestry.itemValue
        revision = try Revision(fields: emittedFields, formatVersion: 2)
        let data = try RecordCodec.encode(revision)
        guard data.count <= min(8 * 1024 * 1024, canonicalRecordByteLimitForTesting) else {
            throw TractandaError(
                "resourceLimit", "Record exceeds its byte window, including metadata and retry intent.")
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
        if revisionProjectionEnabled {
            try beforeProjectionCommitAuthorityForTesting?()
            try withAccess(forUID: uid) {
                guard accessContext?.account?.name == context.account?.name else {
                    throw TractandaError(
                        "principalChanged", "Authenticated principal changed before publication.")
                }
                if let base {
                    let current = try get(base.itemID)
                    guard current.revisionID == request.expectedRevisionID else {
                        throw TractandaError(
                            "revisionConflict", "Current projection changed before publication.")
                    }
                    if request.action != .copy {
                        try requireEdit(
                            current,
                            changesPermissions: request.changes["permissions"] != nil
                                || request.unset.contains("permissions"))
                    }
                }
                if isConfiguration { try requireAdministrator() }
                if let value = revision.fields["permissions"], let fresh = accessContext {
                    let permissions = try ItemPermissions(value)
                    try permissions.validate(using: fresh.resolver)
                    if !isAdministrator, let account = fresh.account {
                        guard try permissions.allows(4, for: account, using: fresh.resolver),
                            try !isNew || fresh.resolver.userID(permissions.owner) == account.uid
                        else {
                            throw TractandaError(
                                "forbidden", "Current authority does not allow this publication.")
                        }
                    }
                }
                if isCategoryRecord {
                    guard try !knownCategoryConstraintConflicts(replacing: revision).contains(revision.itemID)
                    else {
                        throw TractandaError(
                            "categoryCycle", "Publication conflicts with known category constraints.")
                    }
                }
            }
        }
        guard let publicationIndex = index, try publicationIndex.acceptedGraphProofIsCurrent() else {
            throw TractandaError(
                "projectionRequired", "Accepted graph proof must be rebuilt before publication.")
        }
        let markerPreviouslyDirty = StoreCheckpoint.isDirty(root: root)
        let localAuthorityPackage = try sealLocalAuthority(
            revision, data: data, path: path, index: publicationIndex)
        try CanonicalReaderRequirement.beforePublication(
            root: root, ownerUID: ownerUID, format: revision.formatVersion,
            beforePersist: beforeCanonicalReaderRequirementForTesting)
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
            } ?? []), modifiedAt: revision.modifiedAt, provenance: ancestry)
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
            "schemaVersion", "revisionAncestry",
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
                try finishLocalAuthority(localAuthorityPackage, index: index)
                try index.appendValidatedLocal(
                    row: newLocation.catalogueRow(revisionID: revision.revisionID), revision: revision,
                    parent: isNew ? nil : base,
                    expectedRepresentativeID: isNew ? nil : base?.revisionID,
                    state: readyProjectionState(revision),
                    policies: [
                        .init(
                            revisionID: revision.revisionID, classID: revision.classID,
                            permissions: revision.fields["permissions"])
                    ], corpus: indexedCorpus)
                try index.execute("COMMIT")
                if isConfiguration, revisionProjectionEnabled {
                    try refreshCurrentAccessConfigurations(using: index)
                }
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
            warnings: warnings, itemState: revisionProjectionEnabled ? (try? itemState(revision.itemID)) : nil
        )
    }

    public func rebuildIndex() throws { try rebuildIndex(control: nil) }
    func rebuildIndex(control: RebuildControl?) throws {
        try requireAdministrator()
        rebuildControl = control
        defer { rebuildControl = nil }
        try control?.check()
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
        try attachmentPayloads.preparePlacement()
        try documentContents.preparePlacement()
        try control?.pulse(phase: "verifyingCanonicalClosure")
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
            if temporaryIsClosed, FileManager.default.fileExists(atPath: temporary.path) {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        let fresh = try ItemIndex(path: temporary.path, create: true)
        try recoveryCatalogueForTesting?(fresh)
        try fresh.execute("BEGIN IMMEDIATE")
        let statements = try fresh.makeRebuildStatements()
        defer { statements.close() }
        let recoveryPhases = try recover(
            staging: fresh, statements: statements, measurePhases: measureStartup)
        try control?.pulse(phase: "finalizingIndex")
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
        try control?.authorizePublication()
        try control?.pulse(phase: "publishingIndex")
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
        guard let installed = index, let validated = try installed.validatedCatalogue(identity: identity)
        else {
            throw TractandaError("projectionRequired", "Rebuilt catalogue checkpoint cannot be admitted.")
        }
        guard try installed.hasCompleteCurrentProjectionCheckpoint() else {
            throw TractandaError("projectionRequired", "Rebuilt current projection cache is incomplete.")
        }
        guard
            try installed.resumeAcceptedGraphProofFromCheckpoint(
                validated: validated, requireLinearProjection: !revisionProjectionEnabled)
        else {
            throw TractandaError("projectionRequired", "Rebuilt accepted graph proof cannot be resumed.")
        }
        installIndexFailureHandler(installed)
        try StoreCheckpoint.syncDirectory(indexDirectory)
        if let coordinator = peerIntake, replicaID != nil {
            try coordinator.withOperation(recovery: true) {
                try finishAuthorityDispositionEffects(coordinator: coordinator, index: installed)
                try ensureInitialAuthorityVisibility(coordinator: coordinator, index: installed)
                try drainAuthorityVisibility(coordinator: coordinator, index: installed)
            }
        }
        if StoreCheckpoint.isDirty(root: root) {
            try control?.authorizePublication()
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
        try rebuildControl?.pulse(phase: "synchronizingCanonicalDurability")
        try beforeCanonicalDurabilitySync?()
        func confirmedEntry() throws {
            try rebuildControl?.pulse(durabilityEntries: 1)
            try afterCanonicalSyncEntryForTesting?()
        }
        let itemsRoot = root.appendingPathComponent("items")
        var cursor: String?
        while true {
            let rows = try index.recoveryRowPage(after: cursor, limit: 128)
            if rows.isEmpty { break }
            for row in rows {
                try rebuildControl?.check()
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
                    defer { _ = close(descriptor) }
                    try rebuildControl?.check()
                    let result = fsync(descriptor)
                    guard result == 0 else {
                        throw TractandaError("recoveryError", "Cannot synchronize canonical record.")
                    }
                }
                try confirmedEntry()
                var directory = locationURL.deletingLastPathComponent()
                while directory.path.hasPrefix(itemsRoot.path + "/") {
                    try rebuildControl?.check()
                    if tractanda_path_read_only(directory.path) != 1 {
                        try StoreCheckpoint.syncDirectory(directory)
                    }
                    try confirmedEntry()
                    directory.deleteLastPathComponent()
                }
                cursor = row.revisionID
            }
        }
        try rebuildControl?.check()
        if tractanda_path_read_only(itemsRoot.path) != 1 { try StoreCheckpoint.syncDirectory(itemsRoot) }
        try confirmedEntry()
        try rebuildControl?.check()
        if tractanda_path_read_only(root.path) != 1 { try StoreCheckpoint.syncDirectory(root) }
        try confirmedEntry()
    }
}

// Metadata-only trusted peer intake. These methods are internal and have no Service route.
extension ItemStore {
    private func sealLocalAuthority(
        _ revision: Revision, data: Data, path: String, index: ItemIndex,
        additionalControls: [AuthorityRecord] = [], onSealed: (() -> Void)? = nil
    ) throws
        -> String?
    {
        try requireActivePublishingOrigin()
        guard let coordinator = peerIntake else { return nil }
        _ = try AuthorityRevision(originalBytes: data)
        guard !authorityCatchupActive else {
            throw TractandaError(
                "authorityReconciliationRequired",
                "Finish affected authority catch-up before freezing a new source cut.")
        }
        guard authorityExistingHistoryAdmitted else {
            throw TractandaError(
                "authorityBootstrapRequired",
                "Explicitly pin the existing history before authority-aware local publication.")
        }
        try CanonicalReaderRequirement.beforeAuthorityPublication(root: root, ownerUID: ownerUID)
        let provenance = try revision.provenance!
        func binding(_ id: String) throws -> ItemValue {
            guard let row = try index.revision(id) else {
                throw TractandaError("missingDependencies", "Local authority parent is missing.")
            }
            return .object([
                "itemID": .text(row.itemID), "revisionID": .text(id),
                "sha256": .text(row.digest.map { String(format: "%02x", $0) }.joined()),
            ])
        }
        try index.initializeAuthorityControlSchema()
        let controlActor = accessContext?.account?.name ?? "uid:\(accessContext?.uid ?? ownerUID)"
        let cutDraft = try coordinator.prepareSourceCut(
            index: index, origin: provenance.originReplicaID, actor: controlActor)
        let evidence: AuthorityRecord?
        if provenance.kind == .automaticMerge {
            evidence = nil
        } else {
            let context = accessContext
            let account = context?.account ?? (try? accounts.user(forUID: context?.uid ?? ownerUID))
            let principal = account?.name ?? "uid:\(context?.uid ?? ownerUID)"
            var groups: [String: ItemValue] = [:]
            var names = Set(currentAccessConfigurations.flatMap(\.groups))
            names.insert(AccessConfiguration.defaultAdministratorGroup)
            names.formUnion(currentAccessConfigurations.compactMap(\.administratorGroup))
            if let account { names.insert(account.primaryGroupName) }
            if let value = revision.fields["permissions"] {
                let permissions = try ItemPermissions(value)
                names.insert(permissions.group)
                names.formUnion(permissions.groups.keys)
            }
            for name in names {
                let actual = accessConfiguration?.groupAliases[name] ?? name
                if let group = try? accounts.groupID(named: actual), account?.groupIDs.contains(group) == true
                {
                    groups[actual] = .integer(Int64(group))
                }
            }
            if let account {
                var administrationGroups = Set(currentAccessConfigurations.compactMap(\.administratorGroup))
                administrationGroups.insert(AccessConfiguration.defaultAdministratorGroup)
                for name in administrationGroups {
                    if let gid = try? accounts.groupID(named: name), account.groupIDs.contains(gid) {
                        groups[name] = .integer(Int64(gid))
                    }
                }
            }
            var aliases: [String: ItemValue] = [:]
            for configuration in currentAccessConfigurations {
                for (name, target) in configuration.userAliases.merging(
                    configuration.groupAliases, uniquingKeysWith: { left, right in left == right ? left : "" }
                ) {
                    guard !target.isEmpty else {
                        throw TractandaError(
                            "resourceLimit", "Source alias namespaces need a separate authority profile.")
                    }
                    aliases[name] = .text(target)
                }
            }
            var admissions: [ItemValue] = []
            if let summary = try index.currentHeadSummary(classID: AccessConfiguration.classID) {
                admissions = [try binding(summary.revisionID)]
            }
            let frontier = try index.currentProjection(itemID: revision.itemID)?.state.frontier ?? []
            evidence = try AuthorityRecord(
                recordID: makePersistentUUID().uuidString.lowercased(),
                storeID: coordinator.storeID, originReplicaID: provenance.originReplicaID,
                kind: .authoredEvidence, parentAuthorityIDs: cutDraft.cut.map { [$0.recordID] } ?? [],
                actorPrincipal: principal, createdAt: Timestamp.now(),
                payload: [
                    "target": .object([
                        "itemID": .text(revision.itemID), "revisionID": .text(revision.revisionID),
                        "sha256": .text(AuthorityRecordCodec.sha256(data)),
                    ]),
                    "parents": .list(provenance.parents.map(ItemValue.text)),
                    "frontier": .list(frontier.map(ItemValue.text)),
                    "itemPolicies": .list(try provenance.parents.map(binding)),
                    "admissionPolicies": .list(admissions), "principal": .text(principal),
                    "sourceUID": .integer(Int64(context?.uid ?? ownerUID)), "groups": .object(groups),
                    "sourceAdministration": try sourceAdministration().itemValue,
                    "aliases": .object(aliases),
                    "rights": .list(
                        (context?.isAdministrator == true
                            ? ["administrator", "read", "write"] : ["read", "write"]).map(ItemValue.text)),
                    "evaluated": .boolean(true),
                    "intent": .object([
                        "writtenFields": .list(provenance.writtenFields.map(ItemValue.text)),
                        "unsetFields": .list(provenance.unsetFields.map(ItemValue.text)),
                    ]),
                    "acceptedAuthority": .list([]),
                    "sourceControl": .list(cutDraft.cut.map { [$0.itemValue] } ?? []),
                ])
        }
        let relative = String(path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
        guard relative.count == 8, relative[0] == "items" else {
            throw TractandaError("invalidAuthority", "Local publication path differs.")
        }
        var sealed = false
        do {
            return try coordinator.stageLocal(
                revision: revision, bytes: data, evidence: evidence,
                contextToken: peerIntakeContextToken(), arrivalMinute: relative[1...5].joined(separator: "/"),
                localItemPath: relative.joined(separator: "/"),
                controls: additionalControls
                    + coordinator.localControlRecords(
                        revision: revision, bytes: data, evidence: evidence,
                        draft: cutDraft, origin: provenance.originReplicaID, actor: controlActor,
                        causeKey: additionalControls.first(where: { $0.kind == .reconciliationWitness }).map {
                            try index.authorityReconciliationCauseKey(
                                itemID: revision.itemID, frontier: provenance.frontier,
                                causes: AuthorityStore.VerifiedReconciliationPlan(
                                    witness: AuthorityRecordCodec.decode(AuthorityRecordCodec.encode($0))
                                ).causes)
                        }),
                afterSeal: {
                    sealed = true
                    onSealed?()
                })
        } catch {
            if sealed { quarantineCheckpoint() }
            throw error
        }
    }
    private func finishLocalAuthority(_ packageID: String?, index: ItemIndex) throws {
        guard let packageID, let coordinator = peerIntake else { return }
        try index.initializeAuthoritySchema()
        try coordinator.retainSealed(packageID, index: index)
        try validateAuthorityControls(
            packageID: packageID, coordinator: coordinator, index: index, localUnit: true)
        try coordinator.journal.applied(packageID)
    }
    private func requirePeerIntake() throws -> PeerIntakeCoordinator {
        guard authorityIntakeEnabled, let peerIntake else {
            throw TractandaError(
                "peerIntakeDisabled", "Metadata intake is disabled; no listener or public import exists.")
        }
        return peerIntake
    }
    /// Actual private runtime readiness; reading this never enables clustering.
    private func peerClockRuntimeContext() throws -> String? {
        guard authorityIntakeEnabled, isCanonicalReady, let peerIntake,
            let configuration = try peerIntake.configuration(), !configuration.peers.isEmpty
        else { return nil }
        return AuthorityRecordCodec.sha256(try JSON.encode(configuration))
    }
    func preparePeerClockSample(
        monotonicNow: Double, interval: Double, configuration: PeerClockHealth.Configuration
    ) throws -> (String, PeerClockHealth.Configuration)? {
        guard let context = try peerClockRuntimeContext() else { return nil }
        if peerClockHealth == nil { peerClockHealth = try PeerClockHealth(configuration: configuration) }
        guard peerClockHealth?.schedule(monotonicNow: monotonicNow, isIdle: true, interval: interval) == .due,
            let health = peerClockHealth
        else { return nil }
        return (context, health.configuration)
    }
    func finishPeerClockSample(
        context: String, sample: PeerClockHealth.Sample?, monotonicNow: Double, nextInterval: Double
    ) throws {
        guard context == (try peerClockRuntimeContext()) else { return }
        if let sample {
            _ = peerClockHealth?.recordSample(
                monotonicNow: monotonicNow, offset: sample.offset, uncertainty: sample.uncertainty,
                nextInterval: nextInterval)
        } else {
            _ = peerClockHealth?.recordUnavailable(monotonicNow: monotonicNow, nextInterval: nextInterval)
        }
    }
    func peerIntakeContext(peerID: String) throws -> PeerPackage.Context {
        try requirePeerIntake().context(peerID: peerID)
    }
    func peerIntakeContextToken() throws -> String {
        let coordinator = try requirePeerIntake()
        let configuration = try coordinator.configuration()
        let configurationDigest = try configuration.map { AuthorityRecordCodec.sha256(try JSON.encode($0)) }
        return AuthorityRecordCodec.sha256(
            try JSON.encode(
                ItemValue.object([
                    "generation": .text(generation), "policyEpoch": .text(String(accessPolicyEpoch)),
                    "configuration": .text(configurationDigest ?? "unconfigured"),
                    "admissions": .text(try coordinator.originAdmissionFrontier()),
                ])))
    }
    var peerLifecycleBoundaryForTesting: ((PeerLifecycle.Boundary) throws -> Void)? {
        get { peerIntake?.lifecycleBoundaryForTesting }
        set { peerIntake?.lifecycleBoundaryForTesting = newValue }
    }
    func configurePeerIntake(peers: [PeerPackage.Context]) throws {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) { try configurePeerIntake(peers: peers) }
        }
        try requireAdministrator()
        let coordinator = try requirePeerIntake()
        guard peers.allSatisfy({ $0.peerID != "local" && $0.storeID == coordinator.storeID }) else {
            throw TractandaError("invalidPeerConfiguration", "Reserved peer name or foreign StoreID.")
        }
        let old = try coordinator.configuration()
        guard (old?.peers ?? []).allSatisfy({ peers.contains($0) }) else {
            throw TractandaError(
                "managedPeerLifecycleRequired",
                "Use managed credential rotation or explicit peer/origin retirement.")
        }
        guard
            !peers.contains(where: { candidate in
                (old?.lifecycle?.historicalContexts ?? []).contains(where: {
                    $0.peerID == candidate.peerID && $0.configurationDigest == candidate.configurationDigest
                })
            })
        else {
            throw TractandaError(
                "managedPeerLifecycleRequired", "A retired credential generation cannot be reused.")
        }
        try AuthorityStore.writeConfiguration(
            .init(
                profile: "tractanda.peer-configuration.v1", peers: peers, bootstrap: old?.bootstrap,
                lifecycle: old?.lifecycle, credentialBindings: old?.credentialBindings),
            root: root, files: coordinator.journal.files)
        generation = Identifier.make()
    }
    func requirePeerCredentialAdministrator() throws { try requireAdministrator() }
    func nativeCredentialRegistrationContext() throws -> String {
        guard accessContext != nil else {
            throw TractandaError("forbidden", "An authenticated administrator is required.")
        }
        try requireAdministrator()
        guard !targetProvisioningPending, isCanonicalReady else {
            throw TractandaError(
                "recoveryRequired", "Credential registration needs an activated, ready store.")
        }
        return try peerIntakeContextToken()
    }
    func registerNativePeerCredential(
        _ credential: PeerCredential, permittedOrigins: [String],
        expectedContextToken: String, operationID: String
    ) throws {
        _ = try nativeCredentialRegistrationContext()
        let binding = credential.binding
        let context = try PeerPackage.Context(
            peerID: binding.peerID, storeID: binding.storeID,
            configurationDigest: binding.configurationDigest, permittedOrigins: permittedOrigins)
        let previous = try requirePeerIntake().configuration()?.peers.first { $0.peerID == context.peerID }
        guard previous == nil || previous == context else {
            throw TractandaError(
                "managedPeerLifecycleRequired", "Use the separate reviewed lifecycle operation for rotation.")
        }
        try registerPeerCredential(
            credential, context: context,
            expectedContextToken: expectedContextToken, operationID: operationID)
    }
    // Trusted host-only registration. The caller supplies current authority context, never a wire key.
    var peerCredentialStagedForTesting: (() throws -> Void)? {
        get { peerIntake?.credentialStagedForTesting }
        set { peerIntake?.credentialStagedForTesting = newValue }
    }
    func registerPeerCredential(
        _ credential: PeerCredential, context: PeerPackage.Context,
        expectedContextToken: String, operationID: String
    ) throws {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try registerPeerCredential(
                    credential, context: context,
                    expectedContextToken: expectedContextToken, operationID: operationID)
            }
        }
        try requireAdministrator()
        let coordinator = try requirePeerIntake()
        guard expectedContextToken == (try peerIntakeContextToken()) else {
            throw TractandaError("operationReviewRequired", "Peer registration context changed.")
        }
        _ = try AuthorityRecord.persistentID(.text(operationID))
        let binding = credential.binding
        let old = try coordinator.configuration()
        guard isCanonicalReady, authorityExistingHistoryAdmitted, !authorityCatchupActive,
            let index, binding.storeID == coordinator.storeID, binding.localReplicaID == replicaID,
            context.storeID == binding.storeID, context.peerID == binding.peerID,
            context.configurationDigest == binding.configurationDigest,
            context.permittedOrigins.contains(binding.remoteReplicaID),
            !(old?.lifecycle?.historicalContexts ?? []).contains(where: {
                $0.peerID == context.peerID && $0.configurationDigest == context.configurationDigest
            })
        else {
            throw TractandaError("invalidPeerCredential", "Private peer credential binding is not current.")
        }
        try requireActivePublishingOrigin()
        try requirePeerExchangeMembership(binding, index: index)
        // Reject conflicting rotations before writing any private material.
        let previous = old?.peers.first { $0.peerID == context.peerID }
        if let previous, previous != context {
            guard previous.storeID == context.storeID,
                previous.permittedOrigins == context.permittedOrigins,
                previous.configurationDigest != context.configurationDigest
            else { throw TractandaError("invalidPeerCredential", "Private peer rotation binding differs.") }
        }
        let commitment = try credential.commitment
        if previous == context, let committed = old?.credentialBindings?[context.peerID],
            committed != commitment
        {
            throw TractandaError("invalidPeerCredential", "Committed private pairing metadata differs.")
        }
        try PeerCredentialStore(files: coordinator.journal.files).stage(credential)
        try coordinator.credentialStagedForTesting?()
        if let previous, previous != context {
            try managePeerLifecycle(
                peerID: context.peerID, replacement: context,
                retiredOriginIDs: [], operationID: operationID, credentialCommitment: commitment)
        } else if old?.credentialBindings?[context.peerID] != commitment {
            var bindings = old?.credentialBindings ?? [:]
            bindings[context.peerID] = commitment
            try AuthorityStore.writeConfiguration(
                .init(
                    profile: "tractanda.peer-configuration.v1",
                    peers: previous == nil ? (old?.peers ?? []) + [context] : old!.peers,
                    bootstrap: old?.bootstrap, lifecycle: old?.lifecycle, credentialBindings: bindings),
                root: root, files: coordinator.journal.files)
            generation = Identifier.make()
        }
        // Read back through the same current-generation/membership gate used after restart.
        _ = try loadPeerCredential(peerID: context.peerID)
    }
    func loadPeerCredential(peerID: String, progress: @escaping () throws -> Void = {}) throws
        -> PeerCredential
    {
        try progress()
        let coordinator = try requirePeerIntake()
        let context = try coordinator.context(peerID: peerID)
        let credential = try PeerCredentialStore(files: coordinator.journal.files).load(
            peerID: peerID, configurationDigest: context.configurationDigest)
        guard try coordinator.configuration()?.credentialBindings?[peerID] == credential.commitment else {
            throw TractandaError("invalidPeerCredential", "Current private pairing metadata differs.")
        }
        return try withPeerExchange(binding: credential.binding, progress: progress) { _, _ in credential }
    }
    /// Explicit caller scope is mandatory; diagnostics never load or repair private credentials.
    func peerOperatorCanonicalStatus() throws -> PeerCanonicalStatus {
        guard accessContext != nil else {
            throw TractandaError("forbidden", "Peer status requires an authenticated administrator.")
        }
        try requireAdministrator()
        let storeID = try canonicalStoreIdentity(creatingIfMissing: false)
        let readiness: PeerCanonicalStatus.Readiness =
            targetProvisioningPending
            ? .pendingActivation
            : !authorityIntakeEnabled ? .authorityUnavailable : isCanonicalReady ? .ready : .recoveryRequired
        let disposed: Bool?
        if !targetProvisioningPending, authorityIntakeEnabled, isCanonicalReady, let index, let replicaID {
            disposed = try index.withCatalogueScanBudget { try index.peerOriginRetired(replicaID) }
        } else {
            disposed = nil
        }
        var configured: Int?
        var committed: Int?
        if authorityIntakeEnabled, let peerIntake {
            let configuration = try peerIntake.withOperation(maximumReadBytes: 1024 * 1024) {
                try peerIntake.configuration(readBudget: peerIntake.admissionReadBudget())
            }
            try configuration?.validateCredentialBindings()
            configured = configuration?.peers.count ?? 0
            committed = configuration?.credentialBindings?.count ?? 0
            guard configured! <= 256, committed! <= 256 else {
                throw TractandaError("resourceLimit", "Peer status pairing count exceeds its bound.")
            }
        }
        return .init(
            storeID: storeID, replicaID: replicaID, readiness: readiness,
            localDisposed: disposed, configuredPairingCount: configured, committedPairingCount: committed)
    }

    /// Serialized unattended reads consume existing committed authority; they never register keys.
    func peerRuntimeMaterial(progress: @escaping () throws -> Void = {}) throws
        -> PeerRuntimeSnapshot.Material
    {
        try progress()
        guard !targetProvisioningPending else {
            throw PeerEnrollmentActivation.failure("Pending target cannot load peer runtime credentials.")
        }
        guard isCanonicalReady, let index, let replicaID else {
            throw TractandaError("recoveryRequired", "Peer runtime requires verified canonical state.")
        }
        let coordinator = try requirePeerIntake()
        let configuration = try coordinator.configuration()
        try configuration?.validateCredentialBindings()
        let bindings = configuration?.credentialBindings ?? [:]
        guard bindings.count <= 256 else {
            throw TractandaError("resourceLimit", "Peer runtime credential limit exceeded.")
        }
        let peerIDs = bindings.keys.sorted()
        try index.withCatalogueScanBudget(progress: progress) {
            guard try !index.peerOriginRetired(replicaID) else {
                throw TractandaError("localReplicaRetired", "Local replica is retired from peer exchange.")
            }
        }
        var credentials: [PeerCredential] = []
        for peerID in peerIDs {
            try progress()
            do { credentials.append(try loadPeerCredential(peerID: peerID, progress: progress)) } catch let
                error as TractandaError where error.code == "peerRetired"
            {
                // Only canonical retirement may omit a still-configured pairing. Missing or
                // malformed keys remain errors, never a fallback to an earlier snapshot.
            }
        }
        let security = try index.withCatalogueScanBudget(progress: progress) {
            try peerExchangeSecurityBinding(coordinator: coordinator, index: index)
        }
        try progress()
        return try .init(
            credentials: credentials, securityToken: security,
            storeID: coordinator.storeID, replicaID: replicaID)
    }
    func validatePeerRuntimeMaterial(
        _ expected: PeerRuntimeSnapshot.Material, progress: @escaping () throws -> Void
    ) throws {
        try expected.requireCurrent(peerRuntimeMaterial(progress: progress))
    }
    func beginPeerIntake(context: PeerPackage.Context, manifestBytes: Data) throws -> PeerPackage.Status {
        let coordinator = try requirePeerIntake()
        try coordinator.requireIntakeCurrent(context, packageID: nil)
        // Reject retired/foreign wire framing before initial ReplicaID or reader-floor writes.
        let manifest = try PeerPackage.decode(PeerPackage.Manifest.self, manifestBytes)
        try manifest.validate()
        if let scope = coordinator.provisioningScope {
            guard [scope.record.baseline, scope.record.proof.manifest].contains(manifest) else {
                throw PeerEnrollmentActivation.failure(
                    "Provisioning manifest differs from its two exact approved packages.")
            }
        }
        try coordinator.requireIntakeCurrent(context, packageID: manifest.packageID)
        if try coordinator.journal.files.readIfPresent(
            path: ["authority", "intake", manifest.packageID, "begin.json"],
            maximumBytes: PeerPackage.maximumPageBytes) != nil
        {
            _ = try coordinator.journal.intakeState(context: context, packageID: manifest.packageID)
        }
        guard manifest.storeID == context.storeID else {
            throw TractandaError("invalidPeerPackage", "Store binding differs.")
        }
        let identity = try ReplicaIdentity.initialize(
            root: root, storeID: coordinator.storeID,
            ownerUID: ownerUID, hasModernOrigins: index?.hasModernRevisionOrigins() ?? false)
        replicaID = identity.replicaID
        try CanonicalReaderRequirement.beforeAuthorityPublication(root: root, ownerUID: ownerUID)
        return try coordinator.journal.begin(context: context, manifestBytes: manifestBytes)
    }
    func appendPeerObject(
        context: PeerPackage.Context, packageID: String, object: PeerPackage.Object,
        offset: Int, bytes: Data
    ) throws -> PeerPackage.Status {
        let coordinator = try requirePeerIntake()
        try coordinator.requireIntakeCurrent(context, packageID: packageID)
        try coordinator.journal.requireCurrentProfile(packageID)
        _ = try coordinator.journal.intakeState(context: context, packageID: packageID)
        return try coordinator.journal.append(
            context: context, packageID: packageID, object: object, offset: offset, bytes: bytes)
    }
    func inspectPeerIntake(context: PeerPackage.Context, packageID: String) throws
        -> PeerPackage.IntakeState
    {
        let coordinator = try requirePeerIntake()
        try coordinator.requireIntakeCurrent(context, packageID: packageID)
        let state = try coordinator.journal.intakeState(
            context: context, packageID: packageID, recoveryRequired: !isCanonicalReady)
        if state.phase == .applied {
            _ = try coordinator.journal.status(packageID)
            if let index { try coordinator.completeDocumentCorpus(packageID: packageID, index: index) }
        }
        return state
    }
    func resumePeerIntake(
        context: PeerPackage.Context, packageID: String, cursor: PeerPackage.ResumeCursor? = nil,
        limit: Int = 128, progress: (() throws -> Void)? = nil
    ) throws -> PeerPackage.ResumePage {
        let coordinator = try requirePeerIntake()
        guard let index else {
            throw TractandaError("indexUnavailable", "Resume requires the retained inventory.")
        }
        return try index.withCatalogueScanBudget(reusingActiveBudget: true) {
            try coordinator.resume(
                context: context, packageID: packageID, index: index, cursor: cursor, limit: limit,
                recoveryRequired: !isCanonicalReady,
                progress: {
                    try index.checkCatalogueScanProgress()
                    try progress?()
                })
        }
    }
    func capturePeerInventory(
        context: PeerPackage.Context, after checkpoint: PeerInventory.CompletionCheckpoint? = nil
    ) throws -> PeerInventory.Boundary {
        let coordinator = try requirePeerIntake()
        try coordinator.requireCurrent(context)
        guard let index else {
            throw TractandaError("indexUnavailable", "Inventory requires retained metadata.")
        }
        return try index.withCatalogueScanBudget(reusingActiveBudget: true) {
            try PeerInventory.capture(
                context: context, after: checkpoint, coordinator: coordinator, index: index)
        }
    }
    func peerInventoryPage(
        context: PeerPackage.Context, boundary: PeerInventory.Boundary,
        cursor: PeerInventory.Cursor? = nil, limit: Int = 128,
        limits: PeerInventory.Limits = .init(), progress: (() throws -> Void)? = nil
    ) throws -> PeerInventory.Page {
        let coordinator = try requirePeerIntake()
        try coordinator.requireCurrent(context)
        guard let index else {
            throw TractandaError("indexUnavailable", "Inventory requires retained metadata.")
        }
        return try index.withCatalogueScanBudget(reusingActiveBudget: true) {
            try PeerInventory.page(
                context: context, boundary: boundary, cursor: cursor, limit: limit,
                coordinator: coordinator, index: index, evaluationsAvailable: isCanonicalReady,
                limits: limits, progress: progress)
        }
    }
    func withPeerLogicalVerification<T>(_ owner: String?, _ body: () throws -> T) throws -> T {
        guard let originals = try requirePeerIntake().journal.originals else { return try body() }
        return try originals.withLogicalVerificationOwner(owner, body)
    }
    func observePeerOriginalReadsForTesting<T>(
        _ observer: @escaping (PeerPackage.Object, Int) -> Void,
        body: () throws -> T
    ) throws -> T {
        let originals = try requirePeerIntake().journal.originals
        let previous = originals?.didReadForTesting
        originals?.didReadForTesting = observer
        defer { originals?.didReadForTesting = previous }
        return try body()
    }
    /// A finite target owner scopes cancellation across real synchronous work, never a network task.
    func withTargetEnrollmentControl<T>(_ check: @escaping () throws -> Void, body: () throws -> T) throws
        -> T
    {
        guard targetProvisioningScope != nil, !targetEnrollmentControlActive else {
            throw TractandaError("invalidTargetProtocol", "Target control owner is already active or absent.")
        }
        let coordinator = try requirePeerIntake()
        let previous = try requirePeerIntake().progress
        targetEnrollmentControlActive = true
        coordinator.progress = {
            try check()
            try previous?()
        }
        defer {
            coordinator.progress = previous
            targetEnrollmentControlActive = false
        }
        try check()
        return try body()
    }
    /// Synchronous downward-only probe; never retained by verification work or wire state.
    func withPeerReadBudgetForTesting<T>(
        _ maximumBytes: UInt64, pageLimit: Int? = nil, consumed: (UInt64) -> Void,
        body: () throws -> T
    ) throws -> T {
        let coordinator = try requirePeerIntake()
        guard maximumBytes > 0, maximumBytes <= coordinator.journal.limits.maximumReadBytes,
            pageLimit.map({ (1...128).contains($0) }) ?? true
        else {
            throw TractandaError(
                "invalidArguments", "Testing read allowance must narrow the existing operation bound.")
        }
        let previousPageLimit = targetEnrollmentPageLimitForTesting
        if let pageLimit { targetEnrollmentPageLimitForTesting = pageLimit }
        defer { targetEnrollmentPageLimitForTesting = previousPageLimit }
        return try coordinator.withOperation(maximumReadBytes: maximumBytes) {
            defer { consumed(coordinator.operationReadBytesForTesting) }
            return try body()
        }
    }
    func releasePeerLogicalVerification(_ owner: String) {
        peerIntake?.journal.originals?.releaseLogicalVerification(owner)
        peerIntake?.documentVerification?.releaseLogicalVerification(owner)
    }
    func peerSyncWork(
        binding: PeerExchangeBinding, security: String,
        replacement: PeerSyncWork? = nil
    ) throws -> PeerSyncWork {
        let files = try requirePeerIntake().journal.files
        let work = PeerSyncWorkStore(files: files)
        if let replacement { return try work.save(replacement, binding: binding, security: security) }
        return try work.load(binding: binding, security: security)
    }
    func peerNeedsTransfer(
        context: PeerPackage.Context, objects: [PeerPackage.Object], after: Int = 0,
        limits: PeerNeedsTransfer.Limits = .init(), progress: @escaping () throws -> Void
    ) throws -> PeerNeedsTransfer.Page {
        let coordinator = try requirePeerIntake()
        guard isCanonicalReady, let index else {
            throw TractandaError("recoveryRequired", "Comparison requires verified canonical state.")
        }
        return try coordinator.withOperation(maximumReadBytes: limits.maximumReadBytes) {
            try coordinator.requireCurrent(context, readBudget: coordinator.admissionReadBudget())
            return try index.withCatalogueScanBudget(progress: progress, reusingActiveBudget: true) {
                try PeerNeedsTransfer.compare(
                    objects, coordinator: coordinator, index: index,
                    after: after, limits: limits, progress: progress)
            }
        }
    }
    /// Private synchronous metadata export. A trusted future gateway must use this Store owner.
    func withPeerExchange<T>(
        binding: PeerExchangeBinding, expectedSecurity: String? = nil,
        progress: @escaping () throws -> Void,
        _ body: (PeerPackage.Context, String) throws -> T
    ) throws -> T {
        try progress()
        guard !targetProvisioningPending else {
            throw PeerEnrollmentActivation.failure("Pending target cannot exchange ordinary peer traffic.")
        }
        let coordinator = try requirePeerIntake()
        let context = try coordinator.context(peerID: binding.peerID)
        let committedCredential = try coordinator.configuration()?.credentialBindings?[binding.peerID]
        guard
            try committedCredential == nil || committedCredential == PeerCredential.commitment(for: binding),
            context.storeID == binding.storeID,
            context.configurationDigest == binding.configurationDigest,
            replicaID == binding.localReplicaID,
            context.permittedOrigins.contains(binding.remoteReplicaID)
        else {
            throw TractandaError("peerConfigurationChanged", "Authenticated pairing is not current.")
        }
        guard isCanonicalReady, let index else {
            throw TractandaError("recoveryRequired", "Peer exchange requires verified canonical state.")
        }
        return try index.withCatalogueScanBudget(progress: progress) {
            try requirePeerExchangeMembership(binding, index: index)
            let security = try peerExchangeSecurityBinding(coordinator: coordinator, index: index)
            guard expectedSecurity == nil || expectedSecurity == security else {
                throw TractandaError(
                    "peerConfigurationChanged", "Peer exchange policy/configuration changed.")
            }
            let response = try body(context, security)
            // This very intake may activate a removal. Durable work remains committed, but
            // normal data must not leave through the now-retired connection afterward.
            try requirePeerExchangeMembership(binding, index: index)
            try progress()
            return response
        }
    }
    private func requirePeerExchangeMembership(_ binding: PeerExchangeBinding, index: ItemIndex) throws {
        guard try !index.peerOriginRetired(binding.localReplicaID) else {
            throw TractandaError("localReplicaRetired", "Local replica is retired from peer exchange.")
        }
        guard try !index.peerOriginRetired(binding.remoteReplicaID) else {
            throw TractandaError("peerRetired", "Authenticated remote replica is retired.")
        }
    }
    private func peerExchangeSecurityBinding(
        coordinator: PeerIntakeCoordinator, index: ItemIndex,
        excludingAdmission: AuthorityBinding? = nil, configurationOverride: Data? = nil
    ) throws
        -> String
    {
        let configuration =
            try configurationOverride ?? coordinator.configuration().map { try JSON.encode($0) } ?? Data()
        var retirements: [AuthorityBinding] = []
        try coordinator.foreignRetirements { retirements.append($0.root) }
        retirements.sort { $0.recordID < $1.recordID }
        return AuthorityRecordCodec.sha256(
            try JSON.encode(
                ItemValue.object([
                    "configuration": .text(AuthorityRecordCodec.sha256(configuration)),
                    "policies": .list(try index.peerExportPolicyBinding().map(ItemValue.text)),
                    "retirements": .list(retirements.map(\.itemValue)),
                    "admissions": .text(
                        try coordinator.originAdmissionFrontier(excluding: excludingAdmission)),
                ])))
    }
    private func withPeerExport<T>(
        context: PeerPackage.Context, progress: (() throws -> Void)? = nil,
        _ body: (PeerExportPlan) throws -> T
    ) throws -> T {
        let coordinator = try requirePeerIntake()
        try coordinator.requireCurrent(context)
        guard isCanonicalReady, let index else {
            throw TractandaError("recoveryRequired", "Export requires current verified canonical state.")
        }
        return try index.withCatalogueScanBudget(reusingActiveBudget: true) {
            let binding = try peerExchangeSecurityBinding(coordinator: coordinator, index: index)
            return try coordinator.withOperation {
                let plan = PeerExportPlan(
                    coordinator: coordinator, index: index, context: context,
                    securityBinding: binding, progress: progress)
                plan.afterBoundaryForTesting = peerExportBoundaryForTesting
                return try body(plan)
            }
        }
    }
    func beginPeerExport(
        context: PeerPackage.Context, planID: String, packageID: String,
        boundary: PeerInventory.Boundary, limits: PeerExportPlan.Limits = .init()
    ) throws -> PeerExportPlan.Handle {
        try withPeerExport(context: context) {
            try $0.begin(planID: planID, packageID: packageID, boundary: boundary, limits: limits)
        }
    }
    func peerExportExists(context: PeerPackage.Context, planID: String, packageID: String) throws -> Bool {
        try withPeerExport(context: context) { try $0.exists(planID: planID, packageID: packageID) }
    }
    func peerPendingIntakes(context: PeerPackage.Context, after: String?) throws
        -> (packages: [String], after: String?, complete: Bool)
    {
        let coordinator = try requirePeerIntake()
        try coordinator.requireCurrent(context)
        guard isCanonicalReady, let index else {
            throw TractandaError("recoveryRequired", "Pending inventory is not ready.")
        }
        let page = try index.authorityPendingPackagePage(after: after, limit: 16)
        var packages: [String] = []
        for package in page {
            guard let publication = try coordinator.journal.publication(package) else {
                throw TractandaError(
                    "peerRepairRequired", "An admitted pending receipt lost its publication proof.")
            }
            if publication.context == context { packages.append(package) }
        }
        return (packages, page.last, page.count < 16)
    }
    func peerSyncEpoch() throws -> String {
        guard isCanonicalReady, let index else {
            throw TractandaError("recoveryRequired", "Inventory is not ready.")
        }
        let state = try index.capturePeerInventory()
        return AuthorityRecordCodec.sha256(
            try JSON.encode(
                ItemValue.object([
                    "epoch": .text(state.epoch), "sequence": .integer(state.maximumSequence),
                ])))
    }
    func reopenPeerExport(context: PeerPackage.Context, planID: String, packageID: String) throws
        -> PeerExportPlan.Handle
    {
        try withPeerExport(context: context) { try $0.reopen(planID: planID, packageID: packageID) }
    }
    func selectPeerExport(
        context: PeerPackage.Context, handle: PeerExportPlan.Handle,
        entries: [PeerInventory.Entry], finish: Bool = false
    ) throws -> PeerExportPlan.Status {
        try withPeerExport(context: context) { try $0.select(handle, entries: entries, finish: finish) }
    }
    func stepPeerExport(
        context: PeerPackage.Context, handle: PeerExportPlan.Handle,
        window: PeerExportPlan.Window = .init(), progress: (() throws -> Void)? = nil
    ) throws -> PeerExportPlan.Status {
        try withPeerExport(context: context, progress: progress) { try $0.step(handle, window: window) }
    }
    func inspectPeerExport(context: PeerPackage.Context, handle: PeerExportPlan.Handle) throws
        -> PeerExportPlan.Status
    {
        try withPeerExport(context: context) { try $0.status(handle) }
    }
    func peerExportObjectPage(
        context: PeerPackage.Context, handle: PeerExportPlan.Handle,
        afterID: String = "", limit: Int = 128
    ) throws -> PeerExportPlan.ObjectPage {
        try withPeerExport(context: context) { try $0.objects(handle, afterID: afterID, limit: limit) }
    }
    func peerExportManifest(context: PeerPackage.Context, handle: PeerExportPlan.Handle) throws -> PeerPackage
        .Manifest?
    {
        try withPeerExport(context: context) { try $0.manifest(handle) }
    }
    func readPeerExport(
        context: PeerPackage.Context, handle: PeerExportPlan.Handle,
        object: PeerPackage.Object, offset: Int, maximumBytes: Int = PeerPackage.maximumChunkBytes,
        receiverKnown: PeerPackage.Object? = nil
    ) throws -> PeerExportPlan.Chunk {
        try withPeerExport(context: context) {
            try $0.read(
                handle, object: object, offset: offset,
                maximumBytes: maximumBytes, receiverKnown: receiverKnown)
        }
    }
    /// Bounded exact-original export for the later trusted transport adapter; no user endpoint.
    func peerMetadataObjects(revisionID: String) throws -> [(PeerPackage.Object, Data)] {
        let coordinator = try requirePeerIntake()
        guard let index, let item = try index.retainedAuthorityObject(id: revisionID),
            item.descriptor.kind == .item,
            try index.authorityDisposition(id: revisionID)?.disposition == .eligible
                || index.authorityHasLocalHistoryAdmission(revisionID: revisionID)
        else {
            throw TractandaError("notFound", "Accepted original is unavailable.")
        }
        return try coordinator.withOperation {
            try coordinator.exportControlClosure(revisionID: revisionID, index: index)
        }
    }
    private func authorityCurrentPolicies(_ itemID: String, index: ItemIndex) throws -> [Revision] {
        // A prior validated acceptance/control in this same intake may dirty the disposable
        // projection. Rebuild policy proof from accepted heads before evaluating its child.
        // Private validation must not publish a merge or a LOCAL visibility/exposure fact.
        if try index.currentProjection(itemID: itemID) == nil {
            // Evidence eligibility precedes catalogue promotion. A child must wait for
            // accepted per-item history rather than analyze an empty current-policy graph.
            guard try index.revisionCount(itemID: itemID) > 0 else {
                throw TractandaError("missingDependencies", "Current policy awaits accepted item history.")
            }
            _ = try prepareRecoveredProjection(itemID, using: index, deferMaterialization: true)
        }
        return try index.currentPolicyWitnesses(itemID: itemID).map { witness in
            guard let revision = try loadRevisionUnchecked(witness.revisionID) else {
                throw TractandaError("invalidAuthority", "Current authority witness is missing.")
            }
            return revision
        }
    }
    private func authorityOriginalsVerified(
        _ revision: Revision, coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws -> Bool {
        try authorityStorageVerified(revision.fields, coordinator: coordinator, index: index)
    }
    private func authorityStorageVerified(
        _ fields: [String: ItemValue], coordinator: PeerIntakeCoordinator, index: ItemIndex,
        corpusScope: String? = nil
    ) throws -> Bool {
        func verified(_ descriptor: AttachmentDescriptor) throws -> Bool {
            try attachmentPayloads.isVerified(descriptor) || coordinator.verifiedCanonicalOriginal(descriptor)
        }
        for descriptor in try AttachmentDescriptor.descriptors(in: fields) {
            if try !verified(descriptor) { return false }
        }
        for text in try AttachmentTextRepresentation.representations(in: fields) {
            try AttachmentTextDecoder.validate(text)
            guard let row = try index.retainedAuthorityObject(id: text.source.revisionID),
                row.descriptor.kind == .item
            else { return false }
            let source = try AuthorityRevision(originalBytes: coordinator.bytes(row)).revision
            guard source.itemID == text.source.itemID, source.revisionID == text.source.revisionID,
                let descriptor = try AttachmentDescriptor.descriptors(in: source.fields).first(where: {
                    $0.attachmentID == text.source.attachmentID
                }),
                descriptor.byteCount == text.source.byteCount, descriptor.sha256 == text.source.sha256,
                descriptor.mediaType == text.source.mediaType, try verified(descriptor)
            else { return false }
        }
        for document in try AttachmentDocumentRepresentation.representations(in: fields) {
            try AttachmentDocumentValidator.validate(document)
            guard let row = try index.retainedAuthorityObject(id: document.source.revisionID),
                row.descriptor.kind == .item
            else { return false }
            let source = try AuthorityRevision(originalBytes: coordinator.bytes(row)).revision
            guard source.itemID == document.source.itemID,
                let descriptor = try AttachmentDescriptor.descriptors(in: source.fields).first(where: {
                    $0.attachmentID == document.source.attachmentID
                }), descriptor.byteCount == document.source.byteCount,
                descriptor.sha256 == document.source.sha256,
                descriptor.mediaType == document.source.mediaType,
                try verified(descriptor),
                try coordinator.verifiedCanonicalDocument(document, index: index, corpusScope: corpusScope)
            else { return false }
        }
        return true
    }
    private func evaluateIncomingAuthority(
        _ node: AuthorityRevision, evidence: AuthorityRecord,
        coordinator: PeerIntakeCoordinator, index: ItemIndex,
        revalidatingAcceptedOriginal: Bool = false
    ) throws -> AuthorityStore.Evaluation {
        if try coordinator.retirementBlocks(node, index: index) {
            return .init(
                disposition: .held,
                reason:
                    "Retired-origin RevisionID is at or after the removal cutoff; exact administrator review required."
            )
        }
        if try node.revision.provenance?.kind == .resolution,
            try index.peerRetirementRecheckContains(node.revision.revisionID),
            try index.authorityHasLocalHistoryAdmission(revisionID: node.revision.revisionID),
            let binding = try index.authorityAppliedReviewControl(
                resolutionID: node.revision.revisionID, digest: node.sha256),
            let raw = try index.retainedAuthorityObject(id: binding.recordID),
            let plan = try authorityReviewPlan(
                for: .init(control: AuthorityRecordCodec.decode(coordinator.bytes(raw))),
                coordinator: coordinator, index: index),
            plan.resolution.sha256 == node.sha256,
            plan.evidence.record == evidence,
            try index.peerAuthorityIssuerPermits(plan.event.binding.recordID)
        {
            try validateHistoricalReviewAuthority(plan, coordinator: coordinator, index: index)
            let outcome = try coordinator.invalidationOutcome(node, evidence: evidence, index: index)
            return .init(
                disposition: outcome.denied ? .held : .eligible,
                reason: outcome.denied
                    ? "Current validated authority denies historical resolution restoration."
                    : "Exact previously admitted review history remains valid after timestamp authority recomputation."
            )
        }
        if let provenance = try node.revision.provenance, provenance.kind != .authored {
            return .init(
                disposition: .held,
                reason: "Foreign materialization/resolution requires the next intake profile.")
        }
        guard node.parents.count <= 1 else {
            throw TractandaError("invalidAuthority", "Ordinary authored intake needs one actual parent.")
        }
        if node.parents.isEmpty, try index.revisionCount(itemID: node.revision.itemID) > 0 {
            let exact = try index.revision(node.revision.revisionID)
            guard revalidatingAcceptedOriginal, exact?.itemID == node.revision.itemID,
                exact?.digest == Data(SHA256.hash(data: node.originalBytes))
            else {
                return .init(
                    disposition: .held, reason: "Another accepted root already exists for this item.")
            }
        }
        if let provenance = try node.revision.provenance,
            let operation = node.revision.fields["operationID"]?.string,
            let matches = try index.receipts(named: operation, localReplicaID: provenance.originReplicaID),
            matches.contains(where: {
                $0.actor == node.revision.fields["actor"]?.string && $0.revisionID != node.revision.revisionID
            })
        {
            return .init(
                disposition: .rejected,
                reason: "Origin/actor operation receipt collides with another original.")
        }
        if let parentID = node.parents.first {
            guard let parentRow = try index.retainedAuthorityObject(id: parentID) else {
                return .init(disposition: .missingDependencies, reason: "Actual parent is missing.")
            }
            let parent = try AuthorityRevision(originalBytes: coordinator.bytes(parentRow)).revision
            guard parent.itemID == node.revision.itemID,
                parent.fields["createdAt"] == node.revision.fields["createdAt"],
                try RevisionTimestamp(node.revision.modifiedAt) > RevisionTimestamp(parent.modifiedAt)
            else {
                throw TractandaError(
                    "invalidRevisionGraph", "Incoming authored parent identity/time differs.")
            }
            let old = RevisionMerge.semanticFields(parent)
            let new = RevisionMerge.semanticFields(node.revision)
            let addressed = Set(
                try node.revision.provenance!.writtenFields + node.revision.provenance!.unsetFields)
            guard Set(old.keys).union(new.keys).filter({ old[$0] != new[$0] }).allSatisfy(addressed.contains)
            else {
                throw TractandaError(
                    "invalidRevisionGraph", "Authored provenance omitted an actual snapshot change.")
            }
            let sourcePolicies = try AuthorityRecord.list(evidence.payload["itemPolicies"])
            let expectedFrontier =
                try parent.provenance?.kind == .automaticMerge ? parent.provenance!.frontier : [parentID]
            guard try AuthorityRecord.ids(evidence.payload["frontier"], maximum: 1024) == expectedFrontier
            else {
                throw TractandaError(
                    "invalidAuthority", "Source frontier differs from its actual accepted parent.")
            }
            // This initial profile accepts an exact parent policy, not an unrelated historical grant.
            guard sourcePolicies.count == 1,
                try AuthorityRecord.binding(sourcePolicies.first).revisionID == parentID
            else {
                return .init(
                    disposition: .held, reason: "Source policy context requires full frontier review.")
            }
        }
        try coordinator.validatePolicyCut(evidence, index: index)
        let cut = try coordinator.sourceControl(evidence)!
        let outcome = try coordinator.invalidationOutcome(node, evidence: evidence, index: index)
        if outcome.denied {
            return .init(
                disposition: .held,
                reason:
                    "A validated revocation did not accept this original in its PRE cut; later grants cannot approve it."
            )
        }
        let currentPolicies: [Revision]
        if node.parents.isEmpty, node.revision.classID == "Item",
            try index.peerItemRootHasNoLocalPolicyHistory(itemID: node.revision.itemID)
        {
            currentPolicies = []
        } else {
            currentPolicies = try authorityCurrentPolicies(node.revision.itemID, index: index)
        }
        let evaluator = RuntimeAuthorityEvaluator(
            accounts: accounts,
            currentConfigurations: currentAccessConfigurations.isEmpty
                ? accessConfiguration.map { [$0] } ?? [] : currentAccessConfigurations,
            currentItemPolicies: currentPolicies,
            ownerUID: ownerUID,
            loadBinding: { try coordinator.bindingAtCut($0, cut: cut, index: index) })
        return try evaluator.evaluate(
            node, evidence: evidence,
            allowPolicy: node.revision.classID == AccessConfiguration.classID,
            historicalPreserved: outcome.preserved,
            originalsVerified: authorityOriginalsVerified(
                node.revision, coordinator: coordinator, index: index))
    }
    private func evaluateAuthorityMaterialization(
        _ node: AuthorityRevision,
        coordinator: PeerIntakeCoordinator, index: ItemIndex,
        requireAcceptanceCut: Bool = true
    ) throws -> AuthorityStore.Evaluation {
        guard try node.revision.provenance?.kind == .automaticMerge,
            node.parents.allSatisfy({ (try? index.revision($0)) != nil })
        else {
            return .init(
                disposition: .missingDependencies,
                reason: "Reconciliation needs its actual eligible parents and controls.")
        }
        if requireAcceptanceCut,
            try index.authorityAcceptanceControl(revisionID: node.revision.revisionID) == nil
        {
            return .init(
                disposition: .missingDependencies,
                reason:
                    "Materialization needs its validated source acceptance control before local visibility.")
        }
        guard let raw = try index.retainedAuthorityObject(id: node.revision.revisionID) else {
            return .init(disposition: .missingDependencies, reason: "Reconciliation original is missing.")
        }
        do {
            try index.validatePeerMaterialization(
                row: authorityCatalogueRow(raw, node: node), revision: node,
                loadVerified: { row in
                    try PooledCanonicalRecord.read(row: row, root: self.root, ownerUID: self.ownerUID)
                },
                limits: revisionProjectionLimits, progress: coordinator.progress)
        } catch let error as TractandaError
            where ["invalidAuthority", "invalidRevisionGraph", "invalidMergeTimestamp"].contains(error.code)
        {
            return .init(disposition: .held, reason: "Reconciliation context/payload proof requires review.")
        }
        return .init(
            disposition: .eligible,
            reason: "Validated zero-write reconciliation in its own eligible parent context.")
    }
    private func evaluateAuthoritySource(
        _ node: AuthorityRevision, evidence: AuthorityRecord,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws -> AuthorityStore.Evaluation {
        try coordinator.validatePolicyCut(evidence, index: index)
        let cut = try coordinator.sourceControl(evidence)!
        return try RuntimeAuthorityEvaluator(
            accounts: accounts, currentConfigurations: [], currentItemPolicies: [],
            ownerUID: ownerUID, loadBinding: { try coordinator.bindingAtCut($0, cut: cut, index: index) }
        )
        .evaluate(
            node, evidence: evidence, sourceOnly: true,
            allowPolicy: node.revision.classID == AccessConfiguration.classID,
            originalsVerified: authorityOriginalsVerified(
                node.revision, coordinator: coordinator, index: index))
    }
    private func authoritySourceWitness(
        _ node: AuthorityRevision, coordinator: PeerIntakeCoordinator,
        index: ItemIndex
    ) throws -> AuthorityRecord? {
        if let selected = try index.authorityEvidence(revisionID: node.revision.revisionID) {
            return try AuthorityRecordCodec.decode(coordinator.bytes(selected)).record
        }
        let admitted = try index.authorityDisposition(id: node.revision.revisionID)?.disposition == .eligible
        let elected = try coordinator.electEvidence(node, index: index) { node, evidence in
            if admitted {
                if try coordinator.sourceControl(evidence) != nil {
                    try coordinator.validatePolicyCut(evidence, index: index)
                }
                return .init(
                    disposition: .eligible,
                    reason: "Exact original was already admitted by sealed publication or pinned baseline.")
            }
            return try self.evaluateAuthoritySource(
                node, evidence: evidence, coordinator: coordinator, index: index)
        }
        guard elected.disposition == .eligible, let id = elected.evidenceID,
            let row = try index.retainedAuthorityObject(id: id)
        else { return nil }
        return try AuthorityRecordCodec.decode(coordinator.bytes(row)).record
    }
    private func validateAuthorityControls(
        packageID: String?, coordinator: PeerIntakeCoordinator,
        index: ItemIndex, recovering: Bool = false, localUnit: Bool = false
    ) throws {
        try index.initializeAuthorityControlSchema()
        var witnessPackages = Set(packageID.map { [$0] } ?? [])
        for _ in 0..<2 {
            var changed = true
            var work = 0
            while changed {
                changed = false
                var after: String?
                while true {
                    let rows = try index.authorityReadyControlPage(
                        packageID: localUnit ? packageID : nil, after: after, limit: 128)
                    if rows.isEmpty { break }
                    for row in rows {
                        after = row.descriptor.id
                        authorityControlInspectedForTesting?(row.descriptor.id)
                        work += 1
                        try coordinator.progress?()
                        guard work <= coordinator.journal.limits.maximumWork else {
                            throw TractandaError("resourceLimit", "Control validation work exhausted.")
                        }
                        let verified = try AuthorityRecordCodec.decode(coordinator.bytes(row))
                        let plan = try AuthorityStore.VerifiedControlPlan(control: verified)
                        let isLocal = try coordinator.hasLocalPublicationReceipt(
                            objectID: row.descriptor.id,
                            origin: verified.record.originReplicaID, index: index)
                        guard
                            try isLocal
                                || coordinator.freshReceipt(
                                    row.descriptor.id,
                                    origin: verified.record.originReplicaID, index: index) != nil
                        else { continue }
                        var valid = true
                        let reviewPlan: AuthorityStore.VerifiedReviewPlan?
                        do {
                            reviewPlan = try authorityReviewPlan(
                                for: plan, coordinator: coordinator, index: index)
                        } catch let error as TractandaError
                            where !isLocal
                            && ["missingDependencies", "invalidAuthority"].contains(error.code)
                        { continue }
                        if let baseline = plan.bootstrap {
                            if let prior = plan.localParent {
                                let old = try AuthorityStore.VerifiedControlPlan(
                                    control: coordinator.control(prior, index: index))
                                guard old.bootstrap == baseline else {
                                    throw TractandaError(
                                        "invalidAuthority",
                                        "A control chain cannot replace its initial baseline.")
                                }
                            } else if !isLocal {
                                guard let retained = try index.retainedAuthorityObject(id: baseline.recordID),
                                    retained.descriptor.kind == .authority,
                                    retained.descriptor.sha256 == baseline.sha256
                                else { continue }
                                let original = try coordinator.control(baseline, index: index)
                                guard
                                    try coordinator.freshReceipt(
                                        baseline.recordID, origin: original.record.originReplicaID,
                                        index: index) != nil
                                else { continue }
                                try index.execute("SAVEPOINT source_baseline")
                                do {
                                    try coordinator.seedBootstrap(
                                        .init(
                                            recordID: baseline.recordID, sha256: baseline.sha256,
                                            actor: original.record.actorPrincipal), index: index,
                                        existingOnly: true)
                                    try index.execute("RELEASE source_baseline")
                                } catch let error as TractandaError where error.code == "missingDependencies"
                                {
                                    try? index.execute("ROLLBACK TO source_baseline")
                                    try? index.execute("RELEASE source_baseline")
                                    continue
                                } catch {
                                    try? index.execute("ROLLBACK TO source_baseline")
                                    try? index.execute("RELEASE source_baseline")
                                    throw error
                                }
                            }
                        }
                        var activateReview: (AuthorityStore.VerifiedReviewPlan, String)?
                        if let review = reviewPlan {
                            if !isLocal {
                                let historicalActivation = try coordinator.foreignReviewActivation(
                                    review.event.binding)
                                guard
                                    try (recovering && historicalActivation != nil)
                                        || index.peerAuthorityIssuerPermits(review.event.binding.recordID)
                                else { continue }
                                guard
                                    try AttachmentDescriptor.descriptors(
                                        in: review.resolution.revision.fields
                                    ).isEmpty,
                                    try AttachmentDocumentRepresentation.representations(
                                        in: review.resolution.revision.fields
                                    ).isEmpty
                                else { continue }
                                do {
                                    try validateHistoricalReviewAuthority(
                                        review, coordinator: coordinator, index: index)
                                    guard
                                        let decisionReceipt = try coordinator.freshReceipt(
                                            review.event.binding.recordID,
                                            origin: review.event.record.record.originReplicaID, index: index),
                                        let evidenceReceipt = try coordinator.freshReceipt(
                                            review.evidence.record.recordID,
                                            origin: review.evidence.record.originReplicaID, index: index),
                                        decisionReceipt.permittedOrigin, evidenceReceipt.permittedOrigin
                                    else { continue }
                                    let saved = try coordinator.foreignReviewActivation(review.event.binding)
                                    if let saved {
                                        guard saved.control == plan.binding,
                                            let receipt = try index.authorityReceipt(
                                                objectID: review.event.binding.recordID,
                                                packageID: saved.packageID),
                                            try coordinator.receiptContextPermits(
                                                receipt, origin: review.event.record.record.originReplicaID,
                                                index: index)
                                        else {
                                            throw TractandaError(
                                                "invalidAuthority",
                                                "Foreign review activation lost its exact control/receipt.")
                                        }
                                    } else {
                                        if recovering { continue }
                                        let raw = try index.retainedAuthorityObject(
                                            id: review.event.resolution.revisionID)!
                                        try withSharedReviewValidation(
                                            review, coordinator: coordinator, index: index
                                        ) {
                                            let policies = try authorityCurrentPolicies(
                                                review.resolution.revision.itemID, index: index)
                                            _ = try index.previewAuthorityReview(
                                                plan: review,
                                                resolutionRow: authorityCatalogueRow(
                                                    raw, node: review.resolution),
                                                loadVerified: {
                                                    try PooledCanonicalRecord.read(
                                                        row: $0, root: self.root, ownerUID: self.ownerUID)
                                                },
                                                limits: revisionProjectionLimits,
                                                progress: coordinator.progress,
                                                validate: { context in
                                                    try self.validateAuthorityReviewResolution(
                                                        review.resolution.revision, context: context,
                                                        policies: policies, using: index)
                                                },
                                                allowConcurrentCurrent: true)
                                        }
                                        activateReview = (review, decisionReceipt.packageID)
                                    }
                                    if recovering {
                                        if try !index.authorityReviewControlAllows(
                                            control: plan.binding,
                                            revisionID: review.event.resolution.revisionID),
                                            try !index.authorityReviewIsProvisional(
                                                revisionID: review.event.resolution.revisionID)
                                        {
                                            try index.retainRecoveryAuthorityReview(plan: review)
                                        }
                                    } else if try !index.authorityReviewControlAllows(
                                        control: plan.binding, revisionID: review.event.resolution.revisionID)
                                    {
                                        let raw = try index.retainedAuthorityObject(
                                            id: review.event.resolution.revisionID)!
                                        _ = try index.applyValidatedReview(
                                            plan: review,
                                            resolutionRow: authorityCatalogueRow(
                                                raw, node: review.resolution),
                                            loadVerified: {
                                                try PooledCanonicalRecord.read(
                                                    row: $0, root: self.root, ownerUID: self.ownerUID)
                                            },
                                            limits: revisionProjectionLimits, progress: coordinator.progress,
                                            allowConcurrentCurrent: true)

                                    }
                                } catch let error as TractandaError
                                    where [
                                        "missingDependencies", "forbidden", "unresolvedPrincipal",
                                        "untrustedPeer",
                                        "revisionConflict", "invalidAuthority",
                                        "invalidRevisionGraph",
                                        "invalidMergeTimestamp",
                                    ].contains(error.code)
                                {
                                    if try coordinator.foreignReviewActivation(review.event.binding) != nil {
                                        throw error
                                    }
                                    continue
                                }
                            }
                            if recovering,
                                try !index.authorityReviewControlAllows(
                                    control: plan.binding, revisionID: review.event.resolution.revisionID)
                            {
                                if isLocal,
                                    try !index.authorityReviewIsProvisional(
                                        revisionID: review.event.resolution.revisionID)
                                {
                                    try index.retainRecoveryAuthorityReview(plan: review)
                                }
                                continue
                            }
                            try validateHistoricalReviewAuthority(
                                review, coordinator: coordinator, index: index)
                            guard
                                try index.authorityReviewControlAllows(
                                    control: plan.binding, revisionID: review.event.resolution.revisionID)
                            else { continue }
                        }
                        if !isLocal && reviewPlan == nil {
                            for delta in plan.deltas {
                                guard
                                    let target = try index.retainedAuthorityObject(
                                        id: delta.target.revisionID),
                                    target.descriptor.sha256 == delta.target.sha256
                                else {
                                    valid = false
                                    break
                                }
                                let node = try AuthorityRevision(originalBytes: coordinator.bytes(target))
                                guard node.revision.itemID == delta.target.itemID,
                                    delta.actor == node.revision.fields["actor"]?.string
                                        || "user:" + delta.actor == node.revision.fields["actor"]?.string
                                else {
                                    throw TractandaError(
                                        "invalidAuthority",
                                        "Control transition target/actor differs from exact original.")
                                }
                                // Exact already admitted originals include the administrator-pinned baseline.
                                // New targets need independent source authority; a raw control claim cannot grant them.
                                let known =
                                    try index.authorityDisposition(id: delta.target.revisionID)?.disposition
                                    == .eligible
                                if delta.eligible, let previous = plan.localParent,
                                    try index.eligibilityAtCut(
                                        revisionID: delta.target.revisionID, cut: previous)
                                        == .held
                                {
                                    valid = false
                                    break  // B does not implement protected/manual reapproval.
                                }
                                guard
                                    try delta.causes.allSatisfy({ try index.hasValidatedAuthorityControl($0) }
                                    )
                                else {
                                    throw TractandaError(
                                        "invalidAuthority", "Control override cause is not validated.")
                                }
                                // This first causal profile only demotes already admitted records;
                                // a denial is not required to manufacture positive source testimony.
                                if !delta.eligible {
                                    let localHistory = try index.authorityHasLocalHistoryAdmission(
                                        revisionID: delta.target.revisionID)
                                    let prior =
                                        try plan.localParent.map {
                                            try index.eligibilityAtCut(
                                                revisionID: delta.target.revisionID,
                                                cut: $0)
                                        } ?? .unknown
                                    if !known && !localHistory && prior == .unknown {
                                        valid = false
                                        break
                                    }
                                    continue
                                }
                                let exactEvidence: AuthorityRecord?
                                if let binding = delta.evidence {
                                    guard let provenance = try node.revision.provenance,
                                        let raw = try index.retainedAuthorityObject(id: binding.recordID),
                                        raw.descriptor.sha256 == binding.sha256,
                                        let receipt = try coordinator.freshReceipt(
                                            binding.recordID,
                                            origin: provenance.originReplicaID,
                                            index: index), receipt.permittedOrigin
                                    else {
                                        valid = false
                                        break
                                    }
                                    let value = try AuthorityRecordCodec.decode(coordinator.bytes(raw)).record
                                    guard try coordinator.matchesIdentity(node, value) else {
                                        throw TractandaError(
                                            "invalidAuthority",
                                            "Control selected testimony differs from original.")
                                    }
                                    exactEvidence = value
                                } else {
                                    guard try node.revision.provenance?.kind != .authored else {
                                        throw TractandaError(
                                            "invalidAuthority", "Authored acceptance requires exact evidence."
                                        )
                                    }
                                    exactEvidence = nil
                                }
                                if let evidence = exactEvidence {
                                    let expected = try
                                        (AuthorityRecord.list(evidence.payload["admissionPolicies"])
                                        + AuthorityRecord.list(evidence.payload["itemPolicies"]))
                                        .map { try AuthorityRecord.binding($0).revisionID }
                                    guard delta.policyIDs == Array(Set(expected)).sorted() else {
                                        throw TractandaError(
                                            "invalidAuthority",
                                            "Control reverse dependencies differ from original source policies."
                                        )
                                    }
                                }

                                if known, delta.eligible,
                                    let evidence = exactEvidence,
                                    try coordinator.invalidationOutcome(
                                        node, evidence: evidence, contextHeads: plan.parents, index: index
                                    ).denied
                                {
                                    valid = false
                                    break
                                }
                                if !known,
                                    try node.revision.provenance?.kind == .automaticMerge
                                {
                                    if try evaluateAuthorityMaterialization(
                                        node, coordinator: coordinator, index: index,
                                        requireAcceptanceCut: false
                                    ).disposition != .eligible {
                                        valid = false
                                        break
                                    }
                                } else if !known, let evidence = exactEvidence {
                                    let result: AuthorityStore.Evaluation
                                    do {
                                        result = try evaluateAuthoritySource(
                                            node, evidence: evidence, coordinator: coordinator, index: index)
                                    } catch let error as TractandaError
                                        where error.code == "missingDependencies"
                                    {
                                        valid = false
                                        break
                                    }
                                    let effect = try coordinator.invalidationOutcome(
                                        node, evidence: evidence, contextHeads: plan.parents, index: index)
                                    if result.disposition != .eligible || effect.denied {
                                        valid = false
                                        break
                                    }
                                }
                            }
                        }
                        if !valid { continue }
                        try index.retainValidatedControl(plan)
                        if let review = reviewPlan {
                            try retainReviewPolicyInvalidations(
                                review, coordinator: coordinator, index: index)
                            if !isLocal {
                                try index.retainAppliedReviewHistory(review)
                                for delta in plan.deltas where delta.eligible {
                                    try coordinator.restoreControlAcceptance(delta, index: index)
                                }
                                if let (review, package) = activateReview {
                                    try coordinator.activateForeignReview(review, packageID: package)
                                }
                                if !recovering {
                                    let projected = try prepareRecoveredProjection(
                                        review.event.target.itemID, using: index,
                                        deferMaterialization: authorityCatchupActive)
                                    if let current = projected.revision {
                                        try index.put(current)
                                        try rememberHead(Self.residentHead(current))
                                    } else {
                                        if let old = heads.removeValue(forKey: review.event.target.itemID) {
                                            headCacheBytes -= try residentByteCount(old)
                                        }
                                        headCacheOrder.removeAll { $0 == review.event.target.itemID }
                                    }
                                }
                            }
                        }
                        witnessPackages.insert(row.packageID)
                        if isLocal {
                            for delta in plan.deltas where delta.eligible {
                                try coordinator.restoreControlAcceptance(delta, index: index)
                            }
                            for delta in plan.deltas where !delta.eligible {
                                try holdAuthorityDescendants(
                                    delta.target.revisionID,
                                    reason: "Sealed local authority decision requires explicit review.",
                                    causes: delta.causes, coordinator: coordinator, index: index)
                            }
                            try index.retainLocalAuthorityAcceptance(plan)
                            if recovering {
                                try restoreRecoveredLocalAuthored(
                                    plan, coordinator: coordinator, index: index)
                            }
                            try consumeRestoredAuthorityEffects(
                                plan, review: reviewPlan, coordinator: coordinator, index: index)
                            // Review D is a typed decision cause, not a pending ordinary
                            // control effect; it must not pass through the control-only queue.
                            if reviewPlan == nil {
                                try index.clearAuthorityDispositionEffects(
                                    coveredBy: plan.binding, originID: verified.record.originReplicaID)
                            }
                        }
                        changed = true
                        for delta in plan.deltas where delta.eligible {
                            guard let target = try index.retainedAuthorityObject(id: delta.target.revisionID)
                            else { continue }
                            let node = try AuthorityRevision(originalBytes: coordinator.bytes(target))
                            if let parent = node.revision.supersedes,
                                let prior = try index.retainedAuthorityObject(id: parent),
                                let witness = try authoritySourceWitness(
                                    node, coordinator: coordinator, index: index)
                            {
                                if let source = try coordinator.sourceControl(witness),
                                    plan.localParent == source,
                                    try node.revision.provenance?.originReplicaID
                                        == verified.record.originReplicaID
                                {
                                    let old = try AuthorityRevision(originalBytes: coordinator.bytes(prior))
                                        .revision
                                    if old.fields["accessConfiguration"]
                                        != node.revision.fields["accessConfiguration"]
                                        || old.fields["permissions"] != node.revision.fields["permissions"]
                                    {
                                        try index.retainValidatedInvalidation(
                                            .init(
                                                control: plan.binding, sourceCut: source,
                                                policy: node, previousPolicyID: parent))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Visibility is canonical acceptance, not a read event; restoring it does not emit a control.
            for phase in 0..<3 {
                let scopes: [String?] = recovering ? [nil] : witnessPackages.sorted().map { Optional($0) }
                for scope in scopes {
                    var after: String?
                    while true {
                        let rows: [AuthorityStore.RetainedObject]
                        if let scope {
                            rows = try index.authorityPackagePage(packageID: scope, after: after, limit: 128)
                        } else {
                            rows = try index.retainedAuthorityPage(after: after, limit: 128)
                        }
                        if rows.isEmpty { break }
                        for row in rows {
                            after = row.descriptor.id
                            guard row.descriptor.kind == .authority else { continue }
                            let verified = try AuthorityRecordCodec.decode(coordinator.bytes(row))
                            let isVisibility = verified.record.kind == .visibilityWitness
                            let hasCause =
                                try isVisibility
                                && !AuthorityRecord.list(verified.record.payload["causeKey"]).isEmpty
                            guard
                                (phase == 0 && isVisibility && !hasCause)
                                    || (phase == 1 && verified.record.kind == .reconciliationWitness)
                                    || (phase == 2 && isVisibility && hasCause)
                            else { continue }
                            guard
                                try row.peerID == "local"
                                    || coordinator.freshReceipt(
                                        row.descriptor.id,
                                        origin: verified.record.originReplicaID, index: index) != nil
                            else { continue }
                            if verified.record.kind == .visibilityWitness {
                                let plan = try AuthorityStore.VerifiedExposurePlan(witness: verified)
                                guard try index.hasValidatedAuthorityControl(plan.cut),
                                    let original = try index.retainedAuthorityObject(
                                        id: plan.target.revisionID)
                                else { continue }
                                try index.retainValidatedExposure(
                                    plan,
                                    revision: AuthorityRevision(originalBytes: coordinator.bytes(original)),
                                    locallyVisible: coordinator.hasLocalPublicationReceipt(
                                        objectID: row.descriptor.id,
                                        origin: verified.record.originReplicaID, index: index))
                            } else if verified.record.kind == .reconciliationWitness {
                                let plan = try AuthorityStore.VerifiedReconciliationPlan(witness: verified)
                                let historical =
                                    try coordinator.hasLocalPublicationReceipt(
                                        objectID: row.descriptor.id, origin: verified.record.originReplicaID,
                                        index: index)
                                    || exactHistoricalReconciliation(
                                        plan, coordinator: coordinator, index: index)
                                guard
                                    try plan.causes.allSatisfy({ cause in
                                        try index.hasValidatedAuthorityControl(cause)
                                            || index.peerRetirementIsActive(cause)
                                            || (historical && index.peerRetirementHasValidatedProof(cause))
                                    })
                                else {
                                    continue
                                }
                                if recovering {
                                    let parents = try plan.parents.map { id -> AuthorityRevision in
                                        guard let row = try index.retainedAuthorityObject(id: id) else {
                                            throw TractandaError(
                                                "missingDependencies",
                                                "Recovery reconciliation parent is absent."
                                            )
                                        }
                                        return try AuthorityRevision(originalBytes: coordinator.bytes(row))
                                    }
                                    try index.retainRecoveryReconciliation(plan, parents: parents)
                                } else if try coordinator.hasLocalPublicationReceipt(
                                    objectID: row.descriptor.id,
                                    origin: verified.record.originReplicaID, index: index)
                                {
                                    _ = try index.reserveReconciliation(plan)
                                } else {
                                    do { try index.retainValidatedReconciliation(plan) } catch let error
                                        as TractandaError
                                        where ["missingDependencies", "invalidAuthority"].contains(error.code)
                                    { continue }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private func authorityCatalogueRow(_ retained: AuthorityStore.RetainedObject, node: AuthorityRevision)
        throws -> ItemIndex.CatalogueRow
    {
        let revision = node.revision
        let metadata = try FileMetadata.read(at: root.appendingPathComponent(retained.path))
        guard metadata.size == UInt64(node.originalBytes.count), metadata.type == .regular,
            metadata.uid == ownerUID, metadata.mode & 0o777 == 0o400,
            CanonicalRecordPath.validate(
                retained.path, itemID: revision.itemID, revisionID: revision.revisionID)
        else {
            throw TractandaError("invalidAuthority", "Receiver original locator/ownership differs.")
        }
        return ItemIndex.CatalogueRow(
            revisionID: revision.revisionID, itemID: revision.itemID, path: retained.path,
            parentID: revision.supersedes, actor: revision.fields["actor"]!.string!,
            operationID: revision.fields["operationID"]!.string!, size: metadata.size, inode: metadata.inode,
            uid: metadata.uid, mode: metadata.mode, modificationSeconds: metadata.modificationSeconds,
            modificationNanoseconds: metadata.modificationNanoseconds,
            digest: Data(SHA256.hash(data: node.originalBytes)),
            createdAt: revision.fields["createdAt"]!.dateString!,
            feedbackRevisionIDs: revision.fields["learningFeedback"]?.map?.values.compactMap {
                try? LearningFeedback($0).revisionID
            } ?? [],
            modifiedAt: revision.modifiedAt, provenance: try revision.provenance)
    }
    private func promoteEligiblePeerPackage(
        _ packageID: String, coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        let token = "promote:" + packageID
        try index.authorityBeginWalk(token: token)
        defer { try? index.authorityEndWalk(token: token) }
        var changed = true
        var work = 0
        while changed {
            changed = false
            var cursor: String?
            while true {
                let rows = try index.authorityPackagePage(packageID: packageID, after: cursor, limit: 128)
                if rows.isEmpty { break }
                for row in rows {
                    cursor = row.descriptor.id
                    guard row.descriptor.kind == .item,
                        try index.authorityDisposition(id: row.descriptor.id)?.disposition == .eligible,
                        try index.revision(row.descriptor.id) == nil
                    else { continue }
                    work += 1
                    guard work <= coordinator.journal.limits.maximumWork else {
                        throw TractandaError("resourceLimit", "Promotion work exhausted.")
                    }
                    let node = try AuthorityRevision(originalBytes: coordinator.bytes(row))
                    if node.parents.contains(where: { (try? index.revision($0)) == nil }) { continue }
                    let parent = try node.parents.first.flatMap { id -> AuthorityRevision? in
                        guard let retained = try index.retainedAuthorityObject(id: id) else { return nil }
                        return try AuthorityRevision(originalBytes: coordinator.bytes(retained))
                    }
                    let peerSnapshot: RevisionProjection.Snapshot?
                    if try index.peerRetirementRecheckContains(row.descriptor.id),
                        try index.authorityHasLocalHistoryAdmission(revisionID: row.descriptor.id)
                    {
                        try index.restoreRetirementHeldHistory(
                            original: node,
                            row: authorityCatalogueRow(row, node: node),
                            loadVerified: {
                                try PooledCanonicalRecord.read(
                                    row: $0, root: self.root, ownerUID: self.ownerUID)
                            })
                        peerSnapshot = nil
                    } else if try node.revision.provenance?.kind == .automaticMerge {
                        peerSnapshot = try index.appendValidatedPeerMaterialization(
                            row: authorityCatalogueRow(row, node: node), revision: node,
                            loadVerified: { row in
                                try PooledCanonicalRecord.read(
                                    row: row, root: self.root, ownerUID: self.ownerUID)
                            },
                            limits: revisionProjectionLimits, progress: coordinator.progress)
                    } else {
                        try index.appendValidatedPeer(
                            row: authorityCatalogueRow(row, node: node), revision: node, parent: parent,
                            control: node.revision.classID == AccessConfiguration.classID
                                ? index.authorityAcceptanceControl(revisionID: node.revision.revisionID)
                                : nil,
                            originalsVerified: authorityOriginalsVerified(
                                node.revision, coordinator: coordinator, index: index)
                        )
                        peerSnapshot = nil
                    }
                    _ = try index.authorityVisitOnce(token: token, id: node.revision.itemID)
                    // Resolve only the affected item through the existing disk projection engine.
                    let exact = try authorityCatalogueRow(row, node: node)
                    let leaf: RevisionProjection.Snapshot?
                    do {
                        leaf =
                            try peerSnapshot
                            ?? index.verifiedLinearProjectionSnapshot(row: exact, revision: node.revision)
                    } catch let error as TractandaError where error.code == "projectionRequired" {
                        leaf = nil
                    }
                    let prepared = try prepareRecoveredProjection(
                        node.revision.itemID, using: index, verifiedSnapshot: leaf,
                        deferMaterialization: authorityCatchupActive)
                    if let current = prepared.revision {
                        if try index.currentHeadSummary(current.itemID)?.revisionID != current.revisionID {
                            try index.put(current)
                        }
                        guard try index.textMatches(current) else {
                            throw TractandaError("indexError", "Promoted current body failed verification.")
                        }
                        try rememberHead(Self.residentHead(current))
                    } else {
                        if let removed = heads.removeValue(forKey: node.revision.itemID) {
                            headCacheBytes -= try residentByteCount(removed)
                        }
                        headCacheOrder.removeAll { $0 == node.revision.itemID }
                    }
                    changed = true
                }
            }
        }
    }
    private func sealAuthorityAcceptance(
        _ node: AuthorityRevision, evaluation: AuthorityStore.Evaluation,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        // Zero-write materializations are validated from their own accepted parents.
        // Receiving an equivalent representation must not mint a shared acknowledgement.
        if try node.revision.provenance?.kind == .automaticMerge { return }
        guard let origin = replicaID else {
            throw TractandaError("missingReplicaIdentity", "Acceptance needs local identity.")
        }
        if try index.peerOriginRetired(origin) { return }
        if try index.authorityLocallyAccepted(revisionID: node.revision.revisionID, originID: origin) {
            return
        }
        let evidence: AuthorityRecord?
        let binding: AuthorityBinding?
        if let id = evaluation.evidenceID, let digest = evaluation.evidenceDigest,
            let package = evaluation.evidencePackageID,
            let receipt = try index.authorityReceipt(objectID: id, packageID: package),
            receipt.permittedOrigin, receipt.descriptor.sha256 == digest
        {
            let value = try AuthorityRecordCodec.decode(coordinator.bytes(receipt)).record
            guard try coordinator.matchesIdentity(node, value) else {
                throw TractandaError("invalidAuthority", "Acceptance selection differs from original.")
            }
            evidence = value
            binding = try .init(recordID: id, sha256: digest)
        } else {
            guard try node.revision.provenance?.kind != .authored else {
                throw TractandaError("invalidAuthority", "Authored acceptance requires selected testimony.")
            }
            evidence = nil
            binding = nil
        }
        let policies =
            try evidence.map {
                try
                    (AuthorityRecord.list($0.payload["admissionPolicies"])
                    + AuthorityRecord.list($0.payload["itemPolicies"]))
                    .map { try AuthorityRecord.binding($0).revisionID }
            } ?? []
        let actor = "replica:" + origin
        let draft = try coordinator.prepareSourceCut(index: index, origin: origin, actor: actor)
        let pin = try coordinator.configuration()?.bootstrap.map {
            try AuthorityBinding(recordID: $0.recordID, sha256: $0.sha256)
        }
        let commit = try coordinator.makeControl(
            origin: origin, actor: actor, localParent: draft.cut,
            parents: draft.cut.map { [$0] } ?? [],
            deltas: [
                .init(
                    target: try .init(
                        itemID: node.revision.itemID,
                        revisionID: node.revision.revisionID, sha256: node.sha256),
                    eligible: true, actor: node.revision.fields["actor"]!.string!,
                    policyIDs: Array(Set(policies)).sorted(), evidence: binding)
            ], bootstrap: pin)
        let package = try coordinator.stageControlUnit(
            draft.records + [commit], contextToken: peerIntakeContextToken())
        // The acceptance fact and exact evidence are durable before the private assessment.
        try authorityAfterAcceptanceSealForTesting?()
        try coordinator.retainSealed(package, index: index)
        try validateAuthorityControls(
            packageID: package, coordinator: coordinator, index: index, localUnit: true)
        try coordinator.journal.applied(package)
    }
    private func persistAuthorityAcceptanceEffects(
        packageID: String, coordinator: PeerIntakeCoordinator,
        index: ItemIndex
    ) throws {
        var cursor: String?
        while true {
            let rows = try index.authorityPackagePage(packageID: packageID, after: cursor, limit: 128)
            if rows.isEmpty { break }
            for row in rows {
                cursor = row.descriptor.id
                guard row.descriptor.kind == .item,
                    try index.authorityDisposition(id: row.descriptor.id)?.disposition == .eligible,
                    let current = try index.currentProjection(
                        itemID:
                            AuthorityRevision(originalBytes: coordinator.bytes(row)).revision.itemID),
                    current.state.status == .ready,
                    current.state.representativeRevisionID == row.descriptor.id
                else { continue }
                try persistAuthorityVisibility(
                    revisionID: row.descriptor.id,
                    coordinator: coordinator, index: index)
            }
        }
    }
    private func persistAuthorityVisibility(
        revisionID: String, coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        if let origin = replicaID, try index.peerOriginRetired(origin) { return }
        guard try !index.authorityLocallyExposed(revisionID: revisionID), let origin = replicaID,
            let row = try index.retainedAuthorityObject(id: revisionID)
        else { return }
        let original = try AuthorityRevision(originalBytes: coordinator.bytes(row))
        let localCut = try index.authorityControlHead(originID: origin)
        let localEligibility =
            try localCut.map {
                try index.eligibilityAtCut(revisionID: revisionID, cut: $0)
            } ?? .unknown
        let cut: AuthorityBinding
        if let localCut, localEligibility == .eligible {
            cut = localCut
        } else if let reviewed = try index.locallyAppliedReviewControl(
            revisionID: revisionID, digest: original.sha256),
            try index.authorityHasLocalHistoryAdmission(revisionID: revisionID),
            try index.eligibilityAtCut(revisionID: revisionID, cut: reviewed) == .eligible
        {
            cut = reviewed
        } else if try original.revision.provenance?.kind == .automaticMerge,
            let source = try index.authorityAcceptanceControl(revisionID: revisionID),
            try index.eligibilityAtCut(revisionID: revisionID, cut: source) == .eligible
        {
            cut = source
        } else {
            throw TractandaError(
                "invalidAuthority",
                "Local visibility lacks a validated acceptance cut for \(revisionID); local=\(localCut?.recordID ?? "none") state=\(localEligibility.rawValue)."
            )
        }
        let causeKey: String?
        if let binding = try original.revision.provenance?.authorityWitness {
            let witness = try AuthorityStore.VerifiedReconciliationPlan(
                witness: coordinator.control(binding, index: index))
            causeKey = try index.authorityReconciliationCauseKey(
                itemID: witness.itemID, frontier: witness.frontier, causes: witness.causes)
        } else {
            causeKey = nil
        }
        let record = try AuthorityRecord(
            recordID: makePersistentUUID().uuidString.lowercased(), storeID: coordinator.storeID,
            originReplicaID: origin, kind: .visibilityWitness, parentAuthorityIDs: [cut.recordID],
            actorPrincipal: "replica:" + origin, createdAt: Timestamp.now(),
            payload: [
                "target": AuthorityStore.Target(
                    itemID: original.revision.itemID,
                    revisionID: revisionID, sha256: original.sha256
                ).itemValue,
                "cut": cut.itemValue, "modifiedAt": .date(original.revision.modifiedAt),
                "causeKey": .list(causeKey.map { [.text($0)] } ?? []),
            ])
        let package = try coordinator.stageControlUnit([record], contextToken: peerIntakeContextToken())
        try coordinator.retainSealed(package, index: index)
        try validateAuthorityControls(
            packageID: package, coordinator: coordinator, index: index, localUnit: true)
        try coordinator.journal.applied(package)
    }
    private struct InitialAuthorityVisibility: Codable, Equatable {
        let profile: String
        let storeID: String
        let replicaID: String
        let pinID: String
        let pinDigest: String
    }
    private func drainAuthorityVisibility(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws {
        guard replicaID != nil else { return }
        var work = 0
        while true {
            let page = try index.authorityLocalVisibilityWorkPage(limit: 128)
            if page.isEmpty { return }
            for entry in page {
                work += 1
                try coordinator.progress?()
                guard work <= coordinator.journal.limits.maximumWork else {
                    throw TractandaError("resourceLimit", "Local visibility recovery work exhausted.")
                }
                if let current = try index.currentProjection(itemID: entry.itemID),
                    current.state.status == .ready, let id = current.state.representativeRevisionID
                {
                    try persistAuthorityVisibility(revisionID: id, coordinator: coordinator, index: index)
                }
                try index.clearAuthorityLocalVisibilityWork(itemID: entry.itemID, token: entry.token)
            }
        }
    }
    /// Rebuild rederives unfinished disposition effects from the admitted controls. In
    /// particular, a sealed revocation plus an unsealed reconciliation must never expose
    /// an older representative without completing the required changed-view publication.
    private func finishAuthorityDispositionEffects(coordinator: PeerIntakeCoordinator, index: ItemIndex)
        throws
    {
        guard let origin = replicaID else { return }
        var work = 0
        while true {
            let page = try index.authorityDispositionEffectPage(limit: 128)
            if page.isEmpty { return }
            work += page.count
            guard work <= coordinator.journal.limits.maximumWork else {
                throw TractandaError("resourceLimit", "Authority effect recovery work exhausted.")
            }
            var items: [String: Set<AuthorityBinding>] = [:]
            for delta in page { items[delta.target.itemID, default: []].formUnion(delta.causes) }
            for (item, causes) in items.sorted(by: { $0.key < $1.key }) {
                try reconcileAuthorityProjection(
                    item,
                    causes: causes.sorted { $0.recordID < $1.recordID }, coordinator: coordinator,
                    index: index)
            }
            if try !index.authorityDispositionEffectPage(limit: 1).isEmpty {
                let draft = try coordinator.prepareSourceCut(
                    index: index, origin: origin, actor: "replica:" + origin)
                guard !draft.records.isEmpty else {
                    throw TractandaError(
                        "invalidAuthority", "Unfinished disposition effects lack a publication plan.")
                }
                let package = try coordinator.stageControlUnit(
                    draft.records, contextToken: peerIntakeContextToken())
                try coordinator.retainSealed(package, index: index)
                try validateAuthorityControls(
                    packageID: package, coordinator: coordinator, index: index, localUnit: true)
                try coordinator.journal.applied(package)
            }
        }
    }
    /// One-time, resumable baseline work: acceptance covers the reviewed history, while
    /// clock exposure records only READY representatives actually admitted on this node.
    private func ensureInitialAuthorityVisibility(
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        guard authorityExistingHistoryAdmitted,
            let pin = try coordinator.configuration()?.bootstrap, let origin = replicaID
        else { return }
        let expected = InitialAuthorityVisibility(
            profile: "tractanda.initial-visibility.v1",
            storeID: coordinator.storeID, replicaID: origin, pinID: pin.recordID, pinDigest: pin.sha256)
        let path = [".authority-initial-visibility", pin.recordID]
        if let bytes = try coordinator.journal.files.readIfPresent(path: path, maximumBytes: 4096) {
            guard try PeerPackage.decode(InitialAuthorityVisibility.self, bytes, maximum: 4096) == expected
            else {
                throw TractandaError(
                    "invalidAuthority", "Initial local visibility belongs to another cut/node.")
            }
            return
        }
        let wasDirty = StoreCheckpoint.isDirty(root: root)
        try StoreCheckpoint.markDirty(root: root)
        do {
            try coordinator.withOperation(recovery: true) {
                try index.withCatalogueScanBudget(progress: coordinator.progress, reusingActiveBudget: true) {
                    try index.retainLocalBootstrapAcceptance(pin)
                    if try index.authorityControlHead(originID: origin) == nil {
                        let draft = try coordinator.prepareSourceCut(
                            index: index, origin: origin,
                            actor: "replica:" + origin)
                        guard !draft.records.isEmpty else {
                            throw TractandaError(
                                "invalidAuthority", "Reviewed initial cut lacks a causal root.")
                        }
                        let package = try coordinator.stageControlUnit(
                            draft.records,
                            contextToken: peerIntakeContextToken())
                        try coordinator.retainSealed(package, index: index)
                        try validateAuthorityControls(
                            packageID: package, coordinator: coordinator, index: index, localUnit: true)
                        try coordinator.journal.applied(package)
                    }
                    try drainAuthorityVisibility(coordinator: coordinator, index: index)
                }
            }
            try coordinator.journal.files.writeImmutable(
                try JSON.encode(expected), path: path, maximumBytes: 4096)
            if !wasDirty { try StoreCheckpoint.clear(root: root) }
        } catch {
            quarantineCheckpoint()
            throw error
        }
    }
    private func holdAuthorityDescendants(
        _ revisionID: String, reason: String, causes: [AuthorityBinding] = [],
        coordinator: PeerIntakeCoordinator, index: ItemIndex, retirement: Bool = false
    ) throws {
        let token = "hold:" + Identifier.make()
        try index.authorityBeginWalk(token: token)
        defer { try? index.authorityEndWalk(token: token) }
        var pending = [revisionID]
        var work = 0
        while let id = pending.popLast() {
            try coordinator.progress?()
            work += 1
            guard work <= coordinator.journal.limits.maximumWork,
                UInt64(pending.count) * 128 < coordinator.journal.limits.maximumStagedBytes
            else {
                throw TractandaError("resourceLimit", "Authority descendant work exhausted.")
            }
            guard try index.authorityVisitOnce(token: token, id: id) else { continue }
            if !causes.isEmpty, let row = try index.retainedAuthorityObject(id: id) {
                let alreadyCovered: Bool
                if let origin = replicaID, let cut = try index.authorityControlHead(originID: origin) {
                    alreadyCovered = try index.eligibilityAtCut(revisionID: id, cut: cut) == .held
                } else {
                    alreadyCovered = false
                }
                if !alreadyCovered {
                    let node = try AuthorityRevision(originalBytes: coordinator.bytes(row))
                    let evidence = try authoritySourceWitness(node, coordinator: coordinator, index: index)
                    let policyIDs =
                        try evidence.map {
                            try
                                (AuthorityRecord.list($0.payload["admissionPolicies"])
                                + AuthorityRecord.list($0.payload["itemPolicies"]))
                                .map { try AuthorityRecord.binding($0).revisionID }
                        } ?? []
                    try index.noteAuthorityDispositionEffect(
                        .init(
                            target: try .init(
                                itemID: node.revision.itemID,
                                revisionID: id, sha256: node.sha256), eligible: false,
                            actor: node.revision.fields["actor"]!.string!,
                            policyIDs: Array(Set(policyIDs)).sorted(), causes: causes))
                }
            }
            if retirement, let state = try index.authorityDisposition(id: id)?.disposition,
                [.eligible, .pending, .missingDependencies].contains(state)
            {
                try index.notePeerRetirementEffect(id)
            }
            try index.setAuthorityDisposition(id: id, evaluation: .init(disposition: .held, reason: reason))
            var after: String?
            while true {
                let children = try index.authorityChildPage(parentID: id, after: after, limit: 128)
                if children.isEmpty { break }
                for child in children {
                    after = child.descriptor.id
                    pending.append(child.descriptor.id)
                }
            }
        }
    }
    private func reduceRetainedAuthorityInventory(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws
    {
        // Existing user-revocation recovery pass; peer retirement uses its separate origin/time index.
        var cursor: String?
        while true {
            let page = try index.retainedAuthorityPage(after: cursor, limit: 128)
            if page.isEmpty { break }
            for row in page {
                cursor = row.descriptor.id
                guard row.descriptor.kind == .item,
                    try index.authorityDisposition(id: row.descriptor.id)?.disposition == .eligible
                else { continue }
                let node = try AuthorityRevision(originalBytes: coordinator.bytes(row))
                guard try node.revision.provenance?.kind != .automaticMerge,
                    try !index.authorityReviewIsProvisional(revisionID: node.revision.revisionID),
                    let evidence = try authoritySourceWitness(node, coordinator: coordinator, index: index)
                else { continue }
                let outcome = try coordinator.invalidationOutcome(node, evidence: evidence, index: index)
                if outcome.denied {
                    try holdAuthorityDescendants(
                        node.revision.revisionID,
                        reason: "Rebuilt validated revocation requires review of this exact original.",
                        causes: outcome.causes, coordinator: coordinator, index: index)
                }
            }
        }
    }
    private func reducePeerRetirements(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws
        -> [String: [AuthorityBinding]]
    {
        var affected: [String: [AuthorityBinding]] = [:]
        var reviewedOriginals: [String: [AuthorityBinding]] = [:]
        var afterOrigin: String?
        var work = 0
        while true {
            let origins = try index.peerRetirementOriginPage(after: afterOrigin)
            if origins.isEmpty { break }
            for (origin, cutoff) in origins {
                afterOrigin = origin
                var reviewCursor: (Int64, String)?
                while true {
                    let reviews = try index.peerRetiredReviewPage(
                        origin: origin, cutoff: cutoff, after: reviewCursor)
                    if reviews.isEmpty { break }
                    for review in reviews {
                        reviewCursor = (review.issued, review.decision)
                        work += 1
                        try coordinator.progress?()
                        guard work <= coordinator.journal.limits.maximumWork else {
                            throw TractandaError(
                                "resourceLimit", "Retired review dependency window exhausted.")
                        }
                        guard let raw = try index.retainedAuthorityObject(id: review.resolution) else {
                            throw TractandaError(
                                "missingDependencies", "Applied review resolution is absent.")
                        }
                        let resolution = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
                        let causes = try index.peerRetirementCauses(
                            revisionID: review.resolution,
                            origin: resolution.revision.provenance!.originReplicaID)
                        if try !index.peerLifecycleHasFreshReview(review.resolution, causes: causes) {
                            try holdAuthorityDescendants(
                                review.resolution,
                                reason: "The exact review issuer was removed before its decision.",
                                coordinator: coordinator, index: index, retirement: true)
                            affected[review.item] = Array(Set((affected[review.item] ?? []) + causes))
                                .sorted { $0.recordID < $1.recordID }
                        }
                        reviewedOriginals[review.target] = Array(
                            Set((reviewedOriginals[review.target] ?? []) + causes)
                        )
                        .sorted { $0.recordID < $1.recordID }
                    }
                }
                var after: (Int64, String)?
                while true {
                    let rows = try index.authorityRetirementTargetPage(
                        origin: origin, cutoff: cutoff, after: after)
                    if rows.isEmpty { break }
                    for row in rows {
                        after = (try PeerLifecycle.revisionTicks(row.descriptor.id), row.descriptor.id)
                        work += 1
                        try coordinator.progress?()
                        guard work <= coordinator.journal.limits.maximumWork,
                            UInt64(affected.count) * 4096 < coordinator.journal.limits.maximumStagedBytes
                        else {
                            throw TractandaError(
                                "resourceLimit", "Timestamp retirement affected-target window exhausted.")
                        }
                        if try index.authorityReviewIsProvisional(revisionID: row.descriptor.id) { continue }
                        let node = try AuthorityRevision(originalBytes: coordinator.bytes(row))
                        guard try coordinator.retirementBlocks(node, index: index) else { continue }
                        let causes = try index.peerRetirementCauses(
                            revisionID: row.descriptor.id, origin: origin)
                        try holdAuthorityDescendants(
                            row.descriptor.id,
                            reason: "Validated timestamp retirement requires exact administrator review.",
                            coordinator: coordinator, index: index, retirement: true)
                        affected[node.revision.itemID] = Array(
                            Set((affected[node.revision.itemID] ?? []) + causes)
                        ).sorted { $0.recordID < $1.recordID }
                    }
                }
            }
        }
        if try index.acceptedGraphProofIsCurrent() {
            // First remove EVERY invalid C/policy before assessing B. No current ACL or
            // admission decision may use a stale just-retired C from the projection cache.
            for item in affected.keys.sorted() {
                try refreshRetirementCurrent(item, coordinator: coordinator, index: index)
            }
            if !affected.isEmpty || !reviewedOriginals.isEmpty {
                try refreshCurrentAccessConfigurations(using: index)
            }
            for (id, causes) in reviewedOriginals.sorted(by: { $0.key < $1.key }) {
                guard try index.authorityDisposition(id: id)?.disposition == .eligible,
                    let heldRaw = try index.retainedAuthorityObject(id: id)
                else { continue }
                let held = try AuthorityRevision(originalBytes: coordinator.bytes(heldRaw))
                let ownCauses = try index.peerRetirementCauses(
                    revisionID: id, origin: held.revision.provenance!.originReplicaID)
                let approved = try index.authorityReviewDisposition(revisionID: id) == .approved
                if approved, try ownCauses.isEmpty || index.peerLifecycleHasFreshReview(id, causes: ownCauses)
                {
                    continue
                }
                var independentlyEligible = false
                if let evidence = try authoritySourceWitness(held, coordinator: coordinator, index: index) {
                    independentlyEligible =
                        try evaluateIncomingAuthority(
                            held, evidence: evidence, coordinator: coordinator, index: index,
                            revalidatingAcceptedOriginal: true
                        ).disposition == .eligible
                }
                if !independentlyEligible {
                    try holdAuthorityDescendants(
                        id,
                        reason: "Original has no independent current authority after review issuer removal.",
                        coordinator: coordinator, index: index, retirement: true)
                    affected[held.revision.itemID] = Array(
                        Set((affected[held.revision.itemID] ?? []) + causes)
                    )
                    .sorted { $0.recordID < $1.recordID }
                    try refreshRetirementCurrent(held.revision.itemID, coordinator: coordinator, index: index)
                    if held.revision.classID == AccessConfiguration.classID {
                        try refreshCurrentAccessConfigurations(using: index)
                    }
                }
            }
        }
        return affected
    }
    private func refreshRetirementCurrent(
        _ item: String, coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        try index.reconcileAuthorityAcceptedItem(itemID: item)
        if let old = heads.removeValue(forKey: item) { headCacheBytes -= try residentByteCount(old) }
        headCacheOrder.removeAll { $0 == item }
        if try index.revisionCount(itemID: item) == 0 {
            try index.replaceCurrentProjection(
                snapshot: nil,
                state: ItemState(
                    itemID: item, stateToken: nextProjectionStateToken(), status: .reviewRequired,
                    detailsComplete: false,
                    resource: .init(
                        code: "authorityReviewRequired", phase: .analysis,
                        message: "Timestamp retirement held all current contributions.")),
                policies: [], policiesComplete: false)
        } else {
            _ = try prepareRecoveredProjection(item, using: index, deferMaterialization: true)
        }
    }
    private func reduceAuthorityItem(
        _ itemID: String, coordinator: PeerIntakeCoordinator,
        index: ItemIndex
    ) throws -> [AuthorityBinding] {
        var cursor: (Int64, String)?
        var causes: Set<AuthorityBinding> = []
        var changed = false
        while true {
            let condition = cursor == nil ? "" : " AND (modified_ticks,revision)>(CAST(? AS INTEGER),?)"
            let page = try index.graphCatalogueRows(
                where: "WHERE item=?\(condition) ORDER BY modified_ticks,revision",
                bindings: [itemID] + (cursor.map { [String($0.0), $0.1] } ?? []), limit: 128)
            if page.isEmpty { break }
            for row in page {
                cursor = (try RevisionTimestamp(row.modifiedAt).ticks, row.revisionID)
                guard try index.authorityDisposition(id: row.revisionID)?.disposition == .eligible,
                    let raw = try index.retainedAuthorityObject(id: row.revisionID)
                else { continue }
                let node = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
                guard try node.revision.provenance?.kind != .automaticMerge,
                    try !index.authorityReviewIsProvisional(revisionID: node.revision.revisionID),
                    let evidence = try authoritySourceWitness(node, coordinator: coordinator, index: index)
                else { continue }
                let outcome = try coordinator.invalidationOutcome(node, evidence: evidence, index: index)
                if outcome.denied {
                    causes.formUnion(outcome.causes)
                    try holdAuthorityDescendants(
                        row.revisionID,
                        reason:
                            "Validated canonical revocation requires review; descendants retain exact originals.",
                        causes: outcome.causes,
                        coordinator: coordinator, index: index)
                    changed = true
                }
            }
        }
        guard changed else { return [] }
        try index.reconcileAuthorityAcceptedItem(itemID: itemID)
        if let old = heads.removeValue(forKey: itemID) { headCacheBytes -= try residentByteCount(old) }
        headCacheOrder.removeAll { $0 == itemID }
        if try index.revisionCount(itemID: itemID) == 0 {
            let state = ItemState(
                itemID: itemID, stateToken: nextProjectionStateToken(), status: .reviewRequired,
                detailsComplete: false,
                resource: .init(
                    code: "authorityReviewRequired", phase: .analysis,
                    message: "No eligible current policy remains; administrator review is required."))
            try index.replaceCurrentProjection(
                snapshot: nil, state: state, policies: [], policiesComplete: false)
        } else {
            let snapshot = try analyzeCurrentProjection(
                itemID, using: index,
                limits: revisionProjectionLimits, progress: coordinator.progress)
            let state = try projectionState(
                for: snapshot, status: .reviewRequired,
                resource: .init(
                    code: "authorityReconciliationPending", phase: .publication,
                    message: "Validated authority transition is reconciling this item."))
            try index.replaceCurrentProjection(
                snapshot: snapshot, state: state,
                policies: projectionPolicies(snapshot, using: index), policiesComplete: true)
        }
        return causes.sorted { $0.recordID < $1.recordID }
    }
    private func applyAuthorityPolicyEffects(
        packageID: String, coordinator: PeerIntakeCoordinator,
        index: ItemIndex
    ) throws -> [String: [AuthorityBinding]] {
        var affected: [String: [AuthorityBinding]] = [:]
        var cursor: String?
        while true {
            let rows = try index.authorityPackagePage(packageID: packageID, after: cursor, limit: 128)
            if rows.isEmpty { break }
            for row in rows {
                cursor = row.descriptor.id
                guard row.descriptor.kind == .item,
                    try index.authorityDisposition(id: row.descriptor.id)?.disposition == .eligible
                else { continue }
                let node = try AuthorityRevision(originalBytes: coordinator.bytes(row))
                guard let previous = node.revision.supersedes,
                    let prior = try index.retainedAuthorityObject(id: previous)
                else { continue }
                let old = try AuthorityRevision(originalBytes: coordinator.bytes(prior)).revision
                guard
                    node.revision.classID == AccessConfiguration.classID
                        || old.fields["permissions"] != node.revision.fields["permissions"]
                else { continue }
                var after: String?
                while true {
                    let items = try index.affectedAuthorityItemPage(
                        kind: "policy", value: previous, after: after, limit: 128)
                    if items.isEmpty { break }
                    for item in items {
                        after = item
                        let causes = try reduceAuthorityItem(item, coordinator: coordinator, index: index)
                        if !causes.isEmpty {
                            affected[item] = Array(Set((affected[item] ?? []) + causes)).sorted {
                                $0.recordID < $1.recordID
                            }
                        }
                        guard UInt64(affected.count) * 4096 <= coordinator.journal.limits.maximumStagedBytes
                        else {
                            throw TractandaError(
                                "resourceLimit", "Affected-item metadata exceeds operation allowance.")
                        }
                    }
                }
            }
        }
        return affected
    }
    private struct ReconciliationIdentity: Codable {
        let profile: String
        let storeID: String
        let replicaID: String
        let key: String
        let outputRevisionID: String
        let witnessID: String
        let createdAt: String
        let modifiedAt: String
    }
    private func reconciliationIdentity(
        key: String, origin: String, after: [String],
        coordinator: PeerIntakeCoordinator
    ) throws -> ReconciliationIdentity {
        let path = ["authority", "local-reconciliation-identities", key]
        if let bytes = try coordinator.journal.files.readIfPresent(path: path, maximumBytes: 4096) {
            let value = try PeerPackage.decode(ReconciliationIdentity.self, bytes, maximum: 4096)
            guard value.profile == "tractanda.local-reconciliation-identity.v1",
                value.storeID == coordinator.storeID, value.replicaID == origin, value.key == key,
                try after.allSatisfy({ try RevisionTimestamp(value.modifiedAt) > RevisionTimestamp($0) })
            else { throw TractandaError("invalidAuthority", "Reconciliation reservation context differs.") }
            _ = try AuthorityRecord.persistentID(.text(value.outputRevisionID))
            _ = try AuthorityRecord.persistentID(.text(value.witnessID))
            _ = try RevisionTimestamp(value.createdAt)
            return value
        }
        // Real UUIDv1 identities are issued once and persisted before a prepared/sealed unit.
        // Retrying does not fabricate deterministic UUIDs or change the reserved original.
        let value = ReconciliationIdentity(
            profile: "tractanda.local-reconciliation-identity.v1",
            storeID: coordinator.storeID, replicaID: origin, key: key,
            outputRevisionID: try makePersistentUUID().uuidString.lowercased(),
            witnessID: try makePersistentUUID().uuidString.lowercased(), createdAt: Timestamp.now(),
            modifiedAt: try RevisionPublicationClock.after(after, now: publicationClockForTesting))
        try coordinator.journal.files.writeImmutable(try JSON.encode(value), path: path, maximumBytes: 4096)
        return value
    }
    private func reconcileAuthorityProjection(
        _ itemID: String, causes: [AuthorityBinding],
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        guard try index.revisionCount(itemID: itemID) > 0 else { return }
        let snapshot = try analyzeCurrentProjection(
            itemID, using: index,
            limits: revisionProjectionLimits, progress: coordinator.progress)
        let policies = try projectionPolicies(snapshot, using: index)
        guard snapshot.analysis.isResolved else {
            try index.replaceCurrentProjection(
                snapshot: snapshot,
                state: projectionState(for: snapshot, status: .conflicted), policies: policies,
                policiesComplete: true)
            return
        }
        if let local = replicaID, try index.peerOriginRetired(local) {
            _ = try prepareRecoveredProjection(
                itemID, using: index, verifiedSnapshot: snapshot, deferMaterialization: true)
            return
        }
        let causeKey = try index.authorityReconciliationCauseKey(
            itemID: itemID,
            frontier: snapshot.analysis.frontier, causes: causes)
        guard let floor = try index.authorityExposureFloor(itemID: itemID, excludingCauseKey: causeKey),
            try snapshot.representative == nil
                || RevisionTimestamp(snapshot.representative!.modifiedAt)
                    < RevisionTimestamp(floor.modifiedAt)
        else {
            let prepared = try prepareRecoveredProjection(itemID, using: index, verifiedSnapshot: snapshot)
            if let revision = prepared.revision { try rememberHead(Self.residentHead(revision)) }
            return
        }
        let parents = Array(Set(snapshot.physicalHeads + [snapshot.clockFloor.revisionID])).sorted()
        guard !parents.isEmpty, parents.count <= 1024, !causes.isEmpty,
            let parent = try index.revision(parents[0]), let origin = replicaID
        else {
            throw TractandaError("resourceLimit", "Reconciliation ancestry/control proof is incomplete.")
        }
        let planDigest = try index.authorityReconciliationPlanDigest(fields: snapshot.analysis.fields)
        let identityKey = AuthorityRecordCodec.sha256(
            try JSON.encode(
                ItemValue.object([
                    "item": .text(itemID), "parents": .list(parents.map(ItemValue.text)),
                    "frontier": .list(snapshot.analysis.frontier.map(ItemValue.text)),
                    "cause": .text(causeKey), "exposure": floor.witness.itemValue,
                    "acceptedClock": .date(snapshot.clockFloor.modifiedAt), "plan": .text(planDigest),
                ])))
        let identity = try reconciliationIdentity(
            key: identityKey, origin: origin,
            after: [snapshot.clockFloor.modifiedAt, floor.modifiedAt], coordinator: coordinator)
        let modified = identity.modifiedAt
        let outputID = identity.outputRevisionID
        let witness = try AuthorityRecord(
            recordID: identity.witnessID,
            storeID: coordinator.storeID, originReplicaID: origin, kind: .reconciliationWitness,
            parentAuthorityIDs: Array(Set(causes.map(\.recordID) + [floor.witness.recordID])).sorted(),
            actorPrincipal: "replica:" + origin, createdAt: identity.createdAt,
            payload: [
                "itemID": .text(itemID), "parents": .list(parents.map(ItemValue.text)),
                "frontier": .list(snapshot.analysis.frontier.map(ItemValue.text)),
                "causes": .list(causes.map(\.itemValue)), "exposures": .list([floor.witness.itemValue]),
                "baseFloor": .date(floor.modifiedAt), "modifiedAt": .date(modified),
                "outputRevisionID": .text(outputID),
                "planDigest": .text(planDigest),
            ])
        let provenance = try RevisionProvenance(
            kind: .automaticMerge, originReplicaID: origin,
            parents: parents, writtenFields: [], unsetFields: [], frontier: snapshot.analysis.frontier,
            mergeProfile: AuthorityStore.reconciliationProfile,
            authorityWitness: coordinator.recordBinding(witness))
        var fields = snapshot.analysis.fields
        fields["itemID"] = .text(itemID)
        fields["revisionID"] = .text(outputID)
        fields["createdAt"] = .date(parent.createdAt)
        fields["modifiedAt"] = .date(modified)
        fields["actor"] = .text("replica:" + origin)
        fields["operationID"] = .text(outputID)
        fields["requestIdentity"] = .text(try JSON.encode(provenance.itemValue).base64EncodedString())
        fields["revisionAncestry"] = provenance.itemValue
        let revision = try Revision(fields: fields, formatVersion: 2)
        try ItemSemantics.validate(revision)
        let output = try publishVerifiedCombination(
            revision, snapshot: snapshot, policies: policies,
            using: index, authorityControls: [witness])
        let reservation = try index.reserveReconciliation(
            .init(witness: AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(witness))))
        try index.completeReconciliation(
            reservation, revision: AuthorityRevision(originalBytes: RecordCodec.encode(output)))
        try rememberHead(Self.residentHead(output))
    }
    func commitPeerIntake(
        context: PeerPackage.Context, packageID: String, expectedContextToken: String,
        retainedRecovery: Bool = false
    )
        throws -> AuthorityStore.Result
    {
        let coordinator = try requirePeerIntake()
        guard let index else {
            throw TractandaError("indexUnavailable", "Intake requires the accepted catalogue.")
        }
        return try coordinator.withOperation {
            try index.withCatalogueScanBudget(reusingActiveBudget: true) {
                try commitPeerIntakeBody(
                    context: context, packageID: packageID, expectedContextToken: expectedContextToken,
                    retainedRecovery: retainedRecovery)
            }
        }
    }
    private func commitPeerIntakeBody(
        context: PeerPackage.Context, packageID: String, expectedContextToken: String, retainedRecovery: Bool
    ) throws -> AuthorityStore.Result {
        let coordinator = try requirePeerIntake()
        if retainedRecovery {
            guard try coordinator.journal.publication(packageID) != nil else {
                throw TractandaError("invalidPeerPackage", "Retained recovery requires an existing seal.")
            }
        } else {
            try coordinator.journal.requireCurrentProfile(packageID)
        }
        let markerWasDirty = StoreCheckpoint.isDirty(root: root)
        try coordinator.requireIntakeCurrent(context, packageID: packageID)
        guard expectedContextToken == (try peerIntakeContextToken()), let index, isCanonicalReady else {
            throw TractandaError("revisionConflict", "Intake authority/current context changed.")
        }
        guard try coordinator.journal.beginRecord(packageID).context == context else {
            throw TractandaError(
                "untrustedPeer", "Package belongs to a different authenticated session/configuration.")
        }
        _ = try coordinator.journal.intakeState(context: context, packageID: packageID)
        if try coordinator.journal.publication(packageID) == nil,
            !(try index.authorityPackagePage(packageID: packageID, limit: 1)).isEmpty
        {
            throw TractandaError(
                "peerRepairRequired", "Retained package lost its admitted publication proof.")
        }
        try coordinator.prepareOriginals(
            packageID: packageID, index: index, publish: false, recovering: retainedRecovery)
        // Verify framing and full originals before sealing. Missing payload closure remains staged.
        var requiresPeerLifecycleReader = false
        var requiresEnrollmentReader = false
        let preflight = "preflight:" + packageID
        try index.authorityBeginWalk(token: preflight)
        defer { try? index.authorityEndWalk(token: preflight) }
        try coordinator.journal.walk(packageID) { descriptor, bytes in
            try coordinator.requireStorageIdentity(descriptor, index: index)
            if descriptor.kind == .attachment || descriptor.kind == .document {
                guard try index.authorityVisitOnce(token: preflight, id: descriptor.id) else {
                    throw TractandaError(
                        "invalidPeerPackage", "Repeated all-kind object identity before seal.")
                }
                return
            }
            let bytes =
                try bytes
                ?? index.retainedAuthorityObject(id: descriptor.id).flatMap { try coordinator.bytes($0) }
            guard let bytes else {
                throw TractandaError("missingDependencies", "Original object transfer is incomplete.")
            }
            guard try index.authorityVisitOnce(token: preflight, id: descriptor.id) else {
                throw TractandaError("invalidPeerPackage", "Repeated object identity in package index.")
            }
            if let known = try index.retainedAuthorityObject(id: descriptor.id) {
                guard known.descriptor == descriptor, try coordinator.bytes(known) == bytes else {
                    throw TractandaError(
                        "peerObjectCollision", "Retained identity differs; incoming stage is preserved.")
                }
                try coordinator.requireRetainedReceipt(known, original: bytes, index: index)
            } else if descriptor.kind == .item, let known = try index.revision(descriptor.id) {
                _ = try PooledCanonicalRecord.read(row: known, root: root, ownerUID: ownerUID)
                guard known.digest == Data(SHA256.hash(data: bytes)) else {
                    throw TractandaError(
                        "peerObjectCollision", "Existing history differs; incoming stage is preserved.")
                }
            }
            switch descriptor.kind {
            case .item:
                guard try AuthorityRevision(originalBytes: bytes).revision.revisionID == descriptor.id else {
                    throw TractandaError(
                        "invalidPeerPackage", "Item descriptor identity differs from original.")
                }
            case .authority:
                let record = try AuthorityRecordCodec.decode(bytes).record
                guard record.recordID == descriptor.id, record.storeID == context.storeID else {
                    throw TractandaError(
                        "invalidPeerPackage", "Control descriptor identity/store differs from original.")
                }
                if record.kind == .enrollmentApproval { requiresEnrollmentReader = true }
                if record.kind == .originRetirement || record.kind == .originRetirementPage {
                    requiresPeerLifecycleReader = true
                }
            default:
                throw TractandaError(
                    "missingDependencies", "Payload closure is not enabled in metadata intake.")
            }
        }
        let begin = try coordinator.journal.beginRecord(packageID)
        if try coordinator.journal.publication(packageID) == nil {
            let prepared =
                try coordinator.journal.preparedPublication(packageID)
                ?? .init(
                    packageID: packageID,
                    manifestDigest: AuthorityRecordCodec.sha256(try JSON.encode(begin.manifest)),
                    context: context, contextToken: expectedContextToken,
                    arrivalMinute: PeerIntakeJournal.currentArrivalMinute())
            try coordinator.journal.prepare(prepared)
            if requiresEnrollmentReader {
                try CanonicalReaderRequirement.beforeEnrollmentApprovalPublication(
                    root: root, ownerUID: ownerUID)
            } else if requiresPeerLifecycleReader {
                try CanonicalReaderRequirement.beforePeerLifecyclePublication(root: root, ownerUID: ownerUID)
            } else {
                try CanonicalReaderRequirement.beforeAuthorityPublication(root: root, ownerUID: ownerUID)
            }
            try StoreCheckpoint.markDirty(root: root)
            try coordinator.journal.seal(packageID)
        }
        try StoreCheckpoint.markDirty(root: root)
        var intakePhase = "retainingOriginals"
        do {
            try index.execute("SAVEPOINT peer_intake")
            try coordinator.retainSealed(packageID, index: index, allowReviewClosure: true)
            authorityCatchupActive = true
            defer { authorityCatchupActive = false }
            var affected: [String: [AuthorityBinding]] = [:]
            var iterations = 0
            while true {
                iterations += 1
                guard iterations <= coordinator.journal.limits.maximumWork else {
                    throw TractandaError("resourceLimit", "Intake closure work exhausted.")
                }
                let before = try index.catalogueWatermark()
                intakePhase = "validatingControls"
                try validateAuthorityControls(packageID: packageID, coordinator: coordinator, index: index)
                let admissionChanged = try activateOriginAdmissions(coordinator: coordinator, index: index)
                if admissionChanged {
                    try validateAuthorityControls(packageID: nil, coordinator: coordinator, index: index)
                    try reconsiderOriginObservations(coordinator: coordinator, index: index)
                }
                if try activatePendingRetirements(coordinator: coordinator, index: index) {
                    for (item, causes) in try reducePeerRetirements(
                        coordinator: coordinator, index: index)
                    {
                        affected[item] = Array(Set((affected[item] ?? []) + causes)).sorted {
                            $0.recordID < $1.recordID
                        }
                    }
                }
                try recheckPeerRetirementEffects(coordinator: coordinator, index: index)
                intakePhase = "evaluatingAuthority"
                _ = try coordinator.evaluatePending(
                    packageID: packageID, index: index,
                    evaluate: { node, evidence in
                        try self.evaluateIncomingAuthority(
                            node, evidence: evidence, coordinator: coordinator, index: index)
                    },
                    evaluateMaterialization: { node in
                        try self.evaluateAuthorityMaterialization(
                            node, coordinator: coordinator, index: index)
                    },
                    beforeAcceptance: { node, result in
                        try self.sealAuthorityAcceptance(
                            node, evaluation: result,
                            coordinator: coordinator, index: index)
                    })
                intakePhase = "promotingAccepted"
                try promoteEligiblePeerPackage(packageID, coordinator: coordinator, index: index)
                intakePhase = "refreshingCurrentPolicy"
                try refreshCurrentAccessConfigurations(using: index)
                intakePhase = "reducingAffectedAuthority"
                for (item, causes) in try applyAuthorityPolicyEffects(
                    packageID: packageID, coordinator: coordinator, index: index)
                {
                    affected[item] = Array(Set((affected[item] ?? []) + causes)).sorted {
                        $0.recordID < $1.recordID
                    }
                }
                if try index.catalogueWatermark() == before, !admissionChanged { break }
            }
            // All causes included in the next PRE cut now have complete affected-target effects.
            authorityCatchupActive = false
            intakePhase = "reconcilingCurrent"
            for (item, causes) in affected.sorted(by: { $0.key < $1.key }) {
                try reconcileAuthorityProjection(item, causes: causes, coordinator: coordinator, index: index)
            }
            intakePhase = "finishingDispositionEffects"
            try finishAuthorityDispositionEffects(coordinator: coordinator, index: index)
            // Finish any ordinary merge deferred by the catch-up barrier.
            var finalCursor: String?
            while true {
                let rows = try index.authorityPackagePage(
                    packageID: packageID, after: finalCursor, limit: 128)
                if rows.isEmpty { break }
                for row in rows {
                    finalCursor = row.descriptor.id
                    guard row.descriptor.kind == .item, let accepted = try index.revision(row.descriptor.id),
                        let current = try index.currentProjection(itemID: accepted.itemID),
                        current.state.status == .reviewRequired,
                        current.state.resource?.code == "authorityCatchupPending"
                    else { continue }
                    _ = try prepareRecoveredProjection(accepted.itemID, using: index)
                }
            }
            intakePhase = "recordingVisibility"
            try persistAuthorityAcceptanceEffects(
                packageID: packageID, coordinator: coordinator, index: index)
            try drainAuthorityVisibility(coordinator: coordinator, index: index)
            let result = try coordinator.evaluatePending(
                packageID: packageID, index: index,
                evaluate: { node, evidence in
                    try self.evaluateIncomingAuthority(
                        node, evidence: evidence, coordinator: coordinator, index: index)
                },
                evaluateMaterialization: { node in
                    try self.evaluateAuthorityMaterialization(node, coordinator: coordinator, index: index)
                },
                beforeAcceptance: { node, result in
                    try self.sealAuthorityAcceptance(
                        node, evaluation: result,
                        coordinator: coordinator, index: index)
                })
            try index.execute("RELEASE peer_intake")
            try coordinator.journal.applied(packageID)
            try coordinator.completeDocumentCorpus(packageID: packageID, index: index)
            if !markerWasDirty { try StoreCheckpoint.clear(root: root) }
            clearSavedViewPages()
            generation = Identifier.make()
            return result
        } catch {
            try? index.execute("ROLLBACK TO peer_intake")
            try? index.execute("RELEASE peer_intake")
            quarantineCheckpoint()
            if let failure = error as? TractandaError,
                ["resourceLimit", "projectionRequired"].contains(failure.code)
            {
                throw TractandaError(
                    failure.code, failure.message + " [intake: " + intakePhase + "]", osError: failure.osError
                )
            }
            throw error
        }
    }
    /// Validate the entire proposed initial cut with the existing disk graph/projection engine
    /// before making the private pin durable. No canonical bytes or accepted live index are copied.
    private func validateAuthorityBootstrapAdmission(index: ItemIndex) throws {
        guard let coordinator = peerIntake else {
            throw TractandaError("authorityModeRequired", "Missing authority coordinator.")
        }
        guard let localReplica = replicaID else {
            throw TractandaError(
                "missingReplicaIdentity", "Bootstrap needs the captured private replica identity.")
        }
        try AuthorityStore.validateInitialHistory(
            root: root,
            storeID: canonicalStoreIdentity(creatingIfMissing: false), replicaID: localReplica,
            files: coordinator.journal.files
        ) { id, digest in
            guard let row = try index.retainedAuthorityObject(id: id) else { return false }
            return try row.descriptor.sha256 == digest
                && index.authorityDisposition(id: id)?.disposition == .eligible
        }
        var cursor: String?
        while true {
            let rows = try index.recoveryRowPage(after: cursor)
            if rows.isEmpty { break }
            for row in rows {
                cursor = row.revisionID
                guard let retained = try index.retainedAuthorityObject(id: row.revisionID),
                    retained.path == row.path,
                    retained.descriptor.sha256 == row.digest.map({ String(format: "%02x", $0) }).joined(),
                    try index.authorityDisposition(id: row.revisionID)?.disposition == .eligible
                else {
                    throw TractandaError(
                        "authorityBootstrapRequired",
                        "The reviewed initial cut omits existing canonical history.")
                }
            }
        }
        let path = indexDirectory.appendingPathComponent("authority-cut-" + Identifier.make() + ".sqlite")
        let temporary = try ItemIndex(path: path.path, create: true)
        defer {
            try? temporary.closeChecked()
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path.path + suffix)
            }
        }
        try coordinator.withOperation(recovery: true) {
            var after: String?
            while true {
                let rows = try index.retainedAuthorityPage(after: after)
                if rows.isEmpty { break }
                for row in rows {
                    after = row.descriptor.id
                    guard row.descriptor.kind == .item,
                        try index.authorityDisposition(id: row.descriptor.id)?.disposition == .eligible
                    else { continue }
                    let node = try AuthorityRevision(originalBytes: coordinator.bytes(row))
                    try ItemSemantics.validate(node.revision)
                    try temporary.insertRecoveryRow(
                        authorityCatalogueRow(row, node: node), graphFields: node.revision.fields)
                }
            }
            try temporary.validateRecoveryGraph(
                requireLinearProjection: false, progress: coordinator.progress)
            var item: String?
            while let next = try temporary.recoveryItem(after: item) {
                item = next
                _ = try temporary.analyzeRevisionProjection(
                    itemID: next,
                    loadVerified: { row in
                        try PooledCanonicalRecord.read(row: row, root: self.root, ownerUID: self.ownerUID)
                    }, progress: coordinator.progress)
            }
        }
    }
    func pinAuthorityBootstrap(
        rootID: String, sha256: String, expectedContextToken: String, actorUID: UInt32? = nil,
        beforeAcceptance: (() throws -> Void)? = nil
    ) throws {
        if accessContext == nil {
            return try withAccess(forUID: actorUID ?? ownerUID) {
                try pinAuthorityBootstrap(
                    rootID: rootID, sha256: sha256, expectedContextToken: expectedContextToken,
                    beforeAcceptance: beforeAcceptance)
            }
        }
        try requireAdministrator()
        let coordinator = try requirePeerIntake()
        guard expectedContextToken == (try peerIntakeContextToken()), let index else {
            throw TractandaError("revisionConflict", "Bootstrap review context changed.")
        }
        let pin = AuthorityStore.BootstrapPin(
            recordID: rootID, sha256: sha256,
            actor: accessContext?.account?.name ?? "uid:\(accessContext!.uid)")
        if let old = try coordinator.configuration()?.bootstrap, old != pin {
            throw TractandaError("invalidAuthority", "The initial bootstrap cannot expand or be replaced.")
        }
        try index.execute("SAVEPOINT authority_bootstrap")
        do {
            try coordinator.seedBootstrap(pin, index: index)
            try validateAuthorityBootstrapAdmission(index: index)
            try requireAdministrator()
            try beforeAcceptance?()
            try CanonicalReaderRequirement.beforeAuthorityPublication(root: root, ownerUID: ownerUID)
            let old = try coordinator.configuration()
            try StoreCheckpoint.markDirty(root: root)
            try AuthorityStore.writeConfiguration(
                .init(
                    profile: "tractanda.peer-configuration.v1", peers: old?.peers ?? [], bootstrap: pin,
                    lifecycle: old?.lifecycle, credentialBindings: old?.credentialBindings),
                root: root, files: coordinator.journal.files)
            try index.execute("RELEASE authority_bootstrap")
        } catch {
            try? index.execute("ROLLBACK TO authority_bootstrap")
            try? index.execute("RELEASE authority_bootstrap")
            throw error
        }
        // Initial-cut promotion uses full recovery once; future ordinary appends stay incremental.
        authorityBootstrapPending = false
        authorityExistingHistoryAdmitted = true  // Exact reviewed pin is already durable above.
        try rebuildIndex()
        if let currentIndex = self.index {
            try ensureInitialAuthorityVisibility(coordinator: coordinator, index: currentIndex)
        }
        generation = Identifier.make()
    }
    private func resumePendingPeerIntakes(using coordinator: PeerIntakeCoordinator, index: ItemIndex) throws {
        var cursor: String?
        while true {
            let packages = try index.authorityPendingPackagePage(after: cursor, limit: 128)
            if packages.isEmpty { break }
            for packageID in packages {
                cursor = packageID
                guard let publication = try coordinator.journal.publication(packageID) else {
                    throw TractandaError("invalidAuthority", "Unsealed retained package.")
                }
                guard try coordinator.intakePublicationIsCurrent(publication) else { continue }
                _ = try commitPeerIntake(
                    context: publication.context, packageID: packageID,
                    expectedContextToken: peerIntakeContextToken(), retainedRecovery: true)
            }
        }
    }
}

// Durable document lifecycle is internal until the sequential producer/coordinator is wired.
extension ItemStore {
    private func saveDocumentJob(_ record: DocumentJobRecord) throws {
        documentJobs[record.intent.jobID] = record  // Fence uncertain checkpoint replies in this process.
        try documentJobRecords.save(record)
    }
    private func archiveDocumentJob(_ record: DocumentJobRecord) throws {
        try documentJobRecords.archive(record)
        stagingByteQuota.releaseJobAdmission(id: record.intent.jobID)
        documentJobs.removeValue(forKey: record.intent.jobID)
        documentJobWriters.removeValue(forKey: record.intent.jobID)
    }
    private func documentJobAuthority(_ id: String) throws -> DocumentJobRecord {
        try Identifier.validate(id)
        guard let record = try documentJobs[id] ?? documentJobRecords.archived(id),
            record.intent.actorUID == (accessContext?.uid ?? ownerUID) || isAdministrator
        else {
            throw TractandaError("notFound", "Document job is unavailable.")
        }
        _ = try get(record.intent.source.itemID)  // Fresh current source ACL even for staged reads.
        return record
    }
    private func validateDocumentJobActor(_ record: DocumentJobRecord, configurationSHA256: String) throws {
        guard configurationSHA256 == record.intent.configurationSHA256 else {
            throw TractandaError(
                "documentConfigurationChanged", "Resume requires the original configured producer identity.")
        }
        try record.intent.identity.validateCurrent()
        try withAccess(forUID: record.intent.actorUID) {
            let principal =
                accessContext!.account.map { "user:\($0.name)" } ?? "uid:\(record.intent.actorUID)"
            guard principal == record.intent.actorPrincipal else {
                throw TractandaError("documentActorChanged", "The original document actor identity changed.")
            }
            let current = try get(record.intent.source.itemID)
            try requireEdit(current)
            guard try AttachmentDescriptor.descriptors(in: current.fields).contains(record.intent.descriptor)
            else {
                throw TractandaError("documentOriginalChanged", "The job original descriptor changed.")
            }
        }
    }
    private func documentJobReplay(_ record: DocumentJobRecord) throws -> AttachmentCommitResult? {
        do {
            let intent = record.intent
            _ = try get(intent.source.itemID)
            guard let index else {
                throw TractandaError("indexUnavailable", "Cannot reconcile document operation receipts.")
            }
            func originalActorReceipt(origin: String?) throws -> ItemIndex.CatalogueRow? {
                guard
                    let receipts = try index.receipts(
                        named: intent.request.operationID, localReplicaID: origin, kind: .authored)
                else {
                    throw TractandaError(
                        "indexUnavailable", "Cannot reconcile bounded document operation receipts.")
                }
                let matches = receipts.filter { $0.actor == intent.actorPrincipal }
                if origin == nil { for row in matches { try requireLocalLegacyReceipt(row) } }
                guard matches.count <= 1 else {
                    throw TractandaError(
                        "operationMismatch", "Document intent has conflicting actor receipts.")
                }
                return matches.first
            }
            let origin =
                try replicaID
                ?? ReplicaIdentity.load(
                    root: root, storeID: canonicalStoreIdentity(creatingIfMissing: false), ownerUID: ownerUID)?
                .replicaID
            let local = try origin.flatMap { try originalActorReceipt(origin: $0) }
            guard let match = try local ?? originalActorReceipt(origin: nil) else { return nil }
            guard let prior = try loadRevision(match.revisionID) else {
                throw TractandaError(
                    "recoveryError", "Document commit receipt points to an unavailable revision.")
            }
            guard let encoded = prior.fields["requestIdentity"]?.string,
                let data = Data(base64Encoded: encoded),
                let original = try? JSON.decode(CommitRequest.self, data),
                original.action == .revise, original.itemID == intent.source.itemID,
                original.expectedRevisionID == record.checkpoint.expectedRevisionID,
                original.unset.isEmpty,
                Set(original.changes.keys) == [AttachmentDocumentRepresentation.fieldName],
                let representation = try AttachmentDocumentRepresentation.representations(
                    in: original.changes
                ).first(where: { $0.attachmentID == intent.source.attachmentID }),
                representation.source == intent.source, representation.identity == intent.identity,
                representation.extractedAt == intent.extractedAt, let content = representation.content,
                record.checkpoint.pageCount == content.pageCount,
                record.checkpoint.coverage == content.coverage,
                let prepared = record.checkpoint.prepared,
                prepared.rootEntry.sha256 == content.rootSHA256,
                prepared.byteCount == content.totalEncodedBytes
            else {
                throw TractandaError(
                    "operationMismatch", "Document operation committed a different immutable intent.")
            }
            return AttachmentCommitResult(
                CommitResult(revision: prior, wasReplayed: true, isIndexReady: isCanonicalReady, warnings: [])
            )
        }
    }
    private func reconciledDocumentJob(_ record: DocumentJobRecord) throws -> DocumentJobRecord {
        guard record.checkpoint.committed == nil, let receipt = try documentJobReplay(record),
            receipt.isIndexReady
        else {
            return record
        }
        var reconciled = record
        reconciled.checkpoint.state = "completed"
        reconciled.checkpoint.reasonCode = nil
        reconciled.checkpoint.committed = receipt
        return reconciled
    }
    func startDocumentJob(
        _ request: DocumentJobStart, identity: DocumentConverterIdentity, configurationSHA256: String
    ) throws -> DocumentJobStatus {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try startDocumentJob(request, identity: identity, configurationSHA256: configurationSHA256)
            }
        }
        try requireActivePublishingOrigin()
        let current = try get(request.itemID)
        let actor = accessContext!.uid
        if let existing = try documentJobs.values.first(where: {
            $0.intent.actorUID == actor && $0.intent.request.operationID == request.operationID
        })
            ?? documentJobRecords.archived(actorUID: actor, operationID: request.operationID)
        {
            guard existing.intent.request == request, existing.intent.identity == identity,
                existing.intent.configurationSHA256 == configurationSHA256
            else {
                throw TractandaError(
                    "operationMismatch", "Document operation already names a different job intent.")
            }
            return try documentJobStatus(existing.intent.jobID)
        }
        try requireEdit(current)
        try identity.validateCurrent()
        guard current.revisionID == request.expectedRevisionID else {
            throw TractandaError(
                "revisionConflict", "Reconcile the current item before starting a document job.")
        }
        guard
            let descriptor = try AttachmentDescriptor.descriptors(in: current.fields).first(where: {
                $0.attachmentID == request.attachmentID
            })
        else {
            throw TractandaError("notFound", "Document original is unavailable.")
        }
        guard documentJobs.count < 64,
            documentJobs.values.filter({
                $0.intent.actorUID == actor && $0.checkpoint.state != "completed" && !$0.checkpoint.discarded
            }).count < 8
        else {
            throw TractandaError("resourceLimit", "Durable document job slots are full.")
        }
        let source = try AttachmentDocumentSource(
            itemID: current.itemID, revisionID: current.revisionID,
            attachmentID: descriptor.attachmentID, sha256: descriptor.sha256, byteCount: descriptor.byteCount,
            mediaType: descriptor.mediaType)
        let intent = DocumentJobIntent(
            jobID: try UUID.makeVersion1().uuidString.lowercased(), actorUID: actor,
            actorPrincipal: accessContext!.account.map { "user:\($0.name)" } ?? "uid:\(actor)",
            request: request, descriptor: descriptor, source: source, identity: identity,
            configurationSHA256: configurationSHA256, extractedAt: Timestamp.now())
        var record = DocumentJobRecord(intent: intent)
        try record.validate()
        // Reject operation reuse before acquiring a durable new admission.
        if try priorOperation(request.operationID, uid: actor) != nil {
            throw TractandaError("operationMismatch", "Operation already committed outside this job.")
        }
        try stagingByteQuota.retainJob(id: intent.jobID, initialBytes: Int64(try JSON.encode(record).count))
        try saveDocumentJob(record)
        do {
            _ = try documentContents.beginJob(
                id: intent.jobID, source: source, identity: identity, extractedAt: intent.extractedAt)
        } catch {
            record.checkpoint.state = "paused"
            record.checkpoint.reasonCode = (error as? TractandaError)?.code ?? "documentStageUnavailable"
            try saveDocumentJob(record)
        }
        return record.status
    }
    func documentJobStatus(_ id: String) throws -> DocumentJobStatus {
        if accessContext == nil { return try withAccess(forUID: ownerUID) { try documentJobStatus(id) } }
        let record = try documentJobAuthority(id)
        if record.checkpoint.committed != nil { return record.status }
        // A read never rewrites another actor's checkpoint or acquires its producer.
        return try reconciledDocumentJob(record).status
    }
    func listDocumentJobs(afterJobID: String? = nil, limit: Int = 32) throws -> DocumentJobList {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try listDocumentJobs(afterJobID: afterJobID, limit: limit)
            }
        }
        guard (1...64).contains(limit) else {
            throw TractandaError("invalidArguments", "Job discovery limit must be1...64.")
        }
        if let afterJobID { try Identifier.validate(afterJobID) }
        var results: [DocumentJobStatus] = []
        var next: String?
        for id in documentJobs.keys.sorted() where afterJobID.map({ id > $0 }) ?? true {
            guard let record = try? documentJobAuthority(id), record.checkpoint.state != "completed",
                !record.checkpoint.discarded
            else { continue }
            if results.count == limit {
                next = results.last?.jobID
                break
            }
            let status = try documentJobStatus(id)
            if status.state != "completed" { results.append(status) }
        }
        return DocumentJobList(jobs: results, nextJobID: next)
    }
    func documentJobPage(_ id: String, pageNumber: Int64) throws -> DocumentJobPage {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) { try documentJobPage(id, pageNumber: pageNumber) }
        }
        let record = try reconciledDocumentJob(documentJobAuthority(id))
        guard !record.checkpoint.discarded, pageNumber > 0, pageNumber <= record.checkpoint.acceptedPages
        else {
            throw TractandaError("notFound", "Accepted provisional page is unavailable.")
        }
        guard record.checkpoint.committed == nil else {
            throw TractandaError(
                "documentJobCompleted", "Read committed document pages through their canonical revision.")
        }
        let page =
            try record.checkpoint.prepared.map {
                try documentContents.readPreparedJobPage($0, number: pageNumber)
            }
            ?? documentContents.readStagedPage(
                stage: record.intent.stage, source: record.intent.source,
                identity: record.intent.identity, number: pageNumber)
        return DocumentJobPage(jobID: id, outcome: page)
    }
    func controlDocumentJob(
        _ id: String, action: String, expectedRevisionID: String? = nil, configurationSHA256: String,
        deferMaterialWork: Bool = false
    ) throws -> DocumentJobStatus {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try controlDocumentJob(
                    id, action: action, expectedRevisionID: expectedRevisionID,
                    configurationSHA256: configurationSHA256, deferMaterialWork: deferMaterialWork)
            }
        }
        guard ["cancel", "resume", "rebase", "discard"].contains(action) else {
            throw TractandaError("invalidArguments", "Unknown document job control.")
        }
        var record = try documentJobAuthority(id)
        record = try reconciledDocumentJob(record)  // Lost commit reply wins over all intent mutation.
        if record.checkpoint.state == "completed" {
            if documentJobs[id] != nil {
                try saveDocumentJob(record)
                try archiveDocumentJob(record)
            }
            return record.status
        }
        if record.checkpoint.discarded {
            if action == "discard", !deferMaterialWork {
                if try hasRetainedDocumentIndexWork(record) {
                    record.checkpoint.reasonCode = "indexProjectionPending"
                    try saveDocumentJob(record)
                    return record.status
                }
                try documentContents.discardJob(
                    stage: record.intent.stage, prepared: record.checkpoint.prepared)
                if documentJobs[id] != nil { try archiveDocumentJob(record) }
            }
            return record.status
        }
        try record.checkpoint.fence()
        documentJobWriters.removeValue(forKey: id)
        if action == "cancel" || action == "discard" {
            record.checkpoint.state = "cancelled"
            record.checkpoint.reasonCode = action == "discard" ? "discarded" : "userCancelled"
            // Tombstone precedes disposal and makes interrupted discard recoverable.
            record.checkpoint.discarded = action == "discard"
            try saveDocumentJob(record)
            if action == "discard", !deferMaterialWork {
                if try hasRetainedDocumentIndexWork(record) {
                    record.checkpoint.reasonCode = "indexProjectionPending"
                    try saveDocumentJob(record)
                    return record.status
                }
                try documentContents.discardJob(
                    stage: record.intent.stage, prepared: record.checkpoint.prepared)
                if documentJobs[id] != nil { try archiveDocumentJob(record) }
            }
            return record.status
        }
        do {
            try validateDocumentJobActor(record, configurationSHA256: configurationSHA256)
            if action == "rebase" {
                guard let expectedRevisionID else {
                    throw TractandaError("invalidArguments", "Rebase requires an explicit current revision.")
                }
                try Identifier.validate(expectedRevisionID)
                guard try get(record.intent.source.itemID).revisionID == expectedRevisionID else {
                    throw TractandaError(
                        "revisionConflict", "Rebase expectation is not the current revision.")
                }
                record.checkpoint.expectedRevisionID = expectedRevisionID
                record.checkpoint.corpusArtifactName = nil
            }
            if deferMaterialWork {
                record.checkpoint.state = "queued"
                record.checkpoint.reasonCode = nil
                try saveDocumentJob(record)
                return record.status
            }
            guard try !hasRetainedDocumentIndexWork(record) else {
                throw TractandaError(
                    "indexProjectionPending",
                    "Resume retained Index work through the sequential document producer.")
            }
            _ = try documentContents.beginJob(
                id: id, source: record.intent.source, identity: record.intent.identity,
                extractedAt: record.intent.extractedAt)
            if record.checkpoint.prepared == nil {
                let writer = try documentContents.reopenJob(
                    stage: record.intent.stage, source: record.intent.source,
                    identity: record.intent.identity, extractedAt: record.intent.extractedAt,
                    acceptedPages: record.checkpoint.acceptedPages, pageCount: record.checkpoint.pageCount)
                record.checkpoint.acceptedPages = writer.acceptedPages
                record.checkpoint.coverage = try writer.coverage
                documentJobWriters[id] = writer
            } else {
                try documentContents.revalidatePrepared(record.checkpoint.prepared!)
            }
            record.checkpoint.state = record.checkpoint.prepared == nil ? "queued" : "readyToPublish"
            record.checkpoint.reasonCode = nil
        } catch {
            record.checkpoint.state = "paused"
            record.checkpoint.reasonCode = (error as? TractandaError)?.code ?? "documentRecoveryFailed"
        }
        try saveDocumentJob(record)
        return record.status
    }
    /// A producer receives one generation token; all later accepts/CAS must present it.
    func claimDocumentJob(_ id: String, configurationSHA256: String, expectedGeneration: Int64? = nil) throws
        -> DocumentJobRecord
    {
        var record = try documentJobAuthority(id)
        guard record.intent.actorUID == (accessContext?.uid ?? ownerUID), record.checkpoint.state == "queued",
            !record.checkpoint.discarded
        else {
            throw TractandaError("documentJobNotRunnable", "Job cannot admit a producer in this state.")
        }
        guard expectedGeneration.map({ $0 == record.checkpoint.generation }) ?? true else {
            throw TractandaError("documentJobFenced", "Queued admission was superseded.")
        }
        try validateDocumentJobActor(record, configurationSHA256: configurationSHA256)
        try record.checkpoint.fence()
        record.checkpoint.state = "verifyingOriginal"
        try saveDocumentJob(record)
        return record
    }
    func inspectDocumentJob(_ id: String, generation: Int64, pageCount: Int64) throws {
        var record = try runningDocumentJob(id, generation: generation)
        guard pageCount > 0, record.checkpoint.pageCount == nil || record.checkpoint.pageCount == pageCount
        else {
            throw TractandaError("documentIntegrity", "Inspected page count changed or is invalid.")
        }
        record.checkpoint.pageCount = pageCount
        record.checkpoint.state = "running"
        try saveDocumentJob(record)
    }
    private func runningDocumentJob(_ id: String, generation: Int64) throws -> DocumentJobRecord {
        let record = try documentJobAuthority(id)
        guard record.intent.actorUID == (accessContext?.uid ?? ownerUID),
            record.checkpoint.generation == generation,
            ["verifyingOriginal", "inspecting", "running", "readyToPublish"].contains(
                record.checkpoint.state), !record.checkpoint.discarded
        else {
            throw TractandaError("documentJobFenced", "Document producer was cancelled or superseded.")
        }
        try validateDocumentJobActor(record, configurationSHA256: record.intent.configurationSHA256)
        return record
    }
    func appendDocumentJobPage(_ id: String, generation: Int64, page: DocumentStoredPage) throws
        -> DocumentJobStatus
    {
        var record = try runningDocumentJob(id, generation: generation)
        guard record.checkpoint.state == "running", let pageCount = record.checkpoint.pageCount,
            page.pageNumber <= pageCount, record.checkpoint.prepared == nil
        else {
            throw TractandaError("documentIntegrity", "Page lies outside inspected terminal coverage.")
        }
        let writer: DocumentContentWriter
        if let retained = documentJobWriters[id] {
            writer = retained
        } else {
            writer = try documentContents.reopenJob(
                stage: record.intent.stage, source: record.intent.source,
                identity: record.intent.identity, extractedAt: record.intent.extractedAt,
                acceptedPages: record.checkpoint.acceptedPages, pageCount: pageCount)
            documentJobWriters[id] = writer
        }
        if page.pageNumber <= writer.acceptedPages {
            guard
                try documentContents.readStagedPage(
                    stage: record.intent.stage, source: record.intent.source,
                    identity: record.intent.identity, number: page.pageNumber) == page
            else {
                throw TractandaError("documentIntegrity", "Accepted page replay changed.")
            }
        } else {
            try writer.append(page)
        }
        record.checkpoint.acceptedPages = writer.acceptedPages
        record.checkpoint.coverage = try writer.coverage
        try saveDocumentJob(record)  // Acknowledge each sealed page before requesting the next.
        return record.status
    }
    func prepareDocumentJobPublication(_ id: String, generation: Int64) throws -> DocumentJobStatus {
        var record = try runningDocumentJob(id, generation: generation)
        guard record.checkpoint.pageCount == record.checkpoint.acceptedPages,
            record.checkpoint.acceptedPages > 0
        else {
            throw TractandaError(
                "documentIncomplete",
                "Publication requires an explicit terminal outcome for every inspected page.")
        }
        if record.checkpoint.prepared == nil {
            let writer =
                try documentJobWriters[id]
                ?? documentContents.reopenJob(
                    stage: record.intent.stage,
                    source: record.intent.source, identity: record.intent.identity,
                    extractedAt: record.intent.extractedAt,
                    acceptedPages: record.checkpoint.acceptedPages, pageCount: record.checkpoint.pageCount)
            record.checkpoint.prepared = try writer.preparePublication()
            documentJobWriters.removeValue(forKey: id)
        }
        record.checkpoint.state = "readyToPublish"
        try saveDocumentJob(record)
        return record.status
    }
    /// Called on startup only after producers are absent; cancelled work remains cancelled.
    func recoverDocumentJobs(configurationSHA256: String) throws {
        for id in documentJobs.keys.sorted() {
            guard let record = documentJobs[id] else { continue }
            if record.checkpoint.state == "completed" {
                try archiveDocumentJob(record)
            } else if record.checkpoint.discarded {
                _ = try controlDocumentJob(id, action: "discard", configurationSHA256: configurationSHA256)
            } else if record.checkpoint.state != "cancelled" {
                _ = try controlDocumentJob(id, action: "resume", configurationSHA256: configurationSHA256)
            }
        }
    }
    /// Coordinator must quiesce its child before invoking this Store-side generation fence.
    func pauseDocumentJobs(reasonCode: String) throws {
        guard ["serverShutdown", "storeMaintenance", "producerInterrupted"].contains(reasonCode) else {
            throw TractandaError("invalidArguments", "Unknown producer lifecycle pause reason.")
        }
        for id in documentJobs.keys.sorted() {
            guard var record = documentJobs[id],
                ["queued", "verifyingOriginal", "inspecting", "running", "readyToPublish"].contains(
                    record.checkpoint.state)
            else { continue }
            try record.checkpoint.fence()
            record.checkpoint.state = "paused"
            record.checkpoint.reasonCode = reasonCode
            documentJobWriters.removeValue(forKey: id)
            try saveDocumentJob(record)
        }
    }
    var afterDocumentJobCommitForTesting: (() throws -> Void)? {
        get { afterAttachmentItemCommitForTesting }
        set { afterAttachmentItemCommitForTesting = newValue }
    }
    func publishDocumentJob(_ id: String, generation: Int64) throws -> DocumentJobStatus {
        var record = try reconciledDocumentJob(documentJobAuthority(id))
        if record.checkpoint.state == "completed" {
            if documentJobs[id] != nil {
                try saveDocumentJob(record)
                try archiveDocumentJob(record)
            }
            return record.status
        }
        record = try runningDocumentJob(id, generation: generation)
        guard let prepared = record.checkpoint.prepared, record.checkpoint.state == "readyToPublish" else {
            throw TractandaError("documentIncomplete", "Prepare terminal page coverage first.")
        }
        guard try get(record.intent.source.itemID).revisionID == record.checkpoint.expectedRevisionID else {
            try pauseDocumentJob(id, generation: generation, reasonCode: "revisionConflict")
            throw TractandaError("revisionConflict", "Rebase explicitly before offline publication.")
        }
        // Explicit offline preparation, outside every head/writer transaction. Managed routing
        // uses the detached producer instead of this synchronous fixture/offline adapter.
        let corpus = try prepareOfflineDocumentCorpus(itemID: record.intent.source.itemID, prepared: prepared)
        let content = try documentContents.publishPrepared(prepared)
        return try publishIndexedDocumentJob(id, generation: generation, content: content, corpus: corpus)
    }
}

extension ItemStore {
    func documentJobMaterialWork(_ id: String, generation: Int64, configurationSHA256: String) throws
        -> DocumentJobMaterialWork
    {
        let record = try runningDocumentJob(id, generation: generation)
        try validateDocumentJobActor(record, configurationSHA256: configurationSHA256)
        return DocumentJobMaterialWork(
            intent: record.intent, checkpoint: record.checkpoint,
            payloads: attachmentPayloads, contents: documentContents)
    }
    /// Compact acceptance only; producer already sealed/validated its bounded material off queue.
    func acknowledgeDocumentStage(_ seal: DocumentStageSeal) throws -> DocumentJobStatus {
        var record = try runningDocumentJob(seal.jobID, generation: seal.generation)
        let next = record.checkpoint.acceptedPages.addingReportingOverflow(1)
        let sameCount = seal.acceptedPages == record.checkpoint.acceptedPages
        guard sameCount || (!next.overflow && seal.acceptedPages == next.partialValue) else {
            throw TractandaError(
                "documentIntegrity", "One sealed outcome must be acknowledged before another.")
        }
        let oldCounts = [
            record.checkpoint.coverage.converted, record.checkpoint.coverage.unsupported,
            record.checkpoint.coverage.truncated, record.checkpoint.coverage.timedOut,
            record.checkpoint.coverage.failed,
        ]
        let newCounts = [
            seal.coverage.converted, seal.coverage.unsupported, seal.coverage.truncated,
            seal.coverage.timedOut, seal.coverage.failed,
        ]
        guard zip(oldCounts, newCounts).allSatisfy({ $1 >= $0 }),
            !sameCount || seal.coverage == record.checkpoint.coverage
        else {
            throw TractandaError(
                "documentIntegrity", "Acknowledged outcome coverage cannot change retroactively.")
        }
        guard seal.source == record.intent.source, seal.identity == record.intent.identity,
            seal.extractedAt == record.intent.extractedAt,
            seal.acceptedPages >= record.checkpoint.acceptedPages,
            try seal.coverage.processedPageCount() == seal.acceptedPages,
            record.checkpoint.pageCount.map({ seal.acceptedPages <= $0 }) ?? (seal.acceptedPages == 0)
        else {
            throw TractandaError("documentIntegrity", "Detached stage acknowledgement binding changed.")
        }
        if let prepared = seal.prepared {
            guard prepared.stage == record.intent.stage, prepared.source == seal.source,
                prepared.identity == seal.identity, prepared.extractedAt == seal.extractedAt,
                prepared.rootEntry.lastPage == seal.acceptedPages, prepared.coverage == seal.coverage,
                seal.acceptedPages == record.checkpoint.pageCount
            else {
                throw TractandaError("documentIncomplete", "Prepared stage lacks full inspected coverage.")
            }
            record.checkpoint.prepared = prepared
            record.checkpoint.state = "readyToPublish"
        }
        record.checkpoint.acceptedPages = seal.acceptedPages
        record.checkpoint.coverage = seal.coverage
        try saveDocumentJob(record)
        return record.status
    }
}

extension ItemStore {
    /// Startup enumerates compact records only; the detached producer rebuilds/authenticates frontiers.
    func recoverDocumentJobAdmissions(configurationSHA256: String?) throws -> [DocumentJobAdmission] {
        var admissions: [DocumentJobAdmission] = []
        for id in documentJobs.keys.sorted() {
            guard let record = documentJobs[id] else { continue }
            if record.checkpoint.state == "completed" {
                try archiveDocumentJob(record)
            } else if record.checkpoint.discarded {
                admissions.append(
                    DocumentJobAdmission(
                        jobID: id, actorUID: ownerUID, generation: record.checkpoint.generation, discard: true
                    ))
            } else if let configurationSHA256,
                ["queued", "verifyingOriginal", "inspecting", "running", "readyToPublish"].contains(
                    record.checkpoint.state)
                    || [
                        "serverShutdown", "storeMaintenance", "producerInterrupted", "indexProjectionPending",
                    ].contains(record.checkpoint.reasonCode ?? "")
            {
                do {
                    _ = try withAccess(forUID: record.intent.actorUID) {
                        try controlDocumentJob(
                            id, action: "resume", configurationSHA256: configurationSHA256,
                            deferMaterialWork: true)
                    }
                } catch {
                    var paused = record
                    try paused.checkpoint.fence()
                    paused.checkpoint.state = "paused"
                    paused.checkpoint.reasonCode =
                        (error as? TractandaError)?.code ?? "documentRecoveryFailed"
                    try saveDocumentJob(paused)
                }
                if let runnable = documentJobs[id], runnable.checkpoint.state == "queued" {
                    admissions.append(
                        DocumentJobAdmission(
                            jobID: id, actorUID: runnable.intent.actorUID,
                            generation: runnable.checkpoint.generation, discard: false))
                }
            }
        }
        return admissions
    }
    func documentJobAdmission(_ id: String, discard: Bool = false) throws -> DocumentJobAdmission {
        let record = try documentJobAuthority(id)
        return DocumentJobAdmission(
            jobID: id, actorUID: discard ? (accessContext?.uid ?? ownerUID) : record.intent.actorUID,
            generation: record.checkpoint.generation, discard: discard)
    }
    func documentJobDisposalWork(_ id: String, generation: Int64) throws -> DocumentJobMaterialWork {
        // The durable authorized tombstone is the disposal capability, even if its actor was removed.
        guard let record = documentJobs[id], record.checkpoint.generation == generation,
            record.checkpoint.discarded, record.checkpoint.committed == nil
        else {
            throw TractandaError("documentJobFenced", "Job no longer owns uncommitted disposal.")
        }
        return DocumentJobMaterialWork(
            intent: record.intent, checkpoint: record.checkpoint,
            payloads: attachmentPayloads, contents: documentContents)
    }
    func acknowledgeDocumentJobDisposal(_ id: String, generation: Int64) throws {
        guard let record = documentJobs[id], record.checkpoint.generation == generation,
            record.checkpoint.discarded, record.checkpoint.committed == nil
        else {
            throw TractandaError("documentJobFenced", "Disposal acknowledgement was superseded.")
        }
        try archiveDocumentJob(record)
    }
    func pauseDocumentJob(
        _ id: String, generation: Int64, reasonCode: String, reasonMessage: String? = nil
    ) throws {
        // Failure fencing grants no content or publication rights, including after actor revocation.
        guard var record = documentJobs[id], record.checkpoint.generation == generation,
            !record.checkpoint.discarded, record.checkpoint.committed == nil,
            ["verifyingOriginal", "inspecting", "running", "readyToPublish"].contains(record.checkpoint.state)
        else {
            throw TractandaError("documentJobFenced", "Failure checkpoint was superseded.")
        }
        try record.checkpoint.fence()
        record.checkpoint.state = "paused"
        record.checkpoint.reasonCode = reasonCode
        record.checkpoint.reasonMessage = reasonMessage
        try saveDocumentJob(record)
    }
    func retainDocumentJobForIndex(_ id: String, generation: Int64) throws {
        var record = try runningDocumentJob(id, generation: generation)
        guard record.checkpoint.prepared != nil else {
            throw TractandaError("documentIncomplete", "Index publication requires a sealed document.")
        }
        record.checkpoint.state = "readyToPublish"
        record.checkpoint.reasonCode = "indexProjectionPending"
        try saveDocumentJob(record)
    }
}

extension ItemStore {
    /// Safe failure metadata only: a stale admission cannot stop a later explicit resume/rebase.
    func pauseQueuedDocumentJob(_ admission: DocumentJobAdmission, reasonCode: String) throws {
        guard var record = documentJobs[admission.jobID], !admission.discard,
            record.intent.actorUID == admission.actorUID,
            record.checkpoint.generation == admission.generation,
            record.checkpoint.state == "queued", !record.checkpoint.discarded
        else { return }
        try record.checkpoint.fence()
        record.checkpoint.state = "paused"
        record.checkpoint.reasonCode = reasonCode
        try saveDocumentJob(record)
    }
}

extension ItemStore {
    func capturePageCorpus(itemID: String, incoming: PreparedDocumentContent? = nil) throws
        -> StoredPageCorpusSnapshot
    {
        let current = try get(itemID)
        let plan = try incoming.map { prepared in
            try PageCorpusDocumentPlan(
                attachmentID: prepared.source.attachmentID,
                source: prepared.source, identity: prepared.identity, extractedAt: prepared.extractedAt,
                rootSHA256: prepared.rootEntry.sha256, pageCount: prepared.rootEntry.lastPage,
                totalEncodedBytes: prepared.byteCount, coverage: prepared.coverage)
        }
        return StoredPageCorpusSnapshot(
            input: try PageCorpusInput(
                storeID: canonicalStoreIdentity(creatingIfMissing: false), revision: current, incoming: plan),
            provider: StoredPageCorpusProvider(contents: documentContents, incoming: incoming))
    }
    func captureIndexedCorpus(itemID: String, expectedRevisionID: String? = nil) throws
        -> IndexedCorpusSnapshot?
    {
        let current = try get(itemID)
        guard expectedRevisionID == nil || expectedRevisionID == current.revisionID else {
            throw TractandaError("revisionConflict", "Current corpus head changed.")
        }
        guard isCanonicalReady, let index else {
            throw TractandaError("indexUnavailable", "Current lexical index is unavailable.")
        }
        guard !current.isDeleted else { return nil }
        guard try index.corpusMatches(current),
            let preflight = try index.captureCorpusSnapshot(
                itemID: itemID, expectedRevisionID: current.revisionID)
        else {
            throw TractandaError(
                "indexProjectionPending", "Current authenticated corpus components are incomplete.")
        }
        guard preflight.identity.unitCount > 0 else { return nil }
        let id = try UUID.makeVersion1().uuidString.lowercased()
        guard try index.corpusRetainedBytes(id) == 0 else {
            throw TractandaError("identifierCollision", "Reader retention identity is already owned.")
        }
        let charge = try ItemIndex.corpusReadLeaseCharge(id, identity: preflight.identity)
        try requireIndexFilesystemCapacity(additionalBytes: 65_536 + Int64(preflight.links.count) * 4096)
        try stagingByteQuota.reserveDerived(workID: id, estimatedAdditionalBytes: charge)
        do {
            guard
                let snapshot = try index.captureCorpusSnapshot(
                    itemID: itemID, expectedRevisionID: current.revisionID, retentionID: id)
            else {
                throw TractandaError(
                    "indexProjectionPending", "Current corpus disappeared before reader capture.")
            }
            // Accounting follows COMMIT before capacity, permissions or any other later failure.
            try stagingByteQuota.observeDerived(
                workID: id, retainedEncodedBytes: index.corpusRetainedBytes(id))
            try requireIndexFilesystemCapacity(additionalBytes: 0)
            try revalidateIndexedCorpus(snapshot)
            return snapshot
        } catch {
            let failure = error
            // Even an uncertain capture reply can have committed a durable header. No reader
            // escaped, so this ID is fenced for retirement; failures retain debt and retry proof.
            do {
                let retained = try index.corpusRetainedBytes(id)
                try stagingByteQuota.observeDerived(
                    workID: id, retainedEncodedBytes: retained, recovering: true)
                if retained > 0 {
                    pendingCorpusReadReleases.insert(id)
                    try? retireCorpusReadLease(id)
                }
            } catch {
                // An unreadable ledger cannot prove rollback/disposal; preserve the fenced ID.
                pendingCorpusReadReleases.insert(id)
            }
            throw failure
        }
    }
    func revalidateIndexedCorpus(_ snapshot: IndexedCorpusSnapshot) throws {
        let current = try get(snapshot.identity.itemID)  // Fresh current ACL before delivery.
        guard isCanonicalReady, let index else {
            throw TractandaError("indexUnavailable", "Current lexical index is unavailable.")
        }
        guard current.revisionID == snapshot.identity.revisionID, try index.corpusMatches(current) else {
            throw TractandaError("revisionConflict", "Current authenticated corpus binding changed.")
        }
        try index.validateCorpusReadLease(snapshot)
    }
    func releaseIndexedCorpus(_ snapshot: IndexedCorpusSnapshot) throws {
        // Owning caller has finished every detached reader before presenting this disposal proof.
        if let id = snapshot.retentionID {
            pendingCorpusReadReleases.insert(id)
            try retireCorpusReadLease(id)
        }
    }
    private func retireCorpusReadLease(_ id: String) throws {
        guard let index else {
            throw TractandaError("indexUnavailable", "Reader debt cannot be reconciled without its index.")
        }
        let before = try index.corpusRetainedBytes(id)
        if before == 0 {
            // A normal read-work header has positive charge. An absent header needs no writer
            // transaction or failed-disposal proof; this also makes repeated release idempotent.
            try stagingByteQuota.observeDerived(workID: id, retainedEncodedBytes: 0, recovering: true)
            pendingCorpusReadReleases.remove(id)
            return
        }
        var failure: Error?
        do {
            try beforeCorpusReadReleaseForTesting?(id)
            try index.releaseCorpusWork(id)
        } catch { failure = error }
        // Reconcile actual committed bytes even if the release reply/budget check failed.
        try stagingByteQuota.observeDerived(
            workID: id, retainedEncodedBytes: index.corpusRetainedBytes(id), recovering: true)
        if let failure { throw failure }
        pendingCorpusReadReleases.remove(id)
    }
    @discardableResult
    func retireOnePendingCorpusRead() throws -> Bool {
        guard let id = pendingCorpusReadReleases.sorted().first else { return false }
        try retireCorpusReadLease(id)
        return true
    }
    private func reclaimStartupCorpusReaders() throws {
        // Constructor owns exclusive store/index writer locks; no reader in this process exists.
        // Old process leases are fenced, while stage/discard ownership and canonical links survive.
        guard let index else { return }
        var cursor: String?
        while true {
            let page = try index.corpusReadWorkPage(after: cursor, limit: 64)
            guard !page.isEmpty else { break }
            for id in page {
                pendingCorpusReadReleases.insert(id)
                try retireCorpusReadLease(id)
                cursor = id
            }
        }
        try restoreCorpusRecoveryCharges()  // Observe any shared ownership transfers after retirement.
    }
    func corpusReadStateForTesting() throws -> (count: Int, charge: Int64, pending: Int) {
        guard let index else { throw TractandaError("indexUnavailable", "Reader state is unavailable.") }
        let ids = try index.corpusReadWorkPage(limit: 64)
        var charge: Int64 = 0
        for id in ids { charge += stagingByteQuota.corpusCharge(id) }
        return (ids.count, charge, pendingCorpusReadReleases.count)
    }
    func requireIndexFilesystemCapacity(additionalBytes: Int64) throws {
        guard additionalBytes >= 0 else {
            throw TractandaError("resourceLimit", "Negative index growth estimate.")
        }
        var capacity = statvfs()
        guard statvfs(indexDirectory.path, &capacity) == 0, capacity.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot determine genuine index-filesystem capacity.")
        }
        let available = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
        let required = UInt64(attachmentUploadPolicy.minimumFreeBytes).addingReportingOverflow(
            UInt64(additionalBytes))
        guard !available.overflow, !required.overflow, available.partialValue >= required.partialValue else {
            throw TractandaError("resourceLimit", "Index write would cross the genuine-free reserve.")
        }
    }
}

extension ItemStore {
    func documentJobProjectionWork(_ id: String, generation: Int64) throws -> DocumentJobProjectionWork {
        let record = try runningDocumentJob(id, generation: generation)
        guard let prepared = record.checkpoint.prepared,
            record.checkpoint.state == "readyToPublish"
        else {
            throw TractandaError("documentIncomplete", "Index projection requires a sealed document.")
        }
        let current = try get(record.intent.source.itemID)
        try requireEdit(current)
        guard current.revisionID == record.checkpoint.expectedRevisionID else {
            throw TractandaError("revisionConflict", "Rebase explicitly before projecting retained pages.")
        }
        return DocumentJobProjectionWork(
            jobID: id, generation: generation,
            snapshot: try capturePageCorpus(itemID: current.itemID, incoming: prepared),
            contents: documentContents, quota: stagingByteQuota,
            indexPath: indexDirectory.appendingPathComponent("items.sqlite").path,
            maximumBytes: attachmentUploadPolicy.maximumStagedBytes,
            minimumFreeBytes: attachmentUploadPolicy.minimumFreeBytes,
            retainedArtifact: record.checkpoint.corpusArtifactName)
    }
    func acknowledgeDocumentCorpus(_ id: String, generation: Int64, prepared: PreparedPageCorpus) throws {
        var record = try runningDocumentJob(id, generation: generation)
        let actual = try documentJobProjectionWork(id, generation: generation)
        guard prepared.receipt.source == actual.snapshot.input.binding,
            prepared.directory.deletingLastPathComponent().lastPathComponent == "corpus",
            prepared.directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == id
        else {
            throw TractandaError("documentIntegrity", "Corpus seal belongs to another current job/base.")
        }
        record.checkpoint.corpusArtifactName = prepared.directory.lastPathComponent
        try saveDocumentJob(record)
    }
    func publishIndexedDocumentJob(
        _ id: String, generation: Int64,
        content: DocumentContentReference, corpus: IndexedCorpusStage
    ) throws -> DocumentJobStatus {
        var record = try reconciledDocumentJob(documentJobAuthority(id))
        if record.checkpoint.state == "completed" {
            if documentJobs[id] != nil {
                try saveDocumentJob(record)
                try archiveDocumentJob(record)
            }
            return record.status
        }
        record = try runningDocumentJob(id, generation: generation)
        guard let prepared = record.checkpoint.prepared, record.checkpoint.state == "readyToPublish",
            content.rootSHA256 == prepared.rootEntry.sha256,
            content.pageCount == prepared.rootEntry.lastPage,
            content.totalEncodedBytes == prepared.byteCount, content.coverage == prepared.coverage,
            corpus.workID == id
        else {
            throw TractandaError("documentIntegrity", "Publication capability binding changed.")
        }
        let current = try get(record.intent.source.itemID)
        try requireEdit(current)
        guard current.revisionID == record.checkpoint.expectedRevisionID,
            corpus.source
                == (try documentJobProjectionWork(id, generation: generation)).snapshot.input.binding
        else {
            throw TractandaError("revisionConflict", "Current projection/publication expectation changed.")
        }
        let representation = try AttachmentDocumentRepresentation(
            representationID: makePersistentUUID().uuidString.lowercased(),
            attachmentID: record.intent.source.attachmentID, source: record.intent.source,
            extractedAt: record.intent.extractedAt, identity: record.intent.identity, content: content)
        var documents = try activeDocuments(
            in: current.fields, originals: AttachmentDescriptor.descriptors(in: current.fields))
        documents.removeAll { $0.attachmentID == record.intent.source.attachmentID }
        documents.append(representation)
        try beforeDocumentJobCommitForTesting?()
        let result = try commitInternal(
            CommitRequest(
                action: .revise, itemID: current.itemID,
                expectedRevisionID: record.checkpoint.expectedRevisionID,
                changes: [
                    AttachmentDocumentRepresentation.fieldName: .list(try documents.map { try $0.itemValue })
                ],
                operationID: record.intent.request.operationID), indexedCorpus: corpus)
        try afterDocumentJobCommitForTesting?()
        guard result.isIndexReady else {
            try pauseDocumentJob(id, generation: generation, reasonCode: "indexUnavailable")
            throw TractandaError(
                "indexUnavailable",
                "Canonical content committed; rebuild before claiming completed search readiness.")
        }
        try stagingByteQuota.observeDerived(
            workID: id,
            retainedEncodedBytes: index?.corpusRetainedBytes(id) ?? 0, recovering: true)
        record.checkpoint.committed = AttachmentCommitResult(result)
        record.checkpoint.state = "completed"
        record.checkpoint.reasonCode = nil
        try saveDocumentJob(record)
        try archiveDocumentJob(record)
        return record.status
    }
}

extension ItemStore {
    func checkDocumentIndexBoundary(
        _ id: String, generation: Int64,
        binding: PageCorpusBinding, reserveBytes: Int64
    ) throws {
        let actual = try documentJobProjectionWork(id, generation: generation)
        guard actual.snapshot.input.binding == binding else {
            throw TractandaError("revisionConflict", "Current source/ordinary projection changed.")
        }
        try requireIndexFilesystemCapacity(additionalBytes: reserveBytes)
        if reserveBytes > 0 {
            try stagingByteQuota.reserveDerived(workID: id, estimatedAdditionalBytes: reserveBytes)
        }
    }
    func observeDocumentIndexWork(_ id: String, retainedEncodedBytes: Int64) throws {
        // Safe ledger reconciliation must still happen when the actor disappears after COMMIT.
        try stagingByteQuota.observeDerived(workID: id, retainedEncodedBytes: retainedEncodedBytes)
        try requireIndexFilesystemCapacity(additionalBytes: 0)
    }
}

extension ItemStore {
    /// One canonical current revision per call; no array of complete 8 MiB records is assembled.
    func semanticCurrentRevision(after itemID: String? = nil) throws -> Revision? {
        guard isCanonicalReady, let index else {
            throw TractandaError("indexUnavailable", "Current semantic cursor requires a trusted index.")
        }
        if let itemID { try Identifier.validate(itemID) }
        guard let head = try index.checkpointHead(after: itemID) else { return nil }
        let revision = try get(head.itemID)
        guard revision.revisionID == head.revisionID else {
            throw TractandaError("revisionConflict", "Semantic maintenance head changed.")
        }
        return revision
    }
}

extension ItemStore {
    func semanticVectorWriteBoundary(_ batch: Vec1WriteBatch) throws {
        let work = "vector:" + batch.generationID
        switch batch.phase {
        case .beforeAppend:
            try requireIndexFilesystemCapacity(additionalBytes: batch.estimatedAdditionalBytes)
            try stagingByteQuota.reserveDerived(
                workID: work, estimatedAdditionalBytes: batch.estimatedAdditionalBytes)
        case .afterAppend:
            // Held Vector writer transaction: no Store/SQLite re-entry or invented physical observation.
            break
        case .afterCommit:
            try stagingByteQuota.observeDerived(
                workID: work, retainedEncodedBytes: batch.retainedEncodedBytes)
            try requireIndexFilesystemCapacity(additionalBytes: 0)
        case .rollback:
            stagingByteQuota.releaseDerivedReservation(workID: work)
        case .promotion, .disposal:
            try stagingByteQuota.observeDerived(workID: work, retainedEncodedBytes: 0, recovering: true)
            try requireIndexFilesystemCapacity(additionalBytes: 0)
        }
    }
}

extension ItemStore {
    /// Explicit synchronous offline preparation. Managed routes perform these stages off queue.
    func prepareAttachmentDocumentCorpus(
        _ snapshot: DocumentExtractionSnapshot,
        prepared: PreparedDocumentContent, cancellation: DocumentConversionCancellation? = nil
    ) throws -> IndexedCorpusStage {
        let current = try get(snapshot.source.itemID)
        try requireEdit(current)
        guard current.revisionID == snapshot.source.revisionID,
            prepared.source == snapshot.source, prepared.identity == snapshot.identity
        else {
            throw TractandaError("revisionConflict", "Offline projection source/base changed.")
        }
        return try prepareOfflineDocumentCorpus(
            itemID: current.itemID, prepared: prepared,
            cancellation: cancellation)
    }
    private func prepareOfflineDocumentCorpus(
        itemID: String, prepared: PreparedDocumentContent,
        cancellation: DocumentConversionCancellation? = nil
    ) throws -> IndexedCorpusStage {
        let snapshot = try capturePageCorpus(itemID: itemID, incoming: prepared)
        let workID = prepared.stage.last!
        let root = try documentContents.offlineCorpusRoot(workID)
        let reservation = "offline-spool:" + workID
        let path = ["documents", ".staging", "corpus-" + workID]
        let policy = try PageCorpusSpoolPolicy(
            maximumBytes: attachmentUploadPolicy.maximumStagedBytes,
            minimumFreeBytes: attachmentUploadPolicy.minimumFreeBytes,
            stagingBoundary: { [stagingByteQuota] directory, growth in
                try cancellation?.check()
                if directory == root {
                    try stagingByteQuota!.reserveDerived(
                        workID: reservation, estimatedAdditionalBytes: growth)
                } else {
                    try stagingByteQuota!.observePrivateCorpus(
                        path: path, reservationID: reservation,
                        encodedBytes: PageCorpusAllocation.usage(at: directory).logicalBytes)
                    try stagingByteQuota!.reserveDerived(
                        workID: reservation, estimatedAdditionalBytes: growth)
                }
            })
        let spool = try PageCorpusProjection.prepare(
            input: snapshot.input, provider: snapshot.provider,
            root: root, policy: policy, boundary: { try cancellation?.check() })
        let stage = try ItemIndex.stageCorpus(
            indexPath: indexDirectory.appendingPathComponent("items.sqlite").path,
            input: snapshot.input, prepared: spool, workID: workID,
            writeBoundary: { batch in
                try cancellation?.check()
                if batch.phase == .before {
                    try self.requireIndexFilesystemCapacity(additionalBytes: batch.estimatedAdditionalBytes)
                    try self.stagingByteQuota.reserveDerived(
                        workID: workID, estimatedAdditionalBytes: batch.estimatedAdditionalBytes)
                } else if batch.phase == .afterCommit {
                    try self.observeDocumentIndexWork(
                        workID, retainedEncodedBytes: batch.retainedEncodedBytes)
                }
            }, boundary: { try cancellation?.check() })
        try documentContents.discardOfflineCorpus(workID)
        stagingByteQuota.release(path: path)
        stagingByteQuota.releaseDerivedReservation(workID: reservation)
        return stage
    }
}

extension ItemStore {
    func restoreCorpusRecoveryCharges() throws {
        guard let index else { return }
        var cursor: String?
        while true {
            let page = try index.retainedCorpusWorkPage(after: cursor, limit: 64)
            guard !page.isEmpty else { break }
            for work in page {
                try retireFinishedOrIdlePeerCorpus(work.workID, index: index)
                try stagingByteQuota.observeDerived(
                    workID: work.workID,
                    retainedEncodedBytes: index.corpusRetainedBytes(work.workID), recovering: true)
                cursor = work.workID
            }
        }
    }
    func semanticVectorIndexDisposed() {
        // Called only after storage is drained/closed and all owned Vector files are gone.
        stagingByteQuota.releaseDerivedNamespace(prefix: "vector:")
    }
}

extension ItemStore {
    /// Compare the actual common lexical FTS rows for bounded ordinary canonical values.
    /// Referenced documents retain their authenticated source bindings and use bounded unit reads.
    func ownedFTSTextState(for revision: Revision) throws -> String {
        _ = try get(revision.itemID)
        guard let index else {
            throw TractandaError("indexUnavailable", "Current lexical index is unavailable.")
        }
        let statement = try index.corpusPrepare(
            "SELECT u.origin,p.text FROM corpus_link l JOIN corpus_generation g ON g.id=l.generation_id AND g.state='ready' JOIN corpus_unit u ON u.generation_id=g.id JOIN page_text_index p ON p.rowid=u.id WHERE l.item_id=? AND g.kind='field' ORDER BY u.ordinal",
            [revision.itemID])
        defer { sqlite3_finalize(statement) }
        var state = "current"
        func text(_ column: Int32) throws -> String {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count >= 0, count <= 16 * 1024 * 1024,
                let pointer = sqlite3_column_text(statement, column)
            else {
                throw TractandaError("indexError", "Malformed lexical source row.")
            }
            let data = Data(bytes: pointer, count: count)
            guard String(data: data, encoding: .utf8) != nil else {
                throw TractandaError("indexError", "Malformed lexical UTF8 row.")
            }
            return String(decoding: data, as: UTF8.self)
        }
        try IndexCorpusPlan.forEachField(revision) { path, value in
            guard state == "current" else { return }
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                state = "missing"
                return
            }
            guard step == SQLITE_ROW else {
                throw TractandaError("indexError", "Lexical source query failed.")
            }
            let origin = try JSON.decode(PageCorpusOrigin.self, Data(text(0).utf8))
            let indexedText = try text(1)
            if origin.kind != "field" || origin.fieldPath != path || indexedText != value {
                state = "stale"
            }
        }
        if state == "current", sqlite3_step(statement) != SQLITE_DONE { state = "stale" }
        return state
    }
}

extension ItemStore {
    private func retireFinishedOrIdlePeerCorpus(_ workID: String, index: ItemIndex) throws {
        guard let owner = try index.peerDocumentCorpusOwner(workID) else { return }
        var applied = false
        if UUID(uuidString: owner.package)?.version1Components != nil, let peerIntake,
            try peerIntake.journal.publication(owner.package) != nil
        {
            let begin = try peerIntake.journal.beginRecord(owner.package)
            applied =
                try peerIntake.journal.intakeState(context: begin.context, packageID: owner.package).phase
                == .applied
        }
        let observations =
            try applied
            ? index.completePeerDocumentCorpus(packageID: owner.package, workID: workID, limit: 1)
            : index.expirePeerDocumentCorpus(workID)
        for work in observations {
            try stagingByteQuota.observeDerived(
                workID: work.workID, retainedEncodedBytes: work.retainedEncodedBytes, recovering: true)
        }
    }
    func documentJobIndexRecoveryWork(_ id: String, generation: Int64, discard: Bool)
        throws -> DocumentJobIndexRecoveryWork
    {
        if discard {
            _ = try documentJobDisposalWork(id, generation: generation)
        } else {
            guard let record = documentJobs[id] else {
                throw TractandaError("documentJobFenced", "Recovery admission disappeared.")
            }
            _ = try withAccess(forUID: record.intent.actorUID) {
                try documentJobProjectionWork(id, generation: generation)
            }
        }
        guard index != nil else {
            throw TractandaError("indexUnavailable", "Document recovery requires the current index.")
        }
        return DocumentJobIndexRecoveryWork(
            indexPath: indexDirectory.appendingPathComponent("items.sqlite").path, workID: id)
    }
    /// Fresh ledger reads and observations are serialized with all new quota reservations.
    /// Reconcile both vanished charged IDs and newly transferred ledger owners, one page per call.
    func reconcileCorpusChargePage(after: String? = nil, charged: Bool) throws -> String? {
        guard let index else {
            throw TractandaError("indexUnavailable", "Cannot reconcile unavailable corpus debt.")
        }
        let ids =
            try charged
            ? stagingByteQuota.chargedCorpusWorkPage(after: after, limit: 64)
            : index.retainedCorpusWorkPage(after: after, limit: 64).map(\.workID)
        for id in ids {
            if !charged { try retireFinishedOrIdlePeerCorpus(id, index: index) }
            try stagingByteQuota.observeDerived(
                workID: id, retainedEncodedBytes: index.corpusRetainedBytes(id), recovering: true)
        }
        return ids.last
    }
}

extension ItemStore {
    func pauseDocumentJobDisposal(_ id: String, generation: Int64, reasonCode: String) throws {
        guard var record = documentJobs[id], record.checkpoint.generation == generation,
            record.checkpoint.discarded, record.checkpoint.committed == nil
        else { throw TractandaError("documentJobFenced", "Disposal checkpoint was superseded.") }
        record.checkpoint.reasonCode = reasonCode
        try saveDocumentJob(record)
    }
}

extension ItemStore {
    private func hasRetainedDocumentIndexWork(_ record: DocumentJobRecord) throws -> Bool {
        guard let index else { return record.checkpoint.corpusArtifactName != nil }
        return try index.corpusRetainedBytes(record.intent.jobID) > 0
    }
}

// Internal atomic stale-authority review; deliberately no native/public endpoint.
extension ItemStore {
    func prepareAuthorityReview(
        itemID: String, revisionID: String, evidence: AuthorityBinding, actorUID: UInt32? = nil
    ) throws -> AuthorityStore.ReviewState {
        try authorityReviewState(
            itemID: itemID, revisionID: revisionID, evidence: evidence, actorUID: actorUID,
            requireStorageReady: true)
    }
    private func authorityReviewState(
        itemID: String, revisionID: String, evidence: AuthorityBinding, actorUID: UInt32?,
        requireStorageReady: Bool
    ) throws -> AuthorityStore.ReviewState {
        let uid = actorUID ?? accessContext?.uid ?? ownerUID
        return try withAccess(forUID: uid) {
            try requireAdministrator()
            let coordinator = try requirePeerIntake()
            guard isCanonicalReady, authorityExistingHistoryAdmitted, !authorityCatchupActive,
                let index, let origin = replicaID,
                let raw = try index.retainedAuthorityObject(id: revisionID),
                raw.descriptor.kind == .item,
                try index.authorityDisposition(id: revisionID)?.disposition == .held,
                let witness = try index.retainedAuthorityObject(id: evidence.recordID),
                witness.descriptor.sha256 == evidence.sha256,
                let cut = try index.authorityControlHead(originID: origin),
                let current = try index.currentProjection(itemID: itemID)
            else {
                throw TractandaError(
                    "operationReviewRequired", "Exact held original/current review context is unavailable.")
            }
            return try coordinator.withOperation {
                try index.initializeAuthorityReviewSchema()
                let node = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
                let testimony = try AuthorityRecordCodec.decode(coordinator.bytes(witness))
                guard node.revision.itemID == itemID, try node.revision.provenance?.kind == .authored,
                    let originalOrigin = try node.revision.provenance?.originReplicaID,
                    try coordinator.freshReceipt(
                        revisionID, origin: originalOrigin, index: index,
                        forAdministratorReview: true) != nil,
                    try coordinator.freshReceipt(
                        evidence.recordID, origin: originalOrigin, index: index,
                        forAdministratorReview: true) != nil,
                    try coordinator.matchesIdentity(node, testimony.record),
                    try AuthorityRecord.list(testimony.record.payload["acceptedAuthority"]).isEmpty
                else {
                    throw TractandaError(
                        "operationReviewRequired",
                        "Review cannot enroll an origin or supply missing/unsupported original proof.")
                }
                if requireStorageReady {
                    guard try reviewStorageReady(node.revision.fields, coordinator: coordinator, index: index)
                    else {
                        throw TractandaError(
                            "reviewPreparationRequired",
                            "Run bounded review preflight before taking its snapshot.")
                    }
                }
                // Source authorization may be stale, but identity, actual intent and causal dependencies
                // must be complete. A decision never repairs forged or missing testimony.
                try coordinator.validatePolicyCut(testimony.record, index: index)
                let retirements = try index.peerRetirementCauses(
                    revisionID: revisionID, origin: originalOrigin)
                let frontier = try index.authorityReviewFrontier(revisionID: revisionID)
                let holds = try index.authorityReviewControlHolds(revisionID: revisionID, cut: cut)
                let policies = try (current.state.frontier ?? []).map { id -> AuthorityStore.Target in
                    guard let row = try index.revision(id), row.itemID == itemID,
                        try index.eligibilityAtCut(revisionID: id, cut: cut) == .eligible
                    else {
                        throw TractandaError(
                            "missingDependencies", "Review PRE policy is not accepted at its frozen cut.")
                    }
                    return try .init(
                        itemID: itemID, revisionID: id,
                        sha256: row.digest.map { String(format: "%02x", $0) }.joined())
                }
                var admissions: [ItemValue] = []
                if let row = try index.currentHeadSummary(classID: AccessConfiguration.classID),
                    let exact = try index.revision(row.revisionID)
                {
                    admissions = [
                        try AuthorityStore.Target(
                            itemID: exact.itemID, revisionID: exact.revisionID,
                            sha256: exact.digest.map { String(format: "%02x", $0) }.joined()
                        ).itemValue
                    ]
                }
                let account = accessContext?.account
                let token = AuthorityRecordCodec.sha256(
                    try JSON.encode(
                        ItemValue.object([
                            "target": AuthorityStore.Target(
                                itemID: itemID, revisionID: revisionID, sha256: node.sha256
                            ).itemValue,
                            "evidence": evidence.itemValue, "state": .text(current.state.stateToken),
                            "frontier": .list(frontier.map(\.itemValue)),
                            "holds": .list(holds.map(\.itemValue)),
                            "retirements": .list(retirements.map(\.itemValue)),
                            "policies": .list(policies.map(\.itemValue)), "admission": .list(admissions),
                            "uid": .integer(Int64(uid)), "principal": .text(account?.name ?? "uid:\(uid)"),
                            "groups": .list((account?.groupIDs.sorted() ?? []).map { .integer(Int64($0)) }),
                        ])))
                return .init(
                    original: try .init(itemID: itemID, revisionID: revisionID, sha256: node.sha256),
                    evidence: evidence, stateToken: token, decisionFrontier: frontier,
                    controlHolds: holds, policyFrontier: policies, current: current.state,
                    retirements: retirements)
            }
        }
    }
}

extension ItemStore {
    private func reviewStorageReady(
        _ fields: [String: ItemValue], coordinator: PeerIntakeCoordinator, index: ItemIndex,
        corpusScope: String? = nil
    ) throws -> Bool {
        do {
            guard
                try authorityStorageVerified(
                    fields, coordinator: coordinator, index: index, corpusScope: corpusScope)
            else { return false }
            for document in try AttachmentDocumentRepresentation.representations(in: fields)
            where document.content != nil {
                if try !index.peerDocumentCorpusReady(document) { return false }
            }
            return true
        } catch let error as TractandaError where error.code == "peerPayloadVerifying" {
            return false
        }
    }
    private func reviewPreflightScope(
        _ state: AuthorityStore.ReviewState, request: AuthorityStore.ReviewRequest?,
        uid: UInt32, coordinator: PeerIntakeCoordinator
    ) throws -> String {
        guard let origin = replicaID, let actor = accessContext?.account?.name else {
            throw TractandaError("operationReviewRequired", "Named active review origin is unavailable.")
        }
        let intent = try request.map { try JSON.encode($0) }
        guard (intent?.count ?? 0) <= PooledCanonicalRecord.maximumRecordBytes else {
            throw TractandaError("resourceLimit", "Review intent exceeds its canonical record window.")
        }
        let binding: ItemValue = .object([
            "store": .text(coordinator.storeID), "origin": .text(origin),
            "actor": .text(actor), "uid": .integer(Int64(uid)),
            "target": state.original.itemValue, "evidence": state.evidence.itemValue,
            "state": .text(state.stateToken), "phase": .text(request == nil ? "snapshot" : "resolution"),
            "intent": .text(intent?.base64EncodedString() ?? ""),
        ])
        return "local-review:" + AuthorityRecordCodec.sha256(try JSON.encode(binding))
    }
    /// A private cache handle is bound to the authenticated target/current context. Slow
    /// work is outside preview SAVEPOINTs and never mints a publication identity.
    func preflightAuthorityReview(
        itemID: String, revisionID: String, evidence: AuthorityBinding, actorUID: UInt32? = nil
    ) throws -> AuthorityStore.ReviewPreflight {
        let uid = actorUID ?? accessContext?.uid ?? ownerUID
        return try withAccess(forUID: uid) {
            try requireAdministrator()
            try requireActivePublishingOrigin()
            let coordinator = try requirePeerIntake()
            guard let index else { throw TractandaError("indexUnavailable", "Review index is unavailable.") }
            return try coordinator.withOperation {
                let state = try authorityReviewState(
                    itemID: itemID, revisionID: revisionID, evidence: evidence, actorUID: uid,
                    requireStorageReady: false)
                let scope = try reviewPreflightScope(state, request: nil, uid: uid, coordinator: coordinator)
                guard let raw = try index.retainedAuthorityObject(id: revisionID) else {
                    throw TractandaError("missingDependencies", "Held original disappeared.")
                }
                let held = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
                let ready = try reviewStorageReady(
                    held.revision.fields, coordinator: coordinator, index: index, corpusScope: scope)
                if ready {
                    let fresh = try authorityReviewState(
                        itemID: itemID, revisionID: revisionID, evidence: evidence, actorUID: uid,
                        requireStorageReady: false)
                    try requireActivePublishingOrigin()
                    guard fresh.stateToken == state.stateToken else {
                        throw TractandaError("stateConflict", "Review context changed during preparation.")
                    }
                }
                return .init(handle: scope, ready: ready)
            }
        }
    }
    func preflightAuthorityReviewResolution(
        _ request: AuthorityStore.ReviewRequest, actorUID: UInt32? = nil
    ) throws -> AuthorityStore.ReviewPreflight {
        let uid = actorUID ?? accessContext?.uid ?? ownerUID
        return try withAccess(forUID: uid) {
            try requireAdministrator()
            try requireActivePublishingOrigin()
            let coordinator = try requirePeerIntake()
            guard let index else { throw TractandaError("indexUnavailable", "Review index is unavailable.") }
            return try coordinator.withOperation {
                let state = try authorityReviewState(
                    itemID: request.itemID, revisionID: request.revisionID, evidence: request.evidence,
                    actorUID: uid, requireStorageReady: false)
                guard state.stateToken == request.expectedStateToken,
                    state.decisionFrontier == request.reviewedFrontier,
                    state.controlHolds == request.reviewedControlHolds,
                    state.retirements == request.reviewedRetirements,
                    !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
                    !request.operationID.contains("\0"),
                    Set(request.changes.keys).isDisjoint(with: request.unset),
                    Set(request.changes.keys).union(request.unset).isDisjoint(
                        with: RevisionMerge.managedFields),
                    request.unset == Array(Set(request.unset)).sorted(),
                    let raw = try index.retainedAuthorityObject(id: request.revisionID)
                else {
                    throw TractandaError("stateConflict", "Review intent must match the fresh exact context.")
                }
                let held = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
                let row = try authorityCatalogueRow(raw, node: held)
                let context = try index.previewAuthorityReviewContext(
                    held: held, heldRow: row,
                    loadVerified: {
                        try PooledCanonicalRecord.read(row: $0, root: self.root, ownerUID: self.ownerUID)
                    },
                    limits: revisionProjectionLimits, progress: coordinator.progress)
                let required = Set(context.analysis.conflicts.keys).union(context.analysis.protectedFields)
                    .union(try held.revision.provenance!.writtenFields)
                    .union(try held.revision.provenance!.unsetFields)
                guard required.isSubset(of: Set(request.changes.keys).union(request.unset)) else {
                    throw TractandaError(
                        "invalidArguments", "Explicitly choose every reviewed authored/conflicting field.")
                }
                var fields = context.analysis.fields
                fields.merge(request.changes) { _, value in value }
                for key in request.unset { fields.removeValue(forKey: key) }
                let scope = try reviewPreflightScope(
                    state, request: request, uid: uid, coordinator: coordinator)
                let ready =
                    try reviewStorageReady(
                        held.revision.fields, coordinator: coordinator, index: index, corpusScope: scope)
                    && reviewStorageReady(fields, coordinator: coordinator, index: index, corpusScope: scope)
                if ready {
                    let fresh = try authorityReviewState(
                        itemID: request.itemID, revisionID: request.revisionID, evidence: request.evidence,
                        actorUID: uid, requireStorageReady: false)
                    try requireActivePublishingOrigin()
                    guard fresh.stateToken == state.stateToken else {
                        throw TractandaError("stateConflict", "Review context changed during preparation.")
                    }
                }
                return .init(handle: scope, ready: ready)
            }
        }
    }
    private func reviewIdentityPath(origin: String, actor: String, operation: String) throws -> [String] {
        [
            "authority", "local-review-identities",
            AuthorityRecordCodec.sha256(
                try JSON.encode(
                    ItemValue.list([.text(origin), .text(actor), .text(operation)]))),
        ]
    }
    private func reviewRow(_ original: AuthorityRevision, path: String) throws -> ItemIndex.CatalogueRow {
        let m = try FileMetadata.read(at: root.appendingPathComponent(path))
        let r = original.revision
        guard m.type == .regular, m.uid == ownerUID, m.mode & 0o777 == 0o400,
            m.size == original.originalBytes.count
        else { throw TractandaError("invalidAuthority", "Review draft descriptor changed.") }
        return .init(
            revisionID: r.revisionID, itemID: r.itemID, path: path, parentID: r.supersedes,
            actor: r.fields["actor"]!.string!, operationID: r.fields["operationID"]!.string!,
            size: m.size, inode: m.inode, uid: m.uid, mode: m.mode,
            modificationSeconds: m.modificationSeconds, modificationNanoseconds: m.modificationNanoseconds,
            digest: Data(SHA256.hash(data: original.originalBytes)),
            createdAt: r.fields["createdAt"]!.dateString!,
            feedbackRevisionIDs: r.fields["learningFeedback"]?.map?.values.compactMap {
                try? LearningFeedback($0).revisionID
            } ?? [],
            modifiedAt: r.modifiedAt, provenance: try r.provenance)
    }
    private func reviewTestimony(
        revision: AuthorityRevision, identity: AuthorityStore.ReviewIdentity,
        state: AuthorityStore.ReviewState, coordinator: PeerIntakeCoordinator, index: ItemIndex,
        decision: AuthorityBinding
    ) throws -> AuthorityRecord {
        guard let context = accessContext else {
            throw TractandaError("forbidden", "Fresh reviewer identity is required.")
        }
        let account = context.account
        var names = Set(currentAccessConfigurations.flatMap(\.groups))
        names.insert(AccessConfiguration.defaultAdministratorGroup)
        names.formUnion(currentAccessConfigurations.compactMap(\.administratorGroup))
        if let account { names.insert(account.primaryGroupName) }
        for target in state.policyFrontier {
            guard let row = try index.revision(target.revisionID) else {
                throw TractandaError("missingDependencies", "Review PRE policy is missing.")
            }
            let policy = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: ownerUID).revision
            if let value = policy.fields["permissions"] {
                let permissions = try ItemPermissions(value)
                names.insert(permissions.group)
                names.formUnion(permissions.groups.keys)
            }
        }
        if let value = revision.revision.fields["permissions"] {
            let permission = try ItemPermissions(value)
            names.insert(permission.group)
            names.formUnion(permission.groups.keys)
        }
        var groups: [String: ItemValue] = [:]
        for name in names {
            let actual = accessConfiguration?.groupAliases[name] ?? name
            if let group = try? accounts.groupID(named: actual), account?.groupIDs.contains(group) == true {
                groups[actual] = .integer(Int64(group))
            }
        }
        if let account {
            var administrationGroups = Set(currentAccessConfigurations.compactMap(\.administratorGroup))
            administrationGroups.insert(AccessConfiguration.defaultAdministratorGroup)
            for name in administrationGroups {
                if let gid = try? accounts.groupID(named: name), account.groupIDs.contains(gid) {
                    groups[name] = .integer(Int64(gid))
                }
            }
        }
        var aliases: [String: ItemValue] = [:]
        for configuration in currentAccessConfigurations {
            for (name, target) in configuration.userAliases.merging(
                configuration.groupAliases,
                uniquingKeysWith: { $0 == $1 ? $0 : "" })
            {
                guard !target.isEmpty, aliases[name] == nil || aliases[name] == .text(target) else {
                    throw TractandaError("invalidAuthority", "Review alias context is ambiguous.")
                }
                aliases[name] = .text(target)
            }
        }
        var admission: [ItemValue] = []
        if let summary = try index.currentHeadSummary(classID: AccessConfiguration.classID),
            let row = try index.revision(summary.revisionID)
        {
            guard try index.eligibilityAtCut(revisionID: row.revisionID, cut: identity.preCut) == .eligible
            else {
                throw TractandaError(
                    "missingDependencies", "Review admission policy is absent from its PRE cut.")
            }
            admission = [
                try AuthorityStore.Target(
                    itemID: row.itemID, revisionID: row.revisionID,
                    sha256: row.digest.map { String(format: "%02x", $0) }.joined()
                ).itemValue
            ]
        }
        guard !admission.isEmpty else {
            throw TractandaError(
                "operationReviewRequired", "Review needs an explicit accepted administrator policy.")
        }
        let p = try revision.revision.provenance!
        return try AuthorityRecord(
            recordID: identity.evidenceID, storeID: coordinator.storeID,
            originReplicaID: identity.replicaID, kind: .authoredEvidence,
            parentAuthorityIDs: [decision.recordID, identity.preCut.recordID].sorted(),
            actorPrincipal: identity.actor,
            createdAt: identity.createdAt,
            payload: [
                "target": AuthorityStore.Target(
                    itemID: revision.revision.itemID, revisionID: revision.revision.revisionID,
                    sha256: revision.sha256
                ).itemValue,
                "parents": .list(p.parents.map(ItemValue.text)),
                "frontier": .list(p.frontier.map(ItemValue.text)),
                "itemPolicies": .list(state.policyFrontier.map(\.itemValue)),
                "admissionPolicies": .list(admission),
                "principal": .text(identity.actor), "sourceUID": .integer(Int64(context.uid)),
                "sourceAdministration": try sourceAdministration().itemValue,
                "groups": .object(groups), "aliases": .object(aliases),
                "rights": .list([.text("administrator"), .text("read"), .text("write")]),
                "evaluated": .boolean(true),
                "intent": .object([
                    "writtenFields": .list(p.writtenFields.map(ItemValue.text)),
                    "unsetFields": .list(p.unsetFields.map(ItemValue.text)),
                ]),
                "acceptedAuthority": .list([decision.itemValue]),
                "sourceControl": .list([identity.preCut.itemValue]),
            ])
    }

    func resolveAuthorityReview(_ request: AuthorityStore.ReviewRequest, actorUID: UInt32? = nil) throws
        -> AuthorityStore.ReviewResult
    {
        let uid = actorUID ?? accessContext?.uid ?? ownerUID
        return try withAccess(forUID: uid) {
            try requireAdministrator()
            let coordinator = try requirePeerIntake()
            guard isCanonicalReady, !authorityCatchupActive, let index, let origin = replicaID,
                !request.operationID.isEmpty, request.operationID.utf8.count <= 200,
                !request.operationID.contains("\0"), let account = accessContext?.account
            else {
                throw TractandaError(
                    "operationReviewRequired", "A fresh named administrator and ready Store are required.")
            }
            let encodedRequest = try JSON.encode(request)
            let requestDigest = AuthorityRecordCodec.sha256(encodedRequest)
            let reservationPath = try reviewIdentityPath(
                origin: origin, actor: account.name, operation: request.operationID)
            return try coordinator.withOperation {
                try index.withCatalogueScanBudget(reusingActiveBudget: true) {
                    try index.initializeAuthorityReviewSchema()
                    let prior = try coordinator.journal.files.readIfPresent(
                        path: reservationPath, maximumBytes: 8192)
                    let reserved = try prior.map {
                        try PeerPackage.decode(AuthorityStore.ReviewIdentity.self, $0, maximum: 8192)
                    }
                    if let reserved {
                        guard reserved.profile == "tractanda.local-authority-review.v1",
                            reserved.storeID == coordinator.storeID, reserved.replicaID == origin,
                            reserved.actor == account.name, reserved.request == requestDigest
                        else {
                            throw TractandaError(
                                "operationMismatch",
                                "This origin-pinned review operation has different intent.")
                        }
                        if try coordinator.journal.publication(reserved.packageID) != nil,
                            let raw = try index.retainedAuthorityObject(id: reserved.revisionID),
                            let d = try index.retainedAuthorityObject(id: reserved.decisionID)
                        {
                            let cOriginal = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
                            let c = cOriginal.revision
                            let decision = try AuthorityRecordCodec.decode(coordinator.bytes(d)).record
                            guard decision.kind == .reviewDecision, decision.actorPrincipal == account.name,
                                decision.originReplicaID == origin,
                                try AuthorityRecord.list(decision.payload["resolution"]) == [
                                    AuthorityStore.Target(
                                        itemID: c.itemID, revisionID: c.revisionID, sha256: cOriginal.sha256
                                    ).itemValue
                                ],
                                try AuthorityStore.Target(value: decision.payload["target"]!).revisionID
                                    == request.revisionID,
                                try AuthorityBinding(value: decision.payload["evidence"]!)
                                    == request.evidence,
                                c.fields["requestIdentity"] == .text(encodedRequest.base64EncodedString()),
                                c.fields["actor"] == .text("user:" + account.name)
                            else {
                                throw TractandaError(
                                    "operationMismatch",
                                    "Historical review receipt differs from immutable intent.")
                            }
                            // Receipt acknowledgement never re-applies the old approval or grants current access.
                            return .init(
                                revision: c,
                                decision: try .init(recordID: d.descriptor.id, sha256: d.descriptor.sha256),
                                wasReplayed: true, current: try itemState(request.itemID),
                                disposition: try currentReviewDisposition(
                                    originalID: request.revisionID, resolutionID: c.revisionID, index: index))
                        }
                    }
                    try requireActivePublishingOrigin()
                    let state = try prepareAuthorityReview(
                        itemID: request.itemID, revisionID: request.revisionID,
                        evidence: request.evidence, actorUID: uid)
                    guard state.stateToken == request.expectedStateToken,
                        state.decisionFrontier == request.reviewedFrontier,
                        state.controlHolds == request.reviewedControlHolds,
                        state.retirements == request.reviewedRetirements,
                        Set(request.changes.keys).isDisjoint(with: request.unset),
                        Set(request.changes.keys).union(request.unset).isDisjoint(
                            with: RevisionMerge.managedFields),
                        request.unset == Array(Set(request.unset)).sorted(),
                        let raw = try index.retainedAuthorityObject(id: request.revisionID),
                        let preCut = try index.authorityControlHead(originID: origin)
                    else {
                        throw TractandaError(
                            "stateConflict",
                            "Review must consume the exact current held/decision/policy context."
                        )
                    }
                    let held = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
                    let heldRow = try authorityCatalogueRow(raw, node: held)
                    let load: (ItemIndex.CatalogueRow) throws -> PooledCanonicalRecord = {
                        try PooledCanonicalRecord.read(row: $0, root: self.root, ownerUID: self.ownerUID)
                    }
                    let context = try index.previewAuthorityReviewContext(
                        held: held, heldRow: heldRow,
                        loadVerified: load, limits: revisionProjectionLimits, progress: coordinator.progress)
                    let addressed = Set(request.changes.keys).union(request.unset)
                    let required = Set(context.analysis.conflicts.keys).union(
                        context.analysis.protectedFields
                    )
                    .union(try held.revision.provenance!.writtenFields).union(
                        try held.revision.provenance!.unsetFields)
                    guard required.isSubset(of: addressed) else {
                        throw TractandaError(
                            "invalidArguments",
                            "Explicitly choose every held authored field and conflicting/protected field.")
                    }
                    var resolutionFields = context.analysis.fields
                    resolutionFields.merge(request.changes) { _, value in value }
                    for key in request.unset { resolutionFields.removeValue(forKey: key) }
                    let corpusScope = try reviewPreflightScope(
                        state, request: request, uid: uid, coordinator: coordinator)
                    guard
                        try reviewStorageReady(
                            resolutionFields, coordinator: coordinator, index: index, corpusScope: corpusScope
                        )
                    else {
                        throw TractandaError(
                            "reviewPreparationRequired",
                            "Complete bounded exact-request preflight before review publication.")
                    }
                    let identity: AuthorityStore.ReviewIdentity
                    if let reserved {
                        guard reserved.preCut == preCut else {
                            throw TractandaError(
                                "stateConflict",
                                "Unsealed review PRE cut changed; use a fresh reviewed operation.")
                        }
                        identity = reserved
                    } else {
                        identity = .init(
                            profile: "tractanda.local-authority-review.v1", storeID: coordinator.storeID,
                            replicaID: origin, actor: account.name, request: requestDigest,
                            packageID: try makePersistentUUID().uuidString.lowercased(),
                            revisionID: try makePersistentUUID().uuidString.lowercased(),
                            decisionID: try makePersistentUUID().uuidString.lowercased(),
                            evidenceID: try makePersistentUUID().uuidString.lowercased(),
                            controlID: try makePersistentUUID().uuidString.lowercased(),
                            visibilityID: try makePersistentUUID().uuidString.lowercased(),
                            createdAt: Timestamp.now(),
                            modifiedAt: try RevisionPublicationClock.after(
                                [context.clockFloor.modifiedAt], now: publicationClockForTesting),
                            preCut: preCut)
                        try coordinator.journal.files.writeImmutable(
                            try JSON.encode(identity), path: reservationPath, maximumBytes: 8192)
                    }
                    var fields = context.analysis.fields
                    for (key, value) in request.changes { fields[key] = value }
                    for key in request.unset { fields.removeValue(forKey: key) }
                    let parents = Array(Set(context.physicalHeads + [context.clockFloor.revisionID])).sorted()
                    let provenance = try RevisionProvenance(
                        kind: .resolution, originReplicaID: origin, parents: parents,
                        writtenFields: request.changes.keys.sorted(), unsetFields: request.unset,
                        frontier: context.analysis.frontier)
                    fields["itemID"] = .text(request.itemID)
                    fields["revisionID"] = .text(identity.revisionID)
                    fields["createdAt"] = held.revision.fields["createdAt"]
                    fields["modifiedAt"] = .date(identity.modifiedAt)
                    fields["actor"] = .text("user:" + account.name)
                    fields["operationID"] = .text(request.operationID)
                    fields["requestIdentity"] = .text(encodedRequest.base64EncodedString())
                    fields["revisionAncestry"] = provenance.itemValue
                    let revision = try Revision(fields: fields, formatVersion: 2)
                    try ItemSemantics.validate(revision)
                    let data = try RecordCodec.encode(revision)
                    guard data.count <= PooledCanonicalRecord.maximumRecordBytes else {
                        throw TractandaError(
                            "resourceLimit", "Complete reviewed resolution exceeds its record window.")
                    }
                    let original = try AuthorityRevision(originalBytes: data)
                    let target = try AuthorityStore.Target(
                        itemID: request.itemID, revisionID: revision.revisionID, sha256: original.sha256)
                    let draftPath = ["authority", "review-drafts", identity.revisionID + ".tractanda"]
                    if let existing = try coordinator.journal.files.readIfPresent(
                        path: draftPath, maximumBytes: PooledCanonicalRecord.maximumRecordBytes)
                    {
                        guard existing == data else {
                            throw TractandaError("operationMismatch", "Reserved review draft differs.")
                        }
                    } else {
                        try coordinator.journal.files.writeImmutable(
                            data, path: draftPath, maximumBytes: PooledCanonicalRecord.maximumRecordBytes)
                    }
                    let row = try reviewRow(original, path: draftPath.joined(separator: "/"))
                    var admissions: [ItemValue] = []
                    if let summary = try index.currentHeadSummary(classID: AccessConfiguration.classID),
                        let a = try index.revision(summary.revisionID)
                    {
                        admissions = [
                            try AuthorityStore.Target(
                                itemID: a.itemID, revisionID: a.revisionID,
                                sha256: a.digest.map { String(format: "%02x", $0) }.joined()
                            ).itemValue
                        ]
                    }
                    let d = try AuthorityRecord(
                        recordID: identity.decisionID, storeID: coordinator.storeID,
                        originReplicaID: origin, kind: .reviewDecision,
                        parentAuthorityIDs: Array(
                            Set(
                                [preCut.recordID] + state.decisionFrontier.map(\.recordID)
                                    + state.controlHolds.map(\.recordID) + state.retirements.map(\.recordID))
                        ).sorted(),
                        actorPrincipal: account.name, createdAt: identity.createdAt,
                        payload: [
                            "target": state.original.itemValue, "evidence": state.evidence.itemValue,
                            "holds": .list(state.decisionFrontier.map { .text($0.recordID) }),
                            "decisionFrontier": .list(state.decisionFrontier.map { .text($0.recordID) }),
                            "decision": .text("accept"),
                            "administrationPolicies": .list(admissions),
                            "itemPolicies": .list(state.policyFrontier.map(\.itemValue)),
                            "reason": .text("Explicit atomic administrator review with fresh resolution."),
                            "sourceControl": .list([preCut.itemValue]),
                            "resolution": .list([target.itemValue]),
                            "controlHolds": .list(state.controlHolds.map(\.itemValue)),
                            "retirements": .list(state.retirements.map(\.itemValue)),
                        ])
                    let decision = try coordinator.recordBinding(d)
                    let e = try reviewTestimony(
                        revision: original, identity: identity, state: state,
                        coordinator: coordinator, index: index, decision: decision)
                    let oldEvidence = try coordinator.control(state.evidence, index: index).record
                    func policyIDs(_ evidence: AuthorityRecord) throws -> [String] {
                        try Array(
                            Set(
                                (AuthorityRecord.list(evidence.payload["admissionPolicies"])
                                    + AuthorityRecord.list(evidence.payload["itemPolicies"]))
                                    .map { try AuthorityRecord.binding($0).revisionID })
                        ).sorted()
                    }
                    let control = try AuthorityRecord(
                        recordID: identity.controlID, storeID: coordinator.storeID,
                        originReplicaID: origin, kind: .controlCommit, parentAuthorityIDs: [preCut.recordID],
                        actorPrincipal: account.name, createdAt: identity.createdAt,
                        payload: [
                            "controls": .list([preCut.itemValue]), "localParent": .list([preCut.itemValue]),
                            "bootstrap": .list(
                                try coordinator.configuration()?.bootstrap.map {
                                    [try AuthorityBinding(recordID: $0.recordID, sha256: $0.sha256).itemValue]
                                } ?? []),
                            "deltas": .list(
                                [
                                    AuthorityStore.DispositionDelta(
                                        target: state.original, eligible: true,
                                        actor: held.revision.fields["actor"]!.string!,
                                        policyIDs: try policyIDs(oldEvidence), causes: [decision],
                                        evidence: state.evidence),
                                    AuthorityStore.DispositionDelta(
                                        target: target, eligible: true,
                                        actor: revision.fields["actor"]!.string!,
                                        policyIDs: try policyIDs(e), causes: [decision],
                                        evidence: try coordinator.recordBinding(e)),
                                ].sorted { $0.target.revisionID < $1.target.revisionID }.map(\.itemValue)),
                        ])
                    let plan = try AuthorityStore.VerifiedReviewPlan(
                        event: .init(
                            record: AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(d)),
                            parents: state.decisionFrontier),
                        held: held, heldRow: heldRow, resolution: original,
                        evidence: AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(e)),
                        control: .init(
                            control: AuthorityRecordCodec.decode(AuthorityRecordCodec.encode(control))),
                        policyFrontier: state.policyFrontier, operationID: request.operationID)
                    try preflightReviewPolicyTransitions(plan, coordinator: coordinator, index: index)
                    let draftLoad: (ItemIndex.CatalogueRow) throws -> PooledCanonicalRecord = { requested in
                        if requested.revisionID == revision.revisionID {
                            let checked = try self.reviewRow(original, path: row.path)
                            guard checked == requested,
                                try coordinator.journal.files.read(
                                    path: draftPath, maximumBytes: PooledCanonicalRecord.maximumRecordBytes)
                                    == data
                            else {
                                throw TractandaError("invalidAuthority", "Immutable review draft changed.")
                            }
                            return .init(
                                revision: revision,
                                metadata: try FileMetadata.read(
                                    at: self.root.appendingPathComponent(row.path)),
                                archived: false, metadataDrifted: false)
                        }
                        return try load(requested)
                    }
                    let reviewedPolicies = try state.policyFrontier.map { target -> Revision in
                        guard let row = try index.revision(target.revisionID) else {
                            throw TractandaError("missingDependencies", "PRE-review policy disappeared.")
                        }
                        return try load(row).revision
                    }
                    _ = try index.previewAuthorityReview(
                        plan: plan, resolutionRow: row, loadVerified: draftLoad,
                        limits: revisionProjectionLimits, progress: coordinator.progress,
                        validate: { _ in
                            try self.validateAuthorityReviewResolution(
                                revision, context: context, policies: reviewedPolicies, using: index)
                        })
                    try beforeProjectionCommitAuthorityForTesting?()
                    try withAccess(forUID: uid) {
                        try requireActivePublishingOrigin()
                        let fresh = try prepareAuthorityReview(
                            itemID: request.itemID, revisionID: request.revisionID,
                            evidence: request.evidence, actorUID: uid)
                        guard fresh.stateToken == state.stateToken else {
                            throw TractandaError(
                                "stateConflict", "Fresh authority or reviewed state changed before sealing.")
                        }
                        // C-only named principals and references are absent from the PRE token.
                        // Repeat full staged validation under fresh NSS, sharing the SAME work budget.
                        _ = try index.previewAuthorityReview(
                            plan: plan, resolutionRow: row, loadVerified: draftLoad,
                            limits: revisionProjectionLimits, progress: coordinator.progress,
                            validate: { _ in
                                try self.validateAuthorityReviewResolution(
                                    revision, context: context, policies: reviewedPolicies, using: index)
                            })
                        guard
                            try AuthorityRecordCodec.encode(
                                reviewTestimony(
                                    revision: original, identity: identity,
                                    state: state, coordinator: coordinator, index: index, decision: decision))
                                == plan.evidence.originalBytes
                        else {
                            throw TractandaError(
                                "stateConflict", "Fresh source identity testimony changed before sealing.")
                        }
                    }
                    try CanonicalReaderRequirement.beforeReviewPublication(root: root, ownerUID: ownerUID)
                    // Physical arrival is local wall time; logical modifiedAt may be far ahead.
                    let minute = String(identity.createdAt.prefix(16)).replacingOccurrences(
                        of: "-", with: "/"
                    )
                    .replacingOccurrences(of: "T", with: "/").replacingOccurrences(of: ":", with: "/")
                    let localPath =
                        "items/" + minute + "/" + request.itemID + "/" + revision.revisionID + ".tractanda"
                    let cutBinding = try coordinator.recordBinding(control)
                    let visibility = try AuthorityRecord(
                        recordID: identity.visibilityID, storeID: coordinator.storeID,
                        originReplicaID: origin,
                        kind: .visibilityWitness, parentAuthorityIDs: [cutBinding.recordID],
                        actorPrincipal: account.name, createdAt: identity.createdAt,
                        payload: [
                            "target": target.itemValue, "cut": cutBinding.itemValue,
                            "modifiedAt": .date(revision.modifiedAt), "causeKey": .list([]),
                        ])
                    let markerWasDirty = StoreCheckpoint.isDirty(root: root)
                    var sealed = false
                    do {
                        let package = try coordinator.stageLocal(
                            revision: revision, bytes: data, evidence: e,
                            contextToken: peerIntakeContextToken(), arrivalMinute: minute,
                            localItemPath: localPath,
                            controls: [d, control, visibility], afterSeal: { sealed = true },
                            reservedPackageID: identity.packageID)
                        try coordinator.retainSealed(
                            package, index: index, applyAssessment: false, allowReviewClosure: true)
                        guard let retained = try index.retainedAuthorityObject(id: revision.revisionID) else {
                            throw TractandaError("missingDependencies", "Sealed review C is unavailable.")
                        }
                        try index.execute("SAVEPOINT apply_authority_review")
                        do {
                            let after = try index.applyValidatedReview(
                                plan: plan, resolutionRow: authorityCatalogueRow(retained, node: original),
                                loadVerified: load, limits: revisionProjectionLimits,
                                progress: coordinator.progress)
                            try index.retainValidatedControl(plan.control)
                            try retainReviewPolicyInvalidations(plan, coordinator: coordinator, index: index)
                            for delta in plan.control.deltas {
                                try coordinator.restoreControlAcceptance(delta, index: index)
                            }
                            try index.retainLocalAuthorityAcceptance(plan.control)
                            try consumeRestoredAuthorityEffects(
                                plan.control, review: plan, coordinator: coordinator, index: index)
                            try index.replaceCurrentProjection(
                                snapshot: after, state: readyProjectionState(revision),
                                policies: [
                                    .init(
                                        revisionID: revision.revisionID, classID: revision.classID,
                                        permissions: revision.fields["permissions"])
                                ], policiesComplete: true)
                            try index.put(revision)
                            try index.retainValidatedExposure(
                                .init(
                                    witness: AuthorityRecordCodec.decode(
                                        AuthorityRecordCodec.encode(visibility))),
                                locallyVisible: true)
                            try index.execute("RELEASE apply_authority_review")
                        } catch {
                            try? index.execute("ROLLBACK TO apply_authority_review")
                            try? index.execute("RELEASE apply_authority_review")
                            throw error
                        }
                        try coordinator.journal.applied(package)
                        try drainAuthorityVisibility(coordinator: coordinator, index: index)
                        for work in try index.completePeerDocumentCorpus(packageID: corpusScope) {
                            try stagingByteQuota.observeDerived(
                                workID: work.workID, retainedEncodedBytes: work.retainedEncodedBytes)
                        }
                        try rememberHead(Self.residentHead(revision))
                        if revision.classID == AccessConfiguration.classID {
                            try refreshCurrentAccessConfigurations(using: index)
                        }
                        generation = Identifier.make()
                        clearSavedViewPages()
                        if !markerWasDirty { try StoreCheckpoint.clear(root: root) }
                        return .init(
                            revision: revision, decision: decision, wasReplayed: false,
                            current: try itemState(request.itemID), disposition: .approved)
                    } catch {
                        if sealed || (try? coordinator.journal.publication(identity.packageID)) != nil {
                            quarantineCheckpoint()
                        }
                        throw error
                    }
                }
            }
        }
    }
    private func currentReviewDisposition(originalID: String, resolutionID: String, index: ItemIndex) throws
        -> AuthorityStore.ReviewDisposition
    {
        let review = try index.authorityReviewDisposition(revisionID: originalID)
        if review == .approved,
            try index.authorityDisposition(id: originalID)?.disposition != .eligible
                || index.authorityDisposition(id: resolutionID)?.disposition != .eligible
        {
            return .held
        }
        return review
    }
    private func validateAuthorityReviewResolution(
        _ revision: Revision, context: RevisionProjection.Snapshot, policies: [Revision],
        using index: ItemIndex
    ) throws {
        try requireAdministrator()
        try ItemSemantics.validate(revision)
        if policies.contains(where: { $0.classID == AccessConfiguration.classID }) {
            guard revision.classID == AccessConfiguration.classID else {
                throw TractandaError("invalidAccessConfiguration", "Access configuration cannot be retyped.")
            }
        }
        if revision.classID == AccessConfiguration.classID {
            guard policies.contains(where: { $0.classID == AccessConfiguration.classID }) else {
                throw TractandaError(
                    "invalidAccessConfiguration",
                    "Review cannot create a second or retyped access configuration.")
            }
            let configuration = try AccessConfiguration(revision.fields["accessConfiguration"]!)
            try configuration.validate(
                using: PrincipalResolver(directory: accounts, configuration: configuration))
        }
        if let value = revision.fields["permissions"], let fresh = accessContext {
            try ItemPermissions(value).validate(using: fresh.resolver)
        }
        guard try !knownCategoryConstraintConflicts(replacing: revision).contains(revision.itemID) else {
            throw TractandaError("categoryCycle", "Reviewed resolution violates category invariants.")
        }
        try validateResolutionReferences(revision, snapshot: context, using: index)
        for holding in try RoleSemantics.holdings(revision) {
            let holder = try get(holding.holder.itemID, revisionID: holding.holder.revisionID)
            guard ItemTypes.ancestry(holder.classID).contains("PersonItem"), holder.classID != "RoleItem",
                !holder.isDeleted
            else { throw TractandaError("invalidHolder", "Reviewed resolution holder is unavailable.") }
        }
    }
}

extension ItemStore {
    /// Only exact D/C-bound post-controls use this path. A raw review record is never a grant.
    private func authorityReviewPlan(
        for control: AuthorityStore.VerifiedControlPlan, coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws -> AuthorityStore.VerifiedReviewPlan? {
        var selected: (AuthorityStore.DispositionDelta, AuthorityRecordCodec.Verified, AuthorityBinding)?
        for delta in control.deltas where delta.eligible {
            guard let evidence = delta.evidence,
                let raw = try index.retainedAuthorityObject(id: evidence.recordID),
                raw.descriptor.sha256 == evidence.sha256
            else { continue }
            let witness = try AuthorityRecordCodec.decode(coordinator.bytes(raw))
            guard witness.record.kind == .authoredEvidence else { continue }
            let approvals = try AuthorityRecord.list(witness.record.payload["acceptedAuthority"]).map(
                AuthorityBinding.init(value:))
            guard !approvals.isEmpty else { continue }
            if approvals.count == 1, !delta.causes.contains(approvals[0]) { continue }
            guard approvals.count == 1, selected == nil else {
                throw TractandaError("invalidAuthority", "Atomic review needs one exact fresh C decision.")
            }
            selected = (delta, witness, approvals[0])
        }
        guard let selected else { return nil }
        let d = try coordinator.control(selected.2, index: index)
        let parentIDs = try AuthorityRecord.ids(d.record.payload["decisionFrontier"])
        let parents = try parentIDs.map { id -> AuthorityBinding in
            guard let row = try index.retainedAuthorityObject(id: id), row.descriptor.kind == .authority
            else { throw TractandaError("missingDependencies", "Reviewed decision dependency is missing.") }
            return try .init(recordID: id, sha256: row.descriptor.sha256)
        }
        let event = try AuthorityStore.VerifiedReviewEvent(record: d, parents: parents)
        guard let b = try index.retainedAuthorityObject(id: event.target.revisionID),
            b.descriptor.sha256 == event.target.sha256,
            let c = try index.retainedAuthorityObject(id: event.resolution.revisionID),
            c.descriptor.sha256 == event.resolution.sha256
        else {
            throw TractandaError(
                "missingDependencies", "Atomic review omitted its exact unchanged B or fresh C.")
        }
        let held = try AuthorityRevision(originalBytes: coordinator.bytes(b))
        let resolution = try AuthorityRevision(originalBytes: coordinator.bytes(c))
        return try .init(
            event: event, held: held, heldRow: authorityCatalogueRow(b, node: held), resolution: resolution,
            evidence: selected.1, control: control,
            policyFrontier: AuthorityRecord.list(d.record.payload["itemPolicies"]).map(
                AuthorityStore.Target.init(value:)),
            operationID: resolution.revision.fields["operationID"]!.string!)
    }
    /// Re-evaluate the historical administrator proof in its frozen PRE context. Present
    /// administrator authorization is a separate mandatory runtime pre-seal check.
    private func validateHistoricalReviewAuthority(
        _ plan: AuthorityStore.VerifiedReviewPlan, coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        let evidence = plan.evidence.record
        let d = plan.event.record.record
        guard try coordinator.matchesIdentity(plan.resolution, evidence),
            d.actorPrincipal == evidence.actorPrincipal, d.originReplicaID == evidence.originReplicaID,
            evidence.payload["evaluated"] == .boolean(true),
            evidence.payload["rights"]?.array?.contains(.text("administrator")) == true,
            d.payload["administrationPolicies"] == evidence.payload["admissionPolicies"],
            d.payload["itemPolicies"] == evidence.payload["itemPolicies"],
            try !AuthorityRecord.list(evidence.payload["admissionPolicies"]).isEmpty
        else {
            throw TractandaError(
                "invalidAuthority", "Decision and C differ from their PRE-review administrator context.")
        }
        try validateReviewPolicyCut(evidence, cut: plan.event.preCut, coordinator: coordinator, index: index)
        var aliases: [String: ItemValue] = [:]
        for binding in try AuthorityRecord.list(evidence.payload["admissionPolicies"]) {
            guard let node = try coordinator.bindingAtCut(binding, cut: plan.event.preCut, index: index),
                node.revision.classID == AccessConfiguration.classID,
                let value = node.revision.fields["accessConfiguration"]
            else {
                throw TractandaError(
                    "missingDependencies", "Review's accepted administrator policy is unavailable.")
            }
            let configuration = try AccessConfiguration(value)
            let administrator = try SourceAdministration.administrator(configuration, evidence: evidence)
            guard administrator else {
                throw TractandaError(
                    "forbidden", "Decision author was not an administrator under the PRE-review policy.")
            }
            for (name, target) in configuration.userAliases.merging(
                configuration.groupAliases, uniquingKeysWith: { $0 == $1 ? $0 : "" })
            {
                guard !target.isEmpty, aliases[name] == nil || aliases[name] == .text(target) else {
                    throw TractandaError("invalidAuthority", "Review aliases conflict with its PRE policy.")
                }
                aliases[name] = .text(target)
            }
        }
        guard aliases == evidence.payload["aliases"]?.map else {
            throw TractandaError("invalidAuthority", "Review alias testimony differs from the PRE policy.")
        }
    }
    private func finishRecoveryAuthorityReviews(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws {
        var cursor: String?
        var any = false
        while true {
            let page = try index.authorityReviewItemPage(after: cursor, limit: 128)
            if page.isEmpty { break }
            for item in page {
                cursor = item
                any = true
                // Existing disk projection validates each C in its OWN parent context,
                // including earlier demotion materializations. No current cache is exposed.
                _ = try analyzeCurrentProjection(
                    item, using: index, limits: revisionProjectionLimits, progress: coordinator.progress)
            }
        }
        guard try index.authorityReviewRecoveryIsComplete() else {
            throw TractandaError("recoveryError", "Atomic review closure remains incomplete.")
        }
        if any {
            try validateAuthorityControls(
                packageID: nil, coordinator: coordinator, index: index, recovering: true)
            try reduceRetainedAuthorityInventory(coordinator: coordinator, index: index)
            cursor = nil
            while true {
                let page = try index.authorityReviewItemPage(after: cursor, limit: 128)
                if page.isEmpty { break }
                for item in page {
                    cursor = item
                    try index.reconcileAuthorityAcceptedItem(itemID: item)
                }
            }
        }
    }
}

extension ItemStore {
    /// Review policies are exact eligible AUTHORED frontier snapshots. Transparent physical
    /// materializations in the PRE cut are expanded only after the existing disk projector
    /// validates their full own-context payloads; a claimed frontier alone proves nothing.
    private func validateReviewPolicyCut(
        _ evidence: AuthorityRecord, cut: AuthorityBinding,
        coordinator: PeerIntakeCoordinator, index: ItemIndex,
        policyFields: [String] = ["admissionPolicies", "itemPolicies"]
    ) throws {
        guard try index.hasValidatedAuthorityControl(cut),
            try coordinator.control(cut, index: index).record.originReplicaID == evidence.originReplicaID
        else { throw TractandaError("missingDependencies", "Review PRE source cut is not validated.") }
        // Source PRE proof is immutable and independent of today's accepted projection.
        // Retained policies are NEVER used as a receiver-current permission fallback.
        for field in policyFields {
            var groups: [String: [AuthorityStore.Target]] = [:]
            for value in try AuthorityRecord.list(evidence.payload[field]) {
                let target = try AuthorityStore.Target(value: value)
                groups[target.itemID, default: []].append(target)
            }
            for (item, policies) in groups {
                let physical = try index.authorityItemFrontierAtCut(itemID: item, cut: cut)
                var authored: Set<String> = []
                for id in physical {
                    guard let raw = try index.retainedAuthorityObject(id: id), raw.descriptor.kind == .item
                    else {
                        throw TractandaError(
                            "missingDependencies", "Exact historical PRE policy original is absent.")
                    }
                    let node = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
                    guard node.revision.itemID == item,
                        try index.eligibilityAtCut(revisionID: id, cut: cut) == .eligible
                    else {
                        throw TractandaError(
                            "invalidAuthority", "Source PRE policy identity/eligibility differs.")
                    }
                    if try node.revision.provenance?.kind == .automaticMerge {
                        authored.formUnion(try node.revision.provenance!.frontier)
                    } else {
                        authored.insert(id)
                    }
                }
                for id in authored.sorted() {
                    for other in authored where id != other {
                        if try index.authorityRetainedHasAncestor(source: other, target: id) {
                            authored.remove(id)
                            break
                        }
                    }
                }
                guard authored.sorted() == policies.map(\.revisionID).sorted() else {
                    throw TractandaError(
                        "invalidAuthority", "Review policies are not the exact authored PRE frontier.")
                }
                for policy in policies {
                    guard try coordinator.bindingAtCut(policy.itemValue, cut: cut, index: index) != nil else {
                        throw TractandaError(
                            "missingDependencies",
                            "Exact retained policy bytes or source-cut proof is absent.")
                    }
                }
            }
        }
    }

}

extension ItemStore {
    private func retainReviewPolicyInvalidations(
        _ plan: AuthorityStore.VerifiedReviewPlan, coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        let current = plan.resolution.revision
        for target in plan.policyFrontier {
            guard let row = try index.retainedAuthorityObject(id: target.revisionID),
                row.descriptor.sha256 == target.sha256
            else {
                throw TractandaError("missingDependencies", "Reviewed PRE policy original is missing.")
            }
            let previous = try AuthorityRevision(originalBytes: coordinator.bytes(row))
            if previous.revision.fields["permissions"] != current.fields["permissions"]
                || previous.revision.fields["accessConfiguration"] != current.fields["accessConfiguration"]
            {
                try AuthorityStore.validateReviewPolicyTransition(plan, previous: previous)
                try index.retainValidatedReviewInvalidation(plan, previous: previous)
            }
        }
    }
}

extension ItemStore {
    private func preflightReviewPolicyTransitions(
        _ plan: AuthorityStore.VerifiedReviewPlan,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        for target in plan.policyFrontier {
            guard let raw = try index.retainedAuthorityObject(id: target.revisionID),
                raw.descriptor.sha256 == target.sha256
            else {
                throw TractandaError("missingDependencies", "Review PRE transition input is missing.")
            }
            let old = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
            if old.revision.fields["permissions"] != plan.resolution.revision.fields["permissions"]
                || old.revision.fields["accessConfiguration"]
                    != plan.resolution.revision.fields["accessConfiguration"]
            {
                try AuthorityStore.validateReviewPolicyTransition(plan, previous: old)
            }
        }
    }
}

extension ItemStore {
    /// Consume obsolete queued negatives only AFTER restoring the exact authorized LOCAL
    /// positive publication. This never grants a target or approves an unnamed descendant.
    private func consumeRestoredAuthorityEffects(
        _ control: AuthorityStore.VerifiedControlPlan, review: AuthorityStore.VerifiedReviewPlan?,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        guard let origin = replicaID, control.control.record.originReplicaID == origin else { return }
        for delta in control.deltas where delta.eligible {
            if let review {
                try index.consumeSupersededAuthorityEffect(
                    control: control.binding, originID: origin,
                    target: delta.target, cut: review.event.preCut, review: review)
            } else if let binding = delta.evidence,
                let raw = try index.retainedAuthorityObject(id: delta.target.revisionID)
            {
                let original = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
                guard try original.revision.provenance?.kind == .authored else { continue }
                let evidence = try coordinator.control(binding, index: index)
                guard let cut = try coordinator.sourceControl(evidence.record) else { continue }
                try index.consumeSupersededAuthorityEffect(
                    control: control.binding, originID: origin,
                    target: delta.target, cut: cut, original: original, evidence: evidence)
            }
        }
    }
}

extension ItemStore {
    /// A later sealed LOCAL authored publication can become eligible only after a
    /// provisional review parent completes, after the initial canonical scan. Restore
    /// exactly that accepted fact incrementally, never by rescanning the store.
    private func restoreRecoveredLocalAuthored(
        _ control: AuthorityStore.VerifiedControlPlan, coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        guard indexRebuildInProgress, try index.acceptedGraphProofIsCurrent() else { return }
        for delta in control.deltas where delta.eligible {
            guard try index.revision(delta.target.revisionID) == nil,
                let selected = delta.evidence,
                let raw = try index.retainedAuthorityObject(id: delta.target.revisionID)
            else { continue }
            let original = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
            guard try original.revision.provenance?.kind == .authored else { continue }
            let evidence = try coordinator.control(selected, index: index)
            let revision = original.revision
            // Use the SAME ownership/digest/dependency registries as the initial scan.
            // These checks never infer a client permission or fetch a remote payload.
            for attachment in try AttachmentDescriptor.descriptors(in: revision.fields) {
                if try index.registerRecoveryAttachment(attachment, itemID: revision.itemID) {
                    let control = rebuildControl
                    let startingBytes = control?.status.originalBytesVerified ?? 0
                    try attachmentPayloads.validate(
                        descriptor: attachment,
                        progress: { verified in
                            let prior = control?.status.originalBytesVerified ?? startingBytes
                            let total = startingBytes.addingReportingOverflow(verified)
                            guard !total.overflow else {
                                throw TractandaError(
                                    "resourceLimit", "Recovered dependency byte progress overflowed.")
                            }
                            try control?.pulse(originalBytes: total.partialValue - prior)
                        })
                    attachmentRecoveryValidationsForTesting += 1
                }
            }
            for document in try AttachmentDocumentRepresentation.representations(in: revision.fields) {
                if let content = document.content,
                    try index.registerRecoveryDocument(document, itemID: revision.itemID)
                {
                    try documentContents.validate(
                        content, source: document.source, identity: document.identity,
                        extractedAt: document.extractedAt, boundary: { try self.rebuildControl?.check() },
                        progress: { _ in try self.rebuildControl?.pulse(pages: 1) })
                }
            }
            try index.restoreLocallyAcceptedAuthored(
                row: authorityCatalogueRow(raw, node: original),
                original: original, control: control.binding, evidence: evidence,
                loadVerified: {
                    try PooledCanonicalRecord.read(row: $0, root: self.root, ownerUID: self.ownerUID)
                },
                limits: revisionProjectionLimits, progress: coordinator.progress)
        }
    }
}

// Internal managed peer lifecycle. There is deliberately no Service/CLI/native wire route.
extension ItemStore {
    func rotatePeerIntakeCredential(
        peerID: String, replacement: PeerPackage.Context,
        operationID: String
    ) throws {
        try managePeerLifecycle(
            peerID: peerID, replacement: replacement,
            retiredOriginIDs: [], operationID: operationID)
    }
    /// Removes this credential endpoint and explicitly retires the selected origin identities.
    /// An empty set removes only the endpoint; no own-origin is inferred from a relay label.
    func removePeerIntake(peerID: String, retiredOriginIDs: [String], operationID: String) throws {
        try managePeerLifecycle(
            peerID: peerID, replacement: nil,
            retiredOriginIDs: retiredOriginIDs, operationID: operationID)
    }
    private func managePeerLifecycle(
        peerID: String, replacement: PeerPackage.Context?,
        retiredOriginIDs: [String], operationID: String, credentialCommitment: String? = nil
    ) throws {
        if accessContext == nil {
            return try withAccess(forUID: ownerUID) {
                try managePeerLifecycle(
                    peerID: peerID, replacement: replacement,
                    retiredOriginIDs: retiredOriginIDs, operationID: operationID,
                    credentialCommitment: credentialCommitment)
            }
        }
        try requireAdministrator()
        let coordinator = try requirePeerIntake()
        _ = try AuthorityRecord.persistentID(.text(operationID))
        guard retiredOriginIDs == Array(Set(retiredOriginIDs)).sorted(), retiredOriginIDs.count <= 256,
            let actor = accessContext?.account?.name
        else {
            throw TractandaError(
                "invalidPeerLifecycle", "Explicit sorted origins/current administrator required.")
        }
        var requestFields: [String: ItemValue] = [
            "peerID": .text(peerID), "actor": .text(actor),
            "replacement": .text(
                try replacement.map { String(decoding: try JSON.encode($0), as: UTF8.self) } ?? "removed"),
            "retiredOrigins": .list(retiredOriginIDs.map(ItemValue.text)),
        ]
        if let credentialCommitment {
            _ = try AuthorityRecord.digest(.text(credentialCommitment))
            requestFields["credentialCommitment"] = .text(credentialCommitment)
        }
        let request = ItemValue.object(requestFields)
        let requestDigest = AuthorityRecordCodec.sha256(try JSON.encode(request))
        var mutationStarted = false
        do {
            if let saved = try coordinator.lifecycleOperation(operationID) {
                guard saved.requestDigest == requestDigest else {
                    throw TractandaError(
                        "operationMismatch", "Lifecycle operation identity names a different request.")
                }
                mutationStarted = true
                try coordinator.finishLifecycleOperation(saved)
                if !isCanonicalReady { try rebuildIndex() }
                generation = Identifier.make()
                return
            }
            guard isCanonicalReady, authorityExistingHistoryAdmitted, !authorityCatchupActive,
                let index, let localOrigin = replicaID,
                let previous = try coordinator.configuration()
            else {
                throw TractandaError(
                    "operationReviewRequired", "Lifecycle requires a recovered current store.")
            }
            let old = try previous.context(peerID: peerID)
            guard old.storeID == coordinator.storeID,
                Set(retiredOriginIDs).isSubset(of: old.permittedOrigins)
            else {
                throw TractandaError(
                    "invalidPeerLifecycle", "Retired origins must be explicitly permitted by this endpoint.")
            }
            try requireActivePublishingOrigin()
            if !retiredOriginIDs.isEmpty, peerClockHealth?.permitsRetirement == false {
                throw TractandaError(
                    "clockUnhealthy",
                    "Known clock drift prevents issuing a new peer retirement; check reference-time diagnostics."
                )
            }
            var peers = previous.peers.filter { $0.peerID != peerID }
            if let replacement {
                guard replacement.peerID == old.peerID, replacement.storeID == old.storeID,
                    replacement.permittedOrigins == old.permittedOrigins,
                    replacement.configurationDigest != old.configurationDigest, retiredOriginIDs.isEmpty
                else {
                    throw TractandaError(
                        "invalidPeerLifecycle",
                        "Credential rotation must preserve exact peer/origin identities.")
                }
                peers.append(replacement)
            }
            var state = previous.lifecycle ?? .empty
            guard !retiredOriginIDs.contains(localOrigin),
                replacement.map({ candidate in
                    !state.historicalContexts.contains(where: {
                        $0.peerID == candidate.peerID
                            && $0.configurationDigest == candidate.configurationDigest
                    })
                }) ?? true
            else {
                throw TractandaError(
                    "invalidPeerLifecycle",
                    "Local origin retirement/credential generation reuse is unsupported.")
            }
            if !state.historicalContexts.contains(old) { state.historicalContexts.append(old) }
            var retirementBytes: Data?
            try AuthorityStore.requireNoPendingPeerLifecycle(root: root, files: coordinator.journal.files)
            mutationStarted = true
            try CanonicalReaderRequirement.beforePeerLifecyclePublication(root: root, ownerUID: ownerUID)
            if !retiredOriginIDs.isEmpty {
                try index.withCatalogueScanBudget(reusingActiveBudget: true) {
                    // A real administrator retirement incorporates accepted imports into the
                    // existing sparse causal DAG. It does not create acknowledgement loops.
                    var draft = try coordinator.prepareSourceCut(
                        index: index, origin: localOrigin, actor: actor)
                    if draft.cut == nil {
                        let genesis = try coordinator.makeControl(
                            origin: localOrigin, actor: actor,
                            localParent: nil, parents: [], deltas: [], bootstrap: nil)
                        draft = .init(cut: try coordinator.recordBinding(genesis), records: [genesis])
                    }
                    if !draft.records.isEmpty {
                        let package = try coordinator.stageControlUnit(
                            draft.records, contextToken: peerIntakeContextToken())
                        try coordinator.retainSealed(package, index: index)
                        try validateAuthorityControls(
                            packageID: package, coordinator: coordinator,
                            index: index, localUnit: true)
                        try coordinator.journal.applied(package)
                        try drainAuthorityVisibility(coordinator: coordinator, index: index)
                    }
                    guard let cut = draft.cut, try index.hasValidatedAuthorityControl(cut) else {
                        throw TractandaError(
                            "invalidPeerLifecycle", "Retirement accepted cut is not validated.")
                    }
                    let retirementID = try UUID.makeVersion1()
                    let effectiveAt = try UUIDVersion1Components(retirementID).timestampUTC
                    var admission: [ItemValue] = []
                    if let head = try index.currentHeadSummary(classID: AccessConfiguration.classID),
                        let row = try index.retainedAuthorityObject(id: head.revisionID)
                    {
                        admission = [
                            try AuthorityStore.Target(
                                itemID: head.itemID, revisionID: head.revisionID,
                                sha256: row.descriptor.sha256
                            ).itemValue
                        ]
                    }
                    let rootRecord = try AuthorityRecord(
                        recordID: retirementID.uuidString.lowercased(),
                        storeID: coordinator.storeID, originReplicaID: localOrigin, kind: .originRetirement,
                        parentAuthorityIDs: [cut.recordID],
                        actorPrincipal: actor, createdAt: Timestamp.now(),
                        payload: [
                            "operationID": .text(operationID), "cut": cut.itemValue,
                            "effectiveAt": .date(effectiveAt),
                            "retirementProfile": .text(PeerLifecycle.timestampProfile),
                            "sourceAdministration": try sourceAdministration().itemValue,
                            "sourceUID": .integer(Int64(accessContext!.uid)),
                            "groups": .object(try sourceAdministrationGroups()),
                            "origins": .list(retiredOriginIDs.map(ItemValue.text)),
                            "administrationPolicies": .list(admission),
                        ])
                    retirementBytes = try AuthorityRecordCodec.encode(rootRecord)
                    state.retirements.append(
                        .init(
                            operationID: operationID,
                            root: try coordinator.recordBinding(rootRecord), origins: retiredOriginIDs))
                }
            }
            var credentialBindings = previous.credentialBindings ?? [:]
            credentialBindings.removeValue(forKey: peerID)
            if let credentialCommitment, replacement != nil {
                credentialBindings[peerID] = credentialCommitment
            }
            let configuration = AuthorityStore.Configuration(
                profile: previous.profile,
                peers: peers.sorted { $0.peerID < $1.peerID }, bootstrap: previous.bootstrap,
                lifecycle: state,
                credentialBindings: credentialBindings.isEmpty ? nil : credentialBindings
            )
            try state.validate(storeID: coordinator.storeID)
            let operation = PeerLifecycle.Operation(
                profile: PeerLifecycle.capability,
                operationID: operationID, requestDigest: requestDigest,
                previousConfigurationDigest: AuthorityRecordCodec.sha256(try JSON.encode(Optional(previous))),
                sequence: try AuthorityStore.configurationSequence(root: root) + 1,
                configuration: configuration, retirementBytes: retirementBytes)
            try coordinator.prepareLifecycleOperation(operation)
            try coordinator.lifecycleBoundaryForTesting?(.prepared)
            try coordinator.finishLifecycleOperation(operation)
            try coordinator.lifecycleBoundaryForTesting?(.committed)
            if let retirementBytes {
                let record = try AuthorityRecordCodec.decode(retirementBytes).record
                try coordinator.retainSealed(record.recordID, index: index)
                try coordinator.loadPeerRetirements(index: index)
                try coordinator.validatePeerRetirementCuts(index: index)
                try validateActivatedRetirements(coordinator: coordinator, index: index)
                for (item, causes) in try reducePeerRetirements(
                    coordinator: coordinator, index: index)
                {
                    try reconcileAuthorityProjection(
                        item, causes: causes, coordinator: coordinator, index: index)
                }
                try finishAuthorityDispositionEffects(coordinator: coordinator, index: index)
            }
            generation = Identifier.make()
        } catch {
            if mutationStarted { quarantineCheckpoint() }
            throw error
        }
    }
}

extension ItemStore {
    private func sourceAdministration() throws -> SourceAdministration {
        try .init(
            defaultAdministratorGroup: AccessConfiguration.defaultAdministratorGroup,
            serviceOwnerPrincipal: accounts.user(forUID: ownerUID).name)
    }
    private func sourceAdministrationGroups() throws -> [String: ItemValue] {
        guard let account = accessContext?.account else {
            throw TractandaError("unresolvedPrincipal", "Source administrator account is unavailable.")
        }
        var names = Set(currentAccessConfigurations.flatMap(\.groups))
        names.insert(account.primaryGroupName)
        names.insert(AccessConfiguration.defaultAdministratorGroup)
        names.formUnion(currentAccessConfigurations.compactMap(\.administratorGroup))
        var result: [String: ItemValue] = [:]
        for name in names {
            if let gid = try? accounts.groupID(named: name), account.groupIDs.contains(gid) {
                result[name] = .integer(Int64(gid))
            }
        }
        return result
    }
    private func requireActivePublishingOrigin() throws {
        guard authorityIntakeEnabled, let origin = replicaID, let index else { return }
        if try index.peerOriginRetired(origin) {
            throw TractandaError(
                "localOriginRetired",
                "This replica was retired; normal publication is disabled. Read and administrator recovery remain available."
            )
        }
    }
}

extension ItemStore {
    private func validateRetirementAuthority(
        _ original: AuthorityRecordCodec.Verified,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        let record = original.record
        guard record.kind == .originRetirement,
            record.payload["retirementProfile"] == .text(PeerLifecycle.timestampProfile),
            let effective = record.payload["effectiveAt"]?.dateString,
            try RevisionTimestamp(effective).formatted() == effective,
            try PeerLifecycle.revisionTicks(record.recordID) == RevisionTimestamp(effective).ticks,
            try !AuthorityRecord.list(record.payload["administrationPolicies"]).isEmpty
        else {
            throw TractandaError(
                "missingDependencies",
                "Timestamp retirement needs exact canonical source administrator proof.")
        }
        let cut = try AuthorityBinding(value: record.payload["cut"]!)
        try validateReviewPolicyCut(
            record, cut: cut, coordinator: coordinator, index: index,
            policyFields: ["administrationPolicies"])
        for binding in try AuthorityRecord.list(record.payload["administrationPolicies"]) {
            guard let node = try coordinator.bindingAtCut(binding, cut: cut, index: index),
                node.revision.classID == AccessConfiguration.classID,
                let value = node.revision.fields["accessConfiguration"],
                try SourceAdministration.administrator(AccessConfiguration(value), evidence: record)
            else {
                throw TractandaError(
                    "forbidden", "Retirement author is not a source administrator in its exact PRE cut.")
            }
        }
    }
    private func validateActivatedRetirements(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws {
        for activation in try coordinator.configuration()?.lifecycle?.retirements ?? [] {
            try validateRetirementAuthority(
                coordinator.retirementOriginal(activation.root, index: index), coordinator: coordinator,
                index: index)
        }
        try coordinator.foreignRetirements { activation in
            try validateRetirementAuthority(
                coordinator.retirementOriginal(activation.root, index: index), coordinator: coordinator,
                index: index)
        }
    }
    private func activatePendingRetirements(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws
        -> Bool
    {
        var after: String?
        var work = 0
        var admitted = false
        while true {
            let page = try index.peerRetirementRootPage(after: after)
            if page.isEmpty { break }
            for row in page {
                after = row.descriptor.id
                work += 1
                try coordinator.progress?()
                guard work <= coordinator.journal.limits.maximumWork else {
                    throw TractandaError("resourceLimit", "Retirement validation work exhausted.")
                }
                let binding = try AuthorityBinding(recordID: row.descriptor.id, sha256: row.descriptor.sha256)
                if try index.peerRetirementIsActive(binding) { continue }
                if try coordinator.journal.files.readIfPresent(
                    path: [".peer-retirement-activations", binding.recordID], maximumBytes: 4096) != nil
                {
                    continue
                }
                let original = try AuthorityRecordCodec.decode(coordinator.bytes(row))
                let record = original.record
                // Historical snapshot roots are audit evidence only, never mixed into timestamp eligibility.
                guard record.payload["retirementProfile"] == .text(PeerLifecycle.timestampProfile),
                    let receipt = try coordinator.freshReceipt(
                        record.recordID, origin: record.originReplicaID, index: index),
                    receipt.peerID != "local"
                else { continue }
                do {
                    try validateRetirementAuthority(original, coordinator: coordinator, index: index)
                } catch let error as TractandaError
                    where ["missingDependencies", "forbidden", "unresolvedPrincipal", "invalidAuthority"]
                    .contains(error.code)
                {
                    continue  // Inert observations cannot block unrelated accepted content.
                }
                try coordinator.activateForeignRetirement(binding, packageID: receipt.packageID)
                admitted = true
            }
        }
        return try admitted && coordinator.loadPeerRetirements(index: index)
    }
}

extension ItemStore {
    private func validateForeignReviewSeals(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws {
        let directory = root.appendingPathComponent(".peer-review-activations")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var work = 0
        try POSIXDirectory.withEntries(at: directory) { name in
            work += 1
            guard work <= coordinator.journal.limits.maximumObjects,
                let row = try index.retainedAuthorityObject(id: name), row.descriptor.kind == .authority
            else {
                throw TractandaError("invalidAuthority", "Activated foreign decision original is missing.")
            }
            let decision = try AuthorityBinding(recordID: name, sha256: row.descriptor.sha256)
            guard let activation = try coordinator.foreignReviewActivation(decision),
                let control = try index.retainedAuthorityObject(id: activation.control.recordID),
                control.descriptor.sha256 == activation.control.sha256,
                let receipt = try index.authorityReceipt(objectID: name, packageID: activation.packageID),
                let plan = try authorityReviewPlan(
                    for: .init(control: AuthorityRecordCodec.decode(coordinator.bytes(control))),
                    coordinator: coordinator, index: index),
                plan.event.binding == decision,
                try coordinator.receiptContextPermits(
                    receipt, origin: plan.event.record.record.originReplicaID, index: index)
            else {
                throw TractandaError(
                    "invalidAuthority", "Activated foreign review lost its exact proof or receipt.")
            }
            return true
        }
    }
}

extension ItemStore {
    private func recheckPeerRetirementEffects(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws {
        var after: String?
        var work = 0
        while true {
            let packages = try index.peerRetirementRecheckPackagePage(after: after)
            if packages.isEmpty { return }
            for package in packages {
                after = package
                work += 1
                guard work <= coordinator.journal.limits.maximumWork else {
                    throw TractandaError("resourceLimit", "Retirement recheck work exhausted.")
                }
                _ = try coordinator.evaluatePending(
                    packageID: package, index: index,
                    evaluate: {
                        try self.evaluateIncomingAuthority(
                            $0, evidence: $1, coordinator: coordinator, index: index)
                    },
                    evaluateMaterialization: {
                        try self.evaluateAuthorityMaterialization($0, coordinator: coordinator, index: index)
                    },
                    beforeAcceptance: { node, result in
                        try self.sealAuthorityAcceptance(
                            node, evaluation: result, coordinator: coordinator, index: index)
                    })
                try promoteEligiblePeerPackage(package, coordinator: coordinator, index: index)
                try index.finishPeerRetirementRecheck(packageID: package)
            }
        }
    }
}

extension ItemStore {
    private func exactHistoricalReconciliation(
        _ plan: AuthorityStore.VerifiedReconciliationPlan,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws -> Bool {
        guard try index.authorityHasLocalHistoryAdmission(revisionID: plan.outputRevisionID),
            let raw = try index.retainedAuthorityObject(id: plan.outputRevisionID),
            raw.descriptor.kind == .item
        else { return false }
        let value = try AuthorityRevision(originalBytes: coordinator.bytes(raw)).revision
        let binding = try AuthorityBinding(
            recordID: plan.witness.record.recordID, sha256: plan.witness.sha256)
        guard let p = try value.provenance else { return false }
        return try p.kind == .automaticMerge && p.mergeProfile == AuthorityStore.reconciliationProfile
            && p.authorityWitness == binding && p.writtenFields.isEmpty && p.unsetFields.isEmpty
            && value.itemID == plan.itemID && value.modifiedAt == plan.modifiedAt
            && p.parents == plan.parents && p.frontier == plan.frontier
            && p.originReplicaID == plan.witness.record.originReplicaID
            && index.authorityReconciliationPlanDigest(fields: RevisionMerge.semanticFields(value))
                == plan.planDigest
    }
}

extension ItemStore {
    /// One-system administrator capability, not a local account impersonation. Only exact
    /// authenticated source D/B/C proof can enter this synchronous semantic preview.
    /// No caller UID, stored actor, OS account or ordinary authorization is changed.
    private func withSharedReviewValidation<T>(
        _ plan: AuthorityStore.VerifiedReviewPlan,
        coordinator: PeerIntakeCoordinator, index: ItemIndex, _ body: () throws -> T
    ) throws -> T {
        let origin = plan.event.record.record.originReplicaID
        guard try index.peerAuthorityIssuerPermits(plan.event.binding.recordID),
            plan.control.control.record.originReplicaID == origin,
            plan.evidence.record.originReplicaID == origin
        else {
            throw TractandaError("forbidden", "Shared review issuer is not currently valid.")
        }
        for id in [plan.event.binding.recordID, plan.control.binding.recordID, plan.evidence.record.recordID]
        {
            guard try coordinator.freshReceipt(id, origin: origin, index: index) != nil else {
                throw TractandaError(
                    "untrustedPeer", "Shared review lacks exact authenticated allowed-origin testimony.")
            }
        }
        let heldOrigin = try plan.held.revision.provenance!.originReplicaID
        guard
            try index.peerReviewCoversCurrentRetirements(
                revisionID: plan.event.target.revisionID, origin: heldOrigin,
                covered: plan.event.retirements)
        else {
            throw TractandaError(
                "forbidden", "Shared review omits a currently applicable retirement cause.")
        }
        guard
            try coordinator.freshReceipt(
                plan.event.target.revisionID, origin: heldOrigin, index: index,
                forAdministratorReview: true) != nil,
            let heldEvidence = try index.retainedAuthorityObject(id: plan.event.evidence.recordID),
            heldEvidence.descriptor.sha256 == plan.event.evidence.sha256,
            try coordinator.freshReceipt(
                plan.event.evidence.recordID, origin: heldOrigin, index: index,
                forAdministratorReview: true) != nil
        else {
            throw TractandaError(
                "untrustedPeer", "Shared review cannot enroll an unknown held-origin contribution.")
        }
        let evidence = try AuthorityRecordCodec.decode(coordinator.bytes(heldEvidence)).record
        guard try coordinator.matchesIdentity(plan.held, evidence) else {
            throw TractandaError(
                "invalidAuthority", "Shared review held evidence differs from its exact original.")
        }
        try coordinator.validatePolicyCut(evidence, index: index)
        try validateHistoricalReviewAuthority(plan, coordinator: coordinator, index: index)
        let previous = accessContext
        accessContext = StoreAccessContext(
            uid: ownerUID, account: nil,
            resolver: PrincipalResolver(directory: accounts, configuration: accessConfiguration),
            isAdministrator: true)
        defer { accessContext = previous }
        return try body()
    }
}

// Internal first-source support. The stopped development driver is not an installed product.
extension ItemStore {
    static func createInitialized(
        root: URL, indexDirectory: URL? = nil,
        accounts: any AccountDirectory = SystemAccountDirectory(),
        initialAccessConfiguration: ItemValue, actorUID: UInt32, operationID: String,
        initializationKey: String? = nil,
        progress: ((String) throws -> Void)? = nil
    ) throws -> ItemStore {
        // The ordinary empty store policy admits only its OS owner.
        guard actorUID == tractanda_uid() else {
            throw TractandaError("forbidden", "Empty store administration requires its owning OS user.")
        }
        let request: InitialAuthorityBootstrap.Request
        if let old = try InitialAuthorityBootstrap.load(root: root) {
            guard old.operationID == operationID, old.actorUID == actorUID,
                old.initialAccessConfiguration == initialAccessConfiguration, old.inventory == nil,
                old.initializationKey == initializationKey
            else { throw InitialAuthorityBootstrap.failure("Fresh creation inputs changed.") }
            request = old
        } else {
            request = try .make(
                operationID: operationID, actorUID: actorUID,
                policy: initialAccessConfiguration, inventory: nil, actor: "uid:\(actorUID)",
                initializationKey: initializationKey)
        }
        let store = try ItemStore(
            root: root, indexDirectory: indexDirectory, accounts: accounts,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true, firstSourceOperation: request,
            firstSourceProgress: progress)
        try store.finishInitialAuthority(request, progress: progress)
        return store
    }

    /// Preflight under ordinary opening/current policy, BEFORE authority constructor capture.
    /// The receipt is a fixed local operation, not an authority assessment or acceptance grant.
    func prepareInitialAuthorityConversion(
        operationID: String, actorUID: UInt32, limits: InitialAuthorityBootstrap.Limits = .init(),
        progress: (() throws -> Void)? = nil
    ) throws -> InitialAuthorityBootstrap.Request {
        try withAccess(forUID: actorUID) {
            try requireAdministrator()
            guard !authorityIntakeEnabled, !accessConfigurationAmbiguous,
                !accessConfigurationProofUnavailable,
                try InitialAuthorityBootstrap.load(root: root) == nil,
                !FileManager.default.fileExists(atPath: root.appendingPathComponent("authority").path),
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(".peer-configuration").path),
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(".peer-retirement-activations").path)
            else {
                throw InitialAuthorityBootstrap.failure(
                    "Conversion requires an unconverted standalone store.")
            }
            try limits.validate()
            try InitialAuthorityBootstrap.capacity(root: root, limits: limits)
            guard let index else { throw TractandaError("indexError", "Missing catalogue.") }
            let policyID = try index.currentHeadSummary(classID: AccessConfiguration.classID)?.revisionID
            var originals: [InitialAuthorityBootstrap.Original] = []
            var total = 0
            var cursor: String?
            while true {
                try progress?()
                try InitialAuthorityBootstrap.capacity(root: root, limits: limits)
                let rows = try index.recoveryRowPage(after: cursor, limit: 128)
                if rows.isEmpty { break }
                for row in rows {
                    cursor = row.revisionID
                    guard originals.count < limits.maximumRecords,
                        row.size <= UInt64(limits.maximumBytes - total)
                    else {
                        throw TractandaError("resourceLimit", "First-source total inventory cap exceeded.")
                    }
                    let verified = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: ownerUID)
                    guard verified.metadata.size <= UInt64(limits.maximumBytes - total) else {
                        throw TractandaError("resourceLimit", "First-source total byte cap exceeded.")
                    }
                    let bytes = try Data(contentsOf: root.appendingPathComponent(row.path))
                    guard
                        AuthorityRecordCodec.sha256(bytes)
                            == row.digest.map({ String(format: "%02x", $0) }).joined(),
                        try FileMetadata.read(at: root.appendingPathComponent(row.path)) == verified.metadata
                    else {
                        throw InitialAuthorityBootstrap.failure(
                            "Canonical original changed during preflight.")
                    }
                    total += bytes.count
                    try originals.append(
                        .init(
                            path: row.path, itemID: row.itemID, revisionID: row.revisionID,
                            sha256: AuthorityRecordCodec.sha256(bytes), length: bytes.count,
                            currentAccessConfiguration: row.revisionID == policyID,
                            mode: verified.metadata.mode,
                            uid: verified.metadata.uid,
                            packageID: UUID.makeVersion1().uuidString.lowercased(),
                            framingID: UUID.makeVersion1().uuidString.lowercased()))
                }
            }
            // Allocation of a genuinely legacy local identity is an authorized preflight mutation.
            // Modern history with a missing identity fails inside this existing API.
            try withAccess(forUID: actorUID) { try requireAdministrator() }
            let local = try ReplicaIdentity.initialize(
                root: root,
                storeID: canonicalStoreIdentity(creatingIfMissing: false), ownerUID: ownerUID,
                hasModernOrigins: index.hasModernRevisionOrigins())
            replicaID = local.replicaID
            for original in originals {
                let revision = try RecordCodec.decode(
                    InitialAuthorityBootstrap.readOriginal(root: root, original: original))
                if let origin = try revision.provenance?.originReplicaID, origin != local.replicaID {
                    throw TractandaError(
                        "invalidAuthority", "Standalone preflight found an unknown modern origin.")
                }
            }
            let files = InitialAuthorityBootstrap.files(root)
            let inventory = try InitialAuthorityBootstrap.Inventory(
                storeIdentity: InitialAuthorityBootstrap.storeIdentityBytes(root: root),
                replicaIdentity: files.read(path: [".tractanda-replica-identity.json"], maximumBytes: 4096),
                originals: originals)
            let request = try InitialAuthorityBootstrap.Request.make(
                operationID: operationID,
                actorUID: actorUID, policy: nil, inventory: inventory, limits: limits,
                actor: accessContext?.account?.name ?? "uid:\(actorUID)")
            try InitialAuthorityBootstrap.validateOriginalInventory(
                root: root, request: request,
                progress: progress)
            try withAccess(forUID: actorUID) { try requireAdministrator() }
            try files.writeImmutable(
                JSON.encode(request), path: [InitialAuthorityBootstrap.receiptName],
                maximumBytes: InitialAuthorityBootstrap.maximumReceiptBytes)
            return request
        }
    }

    /// The strict builder can only retain the exact originals of its root-bound local operation.
    /// It never manufactures authored testimony and never admits a foreign modern origin.
    func finishInitialAuthority(
        _ request: InitialAuthorityBootstrap.Request, progress: ((String) throws -> Void)? = nil
    ) throws {
        guard try InitialAuthorityBootstrap.load(root: root) == request,
            let coordinator = peerIntake, let index, let origin = replicaID,
            !accessConfigurationAmbiguous, !accessConfigurationProofUnavailable
        else { throw InitialAuthorityBootstrap.failure("Missing current-policy first-source operation.") }
        if try InitialAuthorityBootstrap.completed(root: root, request: request) { return }
        // A sealed fresh initial policy is the accepted handoff. This branch only records
        // completion of that exact publication, without recovering the actor's old rights.
        if request.inventory == nil, try finalizeAcceptedFreshInitialization(request, progress: progress) {
            return
        }
        try withAccess(forUID: request.actorUID) {
            try requireAdministrator()
            try InitialAuthorityBootstrap.capacity(root: root, limits: request.limits)
            try InitialAuthorityBootstrap.validateOriginalInventory(
                root: root, request: request,
                progress: { try progress?("inventory") })
            let actor = request.actor
            let records = try InitialAuthorityBootstrap.records(
                root: root, request: request,
                storeID: coordinator.storeID, origin: origin, actor: actor)
            // Initial metadata uses the same immutable local transport identity as later
            // publications. The separate token binds this exact initialization operation.
            let metadataContext = try coordinator.context(peerID: "local")
            let initializationDigest = try InitialAuthorityBootstrap.digest(request)
            let historyContext = try PeerPackage.Context(
                peerID: "local", storeID: coordinator.storeID,
                configurationDigest: initializationDigest, permittedOrigins: [origin])
            func retain(
                _ objects: [(PeerPackage.Object, Data)], package: String, framing: String, path: String?
            ) throws {
                let context =
                    objects.allSatisfy { $0.0.kind == .authority } ? metadataContext : historyContext
                try progress?("retain")
                try InitialAuthorityBootstrap.capacity(root: root, limits: request.limits)
                try withAccess(forUID: request.actorUID) { try requireAdministrator() }
                if try coordinator.journal.publication(package) == nil {
                    let manifest = try coordinator.stageObjects(
                        objects, context: context, packageID: package,
                        reservedPageID: framing)
                    var publication =
                        try coordinator.journal.preparedPublication(package)
                        ?? PeerIntakeJournal.Publication(
                            packageID: package,
                            manifestDigest: AuthorityRecordCodec.sha256(JSON.encode(manifest)),
                            context: context, contextToken: initializationDigest,
                            arrivalMinute: String(request.createdAt.prefix(16))
                                .replacingOccurrences(of: "-", with: "/")
                                .replacingOccurrences(of: "T", with: "/")
                                .replacingOccurrences(of: ":", with: "/"))
                    publication.localItemPath = path
                    try coordinator.journal.prepare(publication)
                    try StoreCheckpoint.markDirty(root: root)
                    try coordinator.journal.seal(package)
                }
                _ = try InitialAuthorityBootstrap.verifyPublication(
                    objects, package: package,
                    framing: framing, path: path, context: context, request: request, coordinator: coordinator
                )
                try withAccess(forUID: request.actorUID) {
                    try requireAdministrator()
                    try coordinator.retainSealed(package, index: index)
                }
            }
            for original in InitialAuthorityBootstrap.admittedOriginals(request) {
                let bytes = try InitialAuthorityBootstrap.readOriginal(root: root, original: original)
                let revision = try RecordCodec.decode(bytes)
                guard
                    try revision.provenance?.originReplicaID == nil
                        || revision.provenance?.originReplicaID == origin
                else {
                    throw TractandaError(
                        "invalidAuthority", "Standalone conversion cannot enroll an unknown modern origin.")
                }
                try retain(
                    [
                        (
                            InitialAuthorityBootstrap.descriptor(
                                bytes, kind: .item,
                                id: revision.revisionID), bytes
                        )
                    ], package: original.packageID,
                    framing: original.framingID, path: original.path)
            }
            let objects = try records.map { record -> (PeerPackage.Object, Data) in
                let bytes = try AuthorityRecordCodec.encode(record)
                return (
                    InitialAuthorityBootstrap.descriptor(bytes, kind: .authority, id: record.recordID), bytes
                )
            }
            for (offset, allocation) in request.pages.enumerated() {
                try retain(
                    [objects[offset]], package: allocation.packageID, framing: allocation.framingID, path: nil
                )
            }
            try retain(
                Array(objects.suffix(2)), package: request.packageID, framing: request.framingID, path: nil)
            let rootRecord = records.last!
            if request.foundingPolicy != nil { try progress?("beforePolicy") }
            try progress?("beforePin")
            try withAccess(forUID: request.actorUID) {
                try requireAdministrator()
                if request.foundingPolicy != nil {
                    try InitialAuthorityBootstrap.requireFreshCreator(
                        request, ownerUID: ownerUID, accounts: accounts)
                }
                let digest = try AuthorityRecordCodec.sha256(AuthorityRecordCodec.encode(rootRecord))
                if let pin = try coordinator.configuration()?.bootstrap {
                    guard pin.recordID == rootRecord.recordID, pin.sha256 == digest else {
                        throw TractandaError(
                            "invalidAuthority", "The operation conflicts with the original bootstrap pin.")
                    }
                    // The original pin actor is historical testimony; do not rewrite it when
                    // today's authenticated actor resolves to a different account spelling.
                    try rebuildIndex()
                } else {
                    try pinAuthorityBootstrap(
                        rootID: rootRecord.recordID, sha256: digest,
                        expectedContextToken: peerIntakeContextToken(),
                        beforeAcceptance: {
                            if request.foundingPolicy != nil { try progress?("beforePinAcceptance") }
                            guard try InitialAuthorityBootstrap.load(root: self.root) == request else {
                                throw InitialAuthorityBootstrap.failure(
                                    "Initial request changed before acceptance.")
                            }
                            if let founding = request.foundingPolicy {
                                try InitialAuthorityBootstrap.requireFreshCreator(
                                    request,
                                    ownerUID: self.ownerUID, accounts: self.accounts)
                                try InitialAuthorityBootstrap.validateOriginalInventory(
                                    root: self.root, request: request)
                                let bytes = try InitialAuthorityBootstrap.readOriginal(
                                    root: self.root, original: founding.original)
                                let object = InitialAuthorityBootstrap.descriptor(
                                    bytes, kind: .item, id: founding.original.revisionID)
                                let publication = try InitialAuthorityBootstrap.verifyPublication(
                                    [(object, bytes)],
                                    package: founding.original.packageID,
                                    framing: founding.original.framingID,
                                    path: founding.original.path, context: historyContext, request: request,
                                    coordinator: coordinator)
                                guard
                                    let receipt = try index.authorityReceipt(
                                        objectID: object.id, packageID: founding.original.packageID),
                                    try AuthorityStore.isInitialHistoryReceipt(
                                        receipt,
                                        node: AuthorityRevision(originalBytes: bytes),
                                        publication: publication,
                                        root: self.root, storeID: coordinator.storeID,
                                        ownerUID: self.ownerUID,
                                        files: coordinator.journal.files)
                                else {
                                    throw InitialAuthorityBootstrap.failure(
                                        "Founding policy capture proof changed before pin acceptance.")
                                }
                            }
                        })
                }
            }
            if request.foundingPolicy != nil {
                try progress?("afterPin")
                guard try finalizeAcceptedFreshInitialization(request, progress: progress) else {
                    throw InitialAuthorityBootstrap.failure("Initial policy has not been accepted.")
                }
                return
            }
            // The strict pin/rebuild above has admitted this fixed initial inventory. Its
            // exact sealed packages are completed history, not perpetual pending quota.
            let initialPackages =
                (request.inventory?.originals.map(\.packageID) ?? [])
                + request.pages.map(\.packageID) + [request.packageID]
            for packageID in initialPackages {
                try withAccess(forUID: request.actorUID) {
                    try requireAdministrator()
                    try coordinator.journal.applied(packageID)
                }
            }
            try progress?("afterPin")
            try progress?("beforeComplete")
            try withAccess(forUID: request.actorUID) { try requireAdministrator() }
            try InitialAuthorityBootstrap.capacity(root: root, limits: request.limits)
            try InitialAuthorityBootstrap.files(root).writeImmutable(
                JSON.encode(
                    InitialAuthorityBootstrap.Completion(
                        requestDigest: InitialAuthorityBootstrap.digest(request))),
                path: [InitialAuthorityBootstrap.completeName], maximumBytes: 4096)
        }
    }
    /// Exact finite bookkeeping after the canonical initial pin hands authority to the new policy.
    /// No creator lookup or restored administrator context is permitted after acceptance.
    private func finalizeAcceptedFreshInitialization(
        _ request: InitialAuthorityBootstrap.Request, progress: ((String) throws -> Void)?
    ) throws -> Bool {
        guard request.inventory == nil, let founding = request.foundingPolicy,
            request.actorUID == ownerUID, request.actor == "uid:\(ownerUID)",
            let coordinator = peerIntake, let index, let origin = replicaID,
            coordinator.storeID == request.freshStoreID, origin == request.freshReplicaID
        else { return false }
        guard let pin = try coordinator.configuration()?.bootstrap else { return false }
        let records = try InitialAuthorityBootstrap.records(
            root: root, request: request,
            storeID: coordinator.storeID, origin: origin, actor: request.actor)
        let rootDigest = try AuthorityRecordCodec.sha256(AuthorityRecordCodec.encode(records.last!))
        let originalBytes = try InitialAuthorityBootstrap.readOriginal(
            root: root, original: founding.original)
        guard pin.recordID == request.rootID, pin.sha256 == rootDigest, pin.actor == request.actor,
            originalBytes == founding.bytes,
            let summary = try index.currentHeadSummary(classID: AccessConfiguration.classID),
            summary.itemID == founding.original.itemID, summary.revisionID == founding.original.revisionID,
            let row = try index.revision(summary.revisionID), row.path == founding.original.path,
            row.digest.map({ String(format: "%02x", $0) }).joined() == founding.original.sha256,
            try index.revisionCount(itemID: summary.itemID) == 1,
            try index.authorityDisposition(id: row.revisionID)?.disposition == .eligible,
            try index.acceptedGraphProofIsCurrent()
        else {
            throw InitialAuthorityBootstrap.failure("Initial handoff lacks its exact accepted policy/pin.")
        }
        let metadataContext = try coordinator.context(peerID: "local")
        let historyContext = try PeerPackage.Context(
            peerID: "local", storeID: coordinator.storeID,
            configurationDigest: InitialAuthorityBootstrap.digest(request), permittedOrigins: [origin])
        func verify(
            _ objects: [(PeerPackage.Object, Data)], package: String, framing: String,
            path: String?, context: PeerPackage.Context
        ) throws -> PeerIntakeJournal.Publication {
            let publication = try InitialAuthorityBootstrap.verifyPublication(
                objects, package: package,
                framing: framing, path: path, context: context, request: request, coordinator: coordinator)
            for (object, bytes) in objects {
                guard let retained = try index.authorityReceipt(objectID: object.id, packageID: package),
                    retained.descriptor == object, retained.peerID == "local", retained.permittedOrigin,
                    retained.configurationDigest == context.configurationDigest,
                    try coordinator.bytes(retained) == bytes
                else { throw InitialAuthorityBootstrap.failure("Initial handoff receipt/original changed.") }
            }
            return publication
        }
        let policyObject = InitialAuthorityBootstrap.descriptor(
            originalBytes, kind: .item, id: row.revisionID)
        let publication = try verify(
            [(policyObject, originalBytes)], package: founding.original.packageID,
            framing: founding.original.framingID, path: founding.original.path, context: historyContext)
        guard
            let retained = try index.authorityReceipt(
                objectID: row.revisionID, packageID: founding.original.packageID),
            retained.path == row.path,
            try AuthorityStore.isInitialHistoryReceipt(
                retained,
                node: AuthorityRevision(originalBytes: originalBytes), publication: publication,
                root: root, storeID: coordinator.storeID, ownerUID: ownerUID, files: coordinator.journal.files
            )
        else { throw InitialAuthorityBootstrap.failure("Initial handoff lost its original captured proof.") }
        let objects = try records.map { record -> (PeerPackage.Object, Data) in
            let bytes = try AuthorityRecordCodec.encode(record)
            return (InitialAuthorityBootstrap.descriptor(bytes, kind: .authority, id: record.recordID), bytes)
        }
        for (offset, allocation) in request.pages.enumerated() {
            _ = try verify(
                [objects[offset]], package: allocation.packageID, framing: allocation.framingID,
                path: nil, context: metadataContext)
        }
        _ = try verify(
            Array(objects.suffix(2)), package: request.packageID, framing: request.framingID,
            path: nil, context: metadataContext)
        // Every mutation below is fixed by the proven immutable request and accepted canonical cut.
        for packageID in [founding.original.packageID] + request.pages.map(\.packageID) + [request.packageID]
        {
            try coordinator.journal.applied(packageID)
        }
        try progress?("beforeComplete")
        try InitialAuthorityBootstrap.capacity(root: root, limits: request.limits)
        try InitialAuthorityBootstrap.files(root).writeImmutable(
            JSON.encode(
                InitialAuthorityBootstrap.Completion(requestDigest: InitialAuthorityBootstrap.digest(request))
            ),
            path: [InitialAuthorityBootstrap.completeName], maximumBytes: 4096)
        return true
    }

}

// Offline source enrollment ownership. No active peer configuration is written by this unit.
extension ItemStore {
    var peerEnrollmentBoundaryForTesting: ((String) throws -> Void)? {
        get { peerIntake?.enrollmentBoundaryForTesting }
        set { peerIntake?.enrollmentBoundaryForTesting = newValue }
    }
    private func enrollmentJournal(_ id: String, _ coordinator: PeerIntakeCoordinator)
        -> PeerEnrollmentApproval.Journal
    {
        .init(files: coordinator.journal.files, operationID: id)
    }
    private func enrollmentOperation(
        _ handle: PeerEnrollmentApproval.Handle,
        _ coordinator: PeerIntakeCoordinator,
        readBudget: ((Int) throws -> Void)? = nil
    ) throws -> PeerEnrollmentApproval.Operation {
        guard
            let value = try enrollmentJournal(handle.operationID, coordinator)
                .read(PeerEnrollmentApproval.Operation.self, "request.json", readBudget: readBudget),
            value.operationID == handle.operationID, value.profile == PeerEnrollmentApproval.capability
        else { throw PeerEnrollmentApproval.failure("Exact enrollment request is missing.") }
        let preparation = try PeerEnrollmentApproval.preparation(value.input.preparationBytes)
        guard preparation.commonStoreID == coordinator.storeID, preparation.sourceReplicaID == replicaID
        else {
            throw PeerEnrollmentApproval.failure("Enrollment source/store identity differs.")
        }
        return value
    }
    private func enrollmentKeys(
        _ operation: PeerEnrollmentApproval.Operation,
        _ coordinator: PeerIntakeCoordinator
    ) throws -> (PeerCredential, PeerCredential) {
        let input = operation.input
        let local = try PeerCredentialStore(files: coordinator.journal.files).load(
            peerID: input.sourceContext.peerID, configurationDigest: input.sourceContext.configurationDigest)
        let remote = try PeerCredentialStore(
            files: coordinator.journal.files,
            prefix: [PeerEnrollmentApproval.directory, operation.operationID, "remote"]
        ).load(
            peerID: input.targetContext.peerID, configurationDigest: input.targetContext.configurationDigest)
        let request = PeerEnrollmentApproval.Request(
            operationID: operation.operationID,
            preparationBytes: input.preparationBytes, sourceContext: input.sourceContext,
            targetContext: input.targetContext, sourceCredential: local, targetCredential: remote)
        let loaded = try PeerEnrollmentApproval.checkPair(
            request, source: replicaID!,
            storeID: coordinator.storeID, trustedOrigins: operation.trustedOrigins)
        guard try JSON.encode(loaded) == JSON.encode(input) else {
            throw PeerEnrollmentApproval.failure("Staged enrollment credential metadata differs.")
        }
        return (local, remote)
    }
    private func requireEnrollmentFences(
        _ operation: PeerEnrollmentApproval.Operation,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        let preparation = try PeerEnrollmentApproval.preparation(operation.input.preparationBytes)
        guard isCanonicalReady, authorityExistingHistoryAdmitted, !authorityCatchupActive,
            replicaID == preparation.sourceReplicaID,
            try !index.peerOriginRetired(preparation.sourceReplicaID),
            try !index.peerOriginRetired(preparation.targetReplicaID)
        else {
            throw PeerEnrollmentApproval.failure("Recovered active source/target membership is required.")
        }
        let configuration = try coordinator.configuration()
        guard
            !((configuration?.lifecycle?.historicalContexts ?? []).contains {
                $0.peerID == operation.input.sourceContext.peerID
                    && $0.configurationDigest == operation.input.sourceContext.configurationDigest
            })
        else { throw PeerEnrollmentApproval.failure("Enrollment credential generation was revoked.") }
        _ = try enrollmentKeys(operation, coordinator)
    }
    private func requireCurrentEnrollment(
        _ operation: PeerEnrollmentApproval.Operation,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        try requireAdministrator()
        try requireEnrollmentFences(operation, coordinator: coordinator, index: index)
        // Exclude only this operation's exact accepted decision, never an arbitrary target.
        let ownAdmission: AuthorityBinding?
        if let decision = try coordinator.originDecision(operation.input.sourceContext.permittedOrigins[0]),
            decision.approval.id == operation.approvalID,
            let approval = try enrollmentJournal(operation.operationID, coordinator).read(
                Data.self, "approval.json"),
            let accepted = try enrollmentJournal(operation.operationID, coordinator).read(
                PeerEnrollmentApproval.Accepted.self, "accepted.json"),
            accepted.approval.recordID == operation.approvalID,
            accepted.approval.sha256 == AuthorityRecordCodec.sha256(approval),
            decision.approval.sha256 == accepted.approval.sha256
        {
            ownAdmission = accepted.approval
        } else {
            ownAdmission = nil
        }
        guard let account = accessContext?.account, accessContext?.uid == operation.actorUID,
            account.name == operation.actor,
            try sourceAdministrationGroups() == operation.groups,
            try sourceAdministration().itemValue == operation.sourceAdministration,
            try peerExchangeSecurityBinding(
                coordinator: coordinator, index: index,
                excludingAdmission: ownAdmission,
                configurationOverride: enrollmentConfigurationBeforeOwnRegistration(operation, coordinator))
                == operation.securityBinding,
            try coordinator.configuration()?.bootstrap.map({
                try AuthorityBinding(recordID: $0.recordID, sha256: $0.sha256)
            })
                == operation.bootstrap
        else {
            throw PeerEnrollmentApproval.failure(
                "Enrollment authority/security changed; review and start a new operation.")
        }
    }
    private func enrollmentScope(
        _ operation: PeerEnrollmentApproval.Operation,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    )
        -> PeerEnrollmentApproval.OwnerExportScope
    {
        .init(
            context: operation.input.sourceContext,
            validate: { [self] in
                try requireCurrentEnrollment(operation, coordinator: coordinator, index: index)
            })
    }
    private func enrollmentPlan(
        _ operation: PeerEnrollmentApproval.Operation,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) -> PeerExportPlan {
        PeerExportPlan(
            coordinator: coordinator, index: index, context: operation.input.sourceContext,
            securityBinding: operation.securityBinding,
            ownerScope: enrollmentScope(operation, coordinator: coordinator, index: index))
    }
    private func enrollmentAdministrationPolicies(
        _ index: ItemIndex,
        coordinator: PeerIntakeCoordinator
    ) throws -> [ItemValue] {
        guard !accessConfigurationAmbiguous, !accessConfigurationProofUnavailable,
            let head = try index.currentHeadSummary(classID: AccessConfiguration.classID),
            let raw = try index.retainedAuthorityObject(id: head.revisionID)
        else {
            throw PeerEnrollmentApproval.failure("Current global administration frontier is unavailable.")
        }
        let node = try AuthorityRevision(originalBytes: coordinator.bytes(raw))
        let ids =
            try node.revision.provenance?.kind == .automaticMerge
            ? node.revision.provenance!.frontier : [node.revision.revisionID]
        guard ids.count <= AuthorityRecord.maximumEntries else {
            throw TractandaError("resourceLimit", "Enrollment administration frontier exceeds its window.")
        }
        return try ids.sorted().map { id in
            guard let raw = try index.retainedAuthorityObject(id: id) else {
                throw PeerEnrollmentApproval.failure("Administration original is unavailable.")
            }
            let revision = try AuthorityRevision(originalBytes: coordinator.bytes(raw)).revision
            guard revision.itemID == head.itemID else {
                throw PeerEnrollmentApproval.failure("Administration item differs.")
            }
            return try AuthorityStore.Target(
                itemID: head.itemID, revisionID: id, sha256: raw.descriptor.sha256
            ).itemValue
        }
    }
    func beginPeerEnrollment(_ request: PeerEnrollmentApproval.Request, forUID uid: UInt32) throws
        -> PeerEnrollmentApproval.Handle
    {
        try withAccess(forUID: uid) {
            try requireAdministrator()
            let coordinator = try requirePeerIntake()
            guard isCanonicalReady, authorityExistingHistoryAdmitted, !authorityCatchupActive,
                let index, let source = replicaID, let configuration = try coordinator.configuration(),
                let pin = configuration.bootstrap
            else {
                throw PeerEnrollmentApproval.failure(
                    "Enrollment requires initialized canonical source history.")
            }
            _ = try AuthorityRecord.persistentID(.text(request.operationID))
            let handle = PeerEnrollmentApproval.Handle(operationID: request.operationID)
            let journal = enrollmentJournal(request.operationID, coordinator)
            let saved = try journal.read(PeerEnrollmentApproval.Operation.self, "request.json")
            let trustedOrigins: [String]
            if let saved {
                trustedOrigins = saved.trustedOrigins
            } else {
                trustedOrigins = try coordinator.admittedOriginSnapshot(index: index, localOrigin: source)
            }
            let input = try PeerEnrollmentApproval.checkPair(
                request, source: source,
                storeID: coordinator.storeID, trustedOrigins: trustedOrigins)
            if let saved {
                guard try JSON.encode(saved.input) == JSON.encode(input), saved.actorUID == uid else {
                    throw PeerEnrollmentApproval.failure(
                        "Enrollment operation already binds another exact request.")
                }
                let keys = try enrollmentKeys(saved, coordinator)
                try PeerEnrollmentApproval.compare(keys.0, request.sourceCredential)
                try PeerEnrollmentApproval.compare(keys.1, request.targetCredential)
                try requireCurrentEnrollment(saved, coordinator: coordinator, index: index)
                return handle
            }
            guard !configuration.peers.contains(where: { $0.peerID == input.sourceContext.peerID }),
                let account = accessContext?.account
            else {
                throw PeerEnrollmentApproval.failure(
                    "Enrollment requires a new peer and an authenticated operator.")
            }
            let preparation = try PeerEnrollmentApproval.preparation(input.preparationBytes)
            func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
            let operation = try PeerEnrollmentApproval.Operation(
                profile: PeerEnrollmentApproval.capability,
                operationID: request.operationID, input: input, actorUID: uid, actor: account.name,
                groups: sourceAdministrationGroups(), sourceAdministration: sourceAdministration().itemValue,
                administrationPolicies: enrollmentAdministrationPolicies(index, coordinator: coordinator),
                trustedOrigins: trustedOrigins,
                bootstrap: .init(recordID: pin.recordID, sha256: pin.sha256),
                issuerAdmission: coordinator.originAdmission(source, index: index),
                securityBinding: peerExchangeSecurityBinding(coordinator: coordinator, index: index),
                approvalID: id(), publicationID: id(), framingID: id(), planID: id(), packageID: id(),
                createdAt: Timestamp.now())
            let identities = [
                coordinator.storeID, source, preparation.targetReplicaID, preparation.operationID,
                operation.operationID, input.pairingID, operation.approvalID, operation.publicationID,
                operation.framingID, operation.planID, operation.packageID,
            ]
            guard Set(identities).count == identities.count,
                !(configuration.lifecycle?.historicalContexts ?? []).contains(input.sourceContext)
            else {
                throw PeerEnrollmentApproval.failure("Enrollment reserved identities/generation collide.")
            }
            for identity in identities.dropFirst(4) {
                guard try index.retainedAuthorityObject(id: identity) == nil else {
                    throw PeerEnrollmentApproval.failure(
                        "Enrollment identity collides with retained history.")
                }
            }
            guard try !index.peerOriginRetired(source),
                try !index.peerOriginRetired(preparation.targetReplicaID)
            else {
                throw PeerEnrollmentApproval.failure("Enrollment source or target is disposed.")
            }
            // The private full bytes precede the intent: a recorded request can never bind a new key on retry.
            try PeerCredentialStore(files: coordinator.journal.files).stage(request.sourceCredential)
            try PeerCredentialStore(
                files: coordinator.journal.files,
                prefix: [PeerEnrollmentApproval.directory, request.operationID, "remote"]
            ).stage(request.targetCredential)
            try journal.write(operation, "request.json")
            return handle
        }
    }
    private func stageEnrollmentRecord(
        _ bytes: Data, packageID: String, framingID: String,
        operation: PeerEnrollmentApproval.Operation,
        coordinator: PeerIntakeCoordinator, index: ItemIndex,
        approval: Bool
    ) throws {
        let record = try AuthorityRecordCodec.decode(bytes)
        let descriptor = PeerPackage.Object(
            kind: .authority, id: record.record.recordID,
            length: bytes.count, sha256: record.sha256)
        let local = try coordinator.context(peerID: "local")
        if try coordinator.journal.publication(packageID) == nil {
            let manifest = try coordinator.stageObjects(
                [(descriptor, bytes)], context: local,
                packageID: packageID, reservedPageID: framingID)
            let publication =
                try coordinator.journal.preparedPublication(packageID)
                ?? PeerIntakeJournal.Publication(
                    packageID: packageID,
                    manifestDigest: AuthorityRecordCodec.sha256(try JSON.encode(manifest)),
                    context: local, contextToken: PeerEnrollmentApproval.capability,
                    arrivalMinute: PeerIntakeJournal.currentArrivalMinute())
            try coordinator.journal.prepare(publication)
            if approval { try coordinator.enrollmentBoundaryForTesting?("beforeAcceptance") }
            if approval {
                try CanonicalReaderRequirement.beforeOriginAdmissionPublication(
                    root: root, ownerUID: ownerUID)
            } else {
                try CanonicalReaderRequirement.beforeControlPublication(root: root, ownerUID: ownerUID)
            }
            // Re-resolve the real OS principal immediately before acceptance, including NSS changes.
            try withAccess(forUID: operation.actorUID) {
                try requireCurrentEnrollment(operation, coordinator: coordinator, index: index)
                if approval {
                    try validateEnrollmentAuthority(record, coordinator: coordinator, index: index)
                }
                try StoreCheckpoint.markDirty(root: root)
                try coordinator.journal.seal(packageID)
            }
            if approval { try coordinator.enrollmentBoundaryForTesting?("accepted") }
        }
        guard let sealed = try coordinator.journal.publication(packageID), sealed.context == local,
            sealed.contextToken == PeerEnrollmentApproval.capability,
            try coordinator.journal.object(descriptor, packageID: packageID) == bytes
        else { throw PeerEnrollmentApproval.failure("Enrollment exact canonical publication proof differs.") }
        // Durable publication already accepted this exact local decision. Completion is not a fresh grant.
        try coordinator.retainSealed(packageID, index: index)
        if !approval {
            try validateAuthorityControls(
                packageID: packageID, coordinator: coordinator, index: index, localUnit: true)
        }
        try coordinator.journal.applied(packageID)
    }
    private func captureEnrollment(
        _ operation: PeerEnrollmentApproval.Operation,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws -> PeerEnrollmentApproval.Capture {
        let journal = enrollmentJournal(operation.operationID, coordinator)
        if let capture = try journal.read(PeerEnrollmentApproval.Capture.self, "capture.json") {
            return capture
        }
        let draft: PeerEnrollmentApproval.Draft
        if let old = try journal.read(PeerEnrollmentApproval.Draft.self, "draft.json") {
            draft = old
        } else {
            let source = try PeerEnrollmentApproval.preparation(operation.input.preparationBytes)
                .sourceReplicaID
            let prepared = try coordinator.prepareSourceCut(
                index: index, origin: source, actor: operation.actor)
            guard let cut = prepared.cut, prepared.records.count <= 128 else {
                throw TractandaError(
                    "resourceLimit",
                    "Enrollment PRE join exceeds one bounded draft; reconcile and review a new operation.")
            }
            let records = try prepared.records.map { record -> PeerEnrollmentApproval.Draft.Record in
                let bytes = try AuthorityRecordCodec.encode(record)
                let binding = try coordinator.recordBinding(record)
                let path = try journal.path("draft-" + record.recordID + ".authority")
                try coordinator.journal.files.writeImmutable(
                    bytes, path: path, maximumBytes: AuthorityRecord.maximumBytes)
                return try .init(
                    binding: binding, packageID: UUID.makeVersion1().uuidString.lowercased(),
                    framingID: UUID.makeVersion1().uuidString.lowercased())
            }
            draft = .init(cut: cut, records: records)
            // Exact records and all framing allocations precede canonical use.
            try journal.write(draft, "draft.json")
        }
        for item in draft.records {
            let bytes = try coordinator.journal.files.read(
                path: journal.path("draft-" + item.binding.recordID + ".authority"),
                maximumBytes: AuthorityRecord.maximumBytes)
            guard AuthorityRecordCodec.sha256(bytes) == item.binding.sha256 else {
                throw PeerEnrollmentApproval.failure("Reserved PRE control bytes differ.")
            }
            try stageEnrollmentRecord(
                bytes, packageID: item.packageID, framingID: item.framingID,
                operation: operation, coordinator: coordinator, index: index, approval: false)
        }
        guard try index.hasValidatedAuthorityControl(draft.cut) else {
            throw PeerEnrollmentApproval.failure("Enrollment PRE cut is not accepted.")
        }
        try drainAuthorityVisibility(coordinator: coordinator, index: index)
        let capture = try PeerEnrollmentApproval.Capture(
            boundary: PeerInventory.capture(
                context: operation.input.sourceContext, coordinator: coordinator, index: index,
                ownerScope: enrollmentScope(operation, coordinator: coordinator, index: index)),
            cut: draft.cut)
        try journal.write(capture, "capture.json")
        return capture
    }
    func stepPeerEnrollment(
        _ handle: PeerEnrollmentApproval.Handle, forUID uid: UInt32,
        window: PeerExportPlan.Window = .init()
    ) throws -> PeerEnrollmentApproval.Status {
        try withAccess(forUID: uid) {
            let coordinator = try requirePeerIntake()
            guard let index else {
                throw PeerEnrollmentApproval.failure("Enrollment requires its rebuilt inventory.")
            }
            let operation = try enrollmentOperation(handle, coordinator)
            try requireCurrentEnrollment(operation, coordinator: coordinator, index: index)
            return try index.withCatalogueScanBudget(reusingActiveBudget: true) {
                let journal = enrollmentJournal(handle.operationID, coordinator)
                let capture = try captureEnrollment(operation, coordinator: coordinator, index: index)
                let plan = enrollmentPlan(operation, coordinator: coordinator, index: index)
                let export: PeerExportPlan.Handle
                if try coordinator.journal.files.readIfPresent(
                    path: ["authority", "export", operation.planID, "begin.json"],
                    maximumBytes: PeerPackage.maximumPageBytes) == nil
                {
                    export = try plan.begin(
                        planID: operation.planID, packageID: operation.packageID,
                        boundary: capture.boundary, limits: .init())
                } else {
                    export = try plan.reopen(planID: operation.planID, packageID: operation.packageID)
                }
                if let manifest = try plan.manifest(export) {
                    return .init(phase: .ready, approval: nil, manifest: manifest)
                }
                let previous = try journal.selection(maximumWork: coordinator.journal.limits.maximumWork)
                if previous?.complete != true {
                    let page = try PeerInventory.page(
                        context: operation.input.sourceContext,
                        boundary: capture.boundary, cursor: previous?.cursor, limit: 128,
                        coordinator: coordinator, index: index, evaluationsAvailable: true,
                        limits: .init(), progress: nil,
                        ownerScope: enrollmentScope(operation, coordinator: coordinator, index: index))
                    _ = try plan.select(export, entries: page.entries, finish: page.nextCursor == nil)
                    let next = try PeerEnrollmentApproval.Selection(
                        sequence: (previous?.sequence ?? 0) + 1,
                        previousDigest: previous.map { AuthorityRecordCodec.sha256(try JSON.encode($0)) }
                            ?? "",
                        cursor: page.nextCursor, complete: page.nextCursor == nil)
                    try journal.write(next, "selection-\(next.sequence).json")
                    return .init(
                        phase: page.nextCursor == nil ? .building : .selecting, approval: nil, manifest: nil)
                }
                let status = try plan.step(export, window: window)
                if status.pending == 0, status.missing > 0 || status.unsupported > 0 {
                    let blocked = try index.peerExportSlots(
                        operation.planID,
                        status: status.missing > 0
                            ? PeerExportPlan.ObjectState.missing.rawValue
                            : PeerExportPlan.ObjectState.unsupported.rawValue, limit: 1
                    ).first
                    throw TractandaError(
                        "enrollmentBaselineIncomplete",
                        "Finite enrollment baseline needs canonical dependency review: "
                            + (blocked?.reason ?? blocked?.unsupportedReason ?? "unavailable dependency")
                            + " (" + (blocked?.id ?? "unknown")
                            + "). Repair retained evidence and start a reviewed operation.")
                }
                return .init(
                    phase: status.manifest == nil ? .building : .ready,
                    approval: nil, manifest: status.manifest)
            }
        }
    }
    private func enrollmentRecord(
        _ operation: PeerEnrollmentApproval.Operation,
        capture: PeerEnrollmentApproval.Capture,
        manifest: PeerPackage.Manifest
    ) throws -> AuthorityRecord {
        let input = operation.input
        let preparation = try PeerEnrollmentApproval.preparation(input.preparationBytes)
        var payload: [String: ItemValue] = [
            "approvalProfile": .text(PeerEnrollmentApproval.capability)
        ]
        if let issuer = operation.issuerAdmission { payload["issuerAdmission"] = .list([issuer.itemValue]) }
        return try AuthorityRecord(
            recordID: operation.approvalID, storeID: preparation.commonStoreID,
            originReplicaID: preparation.sourceReplicaID, kind: .enrollmentApproval,
            parentAuthorityIDs: [capture.cut.recordID], actorPrincipal: operation.actor,
            createdAt: operation.createdAt,
            payload: payload.merging(
                [
                    "approvalProfile": .text(PeerEnrollmentApproval.capability),
                    "operationID": .text(operation.operationID),
                    "preparationDigest": .text(AuthorityRecordCodec.sha256(input.preparationBytes)),
                    "targetReplicaID": .text(preparation.targetReplicaID),
                    "pairingID": .text(input.pairingID),
                    "sourceIsInitiator": .boolean(input.sourceIsInitiator),
                    "credentialProfile": .text(input.profile),
                    "sourcePeer": .text(input.sourceContext.peerID),
                    "targetPeer": .text(input.targetContext.peerID),
                    "sourceConfiguration": .text(input.sourceContext.configurationDigest),
                    "targetConfiguration": .text(input.targetContext.configurationDigest),
                    "sourceOrigins": .list(input.sourceContext.permittedOrigins.map(ItemValue.text)),
                    "targetOrigins": .list(input.targetContext.permittedOrigins.map(ItemValue.text)),
                    "sourceCredential": .text(input.sourceCredentialCommitment),
                    "targetCredential": .text(input.targetCredentialCommitment),
                    "bootstrap": .list([operation.bootstrap.itemValue]),
                    "securityBinding": .text(operation.securityBinding), "cut": capture.cut.itemValue,
                    "administrationPolicies": .list(operation.administrationPolicies),
                    "sourceAdministration": operation.sourceAdministration,
                    "sourceUID": .integer(Int64(operation.actorUID)), "groups": .object(operation.groups),
                    "planID": .text(operation.planID), "packageID": .text(operation.packageID),
                    "manifestDigest": .text(AuthorityRecordCodec.sha256(try JSON.encode(manifest))),
                    "boundaryDigest": .text(AuthorityRecordCodec.sha256(try JSON.encode(capture.boundary))),
                ], uniquingKeysWith: { _, supplied in supplied }))
    }
    private func validateEnrollmentAuthority(
        _ original: AuthorityRecordCodec.Verified,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws {
        let record = original.record
        guard record.kind == .enrollmentApproval,
            record.payload["approvalProfile"] == .text(PeerEnrollmentApproval.capability),
            try coordinator.freshReceipt(record.recordID, origin: record.originReplicaID, index: index) != nil
                || record.originReplicaID == replicaID
        else { throw PeerEnrollmentApproval.failure("Enrollment testimony lacks a trusted origin receipt.") }
        let cut = try AuthorityBinding(value: record.payload["cut"]!)
        try validateReviewPolicyCut(
            record, cut: cut, coordinator: coordinator, index: index,
            policyFields: ["administrationPolicies"])
        for binding in try AuthorityRecord.list(record.payload["administrationPolicies"]) {
            guard let policy = try coordinator.bindingAtCut(binding, cut: cut, index: index),
                policy.revision.classID == AccessConfiguration.classID,
                let value = policy.revision.fields["accessConfiguration"],
                try SourceAdministration.administrator(AccessConfiguration(value), evidence: record)
            else {
                throw PeerEnrollmentApproval.failure(
                    "Enrollment author lacks exact historical source administrator proof.")
            }
        }
        let bootstrap = try AuthorityRecord.list(record.payload["bootstrap"]).map(
            AuthorityBinding.init(value:))
        guard let pin = try coordinator.configuration()?.bootstrap,
            bootstrap == [try .init(recordID: pin.recordID, sha256: pin.sha256)],
            let root = try index.retainedAuthorityObject(id: pin.recordID),
            root.descriptor.sha256 == pin.sha256,
            try AuthorityRecordCodec.decode(coordinator.bytes(root)).record.kind == .bootstrap
        else {
            throw PeerEnrollmentApproval.failure(
                "Enrollment permanent bootstrap pin is unavailable or changed.")
        }
    }
    func acceptPeerEnrollment(_ handle: PeerEnrollmentApproval.Handle, forUID uid: UInt32) throws
        -> PeerEnrollmentApproval.Status
    {
        try withAccess(forUID: uid) {
            let coordinator = try requirePeerIntake()
            guard let index else {
                throw PeerEnrollmentApproval.failure("Enrollment requires its rebuilt inventory.")
            }
            let operation = try enrollmentOperation(handle, coordinator)
            // An exact accepted publication can finish bookkeeping after its author is demoted.
            if try coordinator.journal.publication(operation.publicationID) != nil {
                return try finishAcceptedPeerEnrollment(handle)
            }
            try requireCurrentEnrollment(operation, coordinator: coordinator, index: index)
            let journal = enrollmentJournal(handle.operationID, coordinator)
            guard let capture = try journal.read(PeerEnrollmentApproval.Capture.self, "capture.json") else {
                throw PeerEnrollmentApproval.failure(
                    "Build the finite enrollment baseline before acceptance.")
            }
            let plan = enrollmentPlan(operation, coordinator: coordinator, index: index)
            let export = try plan.reopen(planID: operation.planID, packageID: operation.packageID)
            guard let manifest = try plan.manifest(export) else {
                throw PeerEnrollmentApproval.failure("Enrollment baseline is not completely sealed.")
            }
            let record = try enrollmentRecord(operation, capture: capture, manifest: manifest)
            try journal.write(try AuthorityRecordCodec.encode(record), "approval.json")
            try stageEnrollmentRecord(
                AuthorityRecordCodec.encode(record), packageID: operation.publicationID,
                framingID: operation.framingID, operation: operation,
                coordinator: coordinator, index: index, approval: true)
            return try finishAcceptedPeerEnrollment(handle)
        }
    }
    func finishAcceptedPeerEnrollment(_ handle: PeerEnrollmentApproval.Handle) throws
        -> PeerEnrollmentApproval.Status
    {
        let coordinator = try requirePeerIntake()
        guard isCanonicalReady, let index else {
            throw PeerEnrollmentApproval.failure("Recover canonical source history first.")
        }
        let operation = try enrollmentOperation(handle, coordinator)
        let journal = enrollmentJournal(handle.operationID, coordinator)
        guard let bytes = try journal.read(Data.self, "approval.json"),
            let capture = try journal.read(PeerEnrollmentApproval.Capture.self, "capture.json")
        else {
            throw PeerEnrollmentApproval.failure("Exact enrollment approval/capture is absent.")
        }
        let original = try AuthorityRecordCodec.decode(bytes)
        let plan = enrollmentPlan(operation, coordinator: coordinator, index: index)
        let manifest = try plan.retainedManifest(planID: operation.planID, packageID: operation.packageID)
        guard
            try AuthorityRecordCodec.encode(enrollmentRecord(operation, capture: capture, manifest: manifest))
                == bytes,
            let publication = try coordinator.journal.publication(operation.publicationID),
            try publication.context == coordinator.context(peerID: "local"),
            publication.contextToken == PeerEnrollmentApproval.capability,
            try coordinator.journal.object(
                .init(
                    kind: .authority, id: operation.approvalID,
                    length: bytes.count, sha256: original.sha256), packageID: operation.publicationID)
                == bytes
        else {
            throw PeerEnrollmentApproval.failure(
                "Enrollment has no exact durable accepted publication proof.")
        }
        try coordinator.retainSealed(operation.publicationID, index: index)
        try validateEnrollmentAuthority(original, coordinator: coordinator, index: index)
        try coordinator.journal.applied(operation.publicationID)
        let accepted = try PeerEnrollmentApproval.Accepted(
            approval: .init(recordID: operation.approvalID, sha256: original.sha256),
            publicationID: operation.publicationID,
            manifestDigest: AuthorityRecordCodec.sha256(JSON.encode(manifest)))
        try journal.write(accepted, "accepted.json")
        _ = try activateOriginAdmissions(coordinator: coordinator, index: index)
        return .init(phase: .accepted, approval: accepted.approval, manifest: manifest)
    }
    func readPeerEnrollment(
        _ handle: PeerEnrollmentApproval.Handle, object: PeerPackage.Object,
        offset: Int, maximumBytes: Int = PeerPackage.maximumChunkBytes,
        forUID uid: UInt32
    ) throws -> PeerExportPlan.Chunk {
        try withAccess(forUID: uid) {
            let coordinator = try requirePeerIntake()
            guard let index else {
                throw PeerEnrollmentApproval.failure("Enrollment requires its rebuilt inventory.")
            }
            let operation = try enrollmentOperation(handle, coordinator)
            _ = try finishAcceptedPeerEnrollment(handle)  // Private marker alone never authorizes bytes.
            try requireCurrentEnrollment(operation, coordinator: coordinator, index: index)
            let plan = enrollmentPlan(operation, coordinator: coordinator, index: index)
            let export = try plan.reopen(planID: operation.planID, packageID: operation.packageID)
            return try plan.read(export, object: object, offset: offset, maximumBytes: maximumBytes)
        }
    }
}

extension ItemStore {
    /// Source acceptance replay validates canonical proof and historical authority. Pending private
    /// work does not block ordinary opening; a disposable unfinished export needs explicit review.
    private func validateSourceEnrollmentApprovals(coordinator: PeerIntakeCoordinator, index: ItemIndex)
        throws
    {
        let directory = root.appendingPathComponent(PeerEnrollmentApproval.directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var work = 0
        try POSIXDirectory.withEntries(at: directory) { name in
            work += 1
            guard work <= coordinator.journal.limits.maximumObjects else {
                throw TractandaError("resourceLimit", "Enrollment replay exceeds its operation window.")
            }
            let handle = PeerEnrollmentApproval.Handle(operationID: name)
            let journal = enrollmentJournal(name, coordinator)
            guard let operation = try journal.read(PeerEnrollmentApproval.Operation.self, "request.json")
            else {
                return true  // An interrupted private key staging is inert.
            }
            guard let publication = try coordinator.journal.publication(operation.publicationID) else {
                return true
            }
            _ = try enrollmentOperation(handle, coordinator)
            guard let bytes = try journal.read(Data.self, "approval.json"),
                let capture = try journal.read(PeerEnrollmentApproval.Capture.self, "capture.json")
            else {
                throw PeerEnrollmentApproval.failure(
                    "Accepted enrollment lost its exact private request/capture proof.")
            }
            let original = try AuthorityRecordCodec.decode(bytes)
            let manifest = try enrollmentPlan(operation, coordinator: coordinator, index: index)
                .retainedManifest(planID: operation.planID, packageID: operation.packageID)
            guard
                try AuthorityRecordCodec.encode(
                    enrollmentRecord(operation, capture: capture, manifest: manifest)) == bytes,
                publication.contextToken == PeerEnrollmentApproval.capability,
                try publication.context == coordinator.context(peerID: "local"),
                try coordinator.journal.object(
                    .init(
                        kind: .authority, id: operation.approvalID,
                        length: bytes.count, sha256: original.sha256), packageID: operation.publicationID)
                    == bytes,
                let raw = try index.retainedAuthorityObject(id: operation.approvalID),
                raw.descriptor.sha256 == original.sha256,
                try coordinator.hasLocalPublicationReceipt(
                    objectID: operation.approvalID,
                    origin: original.record.originReplicaID, index: index)
            else {
                throw PeerEnrollmentApproval.failure(
                    "Accepted canonical enrollment publication is incomplete or changed.")
            }
            try validateEnrollmentAuthority(original, coordinator: coordinator, index: index)
            return true
        }
    }
    func peerEnrollmentApprovalBytes(_ handle: PeerEnrollmentApproval.Handle, forUID uid: UInt32) throws
        -> Data
    {
        try withAccess(forUID: uid) {
            let coordinator = try requirePeerIntake()
            guard let index else {
                throw PeerEnrollmentApproval.failure("Recover enrollment source inventory first.")
            }
            let operation = try enrollmentOperation(handle, coordinator)
            _ = try finishAcceptedPeerEnrollment(handle)
            try requireCurrentEnrollment(operation, coordinator: coordinator, index: index)
            guard
                let bytes = try enrollmentJournal(handle.operationID, coordinator).read(
                    Data.self, "approval.json")
            else {
                throw PeerEnrollmentApproval.failure("Accepted approval bytes are unavailable.")
            }
            return bytes
        }
    }
}

extension ItemStore {
    var originAdmissionBoundaryForTesting: ((String) throws -> Void)? {
        get { peerIntake?.originAdmissionBoundaryForTesting }
        set { peerIntake?.originAdmissionBoundaryForTesting = newValue }
    }
    /// Host-private historical membership inspection; neither channel authentication nor a grant.
    func peerOriginMembership(_ origin: String, readBudget: ((Int) throws -> Void)? = nil) throws
        -> AuthorityBinding?
    {
        let coordinator = try requirePeerIntake()
        guard let index else {
            throw TractandaError("indexUnavailable", "Membership requires canonical replay.")
        }
        return try index.withCatalogueScanBudget(reusingActiveBudget: true) {
            try coordinator.withOperation {
                try coordinator.originAdmission(origin, index: index, readBudget: readBudget)
            }
        }
    }

    /// Historical public decision replay: never loads a private enrollment request or any key.
    private func validateOriginAdmissions(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws {
        let directory = root.appendingPathComponent(PeerOriginAdmission.directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var work = 0
        try POSIXDirectory.withEntries(at: directory) { origin in
            work += 1
            guard work <= min(4096, coordinator.journal.limits.maximumObjects),
                let decision = try coordinator.originDecision(origin),
                try coordinator.originAdmission(origin, index: index) != nil
            else {
                throw PeerOriginAdmission.failure("Canonical membership replay lost its public authority.")
            }
            let original = try coordinator.admissionOriginal(decision)
            try validateEnrollmentAuthority(original, coordinator: coordinator, index: index)
            guard
                try index.peerAuthorityTimePermits(
                    origin: original.record.originReplicaID,
                    ticks: PeerLifecycle.revisionTicks(original.record.recordID))
            else {
                throw PeerOriginAdmission.failure("Admission issuer was already disposed at issuance.")
            }
            return true
        }
        _ = try coordinator.replayOriginReceipts(index: index, create: false)
    }

    /// Validated explicit-target decisions form a bounded anchored fixed point, not a peer-list union.
    @discardableResult
    private func activateOriginAdmissions(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws -> Bool
    {
        try coordinator.withOperation {
            try index.withCatalogueScanBudget(reusingActiveBudget: true) {
                try activateOriginAdmissionsBody(coordinator: coordinator, index: index)
            }
        }
    }
    private func activateOriginAdmissionsBody(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws
        -> Bool
    {
        var changed = false
        var progress = true
        var work = 0
        while progress {
            progress = false
            var after: String?
            while true {
                let rows = try index.authorityKindPage(kind: "enrollmentApproval", after: after, limit: 128)
                if rows.isEmpty { break }
                for row in rows {
                    after = row.descriptor.id
                    work += 1
                    try coordinator.progress?()
                    guard work <= coordinator.journal.limits.maximumWork else {
                        throw TractandaError("resourceLimit", "Origin admission decision work exhausted.")
                    }
                    let original = try AuthorityRecordCodec.decode(coordinator.bytes(row))
                    let record = original.record
                    let target = try AuthorityRecord.persistentID(record.payload["targetReplicaID"])
                    if try coordinator.originDecision(target) != nil { continue }
                    guard let issuer = try coordinator.originAdmission(record.originReplicaID, index: index),
                        record.originReplicaID != target,
                        try index.peerAuthorityTimePermits(
                            origin: record.originReplicaID,
                            ticks: PeerLifecycle.revisionTicks(record.recordID)),
                        let receipt = try coordinator.freshReceipt(
                            record.recordID, origin: record.originReplicaID, index: index),
                        let publication = try coordinator.journal.publication(
                            receipt.packageID, readBudget: coordinator.admissionReadBudget())
                    else { continue }
                    if publication.context.peerID == "local",
                        publication.contextToken != PeerEnrollmentApproval.capability
                    {
                        continue
                    }
                    if let prior = record.payload["issuerAdmission"] {
                        guard try AuthorityRecord.list(prior).map(AuthorityBinding.init(value:)) == [issuer]
                        else { continue }
                    } else {
                        // Earlier canonical envelopes can only root directly in the permanent initialization.
                        guard
                            let pin = try coordinator.configuration(
                                readBudget: coordinator.admissionReadBudget())?.bootstrap,
                            issuer == (try AuthorityBinding(recordID: pin.recordID, sha256: pin.sha256))
                        else { continue }
                    }
                    do {
                        try validateEnrollmentAuthority(original, coordinator: coordinator, index: index)
                    } catch let error as TractandaError
                        where ["missingDependencies", "enrollmentReviewRequired"].contains(error.code)
                    {
                        continue  // Retained unvalidated testimony is not membership.
                    }
                    let decision = PeerOriginAdmission.Decision(
                        profile: PeerOriginAdmission.capability,
                        target: target, approval: row.descriptor, packageID: receipt.packageID,
                        issuerAdmission: issuer)
                    try CanonicalReaderRequirement.beforeOriginAdmissionPublication(
                        root: root, ownerUID: ownerUID)
                    try coordinator.journal.files.writeImmutable(
                        JSON.encode(decision),
                        path: [PeerOriginAdmission.directory, target],
                        maximumBytes: PeerPackage.maximumPageBytes)
                    try coordinator.originAdmissionBoundaryForTesting?(target)
                    progress = true
                    changed = true
                }
            }
            if try coordinator.replayOriginReceipts(index: index, create: true) { changed = true }
        }
        return changed
    }

    private func reconsiderOriginObservations(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws {
        var after: String?
        var work = 0
        while true {
            let packages = try index.originReconsiderationPage(after: after)
            if packages.isEmpty { break }
            for package in packages {
                after = package
                work += 1
                guard work <= coordinator.journal.limits.maximumWork else {
                    throw TractandaError("resourceLimit", "Admission reconsideration work exhausted.")
                }
                _ = try coordinator.evaluatePending(
                    packageID: package, index: index,
                    evaluate: {
                        try self.evaluateIncomingAuthority(
                            $0, evidence: $1, coordinator: coordinator, index: index)
                    },
                    evaluateMaterialization: {
                        try self.evaluateAuthorityMaterialization($0, coordinator: coordinator, index: index)
                    },
                    beforeAcceptance: {
                        try self.sealAuthorityAcceptance(
                            $0, evaluation: $1, coordinator: coordinator, index: index)
                    })
                try promoteEligiblePeerPackage(package, coordinator: coordinator, index: index)
                try index.execute("DELETE FROM peer_origin_reconsideration WHERE package=?", [package])
            }
        }
    }
}

// Exact accepted finite enrollment completion. No listener or ordinary service can open this owner.
extension ItemStore {
    func peerEnrollmentActivationMaterial(_ handle: PeerEnrollmentApproval.Handle, forUID uid: UInt32) throws
        -> PeerEnrollmentActivation.Material
    {
        try withAccess(forUID: uid) {
            let c = try requirePeerIntake()
            return try c.withOperation {
                guard let index else {
                    throw PeerEnrollmentActivation.failure("Recover source inventory first.")
                }
                let op = try enrollmentOperation(handle, c, readBudget: c.admissionReadBudget())
                let status = try finishAcceptedPeerEnrollment(handle)
                try requireCurrentEnrollment(op, coordinator: c, index: index)
                let keys = try enrollmentKeys(op, c)
                guard let baseline = status.manifest,
                    let approval = try enrollmentJournal(op.operationID, c).read(
                        Data.self, "approval.json", readBudget: c.admissionReadBudget()),
                    let prepared = try c.journal.preparedPublication(
                        op.publicationID, readBudget: c.admissionReadBudget()),
                    let published = try c.journal.publication(
                        op.publicationID, readBudget: c.admissionReadBudget())
                else {
                    throw PeerEnrollmentActivation.failure(
                        "Accepted complete approval publication is absent.")
                }
                let manifest = try c.journal.beginRecord(
                    op.publicationID, readBudget: c.admissionReadBudget()
                ).manifest
                guard
                    let framing = try c.journal.object(
                        manifest.root, packageID: op.publicationID, readBudget: c.admissionReadBudget())
                else {
                    throw PeerEnrollmentActivation.failure("Accepted approval framing is absent.")
                }
                return .init(
                    preparationBytes: op.input.preparationBytes, baseline: baseline,
                    proof: .init(
                        manifest: manifest, framingBytes: framing, approvalBytes: approval,
                        prepared: prepared, publication: published),
                    sourceContext: op.input.sourceContext, targetContext: op.input.targetContext,
                    targetCredential: keys.1, targetPrivateBytesDigest: op.input.targetPrivateBytesDigest)
            }
        }
    }
    private func provisioningOwner() throws -> (PeerEnrollmentActivation.Scope, PeerIntakeCoordinator) {
        guard let scope = targetProvisioningScope else {
            throw PeerEnrollmentActivation.failure(
                "Only the private provisioning owner can complete this target.")
        }
        try scope.validate()
        return (scope, try requirePeerIntake())
    }
    func startTargetEnrollment() throws {
        let (scope, _) = try provisioningOwner()
        for manifest in [scope.record.baseline, scope.record.proof.manifest] {
            _ = try beginPeerIntake(context: scope.record.targetContext, manifestBytes: JSON.encode(manifest))
        }
        let proof = scope.record.proof
        _ = try appendTargetEnrollment(
            packageID: proof.manifest.packageID, object: proof.manifest.root,
            offset: 0, bytes: proof.framingBytes)
        let original = try AuthorityRecordCodec.decode(proof.approvalBytes)
        _ = try appendTargetEnrollment(
            packageID: proof.manifest.packageID,
            object: .init(
                kind: .authority, id: original.record.recordID, length: proof.approvalBytes.count,
                sha256: original.sha256), offset: 0, bytes: proof.approvalBytes)
    }
    func appendTargetEnrollment(packageID: String, object: PeerPackage.Object, offset: Int, bytes: Data)
        throws -> PeerPackage.Status
    {
        let (scope, c) = try provisioningOwner()
        return try c.withOperation {
            // Descriptor possession is not admission. Discover it from the two exact immutable
            // approved manifest trees before creating any original/document staging binding.
            var cursor: PeerPackage.ResumeCursor?
            var work = 0
            var found = false
            repeat {
                let page = try resumePeerIntake(
                    context: scope.record.targetContext, packageID: packageID,
                    cursor: cursor, limit: targetEnrollmentPageLimitForTesting ?? 128, progress: c.progress)
                work += page.objects.count + 1
                guard work <= c.journal.limits.maximumWork else {
                    throw TractandaError(
                        "resourceLimit", "Provisioning descriptor discovery exhausted its work window.")
                }
                if page.objects.contains(where: { $0.descriptor == object }) {
                    found = true
                    break
                }
                if page.blockedOnIndex { break }
                cursor = page.nextCursor
            } while cursor != nil
            guard found else {
                throw PeerEnrollmentActivation.failure(
                    "Object is outside the exact currently discoverable approved closure.")
            }
            return try appendPeerObject(
                context: scope.record.targetContext, packageID: packageID,
                object: object, offset: offset, bytes: bytes)
        }
    }
    func resumeTargetEnrollment(packageID: String, cursor: PeerPackage.ResumeCursor?, limit: Int) throws
        -> PeerPackage.ResumePage
    {
        let (scope, coordinator) = try provisioningOwner()
        return try resumePeerIntake(
            context: scope.record.targetContext, packageID: packageID, cursor: cursor, limit: limit,
            progress: coordinator.progress)
    }
    /// Walks the finite retained manifest; never infers completeness from an applied marker.
    private func requireProvisioningClosure(
        _ manifest: PeerPackage.Manifest,
        context: PeerPackage.Context
    ) throws {
        var cursor: PeerPackage.ResumeCursor?
        var work = 0
        repeat {
            let page = try resumePeerIntake(
                context: context, packageID: manifest.packageID, cursor: cursor,
                limit: targetEnrollmentPageLimitForTesting ?? 128, progress: try requirePeerIntake().progress)
            work += page.objects.count + 1
            guard work <= PeerPackage.Limits().maximumWork,
                !page.blockedOnIndex, page.objects.allSatisfy({ $0.verifiedComplete })
            else {
                throw TractandaError(
                    "missingDependencies", "Exact approved enrollment closure remains incomplete.")
            }
            cursor = page.nextCursor
        } while cursor != nil
    }
    /// Replayed after SQLite loss too. It uses actual receiver receipts and historical public
    /// policy/control proof, never the source's private marker or the survival of an ancestor key.
    private func validateTargetEnrollment(
        coordinator c: PeerIntakeCoordinator, index: ItemIndex,
        requireReceipt: Bool = true,
        validation: TargetEnrollmentValidation = .committedControls
    ) throws {
        guard
            let record = try PeerEnrollmentActivation.loadRecord(
                c.journal.files,
                readBudget: c.admissionReadBudget())
        else {
            if try PeerEnrollmentActivation.requiresTargetProof(root: root, ownerUID: ownerUID) {
                throw PeerEnrollmentActivation.failure(
                    "Required target activation request is absent during canonical replay.")
            }
            return
        }
        if requireReceipt,
            try PeerEnrollmentActivation.loadReceipt(c.journal.files, readBudget: c.admissionReadBudget())
                == nil
        {
            return
        }
        if validation == .committedControls, !isCanonicalReady {
            throw PeerEnrollmentActivation.failure(
                "Bounded committed-proof validation requires the existing validated catalogue checkpoint/replay."
            )
        }
        let prep = try record.preparation
        guard replicaID == prep.targetReplicaID, c.storeID == prep.commonStoreID,
            let pin = try c.configuration(readBudget: c.admissionReadBudget())?.bootstrap,
            pin.recordID == record.pin.bootstrap.recordID, pin.sha256 == record.pin.bootstrap.sha256
        else {
            throw PeerEnrollmentActivation.failure(
                "Target bootstrap/identity differs from approved preparation.")
        }
        let original = try AuthorityRecordCodec.decode(record.proof.approvalBytes)
        let administrationIDs = try Set(
            AuthorityRecord.list(original.record.payload["administrationPolicies"])
                .map { try AuthorityRecord.binding($0).revisionID })
        for manifest in [record.baseline, record.proof.manifest] {
            guard
                let publication = try c.journal.publication(
                    manifest.packageID, readBudget: c.admissionReadBudget()),
                publication.context == record.targetContext,
                publication.manifestDigest == AuthorityRecordCodec.sha256(try JSON.encode(manifest)),
                try c.journal.preparedPublication(manifest.packageID, readBudget: c.admissionReadBudget())
                    == publication
            else {
                throw PeerEnrollmentActivation.failure(
                    "Target activation lost an exact accepted receiver publication.")
            }
            if validation == .fullReplay {
                try c.journal.walk(manifest.packageID, readBudget: c.admissionReadBudget()) { object, bytes in
                    // Full initial activation/canonical rebuild owns this finite original walk.
                    // Warm checkpoint opening and accepted completion retries retain exact seals
                    // and historical control proof, without rehashing the entire baseline.
                    if object.kind == .authority || object.kind == .item {
                        guard let row = try index.retainedAuthorityObject(id: object.id),
                            row.descriptor == object
                        else {
                            throw PeerEnrollmentActivation.failure(
                                "Activated target lost an approved retained original.")
                        }
                        let original = try c.bytes(row)
                        if object.kind == .item, !administrationIDs.contains(object.id) {
                            targetEnrollmentReadMetrics.record(object.id)
                        }
                        guard bytes == nil || bytes == original else {
                            throw PeerEnrollmentActivation.failure(
                                "Activated target lost approved retained original proof.")
                        }
                    }
                }
            }
        }
        guard let row = try index.retainedAuthorityObject(id: record.pin.approval.recordID),
            row.descriptor.sha256 == record.pin.approval.sha256,
            try c.bytes(row) == record.proof.approvalBytes,
            try c.originAdmission(prep.targetReplicaID, index: index) == record.pin.approval
        else {
            throw PeerEnrollmentActivation.failure("Target has no exact canonical accepted global admission.")
        }
        try validateEnrollmentAuthority(original, coordinator: c, index: index)
    }
    func activateTargetEnrollment() throws -> PeerEnrollmentActivation.Receipt {
        let (scope, c) = try provisioningOwner()
        return try c.withOperation {
            do {
                let record = scope.record
                let prep = try record.preparation
                if let done = try PeerEnrollmentActivation.loadReceipt(
                    c.journal.files, readBudget: c.admissionReadBudget())
                {
                    try PeerEnrollmentActivation.requireActivated(root: root, ownerUID: ownerUID)
                    try validateTargetEnrollment(coordinator: c, index: index!)
                    return done
                }
                try requireProvisioningClosure(record.baseline, context: record.targetContext)
                _ = try commitPeerIntake(
                    context: record.targetContext, packageID: record.baseline.packageID,
                    expectedContextToken: peerIntakeContextToken())
                try targetProvisioningProgress?("baselineAccepted")
                if let pin = try c.configuration(readBudget: c.admissionReadBudget())?.bootstrap {
                    guard pin.recordID == record.pin.bootstrap.recordID,
                        pin.sha256 == record.pin.bootstrap.sha256
                    else {
                        throw PeerEnrollmentActivation.failure("Permanent target bootstrap differs.")
                    }
                } else {
                    // The ordinary independently reviewed initial pin performs the real policy handoff.
                    try pinAuthorityBootstrap(
                        rootID: record.pin.bootstrap.recordID, sha256: record.pin.bootstrap.sha256,
                        expectedContextToken: peerIntakeContextToken(), actorUID: ownerUID)
                }
                try targetProvisioningProgress?("bootstrapPinned")
                try requireProvisioningClosure(record.proof.manifest, context: record.targetContext)
                _ = try commitPeerIntake(
                    context: record.targetContext, packageID: record.proof.manifest.packageID,
                    expectedContextToken: peerIntakeContextToken())
                guard let index = self.index else {
                    throw PeerEnrollmentActivation.failure("Recover target inventory.")
                }
                try validateTargetEnrollment(
                    coordinator: c, index: index, requireReceipt: false, validation: .fullReplay)
                guard try !index.peerOriginRetired(prep.targetReplicaID),
                    try !index.peerOriginRetired(prep.sourceReplicaID)
                else {
                    throw PeerEnrollmentActivation.failure("A disposed node cannot activate a pairing.")
                }
                try targetProvisioningProgress?("approvalAccepted")
                let path = [PeerEnrollmentActivation.directory, "configuration.json"]
                let old = try c.configuration(readBudget: c.admissionReadBudget())
                let commit: PeerEnrollmentActivation.ConfigurationCommit
                if let bytes = try c.journal.files.readIfPresent(
                    path: path, maximumBytes: PeerEnrollmentActivation.maximumBytes,
                    readBudget: c.admissionReadBudget())
                {
                    commit = try PeerPackage.decode(PeerEnrollmentActivation.ConfigurationCommit.self, bytes)
                    guard commit.profile == PeerEnrollmentActivation.capability,
                        commit.requestDigest == (try record.digest), commit.approval == record.pin.approval,
                        old == commit.before || old == commit.after
                    else {
                        throw PeerEnrollmentActivation.failure(
                            "Activation configuration changed outside this accepted operation.")
                    }
                } else {
                    guard let old, old.peers.isEmpty, old.credentialBindings?.isEmpty != false,
                        old.lifecycle?.historicalContexts.isEmpty != false
                    else {
                        throw PeerEnrollmentActivation.failure(
                            "A prepared target cannot adopt unrelated pairing history.")
                    }
                    let after = AuthorityStore.Configuration(
                        profile: old.profile, peers: [record.targetContext],
                        bootstrap: old.bootstrap, lifecycle: old.lifecycle,
                        credentialBindings: [record.targetContext.peerID: record.targetCredentialCommitment])
                    commit = .init(
                        profile: PeerEnrollmentActivation.capability, requestDigest: try record.digest,
                        approval: record.pin.approval, before: old, after: after,
                        sequence: try AuthorityStore.configurationSequence(root: root) + 1)
                    try CanonicalReaderRequirement.beforeEnrollmentActivationPublication(
                        root: root, ownerUID: ownerUID)
                    try c.journal.files.writeImmutable(
                        JSON.encode(commit), path: path,
                        maximumBytes: PeerEnrollmentActivation.maximumBytes)
                }
                try PeerEnrollmentActivation.validateTargetConfiguration(commit, record: record)
                try AuthorityStore.writeConfiguration(
                    commit.after, root: root, files: c.journal.files, sequence: commit.sequence)
                try targetProvisioningProgress?("configurationCommitted")
                let receipt = PeerEnrollmentActivation.Receipt(
                    profile: PeerEnrollmentActivation.capability,
                    requestDigest: try record.digest, approval: record.pin.approval,
                    baselineDigest: AuthorityRecordCodec.sha256(try JSON.encode(record.baseline)),
                    configurationDigest: AuthorityRecordCodec.sha256(try JSON.encode(commit.after)),
                    configurationSequence: commit.sequence)
                try c.journal.files.writeImmutable(
                    JSON.encode(receipt),
                    path: [PeerEnrollmentActivation.directory, "activated.json"],
                    maximumBytes: PeerEnrollmentActivation.maximumBytes)
                try targetProvisioningProgress?("receiptCommitted")
                try PeerEnrollmentActivation.requireActivated(root: root, ownerUID: ownerUID)
                targetProvisioningPending = false
                c.provisioningScope = nil
                return receipt
            }
        }
    }
}

extension ItemStore {
    private func enrollmentOwnAdmission(
        _ operation: PeerEnrollmentApproval.Operation,
        _ c: PeerIntakeCoordinator
    ) throws -> AuthorityBinding? {
        guard let decision = try c.originDecision(operation.input.sourceContext.permittedOrigins[0]),
            decision.approval.id == operation.approvalID,
            let bytes = try enrollmentJournal(operation.operationID, c).read(
                Data.self, "approval.json", readBudget: c.admissionReadBudget()),
            let accepted = try enrollmentJournal(operation.operationID, c).read(
                PeerEnrollmentApproval.Accepted.self, "accepted.json", readBudget: c.admissionReadBudget()),
            accepted.approval.recordID == operation.approvalID,
            accepted.approval.sha256 == AuthorityRecordCodec.sha256(bytes),
            decision.approval.sha256 == accepted.approval.sha256
        else { return nil }
        return accepted.approval
    }
    private func registrationCommit(
        _ operation: PeerEnrollmentApproval.Operation,
        _ c: PeerIntakeCoordinator
    ) throws -> PeerEnrollmentActivation.ConfigurationCommit? {
        guard
            let bytes = try c.journal.files.readIfPresent(
                path: [
                    PeerEnrollmentActivation.sourceDirectory, operation.operationID, "configuration.json",
                ],
                maximumBytes: PeerEnrollmentActivation.maximumBytes, readBudget: c.admissionReadBudget())
        else { return nil }
        let value = try PeerPackage.decode(PeerEnrollmentActivation.ConfigurationCommit.self, bytes)
        guard
            let accepted = try enrollmentJournal(operation.operationID, c).read(
                PeerEnrollmentApproval.Accepted.self, "accepted.json", readBudget: c.admissionReadBudget()),
            value.profile == PeerEnrollmentActivation.capability,
            value.requestDigest == AuthorityRecordCodec.sha256(try JSON.encode(operation)),
            value.approval == accepted.approval, value.sequence > 0,
            value.after == (try enrollmentRegisteredConfiguration(operation, before: value.before))
        else {
            throw PeerEnrollmentActivation.failure(
                "Source registration lost exact approved configuration transition.")
        }
        return value
    }
    private func enrollmentRegisteredConfiguration(
        _ op: PeerEnrollmentApproval.Operation,
        before: AuthorityStore.Configuration?
    ) throws -> AuthorityStore.Configuration {
        guard let before, before.peers.count < 256,
            !before.peers.contains(where: { $0.peerID == op.input.sourceContext.peerID }),
            !((before.lifecycle?.historicalContexts ?? []).contains(where: {
                $0.peerID == op.input.sourceContext.peerID
                    && $0.configurationDigest == op.input.sourceContext.configurationDigest
            })),
            before.bootstrap?.recordID == op.bootstrap.recordID,
            before.bootstrap?.sha256 == op.bootstrap.sha256
        else {
            throw PeerEnrollmentActivation.failure("Source peer slot/bootstrap/generation is unavailable.")
        }
        var bindings = before.credentialBindings ?? [:]
        bindings[op.input.sourceContext.peerID] = op.input.sourceCredentialCommitment
        return .init(
            profile: before.profile,
            peers: (before.peers + [op.input.sourceContext]).sorted { $0.peerID < $1.peerID },
            bootstrap: before.bootstrap, lifecycle: before.lifecycle, credentialBindings: bindings)
    }
    /// Only an exact operation-owned after-image can be normalized. Current unrelated security
    /// facts (policy, disposal, admission and every other configuration byte) remain in the fence.
    private func enrollmentConfigurationBeforeOwnRegistration(
        _ op: PeerEnrollmentApproval.Operation,
        _ c: PeerIntakeCoordinator
    ) throws -> Data? {
        guard let commit = try registrationCommit(op, c),
            try c.configuration(readBudget: c.admissionReadBudget()) == commit.after
        else { return nil }
        let bytes = try c.journal.files.read(
            path: [".peer-configuration", String(format: "%020llu.json", commit.sequence)],
            maximumBytes: PeerEnrollmentActivation.maximumBytes, readBudget: c.admissionReadBudget())
        guard bytes == (try JSON.encode(commit.after)) else {
            throw PeerEnrollmentActivation.failure("Source registration configuration witness differs.")
        }
        return try commit.before.map { try JSON.encode($0) } ?? Data()
    }
    /// Accepted historical completion, not a fresh grant. Host caller identity still resolves on
    /// the serial owner; canonical administrator proof and exact staged source secret are checked.
    func registerAcceptedPeerEnrollment(_ handle: PeerEnrollmentApproval.Handle, forUID uid: UInt32) throws {
        try withAccess(forUID: uid) {
            let c = try requirePeerIntake()
            return try c.withOperation {
                guard let index else {
                    throw PeerEnrollmentActivation.failure("Recover source inventory first.")
                }
                let op = try enrollmentOperation(handle, c, readBudget: c.admissionReadBudget())
                guard let account = accessContext?.account,
                    (uid == op.actorUID && account.name == op.actor) || isAdministrator
                else {
                    throw PeerEnrollmentActivation.failure(
                        "Only the exact authenticated operation author or a current global administrator can finish registration."
                    )
                }
                let status = try finishAcceptedPeerEnrollment(handle)
                let prep = try PeerEnrollmentApproval.preparation(op.input.preparationBytes)
                guard isCanonicalReady, authorityExistingHistoryAdmitted, !authorityCatchupActive,
                    try !index.peerOriginRetired(prep.sourceReplicaID),
                    try !index.peerOriginRetired(prep.targetReplicaID),
                    let approval = status.approval, try enrollmentOwnAdmission(op, c) == approval
                else {
                    throw PeerEnrollmentActivation.failure(
                        "Current disposal or canonical admission fences source registration.")
                }
                let key = try PeerCredentialStore(files: c.journal.files).load(
                    peerID: op.input.sourceContext.peerID,
                    configurationDigest: op.input.sourceContext.configurationDigest)
                guard try key.commitment == op.input.sourceCredentialCommitment,
                    try key.privateBytesDigest == op.input.sourcePrivateBytesDigest,
                    key.binding.localReplicaID == prep.sourceReplicaID,
                    key.binding.remoteReplicaID == prep.targetReplicaID,
                    !((try c.configuration(readBudget: c.admissionReadBudget())?.lifecycle?.historicalContexts
                        ?? []).contains(op.input.sourceContext)),
                    try peerExchangeSecurityBinding(
                        coordinator: c, index: index, excludingAdmission: approval,
                        configurationOverride: enrollmentConfigurationBeforeOwnRegistration(op, c))
                        == op.securityBinding
                else {
                    throw PeerEnrollmentActivation.failure(
                        "Source generation, exact private bytes or unrelated security changed.")
                }
                let path = [PeerEnrollmentActivation.sourceDirectory, op.operationID, "configuration.json"]
                let commit: PeerEnrollmentActivation.ConfigurationCommit
                if let saved = try registrationCommit(op, c) {
                    commit = saved
                    guard
                        try c.configuration(readBudget: c.admissionReadBudget()) == commit.before
                            || c.configuration(readBudget: c.admissionReadBudget()) == commit.after
                    else {
                        throw PeerEnrollmentActivation.failure(
                            "Unrelated configuration change fences source registration.")
                    }
                } else {
                    let before = try c.configuration(readBudget: c.admissionReadBudget())
                    commit = .init(
                        profile: PeerEnrollmentActivation.capability,
                        requestDigest: AuthorityRecordCodec.sha256(try JSON.encode(op)), approval: approval,
                        before: before, after: try enrollmentRegisteredConfiguration(op, before: before),
                        sequence: try AuthorityStore.configurationSequence(root: root) + 1)
                    try CanonicalReaderRequirement.beforeEnrollmentActivationPublication(
                        root: root, ownerUID: ownerUID)
                    try c.journal.files.writeImmutable(
                        JSON.encode(commit), path: path,
                        maximumBytes: PeerEnrollmentActivation.maximumBytes)
                }
                try c.enrollmentBoundaryForTesting?("registrationPrepared")
                try AuthorityStore.writeConfiguration(
                    commit.after, root: root, files: c.journal.files, sequence: commit.sequence)
                try c.enrollmentBoundaryForTesting?("registrationCommitted")
                let marker = [PeerEnrollmentActivation.sourceDirectory, op.operationID, "registered.json"]
                let acknowledgement = try JSON.encode(approval)
                // All current authority, exact private bytes and canonical configuration checks above
                // still run on a retry. The immutable acknowledgement itself is exact-idempotent.
                if let existing = try c.journal.files.readIfPresent(
                    path: marker,
                    maximumBytes: PeerEnrollmentActivation.maximumBytes, readBudget: c.admissionReadBudget())
                {
                    guard existing == acknowledgement else {
                        throw PeerEnrollmentActivation.failure(
                            "Source registration acknowledgement bytes differ.")
                    }
                    try c.journal.files.synchronizeDirectory(Array(marker.dropLast()))
                } else {
                    try c.journal.files.writeImmutable(
                        acknowledgement, path: marker,
                        maximumBytes: PeerEnrollmentActivation.maximumBytes)
                }
            }
        }
    }
    private func validateSourceRegistrations(coordinator c: PeerIntakeCoordinator) throws {
        let directory = root.appendingPathComponent(PeerEnrollmentActivation.sourceDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var work = 0
        try POSIXDirectory.withEntries(at: directory) { name in
            work += 1
            guard work <= c.journal.limits.maximumObjects else {
                throw TractandaError("resourceLimit", "Source registration replay window exceeded.")
            }
            let op = try enrollmentOperation(.init(operationID: name), c, readBudget: c.admissionReadBudget())
            guard let commit = try registrationCommit(op, c) else {
                throw PeerEnrollmentActivation.failure("Registration lost exact configuration intent.")
            }
            if let bytes = try c.journal.files.readIfPresent(
                path: [PeerEnrollmentActivation.sourceDirectory, name, "registered.json"],
                maximumBytes: PeerEnrollmentActivation.maximumBytes, readBudget: c.admissionReadBudget())
            {
                guard try PeerPackage.decode(AuthorityBinding.self, bytes) == commit.approval,
                    try c.journal.files.read(
                        path: [".peer-configuration", String(format: "%020llu.json", commit.sequence)],
                        maximumBytes: PeerEnrollmentActivation.maximumBytes,
                        readBudget: c.admissionReadBudget()) == JSON.encode(commit.after)
                else {
                    throw PeerEnrollmentActivation.failure(
                        "Registration lost historical committed configuration proof.")
                }
            }
            return true
        }
    }
}

// Native-only operator adapters. Private enrollment scopes remain constructed inside Core.
extension ItemStore {
    func nativeEnrollmentPreflight(forUID uid: UInt32) throws {
        try withAccess(forUID: uid) {
            _ = try nativeCredentialRegistrationContext()
            guard authorityExistingHistoryAdmitted, !authorityCatchupActive, let index,
                try index.acceptedGraphProofIsCurrent(),
                try requirePeerIntake().configuration()?.bootstrap != nil
            else {
                throw PeerEnrollmentApproval.failure("Enrollment requires a recovered current source.")
            }
        }
    }
    private func nativeEnrollmentDescription(
        _ operation: PeerEnrollmentApproval.Operation, phase: String,
        approval: AuthorityBinding? = nil, manifest: PeerPackage.Manifest? = nil
    ) throws -> PeerEnrollmentOperatorStatus {
        let prep = try PeerEnrollmentApproval.preparation(operation.input.preparationBytes)
        return try .init(
            operationID: operation.operationID, phase: phase, storeID: prep.commonStoreID,
            sourceReplicaID: prep.sourceReplicaID, targetReplicaID: prep.targetReplicaID,
            bootstrap: operation.bootstrap, approval: approval,
            baselineManifest: manifest.map { try JSON.encode($0) })
    }
    func nativeEnrollmentBegin(_ input: PeerEnrollmentPairInput, forUID uid: UInt32) throws
        -> PeerEnrollmentOperatorStatus
    {
        try nativeEnrollmentPreflight(forUID: uid)
        let pair = try input.withBytes { try PeerEnrollmentPairInput.decode($0) }
        return try withAccess(forUID: uid) {
            let c = try requirePeerIntake()
            guard let index, let source = replicaID else { throw NativePeerEnrollment.failure() }
            let saved = try enrollmentJournal(pair.operationID, c).read(
                PeerEnrollmentApproval.Operation.self, "request.json")
            let prep = try PeerEnrollmentApproval.preparation(pair.preparationBytes)
            // Exact retries preserve the original origin set, including after their own admission.
            let sourceContext =
                try saved?.input.sourceContext
                ?? PeerPackage.Context(
                    peerID: pair.sourceCredential.binding.peerID,
                    storeID: prep.commonStoreID,
                    configurationDigest: pair.sourceCredential.binding.configurationDigest,
                    permittedOrigins: [prep.targetReplicaID])
            let targetContext =
                try saved?.input.targetContext
                ?? PeerPackage.Context(
                    peerID: pair.targetCredential.binding.peerID,
                    storeID: prep.commonStoreID,
                    configurationDigest: pair.targetCredential.binding.configurationDigest,
                    permittedOrigins: c.admittedOriginSnapshot(index: index, localOrigin: source))
            let request = PeerEnrollmentApproval.Request(
                operationID: pair.operationID, preparationBytes: pair.preparationBytes,
                sourceContext: sourceContext, targetContext: targetContext,
                sourceCredential: pair.sourceCredential,
                targetCredential: pair.targetCredential)
            let handle = try beginPeerEnrollment(request, forUID: uid)
            return try nativeEnrollmentStatus(handle.operationID, forUID: uid)
        }
    }
    /// Reads bounded request/seal/publication witnesses. Never selects, repairs or finishes work.
    func nativeEnrollmentStatus(_ operationID: String, forUID uid: UInt32) throws
        -> PeerEnrollmentOperatorStatus
    {
        try withAccess(forUID: uid) {
            let c = try requirePeerIntake()
            return try c.withOperation {
                guard let index else { throw NativePeerEnrollment.failure() }
                let operation = try enrollmentOperation(.init(operationID: operationID), c)
                try requireCurrentEnrollment(operation, coordinator: c, index: index)
                let journal = enrollmentJournal(operationID, c)
                let plan = enrollmentPlan(operation, coordinator: c, index: index)
                if let publication = try c.journal.publication(operation.publicationID) {
                    guard let bytes = try journal.read(Data.self, "approval.json"),
                        let capture = try journal.read(PeerEnrollmentApproval.Capture.self, "capture.json")
                    else {
                        throw PeerEnrollmentApproval.failure("Accepted source proof is unavailable.")
                    }
                    let manifest = try plan.retainedManifest(
                        planID: operation.planID, packageID: operation.packageID)
                    let original = try AuthorityRecordCodec.decode(bytes)
                    let descriptor = PeerPackage.Object(
                        kind: .authority, id: operation.approvalID, length: bytes.count,
                        sha256: original.sha256)
                    guard
                        try AuthorityRecordCodec.encode(
                            enrollmentRecord(operation, capture: capture, manifest: manifest)) == bytes,
                        publication.context == (try c.context(peerID: "local")),
                        publication.contextToken == PeerEnrollmentApproval.capability,
                        let row = try index.authorityReceipt(
                            objectID: operation.approvalID, packageID: operation.publicationID),
                        row.permittedOrigin, row.descriptor == descriptor,
                        try c.receiptContextPermits(
                            row, origin: original.record.originReplicaID, index: index),
                        try c.journal.retainedBytes(descriptor, publication: publication) == bytes,
                        try index.acceptedGraphProofIsCurrent()
                    else {
                        throw PeerEnrollmentApproval.failure(
                            "Accepted source status needs its actual retained canonical proof.")
                    }
                    try validateEnrollmentAuthority(original, coordinator: c, index: index)
                    let accepted = PeerEnrollmentApproval.Accepted(
                        approval: try .init(recordID: operation.approvalID, sha256: original.sha256),
                        publicationID: operation.publicationID,
                        manifestDigest: AuthorityRecordCodec.sha256(try JSON.encode(manifest)))
                    if let saved = try journal.read(PeerEnrollmentApproval.Accepted.self, "accepted.json") {
                        guard try JSON.encode(saved) == JSON.encode(accepted) else {
                            throw NativePeerEnrollment.failure()
                        }
                    }
                    return try nativeEnrollmentDescription(
                        operation, phase: "accepted", approval: accepted.approval, manifest: manifest)
                }
                if try c.journal.files.readIfPresent(
                    path: ["authority", "export", operation.planID, "begin.json"],
                    maximumBytes: PeerPackage.maximumPageBytes) != nil
                {
                    let handle = try plan.reopen(planID: operation.planID, packageID: operation.packageID)
                    if let manifest = try plan.manifest(handle) {
                        return try nativeEnrollmentDescription(operation, phase: "ready", manifest: manifest)
                    }
                    return try nativeEnrollmentDescription(operation, phase: "building")
                }
                return try nativeEnrollmentDescription(operation, phase: "pending")
            }
        }
    }
    func nativeEnrollmentCall(_ call: PeerEnrollmentNativeCall, forUID uid: UInt32) throws -> Data {
        return try withAccess(forUID: uid) {
            let handle = PeerEnrollmentApproval.Handle(operationID: call.operationID)
            switch call.action {
            case "status": return try JSON.encode(nativeEnrollmentStatus(call.operationID, forUID: uid))
            case "step", "accept":
                if call.action == "accept" {
                    let c = try requirePeerIntake()
                    let operation = try enrollmentOperation(handle, c)
                    if try c.journal.publication(operation.publicationID) != nil {
                        guard let account = accessContext?.account,
                            (uid == operation.actorUID && account.name == operation.actor) || isAdministrator
                        else {
                            throw TractandaError(
                                "forbidden",
                                "Only the exact operation author or a current global administrator can acknowledge accepted enrollment."
                            )
                        }
                    }
                }
                let status =
                    try call.action == "step"
                    ? stepPeerEnrollment(handle, forUID: uid) : acceptPeerEnrollment(handle, forUID: uid)
                let operation = try enrollmentOperation(handle, requirePeerIntake())
                return try JSON.encode(
                    nativeEnrollmentDescription(
                        operation, phase: status.phase.rawValue,
                        approval: status.approval, manifest: status.manifest))
            case "register":
                try registerAcceptedPeerEnrollment(handle, forUID: uid)
                let c = try requirePeerIntake()
                let operation = try enrollmentOperation(handle, c)
                let accepted = try enrollmentJournal(call.operationID, c).read(
                    PeerEnrollmentApproval.Accepted.self, "accepted.json")
                return try JSON.encode(
                    nativeEnrollmentDescription(operation, phase: "registered", approval: accepted?.approval))
            case "read":
                guard let object = call.object else { throw NativePeerEnrollment.failure() }
                let chunk = try readPeerEnrollment(
                    handle, object: object, offset: call.offset, maximumBytes: call.maximumBytes, forUID: uid)
                return try JSON.encode(
                    PeerEnrollmentNativeChunk(
                        object: chunk.descriptor, offset: chunk.offset, bytes: chunk.bytes))
            default: throw NativePeerEnrollment.failure()
            }
        }
    }
    func nativeEnrollmentValidateDelivery(_ operationID: String, forUID uid: UInt32) throws {
        try withAccess(forUID: uid) {
            let c = try requirePeerIntake()
            guard let index else { throw NativePeerEnrollment.failure() }
            let operation = try enrollmentOperation(.init(operationID: operationID), c)
            try requireCurrentEnrollment(operation, coordinator: c, index: index)
        }
    }
    func nativeEnrollmentExport(_ operationID: String, forUID uid: UInt32) throws
        -> PeerEnrollmentTargetOutput
    {
        try .init(material: peerEnrollmentActivationMaterial(.init(operationID: operationID), forUID: uid))
    }
}
