import Foundation

/// Deterministic owned-text corpus used by lexical metadata and semantic v2 retrieval.
///
/// Only tagged text leaves are included. References are deliberately terminal values: this
/// never follows another item's history, attachment, or remote content. The exclusions apply
/// only to root fields; an ordinary nested field with the same name remains owned content.
enum ItemTextContent {
    static let profile = "tractanda.item-text.v3"
    static let excludedRootFields: Set<String> = [
        "itemID", "revisionID", "classID", "schemaVersion", "createdAt", "modifiedAt",
        "supersedes", "actor", "operationID", "requestIdentity", "isDeleted", "permissions",
        "accessConfiguration", "categoryOverrides", "personalOverrides", "categoryParents",
        "selection", "viewDefinition", "learningFeedback", "learningSettings",
        "developmentUUIDMigration", "templateKey",
    ]

    struct Corpus: Equatable, Sendable {
        let subject: String
        let body: String
        let metadata: String

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
        return Corpus(
            subject: subject, body: body,
            metadata: leaves.map { "\($0.path):\n\($0.text)" }.joined(separator: "\n\n"))
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
