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

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A caller-scoped snapshot of readable personal overlays for one category evaluation.
/// Candidate revisions are resolved by target item only when their membership is evaluated.
struct CategoryOverrideIndex {
    private let overlaysByTargetID: [String: [Revision]]
    private let uid: UInt32
    private let resolver: PrincipalResolver

    init(overlaysByTargetID: [String: [Revision]], uid: UInt32, resolver: PrincipalResolver) {
        self.overlaysByTargetID = overlaysByTargetID
        self.uid = uid
        self.resolver = resolver
    }

    func decision(for item: Revision, categoryID: String) throws -> (decision: String, origin: String)? {
        let overlays = try (overlaysByTargetID[item.itemID] ?? []).filter { record in
            guard let owner = record.fields["permissions"]?.map?["owner"]?.string else { return false }
            return try resolver.userID(owner) == uid
        }
        guard overlays.count <= 1 else {
            throw TractandaError("invalidPersonalState", "Several personal overlays target the same item.")
        }
        if let overlay = overlays.first,
            let decision = overlay.fields["personalOverrides"]?.map?[categoryID]?.string
        {
            return (decision, "personal:\(overlay.revisionID)")
        }
        return item.fields["categoryOverrides"]?.map?[categoryID]?.string.map { ($0, "manual") }
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
    private var scopedStates: [String: (fingerprint: String, token: String)] = [:]
    private var savedViewPages: [String: [String]] = [:]
    private var savedViewPageDependencies: [String: Set<String>] = [:]
    private var savedViewPageOrder: [String] = []
    private var savedViewPageIDs = 0
    private var hasLivePersonalStateMemo: Bool?
    private var clockDependentCategories = false
    public var isMultiUser: Bool { accessConfiguration != nil }
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
        let visible = heads.values.filter { $0.canRead(accessContext, administrator: isAdministrator) }
        let personalOwners = visible.compactMap { item -> String? in
            guard item.classID == "PersonalStateItem",
                let owner = item.fields["permissions"]?.map?["owner"]?.string
            else { return nil }
            let resolved = try? context.resolver.userID(owner)
            return item.itemID + ":" + owner + ":" + (resolved.map(String.init) ?? "unresolved")
        }.sorted().joined(separator: "/")
        let fingerprint =
            visible.map(\.revisionID).sorted().joined(separator: "/")
            + ":" + (context.account?.groupIDs.sorted().map(String.init).joined(separator: ",") ?? "")
            + ":" + (context.account.map { "\($0.uid):\($0.name)" } ?? "")
            + ":" + personalOwners
        if let previous = scopedStates[accessScope], previous.fingerprint == fingerprint {
            return previous.token
        }
        if scopedStates.count >= 256 { scopedStates.removeAll() }
        let token = Identifier.make()
        scopedStates[accessScope] = (fingerprint, token)
        return token
    }
    public private(set) var recoveryWarnings: [String] = []
    public private(set) var startupRecovery: [String: String] = ["mode": "pending"]
    private var writer: Int32 = -1
    private var indexWriter: Int32 = -1
    private let usesExternalIndexDirectory: Bool
    private var index: ItemIndex?
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

        func url(root: URL) -> URL { root.appendingPathComponent(relativePath) }

        func catalogueRow(revisionID: String) -> ItemIndex.CatalogueRow {
            ItemIndex.CatalogueRow(
                revisionID: revisionID, itemID: itemID,
                path: relativePath, parentID: parentID,
                actor: actor, operationID: operationID, size: metadata.size,
                inode: metadata.inode, uid: metadata.uid,
                mode: metadata.mode, modificationSeconds: metadata.modificationSeconds,
                modificationNanoseconds: metadata.modificationNanoseconds, digest: digest)
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
                var retained = revision.fields
                retained.removeValue(forKey: "body")
                retained.removeValue(forKey: "requestIdentity")
                fields = retained
                full = nil
            } else {
                fields = revision.fields
                full = revision
            }
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
    var evictedCurrentHeadCount: Int { heads.values.filter(\.needsHydration).count }
    var historicalCacheBytesForTesting: Int { historicalCacheBytes }
    var currentHeadHydrationsForTesting = 0
    private var operations: [String: String] = [:]
    private var operationIDs: [String: [String]] = [:]

    private func currentRevision(_ itemID: String) throws -> Revision? {
        guard let resident = heads[itemID] else { return nil }
        if let full = resident.full { return full }
        currentHeadHydrationsForTesting += 1
        guard let revision = try loadRevision(resident.revisionID) else {
            throw TractandaError("recoveryError", "Current revision location is unavailable.")
        }
        return revision
    }

    private func retainedCategoryRevisions(excluding itemID: String) throws -> [Revision] {
        try heads.values.compactMap { head in
            guard head.itemID != itemID,
                head.fields["selection"] != nil || head.fields["categoryParents"] != nil
            else { return nil }
            guard let revision = head.full else {
                throw TractandaError("recoveryError", "Category head needs canonical hydration.")
            }
            return revision
        }
    }

    private func retainedConfigurationRevisions(excluding itemID: String) throws -> [Revision] {
        try heads.values.compactMap { head in
            guard head.itemID != itemID, head.classID == AccessConfiguration.classID else {
                return nil
            }
            guard let revision = head.full else {
                throw TractandaError("recoveryError", "Access configuration head is incomplete.")
            }
            return revision
        }
    }

    private static func residentHead(_ revision: Revision) -> ResidentHead {
        let needsSemanticFields =
            revision.classID == "PersonalStateItem"
            || revision.classID == AccessConfiguration.classID
            || revision.fields["selection"] != nil || revision.fields["categoryParents"] != nil
        return ResidentHead(revision, evictContent: !needsSemanticFields)
    }
    private var isCanonicalReady = false
    var isCanonicalTrusted: Bool { isCanonicalReady }
    private(set) var canonicalVerificationStatus: [String: Any] = ["state": "pending"]
    // Failure injection at the file/index boundary, available to core tests only.
    var beforeIndexUpdate: (() throws -> Void)?
    var beforeCheckpointClear: (() throws -> Void)?
    var beforeCanonicalDurabilitySync: (() throws -> Void)?
    var publishResultOverrideForTesting: Int32?
    var beforeCategoryGraphValidation: (() -> Void)?
    var beforeCategoryOverlayScan: (() -> Void)?
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
            let entries = try POSIXDirectory.entries(at: indexDirectory).filter {
                $0 != Self.indexLockName && $0 != Self.indexBindingName
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
                guard entries.isEmpty else {
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
        guard head.classID != AccessConfiguration.classID,
            let context = accessContext, let account = context.account,
            let value = head.fields["permissions"]
        else { return false }
        return (try? ItemPermissions(value).allows(4, for: account, using: context.resolver)) == true
    }

    private func canRead(_ head: ResidentHead) -> Bool {
        head.canRead(accessContext, administrator: isAdministrator)
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
        let matches = (operationIDs[id] ?? []).compactMap { key -> String? in
            guard let separator = key.firstIndex(of: "\0"), let revisionID = operations[key] else {
                return nil
            }
            let actor = String(key[..<separator])
            if actor == "uid:\(uid)", uid == ownerUID { return revisionID }
            if actor.hasPrefix("uid:"), let legacyUID = UInt32(actor.dropFirst(4)),
                let legacyUser = accessConfiguration?.legacyUsers[legacyUID], let context = accessContext
            {
                // Preserve receipt bytes and old actor identity, but only replay after an
                // explicit canonical mapping resolves to this caller on this request.
                return (try? context.resolver.userID(legacyUser)) == uid ? revisionID : nil
            }
            guard actor.hasPrefix("user:"), let context = accessContext else { return nil }
            return (try? context.resolver.userID(String(actor.dropFirst(5)))) == uid ? revisionID : nil
        }
        guard matches.count <= 1 else {
            throw TractandaError("operationMismatch", "Aliases merge conflicting operation receipts.")
        }
        guard let revisionID = matches.first else { return nil }
        guard let location = revisionLocations[revisionID], let current = heads[location.itemID] else {
            throw TractandaError("recoveryError", "Operation receipt points to an unavailable revision.")
        }
        guard canRead(current) else { throw TractandaError("forbidden", "Item access is denied.") }
        return try loadRevision(revisionID)
    }

    public func configureAccess(_ value: ItemValue, operationID: String) throws -> CommitResult {
        try requireAdministrator()
        let previous = heads.values.first { $0.classID == AccessConfiguration.classID }?.full
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
        try categoryOverrideIndex().decision(for: item, categoryID: categoryID)
    }

    /// Build once for a category evaluation, then resolve owners only for overlays
    /// targeting each candidate item. The snapshot follows this request's current ACL context.
    func categoryOverrideIndex() -> CategoryOverrideIndex {
        beforeCategoryOverlayScan?()
        let uid = accessContext?.uid ?? ownerUID
        let resolver =
            accessContext?.resolver
            ?? PrincipalResolver(directory: accounts, configuration: accessConfiguration)
        var overlaysByTargetID: [String: [Revision]] = [:]
        for record in heads.values.compactMap(\.full)
        where record.classID == "PersonalStateItem" && !record.isDeleted
            && canRead(record)
        {
            guard let targetID = record.fields["target"]?.link?.itemID else { continue }
            overlaysByTargetID[targetID, default: []].append(record)
        }
        return CategoryOverrideIndex(overlaysByTargetID: overlaysByTargetID, uid: uid, resolver: resolver)
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
            let rows = try? candidate.catalogue(identity: identity), !rows.isEmpty
        else {
            candidate.close()
            return false
        }
        var locations: [String: RevisionLocation] = [:]
        var grouped: [String: [ItemIndex.CatalogueRow]] = [:]
        var operationMap: [String: String] = [:]
        var operationIDsByName: [String: [String]] = [:]
        var paths = Set<String>()
        for row in rows {
            guard (try? Identifier.validate(row.revisionID)) != nil,
                (try? Identifier.validate(row.itemID)) != nil,
                row.size <= 8 * 1024 * 1024, !row.actor.isEmpty, !row.operationID.isEmpty,
                !row.path.hasPrefix("/"), !row.path.split(separator: "/").contains(".."),
                Self.validCanonicalRecordPath(row.path, itemID: row.itemID, revisionID: row.revisionID),
                paths.insert(row.path).inserted, locations[row.revisionID] == nil
            else {
                candidate.close()
                return false
            }
            let url = root.appendingPathComponent(row.path).standardizedFileURL
            let itemsRoot = root.appendingPathComponent("items")
            guard url.path.hasPrefix(itemsRoot.path + "/") else {
                candidate.close()
                return false
            }
            // Historical paths and file metadata are catalogued here without lstat/read. The
            // bounded background verifier can compare them after startup; only heads are touched now.
            let metadata = FileMetadata(
                mode: row.mode, uid: row.uid, gid: 0, size: row.size, inode: row.inode,
                device: 0, modificationSeconds: row.modificationSeconds,
                modificationNanoseconds: row.modificationNanoseconds)
            locations[row.revisionID] = RevisionLocation(
                itemID: row.itemID, relativePath: row.path, actor: row.actor, operationID: row.operationID,
                parentID: row.parentID, metadata: metadata, digest: row.digest)
            grouped[row.itemID, default: []].append(row)
            let key = operationKey(actor: row.actor, id: row.operationID)
            guard operationMap[key] == nil else {
                candidate.close()
                return false
            }
            operationMap[key] = row.revisionID
            operationIDsByName[row.operationID, default: []].append(key)
        }
        var recoveredHeads: [String: ResidentHead] = [:]
        var headIDs: [String: String] = [:]
        for (itemID, versions) in grouped {
            let roots = versions.filter { $0.parentID == nil }
            guard roots.count == 1 else {
                candidate.close()
                return false
            }
            var successors: [String: String] = [:]
            for row in versions {
                if let parent = row.parentID {
                    guard locations[parent]?.itemID == itemID, successors[parent] == nil else {
                        candidate.close()
                        return false
                    }
                    successors[parent] = row.revisionID
                }
            }
            var current = roots[0].revisionID
            var seen: Set<String> = [current]
            while let next = successors[current] {
                guard seen.insert(next).inserted else {
                    candidate.close()
                    return false
                }
                current = next
            }
            guard seen.count == versions.count, let location = locations[current] else {
                candidate.close()
                return false
            }
            let headMetadata: FileMetadata
            let locationURL = location.url(root: root)
            do { headMetadata = try FileMetadata.read(at: locationURL) } catch {
                candidate.close()
                return false
            }
            let archivedHead = tractanda_path_read_only(locationURL.path) == 1
            guard headMetadata.type == .regular, headMetadata.size == location.metadata.size,
                headMetadata.inode == location.metadata.inode,
                headMetadata.uid == location.metadata.uid, headMetadata.mode == location.metadata.mode,
                headMetadata.modificationSeconds == location.metadata.modificationSeconds,
                headMetadata.modificationNanoseconds == location.metadata.modificationNanoseconds,
                archivedHead || (headMetadata.uid == ownerUID && headMetadata.mode & 0o077 == 0)
            else {
                candidate.close()
                return false
            }
            var ancestor = locationURL.deletingLastPathComponent()
            let itemsRoot = root.appendingPathComponent("items")
            while ancestor.path != itemsRoot.path {
                guard ancestor.path.hasPrefix(itemsRoot.path + "/") else {
                    candidate.close()
                    return false
                }
                let directoryMetadata: FileMetadata
                do { directoryMetadata = try FileMetadata.read(at: ancestor) } catch {
                    candidate.close()
                    return false
                }
                let archivedDirectory = tractanda_path_read_only(ancestor.path) == 1
                guard directoryMetadata.type == .directory,
                    archivedDirectory
                        || (directoryMetadata.uid == ownerUID && directoryMetadata.mode & 0o077 == 0)
                else {
                    candidate.close()
                    return false
                }
                ancestor.deleteLastPathComponent()
            }
            let revision: Revision
            do {
                let bytes = try Data(contentsOf: locationURL)
                guard Data(SHA256.hash(data: bytes)) == location.digest else {
                    candidate.close()
                    return false
                }
                revision = try RecordCodec.decode(bytes)
                try ItemSemantics.validate(revision)
            } catch {
                candidate.close()
                return false
            }
            guard revision.itemID == itemID, revision.revisionID == current,
                revision.supersedes == location.parentID,
                revision.fields["actor"]?.string == location.actor,
                revision.fields["operationID"]?.string == location.operationID
            else {
                candidate.close()
                return false
            }
            recoveredHeads[itemID] = Self.residentHead(revision)
            headIDs[itemID] = current
            guard try candidate.textMatches(revision) else {
                candidate.close()
                return false
            }
        }
        do {
            _ = try CategoryHierarchy(
                recoveredHeads.values.compactMap(\.full).filter {
                    $0.fields["selection"] != nil || $0.fields["categoryParents"] != nil
                })
            guard try candidate.catalogueMatchesHeads(headIDs) else {
                candidate.close()
                return false
            }
            revisionLocations = locations
            heads = recoveredHeads
            operations = operationMap
            operationIDs = operationIDsByName
            accessConfiguration = try configuration(in: recoveredHeads.values.compactMap(\.full))
            isCanonicalReady = true
            clockDependentCategories = recoveredHeads.values.compactMap(\.full)
                .contains(where: Self.categoryUsesClock)
            clearSavedViewPages()
            index = candidate
            return true
        } catch {
            candidate.close()
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

    func verificationSnapshot() throws -> (CanonicalVerifier.Snapshot, String) {
        guard isCanonicalReady else {
            throw TractandaError("recoveryRequired", "Resolve canonical recovery errors before verification.")
        }
        let rows = revisionLocations.map { $0.value.catalogueRow(revisionID: $0.key) }
        return (CanonicalVerifier.Snapshot(rootPath: root.path, ownerUID: ownerUID, rows: rows), generation)
    }

    /// Reconcile an asynchronous scan on the store queue. A stale scan finding is ignored only
    /// after the current catalogue and current bytes establish that the path is now consistent.
    func applyVerification(_ findings: [CanonicalVerifier.Finding], scannedGeneration: String) throws {
        // Canonical record names carry their immutable revision ID. Resolve only findings;
        // a clean background scan no longer copies the entire catalogue on this queue.
        func currentRow(for path: String) -> ItemIndex.CatalogueRow? {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            guard filename.hasSuffix(".tractanda") else { return nil }
            let revisionID = String(filename.dropLast(".tractanda".count))
            guard let location = revisionLocations[revisionID] else { return nil }
            let row = location.catalogueRow(revisionID: revisionID)
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
                "findingCount": confirmed.count,
                "findings": confirmed.prefix(100).map {
                    [
                        "kind": $0.kind.rawValue, "path": $0.path,
                        "detail": $0.detail,
                    ]
                },
            ]
            isCanonicalReady = false
            index?.close()
            index = nil
            do {
                try StoreCheckpoint.markDirty(root: root)
            } catch let markerFailure {
                // The SQLite catalogue is disposable. Removing it provides a second durable
                // fail-closed signal if the canonical-root marker cannot be written.
                do {
                    for suffix in ["", "-wal", "-shm", "-journal"] {
                        let url = indexDirectory.appendingPathComponent("items.sqlite" + suffix)
                        if FileManager.default.fileExists(atPath: url.path) {
                            try FileManager.default.removeItem(at: url)
                        }
                    }
                    try StoreCheckpoint.syncDirectory(indexDirectory)
                    canonicalVerificationStatus["checkpointFallback"] = "disposable catalogue removed"
                } catch let invalidationFailure {
                    canonicalVerificationStatus["markerError"] =
                        "\(markerFailure); catalogue invalidation failed: \(invalidationFailure)"
                    throw invalidationFailure
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

    private func recover(measurePhases: Bool = false) throws -> RecoveryPhaseMetrics? {
        let folder = root.appendingPathComponent("items")
        let enumerationStart = measurePhases ? ProcessInfo.processInfo.systemUptime : 0
        var versionsByItem: [String: [String: RecoveryRevision]] = [:]
        var revisionIDsWithSuccessors = Set<String>()
        var bodyCandidatesByItem: [String: Revision] = [:]
        var locations: [String: RevisionLocation] = [:]
        var recordReadDecodeSeconds: TimeInterval = 0
        var recordReadSeconds: TimeInterval = 0
        var recordDecodeSeconds: TimeInterval = 0
        var recordHashSeconds: TimeInterval = 0
        var semanticValidationSeconds: TimeInterval = 0
        var directories = [folder]
        while let directory = directories.popLast() {
            let names: [String]
            do {
                names = try POSIXDirectory.entries(at: directory)
            } catch {
                throw TractandaError("recoveryError", "Cannot enumerate canonical records: \(error)")
            }
            for name in names {
                let url = directory.appendingPathComponent(name, isDirectory: false)
                let metadata = try FileMetadata.read(at: url)
                let isArchived = tractanda_path_read_only(url.path) == 1
                if metadata.type == .directory {
                    guard isArchived || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0) else {
                        throw TractandaError(
                            "recoveryError", "Unexpected type, ownership or permissions: \(url.path)")
                    }
                    if !isArchived { try ensureDirectory(url) }
                    directories.append(url)
                    continue
                }
                guard metadata.type == .regular,
                    isArchived
                        || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0)
                else {
                    throw TractandaError(
                        "recoveryError", "Unexpected type, ownership or permissions: \(url.path)")
                }
                if url.pathExtension != "tractanda" {
                    // A crashed publication can leave its uniquely named staging file.
                    let parts = url.lastPathComponent.components(separatedBy: ".tractanda.")
                    if parts.count == 2, UUID(uuidString: parts[0]) != nil,
                        parts[1].count == 6,
                        parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
                    {
                        recoveryWarnings.append("Unpublished staging file retained: \(url.lastPathComponent)")
                        continue
                    }
                    throw TractandaError(
                        "recoveryError", "Unrecognized file in canonical item tree: \(url.path)")
                }
                guard metadata.size <= 8 * 1024 * 1024 else {
                    throw TractandaError("recoveryError", "Record exceeds the prototype size limit.")
                }
                let r: Revision
                let recordData: Data
                let recordDigest: Data
                do {
                    let started = measurePhases ? ProcessInfo.processInfo.systemUptime : 0
                    let readStarted = started
                    recordData = try Data(contentsOf: url)
                    if measurePhases {
                        let readEnded = ProcessInfo.processInfo.systemUptime
                        recordReadSeconds += readEnded - readStarted
                    }
                    let decodeStarted = measurePhases ? ProcessInfo.processInfo.systemUptime : 0
                    r = try RecordCodec.decode(recordData)
                    if measurePhases {
                        let decodeEnded = ProcessInfo.processInfo.systemUptime
                        recordDecodeSeconds += decodeEnded - decodeStarted
                    }
                    let hashStarted = measurePhases ? ProcessInfo.processInfo.systemUptime : 0
                    recordDigest = Data(SHA256.hash(data: recordData))
                    if measurePhases {
                        let hashEnded = ProcessInfo.processInfo.systemUptime
                        recordHashSeconds += hashEnded - hashStarted
                        recordReadDecodeSeconds += hashEnded - started
                    }
                } catch { throw TractandaError("recoveryError", "\(url.path): \(error)") }
                do {
                    let started = measurePhases ? ProcessInfo.processInfo.systemUptime : 0
                    try ItemSemantics.validate(r)
                    if measurePhases {
                        semanticValidationSeconds += ProcessInfo.processInfo.systemUptime - started
                    }
                } catch { throw TractandaError("recoveryError", "\(url.path): \(error)") }
                guard url.deletingPathExtension().lastPathComponent == r.revisionID,
                    locations[r.revisionID] == nil
                else {
                    throw TractandaError(
                        "recoveryError", "Duplicate revision or filename/record identity mismatch.")
                }
                if let parent = r.supersedes {
                    revisionIDsWithSuccessors.insert(parent)
                    if bodyCandidatesByItem[r.itemID]?.revisionID == parent {
                        bodyCandidatesByItem.removeValue(forKey: r.itemID)
                    }
                }
                // A revision with any observed successor cannot be the head. This retains at
                // most one leaf body per item while handling children read before their parents.
                if !revisionIDsWithSuccessors.contains(r.revisionID) {
                    bodyCandidatesByItem[r.itemID] = r
                }
                locations[r.revisionID] = RevisionLocation(
                    itemID: r.itemID,
                    relativePath: String(url.path.dropFirst(root.path.count + 1)),
                    actor: r.fields["actor"]!.string!,
                    operationID: r.fields["operationID"]!.string!, parentID: r.supersedes,
                    metadata: metadata, digest: recordDigest)
                let feedback = r.fields["learningFeedback"]?.map?.values.map { $0 } ?? []
                versionsByItem[r.itemID, default: [:]][r.revisionID] = RecoveryRevision(
                    revisionID: r.revisionID, itemID: r.itemID,
                    createdAt: r.fields["createdAt"]!, supersedes: r.supersedes,
                    actor: r.fields["actor"]!.string!, operationID: r.fields["operationID"]!.string!,
                    feedback: feedback, contentDigest: recordDigest)
            }
        }
        let enumerationEnd = measurePhases ? ProcessInfo.processInfo.systemUptime : 0
        let chainStart = enumerationEnd
        var headRevisionIDs: [String: String] = [:]
        var recoveredOperations: [String: String] = [:]
        var recoveredOperationIDs: [String: [String]] = [:]
        for (itemID, versions) in versionsByItem {
            var successors: [String: String] = [:]
            let roots = versions.values.filter { $0.supersedes == nil }
            guard roots.count == 1 else {
                throw TractandaError("recoveryError", "An item must have exactly one initial revision.")
            }
            for version in versions.values {
                guard version.createdAt == roots[0].createdAt else {
                    throw TractandaError(
                        "recoveryError", "An item's creation time changed between revisions.")
                }
                if let parent = version.supersedes {
                    guard locations[parent]?.itemID == itemID, successors[parent] == nil else {
                        throw TractandaError(
                            "recoveryError", "Missing predecessor, cross-item link or competing revisions.")
                    }
                    successors[parent] = version.revisionID
                }
                let key = operationKey(actor: version.actor, id: version.operationID)
                guard recoveredOperations[key] == nil else {
                    throw TractandaError("recoveryError", "Operation ID reused in canonical records.")
                }
                recoveredOperations[key] = version.revisionID
                recoveredOperationIDs[version.operationID, default: []].append(key)
            }
            var current = roots[0].revisionID
            var seen: Set<String> = [current]
            func validateFeedback(_ version: RecoveryRevision, ancestors: Set<String>) throws {
                for value in version.feedback {
                    let feedback = try LearningFeedback(value)
                    guard ancestors.contains(feedback.revisionID) else {
                        throw TractandaError(
                            "recoveryError",
                            "Learning feedback must refer to an earlier revision of the same item.")
                    }
                }
            }
            try validateFeedback(roots[0], ancestors: [])
            while let nextID = successors[current] {
                guard let next = versions[nextID] else {
                    throw TractandaError("recoveryError", "Missing revision in canonical chain.")
                }
                try validateFeedback(next, ancestors: seen)
                guard seen.insert(next.revisionID).inserted else {
                    throw TractandaError("recoveryError", "Revision cycle.")
                }
                current = next.revisionID
            }
            guard seen.count == versions.count else {
                throw TractandaError("recoveryError", "Disconnected revision chain.")
            }
            headRevisionIDs[itemID] = current
        }
        let chainEnd = measurePhases ? ProcessInfo.processInfo.systemUptime : 0
        let finalizationStart = chainEnd
        var recoveredHeads: [String: Revision] = [:]
        for (itemID, revisionID) in headRevisionIDs {
            var revision = bodyCandidatesByItem.removeValue(forKey: itemID)
            if revision?.revisionID != revisionID { revision = nil }
            if revision == nil, let location = locations[revisionID], location.itemID == itemID {
                let locationURL = location.url(root: root)
                do {
                    let metadata = try FileMetadata.read(at: locationURL)
                    let isArchived = tractanda_path_read_only(locationURL.path) == 1
                    guard metadata.type == .regular, metadata.size <= 8 * 1024 * 1024,
                        isArchived || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0)
                    else {
                        throw TractandaError(
                            "recoveryError", "Current revision permissions changed during recovery.")
                    }
                    let bytes = try Data(contentsOf: locationURL)
                    let decoded = try RecordCodec.decode(bytes)
                    try ItemSemantics.validate(decoded)
                    guard let expected = versionsByItem[itemID]?[revisionID],
                        Data(SHA256.hash(data: bytes)) == expected.contentDigest,
                        locationURL.deletingPathExtension().lastPathComponent == decoded.revisionID,
                        decoded.revisionID == revisionID, decoded.itemID == itemID
                    else {
                        throw TractandaError("recoveryError", "Current revision changed during recovery.")
                    }
                    revision = decoded
                } catch { throw TractandaError("recoveryError", "\(locationURL.path): \(error)") }
            }
            guard let revision, revision.revisionID == revisionID, revision.itemID == itemID else {
                throw TractandaError(
                    "recoveryError", "Current revision body is missing or has changed identity.")
            }
            recoveredHeads[itemID] = revision
        }
        revisionLocations = locations
        historicalCache.removeAll(keepingCapacity: true)
        historicalOrder.removeAll(keepingCapacity: true)
        historicalCacheBytes = 0
        _ = try CategoryHierarchy(Array(recoveredHeads.values))
        heads = recoveredHeads.mapValues(Self.residentHead)
        clockDependentCategories = recoveredHeads.values.contains(where: Self.categoryUsesClock)
        clearSavedViewPages()
        operations = recoveredOperations
        operationIDs = recoveredOperationIDs
        accessConfiguration = try configuration(in: Array(recoveredHeads.values))
        isCanonicalReady = true
        let finalizationEnd = measurePhases ? ProcessInfo.processInfo.systemUptime : 0
        guard measurePhases else { return nil }
        return RecoveryPhaseMetrics(
            enumerationStart: enumerationStart, enumerationEnd: enumerationEnd,
            chainStart: chainStart, chainEnd: chainEnd,
            finalizationStart: finalizationStart, finalizationEnd: finalizationEnd,
            recordReadDecodeSeconds: recordReadDecodeSeconds,
            recordReadSeconds: recordReadSeconds,
            recordDecodeSeconds: recordDecodeSeconds,
            recordHashSeconds: recordHashSeconds,
            semanticValidationSeconds: semanticValidationSeconds)
    }
    private static func categoryUsesClock(_ item: Revision) -> Bool {
        guard !item.isDeleted, let selection = item.fields["selection"]?.map else { return false }
        return selection["timeWindow"] != nil
            || selection["expression"]?.string?.contains("$time.") == true
    }
    private func loadRevision(_ revisionID: String) throws -> Revision? {
        guard let location = revisionLocations[revisionID] else { return nil }
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
        if let head = heads[revision.itemID], head.revisionID == revisionID, let full = head.full {
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
        guard let head = heads[itemID] else {
            throw TractandaError("notFound", "Item or revision is unavailable.")
        }
        guard canRead(head) else { throw TractandaError("forbidden", "Item access is denied.") }
        let revision: Revision?
        if let revisionID {
            guard revisionLocations[revisionID]?.itemID == itemID else {
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
            guard revisionLocations[previous]?.itemID == itemID, seen.insert(previous).inserted else {
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
    public func candidates(text: String? = nil, includeDeleted: Bool = false) throws -> [Revision] {
        try candidates(text: text, includeDeleted: includeDeleted, restrictedTo: nil)
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
        var ids: [String] = []
        var estimatedBytes = 0
        if !candidateRestrictions.isEmpty {
            guard let index,
                let selected = try index.boundedCandidateIDs(
                    restrictions: candidateRestrictions, maximumReadable: maximumCandidates,
                    accepts: { id in
                        guard let head = self.heads[id] else {
                            throw TractandaError("indexError", "Indexed candidate has no current head.")
                        }
                        return !head.isDeleted && self.canRead(head)
                    })
            else { return nil }
            ids = selected
            for id in ids {
                guard let head = heads[id], !head.isDeleted, canRead(head),
                    let location = revisionLocations[head.revisionID],
                    location.metadata.size <= UInt64(maximumSerializedBytes - estimatedBytes)
                else { return nil }
                estimatedBytes += Int(location.metadata.size)
            }
        } else {
            for id in heads.keys {
                guard let head = heads[id], !head.isDeleted, canRead(head) else { continue }
                guard ids.count < maximumCandidates,
                    let location = revisionLocations[head.revisionID],
                    location.metadata.size <= UInt64(maximumSerializedBytes - estimatedBytes)
                else { return nil }
                estimatedBytes += Int(location.metadata.size)
                ids.append(id)
            }
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
            guard let head = heads[revision.itemID], head.revisionID == revision.revisionID,
                canRead(head), let location = revisionLocations[revision.revisionID]
            else { return false }
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
    private func candidates(text: String?, includeDeleted: Bool, restrictedTo ids: Set<String>?) throws
        -> [Revision]
    {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        let visible = try index.ids(lexicalText: text, restrictingTo: ids).compactMap { id -> Revision? in
            guard let head = heads[id], includeDeleted || !head.isDeleted, canRead(head) else {
                return nil
            }
            return try currentRevision(id)
        }
        // Global FTS rank depends on hidden documents. Shared clients get stable ID ordering.
        return isMultiUser && !isAdministrator ? visible.sorted { $0.itemID < $1.itemID } : visible
    }
    func readableCategoryHeads() -> [Revision] {
        heads.values.compactMap(\.full).filter {
            !$0.isDeleted && $0.fields["selection"] != nil && canRead($0)
        }
    }
    func hasLivePersonalStateItems() -> Bool {
        if let hasLivePersonalStateMemo { return hasLivePersonalStateMemo }
        let present = heads.values.contains { !$0.isDeleted && $0.classID == "PersonalStateItem" }
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
    func indexedPage(
        text: String?, classEquals: String?, order: ItemIndex.IndexedOrder,
        position: Int, limit: Int,
        exactIndexPredicate: Bool,
        needsFullRevision: Bool,
        candidateRestrictions: [SpotlightQuery.IndexCandidateRestriction] = [],
        accepts: (Revision) throws -> Bool
    ) throws -> ItemIndex.Page {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        return try index.orderedPage(
            lexicalText: text, classEquals: classEquals, order: order,
            position: position, limit: limit,
            fastCount: isAdministrator && exactIndexPredicate,
            candidateRestrictions: candidateRestrictions
        ) { id in
            guard let head = heads[id], !head.isDeleted, canRead(head) else { return false }
            guard needsFullRevision else { return true }
            guard let revision = try currentRevision(id) else { return false }
            return try accepts(revision)
        }
    }
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
        let key = operationKey(actor: actor, id: request.operationID)
        if let previous = try priorOperation(request.operationID, uid: uid) {
            guard let previousHead = heads[previous.itemID], canRead(previousHead) else {
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
        guard !isNew || (heads[itemID] == nil && revisionLocations[itemID] == nil),
            revisionLocations[revisionID] == nil, heads[revisionID] == nil, itemID != revisionID
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
            for head in heads.values where head.itemID != revision.itemID {
                if let value = head.fields["permissions"] {
                    try ItemPermissions(value).validate(using: resolver)
                }
            }
        }
        if revision.classID == "PersonalStateItem", let target = revision.fields["target"]?.link {
            _ = try get(target.itemID, revisionID: target.revisionID)
            if let owner = revision.fields["permissions"]?.map?["owner"]?.string {
                let ownerUID = try context.resolver.userID(owner)
                for other in heads.values
                where other.itemID != revision.itemID && !other.isDeleted
                    && other.classID == "PersonalStateItem"
                    && other.fields["target"]?.link?.itemID == target.itemID
                {
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
        revisionLocations[revision.revisionID] = RevisionLocation(
            itemID: revision.itemID,
            relativePath: String(publishedURL.path.dropFirst(root.path.count + 1)), actor: actor,
            operationID: request.operationID, parentID: revision.supersedes,
            metadata: publishedMetadata, digest: Data(SHA256.hash(data: data)))
        heads[revision.itemID] = Self.residentHead(revision)
        hasLivePersonalStateMemo = nil
        operations[key] = revision.revisionID
        operationIDs[request.operationID, default: []].append(key)
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
        if Self.categoryUsesClock(revision) || base.map(Self.categoryUsesClock) == true {
            clockDependentCategories = heads.values.compactMap(\.full).contains(where: Self.categoryUsesClock)
        }
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
                try index.upsertCatalogue(
                    revisionLocations[revision.revisionID]!.catalogueRow(
                        revisionID: revision.revisionID))
                try index.execute("COMMIT")
                try index.checkpoint(path: indexDirectory.appendingPathComponent("items.sqlite").path)
            } catch {
                try? index.execute("ROLLBACK")
                throw error
            }
        } catch {
            index?.close()
            index = nil
            warnings.append("Committed to files; index update failed. Rebuild before querying.")
        }
        if index != nil, directoryDurabilityConfirmed, !markerPreviouslyDirty {
            do {
                try beforeCheckpointClear?()
                try StoreCheckpoint.clear(root: root)
            } catch {
                warnings.append("Committed; checkpoint marker remains and startup will recover fully.")
            }
        }
        return CommitResult(
            revision: revision, wasReplayed: false, isIndexReady: index != nil, warnings: warnings)
    }

    public func rebuildIndex() throws {
        try requireAdministrator()
        let priorVerificationState = canonicalVerificationStatus["state"] as? String
        let priorFindingCount = canonicalVerificationStatus["findingCount"] as? Int ?? 0
        // A caller may request this after an offline restore. If the process stops before the
        // replacement catalogue is durable, the previous clean catalogue must not be reused.
        try StoreCheckpoint.markDirty(root: root)
        index?.close()
        index = nil
        hasLivePersonalStateMemo = nil
        isCanonicalReady = false
        recoveryWarnings = []
        let measureStartup = ProcessInfo.processInfo.environment["TRACTANDA_STARTUP_METRICS"] == "1"
        let recoveryStarted = ProcessInfo.processInfo.systemUptime
        let recoveryPhases = try recover(measurePhases: measureStartup)
        let recoveryEnded = ProcessInfo.processInfo.systemUptime
        try syncCanonicalForCheckpoint()
        let temporary = indexDirectory.appendingPathComponent("rebuild-\(Identifier.make()).sqlite")
        let destination = indexDirectory.appendingPathComponent("items.sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fresh = try ItemIndex(path: temporary.path, create: true)
        let insertStarted = ProcessInfo.processInfo.systemUptime
        try fresh.execute("BEGIN IMMEDIATE")
        let statements = try fresh.makeRebuildStatements()
        defer { statements.close() }
        // Keep the full canonical working set to one verified head at a time. The
        // serialized-byte cache remains bounded while the transaction builds rows.
        for id in heads.keys {
            guard let revision = try currentRevision(id) else {
                throw TractandaError("recoveryError", "Current head is unavailable during rebuild.")
            }
            try fresh.putForRebuild(revision, using: statements)
        }
        let identity = try canonicalStoreIdentity(creatingIfMissing: false)
        try fresh.replaceCatalogue(
            identity: identity,
            rows: revisionLocations.lazy.map { $0.value.catalogueRow(revisionID: $0.key) })
        let insertEnded = ProcessInfo.processInfo.systemUptime
        let commitStarted = ProcessInfo.processInfo.systemUptime
        try fresh.execute("COMMIT")
        let commitEnded = ProcessInfo.processInfo.systemUptime
        statements.close()
        fresh.close()
        index?.close()
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
        try index?.checkpoint(path: destination.path)
        try StoreCheckpoint.syncDirectory(indexDirectory)
        if StoreCheckpoint.isDirty(root: root) { try StoreCheckpoint.clear(root: root) }
        let publicationEnded = ProcessInfo.processInfo.systemUptime
        generation = Identifier.make()
        scopedStates.removeAll()
        canonicalVerificationStatus = [
            "state": "rebuilt", "completedAt": ISO8601DateFormatter().string(from: Date()),
            "recoveredRecordCount": revisionLocations.count,
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
                "headCount": self.heads.count,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys]),
                let line = String(data: data, encoding: .utf8)
            {
                FileHandle.standardError.write(Data(("TRACTANDA_STARTUP_METRICS " + line + "\n").utf8))
            }
        }
    }

    /// A full rebuild may follow uncertain publication or an explicit offline restore. Validate
    /// and synchronize writable canonical bytes and ancestor entries before sealing a clean
    /// checkpoint. Read-only archive paths retain their existing recovery exemption.
    private func syncCanonicalForCheckpoint() throws {
        try beforeCanonicalDurabilitySync?()
        var directories: Set<URL> = [root, root.appendingPathComponent("items")]
        for location in revisionLocations.values {
            let locationURL = location.url(root: root)
            if tractanda_path_read_only(locationURL.path) != 1 {
                let descriptor = open(locationURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else {
                    throw TractandaError("recoveryError", "Cannot open canonical record for synchronization.")
                }
                let result = fsync(descriptor)
                _ = close(descriptor)
                guard result == 0 else {
                    throw TractandaError("recoveryError", "Cannot synchronize canonical record.")
                }
            }
            var directory = locationURL.deletingLastPathComponent()
            while directory.path.hasPrefix(root.path + "/") {
                directories.insert(directory)
                directory.deleteLastPathComponent()
            }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count })
        where tractanda_path_read_only(directory.path) != 1 {
            try StoreCheckpoint.syncDirectory(directory)
        }
    }
}
