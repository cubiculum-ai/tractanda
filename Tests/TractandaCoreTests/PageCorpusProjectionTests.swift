import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PageCorpusProjectionTests: XCTestCase {
    private struct Provider: PageCorpusPageProvider {
        let pages: [DocumentStoredPage]  // Tiny fake only; production provider must stream proofs.
        var failure: Bool = false
        func forEachPage(
            document: PageCorpusDocumentPlan, visit: (DocumentStoredPage) throws -> Void
        ) throws {
            if failure {
                throw TractandaError("documentIntegrity", "Missing authenticated provider dependency")
            }
            for page in pages { try visit(page) }
        }
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func revision(_ extra: [String: ItemValue] = [:]) throws -> Revision {
        var fields: [String: ItemValue] = [
            "itemID": .text(try id()), "revisionID": .text(try id()), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date(Timestamp.now()),
            "modifiedAt": .date(Timestamp.now()),
            "actor": .text("fixture"), "operationID": .text("fixture"), "requestIdentity": .text("fixture"),
        ]
        fields.merge(extra) { _, new in new }
        return try Revision(fields: fields)
    }
    private func input(_ extra: [String: ItemValue] = [:]) throws -> PageCorpusInput {
        try PageCorpusInput(storeID: id(), revision: revision(extra))
    }
    private func root() throws -> URL {
        // Estimate <256KiB total with all sidecars; enforce <=16MiB and genuine10GiB reserve.
        let parent = FileManager.default.temporaryDirectory
        try PageCorpusSpoolPolicy(
            maximumBytes: 16 * 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024
        ).check(at: parent, additionalBytes: 16 * 1024 * 1024)
        let root = parent.appendingPathComponent("page-corpus-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func policy() throws -> PageCorpusSpoolPolicy {
        try PageCorpusSpoolPolicy(maximumBytes: 16 * 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024)
    }
    private func prepare(_ input: PageCorpusInput, provider: Provider = Provider(pages: []), root: URL) throws
        -> PreparedPageCorpus
    {
        try PageCorpusProjection.prepare(input: input, provider: provider, root: root, policy: policy())
    }
    private func matches(_ prepared: PreparedPageCorpus, _ text: String, allowed: Bool = true) throws
        -> [String]
    {
        var result: [String] = []
        try PageCorpusProjection.forEachMatchingItem(
            prepared, expected: prepared.receipt.source, literalText: text,
            isCurrentAndReadable: { _ in allowed }, visit: { result.append($0) })
        return result
    }
    private func page(_ number: Int, source: AttachmentDocumentSource, text: String) throws
        -> DocumentStoredPage
    {
        let parsed = try DoclingDocTagsParser.parse("<doctag><text>" + text + "</text></doctag>")
        let geometry = try DocumentPageGeometry(
            sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint", displayWidth: 512,
            displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024,
            contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024)
        return try DocumentStoredPage(
            pageNumber: Int64(number), sourceSHA256: source.sha256,
            page: AttachmentDocumentPage(
                pageNumber: number, geometry: geometry, rasterSHA256: String(repeating: "b", count: 64),
                parsed: parsed, generatedTokens: 32, stopReason: "stop"))
    }
    private func documentInput(_ make: (AttachmentDocumentSource) throws -> [DocumentStoredPage]) throws -> (
        PageCorpusInput, Provider
    ) {
        let base = try revision()
        let attachmentID = try id()
        // Provenance intentionally differs from the current local owning item after a copy.
        let source = try AttachmentDocumentSource(
            itemID: id(), revisionID: id(), attachmentID: id(), sha256: String(repeating: "a", count: 64),
            byteCount: 100, mediaType: "application/pdf")
        let pages = try make(source)
        var counts = [Int64](repeating: 0, count: 5)
        for saved in pages {
            let index = try XCTUnwrap(
                ["converted", "unsupported", "truncated", "timeout", "failed"].firstIndex(of: saved.status))
            counts[index] += 1
        }
        let reference = try DocumentContentReference(
            contentID: id(), manifestSHA256: String(repeating: "c", count: 64),
            rootSHA256: String(repeating: "d", count: 64),
            pageCount: Int64(pages.count),
            totalEncodedBytes: pages.reduce(0) { total, page in
                total + Int64((try? JSON.encode(page).count) ?? 0)
            },
            coverage: DocumentCoverage(
                converted: counts[0], unsupported: counts[1], truncated: counts[2], timedOut: counts[3],
                failed: counts[4]))
        let document = try AttachmentDocumentRepresentation(
            representationID: id(), attachmentID: attachmentID, source: source,
            extractedAt: Timestamp.now(), identity: .init(), content: reference)
        let original = try AttachmentDescriptor(
            attachmentID: attachmentID, filename: "synthetic.pdf", mediaType: source.mediaType,
            byteCount: source.byteCount, sha256: source.sha256)
        var fields = base.fields
        fields["attachments"] = .list([original.itemValue])
        fields["attachmentDocument"] = .list([try document.itemValue])
        return (
            try PageCorpusInput(storeID: id(), revision: Revision(fields: fields)), Provider(pages: pages)
        )
    }

    func testWholeFieldPhraseUnicodeQuotesAndIntentionalFieldBoundary() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try input([
            "body": .text("Café says \"loan note\" and literal AND beta"),
            "left": .text("tailalpha"), "right": .text("headbeta"),
            "nested": .object(["templateKey": .text("visible nested marker")]),
            "templateKey": .text("hidden operational marker"),
        ])
        let prepared = try prepare(input, root: root)
        XCTAssertEqual(try matches(prepared, "cafe says loan note"), [input.binding.itemID])
        XCTAssertEqual(try matches(prepared, "\"loan note\""), [input.binding.itemID])
        XCTAssertEqual(try matches(prepared, "literal AND beta"), [input.binding.itemID])
        XCTAssertTrue(try matches(prepared, "tailalpha headbeta").isEmpty)
        XCTAssertTrue(try matches(prepared, "hidden operational marker").isEmpty)
        XCTAssertEqual(try matches(prepared, "visible nested marker"), [input.binding.itemID])
        // Existing tagged-value/glob query semantics have not changed or been synthesized.
        XCTAssertTrue(try SpotlightQuery("body == '*loan note*'").matches(input.revision))
        XCTAssertFalse(try SpotlightQuery("body == '*visible nested marker*'").matches(input.revision))
        let loaded = try PageCorpusProjection.load(
            root: root, artifactName: prepared.directory.lastPathComponent, expected: input.binding)
        XCTAssertEqual(loaded.receipt, prepared.receipt)
    }

    func testPagePhrasesDeduplicateItemAndDoNotCrossBoundaries() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (input, provider) = try documentInput { source in
            [
                try page(1, source: source, text: "shared income tailalpha"),
                try page(2, source: source, text: "headbeta shared income"),
            ]
        }
        let prepared = try prepare(input, provider: provider, root: root)
        XCTAssertEqual(try matches(prepared, "shared income"), [input.binding.itemID])
        XCTAssertTrue(try matches(prepared, "tailalpha headbeta").isEmpty)
        XCTAssertTrue(try matches(prepared, "tailalpha attachment page headbeta").isEmpty)
        XCTAssertEqual(prepared.receipt.summary.converted, 2)
        XCTAssertEqual(prepared.receipt.summary.spanCount, 2)
        let window = try PageCorpusProjection.readUnit(
            prepared, expected: input.binding, ordinal: 1, offset: 0, limit: 4,
            isCurrentAndReadable: { _ in true })
        XCTAssertEqual(String(decoding: window.data, as: UTF8.self), "head")
        XCTAssertEqual(window.nextOffset, 4)
        XCTAssertEqual(window.origin.pageNumber, 2)
        XCTAssertNotEqual(window.origin.documentSource?.itemID, input.binding.itemID)
        XCTAssertNil(window.origin.sourceByteStart, "PDF bytes cannot be invented from OCR offsets")
    }

    func testFailedEmptyAndDetachedOutputsNeverBecomeText() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (input, provider) = try documentInput { source in
            [
                try page(1, source: source, text: ""),
                try DocumentStoredPage(
                    pageNumber: 2, sourceSHA256: source.sha256, status: "failed",
                    failureCode: "synthetic-failure-secret"),
                try page(3, source: source, text: "known text"),
            ]
        }
        let prepared = try prepare(input, provider: provider, root: root)
        XCTAssertEqual(prepared.receipt.summary.unitCount, 1)
        XCTAssertEqual(prepared.receipt.summary.converted, 2)
        XCTAssertEqual(prepared.receipt.summary.failed, 1)
        XCTAssertTrue(try matches(prepared, "synthetic-failure-secret").isEmpty)
        XCTAssertEqual(try matches(prepared, "known text"), [input.binding.itemID])
        var detached = input.revision.fields
        detached.removeValue(forKey: "attachments")
        let withoutOriginal = try PageCorpusInput(
            storeID: input.binding.storeID, revision: Revision(fields: detached))
        let empty = try prepare(withoutOriginal, provider: Provider(pages: [], failure: true), root: root)
        XCTAssertEqual(empty.receipt.summary.unitCount, 0)
        XCTAssertTrue(try matches(empty, "known text").isEmpty)
    }

    func testCurrentBindingAuthorityForeignStoreAndReceiptTamperFailClosed() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try input(["body": .text("private payload")])
        let prepared = try prepare(input, root: root)
        XCTAssertTrue(try matches(prepared, "private payload", allowed: false).isEmpty)
        var calls = 0
        var delivered = false
        try PageCorpusProjection.forEachMatchingItem(
            prepared, expected: input.binding, literalText: "private payload",
            isCurrentAndReadable: { _ in
                calls += 1
                return calls == 1
            }, visit: { _ in delivered = true })
        XCTAssertFalse(delivered, "Fresh final authority precedes delivery")
        let foreign = try PageCorpusInput(storeID: id(), revision: input.revision)
        XCTAssertThrowsError(try PageCorpusProjection.verify(prepared, expected: foreign.binding))
        var changed = input.revision.fields
        changed["revisionID"] = .text(try id())
        let newer = try PageCorpusInput(storeID: input.binding.storeID, revision: Revision(fields: changed))
        XCTAssertThrowsError(try PageCorpusProjection.verify(prepared, expected: newer.binding))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: prepared.databaseURL.path)
        let fd = try FileHandle(forWritingTo: prepared.databaseURL)
        try fd.write(contentsOf: Data([0]))
        try fd.close()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400], ofItemAtPath: prepared.databaseURL.path)
        XCTAssertThrowsError(try PageCorpusProjection.verify(prepared, expected: input.binding))
    }

    func testMissingIncompleteAndCorruptProvidersDiscardOnlyDisposableStage() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (input, provider) = try documentInput { source in
            [try page(1, source: source, text: "source text")]
        }
        for bad in [Provider(pages: [], failure: true), Provider(pages: [])] {
            XCTAssertThrowsError(try prepare(input, provider: bad, root: root))
        }
        let saved = try XCTUnwrap(provider.pages.first)
        let badHash = try DocumentStoredPage(
            pageNumber: saved.pageNumber, sourceSHA256: String(repeating: "f", count: 64),
            page: XCTUnwrap(saved.page))
        XCTAssertThrowsError(try prepare(input, provider: Provider(pages: [badHash]), root: root))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertEqual(input.documents.count, 1, "Source input/history is untouched")
    }

    func testIncomingPlanBindsActualBaseAndRebaseRebuildsOrdinaryUnits() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (saved, provider) = try documentInput { source in
            [try page(1, source: source, text: "incoming page text")]
        }
        let current = try XCTUnwrap(saved.documents.first)
        let incoming = try PageCorpusDocumentPlan(
            attachmentID: current.attachmentID, source: current.source, identity: current.identity,
            extractedAt: current.extractedAt, rootSHA256: XCTUnwrap(current.rootSHA256),
            pageCount: current.pageCount, totalEncodedBytes: current.totalEncodedBytes,
            coverage: current.coverage)
        let input = try PageCorpusInput(
            storeID: saved.binding.storeID, revision: saved.revision, incoming: incoming)
        let prepared = try prepare(input, provider: provider, root: root)
        XCTAssertEqual(prepared.receipt.source.baseRevisionID, saved.revision.revisionID)
        XCTAssertNotNil(prepared.receipt.source.incomingSHA256)
        let window = try PageCorpusProjection.readUnit(
            prepared, expected: input.binding, ordinal: 0, limit: 32, isCurrentAndReadable: { _ in true })
        XCTAssertNil(window.origin.contentID)
        XCTAssertNil(window.origin.representationID)
        XCTAssertEqual(window.origin.documentSource?.revisionID, current.source.revisionID)
        var fields = saved.revision.fields
        fields["revisionID"] = .text(try id())
        fields["body"] = .text("new ordinary field bytes")
        let rebased = try PageCorpusInput(
            storeID: saved.binding.storeID, revision: Revision(fields: fields), incoming: incoming)
        XCTAssertEqual(rebased.binding.incomingSHA256, input.binding.incomingSHA256)
        XCTAssertNotEqual(rebased.binding.snapshotSHA256, input.binding.snapshotSHA256)
        XCTAssertThrowsError(try PageCorpusProjection.verify(prepared, expected: rebased.binding))
        let rebuilt = try prepare(rebased, provider: provider, root: root)
        XCTAssertEqual(try matches(rebuilt, "new ordinary field bytes"), [rebased.binding.itemID])
        XCTAssertEqual(try matches(rebuilt, "incoming page text"), [rebased.binding.itemID])
        XCTAssertEqual(rebuilt.receipt.summary.unitCount, 2)
    }

    func testDecodedIncomingPlanCannotBypassValidation() throws {
        let (saved, _) = try documentInput { source in
            [try page(1, source: source, text: "small source")]
        }
        let current = try XCTUnwrap(saved.documents.first)
        let incoming = try PageCorpusDocumentPlan(
            attachmentID: current.attachmentID, source: current.source, identity: current.identity,
            extractedAt: current.extractedAt, rootSHA256: XCTUnwrap(current.rootSHA256),
            pageCount: current.pageCount, totalEncodedBytes: current.totalEncodedBytes,
            coverage: current.coverage)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSON.encode(incoming)) as? [String: Any])
        object["rootSHA256"] = "not-a-digest"
        let decoded = try JSON.decode(
            PageCorpusDocumentPlan.self, JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(
            try PageCorpusInput(storeID: saved.binding.storeID, revision: saved.revision, incoming: decoded)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "documentIntegrity")
        }
    }

    func testCapacityUnknownReserveAndSpoolCapUseTinyFixtures() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try input(["body": .text(String(repeating: "small bounded phrase ", count: 500))])
        let unknown = try PageCorpusSpoolPolicy(
            maximumBytes: 16 * 1024 * 1024, minimumFreeBytes: 10,
            availableBytes: { throw TractandaError("injected", "Unknown capacity") })
        let low = try PageCorpusSpoolPolicy(
            maximumBytes: 16 * 1024 * 1024, minimumFreeBytes: 10, availableBytes: { 9 })
        for policy in [unknown, low] {
            XCTAssertThrowsError(
                try PageCorpusProjection.prepare(
                    input: input, provider: Provider(pages: []), root: root, policy: policy)
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
            }
        }
        let capped = try PageCorpusSpoolPolicy(
            maximumBytes: 128 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024)
        XCTAssertThrowsError(
            try PageCorpusProjection.prepare(
                input: input, provider: Provider(pages: []), root: root, policy: capped)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertThrowsError(try PageCorpusEmitter.add(.max, 1))
    }
}
