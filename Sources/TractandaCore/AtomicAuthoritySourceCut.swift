import CSQLite
import Crypto
import Foundation

extension PeerIntakeCoordinator {
    struct AtomicSourceCutDraft {
        let cut: AuthorityBinding
        let newRoot: AtomicAuthorityArchive.Handle?
    }

    /// A context join inherits genuine facts through its complete accepted parent heads. It
    /// never recopies historical positives/negatives as fresh assertions or local admissions.
    /// Only genuinely new pending decisions are encoded as support facts, with exact CAS bytes.
    /// The Store freezes authorization/context and owns subsequent semantic/seal publication.
    func prepareAtomicSourceCut(
        index: ItemIndex, archive: AtomicAuthorityArchive, reservation: AtomicAuthorityArchive.Context
    ) throws -> AtomicSourceCutDraft {
        guard reservation.storeID == storeID,
            try index.authorityControlHead(originID: reservation.origin) == reservation.previous
        else {
            throw AtomicAuthorityFormat.invalid("Atomic source-cut reservation changed its original head.")
        }
        let header = LogicalControlSource.Header(
            binding: try .init(recordID: reservation.rootID, sha256: String(repeating: "0", count: 64)),
            storeID: storeID, origin: reservation.origin, actor: reservation.actor,
            createdAt: reservation.createdAt, previous: reservation.previous, bootstrap: reservation.bootstrap
        )
        try requireAtomicBootstrap(header, index: index)
        try index.initializeAtomicAuthorityAcceptedSchema()
        if let previous = reservation.previous, try index.atomicPendingEffectPage(limit: 1).isEmpty {
            let bridge = try logicalControlHeader(previous, index: index).previous
            var after: String?
            var completeContext = true
            while completeContext {
                let heads = try index.atomicCurrentHeadPage(afterRecordID: after, limit: 128)
                if heads.isEmpty { break }
                for head in heads {
                    after = head.recordID
                    if head == previous { continue }
                    if try index.acceptedControlHasParent(previous, parent: head) { continue }
                    if let bridge, try index.acceptedControlHasParent(bridge, parent: head) { continue }
                    completeContext = false
                    break
                }
            }
            // This is a bounded sufficient proof, not a depth limit: if a deeper inherited
            // context is not cheaply proved, build a new zero-effect join instead of failing or
            // walking/copying all imported history. Existing raw ancestry remains unchanged.
            if completeContext { return .init(cut: previous, newRoot: nil) }
        }
        var parentCursor: String?
        var parents: [AuthorityBinding] = []
        var parentOffset = 0
        var effectCursor: String?
        var effects: [AuthorityStore.DispositionDelta] = []
        var effectOffset = 0
        let handle = try archive.build(
            context: reservation,
            parents: {
                if parentOffset == parents.count {
                    parents = try index.atomicCurrentHeadPage(afterRecordID: parentCursor, limit: 128)
                    parentOffset = 0
                }
                guard parentOffset < parents.count else { return nil }
                let next = parents[parentOffset]
                parentCursor = next.recordID
                parentOffset += 1
                return next.itemValue
            },
            effects: {
                if effectOffset == effects.count {
                    effects = try index.atomicPendingEffectPage(afterRevisionID: effectCursor, limit: 128)
                    effectOffset = 0
                }
                guard effectOffset < effects.count else { return nil }
                let next = effects[effectOffset]
                if next.eligible,
                    try !index.authorityHasLocalHistoryAdmission(revisionID: next.target.revisionID)
                {
                    throw TractandaError(
                        "authorityReviewRequired",
                        "A source-cut join cannot grant new local history; use current actor-bound admission."
                    )
                }
                effectCursor = next.target.revisionID
                effectOffset += 1
                return next.itemValue
            })
        return .init(cut: handle.binding, newRoot: handle)
    }
}

extension ItemIndex {
    func atomicCurrentHeadPage(afterRecordID: String? = nil, limit: Int = 128) throws -> [AuthorityBinding] {
        try LogicalControlSource.page(-1, limit)
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT id,sha256 FROM authority_control_heads INDEXED BY authority_atomic_head_id"
                    + (afterRecordID == nil ? "" : " WHERE id>?") + " ORDER BY id LIMIT ?",
                (afterRecordID.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var result: [AuthorityBinding] = []
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                result.append(try .init(recordID: atomicDraftText(s, 0), sha256: atomicDraftText(s, 1)))
            }
        }
    }
    /// Exact immutable pending payloads, not regenerated/merged delta surrogates. No queue is
    /// consumed while planning; final accepted support uses the original payload/fingerprint CAS.
    func atomicPendingEffectPage(afterRevisionID: String? = nil, limit: Int = 128) throws
        -> [AuthorityStore.DispositionDelta]
    {
        try LogicalControlSource.page(-1, limit)
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT revision,fingerprint,payload FROM authority_pending_effect"
                    + (afterRevisionID == nil ? "" : " WHERE revision>?") + " ORDER BY revision LIMIT ?",
                (afterRevisionID.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var result: [AuthorityStore.DispositionDelta] = []
            var bytes = 0
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                let payload = try atomicDraftText(s, 2)
                if !result.isEmpty,
                    payload.utf8.count > graphMaximumPageBytes - min(bytes, graphMaximumPageBytes)
                {
                    return result
                }
                let data = Data(payload.utf8)
                let value = try AtomicAuthorityFormat.decodeValue(data)
                try AtomicAuthorityEntryStream.validate(value, section: .effects)
                let delta = try AuthorityStore.DispositionDelta(value: value)
                guard delta.target.revisionID == (try atomicDraftText(s, 0)),
                    AuthorityRecordCodec.sha256(data) == (try atomicDraftText(s, 1)),
                    try JSON.encode(delta.itemValue) == data
                else {
                    throw AtomicAuthorityFormat.invalid(
                        "Pending atomic decision lost exact target/payload binding.")
                }
                bytes += data.count
                result.append(delta)
            }
        }
    }
    private func atomicDraftText(_ s: OpaquePointer, _ column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(s, column))
        guard sqlite3_column_type(s, column) == SQLITE_TEXT, count >= 0,
            count <= AtomicAuthorityFormat.maximumEnvelopeBytes,
            let bytes = sqlite3_column_text(s, column),
            let text = String(data: Data(bytes: bytes, count: count), encoding: .utf8)
        else {
            throw AtomicAuthorityFormat.invalid("Malformed atomic draft metadata text.")
        }
        return text
    }
}
