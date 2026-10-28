import Foundation

extension PeerPackage {
    enum IntakePhase: String, Sendable { case staged, prepared, sealed, applied }
    struct IntakeState: Sendable {
        let packageID: String
        let manifestDigest: String
        let phase: IntakePhase
        /// A sealed publication still awaiting application, or an active Store recovery barrier.
        let recoveryRequired: Bool
    }
    enum ResumeSource: String, Sendable { case missing, staged, knownOriginal }
    struct ObjectResume: Sendable {
        let descriptor: Object
        let nextOffset: Int
        let source: ResumeSource
        var verifiedComplete: Bool = false
        /// Current reducer output only. Neither transferred bytes nor an applied receipt is a grant.
        var evaluation: AuthorityStore.Evaluation? = nil
    }
    /// Trusted internal continuation, not a wire-deserializable authority/context capability.
    struct ResumeCursor: Sendable {
        fileprivate struct Frame: Sendable {
            let descriptor: Object
            var position: Int = -1
        }
        fileprivate struct DocumentCursor: Sendable {
            let manifest: Object
            var manifestReported = false
            var manifestVisited = false
            var frames: [Frame] = []
        }
        func retainedByteCount() throws -> Int {
            let descriptors =
                frames.map(\.descriptor)
                + (document.map { [$0.manifest] + $0.frames.map(\.descriptor) } ?? [])
            return try JSON.encode(descriptors).count + 2048
        }
        fileprivate let packageID: String
        fileprivate let manifestDigest: String
        fileprivate let contextDigest: String
        fileprivate var frames: [Frame]
        fileprivate var work: Int = 0
        fileprivate var document: DocumentCursor? = nil
    }
    struct ResumePage: Sendable {
        let state: IntakeState
        let objects: [ObjectResume]
        let nextCursor: ResumeCursor?
        /// Transfer this index page, then retry the same continuation to discover its children.
        let blockedOnIndex: Bool
    }
}

extension PeerIntakeJournal {
    private func resumePath(_ id: String, _ suffix: [String]) throws -> [String] {
        _ = try AuthorityRecord.persistentID(.text(id))
        return ["authority", "intake", id] + suffix
    }
    func intakeState(context: PeerPackage.Context, packageID: String, recoveryRequired: Bool = false)
        throws -> PeerPackage.IntakeState
    {
        let begin = try beginRecord(packageID)
        guard begin.context == context else {
            throw TractandaError("peerConfigurationChanged", "Session/configuration binding changed.")
        }
        try begin.manifest.validate(retained: true)
        guard begin.manifest.packageID == packageID, begin.manifest.storeID == context.storeID else {
            throw TractandaError("invalidPeerPackage", "Journal manifest/folder/store binding differs.")
        }
        let digest = AuthorityRecordCodec.sha256(try JSON.encode(begin.manifest))
        let prepared = try preparedPublication(packageID)
        let sealed = try publication(packageID)
        let applied = try files.readIfPresent(
            path: resumePath(packageID, ["applied.json"]), maximumBytes: PeerPackage.maximumPageBytes
        ).map { try PeerPackage.decode(Publication.self, $0) }
        for record in [prepared, sealed, applied].compactMap({ $0 }) {
            guard record.packageID == packageID, record.context == context,
                record.manifestDigest == digest
            else { throw TractandaError("invalidPeerPackage", "Journal phase binding differs.") }
        }
        guard sealed == nil || sealed == prepared, applied == nil || applied == sealed else {
            throw TractandaError("invalidPeerPackage", "Journal phase closure differs.")
        }
        return .init(
            packageID: packageID, manifestDigest: digest,
            phase: applied != nil
                ? .applied : sealed != nil ? .sealed : prepared != nil ? .prepared : .staged,
            recoveryRequired: recoveryRequired || (sealed != nil && applied == nil))
    }

    /// Traverses only the immutable manifest hierarchy. No total-object collection is retained.
    /// `knownOriginal` must use a verified receiver locator, never a sender filesystem path.
    func resumePage(
        context: PeerPackage.Context, packageID: String, cursor: PeerPackage.ResumeCursor? = nil,
        limit: Int = 128, recoveryRequired: Bool = false,
        knownOriginal: (PeerPackage.Object) throws -> Data? = { _ in nil },
        evaluation: (PeerPackage.Object) throws -> AuthorityStore.Evaluation? = { _ in nil },
        progress: (() throws -> Void)? = nil
    ) throws -> PeerPackage.ResumePage {
        let state = try intakeState(
            context: context, packageID: packageID, recoveryRequired: recoveryRequired)
        let maximumDepth = min(limits.maximumDepth, 64)
        guard limit > 0, limit <= 128, maximumDepth >= 0, limits.maximumWork > 0 else {
            throw TractandaError("resourceLimit", "Resume page limit must be between 1 and 128.")
        }
        let begin = try beginRecord(packageID)
        let contextDigest = AuthorityRecordCodec.sha256(try JSON.encode(context))
        var next =
            cursor
            ?? .init(
                packageID: packageID, manifestDigest: state.manifestDigest, contextDigest: contextDigest,
                frames: [.init(descriptor: begin.manifest.root)])
        guard next.packageID == packageID, next.manifestDigest == state.manifestDigest,
            next.contextDigest == contextDigest, next.frames.count <= maximumDepth + 1,
            next.frames.first?.descriptor == begin.manifest.root || next.frames.isEmpty,
            next.frames.allSatisfy({ $0.descriptor.kind == .index && $0.position >= -1 && $0.position <= 256 }
            ),
            Set(next.frames.map { $0.descriptor.id }).count == next.frames.count,
            next.work >= 0, next.work <= limits.maximumWork
        else { throw TractandaError("invalidPeerCursor", "Resume continuation belongs to another package.") }
        var operationWork = 0
        let originalBudget = PeerOriginalReadBudget(
            bytes: limits.maximumReadBytes, maximumSteps: limits.maximumWork,
            onStep: { try check() })
        var readBytes: UInt64 = 0
        // One parsed page per active DFS depth, never a total-package page collection.
        var pages: [String: PeerPackage.Page] = [:]
        var metadataBytes = try next.frames.reduce(512) { try $0 + JSON.encode($1.descriptor).count + 32 }
        if let document = next.document {
            metadataBytes += try JSON.encode(document.manifest).count + 64
            metadataBytes += try document.frames.reduce(0) { try $0 + JSON.encode($1.descriptor).count + 32 }
        }
        var output: [PeerPackage.ObjectResume] = []
        func check() throws {
            try Task.checkCancellation()
            try progress?()
            guard operationWork < limits.maximumWork else {
                throw TractandaError(
                    "peerPayloadVerifying", "Resume operation work exhausted; continue traversal.")
            }
            operationWork += 1
        }
        func charge(_ bytes: Int) throws {
            guard bytes >= 0, UInt64(bytes) <= originalBudget.capacity else {
                throw TractandaError("resourceLimit", "One metadata read exceeds the caller window.")
            }
            try originalBudget.charge(bytes)
            readBytes += UInt64(bytes)
        }
        func inspect(_ object: PeerPackage.Object) throws -> (PeerPackage.ObjectResume, Data?) {
            try object.validate(retainedProfile: begin.manifest.profile)
            if object.kind == .attachment {
                guard
                    [PeerPackage.profile, PeerPackage.retainedOriginalProfile].contains(
                        begin.manifest.profile), let originals
                else {
                    throw TractandaError("missingDependencies", "Original streaming is unavailable.")
                }
                return (
                    try originals.resume(
                        packageID: packageID, object: object, progress: progress, budget: originalBudget), nil
                )
            }
            try originalBudget.requireWorkingSet(
                bytes: UInt64(object.length * (object.kind == .index ? 1 : 2) + 16 * 1024),
                steps: (object.length - 1) / object.chunkBytes + 6,
                label: "One metadata resume step")
            try check()
            let prefix = try resumePath(packageID, ["objects", object.id])
            if let descriptor = try files.readIfPresent(
                path: prefix + ["descriptor.json"], maximumBytes: PeerPackage.maximumPageBytes,
                readBudget: charge)
            {
                guard try PeerPackage.decode(PeerPackage.Object.self, descriptor) == object else {
                    throw TractandaError("peerObjectCollision", "Resume descriptor differs.")
                }
            }
            var original: Data?
            if object.kind != .index {
                try charge(object.length)
                original = try knownOriginal(object)
                if original == nil, let sealed = try publication(packageID) {
                    original = try retainedBytes(object, publication: sealed)
                }
                if let original {
                    guard original.count == object.length,
                        AuthorityRecordCodec.sha256(original) == object.sha256
                    else { throw TractandaError("peerObjectCollision", "Known original differs.") }
                }
            }
            var bytes = Data()
            var gap = false
            var lacksProof = false
            for offset in stride(from: 0, to: object.length, by: PeerPackage.maximumChunkBytes) {
                try check()
                let part = try files.readIfPresent(
                    path: prefix + [String(offset)], maximumBytes: PeerPackage.maximumChunkBytes,
                    readBudget: charge)
                let receipt = try files.readIfPresent(
                    path: prefix + [String(offset) + ".proof.json"], maximumBytes: 4096,
                    readBudget: charge)
                let proof = try receipt.map { data -> ChunkProof in
                    let value = try PeerPackage.decode(ChunkProof.self, data, maximum: 4096)
                    guard value.object == object, value.offset == offset,
                        value.length == min(PeerPackage.maximumChunkBytes, object.length - offset)
                    else { throw TractandaError("peerObjectCollision", "Chunk proof binding differs.") }
                    _ = try AuthorityRecord.digest(.text(value.sha256))
                    return value
                }
                guard let part else {
                    gap = true
                    continue
                }
                guard !gap, part.count == min(PeerPackage.maximumChunkBytes, object.length - offset) else {
                    throw TractandaError("invalidPeerPackage", "Staged prefix is truncated or noncontiguous.")
                }
                if let proof {
                    guard AuthorityRecordCodec.sha256(part) == proof.sha256 else {
                        throw TractandaError("peerObjectCollision", "Staged chunk digest differs.")
                    }
                } else {
                    lacksProof = true
                }
                if let original, Data(original[offset..<offset + part.count]) != part {
                    throw TractandaError("peerObjectCollision", "Staged bytes differ from known original.")
                }
                bytes.append(part)
            }
            let complete = bytes.count == object.length
            if complete {
                guard AuthorityRecordCodec.sha256(bytes) == object.sha256 else {
                    throw TractandaError("peerObjectCollision", "Staged original digest differs.")
                }
            } else if lacksProof, original == nil {
                throw TractandaError(
                    "peerResumeProofMissing", "Partial legacy stage has no verifiable chunk proof.")
            }
            let result = PeerPackage.ObjectResume(
                descriptor: object, nextOffset: original == nil ? bytes.count : object.length,
                source: original != nil ? .knownOriginal : bytes.isEmpty ? .missing : .staged,
                verifiedComplete: original != nil || complete, evaluation: try evaluation(object))
            return (result, original ?? (complete ? bytes : nil))
        }
        func append(_ value: PeerPackage.ObjectResume) throws {
            let cost =
                try JSON.encode(value.descriptor).count + 128
                + (value.evaluation?.reason.utf8.count ?? 0)
                + (value.evaluation?.evidenceID?.utf8.count ?? 0)
                + (value.evaluation?.evidenceDigest?.utf8.count ?? 0)
                + (value.evaluation?.evidencePackageID?.utf8.count ?? 0)
            guard cost <= PeerPackage.maximumPageBytes - metadataBytes else {
                throw TractandaError(
                    output.isEmpty ? "resourceLimit" : "peerPayloadVerifying",
                    "Resume result metadata window exhausted.")
            }
            metadataBytes += cost
            output.append(value)
        }
        func documentStep() throws -> Bool {
            guard var cursor = next.document, let documents else {
                throw TractandaError("missingDependencies", "Document streaming is unavailable.")
            }
            try cursor.manifest.validate()
            guard cursor.manifest.kind == .document, cursor.manifest.part == .manifest,
                cursor.frames.count <= 10,
                cursor.frames.allSatisfy({
                    $0.descriptor.kind == .document && $0.descriptor.id == cursor.manifest.id
                        && $0.descriptor.part?.role != .manifest && (-1...128).contains($0.position)
                })
            else { throw TractandaError("invalidPeerCursor", "Invalid document continuation.") }
            let ancestorBytes = cursor.frames.dropLast().reduce(UInt64(0)) {
                $0 + UInt64($1.descriptor.length)
            }
            let semanticNode =
                cursor.frames.last.flatMap {
                    $0.descriptor.part?.role == .node ? $0.descriptor.length : nil
                } ?? 0
            try originalBudget.requireWorkingSet(
                bytes: UInt64(2 * cursor.manifest.length + semanticNode)
                    + ancestorBytes + UInt64(cursor.frames.count + 3) * 16 * 1024,
                steps: 2 * cursor.frames.count + 8, label: "One document resume proof step")
            if !cursor.manifestVisited {
                if !cursor.manifestReported {
                    let value = try documents.resume(
                        packageID: packageID, object: cursor.manifest, budget: originalBudget)
                    try append(value)
                    guard value.verifiedComplete else { return false }
                    cursor.manifestReported = true
                    next.document = cursor
                }
                let (manifest, _) = try documents.manifest(
                    packageID: packageID, contentID: cursor.manifest.id, budget: originalBudget)
                let root = PeerPackage.Object(
                    kind: .document, id: cursor.manifest.id, length: Int(manifest.rootByteCount),
                    sha256: manifest.rootSHA256,
                    part: .init(role: .node, level: manifest.rootLevel, ordinal: 0))
                try root.validate()
                cursor.manifestVisited = true
                cursor.frames = [.init(descriptor: root)]
                next.document = cursor
                return true
            }
            guard let frame = cursor.frames.last else {
                next.document = nil
                return true
            }
            let top = cursor.frames.count - 1
            if frame.position == -1 {
                let value = try documents.resume(
                    packageID: packageID, object: frame.descriptor, budget: originalBudget)
                try append(value)
                guard value.verifiedComplete else { return false }
                if frame.descriptor.part?.role == .page {
                    cursor.frames.removeLast()
                    next.document = cursor
                    return true
                }
                cursor.frames[top].position = 0
                next.document = cursor
            }
            let raw = try documents.partBytes(
                packageID: packageID, object: frame.descriptor, budget: originalBudget)
            let node = try DocumentValue.strictDecode(DocumentHashNode.self, data: raw)
            try node.validate()
            guard node.level == frame.descriptor.part?.level,
                node.ordinal == frame.descriptor.part?.ordinal
            else { throw TractandaError("peerObjectCollision", "Document proof cursor identity differs.") }
            let position = cursor.frames[top].position
            if position == node.entries.count {
                cursor.frames.removeLast()
            } else {
                guard position < node.entries.count, cursor.frames.count < 10 else {
                    throw TractandaError("invalidPeerCursor", "Document proof cursor range differs.")
                }
                let edge = node.entries[position]
                let child = PeerPackage.Object(
                    kind: .document, id: cursor.manifest.id, length: Int(edge.byteCount), sha256: edge.sha256,
                    part: .init(
                        role: node.level == 0 ? .page : .node, level: max(0, node.level - 1),
                        ordinal: edge.ordinal))
                try child.validate()
                cursor.frames[top].position += 1
                cursor.frames.append(.init(descriptor: child))
            }
            next.document = cursor
            return true
        }
        do {
            while !next.frames.isEmpty || next.document != nil, output.count < limit {
                try check()
                if next.document != nil {
                    guard try documentStep() else {
                        return .init(state: state, objects: output, nextCursor: next, blockedOnIndex: true)
                    }
                    continue
                }
                let top = next.frames.count - 1
                let frame = next.frames[top]
                if frame.position == -1 {
                    let (value, pageBytes) = try inspect(frame.descriptor)
                    try append(value)
                    guard pageBytes != nil else {
                        return .init(state: state, objects: output, nextCursor: next, blockedOnIndex: true)
                    }
                    next.frames[top].position = 0
                    if output.count == limit { break }
                }
                let page: PeerPackage.Page
                if let cached = pages[frame.descriptor.id] {
                    page = cached
                } else {
                    let (_, pageBytes) = try inspect(frame.descriptor)
                    guard let pageBytes else {
                        throw TractandaError("invalidPeerPackage", "An immutable index page disappeared.")
                    }
                    page = try PeerPackage.decode(PeerPackage.Page.self, pageBytes)
                    try page.validate(retainedProfile: begin.manifest.profile)
                    pages[frame.descriptor.id] = page
                }
                let position = next.frames[top].position
                let entries = page.children.isEmpty ? page.objects : page.children
                guard position < entries.count else {
                    pages.removeValue(forKey: frame.descriptor.id)
                    next.frames.removeLast()
                    continue
                }
                let entry = entries[position]
                guard next.work < limits.maximumWork else {
                    throw TractandaError("resourceLimit", "Package metadata traversal work exhausted.")
                }
                if entry.kind == .index {
                    guard next.frames.count <= maximumDepth,
                        !next.frames.contains(where: { $0.descriptor.id == entry.id })
                    else { throw TractandaError("resourceLimit", "Resume index cycle or depth exhausted.") }
                    let frameCost = try JSON.encode(entry).count + 32
                    guard frameCost <= PeerPackage.maximumPageBytes - metadataBytes else {
                        throw TractandaError("resourceLimit", "Resume continuation metadata exhausted.")
                    }
                    metadataBytes += frameCost
                    next.frames.append(.init(descriptor: entry))
                } else if entry.kind == .document {
                    try admitDocumentAnchor(packageID: packageID, object: entry)
                    next.document = .init(manifest: entry)
                } else {
                    try append(inspect(entry).0)
                }
                next.frames[top].position += 1
                next.work += 1
            }
        } catch let error as TractandaError where error.code == "peerPayloadVerifying" {
            try Task.checkCancellation()
            try progress?()
            return .init(state: state, objects: output, nextCursor: next, blockedOnIndex: false)
        }
        try Task.checkCancellation()
        try progress?()
        return .init(
            state: state, objects: output,
            nextCursor: next.frames.isEmpty && next.document == nil ? nil : next,
            blockedOnIndex: false)
    }
}

extension PeerIntakeJournal {
    /// Private descriptor walk for atomic intake work. Unlike wire resume it does not expand a
    /// saved document into repeated composite IDs or hydrate every original. The namespace-bound
    /// cursor is never accepted by the public transfer-resume parser. Prefixes grant no authority.
    func atomicMetadataPage(
        context: PeerPackage.Context, packageID: String,
        cursor: PeerPackage.ResumeCursor?, limit: Int = 16,
        readBudget: ((Int) throws -> Void)? = nil,
        visitIndex: ((PeerPackage.Object) throws -> Void)? = nil
    ) throws -> (objects: [PeerPackage.Object], next: PeerPackage.ResumeCursor?) {
        guard (1...128).contains(limit) else {
            throw TractandaError("resourceLimit", "Invalid atomic metadata work window.")
        }
        let begin = try beginRecord(packageID, readBudget: readBudget)
        guard begin.context == context else {
            throw TractandaError("untrustedPeer", "Atomic metadata work changed authenticated context.")
        }
        let manifest = AuthorityRecordCodec.sha256(try JSON.encode(begin.manifest))
        let namespace = AuthorityRecordCodec.sha256(
            Data("tractanda.private-atomic-metadata.v1".utf8) + (try JSON.encode(context)))
        var next =
            cursor
            ?? .init(
                packageID: packageID, manifestDigest: manifest, contextDigest: namespace,
                frames: [.init(descriptor: begin.manifest.root)])
        let depth = min(64, limits.maximumDepth)
        guard next.packageID == packageID, next.manifestDigest == manifest,
            next.contextDigest == namespace, next.document == nil,
            next.frames.count <= depth + 1,
            next.frames.first?.descriptor == begin.manifest.root || next.frames.isEmpty,
            next.frames.allSatisfy({ $0.descriptor.kind == .index && (-1...256).contains($0.position) }),
            Set(next.frames.map { $0.descriptor.id }).count == next.frames.count,
            next.work >= 0, next.work <= min(limits.maximumWork, limits.maximumObjects)
        else { throw TractandaError("invalidPeerCursor", "Atomic private metadata cursor lost its root.") }
        var pages: [String: PeerPackage.Page] = [:]
        var result: [PeerPackage.Object] = []
        var units = 0
        while !next.frames.isEmpty, result.count < limit, units < limit * 4 + 128 {
            try Task.checkCancellation()
            let position = next.frames.count - 1
            let frame = next.frames[position]
            let page: PeerPackage.Page
            if let saved = pages[frame.descriptor.id] {
                page = saved
            } else {
                guard
                    let bytes = try object(
                        frame.descriptor, packageID: packageID, readBudget: readBudget)
                else {
                    throw TractandaError("missingDependencies", "Atomic metadata index is incomplete.")
                }
                page = try PeerPackage.decode(PeerPackage.Page.self, bytes)
                try page.validate(retainedProfile: begin.manifest.profile)
                pages[frame.descriptor.id] = page
            }
            if frame.position == -1 {
                guard next.work < min(limits.maximumWork, limits.maximumObjects) else {
                    throw TractandaError("resourceLimit", "Atomic metadata closure work exhausted.")
                }
                try visitIndex?(frame.descriptor)
                next.work += 1
                units += 1
                next.frames[position].position = 0
                continue
            }
            let entries = page.children.isEmpty ? page.objects : page.children
            guard frame.position <= entries.count else {
                throw TractandaError("invalidPeerCursor", "Atomic metadata cursor skipped its page.")
            }
            if frame.position == entries.count {
                next.frames.removeLast()
                pages.removeValue(forKey: frame.descriptor.id)
                units += 1
                continue
            }
            let entry = entries[frame.position]
            try entry.validate(retainedProfile: begin.manifest.profile)
            next.frames[position].position += 1
            if entry.kind == .index {
                guard next.frames.count <= depth,
                    !next.frames.contains(where: { $0.descriptor.id == entry.id })
                else { throw TractandaError("invalidPeerPackage", "Atomic metadata index cycle/depth.") }
                next.frames.append(.init(descriptor: entry))
            } else {
                guard next.work < min(limits.maximumWork, limits.maximumObjects) else {
                    throw TractandaError("resourceLimit", "Atomic metadata closure object count exhausted.")
                }
                next.work += 1
                result.append(entry)
            }
            units += 1
        }
        return (result, next.frames.isEmpty ? nil : next)
    }
}
