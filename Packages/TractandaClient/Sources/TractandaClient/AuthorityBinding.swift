import Foundation

/// Exact immutable control reference; its UUID alone grants no trust or eligibility.
public struct AuthorityBinding: Codable, Equatable, Hashable, Sendable {
    public let recordID: String
    public let sha256: String
    public init(recordID: String, sha256: String) throws {
        self.recordID = try AuthorityRecord.persistentID(.text(recordID))
        self.sha256 = try AuthorityRecord.digest(.text(sha256))
    }
    public init(value: ItemValue) throws {
        let object = try AuthorityRecord.object(value, keys: ["recordID", "sha256"])
        try self.init(
            recordID: AuthorityRecord.text(object["recordID"]),
            sha256: AuthorityRecord.digest(object["sha256"]))
    }
    public var itemValue: ItemValue { .object(["recordID": .text(recordID), "sha256": .text(sha256)]) }
}
