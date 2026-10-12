import CSQLite
import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class IndexCorpusIntegrationTests: XCTestCase {
    private let cap: Int64 = 16 * 1024 * 1024
    private let reserve: Int64 = 10 * 1024 * 1024 * 1024
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func root() throws -> URL {
        // Entire103-page text fixture is estimated below2MiB; never raster/model/original bulk.
        try PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve).check(
            at: FileManager.default.temporaryDirectory, additionalBytes: 2 * 1024 * 1024)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "index-corpus-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return path
    }
    private func budget(_ root: URL, additional: Int64 = 0) throws {
        let policy = try PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve)
        try policy.check(at: root, additionalBytes: additional)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { throw TractandaError("resourceLimit", "Fixture allocation is unknown.") }
        var bytes: UInt64 = 0
        var entries = 0
        while let url = enumerator.nextObject() as? URL {
            entries += 1
            guard entries <= 4096 else {
                throw TractandaError("resourceLimit", "Fixture entry cap exceeded.")
            }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_blocks >= 0,
                info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK)
            else { throw TractandaError("resourceLimit", "Fixture allocation is unknown.") }
            let product = UInt64(info.st_blocks).multipliedReportingOverflow(by: 512)
            let sum = bytes.addingReportingOverflow(product.partialValue)
            guard !product.overflow, !sum.overflow else {
                throw TractandaError("resourceLimit", "Fixture allocation overflow.")
            }
            bytes = sum.partialValue
        }
        guard bytes <= UInt64(cap), additional >= 0, UInt64(additional) <= UInt64(cap) - bytes else {
            throw TractandaError("resourceLimit", "Fixture allocation cap exceeded.")
        }
    }
    private func revision() throws -> Revision {
        try Revision(fields: [
            "itemID": .text(id()), "revisionID": .text(id()), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date(Timestamp.now()),
            "modifiedAt": .date(Timestamp.now()), "actor": .text("fixture"), "operationID": .text("fixture"),
            "requestIdentity": .text("fixture"), "body": .text("stored body Café 😃"),
            "subject": .text("owned subject"),
        ])
    }
    private func successor(_ base: Revision, _ changes: [String: ItemValue] = [:]) throws -> Revision {
        var fields = base.fields
        fields["revisionID"] = .text(try id())
        fields["supersedes"] = .text(base.revisionID)
        fields["modifiedAt"] = .date(Timestamp.now())
        fields.merge(changes) { _, new in new }
        return try Revision(fields: fields)
    }
    private struct Provider: PageCorpusPageProvider {
        let pages: Int
        func page(_ number: Int, source: AttachmentDocumentSource) throws -> DocumentStoredPage {
            let text =
                number == 97
                ? "page ninetyseven document needle"
                : number == 1
                    ? "common paper tailalpha" : number == 2 ? "headbeta common paper" : "common paper"
            let parsed = try DoclingDocTagsParser.parse("<doctag><text>" + text + "</text></doctag>")
            let geometry = try DocumentPageGeometry(
                sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint", displayWidth: 512,
                displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024, contentLeft: 0, contentTop: 0,
                contentWidth: 2048, contentHeight: 1024)
            return try DocumentStoredPage(
                pageNumber: Int64(number), sourceSHA256: source.sha256,
                page: AttachmentDocumentPage(
                    pageNumber: number, geometry: geometry, rasterSHA256: String(repeating: "b", count: 64),
                    parsed: parsed, generatedTokens: 32, stopReason: "stop"))
        }
        func forEachPage(document: PageCorpusDocumentPlan, visit: (DocumentStoredPage) throws -> Void) throws
        {
            for number in 1...pages { try visit(page(number, source: document.source)) }
        }
    }
    private struct Fixture {
        let base: Revision
        let input: PageCorpusInput
        let provider: Provider
        let final: Revision
        let reference: DocumentContentReference
        let document: AttachmentDocumentRepresentation
    }
    private func document(pages: Int = 103) throws -> Fixture {
        let raw = try revision()
        let attachmentID = try id()
        let source = try AttachmentDocumentSource(
            itemID: raw.itemID, revisionID: raw.revisionID, attachmentID: attachmentID,
            sha256: String(repeating: "a", count: 64), byteCount: (1 << 40) + 7, mediaType: "application/pdf")
        let original = try AttachmentDescriptor(
            attachmentID: attachmentID, filename: "hidden-filename-noise.pdf", mediaType: source.mediaType,
            byteCount: source.byteCount, sha256: source.sha256)
        var fields = raw.fields
        fields["attachments"] = .list([original.itemValue])
        let base = try Revision(fields: fields)
        let provider = Provider(pages: pages)
        var encoded: Int64 = 0
        for number in 1...pages {
            encoded = try PageCorpusEmitter.add(
                encoded, Int64(JSON.encode(provider.page(number, source: source)).count))
        }
        let date = Timestamp.now()
        let coverage = try DocumentCoverage(converted: Int64(pages))
        let incoming = try PageCorpusDocumentPlan(
            attachmentID: attachmentID, source: source, identity: .init(), extractedAt: date,
            rootSHA256: String(repeating: "d", count: 64), pageCount: Int64(pages),
            totalEncodedBytes: encoded, coverage: coverage)
        let input = try PageCorpusInput(storeID: id(), revision: base, incoming: incoming)
        let reference = try DocumentContentReference(
            contentID: id(), manifestSHA256: String(repeating: "c", count: 64),
            rootSHA256: incoming.rootSHA256!, pageCount: Int64(pages), totalEncodedBytes: encoded,
            coverage: coverage)
        let document = try AttachmentDocumentRepresentation(
            representationID: id(), attachmentID: attachmentID, source: source, extractedAt: date,
            identity: .init(), content: reference)
        let final = try successor(base, ["attachmentDocument": .list([document.itemValue])])
        return Fixture(
            base: base, input: input, provider: provider, final: final, reference: reference,
            document: document)
    }
    private func put(_ revision: Revision, index: ItemIndex, stage: IndexedCorpusStage? = nil) throws {
        try index.execute("BEGIN IMMEDIATE")
        do {
            try index.put(revision, corpus: stage)
            try index.execute("COMMIT")
        } catch {
            try? index.execute("ROLLBACK")
            throw error
        }
    }
    private func stage(
        _ fixture: Fixture, indexPath: String, root: URL, workID: String? = nil, failAfterUnit: Bool = false,
        failAfterCommit: Bool = false
    ) throws -> IndexedCorpusStage {
        let prepared = try PageCorpusProjection.prepare(
            input: fixture.input, provider: fixture.provider, root: root,
            policy: PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve),
            boundary: { try budget(root) })
        return try ItemIndex.stageCorpus(
            indexPath: indexPath, input: fixture.input, prepared: prepared, workID: workID ?? id(),
            writeBoundary: { batch in
                try budget(root, additional: batch.estimatedAdditionalBytes)
                if failAfterCommit, batch.phase == .afterCommit, batch.units == 1 {
                    throw TractandaError(
                        "resourceLimit", "Mocked postcommit capacity failure; retained ledger must survive.")
                }
                if failAfterUnit, batch.phase == .after, batch.units == 1 {
                    throw TractandaError("resourceLimit", "Mocked observed allocation exceeds budget.")
                }
            }, boundary: { try budget(root) })
    }

    func test103PagesAreHiddenUntilCurrentPromotionAndPhraseResultsDeduplicate() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("items.sqlite").path
        let index = try ItemIndex(path: path, create: true)
        let fixture = try document()
        try put(fixture.base, index: index)
        let prepared = try stage(fixture, indexPath: path, root: root)
        XCTAssertTrue(try index.ids(lexicalText: "document needle").isEmpty)
        let reloaded = try XCTUnwrap(
            ItemIndex.loadStagedCorpus(indexPath: path, input: fixture.input, workID: prepared.workID))
        XCTAssertEqual(reloaded, prepared)
        try put(fixture.final, index: index, stage: reloaded)
        XCTAssertEqual(try index.ids(lexicalText: "document needle"), [fixture.final.itemID])
        XCTAssertEqual(try index.ids(lexicalText: "common paper"), [fixture.final.itemID])
        XCTAssertTrue(try index.ids(lexicalText: "tailalpha headbeta").isEmpty)
        XCTAssertTrue(try index.ids(lexicalText: "hidden filename noise").isEmpty)
        let page = try index.orderedPage(
            lexicalText: "common paper", classEquals: nil, order: .modifiedAt, position: 0, limit: 16,
            fastCount: true, accepts: { _ in true })
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.ids, [fixture.final.itemID])
        let snapshot = try XCTUnwrap(
            index.captureCorpusSnapshot(
                itemID: fixture.final.itemID, expectedRevisionID: fixture.final.revisionID))
        let component = try XCTUnwrap(snapshot.links.first(where: { $0.component.kind == "document" }))
        let window = try ItemIndex.readCorpusUnit(snapshot, ordinal: component.unitStart + 96)
        XCTAssertEqual(window.origin.pageNumber, 97)
        XCTAssertEqual(window.origin.representationID, fixture.document.representationID)
        XCTAssertEqual(window.origin.contentID, fixture.reference.contentID)
        XCTAssertEqual(window.spans.count, 1)
        XCTAssertEqual(String(data: window.data, encoding: .utf8), "page ninetyseven document needle")
        XCTAssertTrue(try index.textMatches(fixture.final))
        try budget(root)
    }

    func testMetadataCopyDetachAndReaderRetentionReuseBoundDocumentGeneration() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("items.sqlite").path
        let index = try ItemIndex(path: path, create: true)
        let fixture = try document()
        try put(fixture.base, index: index)
        try put(fixture.final, index: index, stage: stage(fixture, indexPath: path, root: root))
        let lease = try id()
        let before = try XCTUnwrap(
            index.captureCorpusSnapshot(
                itemID: fixture.final.itemID, expectedRevisionID: fixture.final.revisionID, retentionID: lease
            ))
        let metadata = try successor(fixture.final, ["body": .text("changed owned body")])
        try put(metadata, index: index)
        let after = try XCTUnwrap(
            index.captureCorpusSnapshot(itemID: metadata.itemID, expectedRevisionID: metadata.revisionID))
        let oldDoc = try XCTUnwrap(before.links.first(where: { $0.component.kind == "document" }))
        let newDoc = try XCTUnwrap(after.links.first(where: { $0.component.kind == "document" }))
        XCTAssertEqual(oldDoc.component.generationID, newDoc.component.generationID)
        XCTAssertNotEqual(before.identity.contentHash, after.identity.contentHash)
        let original = try AttachmentDescriptor(
            attachmentID: id(), filename: "copy.pdf", mediaType: fixture.document.source.mediaType,
            byteCount: fixture.document.source.byteCount, sha256: fixture.document.source.sha256)
        let copiedRef = try DocumentContentReference(
            contentID: id(), manifestSHA256: fixture.reference.manifestSHA256,
            rootSHA256: fixture.reference.rootSHA256, pageCount: fixture.reference.pageCount,
            totalEncodedBytes: fixture.reference.totalEncodedBytes, coverage: fixture.reference.coverage)
        let copiedDoc = try AttachmentDocumentRepresentation(
            representationID: id(), attachmentID: original.attachmentID, source: fixture.document.source,
            extractedAt: fixture.document.extractedAt, identity: fixture.document.identity, content: copiedRef
        )
        var copyFields = metadata.fields
        copyFields["itemID"] = .text(try id())
        copyFields["revisionID"] = .text(try id())
        copyFields.removeValue(forKey: "supersedes")
        copyFields["attachments"] = .list([original.itemValue])
        copyFields["attachmentDocument"] = .list([try copiedDoc.itemValue])
        let copy = try Revision(fields: copyFields)
        try put(copy, index: index)
        let copied = try XCTUnwrap(
            index.captureCorpusSnapshot(itemID: copy.itemID, expectedRevisionID: copy.revisionID))
        let link = try XCTUnwrap(copied.links.first(where: { $0.component.kind == "document" }))
        XCTAssertEqual(link.component.generationID, oldDoc.component.generationID)
        let window = try ItemIndex.readCorpusUnit(copied, ordinal: link.unitStart + 96)
        XCTAssertEqual(window.origin.attachmentID, original.attachmentID)
        XCTAssertEqual(window.origin.representationID, copiedDoc.representationID)
        XCTAssertEqual(window.origin.documentSource, fixture.document.source)
        try put(
            successor(metadata, ["attachments": .list([]), "attachmentDocument": .list([])]), index: index)
        try put(successor(copy, ["attachments": .list([]), "attachmentDocument": .list([])]), index: index)
        XCTAssertTrue(try index.ids(lexicalText: "document needle").isEmpty)
        XCTAssertEqual(try index.cleanupCorpus(), 0)
        XCTAssertEqual(
            try ItemIndex.readCorpusUnit(before, ordinal: oldDoc.unitStart + 96).origin.pageNumber, 97)
        try index.releaseCorpusWork(lease)
        XCTAssertGreaterThan(try index.cleanupCorpus(), 0)
        XCTAssertThrowsError(try ItemIndex.readCorpusUnit(before, ordinal: oldDoc.unitStart + 96))
        try budget(root)
    }

    func testRejectedBatchDoesNotPublishAndSourceFingerprintRejectsChangedBase() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("items.sqlite").path
        let index = try ItemIndex(path: path, create: true)
        let fixture = try document(pages: 2)
        try put(fixture.base, index: index)
        XCTAssertThrowsError(try stage(fixture, indexPath: path, root: root, failAfterUnit: true))
        let retained = try XCTUnwrap(index.corpusWorkPage().first)
        XCTAssertGreaterThan(try index.corpusRetainedBytes(retained.workID), 0)
        try index.releaseCorpusWork(retained.workID)  // This test owns/fences the stopped producer.
        _ = try index.cleanupCorpus()
        XCTAssertTrue(try index.corpusWorkPage().isEmpty)
        XCTAssertTrue(try index.ids(lexicalText: "common paper").isEmpty)
        let prepared = try stage(fixture, indexPath: path, root: root)
        let changed = try successor(
            fixture.base,
            [
                "body": .text("rebased subject and body"),
                "attachmentDocument": .list([fixture.document.itemValue]),
            ])
        XCTAssertThrowsError(try put(changed, index: index, stage: prepared))
        XCTAssertTrue(try index.ids(lexicalText: "common paper").isEmpty)
        try index.releaseCorpusWork(prepared.workID)
        try budget(root)
    }

    func testUTF8WindowsKeepScalarBoundariesAndOwnedFieldPhraseBoundary() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("items.sqlite").path
        let index = try ItemIndex(path: path, create: true)
        var fields = try revision().fields
        fields["body"] = .text("😃 café says \"loan note\" literal AND beta")
        fields["left"] = .text("tailalpha")
        fields["right"] = .text("headbeta")
        let value = try Revision(fields: fields)
        try put(value, index: index)
        XCTAssertEqual(try index.ids(lexicalText: "cafe says loan note"), [value.itemID])
        XCTAssertEqual(try index.ids(lexicalText: "literal AND beta"), [value.itemID])
        XCTAssertTrue(try index.ids(lexicalText: "tailalpha headbeta").isEmpty)
        let snapshot = try XCTUnwrap(
            index.captureCorpusSnapshot(itemID: value.itemID, expectedRevisionID: value.revisionID))
        XCTAssertThrowsError(try ItemIndex.readCorpusUnit(snapshot, ordinal: 0, limit: 1))
        XCTAssertThrowsError(try ItemIndex.readCorpusUnit(snapshot, ordinal: 0, offset: 1, limit: 16))
        let window = try ItemIndex.readCorpusUnit(snapshot, ordinal: 0, limit: 5)
        XCTAssertEqual(String(data: window.data, encoding: .utf8), "😃 ")
        XCTAssertEqual(window.nextOffset, 5)
        XCTAssertTrue(try SpotlightQuery("body == '*loan note*'").matches(value))
        try budget(root)
    }
    func testPostcommitFailureKeepsAbsoluteDebtAcrossReopenUntilActualDisposal() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("items.sqlite").path
        let fixture = try document(pages: 4)
        let workID = try id()
        var debt: Int64 = 0
        do {
            let index = try ItemIndex(path: path, create: true)
            try put(fixture.base, index: index)
            XCTAssertThrowsError(
                try stage(fixture, indexPath: path, root: root, workID: workID, failAfterCommit: true))
            debt = try index.corpusRetainedBytes(workID)
            XCTAssertGreaterThan(debt, 0)
            XCTAssertEqual(try index.retainedCorpusWorkPage().first?.retainedEncodedBytes, debt)
            XCTAssertTrue(try index.ids(lexicalText: "common paper").isEmpty)
        }
        let reopened = try ItemIndex(path: path, create: false)
        XCTAssertEqual(try reopened.corpusRetainedBytes(workID), debt)
        XCTAssertThrowsError(
            try ItemIndex.loadStagedCorpus(indexPath: path, input: fixture.input, workID: workID))
        try reopened.releaseCorpusWork(workID)
        // Fencing alone is not disposal/refund.
        XCTAssertGreaterThan(try reopened.corpusRetainedBytes(workID), 0)
        _ = try reopened.cleanupCorpus(limit: 1)
        XCTAssertEqual(try reopened.corpusRetainedBytes(workID), 0)
        XCTAssertTrue(try reopened.retainedCorpusWorkPage().isEmpty)
        try budget(root)
    }

    func testPostcommitObservationHasNoWriterLockAndReuseTransfersSingleDebtOwner() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("items.sqlite").path
        let index = try ItemIndex(path: path, create: true)
        let fixture = try document(pages: 2)
        try put(fixture.base, index: index)
        let prepared = try PageCorpusProjection.prepare(
            input: fixture.input, provider: fixture.provider, root: root,
            policy: PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve))
        let firstID = try id()
        var post = 0
        let first = try ItemIndex.stageCorpus(
            indexPath: path, input: fixture.input, prepared: prepared, workID: firstID,
            writeBoundary: { batch in
                try budget(root, additional: batch.estimatedAdditionalBytes)
                if batch.phase == .afterCommit {
                    post += 1
                    let other = try ItemIndex(path: path, create: false)
                    // Would be busy/deadlock if the stage still held its writer lock.
                    try other.execute("BEGIN IMMEDIATE")
                    try other.execute("ROLLBACK")
                    XCTAssertEqual(try other.corpusRetainedBytes(firstID), batch.retainedEncodedBytes)
                }
            }, boundary: { try budget(root) })
        XCTAssertGreaterThan(post, 2)
        let firstDebt = try index.corpusRetainedBytes(firstID)
        let secondID = try id()
        let second = try ItemIndex.stageCorpus(
            indexPath: path, input: fixture.input, prepared: prepared, workID: secondID,
            writeBoundary: { try budget(root, additional: $0.estimatedAdditionalBytes) },
            boundary: { try budget(root) })
        let secondHeaderDebt = try index.corpusRetainedBytes(secondID)
        XCTAssertEqual(first.components.map(\.generationID), second.components.map(\.generationID))
        XCTAssertLessThan(secondHeaderDebt, firstDebt)
        try index.releaseCorpusWork(firstID)
        XCTAssertEqual(try index.corpusRetainedBytes(firstID), 0)
        XCTAssertGreaterThan(try index.corpusRetainedBytes(secondID), secondHeaderDebt)
        try put(fixture.final, index: index, stage: second)
        XCTAssertEqual(try index.corpusRetainedBytes(secondID), 0)
        XCTAssertEqual(try index.ids(lexicalText: "common paper"), [fixture.final.itemID])
        XCTAssertEqual(try index.cleanupCorpus(), 0)
        XCTAssertEqual(index.corpusGCStatsForTesting.unitsExamined, 0)
        try budget(root)
    }

    func testGCCursorVisitsBoundedCandidatesAndUsesPerGenerationIndex() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("items.sqlite").path
        let index = try ItemIndex(path: path, create: true)
        let fixture = try document()
        try put(fixture.base, index: index)
        try put(fixture.final, index: index, stage: stage(fixture, indexPath: path, root: root))
        XCTAssertEqual(try index.cleanupCorpus(), 0)
        XCTAssertEqual(index.corpusGCStatsForTesting.candidateGenerations, 0)
        XCTAssertEqual(index.corpusGCStatsForTesting.unitsExamined, 0)  //103livepages were not scanned.
        let plans = try index.corpusGCPlanForTesting().joined(separator: " ").uppercased()
        XCTAssertTrue(plans.contains("INDEX"))
        XCTAssertFalse(plans.contains("SCAN CORPUS_UNIT"))
        let lease = try id()
        let snapshot = try XCTUnwrap(
            index.captureCorpusSnapshot(
                itemID: fixture.final.itemID, expectedRevisionID: fixture.final.revisionID, retentionID: lease
            ))
        try put(
            successor(fixture.final, ["attachmentDocument": .list([]), "attachments": .list([])]),
            index: index)
        XCTAssertEqual(try index.cleanupCorpus(), 0)
        XCTAssertLessThanOrEqual(index.corpusGCStatsForTesting.candidateGenerations, 16)
        XCTAssertEqual(index.corpusGCStatsForTesting.unitsExamined, 0)
        try index.releaseCorpusWork(lease)
        XCTAssertEqual(try index.cleanupCorpus(limit: 1), 1)
        XCTAssertEqual(index.corpusGCStatsForTesting.unitsExamined, 1)
        XCTAssertThrowsError(try ItemIndex.readCorpusUnit(snapshot, ordinal: 2))
        try budget(root)
    }

    /// Models the post-concurrent-seal metadata state, not page authentication/inference.
    ///129validcomponents retain129readyroots while129private duplicates await disposal.
    func testTransferredOwnershipBeyondComponentCapPromotesAndDisposesBoundedly() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("items.sqlite").path
        let index = try ItemIndex(path: path, create: true)
        var fields = try revision().fields
        fields["body"] = .text("")
        fields["subject"] = .text("")
        var originals: [ItemValue] = []
        var documents: [ItemValue] = []
        let itemID = try XCTUnwrap(fields["itemID"]?.string)
        let revisionID = try XCTUnwrap(fields["revisionID"]?.string)
        for _ in 0..<128 {
            let attachmentID = try id()
            let source = try AttachmentDocumentSource(
                itemID: itemID, revisionID: revisionID, attachmentID: attachmentID,
                sha256: String(repeating: "a", count: 64), byteCount: 100, mediaType: "application/pdf")
            let original = try AttachmentDescriptor(
                attachmentID: attachmentID, filename: "metadata-only.pdf", mediaType: source.mediaType,
                byteCount: source.byteCount, sha256: source.sha256)
            let reference = try DocumentContentReference(
                contentID: id(), manifestSHA256: String(repeating: "c", count: 64),
                rootSHA256: String(repeating: "d", count: 64), pageCount: 1, totalEncodedBytes: 1,
                coverage: DocumentCoverage(converted: 1))
            let document = try AttachmentDocumentRepresentation(
                representationID: id(), attachmentID: attachmentID, source: source,
                extractedAt: Timestamp.now(), identity: .init(), content: reference)
            originals.append(original.itemValue)
            documents.append(try document.itemValue)
        }
        fields["attachments"] = .list(originals)
        fields["attachmentDocument"] = .list(documents)
        let base = try Revision(fields: fields)
        let input = try PageCorpusInput(storeID: id(), revision: base)
        let plans = try IndexCorpusPlan.components(input)
        XCTAssertEqual(plans.count, 129)
        let firstID = try id()
        let secondID = try id()
        let sourceJSON = String(decoding: try JSON.encode(input.binding), as: UTF8.self)
        // Fixed positive ledger values are intentional metadata fixtures, not physical-byte claims.
        try index.execute("INSERT INTO corpus_work VALUES (?,'stage',?,100)", [firstID, sourceJSON])
        try index.execute("INSERT INTO corpus_work VALUES (?,'stage',?,100)", [secondID, sourceJSON])
        var retained: [IndexedCorpusComponent] = []
        let writer = try IndexCorpusSQL(path: path, readOnly: false)
        try writer.transaction {
            for plan in plans {
                let ready = try id()
                let duplicate = try id()
                try writer.execute(
                    "INSERT INTO corpus_generation VALUES (?,?,?,'ready',0,0,?,50,50)",
                    [.text(ready), .text(plan.sourceKey), .text(plan.kind), .text(firstID)])
                try writer.execute(
                    "INSERT INTO corpus_generation VALUES (?,?,?,'writing',0,0,?,50,50)",
                    [.text(duplicate), .text(plan.sourceKey), .text(plan.kind), .text(secondID)])
                try writer.execute(
                    "INSERT INTO corpus_work_generation VALUES (?,?)", [.text(firstID), .text(ready)])
                // The second import has already adopted the first import's ready generation.
                try writer.execute(
                    "INSERT INTO corpus_work_generation VALUES (?,?)", [.text(secondID), .text(ready)])
                try writer.execute("INSERT INTO corpus_gc_candidate VALUES (?)", [.text(duplicate)])
                retained.append(
                    .init(
                        generationID: ready, sourceKey: plan.sourceKey, kind: plan.kind, unitCount: 0,
                        byteCount: 0))
            }
        }
        try budget(root)
        try index.releaseCorpusWork(firstID)
        XCTAssertEqual(try index.corpusRetainedBytes(firstID), 0)
        var owned: Int64 = 0
        try writer.rows("SELECT count(*) FROM corpus_generation WHERE owner_work_id=?", [.text(secondID)]) {
            owned = sqlite3_column_int64($0, 0)
        }
        XCTAssertEqual(owned, 258)  // This exact admitted state rejected promotion in the reviewed code.
        let indexID = try XCTUnwrap(writer.scalar("SELECT id FROM corpus_index_identity"))
        let stage = IndexedCorpusStage(
            workID: secondID, indexIdentity: indexID, fence: try IndexCorpusFileFence.capture(path),
            source: input.binding, ordinaryFingerprint: try IndexCorpusPlan.ordinaryFingerprint(base),
            components: retained)
        let final = try successor(base)
        try put(final, index: index, stage: stage)
        let debt = try index.corpusRetainedBytes(secondID)
        XCTAssertGreaterThan(debt, 0)  // Private duplicate headers remain charged after successful promotion.
        let lease = try id()
        let snapshot = try XCTUnwrap(
            index.captureCorpusSnapshot(
                itemID: final.itemID, expectedRevisionID: final.revisionID, retentionID: lease))
        XCTAssertEqual(snapshot.links.count, 129)
        try index.releaseCorpusWork(secondID)  // Empty retained refs +129orphan ownership is valid disposal.
        XCTAssertEqual(try index.corpusRetainedBytes(secondID), debt)
        for _ in 0..<10 {
            _ = try index.cleanupCorpus()
            XCTAssertLessThanOrEqual(index.corpusGCStatsForTesting.candidateGenerations, 16)
            XCTAssertEqual(index.corpusGCStatsForTesting.unitsExamined, 0)
            try budget(root)
        }
        XCTAssertEqual(try index.corpusRetainedBytes(secondID), 0)
        XCTAssertFalse(try index.retainedCorpusWorkPage().contains(where: { $0.workID == secondID }))
        let stillCurrent = try XCTUnwrap(
            index.captureCorpusSnapshot(itemID: final.itemID, expectedRevisionID: final.revisionID))
        XCTAssertEqual(stillCurrent.links.map { $0.component.generationID }, retained.map(\.generationID))
        XCTAssertTrue(try index.corpusMatches(final))
        try index.releaseCorpusWork(lease)
        XCTAssertEqual(try index.cleanupCorpus(), 0)
    }

}
