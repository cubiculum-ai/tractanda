import Foundation

/// Append-only private journal. Every checkpoint is immutable and synchronized using the same
/// no-follow descriptor I/O as document dependencies. A sealed receipt is a durability boundary,
/// never a permanent authorization grant. The caller holds the Store root writer lock.
final class PeerIntakeJournal {
    enum Boundary: String { case began, chunk, prepared, sealed, applied }
    struct Begin: Codable, Equatable {
        let manifest: PeerPackage.Manifest
        let context: PeerPackage.Context
    }
    struct ChunkProof: Codable, Equatable {
        let object: PeerPackage.Object
        let offset: Int
        let length: Int
        let sha256: String
    }
    struct Publication: Codable, Equatable, Sendable {
        let packageID: String
        let manifestDigest: String
        let context: PeerPackage.Context
        let contextToken: String
        /// Physical receiver arrival minute, independent of original or logical modifiedAt.
        let arrivalMinute: String
        /// Reserved for B's accepted-publication/control DAG. A never invents causal proof.
        var controlParents: [PeerPackage.ControlReference] = []
        /// A local writer's already selected path; never a sender-supplied filesystem path.
        var localItemPath: String? = nil
    }
    let files: DocumentContentFiles
    let root: URL
    let limits: PeerPackage.Limits
    private let stagingQuota: StagingByteQuota?
    var originals: PeerOriginalTransfer? {
        didSet {
            originals?.admitNewBinding = { [weak self] packageID in
                guard let self else { throw TractandaError("serviceClosed", "Intake journal closed.") }
                _ = try self.status(packageID)
                let count = self.objectCountCache[packageID] ?? 0
                guard count < self.limits.maximumObjects else {
                    throw TractandaError("resourceLimit", "Original object admission exceeds package limit.")
                }
                // Reserve the count conservatively before any binding file is admitted. An
                // interrupted initialization invalidates byte cache and is recounted on retry.
                self.objectCountCache[packageID] = count + 1
                self.byteCache.removeValue(forKey: packageID)
                self.activeStagedBytes = nil
            }
        }
    }
    var documents: PeerDocumentTransfer?
    var beforeSealForProfile: ((String) throws -> Void)?
    var afterBoundaryForTesting: ((Boundary) throws -> Void)?
    var afterOriginalPublicationForTesting: (() throws -> Void)?
    /// Simulates interruption after durable checksum intent but before any chunk bytes.
    var afterChunkIntentForTesting: (() throws -> Void)?
    private var byteCache: [String: UInt64] = [:]
    private var objectCountCache: [String: Int] = [:]
    private var activeStagedBytes: UInt64?
    init(
        root: URL, ownerUID: UInt32, limits: PeerPackage.Limits = .init(),
        stagingQuota: StagingByteQuota? = nil
    ) {
        self.stagingQuota = stagingQuota
        self.root = root
        self.limits = limits
        files = DocumentContentFiles(
            root: root, ownerUID: ownerUID, minimumFreeBytes: limits.reserveBytes, stagingQuota: stagingQuota)
    }
    private func path(_ id: String, _ suffix: [String]) throws -> [String] {
        _ = try AuthorityRecord.persistentID(.text(id))
        return ["authority", "intake", id] + suffix
    }
    private func write(_ data: Data, at path: [String], maximum: Int = PeerPackage.maximumPageBytes) throws {
        if let old = try files.readIfPresent(path: path, maximumBytes: maximum) {
            guard old == data else {
                throw TractandaError("peerObjectCollision", "Retained bytes differ for this identity.")
            }
        } else {
            try files.writeImmutable(data, path: path, maximumBytes: maximum)
        }
    }
    private func stagedBytes() throws -> UInt64 {
        if let activeStagedBytes { return activeStagedBytes }
        var total: UInt64 = 0
        try packageIDs { id in
            if try files.readIfPresent(
                path: path(id, ["applied.json"]), maximumBytes: PeerPackage.maximumPageBytes) == nil
            {
                let next = try self.status(id).receivedBytes
                guard next <= limits.maximumStagedBytes - min(total, limits.maximumStagedBytes) else {
                    throw TractandaError("resourceLimit", "Aggregate intake staging exhausted.")
                }
                total += next
            }
        }
        activeStagedBytes = total
        return total
    }
    func begin(context: PeerPackage.Context, manifestBytes: Data) throws -> PeerPackage.Status {
        try begin(context: context, manifestBytes: manifestBytes, retainedLocal: false)
    }
    func begin(context: PeerPackage.Context, manifestBytes: Data, retainedLocal: Bool) throws
        -> PeerPackage.Status
    {
        let manifest = try PeerPackage.decode(PeerPackage.Manifest.self, manifestBytes)
        try manifest.validate(retained: retainedLocal)
        if retainedLocal && manifest.profile != PeerPackage.profile {
            guard context.peerID == "local",
                let old = try files.readIfPresent(
                    path: path(manifest.packageID, ["begin.json"]), maximumBytes: PeerPackage.maximumPageBytes
                ),
                try PeerPackage.decode(Begin.self, old) == Begin(manifest: manifest, context: context)
            else {
                throw TractandaError(
                    "invalidPeerPackage", "Historical local continuation lacks its exact reserved Begin.")
            }
        }
        guard manifest.storeID == context.storeID else {
            throw TractandaError("invalidPeerPackage", "Store binding differs.")
        }
        let begin = try JSON.encode(Begin(manifest: manifest, context: context))
        let beginPath = try path(manifest.packageID, ["begin.json"])
        if try files.readIfPresent(path: beginPath, maximumBytes: PeerPackage.maximumPageBytes) == nil {
            let total = try stagedBytes()
            guard UInt64(begin.count) <= limits.maximumStagedBytes - min(total, limits.maximumStagedBytes)
            else {
                throw TractandaError("resourceLimit", "Intake metadata staging quota exhausted.")
            }
            try write(begin, at: beginPath)
            activeStagedBytes = total + UInt64(begin.count)
        } else {
            try write(begin, at: beginPath)
        }
        try afterBoundaryForTesting?(.began)
        return try status(manifest.packageID)
    }
    func beginRecord(_ id: String, readBudget: ((Int) throws -> Void)? = nil) throws -> Begin {
        let record = try PeerPackage.decode(
            Begin.self, files.read(path: path(id, ["begin.json"]), maximumBytes: PeerPackage.maximumPageBytes, readBudget: readBudget)
        )
        try record.manifest.validate(retained: true)
        guard record.manifest.packageID == id, record.manifest.storeID == record.context.storeID else {
            throw TractandaError("invalidPeerPackage", "Retained manifest identity differs.")
        }
        return record
    }
    func requireCurrentProfile(_ id: String) throws {
        guard try beginRecord(id).manifest.profile == PeerPackage.profile else {
            throw TractandaError(
                "historicalPeerPackage",
                "Retained v1 evidence cannot receive new network mutations; start v2 transfer.")
        }
    }
    func append(
        context: PeerPackage.Context, packageID: String, object: PeerPackage.Object, offset: Int, bytes: Data,
        retainedLocal: Bool = false
    ) throws -> PeerPackage.Status {
        var complete = false
        defer {
            if !complete {
                byteCache.removeValue(forKey: packageID)
                objectCountCache.removeValue(forKey: packageID)
                activeStagedBytes = nil
            }
        }
        let begin = try beginRecord(packageID)
        if begin.manifest.profile != PeerPackage.profile {
            guard retainedLocal, context.peerID == "local", begin.context == context else {
                throw TractandaError(
                    "historicalPeerPackage",
                    "Only exact reserved local recovery may append historical framing.")
            }
        }
        try object.validate(retainedProfile: begin.manifest.profile)
        guard begin.context == context else {
            throw TractandaError("peerConfigurationChanged", "Session/configuration binding changed.")
        }
        if object.kind == .document {
            guard begin.manifest.profile == PeerPackage.profile, let documents else {
                throw TractandaError("missingDependencies", "Document streaming is unavailable.")
            }
            guard try publication(packageID) == nil else {
                throw TractandaError("peerPackageSealed", "A sealed document cannot acquire new bytes.")
            }
            // Initial admission proves this exact manifest against the immutable package index.
            // Later parts use its retained anchor and bounded document proofs, never a full walk.
            do {
                _ = try documents.tree(packageID: packageID, contentID: object.id)
            } catch let error as TractandaError where error.code == "missingDependencies" {
                guard object.part == .manifest else { throw error }
                var found = 0
                try walk(packageID) { entry, _ in
                    if entry.id == object.id {
                        guard entry == object else {
                            throw TractandaError("peerObjectCollision", "Document anchor differs.")
                        }
                        found += 1
                    }
                }
                guard found == 1 else {
                    throw TractandaError("invalidPeerPackage", "Document lacks one exact manifest anchor.")
                }
                try admitDocumentAnchor(packageID: packageID, object: object)
            }
            let previous = try status(packageID)
            let total = try stagedBytes()
            let allowance = UInt64(bytes.count + 8192)
            guard allowance <= limits.maximumStagedBytes - min(total, limits.maximumStagedBytes) else {
                throw TractandaError("resourceLimit", "Document chunk/proof staging quota exhausted.")
            }
            let before = try documents.accountedUsage(packageID: packageID).bytes
            try documents.append(
                packageID: packageID, object: object, offset: offset, bytes: bytes,
                budget: .init(bytes: limits.maximumReadBytes, maximumSteps: limits.maximumWork))
            let after = try documents.accountedUsage(packageID: packageID).bytes
            guard after >= before else {
                throw TractandaError("peerObjectCollision", "Document quota counter regressed.")
            }
            let delta = after - before
            let received = previous.receivedBytes.addingReportingOverflow(delta)
            let aggregate = total.addingReportingOverflow(delta)
            guard !received.overflow, !aggregate.overflow,
                aggregate.partialValue <= limits.maximumStagedBytes
            else { throw TractandaError("resourceLimit", "Document staging quota exceeded.") }
            byteCache[packageID] = received.partialValue
            activeStagedBytes = aggregate.partialValue
            complete = true
            try afterBoundaryForTesting?(.chunk)
            return .init(packageID: packageID, sealed: false, receivedBytes: received.partialValue)
        }
        if object.kind == .attachment {
            guard let originals else {
                throw TractandaError("missingDependencies", "Original streaming is unavailable.")
            }
            if try publication(packageID) != nil {
                guard try originals.known(object), offset >= 0, offset < object.length,
                    bytes.count <= PeerPackage.maximumPayloadChunkBytes, bytes.count <= object.length - offset
                else {
                    throw TractandaError("peerPackageSealed", "A sealed original cannot acquire new bytes.")
                }
                let file = try originals.payloads.peerStoredFile(
                    id: object.id, byteCount: Int64(object.length))
                guard try file.read(offset: Int64(offset), count: bytes.count) == bytes else {
                    throw TractandaError("peerObjectCollision", "Published original retry differs.")
                }
                complete = true
                return try status(packageID)
            }
            let previous = try status(packageID)
            let existing = try originals.hasObject(packageID: packageID, objectID: object.id)
            guard existing || (objectCountCache[packageID] ?? 0) < limits.maximumObjects else {
                throw TractandaError("resourceLimit", "Package original object count exceeded.")
            }
            let total = try stagedBytes()
            let allowance = UInt64(bytes.count + 8192)
            guard allowance <= limits.maximumStagedBytes - min(total, limits.maximumStagedBytes) else {
                throw TractandaError("resourceLimit", "Peer original stage/proof quota exhausted.")
            }
            let before = try originals.accountedBytes(packageID: packageID, objectID: object.id)
            try originals.append(
                packageID: packageID, object: object, offset: offset, bytes: bytes,
                budget: PeerOriginalReadBudget(
                    bytes: limits.maximumReadBytes, maximumSteps: limits.maximumWork))
            let after = try originals.accountedBytes(packageID: packageID, objectID: object.id)
            let next: UInt64
            let aggregate: UInt64
            if after >= before {
                let delta = after - before
                let n = previous.receivedBytes.addingReportingOverflow(delta)
                let a = total.addingReportingOverflow(delta)
                guard !n.overflow, !a.overflow else {
                    throw TractandaError("resourceLimit", "Peer accounting overflow.")
                }
                next = n.partialValue
                aggregate = a.partialValue
            } else {
                let delta = before - after
                guard delta <= previous.receivedBytes, delta <= total else {
                    throw TractandaError("peerObjectCollision", "Peer quota counter regressed.")
                }
                next = previous.receivedBytes - delta
                aggregate = total - delta
            }
            guard aggregate <= limits.maximumStagedBytes else {
                throw TractandaError("resourceLimit", "Peer original accounting exceeded quota.")
            }
            byteCache[packageID] = next
            activeStagedBytes = aggregate
            complete = true
            return .init(packageID: packageID, sealed: false, receivedBytes: next)
        }
        guard offset >= 0, offset % PeerPackage.maximumChunkBytes == 0, !bytes.isEmpty,
            bytes.count == min(PeerPackage.maximumChunkBytes, object.length - offset), offset < object.length
        else {
            throw TractandaError("invalidPeerOffset", "Resume at a complete framed chunk boundary.")
        }
        if try publication(packageID) != nil, let original = try self.object(object, packageID: packageID) {
            guard Data(original[offset..<offset + bytes.count]) == bytes else {
                throw TractandaError("peerObjectCollision", "Retained retry bytes differ.")
            }
            complete = true
            return try status(packageID)
        }
        let descriptorPath = try path(packageID, ["objects", object.id, "descriptor.json"])
        let oldDescriptor = try files.readIfPresent(
            path: descriptorPath, maximumBytes: PeerPackage.maximumPageBytes)
        if let oldDescriptor {
            guard try PeerPackage.decode(PeerPackage.Object.self, oldDescriptor) == object else {
                throw TractandaError("peerObjectCollision", "Object identity/descriptor differs.")
            }
        }
        let chunkPath = try path(packageID, ["objects", object.id, String(offset)])
        if let old = try files.readIfPresent(path: chunkPath, maximumBytes: PeerPackage.maximumChunkBytes) {
            guard old == bytes else { throw TractandaError("peerObjectCollision", "Resume bytes differ.") }
            complete = true
            return try status(packageID)
        }
        guard try publication(packageID) == nil else {
            throw TractandaError("peerPackageSealed", "A sealed package is immutable.")
        }
        let descriptorBytes = try JSON.encode(object)
        let proofPath = try path(packageID, ["objects", object.id, String(offset) + ".proof.json"])
        let proofBytes = try JSON.encode(
            ChunkProof(
                object: object, offset: offset, length: bytes.count,
                sha256: AuthorityRecordCodec.sha256(bytes)))
        let oldProof = try files.readIfPresent(path: proofPath, maximumBytes: 4096)
        if let oldProof, oldProof != proofBytes {
            throw TractandaError("peerObjectCollision", "Chunk proof differs.")
        }
        let status = try status(packageID)
        let descriptorCharge = oldDescriptor == nil ? descriptorBytes.count : 0
        guard oldDescriptor != nil || (objectCountCache[packageID] ?? 0) < limits.maximumObjects else {
            throw TractandaError("resourceLimit", "Package object count exhausted.")
        }
        _ = try stagedBytes()
        let charge = UInt64(bytes.count + descriptorCharge + (oldProof == nil ? proofBytes.count : 0))
        guard charge <= limits.maximumStagedBytes - min(activeStagedBytes!, limits.maximumStagedBytes) else {
            throw TractandaError("resourceLimit", "Aggregate intake staging quota exhausted.")
        }
        try write(descriptorBytes, at: descriptorPath)
        if offset > 0 {
            _ = try files.read(
                path: path(
                    packageID, ["objects", object.id, String(offset - PeerPackage.maximumChunkBytes)]),
                maximumBytes: PeerPackage.maximumChunkBytes)
        }
        guard status.receivedBytes <= limits.maximumStagedBytes,
            charge <= limits.maximumStagedBytes - status.receivedBytes
        else {
            throw TractandaError("resourceLimit", "Intake staging quota exhausted.")
        }
        // Synchronize checksum intent before the chunk. Intent alone acknowledges no bytes;
        // resume still verifies the actual chunk and exact retry completes an interrupted write.
        try write(proofBytes, at: proofPath, maximum: 4096)
        try afterChunkIntentForTesting?()
        try write(
            bytes, at: chunkPath,
            maximum: PeerPackage.maximumChunkBytes)
        byteCache[packageID] = status.receivedBytes + charge
        if oldDescriptor == nil { objectCountCache[packageID, default: 0] += 1 }
        activeStagedBytes! += charge
        complete = true
        try afterBoundaryForTesting?(.chunk)
        return try self.status(packageID)
    }
    func object(_ object: PeerPackage.Object, packageID: String, readBudget: ((Int) throws -> Void)? = nil) throws -> Data? {
        try object.validate()
        if object.kind == .attachment || object.kind == .document { return nil }
        if let publication = try publication(packageID, readBudget: readBudget), object.kind != .index,
            let bytes = try retainedBytes(object, publication: publication, readBudget: readBudget)
        {
            return bytes
        }
        let descriptor = try files.readIfPresent(
            path: path(packageID, ["objects", object.id, "descriptor.json"]),
            maximumBytes: PeerPackage.maximumPageBytes, readBudget: readBudget)
        guard let descriptor else { return nil }
        guard try PeerPackage.decode(PeerPackage.Object.self, descriptor) == object else {
            throw TractandaError("peerObjectCollision", "Object identity/descriptor differs.")
        }
        var bytes = Data()
        for offset in stride(from: 0, to: object.length, by: PeerPackage.maximumChunkBytes) {
            guard
                let part = try files.readIfPresent(
                    path: path(packageID, ["objects", object.id, String(offset)]),
                    maximumBytes: PeerPackage.maximumChunkBytes, readBudget: readBudget)
            else { return nil }
            guard part.count == min(PeerPackage.maximumChunkBytes, object.length - offset) else {
                throw TractandaError("invalidPeerPackage", "Chunk framing changed.")
            }
            bytes.append(part)
        }
        guard AuthorityRecordCodec.sha256(bytes) == object.sha256 else {
            throw TractandaError("peerObjectCollision", "Original object digest differs.")
        }
        return bytes
    }
    /// Stream pages to a disk-backed consumer; keep only the bounded recursion path in memory.
    func walk(
        _ packageID: String, visitIndex: ((PeerPackage.Object) throws -> Void)? = nil,
        readBudget: ((Int) throws -> Void)? = nil, visit: (PeerPackage.Object, Data?) throws -> Void
    ) throws {
        let begin = try beginRecord(packageID, readBudget: readBudget)
        var active = Set<String>()
        var work = 0
        func page(_ descriptor: PeerPackage.Object, depth: Int) throws {
            work += 1
            guard work <= min(limits.maximumWork, limits.maximumObjects), depth <= limits.maximumDepth,
                active.insert(descriptor.id).inserted
            else {
                throw TractandaError("resourceLimit", "Package index work/depth exceeded or index cycle.")
            }
            defer { active.remove(descriptor.id) }
            try visitIndex?(descriptor)
            guard let data = try object(descriptor, packageID: packageID, readBudget: readBudget) else {
                throw TractandaError("missingDependencies", "Package index page is incomplete.")
            }
            let value = try PeerPackage.decode(PeerPackage.Page.self, data)
            try value.validate(retainedProfile: begin.manifest.profile)
            for child in value.children { try page(child, depth: depth + 1) }
            for entry in value.objects {
                work += 1
                guard work <= min(limits.maximumWork, limits.maximumObjects) else {
                    throw TractandaError("resourceLimit", "Package index work exceeded.")
                }
                try visit(entry, object(entry, packageID: packageID, readBudget: readBudget))
            }
        }
        try page(begin.manifest.root, depth: 0)
    }
    /// Only a caller traversing authenticated package pages may invoke this storage admission.
    func admitDocumentAnchor(packageID: String, object: PeerPackage.Object) throws {
        guard try beginRecord(packageID).manifest.profile == PeerPackage.profile, let documents else {
            throw TractandaError("invalidPeerPackage", "Only v3 packages admit document anchors.")
        }
        do {
            _ = try documents.tree(packageID: packageID, contentID: object.id)
        } catch let error as TractandaError where error.code == "missingDependencies" {
            _ = try status(packageID)
            guard (objectCountCache[packageID] ?? 0) < limits.maximumObjects else {
                throw TractandaError("resourceLimit", "Package manifest admission limit exceeded.")
            }
        }
        try documents.anchor(packageID: packageID, manifest: object)
        byteCache.removeValue(forKey: packageID)
        objectCountCache.removeValue(forKey: packageID)
        activeStagedBytes = nil
    }
    private func writePhase(_ bytes: Data, packageID: String, name: String) throws {
        let destination = try path(packageID, [name])
        if try files.readIfPresent(path: destination, maximumBytes: PeerPackage.maximumPageBytes) == nil {
            let used = try stagedBytes()
            guard UInt64(bytes.count) <= limits.maximumStagedBytes - min(used, limits.maximumStagedBytes)
            else {
                throw TractandaError("resourceLimit", "Peer phase journal exceeds actual staging quota.")
            }
        }
        try write(bytes, at: destination)
        byteCache.removeValue(forKey: packageID)
        activeStagedBytes = nil
    }
    func prepare(_ publication: Publication) throws {
        let begin = try beginRecord(publication.packageID)
        guard begin.manifest.profile == PeerPackage.profile || begin.context.peerID == "local" else {
            throw TractandaError(
                "historicalPeerPackage", "An unsealed foreign v1 stage cannot acquire a new seal.")
        }
        _ = try canonicalPath(begin.manifest.root, publication: publication)
        guard publication.controlParents.isEmpty else {
            throw TractandaError(
                "unsupportedAuthorityContext",
                "Accepted control causality is not enabled in metadata intake A.")
        }
        guard publication.localItemPath == nil || publication.context.peerID == "local" else {
            throw TractandaError(
                "invalidPeerPackage", "Foreign publication cannot select a receiver filesystem path.")
        }
        guard publication.context == begin.context,
            publication.manifestDigest == AuthorityRecordCodec.sha256(try JSON.encode(begin.manifest))
        else { throw TractandaError("invalidPeerPackage", "Publication binding differs.") }
        try writePhase(try JSON.encode(publication), packageID: publication.packageID, name: "prepared.json")
        try afterBoundaryForTesting?(.prepared)
    }
    func seal(_ id: String) throws {
        try beforeSealForProfile?(beginRecord(id).manifest.profile)
        let bytes = try files.read(
            path: path(id, ["prepared.json"]), maximumBytes: PeerPackage.maximumPageBytes)
        try writePhase(bytes, packageID: id, name: "sealed.json")
        try afterBoundaryForTesting?(.sealed)
    }
    func preparedPublication(_ id: String, readBudget: ((Int) throws -> Void)? = nil) throws -> Publication? {
        try files.readIfPresent(path: path(id, ["prepared.json"]), maximumBytes: PeerPackage.maximumPageBytes, readBudget: readBudget)
            .map { try PeerPackage.decode(Publication.self, $0) }
    }
    /// Existing canonical locators are written only after sealing. They survive index loss and
    /// therefore distinguish missing admitted proof from a legitimate never-sealed partial stage.
    func hasPublishedEvidence(_ id: String) throws -> Bool {
        _ = try AuthorityRecord.persistentID(.text(id))
        var present = false
        do {
            try files.withDirectoryEntries(path: ["authority", "locators", id]) { _ in present = true; return false }
        } catch let error as TractandaError where error.osError == ENOENT { return false }
        return present
    }
    func publication(_ id: String, readBudget: ((Int) throws -> Void)? = nil) throws -> Publication? {
        let value = try files.readIfPresent(
            path: path(id, ["sealed.json"]), maximumBytes: PeerPackage.maximumPageBytes, readBudget: readBudget
        )
        .map { try PeerPackage.decode(Publication.self, $0) }
        if value == nil {
            let applied = try files.readIfPresent(path: path(id, ["applied.json"]),
                maximumBytes: PeerPackage.maximumPageBytes, readBudget: readBudget)
            guard applied == nil, try !hasPublishedEvidence(id) else {
                throw TractandaError("peerRepairRequired", "Published intake lost its immutable receipt proof.")
            }
        }
        guard value?.controlParents.isEmpty != false else {
            throw TractandaError(
                "unsupportedAuthorityContext", "This reader cannot enforce later accepted-control causality.")
        }
        if let value {
            let begin = try beginRecord(id, readBudget: readBudget)
            guard value.packageID == id, value.context == begin.context,
                value.manifestDigest == AuthorityRecordCodec.sha256(try JSON.encode(begin.manifest)),
                try preparedPublication(id, readBudget: readBudget) == value
            else {
                throw TractandaError("invalidPeerPackage", "Retained sealed phase/manifest binding differs.")
            }
        }
        return value
    }
    func applied(_ id: String) throws {
        guard let publication = try publication(id) else {
            throw TractandaError("invalidPeerPackage", "Unsealed package cannot apply.")
        }
        try writePhase(try JSON.encode(publication), packageID: id, name: "applied.json")
        stagingQuota?.completePeerJournal(packageID: id)
        activeStagedBytes = nil
        try originals?.complete(packageID: id)
        try documents?.complete(packageID: id)
        try afterBoundaryForTesting?(.applied)
    }
    /// A sealed receiver locator is deterministic from the synchronized arrival minute and IDs.
    /// Revision UUID time and modifiedAt never choose this path.
    func canonicalPath(_ object: PeerPackage.Object, publication: Publication) throws -> [String] {
        let minute = publication.arrivalMinute.split(separator: "/").map(String.init)
        guard minute.count == 5,
            let date = Timestamp.parse(
                "\(minute[0])-\(minute[1])-\(minute[2])T\(minute[3]):\(minute[4]):00Z"),
            Timestamp.format(date).hasPrefix(
                "\(minute[0])-\(minute[1])-\(minute[2])T\(minute[3]):\(minute[4])")
        else {
            throw TractandaError("invalidPeerPackage", "Invalid receiver arrival locator.")
        }
        try object.validate()
        return ["authority", "locators", publication.packageID, object.id]
    }
    func publishOriginal(
        _ object: PeerPackage.Object, bytes: Data, publication: Publication, existingPath: String? = nil
    ) throws -> String {
        guard bytes.count == object.length, AuthorityRecordCodec.sha256(bytes) == object.sha256 else {
            throw TractandaError("peerObjectCollision", "Publication original differs.")
        }
        let destination: [String]
        if let existingPath {
            destination = existingPath.split(separator: "/").map(String.init)
        } else if let locator = try files.readIfPresent(
            path: canonicalPath(object, publication: publication), maximumBytes: 512),
            let text = String(data: locator, encoding: .utf8)
        {
            _ = try retainedBytes(object, publication: publication)
            destination = text.split(separator: "/").map(String.init)
        } else if object.kind == .item {
            let revision = try AuthorityRevision(originalBytes: bytes).revision
            guard revision.revisionID == object.id else {
                throw TractandaError("invalidPeerPackage", "Item identity differs.")
            }
            destination =
                try ["items"] + Self.currentArrivalMinute().split(separator: "/").map(String.init)
                + [revision.itemID, revision.revisionID + ".tractanda"]
        } else {
            destination =
                try ["authority", "records"]
                + Self.currentArrivalMinute().split(separator: "/").map(String.init)
                + [object.id + ".authority"]
        }
        let relative = destination.joined(separator: "/")
        if object.kind == .item {
            let revision = try AuthorityRevision(originalBytes: bytes).revision
            guard CanonicalRecordPath.validate(relative, itemID: revision.itemID, revisionID: object.id)
            else {
                throw TractandaError("invalidPeerPackage", "Receiver item locator is invalid.")
            }
        } else {
            guard destination.count == 8, destination.prefix(2) == ["authority", "records"],
                destination.last == object.id + ".authority"
            else { throw TractandaError("invalidPeerPackage", "Receiver control locator is invalid.") }
        }
        // Plan and synchronize the actual receiver locator BEFORE the file. A crash cannot
        // publish a second copy in another minute because the first path became undiscoverable.
        try write(
            Data(relative.utf8), at: canonicalPath(object, publication: publication)
        )
        try write(bytes, at: destination, maximum: object.length)
        try afterOriginalPublicationForTesting?()
        // Item chunks would otherwise duplicate canonical content. Index pages remain journal
        // metadata. Authority originals are likewise retained exactly once in their record tree.
        try files.removePeerObjectStage(packageID: publication.packageID, objectID: object.id)
        byteCache.removeValue(forKey: publication.packageID)
        objectCountCache.removeValue(forKey: publication.packageID)
        activeStagedBytes = nil
        return destination.joined(separator: "/")
    }
    static func currentArrivalMinute() throws -> String {
        let stamp = try RevisionTimestamp(Timestamp.now()).formatted()
        return String(stamp.prefix(16)).replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: "T", with: "/").replacingOccurrences(of: ":", with: "/")
    }
    func retainedBytes(_ object: PeerPackage.Object, publication: Publication, readBudget: ((Int) throws -> Void)? = nil) throws -> Data? {
        guard
            let locator = try files.readIfPresent(
                path: canonicalPath(object, publication: publication), maximumBytes: 512, readBudget: readBudget),
            let text = String(data: locator, encoding: .utf8)
        else { return nil }
        let destination = text.split(separator: "/").map(String.init)
        guard !text.hasPrefix("/"), !destination.contains(".."), !destination.contains("."),
            destination.joined(separator: "/") == text
        else { throw TractandaError("invalidPeerPackage", "Unsafe retained locator.") }
        guard let bytes = try files.readIfPresent(path: destination, maximumBytes: object.length, readBudget: readBudget) else {
            return nil
        }
        guard bytes.count == object.length, AuthorityRecordCodec.sha256(bytes) == object.sha256 else {
            throw TractandaError("peerObjectCollision", "Retained bytes changed.")
        }
        if object.kind == .item {
            let revision = try AuthorityRevision(originalBytes: bytes).revision
            guard CanonicalRecordPath.validate(text, itemID: revision.itemID, revisionID: object.id) else {
                throw TractandaError("invalidPeerPackage", "Retained locator is not an item path.")
            }
        } else {
            guard destination.count == 8, destination.prefix(2) == ["authority", "records"],
                destination.last == object.id + ".authority"
            else { throw TractandaError("invalidPeerPackage", "Retained authority locator differs.") }
        }
        return bytes
    }
    func packageIDs(_ visit: (String) throws -> Void) throws {
        let directory = root.appendingPathComponent("authority/intake")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var count = 0
        try POSIXDirectory.withEntries(at: directory) { name in
            count += 1
            guard count <= limits.maximumObjects else {
                throw TractandaError("resourceLimit", "Package inventory work exceeded.")
            }
            _ = try AuthorityRecord.persistentID(.text(name))
            try visit(name)
            return true
        }
    }
    func status(_ id: String) throws -> PeerPackage.Status {
        _ = try beginRecord(id)
        if let documents,
            try files.readIfPresent(
                path: path(id, ["applied.json"]), maximumBytes: PeerPackage.maximumPageBytes) != nil
        {
            try documents.complete(packageID: id)
            byteCache.removeValue(forKey: id)
            objectCountCache.removeValue(forKey: id)
            activeStagedBytes = nil
        }
        if let total = byteCache[id] {
            return .init(packageID: id, sealed: try publication(id) != nil, receivedBytes: total)
        }
        let directory = root.appendingPathComponent(try path(id, ["objects"]).joined(separator: "/"))
        var total = UInt64(try JSON.encode(beginRecord(id)).count)
        var count = 0
        if FileManager.default.fileExists(atPath: directory.path) {
            try POSIXDirectory.withEntries(at: directory) { name in
                count += 1
                guard count <= limits.maximumObjects else {
                    throw TractandaError("resourceLimit", "Object count exceeded.")
                }
                _ = try AuthorityRecord.persistentID(.text(name))
                try POSIXDirectory.withEntries(at: directory.appendingPathComponent(name)) { chunk in
                    let metadata = try FileMetadata.read(
                        at: directory.appendingPathComponent(name).appendingPathComponent(chunk))
                    guard metadata.type == .regular, metadata.size <= UInt64(PeerPackage.maximumChunkBytes),
                        metadata.size <= limits.maximumStagedBytes - min(total, limits.maximumStagedBytes)
                    else {
                        throw TractandaError("resourceLimit", "Intake inventory quota or file type exceeded.")
                    }
                    total += metadata.size
                    return true
                }
                return true
            }
        }
        for name in ["prepared.json", "sealed.json", "applied.json"] {
            if let bytes = try files.readIfPresent(
                path: path(id, [name]), maximumBytes: PeerPackage.maximumPageBytes)
            {
                let next = total.addingReportingOverflow(UInt64(bytes.count))
                guard !next.overflow else {
                    throw TractandaError("resourceLimit", "Peer phase accounting overflow.")
                }
                total = next.partialValue
            }
        }
        if let originals {
            count += try originals.objectCount(packageID: id, maximum: limits.maximumObjects - count)
            let next = total.addingReportingOverflow(try originals.stagedBytes(packageID: id))
            guard !next.overflow else {
                throw TractandaError("resourceLimit", "Peer stage accounting overflow.")
            }
            total = next.partialValue
        }
        if let documents {
            let usage = try documents.accountedUsage(packageID: id)
            guard usage.objects <= limits.maximumObjects - count else {
                throw TractandaError("resourceLimit", "Package manifest count exceeded.")
            }
            count += usage.objects
            let next = total.addingReportingOverflow(usage.bytes)
            guard !next.overflow, next.partialValue <= limits.maximumStagedBytes else {
                throw TractandaError("resourceLimit", "Document stage/proof accounting exceeded quota.")
            }
            total = next.partialValue
        }
        if byteCache.count >= 256 { byteCache.removeAll(keepingCapacity: false) }
        byteCache[id] = total
        objectCountCache[id] = count
        return .init(packageID: id, sealed: try publication(id) != nil, receivedBytes: total)
    }
}
