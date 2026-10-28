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
    let requiredFeature: String?

    init(
        _ name: String, method: String, description: String, properties: [String: Value],
        required: [String] = [], readOnly: Bool = true, isPaged: Bool = false,
        idempotent: Bool? = nil, destructive: Bool = false, requiredFeature: String? = nil,
        includesOutputSchema: Bool = true
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
        self.requiredFeature = requiredFeature
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
        if isPaged && nativeMethod != "TractandaItem/query" {
            if let limit = arguments["limit"] {
                guard let count = limit.intValue, (1...64).contains(count) else {
                    throw TractandaError(
                        "invalidArguments", "MCP page limit must be an integer from 1 through 64.")
                }
            } else {
                arguments["limit"] = .int(32)
            }
        }
        if nativeMethod == "TractandaItem/state", arguments["maxBytes"] == nil {
            arguments["maxBytes"] = .int(65_536)
        }
        if nativeMethod == "TractandaItem/conflicts", arguments["limit"] == nil {
            arguments["limit"] = .int(64)
        }
        for name in ["ids", "categoryIDs"] where arguments[name] != nil {
            guard let values = arguments[name]?.arrayValue,
                !values.isEmpty
                    || ["TractandaItem/get", "TractandaItem/getBounded", "TractandaRevision/get"].contains(
                        nativeMethod),
                values.count <= 64,
                values.allSatisfy({ $0.stringValue != nil })
            else {
                throw TractandaError("invalidArguments", "\(name) must contain 1 through 64 string IDs.")
            }
        }
        if nativeMethod == "TractandaItem/extractedText" {
            if let value = arguments["projection"],
                !["source", "fts", "summary"].contains(value.stringValue ?? "")
            {
                throw TractandaError("invalidArguments", "projection must be source, fts, or summary.")
            }
            if let ids = arguments["ids"]?.arrayValue,
                Set(ids.compactMap(\.stringValue)).count != ids.count
            {
                throw TractandaError("invalidArguments", "ids must be distinct.")
            }
        }
        if nativeMethod == "TractandaItem/extractedTextUnit" {
            for key in ["unit", "offset"] where arguments[key] != nil {
                guard let value = arguments[key]?.intValue, value >= 0, value < Int.max else {
                    throw TractandaError(
                        "invalidArguments", "\(key) must be a nonnegative UTF8 unit/offset integer.")
                }
            }
            if let limit = arguments["limit"] {
                guard let value = limit.intValue, (1...262_144).contains(value) else {
                    throw TractandaError("invalidArguments", "limit must be 1 through 262144 UTF8 bytes.")
                }
            }
        }
        if nativeMethod == "TractandaItem/state" {
            if let ids = arguments["ids"]?.arrayValue {
                guard Set(ids.compactMap(\.stringValue)).count == ids.count else {
                    throw TractandaError("invalidArguments", "ids must be distinct.")
                }
                if nativeMethod == "TractandaItem/state" {
                    for id in ids { try validateUUIDv1(id.stringValue, field: "ids") }
                }
            }
        }
        if nativeMethod == "TractandaAttachment/content" {
            if let offset = arguments["offset"] {
                guard let value = offset.intValue, let checked = Int64(exactly: value), checked >= 0 else {
                    throw TractandaError(
                        "invalidArguments", "offset must be a nonnegative Int64 byte offset.")
                }
            } else {
                arguments["offset"] = .int(0)
            }
            if let limit = arguments["limit"] {
                guard let value = limit.intValue, (1...65_536).contains(value) else {
                    throw TractandaError(
                        "invalidArguments", "limit must be an integer from 1 through 65536 bytes.")
                }
            } else {
                arguments["limit"] = .int(4_096)
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
        if arguments["projection"] != nil && arguments["fieldProperties"] != nil {
            throw TractandaError("invalidArguments", "projection and fieldProperties are mutually exclusive.")
        }
        if let maxBytes = arguments["maxBytes"] {
            let allowedBytes =
                nativeMethod == "TractandaAttachment/document"
                ? (4_096...262_144) : (8_192...524_288)
            guard let count = maxBytes.intValue, allowedBytes.contains(count) else {
                throw TractandaError(
                    "invalidArguments",
                    "maxBytes must be an integer from \(allowedBytes.lowerBound) through \(allowedBytes.upperBound)."
                )
            }
        }
        if let sort = arguments["sort"] {
            guard let values = sort.arrayValue, values.count <= 4 else {
                throw TractandaError("invalidArguments", "sort must contain at most four entries.")
            }
            for value in values {
                guard let object = value.objectValue,
                    Set(object.keys).isSubset(of: ["property", "categoryRootId", "isAscending", "collation"])
                else {
                    throw TractandaError("invalidArguments", "sort contains an unknown comparator key.")
                }
            }
            _ = try JSONDecoder().decode([JMAPReadComparator].self, from: JSONEncoder().encode(sort))
        }
        if arguments["sectionID"] != nil && arguments["viewID"] == nil {
            throw TractandaError("invalidArguments", "sectionID requires viewID.")
        }
        if arguments["viewID"] != nil && arguments["sort"] != nil {
            throw TractandaError("invalidArguments", "viewID cannot be combined with inline sort.")
        }
        if nativeMethod == "TractandaDocumentJob/list", arguments["limit"] == nil {
            arguments["limit"] = .int(32)
        }
        if nativeMethod == "TractandaAttachment/document", arguments["maxBytes"] == nil {
            arguments["maxBytes"] = .int(65_536)
        }
        try validateDocumentJobArguments(arguments)
        return arguments
    }

    private func validateDocumentJobArguments(_ arguments: [String: Value]) throws {
        switch nativeMethod {
        case "TractandaAttachment/document":
            try validateUUIDv1(arguments["itemID"]?.stringValue, field: "itemID")
            try validateUUIDv1(arguments["attachmentID"]?.stringValue, field: "attachmentID")
            if let revisionID = arguments["revisionID"] {
                try validateUUIDv1(revisionID.stringValue, field: "revisionID")
            }
            guard let rawPage = arguments["pageNumber"]?.intValue,
                let pageNumber = Int64(exactly: rawPage), pageNumber > 0
            else {
                throw TractandaError("invalidArguments", "pageNumber must be a positive exact Int64.")
            }
            guard let maxBytes = arguments["maxBytes"]?.intValue, (4_096...262_144).contains(maxBytes) else {
                throw TractandaError(
                    "invalidArguments", "maxBytes must be an integer from 4096 through 262144.")
            }
        case "TractandaDocumentJob/start":
            for key in ["itemID", "expectedRevisionID", "attachmentID"] {
                try validateUUIDv1(arguments[key]?.stringValue, field: key)
            }
            guard let operationID = arguments["operationID"]?.stringValue,
                !operationID.isEmpty, operationID.utf8.count <= 200, !operationID.contains("\0")
            else {
                throw TractandaError(
                    "invalidArguments", "operationID must contain 1 through 200 UTF-8 bytes without NUL.")
            }
        case "TractandaDocumentJob/status", "TractandaDocumentJob/cancel",
            "TractandaDocumentJob/resume", "TractandaDocumentJob/discard":
            try validateUUIDv1(arguments["jobID"]?.stringValue, field: "jobID")
        case "TractandaDocumentJob/rebase":
            try validateUUIDv1(arguments["jobID"]?.stringValue, field: "jobID")
            try validateUUIDv1(arguments["expectedRevisionID"]?.stringValue, field: "expectedRevisionID")
        case "TractandaDocumentJob/page":
            try validateUUIDv1(arguments["jobID"]?.stringValue, field: "jobID")
            guard let value = arguments["pageNumber"]?.intValue,
                let pageNumber = Int64(exactly: value), pageNumber > 0
            else {
                throw TractandaError("invalidArguments", "pageNumber must be a positive exact Int64.")
            }
        case "TractandaDocumentJob/list":
            if let afterJobID = arguments["afterJobID"] {
                try validateUUIDv1(afterJobID.stringValue, field: "afterJobID")
            }
            let limit: Int
            if let supplied = arguments["limit"] {
                guard let parsed = supplied.intValue else {
                    throw TractandaError("invalidArguments", "limit must be an integer from 1 through 64.")
                }
                limit = parsed
            } else {
                limit = 32
            }
            guard (1...64).contains(limit) else {
                throw TractandaError("invalidArguments", "limit must be an integer from 1 through 64.")
            }
        case "TractandaItem/conflicts":
            let limit: Int
            if let supplied = arguments["limit"] {
                guard let value = supplied.intValue else {
                    throw TractandaError("invalidArguments", "limit must be an integer from 1 through 256.")
                }
                limit = value
            } else {
                limit = 64
            }
            if let cursor = arguments["cursor"] {
                guard let value = cursor.stringValue, !value.isEmpty, value.utf8.count <= 8_192 else {
                    throw TractandaError("invalidArguments", "cursor must contain 1 through 8192 bytes.")
                }
            }
            guard (1...256).contains(limit)
            else { throw TractandaError("invalidArguments", "Invalid conflict cursor or page limit.") }
        case "TractandaItem/resolveConflict":
            try validateUUIDv1(arguments["itemID"]?.stringValue, field: "itemID")
            guard let stateToken = arguments["expectedStateToken"]?.stringValue,
                !stateToken.isEmpty, stateToken.utf8.count <= 8_192,
                let frontier = arguments["reviewedFrontier"]?.arrayValue,
                (1...1024).contains(frontier.count), frontier.allSatisfy({ $0.stringValue != nil }),
                Set(frontier.compactMap(\.stringValue)).count == frontier.count,
                let changes = arguments["changes"]?.objectValue,
                let unset = arguments["unset"]?.arrayValue, unset.count <= 4096,
                unset.allSatisfy({
                    guard let field = $0.stringValue else { return false }
                    return !field.isEmpty && !field.contains("\0")
                }),
                Set(unset.compactMap(\.stringValue)).count == unset.count,
                Set(changes.keys).isDisjoint(with: Set(unset.compactMap(\.stringValue))),
                let operationID = arguments["operationID"]?.stringValue,
                !operationID.isEmpty, operationID.utf8.count <= 200, !operationID.contains("\0")
            else { throw TractandaError("invalidArguments", "Invalid conflict resolution fields.") }
            for id in frontier { try validateUUIDv1(id.stringValue, field: "reviewedFrontier") }
        default:
            break
        }
    }

    private func validateUUIDv1(_ value: String?, field: String) throws {
        guard let value, (try? Identifier.validate(value)) != nil,
            UUID(uuidString: value)?.version1Components != nil
        else {
            throw TractandaError("invalidArguments", "\(field) must be a canonical lowercase UUIDv1.")
        }
    }
}

enum ToolCatalog {
    private static let documentJobsFeature = "tractanda.document-jobs.v1"
    private static let text: Value = .object(["type": .string("string")])
    private static let identifier: Value = .object([
        "type": .string("string"),
        "description": .string("Canonical lowercase UUID returned by the server."),
    ])
    private static let uuidV1Identifier: Value = .object([
        "type": .string("string"),
        "description": .string("Canonical lowercase UUIDv1 returned by the server."),
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
    private static let readIdentifiers: Value = .object([
        "type": .string("array"), "items": identifier,
        "minItems": .int(0), "maxItems": .int(64),
    ])
    private static let projection: Value = .object([
        "type": .string("string"), "enum": .array(["full", "content", "summary"].map(Value.string)),
        "description": .string(
            "full is native complete output; MCP defaults to content when omitted. Mutually exclusive with fieldProperties."
        ),
    ])
    private static let propertyNames: Value = .object([
        "type": .string("array"), "items": .object(["type": .string("string"), "minLength": .int(1)]),
        "maxItems": .int(64), "uniqueItems": .bool(true),
        "description": .string(
            "Literal top-level field names; always retains available record identity fields. Mutually exclusive with projection."
        ),
    ])
    private static let dtoProperties: Value = .object([
        "type": .string("array"), "items": text,
        "description": .string(
            "DTO properties only: Item id/revisionId/formatVersion/fields/resolution; Revision id/itemId/formatVersion/fields. id is always returned. fieldProperties selects interior fields separately."
        ),
    ])
    private static let sort: Value = .object([
        "type": .string("array"), "maxItems": .int(4),
        "items": .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object([
                "property": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(256)]
                ),
                "categoryRootId": identifier, "collation": text,
                "isAscending": .object(["type": .string("boolean"), "default": .bool(true)]),
            ]),
            "required": .array([.string("property")]),
        ]),
        "description": .string(
            "Up to four distinct targets: property for owned metadata, or property=categoryMembership plus categoryRootId for effective membership ordered by that root’s immediate children. Unranked items remain last in either direction."
        ),
    ])
    private static let tagged: Value = .object([
        "type": .string("object"),
        "description": .string(
            "Native tagged value: {type, value}. Every integer value is a canonical base-10 Int64 decimal string, including small integers; real/protocol numbers remain JSON numbers. Types: text, integer, real, boolean, date (ISO 8601), bytes (base64), reference ({itemID, optional revisionID}), list (tagged values), object (key to tagged value)."
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
                destructive: definition.destructive, requiredFeature: definition.requiredFeature,
                includesOutputSchema: includesOutputSchema)
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
                "Query readable IDs using filter criteria (expression/text/categoryPath/excludedCategoryIDs/viewID/sectionID/at/timeZone), standard comparators and position or anchor. calculateTotal defaults false; request it explicitly when needed. Advance by consumed IDs and fetch content separately. Query never calculates deltas.",
            properties: [
                "filter": .object(["type": .string("object")]), "sort": sort,
                "position": .object(["type": .string("integer")]), "anchor": identifier,
                "anchorOffset": .object(["type": .string("integer")]), "cursor": text,
                "limit": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(256)]),
                "calculateTotal": .object(["type": .string("boolean"), "default": .bool(false)]),
            ], isPaged: true),
        .init(
            "tractanda_get", method: "TractandaItem/get",
            description:
                "Complete collection get for zero through 64 Item IDs. DTO id is stable ItemID; unresolved readable objects remain in list with resolution and null content. properties selects DTO keys; fieldProperties/projection selects inner fields. No continuations; oversized complete replies fail.",
            properties: [
                "ids": readIdentifiers, "projection": projection, "properties": dtoProperties,
                "fieldProperties": propertyNames,
            ], required: ["ids"]),
        .init(
            "tractanda_get_bounded", method: "TractandaItem/getBounded",
            description:
                "Explicit bounded Item get. Same DTOs as get; follow remainingIDs and handle oversizedIDs, comparing state. Unresolved readable objects are list entries with null content; never select a diagnostic head as content.",
            properties: [
                "ids": readIdentifiers, "projection": projection, "properties": dtoProperties,
                "fieldProperties": propertyNames,
                "maxBytes": .object([
                    "type": .string("integer"), "minimum": .int(8192), "maximum": .int(524288),
                ]),
            ], required: ["ids"]),
        .init(
            "tractanda_state", method: "TractandaItem/state",
            description:
                "Read current item projection status, state token, representative/frontier and bounded conflict details without requiring a current content representative. notFound remains privacy-safe. Follow remainingIDs; increase maxBytes within its bound or handle oversized/resource results explicitly. ready means a resolved current projection, not a Ready/In review workflow category or an actionable task. Requires tractanda.revision-projection.v1.",
            properties: [
                "ids": .object([
                    "type": .string("array"), "items": uuidV1Identifier,
                    "minItems": .int(1), "maxItems": .int(64), "uniqueItems": .bool(true),
                ]),
                "maxBytes": .object([
                    "type": .string("integer"), "minimum": .int(8_192), "maximum": .int(524_288),
                    "default": .int(65_536),
                ]),
            ], required: ["ids"], requiredFeature: ServerFeature.revisionProjection.rawValue),
        .init(
            "tractanda_conflicts", method: "TractandaItem/conflicts",
            description:
                "List authorized current conflicts/invariant/resource states with an opaque continuation cursor and store state token. It does not select a branch. Requires tractanda.revision-projection.v1.",
            properties: [
                "limit": .object([
                    "type": .string("integer"), "minimum": .int(1), "maximum": .int(256),
                    "default": .int(64),
                ]), "cursor": .object(["type": .string("string"), "maxLength": .int(8_192)]),
            ], requiredFeature: ServerFeature.revisionProjection.rawValue),
        .init(
            "tractanda_resolve_conflict", method: "TractandaItem/resolveConflict",
            description:
                "Explicitly resolve the complete reviewed frontier with top-level changes/unsets. The expected itemState token fences stale review. This does not edit one branch in place; it creates a separate authored resolution. Retry with the same operationID. Requires tractanda.revision-projection.v1. Success returns a compact confirmed receipt (itemId, revisionId, operationId, replayed, indexReady, diagnostics). To read saved content, use tractanda_revision with ids:[revisionId] and verify the returned itemId; a read failure does not undo the saved edit.",
            properties: [
                "itemID": uuidV1Identifier,
                "expectedStateToken": .object([
                    "type": .string("string"), "minLength": .int(1), "maxLength": .int(8_192),
                ]),
                "reviewedFrontier": .object([
                    "type": .string("array"), "items": uuidV1Identifier,
                    "minItems": .int(1), "maxItems": .int(1024), "uniqueItems": .bool(true),
                ]),
                "changes": .object(["type": .string("object"), "additionalProperties": tagged]),
                "unset": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string"), "minLength": .int(1)]),
                    "maxItems": .int(4096),
                    "uniqueItems": .bool(true),
                ]),
                "operationID": .object([
                    "type": .string("string"), "minLength": .int(1), "maxLength": .int(200),
                ]),
            ],
            required: [
                "itemID", "expectedStateToken", "reviewedFrontier", "changes", "unset", "operationID",
            ],
            readOnly: false, idempotent: true, destructive: true,
            requiredFeature: ServerFeature.revisionProjection.rawValue),
        .init(
            "tractanda_extracted_text", method: "TractandaItem/extractedText",
            description:
                "Diagnose search coverage for readable current items. Returns item/revision identity, extractionProfile, byte counts and separate FTS/semantic index freshness. source returns inlineFieldsAndRepresentations; saved v2 pages are explicitly omitted with sourceComplete false and coverage. Use tractanda_extracted_text_unit for them; fts returns the three inline extraction fields; FTS status verifies actual ordinary owned values; summary omits text. It never follows references or extracts attachments. No silent truncation: follow remainingIDs; retry oversizedIDs with summary. maxBytes covers the native result, not MCP framing. Requires tractanda.extracted-text.v1; read the served query/semantic references.",
            properties: [
                "ids": .object([
                    "type": .string("array"), "items": identifier,
                    "minItems": .int(1), "maxItems": .int(64), "uniqueItems": .bool(true),
                ]),
                "projection": .object([
                    "type": .string("string"),
                    "enum": .array(["source", "fts", "summary"].map(Value.string)),
                    "default": .string("source"),
                ]),
                "maxBytes": .object([
                    "type": .string("integer"), "minimum": .int(8_192),
                    "maximum": .int(524_288), "default": .int(65_536),
                ]),
            ], required: ["ids"]),
        .init(
            "tractanda_extracted_text_unit", method: "TractandaItem/extractedTextUnit",
            description:
                "Read one bounded current source unit, including saved v2 document pages. Requires fresh tractanda.extracted-text-units.v1. Pin expectedRevisionID from current get/diagnostics; follow next.unit/offset with the same revision. unit/offset and spans count UTF8 bytes. Canonical verification covers only the selected window, length, locator and spans; indexConsistency covers component metadata. Whole-document and global placement verification are explicitly false. No silent truncation; reduce limit on responseTooLarge. Native and serialized MCP wrapper budgets both apply.",
            properties: [
                "itemID": identifier, "expectedRevisionID": identifier,
                "unit": .object(["type": .string("integer"), "minimum": .int(0)]),
                "offset": .object(["type": .string("integer"), "minimum": .int(0), "default": .int(0)]),
                "limit": .object([
                    "type": .string("integer"), "minimum": .int(1), "maximum": .int(262_144),
                    "default": .int(65_536),
                ]),
                "maxBytes": .object([
                    "type": .string("integer"), "minimum": .int(8_192), "maximum": .int(524_288),
                    "default": .int(524_288),
                ]),
            ], required: ["itemID", "expectedRevisionID", "unit"],
            requiredFeature: ServerFeature.extractedTextUnits.rawValue),
        .init(
            "tractanda_attachments", method: "TractandaAttachment/list",
            description:
                "List immutable attachment descriptors for a readable current item or an explicitly pinned revision. Current permissions govern historical reads. Returns attachment IDs, display filename, media type, byte count and SHA-256; it never returns payload bytes. Requires native feature tractanda.attachment-lifecycle.v1.",
            properties: ["itemID": identifier, "revisionID": identifier],
            required: ["itemID"], requiredFeature: ServerFeature.attachmentLifecycle.rawValue),
        .init(
            "tractanda_attachment_content", method: "TractandaAttachment/content",
            description:
                "Read a bounded byte slice from one readable immutable attachment. Requires itemID and attachmentID; revisionID optionally pins an immutable historical revision. offset is a byte offset (not a character offset), default 0, and limit is bytes, default 4096 and maximum 65536. Follow nextOffset until isComplete; verify the joined bytes against attachment.sha256 and byteCount. Pin the list result's revisionID across continuation calls; the server still rechecks current permissions for every chunk. Data is base64 of original bytes. Never pass a path. Requires native feature tractanda.attachment-lifecycle.v1.",
            properties: [
                "itemID": identifier, "revisionID": identifier, "attachmentID": identifier,
                "offset": .object([
                    "type": .string("integer"), "minimum": .int(0), "maximum": .int(Int.max),
                    "default": .int(0), "description": .string("Byte offset into the immutable original."),
                ]),
                "limit": .object([
                    "type": .string("integer"), "minimum": .int(1), "maximum": .int(65_536),
                    "default": .int(4_096),
                    "description": .string("Maximum original bytes in this response."),
                ]),
            ], required: ["itemID", "attachmentID"],
            requiredFeature: ServerFeature.attachmentLifecycle.rawValue),
        .init(
            "tractanda_attachment_document_page", method: "TractandaAttachment/document",
            description:
                "Read one selected page from a saved canonical extraction, optionally pinned to a revision. Returns canonical item/revision/representation identity, source provenance, total page count and citation-bearing page content. pageNumber is required; this tool never reads a whole representation. maxBytes defaults to 65536 and is capped at 262144 native-result bytes; MCP also checks serialized wrapper size and returns responseTooLarge without truncation. For unusually large pages, lower maxBytes or use bounded source windows/original attachment chunks. Current permissions are rechecked for historical reads. Requires native feature tractanda.attachment-document.v1.",
            properties: [
                "itemID": uuidV1Identifier, "revisionID": uuidV1Identifier,
                "attachmentID": uuidV1Identifier,
                "pageNumber": .object([
                    "type": .string("integer"), "minimum": .int(1), "maximum": .int(Int.max),
                    "description": .string("Positive exact Int64 page ordinal."),
                ]),
                "maxBytes": .object([
                    "type": .string("integer"), "minimum": .int(4_096),
                    "maximum": .int(262_144), "default": .int(65_536),
                ]),
            ], required: ["itemID", "attachmentID", "pageNumber"],
            requiredFeature: ServerFeature.attachmentDocument.rawValue),
        .init(
            "tractanda_document_job_start", method: "TractandaDocumentJob/start",
            description:
                "Start or replay one durable extraction job for the specified original revision and attachment. Reuse the exact operationID and payload after an uncertain reply. A successful admission may be queued or paused if local conversion configuration is unavailable; native authorization and source checks remain authoritative. Requires fresh native feature tractanda.document-jobs.v1.",
            properties: [
                "itemID": uuidV1Identifier, "expectedRevisionID": uuidV1Identifier,
                "attachmentID": uuidV1Identifier, "operationID": operation,
            ], required: ["itemID", "expectedRevisionID", "attachmentID", "operationID"],
            readOnly: false, idempotent: true, requiredFeature: documentJobsFeature),
        .init(
            "tractanda_document_job_status", method: "TractandaDocumentJob/status",
            description:
                "Read the current status of a durable job owned by this actor or readable by an administrator. Page counts and processing coverage make no OCR accuracy claim. This remains available when conversion configuration is not ready. Requires fresh native feature tractanda.document-jobs.v1.",
            properties: ["jobID": uuidV1Identifier], required: ["jobID"],
            requiredFeature: documentJobsFeature),
        .init(
            "tractanda_document_job_cancel", method: "TractandaDocumentJob/cancel",
            description:
                "Request bounded cancellation of this actor's durable job. Accepted page outcomes remain recoverable. Current native authorization is checked. Requires fresh native feature tractanda.document-jobs.v1.",
            properties: ["jobID": uuidV1Identifier], required: ["jobID"],
            readOnly: false, idempotent: false, requiredFeature: documentJobsFeature),
        .init(
            "tractanda_document_job_resume", method: "TractandaDocumentJob/resume",
            description:
                "Resume a paused or cancelled durable job after the native service revalidates current authority, source identity and configuration. Requires fresh native feature tractanda.document-jobs.v1.",
            properties: ["jobID": uuidV1Identifier], required: ["jobID"],
            readOnly: false, idempotent: false, requiredFeature: documentJobsFeature),
        .init(
            "tractanda_document_job_rebase", method: "TractandaDocumentJob/rebase",
            description:
                "Deliberately change only the publication revision expectation for an unfinished job. Original source revision/provenance and accepted pages remain fixed; native authorization and current revision are rechecked. Requires fresh native feature tractanda.document-jobs.v1.",
            properties: ["jobID": uuidV1Identifier, "expectedRevisionID": uuidV1Identifier],
            required: ["jobID", "expectedRevisionID"],
            readOnly: false, idempotent: false, requiredFeature: documentJobsFeature),
        .init(
            "tractanda_document_job_page", method: "TractandaDocumentJob/page",
            description:
                "Read one bounded provisional page outcome from a durable job. It has no canonical revision identity or citation; after completion, use tractanda_attachment_document_page for saved canonical page content and its citations. This never returns the whole document. MCP checks the fully serialized wrapper against its response budget and returns responseTooLarge without truncation. Requires fresh native feature tractanda.document-jobs.v1.",
            properties: [
                "jobID": uuidV1Identifier,
                "pageNumber": .object([
                    "type": .string("integer"), "minimum": .int(1), "maximum": .int(Int.max),
                    "description": .string("Positive exact Int64 page ordinal."),
                ]),
            ], required: ["jobID", "pageNumber"], requiredFeature: documentJobsFeature),
        .init(
            "tractanda_document_job_discard", method: "TractandaDocumentJob/discard",
            description:
                "Explicitly discard only this job's staged or uncommitted work after reconciling any canonical commit receipt. Canonical committed content and immutable history are preserved. Current native authorization is checked. Requires fresh native feature tractanda.document-jobs.v1.",
            properties: ["jobID": uuidV1Identifier], required: ["jobID"],
            readOnly: false, idempotent: false, destructive: true, requiredFeature: documentJobsFeature),
        .init(
            "tractanda_document_jobs", method: "TractandaDocumentJob/list",
            description:
                "List a bounded page of this actor's discoverable durable jobs. Use nextJobID as afterJobID; limit defaults to 32 and is at most 64. This does not expose other actors' jobs unless native administrator authorization permits it. Requires fresh native feature tractanda.document-jobs.v1.",
            properties: [
                "afterJobID": uuidV1Identifier,
                "limit": .object([
                    "type": .string("integer"), "minimum": .int(1),
                    "maximum": .int(64), "default": .int(32),
                ]),
            ], requiredFeature: documentJobsFeature),
        .init(
            "tractanda_memberships", method: "TractandaCategory/memberships",
            description:
                "Read effective category branches for up to 64 items and 8 readable roots. roots describes ordered immediate children; memberships maps itemID to rootID to matching category IDs. Respects rules, inherited membership, exclusions and current ACLs. Empty means unranked; notFound covers missing or unreadable items. Check state across batches.",
            properties: [
                "ids": identifiers,
                "categoryRootIDs": .object([
                    "type": .string("array"), "items": identifier,
                    "minItems": .int(1), "maxItems": .int(8), "uniqueItems": .bool(true),
                ]),
                "at": text,
            ], required: ["ids", "categoryRootIDs"]),
        .init(
            "tractanda_history", method: "TractandaItem/history",
            description:
                "Paged immutable Revision DTOs under current item permissions. properties selects DTO keys; fieldProperties/projection selects inner fields.",
            properties: page([
                "itemID": identifier, "projection": projection, "properties": dtoProperties,
                "fieldProperties": propertyNames,
            ]), required: ["itemID"], isPaged: true),
        .init(
            "tractanda_revision", method: "TractandaRevision/get",
            description:
                "Collection get keyed by Revision IDs. Current item permissions govern every historical record. Returns accountId/state/list/notFound; id is RevisionID and itemId identifies its item.",
            properties: [
                "ids": readIdentifiers, "projection": projection, "properties": dtoProperties,
                "fieldProperties": propertyNames,
            ], required: ["ids"]),
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
                "Commit one whole edit. Create needs classID; revise/retype/copy need itemID and expectedRevisionID; retype also needs classID. changes is a dictionary of native tagged values; unset is required and removes named keys (send [] when removing nothing). All writes require operationID. Deletes/restores revise isDeleted; copies start a new private history. Preserve unknown properties. Read tractanda://reference/items first. Success returns a compact confirmed receipt (itemId, revisionId, operationId, replayed, indexReady, diagnostics). To read saved content, use tractanda_revision with ids:[revisionId] and verify the returned itemId; a read failure does not undo the saved edit.",
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
            "tractanda_capture_preview", method: "TractandaItem/prepareCapture",
            description:
                "Explicit authoring preview for #name, #[Parent/Child] or #[categoryID]. Supply a complete native CommitRequest in request. Body stays plain text. Unknown, ambiguous, excluded and conflicting dates require review. Category captureDate freezes a YYYY-MM-DD calendar date using its configured timezone; no alarm is scheduled. Return the entire unchanged plan to tractanda_capture_commit, retaining it for retries. Imports and tractanda_commit do not parse hashtags.",
            properties: ["request": .object(["type": .string("object")]), "at": text],
            required: ["request"], requiredFeature: ServerFeature.inlineCapture.rawValue),
        .init(
            "tractanda_capture_commit", method: "TractandaItem/commitCapture",
            description:
                "Commit the exact complete plan from tractanda_capture_preview after resolving all issues. Revalidates current item/category permissions, revisions and frozen interpretation, then publishes body, assignments and dates in one revision. Retry the identical plan after uncertainty; never generate a fresh operationID for the same edit. Success returns a compact confirmed receipt (itemId, revisionId, operationId, replayed, indexReady, diagnostics). To read saved content, use tractanda_revision with ids:[revisionId] and verify the returned itemId; a read failure does not undo the saved edit.",
            properties: [
                "request": .object(["type": .string("object")]), "evaluatedAt": text,
                "commitRequest": .object(["type": .string("object")]),
                "categoryRevisionIDs": .object(["type": .string("object")]),
                "mentions": .object(["type": .string("array")]),
                "issues": .object(["type": .string("array")]),
            ],
            required: [
                "request", "evaluatedAt", "commitRequest", "categoryRevisionIDs", "mentions", "issues",
            ],
            readOnly: false, idempotent: true, destructive: true,
            requiredFeature: ServerFeature.inlineCapture.rawValue),
        .init(
            "tractanda_semantic_status", method: "TractandaSemantic/status",
            description:
                "Read semantic-index availability for the current OS-bound readable scope. Missing configuration means disabled.",
            properties: [:]),
        .init(
            "tractanda_semantic_search", method: "TractandaSemantic/search",
            description:
                "Start an asynchronous semantic query; poll tractanda_semantic_results with queryID. A server declaring tractanda.semantic-job-timing.v1 in tractanda_info.features returns createdAt/expiresAt and a pending retryAfterMilliseconds hint. Pending allowance is hardware-configurable; consuming completion starts a separate 120-second result-retention window. Use the latest returned expiry. Compiled documentation alone does not prove timing support. Makes no canonical edit.",
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
                "Poll a caller-scoped queryID. With native feature tractanda.semantic-job-timing.v1, result states return createdAt/expiresAt and pending includes retryAfterMilliseconds; completion updates expiry to the bounded result-retention window, while polling never extends it. notFound errors omit timing and deliberately do not distinguish expired/unknown/foreign IDs. Start a new search. Results recheck current access.",
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
                "Record versioned feedback: accept includes; exclude forbids membership; negative trains a negative without overriding membership; dismiss hides the suggestion; clear removes only feedback, preserving manual overrides. Native item write permission, expectedRevisionID and operationID are required. This edits shared item state; private categories use PersonalStateItem instead. Success returns a compact confirmed receipt (itemId, revisionId, operationId, replayed, indexReady, diagnostics). To read saved content, use tractanda_revision with ids:[revisionId] and verify the returned itemId; a read failure does not undo the saved edit.",
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
                "Revise a category's shared learning settings with a native tagged object and revision guard. Read tractanda://reference/learning for the settings profile. Success returns a compact confirmed receipt (itemId, revisionId, operationId, replayed, indexReady, diagnostics). To read saved content, use tractanda_revision with ids:[revisionId] and verify the returned itemId; a read failure does not undo the saved edit.",
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
