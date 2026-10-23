import CTractandaPlatform
import XCTest

@testable import TractandaCore

/// Cold tests of actual accepted receipts and current authorization. No accepted-row seeding.
final class AtomicAuthorityRecoveryTests: XCTestCase {
    private typealias Fixture = AtomicAuthorityReplicationTests.Fixture
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func withIndex<T>(_ root: URL, _ body: (ItemIndex) throws -> T) throws -> T {
        let index = try ItemIndex(path: root.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        return try body(index)
    }
    private func close(_ f: Fixture) {
        f.enrolled.target = nil
        f.enrolled.source.source = nil
    }
    private func reopen(_ f: Fixture) throws {
        f.enrolled.source.source = try AtomicAuthorityStoreFixture.open(
            f.enrolled.source.sourceRoot, accounts: f.enrolled.source.accounts)
        f.enrolled.target = try AtomicAuthorityStoreFixture.open(
            f.enrolled.source.targetRoot, accounts: f.targetAccounts)
    }
    private func removeIndexOnly(_ root: URL) throws {
        for name in ["items.sqlite", "items.sqlite-wal", "items.sqlite-shm", "items.sqlite-journal"] {
            let file = root.appendingPathComponent("index").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                XCTAssertEqual(try FileMetadata.read(at: file).type, .regular)
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    private func isDerived(_ relative: String) -> Bool {
        if relative == StoreCheckpoint.name { return true }
        let fixed: Set<String> = [
            "index/items.sqlite", "index/items.sqlite-wal", "index/items.sqlite-shm",
            "index/items.sqlite-journal",
        ]
        if fixed.contains(relative) { return true }
        // Only exact UUID-named rebuild SQLite files are disposable after an interrupted
        // rebuild. All other index files and every hidden peer/configuration file are hashed.
        guard relative.hasPrefix("index/rebuild-"), !relative.dropFirst(6).contains("/") else { return false }
        var name = String(relative.dropFirst("index/rebuild-".count))
        for suffix in ["-wal", "-shm", "-journal"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        guard name.hasSuffix(".sqlite") else { return false }
        name.removeLast(".sqlite".count)
        return UUID(uuidString: name) != nil
    }
    private func canonicalSnapshot(_ root: URL) throws -> [String: String] {
        try AttachmentFixtureCapacity.requireFree(at: root)
        var total: UInt64 = 0
        var result: [String: String] = [:]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let file as URL in files {
            let metadata = try FileMetadata.read(at: file)
            guard metadata.type == .regular else {
                XCTAssertEqual(metadata.type, .directory, "Unexpected fixture object: \(file.path)")
                continue
            }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if isDerived(relative) { continue }
            guard
                metadata.size <= AttachmentFixtureCapacity.fixtureCapBytes
                    - min(total, AttachmentFixtureCapacity.fixtureCapBytes)
            else {
                throw TractandaError("resourceLimit", "Recovery fingerprint fixture cap")
            }
            total += metadata.size
            result[relative] = AuthorityRecordCodec.sha256(try Data(contentsOf: file))
        }
        XCTAssertTrue(result.keys.contains(".tractanda-store-identity.json"))
        XCTAssertTrue(result.keys.contains { $0.hasPrefix(".peer-configuration/") })
        XCTAssertTrue(result.keys.contains { $0.contains("/atomic-accepted/") })
        return result
    }
    private func assertSnapshot(
        _ root: URL, equals expected: [String: String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let actual = try canonicalSnapshot(root)
        let changed = Set(actual.keys).union(expected.keys).filter { actual[$0] != expected[$0] }.sorted()
        XCTAssertTrue(
            changed.isEmpty,
            "Canonical file changes (\(changed.count)): " + changed.prefix(64).joined(separator: ", "),
            file: file, line: line)
    }
    private func authorityState(_ root: URL, origins: [String], revisions: [String]) throws -> [String:
        String]
    {
        try withIndex(root) { index in
            let storeID = try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: tractanda_uid())
            let coordinator = PeerIntakeCoordinator(root: root, ownerUID: tractanda_uid(), storeID: storeID)
            var state: [String: String] = [:]
            for origin in origins {
                let head = try XCTUnwrap(index.authorityControlHead(originID: origin))
                state["head:" + origin] = head.recordID + ":" + head.sha256
                XCTAssertTrue(try index.hasValidatedAuthorityControl(head))
                let raw = try XCTUnwrap(index.retainedAuthorityObject(id: head.recordID))
                let original = try coordinator.bytes(raw)
                let atomic = try index.isAcceptedAtomicControl(head)
                state["atomic:" + origin] = String(atomic)
                if atomic {
                    let accepted = try XCTUnwrap(
                        coordinator.journal.atomicAcceptance(packageID: raw.packageID, root: head))
                    state["receipt:" + origin] = accepted.bytesSHA256
                } else {
                    try coordinator.requireRetainedReceipt(raw, original: original, index: index)
                    state["receipt:" + origin] = AuthorityRecordCodec.sha256(
                        try JSON.encode(XCTUnwrap(coordinator.journal.publication(raw.packageID))))
                }
                state["package:" + origin] = raw.packageID
                state["original:" + origin] = AuthorityRecordCodec.sha256(original)
            }
            for revision in revisions {
                state["visible:" + revision] = String(try index.revision(revision) != nil)
                state["disposition:" + revision] =
                    try index.authorityDisposition(id: revision)?.disposition.rawValue ?? "absent"
                state["history:" + revision] = String(
                    try index.authorityHasLocalHistoryAdmission(revisionID: revision))
                let local = try index.localAuthorityAcceptanceControl(revisionID: revision)
                state["local:" + revision] = local.map { $0.recordID + ":" + $0.sha256 } ?? "none"
            }
            return state
        }
    }
    private func applied(_ root: URL, packageID: String) throws {
        let storeID = try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: tractanda_uid())
        let coordinator = PeerIntakeCoordinator(root: root, ownerUID: tractanda_uid(), storeID: storeID)
        let publication = try XCTUnwrap(coordinator.journal.publication(packageID))
        try coordinator.journal.applied(packageID)
        let bytes = try coordinator.journal.files.read(
            path: ["authority", "intake", packageID, "applied.json"],
            maximumBytes: PeerPackage.maximumPageBytes)
        XCTAssertEqual(try PeerPackage.decode(PeerIntakeJournal.Publication.self, bytes), publication)
    }
    private func denied(_ f: Fixture, operation: String) throws -> Revision {
        let revision = try f.source.withAccess(forUID: f.enrolled.source.accounts.contributor) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: f.enrolled.revision.itemID,
                    expectedRevisionID: f.enrolled.revision.revisionID,
                    changes: ["subject": .text(operation)], operationID: operation)
            ).revision
        }
        f.targetAccounts.contributorHasWriterGroup = false
        let (handle, manifest) = try f.packet(revision.revisionID)
        let result = try f.send(handle, manifest: manifest)
        XCTAssertEqual(result.missing, 0)
        XCTAssertGreaterThanOrEqual(result.held, 1)
        return revision
    }
    private func assertDenied(_ f: Fixture, revision: Revision) throws {
        try withIndex(f.enrolled.source.targetRoot) { index in
            let head = try XCTUnwrap(index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)))
            XCTAssertTrue(try index.isAcceptedAtomicControl(head))
            XCTAssertEqual(try index.authorityDisposition(id: revision.revisionID)?.disposition, .held)
            XCTAssertNil(try index.revision(revision.revisionID))
            XCTAssertFalse(try index.authorityHasLocalHistoryAdmission(revisionID: revision.revisionID))
            XCTAssertNil(try index.localAuthorityAcceptanceControl(revisionID: revision.revisionID))
        }
        XCTAssertEqual(
            try f.target.withAccess(forUID: f.enrolled.source.uid) {
                try f.target.get(revision.itemID).revisionID
            }, f.enrolled.revision.revisionID)
    }

    func testAcceptedForeignAndLocalHistorySurviveAppliedCleanupAndIndexOnlyDeletion() throws {
        let f = try Fixture()
        let foreign = try f.revise(
            f.enrolled.revision, operation: "recovery-foreign", subject: "foreign accepted")
        let (handle, manifest) = try f.packet(foreign.revisionID)
        XCTAssertEqual(try f.send(handle, manifest: manifest).held, 0)
        let local = try f.target.withAccess(forUID: f.enrolled.source.uid) {
            try f.target.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("local accepted")],
                    operationID: "recovery-local")
            ).revision
        }
        let sourceOrigin = try XCTUnwrap(f.source.replicaID)
        let targetOrigin = try XCTUnwrap(f.target.replicaID)
        let sourceRoot = f.enrolled.source.sourceRoot
        let targetRoot = f.enrolled.source.targetRoot
        try applied(targetRoot, packageID: manifest.packageID)
        let sourceState = try authorityState(
            sourceRoot, origins: [sourceOrigin], revisions: [foreign.revisionID])
        let targetState = try authorityState(
            targetRoot, origins: [sourceOrigin, targetOrigin],
            revisions: [foreign.revisionID, local.revisionID])
        XCTAssertEqual(sourceState["atomic:" + sourceOrigin], "true")
        XCTAssertEqual(targetState["atomic:" + sourceOrigin], "true")
        XCTAssertEqual(targetState["atomic:" + targetOrigin], "true")
        XCTAssertEqual(targetState["history:" + foreign.revisionID], "true")
        XCTAssertEqual(targetState["history:" + local.revisionID], "true")
        try applied(sourceRoot, packageID: XCTUnwrap(sourceState["package:" + sourceOrigin]))
        try applied(targetRoot, packageID: XCTUnwrap(targetState["package:" + targetOrigin]))
        close(f)
        let sourceBytes = try canonicalSnapshot(sourceRoot)
        let targetBytes = try canonicalSnapshot(targetRoot)
        try removeIndexOnly(sourceRoot)
        try removeIndexOnly(targetRoot)
        try reopen(f)
        XCTAssertEqual(f.source.replicaID, sourceOrigin)
        XCTAssertEqual(f.target.replicaID, targetOrigin)
        XCTAssertEqual(
            try authorityState(sourceRoot, origins: [sourceOrigin], revisions: [foreign.revisionID]),
            sourceState)
        XCTAssertEqual(
            try authorityState(
                targetRoot, origins: [sourceOrigin, targetOrigin],
                revisions: [foreign.revisionID, local.revisionID]), targetState)
        XCTAssertEqual(
            try f.target.withAccess(forUID: f.enrolled.source.uid) {
                try f.target.get(foreign.itemID).revisionID
            }, foreign.revisionID)
        XCTAssertEqual(
            try f.target.withAccess(forUID: f.enrolled.source.uid) {
                try f.target.get(local.itemID).revisionID
            }, local.revisionID)
        close(f)
        try assertSnapshot(sourceRoot, equals: sourceBytes)
        try assertSnapshot(targetRoot, equals: targetBytes)
        try f.enrolled.source.capacity()
    }

    func testCurrentMappingDeniedHistoryRemainsHeldAfterColdRebuildWithAcceptedForeignRoot() throws {
        let f = try Fixture(nonAdministratorWriter: true)
        let revision = try denied(f, operation: "recovery-current-denied")
        try assertDenied(f, revision: revision)
        let sourceOrigin = try XCTUnwrap(f.source.replicaID)
        let targetOrigin = try XCTUnwrap(f.target.replicaID)
        let root = f.enrolled.source.targetRoot
        let state = try authorityState(
            root, origins: [sourceOrigin, targetOrigin], revisions: [revision.revisionID])
        close(f)
        let bytes = try canonicalSnapshot(root)
        try removeIndexOnly(root)
        try reopen(f)
        try assertDenied(f, revision: revision)
        XCTAssertEqual(
            try authorityState(
                root, origins: [sourceOrigin, targetOrigin], revisions: [revision.revisionID]), state)
        close(f)
        try assertSnapshot(root, equals: bytes)
        try f.enrolled.source.capacity()
    }

    func testInterruptedAcceptedRestoreRetriesSameCanonicalStoreWithoutChangingReceipts() throws {
        let f = try Fixture()
        let revision = try f.revise(
            f.enrolled.revision, operation: "recovery-interrupted", subject: "survives interrupted restore")
        let (handle, manifest) = try f.packet(revision.revisionID)
        XCTAssertEqual(try f.send(handle, manifest: manifest).held, 0)
        let sourceOrigin = try XCTUnwrap(f.source.replicaID)
        let targetOrigin = try XCTUnwrap(f.target.replicaID)
        let root = f.enrolled.source.targetRoot
        let state = try authorityState(
            root, origins: [sourceOrigin, targetOrigin], revisions: [revision.revisionID])
        let bytes = try canonicalSnapshot(root)
        var interrupted = false
        f.target.beforeRevisionGraphValidationForTesting = { index in
            interrupted = true
            index.graphMaximumTemporaryBytes = 1
        }
        XCTAssertThrowsError(
            try f.target.withAccess(forUID: f.enrolled.source.uid) { try f.target.rebuildIndex() }
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertTrue(interrupted)
        XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
        close(f)
        try assertSnapshot(root, equals: bytes)
        try reopen(f)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
        XCTAssertEqual(
            try authorityState(
                root, origins: [sourceOrigin, targetOrigin], revisions: [revision.revisionID]), state)
        XCTAssertEqual(
            try f.target.withAccess(forUID: f.enrolled.source.uid) {
                try f.target.get(revision.itemID).revisionID
            }, revision.revisionID)
        close(f)
        try assertSnapshot(root, equals: bytes)
        try f.enrolled.source.capacity()
    }
    func testPreviouslyAdmittedHistorySurvivesMappingLossButCurrentAndHistoryReadsAreDenied() throws {
        let f = try Fixture(nonAdministratorWriter: true)
        f.targetAccounts.contributorHasWriterGroup = true
        let revision = try f.source.withAccess(forUID: f.enrolled.source.accounts.contributor) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: f.enrolled.revision.itemID,
                    expectedRevisionID: f.enrolled.revision.revisionID,
                    changes: ["subject": .text("admitted before current group loss")],
                    operationID: "recovery-admitted-before-group-loss")
            ).revision
        }
        let (handle, manifest) = try f.packet(revision.revisionID)
        let received = try f.send(handle, manifest: manifest)
        XCTAssertEqual(received.missing, 0)
        XCTAssertEqual(received.held, 0)
        XCTAssertGreaterThanOrEqual(received.accepted, 1)
        try f.target.withAccess(forUID: f.targetAccounts.contributor) {
            XCTAssertEqual(try f.target.get(revision.itemID).revisionID, revision.revisionID)
            XCTAssertEqual(try f.target.get(revision.itemID, revisionID: revision.revisionID), revision)
            XCTAssertTrue(
                try f.target.history(revision.itemID).contains { $0.revisionID == revision.revisionID })
        }
        let sourceOrigin = try XCTUnwrap(f.source.replicaID)
        let targetOrigin = try XCTUnwrap(f.target.replicaID)
        let root = f.enrolled.source.targetRoot
        let state = try authorityState(
            root, origins: [sourceOrigin, targetOrigin], revisions: [revision.revisionID])
        XCTAssertEqual(state["history:" + revision.revisionID], "true")
        XCTAssertNotEqual(state["local:" + revision.revisionID], "none")
        XCTAssertEqual(state["atomic:" + targetOrigin], "true")
        try applied(root, packageID: manifest.packageID)
        f.targetAccounts.contributorHasWriterGroup = false
        close(f)
        let bytes = try canonicalSnapshot(root)
        try removeIndexOnly(root)
        try reopen(f)
        let restored = try authorityState(
            root, origins: [sourceOrigin, targetOrigin], revisions: [revision.revisionID])
        // Current materialization is a separate reduction. These keys describe the immutable
        // historical decision and local history admission, rather than today's read permission.
        for (key, value) in state where !key.hasPrefix("visible:") && !key.hasPrefix("disposition:") {
            XCTAssertEqual(restored[key], value, "Historical authority changed at " + key)
        }
        XCTAssertEqual(restored["history:" + revision.revisionID], "true")
        XCTAssertNotEqual(restored["local:" + revision.revisionID], "none")
        XCTAssertThrowsError(
            try f.target.withAccess(forUID: f.targetAccounts.contributor) {
                try f.target.get(revision.itemID)
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        XCTAssertThrowsError(
            try f.target.withAccess(forUID: f.targetAccounts.contributor) {
                try f.target.get(revision.itemID, revisionID: revision.revisionID)
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        XCTAssertThrowsError(
            try f.target.withAccess(forUID: f.targetAccounts.contributor) {
                try f.target.history(revision.itemID)
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        close(f)
        try assertSnapshot(root, equals: bytes)
        try f.enrolled.source.capacity()
    }

    func testPreparedPositiveForGenuineHeldOriginalCannotBecomeAcceptedOnColdRecovery() throws {
        let f = try Fixture(nonAdministratorWriter: true)
        let revision = try denied(f, operation: "recovery-prepared-held")
        try assertDenied(f, revision: revision)
        let root = f.enrolled.source.targetRoot
        let sourceOrigin = try XCTUnwrap(f.source.replicaID)
        let targetOrigin = try XCTUnwrap(f.target.replicaID)
        let before = try authorityState(
            root, origins: [sourceOrigin, targetOrigin], revisions: [revision.revisionID])
        // The receiver intentionally elects no evidence for held history. Select the source's
        // actual accepted witness, then require the receiver's identical retained raw original.
        let sourceEvidence = try withIndex(f.enrolled.source.sourceRoot) { index in
            let storeID = try CanonicalReaderRequirement.storeIdentity(
                root: f.enrolled.source.sourceRoot, ownerUID: tractanda_uid())
            let coordinator = PeerIntakeCoordinator(
                root: f.enrolled.source.sourceRoot, ownerUID: tractanda_uid(), storeID: storeID)
            let row = try XCTUnwrap(index.authorityEvidence(revisionID: revision.revisionID))
            return (row.descriptor, try coordinator.bytes(row))
        }
        let prepared: (AuthorityBinding, String) = try withIndex(root) { index in
            let storeID = try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: tractanda_uid())
            let coordinator = PeerIntakeCoordinator(root: root, ownerUID: tractanda_uid(), storeID: storeID)
            coordinator.canonicalFormatSupport = AtomicAuthorityCompatibility.support
            let previous = try XCTUnwrap(index.authorityControlHead(originID: targetOrigin))
            let sourceHead = try XCTUnwrap(index.authorityControlHead(originID: sourceOrigin))
            let bootstrap = try coordinator.logicalControlHeader(previous, index: index).bootstrap
            let evidence = try XCTUnwrap(index.retainedAuthorityObject(id: sourceEvidence.0.id))
            let evidenceBytes = try coordinator.bytes(evidence)
            XCTAssertEqual(evidence.descriptor, sourceEvidence.0)
            XCTAssertEqual(evidenceBytes, sourceEvidence.1)
            guard evidence.descriptor == sourceEvidence.0, evidenceBytes == sourceEvidence.1 else {
                throw TractandaError(
                    "fixture", "Receiver did not retain the source's exact authored evidence")
            }
            let target = try XCTUnwrap(index.retainedAuthorityObject(id: revision.revisionID))
            let node = try AuthorityRevision(originalBytes: coordinator.bytes(target))
            XCTAssertEqual(node.revision, revision)
            let original = try AuthorityRecordCodec.decode(evidenceBytes).record
            guard try coordinator.matchesIdentity(node, original) else {
                throw TractandaError("fixture", "Authored evidence does not bind the genuine held original")
            }
            let policies = try
                (AuthorityRecord.list(original.payload["admissionPolicies"])
                + AuthorityRecord.list(original.payload["itemPolicies"])).map {
                    try AuthorityRecord.binding($0).revisionID
                }
            let delta = AuthorityStore.DispositionDelta(
                target: try .init(
                    itemID: revision.itemID, revisionID: revision.revisionID,
                    sha256: AuthorityRecordCodec.sha256(RecordCodec.encode(revision))),
                eligible: true, actor: try XCTUnwrap(revision.fields["actor"]?.string),
                policyIDs: Array(Set(policies)).sorted(),
                evidence: try .init(recordID: evidence.descriptor.id, sha256: evidence.descriptor.sha256))
            try f.enrolled.source.capacity()
            let directory = f.enrolled.source.root.appendingPathComponent("prepared-only-" + (try id()))
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let archive = try AtomicAuthorityArchive(
                root: directory, limits: .init(maximumStoredBytes: 2 * 1024 * 1024, maximumParts: 128),
                chunkBytes: 1024)
            var parents = [previous, sourceHead].sorted { $0.recordID < $1.recordID }.map(\.itemValue)
                .makeIterator()
            var effects = [delta.itemValue].makeIterator()
            let handle = try archive.build(
                context: .init(
                    rootID: id(), storeID: storeID, origin: targetOrigin,
                    actor: "user:human", createdAt: Timestamp.now(),
                    inputIdentity: AuthorityRecordCodec.sha256(RecordCodec.encode(revision)),
                    previous: previous, bootstrap: bootstrap),
                parents: { parents.next() }, effects: { effects.next() })
            var objects: [(PeerPackage.Object, Data)] = []
            var bytes = 0
            try archive.forEachUntrustedLocalObject(handle) { descriptor, data in
                bytes += data.count
                guard objects.count < 128, bytes < 2 * 1024 * 1024 else {
                    throw TractandaError("resourceLimit", "Tiny PREPARED physical fixture estimate")
                }
                objects.append((descriptor, data))
            }
            let context = try coordinator.context(peerID: "local")
            let manifest = try coordinator.stageObjects(objects, context: context, packageID: id())
            let publication = PeerIntakeJournal.Publication(
                packageID: manifest.packageID,
                manifestDigest: AuthorityRecordCodec.sha256(try JSON.encode(manifest)),
                context: context, contextToken: "prepared-only-no-acceptance",
                arrivalMinute: try PeerIntakeJournal.currentArrivalMinute())
            try coordinator.journal.prepare(publication)
            try coordinator.journal.seal(manifest.packageID)
            for (descriptor, data) in objects {
                _ = try coordinator.retainSealedOriginal(
                    descriptor, data: data, publication: publication,
                    index: index, applyAssessment: false, allowReviewClosure: true)
            }
            XCTAssertNil(
                try coordinator.journal.files.readIfPresent(
                    path: ["authority", "intake", manifest.packageID, "applied.json"],
                    maximumBytes: PeerPackage.maximumPageBytes))
            XCTAssertNil(
                try coordinator.journal.atomicAcceptance(packageID: manifest.packageID, root: handle.binding))
            XCTAssertFalse(try index.hasValidatedAuthorityControl(handle.binding))
            XCTAssertEqual(try index.authorityControlHead(originID: targetOrigin), previous)
            return (handle.binding, manifest.packageID)
        }
        close(f)
        let bytes = try canonicalSnapshot(root)
        try removeIndexOnly(root)
        try reopen(f)
        try assertDenied(f, revision: revision)
        XCTAssertEqual(
            try authorityState(
                root, origins: [sourceOrigin, targetOrigin], revisions: [revision.revisionID]), before)
        try withIndex(root) { index in
            XCTAssertFalse(try index.hasValidatedAuthorityControl(prepared.0))
            let coordinator = PeerIntakeCoordinator(
                root: root, ownerUID: tractanda_uid(),
                storeID: try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: tractanda_uid()))
            XCTAssertNil(try coordinator.journal.atomicAcceptance(packageID: prepared.1, root: prepared.0))
        }
        close(f)
        try assertSnapshot(root, equals: bytes)
        try f.enrolled.source.capacity()
    }

}
