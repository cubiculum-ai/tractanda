import Foundation

/// Experimental single-file MIME envelope. Its JSON body is the typed dictionary.
public enum RecordCodec {
    public static func encode(_ revision: Revision) throws -> Data {
        try revision.validate()
        let headers = [
            "MIME-Version: 1.0",
            "Content-Type: application/vnd.tractanda.item+json; charset=utf-8",
            "X-Tractanda-Format-Version: 1",
            "X-IsA: \(revision.classID)",
            "X-Item-ID: \(revision.itemID)",
            "X-Revision-ID: \(revision.revisionID)",
        ]
        var data = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(try JSON.encode(revision))
        data.append(0x0A)
        return data
    }
    public static func decode(_ data: Data) throws -> Revision {
        guard data.count <= 8 * 1024 * 1024,
            let split = data.range(of: Data("\r\n\r\n".utf8)),
            let text = String(data: data[..<split.lowerBound], encoding: .utf8)
        else {
            throw TractandaError("invalidRecord", "Invalid or oversized MIME envelope.")
        }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else {
                throw TractandaError("invalidRecord", "Malformed envelope header.")
            }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else {
                throw TractandaError("invalidRecord", "Duplicate envelope header.")
            }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let revision = try JSON.decode(Revision.self, Data(data[split.upperBound...]))
        guard headers["mime-version"] == "1.0",
            headers["x-item-id"] == revision.itemID,
            headers["x-revision-id"] == revision.revisionID,
            headers["x-isa"] == revision.classID,
            headers["x-tractanda-format-version"] == "1",
            headers["content-type"] == "application/vnd.tractanda.item+json; charset=utf-8"
        else {
            throw TractandaError("invalidRecord", "Envelope and dictionary disagree.")
        }
        return revision
    }
}
