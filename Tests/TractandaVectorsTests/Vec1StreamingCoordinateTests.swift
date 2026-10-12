import CSQLite
import Foundation
import XCTest

@testable import TractandaVectors

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class Vec1StreamingCoordinateTests: XCTestCase {
    private func supplier() -> () throws -> String {
        var tick = 0
        return {
            tick += 1
            return String(format: "%08x-0000-1000-8000-0123456789ab", tick)
        }
    }
    private struct FixtureGuard {
        let check: () throws -> Void
        func callAsFunction() throws { try check() }
    }
    private func fixture(_ body: (String, FixtureGuard) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vec-stream-" + UUID().uuidString)
        let cap: UInt64 = 16 * 1024 * 1024
        let reserve: UInt64 = 10 * 1024 * 1024 * 1024
        func free(_ path: URL) throws {
            var value = statvfs()
            guard statvfs(path.path, &value) == 0, value.f_frsize > 0 else {
                throw NSError(domain: "unknownCapacity", code: 1)
            }
            let bytes = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_frsize))
            guard !bytes.overflow, bytes.partialValue >= reserve + cap else {
                throw NSError(domain: "freeReserve", code: 1)
            }
        }
        try free(root.deletingLastPathComponent())  // <1MiB expected; reserve a16MiB cap before writing.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func check() throws {
            try free(root)
            var bytes: UInt64 = 0
            for path in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            {
                var info = stat()
                guard lstat(path.path, &info) == 0, info.st_blocks >= 0 else {
                    throw NSError(domain: "unknownAllocation", code: 1)
                }
                let allocated = UInt64(info.st_blocks).multipliedReportingOverflow(by: 512)
                let sum = bytes.addingReportingOverflow(allocated.partialValue)
                guard !allocated.overflow, !sum.overflow else {
                    throw NSError(domain: "allocationOverflow", code: 1)
                }
                bytes = sum.partialValue
            }
            guard bytes <= cap else { throw NSError(domain: "fixtureCap", code: 1) }
        }
        try body(root.appendingPathComponent("vectors.sqlite").path, FixtureGuard(check: check))
        try check()
    }
    private func record(
        _ item: String, ordinal: Int = 0, revision: String = "r1", hash: String = "h1",
        vector: [Float] = [1, 0]
    ) -> VectorRecord {
        let text = "e\u{301} 😃 Café"
        return .init(
            id: item + ":" + String(ordinal), itemID: item, revisionID: revision, contentHash: hash,
            chunkIndex: ordinal, text: text, vector: vector, unitOrdinal: 98,
            byteStart: 1_099_511_627_777, byteEnd: 1_099_511_627_777 + Int64(text.utf8.count))
    }
    func testCoordinatesSurvivePublishReopenRebindAndPreRankingFilter() throws {
        try fixture { path, check in
            do {
                let index = try Vec1Index(
                    path: path, dimensions: 2, profileID: "p", makeGenerationID: supplier(),
                    writeBoundary: { _ in try check() })
                for number in 0..<3 {
                    try index.replace(itemID: "hidden\(number)", records: [record("hidden\(number)")])
                }
                try index.replace(itemID: "visible", records: [record("visible", vector: [0, 1])])
                try index.updateRevision(itemID: "visible", revisionID: "r2", contentHash: "h1")
            }
            let index = try Vec1Index(path: path, dimensions: 2, profileID: "p", makeGenerationID: supplier())
            let hits = try index.searchBestPerItem(query: [1, 0], limit: 1) { visit in
                try visit(.init(itemID: "visible", revisionID: "r2", contentHash: "h1"))
            }
            let hit = try XCTUnwrap(hits.first)
            XCTAssertEqual(hit.itemID, "visible")
            XCTAssertEqual(hit.unitOrdinal, 98)
            XCTAssertEqual(hit.byteStart, 1_099_511_627_777)
            XCTAssertEqual(hit.byteEnd - hit.byteStart, Int64(hit.text.utf8.count))
            XCTAssertTrue(
                try index.searchBestPerItem(query: [1, 0], limit: 1) { visit in
                    try visit(.init(itemID: "visible", revisionID: "r2", contentHash: "changed"))
                }.isEmpty)
            var cursor: String?
            var count = 0
            while let head = try index.itemMetadataPage(after: cursor, limit: 1).first {
                count += 1
                cursor = head.itemID
            }
            XCTAssertEqual(count, 4)
        }
    }
    func testCommittedFailureRetainsExactChargeAcrossCrashAndExplicitDisposal() throws {
        try fixture { path, check in
            var failed = false
            var token: Vec1Generation?
            var debt: Int64 = 0
            do {
                let index = try Vec1Index(
                    path: path, dimensions: 2, profileID: "p", makeGenerationID: supplier(),
                    writeBoundary: { batch in
                        try check()
                        if batch.phase == .afterCommit, batch.recordCount == 1, !failed {
                            failed = true
                            throw NSError(domain: "postCommitFreeReserve", code: 1)
                        }
                    })
                token = try index.beginGeneration(itemID: "item", revisionID: "r1", contentHash: "h1")
                let generation = try XCTUnwrap(token)
                let header = try index.generationEncodedBytes(generation)
                XCTAssertThrowsError(try index.appendGeneration(generation, records: [record("item")]))
                debt = try index.generationEncodedBytes(generation)
                XCTAssertGreaterThan(debt, header)
                XCTAssertNil(try index.itemMetadata(itemID: "item"))
                XCTAssertEqual(try index.retainedWorkPage(limit: 1).first?.encodedBytes, debt)
            }
            var refunded: Int64 = 0
            let reopened = try Vec1Index(
                path: path, dimensions: 2, profileID: "p", makeGenerationID: supplier(),
                writeBoundary: { batch in
                    try check()
                    if batch.phase == .disposal { refunded += batch.retainedEncodedBytes }
                })
            let generation = try XCTUnwrap(reopened.stagingGenerationsPage(limit: 1).first)
            XCTAssertEqual(generation, token)
            XCTAssertEqual(try reopened.generationEncodedBytes(generation), debt)
            try reopened.discardGeneration(generation)
            XCTAssertEqual(refunded, 0, "revocation does not refund retained bytes")
            XCTAssertEqual(try reopened.cleanupUnpublished(limit: 1), 1)
            XCTAssertEqual(refunded, debt)
            XCTAssertTrue(try reopened.retainedWorkPage(limit: 1).isEmpty)
        }
    }
    func testCoordinateMismatchAndOldSourceSchemaFailClosed() throws {
        try fixture { path, check in
            do {
                let index = try Vec1Index(
                    path: path, dimensions: 2, profileID: "p", makeGenerationID: supplier())
                let token = try index.beginGeneration(itemID: "item", revisionID: "r1", contentHash: "h1")
                let bad = VectorRecord(
                    id: "bad", itemID: "item", revisionID: "r1", contentHash: "h1", chunkIndex: 0,
                    text: "😃", vector: [1, 0], unitOrdinal: 0, byteStart: 0, byteEnd: 1)
                XCTAssertThrowsError(try index.appendGeneration(token, records: [bad]))
                XCTAssertThrowsError(try index.publishGeneration(token, expectedRecordCount: 1))
                try check()
            }
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
            XCTAssertEqual(
                sqlite3_exec(
                    database, "UPDATE vector_index_metadata SET value='2' WHERE key='formatVersion'", nil,
                    nil, nil), SQLITE_OK)
            sqlite3_close(database)
            XCTAssertThrowsError(
                try Vec1Index(path: path, dimensions: 2, profileID: "p", makeGenerationID: supplier()))
        }
    }
    private func insertStaleCandidates(_ ids: [String], path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw NSError(domain: "fixtureOpen", code: 1)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, "INSERT OR IGNORE INTO vector_gc_candidate VALUES (?1)", -1, &statement, nil)
                == SQLITE_OK
        else { throw NSError(domain: "fixturePrepare", code: 1) }
        defer { sqlite3_finalize(statement) }
        for id in ids {
            guard
                sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    == SQLITE_OK,
                sqlite3_step(statement) == SQLITE_DONE
            else { throw NSError(domain: "fixtureWrite", code: 1) }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
    }
    func testCleanupSeeksOnlyRetiredCandidatesAndProgressesPastProtectedHeaders() throws {
        try fixture { path, check in
            let index = try Vec1Index(
                path: path, dimensions: 2, profileID: "p", makeGenerationID: supplier(),
                writeBoundary: { _ in try check() })
            let active = try index.beginGeneration(itemID: "active", revisionID: "r1", contentHash: "h1")
            for offset in [0, 16] {
                try index.appendGeneration(
                    active, records: (offset..<(offset + 16)).map { record("active", ordinal: $0) })
            }
            try index.publishGeneration(active, expectedRecordCount: 32)
            let staging = try index.beginGeneration(itemID: "staging", revisionID: "r1", contentHash: "h1")
            try index.appendGeneration(staging, records: [record("staging")])
            XCTAssertEqual(try index.cleanupUnpublished(limit: 1), 0)
            XCTAssertEqual(index.cleanupStatsForTesting.candidateGenerations, 0)
            XCTAssertEqual(index.cleanupStatsForTesting.rowsExamined, 0)
            XCTAssertLessThan(
                index.cleanupStatsForTesting.candidateVMSteps, 30,
                "idle cleanup cannot traverse the protected32-row prefix")
            let first = try index.beginGeneration(itemID: "retiredA", revisionID: "r1", contentHash: "h1")
            let second = try index.beginGeneration(itemID: "retiredB", revisionID: "r1", contentHash: "h1")
            try index.appendGeneration(first, records: (0..<3).map { record("retiredA", ordinal: $0) })
            try index.appendGeneration(second, records: [record("retiredB")])
            try index.discardGeneration(first)
            try index.discardGeneration(second)
            try insertStaleCandidates([active.generationID, staging.generationID], path: path)
            XCTAssertEqual(try index.cleanupUnpublished(limit: 1), 1)
            XCTAssertEqual(index.cleanupStatsForTesting.candidateGenerations, 3)
            XCTAssertEqual(index.cleanupStatsForTesting.rowsExamined, 1)
            XCTAssertEqual(index.cleanupStatsForTesting.cursor, first.generationID)
            XCTAssertLessThan(index.cleanupStatsForTesting.rowVMSteps, 40)
            XCTAssertEqual(try index.cleanupUnpublished(limit: 1), 1)
            XCTAssertEqual(index.cleanupStatsForTesting.cursor, second.generationID)
            XCTAssertEqual(index.cleanupStatsForTesting.headersAcknowledged, 1)
            let plans = try index.cleanupQueryPlansForTesting()
            XCTAssertTrue(plans[0].contains("SEARCH") && plans[0].contains("PRIMARY KEY"), plans[0])
            XCTAssertTrue(plans[1].contains("SEARCH") && plans[1].contains("vector_ledger_gc"), plans[1])
            XCTAssertFalse(plans.joined().contains("SCAN vector_ledger"))
            XCTAssertEqual(try index.itemMetadata(itemID: "active")?.recordCount, 32)
            XCTAssertTrue(try index.stagingGenerationsPage().contains(staging))
            try check()
        }
    }
    func testFailedDisposalKeepsDurableProofAttemptsEveryObserverAndReplaysAfterCrash() throws {
        try fixture { path, check in
            var charges: [String: Int64] = [:]
            var attempted: [String] = []
            var rejected: String?
            var receipt: Vec1Generation?
            var protected: Vec1Generation?
            var firstCharge: Int64 = 0
            do {
                let index = try Vec1Index(
                    path: path, dimensions: 2, profileID: "p", makeGenerationID: supplier(),
                    writeBoundary: { batch in
                        try check()
                        if batch.phase == .afterCommit {
                            charges[batch.generationID] = batch.retainedEncodedBytes
                        }
                        if batch.phase == .promotion { charges[batch.generationID] = 0 }
                        if batch.phase == .disposal {
                            attempted.append(batch.generationID)
                            if batch.generationID == rejected {
                                throw NSError(domain: "beforeQuotaObservation", code: 1)
                            }
                            charges[batch.generationID] = 0
                        }
                    })
                let active = try index.beginGeneration(itemID: "active", revisionID: "r1", contentHash: "h1")
                try index.appendGeneration(active, records: [record("active")])
                try index.publishGeneration(active, expectedRecordCount: 1)
                let staging = try index.beginGeneration(
                    itemID: "staging", revisionID: "r1", contentHash: "h1")
                try index.appendGeneration(staging, records: [record("staging")])
                protected = staging
                let first = try index.beginGeneration(itemID: "first", revisionID: "r1", contentHash: "h1")
                let second = try index.beginGeneration(itemID: "second", revisionID: "r1", contentHash: "h1")
                try index.appendGeneration(first, records: [record("first")])
                try index.appendGeneration(second, records: [record("second")])
                try index.discardGeneration(first)
                try index.discardGeneration(second)
                rejected = first.generationID
                receipt = first
                firstCharge = try index.generationEncodedBytes(first)
                XCTAssertThrowsError(try index.cleanupUnpublished(limit: 2))
                XCTAssertEqual(
                    attempted, [first.generationID, second.generationID],
                    "a failing observer cannot skip another committed disposal")
                XCTAssertEqual(charges[first.generationID], firstCharge)
                XCTAssertEqual(charges[second.generationID], 0)
                XCTAssertEqual(
                    try index.retainedWorkPage().first(where: { $0.generationID == first.generationID })?
                        .state, "disposed")
                XCTAssertFalse(
                    try index.retainedWorkPage().contains(where: { $0.generationID == second.generationID }))
                XCTAssertEqual(try index.itemMetadata(itemID: "active")?.recordCount, 1)
                XCTAssertTrue(try index.stagingGenerationsPage().contains(staging))
            }
            let first = try XCTUnwrap(receipt)
            do {
                let index = try Vec1Index(
                    path: path, dimensions: 2, profileID: "p", makeGenerationID: supplier(),
                    writeBoundary: { batch in
                        try check()
                        if batch.phase == .disposal {
                            XCTAssertEqual(batch.generationID, first.generationID)
                            charges[batch.generationID] = 0
                            throw NSError(domain: "crashAfterAbsoluteObservationBeforeReceiptACK", code: 1)
                        }
                    })
                XCTAssertEqual(try index.generationEncodedBytes(first), firstCharge)
                XCTAssertThrowsError(try index.cleanupUnpublished(limit: 1))
                XCTAssertEqual(charges[first.generationID], 0)
                XCTAssertTrue(
                    try index.retainedWorkPage().contains(where: {
                        $0.generationID == first.generationID && $0.state == "disposed"
                    }))
            }
            var replayed = 0
            let final = try Vec1Index(
                path: path, dimensions: 2, profileID: "p", makeGenerationID: supplier(),
                writeBoundary: { batch in
                    try check()
                    if batch.phase == .disposal {
                        replayed += 1
                        charges[batch.generationID] = 0
                    }
                })
            XCTAssertEqual(try final.cleanupUnpublished(limit: 1), 0)
            XCTAssertEqual(replayed, 1)
            XCTAssertEqual(charges[first.generationID], 0, "absolute-zero replay cannot double-subtract")
            XCTAssertFalse(
                try final.retainedWorkPage().contains(where: { $0.generationID == first.generationID }))
            XCTAssertThrowsError(try final.generationEncodedBytes(first))
            XCTAssertEqual(try final.cleanupUnpublished(limit: 1), 0)
            XCTAssertEqual(replayed, 1, "ACKed receipts are not observed again")
            XCTAssertEqual(try final.itemMetadata(itemID: "active")?.recordCount, 1)
            XCTAssertTrue(try final.stagingGenerationsPage().contains(try XCTUnwrap(protected)))
        }
    }

}
