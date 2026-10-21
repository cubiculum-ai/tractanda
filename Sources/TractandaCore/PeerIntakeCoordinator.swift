import Crypto
import Foundation

/// Internal metadata intake orchestrator. The Store supplies current authority and owns the
/// root writer/Index transaction. There is no listener, enrollment or public import endpoint.
final class PeerIntakeCoordinator {
    struct BootstrapTarget: Sendable {
        let revisionID: String
        let sha256: String
        let pinID: String
        let pinDigest: String
        fileprivate init(revisionID: String, sha256: String, pin: AuthorityStore.BootstrapPin) {
            self.revisionID = revisionID
            self.sha256 = sha256
            pinID = pin.recordID
            pinDigest = pin.sha256
        }
    }
    struct SealedEligibility: Sendable {
        let revisionID: String
        let sha256: String
        let packageID: String
        let evidenceID: String?
        let evidenceDigest: String?
        let evidencePackageID: String?
        fileprivate init(
            object: PeerPackage.Object, packageID: String, evidenceID: String? = nil,
            evidenceDigest: String? = nil, evidencePackageID: String? = nil
        ) {
            revisionID = object.id
            sha256 = object.sha256
            self.packageID = packageID
            self.evidenceID = evidenceID
            self.evidenceDigest = evidenceDigest
            self.evidencePackageID = evidencePackageID
        }
    }
    struct Assessment: Codable {
        let profile: String
        let targetDigest: String
        let evaluation: StoredEvaluation
        struct StoredEvaluation: Codable {
            let disposition: AuthorityStore.Disposition
            let reason: String
            let evidenceID: String?
            let evidenceDigest: String?
            let evidencePackageID: String?
            var evaluation: AuthorityStore.Evaluation {
                .init(
                    disposition: disposition, reason: reason, evidenceID: evidenceID,
                    evidenceDigest: evidenceDigest, evidencePackageID: evidencePackageID)
            }
        }
    }
    struct AdmittedAssessment: Codable {
        let object: PeerPackage.Object
        let origin: String
        let receipt: PeerOriginAdmission.Receipt
        let assessment: Assessment
    }
    let root: URL
    let ownerUID: UInt32
    let storeID: String
    let journal: PeerIntakeJournal
    var documentVerification: PeerDocumentVerification?
    var progress: (() throws -> Void)?
    var provisioningScope: PeerEnrollmentActivation.Scope?
    var enrollmentBoundaryForTesting: ((String) throws -> Void)?
    var originAdmissionBoundaryForTesting: ((String) throws -> Void)?
    var credentialStagedForTesting: (() throws -> Void)?
    var lifecycleBoundaryForTesting: ((PeerLifecycle.Boundary) throws -> Void)?
    private var operationDepth = 0
    private var remainingReadBytes: UInt64 = 0
    private var operationReadCapacity: UInt64 = 0
    /// Read-only owning-operation budget evidence, inspected on this coordinator's serial owner.
    var operationReadBytesForTesting: UInt64 { operationReadCapacity - remainingReadBytes }
    func withOperation<T>(recovery: Bool = false, maximumReadBytes: UInt64? = nil, _ body: () throws -> T)
        throws -> T
    {
        var enclosing: (remaining: UInt64, capacity: UInt64, window: UInt64)?
        if operationDepth == 0 {
            remainingReadBytes =
                recovery ? journal.limits.maximumRecoveryReadBytes : journal.limits.maximumReadBytes
            if let maximumReadBytes { remainingReadBytes = min(remainingReadBytes, maximumReadBytes) }
            operationReadCapacity = remainingReadBytes
        } else if let maximumReadBytes {
            let window = min(remainingReadBytes, maximumReadBytes)
            enclosing = (remainingReadBytes, operationReadCapacity, window)
            remainingReadBytes = window
            operationReadCapacity = min(operationReadCapacity, maximumReadBytes)
        }
        operationDepth += 1
        defer {
            operationDepth -= 1
            if let enclosing {
                // Nested comparison cannot escape its cap or restore consumed parent bytes.
                let used = enclosing.window - remainingReadBytes
                remainingReadBytes = enclosing.remaining - used
                operationReadCapacity = enclosing.capacity
            }
        }
        return try body()
    }
    /// One owning operation shares this counter across every admission/publication metadata read.
    func admissionReadBudget() -> (Int) throws -> Void {
        let local = PeerOriginAdmission.ReadBudget(journal.limits.maximumReadBytes)
        return { count in
            try self.progress?()
            if self.operationDepth > 0 {
                guard count >= 0, UInt64(count) <= self.remainingReadBytes else {
                    throw TractandaError(
                        "resourceLimit", "Admission exhausted the owning operation read budget.")
                }
                self.remainingReadBytes -= UInt64(count)
            } else {
                try local.charge(count)
            }
        }
    }
    init(
        root: URL, ownerUID: UInt32, storeID: String, limits: PeerPackage.Limits = .init(),
        stagingQuota: StagingByteQuota? = nil
    ) {
        self.root = root
        self.ownerUID = ownerUID
        self.storeID = storeID
        journal = PeerIntakeJournal(
            root: root, ownerUID: ownerUID, limits: limits, stagingQuota: stagingQuota)
    }
    func configuration(readBudget: ((Int) throws -> Void)? = nil) throws -> AuthorityStore.Configuration? {
        try AuthorityStore.configuration(root: root, files: journal.files, readBudget: readBudget)
    }
    func context(peerID: String, readBudget: ((Int) throws -> Void)? = nil) throws -> PeerPackage.Context {
        if peerID == "local" {
            guard
                let identity = try ReplicaIdentity.load(
                    root: root, storeID: storeID, ownerUID: ownerUID, readBudget: readBudget)
            else {
                throw TractandaError(
                    "missingReplicaIdentity", "Local publication requires its private replica identity.")
            }
            return try PeerPackage.Context(
                peerID: "local", storeID: storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data(("local:" + identity.replicaID).utf8)),
                permittedOrigins: [identity.replicaID])
        }
        guard let configuration = try configuration(readBudget: readBudget) else {
            throw TractandaError("untrustedPeer", "No peer is configured.")
        }
        let context = try configuration.context(peerID: peerID)
        guard context.storeID == storeID else {
            throw TractandaError("untrustedPeer", "Peer StoreID differs.")
        }
        return context
    }
    func requireIntakeCurrent(_ supplied: PeerPackage.Context, packageID: String?) throws {
        if let provisioningScope,
            try provisioningScope.permits(supplied, packageID: packageID, readBudget: admissionReadBudget())
        {
            return
        }
        try requireCurrent(supplied)
    }
    func intakePublicationIsCurrent(_ publication: PeerIntakeJournal.Publication) throws -> Bool {
        if let provisioningScope,
            try provisioningScope.permits(publication, readBudget: admissionReadBudget())
        {
            return true
        }
        return (try? context(peerID: publication.context.peerID)) == publication.context
    }
    func requireCurrent(_ supplied: PeerPackage.Context, readBudget: ((Int) throws -> Void)? = nil) throws {
        guard supplied == (try context(peerID: supplied.peerID, readBudget: readBudget)) else {
            throw TractandaError(
                "peerConfigurationChanged", "Reauthenticate against current private peer configuration.")
        }
    }
    /// Promotion's independent canonical recheck shares the owning admission counter.
    func retainedCanonicalItemBytes(_ row: AuthorityStore.RetainedObject) throws -> Data? {
        try InitialAuthorityBootstrap.retainedItemBytes(
            root: root, path: row.path, object: row.descriptor, ownerUID: ownerUID,
            readBudget: admissionReadBudget())
    }
    func bytes(_ row: AuthorityStore.RetainedObject) throws -> Data {
        try progress?()
        if operationDepth > 0 {
            guard UInt64(row.descriptor.length) <= remainingReadBytes else {
                throw TractandaError("resourceLimit", "Authority operation hydration allowance exhausted.")
            }
            remainingReadBytes -= UInt64(row.descriptor.length)
        }
        let data: Data
        if row.descriptor.kind == .item {
            guard
                let original = try InitialAuthorityBootstrap.retainedItemBytes(
                    root: root, path: row.path, object: row.descriptor, ownerUID: ownerUID)
            else { throw TractandaError("peerObjectCollision", "Retained original is missing.") }
            data = original
        } else {
            data = try journal.files.read(
                path: row.path.split(separator: "/").map(String.init), maximumBytes: row.descriptor.length)
        }
        guard data.count == row.descriptor.length, AuthorityRecordCodec.sha256(data) == row.descriptor.sha256
        else {
            throw TractandaError("peerObjectCollision", "Retained original digest changed.")
        }
        return data
    }
    /// Known bytes cannot bypass loss of the receipt that admitted them. This is read-only;
    /// a new package must not manufacture a replacement for missing published/origin proof.
    func requireRetainedReceipt(_ row: AuthorityStore.RetainedObject, original: Data, index: ItemIndex) throws
    {
        guard row.permittedOrigin else { return }
        guard let publication = try journal.publication(row.packageID),
            publication.context.peerID == row.peerID,
            publication.context.configurationDigest == row.configurationDigest
        else {
            throw TractandaError("peerRepairRequired", "Retained original lost its admitted receipt proof.")
        }
        let origin: String?
        if row.descriptor.kind == .item {
            origin = try AuthorityRevision(originalBytes: original).revision.provenance?.originReplicaID
        } else {
            origin = try AuthorityRecordCodec.decode(original).record.originReplicaID
        }
        if let origin, !publication.context.permittedOrigins.contains(origin),
            try !admittedReceiptPermits(packageID: row.packageID, origin: origin, index: index)
        {
            throw TractandaError("peerRepairRequired", "Retained original lost its admitted origin proof.")
        }
    }
    func binding(_ value: ItemValue, index: ItemIndex) throws -> AuthorityRevision? {
        let binding = try AuthorityRecord.binding(value)
        guard let row = try index.retainedAuthorityObject(id: binding.revisionID),
            row.descriptor.kind == .item, row.descriptor.sha256 == binding.sha256,
            try index.authorityDisposition(id: binding.revisionID)?.disposition == .eligible
        else { return nil }
        let node = try AuthorityRevision(originalBytes: bytes(row))
        guard node.revision.itemID == binding.itemID else {
            throw TractandaError("invalidAuthority", "Policy item binding differs.")
        }
        return node
    }
    private func originalReadBudget() -> PeerOriginalReadBudget {
        PeerOriginalReadBudget(
            bytes: operationDepth > 0 ? remainingReadBytes : journal.limits.maximumReadBytes,
            maximumSteps: journal.limits.maximumWork,
            workingCapacity: operationDepth > 0 ? operationReadCapacity : journal.limits.maximumReadBytes)
    }
    func verifiedCanonicalOriginal(_ descriptor: AttachmentDescriptor) throws -> Bool {
        guard let originals = journal.originals else { return false }
        let budget = originalReadBudget()
        defer { if operationDepth > 0 { remainingReadBytes -= budget.used } }
        return try originals.known(
            .init(
                kind: .attachment, id: descriptor.attachmentID, length: Int(descriptor.byteCount),
                sha256: descriptor.sha256), progress: progress, budget: budget)
    }
    func verifiedCanonicalDocument(
        _ document: AttachmentDocumentRepresentation, index: ItemIndex, corpusScope: String? = nil
    ) throws
        -> Bool
    {
        try AttachmentDocumentValidator.validate(document)
        guard let reference = document.content else { return true }
        guard let documentVerification else { return false }
        let budget = originalReadBudget()
        defer { if operationDepth > 0 { remainingReadBytes -= budget.used } }
        return try documentVerification.step(
            scope: PeerDocumentVerification.canonicalScope(reference.contentID),
            document: document, source: .canonical, index: index, budget: budget,
            corpusPackageID: corpusScope)
    }
    func completeDocumentCorpus(packageID: String, index: ItemIndex) throws {
        guard
            try journal.intakeState(context: journal.beginRecord(packageID).context, packageID: packageID)
                .phase == .applied
        else {
            throw TractandaError("invalidPeerPackage", "Peer corpus retirement requires applied history.")
        }
        for work in try index.completePeerDocumentCorpus(packageID: packageID) {
            try documentVerification?.corpusBoundary?(
                .init(
                    phase: .afterCommit, workID: work.workID,
                    estimatedAdditionalBytes: 0, units: 0, retainedEncodedBytes: work.retainedEncodedBytes))
        }
    }
    func requireStorageIdentity(_ object: PeerPackage.Object, index: ItemIndex) throws {
        if object.kind != .document,
            try journal.documents?.contents.peerDirectory(object.id) != nil
        {
            throw TractandaError("peerObjectCollision", "Object identity belongs to a canonical document.")
        }
        if object.kind != .attachment,
            try journal.originals?.payloads.resolvedPayloadPath(object.id) != nil
        {
            throw TractandaError("peerObjectCollision", "Object identity belongs to a canonical original.")
        }
        if [.document, .attachment, .index].contains(object.kind),
            try index.peerMetadataIdentityExists(object.id)
        {
            throw TractandaError(
                "peerObjectCollision", "Payload/index identity belongs to canonical metadata.")
        }
        if let retained = try index.retainedAuthorityObject(id: object.id),
            retained.descriptor.kind != object.kind
        {
            throw TractandaError("peerObjectCollision", "Canonical object kind differs for this identity.")
        }
    }
    /// Shared preflight/recovery closure. Scratch SQL retains descriptor work, never original bodies.
    func prepareOriginals(packageID: String, index: ItemIndex, publish: Bool, recovering: Bool = false) throws
    {
        let begin = try journal.beginRecord(packageID)
        if begin.manifest.profile == PeerPackage.retainedMetadataProfile { return }
        // LOCAL packages are authored through the Store's existing verified attachment/document
        // publication path. They are not foreign transfer manifests; cold canonical recovery
        // validates their original/document closure before READY as it did before peer v2.
        if begin.context.peerID == "local" { return }
        // Foreign payload/document publication also moves private stages outside the journal.
        // Keep its aggregate conservative across both successful and interrupted work.
        journal.invalidateStageAccounting(packageID: packageID)
        defer { journal.invalidateStageAccounting(packageID: packageID) }
        if recovering, try journal.publication(packageID) == nil {
            throw TractandaError("invalidPeerPackage", "Historical storage recovery needs an exact seal.")
        }
        try index.peerOriginalBegin()
        let token = "storage-closure:" + packageID
        try index.authorityBeginWalk(token: token)
        defer { try? index.authorityEndWalk(token: token) }
        func visit(_ object: PeerPackage.Object) throws {
            try requireStorageIdentity(object, index: index)
            guard try index.authorityVisitOnce(token: token, id: object.id) else {
                throw TractandaError("invalidPeerPackage", "Repeated all-kind identity in package closure.")
            }
        }
        try journal.walk(packageID, visitIndex: visit) { object, bytes in
            try self.progress?()
            try visit(object)
            if object.kind == .attachment {
                try index.peerOriginalPresent(object)
                return
            }
            if object.kind == .document {
                try index.peerDocumentPresent(object)
                try journal.admitDocumentAnchor(packageID: packageID, object: object)
                return
            }
            if object.kind == .item {
                let bytes =
                    try bytes ?? index.retainedAuthorityObject(id: object.id).map { try self.bytes($0) }
                guard let bytes else {
                    throw TractandaError("missingDependencies", "Original witness revision is incomplete.")
                }
                let node = try AuthorityRevision(originalBytes: bytes)
                try ItemSemantics.validate(node.revision)
                try index.peerOriginalRegister(node.revision)
            }
        }
        try index.peerOriginalValidateClosure()
        var cursor = ""
        while true {
            let page = try index.peerOriginalPage(after: cursor)
            if page.isEmpty { break }
            for row in page {
                guard let originals = journal.originals else {
                    throw TractandaError("missingDependencies", "Original streaming bridge is unavailable.")
                }
                while true {
                    let budget = originalReadBudget()
                    do {
                        defer { if operationDepth > 0 { remainingReadBytes -= budget.used } }
                        try originals.requireComplete(
                            packageID: packageID, object: row.object, descriptor: row.descriptor,
                            progress: progress, budget: budget)
                        if publish {
                            try originals.publish(
                                packageID: packageID, object: row.object, descriptor: row.descriptor,
                                budget: budget)
                        }
                        break
                    } catch let error as TractandaError
                        where recovering && error.code == "peerPayloadVerifying"
                    {
                        if budget.used == 0 || (operationDepth > 0 && remainingReadBytes == 0) { throw error }
                        try Task.checkCancellation()
                        try progress?()
                    }
                }
                cursor = row.object.id
            }
        }
        cursor = ""
        while true {
            let page = try index.peerDocumentPage(after: cursor)
            if page.isEmpty { break }
            for row in page {
                if row.document.content != nil {
                    guard let documents = journal.documents, let documentVerification else {
                        throw TractandaError("missingDependencies", "Document verification is unavailable.")
                    }
                    while true {
                        let budget = originalReadBudget()
                        do {
                            defer { if operationDepth > 0 { remainingReadBytes -= budget.used } }
                            let complete = try documentVerification.step(
                                scope: "intake:" + packageID, document: row.document,
                                source: .incoming(packageID: packageID, transfer: documents),
                                index: index, budget: budget, publish: publish,
                                beforePublication: {
                                    try self.progress?()
                                    if !recovering {
                                        try self.requireIntakeCurrent(begin.context, packageID: packageID)
                                    }
                                })
                            if complete { break }
                            throw TractandaError(
                                "peerPayloadVerifying", "Saved document verification has remaining work.")
                        } catch let error as TractandaError
                            where recovering && error.code == "peerPayloadVerifying"
                        {
                            if budget.used == 0 || (operationDepth > 0 && remainingReadBytes == 0) {
                                throw error
                            }
                            try Task.checkCancellation()
                            try progress?()
                        }
                    }
                }
                cursor = row.document.representationID
            }
        }
    }
    func retainSealed(
        _ packageID: String, index: ItemIndex, applyAssessment: Bool = true, allowReviewClosure: Bool = false,
        recovering: Bool = false
    ) throws {
        guard let publication = try journal.publication(packageID), publication.context.storeID == storeID
        else {
            throw TractandaError("invalidPeerPackage", "Only a sealed publication enters retained inventory.")
        }
        try prepareOriginals(packageID: packageID, index: index, publish: true, recovering: recovering)
        // Reopened connections must enable control queue maintenance before inserting
        // the first object; initializing only inside later validation misses that row.
        if !index.authorityControlSchemaReady { try index.initializeAuthorityControlSchema() }
        var unsupportedLocalHold = false
        let token = "package:" + packageID
        try index.authorityBeginWalk(token: token)
        defer { try? index.authorityEndWalk(token: token) }
        try journal.walk(packageID) { descriptor, data in
            try progress?()
            guard try index.authorityVisitOnce(token: token, id: descriptor.id) else {
                throw TractandaError("invalidPeerPackage", "Repeated object in hierarchical package index.")
            }
            if descriptor.kind == .attachment || descriptor.kind == .document { return }
            let known = try index.retainedAuthorityObject(id: descriptor.id)
            let data = try data ?? known.flatMap { try bytes($0) }
            guard let data else {
                throw TractandaError("missingDependencies", "A sealed original is missing.")
            }
            let revision = descriptor.kind == .item ? try AuthorityRevision(originalBytes: data) : nil
            let authority = descriptor.kind == .authority ? try AuthorityRecordCodec.decode(data) : nil
            guard descriptor.kind == .item || descriptor.kind == .authority else {
                throw TractandaError("missingDependencies", "Metadata intake cannot publish payload objects.")
            }
            let origin =
                try revision?.revision.provenance?.originReplicaID ?? authority?.record.originReplicaID
            if let authority {
                guard authority.record.storeID == storeID, authority.record.recordID == descriptor.id else {
                    throw TractandaError("invalidAuthority", "Authority StoreID/object identity differs.")
                }
                let unsupportedParents =
                    authority.record.kind == .authoredEvidence
                    ? try !AuthorityRecord.list(authority.record.payload["acceptedAuthority"]).isEmpty
                    : false
                if authority.record.kind == .reviewHold, publication.context.peerID == "local" {
                    unsupportedLocalHold = true
                }
                if (authority.record.kind == .reviewDecision || unsupportedParents) && !allowReviewClosure {
                    throw TractandaError(
                        "authorityReconciliationRequired",
                        "This reader cannot enforce later review/control causality; authority fallback is forbidden."
                    )
                }
            }
            if let revision, revision.revision.revisionID != descriptor.id {
                throw TractandaError("invalidPeerPackage", "Revision object identity differs.")
            }
            let existing = try index.retainedAuthorityObject(id: descriptor.id)
            let previouslyAccepted = try revision.flatMap { try index.revision($0.revision.revisionID) }
            let path: String
            if let existing {
                guard existing.descriptor == descriptor, try bytes(existing) == data else {
                    throw TractandaError("peerObjectCollision", "Global immutable identity collides.")
                }
                path = try journal.publishOriginal(
                    descriptor, bytes: data, publication: publication, existingPath: existing.path)
            } else if let previouslyAccepted {
                let original = try PooledCanonicalRecord.read(
                    row: previouslyAccepted, root: root, ownerUID: ownerUID)
                guard original.revision == revision?.revision,
                    previouslyAccepted.digest == Data(SHA256.hash(data: data))
                else { throw TractandaError("peerObjectCollision", "Existing accepted original differs.") }
                path = try journal.publishOriginal(
                    descriptor, bytes: data, publication: publication, existingPath: previouslyAccepted.path)
            } else if descriptor.kind == .item, publication.context.peerID == "local",
                let selected = publication.localItemPath,
                let existingBytes = try InitialAuthorityBootstrap.retainedItemBytes(
                    root: root, path: selected, object: descriptor, ownerUID: ownerUID)
            {
                guard let revision, existingBytes == data,
                    CanonicalRecordPath.validate(
                        selected, itemID: revision.revision.itemID, revisionID: descriptor.id)
                else {
                    throw TractandaError(
                        "invalidAuthority", "Local publication locator differs from original.")
                }
                path = try journal.publishOriginal(
                    descriptor, bytes: data, publication: publication, existingPath: selected)
            } else {
                path = try journal.publishOriginal(descriptor, bytes: data, publication: publication)
            }
            let admitted: Bool
            if let origin, !publication.context.permittedOrigins.contains(origin), !recovering {
                admitted = try sealAdmittedOrigin(packageID: packageID, origin: origin, index: index)
            } else {
                admitted = false
            }
            if admitted, let old = try index.authorityReceipt(objectID: descriptor.id, packageID: packageID),
                !old.permittedOrigin
            {
                try index.admitOriginReceipt(old)
            }
            let row = AuthorityStore.RetainedObject(
                descriptor: descriptor, path: path,
                packageID: packageID, peerID: publication.context.peerID,
                configurationDigest: publication.context.configurationDigest,
                permittedOrigin: (origin.map(publication.context.permittedOrigins.contains) ?? false)
                    || admitted)
            try index.retainAuthorityObject(row, revision: revision, authority: authority)
            if applyAssessment, publication.context.peerID != "local", let revision {
                try assessRetiredOriginalIfNeeded(revision, row: row, index: index)
            }
            if descriptor.kind == .authority,
                try index.authorityDisposition(id: descriptor.id)?.disposition == .pending
            {
                try index.setAuthorityDisposition(
                    id: descriptor.id,
                    evaluation: .init(
                        disposition: .held,
                        reason: "Retained control witness; target eligibility is evaluated separately."))
            }
        }
        if unsupportedLocalHold {
            throw TractandaError(
                "unsupportedAuthorityReviewHold",
                "Local canonical hold originals are preserved; this reader cannot validate their historical source context."
            )
        }
        // Immutable assessments are historical testimony. Warm retention preserves the
        // established CURRENT disposition; fresh originals remain pending until validation.
        // Only quarantined cold recovery below restores historical acceptance and then
        // reconciles current authority before any serving.
    }
    func recoverInventory(index: ItemIndex, validateClosure: Bool = true) throws {
        try index.initializeAuthoritySchema()
        try journal.packageIDs { id in
            try progress?()
            if try journal.publication(id) != nil {
                try retainSealed(
                    id, index: index, applyAssessment: false, allowReviewClosure: true, recovering: true)
            }
        }
        try replayOriginReceipts(index: index, create: false)
        try loadPeerRetirements(index: index)
        if let pin = try configuration()?.bootstrap { try seedBootstrap(pin, index: index) }
        try journal.packageIDs { id in
            try progress?()
            guard let publication = try journal.publication(id) else { return }
            if publication.context.peerID == "local" {
                var cursor: String?
                while true {
                    let rows = try index.authorityPackagePage(packageID: id, after: cursor, limit: 128)
                    if rows.isEmpty { break }
                    for row in rows {
                        cursor = row.descriptor.id
                        if row.descriptor.kind == .item {
                            let node = try AuthorityRevision(originalBytes: bytes(row))
                            // Existing initial originals are not newly authored publications.
                            // This exception restores NO eligibility: only the independently
                            // validated initial bootstrap pin may admit this exact history.
                            if try AuthorityStore.isInitialHistoryReceipt(
                                row, node: node, publication: publication,
                                root: root, storeID: storeID, ownerUID: ownerUID, files: journal.files)
                            {
                                continue
                            }
                            guard let origin = try node.revision.provenance?.originReplicaID,
                                publication.context.permittedOrigins == [origin]
                            else {
                                throw TractandaError(
                                    "invalidAuthority",
                                    "Local sealed origin differs from its publication context.")
                            }
                            var selected: (AuthorityRecordCodec.Verified, AuthorityStore.RetainedObject)?
                            if try node.revision.provenance?.kind != .automaticMerge {
                                var evidenceCursor: String?
                                while true {
                                    let candidates = try index.authorityEvidenceCandidates(
                                        revisionID: row.descriptor.id, after: evidenceCursor, limit: 128)
                                    if candidates.isEmpty { break }
                                    for candidate in candidates {
                                        evidenceCursor = candidate.descriptor.id
                                        guard
                                            let receipt = try index.authorityReceipt(
                                                objectID: candidate.descriptor.id, packageID: id),
                                            receipt.peerID == "local", receipt.permittedOrigin,
                                            receipt.configurationDigest
                                                == publication.context.configurationDigest
                                        else { continue }
                                        let witness = try AuthorityRecordCodec.decode(bytes(candidate))
                                        guard try matchesIdentity(node, witness.record) else { continue }
                                        guard selected == nil else {
                                            throw TractandaError(
                                                "invalidAuthority",
                                                "Local seal contains contradictory original evidence.")
                                        }
                                        selected = (witness, receipt)
                                    }
                                }
                                guard selected != nil else {
                                    throw TractandaError(
                                        "missingDependencies",
                                        "Local authored publication lacks exact sealed evidence.")
                                }
                            }
                            try index.restoreSealedEligibility(
                                .init(
                                    object: row.descriptor, packageID: id,
                                    evidenceID: selected?.0.record.recordID,
                                    evidenceDigest: selected?.0.sha256,
                                    evidencePackageID: selected?.1.packageID))
                        }
                    }
                }
            } else {
                var cursor: String?
                while true {
                    let rows = try index.authorityPackagePage(packageID: id, after: cursor, limit: 128)
                    if rows.isEmpty { break }
                    for row in rows {
                        cursor = row.descriptor.id
                        if row.descriptor.kind == .item {
                            let original = try AuthorityRevision(originalBytes: bytes(row))
                            try assessRetiredOriginalIfNeeded(original, row: row, index: index)
                        }
                        if row.descriptor.kind == .item,
                            let saved = try assessment(packageID: id, object: row.descriptor)
                        {
                            if saved.evaluation.disposition == .eligible {
                                let restored = try AuthorityRevision(originalBytes: bytes(row))
                                if try restored.revision.provenance?.kind == .automaticMerge {
                                    try index.restoreSealedEligibility(
                                        .init(object: row.descriptor, packageID: id))
                                    try index.retainLocalAssessedMaterialization(restored, packageID: id)
                                    continue
                                }
                                guard let evidenceID = saved.evaluation.evidenceID,
                                    let evidenceDigest = saved.evaluation.evidenceDigest,
                                    let evidencePackageID = saved.evaluation.evidencePackageID,
                                    let receipt = try index.authorityReceipt(
                                        objectID: evidenceID, packageID: evidencePackageID),
                                    receipt.permittedOrigin, receipt.descriptor.sha256 == evidenceDigest
                                else {
                                    throw TractandaError(
                                        "invalidAuthority",
                                        "Accepted assessment lost its exact source evidence receipt.")
                                }
                                let node = try AuthorityRevision(originalBytes: bytes(row))
                                let evidence = try AuthorityRecordCodec.decode(bytes(receipt))
                                guard try matchesIdentity(node, evidence.record) else {
                                    throw TractandaError(
                                        "invalidAuthority", "Assessment source intent differs from original.")
                                }
                                try index.restoreSealedEligibility(
                                    .init(
                                        object: row.descriptor, packageID: id,
                                        evidenceID: evidenceID, evidenceDigest: evidenceDigest,
                                        evidencePackageID: evidencePackageID))
                            } else if try index.authorityDisposition(id: row.descriptor.id)?.disposition
                                != .eligible
                            {
                                try index.setAuthorityDisposition(
                                    id: row.descriptor.id,
                                    evaluation: saved.evaluation.evaluation)
                            }
                        }
                    }
                }
            }
        }
        if validateClosure { try index.validateRestoredAuthorityClosure() }
    }
    func assessment(packageID: String, object: PeerPackage.Object) throws -> Assessment? {
        guard
            let data = try journal.files.readIfPresent(
                path: ["authority", "assessments", packageID, object.id],
                maximumBytes: PeerPackage.maximumPageBytes)
        else { return nil }
        var value = try PeerPackage.decode(Assessment.self, data)
        if value.evaluation.disposition == .unknownOrigin,
            let replacement = try journal.files.readIfPresent(
                path: ["authority", "admitted-assessments", packageID, object.id],
                maximumBytes: PeerPackage.maximumPageBytes)
        {
            let rebound = try PeerPackage.decode(AdmittedAssessment.self, replacement)
            guard rebound.object == object,
                let proof = try originReceipt(packageID: packageID, origin: rebound.origin),
                proof == rebound.receipt,
                let publication = try journal.publication(packageID),
                proof.manifestDigest == publication.manifestDigest,
                proof.contextDigest == AuthorityRecordCodec.sha256(try JSON.encode(publication.context))
            else {
                throw PeerOriginAdmission.failure("Reconsidered assessment lost its exact origin receipt.")
            }
            value = rebound.assessment
        }
        guard value.profile == "tractanda.intake-assessment.v1", value.targetDigest == object.sha256,
            value.evaluation.reason.utf8.count <= 4096
        else { throw TractandaError("invalidAuthority", "Assessment binding differs.") }
        return value
    }
    func recordAssessment(
        packageID: String, object: PeerPackage.Object, evaluation: AuthorityStore.Evaluation
    ) throws {
        let path = ["authority", "assessments", packageID, object.id]
        let value = Assessment(
            profile: "tractanda.intake-assessment.v1", targetDigest: object.sha256,
            evaluation: .init(
                disposition: evaluation.disposition, reason: evaluation.reason,
                evidenceID: evaluation.evidenceID, evidenceDigest: evaluation.evidenceDigest,
                evidencePackageID: evaluation.evidencePackageID))
        let data = try JSON.encode(value)
        if let old = try journal.files.readIfPresent(path: path, maximumBytes: PeerPackage.maximumPageBytes) {
            if old != data {
                let prior = try PeerPackage.decode(Assessment.self, old)
                guard prior.evaluation.disposition == .unknownOrigin,
                    evaluation.disposition != .unknownOrigin,
                    let original = try journal.object(object, packageID: packageID),
                    let origin = try AuthorityRevision(originalBytes: original).revision.provenance?
                        .originReplicaID,
                    let proof = try originReceipt(packageID: packageID, origin: origin)
                else {
                    throw TractandaError(
                        "authorityReconciliationRequired", "A prior assessment needs reviewed reconciliation."
                    )
                }
                let replacement = AdmittedAssessment(
                    object: object, origin: origin, receipt: proof, assessment: value)
                let path = ["authority", "admitted-assessments", packageID, object.id]
                let bytes = try JSON.encode(replacement)
                if let existing = try journal.files.readIfPresent(
                    path: path, maximumBytes: PeerPackage.maximumPageBytes)
                {
                    guard existing == bytes else {
                        throw PeerOriginAdmission.failure("Reconsidered assessment differs.")
                    }
                } else {
                    try journal.files.writeImmutable(
                        bytes, path: path, maximumBytes: PeerPackage.maximumPageBytes)
                }
            }
        } else {
            try journal.files.writeImmutable(data, path: path, maximumBytes: PeerPackage.maximumPageBytes)
        }
    }
    func stageLocal(
        revision: Revision, bytes: Data, evidence: AuthorityRecord?, contextToken: String,
        arrivalMinute: String, localItemPath: String, controls: [AuthorityRecord] = [],
        afterSeal: (() -> Void)? = nil, reservedPackageID: String? = nil
    ) throws -> String {
        let context = try context(peerID: "local")
        let packageID = try reservedPackageID ?? UUID.makeVersion1().uuidString.lowercased()
        let item = PeerPackage.Object(
            kind: .item, id: revision.revisionID, length: bytes.count,
            sha256: AuthorityRecordCodec.sha256(bytes))
        var objects = [(item, bytes)]
        if let evidence {
            let data = try AuthorityRecordCodec.encode(evidence)
            objects.append(
                (
                    .init(
                        kind: .authority, id: evidence.recordID, length: data.count,
                        sha256: AuthorityRecordCodec.sha256(data)), data
                ))
        }
        for control in controls {
            let data = try AuthorityRecordCodec.encode(control)
            objects.append(
                (
                    .init(
                        kind: .authority, id: control.recordID, length: data.count,
                        sha256: AuthorityRecordCodec.sha256(data)), data
                ))
        }
        let manifest = try stageObjects(objects, context: context, packageID: packageID)
        var publication = PeerIntakeJournal.Publication(
            packageID: packageID, manifestDigest: AuthorityRecordCodec.sha256(try JSON.encode(manifest)),
            context: context, contextToken: contextToken, arrivalMinute: arrivalMinute)
        publication.localItemPath = localItemPath
        try journal.prepare(publication)
        try CanonicalReaderRequirement.beforeControlPublication(root: root, ownerUID: ownerUID)
        try StoreCheckpoint.markDirty(root: root)
        try journal.seal(packageID)
        afterSeal?()
        try recordAssessment(
            packageID: packageID, object: item,
            evaluation: .init(
                disposition: .eligible, reason: "Local Store authorized and sealed this exact publication.",
                evidenceID: evidence?.recordID,
                evidenceDigest: evidence.flatMap { e in
                    objects.first(where: { $0.0.id == e.recordID })?.0.sha256
                },
                evidencePackageID: evidence == nil ? nil : packageID))
        return packageID
    }
    /// Root pin traverses bounded objects on disk. The total baseline never uses reducer arrays.
    func seedBootstrap(_ pin: AuthorityStore.BootstrapPin, index: ItemIndex, existingOnly: Bool = false)
        throws
    {
        guard let rootRow = try index.retainedAuthorityObject(id: pin.recordID), rootRow.permittedOrigin,
            rootRow.descriptor.sha256 == pin.sha256
        else {
            throw TractandaError("missingDependencies", "Pinned bootstrap root is not retained/trusted.")
        }
        let manifest = try AuthorityRecordCodec.decode(bytes(rootRow)).record
        guard manifest.kind == .bootstrap, manifest.storeID == storeID else {
            throw TractandaError("invalidAuthority", "Pin must bind an explicit initial bootstrap root.")
        }
        let walk = "bootstrap:" + pin.recordID
        try index.authorityBeginWalk(token: walk)
        defer { try? index.authorityEndWalk(token: walk) }
        var work = 0
        func visit(_ ref: ItemValue, depth: Int) throws {
            try progress?()
            work += 1
            guard work <= journal.limits.maximumWork, depth <= journal.limits.maximumDepth,
                let fields = ref.map
            else { throw TractandaError("resourceLimit", "Bootstrap work/depth exceeded.") }
            let id = try AuthorityRecord.persistentID(fields["recordID"])
            let digest = try AuthorityRecord.digest(fields["sha256"])
            guard try index.authorityVisitOnce(token: walk, id: id),
                let row = try index.retainedAuthorityObject(id: id), row.permittedOrigin,
                row.descriptor.sha256 == digest
            else { throw TractandaError("invalidAuthority", "Repeated/untrusted/missing bootstrap page.") }
            let page = try AuthorityRecordCodec.decode(bytes(row)).record
            guard page.payload["manifestID"]?.string == pin.recordID else {
                throw TractandaError("invalidAuthority", "Bootstrap page belongs to another cut.")
            }
            if page.kind == .bootstrapIndex {
                let children = try AuthorityRecord.list(page.payload["children"])
                guard
                    try children.map({ try AuthorityRecord.persistentID($0.map?["recordID"]) }).sorted()
                        == page.parentAuthorityIDs
                else {
                    throw TractandaError("invalidAuthority", "Bootstrap index omitted its actual children.")
                }
                for child in children { try visit(child, depth: depth + 1) }
            } else if page.kind == .bootstrapPage {
                for entry in try AuthorityRecord.list(page.payload["entries"]) {
                    work += 1
                    guard work <= journal.limits.maximumWork else {
                        throw TractandaError("resourceLimit", "Bootstrap entry work exceeded.")
                    }
                    let binding = try AuthorityRecord.binding(entry.map?["target"])
                    guard try index.authorityVisitOnce(token: walk, id: binding.revisionID),
                        let target = try index.retainedAuthorityObject(id: binding.revisionID),
                        target.descriptor.sha256 == binding.sha256
                    else {
                        throw TractandaError(
                            "invalidAuthority", "Bootstrap entry is repeated, missing or untrusted.")
                    }
                    let node = try AuthorityRevision(originalBytes: bytes(target))
                    guard try target.permittedOrigin || node.revision.provenance == nil else {
                        throw TractandaError(
                            "invalidAuthority", "Bootstrap cannot enroll an unknown modern origin.")
                    }
                    let frontier =
                        try node.revision.provenance?.kind == .automaticMerge
                        ? node.revision.provenance!.frontier : [node.revision.revisionID]
                    guard node.revision.itemID == binding.itemID,
                        try AuthorityRecord.ids(entry.map?["frontier"], maximum: 1024) == frontier
                    else {
                        throw TractandaError(
                            "invalidAuthority", "Bootstrap entry differs from original causal state.")
                    }
                    if existingOnly,
                        try index.authorityDisposition(id: binding.revisionID)?.disposition != .eligible
                    {
                        throw TractandaError(
                            "missingDependencies",
                            "A source baseline cannot admit unseen or held originals on this receiver.")
                    }
                    try index.admitPinnedBootstrap(
                        .init(revisionID: binding.revisionID, sha256: binding.sha256, pin: pin))
                }
            } else {
                throw TractandaError("invalidAuthority", "Unexpected bootstrap child kind.")
            }
        }
        let pages = try AuthorityRecord.list(manifest.payload["pages"])
        guard
            try pages.map({ try AuthorityRecord.persistentID($0.map?["recordID"]) }).sorted()
                == manifest.parentAuthorityIDs
        else {
            throw TractandaError("invalidAuthority", "Bootstrap root omitted actual child pages.")
        }
        for page in pages { try visit(page, depth: 0) }
        try index.validatePinnedBootstrapClosure(pinID: pin.recordID)
    }
    func matchesIdentity(_ node: AuthorityRevision, _ evidence: AuthorityRecord) throws -> Bool {
        let target = try AuthorityRecord.binding(evidence.payload["target"])
        guard let provenance = try node.revision.provenance,
            evidence.kind == .authoredEvidence, provenance.kind != .automaticMerge,
            target.itemID == node.revision.itemID, target.revisionID == node.revision.revisionID,
            target.sha256 == node.sha256, evidence.originReplicaID == provenance.originReplicaID,
            evidence.actorPrincipal == evidence.payload["principal"]?.string,
            try AuthorityRecord.ids(evidence.payload["parents"], maximum: 1024) == node.parents,
            evidence.payload["intent"]?.map?["writtenFields"]
                == .list(provenance.writtenFields.map(ItemValue.text)),
            evidence.payload["intent"]?.map?["unsetFields"]
                == .list(provenance.unsetFields.map(ItemValue.text))
        else { return false }
        let actor = node.revision.fields["actor"]?.string
        return actor == "user:" + evidence.actorPrincipal
            || actor == "uid:" + String(evidence.payload["sourceUID"]!.integerValue!)
    }
    /// The session adapter supplies only a Store-created Context. Recheck its private binding
    /// before reading the journal, so a wrong peer cannot use status as an object oracle.
    func resume(
        context: PeerPackage.Context, packageID: String, index: ItemIndex?,
        cursor: PeerPackage.ResumeCursor? = nil, limit: Int = 128,
        recoveryRequired: Bool = false, progress: (() throws -> Void)? = nil
    ) throws -> PeerPackage.ResumePage {
        try requireIntakeCurrent(context, packageID: packageID)
        let state = try journal.intakeState(
            context: context, packageID: packageID, recoveryRequired: recoveryRequired)
        return try withOperation {
            try journal.resumePage(
                context: context, packageID: packageID, cursor: cursor, limit: limit,
                recoveryRequired: state.recoveryRequired,
                knownOriginal: { descriptor in
                    guard let index, let row = try index.retainedAuthorityObject(id: descriptor.id) else {
                        return nil
                    }
                    guard row.descriptor == descriptor else {
                        throw TractandaError("peerObjectCollision", "Known original descriptor differs.")
                    }
                    let bytes = try self.bytes(row)
                    try self.requireRetainedReceipt(row, original: bytes, index: index)
                    return bytes
                },
                evaluation: { descriptor in
                    guard !state.recoveryRequired, descriptor.kind != .index, let index,
                        let row = try index.retainedAuthorityObject(id: descriptor.id)
                    else { return nil }
                    guard row.descriptor == descriptor else {
                        throw TractandaError("peerObjectCollision", "Current disposition target differs.")
                    }
                    return try index.authorityDisposition(id: descriptor.id)
                }, progress: progress)
        }
    }

    func freshReceipt(
        _ objectID: String, origin: String, index: ItemIndex,
        forAdministratorReview: Bool = false
    ) throws -> AuthorityStore
        .RetainedObject?
    {
        var cursor: String?
        var work = 0
        while true {
            let rows = try index.authorityObjectReceiptPage(
                objectID: objectID, afterPackageID: cursor, limit: 128)
            if rows.isEmpty { return nil }
            for row in rows {
                cursor = row.packageID
                work += 1
                guard work <= journal.limits.maximumWork else {
                    throw TractandaError("resourceLimit", "Receipt election work exceeded.")
                }
                guard
                    try receiptContextPermits(
                        row, origin: origin, index: index,
                        forAdministratorReview: forAdministratorReview)
                else { continue }
                return row
            }
        }
    }
    func electEvidence(
        _ node: AuthorityRevision, index: ItemIndex,
        evaluate: (AuthorityRevision, AuthorityRecord) throws -> AuthorityStore.Evaluation
    ) throws -> AuthorityStore.Evaluation {
        var chosen: AuthorityStore.Evaluation?
        var chosenDisposition: AuthorityStore.Disposition?
        var contradiction = false
        var cursor: String?
        var work = 0
        while true {
            let rows = try index.authorityEvidenceCandidates(
                revisionID: node.revision.revisionID, after: cursor, limit: 128)
            if rows.isEmpty { break }
            for candidate in rows {
                cursor = candidate.descriptor.id
                work += 1
                try progress?()
                guard work <= journal.limits.maximumWork else {
                    throw TractandaError("resourceLimit", "Evidence election work exceeded.")
                }
                let witness = try AuthorityRecordCodec.decode(bytes(candidate))
                guard try matchesIdentity(node, witness.record),
                    let receipt = try freshReceipt(
                        candidate.descriptor.id, origin: witness.record.originReplicaID, index: index)
                else { continue }
                var result: AuthorityStore.Evaluation
                do { result = try evaluate(node, witness.record) } catch let error as TractandaError
                    where error.code == "missingDependencies"
                {
                    continue  // Out-of-order evidence and pre-pin genesis remain resumable.
                } catch let error as TractandaError
                    where [
                        "invalidAuthority", "invalidRevisionGraph", "invalidMergeTimestamp",
                        "invalidPermissions", "invalidAccessConfiguration",
                    ].contains(error.code)
                {
                    continue  // A malformed raw witness cannot reserve the original's authority slot.
                }
                guard result.disposition == .eligible || result.disposition == .held else { continue }
                result.evidenceID = witness.record.recordID
                result.evidenceDigest = witness.sha256
                result.evidencePackageID = receipt.packageID
                if let previous = chosenDisposition, previous != result.disposition { contradiction = true }
                if chosen == nil || witness.record.recordID < (chosen!.evidenceID ?? "") { chosen = result }
                chosenDisposition = chosenDisposition ?? result.disposition
            }
        }
        if contradiction {
            return .init(
                disposition: .held,
                reason: "Contradictory fully validated authority testimony requires review.")
        }
        return chosen
            ?? .init(
                disposition: .missingDependencies,
                reason: "No complete currently authorized original evidence is available.")
    }
    func evaluatePending(
        packageID: String, index: ItemIndex,
        evaluate: (AuthorityRevision, AuthorityRecord) throws -> AuthorityStore.Evaluation,
        evaluateMaterialization: ((AuthorityRevision) throws -> AuthorityStore.Evaluation)? = nil,
        beforeAcceptance: ((AuthorityRevision, AuthorityStore.Evaluation) throws -> Void)? = nil
    ) throws -> AuthorityStore.Result {
        guard let publication = try journal.publication(packageID) else {
            throw TractandaError("invalidAuthority", "Pending evaluation needs a sealed publication.")
        }
        let currentReceipt = try intakePublicationIsCurrent(publication)
        var madeProgress = true
        var work = 0
        while madeProgress {
            madeProgress = false
            var cursor: String?
            while true {
                let rows = try index.authorityReadyPage(packageID: packageID, after: cursor, limit: 128)
                if rows.isEmpty { break }
                for row in rows {
                    try progress?()
                    cursor = row.descriptor.id
                    work += 1
                    guard work <= journal.limits.maximumWork else {
                        throw TractandaError("resourceLimit", "Eligibility delta work exceeded.")
                    }
                    let node = try AuthorityRevision(originalBytes: bytes(row))
                    let result: AuthorityStore.Evaluation
                    let retired = try retirementBlocks(node, index: index)
                    if retired {
                        try index.notePeerRetirementEffect(row.descriptor.id)
                        result = .init(
                            disposition: .held,
                            reason:
                                "Retired-origin revision is at or after the event cutoff; exact administrator review required."
                        )
                    } else if try
                        (!currentReceipt
                        && !index.authorityHasLocalHistoryAdmission(revisionID: row.descriptor.id))
                        || !row.permittedOrigin
                    {
                        result = .init(
                            disposition: .unknownOrigin,
                            reason: "No current configured relay receipt permits this origin.")
                    } else if try node.revision.provenance?.kind == .automaticMerge,
                        let evaluateMaterialization
                    {
                        result = try evaluateMaterialization(node)
                    } else {
                        result = try electEvidence(node, index: index, evaluate: evaluate)
                    }
                    if result.disposition == .eligible { try beforeAcceptance?(node, result) }
                    if !retired
                        && (result.disposition == .eligible || result.disposition == .held
                            || result.disposition == .unknownOrigin)
                    {
                        if try assessment(packageID: packageID, object: row.descriptor) == nil
                            || (assessment(packageID: packageID, object: row.descriptor)?.evaluation
                                .disposition == .unknownOrigin
                                && result.disposition != .unknownOrigin)
                        {
                            try recordAssessment(
                                packageID: packageID, object: row.descriptor, evaluation: result)
                        }
                        if result.disposition == .eligible,
                            try node.revision.provenance?.kind == .automaticMerge
                        {
                            try index.retainLocalAssessedMaterialization(node, packageID: packageID)
                        }
                    }
                    try index.setAuthorityDisposition(id: row.descriptor.id, evaluation: result)
                    madeProgress = madeProgress || result.disposition == .eligible
                }
            }
        }
        var stored = 0
        var accepted = 0
        var held = 0
        var missing = 0
        var rejected = 0
        var cursor: String?
        while true {
            let rows = try index.authorityPackagePage(packageID: packageID, after: cursor, limit: 128)
            if rows.isEmpty { break }
            for row in rows {
                cursor = row.descriptor.id
                stored += 1
                if row.descriptor.kind != .item { continue }
                switch try index.authorityDisposition(id: row.descriptor.id)?.disposition {
                case .eligible: accepted += 1
                case .held, .unknownOrigin: held += 1
                case .rejected: rejected += 1
                default: missing += 1
                }
            }
        }
        return .init(
            packageID: packageID, stored: stored, accepted: accepted, held: held, missing: missing,
            rejected: rejected)
    }

    /// A private, sealed LOCAL control records a completed historical acceptance decision.
    /// This restores its exact selected testimony; current invalidation reduction and ACLs
    /// remain separate gates before any current or historical item can be served.
    func restoreControlAcceptance(_ delta: AuthorityStore.DispositionDelta, index: ItemIndex) throws {
        guard delta.eligible,
            let target = try index.retainedAuthorityObject(id: delta.target.revisionID),
            target.descriptor.sha256 == delta.target.sha256, target.permittedOrigin
        else { throw TractandaError("invalidAuthority", "Local acceptance lost its exact target receipt.") }
        let node = try AuthorityRevision(originalBytes: bytes(target))
        guard node.revision.itemID == delta.target.itemID,
            node.revision.fields["actor"]?.string == delta.actor
        else { throw TractandaError("invalidAuthority", "Local acceptance target/actor mismatch.") }
        var selected: AuthorityStore.RetainedObject?
        if let binding = delta.evidence {
            guard let witness = try index.retainedAuthorityObject(id: binding.recordID),
                witness.descriptor.sha256 == binding.sha256,
                try matchesIdentity(node, AuthorityRecordCodec.decode(bytes(witness)).record)
            else {
                throw TractandaError("invalidAuthority", "Sealed acceptance evidence differs from original.")
            }
            var cursor: String?
            while selected == nil {
                let page = try index.authorityObjectReceiptPage(
                    objectID: binding.recordID, afterPackageID: cursor, limit: 128)
                if page.isEmpty { break }
                for receipt in page {
                    cursor = receipt.packageID
                    if receipt.permittedOrigin {
                        selected = receipt
                        break
                    }
                }
            }
            guard selected != nil else {
                throw TractandaError(
                    "invalidAuthority", "Sealed acceptance lost historical evidence receipt.")
            }
        } else if try node.revision.provenance?.kind == .authored {
            throw TractandaError("invalidAuthority", "Modern authored acceptance requires exact testimony.")
        }
        try index.restoreSealedEligibility(
            .init(
                object: target.descriptor, packageID: target.packageID,
                evidenceID: delta.evidence?.recordID, evidenceDigest: delta.evidence?.sha256,
                evidencePackageID: selected?.packageID))
    }
}
