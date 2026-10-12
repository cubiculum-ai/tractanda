import CSQLite
import Foundation
import XCTest

@testable import TractandaVectors

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class Vec1GenerationTests: XCTestCase {
    /// Deterministic test identities; production injects Core's real node/time UUIDv1 generator.
    private func generationSupplier() -> () throws -> String {
        var ticks: UInt64 = 0
        return {
            ticks += 1
            return String(format: "%08llx-0000-1000-8000-0123456789ab", ticks)
        }
    }

    private let fixtureCap: UInt64 = 16 * 1024 * 1024
    private let freeReserve: UInt64 = 10 * 1024 * 1024 * 1024

    private func capacity(_ directory: URL, expected: UInt64 = 1 * 1024 * 1024) throws {
        guard expected <= fixtureCap else { throw NSError(domain: "fixtureCap", code: 1) }
        var available = statvfs()
        guard statvfs(directory.path, &available) == 0, available.f_frsize > 0 else {
            throw NSError(domain: "fixtureCapacityUnknown", code: 1)
        }
        let bytes = UInt64(available.f_bavail).multipliedReportingOverflow(by: UInt64(available.f_frsize))
        guard !bytes.overflow, bytes.partialValue >= freeReserve + expected else {
            throw NSError(domain: "fixtureFreeReserve", code: 1)
        }
        if expected == 0 { return }
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        var allocation: UInt64 = 0
        for child in children {
            var info = stat()
            guard lstat(child.path, &info) == 0, info.st_blocks >= 0 else {
                throw NSError(domain: "fixtureStat", code: 1)
            }
            let blocks = UInt64(info.st_blocks).multipliedReportingOverflow(by: 512)
            let sum = allocation.addingReportingOverflow(blocks.partialValue)
            guard !blocks.overflow, !sum.overflow else { throw NSError(domain: "fixtureOverflow", code: 1) }
            allocation = sum.partialValue
        }
        guard allocation <= fixtureCap else { throw NSError(domain: "fixtureAllocationCap", code: 1) }
    }

    private struct FixtureGuard {
        let check: () throws -> Void
        func callAsFunction() throws { try check() }
    }

    private func fixture(_ run: (String, FixtureGuard) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory
        try capacity(parent, expected: 0)  // Real f_bavail before creating the tiny fixture.
        let root = parent.appendingPathComponent("vec1-generation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try capacity(root)
        try run(
            root.appendingPathComponent("semantic.sqlite").path,
            FixtureGuard(check: { try self.capacity(root) }))
    }

    private func record(
        _ item: String = "item", revision: String = "r1", hash: String = "h1", ordinal: Int = 0,
        vector: [Float] = [1, 0]
    ) -> VectorRecord {
        VectorRecord(
            id: item + ":" + String(ordinal), itemID: item, revisionID: revision, contentHash: hash,
            chunkIndex: ordinal, text: "known passage \(ordinal)", vector: vector)
    }

    func testStagingCountFailureAndDiscardNeverReplaceCompleteGeneration() throws {
        try fixture { path, guardCapacity in
            let index = try Vec1Index(
                path: path, dimensions: 2, profileID: "profile", makeGenerationID: generationSupplier())
            try index.replace(itemID: "item", records: [record()])
            let stage = try index.beginGeneration(itemID: "item", revisionID: "r2", contentHash: "h2")
            try index.appendGeneration(stage, records: [record(revision: "r2", hash: "h2", vector: [0, 1])])
            XCTAssertEqual(try index.itemMetadata(itemID: "item")?.revisionID, "r1")
            XCTAssertEqual(
                try index.search(query: [1, 0], allowedItemIDs: ["item"], limit: 1).first?.revisionID, "r1")
            XCTAssertThrowsError(try index.publishGeneration(stage, expectedRecordCount: 2))
            XCTAssertThrowsError(
                try index.appendGeneration(
                    stage,
                    records: [
                        record(revision: "r2", hash: "h2", ordinal: 1),
                        record(revision: "r2", hash: "h2", ordinal: 1),
                    ]))
            try guardCapacity()
            try index.discardGeneration(stage)
            XCTAssertThrowsError(try index.publishGeneration(stage, expectedRecordCount: 1))
            XCTAssertEqual(try index.cleanupUnpublished(limit: 1), 1)
            XCTAssertEqual(try index.records().map(\.revisionID), ["r1"])
        }
    }

    func testPublicationReopenAndRebindUseOnlyCompleteCurrentGeneration() throws {
        try fixture { path, guardCapacity in
            do {
                let index = try Vec1Index(
                    path: path, dimensions: 2, profileID: "profile", makeGenerationID: generationSupplier())
                try index.replace(itemID: "item", records: [record()])
                let stage = try index.beginGeneration(itemID: "item", revisionID: "r2", contentHash: "h2")
                try index.appendGeneration(
                    stage,
                    records: [
                        record(revision: "r2", hash: "h2"), record(revision: "r2", hash: "h2", ordinal: 1),
                    ])
                try index.publishGeneration(stage, expectedRecordCount: 2)
                XCTAssertThrowsError(try index.discardGeneration(stage))
                XCTAssertEqual(try index.itemMetadata(itemID: "item")?.recordCount, 2)
                let pending = try index.beginGeneration(itemID: "item", revisionID: "r3", contentHash: "h3")
                try index.appendGeneration(pending, records: [record(revision: "r3", hash: "h3")])
                try guardCapacity()
            }
            let index = try Vec1Index(
                path: path, dimensions: 2, profileID: "profile", makeGenerationID: generationSupplier())
            XCTAssertEqual(try index.records().map(\.revisionID), ["r2", "r2"])
            let pending = try XCTUnwrap(index.stagingGenerationsPage(limit: 1).first)
            // A restart owner has explicitly fenced this unfinished job before disposal.
            try index.discardGeneration(pending)
            _ = try index.cleanupUnpublished(limit: 1)
            let vectors = try index.records().map(\.vector)
            try index.updateRevision(itemID: "item", revisionID: "r4", contentHash: "h2")
            XCTAssertEqual(try index.itemMetadata(itemID: "item")?.revisionID, "r4")
            XCTAssertEqual(try index.records().map(\.vector), vectors)
            XCTAssertEqual(try index.records().map(\.revisionID), ["r4", "r4"])
            try guardCapacity()
        }
    }

    func testBoundedAppendAndCleanupProtectAnotherLiveToken() throws {
        try fixture { path, guardCapacity in
            let index = try Vec1Index(
                path: path, dimensions: 2, profileID: "profile", makeGenerationID: generationSupplier())
            let old = try index.beginGeneration(itemID: "item", revisionID: "r1", contentHash: "h1")
            for offset in stride(from: 0, to: 129, by: 16) {
                try guardCapacity()
                try index.appendGeneration(
                    old, records: (offset..<min(offset + 16, 129)).map { record(ordinal: $0) })
            }
            try index.publishGeneration(old, expectedRecordCount: 129)
            let other = try index.beginGeneration(itemID: "other", revisionID: "r1", contentHash: "h1")
            try index.appendGeneration(other, records: [record("other")])
            XCTAssertThrowsError(
                try index.appendGeneration(other, records: (0..<17).map { record("other", ordinal: $0) }))
            try index.replace(itemID: "item", records: [record(revision: "r2", hash: "h2")])
            XCTAssertEqual(try index.cleanupUnpublished(limit: 16), 16)
            XCTAssertEqual(try index.stagingGenerationsPage().map(\.generationID), [other.generationID])
            try index.publishGeneration(other, expectedRecordCount: 1)
            XCTAssertEqual(try index.itemMetadata(itemID: "other")?.recordCount, 1)
            try guardCapacity()
        }
    }

    func testStreamingCurrentFiltersDeduplicateAndClearFailureBeforeNextQuery() throws {
        try fixture { path, guardCapacity in
            let index = try Vec1Index(
                path: path, dimensions: 2, profileID: "profile", makeGenerationID: generationSupplier())
            try index.replace(itemID: "private", records: [record("private")])
            try index.replace(itemID: "visible", records: [record("visible", vector: [0, 1])])
            let current = Vec1RecordFilter(itemID: "visible", revisionID: "r1", contentHash: "h1")
            let hits = try index.searchBestPerItem(query: [1, 0], limit: 1) { visit in try visit(current) }
            XCTAssertEqual(hits.map(\.itemID), ["visible"])
            XCTAssertThrowsError(
                try index.searchBestPerItem(query: [1, 0], limit: 1) { visit in
                    try visit(current)
                    try visit(current)
                })
            XCTAssertTrue(try index.searchBestPerItem(query: [1, 0], limit: 1) { _ in }.isEmpty)
            XCTAssertTrue(
                try index.searchBestPerItem(query: [1, 0], limit: 1) { visit in
                    try visit(Vec1RecordFilter(itemID: "visible", revisionID: "stale", contentHash: "h1"))
                }.isEmpty)
            XCTAssertEqual(try index.itemMetadataPage(limit: 1).map(\.itemID), ["private"])
            XCTAssertEqual(try index.itemMetadataPage(after: "private", limit: 1).map(\.itemID), ["visible"])
            XCTAssertThrowsError(try index.itemMetadataPage(limit: 129))
            try guardCapacity()
        }
    }
    func testPendingWindowIsOperationalAndCompletedWorkDoesNotExhaustIt() throws {
        try fixture { path, guardCapacity in
            let index = try Vec1Index(
                path: path, dimensions: 2, profileID: "profile", makeGenerationID: generationSupplier())
            var tokens: [Vec1Generation] = []
            for number in 0..<64 {
                tokens.append(
                    try index.beginGeneration(
                        itemID: "pending-" + String(number), revisionID: "r1", contentHash: "h1"))
                try guardCapacity()
            }
            XCTAssertThrowsError(
                try index.beginGeneration(itemID: "overflow", revisionID: "r1", contentHash: "h1"))
            for token in tokens { try index.discardGeneration(token) }
            _ = try index.cleanupUnpublished()
            for number in 0..<65 {
                let item = "complete-" + String(number)
                let token = try index.beginGeneration(itemID: item, revisionID: "r1", contentHash: "h1")
                try index.appendGeneration(token, records: [record(item)])
                try index.publishGeneration(token, expectedRecordCount: 1)
                try guardCapacity()
            }
            XCTAssertTrue(try index.stagingGenerationsPage().isEmpty)
            XCTAssertEqual(try index.itemMetadataPage(limit: 128).count, 65)
        }
    }

    func testPolicyRejectsUnknownCapacityAndPostWriteFailureRollsBackBatch() throws {
        try fixture { path, guardCapacity in
            var failBefore = false
            var failAfter = false
            var observed: [Vec1WriteBatch.Phase] = []
            let index = try Vec1Index(
                path: path, dimensions: 2, profileID: "profile", makeGenerationID: generationSupplier(),
                writeBoundary: { batch in
                    try guardCapacity()
                    XCTAssertLessThanOrEqual(batch.recordCount, 16)
                    observed.append(batch.phase)
                    if batch.phase == .beforeAppend && failBefore {
                        throw NSError(domain: "unknownAvailableBytes", code: 1)
                    }
                    if batch.phase == .afterAppend && failAfter {
                        throw NSError(domain: "observedAllocationOverCap", code: 1)
                    }
                })
            let token = try index.beginGeneration(itemID: "item", revisionID: "r1", contentHash: "h1")
            failBefore = true
            observed = []
            XCTAssertThrowsError(try index.appendGeneration(token, records: [record()]))
            failBefore = false
            failAfter = true
            XCTAssertThrowsError(try index.appendGeneration(token, records: [record()]))
            XCTAssertThrowsError(try index.publishGeneration(token, expectedRecordCount: 1))
            XCTAssertNil(try index.itemMetadata(itemID: "item"))
            failAfter = false
            // The rejected row/count really rolled back.
            try index.appendGeneration(token, records: [record()])
            try index.publishGeneration(token, expectedRecordCount: 1)
            XCTAssertEqual(try index.itemMetadata(itemID: "item")?.recordCount, 1)
            XCTAssertEqual(
                observed,
                [
                    .beforeAppend, .rollback, .beforeAppend, .afterAppend, .rollback, .beforeAppend,
                    .afterAppend, .afterCommit,
                    .promotion,
                ])
        }
    }

    func testInjectedIdentityIsCanonicalRFCUUIDv1BeforeMutationAndSurvivesReopen() throws {
        try fixture { path, guardCapacity in
            var supplied: String?
            var ticks: UInt64 = 0
            var pendingID: String?
            func ledgerCount() throws -> Int32 {
                var database: OpaquePointer?
                guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                    throw NSError(domain: "testRead", code: 1)
                }
                defer { sqlite3_close(database) }
                var statement: OpaquePointer?
                guard
                    sqlite3_prepare_v2(database, "SELECT count(*) FROM vector_ledger", -1, &statement, nil)
                        == SQLITE_OK
                else { throw NSError(domain: "testRead", code: 2) }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw NSError(domain: "testRead", code: 3)
                }
                return sqlite3_column_int(statement, 0)
            }
            do {
                let index = try Vec1Index(
                    path: path, dimensions: 2, profileID: "profile",
                    makeGenerationID: {
                        if let supplied { return supplied }
                        ticks += 1
                        return String(format: "%08llx-0000-1000-8000-0123456789ab", ticks)
                    })
                try index.replace(itemID: "item", records: [record()])
                try index.replace(itemID: "item", records: [record(revision: "r2", hash: "h2")])
                let before = try ledgerCount()
                XCTAssertEqual(before, 2)  // One retained obsolete generation plus the current head.
                for invalid in [
                    "00000000-0000-4000-8000-0123456789ab", "00000000-0000-1000-c000-0123456789ab",
                    "00000000-0000-1000-8000-0123456789AB", "not-a-uuid",
                ] {
                    supplied = invalid
                    XCTAssertThrowsError(
                        try index.beginGeneration(itemID: "new", revisionID: "r1", contentHash: "h1"))
                    XCTAssertEqual(try ledgerCount(), before)
                    XCTAssertTrue(try index.stagingGenerationsPage().isEmpty)
                }
                supplied = nil
                let pending = try index.beginGeneration(itemID: "next", revisionID: "r1", contentHash: "h1")
                pendingID = pending.generationID
                let uuid = try XCTUnwrap(UUID(uuidString: pending.generationID))
                var raw = uuid.uuid
                withUnsafeBytes(of: &raw) { bytes in
                    XCTAssertEqual(bytes[6] >> 4, 1)
                    XCTAssertEqual(bytes[8] & 0xC0, 0x80)
                }
                XCTAssertEqual(uuid.uuidString.lowercased(), pending.generationID)
                try guardCapacity()
            }
            let reopened = try Vec1Index(
                path: path, dimensions: 2, profileID: "profile", makeGenerationID: generationSupplier())
            XCTAssertEqual(try reopened.stagingGenerationsPage().first?.generationID, pendingID)
            XCTAssertEqual(try reopened.records().map(\.id), ["item:0"])
        }
    }

}
