import CTractandaPlatform
import Crypto
import Foundation
import TractandaClient

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Private immutable-payload storage. This type performs no authorization; callers must check
/// current ACLs before invoking any method that reads or publishes attachment bytes.
final class AttachmentPayloadStore: @unchecked Sendable {
    static let maximumFileBytes: Int64 = AttachmentDescriptor.maximumPayloadBytes
    static let maximumChunkBytes = 256 * 1024
    static let maximumAttachments = AttachmentDescriptor.maximumAttachments
    static let defaultReserveBytes: Int64 = 1024 * 1024 * 1024
    private static let cacheEntryLimit = 128
    private static let pathComponentLimit = 255
    private static let publishedMode: mode_t = 0o400
    private static let stagingMode: mode_t = 0o600
    private static let privateDirectoryMode: mode_t = 0o700

    private struct VerifiedSignature: Equatable {
        let descriptor: AttachmentDescriptor
        let metadata: FileMetadata
    }

    private let stagingQuota: StagingByteQuota?
    private let root: URL
    private var placement: PayloadPlacement!
    var placementArrivalMinuteForTesting: (() throws -> String) {
        get { placement.arrivalMinute }
        set { placement.arrivalMinute = newValue }
    }
    var afterPlacementIntentForTesting: (() throws -> Void)? {
        get { placement.afterIntent }
        set { placement.afterIntent = newValue }
    }
    var afterPlacementFileForTesting: (() throws -> Void)? {
        get { placement.afterFile }
        set { placement.afterFile = newValue }
    }
    var placementRecoveryScansForTesting: Int { placement.recoveryScans }
    private let ownerUID: UInt32
    private let reserveBytes: Int64
    private let availableBytesOverride: (@Sendable () throws -> UInt64)?
    private let fileByteLimit: Int64
    private let chunkByteLimit: Int
    private let cacheLock = NSLock()
    private var verified: [String: VerifiedSignature] = [:]
    private var verifiedOrder: [String] = []
    private var digestPassCount = 0

    var digestPassCountForTesting: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return digestPassCount
    }

    init(
        root: URL, ownerUID: UInt32, reserveBytes: Int64 = defaultReserveBytes,
        availableBytes: (@Sendable () throws -> UInt64)? = nil,
        maxFileBytesForTesting: Int64? = nil, maxChunkBytesForTesting: Int? = nil,
        stagingQuota: StagingByteQuota? = nil, indexDirectory: URL? = nil,
        maintenance: CanonicalMaintenanceContext? = nil
    ) throws {
        guard reserveBytes >= 0 else {
            throw TractandaError("unsafeAttachmentStore", "Invalid attachment free-space reserve.")
        }
        let fileLimit = min(Self.maximumFileBytes, maxFileBytesForTesting ?? Self.maximumFileBytes)
        let chunkLimit = min(Self.maximumChunkBytes, maxChunkBytesForTesting ?? Self.maximumChunkBytes)
        guard fileLimit > 0, chunkLimit > 0 else {
            throw TractandaError("unsafeAttachmentStore", "Invalid attachment transfer limits.")
        }
        self.stagingQuota = stagingQuota
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.ownerUID = ownerUID
        self.reserveBytes = reserveBytes
        self.availableBytesOverride = availableBytes
        self.fileByteLimit = fileLimit
        self.chunkByteLimit = chunkLimit
        let rootDescriptor = self.root.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else { throw Self.posix("Cannot open canonical attachment root.") }
        defer { _ = close(rootDescriptor) }
        try Self.validateDirectory(rootDescriptor, ownerUID: ownerUID)
        placement = PayloadPlacement(
            root: self.root, indexDirectory: indexDirectory, ownerUID: ownerUID, maintenance: maintenance
        ) {
            [weak self] bytes, location in
            guard let self else { throw TractandaError("unsafeAttachmentStore", "Payload storage closed.") }
            try self.ensureReserve(forAdditionalBytes: bytes, at: location)
        }
    }

    /// Creates an empty server-owned upload stage. The upload ID is a validated UUIDv1 and is
    /// separate from the user-supplied display filename.
    func createStaging(id: String, onCreated: () -> Void = {}) throws {
        try CanonicalMaintenanceContext.deny(
            root: root, path: ["attachments", ".staging", id], operation: "payload stage creation")
        try Self.validateID(id)
        try ensureReserve(forAdditionalBytes: UInt64(Self.pathComponentLimit))
        guard try resolvedPayloadPath(id) == nil else {
            throw TractandaError("identifierCollision", "Attachment ID already names a published payload.")
        }
        let directory = try openDirectoryChain(components: ["attachments", ".staging"], create: true)
        defer { closeAll(directory) }
        try ensureReserve(forAdditionalBytes: UInt64(Self.pathComponentLimit), descriptor: directory.last!)
        let name = Self.stageName(id)
        let descriptor = name.withCString {
            openat(
                directory.last!, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                Self.stagingMode)
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw TractandaError("uploadExists", "An attachment upload with this ID already exists.")
            }
            throw Self.posix("Cannot create attachment upload stage.")
        }
        defer { _ = close(descriptor) }
        onCreated()
        guard fsync(descriptor) == 0, fsync(directory.last!) == 0 else {
            throw Self.posix("Cannot synchronize attachment upload stage.")
        }
    }

    /// Appends one bounded chunk or accepts a byte-identical retry at an earlier offset.
    @discardableResult
    func append(id: String, offset: Int64, data: Data) throws -> Int64 {
        try CanonicalMaintenanceContext.deny(
            root: root, path: ["attachments", ".staging", id], operation: "payload stage write")
        try Self.validateID(id)
        guard offset >= 0, data.count <= chunkByteLimit else {
            throw TractandaError("resourceLimit", "Attachment chunks are limited to 256 KiB.")
        }
        let directories = try openDirectoryChain(components: ["attachments", ".staging"], create: false)
        defer { closeAll(directories) }
        let name = Self.stageName(id)
        let descriptor = try openRegularFile(
            in: directories.last!, name: name, flags: O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            expectedMode: Self.stagingMode)
        defer { _ = close(descriptor) }
        let metadata = try Self.metadata(for: descriptor)
        guard metadata.size <= UInt64(fileByteLimit), let currentSize = Int64(exactly: metadata.size) else {
            throw TractandaError(
                "resourceLimit", "Attachment exceeds its configured storage or addressability limit.")
        }
        let (end, overflow) = offset.addingReportingOverflow(Int64(data.count))
        guard !overflow, end <= fileByteLimit else {
            throw TractandaError(
                "resourceLimit", "Attachment exceeds its configured storage or addressability limit.")
        }
        if offset < currentSize {
            guard end <= currentSize else {
                throw TractandaError("uploadOffsetMismatch", "Attachment retry overlaps unwritten bytes.")
            }
            let existing = try Self.readExactly(descriptor: descriptor, offset: offset, count: data.count)
            guard existing == data else {
                throw TractandaError(
                    "uploadMismatch", "Retried attachment bytes differ from the staged bytes.")
            }
            return currentSize
        }
        guard offset == currentSize else {
            throw TractandaError("uploadOffsetMismatch", "Attachment chunks must be sequential.")
        }
        if data.isEmpty { return currentSize }
        try ensureReserve(forAdditionalBytes: UInt64(data.count), descriptor: descriptor)
        // Reserve before the bounded write; failures conservatively retain the charged bytes
        // until startup reconstructs actual sizes or the stage is durably disposed.
        try stagingQuota?.charge(data.count, path: ["attachments", ".staging", name])
        try Self.writeAll(descriptor: descriptor, offset: offset, data: data)
        guard fsync(descriptor) == 0 else {
            throw Self.posix("Cannot synchronize attachment upload bytes.")
        }
        let after = try Self.metadata(for: descriptor)
        guard after.type == .regular, after.size == UInt64(end), after.inode == metadata.inode,
            after.uid == ownerUID, after.mode & 0o777 == UInt32(Self.stagingMode)
        else { throw TractandaError("uploadMismatch", "Attachment stage changed during append.") }
        return end
    }

    func stagedSize(id: String) throws -> Int64 {
        try Self.validateID(id)
        let directories = try openDirectoryChain(components: ["attachments", ".staging"], create: false)
        defer { closeAll(directories) }
        let descriptor = try Self.openFile(
            in: directories.last!, name: Self.stageName(id),
            flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        defer { _ = close(descriptor) }
        let metadata = try Self.metadata(for: descriptor)
        guard Self.validStagingMetadata(metadata, allowSealed: true, ownerUID: ownerUID),
            let size = Int64(exactly: metadata.size), size <= fileByteLimit
        else {
            throw TractandaError(
                "resourceLimit", "Attachment exceeds its configured storage or addressability limit.")
        }
        return size
    }

    /// Publishes a verified staged payload without replacing an existing immutable attachment.
    /// Linking the same inode into the payload tree avoids an unbounded duplicate copy.
    func publish(
        descriptor attachment: AttachmentDescriptor, requireVerifiedStage: Bool = false,
        stageID: String? = nil
    ) throws {
        let stageID = stageID ?? attachment.attachmentID
        try Self.validateID(stageID)
        _ = try Self.validated(attachment)
        try placement.publish(attachment, recover: recoverPlacement, reconcile: reconcilePlacement) {
            path, existing in
            if !existing {
                try CanonicalReaderRequirement.beforePayloadPlacementPublication(
                    root: root, ownerUID: ownerUID)
            }
            try publishAt(
                descriptor: attachment, path: path, existing: existing,
                requireVerifiedStage: requireVerifiedStage, stageID: stageID)
        }
    }

    private func publishAt(
        descriptor attachment: AttachmentDescriptor, path: String, existing: Bool, requireVerifiedStage: Bool,
        stageID: String
    ) throws {
        let payloadDirectories = try openDirectoryChain(
            components: Array(path.split(separator: "/").map(String.init).dropLast()), create: !existing)
        defer { closeAll(payloadDirectories) }
        let payloadParent = payloadDirectories.last!
        let payloadName = Self.payloadName(attachment.attachmentID)
        if let existing = try? Self.openFile(
            in: payloadParent, name: payloadName, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        {
            defer { _ = close(existing) }
            if requireVerifiedStage {
                guard cached(attachment, metadata: try Self.metadata(for: existing)) != nil else {
                    throw TractandaError(
                        "attachmentVerifying", "Published original integrity verification is pending.")
                }
            } else {
                try verifyPayload(attachment, descriptor: existing, cacheResult: true)
            }
            guard fsync(payloadParent) == 0, tractanda_durable_sync(existing) == 0 else {
                throw Self.posix("Cannot synchronize attachment payload directory.")
            }
            try discardStaging(id: stageID)
            return
        }

        let stagingDirectories = try openDirectoryChain(
            components: ["attachments", ".staging"], create: false)
        defer { closeAll(stagingDirectories) }
        let stagingParent = stagingDirectories.last!
        let stageName = Self.stageName(stageID)
        try CanonicalMaintenanceContext.deny(
            root: root, path: ["attachments", "payloads", attachment.attachmentID],
            operation: "payload publication")
        let staged = try Self.openFile(
            in: stagingParent, name: stageName, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        defer { _ = close(staged) }
        let before = try Self.metadata(for: staged)
        guard Self.validStagingMetadata(before, allowSealed: true, ownerUID: ownerUID),
            before.size == UInt64(attachment.byteCount), before.size <= UInt64(fileByteLimit)
        else {
            throw TractandaError("uploadMismatch", "Attachment byte count does not match its descriptor.")
        }
        let digest: String
        if requireVerifiedStage {
            guard cached(attachment, metadata: before) != nil else {
                throw TractandaError(
                    "attachmentVerifying", "Staged original integrity verification is pending.")
            }
            digest = attachment.sha256
        } else {
            recordDigestPass()
            digest = try Self.sha256(descriptor: staged, byteCount: before.size, chunkLimit: chunkByteLimit)
        }
        let afterHash = try Self.metadata(for: staged)
        guard before == afterHash, digest == attachment.sha256 else {
            throw TractandaError("attachmentIntegrity", "Attachment stage failed size or digest validation.")
        }
        let stagedMode = before.mode & 0o777
        guard stagedMode == UInt32(Self.stagingMode) || stagedMode == UInt32(Self.publishedMode),
            stagedMode == UInt32(Self.publishedMode) || fchmod(staged, Self.publishedMode) == 0,
            tractanda_durable_sync(staged) == 0
        else {
            throw Self.posix("Cannot make attachment payload immutable.")
        }
        let publishedMetadata = try Self.metadata(for: staged)
        guard Self.validPublishedMetadata(publishedMetadata, descriptor: attachment, ownerUID: ownerUID)
        else {
            throw TractandaError(
                "attachmentIntegrity", "Attachment stage metadata changed before publication.")
        }
        guard try Self.metadata(for: payloadParent).device == publishedMetadata.device else {
            throw TractandaError(
                "unsupportedPayloadFilesystem",
                "Private stage and current payload destination must share a filesystem for immutable no-copy publication."
            )
        }
        let linkResult = stageName.withCString { sourceName in
            payloadName.withCString { destinationName in
                linkat(stagingParent, sourceName, payloadParent, destinationName, 0)
            }
        }
        if linkResult != 0 {
            if errno == EEXIST,
                let existing = try? Self.openFile(
                    in: payloadParent, name: payloadName,
                    flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            {
                defer { _ = close(existing) }
                try verifyPayload(attachment, descriptor: existing, cacheResult: true)
                guard fsync(payloadParent) == 0, tractanda_durable_sync(existing) == 0 else {
                    throw Self.posix("Cannot synchronize attachment payload directory.")
                }
                try discardStaging(id: stageID)
                return
            }
            throw Self.posix("Cannot publish attachment payload.")
        }
        // If this sync fails, the immutable name may already exist. A retry validates it and
        // synchronizes the directory before acknowledging publication.
        guard fsync(payloadParent) == 0, tractanda_durable_sync(staged) == 0 else {
            throw Self.posix("Cannot synchronize published attachment payload.")
        }
        guard stageName.withCString({ unlinkat(stagingParent, $0, 0) }) == 0,
            fsync(stagingParent) == 0
        else { throw Self.posix("Cannot clear published attachment stage.") }
        stagingQuota?.release(path: ["attachments", ".staging", stageName])
        putCached(attachment, metadata: publishedMetadata)
    }

    /// Validates identity, exact size, private ownership/mode and a streamed SHA-256 digest.
    func validate(
        descriptor attachment: AttachmentDescriptor, progress: @Sendable (Int64) throws -> Void = { _ in }
    ) throws {
        _ = try Self.validated(attachment)
        let files = try openPayloadFile(id: attachment.attachmentID)
        defer { closeAll(files) }
        try verifyPayload(attachment, descriptor: files.last!, cacheResult: true, progress: progress)
    }

    /// A private validator has no placement database and cannot escape via a replaced root path.
    private init(inventoryRoot: URL, ownerUID: UInt32) {
        root = inventoryRoot
        self.ownerUID = ownerUID
        stagingQuota = nil
        reserveBytes = Self.defaultReserveBytes
        availableBytesOverride = nil
        fileByteLimit = Self.maximumFileBytes
        chunkByteLimit = Self.maximumChunkBytes
    }

    /// Descriptor-anchored offline reads never open/rebuild placement SQLite or mutate payloads.
    static func validateForInventory(
        _ attachment: AttachmentDescriptor, path: String, root: URL, rootDescriptor: Int32,
        ownerUID: UInt32, readBudget: @escaping (Int) throws -> Void,
        progress: @Sendable (Int64) throws -> Void = { _ in }
    ) throws {
        _ = try Self.validated(attachment)
        try PayloadPlacement.validate(path, id: attachment.attachmentID)
        let components = path.split(separator: "/").map(String.init)
        var descriptors: [Int32] = []
        defer { for fd in descriptors.reversed() { _ = close(fd) } }
        var parent = rootDescriptor
        try Self.validateDirectory(parent, ownerUID: ownerUID)
        for component in components.dropLast() {
            let fd = component.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else { throw Self.posix("Cannot open selected payload directory.") }
            descriptors.append(fd)
            try Self.validateDirectory(fd, ownerUID: ownerUID)
            parent = fd
        }
        let fd = try Self.openFile(
            in: parent, name: components.last!, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        descriptors.append(fd)
        let validator = Self(inventoryRoot: root, ownerUID: ownerUID)
        try validator.verifyPayload(
            attachment, descriptor: fd, cacheResult: false, readBudget: readBudget, progress: progress)
    }

    /// Returns no more than one transfer chunk from an immutable payload.
    func read(
        descriptor attachment: AttachmentDescriptor, offset: Int64, limit: Int,
        requireVerified: Bool = false
    ) throws -> Data {
        _ = try Self.validated(attachment)
        guard offset >= 0, offset <= attachment.byteCount, limit >= 0, limit <= chunkByteLimit else {
            throw TractandaError("invalidArguments", "Attachment reads must be within a 256 KiB window.")
        }
        if !requireVerified { try validate(descriptor: attachment) }
        if limit == 0 || offset == attachment.byteCount { return Data() }
        for attempt in 0...1 {
            let files = try openPayloadFile(id: attachment.attachmentID)
            var descriptorsOpen = true
            defer { if descriptorsOpen { closeAll(files) } }
            let descriptor = files.last!
            do {
                let before = try Self.metadata(for: descriptor)
                guard
                    Self.validPublishedMetadata(
                        before, descriptor: attachment, ownerUID: ownerUID,
                        archived: Self.isArchived(descriptor))
                else {
                    throw TractandaError(
                        "attachmentIntegrity", "Attachment metadata does not match its descriptor.")
                }
                guard cached(attachment, metadata: before) != nil else {
                    closeAll(files)
                    descriptorsOpen = false
                    guard !requireVerified else {
                        throw TractandaError(
                            "attachmentVerifying", "Original integrity verification is pending.")
                    }
                    try validate(descriptor: attachment)
                    continue
                }
                let amount = Int(min(Int64(limit), attachment.byteCount - offset))
                let bytes = try Self.readExactly(descriptor: descriptor, offset: offset, count: amount)
                let after = try Self.metadata(for: descriptor)
                guard before == after, cached(attachment, metadata: after) != nil else {
                    invalidate(attachment.attachmentID)
                    closeAll(files)
                    descriptorsOpen = false
                    if attempt == 0 && !requireVerified {
                        try validate(descriptor: attachment)
                        continue
                    }
                    throw TractandaError("attachmentIntegrity", "Attachment changed during a bounded read.")
                }
                closeAll(files)
                descriptorsOpen = false
                return bytes
            } catch {
                throw error
            }
        }
        throw TractandaError("attachmentIntegrity", "Attachment could not be stabilized for reading.")
    }

    /// Copies an immutable payload to a new UUIDv1 identity using only bounded chunks.
    func clone(
        source attachment: AttachmentDescriptor, newID: String, publish: Bool = true, resume: Bool = false,
        progress: @Sendable (Int64) -> Void = { _ in }
    ) throws -> AttachmentDescriptor {
        _ = try Self.validated(attachment)
        try Self.validateID(newID)
        guard newID != attachment.attachmentID else {
            throw TractandaError("invalidAttachment", "A cloned attachment needs a new identity.")
        }
        try validate(descriptor: attachment)
        do { try createStaging(id: newID) } catch let error as TractandaError
            where resume && error.code == "uploadExists"
        {}
        let resumedBytes = try stagedSize(id: newID)
        guard resumedBytes <= attachment.byteCount else {
            throw TractandaError("attachmentIntegrity", "Copy stage exceeds its original.")
        }
        do {
            let files = try openPayloadFile(id: attachment.attachmentID)
            defer { closeAll(files) }
            let descriptor = files.last!
            let before = try Self.metadata(for: descriptor)
            guard
                Self.validPublishedMetadata(
                    before, descriptor: attachment, ownerUID: ownerUID, archived: Self.isArchived(descriptor))
            else {
                throw TractandaError(
                    "attachmentIntegrity", "Source attachment metadata changed during clone.")
            }
            var offset: Int64 = 0
            while offset < attachment.byteCount {
                let boundary = offset < resumedBytes ? resumedBytes : attachment.byteCount
                let amount = Int(min(Int64(chunkByteLimit), boundary - offset))
                let chunk = try Self.readExactly(descriptor: descriptor, offset: offset, count: amount)
                _ = try append(id: newID, offset: offset, data: chunk)
                offset += Int64(amount)
                progress(offset)
            }
            guard try Self.metadata(for: descriptor) == before else {
                throw TractandaError("attachmentIntegrity", "Source attachment changed during clone.")
            }
            let copy = try AttachmentDescriptor(
                attachmentID: newID, filename: attachment.filename, mediaType: attachment.mediaType,
                byteCount: attachment.byteCount, sha256: attachment.sha256)
            if publish {
                try self.publish(descriptor: copy)
            } else {
                try verifyStagedOriginal(copy, progress: { _ in })
            }
            return copy
        } catch {
            if !resume { try? discardStaging(id: newID) }
            throw error
        }
    }

    /// Removes unpublished stages only. Names are validated and unlinkat never follows a link.
    func clearStaging() throws {
        let directories = try openDirectoryChain(
            components: ["attachments", ".staging"], create: false, missingIsEmpty: true)
        guard !directories.isEmpty else { return }
        defer { closeAll(directories) }
        let stagingFD = directories.last!
        let stagingURL = root.appendingPathComponent("attachments/.staging", isDirectory: true)
        try POSIXDirectory.withEntries(at: stagingURL) { name in
            guard name.hasSuffix(".stage") else {
                throw TractandaError(
                    "unsafeAttachmentStore", "Unexpected entry in attachment staging directory.")
            }
            let id = String(name.dropLast(".stage".count))
            try Self.validateID(id)
            try CanonicalMaintenanceContext.deny(
                root: root, path: ["attachments", ".staging", name], operation: "payload stage deletion")
            let status = name.withCString { unlinkat(stagingFD, $0, 0) }
            guard status == 0 || errno == ENOENT else {
                throw Self.posix("Cannot clear attachment upload stage.")
            }
            return true
        }
        guard fsync(stagingFD) == 0 else {
            throw Self.posix("Cannot synchronize attachment staging cleanup.")
        }
    }

    func discardStaging(id: String) throws {
        try Self.validateID(id)
        let directories = try openDirectoryChain(components: ["attachments", ".staging"], create: false)
        defer { closeAll(directories) }
        let name = Self.stageName(id)
        try CanonicalMaintenanceContext.deny(
            root: root, path: ["attachments", ".staging", name], operation: "payload stage deletion",
            onlyIfPresent: true)
        let status = name.withCString { unlinkat(directories.last!, $0, 0) }
        guard status == 0 || errno == ENOENT else {
            throw Self.posix("Cannot discard attachment upload stage.")
        }
        guard fsync(directories.last!) == 0 else {
            throw Self.posix("Cannot synchronize attachment stage removal.")
        }
        stagingQuota?.release(path: ["attachments", ".staging", name])
    }

    // Test-only path permits tiny, isolated symlink/corruption cases without exposing a URL publicly.
    func payloadURL(for attachmentID: String) throws -> URL {
        try Self.validateID(attachmentID)
        guard let path = try resolvedPayloadPath(attachmentID) else {
            throw TractandaError("attachmentIntegrity", "Original is missing.")
        }
        return root.appendingPathComponent(path)
    }

    func stagingURLForTesting(id: String) throws -> URL {
        try Self.validateID(id)
        return root.appendingPathComponent("attachments/.staging/\(Self.stageName(id))")
    }

    func preparePlacement() throws {
        do { try placement.prepare(recover: recoverPlacement, reconcile: reconcilePlacement) } catch let error
            as TractandaError where error.code == "payloadIndexRecoveryRequired"
        {
            try rebuildPlacement()
        }
    }

    func rebuildPlacement() throws {
        try placement.rebuild(recover: recoverPlacement, reconcile: reconcilePlacement)
    }

    func truncatePeerUnacknowledgedTail(stageID: String, to offset: Int64) throws {
        try CanonicalMaintenanceContext.deny(
            root: root, path: ["attachments", ".staging", stageID], operation: "payload truncation")
        try Self.validateID(stageID)
        let chain = try openDirectoryChain(components: ["attachments", ".staging"], create: false)
        defer { closeAll(chain) }
        let fd = try openRegularFile(
            in: chain.last!, name: Self.stageName(stageID),
            flags: O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, expectedMode: Self.stagingMode)
        defer { _ = close(fd) }
        let before = try Self.metadata(for: fd)
        guard offset >= 0, UInt64(offset) <= before.size,
            before.size - UInt64(offset) < UInt64(Self.maximumChunkBytes),
            ftruncate(fd, off_t(offset)) == 0, fsync(fd) == 0,
            try Self.metadata(for: fd).size == UInt64(offset)
        else {
            throw TractandaError("peerObjectCollision", "Cannot repair unacknowledged private peer tail.")
        }
        stagingQuota?.refund(
            Int(before.size - UInt64(offset)), path: ["attachments", ".staging", Self.stageName(stageID)])
    }

    func peerStage(_ stageID: String, maximumBytes: Int64) throws -> PeerOriginalFile {
        try Self.validateID(stageID)
        let directories = try openDirectoryChain(components: ["attachments", ".staging"], create: false)
        do {
            let fd = try Self.openFile(
                in: directories.last!, name: Self.stageName(stageID),
                flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            let chain = directories + [fd]
            do {
                let metadata = try Self.metadata(for: fd)
                guard maximumBytes >= 0, metadata.size <= UInt64(maximumBytes),
                    Self.validStagingMetadata(metadata, allowSealed: true, ownerUID: ownerUID)
                else {
                    throw TractandaError("attachmentIntegrity", "Peer stage metadata differs.")
                }
                return PeerOriginalFile(
                    metadata: metadata, descriptors: chain,
                    read: { offset, count in
                        try Self.readExactly(descriptor: fd, offset: offset, count: count)
                    },
                    validate: {
                        guard try Self.metadata(for: fd) == metadata else {
                            throw TractandaError("attachmentIntegrity", "Peer stage changed.")
                        }
                    })
            } catch {
                _ = close(fd)
                throw error
            }
        } catch {
            closeAll(directories)
            throw error
        }
    }
    func peerStoredFile(id: String, byteCount: Int64) throws -> PeerOriginalFile {
        let chain = try openPayloadFile(id: id)
        do {
            let fd = chain.last!
            let metadata = try Self.metadata(for: fd)
            guard byteCount >= 0, metadata.size == UInt64(byteCount), metadata.type == .regular,
                Self.isArchived(fd)
                    || (metadata.uid == ownerUID && metadata.mode & 0o777 == UInt32(Self.publishedMode))
            else {
                throw TractandaError("attachmentIntegrity", "Peer stored original metadata differs.")
            }
            return PeerOriginalFile(
                metadata: metadata, descriptors: chain,
                read: { offset, count in try Self.readExactly(descriptor: fd, offset: offset, count: count) },
                validate: {
                    guard try Self.metadata(for: fd) == metadata else {
                        throw TractandaError("attachmentIntegrity", "Peer stored original changed.")
                    }
                })
        } catch {
            closeAll(chain)
            throw error
        }
    }

    /// Retained descriptor for bounded peer verification; no pathname crosses the peer protocol.
    func peerOriginal(_ attachment: AttachmentDescriptor, stageID: String? = nil) throws -> PeerOriginalFile {
        let chain: [Int32]
        if let stageID {
            try Self.validateID(stageID)
            let directories = try openDirectoryChain(components: ["attachments", ".staging"], create: false)
            do {
                let fd = try Self.openFile(
                    in: directories.last!, name: Self.stageName(stageID),
                    flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                chain = directories + [fd]
            } catch {
                closeAll(directories)
                throw error
            }
        } else {
            chain = try openPayloadFile(id: attachment.attachmentID)
        }
        do {
            let fd = chain.last!
            let metadata = try Self.metadata(for: fd)
            guard metadata.size == UInt64(attachment.byteCount),
                stageID != nil
                    ? Self.validStagingMetadata(metadata, allowSealed: true, ownerUID: ownerUID)
                    : Self.validPublishedMetadata(
                        metadata, descriptor: attachment, ownerUID: ownerUID, archived: Self.isArchived(fd))
            else {
                throw TractandaError("attachmentIntegrity", "Peer original metadata differs.")
            }
            return PeerOriginalFile(
                metadata: metadata, descriptors: chain,
                read: { offset, count in try Self.readExactly(descriptor: fd, offset: offset, count: count) },
                validate: {
                    guard try Self.metadata(for: fd) == metadata else {
                        throw TractandaError(
                            "attachmentIntegrity", "Peer original changed during verification.")
                    }
                })
        } catch {
            closeAll(chain)
            throw error
        }
    }
    func rememberPeerVerification(_ attachment: AttachmentDescriptor, metadata: FileMetadata) {
        putCached(attachment, metadata: metadata)
    }

    func resolvedPayloadPath(_ id: String) throws -> String? {
        try Self.validateID(id)
        return try placement.path(id: id, recover: recoverPlacement, reconcile: reconcilePlacement)
    }

    private func openPayloadFile(id: String) throws -> [Int32] {
        guard let path = try resolvedPayloadPath(id) else {
            throw TractandaError("attachmentIntegrity", "Attachment original is missing.")
        }
        return try openPayloadFile(path: path, id: id)
    }

    private func openPayloadFile(path: String, id: String) throws -> [Int32] {
        try PayloadPlacement.validate(path, id: id)
        let directories = try openDirectoryChain(
            components: Array(path.split(separator: "/").map(String.init).dropLast()), create: false)
        do {
            let descriptor = try Self.openFile(
                in: directories.last!, name: Self.payloadName(id),
                flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            return directories + [descriptor]
        } catch {
            closeAll(directories)
            throw error
        }
    }

    private func reconcilePlacement(_ attachment: AttachmentDescriptor, path: String) throws -> Bool {
        let url = root.appendingPathComponent(path)
        do { _ = try FileMetadata.read(at: url) } catch FileMetadataError.posix(ENOENT) { return false }
        let descriptors = try openPayloadFile(path: path, id: attachment.attachmentID)
        defer { closeAll(descriptors) }
        try verifyPayload(attachment, descriptor: descriptors.last!, cacheResult: true)
        guard fsync(descriptors[descriptors.count - 2]) == 0,
            tractanda_durable_sync(descriptors.last!) == 0
        else {
            throw Self.posix("Cannot synchronize recovered original publication.")
        }
        return true
    }

    private func recoverPlacement(_ visit: (String, String) throws -> Void) throws {
        func walk(_ components: [String]) throws {
            try Task.checkCancellation()
            let directories = try openDirectoryChain(
                components: components, create: false, missingIsEmpty: true)
            guard let parent = directories.last else { return }
            defer { closeAll(directories) }
            try POSIXDirectory.withEntries(descriptor: parent) { name in
                let relative = components + [name]
                let url = relative.reduce(root) { $0.appendingPathComponent($1) }
                let metadata = try FileMetadata.read(at: url)
                if components.count < 7 {
                    guard metadata.type == .directory, name.count == (components.count == 2 ? 4 : 2),
                        name.utf8.allSatisfy({ (48...57).contains($0) })
                    else {
                        throw TractandaError("unsafeAttachmentStore", "Unsafe payload archive directory.")
                    }
                    try walk(relative)
                } else {
                    guard name.hasSuffix(".payload") else {
                        throw TractandaError("unsafeAttachmentStore", "Unknown payload archive file.")
                    }
                    let id = String(name.dropLast(8))
                    let path = relative.joined(separator: "/")
                    try Self.validateID(id)
                    try PayloadPlacement.validate(path, id: id)
                    let files = try openPayloadFile(path: path, id: id)
                    defer { closeAll(files) }
                    let before = try Self.metadata(for: files.last!)
                    guard before.type == .regular, before.size <= UInt64(Self.maximumFileBytes),
                        Self.isArchived(files.last!)
                            || (before.uid == ownerUID && before.mode & 0o777 == UInt32(Self.publishedMode))
                    else {
                        throw TractandaError("attachmentIntegrity", "Unsafe recovered original metadata.")
                    }
                    _ = try Self.sha256(
                        descriptor: files.last!, byteCount: before.size, chunkLimit: chunkByteLimit)
                    guard try Self.metadata(for: files.last!) == before else {
                        throw TractandaError("attachmentIntegrity", "Recovered original changed.")
                    }
                    if !Self.isArchived(files.last!) {
                        guard fsync(parent) == 0, tractanda_durable_sync(files.last!) == 0 else {
                            throw Self.posix("Cannot confirm recovered original durability.")
                        }
                    }
                    try visit(id, path)
                }
                return true
            }
        }
        try walk(["attachments", "payloads"])
    }

    private func openDirectoryChain(
        components: [String], create: Bool, missingIsEmpty: Bool = false
    ) throws -> [Int32] {
        guard !components.isEmpty, components.allSatisfy(Self.isSafeComponent) else {
            throw TractandaError("unsafeAttachmentStore", "Invalid internal attachment path.")
        }
        let rootPath = root.path
        guard rootPath.hasPrefix("/"), rootPath != "/", !rootPath.utf8.contains(0) else {
            throw TractandaError("unsafeAttachmentStore", "Invalid attachment root.")
        }
        let rootFD = rootPath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else { throw Self.posix("Cannot open canonical attachment root.") }
        var descriptors: [Int32] = [rootFD]
        do {
            try Self.validateDirectory(rootFD, ownerUID: ownerUID)
            var walked = [String]()
            for component in components {
                walked.append(component)
                let parent = descriptors.last!
                var child = component.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if child < 0 && errno == ENOENT && create {
                    try CanonicalMaintenanceContext.deny(
                        root: root, path: walked, operation: "payload directory creation")
                    try ensureReserve(forAdditionalBytes: UInt64(Self.pathComponentLimit), descriptor: parent)
                    let made = component.withCString {
                        mkdirat(parent, $0, Self.privateDirectoryMode)
                    }
                    if made != 0 && errno != EEXIST {
                        throw Self.posix("Cannot create private attachment directory.")
                    }
                    guard fsync(parent) == 0 else {
                        throw Self.posix("Cannot synchronize attachment directory creation.")
                    }
                    child = component.withCString {
                        openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                }
                guard child >= 0 else {
                    if errno == ENOENT, missingIsEmpty {
                        closeAll(descriptors)
                        return []
                    }
                    throw TractandaError(
                        "unsafeAttachmentStore", "Attachment directory is missing or unsafe.")
                }
                try Self.validateDirectory(child, ownerUID: ownerUID)
                descriptors.append(child)
            }
            return descriptors
        } catch {
            closeAll(descriptors)
            throw error
        }
    }

    private func openRegularFile(
        in directory: Int32, name: String, flags: Int32, expectedMode: mode_t
    ) throws -> Int32 {
        let descriptor = try Self.openFile(in: directory, name: name, flags: flags)
        do {
            let metadata = try Self.metadata(for: descriptor)
            guard metadata.type == .regular, metadata.uid == ownerUID,
                metadata.mode & 0o777 == UInt32(expectedMode)
            else { throw TractandaError("unsafeAttachmentStore", "Attachment stage file is unsafe.") }
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private func ensureReserve(
        forAdditionalBytes bytes: UInt64, at location: URL? = nil, descriptor: Int32? = nil
    ) throws {
        let available: UInt64
        if let availableBytesOverride {
            do { available = try availableBytesOverride() } catch {
                throw TractandaError("resourceLimit", "Cannot determine attachment filesystem capacity.")
            }
        } else {
            var status = statvfs()
            let target = location ?? root
            let result =
                descriptor.map { fstatvfs($0, &status) } ?? target.path.withCString { statvfs($0, &status) }
            guard result == 0, status.f_bavail >= 0, status.f_frsize > 0
            else {
                throw TractandaError("resourceLimit", "Cannot determine attachment filesystem capacity.")
            }
            let (value, overflow) = UInt64(status.f_bavail)
                .multipliedReportingOverflow(by: UInt64(status.f_frsize))
            guard !overflow else {
                throw TractandaError("resourceLimit", "Cannot determine attachment filesystem capacity.")
            }
            available = value
        }
        let (required, overflow) = UInt64(reserveBytes).addingReportingOverflow(bytes)
        guard !overflow, available >= required else {
            throw TractandaError(
                "resourceLimit", "Attachment write would cross its filesystem-available reserve.")
        }
    }

    private func verifyPayload(
        _ attachment: AttachmentDescriptor, descriptor: Int32, cacheResult: Bool,
        readBudget: ((Int) throws -> Void)? = nil, progress: @Sendable (Int64) throws -> Void = { _ in }
    ) throws {
        let before = try Self.metadata(for: descriptor)
        guard
            Self.validPublishedMetadata(
                before, descriptor: attachment, ownerUID: ownerUID, archived: Self.isArchived(descriptor))
        else {
            invalidate(attachment.attachmentID)
            throw TractandaError(
                "attachmentIntegrity", "Attachment payload metadata does not match its descriptor.")
        }
        if cached(attachment, metadata: before) != nil {
            try progress(attachment.byteCount)
            return
        }
        recordDigestPass()
        let digest = try Self.sha256(
            descriptor: descriptor, byteCount: before.size, chunkLimit: chunkByteLimit,
            readBudget: readBudget, progress: progress)
        let after = try Self.metadata(for: descriptor)
        guard before == after, digest == attachment.sha256 else {
            invalidate(attachment.attachmentID)
            throw TractandaError("attachmentIntegrity", "Attachment payload checksum does not match.")
        }
        if cacheResult { putCached(attachment, metadata: after) }
    }

    private func cached(_ attachment: AttachmentDescriptor, metadata: FileMetadata) -> VerifiedSignature? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let value = verified[attachment.attachmentID], value.descriptor == attachment,
            value.metadata == metadata
        else { return nil }
        verifiedOrder.removeAll { $0 == attachment.attachmentID }
        verifiedOrder.append(attachment.attachmentID)
        return value
    }

    private func putCached(_ attachment: AttachmentDescriptor, metadata: FileMetadata) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        verified.removeValue(forKey: attachment.attachmentID)
        verifiedOrder.removeAll { $0 == attachment.attachmentID }
        while verifiedOrder.count >= Self.cacheEntryLimit, let oldest = verifiedOrder.first {
            verifiedOrder.removeFirst()
            verified.removeValue(forKey: oldest)
        }
        verified[attachment.attachmentID] = VerifiedSignature(descriptor: attachment, metadata: metadata)
        verifiedOrder.append(attachment.attachmentID)
    }

    private func invalidate(_ id: String) {
        cacheLock.lock()
        verified.removeValue(forKey: id)
        verifiedOrder.removeAll { $0 == id }
        cacheLock.unlock()
    }

    private func recordDigestPass() {
        cacheLock.lock()
        digestPassCount += 1
        cacheLock.unlock()
    }

    private func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors.reversed() { _ = close(descriptor) }
    }

    private static func validated(_ attachment: AttachmentDescriptor) throws -> AttachmentDescriptor {
        try AttachmentDescriptor(
            attachmentID: attachment.attachmentID, filename: attachment.filename,
            mediaType: attachment.mediaType, byteCount: attachment.byteCount, sha256: attachment.sha256)
    }

    private static func validateID(_ id: String) throws {
        try Identifier.validate(id)
        guard UUID(uuidString: id)?.version1Components != nil else {
            throw TractandaError("invalidAttachment", "Attachment ID must be a canonical UUIDv1.")
        }
    }

    private static func stageName(_ id: String) -> String { id + ".stage" }
    private static func payloadName(_ id: String) -> String { id + ".payload" }
    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.utf8.contains(0)
    }

    private static func openFile(in directory: Int32, name: String, flags: Int32) throws -> Int32 {
        guard isSafeComponent(name) else {
            throw TractandaError("unsafeAttachmentStore", "Invalid attachment filename.")
        }
        let descriptor = name.withCString { openat(directory, $0, flags) }
        guard descriptor >= 0 else {
            throw TractandaError(
                "attachmentIntegrity", "Attachment file is missing or is not a regular file.", osError: errno)
        }
        return descriptor
    }

    private static func isArchived(_ descriptor: Int32) -> Bool {
        var status = statvfs()
        return fstatvfs(descriptor, &status) == 0 && status.f_flag & UInt(ST_RDONLY) != 0
    }

    private static func validateDirectory(_ descriptor: Int32, ownerUID: UInt32) throws {
        let metadata = try self.metadata(for: descriptor)
        guard metadata.type == .directory,
            isArchived(descriptor) || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0)
        else {
            throw TractandaError(
                "unsafeAttachmentStore", "Attachment directories must be private and owner-owned.")
        }
    }

    private static func validPublishedMetadata(
        _ metadata: FileMetadata, descriptor: AttachmentDescriptor, ownerUID: UInt32, archived: Bool = false
    ) -> Bool {
        metadata.type == .regular
            && (archived
                || (metadata.uid == ownerUID
                    && metadata.mode & 0o777 == UInt32(publishedMode)))
            && metadata.size == UInt64(descriptor.byteCount)
            && metadata.size <= UInt64(maximumFileBytes)
    }

    private static func validStagingMetadata(
        _ metadata: FileMetadata, allowSealed: Bool, ownerUID: UInt32
    ) -> Bool {
        let mode = metadata.mode & 0o777
        return metadata.type == .regular && metadata.uid == ownerUID
            && (mode == UInt32(stagingMode) || (allowSealed && mode == UInt32(publishedMode)))
    }

    private static func metadata(for descriptor: Int32) throws -> FileMetadata {
        var raw = stat()
        guard fstat(descriptor, &raw) == 0 else { throw posix("Cannot inspect attachment descriptor.") }
        #if canImport(Darwin)
            let seconds = Int64(raw.st_mtimespec.tv_sec)
            let nanoseconds = Int32(raw.st_mtimespec.tv_nsec)
        #else
            let seconds = Int64(raw.st_mtim.tv_sec)
            let nanoseconds = Int32(raw.st_mtim.tv_nsec)
        #endif
        guard raw.st_size >= 0 else {
            throw TractandaError("attachmentIntegrity", "Attachment descriptor has invalid size.")
        }
        return FileMetadata(
            mode: UInt32(raw.st_mode), uid: UInt32(raw.st_uid), gid: UInt32(raw.st_gid),
            size: UInt64(raw.st_size), inode: UInt64(raw.st_ino), device: UInt64(raw.st_dev),
            modificationSeconds: seconds, modificationNanoseconds: nanoseconds)
    }

    private static func sha256(
        descriptor: Int32, byteCount: UInt64, chunkLimit: Int,
        readBudget: ((Int) throws -> Void)? = nil, progress: @Sendable (Int64) throws -> Void = { _ in }
    ) throws -> String {
        guard byteCount <= UInt64(maximumFileBytes) else {
            throw TractandaError(
                "resourceLimit", "Attachment exceeds its configured storage or addressability limit.")
        }
        var hasher = SHA256()
        var offset: Int64 = 0
        while UInt64(offset) < byteCount {
            let count = Int(min(UInt64(chunkLimit), byteCount - UInt64(offset)))
            try Task.checkCancellation()
            try readBudget?(count)
            let bytes = try readExactly(descriptor: descriptor, offset: offset, count: count)
            hasher.update(data: bytes)
            offset += Int64(count)
            try progress(offset)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readExactly(descriptor: Int32, offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, count <= maximumChunkBytes else {
            throw TractandaError("resourceLimit", "Attachment reads are limited to 256 KiB.")
        }
        if count == 0 { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var completed = 0
        while completed < count {
            let result = buffer.withUnsafeMutableBytes { raw -> Int in
                #if canImport(Darwin)
                    Darwin.pread(
                        descriptor, raw.baseAddress!.advanced(by: completed), count - completed,
                        off_t(offset + Int64(completed)))
                #else
                    Glibc.pread(
                        descriptor, raw.baseAddress!.advanced(by: completed), count - completed,
                        off_t(offset + Int64(completed)))
                #endif
            }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else {
                throw TractandaError("attachmentIntegrity", "Attachment ended before the requested bytes.")
            }
            completed += result
        }
        return Data(buffer)
    }

    private static func writeAll(descriptor: Int32, offset: Int64, data: Data) throws {
        guard offset >= 0, data.count <= maximumChunkBytes else {
            throw TractandaError("resourceLimit", "Attachment chunks are limited to 256 KiB.")
        }
        try data.withUnsafeBytes { raw in
            var completed = 0
            while completed < raw.count {
                let result = pwrite(
                    descriptor, raw.baseAddress!.advanced(by: completed), raw.count - completed,
                    off_t(offset + Int64(completed)))
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw posix("Cannot write attachment chunk.") }
                completed += result
            }
        }
    }

    private static func posix(_ message: String) -> TractandaError {
        TractandaError("writeFailed", "\(message) \(String(cString: strerror(errno)))")
    }
}

extension AttachmentPayloadStore {
    /// Recovery records are private, bounded and atomically replaced through directory descriptors.
    @discardableResult
    func verifyStagedOriginal(_ attachment: AttachmentDescriptor, progress: @Sendable (Int64) -> Void) throws
        -> FileMetadata
    {
        if try publishedMetadataMatches(attachment) {
            let descriptors = try openPayloadFile(id: attachment.attachmentID)
            defer { closeAll(descriptors) }
            try verifyPayload(
                attachment, descriptor: descriptors.last!, cacheResult: true, progress: progress)
            return try Self.metadata(for: descriptors.last!)
        }
        let directories = try openDirectoryChain(components: ["attachments", ".staging"], create: false)
        defer { closeAll(directories) }
        let fd = try Self.openFile(
            in: directories.last!, name: Self.stageName(attachment.attachmentID),
            flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        defer { _ = close(fd) }
        let before = try Self.metadata(for: fd)
        guard Self.validStagingMetadata(before, allowSealed: true, ownerUID: ownerUID),
            before.size == UInt64(attachment.byteCount)
        else {
            throw TractandaError("uploadMismatch", "Staged original is incomplete or changed.")
        }
        recordDigestPass()
        let digest = try Self.sha256(
            descriptor: fd, byteCount: before.size, chunkLimit: chunkByteLimit, progress: progress)
        guard try Self.metadata(for: fd) == before, digest == attachment.sha256 else {
            throw TractandaError("attachmentIntegrity", "Staged original checksum does not match.")
        }
        putCached(attachment, metadata: before)
        return before
    }

    func restoreVerifiedSignature(_ attachment: AttachmentDescriptor, expected: FileMetadata) throws {
        let descriptors: [Int32]
        if try publishedMetadataMatches(attachment) {
            descriptors = try openPayloadFile(id: attachment.attachmentID)
        } else {
            let directories = try openDirectoryChain(components: ["attachments", ".staging"], create: false)
            do {
                let fd = try Self.openFile(
                    in: directories.last!, name: Self.stageName(attachment.attachmentID),
                    flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                descriptors = directories + [fd]
            } catch {
                closeAll(directories)
                throw error
            }
        }
        defer { closeAll(descriptors) }
        let actual = try Self.metadata(for: descriptors.last!)
        let sealed = FileMetadata(
            mode: (expected.mode & ~UInt32(0o777)) | UInt32(0o400), uid: expected.uid,
            gid: expected.gid, size: expected.size, inode: expected.inode, device: expected.device,
            modificationSeconds: expected.modificationSeconds,
            modificationNanoseconds: expected.modificationNanoseconds)
        guard actual == expected || actual == sealed else {
            throw TractandaError("attachmentIntegrity", "Verified copy signature changed before publication.")
        }
        putCached(attachment, metadata: actual)
    }

    func publishedMetadataMatches(_ attachment: AttachmentDescriptor) throws -> Bool {
        let files: [Int32]
        guard let path = try resolvedPayloadPath(attachment.attachmentID) else { return false }
        files = try openPayloadFile(path: path, id: attachment.attachmentID)
        defer { closeAll(files) }
        return Self.validPublishedMetadata(
            try Self.metadata(for: files.last!), descriptor: attachment, ownerUID: ownerUID,
            archived: Self.isArchived(files.last!))
    }

    func isStagedVerified(_ attachment: AttachmentDescriptor) throws -> Bool {
        if try isVerified(attachment) { return true }
        // A cold published original needs background revalidation, never a vanished stage.
        if try publishedMetadataMatches(attachment) { return false }
        let directories = try openDirectoryChain(components: ["attachments", ".staging"], create: false)
        defer { closeAll(directories) }
        let fd = try Self.openFile(
            in: directories.last!, name: Self.stageName(attachment.attachmentID),
            flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        defer { _ = close(fd) }
        let metadata = try Self.metadata(for: fd)
        return Self.validStagingMetadata(metadata, allowSealed: true, ownerUID: ownerUID)
            && metadata.size == UInt64(attachment.byteCount) && cached(attachment, metadata: metadata) != nil
    }

    func isVerified(_ attachment: AttachmentDescriptor) throws -> Bool {
        let files: [Int32]
        guard let path = try resolvedPayloadPath(attachment.attachmentID) else { return false }
        files = try openPayloadFile(path: path, id: attachment.attachmentID)
        defer { closeAll(files) }
        let metadata = try Self.metadata(for: files.last!)
        return Self.validPublishedMetadata(
            metadata, descriptor: attachment, ownerUID: ownerUID, archived: Self.isArchived(files.last!))
            && cached(attachment, metadata: metadata) != nil
    }

    func saveUpload(_ upload: AttachmentUploadState) throws {
        try CanonicalMaintenanceContext.deny(
            root: root, path: ["attachments", "uploads"], operation: "payload upload metadata write")
        try upload.validate()
        let data = try JSON.encode(upload)
        guard data.count <= StagingByteQuota.uploadCheckpointReservation else {
            throw TractandaError(
                "resourceLimit", "Upload recovery record exceeds its reserved 16 KiB bookkeeping window.")
        }
        try ensureReserve(forAdditionalBytes: UInt64(data.count))
        let chain = try openDirectoryChain(components: ["attachments", ".uploads"], create: true)
        defer { closeAll(chain) }
        let parent = chain.last!
        let id = upload.descriptor.attachmentID
        let temporary = id + "." + UUID().uuidString + ".tmp"
        let temporaryPath = ["attachments", ".uploads", temporary]
        let destination = id + ".json"
        try stagingQuota?.chargeCheckpoint(data.count, temporaryPath: temporaryPath, uploadID: id)
        let fd = temporary.withCString {
            openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else {
            stagingQuota?.release(path: temporaryPath)
            throw Self.posix("Cannot create upload recovery record.")
        }
        var replaced = false
        defer {
            _ = close(fd)
            let removed = temporary.withCString { unlinkat(parent, $0, 0) }
            if !replaced, removed == 0, fsync(parent) == 0 { stagingQuota?.release(path: temporaryPath) }
        }
        try Self.writeAll(descriptor: fd, offset: 0, data: data)
        guard fsync(fd) == 0,
            temporary.withCString({ source in destination.withCString { renameat(parent, source, parent, $0) }
            }) == 0
        else {
            throw Self.posix("Cannot replace upload recovery record.")
        }
        replaced = true
        stagingQuota?.checkpointReplaced(temporaryPath: temporaryPath, uploadID: id)
        guard fsync(parent) == 0 else { throw Self.posix("Cannot synchronize upload recovery record.") }
    }

    func removeUpload(id: String) throws {
        try CanonicalMaintenanceContext.deny(
            root: root, path: ["attachments", "uploads", id + ".json"], operation: "payload upload removal")
        try Self.validateID(id)
        let chain = try openDirectoryChain(
            components: ["attachments", ".uploads"], create: false, missingIsEmpty: true)
        guard let parent = chain.last else { return }
        defer { closeAll(chain) }
        let result = (id + ".json").withCString { unlinkat(parent, $0, 0) }
        guard result == 0 || errno == ENOENT, fsync(parent) == 0 else {
            throw Self.posix("Cannot remove upload recovery record.")
        }
        stagingQuota?.completeUpload(id: id)
    }

    func loadUploads() throws -> [String: AttachmentUploadState] {
        let chain = try openDirectoryChain(
            components: ["attachments", ".uploads"], create: false, missingIsEmpty: true)
        guard let parent = chain.last else { return [:] }
        defer { closeAll(chain) }
        var result: [String: AttachmentUploadState] = [:]
        try POSIXDirectory.withEntries(at: root.appendingPathComponent("attachments/.uploads")) { name in
            // Interrupted atomic replacements are retained for diagnosis, never admitted.
            if name.hasSuffix(".tmp") { return true }
            guard name.hasSuffix(".json"), result.count < 64 else {
                throw TractandaError(
                    "unsafeAttachmentStore", "Unexpected or excessive upload recovery entries.")
            }
            let id = String(name.dropLast(5))
            try Self.validateID(id)
            let fd = try openRegularFile(
                in: parent, name: name, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                expectedMode: 0o600)
            defer { _ = close(fd) }
            let before = try Self.metadata(for: fd)
            guard before.size <= 16 * 1024 else {
                throw TractandaError("unsafeAttachmentStore", "Upload recovery metadata exceeds its bound.")
            }
            let bytes = try Self.readExactly(descriptor: fd, offset: 0, count: Int(before.size))
            guard try Self.metadata(for: fd) == before else {
                throw TractandaError(
                    "unsafeAttachmentStore", "Upload recovery metadata changed while reading.")
            }
            var upload = try JSON.decode(AttachmentUploadState.self, bytes)
            try upload.validate()
            guard upload.descriptor.attachmentID == id else {
                throw TractandaError(
                    "unsafeAttachmentStore", "Upload recovery filename does not match its identity.")
            }
            if upload.phase == "discarding" {
                try discardStaging(id: id)
                try removeUpload(id: id)
                return true
            }
            if upload.phase == "verifying" || upload.phase == "verified" { upload.phase = "paused" }
            // Physical publication and a renewed integrity proof are independent state.
            if try publishedMetadataMatches(upload.descriptor) {
                upload.location = "published"
            } else if upload.location == nil {
                upload.location = "staged"
            }
            if upload.location != "published" {
                let size = try stagedSize(id: id)
                guard size <= upload.descriptor.byteCount else {
                    throw TractandaError(
                        "unsafeAttachmentStore", "Recovered stage exceeds its declared original.")
                }
            }
            result[id] = upload
            return true
        }
        return result
    }
}

extension AttachmentPayloadStore {
    /// One verified retained descriptor; only <=256KiB hash chunks cross the working set.
    func prepareDocumentOriginal(
        descriptor: AttachmentDescriptor, cancellation: DocumentConversionCancellation,
        progress: @escaping @Sendable (Int64) throws -> Void
    ) throws -> DocumentVerifiedOriginal {
        _ = try Self.validated(descriptor)
        guard let relative = try resolvedPayloadPath(descriptor.attachmentID) else {
            throw TractandaError("attachmentIntegrity", "Document original is missing.")
        }
        let chain = try openPayloadFile(path: relative, id: descriptor.attachmentID)
        do {
            let fd = chain.last!
            let before = try Self.metadata(for: fd)
            guard
                Self.validPublishedMetadata(
                    before, descriptor: descriptor, ownerUID: ownerUID, archived: Self.isArchived(fd))
            else {
                throw TractandaError(
                    "attachmentIntegrity", "Document original metadata differs from its descriptor.")
            }
            let digest = try Self.sha256(
                descriptor: fd, byteCount: before.size, chunkLimit: chunkByteLimit,
                progress: { bytes in
                    try cancellation.check()
                    try progress(bytes)
                })
            let after = try Self.metadata(for: fd)
            guard before == after, digest == descriptor.sha256 else {
                throw TractandaError("attachmentIntegrity", "Document original changed while hashing.")
            }
            try cancellation.check()
            let token = NativeSourceFileIdentity(
                device: after.device, inode: after.inode, byteCount: descriptor.byteCount,
                mode: after.mode, uid: after.uid, gid: after.gid,
                modificationSeconds: after.modificationSeconds,
                modificationNanoseconds: after.modificationNanoseconds)
            let path = root.path + "/" + relative
            return DocumentVerifiedOriginal(path: path, file: token, descriptors: chain) { [self] in
                guard try Self.metadata(for: fd) == after else {
                    throw TractandaError("documentOriginalChanged", "Retained document original changed.")
                }
                let current = try openPayloadFile(path: relative, id: descriptor.attachmentID)
                defer { closeAll(current) }
                guard try Self.metadata(for: current.last!) == after else {
                    throw TractandaError(
                        "documentOriginalChanged",
                        "Canonical original path no longer names the verified descriptor.")
                }
            }
        } catch {
            closeAll(chain)
            throw error
        }
    }
}

/// A descriptor-pinned immutable source. It exposes no path and cannot authorize a principal.
/// HTTP callers verify off-queue before headers and recheck current access before each bounded read.
public final class JMAPBlobPinnedSource: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var verified = false
    private let verifier: () throws -> Void
    private let reader: (Int64, Int) throws -> Data
    private let closer: () -> Void
    init(
        verify: @escaping () throws -> Void, read: @escaping (Int64, Int) throws -> Data,
        close: @escaping () -> Void
    ) {
        verifier = verify
        reader = read
        closer = close
    }
    public func verify() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw TractandaError("notFound", "Blob source is closed.") }
        if !verified {
            try verifier()
            verified = true
        }
    }
    public func read(offset: Int64, limit: Int = 262_144) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, verified else {
            throw TractandaError("attachmentVerifying", "Blob source is not verified.")
        }
        return try reader(offset, limit)
    }
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            closer()
        }
    }
    deinit { close() }
}

extension AttachmentPayloadStore {
    func pinBlob(_ attachment: AttachmentDescriptor, staged: Bool) throws -> JMAPBlobPinnedSource {
        _ = try Self.validated(attachment)
        let chain: [Int32]
        if staged {
            let directories = try openDirectoryChain(components: ["attachments", ".staging"], create: false)
            do {
                let fd = try openRegularFile(
                    in: directories.last!, name: Self.stageName(attachment.attachmentID),
                    flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                    expectedMode: Self.stagingMode)
                chain = directories + [fd]
            } catch {
                closeAll(directories)
                throw error
            }
        } else {
            chain = try openPayloadFile(id: attachment.attachmentID)
        }
        do {
            let fd = chain.last!
            let expected = try Self.metadata(for: fd)
            guard expected.size == UInt64(attachment.byteCount),
                staged
                    ? Self.validStagingMetadata(expected, allowSealed: false, ownerUID: ownerUID)
                    : Self.validPublishedMetadata(
                        expected, descriptor: attachment, ownerUID: ownerUID, archived: Self.isArchived(fd))
            else { throw TractandaError("attachmentIntegrity", "Blob source metadata differs.") }
            return JMAPBlobPinnedSource(
                verify: {
                    guard try Self.metadata(for: fd) == expected else {
                        throw TractandaError("attachmentIntegrity", "Blob source changed.")
                    }
                    let digest = try Self.sha256(
                        descriptor: fd, byteCount: expected.size, chunkLimit: Self.maximumChunkBytes,
                        progress: { _ in try Task.checkCancellation() })
                    guard digest == attachment.sha256, try Self.metadata(for: fd) == expected else {
                        throw TractandaError("attachmentIntegrity", "Blob digest differs.")
                    }
                },
                read: { offset, limit in
                    guard offset >= 0, offset <= attachment.byteCount, limit >= 0,
                        limit <= Self.maximumChunkBytes
                    else {
                        throw TractandaError("invalidArguments", "Blob read exceeds its bounded range.")
                    }
                    guard try Self.metadata(for: fd) == expected else {
                        throw TractandaError("attachmentIntegrity", "Blob source changed.")
                    }
                    let bytes = try Self.readExactly(
                        descriptor: fd, offset: offset,
                        count: Int(min(Int64(limit), attachment.byteCount - offset)))
                    guard try Self.metadata(for: fd) == expected else {
                        throw TractandaError("attachmentIntegrity", "Blob source changed while reading.")
                    }
                    return bytes
                }, close: { [self] in closeAll(chain) })
        } catch {
            closeAll(chain)
            throw error
        }
    }
}

extension AttachmentPayloadStore {
    func requireBlobReserve(minimumFreeBytes: Int64, additionalBytes: Int) throws {
        guard minimumFreeBytes >= 0, additionalBytes >= 0 else {
            throw TractandaError("resourceLimit", "Invalid blob capacity request.")
        }
        let free: UInt64
        if let availableBytesOverride {
            free = try availableBytesOverride()
        } else {
            var capacity = statvfs()
            guard statvfs(root.path, &capacity) == 0, capacity.f_frsize > 0 else {
                throw TractandaError("resourceLimit", "Cannot inspect blob filesystem capacity.")
            }
            let total = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
            guard !total.overflow else { throw TractandaError("resourceLimit", "Blob capacity overflowed.") }
            free = total.partialValue
        }
        let required = UInt64(minimumFreeBytes).addingReportingOverflow(UInt64(additionalBytes))
        guard !required.overflow, free >= required.partialValue else {
            throw TractandaError("resourceLimit", "Blob free-space reserve would be crossed.")
        }
    }
}
