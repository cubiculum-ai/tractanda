import Crypto
import Foundation
import TractandaCore

/// A caller-side boundary over ordinary native methods. It grants no store access itself.
public protocol ImportTransport {
    func binding() throws -> ImportBinding
    func imported(namespace: String, limits: ImportLimits) throws -> [ImportItemSnapshot]
    func revision(itemID: String, revisionID: String?) throws -> ImportItemSnapshot
    func commit(_ request: CommitRequest) throws -> MutationReceipt
    func beginAttachment(_ request: AttachmentUploadRequest) throws -> AttachmentUploadResult
    func appendAttachment(uploadID: String, offset: Int64, data: Data) throws -> Int64
    func finishAttachment(uploadID: String) throws -> AttachmentCommitResult
    func attachmentContent(itemID: String, revisionID: String, attachmentID: String, offset: Int64) throws
        -> AttachmentContentResult
}

/// Synchronous ordinary-user adapter. Stable session account/name and endpoint bind the outbox;
/// process IDs, session/query states, credentials and filesystem device IDs never bind retries.
public final class CoreImportTransport: ImportTransport {
    public let client: ItemClient
    public let endpoint: String
    public init(client: ItemClient, endpoint: String) {
        self.client = client
        self.endpoint = endpoint
    }

    public func binding() throws -> ImportBinding {
        guard
            let session = try JSONSerialization.jsonObject(with: client.call("TractandaSession/get"))
                as? [String: Any],
            let primary = session["primaryAccounts"] as? [String: String],
            let store = primary[ItemService.capability], let principal = session["username"] as? String,
            ImportHash.validIdentity(store), ImportHash.validIdentity(principal),
            ImportHash.validIdentity(endpoint)
        else {
            throw TractandaError(
                "importBinding", "Server did not identify the authenticated account and store.")
        }
        return ImportBinding(storeID: store, principal: principal, endpoint: endpoint)
    }

    public func imported(namespace: String, limits: ImportLimits) throws -> [ImportItemSnapshot] {
        guard
            let info = try JSONSerialization.jsonObject(with: client.call("TractandaStore/info"))
                as? [String: Any],
            let features = info["features"] as? [String],
            features.contains("tractanda.query-include-deleted.v1")
        else {
            throw TractandaError(
                "importDiscoveryUnavailable", "Import requires explicit tombstone-inclusive query support.")
        }
        let literal = String(data: try JSONEncoder().encode(namespace), encoding: .utf8)!
        let expression = "importSchema == \"" + ImportFields.schema + "\" && importNamespace == " + literal
        var result: [ImportItemSnapshot] = []
        var position = 0
        var queryState: String?
        let initialState = try JSON.decode(
            JMAPItemGetResponse.self, client.call("TractandaItem/get", arguments: ["ids": [String]()])
        ).state
        var bytes = 0
        var seen: Set<String> = []
        while true {
            try Task.checkCancellation()
            let data = try client.query(criteria: [
                "expression": expression, "includeDeleted": true, "position": position, "limit": 64,
            ])
            guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ids = page["ids"] as? [String], let total = page["total"] as? Int,
                let actualPosition = page["position"] as? Int, actualPosition == position,
                let state = page["queryState"] as? String, !state.isEmpty,
                page["completeness"] as? String != "unresolvedItems",
                total <= limits.maximumRecords, total >= 0, ids.count <= 64,
                ids.count <= max(0, total - position), ids.allSatisfy({ seen.insert($0).inserted }),
                queryState == nil || queryState == state
            else {
                throw TractandaError(
                    "importDiscoveryIncomplete",
                    "Imported-item discovery was incomplete, changed or exceeded its budget.")
            }
            queryState = state
            // Each content DTO is individually bounded by the native response budget. A page
            // of IDs must never become one 64-body response; receipt/ancestry bytes are not used.
            for id in ids {
                let fetched = try JSON.decode(
                    JMAPItemGetResponse.self,
                    client.call("TractandaItem/get", arguments: ["ids": [id], "projection": "content"]))
                guard fetched.notFound.isEmpty, fetched.remainingIDs.isEmpty,
                    fetched.oversizedIDs.isEmpty, fetched.list.count == 1,
                    fetched.list[0].id == id, initialState == fetched.state
                else {
                    throw TractandaError(
                        "importDiscoveryIncomplete", "Imported records changed or could not be fully read.")
                }
                let snapshot = try Self.snapshot(fetched.list[0])
                let size = try JSON.encode(snapshot).count
                guard size <= limits.maximumProjectionBytes + 1024 * 1024,
                    bytes <= limits.maximumJournalBytes - size,
                    snapshot.fields["importSchema"]?.string == ImportFields.schema,
                    snapshot.fields["importNamespace"]?.string == namespace
                else {
                    throw TractandaError(
                        "importDiscoveryIncomplete",
                        "Imported record identity or discovery byte budget is invalid.")
                }
                bytes += size
                result.append(snapshot)
            }
            position += ids.count
            if position >= total { break }
            guard !ids.isEmpty else {
                throw TractandaError("importDiscoveryIncomplete", "Discovery did not advance.")
            }
        }
        // A zero-length get observes the same caller-scoped state without hydrating content.
        let observed = try JSON.decode(
            JMAPItemGetResponse.self, client.call("TractandaItem/get", arguments: ["ids": [String]()]))
        guard observed.state == initialState else {
            throw TractandaError("stateChanged", "Items changed during import discovery.")
        }
        return result
    }

    public func revision(itemID: String, revisionID: String?) throws -> ImportItemSnapshot {
        if let revisionID {
            let result = try JSON.decode(
                JMAPRevisionGetResponse.self,
                client.call(
                    "TractandaRevision/get", arguments: ["ids": [revisionID], "projection": "content"]))
            guard result.notFound.isEmpty, result.list.count == 1, let record = result.list.first,
                record.id == revisionID, record.itemID == itemID, let fields = record.fields
            else {
                throw TractandaError("importProjection", "Exact import revision projection was not returned.")
            }
            return try ImportItemSnapshot(itemID: itemID, revisionID: revisionID, fields: fields)
        }
        let result = try JSON.decode(
            JMAPItemGetResponse.self,
            client.call("TractandaItem/get", arguments: ["ids": [itemID], "projection": "content"]))
        guard result.notFound.isEmpty, result.remainingIDs.isEmpty, result.oversizedIDs.isEmpty,
            result.list.count == 1, result.list[0].id == itemID
        else {
            throw TractandaError("importProjection", "Current import content projection was not returned.")
        }
        return try Self.snapshot(result.list[0])
    }
    private static func snapshot(_ record: JMAPItemRecord) throws -> ImportItemSnapshot {
        guard record.resolution == nil || record.resolution?.status == .ready,
            let revisionID = record.revisionID, let fields = record.fields
        else {
            throw TractandaError(
                "importProjection", "Import record is unresolved or its content projection is incomplete.")
        }
        return try ImportItemSnapshot(itemID: record.id, revisionID: revisionID, fields: fields)
    }
    public func commit(_ request: CommitRequest) throws -> MutationReceipt { try client.commit(request) }
    public func beginAttachment(_ request: AttachmentUploadRequest) throws -> AttachmentUploadResult {
        try client.beginAttachment(request)
    }
    public func appendAttachment(uploadID: String, offset: Int64, data: Data) throws -> Int64 {
        try client.appendAttachment(uploadID: uploadID, offset: offset, data: data)
    }
    public func finishAttachment(uploadID: String) throws -> AttachmentCommitResult {
        try client.finishAttachment(uploadID: uploadID)
    }
    public func attachmentContent(itemID: String, revisionID: String, attachmentID: String, offset: Int64)
        throws -> AttachmentContentResult
    {
        try client.attachmentContent(
            itemID: itemID, revisionID: revisionID, attachmentID: attachmentID, offset: offset)
    }
}

public final class ImportEngine {
    private let transport: any ImportTransport
    public init(transport: any ImportTransport) { self.transport = transport }
    public convenience init(client: ItemClient, endpoint: String) {
        self.init(transport: CoreImportTransport(client: client, endpoint: endpoint))
    }

    public func preview(_ plan: ImportPlan) throws -> ImportReport {
        try plan.validate()
        _ = try transport.binding()
        let existing = try transport.imported(namespace: plan.namespace, limits: plan.limits)
        return try decisions(plan, existing: existing)
    }

    public func apply(_ plan: ImportPlan, journal: ImportJournal) throws -> ImportReport {
        try plan.validate()
        guard !journal.exists else {
            throw TractandaError(
                "importJournalExists", "Resume the existing exact journal instead of replacing it.")
        }
        try verifySources(plan)
        let binding = try transport.binding()
        let existing = try transport.imported(namespace: plan.namespace, limits: plan.limits)
        var state = try ImportJournalState(plan: plan, binding: binding)
        state.report = try decisions(plan, existing: existing)
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.itemID, $0) })
        for outcome in state.report.outcomes where state.records[outcome.sourceID] != nil {
            var progress = state.records[outcome.sourceID]!
            progress.originalDisposition = outcome.disposition
            progress.itemID = outcome.itemID
            progress.revisionID = outcome.revisionID
            progress.outcome = outcome
            if ![ImportDisposition.create, .update].contains(outcome.disposition) {
                progress.phase = .skipped
            }
            if let itemID = outcome.itemID, let previous = existingByID[itemID] {
                progress.aliases = aliases(previous)
                if previous.fields["importSourceID"]?.string != outcome.sourceID,
                    let old = previous.fields["importSourceID"]?.string
                {
                    progress.aliases.append(old)
                }
                progress.previousManagedFields = managedFields(previous)
                progress.originalAttachmentID =
                    previous.fields["importMetadata"]?.map?["originalAttachmentID"]?.string
            }
            state.records[outcome.sourceID] = progress
        }
        state.refreshReport()
        try journal.save(state)
        return try run(&state, journal: journal, initialExisting: existing)
    }

    public func resume(journal: ImportJournal) throws -> ImportReport {
        var state = try journal.load()
        guard try transport.binding() == state.binding else {
            throw TractandaError(
                "importBinding", "Retained intent belongs to another store, principal or endpoint.")
        }
        // Reconcile exact uncertain requests before consulting local sources. A completed
        // original or fully received stage can finish even after the selected directory is gone.
        let needed = state.plan.records.filter { record in
            let progress = state.records[record.sourceID]!
            return (progress.phase == .planned && progress.pendingCommit == nil)
                || (progress.phase == .admitted && progress.pendingUpload == nil
                    && progress.originalAttachmentID == nil)
        }
        if !needed.isEmpty { try verifySources(state.plan, records: needed) }
        let existing = try transport.imported(namespace: state.plan.namespace, limits: state.plan.limits)
        return try run(&state, journal: journal, initialExisting: existing)
    }

    private func run(
        _ state: inout ImportJournalState, journal: ImportJournal, initialExisting: [ImportItemSnapshot]
    ) throws -> ImportReport {
        guard try transport.binding() == state.binding else {
            throw TractandaError("importBinding", "Import destination changed.")
        }
        let initialMapping = identityMap(initialExisting)
        // Phase one establishes all server-issued IDs, including cyclic/forward-link targets.
        for record in state.plan.records where state.records[record.sourceID]!.phase == .planned {
            try admit(record, mapping: initialMapping, state: &state, journal: journal)
        }
        // Originals are canonical before any Item is declared complete.
        for record in state.plan.records where state.records[record.sourceID]!.phase == .admitted {
            try upload(record, state: &state, journal: journal)
        }
        let discovered = try transport.imported(namespace: state.plan.namespace, limits: state.plan.limits)
        let mapping = identityMap(discovered)
        // A newly imported or removed target can change navigation while the source bytes stay
        // identical. Refresh derived links only where the last managed projection is unchanged.
        for record in state.plan.records {
            var progress = state.records[record.sourceID]!
            guard progress.phase == .skipped, progress.outcome?.disposition == .unchanged else { continue }
            let current = try checkedCurrent(progress, namespace: state.plan.namespace)
            let links = ItemValue.list(record.links.map { linkValue($0, mapping: mapping) })
            guard current.fields["importLinks"] != links else { continue }
            guard let originalID = progress.originalAttachmentID,
                try AttachmentDescriptor.descriptors(in: current.fields).contains(where: {
                    $0.attachmentID == originalID && $0.sha256 == record.original.sha256
                        && $0.byteCount == record.original.byteCount
                })
            else {
                throw TractandaError(
                    "importOriginalReadback",
                    "Cannot refresh navigation without a verified completed source original.")
            }
            progress.phase = .originalStored
            progress.originalDisposition = .update
            state.records[record.sourceID] = progress
            try journal.saveRecord(sourceID: record.sourceID, progress: progress)
        }
        for record in state.plan.records where state.records[record.sourceID]!.phase == .originalStored {
            try finalize(record, mapping: mapping, state: &state, journal: journal)
        }
        let final = try transport.imported(namespace: state.plan.namespace, limits: state.plan.limits)
        let finalMap = identityMap(final)
        for record in state.plan.records {
            if let candidates = finalMap[record.sourceID], Set(candidates.map(\.itemID)).count > 1 {
                state.records[record.sourceID]?.outcome = ImportOutcome(
                    sourceID: record.sourceID, disposition: .duplicate,
                    diagnostics: [
                        ImportDiagnostic(
                            "duplicateSourceIdentity",
                            "Concurrent same-namespace imports produced multiple readable Items; reconcile explicitly.",
                            severity: .error)
                    ])
                try journal.saveRecord(sourceID: record.sourceID, progress: state.records[record.sourceID]!)
            }
        }
        state.refreshReport()
        return state.report
    }

    private func decisions(_ plan: ImportPlan, existing: [ImportItemSnapshot]) throws -> ImportReport {
        let mapping = identityMap(existing)
        var outcomes: [ImportOutcome] = []
        let previousIDByNew = Dictionary(uniqueKeysWithValues: plan.renames.map { ($0.value, $0.key) })
        for record in plan.records {
            var candidates = mapping[record.sourceID] ?? []
            if let old = previousIDByNew[record.sourceID] { candidates += mapping[old] ?? [] }
            let unique = Dictionary(
                candidates.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
            guard unique.count <= 1 else {
                outcomes.append(
                    ImportOutcome(
                        sourceID: record.sourceID, disposition: .duplicate,
                        diagnostics: [
                            ImportDiagnostic(
                                "duplicateSourceIdentity",
                                "More than one readable Item claims this source identity: "
                                    + unique.keys.sorted().joined(separator: ", "), severity: .error)
                        ]))
                continue
            }
            guard let current = unique.values.first else {
                outcomes.append(
                    ImportOutcome(
                        sourceID: record.sourceID, disposition: .create, diagnostics: record.diagnostics))
                continue
            }
            let outcome: ImportDisposition
            if current.isDeleted {
                outcome = .tombstone
            } else if current.fields["importState"]?.string != "complete" {
                outcome = .incomplete
            } else {
                let baseline = current.fields["importProjectionSHA256"]?.string
                let currentHash = try projectionHash(current.fields, fields: managedFields(current))
                let inputSHA = try ImportHash.digest(record)
                let inputSame =
                    current.fields["importSourceSHA256"]?.string == record.original.sha256
                    && current.fields["importAdapter"]?.string == plan.adapter
                    && current.fields["importInputSHA256"]?.string == inputSHA
                    && current.fields["importSourceID"]?.string == record.sourceID
                if inputSame {
                    outcome = baseline == currentHash ? .unchanged : .localDivergence
                } else {
                    outcome = baseline == currentHash && baseline != nil ? .update : .conflict
                }
            }
            var diagnostics = record.diagnostics
            if outcome == .incomplete {
                diagnostics.append(
                    ImportDiagnostic(
                        "incompleteImport",
                        "Resume its exact retained journal; without that journal reconcile the incomplete Item before writing.",
                        severity: .error))
            }
            if outcome == .tombstone {
                diagnostics.append(
                    ImportDiagnostic(
                        "sourceTombstone",
                        "The imported Item is deleted. Import never restores it automatically.",
                        severity: .warning))
            }
            if outcome == .conflict {
                diagnostics.append(
                    ImportDiagnostic(
                        "sourceLocalConflict",
                        "Both source/mapping and importer-managed local content changed; reconcile explicitly.",
                        severity: .error))
            }
            outcomes.append(
                ImportOutcome(
                    sourceID: record.sourceID, disposition: outcome, itemID: current.itemID,
                    revisionID: current.revisionID, diagnostics: diagnostics))
        }
        let selected = Set(plan.records.map(\.sourceID)).union(plan.renames.keys)
        for current in existing {
            if let sourceID = current.fields["importSourceID"]?.string, !selected.contains(sourceID) {
                outcomes.append(
                    ImportOutcome(
                        sourceID: sourceID, disposition: .missing, itemID: current.itemID,
                        revisionID: current.revisionID,
                        diagnostics: [
                            ImportDiagnostic(
                                "sourceNotSelected",
                                "Previously imported source is absent from this selection; no deletion is performed.",
                                severity: .information)
                        ]))
            }
        }
        return ImportReport(
            namespace: plan.namespace, outcomes: outcomes,
            diagnostics: [
                ImportDiagnostic(
                    "singleWriterNamespace",
                    "Use one active writer per namespace. Duplicate detection is scoped to readable Items and is not distributed uniqueness.",
                    severity: .information)
            ])
    }

    private func admit(
        _ record: ImportRecord, mapping: [String: [ImportItemSnapshot]], state: inout ImportJournalState,
        journal: ImportJournal
    ) throws {
        var progress = state.records[record.sourceID]!
        if progress.pendingCommit == nil {
            if progress.originalDisposition == .create {
                // The bounded initial map and final duplicate scan implement the documented
                // single-writer workflow; there is deliberately no per-record full-store scan.
                guard mapping[record.sourceID]?.isEmpty != false else {
                    throw TractandaError(
                        "importIdentityChanged",
                        "A source identity is already present; reconcile before creating.")
                }
            } else {
                let current = try checkedCurrent(progress, namespace: state.plan.namespace)
                guard current.fields["importState"]?.string == "complete",
                    try projectionHash(current.fields, fields: managedFields(current))
                        == current.fields["importProjectionSHA256"]?.string
                else {
                    throw TractandaError("importConflict", "Local imported content changed after preview.")
                }
            }
            var fields: [String: ItemValue] = [
                "importSchema": .text(ImportFields.schema), "importNamespace": .text(state.plan.namespace),
                "importSourceID": .text(record.sourceID), "importAdapter": .text(state.plan.adapter),
                "importState": .text("incomplete"),
                "importSourceIDAliases": .list(Set(progress.aliases).sorted().map(ItemValue.text)),
            ]
            var metadata = record.metadata
            metadata["sourcePath"] = .text(record.original.relativePath)
            metadata["pendingSourceSHA256"] = .text(record.original.sha256)
            metadata["pendingPhase"] = .text("original")
            fields["importMetadata"] = .object(metadata)
            if progress.originalDisposition == .create { fields.merge(record.projection) { _, new in new } }
            let request = CommitRequest(
                action: progress.originalDisposition == .create ? .create : .revise,
                itemID: progress.itemID, expectedRevisionID: progress.revisionID,
                classID: progress.originalDisposition == .create ? "Item" : nil, changes: fields,
                operationID: operationID())
            progress.pendingCommit = request
            progress.pendingCommitBytes = try JSON.encode(request)
            state.records[record.sourceID] = progress
            try journal.saveRecord(sourceID: record.sourceID, progress: state.records[record.sourceID]!)
        }
        try commitPending(record, state: &state, journal: journal, resultingPhase: .admitted)
    }

    private func upload(_ record: ImportRecord, state: inout ImportJournalState, journal: ImportJournal)
        throws
    {
        var progress = state.records[record.sourceID]!
        if progress.pendingUpload == nil {
            let current = try checkedCurrent(progress, namespace: state.plan.namespace)
            // Mapping-only changes and explicit renames retain the already verified exact
            // original instead of appending a duplicate attachment with identical bytes.
            if let originalID = progress.originalAttachmentID,
                let retained = try AttachmentDescriptor.descriptors(in: current.fields).first(where: {
                    $0.attachmentID == originalID && $0.sha256 == record.original.sha256
                        && $0.byteCount == record.original.byteCount
                })
            {
                try verifyOriginal(record.original, descriptor: retained, revision: current)
                progress.phase = .originalStored
                state.records[record.sourceID] = progress
                try journal.saveRecord(sourceID: record.sourceID, progress: state.records[record.sourceID]!)
                return
            }
            guard
                try AttachmentDescriptor.descriptors(in: current.fields).count
                    < AttachmentDescriptor.maximumAttachments
            else {
                throw TractandaError(
                    "importAttachmentLimit",
                    "Original retention reached the Item attachment limit; reconcile retention explicitly.")
            }
            let request = AttachmentUploadRequest(
                itemID: current.itemID, expectedRevisionID: current.revisionID,
                operationID: operationID(), filename: record.original.filename,
                mediaType: record.original.mediaType,
                byteCount: record.original.byteCount, sha256: record.original.sha256)
            progress.pendingUpload = request
            progress.pendingUploadBytes = try JSON.encode(request)
            state.records[record.sourceID] = progress
            try journal.saveRecord(sourceID: record.sourceID, progress: state.records[record.sourceID]!)
        }
        let request = progress.pendingUpload!
        let admission = try transport.beginAttachment(request)
        let sameHandle = progress.uploadID != nil && progress.uploadID == admission.uploadID
        guard admission.attachment.filename == request.filename,
            admission.attachment.mediaType == request.mediaType,
            admission.attachment.byteCount == request.byteCount,
            admission.attachment.sha256 == request.sha256,
            (0...request.byteCount).contains(admission.offset), (1...262_144).contains(admission.chunkBytes),
            !sameHandle || progress.uploadAttachmentID == nil
                || progress.uploadAttachmentID == admission.attachment.attachmentID
        else {
            throw TractandaError(
                "importUpload", "Original admission differs from the exact retained request.")
        }
        if let previous = progress.uploadID, let next = admission.uploadID, previous != next {
            if !progress.events.contains(where: { $0.code == "uploadRestarted" }) {
                progress.events.append(
                    ImportDiagnostic(
                        "uploadRestarted",
                        "An expired uncommitted original received a new server handle for the same exact retained intent.",
                        severity: .information, sourceID: record.sourceID))
            }
        }
        progress.uploadID = admission.uploadID
        progress.uploadAttachmentID = admission.attachment.attachmentID
        progress.acknowledgedOffset = admission.offset
        state.records[record.sourceID] = progress
        try journal.saveRecord(sourceID: record.sourceID, progress: state.records[record.sourceID]!)
        let receipt: AttachmentCommitResult
        if let committed = admission.committed {
            receipt = committed
        } else {
            guard let uploadID = admission.uploadID else {
                throw TractandaError("importUpload", "Original admission returned no upload identity.")
            }
            var offset = admission.offset
            if offset < request.byteCount {
                let source = try ImportSourceFiles(
                    root: URL(fileURLWithPath: state.plan.sourceRoot), limits: state.plan.limits
                ).open(relativePath: record.original.relativePath)
                guard source.sha256 == record.original.sha256, source.byteCount == record.original.byteCount
                else {
                    throw TractandaError(
                        "importSourceChanged", "Selected original changed; exact intent remains retained.")
                }
                while offset < request.byteCount {
                    let bytes = try source.chunk(offset: offset, limit: admission.chunkBytes)
                    guard !bytes.isEmpty else {
                        throw TractandaError("importSourceChanged", "Selected source stopped advancing.")
                    }
                    let next = try transport.appendAttachment(uploadID: uploadID, offset: offset, data: bytes)
                    guard next == offset + Int64(bytes.count) else {
                        throw TractandaError("importUpload", "Original acknowledgement offset changed.")
                    }
                    offset = next
                    progress.acknowledgedOffset = offset
                    state.records[record.sourceID] = progress
                    try journal.saveRecord(
                        sourceID: record.sourceID, progress: state.records[record.sourceID]!)
                }
                try source.verifyUnchanged()
            }
            receipt = try transport.finishAttachment(uploadID: uploadID)
        }
        guard receipt.itemID == request.itemID, receipt.operationID == request.operationID else {
            throw TractandaError("importUpload", "Original receipt differs from exact intent.")
        }
        let saved = try transport.revision(itemID: receipt.itemID, revisionID: receipt.revisionID)
        guard saved.fields["operationID"]?.string == request.operationID,
            try AttachmentDescriptor.descriptors(in: saved.fields).contains(admission.attachment)
        else {
            throw TractandaError(
                "importUpload", "Saved original descriptor was not found at the receipt revision.")
        }
        try verifyOriginal(record.original, descriptor: admission.attachment, revision: saved)
        progress.phase = .originalStored
        progress.revisionID = saved.revisionID
        progress.originalAttachmentID = admission.attachment.attachmentID
        progress.pendingUpload = nil
        progress.pendingUploadBytes = nil
        progress.uploadID = nil
        state.records[record.sourceID] = progress
        try journal.saveRecord(sourceID: record.sourceID, progress: state.records[record.sourceID]!)
    }

    private func finalize(
        _ record: ImportRecord, mapping: [String: [ImportItemSnapshot]], state: inout ImportJournalState,
        journal: ImportJournal
    ) throws {
        var progress = state.records[record.sourceID]!
        if progress.pendingCommit == nil {
            _ = try checkedCurrent(progress, namespace: state.plan.namespace)
            var fields = record.projection
            fields["importLinks"] = .list(record.links.map { link in linkValue(link, mapping: mapping) })
            let keys = fields.keys.sorted()
            let projectionSHA = try projectionHash(fields, fields: keys)
            fields["importManagedFields"] = .list(keys.map(ItemValue.text))
            fields["importProjectionSHA256"] = .text(projectionSHA)
            fields["importInputSHA256"] = .text(try ImportHash.digest(record))
            fields["importSourceSHA256"] = .text(record.original.sha256)
            fields["importState"] = .text("complete")
            var metadata = record.metadata
            metadata["sourcePath"] = .text(record.original.relativePath)
            metadata["sourceByteCount"] = .integer(record.original.byteCount)
            metadata["sourceMediaType"] = .text(record.original.mediaType)
            metadata["originalAttachmentID"] = .text(progress.originalAttachmentID!)
            fields["importMetadata"] = .object(metadata)
            let selectedKeys = Set(keys)
            let unset = progress.previousManagedFields.filter {
                !selectedKeys.contains($0) && fields[$0] == nil
            }
            let request = CommitRequest(
                action: .revise, itemID: progress.itemID, expectedRevisionID: progress.revisionID,
                changes: fields, unset: unset, operationID: operationID())
            progress.pendingCommit = request
            progress.pendingCommitBytes = try JSON.encode(request)
            state.records[record.sourceID] = progress
            try journal.saveRecord(sourceID: record.sourceID, progress: state.records[record.sourceID]!)
        }
        try commitPending(record, state: &state, journal: journal, resultingPhase: .complete)
    }

    private func commitPending(
        _ record: ImportRecord, state: inout ImportJournalState, journal: ImportJournal,
        resultingPhase: ImportRecordProgress.Phase
    ) throws {
        let sourceID = record.sourceID
        var progress = state.records[sourceID]!
        let request = progress.pendingCommit!
        let receipt = try transport.commit(request)
        guard receipt.operationID == request.operationID,
            request.action == .create || receipt.itemID == request.itemID
        else {
            throw TractandaError("importReceipt", "Commit acknowledgement differs from retained intent.")
        }
        let saved = try transport.revision(itemID: receipt.itemID, revisionID: receipt.revisionID)
        guard saved.itemID == receipt.itemID, saved.revisionID == receipt.revisionID,
            saved.fields["operationID"]?.string == request.operationID,
            request.changes.allSatisfy({ saved.fields[$0.key] == $0.value }),
            request.unset.allSatisfy({ saved.fields[$0] == nil })
        else {
            throw TractandaError(
                "importReadback", "Immutable revision does not match the exact import intent.")
        }
        progress.itemID = saved.itemID
        progress.revisionID = saved.revisionID
        progress.pendingCommit = nil
        progress.pendingCommitBytes = nil
        progress.phase = resultingPhase
        if resultingPhase == .complete {
            progress.outcome = ImportOutcome(
                sourceID: sourceID, disposition: progress.originalDisposition,
                itemID: saved.itemID, revisionID: saved.revisionID, diagnostics: record.diagnostics)
        }
        state.records[sourceID] = progress
        try journal.saveRecord(sourceID: record.sourceID, progress: state.records[record.sourceID]!)
    }

    private func verifyOriginal(
        _ original: ImportOriginal, descriptor: AttachmentDescriptor, revision: ImportItemSnapshot
    ) throws {
        var offset: Int64 = 0
        var hash = Crypto.SHA256()
        repeat {
            let part = try transport.attachmentContent(
                itemID: revision.itemID, revisionID: revision.revisionID,
                attachmentID: descriptor.attachmentID, offset: offset)
            guard part.attachment == descriptor, part.offset == offset, part.data.count <= 262_144,
                part.nextOffset == offset + Int64(part.data.count), part.nextOffset <= original.byteCount,
                part.isComplete == (part.nextOffset == original.byteCount),
                !part.data.isEmpty || part.isComplete
            else {
                throw TractandaError(
                    "importOriginalReadback", "Original readback did not match its pinned descriptor.")
            }
            hash.update(data: part.data)
            offset = part.nextOffset
            if part.isComplete { break }
        } while true
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard offset == original.byteCount, digest == original.sha256 else {
            throw TractandaError(
                "importOriginalReadback", "Saved original bytes differ from selected source.")
        }
    }

    private func checkedCurrent(_ progress: ImportRecordProgress, namespace: String) throws
        -> ImportItemSnapshot
    {
        guard let itemID = progress.itemID, let revisionID = progress.revisionID else {
            throw TractandaError("importJournal", "Missing admitted Item identity.")
        }
        let current = try transport.revision(itemID: itemID, revisionID: nil)
        guard current.revisionID == revisionID, !current.isDeleted,
            current.fields["importSchema"]?.string == ImportFields.schema,
            current.fields["importNamespace"]?.string == namespace
        else {
            throw TractandaError(
                "revisionConflict", "Imported Item changed; reconcile before creating a new intent.")
        }
        return current
    }

    private func verifySources(_ plan: ImportPlan, records: [ImportRecord]? = nil) throws {
        let sources = try ImportSourceFiles(root: URL(fileURLWithPath: plan.sourceRoot), limits: plan.limits)
        for record in records ?? plan.records {
            let original = try sources.open(relativePath: record.original.relativePath)
            guard original.byteCount == record.original.byteCount, original.sha256 == record.original.sha256
            else {
                throw TractandaError(
                    "importSourceChanged",
                    "Selected source manifest changed; preview a new plan after reconciling retained intent.")
            }
        }
    }

    private func identityMap(_ revisions: [ImportItemSnapshot]) -> [String: [ImportItemSnapshot]] {
        var mapping: [String: [ImportItemSnapshot]] = [:]
        for revision in revisions {
            if let id = revision.fields["importSourceID"]?.string {
                mapping[id, default: []].append(revision)
            }
            for id in aliases(revision) { mapping[id, default: []].append(revision) }
        }
        return mapping.mapValues {
            Array(Dictionary($0.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first }).values)
        }
    }

    private func aliases(_ revision: ImportItemSnapshot) -> [String] {
        revision.fields["importSourceIDAliases"]?.array?.compactMap(\.string) ?? []
    }
    private func managedFields(_ revision: ImportItemSnapshot) -> [String] {
        revision.fields["importManagedFields"]?.array?.compactMap(\.string) ?? []
    }
    private func projectionHash(_ values: [String: ItemValue], fields: [String]) throws -> String {
        let selected = Set(fields)
        return try ImportHash.digest(values.filter { selected.contains($0.key) })
    }
    private func operationID() -> String { "import-" + UUID().uuidString.lowercased() }

    private func linkValue(_ link: ImportLink, mapping: [String: [ImportItemSnapshot]]) -> ItemValue {
        var value: [String: ItemValue] = [
            "originalTarget": .text(link.originalTarget), "resolution": .text(link.kind.rawValue),
        ]
        if let fragment = link.fragment { value["fragment"] = .text(fragment) }
        if let line = link.sourceLine { value["sourceLine"] = .integer(Int64(line)) }
        if let column = link.sourceColumn { value["sourceColumn"] = .integer(Int64(column)) }
        if let sourceID = link.targetSourceID {
            value["targetSourceID"] = .text(sourceID)
            if link.kind == .local || link.kind == .missing {
                let targets = mapping[sourceID] ?? []
                if targets.count == 1, let target = targets.first, !target.isDeleted {
                    value["target"] = .reference(ItemReference(target.itemID))
                    value["resolution"] = .text("resolved")
                } else {
                    value["resolution"] = .text(targets.count > 1 ? "ambiguous" : "missing")
                }
            }
        }
        return .object(value)
    }

}
