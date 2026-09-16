import Foundation
import XCTest

@testable import TractandaCore

@MainActor
final class Version1UUIDTests: XCTestCase {
    func testNodeSelectionPrefersEn0AndRejectsLocalMulticastAndZeroAddresses() {
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

    func testRFCVectorDecodesTimeClockAndNodeAndRoundTrips() throws {
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

    func testIdentifierCollisionCannotReplaceAnExistingItemOrRevision() throws {
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

    func testLayoutBoundsAndExactSubsecondDates() throws {
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

    func testStoreCreatesVersion1AndKeepsLegacyIdentityThroughEditAndRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "trac-uuid-v1-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let itemDirectory = root.appendingPathComponent("items")
        try FileManager.default.createDirectory(
            at: itemDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let oldItemID = Identifier.make()
        let oldRevisionID = Identifier.make()
        let now = Timestamp.now()
        let intent = CommitRequest(
            classID: "Item", changes: ["subject": .text("Legacy v4")], operationID: "legacy-v4-fixture")
        let legacy = try Revision(fields: [
            "itemID": .text(oldItemID), "revisionID": .text(oldRevisionID), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date(now), "modifiedAt": .date(now),
            "subject": .text("Legacy v4"), "actor": .text("legacy"), "operationID": .text(intent.operationID),
            "requestIdentity": .text(try JSON.encode(intent).base64EncodedString()),
        ])
        let file = itemDirectory.appendingPathComponent(oldRevisionID + ".tractanda")
        let originalBytes = try RecordCodec.encode(legacy)
        try originalBytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        var store: ItemStore? = try ItemStore(root: root)
        let edit = CommitRequest(
            action: .revise, itemID: oldItemID, expectedRevisionID: oldRevisionID,
            changes: ["body": .text("Updated")], operationID: "update-legacy")
        let result = try store!.commit(edit)
        XCTAssertEqual(result.revision.itemID, oldItemID)
        XCTAssertEqual(result.revision.supersedes, oldRevisionID)
        XCTAssertNotNil(UUID(uuidString: result.revision.revisionID)?.version1Components)
        XCTAssertEqual(try store!.commit(edit).revision, result.revision)
        let copy = try store!.commit(
            CommitRequest(
                action: .copy, itemID: oldItemID,
                expectedRevisionID: result.revision.revisionID, operationID: "copy-legacy")
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
        XCTAssertEqual(try store!.get(oldItemID, revisionID: oldRevisionID), legacy)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        XCTAssertEqual(try store!.get(copy.itemID), copy)
        XCTAssertEqual(try store!.get(fresh.itemID), fresh)
    }
}
