import Crypto
import Foundation
import TractandaClient

public typealias AuthorityRecord = TractandaClient.AuthorityRecord

/// Strict, bounded canonical authority envelopes; no filesystem or authentication side effects.
enum AuthorityRecordCodec {
    struct Verified: Equatable, Sendable {
        let record: AuthorityRecord
        let originalBytes: Data
        let sha256: String
        fileprivate init(record: AuthorityRecord, bytes: Data) {
            self.record = record
            originalBytes = bytes
            sha256 = AuthorityRecordCodec.sha256(bytes)
        }
    }
    static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func encode(_ record: AuthorityRecord) throws -> Data {
        _ = try AuthorityRecord(value: record.itemValue)
        _ = try RevisionTimestamp(record.createdAt)
        let data = try envelope(record.itemValue, recordID: record.recordID, storeID: record.storeID)
        guard data.count <= AuthorityRecord.maximumBytes else {
            throw TractandaError("resourceLimit", "Complete authority envelope exceeds its byte window.")
        }
        return data
    }
    /// Planning only: the same complete envelope encoding as publication, without admission.
    static func encodedSize(_ value: ItemValue, recordID: String, storeID: String) throws -> Int {
        try envelope(value, recordID: recordID, storeID: storeID).count
    }
    private static func envelope(_ value: ItemValue, recordID: String, storeID: String) throws -> Data {
        let header = [
            "MIME-Version: 1.0",
            "Content-Type: application/vnd.tractanda.authority+json; charset=utf-8",
            "X-Tractanda-Authority-Profile: \(AuthorityRecord.profile)",
            "X-Authority-ID: \(recordID)", "X-Store-ID: \(storeID)",
        ].joined(separator: "\r\n")
        var data = Data((header + "\r\n\r\n").utf8)
        data.append(try JSON.encode(value))
        data.append(10)
        return data
    }
    static func decode(_ bytes: Data) throws -> Verified {
        guard bytes.count <= AuthorityRecord.maximumBytes else {
            throw TractandaError("resourceLimit", "Authority envelope exceeds its byte window.")
        }
        guard
            let split = bytes.range(of: Data("\r\n\r\n".utf8)), split.lowerBound <= 4096
        else { throw TractandaError("invalidAuthority", "Malformed or oversized authority envelope.") }
        let body = Data(bytes[split.upperBound...])
        // Reject deep input before the recursive ItemValue decoder. Canonical roundtrip
        // below also rejects duplicate/unknown JSON fields and ambiguous encodings.
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in body {
            if quoted {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    quoted = false
                }
            } else if byte == 34 {
                quoted = true
            } else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 24 else {
                    throw TractandaError("invalidAuthority", "Authority JSON is too deep.")
                }
            } else if byte == 125 || byte == 93 {
                depth -= 1
            }
        }
        guard depth == 0, !quoted else {
            throw TractandaError("invalidAuthority", "Malformed authority JSON.")
        }
        let record = try AuthorityRecord(value: JSON.decode(ItemValue.self, body))
        guard try encode(record) == bytes else {
            throw TractandaError("invalidAuthority", "Noncanonical or mismatched authority envelope.")
        }
        return Verified(record: record, bytes: bytes)
    }
}

struct AuthorityRevision: Equatable, Sendable {
    let revision: Revision
    let originalBytes: Data
    let sha256: String
    init(originalBytes: Data) throws {
        let revision = try RecordCodec.decode(originalBytes)
        try ItemSemantics.validate(revision)
        guard AuthorityRecord.reservedItemFields.isDisjoint(with: revision.fields.keys) else {
            throw TractandaError("invalidAuthority", "Authority controls must be separate canonical records.")
        }
        _ = try AuthorityRecord.persistentID(.text(revision.itemID))
        _ = try AuthorityRecord.persistentID(.text(revision.revisionID))
        self.revision = revision
        self.originalBytes = originalBytes
        sha256 = AuthorityRecordCodec.sha256(originalBytes)
    }
    var parents: [String] { (try? revision.provenance?.parents) ?? revision.supersedes.map { [$0] } ?? [] }
}

/// Capability is injected by a trusted boundary; origin UUID alone never constructs one.
struct TrustedAuthorityPeer: Sendable {
    let peerName: String
    let storeID: String
    let origins: Set<String>
    init(peerName: String, storeID: String, origins: Set<String>) throws {
        _ = try AuthorityRecord.text(.text(peerName))
        try Identifier.validate(storeID)
        guard !origins.isEmpty, origins.count <= AuthorityRecord.maximumEntries else {
            throw TractandaError("invalidAuthority", "Invalid configured origin set.")
        }
        for origin in origins { _ = try AuthorityRecord.persistentID(.text(origin)) }
        self.peerName = peerName
        self.storeID = storeID
        self.origins = origins
    }
    func permits(_ record: AuthorityRecord) -> Bool {
        record.storeID == storeID && origins.contains(record.originReplicaID)
    }
}
