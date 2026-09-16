import Foundation
import MCP
import TractandaCore

struct ToolDefinition: Sendable {
    let tool: Tool
    let nativeMethod: String
    let description: String
    let properties: [String: Value]
    let required: Set<String>
    let allowed: Set<String>
    let readOnly: Bool
    let isPaged: Bool
    let idempotent: Bool
    let destructive: Bool

    init(
        _ name: String, method: String, description: String, properties: [String: Value],
        required: [String] = [], readOnly: Bool = true, isPaged: Bool = false,
        idempotent: Bool? = nil, destructive: Bool = false, includesOutputSchema: Bool = true
    ) {
        nativeMethod = method
        self.description = description
        self.properties = properties
        self.required = Set(required)
        allowed = Set(properties.keys)
        self.readOnly = readOnly
        self.isPaged = isPaged
        self.idempotent = idempotent ?? readOnly
        self.destructive = destructive
        tool = Tool(
            name: name, description: description,
            inputSchema: .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.sorted().map(Value.string)), "additionalProperties": .bool(false),
            ]),
            annotations: .init(
                readOnlyHint: readOnly, destructiveHint: destructive,
                idempotentHint: self.idempotent, openWorldHint: false),
            outputSchema: includesOutputSchema ? .object(["type": .string("object")]) : nil)
    }

    func arguments(from input: [String: Value]) throws -> [String: Value] {
        let supplied = Set(input.keys)
        let unknown = supplied.subtracting(allowed).sorted()
        let missing = required.subtracting(supplied).sorted()
        guard unknown.isEmpty, missing.isEmpty else {
            var problems: [String] = []
            if !unknown.isEmpty {
                problems.append("Unknown argument keys: \(unknown.joined(separator: ", ")).")
            }
            if !missing.isEmpty {
                problems.append("Missing required argument keys: \(missing.joined(separator: ", ")).")
            }
            if nativeMethod == "TractandaItem/get", !supplied.isDisjoint(with: ["itemID", "itemIDs"]) {
                problems.append(
                    "tractanda_get is a batch operation: use ids: [\"item UUID\"]. Single-item tools use itemID."
                )
            }
            throw TractandaError("invalidArguments", problems.joined(separator: " "))
        }
        var arguments = input
        if isPaged {
            if let limit = arguments["limit"] {
                guard let count = limit.intValue, (1...64).contains(count) else {
                    throw TractandaError(
                        "invalidArguments", "MCP page limit must be an integer from 1 through 64.")
                }
            } else {
                arguments["limit"] = .int(32)
            }
        }
        for name in ["ids", "categoryIDs"] where arguments[name] != nil {
            guard let values = arguments[name]?.arrayValue, !values.isEmpty, values.count <= 64,
                values.allSatisfy({ $0.stringValue != nil })
            else {
                throw TractandaError("invalidArguments", "\(name) must contain 1 through 64 string IDs.")
            }
        }
        for key in ["categoryPath", "excludedCategoryIDs"] {
            if let path = arguments[key] {
                guard let values = path.arrayValue, values.count <= 32,
                    values.allSatisfy({ $0.stringValue != nil })
                else {
                    throw TractandaError(
                        "invalidArguments", "\(key) must contain at most 32 string IDs.")
                }
            }
        }
        if let properties = arguments["properties"] {
            guard let names = properties.arrayValue, names.count <= 64,
                Set(names.compactMap(\.stringValue)).count == names.count,
                names.allSatisfy({
                    $0.stringValue?.isEmpty == false && $0.stringValue?.contains("\0") == false
                })
            else {
                throw TractandaError(
                    "invalidArguments", "properties must contain up to 64 distinct, nonempty field names.")
            }
        }
        if arguments["projection"] != nil && arguments["properties"] != nil {
            throw TractandaError("invalidArguments", "projection and properties are mutually exclusive.")
        }
        if let maxBytes = arguments["maxBytes"] {
            guard let count = maxBytes.intValue, (8_192...524_288).contains(count) else {
                throw TractandaError(
                    "invalidArguments", "maxBytes must be an integer from 8192 through 524288.")
            }
        }
        if let sort = arguments["sort"] {
            guard let values = sort.arrayValue, values.count <= 4 else {
                throw TractandaError("invalidArguments", "sort must contain at most four entries.")
            }
            var names = Set<String>()
            for value in values {
                guard let object = value.objectValue,
                    Set(object.keys).isSubset(of: ["property", "isAscending"]),
                    let property = object["property"]?.stringValue, !property.isEmpty,
                    property.utf8.count <= 256, !property.contains("\0"),
                    object["isAscending"] == nil || object["isAscending"]?.boolValue != nil,
                    names.insert(property).inserted
                else {
                    throw TractandaError(
                        "invalidArguments", "sort must contain distinct property/isAscending entries.")
                }
            }
        }
        if arguments["sectionID"] != nil && arguments["viewID"] == nil {
            throw TractandaError("invalidArguments", "sectionID requires viewID.")
        }
        if arguments["viewID"] != nil && arguments["sort"] != nil {
            throw TractandaError("invalidArguments", "viewID cannot be combined with inline sort.")
        }
        return arguments
    }
}

enum ToolCatalog {
    private static let text: Value = .object(["type": .string("string")])
    private static let identifier: Value = .object([
        "type": .string("string"),
        "description": .string("Canonical lowercase UUID returned by the server."),
    ])
    private static let operation: Value = .object([
        "type": .string("string"),
        "description": .string(
            "Nonempty text, at most 200 UTF-8 bytes, with no NUL characters; it need not be a UUID. Scoped to the store and authenticated actor. Persist it with the exact payload and reuse both after an uncertain outcome."
        ),
    ])
    private static let identifiers: Value = .object([
        "type": .string("array"), "items": identifier,
        "minItems": .int(1), "maxItems": .int(64),
    ])
    private static let projection: Value = .object([
        "type": .string("string"), "enum": .array(["full", "content", "summary"].map(Value.string)),
        "description": .string("full is native complete output; MCP defaults to content when omitted."),
    ])
    private static let propertyNames: Value = .object([
        "type": .string("array"), "items": .object(["type": .string("string"), "minLength": .int(1)]),
        "maxItems": .int(64), "uniqueItems": .bool(true),
        "description": .string(
            "Literal top-level field names; always retains available record identity fields."),
    ])
    private static let sort: Value = .object([
        "type": .string("array"), "maxItems": .int(4),
        "items": .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object([
                "property": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(256)]
                ),
                "isAscending": .object(["type": .string("boolean"), "default": .bool(true)]),
            ]), "required": .array([.string("property")]),
        ]),
        "description": .string("Up to four distinct direct metadata properties, each with isAscending."),
    ])
    private static let tagged: Value = .object([
        "type": .string("object"),
        "description": .string(
            "Native tagged value: {type, value}. Types: text, integer, real, boolean, date (ISO 8601), bytes (base64), reference ({itemID, optional revisionID}), list (tagged values), object (key to tagged value)."
        ),
        "properties": .object([
            "type": .object([
                "type": .string("string"),
                "enum": .array(
                    ["text", "integer", "real", "boolean", "date", "bytes", "reference", "list", "object"]
                        .map(Value.string)),
            ]),
            "value": .object([:]),
        ]), "required": .array([.string("type"), .string("value")]),
        "additionalProperties": .bool(false),
    ])
    private static let paging: [String: Value] = [
        "position": .object(["type": .string("integer"), "minimum": .int(0)]),
        "limit": .object([
            "type": .string("integer"), "minimum": .int(1), "maximum": .int(64), "default": .int(32),
        ]),
    ]
    private static func page(_ properties: [String: Value]) -> [String: Value] {
        properties.merging(paging, uniquingKeysWith: { _, new in new })
    }

    static func definitions(includesOutputSchema: Bool = true) -> [ToolDefinition] {
        definitions.map { definition in
            ToolDefinition(
                definition.tool.name, method: definition.nativeMethod,
                description: definition.description, properties: definition.properties,
                required: definition.required.sorted(), readOnly: definition.readOnly,
                isPaged: definition.isPaged, idempotent: definition.idempotent,
                destructive: definition.destructive, includesOutputSchema: includesOutputSchema)
        }
    }

    private static let definitions: [ToolDefinition] = [
        .init(
            "tractanda_info", method: "TractandaStore/info",
            description:
                "Read connection diagnostics, native features, referenceCompatibility, build identity, access scope and state. Missing feature declarations mean unverified server support, not a proven defect. Stdio errors retain local diagnostics without cached server facts. Authority comes from Unix peer credentials or the authenticated HTTP session.",
            properties: [:]),
        .init(
            "tractanda_describe", method: "TractandaStore/describe",
            description:
                "Start here for the bounded native overview and registered type/common-property catalog. Read tractanda://reference/intro for agent orientation.",
            properties: [
                "topic": .object([
                    "type": .string("string"),
                    "enum": .array(["overview", "types", "properties"].map(Value.string)),
                    "default": .string("overview"),
                ])
            ]),
        .init(
            "tractanda_query", method: "TractandaItem/query",
            description:
                "Find readable item IDs with the portable Spotlight expression, literal FTS text and cumulative categoryPath, or a saved viewID. A viewID cannot be combined with inline criteria. Get contents separately. Read tractanda://reference/query for the supported grammar.",
            properties: page([
                "expression": text, "text": text, "at": text, "timeZone": text,
                "categoryPath": .object(["type": .string("array"), "items": identifier, "maxItems": .int(32)]
                ),
                "excludedCategoryIDs": .object([
                    "type": .string("array"), "items": identifier, "maxItems": .int(32),
                ]), "viewID": identifier, "sectionID": identifier, "sort": sort,
            ]), isPaged: true),
        .init(
            "tractanda_get", method: "TractandaItem/get",
            description:
                "Batch-fetch current revisions with ids (an array, even for one item); do not use itemID or itemIDs. Accepts up to 64 IDs. notFound are unreadable/missing IDs; remainingIDs are unprocessed IDs to fetch next with the same projection; compare state between pages. oversizedIDs require a narrower projection. Item count and maxBytes are independent; fields are not silently truncated.",
            properties: [
                "ids": identifiers, "projection": projection, "properties": propertyNames,
                "maxBytes": .object([
                    "type": .string("integer"), "minimum": .int(8_192), "maximum": .int(524_288),
                    "default": .int(524_288),
                ]),
            ], required: ["ids"]),
        .init(
            "tractanda_history", method: "TractandaItem/history",
            description: "Read immutable revisions newest first, under the item's current permissions.",
            properties: page(["itemID": identifier, "projection": projection, "properties": propertyNames]),
            required: ["itemID"], isPaged: true),
        .init(
            "tractanda_revision", method: "TractandaRevision/get",
            description:
                "Read one revision belonging to an item. Current item permissions also govern old revisions.",
            properties: [
                "itemID": identifier, "revisionID": identifier, "projection": projection,
                "properties": propertyNames,
            ], required: ["itemID", "revisionID"]),
        .init(
            "tractanda_resolve", method: "TractandaItem/resolve",
            description:
                "Resolve an owned field or reference path. Supply path or literal segments, optionally pin a revision/effective time. A vacant role, absent field, and accessDenied are different outcomes; holder fields never override role fields.",
            properties: [
                "itemID": identifier, "revisionID": identifier, "path": text,
                "segments": .object(["type": .string("array"), "items": text]), "at": text,
            ], required: ["itemID"]),
        .init(
            "tractanda_explain", method: "TractandaItem/explain",
            description:
                "Explain effective category membership, including private and shared overrides. Optional inheritancePath is an ordered list of category IDs from the requested category through the matching descendant; sourceReason gives its terminal reason. Output returns one readable witness path, not all graph paths. No new input flag is required.",
            properties: ["itemID": identifier, "categoryID": identifier],
            required: ["itemID", "categoryID"]),
        .init(
            "tractanda_commit", method: "TractandaItem/commit",
            description:
                "Commit one whole edit. Create needs classID; revise/retype/copy need itemID and expectedRevisionID; retype also needs classID. changes is a dictionary of native tagged values; unset is required and removes named keys (send [] when removing nothing). All writes require operationID. Deletes/restores revise isDeleted; copies start a new private history. Preserve unknown properties. Read tractanda://reference/items first.",
            properties: [
                "action": .object([
                    "type": .string("string"),
                    "enum": .array(["create", "revise", "retype", "copy"].map(Value.string)),
                ]),
                "itemID": identifier, "expectedRevisionID": identifier, "classID": text,
                "operationID": operation,
                "changes": .object(["type": .string("object"), "additionalProperties": tagged]),
                "unset": .object(["type": .string("array"), "items": text]),
            ],
            required: ["action", "operationID", "changes", "unset"], readOnly: false,
            idempotent: true, destructive: true),
        .init(
            "tractanda_semantic_status", method: "TractandaSemantic/status",
            description:
                "Read semantic-index availability for the current OS-bound readable scope. Missing configuration means disabled.",
            properties: [:]),
        .init(
            "tractanda_semantic_search", method: "TractandaSemantic/search",
            description:
                "Start an asynchronous semantic query; poll tractanda_semantic_results with queryID. A server declaring tractanda.semantic-job-timing.v1 in tractanda_info.features returns createdAt/expiresAt (120 seconds) and a pending retryAfterMilliseconds hint. Retain that expiry. Compiled documentation alone does not prove timing support. Makes no canonical edit.",
            properties: [
                "text": text, "expression": text, "viewID": identifier,
                "categoryPath": .object(["type": .string("array"), "items": identifier, "maxItems": .int(32)]
                ),
                "excludedCategoryIDs": .object([
                    "type": .string("array"), "items": identifier, "maxItems": .int(32),
                ]),
                "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(64)]),
                "at": text, "timeZone": text,
            ], required: ["text"], readOnly: false, idempotent: false),
        .init(
            "tractanda_semantic_results", method: "TractandaSemantic/results",
            description:
                "Poll a caller-scoped queryID. With native feature tractanda.semantic-job-timing.v1, result states retain createdAt/expiresAt and pending includes retryAfterMilliseconds; polling never extends expiry. notFound errors omit timing and deliberately do not distinguish expired/unknown/foreign IDs. Start a new search. Results recheck current access.",
            properties: ["queryID": identifier], required: ["queryID"]),
        .init(
            "tractanda_semantic_configure", method: "TractandaSemantic/configure",
            description:
                "Owner-only versioned local semantic runtime/model configuration. endpoint must be numeric loopback HTTP; endpoint routing is not part of profile identity.",
            properties: [
                "expectedConfigurationID": identifier,
                "configuration": .object(["type": .string("object")]),
            ], required: ["configuration"], readOnly: false, idempotent: false),
        .init(
            "tractanda_semantic_rebuild", method: "TractandaSemantic/rebuild",
            description:
                "Owner-only guarded reconstruction of the disposable semantic index; canonical content and history remain unchanged.",
            properties: ["expectedConfigurationID": identifier, "operationID": operation],
            required: ["expectedConfigurationID", "operationID"], readOnly: false, idempotent: true),
        .init(
            "tractanda_semantic_reset", method: "TractandaSemantic/reset",
            description:
                "Owner-only guarded deletion of derived semantic files followed by reconstruction. Canonical content and history remain unchanged.",
            properties: ["expectedConfigurationID": identifier, "operationID": operation],
            required: ["expectedConfigurationID", "operationID"], readOnly: false, idempotent: true,
            destructive: true),
        .init(
            "tractanda_learning_status", method: "TractandaLearning/status",
            description: "Read this OS user's category training readiness and example counts.",
            properties: ["categoryID": identifier], required: ["categoryID"]),
        .init(
            "tractanda_learning_train", method: "TractandaLearning/train",
            description:
                "Train a derived model from this user's readable assignments, exclusions and feedback. Does not assign items or change permissions.",
            properties: ["categoryID": identifier], required: ["categoryID"], readOnly: false,
            idempotent: false),
        .init(
            "tractanda_learning_suggest", method: "TractandaLearning/suggest",
            description:
                "Suggest readable items for a category without assigning them. Optional expression narrows candidates; ifInState guards pagination. Confidence scores are experimental.",
            properties: page(["categoryID": identifier, "expression": text, "ifInState": text]),
            required: ["categoryID"], isPaged: true),
        .init(
            "tractanda_learning_categories", method: "TractandaLearning/categories",
            description:
                "Suggest readable categories for an item, optionally restricted to categoryIDs. ifInState guards pagination; no assignment is made.",
            properties: page(["itemID": identifier, "categoryIDs": identifiers, "ifInState": text]),
            required: ["itemID"], isPaged: true),
        .init(
            "tractanda_learning_feedback", method: "TractandaLearning/feedback",
            description:
                "Record versioned feedback: accept includes; exclude forbids membership; negative trains a negative without overriding membership; dismiss hides the suggestion; clear removes only feedback, preserving manual overrides. Native item write permission, expectedRevisionID and operationID are required. This edits shared item state; private categories use PersonalStateItem instead.",
            properties: [
                "itemID": identifier, "categoryID": identifier, "expectedRevisionID": identifier,
                "operationID": operation,
                "action": .object([
                    "type": .string("string"),
                    "enum": .array(["accept", "exclude", "negative", "dismiss", "clear"].map(Value.string)),
                ]), "modelID": identifier,
            ],
            required: ["itemID", "categoryID", "expectedRevisionID", "operationID", "action"],
            readOnly: false, idempotent: true, destructive: true),
        .init(
            "tractanda_learning_settings", method: "TractandaLearning/settings",
            description:
                "Revise a category's shared learning settings with a native tagged object and revision guard. Read tractanda://reference/learning for the settings profile.",
            properties: [
                "categoryID": identifier, "expectedRevisionID": identifier, "operationID": operation,
                "settings": tagged,
            ],
            required: ["categoryID", "expectedRevisionID", "operationID", "settings"], readOnly: false,
            idempotent: true, destructive: true),
        .init(
            "tractanda_learning_reset", method: "TractandaLearning/reset",
            description:
                "Discard only this user's derived category model. Canonical assignments, exclusions, feedback and history remain intact; train again to rebuild.",
            properties: ["categoryID": identifier], required: ["categoryID"], readOnly: false,
            idempotent: false, destructive: true),
    ]
}
