import Foundation
import TractandaClient

public typealias ExtractedTextUnitResult = TractandaClient.ExtractedTextUnitResult

struct ExtractedTextUnitCall: Sendable {
    static let method = "TractandaItem/extractedTextUnit"
    let callID: String
    let arguments: Data
}

struct PreparedExtractedTextUnit: Sendable {
    let callID: String
    let corpus: IndexedCorpusSnapshot
    let canonical: StoredPageCorpusSnapshot
    let ordinal: Int64
    let offset: Int64
    let limit: Int
    let maxBytes: Int

    struct Continuation: Codable, Sendable {
        let unit: Int64
        let offset: Int64
    }
    struct Verification: Codable, Sendable {
        let status: String
        let scope: String
    }
    struct Unit: Codable, Sendable {
        let ordinal: Int64
        let corpusByteStart: Int64
        let utf8Bytes: Int64
        let offset: Int64
        let nextOffset: Int64
        let text: String
        let origin: PageCorpusOrigin
        let spans: [PageCorpusSpan]
        let coverage: DocumentCoverage?
    }
    struct Result: Codable, Sendable {
        let itemID: String
        let revisionID: String
        let sourceIdentity: IndexedCorpusIdentity
        let unit: Unit
        let next: Continuation?
        let indexConsistency: Verification
        let canonicalVerification: Verification
        let globalPlacementVerified: Bool
        let wholeDocumentVerified: Bool
    }

    func evaluate() throws -> Data {
        try Task.checkCancellation()
        let window = try ItemIndex.readCorpusUnit(
            corpus, ordinal: ordinal, offset: offset, limit: limit,
            boundary: { try Task.checkCancellation() })
        guard window.nextOffset > window.offset else {
            throw TractandaError("invalidArguments", "The window must advance within a nonempty source unit.")
        }
        let selected = try canonicalUnit(window.origin)
        try Task.checkCancellation()
        let bytes = Data(selected.text.utf8)
        guard window.byteCount == Int64(bytes.count), window.origin == selected.origin,
            window.spans == selected.spans, window.nextOffset <= Int64(bytes.count),
            window.data == bytes.subdata(in: Int(window.offset)..<Int(window.nextOffset))
        else {
            throw TractandaError(
                "indexSourceMismatch", "Cached source window differs from its canonical source.")
        }
        let next: Continuation?
        if window.nextOffset < window.byteCount {
            next = .init(unit: ordinal, offset: window.nextOffset)
        } else if ordinal + 1 < corpus.identity.unitCount {
            next = .init(unit: ordinal + 1, offset: 0)
        } else {
            next = nil
        }
        let text = String(decoding: window.data, as: UTF8.self)
        guard Data(text.utf8) == window.data else {
            throw TractandaError("indexSourceMismatch", "Source window text encoding changed.")
        }
        let result = Result(
            itemID: corpus.identity.itemID, revisionID: corpus.identity.revisionID,
            sourceIdentity: corpus.identity,
            unit: .init(
                ordinal: ordinal, corpusByteStart: window.byteStart, utf8Bytes: window.byteCount,
                offset: window.offset, nextOffset: window.nextOffset,
                text: text, origin: window.origin,
                spans: window.spans, coverage: selected.coverage), next: next,
            indexConsistency: .init(status: "currentBinding", scope: "captured component metadata"),
            canonicalVerification: .init(
                status: "verified", scope: "selected UTF8 window, unit length, locator and spans"),
            globalPlacementVerified: false, wholeDocumentVerified: false)
        let data = try JSON.encode(result)
        guard data.count <= maxBytes else {
            throw TractandaError(
                "responseTooLarge", "Reduce limit or increase maxBytes for this source window and spans.")
        }
        try Task.checkCancellation()
        return data
    }

    private struct CanonicalUnit {
        let text: String
        let origin: PageCorpusOrigin
        let spans: [PageCorpusSpan]
        let coverage: DocumentCoverage?
    }
    private func canonicalUnit(_ origin: PageCorpusOrigin) throws -> CanonicalUnit {
        let input = canonical.input
        switch origin.kind {
        case "field":
            var result: CanonicalUnit?
            try IndexCorpusPlan.forEachField(input.revision) { path, text in
                try Task.checkCancellation()
                if path == origin.fieldPath {
                    result = .init(
                        text: text,
                        origin: .init(
                            kind: "field", fieldPath: path, attachmentID: nil, representationID: nil,
                            contentID: nil, documentSource: nil, textSource: nil, pageNumber: nil,
                            sourceByteStart: nil, sourceByteEnd: nil, rasterSHA256: nil, geometry: nil),
                        spans: [], coverage: nil)
                }
            }
            guard let result else { throw mismatch() }
            return result
        case "originalBytes":
            guard
                let text = input.texts.first(where: {
                    $0.attachmentID == origin.attachmentID && $0.representationID == origin.representationID
                })
            else { throw mismatch() }
            return .init(
                text: text.text,
                origin: .init(
                    kind: "originalBytes", fieldPath: nil, attachmentID: text.attachmentID,
                    representationID: text.representationID, contentID: nil, documentSource: nil,
                    textSource: text.source, pageNumber: nil, sourceByteStart: Int64(text.sourceByteStart),
                    sourceByteEnd: text.source.byteCount, rasterSHA256: nil, geometry: nil),
                spans: [], coverage: nil)
        case "document":
            guard
                let document = input.documents.first(where: {
                    $0.attachmentID == origin.attachmentID && $0.representationID == origin.representationID
                }), let number = origin.pageNumber, number > 0, number <= document.pageCount
            else { throw mismatch() }
            let output: AttachmentDocumentPage
            if let reference = document.savedContent {
                let manifest = try canonical.provider.contents.manifest(reference)
                guard manifest.source == document.source, manifest.identity == document.identity,
                    manifest.extractedAt == document.extractedAt, manifest.rootSHA256 == document.rootSHA256,
                    manifest.pageCount == document.pageCount,
                    manifest.totalEncodedBytes == document.totalEncodedBytes,
                    manifest.coverage == document.coverage
                else { throw TractandaError("documentIntegrity", "Canonical document binding changed.") }
                try Task.checkCancellation()
                let saved = try canonical.provider.contents.readPage(reference, pageNumber: number)
                guard let page = saved.page else { throw mismatch() }
                output = page
            } else {
                guard let page = document.inlinePages.first(where: { Int64($0.pageNumber) == number })
                else { throw mismatch() }
                output = page
            }
            let spans = output.parsed.blocks.enumerated().compactMap { index, block -> PageCorpusSpan? in
                guard !block.text.isEmpty else { return nil }
                return .init(
                    blockIndex: Int64(index), unitByteStart: Int64(block.textByteStart),
                    unitByteEnd: Int64(block.textByteEnd), box: block.location)
            }
            guard spans.count <= 512 else { throw mismatch() }
            return .init(
                text: output.parsed.text,
                origin: .init(
                    kind: "document", fieldPath: nil, attachmentID: document.attachmentID,
                    representationID: document.representationID, contentID: document.savedContent?.contentID,
                    documentSource: document.source, textSource: nil, pageNumber: number,
                    sourceByteStart: nil, sourceByteEnd: nil, rasterSHA256: output.rasterSHA256,
                    geometry: output.geometry), spans: spans, coverage: document.coverage)
        default: throw mismatch()
        }
    }
    private func mismatch() -> TractandaError {
        TractandaError("indexSourceMismatch", "Cached source locator has no current canonical source.")
    }
}

struct ExtractedDocumentCoverage: Encodable {
    let attachmentID: String
    let representationID: String?
    let pageCount: Int64
    let coverage: DocumentCoverage
}

struct ExtractedTextUnitResponse: Encodable {
    let result: PreparedExtractedTextUnit.Result
    let callID: String
    let sessionState: String
    private enum CodingKeys: String, CodingKey { case methodResponses, sessionState }
    func encode(to encoder: any Encoder) throws {
        var envelope = encoder.container(keyedBy: CodingKeys.self)
        var calls = envelope.nestedUnkeyedContainer(forKey: .methodResponses)
        var call = calls.nestedUnkeyedContainer()
        try call.encode(ExtractedTextUnitCall.method)
        try call.encode(result)
        try call.encode(callID)
        try envelope.encode(sessionState, forKey: .sessionState)
    }
}
