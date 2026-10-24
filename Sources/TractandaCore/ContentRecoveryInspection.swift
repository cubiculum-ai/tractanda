import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Local filesystem inspection, not a client read API or historical-admission certificate.
public struct ContentInspectionReport: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let itemID: String
        public let heads: [String]
        public let revisionCount: Int
        public let hasDiagnostics: Bool
    }
    public struct Record: Codable, Sendable {
        public let itemID: String
        public let revisionID: String
        public let parents: [String]
        public let isDeleted: Bool
        public let sha256: String
        public let byteCount: UInt64
        public let locations: [String]
    }
    public struct Original: Codable, Sendable {
        public let itemID: String
        public let descriptor: AttachmentDescriptor
        public let verifiedLocations: [String]
    }
    public struct SavedDocument: Codable, Sendable {
        public let itemID: String
        public let representationID: String
        public let attachmentID: String
        public let source: AttachmentDocumentSource
        public let content: DocumentContentReference
        public let verifiedLocations: [String]
    }
    public struct Diagnostic: Codable, Sendable {
        public let kind: String
        public let itemID: String?
        public let revisionID: String?
        public let location: String?
    }
    public struct Counts: Codable, Sendable {
        public let items: Int
        public let revisions: Int
        public let referencedOriginals: Int
        public let originalsWithVerifiedLocations: Int
        public let referencedSavedDocuments: Int
        public let savedDocumentsWithVerifiedLocations: Int
        public let entriesVisited: Int
        public let visitedTemporaryEntriesExcluded: Int
        public let recordBytesBudgeted: UInt64
        public let payloadBytesBudgeted: UInt64
    }
    public let profile: String
    public let sourcePath: String
    public let expectedOwnerUID: UInt32
    public let ownerSelection: String
    public let writerObservation: String
    public let structurallyComplete: Bool
    public let readinessScope: String
    public let osIdentityMapping: String
    public let historicalAdmission: String
    public let payloadScope: String
    public let stability: String
    public let counts: Counts
    public let items: [Item]
    public let records: [Record]
    public let originals: [Original]
    public let savedDocuments: [SavedDocument]
    public let diagnostics: [Diagnostic]
}

public struct ContentActivationReport: Codable, Sendable {
    public let profile: String
    public let storePath: String
    public let indexDirectory: String
    public let storeID: String
    public let replicaID: String
    public let persistenceProfile: String
    public let state: String
    public let ready: Bool
    public let items: Int
    public let revisions: Int
}

public enum LocalContentRecovery {
    /// Requires actual filesystem read rights. Supplying another UID does not impersonate it.
    /// A held existing shared lock excludes cooperating writers; raw roots without a lock must
    /// remain explicitly offline/stable. No lock/profile/index/control file is created.
    public static func inspect(root: URL, ownerUID requestedUID: UInt32? = nil) throws
        -> ContentInspectionReport
    {
        let root = root.standardizedFileURL
        let before = try FileMetadata.read(at: root)
        let owner = requestedUID ?? before.uid
        guard before.type == .directory, before.uid == owner, before.mode & 0o077 == 0 else {
            throw TractandaError(
                "invalidRecoveryScope", "Selected content root must retain its expected private owner.")
        }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw FileMetadataError.posix(errno) }
        defer { close(directory) }
        let retained = try PooledCanonicalRecord.inventoryMetadata(for: directory)
        guard retained.inode == before.inode, retained.device == before.device else {
            throw TractandaError("invalidRecoveryScope", "Selected content root changed before inspection.")
        }
        let lock = openat(directory, ".writer.lock", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        let observation: String
        if lock < 0 {
            guard errno == ENOENT else { throw FileMetadataError.posix(errno) }
            observation = "absent-explicit-offline-stability-required"
        } else {
            do {
                let metadata = try PooledCanonicalRecord.inventoryMetadata(for: lock)
                var raw = stat()
                guard metadata.type == .regular, metadata.uid == owner, metadata.mode & 0o077 == 0,
                    fstat(lock, &raw) == 0, raw.st_nlink == 1
                else {
                    throw TractandaError("invalidRecoveryScope", "Existing writer lock custody is unsafe.")
                }
                guard flock(lock, LOCK_SH | LOCK_NB) == 0 else {
                    throw TractandaError(
                        "contentBusy", "Stop the cooperating writer before content inspection.")
                }
            } catch {
                close(lock)
                throw error
            }
            observation = "existing-shared-lock-held-during-inspection"
        }
        defer {
            if lock >= 0 {
                _ = flock(lock, LOCK_UN)
                close(lock)
            }
        }
        let result = try PersonalRecoveryInventory.inspect([.init(root: root, ownerUID: owner)])
        let after = try FileMetadata.read(at: root)
        guard after.inode == retained.inode, after.device == retained.device,
            after.uid == owner, after.mode == retained.mode
        else {
            throw TractandaError("invalidRecoveryScope", "Selected content root changed during inspection.")
        }
        let originals = result.referencedOriginals.keys.sorted().map { id in
            let value = result.referencedOriginals[id]!
            return ContentInspectionReport.Original(
                itemID: value.itemID, descriptor: value.descriptor,
                verifiedLocations: value.verifiedLocations.map(\.path).sorted())
        }
        let documents = result.referencedSavedDocuments.keys.sorted().map { id in
            let value = result.referencedSavedDocuments[id]!
            return ContentInspectionReport.SavedDocument(
                itemID: value.itemID, representationID: value.representationID,
                attachmentID: value.attachmentID, source: value.source, content: value.content,
                verifiedLocations: value.verifiedLocations.map(\.path).sorted())
        }
        return ContentInspectionReport(
            profile: "tractanda.content-inspection.v1", sourcePath: root.path,
            expectedOwnerUID: owner,
            ownerSelection: requestedUID == nil ? "inferred-from-root-custody" : "explicit",
            writerObservation: observation, structurallyComplete: result.isStructurallyComplete,
            readinessScope:
                "structural DAG, unique physical heads and referenced payload closure only; runtime/activation preparation not assessed",
            osIdentityMapping: "not-evaluated; no access policy supplied",
            historicalAdmission: "not-assessed; old-format placement does not establish former admission",
            payloadScope:
                "referenced originals and saved-content documents only; verifiedLocations passed streaming checks; unreferenced/orphan bytes are not verified or reported; inline document bytes remain within revision digests",
            stability:
                "per-file descriptor checks, not a concurrent snapshot; keep the selected source offline and stable",
            counts: .init(
                items: result.items.count, revisions: result.records.count,
                referencedOriginals: originals.count,
                originalsWithVerifiedLocations: originals.filter { !$0.verifiedLocations.isEmpty }.count,
                referencedSavedDocuments: documents.count,
                savedDocumentsWithVerifiedLocations: documents.filter { !$0.verifiedLocations.isEmpty }.count,
                entriesVisited: result.entriesVisited,
                visitedTemporaryEntriesExcluded: result.stagedEntriesExcluded,
                recordBytesBudgeted: result.recordBytesBudgeted,
                payloadBytesBudgeted: result.payloadBytesBudgeted),
            items: result.items.keys.sorted().map {
                let value = result.items[$0]!
                return .init(
                    itemID: value.itemID, heads: value.heads, revisionCount: value.revisionCount,
                    hasDiagnostics: value.hasDiagnostics)
            },
            records: result.records.keys.sorted().map {
                let value = result.records[$0]!
                return .init(
                    itemID: value.itemID, revisionID: value.revisionID, parents: value.parents,
                    isDeleted: value.isDeleted,
                    sha256: value.sha256.map { String(format: "%02x", $0) }.joined(),
                    byteCount: value.byteCount, locations: value.locations.map(\.path).sorted())
            },
            originals: originals, savedDocuments: documents,
            diagnostics: result.diagnostics.sorted {
                ($0.kind.rawValue, $0.itemID ?? "", $0.revisionID ?? "", $0.location?.path ?? "")
                    < ($1.kind.rawValue, $1.itemID ?? "", $1.revisionID ?? "", $1.location?.path ?? "")
            }.map {
                .init(
                    kind: $0.kind.rawValue, itemID: $0.itemID, revisionID: $0.revisionID,
                    location: $0.location?.path)
            })
    }

    public static func activate(root: URL, indexDirectory: URL, configuration: ItemValue) throws
        -> ContentActivationReport
    {
        let store = try ItemStore.activatePersonalWorkgroupContent(
            root: root, indexDirectory: indexDirectory,
            accessConfiguration: configuration)
        return try store.contentActivationReport()
    }

    package static func configuration(at url: URL) throws -> ItemValue {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FileMetadataError.posix(errno) }
        defer { close(fd) }
        let metadata = try PooledCanonicalRecord.inventoryMetadata(for: fd)
        guard metadata.type == .regular, metadata.size > 0, metadata.size <= 128 * 1024 else {
            throw TractandaError("resourceLimit", "Supply a regular bounded local access configuration file.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while data.count < Int(metadata.size) {
            let window = min(buffer.count, Int(metadata.size) - data.count)
            let amount = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, window) }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else {
                throw TractandaError("invalidConfiguration", "Access configuration changed during reading.")
            }
            data.append(contentsOf: buffer.prefix(amount))
        }
        guard try PooledCanonicalRecord.inventoryMetadata(for: fd) == metadata else {
            throw TractandaError("invalidConfiguration", "Access configuration changed during reading.")
        }
        return try JSON.decode(ItemValue.self, data)
    }

    /// An optional report artifact is private, new and outside the inspected source. Existing
    /// files/symlinks are never overwritten and no directory is created on the caller's behalf.
    public static func write(_ report: ContentInspectionReport, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try PrivateConfiguration.validate(parent, directory: true)
        func physical(_ url: URL) throws -> String {
            guard let value = realpath(url.path, nil) else { throw FileMetadataError.posix(errno) }
            defer { free(value) }
            return String(cString: value)
        }
        let source = open(report.sourcePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw FileMetadataError.posix(errno) }
        defer { close(source) }
        let sourceIdentity = try PooledCanonicalRecord.inventoryMetadata(for: source)
        let directory = open(try physical(parent), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw FileMetadataError.posix(errno) }
        defer { close(directory) }
        let parentIdentity = try PooledCanonicalRecord.inventoryMetadata(for: directory)
        guard parentIdentity.uid == tractanda_uid(), parentIdentity.mode & 0o077 == 0 else {
            throw TractandaError("invalidReportDestination", "Report directory custody changed.")
        }
        // Directory identities establish confinement even under case/normalization aliases.
        // Keep the destination descriptor for publication instead of reopening a pathname.
        var ancestor = dup(directory)
        guard ancestor >= 0 else { throw FileMetadataError.posix(errno) }
        defer { close(ancestor) }
        while true {
            let identity = try PooledCanonicalRecord.inventoryMetadata(for: ancestor)
            guard identity.device != sourceIdentity.device || identity.inode != sourceIdentity.inode else {
                throw TractandaError(
                    "invalidReportDestination", "Write inspection reports outside the selected source.")
            }
            let above = openat(ancestor, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard above >= 0 else { throw FileMetadataError.posix(errno) }
            let aboveIdentity: FileMetadata
            do {
                aboveIdentity = try PooledCanonicalRecord.inventoryMetadata(for: above)
            } catch {
                close(above)
                throw error
            }
            if aboveIdentity.device == identity.device, aboveIdentity.inode == identity.inode {
                close(above)
                break
            }
            close(ancestor)
            ancestor = above
        }
        let data = try JSON.encode(report)
        guard data.count <= 256 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Inspection report exceeds its bounded metadata output.")
        }
        let name = destination.lastPathComponent
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileMetadataError.posix(errno) }
        var success = false
        defer {
            close(fd)
            if !success { unlinkat(directory, name, 0) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                    let count = Darwin.write(
                        fd, bytes.baseAddress!.advanced(by: offset), min(262_144, bytes.count - offset))
                #else
                    let count = Glibc.write(
                        fd, bytes.baseAddress!.advanced(by: offset), min(262_144, bytes.count - offset))
                #endif
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw FileMetadataError.posix(errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw FileMetadataError.posix(errno) }
        guard fsync(directory) == 0 else { throw FileMetadataError.posix(errno) }
        success = true
    }
}
