import Crypto
import Foundation

/// A source/base revision binding, never a prediction of a future publication revision.
struct PageCorpusBinding: Codable, Equatable, Sendable {
    static let layoutName = "tractanda.page-corpus.v1"
    let storeID: String
    let itemID: String
    let baseRevisionID: String
    let layout: String
    let snapshotSHA256: String
    let incomingSHA256: String?
}

/// Current saved identities are retained; incoming prepared pages have no fabricated local IDs.
struct PageCorpusDocumentPlan: Codable, Equatable, Sendable {
    let attachmentID: String
    let representationID: String?
    let savedContent: DocumentContentReference?
    let source: AttachmentDocumentSource
    let identity: DocumentConverterIdentity
    let extractedAt: String
    let rootSHA256: String?
    let pageCount: Int64
    let totalEncodedBytes: Int64
    let coverage: DocumentCoverage
    let inlinePages: [AttachmentDocumentPage]  // Historical bounded inline representation only.
    let isIncoming: Bool

    init(document: AttachmentDocumentRepresentation) throws {
        try document.validate()
        attachmentID = document.attachmentID
        representationID = document.representationID
        savedContent = document.content
        source = document.source
        identity = document.identity
        extractedAt = document.extractedAt
        rootSHA256 = document.content?.rootSHA256
        inlinePages = document.pages
        isIncoming = false
        if let content = document.content {
            pageCount = content.pageCount
            totalEncodedBytes = content.totalEncodedBytes
            coverage = content.coverage
        } else {
            pageCount = Int64(document.pages.count)
            var bytes: Int64 = 0
            for page in document.pages {
                let saved = try DocumentStoredPage(
                    pageNumber: Int64(page.pageNumber), sourceSHA256: document.source.sha256, page: page)
                bytes = try PageCorpusEmitter.add(bytes, Int64(try JSON.encode(saved).count))
            }
            totalEncodedBytes = bytes
            coverage = try DocumentCoverage(converted: pageCount)
        }
    }
    init(
        attachmentID: String, source: AttachmentDocumentSource, identity: DocumentConverterIdentity,
        extractedAt: String, rootSHA256: String, pageCount: Int64, totalEncodedBytes: Int64,
        coverage: DocumentCoverage
    ) throws {
        try PageCorpusInput.validateID(attachmentID)
        try source.validate()
        try identity.validate()
        guard Timestamp.parse(extractedAt) != nil, DocumentHashNode.isDigest(rootSHA256),
            pageCount > 0, totalEncodedBytes > 0, try coverage.processedPageCount() == pageCount,
            source.mediaType == "application/pdf" || pageCount == 1
        else { throw TractandaError("documentIntegrity", "Invalid incoming corpus page plan.") }
        self.attachmentID = attachmentID
        representationID = nil
        savedContent = nil
        self.source = source
        self.identity = identity
        self.extractedAt = extractedAt
        self.rootSHA256 = rootSHA256
        self.pageCount = pageCount
        self.totalEncodedBytes = totalEncodedBytes
        self.coverage = coverage
        inlinePages = []
        isIncoming = true
    }
    func validateIncoming() throws {
        try PageCorpusInput.validateID(attachmentID)
        try source.validate()
        try identity.validate()
        guard isIncoming, representationID == nil, savedContent == nil, inlinePages.isEmpty,
            Timestamp.parse(extractedAt) != nil, rootSHA256.map(DocumentHashNode.isDigest) == true,
            pageCount > 0, totalEncodedBytes > 0, try coverage.processedPageCount() == pageCount,
            source.mediaType == "application/pdf" || pageCount == 1
        else { throw TractandaError("documentIntegrity", "Invalid decoded incoming corpus page plan.") }
    }
}

struct PageCorpusInput: Sendable {
    let binding: PageCorpusBinding
    let revision: Revision
    let originals: [AttachmentDescriptor]
    let texts: [AttachmentTextRepresentation]
    let documents: [PageCorpusDocumentPlan]

    init(storeID: String, revision: Revision, incoming: PageCorpusDocumentPlan? = nil) throws {
        try Self.validateID(storeID)
        try incoming?.validateIncoming()
        let bytes = try JSON.encode(revision)
        guard bytes.count <= 8 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Corpus input exceeds the canonical record window.")
        }
        binding = PageCorpusBinding(
            storeID: storeID, itemID: revision.itemID, baseRevisionID: revision.revisionID,
            layout: PageCorpusBinding.layoutName, snapshotSHA256: Self.digest(bytes),
            incomingSHA256: try incoming.map { Self.digest(try JSON.encode($0)) })
        self.revision = revision
        let descriptors = try AttachmentDescriptor.descriptors(in: revision.fields)
        originals = descriptors
        texts = try AttachmentTextRepresentation.representations(in: revision.fields).filter { text in
            descriptors.contains {
                $0.attachmentID == text.attachmentID && $0.sha256 == text.source.sha256
                    && $0.byteCount == text.source.byteCount && $0.mediaType == text.source.mediaType
            }
        }
        let currentDocuments = try AttachmentDocumentRepresentation.representations(in: revision.fields)
            .filter { doc in
                descriptors.contains {
                    $0.attachmentID == doc.attachmentID && $0.sha256 == doc.source.sha256
                        && $0.byteCount == doc.source.byteCount && $0.mediaType == doc.source.mediaType
                }
            }
        var plans = try currentDocuments.map { try PageCorpusDocumentPlan(document: $0) }
        if let incoming {
            guard incoming.isIncoming, incoming.representationID == nil, incoming.savedContent == nil,
                incoming.inlinePages.isEmpty,
                descriptors.contains(where: {
                    $0.attachmentID == incoming.attachmentID && $0.sha256 == incoming.source.sha256
                        && $0.byteCount == incoming.source.byteCount
                        && $0.mediaType == incoming.source.mediaType
                })
            else {
                throw TractandaError(
                    "documentIntegrity", "Incoming corpus plan has no active local original.")
            }
            plans.removeAll { $0.attachmentID == incoming.attachmentID }
            plans.append(incoming)
        }
        documents = plans
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func validateID(_ value: String) throws {
        try Identifier.validate(value)
        guard UUID(uuidString: value)?.version1Components != nil else {
            throw TractandaError("documentIntegrity", "Corpus identity must be UUIDv1.")
        }
    }
}

/// Implementations authenticate manifest/root/source/identity/date and every proof/page before
/// invoking visit. Authentication is performed here, not by rereading a closure at final CAS.
protocol PageCorpusPageProvider: Sendable {
    func forEachPage(
        document: PageCorpusDocumentPlan, visit: (DocumentStoredPage) throws -> Void
    ) throws
}

struct PageCorpusOrigin: Codable, Equatable, Sendable {
    let kind: String
    let fieldPath: String?
    let attachmentID: String?
    let representationID: String?
    let contentID: String?
    let documentSource: AttachmentDocumentSource?
    let textSource: AttachmentTextSource?
    let pageNumber: Int64?
    let sourceByteStart: Int64?
    let sourceByteEnd: Int64?
    let rasterSHA256: String?
    let geometry: DocumentPageGeometry?
}

struct PageCorpusSpan: Codable, Equatable, Sendable {
    let blockIndex: Int64
    let unitByteStart: Int64
    let unitByteEnd: Int64
    let box: DoclingBoundingBox?
}

struct PageCorpusUnit: Sendable {
    let ordinal: Int64
    let byteStart: Int64
    let text: String
    let origin: PageCorpusOrigin
    let spans: [PageCorpusSpan]  // One bounded page, never all document blocks.
}

struct PageCorpusSummary: Codable, Equatable, Sendable {
    var unitCount: Int64 = 0
    var utf8Bytes: Int64 = 0
    var spanCount: Int64 = 0
    var converted: Int64 = 0
    var unsupported: Int64 = 0
    var truncated: Int64 = 0
    var timedOut: Int64 = 0
    var failed: Int64 = 0
}

enum PageCorpusEmitter {
    static func emit(
        _ input: PageCorpusInput, provider: any PageCorpusPageProvider,
        boundary: () throws -> Void = {}, visit: (PageCorpusUnit) throws -> Void
    ) throws -> PageCorpusSummary {
        var summary = PageCorpusSummary()
        if input.revision.isDeleted { return summary }
        func unit(_ text: String, origin: PageCorpusOrigin, spans: [PageCorpusSpan] = []) throws {
            try boundary()
            try Task.checkCancellation()
            guard text.utf8.count <= 8 * 1024 * 1024 else {
                throw TractandaError("resourceLimit", "Corpus unit exceeds its canonical window.")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let nextCount = try add(summary.unitCount, 1)
            let nextBytes = try add(summary.utf8Bytes, Int64(text.utf8.count))
            let nextSpans = try add(summary.spanCount, Int64(spans.count))
            try visit(
                PageCorpusUnit(
                    ordinal: summary.unitCount, byteStart: summary.utf8Bytes, text: text,
                    origin: origin, spans: spans))
            summary.unitCount = nextCount
            summary.utf8Bytes = nextBytes
            summary.spanCount = nextSpans
        }
        func field(_ value: ItemValue, path: String, depth: Int) throws {
            try boundary()
            guard depth <= 64 else {
                throw TractandaError("resourceLimit", "Owned-text field nesting exceeds its working window.")
            }
            switch value {
            case .text(let text):
                try unit(
                    text,
                    origin: PageCorpusOrigin(
                        kind: "field", fieldPath: path, attachmentID: nil, representationID: nil,
                        contentID: nil, documentSource: nil, textSource: nil, pageNumber: nil,
                        sourceByteStart: nil, sourceByteEnd: nil, rasterSHA256: nil, geometry: nil))
            case .object(let values):
                for key in values.keys.sorted() {
                    try field(values[key]!, path: path + "[" + quoted(key) + "]", depth: depth + 1)
                }
            case .list(let values):
                for (index, value) in values.enumerated() {
                    try field(value, path: path + "[\(index)]", depth: depth + 1)
                }
            case .integer, .real, .boolean, .date, .reference, .bytes: break
            }
        }
        for key in input.revision.fields.keys.sorted()
        where !ItemTextContent.excludedRootFields.contains(key) {
            try field(input.revision.fields[key]!, path: "field[" + quoted(key) + "]", depth: 0)
        }
        for text in input.texts {
            try unit(
                text.text,
                origin: PageCorpusOrigin(
                    kind: "originalBytes", fieldPath: nil, attachmentID: text.attachmentID,
                    representationID: text.representationID, contentID: nil, documentSource: nil,
                    textSource: text.source, pageNumber: nil, sourceByteStart: Int64(text.sourceByteStart),
                    sourceByteEnd: text.source.byteCount, rasterSHA256: nil, geometry: nil))
        }
        for document in input.documents {
            var number: Int64 = 0
            var encodedBytes: Int64 = 0
            var counts = [Int64](repeating: 0, count: 5)
            func page(_ saved: DocumentStoredPage) throws {
                try boundary()
                try saved.validate()
                let next = try add(number, 1)
                guard saved.pageNumber == next, saved.sourceSHA256 == document.source.sha256 else {
                    throw TractandaError("documentIntegrity", "Corpus provider page binding changed.")
                }
                let bytes = try JSON.encode(saved)
                guard bytes.count <= DocumentContentStore.maximumPageBytes else {
                    throw TractandaError("resourceLimit", "Corpus provider exceeded its page window.")
                }
                number = next
                encodedBytes = try add(encodedBytes, Int64(bytes.count))
                guard
                    let index = ["converted", "unsupported", "truncated", "timeout", "failed"]
                        .firstIndex(of: saved.status)
                else { throw TractandaError("documentIntegrity", "Unknown corpus page outcome.") }
                counts[index] = try add(counts[index], 1)
                guard let output = saved.page else { return }
                guard try DoclingDocTagsParser.parse(output.parsed.rawDocTags) == output.parsed,
                    output.geometry.sourceUnit
                        == (document.source.mediaType == "application/pdf" ? "pdfPoint" : "pixel")
                else { throw TractandaError("documentIntegrity", "Corpus page output/source units changed.") }
                if document.identity.preprocessing == DocumentConverterIdentity().preprocessing {
                    try output.geometry.validateContentCrop()
                }
                let spans = output.parsed.blocks.enumerated().compactMap { index, block -> PageCorpusSpan? in
                    guard !block.text.isEmpty else { return nil }
                    return PageCorpusSpan(
                        blockIndex: Int64(index), unitByteStart: Int64(block.textByteStart),
                        unitByteEnd: Int64(block.textByteEnd), box: block.location)
                }
                try unit(
                    output.parsed.text,
                    origin: PageCorpusOrigin(
                        kind: "document", fieldPath: nil, attachmentID: document.attachmentID,
                        representationID: document.representationID,
                        contentID: document.savedContent?.contentID,
                        documentSource: document.source, textSource: nil, pageNumber: number,
                        sourceByteStart: nil, sourceByteEnd: nil, rasterSHA256: output.rasterSHA256,
                        geometry: output.geometry), spans: spans)
            }
            if document.savedContent != nil || document.isIncoming {
                try provider.forEachPage(document: document, visit: page)
                let coverage = try DocumentCoverage(
                    converted: counts[0], unsupported: counts[1], truncated: counts[2],
                    timedOut: counts[3], failed: counts[4])
                guard number == document.pageCount, encodedBytes == document.totalEncodedBytes,
                    coverage == document.coverage
                else { throw TractandaError("documentIntegrity", "Corpus provider closure is incomplete.") }
            } else {
                for output in document.inlinePages {
                    try page(
                        DocumentStoredPage(
                            pageNumber: Int64(output.pageNumber), sourceSHA256: document.source.sha256,
                            page: output))
                }
            }
            summary.converted = try add(summary.converted, counts[0])
            summary.unsupported = try add(summary.unsupported, counts[1])
            summary.truncated = try add(summary.truncated, counts[2])
            summary.timedOut = try add(summary.timedOut, counts[3])
            summary.failed = try add(summary.failed, counts[4])
        }
        return summary
    }
    static func add(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard left >= 0, right >= 0, !result.overflow else {
            throw TractandaError("resourceLimit", "Corpus count is not addressable.")
        }
        return result.partialValue
    }
    private static func quoted(_ value: String) -> String {
        // Path metadata only; never part of searchable prose.
        let encoder = JSONEncoder()
        return String(decoding: (try? encoder.encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}
