import Foundation

/// A bounded view of one logical control. Atomic structural staging confers no authority.
/// Only accepted-control queries establish eligibility; a source is input to Store validation.
enum LogicalControlSource {
    case legacy(AuthorityStore.VerifiedControlPlan)
    case atomic(AtomicControlStage)

    struct Header: Equatable {
        let binding: AuthorityBinding
        let storeID: String
        let origin: String
        let actor: String
        let createdAt: String
        let previous: AuthorityBinding?
        let bootstrap: AuthorityBinding?
    }
    struct Support: Equatable {
        let ordinal: Int64
        let fingerprint: String
        let delta: AuthorityStore.DispositionDelta
    }
    func header() throws -> Header {
        switch self {
        case .legacy(let plan):
            let r = plan.control.record
            return Header(
                binding: plan.binding, storeID: r.storeID, origin: r.originReplicaID,
                actor: r.actorPrincipal, createdAt: r.createdAt, previous: plan.localParent,
                bootstrap: plan.bootstrap)
        case .atomic(let stage): return stage.header
        }
    }
    func parents(index: ItemIndex, afterOrdinal: Int64 = -1, limit: Int = 128) throws
        -> [(ordinal: Int64, binding: AuthorityBinding)]
    {
        try Self.page(afterOrdinal, limit)
        switch self {
        case .legacy(let plan):
            return plan.parents.enumerated().filter { Int64($0.offset) > afterOrdinal }.prefix(limit).map {
                (Int64($0.offset), $0.element)
            }
        case .atomic(let stage):
            return try index.atomicControlParents(stage, afterOrdinal: afterOrdinal, limit: limit)
        }
    }
    func supports(index: ItemIndex, afterOrdinal: Int64 = -1, limit: Int = 128) throws -> [Support] {
        try Self.page(afterOrdinal, limit)
        switch self {
        case .legacy(let plan):
            return try plan.deltas.enumerated().filter { Int64($0.offset) > afterOrdinal }.prefix(limit).map {
                Support(
                    ordinal: Int64($0.offset),
                    fingerprint: AuthorityRecordCodec.sha256(try JSON.encode($0.element.itemValue)),
                    delta: $0.element)
            }
        case .atomic(let stage):
            return try index.atomicControlSupports(stage, afterOrdinal: afterOrdinal, limit: limit)
        }
    }
    static func page(_ ordinal: Int64, _ limit: Int) throws {
        guard ordinal >= -1, (1...1024).contains(limit) else {
            throw AtomicAuthorityFormat.invalid("Invalid logical control cursor/window.")
        }
    }
}

/// An exact structural root/stage handle, deliberately not a VerifiedControlPlan/acceptance token.
struct AtomicControlStage: Equatable {
    let header: LogicalControlSource.Header
    let rootBytes: Data
    let parents: AtomicAuthorityFormat.Stream
    let effects: AtomicAuthorityFormat.Stream
    init(rootBytes: Data) throws {
        let r = try AtomicAuthorityFormat.Codec.decode(rootBytes)
        guard r.kind == .atomicControl else {
            throw AtomicAuthorityFormat.invalid("Physical parts are not logical controls.")
        }
        self.rootBytes = rootBytes
        header = try .init(
            binding: .init(recordID: r.recordID, sha256: AuthorityRecordCodec.sha256(rootBytes)),
            storeID: r.storeID, origin: r.originReplicaID,
            actor: AuthorityRecord.text(r.itemValue.map?["actorPrincipal"]),
            createdAt: r.itemValue.map?["createdAt"]?.dateString ?? "",
            previous: AtomicAuthorityFormat.bindings(r.payload["previous"]).first,
            bootstrap: AtomicAuthorityFormat.bindings(r.payload["bootstrap"]).first)
        parents = try .init(value: r.payload["parents"]!, section: .parents)
        effects = try .init(value: r.payload["effects"]!, section: .effects)
    }
}

extension AuthorityStore {
    /// Trusted Store boundary, corresponding to VerifiedControlPlan for a whole atomic root.
    /// Store validates original PRE, all support facts and fresh current context before sealing.
    /// Index additionally requires its active canonical-to-stage finalization scope and rechecks
    /// exact original/parent/target bindings; a structural stage alone cannot insert this plan.
    struct VerifiedAtomicControlPlan {
        let stage: AtomicControlStage
        let contextDigest: String
        let validationPurpose: AtomicAuthorityAcceptance.ValidationPurpose
        /// Existing historical attestation only, never permission to originate a new decision.
        let reconstruction: AtomicAuthorityAcceptance.Sealed?
        init(
            stage: AtomicControlStage, contextDigest: String,
            reconstruction: AtomicAuthorityAcceptance.Sealed? = nil,
            validationPurpose: AtomicAuthorityAcceptance.ValidationPurpose = .authenticatedRequest
        ) throws {
            self.stage = stage
            self.validationPurpose = validationPurpose
            self.contextDigest = try AuthorityRecord.digest(.text(contextDigest))
            if let reconstruction {
                guard reconstruction.receipt.root == stage.header.binding,
                    reconstruction.receipt.storeID == stage.header.storeID,
                    reconstruction.bytesSHA256 == contextDigest,
                    reconstruction.receipt.context.validationPurpose == validationPurpose
                else {
                    throw AtomicAuthorityFormat.invalid(
                        "Historical plan lost its exact canonical receipt identity.")
                }
            }
            self.reconstruction = reconstruction
        }
        func acceptanceContextSHA256(_ sealed: AtomicAuthorityAcceptance.Sealed) throws -> String {
            guard sealed.receipt.context.validationPurpose == validationPurpose else {
                throw AtomicAuthorityFormat.invalid(
                    "Accepted validation purpose differs from its verified plan.")
            }
            if let reconstruction {
                guard reconstruction.receipt == sealed.receipt,
                    reconstruction.bytesSHA256 == sealed.bytesSHA256
                else {
                    throw AtomicAuthorityFormat.invalid("Reconstruction changed its historical attestation.")
                }
                return sealed.receipt.validationContextSHA256
            }
            guard contextDigest == sealed.receipt.validationContextSHA256 else {
                throw AtomicAuthorityFormat.invalid(
                    "Accepted current context differs from its validated plan.")
            }
            return contextDigest
        }
        var binding: AuthorityBinding { stage.header.binding }
    }
}
