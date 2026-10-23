import Foundation

/// Current credentials are private host state. Retirement roots/pages are immutable canonical
/// decisions. Admission uses UUIDv1 issuance time, never historical snapshot membership.
enum PeerLifecycle {
    static let capability = "tractanda.peer-lifecycle.v1"
    static let timestampProfile = "tractanda.peer-retirement-time.v1"
    static func revisionTicks(_ revisionID: String) throws -> Int64 {
        _ = try AuthorityRecord.persistentID(.text(revisionID))
        return Int64(try UUIDVersion1Components(UUID(uuidString: revisionID)!).timestamp)
            - Int64(UUIDVersion1Components.unixEpochOffset)
    }
    static func revisionIsRemoved(revisionID: String, effectiveAt: String) throws -> Bool {
        try revisionTicks(revisionID) >= RevisionTimestamp(effectiveAt).ticks
    }
    struct ReviewActivation: Codable {
        let profile: String
        let decision: AuthorityBinding
        let control: AuthorityBinding
        let packageID: String
    }
    struct ForeignActivation: Codable {
        let profile: String
        let root: AuthorityBinding
        let packageID: String
    }
    struct Activation: Codable, Equatable {
        let operationID: String
        let root: AuthorityBinding
        let origins: [String]
    }
    struct State: Codable, Equatable {
        let profile: String
        var historicalContexts: [PeerPackage.Context]
        var retirements: [Activation]
        static var empty: Self { .init(profile: capability, historicalContexts: [], retirements: []) }
        func validate(storeID: String?) throws {
            guard profile == PeerLifecycle.capability, historicalContexts.count <= 4096,
                retirements.count <= 256,
                Set(historicalContexts.map { $0.peerID + ":" + $0.configurationDigest }).count
                    == historicalContexts.count,
                Set(retirements.map(\.operationID)).count == retirements.count
            else {
                throw TractandaError("invalidPeerLifecycle", "Invalid private lifecycle state.")
            }
            for context in historicalContexts {
                _ = try PeerPackage.Context(
                    peerID: context.peerID, storeID: context.storeID,
                    configurationDigest: context.configurationDigest,
                    permittedOrigins: context.permittedOrigins)
                guard storeID == nil || context.storeID == storeID else {
                    throw TractandaError("invalidPeerLifecycle", "Historical context StoreID differs.")
                }
            }
            for activation in retirements {
                _ = try AuthorityRecord.persistentID(.text(activation.operationID))
                _ = try AuthorityBinding(recordID: activation.root.recordID, sha256: activation.root.sha256)
                guard !activation.origins.isEmpty,
                    activation.origins == Array(Set(activation.origins)).sorted(),
                    activation.origins.count <= 256
                else {
                    throw TractandaError("invalidPeerLifecycle", "Invalid retired origin set.")
                }
                for origin in activation.origins { _ = try AuthorityRecord.persistentID(.text(origin)) }
            }
        }
    }
    struct Member: Equatable {
        let objectID: String
        let sha256: String
        let kind: PeerPackage.Kind
        let eligible: Bool
        var value: ItemValue {
            .object([
                "objectID": .text(objectID), "sha256": .text(sha256), "kind": .text(kind.rawValue),
                "eligible": .boolean(eligible),
            ])
        }
        init(objectID: String, sha256: String, kind: PeerPackage.Kind, eligible: Bool) {
            self.objectID = objectID
            self.sha256 = sha256
            self.kind = kind
            self.eligible = eligible
        }
        init(_ value: ItemValue) throws {
            let fields = try AuthorityRecord.object(value, keys: ["objectID", "sha256", "kind", "eligible"])
            objectID = try AuthorityRecord.persistentID(fields["objectID"])
            sha256 = try AuthorityRecord.digest(fields["sha256"])
            guard let kind = PeerPackage.Kind(rawValue: try AuthorityRecord.text(fields["kind"])),
                kind == .item || kind == .authority, let eligible = fields["eligible"]?.booleanValue,
                kind == .item || !eligible
            else {
                throw TractandaError("invalidPeerLifecycle", "Invalid retirement member.")
            }
            self.kind = kind
            self.eligible = eligible
        }
    }
    /// A prepared local operation reserves the exact next Configuration bytes. Publishing that
    /// immutable sequence is its commit; the same manifest completes interruption before it.
    struct Operation: Codable {
        let profile: String
        let operationID: String
        let requestDigest: String
        let previousConfigurationDigest: String
        let sequence: UInt64
        let configuration: AuthorityStore.Configuration
        let retirementBytes: Data?
    }
    enum Boundary { case prepared, committed }
}

extension PeerIntakeCoordinator {
    func lifecycleOperation(_ id: String) throws -> PeerLifecycle.Operation? {
        _ = try AuthorityRecord.persistentID(.text(id))
        guard
            let bytes = try journal.files.readIfPresent(
                path: [".peer-lifecycle-operations", id],
                maximumBytes: PeerPackage.maximumPageBytes)
        else { return nil }
        let operation = try PeerPackage.decode(PeerLifecycle.Operation.self, bytes)
        guard operation.profile == PeerLifecycle.capability, operation.operationID == id,
            operation.sequence > 0
        else { throw TractandaError("invalidPeerLifecycle", "Invalid lifecycle operation.") }
        _ = try AuthorityRecord.digest(.text(operation.requestDigest))
        _ = try AuthorityRecord.digest(.text(operation.previousConfigurationDigest))
        try operation.configuration.lifecycle?.validate(storeID: storeID)
        return operation
    }
    func prepareLifecycleOperation(_ operation: PeerLifecycle.Operation) throws {
        try CanonicalReaderRequirement.beforePeerLifecyclePublication(
            root: root, ownerUID: ownerUID, support: canonicalFormatSupport)
        try StoreCheckpoint.markDirty(root: root)
        try journal.files.writeImmutable(
            try JSON.encode(operation),
            path: [".peer-lifecycle-operations", operation.operationID],
            maximumBytes: PeerPackage.maximumPageBytes)
    }
    @discardableResult
    func stageLifecycleRecord(_ record: AuthorityRecord, packageID: String) throws -> AuthorityBinding {
        let data = try AuthorityRecordCodec.encode(record)
        let descriptor = PeerPackage.Object(
            kind: .authority, id: record.recordID,
            length: data.count, sha256: AuthorityRecordCodec.sha256(data))
        if try journal.publication(packageID) == nil {
            let local = try context(peerID: "local")
            let manifest = try stageObjects([(descriptor, data)], context: local, packageID: packageID)
            let stamp = try RevisionTimestamp(record.createdAt).formatted()
            let minute = String(stamp.prefix(16)).replacingOccurrences(of: "-", with: "/")
                .replacingOccurrences(of: "T", with: "/").replacingOccurrences(of: ":", with: "/")
            try journal.prepare(
                .init(
                    packageID: packageID,
                    manifestDigest: AuthorityRecordCodec.sha256(JSON.encode(manifest)), context: local,
                    contextToken: PeerLifecycle.capability, arrivalMinute: minute))
            try StoreCheckpoint.markDirty(root: root)
            try journal.seal(packageID)
        }
        guard let publication = try journal.publication(packageID),
            publication.context == (try context(peerID: "local")),
            try journal.object(descriptor, packageID: packageID) == data
        else {
            throw TractandaError("invalidPeerLifecycle", "Lifecycle record publication differs.")
        }
        _ = try journal.publishOriginal(descriptor, bytes: data, publication: publication)
        try journal.applied(packageID)
        return try .init(recordID: record.recordID, sha256: descriptor.sha256)
    }
    /// Each snapshot page/root uses its own recordID as packageID. Boundaries and chunks are
    /// validated by the normal journal; no private filesystem locator is accepted from a peer.
    func lifecycleRecord(_ binding: AuthorityBinding) throws -> AuthorityRecordCodec.Verified {
        guard let publication = try journal.publication(binding.recordID),
            publication.context == (try context(peerID: "local"))
        else {
            throw TractandaError("invalidPeerLifecycle", "Retirement requires exact LOCAL sealed originals.")
        }
        var found: AuthorityRecordCodec.Verified?
        try journal.walk(binding.recordID) { descriptor, bytes in
            guard descriptor.id == binding.recordID, descriptor.kind == .authority,
                descriptor.sha256 == binding.sha256, let bytes, found == nil
            else {
                throw TractandaError("invalidPeerLifecycle", "Ambiguous/missing retirement original.")
            }
            found = try AuthorityRecordCodec.decode(bytes)
        }
        guard let found, found.sha256 == binding.sha256 else {
            throw TractandaError("invalidPeerLifecycle", "Retirement original is missing.")
        }
        return found
    }
    func retirementOriginal(_ binding: AuthorityBinding, index: ItemIndex) throws
        -> AuthorityRecordCodec.Verified
    {
        guard let row = try index.retainedAuthorityObject(id: binding.recordID),
            row.descriptor.sha256 == binding.sha256,
            row.descriptor.kind == .authority
        else {
            throw TractandaError(
                "invalidPeerLifecycle", "Activated retirement original is missing or changed.")
        }
        let original = try AuthorityRecordCodec.decode(bytes(row))
        guard original.record.kind == .originRetirement,
            original.record.payload["retirementProfile"] == .text(PeerLifecycle.timestampProfile),
            original.record.payload["effectiveAt"]?.dateString != nil
        else {
            throw TractandaError(
                "peerRetirementMigrationRequired",
                "Historical activated removal has no explicit timestamp; preserve evidence and migrate explicitly."
            )
        }
        return original
    }
    func foreignRetirements(_ visit: (PeerLifecycle.ForeignActivation) throws -> Void) throws {
        let directory = root.appendingPathComponent(".peer-retirement-activations")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var work = 0
        try POSIXDirectory.withEntries(at: directory) { name in
            work += 1
            guard work <= 256 else {
                throw TractandaError("resourceLimit", "Retirement activation window exceeded.")
            }
            _ = try AuthorityRecord.persistentID(.text(name))
            let value = try PeerPackage.decode(
                PeerLifecycle.ForeignActivation.self,
                journal.files.read(path: [".peer-retirement-activations", name], maximumBytes: 4096),
                maximum: 4096)
            guard value.profile == PeerLifecycle.timestampProfile, value.root.recordID == name else {
                throw TractandaError("invalidPeerLifecycle", "Retirement activation identity changed.")
            }
            try visit(value)
            return true
        }
    }
    func activateForeignRetirement(_ binding: AuthorityBinding, packageID: String) throws {
        try CanonicalReaderRequirement.beforePeerLifecyclePublication(
            root: root, ownerUID: ownerUID, support: canonicalFormatSupport)
        try StoreCheckpoint.markDirty(root: root)
        try journal.files.writeImmutable(
            try JSON.encode(
                PeerLifecycle.ForeignActivation(
                    profile: PeerLifecycle.timestampProfile, root: binding, packageID: packageID)),
            path: [".peer-retirement-activations", binding.recordID], maximumBytes: 4096)
    }
    func finishLifecycleOperation(_ operation: PeerLifecycle.Operation) throws {
        let configurationPath = [".peer-configuration", String(format: "%020llu.json", operation.sequence)]
        if let existing = try journal.files.readIfPresent(
            path: configurationPath,
            maximumBytes: PeerPackage.maximumPageBytes)
        {
            guard existing == (try JSON.encode(operation.configuration)) else {
                throw TractandaError("peerLifecycleChanged", "Committed lifecycle configuration differs.")
            }
            return
        }
        guard try AuthorityStore.configurationSequence(root: root) + 1 == operation.sequence,
            AuthorityRecordCodec.sha256(try JSON.encode(configuration()))
                == operation.previousConfigurationDigest
        else {
            throw TractandaError(
                "peerLifecycleChanged", "Pending lifecycle operation lost its original configuration.")
        }
        if let bytes = operation.retirementBytes {
            let record = try AuthorityRecordCodec.decode(bytes).record
            guard let activation = operation.configuration.lifecycle?.retirements.last,
                activation.operationID == operation.operationID,
                activation.root == (try recordBinding(record))
            else {
                throw TractandaError(
                    "invalidPeerLifecycle", "Prepared retirement/configuration binding differs.")
            }
            _ = try stageLifecycleRecord(record, packageID: record.recordID)
            guard record.payload["retirementProfile"] == .text(PeerLifecycle.timestampProfile),
                record.payload["effectiveAt"]?.dateString != nil
            else {
                throw TractandaError(
                    "peerRetirementMigrationRequired",
                    "Prepared historical removal requires explicit migration.")
            }
        }
        try AuthorityStore.writeConfiguration(
            operation.configuration, root: root, files: journal.files,
            sequence: operation.sequence)
    }
    func recoverLifecycleOperations() throws {
        let directory = root.appendingPathComponent(".peer-lifecycle-operations")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        // Synchronous operations reserve one next sequence; later mutations cannot overtake a
        // failed prepared unit. Completed older operations are verified without reapplying them.
        var count = 0
        try POSIXDirectory.withEntries(at: directory) { name in
            count += 1
            guard count <= 100_000, let operation = try lifecycleOperation(name) else {
                throw TractandaError("resourceLimit", "Lifecycle operation history is invalid or too large.")
            }
            try finishLifecycleOperation(operation)
            return true
        }
    }
    @discardableResult
    func loadPeerRetirements(index: ItemIndex) throws -> Bool {
        try index.initializePeerLifecycleSchema()
        try index.initializePeerRetirementEffects()
        let prior = try index.peerRetirementActiveBindings()
        struct Candidate {
            let binding: AuthorityBinding
            let issuer: String
            let origins: [String]
            let effective: String
            let ticks: Int64
        }
        var candidates: [Candidate] = []
        var totalBytes = 0
        func candidate(_ binding: AuthorityBinding) throws {
            let original = try retirementOriginal(binding, index: index)
            totalBytes += original.originalBytes.count
            guard candidates.count < 512, UInt64(totalBytes) <= journal.limits.maximumStagedBytes else {
                throw TractandaError("resourceLimit", "Retirement temporal replay metadata window exceeded.")
            }
            let record = original.record
            let time = record.payload["effectiveAt"]!.dateString!
            let ticks = try PeerLifecycle.revisionTicks(record.recordID)
            guard try RevisionTimestamp(time).ticks == ticks else {
                throw TractandaError(
                    "invalidPeerLifecycle",
                    "Removal effective time must be its exact UUIDv1 event issuance time.")
            }
            candidates.append(
                .init(
                    binding: binding, issuer: record.originReplicaID,
                    origins: try AuthorityRecord.ids(record.payload["origins"]), effective: time, ticks: ticks
                ))
        }
        for activation in try configuration()?.lifecycle?.retirements ?? [] {
            let original = try lifecycleRecord(activation.root).record
            guard original.payload["operationID"]?.string == activation.operationID,
                try AuthorityRecord.ids(original.payload["origins"]) == activation.origins
            else {
                throw TractandaError(
                    "invalidPeerLifecycle", "Local retirement activation differs from its original.")
            }
            try candidate(activation.root)
        }
        try foreignRetirements { activation in
            let original = try retirementOriginal(activation.root, index: index).record
            guard
                let receipt = try index.authorityReceipt(
                    objectID: activation.root.recordID, packageID: activation.packageID),
                try receiptContextPermits(receipt, origin: original.originReplicaID, index: index)
            else {
                throw TractandaError(
                    "invalidPeerLifecycle", "Retirement lost its authenticated admission receipt.")
            }
            try candidate(activation.root)
        }
        try index.clearPeerLifecycle()
        for entry in candidates { try index.retainPeerRetirementProof(entry.binding) }
        // With effectiveAt == root UUID time, direct invalidation edges strictly increase time.
        // Equal-tick removal events are simultaneous and retain both PRE-event authorities.
        for entry in candidates.sorted(by: {
            ($0.ticks, $0.binding.recordID) < ($1.ticks, $1.binding.recordID)
        }) {
            if try index.peerAuthorityTimePermits(origin: entry.issuer, ticks: entry.ticks) {
                try index.retainPeerRetirement(
                    entry.binding, origins: entry.origins, effectiveAt: entry.effective)
            }
        }
        let changed = try prior != index.peerRetirementActiveBindings()
        if changed { try index.resetPeerRetirementEffects() }
        return changed
    }
    func validatePeerRetirementCuts(index: ItemIndex) throws {
        func validate(_ binding: AuthorityBinding) throws {
            let root = try retirementOriginal(binding, index: index).record
            let cut = try AuthorityBinding(value: root.payload["cut"]!)
            guard try index.hasValidatedAuthorityControl(cut),
                try logicalControlHeader(cut, index: index).origin == root.originReplicaID
            else {
                throw TractandaError("invalidPeerLifecycle", "Retirement source PRE cut is not validated.")
            }
        }
        for activation in try configuration()?.lifecycle?.retirements ?? [] { try validate(activation.root) }
        try foreignRetirements { try validate($0.root) }
    }
    func receiptContextPermits(
        _ row: AuthorityStore.RetainedObject, origin: String,
        index: ItemIndex, configuration supplied: AuthorityStore.Configuration? = nil,
        forAdministratorReview: Bool = false, readBudget: ((Int) throws -> Void)? = nil
    ) throws -> Bool {
        guard row.permittedOrigin,
            let publication = try journal.publication(row.packageID, readBudget: readBudget),
            publication.context.peerID == row.peerID,
            publication.context.configurationDigest == row.configurationDigest
        else { return false }
        guard
            try publication.context.permittedOrigins.contains(origin)
                || admittedReceiptPermits(
                    packageID: row.packageID, origin: origin, index: index,
                    readBudget: readBudget)
        else { return false }
        let configuration = try supplied ?? self.configuration(readBudget: readBudget)
        if row.peerID == "local" {
            return try publication.context == context(peerID: "local", readBudget: readBudget)
        }
        if let provisioningScope,
            try provisioningScope.permits(publication, readBudget: readBudget ?? admissionReadBudget())
        {
            return true
        }
        if configuration?.peers.contains(publication.context) == true { return true }
        if configuration?.lifecycle?.historicalContexts.contains(publication.context) == true {
            return true
        }
        // Captured pre-pairing native trust is reconstructed from its exact approved request
        // and completed transition. This applies to roots AND selected source testimony; it
        // does not substitute today's peer list, grant an origin, or qualify pending targets
        // for ordinary opening. The private scope above owns unfinished activation recovery.
        if let supplied,
            let receiver = try ReplicaIdentity.load(
                root: root, storeID: storeID, ownerUID: ownerUID,
                readBudget: readBudget ?? admissionReadBudget())?.replicaID
        {
            return try PeerEnrollmentActivation.permitsHistoricalPublication(
                publication, receiverReplicaID: receiver, capturedConfiguration: supplied,
                files: journal.files, readBudget: readBudget ?? admissionReadBudget())
        }
        return false
    }
    /// This hold is independent of parent readiness. It grants no dependency closure or
    /// reviewability and never overwrites an earlier immutable assessment/acceptance.
    func assessRetiredOriginalIfNeeded(
        _ node: AuthorityRevision, row: AuthorityStore.RetainedObject,
        index: ItemIndex
    ) throws {
        guard try retirementBlocks(node, index: index),
            let current = try index.authorityDisposition(id: row.descriptor.id)?.disposition,
            [.eligible, .pending, .missingDependencies].contains(current)
        else { return }
        if let saved = try assessment(packageID: row.packageID, object: row.descriptor),
            saved.evaluation.disposition != .eligible
        {
            return
        }
        let result = AuthorityStore.Evaluation(
            disposition: .held,
            reason:
                "Retired-origin revision is at or after the removal cutoff; complete dependencies and fresh administrator review required."
        )
        try index.notePeerRetirementEffect(row.descriptor.id)
        try index.setAuthorityDisposition(id: row.descriptor.id, evaluation: result)
    }
    func retirementBlocks(_ node: AuthorityRevision, index: ItemIndex) throws -> Bool {
        guard let origin = try node.revision.provenance?.originReplicaID else { return false }
        let causes = try index.peerRetirementCauses(revisionID: node.revision.revisionID, origin: origin)
        return try !causes.isEmpty
            && !index.peerLifecycleHasFreshReview(node.revision.revisionID, causes: causes)
    }
    func foreignReviewActivation(_ decision: AuthorityBinding) throws -> PeerLifecycle.ReviewActivation? {
        guard
            let data = try journal.files.readIfPresent(
                path: [".peer-review-activations", decision.recordID], maximumBytes: 4096)
        else { return nil }
        let value = try PeerPackage.decode(PeerLifecycle.ReviewActivation.self, data, maximum: 4096)
        guard value.profile == "tractanda.shared-authority.v1", value.decision == decision else {
            throw TractandaError("invalidAuthority", "Foreign review activation changed.")
        }
        return value
    }
    func activateForeignReview(_ plan: AuthorityStore.VerifiedReviewPlan, packageID: String) throws {
        try CanonicalReaderRequirement.beforeReviewPublication(
            root: root, ownerUID: ownerUID, support: canonicalFormatSupport)
        try StoreCheckpoint.markDirty(root: root)
        try journal.files.writeImmutable(
            try JSON.encode(
                PeerLifecycle.ReviewActivation(
                    profile: "tractanda.shared-authority.v1", decision: plan.event.binding,
                    control: plan.control.binding, packageID: packageID)),
            path: [".peer-review-activations", plan.event.binding.recordID], maximumBytes: 4096)
    }

}
