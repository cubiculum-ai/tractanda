import CSQLite
import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class PeerAtomicIntakePreparationTests: XCTestCase {
    private typealias Fixture = AtomicAuthorityStoreFixture
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func privateRoot(_ f: Fixture) throws -> URL {
        let root = f.directory.appendingPathComponent("preparation-" + (try id()))
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func coordinator(_ f: Fixture, limits: PeerPackage.Limits = .init()) -> PeerIntakeCoordinator {
        let result = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID, limits: limits)
        result.canonicalFormatSupport = AtomicAuthorityCompatibility.support
        return result
    }
    private func part(_ f: Fixture) throws -> (PeerPackage.Object, Data) {
        let record = try AtomicAuthorityFormat.Record(
            value: .object([
                "profile": .text(AtomicAuthorityFormat.profile), "kind": .text("atomicControlPart"),
                "recordID": .text(try id()), "controlID": .text(try id()), "storeID": .text(f.storeID),
                "originReplicaID": .text(try XCTUnwrap(f.source.replicaID)),
                "actorPrincipal": .text("user:admin"), "createdAt": .date(Timestamp.now()),
                "payload": .object([
                    "section": .text("effects"), "ordinal": .integer(0), "byteOffset": .integer(0),
                    "bytes": .bytes(Data([1, 2, 3])),
                ]),
            ]))
        let data = try AtomicAuthorityFormat.Codec.encode(record)
        return (
            .init(
                kind: .authority, id: record.recordID, length: data.count,
                sha256: AuthorityRecordCodec.sha256(data)), data
        )
    }
    private func drain(_ preparation: PeerAtomicIntakePreparation, limit: Int = 100) throws -> Int {
        for count in 1...limit {
            if try preparation.step(maximumObjects: 1) { return count }
        }
        XCTFail("Tiny preparation did not complete within its explicit work bound")
        throw TractandaError("fixture", "Preparation work bound")
    }
    private func assertScratchRemoved(_ root: URL, file: StaticString = #filePath, line: UInt = #line) {
        for name in [
            "preparation.sqlite", "preparation.sqlite-journal", "preparation.sqlite-wal",
            "preparation.sqlite-shm",
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                name, file: file, line: line)
        }
    }
    func testPhysicalPartCompletesRawOnlyAndExactSealedRetryPreservesUnknownFiles() throws {
        let f = try Fixture()
        try f.activateAndOpen()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let coordinator = coordinator(f)
        let object = try part(f)
        let context = try coordinator.context(peerID: "local")
        let manifest = try coordinator.stageObjects([object], context: context, packageID: id())
        let head = try index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID))
        let root = try privateRoot(f)
        let unknown = root.appendingPathComponent("keep.txt")
        try Data("caller-owned".utf8).write(to: unknown)
        var seals = 0
        let preparation = try PeerAtomicIntakePreparation(
            coordinator: coordinator, index: index, privateRoot: root, context: context,
            packageID: manifest.packageID, contextToken: "exact-private-context", beforeSeal: { seals += 1 })
        XCTAssertGreaterThan(try drain(preparation), 1)
        XCTAssertEqual(seals, 1)
        XCTAssertNotNil(try coordinator.journal.publication(manifest.packageID))
        let row = try XCTUnwrap(index.retainedAuthorityObject(id: object.0.id))
        XCTAssertEqual(try coordinator.bytes(row), object.1)
        XCTAssertFalse(
            try index.hasValidatedAuthorityControl(.init(recordID: object.0.id, sha256: object.0.sha256)))
        XCTAssertEqual(try index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)), head)
        try preparation.close()
        assertScratchRemoved(root)
        XCTAssertEqual(try Data(contentsOf: unknown), Data("caller-owned".utf8))
        let sealed = try coordinator.journal.publication(manifest.packageID)
        let retry = try PeerAtomicIntakePreparation(
            coordinator: coordinator, index: index, privateRoot: root, context: context,
            packageID: manifest.packageID, contextToken: "new-request-after-head-change", beforeSeal: {})
        _ = try drain(retry)
        XCTAssertEqual(try coordinator.journal.publication(manifest.packageID), sealed)
        try retry.close()
        assertScratchRemoved(root)
        try f.capacity()
    }
    func testMalformedFinalOriginalCannotSealOrRetainValidPrefix() throws {
        let f = try Fixture()
        try f.activateAndOpen()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let coordinator = coordinator(f)
        let first = try part(f)
        let bad = Data("invalid canonical authority".utf8)
        let descriptor = PeerPackage.Object(
            kind: .authority, id: try id(), length: bad.count, sha256: AuthorityRecordCodec.sha256(bad))
        let context = try coordinator.context(peerID: "local")
        let manifest = try coordinator.stageObjects(
            [first, (descriptor, bad)], context: context, packageID: id())
        let root = try privateRoot(f)
        var seals = 0
        let preparation = try PeerAtomicIntakePreparation(
            coordinator: coordinator, index: index, privateRoot: root, context: context,
            packageID: manifest.packageID, contextToken: "bad-final", beforeSeal: { seals += 1 })
        XCTAssertThrowsError(try drain(preparation))
        XCTAssertEqual(seals, 0)
        XCTAssertNil(try coordinator.journal.publication(manifest.packageID))
        XCTAssertNil(try index.retainedAuthorityObject(id: first.0.id))
        try preparation.close()
        assertScratchRemoved(root)
        try f.capacity()
    }
    func testCancellationAndBeforeSealFailureRemainRetryableWithoutEarlyPublication() throws {
        let f = try Fixture()
        try f.activateAndOpen()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let coordinator = coordinator(f)
        let object = try part(f)
        let context = try coordinator.context(peerID: "local")
        let manifest = try coordinator.stageObjects([object], context: context, packageID: id())
        let root = try privateRoot(f)
        var permit = false
        let preparation = try PeerAtomicIntakePreparation(
            coordinator: coordinator, index: index, privateRoot: root, context: context,
            packageID: manifest.packageID, contextToken: "fresh-authorization",
            beforeSeal: {
                if !permit { throw TractandaError("permissionDenied", "Fixture fresh authorization") }
            })
        coordinator.progress = { throw CancellationError() }
        XCTAssertThrowsError(try preparation.step(maximumObjects: 1)) {
            XCTAssertTrue($0 is CancellationError)
        }
        coordinator.progress = nil
        XCTAssertThrowsError(try drain(preparation)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "permissionDenied")
        }
        XCTAssertNil(try coordinator.journal.publication(manifest.packageID))
        XCTAssertNil(try index.retainedAuthorityObject(id: object.0.id))
        permit = true
        _ = try drain(preparation)
        try preparation.close()
        assertScratchRemoved(root)
        try f.capacity()
    }
    func testReplacedScratchIsRejectedAndPreserved() throws {
        let f = try Fixture()
        try f.activateAndOpen()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let coordinator = coordinator(f)
        let context = try coordinator.context(peerID: "local")
        let manifest = try coordinator.stageObjects([part(f)], context: context, packageID: id())
        let root = try privateRoot(f)
        let preparation = try PeerAtomicIntakePreparation(
            coordinator: coordinator, index: index, privateRoot: root, context: context,
            packageID: manifest.packageID, contextToken: "custody", beforeSeal: {})
        let database = root.appendingPathComponent("preparation.sqlite")
        try FileManager.default.moveItem(at: database, to: root.appendingPathComponent("displaced.sqlite"))
        try Data("foreign".utf8).write(to: database)
        _ = chmod(database.path, 0o600)
        XCTAssertThrowsError(try preparation.step()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "storeBusy")
        }
        XCTAssertThrowsError(try preparation.close())
        XCTAssertEqual(try Data(contentsOf: database), Data("foreign".utf8))
        XCTAssertNil(try coordinator.journal.publication(manifest.packageID))
        try f.capacity()
    }
    func testPayloadLargerThanReadWindowResumesAndRetainsOriginalWithoutNewAuthority() throws {
        let f = try Fixture()
        // Estimate well below the fixture cap before creating the payload or transfer copies.
        let payloadLength = 1024 * 1024 + 17
        guard UInt64(payloadLength * 6) < AttachmentFixtureCapacity.fixtureCapBytes else {
            throw TractandaError("resourceLimit", "Preparation fixture estimate")
        }
        try f.capacity()
        let data = Data(repeating: 73, count: payloadLength)
        let base = try f.source.commit(CommitRequest(classID: "Item", operationID: "preparation-base"))
            .revision
        let upload = try f.source.beginAttachment(
            AttachmentUploadRequest(
                itemID: base.itemID, expectedRevisionID: base.revisionID,
                operationID: "preparation-payload", filename: "bounded.bin",
                mediaType: "application/octet-stream", byteCount: Int64(data.count),
                sha256: AuthorityRecordCodec.sha256(data)))
        var offset = 0
        while offset < data.count {
            try f.capacity()
            let end = min(offset + PeerPackage.maximumPayloadChunkBytes, data.count)
            _ = try f.source.appendAttachment(
                uploadID: XCTUnwrap(upload.uploadID), offset: Int64(offset),
                data: data.subdata(in: offset..<end))
            offset = end
        }
        let revision = try f.source.finishAttachment(uploadID: XCTUnwrap(upload.uploadID)).revision
        try f.activateAndOpen()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        var limits = PeerPackage.Limits()
        limits.maximumReadBytes = 384 * 1024
        let coordinator = coordinator(f, limits: limits)
        let quota = try StagingByteQuota(
            root: f.sourceRoot, ownerUID: tractanda_uid(), maximumBytes: 32 * 1024 * 1024)
        let payloads = try AttachmentPayloadStore(
            root: f.sourceRoot, ownerUID: tractanda_uid(),
            reserveBytes: limits.reserveBytes, stagingQuota: quota)
        let originals = try PeerOriginalTransfer(
            root: f.sourceRoot, ownerUID: tractanda_uid(),
            payloads: payloads, quota: quota, reserveBytes: limits.reserveBytes)
        coordinator.journal.originals = originals
        let revisionBytes = try RecordCodec.encode(revision)
        let item = PeerPackage.Object(
            kind: .item, id: revision.revisionID, length: revisionBytes.count,
            sha256: AuthorityRecordCodec.sha256(revisionBytes))
        let attachment = PeerPackage.Object(
            kind: .attachment, id: upload.attachment.attachmentID,
            length: data.count, sha256: AuthorityRecordCodec.sha256(data))
        let pageBytes = try JSON.encode(PeerPackage.Page(objects: [item, attachment], children: []))
        let page = PeerPackage.Object(
            kind: .index, id: try id(), length: pageBytes.count,
            sha256: AuthorityRecordCodec.sha256(pageBytes))
        let context = try coordinator.context(peerID: "local")
        let manifest = PeerPackage.Manifest(packageID: try id(), storeID: f.storeID, root: page)
        _ = try coordinator.journal.begin(context: context, manifestBytes: JSON.encode(manifest))
        for entry in [(page, pageBytes), (item, revisionBytes)] {
            _ = try coordinator.journal.append(
                context: context, packageID: manifest.packageID,
                object: entry.0, offset: 0, bytes: entry.1)
        }
        // The payload is already canonical. A fresh bridge must still hash it across bounded calls.
        let root = try privateRoot(f)
        let preparation = try PeerAtomicIntakePreparation(
            coordinator: coordinator, index: index, privateRoot: root, context: context,
            packageID: manifest.packageID, contextToken: "bounded-payload", beforeSeal: {})
        var call = 0
        var payloadReadCalls = Set<Int>()
        originals.didReadForTesting = { object, _ in
            if object.id == attachment.id { payloadReadCalls.insert(call) }
        }
        let beforeHead = try index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID))
        var complete = false
        for next in 1...100 {
            call = next
            complete = try preparation.step(maximumObjects: 1)
            if complete { break }
        }
        XCTAssertTrue(complete)
        XCTAssertGreaterThan(payloadReadCalls.count, 1, "Payload hashing must span native read windows")
        XCTAssertNotNil(try coordinator.journal.publication(manifest.packageID))
        XCTAssertEqual(try index.retainedAuthorityObject(id: item.id)?.descriptor, item)
        XCTAssertEqual(try index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)), beforeHead)
        try preparation.close()
        assertScratchRemoved(root)
        try f.capacity()
    }

    func testInsufficientPrivateAllowanceFailsBeforeCreatingOwnedFiles() throws {
        let f = try Fixture()
        try f.activateAndOpen()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        index.graphMaximumTemporaryBytes = 1024
        let coordinator = coordinator(f)
        let context = try coordinator.context(peerID: "local")
        let manifest = try coordinator.stageObjects([part(f)], context: context, packageID: id())
        let root = try privateRoot(f)
        XCTAssertThrowsError(
            try PeerAtomicIntakePreparation(
                coordinator: coordinator, index: index, privateRoot: root, context: context,
                packageID: manifest.packageID, contextToken: "bounded-storage", beforeSeal: {})
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        assertScratchRemoved(root)
        XCTAssertNil(try coordinator.journal.publication(manifest.packageID))
        try f.capacity()
    }

    func testPreparedHistoricalTokenAndPrivateDatabaseBackingRemainBounded() throws {
        let f = try Fixture()
        try f.activateAndOpen()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        index.graphMaximumTemporaryBytes = 8 * 1024 * 1024
        let coordinator = coordinator(f)
        let object = try part(f)
        let context = try coordinator.context(peerID: "local")
        let manifest = try coordinator.stageObjects([object], context: context, packageID: id())
        let prepared = PeerIntakeJournal.Publication(
            packageID: manifest.packageID,
            manifestDigest: AuthorityRecordCodec.sha256(try JSON.encode(manifest)), context: context,
            contextToken: "historical-prepared-request",
            arrivalMinute: try PeerIntakeJournal.currentArrivalMinute())
        try coordinator.journal.prepare(prepared)
        let root = try privateRoot(f)
        let preparation = try PeerAtomicIntakePreparation(
            coordinator: coordinator, index: index, privateRoot: root, context: context,
            packageID: manifest.packageID, contextToken: "fresh-request", beforeSeal: {})
        XCTAssertFalse(try preparation.step(maximumObjects: 1))
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                root.appendingPathComponent("preparation.sqlite").path,
                &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        func scalar(_ sql: String) throws -> String {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw TractandaError("fixture", "Cannot inspect private backing")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
                throw TractandaError("fixture", "Missing private backing evidence")
            }
            return String(cString: value)
        }
        XCTAssertEqual(try scalar("PRAGMA journal_mode"), "delete")
        XCTAssertEqual(
            try scalar(
                "SELECT count(*) FROM main.sqlite_master WHERE type='table' AND name LIKE 'peer_original_%'"),
            "7")
        // A canonical-only part has no payload requirements, but real descriptor tables must
        // live in the controlled main file rather than an anonymous SQLite TEMP database.
        XCTAssertEqual(try scalar("SELECT count(*) FROM main.authority_walk WHERE object<>''"), "2")
        _ = try drain(preparation)
        XCTAssertEqual(try coordinator.journal.publication(manifest.packageID), prepared)
        var actual: UInt64 = 0
        for name in [
            "preparation.sqlite", "preparation.sqlite-journal", "preparation.sqlite-wal",
            "preparation.sqlite-shm",
        ] {
            let path = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                actual += try FileMetadata.read(at: path).size
            }
        }
        XCTAssertLessThanOrEqual(actual, index.graphMaximumTemporaryBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("preparation.sqlite-wal").path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("preparation.sqlite-shm").path)
        )
        try preparation.close()
        assertScratchRemoved(root)
        try f.capacity()
    }

    func testActualPrivateDatabaseGrowthFailsClosedAndOwnedCleanupStillWorks() throws {
        let f = try Fixture()
        try f.activateAndOpen()
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        index.graphMaximumTemporaryBytes = 8 * 1024 * 1024
        let coordinator = coordinator(f)
        let context = try coordinator.context(peerID: "local")
        let manifest = try coordinator.stageObjects([part(f)], context: context, packageID: id())
        let root = try privateRoot(f)
        let preparation = try PeerAtomicIntakePreparation(
            coordinator: coordinator, index: index, privateRoot: root, context: context,
            packageID: manifest.packageID, contextToken: "actual-allocation", beforeSeal: {})
        // Sparse growth of this exact tiny owned fixture exercises real file-size accounting;
        // it neither fills a disk nor substitutes a fake available-space provider.
        let file = try FileHandle(forWritingTo: root.appendingPathComponent("preparation.sqlite"))
        try file.truncate(atOffset: index.graphMaximumTemporaryBytes + 4096)
        try file.close()
        XCTAssertThrowsError(try preparation.step(maximumObjects: 1)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertNil(try coordinator.journal.publication(manifest.packageID))
        try preparation.close()
        assertScratchRemoved(root)
        try f.capacity()
    }

}
