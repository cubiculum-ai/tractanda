import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Current local runtime configuration. It attests to no historical admission or peer trust.
enum PersonalWorkgroupProfile {
    static let capability = "tractanda.personal-workgroup.v1"
    static let readerLevel = 16
    static let name = ".tractanda-personal-profile.json"
    static let pendingName = ".tractanda-personal-profile.pending.json"
    struct Record: Codable, Equatable {
        let profile: String
        let storeID: String
        let replicaID: String
        let accessConfiguration: ItemValue
        let initialization: String
    }
    private struct StoreIdentity: Codable {
        let formatVersion: Int
        let storeID: String
    }
    enum Opening {
        case fresh(ItemValue)
        case freshReplica(storeID: String, configuration: ItemValue)
        case selectedContent(ItemValue)
        case existing
    }

    static func load(_ root: URL, pending: Bool = false, ownerUID: UInt32 = tractanda_uid()) throws -> Record?
    {
        guard
            let bytes = try CanonicalReaderRequirement.localConfigurationBytes(
                root: root, name: pending ? pendingName : name, ownerUID: ownerUID,
                maximumBytes: 128 * 1024)
        else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(object.keys) == ["profile", "storeID", "replicaID", "accessConfiguration", "initialization"]
        else { throw TractandaError("invalidPersonalProfile", "Unknown local profile configuration.") }
        let record = try JSON.decode(Record.self, bytes)
        guard record.profile == "tractanda.personal-workgroup.v1",
            UUID(uuidString: record.storeID)?.version1Components != nil,
            UUID(uuidString: record.replicaID)?.version1Components != nil,
            record.storeID != record.replicaID,
            ["fresh", "freshReplica", "selectedContent"].contains(record.initialization)
        else { throw TractandaError("invalidPersonalProfile", "Invalid local personal/workgroup profile.") }
        _ = try AccessConfiguration(record.accessConfiguration)
        return record
    }

    /// Caller holds the lifetime root writer lock. Failed activation retains its exact local plan.
    static func prepare(
        _ root: URL, opening: Opening, accounts: any AccountDirectory,
        boundary: (String) throws -> Void = { _ in }
    ) throws -> Record {
        if (try? FileMetadata.read(at: root.appendingPathComponent(".peer-configuration"))) != nil {
            throw TractandaError(
                "unsupportedPersonalPeers", "Old peer configuration is not personal membership.")
        }
        if try PersonalPeerRuntimeConfiguration.load(root: root, ownerUID: tractanda_uid()) != nil {
            let current = try PersonalSyncConfiguration.membership(root: root, ownerUID: tractanda_uid())
            let pending = try PersonalSyncConfiguration.read(
                PersonalMembershipPreparation.self,
                root: root, name: PersonalSyncConfiguration.pendingName, ownerUID: tractanda_uid())
            try pending?.configuration.validate()
            guard let active = try load(root), let configuration = current ?? pending?.configuration,
                configuration.storeID == active.storeID,
                configuration.members.contains(where: { $0.replicaID == active.replicaID }),
                let fence = try CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()),
                fence.minimumReaderLevel >= 18,
                fence.capabilities.contains(PersonalSyncValidation.capability)
            else {
                throw TractandaError(
                    "unsupportedPersonalPeers",
                    "Personal runtime needs explicit current or control-only prepared membership.")
            }
        }
        if let active = try load(root) {
            switch opening {
            case .fresh(let policy), .selectedContent(let policy):
                guard active.accessConfiguration == policy else {
                    throw TractandaError(
                        "invalidPersonalProfile",
                        "Existing local policy differs; open or explicitly configure it.")
                }
            case .freshReplica(let storeID, let policy):
                guard active.storeID == storeID, active.accessConfiguration == policy else {
                    throw TractandaError(
                        "invalidPersonalProfile", "Existing replica differs from its fresh plan.")
                }
            case .existing: break
            }
            if let pending = try load(root, pending: true), pending != active {
                throw TractandaError("invalidPersonalProfile", "Local activation plans conflict.")
            }
            guard
                try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: tractanda_uid())
                    == active.storeID,
                try ReplicaIdentity.load(root: root, storeID: active.storeID, ownerUID: tractanda_uid())?
                    .replicaID == active.replicaID
            else {
                throw TractandaError(
                    "invalidPersonalProfile", "Established local runtime identities are incomplete.")
            }
            guard let fence = try CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()),
                fence.storeID == active.storeID, fence.minimumReaderLevel >= readerLevel,
                fence.capabilities.contains(capability)
            else {
                throw TractandaError(
                    "invalidPersonalProfile", "Personal/workgroup reader fence is missing or weakened.")
            }
            try CanonicalFormatSupport.personalWorkgroup.require(fence)
            return active
        }
        if case .existing = opening, let pending = try load(root, pending: true) {
            let intended: Opening
            if pending.initialization == "freshReplica" {
                intended = .freshReplica(storeID: pending.storeID, configuration: pending.accessConfiguration)
            } else {
                intended =
                    pending.initialization == "fresh"
                    ? .fresh(pending.accessConfiguration) : .selectedContent(pending.accessConfiguration)
            }
            return try prepare(root, opening: intended, accounts: accounts, boundary: boundary)
        }
        guard case .existing = opening else {
            let policy: ItemValue
            let fresh: Bool
            let commonStoreID: String?
            switch opening {
            case .fresh(let value):
                policy = value
                fresh = true
                commonStoreID = nil
            case .freshReplica(let storeID, let value):
                try PersonalSyncValidation.identifier(storeID)
                policy = value
                fresh = true
                commonStoreID = storeID
            case .selectedContent(let value):
                policy = value
                fresh = false
                commonStoreID = nil
            case .existing:
                throw TractandaError("uninitializedPersonalProfile", "No established local profile.")
            }
            if fresh { try PrivateConfiguration.makeDirectory(root.appendingPathComponent("items")) }
            let configuration = try AccessConfiguration(policy)
            try configuration.validate(
                using: PrincipalResolver(directory: accounts, configuration: configuration))
            if let pending = try load(root, pending: true) {
                guard pending.accessConfiguration == policy,
                    pending.initialization
                        == (commonStoreID != nil ? "freshReplica" : fresh ? "fresh" : "selectedContent"),
                    commonStoreID == nil || pending.storeID == commonStoreID
                else {
                    throw TractandaError("invalidPersonalProfile", "Retry the same local activation policy.")
                }
                let inventory = try PersonalRecoveryInventory.inspect([
                    .init(root: root, ownerUID: tractanda_uid())
                ])
                guard inventory.isStructurallyComplete, !fresh || inventory.records.isEmpty else {
                    throw TractandaError(
                        "personalPreparationRequired",
                        "Pending activation's selected content changed or fresh root is populated.")
                }
                try installIdentities(pending, root: root, boundary: boundary)
                return pending
            }
            // A deliberately prepared raw baseline contains committed content only. Old operational
            // data must be retained separately by an explicit migration, never silently imported.
            let allowed: Set<String> = [
                "items", "attachments", "documents", ".writer.lock", ".personal-activation",
            ]
            try POSIXDirectory.withEntries(at: root) { entry in
                guard allowed.contains(entry) else {
                    throw TractandaError(
                        "personalPreparationRequired",
                        "Prepare raw content without old operational state before activation.")
                }
                return true
            }
            for (directory, allowedChild) in [("attachments", "payloads"), ("documents", "content")] {
                let path = root.appendingPathComponent(directory)
                if (try? FileMetadata.read(at: path)) != nil {
                    try POSIXDirectory.withEntries(at: path) { entry in
                        guard entry == allowedChild else {
                            throw TractandaError(
                                "personalPreparationRequired",
                                "Pending data is not committed recovery content.")
                        }
                        return true
                    }
                }
            }
            let inventory = try PersonalRecoveryInventory.inspect([
                .init(root: root, ownerUID: tractanda_uid())
            ])
            guard inventory.isStructurallyComplete else {
                throw PersonalRecoveryIndex.Incomplete(diagnostics: inventory.diagnostics)
            }
            guard !fresh || inventory.records.isEmpty else {
                throw TractandaError(
                    "personalPreparationRequired",
                    "Use explicit selected-content activation for retained items.")
            }
            let record = try Record(
                profile: "tractanda.personal-workgroup.v1",
                storeID: commonStoreID ?? UUID.makeVersion1().uuidString.lowercased(),
                replicaID: UUID.makeVersion1().uuidString.lowercased(), accessConfiguration: policy,
                initialization: commonStoreID != nil ? "freshReplica" : fresh ? "fresh" : "selectedContent")
            try persist(record, root: root, name: pendingName)
            try boundary("pendingPublished")
            try installIdentities(record, root: root, boundary: boundary)
            return record
        }
        throw TractandaError(
            "uninitializedPersonalProfile",
            "Explicit personal/workgroup creation or selected-content activation is required.")
    }

    private static func installIdentities(_ record: Record, root: URL, boundary: (String) throws -> Void)
        throws
    {
        let files = DocumentContentFiles(root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 0)
        // Fence the new interpretation BEFORE exposing any new operational identity. Older
        // software must fail closed even if activation stops between these durable local files.
        let requirement = CanonicalReaderRequirement(
            storeID: record.storeID, minimumReaderLevel: readerLevel, recordFormats: [1, 2],
            capabilities: [capability])
        if let old = try CanonicalReaderRequirement.localConfigurationBytes(
            root: root, name: CanonicalReaderRequirement.fileName, ownerUID: tractanda_uid(),
            maximumBytes: 16 * 1024)
        {
            let retained = try JSON.decode(CanonicalReaderRequirement.self, old)
            guard retained.storeID == record.storeID, retained.minimumReaderLevel >= readerLevel,
                retained.capabilities.contains(capability), Set([1, 2]).isSubset(of: retained.recordFormats)
            else {
                throw TractandaError(
                    "invalidPersonalProfile", "Activation reader fence differs from its local plan.")
            }
            try CanonicalFormatSupport.personalWorkgroup.require(retained)
        } else {
            try persistBytes(JSON.encode(requirement), root: root, name: CanonicalReaderRequirement.fileName)
        }
        try boundary("readerFenced")
        let identities: [(String, Data)] = [
            (
                ".tractanda-store-identity.json",
                try JSON.encode(StoreIdentity(formatVersion: 1, storeID: record.storeID))
            ),
            (
                ReplicaIdentity.name,
                try JSON.encode(
                    ReplicaIdentity.Record(
                        formatVersion: 1, storeID: record.storeID, replicaID: record.replicaID))
            ),
        ]
        for (name, bytes) in identities {
            let old =
                try name == ".tractanda-store-identity.json"
                ? CanonicalReaderRequirement.localConfigurationBytes(
                    root: root, name: name, ownerUID: tractanda_uid(), maximumBytes: 4096)
                : files.readIfPresent(path: [name], maximumBytes: 4096)
            if let old {
                guard old == bytes else {
                    throw TractandaError(
                        "invalidPersonalProfile", "Local identity differs from activation plan.")
                }
            } else if name == ".tractanda-store-identity.json" {
                try persistBytes(bytes, root: root, name: name)
            } else {
                try files.writeImmutable(bytes, path: [name], maximumBytes: 4096)
            }
        }
    }

    static func complete(_ record: Record, root: URL) throws {
        try persist(record, root: root, name: name)
        if unlink(root.appendingPathComponent(pendingName).path) != 0, errno != ENOENT {
            throw FileMetadataError.posix(errno)
        }
        try StoreCheckpoint.syncDirectory(root)
    }

    static func persist(
        _ record: Record, root: URL, name: String = PersonalWorkgroupProfile.name,
        afterPublication: () throws -> Void = {}
    ) throws {
        try persistBytes(JSON.encode(record), root: root, name: name, afterPublication: afterPublication)
    }
    private static func persistBytes(
        _ bytes: Data, root: URL, name: String, afterPublication: () throws -> Void = {}
    ) throws {
        let workspace = root.appendingPathComponent(".personal-activation")
        try PrivateConfiguration.makeDirectory(workspace)
        let temporary = ".config-" + Identifier.make()
        let files = DocumentContentFiles(root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 0)
        try files.writeImmutable(bytes, path: [".personal-activation", temporary], maximumBytes: 128 * 1024)
        defer { _ = unlink(workspace.appendingPathComponent(temporary).path) }
        let descriptor = open(
            workspace.appendingPathComponent(temporary).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileMetadataError.posix(errno) }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else {
            throw FileMetadataError.posix(errno)
        }
        guard
            rename(workspace.appendingPathComponent(temporary).path, root.appendingPathComponent(name).path)
                == 0
        else {
            throw FileMetadataError.posix(errno)
        }
        try afterPublication()
        try StoreCheckpoint.syncDirectory(root)
        try StoreCheckpoint.syncDirectory(workspace)
    }
}
