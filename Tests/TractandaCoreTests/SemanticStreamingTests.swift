import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class SemanticStreamingTests: XCTestCase {
    private let cap: Int64 = 16 * 1024 * 1024
    private let reserve: Int64 = 10 * 1024 * 1024 * 1024
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func fixture(_ body: (URL) throws -> Void) throws {
        let policy = try PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve)
        let parent = FileManager.default.temporaryDirectory
        try policy.check(at: parent, additionalBytes: cap)  // Tiny103-page text only, estimated below2MiB.
        let root = parent.appendingPathComponent("semantic-stream-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
        try check(root)
    }
    private func check(_ root: URL, additional: Int64 = 0) throws {
        try PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve).check(
            at: root, additionalBytes: additional)
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw TractandaError("resourceLimit", "Unknown fixture allocation.")
        }
        var bytes: UInt64 = 0
        var count = 0
        while let url = iterator.nextObject() as? URL {
            count += 1
            guard count <= 4096 else { throw TractandaError("resourceLimit", "Fixture entries exceed cap.") }
            var value = stat()
            guard lstat(url.path, &value) == 0, value.st_blocks >= 0,
                value.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK)
            else { throw TractandaError("resourceLimit", "Unknown fixture allocation.") }
            let allocated = UInt64(value.st_blocks).multipliedReportingOverflow(by: 512)
            let sum = bytes.addingReportingOverflow(allocated.partialValue)
            guard !allocated.overflow, !sum.overflow else {
                throw TractandaError("resourceLimit", "Fixture allocation overflow.")
            }
            bytes = sum.partialValue
        }
        guard bytes <= UInt64(cap), additional >= 0, UInt64(additional) <= UInt64(cap) - bytes else {
            throw TractandaError("resourceLimit", "Fixture allocation exceeds cap.")
        }
    }
    private func revision(_ extra: [String: ItemValue] = [:]) throws -> Revision {
        var fields: [String: ItemValue] = [
            "itemID": .text(try id()), "revisionID": .text(try id()), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date(Timestamp.now()),
            "modifiedAt": .date(Timestamp.now()),
            "actor": .text("fixture"), "operationID": .text("fixture"), "requestIdentity": .text("fixture"),
        ]
        fields.merge(extra) { _, value in value }
        return try Revision(fields: fields)
    }
    private struct Provider: PageCorpusPageProvider {
        func page(_ number: Int, source: AttachmentDocumentSource) throws -> DocumentStoredPage {
            let text = number == 97 ? "😃 e\u{301} Café page ninetyseven needle" : "page \(number)"
            let parsed = try DoclingDocTagsParser.parse("<doctag><text>" + text + "</text></doctag>")
            let geometry = try DocumentPageGeometry(
                sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint",
                displayWidth: 512, displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024,
                contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024)
            return try DocumentStoredPage(
                pageNumber: Int64(number), sourceSHA256: source.sha256,
                page: .init(
                    pageNumber: number, geometry: geometry, rasterSHA256: String(repeating: "b", count: 64),
                    parsed: parsed, generatedTokens: 32, stopReason: "stop"))
        }
        func forEachPage(document: PageCorpusDocumentPlan, visit: (DocumentStoredPage) throws -> Void) throws
        {
            for number in 1...103 { try visit(page(number, source: document.source)) }
        }
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
    private final class BatchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var maximumInputs = 0
        private var maximumBytes = 0
        func observe(_ inputs: [String]) {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            maximumInputs = max(maximumInputs, inputs.count)
            maximumBytes = max(maximumBytes, inputs.map { $0.utf8.count }.max() ?? 0)
        }
        func value() -> (Int, Int, Int) {
            lock.lock()
            defer { lock.unlock() }
            return (calls, maximumInputs, maximumBytes)
        }
    }
    func testProducerWaitsForAcknowledgementAndCancellationAwaitsItsReaderFence() async throws {
        let policy = try PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve)
        let parent = FileManager.default.temporaryDirectory
        try policy.check(at: parent, additionalBytes: cap)
        let root = parent.appendingPathComponent("semantic-ack-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        try store.setAttachmentReserveForTesting(reserve)
        _ = try store.commit(
            .init(
                classID: "Item", changes: ["body": .text(String(repeating: "😃e\u{301}é日本", count: 100))],
                operationID: "ack-source"))
        let counter = BatchCounter()
        let service = SemanticService(store: store, storage: SemanticMemoryStorage()) { _, inputs, _ in
            counter.observe(inputs)
            return inputs.map { _ in [1, 0] }
        }
        var configuration = SemanticConfiguration(
            operationID: "ack-config", endpoint: "http://127.0.0.1:11434/v1/embeddings",
            model: "fake", modelRevision: "fake", dimensions: 2, documentPrefix: "unchanged prefix",
            queryPrefix: "unchanged query")
        configuration.chunkBytes = 32
        configuration.overlapBytes = 0
        _ = try service.configure(configuration, expectedConfigurationID: nil)
        service.maintain()
        for _ in 0..<100 where counter.value().0 == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(
            counter.value().0, 1, "the producer cannot request another batch before Store acknowledgement")
        XCTAssertEqual(counter.value().1, 16)
        XCTAssertLessThanOrEqual(counter.value().2, 32)
        XCTAssertTrue(service.hasPendingDocumentWork)
        let task = try XCTUnwrap(service.cancelDocumentWork())
        await task.value
        service.maintain()
        XCTAssertFalse(service.hasPendingDocumentWork)
        XCTAssertEqual(counter.value().0, 1)
        let status = try service.status()
        XCTAssertEqual(
            status["indexedItems"] as? Int, 0, "a canceled unpublished generation never becomes current")
        try check(root)
    }

    func testUTF8CursorResetsOverlapAcrossOwnedValuesAndKeepsEachWindowBounded() throws {
        try fixture { root in
            let index = try ItemIndex(path: root.appendingPathComponent("items.sqlite").path, create: true)
            let first = String(repeating: "😃e\u{301}é日本", count: 19)
            let second = " second boundary 😃 end "
            let revision = try revision(["alpha": .text(first), "beta": .text(second)])
            try put(revision, index: index)
            let snapshot = try XCTUnwrap(
                index.captureCorpusSnapshot(
                    itemID: revision.itemID, expectedRevisionID: revision.revisionID, retentionID: id()))
            defer { if let lease = snapshot.retentionID { try? index.releaseCorpusWork(lease) } }
            var cursor = try SemanticChunkCursor(snapshot: snapshot, chunkBytes: 32, overlapBytes: 7)
            var sawSecond = false
            var firstChunkOfSecond: SemanticChunk?
            var count = 0
            while let chunk = try cursor.next(boundary: { try check(root) }) {
                count += 1
                XCTAssertLessThanOrEqual(chunk.text.utf8.count, 32)
                XCTAssertEqual(chunk.byteRange.count, chunk.text.utf8.count)
                let firstUnit = "metadata:\nfield[\"alpha\"]:\n" + first
                let secondUnit = "metadata:\nfield[\"beta\"]:\n" + second
                let expected = chunk.unitOrdinal == 0 ? Data(firstUnit.utf8) : Data(secondUnit.utf8)
                let originStart = chunk.unitOrdinal == 0 ? 0 : firstUnit.utf8.count
                let local =
                    (chunk.byteRange.lowerBound - originStart)..<(chunk.byteRange.upperBound - originStart)
                XCTAssertEqual(Data(chunk.text.utf8), expected.subdata(in: local))
                if chunk.unitOrdinal == 1 {
                    sawSecond = true
                    if firstChunkOfSecond == nil { firstChunkOfSecond = chunk }
                }
            }
            XCTAssertTrue(sawSecond)
            XCTAssertGreaterThan(count, 10)
            XCTAssertEqual(
                firstChunkOfSecond?.byteRange.lowerBound,
                ("metadata:\nfield[\"alpha\"]:\n" + first).utf8.count)
            XCTAssertEqual(firstChunkOfSecond?.unitByteRange.lowerBound, 0)
            XCTAssertTrue(firstChunkOfSecond?.text.hasPrefix("metadata:\nfield[\"beta\"]:\n") == true)
        }
    }
    func testBOMAtLabeledChunkBoundaryIsPreservedThroughVectorStorage() throws {
        try fixture { root in
            let index = try ItemIndex(path: root.appendingPathComponent("items.sqlite").path, create: true)
            let revision = try revision(["body": .text(String(repeating: "a", count: 26) + "\u{FEFF}café")])
            try put(revision, index: index)
            let corpus = try XCTUnwrap(
                index.captureCorpusSnapshot(
                    itemID: revision.itemID, expectedRevisionID: revision.revisionID, retentionID: id()))
            defer { if let lease = corpus.retentionID { try? index.releaseCorpusWork(lease) } }
            let snapshot = SemanticSnapshot(corpus: corpus, profileID: "bom", dimensions: 2)
            let storage = try SemanticVec1Storage(
                path: root.appendingPathComponent("vectors.sqlite").path, dimensions: 2, profileID: "bom",
                writeBoundary: { try self.check(root, additional: $0.estimatedAdditionalBytes) })
            let generation = try storage.begin(snapshot)
            var cursor = try SemanticChunkCursor(snapshot: corpus, chunkBytes: 32, overlapBytes: 0)
            let first = try XCTUnwrap(cursor.next())
            let second = try XCTUnwrap(cursor.next())
            XCTAssertNil(try cursor.next())
            XCTAssertEqual(first.text, "body:\n" + String(repeating: "a", count: 26))
            XCTAssertEqual(Data(second.text.utf8), Data("\u{FEFF}café".utf8))
            XCTAssertEqual(second.text.unicodeScalars.first?.value, 0xFEFF)
            XCTAssertEqual(second.byteRange, 32..<40)
            try storage.append(generation, chunks: [first, second], vectors: [[0, 1], [1, 0]])
            try storage.publish(generation, count: 2)
            let hit = try XCTUnwrap(
                storage.search(vector: [1, 0], profileID: "bom", limit: 1) { try $0(snapshot) }.first)
            XCTAssertEqual(Data(hit.text.utf8), Data(second.text.utf8))
            let window = try SemanticSource.readUnitWindow(
                corpus, ordinal: hit.unitOrdinal, offset: Int64(hit.unitByteRange.lowerBound),
                limit: hit.byteRange.count)
            XCTAssertEqual(window.data, Data(hit.text.utf8))
        }
    }

    func testPrefixOnlyWindowsRemainUTF8AndEmptyValuesDoNotProduceLabels() throws {
        try fixture { root in
            let index = try ItemIndex(path: root.appendingPathComponent("items.sqlite").path, create: true)
            let key = "owned" + String(repeating: "😃", count: 16)
            let revision = try revision([key: .text("é😃"), "empty": .text(""), "blank": .text(" \n\t")])
            try put(revision, index: index)
            let snapshot = try XCTUnwrap(
                index.captureCorpusSnapshot(
                    itemID: revision.itemID, expectedRevisionID: revision.revisionID, retentionID: id()))
            defer { if let lease = snapshot.retentionID { try? index.releaseCorpusWork(lease) } }
            XCTAssertEqual(snapshot.identity.unitCount, 1)
            var cursor = try SemanticChunkCursor(snapshot: snapshot, chunkBytes: 32, overlapBytes: 0)
            var reconstructed = ""
            var windows = 0
            while let chunk = try cursor.next() {
                windows += 1
                XCTAssertLessThanOrEqual(chunk.text.utf8.count, 32)
                XCTAssertEqual(chunk.byteRange.count, chunk.text.utf8.count)
                reconstructed += chunk.text
            }
            let prefix = "metadata:\nfield[\"" + key + "\"]:\n"
            XCTAssertGreaterThan(windows, 2)
            XCTAssertEqual(reconstructed, prefix + "é😃")
            let leadingASCII = "metadata:\nfield[\"owned".utf8.count
            XCTAssertThrowsError(
                try SemanticSource.readUnitWindow(
                    snapshot, ordinal: 0, offset: Int64(leadingASCII + 1), limit: 32))
            try check(root)
        }
    }

    func testPage97VectorCoordinatesAndCitationsUseCurrentLocalOverlay() throws {
        try fixture { root in
            let path = root.appendingPathComponent("items.sqlite").path
            let index = try ItemIndex(path: path, create: true)
            let raw = try revision(["body": .text("owned body")])
            let attachmentID = try id()
            let source = try AttachmentDocumentSource(
                itemID: raw.itemID, revisionID: raw.revisionID,
                attachmentID: attachmentID, sha256: String(repeating: "a", count: 64), byteCount: 9,
                mediaType: "application/pdf")
            let original = try AttachmentDescriptor(
                attachmentID: attachmentID, filename: "fixture.pdf", mediaType: source.mediaType,
                byteCount: 9, sha256: source.sha256)
            var fields = raw.fields
            fields["attachments"] = .list([original.itemValue])
            let base = try Revision(fields: fields)
            let provider = Provider()
            var encoded: Int64 = 0
            for page in 1...103 {
                encoded = try PageCorpusEmitter.add(
                    encoded, Int64(JSON.encode(provider.page(page, source: source)).count))
            }
            let date = Timestamp.now()
            let coverage = try DocumentCoverage(converted: 103)
            let incoming = try PageCorpusDocumentPlan(
                attachmentID: attachmentID, source: source, identity: .init(),
                extractedAt: date, rootSHA256: String(repeating: "d", count: 64), pageCount: 103,
                totalEncodedBytes: encoded, coverage: coverage)
            let input = try PageCorpusInput(storeID: id(), revision: base, incoming: incoming)
            let prepared = try PageCorpusProjection.prepare(
                input: input, provider: provider, root: root,
                policy: PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve),
                boundary: { try check(root) })
            try put(base, index: index)
            let stage = try ItemIndex.stageCorpus(
                indexPath: path, input: input, prepared: prepared, workID: id(),
                writeBoundary: { try check(root, additional: $0.estimatedAdditionalBytes) },
                boundary: { try check(root) })
            let content = try DocumentContentReference(
                contentID: id(), manifestSHA256: String(repeating: "c", count: 64),
                rootSHA256: incoming.rootSHA256!, pageCount: 103, totalEncodedBytes: encoded,
                coverage: coverage)
            let representationID = try id()
            let document = try AttachmentDocumentRepresentation(
                representationID: representationID, attachmentID: attachmentID,
                source: source, extractedAt: date, identity: .init(), content: content)
            fields["revisionID"] = .text(try id())
            fields["supersedes"] = .text(base.revisionID)
            fields["attachmentDocument"] = .list([try document.itemValue])
            let final = try Revision(fields: fields)
            try put(final, index: index, stage: stage)
            let corpus = try XCTUnwrap(
                index.captureCorpusSnapshot(
                    itemID: final.itemID, expectedRevisionID: final.revisionID, retentionID: id()))
            defer { if let lease = corpus.retentionID { try? index.releaseCorpusWork(lease) } }
            let snapshot = SemanticSnapshot(corpus: corpus, profileID: "p", dimensions: 2)
            let storage = try SemanticVec1Storage(
                path: root.appendingPathComponent("vectors.sqlite").path, dimensions: 2, profileID: "p",
                writeBoundary: { try self.check(root, additional: $0.estimatedAdditionalBytes) })
            let generation = try storage.begin(snapshot)
            var cursor = try SemanticChunkCursor(snapshot: corpus, chunkBytes: 96, overlapBytes: 7)
            var count: Int64 = 0
            while let chunk = try cursor.next() {
                try storage.append(
                    generation, chunks: [chunk],
                    vectors: [chunk.text.contains("ninetyseven") ? [1, 0] : [0, 1]])
                count += 1
            }
            try storage.publish(generation, count: count)
            let hit = try XCTUnwrap(
                storage.search(vector: [1, 0], profileID: "p", limit: 1) { try $0(snapshot) }.first)
            let labeled = try SemanticSource.readUnitWindow(
                corpus, ordinal: hit.unitOrdinal, offset: Int64(hit.unitByteRange.lowerBound),
                limit: hit.byteRange.count)
            let window = labeled.raw
            XCTAssertEqual(window.origin.pageNumber, 97)
            XCTAssertEqual(hit.text, "metadata:\nattachment page:\n😃 e\u{301} Café page ninetyseven needle")
            XCTAssertEqual(hit.text, String(data: labeled.data, encoding: .utf8))
            XCTAssertEqual(hit.unitByteRange.lowerBound, 0)
            XCTAssertGreaterThan(
                hit.byteRange.lowerBound, Int(window.byteStart),
                "semantic labels count actualUTF8 independently from raw indexed bytes")
            XCTAssertEqual(hit.byteRange.count, hit.text.utf8.count)
            let sources = try SemanticSource.passageSources(
                snapshot, window: window, range: hit.byteRange, unitStart: Int64(hit.byteRange.lowerBound))
            XCTAssertFalse(sources.isEmpty)
            let citation = try XCTUnwrap(sources.first)
            XCTAssertEqual(citation.itemID, final.itemID)
            XCTAssertEqual(citation.revisionID, final.revisionID)
            XCTAssertEqual(citation.attachmentID, attachmentID)
            XCTAssertEqual(citation.representationID, representationID)
            XCTAssertEqual(citation.sourceSHA256, source.sha256)
            XCTAssertEqual(
                citation.corpusByteStart,
                hit.byteRange.lowerBound + "metadata:\nattachment page:\n".utf8.count)
            if case .document(let page, _, _, _, _) = citation.location {
                XCTAssertEqual(page, 97)
            } else {
                XCTFail("page citation must preserve a document region")
            }
            let bytes = try JSON.encode(citation)
            XCTAssertEqual(try JSON.decode(AttachmentPassageSource.self, bytes), citation)
        }
    }
}
