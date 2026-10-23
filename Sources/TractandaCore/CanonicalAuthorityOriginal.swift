import Foundation

/// Exact raw authority dispatch. Physical atomic records are retained bytes, never control cuts.
/// Recognizing the atomic MIME type does not advertise or activate its canonical capability.
struct CanonicalAuthorityOriginal {
    enum Payload: Equatable {
        case legacy(AuthorityRecordCodec.Verified)
        case atomic(AtomicAuthorityFormat.Record)
    }
    let payload: Payload
    let bytes: Data
    let sha256: String
    init(_ bytes: Data) throws {
        let atomicHeader = Data(
            "MIME-Version: 1.0\r\nContent-Type: application/vnd.tractanda.atomic-authority+json; charset=utf-8\r\n"
                .utf8)
        if bytes.starts(with: atomicHeader) {
            payload = .atomic(try AtomicAuthorityFormat.Codec.decode(bytes))
        } else {
            payload = .legacy(try AuthorityRecordCodec.decode(bytes))
        }
        self.bytes = bytes
        sha256 = AuthorityRecordCodec.sha256(bytes)
    }
    var recordID: String {
        switch payload {
        case .legacy(let v): v.record.recordID
        case .atomic(let r): r.recordID
        }
    }
    var storeID: String {
        switch payload {
        case .legacy(let v): v.record.storeID
        case .atomic(let r): r.storeID
        }
    }
    var origin: String {
        switch payload {
        case .legacy(let v): v.record.originReplicaID
        case .atomic(let r): r.originReplicaID
        }
    }
    var kind: String {
        switch payload {
        case .legacy(let v): v.record.kind.rawValue
        case .atomic(let r): r.kind.rawValue
        }
    }
    var legacy: AuthorityRecordCodec.Verified? {
        if case .legacy(let value) = payload { return value }
        return nil
    }
    /// Only immediate physical children. Decoded logical parents/support dependencies are streamed
    /// after whole-closure validation; a part's controlID is not a causal dependency back to root.
    func physicalChildren() throws -> [AtomicAuthorityFormat.Reference] {
        guard case .atomic(let r) = payload else { return [] }
        switch r.kind {
        case .atomicControl:
            return try [AtomicAuthorityFormat.Section.parents, .effects].compactMap {
                try AtomicAuthorityFormat.Stream(value: r.payload[$0.rawValue]!, section: $0).root
            }
        case .atomicControlIndex:
            return try AuthorityRecord.list(r.payload["children"]).map(
                AtomicAuthorityFormat.Reference.init(value:))
        case .atomicControlPart: return []
        }
    }
}
