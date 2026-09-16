import Foundation
import XCTest

@testable import TractandaCore

final class ItemTextContentTests: XCTestCase {
    func testOperationalRootsAndBlankFieldsProduceNoSearchText() throws {
        let revision = try Revision(
            fields: fields([
                "subject": .text(""), "body": .text(" \n\t"),
                "developmentUUIDMigration": .object(["note": .text("original issuer unknown")]),
                "templateKey": .text("internal-template-marker"),
                "assignee": .text(""), "whitespace": .text(" \t\n\u{2003}"),
                "nested": .list([.object(["empty": .text("\n")])]),
            ]))
        let corpus = ItemTextContent.corpus(for: revision)
        XCTAssertTrue(corpus.metadata.isEmpty)
        XCTAssertTrue(corpus.sourceText.isEmpty)
        XCTAssertEqual(ItemTextContent.profile, "tractanda.item-text.v3")
    }

    func testOperationalExclusionDoesNotHideOrdinaryNestedText() throws {
        let revision = try Revision(
            fields: fields([
                "custom": .object([
                    "developmentUUIDMigration": .text("ordinary nested history"),
                    "templateKey": .text("ordinary nested template discussion"),
                    "spaced": .text(" \tmeaningful text\n "),
                ])
            ]))
        let text = ItemTextContent.corpus(for: revision).sourceText
        XCTAssertTrue(text.contains("ordinary nested history"))
        XCTAssertTrue(text.contains("ordinary nested template discussion"))
        XCTAssertTrue(text.contains(" \tmeaningful text\n "), "Retained values keep their original bytes")
        XCTAssertFalse(text.contains("subject:\n"))
        XCTAssertFalse(text.contains("body:\n"))
    }

    func testFTSExcludesMigrationReceiptsAndEmptyFieldLabelsAfterRebuild() throws {
        try fixture { store in
            _ = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text("Ordinary searchable content"),
                        "developmentUUIDMigration": .object(["note": .text("original issuer unknown")]),
                        "templateKey": .text("internal-template-marker"),
                        "assignee": .text("  "),
                    ], operationID: "exclude-operational-metadata"))
            for _ in 0..<2 {
                XCTAssertTrue(try store.candidates(text: "original issuer unknown").isEmpty)
                XCTAssertTrue(try store.candidates(text: "internal-template-marker").isEmpty)
                XCTAssertTrue(try store.candidates(text: "assignee").isEmpty)
                XCTAssertEqual(try store.candidates(text: "Ordinary searchable content").count, 1)
                try store.rebuildIndex()
            }
        }
    }

    private func fixture(_ body: (ItemStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "item-text-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(try ItemStore(root: root))
    }

    private func fields(_ additions: [String: ItemValue]) -> [String: ItemValue] {
        [
            "itemID": .text("00000000-0000-1000-8000-000000000001"),
            "revisionID": .text("00000000-0000-1000-8000-000000000002"),
            "classID": .text("Item"), "schemaVersion": .integer(1),
            "createdAt": .date("2026-01-01T00:00:00Z"), "modifiedAt": .date("2026-01-01T00:00:00Z"),
            "actor": .text("actor"), "operationID": .text("operation"), "requestIdentity": .text("receipt"),
        ].merging(additions, uniquingKeysWith: { _, replacement in replacement })
    }

    func testFTSCoversOwnedTextAndRebuildPreservesCoverage() throws {
        try fixture { store in
            let referenced = try store.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("unfollowed remote secret")],
                    operationID: "referenced")
            )
            .revision
            let revision = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "workingNotes": .text("working-note needle"),
                        "checklist": .list([.object(["title": .text("checklist needle")])]),
                        "referenceLabels": .list([.object(["label": .text("label needle")])]),
                        "custom": .object([
                            "z": .text("zeta needle"), "a": .list([.text("nested requestIdentity needle")]),
                            "requestIdentity": .text("nested reserved needle"),
                        ]),
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("acl-root-needle"),
                            "group": .text("group"), "mode": .integer(0o600), "acl": .object([:]),
                        ]),
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile),
                            "expression": .text("subject == \"rule-root-needle\""),
                        ]),
                        "related": .reference(ItemReference(referenced.itemID)),
                    ], operationID: "owned-text")
            )
            .revision
            for term in [
                "working-note needle", "checklist needle", "label needle", "zeta needle",
                "nested requestIdentity needle", "nested reserved needle",
            ] {
                XCTAssertEqual(try store.candidates(text: term).map(\.itemID), [revision.itemID])
            }
            XCTAssertEqual(
                try store.candidates(text: "unfollowed remote secret").map(\.itemID), [referenced.itemID],
                "the referencing item must not inherit text from its reference")
            XCTAssertTrue(try store.candidates(text: "acl-root-needle").isEmpty)
            XCTAssertTrue(try store.candidates(text: "rule-root-needle").isEmpty)
            try store.rebuildIndex()
            XCTAssertEqual(try store.candidates(text: "checklist needle").map(\.itemID), [revision.itemID])
        }
    }

    func testExtractionIsDeterministicUTF8SafeAndExcludesOnlyRoots() throws {
        let first = try Revision(
            fields: fields([
                "subject": .text("Café"), "body": .text("日本語"),
                "b": .object(["two": .text("second")]), "a": .list([.text("first"), .text("é")]),
                "permissions": .object(["receipt": .text("acl receipt needle")]),
                "selection": .object(["rule": .text("rule needle")]),
                "custom": .object(["permissions": .text("nested permission needle")]),
                "related": .reference(ItemReference("00000000-0000-1000-8000-000000000003")),
            ]))
        let second = try Revision(
            fields: fields([
                "subject": .text("Café"), "body": .text("日本語"),
                "a": .list([.text("first"), .text("é")]), "b": .object(["two": .text("second")]),
                "permissions": .object(["receipt": .text("acl receipt needle")]),
                "selection": .object(["rule": .text("rule needle")]),
                "custom": .object(["permissions": .text("nested permission needle")]),
                "related": .reference(ItemReference("00000000-0000-1000-8000-000000000003")),
            ]))
        let corpus = ItemTextContent.corpus(for: first)
        XCTAssertEqual(corpus, ItemTextContent.corpus(for: second))
        XCTAssertTrue(corpus.metadata.contains("nested permission needle"))
        XCTAssertFalse(corpus.metadata.contains("acl receipt needle"))
        XCTAssertFalse(corpus.metadata.contains("rule needle"))
        XCTAssertFalse(corpus.metadata.contains("00000000-0000-1000-8000-000000000003"))
        XCTAssertLessThan(
            corpus.metadata.range(of: "field[\"a\"]")!.lowerBound,
            corpus.metadata.range(of: "field[\"b\"]")!.lowerBound)
        XCTAssertNoThrow(try SemanticChunker.chunks(corpus.sourceText, chunkBytes: 32, overlapBytes: 0))
    }
}
