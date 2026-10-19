import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// One caller-owned hydration/work allowance, shared by metadata and original verification.
final class PeerOriginalReadBudget {
    private(set) var remaining: UInt64
    private(set) var used: UInt64 = 0
    private(set) var steps = 0
    let maximumSteps: Int
    let capacity: UInt64
    private let onStep: (() throws -> Void)?
    init(
        bytes: UInt64 = 4 * 1024 * 1024, maximumSteps: Int = 1024,
        workingCapacity: UInt64? = nil, onStep: (() throws -> Void)? = nil
    ) {
        remaining = bytes
        capacity = max(bytes, workingCapacity ?? bytes)
        self.maximumSteps = maximumSteps
        self.onStep = onStep
    }
    func charge(_ count: Int) throws {
        guard count >= 0, UInt64(count) <= remaining else {
            throw TractandaError(
                "peerPayloadVerifying", "Read allowance exhausted; resume original verification.")
        }
        remaining -= UInt64(count)
        used += UInt64(count)
    }
    func requireWorkingSet(bytes: UInt64, steps: Int, label: String) throws {
        guard capacity >= bytes, maximumSteps >= steps else {
            throw TractandaError(
                "resourceLimit",
                "\(label) needs a caller read window of at least \(bytes) bytes and \(steps) work steps; increase the operation limits and retry. Retained bytes are unchanged."
            )
        }
    }
    func step() throws {
        guard steps < maximumSteps else {
            throw TractandaError(
                "peerPayloadVerifying", "Work allowance exhausted; resume original verification.")
        }
        steps += 1
        try onStep?()
    }
    func count(maximum: Int) throws -> Int {
        guard remaining > 0 else {
            throw TractandaError(
                "peerPayloadVerifying", "Read allowance exhausted; resume original verification.")
        }
        return Int(min(remaining, UInt64(maximum)))
    }
    /// Keep room for a final bounded read without charging unused reservations as actual reads.
    func reservingReadBytes<T>(_ count: Int, _ body: () throws -> T) throws -> T {
        guard count >= 0, UInt64(count) <= remaining else {
            throw TractandaError("peerPayloadVerifying", "Final publication read allowance is unavailable.")
        }
        remaining -= UInt64(count)
        defer { remaining += UInt64(count) }
        return try body()
    }
}

/// One retained bounded-window reader. Neither callers nor wire messages receive its path/FD.
final class PeerOriginalFile {
    let metadata: FileMetadata
    private let descriptors: [Int32]
    private let reader: (Int64, Int) throws -> Data
    private let validate: () throws -> Void
    init(
        metadata: FileMetadata, descriptors: [Int32], read: @escaping (Int64, Int) throws -> Data,
        validate: @escaping () throws -> Void
    ) {
        self.metadata = metadata
        self.descriptors = descriptors
        reader = read
        self.validate = validate
    }
    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, count <= PeerPackage.maximumPayloadChunkBytes,
            UInt64(offset) <= metadata.size, UInt64(count) <= metadata.size - UInt64(offset)
        else {
            throw TractandaError("invalidPeerOffset", "Original read exceeds its bounded window.")
        }
        try validate()
        let bytes = try reader(offset, count)
        try validate()
        return bytes
    }
    func check() throws { try validate() }
    func synchronize(allowReadOnly: Bool = false) throws {
        try validate()
        if allowReadOnly, let descriptor = descriptors.last {
            var status = statvfs()
            if fstatvfs(descriptor, &status) == 0, status.f_flag & UInt(ST_RDONLY) != 0 { return }
        }
        guard let descriptor = descriptors.last, fsync(descriptor) == 0 else {
            throw TractandaError("writeFailed", "Cannot synchronize verified private original bytes.")
        }
        try validate()
    }
    deinit { for fd in descriptors.reversed() { _ = close(fd) } }
}

/// Private transfer work. The Store owner serializes access; no network wait holds a writer operation.
/// Current-process certificates replace an unbounded memory cache, never canonical authority.
final class PeerOriginalTransfer {
    struct Binding: Codable, Equatable {
        let object: PeerPackage.Object
        let stageID: String
    }
    struct Stamp: Codable, Equatable {
        let mode: UInt32
        let uid: UInt32
        let gid: UInt32
        let size: UInt64
        let inode: UInt64
        let device: UInt64
        let seconds: Int64
        let nanos: Int32
        init(_ metadata: FileMetadata) {
            mode = metadata.mode
            uid = metadata.uid
            gid = metadata.gid
            size = metadata.size
            inode = metadata.inode
            device = metadata.device
            seconds = metadata.modificationSeconds
            nanos = metadata.modificationNanoseconds
        }
    }
    struct Verified: Codable {
        let object: PeerPackage.Object
        let stamp: Stamp
        let complete: Bool
    }
    private struct HighWater: Codable {
        let object: PeerPackage.Object
        let stageID: String
        let nextOffset: Int64
    }
    private func highWater(_ binding: Binding, packageID: String, budget: PeerOriginalReadBudget) throws
        -> Int64
    {
        guard
            let bytes = try files.readPeerCheckpoint(
                path: prefix(packageID, binding.object.id) + ["high-water.json"], readBudget: budget.charge)
        else {
            throw TractandaError(
                "peerObjectCollision", "Existing receiver stage lost its durable acknowledgment checkpoint.")
        }
        let saved = try PeerPackage.decode(HighWater.self, bytes, maximum: 16 * 1024)
        guard saved.object == binding.object, saved.stageID == binding.stageID, saved.nextOffset >= 0,
            saved.nextOffset <= Int64(binding.object.length),
            saved.nextOffset == Int64(binding.object.length)
                || saved.nextOffset % Int64(PeerPackage.maximumPayloadChunkBytes) == 0
        else {
            throw TractandaError("peerObjectCollision", "Private original acknowledgment binding differs.")
        }
        return saved.nextOffset
    }
    private func acknowledge(
        _ binding: Binding, packageID: String, offset: Int64, budget: PeerOriginalReadBudget
    ) throws {
        let previous = try highWater(binding, packageID: packageID, budget: budget)
        guard offset >= previous else {
            throw TractandaError("peerObjectCollision", "Acknowledged original prefix regressed.")
        }
        if offset == previous {
            // A prior rename can be visible even when its parent fsync failed. Retry the exact
            // durability boundary before acknowledging an unchanged high-water offset.
            try files.synchronizeDirectory(prefix(packageID, binding.object.id))
            return
        }
        try files.replacePeerCheckpoint(
            try JSON.encode(HighWater(object: binding.object, stageID: binding.stageID, nextOffset: offset)),
            path: prefix(packageID, binding.object.id) + ["high-water.json"])
    }
    private struct Job {
        let key: String
        let object: PeerPackage.Object
        let metadata: FileMetadata
        let certificateKey: String
        let proofPrefix: [String]?
        var offset: Int64 = 0
        var hash = SHA256()
        var chunkHash = SHA256()
        var proof: PeerIntakeJournal.ChunkProof?
        var touched = ProcessInfo.processInfo.systemUptime
    }
    let payloads: AttachmentPayloadStore
    private let root: URL
    private let files: DocumentContentFiles
    private let quota: StagingByteQuota
    private let epoch: String
    private var jobs: [String: Job] = [:]
    // Native hash state is process-local. Park no file descriptor, serialized hash or new proof.
    // Three fixed operation slots per at-most256 current logical contexts, reserved16KiB each.
    private var parked: [String: Job] = [:]
    private var logicalOwner: String?
    private var activeVerifications = 0
    var logicalVerificationOwner: String? { logicalOwner }
    func withLogicalVerificationOwner<T>(_ owner: String?, _ body: () throws -> T) throws -> T {
        if let owner {
            let fields = owner.split(separator: ":")
            guard fields.count == 2, UUID(uuidString: String(fields[0])) != nil,
                ["comparison", "export", "intake"].contains(String(fields[1])) else {
                throw TractandaError("resourceLimit", "Invalid logical verification slot.")
            }
        }
        let previous = logicalOwner; logicalOwner = owner
        defer { logicalOwner = previous }
        return try body()
    }
    func releaseLogicalVerification(_ owner: String) {
        parked = parked.filter { !$0.key.hasPrefix(owner + ":") }
    }
    var didReadForTesting: ((PeerPackage.Object, Int) -> Void)?
    func verificationCountsForTesting() -> (ordinary: Int, parked: Int, active: Int) {
        (jobs.count, parked.count, activeVerifications)
    }
    var admitNewBinding: ((String) throws -> Void)?
    var afterProofIntentForTesting: (() throws -> Void)?
    var afterPayloadPublicationForTesting: (() throws -> Void)?
    init(
        root: URL, ownerUID: UInt32, payloads: AttachmentPayloadStore, quota: StagingByteQuota,
        reserveBytes: Int64, availableBytes: (@Sendable () throws -> UInt64)? = nil
    ) throws {
        self.root = root
        self.payloads = payloads
        self.quota = quota
        epoch = try UUID.makeVersion1().uuidString.lowercased()
        files = DocumentContentFiles(
            root: root, ownerUID: ownerUID, minimumFreeBytes: reserveBytes, availableBytes: availableBytes,
            stagingQuota: quota)
    }
    private func prefix(_ packageID: String, _ objectID: String) throws -> [String] {
        _ = try AuthorityRecord.persistentID(.text(packageID))
        _ = try AuthorityRecord.persistentID(.text(objectID))
        return ["authority", "payloads", packageID, objectID]
    }
    private func key(_ packageID: String, _ objectID: String) -> String {
        "peer:" + packageID + ":" + objectID
    }
    private func immutable(
        _ bytes: Data, path: [String], maximum: Int = 4096, budget: PeerOriginalReadBudget? = nil
    ) throws {
        if let old = try files.readIfPresent(path: path, maximumBytes: maximum, readBudget: budget?.charge) {
            guard old == bytes else {
                throw TractandaError("peerObjectCollision", "Peer payload work binding differs.")
            }
        } else {
            try files.writeImmutable(bytes, path: path, maximumBytes: maximum)
        }
    }
    func binding(
        packageID: String, object: PeerPackage.Object, create: Bool, budget: PeerOriginalReadBudget? = nil
    ) throws -> Binding? {
        try object.validate()
        guard object.kind == .attachment else {
            throw TractandaError("invalidPeerPackage", "Original transfer requires attachment kind.")
        }
        let base = try prefix(packageID, object.id)
        let binding: Binding
        if let bytes = try files.readIfPresent(
            path: base + ["binding.json"], maximumBytes: 4096, readBudget: budget?.charge)
        {
            binding = try PeerPackage.decode(Binding.self, bytes, maximum: 4096)
            guard binding.object == object else {
                throw TractandaError("peerObjectCollision", "Original transfer descriptor changed.")
            }
            _ = try AuthorityRecord.persistentID(.text(binding.stageID))
            _ = try highWater(binding, packageID: packageID, budget: budget ?? PeerOriginalReadBudget())
        } else {
            guard create else { return nil }
            try admitNewBinding?(packageID)
            try files.ensurePrivateDirectory(base)
            if let zero = try files.readPeerCheckpoint(
                path: base + ["high-water.json"], readBudget: budget?.charge)
            {
                let saved = try PeerPackage.decode(HighWater.self, zero, maximum: 16 * 1024)
                guard saved.object == object, saved.nextOffset == 0 else {
                    throw TractandaError(
                        "peerObjectCollision",
                        "Interrupted stage initialization is not provably pre-acknowledgment.")
                }
                _ = try AuthorityRecord.persistentID(.text(saved.stageID))
                binding = Binding(object: object, stageID: saved.stageID)
            } else {
                binding = Binding(object: object, stageID: try UUID.makeVersion1().uuidString.lowercased())
                try files.replacePeerCheckpoint(
                    try JSON.encode(HighWater(object: object, stageID: binding.stageID, nextOffset: 0)),
                    path: base + ["high-water.json"])
            }
            try files.synchronizeDirectory(base)
            // Zero acknowledgment is durable BEFORE the immutable binding makes this stage
            // discoverable. Missing checkpoints on an existing binding never mean zero.
            try immutable(try JSON.encode(binding), path: base + ["binding.json"])
        }
        quota.pin(
            path: ["attachments", ".staging", binding.stageID + ".stage"], copyKey: key(packageID, object.id))
        quota.pin(path: base, copyKey: key(packageID, object.id))
        return binding
    }
    private func ensureStage(_ binding: Binding) throws {
        do { _ = try payloads.stagedSize(id: binding.stageID) } catch let error as TractandaError
            where error.code == "attachmentIntegrity" || error.code == "unsafeAttachmentStore"
        {
            // createStaging never replaces an existing file, symlink or competing stage.
            try payloads.createStaging(id: binding.stageID)
        }
    }
    private func certificate(file: PeerOriginalFile, key: String, whole: Bool) throws -> [String] {
        let token = AuthorityRecordCodec.sha256(try JSON.encode(Stamp(file.metadata)))
        return [
            "authority", "payload-work", epoch, key + "-" + token + (whole ? "-whole.json" : "-prefix.json"),
        ]
    }
    private func repairTail(_ binding: Binding, packageID: String, budget: PeerOriginalReadBudget) throws {
        let size = try payloads.stagedSize(id: binding.stageID)
        let acknowledged = try highWater(binding, packageID: packageID, budget: budget)
        guard size >= acknowledged else {
            throw TractandaError(
                "peerObjectCollision", "Acknowledged original stage is missing or truncated.")
        }
        guard size < Int64(binding.object.length), size % Int64(PeerPackage.maximumPayloadChunkBytes) != 0
        else { return }
        let offset = size - size % Int64(PeerPackage.maximumPayloadChunkBytes)
        let base = try prefix(packageID, binding.object.id)
        let intent = try files.read(
            path: base + [String(offset) + ".proof.json"], maximumBytes: 4096, readBudget: budget.charge)
        let proof = try PeerPackage.decode(PeerIntakeJournal.ChunkProof.self, intent, maximum: 4096)
        guard proof.object == binding.object, proof.offset == Int(offset),
            proof.length == min(PeerPackage.maximumPayloadChunkBytes, binding.object.length - Int(offset))
        else {
            throw TractandaError(
                "peerObjectCollision", "Unacknowledged tail lacks its exact bounded proof intent.")
        }
        if try files.readIfPresent(
            path: base + [String(offset) + ".received.json"], maximumBytes: 4096, readBudget: budget.charge)
            != nil
        {
            throw TractandaError("peerObjectCollision", "Acknowledged original prefix was truncated.")
        }
        guard offset >= acknowledged else {
            throw TractandaError("peerObjectCollision", "Cannot discard acknowledged original bytes.")
        }
        try payloads.truncatePeerUnacknowledgedTail(stageID: binding.stageID, to: offset)
    }
    func append(
        packageID: String, object: PeerPackage.Object, offset: Int, bytes: Data,
        budget: PeerOriginalReadBudget? = nil
    ) throws {
        let budget = budget ?? PeerOriginalReadBudget()
        guard object.kind == .attachment, offset >= 0, offset < object.length,
            offset % PeerPackage.maximumPayloadChunkBytes == 0,
            bytes.count == min(PeerPackage.maximumPayloadChunkBytes, object.length - offset)
        else {
            throw TractandaError(
                "invalidPeerOffset", "Original chunk does not match its fixed bounded frame.")
        }
        guard let binding = try binding(packageID: packageID, object: object, create: true, budget: budget)
        else { preconditionFailure() }
        try ensureStage(binding)
        try repairTail(binding, packageID: packageID, budget: budget)
        let before = try payloads.peerStage(binding.stageID, maximumBytes: Int64(object.length))
        _ = try verify(
            file: before, key: binding.stageID, object: object, proofPrefix: prefix(packageID, object.id),
            whole: false, budget: budget, progress: nil)
        let proof = PeerIntakeJournal.ChunkProof(
            object: object, offset: offset, length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes))
        let proofBytes = try JSON.encode(proof)
        let base = try prefix(packageID, object.id)
        try immutable(proofBytes, path: base + [String(offset) + ".proof.json"], budget: budget)
        try afterProofIntentForTesting?()
        if Int64(offset) < Int64(before.metadata.size) { try budget.charge(bytes.count) }
        _ = try payloads.append(id: binding.stageID, offset: Int64(offset), data: bytes)
        let after = try payloads.peerStage(binding.stageID, maximumBytes: Int64(object.length))
        try after.synchronize()
        try immutable(proofBytes, path: base + [String(offset) + ".received.json"], budget: budget)
        try acknowledge(binding, packageID: packageID, offset: Int64(after.metadata.size), budget: budget)
        // Already verified prefix + byte-identical/fully fsynced chunk proves the new prefix.
        // Full-original SHA verification is separate and still mandatory before publication.
        try immutable(
            try JSON.encode(Verified(object: object, stamp: Stamp(after.metadata), complete: false)),
            path: certificate(file: after, key: binding.stageID, whole: false))
    }
    private func verify(
        file: PeerOriginalFile, key: String, object: PeerPackage.Object,
        proofPrefix: [String]?, whole: Bool, budget: PeerOriginalReadBudget, progress: (() throws -> Void)?
    ) throws -> Bool {
        guard activeVerifications < 8 else {
            throw TractandaError("peerVerificationBusy", "Active verification slots are busy.")
        }
        activeVerifications += 1
        defer { activeVerifications -= 1 }
        let certificate = try certificate(file: file, key: key, whole: whole)
        try budget.step()
        if let bytes = try files.readIfPresent(
            path: certificate, maximumBytes: 4096, readBudget: budget.charge)
        {
            let old = try PeerPackage.decode(Verified.self, bytes, maximum: 4096)
            guard old.object == object, old.stamp == Stamp(file.metadata), !whole || old.complete else {
                throw TractandaError("peerObjectCollision", "Original verification certificate differs.")
            }
            try file.check()
            if let owner = logicalOwner, parked[owner]?.certificateKey == certificate.last! {
                parked.removeValue(forKey: owner)
            }
            jobs.removeValue(forKey: certificate.last!)
            return old.complete
        }
        let jobKey = certificate.last!, owner = logicalOwner
        let now = ProcessInfo.processInfo.systemUptime
        jobs = jobs.filter { now - $0.value.touched < 60 }
        let existing = owner.flatMap { parked[$0] } ?? (owner == nil ? jobs[jobKey] : nil)
        if let existing, existing.certificateKey != jobKey {
            guard existing.object == object, existing.metadata == file.metadata else {
                throw TractandaError("peerVerificationBusy", "This bounded logical slot has unfinished verification.")
            }
            throw TractandaError("peerObjectCollision", "Verification certificate binding changed.")
        }
        if existing == nil {
            guard owner != nil ? parked.count < 768 : jobs.count < 8 else {
                throw TractandaError("peerVerificationBusy", "Bounded verification progress slots are busy.")
            }
        }
        var current = existing ?? Job(key: key, object: object, metadata: file.metadata,
            certificateKey: jobKey, proofPrefix: proofPrefix)
        guard current.object == object, current.metadata == file.metadata else {
            throw TractandaError("peerObjectCollision", "Original verification work binding differs.")
        }
        let parkedCost = try JSON.encode(current.object).count + (current.proofPrefix?.reduce(0) { $0 + $1.utf8.count } ?? 0)
            + MemoryLayout<SHA256>.stride * 2 + MemoryLayout<FileMetadata>.stride + 8192
        guard parkedCost <= 16 * 1024 else {
            throw TractandaError("resourceLimit", "One parked verification state exceeds its fixed reserve.")
        }
        var retain = true
        defer {
            if retain {
                current.touched = ProcessInfo.processInfo.systemUptime
                if let owner { parked[owner] = current } else { jobs[jobKey] = current }
            } else {
                if let owner { parked.removeValue(forKey: owner) } else { jobs.removeValue(forKey: jobKey) }
            }
        }
        for _ in 0..<64 where UInt64(current.offset) < current.metadata.size {
            try budget.step()
            try Task.checkCancellation()
            try progress?()
            if let prefix = current.proofPrefix, current.proof == nil {
                let frame = current.offset - current.offset % Int64(PeerPackage.maximumPayloadChunkBytes)
                let bytes = try files.read(
                    path: prefix + [String(frame) + ".proof.json"], maximumBytes: 4096,
                    readBudget: budget.charge)
                let proof = try PeerPackage.decode(PeerIntakeJournal.ChunkProof.self, bytes, maximum: 4096)
                guard proof.object == object, proof.offset == Int(frame),
                    proof.length == min(PeerPackage.maximumPayloadChunkBytes, object.length - Int(frame))
                else {
                    retain = false
                    throw TractandaError(
                        "peerObjectCollision", "Actual original prefix proof binding differs.")
                }
                current.proof = proof
                current.chunkHash = SHA256()
            }
            let frameRemaining =
                current.proof.map { Int64($0.offset + $0.length) - current.offset }
                ?? Int64(PeerPackage.maximumPayloadChunkBytes)
            let maximum = Int(
                min(64 * 1024, UInt64(frameRemaining), current.metadata.size - UInt64(current.offset)))
            let count = try budget.count(maximum: maximum)
            try budget.charge(count)
            let bytes = try file.read(offset: current.offset, count: count)
            didReadForTesting?(object, bytes.count)
            current.hash.update(data: bytes)
            if let proof = current.proof {
                current.chunkHash.update(data: bytes)
                if current.offset + Int64(count) == Int64(proof.offset + proof.length) {
                    let digest = current.chunkHash.finalize().map { String(format: "%02x", $0) }.joined()
                    guard digest == proof.sha256 else {
                        retain = false
                        throw TractandaError(
                            "peerObjectCollision", "Actual original prefix differs from synchronized proof.")
                    }
                    current.proof = nil
                }
            }
            current.offset += Int64(count)
        }
        guard UInt64(current.offset) == current.metadata.size else {
            throw TractandaError(
                "peerPayloadVerifying",
                "Original verification has bounded remaining work (\(current.offset)/\(object.length) bytes); retry the same operation."
            )
        }
        try file.check()
        let complete = current.metadata.size == UInt64(object.length)
        if whole {
            guard complete else { return false }
            let digest = current.hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == object.sha256 else {
                retain = false
                throw TractandaError("peerObjectCollision", "Original length/digest differs.")
            }
        }
        try immutable(
            try JSON.encode(
                Verified(object: object, stamp: Stamp(file.metadata), complete: whole && complete)),
            path: certificate)
        retain = false
        return whole && complete
    }
    /// Shared bounded hashing engine. Document part identities remain composite and never become
    /// canonical attachment identities; only their receiver-private stage file uses the byte store.
    func verifyDocumentPart(
        file: PeerOriginalFile, key: String, object: PeerPackage.Object, proofPrefix: [String]?,
        whole: Bool, budget: PeerOriginalReadBudget, progress: (() throws -> Void)? = nil
    ) throws -> Bool {
        try object.validate()
        guard object.kind == .document else {
            throw TractandaError("invalidPeerPackage", "Document hashing requires a composite part.")
        }
        return try verify(
            file: file, key: key, object: object, proofPrefix: proofPrefix,
            whole: whole, budget: budget, progress: progress)
    }
    func rememberDocumentPrefix(file: PeerOriginalFile, key: String, object: PeerPackage.Object) throws {
        try immutable(
            try JSON.encode(Verified(object: object, stamp: Stamp(file.metadata), complete: false)),
            path: certificate(file: file, key: key, whole: false))
    }
    func known(
        _ object: PeerPackage.Object, progress: (() throws -> Void)? = nil,
        budget: PeerOriginalReadBudget? = nil
    ) throws -> Bool {
        guard try payloads.resolvedPayloadPath(object.id) != nil else { return false }
        let file: PeerOriginalFile
        do { file = try payloads.peerStoredFile(id: object.id, byteCount: Int64(object.length)) } catch let
            error as TractandaError where error.code == "attachmentIntegrity" && error.osError == ENOENT
        { return false }
        return try verify(
            file: file, key: object.id, object: object, proofPrefix: nil, whole: true,
            budget: budget ?? PeerOriginalReadBudget(), progress: progress)
    }
    func resume(
        packageID: String, object: PeerPackage.Object, progress: (() throws -> Void)? = nil,
        budget: PeerOriginalReadBudget? = nil
    ) throws
        -> PeerPackage.ObjectResume
    {
        let budget = budget ?? PeerOriginalReadBudget()
        _ = try binding(packageID: packageID, object: object, create: false, budget: budget)
        if try known(object, progress: progress, budget: budget) {
            return .init(
                descriptor: object, nextOffset: object.length, source: .knownOriginal, verifiedComplete: true)
        }
        guard
            let binding = try binding(
                packageID: packageID, object: object, create: object.length == 0, budget: budget)
        else {
            return .init(descriptor: object, nextOffset: 0, source: .missing, verifiedComplete: false)
        }
        try ensureStage(binding)
        try repairTail(binding, packageID: packageID, budget: budget)
        let file = try payloads.peerStage(binding.stageID, maximumBytes: Int64(object.length))
        let complete = try verify(
            file: file, key: binding.stageID, object: object, proofPrefix: prefix(packageID, object.id),
            whole: file.metadata.size == UInt64(object.length), budget: budget, progress: progress)
        try file.synchronize()
        try acknowledge(binding, packageID: packageID, offset: Int64(file.metadata.size), budget: budget)
        return .init(
            descriptor: object, nextOffset: Int(file.metadata.size), source: .staged,
            verifiedComplete: complete)
    }
    func requireComplete(
        packageID: String, object: PeerPackage.Object, descriptor: AttachmentDescriptor,
        progress: (() throws -> Void)? = nil, budget: PeerOriginalReadBudget? = nil
    ) throws {
        guard object.id == descriptor.attachmentID, object.length == Int(exactly: descriptor.byteCount),
            object.sha256 == descriptor.sha256
        else {
            throw TractandaError(
                "peerObjectCollision", "Canonical original descriptor does not bind transferred bytes.")
        }
        let state = try resume(packageID: packageID, object: object, progress: progress, budget: budget)
        guard state.verifiedComplete else {
            throw TractandaError("missingDependencies", "Referenced original is incomplete.")
        }
    }
    func publish(
        packageID: String, object: PeerPackage.Object, descriptor: AttachmentDescriptor,
        budget: PeerOriginalReadBudget? = nil
    ) throws {
        let budget = budget ?? PeerOriginalReadBudget()
        _ = try binding(packageID: packageID, object: object, create: false, budget: budget)
        if try known(object, budget: budget) { return }
        guard
            let binding = try binding(
                packageID: packageID, object: object, create: object.length == 0, budget: budget)
        else {
            throw TractandaError("missingDependencies", "Referenced original has no receiver stage.")
        }
        let file = try payloads.peerStage(binding.stageID, maximumBytes: Int64(object.length))
        guard
            try verify(
                file: file, key: binding.stageID, object: object, proofPrefix: prefix(packageID, object.id),
                whole: true, budget: budget, progress: nil)
        else {
            throw TractandaError("missingDependencies", "Referenced original verification is incomplete.")
        }
        payloads.rememberPeerVerification(descriptor, metadata: file.metadata)
        try payloads.publish(descriptor: descriptor, requireVerifiedStage: true, stageID: binding.stageID)
        try afterPayloadPublicationForTesting?()
    }
    func read(
        descriptor: AttachmentDescriptor, offset: Int, maximumBytes: Int, progress: (() throws -> Void)?,
        budget: PeerOriginalReadBudget? = nil
    ) throws -> Data {
        let budget = budget ?? PeerOriginalReadBudget()
        let object = PeerPackage.Object(
            kind: .attachment, id: descriptor.attachmentID, length: Int(descriptor.byteCount),
            sha256: descriptor.sha256)
        guard try known(object, progress: progress, budget: budget) else {
            throw TractandaError("missingDependencies", "Selected original is absent.")
        }
        let file = try payloads.peerStoredFile(id: object.id, byteCount: descriptor.byteCount)
        let count = min(maximumBytes, object.length - offset)
        try budget.charge(count)
        return try file.read(offset: Int64(offset), count: count)
    }
    func cleanupApplied() throws {
        try files.withDirectoryEntries(path: ["authority", "payloads"]) { packageID in
            _ = try AuthorityRecord.persistentID(.text(packageID))
            let base = ["authority", "intake", packageID]
            if let applied = try self.files.readIfPresent(
                path: base + ["applied.json"], maximumBytes: PeerPackage.maximumPageBytes),
                let sealed = try self.files.readIfPresent(
                    path: base + ["sealed.json"], maximumBytes: PeerPackage.maximumPageBytes),
                applied == sealed
            {
                try self.complete(packageID: packageID)
            }
            return true
        }
    }
    func cleanupOldVerificationWork() throws {
        try files.withDirectoryEntries(path: ["authority", "payload-work"]) { old in
            _ = try AuthorityRecord.persistentID(.text(old))
            guard old != self.epoch else { return true }
            try self.files.removePeerPayloadTree(["authority", "payload-work", old])
            self.quota.release(path: ["authority", "payload-work", old])
            return true
        }
    }
    func complete(packageID: String) throws {
        try files.withDirectoryEntries(path: ["authority", "payloads", packageID]) { id in
            _ = try AuthorityRecord.persistentID(.text(id))
            let base = try self.prefix(packageID, id)
            if let bytes = try self.files.readIfPresent(path: base + ["binding.json"], maximumBytes: 4096) {
                let binding = try PeerPackage.decode(Binding.self, bytes, maximum: 4096)
                _ = try AuthorityRecord.persistentID(.text(binding.stageID))
                try self.payloads.discardStaging(id: binding.stageID)
            }
            try self.files.removePeerPayloadTree(base)
            self.quota.complete(copyKey: self.key(packageID, id))
            return true
        }
    }
    func accountedBytes(packageID: String, objectID: String) throws -> UInt64 {
        let base = try prefix(packageID, objectID)
        var value = quota.usedBytes(path: base)
        if let bytes = try files.readIfPresent(path: base + ["binding.json"], maximumBytes: 4096) {
            let binding = try PeerPackage.decode(Binding.self, bytes, maximum: 4096)
            _ = try AuthorityRecord.persistentID(.text(binding.stageID))
            let next = value.addingReportingOverflow(
                quota.usedBytes(path: ["attachments", ".staging", binding.stageID + ".stage"]))
            guard !next.overflow else {
                throw TractandaError("resourceLimit", "Peer original accounting overflow.")
            }
            value = next.partialValue
        }
        return UInt64(value)
    }
    func hasObject(packageID: String, objectID: String) throws -> Bool {
        try files.readIfPresent(path: prefix(packageID, objectID) + ["binding.json"], maximumBytes: 4096)
            != nil
    }
    func objectCount(packageID: String, maximum: Int) throws -> Int {
        var count = 0
        try files.withDirectoryEntries(path: ["authority", "payloads", packageID]) { id in
            _ = try AuthorityRecord.persistentID(.text(id))
            if try self.hasObject(packageID: packageID, objectID: id) {
                guard count < maximum else {
                    throw TractandaError("resourceLimit", "Original object count exceeded.")
                }
                count += 1
            }
            return true
        }
        return count
    }
    func stagedBytes(packageID: String) throws -> UInt64 {
        var total: UInt64 = 0
        try files.withDirectoryEntries(path: ["authority", "payloads", packageID]) { id in
            let next = total.addingReportingOverflow(
                try self.accountedBytes(packageID: packageID, objectID: id))
            guard !next.overflow else {
                throw TractandaError("resourceLimit", "Peer payload accounting overflow.")
            }
            total = next.partialValue
            return true
        }
        return total
    }
}
