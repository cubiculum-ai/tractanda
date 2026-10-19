import Crypto
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class DocumentJobLifecycleTests: XCTestCase {
    private let config = String(repeating: "c", count: 64)
    private func root() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "document-jobs-" + Identifier.make())
    }
    private func fixture(_ store: ItemStore) throws -> (Revision, AttachmentDescriptor) {
        let base = try store.commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("preserve")], operationID: "create")
        ).revision
        let data = Data([1, 2, 3])
        let upload = try store.beginAttachment(
            AttachmentUploadRequest(
                itemID: base.itemID, expectedRevisionID: base.revisionID,
                operationID: "original", filename: "tiny.pdf", mediaType: "application/pdf", byteCount: 3,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        let id = try XCTUnwrap(upload.uploadID)
        _ = try store.appendAttachment(uploadID: id, offset: 0, data: data)
        return (try store.finishAttachment(uploadID: id).revision, upload.attachment)
    }
    private func request(
        _ revision: Revision, _ descriptor: AttachmentDescriptor, operation: String = "document"
    ) -> DocumentJobStart {
        DocumentJobStart(
            itemID: revision.itemID, expectedRevisionID: revision.revisionID,
            attachmentID: descriptor.attachmentID, operationID: operation)
    }
    private func outcome(_ number: Int64, _ descriptor: AttachmentDescriptor) throws -> DocumentStoredPage {
        try DocumentStoredPage(
            pageNumber: number, sourceSHA256: descriptor.sha256, status: "unsupported",
            failureCode: "fakeUnsupported")
    }
    func test129TerminalOutcomesCancelRestartResumeAndExplicitCAS() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jobID: String
        let descriptor: AttachmentDescriptor
        let intent: DocumentJobStart
        do {
            let store = try AttachmentFixtureCapacity.makeStore(root: directory)
            let fixture = try fixture(store)
            descriptor = fixture.1
            intent = request(fixture.0, descriptor)
            jobID = try store.startDocumentJob(intent, identity: .init(), configurationSHA256: config).jobID
            let claim = try store.claimDocumentJob(jobID, configurationSHA256: config)
            try store.inspectDocumentJob(jobID, generation: claim.checkpoint.generation, pageCount: 129)
            for number in 1...65 {
                _ = try store.appendDocumentJobPage(
                    jobID, generation: claim.checkpoint.generation, page: outcome(Int64(number), descriptor))
            }
            XCTAssertThrowsError(
                try store.prepareDocumentJobPublication(jobID, generation: claim.checkpoint.generation))
            let cancelled = try store.controlDocumentJob(jobID, action: "cancel", configurationSHA256: config)
            XCTAssertEqual(cancelled.acceptedPages, 65)
            XCTAssertEqual(cancelled.state, "cancelled")
            XCTAssertThrowsError(
                try store.appendDocumentJobPage(
                    jobID, generation: claim.checkpoint.generation, page: outcome(66, descriptor)))
            XCTAssertTrue(try store.documentJobPage(jobID, pageNumber: 64).provisional)
            XCTAssertEqual(try store.listDocumentJobs().jobs.count, 1)
        }
        let store = try AttachmentFixtureCapacity.makeStore(root: directory)
        XCTAssertEqual(
            try store.startDocumentJob(intent, identity: .init(), configurationSHA256: config).jobID, jobID)
        let resumed = try store.controlDocumentJob(jobID, action: "resume", configurationSHA256: config)
        XCTAssertEqual(resumed.acceptedPages, 65)
        let claim = try store.claimDocumentJob(jobID, configurationSHA256: config)
        try store.inspectDocumentJob(jobID, generation: claim.checkpoint.generation, pageCount: 129)
        for number in 66...129 {
            _ = try store.appendDocumentJobPage(
                jobID, generation: claim.checkpoint.generation, page: outcome(Int64(number), descriptor))
        }
        let ready = try store.prepareDocumentJobPublication(jobID, generation: claim.checkpoint.generation)
        XCTAssertEqual(ready.state, "readyToPublish")
        let completed = try store.publishDocumentJob(jobID, generation: claim.checkpoint.generation)
        XCTAssertEqual(completed.state, "completed")
        XCTAssertEqual(completed.coverage.unsupported, 129)
        XCTAssertEqual(completed.coverage.state, "partial")
        XCTAssertTrue(try store.listDocumentJobs().jobs.isEmpty)
        let saved = try store.get(intent.itemID)
        XCTAssertEqual(saved.fields["subject"], .text("preserve"))
        let content = try XCTUnwrap(
            AttachmentDocumentRepresentation.representations(in: saved.fields).first?.content)
        XCTAssertEqual(content.pageCount, 129)
        XCTAssertEqual(
            try store.readAttachmentDocument(
                itemID: saved.itemID, attachmentID: descriptor.attachmentID, pageNumber: 129
            ).outcomes?.first?.status, "unsupported")
    }
    func testConflictRebasePreservesProvenanceAndUnrelatedFields() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AttachmentFixtureCapacity.makeStore(root: directory)
        let (attached, descriptor) = try fixture(store)
        let job = try store.startDocumentJob(
            request(attached, descriptor), identity: .init(), configurationSHA256: config)
        let claim = try store.claimDocumentJob(job.jobID, configurationSHA256: config)
        try store.inspectDocumentJob(job.jobID, generation: claim.checkpoint.generation, pageCount: 1)
        _ = try store.appendDocumentJobPage(
            job.jobID, generation: claim.checkpoint.generation, page: outcome(1, descriptor))
        _ = try store.prepareDocumentJobPublication(job.jobID, generation: claim.checkpoint.generation)
        let changed = try store.commit(
            CommitRequest(
                action: .revise, itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                changes: ["subject": .text("new unrelated field")], operationID: "unrelated")
        ).revision
        XCTAssertThrowsError(try store.publishDocumentJob(job.jobID, generation: claim.checkpoint.generation))
        XCTAssertEqual(try store.documentJobStatus(job.jobID).reasonCode, "revisionConflict")
        let rebased = try store.controlDocumentJob(
            job.jobID, action: "rebase", expectedRevisionID: changed.revisionID, configurationSHA256: config)
        XCTAssertEqual(rebased.state, "readyToPublish")
        XCTAssertEqual(rebased.sourceRevisionID, attached.revisionID)
        let recordBytes = try Data(
            contentsOf: directory.appendingPathComponent("document-jobs/" + job.jobID + "/record.json"))
        let record = try JSON.decode(DocumentJobRecord.self, recordBytes)
        let done = try store.publishDocumentJob(job.jobID, generation: record.checkpoint.generation)
        XCTAssertEqual(done.state, "completed")
        let saved = try store.get(attached.itemID)
        XCTAssertEqual(saved.fields["subject"], .text("new unrelated field"))
        XCTAssertEqual(
            try AttachmentDocumentRepresentation.representations(in: saved.fields).first?.source.revisionID,
            attached.revisionID)
    }
    func testLostCommitReplyReconcilesBeforeCancelOrRebaseAcrossRestart() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jobID: String
        let intent: DocumentJobStart
        let committedRevision: String
        do {
            let store = try AttachmentFixtureCapacity.makeStore(root: directory)
            let (attached, descriptor) = try fixture(store)
            intent = request(attached, descriptor)
            jobID = try store.startDocumentJob(intent, identity: .init(), configurationSHA256: config).jobID
            let claim = try store.claimDocumentJob(jobID, configurationSHA256: config)
            try store.inspectDocumentJob(jobID, generation: claim.checkpoint.generation, pageCount: 1)
            _ = try store.appendDocumentJobPage(
                jobID, generation: claim.checkpoint.generation, page: outcome(1, descriptor))
            _ = try store.prepareDocumentJobPublication(jobID, generation: claim.checkpoint.generation)
            store.afterDocumentJobCommitForTesting = { throw TractandaError("injected", "Lost commit reply") }
            XCTAssertThrowsError(try store.publishDocumentJob(jobID, generation: claim.checkpoint.generation))
            let canonical = try store.get(attached.itemID)
            committedRevision = canonical.revisionID
            XCTAssertEqual(canonical.formatVersion, 2)
            XCTAssertEqual(try canonical.provenance?.originReplicaID, store.replicaID)
            XCTAssertEqual(try store.documentJobStatus(jobID).state, "completed")
        }
        let store = try AttachmentFixtureCapacity.makeStore(root: directory)
        let result = try store.controlDocumentJob(
            jobID, action: "rebase", expectedRevisionID: intent.expectedRevisionID,
            configurationSHA256: config)
        XCTAssertEqual(result.state, "completed")
        XCTAssertEqual(result.committed?.revisionID, committedRevision)
        XCTAssertTrue(result.committed?.wasReplayed == true)
        let reopened = try store.get(intent.itemID)
        XCTAssertEqual(reopened.revisionID, committedRevision)
        XCTAssertEqual(reopened.formatVersion, 2)
        XCTAssertEqual(try reopened.provenance?.originReplicaID, store.replicaID)
    }
    func testUncertainPageBeforeCheckpointReopensOnlyOneOutcomeAndRejectsChangedReplay() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AttachmentFixtureCapacity.makeStore(root: directory)
        let (attached, descriptor) = try fixture(store)
        let job = try store.startDocumentJob(
            request(attached, descriptor), identity: .init(), configurationSHA256: config)
        let claim = try store.claimDocumentJob(job.jobID, configurationSHA256: config)
        try store.inspectDocumentJob(job.jobID, generation: claim.checkpoint.generation, pageCount: 2)
        let contents = DocumentContentStore(
            root: directory, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let writer = try contents.reopenJob(
            stage: claim.intent.stage, source: claim.intent.source, identity: claim.intent.identity,
            extractedAt: claim.intent.extractedAt, acceptedPages: 0, pageCount: 2)
        try writer.append(outcome(1, descriptor))  // Sealed page, deliberately no durable job reply.
        _ = try store.controlDocumentJob(job.jobID, action: "cancel", configurationSHA256: config)
        let resumed = try store.controlDocumentJob(job.jobID, action: "resume", configurationSHA256: config)
        XCTAssertEqual(resumed.acceptedPages, 1)
        let next = try store.claimDocumentJob(job.jobID, configurationSHA256: config)
        try store.inspectDocumentJob(job.jobID, generation: next.checkpoint.generation, pageCount: 2)
        XCTAssertThrowsError(
            try store.appendDocumentJobPage(
                job.jobID, generation: next.checkpoint.generation,
                page: DocumentStoredPage(
                    pageNumber: 1, sourceSHA256: descriptor.sha256, status: "failed", failureCode: "changed"))
        )
        XCTAssertThrowsError(
            try store.prepareDocumentJobPublication(job.jobID, generation: next.checkpoint.generation))
        let discarded = try store.controlDocumentJob(
            job.jobID, action: "discard", configurationSHA256: config)
        XCTAssertTrue(discarded.discarded)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("documents/.staging/" + job.jobID).path))
        XCTAssertThrowsError(try store.documentJobPage(job.jobID, pageNumber: 1))
    }
    func testOriginalOrConfigurationChangePausesWithoutReplacingPages() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AttachmentFixtureCapacity.makeStore(root: directory)
        let (attached, descriptor) = try fixture(store)
        let job = try store.startDocumentJob(
            request(attached, descriptor), identity: .init(), configurationSHA256: config)
        let configPaused = try store.controlDocumentJob(
            job.jobID, action: "resume", configurationSHA256: String(repeating: "d", count: 64))
        XCTAssertEqual(configPaused.reasonCode, "documentConfigurationChanged")
        let detached = try store.detachAttachment(
            itemID: attached.itemID, expectedRevisionID: attached.revisionID,
            attachmentID: descriptor.attachmentID, operationID: "detach")
        let paused = try store.controlDocumentJob(
            job.jobID, action: "rebase", expectedRevisionID: detached.revision.revisionID,
            configurationSHA256: config)
        XCTAssertEqual(paused.state, "paused")
        XCTAssertEqual(paused.reasonCode, "documentOriginalChanged")
        XCTAssertEqual(paused.sourceRevisionID, attached.revisionID)
    }
    private func ready(
        _ store: ItemStore, attached: Revision, descriptor: AttachmentDescriptor, operation: String
    ) throws -> DocumentJobRecord {
        let job = try store.startDocumentJob(
            request(attached, descriptor, operation: operation), identity: .init(),
            configurationSHA256: config)
        let claim = try store.claimDocumentJob(job.jobID, configurationSHA256: config)
        try store.inspectDocumentJob(job.jobID, generation: claim.checkpoint.generation, pageCount: 1)
        _ = try store.appendDocumentJobPage(
            job.jobID, generation: claim.checkpoint.generation, page: outcome(1, descriptor))
        _ = try store.prepareDocumentJobPublication(job.jobID, generation: claim.checkpoint.generation)
        return claim
    }
    private func boundedFixtureBatch(_ directory: URL) throws {
        try AttachmentFixtureCapacity.requireFree(at: directory)
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [])
        else {
            throw TractandaError("resourceLimit", "Cannot inspect document fixture allocation.")
        }
        var total: Int64 = 0
        for case let url as URL in entries {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_size >= 0, info.st_blocks >= 0 else {
                throw TractandaError("resourceLimit", "Cannot inspect document fixture bytes.")
            }
            let blocks = Int64(info.st_blocks).multipliedReportingOverflow(by: 512)
            let sum = total.addingReportingOverflow(max(Int64(info.st_size), blocks.partialValue))
            guard !blocks.overflow, !sum.overflow else {
                throw TractandaError("resourceLimit", "Document fixture byte count overflowed.")
            }
            total = sum.partialValue
            guard total <= 16 * 1024 * 1024 - 128 * 1024 else {
                throw TractandaError(
                    "resourceLimit", "Next tiny job batch would cross its16MiB complete fixture cap.")
            }
        }
    }
    func test65SequentialCompletionsReleaseActiveSlotsAndReplayDirectHistory() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Worst-case65 *128KiB including all JSON, directories and indexes is <16MiB.
        let store = try AttachmentFixtureCapacity.makeStore(root: directory)
        var (attached, descriptor) = try fixture(store)
        var firstID: String?
        var firstRequest: DocumentJobStart?
        for number in 1...65 {
            try boundedFixtureBatch(directory)
            let operation = "sequential-" + String(number)
            let intent = request(attached, descriptor, operation: operation)
            let claim = try ready(store, attached: attached, descriptor: descriptor, operation: operation)
            if number == 1 {
                firstID = claim.intent.jobID
                firstRequest = intent
            }
            let done = try store.publishDocumentJob(
                claim.intent.jobID, generation: claim.checkpoint.generation)
            XCTAssertEqual(done.state, "completed")
            attached = try store.get(attached.itemID)
        }
        XCTAssertTrue(try store.listDocumentJobs().jobs.isEmpty)
        let id = try XCTUnwrap(firstID)
        XCTAssertEqual(try store.documentJobStatus(id).state, "completed")
        XCTAssertEqual(
            try store.startDocumentJob(
                XCTUnwrap(firstRequest), identity: .init(), configurationSHA256: config
            ).jobID, id)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("document-jobs/" + id).path))
    }
    func testHistoryAndLookupInterruptedArchivesRetainCommittedRecoveryAndRetry() throws {
        for afterLookup in [false, true] {
            let directory = try root()
            defer { try? FileManager.default.removeItem(at: directory) }
            let id: String
            let intent: DocumentJobStart
            let revisionID: String
            do {
                let store = try AttachmentFixtureCapacity.makeStore(root: directory)
                let (attached, descriptor) = try fixture(store)
                intent = request(attached, descriptor)
                let claim = try ready(
                    store, attached: attached, descriptor: descriptor, operation: "document")
                id = claim.intent.jobID
                let hook = { throw TractandaError("injected", "Interrupted terminal archive") }
                if afterLookup {
                    store.afterDocumentJobLookupForTesting = hook
                } else {
                    store.afterDocumentJobHistoryForTesting = hook
                }
                XCTAssertThrowsError(
                    try store.publishDocumentJob(id, generation: claim.checkpoint.generation))
                revisionID = try store.get(attached.itemID).revisionID
                XCTAssertEqual(try store.documentJobStatus(id).state, "completed")
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("document-jobs/" + id + "/record.json").path)
                )
            }
            let store = try AttachmentFixtureCapacity.makeStore(root: directory)
            try store.recoverDocumentJobs(configurationSHA256: config)
            let replay = try store.startDocumentJob(intent, identity: .init(), configurationSHA256: config)
            XCTAssertEqual(replay.committed?.revisionID, revisionID)
            XCTAssertEqual(try store.get(intent.itemID).revisionID, revisionID)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("document-jobs/" + id).path))
        }
    }
    func testPublishedBeforeCASRemainsChargedAcrossRestartAndExplicitDiscardRemovesOnlyCandidate() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id: String
        let attached: Revision
        let descriptor: AttachmentDescriptor
        do {
            let store = try AttachmentFixtureCapacity.makeStore(root: directory)
            let fixture = try fixture(store)
            attached = fixture.0
            descriptor = fixture.1
            let claim = try ready(store, attached: attached, descriptor: descriptor, operation: "document")
            id = claim.intent.jobID
            store.beforeDocumentJobCommitForTesting = {
                throw TractandaError("injected", "After canonical tree rename, beforeCAS")
            }
            XCTAssertThrowsError(try store.publishDocumentJob(id, generation: claim.checkpoint.generation))
            XCTAssertEqual(try store.get(attached.itemID).revisionID, attached.revisionID)
            XCTAssertEqual(try store.documentJobPage(id, pageNumber: 1).outcome.status, "unsupported")
        }
        let quota = try StagingByteQuota(root: directory, ownerUID: getuid(), maximumBytes: .max)
        XCTAssertGreaterThan(quota.usedBytes, 512)
        let files = DocumentContentFiles(
            root: directory, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let record = try JSON.decode(
            DocumentJobRecord.self,
            files.read(path: ["document-jobs", id, "record.json"], maximumBytes: 16 * 1024))
        let receipt = try JSON.decode(
            DocumentPublicationReceipt.self,
            files.read(path: ["documents", ".staging", id + ".publication.json"], maximumBytes: 64 * 1024))
        let contents = DocumentContentStore(
            root: directory, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let candidate = try contents.directory(receipt.manifest.contentID).reduce(directory) {
            $0.appendingPathComponent($1)
        }
        XCTAssertNotNil(record.checkpoint.prepared)
        let store = try AttachmentFixtureCapacity.makeStore(root: directory)
        let discarded = try store.controlDocumentJob(id, action: "discard", configurationSHA256: config)
        XCTAssertTrue(discarded.discarded)
        XCTAssertEqual(discarded.reasonCode, "indexProjectionPending")
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        let pending = try JSON.decode(
            DocumentJobRecord.self,
            files.read(path: ["document-jobs", id, "record.json"], maximumBytes: 16 * 1024))
        let recovery = try store.documentJobIndexRecoveryWork(
            id, generation: pending.checkpoint.generation, discard: true)
        // Direct test/offline material work is outside the Store owner queue.
        try recovery.retire(boundary: {})
        while !(try recovery.cleanup(authorityBoundary: {}).complete) { try boundedFixtureBatch(directory) }
        for charged in [true, false] {
            var cursor: String?
            repeat {
                cursor = try store.reconcileCorpusChargePage(after: cursor, charged: charged)
            } while cursor != nil
        }
        _ = try store.controlDocumentJob(id, action: "discard", configurationSHA256: config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertEqual(try store.get(attached.itemID).revisionID, attached.revisionID)
        XCTAssertEqual(
            try store.attachmentContent(itemID: attached.itemID, attachmentID: descriptor.attachmentID).data,
            Data([1, 2, 3]))
        XCTAssertEqual(
            try StagingByteQuota(root: directory, ownerUID: getuid(), maximumBytes: .max).usedBytes, 0)
    }
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 61313
        var admitted = true
        var deleted = false
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard (uid == getuid() || uid == alice) && !(uid == alice && deleted) else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
            }
            return AccountIdentity(
                uid: uid, name: uid == alice ? "alice" : "admin", primaryGroupName: "staff",
                groupIDs: uid == getuid() || admitted ? [71313] : [])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "alice" || name == "admin" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
            }
            return try user(forUID: name == "alice" ? alice : getuid())
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
            }
            return 71313
        }
    }
    func testAdminControlNeverImpersonatesRevokedOriginalActorAndCurrentACLHidesReads() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accounts = Accounts()
        let store = try AttachmentFixtureCapacity.makeStore(root: directory, accounts: accounts)
        _ = try store.configureAccess(
            .object(["profile": .text(AccessConfiguration.profile), "groups": .list([.text("staff")])]),
            operationID: "access")
        let (original, descriptor) = try fixture(store)
        let attached = try store.commit(
            CommitRequest(
                action: .revise, itemID: original.itemID, expectedRevisionID: original.revisionID,
                changes: [
                    "permissions": .object([
                        "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                        "group": .text("staff"), "mode": .integer(0o660), "acl": .object([:]),
                    ])
                ], operationID: "share")
        ).revision
        let job = try store.withAccess(forUID: accounts.alice) {
            try store.startDocumentJob(
                request(attached, descriptor), identity: .init(), configurationSHA256: config)
        }
        XCTAssertThrowsError(try store.claimDocumentJob(job.jobID, configurationSHA256: config))
        accounts.admitted = false
        XCTAssertThrowsError(
            try store.withAccess(forUID: accounts.alice) { try store.documentJobStatus(job.jobID) })
        let paused = try store.controlDocumentJob(job.jobID, action: "resume", configurationSHA256: config)
        XCTAssertEqual(paused.state, "paused")
        XCTAssertEqual(paused.reasonCode, "forbidden")
        XCTAssertEqual(try store.documentJobStatus(job.jobID).state, "paused")
        XCTAssertEqual(
            try store.controlDocumentJob(job.jobID, action: "cancel", configurationSHA256: config).state,
            "cancelled")
        XCTAssertEqual(try store.get(attached.itemID).revisionID, attached.revisionID)
    }

    func testCommittedReplyReconcilesEvenAfterOriginalAccountDisappears() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accounts = Accounts()
        let store = try AttachmentFixtureCapacity.makeStore(root: directory, accounts: accounts)
        _ = try store.configureAccess(
            .object(["profile": .text(AccessConfiguration.profile), "groups": .list([.text("staff")])]),
            operationID: "access")
        let (original, descriptor) = try fixture(store)
        let attached = try store.commit(
            CommitRequest(
                action: .revise, itemID: original.itemID, expectedRevisionID: original.revisionID,
                changes: [
                    "permissions": .object([
                        "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                        "group": .text("staff"), "mode": .integer(0o660), "acl": .object([:]),
                    ])
                ], operationID: "share")
        ).revision
        let claim = try store.withAccess(forUID: accounts.alice) {
            try ready(store, attached: attached, descriptor: descriptor, operation: "alice-document")
        }
        store.afterDocumentJobCommitForTesting = {
            throw TractandaError("injected", "Lost alice commit reply")
        }
        XCTAssertThrowsError(
            try store.withAccess(forUID: accounts.alice) {
                try store.publishDocumentJob(claim.intent.jobID, generation: claim.checkpoint.generation)
            })
        let revisionID = try store.get(attached.itemID).revisionID
        accounts.deleted = true
        let reconciled = try store.controlDocumentJob(
            claim.intent.jobID, action: "discard", configurationSHA256: config)
        XCTAssertEqual(reconciled.state, "completed")
        XCTAssertFalse(reconciled.discarded)
        XCTAssertEqual(reconciled.committed?.revisionID, revisionID)
        XCTAssertEqual(try store.get(attached.itemID).fields["actor"], .text("user:alice"))
        XCTAssertEqual(
            try store.readAttachmentDocument(itemID: attached.itemID, attachmentID: descriptor.attachmentID)
                .totalPageCount, 1)
    }
    func testFreshItemACLHidesJobStatusListAndProvisionalPage() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accounts = Accounts()
        let store = try AttachmentFixtureCapacity.makeStore(root: directory, accounts: accounts)
        _ = try store.configureAccess(
            .object(["profile": .text(AccessConfiguration.profile), "groups": .list([.text("staff")])]),
            operationID: "access")
        let (original, descriptor) = try fixture(store)
        func permissions(_ mode: Int64) -> ItemValue {
            .object([
                "profile": .text(ItemPermissions.profile), "owner": .text("admin"), "group": .text("staff"),
                "mode": .integer(mode), "acl": .object([:]),
            ])
        }
        let attached = try store.commit(
            CommitRequest(
                action: .revise, itemID: original.itemID, expectedRevisionID: original.revisionID,
                changes: ["permissions": permissions(0o660)], operationID: "share")
        ).revision
        let claim = try store.withAccess(forUID: accounts.alice) {
            try ready(store, attached: attached, descriptor: descriptor, operation: "alice-document")
        }
        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                changes: ["permissions": permissions(0o600)], operationID: "revoke-read"))
        XCTAssertThrowsError(
            try store.withAccess(forUID: accounts.alice) { try store.documentJobStatus(claim.intent.jobID) })
        XCTAssertThrowsError(
            try store.withAccess(forUID: accounts.alice) {
                try store.documentJobPage(claim.intent.jobID, pageNumber: 1)
            })
        XCTAssertTrue(
            try store.withAccess(forUID: accounts.alice) { try store.listDocumentJobs() }.jobs.isEmpty)
        let paused = try store.controlDocumentJob(
            claim.intent.jobID, action: "resume", configurationSHA256: config)
        XCTAssertEqual(paused.reasonCode, "forbidden")
        XCTAssertEqual(
            try store.documentJobPage(claim.intent.jobID, pageNumber: 1).outcome.status, "unsupported")
    }

    func testUncertain128thPageReplaysAnAlreadySealedProofNodeExactly() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AttachmentFixtureCapacity.makeStore(root: directory)
        let (attached, descriptor) = try fixture(store)
        let job = try store.startDocumentJob(
            request(attached, descriptor), identity: .init(), configurationSHA256: config)
        let claim = try store.claimDocumentJob(job.jobID, configurationSHA256: config)
        try store.inspectDocumentJob(job.jobID, generation: claim.checkpoint.generation, pageCount: 129)
        for number in 1...127 {
            _ = try store.appendDocumentJobPage(
                job.jobID, generation: claim.checkpoint.generation, page: outcome(Int64(number), descriptor))
        }
        let contents = DocumentContentStore(
            root: directory, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let uncertain = try contents.reopenJob(
            stage: claim.intent.stage, source: claim.intent.source,
            identity: claim.intent.identity, extractedAt: claim.intent.extractedAt, acceptedPages: 127,
            pageCount: 129)
        // Page and fanout128 node sealed before checkpoint reply.
        try uncertain.append(outcome(128, descriptor))
        _ = try store.controlDocumentJob(job.jobID, action: "cancel", configurationSHA256: config)
        XCTAssertEqual(
            try store.controlDocumentJob(job.jobID, action: "resume", configurationSHA256: config)
                .acceptedPages, 128)
        let next = try store.claimDocumentJob(job.jobID, configurationSHA256: config)
        try store.inspectDocumentJob(job.jobID, generation: next.checkpoint.generation, pageCount: 129)
        _ = try store.appendDocumentJobPage(
            job.jobID, generation: next.checkpoint.generation, page: outcome(129, descriptor))
        _ = try store.prepareDocumentJobPublication(job.jobID, generation: next.checkpoint.generation)
        XCTAssertEqual(
            try store.publishDocumentJob(job.jobID, generation: next.checkpoint.generation).acceptedPages, 129
        )
    }

    func testRecoveredJobProtectsReplacementHeadroomFromCopyAdmission() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try AttachmentFixtureCapacity.makeStore(root: directory)
            let (attached, descriptor) = try fixture(store)
            _ = try store.startDocumentJob(
                request(attached, descriptor), identity: .init(), configurationSHA256: config)
        }
        let measured = try StagingByteQuota(root: directory, ownerUID: getuid(), maximumBytes: .max)
        let quota = try StagingByteQuota(
            root: directory, ownerUID: getuid(),
            maximumBytes: measured.usedBytes + StagingByteQuota.uploadCheckpointReservation)
        XCTAssertThrowsError(try quota.charge(1, path: ["copies", "racer", "intent.json"]))
        XCTAssertThrowsError(try quota.retainUpload(id: "new", initialCheckpointBytes: 1))
        XCTAssertNoThrow(try quota.require(additionalBytes: 0))
    }
    func test65HistoricalEmptyFirstWriteDirectoriesDoNotConsumeRealRecoverySlots() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jobID: String
        let intent: DocumentJobStart
        do {
            let store = try AttachmentFixtureCapacity.makeStore(root: directory)
            let (attached, descriptor) = try fixture(store)
            intent = request(attached, descriptor)
            jobID = try store.startDocumentJob(intent, identity: .init(), configurationSHA256: config).jobID
        }
        // Estimate66private directory entries plus tiny metadata <1MiB, within16MiB fixture cap.
        let parent = directory.appendingPathComponent("document-jobs")
        var emptyID: String?
        for _ in 0..<65 {
            try boundedFixtureBatch(directory)
            let id = try UUID.makeVersion1().uuidString.lowercased()
            emptyID = id
            try FileManager.default.createDirectory(
                at: parent.appendingPathComponent(id), withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let failedID = try XCTUnwrap(emptyID)
        let capacityRejected = DocumentContentFiles(
            root: directory, ownerUID: getuid(),
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes,
            availableBytes: { UInt64(AttachmentFixtureCapacity.reserveBytes) })
        XCTAssertThrowsError(
            try capacityRejected.replaceJobCheckpoint(
                Data([1]),
                path: ["document-jobs", failedID, "record.json"], jobID: failedID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent(failedID).path))
        let retainedID = try UUID.makeVersion1().uuidString.lowercased()
        let retained = parent.appendingPathComponent(retainedID)
        try FileManager.default.createDirectory(
            at: retained, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let uncertain = retained.appendingPathComponent(".checkpoint-retained.tmp")
        try Data([4, 5, 6]).write(to: uncertain)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: uncertain.path)
        let reopened = try AttachmentFixtureCapacity.makeStore(root: directory)
        XCTAssertEqual(
            try reopened.startDocumentJob(intent, identity: .init(), configurationSHA256: config).jobID, jobID
        )
        XCTAssertEqual(try reopened.listDocumentJobs().jobs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(failedID).path))
        XCTAssertEqual(try Data(contentsOf: uncertain), Data([4, 5, 6]))
        let children = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertEqual(Set(children), [jobID, retainedID])
        let quota = try StagingByteQuota(root: directory, ownerUID: getuid(), maximumBytes: .max)
        XCTAssertGreaterThanOrEqual(quota.usedBytes, 3, "Uncertain retained bytes remain charged")
    }

    func testRecoveryReconcilesTransferredAndDisappearedDebtAndBoundsGC() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Twenty short stored pages + originals, spools and Index copies are estimated below2MiB.
        let store = try AttachmentFixtureCapacity.makeStore(root: directory)
        let (attached, descriptor) = try fixture(store)
        let job = try store.startDocumentJob(
            request(attached, descriptor), identity: .init(), configurationSHA256: config)
        let claim = try store.claimDocumentJob(job.jobID, configurationSHA256: config)
        try store.inspectDocumentJob(job.jobID, generation: claim.checkpoint.generation, pageCount: 20)
        let geometry = try DocumentPageGeometry(
            sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint",
            displayWidth: 512, displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024,
            contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024)
        for number in 1...20 {
            try boundedFixtureBatch(directory)
            let parsed = try DoclingDocTagsParser.parse(
                Data("<doctag><text>retained page</text></doctag>".utf8))
            let page = try DocumentStoredPage(
                pageNumber: Int64(number), sourceSHA256: descriptor.sha256,
                page: AttachmentDocumentPage(
                    pageNumber: number, geometry: geometry, rasterSHA256: String(repeating: "b", count: 64),
                    parsed: parsed, generatedTokens: 20, stopReason: "stop"))
            _ = try store.appendDocumentJobPage(
                job.jobID, generation: claim.checkpoint.generation, page: page)
        }
        _ = try store.prepareDocumentJobPublication(job.jobID, generation: claim.checkpoint.generation)
        let projection = try store.documentJobProjectionWork(
            job.jobID, generation: claim.checkpoint.generation)
        let spool = try projection.prepareSpool(cancellation: .init())
        func stage(_ id: String) throws {
            _ = try ItemIndex.stageCorpus(
                indexPath: projection.indexPath, input: projection.snapshot.input,
                prepared: spool, workID: id, writeBoundary: { _ in },
                boundary: { try self.boundedFixtureBatch(directory) })
        }
        func reconcile() throws {
            for charged in [true, false] {
                var cursor: String?
                repeat {
                    cursor = try store.reconcileCorpusChargePage(after: cursor, charged: charged)
                } while cursor != nil
            }
        }
        try stage(job.jobID)
        let sharedID = try UUID.makeVersion1().uuidString.lowercased()
        try stage(sharedID)
        try reconcile()
        let index = try ItemIndex(path: projection.indexPath, create: false)
        let pending = try store.controlDocumentJob(job.jobID, action: "discard", configurationSHA256: config)
        XCTAssertTrue(pending.discarded)
        XCTAssertEqual(pending.reasonCode, "indexProjectionPending")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("document-jobs/" + job.jobID + "/record.json").path))
        let firstDebt = try index.corpusRetainedBytes(job.jobID)
        let sharedHeader = try index.corpusRetainedBytes(sharedID)
        let before = projection.quota.usedBytes
        let recovery = DocumentJobIndexRecoveryWork(indexPath: projection.indexPath, workID: job.jobID)
        try recovery.retire(boundary: {})
        try reconcile()
        let transferred = try index.corpusRetainedBytes(sharedID)
        XCTAssertEqual(try index.corpusRetainedBytes(job.jobID), 0)
        XCTAssertGreaterThan(transferred, sharedHeader)
        XCTAssertEqual(projection.quota.usedBytes, before - firstDebt + transferred - sharedHeader)
        XCTAssertFalse(try projection.quota.chargedCorpusWorkPage().contains(job.jobID))
        XCTAssertTrue(try recovery.cleanup(authorityBoundary: {}).complete)
        XCTAssertGreaterThan(try index.corpusRetainedBytes(sharedID), 0, "Live shared work is protected")
        let shared = DocumentJobIndexRecoveryWork(indexPath: projection.indexPath, workID: sharedID)
        try shared.retire(boundary: {})
        try reconcile()
        let retained = try index.corpusRetainedBytes(sharedID)
        XCTAssertGreaterThan(retained, 0, "Retirement cannot refund retained units")
        let partial = try shared.cleanup(authorityBoundary: {})
        XCTAssertFalse(partial.complete, "Twenty units require multiple bounded GC steps")
        XCTAssertTrue(partial.madeProgress)
        try reconcile()
        XCTAssertGreaterThan(try index.corpusRetainedBytes(sharedID), 0)
        while !(try shared.cleanup(authorityBoundary: {}).complete) { try boundedFixtureBatch(directory) }
        try reconcile()
        XCTAssertFalse(try projection.quota.chargedCorpusWorkPage().contains(sharedID))
        _ = try store.controlDocumentJob(job.jobID, action: "discard", configurationSHA256: config)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("document-jobs/" + job.jobID).path))
        try boundedFixtureBatch(directory)
    }

    func testRecoveryAuthorityBoundaryNeverRunsWhileGCWriterIsHeld() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        // One short saved page and all store/spool/Index copies are estimated below2MiB.
        let store = try AttachmentFixtureCapacity.makeStore(root: directory)
        let (attached, descriptor) = try fixture(store)
        let job = try store.startDocumentJob(
            request(attached, descriptor), identity: .init(), configurationSHA256: config)
        let claim = try store.claimDocumentJob(job.jobID, configurationSHA256: config)
        try store.inspectDocumentJob(job.jobID, generation: claim.checkpoint.generation, pageCount: 1)
        let geometry = try DocumentPageGeometry(
            sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint",
            displayWidth: 512, displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024,
            contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024)
        let parsed = try DoclingDocTagsParser.parse(Data("<doctag><text>retired unit</text></doctag>".utf8))
        _ = try store.appendDocumentJobPage(
            job.jobID, generation: claim.checkpoint.generation,
            page: DocumentStoredPage(
                pageNumber: 1, sourceSHA256: descriptor.sha256,
                page: AttachmentDocumentPage(
                    pageNumber: 1, geometry: geometry,
                    rasterSHA256: String(repeating: "b", count: 64), parsed: parsed,
                    generatedTokens: 20, stopReason: "stop")))
        _ = try store.prepareDocumentJobPublication(job.jobID, generation: claim.checkpoint.generation)
        let projection = try store.documentJobProjectionWork(
            job.jobID, generation: claim.checkpoint.generation)
        let spool = try projection.prepareSpool(cancellation: .init())
        _ = try ItemIndex.stageCorpus(
            indexPath: projection.indexPath, input: projection.snapshot.input,
            prepared: spool, workID: job.jobID, writeBoundary: { _ in },
            boundary: { try self.boundedFixtureBatch(directory) })
        let recovery = DocumentJobIndexRecoveryWork(indexPath: projection.indexPath, workID: job.jobID)
        try recovery.retire(boundary: {})
        let probe = try ItemIndex(path: projection.indexPath, create: false)
        try probe.execute("PRAGMA busy_timeout=0")
        XCTAssertGreaterThan(try probe.corpusRetainedBytes(job.jobID), 0)
        var authorityCalls = 0
        var heldWriterChecks = 0
        let result = try recovery.cleanup(
            authorityBoundary: {
                authorityCalls += 1
                // A Store request needing a writer can finish here immediately: no GC writer is held.
                try probe.execute("BEGIN IMMEDIATE")
                try probe.execute("ROLLBACK")
            },
            transactionBoundary: {
                do {
                    try probe.execute("BEGIN IMMEDIATE")
                    try probe.execute("ROLLBACK")
                } catch {
                    XCTAssertEqual((error as? TractandaError)?.code, "indexTransient")
                    heldWriterChecks += 1
                }
            })
        XCTAssertEqual(authorityCalls, 1, "Fresh Store authority is checked outside the writer transaction")
        XCTAssertGreaterThan(
            heldWriterChecks, 0, "Actual retired-unit GC exercises local checks inside its writer transaction"
        )
        XCTAssertTrue(result.complete)
        XCTAssertEqual(try probe.corpusRetainedBytes(job.jobID), 0)
        try boundedFixtureBatch(directory)
    }

}
