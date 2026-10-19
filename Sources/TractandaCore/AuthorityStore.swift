import Foundation

/// Shared Store/derived-index boundary. Locators identify one retained original; they confer no
/// eligibility. Controls and item history are rebuilt from sealed journal publications.
enum AuthorityStore {
    static let capability = "tractanda.authority.v1"
    enum Disposition: String, Codable, Sendable {
        case pending, eligible, held, rejected, missingDependencies, unknownOrigin
    }
    struct RetainedObject: Equatable, Sendable {
        let descriptor: PeerPackage.Object
        let path: String
        let packageID: String
        let peerID: String
        let configurationDigest: String
        let permittedOrigin: Bool
    }
    struct Evaluation: Sendable {
        let disposition: Disposition
        let reason: String
        var evidenceID: String? = nil
        var evidenceDigest: String? = nil
        var evidencePackageID: String? = nil
    }
    struct Result: Equatable, Sendable {
        let packageID: String
        let stored: Int
        let accepted: Int
        let held: Int
        let missing: Int
        var rejected: Int = 0
    }
    struct BootstrapPin: Codable, Equatable {
        let recordID: String
        let sha256: String
        let actor: String
    }
    struct InitialState: Codable {
        enum Mode: String, Codable { case empty, requiresBootstrap }
        let profile: String
        let storeID: String
        let replicaID: String
        let mode: Mode
    }
    private struct Capture: Codable {
        let profile: String
        let storeID: String
        let replicaID: String
    }
    struct LegacyReceiptProof: Codable {
        let profile: String
        let storeID: String
        let replicaID: String
        let revisionID: String
        let sha256: String
    }
    private static func savePrivate(_ bytes: Data, path: [String], files: DocumentContentFiles) throws {
        if let old = try files.readIfPresent(path: path, maximumBytes: 4096) {
            guard old == bytes else {
                throw TractandaError("invalidAuthority", "Private initialization proof changed.")
            }
        } else {
            try files.writeImmutable(bytes, path: path, maximumBytes: 4096)
        }
    }
    /// Initial authorization state is distinct from reader compatibility. The root writer
    /// captures it before any authority intake or new foreign file may exist.
    static func initialState(
        root: URL, storeID: String, ownerUID: UInt32, files: DocumentContentFiles,
        allocateReplica: () throws -> UUID = UUID.makeVersion1
    ) throws
        -> InitialState
    {
        let path = [".authority-initial-state.json"]
        let seal = [".authority-initial-state-sealed.json"]
        if let bytes = try files.readIfPresent(path: path, maximumBytes: 4096)
            ?? files.readIfPresent(path: seal, maximumBytes: 4096)
        {
            let value = try PeerPackage.decode(InitialState.self, bytes, maximum: 4096)
            guard value.profile == "tractanda.authority-initial-state.v1", value.storeID == storeID,
                let actualReplica = try ReplicaIdentity.load(
                    root: root, storeID: storeID, ownerUID: ownerUID),
                value.replicaID == actualReplica.replicaID
            else {
                throw TractandaError(
                    "invalidAuthority",
                    "Initial authority/replica proof is missing or belongs to another store.")
            }
            try savePrivate(bytes, path: path, files: files)
            try savePrivate(bytes, path: seal, files: files)
            return value
        }
        let capturePath = [".authority-initial-capture.json"]
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("authority").path),
            try files.readIfPresent(path: capturePath, maximumBytes: 4096) == nil
        {
            throw TractandaError(
                "invalidAuthority",
                "Missing initial proof cannot be reconstructed from later authority observations.")
        }
        let authorityDirectory = root.appendingPathComponent("authority")
        if FileManager.default.fileExists(atPath: authorityDirectory.path) {
            try POSIXDirectory.withEntries(at: authorityDirectory) { name in
                guard ["local-legacy-receipts", "initial-history"].contains(name) else {
                    throw TractandaError(
                        "invalidAuthority",
                        "Missing initial proof cannot be recreated after intake or publication.")
                }
                return true
            }
        }
        try CanonicalReaderRequirement.beforeAuthorityPublication(root: root, ownerUID: ownerUID)
        let hasModern =
            try CanonicalReaderRequirement.load(root: root, ownerUID: ownerUID)?.recordFormats.contains(2)
            == true
        let replica = try ReplicaIdentity.initialize(
            root: root, storeID: storeID, ownerUID: ownerUID, hasModernOrigins: hasModern,
            allocate: allocateReplica)
        let capture = Capture(
            profile: "tractanda.authority-capture.v1", storeID: storeID, replicaID: replica.replicaID)
        try savePrivate(try JSON.encode(capture), path: capturePath, files: files)
        var work = 0
        var found = false
        func walk(_ directory: URL, depth: Int) throws {
            guard depth <= 8 else {
                throw TractandaError("resourceLimit", "Initial inventory depth exceeded.")
            }
            try POSIXDirectory.withEntries(at: directory) { name in
                work += 1
                guard work <= 10_000_000 else {
                    throw TractandaError("resourceLimit", "Initial inventory work exceeded.")
                }
                let child = directory.appendingPathComponent(name)
                let before = try FileMetadata.read(at: child)
                if before.type == .directory {
                    try walk(child, depth: depth + 1)
                } else if before.type == .regular {
                    if name.hasSuffix(".tractanda") {
                        found = true
                        guard before.size <= 8 * 1024 * 1024 else {
                            throw TractandaError("resourceLimit", "Initial record too large.")
                        }
                        let data = try Data(contentsOf: child)
                        let revision = try RecordCodec.decode(data)
                        guard try FileMetadata.read(at: child) == before,
                            CanonicalRecordPath.validate(
                                String(child.path.dropFirst(root.path.count + 1)), itemID: revision.itemID,
                                revisionID: revision.revisionID)
                        else {
                            throw TractandaError(
                                "invalidAuthority", "Initial original changed during capture.")
                        }
                        let initial = LegacyReceiptProof(
                            profile: "tractanda.authority-initial-history.v1", storeID: storeID,
                            replicaID: replica.replicaID, revisionID: revision.revisionID,
                            sha256: AuthorityRecordCodec.sha256(data))
                        try savePrivate(
                            try JSON.encode(initial),
                            path: ["authority", "initial-history", revision.revisionID], files: files)
                        if revision.formatVersion == 1 {
                            let proof = LegacyReceiptProof(
                                profile: "tractanda.local-legacy-receipt.v1", storeID: storeID,
                                replicaID: replica.replicaID, revisionID: revision.revisionID,
                                sha256: AuthorityRecordCodec.sha256(data))
                            try savePrivate(
                                try JSON.encode(proof),
                                path: ["authority", "local-legacy-receipts", revision.revisionID],
                                files: files)
                        }
                    }
                } else {
                    throw TractandaError("invalidAuthority", "Unsafe initial canonical inventory.")
                }
                return true
            }
        }
        try walk(root.appendingPathComponent("items"), depth: 0)
        let state = InitialState(
            profile: "tractanda.authority-initial-state.v1", storeID: storeID,
            replicaID: replica.replicaID, mode: found ? .requiresBootstrap : .empty)
        let bytes = try JSON.encode(state)
        try savePrivate(bytes, path: path, files: files)
        try savePrivate(bytes, path: seal, files: files)
        return state
    }
    static func validateInitialHistory(
        root: URL, storeID: String, replicaID: String, files: DocumentContentFiles,
        eligible: (String, String) throws -> Bool
    ) throws {
        let directory = root.appendingPathComponent("authority/initial-history")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var work = 0
        try POSIXDirectory.withEntries(at: directory) { name in
            work += 1
            guard work <= 10_000_000 else {
                throw TractandaError("resourceLimit", "Initial cut coverage work exceeded.")
            }
            try Identifier.validate(name)
            let proof = try PeerPackage.decode(
                LegacyReceiptProof.self,
                files.read(path: ["authority", "initial-history", name], maximumBytes: 4096), maximum: 4096)
            guard proof.profile == "tractanda.authority-initial-history.v1", proof.storeID == storeID,
                proof.replicaID == replicaID, proof.revisionID == name, try eligible(name, proof.sha256)
            else {
                throw TractandaError(
                    "authorityBootstrapRequired", "The reviewed cut omits the original pre-intake inventory.")
            }
            return true
        }
    }
    static func isLocalLegacyReceipt(
        _ row: ItemIndex.CatalogueRow, root: URL, storeID: String,
        replicaID: String, files: DocumentContentFiles
    ) throws -> Bool {
        guard row.provenance == nil,
            let bytes = try files.readIfPresent(
                path: ["authority", "local-legacy-receipts", row.revisionID], maximumBytes: 4096)
        else { return false }
        let value = try PeerPackage.decode(LegacyReceiptProof.self, bytes, maximum: 4096)
        return value.profile == "tractanda.local-legacy-receipt.v1" && value.storeID == storeID
            && value.replicaID == replicaID && value.revisionID == row.revisionID
            && value.sha256 == row.digest.map { String(format: "%02x", $0) }.joined()
    }
    /// Distinguishes the original captured inventory from post-bootstrap authored seals.
    /// The sealed journal object/path and immutable capture proofs must all agree. This
    /// establishes only membership in the INITIAL inventory, never current eligibility.
    static func isInitialHistoryReceipt(
        _ row: RetainedObject, node: AuthorityRevision, publication: PeerIntakeJournal.Publication,
        root: URL, storeID: String, ownerUID: UInt32, files: DocumentContentFiles
    ) throws -> Bool {
        guard row.descriptor.kind == .item, row.peerID == "local",
            publication.context.peerID == "local", publication.context.storeID == storeID,
            row.packageID == publication.packageID,
            row.configurationDigest == publication.context.configurationDigest,
            publication.localItemPath == row.path,
            row.descriptor.id == node.revision.revisionID, row.descriptor.sha256 == node.sha256,
            row.descriptor.length == node.originalBytes.count,
            CanonicalRecordPath.validate(
                row.path, itemID: node.revision.itemID, revisionID: row.descriptor.id),
            let replica = try ReplicaIdentity.load(root: root, storeID: storeID, ownerUID: ownerUID),
            publication.context.permittedOrigins == [replica.replicaID],
            try node.revision.provenance?.originReplicaID == nil
                || node.revision.provenance?.originReplicaID == replica.replicaID,
            let captureBytes = try files.readIfPresent(
                path: [".authority-initial-capture.json"], maximumBytes: 4096),
            let stateBytes = try files.readIfPresent(
                path: [".authority-initial-state.json"], maximumBytes: 4096),
            let sealedState = try files.readIfPresent(
                path: [".authority-initial-state-sealed.json"], maximumBytes: 4096),
            stateBytes == sealedState,
            let proofBytes = try files.readIfPresent(
                path: ["authority", "initial-history", row.descriptor.id], maximumBytes: 4096)
        else { return false }
        let capture = try PeerPackage.decode(Capture.self, captureBytes, maximum: 4096)
        let state = try PeerPackage.decode(InitialState.self, stateBytes, maximum: 4096)
        let proof = try PeerPackage.decode(LegacyReceiptProof.self, proofBytes, maximum: 4096)
        return capture.profile == "tractanda.authority-capture.v1" && capture.storeID == storeID
            && capture.replicaID == replica.replicaID
            && state.profile == "tractanda.authority-initial-state.v1" && state.storeID == storeID
            && state.replicaID == replica.replicaID && state.mode == .requiresBootstrap
            && proof.profile == "tractanda.authority-initial-history.v1" && proof.storeID == storeID
            && proof.replicaID == replica.replicaID && proof.revisionID == row.descriptor.id
            && proof.sha256 == node.sha256
    }
    /// This is private host configuration, not replicated or accepted from package bytes.
    struct Configuration: Codable, Equatable {
        let profile: String
        let peers: [PeerPackage.Context]
        let bootstrap: BootstrapPin?
        var lifecycle: PeerLifecycle.State? = nil
        /// Non-secret exact TLS metadata commitments; private files alone cannot activate a pairing.
        var credentialBindings: [String: String]? = nil
        func validateCredentialBindings() throws {
            let bindings = credentialBindings ?? [:]
            guard bindings.count <= peers.count,
                Set(bindings.keys).isSubset(of: Set(peers.map(\.peerID)))
            else { throw TractandaError("invalidPeerConfiguration", "Invalid private credential bindings.") }
            for digest in bindings.values { _ = try AuthorityRecord.digest(.text(digest)) }
        }
        func context(peerID: String) throws -> PeerPackage.Context {
            guard profile == "tractanda.peer-configuration.v1", peers.count <= 256,
                Set(peers.map(\.peerID)).count == peers.count,
                let context = peers.first(where: { $0.peerID == peerID })
            else {
                throw TractandaError("untrustedPeer", "Peer is not explicitly configured.")
            }
            return context
        }
    }

    /// Local configuration is never a peer package object. The root writer serializes updates;
    /// immutable sequence files give a durable current value without a mutable pointer race.
    static func configuration(
        root: URL, files: DocumentContentFiles, readBudget: ((Int) throws -> Void)? = nil
    ) throws -> Configuration? {
        let directory = root.appendingPathComponent(".peer-configuration")
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        var latest: String?
        var count = 0
        try POSIXDirectory.withEntries(at: directory) { name in
            count += 1
            guard count <= 100_000, name.count == 25, name.hasSuffix(".json"),
                name.prefix(20).allSatisfy(\.isNumber)
            else {
                throw TractandaError("invalidPeerConfiguration", "Unknown private configuration history.")
            }
            if latest == nil || name > latest! { latest = name }
            return true
        }
        guard let latest else { return nil }
        let result = try PeerPackage.decode(
            Configuration.self,
            files.read(
                path: [".peer-configuration", latest], maximumBytes: PeerPackage.maximumPageBytes,
                readBudget: readBudget))
        guard result.profile == "tractanda.peer-configuration.v1", result.peers.count <= 256,
            Set(result.peers.map(\.peerID)).count == result.peers.count
        else {
            throw TractandaError("invalidPeerConfiguration", "Invalid private peer configuration.")
        }
        try result.validateCredentialBindings()
        try result.lifecycle?.validate(storeID: result.peers.first?.storeID)
        for context in result.peers {
            _ = try PeerPackage.Context(
                peerID: context.peerID, storeID: context.storeID,
                configurationDigest: context.configurationDigest, permittedOrigins: context.permittedOrigins)
        }
        return result
    }
    static func configurationSequence(root: URL) throws -> UInt64 {
        let directory = root.appendingPathComponent(".peer-configuration")
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        var sequence: UInt64 = 0
        var count = 0
        try POSIXDirectory.withEntries(at: directory) { name in
            count += 1
            guard count <= 100_000, name.count == 25, name.hasSuffix(".json"),
                let number = UInt64(name.prefix(20)), number > 0
            else {
                throw TractandaError("invalidPeerConfiguration", "Unknown configuration sequence.")
            }
            sequence = max(sequence, number)
            return true
        }
        return sequence
    }
    static func requireNoPendingPeerLifecycle(root: URL, files: DocumentContentFiles) throws {
        let directory = root.appendingPathComponent(".peer-lifecycle-operations")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var count = 0
        try POSIXDirectory.withEntries(at: directory) { name in
            count += 1
            guard count <= 100_000 else {
                throw TractandaError("resourceLimit", "Lifecycle reservation history exceeds its window.")
            }
            _ = try AuthorityRecord.persistentID(.text(name))
            let operation = try PeerPackage.decode(
                PeerLifecycle.Operation.self,
                files.read(
                    path: [".peer-lifecycle-operations", name], maximumBytes: PeerPackage.maximumPageBytes))
            guard operation.profile == PeerLifecycle.capability, operation.operationID == name,
                operation.sequence > 0
            else {
                throw TractandaError("invalidPeerLifecycle", "Invalid pending lifecycle reservation.")
            }
            let path = [".peer-configuration", String(format: "%020llu.json", operation.sequence)]
            guard
                let committed = try files.readIfPresent(
                    path: path, maximumBytes: PeerPackage.maximumPageBytes),
                committed == (try JSON.encode(operation.configuration))
            else {
                throw TractandaError(
                    "peerLifecycleRecoveryRequired",
                    "Complete the reserved lifecycle operation before changing peer configuration.")
            }
            return true
        }
    }
    static func writeConfiguration(
        _ value: Configuration, root: URL, files: DocumentContentFiles,
        sequence reserved: UInt64? = nil
    ) throws {
        // Validate every input before publishing the next immutable local configuration version.
        guard value.profile == "tractanda.peer-configuration.v1", value.peers.count <= 256,
            Set(value.peers.map(\.peerID)).count == value.peers.count
        else { throw TractandaError("invalidPeerConfiguration", "Invalid peer configuration.") }
        try value.validateCredentialBindings()
        for peer in value.peers {
            _ = try value.context(peerID: peer.peerID)
            _ = try PeerPackage.Context(
                peerID: peer.peerID, storeID: peer.storeID,
                configurationDigest: peer.configurationDigest, permittedOrigins: peer.permittedOrigins)
        }
        if reserved == nil { try requireNoPendingPeerLifecycle(root: root, files: files) }
        let current = try configurationSequence(root: root)
        guard reserved == nil || reserved! > 0 else {
            throw TractandaError("invalidPeerConfiguration", "Invalid reserved sequence.")
        }
        let sequence = reserved.map { $0 - 1 } ?? current
        let path = [".peer-configuration", String(format: "%020llu.json", sequence + 1)]
        let data = try JSON.encode(value)
        if let old = try files.readIfPresent(path: path, maximumBytes: PeerPackage.maximumPageBytes) {
            guard old == data else {
                throw TractandaError("peerLifecycleChanged", "Reserved configuration sequence differs.")
            }
            return
        }
        guard sequence == current else {
            throw TractandaError(
                "peerLifecycleChanged", "Configuration overtook a pending lifecycle operation.")
        }
        guard sequence < 99_999 else {
            throw TractandaError("resourceLimit", "Private configuration history requires maintenance.")
        }
        try files.writeImmutable(
            data, path: path,
            maximumBytes: PeerPackage.maximumPageBytes)
    }
}
