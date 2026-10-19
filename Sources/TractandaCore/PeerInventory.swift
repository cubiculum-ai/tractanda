import Foundation

/// Internal finite descriptor enumeration. Discovery transfers no bytes and proves no eligibility.
enum PeerInventory {
    /// Canonical metadata reuse within one synchronous page/export operation, never lifetime state.
    final class BootstrapProof {
        fileprivate var records: [String: AuthorityRecordCodec.Verified] = [:]
        fileprivate var members: [String: AuthorityBinding] = [:]
        fileprivate var configurationLoaded = false
        fileprivate var configuration: AuthorityStore.Configuration?
    }
    struct Receipt: Sendable {
        let sequence: Int64
        let retained: AuthorityStore.RetainedObject
    }
    /// Codable only for the private export journal; never decoded from a peer/wire request.
    struct Boundary: Codable, Sendable {
        fileprivate let epoch: String
        fileprivate let startSequence: Int64
        fileprivate let maximumSequence: Int64
        fileprivate let contextDigest: String
        fileprivate let storeID: String
        fileprivate let scope: String
    }
    struct Cursor: Codable, Sendable {
        fileprivate let epoch: String
        fileprivate let startSequence: Int64
        fileprivate let maximumSequence: Int64
        fileprivate let contextDigest: String
        fileprivate let scope: String
        fileprivate let lastScanned: Int64
    }
    /// Opaque in-memory evidence that one exact finite descriptor scan reached its end.
    /// It is neither Codable nor a receipt of byte transfer/eligibility.
    struct CompletionCheckpoint: Sendable {
        fileprivate let epoch: String
        fileprivate let completedMaximumSequence: Int64
        fileprivate let contextDigest: String
        fileprivate let storeID: String
        fileprivate let scope: String
    }
    enum Proof: String, Sendable { case configuredOrigin, pinnedLegacy, pinnedInitialHistory }
    struct Entry: Sendable {
        let sequence: Int64
        let descriptor: PeerPackage.Object
        let proof: Proof
        /// Advisory current reducer result, never an acceptance claim from inventory itself.
        let disposition: AuthorityStore.Disposition?
    }
    struct Page: Sendable {
        let entries: [Entry]
        let nextCursor: Cursor?
        let scannedCount: Int
        /// Present only on a successful page that completed the finite boundary.
        let completionCheckpoint: CompletionCheckpoint?
    }
    struct Limits: Sendable {
        var maximumReadBytes: UInt64 = 32 * 1024 * 1024
        var maximumResultBytes = 128 * 1024
    }

    private static func contextDigest(
        _ context: PeerPackage.Context, coordinator: PeerIntakeCoordinator,
        readBudget: ((Int) throws -> Void)? = nil
    ) throws -> String {
        AuthorityRecordCodec.sha256(
            try JSON.encode([
                JSON.encode(context),
                Data(coordinator.originAdmissionFrontier(readBudget: readBudget).utf8),
            ]))
    }
    private static let receiptScope = "tractanda.peer-inventory.receipts.v1"

    static func canonicalInitialPin(
        _ node: AuthorityRevision, coordinator: PeerIntakeCoordinator, index: ItemIndex,
        proof: BootstrapProof, read: (AuthorityStore.RetainedObject) throws -> Data,
        charge: @escaping (Int) throws -> Void
    ) throws -> AuthorityBinding? {
        if !proof.configurationLoaded {
            proof.configuration = try coordinator.configuration(readBudget: charge)
            proof.configurationLoaded = true
        }
        guard let pin = proof.configuration?.bootstrap,
            let located = try index.peerInventoryLegacyPin(
                revisionID: node.revision.revisionID, sha256: node.sha256),
            located.recordID == pin.recordID, located.sha256 == pin.sha256
        else { return nil }
        let key = node.revision.revisionID + ":" + node.sha256
        if proof.members[key] == located { return located }
        guard
            let path = try index.peerInventoryBootstrapPath(
                revisionID: node.revision.revisionID, sha256: node.sha256, pin: located)
        else { return nil }
        func record(_ binding: AuthorityBinding) throws -> AuthorityRecordCodec.Verified {
            if let old = proof.records[binding.recordID] {
                guard old.sha256 == binding.sha256 else {
                    throw TractandaError("peerObjectCollision", "Bootstrap metadata digest changed.")
                }
                return old
            }
            guard let row = try index.retainedAuthorityObject(id: binding.recordID),
                row.descriptor.kind == .authority,
                row.descriptor.sha256 == binding.sha256, row.permittedOrigin
            else {
                throw TractandaError("missingDependencies", "Canonical initial membership proof is missing.")
            }
            let value = try AuthorityRecordCodec.decode(read(row))
            guard value.record.recordID == binding.recordID, value.sha256 == binding.sha256,
                value.record.storeID == coordinator.storeID,
                try coordinator.receiptContextPermits(
                    row, origin: value.record.originReplicaID, index: index,
                    configuration: proof.configuration, readBudget: charge)
            else {
                throw TractandaError("untrustedPeer", "Canonical initial membership origin proof differs.")
            }
            proof.records[binding.recordID] = value
            return value
        }
        var parent = try record(located).record
        guard parent.kind == .bootstrap, parent.payload["initial"] == .boolean(true) else { return nil }
        for binding in path {
            let field = parent.kind == .bootstrap ? "pages" : "children"
            guard parent.kind == .bootstrap || parent.kind == .bootstrapIndex else { return nil }
            let references = try AuthorityRecord.list(parent.payload[field]).map(
                AuthorityBinding.init(value:))
            guard references.contains(binding),
                parent.parentAuthorityIDs == references.map(\.recordID).sorted()
            else { return nil }
            let child = try record(binding).record
            guard child.payload["manifestID"] == .text(located.recordID),
                child.kind == .bootstrapIndex || child.kind == .bootstrapPage
            else { return nil }
            parent = child
        }
        guard parent.kind == .bootstrapPage, parent.parentAuthorityIDs.isEmpty else { return nil }
        let frontier =
            try node.revision.provenance?.kind == .automaticMerge
            ? node.revision.provenance!.frontier : [node.revision.revisionID]
        let matches = try AuthorityRecord.list(parent.payload["entries"]).filter { entry in
            guard let target = entry.map?["target"] else { return false }
            let binding = try AuthorityRecord.binding(target)
            let boundFrontier = try AuthorityRecord.ids(entry.map?["frontier"], maximum: 1024)
            return binding.itemID == node.revision.itemID && binding.revisionID == node.revision.revisionID
                && binding.sha256 == node.sha256 && boundFrontier == frontier
        }
        guard matches.count == 1 else { return nil }
        proof.members[key] = located
        return located
    }
    /// The same relayed legacy proof used by inventory: current bootstrap receipt plus exact
    /// canonical membership. Foreign receipts do not require the source's private local seal.
    static func canonicalLegacyProof(
        _ node: AuthorityRevision, coordinator: PeerIntakeCoordinator,
        index: ItemIndex, proof: BootstrapProof, read: (AuthorityStore.RetainedObject) throws -> Data,
        charge: @escaping (Int) throws -> Void
    ) throws -> Bool {
        guard try node.revision.provenance == nil else { return false }
        if !proof.configurationLoaded {
            proof.configuration = try coordinator.configuration(readBudget: charge)
            proof.configurationLoaded = true
        }
        guard let pin = proof.configuration?.bootstrap,
            let bound = try index.peerInventoryLegacyPin(
                revisionID: node.revision.revisionID, sha256: node.sha256),
            bound.recordID == pin.recordID, bound.sha256 == pin.sha256,
            let control = try index.retainedAuthorityObject(id: pin.recordID),
            control.descriptor.kind == .authority, control.descriptor.sha256 == pin.sha256
        else { return false }
        let manifest = try AuthorityRecordCodec.decode(read(control)).record
        guard manifest.kind == .bootstrap, manifest.recordID == pin.recordID,
            manifest.storeID == coordinator.storeID
        else { return false }
        var after: String?
        var current = false
        while !current {
            try charge(0)
            let receipts = try index.authorityObjectReceiptPage(
                objectID: pin.recordID, afterPackageID: after, limit: 32)
            if receipts.isEmpty { return false }
            for receipt in receipts {
                try charge(0)
                after = receipt.packageID
                if try coordinator.receiptContextPermits(
                    receipt, origin: manifest.originReplicaID,
                    index: index, configuration: proof.configuration, readBudget: charge)
                {
                    current = true
                    break
                }
            }
        }
        return try canonicalInitialPin(
            node, coordinator: coordinator, index: index,
            proof: proof, read: read, charge: charge) != nil
    }
    static func initialLocalReceipt(
        _ row: AuthorityStore.RetainedObject, node: AuthorityRevision,
        coordinator: PeerIntakeCoordinator, charge: @escaping (Int) throws -> Void
    ) throws -> Bool {
        guard row.peerID == "local" else { return false }
        // The reused proof reads four <=4096-byte originals plus the <=4096 identity.
        try charge(20 * 1024)
        guard let publication = try coordinator.journal.publication(row.packageID, readBudget: charge) else {
            return false
        }
        return try AuthorityStore.isInitialHistoryReceipt(
            row, node: node, publication: publication,
            root: coordinator.root, storeID: coordinator.storeID, ownerUID: coordinator.ownerUID,
            files: coordinator.journal.files)
    }
    static func capture(
        context: PeerPackage.Context, after checkpoint: CompletionCheckpoint? = nil,
        coordinator: PeerIntakeCoordinator, index: ItemIndex,
        ownerScope: PeerEnrollmentApproval.OwnerExportScope? = nil
    )
        throws -> Boundary
    {
        try PeerEnrollmentApproval.requireExport(context, coordinator: coordinator, ownerScope: ownerScope)
        let captured = try index.capturePeerInventory()
        let contextDigest = try Self.contextDigest(context, coordinator: coordinator)
        let startSequence: Int64
        if let checkpoint {
            guard checkpoint.scope == Self.receiptScope, checkpoint.storeID == context.storeID,
                checkpoint.contextDigest == contextDigest, checkpoint.epoch == captured.epoch,
                checkpoint.completedMaximumSequence >= 0,
                checkpoint.completedMaximumSequence <= captured.maximumSequence
            else {
                throw TractandaError(
                    "peerInventoryChanged",
                    "Completed inventory checkpoint is stale or belongs to another scope.")
            }
            startSequence = checkpoint.completedMaximumSequence
        } else {
            startSequence = 0
        }
        return .init(
            epoch: captured.epoch, startSequence: startSequence,
            maximumSequence: captured.maximumSequence, contextDigest: contextDigest,
            storeID: context.storeID, scope: Self.receiptScope)
    }

    static func page(
        context: PeerPackage.Context, boundary: Boundary, cursor: Cursor?, limit: Int,
        coordinator: PeerIntakeCoordinator, index: ItemIndex, evaluationsAvailable: Bool,
        limits: Limits, progress: (() throws -> Void)?,
        ownerScope: PeerEnrollmentApproval.OwnerExportScope? = nil,
        bootstrapProof suppliedBootstrapProof: BootstrapProof? = nil,
        proofReadBudget: ((Int) throws -> Void)? = nil
    ) throws -> Page {
        try PeerEnrollmentApproval.requireExport(context, coordinator: coordinator, ownerScope: ownerScope)
        guard limit > 0, limit <= 128, limits.maximumResultBytes >= 512,
            limits.maximumResultBytes <= 128 * 1024, limits.maximumReadBytes > 0,
            limits.maximumReadBytes <= coordinator.journal.limits.maximumReadBytes
        else { throw TractandaError("resourceLimit", "Inventory page limits exceed the operation window.") }
        let headerBudget = PeerOriginAdmission.ReadBudget(limits.maximumReadBytes)
        let chargeHeader: (Int) throws -> Void = { count in
            try headerBudget.charge(count)
            try proofReadBudget?(count)
        }
        let digest = try contextDigest(context, coordinator: coordinator, readBudget: chargeHeader)
        guard boundary.contextDigest == digest, boundary.storeID == context.storeID,
            boundary.scope == Self.receiptScope,
            boundary.startSequence >= 0, boundary.maximumSequence >= boundary.startSequence
        else { throw TractandaError("invalidPeerCursor", "Inventory boundary belongs to another context.") }
        if let cursor {
            guard cursor.epoch == boundary.epoch, cursor.startSequence == boundary.startSequence,
                cursor.maximumSequence == boundary.maximumSequence,
                cursor.contextDigest == digest, cursor.scope == boundary.scope,
                cursor.lastScanned >= boundary.startSequence,
                cursor.lastScanned <= boundary.maximumSequence
            else {
                throw TractandaError("invalidPeerCursor", "Inventory continuation belongs to another pass.")
            }
        }
        let rows = try index.peerInventoryReceiptPage(
            epoch: boundary.epoch, afterSequence: cursor?.lastScanned ?? boundary.startSequence,
            throughSequence: boundary.maximumSequence, limit: limit)
        // Configuration is fresh for this serialized synchronous page, not a cache across
        // requests. Never walk private configuration history once per inventory receipt.
        let configuration = try coordinator.configuration(readBudget: chargeHeader)
        var readBytes = limits.maximumReadBytes - headerBudget.remaining
        var resultBytes = 512
        var work = 0
        let bootstrapProof = suppliedBootstrapProof ?? BootstrapProof()
        if !bootstrapProof.configurationLoaded {
            bootstrapProof.configuration = configuration
            bootstrapProof.configurationLoaded = true
        }
        var entries: [Entry] = []
        func check() throws {
            guard work < coordinator.journal.limits.maximumWork else {
                throw TractandaError("resourceLimit", "Inventory verification work exhausted.")
            }
            work += 1
            try Task.checkCancellation()
            try index.checkCatalogueScanProgress()
            try progress?()
        }
        func chargeProof(_ count: Int) throws {
            try check()
            guard count >= 0,
                UInt64(count) <= limits.maximumReadBytes - min(readBytes, limits.maximumReadBytes)
            else {
                throw TractandaError(
                    "resourceLimit", "Initial membership proof exhausted inventory read budget.")
            }
            try proofReadBudget?(count)
            readBytes += UInt64(count)
        }
        func proofOriginal(_ row: AuthorityStore.RetainedObject) throws -> Data {
            try row.descriptor.validate()
            try chargeProof(row.descriptor.length)
            return try coordinator.bytes(row)
        }
        func original(_ row: AuthorityStore.RetainedObject) throws -> Data {
            try check()
            try row.descriptor.validate()
            guard
                UInt64(row.descriptor.length) <= limits.maximumReadBytes
                    - min(readBytes, limits.maximumReadBytes)
            else { throw TractandaError("resourceLimit", "Inventory verification read budget exhausted.") }
            readBytes += UInt64(row.descriptor.length)
            return try coordinator.bytes(row)
        }
        func currentReceipt(_ row: AuthorityStore.RetainedObject, origin: String) throws -> Bool {
            try coordinator.receiptContextPermits(
                row, origin: origin, index: index,
                configuration: configuration, readBudget: chargeProof)
        }
        return try coordinator.withOperation {
            for receipt in rows {
                try check()
                let row = receipt.retained
                guard row.descriptor.kind == .item || row.descriptor.kind == .authority else { continue }
                // An unknown receipt cannot reserve a transfer slot or force hydration of raw
                // observations. Legacy bytes require the separately reviewed exact pin witness.
                let legacyPin =
                    row.descriptor.kind == .item
                    ? try index.peerInventoryLegacyPin(
                        revisionID: row.descriptor.id, sha256: row.descriptor.sha256) : nil
                guard row.permittedOrigin || legacyPin != nil else { continue }
                let bytes = try original(row)
                let proof: Proof
                if row.descriptor.kind == .item {
                    let node = try AuthorityRevision(originalBytes: bytes)
                    guard node.revision.revisionID == row.descriptor.id else {
                        throw TractandaError("peerObjectCollision", "Inventory item identity differs.")
                    }
                    if let origin = try node.revision.provenance?.originReplicaID {
                        if try currentReceipt(row, origin: origin) {
                            proof = .configuredOrigin
                        } else {
                            guard
                                try canonicalInitialPin(
                                    node, coordinator: coordinator, index: index,
                                    proof: bootstrapProof, read: proofOriginal, charge: chargeProof) != nil,
                                try initialLocalReceipt(
                                    row, node: node, coordinator: coordinator, charge: chargeProof)
                            else { continue }
                            proof = .pinnedInitialHistory
                        }
                    } else {
                        guard
                            try canonicalLegacyProof(
                                node, coordinator: coordinator, index: index,
                                proof: bootstrapProof, read: proofOriginal, charge: chargeProof)
                        else { continue }
                        proof = .pinnedLegacy
                    }
                } else {
                    let record = try AuthorityRecordCodec.decode(bytes).record
                    guard record.recordID == row.descriptor.id, record.storeID == context.storeID else {
                        throw TractandaError(
                            "peerObjectCollision", "Inventory control identity/store differs.")
                    }
                    guard try currentReceipt(row, origin: record.originReplicaID) else { continue }
                    proof = .configuredOrigin
                }
                let entry = Entry(
                    sequence: receipt.sequence, descriptor: row.descriptor, proof: proof,
                    disposition: evaluationsAvailable
                        ? try index.authorityDisposition(id: row.descriptor.id)?.disposition : nil)
                let cost = try JSON.encode(row.descriptor).count + 128
                guard cost <= limits.maximumResultBytes - min(resultBytes, limits.maximumResultBytes) else {
                    throw TractandaError("resourceLimit", "Inventory result byte budget exhausted.")
                }
                resultBytes += cost
                entries.append(entry)
            }
            try check()
            let last = rows.last?.sequence ?? boundary.maximumSequence
            let nextCursor: Cursor? =
                rows.isEmpty || last >= boundary.maximumSequence
                ? nil
                : .init(
                    epoch: boundary.epoch, startSequence: boundary.startSequence,
                    maximumSequence: boundary.maximumSequence,
                    contextDigest: digest, scope: boundary.scope, lastScanned: last)
            return .init(
                entries: entries, nextCursor: nextCursor, scannedCount: rows.count,
                completionCheckpoint: nextCursor == nil
                    ? .init(
                        epoch: boundary.epoch,
                        completedMaximumSequence: boundary.maximumSequence,
                        contextDigest: digest, storeID: context.storeID, scope: boundary.scope)
                    : nil)
        }
    }
    static func exportMaximumSequence(_ boundary: Boundary) -> Int64 { boundary.maximumSequence }
    static func exportEpoch(
        _ boundary: Boundary, context: PeerPackage.Context, coordinator: PeerIntakeCoordinator,
        index: ItemIndex
    ) throws
        -> String
    {
        let captured = try index.capturePeerInventory()
        guard boundary.contextDigest == (try contextDigest(context, coordinator: coordinator)),
            boundary.storeID == context.storeID, boundary.scope == receiptScope,
            boundary.startSequence >= 0, boundary.maximumSequence >= boundary.startSequence,
            boundary.maximumSequence <= captured.maximumSequence, captured.epoch == boundary.epoch
        else { throw TractandaError("peerExportChanged", "Export inventory boundary is stale.") }
        return boundary.epoch
    }
    static func exportSelection(
        _ entry: Entry, boundary: Boundary, context: PeerPackage.Context,
        coordinator: PeerIntakeCoordinator, index: ItemIndex,
        ownerScope: PeerEnrollmentApproval.OwnerExportScope? = nil,
        bootstrapProof: BootstrapProof? = nil, proofReadBudget: ((Int) throws -> Void)? = nil
    ) throws -> AuthorityStore.RetainedObject {
        _ = try exportEpoch(boundary, context: context, coordinator: coordinator, index: index)
        guard entry.sequence > boundary.startSequence, entry.sequence <= boundary.maximumSequence else {
            throw TractandaError("invalidPeerExport", "Selected receipt lies outside the finite boundary.")
        }
        let cursor = Cursor(
            epoch: boundary.epoch, startSequence: boundary.startSequence,
            maximumSequence: boundary.maximumSequence, contextDigest: boundary.contextDigest,
            scope: boundary.scope, lastScanned: entry.sequence - 1)
        let verified = try page(
            context: context, boundary: boundary, cursor: cursor, limit: 1,
            coordinator: coordinator, index: index, evaluationsAvailable: false, limits: .init(),
            progress: nil, ownerScope: ownerScope, bootstrapProof: bootstrapProof,
            proofReadBudget: proofReadBudget)
        guard verified.entries.first?.sequence == entry.sequence,
            verified.entries.first?.descriptor == entry.descriptor,
            let row = try index.peerInventoryReceiptPage(
                epoch: boundary.epoch, afterSequence: entry.sequence - 1,
                throughSequence: entry.sequence, limit: 1
            ).first?.retained
        else {
            throw TractandaError(
                "invalidPeerExport", "Selected descriptor is not a verified current inventory entry.")
        }
        return row
    }

}
