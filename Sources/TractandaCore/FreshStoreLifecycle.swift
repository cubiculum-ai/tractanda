import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

extension ItemStore {
    /// Explicit personal/workgroup creation. Historical authority initialization remains separate.
    public static func initializePersonalWorkgroup(
        root: URL, indexDirectory: URL? = nil,
        accounts: any AccountDirectory = SystemAccountDirectory(),
        accessConfiguration: ItemValue
    ) throws -> ItemStore {
        try ItemStore(
            personalRoot: root, indexDirectory: indexDirectory,
            opening: .fresh(accessConfiguration), accounts: accounts)
    }

    /// Explicit administrator-selected prepared raw content; this is not ordinary legacy startup.
    public static func activatePersonalWorkgroupContent(
        root: URL, indexDirectory: URL? = nil,
        accounts: any AccountDirectory = SystemAccountDirectory(),
        accessConfiguration: ItemValue
    ) throws -> ItemStore {
        try ItemStore(
            personalRoot: root, indexDirectory: indexDirectory,
            opening: .selectedContent(accessConfiguration), accounts: accounts)
    }

    public static func openPersonalWorkgroup(
        root: URL, indexDirectory: URL? = nil,
        accounts: any AccountDirectory = SystemAccountDirectory(),
        attachmentUploadPolicy: AttachmentUploadPolicy = .init()
    ) throws -> ItemStore {
        try ItemStore(
            personalRoot: root, indexDirectory: indexDirectory, opening: .existing, accounts: accounts,
            attachmentUploadPolicy: attachmentUploadPolicy)
    }

    /// Normal fresh creation uses the personal/workgroup profile and executing OS identity.
    /// The bounded request label is accepted for Setup callers; it grants no authority and
    /// never selects another store or replaces an established local policy.
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
        return try initializePersonalWorkgroup(
            root: root, indexDirectory: indexDirectory, accounts: accounts,
            accessConfiguration: configuration)
    }

    /// Normal runtime opening never creates canonical identity or admits standalone history.
    /// Derived indexes may be reconstructed from the retained canonical store.
    public static func openInitialized(
        root: URL, indexDirectory: URL? = nil,
        accounts: any AccountDirectory = SystemAccountDirectory(),
        attachmentUploadPolicy: AttachmentUploadPolicy = AttachmentUploadPolicy()
    ) throws -> ItemStore {
        try requireInitializedRoot(root)
        return try openPersonalWorkgroup(
            root: root, indexDirectory: indexDirectory, accounts: accounts,
            attachmentUploadPolicy: attachmentUploadPolicy)
    }

    static func requireInitializedRoot(_ root: URL, ownerUID: UInt32 = tractanda_uid()) throws {
        let metadata = try FileMetadata.read(at: root)
        guard metadata.type == .directory, metadata.uid == ownerUID, metadata.mode & 0o077 == 0 else {
            throw TractandaError(
                "privateConfiguration", "Personal store root custody differs from the selected owner.")
        }
        guard
            try PersonalWorkgroupProfile.load(root, ownerUID: ownerUID) != nil
                || PersonalWorkgroupProfile.load(root, pending: true, ownerUID: ownerUID) != nil
        else {
            throw TractandaError(
                "personalMigrationRequired",
                "This root requires explicit selected-content preparation and personal/workgroup activation; ordinary opening never converts historical or raw stores."
            )
        }
    }

    /// Read-only Setup validation can run as root for a daemon-owned tree. Every private read
    /// uses the explicitly selected filesystem owner, never the validator process's UID.
    package static func verifyPersonalWorkgroupRoot(root: URL, ownerUID: UInt32) throws {
        try requireInitializedRoot(root, ownerUID: ownerUID)
        guard let record = try PersonalWorkgroupProfile.load(root, ownerUID: ownerUID),
            let fence = try CanonicalReaderRequirement.load(root: root, ownerUID: ownerUID),
            fence.storeID == record.storeID, fence.minimumReaderLevel >= PersonalWorkgroupProfile.readerLevel,
            fence.capabilities.contains(PersonalWorkgroupProfile.capability),
            try ReplicaIdentity.load(root: root, storeID: record.storeID, ownerUID: ownerUID)?.replicaID
                == record.replicaID
        else {
            throw TractandaError(
                "invalidPersonalProfile", "Personal runtime activation or identities are incomplete.")
        }
        try CanonicalFormatSupport.personalWorkgroup.require(fence)
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
