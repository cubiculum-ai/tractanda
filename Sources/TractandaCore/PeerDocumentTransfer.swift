import Foundation

/// Receiver-private part transfer. A metadata package anchors only the manifest; bounded proof
/// paths authorize every other composite address. Storage readiness grants no canonical authority.
final class PeerDocumentTransfer {
    struct TreeBinding: Codable, Equatable {
        let manifest: PeerPackage.Object
        let stageID: String
        var stage: [String] { ["documents", ".staging", stageID] }
    }
    struct PartBinding: Codable, Equatable {
        let object: PeerPackage.Object
        let stageID: String
    }
    private struct HighWater: Codable {
        let object: PeerPackage.Object
        let stageID: String
        let nextOffset: Int64
    }
    let contents: DocumentContentStore
    let originals: PeerOriginalTransfer
    private let root: URL
    private let files: DocumentContentFiles
    private let quota: StagingByteQuota
    var afterProofIntentForTesting: (() throws -> Void)?
    var afterPartAdoptionForTesting: (() throws -> Void)?
    var afterPartRenameForTesting: (() throws -> Void)? {
        get { files.afterPeerPartRenameForTesting }
        set { files.afterPeerPartRenameForTesting = newValue }
    }

    init(
        root: URL, ownerUID: UInt32, contents: DocumentContentStore,
        originals: PeerOriginalTransfer, quota: StagingByteQuota, reserveBytes: Int64,
        availableBytes: (@Sendable () throws -> UInt64)? = nil
    ) {
        self.root = root
        self.contents = contents
        self.originals = originals
        self.quota = quota
        files = DocumentContentFiles(
            root: root, ownerUID: ownerUID, minimumFreeBytes: reserveBytes,
            availableBytes: availableBytes, stagingQuota: quota)
    }
    static func prefix(_ package: String, _ content: String) throws -> [String] {
        for id in [package, content] { _ = try AuthorityRecord.persistentID(.text(id)) }
        return ["authority", "document-transfers", package, content]
    }
    static func key(_ package: String, _ content: String) -> String {
        "peer-document:" + package + ":" + content
    }
    func accountedUsage(packageID: String) throws -> (objects: Int, bytes: UInt64) {
        try quota.peerDocumentUsage(packageID: packageID)
    }
    private func partPrefix(_ package: String, _ object: PeerPackage.Object) throws -> [String] {
        try object.validate()
        guard object.kind == .document, let part = object.part else {
            throw TractandaError("invalidPeerPackage", "Document transfer requires a composite address.")
        }
        return try Self.prefix(package, object.id) + [
            "parts", part.role.rawValue, String(part.level), String(part.ordinal),
        ]
    }
    private func immutable(
        _ data: Data, path: [String], maximum: Int = 4096,
        budget: PeerOriginalReadBudget? = nil
    ) throws {
        if let old = try files.readIfPresent(path: path, maximumBytes: maximum, readBudget: budget?.charge) {
            guard old == data else { throw collision("Document operational identity differs.") }
            try files.synchronizeDirectory(Array(path.dropLast()))
        } else {
            try files.writeImmutable(data, path: path, maximumBytes: maximum)
        }
    }
    /// Caller must establish this exact manifest descriptor from the authenticated package index.
    /// No node/page request, sender pathname or source assertion can create an anchor.
    @discardableResult
    func anchor(packageID: String, manifest: PeerPackage.Object) throws -> TreeBinding {
        try manifest.validate()
        guard manifest.kind == .document, manifest.part == .manifest else {
            throw collision("Only a document manifest may anchor its tree.")
        }
        let base = try Self.prefix(packageID, manifest.id)
        let binding: TreeBinding
        if let raw = try files.readIfPresent(path: base + ["binding.json"], maximumBytes: 4096) {
            binding = try PeerPackage.decode(TreeBinding.self, raw, maximum: 4096)
            guard binding.manifest == manifest else { throw collision("Document anchor changed.") }
            _ = try AuthorityRecord.persistentID(.text(binding.stageID))
        } else {
            var occupied = false
            try files.withDirectoryEntries(path: base) { _ in
                occupied = true
                return false
            }
            guard !occupied else { throw collision("Document anchor was lost over retained transfer state.") }
            try contents.preparePlacement()
            binding = TreeBinding(
                manifest: manifest, stageID: try UUID.makeVersion1().uuidString.lowercased())
            try files.createUniqueDirectory(binding.stage)
            try immutable(try JSON.encode(binding), path: base + ["binding.json"])
        }
        quota.pin(path: base, copyKey: Self.key(packageID, manifest.id))
        quota.pin(path: binding.stage, copyKey: Self.key(packageID, manifest.id))
        return binding
    }
    func tree(packageID: String, contentID: String, budget: PeerOriginalReadBudget? = nil) throws
        -> TreeBinding
    {
        let base = try Self.prefix(packageID, contentID)
        guard
            let bytes = try files.readIfPresent(
                path: base + ["binding.json"], maximumBytes: 4096, readBudget: budget?.charge)
        else {
            throw TractandaError("missingDependencies", "Document part has no package manifest anchor.")
        }
        let binding = try PeerPackage.decode(TreeBinding.self, bytes, maximum: 4096)
        try binding.manifest.validate()
        _ = try AuthorityRecord.persistentID(.text(binding.stageID))
        guard binding.manifest.id == contentID, binding.manifest.kind == .document,
            binding.manifest.part == .manifest
        else { throw collision("Document anchor binding differs.") }
        return binding
    }
    private func watermark(_ binding: PartBinding, prefix: [String], budget: PeerOriginalReadBudget) throws
        -> Int64
    {
        guard
            let raw = try files.readPeerCheckpoint(
                path: prefix + ["high-water.json"], readBudget: budget.charge)
        else {
            throw collision("Acknowledged document part lost its durable checkpoint.")
        }
        let value = try PeerPackage.decode(HighWater.self, raw, maximum: 16 * 1024)
        guard value.object == binding.object, value.stageID == binding.stageID, value.nextOffset >= 0,
            value.nextOffset <= Int64(binding.object.length),
            value.nextOffset == Int64(binding.object.length)
                || value.nextOffset % Int64(PeerPackage.maximumPayloadChunkBytes) == 0
        else { throw collision("Document part acknowledgment binding differs.") }
        return value.nextOffset
    }
    private func acknowledge(
        _ binding: PartBinding, prefix: [String], offset: Int64,
        budget: PeerOriginalReadBudget
    ) throws {
        let prior = try watermark(binding, prefix: prefix, budget: budget)
        guard offset >= prior else { throw collision("Document acknowledgment regressed.") }
        if offset == prior {
            try files.synchronizeDirectory(prefix)
            return
        }
        try files.replacePeerCheckpoint(
            try JSON.encode(
                HighWater(
                    object: binding.object, stageID: binding.stageID,
                    nextOffset: offset)), path: prefix + ["high-water.json"], readBudget: budget.charge)
    }
    private func partBinding(
        package: String, object: PeerPackage.Object, create: Bool,
        budget: PeerOriginalReadBudget
    ) throws -> PartBinding? {
        let base = try partPrefix(package, object)
        let binding: PartBinding
        if let raw = try files.readIfPresent(
            path: base + ["binding.json"], maximumBytes: 4096, readBudget: budget.charge)
        {
            binding = try PeerPackage.decode(PartBinding.self, raw, maximum: 4096)
            guard binding.object == object else { throw collision("Composite document descriptor changed.") }
            _ = try AuthorityRecord.persistentID(.text(binding.stageID))
            _ = try watermark(binding, prefix: base, budget: budget)
        } else {
            guard create else { return nil }
            try files.ensurePrivateDirectory(base)
            if let raw = try files.readPeerCheckpoint(
                path: base + ["high-water.json"], readBudget: budget.charge)
            {
                let value = try PeerPackage.decode(HighWater.self, raw, maximum: 16 * 1024)
                guard value.object == object, value.nextOffset == 0 else {
                    throw collision("Lost document binding is not a provably unacknowledged initialization.")
                }
                _ = try AuthorityRecord.persistentID(.text(value.stageID))
                binding = PartBinding(object: object, stageID: value.stageID)
            } else {
                binding = PartBinding(
                    object: object, stageID: try UUID.makeVersion1().uuidString.lowercased())
                try files.replacePeerCheckpoint(
                    try JSON.encode(
                        HighWater(
                            object: object, stageID: binding.stageID,
                            nextOffset: 0)), path: base + ["high-water.json"], readBudget: budget.charge)
            }
            try immutable(try JSON.encode(binding), path: base + ["binding.json"], budget: budget)
        }
        return binding
    }
    private func adoptedPath(_ binding: TreeBinding, object: PeerPackage.Object) throws -> [String]? {
        guard let part = object.part else { throw collision("Missing document address.") }
        let staged = binding.stage + part.relativePath
        do {
            _ = try FileMetadata.read(at: staged.reduce(root) { $0.appendingPathComponent($1) })
            return staged
        } catch FileMetadataError.posix(ENOENT) {}
        return try contents.peerDirectory(object.id).map { $0 + part.relativePath }
    }
    private func rawProof(package: String, object: PeerPackage.Object, budget: PeerOriginalReadBudget) throws
        -> Data
    {
        guard object.part?.role != .page else { throw collision("Page bodies never authorize another part.") }
        let tree = try tree(packageID: package, contentID: object.id, budget: budget)
        guard let path = try adoptedPath(tree, object: object) else {
            throw TractandaError("missingDependencies", "Document proof is not complete.")
        }
        try requireAdoptedAcknowledgment(package: package, object: object, path: path, budget: budget)
        let bytes = try files.read(
            path: path, maximumBytes: DocumentContentStore.maximumNodeBytes, readBudget: budget.charge)
        guard bytes.count == object.length, AuthorityRecordCodec.sha256(bytes) == object.sha256 else {
            throw collision("Document proof bytes differ from their authenticated edge.")
        }
        return bytes
    }
    private func requireAdoptedAcknowledgment(
        package: String, object: PeerPackage.Object, path: [String],
        budget: PeerOriginalReadBudget
    ) throws {
        guard path.starts(with: ["documents", ".staging"]) else { return }
        guard let binding = try partBinding(package: package, object: object, create: false, budget: budget),
            try watermark(binding, prefix: partPrefix(package, object), budget: budget)
                == Int64(object.length)
        else { throw collision("Adopted private document part lost its acknowledgment.") }
    }
    private func repairAdoptedPart(
        package: String, object: PeerPackage.Object, path: [String],
        budget: PeerOriginalReadBudget
    ) throws {
        if try files.frozenPeerStage(path, readBudget: budget.charge) != nil { return }
        guard path.starts(with: ["documents", ".staging"]),
            let binding = try partBinding(package: package, object: object, create: false, budget: budget)
        else { return }
        try files.adoptPeerDocumentPart(stageID: binding.stageID, to: path, bytes: Int64(object.length))
    }
    func manifest(packageID: String, contentID: String, budget: PeerOriginalReadBudget) throws -> (
        DocumentManifest, DocumentContentReference
    ) {
        let tree = try tree(packageID: packageID, contentID: contentID, budget: budget)
        let bytes = try rawProof(package: packageID, object: tree.manifest, budget: budget)
        let manifest = try DocumentValue.strictDecode(DocumentManifest.self, data: bytes)
        try manifest.source.validate()
        try manifest.identity.validate()
        guard manifest.schema == "tractanda.document-manifest.v2", manifest.contentID == contentID,
            UUID(uuidString: manifest.publicationID)?.version1Components != nil,
            Timestamp.parse(manifest.extractedAt) != nil, (0...8).contains(manifest.rootLevel),
            manifest.rootByteCount > 0, manifest.rootByteCount <= DocumentContentStore.maximumNodeBytes
        else {
            throw collision("Manifest structure/provenance differs.")
        }
        let reference = try DocumentContentReference(
            contentID: contentID, manifestSHA256: tree.manifest.sha256,
            rootSHA256: manifest.rootSHA256, pageCount: manifest.pageCount,
            totalEncodedBytes: manifest.totalEncodedBytes, coverage: manifest.coverage)
        return (manifest, reference)
    }
    /// Authenticate one address through at most nine bounded proof nodes, with no total-part list.
    func requireReachable(packageID: String, object: PeerPackage.Object, budget: PeerOriginalReadBudget)
        throws
    {
        try object.validate()
        let tree = try tree(packageID: packageID, contentID: object.id, budget: budget)
        if object.part == .manifest {
            guard tree.manifest == object else {
                throw collision("Manifest descriptor differs from its package anchor.")
            }
            return
        }
        let (manifest, _) = try manifest(packageID: packageID, contentID: object.id, budget: budget)
        guard let target = object.part else { throw collision("Document part address is missing.") }
        var level = manifest.rootLevel
        var edge = DocumentHashEntry(
            ordinal: 0, firstPage: 1, lastPage: manifest.pageCount,
            byteCount: manifest.rootByteCount, sha256: manifest.rootSHA256)
        while true {
            try budget.step()
            let descriptor = PeerPackage.Object(
                kind: .document, id: object.id, length: Int(edge.byteCount), sha256: edge.sha256,
                part: .init(role: .node, level: level, ordinal: edge.ordinal))
            try descriptor.validate()
            if descriptor.part == target {
                guard descriptor == object else { throw collision("Node edge descriptor differs.") }
                return
            }
            let bytes = try rawProof(package: packageID, object: descriptor, budget: budget)
            let node = try DocumentValue.strictDecode(DocumentHashNode.self, data: bytes)
            try node.validate()
            guard node.level == level, node.ordinal == edge.ordinal,
                node.entries.first?.firstPage == edge.firstPage, node.entries.last?.lastPage == edge.lastPage
            else {
                throw collision("Proof node range/identity differs.")
            }
            if level == 0 {
                guard target.role == .page,
                    let child = node.entries.first(where: { $0.ordinal == target.ordinal })
                else {
                    throw collision("Requested document address is not reachable.")
                }
                let expected = PeerPackage.Object(
                    kind: .document, id: object.id, length: Int(child.byteCount), sha256: child.sha256,
                    part: target)
                try expected.validate()
                guard expected == object else { throw collision("Page edge descriptor differs.") }
                return
            }
            let child: DocumentHashEntry?
            if target.role == .page {
                child = node.entries.first { $0.firstPage <= target.ordinal && target.ordinal <= $0.lastPage }
            } else {
                guard target.role == .node, target.level < level else {
                    throw collision("Node level is not reachable.")
                }
                var ordinal = target.ordinal
                for _ in target.level..<(level - 1) { ordinal /= 128 }
                child = node.entries.first { $0.ordinal == ordinal }
            }
            guard let child else { throw collision("Requested document address is not reachable.") }
            edge = child
            level -= 1
        }
    }
    func append(
        packageID: String, object: PeerPackage.Object, offset: Int, bytes: Data,
        budget: PeerOriginalReadBudget = .init()
    ) throws {
        try requireReachable(packageID: packageID, object: object, budget: budget)
        guard offset >= 0, offset < object.length, offset % PeerPackage.maximumPayloadChunkBytes == 0,
            bytes.count == min(PeerPackage.maximumPayloadChunkBytes, object.length - offset)
        else {
            throw TractandaError("invalidPeerOffset", "Document chunks require exact 256 KiB framing.")
        }
        let tree = try tree(packageID: packageID, contentID: object.id, budget: budget)
        if try files.frozenPeerStage(tree.stage, readBudget: budget.charge) != nil {
            throw TractandaError(
                "peerDocumentFrozen", "Closed peer document cannot accept appends or retries.")
        }
        if let path = try adoptedPath(tree, object: object) {
            try requireAdoptedAcknowledgment(package: packageID, object: object, path: path, budget: budget)
            let file = try files.peerDocumentPartFile(path: path, maximumBytes: object.length)
            guard file.metadata.size == UInt64(object.length),
                try originals.verifyDocumentPart(
                    file: file, key: AuthorityRecordCodec.sha256(Data(object.key.utf8)),
                    object: object, proofPrefix: nil, whole: true, budget: budget)
            else {
                throw collision("Retried canonical document bytes differ.")
            }
            try budget.charge(bytes.count)
            guard try file.read(offset: Int64(offset), count: bytes.count) == bytes else {
                throw collision("Retried canonical document bytes differ.")
            }
            try repairAdoptedPart(package: packageID, object: object, path: path, budget: budget)
            return
        }
        guard let binding = try partBinding(package: packageID, object: object, create: true, budget: budget)
        else { preconditionFailure() }
        let base = try partPrefix(packageID, object)
        let privatePath = ["attachments", ".staging", binding.stageID + ".stage"]
        quota.pin(path: privatePath, copyKey: Self.key(packageID, object.id))
        let acknowledged = try watermark(binding, prefix: base, budget: budget)
        do {
            _ = try FileMetadata.read(at: privatePath.reduce(root) { $0.appendingPathComponent($1) })
        } catch FileMetadataError.posix(ENOENT) {
            guard acknowledged == 0 else { throw collision("Acknowledged document stage disappeared.") }
            try originals.payloads.createStaging(id: binding.stageID)
        }
        try repairTail(binding, prefix: base, acknowledged: acknowledged, budget: budget)
        let file = try originals.payloads.peerStage(binding.stageID, maximumBytes: Int64(object.length))
        guard file.metadata.size >= UInt64(acknowledged) else {
            throw collision("Acknowledged document prefix was truncated.")
        }
        if file.metadata.size == UInt64(object.length) {
            _ = try resume(packageID: packageID, object: object, budget: budget)
            return try append(
                packageID: packageID, object: object, offset: offset, bytes: bytes, budget: budget)
        }
        _ = try originals.verifyDocumentPart(
            file: file, key: binding.stageID, object: object, proofPrefix: base,
            whole: false, budget: budget)
        let proof = PeerIntakeJournal.ChunkProof(
            object: object, offset: offset, length: bytes.count,
            sha256: AuthorityRecordCodec.sha256(bytes))
        try immutable(try JSON.encode(proof), path: base + [String(offset) + ".proof.json"], budget: budget)
        try afterProofIntentForTesting?()
        if UInt64(offset) < file.metadata.size { try budget.charge(bytes.count) }
        _ = try originals.payloads.append(id: binding.stageID, offset: Int64(offset), data: bytes)
        let after = try originals.payloads.peerStage(binding.stageID, maximumBytes: Int64(object.length))
        try after.synchronize()
        try acknowledge(binding, prefix: base, offset: Int64(after.metadata.size), budget: budget)
        try originals.rememberDocumentPrefix(file: after, key: binding.stageID, object: object)
        if after.metadata.size == UInt64(object.length) {
            _ = try resume(packageID: packageID, object: object, budget: budget)
        }
    }
    private func repairTail(
        _ binding: PartBinding, prefix: [String], acknowledged: Int64,
        budget: PeerOriginalReadBudget
    ) throws {
        let size = try originals.payloads.stagedSize(id: binding.stageID)
        guard size >= acknowledged else { throw collision("Acknowledged document prefix was truncated.") }
        if size == Int64(binding.object.length) || size % Int64(PeerPackage.maximumPayloadChunkBytes) == 0 {
            return
        }
        let offset = size - size % Int64(PeerPackage.maximumPayloadChunkBytes)
        let raw = try files.read(
            path: prefix + [String(offset) + ".proof.json"], maximumBytes: 4096, readBudget: budget.charge)
        let proof = try PeerPackage.decode(PeerIntakeJournal.ChunkProof.self, raw, maximum: 4096)
        guard offset >= acknowledged, proof.object == binding.object, proof.offset == Int(offset),
            proof.length == min(PeerPackage.maximumPayloadChunkBytes, binding.object.length - Int(offset))
        else {
            throw collision("Unacknowledged document tail lacks its exact intent.")
        }
        try originals.payloads.truncatePeerUnacknowledgedTail(stageID: binding.stageID, to: offset)
    }
    func resume(packageID: String, object: PeerPackage.Object, budget: PeerOriginalReadBudget = .init())
        throws -> PeerPackage.ObjectResume
    {
        try requireReachable(packageID: packageID, object: object, budget: budget)
        let tree = try tree(packageID: packageID, contentID: object.id, budget: budget)
        if let path = try adoptedPath(tree, object: object) {
            try requireAdoptedAcknowledgment(package: packageID, object: object, path: path, budget: budget)
            let file = try files.peerDocumentPartFile(path: path, maximumBytes: object.length)
            guard file.metadata.size == UInt64(object.length),
                try originals.verifyDocumentPart(
                    file: file, key: AuthorityRecordCodec.sha256(Data(object.key.utf8)),
                    object: object, proofPrefix: nil, whole: true, budget: budget)
            else {
                throw collision("Adopted document part differs.")
            }
            try repairAdoptedPart(package: packageID, object: object, path: path, budget: budget)
            return .init(
                descriptor: object, nextOffset: object.length, source: .knownOriginal, verifiedComplete: true)
        }
        guard let binding = try partBinding(package: packageID, object: object, create: false, budget: budget)
        else {
            if try files.frozenPeerStage(tree.stage, readBudget: budget.charge) != nil {
                throw TractandaError("peerDocumentFrozen", "Closed peer tree is missing its verified part.")
            }
            return .init(descriptor: object, nextOffset: 0, source: .missing)
        }
        if try files.frozenPeerStage(tree.stage, readBudget: budget.charge) != nil {
            throw TractandaError("peerDocumentFrozen", "Closed peer tree cannot adopt a new part.")
        }
        let prefix = try partPrefix(packageID, object)
        let acknowledged = try watermark(binding, prefix: prefix, budget: budget)
        do { try repairTail(binding, prefix: prefix, acknowledged: acknowledged, budget: budget) } catch let
            error as TractandaError where error.osError == ENOENT
        {
            guard acknowledged == 0 else { throw collision("Acknowledged document stage disappeared.") }
            return .init(descriptor: object, nextOffset: 0, source: .missing)
        }
        let file = try originals.payloads.peerStage(binding.stageID, maximumBytes: Int64(object.length))
        guard file.metadata.size >= UInt64(acknowledged) else {
            throw collision("Document acknowledgment exceeds actual bytes.")
        }
        let complete = file.metadata.size == UInt64(object.length)
        let verified = try originals.verifyDocumentPart(
            file: file, key: binding.stageID, object: object,
            proofPrefix: prefix, whole: complete, budget: budget)
        try acknowledge(binding, prefix: prefix, offset: Int64(file.metadata.size), budget: budget)
        if verified {
            try files.adoptPeerDocumentPart(
                stageID: binding.stageID, to: tree.stage + object.part!.relativePath,
                bytes: Int64(object.length))
            try afterPartAdoptionForTesting?()
        }
        return .init(
            descriptor: object, nextOffset: Int(file.metadata.size), source: .staged,
            verifiedComplete: verified)
    }
    private func collision(_ text: String) -> TractandaError { .init("peerObjectCollision", text) }
    func partFile(packageID: String, object: PeerPackage.Object, budget: PeerOriginalReadBudget? = nil) throws
        -> PeerOriginalFile
    {
        let binding = try tree(packageID: packageID, contentID: object.id, budget: budget)
        guard let path = try adoptedPath(binding, object: object) else {
            throw TractandaError("missingDependencies", "Verified document part is absent.")
        }
        return try files.peerDocumentPartFile(path: path, maximumBytes: object.length)
    }
    func partBytes(packageID: String, object: PeerPackage.Object, budget: PeerOriginalReadBudget) throws
        -> Data
    {
        try budget.requireWorkingSet(
            bytes: UInt64(object.length), steps: 1, label: "One encoded document part")
        guard try resume(packageID: packageID, object: object, budget: budget).verifiedComplete else {
            throw TractandaError("missingDependencies", "Document part is not complete.")
        }
        let file = try partFile(packageID: packageID, object: object, budget: budget)
        try budget.charge(object.length)
        var data = Data()
        data.reserveCapacity(object.length)
        for offset in stride(from: 0, to: object.length, by: PeerPackage.maximumPayloadChunkBytes) {
            data.append(
                try file.read(
                    offset: Int64(offset),
                    count: min(PeerPackage.maximumPayloadChunkBytes, object.length - offset)))
        }
        return data
    }
    func inspectionBase(packageID: String, contentID: String, budget: PeerOriginalReadBudget? = nil) throws
        -> [String]
    {
        if let canonical = try contents.peerDirectory(contentID) { return canonical }
        return try tree(packageID: packageID, contentID: contentID, budget: budget).stage
    }
    func freeze(packageID: String, reference: DocumentContentReference, budget: PeerOriginalReadBudget) throws
    {
        let binding = try tree(packageID: packageID, contentID: reference.contentID, budget: budget)
        guard binding.manifest.sha256 == reference.manifestSHA256 else {
            throw collision("Frozen manifest binding differs.")
        }
        quota.pin(
            path: ["documents", ".staging", binding.stageID + ".frozen.json"],
            copyKey: Self.key(packageID, reference.contentID))
        try files.freezePeerStage(binding.stage, reference: reference, readBudget: budget.charge)
    }
    /// Disposable cleanup only, after exact applied history. Each call removes at most128
    /// private tree entries or part handles; cancellation/restart retains the remaining work.
    @discardableResult
    func complete(packageID: String, maximumParts: Int = 128) throws -> Bool {
        _ = try AuthorityRecord.persistentID(.text(packageID))
        guard (1...128).contains(maximumParts) else {
            throw TractandaError("resourceLimit", "Invalid document cleanup window.")
        }
        let journal = ["authority", "intake", packageID]
        guard
            let applied = try files.readIfPresent(
                path: journal + ["applied.json"], maximumBytes: PeerPackage.maximumPageBytes),
            applied
                == (try files.readIfPresent(
                    path: journal + ["sealed.json"], maximumBytes: PeerPackage.maximumPageBytes)),
            applied
                == (try files.readIfPresent(
                    path: journal + ["prepared.json"], maximumBytes: PeerPackage.maximumPageBytes))
        else {
            throw collision("Document cleanup requires exact applied/sealed history.")
        }
        let publication = try PeerPackage.decode(PeerIntakeJournal.Publication.self, applied)
        let begin = try PeerPackage.decode(
            PeerIntakeJournal.Begin.self,
            files.read(path: journal + ["begin.json"], maximumBytes: PeerPackage.maximumPageBytes))
        try begin.manifest.validate(retained: true)
        guard begin.manifest.packageID == packageID, publication.packageID == packageID,
            begin.manifest.storeID == begin.context.storeID,
            publication.context == begin.context,
            publication.manifestDigest == AuthorityRecordCodec.sha256(try JSON.encode(begin.manifest))
        else {
            throw collision("Applied document cleanup binding differs.")
        }
        var remaining = maximumParts
        var contentWindow = 16
        var complete = true
        try files.withDirectoryEntries(path: ["authority", "document-transfers", packageID]) { content in
            guard remaining > 0, contentWindow > 0 else {
                complete = false
                return false
            }
            contentWindow -= 1
            try Task.checkCancellation()
            let base = try Self.prefix(packageID, content)
            guard let raw = try self.files.readIfPresent(path: base + ["binding.json"], maximumBytes: 4096)
            else {
                guard try self.files.removeEmptyPeerDocumentDirectory(base) else {
                    throw self.collision("Applied cleanup lost its binding over retained work.")
                }
                self.quota.complete(copyKey: Self.key(packageID, content))
                return true
            }
            let binding = try PeerPackage.decode(TreeBinding.self, raw, maximum: 4096)
            try binding.manifest.validate()
            guard binding.manifest.kind == .document, binding.manifest.id == content,
                binding.manifest.part == .manifest
            else {
                throw self.collision("Applied document anchor differs.")
            }
            _ = try AuthorityRecord.persistentID(.text(binding.stageID))
            guard let canonical = try self.contents.peerDirectory(content) else {
                throw self.collision("Applied document has no durable canonical tree.")
            }
            let manifestBytes = try self.files.read(
                path: canonical + ["manifest.json"], maximumBytes: DocumentContentStore.maximumNodeBytes)
            guard manifestBytes.count == binding.manifest.length,
                AuthorityRecordCodec.sha256(manifestBytes) == binding.manifest.sha256
            else {
                throw self.collision("Applied canonical document manifest differs.")
            }
            let manifest = try DocumentValue.strictDecode(DocumentManifest.self, data: manifestBytes)
            let reference = try DocumentContentReference(
                contentID: content, manifestSHA256: binding.manifest.sha256,
                rootSHA256: manifest.rootSHA256, pageCount: manifest.pageCount,
                totalEncodedBytes: manifest.totalEncodedBytes, coverage: manifest.coverage)
            _ = try self.contents.validatePeerManifest(manifestBytes, reference: reference)
            let disposal = try self.files.stepAppliedPeerDocumentStage(
                binding.stage, reference: reference, maximumEntries: remaining)
            remaining -= disposal.used
            guard disposal.complete else {
                complete = false
                return false
            }
            try self.files.finishAppliedPeerDocumentStage(binding.stage, reference: reference)
            self.quota.releaseAppliedDocumentStage(binding.stage, copyKey: Self.key(packageID, content))
            try self.files.withDirectoryEntries(path: base + ["parts"]) { role in
                guard PeerPackage.DocumentPart.Role(rawValue: role) != nil else {
                    throw self.collision("Unknown cleanup role.")
                }
                try self.files.withDirectoryEntries(path: base + ["parts", role]) { level in
                    guard let value = Int(level), (0...8).contains(value), String(value) == level else {
                        throw self.collision("Unknown cleanup proof level.")
                    }
                    try self.files.withDirectoryEntries(path: base + ["parts", role, level]) { ordinal in
                        guard remaining > 0 else {
                            complete = false
                            return false
                        }
                        remaining -= 1
                        try Task.checkCancellation()
                        let path = base + ["parts", role, level, ordinal]
                        if let raw = try self.files.readIfPresent(
                            path: path + ["binding.json"], maximumBytes: 4096)
                        {
                            let part = try PeerPackage.decode(PartBinding.self, raw, maximum: 4096)
                            try part.object.validate()
                            guard let address = part.object.part, part.object.id == content,
                                address.role.rawValue == role, String(address.level) == level,
                                String(address.ordinal) == ordinal
                            else { throw self.collision("Applied part cleanup address differs.") }
                            // Raw handle disposal is durable before deleting its only binding.
                            try self.originals.payloads.discardStaging(id: part.stageID)
                        }
                        try self.files.removePeerDocumentPart(path)
                        return remaining > 0
                    }
                    _ = try self.files.removeEmptyPeerDocumentDirectory(base + ["parts", role, level])
                    return remaining > 0
                }
                _ = try self.files.removeEmptyPeerDocumentDirectory(base + ["parts", role])
                return remaining > 0
            }
            guard try self.files.removeEmptyPeerDocumentDirectory(base + ["parts"]) else {
                complete = false
                return false
            }
            try self.files.removeAppliedPeerDocumentBinding(base)
            self.quota.complete(copyKey: Self.key(packageID, content))
            return remaining > 0
        }
        var pending = false
        try files.withDirectoryEntries(path: ["authority", "document-transfers", packageID]) { _ in
            pending = true
            return false
        }
        return complete && !pending
    }
}
