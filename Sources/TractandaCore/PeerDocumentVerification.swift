import Foundation

/// Disk-backed storage progress only. Source/original closure and current authority belong to
/// the caller. A process restart discards verification certificates, never transferred bytes.
final class PeerDocumentVerification {
    static func canonicalScope(_ contentID: String) -> String { "canonical-document:" + contentID }
    enum Source {
        case incoming(packageID: String, transfer: PeerDocumentTransfer)
        case canonical
    }
    struct Frame: Codable {
        let object: PeerPackage.Object
        let firstPage: Int64
        let lastPage: Int64
        var position = -1
    }
    struct State: Codable {
        let epoch: String
        let root: PeerPackage.Object
        var base: [String]
        var rootStamp: PeerOriginalTransfer.Stamp
        var phase = "walk"
        var frames: [Frame]
        var parts: Int64 = 1
        var pages: Int64 = 0
        var encodedBytes: Int64 = 0
        var coverage = [Int64](repeating: 0, count: 5)
        // Scalar bounds for one hydrated proof/semantic step, retained after DFS frames empty.
        // Inspection must not spin forever if the caller lowers its window after freezing.
        var minimumReadBytes: UInt64? = nil
        var minimumWorkSteps: Int? = nil
        var corpus: PeerDocumentCorpusToken? = nil
        var corpusUnits: Int64? = nil
        var corpusBytes: Int64? = nil
    }
    private struct Job {
        let key: String
        let inspection: DocumentContentFiles.PeerTreeInspection
        var touched = ProcessInfo.processInfo.systemUptime
    }
    private let epoch: String
    let contents: DocumentContentStore
    private let originals: PeerOriginalTransfer
    var corpusBoundary: ((IndexCorpusWriteBatch) throws -> Void)?
    private var jobs: [String: Job] = [:]
    // Three fixed verification slots per at most 256 logical contexts. Parked inspection
    // frames contain bounded names/metadata and no directory or original descriptors.
    private var parked: [String: Job] = [:]
    private var activeInspections = 0
    func releaseLogicalVerification(_ owner: String) {
        parked = parked.filter { !$0.key.hasPrefix(owner + ":") }
    }
    func inspectionCountsForTesting() -> (ordinary: Int, parked: Int, active: Int, descriptors: Int) {
        (
            jobs.count, parked.count, activeInspections,
            parked.values.filter { $0.inspection.retainsDirectoryDescriptors }.count
        )
    }
    private func job(_ key: String) -> Job? {
        if let owner = originals.logicalVerificationOwner {
            return parked[owner].flatMap { $0.key == key ? $0 : nil }
        }
        return jobs[key]
    }
    private func removeJob(_ key: String) {
        if let owner = originals.logicalVerificationOwner {
            if parked[owner]?.key == key { parked.removeValue(forKey: owner) }
        } else {
            jobs.removeValue(forKey: key)
        }
    }
    private func touchJob(_ key: String) {
        if let owner = originals.logicalVerificationOwner {
            if parked[owner]?.key == key { parked[owner]?.touched = ProcessInfo.processInfo.systemUptime }
        } else {
            jobs[key]?.touched = ProcessInfo.processInfo.systemUptime
        }
    }
    private func inspection(_ key: String, base: [String]) throws -> DocumentContentFiles.PeerTreeInspection {
        if let owner = originals.logicalVerificationOwner {
            if let retained = parked[owner], retained.key != key {
                throw TractandaError(
                    "peerVerificationBusy", "Finish the logical inspection slot before another object.")
            }
            if parked[owner] == nil {
                guard parked.count < 768 else {
                    throw TractandaError("peerVerificationBusy", "Parked inspection slots are busy.")
                }
                parked[owner] = .init(
                    key: key, inspection: try contents.beginPeerInspection(base: base, parkable: true))
            }
            return parked[owner]!.inspection
        }
        if jobs[key] == nil {
            guard jobs.count < 8 else {
                throw TractandaError("peerVerificationBusy", "Inspection slots are busy.")
            }
            jobs[key] = .init(key: key, inspection: try contents.beginPeerInspection(base: base))
        }
        return jobs[key]!.inspection
    }
    init(contents: DocumentContentStore, originals: PeerOriginalTransfer) throws {
        self.contents = contents
        self.originals = originals
        epoch = try UUID.makeVersion1().uuidString.lowercased()
    }
    private func base(_ source: Source, reference: DocumentContentReference, budget: PeerOriginalReadBudget)
        throws -> [String]
    {
        switch source {
        case .incoming(let package, let transfer):
            return try transfer.inspectionBase(
                packageID: package, contentID: reference.contentID, budget: budget)
        case .canonical: return try contents.directory(reference.contentID)
        }
    }
    private func file(
        _ object: PeerPackage.Object, source: Source, reference: DocumentContentReference,
        base: [String], scope: String, budget: PeerOriginalReadBudget
    ) throws -> PeerOriginalFile {
        switch source {
        case .incoming(let package, let transfer):
            guard try transfer.resume(packageID: package, object: object, budget: budget).verifiedComplete
            else {
                throw TractandaError("missingDependencies", "Document part transfer is incomplete.")
            }
        case .canonical:
            guard let part = object.part,
                try contents.peerExpectedPart(reference, part: part, budget: budget) == object
            else {
                throw TractandaError("peerObjectCollision", "Canonical document edge differs.")
            }
        }
        let file = try contents.peerPartFile(base: base, object: object)
        let token = AuthorityRecordCodec.sha256(Data((scope + ":" + object.key).utf8))
        guard file.metadata.size == UInt64(object.length),
            try originals.verifyDocumentPart(
                file: file, key: token, object: object, proofPrefix: nil, whole: true, budget: budget)
        else {
            throw TractandaError("missingDependencies", "Document part verification is incomplete.")
        }
        return file
    }
    private func bytes(
        _ object: PeerPackage.Object, source: Source, reference: DocumentContentReference,
        base: [String], scope: String, budget: PeerOriginalReadBudget
    ) throws -> (Data, PeerOriginalFile) {
        let file = try file(
            object, source: source, reference: reference, base: base, scope: scope, budget: budget)
        try budget.charge(object.length)
        var raw = Data()
        raw.reserveCapacity(object.length)
        for offset in stride(from: 0, to: object.length, by: PeerPackage.maximumPayloadChunkBytes) {
            raw.append(
                try file.read(
                    offset: Int64(offset),
                    count: min(PeerPackage.maximumPayloadChunkBytes, object.length - offset)))
        }
        return (raw, file)
    }
    private func manifest(
        _ source: Source, document: AttachmentDocumentRepresentation,
        budget: PeerOriginalReadBudget
    ) throws -> (DocumentManifest, DocumentContentReference, PeerPackage.Object, Data) {
        guard let reference = document.content else {
            throw TractandaError("invalidPeerPackage", "Paged reference is required.")
        }
        let raw: Data
        switch source {
        case .incoming(let package, let transfer):
            // Binding reads precede knowledge of the anchored manifest's exact length.
            // Admit their bounded metadata window before any charged read, so an unusable
            // initial allowance cannot masquerade as resumable verification exhaustion.
            try budget.requireWorkingSet(
                bytes: 4096, steps: 4, label: "Document manifest binding hydration")
            let tree = try transfer.tree(packageID: package, contentID: reference.contentID, budget: budget)
            guard tree.manifest.sha256 == reference.manifestSHA256 else {
                throw TractandaError("peerObjectCollision", "Package manifest differs from its revision.")
            }
            try budget.requireWorkingSet(
                bytes: UInt64(tree.manifest.length + 16 * 1024), steps: 4,
                label: "Document manifest hydration")
            raw = try transfer.partBytes(packageID: package, object: tree.manifest, budget: budget)
        case .canonical: raw = try contents.peerManifestBytes(reference, budget: budget)
        }
        let manifest = try contents.validatePeerManifest(raw, reference: reference)
        guard manifest.source == document.source, manifest.identity == document.identity,
            manifest.extractedAt == document.extractedAt
        else { throw TractandaError("peerObjectCollision", "Document provenance differs.") }
        return (
            manifest, reference,
            .init(
                kind: .document, id: reference.contentID, length: raw.count,
                sha256: reference.manifestSHA256, part: .manifest), raw
        )
    }
    private func node(_ raw: Data, frame: Frame) throws -> DocumentHashNode {
        let node = try DocumentValue.strictDecode(DocumentHashNode.self, data: raw)
        try node.validate()
        guard node.level == frame.object.part?.level, node.ordinal == frame.object.part?.ordinal,
            node.entries.first?.firstPage == frame.firstPage, node.entries.last?.lastPage == frame.lastPage
        else {
            throw TractandaError("peerObjectCollision", "Document node coverage differs.")
        }
        return node
    }
    private func validate(_ state: State, root: PeerPackage.Object, manifest: DocumentManifest) throws {
        guard state.root == root, state.frames.count <= 10, state.parts > 0, state.pages >= 0,
            state.encodedBytes >= 0, state.coverage.count == 5,
            state.pages <= manifest.pageCount, state.encodedBytes <= manifest.totalEncodedBytes,
            ["walk", "inspect", "ready", "published"].contains(state.phase)
        else {
            throw TractandaError("peerObjectCollision", "Document cursor differs.")
        }
        let coverage = try DocumentCoverage(
            converted: state.coverage[0], unsupported: state.coverage[1],
            truncated: state.coverage[2], timedOut: state.coverage[3], failed: state.coverage[4])
        guard try coverage.processedPageCount() == state.pages else {
            throw TractandaError("peerObjectCollision", "Cursor coverage differs.")
        }
        for frame in state.frames {
            try frame.object.validate()
            guard frame.object.kind == .document, frame.object.part?.role != .manifest,
                frame.object.id == root.id, frame.firstPage > 0, frame.lastPage >= frame.firstPage,
                frame.lastPage <= manifest.pageCount, (-1...128).contains(frame.position)
            else {
                throw TractandaError("peerObjectCollision", "Invalid proof frame.")
            }
        }
    }
    /// Operation limits never cap aggregate document pages. Progress lives in indexed SQL rows;
    /// at most nine parsed nodes, one page and eight bounded inspection jobs live in memory.
    func step(
        scope: String, document: AttachmentDocumentRepresentation, source: Source,
        index: ItemIndex, budget: PeerOriginalReadBudget, maximumUnits: Int = 16,
        publish: Bool = false, corpusPackageID: String? = nil, beforePublication: () throws -> Void = {}
    ) throws -> Bool {
        guard (1...128).contains(maximumUnits) else {
            throw TractandaError("resourceLimit", "Invalid document work window.")
        }
        let (manifest, reference, root, manifestBytes) = try manifest(
            source, document: document, budget: budget)
        let physical = try base(source, reference: reference, budget: budget)
        let stamp = PeerOriginalTransfer.Stamp(try contents.peerRootMetadata(physical))
        try index.initializePeerDocumentSchema()
        var state = try index.peerDocumentState(scope: scope, content: root.id).map {
            try PeerPackage.decode(State.self, $0)
        }
        if let old = state, old.root != root {
            throw TractandaError("peerObjectCollision", "Document scope root changed.")
        }
        if state?.epoch != epoch || state?.rootStamp != stamp {
            try index.peerDocumentReset(scope: scope, content: root.id)
            let node = PeerPackage.Object(
                kind: .document, id: root.id, length: Int(manifest.rootByteCount),
                sha256: manifest.rootSHA256, part: .init(role: .node, level: manifest.rootLevel, ordinal: 0))
            try node.validate()
            state = .init(
                epoch: epoch, root: root, base: physical, rootStamp: stamp,
                frames: [.init(object: node, firstPage: 1, lastPage: manifest.pageCount)])
            // manifest() just authenticated the exact bytes. Seed its stamp without
            // repeating proof hydration/hash reads before the first walk admission.
            let file = try contents.peerPartFile(base: physical, object: root)
            try index.peerDocumentRecord(scope: scope, object: root, metadata: file.metadata)
        }
        var current = state!
        current.base = physical
        try validate(current, root: root, manifest: manifest)
        let jobKey = scope + ":" + root.id
        let initialProgress = try JSON.encode(current)
        let initialInspectionCount = job(jobKey)?.inspection.count ?? 0
        var inspectionAdvanced = false
        defer { touchJob(jobKey) }
        let corpusOwner: String?
        if let corpusPackageID {
            corpusOwner = corpusPackageID
        } else if case .incoming(let package, _) = source {
            corpusOwner = package
        } else {
            corpusOwner = nil
        }
        var corpusReservationWork: String?
        func corpusWriteBoundary(_ batch: IndexCorpusWriteBatch) throws {
            corpusReservationWork = batch.workID
            try corpusBoundary?(batch)
        }
        func observeCorpus() throws {
            if let work = corpusReservationWork ?? current.corpus?.workID, corpusOwner != nil {
                try corpusBoundary?(
                    .init(
                        phase: .afterCommit, workID: work,
                        estimatedAdditionalBytes: 0, units: 0,
                        retainedEncodedBytes: index.corpusRetainedBytes(work)))
            }
        }
        func renewCorpusProgress() throws {
            let changed = try JSON.encode(current) != initialProgress
            guard let token = current.corpus, corpusOwner != nil,
                inspectionAdvanced || (job(jobKey)?.inspection.count ?? 0) > initialInspectionCount
                    || changed
            else { return }
            try index.touchPeerDocumentCorpus(token)
        }
        try index.execute("SAVEPOINT peer_document_step")
        do {
            if let corpusOwner {
                let priorWork = current.corpus?.workID
                current.corpus = try index.beginPeerDocumentCorpus(
                    packageID: corpusOwner, document: document,
                    boundary: corpusWriteBoundary)
                if current.corpus?.reusable == false,
                    ["ready", "published"].contains(current.phase) || priorWork != current.corpus?.workID
                {
                    current.phase = "walk"
                    current.parts = 1
                    current.pages = 0
                    current.encodedBytes = 0
                    current.coverage = [Int64](repeating: 0, count: 5)
                    current.corpusUnits = 0
                    current.corpusBytes = 0
                    let node = PeerPackage.Object(
                        kind: .document, id: root.id,
                        length: Int(manifest.rootByteCount), sha256: manifest.rootSHA256,
                        part: .init(role: .node, level: manifest.rootLevel, ordinal: 0))
                    current.frames = [.init(object: node, firstPage: 1, lastPage: manifest.pageCount)]
                }
            }
            if current.phase == "published" || (current.phase == "ready" && !publish) {
                removeJob(jobKey)
                try index.peerDocumentSave(scope: scope, content: root.id, state: JSON.encode(current))
                try index.execute("RELEASE SAVEPOINT peer_document_step")
                try observeCorpus()
                return true
            }
            if current.phase == "ready" { current.phase = "inspect" }
            var nodes: [String: DocumentHashNode] = [:]
            var units = 0
            while current.phase == "walk", !current.frames.isEmpty, units < maximumUnits {
                try budget.step()
                units += 1
                let top = current.frames.count - 1
                var frame = current.frames[top]
                let ancestorBytes = current.frames.dropLast().reduce(UInt64(0)) {
                    $0 + UInt64($1.object.length)
                }
                let workingBytes =
                    UInt64(frame.object.length + 2 * manifestBytes.count + 16 * 1024)
                    + ancestorBytes + UInt64(current.frames.count + 2) * 16 * 1024
                current.minimumReadBytes = max(current.minimumReadBytes ?? 0, workingBytes)
                current.minimumWorkSteps = max(
                    current.minimumWorkSteps ?? 0, 2 * current.frames.count + 8)
                try budget.requireWorkingSet(
                    bytes: workingBytes, steps: 2 * current.frames.count + 8,
                    label: "One document proof/semantic step")
                if frame.position == -1 {
                    let (raw, file) = try bytes(
                        frame.object, source: source, reference: reference,
                        base: physical, scope: scope, budget: budget)
                    try index.peerDocumentRecord(scope: scope, object: frame.object, metadata: file.metadata)
                    let parts = current.parts.addingReportingOverflow(1)
                    guard !parts.overflow else {
                        throw TractandaError("resourceLimit", "Document part count overflowed.")
                    }
                    current.parts = parts.partialValue
                    if frame.object.part!.role == .page {
                        let page = try contents.validatePeerPage(
                            raw, source: manifest.source, identity: manifest.identity,
                            number: frame.object.part!.ordinal)
                        let pages = current.pages.addingReportingOverflow(1)
                        let total = current.encodedBytes.addingReportingOverflow(Int64(raw.count))
                        guard !pages.overflow, !total.overflow, page.pageNumber == pages.partialValue,
                            let status = ["converted", "unsupported", "truncated", "timeout", "failed"]
                                .firstIndex(of: page.status)
                        else {
                            throw TractandaError("peerObjectCollision", "Document pages are not contiguous.")
                        }
                        current.pages = pages.partialValue
                        current.encodedBytes = total.partialValue
                        current.coverage[status] += 1
                        if let token = current.corpus, corpusOwner != nil, !token.reusable,
                            let unit = try PageCorpusEmitter.documentUnit(
                                page,
                                document: PageCorpusDocumentPlan(document: document),
                                ordinal: current.corpusUnits ?? 0, byteStart: current.corpusBytes ?? 0)
                        {
                            try index.appendPeerDocumentCorpus(
                                unit, token: token,
                                boundary: corpusWriteBoundary)
                            current.corpusUnits = try PageCorpusEmitter.add(current.corpusUnits ?? 0, 1)
                            current.corpusBytes = try PageCorpusEmitter.add(
                                current.corpusBytes ?? 0,
                                Int64(unit.text.utf8.count))
                        }
                        current.frames.removeLast()
                        continue
                    }
                    nodes[frame.object.key] = try node(raw, frame: frame)
                    frame.position = 0
                    current.frames[top] = frame
                }
                let decoded: DocumentHashNode
                if let cached = nodes[frame.object.key] {
                    decoded = cached
                } else {
                    let (raw, _) = try bytes(
                        frame.object, source: source, reference: reference, base: physical, scope: scope,
                        budget: budget)
                    decoded = try node(raw, frame: frame)
                    nodes[frame.object.key] = decoded
                }
                if frame.position == decoded.entries.count {
                    nodes.removeValue(forKey: frame.object.key)
                    current.frames.removeLast()
                    continue
                }
                guard frame.position < decoded.entries.count else {
                    throw TractandaError("peerObjectCollision", "Cursor entry changed.")
                }
                let entry = decoded.entries[frame.position]
                let part = PeerPackage.DocumentPart(
                    role: decoded.level == 0 ? .page : .node,
                    level: max(0, decoded.level - 1), ordinal: entry.ordinal)
                let child = PeerPackage.Object(
                    kind: .document, id: root.id, length: Int(entry.byteCount), sha256: entry.sha256,
                    part: part)
                try child.validate()
                current.frames[top].position += 1
                current.frames.append(
                    .init(object: child, firstPage: entry.firstPage, lastPage: entry.lastPage))
            }
            if current.phase == "walk", current.frames.isEmpty {
                let coverage = try DocumentCoverage(
                    converted: current.coverage[0], unsupported: current.coverage[1],
                    truncated: current.coverage[2], timedOut: current.coverage[3], failed: current.coverage[4]
                )
                guard current.pages == reference.pageCount,
                    current.encodedBytes == reference.totalEncodedBytes,
                    coverage == reference.coverage
                else { throw TractandaError("peerObjectCollision", "Document totals/outcomes differ.") }
                if case .incoming(let package, let transfer) = source {
                    try transfer.freeze(packageID: package, reference: reference, budget: budget)
                }
                current.phase = "inspect"
            }
            if current.phase == "inspect", units < maximumUnits {
                try budget.requireWorkingSet(
                    bytes: current.minimumReadBytes ?? UInt64(3 * 1024 * 1024),
                    steps: current.minimumWorkSteps ?? 32,
                    label: "One verified document inspection step")
                let now = ProcessInfo.processInfo.systemUptime
                jobs = jobs.filter { now - $0.value.touched < 60 }
                if job(jobKey)?.inspection.base != physical || job(jobKey)?.inspection.complete == true {
                    removeJob(jobKey)
                }
                guard activeInspections < 8 else {
                    throw TractandaError("peerVerificationBusy", "Inspection execution slots are busy.")
                }
                activeInspections += 1
                defer { activeInspections -= 1 }
                let inspection = try inspection(jobKey, base: physical)
                defer {
                    // Fixed depth and bounded windows reserve at most 48KiB per parked slot.
                    if originals.logicalVerificationOwner != nil, inspection.retainedByteCount > 48 * 1024 {
                        removeJob(jobKey)
                    }
                }
                let inspect: ([String], PeerOriginalFile) throws -> Void = { path, actual in
                    let part = try PeerPackage.DocumentPart.from(relativePath: path)
                    let lookup = PeerPackage.Object(
                        kind: .document, id: root.id, length: 1, sha256: root.sha256, part: part)
                    guard let row = try index.peerDocumentPart(scope: scope, object: lookup),
                        row.1 == PeerOriginalTransfer.Stamp(actual.metadata),
                        actual.metadata.size == UInt64(row.0.length)
                    else {
                        throw TractandaError(
                            "peerObjectCollision", "Nested part differs from its verified stamp.")
                    }
                    _ = try self.file(
                        row.0, source: source, reference: reference, base: physical, scope: scope,
                        budget: budget)
                }
                let complete: Bool
                if publish, case .incoming(let package, let transfer) = source {
                    let tree = try transfer.tree(packageID: package, contentID: root.id, budget: budget)
                    complete = try contents.stepFrozenPeerPublication(
                        stage: tree.stage, reference: reference,
                        manifestBytes: manifestBytes, inspection: inspection, expectedParts: current.parts,
                        budget: budget,
                        inspect: inspect, beforePublication: beforePublication)
                } else {
                    complete = try inspection.step(budget: budget, synchronize: false, inspect: inspect)
                    if complete, inspection.count != current.parts {
                        throw TractandaError("peerObjectCollision", "Missing or extra document parts.")
                    }
                }
                touchJob(jobKey)
                guard originals.logicalVerificationOwner == nil || inspection.retainedByteCount <= 48 * 1024
                else {
                    throw TractandaError(
                        "resourceLimit", "Parked inspection state exceeds its fixed reservation.")
                }
                inspectionAdvanced = inspection.count > initialInspectionCount
                if complete {
                    if let token = current.corpus, corpusOwner != nil {
                        try index.finishPeerDocumentCorpus(
                            token, units: current.corpusUnits ?? 0,
                            bytes: current.corpusBytes ?? 0)
                    }
                    removeJob(jobKey)
                    current.phase = publish ? "published" : "ready"
                    if publish, case .incoming = source {
                        // A durable immutable canonical tree may reuse this process's exact
                        // storage verification. This is neither authority nor a publication permit.
                        var canonical = current
                        canonical.base = try contents.directory(root.id)
                        canonical.rootStamp = PeerOriginalTransfer.Stamp(
                            try contents.peerRootMetadata(canonical.base))
                        try index.peerDocumentSave(
                            scope: Self.canonicalScope(root.id), content: root.id,
                            state: JSON.encode(canonical))
                    }
                }
            }
            try renewCorpusProgress()
            try index.peerDocumentSave(scope: scope, content: root.id, state: JSON.encode(current))
            try index.execute("RELEASE SAVEPOINT peer_document_step")
            try observeCorpus()
            return current.phase == "ready" || current.phase == "published"
        } catch let error as TractandaError where error.code == "peerPayloadVerifying" {
            do {
                try renewCorpusProgress()
                try index.peerDocumentSave(scope: scope, content: root.id, state: JSON.encode(current))
                try index.execute("RELEASE SAVEPOINT peer_document_step")
                try observeCorpus()
            } catch {
                try? index.execute("ROLLBACK TO SAVEPOINT peer_document_step")
                try? index.execute("RELEASE SAVEPOINT peer_document_step")
                throw error
            }
            throw error
        } catch {
            try? index.execute("ROLLBACK TO SAVEPOINT peer_document_step")
            try? index.execute("RELEASE SAVEPOINT peer_document_step")
            removeJob(jobKey)
            try? observeCorpus()
            throw error
        }
    }
}
