import CSQLite
import Crypto
import Foundation

extension AuthorityStore {
    struct SupportCursor: Equatable {
        let target: String
        let fingerprint: String
    }
    struct AcceptedSupport {
        let delta: DispositionDelta
        let fingerprint: String
        var cursor: SupportCursor { .init(target: delta.target.revisionID, fingerprint: fingerprint) }
    }
}

extension ItemIndex {
    /// Mutable semantic-context fingerprint only, never a canonical proof or cached grant.
    /// Every accepted issuer head participates without materializing the whole frontier.
    func acceptedControlHeadFrontierSHA256() throws -> String {
        var hasher = SHA256()
        var after: String?
        while true {
            let page = try withCatalogueScanBudget(reusingActiveBudget: true) {
                () -> [(String, AuthorityBinding)] in
                let s = try corpusPrepare(
                    "SELECT origin,id,sha256 FROM authority_control_heads"
                        + (after == nil ? "" : " WHERE origin>?") + " ORDER BY origin LIMIT 128",
                    after.map { [$0] } ?? [])
                defer { sqlite3_finalize(s) }
                var rows: [(String, AuthorityBinding)] = []
                while true {
                    try checkCatalogueScanProgress()
                    let status = catalogueStep(s)
                    if status == SQLITE_DONE { return rows }
                    guard status == SQLITE_ROW else { throw graphSQLiteError() }
                    let origin = try AuthorityRecord.persistentID(.text(atomicQueryText(s, 0)))
                    rows.append(
                        try (origin, .init(recordID: atomicQueryText(s, 1), sha256: atomicQueryText(s, 2))))
                }
            }
            if page.isEmpty { break }
            for (origin, binding) in page {
                let bytes = try JSON.encode(
                    ItemValue.object(["origin": .text(origin), "head": binding.itemValue]))
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
                hasher.update(data: bytes)
                after = origin
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func hasAcceptedInitialBootstrap(_ binding: AuthorityBinding) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT EXISTS(SELECT 1 FROM authority_local_bootstrap b JOIN authority_objects o ON o.id=b.pin AND o.sha256=b.sha256 AND o.control_kind='bootstrap' WHERE b.pin=? AND b.sha256=?)",
                [binding.recordID, binding.sha256])
            defer { sqlite3_finalize(s) }
            guard catalogueStep(s) == SQLITE_ROW else { throw graphSQLiteError() }
            return sqlite3_column_int(s, 0) != 0
        }
    }
    func acceptedControlParents(
        _ binding: AuthorityBinding, afterRecordID: String? = nil, limit: Int = 128
    ) throws -> [AuthorityBinding] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit), try hasValidatedAuthorityControl(binding) else {
                throw AtomicAuthorityFormat.invalid("Unknown logical parent source or invalid page.")
            }
            let s = try corpusPrepare(
                "SELECT parent,sha256 FROM authority_control_edges WHERE child=?"
                    + (afterRecordID == nil ? "" : " AND parent>?") + " ORDER BY parent LIMIT ?",
                [binding.recordID] + (afterRecordID.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var parents: [AuthorityBinding] = []
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return parents }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                parents.append(try .init(recordID: atomicQueryText(s, 0), sha256: atomicQueryText(s, 1)))
            }
        }
    }
    /// Genuine support facts, not a target-only projection. Cursor order preserves every distinct
    /// context for atomic roots. A legacy single fact's empty SQL fingerprint is computed exactly
    /// on decode; its target is unique, so advancing by its real digest still excludes that row.
    func acceptedControlSupports(
        _ binding: AuthorityBinding, targetRevisionID: String? = nil,
        after: AuthorityStore.SupportCursor? = nil, limit: Int = 128
    ) throws -> [AuthorityStore.AcceptedSupport] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard (1...1024).contains(limit), try hasValidatedAuthorityControl(binding) else {
                throw AtomicAuthorityFormat.invalid("Unknown accepted support source or invalid page.")
            }
            let s = try corpusPrepare(
                "SELECT target,item,sha256,eligible,actor,policies,causes,evidence,fingerprint FROM authority_control_facts WHERE control=?"
                    + (targetRevisionID == nil ? "" : " AND target=?")
                    + (after == nil ? "" : " AND (target>? OR (target=? AND fingerprint>?))")
                    + " ORDER BY target,fingerprint LIMIT ?",
                [binding.recordID] + (targetRevisionID.map { [$0] } ?? [])
                    + (after.map { [$0.target, $0.target, $0.fingerprint] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var facts: [AuthorityStore.AcceptedSupport] = []
            var bytes = 0
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return facts }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                var rowBytes = 256
                for column in 0..<sqlite3_column_count(s) {
                    let count = Int(sqlite3_column_bytes(s, column))
                    guard count >= 0, count <= graphMaximumPageBytes - min(rowBytes, graphMaximumPageBytes)
                    else {
                        throw TractandaError(
                            "resourceLimit", "One accepted support row exceeds its metadata window.")
                    }
                    rowBytes += count
                }
                if rowBytes > graphMaximumPageBytes - min(bytes, graphMaximumPageBytes) {
                    if !facts.isEmpty { return facts }
                    throw TractandaError("resourceLimit", "One accepted support cannot fit its page.")
                }
                let evidence = try AtomicAuthorityFormat.bindings(
                    AtomicAuthorityFormat.decodeValue(Data(atomicQueryText(s, 7).utf8)))
                guard evidence.count <= 1 else {
                    throw AtomicAuthorityFormat.invalid("Accepted support has extra evidence.")
                }
                let delta = try AuthorityStore.DispositionDelta(
                    target: .init(
                        itemID: atomicQueryText(s, 1), revisionID: atomicQueryText(s, 0),
                        sha256: atomicQueryText(s, 2)),
                    eligible: sqlite3_column_int(s, 3) != 0, actor: atomicQueryText(s, 4),
                    policyIDs: JSON.decode([String].self, Data(atomicQueryText(s, 5).utf8)),
                    causes: JSON.decode([AuthorityBinding].self, Data(atomicQueryText(s, 6).utf8)),
                    evidence: evidence.first)
                try AtomicAuthorityEntryStream.validate(delta.itemValue, section: .effects)
                let fingerprint = AuthorityRecordCodec.sha256(try JSON.encode(delta.itemValue))
                let stored = try atomicQueryText(s, 8)
                guard stored.isEmpty || stored == fingerprint else {
                    throw AtomicAuthorityFormat.invalid(
                        "Accepted support differs from its exact fact fingerprint.")
                }
                facts.append(.init(delta: delta, fingerprint: fingerprint))
                bytes += rowBytes
            }
        }
    }
    func isAcceptedAtomicControl(_ binding: AuthorityBinding) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT EXISTS(SELECT 1 FROM authority_atomic_accepted a JOIN authority_control c ON c.id=a.control AND c.sha256=a.sha256 WHERE a.control=? AND a.sha256=?)",
                [binding.recordID, binding.sha256])
            defer { sqlite3_finalize(s) }
            guard catalogueStep(s) == SQLITE_ROW else { throw graphSQLiteError() }
            return sqlite3_column_int(s, 0) == 1
        }
    }
    func acceptedControlHasParent(_ binding: AuthorityBinding, parent: AuthorityBinding) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try hasValidatedAuthorityControl(binding), try hasValidatedAuthorityControl(parent) else {
                return false
            }
            let s = try corpusPrepare(
                "SELECT EXISTS(SELECT 1 FROM authority_control_edges WHERE child=? AND parent=? AND sha256=?)",
                [binding.recordID, parent.recordID, parent.sha256])
            defer { sqlite3_finalize(s) }
            guard catalogueStep(s) == SQLITE_ROW else { throw graphSQLiteError() }
            return sqlite3_column_int(s, 0) == 1
        }
    }
    private func atomicQueryText(_ s: OpaquePointer, _ column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(s, column))
        guard sqlite3_column_type(s, column) == SQLITE_TEXT, count >= 0,
            count <= AtomicAuthorityFormat.maximumEnvelopeBytes,
            let bytes = sqlite3_column_text(s, column),
            let text = String(data: Data(bytes: bytes, count: count), encoding: .utf8)
        else { throw AtomicAuthorityFormat.invalid("Malformed or non-UTF8 atomic metadata text.") }
        return text
    }
}

// Private, deduplicated affected-item cursor. No descriptor or authority proof is inferred.
extension ItemIndex {
    func atomicAffectedItemPage(token: String, afterID: String?, limit: Int) throws -> [String] {
        try LogicalControlSource.page(-1, limit)
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT object FROM authority_walk WHERE token=? AND object!=''"
                    + (afterID == nil ? "" : " AND object>?") + " ORDER BY object LIMIT ?",
                [token] + (afterID.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var result: [String] = []
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW, sqlite3_column_type(s, 0) == SQLITE_TEXT,
                    sqlite3_column_bytes(s, 0) == 36, let raw = sqlite3_column_text(s, 0),
                    let id = String(data: Data(bytes: raw, count: 36), encoding: .utf8)
                else {
                    throw AtomicAuthorityFormat.invalid("Malformed private affected-item cursor.")
                }
                _ = try AuthorityRecord.persistentID(.text(id))
                result.append(id)
            }
        }
    }
}
