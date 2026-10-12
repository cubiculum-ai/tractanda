import Foundation

/// Deterministic owned-text corpus used by lexical metadata and semantic v2 retrieval.
///
/// Only tagged text leaves are included. References are deliberately terminal values: this
/// never follows another item's history, attachment, or remote content. The exclusions apply
/// only to root fields; an ordinary nested field with the same name remains owned content.
enum ItemTextContent {
    static let profile = "tractanda.item-text.v6"
    static let excludedRootFields: Set<String> = [
        "itemID", "revisionID", "classID", "schemaVersion", "createdAt", "modifiedAt",
        "supersedes", "actor", "operationID", "requestIdentity", "isDeleted", "permissions",
        "accessConfiguration", "categoryOverrides", "personalOverrides", "categoryParents",
        "selection", "viewDefinition", "learningFeedback", "learningSettings",
        "developmentUUIDMigration", "templateKey", "attachments", "attachmentText", "attachmentDocument",
    ]

    struct Corpus: Equatable, Sendable {
        let subject: String
        let body: String
        let metadata: String
        let metadataSourceSegments: [AttachmentSourceSegment]

        init(
            subject: String, body: String, metadata: String,
            metadataSourceSegments: [AttachmentSourceSegment] = []
        ) {
            self.subject = subject
            self.body = body
            self.metadata = metadata
            self.metadataSourceSegments = metadataSourceSegments
        }
        var sourceSegments: [AttachmentSourceSegment] {
            var prefix: [String] = []
            if ItemTextContent.hasContent(subject) { prefix.append("subject:\n\(subject)") }
            if ItemTextContent.hasContent(body) { prefix.append("body:\n\(body)") }
            let bytes =
                prefix.joined(separator: "\n\n").utf8.count
                + (prefix.isEmpty ? 0 : 2) + "metadata:\n".utf8.count
            return metadataSourceSegments.map { $0.shifted(by: bytes) }
        }

        /// Field labels make boundaries and arbitrary custom-field provenance unambiguous.
        var sourceText: String {
            var sections: [String] = []
            if ItemTextContent.hasContent(subject) { sections.append("subject:\n\(subject)") }
            if ItemTextContent.hasContent(body) { sections.append("body:\n\(body)") }
            if !metadata.isEmpty { sections.append("metadata:\n\(metadata)") }
            return sections.joined(separator: "\n\n")
        }
    }

    static func corpus(for revision: Revision) -> Corpus {
        let subject = revision.fields["subject"]?.string ?? ""
        let body = revision.fields["body"]?.string ?? ""
        var leaves: [(path: String, text: String)] = []
        for key in revision.fields.keys.sorted()
        where key != "subject" && key != "body" && !excludedRootFields.contains(key) {
            collect(revision.fields[key]!, path: "field[\(quoted(key))]", into: &leaves)
        }
        var metadata = leaves.map { "\($0.path):\n\($0.text)" }.joined(separator: "\n\n")
        var segments: [AttachmentSourceSegment] = []
        // Canonical validation has already checked these bounded reserved structures.
        let descriptors = (try? AttachmentDescriptor.descriptors(in: revision.fields)) ?? []
        let representations = (try? AttachmentTextRepresentation.representations(in: revision.fields)) ?? []
        let byID = Dictionary(uniqueKeysWithValues: representations.map { ($0.attachmentID, $0) })
        for descriptor in descriptors {
            guard let representation = byID[descriptor.attachmentID],
                representation.source.sha256 == descriptor.sha256,
                representation.source.byteCount == descriptor.byteCount,
                representation.source.mediaType == descriptor.mediaType,
                hasContent(representation.text)
            else { continue }
            if !metadata.isEmpty { metadata += "\n\n" }
            metadata += "attachment:\n"
            let start = metadata.utf8.count
            metadata += representation.text
            segments.append(
                AttachmentSourceSegment(
                    itemID: revision.itemID, revisionID: revision.revisionID,
                    attachmentID: descriptor.attachmentID, representationID: representation.representationID,
                    sourceSHA256: descriptor.sha256, corpusByteStart: start,
                    corpusByteEnd: metadata.utf8.count, sourceByteStart: representation.sourceByteStart,
                    sourceByteEnd: Int(descriptor.byteCount)))
        }
        let documents = (try? AttachmentDocumentRepresentation.representations(in: revision.fields)) ?? []
        let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.attachmentID, $0) })
        for descriptor in descriptors {
            guard let document = documentsByID[descriptor.attachmentID],
                document.source.sha256 == descriptor.sha256,
                document.source.byteCount == descriptor.byteCount,
                document.source.mediaType == descriptor.mediaType
            else { continue }
            for page in document.pages where hasContent(page.parsed.text) {
                if !metadata.isEmpty { metadata += "\n\n" }
                metadata += "attachment page:\n"
                let pageStart = metadata.utf8.count
                metadata += page.parsed.text
                for (blockIndex, block) in page.parsed.blocks.enumerated() where !block.text.isEmpty {
                    segments.append(
                        AttachmentSourceSegment(
                            itemID: revision.itemID, revisionID: revision.revisionID,
                            attachmentID: descriptor.attachmentID,
                            representationID: document.representationID,
                            sourceSHA256: descriptor.sha256,
                            corpusByteStart: pageStart + block.textByteStart,
                            corpusByteEnd: pageStart + block.textByteEnd,
                            location: .document(
                                pageNumber: page.pageNumber, blockIndex: blockIndex,
                                rasterSHA256: page.rasterSHA256, geometry: page.geometry, box: block.location)
                        ))
                }
            }
        }
        return Corpus(subject: subject, body: body, metadata: metadata, metadataSourceSegments: segments)
    }

    private static func collect(
        _ value: ItemValue, path: String, into leaves: inout [(path: String, text: String)]
    ) {
        switch value {
        case .text(let text):
            if hasContent(text) { leaves.append((path, text)) }
        case .object(let values):
            for key in values.keys.sorted() {
                collect(values[key]!, path: "\(path)[\(quoted(key))]", into: &leaves)
            }
        case .list(let values):
            for (index, child) in values.enumerated() {
                collect(child, path: "\(path)[\(index)]", into: &leaves)
            }
        case .integer, .real, .boolean, .date, .reference, .bytes:
            break
        }
    }

    private static func hasContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// JSON-style escaping keeps generated paths single-line and deterministic for all valid keys.
    private static func quoted(_ key: String) -> String {
        var result = "\""
        for scalar in key.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x0C: result += "\\f"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0...0x1F: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
