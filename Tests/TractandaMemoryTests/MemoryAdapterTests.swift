import Foundation
import TractandaCore
import XCTest

@testable import TractandaMemory

final class MemoryAdapterTests: XCTestCase {
    private func fixture(_ files: [String: String], _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-memory-adapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, content) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file)
        }
        try body(root)
    }

    func testOKFProvenanceLifecycleDatesAndUnknownValues() throws {
        let note = """
            ---
            type: FutureType
            title: Source title
            generated:
              by: claimed-agent
              at: 2026-11-14T12:30:00+01:00
            verified:
              by: claimed-verifier
              at: definitely-not-a-date
            stale_after: 2026-11-15
            tags: [memory, preference]
            extension:
              custom: !inert value
              huge: 999999999999999999999999999999
            runtime: never-run
            computation: dangerous-command
            ---
            Body stays source text.
            """
        try fixture(["note.md": note]) { root in
            let record = try XCTUnwrap(
                OKFMemoryAdapter.preview(source: root, namespace: "fixture").records.first)
            XCTAssertEqual(record.sourceID, "note")
            XCTAssertEqual(record.original.sha256, ImportHash.bytes(Data(note.utf8)))
            XCTAssertEqual(record.projection["subject"], .text("Source title"))
            XCTAssertEqual(record.projection["body"], .text("Body stays source text."))
            XCTAssertEqual(record.projection["okfType"], .text("FutureType"))
            XCTAssertEqual(record.projection["okfStatus"], .text("stable"))
            XCTAssertEqual(record.metadata["statusDefaulted"], .boolean(true))
            XCTAssertEqual(record.metadata["claimsAuthenticated"], .boolean(false))
            XCTAssertEqual(record.metadata["instructionsActive"], .boolean(false))
            XCTAssertEqual(record.projection["originalModifiedAt"], .date("2026-11-14T12:30:00+01:00"))
            XCTAssertNil(record.projection["okfStaleAfter"])
            XCTAssertEqual(record.projection["okfVerifiedClaims"]?.array?.count, 1)
            XCTAssertEqual(record.projection["okfExecuted"], .boolean(false))
            XCTAssertEqual(record.projection["okfAttestation"], .text("absent"))
            XCTAssertTrue(record.diagnostics.contains { $0.code == "yamlTagCarried" })
            XCTAssertTrue(record.diagnostics.contains { $0.code == "yamlNumberCarried" })
            XCTAssertTrue(record.diagnostics.contains { $0.code == "okfExtensionCarried" })
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("note.md")), Data(note.utf8))
        }
    }

    func testMarkdownReferenceLinksAndFencesUseOriginalSourceSpans() throws {
        let note = """
            ---
            type: fact
            ---
            [Go][other]

            [other]: /folder/target.md#part

            ```md
            [fake](missing.md)
            ```
            `[also fake](missing.md)`
            """
        try fixture(["note.md": note, "folder/target.md": "---\ntype: fact\n---\n[back](../note.md)\n"]) {
            root in
            let plan = try OKFMemoryAdapter.preview(source: root, namespace: "fixture")
            let record = try XCTUnwrap(plan.records.first { $0.sourceID == "note" })
            XCTAssertEqual(record.links.count, 1)
            XCTAssertEqual(record.links.first?.originalTarget, "/folder/target.md#part")
            XCTAssertEqual(record.links.first?.targetSourceID, "folder/target")
            XCTAssertEqual(record.links.first?.fragment, "part")
            XCTAssertEqual(record.links.first?.kind, .local)
            XCTAssertEqual(record.links.first?.sourceLine, 4)
            XCTAssertEqual(
                record.metadata["markdownLinks"]?.array?.first?.map?["rawMarkdown"], .text("[Go][other]"))
            let back = try XCTUnwrap(plan.records.first { $0.sourceID == "folder/target" })
            XCTAssertEqual(back.links.first?.targetSourceID, "note")
        }
    }

    func testBrokenExternalAndEscapingLinksAreRetainedWithoutFetching() throws {
        try fixture([
            "note.md":
                "---\ntype: fact\n---\n[a](absent.md#x) [b](../../outside.md) [c](https://example.invalid/x) [d](%2e%2e/escape.md)"
        ]) { root in
            let record = try XCTUnwrap(
                OKFMemoryAdapter.preview(source: root, namespace: "fixture").records.first)
            XCTAssertEqual(record.links.map(\.kind), [.missing, .unsafe, .external, .unsafe])
            XCTAssertEqual(record.links.first?.targetSourceID, "absent")
            XCTAssertEqual(record.links.first?.fragment, "x")
        }
    }

    func testOKFSourceMarkersJoinDeclaredIDsWithoutInterpretingCode() throws {
        try fixture([
            "note.md":
                "---\ntype: fact\nsources:\n  - id: source-a\n    resource: https://example.invalid\n---\nClaim[^source-a], unknown[^missing]. `[^not-a-claim]` \\[^escaped] &#91;^entity]\n\n```\n[^also-not-a-claim]\n```"
        ]) { root in
            let record = try XCTUnwrap(
                OKFMemoryAdapter.preview(source: root, namespace: "fixture").records.first)
            let mentions = try XCTUnwrap(record.metadata["sourceMentions"]?.array)
            XCTAssertEqual(mentions.count, 2)
            XCTAssertEqual(mentions[0].map?["sourceID"], .text("source-a"))
            XCTAssertEqual(mentions[0].map?["resolution"], .text("source"))
            XCTAssertEqual(mentions[0].map?["sourceSpanKind"], .text("enclosingMarkdownTextNode"))
            XCTAssertEqual(mentions[0].map?["textOffsetUTF16"], .integer(5))
            XCTAssertEqual(mentions[0].map?["textOffsetEncoding"], .text("rawMarkdownUTF16"))
            XCTAssertEqual(mentions[1].map?["resolution"], .text("unresolved"))
            XCTAssertTrue(record.diagnostics.contains { $0.code == "footnoteDialectPartial" })
        }
    }

    func testAcyclicAliasesAreExpandedWithinExplicitBounds() throws {
        let node = try BoundedYAML.parse("type: fact\nbase: &base [one, two]\ncopy: *base\n")
        var diagnostics: [ImportDiagnostic] = []
        let value = BoundedYAML.value(node, diagnostics: &diagnostics)
        XCTAssertEqual(value.map?["base"], value.map?["copy"])
        XCTAssertEqual(value.map?["copy"], .list([.text("one"), .text("two")]))
    }

    func testYAMLAliasExpansionDepthAndCyclesAreRejectedBeforeCompose() throws {
        var bomb = "type: fact\na0: &a0 [x,x]\n"
        for index in 1...18 { bomb += "a\(index): &a\(index) [*a\(index - 1), *a\(index - 1)]\n" }
        XCTAssertThrowsError(try BoundedYAML.parse(bomb)) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "importYAMLLimit")
        }
        XCTAssertThrowsError(try BoundedYAML.parse("type: fact\nrecursive: &self [*self]\n")) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "importYAMLAliasUnsupported")
        }
        XCTAssertThrowsError(
            try BoundedYAML.parse(
                "type: fact\nnested: " + String(repeating: "[", count: 30) + "x"
                    + String(repeating: "]", count: 30)))
        XCTAssertThrowsError(try BoundedYAML.parse("type: fact\n---\ntype: second"))
        XCTAssertThrowsError(try BoundedYAML.parse("type: fact\ntype: duplicate"))
    }

    func testInvalidCalendarAndOffsetTimestampsNeverBecomeNativeDates() throws {
        try fixture([
            "note.md":
                "---\ntype: fact\ngenerated:\n  at: 2026-02-31T12:00:00Z\nstale_after: 2026-11-14T12:01:00+99:99\nverified:\n  by: source-claim\n  at: 2026-11-14\n---\nBody"
        ]) { root in
            let record = try XCTUnwrap(
                OKFMemoryAdapter.preview(source: root, namespace: "fixture").records.first)
            XCTAssertNil(record.projection["originalModifiedAt"])
            XCTAssertNil(record.projection["okfStaleAfter"])
            XCTAssertEqual(record.metadata["dateClaims"], .object([:]))
            XCTAssertTrue(record.diagnostics.contains { $0.code == "okfInvalidTimestamp" })
        }
    }

    func testUnknownComplexYAMLKeysAreCarried() throws {
        try fixture(["note.md": "---\ntype: fact\n? [a, b]\n: value\n---\nBody"]) { root in
            let record = try XCTUnwrap(
                OKFMemoryAdapter.preview(source: root, namespace: "fixture").records.first)
            XCTAssertEqual(record.projection["okfType"], .text("fact"))
            XCTAssertEqual(record.metadata["yaml"]?.map?["otherEntries"]?.array?.count, 1)
            XCTAssertTrue(record.diagnostics.contains { $0.code == "yamlComplexKeysCarried" })
        }
    }

    func testAuxiliaryDocumentsAssetsAndSelectedNativeOriginAreOrdinaryData() throws {
        try fixture([
            "index.md": "# Navigation\n[note](note.md)", "log.md": "Original log",
            "note.md": "---\ntype: fact\n---\nBody", "image.bin": "asset",
        ]) { root in
            let plan = try OKFMemoryAdapter.preview(source: root, namespace: "fixture")
            XCTAssertEqual(plan.records.count, 4)
            XCTAssertEqual(
                plan.records.first { $0.sourceID == "index" }?.metadata["sourceRole"], .text("index"))
            XCTAssertEqual(plan.records.first { $0.sourceID == "log" }?.metadata["sourceRole"], .text("log"))
            XCTAssertEqual(
                plan.records.first { $0.sourceID == "image.bin" }?.metadata["sourceRole"], .text("asset"))
        }
        try fixture([
            "MEMORY.md": "# Remember\nKeep this.", "CLAUDE.md": "Instruction-looking source",
            "transcript.jsonl": "{\"role\":\"user\"}",
        ]) { root in
            let plan = try MemoryDirectoryAdapter.preview(
                source: root, namespace: "fixture", origin: "claude")
            XCTAssertEqual(plan.adapter, "selected-claude-notes-v1")
            XCTAssertEqual(plan.records.count, 3)
            XCTAssertEqual(
                plan.records.first { $0.sourceID == "MEMORY.md" }?.projection["subject"], .text("Remember"))
            XCTAssertTrue(plan.records.allSatisfy { $0.metadata["instructionsActive"] == .boolean(false) })
            XCTAssertTrue(plan.records.allSatisfy { $0.metadata["selectedOrigin"] == .text("claude") })
            let transcript = try XCTUnwrap(plan.records.first { $0.sourceID == "transcript.jsonl" })
            XCTAssertNil(transcript.projection["body"])
            XCTAssertTrue(transcript.diagnostics.contains { $0.code == "assetOriginalOnly" })
        }
    }

    func testUTF8BOMAndNumericBundleVersionPreserveOriginals() throws {
        let index = "\u{FEFF}---\r\nokf_version: 0.2\r\n---\r\n# Navigation\r\n"
        try fixture(["index.md": index]) { root in
            let record = try XCTUnwrap(
                OKFMemoryAdapter.preview(source: root, namespace: "fixture").records.first)
            XCTAssertEqual(record.projection["okfVersion"], .text("0.2"))
            XCTAssertEqual(record.projection["body"], .text("# Navigation\r\n"))
            XCTAssertEqual(record.original.sha256, ImportHash.bytes(Data(index.utf8)))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.md")), Data(index.utf8))
        }
    }

    func testCRLFConceptLinksAndSourceMarkersPreserveSourceSpans() throws {
        let body = "Claim[^source-a].\r\n[self](#part)\r\n"
        let note = "---\r\ntype: fact\r\nsources:\r\n  - id: source-a\r\n---\r\n" + body
        try fixture(["note.md": note]) { root in
            let record = try XCTUnwrap(
                OKFMemoryAdapter.preview(source: root, namespace: "fixture").records.first)
            XCTAssertEqual(record.projection["okfType"], .text("fact"))
            XCTAssertEqual(record.projection["body"], .text(body))
            XCTAssertEqual(record.links.count, 1)
            XCTAssertEqual(record.links.first?.sourceLine, 7)
            XCTAssertEqual(record.links.first?.targetSourceID, "note")
            XCTAssertEqual(
                record.metadata["markdownLinks"]?.array?.first?.map?["rawMarkdown"], .text("[self](#part)"))
            let mention = try XCTUnwrap(record.metadata["sourceMentions"]?.array?.first?.map)
            XCTAssertEqual(mention["sourceLine"], .integer(6))
            XCTAssertEqual(mention["textOffsetUTF16"], .integer(5))
            XCTAssertEqual(mention["resolution"], .text("source"))
            XCTAssertEqual(record.original.sha256, ImportHash.bytes(Data(note.utf8)))
        }
    }

    func testRequiredTypeMalformedUTF8AndIdentityCollisionReject() throws {
        try fixture(["note.md": "---\ntitle: missing-type\n---\nBody"]) { root in
            XCTAssertThrowsError(try OKFMemoryAdapter.preview(source: root, namespace: "fixture"))
        }
        try fixture(["note.md": "---\ntype: fact\n---\nBody", "note": "asset collision"]) { root in
            XCTAssertThrowsError(try OKFMemoryAdapter.preview(source: root, namespace: "fixture"))
        }
        try fixture(["note.txt": "initial"]) { root in
            try Data([0xFF, 0xFE]).write(to: root.appendingPathComponent("note.txt"))
            XCTAssertThrowsError(try MemoryDirectoryAdapter.preview(source: root, namespace: "fixture"))
        }
    }
}
