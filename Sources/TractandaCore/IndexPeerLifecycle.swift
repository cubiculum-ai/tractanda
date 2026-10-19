import CSQLite
import Foundation

extension ItemIndex {
    func initializePeerLifecycleSchema() throws {
        try requireGraphCapacity(additionalBytes: 32 * 1024)
        try initializeAuthorityReviewSchema()
        try execute(
            "CREATE TABLE IF NOT EXISTS peer_lifecycle_retired(origin TEXT NOT NULL,retirement TEXT NOT NULL,digest TEXT NOT NULL,effective INTEGER NOT NULL,PRIMARY KEY(origin,retirement))"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS peer_lifecycle_cutoff ON peer_lifecycle_retired(origin,effective,retirement)"
        )
    }
    func initializePeerRetirementEffects() throws {
        try execute(
            "CREATE TABLE IF NOT EXISTS peer_lifecycle_decision(id TEXT PRIMARY KEY,digest TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS peer_lifecycle_effect(object TEXT PRIMARY KEY)")
        try execute("CREATE TABLE IF NOT EXISTS peer_lifecycle_recheck(object TEXT PRIMARY KEY)")
    }
    func clearPeerLifecycle() throws {
        try initializePeerLifecycleSchema()
        try initializePeerRetirementEffects()
        try execute("DELETE FROM peer_lifecycle_retired")
        try execute("DELETE FROM peer_lifecycle_decision")
    }
    func retainPeerRetirement(_ binding: AuthorityBinding, origins: [String], effectiveAt: String) throws {
        try requireGraphCapacity(additionalBytes: UInt64(origins.count + 1) * 8192)
        let ticks = try RevisionTimestamp(effectiveAt).ticks
        for origin in origins {
            try execute(
                "INSERT OR IGNORE INTO peer_lifecycle_retired VALUES(?,?,?,?)",
                [origin, binding.recordID, binding.sha256, String(ticks)])
        }
    }
    private func lifecycleExists(_ sql: String, _ bindings: [String]) throws -> Bool {
        let statement = try corpusPrepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW else { throw graphSQLiteError() }
        return sqlite3_column_int(statement, 0) == 1
    }
    func peerOriginRetired(_ origin: String) throws -> Bool {
        try lifecycleExists("SELECT EXISTS(SELECT 1 FROM peer_lifecycle_retired WHERE origin=?)", [origin])
    }
    func peerRetirementCauses(revisionID: String, origin: String) throws -> [AuthorityBinding] {
        let ticks = try PeerLifecycle.revisionTicks(revisionID)
        let statement = try corpusPrepare(
            "SELECT retirement,digest FROM peer_lifecycle_retired WHERE origin=? AND effective<=CAST(? AS INTEGER) UNION SELECT r.retirement,r.digest FROM authority_review_applied a INDEXED BY authority_review_resolution JOIN authority_objects d ON d.id=a.decision AND d.sha256=a.sha256 JOIN peer_lifecycle_retired r ON r.origin=d.origin AND r.effective<d.issued WHERE a.revision=? AND a.recovery=0 ORDER BY retirement",
            [origin, String(ticks), revisionID])
        defer { sqlite3_finalize(statement) }
        var result: [AuthorityBinding] = []
        while true {
            try checkCatalogueScanProgress()
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            guard result.count < 256, let id = sqlite3_column_text(statement, 0),
                let digest = sqlite3_column_text(statement, 1)
            else {
                throw TractandaError("resourceLimit", "Retirement cause window exceeded.")
            }
            result.append(try .init(recordID: String(cString: id), sha256: String(cString: digest)))
        }
    }
    /// A complete, applied exact review must cover every presently applicable removal.
    /// A later learned root cannot be bypassed by an older generic reviewed flag.
    func peerReviewCoversCurrentRetirements(
        revisionID: String, origin: String, covered: [AuthorityBinding]
    ) throws -> Bool {
        let required = try peerRetirementCauses(revisionID: revisionID, origin: origin)
        return Set(required).isSubset(of: Set(covered))
    }
    func peerLifecycleHasFreshReview(_ revisionID: String, causes: [AuthorityBinding]) throws -> Bool {
        guard !causes.isEmpty,
            try lifecycleExists(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='authority_review_applied')",
                [])
        else { return false }
        let statement = try corpusPrepare(
            "SELECT e.id FROM authority_review_applied a JOIN authority_review_event e ON e.id=a.decision AND e.sha256=a.sha256 WHERE a.recovery=0 AND e.target=? ORDER BY e.id",
            [revisionID])
        defer { sqlite3_finalize(statement) }
        var work = 0
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return false }
            guard status == SQLITE_ROW, let id = sqlite3_column_text(statement, 0) else {
                throw graphSQLiteError()
            }
            work += 1
            try checkCatalogueScanProgress()
            guard work <= 4096 else {
                throw TractandaError("resourceLimit", "Retirement review window exceeded.")
            }
            let decision = String(cString: id)
            guard try peerAuthorityIssuerPermits(decision) else { continue }
            if try causes.allSatisfy({ cause in
                try lifecycleExists(
                    "SELECT EXISTS(SELECT 1 FROM authority_dependencies WHERE source=? AND kind='retirements' AND target=? AND sha256=?)",
                    [decision, cause.recordID, cause.sha256])
            }) {
                return true
            }
        }
    }
    func peerRetirementIsActive(_ binding: AuthorityBinding) throws -> Bool {
        try lifecycleExists(
            "SELECT EXISTS(SELECT 1 FROM peer_lifecycle_retired WHERE retirement=? AND digest=?)",
            [binding.recordID, binding.sha256])
    }
    func peerRetirementRootPage(after: String? = nil) throws -> [AuthorityStore.RetainedObject] {
        // Direct indexed-kind candidates, no whole-store in-memory graph.
        try authorityKindPage(kind: "originRetirement", after: after)
    }

    func peerAuthorityIssuerPermits(_ recordID: String) throws -> Bool {
        let statement = try corpusPrepare(
            "SELECT origin,issued FROM authority_objects WHERE id=? AND kind='authority'", [recordID])
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
            return false
        }
        return try peerAuthorityTimePermits(
            origin: String(cString: raw), ticks: sqlite3_column_int64(statement, 1))
    }
    func peerAuthorityTimePermits(origin: String, ticks: Int64) throws -> Bool {
        try !lifecycleExists(
            "SELECT EXISTS(SELECT 1 FROM peer_lifecycle_retired WHERE origin=? AND effective<CAST(? AS INTEGER))",
            [origin, String(ticks)])
    }
    func peerRetirementActiveBindings() throws -> [AuthorityBinding] {
        let statement = try corpusPrepare(
            "SELECT DISTINCT retirement,digest FROM peer_lifecycle_retired ORDER BY retirement")
        defer { sqlite3_finalize(statement) }
        var result: [AuthorityBinding] = []
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let id = sqlite3_column_text(statement, 0),
                let digest = sqlite3_column_text(statement, 1), result.count < 512
            else { throw TractandaError("resourceLimit", "Active retirement proof window exceeded.") }
            result.append(try .init(recordID: String(cString: id), sha256: String(cString: digest)))
        }
    }
    func peerRetirementOriginPage(after: String? = nil) throws -> [(String, Int64)] {
        let statement = try corpusPrepare(
            "SELECT origin,MIN(effective) FROM peer_lifecycle_retired"
                + (after == nil ? "" : " WHERE origin>?") + " GROUP BY origin ORDER BY origin LIMIT 128",
            after.map { [$0] } ?? [])
        defer { sqlite3_finalize(statement) }
        var result: [(String, Int64)] = []
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let origin = sqlite3_column_text(statement, 0) else {
                throw graphSQLiteError()
            }
            result.append((String(cString: origin), sqlite3_column_int64(statement, 1)))
        }
    }
    /// Control identities and C identities are issued separately. Follow exact completed
    /// D→B/C bindings even when C's own UUID precedes the issuer's removal event.
    func peerRetiredReviewPage(origin: String, cutoff: Int64, after: (Int64, String)? = nil) throws
        -> [(decision: String, issued: Int64, item: String, target: String, resolution: String)]
    {
        let statement = try corpusPrepare(
            "SELECT d.id,d.issued,e.item,e.target,a.revision FROM authority_objects d INDEXED BY authority_origin_issued JOIN authority_review_applied a ON a.decision=d.id AND a.sha256=d.sha256 AND a.recovery=0 JOIN authority_review_event e ON e.id=a.decision AND e.sha256=a.sha256 WHERE d.origin=? AND d.issued>CAST(? AS INTEGER) AND d.control_kind='reviewDecision'"
                + (after == nil ? "" : " AND (d.issued,d.id)>(CAST(? AS INTEGER),?)")
                + " ORDER BY d.issued,d.id LIMIT 128",
            [origin, String(cutoff)] + (after.map { [String($0.0), $0.1] } ?? []))
        defer { sqlite3_finalize(statement) }
        var result: [(String, Int64, String, String, String)] = []
        while true {
            try checkCatalogueScanProgress()
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            func text(_ column: Int32) throws -> String {
                guard let value = sqlite3_column_text(statement, column) else { throw graphSQLiteError() }
                return String(cString: value)
            }
            result.append(
                (try text(0), sqlite3_column_int64(statement, 1), try text(2), try text(3), try text(4)))
        }
    }
    func notePeerRetirementEffect(_ id: String) throws {
        try requireGraphCapacity(additionalBytes: 8192)
        try execute("INSERT OR IGNORE INTO peer_lifecycle_effect VALUES(?)", [id])
    }
    func resetPeerRetirementEffects() throws {
        try execute("INSERT OR IGNORE INTO peer_lifecycle_recheck SELECT object FROM peer_lifecycle_effect")
        try execute(
            "UPDATE authority_dispositions SET state='pending',reason='Reevaluate timestamp retirement effects under complete current proof.' WHERE state='held' AND object IN(SELECT object FROM peer_lifecycle_effect)"
        )
        try execute(
            "UPDATE authority_packages SET pending=permitted AND (SELECT state IN('pending','missingDependencies') FROM authority_dispositions WHERE object=authority_packages.object) WHERE object IN(SELECT object FROM peer_lifecycle_effect)"
        )
        try execute("DELETE FROM peer_lifecycle_effect")
    }

    func peerRetirementRecheckContains(_ id: String) throws -> Bool {
        try lifecycleExists("SELECT EXISTS(SELECT 1 FROM peer_lifecycle_recheck WHERE object=?)", [id])
    }
    func peerRetirementRecheckPackagePage(after: String? = nil) throws -> [String] {
        let statement = try corpusPrepare(
            "SELECT DISTINCT p.package FROM peer_lifecycle_recheck q JOIN authority_packages p ON p.object=q.object WHERE p.permitted=1"
                + (after == nil ? "" : " AND p.package>?") + " ORDER BY p.package LIMIT 128",
            after.map { [$0] } ?? [])
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let id = sqlite3_column_text(statement, 0) else {
                throw graphSQLiteError()
            }
            result.append(String(cString: id))
        }
    }
    func finishPeerRetirementRecheck(packageID: String) throws {
        try execute(
            "DELETE FROM peer_lifecycle_recheck WHERE object IN(SELECT p.object FROM authority_packages p JOIN authority_dispositions d ON d.object=p.object WHERE p.package=? AND d.state NOT IN('pending','missingDependencies'))",
            [packageID])
    }

    func retainPeerRetirementProof(_ binding: AuthorityBinding) throws {
        try execute("INSERT INTO peer_lifecycle_decision VALUES(?,?)", [binding.recordID, binding.sha256])
    }
    func peerRetirementHasValidatedProof(_ binding: AuthorityBinding) throws -> Bool {
        try lifecycleExists(
            "SELECT EXISTS(SELECT 1 FROM peer_lifecycle_decision WHERE id=? AND digest=?)",
            [binding.recordID, binding.sha256])
    }

}
