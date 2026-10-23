import CSQLite
import Foundation

/// Disposable, bounded work rows. The private export journal owns every transition.
extension ItemIndex {
    func initializePeerExportSchema() throws {
        try requireGraphCapacity(additionalBytes: 32 * 1024)
        try execute("CREATE TABLE IF NOT EXISTS peer_export_plan(id TEXT PRIMARY KEY,state TEXT NOT NULL)")
        try execute(
            "CREATE TABLE IF NOT EXISTS peer_export_object(plan TEXT NOT NULL,id TEXT NOT NULL,status TEXT NOT NULL,root INTEGER NOT NULL,slot TEXT NOT NULL,PRIMARY KEY(plan,id))"
        )
        try execute("CREATE INDEX IF NOT EXISTS peer_export_ready ON peer_export_object(plan,status,id)")
        try prepareExportDependencyIndex()
        try execute(
            "CREATE TABLE IF NOT EXISTS peer_export_page(plan TEXT NOT NULL,level INTEGER NOT NULL,ordinal INTEGER NOT NULL,descriptor TEXT NOT NULL,PRIMARY KEY(plan,level,ordinal))"
        )
    }
    private func hasExportDependencyIndex() throws -> Bool {
        let s = try corpusPrepare(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='index' AND name='authority_dependencies_export' AND tbl_name='authority_dependencies')"
        )
        defer { sqlite3_finalize(s) }
        guard catalogueStep(s) == SQLITE_ROW else { throw graphSQLiteError() }
        return sqlite3_column_int(s, 0) != 0
    }
    private func prepareExportDependencyIndex() throws {
        // A warm index never rescans historical dependencies or rebuilds transient sort work.
        guard try !hasExportDependencyIndex() else { return }
        let estimate: UInt64 = try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT COALESCE(SUM(length(CAST(source AS BLOB))+length(CAST(package AS BLOB))+length(CAST(kind AS BLOB))+length(CAST(target AS BLOB))+length(CAST(sha256 AS BLOB))+192),0) FROM authority_dependencies"
            )
            defer { sqlite3_finalize(s) }
            guard catalogueStep(s) == SQLITE_ROW, sqlite3_column_type(s, 0) == SQLITE_INTEGER,
                sqlite3_column_int64(s, 0) >= 0
            else { throw graphSQLiteError() }
            return UInt64(sqlite3_column_int64(s, 0))
        }
        // Cover index pages, fragmentation, sort and WAL copies before creating build products.
        let copies = estimate.multipliedReportingOverflow(by: 6)
        let working = copies.partialValue.addingReportingOverflow(32 * 1024)
        guard !copies.overflow, !working.overflow, working.partialValue <= graphMaximumTemporaryBytes else {
            throw TractandaError(
                "resourceLimit", "Dependency export index exceeds its bounded build storage allowance.")
        }
        try requireGraphCapacity(additionalBytes: working.partialValue)
        // Fixed derived-schema DDL only; execute() must not discard accepted graph proofs.
        try installAtomicAuthorityIndexSchema(.dependencyExport)
        guard try hasExportDependencyIndex() else {
            throw TractandaError("indexError", "Dependency export index installation did not complete.")
        }
    }
    private func exportText(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= PeerPackage.maximumPageBytes, let pointer = sqlite3_column_text(statement, column),
            let value = String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8)
        else { throw TractandaError("invalidPeerExport", "Invalid export work metadata.") }
        return value
    }
    func peerExportState(_ id: String) throws -> PeerExportPlan.State? {
        let s = try corpusPrepare("SELECT state FROM peer_export_plan WHERE id=?", [id])
        defer { sqlite3_finalize(s) }
        let status = catalogueStep(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw graphSQLiteError() }
        return try PeerPackage.decode(PeerExportPlan.State.self, Data(exportText(s, 0).utf8))
    }
    func peerExportInsert(_ id: String, state: PeerExportPlan.State) throws {
        try requireGraphCapacity(additionalBytes: 8192)
        try execute(
            "INSERT INTO peer_export_plan VALUES(?,?)",
            [id, String(decoding: try JSON.encode(state), as: UTF8.self)])
    }
    func peerExportSlot(_ plan: String, id: String) throws -> PeerExportPlan.Slot? {
        let s = try corpusPrepare("SELECT slot FROM peer_export_object WHERE plan=? AND id=?", [plan, id])
        defer { sqlite3_finalize(s) }
        let status = catalogueStep(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw graphSQLiteError() }
        return try PeerPackage.decode(PeerExportPlan.Slot.self, Data(exportText(s, 0).utf8))
    }
    func peerExportSlots(_ plan: String, status: String? = nil, after: String = "", limit: Int = 128) throws
        -> [PeerExportPlan.Slot]
    {
        guard (1...128).contains(limit) else {
            throw TractandaError("resourceLimit", "Invalid export page size.")
        }
        let s = try corpusPrepare(
            "SELECT slot FROM peer_export_object WHERE plan=? AND id>?"
                + (status == nil ? "" : " AND status=?") + " ORDER BY id LIMIT ?",
            [plan, after] + (status.map { [$0] } ?? []) + [String(limit)])
        defer { sqlite3_finalize(s) }
        var result: [PeerExportPlan.Slot] = []
        while true {
            try checkCatalogueScanProgress()
            let status = catalogueStep(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            result.append(try PeerPackage.decode(PeerExportPlan.Slot.self, Data(exportText(s, 0).utf8)))
        }
    }
    func peerExportCount(_ plan: String, status: String? = nil) throws -> Int {
        let s = try corpusPrepare(
            "SELECT COUNT(*) FROM peer_export_object WHERE plan=?" + (status == nil ? "" : " AND status=?"),
            [plan] + (status.map { [$0] } ?? []))
        defer { sqlite3_finalize(s) }
        guard catalogueStep(s) == SQLITE_ROW else { throw graphSQLiteError() }
        return Int(sqlite3_column_int64(s, 0))
    }
    func peerExportPages(_ plan: String, level: Int, after: Int, limit: Int) throws -> [(
        Int, PeerPackage.Object
    )] {
        guard (1...128).contains(limit) else {
            throw TractandaError("resourceLimit", "Invalid export index size.")
        }
        let s = try corpusPrepare(
            "SELECT ordinal,descriptor FROM peer_export_page WHERE plan=? AND level=? AND ordinal>? ORDER BY ordinal LIMIT ?",
            [plan, String(level), String(after), String(limit)])
        defer { sqlite3_finalize(s) }
        var result: [(Int, PeerPackage.Object)] = []
        while true {
            try checkCatalogueScanProgress()
            let status = catalogueStep(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            result.append(
                (
                    Int(sqlite3_column_int64(s, 0)),
                    try PeerPackage.decode(PeerPackage.Object.self, Data(exportText(s, 1).utf8))
                ))
        }
    }
    func peerExportApply(_ plan: String, event: PeerExportPlan.Event) throws {
        try requireGraphCapacity(additionalBytes: UInt64(event.slots.count + event.pages.count + 1) * 8192)
        try execute("SAVEPOINT peer_export_apply")
        do {
            for slot in event.slots {
                try execute(
                    "INSERT INTO peer_export_object VALUES(?,?,?,?,?) ON CONFLICT(plan,id) DO UPDATE SET status=excluded.status,root=excluded.root,slot=excluded.slot",
                    [
                        plan, slot.id, slot.status.rawValue, slot.root ? "1" : "0",
                        String(decoding: try JSON.encode(slot), as: UTF8.self),
                    ])
            }
            for page in event.pages {
                try execute(
                    "INSERT INTO peer_export_page VALUES(?,?,?,?)",
                    [
                        plan, String(page.level), String(page.ordinal),
                        String(decoding: try JSON.encode(page.descriptor), as: UTF8.self),
                    ])
            }
            var state = event.next
            state.digest = AuthorityRecordCodec.sha256(try JSON.encode(event))
            try execute(
                "UPDATE peer_export_plan SET state=? WHERE id=?",
                [String(decoding: try JSON.encode(state), as: UTF8.self), plan])
            try execute("RELEASE peer_export_apply")
        } catch {
            try? execute("ROLLBACK TO peer_export_apply")
            try? execute("RELEASE peer_export_apply")
            throw error
        }
    }
    /// Existing normalized direct edges only; no recursive graph/authority evaluation.
    func peerExportDependencies(_ id: String, after: String, limit: Int) throws -> [PeerExportPlan.Reference]
    {
        guard (1...128).contains(limit) else {
            throw TractandaError("resourceLimit", "Invalid export edge page.")
        }
        _ = try AuthorityRecord.persistentID(.text(id))
        let cursor: [String]
        if after.isEmpty {
            cursor = ["", "", ""]
        } else {
            guard after.utf8.count <= 128 + 1 + 36 + 1 + 64 else {
                throw TractandaError(
                    "invalidPeerExport", "Dependency continuation exceeds its bounded representation.")
            }
            cursor = after.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(
                String.init)
            guard cursor.count == 3 else {
                throw TractandaError("invalidPeerExport", "Malformed dependency continuation.")
            }
            try validateExportDependency(kind: cursor[0], target: cursor[1], digest: cursor[2])
        }
        let s = try corpusPrepare(
            "SELECT kind,target,sha256 FROM authority_dependencies INDEXED BY authority_dependencies_export WHERE source=? AND package='' AND (kind,target,sha256)>(?,?,?) ORDER BY kind,target,sha256 LIMIT ?",
            [id] + cursor + [String(limit)])
        defer { sqlite3_finalize(s) }
        var result: [PeerExportPlan.Reference] = []
        while true {
            try checkCatalogueScanProgress()
            let status = catalogueStep(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            let kind = try exportText(s, 0)
            let target = try exportText(s, 1)
            let digest = try exportText(s, 2)
            try validateExportDependency(kind: kind, target: target, digest: digest)
            result.append(
                .init(
                    id: target, kind: nil, digest: digest.isEmpty ? nil : digest,
                    cursor: kind + ":" + target + ":" + digest))
        }
    }
    private func validateExportDependency(kind: String, target: String, digest: String) throws {
        // Every normalized kind is an ASCII field/name. With letters above ':' in byte order,
        // tuple order is identical to the retained kind:UUID:sha cursor, including kind prefixes.
        guard !kind.isEmpty, kind.utf8.count <= 128,
            kind.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) })
        else { throw TractandaError("invalidPeerExport", "Invalid normalized dependency kind.") }
        _ = try AuthorityRecord.persistentID(.text(target))
        if !digest.isEmpty { _ = try AuthorityRecord.digest(.text(digest)) }
    }
    /// Stable across reopen and ordinary publication, changed by actual active global policy.
    func peerExportPolicyBinding() throws -> [String] {
        let s = try corpusPrepare(
            "SELECT p.revision,r.digest FROM current_policy p JOIN revision_catalog r ON r.revision=p.revision WHERE p.class=? ORDER BY p.revision LIMIT 65",
            [AccessConfiguration.classID])
        defer { sqlite3_finalize(s) }
        var result: [String] = []
        while true {
            let status = catalogueStep(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            guard result.count < 64 else {
                throw TractandaError("resourceLimit", "Active export policy binding exceeds its window.")
            }
            result.append(try exportText(s, 0) + ":" + exportText(s, 1).lowercased())
        }
    }
    func peerExportWitnesses(_ id: String, boundary: PeerInventory.Boundary, after: String, limit: Int) throws
        -> [PeerExportPlan.Reference]
    {
        let maximum = PeerInventory.exportMaximumSequence(boundary)
        let sql =
            "SELECT DISTINCT o.id,o.sha256 FROM authority_objects o JOIN (SELECT control AS id FROM authority_control_outcomes WHERE target=? UNION SELECT id FROM authority_exposure WHERE revision=? UNION SELECT id FROM authority_review_event WHERE target=? UNION SELECT r.retirement AS id FROM authority_objects t JOIN peer_lifecycle_retired r ON r.origin=t.origin AND r.effective<=t.issued WHERE t.id=? UNION SELECT r.retirement AS id FROM authority_review_applied a INDEXED BY authority_review_resolution JOIN authority_objects d ON d.id=a.decision AND d.sha256=a.sha256 JOIN peer_lifecycle_retired r ON r.origin=d.origin AND r.effective<d.issued WHERE a.revision=? AND a.recovery=0) w ON w.id=o.id WHERE o.id>? AND EXISTS(SELECT 1 FROM peer_inventory_receipt i WHERE i.object=o.id AND i.sequence<=?) ORDER BY o.id LIMIT ?"
        let s = try corpusPrepare(sql, [id, id, id, id, id, after, String(maximum), String(limit)])
        defer { sqlite3_finalize(s) }
        var result: [PeerExportPlan.Reference] = []
        while true {
            try checkCatalogueScanProgress()
            let status = catalogueStep(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            let target = try exportText(s, 0)
            result.append(.init(id: target, kind: .authority, digest: try exportText(s, 1), cursor: target))
        }
    }

}
