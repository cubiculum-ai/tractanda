import Foundation

/// Inert entry framing, independent of physical leaf boundaries. It makes no authorization decision.
enum AtomicAuthorityEntryStream {
    typealias Section = AtomicAuthorityFormat.Section

    /// Derived from the existing model: UUIDv1=36, SHA256=64, authority text<=256 UTF8 bytes,
    /// policies/causes<=maximumEntries and selected evidence<=1. Backslashes maximize JSON escaping.
    /// No complete-effect bound is inherited from the physical 128KiB envelope window.
    private static let parentBound = Result { try deriveMaximumEntryBytes(.parents) }
    private static let effectBound = Result { try deriveMaximumEntryBytes(.effects) }
    static func maximumEntryBytes(_ section: Section) throws -> Int {
        try (section == .parents ? parentBound : effectBound).get()
    }
    private static func deriveMaximumEntryBytes(_ section: Section) throws -> Int {
        func id(_ n: Int) -> String { String(format: "%08x-0000-1000-8000-000000000001", n) }
        let binding = try AuthorityBinding(recordID: id(1), sha256: String(repeating: "f", count: 64))
        if section == .parents { return try JSON.encode(binding.itemValue).count }
        let maximum = AuthorityRecord.maximumEntries
        let delta = AuthorityStore.DispositionDelta(
            target: try .init(itemID: id(2), revisionID: id(3), sha256: String(repeating: "f", count: 64)),
            eligible: false, actor: String(repeating: "\\", count: 256),
            policyIDs: (0..<maximum).map { id(1000 + $0) },
            causes: try (0..<maximum).map {
                try AuthorityBinding(recordID: id(2000 + $0), sha256: String(repeating: "f", count: 64))
            }, evidence: binding)
        _ = try AuthorityStore.DispositionDelta(value: delta.itemValue)
        return try JSON.encode(delta.itemValue).count
    }
    static func validate(_ value: ItemValue, section: Section) throws {
        if section == .parents {
            _ = try AuthorityBinding(value: value)
        } else {
            let delta = try AuthorityStore.DispositionDelta(value: value)
            guard delta.itemValue == value else {
                throw AtomicAuthorityFormat.invalid("Atomic fact differs from its complete typed model.")
            }
            _ = try AtomicAuthorityFormat.bindings(value.map?["causes"])
            guard try AtomicAuthorityFormat.bindings(value.map?["evidence"]).count <= 1 else {
                throw AtomicAuthorityFormat.invalid("At most one selected evidence binding is permitted.")
            }
        }
    }
    static func frame(_ value: ItemValue, section: Section) throws -> Data {
        try validate(value, section: section)
        let data = try JSON.encode(value)
        guard data.count <= (try maximumEntryBytes(section)) else {
            throw AtomicAuthorityFormat.invalid("Entry exceeds its existing semantic model bound.")
        }
        var length = UInt64(data.count).bigEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(data)
        return result
    }

    struct Decoder {
        let section: Section
        let expectedBytes: UInt64
        let expectedEntries: UInt64
        let expectedTargets: UInt64
        private let maximumEntry: Int
        private(set) var receivedBytes: UInt64 = 0
        private(set) var decodedEntries: UInt64 = 0
        private(set) var decodedTargets: UInt64 = 0
        private(set) var failed = false
        private var prefix: [UInt8] = []
        private var entry: [UInt8] = []
        private var declared: Int?
        private var lastKey: String?
        private var lastTarget: String?

        init(section: Section, expectedBytes: UInt64, expectedEntries: UInt64, expectedTargets: UInt64) throws
        {
            guard expectedEntries <= expectedBytes / 9,
                expectedBytes == 0 ? expectedEntries == 0 : expectedEntries > 0,
                section == .parents
                    ? expectedTargets == 0
                    : (expectedEntries == 0
                        ? expectedTargets == 0 : (1...expectedEntries).contains(expectedTargets))
            else { throw AtomicAuthorityFormat.invalid("Invalid declared atomic entry counts.") }
            self.section = section
            self.expectedBytes = expectedBytes
            self.expectedEntries = expectedEntries
            self.expectedTargets = expectedTargets
            maximumEntry = try maximumEntryBytes(section)
        }
        /// Caller owns closure validation and current rights. A callback cannot commit partial authority.
        mutating func append(_ chunk: Data, onEntry: (ItemValue) throws -> Void) throws {
            var completed = false
            defer { if !completed { failed = true } }
            try Task.checkCancellation()
            guard !failed, chunk.count <= AtomicAuthorityFormat.maximumChunkBytes,
                UInt64(chunk.count) <= expectedBytes - receivedBytes
            else { throw AtomicAuthorityFormat.invalid("Atomic stream chunk/count differs.") }
            receivedBytes += UInt64(chunk.count)
            let bytes = Array(chunk)
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                if declared == nil {
                    let amount = min(8 - prefix.count, bytes.count - offset)
                    prefix.append(contentsOf: bytes[offset..<(offset + amount)])
                    offset += amount
                    if prefix.count < 8 { continue }
                    let count = prefix.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    // Guard the advertised size before converting, reserving or allocating its buffer.
                    guard count > 0, count <= UInt64(maximumEntry),
                        count <= expectedBytes - receivedBytes + UInt64(bytes.count - offset),
                        decodedEntries < expectedEntries
                    else {
                        throw AtomicAuthorityFormat.invalid("Atomic entry length exceeds its semantic bound.")
                    }
                    declared = Int(count)
                    prefix.removeAll(keepingCapacity: true)
                    entry.reserveCapacity(Int(count))
                }
                let amount = min(declared! - entry.count, bytes.count - offset)
                entry.append(contentsOf: bytes[offset..<(offset + amount)])
                offset += amount
                if entry.count == declared {
                    let data = Data(entry)
                    let value = try AtomicAuthorityFormat.decodeValue(data)
                    try validate(value, section: section)
                    guard try JSON.encode(value) == data else {
                        throw AtomicAuthorityFormat.invalid("Noncanonical atomic stream entry.")
                    }
                    let target: String
                    let key: String
                    if section == .parents {
                        target = try AuthorityBinding(value: value).recordID
                        key = target
                    } else {
                        target = try AuthorityStore.DispositionDelta(value: value).target.revisionID
                        key = target + ":" + AuthorityRecordCodec.sha256(data)
                        if target != lastTarget { decodedTargets += 1 }
                    }
                    guard lastKey == nil || lastKey! < key else {
                        throw AtomicAuthorityFormat.invalid("Atomic entries are duplicated or out of order.")
                    }
                    lastKey = key
                    lastTarget = target
                    decodedEntries += 1
                    try onEntry(value)
                    declared = nil
                    entry.removeAll(keepingCapacity: true)
                }
            }
            completed = true
        }
        mutating func finish() throws {
            try Task.checkCancellation()
            guard !failed, declared == nil, prefix.isEmpty, receivedBytes == expectedBytes,
                decodedEntries == expectedEntries, decodedTargets == expectedTargets
            else {
                failed = true
                throw AtomicAuthorityFormat.invalid("Incomplete atomic entry stream/counts.")
            }
        }
    }
}
