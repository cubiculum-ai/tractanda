import CSQLite
import Crypto
import Foundation

/// Canonical historical membership, deliberately independent of pair credentials and their keys.
enum PeerOriginAdmission {
    static let capability = "tractanda.peer-origin-admission.v1"
    static let directory = ".peer-origin-admissions"
    final class ReadBudget {
        var remaining: UInt64
        init(_ bytes: UInt64) { remaining = bytes }
        func charge(_ bytes: Int) throws {
            guard bytes >= 0, UInt64(bytes) <= remaining else {
                throw TractandaError("resourceLimit", "Canonical admission read window exhausted.")
            }
            remaining -= UInt64(bytes)
        }
    }
    struct Decision: Codable, Equatable {
        let profile: String
        let target: String
        let approval: PeerPackage.Object
        let packageID: String
        let issuerAdmission: AuthorityBinding
    }
    struct Receipt: Codable, Equatable {
        let profile: String
        let origin: String
        let admission: AuthorityBinding
        let manifestDigest: String
        let contextDigest: String
    }
    static func failure(_ message: String) -> TractandaError {
        TractandaError("invalidOriginAdmission", message)
    }
}

extension PeerIntakeCoordinator {
    /// Finite receipt scan. Unknown observations alone are queued for ordinary reevaluation.
    @discardableResult
    func replayOriginReceipts(index: ItemIndex, create: Bool) throws -> Bool {
        try withOperation { try replayOriginReceiptsBody(index: index, create: create) }
    }
    private func replayOriginReceiptsBody(index: ItemIndex, create: Bool) throws -> Bool {
        let boundary = try index.capturePeerInventory()
        var sequence: Int64 = 0
        var work = 0
        var changed = false
        while sequence < boundary.maximumSequence {
            let rows = try index.peerOriginReplayReceiptPage(
                epoch: boundary.epoch, afterSequence: sequence,
                throughSequence: boundary.maximumSequence, limit: 128)
            guard !rows.isEmpty else { break }
            for entry in rows {
                sequence = entry.sequence
                work += 1
                try progress?()
                guard work <= journal.limits.maximumWork else {
                    throw TractandaError("resourceLimit", "Origin receipt reconsideration work exhausted.")
                }
                let row = entry.retained
                guard
                    let publication = try journal.publication(
                        row.packageID, readBudget: admissionReadBudget())
                else {
                    throw PeerOriginAdmission.failure("Retained receipt lost its canonical publication seal.")
                }
                guard publication.packageID == row.packageID,
                    publication.context.peerID == row.peerID,
                    publication.context.configurationDigest == row.configurationDigest
                else {
                    throw PeerOriginAdmission.failure(
                        "Canonical publication and typed receipt context differ.")
                }
                if publication.context.peerID == "local" { continue }
                guard row.descriptor.kind == .item || row.descriptor.kind == .authority,
                    let origin = entry.origin, !publication.context.permittedOrigins.contains(origin)
                else { continue }
                let old = try originReceipt(packageID: row.packageID, origin: origin)
                if old != nil {
                    guard try admittedReceiptPermits(packageID: row.packageID, origin: origin, index: index)
                    else {
                        throw PeerOriginAdmission.failure(
                            "Retained receipt lost its canonical admission proof.")
                    }
                } else {
                    // An already-permitted derived row cannot repair lost canonical authority
                    // by resealing it. Only a genuinely unadmitted observation may acquire proof.
                    if row.permittedOrigin {
                        throw PeerOriginAdmission.failure("Admitted receipt proof is missing.")
                    }
                    guard
                        try create
                            && sealAdmittedOrigin(packageID: row.packageID, origin: origin, index: index)
                    else { continue }
                }
                if !row.permittedOrigin {
                    try index.admitOriginReceipt(row)
                    changed = true
                }
            }
        }
        return changed
    }
    func originDecision(_ origin: String, readBudget: ((Int) throws -> Void)? = nil) throws
        -> PeerOriginAdmission.Decision?
    {
        _ = try AuthorityRecord.persistentID(.text(origin))
        guard
            let bytes = try journal.files.readIfPresent(
                path: [PeerOriginAdmission.directory, origin], maximumBytes: PeerPackage.maximumPageBytes,
                readBudget: readBudget ?? admissionReadBudget())
        else { return nil }
        let value = try PeerPackage.decode(PeerOriginAdmission.Decision.self, bytes)
        guard value.profile == PeerOriginAdmission.capability, value.target == origin,
            value.approval.kind == .authority
        else {
            throw PeerOriginAdmission.failure("Canonical admission target/profile differs.")
        }
        _ = try AuthorityRecord.persistentID(.text(value.packageID))
        return value
    }

    /// Returns the root or an exact accepted explicit-target decision. SQL is never its authority.
    /// A bounded recursion detects self/circular trust before any receipt can use it.
    func originAdmission(
        _ origin: String, index: ItemIndex,
        readBudget: ((Int) throws -> Void)? = nil
    ) throws -> AuthorityBinding? {
        let charge = readBudget ?? admissionReadBudget()
        var visiting = Set<String>()
        func resolve(_ origin: String) throws -> AuthorityBinding? {
            try progress?()
            guard visiting.count < min(journal.limits.maximumDepth, journal.limits.maximumWork),
                visiting.insert(origin).inserted
            else {
                throw PeerOriginAdmission.failure("Circular or excessive origin-admission chain.")
            }
            defer { visiting.remove(origin) }
            guard let pin = try configuration(readBudget: charge)?.bootstrap,
                let root = try index.retainedAuthorityObject(id: pin.recordID),
                root.descriptor.sha256 == pin.sha256
            else { return nil }
            let rootBytes = try verifiedOriginalBytes(root, readBudget: charge)
            guard AuthorityRecordCodec.sha256(rootBytes) == pin.sha256 else {
                throw PeerOriginAdmission.failure("Permanent root original differs.")
            }
            let bootstrap = try AuthorityRecordCodec.decode(rootBytes).record
            guard bootstrap.kind == .bootstrap, bootstrap.storeID == storeID else {
                throw PeerOriginAdmission.failure("Admission lacks its permanent canonical root.")
            }
            let rootBinding = try AuthorityBinding(recordID: pin.recordID, sha256: pin.sha256)
            if bootstrap.originReplicaID == origin { return rootBinding }
            guard let decision = try originDecision(origin, readBudget: charge) else { return nil }
            guard let publication = try journal.publication(decision.packageID, readBudget: charge) else {
                throw PeerOriginAdmission.failure("Retained admission lost its accepted publication proof.")
            }
            let original = try admissionOriginal(decision, readBudget: charge)
            let record = original.record
            guard original.sha256 == decision.approval.sha256, record.recordID == decision.approval.id,
                record.kind == .enrollmentApproval, record.storeID == storeID,
                record.payload["targetReplicaID"] == .text(origin),
                try AuthorityRecord.list(record.payload["bootstrap"]).map(AuthorityBinding.init(value:)) == [
                    rootBinding
                ],
                let issuer = try resolve(record.originReplicaID), issuer == decision.issuerAdmission,
                try receiptPublicationIsConfigured(publication, readBudget: charge)
            else { throw PeerOriginAdmission.failure("Admission public decision/issuer/receipt differs.") }
            if let prior = record.payload["issuerAdmission"] {
                guard try AuthorityRecord.list(prior).map(AuthorityBinding.init(value:)) == [issuer] else {
                    throw PeerOriginAdmission.failure(
                        "Decision does not bind its exact prior issuer admission.")
                }
            } else if issuer != rootBinding {
                throw PeerOriginAdmission.failure(
                    "Unanchored historical issuer cannot acquire authority later.")
            }
            if !publication.context.permittedOrigins.contains(record.originReplicaID) {
                guard
                    let proof = try originReceipt(
                        packageID: decision.packageID, origin: record.originReplicaID,
                        readBudget: charge),
                    proof.admission == issuer, try receipt(proof, matches: publication)
                else { throw PeerOriginAdmission.failure("Admission lost its authenticated issuer receipt.") }
            }
            return try AuthorityBinding(recordID: original.record.recordID, sha256: original.sha256)
        }
        return try resolve(origin)
    }

    func admissionOriginal(
        _ decision: PeerOriginAdmission.Decision,
        readBudget: ((Int) throws -> Void)? = nil
    ) throws -> AuthorityRecordCodec.Verified {
        guard
            let bytes = try journal.object(
                decision.approval, packageID: decision.packageID,
                readBudget: readBudget ?? admissionReadBudget())
        else {
            throw PeerOriginAdmission.failure("Admission canonical approval original is missing.")
        }
        return try AuthorityRecordCodec.decode(bytes)
    }
    func receiptPublicationIsConfigured(
        _ publication: PeerIntakeJournal.Publication,
        readBudget: ((Int) throws -> Void)? = nil
    ) throws -> Bool {
        if publication.context.peerID == "local" {
            return try publication.context == context(peerID: "local", readBudget: readBudget)
        }
        if let provisioningScope,
            try provisioningScope.permits(publication, readBudget: readBudget ?? admissionReadBudget())
        {
            return true
        }
        let configuration = try configuration(readBudget: readBudget ?? admissionReadBudget())
        return configuration?.peers.contains(publication.context) == true
            || configuration?.lifecycle?.historicalContexts.contains(publication.context) == true
    }
    func originReceipt(
        packageID: String, origin: String,
        readBudget: ((Int) throws -> Void)? = nil
    ) throws -> PeerOriginAdmission.Receipt? {
        _ = try AuthorityRecord.persistentID(.text(packageID))
        _ = try AuthorityRecord.persistentID(.text(origin))
        guard
            let bytes = try journal.files.readIfPresent(
                path: ["authority", "intake", packageID, "origin-admissions", origin],
                maximumBytes: PeerPackage.maximumPageBytes, readBudget: readBudget ?? admissionReadBudget())
        else { return nil }
        let value = try PeerPackage.decode(PeerOriginAdmission.Receipt.self, bytes)
        guard value.profile == PeerOriginAdmission.capability, value.origin == origin else {
            throw PeerOriginAdmission.failure("Origin receipt binding differs.")
        }
        return value
    }
    private func receipt(
        _ proof: PeerOriginAdmission.Receipt,
        matches publication: PeerIntakeJournal.Publication
    ) throws -> Bool {
        try proof.manifestDigest == publication.manifestDigest
            && proof.contextDigest == AuthorityRecordCodec.sha256(JSON.encode(publication.context))
    }
    func admittedReceiptPermits(
        packageID: String, origin: String, index: ItemIndex,
        readBudget: ((Int) throws -> Void)? = nil
    ) throws -> Bool {
        let charge = readBudget ?? admissionReadBudget()
        guard let proof = try originReceipt(packageID: packageID, origin: origin, readBudget: charge),
            let publication = try journal.publication(packageID, readBudget: charge),
            try receipt(proof, matches: publication),
            try receiptPublicationIsConfigured(publication, readBudget: charge),
            try originAdmission(origin, index: index, readBudget: charge) == proof.admission
        else { return false }
        return true
    }
    /// Called only after a sealed authenticated publication; membership itself grants no channel.
    @discardableResult
    func sealAdmittedOrigin(packageID: String, origin: String, index: ItemIndex) throws -> Bool {
        let charge = admissionReadBudget()
        guard let publication = try journal.publication(packageID, readBudget: charge),
            publication.context.peerID != "local",
            try receiptPublicationIsConfigured(publication, readBudget: charge),
            let admission = try originAdmission(origin, index: index, readBudget: charge)
        else { return false }
        let value = PeerOriginAdmission.Receipt(
            profile: PeerOriginAdmission.capability, origin: origin,
            admission: admission, manifestDigest: publication.manifestDigest,
            contextDigest: AuthorityRecordCodec.sha256(try JSON.encode(publication.context)))
        let path = ["authority", "intake", packageID, "origin-admissions", origin]
        try CanonicalReaderRequirement.beforeOriginAdmissionPublication(root: root, ownerUID: ownerUID)
        if let old = try originReceipt(packageID: packageID, origin: origin, readBudget: charge) {
            guard old == value else { throw PeerOriginAdmission.failure("Immutable origin receipt differs.") }
        } else {
            try journal.files.writeImmutable(
                JSON.encode(value), path: path, maximumBytes: PeerPackage.maximumPageBytes)
        }
        return true
    }

    /// The frontier is bounded canonical metadata, not configuration or private key state.
    func originAdmissionFrontier(
        excluding: AuthorityBinding? = nil, readBudget: ((Int) throws -> Void)? = nil
    ) throws -> String {
        let root = self.root.appendingPathComponent(PeerOriginAdmission.directory)
        guard FileManager.default.fileExists(atPath: root.path) else { return "" }
        var entries: [String] = []
        var work = 0
        let charge = readBudget ?? admissionReadBudget()
        try POSIXDirectory.withEntries(at: root) { origin in
            work += 1
            guard work <= min(4096, journal.limits.maximumObjects) else {
                throw TractandaError(
                    "resourceLimit", "Admission frontier exceeds its bounded membership window.")
            }
            guard let decision = try originDecision(origin, readBudget: charge) else {
                throw PeerOriginAdmission.failure("Canonical admission disappeared.")
            }
            let binding = try AuthorityBinding(
                recordID: decision.approval.id, sha256: decision.approval.sha256)
            if binding != excluding { entries.append(origin + ":" + binding.recordID + ":" + binding.sha256) }
            return true
        }
        return entries.isEmpty ? "" : AuthorityRecordCodec.sha256(try JSON.encode(entries.sorted()))
    }

    func admittedOriginSnapshot(index: ItemIndex, localOrigin: String) throws -> [String] {
        try withOperation { try admittedOriginSnapshotBody(index: index, localOrigin: localOrigin) }
    }
    private func admittedOriginSnapshotBody(index: ItemIndex, localOrigin: String) throws -> [String] {
        var origins = Set([localOrigin])
        if let pin = try configuration(readBudget: admissionReadBudget())?.bootstrap,
            let row = try index.retainedAuthorityObject(id: pin.recordID)
        {
            origins.insert(try AuthorityRecordCodec.decode(bytes(row)).record.originReplicaID)
        }
        let directory = root.appendingPathComponent(PeerOriginAdmission.directory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try POSIXDirectory.withEntries(at: directory) { origin in
                guard origins.count < 256, try originAdmission(origin, index: index) != nil else {
                    throw TractandaError(
                        "resourceLimit", "Enrollment origin snapshot exceeds its protocol window.")
                }
                origins.insert(origin)
                return true
            }
        }
        return origins.sorted()
    }
}

extension ItemIndex {
    /// This is invoked only with a checked canonical origin receipt. Preserve held/rejected state.
    func admitOriginReceipt(_ row: AuthorityStore.RetainedObject) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try execute("CREATE TABLE IF NOT EXISTS peer_origin_reconsideration(package TEXT PRIMARY KEY)")
            try execute(
                "INSERT OR IGNORE INTO peer_origin_reconsideration SELECT ? WHERE EXISTS(SELECT 1 FROM authority_dispositions WHERE object=? AND state='unknownOrigin')",
                [row.packageID, row.descriptor.id])
            try execute(
                "UPDATE authority_packages SET permitted=1 WHERE package=? AND object=?",
                [row.packageID, row.descriptor.id])
            try execute(
                "UPDATE authority_dispositions SET state='pending',reason='Canonical origin admission; awaiting ordinary authority.' WHERE object=? AND state='unknownOrigin'",
                [row.descriptor.id])
            try execute(
                "UPDATE authority_packages SET pending=permitted AND (SELECT state IN('pending','missingDependencies') FROM authority_dispositions WHERE object=?) WHERE object=?",
                [row.descriptor.id, row.descriptor.id])
        }
    }
    func originReconsiderationPage(after: String? = nil) throws -> [String] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try execute("CREATE TABLE IF NOT EXISTS peer_origin_reconsideration(package TEXT PRIMARY KEY)")
            let statement = try corpusPrepare(
                "SELECT package FROM peer_origin_reconsideration WHERE package>? ORDER BY package LIMIT 128",
                [after ?? ""])
            defer { sqlite3_finalize(statement) }
            var result: [String] = []
            while true {
                let status = catalogueStep(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW, sqlite3_column_bytes(statement, 0) == 36,
                    let pointer = sqlite3_column_text(statement, 0)
                else { throw graphSQLiteError() }
                let value = String(cString: pointer)
                _ = try AuthorityRecord.persistentID(.text(value))
                result.append(value)
            }
        }
    }
}
