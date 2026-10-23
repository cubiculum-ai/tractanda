import CSQLite
import Foundation

/// Disposable structural work. Nothing in these tables is an accepted control, head or opinion.
/// Store supplies semantic validation/accepted publication separately in the integration boundary.
extension ItemIndex {
    func initializeAtomicAuthoritySchema() throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try requireGraphCapacity(additionalBytes: 64 * 1024)
            try installAtomicAuthorityIndexSchema(.staging)
        }
    }

    /// Complete hash/custody validation precedes callbacks. Failed replay leaves only private rows;
    /// no accepted query reads them. Exact retry compares every existing prefix fact byte for byte.
    func stageAtomicControl(archive: AtomicAuthorityArchive, handle: AtomicAuthorityArchive.Handle) throws
        -> AtomicControlStage
    {
        let stage = try AtomicControlStage(rootBytes: archive.rootBytes(handle))
        try beginAtomicControlStage(stage)
        try execute(
            "UPDATE authority_atomic_stage SET complete=0 WHERE id=?", [stage.header.binding.recordID])
        var parents: Int64 = 0
        var supports: Int64 = 0
        _ = try archive.forEachUntrustedStagingFact(handle) { fact in
            let ordinal = fact.section == .parents ? parents : supports
            try self.appendAtomicControlEntry(
                stage, section: fact.section, ordinal: ordinal, value: fact.value)
            if fact.section == .parents {
                parents = try AtomicAuthorityFormat.sum(parents, 1)
            } else {
                supports = try AtomicAuthorityFormat.sum(supports, 1)
            }
        }
        guard parents == stage.parents.entryCount, supports == stage.effects.entryCount else {
            throw AtomicAuthorityFormat.invalid("Atomic staged stream counts changed.")
        }
        try finishAtomicControlStage(stage)
        return stage
    }

    func beginAtomicControlStage(_ stage: AtomicControlStage) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try atomicCapacity(UInt64(stage.rootBytes.count) * 2 + 4096)
            let s = try corpusPrepare(
                "SELECT sha256,root FROM authority_atomic_stage WHERE id=?", [stage.header.binding.recordID])
            defer { sqlite3_finalize(s) }
            let status = catalogueStep(s)
            if status == SQLITE_ROW {
                guard try atomicText(s, 0) == stage.header.binding.sha256,
                    try atomicText(s, 1) == String(decoding: stage.rootBytes, as: UTF8.self)
                else { throw AtomicAuthorityFormat.invalid("Staged logical root identity changed.") }
                return
            }
            guard status == SQLITE_DONE else { throw graphSQLiteError() }
            try execute(
                "INSERT INTO authority_atomic_stage(id,sha256,root) VALUES(?,?,?)",
                [
                    stage.header.binding.recordID, stage.header.binding.sha256,
                    String(decoding: stage.rootBytes, as: UTF8.self),
                ])
        }
    }

    /// Private proposed input only. An accepted logical root is immutable history and never
    /// reaches this cleanup; callers release the exact comparison lease before discarding.
    func discardUnacceptedAtomicStage(_ root: AuthorityBinding) throws {
        guard activeAtomicControlFinalization == nil,
            try !hasValidatedAuthorityControl(root)
        else {
            throw AtomicAuthorityFormat.invalid("Accepted atomic history cannot be discarded.")
        }
        try execute(
            "DELETE FROM authority_atomic_parent_stage WHERE root IN(SELECT id FROM authority_atomic_stage WHERE id=? AND sha256=?)",
            [root.recordID, root.sha256])
        try execute(
            "DELETE FROM authority_atomic_support_stage WHERE root IN(SELECT id FROM authority_atomic_stage WHERE id=? AND sha256=?)",
            [root.recordID, root.sha256])
        try execute(
            "DELETE FROM authority_atomic_stage WHERE id=? AND sha256=?", [root.recordID, root.sha256])
    }

    func appendAtomicControlEntry(
        _ stage: AtomicControlStage, section: AtomicAuthorityFormat.Section, ordinal: Int64, value: ItemValue
    ) throws {
        try AtomicAuthorityEntryStream.validate(value, section: section)
        guard ordinal >= 0 else { throw AtomicAuthorityFormat.invalid("Negative staging ordinal.") }
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try atomicSavepoint {
                let status = try atomicStatus(stage)
                let root = stage.header.binding.recordID
                let parent = section == .parents
                let expected = parent ? stage.parents.entryCount : stage.effects.entryCount
                let count = parent ? status.parents : status.facts
                guard ordinal < expected, ordinal <= count else {
                    throw AtomicAuthorityFormat.invalid("Atomic staging cursor has a gap or exceeds root.")
                }
                let payload = String(decoding: try JSON.encode(value), as: UTF8.self)
                let fingerprint = AuthorityRecordCodec.sha256(Data(payload.utf8))
                let id =
                    try parent
                    ? AuthorityBinding(value: value).recordID
                    : AuthorityStore.DispositionDelta(value: value).target.revisionID
                let table = parent ? "authority_atomic_parent_stage" : "authority_atomic_support_stage"
                let old = try corpusPrepare(
                    "SELECT " + (parent ? "id,sha256" : "target,fingerprint,payload")
                        + " FROM \(table) WHERE root=? AND ordinal=?", [root, String(ordinal)])
                let oldStatus = catalogueStep(old)
                if oldStatus == SQLITE_ROW {
                    defer { sqlite3_finalize(old) }
                    guard try atomicText(old, 0) == id,
                        try atomicText(old, 1)
                            == (parent ? AuthorityBinding(value: value).sha256 : fingerprint),
                        try parent || atomicText(old, 2) == payload
                    else { throw AtomicAuthorityFormat.invalid("Exact staged entry retry changed bytes.") }
                    return
                }
                sqlite3_finalize(old)
                guard oldStatus == SQLITE_DONE else { throw graphSQLiteError() }
                guard ordinal == count, !status.complete else {
                    throw AtomicAuthorityFormat.invalid("Completed stage cannot be extended.")
                }
                var newTarget = false
                if ordinal > 0 {
                    let previous = try corpusPrepare(
                        "SELECT " + (parent ? "id,sha256" : "target,fingerprint")
                            + " FROM \(table) WHERE root=? AND ordinal=?", [root, String(ordinal - 1)])
                    defer { sqlite3_finalize(previous) }
                    guard catalogueStep(previous) == SQLITE_ROW else { throw graphSQLiteError() }
                    let lastID = try atomicText(previous, 0)
                    if parent {
                        guard lastID < id else {
                            throw AtomicAuthorityFormat.invalid("Staged parents are not strictly ordered.")
                        }
                    } else {
                        let lastFingerprint = try atomicText(previous, 1)
                        guard lastID < id || (lastID == id && lastFingerprint < fingerprint) else {
                            throw AtomicAuthorityFormat.invalid(
                                "Staged support facts are not strictly ordered.")
                        }
                        newTarget = lastID != id
                    }
                } else {
                    newTarget = !parent
                }
                try atomicCapacity(UInt64(payload.utf8.count) * 3 + 8192)
                if parent {
                    let binding = try AuthorityBinding(value: value)
                    guard binding.recordID != root else {
                        throw AtomicAuthorityFormat.invalid("Logical root cannot be its own PRE.")
                    }
                    try execute(
                        "INSERT INTO \(table) VALUES(?,?,?,?)", [root, String(ordinal), id, binding.sha256])
                    try execute("UPDATE authority_atomic_stage SET parents=parents+1 WHERE id=?", [root])
                } else {
                    try execute(
                        "INSERT INTO \(table) VALUES(?,?,?,?,?)",
                        [root, String(ordinal), id, fingerprint, payload])
                    try execute(
                        "UPDATE authority_atomic_stage SET facts=facts+1,targets=targets+? WHERE id=?",
                        [newTarget ? "1" : "0", root])
                }
            }
        }
    }

    func finishAtomicControlStage(_ stage: AtomicControlStage) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let state = try atomicStatus(stage)
            guard state.parents == stage.parents.entryCount, state.facts == stage.effects.entryCount,
                state.targets == stage.effects.targetCount
            else { throw AtomicAuthorityFormat.invalid("Structural stage is incomplete.") }
            if let previous = stage.header.previous {
                let s = try corpusPrepare(
                    "SELECT 1 FROM authority_atomic_parent_stage WHERE root=? AND id=? AND sha256=?",
                    [stage.header.binding.recordID, previous.recordID, previous.sha256])
                defer { sqlite3_finalize(s) }
                guard catalogueStep(s) == SQLITE_ROW else {
                    throw AtomicAuthorityFormat.invalid("Staged PRE omits exact previous root.")
                }
            }
            try execute(
                "UPDATE authority_atomic_stage SET complete=1 WHERE id=?", [stage.header.binding.recordID])
        }
    }

    /// The final Store boundary runs inside this writer savepoint: canonical verification,
    /// semantic/current-context checks, accepted seal, derived activation and commit are serialized.
    /// No SQLite completeness flag/fingerprint substitutes for comparison with the whole root.
    func withCanonicalAtomicStage<T>(
        _ stage: AtomicControlStage, archive: AtomicAuthorityArchive,
        handle: AtomicAuthorityArchive.Handle, _ body: (LogicalControlSource) throws -> T
    ) throws -> T {
        guard stage.header.binding == handle.binding,
            try archive.rootBytes(handle) == stage.rootBytes
        else { throw AtomicAuthorityFormat.invalid("Final stage names a different canonical root.") }
        return try atomicSavepoint {
            guard try atomicStatus(stage).complete else {
                throw AtomicAuthorityFormat.invalid("Incomplete structural work cannot be finalized.")
            }
            // Obtain the SQLite writer before walking/comparing immutable canonical input. Store
            // also owns its lifetime filesystem writer lock and fresh authority/context checks.
            try execute(
                "UPDATE authority_atomic_stage SET complete=complete WHERE id=?",
                [stage.header.binding.recordID])
            let frozen = try freezeAtomicStage(stage.header.binding)
            defer { try? releaseAtomicStageFreeze(frozen) }
            var parentOrdinal: Int64 = 0
            var supportOrdinal: Int64 = 0
            _ = try archive.forEachUntrustedStagingFact(handle) { fact in
                let section = fact.section
                let value = fact.value
                let ordinal = section == .parents ? parentOrdinal : supportOrdinal
                try self.compareAtomicStagedFact(stage, fact: fact, ordinal: ordinal)
                let next = try AtomicAuthorityFormat.sum(ordinal, 1)
                if section == .parents { parentOrdinal = next } else { supportOrdinal = next }
            }
            for section in [AtomicAuthorityFormat.Section.parents, .effects] {
                let ordinal = section == .parents ? parentOrdinal : supportOrdinal
                let expected = section == .parents ? stage.parents.entryCount : stage.effects.entryCount
                guard ordinal == expected else {
                    throw AtomicAuthorityFormat.invalid("Final canonical stream count differs.")
                }
                try validateAtomicRowDomain(stage, section: section, expected: expected)
            }
            let status = try atomicStatus(stage)
            guard status.parents == stage.parents.entryCount, status.facts == stage.effects.entryCount,
                status.targets == stage.effects.targetCount, status.complete
            else { throw AtomicAuthorityFormat.invalid("Final structural summaries changed.") }
            try checkAtomicStageFreeze(frozen)
            let previousFinalization = activeAtomicControlFinalization
            activeAtomicControlFinalization = stage.header.binding
            defer { activeAtomicControlFinalization = previousFinalization }
            return try body(.atomic(stage))
        }
    }

    func atomicControlParents(_ stage: AtomicControlStage, afterOrdinal: Int64, limit: Int) throws
        -> [(ordinal: Int64, binding: AuthorityBinding)]
    {
        try LogicalControlSource.page(afterOrdinal, limit)
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try atomicStatus(stage).complete else {
                throw AtomicAuthorityFormat.invalid("Cannot expose an incomplete logical source.")
            }
            let s = try corpusPrepare(
                "SELECT ordinal,id,sha256 FROM authority_atomic_parent_stage WHERE root=? AND ordinal>? ORDER BY ordinal LIMIT ?",
                [stage.header.binding.recordID, String(afterOrdinal), String(limit)])
            defer { sqlite3_finalize(s) }
            var result: [(Int64, AuthorityBinding)] = []
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                result.append(
                    try (
                        sqlite3_column_int64(s, 0),
                        .init(recordID: atomicText(s, 1), sha256: atomicText(s, 2))
                    ))
            }
        }
    }

    func atomicControlSupports(_ stage: AtomicControlStage, afterOrdinal: Int64, limit: Int) throws
        -> [LogicalControlSource.Support]
    {
        try LogicalControlSource.page(afterOrdinal, limit)
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try atomicStatus(stage).complete else {
                throw AtomicAuthorityFormat.invalid("Cannot expose an incomplete logical source.")
            }
            let s = try corpusPrepare(
                "SELECT ordinal,fingerprint,payload FROM authority_atomic_support_stage WHERE root=? AND ordinal>? ORDER BY ordinal LIMIT ?",
                [stage.header.binding.recordID, String(afterOrdinal), String(limit)])
            defer { sqlite3_finalize(s) }
            var result: [LogicalControlSource.Support] = []
            var bytes = 0
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                let payload = try atomicText(s, 2)
                if !result.isEmpty,
                    payload.utf8.count > graphMaximumPageBytes - min(bytes, graphMaximumPageBytes)
                {
                    return result
                }
                let data = Data(payload.utf8)
                let fingerprint = try atomicText(s, 1)
                guard AuthorityRecordCodec.sha256(data) == fingerprint else {
                    throw AtomicAuthorityFormat.invalid("Staged support fingerprint changed.")
                }
                let value = try AtomicAuthorityFormat.decodeValue(data)
                try AtomicAuthorityEntryStream.validate(value, section: .effects)
                bytes += payload.utf8.count
                result.append(
                    try .init(
                        ordinal: sqlite3_column_int64(s, 0), fingerprint: fingerprint,
                        delta: .init(value: value)))
            }
        }
    }

    func atomicStatus(_ stage: AtomicControlStage) throws -> (
        parents: Int64, facts: Int64, targets: Int64, complete: Bool
    ) {
        let s = try corpusPrepare(
            "SELECT sha256,root,parents,facts,targets,complete FROM authority_atomic_stage WHERE id=?",
            [stage.header.binding.recordID])
        defer { sqlite3_finalize(s) }
        guard catalogueStep(s) == SQLITE_ROW, try atomicText(s, 0) == stage.header.binding.sha256,
            try atomicText(s, 1) == String(decoding: stage.rootBytes, as: UTF8.self)
        else { throw AtomicAuthorityFormat.invalid("Unknown or changed structural root stage.") }
        return (
            sqlite3_column_int64(s, 2), sqlite3_column_int64(s, 3), sqlite3_column_int64(s, 4),
            sqlite3_column_int(s, 5) == 1
        )
    }
    /// One canonical fact compared with the complete exact SQL row. This is deliberately
    /// outside the decoder callback: healthy quantum yields must not poison a parser.
    func compareAtomicStagedFact(
        _ stage: AtomicControlStage, fact: AtomicAuthorityArchive.UntrustedStagingFact, ordinal: Int64
    ) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let parent = fact.section == .parents
            let table = parent ? "authority_atomic_parent_stage" : "authority_atomic_support_stage"
            let s = try corpusPrepare(
                "SELECT " + (parent ? "id,sha256" : "target,fingerprint,payload")
                    + " FROM \(table) WHERE root=? AND ordinal=?",
                [stage.header.binding.recordID, String(ordinal)])
            defer { sqlite3_finalize(s) }
            guard catalogueStep(s) == SQLITE_ROW else {
                throw AtomicAuthorityFormat.invalid("Canonical entry is absent from structural stage.")
            }
            if parent {
                let binding = try AuthorityBinding(value: fact.value)
                guard try atomicText(s, 0) == binding.recordID,
                    try atomicText(s, 1) == binding.sha256
                else { throw AtomicAuthorityFormat.invalid("Staged parent differs from canonical PRE.") }
            } else {
                let bytes = try JSON.encode(fact.value)
                let delta = try AuthorityStore.DispositionDelta(value: fact.value)
                guard try atomicText(s, 0) == delta.target.revisionID,
                    try atomicText(s, 1) == AuthorityRecordCodec.sha256(bytes),
                    try atomicText(s, 2) == String(decoding: bytes, as: UTF8.self)
                else {
                    throw AtomicAuthorityFormat.invalid("Staged support differs from canonical fact bytes.")
                }
            }
        }
    }

    /// Count EVERY SQL row, including fractional/text/negative ordinals. Root-only indexes order
    /// ties by rowid, so bounded keyset pages are linear and don't impose a whole-root VM ceiling.
    func atomicRowDomainPage(
        _ stage: AtomicControlStage, section: AtomicAuthorityFormat.Section, afterRow: Int64?,
        limit: Int
    ) throws -> (lastRow: Int64?, count: Int64) {
        guard (1...128).contains(limit) else {
            throw AtomicAuthorityFormat.invalid("Invalid atomic domain window.")
        }
        let parent = section == .parents
        let table = parent ? "authority_atomic_parent_stage" : "authority_atomic_support_stage"
        let domainIndex = parent ? "authority_atomic_parent_domain" : "authority_atomic_support_domain"
        let expected = parent ? stage.parents.entryCount : stage.effects.entryCount
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT rowid,ordinal,typeof(ordinal) FROM \(table) INDEXED BY \(domainIndex) WHERE root=?"
                    + (afterRow == nil ? "" : " AND rowid>?") + " ORDER BY rowid LIMIT ?",
                [stage.header.binding.recordID] + (afterRow.map { [String($0)] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var last: Int64?
            var seen: Int64 = 0
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return (last, seen) }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                let ordinal = sqlite3_column_int64(s, 1)
                guard try atomicText(s, 2) == "integer", ordinal >= 0, ordinal < expected else {
                    throw AtomicAuthorityFormat.invalid("Structural stage has a noncanonical ordinal domain.")
                }
                last = sqlite3_column_int64(s, 0)
                seen += 1
            }
        }
    }
    private func validateAtomicRowDomain(
        _ stage: AtomicControlStage, section: AtomicAuthorityFormat.Section, expected: Int64
    ) throws {
        var row: Int64?
        var count: Int64 = 0
        while true {
            let batch = try atomicRowDomainPage(stage, section: section, afterRow: row, limit: 128)
            count = try AtomicAuthorityFormat.sum(count, batch.count)
            guard count <= expected else {
                throw AtomicAuthorityFormat.invalid("Structural stage contains extra noncanonical rows.")
            }
            if batch.count == 0 { break }
            row = batch.lastRow
        }
        guard count == expected else {
            throw AtomicAuthorityFormat.invalid("Structural stage row count differs.")
        }
    }
    private func atomicText(_ s: OpaquePointer, _ column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(s, column))
        guard sqlite3_column_type(s, column) == SQLITE_TEXT, count >= 0,
            count <= AtomicAuthorityFormat.maximumEnvelopeBytes,
            let bytes = sqlite3_column_text(s, column),
            let text = String(data: Data(bytes: bytes, count: count), encoding: .utf8)
        else { throw AtomicAuthorityFormat.invalid("Malformed or non-UTF8 atomic metadata text.") }
        return text
    }
    private func atomicCapacity(_ bytes: UInt64) throws {
        try checkCatalogueScanProgress()
        try requireGraphCapacity(additionalBytes: bytes)
    }
    private func atomicSavepoint<T>(_ body: () throws -> T) throws -> T {
        try execute("SAVEPOINT atomic_stage_entry")
        do {
            let result = try body()
            try execute("RELEASE atomic_stage_entry")
            return result
        } catch {
            try? execute("ROLLBACK TO atomic_stage_entry")
            try? execute("RELEASE atomic_stage_entry")
            throw error
        }
    }
}
