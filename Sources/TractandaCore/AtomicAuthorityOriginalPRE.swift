import CSQLite
import Foundation

/// One target's causal-maximal reduction over the COMPLETE frozen original PRE. Physical parts
/// never seed this walk. Queue-confined, resumable private work; a partial result grants nothing.
/// Store must bind/recheck the source and mutable semantic context before final accepted sealing.
final class AtomicAuthorityOriginalPRE {
    private let index: ItemIndex
    private let source: LogicalControlSource
    private let target: AuthorityStore.Target
    private let token: String
    private var closed = false
    private var failed = false
    private var seeding = true
    private var parentCursor: Int64 = -1
    private var seedPage: [(ordinal: Int64, binding: AuthorityBinding)] = []
    private var seedOffset = 0
    private var active: (id: String, ordinal: Int64, covered: Bool, parent: String?)?
    private var sawEligible = false
    private var sawHeld = false
    private var result: AuthorityStore.HistoricalEligibility?
    private var targetAbsentEverywhere = false
    private var absenceChecked = false
    private(set) var processedUnits: Int64 = 0

    init(index: ItemIndex, source: LogicalControlSource, target: AuthorityStore.Target) throws {
        self.index = index
        self.source = source
        self.target = target
        token = "atomic-pre:" + (try UUID.makeVersion1().uuidString.lowercased())
        try index.authorityBeginWalk(token: token)
    }
    deinit { try? close() }

    /// A nil result is an explicit private-work yield, not invalid authority or completion.
    /// The caller ends its native work scope and resumes with fresh current-context checks.
    /// Nested calls consume their enclosing budget; this method never resets that allowance.
    func step(maximumUnits: Int = 64) throws -> AuthorityStore.HistoricalEligibility? {
        guard !closed, !failed, (1...1024).contains(maximumUnits) else {
            throw AtomicAuthorityFormat.invalid("Closed/failed original-PRE walk or invalid window.")
        }
        if let result { return result }
        do {
            return try index.withCatalogueScanBudget(reusingActiveBudget: true) {
                if !absenceChecked {
                    let query = try index.corpusPrepare(
                        "SELECT EXISTS(SELECT 1 FROM authority_control_outcomes WHERE target=? LIMIT 1) OR EXISTS(SELECT 1 FROM authority_dependencies WHERE source=? AND kind='bootstrap' LIMIT 1)",
                        [target.revisionID, target.revisionID])
                    defer { sqlite3_finalize(query) }
                    guard index.catalogueStep(query) == SQLITE_ROW else { throw index.graphSQLiteError() }
                    targetAbsentEverywhere = sqlite3_column_int(query, 0) == 0
                    absenceChecked = true
                    if targetAbsentEverywhere {
                        // No accepted opinion or baseline anywhere can mention this revision.
                        // This proves UNKNOWN, never eligibility, local admission or PRE membership.
                        result = .unknown
                        return result
                    }
                }
                var units = 0
                while units < maximumUnits {
                    guard try index.atomicPrivateWindowHasRoom() else { return nil }
                    if seeding {
                        if seedOffset == seedPage.count {
                            seedPage = try source.parents(
                                index: index, afterOrdinal: parentCursor, limit: 128)
                            seedOffset = 0
                            if seedPage.isEmpty {
                                seeding = false
                                continue
                            }
                        }
                        let parent = seedPage[seedOffset]
                        try enqueue(parent.binding, covered: false, beforeOrdinal: nil)
                        parentCursor = parent.ordinal
                        seedOffset += 1
                    } else if let node = active {
                        let page = try index.acceptedControlParents(
                            .init(recordID: node.id, sha256: controlDigest(node.id)),
                            afterRecordID: node.parent, limit: 1)
                        if let parent = page.first {
                            try enqueue(parent, covered: node.covered, beforeOrdinal: node.ordinal)
                            active = (node.id, node.ordinal, node.covered, parent.recordID)
                        } else {
                            try index.execute(
                                "UPDATE authority_control_work SET processed=1 WHERE token=? AND id=?",
                                [token, node.id])
                            active = nil
                        }
                    } else if let node = try next() {
                        var covered = node.covered
                        if !covered, let eligible = try directOutcome(node.id) {
                            sawEligible = sawEligible || eligible
                            sawHeld = sawHeld || !eligible
                            covered = true
                        } else if !covered, try bootstrapIncludesTarget(node.id) {
                            sawEligible = true
                            covered = true
                        }
                        active = (node.id, node.ordinal, covered, nil)
                    } else {
                        result = sawHeld ? .held : (sawEligible ? .eligible : .unknown)
                        return result
                    }
                    units += 1
                    processedUnits = try AtomicAuthorityFormat.sum(processedUnits, 1)
                }
                return nil
            }
        } catch {
            failed = true
            throw error
        }
    }
    /// Exact accepted ancestor membership in the COMPLETE original PRE, available only after
    /// its causal walk completes. This reuses its bounded private work rather than materializing
    /// every parent or rerunning the whole ancestry walk for each policy transition.
    func contains(_ binding: AuthorityBinding) throws -> Bool {
        guard result != nil, !closed, !failed else {
            throw AtomicAuthorityFormat.invalid("Original PRE ancestor closure is incomplete.")
        }
        return try index.withCatalogueScanBudget(reusingActiveBudget: true) {
            if targetAbsentEverywhere {
                // A disposition shortcut must not invent membership answers. Check the exact
                // accepted parent bindings, then use the existing ancestry validator on demand.
                var cursor: Int64 = -1
                while true {
                    let parents = try source.parents(index: index, afterOrdinal: cursor, limit: 128)
                    if parents.isEmpty { break }
                    for parent in parents {
                        cursor = parent.ordinal
                        if parent.binding == binding { return true }
                    }
                }
                cursor = -1
                while true {
                    let parents = try source.parents(index: index, afterOrdinal: cursor, limit: 128)
                    if parents.isEmpty { return false }
                    for parent in parents {
                        cursor = parent.ordinal
                        if try index.authorityControlContains(binding, in: parent.binding) { return true }
                    }
                }
            }
            let s = try index.corpusPrepare(
                "SELECT EXISTS(SELECT 1 FROM authority_control_work w JOIN authority_control c ON c.id=w.id WHERE w.token=? AND w.id=? AND c.sha256=?)",
                [token, binding.recordID, binding.sha256])
            defer { sqlite3_finalize(s) }
            guard index.catalogueStep(s) == SQLITE_ROW else { throw index.graphSQLiteError() }
            return sqlite3_column_int(s, 0) != 0
        }
    }
    func close() throws {
        guard !closed else { return }
        try index.execute("DELETE FROM authority_control_work WHERE token=?", [token])
        try index.authorityEndWalk(token: token)
        closed = true
    }
    private func enqueue(_ binding: AuthorityBinding, covered: Bool, beforeOrdinal: Int64?) throws {
        let s = try index.corpusPrepare(
            "SELECT ordinal FROM authority_control WHERE id=? AND sha256=?",
            [binding.recordID, binding.sha256])
        let status = index.catalogueStep(s)
        guard status == SQLITE_ROW else {
            sqlite3_finalize(s)
            if status != SQLITE_DONE { throw index.graphSQLiteError() }
            throw AtomicAuthorityFormat.invalid("Original PRE contains an unaccepted control binding.")
        }
        let ordinal = sqlite3_column_int64(s, 0)
        sqlite3_finalize(s)
        guard beforeOrdinal.map({ ordinal < $0 }) ?? true else {
            throw AtomicAuthorityFormat.invalid(
                "Original PRE has a causal cycle/nondecreasing parent ordinal.")
        }
        if try index.authorityVisitOnce(token: token, id: binding.recordID) {
            try index.execute(
                "INSERT INTO authority_control_work VALUES(?,?,?,?,0)",
                [token, binding.recordID, String(ordinal), covered ? "1" : "0"])
        } else if covered {
            try index.execute(
                "UPDATE authority_control_work SET covered=1 WHERE token=? AND id=?",
                [token, binding.recordID])
        }
    }
    private func next() throws -> (id: String, ordinal: Int64, covered: Bool)? {
        let s = try index.corpusPrepare(
            "SELECT id,ordinal,covered FROM authority_control_work WHERE token=? AND processed=0 ORDER BY ordinal DESC,id LIMIT 1",
            [token])
        defer { sqlite3_finalize(s) }
        let status = index.catalogueStep(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw index.graphSQLiteError() }
        return try (text(s, 0), sqlite3_column_int64(s, 1), sqlite3_column_int(s, 2) != 0)
    }
    private func controlDigest(_ id: String) throws -> String {
        let s = try index.corpusPrepare("SELECT sha256 FROM authority_control WHERE id=?", [id])
        defer { sqlite3_finalize(s) }
        guard index.catalogueStep(s) == SQLITE_ROW else { throw index.graphSQLiteError() }
        return try text(s, 0)
    }
    private func directOutcome(_ id: String) throws -> Bool? {
        let s = try index.corpusPrepare(
            "SELECT item,sha256,eligible FROM authority_control_outcomes WHERE control=? AND target=?",
            [id, target.revisionID])
        defer { sqlite3_finalize(s) }
        let status = index.catalogueStep(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, try text(s, 0) == target.itemID, try text(s, 1) == target.sha256 else {
            throw AtomicAuthorityFormat.invalid("Original PRE outcome changed exact target identity.")
        }
        let eligible = sqlite3_column_int(s, 2) != 0
        guard index.catalogueStep(s) == SQLITE_DONE else {
            throw AtomicAuthorityFormat.invalid("One logical control has duplicate reduced outcomes.")
        }
        return eligible
    }
    private func bootstrapIncludesTarget(_ id: String) throws -> Bool {
        let s = try index.corpusPrepare(
            "SELECT EXISTS(SELECT 1 FROM authority_control c JOIN authority_dependencies d ON d.target=c.bootstrap AND d.sha256=c.bootstrap_digest AND d.kind='bootstrap' JOIN authority_objects o ON o.id=d.source WHERE c.id=? AND d.source=? AND o.item=? AND o.sha256=?)",
            [id, target.revisionID, target.itemID, target.sha256])
        defer { sqlite3_finalize(s) }
        guard index.catalogueStep(s) == SQLITE_ROW else { throw index.graphSQLiteError() }
        return sqlite3_column_int(s, 0) == 1
    }
    private func text(_ s: OpaquePointer, _ column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(s, column))
        guard sqlite3_column_type(s, column) == SQLITE_TEXT, count >= 0,
            count <= AtomicAuthorityFormat.maximumEnvelopeBytes,
            let bytes = sqlite3_column_text(s, column),
            let text = String(data: Data(bytes: bytes, count: count), encoding: .utf8)
        else { throw AtomicAuthorityFormat.invalid("Malformed or non-UTF8 atomic metadata text.") }
        return text
    }
}
