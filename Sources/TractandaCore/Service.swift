import CTractandaPlatform
import Foundation
import TractandaClient

struct PreparedNativeRead: Sendable {
    let query: PreparedReadQuery
    let snapshot: ImmutableReadSnapshot
    let callID: String
}

struct PreparedPooledQuery: Sendable {
    let callID: String
    let argumentsJSON: Data
    let sourceSQL: String
    let bindings: [SQLiteReadValue]
    let authority: PooledReadAuthority
    let orderColumn: String
    let position: Int
    let limit: Int
    let evaluatedAt: Date
    let evaluatedAtString: String
    let timeZone: String
    let queryDigest: String
    let residual: SpotlightQuery?
    let category: PooledCategorySelection?
    let viewID: String?
    let viewRevisionID: String?

    func evaluate(
        in pool: SQLiteReadPool, cancellation: SQLiteReadCancellation = SQLiteReadCancellation(),
        afterLease: (@Sendable () -> Void)? = nil
    ) throws
        -> ItemIndex.Page
    {
        let lease = try pool.lease(principal: authority.principals, cancellation: cancellation)
        defer { lease.finish() }
        afterLease?()
        return try lease.withReadTransaction {
            if residual != nil || category != nil {
                let calendar = try QueryCalendar.make(timeZone: timeZone)
                let evaluator = try category.map {
                    try CategoryEvaluator(definitions: $0.definitions, store: nil, at: evaluatedAt)
                }
                var total = 0
                var ids: [String] = []
                let personalSQL: String
                var personalBindings: [SQLiteReadValue] = []
                if let category, !category.ownerNames.isEmpty {
                    let owners = Array(repeating: "?", count: category.ownerNames.count)
                        .joined(separator: ",")
                    let categories = category.definitions.map(\.itemID).sorted()
                    let categoryIDs = Array(repeating: "?", count: categories.count)
                        .joined(separator: ",")
                    personalSQL =
                        ",CASE WHEN (SELECT COUNT(*) FROM personal_overlay_targets p "
                        + "WHERE p.target_id=items.id AND p.owner_name IN (\(owners)))>1 "
                        + "OR EXISTS (SELECT 1 FROM personal_category_delta d "
                        + "WHERE d.target_id=items.id AND d.owner_name IN (\(owners)) "
                        + "AND d.category_id IN (\(categoryIDs))) THEN 1 ELSE 0 END"
                    personalBindings =
                        category.ownerNames.map(SQLiteReadValue.text)
                        + category.ownerNames.map(SQLiteReadValue.text)
                        + categories.map(SQLiteReadValue.text)
                } else {
                    personalSQL = ",0"
                }
                _ = try lease.stream(
                    "SELECT items.id,items.fields" + personalSQL + sourceSQL
                        + " ORDER BY items.\(orderColumn) DESC, items.id",
                    bindings: personalBindings + bindings, maximumRows: Int.max,
                    maximumRowBytes: 9 * 1024 * 1024,
                    cancellation: cancellation,
                    onRow: { row in
                        guard row.count == 3, case .text(let id) = row[0],
                            case .text(let fieldsJSON) = row[1]
                        else { throw TractandaError("indexError", "Pooled candidate row is invalid.") }
                        guard case .integer(let personal) = row[2], personal == 0 else {
                            throw TractandaError(
                                "unsupportedPersonal", "Personal decisions require exact serial evaluation.")
                        }
                        let fields = try JSON.decode(
                            [String: ItemValue].self, Data(fieldsJSON.utf8))
                        let revision = try Revision(fields: fields)
                        guard revision.itemID == id else {
                            throw TractandaError("indexError", "Pooled candidate identity differs.")
                        }
                        guard residual?.matches(revision, at: evaluatedAt, calendar: calendar) ?? true
                        else { return }
                        if let category, let evaluator {
                            var cache: [String: Membership] = [:]
                            for id in category.path
                            where try !evaluator.membership(
                                revision, categoryID: id, cache: &cache
                            ).isIncluded { return }
                            for id in category.excluded
                            where try evaluator.membership(
                                revision, categoryID: id, cache: &cache
                            ).isIncluded { return }
                        }
                        guard total < Int.max else {
                            throw TractandaError("resourceLimit", "Pooled query count overflowed.")
                        }
                        if total >= position && ids.count < limit { ids.append(id) }
                        total += 1
                    })
                return .init(ids: ids, total: total)
            }
            let counts = try lease.query(
                "SELECT COUNT(*)" + sourceSQL, bindings: bindings,
                limits: .init(maximumRows: 1, maximumBytes: 256), cancellation: cancellation)
            guard counts.count == 1, counts[0].count == 1,
                case .integer(let totalValue) = counts[0][0], totalValue >= 0,
                let total = Int(exactly: totalValue)
            else { throw TractandaError("indexError", "Pooled query count is invalid.") }
            let rows = try lease.query(
                "SELECT items.id" + sourceSQL
                    + " ORDER BY items.\(orderColumn) DESC, items.id LIMIT ? OFFSET ?",
                bindings: bindings + [.integer(Int64(limit)), .integer(Int64(position))],
                limits: .init(maximumRows: limit, maximumBytes: 128 * 1024),
                cancellation: cancellation)
            let ids = try rows.map { row -> String in
                guard row.count == 1, case .text(let id) = row[0] else {
                    throw TractandaError("indexError", "Pooled query returned an invalid item ID.")
                }
                return id
            }
            return .init(ids: ids, total: total)
        }
    }
}

struct PooledCategorySelection: Sendable {
    let definitions: [CategoryDefinition]
    let path: [String]
    let excluded: [String]
    let ownerNames: [String]
}

struct PreparedPooledGet: Sendable {
    let callID: String
    let argumentsJSON: Data
    let rows: [ItemIndex.CatalogueRow]
    let notFound: [String]
    let authority: PooledReadAuthority
    let root: URL
    let ownerUID: UInt32
    let resourceLimited: Bool

    func evaluate(
        in pool: SQLiteReadPool, cancellation: SQLiteReadCancellation = SQLiteReadCancellation(),
        afterLease: (@Sendable () -> Void)? = nil
    ) throws
        -> [PooledCanonicalRecord]
    {
        if resourceLimited { return [] }
        let lease = try pool.lease(principal: authority.principals, cancellation: cancellation)
        afterLease?()
        do {
            try lease.withReadTransaction {
                for row in rows {
                    let digest = row.digest.map { String(format: "%02x", $0) }.joined()
                    let found = try lease.query(
                        "SELECT 1 FROM revision_catalog WHERE revision=? AND item=? AND digest=?",
                        bindings: [.text(row.revisionID), .text(row.itemID), .text(digest)],
                        limits: .init(maximumRows: 1, maximumBytes: 128), cancellation: cancellation)
                    guard found.count == 1 else {
                        throw TractandaError("recoveryError", "A pooled canonical row changed.")
                    }
                }
            }
        } catch {
            lease.finish()
            throw error
        }
        // No SQLite read snapshot is retained during canonical filesystem I/O.
        lease.finish()
        return try rows.map {
            try Task.checkCancellation()
            return try PooledCanonicalRecord.read(row: $0, root: root, ownerUID: ownerUID)
        }
    }
}

struct PooledHistoryResult: Sendable {
    let rows: [ItemIndex.CatalogueRow]
    let records: [PooledCanonicalRecord]
    let total: Int
}

struct PreparedPooledHistory: Sendable {
    let callID: String
    let argumentsJSON: Data
    let itemID: String
    let headRevisionID: String
    let position: Int
    let limit: Int
    let authority: PooledReadAuthority
    let root: URL
    let ownerUID: UInt32
    let maximumSerializedBytes: Int
    let batchLimit: Int

    func evaluate(
        in pool: SQLiteReadPool, cancellation: SQLiteReadCancellation = SQLiteReadCancellation(),
        afterLease: (@Sendable () -> Void)? = nil,
        afterSnapshot: (@Sendable () -> Void)? = nil
    ) throws
        -> PooledHistoryResult
    {
        let lease = try pool.lease(principal: authority.principals, cancellation: cancellation)
        defer { lease.finish() }
        afterLease?()
        let capturedCount = try lease.withReadTransaction { () -> Int in
            let snapshot = try lease.query(
                "SELECT items.revision,(SELECT COUNT(*) FROM revision_catalog WHERE item=?) "
                    + "FROM items WHERE items.id=?",
                bindings: [.text(itemID), .text(itemID)],
                limits: .init(maximumRows: 1, maximumBytes: 512), cancellation: cancellation)
            guard snapshot.count == 1, snapshot[0].count == 2,
                case .text(let currentHead) = snapshot[0][0],
                case .integer(let count) = snapshot[0][1],
                let result = Int(exactly: count), result > 0
            else { throw TractandaError("recoveryError", "Historical admission snapshot is invalid.") }
            guard currentHead == headRevisionID else {
                throw TractandaError("stateChanged", "History head changed before SQL admission.")
            }
            return result
        }
        afterSnapshot?()
        func parent(of revisionID: String?) throws -> String? {
            guard let revisionID else { return nil }
            let rows = try lease.query(
                "SELECT parent FROM revision_catalog WHERE revision=? AND item=?",
                bindings: [.text(revisionID), .text(itemID)],
                limits: .init(maximumRows: 1, maximumBytes: 256), cancellation: cancellation)
            guard rows.count == 1, rows[0].count == 1 else {
                throw TractandaError("recoveryError", "Historical parent is unavailable.")
            }
            switch rows[0][0] {
            case .null: return nil
            case .text(let parent): return parent
            default: throw TractandaError("recoveryError", "Historical parent is invalid.")
            }
        }
        func fullRow(_ revisionID: String) throws -> ItemIndex.CatalogueRow {
            let values = try lease.query(
                "SELECT revision,item,path,parent,actor,operation,size,inode,uid,mode,"
                    + "mtime_seconds,mtime_nanoseconds,digest,created_at "
                    + "FROM revision_catalog WHERE revision=? AND item=?",
                bindings: [.text(revisionID), .text(itemID)],
                limits: .init(maximumRows: 1, maximumBytes: 2 * 1024), cancellation: cancellation)
            guard values.count == 1 else {
                throw TractandaError("recoveryError", "Historical page row is unavailable.")
            }
            return try ItemIndex.CatalogueRow.fromPooledValues(values[0])
        }
        var current: String? = headRevisionID
        var slow: String? = headRevisionID
        var fast: String? = headRevisionID
        var total = 0
        var rows: [ItemIndex.CatalogueRow] = []
        var serializedBytes = 0
        while current != nil {
            try Task.checkCancellation()
            try lease.withReadTransaction {
                for _ in 0..<batchLimit {
                    guard let revisionID = current else { break }
                    let next = try parent(of: revisionID)
                    if total >= position && rows.count < limit {
                        let row = try fullRow(revisionID)
                        guard row.size <= UInt64(maximumSerializedBytes - serializedBytes) else {
                            throw TractandaError(
                                "resourceLimit", "History page exceeds its byte window.")
                        }
                        serializedBytes += Int(row.size)
                        rows.append(row)
                    }
                    guard total < Int.max else {
                        throw TractandaError("resourceLimit", "History count overflowed.")
                    }
                    total += 1
                    current = next
                    slow = try parent(of: slow)
                    fast = try parent(of: try parent(of: fast))
                    if let slow, slow == fast {
                        throw TractandaError("recoveryError", "Historical chain contains a cycle.")
                    }
                }
            }
        }
        guard total == capturedCount else {
            throw TractandaError("recoveryError", "Historical catalogue has disconnected rows.")
        }
        // Release the read lease before filesystem hydration; the owner rechecks the
        // current head/authority and immutable catalogue rows before delivery.
        lease.finish()
        let records = try rows.map {
            try Task.checkCancellation()
            return try PooledCanonicalRecord.read(row: $0, root: root, ownerUID: ownerUID)
        }
        return .init(
            rows: rows, records: records, total: total)
    }
}

extension ItemIndex.CatalogueRow {
    fileprivate static func fromPooledValues(_ values: [SQLiteReadValue]) throws -> Self {
        guard values.count == 14 else {
            throw TractandaError("indexError", "Pooled catalogue row has wrong width.")
        }
        func text(_ index: Int) -> String? {
            if case .text(let value) = values[index] { return value }
            return nil
        }
        func number(_ index: Int) -> Int64? {
            if case .integer(let value) = values[index] { return value }
            return nil
        }
        guard let revision = text(0), let item = text(1), let path = text(2),
            let actor = text(4), let operation = text(5), let digestHex = text(12),
            let createdAt = text(13), digestHex.count == 64,
            let size = number(6), size >= 0, let inode = number(7), inode >= 0,
            let uid = number(8), let owner = UInt32(exactly: uid),
            let modeValue = number(9), let mode = UInt32(exactly: modeValue),
            let seconds = number(10), let nanosecondsValue = number(11),
            let nanoseconds = Int32(exactly: nanosecondsValue)
        else { throw TractandaError("indexError", "Pooled catalogue row is invalid.") }
        let parent: String?
        switch values[3] {
        case .null: parent = nil
        case .text(let value): parent = value
        default: throw TractandaError("indexError", "Pooled catalogue parent is invalid.")
        }
        var digest = Data()
        var cursor = digestHex.startIndex
        for _ in 0..<32 {
            let next = digestHex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(digestHex[cursor..<next], radix: 16) else {
                throw TractandaError("indexError", "Pooled catalogue digest is invalid.")
            }
            digest.append(byte)
            cursor = next
        }
        return .init(
            revisionID: revision, itemID: item, path: path, parentID: parent,
            actor: actor, operationID: operation, size: UInt64(size), inode: UInt64(inode),
            uid: owner, mode: mode, modificationSeconds: seconds,
            modificationNanoseconds: nanoseconds, digest: digest, createdAt: createdAt)
    }
}

/// Local experimental binding with JMAP-shaped method calls. This is not a
/// conforming JMAP server: discovery, HTTP/auth and the complete Core contract are pending.
public final class ItemService {
    public static let capability = TractandaClient.ItemClient.capability
    public let store: ItemStore
    private var learners: [String: CategoryLearning] = [:]
    private let semantic: SemanticService
    public var learning: CategoryLearning {
        let scope = store.accessScope
        if let existing = learners[scope] { return existing }
        if learners.count >= 64 { learners.removeAll() }
        let learner = CategoryLearning(store: store)
        learners[scope] = learner
        return learner
    }
    public init(store: ItemStore) {
        self.store = store
        semantic = SemanticService(store: store)
    }
    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSON.encode(value), options: [.fragmentsAllowed])
    }
    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSON.decode(
            type, JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]))
    }
    private func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else {
            throw TractandaError("invalidArguments", "Missing/invalid \(key).")
        }
        return value
    }
    private func strings(_ args: [String: Any], _ key: String, default value: [String]? = nil) throws
        -> [String]
    {
        guard let result = args[key] as? [String] ?? (args[key] == nil ? value : nil), result.count <= 256
        else {
            throw TractandaError("invalidArguments", "\(key) must be an array of at most 256 strings.")
        }
        return result
    }
    private func check(_ args: [String: Any], allowed: Set<String>) throws {
        guard Set(args.keys).isSubset(of: allowed) else {
            throw TractandaError(
                "invalidArguments",
                "Unknown arguments: \(Set(args.keys).subtracting(allowed).sorted().joined(separator: ", ")).")
        }
    }
    private func makeInitialCursor(
        args: [String: Any], ids: [String], total: Int, position: Int,
        evaluatedAt: Date, evaluatedAtString: String, timeZone: String, digest: String
    ) throws -> Any {
        let allowed = Set(["expression", "sort", "position", "limit", "at", "timeZone"])
        guard Set(args.keys).isSubset(of: allowed), let last = ids.last,
            ids.count > 0, total > position + ids.count
        else { return NSNull() }
        let sort = try args["sort"].map { try decode([ItemSort].self, $0) } ?? []
        let field: String
        if sort.isEmpty {
            field = "modifiedAt"
        } else if sort.count == 1, sort[0].categoryRootID == nil, !sort[0].isAscending,
            let property = sort[0].property,
            ["createdAt", "modifiedAt"].contains(metadataKey(property))
        {
            field = metadataKey(property)
        } else {
            return NSNull()
        }
        if let expression = args["expression"] as? String {
            guard let predicate = try? SpotlightQuery(expression),
                predicate.indexExactClassEquals != nil || !predicate.boundedIndexCandidatePlan.isAll
            else { return NSNull() }
        }
        let storeID = try store.cursorStoreIdentity
        let state = store.state
        let totalReference = LiveQueryCursor.retainTotal(
            total: total, storeID: storeID, actorUID: store.cursorActorUID, queryDigest: digest, state: state)
        return try LiveQueryCursor.encode(
            .init(
                domain: LiveQueryCursor.tokenDomain, version: 1,
                storeID: storeID, actorUID: store.cursorActorUID,
                queryDigest: digest, state: state, orderField: field,
                boundary: try store.cursorSortValue(itemID: last, field: field), boundaryID: last,
                position: position + ids.count, totalReference: totalReference, previous: false,
                evaluatedAt: evaluatedAtString, timeZone: timeZone))
    }
    private enum RetrievalProjection {
        case full, content, summary
        case properties(Set<String>)
    }
    private func retrievalProjection(_ args: [String: Any]) throws -> RetrievalProjection {
        guard args["projection"] == nil || args["properties"] == nil else {
            throw TractandaError("invalidArguments", "projection and properties are mutually exclusive.")
        }
        if let properties = args["properties"] {
            guard let names = properties as? [String], names.count <= 64,
                Set(names).count == names.count,
                names.allSatisfy({ !$0.isEmpty && !$0.contains("\0") })
            else {
                throw TractandaError(
                    "invalidArguments",
                    "properties must contain up to 64 distinct, nonempty top-level field names.")
            }
            return .properties(Set(names))
        }
        guard let projection = args["projection"] else { return .full }
        guard let name = projection as? String else {
            throw TractandaError("invalidArguments", "projection must be full, content, or summary.")
        }
        switch name {
        case "full": return .full
        case "content": return .content
        case "summary": return .summary
        default: throw TractandaError("invalidArguments", "projection must be full, content, or summary.")
        }
    }
    private func projectedRevision(_ revision: Revision, projection: RetrievalProjection) throws -> Any {
        guard case .full = projection else {
            let identity: Set<String> = [
                "itemID", "revisionID", "classID", "schemaVersion", "createdAt", "modifiedAt", "isDeleted",
            ]
            let selected: Set<String>
            switch projection {
            case .content: selected = Set(revision.fields.keys).subtracting(["requestIdentity"])
            case .summary: selected = identity.union(["subject", "referenceLabels"])
            case .properties(let names): selected = identity.union(names)
            case .full: selected = []
            }
            let fields = revision.fields.filter { selected.contains($0.key) }
            return ["formatVersion": revision.formatVersion, "fields": try object(fields)]
        }
        return try object(revision)
    }
    private func boundedGet(
        ids: [String], projection: RetrievalProjection, maxBytes: Int
    ) throws -> [String: Any] {
        guard ids.count <= 64 else {
            throw TractandaError("invalidArguments", "maxBytes permits at most 64 requested ids.")
        }
        var list: [Any] = []
        var notFound: [String] = []
        var oversized: [String] = []
        func response(_ remaining: ArraySlice<String>) -> [String: Any] {
            [
                "list": list, "notFound": notFound, "state": store.state,
                "remainingIDs": Array(remaining), "oversizedIDs": oversized,
            ]
        }
        func fits(_ result: [String: Any]) throws -> Bool {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).count
                <= maxBytes
        }
        for index in ids.indices {
            let id = ids[index]
            let suffix = ids[ids.index(after: index)...]
            do {
                let revision = try store.get(id)
                let value = try projectedRevision(revision, projection: projection)
                var candidate = list
                candidate.append(value)
                let prior = list
                list = candidate
                if try fits(response(suffix)) { continue }
                list = prior
                let alone: [String: Any] = [
                    "list": [value], "notFound": [], "state": store.state,
                    "remainingIDs": [], "oversizedIDs": [],
                ]
                if try fits(alone) {
                    let result = response(ids[index...])
                    guard !list.isEmpty, try fits(result) else {
                        throw TractandaError(
                            "responseTooLarge",
                            "maxBytes cannot return this ID with its continuation; retry that ID alone or use a narrower projection."
                        )
                    }
                    return result
                }
                oversized.append(id)
                if try fits(response(suffix)) { continue }
                throw TractandaError(
                    "responseTooLarge", "maxBytes cannot contain the required continuation envelope.")
            } catch let error as TractandaError where error.code == "notFound" || error.code == "forbidden" {
                notFound.append(id)
                if try fits(response(suffix)) { continue }
                throw TractandaError(
                    "responseTooLarge", "maxBytes cannot contain the required continuation envelope.")
            }
        }
        let result = response([])
        guard try fits(result) else {
            throw TractandaError(
                "responseTooLarge", "maxBytes cannot contain the required continuation envelope.")
        }
        return result
    }
    private func extractionEntry(_ revision: Revision, projection: String) throws -> [String: Any] {
        let corpus = ItemTextContent.corpus(for: revision)
        let source = corpus.sourceText
        var fts: [String: Any] = ["searchEligible": !revision.isDeleted && !source.isEmpty]
        do {
            if let row = try store.ftsTextRow(for: revision.itemID) {
                fts["indexedRevisionID"] = row.revisionID
                fts["status"] =
                    row.revisionID == revision.revisionID && row.subject == corpus.subject
                        && row.body == corpus.body && row.metadata == corpus.metadata ? "current" : "stale"
            } else {
                fts["status"] = "missing"
            }
        } catch {
            // A transient cache failure may leave canonical extraction usable. A persistent
            // index fault has already gated the store; do not deliver part of that request.
            guard store.isCanonicalTrusted else {
                throw TractandaError("recoveryRequired", "Rebuild the disposable index before reading.")
            }
            // Never return SQLite messages, filenames or old index text.
            fts["status"] = "unavailable"
        }
        var result: [String: Any] = [
            "itemID": revision.itemID, "revisionID": revision.revisionID, "isDeleted": revision.isDeleted,
            "sourceHash": try SemanticSource.contentHash(sourceText: source),
            "sourceUTF8Bytes": source.utf8.count,
            "ftsUTF8Bytes": [
                "subject": corpus.subject.utf8.count, "body": corpus.body.utf8.count,
                "metadata": corpus.metadata.utf8.count,
            ],
            "index": ["fts": fts, "semantic": semantic.textDiagnostics(for: revision, corpus: corpus)],
        ]
        if projection == "source" { result["sourceText"] = source }
        if projection == "fts" {
            result["fts"] = ["subject": corpus.subject, "body": corpus.body, "metadata": corpus.metadata]
        }
        return result
    }

    private func extractedText(ids: [String], projection: String, maxBytes: Int) throws -> [String: Any] {
        let state = store.state
        var list: [[String: Any]] = []
        var notFound: [String] = []
        var oversized: [String] = []
        func response(_ remaining: ArraySlice<String>) -> [String: Any] {
            [
                "extractionProfile": ItemTextContent.profile, "state": state,
                "list": list, "notFound": notFound, "remainingIDs": Array(remaining),
                "oversizedIDs": oversized,
                "excludedRootFields": ItemTextContent.excludedRootFields.sorted(),
                "ignoredValueTypes": ["integer", "real", "boolean", "date", "reference", "bytes"],
                "blankMetadataTextOmitted": true, "blankSourceSectionsOmitted": true,
            ]
        }
        func fits(_ result: [String: Any]) throws -> Bool {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).count
                <= maxBytes
        }
        for offset in ids.indices {
            let id = ids[offset]
            let suffix = ids[(offset + 1)...]
            let revision: Revision
            do { revision = try store.get(id) } catch let error as TractandaError
                where error.code == "notFound" || error.code == "forbidden"
            {
                notFound.append(id)
                guard try fits(response(suffix)) else {
                    throw TractandaError("responseTooLarge", "The diagnostic continuation exceeds maxBytes.")
                }
                continue
            }
            let entry = try extractionEntry(revision, projection: projection)
            list.append(entry)
            if try fits(response(suffix)) { continue }
            list.removeLast()
            var alone = response([])
            alone["list"] = [entry]
            alone["notFound"] = [String]()
            alone["oversizedIDs"] = [String]()
            if try fits(alone) {
                let result = response(ids[offset...])
                guard offset > 0, try fits(result) else {
                    throw TractandaError(
                        "responseTooLarge",
                        "This record fits alone, but not with its continuation. Retry this ID alone, use summary, or increase maxBytes."
                    )
                }
                return result
            }
            oversized.append(id)
            guard try fits(response(suffix)) else {
                throw TractandaError("responseTooLarge", "The diagnostic continuation exceeds maxBytes.")
            }
        }
        let result = response([])
        guard try fits(result) else {
            throw TractandaError("responseTooLarge", "The diagnostic response exceeds maxBytes.")
        }
        return result
    }

    private func storeDescription(topic: String, currentUID: UInt32) throws -> [String: Any] {
        switch topic {
        case "overview":
            return [
                "topic": topic,
                "binding": "local experimental; not JMAP conformant",
                "capability": Self.capability,
                "currentUID": currentUID,
                "ownerUID": store.ownerUID,
                "accessScope": store.accessScope,
                "accessMode": store.isMultiUser ? "multi-user" : "single-user",
                "currentPermission": store.isAdministrator ? "administrator" : "read/edit by item permission",
                "callerIsAdministrator": store.isAdministrator,
                "overview": [
                    "Item is the concrete generic root; specialized item types form an inheritance hierarchy.",
                    "Categories are overlapping dimensions, not item types; All items is implicit.",
                    "To-do and waiting states are category assignments on ordinary items such as Item.",
                    "Views are transient queries or saved view definitions.",
                    "Permissions apply to every read. Use one guarded edit and retry the exact request after uncertainty.",
                    "Use content, summary, or properties projections and constrain query scope before retrieving bodies.",
                ],
                "resources": [
                    "tractanda://reference/intro", "tractanda://reference/items",
                    "tractanda://reference/query", "tractanda://reference/learning",
                    "tractanda://reference/semantic",
                ],
            ]
        case "types":
            let names = Set(ItemTypes.parents.keys).union(["Item"])
            return [
                "topic": topic,
                "types": names.sorted().map { name in
                    [
                        "classID": name,
                        "parentID": ItemTypes.parents[name].map { $0 as Any } ?? NSNull(),
                        "abstract": ItemTypes.abstract.contains(name),
                    ]
                },
            ]
        case "properties":
            let activityElement: [String: Any] = [
                "kind": "object",
                "properties": [
                    ["name": "at", "kind": "date"],
                    ["name": "text", "kind": "text"],
                ],
            ]
            return [
                "topic": topic,
                "nonExhaustive": true,
                "properties": [
                    ["name": "subject", "kind": "text", "editing": "ordinary"],
                    ["name": "body", "kind": "text", "editing": "ordinary"],
                    ["name": "workingNotes", "kind": "text", "editing": "ordinary"],
                    ["name": "waitingOn", "kind": "reference or text", "editing": "ordinary"],
                    ["name": "originalCreatedAt", "kind": "date", "editing": "ordinary source provenance"],
                    ["name": "originalModifiedAt", "kind": "date", "editing": "ordinary source provenance"],
                    [
                        "name": "activityNotes", "kind": "list", "editing": "ordinary",
                        "element": activityElement,
                    ],
                    [
                        "name": "activity", "kind": "list", "editing": "ordinary",
                        "element": activityElement,
                    ],
                    ["name": "referenceLabels", "kind": "list", "editing": "ordinary"],
                    ["name": "categoryParents", "kind": "list of current references", "editing": "ordinary"],
                    [
                        "name": "categoryOrder", "kind": "integer",
                        "editing": "ordinary sibling presentation order",
                    ],
                    ["name": "selection", "kind": "object", "editing": "ordinary category criterion"],
                    ["name": "categoryOverrides", "kind": "object", "editing": "ordinary include/exclude"],
                    ["name": "sortOrder", "kind": "integer", "editing": "optional explicit-view metadata"],
                    [
                        "name": "checklist", "kind": "list", "editing": "ordinary",
                        "element": [
                            "id": "text", "title": "text", "isComplete": "Boolean", "source": "text",
                        ],
                    ],
                    ["name": "dependencies", "kind": "list of current references", "editing": "ordinary"],
                    ["name": "viewDefinition", "kind": "object", "editing": "ordinary saved view"],
                    ["name": "permissions", "kind": "object", "editing": "owner-controlled"],
                    ["name": "target", "kind": "reference", "editing": "PersonalStateItem only"],
                    ["name": "personalOverrides", "kind": "object", "editing": "PersonalStateItem only"],
                    [
                        "name": "values",
                        "kind": "text, Int64, real, Boolean, date, list, object, reference, bytes",
                        "editing": "ordinary tagged values",
                    ],
                    ["name": "itemID", "kind": "UUID text", "editing": "server-owned"],
                    ["name": "revisionID", "kind": "UUID text", "editing": "server-owned"],
                    ["name": "classID", "kind": "text", "editing": "server-owned"],
                    ["name": "schemaVersion", "kind": "Int64", "editing": "server-owned"],
                    ["name": "createdAt", "kind": "date", "editing": "server-owned"],
                    ["name": "modifiedAt", "kind": "date", "editing": "server-owned"],
                    ["name": "supersedes", "kind": "UUID text", "editing": "server-owned"],
                    ["name": "actor", "kind": "text", "editing": "server-owned"],
                    ["name": "operationID", "kind": "text", "editing": "server-owned"],
                    [
                        "name": "requestIdentity", "kind": "text",
                        "editing": "server-owned and withheld by content projection",
                    ],
                ],
                "note":
                    "These are field conventions; arbitrary top-level keys and tagged values remain supported. "
                    + "Use date tags for timestamps, with an ISO 8601 timezone. Nested element descriptions "
                    + "do not imply nested-array query support.",
            ]
        default: throw TractandaError("invalidArguments", "topic must be overview, types, or properties.")
        }
    }
    private func execute(_ method: String, _ args: [String: Any], uid: UInt32) throws -> [String: Any] {
        switch method {
        case "Core/echo": return args
        case "TractandaSemantic/status":
            try check(args, allowed: [])
            return try semantic.status()
        case "TractandaSemantic/configure":
            try check(args, allowed: ["configuration", "expectedConfigurationID"])
            guard let value = args["configuration"] else {
                throw TractandaError("invalidArguments", "Supply semantic configuration.")
            }
            if let expected = args["expectedConfigurationID"], !(expected is String) {
                throw TractandaError("invalidArguments", "expectedConfigurationID must be text or omitted.")
            }
            return try semantic.configure(
                decode(SemanticConfiguration.self, value),
                expectedConfigurationID: args["expectedConfigurationID"] as? String)
        case "TractandaSemantic/rebuild", "TractandaSemantic/reset":
            try check(args, allowed: ["expectedConfigurationID", "operationID"])
            let expected = try string(args, "expectedConfigurationID")
            let operation = try string(args, "operationID")
            return try
                (method == "TractandaSemantic/rebuild"
                ? semantic.rebuild(expectedConfigurationID: expected, operationID: operation)
                : semantic.reset(expectedConfigurationID: expected, operationID: operation))
        case "TractandaSemantic/search":
            try check(
                args,
                allowed: [
                    "text", "expression", "categoryPath", "excludedCategoryIDs", "viewID", "limit", "at",
                    "timeZone",
                ])
            for key in ["expression", "viewID"] where args[key] != nil && !(args[key] is String) {
                throw TractandaError("invalidArguments", "\(key) must be text.")
            }
            let evaluatedAt: Date
            if args["at"] == nil {
                evaluatedAt = Date()
            } else {
                guard let date = Timestamp.parse(try string(args, "at")) else {
                    throw TractandaError("invalidArguments", "at must be an ISO 8601 timestamp.")
                }
                evaluatedAt = date
            }
            let timeZone = args["timeZone"] == nil ? "UTC" : try string(args, "timeZone")
            _ = try QueryCalendar.make(timeZone: timeZone)
            return try semantic.search(
                text: string(args, "text"), expression: args["expression"] as? String,
                categoryPath: strings(args, "categoryPath", default: []),
                excludedCategoryIDs: strings(args, "excludedCategoryIDs", default: []),
                viewID: args["viewID"] as? String,
                limit: integer(args, "limit", default: 20, range: 1...64), evaluatedAt: evaluatedAt,
                timeZone: timeZone)
        case "TractandaSemantic/results":
            try check(args, allowed: ["queryID"])
            return try semantic.results(queryID: string(args, "queryID"))
        case "TractandaCategory/installTemplate":
            try check(args, allowed: ["template", "timeZone"])
            guard let template = args["template"] else {
                throw TractandaError("invalidArguments", "Supply a template.")
            }
            let definition = try decode(CategoryTemplate.self, template)
            return [
                "items": try definition.install(in: store, timeZone: string(args, "timeZone"), actorUID: uid)
            ]
        case "TractandaCategory/memberships":
            try check(args, allowed: ["ids", "categoryRootIDs", "at"])
            let date: Date
            if args["at"] == nil {
                date = Date()
            } else {
                guard let parsed = Timestamp.parse(try string(args, "at")) else {
                    throw TractandaError("invalidArguments", "Invalid query timestamp.")
                }
                date = parsed
            }
            return try object(
                Categories.memberships(
                    store: store, ids: strings(args, "ids"),
                    categoryRootIDs: strings(args, "categoryRootIDs"),
                    at: date)) as! [String: Any]
        case "TractandaLearning/status", "TractandaLearning/train", "TractandaLearning/reset":
            try check(args, allowed: ["categoryID"])
            let id = try string(args, "categoryID")
            let state: CategoryLearningState
            if method == "TractandaLearning/train" {
                state = try learning.train(categoryID: id)
            } else if method == "TractandaLearning/reset" {
                state = try learning.reset(categoryID: id)
            } else {
                state = try learning.status(for: id)
            }
            return try object(state) as! [String: Any]
        case "TractandaLearning/suggest", "TractandaLearning/categories":
            let isCategoryQuery = method == "TractandaLearning/categories"
            try check(
                args,
                allowed: isCategoryQuery
                    ? ["itemID", "categoryIDs", "position", "limit", "ifInState"]
                    : ["categoryID", "expression", "position", "limit", "ifInState"])
            if args["ifInState"] != nil, try string(args, "ifInState") != learning.queryState {
                throw TractandaError(
                    "stateMismatch", "Items or learning models changed; restart suggestion pagination.")
            }
            let position = try integer(args, "position", default: 0, range: 0...Int.max)
            let limit = try integer(args, "limit", default: 100, range: 1...256)
            if isCategoryQuery {
                return try object(
                    learning.categories(
                        for: string(args, "itemID"),
                        categoryIDs: args["categoryIDs"] == nil ? nil : strings(args, "categoryIDs"),
                        position: position, limit: limit)) as! [String: Any]
            }
            if let value = args["expression"], !(value is String) {
                throw TractandaError("invalidArguments", "expression must be text.")
            }
            return try object(
                learning.suggestions(
                    categoryID: string(args, "categoryID"),
                    expression: args["expression"] as? String, position: position, limit: limit))
                as! [String: Any]
        case "TractandaLearning/settings":
            try check(args, allowed: ["categoryID", "expectedRevisionID", "operationID", "settings"])
            guard let settings = args["settings"] else {
                throw TractandaError("invalidArguments", "Supply tagged learning settings.")
            }
            return try object(
                learning.setSettings(
                    categoryID: string(args, "categoryID"),
                    expectedRevisionID: string(args, "expectedRevisionID"),
                    operationID: string(args, "operationID"),
                    settings: decode(ItemValue.self, settings), actorUID: uid)) as! [String: Any]
        case "TractandaLearning/feedback":
            try check(
                args,
                allowed: ["itemID", "categoryID", "expectedRevisionID", "operationID", "action", "modelID"])
            guard let action = try LearningFeedbackAction(rawValue: string(args, "action")) else {
                throw TractandaError("invalidArguments", "Unknown feedback action.")
            }
            if let value = args["modelID"], !(value is String) {
                throw TractandaError("invalidArguments", "modelID must be text.")
            }
            return try object(
                learning.recordFeedback(
                    itemID: string(args, "itemID"),
                    categoryID: string(args, "categoryID"),
                    expectedRevisionID: string(args, "expectedRevisionID"),
                    action: action, operationID: string(args, "operationID"),
                    modelID: args["modelID"] as? String,
                    actorUID: uid)) as! [String: Any]
        case "TractandaItem/get":
            try check(args, allowed: ["ids", "projection", "properties", "maxBytes"])
            let ids = try strings(args, "ids")
            let projection = try retrievalProjection(args)
            if args["maxBytes"] != nil {
                return try boundedGet(
                    ids: ids, projection: projection,
                    maxBytes: integer(args, "maxBytes", default: 8_192, range: 8_192...524_288))
            }
            var list: [Any] = []
            var notFound: [String] = []
            var retainedBytes = 0
            for id in ids {
                do {
                    let value = try projectedRevision(store.get(id), projection: projection)
                    let size = try JSONSerialization.data(
                        withJSONObject: value, options: [.fragmentsAllowed]
                    ).count
                    let budget = min(8 * 1024 * 1024 - 16 * 1024, store.pooledRecordByteLimit)
                    guard size <= budget - retainedBytes else {
                        throw TractandaError(
                            "responseTooLarge", "Use fewer IDs or a narrower projection.")
                    }
                    retainedBytes += size
                    list.append(value)
                } catch let error as TractandaError
                    where error.code == "notFound" || error.code == "forbidden"
                { notFound.append(id) }
            }
            return [
                "list": list,
                "notFound": notFound, "state": store.state,
            ]
        case "TractandaItem/extractedText":
            try check(args, allowed: ["ids", "projection", "maxBytes"])
            let ids = try strings(args, "ids")
            guard (1...64).contains(ids.count), Set(ids).count == ids.count else {
                throw TractandaError("invalidArguments", "ids must contain 1–64 distinct UUIDs.")
            }
            for id in ids { try Identifier.validate(id) }
            guard args["projection"] == nil || args["projection"] is String else {
                throw TractandaError("invalidArguments", "projection must be text.")
            }
            let projection = args["projection"] as? String ?? "source"
            guard ["source", "fts", "summary"].contains(projection) else {
                throw TractandaError("invalidArguments", "projection must be source, fts, or summary.")
            }
            let maximum = try integer(args, "maxBytes", default: 65_536, range: 8_192...524_288)
            return try extractedText(ids: ids, projection: projection, maxBytes: maximum)
        case "TractandaItem/query":
            try check(
                args,
                allowed: [
                    "expression", "text", "categoryPath", "excludedCategoryIDs", "position", "limit",
                    "viewID", "sort", "sectionID", "cursor",
                    "at", "timeZone",
                ])
            for key in ["expression", "text"] where args[key] != nil && !(args[key] is String) {
                throw TractandaError("invalidArguments", "\(key) must be text.")
            }
            let cursor = try args["cursor"].map { _ in try LiveQueryCursor.decode(try string(args, "cursor"))
            }
            guard cursor == nil || args["position"] == nil else {
                throw TractandaError("invalidArguments", "Use cursor or position, not both.")
            }
            let position = try integer(args, "position", default: 0, range: 0...Int.max)
            let limit = try integer(args, "limit", default: 100, range: 1...256)
            let evaluatedAtString =
                try args["at"].map { _ in try string(args, "at") }
                ?? cursor?.evaluatedAt ?? Timestamp.format(Date())
            guard let evaluatedAt = Timestamp.parse(evaluatedAtString) else {
                throw TractandaError("invalidArguments", "Invalid query timestamp.")
            }
            let timeZone =
                try args["timeZone"].map { _ in try string(args, "timeZone") }
                ?? cursor?.timeZone ?? "UTC"
            let queryCalendar = try QueryCalendar.make(timeZone: timeZone)
            let queryDigest = try LiveQueryCursor.digest(args)
            if let cursor {
                guard cursor.storeID == (try store.cursorStoreIdentity),
                    cursor.actorUID == store.cursorActorUID, cursor.queryDigest == queryDigest,
                    cursor.state == store.state, cursor.evaluatedAt == evaluatedAtString,
                    cursor.timeZone == timeZone
                else {
                    throw TractandaError(
                        "invalidCursor", "The live query cursor is invalid or no longer current.")
                }
            }
            if let cursor {
                let allowed = Set(["cursor", "limit", "at", "timeZone", "sort", "expression"])
                guard Set(args.keys).isSubset(of: allowed) else {
                    throw TractandaError("unsupportedCursor", "This query shape uses position paging.")
                }
                let sort = try args["sort"].map { try decode([ItemSort].self, $0) } ?? []
                let field: String
                if sort.isEmpty {
                    field = "modifiedAt"
                } else if sort.count == 1, sort[0].categoryRootID == nil, !sort[0].isAscending,
                    let property = sort[0].property,
                    ["createdAt", "modifiedAt"].contains(metadataKey(property))
                {
                    field = metadataKey(property)
                } else {
                    throw TractandaError("unsupportedCursor", "This ordering uses position paging.")
                }
                let predicate = try (args["expression"] as? String).map(SpotlightQuery.init)
                guard
                    args["expression"] == nil || predicate?.indexExactClassEquals != nil
                        || predicate.map({ !$0.boundedIndexCandidatePlan.isAll }) == true
                else {
                    throw TractandaError("unsupportedCursor", "This expression uses position paging.")
                }
                guard cursor.orderField == field else {
                    throw TractandaError(
                        "invalidCursor", "The live query cursor is invalid or no longer current.")
                }
                guard
                    let exactTotal = LiveQueryCursor.exactTotal(
                        reference: cursor.totalReference, storeID: cursor.storeID, actorUID: cursor.actorUID,
                        queryDigest: queryDigest, state: cursor.state)
                else {
                    throw TractandaError(
                        "invalidCursor", "The live query cursor is invalid or no longer current.")
                }
                let seek = try store.indexedSeekPage(
                    order: field == "createdAt" ? .createdAt : .modifiedAt,
                    classEquals: predicate?.indexExactClassEquals,
                    boundary: cursor.boundary, boundaryID: cursor.boundaryID,
                    previous: cursor.previous, limit: limit, knownTotal: exactTotal,
                    candidatePlan: predicate?.boundedIndexCandidatePlan ?? .all,
                    needsFullRevision: predicate != nil && predicate?.indexExactClassEquals == nil,
                    accepts: { revision in
                        predicate?.matches(revision, at: evaluatedAt, calendar: queryCalendar)
                            ?? true
                    })
                let currentState = store.state
                let pagePosition =
                    cursor.previous ? max(0, cursor.position - seek.ids.count) : cursor.position
                var next: String?
                var previous: String?
                if let last = seek.ids.last, pagePosition + seek.ids.count < seek.total {
                    next = try LiveQueryCursor.encode(
                        .init(
                            domain: LiveQueryCursor.tokenDomain, version: 1,
                            storeID: cursor.storeID, actorUID: cursor.actorUID,
                            queryDigest: queryDigest, state: currentState, orderField: field,
                            boundary: try store.cursorSortValue(itemID: last, field: field),
                            boundaryID: last, position: pagePosition + seek.ids.count,
                            totalReference: cursor.totalReference, previous: false,
                            evaluatedAt: evaluatedAtString, timeZone: timeZone))
                }
                if let first = seek.ids.first, pagePosition > 0 {
                    previous = try LiveQueryCursor.encode(
                        .init(
                            domain: LiveQueryCursor.tokenDomain, version: 1,
                            storeID: cursor.storeID, actorUID: cursor.actorUID,
                            queryDigest: queryDigest, state: currentState, orderField: field,
                            boundary: try store.cursorSortValue(itemID: first, field: field),
                            boundaryID: first, position: pagePosition,
                            totalReference: cursor.totalReference, previous: true,
                            evaluatedAt: evaluatedAtString, timeZone: timeZone))
                }
                return [
                    "ids": seek.ids, "position": pagePosition, "total": seek.total,
                    "queryState": currentState,
                    "evaluatedAt": evaluatedAtString,
                    "nextCursor": next as Any? ?? NSNull(), "previousCursor": previous as Any? ?? NSNull(),
                ]
            }
            let page: ItemIndex.Page
            if args["viewID"] != nil {
                guard args["expression"] == nil, args["text"] == nil, args["categoryPath"] == nil,
                    args["sort"] == nil, args["excludedCategoryIDs"] == nil
                else {
                    throw TractandaError("invalidArguments", "Use either viewID or inline query criteria.")
                }
                page = try Categories.savedViewPage(
                    store: store, id: string(args, "viewID"),
                    sectionID: args["sectionID"].map { _ in try string(args, "sectionID") },
                    position: position, limit: limit, at: evaluatedAt, timeZone: timeZone)
            } else {
                guard args["sectionID"] == nil else {
                    throw TractandaError("invalidArguments", "sectionID requires a saved viewID.")
                }
                let sort = try args["sort"].map { try decode([ItemSort].self, $0) } ?? []
                try ItemSort.validate(sort)
                page = try Categories.page(
                    store: store, expression: args["expression"] as? String,
                    text: args["text"] as? String, categoryPath: strings(args, "categoryPath", default: []),
                    excludedCategoryIDs: strings(args, "excludedCategoryIDs", default: []),
                    sort: sort, position: position, limit: limit, at: evaluatedAt, timeZone: timeZone)
            }
            return [
                "ids": page.ids, "position": position, "total": page.total, "queryState": store.state,
                "evaluatedAt": evaluatedAtString,
                "nextCursor": try makeInitialCursor(
                    args: args, ids: page.ids, total: page.total, position: position,
                    evaluatedAt: evaluatedAt, evaluatedAtString: evaluatedAtString,
                    timeZone: timeZone, digest: queryDigest),
                "previousCursor": NSNull(),
            ]
        case "TractandaItem/commit":
            try check(
                args,
                allowed: [
                    "action", "itemID", "expectedRevisionID", "classID", "changes", "unset", "operationID",
                ])
            let request = try decode(CommitRequest.self, args)
            return try object(store.commit(request, actorUID: uid)) as! [String: Any]
        case "TractandaItem/history":
            try check(args, allowed: ["itemID", "position", "limit", "projection", "properties"])
            let position = try integer(args, "position", default: 0, range: 0...Int.max)
            let limit = try integer(args, "limit", default: 100, range: 1...256)
            let page = try store.historyPageBounded(
                string(args, "itemID"), position: position, limit: limit)
            return [
                "list": try page.list.map {
                    try projectedRevision($0, projection: retrievalProjection(args))
                },
                "total": page.total,
            ]
        case "TractandaRevision/get":
            try check(args, allowed: ["itemID", "revisionID", "projection", "properties"])
            return [
                "revision": try projectedRevision(
                    store.get(string(args, "itemID"), revisionID: string(args, "revisionID")),
                    projection: retrievalProjection(args))
            ]
        case "TractandaItem/resolve":
            try check(args, allowed: ["itemID", "revisionID", "path", "segments", "at"])
            guard (args["path"] == nil) != (args["segments"] == nil) else {
                throw TractandaError("invalidArguments", "Supply either path or segments.")
            }
            if let revision = args["revisionID"], !(revision is String) {
                throw TractandaError("invalidArguments", "revisionID must be text.")
            }
            let segments =
                try args["path"].map { _ in try ItemPath.parse(string(args, "path")) }
                ?? strings(args, "segments")
            var date = Date()
            if args["at"] != nil {
                guard let parsed = Timestamp.parse(try string(args, "at")) else {
                    throw TractandaError("invalidArguments", "Invalid effective time.")
                }
                date = parsed
            }
            let reference = ItemReference(
                try string(args, "itemID"), revisionID: args["revisionID"] as? String)
            return try object(
                ItemPath.resolve(reference, segments: segments, at: date) {
                    try store.get($0.itemID, revisionID: $0.revisionID)
                }) as! [String: Any]
        case "TractandaItem/explain":
            try check(args, allowed: ["itemID", "categoryID"])
            return try object(
                Categories.explain(
                    store.get(string(args, "itemID")), category: store.get(string(args, "categoryID")),
                    store: store))
                as! [String: Any]
        case "TractandaStore/rebuild":
            try check(args, allowed: [])
            try store.rebuildIndex()
            return ["state": store.state, "warnings": store.recoveryWarnings]
        case "TractandaStore/info":
            try check(args, allowed: [])
            return [
                "features": [
                    ServerFeature.runtimeIdentity.rawValue, ServerFeature.semanticJobTiming.rawValue,
                    ServerFeature.categoryMembershipSort.rawValue,
                    ServerFeature.categoryMembershipProjection.rawValue,
                    ServerFeature.extractedTextDiagnostics.rawValue,
                    ServerFeature.liveSeekCursor.rawValue,
                ],
                "server": try JSONSerialization.jsonObject(with: JSON.encode(RuntimeIdentity.current)),
                "state": store.state, "ownerUID": store.ownerUID, "queryProfile": SpotlightQuery.profile,
                "binding": "local experimental; not JMAP conformant", "capability": Self.capability,
                "warnings": store.isAdministrator ? store.recoveryWarnings : [],
                "startupRecovery": store.isAdministrator ? store.startupRecovery : [:],
                "canonicalVerification": store.isAdministrator ? store.canonicalVerificationStatus : [:],
                "accessMode": store.isMultiUser ? "multi-user" : "single-user",
                "accessScope": store.accessScope,
                "callerIsAdministrator": store.isAdministrator,
                "learningProfile": CategoryLearningSettings.profile,
                "itemTextProfile": ItemTextContent.profile,
                "itemTextExcludedRootFields": ItemTextContent.excludedRootFields.sorted(),
                "itemTextAttachmentLimit":
                    "Attachments, bytes, references, and remote content are not extracted.",
            ]
        case "TractandaStore/describe":
            try check(args, allowed: ["topic"])
            let topic = args["topic"] == nil ? "overview" : try string(args, "topic")
            return try storeDescription(topic: topic, currentUID: uid)
        case "TractandaItem/changes":
            throw TractandaError(
                "cannotCalculateChanges",
                "Synchronization deltas are not implemented; perform a full query/get refresh.")
        default: throw TractandaError("unknownMethod", "Method is not available in the local prototype.")
        }
    }
    private func integer(_ args: [String: Any], _ key: String, default value: Int, range: ClosedRange<Int>)
        throws -> Int
    {
        guard let input = args[key] else { return value }
        guard let number = input as? NSNumber, String(cString: number.objCType) != "c",
            let result = Int(number.stringValue), range.contains(result)
        else {
            throw TractandaError("invalidArguments", "Invalid \(key).")
        }
        return result
    }

    public func handle(_ data: Data, peerUID: UInt32) -> Data {
        // Semantic maintenance deliberately runs outside the temporary caller
        // scope below. It sees canonical snapshots only and cannot prune a
        // different user's unreadable vectors.
        semantic.maintain()
        defer { semantic.maintain() }
        do {
            return try store.withAccess(forUID: peerUID) { try handleAuthorized(data, peerUID: peerUID) }
        } catch {
            let failure =
                error as? TractandaError ?? TractandaError("invalidRequest", String(describing: error))
            return (try? JSON.encode(failure)) ?? Data("{\"code\":\"serverError\"}".utf8)
        }
    }

    func maintainSemanticIndex() {
        semantic.maintain()
    }

    /// One ordinary indexed query may run its SQL count/page on an isolated read lease.
    /// Unsupported or mixed envelopes retain the serial method implementation.
    func preparePooledQuery(_ data: Data, peerUID: UInt32) throws -> PreparedPooledQuery? {
        guard data.count <= 8 * 1024 * 1024,
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(request.keys) == ["using", "methodCalls"],
            let using = request["using"] as? [String], using.contains(Self.capability),
            Set(using).isSubset(of: [Self.capability, "urn:ietf:params:jmap:core"]),
            let calls = request["methodCalls"] as? [[Any]], calls.count == 1,
            calls[0].count == 3, calls[0][0] as? String == "TractandaItem/query",
            let args = calls[0][1] as? [String: Any],
            let callID = calls[0][2] as? String, !callID.isEmpty,
            Set(args.keys).isSubset(of: [
                "expression", "sort", "position", "limit", "at", "timeZone",
                "categoryPath", "excludedCategoryIDs",
            ]),
            args["expression"] == nil || args["expression"] is String,
            args["at"] == nil || args["at"] is String,
            args["timeZone"] == nil || args["timeZone"] is String,
            args["categoryPath"] == nil || args["categoryPath"] is [String],
            args["excludedCategoryIDs"] == nil || args["excludedCategoryIDs"] is [String],
            let position = try? integer(args, "position", default: 0, range: 0...Int.max),
            let limit = try? integer(args, "limit", default: 100, range: 1...256)
        else { return nil }
        let predicate: SpotlightQuery?
        if let expression = args["expression"] as? String {
            guard let parsed = try? SpotlightQuery(expression),
                parsed.indexExactClassEquals != nil || !parsed.boundedIndexCandidatePlan.isAll
            else { return nil }
            predicate = parsed
        } else {
            predicate = nil
        }
        let sort: [ItemSort]
        if let value = args["sort"] {
            guard let parsed = try? decode([ItemSort].self, value) else { return nil }
            sort = parsed
        } else {
            sort = []
        }
        let orderColumn: String
        if sort.isEmpty {
            orderColumn = "modified"
        } else if sort.count == 1,
            !sort[0].isAscending, sort[0].categoryRootID == nil,
            let property = sort[0].property
        {
            switch metadataKey(property) {
            case "modifiedAt": orderColumn = "modified"
            case "createdAt": orderColumn = "created"
            default: return nil
            }
        } else {
            return nil
        }
        let evaluatedAtString = args["at"] as? String ?? Timestamp.format(Date())
        guard let evaluatedAt = Timestamp.parse(evaluatedAtString) else { return nil }
        let timeZone = args["timeZone"] as? String ?? "UTC"
        guard (try? QueryCalendar.make(timeZone: timeZone)) != nil else { return nil }
        let categoryPath = args["categoryPath"] as? [String] ?? []
        let excludedCategoryIDs = args["excludedCategoryIDs"] as? [String] ?? []
        guard categoryPath.count <= 32, excludedCategoryIDs.count <= 32,
            excludedCategoryIDs.isEmpty || !categoryPath.isEmpty
        else { return nil }
        let digest = try LiveQueryCursor.digest(args)
        let argumentsJSON = try JSONSerialization.data(withJSONObject: args)
        return try store.withAccess(forUID: peerUID) {
            guard let authority = try store.pooledReadAuthority() else { return nil }
            var category: PooledCategorySelection?
            var categoryPlan: SpotlightQuery.IndexCandidatePlan = .all
            if !categoryPath.isEmpty {
                let requested = Set(categoryPath + excludedCategoryIDs)
                for id in requested { _ = try Categories.rule(store.get(id)) }
                guard try store.categoryGraphIsFullyReadable(requestedCategoryIDs: requested)
                else { return nil }
                let definitions = try store.readableCategoryDefinitions(requestedCategoryIDs: requested)
                guard
                    let positive = try Categories.manualCategoryPositiveSeeds(
                        store: store, definitions: definitions, requested: requested)
                else { return nil }
                categoryPlan = positive
                let ownerNames = try store.pooledApplicablePersonalOwnerNames(authority: authority)
                    .sorted()
                guard ownerNames.count <= 400 else { return nil }
                category = .init(
                    definitions: definitions, path: categoryPath, excluded: excludedCategoryIDs,
                    ownerNames: ownerNames)
            }
            let source = try store.pooledQuerySource(
                classEquals: predicate?.indexClassEquals,
                candidatePlan: .and(predicate?.boundedIndexCandidatePlan ?? .all, categoryPlan),
                authority: authority)
            return PreparedPooledQuery(
                callID: callID, argumentsJSON: argumentsJSON, sourceSQL: source.sql,
                bindings: source.arguments.map(SQLiteReadValue.text), authority: authority,
                orderColumn: orderColumn, position: position, limit: limit,
                evaluatedAt: evaluatedAt, evaluatedAtString: evaluatedAtString,
                timeZone: timeZone, queryDigest: digest,
                residual: predicate?.indexExactClassEquals == nil ? predicate : nil,
                category: category, viewID: nil, viewRevisionID: nil)
        }
    }

    func preparePooledSavedViewQuery(_ data: Data, peerUID: UInt32) throws -> PreparedPooledQuery? {
        guard data.count <= 8 * 1024 * 1024,
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(request.keys) == ["using", "methodCalls"],
            let using = request["using"] as? [String], using.contains(Self.capability),
            Set(using).isSubset(of: [Self.capability, "urn:ietf:params:jmap:core"]),
            let calls = request["methodCalls"] as? [[Any]], calls.count == 1,
            calls[0].count == 3, calls[0][0] as? String == "TractandaItem/query",
            let args = calls[0][1] as? [String: Any],
            let callID = calls[0][2] as? String, !callID.isEmpty,
            Set(args.keys).isSubset(of: [
                "viewID", "sectionID", "position", "limit", "at", "timeZone",
            ]),
            let viewID = args["viewID"] as? String, !viewID.isEmpty,
            args["sectionID"] == nil || args["sectionID"] is String
        else { return nil }
        let view = try store.withAccess(forUID: peerUID) { try store.get(viewID) }
        guard !view.isDeleted, let value = view.fields["viewDefinition"],
            let definition = try? SavedViewDefinition(value), definition.text == nil
        else { return nil }
        var path = definition.categoryPath
        if let sectionID = args["sectionID"] as? String {
            guard definition.presentation.sectionIDs.contains(sectionID) else { return nil }
            if !path.contains(sectionID) { path.append(sectionID) }
        }
        var effective = args
        effective.removeValue(forKey: "viewID")
        effective.removeValue(forKey: "sectionID")
        if let expression = definition.expression { effective["expression"] = expression }
        if !path.isEmpty { effective["categoryPath"] = path }
        if !definition.excludedCategoryIDs.isEmpty {
            effective["excludedCategoryIDs"] = definition.excludedCategoryIDs
        }
        if !definition.sort.isEmpty {
            effective["sort"] = try JSONSerialization.jsonObject(with: JSON.encode(definition.sort))
        }
        let synthetic = try JSONSerialization.data(withJSONObject: [
            "using": using, "methodCalls": [["TractandaItem/query", effective, callID]],
        ])
        guard let prepared = try preparePooledQuery(synthetic, peerUID: peerUID) else { return nil }
        return PreparedPooledQuery(
            callID: callID, argumentsJSON: try JSONSerialization.data(withJSONObject: args),
            sourceSQL: prepared.sourceSQL, bindings: prepared.bindings,
            authority: prepared.authority, orderColumn: prepared.orderColumn,
            position: prepared.position, limit: prepared.limit,
            evaluatedAt: prepared.evaluatedAt, evaluatedAtString: prepared.evaluatedAtString,
            timeZone: prepared.timeZone, queryDigest: try LiveQueryCursor.digest(args),
            residual: prepared.residual, category: prepared.category,
            viewID: viewID, viewRevisionID: view.revisionID)
    }

    func preparePooledGet(_ data: Data, peerUID: UInt32) throws -> PreparedPooledGet? {
        guard data.count <= 8 * 1024 * 1024,
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(request.keys) == ["using", "methodCalls"],
            let using = request["using"] as? [String], using.contains(Self.capability),
            Set(using).isSubset(of: [Self.capability, "urn:ietf:params:jmap:core"]),
            let calls = request["methodCalls"] as? [[Any]], calls.count == 1,
            calls[0].count == 3, calls[0][0] as? String == "TractandaItem/get",
            let args = calls[0][1] as? [String: Any],
            let callID = calls[0][2] as? String, !callID.isEmpty,
            Set(args.keys).isSubset(of: ["ids", "projection", "properties"]),
            let ids = args["ids"] as? [String], (1...64).contains(ids.count),
            Set(ids).count == ids.count,
            (try? retrievalProjection(args)) != nil
        else { return nil }
        let argumentsJSON = try JSONSerialization.data(withJSONObject: args)
        return try store.withAccess(forUID: peerUID) {
            guard let authority = try store.pooledReadAuthority() else { return nil }
            let admitted = try store.preparePooledGet(ids)
            var bytes = 0
            var resourceLimited = false
            for row in admitted.rows {
                guard row.size <= UInt64(store.pooledRecordByteLimit - bytes) else {
                    resourceLimited = true
                    break
                }
                bytes += Int(row.size)
            }
            return PreparedPooledGet(
                callID: callID, argumentsJSON: argumentsJSON,
                rows: resourceLimited ? [] : admitted.rows,
                notFound: resourceLimited ? [] : admitted.notFound,
                authority: authority, root: store.root,
                ownerUID: store.ownerUID, resourceLimited: resourceLimited)
        }
    }

    func finishPooledGet(
        _ prepared: PreparedPooledGet, records: [PooledCanonicalRecord],
        peerUID: UInt32
    ) throws -> Data? {
        try store.withAccess(forUID: peerUID) {
            guard store.isCanonicalTrusted,
                let current = try store.pooledReadAuthority(), current == prepared.authority,
                try store.verifyPooledGet(records, rows: prepared.rows)
            else { return nil }
            do {
                guard !prepared.resourceLimited else {
                    throw TractandaError("resourceLimit", "Get exceeds the bounded record byte window.")
                }
                guard
                    let args = try JSONSerialization.jsonObject(
                        with: prepared.argumentsJSON) as? [String: Any]
                else { throw TractandaError("invalidRequest", "Pooled get arguments changed.") }
                let projection = try retrievalProjection(args)
                let result: [String: Any] = [
                    "list": try records.map { try projectedRevision($0.revision, projection: projection) },
                    "notFound": prepared.notFound, "state": current.state,
                ]
                let response = try JSONSerialization.data(
                    withJSONObject: [
                        "methodResponses": [["TractandaItem/get", result, prepared.callID]],
                        "sessionState": current.state,
                    ], options: [.sortedKeys, .prettyPrinted])
                guard response.count <= 8 * 1024 * 1024 else {
                    throw TractandaError("responseTooLarge", "Use a smaller item retrieval page.")
                }
                return response
            } catch {
                let failure =
                    error as? TractandaError
                    ?? TractandaError("invalidArguments", String(describing: error))
                return try JSONSerialization.data(
                    withJSONObject: [
                        "methodResponses": [
                            [
                                "error", ["type": failure.code, "description": failure.message],
                                prepared.callID,
                            ]
                        ],
                        "sessionState": store.state,
                    ], options: [.sortedKeys, .prettyPrinted])
            }
        }
    }

    func preparePooledHistory(_ data: Data, peerUID: UInt32) throws -> PreparedPooledHistory? {
        guard data.count <= 8 * 1024 * 1024,
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(request.keys) == ["using", "methodCalls"],
            let using = request["using"] as? [String], using.contains(Self.capability),
            Set(using).isSubset(of: [Self.capability, "urn:ietf:params:jmap:core"]),
            let calls = request["methodCalls"] as? [[Any]], calls.count == 1,
            calls[0].count == 3, calls[0][0] as? String == "TractandaItem/history",
            let args = calls[0][1] as? [String: Any],
            let callID = calls[0][2] as? String, !callID.isEmpty,
            Set(args.keys).isSubset(of: ["itemID", "position", "limit", "projection", "properties"]),
            let itemID = args["itemID"] as? String, !itemID.isEmpty,
            let position = try? integer(args, "position", default: 0, range: 0...Int.max),
            let limit = try? integer(args, "limit", default: 100, range: 1...256),
            (try? retrievalProjection(args)) != nil
        else { return nil }
        let argumentsJSON = try JSONSerialization.data(withJSONObject: args)
        return try store.withAccess(forUID: peerUID) {
            guard let authority = try store.pooledReadAuthority() else { return nil }
            let headID = try store.preparePooledHistory(itemID)
            return PreparedPooledHistory(
                callID: callID, argumentsJSON: argumentsJSON, itemID: itemID,
                headRevisionID: headID, position: position, limit: limit,
                authority: authority, root: store.root, ownerUID: store.ownerUID,
                maximumSerializedBytes: store.pooledRecordByteLimit,
                batchLimit: store.pooledHistoryBatchLimit)
        }
    }

    func finishPooledHistory(
        _ prepared: PreparedPooledHistory, result: PooledHistoryResult, peerUID: UInt32
    ) throws -> Data? {
        try store.withAccess(forUID: peerUID) {
            guard store.isCanonicalTrusted,
                let current = try store.pooledReadAuthority(), current == prepared.authority,
                try store.verifyPooledHistory(
                    result, itemID: prepared.itemID, headRevisionID: prepared.headRevisionID)
            else { return nil }
            do {
                guard
                    let args = try JSONSerialization.jsonObject(
                        with: prepared.argumentsJSON) as? [String: Any]
                else { throw TractandaError("invalidRequest", "Pooled history arguments changed.") }
                let projection = try retrievalProjection(args)
                let payload: [String: Any] = [
                    "list": try result.records.map {
                        try projectedRevision($0.revision, projection: projection)
                    },
                    "total": result.total,
                ]
                let response = try JSONSerialization.data(
                    withJSONObject: [
                        "methodResponses": [["TractandaItem/history", payload, prepared.callID]],
                        "sessionState": current.state,
                    ], options: [.sortedKeys, .prettyPrinted])
                guard response.count <= 8 * 1024 * 1024 else {
                    throw TractandaError("responseTooLarge", "Use a smaller history page.")
                }
                return response
            } catch {
                let failure =
                    error as? TractandaError
                    ?? TractandaError("invalidArguments", String(describing: error))
                return try JSONSerialization.data(
                    withJSONObject: [
                        "methodResponses": [
                            [
                                "error", ["type": failure.code, "description": failure.message],
                                prepared.callID,
                            ]
                        ],
                        "sessionState": store.state,
                    ], options: [.sortedKeys, .prettyPrinted])
            }
        }
    }

    /// Returns nil after any visible or authority change so the coordinator retries through
    /// the serial exact path. Response construction stays on the owner queue.
    func finishPooledQuery(_ prepared: PreparedPooledQuery, page: ItemIndex.Page, peerUID: UInt32)
        throws -> Data?
    {
        try store.withAccess(forUID: peerUID) {
            guard store.isCanonicalTrusted,
                let current = try store.pooledReadAuthority(), current == prepared.authority,
                try store.verifyPooledCategorySelection(prepared.category, authority: current)
            else { return nil }
            if let viewID = prepared.viewID,
                try store.get(viewID).revisionID != prepared.viewRevisionID
            {
                return nil
            }
            for id in page.ids where try !store.canReadCurrentItemForPooledQuery(id) {
                return nil
            }
            do {
                guard
                    let args = try JSONSerialization.jsonObject(
                        with: prepared.argumentsJSON) as? [String: Any]
                else { throw TractandaError("invalidRequest", "Pooled query arguments changed.") }
                let result: [String: Any] = [
                    "ids": page.ids, "position": prepared.position, "total": page.total,
                    "queryState": current.state, "evaluatedAt": prepared.evaluatedAtString,
                    "nextCursor": try makeInitialCursor(
                        args: args, ids: page.ids, total: page.total, position: prepared.position,
                        evaluatedAt: prepared.evaluatedAt,
                        evaluatedAtString: prepared.evaluatedAtString,
                        timeZone: prepared.timeZone, digest: prepared.queryDigest),
                    "previousCursor": NSNull(),
                ]
                let response = try JSONSerialization.data(
                    withJSONObject: [
                        "methodResponses": [["TractandaItem/query", result, prepared.callID]],
                        "sessionState": current.state,
                    ], options: [.sortedKeys, .prettyPrinted])
                guard response.count <= 8 * 1024 * 1024 else {
                    throw TractandaError("responseTooLarge", "Use smaller query pages.")
                }
                return response
            } catch {
                let failure =
                    error as? TractandaError
                    ?? TractandaError("invalidArguments", String(describing: error))
                return try JSONSerialization.data(
                    withJSONObject: [
                        "methodResponses": [
                            [
                                "error", ["type": failure.code, "description": failure.message],
                                prepared.callID,
                            ]
                        ],
                        "sessionState": store.state,
                    ], options: [.sortedKeys, .prettyPrinted])
            }
        }
    }

    /// Recognizes only one unindexed, category-free, read-only query. Every other
    /// envelope goes through the ordinary handler and retains its existing errors.
    func prepareNativeRead(_ data: Data, peerUID: UInt32) throws -> PreparedNativeRead? {
        guard data.count <= 8 * 1024 * 1024,
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(request.keys) == ["using", "methodCalls"],
            let using = request["using"] as? [String], using.contains(Self.capability),
            Set(using).isSubset(of: [Self.capability, "urn:ietf:params:jmap:core"]),
            let calls = request["methodCalls"] as? [[Any]], calls.count == 1,
            calls[0].count == 3, calls[0][0] as? String == "TractandaItem/query",
            let args = calls[0][1] as? [String: Any],
            let callID = calls[0][2] as? String, !callID.isEmpty,
            Set(args.keys).isSubset(of: ["expression", "sort", "position", "limit", "at", "timeZone"]),
            let rawSort = args["sort"],
            let sortData = try? JSONSerialization.data(withJSONObject: rawSort),
            let sort = try? JSON.decode([ItemSort].self, sortData)
        else { return nil }
        if args["expression"] != nil && !(args["expression"] is String) { return nil }
        if args["at"] != nil && !(args["at"] is String) { return nil }
        if args["timeZone"] != nil && !(args["timeZone"] is String) { return nil }
        guard let position = try? integer(args, "position", default: 0, range: 0...Int.max),
            let limit = try? integer(args, "limit", default: 100, range: 1...256)
        else { return nil }
        let date: Date
        if let instant = args["at"] as? String {
            guard let parsed = Timestamp.parse(instant) else { return nil }
            date = parsed
        } else {
            date = Date()
        }
        let timeZone = args["timeZone"] as? String ?? "UTC"
        guard (try? QueryCalendar.make(timeZone: timeZone)) != nil,
            let query = try? PreparedReadQuery(
                expression: args["expression"] as? String, sort: sort, evaluatedAt: date,
                timeZone: timeZone, position: position, limit: limit)
        else { return nil }
        // Indexed one-key time sorts are already cheaper on the serial SQL path.
        if sort.count == 1, !sort[0].isAscending,
            ["modifiedAt", "createdAt"].contains(sort[0].property.map(metadataKey) ?? "")
        {
            return nil
        }
        semantic.maintain()
        guard
            let snapshot = try store.withAccess(
                forUID: peerUID,
                {
                    try store.immutableReadSnapshot(
                        candidateRestrictions: query.expression?.indexCandidateRestrictions ?? [])
                })
        else { return nil }
        return PreparedNativeRead(query: query, snapshot: snapshot, callID: callID)
    }

    /// Returns nil only when the captured result became stale; the caller then runs the
    /// ordinary serial handler. Integrity failures are errors and never return stale data.
    func finishNativeRead(_ prepared: PreparedNativeRead, page: PreparedReadPage, peerUID: UInt32)
        throws -> Data?
    {
        try store.withAccess(forUID: peerUID) {
            do {
                guard try store.verifyImmutableReadSnapshot(prepared.snapshot) else { return nil }
                let currentState = store.state
                guard currentState == page.state else { return nil }
                let result: [String: Any] = [
                    "ids": page.ids, "position": prepared.query.position, "total": page.total,
                    "queryState": currentState, "evaluatedAt": Timestamp.format(page.evaluatedAt),
                ]
                let response = try JSONSerialization.data(
                    withJSONObject: [
                        "methodResponses": [["TractandaItem/query", result, prepared.callID]],
                        "sessionState": currentState,
                    ], options: [.sortedKeys, .prettyPrinted])
                guard response.count <= 8 * 1024 * 1024 else {
                    throw TractandaError("responseTooLarge", "Use smaller query pages.")
                }
                return response
            } catch {
                let failure =
                    error as? TractandaError
                    ?? TractandaError("invalidArguments", String(describing: error))
                return try JSONSerialization.data(
                    withJSONObject: [
                        "methodResponses": [
                            [
                                "error", ["type": failure.code, "description": failure.message],
                                prepared.callID,
                            ]
                        ],
                        "sessionState": store.state,
                    ], options: [.sortedKeys, .prettyPrinted])
            }
        }
    }

    private func handleAuthorized(_ data: Data, peerUID: UInt32) throws -> Data {
        guard data.count <= 8 * 1024 * 1024,
            let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw TractandaError("invalidRequest", "Expected a JSON object under 8 MiB.")
        }
        try check(request, allowed: ["using", "methodCalls"])
        guard let using = request["using"] as? [String], let calls = request["methodCalls"] as? [[Any]],
            calls.count <= 32
        else {
            throw TractandaError(
                "invalidRequest", "using must be a string array and methodCalls an array of at most 32 calls."
            )
        }
        let supportedCapabilities: Set<String> = [Self.capability, "urn:ietf:params:jmap:core"]
        guard using.contains(Self.capability), Set(using).isSubset(of: supportedCapabilities) else {
            throw TractandaError(
                "unsupportedCapability",
                "This local service requires capability \(Self.capability). Update the client and server to matching prototype protocol versions."
            )
        }
        var ids: Set<String> = []
        for call in calls {
            guard call.count == 3, call[0] is String, call[1] is [String: Any],
                let id = call[2] as? String, !id.isEmpty, ids.insert(id).inserted
            else {
                throw TractandaError(
                    "invalidRequest", "Calls are [method, arguments, uniqueCallID] triples.")
            }
        }
        var responses: [[Any]] = []
        var retainedResponseBytes = 0
        let responseBudget = min(
            8 * 1024 * 1024 - 16 * 1024, max(256, store.pooledRecordByteLimit))
        for call in calls {
            let method = call[0] as! String
            let id = call[2] as! String
            do {
                if !store.isCanonicalTrusted,
                    !["TractandaStore/info", "TractandaStore/rebuild"].contains(method)
                {
                    throw TractandaError(
                        "recoveryRequired",
                        "Canonical verification found an inconsistency; rebuild the store before access.")
                }
                var args = call[1] as! [String: Any]
                for key in args.keys.filter({ $0.hasPrefix("#") }).sorted() {
                    let name = String(key.dropFirst())
                    guard args[name] == nil, let reference = args[key] as? [String: String],
                        Set(reference.keys) == ["resultOf", "name", "path"],
                        let prior = responses.first(where: { $0[2] as? String == reference["resultOf"] }),
                        prior[0] as? String == reference["name"], reference["path"] == "/ids",
                        let value = (prior[1] as? [String: Any])?["ids"]
                    else {
                        throw TractandaError(
                            "invalidResultReference",
                            "v0 supports /ids references to earlier successful calls only.")
                    }
                    args.removeValue(forKey: key)
                    args[name] = value
                }
                let response: [Any] = [method, try execute(method, args, uid: peerUID), id]
                let size = try JSONSerialization.data(withJSONObject: response).count
                guard size <= responseBudget - retainedResponseBytes else {
                    throw TractandaError(
                        "responseTooLarge", "Use smaller pages or a narrower projection.")
                }
                retainedResponseBytes += size
                responses.append(response)
            } catch {
                let failure =
                    error as? TractandaError
                    ?? TractandaError("invalidArguments", String(describing: error))
                let response: [Any] = [
                    "error", ["type": failure.code, "description": failure.message], id,
                ]
                let size = try JSONSerialization.data(withJSONObject: response).count
                guard size <= responseBudget - retainedResponseBytes else {
                    throw TractandaError(
                        "responseTooLarge",
                        "The full response exceeds its byte budget; earlier commits may have succeeded.")
                }
                retainedResponseBytes += size
                responses.append(response)
            }
        }
        let result = try JSONSerialization.data(
            withJSONObject: ["methodResponses": responses, "sessionState": store.state],
            options: [.sortedKeys, .prettyPrinted])
        guard result.count <= 8 * 1024 * 1024 else {
            throw TractandaError(
                "responseTooLarge",
                "Use smaller get/history pages. Earlier successful commits remain committed; retry with the same operationID."
            )
        }
        return result
    }

    /// Read-only admission for the coordinator's asynchronous verifier drain. Invalid or
    /// unauthorized envelopes use the ordinary handler and never stop background work.
    func admittedRebuildRequest(_ data: Data, peerUID: UInt32) -> Bool {
        guard data.count <= 8 * 1024 * 1024,
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(request.keys) == ["using", "methodCalls"],
            let using = request["using"] as? [String], using.contains(Self.capability),
            Set(using).isSubset(of: [Self.capability, "urn:ietf:params:jmap:core"]),
            let calls = request["methodCalls"] as? [[Any]], calls.count <= 32
        else { return false }
        var callIDs: Set<String> = []
        var hasRebuild = false
        for call in calls {
            guard call.count == 3, let method = call[0] as? String,
                let arguments = call[1] as? [String: Any],
                let callID = call[2] as? String, !callID.isEmpty,
                callIDs.insert(callID).inserted
            else { return false }
            if method == "TractandaStore/rebuild" {
                guard arguments.isEmpty else { return false }
                hasRebuild = true
            }
        }
        guard hasRebuild else { return false }
        return (try? store.withAccess(forUID: peerUID) { store.isAdministrator }) == true
    }
}

public enum LocalTransport {
    public static func call(socket: String, request: Data, serverUser: String? = nil) throws -> Data {
        guard !request.isEmpty, request.count <= 8 * 1024 * 1024 else {
            throw TractandaError("limit", "Request must contain 1 byte to 8 MiB.")
        }
        let fd = tractanda_connect(socket)
        guard fd >= 0 else { throw TractandaError("connectionFailed", "Cannot connect to the local socket.") }
        defer { tractanda_close(fd) }
        var peer: UInt32 = 0
        let expectedUID: UInt32
        if let username = serverUser ?? ProcessInfo.processInfo.environment["TRACTANDA_SERVER_USER"] {
            expectedUID = try SystemAccountDirectory().user(named: username).uid
        } else {
            expectedUID = tractanda_uid()
        }
        guard tractanda_peer_uid(fd, &peer) == 0, peer == expectedUID else {
            throw TractandaError("forbidden", "Server identity differs from the expected OS user.")
        }
        guard request.withUnsafeBytes({ tractanda_send_frame(fd, $0.baseAddress, UInt32($0.count)) }) == 0
        else {
            throw TractandaError("transportError", "Send failed; retry mutations with the same operationID.")
        }
        return try receive(fd)
    }
    private static func receive(_ fd: Int32) throws -> Data {
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        guard tractanda_receive_frame(fd, &pointer, &count) == 0, let pointer else {
            throw TractandaError(
                "transportError",
                "Receive failed; a mutation may have committed. Retry with the same operationID.")
        }
        defer { tractanda_free(pointer) }
        return Data(bytes: pointer, count: Int(count))
    }
    public static func serve(
        _ service: ItemService, socket: String, maxRequests: Int? = nil, isManaged: Bool = false
    ) throws {
        // ItemStore already holds its exclusive writer lock before any stale endpoint is considered.
        if isManaged, tractanda_remove_stale_socket(socket) != 0 {
            throw TractandaError(
                "unsafeSocket", "Managed startup found a live or unsafe socket path; it was left intact.")
        }
        let listener = tractanda_listen_mode(socket, service.store.isMultiUser ? 0o666 : 0o600)
        guard listener >= 0 else {
            throw TractandaError(
                "listenFailed",
                "Cannot bind socket. Choose a short path; existing socket paths are never automatically removed."
            )
        }
        defer {
            tractanda_close(listener)
            try? FileManager.default.removeItem(atPath: socket)
        }
        guard tractanda_start_signals() == 0 else {
            throw TractandaError("transportError", "Cannot install shutdown handlers.")
        }
        defer { tractanda_restore_signals() }
        var count = 0
        while tractanda_stopping() == 0 && (maxRequests == nil || count < maxRequests!) {
            let fd = tractanda_accept(listener)
            if fd == -2 {
                service.maintainSemanticIndex()
                continue
            }
            guard fd >= 0 else { throw TractandaError("transportError", "Accept failed.") }
            do {
                defer { tractanda_close(fd) }
                var uid: UInt32 = 0
                guard tractanda_peer_uid(fd, &uid) == 0 else { continue }
                let request = try receive(fd)
                let response = service.handle(request, peerUID: uid)
                _ = response.withUnsafeBytes { tractanda_send_frame(fd, $0.baseAddress, UInt32($0.count)) }
            } catch {
                // One malformed/disconnected local client must not terminate the service.
                FileHandle.standardError.write(Data("\(error)\n".utf8))
            }
            count += 1
        }
    }
}
