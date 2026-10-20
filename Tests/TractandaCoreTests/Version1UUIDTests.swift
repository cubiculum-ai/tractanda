import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

@MainActor
final class Version1UUIDTests: XCTestCase {
    private struct OriginalStoreIdentity: Codable {
        let formatVersion: Int
        let storeID: String
    }

    private func seedOriginalStoreIdentity(root: URL) throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let storeID = try UUID.makeVersion1().uuidString.lowercased()
        let identityURL = root.appendingPathComponent(".tractanda-store-identity.json")
        try PrivateConfiguration.write(
            try JSON.encode(OriginalStoreIdentity(formatVersion: 1, storeID: storeID)), to: identityURL)
        XCTAssertEqual(
            try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: tractanda_uid()), storeID)
    }

    private func publishOriginalRecord(_ revision: Revision, root: URL) throws -> (
        directory: URL, file: URL, bytes: Data
    ) {
        let createdAt = try XCTUnwrap(revision.fields["createdAt"]?.dateString)
        let date = try XCTUnwrap(Timestamp.parse(createdAt))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let directory = root.appendingPathComponent(
            String(
                format: "items/%04d/%02d/%02d/%02d/%02d/%@",
                components.year!, components.month!, components.day!, components.hour!, components.minute!,
                revision.itemID))
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var parent = directory
        while parent.path.hasPrefix(root.path + "/") {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            parent.deleteLastPathComponent()
        }
        let file = directory.appendingPathComponent(revision.revisionID + ".tractanda")
        let bytes = try RecordCodec.encode(revision)
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        return (directory, file, bytes)
    }

    func testNodeSelectionPrefersEn0AndRejectsLocalMulticastAndZeroAddresses() async {
        func node(_ name: String, _ value: UInt64, builtIn: Bool = false) -> UUIDHardwareNode {
            UUIDHardwareNode(node: value, interfaceName: name, source: "fixture", isBuiltIn: builtIn)
        }
        let en0 = node("en0", 0x842F_575E_6AC5)
        let builtIn = node("en9", 0x0011_2233_4455, builtIn: true)
        let differentlyNamed = node("enp2s0", 0x0411_2233_4455)
        let localEn0 = node("en0", 0x0211_2233_4455, builtIn: true)
        let multicast = node("en0", 0x0111_2233_4455, builtIn: true)
        let zero = node("en0", 0, builtIn: true)
        XCTAssertEqual(UUIDHardwareNode.select([builtIn, differentlyNamed, en0])?.node, en0.node)
        XCTAssertEqual(
            UUIDHardwareNode.select([localEn0, differentlyNamed, multicast, zero])?.node,
            differentlyNamed.node)
        XCTAssertEqual(UUIDHardwareNode.select([localEn0, differentlyNamed, builtIn])?.node, builtIn.node)
        XCTAssertNil(UUIDHardwareNode.select([localEn0, multicast, zero]))
    }

    func testRFCVectorDecodesTimeClockAndNodeAndRoundTrips() async throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "c232ab00-9414-11ec-b3c8-9f6bdeced846"))
        let fields = try UUIDVersion1Components(uuid)
        XCTAssertEqual(fields.timestamp, 138_648_505_420_000_000)
        XCTAssertEqual(fields.clockSequence, 0x33C8)
        XCTAssertEqual(fields.node, 0x9F6B_DECE_D846)
        XCTAssertEqual(fields.nodeAddress, "9f:6b:de:ce:d8:46")
        XCTAssertTrue(fields.isGeneratedNode)
        XCTAssertEqual(fields.timestampUTC, "2022-02-22T19:22:22.0000000Z")
        XCTAssertEqual(fields.uuid, uuid)
        XCTAssertEqual(uuid.version1Components, fields)
        XCTAssertNil(UUID().version1Components)
    }

    func testIdentifierCollisionCannotReplaceAnExistingItemOrRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trac-uuid-collision-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let first = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "first"))
            .revision
        let state = store.state
        store.makePersistentUUID = { UUID(uuidString: first.itemID)! }
        XCTAssertThrowsError(
            try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "collision"))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "identifierCollision")
        }
        store.makePersistentUUID = { UUID(uuidString: first.revisionID)! }
        XCTAssertThrowsError(
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: first.itemID,
                    expectedRevisionID: first.revisionID, changes: ["subject": .text("Must not replace")],
                    operationID: "revision-collision"))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "identifierCollision")
        }
        XCTAssertEqual(store.state, state)
        XCTAssertEqual(try store.get(first.itemID), first)
        try store.rebuildIndex()
        XCTAssertEqual(try store.history(first.itemID), [first])
    }

    func testLayoutBoundsAndExactSubsecondDates() async throws {
        let maximum = try UUIDVersion1Components(
            timestamp: (1 << 60) - 1, clockSequence: (1 << 14) - 1, node: (1 << 48) - 1)
        XCTAssertEqual(maximum.uuid.uuidString.lowercased(), "ffffffff-ffff-1fff-bfff-ffffffffffff")
        XCTAssertEqual(try UUIDVersion1Components(maximum.uuid), maximum)
        let minimum = try UUIDVersion1Components(timestamp: 0, clockSequence: 0, node: 0)
        XCTAssertEqual(minimum.uuid.uuidString.lowercased(), "00000000-0000-1000-8000-000000000000")
        XCTAssertEqual(minimum.timestampUTC, "1582-10-15T00:00:00.0000000Z")
        let epoch = UUIDVersion1Components.unixEpochOffset
        XCTAssertEqual(
            try UUIDVersion1Components(timestamp: epoch - 1, clockSequence: 0, node: 0).timestampUTC,
            "1969-12-31T23:59:59.9999999Z")
        XCTAssertEqual(
            try UUIDVersion1Components(timestamp: epoch + 1, clockSequence: 0, node: 0).timestampUTC,
            "1970-01-01T00:00:00.0000001Z")
        XCTAssertThrowsError(try UUIDVersion1Components(timestamp: 1 << 60, clockSequence: 0, node: 0))
        XCTAssertThrowsError(try UUIDVersion1Components(timestamp: 0, clockSequence: 1 << 14, node: 0))
        XCTAssertThrowsError(try UUIDVersion1Components(timestamp: 0, clockSequence: 0, node: 1 << 48))
        let wrongVariant = try XCTUnwrap(UUID(uuidString: "ffffffff-ffff-1fff-ffff-ffffffffffff"))
        XCTAssertThrowsError(try UUIDVersion1Components(wrongVariant))
    }

    func testSystemGenerationAndConcurrentCallsStayVersion1AndUnique() async throws {
        let started = Date()
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<1_000 { group.addTask { try UUID.makeVersion1() } }
            var values: [UUID] = []
            for try await value in group { values.append(value) }
            return values
        }
        let finished = Date()
        XCTAssertEqual(Set(ids).count, 1_000)
        let parts = try ids.map(UUIDVersion1Components.init)
        XCTAssertEqual(Set(parts.map(\.node)).count, 1)
        for fields in parts {
            XCTAssertGreaterThanOrEqual(fields.date.timeIntervalSince1970, started.timeIntervalSince1970 - 1)
            XCTAssertLessThanOrEqual(fields.date.timeIntervalSince1970, finished.timeIntervalSince1970 + 1)
        }
        let random = try XCTUnwrap(UUID(uuidString: Identifier.make()))
        XCTAssertNil(random.version1Components, "Nonces and transient identities keep random UUID generation")
        XCTAssertEqual(random.uuidString.split(separator: "-")[2].first, "4")
    }

    func testOriginalFormatVersion1RecordWithVersion1IDsSupportsEditCopyAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trac-uuid-v1-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        try seedOriginalStoreIdentity(root: root)
        let oldItemID = try UUID.makeVersion1().uuidString.lowercased()
        let oldRevisionID = try UUID.makeVersion1().uuidString.lowercased()
        XCTAssertNotNil(UUID(uuidString: oldItemID)?.version1Components)
        XCTAssertNotNil(UUID(uuidString: oldRevisionID)?.version1Components)
        let now = Timestamp.now()
        let intent = CommitRequest(
            classID: "Item", changes: ["subject": .text("Original format 1")],
            operationID: "original-format-v1-fixture")
        let original = try Revision(fields: [
            "itemID": .text(oldItemID), "revisionID": .text(oldRevisionID), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date(now), "modifiedAt": .date(now),
            "subject": .text("Original format 1"), "actor": .text("fixture"),
            "operationID": .text(intent.operationID),
            "requestIdentity": .text(try JSON.encode(intent).base64EncodedString()),
        ])
        XCTAssertEqual(original.formatVersion, 1)
        let published = try publishOriginalRecord(original, root: root)
        var store: ItemStore? = try ItemStore(root: root)
        let edit = CommitRequest(
            action: .revise, itemID: oldItemID, expectedRevisionID: oldRevisionID,
            changes: ["body": .text("Updated")], operationID: "update-original-format-v1")
        let result = try store!.commit(edit)
        XCTAssertEqual(result.revision.itemID, oldItemID)
        XCTAssertEqual(result.revision.supersedes, oldRevisionID)
        XCTAssertNotNil(UUID(uuidString: result.revision.revisionID)?.version1Components)
        XCTAssertEqual(try store!.commit(edit).revision, result.revision)
        let copy = try store!.commit(
            CommitRequest(
                action: .copy, itemID: oldItemID,
                expectedRevisionID: result.revision.revisionID, operationID: "copy-original-format-v1")
        ).revision
        XCTAssertNotNil(UUID(uuidString: copy.itemID)?.version1Components)
        XCTAssertNotNil(UUID(uuidString: copy.revisionID)?.version1Components)
        XCTAssertNotEqual(copy.itemID, copy.revisionID)
        let fresh = try store!.commit(
            CommitRequest(classID: "Item", changes: [:], operationID: "create-v1")
        ).revision
        XCTAssertNotNil(UUID(uuidString: fresh.itemID)?.version1Components)
        XCTAssertNotNil(UUID(uuidString: fresh.revisionID)?.version1Components)
        store = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
        store = try ItemStore(root: root)
        XCTAssertEqual(try store!.get(oldItemID), result.revision)
        XCTAssertEqual(try store!.get(oldItemID, revisionID: oldRevisionID), original)
        XCTAssertEqual(try Data(contentsOf: published.file), published.bytes)
        XCTAssertEqual(try store!.get(copy.itemID), copy)
        XCTAssertEqual(try store!.get(fresh.itemID), fresh)
    }

    func testModernEditRejectsUnmigratedV4ItemWithoutCanonicalMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trac-uuid-v4-edit-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        try seedOriginalStoreIdentity(root: root)
        let oldItemID = Identifier.make()
        let oldRevisionID = Identifier.make()
        XCTAssertNil(UUID(uuidString: oldItemID)?.version1Components)
        XCTAssertNil(UUID(uuidString: oldRevisionID)?.version1Components)
        let now = Timestamp.now()
        let request = CommitRequest(
            classID: "Item", changes: ["subject": .text("Unmigrated v4")],
            operationID: "unmigrated-v4-fixture")
        let original = try Revision(fields: [
            "itemID": .text(oldItemID), "revisionID": .text(oldRevisionID), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date(now), "modifiedAt": .date(now),
            "subject": .text("Unmigrated v4"), "actor": .text("fixture"),
            "operationID": .text(request.operationID),
            "requestIdentity": .text(try JSON.encode(request).base64EncodedString()),
        ])
        let published = try publishOriginalRecord(original, root: root)
        let store = try ItemStore(root: root)
        XCTAssertEqual(try store.get(oldItemID), original)
        XCTAssertEqual(try store.history(oldItemID), [original])

        let edit = CommitRequest(
            action: .revise, itemID: oldItemID, expectedRevisionID: oldRevisionID,
            changes: ["body": .text("Must not publish")], operationID: "reject-unmigrated-v4-edit")
        XCTAssertThrowsError(try store.commit(edit)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidRevisionAncestry")
        }
        XCTAssertEqual(try store.get(oldItemID), original)
        XCTAssertEqual(try store.history(oldItemID), [original])
        XCTAssertEqual(try Data(contentsOf: published.file), published.bytes)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: published.directory.path),
            [oldRevisionID + ".tractanda"])
    }
}
