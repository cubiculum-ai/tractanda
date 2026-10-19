import Dispatch
import Foundation

/// Host-private authenticated identity. Never Codable, never supplied by a peer frame.
package struct PeerExchangeBinding: Equatable, Sendable {
    package let peerID: String
    package let storeID: String
    package let localReplicaID: String
    package let remoteReplicaID: String
    package let pairingID: String
    package let localIsInitiator: Bool
    package let configurationDigest: String

    package init(
        peerID: String, storeID: String, localReplicaID: String, remoteReplicaID: String,
        pairingID: String, localIsInitiator: Bool, configurationDigest: String
    ) throws {
        _ = try AuthorityRecord.text(.text(peerID))
        for id in [storeID, localReplicaID, remoteReplicaID, pairingID] {
            _ = try AuthorityRecord.persistentID(.text(id))
        }
        _ = try AuthorityRecord.digest(.text(configurationDigest))
        guard peerID != "local", localReplicaID != remoteReplicaID else {
            throw TractandaError("untrustedPeer", "Invalid local pairing identity.")
        }
        self.peerID = peerID
        self.storeID = storeID
        self.localReplicaID = localReplicaID
        self.remoteReplicaID = remoteReplicaID
        self.pairingID = pairingID
        self.localIsInitiator = localIsInitiator
        self.configurationDigest = configurationDigest
    }
}

/// Explicit cancellation crosses the GCD boundary; Task cancellation alone cannot do that.
package final class PeerExchangeControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: UInt64
    package init(maximumSeconds: Double = 30) throws {
        guard maximumSeconds.isFinite, maximumSeconds > 0, maximumSeconds <= 60 else {
            throw TractandaError("resourceLimit", "Invalid peer operation deadline.")
        }
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(maximumSeconds * 1_000_000_000)
    }
    package func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    package func check() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        guard !stopped else { throw TractandaError("cancelled", "Peer operation cancelled.") }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw TractandaError("deadlineExceeded", "Peer operation deadline exceeded.")
        }
    }
}

/// The only wire request schema in Core. No Context, UID, origin set or trusted cursor exists here.
package struct PeerExchangeRequest: Codable, Sendable {
    package let operation: String
    package let fields: [String: ItemValue]
    package init(_ operation: String, _ fields: [String: ItemValue] = [:]) {
        self.operation = operation
        self.fields = fields
    }
}

/// One connection's bounded continuation slots. Values cross the owner queue, never ItemStore.
struct PeerExchangeState: Sendable {
    let binding: PeerExchangeBinding
    let securityBinding: String
    var logicalOwner: String? = nil
    var compatibility = PeerExchangeCompatibility()
    var boundary: PeerInventory.Boundary?
    var inventoryCursor: PeerInventory.Cursor?
    var checkpoint: PeerInventory.CompletionCheckpoint?
    var entries: [PeerInventory.Entry] = []
    var inventoryComplete = false
    var export: PeerExportPlan.Handle?
    var resumePackage: String?
    var resumeCursor: PeerPackage.ResumeCursor?
    var resumeComplete = false

    func retainedByteCount() throws -> Int {
        try JSON.encode(entries.map { Self.descriptor($0.descriptor) }).count
            + (resumeCursor?.retainedByteCount() ?? 0) + (try compatibility.retainedByteCount()) + 8192
    }
    private func exact(_ fields: [String: ItemValue], _ keys: Set<String>) throws {
        guard Set(fields.keys) == keys else {
            throw TractandaError("invalidPeerRequest", "Unexpected peer request fields.")
        }
    }
    private func id(_ value: ItemValue?) throws -> String { try AuthorityRecord.persistentID(value) }
    private func integer(_ value: ItemValue?, maximum: Int) throws -> Int {
        guard case .integer(let number) = value, number >= 0, number <= Int64(maximum) else {
            throw TractandaError("resourceLimit", "Peer integer exceeds its operation bound.")
        }
        return Int(number)
    }
    private func bytes(_ value: ItemValue?, maximum: Int) throws -> Data {
        guard case .bytes(let bytes) = value, bytes.count <= maximum else {
            throw TractandaError("resourceLimit", "Peer byte window exceeded.")
        }
        return bytes
    }
    private func descriptor(_ value: ItemValue?) throws -> PeerPackage.Object {
        try Self.decodeDescriptor(value)
    }
    static func decodeDescriptor(_ value: ItemValue?) throws -> PeerPackage.Object {
        guard let value else { throw TractandaError("invalidPeerRequest", "Missing descriptor.") }
        guard let shape = value.map else {
            throw TractandaError("invalidPeerRequest", "Descriptor must be an object.")
        }
        let fields = try AuthorityRecord.object(
            value,
            keys: shape["part"] == nil
                ? ["kind", "id", "length", "sha256"] : ["kind", "id", "length", "sha256", "part"])
        guard let kind = PeerPackage.Kind(rawValue: try AuthorityRecord.text(fields["kind"])) else {
            throw TractandaError("invalidPeerRequest", "Unknown object kind.")
        }
        guard let length = fields["length"]?.integerValue, length >= 0,
            let encodedLength = Int(exactly: length)
        else {
            throw TractandaError("resourceLimit", "Invalid descriptor length.")
        }
        var part: PeerPackage.DocumentPart?
        if let value = fields["part"] {
            let fields = try AuthorityRecord.object(value, keys: ["role", "level", "ordinal"])
            guard
                let role = PeerPackage.DocumentPart.Role(rawValue: try AuthorityRecord.text(fields["role"])),
                let level = fields["level"]?.integerValue, let encodedLevel = Int(exactly: level),
                let ordinal = fields["ordinal"]?.integerValue
            else {
                throw TractandaError("invalidPeerRequest", "Invalid composite document address.")
            }
            part = .init(role: role, level: encodedLevel, ordinal: ordinal)
        }
        let object = PeerPackage.Object(
            kind: kind, id: try AuthorityRecord.persistentID(fields["id"]), length: encodedLength,
            sha256: try AuthorityRecord.digest(fields["sha256"]), part: part)
        try object.validate()
        return object
    }
    static func descriptor(_ object: PeerPackage.Object) -> ItemValue {
        var fields: [String: ItemValue] = [
            "kind": .text(object.kind.rawValue), "id": .text(object.id),
            "length": .integer(Int64(object.length)), "sha256": .text(object.sha256),
        ]
        if let part = object.part {
            fields["part"] = .object([
                "role": .text(part.role.rawValue), "level": .integer(Int64(part.level)),
                "ordinal": .integer(part.ordinal),
            ])
        }
        return .object(fields)
    }
    private func intake(_ state: PeerPackage.IntakeState) -> [String: ItemValue] {
        [
            "packageID": .text(state.packageID), "manifestDigest": .text(state.manifestDigest),
            "phase": .text(state.phase.rawValue), "recoveryRequired": .boolean(state.recoveryRequired),
        ]
    }
    private func exportStatus(_ status: PeerExportPlan.Status) throws -> [String: ItemValue] {
        var value: [String: ItemValue] = [
            "phase": .text(status.phase.rawValue), "objects": .integer(Int64(status.objects)),
            "pending": .integer(Int64(status.pending)), "missing": .integer(Int64(status.missing)),
            "unsupported": .integer(Int64(status.unsupported)),
            "chargedBytes": .integer(Int64(status.chargedBytes)),
        ]
        if let manifest = status.manifest { value["manifest"] = .bytes(try JSON.encode(manifest)) }
        return value
    }
    private mutating func inventoryPage(_ store: ItemStore, _ context: PeerPackage.Context, limit: Int) throws
        -> [String: ItemValue]
    {
        guard let boundary, !inventoryComplete else {
            throw TractandaError("invalidPeerCursor", "No active finite inventory continuation.")
        }
        let page = try store.peerInventoryPage(context: context, boundary: boundary, cursor: inventoryCursor, limit: limit)
        entries = page.entries
        inventoryCursor = page.nextCursor
        checkpoint = page.completionCheckpoint
        inventoryComplete = page.nextCursor == nil
        return [
            "entries": .list(
                page.entries.map { entry in
                    var fields: [String: ItemValue] = [
                        "descriptor": Self.descriptor(entry.descriptor), "proof": .text(entry.proof.rawValue),
                    ]
                    if let disposition = entry.disposition {
                        fields["disposition"] = .text(disposition.rawValue)
                    }
                    return .object(fields)
                }),
            "complete": .boolean(inventoryComplete), "scannedCount": .integer(Int64(page.scannedCount)),
        ]
    }
    private mutating func resumePage(
        _ store: ItemStore, _ context: PeerPackage.Context, _ packageID: String, limit: Int
    ) throws -> [String: ItemValue] {
        let page = try store.resumePeerIntake(context: context, packageID: packageID, cursor: resumeCursor, limit: limit)
        resumePackage = packageID
        resumeCursor = page.nextCursor
        resumeComplete = page.nextCursor == nil
        var fields = intake(page.state)
        fields["complete"] = .boolean(resumeComplete)
        fields["blockedOnIndex"] = .boolean(page.blockedOnIndex)
        fields["objects"] = .list(
            page.objects.map { object in
                var item: [String: ItemValue] = [
                    "descriptor": Self.descriptor(object.descriptor),
                    "nextOffset": .integer(Int64(object.nextOffset)),
                    "source": .text(object.source.rawValue),
                    "verifiedComplete": .boolean(object.verifiedComplete),
                ]
                if let evaluation = object.evaluation {
                    item["disposition"] = .text(evaluation.disposition.rawValue)
                    item["reason"] = .text(evaluation.reason)
                }
                return .object(item)
            })
        return fields
    }
    mutating func perform(
        _ data: Data, store: ItemStore, context: PeerPackage.Context, control: PeerExchangeControl, scanLimit: Int = 128
    ) throws -> Data {
        try control.check()
        try compatibility.requireAdmission(store: store, storeID: binding.storeID)
        let request = try PeerPackage.decode(PeerExchangeRequest.self, data, maximum: 2 * 1024 * 1024)
        let fields = request.fields
        let output: [String: ItemValue]
        switch request.operation {
        case "inventory":
            try exact(fields, [])
            boundary = try store.capturePeerInventory(context: context)
            inventoryCursor = nil
            checkpoint = nil
            inventoryComplete = false
            output = try inventoryPage(store, context, limit: scanLimit)
        case "inventoryNext":
            try exact(fields, [])
            output = try inventoryPage(store, context, limit: scanLimit)
        case "inventoryChanges":
            try exact(fields, [])
            guard let checkpoint, inventoryComplete else {
                throw TractandaError("invalidPeerCursor", "Inventory enumeration is incomplete.")
            }
            boundary = try store.capturePeerInventory(context: context, after: checkpoint)
            inventoryCursor = nil
            inventoryComplete = false
            output = try inventoryPage(store, context, limit: scanLimit)
        case "needsTransfer":
            try exact(fields, ["descriptors", "after"])
            let objects = try AuthorityRecord.list(fields["descriptors"]).map(Self.decodeDescriptor)
            let results = try store.peerNeedsTransfer(context: context, objects: objects,
                after: integer(fields["after"], maximum: 128), progress: control.check)
            output = ["nextOffset": .integer(Int64(results.nextOffset)), "complete": .boolean(results.complete),
                "objects": .list(results.objects.map { result in
                var fields: [String: ItemValue] = ["descriptor": Self.descriptor(result.descriptor),
                    "state": .text(result.state.rawValue)]
                if let disposition = result.disposition { fields["disposition"] = .text(disposition.rawValue) }
                return .object(fields)
            })]
        case "exportBegin":
            try exact(fields, ["planID", "packageID"])
            guard let boundary else { throw TractandaError("invalidPeerCursor", "Capture inventory first.") }
            export = try store.beginPeerExport(
                context: context, planID: id(fields["planID"]), packageID: id(fields["packageID"]),
                boundary: boundary)
            output = try exportStatus(store.inspectPeerExport(context: context, handle: export!))
        case "pendingIntakes":
            try exact(fields, ["afterID"])
            guard case .text(let after) = fields["afterID"],
                after.isEmpty || (try? id(.text(after))) != nil else {
                throw TractandaError("invalidPeerCursor", "Invalid pending receipt continuation.")
            }
            let page = try store.peerPendingIntakes(context: context, after: after.isEmpty ? nil : after)
            output = ["packages": .list(page.packages.map(ItemValue.text)),
                "afterID": .text(page.after ?? ""), "complete": .boolean(page.complete)]
        case "syncEpoch":
            try exact(fields, [])
            output = ["epoch": .text(try store.peerSyncEpoch()), "security": .text(securityBinding)]
        case "exportExists":
            try exact(fields, ["planID", "packageID"])
            output = ["exists": .boolean(try store.peerExportExists(context: context,
                planID: id(fields["planID"]), packageID: id(fields["packageID"])))]
        case "exportReopen":
            try exact(fields, ["planID", "packageID"])
            export = try store.reopenPeerExport(
                context: context, planID: id(fields["planID"]), packageID: id(fields["packageID"]))
            output = try exportStatus(store.inspectPeerExport(context: context, handle: export!))
        case "exportSelect":
            try exact(fields, ["ids", "finish"])
            guard let export, case .boolean(let finish) = fields["finish"] else {
                throw TractandaError("invalidPeerRequest", "No export selection or finish flag.")
            }
            let ids = try AuthorityRecord.list(fields["ids"]).map(id)
            guard ids.count <= 128, Set(ids).count == ids.count else {
                throw TractandaError("resourceLimit", "Selection exceeds one inventory page.")
            }
            let selected = try ids.map { id -> PeerInventory.Entry in
                guard let entry = entries.first(where: { $0.descriptor.id == id }) else {
                    throw TractandaError("invalidPeerCursor", "Select exact current inventory entries.")
                }
                return entry
            }
            output = try exportStatus(
                store.selectPeerExport(context: context, handle: export, entries: selected, finish: finish))
        case "exportStep", "exportStatus", "exportManifest":
            try exact(fields, [])
            guard let export else { throw TractandaError("invalidPeerCursor", "No export handle.") }
            if request.operation == "exportStep" {
                output = try exportStatus(
                    store.stepPeerExport(context: context, handle: export, progress: control.check))
            } else {
                output = try exportStatus(store.inspectPeerExport(context: context, handle: export))
            }
        case "exportObjects":
            try exact(fields, ["afterID"])
            guard let export, case .text(let after) = fields["afterID"],
                after.isEmpty || (try? id(.text(after))) != nil
            else {
                throw TractandaError("invalidPeerCursor", "No export handle or invalid object cursor.")
            }
            let page = try store.peerExportObjectPage(context: context, handle: export, afterID: after)
            var result: [String: ItemValue] = [
                "objects": .list(
                    page.objects.map { slot in
                        var fields: [String: ItemValue] = [
                            "id": .text(slot.id), "state": .text(slot.status.rawValue),
                        ]
                        if let descriptor = slot.descriptor {
                            fields["descriptor"] = Self.descriptor(descriptor)
                        }
                        if let reason = slot.reason { fields["reason"] = .text(reason) }
                        return .object(fields)
                    }), "complete": .boolean(page.nextAfterID == nil),
            ]
            if let next = page.nextAfterID { result["afterID"] = .text(next) }
            output = result
        case "exportRead":
            guard
                Set(fields.keys) == ["descriptor", "offset"]
                    || Set(fields.keys) == ["descriptor", "offset", "known"]
            else {
                throw TractandaError("invalidPeerRequest", "Unexpected chunk fields.")
            }
            guard let export else { throw TractandaError("invalidPeerCursor", "No export handle.") }
            let chunk = try store.readPeerExport(
                context: context, handle: export, object: descriptor(fields["descriptor"]),
                offset: integer(fields["offset"], maximum: Int.max),
                receiverKnown: fields["known"].map { try descriptor($0) })
            output = [
                "descriptor": Self.descriptor(chunk.descriptor), "offset": .integer(Int64(chunk.offset)),
                "bytes": .bytes(chunk.bytes), "receiverKnown": .boolean(chunk.receiverKnown),
            ]
        case "begin":
            try exact(fields, ["manifest"])
            let status = try store.beginPeerIntake(
                context: context,
                manifestBytes: bytes(fields["manifest"], maximum: PeerPackage.maximumPageBytes))
            output = [
                "packageID": .text(status.packageID), "sealed": .boolean(status.sealed),
                "receivedBytes": .integer(Int64(status.receivedBytes)),
            ]
        case "append":
            try exact(fields, ["packageID", "descriptor", "offset", "bytes"])
            let status = try store.appendPeerObject(
                context: context, packageID: id(fields["packageID"]),
                object: descriptor(fields["descriptor"]),
                offset: integer(fields["offset"], maximum: Int.max),
                bytes: bytes(fields["bytes"], maximum: PeerPackage.maximumChunkBytes))
            output = [
                "packageID": .text(status.packageID), "sealed": .boolean(status.sealed),
                "receivedBytes": .integer(Int64(status.receivedBytes)),
            ]
        case "status":
            try exact(fields, ["packageID"])
            output = intake(try store.inspectPeerIntake(context: context, packageID: id(fields["packageID"])))
        case "resume":
            try exact(fields, ["packageID"])
            resumeCursor = nil
            resumeComplete = false
            output = try resumePage(store, context, id(fields["packageID"]), limit: scanLimit)
        case "resumeNext":
            try exact(fields, [])
            guard let resumePackage, !resumeComplete else {
                throw TractandaError("invalidPeerCursor", "No resume continuation.")
            }
            output = try resumePage(store, context, resumePackage, limit: scanLimit)
        case "commit":
            try exact(fields, ["packageID"])
            // Current policy/Context was checked above on this same serial owner. Ordinary
            // writes may advance general Store generation while an immutable transfer runs.
            let result = try store.commitPeerIntake(
                context: context, packageID: id(fields["packageID"]),
                expectedContextToken: store.peerIntakeContextToken())
            output = [
                "packageID": .text(result.packageID), "stored": .integer(Int64(result.stored)),
                "accepted": .integer(Int64(result.accepted)), "held": .integer(Int64(result.held)),
                "missing": .integer(Int64(result.missing)), "rejected": .integer(Int64(result.rejected)),
            ]
        default:
            throw TractandaError("invalidPeerRequest", "Unknown peer operation.")
        }
        try control.check(); try compatibility.requireLifetime()
        let response = try JSON.encode(output)
        guard
            response.count
                <= (request.operation == "exportRead" ? 2 * 1024 * 1024 : PeerPackage.maximumPageBytes)
        else {
            throw TractandaError("resourceLimit", "Peer response exceeds its bounded page.")
        }
        return response
    }
}

/// Revocable physical-session lifetime only; no lock is held over Store work or an await.
package final class PeerCompatibilityLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    package init() {}
    package func cancel() { lock.lock(); active = false; lock.unlock() }
    package func check() throws {
        lock.lock(); let valid = active; lock.unlock()
        guard valid else { throw PeerExchangeCompatibility.invalid() }
    }
}
/// Core-minted host-private proof. No public initializer, raw setter or Codable conformance.
package struct PeerCompatibilityAdmission: Sendable {
    let binding: PeerExchangeBinding
    let compatibility: PeerExchangeCompatibility
    package func requireBinding(_ expected: PeerExchangeBinding) throws {
        guard binding == expected else { throw PeerExchangeCompatibility.invalid() }
        try checkLifetime()
    }
    package func checkLifetime() throws {
        guard let lifetime = compatibility.lifetime else { throw PeerExchangeCompatibility.invalid() }
        try lifetime.check()
    }
}

/// A physical connection's compatibility claims. They confer no item or administrator authority.
struct PeerExchangeCompatibility: Sendable {
    var local: PeerCompatibilityDeclaration?
    var remote: PeerCompatibilityDeclaration?
    var acknowledged = false
    var lifetime: PeerCompatibilityLifetime?
    func requireLifetime() throws { try lifetime?.check() }
    static func current(store: ItemStore, storeID: String) throws -> PeerCompatibilityDeclaration {
        guard let requirement = try CanonicalReaderRequirement.load(root: store.root, ownerUID: store.ownerUID),
            requirement.storeID == storeID else { throw invalid() }
        try CanonicalFormatSupport.current.require(requirement)
        return try .init(support: .current, requirement: requirement)
    }
    static func invalid() -> TractandaError {
        TractandaError("peerCompatibilityRequired", "Current mutual peer compatibility admission is required.")
    }
    mutating func advance(_ action: PeerCompatibilityAction, store: ItemStore, storeID: String) throws -> Data {
        let current = try Self.current(store: store, storeID: storeID)
        switch action {
        case .declare:
            guard local == nil, remote == nil, !acknowledged else { throw Self.invalid() }
            local = current
            return try current.encoded()
        case .accept(let bytes):
            guard let local, remote == nil, !acknowledged, local == current else { throw Self.invalid() }
            let declaration = try PeerCompatibilityDeclaration.decode(bytes)
            try current.requireCompatible(with: declaration)
            remote = declaration
            return try PeerCompatibilityAcknowledgement(declaration: declaration).encoded()
        case .acknowledge(let bytes):
            guard let local, let remote, !acknowledged, local == current else { throw Self.invalid() }
            try PeerCompatibilityAcknowledgement.decode(bytes).matches(declaration: local)
            try current.requireCompatible(with: remote)
            acknowledged = true
            return Data()
        }
    }
    func requireAdmission(store: ItemStore, storeID: String) throws {
        guard local != nil, let remote, acknowledged else { throw Self.invalid() }
        try requireLifetime()
        try Self.current(store: store, storeID: storeID).requireCompatible(with: remote)
        try requireLifetime()
    }
    func retainedByteCount() throws -> Int {
        try (local?.encoded().count ?? 0) + (remote?.encoded().count ?? 0)
    }
}
package enum PeerCompatibilityAction: Sendable { case declare, accept(Data), acknowledge(Data) }

struct PeerExchangeStep: Sendable {
    let state: PeerExchangeState
    let response: Data
}

/// Package-only authenticated metadata adapter. One active operation and bounded local slots.
package actor PeerExchangeGateway {
    private let coordinator: ServiceCoordinator
    private var state: PeerExchangeState
    private var busy = false
    private let logicalLease: PeerLogicalExchange.Lease?
    package init(
        coordinator: ServiceCoordinator, binding: PeerExchangeBinding,
        control suppliedControl: PeerExchangeControl? = nil, logicalLease: PeerLogicalExchange.Lease? = nil
    ) async throws {
        self.coordinator = coordinator
        self.logicalLease = logicalLease
        let control = try suppliedControl ?? PeerExchangeControl()
        state = try await withTaskCancellationHandler {
            try await coordinator.openPeerExchange(binding, control: control)
        } onCancel: {
            control.cancel()
        }
    }
    package func compatibilityAdmission(lifetime: PeerCompatibilityLifetime,
        control: PeerExchangeControl) async throws -> PeerCompatibilityAdmission {
        if let logicalLease { return try await logicalLease.compatibilityAdmission(lifetime: lifetime, control: control) }
        guard !busy, state.compatibility.lifetime == nil else { throw PeerExchangeCompatibility.invalid() }
        busy = true; defer { busy = false }
        return try await withTaskCancellationHandler {
            try control.check(); try lifetime.check()
            var next = state; next.compatibility.lifetime = lifetime
            try await coordinator.authorizePeerExchange(next, control: control)
            try control.check(); try lifetime.check()
            state = next
            return PeerCompatibilityAdmission(binding: state.binding, compatibility: state.compatibility)
        } onCancel: { control.cancel() }
    }
    package func advanceCompatibility(_ action: PeerCompatibilityAction, control: PeerExchangeControl) async throws -> Data {
        if let logicalLease { return try await logicalLease.advanceCompatibility(action, control: control) }
        guard !busy else { throw TractandaError("serviceBusy", "One peer operation is already active.") }
        busy = true; defer { busy = false }
        return try await withTaskCancellationHandler {
            let step = try await coordinator.advancePeerCompatibility(action, state: state, control: control)
            state = step.state
            return step.response
        } onCancel: { control.cancel() }
    }
    package func execute(_ request: Data, control: PeerExchangeControl) async throws -> Data {
        if let logicalLease { return try await logicalLease.execute(request, control: control) }
        guard !busy else { throw TractandaError("serviceBusy", "One peer operation is already active.") }
        busy = true
        defer { busy = false }
        return try await withTaskCancellationHandler {
            let step = try await coordinator.performPeerExchange(request, state: state, control: control)
            try state.compatibility.requireLifetime(); try control.check()
            state = step.state
            return step.response
        } onCancel: {
            control.cancel()
        }
    }
    /// Host-only pending-work access. Peers cannot write this through a request operation.
    package func syncWork(_ replacement: PeerSyncWork? = nil, control: PeerExchangeControl) async throws -> PeerSyncWork {
        if let logicalLease { return try await logicalLease.syncWork(replacement, control: control) }
        guard !busy else { throw TractandaError("serviceBusy", "One peer operation is already active.") }
        busy = true; defer { busy = false }
        return try await withTaskCancellationHandler {
            try await coordinator.peerSyncWork(state: state, replacement: replacement, control: control)
        } onCancel: { control.cancel() }
    }
    /// Authorize a transport boundary on the same owner as canonical retirement activation.
    /// An authorized bounded frame may already be queued when a later removal is learned.
    package func detachLogicalLease() async { await logicalLease?.detach() }
    package func authorize(control: PeerExchangeControl) async throws {
        if let logicalLease { return try await logicalLease.authorize(control: control) }
        try await withTaskCancellationHandler {
            try await coordinator.authorizePeerExchange(state, control: control)
        } onCancel: {
            control.cancel()
        }
    }
}
