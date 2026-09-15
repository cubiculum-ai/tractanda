import Foundation

public struct Revision: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let fields: [String: ItemValue]
    public var itemID: String { fields["itemID"]!.string! }
    public var revisionID: String { fields["revisionID"]!.string! }
    public var classID: String { fields["classID"]!.string! }
    public var supersedes: String? { fields["supersedes"]?.string }
    public var isDeleted: Bool { fields["isDeleted"]?.booleanValue == true }
    public var modifiedAt: String { fields["modifiedAt"]!.dateString! }
    public init(fields: [String: ItemValue], formatVersion: Int = 1) throws {
        self.formatVersion = formatVersion
        self.fields = fields
        try validate()
    }
    public func validate() throws {
        guard formatVersion == 1 else { throw TractandaError("unsupportedFormat", "Unknown record format.") }
        for name in ["itemID", "revisionID", "classID", "actor", "operationID", "requestIdentity"] {
            guard let value = fields[name]?.string, !value.isEmpty else {
                throw TractandaError("invalidRecord", "Missing/invalid \(name).")
            }
        }
        try Identifier.validate(itemID)
        try Identifier.validate(revisionID)
        if let previous = fields["supersedes"] {
            guard let id = previous.string else {
                throw TractandaError("invalidRecord", "Invalid predecessor.")
            }
            try Identifier.validate(id)
        }
        for name in ["createdAt", "modifiedAt"] {
            guard let date = fields[name]?.dateString, Timestamp.parse(date) != nil else {
                throw TractandaError("invalidRecord", "Invalid \(name).")
            }
        }
        guard case .integer(let schema)? = fields["schemaVersion"], schema > 0 else {
            throw TractandaError("invalidRecord", "Invalid schemaVersion.")
        }
        guard classID.utf8.count < 200,
            classID.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
            })
        else {
            throw TractandaError("invalidRecord", "Invalid class identifier.")
        }
        for value in fields.values { try value.validate() }
        for key in ["subject", "body"] where fields[key] != nil {
            guard fields[key]?.string != nil else {
                throw TractandaError("invalidRecord", "\(key) must be text.")
            }
        }
        if let deleted = fields["isDeleted"], deleted.booleanValue == nil {
            throw TractandaError("invalidRecord", "isDeleted must be Boolean.")
        }
    }
    private enum CodingKeys: String, CodingKey { case formatVersion, fields }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            fields: c.decode([String: ItemValue].self, forKey: .fields),
            formatVersion: c.decode(Int.self, forKey: .formatVersion))
    }
}
extension ItemValue {
    public var dateString: String? {
        if case .date(let v) = self { return v }
        return nil
    }
}
