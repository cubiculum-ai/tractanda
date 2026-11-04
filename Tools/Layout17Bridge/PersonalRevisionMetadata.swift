import Foundation
import TractandaClient
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Tools-only projection of the existing personal peer revision descriptor.
/// It deliberately does not decode or rewrite original/document payload descriptors.
struct PersonalRevisionDescriptor: Codable, Equatable {
    let kind: String
    let id: String
    let byteCount: Int64
    let sha256: String
    let itemID: String
    let parentRevisionIDs: [String]

    func validate() throws {
        guard kind == "revision", Self.validID(id), Self.validID(itemID),
            byteCount > 0, byteCount <= Int64(LegacyRecordCodec.maximumRecordBytes),
            Self.validDigest(sha256), parentRevisionIDs.count <= 1024,
            parentRevisionIDs == Array(Set(parentRevisionIDs)).sorted(),
            parentRevisionIDs.allSatisfy(Self.validID)
        else { throw TractandaError("invalidPersonalObject", "Invalid retained revision descriptor.") }
    }

    var key: String {
        get throws {
            try validate()
            return SHA256.hash(data: try JSON.encode(self)).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func decode(_ object: Any) throws -> Self {
        guard let value = object as? [String: Any],
            Set(value.keys) == ["kind", "id", "byteCount", "sha256", "itemID", "parentRevisionIDs"]
        else { throw TractandaError("invalidPersonalObject", "Unknown retained revision descriptor fields.") }
        let result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        try result.validate()
        return result
    }

    static func validID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { return false }
        var bytes = uuid.uuid
        return withUnsafeBytes(of: &bytes) { $0[6] >> 4 == 1 && $0[8] & 0xc0 == 0x80 }
    }

    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

struct PersonalRevisionStage: Codable, Equatable {
    let descriptor: PersonalRevisionDescriptor
    let stageID: String
}

struct PersonalRevisionReview: Codable, Equatable {
    let reviewID: String
    let descriptor: PersonalRevisionDescriptor
    let sourceReplicaID: String
    let currentFrontier: [String]
    let baseRevisionIDs: [String]
    let reason: String
    var disposition: String

    func replacingDescriptor(_ value: PersonalRevisionDescriptor) -> Self {
        .init(reviewID: reviewID, descriptor: value, sourceReplicaID: sourceReplicaID,
              currentFrontier: currentFrontier, baseRevisionIDs: baseRevisionIDs,
              reason: reason, disposition: disposition)
    }
}

/// One bounded stage/review operation in the external resumable journal.
struct PersonalStageTransition: Codable {
    let stageID: String
    let oldDescriptor: PersonalRevisionDescriptor
    let newDescriptor: PersonalRevisionDescriptor
    let oldBindingSHA256: String
    let newBinding: Data
    let oldReviewSHA256: String?
    let newReview: Data?
}

struct PersonalReviewTransition: Codable {
    let oldDescriptor: PersonalRevisionDescriptor
    let newDescriptor: PersonalRevisionDescriptor
    let oldReviewSHA256: String
    let newReview: Data
}
