import Foundation

/// Canonical historical decision inputs, never a new current grant or an opaque-token replay.
/// Store's unpublished rebuild owner supplies source/PRE validation and current reduction.
struct AtomicAuthorityHistoricalAcceptance {
    let sealed: AtomicAuthorityAcceptance.Sealed
    let configuration: AuthorityStore.Configuration
    let original: AuthorityStore.RetainedObject
    let publication: PeerIntakeJournal.Publication

    static func find(
        _ binding: AuthorityBinding, receiverReplicaID: String,
        coordinator: PeerIntakeCoordinator, index: ItemIndex
    ) throws -> Self? {
        var after: String?
        var chosen: Self?
        while true {
            let rows = try index.authorityObjectReceiptPage(
                objectID: binding.recordID, afterPackageID: after, limit: 128)
            if rows.isEmpty { return chosen }
            for row in rows {
                after = row.packageID
                guard
                    let sealed = try coordinator.journal.atomicAcceptance(
                        packageID: row.packageID, root: binding)
                else { continue }
                guard sealed.receipt.storeID == coordinator.storeID,
                    sealed.receipt.receiverReplicaID == receiverReplicaID,
                    row.descriptor.kind == .authority, row.descriptor.sha256 == binding.sha256,
                    let publication = try coordinator.journal.publication(row.packageID),
                    publication.manifestDigest == sealed.receipt.manifestSHA256
                else {
                    throw AtomicAuthorityFormat.invalid(
                        "Historical acceptance belongs to another receiver or publication.")
                }
                let reference = sealed.receipt.context.configuration
                let bytes = try coordinator.journal.files.read(
                    path: [".peer-configuration", reference.fileName],
                    maximumBytes: PeerPackage.maximumPageBytes,
                    readBudget: coordinator.admissionReadBudget())
                guard AuthorityRecordCodec.sha256(bytes) == reference.sha256 else {
                    throw AtomicAuthorityFormat.invalid(
                        "Historical configuration changed its canonical hash.")
                }
                let configuration = try PeerPackage.decode(AuthorityStore.Configuration.self, bytes)
                try configuration.validateCredentialBindings()
                let value = Self(
                    sealed: sealed, configuration: configuration,
                    original: row, publication: publication)
                // A root is decided once per physical receiver. Exact retry reuses the same
                // receipt; conflicting attestations cannot be resolved by arbitrary file order.
                if let chosen, chosen.sealed.receipt != sealed.receipt {
                    throw AtomicAuthorityFormat.invalid(
                        "One historical root has conflicting accepted receipts.")
                }
                chosen = value
            }
        }
    }
    /// Full captured canonical body closure. Captured accepted heads must also be reconstructed;
    /// physical parts, private staging and the receipt's volatile generation token are no cuts.
    func requireContextClosure(coordinator: PeerIntakeCoordinator, index: ItemIndex) throws -> Bool {
        var complete = true
        _ = try coordinator.journal.walkUntrustedAtomicContext(sealed.receipt) { descriptor in
            guard let row = try index.retainedAuthorityObject(id: descriptor.id),
                row.descriptor == descriptor
            else {
                throw AtomicAuthorityFormat.invalid("Historical context original lost its exact identity.")
            }
            let raw = try CanonicalAuthorityOriginal(coordinator.bytes(row))
            guard raw.storeID == coordinator.storeID, raw.recordID == descriptor.id,
                raw.sha256 == descriptor.sha256
            else {
                throw AtomicAuthorityFormat.invalid("Historical context canonical bytes changed.")
            }
            let control: Bool
            switch raw.payload {
            case .atomic(let record):
                guard record.kind == .atomicControl else {
                    throw AtomicAuthorityFormat.invalid("Physical parts cannot be historical context heads.")
                }
                control = true
            case .legacy(let value):
                switch value.record.kind {
                case .controlCommit: control = true
                case .bootstrap, .enrollmentApproval, .originRetirement: control = false
                default:
                    throw AtomicAuthorityFormat.invalid(
                        "Unexpected original role in historical acceptance context.")
                }
            }
            if control {
                let binding = try AuthorityBinding(recordID: descriptor.id, sha256: descriptor.sha256)
                if try !index.hasValidatedAuthorityControl(binding) { complete = false }
            }
        }
        try requireStableCanonicalBinding(coordinator: coordinator)
        return complete
    }
    /// Fresh bounded reopens across private work windows. The receipt binds the context tree;
    /// its complete raw closure was checked separately, never replaced by this identity check.
    func requireStableCanonicalBinding(coordinator: PeerIntakeCoordinator) throws {
        let receipt = sealed.receipt
        let raw = try coordinator.journal.files.read(
            path: [
                "authority", "intake", receipt.packageID, "atomic-accepted", receipt.root.recordID + ".json",
            ],
            maximumBytes: PeerPackage.maximumPageBytes, readBudget: coordinator.admissionReadBudget())
        guard AuthorityRecordCodec.sha256(raw) == sealed.bytesSHA256,
            try PeerPackage.decode(AtomicAuthorityAcceptance.Receipt.self, raw) == receipt,
            try coordinator.journal.publication(receipt.packageID) == publication
        else {
            throw AtomicAuthorityFormat.invalid(
                "Historical receipt/publication identity changed during reconstruction.")
        }
        let config = try coordinator.journal.files.read(
            path: [".peer-configuration", receipt.context.configuration.fileName],
            maximumBytes: PeerPackage.maximumPageBytes, readBudget: coordinator.admissionReadBudget())
        guard AuthorityRecordCodec.sha256(config) == receipt.context.configuration.sha256 else {
            throw AtomicAuthorityFormat.invalid(
                "Historical configuration original changed during reconstruction.")
        }
        let expected = receipt.context.authorities.root
        let root = try coordinator.journal.files.read(
            path: [
                "authority", "intake", receipt.packageID, "atomic-context", receipt.root.recordID,
                "pages", expected.id,
            ], maximumBytes: PeerPackage.maximumPageBytes,
            readBudget: coordinator.admissionReadBudget())
        guard root.count == expected.length, AuthorityRecordCodec.sha256(root) == expected.sha256 else {
            throw AtomicAuthorityFormat.invalid("Historical context tree changed its committed root.")
        }
    }
}
