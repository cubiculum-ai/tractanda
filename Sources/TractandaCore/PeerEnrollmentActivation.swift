import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Host-private provisioning. Neither a wire request nor secret possession constructs authority.
enum PeerEnrollmentActivation {
    static let capability = "tractanda.peer-enrollment-activation.v1"
    /// A required local role marker; it grants no authority and only strengthens opening gates.
    static let targetCapability = "tractanda.peer-enrollment-target.v1"
    static let directory = ".peer-enrollment-activation"
    static let sourceDirectory = ".peer-enrollment-registrations"
    static let maximumBytes = PeerPackage.maximumPageBytes

    struct Pin: Codable, Equatable, Sendable {
        let sourceReplicaID: String
        let bootstrap: AuthorityBinding
        let approval: AuthorityBinding
    }
    struct Proof: Codable, Equatable, Sendable {
        let manifest: PeerPackage.Manifest
        let framingBytes: Data
        let approvalBytes: Data
        let prepared: PeerIntakeJournal.Publication
        let publication: PeerIntakeJournal.Publication
    }
    /// Only the target-oriented credential is delivered. Source credentials/journals never leave.
    struct Material: Sendable {
        let preparationBytes: Data
        let baseline: PeerPackage.Manifest
        let proof: Proof
        let sourceContext: PeerPackage.Context
        let targetContext: PeerPackage.Context
        let targetCredential: PeerCredential
        let targetPrivateBytesDigest: String
    }
    struct Record: Codable, Equatable, Sendable {
        let profile: String
        let preparationBytes: Data
        let pin: Pin
        let baseline: PeerPackage.Manifest
        let proof: Proof
        let sourceContext: PeerPackage.Context
        let targetContext: PeerPackage.Context
        let targetCredentialCommitment: String
        let targetPrivateBytesDigest: String
        var preparation: PeerEnrollment.Preparation {
            get throws { try PeerEnrollmentApproval.preparation(preparationBytes) }
        }
        var digest: String { get throws { AuthorityRecordCodec.sha256(try JSON.encode(self)) } }
    }
    struct Receipt: Codable, Equatable, Sendable {
        let profile: String
        let requestDigest: String
        let approval: AuthorityBinding
        let baselineDigest: String
        let configurationDigest: String
        let configurationSequence: UInt64
    }
    struct ConfigurationCommit: Codable, Equatable {
        let profile: String
        let requestDigest: String
        let approval: AuthorityBinding
        let before: AuthorityStore.Configuration?
        let after: AuthorityStore.Configuration
        let sequence: UInt64
    }
    /// Cannot be obtained by ordinary Store/service opening; Store revalidates it under its lock.
    struct Opening {
        let record: Record
        let credential: PeerCredential
    }
    final class Scope {
        let record: Record
        let files: DocumentContentFiles
        init(record: Record, files: DocumentContentFiles) {
            self.record = record
            self.files = files
        }
        func validate(readBudget: ((Int) throws -> Void)? = nil) throws {
            let credential = try PeerCredentialStore(files: files).load(
                peerID: record.targetContext.peerID,
                configurationDigest: record.targetContext.configurationDigest, readBudget: readBudget)
            guard try loadRecord(files, readBudget: readBudget) == record,
                try files.read(
                    path: [PeerEnrollment.intentName], maximumBytes: PeerEnrollment.maximumBytes,
                    readBudget: readBudget) == record.preparationBytes,
                try credential.privateBytesDigest == record.targetPrivateBytesDigest,
                try credential.commitment == record.targetCredentialCommitment
            else { throw failure("Provisioning request/preparation/private credential changed.") }
        }
        func permits(
            _ context: PeerPackage.Context, packageID: String? = nil,
            readBudget: ((Int) throws -> Void)? = nil
        ) throws -> Bool {
            guard context == record.targetContext else { return false }
            if let packageID,
                packageID != record.baseline.packageID && packageID != record.proof.manifest.packageID
            {
                return false
            }
            try validate(readBudget: readBudget)
            return true
        }
        func permits(_ publication: PeerIntakeJournal.Publication, readBudget: ((Int) throws -> Void)? = nil)
            throws -> Bool
        {
            guard try permits(publication.context, packageID: publication.packageID, readBudget: readBudget)
            else { return false }
            let manifest =
                publication.packageID == record.baseline.packageID ? record.baseline : record.proof.manifest
            return try publication.manifestDigest == AuthorityRecordCodec.sha256(JSON.encode(manifest))
        }
    }

    /// One private lifetime writer. Only finite provisioning methods expose its Store.
    final class Session {
        private var store: ItemStore?
        let record: Record
        fileprivate init(store: ItemStore, record: Record) {
            self.store = store
            self.record = record
        }
        func close() { store = nil }
        func closeForAcknowledgement() throws {
            weak var previous = store
            store = nil
            guard previous == nil else {
                throw TractandaError("custodyUncertain", "Target owner still has a retained Store.")
            }
        }
        private func owner() throws -> ItemStore {
            guard let store else { throw failure("Provisioning session is closed.") }
            return store
        }
        func append(packageID: String, object: PeerPackage.Object, offset: Int, bytes: Data) throws
            -> PeerPackage.Status
        {
            try owner().appendTargetEnrollment(
                packageID: packageID, object: object, offset: offset, bytes: bytes)
        }
        func resume(packageID: String, cursor: PeerPackage.ResumeCursor? = nil, limit: Int = 128) throws
            -> PeerPackage.ResumePage
        {
            try owner().resumeTargetEnrollment(packageID: packageID, cursor: cursor, limit: limit)
        }
        func finish() throws -> Receipt { try owner().activateTargetEnrollment() }
        func withControl<T>(_ check: @escaping () throws -> Void, body: () throws -> T) throws -> T {
            try owner().withTargetEnrollmentControl(check, body: body)
        }
        func withReadBudgetForTesting<T>(
            _ maximumBytes: UInt64, pageLimit: Int? = nil, consumed: (UInt64) -> Void,
            body: () throws -> T
        ) throws -> T {
            try owner().withPeerReadBudgetForTesting(
                maximumBytes, pageLimit: pageLimit, consumed: consumed, body: body)
        }
    }
    static func open(
        root: URL, material: Material, pin: Pin,
        accounts: any AccountDirectory = SystemAccountDirectory(),
        progress: ((String) throws -> Void)? = nil,
        control: (() throws -> Void)? = nil
    ) throws -> Session {
        try control?()
        let record = try makeRecord(material, pin: pin)
        let store = try ItemStore(
            root: root, accounts: accounts, revisionProjectionEnabled: true,
            authorityIntakeEnabled: true, firstSourceOperation: nil,
            targetProvisioning: .init(record: record, credential: material.targetCredential),
            targetProvisioningProgress: progress, targetProvisioningControl: control)
        if let control {
            try store.withTargetEnrollmentControl(control) { try store.startTargetEnrollment() }
        } else {
            try store.startTargetEnrollment()
        }
        return Session(store: store, record: record)
    }
    static func makeRecord(_ material: Material, pin: Pin) throws -> Record {
        let record = try Record(
            profile: capability, preparationBytes: material.preparationBytes, pin: pin,
            baseline: material.baseline, proof: material.proof, sourceContext: material.sourceContext,
            targetContext: material.targetContext,
            targetCredentialCommitment: material.targetCredential.commitment,
            targetPrivateBytesDigest: material.targetPrivateBytesDigest)
        try validate(record)
        try validateCredential(material.targetCredential, record: record)
        return record
    }
    static func validateCredential(_ credential: PeerCredential, record: Record) throws {
        let prep = try record.preparation
        let binding = credential.binding
        let approval = try AuthorityRecordCodec.decode(record.proof.approvalBytes).record
        guard try credential.commitment == record.targetCredentialCommitment,
            try credential.privateBytesDigest == record.targetPrivateBytesDigest,
            binding.storeID == prep.commonStoreID, binding.localReplicaID == prep.targetReplicaID,
            binding.remoteReplicaID == prep.sourceReplicaID, binding.peerID == record.targetContext.peerID,
            binding.configurationDigest == record.targetContext.configurationDigest,
            binding.pairingID == approval.payload["pairingID"]?.string,
            binding.localIsInitiator != approval.payload["sourceIsInitiator"]?.booleanValue
        else { throw failure("Target credential differs from exact approved private material.") }
    }
    static func validate(_ record: Record) throws {
        guard record.profile == capability, try JSON.encode(record).count <= maximumBytes else {
            throw failure("Provisioning input exceeds its strict profile/window.")
        }
        for context in [record.sourceContext, record.targetContext] {
            _ = try PeerPackage.Context(
                peerID: context.peerID, storeID: context.storeID,
                configurationDigest: context.configurationDigest, permittedOrigins: context.permittedOrigins)
        }
        let prep = try record.preparation
        let original = try AuthorityRecordCodec.decode(record.proof.approvalBytes)
        let approval = original.record
        let proof = record.proof
        try record.baseline.validate()
        try proof.manifest.validate()
        let page = try PeerPackage.decode(PeerPackage.Page.self, proof.framingBytes)
        try page.validate()
        let descriptor = PeerPackage.Object(
            kind: .authority, id: approval.recordID,
            length: proof.approvalBytes.count, sha256: original.sha256)
        let local = try PeerPackage.Context(
            peerID: "local", storeID: prep.commonStoreID,
            configurationDigest: AuthorityRecordCodec.sha256(Data(("local:" + prep.sourceReplicaID).utf8)),
            permittedOrigins: [prep.sourceReplicaID])
        guard record.pin.sourceReplicaID == prep.sourceReplicaID,
            record.pin.approval == (try .init(recordID: approval.recordID, sha256: original.sha256)),
            approval.kind == .enrollmentApproval, approval.storeID == prep.commonStoreID,
            approval.originReplicaID == prep.sourceReplicaID,
            approval.payload["targetReplicaID"] == .text(prep.targetReplicaID),
            approval.payload["preparationDigest"]
                == .text(AuthorityRecordCodec.sha256(record.preparationBytes)),
            try AuthorityRecord.list(approval.payload["bootstrap"]).map(AuthorityBinding.init(value:)) == [
                record.pin.bootstrap
            ],
            record.baseline.storeID == prep.commonStoreID,
            approval.payload["packageID"] == .text(record.baseline.packageID),
            approval.payload["manifestDigest"]
                == .text(AuthorityRecordCodec.sha256(try JSON.encode(record.baseline))),
            proof.prepared == proof.publication, proof.publication.context == local,
            proof.publication.packageID == proof.manifest.packageID,
            proof.publication.contextToken == PeerEnrollmentApproval.capability,
            proof.publication.manifestDigest == AuthorityRecordCodec.sha256(try JSON.encode(proof.manifest)),
            proof.publication.localItemPath == nil, proof.publication.controlParents.isEmpty,
            proof.manifest.storeID == prep.commonStoreID,
            proof.manifest.root.length == proof.framingBytes.count,
            proof.manifest.root.sha256 == AuthorityRecordCodec.sha256(proof.framingBytes),
            page.objects == [descriptor], page.children.isEmpty,
            record.baseline.packageID != proof.manifest.packageID,
            record.sourceContext.storeID == prep.commonStoreID,
            record.targetContext.storeID == prep.commonStoreID,
            approval.payload["sourcePeer"] == .text(record.sourceContext.peerID),
            approval.payload["targetPeer"] == .text(record.targetContext.peerID),
            approval.payload["sourceConfiguration"] == .text(record.sourceContext.configurationDigest),
            approval.payload["targetConfiguration"] == .text(record.targetContext.configurationDigest),
            approval.payload["sourceOrigins"]
                == .list(record.sourceContext.permittedOrigins.map(ItemValue.text)),
            approval.payload["targetOrigins"]
                == .list(record.targetContext.permittedOrigins.map(ItemValue.text)),
            record.sourceContext.permittedOrigins == [prep.targetReplicaID],
            record.targetContext.permittedOrigins.contains(prep.sourceReplicaID),
            approval.payload["targetCredential"] == .text(record.targetCredentialCommitment)
        else { throw failure("Preparation, independent pins or complete accepted approval proof differ.") }
        _ = try AuthorityRecord.digest(.text(record.targetPrivateBytesDigest))
        let binding = try PeerExchangeBinding(
            peerID: record.sourceContext.peerID, storeID: prep.commonStoreID,
            localReplicaID: prep.sourceReplicaID, remoteReplicaID: prep.targetReplicaID,
            pairingID: AuthorityRecord.persistentID(approval.payload["pairingID"]),
            localIsInitiator: approval.payload["sourceIsInitiator"]!.booleanValue!,
            configurationDigest: record.sourceContext.configurationDigest)
        guard try approval.payload["sourceCredential"] == .text(PeerCredential.commitment(for: binding))
        else {
            throw failure("Oriented source pairing commitment differs.")
        }
    }
    static func loadRecord(_ files: DocumentContentFiles, readBudget: ((Int) throws -> Void)? = nil) throws
        -> Record?
    {
        guard
            let bytes = try files.readIfPresent(
                path: [directory, "request.json"], maximumBytes: maximumBytes, readBudget: readBudget)
        else { return nil }
        let record = try PeerPackage.decode(Record.self, bytes)
        try validate(record)
        return record
    }
    static func loadReceipt(_ files: DocumentContentFiles, readBudget: ((Int) throws -> Void)? = nil) throws
        -> Receipt?
    {
        try files.readIfPresent(
            path: [directory, "activated.json"], maximumBytes: maximumBytes, readBudget: readBudget
        )
        .map { try PeerPackage.decode(Receipt.self, $0) }
    }
    /// The Store already owns this exact lifetime writer descriptor. This never locks a second time.
    static func prepareUnderLock(
        root: URL, suppliedRoot: URL, ownerUID: UInt32, writer: Int32,
        opening: Opening
    ) throws -> Scope {
        let record = opening.record
        try validate(record)
        try validateCredential(opening.credential, record: record)
        let leaf = try FileMetadata.read(at: suppliedRoot.standardizedFileURL)
        guard leaf.type == .directory, leaf.uid == ownerUID, leaf.mode & 0o077 == 0 else {
            throw failure("Provisioning requires its existing private prepared directory.")
        }
        #if canImport(Darwin)
            let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #else
            let fd = Glibc.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #endif
        guard fd >= 0 else { throw failure("Cannot inspect prepared root.") }
        defer { _ = close(fd) }
        var held = stat()
        var named = stat()
        var directory = stat()
        guard fstat(fd, &directory) == 0, directory.st_uid == ownerUID, directory.st_mode & 0o077 == 0,
            UInt64(directory.st_dev) == leaf.device, UInt64(directory.st_ino) == leaf.inode,
            fstat(writer, &held) == 0,
            fstatat(fd, ".writer.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
            held.st_ino == named.st_ino, held.st_dev == named.st_dev,
            held.st_uid == ownerUID, held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            held.st_mode & 0o777 == 0o600, held.st_nlink == 1, held.st_size == 0
        else { throw failure("Prepared root/writer ownership or inode changed.") }
        let files = DocumentContentFiles(
            root: root, ownerUID: ownerUID, minimumFreeBytes: 10 * 1024 * 1024 * 1024,
            rootDescriptor: fd)
        guard
            try files.read(path: [PeerEnrollment.intentName], maximumBytes: PeerEnrollment.maximumBytes)
                == record.preparationBytes
        else {
            throw failure("Prepared target differs from the exact approved operation.")
        }
        if let old = try loadRecord(files) {
            guard old == record else {
                throw failure("Provisioning retry changed its exact immutable inputs.")
            }
        } else {
            // A new operation cannot adopt arbitrary canonical data, old identities or secrets.
            try PeerEnrollment.inspectRoot(fd, files: files, owner: ownerUID)
            try files.writeImmutable(
                JSON.encode(record), path: [directoryName, "request.json"], maximumBytes: maximumBytes)
        }
        let keys = PeerCredentialStore(files: files)
        let keyPath = try PeerCredentialStore.path(
            peerID: record.targetContext.peerID,
            configurationDigest: record.targetContext.configurationDigest)
        if try files.readIfPresent(path: keyPath, maximumBytes: PeerCredentialStore.maximumBytes) == nil {
            guard
                (try? FileMetadata.read(at: root.appendingPathComponent(".tractanda-store-identity.json")))
                    == nil,
                (try? FileMetadata.read(at: root.appendingPathComponent("items"))) == nil
            else {
                throw failure(
                    "Established provisioning lost its exact private credential; restore it explicitly.")
            }
            try keys.stage(opening.credential)  // Exact supplied reserved bytes, never generated credentials.
        }
        try validateCredential(
            keys.load(
                peerID: record.targetContext.peerID,
                configurationDigest: record.targetContext.configurationDigest), record: record)
        return Scope(
            record: record,
            files: DocumentContentFiles(
                root: root, ownerUID: ownerUID,
                minimumFreeBytes: 10 * 1024 * 1024 * 1024))
    }
    private static let directoryName = directory
    /// Absence is only ENOENT. Unsafe/malformed retained artifacts are still a closed gate.
    static func requiresTargetProof(root: URL, ownerUID: UInt32) throws -> Bool {
        for name in [PeerEnrollment.intentName, directory] {
            do {
                _ = try FileMetadata.read(at: root.appendingPathComponent(name))
                return true
            } catch FileMetadataError.posix(let code) where code == ENOENT { continue }
        }
        return try CanonicalReaderRequirement.load(root: root, ownerUID: ownerUID)?
            .capabilities.contains(targetCapability) == true
    }
    /// Structural proof before Store/index opening; semantic canonical replay still precedes READY.
    static func requireActivated(root: URL, ownerUID: UInt32) throws {
        let files = DocumentContentFiles(root: root, ownerUID: ownerUID, minimumFreeBytes: 0)
        guard let record = try loadRecord(files), let receipt = try loadReceipt(files),
            let config = try AuthorityStore.configuration(root: root, files: files),
            receipt.profile == capability, receipt.requestDigest == (try record.digest),
            receipt.approval == record.pin.approval,
            receipt.baselineDigest == AuthorityRecordCodec.sha256(try JSON.encode(record.baseline)),
            receipt.configurationSequence > 0,
            let committed = try files.readIfPresent(
                path: [".peer-configuration", String(format: "%020llu.json", receipt.configurationSequence)],
                maximumBytes: maximumBytes),
            receipt.configurationDigest == AuthorityRecordCodec.sha256(committed),
            let original = try files.readIfPresent(
                path: [PeerEnrollment.intentName], maximumBytes: PeerEnrollment.maximumBytes),
            original == record.preparationBytes,
            try ReplicaIdentity.load(
                root: root, storeID: record.preparation.commonStoreID, ownerUID: ownerUID)?.replicaID
                == record.preparation.targetReplicaID,
            config.bootstrap?.recordID == record.pin.bootstrap.recordID,
            config.bootstrap?.sha256 == record.pin.bootstrap.sha256
        else {
            throw failure("Target remains pending or lost exact activation/identity/configuration proof.")
        }
        let commit = try PeerPackage.decode(
            ConfigurationCommit.self,
            files.read(path: [directory, "configuration.json"], maximumBytes: maximumBytes))
        let historical = try PeerPackage.decode(
            AuthorityStore.Configuration.self,
            files.read(
                path: [".peer-configuration", String(format: "%020llu.json", receipt.configurationSequence)],
                maximumBytes: maximumBytes))
        try validateTargetConfiguration(commit, record: record)
        guard commit.sequence == receipt.configurationSequence, commit.after == historical else {
            throw failure("Activation historical configuration/sequence differs.")
        }
        guard
            try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: ownerUID)
                == record.preparation.commonStoreID
        else {
            throw failure("Activated target lost its common store identity.")
        }
        if let context = config.peers.first(where: { $0.peerID == record.targetContext.peerID }) {
            let credential = try PeerCredentialStore(files: files).load(
                peerID: context.peerID,
                configurationDigest: context.configurationDigest)
            guard try config.credentialBindings?[context.peerID] == credential.commitment else {
                throw failure("Active target pairing lost its current private generation.")
            }
            if context == record.targetContext {
                try validateCredential(credential, record: record)
            } else if config.lifecycle?.historicalContexts.contains(record.targetContext) != true {
                throw failure("Pairing moved without retaining its historical activation context.")
            }
        } else if config.lifecycle?.historicalContexts.contains(record.targetContext) != true {
            throw failure("Activated target lost its pairing configuration history.")
        }
    }
    static func validateTargetConfiguration(_ commit: ConfigurationCommit, record: Record) throws {
        guard let before = commit.before, before.peers.isEmpty,
            before.credentialBindings?.isEmpty != false,
            before.lifecycle?.historicalContexts.isEmpty != false,
            before.bootstrap?.recordID == record.pin.bootstrap.recordID,
            before.bootstrap?.sha256 == record.pin.bootstrap.sha256,
            commit.profile == capability, commit.requestDigest == (try record.digest),
            commit.approval == record.pin.approval, commit.sequence > 0,
            commit.after
                == AuthorityStore.Configuration(
                    profile: before.profile, peers: [record.targetContext],
                    bootstrap: before.bootstrap, lifecycle: before.lifecycle,
                    credentialBindings: [record.targetContext.peerID: record.targetCredentialCommitment])
        else {
            throw failure("Target configuration intent differs from exact approved transition.")
        }
    }
    static func failure(_ message: String) -> TractandaError {
        TractandaError("enrollmentActivationRequired", message)
    }
}
