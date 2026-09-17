import Foundation
import XCTest

@testable import TractandaCore

final class ExtractedTextTests: XCTestCase {
    private func fixture(_ body: (ItemStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-extracted-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(ItemStore(root: root))
    }
    private func item(_ store: ItemStore, _ fields: [String: ItemValue]) throws -> Revision {
        try store.commit(CommitRequest(classID: "Item", changes: fields, operationID: Identifier.make()))
            .revision
    }
    private func call(_ store: ItemStore, _ args: [String: Any]) throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [["TractandaItem/extractedText", args, "test"]],
        ])
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ItemService(store: store).handle(request, peerUID: store.ownerUID)) as? [String: Any])
        let calls = try XCTUnwrap(response["methodResponses"] as? [[Any]])
        let result = try XCTUnwrap(calls[0][1] as? [String: Any])
        if calls[0][0] as? String == "error" {
            throw TractandaError(result["type"] as? String ?? "error", result["description"] as? String ?? "")
        }
        return result
    }
    private func record(_ response: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((response["list"] as? [[String: Any]])?.first)
    }
    private func state(_ record: [String: Any], _ name: String) throws -> [String: Any] {
        try XCTUnwrap((record["index"] as? [String: [String: Any]])?[name])
    }
    private func size(_ result: [String: Any]) throws -> Int {
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).count
    }
    func testExactCanonicalProjectionsExcludeNonTextWithoutFollowingReferences() throws {
        try fixture { store in
            let target = try item(store, ["body": .text("unfollowed target")])
            let revision = try item(
                store,
                [
                    "subject": .text("Title"), "body": .text("body\0snow ☃"),
                    "custom": .object(["permissions": .text("ordinary nested text"), "empty": .text("  ")]),
                    "when": .date("2026-09-17T12:00:00Z"),
                    "reference": .reference(ItemReference(target.itemID)),
                    "bytes": .bytes(Data("secret bytes".utf8)), "count": .integer(17),
                    "developmentUUIDMigration": .object(["note": .text("excluded migration")]),
                    "templateKey": .text("excluded template"),
                ])
            let before = store.state
            let corpus = ItemTextContent.corpus(for: revision)
            let source = try call(store, ["ids": [revision.itemID]])
            let value = try record(source)
            XCTAssertEqual(source["extractionProfile"] as? String, ItemTextContent.profile)
            XCTAssertEqual(value["revisionID"] as? String, revision.revisionID)
            XCTAssertEqual(value["sourceText"] as? String, corpus.sourceText)
            XCTAssertEqual(
                value["sourceHash"] as? String, try SemanticSource.contentHash(sourceText: corpus.sourceText))
            XCTAssertEqual(value["sourceUTF8Bytes"] as? Int, corpus.sourceText.utf8.count)
            for absent in [
                "excluded migration", "excluded template", "unfollowed target", "secret bytes", "2026-09-17",
                "field[\"count\"]", "field[\"custom\"][\"empty\"]",
            ] {
                XCTAssertFalse(corpus.sourceText.contains(absent))
            }
            XCTAssertTrue(corpus.sourceText.contains("ordinary nested text"))
            XCTAssertEqual(try state(value, "fts")["status"] as? String, "current")
            XCTAssertEqual(try state(value, "semantic")["status"] as? String, "disabled")
            let fts = try record(call(store, ["ids": [revision.itemID], "projection": "fts"]))
            XCTAssertEqual(
                fts["fts"] as? [String: String],
                ["subject": corpus.subject, "body": corpus.body, "metadata": corpus.metadata])
            XCTAssertNil(fts["sourceText"])
            let summary = try record(call(store, ["ids": [revision.itemID], "projection": "summary"]))
            XCTAssertNil(summary["sourceText"])
            XCTAssertNil(summary["fts"])
            XCTAssertEqual(summary["sourceHash"] as? String, value["sourceHash"] as? String)
            XCTAssertEqual(store.state, before)
        }
    }
    func testByteBudgetHasDisjointContinuationAndOversizedResults() throws {
        try fixture { store in
            let huge = try item(store, ["body": .text(String(repeating: "é\"", count: 10_000))])
            let items = try (0..<6).map { _ in
                try item(store, ["body": .text(String(repeating: "x", count: 2_000))])
            }
            var ids = [huge.itemID] + items.map(\.itemID)
            var collected: [String] = []
            var oversized: [String] = []
            var pages = 0
            repeat {
                let response = try call(store, ["ids": ids, "maxBytes": 8_192])
                XCTAssertLessThanOrEqual(try size(response), 8_192)
                let values = try XCTUnwrap(response["list"] as? [[String: Any]])
                XCTAssertTrue(
                    values.allSatisfy { $0["sourceText"] != nil },
                    "Never substitute a partial diagnostic record")
                collected += values.compactMap { $0["itemID"] as? String }
                oversized += response["oversizedIDs"] as? [String] ?? []
                let remaining = try XCTUnwrap(response["remainingIDs"] as? [String])
                XCTAssertLessThan(remaining.count, ids.count)
                ids = remaining
                pages += 1
            } while !ids.isEmpty && pages < 10
            XCTAssertGreaterThan(pages, 1)
            XCTAssertTrue(ids.isEmpty)
            XCTAssertEqual(collected, items.map(\.itemID))
            XCTAssertEqual(oversized, [huge.itemID])
            let summary = try call(store, ["ids": [huge.itemID], "projection": "summary", "maxBytes": 8_192])
            XCTAssertLessThanOrEqual(try size(summary), 8_192)
            XCTAssertEqual((summary["oversizedIDs"] as? [String])?.count, 0)
            XCTAssertEqual(try record(summary)["itemID"] as? String, huge.itemID)
        }
    }
    func testActualFTSStateIsComparedAndUnavailableIndexStillAllowsExtraction() throws {
        try fixture { store in
            let revision = try item(store, ["subject": .text("canonical")])
            let index = try ItemIndex(
                path: store.indexDirectory.appendingPathComponent("items.sqlite").path, create: false)
            func status() throws -> String? {
                try state(record(call(store, ["ids": [revision.itemID]])), "fts")["status"] as? String
            }
            XCTAssertEqual(try status(), "current")
            try index.execute(
                "UPDATE text_index SET subject = ? WHERE id = ?", ["old index text", revision.itemID])
            XCTAssertEqual(try status(), "stale")
            XCTAssertFalse(
                String(
                    decoding: try JSONSerialization.data(
                        withJSONObject: call(store, ["ids": [revision.itemID]])), as: UTF8.self
                ).contains("old index text"))
            try index.execute("DELETE FROM text_index WHERE id = ?", [revision.itemID])
            XCTAssertEqual(try status(), "missing")
            try index.execute("DROP TABLE text_index")
            XCTAssertEqual(try status(), "unavailable")
            XCTAssertTrue(
                (try record(call(store, ["ids": [revision.itemID]]))["sourceText"] as? String)?.contains(
                    "canonical") == true)
            index.close()
            try store.rebuildIndex()
            XCTAssertEqual(try status(), "current")
        }
    }
    func testIndependentIDLimitAndInvalidArguments() throws {
        try fixture { store in
            let ids = (0..<64).map { _ in Identifier.make() }
            let response = try call(store, ["ids": ids, "maxBytes": 8_192])
            XCTAssertEqual(response["notFound"] as? [String], ids)
            XCTAssertLessThanOrEqual(try size(response), 8_192)
            for args: [String: Any] in [
                ["ids": []], ["ids": ids + [Identifier.make()]],
                ["ids": [ids[0], ids[0]]], ["ids": [ids[0]], "projection": 1],
                ["ids": [ids[0]], "projection": "full"], ["ids": [ids[0]], "maxBytes": 100],
                ["ids": [ids[0]], "revisionID": ids[1]],
            ] { XCTAssertThrowsError(try call(store, args)) }
        }
    }
}
