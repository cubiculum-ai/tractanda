import CSQLite
import Foundation

extension ItemIndex {
    struct CurrentProjection: Sendable {
        let state: ItemState
        let representativeDigest: String?
        let clockFloor: RevisionProjection.ClockWitness?
        let policiesComplete: Bool
    }
    static let projectionMetadataByteWindow = 32 * 1024 * 1024

    func createCurrentProjectionTables() throws {
        for sql in [
            "CREATE TABLE current_projection(item TEXT PRIMARY KEY,status TEXT NOT NULL,state TEXT NOT NULL,representative_digest TEXT,clock_revision TEXT,clock_modified TEXT,policies_complete INTEGER NOT NULL,dirty INTEGER NOT NULL DEFAULT 0)",
            "CREATE INDEX current_projection_status ON current_projection(status,item)",
            "CREATE INDEX current_projection_dirty ON current_projection(dirty,item)",
            "CREATE INDEX current_projection_unresolved_items ON current_projection(item) WHERE status!='ready' AND dirty=0",
            "CREATE TABLE current_policy(item TEXT NOT NULL,revision TEXT NOT NULL,class TEXT NOT NULL,permissions TEXT,PRIMARY KEY(item,revision))",
            "CREATE TABLE projection_acl(item TEXT NOT NULL,revision TEXT NOT NULL,owner TEXT NOT NULL,group_name TEXT NOT NULL,mode INTEGER NOT NULL,mask INTEGER NOT NULL,owning_rights INTEGER NOT NULL,other_rights INTEGER NOT NULL,PRIMARY KEY(item,revision))",
            "CREATE TABLE projection_acl_named(item TEXT NOT NULL,revision TEXT NOT NULL,kind TEXT NOT NULL,name TEXT NOT NULL,rights INTEGER NOT NULL,PRIMARY KEY(item,revision,kind,name))",
            "CREATE TABLE projection_principal_counts(kind TEXT NOT NULL,name TEXT NOT NULL,refcount INTEGER NOT NULL,PRIMARY KEY(kind,name))",
            "CREATE TRIGGER projection_acl_insert AFTER INSERT ON projection_acl BEGIN INSERT INTO projection_principal_counts VALUES('user',NEW.owner,1) ON CONFLICT(kind,name) DO UPDATE SET refcount=refcount+1; INSERT INTO projection_principal_counts VALUES('group',NEW.group_name,1) ON CONFLICT(kind,name) DO UPDATE SET refcount=refcount+1; END",
            "CREATE TRIGGER projection_acl_delete AFTER DELETE ON projection_acl BEGIN UPDATE projection_principal_counts SET refcount=refcount-1 WHERE (kind='user' AND name=OLD.owner) OR (kind='group' AND name=OLD.group_name); DELETE FROM projection_principal_counts WHERE refcount=0; END",
            "CREATE TRIGGER projection_named_insert AFTER INSERT ON projection_acl_named BEGIN INSERT INTO projection_principal_counts VALUES(NEW.kind,NEW.name,1) ON CONFLICT(kind,name) DO UPDATE SET refcount=refcount+1; END",
            "CREATE TRIGGER projection_named_delete AFTER DELETE ON projection_acl_named BEGIN UPDATE projection_principal_counts SET refcount=refcount-1 WHERE kind=OLD.kind AND name=OLD.name; DELETE FROM projection_principal_counts WHERE refcount=0; END",
        ] { try execute(sql) }
        currentProjectionSchemaReady = true
    }

    func currentProjection(itemID: String) throws -> CurrentProjection? {
        let statement = try corpusPrepare(
            "SELECT state,representative_digest,clock_revision,clock_modified,policies_complete FROM current_projection WHERE item=? AND dirty=0",
            [itemID])
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw graphSQLiteError() }
        return try projectionRow(statement)
    }
    private func projectionRow(_ statement: OpaquePointer) throws -> CurrentProjection {
        var bytes = 0
        for column in 0..<4 {
            let next = Int(sqlite3_column_bytes(statement, Int32(column)))
            guard next <= Self.projectionMetadataByteWindow - bytes else {
                throw TractandaError("resourceLimit", "Current state metadata exceeds its byte window.")
            }
            bytes += next
        }
        guard let raw = sqlite3_column_text(statement, 0) else { throw graphSQLiteError() }
        let state = try JSON.decode(
            ItemState.self, Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, 0))))
        let digest = sqlite3_column_text(statement, 1).map { String(cString: $0) }.flatMap {
            $0.isEmpty ? nil : $0
        }
        let clock: RevisionProjection.ClockWitness?
        if let id = sqlite3_column_text(statement, 2), let time = sqlite3_column_text(statement, 3),
            id.pointee != 0, time.pointee != 0
        {
            clock = .init(revisionID: String(cString: id), modifiedAt: String(cString: time))
        } else {
            clock = nil
        }
        return .init(
            state: state, representativeDigest: digest, clockFloor: clock,
            policiesComplete: sqlite3_column_int(statement, 4) != 0)
    }
    func currentPolicyWitnesses(itemID: String) throws -> [RevisionProjection.PolicyWitness] {
        guard let current = try currentProjection(itemID: itemID), current.policiesComplete else {
            throw TractandaError("projectionRequired", "Current policy proof is unavailable.")
        }
        let statement = try corpusPrepare(
            "SELECT revision,class,permissions FROM current_policy WHERE item=? ORDER BY revision", [itemID])
        defer { sqlite3_finalize(statement) }
        var result: [RevisionProjection.PolicyWitness] = []
        var bytes = 0
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, result.count < 4096 else {
                if status == SQLITE_ROW {
                    throw TractandaError("resourceLimit", "Current policies exceed their count window.")
                }
                throw graphSQLiteError()
            }
            for column in 0..<3 {
                let next = Int(sqlite3_column_bytes(statement, Int32(column)))
                guard next <= Self.projectionMetadataByteWindow - bytes else {
                    throw TractandaError("resourceLimit", "Current policies exceed their byte window.")
                }
                bytes += next
            }
            guard let id = sqlite3_column_text(statement, 0), let kind = sqlite3_column_text(statement, 1)
            else { throw graphSQLiteError() }
            let permissions = try sqlite3_column_text(statement, 2).flatMap { raw -> ItemValue? in
                guard raw.pointee != 0 else { return nil }
                return try JSON.decode(
                    ItemValue.self, Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, 2))))
            }
            result.append(
                .init(
                    revisionID: String(cString: id), classID: String(cString: kind), permissions: permissions)
            )
        }
    }

    /// Only a genuinely new authored Item root may use its proposed owner/permissions as
    /// current item policy. Dirty/missing projections of any prior local history fail closed.
    func peerItemRootHasNoLocalPolicyHistory(itemID: String) throws -> Bool {
        let statement = try corpusPrepare(
            "SELECT NOT EXISTS(SELECT 1 FROM revision_catalog WHERE item=? LIMIT 1) "
                + "AND NOT EXISTS(SELECT 1 FROM current_projection WHERE item=? LIMIT 1) "
                + "AND NOT EXISTS(SELECT 1 FROM current_policy WHERE item=? LIMIT 1) "
                + "AND NOT EXISTS(SELECT 1 FROM authority_local_history WHERE item=? LIMIT 1) "
                + "AND NOT EXISTS(SELECT 1 FROM authority_retired_items WHERE item=? LIMIT 1)",
            Array(repeating: itemID, count: 5))
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW else { throw graphSQLiteError() }
        let absent = sqlite3_column_int(statement, 0) == 1
        guard catalogueStep(statement) == SQLITE_DONE else { throw graphSQLiteError() }
        return absent
    }
    func unresolvedProjectionPage(after: String? = nil, limit: Int = 128) throws -> [CurrentProjection] {
        guard (1...256).contains(limit) else {
            throw TractandaError("invalidLimit", "Invalid unresolved state page.")
        }
        try requireCurrentProjectionCacheClean()
        let statement = try corpusPrepare(
            "SELECT state,representative_digest,clock_revision,clock_modified,policies_complete FROM current_projection WHERE status!='ready' AND dirty=0"
                + (after == nil ? "" : " AND item>?") + " ORDER BY item LIMIT ?",
            (after.map { [$0] } ?? []) + [String(limit)])
        defer { sqlite3_finalize(statement) }
        var result: [CurrentProjection] = []
        var bytes = 0
        while true {
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            let size = (0..<4).reduce(0) { $0 + Int(sqlite3_column_bytes(statement, Int32($1))) }
            guard size <= Self.projectionMetadataByteWindow else {
                throw TractandaError("resourceLimit", "Current state exceeds page bytes.")
            }
            if size > Self.projectionMetadataByteWindow - bytes { return result }
            bytes += size
            result.append(try projectionRow(statement))
        }
    }
    func requireCurrentProjectionCacheClean() throws {
        let statement = try corpusPrepare("SELECT 1 FROM current_projection WHERE dirty=1 LIMIT 1")
        defer { sqlite3_finalize(statement) }
        let status = catalogueStep(statement)
        guard status != SQLITE_ROW else {
            throw TractandaError(
                "projectionRequired", "Accepted changes require current projection reconciliation.")
        }
        guard status == SQLITE_DONE else { throw graphSQLiteError() }
    }
    func replaceCurrentProjection(
        snapshot: RevisionProjection.Snapshot?, state: ItemState,
        policies: [RevisionProjection.PolicyWitness], policiesComplete: Bool
    ) throws {
        try execute("SAVEPOINT current_projection_guard")
        do {
            try withCatalogueScanBudget(reusingActiveBudget: true) {
                try replaceCurrentProjectionBody(
                    snapshot: snapshot, state: state, policies: policies, policiesComplete: policiesComplete)
            }
            try execute("RELEASE current_projection_guard")
        } catch {
            try? execute("ROLLBACK TO current_projection_guard")
            try? execute("RELEASE current_projection_guard")
            throw error
        }
    }
    private func replaceCurrentProjectionBody(
        snapshot: RevisionProjection.Snapshot?, state: ItemState,
        policies: [RevisionProjection.PolicyWitness], policiesComplete: Bool
    ) throws {
        let bytes = try JSON.encode(state)
        guard bytes.count <= Self.projectionMetadataByteWindow, !state.stateToken.isEmpty,
            state.stateToken.utf8.count <= 1024, policies.count <= 4096
        else {
            throw TractandaError("resourceLimit", "Current projection metadata exceeded its window.")
        }
        try Identifier.validate(state.itemID)
        if let snapshot {
            let fresh =
                projectionAppendActive
                ? true : (try acceptedGraphProofIsCurrent()) && snapshot == lastAnalyzedProjection
            guard fresh else {
                throw TractandaError(
                    "projectionRequired", "Current state must bind the fresh verified item projection.")
            }
            let actualClock = try graphCatalogueRows(
                where: "WHERE item=? ORDER BY modified_ticks DESC,revision DESC", bindings: [state.itemID],
                limit: 1
            ).first
            guard let actualClock, snapshot.clockFloor.revisionID == actualClock.revisionID,
                snapshot.clockFloor.modifiedAt == actualClock.modifiedAt
            else {
                throw TractandaError(
                    "invalidRevisionGraph", "Current state clock witness is not the accepted item maximum.")
            }
            guard snapshot.itemID == state.itemID,
                state.frontier == nil || state.frontier == snapshot.analysis.frontier,
                state.representativeRevisionID == snapshot.representative?.revisionID
            else {
                throw TractandaError(
                    "invalidRevisionGraph", "Current state disagrees with its validated projection.")
            }
        }
        if state.status == .ready {
            guard let snapshot, snapshot.analysis.isResolved, !snapshot.analysis.needsMaterialization,
                snapshot.representative != nil, state.detailsComplete, policiesComplete
            else {
                throw TractandaError(
                    "invalidRevisionGraph", "Ready state needs an exact eligible representative.")
            }
        }
        let frontier = snapshot?.analysis.frontier ?? state.frontier
        if policiesComplete {
            guard let frontier, policies.map(\.revisionID).sorted() == frontier,
                Set(policies.map(\.revisionID)).count == policies.count
            else {
                throw TractandaError(
                    "invalidRevisionGraph", "Policy witnesses must cover the exact authored frontier.")
            }
        }
        var policyBytes = bytes.count
        for policy in policies {
            guard let row = try revision(policy.revisionID), row.itemID == state.itemID else {
                throw TractandaError(
                    "invalidRevisionGraph", "Current policy refers to another or absent item.")
            }
            if let value = policy.permissions { _ = try ItemPermissions(value) }
            guard
                try projectionCount(
                    "SELECT COUNT(*) FROM revision_field_values WHERE revision=? AND field='classID' AND digest=?",
                    [policy.revisionID, try Self.graphValueDigest(.text(policy.classID))]) == 1
            else {
                throw TractandaError("invalidRevisionGraph", "Policy class does not match canonical fields.")
            }
            if let permissions = policy.permissions {
                guard
                    try projectionCount(
                        "SELECT COUNT(*) FROM revision_field_values WHERE revision=? AND field='permissions' AND digest=?",
                        [policy.revisionID, try Self.graphValueDigest(permissions)]) == 1
                else {
                    throw TractandaError(
                        "invalidRevisionGraph", "Policy permissions do not match canonical fields.")
                }
            } else {
                guard
                    try projectionCount(
                        "SELECT COUNT(*) FROM revision_field_values WHERE revision=? AND field='permissions'",
                        [policy.revisionID]) == 0
                else {
                    throw TractandaError(
                        "invalidRevisionGraph", "Single-user policy omitted canonical permissions.")
                }
            }
            let size =
                try JSON.encode(policy.permissions).count + policy.classID.utf8.count
                + policy.revisionID.utf8.count + 512
            guard size <= Self.projectionMetadataByteWindow - policyBytes else {
                throw TractandaError(
                    "resourceLimit", "Combined current state/policies exceeded their byte window.")
            }
            policyBytes += size
        }
        let representative = try state.representativeRevisionID.flatMap { try revision($0) }
        if state.status == .ready, let representative, let snapshot {
            let authored = representative.provenance?.kind != .automaticMerge
            let representedFrontier =
                authored ? [representative.revisionID] : representative.provenance!.frontier
            guard representedFrontier == snapshot.analysis.frontier,
                snapshot.representative?.modifiedAt == representative.modifiedAt,
                try RevisionTimestamp(representative.modifiedAt)
                    >= RevisionTimestamp(snapshot.clockFloor.modifiedAt)
            else {
                throw TractandaError(
                    "invalidRevisionGraph",
                    "Ready representative does not bind its eligible frontier and clock.")
            }
        }
        if snapshot == nil, policiesComplete {
            guard let previous = try currentProjection(itemID: state.itemID),
                previous.policiesComplete, previous.state.frontier == state.frontier,
                previous.state.representativeRevisionID == state.representativeRevisionID
            else {
                throw TractandaError(
                    "projectionRequired",
                    "Policy-complete status-only update needs an unchanged validated item context.")
            }
        }
        guard representative == nil || representative?.itemID == state.itemID else {
            throw TractandaError("invalidRevisionGraph", "Representative belongs to another item.")
        }
        let estimate = UInt64(policyBytes).multipliedReportingOverflow(by: 8)
        guard !estimate.overflow, estimate.partialValue <= graphMaximumTemporaryBytes else {
            throw TractandaError("resourceLimit", "Current policy staging exceeds its byte budget.")
        }
        try requireGraphCapacity(additionalBytes: estimate.partialValue)
        try execute("SAVEPOINT current_projection_update")
        do {
            try execute("DELETE FROM projection_acl_named WHERE item=?", [state.itemID])
            try execute("DELETE FROM projection_acl WHERE item=?", [state.itemID])
            try execute("DELETE FROM current_policy WHERE item=?", [state.itemID])
            for policy in policies {
                try execute(
                    "INSERT INTO current_policy VALUES(?,?,?,?)",
                    [
                        state.itemID, policy.revisionID, policy.classID,
                        try policy.permissions.map { String(decoding: try JSON.encode($0), as: UTF8.self) }
                            ?? "",
                    ])
                // Empty permissions are a single-user witness and never an ACL grant.
                if let value = policy.permissions {
                    try insertProjectionACL(itemID: state.itemID, revisionID: policy.revisionID, value: value)
                }
            }
            try execute(
                "INSERT OR REPLACE INTO current_projection VALUES(?,?,?,?,?,?,?,0)",
                [
                    state.itemID, state.status.rawValue, String(decoding: bytes, as: UTF8.self),
                    representative?.digest.map { String(format: "%02x", $0) }.joined() ?? "",
                    snapshot?.clockFloor.revisionID ?? "", snapshot?.clockFloor.modifiedAt ?? "",
                    policiesComplete ? "1" : "0",
                ])
            if state.status != .ready { try removeCurrentContentProjection(itemID: state.itemID) }
            try execute("RELEASE current_projection_update")
        } catch {
            try? execute("ROLLBACK TO current_projection_update")
            try? execute("RELEASE current_projection_update")
            throw error
        }
    }
    func insertProjectionACL(itemID: String, revisionID: String, value: ItemValue) throws {
        let p = try ItemPermissions(value)
        try execute(
            "INSERT INTO projection_acl VALUES(?,?,?,?,?,?,?,?)",
            [
                itemID, revisionID, p.owner, p.group,
                String(p.mode), String(p.mask ?? ((p.mode >> 3) & 7)), String(p.owningGroupPermissions),
                String(p.mode & 7),
            ])
        for (kind, entries) in [("user", p.users), ("group", p.groups)] {
            for (name, rights) in entries {
                try execute(
                    "INSERT INTO projection_acl_named VALUES(?,?,?,?,?)",
                    [itemID, revisionID, kind, name, String(rights)])
            }
        }
    }
    func removeCurrentContentProjection(itemID: String) throws {
        for (table, field) in [
            ("items", "id"), ("head_summaries", "item_id"), ("field_presence", "item_id"),
            ("scalar_value", "item_id"),
            ("acl_named", "item_id"), ("acl_core", "item_id"), ("text_snapshot", "id"),
            ("corpus_head", "item_id"), ("corpus_link", "item_id"),
            ("saved_view_targets", "id"), ("saved_view_dependencies", "view_id"),
            ("saved_view_coverage", "view_id"),
            ("saved_view_staging", "view_id"), ("saved_view_build_state", "view_id"),
            ("category_include_candidates", "source_id"), ("category_decision_candidates", "source_id"),
            ("personal_category_delta", "source_id"), ("personal_overlay_targets", "source_id"),
        ] { try execute("DELETE FROM \(table) WHERE \(field)=?", [itemID]) }
        try execute("DELETE FROM saved_view_base WHERE view_id=? OR item_id=?", [itemID, itemID])
        try execute(
            "DELETE FROM category_edges WHERE (target_id=? AND kind='parent') OR (source_id=? AND kind='exclusion')",
            [itemID, itemID])
    }
}

extension ItemIndex {
    private func projectionCount(_ sql: String, _ args: [String] = []) throws -> Int64 {
        let statement = try corpusPrepare(sql, args)
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW else { throw graphSQLiteError() }
        return sqlite3_column_int64(statement, 0)
    }
    func appendValidatedLocal(
        row: CatalogueRow, revision value: Revision, parent: Revision?,
        expectedRepresentativeID: String?, state: ItemState,
        policies: [RevisionProjection.PolicyWitness], corpus: IndexedCorpusStage? = nil,
        snapshot: RevisionProjection.Snapshot? = nil
    ) throws {
        guard !projectionAppendActive else {
            throw TractandaError("indexTransient", "An append already owns this index.")
        }
        projectionAppendActive = true
        defer { projectionAppendActive = false }
        try execute("SAVEPOINT validated_local_append")
        do {
            try withCatalogueScanBudget(reusingActiveBudget: true) {
                guard try acceptedGraphProofIsCurrent() else {
                    throw TractandaError(
                        "projectionRequired", "Local append needs completed accepted graph admission.")
                }
                try value.validate()
                try ItemSemantics.validate(value)
                guard let provenance = try value.provenance,
                    value.itemID == row.itemID, value.revisionID == row.revisionID,
                    value.modifiedAt == row.modifiedAt, value.supersedes == row.parentID,
                    provenance == row.provenance,
                    value.fields["createdAt"]?.dateString == row.createdAt,
                    value.fields["actor"]?.string == row.actor,
                    value.fields["operationID"]?.string == row.operationID,
                    row.digest.count == 32, try self.revision(row.revisionID) == nil,
                    state.itemID == row.itemID, state.representativeRevisionID == row.revisionID,
                    state.status == .ready, state.detailsComplete
                else {
                    throw TractandaError(
                        "invalidRevisionGraph",
                        "Validated append metadata/state does not bind its complete revision."
                    )
                }
                let feedback =
                    (value.fields["learningFeedback"]?.map?.values.compactMap {
                        $0.map?["revisionID"]?.string
                    } ?? [])
                    .sorted()
                guard row.feedbackRevisionIDs.sorted() == feedback else {
                    throw TractandaError(
                        "invalidRevisionGraph", "Append omitted canonical feedback references.")
                }
                let prior = try currentProjection(itemID: row.itemID)
                let oldFloor: RevisionProjection.ClockWitness?
                let resultingFrontier: [String]
                if provenance.kind == .authored {
                    if provenance.parents.isEmpty {
                        guard parent == nil, expectedRepresentativeID == nil, prior == nil,
                            try projectionCount(
                                "SELECT COUNT(*) FROM revision_catalog WHERE item=?", [row.itemID])
                                == 0
                        else {
                            throw TractandaError("revisionConflict", "New item root already exists.")
                        }
                        oldFloor = nil
                    } else {
                        guard let parent, let prior, prior.state.status == .ready, prior.policiesComplete,
                            expectedRepresentativeID == prior.state.representativeRevisionID,
                            provenance.parents == [parent.revisionID],
                            parent.revisionID == expectedRepresentativeID,
                            parent.itemID == row.itemID,
                            let parentRow = try self.revision(parent.revisionID),
                            parentRow.digest.map({ String(format: "%02x", $0) }).joined()
                                == prior.representativeDigest,
                            parent.fields["createdAt"] == value.fields["createdAt"]
                        else {
                            throw TractandaError(
                                "revisionConflict",
                                "Local append requires the exact current eligible representative."
                            )
                        }
                        try bindNormalizedSnapshot(parent)
                        let before = RevisionMerge.semanticFields(parent)
                        let after = RevisionMerge.semanticFields(value)
                        let written = Set(provenance.writtenFields)
                        let unset = Set(provenance.unsetFields)
                        for field in Set(before.keys).union(after.keys) where before[field] != after[field] {
                            guard after[field] == nil ? unset.contains(field) : written.contains(field) else {
                                throw TractandaError(
                                    "invalidRevisionGraph",
                                    "Authored append omitted an actual applied field delta.")
                            }
                        }
                        oldFloor = prior.clockFloor
                    }
                    resultingFrontier = [row.revisionID]
                } else {
                    guard let snapshot, snapshot == lastAnalyzedProjection,
                        snapshot.itemID == row.itemID,
                        provenance.frontier == snapshot.analysis.frontier
                    else {
                        throw TractandaError(
                            "projectionRequired",
                            "Reviewed/automatic append needs the fresh verified item context.")
                    }
                    let parentSet = Set(provenance.parents)
                    if provenance.mergeProfile == AuthorityStore.reconciliationProfile {
                        try validateAuthorityReconciliation(value, snapshot: snapshot)
                        guard Set(snapshot.physicalHeads).isSubset(of: parentSet) else {
                            throw TractandaError(
                                "invalidAuthority", "Reconciliation omitted eligible physical inputs.")
                        }
                    } else if provenance.kind == .automaticMerge, let representative = snapshot.representative
                    {
                        guard parentSet.contains(representative.revisionID),
                            parentSet.contains(snapshot.clockFloor.revisionID),
                            snapshot.analysis.isResolved,
                            try RevisionTimestamp(snapshot.clockFloor.modifiedAt)
                                > RevisionTimestamp(representative.modifiedAt)
                        else {
                            throw TractandaError(
                                "invalidRevisionGraph",
                                "Clock materialization lacks its advancing real witness.")
                        }
                    } else {
                        guard Set(snapshot.physicalHeads).isSubset(of: parentSet) else {
                            throw TractandaError(
                                "invalidRevisionGraph",
                                "Local materialization/resolution omitted accepted physical inputs.")
                        }
                    }
                    var expected = snapshot.analysis.fields
                    if provenance.kind == .automaticMerge {
                        guard snapshot.analysis.isResolved else {
                            throw TractandaError("itemUnresolved", "Automatic merge is not eligible.")
                        }
                        resultingFrontier = snapshot.analysis.frontier
                    } else {
                        let addressed = Set(provenance.writtenFields + provenance.unsetFields)
                        guard
                            Set(snapshot.analysis.conflicts.keys).union(snapshot.analysis.protectedFields)
                                .isSubset(
                                    of: addressed)
                        else {
                            throw TractandaError(
                                "invalidRevisionGraph",
                                "Resolution omitted explicit conflict/protected choices.")
                        }
                        for field in provenance.writtenFields { expected[field] = value.fields[field]! }
                        for field in provenance.unsetFields { expected.removeValue(forKey: field) }
                        resultingFrontier = [row.revisionID]
                    }
                    guard expected == RevisionMerge.semanticFields(value) else {
                        throw TractandaError(
                            "invalidRevisionGraph",
                            "Local materialization/resolution differs from actual authored causes.")
                    }
                    oldFloor = snapshot.clockFloor
                }
                guard state.frontier == resultingFrontier,
                    policies.map(\.revisionID).sorted() == resultingFrontier
                else {
                    throw TractandaError(
                        "invalidRevisionGraph", "Append state/policy frontier differs from its causal event.")
                }
                let time = try RevisionTimestamp(row.modifiedAt)
                guard row.modifiedAt == String(try time.formatted().prefix(23)) + "Z",
                    let runtimeTime = Timestamp.parse(row.modifiedAt)
                else {
                    throw TractandaError(
                        "invalidMergeTimestamp", "Local publication needs canonical millisecond precision.")
                }
                if let oldFloor {
                    guard time > (try RevisionTimestamp(oldFloor.modifiedAt)),
                        let oldRuntime = Timestamp.parse(oldFloor.modifiedAt), runtimeTime > oldRuntime
                    else {
                        throw TractandaError(
                            "invalidMergeTimestamp",
                            "Local publication must exceed the accepted historical clock floor.")
                    }
                }
                for id in provenance.parents {
                    guard let input = try self.revision(id), input.itemID == row.itemID,
                        input.createdAt == row.createdAt, time > (try RevisionTimestamp(input.modifiedAt)),
                        let inputRuntime = Timestamp.parse(input.modifiedAt), runtimeTime > inputRuntime
                    else {
                        throw TractandaError(
                            "invalidRevisionGraph",
                            "Append has an absent/cross-item parent or unsafe timestamp.")
                    }
                }
                try insertRecoveryRow(row, graphFields: value.fields)
                let linear = try appendAcceptedGraphBookkeeping(
                    row: row, parents: provenance.parents, feedback: feedback)
                let fields = RevisionMerge.semanticFields(value).mapValues(RevisionFieldWrite.set)
                let analysis = RevisionMerge.Analysis(
                    frontier: resultingFrontier, values: fields, conflicts: [:],
                    protectedFields: [], representativeRevisionID: row.revisionID, needsMaterialization: false
                )
                let updated = RevisionProjection.Snapshot(
                    itemID: row.itemID, analysis: analysis,
                    representative: .init(revisionID: row.revisionID, modifiedAt: row.modifiedAt),
                    clockFloor: .init(revisionID: row.revisionID, modifiedAt: row.modifiedAt),
                    physicalHeads: [row.revisionID])
                try replaceCurrentProjection(
                    snapshot: updated, state: state, policies: policies, policiesComplete: true)
                try put(value, corpus: corpus)
                try advanceAcceptedGraphProof(retainsLinearProjection: provenance.kind == .authored && linear)
            }
            try execute("RELEASE validated_local_append")
        } catch {
            try? execute("ROLLBACK TO validated_local_append")
            try? execute("RELEASE validated_local_append")
            invalidateRevisionGraphValidation()
            try? execute("DELETE FROM checkpoint_meta WHERE key='graphAdmissionProof'")
            try? execute("UPDATE current_projection SET dirty=1 WHERE item=?", [row.itemID])
            throw error
        }
    }
    func bindNormalizedSnapshot(_ value: Revision) throws {
        let fields = RevisionMerge.semanticFields(value)
        guard
            try projectionCount(
                "SELECT COUNT(*) FROM revision_field_values WHERE revision=?", [value.revisionID])
                == Int64(fields.count)
        else {
            throw TractandaError(
                "invalidRevisionGraph", "Verified parent differs from normalized canonical fields.")
        }
        for (field, fieldValue) in fields {
            guard
                try projectionCount(
                    "SELECT COUNT(*) FROM revision_field_values WHERE revision=? AND field=? AND digest=?",
                    [value.revisionID, field, try Self.graphValueDigest(fieldValue)]) == 1
            else {
                throw TractandaError(
                    "invalidRevisionGraph", "Verified parent field differs from normalized canonical bytes.")
            }
        }
    }
}

extension ItemIndex {
    /// Requires request principal tables from the fresh Store access plan; nil is owner-gated
    /// single-user operation. No unresolved class/content branch enters ordinary indexes.
    func hasReadableUnresolvedProjection(aclUserID: UInt32? = nil) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try requireCurrentProjectionCacheClean()
            if let aclUserID {
                guard
                    try projectionCount("SELECT COUNT(*) FROM request_actor WHERE uid=?", [String(aclUserID)])
                        == 1
                else {
                    throw TractandaError(
                        "accessDenied", "Unresolved probe requires the fresh caller principal context.")
                }
            }
            let sql =
                "SELECT 1 FROM current_projection s WHERE s.status!='ready' AND s.dirty=0 AND s.policies_complete=1 "
                + "AND EXISTS(SELECT 1 FROM current_policy p WHERE p.item=s.item) "
                + (aclUserID == nil
                    ? ""
                    : "AND NOT EXISTS(SELECT 1 FROM current_policy p LEFT JOIN projection_acl a ON a.item=p.item AND a.revision=p.revision WHERE p.item=s.item AND (a.revision IS NULL OR NOT (\(projectionPolicyAllowsRead)))) ")
                + "LIMIT 1"
            let statement = try corpusPrepare(sql)
            defer { sqlite3_finalize(statement) }
            let status = catalogueStep(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw graphSQLiteError() }
            return status == SQLITE_ROW
        }
    }
    private var projectionPolicyAllowsRead: String {
        """
        EXISTS(SELECT 1 FROM request_users u WHERE u.name=a.owner)
        AND EXISTS(SELECT 1 FROM request_groups g WHERE g.name=a.group_name)
        AND NOT EXISTS(SELECT 1 FROM projection_acl_named n LEFT JOIN request_users u ON u.name=n.name
            WHERE n.item=a.item AND n.revision=a.revision AND n.kind='user' AND u.uid IS NULL)
        AND NOT EXISTS(SELECT 1 FROM projection_acl_named n LEFT JOIN request_groups g ON g.name=n.name
            WHERE n.item=a.item AND n.revision=a.revision AND n.kind='group' AND g.gid IS NULL)
        AND NOT EXISTS(SELECT 1 FROM projection_acl_named n JOIN request_users u ON u.name=n.name
            WHERE n.item=a.item AND n.revision=a.revision AND n.kind='user'
            GROUP BY n.item,n.revision HAVING COUNT(DISTINCT u.uid)!=COUNT(*))
        AND NOT EXISTS(SELECT 1 FROM projection_acl_named n JOIN request_groups g ON g.name=n.name
            WHERE n.item=a.item AND n.revision=a.revision AND n.kind='group'
            GROUP BY n.item,n.revision HAVING COUNT(DISTINCT g.gid)!=COUNT(*))
        AND CASE
          WHEN EXISTS(SELECT 1 FROM request_users u,request_actor actor WHERE u.name=a.owner AND u.uid=actor.uid)
            THEN ((a.mode >> 6) & 4)=4
          WHEN EXISTS(SELECT 1 FROM projection_acl_named n JOIN request_users u ON u.name=n.name
            WHERE n.item=a.item AND n.revision=a.revision AND n.kind='user' AND u.uid=(SELECT uid FROM request_actor))
            THEN EXISTS(SELECT 1 FROM projection_acl_named n JOIN request_users u ON u.name=n.name
              WHERE n.item=a.item AND n.revision=a.revision AND n.kind='user' AND u.uid=(SELECT uid FROM request_actor) AND (n.rights & a.mask & 4)=4)
          WHEN EXISTS(SELECT 1 FROM request_groups g WHERE g.name=a.group_name AND g.member=1)
            THEN (a.owning_rights & a.mask & 4)=4 OR EXISTS(SELECT 1 FROM projection_acl_named n JOIN request_groups g ON g.name=n.name
              WHERE n.item=a.item AND n.revision=a.revision AND n.kind='group' AND g.member=1 AND (n.rights & a.mask & 4)=4)
          WHEN EXISTS(SELECT 1 FROM projection_acl_named n JOIN request_groups g ON g.name=n.name
            WHERE n.item=a.item AND n.revision=a.revision AND n.kind='group' AND g.member=1)
            THEN EXISTS(SELECT 1 FROM projection_acl_named n JOIN request_groups g ON g.name=n.name
              WHERE n.item=a.item AND n.revision=a.revision AND n.kind='group' AND g.member=1 AND (n.rights & a.mask & 4)=4)
          ELSE (a.other_rights & 4)=4
        END=1
        """
    }
}

extension ItemIndex {
    /// Verified leaf adapter for a proved linear authored item. No ancestor body hydration.
    func verifiedLinearProjectionSnapshot(
        row: CatalogueRow, revision value: Revision,
        progress: (() throws -> Void)? = nil
    ) throws -> RevisionProjection.Snapshot {
        try withCatalogueScanBudget(progress: progress, reusingActiveBudget: true) {
            guard try acceptedGraphProofIsCurrent(), try self.revision(row.revisionID) == row,
                row.itemID == value.itemID, row.revisionID == value.revisionID,
                row.parentID == value.supersedes, row.provenance == (try value.provenance),
                row.createdAt == value.fields["createdAt"]?.dateString,
                row.modifiedAt == value.modifiedAt, row.actor == value.fields["actor"]?.string,
                row.operationID == value.fields["operationID"]?.string,
                try projectionCount(
                    "SELECT COUNT(*) FROM recovery_heads WHERE item=? AND revision=?",
                    [row.itemID, row.revisionID]) == 1,
                try projectionCount("SELECT COUNT(*) FROM recovery_forks WHERE item=?", [row.itemID]) == 0,
                try projectionCount(
                    "SELECT COUNT(*) FROM scoped_operation_receipts WHERE item=? AND kind IN('automaticMerge','resolution')",
                    [row.itemID]) == 0
            else {
                throw TractandaError(
                    "projectionRequired", "Leaf adapter needs an exact proved authored linear head.")
            }
            try value.validate()
            try ItemSemantics.validate(value)
            try bindNormalizedSnapshot(value)
            guard
                let clock = try graphCatalogueRows(
                    where: "WHERE item=? ORDER BY modified_ticks DESC,revision DESC", bindings: [row.itemID],
                    limit: 1
                ).first
            else {
                throw TractandaError("invalidRevisionGraph", "Proved item has no accepted clock witness.")
            }
            let fields = RevisionMerge.semanticFields(value)
            guard try JSON.encode(fields).count + 1024 <= Self.projectionMetadataByteWindow else {
                throw TractandaError(
                    "resourceLimit", "Verified leaf snapshot exceeds its aggregate byte window.")
            }
            let analysis = RevisionMerge.Analysis(
                frontier: [row.revisionID], values: fields.mapValues(RevisionFieldWrite.set),
                conflicts: [:], protectedFields: [], representativeRevisionID: row.revisionID,
                needsMaterialization: try RevisionTimestamp(row.modifiedAt)
                    < RevisionTimestamp(clock.modifiedAt))
            let snapshot = RevisionProjection.Snapshot(
                itemID: row.itemID, analysis: analysis,
                representative: .init(revisionID: row.revisionID, modifiedAt: row.modifiedAt),
                clockFloor: .init(revisionID: clock.revisionID, modifiedAt: clock.modifiedAt),
                physicalHeads: [row.revisionID])
            lastAnalyzedProjection = snapshot
            return snapshot
        }
    }
    /// One bounded startup/checkpoint pass, never an ordinary request/history scan.
    func hasCompleteCurrentProjectionCheckpoint() throws -> Bool {
        admittedProjectionCheckpointWatermark = nil
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard try projectionCount("SELECT COUNT(*) FROM current_projection WHERE dirty=1") == 0
            else { return false }
            guard
                try projectionCount(
                    "SELECT COUNT(*) FROM recovery_roots r LEFT JOIN current_projection c ON c.item=r.item WHERE c.item IS NULL"
                ) == 0
            else { return false }
            guard
                try projectionCount(
                    "SELECT COUNT(*) FROM current_projection c LEFT JOIN items i ON i.id=c.item WHERE c.status='ready' AND (i.id IS NULL OR c.policies_complete=0)"
                ) == 0
            else { return false }
            var cursor: String?
            while true {
                let s = try corpusPrepare(
                    "SELECT c.item FROM current_projection c LEFT JOIN recovery_roots r ON r.item=c.item WHERE r.item IS NULL"
                        + (cursor == nil ? "" : " AND c.item>?") + " ORDER BY c.item LIMIT 1",
                    cursor.map { [$0] } ?? [])
                let status = catalogueStep(s)
                if status == SQLITE_DONE {
                    sqlite3_finalize(s)
                    break
                }
                guard status == SQLITE_ROW, sqlite3_column_bytes(s, 0) <= 1024,
                    let p = sqlite3_column_text(s, 0)
                else {
                    sqlite3_finalize(s)
                    return false
                }
                let itemID = String(cString: p)
                sqlite3_finalize(s)
                cursor = itemID
                guard let current = try currentProjection(itemID: itemID),
                    try authorityAllowsHistoryOnlyBarrier(current)
                else { return false }
            }
            guard try authorityRecoveryProjectionIsComplete() else { return false }
            admittedProjectionCheckpointWatermark = try catalogueWatermark()
            return true
        }
    }
}
