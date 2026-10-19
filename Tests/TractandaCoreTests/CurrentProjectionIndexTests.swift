import CSQLite
import CTractandaPlatform
import Crypto
import XCTest

@testable import TractandaCore

final class CurrentProjectionIndexTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let index: ItemIndex
        let itemID: String
        let origin: String
        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            itemID = try UUID.makeVersion1().uuidString.lowercased()
            origin = try UUID.makeVersion1().uuidString.lowercased()
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "tractanda-current-" + Identifier.make())
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            index = try ItemIndex(path: root.appendingPathComponent("index.sqlite").path, create: true)
            index.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            try index.validateRecoveryGraph(requireLinearProjection: false)
        }
        deinit {
            index.close()
            try? FileManager.default.removeItem(at: root)
        }
        func record(
            item: String? = nil, parents: [Revision] = [], kind: RevisionProvenance.Kind = .authored,
            writes: [String: ItemValue] = [:], unset: [String] = [], snapshot: [String: ItemValue]? = nil,
            frontier: [String] = [], operationID: String? = nil, at: String? = nil
        ) throws -> (Revision, ItemIndex.CatalogueRow) {
            let id = try UUID.makeVersion1().uuidString.lowercased()
            var fields =
                parents.first?.fields ?? [
                    "classID": .text("Item"), "schemaVersion": .integer(1), "subject": .text("root"),
                    "createdAt": .date("2026-10-13T12:00:00.000Z"),
                ]
            fields.removeValue(forKey: "revisionAncestry")
            fields.removeValue(forKey: "supersedes")
            if let snapshot {
                fields = fields.filter { RevisionMerge.managedFields.contains($0.key) }
                fields.merge(snapshot) { _, new in new }
            }
            fields["itemID"] = .text(item ?? itemID)
            fields["revisionID"] = .text(id)
            fields["actor"] = .text("uid:\(tractanda_uid())")
            fields["operationID"] = .text(operationID ?? id)
            fields["requestIdentity"] = .text("fixture")
            let time =
                try at
                ?? (parents.isEmpty
                    ? "2026-10-13T12:00:00.000Z"
                    : RevisionPublicationClock.after(
                        parents.map(\.modifiedAt), now: { "2026-10-13T12:00:00.000Z" }))
            fields["modifiedAt"] = .date(time)
            if parents.count == 1 { fields["supersedes"] = .text(parents[0].revisionID) }
            for (field, value) in writes { fields[field] = value }
            for field in unset { fields.removeValue(forKey: field) }
            let provenance = try RevisionProvenance(
                kind: kind, originReplicaID: origin,
                parents: parents.map(\.revisionID).sorted(),
                writtenFields: kind == .automaticMerge
                    ? []
                    : (parents.isEmpty
                        ? fields.keys.filter { !RevisionMerge.managedFields.contains($0) }.sorted()
                        : writes.keys.sorted()),
                unsetFields: unset.sorted(), frontier: frontier.sorted(),
                mergeProfile: kind == .automaticMerge ? RevisionMerge.profile : nil)
            fields["revisionAncestry"] = provenance.itemValue
            let revision = try Revision(fields: fields, formatVersion: 2)
            let data = try RecordCodec.encode(revision)
            let directory = root.appendingPathComponent("items/2026/10/13/12/00/" + revision.itemID)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(id + ".tractanda")
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            let m = try FileMetadata.read(at: file)
            return (
                revision,
                .init(
                    revisionID: id, itemID: revision.itemID,
                    path: String(file.path.dropFirst(root.path.count + 1)), parentID: revision.supersedes,
                    actor: fields["actor"]!.string!, operationID: fields["operationID"]!.string!,
                    size: m.size,
                    inode: m.inode, uid: m.uid, mode: m.mode, modificationSeconds: m.modificationSeconds,
                    modificationNanoseconds: m.modificationNanoseconds, digest: Data(SHA256.hash(data: data)),
                    createdAt: fields["createdAt"]!.dateString!, modifiedAt: time, provenance: provenance)
            )
        }
        func policies(_ values: [Revision]) -> [RevisionProjection.PolicyWitness] {
            values.map {
                .init(revisionID: $0.revisionID, classID: $0.classID, permissions: $0.fields["permissions"])
            }.sorted { $0.revisionID < $1.revisionID }
        }
        func ready(_ value: Revision, frontier: [String]? = nil) -> ItemState {
            .init(
                itemID: value.itemID, stateToken: "fixture." + Identifier.make(), status: .ready,
                representativeRevisionID: value.revisionID, frontier: frontier ?? [value.revisionID],
                conflictingFields: [], protectedFields: [], detailsComplete: true)
        }
        func append(_ value: (Revision, ItemIndex.CatalogueRow), parent: Revision? = nil) throws {
            try index.appendValidatedLocal(
                row: value.1, revision: value.0, parent: parent,
                expectedRepresentativeID: parent?.revisionID, state: ready(value.0),
                policies: policies([value.0]))
        }
        func accept(_ value: (Revision, ItemIndex.CatalogueRow)) throws {
            try index.insertRecoveryRow(value.1, graphFields: value.0.fields)
        }
        func analyze() throws -> RevisionProjection.Snapshot {
            var limits = RevisionProjection.Limits()
            limits.minimumFreeBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
            return try index.analyzeRevisionProjection(
                itemID: itemID,
                loadVerified: {
                    try PooledCanonicalRecord.read(row: $0, root: self.root, ownerUID: tractanda_uid())
                }, limits: limits)
        }
        func number(_ sql: String) throws -> Int {
            let s = try index.corpusPrepare(sql)
            defer { sqlite3_finalize(s) }
            guard index.catalogueStep(s) == SQLITE_ROW else { throw index.graphSQLiteError() }
            return Int(sqlite3_column_int64(s, 0))
        }
        func capacity() throws {
            try AttachmentFixtureCapacity.requireFree(at: root)
            guard
                let walk = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.fileSizeKey])
            else {
                throw TractandaError("resourceLimit", "Cannot inspect tiny fixture.")
            }
            var bytes: UInt64 = 0
            while let url = walk.nextObject() as? URL {
                if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    bytes += UInt64(size)
                }
            }
            guard bytes <= AttachmentFixtureCapacity.fixtureCapBytes else {
                throw TractandaError("resourceLimit", "Tiny fixture cap exceeded.")
            }
        }
    }
    private func code(_ code: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, code, "\($0)") }
    }
    private func permissions(_ mode: Int) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text("owner"), "group": .text("team"),
            "mode": .integer(Int64(mode)), "acl": .object([:]),
        ])
    }
    func testThreeHundredValidatedAppendsAndCachedReadsDoNotRevalidateHistory() throws {
        let f = try Fixture()
        XCTAssertLessThan(301 * 16_384, Int(AttachmentFixtureCapacity.fixtureCapBytes))
        var current = try f.record()
        try f.append(current)
        let passes = f.index.graphValidationPassesForTesting
        for number in 1...300 {
            if number % 32 == 0 { try f.capacity() }
            let next = try f.record(parents: [current.0], writes: ["body": .text(String(number))])
            try f.append(next, parent: current.0)
            current = next
            XCTAssertEqual(
                try f.index.currentProjection(itemID: f.itemID)?.state.representativeRevisionID,
                current.0.revisionID)
        }
        XCTAssertEqual(f.index.graphValidationPassesForTesting, passes)
        XCTAssertEqual(try f.index.revisionCount(itemID: f.itemID), 301)
        XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        try f.capacity()
    }
    func testNoopStillCreatesAuthoredRepresentativeAndStaleCASFails() throws {
        let f = try Fixture()
        let root = try f.record()
        try f.append(root)
        let old = try f.index.currentProjection(itemID: f.itemID)!.state
        let noop = try f.record(parents: [root.0], writes: ["subject": .text("root")])
        try f.append(noop, parent: root.0)
        let new = try f.index.currentProjection(itemID: f.itemID)!.state
        XCTAssertNotEqual(old.representativeRevisionID, new.representativeRevisionID)
        XCTAssertEqual(new.frontier, [noop.0.revisionID])
        let stale = try f.record(parents: [root.0], writes: ["subject": .text("stale")])
        code("revisionConflict") { try f.append(stale, parent: root.0) }
        XCTAssertNil(try f.index.revision(stale.0.revisionID))
    }
    func testFrontierPoliciesIntersectConcurrentGrantAndContentUntilResolution() throws {
        let f = try Fixture()
        let root = try f.record(writes: ["permissions": permissions(0o600)])
        try f.append(root)
        let grant = try f.record(parents: [root.0], writes: ["permissions": permissions(0o604)])
        let content = try f.record(
            parents: [root.0], writes: ["subject": .text("private concurrent content")])
        try f.accept(grant)
        try f.accept(content)
        let snapshot = try f.analyze()
        let state = ItemState(
            itemID: f.itemID, stateToken: "review", status: .reviewRequired,
            frontier: snapshot.analysis.frontier,
            conflictingFields: snapshot.analysis.conflicts.keys.sorted(),
            protectedFields: snapshot.analysis.protectedFields.sorted(), detailsComplete: true)
        try f.index.replaceCurrentProjection(
            snapshot: snapshot, state: state, policies: f.policies([grant.0, content.0]),
            policiesComplete: true)
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM items"), 0)
        XCTAssertEqual(try f.index.unresolvedProjectionPage().count, 1)
        try f.index.setRequestPrincipals(actorUID: 2, users: ["owner": 1], groups: ["team": (10, false)])
        XCTAssertFalse(try f.index.hasReadableUnresolvedProjection(aclUserID: 2))
        try f.index.setRequestPrincipals(actorUID: 1, users: ["owner": 1], groups: ["team": (10, false)])
        XCTAssertTrue(try f.index.hasReadableUnresolvedProjection(aclUserID: 1))
        f.index.graphMaximumVMInstructions = 1
        code("resourceLimit") { _ = try f.index.hasReadableUnresolvedProjection(aclUserID: 1) }
        f.index.graphMaximumVMInstructions = 200_000_000
        var fields = snapshot.analysis.fields
        fields["permissions"] = permissions(0o604)
        let resolved = try f.record(
            parents: [grant.0, content.0], kind: .resolution,
            writes: ["permissions": permissions(0o604)], snapshot: fields,
            frontier: snapshot.analysis.frontier, operationID: root.1.operationID)
        try f.index.appendValidatedLocal(
            row: resolved.1, revision: resolved.0, parent: nil,
            expectedRepresentativeID: nil, state: f.ready(resolved.0), policies: f.policies([resolved.0]),
            snapshot: snapshot)
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM items"), 1)
        try f.index.setRequestPrincipals(actorUID: 2, users: ["owner": 1], groups: ["team": (10, false)])
        XCTAssertFalse(try f.index.hasReadableUnresolvedProjection(aclUserID: 2))
        XCTAssertEqual(
            try f.index.currentPolicyWitnesses(itemID: f.itemID).map(\.revisionID), [resolved.0.revisionID])
        XCTAssertEqual(
            try f.index.receipts(named: root.1.operationID, localReplicaID: f.origin, kind: .authored)?.map(
                \.revisionID), [root.0.revisionID])
        XCTAssertEqual(
            try f.index.receipts(named: root.1.operationID, localReplicaID: f.origin, kind: .resolution)?.map(
                \.revisionID), [resolved.0.revisionID])
        XCTAssertEqual(try f.index.receipts(named: root.1.operationID, kind: .resolution)?.count, 0)
    }
    func testFreshAnalyzedContextOnlyAutomaticAppendAndMaintenanceReceiptIsolation() throws {
        let f = try Fixture()
        let root = try f.record()
        try f.append(root)
        let a = try f.record(parents: [root.0], writes: ["subject": .text("A")])
        let b = try f.record(parents: [root.0], writes: ["body": .text("B")])
        try f.accept(a)
        try f.accept(b)
        let snapshot = try f.analyze()
        let merged = try f.record(
            parents: [a.0, b.0], kind: .automaticMerge,
            snapshot: snapshot.analysis.fields, frontier: snapshot.analysis.frontier)
        try f.index.appendValidatedLocal(
            row: merged.1, revision: merged.0, parent: nil,
            expectedRepresentativeID: nil, state: f.ready(merged.0, frontier: snapshot.analysis.frontier),
            policies: f.policies([a.0, b.0]), snapshot: snapshot)
        XCTAssertEqual(try f.index.receipts(named: merged.1.operationID, localReplicaID: f.origin)?.count, 0)
        let next = try f.record(parents: [merged.0], writes: ["body": .text("next")])
        try f.append(next, parent: merged.0)
        XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
    }
    func testLinearRecoveryLeafProofAndMalformedDeltaDoNotInventSnapshotInheritance() throws {
        let f = try Fixture()
        let root = try f.record()
        try f.append(root)
        let snapshot = try f.index.verifiedLinearProjectionSnapshot(row: root.1, revision: root.0)
        XCTAssertEqual(snapshot.analysis.frontier, [root.0.revisionID])
        XCTAssertFalse(snapshot.analysis.needsMaterialization)
        XCTAssertTrue(try f.index.hasCompleteCurrentProjectionCheckpoint())
        var fields = RevisionMerge.semanticFields(root.0)
        fields["body"] = .text("undeclared")
        let wrong = try f.record(parents: [root.0], snapshot: fields)
        code("invalidRevisionGraph") { try f.append(wrong, parent: root.0) }
        XCTAssertNil(try f.index.revision(wrong.0.revisionID))
        XCTAssertFalse(try f.index.hasCompleteCurrentProjectionCheckpoint())
    }

    func testAppendBodyWorkSharesTheExactGuard() throws {
        let f = try Fixture()
        let root = try f.record(writes: ["body": .text("body")])
        try f.append(root)
        let first = try f.record(parents: [root.0], writes: ["subject": .text("first")])
        try f.append(first, parent: root.0)
        let work = f.index.lastCatalogueScanWorkForTesting
        XCTAssertGreaterThan(work, 100)
        let second = try f.record(parents: [first.0], writes: ["subject": .text("other")])
        f.index.graphMaximumVMInstructions = work - 1
        code("resourceLimit") { try f.append(second, parent: first.0) }
        XCTAssertNil(try f.index.revision(second.0.revisionID))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: f.root.appendingPathComponent(second.1.path).path))
    }

    func testResourceRollbackRetainsCanonicalFileAndInvalidatesCurrentProof() throws {
        let f = try Fixture()
        let root = try f.record()
        try f.append(root)
        let next = try f.record(parents: [root.0], writes: ["subject": .text("next")])
        f.index.graphMaximumTemporaryBytes = 1
        code("resourceLimit") { try f.append(next, parent: root.0) }
        XCTAssertNil(try f.index.revision(next.0.revisionID))
        XCTAssertNil(try f.index.currentProjection(itemID: f.itemID))
        XCTAssertFalse(try f.index.acceptedGraphProofIsCurrent())
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(next.1.path).path))
        XCTAssertEqual(try f.index.revisionCount(itemID: f.itemID), 1)
    }
    func testCheckpointResumesBoundProofBeforeFirstAppendAndMutationClearsIt() throws {
        let f = try Fixture()
        let root = try f.record()
        try f.append(root)
        try f.index.sealCatalogue(identity: "fixture")
        let reopened = try ItemIndex(path: f.root.appendingPathComponent("index.sqlite").path, create: false)
        defer { reopened.close() }
        reopened.graphReserveBytes = UInt64(AttachmentFixtureCapacity.reserveBytes)
        let validated = try XCTUnwrap(reopened.validatedCatalogue(identity: "fixture"))
        XCTAssertTrue(try reopened.hasCompleteCurrentProjectionCheckpoint())
        XCTAssertTrue(
            try reopened.resumeAcceptedGraphProofFromCheckpoint(
                validated: validated, requireLinearProjection: false))
        let next = try f.record(parents: [root.0], writes: ["subject": .text("after reopen")])
        try reopened.appendValidatedLocal(
            row: next.1, revision: next.0, parent: root.0,
            expectedRepresentativeID: root.0.revisionID, state: f.ready(next.0),
            policies: f.policies([next.0]))
        XCTAssertEqual(reopened.graphValidationPassesForTesting, 0)
        try reopened.execute("UPDATE revision_catalog SET actor=actor WHERE revision=?", [next.0.revisionID])
        XCTAssertFalse(
            try reopened.resumeAcceptedGraphProofFromCheckpoint(
                validated: validated, requireLinearProjection: false))
    }

    func testReadOnlyIntegrityAuditPreservesAppendProofAndOtherPragmasInvalidate() throws {
        let f = try Fixture()
        let root = try f.record()
        try f.append(root)
        try f.index.sealCatalogue(identity: f.origin)
        let passes = f.index.graphValidationPassesForTesting
        XCTAssertEqual(try f.index.catalogue(identity: f.origin)?.map(\.revisionID), [root.0.revisionID])
        XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        let next = try f.record(parents: [root.0], writes: ["subject": .text("after audit")])
        try f.append(next, parent: root.0)
        XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        XCTAssertEqual(f.index.graphValidationPassesForTesting, passes)
        try f.index.execute("PRAGMA user_version=17")
        XCTAssertFalse(try f.index.acceptedGraphProofIsCurrent())
        try f.index.validateRecoveryGraph(requireLinearProjection: false)
        XCTAssertTrue(try f.index.acceptedGraphProofIsCurrent())
        try f.index.execute("PRAGMA user_version")
        XCTAssertFalse(try f.index.acceptedGraphProofIsCurrent())
        try f.capacity()
    }

    func testRecoveryItemsIncludeForksWithoutCreatingLinearHeads() throws {
        let f = try Fixture()
        let root = try f.record()
        let a = try f.record(parents: [root.0], writes: ["subject": .text("A")])
        let b = try f.record(parents: [root.0], writes: ["subject": .text("B")])
        let otherID = try UUID.makeVersion1().uuidString.lowercased()
        let linear = try f.record(item: otherID)
        for record in [root, a, b, linear] { try f.accept(record) }
        try f.index.validateRecoveryGraph(requireLinearProjection: false)
        let ordered = [f.itemID, otherID].sorted()
        XCTAssertEqual(try f.index.recoveryItem(), ordered[0])
        XCTAssertEqual(try f.index.recoveryItem(after: ordered[0]), ordered[1])
        XCTAssertNil(try f.index.recoveryItem(after: ordered[1]))
        XCTAssertEqual(try f.index.recoveryHead()?.itemID, otherID)
        XCTAssertEqual(try f.index.recoveryHead()?.revisionID, linear.0.revisionID)
        XCTAssertNil(try f.index.recoveryHead(after: otherID))
        try f.capacity()
    }

    func testForgedPolicyAndIncompletePolicyStateCannotGrantDiscovery() throws {
        let f = try Fixture()
        let root = try f.record(writes: ["permissions": permissions(0o600)])
        try f.append(root)
        let snapshot = try f.analyze()
        code("invalidRevisionGraph") {
            try f.index.replaceCurrentProjection(
                snapshot: snapshot, state: f.ready(root.0),
                policies: [
                    .init(
                        revisionID: root.0.revisionID, classID: "Item", permissions: self.permissions(0o604))
                ], policiesComplete: true)
        }
        let state = ItemState(
            itemID: f.itemID, stateToken: "resource", status: .unmaterializable,
            detailsComplete: false,
            resource: .init(code: "resourceLimit", phase: .analysis, message: "bounded"))
        try f.index.replaceCurrentProjection(
            snapshot: nil, state: state, policies: [], policiesComplete: false)
        try f.index.setRequestPrincipals(actorUID: 2, users: ["owner": 1], groups: ["team": (10, false)])
        XCTAssertFalse(try f.index.hasReadableUnresolvedProjection(aclUserID: 2))
        code("projectionRequired") { _ = try f.index.currentPolicyWitnesses(itemID: f.itemID) }
        XCTAssertEqual(try f.number("SELECT COUNT(*) FROM items"), 0)
    }
}
