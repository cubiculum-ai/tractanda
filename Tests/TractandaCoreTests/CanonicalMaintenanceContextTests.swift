import CTractandaPlatform
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class CanonicalMaintenanceContextTests: XCTestCase {
    private final class Fixture {
        let source: AtomicAuthorityStoreFixture
        let audit: URL
        let plan: CanonicalMaintenanceJournal.Plan
        let root: URL
        let storeID: String
        var payloadStageID: String?
        init(
            applied: Bool = true, rollback: Bool = false, seedPayloadStage: Bool = false,
            atomicSource: Bool = false, freshDerivedIndex: Bool = false, clearCompletedScratch: Bool = false
        ) throws {
            let old = CanonicalFormatSupport(
                readerLevel: 14, writerLevel: 14, read: [1, 2], write: [2],
                capabilities: CanonicalFormatSupport.current.capabilities.filter {
                    $0 != AtomicAuthorityCompatibility.capability
                })
            source = try AtomicAuthorityStoreFixture(support: atomicSource ? .current : old)
            root = source.sourceRoot
            storeID = source.storeID
            if seedPayloadStage {
                let id = try UUID.makeVersion1().uuidString.lowercased()
                let payloads = try AttachmentPayloadStore(root: root, ownerUID: tractanda_uid())
                try payloads.createStaging(id: id)
                _ = try payloads.append(id: id, offset: 0, data: Data("preserved private fixture bytes".utf8))
                payloadStageID = id
            }
            source.source = nil
            if freshDerivedIndex {
                try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
            } else if clearCompletedScratch {
                let path = root.appendingPathComponent("index/atomic-authority-work")
                if FileManager.default.fileExists(atPath: path.path) {
                    try FileManager.default.removeItem(at: path)
                }
            }
            try AtomicAuthorityStoreFixture.transition(root)
            audit = source.directory.appendingPathComponent("maintenance-audit")
            try FileManager.default.createDirectory(
                at: audit, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let replica = try XCTUnwrap(
                ReplicaIdentity.load(root: root, storeID: storeID, ownerUID: tractanda_uid()))
            let files = FileManager.default.enumerator(
                at: root.appendingPathComponent("authority/records"), includingPropertiesForKeys: nil)!
            var original: URL?
            for case let file as URL in files where file.pathExtension == "authority" {
                original = file
                break
            }
            let file = try XCTUnwrap(original)
            let bytes = try Data(contentsOf: file)
            let path = file.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
            plan = .init(
                version: 1, operationID: try UUID.makeVersion1().uuidString.lowercased(), storeID: storeID,
                replicaID: replica.replicaID,
                edits: [
                    .init(
                        path: path, role: .authorityOriginal,
                        beforeSHA256: AuthorityRecordCodec.sha256(bytes), after: bytes)
                ])
            let writer = tractanda_lock(root.appendingPathComponent(".writer.lock").path)
            guard writer >= 0 else { throw TractandaError("fixture", "Writer did not close") }
            defer { tractanda_unlock(writer) }
            let journal = try CanonicalMaintenanceJournal(
                root: root, journal: audit, writerDescriptor: writer, plan: plan)
            if applied { try journal.applyAll() }
            if rollback { try journal.rollback() }
            try source.capacity()
        }
        var opening: CanonicalMaintenanceContext.Opening {
            get throws {
                .init(
                    journalRoot: audit, plan: plan,
                    expectedPendingSHA256: AuthorityRecordCodec.sha256(
                        try Data(
                            contentsOf: root.appendingPathComponent(CanonicalMaintenanceJournal.pendingName)))
                )
            }
        }
        func open(_ supplied: CanonicalMaintenanceContext.Opening? = nil) throws -> ItemStore {
            try .init(
                root: root, accounts: source.sourceAccounts, revisionProjectionEnabled: true,
                authorityIntakeEnabled: true,
                firstSourceOperation: nil, requireInitializedStore: true, canonicalFormatSupport: .current,
                maintenanceOpening: supplied ?? opening)
        }
        func withContext<T>(maximum: UInt64? = nil, _ body: (CanonicalMaintenanceContext) throws -> T) throws
            -> T
        {
            let writer = tractanda_lock(root.appendingPathComponent(".writer.lock").path)
            guard writer >= 0 else { throw TractandaError("fixture", "Writer did not close") }
            defer { tractanda_unlock(writer) }
            var request = try opening
            if let maximum { request.maximumPrivateWorkBytes = maximum }
            let context = try CanonicalMaintenanceContext(
                root: root,
                indexDirectory: root.appendingPathComponent("index"), writer: writer, opening: request)
            defer { context.close() }
            return try body(context)
        }
        func privateBytes() throws -> UInt64 {
            var total: UInt64 = 0
            for directory in [audit, root.appendingPathComponent("index")] {
                let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
                for case let path as URL in entries {
                    let metadata = try FileMetadata.read(at: path)
                    if metadata.type == .regular { total += metadata.size }
                }
            }
            return total
        }
        func authorityOriginalBytes(id: String) throws -> Data {
            let entries = FileManager.default.enumerator(
                at: root.appendingPathComponent("authority/records"),
                includingPropertiesForKeys: nil)!
            for case let path as URL in entries where path.lastPathComponent == id + ".authority" {
                return try Data(contentsOf: path)
            }
            throw TractandaError("fixture", "Actual canonical authority original missing")
        }
        func derivedAudits() throws -> [CanonicalMaintenanceContext.DerivedAudit] {
            var result = [CanonicalMaintenanceContext.DerivedAudit]()
            for name in try FileManager.default.contentsOfDirectory(atPath: audit.path)
            where name.hasPrefix("derived-") {
                let bytes = try Data(contentsOf: audit.appendingPathComponent(name))
                result.append(try JSON.decode(CanonicalMaintenanceContext.DerivedAudit.self, bytes))
            }
            return result
        }
        func allCanonicalHashes() throws -> [String: String] {
            var result = [String: String]()
            let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            for case let path as URL in entries {
                let relative = String(path.path.dropFirst(root.path.count + 1))
                if relative == "index" || relative.hasPrefix("index/") || relative == StoreCheckpoint.name {
                    continue
                }
                if try FileMetadata.read(at: path).type == .regular {
                    result[relative] = AuthorityRecordCodec.sha256(try Data(contentsOf: path))
                }
            }
            return result
        }
        func protectedHashes() throws -> [String: String] {
            var result = [String: String]()
            for prefix in ["items", "attachments", "documents", ".peer-credentials"] {
                let base = root.appendingPathComponent(prefix)
                guard FileManager.default.fileExists(atPath: base.path) else { continue }
                let all = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)!
                for case let path as URL in all {
                    let metadata = try FileMetadata.read(at: path)
                    if metadata.type == .regular {
                        result[String(path.path.dropFirst(root.path.count + 1))] =
                            AuthorityRecordCodec.sha256(try Data(contentsOf: path))
                    }
                }
            }
            return result
        }
    }
    private func code(_ body: () throws -> Void) -> String? {
        do {
            try body()
            XCTFail("Expected fail-closed result")
            return nil
        } catch let error as TractandaError { return error.code } catch {
            XCTFail("Unexpected error \(error)")
            return nil
        }
    }
    func testActualOpeningRejectsUnappliedOrRolledBackPlanBeforeRecovery() throws {
        for rollback in [false, true] {
            let f = try Fixture(applied: rollback, rollback: rollback)
            let before = try f.protectedHashes()
            do {
                _ = try f.open()
                XCTFail("Unfinished/rolled-back plan must not open")
            } catch let error as TractandaError {
                XCTAssertEqual(error.code, "maintenanceConflict")
                XCTAssertTrue(
                    error.message.contains(rollback ? "rollback" : "completely APPLIED"), error.message)
            }
            XCTAssertEqual(try f.protectedHashes(), before)
            try f.source.capacity()
        }
    }
    func testActualFilePayloadAndCredentialWritersAreDeniedEvenForAppliedPlanBytes() throws {
        let f = try Fixture(seedPayloadStage: true)
        let before = try f.protectedHashes()
        let files = DocumentContentFiles(
            root: f.root, ownerUID: tractanda_uid(), minimumFreeBytes: 10 * 1024 * 1024 * 1024)
        XCTAssertEqual(
            code { try files.writeImmutable(f.plan.edits[0].after!, path: f.plan.edits[0].path) },
            "maintenanceProposedMutation")
        XCTAssertEqual(
            code {
                try files.writeImmutable(
                    Data("unplanned".utf8),
                    path: [
                        "authority", "records", "2026", "10", "24", "00", "00",
                        UUID.makeVersion1().uuidString.lowercased() + ".authority",
                    ])
            }, "maintenanceProposedMutation")
        XCTAssertEqual(
            code {
                try files.createUniqueDirectory([
                    "documents", ".staging", UUID.makeVersion1().uuidString.lowercased(),
                ])
            }, "maintenanceProposedMutation")
        let payloads = try AttachmentPayloadStore(root: f.root, ownerUID: tractanda_uid())
        XCTAssertEqual(
            code { try payloads.createStaging(id: UUID.makeVersion1().uuidString.lowercased()) },
            "maintenanceProposedMutation")
        let stageID = try XCTUnwrap(f.payloadStageID)
        let size = try payloads.stagedSize(id: stageID)
        XCTAssertEqual(
            code { _ = try payloads.append(id: stageID, offset: size, data: Data("must not append".utf8)) },
            "maintenanceProposedMutation")
        XCTAssertEqual(
            code { try payloads.truncatePeerUnacknowledgedTail(stageID: stageID, to: 0) },
            "maintenanceProposedMutation")
        XCTAssertEqual(code { try payloads.discardStaging(id: stageID) }, "maintenanceProposedMutation")
        XCTAssertEqual(code { try payloads.clearStaging() }, "maintenanceProposedMutation")
        XCTAssertEqual(try payloads.stagedSize(id: stageID), size)
        let binding = try PeerExchangeBinding(
            peerID: "private-fixture", storeID: f.storeID,
            localReplicaID: f.plan.replicaID, remoteReplicaID: UUID.makeVersion1().uuidString.lowercased(),
            pairingID: UUID.makeVersion1().uuidString.lowercased(), localIsInitiator: true,
            configurationDigest: String(repeating: "a", count: 64))
        let credential = try PeerCredential(binding: binding, secret: Array(repeating: 42, count: 32))
        XCTAssertThrowsError(try PeerCredentialStore(files: files).stage(credential))
        XCTAssertEqual(try f.protectedHashes(), before)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".peer-credentials").path))
        try f.source.capacity()
    }

    func testHistoricalMaintenancePlanCannotBypassExplicitPersonalActivationOrChangeCanonicalBytes() throws {
        for atomic in [false, true] {
            let fixture = try Fixture(atomicSource: atomic)
            let before = try fixture.allCanonicalHashes()
            XCTAssertThrowsError(try fixture.open()) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "personalMigrationRequired")
            }
            XCTAssertEqual(try fixture.allCanonicalHashes(), before)
            XCTAssertTrue(try CanonicalMaintenanceContext.pending(root: fixture.root))
            try fixture.source.capacity()
        }
    }

    func testMarkerDriftAndDerivedCapacityRefuseBeforeNormalColdWork() throws {
        let f = try Fixture()
        let before = try f.protectedHashes()
        var request = try f.opening
        request.minimumFreeBytes = UInt64.max
        XCTAssertEqual(
            code {
                _ = try ItemStore(
                    root: f.root, accounts: f.source.sourceAccounts,
                    revisionProjectionEnabled: true, authorityIntakeEnabled: true, firstSourceOperation: nil,
                    requireInitializedStore: true, maintenanceOpening: request)
            }, "resourceLimit")
        let correct = try f.opening
        let marker = f.root.appendingPathComponent(CanonicalMaintenanceJournal.pendingName)
        try Data("unexpected-marker".utf8).write(to: marker, options: .atomic)
        XCTAssertEqual(
            code {
                _ = try ItemStore(
                    root: f.root, accounts: f.source.sourceAccounts,
                    revisionProjectionEnabled: true, authorityIntakeEnabled: true, firstSourceOperation: nil,
                    requireInitializedStore: true, maintenanceOpening: correct)
            }, "maintenanceConflict")
        XCTAssertEqual(try f.protectedHashes(), before)
        try f.source.capacity()
    }
    func testAbsentDocumentStageDoesNotPermitFrozenMarkerDeletion() throws {
        let f = try Fixture()
        let id = try UUID.makeVersion1().uuidString.lowercased()
        let stage = ["documents", ".staging", id]
        let parent = f.root.appendingPathComponent("documents/.staging")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let marker = parent.appendingPathComponent(id + ".frozen.json")
        let bytes = Data("preserved frozen recovery marker".utf8)
        try bytes.write(to: marker)
        let reference = try DocumentContentReference(
            contentID: id,
            manifestSHA256: String(repeating: "a", count: 64), rootSHA256: String(repeating: "b", count: 64),
            pageCount: 1, totalEncodedBytes: 1, coverage: .init(converted: 0, failed: 1))
        let files = DocumentContentFiles(
            root: f.root, ownerUID: tractanda_uid(), minimumFreeBytes: 10 * 1024 * 1024 * 1024)
        XCTAssertEqual(
            code { try files.finishAppliedPeerDocumentStage(stage, reference: reference) },
            "maintenanceProposedMutation")
        XCTAssertEqual(try Data(contentsOf: marker), bytes)
        // Fixture removes only its own marker; the real cleanup then has no canonical output.
        try FileManager.default.removeItem(at: marker)
        try files.finishAppliedPeerDocumentStage(stage, reference: reference)
        XCTAssertTrue(try CanonicalMaintenanceContext.pending(root: f.root))
        try f.source.capacity()
    }
    func testCheckpointCapabilityRejectsDifferentRootAndAuditsFixedSameRootActions() throws {
        let f = try Fixture()
        let other = f.source.directory.appendingPathComponent("other-checkpoint-root")
        try FileManager.default.createDirectory(
            at: other, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try StoreCheckpoint.markDirty(root: other)
        let before = try Data(contentsOf: other.appendingPathComponent(StoreCheckpoint.name))
        try f.withContext { context in
            XCTAssertEqual(
                code { try StoreCheckpoint.markDirty(root: other, maintenance: context) },
                "maintenanceConflict")
            XCTAssertEqual(
                code { try StoreCheckpoint.clear(root: other, maintenance: context) }, "maintenanceConflict")
            XCTAssertEqual(try Data(contentsOf: other.appendingPathComponent(StoreCheckpoint.name)), before)
            try StoreCheckpoint.markDirty(root: f.root, maintenance: context)
            XCTAssertTrue(StoreCheckpoint.isDirty(root: f.root))
            try StoreCheckpoint.clear(root: f.root, maintenance: context)
            XCTAssertFalse(StoreCheckpoint.isDirty(root: f.root))
        }
        var actions = [CanonicalMaintenanceContext.DerivedAudit]()
        for name in try FileManager.default.contentsOfDirectory(atPath: f.audit.path)
        where name.hasPrefix("derived-") {
            actions.append(
                try JSON.decode(
                    CanonicalMaintenanceContext.DerivedAudit.self,
                    Data(contentsOf: f.audit.appendingPathComponent(name))))
        }
        XCTAssertEqual(actions.filter { $0.kind == .checkpointDirty && $0.phase == .completed }.count, 1)
        XCTAssertEqual(actions.filter { $0.kind == .checkpointClear && $0.phase == .completed }.count, 1)
        XCTAssertTrue(try CanonicalMaintenanceContext.pending(root: f.root))
        try f.source.capacity()
    }
    func testPlacementRecoveryRequiresExplicitContextAndReservesNextBatchBeforeSQLiteWrite() throws {
        for document in [false, true] {
            let f = try Fixture()
            let before = try f.protectedHashes()
            let index = f.root.appendingPathComponent("index")
            let database = index.appendingPathComponent(document ? "documents.sqlite" : "payloads.sqlite")
            let databaseBefore = try Data(contentsOf: database)
            let lock = f.root.appendingPathComponent(
                document ? ".document-placement.lock" : ".payload-placement.lock")
            XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
            func prepare(_ context: CanonicalMaintenanceContext?) throws {
                if document {
                    let placement = DocumentPlacement(
                        root: f.root, indexDirectory: index,
                        ownerUID: tractanda_uid(), maintenance: context, reserve: { _, _ in })
                    try placement.prepare(recover: { _ in }, reconcile: { _, _ in false })
                } else {
                    let placement = PayloadPlacement(
                        root: f.root, indexDirectory: index,
                        ownerUID: tractanda_uid(), maintenance: context, reserve: { _, _ in })
                    try placement.prepare(recover: { _ in }, reconcile: { _, _ in false })
                }
            }
            XCTAssertEqual(code { try prepare(nil) }, "maintenanceProposedMutation")
            // Downward-only aggregate allowance leaves room for the intent/failure audit,
            // but less than the next conservative 64 KiB SQLite batch plus audit headroom.
            let maximum = try f.privateBytes() + 32 * 1024
            try f.withContext(maximum: maximum) { context in
                XCTAssertEqual(code { try prepare(context) }, "resourceLimit")
            }
            XCTAssertEqual(try Data(contentsOf: database), databaseBefore)
            let audits = try FileManager.default.contentsOfDirectory(atPath: f.audit.path).filter {
                $0.hasPrefix("derived-")
            }
            let failed = try audits.map {
                try JSON.decode(
                    CanonicalMaintenanceContext.DerivedAudit.self,
                    Data(contentsOf: f.audit.appendingPathComponent($0)))
            }.filter { $0.kind == .placement && $0.phase == .failed }
            XCTAssertEqual(failed.count, 1)
            XCTAssertEqual(try f.protectedHashes(), before)
            XCTAssertTrue(try CanonicalMaintenanceContext.pending(root: f.root))
            try f.source.capacity()
        }
    }

    func testUnknownProducerScratchIsNeverAdoptedOrDeletedByHistoricalScope() throws {
        for marker in [false, true] {
            let f = try Fixture(atomicSource: true, freshDerivedIndex: true)
            let base = f.root.appendingPathComponent("index/atomic-authority-work")
                .appendingPathComponent(try UUID.makeVersion1().uuidString.lowercased())
            let parent =
                marker
                ? base.appendingPathComponent("control/read-work")
                    .appendingPathComponent(try UUID.makeVersion1().uuidString.lowercased())
                : base.appendingPathComponent("package")
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let sentinel = parent.appendingPathComponent(
                marker ? try UUID.makeVersion1().uuidString.lowercased() : "unplanned")
            let bytes = marker ? Data([2]) : Data("retain unknown producer scratch".utf8)
            try bytes.write(to: sentinel)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: sentinel.path)
            let before = try f.allCanonicalHashes()
            XCTAssertEqual(code { _ = try f.open() }, "maintenanceConflict")
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            XCTAssertEqual(try f.allCanonicalHashes(), before)
            try f.source.capacity()
        }
    }
    func testHistoricalFilesystemScopeRequiresExactAcceptedProofAndCannotBeUsedAsProducer() throws {
        let f = try Fixture(atomicSource: true, clearCompletedScratch: true)
        let before = try f.allCanonicalHashes()
        try f.withContext { context in
            let index = try ItemIndex(
                path: f.root.appendingPathComponent("index/items.sqlite").path, create: false)
            let coordinator = PeerIntakeCoordinator(
                root: f.root, ownerUID: tractanda_uid(), storeID: f.storeID)
            let rows = try index.authorityKindPage(kind: "atomicControl", after: nil, limit: 128)
            var accepted: AtomicAuthorityHistoricalAcceptance?
            for row in rows {
                let binding = try AuthorityBinding(recordID: row.descriptor.id, sha256: row.descriptor.sha256)
                if let proof = try AtomicAuthorityHistoricalAcceptance.find(
                    binding,
                    receiverReplicaID: f.plan.replicaID, coordinator: coordinator, index: index)
                {
                    accepted = proof
                    break
                }
            }
            let proof = try XCTUnwrap(accepted)
            let scope = try context.prepareHistoricalScratch(proof, coordinator: coordinator)
            XCTAssertEqual(
                code { _ = try scope.storageHooks.begin(.immutableWrite, ["reservation"], 1) },
                "maintenanceConflict")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: scope.root.appendingPathComponent("package").path))
            let scratchRoot = scope.control.appendingPathComponent("root")
            let unexpected = Data("substituted private scratch root".utf8)
            try unexpected.write(to: scratchRoot)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: scratchRoot.path)
            XCTAssertThrowsError(try scope.cleanup())
            XCTAssertEqual(try Data(contentsOf: scratchRoot), unexpected)
            let canonicalRoot = try coordinator.bytes(proof.original)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scratchRoot.path)
            try canonicalRoot.write(to: scratchRoot)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: scratchRoot.path)
            try scope.cleanup()
            let receipt = f.root.appendingPathComponent("authority/intake")
                .appendingPathComponent(proof.sealed.receipt.packageID)
                .appendingPathComponent("atomic-accepted")
                .appendingPathComponent(proof.sealed.receipt.root.recordID + ".json")
            let original = try Data(contentsOf: receipt)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
            try Data("altered private fixture proof".utf8).write(to: receipt)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: receipt.path)
            XCTAssertThrowsError(try context.prepareHistoricalScratch(proof, coordinator: coordinator))
            // Restore only this fixture mutation; no production or synthesized admission.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
            try original.write(to: receipt)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: receipt.path)
            let second = try context.prepareHistoricalScratch(proof, coordinator: coordinator)
            try second.cleanup()
            let third = try context.prepareHistoricalScratch(proof, coordinator: coordinator)
            context.close()
            XCTAssertThrowsError(try third.storageHooks.begin(.lease, [".archive.lock"], 4096))
        }
        XCTAssertEqual(try f.allCanonicalHashes(), before)
        try f.source.capacity()
    }

}
