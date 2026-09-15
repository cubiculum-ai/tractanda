import CSQLite
import CTractandaVec1
import Foundation
import XCTest

@testable import TractandaVectors

final class Vec1IndexTests: XCTestCase {
    private func fixture(_ body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("semantic.sqlite").path)
    }

    private func record(
        _ id: String, item: String, revision: String = "r1", hash: String = "h1", chunk: Int = 0,
        text: String = "text", vector: [Float]
    ) -> VectorRecord {
        VectorRecord(
            id: id, itemID: item, revisionID: revision, contentHash: hash, chunkIndex: chunk, text: text,
            vector: vector)
    }

    func testExactCosineSearchUsesOnlyAuthorizedItems() throws {
        try fixture { path in
            let index = try Vec1Index(path: path, dimensions: 2, profileID: "profile-a")
            try index.replace(
                itemID: "private", records: [record("private-0", item: "private", vector: [1, 0])])
            try index.replace(
                itemID: "public", records: [record("public-0", item: "public", vector: [0, 1])])
            try index.replace(itemID: "near", records: [record("near-0", item: "near", vector: [0.8, 0.6])])

            let all = try index.search(
                query: [1, 0], allowedItemIDs: ["private", "public", "near"], limit: 3)
            XCTAssertEqual(all.map(\.id), ["private-0", "near-0", "public-0"])
            XCTAssertEqual(all[0].distance, 0, accuracy: 0.0001)

            // The globally closest record is private. The permitted result must
            // still be returned when the caller cannot read that record.
            let authorized = try index.search(query: [1, 0], allowedItemIDs: ["public"], limit: 1)
            XCTAssertEqual(authorized.map(\.id), ["public-0"])
        }
    }

    func testRevisionRelabelDoesNotReembed() throws {
        try fixture { path in
            let index = try Vec1Index(path: path, dimensions: 2, profileID: "profile-a")
            try index.replace(itemID: "item", records: [record("item-0", item: "item", vector: [1, 0])])
            let before = try index.records()
            try index.updateRevision(itemID: "item", revisionID: "r2", contentHash: "h2")
            let after = try index.records()
            let metadata = try index.itemMetadata(itemID: "item")
            XCTAssertEqual(after[0].revisionID, "r2")
            XCTAssertEqual(after[0].contentHash, "h2")
            XCTAssertEqual(after[0].vector, before[0].vector)
            XCTAssertEqual(after[0].text, before[0].text)
            XCTAssertEqual(metadata?.revisionID, "r2")
            XCTAssertEqual(metadata?.contentHash, "h2")
            XCTAssertEqual(metadata?.recordCount, 1)
        }
    }

    func testReplaceDeleteReopenAndResetAreDurable() throws {
        try fixture { path in
            do {
                let index = try Vec1Index(path: path, dimensions: 2, profileID: "profile-a")
                try index.replace(itemID: "item", records: [record("old", item: "item", vector: [1, 0])])
                try index.replace(itemID: "item", records: [record("new", item: "item", vector: [0, 1])])
                XCTAssertEqual(try index.records().map(\.id), ["new"])
                try index.remove(itemID: "item")
                XCTAssertTrue(try index.records().isEmpty)
                try index.replace(itemID: "item", records: [record("reopen", item: "item", vector: [1, 0])])
            }
            let reopened = try Vec1Index(path: path, dimensions: 2, profileID: "profile-a")
            XCTAssertEqual(try reopened.records().map(\.id), ["reopen"])
            try reopened.reset()
            XCTAssertTrue(try reopened.records().isEmpty)
        }
    }

    func testRejectsProfileDimensionAndMalformedVectors() throws {
        try fixture { path in
            let index = try Vec1Index(path: path, dimensions: 2, profileID: "profile-a")
            XCTAssertThrowsError(try Vec1Index(path: path, dimensions: 3, profileID: "profile-a"))
            XCTAssertThrowsError(try Vec1Index(path: path, dimensions: 2, profileID: "profile-b"))
            XCTAssertThrowsError(
                try index.replace(itemID: "item", records: [record("wrong", item: "item", vector: [1])]))
            XCTAssertThrowsError(
                try index.replace(itemID: "item", records: [record("zero", item: "item", vector: [0, 0])]))
            XCTAssertThrowsError(
                try index.replace(itemID: "item", records: [record("nan", item: "item", vector: [.nan, 1])]))
            XCTAssertThrowsError(try index.search(query: [1, .infinity], allowedItemIDs: ["item"], limit: 1))
        }
    }

    func testRegistrationCoexistsWithFTS5OnTheSameConnection() throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &database), SQLITE_OK)
        defer { sqlite3_close_v2(database) }
        var registrationError: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(tractanda_vec1_register(database, &registrationError), SQLITE_OK)
        sqlite3_free(registrationError)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE VIRTUAL TABLE docs USING fts5(text); INSERT INTO docs VALUES ('coexist'); CREATE VIRTUAL TABLE vectors USING vec1(vector);",
                nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database, "SELECT count(*) FROM docs WHERE docs MATCH 'coexist'", -1, &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testBestPerItemFiltersCurrentRecordsBeforeItsLimit() throws {
        try fixture { path in
            let index = try Vec1Index(path: path, dimensions: 2, profileID: "profile-a")
            var current: [Vec1RecordFilter] = []
            for number in 0..<300 {
                let itemID = "item-\(number)"
                let old = record(
                    "\(itemID)-old", item: itemID, revision: "old", hash: "old", chunk: 0, vector: [1, 0])
                let currentRecord = record(
                    "\(itemID)-current", item: itemID, revision: "current", hash: "current",
                    chunk: 1, vector: number == 299 ? [1, 0] : [0, 1])
                try index.replace(itemID: itemID, records: [old, currentRecord])
                current.append(
                    Vec1RecordFilter(itemID: itemID, revisionID: "current", contentHash: "current"))
            }
            let hits = try index.searchBestPerItem(query: [1, 0], allowedRecords: current, limit: 2)
            XCTAssertEqual(hits.count, 2)
            XCTAssertEqual(hits.first?.itemID, "item-299")
            XCTAssertTrue(Set(hits.map(\.itemID)).count == hits.count)
            XCTAssertTrue(hits.allSatisfy { $0.revisionID == "current" && $0.contentHash == "current" })
        }
    }
}
