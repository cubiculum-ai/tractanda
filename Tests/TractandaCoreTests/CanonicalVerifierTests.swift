import CSQLite
import CTractandaPlatform
import Crypto
import Foundation
import XCTest

@testable import TractandaCore

final class CanonicalVerifierTests: XCTestCase {
    private actor FindingCollector {
        private var stored: [CanonicalVerifier.Finding] = []
        func append(_ findings: [CanonicalVerifier.Finding]) { stored.append(contentsOf: findings) }
        func all() -> [CanonicalVerifier.Finding] { stored }
    }

    private actor CatalogueAppender {
        private let index: ItemIndex
        private let row: ItemIndex.CatalogueRow
        private var didAppend = false
        init(path: String, row: ItemIndex.CatalogueRow) throws {
            self.index = try ItemIndex(path: path, create: false)
            self.row = row
        }
        func appendOnce() throws {
            guard !didAppend else { return }
            try index.upsertCatalogue(row)
            didAppend = true
        }
    }

    private struct Fixture {
        let root: URL
        let index: ItemIndex
        let snapshot: CanonicalVerifier.Snapshot
        let rows: [ItemIndex.CatalogueRow]

        func closeAndRemove() {
            index.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(_ records: [(String, Data)], missing: Set<String> = []) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-verifier-\(Identifier.make())")
        let items = root.appendingPathComponent("items", isDirectory: true)
        let indexDirectory = root.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: items.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: indexDirectory.path)

        let uid = tractanda_uid()
        var rows: [ItemIndex.CatalogueRow] = []
        for (revision, bytes) in records {
            let relative = "items/2026/09/27/12/00/\(revision)/\(revision).tractanda"
            let url = root.appendingPathComponent(relative)
            if !missing.contains(revision) {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var parent = url.deletingLastPathComponent()
                while parent.path.hasPrefix(items.path), parent.path != items.path {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o700], ofItemAtPath: parent.path)
                    parent.deleteLastPathComponent()
                }
                try bytes.write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let metadata = missing.contains(revision) ? nil : try FileMetadata.read(at: url)
            rows.append(
                ItemIndex.CatalogueRow(
                    revisionID: revision, itemID: revision, path: relative, parentID: nil,
                    actor: "test-owner", operationID: revision, size: metadata?.size ?? UInt64(bytes.count),
                    inode: metadata?.inode ?? 0, uid: metadata?.uid ?? uid, mode: metadata?.mode ?? 0o100600,
                    modificationSeconds: metadata?.modificationSeconds ?? 0,
                    modificationNanoseconds: metadata?.modificationNanoseconds ?? 0,
                    digest: Data(SHA256.hash(data: bytes))))
        }

        let dbPath = indexDirectory.appendingPathComponent("items.sqlite")
        let index = try ItemIndex(path: dbPath.path, create: true)
        try index.execute("BEGIN IMMEDIATE")
        try index.replaceCatalogue(identity: "verifier-test-store", rows: rows)
        try index.execute("COMMIT")
        let watermark = try catalogueWatermark(at: dbPath.path)
        return Fixture(
            root: root, index: index,
            snapshot: CanonicalVerifier.Snapshot(
                rootPath: root.path, ownerUID: uid, indexPath: dbPath.path,
                storeIdentity: "verifier-test-store", generation: "test-generation",
                catalogueWatermark: watermark),
            rows: rows)
    }

    private func catalogueWatermark(at path: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let database
        else { throw TractandaError("testError", "Could not open fixture catalogue.") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "SELECT COALESCE(MAX(rowid),0) FROM revision_catalog", -1, &statement, nil)
                == SQLITE_OK,
            let statement
        else { throw TractandaError("testError", "Could not read fixture watermark.") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TractandaError("testError", "Fixture watermark query failed.")
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func run(
        _ fixture: Fixture,
        seenPathByteLimit: Int = CanonicalVerifier.seenPathByteLimit,
        readMetadata: @escaping @Sendable (URL) throws -> FileMetadata = { try FileMetadata.read(at: $0) },
        onFindings: @escaping @Sendable ([CanonicalVerifier.Finding]) async throws -> Void
    ) async -> CanonicalVerifier.Result {
        await CanonicalVerifier.scan(
            fixture.snapshot, seenPathByteLimit: seenPathByteLimit,
            readMetadata: readMetadata, onFindings: onFindings)
    }

    func testPagedSeenMissingUnexpectedAndResourceCounters() async throws {
        let fixture = try makeFixture(
            [
                ("revision-a", Data("a".utf8)), ("revision-b", Data("b".utf8)),
                ("revision-c", Data("c".utf8)),
            ], missing: ["revision-b"])
        defer { fixture.closeAndRemove() }
        let orphan = fixture.root.appendingPathComponent("items/2026/09/27/orphan.tractanda")
        try FileManager.default.createDirectory(
            at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        var directory = orphan.deletingLastPathComponent()
        while directory.path.hasPrefix(fixture.root.appendingPathComponent("items").path),
            directory.path != fixture.root.appendingPathComponent("items").path
        {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            directory.deleteLastPathComponent()
        }
        try Data("orphan".utf8).write(to: orphan)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: orphan.path)

        let findings = FindingCollector()
        let result = await run(fixture) { await findings.append($0) }
        let found = await findings.all()
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.exactCatalogueCount, 3)
        XCTAssertEqual(result.exactFindingCount, 2)
        XCTAssertEqual(Set(found.map(\.kind)), [.missing, .unexpected])
        XCTAssertTrue(found.contains { $0.path == fixture.rows[1].path && $0.kind == .missing })
        XCTAssertTrue(
            found.contains { $0.path == "items/2026/09/27/orphan.tractanda" && $0.kind == .unexpected })
        XCTAssertLessThanOrEqual(result.resources.maximumPageRows, CanonicalVerifier.pageLimit)
        XCTAssertLessThanOrEqual(result.resources.maximumFindingsBatch, CanonicalVerifier.findingBatchLimit)
        XCTAssertGreaterThan(result.resources.temporaryPageLimit, 0)
        XCTAssertGreaterThan(result.resources.seenPathBytes, 0)
    }

    func testWatermarkExcludesRevisionCommittedAfterScanStarts() async throws {
        let fixture = try makeFixture([("revision-a", Data("a".utf8))])
        defer { fixture.closeAndRemove() }
        let orphan = fixture.root.appendingPathComponent("items/unexpected")
        try Data("x".utf8).write(to: orphan)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: orphan.path)
        let newPath = "items/2026/09/27/12/00/revision-later/revision-later.tractanda"
        let later = ItemIndex.CatalogueRow(
            revisionID: "revision-later", itemID: "revision-later", path: newPath,
            parentID: nil, actor: "test-owner", operationID: "revision-later", size: 1,
            inode: 0, uid: tractanda_uid(), mode: 0o100600,
            modificationSeconds: 0, modificationNanoseconds: 0,
            digest: Data(SHA256.hash(data: Data("later".utf8))))
        let appender = try CatalogueAppender(path: fixture.snapshot.indexPath, row: later)
        let findings = FindingCollector()
        let result = await run(fixture) { batch in
            await findings.append(batch)
            try await appender.appendOnce()
        }
        let found = await findings.all()
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.exactCatalogueCount, 1)
        XCTAssertFalse(found.contains { $0.revisionID == "revision-later" })
    }

    func testChangedMetadataUsesDigestToDistinguishMetadataOnlyFromContentChange() async throws {
        let fixture = try makeFixture([
            ("revision-a", Data("same-size".utf8)), ("revision-b", Data("same-size".utf8)),
        ])
        defer { fixture.closeAndRemove() }
        for revision in ["revision-a", "revision-b"] {
            let row = try XCTUnwrap(fixture.rows.first { $0.revisionID == revision })
            let url = fixture.root.appendingPathComponent(row.path)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: url.path)
            if revision == "revision-b" { try Data("diff-size".utf8).write(to: url) }
        }
        let findings = FindingCollector()
        let result = await run(fixture) { await findings.append($0) }
        let found = await findings.all()
        XCTAssertEqual(result.status, .complete)
        XCTAssertTrue(found.contains { $0.revisionID == "revision-a" && $0.kind == .metadataChanged })
        XCTAssertTrue(found.contains { $0.revisionID == "revision-b" && $0.kind == .changed })
    }

    func testCancellationDoesNotEmitMissingFindings() async throws {
        let fixture = try makeFixture([("revision-a", Data("a".utf8)), ("revision-b", Data("b".utf8))])
        defer { fixture.closeAndRemove() }
        let cancelledFindings = FindingCollector()
        let cancelled = await run(
            fixture,
            readMetadata: { url in
                withUnsafeCurrentTask { $0?.cancel() }
                return try FileMetadata.read(at: url)
            },
            onFindings: { await cancelledFindings.append($0) })
        let cancelledFound = await cancelledFindings.all()
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertNil(cancelled.exactFindingCount)
        XCTAssertFalse(cancelledFound.contains { $0.kind == .missing })
    }

    func testIOFailureIsIncompleteWithoutMissingFindings() async throws {
        let fixture = try makeFixture([("revision-a", Data("a".utf8)), ("revision-b", Data("b".utf8))])
        defer { fixture.closeAndRemove() }
        let ioFindings = FindingCollector()
        let failed = await run(
            fixture, readMetadata: { _ in throw FileMetadataError.invalidPath },
            onFindings: { await ioFindings.append($0) })
        let ioFound = await ioFindings.all()
        XCTAssertEqual(failed.status, .incomplete)
        XCTAssertNil(failed.exactCatalogueCount)
        XCTAssertFalse(ioFound.contains { $0.kind == .missing })
    }

    func testSeenTableCapFailsClosedAndReaderClosesForLaterWriter() async throws {
        let fixture = try makeFixture([("revision-a", Data("a".utf8))])
        defer { fixture.closeAndRemove() }
        let findings = FindingCollector()
        let result = await run(fixture, seenPathByteLimit: 1) { await findings.append($0) }
        let found = await findings.all()
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertNil(result.exactFindingCount)
        XCTAssertFalse(found.contains { $0.kind == .missing })
        XCTAssertEqual(result.resources.seenPathBytes, 0)
        let later = ItemIndex.CatalogueRow(
            revisionID: "revision-b", itemID: "revision-b", path: "items/revision-b.tractanda",
            parentID: nil, actor: "test-owner", operationID: "revision-b", size: 0,
            inode: 0, uid: tractanda_uid(), mode: 0o100600,
            modificationSeconds: 0, modificationNanoseconds: 0,
            digest: Data(repeating: 0, count: 32))
        XCTAssertNoThrow(try fixture.index.upsertCatalogue(later))
    }

    func testLegalStagingNameAndConfirmedMissingRecordBlocksReadsUntilRebuild() throws {
        let staging = URL(fileURLWithPath: "\(UUID().uuidString).tractanda.Abc123")
        XCTAssertTrue(CanonicalVerifier.isLegalStagingName(staging.lastPathComponent))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-verifier-store-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let item = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "item"))
            .revision
        let snapshot = try store.verificationSnapshot()
        XCTAssertGreaterThan(snapshot.catalogueWatermark, 0)
        let path = try XCTUnwrap(store.exportCatalogueForVerification().first?.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try store.applyVerification(
            [.init(kind: .missing, path: path, revisionID: item.revisionID, detail: "missing")],
            scannedGeneration: "test")
        XCTAssertEqual(store.canonicalVerificationStatus["state"] as? String, "inconsistent")
        XCTAssertThrowsError(try store.get(item.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "recoveryRequired")
        }
        try store.rebuildIndex()
        XCTAssertThrowsError(try store.get(item.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "notFound")
        }
    }

    func testConfirmedFindingDetailsStayBoundedWhileCountRemainsExact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-verifier-details-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        store.verificationDetailLimitForTesting = 2
        try store.beginVerificationScan(generation: "small-scan")
        try store.applyVerification(
            (0..<3).map {
                .init(kind: .unsafe, path: "items/unsafe-\($0)", revisionID: nil, detail: "unsafe")
            }, scannedGeneration: "small-scan")
        XCTAssertEqual(store.canonicalVerificationStatus["state"] as? String, "inconsistent")
        XCTAssertEqual(store.canonicalVerificationStatus["findingCount"] as? Int, 3)
        XCTAssertEqual(
            (store.canonicalVerificationStatus["findings"] as? [[String: String]])?.count, 2)
    }

    func testCoordinatorVerificationDrainsOnCleanShutdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-verifier-coordinator-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try await ServiceCoordinator(opening: root)
        await coordinator.startCanonicalVerification(every: .seconds(3600))
        await coordinator.close()
        _ = try ItemStore(root: root)
    }
}
