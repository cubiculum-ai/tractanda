import CTractandaPlatform
import Foundation
import TractandaClient

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
                    "Every record is a universal item; item types form an inheritance hierarchy.",
                    "Categories are overlapping dimensions, not item types; All items is implicit.",
                    "To-do and waiting states are category assignments on ordinary items such as NoteItem.",
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
            var list: [Revision] = []
            var notFound: [String] = []
            for id in ids {
                do { list.append(try store.get(id)) } catch let error as TractandaError
                    where error.code == "notFound" || error.code == "forbidden"
                { notFound.append(id) }
            }
            return [
                "list": try list.map { try projectedRevision($0, projection: projection) },
                "notFound": notFound, "state": store.state,
            ]
        case "TractandaItem/query":
            try check(
                args,
                allowed: [
                    "expression", "text", "categoryPath", "excludedCategoryIDs", "position", "limit",
                    "viewID", "sort", "sectionID",
                    "at", "timeZone",
                ])
            for key in ["expression", "text"] where args[key] != nil && !(args[key] is String) {
                throw TractandaError("invalidArguments", "\(key) must be text.")
            }
            let position = try integer(args, "position", default: 0, range: 0...Int.max)
            let limit = try integer(args, "limit", default: 100, range: 1...256)
            let evaluatedAt =
                try args["at"].map { _ -> Date in
                    guard let date = Timestamp.parse(try string(args, "at")) else {
                        throw TractandaError("invalidArguments", "Invalid query timestamp.")
                    }
                    return date
                } ?? Date()
            let timeZone = try args["timeZone"].map { _ in try string(args, "timeZone") } ?? "UTC"
            let result: [Revision]
            if args["viewID"] != nil {
                guard args["expression"] == nil, args["text"] == nil, args["categoryPath"] == nil,
                    args["sort"] == nil, args["excludedCategoryIDs"] == nil
                else {
                    throw TractandaError("invalidArguments", "Use either viewID or inline query criteria.")
                }
                result = try Categories.savedView(
                    store: store, id: string(args, "viewID"),
                    sectionID: args["sectionID"].map { _ in try string(args, "sectionID") }, at: evaluatedAt,
                    timeZone: timeZone)
            } else {
                guard args["sectionID"] == nil else {
                    throw TractandaError("invalidArguments", "sectionID requires a saved viewID.")
                }
                let sort = try args["sort"].map { try decode([ItemSort].self, $0) } ?? []
                try ItemSort.validate(sort)
                result = try Categories.query(
                    store: store, expression: args["expression"] as? String,
                    text: args["text"] as? String, categoryPath: strings(args, "categoryPath", default: []),
                    excludedCategoryIDs: strings(args, "excludedCategoryIDs", default: []),
                    sort: sort, at: evaluatedAt, timeZone: timeZone)
            }
            let ids = Array(result.dropFirst(position).prefix(limit).map(\.itemID))
            return [
                "ids": ids, "position": position, "total": result.count, "queryState": store.state,
                "evaluatedAt": Timestamp.format(evaluatedAt),
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
            let versions = try store.history(string(args, "itemID"))
            let position = try integer(args, "position", default: 0, range: 0...Int.max)
            let limit = try integer(args, "limit", default: 100, range: 1...256)
            return [
                "list": try Array(versions.dropFirst(position).prefix(limit)).map {
                    try projectedRevision($0, projection: retrievalProjection(args))
                },
                "total": versions.count,
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
                ],
                "server": try JSONSerialization.jsonObject(with: JSON.encode(RuntimeIdentity.current)),
                "state": store.state, "ownerUID": store.ownerUID, "queryProfile": SpotlightQuery.profile,
                "binding": "local experimental; not JMAP conformant", "capability": Self.capability,
                "warnings": store.isAdministrator ? store.recoveryWarnings : [],
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

    private func handleAuthorized(_ data: Data, peerUID: UInt32) throws -> Data {
        guard data.count <= 8 * 1024 * 1024,
            let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw TractandaError("invalidRequest", "Expected a JSON object under 8 MiB.")
        }
        try check(request, allowed: ["using", "methodCalls"])
        guard let using = request["using"] as? [String], using.contains(Self.capability),
            Set(using).isSubset(of: [Self.capability, "urn:ietf:params:jmap:core"]),
            let calls = request["methodCalls"] as? [[Any]], calls.count <= 32
        else {
            throw TractandaError(
                "invalidRequest", "Declare the local capability and supply at most 32 method calls.")
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
        for call in calls {
            let method = call[0] as! String
            let id = call[2] as! String
            do {
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
                responses.append([method, try execute(method, args, uid: peerUID), id])
            } catch {
                let failure =
                    error as? TractandaError
                    ?? TractandaError("invalidArguments", String(describing: error))
                responses.append(["error", ["type": failure.code, "description": failure.message], id])
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
