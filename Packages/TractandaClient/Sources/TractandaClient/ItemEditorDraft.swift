import Foundation

/// UI-independent draft. Only edited keys are patched; unknown fields belong to the server revision.
public struct ItemEditorDraft: Codable, Equatable, Sendable {
    public static let maximumFieldBytes = 64 * 1024
    public let base: Revision?
    public let assignedCategories: [String]
    public var subject: String
    public var body: String
    public var className: String
    public var rule: String

    public init(base: Revision? = nil, assignedCategories: [String] = []) throws {
        self.base = base
        self.assignedCategories = assignedCategories
        subject = base?.fields["subject"]?.string ?? ""
        body = base?.fields["body"]?.string ?? ""
        className = base?.classID ?? "Item"
        rule = base?.fields["selection"]?.map?["expression"]?.string ?? ""
        try validate()
    }

    public func validate() throws {
        guard [subject, body, rule].allSatisfy({ $0.utf8.count <= Self.maximumFieldBytes }) else {
            throw TractandaError("editLimit", "The trial editor supports up to 64 KiB per text field.")
        }
        guard !className.isEmpty, className.utf8.count < 200 else {
            throw TractandaError("invalidClass", "Supply a class identifier shorter than 200 bytes.")
        }
    }

    /// Call only for an explicit save. Retain this exact request through an uncertain outcome.
    public func makeRequest(operationID: String = Identifier.make()) throws -> CommitRequest? {
        try validate()
        var changes: [String: ItemValue] = [:]
        var unset: [String] = []
        for (key, value) in [("subject", subject), ("body", body)] {
            if base == nil || value != (base?.fields[key]?.string ?? "") { changes[key] = .text(value) }
        }
        let originalRule = base?.fields["selection"]?.map?["expression"]?.string ?? ""
        if rule != originalRule {
            if rule.isEmpty {
                unset.append("selection")
            } else {
                var selection = base?.fields["selection"]?.map ?? [:]
                selection["language"] = .text(ItemClient.queryProfile)
                selection["expression"] = .text(rule)
                changes["selection"] = .object(selection)
            }
        }
        if base == nil, !assignedCategories.isEmpty {
            changes["categoryOverrides"] = .object(
                Dictionary(uniqueKeysWithValues: Set(assignedCategories).map { ($0, .text("include")) }))
        }
        let isRetype = base != nil && className != base?.classID
        if base != nil, changes.isEmpty, unset.isEmpty, !isRetype { return nil }
        return CommitRequest(
            action: base == nil ? .create : isRetype ? .retype : .revise,
            itemID: base?.itemID, expectedRevisionID: base?.revisionID,
            classID: base == nil || isRetype ? className : nil, changes: changes, unset: unset,
            operationID: operationID)
    }
}
