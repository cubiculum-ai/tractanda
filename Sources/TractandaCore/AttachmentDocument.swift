import Foundation

struct DocumentExtractionSnapshot: Sendable {
    let source: AttachmentDocumentSource
    let operationID: String
    let actorUID: UInt32
    let identity: DocumentConverterIdentity
    let input: Data
}

enum DocumentExtractionAdmission: Sendable {
    case replay(AttachmentCommitResult)
    case prepared(DocumentExtractionSnapshot)
}

/// Canonical reconstruction verifies parsed structure against retained raw generation.
/// It never invokes the converter or assigns PDF/image bytes to OCR text ranges.
enum AttachmentDocumentValidator {
    static func validate(_ representation: AttachmentDocumentRepresentation) throws {
        try representation.validate()
        for page in representation.pages {
            guard try DoclingDocTagsParser.parse(Data(page.parsed.rawDocTags.utf8)) == page.parsed else {
                throw TractandaError(
                    "invalidDocumentOutput", "Saved document blocks differ from raw DocTags.")
            }
            let expectedUnit = representation.source.mediaType == "application/pdf" ? "pdfPoint" : "pixel"
            guard page.geometry.sourceUnit == expectedUnit else {
                throw TractandaError(
                    "invalidDocumentOutput", "Document page units do not match its original.")
            }
        }
    }
}
