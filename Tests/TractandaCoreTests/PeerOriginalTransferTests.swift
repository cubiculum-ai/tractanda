import Crypto
import XCTest

@testable import TractandaCore

final class PeerOriginalTransferTests: XCTestCase {
    private struct Fixture {
        let descriptor: AttachmentDescriptor
        let object: PeerPackage.Object
        let bytes: Data
    }

    private func root(_ label: String) throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        let value = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
            "peer-original-\(label)-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: value, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return value
    }

    private func fixture(_ label: String, byteCount: Int = 256 * 1024 + 17) throws -> Fixture {
        // Bound each fixture before allocating payload data or creating its store.
        guard byteCount >= 0, UInt64(byteCount) <= AttachmentFixtureCapacity.fixtureCapBytes else {
            throw TractandaError("resourceLimit", "Peer original fixture exceeds its tiny test cap.")
        }
        try AttachmentFixtureCapacity.requireFree()
        let source = try root(label + "-source")
        defer { try? FileManager.default.removeItem(at: source) }
        let bytes = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let descriptor: AttachmentDescriptor
        do {
            let store = try ItemStore(root: source)
            let item = try store.commit(CommitRequest(classID: "Item", operationID: "base")).revision
            let intent = AttachmentUploadRequest(
                itemID: item.itemID, expectedRevisionID: item.revisionID, operationID: "original",
                filename: "opaque.bin", mediaType: "application/octet-stream", byteCount: Int64(bytes.count),
                sha256: Self.digest(bytes))
            let upload = try store.beginAttachment(intent)
            if !bytes.isEmpty {
                var offset = 0
                while offset < bytes.count {
                    let end = min(offset + PeerPackage.maximumPayloadChunkBytes, bytes.count)
                    _ = try store.appendAttachment(
                        uploadID: try XCTUnwrap(upload.uploadID), offset: Int64(offset),
                        data: bytes.subdata(in: offset..<end))
                    offset = end
                }
            }
            _ = try store.finishAttachment(uploadID: try XCTUnwrap(upload.uploadID))
            descriptor = upload.attachment
        }
        let object = PeerPackage.Object(
            kind: .attachment, id: descriptor.attachmentID, length: byteCount, sha256: Self.digest(bytes))
        return Fixture(descriptor: descriptor, object: object, bytes: bytes)
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func packageID() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }

    private func transfer(
        root: URL, maximumBytes: Int64 = .max,
        reserveBytes: Int64 = 0, availableBytes: (@Sendable () throws -> UInt64)? = nil
    ) throws -> (PeerOriginalTransfer, StagingByteQuota) {
        let uid = UInt32(getuid())
        // Establish genuine format2 reader state before private authority-work directories exist.
        // Release the ordinary Store writer before exercising the internal transfer bridge.
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("canonical-reader.json").path)
        {
            let store = try ItemStore(root: root)
            _ = try store.commit(CommitRequest(classID: "Item", operationID: "receiver-marker"))
        }
        let quota = try StagingByteQuota(root: root, ownerUID: uid, maximumBytes: maximumBytes)
        let payloads = try AttachmentPayloadStore(
            root: root, ownerUID: uid, reserveBytes: 0, stagingQuota: quota)
        let bridge = try PeerOriginalTransfer(
            root: root, ownerUID: uid, payloads: payloads, quota: quota,
            reserveBytes: reserveBytes, availableBytes: availableBytes)
        return (bridge, quota)
    }

    func testProofIntentAloneAcknowledgesNoBytesAndRetriesAreBoundToExactChunk() throws {
        let original = try fixture("proof")
        let receiver = try root("proof-receiver")
        defer { try? FileManager.default.removeItem(at: receiver) }
        let (bridge, _) = try transfer(root: receiver)
        let packageID = try packageID()
        bridge.afterProofIntentForTesting = {
            throw TractandaError("interrupted", "Injected after proof intent.")
        }
        XCTAssertThrowsError(
            try bridge.append(
                packageID: packageID, object: original.object, offset: 0,
                bytes: original.bytes.subdata(in: 0..<PeerPackage.maximumPayloadChunkBytes)))
        bridge.afterProofIntentForTesting = nil
        XCTAssertEqual(try bridge.resume(packageID: packageID, object: original.object).nextOffset, 0)
        let chunk = original.bytes.subdata(in: 0..<PeerPackage.maximumPayloadChunkBytes)
        try bridge.append(packageID: packageID, object: original.object, offset: 0, bytes: chunk)
        XCTAssertEqual(
            try bridge.resume(packageID: packageID, object: original.object).nextOffset, chunk.count)

        let altered = Data(repeating: 0xA5, count: chunk.count)
        XCTAssertThrowsError(
            try bridge.append(
                packageID: packageID, object: original.object, offset: 0, bytes: altered))
        XCTAssertEqual(
            try bridge.resume(packageID: packageID, object: original.object).nextOffset, chunk.count)
    }

    func testInterruptedPrefixReopensAndCompletesWithIdenticalRetry() throws {
        let original = try fixture("resume", byteCount: 2 * 256 * 1024 + 17)
        let receiver = try root("resume-receiver")
        defer { try? FileManager.default.removeItem(at: receiver) }
        let packageID = try packageID()
        let first = original.bytes.subdata(in: 0..<PeerPackage.maximumPayloadChunkBytes)
        let (initial, _) = try transfer(root: receiver)
        try initial.append(packageID: packageID, object: original.object, offset: 0, bytes: first)
        initial.afterProofIntentForTesting = {
            throw TractandaError("interrupted", "Injected after the second chunk proof intent.")
        }
        let second = original.bytes.subdata(
            in: first.count..<(first.count + PeerPackage.maximumPayloadChunkBytes))
        let tailOffset = first.count + second.count
        let tail = original.bytes.subdata(in: tailOffset..<original.bytes.count)
        XCTAssertThrowsError(
            try initial.append(
                packageID: packageID, object: original.object, offset: first.count, bytes: second))
        let binding = try XCTUnwrap(
            initial.binding(packageID: packageID, object: original.object, create: false))
        try initial.payloads.append(
            id: binding.stageID, offset: Int64(first.count), data: second.prefix(17))

        // Simulate a process restart with a new verification epoch and quota reconstruction.
        let reopenedQuota = try StagingByteQuota(
            root: receiver, ownerUID: UInt32(getuid()), maximumBytes: .max)
        let reopenedPayloads = try AttachmentPayloadStore(
            root: receiver, ownerUID: UInt32(getuid()), reserveBytes: 0, stagingQuota: reopenedQuota)
        let reopened = try PeerOriginalTransfer(
            root: receiver, ownerUID: UInt32(getuid()), payloads: reopenedPayloads, quota: reopenedQuota,
            reserveBytes: 0)
        XCTAssertEqual(
            try reopened.resume(packageID: packageID, object: original.object).nextOffset, first.count)
        try reopened.append(
            packageID: packageID, object: original.object, offset: first.count, bytes: second)
        try reopened.append(
            packageID: packageID, object: original.object, offset: tailOffset, bytes: tail)
        let state = try reopened.resume(packageID: packageID, object: original.object)
        XCTAssertEqual(state.nextOffset, original.bytes.count)
        XCTAssertTrue(state.verifiedComplete)
        try reopened.requireComplete(
            packageID: packageID, object: original.object, descriptor: original.descriptor)
    }

    func testOpaqueAndEmptyOriginalsPublishBeforeCleanupAndRetainAccountingUntilComplete() throws {
        let receiver = try root("publish")
        defer { try? FileManager.default.removeItem(at: receiver) }
        let opaque = try fixture("opaque", byteCount: 2 * 256 * 1024 + 9)
        let (bridge, _) = try transfer(root: receiver)
        let opaquePackageID = try packageID()
        var offset = 0
        while offset < opaque.bytes.count {
            let end = min(offset + PeerPackage.maximumPayloadChunkBytes, opaque.bytes.count)
            try bridge.append(
                packageID: opaquePackageID, object: opaque.object, offset: offset,
                bytes: opaque.bytes.subdata(in: offset..<end))
            offset = end
        }
        try bridge.requireComplete(
            packageID: opaquePackageID, object: opaque.object, descriptor: opaque.descriptor)
        try bridge.publish(packageID: opaquePackageID, object: opaque.object, descriptor: opaque.descriptor)
        var readback = Data()
        var readOffset = 0
        while readOffset < opaque.bytes.count {
            let count = min(PeerPackage.maximumPayloadChunkBytes, opaque.bytes.count - readOffset)
            readback.append(
                try bridge.read(
                    descriptor: opaque.descriptor, offset: readOffset, maximumBytes: count, progress: nil))
            readOffset += count
        }
        XCTAssertEqual(readback, opaque.bytes)
        XCTAssertGreaterThan(
            try bridge.accountedBytes(packageID: opaquePackageID, objectID: opaque.object.id),
            UInt64(opaque.bytes.count))
        try bridge.complete(packageID: opaquePackageID)
        XCTAssertEqual(try bridge.stagedBytes(packageID: opaquePackageID), 0)

        let empty = try fixture("empty", byteCount: 0)
        let emptyPackage = try packageID()
        let emptyState = try bridge.resume(packageID: emptyPackage, object: empty.object)
        XCTAssertEqual(emptyState.nextOffset, 0)
        XCTAssertTrue(emptyState.verifiedComplete)
        try bridge.requireComplete(
            packageID: emptyPackage, object: empty.object, descriptor: empty.descriptor)
        try bridge.publish(packageID: emptyPackage, object: empty.object, descriptor: empty.descriptor)
        XCTAssertEqual(
            try bridge.read(descriptor: empty.descriptor, offset: 0, maximumBytes: 1, progress: nil), Data())
        try bridge.complete(packageID: emptyPackage)
    }

    func testQuotaAndUnknownCapacityFailuresDoNotAdvanceAcknowledgedOffset() throws {
        let original = try fixture("limits")
        let chunk = original.bytes.subdata(in: 0..<PeerPackage.maximumPayloadChunkBytes)
        let capacityRoot = try root("capacity-receiver")
        defer { try? FileManager.default.removeItem(at: capacityRoot) }
        let (capacityBridge, _) = try transfer(
            root: capacityRoot, reserveBytes: 1,
            availableBytes: { throw TractandaError("unknown", "unavailable") })
        let capacityPackageID = try packageID()
        XCTAssertThrowsError(
            try capacityBridge.append(
                packageID: capacityPackageID, object: original.object, offset: 0, bytes: chunk))
        XCTAssertEqual(
            try capacityBridge.resume(packageID: capacityPackageID, object: original.object).nextOffset, 0)

        let quotaRoot = try root("quota-receiver")
        defer { try? FileManager.default.removeItem(at: quotaRoot) }
        let (quotaBridge, _) = try transfer(root: quotaRoot, maximumBytes: 1)
        let quotaPackageID = try packageID()
        XCTAssertThrowsError(
            try quotaBridge.append(
                packageID: quotaPackageID, object: original.object, offset: 0, bytes: chunk))
        XCTAssertEqual(
            try quotaBridge.resume(packageID: quotaPackageID, object: original.object).nextOffset, 0)
    }
    func testAcknowledgedAlignedTruncationMissingStageAndMissingCheckpointFailClosed() throws {
        let original = try fixture("ack-loss", byteCount: 2 * PeerPackage.maximumPayloadChunkBytes)
        for fault in ["aligned", "missing-stage", "missing-checkpoint"] {
            let receiver = try root(fault)
            defer { try? FileManager.default.removeItem(at: receiver) }
            let (bridge, _) = try transfer(root: receiver)
            let package = try packageID()
            for offset in stride(from: 0, to: original.bytes.count, by: original.object.chunkBytes) {
                try bridge.append(
                    packageID: package, object: original.object, offset: offset,
                    bytes: Data(original.bytes[offset..<offset + original.object.chunkBytes]))
            }
            let binding = try XCTUnwrap(
                bridge.binding(packageID: package, object: original.object, create: false))
            let stage = receiver.appendingPathComponent("attachments/.staging/" + binding.stageID + ".stage")
            if fault == "aligned" {
                let file = try FileHandle(forWritingTo: stage)
                try file.truncate(atOffset: UInt64(original.object.chunkBytes))
                try file.synchronize()
                try file.close()
            } else if fault == "missing-stage" {
                try FileManager.default.removeItem(at: stage)
            } else {
                try FileManager.default.removeItem(
                    at: receiver.appendingPathComponent(
                        "authority/payloads/" + package + "/" + original.object.id + "/high-water.json"))
            }
            XCTAssertThrowsError(try bridge.resume(packageID: package, object: original.object)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
            }
        }
    }
    func testResumeDurablyAcknowledgesFsyncedBytesWithoutReceivedMarker() throws {
        let original = try fixture("resume-ack", byteCount: 2 * PeerPackage.maximumPayloadChunkBytes)
        let receiver = try root("resume-ack")
        defer { try? FileManager.default.removeItem(at: receiver) }
        let (bridge, _) = try transfer(root: receiver)
        let package = try packageID()
        let chunk = Data(original.bytes.prefix(original.object.chunkBytes))
        bridge.afterProofIntentForTesting = { throw TractandaError("interrupted", "Before stage append") }
        XCTAssertThrowsError(
            try bridge.append(packageID: package, object: original.object, offset: 0, bytes: chunk))
        bridge.afterProofIntentForTesting = nil
        let binding = try XCTUnwrap(
            bridge.binding(packageID: package, object: original.object, create: false))
        _ = try bridge.payloads.append(id: binding.stageID, offset: 0, data: chunk)
        XCTAssertEqual(try bridge.resume(packageID: package, object: original.object).nextOffset, chunk.count)
        let stage = receiver.appendingPathComponent("attachments/.staging/" + binding.stageID + ".stage")
        let file = try FileHandle(forWritingTo: stage)
        try file.truncate(atOffset: 0)
        try file.synchronize()
        try file.close()
        XCTAssertThrowsError(try bridge.resume(packageID: package, object: original.object)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
        }
    }
    func testColdVerificationHonorsSmallReadWindowsAndDirectAppendRejectsCorruptPrefix() throws {
        let original = try fixture("budget", byteCount: 2 * PeerPackage.maximumPayloadChunkBytes + 17)
        let receiver = try root("budget")
        defer { try? FileManager.default.removeItem(at: receiver) }
        let (bridge, _) = try transfer(root: receiver)
        let package = try packageID()
        for offset in stride(from: 0, to: original.bytes.count, by: original.object.chunkBytes) {
            try bridge.append(
                packageID: package, object: original.object, offset: offset,
                bytes: Data(
                    original.bytes[offset..<min(original.bytes.count, offset + original.object.chunkBytes)]))
        }
        let (reopened, _) = try transfer(root: receiver)
        var complete = false
        for _ in 0..<16 {
            let budget = PeerOriginalReadBudget(bytes: 128 * 1024, maximumSteps: 128)
            do {
                complete = try reopened.resume(packageID: package, object: original.object, budget: budget)
                    .verifiedComplete
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "peerPayloadVerifying") }
            XCTAssertLessThanOrEqual(budget.used, 128 * 1024)
            if complete { break }
        }
        XCTAssertTrue(complete)
        let binding = try XCTUnwrap(
            reopened.binding(packageID: package, object: original.object, create: false))
        let stage = receiver.appendingPathComponent("attachments/.staging/" + binding.stageID + ".stage")
        let file = try FileHandle(forWritingTo: stage)
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Data([0xDA]))
        try file.synchronize()
        try file.close()
        let (cold, _) = try transfer(root: receiver)
        XCTAssertThrowsError(
            try cold.append(
                packageID: package, object: original.object, offset: 0,
                bytes: Data(original.bytes.prefix(original.object.chunkBytes)))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
        }
    }

    func testJournalObjectLimitIncludesPrivateOriginalBindingsAcrossReopen() throws {
        let receiver = try root("object-limit")
        defer { try? FileManager.default.removeItem(at: receiver) }
        let first = try fixture("count-first", byteCount: 17)
        let second = try fixture("count-second", byteCount: 19)
        let (bridge, quota) = try transfer(root: receiver)
        let store =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: receiver.appendingPathComponent(".tractanda-store-identity.json")))
            as! [String: Any]
        let storeID = try XCTUnwrap(store["storeID"] as? String)
        let context = try PeerPackage.Context(
            peerID: "raven", storeID: storeID, configurationDigest: Self.digest(Data("config".utf8)),
            permittedOrigins: [try packageID()])
        var limits = PeerPackage.Limits()
        limits.maximumObjects = 2
        limits.reserveBytes = 0
        let journal = PeerIntakeJournal(
            root: receiver, ownerUID: UInt32(getuid()), limits: limits, stagingQuota: quota)
        journal.originals = bridge
        let bytes = try JSON.encode(PeerPackage.Page(objects: [first.object, second.object], children: []))
        let page = PeerPackage.Object(
            kind: .index, id: try packageID(), length: bytes.count, sha256: Self.digest(bytes))
        let manifest = PeerPackage.Manifest(packageID: try packageID(), storeID: storeID, root: page)
        _ = try journal.begin(context: context, manifestBytes: JSON.encode(manifest))
        _ = try journal.append(
            context: context, packageID: manifest.packageID, object: page, offset: 0, bytes: bytes)
        _ = try journal.append(
            context: context, packageID: manifest.packageID, object: first.object, offset: 0,
            bytes: first.bytes)
        let before = quota.usedBytes
        let reopened = PeerIntakeJournal(
            root: receiver, ownerUID: UInt32(getuid()), limits: limits, stagingQuota: quota)
        reopened.originals = bridge
        XCTAssertThrowsError(
            try reopened.append(
                context: context, packageID: manifest.packageID, object: second.object, offset: 0,
                bytes: second.bytes)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertEqual(quota.usedBytes, before)
        XCTAssertFalse(try bridge.hasObject(packageID: manifest.packageID, objectID: second.object.id))
        let empty = PeerPackage.Object(
            kind: .attachment, id: try packageID(), length: 0, sha256: PeerPackage.emptySHA256)
        XCTAssertThrowsError(try bridge.resume(packageID: manifest.packageID, object: empty)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertFalse(try bridge.hasObject(packageID: manifest.packageID, objectID: empty.id))
        XCTAssertEqual(quota.usedBytes, before)

    }

}
