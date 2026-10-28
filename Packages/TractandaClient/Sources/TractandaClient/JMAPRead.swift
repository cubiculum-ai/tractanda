import Foundation

/// The protocol representation of an own value. Canonical ItemValue Codable is unchanged.
/// Every tagged integer uses a decimal string so its full Int64 domain survives JSON clients.
public struct JMAPItemValue: Codable, Equatable, Sendable {
    public let value: ItemValue
    public init(_ value: ItemValue) { self.value = value }
    private enum CodingKeys: String, CodingKey { case type, value }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "integer":
            let text = try c.decode(String.self, forKey: .value)
            guard let integer = Int64(text), String(integer) == text else {
                throw TractandaError(
                    "invalidValue", "Wire integers require a canonical Int64 decimal string.")
            }
            value = .integer(integer)
        case "list": value = .list(try c.decode([Self].self, forKey: .value).map(\.value))
        case "object": value = .object(try c.decode([String: Self].self, forKey: .value).mapValues(\.value))
        case "text": value = .text(try c.decode(String.self, forKey: .value))
        case "real": value = .real(try c.decode(Double.self, forKey: .value))
        case "boolean": value = .boolean(try c.decode(Bool.self, forKey: .value))
        case "date": value = .date(try c.decode(String.self, forKey: .value))
        case "reference": value = .reference(try c.decode(ItemReference.self, forKey: .value))
        case "bytes": value = .bytes(try c.decode(Data.self, forKey: .value))
        default: throw TractandaError("unsupportedValueType", "Unknown wire value encoding.")
        }
        try value.validate()
    }
    public func encode(to encoder: any Encoder) throws {
        try value.validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        func tag(_ name: String) throws { try c.encode(name, forKey: .type) }
        switch value {
        case .integer(let integer):
            try tag("integer")
            try c.encode(String(integer), forKey: .value)
        case .list(let values):
            try tag("list")
            try c.encode(values.map(Self.init), forKey: .value)
        case .object(let values):
            try tag("object")
            try c.encode(values.mapValues(Self.init), forKey: .value)
        case .text(let text):
            try tag("text")
            try c.encode(text, forKey: .value)
        case .real(let real):
            try tag("real")
            try c.encode(real, forKey: .value)
        case .boolean(let boolean):
            try tag("boolean")
            try c.encode(boolean, forKey: .value)
        case .date(let date):
            try tag("date")
            try c.encode(date, forKey: .value)
        case .reference(let reference):
            try tag("reference")
            try c.encode(reference, forKey: .value)
        case .bytes(let bytes):
            try tag("bytes")
            try c.encode(bytes, forKey: .value)
        }
    }
}

/// Standard properties select DTO properties, independently of the vendor's inner-field selection.
public struct JMAPReadProperties: Equatable, Sendable {
    public enum Record: Sendable { case item, revision }
    public let names: Set<String>?
    public init(_ names: [String]?, record: Record) throws {
        let allowed: Set<String> =
            switch record {
            case .item: ["id", "revisionId", "formatVersion", "fields", "resolution"]
            case .revision: ["id", "itemId", "formatVersion", "fields"]
            }
        if let names {
            guard Set(names).isSubset(of: allowed) else {
                throw TractandaError("invalidArguments", "Unknown read object property.")
            }
            self.names = Set(names).union(["id"])
        } else {
            self.names = allowed
        }
    }
    public func includes(_ name: String) -> Bool { names?.contains(name) ?? true }
}

/// A current Item projection. An unresolved item has an identity and authorized state, but no content.
public struct JMAPItemRecord: Codable, Equatable, Sendable {
    public let id: String
    public let revisionID: String?
    public let formatVersion: Int?
    public let fields: [String: ItemValue]?
    public let resolution: ItemState?
    private let properties: JMAPReadProperties

    public init(
        id: String, revisionID: String?, formatVersion: Int?, fields: [String: ItemValue]?,
        resolution: ItemState?, properties: [String]? = nil
    ) throws {
        try Identifier.validate(id)
        if let revisionID { try Identifier.validate(revisionID) }
        guard resolution?.itemID == nil || resolution?.itemID == id,
            fields?["itemID"]?.string == nil || fields?["itemID"]?.string == id,
            revisionID == nil || fields?["revisionID"]?.string == nil
                || fields?["revisionID"]?.string == revisionID
        else { throw TractandaError("invalidResponse", "Item wire identities disagree.") }
        if let resolution, resolution.status != .ready {
            guard revisionID == nil, fields == nil, formatVersion == nil else {
                throw TractandaError(
                    "invalidResponse", "An unresolved item cannot expose representative content.")
            }
        }
        self.id = id
        self.revisionID = revisionID
        self.formatVersion = formatVersion
        self.fields = fields
        self.resolution = resolution
        self.properties = try JMAPReadProperties(properties, record: .item)
    }
    public init(_ revision: Revision, resolution: ItemState, properties: [String]? = nil) throws {
        guard resolution.status == .ready,
            resolution.representativeRevisionID == revision.revisionID
        else { throw TractandaError("invalidResponse", "Item state does not describe this representative.") }
        try self.init(
            id: revision.itemID, revisionID: revision.revisionID, formatVersion: revision.formatVersion,
            fields: revision.fields, resolution: resolution, properties: properties)
    }
    /// A nested state locator is diagnostic when unresolved; it never supplies current content.
    public init(unresolved state: ItemState, properties: [String]? = nil) throws {
        guard state.status != .ready else {
            throw TractandaError("invalidResponse", "Expected an unresolved current item state.")
        }
        try self.init(
            id: state.itemID, revisionID: nil, formatVersion: nil, fields: nil,
            resolution: state, properties: properties)
    }
    /// A partial selection is not a canonical revision. Conversion validates all canonical requirements.
    public func canonicalRevision() throws -> Revision {
        guard let revisionID, let formatVersion, let fields,
            resolution?.status == nil || resolution?.status == .ready
        else {
            throw TractandaError("incompleteProjection", "Item has no complete representative projection.")
        }
        let revision = try Revision(fields: fields, formatVersion: formatVersion)
        guard revision.itemID == id, revision.revisionID == revisionID else {
            throw TractandaError("invalidResponse", "Item wire identities disagree.")
        }
        return revision
    }
    private enum CodingKeys: String, CodingKey {
        case id, formatVersion, fields, resolution
        case revisionID = "revisionId"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            revisionID: c.decodeIfPresent(String.self, forKey: .revisionID),
            formatVersion: c.decodeIfPresent(Int.self, forKey: .formatVersion),
            fields: c.decodeIfPresent([String: JMAPItemValue].self, forKey: .fields)?.mapValues(\.value),
            resolution: c.decodeIfPresent(ItemState.self, forKey: .resolution),
            properties: c.allKeys.map(\.stringValue))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if properties.includes("revisionId") { try c.encode(revisionID, forKey: .revisionID) }
        if properties.includes("formatVersion") { try c.encode(formatVersion, forKey: .formatVersion) }
        if properties.includes("fields") {
            try c.encode(fields?.mapValues(JMAPItemValue.init), forKey: .fields)
        }
        if properties.includes("resolution") { try c.encode(resolution, forKey: .resolution) }
    }
}

/// An immutable Revision projection, identified independently from its containing Item.
public struct JMAPRevisionRecord: Codable, Equatable, Sendable {
    public let id: String
    public let itemID: String?
    public let formatVersion: Int?
    public let fields: [String: ItemValue]?
    private let properties: JMAPReadProperties
    public init(
        id: String, itemID: String?, formatVersion: Int?, fields: [String: ItemValue]?,
        properties: [String]? = nil
    ) throws {
        try Identifier.validate(id)
        if let itemID { try Identifier.validate(itemID) }
        guard fields?["revisionID"]?.string == nil || fields?["revisionID"]?.string == id,
            itemID == nil || fields?["itemID"]?.string == nil || fields?["itemID"]?.string == itemID
        else { throw TractandaError("invalidResponse", "Revision wire identities disagree.") }
        self.id = id
        self.itemID = itemID
        self.formatVersion = formatVersion
        self.fields = fields
        self.properties = try JMAPReadProperties(properties, record: .revision)
    }
    public init(_ revision: Revision, properties: [String]? = nil) throws {
        try self.init(
            id: revision.revisionID, itemID: revision.itemID, formatVersion: revision.formatVersion,
            fields: revision.fields, properties: properties)
    }
    public func canonicalRevision() throws -> Revision {
        guard let itemID, let formatVersion, let fields else {
            throw TractandaError("incompleteProjection", "Revision projection is incomplete.")
        }
        let revision = try Revision(fields: fields, formatVersion: formatVersion)
        guard revision.itemID == itemID, revision.revisionID == id else {
            throw TractandaError("invalidResponse", "Revision wire identities disagree.")
        }
        return revision
    }
    private enum CodingKeys: String, CodingKey {
        case id, formatVersion, fields
        case itemID = "itemId"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id), itemID: c.decodeIfPresent(String.self, forKey: .itemID),
            formatVersion: c.decodeIfPresent(Int.self, forKey: .formatVersion),
            fields: c.decodeIfPresent([String: JMAPItemValue].self, forKey: .fields)?.mapValues(\.value),
            properties: c.allKeys.map(\.stringValue))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if properties.includes("itemId") { try c.encode(itemID, forKey: .itemID) }
        if properties.includes("formatVersion") { try c.encode(formatVersion, forKey: .formatVersion) }
        if properties.includes("fields") {
            try c.encode(fields?.mapValues(JMAPItemValue.init), forKey: .fields)
        }
    }
}

/// Standard get normalization. The enforced maximum is supplied by the server's shared limits.
public enum JMAPGetIDs {
    /// JMAP Id syntax is broader than this server's UUID issuance policy. Never case-fold IDs.
    public static func validate(_ id: String) throws {
        guard (1...255).contains(id.utf8.count),
            id.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                    || $0 == 95
            })
        else { throw TractandaError("invalidArguments", "Expected a JMAP Id of 1–255 URL-safe ASCII bytes.") }
    }
    public static func normalize(_ ids: [String]?, maximum: Int) throws -> [String] {
        guard let ids else {
            throw TractandaError(
                "invalidArguments", "All-record get is unsupported; query IDs and fetch bounded batches.")
        }
        var seen: Set<String> = []
        var result: [String] = []
        for id in ids {
            try validate(id)
            if seen.insert(id).inserted { result.append(id) }
        }
        guard maximum >= 0, result.count <= maximum else {
            throw TractandaError("requestTooLarge", "The requested IDs exceed maxObjectsInGet.")
        }
        return result
    }
}

/// RFC 8620 Comparator, plus the explicit Tractanda category-membership axis.
/// categoryRootID is meaningful only with property=categoryMembership.
public struct JMAPReadComparator: Codable, Equatable, Sendable {
    public let property: String
    public let isAscending: Bool
    public let collation: String?
    public let categoryRootID: String?
    public init(
        property: String, isAscending: Bool = true, collation: String? = nil,
        categoryRootID: String? = nil
    ) throws {
        guard !property.isEmpty, !property.contains("\0") else {
            throw TractandaError("invalidArguments", "Comparator property must be nonempty text.")
        }
        guard (property == "categoryMembership") == (categoryRootID != nil) else {
            throw TractandaError(
                "invalidArguments", "categoryMembership requires exactly one categoryRootID.")
        }
        if let categoryRootID { try Identifier.validate(categoryRootID) }
        self.property = property
        self.isAscending = isAscending
        self.collation = collation
        self.categoryRootID = categoryRootID
    }
    public init(_ sort: ItemSort) throws {
        try self.init(
            property: sort.property ?? "categoryMembership", isAscending: sort.isAscending,
            categoryRootID: sort.categoryRootID)
    }
    public func itemSort(supportedCollations: Set<String>) throws -> ItemSort {
        if let collation, !supportedCollations.contains(collation) {
            throw TractandaError("unsupportedSort", "Unsupported comparator collation.")
        }
        if let categoryRootID {
            return try ItemSort(categoryRootID: categoryRootID, isAscending: isAscending)
        }
        return try ItemSort(property: property, isAscending: isAscending)
    }
    private enum CodingKeys: String, CodingKey {
        case property, isAscending, collation
        case categoryRootID = "categoryRootId"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            property: c.decode(String.self, forKey: .property),
            isAscending: c.contains(.isAscending) ? c.decode(Bool.self, forKey: .isAscending) : true,
            collation: c.contains(.collation) ? c.decode(String.self, forKey: .collation) : nil,
            categoryRootID: c.decodeIfPresent(String.self, forKey: .categoryRootID))
    }
}
