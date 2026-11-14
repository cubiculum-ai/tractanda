import CSQLite
import Crypto
import Foundation

/// Disposable, local synchronization metadata. Canonical files remain the sole authority.
extension ItemIndex {
    struct ChangePolicy: Codable, Equatable {
        let classID: String
        let permissions: ItemValue?
    }
    struct ChangeRepresentation: Codable, Equatable {
        let revisionID: String?
        let resolution: ItemState?
        let policies: [ChangePolicy]
        let policiesComplete: Bool
        var signature: String {
            get throws {
                let bytes = try resolution.map { try JSON.encode($0) } ?? Data()
                return (revisionID ?? "") + ":" + Data(SHA256.hash(data: bytes)).base64EncodedString()
            }
        }
    }
    struct ChangePrincipalBinding: Codable, Equatable {
        let id: UInt32?
    }
    struct ChangeToken: Codable {
        let token: String
        let epoch: String
        var sequence: Int64
        let scope: String
        var users: [String: ChangePrincipalBinding]
        var groups: [String: ChangePrincipalBinding]
        let planID: String?
        let position: Int
        let issuedAt: Double
    }
    struct ChangePlan {
        let id: String
        let epoch: String
        let scope: String
        let base: Int64
        let target: Int64
        let targetToken: String
        let count: Int
        let issuedAt: Double
    }
    struct ChangePlanEntry {
        let itemID: String
        let kind: String
    }
    struct ChangeBounds {
        let epoch: String
        let floor: Int64
        let head: Int64
    }
    struct ChangeCandidate {
        let itemID: String
        let old: ChangeRepresentation?
        var new: ChangeRepresentation?
    }
    static let itemChangesMaximumRows = 100_000
    static let itemChangesMaximumBytes = 64 * 1024 * 1024
    static let itemChangesMaximumAge: Double = 30 * 24 * 60 * 60
    static let itemChangesPlanMaximumRows = 100_000
    static let itemChangesPlanMaximumBytes = 64 * 1024 * 1024
    static let itemChangesTokenMaximumBytes = 256 * 1024
    static let itemChangesTokenTotalBytes = 64 * 1024 * 1024
    static var itemChangesSchemaSQL: [String] {
        var sql = [
            "CREATE TABLE IF NOT EXISTS item_changes_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS item_changes_current(item TEXT PRIMARY KEY,representation TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS item_changes_dirty(item TEXT PRIMARY KEY)",
            "CREATE TABLE IF NOT EXISTS item_changes_journal(sequence INTEGER PRIMARY KEY AUTOINCREMENT,item TEXT NOT NULL,old TEXT NOT NULL,new TEXT NOT NULL,bytes INTEGER NOT NULL,created REAL NOT NULL)",
            "CREATE INDEX IF NOT EXISTS item_changes_journal_item ON item_changes_journal(item,sequence)",
            "CREATE INDEX IF NOT EXISTS item_changes_journal_age ON item_changes_journal(created,sequence)",
            "CREATE TABLE IF NOT EXISTS item_changes_tokens(token TEXT PRIMARY KEY,scope TEXT NOT NULL,sequence INTEGER NOT NULL,final INTEGER NOT NULL,plan TEXT NOT NULL,record TEXT NOT NULL,bytes INTEGER NOT NULL,created REAL NOT NULL)",
            "CREATE INDEX IF NOT EXISTS item_changes_token_scope ON item_changes_tokens(scope,final,sequence)",
            "CREATE INDEX IF NOT EXISTS item_changes_token_age ON item_changes_tokens(created)",
            "CREATE TABLE IF NOT EXISTS item_changes_plans(plan TEXT PRIMARY KEY,epoch TEXT NOT NULL,scope TEXT NOT NULL,base_sequence INTEGER NOT NULL,target_sequence INTEGER NOT NULL,target_token TEXT NOT NULL,count INTEGER NOT NULL,bytes INTEGER NOT NULL,created REAL NOT NULL)",
            "CREATE INDEX IF NOT EXISTS item_changes_plan_lookup ON item_changes_plans(scope,base_sequence,target_sequence)",
            "CREATE INDEX IF NOT EXISTS item_changes_plan_age ON item_changes_plans(created)",
            "CREATE TABLE IF NOT EXISTS item_changes_plan_entries(plan TEXT NOT NULL,ordinal INTEGER NOT NULL,item TEXT NOT NULL,kind TEXT NOT NULL,PRIMARY KEY(plan,ordinal))",

        ]
        for (table, key) in [
            ("items", "id"), ("head_summaries", "item_id"),
            ("current_projection", "item"), ("current_policy", "item"),
        ] {
            for (event, row) in [("INSERT", "NEW"), ("UPDATE", "NEW"), ("DELETE", "OLD")] {
                sql.append(
                    "CREATE TRIGGER IF NOT EXISTS item_changes_\(table)_\(event.lowercased()) AFTER \(event) ON \(table) BEGIN INSERT OR IGNORE INTO item_changes_dirty VALUES(\(row).\(key)); END"
                )
            }
        }
        return sql
    }
    private func changeText(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    private func changeScalar(_ sql: String, _ arguments: [String] = []) throws -> String? {
        let statement = try corpusPrepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        switch catalogueStep(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW: return changeText(statement, 0)
        default: throw graphSQLiteError()
        }
    }
    private func changeMeta(_ key: String) throws -> String? {
        try changeScalar("SELECT value FROM item_changes_meta WHERE key=?", [key])
    }
    private func setChangeMeta(_ key: String, _ value: String) throws {
        try execute("INSERT OR REPLACE INTO item_changes_meta VALUES(?,?)", [key, value])
    }
    private func changeRepresentation(_ itemID: String, projection: Bool) throws -> ChangeRepresentation? {
        if projection {
            guard let current = try currentProjection(itemID: itemID) else { return nil }
            let policies =
                current.policiesComplete
                ? try currentPolicyWitnesses(itemID: itemID).map {
                    ChangePolicy(classID: $0.classID, permissions: $0.permissions)
                } : []
            // Ready Item/get also needs its materialized current content. Unresolved records
            // deliberately remain retrievable without an items/head_summaries row.
            if current.state.status == .ready {
                guard let head = try currentHeadSummary(itemID),
                    head.revisionID == current.state.representativeRevisionID
                else { return nil }
            }
            return .init(
                revisionID: current.state.status == .ready ? current.state.representativeRevisionID : nil,
                resolution: current.state, policies: policies, policiesComplete: current.policiesComplete)
        }
        guard let head = try currentHeadSummary(itemID),
            try changeScalar("SELECT revision FROM items WHERE id=?", [itemID]) == head.revisionID
        else { return nil }
        return .init(
            revisionID: head.revisionID, resolution: nil,
            policies: [.init(classID: head.classID, permissions: head.fields["permissions"])],
            policiesComplete: true)
    }
    private func encodedChange(_ value: ChangeRepresentation?) throws -> String {
        try value.map { String(decoding: try JSON.encode($0), as: UTF8.self) } ?? ""
    }
    private func decodedChange(_ value: String) throws -> ChangeRepresentation? {
        value.isEmpty ? nil : try JSON.decode(ChangeRepresentation.self, Data(value.utf8))
    }
    private func changeDirtyPage() throws -> [String] {
        let statement = try corpusPrepare("SELECT item FROM item_changes_dirty ORDER BY item LIMIT 128")
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            result.append(changeText(statement, 0))
        }
    }
    /// Called only at a serialized Store boundary, never from a mutation trigger. Triggers
    /// persist candidate IDs atomically with the actual projection mutation, including arrivals.
    func reconcileItemChanges(projection: Bool, now: Date = Date()) throws -> ChangeBounds {
        try requireItemChangePublicationBoundary()
        try installItemChangesSchema()
        try execute("SAVEPOINT item_changes_reconcile")
        do {
            let mode = projection ? "projection-v1" : "legacy-v1"
            let seed = try changeMeta("mode") != mode || changeMeta("epoch") == nil
            if seed {
                for table in [
                    "item_changes_current", "item_changes_dirty", "item_changes_journal",
                    "item_changes_tokens", "item_changes_plans", "item_changes_plan_entries",
                ] {
                    try execute("DELETE FROM \(table)")
                }
                try setChangeMeta("epoch", Identifier.make())
                try setChangeMeta("mode", mode)
                try setChangeMeta("head", "0")
                try setChangeMeta("floor", "0")
                try setChangeMeta("rows", "0")
                try setChangeMeta("bytes", "0")
                try setChangeMeta("tokenRows", "0")
                try setChangeMeta("tokenBytes", "0")
                try setChangeMeta("planRows", "0")
                try setChangeMeta("planBytes", "0")
                try execute("INSERT OR IGNORE INTO item_changes_dirty SELECT item_id FROM head_summaries")
                if projection {
                    try execute(
                        "INSERT OR IGNORE INTO item_changes_dirty SELECT item FROM current_projection")
                }
            }
            var appendedRows = 0
            var appendedBytes = 0
            func chargeBatch() throws {
                guard appendedRows > 0 else { return }
                let head =
                    try changeScalar("SELECT COALESCE(MAX(sequence),0) FROM item_changes_journal") ?? "0"
                try setChangeMeta("head", head)
                try setChangeMeta("rows", String((Int(try changeMeta("rows") ?? "0") ?? 0) + appendedRows))
                try setChangeMeta("bytes", String((Int(try changeMeta("bytes") ?? "0") ?? 0) + appendedBytes))
                try pruneItemChanges(now: now)
                appendedRows = 0
                appendedBytes = 0
            }
            while true {
                let ids = try changeDirtyPage()
                if ids.isEmpty { break }
                for id in ids {
                    let old =
                        try changeScalar("SELECT representation FROM item_changes_current WHERE item=?", [id])
                        ?? ""
                    let next = try encodedChange(changeRepresentation(id, projection: projection))
                    if old != next {
                        if !seed {
                            try execute(
                                "INSERT INTO item_changes_journal(item,old,new,bytes,created) VALUES(?,?,?,?,?)",
                                [
                                    id, old, next,
                                    String(id.utf8.count + old.utf8.count + next.utf8.count + 64),
                                    String(now.timeIntervalSince1970),
                                ])
                            appendedRows += 1
                            appendedBytes += id.utf8.count + old.utf8.count + next.utf8.count + 64
                        }
                        if next.isEmpty {
                            try execute("DELETE FROM item_changes_current WHERE item=?", [id])
                        } else {
                            try execute(
                                "INSERT OR REPLACE INTO item_changes_current VALUES(?,?)", [id, next])
                        }
                    }
                    try execute("DELETE FROM item_changes_dirty WHERE item=?", [id])
                    if appendedRows >= 1024 || appendedBytes >= Self.itemChangesMaximumBytes / 10 {
                        try chargeBatch()
                    }
                }
            }
            try chargeBatch()
            let result = ChangeBounds(
                epoch: try changeMeta("epoch") ?? "", floor: Int64(try changeMeta("floor") ?? "") ?? 0,
                head: Int64(try changeMeta("head") ?? "") ?? 0)
            try beforeItemChangesCommitForTesting?()
            try execute("RELEASE item_changes_reconcile")
            return result
        } catch {
            try? execute("ROLLBACK TO item_changes_reconcile")
            try? execute("RELEASE item_changes_reconcile")
            throw error
        }
    }
    private func pruneItemChanges(now: Date) throws {
        let rows = Int(try changeMeta("rows") ?? "0") ?? 0
        let bytes = Int(try changeMeta("bytes") ?? "0") ?? 0
        var floor =
            Int64(
                try changeScalar(
                    "SELECT COALESCE(MAX(sequence),0) FROM item_changes_journal WHERE created<?",
                    [String(now.timeIntervalSince1970 - Self.itemChangesMaximumAge)]) ?? "0") ?? 0
        if rows > Self.itemChangesMaximumRows || bytes > Self.itemChangesMaximumBytes {
            // Evict in batches: scanning bounded retained history on every single edit would
            // defeat changed-candidate polling. Hysteresis makes this work amortized.
            let statement = try corpusPrepare(
                "SELECT sequence,bytes FROM item_changes_journal ORDER BY sequence")
            defer { sqlite3_finalize(statement) }
            var remainingRows = rows
            var remainingBytes = bytes
            while remainingRows > Self.itemChangesMaximumRows * 9 / 10
                || remainingBytes > Self.itemChangesMaximumBytes * 9 / 10
            {
                let status = catalogueStep(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                floor = max(floor, sqlite3_column_int64(statement, 0))
                remainingRows -= 1
                remainingBytes -= Int(sqlite3_column_int64(statement, 1))
            }
        }
        if floor > 0 {
            let removedRows =
                Int(
                    try changeScalar(
                        "SELECT COUNT(*) FROM item_changes_journal WHERE sequence<=?", [String(floor)]) ?? "0"
                ) ?? 0
            let removedBytes =
                Int(
                    try changeScalar(
                        "SELECT COALESCE(SUM(bytes),0) FROM item_changes_journal WHERE sequence<=?",
                        [String(floor)]) ?? "0") ?? 0
            try execute("DELETE FROM item_changes_journal WHERE sequence<=?", [String(floor)])
            try setChangeMeta("floor", String(floor))
            try setChangeMeta("rows", String(rows - removedRows))
            try setChangeMeta("bytes", String(bytes - removedBytes))

        }

    }
    func itemChangeCandidates(after sequence: Int64, through head: Int64) throws -> [String: ChangeCandidate]
    {
        let statement = try corpusPrepare(
            "SELECT item,old,new FROM item_changes_journal WHERE sequence>? AND sequence<=? ORDER BY sequence",
            [String(sequence), String(head)])
        defer { sqlite3_finalize(statement) }
        var result: [String: ChangeCandidate] = [:]
        var count = 0
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, count < Self.itemChangesMaximumRows else {
                throw TractandaError("cannotCalculateChanges", "Change history exceeded its retained window.")
            }
            count += 1
            itemChangeCandidateRowsForTesting += 1
            let id = changeText(statement, 0)
            let next = try decodedChange(changeText(statement, 2))
            if var candidate = result[id] {
                candidate.new = next
                result[id] = candidate
            } else {
                result[id] = .init(itemID: id, old: try decodedChange(changeText(statement, 1)), new: next)
            }
        }
    }
    func currentChangeRepresentation(_ itemID: String) throws -> ChangeRepresentation? {
        try decodedChange(
            changeScalar("SELECT representation FROM item_changes_current WHERE item=?", [itemID]) ?? "")
    }
    func itemChangeToken(_ token: String) throws -> ChangeToken? {
        guard token.utf8.count <= 128,
            let raw = try changeScalar("SELECT record FROM item_changes_tokens WHERE token=?", [token])
        else { return nil }
        return try JSON.decode(ChangeToken.self, Data(raw.utf8))
    }
    func latestItemChangeToken(scope: String) throws -> ChangeToken? {
        guard
            let raw = try changeScalar(
                "SELECT record FROM item_changes_tokens WHERE scope=? AND final=1 ORDER BY sequence DESC,created DESC LIMIT 1",
                [scope])
        else { return nil }
        return try JSON.decode(ChangeToken.self, Data(raw.utf8))
    }
    private func deleteItemChangeToken(_ token: String) throws {
        guard let raw = try changeScalar("SELECT bytes FROM item_changes_tokens WHERE token=?", [token])
        else { return }
        try execute("DELETE FROM item_changes_tokens WHERE token=?", [token])
        try setChangeMeta("tokenRows", String(max(0, (Int(try changeMeta("tokenRows") ?? "0") ?? 0) - 1)))
        try setChangeMeta(
            "tokenBytes", String(max(0, (Int(try changeMeta("tokenBytes") ?? "0") ?? 0) - (Int(raw) ?? 0))))
    }
    func saveItemChangeToken(_ token: ChangeToken, protecting protected: Set<String> = []) throws {
        let raw = try JSON.encode(token)
        let rowLimit = itemChangeTokenRowsLimitForTesting ?? 4096
        let byteLimit = itemChangeTokenBytesLimitForTesting ?? Self.itemChangesTokenTotalBytes
        guard raw.count <= Self.itemChangesTokenMaximumBytes, raw.count <= byteLimit, rowLimit > 0,
            protected.count <= 16
        else {
            throw TractandaError("cannotCalculateChanges", "Scope exceeded its bounded retained metadata.")
        }
        try execute("SAVEPOINT item_changes_token_save")
        do {
            for id in protected {
                guard try itemChangeToken(id) != nil else {
                    throw TractandaError("cannotCalculateChanges", "A required target state was evicted.")
                }
            }
            let retained = protected.union([token.token]).sorted()
            let placeholders = Array(repeating: "?", count: retained.count).joined(separator: ",")
            let previousBytes = try changeScalar(
                "SELECT bytes FROM item_changes_tokens WHERE token=?", [token.token])
            try execute(
                "INSERT OR REPLACE INTO item_changes_tokens VALUES(?,?,?,?,?,?,?,?)",
                [
                    token.token, token.scope, String(token.sequence), token.planID == nil ? "1" : "0",
                    token.planID ?? "", String(decoding: raw, as: UTF8.self), String(raw.count),
                    String(token.issuedAt),
                ])
            var rows = (Int(try changeMeta("tokenRows") ?? "0") ?? 0) + (previousBytes == nil ? 1 : 0)
            var bytes =
                (Int(try changeMeta("tokenBytes") ?? "0") ?? 0) + raw.count - (Int(previousBytes ?? "0") ?? 0)
            try setChangeMeta("tokenRows", String(rows))
            try setChangeMeta("tokenBytes", String(bytes))
            while rows > rowLimit || bytes > byteLimit {
                guard
                    let oldest = try changeScalar(
                        "SELECT token FROM item_changes_tokens WHERE token NOT IN(\(placeholders)) ORDER BY created,token LIMIT 1",
                        retained)
                else {
                    throw TractandaError(
                        "cannotCalculateChanges", "Required states exceed the retained token budget.")
                }
                try deleteItemChangeToken(oldest)
                rows = Int(try changeMeta("tokenRows") ?? "0") ?? 0
                bytes = Int(try changeMeta("tokenBytes") ?? "0") ?? 0
            }
            try execute("RELEASE item_changes_token_save")
            itemChangeTokenSavesForTesting += 1
        } catch {
            try? execute("ROLLBACK TO item_changes_token_save")
            try? execute("RELEASE item_changes_token_save")
            throw error
        }
    }
    private func decodeChangePlan(_ statement: OpaquePointer) -> ChangePlan {
        .init(
            id: changeText(statement, 0), epoch: changeText(statement, 1), scope: changeText(statement, 2),
            base: sqlite3_column_int64(statement, 3), target: sqlite3_column_int64(statement, 4),
            targetToken: changeText(statement, 5), count: Int(sqlite3_column_int64(statement, 6)),
            issuedAt: sqlite3_column_double(statement, 7))
    }
    func itemChangePlan(_ id: String) throws -> ChangePlan? {
        let statement = try corpusPrepare(
            "SELECT plan,epoch,scope,base_sequence,target_sequence,target_token,count,created FROM item_changes_plans WHERE plan=?",
            [id])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw graphSQLiteError() }
        return decodeChangePlan(statement)
    }
    func existingItemChangePlan(scope: String, base: Int64, target: Int64) throws -> ChangePlan? {
        let statement = try corpusPrepare(
            "SELECT plan,epoch,scope,base_sequence,target_sequence,target_token,count,created FROM item_changes_plans WHERE scope=? AND base_sequence=? AND target_sequence=? ORDER BY created DESC LIMIT 1",
            [scope, String(base), String(target)])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw graphSQLiteError() }
        return decodeChangePlan(statement)
    }
    private func deleteItemChangePlan(_ id: String) throws {
        guard let plan = try itemChangePlan(id),
            let size = try changeScalar("SELECT bytes FROM item_changes_plans WHERE plan=?", [id])
        else { return }
        try execute("DELETE FROM item_changes_plan_entries WHERE plan=?", [id])
        try execute("DELETE FROM item_changes_plans WHERE plan=?", [id])
        try setChangeMeta(
            "planRows", String(max(0, (Int(try changeMeta("planRows") ?? "0") ?? 0) - plan.count)))
        try setChangeMeta(
            "planBytes", String(max(0, (Int(try changeMeta("planBytes") ?? "0") ?? 0) - (Int(size) ?? 0))))
        // Intermediate tokens are tiny. Their absent immutable plan makes them unusable;
        // ordinary token retention independently bounds their total encoded storage.
    }
    func saveItemChangePlan(_ plan: ChangePlan, entries: [ChangePlanEntry]) throws {
        let bytes = entries.reduce(256) { $0 + $1.itemID.utf8.count + $1.kind.utf8.count + 64 }
        let rowLimit = itemChangePlanRowsLimitForTesting ?? Self.itemChangesPlanMaximumRows
        let byteLimit = itemChangePlanBytesLimitForTesting ?? Self.itemChangesPlanMaximumBytes
        guard entries.count == plan.count, entries.count <= rowLimit, bytes <= byteLimit
        else { throw TractandaError("cannotCalculateChanges", "Delta plan exceeds its retained window.") }
        try execute("SAVEPOINT item_changes_plan_save")
        do {
            try execute(
                "INSERT INTO item_changes_plans VALUES(?,?,?,?,?,?,?,?,?)",
                [
                    plan.id, plan.epoch, plan.scope, String(plan.base), String(plan.target), plan.targetToken,
                    String(plan.count), String(bytes), String(plan.issuedAt),
                ])
            for (ordinal, entry) in entries.enumerated() {
                try execute(
                    "INSERT INTO item_changes_plan_entries VALUES(?,?,?,?)",
                    [
                        plan.id, String(ordinal), entry.itemID, entry.kind,
                    ])
            }
            var rows = (Int(try changeMeta("planRows") ?? "0") ?? 0) + entries.count
            var retainedBytes = (Int(try changeMeta("planBytes") ?? "0") ?? 0) + bytes
            try setChangeMeta("planRows", String(rows))
            try setChangeMeta("planBytes", String(retainedBytes))
            while rows > rowLimit || retainedBytes > byteLimit {
                guard
                    let oldest = try changeScalar(
                        "SELECT plan FROM item_changes_plans WHERE plan!=? ORDER BY created,plan LIMIT 1",
                        [plan.id])
                else {
                    throw TractandaError(
                        "cannotCalculateChanges", "Required delta plan exceeds the retained budget.")
                }
                try deleteItemChangePlan(oldest)
                rows = Int(try changeMeta("planRows") ?? "0") ?? 0
                retainedBytes = Int(try changeMeta("planBytes") ?? "0") ?? 0
            }
            try execute("RELEASE item_changes_plan_save")
        } catch {
            try? execute("ROLLBACK TO item_changes_plan_save")
            try? execute("RELEASE item_changes_plan_save")
            throw error
        }
    }
    func itemChangePlanPage(_ plan: ChangePlan, position: Int, limit: Int) throws -> [ChangePlanEntry] {
        guard position >= 0, position <= plan.count, limit > 0, limit <= 10_000 else {
            throw TractandaError("cannotCalculateChanges", "Continuation position is invalid.")
        }
        let statement = try corpusPrepare(
            "SELECT item,kind FROM item_changes_plan_entries WHERE plan=? AND ordinal>=? ORDER BY ordinal LIMIT \(limit)",
            [plan.id, String(position)])
        defer { sqlite3_finalize(statement) }
        var result: [ChangePlanEntry] = []
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            let id = changeText(statement, 0)
            let kind = changeText(statement, 1)
            guard ["created", "updated", "destroyed"].contains(kind),
                (try? Identifier.validate(id)) != nil
            else {
                throw TractandaError("cannotCalculateChanges", "Retained delta plan metadata is invalid.")
            }
            result.append(.init(itemID: id, kind: kind))
        }
    }
}
