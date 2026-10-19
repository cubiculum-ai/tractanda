import Foundation

/// Authenticated immutable page source. Never opens originals, follows item history, or holds Store.
struct StoredPageCorpusProvider: PageCorpusPageProvider {
    let contents: DocumentContentStore
    let incoming: PreparedDocumentContent?
    func forEachPage(
        document: PageCorpusDocumentPlan,
        visit: (DocumentStoredPage) throws -> Void
    ) throws {
        try forEachEncodedPage(document: document) { page, _ in try visit(page) }
    }
    func forEachEncodedPage(
        document: PageCorpusDocumentPlan,
        visit: (DocumentStoredPage, Int) throws -> Void
    ) throws {
        if document.isIncoming {
            guard let incoming, document.representationID == nil, document.savedContent == nil,
                document.source == incoming.source, document.identity == incoming.identity,
                document.extractedAt == incoming.extractedAt,
                document.rootSHA256 == incoming.rootEntry.sha256,
                document.pageCount == incoming.rootEntry.lastPage,
                document.totalEncodedBytes == incoming.byteCount,
                document.coverage == incoming.coverage
            else {
                throw TractandaError(
                    "documentIntegrity", "Incoming corpus provider differs from its sealed job.")
            }
            try contents.forEachEncodedPreparedJobPage(incoming, visit)
        } else {
            guard let reference = document.savedContent else {
                throw TractandaError(
                    "documentIntegrity", "Saved provider requires an authenticated content reference.")
            }
            let manifest = try contents.manifest(reference)
            guard manifest.source == document.source, manifest.identity == document.identity,
                manifest.extractedAt == document.extractedAt,
                manifest.rootSHA256 == document.rootSHA256,
                manifest.pageCount == document.pageCount,
                manifest.totalEncodedBytes == document.totalEncodedBytes,
                manifest.coverage == document.coverage
            else {
                throw TractandaError(
                    "documentIntegrity", "Saved corpus plan differs from its authenticated manifest.")
            }
            try contents.forEachEncodedPage(reference, visit)
        }
    }
}

struct StoredPageCorpusSnapshot: Sendable {
    let input: PageCorpusInput
    let provider: StoredPageCorpusProvider
}
