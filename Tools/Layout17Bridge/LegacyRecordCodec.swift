import Foundation
import TractandaClient

/// The finite .17 bridge alone may read the 16.2 MIME/JSON record envelope.
/// Ordinary runtime readers must not depend on this decoder.
enum LegacyRecordCodec {
    static let maximumRecordBytes = 8 * 1024 * 1024

    static func decode(_ data: Data) throws -> Revision {
        guard data.count <= maximumRecordBytes,
            let split = data.range(of: Data("\r\n\r\n".utf8)),
            let text = String(data: data[..<split.lowerBound], encoding: .utf8)
        else { throw TractandaError("invalidRecord", "Invalid or oversized legacy MIME envelope.") }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else {
                throw TractandaError("invalidRecord", "Malformed legacy envelope header.")
            }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else {
                throw TractandaError("invalidRecord", "Duplicate legacy envelope header.")
            }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let revision = try JSON.decode(Revision.self, Data(data[split.upperBound...]))
        guard headers["mime-version"] == "1.0", headers["x-item-id"] == revision.itemID,
            headers["x-revision-id"] == revision.revisionID, headers["x-isa"] == revision.classID,
            headers["x-tractanda-format-version"] == String(revision.formatVersion),
            headers["content-type"] == "application/vnd.tractanda.item+json; charset=utf-8"
        else { throw TractandaError("invalidRecord", "Legacy envelope and dictionary disagree.") }
        return revision
    }

#if LAYOUT17_PRIVATE_FIXTURE
    /// Test-only reverse fixture writer; excluded from the production helper.
    static func encodeFixture(_ revision: Revision) throws -> Data {
        try revision.validate()
        let headers = ["MIME-Version: 1.0", "Content-Type: application/vnd.tractanda.item+json; charset=utf-8",
            "X-Tractanda-Format-Version: \(revision.formatVersion)", "X-IsA: \(revision.classID)",
            "X-Item-ID: \(revision.itemID)", "X-Revision-ID: \(revision.revisionID)"]
        let bytes = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + (try JSON.encode(revision)) + Data([10])
        guard bytes.count <= maximumRecordBytes else {
            throw TractandaError("resourceLimit", "Legacy fixture record exceeds its byte window.")
        }
        return bytes
    }
#endif
}
