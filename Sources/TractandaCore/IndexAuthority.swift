import CSQLite
import Foundation

/// Disposable metadata over sealed retained originals. Store owns authentication, full
/// validation, sealing and the surrounding writer transaction; this is no ancestry engine.
extension ItemIndex {
    static let authorityMetadataRowBytes = 16 * 1024
    private static let authorityColumns =
        "o.id,o.kind,o.length,o.sha256,o.path,p.package,p.peer,p.configuration,p.permitted"

    /// Only Store's sealed, freshly evaluated ordinary peer path calls this. The
    /// original wrappers bind actual bytes; no canonical record is re-encoded here.
    func appendValidatedPeer(
        row: CatalogueRow, revision original: AuthorityRevision, parent: AuthorityRevision?,
        control: AuthorityBinding? = nil, originalsVerified: Bool = false,
        categoryControl: AuthorityBinding? = nil
    ) throws {
        guard !projectionAppendActive else {
            throw TractandaError("indexTransient", "An append already owns this index.")
        }
        projectionAppendActive = true
        defer { projectionAppendActive = false }
        try execute("SAVEPOINT validated_peer_append")
        do {
            try withCatalogueScanBudget(reusingActiveBudget: true) {
                try Task.checkCancellation()
                guard try acceptedGraphProofIsCurrent() else {
                    throw TractandaError(
                        "projectionRequired", "Peer append needs completed accepted graph admission.")
                }
                let value = original.revision
                try value.validate()
                try ItemSemantics.validate(value)
                let configurationChange = value.classID == "AccessConfigurationItem" && control != nil
                let verifiedStorageFields: Set<String> =
                    originalsVerified ? ["attachments", "attachmentText", "attachmentDocument"] : []
                if configurationChange {
                    guard let control, try hasValidatedAuthorityControl(control),
                        try authorityNumber(
                            "SELECT EXISTS(SELECT 1 FROM authority_control_facts d JOIN authority_control c ON c.id=d.control WHERE c.id=? AND c.sha256=? AND d.target=? AND d.item=? AND d.sha256=? AND d.eligible=1 AND d.evidence!=?)",
                            [
                                control.recordID, control.sha256, value.revisionID, value.itemID,
                                original.sha256,
                                String(decoding: try JSON.encode(ItemValue.list([])), as: UTF8.self),
                            ]) == 1
                    else {
                        throw authorityInvalid(
                            "Protected configuration lacks an exact validated acceptance control.")
                    }
                }
                guard let provenance = try value.provenance, provenance.kind == .authored,
                    !RevisionMerge.protectedClasses.contains(value.classID) || configurationChange,
                    value.itemID == row.itemID, value.revisionID == row.revisionID,
                    value.modifiedAt == row.modifiedAt, value.supersedes == row.parentID,
                    provenance == row.provenance, value.fields["createdAt"]?.dateString == row.createdAt,
                    value.fields["actor"]?.string == row.actor,
                    value.fields["operationID"]?.string == row.operationID,
                    row.digest.count == 32,
                    row.digest.map({ String(format: "%02x", $0) }).joined() == original.sha256,
                    row.size == UInt64(original.originalBytes.count),
                    let retained = try retainedAuthorityObject(id: row.revisionID),
                    retained.descriptor.kind == .item,
                    retained.descriptor.sha256 == original.sha256,
                    retained.descriptor.length == original.originalBytes.count,
                    retained.path == row.path,
                    try authorityDisposition(id: row.revisionID)?.disposition == .eligible
                else {
                    throw authorityInvalid("Peer append does not bind one sealed eligible ordinary original.")
                }
                if let existing = try self.revision(row.revisionID) {
                    guard existing == row else {
                        throw authorityInvalid(
                            "Accepted revision identity differs from incoming original metadata.")
                    }
                    return
                }
                guard
                    try authorityNumber(
                        "SELECT EXISTS(SELECT 1 FROM revision_catalog WHERE item=? LIMIT 1)", [row.revisionID]
                    ) == 0
                else {
                    throw authorityInvalid("Incoming revision identity collides with an item identity.")
                }
                let feedback =
                    (value.fields["learningFeedback"]?.map?.values.compactMap {
                        $0.map?["revisionID"]?.string
                    } ?? []).sorted()
                guard row.feedbackRevisionIDs.sorted() == feedback else {
                    throw authorityInvalid("Peer append omitted original feedback references.")
                }
                let addressed = Set(provenance.writtenFields + provenance.unsetFields)
                let categoryAssignment = value.classID == "Item" && addressed.contains("categoryOverrides")
                let categoryFields: Set<String> = categoryAssignment ? ["categoryOverrides"] : []
                if categoryAssignment {
                    guard let categoryControl, try hasValidatedAuthorityControl(categoryControl),
                        try authorityNumber(
                            "SELECT EXISTS(SELECT 1 FROM authority_control_facts d JOIN authority_control c ON c.id=d.control JOIN authority_local_acceptance a ON a.control=c.id AND a.sha256=c.sha256 WHERE c.id=? AND c.sha256=? AND d.target=? AND d.item=? AND d.sha256=? AND d.eligible=1 AND d.evidence!=?)",
                            [
                                categoryControl.recordID, categoryControl.sha256, value.revisionID,
                                value.itemID, original.sha256,
                                String(decoding: try JSON.encode(ItemValue.list([])), as: UTF8.self),
                            ]) == 1
                    else {
                        throw authorityInvalid(
                            "Category assignment lacks its exact sealed local acceptance control.")
                    }
                }
                let time = try RevisionTimestamp(row.modifiedAt)
                if provenance.parents.isEmpty {
                    var initialFields: Set<String> = ["classID", "schemaVersion", "permissions"]
                    if value.fields["isDeleted"] == .boolean(false) { initialFields.insert("isDeleted") }
                    if configurationChange { initialFields.insert("accessConfiguration") }
                    initialFields.formUnion(categoryFields)
                    guard parent == nil,
                        addressed.intersection(RevisionMerge.protectedFields).isSubset(of: initialFields),
                        try authorityNumber(
                            "SELECT EXISTS(SELECT 1 FROM revision_catalog WHERE item=? LIMIT 1)", [row.itemID]
                        ) == 0
                    else {
                        throw authorityInvalid(
                            "New peer root must be ordinary and have no accepted prior root.")
                    }
                } else {
                    guard let parent, provenance.parents == [parent.revision.revisionID],
                        addressed.intersection(RevisionMerge.protectedFields).isSubset(
                            of: verifiedStorageFields.union(categoryFields).union(
                                configurationChange ? ["accessConfiguration"] : [])),
                        parent.revision.itemID == row.itemID,
                        let input = try self.revision(parent.revision.revisionID),
                        input.itemID == parent.revision.itemID,
                        input.modifiedAt == parent.revision.modifiedAt,
                        input.createdAt == parent.revision.fields["createdAt"]?.dateString,
                        input.parentID == parent.revision.supersedes,
                        input.provenance == (try parent.revision.provenance),
                        input.actor == parent.revision.fields["actor"]?.string,
                        input.operationID == parent.revision.fields["operationID"]?.string,
                        input.digest.map({ String(format: "%02x", $0) }).joined() == parent.sha256,
                        input.size == UInt64(parent.originalBytes.count), input.createdAt == row.createdAt,
                        time > (try RevisionTimestamp(input.modifiedAt)),
                        let retainedParent = try retainedAuthorityObject(id: input.revisionID),
                        retainedParent.path == input.path, retainedParent.descriptor.sha256 == parent.sha256,
                        try authorityDisposition(id: input.revisionID)?.disposition == .eligible
                    else {
                        throw authorityInvalid(
                            "Peer append needs its exact accepted original parent and safe causal timestamp.")
                    }
                    try bindNormalizedSnapshot(parent.revision)
                    let before = RevisionMerge.semanticFields(parent.revision)
                    let after = RevisionMerge.semanticFields(value)
                    let written = Set(provenance.writtenFields)
                    let unset = Set(provenance.unsetFields)
                    for field in Set(before.keys).union(after.keys) where before[field] != after[field] {
                        guard after[field] == nil ? unset.contains(field) : written.contains(field) else {
                            throw authorityInvalid(
                                "Peer authored intent omitted an actual original snapshot delta.")
                        }
                    }
                }
                try insertRecoveryRow(row, graphFields: value.fields)
                let linear = try appendAcceptedGraphBookkeeping(
                    row: row, parents: provenance.parents, feedback: feedback)
                try execute("UPDATE current_projection SET dirty=1 WHERE item=?", [row.itemID])
                try advanceAcceptedGraphProof(retainsLinearProjection: linear)
            }
            try execute("RELEASE validated_peer_append")
        } catch {
            try? execute("ROLLBACK TO validated_peer_append")
            try? execute("RELEASE validated_peer_append")
            invalidateRevisionGraphValidation()
            try? execute("DELETE FROM checkpoint_meta WHERE key='graphAdmissionProof'")
            try? execute("UPDATE current_projection SET dirty=1 WHERE item=?", [row.itemID])
            throw error
        }
    }

    func initializeAuthoritySchema() throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try Task.checkCancellation()
            try authorityCapacity(16 * 1024)
            let oldIndex = try corpusPrepare(
                "SELECT sql FROM sqlite_master WHERE type='index' AND name='authority_evidence_target'")
            let oldStatus = catalogueStep(oldIndex)
            let wasUnique: Bool
            if oldStatus == SQLITE_ROW {
                wasUnique =
                    Array(
                        try authorityText(oldIndex, 0).lowercased()
                            .split(whereSeparator: { $0.isWhitespace }).prefix(3).map(String.init)
                    ) == ["create", "unique", "index"]
            } else {
                guard oldStatus == SQLITE_DONE else {
                    sqlite3_finalize(oldIndex)
                    throw graphSQLiteError()
                }
                wasUnique = false
            }
            sqlite3_finalize(oldIndex)
            if wasUnique { try execute("DROP INDEX authority_evidence_target") }
            for sql in [
                "CREATE TABLE IF NOT EXISTS authority_objects(id TEXT PRIMARY KEY,kind TEXT NOT NULL,length INTEGER NOT NULL,sha256 TEXT NOT NULL,path TEXT NOT NULL,origin TEXT NOT NULL,item TEXT NOT NULL,evidence_target TEXT NOT NULL,control_kind TEXT NOT NULL,modified TEXT NOT NULL,issued INTEGER NOT NULL)",
                "CREATE INDEX IF NOT EXISTS authority_origin_issued ON authority_objects(origin,issued,id)",
                "CREATE INDEX IF NOT EXISTS authority_kind ON authority_objects(control_kind,id)",
                "CREATE TABLE IF NOT EXISTS authority_original_receipts(origin TEXT NOT NULL,operation TEXT NOT NULL,revision TEXT NOT NULL,actor TEXT NOT NULL,PRIMARY KEY(origin,operation,revision))",
                "CREATE INDEX IF NOT EXISTS authority_evidence_target ON authority_objects(evidence_target,id) WHERE evidence_target!=''",
                "CREATE UNIQUE INDEX IF NOT EXISTS authority_objects_path ON authority_objects(path)",
                "CREATE INDEX IF NOT EXISTS authority_objects_kind_id ON authority_objects(kind,id)",
                "CREATE INDEX IF NOT EXISTS authority_objects_item ON authority_objects(item,kind,id)",
                "CREATE TABLE IF NOT EXISTS authority_packages(package TEXT NOT NULL,object TEXT NOT NULL,peer TEXT NOT NULL,configuration TEXT NOT NULL,permitted INTEGER NOT NULL,pending INTEGER NOT NULL,PRIMARY KEY(package,object))",
                "CREATE INDEX IF NOT EXISTS authority_packages_object ON authority_packages(object,permitted DESC,package)",
                "CREATE INDEX IF NOT EXISTS authority_object_receipts ON authority_packages(object,package)",
                "CREATE INDEX IF NOT EXISTS authority_package_pending ON authority_packages(pending,package,object)",
                "CREATE TABLE IF NOT EXISTS authority_dispositions(object TEXT PRIMARY KEY,state TEXT NOT NULL,reason TEXT NOT NULL)",
                "CREATE INDEX IF NOT EXISTS authority_ready_status ON authority_dispositions(state,object)",
                "CREATE TABLE IF NOT EXISTS authority_dependencies(source TEXT NOT NULL,kind TEXT NOT NULL,target TEXT NOT NULL,sha256 TEXT NOT NULL,package TEXT NOT NULL,PRIMARY KEY(source,kind,target,package))",
                "CREATE TABLE IF NOT EXISTS authority_evidence_binding(revision TEXT PRIMARY KEY,evidence TEXT NOT NULL,sha256 TEXT NOT NULL,package TEXT NOT NULL)",
                "CREATE INDEX IF NOT EXISTS authority_dependencies_reverse ON authority_dependencies(target,kind,package,source)",
                "CREATE TABLE IF NOT EXISTS authority_walk(token TEXT NOT NULL,object TEXT NOT NULL,cost INTEGER NOT NULL,PRIMARY KEY(token,object))",
            ] { try execute(sql) }
            try execute("INSERT OR IGNORE INTO authority_walk VALUES('','',0)")
            try initializePeerInventorySchema()
            try initializePeerLifecycleSchema()
        }
    }

    func retainAuthorityObject(
        _ row: AuthorityStore.RetainedObject, revision: AuthorityRevision?,
        authority: AuthorityRecordCodec.Verified?, atomic: CanonicalAuthorityOriginal? = nil
    ) throws {
        let saved = captureAuthorityPeerGraphState()
        try execute("SAVEPOINT peer_inventory_retain")
        do {
            try withCatalogueScanBudget(reusingActiveBudget: true) {
                try Task.checkCancellation()
                try validateAuthorityLocator(row)
                let id = row.descriptor.id
                let package = try corpusPrepare(
                    "SELECT peer,configuration FROM authority_packages WHERE package=? LIMIT 1",
                    [row.packageID])
                let packageStatus = catalogueStep(package)
                if packageStatus == SQLITE_ROW {
                    let same =
                        try authorityText(package, 0) == row.peerID
                        && authorityText(package, 1) == row.configurationDigest
                    sqlite3_finalize(package)
                    guard same else {
                        throw TractandaError("peerContextChanged", "A sealed package context cannot change.")
                    }
                } else {
                    sqlite3_finalize(package)
                    guard packageStatus == SQLITE_DONE else { throw graphSQLiteError() }
                }
                var origin = ""
                var item = ""
                var evidenceTarget = ""
                var controlKind = ""
                var modified = ""
                var dependencies: [(String, String, String)] = []
                func dependency(_ kind: String, _ target: String, _ digest: String = "") {
                    dependencies.append((kind, target, digest))
                }
                switch row.descriptor.kind {
                case .item:
                    guard let revision, authority == nil, atomic == nil, revision.revision.revisionID == id,
                        revision.sha256 == row.descriptor.sha256,
                        revision.originalBytes.count == row.descriptor.length
                    else { throw authorityInvalid("Retained item differs from its verified original.") }
                    origin = try revision.revision.provenance?.originReplicaID ?? ""
                    item = revision.revision.itemID
                    modified = revision.revision.modifiedAt
                    for parent in revision.parents { dependency("parent", parent) }
                    for author in try revision.revision.provenance?.frontier ?? [] {
                        dependency("frontier", author)
                    }
                case .authority:
                    if let atomic {
                        guard authority == nil, revision == nil, case .atomic(let record) = atomic.payload,
                            atomic.recordID == id, atomic.sha256 == row.descriptor.sha256,
                            atomic.bytes.count == row.descriptor.length
                        else { throw authorityInvalid("Retained atomic record differs from exact original.") }
                        origin = record.originReplicaID
                        controlKind = record.kind.rawValue
                        for child in try atomic.physicalChildren() {
                            dependency("atomicPart", child.binding.recordID, child.binding.sha256)
                        }
                        if record.kind == .atomicControl {
                            for previous in try AtomicAuthorityFormat.bindings(record.payload["previous"]) {
                                dependency("controlParent", previous.recordID, previous.sha256)
                            }
                            for bootstrap in try AtomicAuthorityFormat.bindings(record.payload["bootstrap"]) {
                                dependency("atomicBootstrap", bootstrap.recordID, bootstrap.sha256)
                            }
                        }
                        // controlID on a physical part is a scope binding, NEVER a parent edge.
                        // Complete logical parents/support dependencies enter separate staging
                        // only after the exact framed closure has been traversed.
                    } else {
                        guard let authority, revision == nil, authority.record.recordID == id,
                            authority.sha256 == row.descriptor.sha256,
                            authority.originalBytes.count == row.descriptor.length
                        else {
                            throw authorityInvalid("Retained control differs from its verified original.")
                        }
                        let record = authority.record
                        controlKind = record.kind.rawValue
                        origin = record.originReplicaID
                        for parent in record.parentAuthorityIDs { dependency("authorityParent", parent) }
                        for ref in try optionalAuthorityList(record.payload["controls"]) {
                            let binding = try AuthorityBinding(value: ref)
                            dependency("controlParent", binding.recordID, binding.sha256)
                        }
                        if record.kind == .enrollmentApproval {
                            let cut = try AuthorityBinding(value: record.payload["cut"]!)
                            dependency("enrollmentCut", cut.recordID, cut.sha256)
                            for value in try optionalAuthorityList(record.payload["issuerAdmission"]) {
                                let issuer = try AuthorityBinding(value: value)
                                dependency("enrollmentIssuer", issuer.recordID, issuer.sha256)
                            }
                            for value in try AuthorityRecord.list(record.payload["bootstrap"]) {
                                let binding = try AuthorityBinding(value: value)
                                dependency("enrollmentBootstrap", binding.recordID, binding.sha256)
                            }
                        }
                        if record.kind == .authoredEvidence {
                            for field in ["parents", "frontier"] {
                                for target in try AuthorityRecord.ids(record.payload[field], maximum: 1024) {
                                    dependency("semantic" + field, target)
                                }
                            }
                        }
                        for field in [
                            "itemPolicies", "admissionPolicies", "administrationPolicies", "revocations",
                        ] {
                            for ref in try optionalAuthorityList(record.payload[field]) {
                                let binding = try AuthorityRecord.binding(ref)
                                dependency(field, binding.revisionID, binding.sha256)
                            }
                        }
                        if let target = record.payload["target"] {
                            let binding = try AuthorityRecord.binding(target)
                            item = binding.itemID
                            dependency("target", binding.revisionID, binding.sha256)
                            if record.kind == .authoredEvidence { evidenceTarget = binding.revisionID }
                        }
                        for field in ["pages", "children", "acceptedAuthority", "previous", "retirements"] {
                            for ref in try optionalAuthorityList(record.payload[field]) {
                                guard let value = ref.map else {
                                    throw authorityInvalid("Invalid control reference.")
                                }
                                dependency(
                                    field, try AuthorityRecord.persistentID(value["recordID"]),
                                    try AuthorityRecord.digest(value["sha256"]))
                            }
                        }
                        if let ref = record.payload["evidence"]?.map {
                            dependency(
                                "evidence", try AuthorityRecord.persistentID(ref["recordID"]),
                                try AuthorityRecord.digest(ref["sha256"]))
                        }
                        for field in ["holds", "decisionFrontier"] {
                            if let value = record.payload[field] {
                                for target in try AuthorityRecord.ids(value) { dependency(field, target) }
                            }
                        }
                        for entry in try optionalAuthorityList(record.payload["entries"]) {
                            let binding = try AuthorityRecord.binding(entry.map?["target"])
                            dependency("bootstrapMember", binding.revisionID, binding.sha256)
                            for author in try AuthorityRecord.ids(entry.map?["frontier"], maximum: 1024) {
                                dependency("bootstrapFrontier", author)
                            }
                        }
                    }
                case .index:
                    guard revision == nil, authority == nil, atomic == nil else {
                        throw authorityInvalid("Package index has an item/control body.")
                    }
                case .attachment, .document:
                    throw authorityInvalid("Blob retention is outside metadata intake.")
                }
                let estimate = try authorityEstimate(
                    row.path.utf8.count + row.peerID.utf8.count + 2048,
                    entries: dependencies.count + dependencies.filter { $0.0 == "parent" }.count)
                try authorityCapacity(estimate)
                if let canonical = try self.revision(id) {
                    let digest = canonical.digest.map { String(format: "%02x", $0) }.joined()
                    guard row.descriptor.kind == .item, digest == row.descriptor.sha256,
                        canonical.size == UInt64(row.descriptor.length), canonical.itemID == item
                    else {
                        throw authorityInvalid("Object identity collides with accepted canonical history.")
                    }
                }
                let existing = try corpusPrepare(
                    "SELECT kind,length,sha256,origin,modified FROM authority_objects WHERE id=?", [id])
                let status = catalogueStep(existing)
                if status == SQLITE_ROW {
                    let same =
                        try authorityText(existing, 0) == row.descriptor.kind.rawValue
                        && sqlite3_column_int64(existing, 1) == Int64(row.descriptor.length)
                        && authorityText(existing, 2) == row.descriptor.sha256
                        && authorityText(existing, 3) == origin
                        && authorityText(existing, 4) == modified
                    sqlite3_finalize(existing)
                    guard same else {
                        throw authorityInvalid("Global object identity has different bytes/type/origin.")
                    }
                } else {
                    sqlite3_finalize(existing)
                    guard status == SQLITE_DONE else { throw graphSQLiteError() }
                    guard
                        try authorityNumber(
                            "SELECT EXISTS(SELECT 1 FROM authority_objects WHERE path=? LIMIT 1)", [row.path])
                            == 0
                    else {
                        throw authorityInvalid("One retained locator cannot identify different originals.")
                    }
                    try execute(
                        "INSERT INTO authority_objects VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                        [
                            id, row.descriptor.kind.rawValue, String(row.descriptor.length),
                            row.descriptor.sha256, row.path, origin, item, evidenceTarget, controlKind,
                            modified, String((try? PeerLifecycle.revisionTicks(id)) ?? Int64.min),
                        ])
                    for (kind, target, digest) in dependencies {
                        try execute(
                            "INSERT OR IGNORE INTO authority_dependencies VALUES(?,?,?,?,'')",
                            [id, kind, target, digest])
                    }
                    try execute(
                        "INSERT INTO authority_dispositions VALUES(?,?,?)",
                        [
                            id, row.permittedOrigin ? "pending" : "unknownOrigin",
                            "Awaiting current authority evaluation.",
                        ])
                }
                if let revision, let operation = revision.revision.fields["operationID"]?.string,
                    let actor = revision.revision.fields["actor"]?.string, !origin.isEmpty
                {
                    guard operation.utf8.count <= Self.authorityMetadataRowBytes,
                        actor.utf8.count <= Self.authorityMetadataRowBytes - operation.utf8.count
                    else {
                        throw TractandaError(
                            "resourceLimit", "Original receipt metadata exceeds its byte window.")
                    }
                    try authorityCapacity(
                        try authorityEstimate(operation.utf8.count + actor.utf8.count + 512, entries: 0))
                    try execute(
                        "INSERT OR IGNORE INTO authority_original_receipts VALUES(?,?,?,?)",
                        [origin, operation, id, actor])
                }
                let membership = try corpusPrepare(
                    "SELECT peer,configuration,permitted FROM authority_packages WHERE package=? AND object=?",
                    [row.packageID, id])
                let memberStatus = catalogueStep(membership)
                if memberStatus == SQLITE_ROW {
                    let same =
                        try authorityText(membership, 0) == row.peerID
                        && authorityText(membership, 1) == row.configurationDigest
                        && (sqlite3_column_int(membership, 2) != 0) == row.permittedOrigin
                    sqlite3_finalize(membership)
                    guard same else {
                        throw authorityInvalid("A sealed package receipt changed its peer binding.")
                    }
                } else {
                    sqlite3_finalize(membership)
                    guard memberStatus == SQLITE_DONE else { throw graphSQLiteError() }
                    let pending =
                        try authorityDisposition(id: id).map {
                            $0.disposition == .pending || $0.disposition == .missingDependencies
                        } ?? false
                    try execute(
                        "INSERT INTO authority_packages VALUES(?,?,?,?,?,?)",
                        [
                            row.packageID, id, row.peerID, row.configurationDigest,
                            row.permittedOrigin ? "1" : "0", pending ? "1" : "0",
                        ])
                }
                try assignPeerInventoryReceipt(packageID: row.packageID, objectID: id)
                for (kind, target, _) in dependencies where kind == "parent" {
                    try execute(
                        "INSERT OR IGNORE INTO authority_dependencies VALUES(?,'packageParent',?,'',?)",
                        [id, target, row.packageID])
                }
                if row.permittedOrigin {
                    try execute(
                        "UPDATE authority_dispositions SET state='pending',reason='Origin attested; awaiting current authority.' WHERE object=? AND state='unknownOrigin'",
                        [id])
                    try execute(
                        "UPDATE authority_packages SET pending=permitted AND (SELECT state IN('pending','missingDependencies') FROM authority_dispositions WHERE object=?) WHERE object=?",
                        [id, id])
                }
                if authorityControlSchemaReady && ["controlCommit", "atomicControl"].contains(controlKind) {
                    try execute(
                        "INSERT OR IGNORE INTO authority_control_pending SELECT ?,?,COUNT(*) FROM authority_dependencies d LEFT JOIN authority_control c ON c.id=d.target AND c.sha256=d.sha256 WHERE d.source=? AND d.kind='controlParent' AND c.id IS NULL HAVING NOT EXISTS(SELECT 1 FROM authority_control WHERE id=?)",
                        [row.packageID, id, id, id])
                }

            }
            try execute("RELEASE peer_inventory_retain")
        } catch {
            do {
                try rollbackPeerInventoryRetain()
                restoreAuthorityPeerGraphState(saved)
            } catch {
                invalidateRevisionGraphValidation()
                throw error
            }
            throw error
        }
    }

    func retainedAuthorityObject(id: String) throws -> AuthorityStore.RetainedObject? {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(id))
            return try authorityRows(
                "SELECT \(Self.authorityColumns) FROM authority_objects o JOIN authority_packages p ON p.object=o.id WHERE o.id=? ORDER BY p.permitted DESC,p.package LIMIT 1",
                [id], maximum: Self.authorityMetadataRowBytes
            ).first
        }
    }
    /// A receiver's own sealed acceptance, not merely the sender's source-only testimony.
    func localAuthorityAcceptanceControl(revisionID: String) throws -> AuthorityBinding? {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let statement = try corpusPrepare(
                "SELECT c.id,c.sha256 FROM authority_control_outcomes d JOIN authority_control c ON c.id=d.control JOIN authority_local_acceptance a ON a.control=c.id AND a.sha256=c.sha256 WHERE d.target=? AND d.eligible=1 ORDER BY c.ordinal DESC LIMIT 1",
                [revisionID])
            defer { sqlite3_finalize(statement) }
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            return try .init(recordID: authorityText(statement, 0), sha256: authorityText(statement, 1))
        }
    }
    func retainedAuthorityPage(after: String? = nil, limit: Int = 128) throws -> [AuthorityStore
        .RetainedObject]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try authorityPageArguments(after: after, limit: limit)
            let condition = after == nil ? "" : " WHERE o.id>?"
            return try authorityRows(
                "SELECT \(Self.authorityColumns) FROM authority_objects o JOIN authority_packages p ON p.object=o.id AND p.package=(SELECT m.package FROM authority_packages m WHERE m.object=o.id ORDER BY m.permitted DESC,m.package LIMIT 1)\(condition) ORDER BY o.id LIMIT ?",
                (after.map { [$0] } ?? []) + [String(limit)])
        }
    }
    func authorityPackagePage(packageID: String, after: String? = nil, limit: Int = 128) throws
        -> [AuthorityStore.RetainedObject]
    {
        try authorityPackageRows(packageID: packageID, after: after, limit: limit, readyOnly: false)
    }
    func authorityReceipt(objectID: String, packageID: String) throws -> AuthorityStore.RetainedObject? {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(objectID))
            _ = try AuthorityRecord.persistentID(.text(packageID))
            return try authorityRows(
                "SELECT \(Self.authorityColumns) FROM authority_packages p JOIN authority_objects o ON o.id=p.object WHERE p.package=? AND p.object=?",
                [packageID, objectID], maximum: Self.authorityMetadataRowBytes
            ).first
        }
    }
    func authorityObjectReceiptPage(objectID: String, afterPackageID: String? = nil, limit: Int = 128) throws
        -> [AuthorityStore.RetainedObject]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(objectID))
            try authorityPageArguments(after: afterPackageID, limit: limit)
            let cursor = afterPackageID == nil ? "" : " AND p.package>?"
            return try authorityRows(
                "SELECT \(Self.authorityColumns) FROM authority_packages p INDEXED BY authority_object_receipts JOIN authority_objects o ON o.id=p.object WHERE p.object=?\(cursor) ORDER BY p.package LIMIT ?",
                [objectID] + (afterPackageID.map { [$0] } ?? []) + [String(limit)])
        }
    }
    func authorityReadyPage(packageID: String, after: String? = nil, limit: Int = 128) throws
        -> [AuthorityStore.RetainedObject]
    {
        try authorityPackageRows(packageID: packageID, after: after, limit: limit, readyOnly: true)
    }
    func authorityDependentPackagePage(parentID: String, after: String? = nil, limit: Int = 128) throws
        -> [String]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(parentID))
            try authorityPageArguments(after: after, limit: limit)
            let cursor = after == nil ? "" : " AND e.package>?"
            let statement = try corpusPrepare(
                "SELECT DISTINCT e.package FROM authority_dependencies e INDEXED BY authority_dependencies_reverse CROSS JOIN authority_dispositions d ON d.object=e.source CROSS JOIN authority_packages p ON p.package=e.package AND p.object=e.source AND p.permitted=1 WHERE e.target=? AND e.kind='packageParent' AND d.state IN('pending','missingDependencies')\(cursor) ORDER BY e.package LIMIT ?",
                [parentID] + (after.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(statement) }
            var result: [String] = []
            var bytes = 0
            while true {
                let status = catalogueStep(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                let size = Int(sqlite3_column_bytes(statement, 0)) + 128
                guard size <= graphMaximumPageBytes - min(bytes, graphMaximumPageBytes) else {
                    if !result.isEmpty { return result }
                    throw TractandaError("resourceLimit", "Dependent-package page cannot fit one key.")
                }
                bytes += size
                let id = try authorityText(statement, 0)
                _ = try AuthorityRecord.persistentID(.text(id))
                result.append(id)
            }
        }
    }
    private func authorityPackageRows(packageID: String, after: String?, limit: Int, readyOnly: Bool) throws
        -> [AuthorityStore.RetainedObject]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(packageID))
            try authorityPageArguments(after: after, limit: limit)
            let cursor = after == nil ? "" : " AND p.object>?"
            let eligible =
                readyOnly
                ? " AND o.kind='item' AND d.state IN('pending','missingDependencies') AND p.permitted=1 AND NOT EXISTS(SELECT 1 FROM authority_dependencies e LEFT JOIN authority_dispositions parent ON parent.object=e.target LEFT JOIN authority_objects input ON input.id=e.target WHERE e.source=o.id AND e.kind='parent' AND (parent.object IS NULL OR parent.state!='eligible' OR input.id IS NULL OR input.kind!='item' OR input.item!=o.item))"
                : ""
            return try authorityRows(
                "SELECT \(Self.authorityColumns) FROM authority_packages p JOIN authority_objects o ON o.id=p.object JOIN authority_dispositions d ON d.object=o.id WHERE p.package=?\(cursor)\(eligible) ORDER BY p.object LIMIT ?",
                [packageID] + (after.map { [$0] } ?? []) + [String(limit)])
        }
    }
    func authorityPendingPackagePage(after: String? = nil, limit: Int = 128) throws -> [String] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try authorityPageArguments(after: after, limit: limit)
            let cursor = after == nil ? "" : " AND package>?"
            let statement = try corpusPrepare(
                "SELECT DISTINCT package FROM authority_packages INDEXED BY authority_package_pending WHERE pending=1\(cursor) ORDER BY package LIMIT ?",
                (after.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(statement) }
            var result: [String] = []
            var bytes = 0
            while true {
                let status = catalogueStep(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                let size = Int(sqlite3_column_bytes(statement, 0)) + 128
                guard size <= graphMaximumPageBytes - min(bytes, graphMaximumPageBytes) else {
                    if !result.isEmpty { return result }
                    throw TractandaError("resourceLimit", "Pending-package page cannot fit one key.")
                }
                bytes += size
                let id = try authorityText(statement, 0)
                _ = try AuthorityRecord.persistentID(.text(id))
                result.append(id)
            }
        }
    }
    func authorityEvidence(revisionID: String) throws -> AuthorityStore.RetainedObject? {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(revisionID))
            return try authorityRows(
                "SELECT \(Self.authorityColumns) FROM authority_evidence_binding b JOIN authority_objects o ON o.id=b.evidence AND o.sha256=b.sha256 JOIN authority_packages p ON p.object=o.id AND p.package=b.package WHERE b.revision=?",
                [revisionID], maximum: Self.authorityMetadataRowBytes
            ).first
        }
    }
    /// Raw retained testimony only. Store validates every candidate and receipt before
    /// selecting an authoritative reference; arrival order never elects one here.
    func authorityEvidenceCandidates(revisionID: String, after: String? = nil, limit: Int = 128) throws
        -> [AuthorityStore.RetainedObject]
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(revisionID))
            try authorityPageArguments(after: after, limit: limit)
            let cursor = after == nil ? "" : " AND o.id>?"
            return try authorityRows(
                "SELECT \(Self.authorityColumns) FROM authority_objects o INDEXED BY authority_evidence_target JOIN authority_packages p ON p.object=o.id AND p.package=(SELECT receipt.package FROM authority_packages receipt WHERE receipt.object=o.id ORDER BY receipt.permitted DESC,receipt.package LIMIT 1) WHERE o.evidence_target=? AND o.evidence_target!=''\(cursor) ORDER BY o.id LIMIT ?",
                [revisionID] + (after.map { [$0] } ?? []) + [String(limit)])
        }
    }
    func authorityParentsAreEligible(revisionID: String) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(revisionID))
            return try authorityNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_objects WHERE id=? AND kind='item') AND NOT EXISTS(SELECT 1 FROM authority_dependencies e JOIN authority_objects child ON child.id=e.source LEFT JOIN authority_dispositions parent ON parent.object=e.target LEFT JOIN authority_objects input ON input.id=e.target WHERE e.source=? AND e.kind='parent' AND (parent.object IS NULL OR parent.state!='eligible' OR input.id IS NULL OR input.kind!='item' OR input.item!=child.item))",
                [revisionID, revisionID]) == 1
        }
    }
    func authorityDisposition(id: String) throws -> AuthorityStore.Evaluation? {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(id))
            let statement = try corpusPrepare(
                "SELECT state,reason FROM authority_dispositions WHERE object=?", [id])
            defer { sqlite3_finalize(statement) }
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, sqlite3_column_bytes(statement, 0) <= 64,
                sqlite3_column_bytes(statement, 1) <= 1024,
                let disposition = AuthorityStore.Disposition(rawValue: try authorityText(statement, 0))
            else { throw authorityInvalid("Malformed or oversized derived disposition.") }
            return .init(disposition: disposition, reason: try authorityText(statement, 1))
        }
    }
    func setAuthorityDisposition(id: String, evaluation: AuthorityStore.Evaluation) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try Task.checkCancellation()
            guard let row = try retainedAuthorityObject(id: id), evaluation.reason.utf8.count <= 1024,
                !evaluation.reason.contains("\0")
            else { throw authorityInvalid("Invalid disposition target/reason.") }
            if evaluation.disposition == .eligible {
                guard row.permittedOrigin else {
                    throw authorityInvalid("Unknown origin cannot become eligible.")
                }
                if row.descriptor.kind == .item, try !authorityParentsAreEligible(revisionID: id) {
                    throw authorityInvalid("Eligible item requires every retained parent eligible.")
                }
            }
            try authorityCapacity(4096)
            try selectAuthorityEvidence(
                revisionID: id,
                evidenceID: evaluation.disposition == .eligible ? evaluation.evidenceID : nil,
                digest: evaluation.disposition == .eligible ? evaluation.evidenceDigest : nil,
                packageID: evaluation.disposition == .eligible ? evaluation.evidencePackageID : nil)
            try execute(
                "UPDATE authority_dispositions SET state=?,reason=? WHERE object=?",
                [evaluation.disposition.rawValue, evaluation.reason, id])
            try execute(
                "UPDATE authority_packages SET pending=permitted AND ? WHERE object=?",
                [
                    (evaluation.disposition == .pending || evaluation.disposition == .missingDependencies)
                        ? "1" : "0", id,
                ])
        }
    }
    /// Only the complete, freshly administered hierarchical cut validator can issue
    /// this capability. Caller holds a private transaction/savepoint until closure.
    func admitPinnedBootstrap(_ target: PeerIntakeCoordinator.BootstrapTarget) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard let item = try retainedAuthorityObject(id: target.revisionID),
                item.descriptor.kind == .item, item.descriptor.sha256 == target.sha256,
                let pin = try retainedAuthorityObject(id: target.pinID),
                pin.descriptor.kind == .authority, pin.descriptor.sha256 == target.pinDigest
            else { throw authorityInvalid("Pinned bootstrap target/control digest mismatch.") }
            let statement = try corpusPrepare(
                "SELECT item.origin,pin.control_kind FROM authority_objects item CROSS JOIN authority_objects pin WHERE item.id=? AND pin.id=?",
                [target.revisionID, target.pinID])
            defer { sqlite3_finalize(statement) }
            guard catalogueStep(statement) == SQLITE_ROW,
                try authorityText(statement, 1) == AuthorityRecord.Kind.bootstrap.rawValue
            else { throw authorityInvalid("Pinned control is not an original bootstrap manifest.") }
            let legacy = try authorityText(statement, 0).isEmpty
            guard legacy || item.permittedOrigin else {
                throw authorityInvalid("Bootstrap cannot enroll an unknown modern origin.")
            }
            try authorityCapacity(8192)
            try execute(
                "INSERT OR IGNORE INTO authority_dependencies VALUES(?,'bootstrap',?,?,'')",
                [target.revisionID, target.pinID, target.pinDigest])
            try stageRestoredAuthorityEligible(
                id: target.revisionID, reason: "Explicit initial bootstrap cut.")
        }
    }
    func restoreSealedEligibility(_ proof: PeerIntakeCoordinator.SealedEligibility) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard let row = try authorityReceipt(objectID: proof.revisionID, packageID: proof.packageID),
                row.descriptor.kind == .item, row.descriptor.sha256 == proof.sha256,
                row.permittedOrigin
            else { throw authorityInvalid("Sealed eligibility proof does not bind its retained receipt.") }
            try authorityCapacity(4096)
            try selectAuthorityEvidence(
                revisionID: proof.revisionID, evidenceID: proof.evidenceID, digest: proof.evidenceDigest,
                packageID: proof.evidencePackageID)
            try stageRestoredAuthorityEligible(
                id: proof.revisionID, reason: "Verified sealed eligibility replay.")
        }
    }
    private func stageRestoredAuthorityEligible(id: String, reason: String) throws {
        try execute(
            "UPDATE authority_dispositions SET state='eligible',reason=? WHERE object=?", [reason, id])
        try execute("UPDATE authority_packages SET pending=0 WHERE object=?", [id])
    }
    private func selectAuthorityEvidence(
        revisionID: String, evidenceID: String?, digest: String?, packageID: String?
    ) throws {
        guard evidenceID != nil || digest != nil || packageID != nil else {
            try execute("DELETE FROM authority_evidence_binding WHERE revision=?", [revisionID])
            return
        }
        guard let evidenceID, let digest, let packageID else {
            throw authorityInvalid("Evidence selection needs its complete reference and receipt.")
        }
        _ = try AuthorityRecord.persistentID(.text(evidenceID))
        _ = try AuthorityRecord.persistentID(.text(packageID))
        _ = try AuthorityRecord.digest(.text(digest))
        guard
            try authorityNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_objects item JOIN authority_objects evidence ON evidence.evidence_target=item.id AND evidence.item=item.item AND evidence.origin=item.origin JOIN authority_packages receipt ON receipt.object=evidence.id JOIN authority_dependencies target ON target.source=evidence.id AND target.kind='target' AND target.target=item.id AND target.sha256=item.sha256 WHERE item.id=? AND item.kind='item' AND evidence.id=? AND evidence.kind='authority' AND evidence.control_kind='authoredEvidence' AND evidence.sha256=? AND receipt.package=? AND receipt.permitted=1 LIMIT 1)",
                [revisionID, evidenceID, digest, packageID]) == 1
        else {
            throw authorityInvalid(
                "Selected evidence does not bind the actual item, issuer, digest and permitted receipt.")
        }
        try execute(
            "INSERT OR REPLACE INTO authority_evidence_binding VALUES(?,?,?,?)",
            [revisionID, evidenceID, digest, packageID])
    }
    func validatePinnedBootstrapClosure(pinID: String) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(pinID))
            guard
                try authorityNumber(
                    "SELECT EXISTS(SELECT 1 FROM authority_dependencies witness INDEXED BY authority_dependencies_reverse JOIN authority_dispositions child ON child.object=witness.source JOIN authority_objects item ON item.id=witness.source AND item.kind='item' JOIN authority_dependencies parent ON parent.source=witness.source AND parent.kind='parent' LEFT JOIN authority_dispositions state ON state.object=parent.target LEFT JOIN authority_objects input ON input.id=parent.target WHERE witness.target=? AND witness.kind='bootstrap' AND child.state='eligible' AND (state.object IS NULL OR state.state!='eligible' OR input.id IS NULL OR input.kind!='item' OR input.item!=item.item) LIMIT 1)",
                    [pinID]) == 0
            else {
                throw authorityInvalid("Pinned bootstrap is not eligible-parent closed.")
            }
        }
    }
    func validateRestoredAuthorityClosure() throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let statement = try corpusPrepare(
                "SELECT child.object,parent.target,COALESCE(state.state,'missing') FROM authority_dispositions child INDEXED BY authority_ready_status JOIN authority_objects item ON item.id=child.object AND item.kind='item' JOIN authority_dependencies parent ON parent.source=child.object AND parent.kind='parent' LEFT JOIN authority_dispositions state ON state.object=parent.target LEFT JOIN authority_objects input ON input.id=parent.target WHERE child.state='eligible' AND (state.object IS NULL OR state.state!='eligible' OR input.id IS NULL OR input.kind!='item' OR input.item!=item.item) LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            let status = catalogueStep(statement)
            guard status == SQLITE_DONE else {
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                throw authorityInvalid(
                    "Replayed eligibility is not retained-parent closed: child=\(try authorityText(statement, 0)) parent=\(try authorityText(statement, 1)) state=\(try authorityText(statement, 2)) provisionalChild=\(try authorityReviewIsProvisional(revisionID: authorityText(statement, 0))) provisionalParent=\(try authorityReviewIsProvisional(revisionID: authorityText(statement, 1)))."
                )
            }
        }
    }
    func clearAuthorityDerivedState() throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try Task.checkCancellation()
            try clearAuthorityControlDerivedState()
            try resetPeerInventoryIfPresent()
            for table in [
                "authority_original_receipts", "authority_walk", "authority_evidence_binding",
                "authority_dependencies",
                "authority_dispositions", "authority_packages",
                "authority_objects",
            ] { try execute("DELETE FROM \(table)") }
            try execute("INSERT INTO authority_walk VALUES('','',0)")
        }
    }
    /// Main-table uniqueness for one caller-owned serialized scan. A restarted token
    /// resets its previous incomplete walk; nested distinct tokens retain separate sets.
    func authorityBeginWalk(token: String) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.text(.text(token))
            try authorityEndWalk(token: token)
            let base = try authorityEstimate(token.utf8.count + 128, entries: 0)
            let current = try authorityWalkCost(token: "")
            let next = try authorityWalkSum(current, base)
            try authorityCapacity(UInt64(next))
            try execute("INSERT INTO authority_walk VALUES(?,'',?)", [token, String(base)])
            try execute("UPDATE authority_walk SET cost=? WHERE token='' AND object=''", [String(next)])
        }
    }
    func authorityVisitOnce(token: String, id: String) throws -> Bool {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try authorityProgressCheck()
            _ = try AuthorityRecord.text(.text(token))
            _ = try AuthorityRecord.persistentID(.text(id))
            guard
                try authorityNumber(
                    "SELECT EXISTS(SELECT 1 FROM authority_walk WHERE token=? AND object='')", [token]) == 1
            else {
                throw authorityInvalid("Authority walk must begin before visiting.")
            }
            if try authorityNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_walk WHERE token=? AND object=?)", [token, id]) == 1
            {
                return false
            }
            let cost = try authorityEstimate(token.utf8.count + id.utf8.count + 128, entries: 0)
            let next = try authorityWalkSum(authorityWalkCost(token: ""), cost)
            let tokenNext = try authorityWalkSum(authorityWalkCost(token: token), cost)
            try authorityCapacity(UInt64(next))
            try execute("INSERT INTO authority_walk VALUES(?,?,?)", [token, id, String(cost)])
            try execute(
                "UPDATE authority_walk SET cost=? WHERE token=? AND object=''", [String(tokenNext), token])
            try execute("UPDATE authority_walk SET cost=? WHERE token='' AND object=''", [String(next)])
            return true
        }
    }
    func authorityEndWalk(token: String) throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.text(.text(token))
            let old = try authorityWalkCost(token: token)
            let current = try authorityWalkCost(token: "")
            guard old >= 0, current >= old else {
                throw authorityInvalid("Authority walk staging counter disagrees.")
            }
            try execute("DELETE FROM authority_walk WHERE token=?", [token])
            try execute(
                "UPDATE authority_walk SET cost=? WHERE token='' AND object=''", [String(current - old)])
        }
    }
    private func authorityWalkCost(token: String) throws -> Int64 {
        let cost = try authorityNumber(
            "SELECT COALESCE((SELECT cost FROM authority_walk WHERE token=? AND object=''),0)", [token])
        guard cost >= 0 else { throw authorityInvalid("Negative authority walk staging.") }
        return cost
    }
    private func authorityWalkSum(_ current: Int64, _ additional: UInt64) throws -> Int64 {
        guard let bytes = Int64(exactly: additional) else {
            throw TractandaError("resourceLimit", "Authority walk staging overflows.")
        }
        let sum = current.addingReportingOverflow(bytes)
        guard !sum.overflow, sum.partialValue >= 0 else {
            throw TractandaError("resourceLimit", "Authority walk staging overflows.")
        }
        return sum.partialValue
    }
    /// Shared bookkeeping after the existing normalized accepted-row insertion.
    /// Callers separately validate local CAS or peer authority; this never selects a body.
    func appendAcceptedGraphBookkeeping(row: CatalogueRow, parents: [String], feedback: [String]) throws
        -> Bool
    {
        let previous = try authorityNumber(
            "SELECT COALESCE(MAX(ordinal),0) FROM recovery_ordinals WHERE item=?", [row.itemID])
        let next = previous.addingReportingOverflow(1)
        guard !next.overflow else {
            throw TractandaError("resourceLimit", "Causal ordinal exhausted its range.")
        }
        try execute(
            "INSERT INTO recovery_ordinals VALUES(?,?,?)",
            [row.itemID, row.revisionID, String(next.partialValue)])
        try execute("INSERT INTO recovery_graph_work VALUES(?,?,0,1)", [row.revisionID, row.itemID])
        if parents.isEmpty {
            try execute(
                "INSERT INTO recovery_roots VALUES(?,?,?)",
                [row.itemID, row.revisionID, row.createdAt])
            try execute(
                "INSERT INTO recovery_item_progress VALUES(?,?)",
                [row.itemID, String(next.partialValue)])
        } else {
            try execute(
                "UPDATE recovery_item_progress SET ordinal=? WHERE item=?",
                [String(next.partialValue), row.itemID])
        }
        var fork = parents.count > 1
        for id in parents {
            if try authorityNumber(
                "SELECT EXISTS(SELECT 1 FROM revision_parents WHERE parent=? AND child!=? LIMIT 1)",
                [id, row.revisionID]) == 1
            {
                fork = true
            }
        }
        if fork { try execute("INSERT OR IGNORE INTO recovery_forks VALUES(?)", [row.itemID]) }
        let linear =
            try authorityNumber("SELECT COUNT(*) FROM recovery_forks WHERE item=?", [row.itemID]) == 0
        for source in feedback {
            guard let target = try self.revision(source), target.itemID == row.itemID,
                source != row.revisionID,
                linear
                    ? (try authorityNumber(
                        "SELECT COUNT(*) FROM recovery_ordinals WHERE revision=? AND item=? AND ordinal<?",
                        [source, row.itemID, String(next.partialValue)]) == 1)
                    : (try graphHasProperAncestor(
                        source: row.revisionID, target: source, progress: nil))
            else {
                throw TractandaError(
                    "invalidRevisionGraph", "Feedback is not a proper causal ancestor.")
            }
        }
        if try authorityNumber("SELECT COUNT(*) FROM recovery_forks WHERE item=?", [row.itemID]) == 0 {
            try execute(
                "INSERT OR REPLACE INTO recovery_heads VALUES(?,?)", [row.itemID, row.revisionID])
        } else {
            try execute("DELETE FROM recovery_heads WHERE item=?", [row.itemID])
        }
        return linear
    }

    private func authorityPageArguments(after: String?, limit: Int) throws {
        guard (1...1024).contains(limit) else {
            throw TractandaError("invalidLimit", "Authority page limit is invalid.")
        }
        if let after { _ = try AuthorityRecord.persistentID(.text(after)) }
    }
    private func optionalAuthorityList(_ value: ItemValue?) throws -> [ItemValue] {
        guard let value else { return [] }
        return try AuthorityRecord.list(value)
    }
    private func validateAuthorityLocator(_ row: AuthorityStore.RetainedObject) throws {
        try row.descriptor.validate()
        _ = try AuthorityRecord.persistentID(.text(row.packageID))
        _ = try AuthorityRecord.text(.text(row.peerID))
        _ = try AuthorityRecord.digest(.text(row.configurationDigest))
        let components = row.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !row.path.isEmpty, row.path.utf8.count <= 4096, !row.path.contains("\0"),
            !row.path.contains("\\"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw authorityInvalid("Retained locator must be a bounded receiver-relative path.") }
    }
    func authorityRows(_ sql: String, _ bindings: [String], maximum: Int? = nil) throws
        -> [AuthorityStore.RetainedObject]
    {
        try Task.checkCancellation()
        let statement = try corpusPrepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let ceiling = min(maximum ?? graphMaximumPageBytes, graphMaximumPageBytes)
        var bytes = 0
        var rows: [AuthorityStore.RetainedObject] = []
        while true {
            try authorityProgressCheck()
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            var size = 512
            for column: Int32 in 0..<9 {
                let amount = Int(sqlite3_column_bytes(statement, column))
                guard amount <= Self.authorityMetadataRowBytes - min(size, Self.authorityMetadataRowBytes)
                else {
                    throw TractandaError("resourceLimit", "Authority locator row exceeds its byte window.")
                }
                size += amount
            }
            guard size <= ceiling - min(bytes, ceiling) else {
                if !rows.isEmpty { return rows }
                throw TractandaError("resourceLimit", "Authority page cannot fit one complete locator.")
            }
            bytes += size
            rows.append(try authorityRetainedRow(statement))
        }
    }
    /// The caller bounds bytes before decoding; shared by ordinary and sequenced pages.
    func authorityRetainedRow(_ statement: OpaquePointer) throws -> AuthorityStore.RetainedObject {
        guard let kind = PeerPackage.Kind(rawValue: try authorityText(statement, 1)),
            let length = Int(exactly: sqlite3_column_int64(statement, 2))
        else { throw authorityInvalid("Invalid retained descriptor.") }
        let row = AuthorityStore.RetainedObject(
            descriptor: .init(
                kind: kind, id: try authorityText(statement, 0), length: length,
                sha256: try authorityText(statement, 3)),
            path: try authorityText(statement, 4), packageID: try authorityText(statement, 5),
            peerID: try authorityText(statement, 6),
            configurationDigest: try authorityText(statement, 7),
            permittedOrigin: sqlite3_column_int(statement, 8) != 0)
        try validateAuthorityLocator(row)
        return row
    }
    private func authorityText(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_bytes(statement, column) <= Self.authorityMetadataRowBytes else {
            throw TractandaError("resourceLimit", "Authority text exceeds its point window.")
        }
        guard let pointer = sqlite3_column_text(statement, column),
            let value = String(
                bytes: UnsafeBufferPointer(
                    start: pointer, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
        else { throw authorityInvalid("Invalid UTF8 authority metadata.") }
        return value
    }
    private func authorityNumber(_ sql: String, _ bindings: [String] = []) throws -> Int64 {
        let statement = try corpusPrepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard catalogueStep(statement) == SQLITE_ROW else { throw graphSQLiteError() }
        return sqlite3_column_int64(statement, 0)
    }
    private func authorityEstimate(_ bytes: Int, entries: Int) throws -> UInt64 {
        let count = entries.multipliedReportingOverflow(by: 512)
        let sum = bytes.addingReportingOverflow(count.partialValue)
        guard !count.overflow, !sum.overflow, sum.partialValue >= 0 else {
            throw TractandaError("resourceLimit", "Authority staging estimate overflowed.")
        }
        let estimate = UInt64(sum.partialValue).multipliedReportingOverflow(by: 4)
        guard !estimate.overflow else {
            throw TractandaError("resourceLimit", "Authority staging estimate overflowed.")
        }
        return estimate.partialValue
    }
    /// SQLite's VM callback may never fire across many individually short statements.
    /// Keep explicit boundaries for the caller's native/GCD cancellation and liveness control.
    private func authorityProgressCheck() throws {
        try checkCatalogueScanProgress()
    }
    private func authorityCapacity(_ bytes: UInt64) throws {
        try authorityProgressCheck()
        guard bytes <= graphMaximumTemporaryBytes else {
            throw TractandaError("resourceLimit", "Authority metadata staging exceeds its byte window.")
        }
        try requireGraphCapacity(additionalBytes: bytes)
    }
    private func authorityInvalid(_ message: String) -> TractandaError {
        .init("invalidAuthorityInventory", message)
    }
    func authorityKindPage(
        kind: String, after: String? = nil, limit: Int = 128, packageID: String? = nil
    ) throws -> [AuthorityStore.RetainedObject] {
        try authorityPageArguments(after: after, limit: limit)
        return try authorityRows(
            "SELECT \(Self.authorityColumns) FROM authority_objects o INDEXED BY authority_kind JOIN authority_packages p ON p.object=o.id WHERE o.control_kind=?"
                + (after == nil ? "" : " AND o.id>?")
                + (packageID == nil
                    ? " AND p.package=(SELECT MIN(r.package) FROM authority_packages r WHERE r.object=o.id)"
                    : " AND p.package=?") + " ORDER BY o.id LIMIT ?",
            [kind] + (after.map { [$0] } ?? []) + (packageID.map { [$0] } ?? []) + [String(limit)])
    }

    /// Exact retained ancestry remains available after current eligibility demotion.
    /// SQL recursion is deduplicated and uses the existing cumulative catalogue VM/work budget.
    func authorityRetainedHasAncestor(source: String, target: String) throws -> Bool {
        try authorityNumber(
            "SELECT EXISTS(WITH RECURSIVE ancestors(id) AS (SELECT target FROM authority_dependencies WHERE source=? AND kind='parent' UNION SELECT edge.target FROM authority_dependencies edge JOIN ancestors a ON edge.source=a.id WHERE edge.kind='parent') SELECT 1 FROM ancestors WHERE id=?)",
            [source, target]) == 1
    }

    func authorityRetirementTargetPage(origin: String, cutoff: Int64, after: (Int64, String)? = nil) throws
        -> [AuthorityStore.RetainedObject]
    {
        try authorityRows(
            "SELECT \(Self.authorityColumns) FROM authority_objects o INDEXED BY authority_origin_issued JOIN authority_dispositions d ON d.object=o.id JOIN authority_packages p ON p.object=o.id WHERE o.origin=? AND o.issued>=CAST(? AS INTEGER) AND o.kind='item' AND d.state IN('eligible','pending','missingDependencies') AND p.permitted=1 AND p.package=(SELECT MIN(r.package) FROM authority_packages r WHERE r.object=o.id AND r.permitted=1)"
                + (after == nil ? "" : " AND (o.issued,o.id)>(CAST(? AS INTEGER),?)")
                + " ORDER BY o.issued,o.id LIMIT 128",
            [origin, String(cutoff)] + (after.map { [String($0.0), $0.1] } ?? []))
    }

}
