import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Local scheduling only. Current membership and pairing credentials are separate host-private
/// configuration. An old authority runtime document can never select the personal gateway.
public struct PersonalPeerRuntimeConfiguration: Codable, Equatable, Sendable {
    public static let profileName = "tractanda.personal-runtime.v1"
    public let profile: String
    public let settings: PeerRuntimeConfiguration
    public init(settings: PeerRuntimeConfiguration) throws {
        self.profile = Self.profileName
        self.settings = settings
        try validate()
    }
    /// Explicit local routing overrides do not alter the shared membership document.
    package static func configuredPeers(
        membership: PersonalMembershipConfiguration, localReplicaID: String, port: Int,
        endpointOverrides: [String: [PeerRuntimeConfiguration.Endpoint]] = [:]
    ) throws -> [PeerRuntimeConfiguration.Peer] {
        try membership.validate()
        let remote = membership.members.filter { $0.replicaID != localReplicaID }
        guard membership.members.contains(where: { $0.replicaID == localReplicaID }),
            Set(endpointOverrides.keys).isSubset(of: Set(remote.map(\.replicaID)))
        else {
            throw TractandaError("invalidConfiguration", "Routing overrides require current remote members.")
        }
        let peers = try remote.map { member in
            let endpoints =
                try endpointOverrides[member.replicaID]
                ?? [PeerRuntimeConfiguration.Endpoint(host: member.hostname, port: port)]
            guard let first = endpoints.first else {
                throw TractandaError(
                    "invalidConfiguration", "A routing override requires at least one destination.")
            }
            return try PeerRuntimeConfiguration.Peer(
                alias: member.replicaID + "-dial", host: first.host, port: first.port,
                fallbackEndpoints: Array(endpoints.dropFirst()))
        }
        _ = try Self(settings: PeerRuntimeConfiguration(peers: peers))
        return peers
    }
    public func validate() throws {
        guard profile == Self.profileName else {
            throw TractandaError("invalidConfiguration", "Unsupported personal peer runtime profile.")
        }
        for peer in settings.peers {
            // DNS is resolved anew for every reconnect. Literal addresses are not durable
            // membership destinations; listener addresses may still be wildcard/loopback.
            for endpoint in peer.endpoints {
                let host = endpoint.host
                guard !PeerRuntimeConfiguration.Endpoint.isNumericAddress(host),
                    !host.contains(":"), host.contains(where: { $0.isLetter }),
                    !host.hasPrefix("["), !host.hasSuffix("]")
                else {
                    throw TractandaError(
                        "invalidConfiguration", "Personal peers require configured hostnames.")
                }
            }
        }
    }
    public static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= PeerRuntimeConfiguration.maximumFileBytes else {
            throw TractandaError("resourceLimit", "Personal runtime configuration exceeds its byte bound.")
        }
        let object = try JSONSerialization.jsonObject(with: bytes)
        guard let fields = object as? [String: Any], Set(fields.keys) == ["profile", "settings"] else {
            throw TractandaError("invalidConfiguration", "Expected an explicit personal runtime document.")
        }
        let value = try JSON.decode(Self.self, bytes)
        try value.validate()
        return value
    }
    public func encoded() throws -> Data {
        try validate()
        let bytes = try JSON.encode(self)
        guard bytes.count <= PeerRuntimeConfiguration.maximumFileBytes else {
            throw TractandaError("resourceLimit", "Personal runtime configuration exceeds its byte bound.")
        }
        return bytes
    }
    package static func load(root: URL, ownerUID: UInt32) throws -> Self? {
        var found: Self?
        for name in [".peer-runtime.json", "peer-runtime.json"] {
            if let bytes = try CanonicalReaderRequirement.localConfigurationBytes(
                root: root, name: name, ownerUID: ownerUID,
                maximumBytes: PeerRuntimeConfiguration.maximumFileBytes)
            {
                let next = try decode(bytes)
                guard found == nil else {
                    throw TractandaError("invalidConfiguration", "Conflicting personal runtime files.")
                }
                found = next
            }
        }
        return found
    }
}

/// Explicit local pairing-file workflow. Secrets remain in protected binary files and are
/// consumed by the existing TLS credential adapter, never printed as ordinary service JSON.
package enum PersonalPairingFiles {
    package static func create(
        configuration: PersonalMembershipConfiguration, leftReplicaID: String, rightReplicaID: String,
        leftDirectory: URL, rightDirectory: URL
    ) throws {
        try configuration.validate()
        let members = Set(configuration.members.map(\.replicaID))
        guard leftReplicaID != rightReplicaID, members.contains(leftReplicaID),
            members.contains(rightReplicaID),
            leftDirectory != rightDirectory
        else {
            throw TractandaError(
                "invalidPeerCredential", "Pairing endpoints must be distinct proposed members.")
        }
        var directoryIdentities: [(UInt64, UInt64)] = []
        for directory in [leftDirectory, rightDirectory] {
            let checked = try PeerPrivateCredentialInput.checkedPath(directory.path)
            let descriptor = checked.withCString { tractanda_open_private_directory($0) }
            guard descriptor >= 0 else {
                throw TractandaError(
                    "invalidPeerCredential", "Use separate empty private pairing directories.")
            }
            defer { tractanda_close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw TractandaError(
                    "invalidPeerCredential", "Cannot inspect private pairing directory custody.")
            }
            var occupied = false
            try POSIXDirectory.withEntries(descriptor: descriptor) { _ in
                occupied = true
                return false
            }
            let identity = (UInt64(metadata.st_dev), UInt64(metadata.st_ino))
            guard !occupied,
                !directoryIdentities.contains(where: { $0.0 == identity.0 && $0.1 == identity.1 })
            else {
                throw TractandaError(
                    "invalidPeerCredential", "Use separate empty private pairing directories.")
            }
            directoryIdentities.append(identity)
        }
        let digest = try configuration.digest
        var random = SystemRandomNumberGenerator()
        for (initiator, responder, initiatingDirectory, respondingDirectory) in [
            (leftReplicaID, rightReplicaID, leftDirectory, rightDirectory),
            (rightReplicaID, leftReplicaID, rightDirectory, leftDirectory),
        ] {
            let pairing = try UUID.makeVersion1().uuidString.lowercased()
            let secret = (0..<32).map { _ in UInt8.random(in: 0...255, using: &random) }
            for (local, remote, role, directory) in [
                (initiator, responder, true, initiatingDirectory),
                (responder, initiator, false, respondingDirectory),
            ] {
                let alias = remote + (role ? "-dial" : "-accept")
                let credential = try PeerCredential(
                    binding: PeerExchangeBinding(
                        peerID: alias, storeID: configuration.storeID, localReplicaID: local,
                        remoteReplicaID: remote, pairingID: pairing, localIsInitiator: role,
                        configurationDigest: digest), secret: secret)
                try PeerEnrollmentFiles.writeExact(
                    credential.privateEncodedBytes(),
                    path: directory.appendingPathComponent(alias + ".credential").path,
                    maximum: PeerCredentialStore.maximumBytes)
            }
        }
    }
    package static func register(
        store: ItemStore, paths: [String], configuration: PersonalMembershipConfiguration, actorUID: UInt32
    ) throws {
        guard !paths.isEmpty, paths.count <= 512 else {
            throw TractandaError("resourceLimit", "Use one bounded private credential set.")
        }
        let credentials = try paths.map { path in
            try PeerPrivateCredentialInput.capture(path: path).withBytes { try PeerCredential.decode($0) }
        }
        try store.registerPersonalPeerCredentials(
            credentials, configuration: configuration, actorUID: actorUID)
    }
}

/// Maps a small disjoint personal protocol onto the single Store owner. The wire cannot
/// select historical authority operations, a filesystem path, an actor UID or a baseline.
package enum PersonalPeerBridge {
    package static func perform(store: ItemStore, binding: PeerExchangeBinding, request: PeerExchangeRequest)
        throws -> Data
    {
        let fields = request.fields
        if request.operation == "personal.membership.ready" {
            try exact(fields, ["preparation"])
            let preparation = try JSON.decode(
                PersonalMembershipPreparation.self, bytes(fields, "preparation"))
            return try JSON.encode(store.personalMembershipReady(session: binding, preparation: preparation))
        }
        if request.operation == "personal.sync.ready" {
            try exact(fields, [])
            try store.validatePersonalPeerBinding(binding, controlOnly: true)
            let ready = (try? store.validatePersonalPeerBinding(binding)) != nil
            return try JSON.encode(["ready": ready])
        }
        try store.validatePersonalPeerBinding(binding)
        switch request.operation {
        case "personal.inventory":
            try exact(
                fields, ["offset", "limit"], optional: ["snapshotID", "knownGeneration", "afterRowID"])
            let offset = try integer(fields, "offset")
            let limit = try integer(fields, "limit", minimum: 1, maximum: 128)
            if let snapshot = fields["snapshotID"] {
                guard case .text(let id) = snapshot, fields["knownGeneration"] == nil,
                    fields["afterRowID"] == nil
                else { throw invalid() }
                return try JSON.encode(
                    store.continuePersonalInventory(
                        session: binding, snapshotID: id, offset: offset, pageSize: limit))
            }
            guard offset == 0 else { throw invalid() }
            let after: Int64
            if let value = fields["afterRowID"] {
                guard case .integer(let number) = value, number >= 0 else { throw invalid() }
                after = number
            } else {
                after = 0
            }
            return try JSON.encode(
                store.capturePersonalInventory(
                    session: binding, pageSize: limit,
                    knownGeneration: optionalText(fields, "knownGeneration"), afterRowID: after))
        case "personal.inventory.close":
            try exact(fields, ["snapshotID"])
            try store.closePersonalInventory(session: binding, snapshotID: text(fields, "snapshotID"))
            return try JSON.encode(["closed": true])
        case "personal.dependencies":
            try exact(fields, ["descriptor", "offset", "limit"])
            return try JSON.encode(
                store.personalDependencies(
                    session: binding, descriptor: descriptor(fields),
                    offset: integer(fields, "offset"),
                    limit: integer(fields, "limit", minimum: 1, maximum: 128)))
        case "personal.read":
            try exact(fields, ["descriptor", "offset", "limit"])
            return try store.readPersonalObject(
                session: binding, descriptor: descriptor(fields), offset: offset(fields),
                limit: integer(fields, "limit", minimum: 1, maximum: 262_144))
        case "personal.prepare":
            try exact(fields, ["descriptor"])
            return try JSON.encode(
                store.preparePersonalObject(session: binding, descriptor: descriptor(fields)))
        case "personal.append":
            try exact(fields, ["descriptor", "offset", "bytes"])
            let data = try bytes(fields, "bytes")
            guard data.count <= 262_144 else { throw invalid() }
            return try JSON.encode(
                store.appendPersonalObject(
                    session: binding, descriptor: descriptor(fields), offset: offset(fields), data: data))
        case "personal.finish":
            try exact(fields, ["descriptor"])
            return try JSON.encode(
                store.finishPersonalObject(session: binding, descriptor: descriptor(fields)))
        case "personal.apply":
            try exact(fields, ["descriptor"])
            return try JSON.encode(
                store.applyPersonalRevision(session: binding, descriptor: descriptor(fields)))
        default: throw TractandaError("unsupportedPeerOperation", "Unknown personal peer operation.")
        }
    }
    package static func local(store: ItemStore, request: PeerExchangeRequest, uid: UInt32) throws -> Data {
        let fields = request.fields
        switch request.operation {
        case "identity":
            try exact(fields, [])
            return try JSON.encode(store.personalSyncIdentity())
        case "membership.prepare":
            try exact(fields, ["configuration"], optional: ["expectedDigest", "nonce", "readmission"])
            let config = try JSON.decode(PersonalMembershipConfiguration.self, bytes(fields, "configuration"))
            let expected = try optionalText(fields, "expectedDigest")
            let nonce = try optionalText(fields, "nonce")
            let readmission: Bool
            if let value = fields["readmission"] {
                guard case .boolean(let flag) = value else { throw invalid() }
                readmission = flag
            } else {
                readmission = false
            }
            return try JSON.encode(
                store.preparePersonalMembershipChange(
                    configuration: config, expectedDigest: expected,
                    nonce: nonce, readmission: readmission, actorUID: uid))
        case "credentials.register":
            try exact(fields, ["configuration", "paths"])
            let config = try JSON.decode(PersonalMembershipConfiguration.self, bytes(fields, "configuration"))
            guard case .list(let raw) = fields["paths"], !raw.isEmpty, raw.count <= 512 else {
                throw invalid()
            }
            let paths = try raw.map { value -> String in
                guard case .text(let path) = value else { throw invalid() }
                return path
            }
            try PersonalPairingFiles.register(
                store: store, paths: paths, configuration: config, actorUID: uid)
            return try JSON.encode(["registered": paths.count])
        case "baseline.begin":
            try exact(fields, ["sourceReplicaID"])
            return try JSON.encode([
                "selectionID": store.startPersonalBaseline(
                    sourceReplicaID: text(fields, "sourceReplicaID"), actorUID: uid)
            ])
        case "baseline.finish":
            try exact(fields, ["selectionID"])
            try store.finishPersonalBaseline(selectionID: text(fields, "selectionID"), actorUID: uid)
            return try JSON.encode(["finished": true])
        default:
            throw TractandaError(
                "unsupportedPeerOperation", "Unknown native personal peer administration operation.")
        }
    }
    private static func descriptor(_ fields: [String: ItemValue]) throws -> PersonalObjectDescriptor {
        let value = try JSON.decode(PersonalObjectDescriptor.self, bytes(fields, "descriptor"))
        try value.validate()
        return value
    }
    private static func exact(
        _ fields: [String: ItemValue], _ required: Set<String>, optional: Set<String> = []
    ) throws {
        guard required.isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: required.union(optional))
        else { throw invalid() }
    }
    private static func text(_ fields: [String: ItemValue], _ key: String) throws -> String {
        guard case .text(let value) = fields[key], value.utf8.count <= 4096 else { throw invalid() }
        return value
    }
    private static func optionalText(_ fields: [String: ItemValue], _ key: String) throws -> String? {
        try fields[key] == nil ? nil : text(fields, key)
    }
    private static func bytes(_ fields: [String: ItemValue], _ key: String) throws -> Data {
        guard case .bytes(let value) = fields[key], value.count <= 262_144 else { throw invalid() }
        return value
    }
    private static func offset(_ fields: [String: ItemValue]) throws -> Int64 {
        guard case .integer(let value) = fields["offset"], value >= 0 else { throw invalid() }
        return value
    }
    private static func integer(
        _ fields: [String: ItemValue], _ key: String, minimum: Int = 0, maximum: Int = Int.max
    ) throws -> Int {
        guard case .integer(let value) = fields[key], let number = Int(exactly: value),
            (minimum...maximum).contains(number)
        else { throw invalid() }
        return number
    }
    private static func invalid() -> TractandaError {
        TractandaError("invalidArguments", "Invalid bounded personal peer request fields.")
    }
}

extension ItemStore {
    func personalPeerCanonicalStatus() throws -> PeerCanonicalStatus {
        try requireAdministrator()
        guard let profile = try PersonalWorkgroupProfile.load(root, ownerUID: ownerUID),
            profile.replicaID == replicaID
        else { throw TractandaError("recoveryRequired", "Local personal identity is unavailable.") }
        let membership = try PersonalSyncConfiguration.membership(root: root, ownerUID: ownerUID)
        let pending = try PersonalSyncConfiguration.read(
            PersonalMembershipPreparation.self, root: root,
            name: PersonalSyncConfiguration.pendingName, ownerUID: ownerUID)
        let baseline = try PersonalSyncConfiguration.read(
            PersonalBaselineSelection.self, root: root,
            name: PersonalSyncConfiguration.baselineName, ownerUID: ownerUID)
        let personal = try PersonalClusterCanonicalStatus(
            storeID: profile.storeID, currentMembership: membership,
            pendingMembership: pending?.configuration,
            requiredOnlineReplicaIDs: pending?.requiredOnlineReplicaIDs ?? [],
            baselineSourceReplicaID: baseline?.sourceReplicaID)
        return .init(
            storeID: profile.storeID, replicaID: profile.replicaID,
            readiness: !isCanonicalTrusted
                ? .recoveryRequired
                : (baseline != nil || isPersonalBaselinePending) ? .pendingActivation : .ready,
            localDisposed: nil, configuredPairingCount: nil, committedPairingCount: nil,
            personal: personal)
    }
}

extension ItemStore {
    /// Explicit managed adoption of a personal factory-created replica. This selects exact
    /// existing identities/custody and never asks an obsolete authority ledger for admission.
    package static func verifyPersonalSyncReplicaIdentityForSetup(
        root: URL, ownerUID: UInt32, expectedStoreID: String, expectedReplicaID: String
    ) throws {
        try PersonalSyncValidation.identifier(expectedStoreID)
        try PersonalSyncValidation.identifier(expectedReplicaID)
        guard expectedStoreID != expectedReplicaID else {
            throw TractandaError("invalidEnrollmentTarget", "Store and replica pins must differ.")
        }
        try verifyPersonalWorkgroupRoot(root: root, ownerUID: ownerUID)
        guard let profile = try PersonalWorkgroupProfile.load(root, ownerUID: ownerUID),
            ["freshReplica", "freshReplicaJoining"].contains(profile.initialization),
            profile.storeID == expectedStoreID,
            profile.replicaID == expectedReplicaID
        else {
            throw TractandaError(
                "invalidEnrollmentTarget",
                "Expected the selected fresh personal replica and exact identity pins.")
        }
        var selected: [PersonalMembershipConfiguration] = []
        if let current = try PersonalSyncConfiguration.membership(root: root, ownerUID: ownerUID) {
            selected.append(current)
        }
        if let pending = try PersonalSyncConfiguration.read(
            PersonalMembershipPreparation.self,
            root: root, name: PersonalSyncConfiguration.pendingName, ownerUID: ownerUID)
        {
            selected.append(pending.configuration)
        }
        for membership in selected {
            try membership.validate()
            guard membership.storeID == expectedStoreID,
                membership.members.contains(where: { $0.replicaID == expectedReplicaID })
            else {
                throw TractandaError(
                    "invalidEnrollmentTarget",
                    "Current or explicitly prepared membership has different replica pins.")
            }
        }
    }
    package static func verifyPersonalSyncReplicaForSetup(
        root: URL, indexDirectory: URL, expectedStoreID: String, expectedReplicaID: String
    ) throws {
        try verifyPersonalSyncReplicaIdentityForSetup(
            root: root, ownerUID: tractanda_uid(),
            expectedStoreID: expectedStoreID, expectedReplicaID: expectedReplicaID)
        let store = try openInitialized(root: root, indexDirectory: indexDirectory)
        let identity = try store.personalSyncIdentity()
        guard identity.storeID == expectedStoreID, identity.replicaID == expectedReplicaID else {
            throw TractandaError(
                "invalidEnrollmentTarget", "Personal initialized opening changed the selected pins.")
        }
        try withExtendedLifetime(store) {
            try verifyPersonalSyncReplicaIdentityForSetup(
                root: root, ownerUID: tractanda_uid(),
                expectedStoreID: expectedStoreID, expectedReplicaID: expectedReplicaID)
        }
    }
    /// Exact interrupted new-target Setup only. No writer/open or implicit promotion;
    /// an already admitted/enrolled or populated target is never resumed as fresh.
    package static func verifyUnjoinedPersonalSyncReplicaIdentityForSetup(
        root: URL, ownerUID: UInt32, expectedStoreID: String, expectedReplicaID: String
    ) throws {
        try verifyPersonalSyncReplicaIdentityForSetup(
            root: root, ownerUID: ownerUID,
            expectedStoreID: expectedStoreID, expectedReplicaID: expectedReplicaID)
        guard let profile = try PersonalWorkgroupProfile.load(root, ownerUID: ownerUID),
            profile.initialization == "freshReplicaJoining",
            try PersonalSyncConfiguration.membership(root: root, ownerUID: ownerUID) == nil,
            try PersonalSyncConfiguration.read(
                PersonalMembershipPreparation.self, root: root,
                name: PersonalSyncConfiguration.pendingName, ownerUID: ownerUID) == nil,
            try PersonalSyncConfiguration.read(
                PersonalBaselineSelection.self, root: root,
                name: PersonalSyncConfiguration.baselineName, ownerUID: ownerUID) == nil
        else {
            throw TractandaError(
                "invalidEnrollmentTarget",
                "The interrupted target is already selected or enrolled; use its existing join/resume command."
            )
        }
        try POSIXDirectory.withEntries(at: root) { name in
            guard name != ".personal-enrollment", name != ".peer-credentials",
                !name.hasPrefix(".personal-credentials-")
            else {
                throw TractandaError(
                    "invalidEnrollmentTarget",
                    "The target already has enrollment or credential state; use its existing join/resume command."
                )
            }
            return true
        }
        let inventory = try PersonalRecoveryInventory.inspect([.init(root: root, ownerUID: ownerUID)])
        guard inventory.isStructurallyComplete, inventory.records.isEmpty else {
            throw TractandaError(
                "invalidEnrollmentTarget",
                "The interrupted target contains history; it was not adopted or changed.")
        }
    }
}

package struct PersonalDependencyWorkFrame: Codable, Sendable {
    package enum Phase: String, Codable, Sendable { case bytes, dependencies, finish }
    package let descriptor: PersonalObjectDescriptor
    package var phase: Phase = .dependencies
    package var dependencyOffset = 0
    package init(descriptor: PersonalObjectDescriptor) { self.descriptor = descriptor }
}
package enum PersonalDependencyWorkOperation: Sendable {
    case peek
    case push(PersonalDependencyWorkFrame)
    case replace(PersonalDependencyWorkFrame)
    case pop, close
}

/// Disposable private DFS frames. Only the current frame is loaded; no growing ancestry or
/// completed-history set is retained in memory. A lost handle is safely replaced by a rescan.
package final class PersonalDependencyWorkStack: @unchecked Sendable, CustomStringConvertible {
    let owner: UUID
    let generation: UInt64
    let binding: PeerExchangeBinding
    private let files: DocumentContentFiles
    private let id: String
    private let maximumBytes: Int64
    private var storedBytes: Int64 = 0
    private var depth: Int64 = 0
    private var closed = false
    private var mayHaveOrphan = false
    private let lock = NSLock()
    package var description: String { "PersonalDependencyWorkStack(<private>)" }
    init(store: ItemStore, binding: PeerExchangeBinding, owner: UUID, generation: UInt64) throws {
        self.owner = owner
        self.generation = generation
        self.binding = binding
        id = try UUID.makeVersion1().uuidString.lowercased()
        let environment = ProcessInfo.processInfo.environment
        let text = environment["TRACTANDA_PERSONAL_PEER_WORK_BYTES"] ?? "268435456"
        guard let budget = Int64(text), budget >= 262_144 else {
            throw TractandaError(
                "invalidConfiguration", "Personal dependency work budget must be at least256KiB.")
        }
        maximumBytes = budget
        files = DocumentContentFiles(
            root: store.root, ownerUID: store.ownerUID,
            minimumFreeBytes: max(10 * 1024 * 1024 * 1024, store.attachmentUploadPolicy.minimumFreeBytes))
    }
    /// Called once under the new Store lifetime writer, before any personal jobs exist.
    static func removeOrphans(store: ItemStore) throws {
        let files = DocumentContentFiles(
            root: store.root, ownerUID: store.ownerUID,
            minimumFreeBytes: max(10 * 1024 * 1024 * 1024, store.attachmentUploadPolicy.minimumFreeBytes))
        try files.withDirectoryEntries(path: [".personal-sync", "work"]) { name in
            if isOwnedWorkName(name) { try files.removePersonalSyncWorkFile(name) }
            return true
        }
    }
    private static func isOwnedWorkName(_ name: String) -> Bool {
        if name.hasPrefix(".metadata-"), name.utf8.count == 46,
            UUID(uuidString: String(name.dropFirst(10))) != nil
        {
            return true
        }
        guard name.hasSuffix(".json"), name.count > 43 else { return false }
        let prefix = String(name.prefix(36))
        guard let identity = UUID(uuidString: prefix), identity.version1Components != nil,
            identity.uuidString.lowercased() == prefix
        else { return false }
        let suffix = String(name.dropFirst(36).dropLast(5))
        if suffix.hasPrefix("-frame-") {
            let value = String(suffix.dropFirst(7))
            return Int64(value).map { $0 > 0 && String($0) == value } ?? false
        }
        if suffix.hasPrefix("-active-") {
            let digest = String(suffix.dropFirst(8))
            return digest.utf8.count == 64
                && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return false
    }
    func requireOwner(_ candidate: UUID) throws {
        guard candidate == owner else {
            throw TractandaError("serviceClosed", "Dependency work belongs to another Store owner.")
        }
    }
    private func frameName(_ level: Int64) -> String { id + "-frame-" + String(level) + ".json" }
    private func activeName(_ descriptor: PersonalObjectDescriptor) throws -> String {
        id + "-active-" + (try descriptor.key) + ".json"
    }
    private func read() throws -> PersonalDependencyWorkFrame? {
        guard depth > 0 else { return nil }
        guard
            let bytes = try files.readIfPresent(
                path: [".personal-sync", "work", frameName(depth)], maximumBytes: 131_072)
        else {
            throw TractandaError(
                "inventoryExpired", "Disposable dependency work was lost; rescan the finite inventory.")
        }
        return try JSON.decode(PersonalDependencyWorkFrame.self, bytes)
    }
    func perform(_ operation: PersonalDependencyWorkOperation) throws -> PersonalDependencyWorkFrame? {
        lock.lock()
        defer { lock.unlock() }
        if case .close = operation {
            while depth > 0 { try pop() }
            if mayHaveOrphan {
                try files.withDirectoryEntries(path: [".personal-sync", "work"]) { name in
                    if name.hasPrefix(id + "-"), Self.isOwnedWorkName(name) {
                        try files.removePersonalSyncWorkFile(name)
                    }
                    return true
                }
            }
            closed = true
            return nil
        }
        guard !closed else { throw TractandaError("inventoryExpired", "Dependency work is closed; rescan.") }
        switch operation {
        case .peek: return try read()
        case .push(let frame):
            try frame.descriptor.validate()
            let active = try activeName(frame.descriptor)
            guard
                try files.readIfPresent(path: [".personal-sync", "work", active], maximumBytes: 131_072)
                    == nil
            else {
                throw TractandaError(
                    "invalidRevisionGraph", "A dependency repeats on its active ancestry path.")
            }
            let bytes = try JSON.encode(frame)
            guard depth < Int64.max, Int64(bytes.count * 2) <= maximumBytes - storedBytes else {
                throw TractandaError(
                    "resourceLimit", "Dependency work exceeds its configured temporary byte budget.")
            }
            try files.replacePersonalSyncMetadata(
                bytes, path: [".personal-sync", "work", frameName(depth + 1)])
            do {
                try files.replacePersonalSyncMetadata(bytes, path: [".personal-sync", "work", active])
            } catch {
                do { try files.removePersonalSyncWorkFile(frameName(depth + 1)) } catch {
                    mayHaveOrphan = true
                }
                throw error
            }
            depth += 1
            storedBytes += Int64(bytes.count * 2)
            return frame
        case .replace(let frame):
            guard let previous = try read(), previous.descriptor == frame.descriptor else {
                throw TractandaError("inventoryExpired", "Dependency frame identity changed.")
            }
            let previousBytes = try JSON.encode(previous).count
            let bytes = try JSON.encode(frame)
            let delta = Int64(bytes.count - previousBytes)
            guard delta <= maximumBytes - storedBytes else {
                throw TractandaError(
                    "resourceLimit", "Dependency checkpoint exceeds its temporary byte budget.")
            }
            try files.replacePersonalSyncMetadata(bytes, path: [".personal-sync", "work", frameName(depth)])
            storedBytes += delta
            return frame
        case .pop:
            try pop()
            return try read()
        case .close: return nil
        }
    }
    private func pop() throws {
        guard let frame = try read() else { return }
        let currentBytes = try JSON.encode(frame).count
        let active = try activeName(frame.descriptor)
        let activeBytes =
            try files.readIfPresent(path: [".personal-sync", "work", active], maximumBytes: 131_072)?.count
            ?? 0
        try files.removePersonalSyncWorkFile(active)
        try files.removePersonalSyncWorkFile(frameName(depth))
        storedBytes = max(0, storedBytes - Int64(currentBytes + activeBytes))
        depth -= 1
    }
}

package struct PersonalPeerSyncCursor: Codable, Sendable {
    let storeID: String
    let localReplicaID: String
    let remoteReplicaID: String
    let configurationDigest: String
    package let localGenerationID: String
    package var remoteGenerationID: String?
    package var consumedRowID: Int64
}

extension PersonalPeerBridge {
    private static func cursorName(_ binding: PeerExchangeBinding) throws -> String {
        try PersonalSyncValidation.digest(
            JSON.encode([
                binding.storeID, binding.localReplicaID,
                binding.remoteReplicaID, binding.configurationDigest,
            ])) + ".json"
    }
    static func loadCursor(store: ItemStore, binding: PeerExchangeBinding) throws -> PersonalPeerSyncCursor {
        try store.validatePersonalPeerBinding(binding)
        let generation = try store.personalCatalogueGeneration()
        let files = DocumentContentFiles(
            root: store.root, ownerUID: store.ownerUID,
            minimumFreeBytes: max(10 * 1024 * 1024 * 1024, store.attachmentUploadPolicy.minimumFreeBytes))
        if let bytes = try files.readIfPresent(
            path: [".personal-sync", "cursors", cursorName(binding)], maximumBytes: 8192)
        {
            if let cursor = try? JSON.decode(PersonalPeerSyncCursor.self, bytes),
                cursor.storeID == binding.storeID, cursor.localReplicaID == binding.localReplicaID,
                cursor.remoteReplicaID == binding.remoteReplicaID,
                cursor.configurationDigest == binding.configurationDigest,
                cursor.localGenerationID == generation, cursor.consumedRowID >= 0,
                cursor.remoteGenerationID.map({ !$0.isEmpty && $0.utf8.count <= 200 }) == true
            {
                return cursor
            }
        }
        return .init(
            storeID: binding.storeID, localReplicaID: binding.localReplicaID,
            remoteReplicaID: binding.remoteReplicaID, configurationDigest: binding.configurationDigest,
            localGenerationID: generation, remoteGenerationID: nil, consumedRowID: 0)
    }
    static func saveCursor(_ cursor: PersonalPeerSyncCursor, store: ItemStore, binding: PeerExchangeBinding)
        throws
    {
        try store.validatePersonalPeerBinding(binding)
        guard cursor.storeID == binding.storeID, cursor.localReplicaID == binding.localReplicaID,
            cursor.remoteReplicaID == binding.remoteReplicaID,
            cursor.configurationDigest == binding.configurationDigest,
            cursor.localGenerationID == (try store.personalCatalogueGeneration()), cursor.consumedRowID >= 0,
            cursor.remoteGenerationID.map({ !$0.isEmpty && $0.utf8.count <= 200 }) == true
        else {
            throw TractandaError(
                "inventoryExpired", "Local catalogue changed during synchronization; rescan.")
        }
        let files = DocumentContentFiles(
            root: store.root, ownerUID: store.ownerUID,
            minimumFreeBytes: max(10 * 1024 * 1024 * 1024, store.attachmentUploadPolicy.minimumFreeBytes))
        try files.replacePersonalSyncMetadata(
            JSON.encode(cursor), path: [".personal-sync", "cursors", cursorName(binding)])
    }
}
