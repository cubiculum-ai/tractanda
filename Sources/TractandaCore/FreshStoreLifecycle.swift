import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

extension ItemStore {
    /// Explicit creation, bound to the executing OS identity. The key identifies only this
    /// local initialization request; it never supplies administrator authority.
    public static func initializeFresh(
        root: URL, indexDirectory: URL? = nil,
        accounts: any AccountDirectory = SystemAccountDirectory(),
        initialAccessConfiguration: ItemValue? = nil, initializationKey: String = "local-init"
    ) throws -> ItemStore {
        guard !initializationKey.isEmpty, initializationKey.utf8.count <= 200,
            !initializationKey.contains("\0")
        else {
            throw TractandaError("invalidArguments", "Invalid initialization key.")
        }
        do {
            _ = try FileMetadata.read(at: root)
            try PrivateConfiguration.validate(root, directory: true)
        } catch FileMetadataError.posix(let code) where code == ENOENT {
            // Only genuine absence permits fresh creation; other inspection failures are fatal.
        }
        let uid = tractanda_uid()
        let configuration =
            try initialAccessConfiguration
            ?? .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text(accounts.user(forUID: uid).name)]), "groups": .list([]),
            ])
        let prior = try InitialAuthorityBootstrap.load(root: root)
        let operation = try prior?.operationID ?? UUID.makeVersion1().uuidString.lowercased()
        return try createInitialized(
            root: root, indexDirectory: indexDirectory, accounts: accounts,
            initialAccessConfiguration: configuration, actorUID: uid, operationID: operation,
            initializationKey: initializationKey)
    }

    /// Normal runtime opening never creates canonical identity or admits standalone history.
    /// Derived indexes may be reconstructed from the retained canonical store.
    public static func openInitialized(
        root: URL, indexDirectory: URL? = nil,
        accounts: any AccountDirectory = SystemAccountDirectory(),
        attachmentUploadPolicy: AttachmentUploadPolicy = AttachmentUploadPolicy()
    ) throws -> ItemStore {
        try requireInitializedRoot(root)
        return try ItemStore(
            root: root, indexDirectory: indexDirectory, accounts: accounts,
            attachmentUploadPolicy: attachmentUploadPolicy,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true, firstSourceOperation: nil,
            requireInitializedStore: true)
    }

    static func requireInitializedRoot(_ root: URL) throws {
        // Check the lexical leaf before resolving system aliases such as /tmp on macOS.
        try PrivateConfiguration.validate(root, directory: true)
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        try PeerEnrollment.requireOrdinaryOpeningAllowed(root: canonical, ownerUID: tractanda_uid())
        try InitialAuthorityBootstrap.requireOpeningAllowed(
            root: canonical, ownerUID: tractanda_uid(),
            request: nil, accounts: SystemAccountDirectory())
        guard
            let requirement = try CanonicalReaderRequirement.load(root: canonical, ownerUID: tractanda_uid()),
            requirement.capabilities.contains(AuthorityStore.capability)
        else {
            throw TractandaError(
                "uninitializedStore",
                "Explicit fresh initialization or stopped development conversion is required.")
        }
        try CanonicalFormatSupport.current.require(requirement)
        _ = try InitialAuthorityBootstrap.storeIdentityBytes(root: canonical)
        guard
            try AuthorityStore.configuration(
                root: canonical,
                files: DocumentContentFiles(root: canonical, ownerUID: tractanda_uid(), minimumFreeBytes: 0))?
                .bootstrap != nil
        else {
            throw TractandaError(
                "authorityBootstrapRequired", "Initialized store lacks its accepted bootstrap pin.")
        }
        // Loading only: a missing local identity must never allocate a replacement here.
        let identity =
            try JSONSerialization.jsonObject(
                with: InitialAuthorityBootstrap.storeIdentityBytes(root: canonical)) as? [String: Any]
        guard let storeID = identity?["storeID"] as? String,
            try ReplicaIdentity.load(root: canonical, storeID: storeID, ownerUID: tractanda_uid()) != nil
        else {
            throw TractandaError(
                "invalidReplicaIdentity", "Initialized store lacks its committed local identity.")
        }
    }
}

extension ItemStore {
    /// Package-only structural inspection for an explicitly selected joining replica. This does
    /// not grant membership/admin authority, allocate identity, or accept an ordinary standalone root.
    package static func verifyPreparedReplicaIdentity(
        root: URL, ownerUID: UInt32,
        expectedStoreID: String, expectedReplicaID: String
    ) throws {
        _ = try AuthorityRecord.persistentID(.text(expectedStoreID))
        _ = try AuthorityRecord.persistentID(.text(expectedReplicaID))
        let metadata = try FileMetadata.read(at: root)
        guard metadata.type == .directory, metadata.uid == ownerUID, metadata.mode & 0o077 == 0,
            try PeerEnrollmentActivation.requiresTargetProof(root: root, ownerUID: ownerUID)
        else {
            throw TractandaError(
                "invalidEnrollmentTarget",
                "An activated prepared replica in its existing private custody is required.")
        }
        try PeerEnrollmentActivation.requireActivated(root: root, ownerUID: ownerUID)
        let storeID = try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: ownerUID)
        guard storeID == expectedStoreID,
            try ReplicaIdentity.load(root: root, storeID: storeID, ownerUID: ownerUID)?.replicaID
                == expectedReplicaID
        else {
            throw TractandaError(
                "invalidEnrollmentTarget",
                "Prepared replica identity differs from the independently selected pins.")
        }
    }

    /// The finite service-UID helper uses normal authority-aware opening/replay after structural
    /// target proof. A pending target, lost secret/proof or stale authority remains a closed gate.
    package static func verifyPreparedReplicaForSetup(
        root: URL, indexDirectory: URL,
        expectedStoreID: String, expectedReplicaID: String
    ) throws {
        try verifyPreparedReplicaIdentity(
            root: root, ownerUID: tractanda_uid(),
            expectedStoreID: expectedStoreID, expectedReplicaID: expectedReplicaID)
        let store = try openInitialized(root: root, indexDirectory: indexDirectory)
        // Normal opening preserves a retired replica for historical reads. Explicit adoption
        // additionally requires current runtime membership; it must not re-admit a disposed node.
        _ = try store.peerRuntimeMaterial()
        try withExtendedLifetime(store) {
            try verifyPreparedReplicaIdentity(
                root: root, ownerUID: tractanda_uid(),
                expectedStoreID: expectedStoreID, expectedReplicaID: expectedReplicaID)
        }
    }
}
