import Crypto
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PayloadPlacementTests: XCTestCase {
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }

    private func fixture() throws -> (URL, AttachmentPayloadStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-payload-placement-\(Identifier.make())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let store = try AttachmentPayloadStore(
            root: root, ownerUID: UInt32(getuid()), reserveBytes: 0, availableBytes: { .max },
            maxFileBytesForTesting: 256, maxChunkBytesForTesting: 8)
        return (root, store)
    }

    private func identifier(_ offset: UInt64 = 0) throws -> String {
        let original = try XCTUnwrap(UUID.makeVersion1().version1Components)
        return try UUIDVersion1Components(
            timestamp: original.timestamp + offset, clockSequence: original.clockSequence,
            node: original.node
        ).uuid.uuidString.lowercased()
    }

    private func descriptor(id: String, bytes: Data) throws -> AttachmentDescriptor {
        try AttachmentDescriptor(
            attachmentID: id, filename: "opaque.bin", mediaType: "application/octet-stream",
            byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    private func privateDirectory(root: URL, components: [String], leafMode: Int = 0o700) throws -> URL {
        var directory = root
        for (index, component) in components.enumerated() {
            directory.appendPathComponent(component, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let mode = index == components.count - 1 ? leafMode : 0o700
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
        }
        return directory
    }

    private func stage(_ bytes: Data, id: String, in store: AttachmentPayloadStore) throws
        -> AttachmentDescriptor
    {
        try store.createStaging(id: id)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 8, bytes.count)
            _ = try store.append(id: id, offset: Int64(offset), data: bytes.subdata(in: offset..<end))
            offset = end
        }
        return try descriptor(id: id, bytes: bytes)
    }

    func testUUIDTimeDoesNotChooseLocalArrivalShard() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.placementArrivalMinuteForTesting = { "2026/10/16/01/00" }
        let current = try XCTUnwrap(UUID.makeVersion1().version1Components)
        let historical = try UUIDVersion1Components(
            timestamp: current.timestamp - 10 * 365 * 24 * 60 * 60 * 10_000_000,
            clockSequence: current.clockSequence, node: current.node
        ).uuid.uuidString.lowercased()
        let future = try UUIDVersion1Components(
            timestamp: current.timestamp + 10 * 365 * 24 * 60 * 60 * 10_000_000,
            clockSequence: current.clockSequence, node: current.node
        ).uuid.uuidString.lowercased()
        let oldBytes = Data("old identity bytes".utf8)
        let futureBytes = Data("future identity bytes".utf8)
        let old = try stage(oldBytes, id: historical, in: store)
        let next = try stage(futureBytes, id: future, in: store)
        try store.publish(descriptor: old)
        try store.publish(descriptor: next)
        let shard = "attachments/payloads/2026/10/16/01/00"
        XCTAssertEqual(try store.resolvedPayloadPath(historical), "\(shard)/\(historical).payload")
        XCTAssertEqual(try store.resolvedPayloadPath(future), "\(shard)/\(future).payload")
        XCTAssertEqual(try Data(contentsOf: store.payloadURL(for: historical)), oldBytes)
        XCTAssertEqual(try Data(contentsOf: store.payloadURL(for: future)), futureBytes)
    }

    func testInterruptedIntentMovesOnFromUnwritablePriorPeriod() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try identifier()
        let bytes = Data("late original".utf8)
        let attachment = try stage(bytes, id: id, in: store)
        let firstMinute = "2026/10/15/22/10"
        let secondMinute = "2026/10/16/01/10"
        let oldDirectory = try privateDirectory(
            root: root, components: ["attachments", "payloads", "2026", "10", "15", "22", "10"],
            leafMode: 0o500)
        store.placementArrivalMinuteForTesting = { firstMinute }
        store.afterPlacementIntentForTesting = { throw TractandaError("interrupted", "simulated") }
        XCTAssertThrowsError(try store.publish(descriptor: attachment))
        store.afterPlacementIntentForTesting = nil
        store.placementArrivalMinuteForTesting = { secondMinute }
        try store.publish(descriptor: attachment)
        XCTAssertEqual(
            try store.resolvedPayloadPath(id),
            "attachments/payloads/\(secondMinute)/\(id).payload")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldDirectory.appendingPathComponent("\(id).payload").path))
        XCTAssertEqual(try Data(contentsOf: store.payloadURL(for: id)), bytes)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: oldDirectory.path)[.posixPermissions]
                as? NSNumber, 0o500 as NSNumber)
    }

    func testPublishedOrphanSurvivesInterruptedIndexingAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-payload-orphan-\(Identifier.make())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try identifier()
        let bytes = Data("published before crash".utf8)
        let attachment = try descriptor(id: id, bytes: bytes)
        do {
            let store = try AttachmentPayloadStore(
                root: root, ownerUID: UInt32(getuid()), reserveBytes: 0, availableBytes: { .max })
            store.placementArrivalMinuteForTesting = { "2026/10/16/01/20" }
            try store.createStaging(id: id)
            _ = try store.append(id: id, offset: 0, data: bytes)
            store.afterPlacementFileForTesting = { throw TractandaError("interrupted", "simulated") }
            XCTAssertThrowsError(try store.publish(descriptor: attachment))
        }
        let reopened = try AttachmentPayloadStore(
            root: root, ownerUID: UInt32(getuid()), reserveBytes: 0, availableBytes: { .max })
        XCTAssertEqual(
            try reopened.resolvedPayloadPath(id), "attachments/payloads/2026/10/16/01/20/\(id).payload")
        XCTAssertEqual(try reopened.read(descriptor: attachment, offset: 0, limit: 64), bytes)
    }

    func testValidIndexLookupAndRepeatedReadAvoidArchiveScanAndDigestPass() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.placementArrivalMinuteForTesting = { "2026/10/16/01/30" }
        let id = try identifier()
        let bytes = Data("small verified bytes".utf8)
        let attachment = try stage(bytes, id: id, in: store)
        try store.publish(descriptor: attachment)
        let scans = store.placementRecoveryScansForTesting
        let hashes = store.digestPassCountForTesting
        for _ in 0..<4 {
            XCTAssertEqual(
                try store.resolvedPayloadPath(id), "attachments/payloads/2026/10/16/01/30/\(id).payload")
            XCTAssertEqual(try store.read(descriptor: attachment, offset: 0, limit: 8), bytes.prefix(8))
        }
        XCTAssertEqual(store.placementRecoveryScansForTesting, scans)
        XCTAssertEqual(store.digestPassCountForTesting, hashes)
    }

    func testDeletedDisposableIndexRebuildsAfterPreviousOwnerCloses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-payload-index-rebuild-\(Identifier.make())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        var store: AttachmentPayloadStore? = try AttachmentPayloadStore(
            root: root, ownerUID: UInt32(getuid()), reserveBytes: 0, availableBytes: { .max },
            maxFileBytesForTesting: 256, maxChunkBytesForTesting: 8)
        let id = try identifier()
        let bytes = Data("index reconstruction".utf8)
        let attachment = try stage(bytes, id: id, in: try XCTUnwrap(store))
        try XCTUnwrap(store).publish(descriptor: attachment)
        store = nil
        for name in ["payloads.sqlite", "payloads.sqlite-journal"] {
            let indexFile = root.appendingPathComponent("index/\(name)")
            if FileManager.default.fileExists(atPath: indexFile.path) {
                try FileManager.default.removeItem(at: indexFile)
            }
        }
        let reopened = try AttachmentPayloadStore(
            root: root, ownerUID: UInt32(getuid()), reserveBytes: 0, availableBytes: { .max })
        XCTAssertEqual(try reopened.read(descriptor: attachment, offset: 0, limit: 64), bytes)
        XCTAssertGreaterThan(reopened.placementRecoveryScansForTesting, 0)
    }

    func testDuplicateIDAndSymlinkEntryFailClosedDuringRebuild() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.placementArrivalMinuteForTesting = { "2026/10/16/01/40" }
        let id = try identifier()
        let bytes = Data("duplicate identity".utf8)
        let attachment = try stage(bytes, id: id, in: store)
        try store.publish(descriptor: attachment)
        let first = try store.payloadURL(for: id)
        let duplicateDir = try privateDirectory(
            root: root, components: ["attachments", "payloads", "2026", "10", "16", "01", "41"])
        let duplicate = duplicateDir.appendingPathComponent("\(id).payload")
        try FileManager.default.copyItem(at: first, to: duplicate)
        XCTAssertThrowsError(try store.rebuildPlacement())
        try FileManager.default.removeItem(at: duplicate)
        try Data("conflicting duplicate".utf8).write(to: duplicate)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: duplicate.path)
        XCTAssertThrowsError(try store.rebuildPlacement())
        try FileManager.default.removeItem(at: duplicate)
        let outside = root.appendingPathComponent("outside.payload")
        try Data("outside".utf8).write(to: outside)
        let link = duplicateDir.appendingPathComponent("\(id).payload")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try store.rebuildPlacement())
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testPlacementCapabilityIsRaisedBeforePublicationAndOldReaderRefuses() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try identifier()
        let bytes = Data("requires placement reader".utf8)
        let attachment = try stage(bytes, id: id, in: store)
        try store.publish(descriptor: attachment)
        let requirement = try XCTUnwrap(
            CanonicalReaderRequirement.load(root: root, ownerUID: UInt32(getuid())))
        XCTAssertTrue(requirement.capabilities.contains(PayloadPlacement.capability))
        let olderReader = CanonicalFormatSupport(readerLevel: 7, writerLevel: 7, read: [1, 2], write: [2])
        XCTAssertThrowsError(try olderReader.require(requirement)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "incompatibleCanonicalReader")
        }
    }
}
