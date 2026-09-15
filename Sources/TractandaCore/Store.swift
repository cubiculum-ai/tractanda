import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

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
    public var isMultiUser: Bool { accessConfiguration != nil }
    /// Internal maintenance has no client context and remains privileged. Client contexts
    /// carry the policy result evaluated from a fresh OS account snapshot.
    public var isAdministrator: Bool { accessContext == nil || accessContext?.isAdministrator == true }
    public var accessScope: String {
        guard isMultiUser else { return "single-user" }
        return accessContext?.account.map { "user:\($0.name)" } ?? "service"
    }
    /// A private edit must not change another caller's synchronization token.
    public var state: String {
        guard !isAdministrator, let context = accessContext else { return generation }
        let fingerprint =
            heads.values.filter(canRead).map(\.revisionID).sorted().joined(separator: "/")
            + ":" + (context.account?.groupIDs.sorted().map(String.init).joined(separator: ",") ?? "")
        if let previous = scopedStates[accessScope], previous.fingerprint == fingerprint {
            return previous.token
        }
        if scopedStates.count >= 256 { scopedStates.removeAll() }
        let token = Identifier.make()
        scopedStates[accessScope] = (fingerprint, token)
        return token
    }
    public private(set) var recoveryWarnings: [String] = []
    private var writer: Int32 = -1
    private var indexWriter: Int32 = -1
    private let usesExternalIndexDirectory: Bool
    private var index: ItemIndex?
    private var revisions: [String: Revision] = [:]
    private var heads: [String: Revision] = [:]
    private var operations: [String: Revision] = [:]
    private var isCanonicalReady = false
    // Failure injection at the file/index boundary, available to core tests only.
    var beforeIndexUpdate: (() throws -> Void)?
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
            if usesExternalIndexDirectory { try bindExternalIndexDirectory() }
            try rebuildIndex()
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
        let canonicalDevice: UInt64
        let canonicalInode: UInt64

        func identifiesSameStore(as other: Self) -> Bool {
            formatVersion == other.formatVersion && canonicalDevice == other.canonicalDevice
                && canonicalInode == other.canonicalInode
        }
    }

    private static let indexBindingName = ".tractanda-index-binding.json"
    private static let indexLockName = ".tractanda-index.writer.lock"

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
            let binding = IndexBinding(
                formatVersion: 1, canonicalPath: root.path, canonicalDevice: rootMetadata.device,
                canonicalInode: rootMetadata.inode)
            if FileManager.default.fileExists(atPath: markerURL.path) {
                try PrivateConfiguration.validate(markerURL, directory: false)
                let existing = try JSON.decode(IndexBinding.self, Data(contentsOf: markerURL))
                guard existing.identifiesSameStore(as: binding) else {
                    throw TractandaError(
                        "indexBindingMismatch", "Derived index directory belongs to another canonical store.")
                }
            } else {
                guard entries.isEmpty else {
                    throw TractandaError(
                        "indexBindingRequired", "Refusing an unbound nonempty derived index directory.")
                }
                try PrivateConfiguration.write(try JSON.encode(binding), to: markerURL)
            }
        } catch {
            tractanda_unlock(indexWriter)
            indexWriter = -1
            throw error
        }
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
        let matches = operations.values.filter { revision in
            guard revision.fields["operationID"]?.string == id,
                let actor = revision.fields["actor"]?.string
            else { return false }
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
        guard matches.count <= 1 else {
            throw TractandaError("operationMismatch", "Aliases merge conflicting operation receipts.")
        }
        return matches.first
    }

    public func configureAccess(_ value: ItemValue, operationID: String) throws -> CommitResult {
        try requireAdministrator()
        let previous = heads.values.first { $0.classID == AccessConfiguration.classID }
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
        let uid = accessContext?.uid ?? ownerUID
        let resolver =
            accessContext?.resolver
            ?? PrincipalResolver(directory: accounts, configuration: accessConfiguration)
        let overlays = try heads.values.filter { record in
            guard record.classID == "PersonalStateItem", !record.isDeleted, canRead(record),
                record.fields["target"]?.link?.itemID == item.itemID,
                let owner = record.fields["permissions"]?.map?["owner"]?.string
            else { return false }
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

    // Convenience operations may skip current-state checks on a retry. commit still
    // verifies the complete immutable intent and the caller's authority before replaying it.
    func hasCommittedOperation(_ id: String, actorUID: UInt32) -> Bool {
        (try? priorOperation(id, uid: actorUID)) != nil
    }

    private func recover() throws {
        let folder = root.appendingPathComponent("items")
        var loaded: [String: Revision] = [:]
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
                do {
                    r = try RecordCodec.decode(Data(contentsOf: url))
                    try ItemSemantics.validate(r)
                } catch { throw TractandaError("recoveryError", "\(url.path): \(error)") }
                guard url.deletingPathExtension().lastPathComponent == r.revisionID,
                    loaded[r.revisionID] == nil
                else {
                    throw TractandaError(
                        "recoveryError", "Duplicate revision or filename/record identity mismatch.")
                }
                loaded[r.revisionID] = r
            }
        }
        var recoveredHeads: [String: Revision] = [:]
        var recoveredOperations: [String: Revision] = [:]
        for (itemID, versions) in Dictionary(grouping: loaded.values, by: \.itemID) {
            var successors: [String: Revision] = [:]
            let roots = versions.filter { $0.supersedes == nil }
            guard roots.count == 1 else {
                throw TractandaError("recoveryError", "An item must have exactly one initial revision.")
            }
            for version in versions {
                guard version.fields["createdAt"] == roots[0].fields["createdAt"] else {
                    throw TractandaError(
                        "recoveryError", "An item's creation time changed between revisions.")
                }
                if let parent = version.supersedes {
                    guard loaded[parent]?.itemID == itemID, successors[parent] == nil else {
                        throw TractandaError(
                            "recoveryError", "Missing predecessor, cross-item link or competing revisions.")
                    }
                    successors[parent] = version
                }
                let key = operationKey(
                    actor: version.fields["actor"]!.string!, id: version.fields["operationID"]!.string!)
                guard recoveredOperations[key] == nil else {
                    throw TractandaError("recoveryError", "Operation ID reused in canonical records.")
                }
                recoveredOperations[key] = version
            }
            var current = roots[0]
            var seen: Set<String> = [current.revisionID]
            func validateFeedback(_ version: Revision, ancestors: Set<String>) throws {
                for value in version.fields["learningFeedback"]?.map?.values ?? [:].values {
                    let feedback = try LearningFeedback(value)
                    guard ancestors.contains(feedback.revisionID) else {
                        throw TractandaError(
                            "recoveryError",
                            "Learning feedback must refer to an earlier revision of the same item.")
                    }
                }
            }
            try validateFeedback(current, ancestors: [])
            while let next = successors[current.revisionID] {
                try validateFeedback(next, ancestors: seen)
                guard seen.insert(next.revisionID).inserted else {
                    throw TractandaError("recoveryError", "Revision cycle.")
                }
                current = next
            }
            guard seen.count == versions.count else {
                throw TractandaError("recoveryError", "Disconnected revision chain.")
            }
            recoveredHeads[itemID] = current
        }
        revisions = loaded
        _ = try CategoryHierarchy(Array(recoveredHeads.values))
        heads = recoveredHeads
        operations = recoveredOperations
        accessConfiguration = try configuration(in: Array(heads.values))
        isCanonicalReady = true
    }

    public func get(_ itemID: String, revisionID: String? = nil) throws -> Revision {
        guard isCanonicalReady else {
            throw TractandaError(
                "recoveryRequired", "Resolve canonical recovery errors before reading or writing.")
        }
        try Identifier.validate(itemID)
        let revision = revisionID.flatMap { revisions[$0] } ?? (revisionID == nil ? heads[itemID] : nil)
        guard let revision, revision.itemID == itemID else {
            throw TractandaError("notFound", "Item or revision is unavailable.")
        }
        try requireRead(heads[itemID]!)
        return revision
    }
    public func history(_ itemID: String) throws -> [Revision] {
        var current = try get(itemID)
        var result = [current]
        while let previous = current.supersedes {
            current = revisions[previous]!
            result.append(current)
        }
        return result
    }
    public func candidates(text: String? = nil, includeDeleted: Bool = false) throws -> [Revision] {
        guard let index else {
            throw TractandaError("indexUnavailable", "Rebuild the disposable index before querying.")
        }
        let visible = try index.ids(lexicalText: text).compactMap { heads[$0] }.filter {
            (includeDeleted || !$0.isDeleted) && canRead($0)
        }
        // Global FTS rank depends on hidden documents. Shared clients get stable ID ordering.
        return isMultiUser && !isAdministrator ? visible.sorted { $0.itemID < $1.itemID } : visible
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
            try requireRead(heads[previous.itemID]!)
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
        guard !isNew || (heads[itemID] == nil && revisions[itemID] == nil),
            revisions[revisionID] == nil, heads[revisionID] == nil, itemID != revisionID
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
        if base?.fields["categoryParents"] != revision.fields["categoryParents"]
            || base?.fields["selection"] != revision.fields["selection"]
            || base?.isDeleted != revision.isDeleted
        {
            _ = try CategoryHierarchy(heads.values.filter { $0.itemID != revision.itemID } + [revision])
        }
        var updatedConfiguration = accessConfiguration
        if isConfiguration {
            updatedConfiguration = try configuration(
                in: heads.values.filter { $0.itemID != revision.itemID } + [revision])
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
            guard revisions[feedback.revisionID]?.itemID == revision.itemID else {
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
        let published = data.withUnsafeBytes { tractanda_publish(path, $0.baseAddress, $0.count) }
        guard published >= 0 else {
            throw TractandaError(
                "writeFailed", "Revision publication failed: \(String(cString: strerror(errno)))")
        }
        revisions[revision.revisionID] = revision
        heads[revision.itemID] = revision
        operations[key] = revision
        accessConfiguration = updatedConfiguration
        if isConfiguration {
            accessContext = StoreAccessContext(
                uid: context.uid, account: context.account ?? (try? accounts.user(forUID: context.uid)),
                resolver: PrincipalResolver(directory: accounts, configuration: updatedConfiguration),
                isAdministrator: context.isAdministrator)
        }
        generation = Identifier.make()
        var warnings = published == 1 ? ["Committed; directory durability could not be confirmed."] : []
        // Persist the new date-directory entries as well as the leaf publication.
        // This is fsync-based durability; actual power-loss behavior still needs hardware testing.
        var directory = folder
        while directory.path.hasPrefix(root.path + "/") || directory == root {
            let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if descriptor < 0 || fsync(descriptor) != 0 {
                warnings.append("Committed; an ancestor directory could not be synchronized.")
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
                try index.execute("COMMIT")
            } catch {
                try? index.execute("ROLLBACK")
                throw error
            }
        } catch {
            index?.close()
            index = nil
            warnings.append("Committed to files; index update failed. Rebuild before querying.")
        }
        return CommitResult(
            revision: revision, wasReplayed: false, isIndexReady: index != nil, warnings: warnings)
    }

    public func rebuildIndex() throws {
        try requireAdministrator()
        index?.close()
        index = nil
        isCanonicalReady = false
        recoveryWarnings = []
        try recover()
        let temporary = indexDirectory.appendingPathComponent("rebuild-\(Identifier.make()).sqlite")
        let destination = indexDirectory.appendingPathComponent("items.sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fresh = try ItemIndex(path: temporary.path, create: true)
        try fresh.execute("BEGIN IMMEDIATE")
        for revision in heads.values { try fresh.put(revision) }
        try fresh.execute("COMMIT")
        fresh.close()
        index?.close()
        index = nil
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
        generation = Identifier.make()
        scopedStates.removeAll()
    }
}
