import Foundation

/// Inert format primitives. No publication, capability advertisement or accepted-control dispatch uses these yet.
enum AtomicAuthorityFormat {
    static let profile = "tractanda.authority-atomic.v1"
    static let maximumEnvelopeBytes = 128 * 1024
    static let maximumChunkBytes = 64 * 1024
    static let fanout: Int64 = 64
    static let maximumLevel: Int64 = 8

    enum Kind: String, Sendable { case atomicControl, atomicControlIndex, atomicControlPart }
    enum Section: String, Sendable { case parents, effects }

    static func invalid(_ message: String) -> TractandaError {
        .init("invalidAtomicAuthority", message)
    }
    static func number(_ value: ItemValue?, minimum: Int64 = 0) throws -> Int64 {
        guard let n = value?.integerValue, n >= minimum else { throw invalid("Invalid atomic count/range.") }
        return n
    }
    static func bindings(_ value: ItemValue?) throws -> [AuthorityBinding] {
        let refs = try AuthorityRecord.list(value).map(AuthorityBinding.init(value:))
        let ids = refs.map(\.recordID)
        guard ids == Array(Set(ids)).sorted() else { throw invalid("Bindings must be sorted and unique.") }
        return refs
    }
    static func sum(_ a: Int64, _ b: Int64) throws -> Int64 {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw invalid("Atomic range overflow.") }
        return result.partialValue
    }
    static func capacity(level: Int64) throws -> Int64 {
        guard (0...maximumLevel).contains(level) else { throw invalid("Invalid atomic tree level.") }
        var result: Int64 = 1
        for _ in 0..<level {
            let next = result.multipliedReportingOverflow(by: fanout)
            guard !next.overflow else { throw invalid("Atomic tree capacity overflow.") }
            result = next.partialValue
        }
        return result
    }
    static func level(leaves: Int64) throws -> Int64 {
        guard leaves > 0 else { throw invalid("A nonempty tree requires leaves.") }
        for level in 0...maximumLevel where try leaves <= capacity(level: level) { return level }
        throw invalid("Atomic tree depth exhausted.")
    }

    struct Reference: Equatable, Sendable {
        let binding: AuthorityBinding
        let encodedBytes: Int64
        let level: Int64
        let firstLeaf: Int64
        let leafCount: Int64
        let byteOffset: Int64
        let byteCount: Int64
        init(value: ItemValue) throws {
            let p = try AuthorityRecord.object(
                value,
                keys: [
                    "binding", "encodedBytes", "level", "firstLeaf", "leafCount", "byteOffset", "byteCount",
                ])
            binding = try AuthorityBinding(value: p["binding"]!)
            encodedBytes = try number(p["encodedBytes"], minimum: 1)
            level = try number(p["level"])
            firstLeaf = try number(p["firstLeaf"])
            leafCount = try number(p["leafCount"], minimum: 1)
            byteOffset = try number(p["byteOffset"])
            byteCount = try number(p["byteCount"], minimum: 1)
            guard encodedBytes <= maximumEnvelopeBytes, leafCount <= (try capacity(level: level)),
                level != 0 || (leafCount == 1 && byteCount <= maximumChunkBytes)
            else { throw invalid("Invalid bounded atomic reference.") }
            _ = try sum(firstLeaf, leafCount)
            _ = try sum(byteOffset, byteCount)
        }
        var itemValue: ItemValue {
            .object([
                "binding": binding.itemValue, "encodedBytes": .integer(encodedBytes),
                "level": .integer(level), "firstLeaf": .integer(firstLeaf), "leafCount": .integer(leafCount),
                "byteOffset": .integer(byteOffset), "byteCount": .integer(byteCount),
            ])
        }
    }

    struct Stream: Equatable, Sendable {
        let root: Reference?
        let byteCount: Int64
        let entryCount: Int64
        let targetCount: Int64
        let leafCount: Int64
        init(value: ItemValue, section: Section) throws {
            let p = try AuthorityRecord.object(
                value, keys: ["root", "byteCount", "entryCount", "targetCount", "leafCount"])
            let roots = try AuthorityRecord.list(p["root"])
            guard roots.count <= 1 else { throw invalid("One stream root is required.") }
            root = try roots.first.map(Reference.init(value:))
            byteCount = try number(p["byteCount"])
            entryCount = try number(p["entryCount"])
            targetCount = try number(p["targetCount"])
            leafCount = try number(p["leafCount"])
            if let root {
                guard byteCount > 0, entryCount > 0, entryCount <= byteCount / 9,
                    leafCount > 0, leafCount <= byteCount,
                    root.firstLeaf == 0, root.leafCount == leafCount,
                    root.byteOffset == 0, root.byteCount == byteCount,
                    root.level == (try level(leaves: leafCount)),
                    section == .parents ? targetCount == 0 : (1...entryCount).contains(targetCount)
                else { throw invalid("Atomic stream summary differs from its root.") }
            } else {
                guard byteCount == 0, entryCount == 0, targetCount == 0, leafCount == 0 else {
                    throw invalid("Only the exact zero stream may omit its root.")
                }
            }
        }
        var itemValue: ItemValue {
            .object([
                "root": .list(root.map { [$0.itemValue] } ?? []), "byteCount": .integer(byteCount),
                "entryCount": .integer(entryCount), "targetCount": .integer(targetCount),
                "leafCount": .integer(leafCount),
            ])
        }
    }

    /// Strict typed envelope only. A successfully decoded record grants no authority or completeness.
    struct Record: Equatable, Sendable {
        let itemValue: ItemValue
        let kind: Kind
        let recordID: String
        let controlID: String
        let storeID: String
        let originReplicaID: String
        let payload: [String: ItemValue]
        init(value: ItemValue) throws {
            let p = try AuthorityRecord.object(
                value,
                keys: [
                    "profile", "kind", "recordID", "controlID", "storeID", "originReplicaID",
                    "actorPrincipal", "createdAt", "payload",
                ])
            guard p["profile"]?.string == profile,
                let kind = Kind(rawValue: try AuthorityRecord.text(p["kind"])),
                let payload = p["payload"]?.map
            else { throw invalid("Unknown atomic authority profile/kind.") }
            self.kind = kind
            self.payload = payload
            itemValue = value
            recordID = try AuthorityRecord.persistentID(p["recordID"])
            controlID = try AuthorityRecord.persistentID(p["controlID"])
            storeID = try AuthorityRecord.text(p["storeID"])
            try Identifier.validate(storeID)
            originReplicaID = try AuthorityRecord.persistentID(p["originReplicaID"])
            _ = try AuthorityRecord.text(p["actorPrincipal"])
            guard case .date(let date)? = p["createdAt"], date.utf8.count <= 36,
                Timestamp.parse(date) != nil
            else { throw invalid("Invalid atomic creation date.") }
            _ = try RevisionTimestamp(date)
            guard (kind == .atomicControl) == (recordID == controlID) else {
                throw invalid("Physical part and logical root identities differ.")
            }
            switch kind {
            case .atomicControl: try validateRoot()
            case .atomicControlIndex: try validateIndex()
            case .atomicControlPart: try validatePart()
            }
        }
        private func exact(_ keys: Set<String>) throws {
            guard Set(payload.keys) == keys else { throw invalid("Unknown/missing atomic payload fields.") }
        }
        var section: Section? { payload["section"]?.string.flatMap(Section.init(rawValue:)) }
        private func requireSection() throws {
            guard section != nil else { throw invalid("Invalid atomic stream section.") }
        }
        private func validateRoot() throws {
            try exact(["previous", "bootstrap", "parents", "effects", "partCount", "partBytes"])
            let previous = try bindings(payload["previous"])
            let bootstrap = try bindings(payload["bootstrap"])
            guard previous.count <= 1, bootstrap.count <= 1,
                !(previous + bootstrap).contains(where: { $0.recordID == recordID })
            else { throw invalid("Invalid original PRE/bootstrap binding.") }
            let parents = try Stream(value: payload["parents"]!, section: .parents)
            let effects = try Stream(value: payload["effects"]!, section: .effects)
            let roots = [parents.root, effects.root].compactMap { $0 }
            let ids = roots.map(\.binding.recordID)
            guard Set(ids).count == ids.count, !ids.contains(recordID),
                previous.isEmpty || parents.entryCount > 0
            else { throw invalid("Atomic root reuses a part or omits its previous context.") }
            let count = try number(payload["partCount"])
            let bytes = try number(payload["partBytes"])
            let minimumCount = try sum(parents.leafCount, effects.leafCount)
            let minimumBytes = try roots.reduce(Int64(0)) { try sum($0, $1.encodedBytes) }
            guard
                roots.isEmpty ? (count == 0 && bytes == 0) : (count >= minimumCount && bytes >= minimumBytes)
            else { throw invalid("Impossible atomic closure totals.") }
            // Exact closure/counts, current rights and previous-head CAS require the future validator.
        }
        private func validatePart() throws {
            try exact(["section", "ordinal", "byteOffset", "bytes"])
            try requireSection()
            _ = try number(payload["ordinal"])
            let offset = try number(payload["byteOffset"])
            guard case .bytes(let bytes)? = payload["bytes"], !bytes.isEmpty,
                bytes.count <= maximumChunkBytes
            else { throw invalid("Invalid bounded atomic chunk.") }
            _ = try sum(offset, Int64(bytes.count))
        }
        private func validateIndex() throws {
            try exact(["section", "level", "totalLeaves", "children"])
            try requireSection()
            let level = try number(payload["level"], minimum: 1)
            let total = try number(payload["totalLeaves"], minimum: 1)
            guard level <= maximumLevel else { throw invalid("Atomic tree is too deep.") }
            let children = try AuthorityRecord.list(payload["children"]).map(Reference.init(value:))
            guard !children.isEmpty, children.count <= fanout else { throw invalid("Invalid atomic fanout.") }
            let first = children[0]
            let nodeCapacity = try capacity(level: level)
            let childCapacity = try capacity(level: level - 1)
            guard first.firstLeaf < total, first.firstLeaf % nodeCapacity == 0 else {
                throw invalid("Atomic index is not at its canonical tree position.")
            }
            let expectedLeaves = min(nodeCapacity, total - first.firstLeaf)
            var leaf = first.firstLeaf
            var byte = first.byteOffset
            var ids = Set<String>()
            for child in children {
                guard child.level == level - 1, child.firstLeaf == leaf, child.byteOffset == byte,
                    child.leafCount == min(childCapacity, total - leaf),
                    child.binding.recordID != recordID, child.binding.recordID != controlID,
                    ids.insert(child.binding.recordID).inserted
                else { throw invalid("Atomic child ranges/order/identity differ.") }
                leaf = try sum(leaf, child.leafCount)
                byte = try sum(byte, child.byteCount)
            }
            guard leaf == (try sum(first.firstLeaf, expectedLeaves)), byte > first.byteOffset,
                children.count != 1 || first.firstLeaf > 0
            else { throw invalid("Invalid atomic tail or redundant unary root.") }
            // A one-child final tail at a nonzero leaf ordinal preserves uniform child levels.
        }
        func reference() throws -> Reference {
            guard kind != .atomicControl else { throw invalid("Logical roots are not physical parts.") }
            let data = try Codec.encode(self)
            let level: Int64
            let first: Int64
            let count: Int64
            let offset: Int64
            let bytes: Int64
            if kind == .atomicControlPart {
                level = 0
                first = try number(payload["ordinal"])
                count = 1
                offset = try number(payload["byteOffset"])
                guard case .bytes(let chunk)? = payload["bytes"] else {
                    throw invalid("Missing atomic bytes.")
                }
                bytes = Int64(chunk.count)
            } else {
                let children = try AuthorityRecord.list(payload["children"]).map(Reference.init(value:))
                level = try number(payload["level"])
                first = children[0].firstLeaf
                offset = children[0].byteOffset
                count = try children.reduce(0) { try sum($0, $1.leafCount) }
                bytes = try children.reduce(0) { try sum($0, $1.byteCount) }
            }
            return try Reference(
                value: .object([
                    "binding": AuthorityBinding(recordID: recordID, sha256: AuthorityRecordCodec.sha256(data))
                        .itemValue,
                    "encodedBytes": .integer(Int64(data.count)), "level": .integer(level),
                    "firstLeaf": .integer(first), "leafCount": .integer(count),
                    "byteOffset": .integer(offset), "byteCount": .integer(bytes),
                ]))
        }
    }

    static func decodeValue(_ data: Data) throws -> ItemValue {
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in data {
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
                guard depth <= 24 else { throw invalid("Atomic metadata is too deep.") }
            } else if byte == 125 || byte == 93 {
                depth -= 1
            }
        }
        guard depth == 0, !quoted else { throw invalid("Malformed atomic JSON.") }
        return try JSON.decode(ItemValue.self, data)
    }

    enum Codec {
        static func encode(_ record: Record) throws -> Data {
            _ = try Record(value: record.itemValue)
            let headers = [
                "MIME-Version: 1.0",
                "Content-Type: application/vnd.tractanda.atomic-authority+json; charset=utf-8",
                "X-Tractanda-Authority-Profile: \(profile)", "X-Authority-ID: \(record.recordID)",
                "X-Store-ID: \(record.storeID)",
            ].joined(separator: "\r\n")
            var data = Data((headers + "\r\n\r\n").utf8)
            data.append(try JSON.encode(record.itemValue))
            data.append(10)
            guard data.count <= maximumEnvelopeBytes else {
                throw TractandaError("resourceLimit", "Atomic physical envelope exceeds its byte window.")
            }
            return data
        }
        static func decode(_ data: Data) throws -> Record {
            try Task.checkCancellation()
            guard data.count <= maximumEnvelopeBytes,
                let split = data.range(of: Data("\r\n\r\n".utf8)), split.lowerBound <= 4096
            else { throw invalid("Malformed/oversized atomic envelope.") }
            let body = Data(data[split.upperBound...])
            let record = try Record(value: decodeValue(body))
            guard try encode(record) == data else { throw invalid("Noncanonical atomic envelope.") }
            return record
        }
    }
}
