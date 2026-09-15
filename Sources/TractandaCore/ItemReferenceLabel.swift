import Foundation

/// Optional human-readable aliases. Scope is an ordinary item identity, not ownership or membership.
public struct ItemReferenceLabel: Equatable, Sendable {
    public let label: String
    public let scope: ItemReference?

    public init(_ value: ItemValue) throws {
        guard let fields = value.map, let label = fields["label"]?.string, !label.isEmpty,
            label.utf8.count <= 256,
            !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw TractandaError(
                "invalidReferenceLabel", "A reference label needs nonempty text of at most 256 bytes.")
        }
        if let value = fields["scope"] {
            guard let reference = value.link, reference.revisionID == nil else {
                throw TractandaError(
                    "invalidReferenceLabel", "A label scope follows an item by its stable ItemID.")
            }
            scope = reference
        } else {
            scope = nil
        }
        self.label = label
    }

    public static func labels(in item: Revision) throws -> [Self] {
        guard let value = item.fields["referenceLabels"] else { return [] }
        guard let values = value.array, values.count <= 64 else {
            throw TractandaError("invalidReferenceLabel", "Use at most 64 reference labels per item.")
        }
        return try values.map(Self.init)
    }

    public static func display(in item: Revision, preferredScopes: [String] = []) -> String {
        let values = (try? labels(in: item)) ?? []
        for scope in preferredScopes.reversed() {
            if let label = values.first(where: { $0.scope?.itemID == scope }) { return label.label }
        }
        return values.first?.label ?? String(item.itemID.prefix(8))
    }
}
