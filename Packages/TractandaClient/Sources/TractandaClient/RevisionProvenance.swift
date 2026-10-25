import Foundation

/// Canonical ancestry references values in this revision's immutable snapshot, not a third body copy.
public struct RevisionProvenance: Equatable, Sendable {
    public enum Kind: String, Sendable { case authored, automaticMerge, resolution }
    public static let profile = "tractanda.revision-ancestry.v1"
    public static let supportedMergeProfile = "tractanda.merge.v2"
    public static let personalMergeProfile = "tractanda.personal-merge.v1"
    public let kind: Kind
    public let originReplicaID: String
    public let parents: [String]
    public let writtenFields: [String]
    public let unsetFields: [String]
    public let frontier: [String]
    public let mergeProfile: String?
    public let authorityWitness: AuthorityBinding?
    public static let authorityReconciliationProfile = "tractanda.authority-reconciliation.v1"
    public static let maximumBytes = 128 * 1024
    private static let managed: Set<String> = [
        "itemID", "revisionID", "createdAt", "modifiedAt", "actor", "operationID", "requestIdentity",
        "supersedes", "revisionAncestry",
    ]

    public init(
        kind: Kind, originReplicaID: String, parents: [String], writtenFields: [String],
        unsetFields: [String], frontier: [String], mergeProfile: String? = nil,
        authorityWitness: AuthorityBinding? = nil
    ) throws {
        self.kind = kind
        self.originReplicaID = originReplicaID
        self.parents = parents
        self.writtenFields = writtenFields
        self.unsetFields = unsetFields
        self.frontier = frontier
        self.mergeProfile = mergeProfile
        self.authorityWitness = authorityWitness
        try validateMetadata()
    }

    public init(value: ItemValue) throws {
        guard let object = value.map, object.count <= 9,
            Set(object.keys) == [
                "profile", "kind", "originReplicaID", "parents", "writtenFields", "unsetFields", "frontier",
            ]
                || Set(object.keys) == [
                    "profile", "kind", "originReplicaID", "parents", "writtenFields", "unsetFields",
                    "frontier", "mergeProfile",
                ]
                || Set(object.keys) == [
                    "profile", "kind", "originReplicaID", "parents", "writtenFields", "unsetFields",
                    "frontier", "mergeProfile", "authorityWitness",
                ],
            object["profile"]?.string == Self.profile,
            let kindText = object["kind"]?.string, let kind = Kind(rawValue: kindText),
            let origin = object["originReplicaID"]?.string
        else { throw TractandaError("invalidRevisionAncestry", "Invalid or unknown ancestry metadata.") }
        func strings(_ key: String, maximum: Int) throws -> [String] {
            guard let values = object[key]?.array, values.count <= maximum else {
                throw TractandaError("invalidRevisionAncestry", "Ancestry list exceeds its count window.")
            }
            return try values.map {
                guard let text = $0.string, text.utf8.count <= 1024 else {
                    throw TractandaError("invalidRevisionAncestry", "Ancestry entries require bounded text.")
                }
                return text
            }
        }
        let mergeProfile: String?
        if let entry = object["mergeProfile"] {
            guard let text = entry.string else {
                throw TractandaError("invalidRevisionAncestry", "Invalid merge profile.")
            }
            mergeProfile = text
        } else {
            mergeProfile = nil
        }
        try self.init(
            kind: kind, originReplicaID: origin, parents: strings("parents", maximum: 1024),
            writtenFields: strings("writtenFields", maximum: 4096),
            unsetFields: strings("unsetFields", maximum: 4096),
            frontier: strings("frontier", maximum: 1024), mergeProfile: mergeProfile,
            authorityWitness: try object["authorityWitness"].map(AuthorityBinding.init(value:)))
    }

    public var itemValue: ItemValue {
        var object: [String: ItemValue] = [
            "profile": .text(Self.profile), "kind": .text(kind.rawValue),
            "originReplicaID": .text(originReplicaID), "parents": .list(parents.map(ItemValue.text)),
            "writtenFields": .list(writtenFields.map(ItemValue.text)),
            "unsetFields": .list(unsetFields.map(ItemValue.text)),
            "frontier": .list(frontier.map(ItemValue.text)),
        ]
        if let mergeProfile { object["mergeProfile"] = .text(mergeProfile) }
        if let authorityWitness { object["authorityWitness"] = authorityWitness.itemValue }
        return .object(object)
    }

    private func validateMetadata() throws {
        try Self.persistentID(originReplicaID)
        guard parents.count <= 1024, frontier.count <= 1024,
            writtenFields.count <= 4096, unsetFields.count <= 4096,
            [parents, frontier, writtenFields, unsetFields].allSatisfy({ $0 == Array(Set($0)).sorted() }),
            Set(writtenFields).isDisjoint(with: unsetFields)
        else {
            throw TractandaError(
                "invalidRevisionAncestry", "Ancestry lists must be bounded, unique and sorted.")
        }
        for id in parents + frontier { try Self.persistentID(id) }
        var estimatedBytes = 512
        for field in writtenFields + unsetFields {
            guard !field.isEmpty, !field.contains("\0"), field.utf8.count <= 1024,
                !Self.managed.contains(field)
            else { throw TractandaError("invalidRevisionAncestry", "Invalid normalized field name.") }
            estimatedBytes += field.utf8.count * 6 + 16
        }
        estimatedBytes += (parents.count + frontier.count) * 64
        guard estimatedBytes <= Self.maximumBytes, try JSON.encode(itemValue).count <= Self.maximumBytes
        else {
            throw TractandaError("invalidRevisionAncestry", "Ancestry exceeds its byte window.")
        }
        switch kind {
        case .authored:
            guard parents.count <= 1, frontier.isEmpty, mergeProfile == nil, authorityWitness == nil else {
                throw TractandaError(
                    "invalidRevisionAncestry", "Authored ancestry requires at most one parent.")
            }
        case .automaticMerge:
            let ordinary =
                [Self.supportedMergeProfile, Self.personalMergeProfile].contains(mergeProfile ?? "")
                && parents.count > 1 && authorityWitness == nil
            let reconciliation =
                mergeProfile == Self.authorityReconciliationProfile && !parents.isEmpty
                && authorityWitness != nil
            guard ordinary || reconciliation, !frontier.isEmpty, writtenFields.isEmpty, unsetFields.isEmpty
            else {
                throw TractandaError("invalidRevisionAncestry", "Automatic merge metadata is inconsistent.")
            }
        case .resolution:
            guard !parents.isEmpty, !frontier.isEmpty, mergeProfile == nil, authorityWitness == nil else {
                throw TractandaError("invalidRevisionAncestry", "Resolution requires reviewed ancestry.")
            }
        }
    }

    public func validate(in fields: [String: ItemValue]) throws {
        for key in ["itemID", "revisionID"] {
            guard let id = fields[key]?.string else {
                throw TractandaError("invalidRevisionAncestry", "Missing canonical ancestry identity.")
            }
            try Self.persistentID(id)
        }
        guard !parents.contains(fields["revisionID"]!.string!) else {
            throw TractandaError("invalidRevisionAncestry", "A revision cannot parent itself.")
        }
        if let predecessor = fields["supersedes"] {
            guard let id = predecessor.string, parents == [id] else {
                throw TractandaError("invalidRevisionAncestry", "Predecessor disagrees with ancestry.")
            }
        }
        guard writtenFields.allSatisfy({ fields[$0] != nil }), unsetFields.allSatisfy({ fields[$0] == nil })
        else {
            throw TractandaError("invalidRevisionAncestry", "Normalized writes disagree with this snapshot.")
        }
        if kind == .authored, parents.isEmpty {
            guard Set(writtenFields) == Set(fields.keys).subtracting(Self.managed), unsetFields.isEmpty else {
                throw TractandaError(
                    "invalidRevisionAncestry", "Initial ancestry must seed every semantic field.")
            }
        }
    }

    private static func persistentID(_ id: String) throws {
        try Identifier.validate(id)
        var bytes = UUID(uuidString: id)!.uuid
        let valid = withUnsafeBytes(of: &bytes) { $0[6] >> 4 == 1 && $0[8] & 0xC0 == 0x80 }
        guard valid else {
            throw TractandaError("invalidRevisionAncestry", "Ancestry identity must be UUIDv1.")
        }
    }
}
