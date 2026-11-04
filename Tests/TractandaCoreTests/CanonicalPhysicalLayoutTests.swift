import CTractandaPlatform
import TractandaClient
import XCTest

@testable import TractandaCore

final class CanonicalPhysicalLayoutTests: XCTestCase {
    func testOnlyFlatCanonicalItemPathsCarryBothIdentities() throws {
        let item = Identifier.make()
        let revision = Identifier.make()
        let valid = "items/2026/11/03/15/42/\(item).\(revision).tractanda"
        XCTAssertTrue(CanonicalRecordPath.validate(valid, itemID: item, revisionID: revision))
        let identities = try XCTUnwrap(CanonicalRecordPath.identities(valid))
        XCTAssertEqual(identities.itemID, item)
        XCTAssertEqual(identities.revisionID, revision)
        for invalid in [
            "items/2026/11/03/15/42/\(item)/\(revision).tractanda",
            "items/2026/11/03/15/42/\(revision).tractanda",
            "items/2026/02/30/15/42/\(item).\(revision).tractanda",
            "items/2026/11/03/15/42/\(item).\(revision).tractanda/extra",
            "items//2026/11/03/15/42/\(item).\(revision).tractanda",
        ] {
            XCTAssertFalse(CanonicalRecordPath.validate(invalid, itemID: item, revisionID: revision))
            XCTAssertNil(CanonicalRecordPath.identities(invalid))
        }
        XCTAssertFalse(CanonicalRecordPath.validate(valid, itemID: revision, revisionID: item))
        XCTAssertTrue(CanonicalVerifier.isLegalStagingName("\(item).\(revision).tractanda.Abc123"))
        XCTAssertFalse(CanonicalVerifier.isLegalStagingName("\(revision).tractanda.Abc123"))
    }

    func testFreshMarkerRestartCompletesInterruptedConstantWritesAndAtomicPublication() throws {
        try AttachmentFixtureCapacity.requireFree()
        let expected = try JSON.encode([
            "profile": "tractanda.physical-layout.v1", "layout": "flat-items-visible-attachments.v1",
            "recordEncoding": "message-v1",
        ])
        for length in [0, 1, expected.count / 2, expected.count - 1, expected.count] {
            let root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
                "tractanda-initial-marker-" + Identifier.make())
            try PrivateConfiguration.makeDirectory(root)
            defer { try? FileManager.default.removeItem(at: root) }
            let writer = tractanda_lock(root.appendingPathComponent(".writer.lock").path)
            XCTAssertGreaterThanOrEqual(writer, 0)
            defer { tractanda_unlock(writer) }
            let stage = root.appendingPathComponent(".physical-layout-" + Identifier.make() + ".stage")
            try Data(expected.prefix(length)).write(to: stage)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.path)
            // Represents process death after any prefix write or after completed fsync.
            try CanonicalPhysicalLayout.prepareOpening(root, ownerUID: tractanda_uid())
            let marker = root.appendingPathComponent(CanonicalPhysicalLayout.fileName)
            XCTAssertEqual(try Data(contentsOf: marker), expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
            XCTAssertEqual(try FileMetadata.read(at: marker).mode & 0o777, 0o600)
            // Represents process death after the exclusive rename and before acknowledgement.
            try CanonicalPhysicalLayout.prepareOpening(root, ownerUID: tractanda_uid())
            XCTAssertEqual(try Data(contentsOf: marker), expected)
        }
    }

    func testFreshMarkerRecoveryPreservesUnknownOrUnsafeStages() throws {
        try AttachmentFixtureCapacity.requireFree()
        for kind in ["unknownBytes", "wrongMode", "unknownName", "otherContent", "hardLink"] {
            let root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
                "tractanda-refused-marker-" + Identifier.make())
            try PrivateConfiguration.makeDirectory(root)
            defer { try? FileManager.default.removeItem(at: root) }
            let writer = tractanda_lock(root.appendingPathComponent(".writer.lock").path)
            XCTAssertGreaterThanOrEqual(writer, 0)
            defer { tractanda_unlock(writer) }
            let name =
                kind == "unknownName"
                ? ".physical-layout-unknown.stage"
                : ".physical-layout-" + Identifier.make() + ".stage"
            let stage = root.appendingPathComponent(name)
            let bytes = Data((kind == "unknownBytes" ? "unexpected" : "{").utf8)
            try bytes.write(to: stage)
            try FileManager.default.setAttributes(
                [.posixPermissions: kind == "wrongMode" ? 0o644 : 0o600],
                ofItemAtPath: stage.path)
            if kind == "otherContent" {
                try Data("retained".utf8).write(to: root.appendingPathComponent("retained"))
            }
            if kind == "hardLink" {
                try FileManager.default.linkItem(at: stage, to: root.appendingPathComponent("other-link"))
            }
            XCTAssertThrowsError(try CanonicalPhysicalLayout.prepareOpening(root, ownerUID: tractanda_uid()))
            XCTAssertEqual(try Data(contentsOf: stage), bytes)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(CanonicalPhysicalLayout.fileName).path))
        }
    }

    func testMissingMarkerAndInterruptedMigrationRejectBeforeRebuildingExistingStore() throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
            "tractanda-layout-guard-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let revision = try store!.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("retained")], operationID: "retained")
        ).revision
        let row = try XCTUnwrap(store!.exportCatalogueForVerification().first)
        let bytes = try Data(contentsOf: root.appendingPathComponent(row.path))
        let marker = root.appendingPathComponent(CanonicalPhysicalLayout.fileName)
        let markerBytes = try Data(contentsOf: marker)
        let oldReader = CanonicalFormatSupport(
            readerLevel: 18, writerLevel: 18, read: [1, 2], write: [2],
            capabilities: CanonicalFormatSupport.current.capabilities.filter {
                $0 != CanonicalPhysicalLayout.capability && $0 != MessageRecordCodec.capability
            },
            writeCapabilities: CanonicalFormatSupport.current.writeCapabilities.filter {
                $0 != CanonicalPhysicalLayout.capability && $0 != MessageRecordCodec.capability
            })
        let fence = try XCTUnwrap(CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
        XCTAssertEqual(fence.minimumReaderLevel, 20)
        XCTAssertThrowsError(try oldReader.require(fence))
        store = nil
        try FileManager.default.removeItem(at: marker)
        XCTAssertThrowsError(try ItemStore(root: root)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "canonicalLayoutMigrationRequired")
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(row.path)), bytes)
        let layoutOnly = try JSON.encode([
            "profile": "tractanda.physical-layout.v1", "layout": "flat-items-visible-attachments.v1",
        ])
        try PrivateConfiguration.write(layoutOnly, to: marker)
        XCTAssertThrowsError(try ItemStore(root: root)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "canonicalLayoutMigrationRequired")
        }
        try PrivateConfiguration.write(markerBytes, to: marker)
        try Data("{}".utf8).write(to: root.appendingPathComponent(CanonicalPhysicalLayout.pendingFileName))
        XCTAssertThrowsError(try ItemStore(root: root)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "canonicalLayoutMigrationRequired")
        }
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(CanonicalPhysicalLayout.pendingFileName))
        store = try ItemStore(root: root)
        XCTAssertEqual(try store!.get(revision.itemID), revision)
        store = nil
    }

    func testPublicationReopenHistoryAndIndexLossUseFlatPathsWithoutChangingBytes() throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
            "tractanda-physical-layout-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let first = try XCTUnwrap(store).commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("layout needle")], operationID: "first")
        ).revision
        let second = try XCTUnwrap(store).commit(
            CommitRequest(
                action: .revise, itemID: first.itemID, expectedRevisionID: first.revisionID,
                changes: ["body": .text("preserved")], operationID: "second")
        ).revision
        let rows = try XCTUnwrap(store).exportCatalogueForVerification()
        XCTAssertEqual(rows.count, 2)
        var originalBytes: [String: Data] = [:]
        for row in rows {
            XCTAssertTrue(
                CanonicalRecordPath.validate(row.path, itemID: row.itemID, revisionID: row.revisionID))
            XCTAssertEqual(row.path.split(separator: "/").count, 7)
            let bytes = try Data(contentsOf: root.appendingPathComponent(row.path))
            XCTAssertTrue(
                String(decoding: bytes, as: UTF8.self).contains("X-Tractanda-Encoding: message-v1\r\n"))
            originalBytes[row.path] = bytes
        }
        store = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
        store = try ItemStore(root: root)
        XCTAssertEqual(try store!.get(first.itemID), second)
        XCTAssertEqual(try store!.get(first.itemID, revisionID: first.revisionID), first)
        XCTAssertEqual(try store!.history(first.itemID).count, 2)
        XCTAssertEqual(try Categories.query(store: store!, text: "needle").first?.itemID, first.itemID)
        for (path, bytes) in originalBytes {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    root.appendingPathComponent(rows[0].path).deletingLastPathComponent()
                    .appendingPathComponent(first.itemID).path))
        store = nil
    }
}
