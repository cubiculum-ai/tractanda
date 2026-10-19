import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class CanonicalCompatibilityTests: XCTestCase {
    private func root() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        let root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
            "tractanda-reader-" + Identifier.make())
        do { _ = try ItemStore(root: root) }
        return root
    }
    private func record(_ root: URL, format: Int) throws -> (URL, Data) {
        try AttachmentFixtureCapacity.requireFree()
        let item = try UUID.makeVersion1().uuidString.lowercased()
        let id = try UUID.makeVersion1().uuidString.lowercased()
        var fields: [String: ItemValue] = [
            "itemID": .text(item), "revisionID": .text(id), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date("2026-10-13T12:00:00Z"),
            "modifiedAt": .date("2026-10-13T12:00:00Z"), "actor": .text("uid:\(tractanda_uid())"),
            "operationID": .text(id), "requestIdentity": .text("fixture"), "subject": .text("retained"),
        ]
        if format == 2 {
            fields["revisionAncestry"] = try RevisionProvenance(
                kind: .authored, originReplicaID: UUID.makeVersion1().uuidString.lowercased(), parents: [],
                writtenFields: ["classID", "schemaVersion", "subject"], unsetFields: [], frontier: []
            ).itemValue
        }
        let bytes = try RecordCodec.encode(Revision(fields: fields, formatVersion: format))
        XCTAssertLessThan(bytes.count, 4096)
        let directory = root.appendingPathComponent("items/2026/10/13/12/00/" + item)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(id + ".tractanda")
        try bytes.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        return (path, bytes)
    }
    func testLegacyReadDoesNotCreateMarkerAndDurablePublicationRaisesMonotonically() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
        let initial = try CanonicalReaderRequirement.withWriterLock(root: root, ownerUID: tractanda_uid()) {
            try CanonicalReaderRequirement.admitQuiescent(root: root, ownerUID: tractanda_uid())
        }
        XCTAssertEqual(initial.minimumReaderLevel, 1)
        XCTAssertNoThrow(try CanonicalFormatSupport.legacy.require(initial))
        let store = try ItemStore(root: root)
        let revision = try store.commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("new")], operationID: "format2")
        ).revision
        XCTAssertEqual(revision.formatVersion, 2)
        let raised = try XCTUnwrap(CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
        XCTAssertEqual(raised.minimumReaderLevel, 2)
        XCTAssertThrowsError(try CanonicalFormatSupport.legacy.require(raised))
        let repeated = try CanonicalReaderRequirement.admitQuiescent(root: root, ownerUID: tractanda_uid())
        XCTAssertEqual(repeated, raised)
        XCTAssertEqual(
            try FileMetadata.read(at: root.appendingPathComponent(CanonicalReaderRequirement.fileName)).mode
                & 0o777, 0o600)
    }
    func testMarkerFailureBlocksTheFirstFormat2RecordAndRetryPreservesTheRecord() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        store.beforeCanonicalReaderRequirementForTesting = {
            throw TractandaError("injectedMarkerFailure", "Stopped before durable reader raise")
        }
        let request = CommitRequest(
            classID: "Item", changes: ["subject": .text("content")], operationID: "first2")
        XCTAssertThrowsError(try store.commit(request))
        XCTAssertNil(try CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
        XCTAssertEqual(try store.exportCatalogueForVerification().count, 0)
        store.beforeCanonicalReaderRequirementForTesting = nil
        let revision = try store.commit(request).revision
        XCTAssertEqual(
            try CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid())?.minimumReaderLevel, 2)
        let rows = try store.exportCatalogueForVerification()
        let path = root.appendingPathComponent(try XCTUnwrap(rows.first).path)
        let original = try Data(contentsOf: path)
        try store.rebuildIndex()
        XCTAssertEqual(try store.get(revision.itemID), revision)
        XCTAssertEqual(try Data(contentsOf: path), original)
    }
    func testMissingProofInventoriesActualVersionsWithoutRewritingAnyOriginal() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try record(root, format: 1)
        let new = try record(root, format: 2)
        let required = try CanonicalReaderRequirement.withWriterLock(root: root, ownerUID: tractanda_uid()) {
            try CanonicalReaderRequirement.admitQuiescent(root: root, ownerUID: tractanda_uid())
        }
        XCTAssertEqual(required.recordFormats, [1, 2])
        XCTAssertEqual(required.minimumReaderLevel, 2)
        XCTAssertNoThrow(try CanonicalFormatSupport.current.require(required))
        XCTAssertThrowsError(try CanonicalFormatSupport.legacy.require(required))
        XCTAssertEqual(try Data(contentsOf: old.0), old.1)
        XCTAssertEqual(try Data(contentsOf: new.0), new.1)
    }
    func testUnknownAndCrossStoreProofFailClosed() throws {
        let a = try root()
        let b = try root()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let marker = try CanonicalReaderRequirement.withWriterLock(root: a, ownerUID: tractanda_uid()) {
            try CanonicalReaderRequirement.admitQuiescent(root: a, ownerUID: tractanda_uid())
        }
        let target = b.appendingPathComponent(CanonicalReaderRequirement.fileName)
        try JSON.encode(marker).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        XCTAssertThrowsError(try CanonicalReaderRequirement.load(root: b, ownerUID: tractanda_uid()))
        XCTAssertThrowsError(try ItemStore(root: b))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(marker)) as? [String: Any])
        object["unknownControlMeaning"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: target)
        XCTAssertThrowsError(try CanonicalReaderRequirement.load(root: b, ownerUID: tractanda_uid()))
    }
    func testRunningWriterFutureLevelBlocksSharedLegacyClientAndAuthorityNeedsANewLevel() throws {
        XCTAssertThrowsError(try CanonicalFormatSupport.legacy.requireWriter(.current))
        XCTAssertNoThrow(try CanonicalFormatSupport.current.requireWriter(.legacy))
        let id = try UUID.makeVersion1().uuidString.lowercased()
        let authority = CanonicalReaderRequirement(
            storeID: id, minimumReaderLevel: 3, recordFormats: [1, 2],
            capabilities: ["tractanda.authority.v1"])
        XCTAssertNoThrow(try CanonicalFormatSupport.current.require(authority))
        let oldReader = CanonicalFormatSupport(readerLevel: 2, writerLevel: 2, read: [1, 2], write: [2])
        XCTAssertThrowsError(try oldReader.require(authority))
        var support = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSON.encode(CanonicalFormatSupport.current)) as? [String: Any])
        support["unknownMeaning"] = true
        XCTAssertThrowsError(
            try JSON.decode(CanonicalFormatSupport.self, JSONSerialization.data(withJSONObject: support)))
    }
    func testQuiescentLockAndInventoryBoundsCannotBeBypassed() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try ItemStore(root: root)
            XCTAssertThrowsError(
                try CanonicalReaderRequirement.withWriterLock(root: root, ownerUID: tractanda_uid()) { () })
            XCTAssertNil(store.replicaID)
        }
        _ = try record(root, format: 1)
        _ = try record(root, format: 1)
        XCTAssertThrowsError(
            try CanonicalReaderRequirement.withWriterLock(root: root, ownerUID: tractanda_uid()) {
                try CanonicalReaderRequirement.admitQuiescent(
                    root: root, ownerUID: tractanda_uid(), maximumRecords: 1)
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
        XCTAssertNil(try CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
    }
}
