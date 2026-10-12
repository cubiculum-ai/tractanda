import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Immutable owner-queue admission; no ItemStore/access context escapes into material work.
struct DocumentJobMaterialWork: Sendable {
    let intent: DocumentJobIntent
    let checkpoint: DocumentJobCheckpoint
    let payloads: AttachmentPayloadStore
    let contents: DocumentContentStore
    func verifyOriginal(
        cancellation: DocumentConversionCancellation,
        progress: @escaping @Sendable (Int64) throws -> Void = { _ in }
    ) throws -> DocumentVerifiedOriginal {
        try payloads.prepareDocumentOriginal(
            descriptor: intent.descriptor, cancellation: cancellation, progress: progress)
    }
    func stage() -> DocumentPageStageWorker {
        DocumentPageStageWorker(intent: intent, checkpoint: checkpoint, contents: contents)
    }
}

/// Core-only retained original descriptor and fresh token. It is never canonical persistent identity.
final class DocumentVerifiedOriginal: @unchecked Sendable {
    let path: String
    let file: NativeSourceFileIdentity
    private let descriptors: [Int32]
    private let validate: @Sendable () throws -> Void
    init(
        path: String, file: NativeSourceFileIdentity, descriptors: [Int32],
        validate: @escaping @Sendable () throws -> Void
    ) {
        self.path = path
        self.file = file
        self.descriptors = descriptors
        self.validate = validate
    }
    func check() throws { try validate() }
    deinit { for descriptor in descriptors.reversed() { _ = close(descriptor) } }
}

struct DocumentStageSeal: Sendable {
    let jobID: String
    let generation: Int64
    let source: AttachmentDocumentSource
    let identity: DocumentConverterIdentity
    let extractedAt: String
    let acceptedPages: Int64
    let coverage: DocumentCoverage
    let prepared: PreparedDocumentContent?
}

/// One detached producer owns this writer; no page/frontier/closure traversal belongs to Store queue.
final class DocumentPageStageWorker {
    let intent: DocumentJobIntent
    private let checkpoint: DocumentJobCheckpoint
    private let contents: DocumentContentStore
    private var writer: DocumentContentWriter?
    private var prepared: PreparedDocumentContent?
    private var acceptedPages: Int64
    private var coverage: DocumentCoverage
    init(intent: DocumentJobIntent, checkpoint: DocumentJobCheckpoint, contents: DocumentContentStore) {
        self.intent = intent
        self.checkpoint = checkpoint
        self.contents = contents
        acceptedPages = checkpoint.acceptedPages
        coverage = checkpoint.coverage
    }
    func recover() throws -> DocumentStageSeal {
        try Task.checkCancellation()
        if let prepared = checkpoint.prepared {
            try contents.revalidatePrepared(prepared)
            self.prepared = prepared
        } else {
            _ = try contents.beginJob(
                id: intent.jobID, source: intent.source, identity: intent.identity,
                extractedAt: intent.extractedAt)
            let writer = try contents.reopenJob(
                stage: intent.stage, source: intent.source, identity: intent.identity,
                extractedAt: intent.extractedAt, acceptedPages: checkpoint.acceptedPages,
                pageCount: checkpoint.pageCount)
            self.writer = writer
            acceptedPages = writer.acceptedPages
            coverage = try writer.coverage
        }
        return seal()
    }
    func append(_ page: DocumentStoredPage, pageCount: Int64) throws -> DocumentStageSeal {
        guard let writer, prepared == nil, page.pageNumber <= pageCount else {
            throw TractandaError(
                "documentIntegrity", "Stage worker must recover and inspect before accepting pages.")
        }
        if page.pageNumber <= writer.acceptedPages {
            guard
                try contents.readStagedPage(
                    stage: intent.stage, source: intent.source, identity: intent.identity,
                    number: page.pageNumber) == page
            else { throw TractandaError("documentIntegrity", "Sealed page retry changed.") }
        } else {
            try writer.append(page)
        }
        acceptedPages = writer.acceptedPages
        coverage = try writer.coverage
        return seal()
    }
    func prepare(pageCount: Int64) throws -> DocumentStageSeal {
        guard pageCount > 0, acceptedPages == pageCount else {
            throw TractandaError("documentIncomplete", "Every inspected page needs a terminal outcome.")
        }
        if prepared == nil {
            guard let writer else {
                throw TractandaError("documentIncomplete", "Recover the stage before preparing publication.")
            }
            prepared = try writer.preparePublication()
            self.writer = nil
        }
        return seal()
    }
    func discard() throws {
        try contents.discardJob(stage: intent.stage, prepared: prepared ?? checkpoint.prepared)
    }
    private func seal() -> DocumentStageSeal {
        DocumentStageSeal(
            jobID: intent.jobID, generation: checkpoint.generation, source: intent.source,
            identity: intent.identity, extractedAt: intent.extractedAt, acceptedPages: acceptedPages,
            coverage: coverage, prepared: prepared)
    }
}
