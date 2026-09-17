import Foundation

/// Portable table presentation; a column displays one literal key or category membership.
public struct ViewColumn: Equatable, Sendable {
    public let property: String?
    public let categoryRootID: String?
    public let title: String
    public let width: Int
    private let extensions: [String: ItemValue]

    public init(property: String, title: String, width: Int, preserving value: ItemValue? = nil) throws {
        guard !property.isEmpty, property.utf8.count <= 256, !property.contains("\0"),
            !title.isEmpty, title.utf8.count <= 256, !title.contains("\0"), (6...120).contains(width)
        else {
            throw TractandaError("invalidView", "Columns need a property, title and width from 6 to 120.")
        }
        self.property = property
        categoryRootID = nil
        self.title = title
        self.width = width
        extensions = value?.map ?? [:]
    }

    public init(categoryRootID: String, title: String, width: Int, preserving value: ItemValue? = nil) throws
    {
        try Identifier.validate(categoryRootID)
        guard !title.isEmpty, title.utf8.count <= 256, !title.contains("\0"), (6...120).contains(width) else {
            throw TractandaError("invalidView", "Columns need a title and width from 6 to 120.")
        }
        property = nil
        self.categoryRootID = categoryRootID
        self.title = title
        self.width = width
        extensions = value?.map ?? [:]
    }

    public init(_ value: ItemValue) throws {
        guard let map = value.map, let title = map["title"]?.string, case .integer(let width) = map["width"],
            (6...120).contains(width)
        else { throw TractandaError("invalidView", "Invalid table column.") }
        switch (map["property"], map["categoryRootID"]) {
        case (.some(.text(let property)), nil):
            try self.init(property: property, title: title, width: Int(width), preserving: value)
        case (nil, .some(.reference(let reference))) where reference.revisionID == nil:
            try self.init(
                categoryRootID: reference.itemID, title: title, width: Int(width), preserving: value)
        default: throw TractandaError("invalidView", "Invalid table column.")
        }
    }

    public var value: ItemValue {
        var map = extensions
        map["property"] = nil
        map["categoryRootID"] = nil
        if let property { map["property"] = .text(property) }
        if let categoryRootID { map["categoryRootID"] = .reference(ItemReference(categoryRootID)) }
        map["title"] = .text(title)
        map["width"] = .integer(Int64(width))
        return .object(map)
    }
}

public struct ViewPresentation: Sendable {
    public static let profile = "tractanda.table.v0"
    public static let defaultColumns: [ViewColumn] = [
        try! ViewColumn(property: "subject", title: "Subject", width: 40),
        try! ViewColumn(property: "classID", title: "Class / type", width: 21),
    ]
    public let columns: [ViewColumn]
    public let sectionIDs: [String]
    public let collapsedSectionIDs: Set<String>

    public init(_ value: ItemValue? = nil) throws {
        guard let value else {
            columns = Self.defaultColumns
            sectionIDs = []
            collapsedSectionIDs = []
            return
        }
        guard let map = value.map, map["profile"]?.string == Self.profile else {
            throw TractandaError("invalidView", "Unsupported table presentation profile.")
        }
        if let value = map["columns"] {
            guard let list = value.array, (1...8).contains(list.count) else {
                throw TractandaError("invalidView", "A table has 1–8 columns.")
            }
            columns = try list.map(ViewColumn.init)
        } else {
            columns = Self.defaultColumns
        }
        sectionIDs = try Self.references(map["sections"])
        collapsedSectionIDs = Set(try Self.references(map["collapsedSections"]))
        guard collapsedSectionIDs.isSubset(of: Set(sectionIDs)) else {
            throw TractandaError("invalidView", "Only configured sections can be collapsed.")
        }
    }

    private static func references(_ value: ItemValue?) throws -> [String] {
        guard let value else { return [] }
        guard let list = value.array, list.count <= 16 else {
            throw TractandaError("invalidView", "Use at most 16 section references.")
        }
        let ids = try list.map { value in
            guard let reference = value.link, reference.revisionID == nil else {
                throw TractandaError("invalidView", "Sections follow current categories by ItemID.")
            }
            return reference.itemID
        }
        guard Set(ids).count == ids.count else {
            throw TractandaError("invalidView", "Section references must be distinct.")
        }
        return ids
    }
}
