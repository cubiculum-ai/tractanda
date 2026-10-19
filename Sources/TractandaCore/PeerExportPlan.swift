import Foundation

/// Private outbound work journal. It contains descriptors/pages, never canonical item bodies.
/// Store serializes calls; no transaction, root writer or model process spans a network wait.
final class PeerExportPlan {
    struct Limits: Codable, Equatable, Sendable {
        var maximumObjects = 1_000_000
        var maximumPlanBytes: UInt64 = 256 * 1024 * 1024
        var pageFanout = 128
        func validate() throws {
            guard maximumObjects > 0, maximumPlanBytes >= 4096, (2...128).contains(pageFanout) else {
                throw TractandaError("resourceLimit", "Invalid private export plan limits.")
            }
        }
    }
    struct Window: Sendable {
        var maximumUnits = 16
        var maximumEdges = 64
        var maximumReadBytes: UInt64 = 32 * 1024 * 1024
        var maximumJournalBytes = 1024 * 1024
        func validate() throws {
            guard (1...128).contains(maximumUnits), (1...128).contains(maximumEdges),
                maximumReadBytes > 0, maximumReadBytes <= 512 * 1024 * 1024,
                maximumJournalBytes >= 4096, maximumJournalBytes <= 16 * 1024 * 1024
            else { throw TractandaError("resourceLimit", "Invalid export operation window.") }
        }
    }
    struct Handle: Sendable {
        let planID: String
        let packageID: String
        fileprivate let beginDigest: String
    }
    struct Begin: Codable, Equatable {
        let profile: String
        let planID: String
        let packageID: String
        let context: PeerPackage.Context
        let securityBinding: String
        let boundary: PeerInventory.Boundary
        let epoch: String
        let limits: Limits
        static func == (lhs: Self, rhs: Self) -> Bool {
            (try? JSON.encode(lhs)) == (try? JSON.encode(rhs))
        }
    }
    enum Phase: String, Codable, Sendable { case selecting, closure, leaves, indexes, sealed }
    enum ObjectState: String, Codable, Sendable { case pending, missing, unsupported, verified }
    struct State: Codable {
        var sequence = 0
        var digest: String
        var phase: Phase = .selecting
        var chargedBytes: UInt64 = 0
        var retryAfter = ""
        var leafAfter = ""
        var level = 0
        var afterOrdinal = -1
        var nextOrdinal = 0
    }
    struct OriginalBinding: Codable, Equatable {
        let descriptor: AttachmentDescriptor
        let revisionID: String
        let revisionSHA256: String
        let receiptID: String
    }
    struct DocumentBinding: Codable, Equatable, Sendable {
        let document: AttachmentDocumentRepresentation
        let revisionID: String
        let revisionSHA256: String
        let receiptID: String
        func sameTree(as other: Self) -> Bool {
            document.content == other.document.content && document.source == other.document.source
                && document.identity == other.document.identity
                && document.extractedAt == other.document.extractedAt
        }
    }
    struct Slot: Codable, Sendable {
        let id: String
        var kind: PeerPackage.Kind?
        var expectedDigest: String?
        var descriptor: PeerPackage.Object?
        var receipt: String?
        var original: OriginalBinding?
        var document: DocumentBinding? = nil
        var root = false
        var status: ObjectState = .pending
        var phase = 0
        var after = ""
        var offset = 0
        var reason: String?
        var unsupportedReason: String?
    }
    struct Reference {
        let id: String
        let kind: PeerPackage.Kind?
        let digest: String?
        var cursor = ""
        var original: OriginalBinding? = nil
        var document: DocumentBinding? = nil
    }
    struct IndexPage: Codable {
        let level: Int
        let ordinal: Int
        let descriptor: PeerPackage.Object
        let bytes: Data
    }
    struct Event: Codable {
        let previousDigest: String
        var next: State
        let slots: [Slot]
        let pages: [IndexPage]
        let manifest: PeerPackage.Manifest?
        let sealedObjects: Int?
    }
    struct Seal: Codable {
        let manifestDigest: String
        let objects: Int
        let chargedBytes: UInt64
    }
    struct Status: Sendable {
        let phase: Phase
        let objects: Int
        let pending: Int
        let missing: Int
        let unsupported: Int
        let chargedBytes: UInt64
        let manifest: PeerPackage.Manifest?
    }
    struct ObjectPage: Sendable {
        let objects: [Slot]
        let nextAfterID: String?
    }
    struct Chunk: Sendable {
        let descriptor: PeerPackage.Object
        let offset: Int
        let bytes: Data
        let receiverKnown: Bool
    }
    enum Boundary { case journaled, artifactsPersisted }
    var afterBoundaryForTesting: ((Boundary) throws -> Void)?
    private let coordinator: PeerIntakeCoordinator
    private let index: ItemIndex
    private let files: DocumentContentFiles
    private let context: PeerPackage.Context
    private let securityBinding: String
    private let progress: (() throws -> Void)?
    private let ownerScope: PeerEnrollmentApproval.OwnerExportScope?
    private var bootstrapProof = PeerInventory.BootstrapProof()
    private var readBytes: UInt64 = 0
    private var journalBytes = 0
    private var window = Window()
    init(
        coordinator: PeerIntakeCoordinator, index: ItemIndex, context: PeerPackage.Context,
        securityBinding: String, progress: (() throws -> Void)? = nil,
        ownerScope: PeerEnrollmentApproval.OwnerExportScope? = nil
    ) {
        self.coordinator = coordinator
        self.index = index
        files = coordinator.journal.files
        self.context = context
        self.securityBinding = securityBinding
        self.progress = progress
        self.ownerScope = ownerScope
    }
    private func check() throws {
        try Task.checkCancellation()
        try index.checkCatalogueScanProgress()
        try progress?()
        try PeerEnrollmentApproval.requireExport(context, coordinator: coordinator, ownerScope: ownerScope)
    }
    private func path(_ id: String, _ tail: [String]) throws -> [String] {
        _ = try AuthorityRecord.persistentID(.text(id))
        return ["authority", "export", id] + tail
    }
    private func write(_ bytes: Data, _ id: String, _ tail: [String]) throws {
        let location = try path(id, tail)
        if let old = try files.readIfPresent(path: location, maximumBytes: PeerPackage.maximumPageBytes) {
            guard old == bytes else {
                throw TractandaError("peerObjectCollision", "Export journal/artifact bytes differ.")
            }
        } else {
            try files.writeImmutable(bytes, path: location, maximumBytes: PeerPackage.maximumPageBytes)
        }
    }
    private func raw(_ row: AuthorityStore.RetainedObject) throws -> Data {
        try check()
        try row.descriptor.validate()
        guard
            UInt64(row.descriptor.length) <= window.maximumReadBytes - min(readBytes, window.maximumReadBytes)
        else {
            throw TractandaError(
                "resourceLimit", "Export hydration window exhausted; resume in another step.")
        }
        readBytes += UInt64(row.descriptor.length)
        return try coordinator.bytes(row)
    }
    private func chargeBootstrapProof(_ count: Int) throws {
        try check()
        guard count >= 0, UInt64(count) <= window.maximumReadBytes - min(readBytes, window.maximumReadBytes) else {
            throw TractandaError("resourceLimit", "Initial membership proof exhausted export read window.")
        }
        readBytes += UInt64(count)
    }
    private func initialPin(_ node: AuthorityRevision) throws -> AuthorityBinding? {
        try PeerInventory.canonicalInitialPin(node, coordinator: coordinator, index: index,
            proof: bootstrapProof, read: raw, charge: chargeBootstrapProof)
    }
    private func chargeDocumentMetadata(_ count: Int) throws {
        guard count >= 0, UInt64(count) <= window.maximumReadBytes - min(readBytes, window.maximumReadBytes)
        else {
            throw TractandaError("peerPayloadVerifying", "Export read window exhausted; retry delivery.")
        }
        readBytes += UInt64(count)
    }
    func begin(
        planID: String, packageID: String, boundary: PeerInventory.Boundary,
        limits: Limits
    ) throws -> Handle {
        try check()
        try limits.validate()
        _ = try AuthorityRecord.persistentID(.text(packageID))
        guard planID != packageID else {
            throw TractandaError("peerObjectCollision", "Plan and package identities must differ.")
        }
        let epoch = try PeerInventory.exportEpoch(boundary, context: context, coordinator: coordinator, index: index)
        let begin = Begin(
            profile: "tractanda.peer-export.v3", planID: planID, packageID: packageID,
            context: context, securityBinding: securityBinding, boundary: boundary, epoch: epoch,
            limits: limits)
        let bytes = try JSON.encode(begin)
        guard try index.retainedAuthorityObject(id: planID) == nil,
            try index.retainedAuthorityObject(id: packageID) == nil
        else {
            throw TractandaError(
                "peerObjectCollision", "Export plan/package identity collides with an original.")
        }
        try write(
            try JSON.encode(ItemValue.object(["planID": .text(planID), "packageID": .text(packageID)])),
            packageID, ["package-reservation.json"])
        try write(bytes, planID, ["begin.json"])
        let handle = Handle(
            planID: planID, packageID: packageID, beginDigest: AuthorityRecordCodec.sha256(bytes))
        try index.initializePeerExportSchema()
        if try index.peerExportState(planID) == nil {
            guard
                try files.readIfPresent(
                    path: path(planID, ["events", "1.json"]), maximumBytes: PeerPackage.maximumPageBytes)
                    == nil
            else {
                throw TractandaError(
                    "peerExportChanged", "Disposable export queue is absent; capture a new plan.")
            }
            try index.peerExportInsert(
                planID, state: .init(digest: handle.beginDigest, chargedBytes: UInt64(bytes.count)))
        }
        _ = try loaded(handle)
        return handle
    }
    /// Distinguish a planned-but-not-created journal from lost/corrupt existing artifacts.
    func exists(planID: String, packageID: String) throws -> Bool {
        if try files.readIfPresent(path: path(planID, ["begin.json"]), maximumBytes: PeerPackage.maximumPageBytes) != nil {
            _ = try reopen(planID: planID, packageID: packageID)
            return true
        }
        var occupied = false
        do { try files.withDirectoryEntries(path: path(planID, [])) { _ in occupied = true; return false } }
        catch let error as TractandaError where error.osError == ENOENT { return false }
        guard !occupied else { throw TractandaError("peerRepairRequired", "Export journal lost its begin binding.") }
        return false
    }
    /// A durable handle can be reopened by exact IDs; it is never a wire capability.
    func reopen(planID: String, packageID: String) throws -> Handle {
        let bytes = try files.read(
            path: path(planID, ["begin.json"]), maximumBytes: PeerPackage.maximumPageBytes)
        let handle = Handle(
            planID: planID, packageID: packageID, beginDigest: AuthorityRecordCodec.sha256(bytes))
        _ = try validate(handle)
        return handle
    }
    private func validate(_ handle: Handle) throws -> Begin {
        try check()
        let bytes = try files.read(
            path: path(handle.planID, ["begin.json"]), maximumBytes: PeerPackage.maximumPageBytes)
        let begin = try PeerPackage.decode(Begin.self, bytes)
        guard begin.profile == "tractanda.peer-export.v3", begin.planID == handle.planID,
            begin.packageID == handle.packageID, begin.context == context,
            begin.securityBinding == securityBinding, AuthorityRecordCodec.sha256(bytes) == handle.beginDigest
        else { throw TractandaError("peerExportChanged", "Export handle/security binding is stale.") }
        try begin.limits.validate()
        return begin
    }
    private func loaded(_ handle: Handle) throws -> (Begin, State) {
        let begin = try validate(handle)
        guard try index.capturePeerInventory().epoch == begin.epoch else {
            throw TractandaError(
                "peerExportChanged", "Rebuild invalidated unfinished export work; capture a new plan.")
        }
        try index.initializePeerExportSchema()
        guard var state = try index.peerExportState(handle.planID) else {
            throw TractandaError("peerExportChanged", "Disposable export work is absent; capture a new plan.")
        }
        // One atomic SQL transition can lag its already synchronized immutable event.
        if let bytes = try files.readIfPresent(
            path: path(handle.planID, ["events", String(state.sequence + 1) + ".json"]),
            maximumBytes: PeerPackage.maximumPageBytes)
        {
            let event = try PeerPackage.decode(Event.self, bytes)
            guard event.previousDigest == state.digest, event.next.sequence == state.sequence + 1 else {
                throw TractandaError("invalidPeerExport", "Export event sequence/digest differs.")
            }
            try persistArtifacts(event, handle: handle)
            try index.peerExportApply(handle.planID, event: event)
            state = try index.peerExportState(handle.planID)!
        }
        return (begin, state)
    }
    private func persistArtifacts(_ event: Event, handle: Handle) throws {
        for slot in event.slots {
            if let original = slot.original {
                try write(try JSON.encode(original), handle.planID, ["originals", slot.id + ".json"])
            }
            if let document = slot.document {
                try write(try JSON.encode(document), handle.planID, ["documents", slot.id + ".json"])
            }
            if let descriptor = slot.descriptor {
                try write(try JSON.encode(descriptor), handle.planID, ["descriptors", slot.id + ".json"])
                if let receipt = slot.receipt {
                    try write(try JSON.encode(receipt), handle.planID, ["receipts", slot.id + ".json"])
                }
            }
        }
        for page in event.pages {
            try page.descriptor.validate()
            guard page.descriptor.kind == .index, page.bytes.count == page.descriptor.length,
                AuthorityRecordCodec.sha256(page.bytes) == page.descriptor.sha256
            else { throw TractandaError("invalidPeerExport", "Export index reservation differs.") }
            try PeerPackage.decode(PeerPackage.Page.self, page.bytes).validate()
            try write(
                try JSON.encode(page.descriptor), handle.planID,
                ["descriptors", page.descriptor.id + ".json"])
            try write(page.bytes, handle.planID, ["pages", page.descriptor.id + ".json"])
        }
        if let manifest = event.manifest {
            try manifest.validate()
            guard manifest.packageID == handle.packageID, manifest.storeID == context.storeID else {
                throw TractandaError("invalidPeerExport", "Export manifest binding differs.")
            }
            let bytes = try JSON.encode(manifest)
            guard let count = event.sealedObjects, count > 0 else {
                throw TractandaError("invalidPeerExport", "Missing seal summary.")
            }
            try write(
                try JSON.encode(
                    Seal(
                        manifestDigest: AuthorityRecordCodec.sha256(bytes), objects: count,
                        chargedBytes: event.next.chargedBytes)), handle.planID, ["seal.json"])
            try write(bytes, handle.planID, ["manifest.json"])
        }
    }
    private func commit(
        _ handle: Handle, begin: Begin, old: State, next: State,
        slots: [Slot] = [], pages: [IndexPage] = [], manifest: PeerPackage.Manifest? = nil
    ) throws -> State {
        try check()
        var next = next
        next.sequence = old.sequence + 1
        next.digest = ""  // Event hash is computed by the derived row after the immutable event exists.
        var event = Event(
            previousDigest: old.digest, next: next, slots: slots, pages: pages, manifest: manifest,
            sealedObjects: manifest == nil ? nil : try index.peerExportCount(handle.planID))
        var bytes = try JSON.encode(event)
        let artifacts =
            try slots.compactMap(\.descriptor).reduce(0) { try $0 + JSON.encode($1).count }
            + slots.compactMap(\.original).reduce(0) { try $0 + JSON.encode($1).count }
            + slots.compactMap(\.document).reduce(0) { try $0 + JSON.encode($1).count }
            + pages.reduce(0) { $0 + $1.bytes.count + 512 } + (manifest == nil ? 0 : 1024)
        // Conservative reserve includes variable integer encoding growth and directory entries.
        let charge = UInt64(bytes.count + artifacts + 4096)
        guard charge <= begin.limits.maximumPlanBytes - min(old.chargedBytes, begin.limits.maximumPlanBytes),
            bytes.count + 64 <= window.maximumJournalBytes - min(journalBytes, window.maximumJournalBytes)
        else {
            throw TractandaError(
                "resourceLimit", "Export journal/output allowance exhausted; earlier progress is durable.")
        }
        next.chargedBytes = old.chargedBytes + charge
        event.next = next
        bytes = try JSON.encode(event)
        guard bytes.count <= PeerPackage.maximumPageBytes else {
            throw TractandaError("resourceLimit", "Export event exceeds its metadata frame.")
        }
        journalBytes += bytes.count
        try write(bytes, handle.planID, ["events", String(next.sequence) + ".json"])
        try afterBoundaryForTesting?(.journaled)
        try persistArtifacts(event, handle: handle)
        try afterBoundaryForTesting?(.artifactsPersisted)
        try index.peerExportApply(handle.planID, event: event)
        return try index.peerExportState(handle.planID)!
    }
    private func merged(_ ref: Reference, plan: String, changed: inout [String: Slot]) throws -> Slot {
        _ = try AuthorityRecord.persistentID(.text(ref.id))
        if let digest = ref.digest { _ = try AuthorityRecord.digest(.text(digest)) }
        var slot =
            try changed[ref.id] ?? index.peerExportSlot(plan, id: ref.id)
            ?? Slot(id: ref.id, kind: ref.kind, expectedDigest: ref.digest)
        guard ref.kind == nil || slot.kind == nil || slot.kind == ref.kind,
            ref.digest == nil || slot.expectedDigest == nil || slot.expectedDigest == ref.digest,
            ref.digest == nil || slot.descriptor == nil || slot.descriptor?.sha256 == ref.digest,
            ref.kind == nil || slot.descriptor == nil || slot.descriptor?.kind == ref.kind
        else {
            throw TractandaError(
                "peerObjectCollision", "One export identity has conflicting kind/digest references.")
        }
        if let incoming = ref.original {
            if let original = slot.original, original.descriptor != incoming.descriptor {
                throw TractandaError("peerObjectCollision", "Original descriptor witnesses disagree.")
            }
            slot.original = slot.original ?? incoming
        }
        if let incoming = ref.document {
            if let document = slot.document, !document.sameTree(as: incoming) {
                throw TractandaError("peerObjectCollision", "Document tree witnesses disagree.")
            }
            slot.document = slot.document ?? incoming
        }
        slot.kind = slot.kind ?? ref.kind
        slot.expectedDigest = slot.expectedDigest ?? ref.digest
        changed[ref.id] = slot
        return slot
    }
    private func checkCount(_ changed: [String: Slot], begin: Begin) throws {
        var count = try index.peerExportCount(begin.planID)
        for id in changed.keys where try index.peerExportSlot(begin.planID, id: id) == nil { count += 1 }
        guard count <= begin.limits.maximumObjects else {
            throw TractandaError(
                "resourceLimit", "Export object allowance exhausted; no dependency was truncated.")
        }
    }
    func select(_ handle: Handle, entries: [PeerInventory.Entry], finish: Bool) throws -> Status {
        bootstrapProof = .init()
        readBytes = 0
        guard entries.count <= 128 else {
            throw TractandaError("resourceLimit", "Select at most128 roots per call.")
        }
        let (begin, old) = try loaded(handle)
        if old.phase != .selecting {
            guard finish else {
                throw TractandaError("peerExportSelectionClosed", "Export root selection is immutable.")
            }
            for entry in entries {
                guard let slot = try index.peerExportSlot(handle.planID, id: entry.descriptor.id),
                    slot.root, slot.descriptor == entry.descriptor
                else {
                    throw TractandaError(
                        "peerExportSelectionClosed", "Closed selection cannot add or change a root.")
                }
            }
            return try status(handle)
        }
        var changed: [String: Slot] = [:]
        for entry in entries {
            try check()
            let row = try PeerInventory.exportSelection(
                entry, boundary: begin.boundary, context: context, coordinator: coordinator, index: index,
                ownerScope: ownerScope, bootstrapProof: bootstrapProof, proofReadBudget: chargeBootstrapProof)
            var slot = try merged(
                .init(id: entry.descriptor.id, kind: entry.descriptor.kind, digest: entry.descriptor.sha256),
                plan: handle.planID, changed: &changed)
            guard slot.descriptor == nil || slot.descriptor == entry.descriptor else {
                throw TractandaError("peerObjectCollision", "Selected exact descriptor differs.")
            }
            slot.descriptor = entry.descriptor
            slot.receipt = row.packageID
            slot.root = true
            changed[slot.id] = slot
        }
        try checkCount(changed, begin: begin)
        guard try !finish || index.peerExportCount(handle.planID) + changed.count > 0 else {
            throw TractandaError("invalidPeerExport", "An export must select at least one root.")
        }
        var next = old
        if finish { next.phase = .closure }
        _ = try commit(
            handle, begin: begin, old: old, next: next, slots: changed.values.sorted { $0.id < $1.id })
        return try status(handle)
    }
    func status(_ handle: Handle) throws -> Status {
        let begin = try validate(handle)
        if let manifest = try manifest(handle) {
            let seal = try PeerPackage.decode(
                Seal.self,
                files.read(
                    path: path(handle.planID, ["seal.json"]), maximumBytes: PeerPackage.maximumPageBytes))
            guard seal.manifestDigest == AuthorityRecordCodec.sha256(try JSON.encode(manifest)),
                seal.objects > 0
            else { throw TractandaError("invalidPeerExport", "Export summary differs.") }
            return .init(
                phase: .sealed, objects: seal.objects, pending: 0, missing: 0, unsupported: 0,
                chargedBytes: seal.chargedBytes, manifest: manifest)
        }
        let (_, state) = try loaded(handle)
        guard state.chargedBytes <= begin.limits.maximumPlanBytes else {
            throw TractandaError("invalidPeerExport", "Export accounting differs.")
        }
        return try .init(
            phase: state.phase, objects: index.peerExportCount(handle.planID),
            pending: index.peerExportCount(handle.planID, status: ObjectState.pending.rawValue),
            missing: index.peerExportCount(handle.planID, status: ObjectState.missing.rawValue),
            unsupported: index.peerExportCount(handle.planID, status: ObjectState.unsupported.rawValue),
            chargedBytes: state.chargedBytes, manifest: nil)
    }
    func objects(_ handle: Handle, afterID: String = "", limit: Int = 128) throws -> ObjectPage {
        _ = try loaded(handle)
        let slots = try index.peerExportSlots(handle.planID, after: afterID, limit: limit)
        return .init(objects: slots, nextAfterID: slots.count == limit ? slots.last?.id : nil)
    }
    func manifest(_ handle: Handle) throws -> PeerPackage.Manifest? {
        _ = try validate(handle)
        guard
            let bytes = try files.readIfPresent(
                path: path(handle.planID, ["manifest.json"]), maximumBytes: PeerPackage.maximumPageBytes)
        else { return nil }
        let value = try PeerPackage.decode(PeerPackage.Manifest.self, bytes)
        try value.validate()
        let seal = try PeerPackage.decode(
            Seal.self,
            files.read(path: path(handle.planID, ["seal.json"]), maximumBytes: PeerPackage.maximumPageBytes))
        guard value.packageID == handle.packageID, value.storeID == context.storeID,
            seal.manifestDigest == AuthorityRecordCodec.sha256(bytes), seal.objects > 0
        else {
            throw TractandaError("invalidPeerExport", "Manifest identity or immutable seal differs.")
        }
        return value
    }
    /// Historical sealed export evidence is read-only. It cannot become a current wire handle.
    func retainedManifest(planID: String, packageID: String) throws -> PeerPackage.Manifest {
        let begin = try PeerPackage.decode(
            Begin.self,
            files.read(path: path(planID, ["begin.json"]), maximumBytes: PeerPackage.maximumPageBytes))
        guard
            ["tractanda.peer-export.v1", "tractanda.peer-export.v2", "tractanda.peer-export.v3"].contains(
                begin.profile),
            begin.planID == planID, begin.packageID == packageID, begin.context.storeID == context.storeID
        else {
            throw TractandaError("invalidPeerExport", "Historical export identity differs.")
        }
        let bytes = try files.read(
            path: path(planID, ["manifest.json"]), maximumBytes: PeerPackage.maximumPageBytes)
        let manifest = try PeerPackage.decode(PeerPackage.Manifest.self, bytes)
        try manifest.validate(retained: true)
        let seal = try PeerPackage.decode(
            Seal.self,
            files.read(path: path(planID, ["seal.json"]), maximumBytes: PeerPackage.maximumPageBytes))
        guard manifest.packageID == packageID, manifest.storeID == context.storeID,
            begin.profile == "tractanda.peer-export.v1"
                ? manifest.profile == PeerPackage.retainedMetadataProfile
                : manifest.profile
                    == (begin.profile == "tractanda.peer-export.v2"
                        ? PeerPackage.retainedOriginalProfile : PeerPackage.profile),
            seal.objects > 0,
            seal.manifestDigest == AuthorityRecordCodec.sha256(bytes)
        else {
            throw TractandaError("invalidPeerExport", "Historical export seal differs.")
        }
        return manifest
    }
    /// Validates one retained immutable original against fresh configured receipt continuity.
    /// Retirement cut checks stay in the existing receipt helper; no acceptance is inferred.
    private func verified(_ row: AuthorityStore.RetainedObject) throws -> Data? {
        let data = try raw(row)
        let origin: String?
        if row.descriptor.kind == .item {
            let node = try AuthorityRevision(originalBytes: data)
            guard node.revision.revisionID == row.descriptor.id else {
                throw TractandaError("peerObjectCollision", "Export item identity differs.")
            }
            origin = try node.revision.provenance?.originReplicaID
            if origin == nil {
                guard try initialPin(node) != nil else { return nil }
                return data
            }
            if let origin, try coordinator.receiptContextPermits(row, origin: origin, index: index, readBudget: chargeBootstrapProof) { return data }
            guard try initialPin(node) != nil,
                try PeerInventory.initialLocalReceipt(row, node: node, coordinator: coordinator,
                    charge: chargeBootstrapProof) else { return nil }
            return data
        } else if row.descriptor.kind == .authority {
            let record = try AuthorityRecordCodec.decode(data).record
            guard record.recordID == row.descriptor.id, record.storeID == context.storeID else {
                throw TractandaError("peerObjectCollision", "Export authority identity/store differs.")
            }
            origin = record.originReplicaID
        } else {
            throw TractandaError(
                "unsupportedPeerDependency", "Payload transfer remains outside metadata export.")
        }
        guard let origin, try coordinator.receiptContextPermits(row, origin: origin, index: index, readBudget: chargeBootstrapProof) else {
            return nil
        }
        return data
    }
    /// Reference extraction only. All semantics remain owned by existing verified record/reducers.
    private func supplemental(_ slot: Slot, bytes: Data) throws -> ([Reference], String?, Bool) {
        var refs: [Reference] = []
        let origin = slot.kind == .item
            ? try AuthorityRevision(originalBytes: bytes).revision.provenance?.originReplicaID
            : try AuthorityRecordCodec.decode(bytes).record.originReplicaID
        if let origin, let decision = try coordinator.originDecision(origin, readBudget: chargeBootstrapProof) {
            refs.append(.init(id: decision.approval.id, kind: .authority, digest: decision.approval.sha256))
        }
        func id(_ value: String, _ kind: PeerPackage.Kind? = nil, _ digest: String? = nil) {
            refs.append(.init(id: value, kind: kind, digest: digest))
        }
        func control(_ value: ItemValue) throws {
            let binding = try AuthorityBinding(value: value)
            id(binding.recordID, .authority, binding.sha256)
        }
        func target(_ value: ItemValue) throws {
            let binding = try AuthorityRecord.binding(value)
            id(binding.revisionID, .item, binding.sha256)
        }
        var unsupported: String?
        var requiresEvidence = false
        if slot.descriptor?.kind == .item {
            let node = try AuthorityRevision(originalBytes: bytes)
            for parent in node.parents { id(parent, .item) }
            if let p = try node.revision.provenance {
                for author in p.frontier { id(author, .item) }
                if let witness = p.authorityWitness { id(witness.recordID, .authority, witness.sha256) }
                requiresEvidence = p.kind != .automaticMerge
                if requiresEvidence, try initialPin(node) != nil { requiresEvidence = false }
            }
            if let evidence = try index.authorityEvidence(revisionID: slot.id) {
                id(evidence.descriptor.id, .authority, evidence.descriptor.sha256)
                requiresEvidence = false
            }
            for descriptor in try AttachmentDescriptor.descriptors(in: node.revision.fields) {
                guard let receiptID = slot.receipt else {
                    throw TractandaError(
                        "missingDependencies",
                        "Original reference has no configured canonical witness receipt.")
                }
                refs.append(
                    .init(
                        id: descriptor.attachmentID, kind: .attachment, digest: descriptor.sha256,
                        original: .init(
                            descriptor: descriptor, revisionID: node.revision.revisionID,
                            revisionSHA256: node.sha256, receiptID: receiptID)))
            }
            for text in try AttachmentTextRepresentation.representations(in: node.revision.fields) {
                try AttachmentTextDecoder.validate(text)
                id(text.source.revisionID, .item)
            }
            for document in try AttachmentDocumentRepresentation.representations(in: node.revision.fields) {
                try AttachmentDocumentValidator.validate(document)
                id(document.source.revisionID, .item)
                if let content = document.content {
                    guard let receiptID = slot.receipt else {
                        throw TractandaError("invalidPeerExport", "Document witness receipt is absent.")
                    }
                    refs.append(
                        .init(
                            id: content.contentID, kind: .document, digest: content.manifestSHA256,
                            document: .init(
                                document: document, revisionID: node.revision.revisionID,
                                revisionSHA256: node.sha256, receiptID: receiptID)))
                }
            }
            if let pin = try index.peerInventoryLegacyPin(revisionID: slot.id, sha256: node.sha256) {
                id(pin.recordID, .authority, pin.sha256)
            }
        } else {
            let record = try AuthorityRecordCodec.decode(bytes).record
            for parent in record.parentAuthorityIDs { id(parent, .authority) }
            for field in [
                "controls", "localParent", "bootstrap", "pages", "children", "acceptedAuthority", "previous",
                "sourceControl", "causes", "exposures", "controlHolds", "retirements", "issuerAdmission",
            ] {
                for value in try AuthorityRecord.list(record.payload[field] ?? .list([])) {
                    try control(value)
                }
            }
            for field in ["cut", "evidence"] {
                if let value = record.payload[field] { try control(value) }
            }
            for field in [
                "itemPolicies", "admissionPolicies", "administrationPolicies", "revocations", "resolution",
            ] {
                for value in try AuthorityRecord.list(record.payload[field] ?? .list([])) {
                    try target(value)
                }
            }
            if let value = record.payload["target"] { try target(value) }
            for field in ["parents", "frontier", "holds", "decisionFrontier"] {
                for value in try AuthorityRecord.ids(record.payload[field] ?? .list([]), maximum: 1024) {
                    id(value, (field == "holds" || field == "decisionFrontier") ? .authority : .item)
                }
            }
            for entry in try AuthorityRecord.list(record.payload["entries"] ?? .list([])) {
                try target(entry.map!["target"]!)
                for author in try AuthorityRecord.ids(entry.map!["frontier"], maximum: 1024) {
                    id(author, .item)
                }
            }
            for delta in try AuthorityRecord.list(record.payload["deltas"] ?? .list([])) {
                try target(delta.map!["target"]!)
                for policy in try AuthorityRecord.ids(delta.map!["policies"]) { id(policy, .item) }
                for field in ["causes", "evidence"] {
                    for value in try AuthorityRecord.list(delta.map![field]) { try control(value) }
                }
            }
            for value in try AuthorityRecord.list(record.payload["members"] ?? .list([])) {
                let member = try PeerLifecycle.Member(value)
                id(member.objectID, member.kind, member.sha256)
            }
            if let manifest = record.payload["manifestID"]?.string { id(manifest, .authority) }
            if record.kind == .reconciliationWitness {
                // The witness names its output as well as its exact parents/exposures.
                id(try AuthorityRecord.persistentID(record.payload["outputRevisionID"]), .item)
            }
            if record.kind == .reviewHold {
                unsupported = "unsupportedForeignProtectedReviewHold"
            }
            if record.kind == .reviewDecision {
                let cuts = try AuthorityRecord.list(record.payload["sourceControl"])
                let resolutions = try AuthorityRecord.list(record.payload["resolution"])
                if record.payload["decision"] != .text("accept") || cuts.count != 1 || resolutions.count != 1
                {
                    unsupported = "unsupportedForeignNonAtomicReview"
                }
            }
            if record.kind == .originRetirementPage {
                unsupported = "unsupportedHistoricalRetirementAdmission"
            }
            if record.kind == .originRetirement,
                record.payload["retirementProfile"] != .text(PeerLifecycle.timestampProfile)
            {
                unsupported = "unsupportedHistoricalRetirementAdmission"
            }
        }
        // Duplicates retain all competing digest constraints; merged() rejects ambiguity.
        refs.sort {
            ($0.id, $0.kind?.rawValue ?? "", $0.digest ?? "") < (
                $1.id, $1.kind?.rawValue ?? "", $1.digest ?? ""
            )
        }
        return (refs, unsupported, requiresEvidence)
    }
    private func validateOriginalWitness(_ binding: OriginalBinding) throws {
        guard
            let row = try index.authorityReceipt(objectID: binding.revisionID, packageID: binding.receiptID),
            row.descriptor.kind == .item, row.descriptor.sha256 == binding.revisionSHA256,
            let bytes = try verified(row)
        else {
            throw TractandaError(
                "untrustedPeer", "Original witness is no longer available under current origin proof.")
        }
        let node = try AuthorityRevision(originalBytes: bytes)
        guard try AttachmentDescriptor.descriptors(in: node.revision.fields).contains(binding.descriptor)
        else {
            throw TractandaError("peerObjectCollision", "Canonical original descriptor witness differs.")
        }
    }
    private func validateDocumentWitness(_ binding: DocumentBinding) throws {
        guard
            let row = try index.authorityReceipt(objectID: binding.revisionID, packageID: binding.receiptID),
            row.descriptor.kind == .item, row.descriptor.sha256 == binding.revisionSHA256,
            let bytes = try verified(row)
        else {
            throw TractandaError(
                "untrustedPeer", "Document witness is unavailable under current origin proof.")
        }
        let node = try AuthorityRevision(originalBytes: bytes)
        guard
            try AttachmentDocumentRepresentation.representations(in: node.revision.fields).contains(
                binding.document)
        else {
            throw TractandaError("peerObjectCollision", "Canonical document witness differs.")
        }
    }
    private func closureUnit(_ handle: Handle, begin: Begin, old: State, initial: Slot) throws -> State {
        var slot = initial
        var changed: [String: Slot] = [:]
        var next = old
        if slot.status == .missing {
            next.retryAfter = slot.id
            slot.status = .pending
            slot.reason = nil
        }
        if slot.kind == .document {
            guard let binding = slot.document, let reference = binding.document.content,
                let verification = coordinator.documentVerification
            else {
                throw TractandaError("missingDependencies", "Document export lacks its canonical witness.")
            }
            try validateDocumentWitness(binding)
            let budget = PeerOriginalReadBudget(
                bytes: window.maximumReadBytes - min(readBytes, window.maximumReadBytes),
                maximumSteps: max(32, window.maximumUnits * (window.maximumEdges + 2)),
                workingCapacity: window.maximumReadBytes)
            defer { readBytes += budget.used }
            let object = try verification.contents.peerManifestDescriptor(reference)
            guard slot.id == object.id, slot.expectedDigest == nil || slot.expectedDigest == object.sha256
            else {
                throw TractandaError("peerObjectCollision", "Document export identity differs.")
            }
            try coordinator.requireStorageIdentity(object, index: index)
            slot.descriptor = object
            if try verification.step(
                scope: PeerDocumentVerification.canonicalScope(object.id),
                document: binding.document, source: .canonical, index: index, budget: budget,
                maximumUnits: window.maximumEdges)
            {
                slot.status = .verified
                slot.reason = nil
                return try commit(handle, begin: begin, old: old, next: next, slots: [slot])
            }
            // Only disposable SQL traversal advanced. Do not grow an immutable export event
            // per document work window, which would turn the plan quota into a page-count cap.
            return old
        }
        if slot.kind == .attachment {
            guard let original = slot.original, let originals = coordinator.journal.originals else {
                throw TractandaError(
                    "missingDependencies", "Original export lacks its canonical source binding.")
            }
            try validateOriginalWitness(original)
            let object = PeerPackage.Object(
                kind: .attachment, id: original.descriptor.attachmentID,
                length: Int(original.descriptor.byteCount), sha256: original.descriptor.sha256)
            try object.validate()
            guard slot.id == object.id, slot.expectedDigest == nil || slot.expectedDigest == object.sha256
            else { throw TractandaError("peerObjectCollision", "Original export identity differs.") }
            slot.descriptor = object
            let budget = PeerOriginalReadBudget(
                bytes: window.maximumReadBytes - min(readBytes, window.maximumReadBytes),
                maximumSteps: window.maximumUnits * (window.maximumEdges + 2))
            defer { readBytes += budget.used }
            if try originals.known(object, progress: check, budget: budget) {
                slot.status = .verified
                slot.reason = nil
            } else {
                slot.status = .missing
                slot.reason = "missingOriginalPayload"
                next.retryAfter = slot.id
            }
            return try commit(handle, begin: begin, old: old, next: next, slots: [slot])
        }
        let row: AuthorityStore.RetainedObject?
        if let receipt = slot.receipt {
            row = try index.authorityReceipt(objectID: slot.id, packageID: receipt)
        } else {
            row = try index.authorityObjectReceiptPage(
                objectID: slot.id, afterPackageID: slot.after.isEmpty ? nil : slot.after, limit: 1
            ).first
        }
        guard let row else {
            slot.status = .missing
            slot.reason = "missingOriginalOrConfiguredReceipt"
            slot.after = ""
            return try commit(handle, begin: begin, old: old, next: next, slots: [slot])
        }
        guard slot.kind == nil || row.descriptor.kind == slot.kind,
            slot.expectedDigest == nil || row.descriptor.sha256 == slot.expectedDigest,
            slot.descriptor == nil || slot.descriptor == row.descriptor
        else {
            throw TractandaError(
                "peerObjectCollision", "Exact export original differs from selected/reference descriptor.")
        }
        guard let bytes = try verified(row) else {
            slot.receipt = nil
            slot.after = row.packageID
            slot.reason = "unavailableConfiguredOriginProof"
            return try commit(handle, begin: begin, old: old, next: next, slots: [slot])
        }
        slot.descriptor = row.descriptor
        slot.kind = row.descriptor.kind
        slot.expectedDigest = row.descriptor.sha256
        if slot.receipt == nil { slot.after = "" }
        slot.receipt = row.packageID
        let (refs, unsupported, requiresEvidence) = try supplemental(slot, bytes: bytes)
        slot.unsupportedReason = unsupported
        var dependencies: [Reference] = []
        switch slot.phase {
        case 0:
            dependencies = try index.peerExportDependencies(
                slot.id, after: slot.after, limit: window.maximumEdges)
            if let last = dependencies.last { slot.after = last.cursor }
            if dependencies.count < window.maximumEdges {
                slot.phase = 1
                slot.after = ""
            }
        case 1:
            guard slot.offset <= refs.count else {
                throw TractandaError("invalidPeerExport", "Immutable dependency continuation changed.")
            }
            dependencies = Array(refs.dropFirst(slot.offset).prefix(window.maximumEdges))
            slot.offset += dependencies.count
            if slot.offset == refs.count {
                slot.phase = 2
                slot.after = ""
            }
        case 2:
            if let selected = try index.authorityEvidence(revisionID: slot.id) {
                dependencies = [
                    .init(id: selected.descriptor.id, kind: .authority, digest: selected.descriptor.sha256)
                ]
                slot.phase = 3
                slot.after = ""
            } else if requiresEvidence {
                let rows = try index.authorityEvidenceCandidates(
                    revisionID: slot.id, after: slot.after.isEmpty ? nil : slot.after,
                    limit: window.maximumEdges)
                dependencies = rows.map {
                    .init(id: $0.descriptor.id, kind: .authority, digest: $0.descriptor.sha256)
                }
                if let last = rows.last { slot.after = last.descriptor.id }
                if rows.isEmpty && slot.after.isEmpty {
                    slot.status = .missing
                    slot.reason = "missingAuthoredEvidence"
                } else if rows.count < window.maximumEdges {
                    slot.phase = 3
                    slot.after = ""
                }
            } else {
                slot.phase = 3
                slot.after = ""
            }
        case 3:
            dependencies = try index.peerExportWitnesses(
                slot.id, boundary: begin.boundary, after: slot.after, limit: window.maximumEdges)
            if let last = dependencies.last { slot.after = last.cursor }
            if dependencies.count < window.maximumEdges {
                slot.phase = 4
                slot.after = ""
            }
        default:
            slot.status = slot.unsupportedReason == nil ? .verified : .unsupported
            slot.reason = slot.unsupportedReason
        }
        for ref in dependencies {
            try check()
            _ = try merged(ref, plan: handle.planID, changed: &changed)
        }
        // Self/cyclic dependencies may tighten this slot's descriptor constraints too.
        if let selfReference = changed[slot.id] {
            guard selfReference.kind == nil || selfReference.kind == slot.kind,
                selfReference.expectedDigest == nil || selfReference.expectedDigest == slot.expectedDigest
            else { throw TractandaError("peerObjectCollision", "Self/cyclic reference descriptor differs.") }
        }
        changed[slot.id] = slot
        try checkCount(changed, begin: begin)
        return try commit(
            handle, begin: begin, old: old, next: next, slots: changed.values.sorted { $0.id < $1.id })
    }
    private func page(
        _ objects: [PeerPackage.Object], children: Bool, level: Int, ordinal: Int,
        handle: Handle
    ) throws -> IndexPage {
        let page = PeerPackage.Page(objects: children ? [] : objects, children: children ? objects : [])
        try page.validate()
        let bytes = try JSON.encode(page)
        let id = try UUID.makeVersion1().uuidString.lowercased()
        guard id != handle.planID, id != handle.packageID,
            try index.retainedAuthorityObject(id: id) == nil,
            try index.peerExportSlot(handle.planID, id: id) == nil,
            try files.readIfPresent(
                path: path(handle.planID, ["descriptors", id + ".json"]),
                maximumBytes: PeerPackage.maximumPageBytes) == nil
        else { throw TractandaError("peerObjectCollision", "Reserved export page identity collides.") }
        let descriptor = PeerPackage.Object(
            kind: .index, id: id, length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes))
        try descriptor.validate()
        return .init(level: level, ordinal: ordinal, descriptor: descriptor, bytes: bytes)
    }
    func step(_ handle: Handle, window: Window) throws -> Status {
        bootstrapProof = .init()
        try window.validate()
        self.window = window
        readBytes = 0
        journalBytes = 0
        if try manifest(handle) != nil { return try status(handle) }
        var (begin, state) = try loaded(handle)
        guard state.phase != .selecting else {
            throw TractandaError(
                "peerExportSelectionOpen", "Close finite root selection before planning closure.")
        }
        for _ in 0..<window.maximumUnits {
            try check()
            if state.phase == .closure {
                var slot = try index.peerExportSlots(
                    handle.planID, status: ObjectState.pending.rawValue, limit: 1
                ).first
                if slot == nil {
                    slot = try index.peerExportSlots(
                        handle.planID, status: ObjectState.missing.rawValue, after: state.retryAfter, limit: 1
                    ).first
                    if slot == nil,
                        try index.peerExportCount(handle.planID, status: ObjectState.missing.rawValue) > 0
                    {
                        var next = state
                        next.retryAfter = ""
                        _ = try commit(handle, begin: begin, old: state, next: next)
                        return try status(handle)
                    }
                }
                if let slot {
                    state = try closureUnit(handle, begin: begin, old: state, initial: slot)
                    if slot.status == .missing { return try status(handle) }
                } else {
                    if try index.peerExportCount(handle.planID, status: ObjectState.unsupported.rawValue) > 0
                    {
                        return try status(handle)
                    }
                    var next = state
                    next.phase = .leaves
                    state = try commit(handle, begin: begin, old: state, next: next)
                }
            } else if state.phase == .leaves {
                let slots = try index.peerExportSlots(
                    handle.planID, after: state.leafAfter, limit: begin.limits.pageFanout)
                var next = state
                if slots.isEmpty {
                    next.phase = .indexes
                    next.level = 0
                    next.afterOrdinal = -1
                    next.nextOrdinal = 0
                    state = try commit(handle, begin: begin, old: state, next: next)
                } else {
                    guard slots.allSatisfy({ $0.status == .verified && $0.descriptor != nil }) else {
                        throw TractandaError(
                            "invalidPeerExport", "Unfinished dependency reached package construction.")
                    }
                    let page = try page(
                        slots.compactMap(\.descriptor), children: false, level: 0, ordinal: state.nextOrdinal,
                        handle: handle)
                    next.leafAfter = slots.last!.id
                    next.nextOrdinal += 1
                    state = try commit(handle, begin: begin, old: state, next: next, pages: [page])
                }
            } else if state.phase == .indexes {
                let first = try index.peerExportPages(handle.planID, level: state.level, after: -1, limit: 2)
                guard !first.isEmpty else {
                    throw TractandaError("invalidPeerExport", "Missing package hierarchy level.")
                }
                var next = state
                if first.count == 1 {
                    let manifest = PeerPackage.Manifest(
                        packageID: handle.packageID, storeID: context.storeID, root: first[0].1)
                    next.phase = .sealed
                    _ = try commit(handle, begin: begin, old: state, next: next, manifest: manifest)
                    return try status(handle)
                }
                let children = try index.peerExportPages(
                    handle.planID, level: state.level, after: state.afterOrdinal,
                    limit: begin.limits.pageFanout)
                if children.isEmpty {
                    next.level += 1
                    next.afterOrdinal = -1
                    next.nextOrdinal = 0
                    guard next.level < 64 else {
                        throw TractandaError(
                            "resourceLimit", "Package index depth exceeds supported framing.")
                    }
                    state = try commit(handle, begin: begin, old: state, next: next)
                } else {
                    let page = try page(
                        children.map(\.1), children: true, level: state.level + 1, ordinal: state.nextOrdinal,
                        handle: handle)
                    next.afterOrdinal = children.last!.0
                    next.nextOrdinal += 1
                    state = try commit(handle, begin: begin, old: state, next: next, pages: [page])
                }
            } else {
                return try status(handle)
            }
        }
        return try status(handle)
    }
    func read(
        _ handle: Handle, object: PeerPackage.Object, offset: Int, maximumBytes: Int,
        receiverKnown: PeerPackage.Object? = nil
    ) throws -> Chunk {
        bootstrapProof = .init()
        readBytes = 0
        _ = try validate(handle)
        guard try manifest(handle) != nil else {
            throw TractandaError("peerExportUnsealed", "Only a sealed immutable export can deliver bytes.")
        }
        try object.validate()
        guard offset >= 0,
            offset < object.length || (object.kind == .attachment && object.length == 0 && offset == 0),
            (1...PeerPackage.maximumChunkBytes).contains(maximumBytes)
        else {
            throw TractandaError("invalidPeerOffset", "Invalid selected export chunk window.")
        }
        let descriptor = try PeerPackage.decode(
            PeerPackage.Object.self,
            files.read(
                path: path(handle.planID, ["descriptors", object.id + ".json"]),
                maximumBytes: PeerPackage.maximumPageBytes,
                readBudget: object.kind == .document ? chargeDocumentMetadata : nil))
        if object.kind == .document {
            guard descriptor.kind == .document, descriptor.part == .manifest,
                let verification = coordinator.documentVerification,
                let originals = coordinator.journal.originals,
                let part = object.part
            else {
                throw TractandaError("peerObjectCollision", "Selected document manifest anchor differs.")
            }
            let binding = try PeerPackage.decode(
                DocumentBinding.self,
                files.read(
                    path: path(handle.planID, ["documents", object.id + ".json"]),
                    maximumBytes: PeerPackage.maximumPageBytes, readBudget: chargeDocumentMetadata))
            try validateDocumentWitness(binding)
            guard let reference = binding.document.content, reference.contentID == object.id,
                reference.manifestSHA256 == descriptor.sha256
            else {
                throw TractandaError("peerObjectCollision", "Document witness anchor differs.")
            }
            let budget = PeerOriginalReadBudget(
                bytes: window.maximumReadBytes - min(readBytes, window.maximumReadBytes),
                maximumSteps: max(32, window.maximumUnits * window.maximumEdges),
                workingCapacity: window.maximumReadBytes)
            defer { readBytes += budget.used }
            guard try verification.contents.peerExpectedPart(reference, part: part, budget: budget) == object
            else {
                throw TractandaError("peerObjectCollision", "Requested part differs from its sealed proof.")
            }
            let base = try verification.contents.directory(object.id)
            let file = try verification.contents.peerPartFile(base: base, object: object)
            let key = AuthorityRecordCodec.sha256(
                Data((PeerDocumentVerification.canonicalScope(object.id) + ":" + object.key).utf8))
            guard
                try originals.verifyDocumentPart(
                    file: file, key: key, object: object, proofPrefix: nil,
                    whole: true, budget: budget)
            else {
                throw TractandaError("missingDependencies", "Document part is unavailable.")
            }
            if let receiverKnown {
                guard receiverKnown == object else {
                    throw TractandaError("peerObjectCollision", "Receiver-known document part differs.")
                }
                return .init(descriptor: object, offset: offset, bytes: Data(), receiverKnown: true)
            }
            let count = min(maximumBytes, PeerPackage.maximumPayloadChunkBytes, object.length - offset)
            try budget.charge(count)
            return .init(
                descriptor: object, offset: offset,
                bytes: try file.read(offset: Int64(offset), count: count), receiverKnown: false)
        }
        guard descriptor == object else {
            throw TractandaError("peerObjectCollision", "Selected export descriptor differs.")
        }
        if object.kind == .attachment {
            let original = try PeerPackage.decode(
                OriginalBinding.self,
                files.read(
                    path: path(handle.planID, ["originals", object.id + ".json"]),
                    maximumBytes: PeerPackage.maximumPageBytes))
            try validateOriginalWitness(original)
            let budget = PeerOriginalReadBudget(
                bytes: window.maximumReadBytes - min(readBytes, window.maximumReadBytes),
                maximumSteps: window.maximumUnits * window.maximumEdges)
            defer { readBytes += budget.used }
            guard original.descriptor.attachmentID == object.id,
                original.descriptor.byteCount == Int64(object.length),
                original.descriptor.sha256 == object.sha256,
                let originals = coordinator.journal.originals,
                try originals.known(object, progress: check, budget: budget)
            else {
                throw TractandaError("missingDependencies", "Selected original is absent or unverified.")
            }
            if let receiverKnown {
                guard receiverKnown == object else {
                    throw TractandaError("peerObjectCollision", "Receiver-known original differs.")
                }
                return .init(descriptor: object, offset: offset, bytes: Data(), receiverKnown: true)
            }
            let bytes = try originals.read(
                descriptor: original.descriptor, offset: offset,
                maximumBytes: min(maximumBytes, PeerPackage.maximumPayloadChunkBytes), progress: check,
                budget: budget)
            return .init(descriptor: object, offset: offset, bytes: bytes, receiverKnown: false)
        }
        let bytes: Data
        if object.kind == .index {
            bytes = try files.read(
                path: path(handle.planID, ["pages", object.id + ".json"]),
                maximumBytes: PeerPackage.maximumPageBytes)
            try PeerPackage.decode(PeerPackage.Page.self, bytes).validate()
        } else {
            let receipt = try PeerPackage.decode(
                String.self,
                files.read(
                    path: path(handle.planID, ["receipts", object.id + ".json"]),
                    maximumBytes: PeerPackage.maximumPageBytes))
            guard let row = try index.authorityReceipt(objectID: object.id, packageID: receipt),
                row.descriptor == object
            else {
                throw TractandaError("peerObjectCollision", "Sealed export original is absent or differs.")
            }
            // Sealed reads after rebuild use exact canonical inventory, never a queue locator.
            guard let original = try verified(row) else {
                throw TractandaError("untrustedPeer", "Current origin proof no longer permits this original.")
            }
            bytes = original
        }
        guard bytes.count == object.length, AuthorityRecordCodec.sha256(bytes) == object.sha256 else {
            throw TractandaError("peerObjectCollision", "Selected export bytes differ.")
        }
        if let receiverKnown {
            guard receiverKnown == object else {
                throw TractandaError("peerObjectCollision", "Receiver-known descriptor differs.")
            }
            return .init(descriptor: object, offset: offset, bytes: Data(), receiverKnown: true)
        }
        return .init(
            descriptor: object, offset: offset,
            bytes: Data(bytes[offset..<offset + min(maximumBytes, object.length - offset)]),
            receiverKnown: false)
    }
}
