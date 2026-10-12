import Crypto
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class AttachmentStorageTests: XCTestCase {
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }
    private final class CapacityProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var available: UInt64
        init(_ available: UInt64) { self.available = available }
        func set(_ value: UInt64) {
            lock.lock()
            available = value
            lock.unlock()
        }
        func get() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return available
        }
    }

    private func fixture(
        fileLimit: Int64 = 256, chunkLimit: Int = 16, reserve: Int64 = 0,
        capacity: CapacityProbe = CapacityProbe(.max)
    ) throws -> (URL, AttachmentPayloadStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-attachment-store-\(Identifier.make())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let store = try AttachmentPayloadStore(
            root: root, ownerUID: UInt32(getuid()), reserveBytes: reserve,
            availableBytes: { capacity.get() }, maxFileBytesForTesting: fileLimit,
            maxChunkBytesForTesting: chunkLimit)
        return (root, store)
    }

    private func identifier(_ offset: UInt64 = 0) throws -> String {
        let original = try UUID.makeVersion1().version1Components!
        return try UUIDVersion1Components(
            timestamp: original.timestamp + offset, clockSequence: original.clockSequence,
            node: original.node
        ).uuid.uuidString.lowercased()
    }

    private func descriptor(id: String, data: Data, filename: String = "../résumé.pdf") throws
        -> AttachmentDescriptor
    {
        try AttachmentDescriptor(
            attachmentID: id, filename: filename, mediaType: "application/pdf",
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func stage(
        _ data: Data, id: String, store: AttachmentPayloadStore, chunkSize: Int
    ) throws -> AttachmentDescriptor {
        try store.createStaging(id: id)
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkSize)
            let chunk = data.subdata(in: offset..<end)
            _ = try store.append(id: id, offset: Int64(offset), data: chunk)
            offset = end
        }
        return try descriptor(id: id, data: data)
    }

    private func assertCode<T>(
        _ code: String, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> T
    ) {
        do {
            _ = try operation()
            XCTFail("Expected error code \(code)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? TractandaError)?.code, code, "\(error)", file: file, line: line)
        }
    }

    func testDescriptorIsStrictTaggedMetadataAndNeverTurnsFilenameIntoPath() throws {
        let firstID = try identifier()
        let data = Data("proof".utf8)
        let first = try descriptor(id: firstID, data: data)
        XCTAssertEqual(first.filename, "../résumé.pdf")
        XCTAssertEqual(
            try AttachmentDescriptor(.object(first.itemValue.map!)), first)
        XCTAssertEqual(try JSON.decode(AttachmentDescriptor.self, JSON.encode(first)), first)
        XCTAssertEqual(
            try AttachmentDescriptor.descriptors(in: ["attachments": .list([first.itemValue])]), [first])
        XCTAssertTrue(try AttachmentDescriptor.descriptors(in: [:]).isEmpty)
        XCTAssertEqual(try AttachmentDescriptor.descriptors(in: ["attachments": .list([])]), [])

        let duplicate = ["attachments": ItemValue.list([first.itemValue, first.itemValue])]
        assertCode("invalidAttachment") { try AttachmentDescriptor.descriptors(in: duplicate) }
        assertCode("invalidAttachment") {
            try AttachmentDescriptor(
                attachmentID: Identifier.make(), filename: "x", mediaType: "application/pdf",
                byteCount: 0, sha256: String(repeating: "0", count: 64))
        }
        assertCode("invalidAttachment") {
            try AttachmentDescriptor(
                attachmentID: firstID, filename: "x", mediaType: "application/pdf; charset=utf-8",
                byteCount: 0, sha256: String(repeating: "0", count: 64))
        }
        assertCode("invalidAttachment") {
            try AttachmentDescriptor(
                attachmentID: firstID, filename: "x", mediaType: "application/pdf",
                byteCount: -1,
                sha256: String(repeating: "0", count: 64))
        }
        XCTAssertEqual(
            try AttachmentDescriptor(
                attachmentID: firstID, filename: "large", mediaType: "application/pdf", byteCount: .max,
                sha256: String(repeating: "0", count: 64)
            ).byteCount, .max)
        var extra = first.itemValue.map!
        extra["unexpected"] = .text("reject unknown descriptor data")
        assertCode("invalidAttachment") { try AttachmentDescriptor(.object(extra)) }
        let unknownJSON = Data(
            "{\"attachmentID\":\"\(firstID)\",\"filename\":\"x\",\"mediaType\":\"application/pdf\",\"byteCount\":0,\"sha256\":\"\(String(repeating: "0", count: 64))\",\"extra\":true}"
                .utf8)
        assertCode("invalidAttachment") { try JSON.decode(AttachmentDescriptor.self, unknownJSON) }
        let tooMany = try (0...AttachmentDescriptor.maximumAttachments).map { index in
            try descriptor(id: identifier(UInt64(index + 1)), data: data).itemValue
        }
        assertCode("invalidAttachment") {
            try AttachmentDescriptor.descriptors(in: ["attachments": .list(tooMany)])
        }
    }

    func testSequentialChunkRetryMismatchAndFileCap() throws {
        let (root, store) = try fixture(fileLimit: 12, chunkLimit: 5)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try identifier()
        try store.createStaging(id: id)
        XCTAssertEqual(try store.append(id: id, offset: 0, data: Data("abcde".utf8)), 5)
        XCTAssertEqual(try store.append(id: id, offset: 0, data: Data("abcde".utf8)), 5)
        assertCode("uploadMismatch") { try store.append(id: id, offset: 0, data: Data("xxxxx".utf8)) }
        assertCode("uploadOffsetMismatch") { try store.append(id: id, offset: 7, data: Data("x".utf8)) }
        XCTAssertEqual(try store.append(id: id, offset: 5, data: Data("fghij".utf8)), 10)
        assertCode("resourceLimit") { try store.append(id: id, offset: 10, data: Data("klm".utf8)) }
        XCTAssertEqual(try store.stagedSize(id: id), 10)
        XCTAssertEqual(try store.append(id: id, offset: 10, data: Data("kl".utf8)), 12)
        XCTAssertEqual(try store.stagedSize(id: id), 12)
    }

    func testPublishReadCloneAndDigestCacheStayChunkBounded() throws {
        let (root, store) = try fixture(fileLimit: 96, chunkLimit: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("0123456789abcdefghijklmnopqrstuv".utf8)
        let id = try identifier()
        let original = try stage(bytes, id: id, store: store, chunkSize: 8)
        try store.publish(descriptor: original)
        XCTAssertEqual(store.digestPassCountForTesting, 1)
        assertCode("identifierCollision") { try store.createStaging(id: id) }
        let payloadURL = try store.payloadURL(for: id)
        XCTAssertTrue(
            payloadURL.path.hasPrefix(root.appendingPathComponent("attachments/payloads").path + "/"))
        XCTAssertFalse(payloadURL.path.contains("résumé.pdf"))
        try store.validate(descriptor: original)
        XCTAssertEqual(try store.read(descriptor: original, offset: 0, limit: 8), bytes.prefix(8))
        XCTAssertEqual(try store.read(descriptor: original, offset: 8, limit: 8), bytes[8..<16])
        XCTAssertEqual(
            store.digestPassCountForTesting, 1, "Repeated bounded reads reuse the verified signature.")
        XCTAssertEqual(try store.read(descriptor: original, offset: Int64(bytes.count), limit: 8), Data())
        assertCode("invalidArguments") { try store.read(descriptor: original, offset: 0, limit: 9) }

        let newID = try identifier(10_000_000)
        let clone = try store.clone(source: original, newID: newID)
        XCTAssertNotEqual(clone.attachmentID, original.attachmentID)
        XCTAssertEqual(clone.sha256, original.sha256)
        XCTAssertEqual(try store.read(descriptor: clone, offset: 0, limit: 8), bytes.prefix(8))
        XCTAssertEqual(try Data(contentsOf: store.payloadURL(for: clone.attachmentID)), bytes)
    }

    func testSealedStageCanFinishPublicationAfterInterruptionAndClearAbandonedStages() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("sealed stage".utf8)
        let sealedID = try identifier()
        let sealedDescriptor = try stage(data, id: sealedID, store: store, chunkSize: 8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400], ofItemAtPath: try store.stagingURLForTesting(id: sealedID).path)
        try store.publish(descriptor: sealedDescriptor)
        try store.publish(descriptor: sealedDescriptor)
        XCTAssertEqual(try Data(contentsOf: store.payloadURL(for: sealedID)), data)

        let pendingID = try identifier(20_000_000)
        try store.createStaging(id: pendingID)
        _ = try store.append(id: pendingID, offset: 0, data: Data("partial".utf8))
        try store.clearStaging()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try store.stagingURLForTesting(id: pendingID).path))
        assertCode("attachmentIntegrity") { try store.stagedSize(id: pendingID) }
    }

    func testFreeSpaceGuardFailsClosedBeforeStageCreation() throws {
        let capacity = CapacityProbe(.max)
        let (root, store) = try fixture(fileLimit: 32, chunkLimit: 8, reserve: 4_096, capacity: capacity)
        defer { try? FileManager.default.removeItem(at: root) }
        capacity.set(4_096)
        let id = try identifier()
        assertCode("resourceLimit") { try store.createStaging(id: id) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.stagingURLForTesting(id: id).path))
        let cannotMeasure = try AttachmentPayloadStore(
            root: root, ownerUID: UInt32(getuid()), reserveBytes: 0,
            availableBytes: { throw TractandaError("capacityUnavailable", "test") })
        assertCode("resourceLimit") { try cannotMeasure.createStaging(id: try identifier(30_000_000)) }
    }

    func testCorruptionAndSymlinkReplacementsAreRejected() throws {
        let (root, store) = try fixture(fileLimit: 64, chunkLimit: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("immutable-original".utf8)
        let id = try identifier()
        let attachment = try stage(data, id: id, store: store, chunkSize: 8)
        try store.publish(descriptor: attachment)
        let payload = try store.payloadURL(for: id)
        let originalMetadata = try FileMetadata.read(at: payload)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)
        try Data("corrupted-original".utf8).write(to: payload)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: payload.path)
        // Same-sized writes can share a filesystem timestamp tick. This case
        // exercises rehashing after an observable metadata change, not a timer race.
        try FileManager.default.setAttributes(
            [
                .modificationDate: Date(
                    timeIntervalSince1970: Double(originalMetadata.modificationSeconds) + 2)
            ],
            ofItemAtPath: payload.path)
        XCTAssertNotEqual(try FileMetadata.read(at: payload), originalMetadata)
        assertCode("attachmentIntegrity") { try store.validate(descriptor: attachment) }
        XCTAssertEqual(store.digestPassCountForTesting, 2, "Changed metadata triggers one streamed rehash.")

        let external = root.appendingPathComponent("outside").appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: external)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: external)
        assertCode("attachmentIntegrity") { try store.validate(descriptor: attachment) }
        XCTAssertEqual(try Data(contentsOf: external), Data("outside".utf8))
    }

    func testDirectorySymlinkCannotRedirectPayloadLookup() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("path test".utf8)
        let id = try identifier()
        let attachment = try stage(data, id: id, store: store, chunkSize: 8)
        try store.publish(descriptor: attachment)
        let payload = try store.payloadURL(for: id)
        let parent = payload.deletingLastPathComponent()
        let relocated = root.appendingPathComponent("relocated-payload-directory", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: relocated)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: relocated)

        assertCode("unsafeAttachmentStore") { try store.validate(descriptor: attachment) }
        XCTAssertEqual(
            try Data(contentsOf: relocated.appendingPathComponent(payload.lastPathComponent)), data)
    }
    func testCanonicalOriginalFIFOReplacementFailsWithoutWaitingForWriter() throws {
        // One tiny original/FIFO and metadata are estimated below128KiB; enforce16MiB+10GiB.
        try PageCorpusSpoolPolicy(
            maximumBytes: 16 * 1024 * 1024,
            minimumFreeBytes: 10 * 1024 * 1024 * 1024
        ).check(
            at: FileManager.default.temporaryDirectory, additionalBytes: 128 * 1024)
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try identifier()
        let attachment = try stage(Data([1, 2, 3]), id: id, store: store, chunkSize: 3)
        try store.publish(descriptor: attachment)
        let payload = try store.payloadURL(for: id)
        try FileManager.default.removeItem(at: payload)
        XCTAssertEqual(mkfifo(payload.path, 0o400), 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                try store.validate(descriptor: attachment)
                XCTFail("FIFO replacement must reject")
            } catch {
                XCTAssertEqual((error as? TractandaError)?.code, "attachmentIntegrity")
            }
        }
        let result = finished.wait(timeout: .now() + 1)
        if result == .timedOut {
            // Unblock a regressed blocking open so the bounded test cannot strand a thread.
            _ = chmod(payload.path, 0o600)
            let writer = open(payload.path, O_RDWR | O_NONBLOCK)
            if writer >= 0 { _ = close(writer) }
            _ = finished.wait(timeout: .now() + 1)
        }
        XCTAssertEqual(result, .success, "Canonical FIFO open must reject before waiting for a writer")
    }

}
