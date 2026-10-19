import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class RevisionProvenanceIntegrationTests: XCTestCase {
    private func root() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-provenance-" + Identifier.make())
    }

    private func legacyFixture(_ root: URL) throws -> (Revision, Revision, [URL: Data]) {
        do { _ = try ItemStore(root: root) }
        let item = try UUID.makeVersion1().uuidString.lowercased()
        let firstID = try UUID.makeVersion1().uuidString.lowercased()
        let secondID = try UUID.makeVersion1().uuidString.lowercased()
        var fields: [String: ItemValue] = [
            "itemID": .text(item), "revisionID": .text(firstID), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date("2020-01-02T03:04:00.000Z"),
            "modifiedAt": .date("2020-01-02T03:04:00.000Z"), "actor": .text("uid:\(tractanda_uid())"),
            "operationID": .text("legacy-create"),
            "requestIdentity": .text(
                try JSON.encode(
                    CommitRequest(
                        classID: "Item", changes: ["subject": .text("first")], operationID: "legacy-create")
                ).base64EncodedString()),
            "subject": .text("first"),
        ]
        let first = try Revision(fields: fields)
        fields["revisionID"] = .text(secondID)
        fields["supersedes"] = .text(firstID)
        fields["modifiedAt"] = .date("2020-01-02T03:05:00.000Z")
        fields["operationID"] = .text("legacy-revise")
        fields["subject"] = .text("second")
        let second = try Revision(fields: fields)
        var originals: [URL: Data] = [:]
        for (revision, minute) in [(first, "04"), (second, "05")] {
            let folder = root.appendingPathComponent("items/2020/01/02/03/\(minute)/\(item)")
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = folder.appendingPathComponent(revision.revisionID + ".tractanda")
            let bytes = try RecordCodec.encode(revision)
            try bytes.write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
            originals[path] = bytes
        }
        try StoreCheckpoint.markDirty(root: root)
        return (first, second, originals)
    }

    func testLegacyReadDoesNotAllocateIdentityAndNewCommitPreservesOriginalBytes() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (first, second, originals) = try legacyFixture(root)
        let store = try ItemStore(root: root)
        XCTAssertNil(store.replicaID)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(ReplicaIdentity.name).path))
        XCTAssertEqual(try store.get(first.itemID), second)
        XCTAssertEqual(
            try store.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("first")], operationID: "legacy-create")
            ).revision, first)
        XCTAssertNil(store.replicaID, "Legacy receipt replay allocates no new origin")
        let revision = try store.commit(
            CommitRequest(
                action: .revise, itemID: first.itemID, expectedRevisionID: second.revisionID,
                changes: ["body": .text("modern")], operationID: "modern-revise")
        ).revision
        XCTAssertEqual(try revision.provenance?.originReplicaID, store.replicaID)
        XCTAssertEqual(try revision.provenance?.writtenFields, ["body"])
        try store.rebuildIndex()
        for (path, bytes) in originals { XCTAssertEqual(try Data(contentsOf: path), bytes) }
        XCTAssertEqual(try store.history(first.itemID).count, 3)
    }

    func testModernWritesNoOpsUnsetsCopyReplayAndMetadataExclusion() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let request = CommitRequest(
            classID: "Item", changes: ["subject": .text("note"), "body": .text("prose")],
            operationID: "create")
        let original = try store.commit(request).revision
        let origin = try XCTUnwrap(original.provenance)
        XCTAssertEqual(original.formatVersion, 2)
        XCTAssertEqual(Set(origin.writtenFields), Set(RevisionMerge.semanticFields(original).keys))
        XCTAssertEqual(origin.parents, [])
        let revised = try store.commit(
            CommitRequest(
                action: .revise, itemID: original.itemID, expectedRevisionID: original.revisionID,
                changes: ["body": .text("prose")], unset: ["absent"], operationID: "same-value")
        ).revision
        XCTAssertEqual(try revised.provenance?.writtenFields, ["body"])
        XCTAssertEqual(try revised.provenance?.unsetFields, ["absent"])
        XCTAssertEqual(
            try RevisionMerge.node(revised).kind.writes, ["body": .set(.text("prose")), "absent": .unset])
        let copy = try store.commit(
            CommitRequest(
                action: .copy, itemID: original.itemID, expectedRevisionID: revised.revisionID,
                operationID: "copy")
        ).revision
        XCTAssertEqual(try copy.provenance?.parents, [])
        XCTAssertEqual(try copy.provenance?.originReplicaID, origin.originReplicaID)
        XCTAssertTrue(try store.candidates(text: RevisionProvenance.profile).isEmpty)
        XCTAssertEqual(try store.commit(request).revision, original)
        XCTAssertThrowsError(
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: original.itemID, expectedRevisionID: revised.revisionID,
                    changes: ["revisionAncestry": .text("forged")], operationID: "forge")))
    }

    func testModernMissingIdentityFailsClosedAndRestoredIdentityPersists() throws {
        let root = try root()
        let restore = try self.root()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: restore)
        }
        let originalID: String
        do {
            let store = try ItemStore(root: root)
            _ = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "create"))
            originalID = try XCTUnwrap(store.replicaID)
        }
        try FileManager.default.copyItem(at: root, to: restore)
        do { XCTAssertEqual(try ItemStore(root: restore).replicaID, originalID) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(ReplicaIdentity.name))
        XCTAssertThrowsError(try ItemStore(root: root)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "missingReplicaIdentity")
        }
    }

    func testExplicitCloneGetsNewIdentityWithoutChangingOriginalOrigins() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let original: Revision
        let storeID: String
        let identity: String
        do {
            let store = try ItemStore(root: root)
            original = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "create"))
                .revision
            identity = try XCTUnwrap(store.replicaID)
            let record = try JSON.decode(
                ReplicaIdentity.Record.self,
                Data(contentsOf: root.appendingPathComponent(ReplicaIdentity.name)))
            storeID = record.storeID
        }
        let lock = tractanda_lock(root.appendingPathComponent(".writer.lock").path)
        XCTAssertGreaterThanOrEqual(lock, 0)
        let fresh: ReplicaIdentity.Record
        do {
            defer { _ = tractanda_unlock(lock) }
            fresh = try ReplicaIdentity.replaceForExplicitClone(
                root: root, storeID: storeID, ownerUID: tractanda_uid())
        }
        XCTAssertNotEqual(fresh.replicaID, identity)
        let reopened = try ItemStore(root: root)
        XCTAssertEqual(reopened.replicaID, fresh.replicaID)
        XCTAssertEqual(try reopened.get(original.itemID), original)
        let next = try reopened.commit(
            CommitRequest(
                action: .revise, itemID: original.itemID, expectedRevisionID: original.revisionID,
                changes: ["subject": .text("clone")], operationID: "clone-revise")
        ).revision
        XCTAssertEqual(try next.provenance?.originReplicaID, fresh.replicaID)
    }

    func testCrossMinuteHistoricalPooledPathUsesActualPublicationFolder() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (first, second, _) = try legacyFixture(root)
        let store = try ItemStore(root: root)
        let row = try XCTUnwrap(
            store.exportCatalogueForVerification().first { $0.revisionID == second.revisionID })
        XCTAssertTrue(row.path.contains("/03/05/"))
        XCTAssertEqual(
            try PooledCanonicalRecord.read(row: row, root: store.root, ownerUID: store.ownerUID).revision,
            second)
        XCTAssertEqual(try store.get(first.itemID, revisionID: first.revisionID), first)
        for bad in [
            "items/2020/02/30/03/05/\(first.itemID)/\(second.revisionID).tractanda",
            "items//2020/01/02/03/05/\(first.itemID)/\(second.revisionID).tractanda",
        ] {
            XCTAssertFalse(
                CanonicalRecordPath.validate(bad, itemID: first.itemID, revisionID: second.revisionID))
        }
    }

    func testPortableMetadataRejectsUnknownUnsortedAndSnapshotMismatches() throws {
        let origin = try UUID.makeVersion1().uuidString.lowercased()
        let a = try UUID.makeVersion1().uuidString.lowercased()
        let b = try UUID.makeVersion1().uuidString.lowercased()
        XCTAssertThrowsError(
            try RevisionProvenance(
                kind: .authored, originReplicaID: origin, parents: [a, b], writtenFields: [], unsetFields: [],
                frontier: []))
        XCTAssertThrowsError(
            try RevisionProvenance(
                kind: .authored, originReplicaID: origin, parents: [], writtenFields: ["revisionAncestry"],
                unsetFields: [], frontier: []))
        let valid = try RevisionProvenance(
            kind: .authored, originReplicaID: origin, parents: [a], writtenFields: ["body"], unsetFields: [],
            frontier: [])
        var fields: [String: ItemValue] = [
            "itemID": .text(origin), "revisionID": .text(b), "supersedes": .text(a),
        ]
        XCTAssertThrowsError(try valid.validate(in: fields))
        fields["body"] = .text("value")
        XCTAssertNoThrow(try valid.validate(in: fields))
        XCTAssertEqual(try RevisionProvenance(value: valid.itemValue), valid)
    }

    func testReplicaIdentityRejectsOversizedOrLinkedPrivateFiles() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try ItemStore(root: root) }
        let name = root.appendingPathComponent(ReplicaIdentity.name)
        try Data(repeating: 0, count: 4097).write(to: name)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: name.path)
        XCTAssertThrowsError(
            try ReplicaIdentity.load(root: root, storeID: "unused", ownerUID: tractanda_uid()))
        try FileManager.default.removeItem(at: name)
        let target = root.appendingPathComponent("private-target")
        try Data("private".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: name, withDestinationURL: target)
        XCTAssertThrowsError(
            try ReplicaIdentity.load(root: root, storeID: "unused", ownerUID: tractanda_uid()))
    }

    func testLegacyCheckpointOpenWithNonWritableRootDoesNotCreateReplicaIdentity() throws {
        let root = try root()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let (_, second, _) = try legacyFixture(root)
        do { _ = try ItemStore(root: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let reader = try ItemStore(root: root)
        XCTAssertEqual(try reader.get(second.itemID), second)
        XCTAssertNil(reader.replicaID)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(ReplicaIdentity.name).path))
    }
}
