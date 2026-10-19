import Foundation

/// Immutable authority testimony. This model grants no access and performs no peer enrollment.
public struct AuthorityRecord: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case enrollmentApproval
        case authoredEvidence, bootstrapPage, bootstrapIndex, bootstrap, reviewHold, reviewDecision
        case controlCommit, visibilityWitness, reconciliationWitness, originRetirement, originRetirementPage
    }
    public static let profile = "tractanda.authority.v1"
    public static let maximumBytes = 128 * 1024
    public static let maximumEntries = 256
    public static let reservedItemFields: Set<String> = [
        "authorityEvidence", "authorityRecords", "authorityDisposition", "authorityBootstrap",
    ]
    public let itemValue: ItemValue
    public let recordID: String
    public let storeID: String
    public let originReplicaID: String
    public let kind: Kind
    public let parentAuthorityIDs: [String]
    public let actorPrincipal: String
    public let createdAt: String
    public let payload: [String: ItemValue]

    public init(
        recordID: String, storeID: String, originReplicaID: String, kind: Kind,
        parentAuthorityIDs: [String] = [], actorPrincipal: String, createdAt: String,
        payload: [String: ItemValue]
    ) throws {
        var payload = payload
        if kind == .authoredEvidence && payload["sourceControl"] == nil {
            payload["sourceControl"] = .list([])
        }
        if kind == .reviewDecision {
            for key in ["sourceControl", "resolution", "controlHolds"] where payload[key] == nil {
                payload[key] = .list([])
            }
        }
        try self.init(
            value: .object([
                "profile": .text(Self.profile), "recordID": .text(recordID), "storeID": .text(storeID),
                "originReplicaID": .text(originReplicaID), "kind": .text(kind.rawValue),
                "parentAuthorityIDs": .list(parentAuthorityIDs.map(ItemValue.text)),
                "actorPrincipal": .text(actorPrincipal), "createdAt": .date(createdAt),
                "payload": .object(payload),
            ]))
    }

    public init(value: ItemValue) throws {
        let common = try Self.object(
            value,
            keys: [
                "profile", "recordID", "storeID", "originReplicaID", "kind", "parentAuthorityIDs",
                "actorPrincipal", "createdAt", "payload",
            ])
        guard common["profile"]?.string == Self.profile,
            let kind = Kind(rawValue: try Self.text(common["kind"])),
            let payload = common["payload"]?.map
        else { throw Self.invalid("Unknown authority profile/kind or payload.") }
        self.recordID = try Self.persistentID(common["recordID"])
        self.storeID = try Self.text(common["storeID"])
        try Identifier.validate(storeID)
        self.originReplicaID = try Self.persistentID(common["originReplicaID"])
        self.parentAuthorityIDs = try Self.ids(common["parentAuthorityIDs"])
        guard !parentAuthorityIDs.contains(recordID) else { throw Self.invalid("Self authority parent.") }
        self.actorPrincipal = try Self.text(common["actorPrincipal"])
        self.createdAt = try Self.date(common["createdAt"])
        self.kind = kind
        self.payload = payload
        self.itemValue = value
        try Self.validatePayload(kind, payload)
        let causal: [String]?
        switch kind {
        case .controlCommit: causal = try Self.controlBindings(payload["controls"]).map(\.recordID)
        case .enrollmentApproval:
            causal = [try AuthorityBinding(value: payload["cut"]!).recordID]
        case .originRetirement:
            causal =
                ([try AuthorityBinding(value: payload["cut"]!).recordID]
                + (try Self.controlBindings(payload["pages"] ?? .list([]))).map(\.recordID)).sorted()
        case .originRetirementPage:
            causal = try Self.controlBindings(payload["previous"]).map(\.recordID)
        case .visibilityWitness: causal = [try AuthorityBinding(value: payload["cut"]!).recordID]
        case .reconciliationWitness:
            causal = Array(
                Set(
                    try (Self.controlBindings(payload["causes"]) + Self.controlBindings(payload["exposures"]))
                        .map(\.recordID))
            ).sorted()
        case .authoredEvidence:
            let cutIDs = try Self.controlBindings(payload["sourceControl"]).map(\.recordID)
            guard Set(cutIDs).isSubset(of: parentAuthorityIDs) else {
                throw Self.invalid("Authored evidence omitted its exact source cut dependency.")
            }
            // Other authority parents are observations. Only sourceControl defines the
            // accepted PRE cut; acceptedAuthority carries separate explicit review proof.
            causal = nil
        default: causal = nil
        }
        if let causal, parentAuthorityIDs != causal {
            throw Self.invalid("Authority parent references differ from payload cuts.")
        }
        guard try JSON.encode(value).count <= Self.maximumBytes else {
            throw TractandaError("resourceLimit", "Authority record exceeds its byte window.")
        }
    }

    public static func persistentID(_ value: ItemValue?) throws -> String {
        let id = try text(value)
        try Identifier.validate(id)
        let bytes = Array(id.utf8)
        guard bytes[14] == 49, [56, 57, 97, 98].contains(bytes[19]) else {
            throw invalid("Authority persistent identity must be UUIDv1.")
        }
        return id
    }
    public static func text(_ value: ItemValue?) throws -> String {
        guard let text = value?.string, !text.isEmpty, text.utf8.count <= 256,
            !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { throw invalid("Expected bounded authority text.") }
        return text
    }
    public static func digest(_ value: ItemValue?) throws -> String {
        let text = try self.text(value)
        guard text.utf8.count == 64,
            text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw invalid("Expected lowercase SHA256.") }
        return text
    }
    public static func ids(_ value: ItemValue?, maximum: Int = maximumEntries) throws -> [String] {
        guard (1...1024).contains(maximum), let entries = value?.array, entries.count <= maximum else {
            throw invalid("Authority identity list exceeds its profile window.")
        }
        let values = try entries.map { try persistentID($0) }
        guard values == Array(Set(values)).sorted() else { throw invalid("IDs must be sorted and unique.") }
        return values
    }
    public static func list(_ value: ItemValue?) throws -> [ItemValue] {
        guard let values = value?.array, values.count <= maximumEntries else {
            throw invalid("Authority list exceeds its count window.")
        }
        return values
    }
    public static func object(_ value: ItemValue, keys: Set<String>) throws -> [String: ItemValue] {
        guard let object = value.map, Set(object.keys) == keys else {
            throw invalid("Unknown or missing authority fields.")
        }
        return object
    }
    public static func binding(_ value: ItemValue?) throws -> (
        itemID: String, revisionID: String, sha256: String
    ) {
        guard let value else { throw invalid("Missing revision binding.") }
        let fields = try object(value, keys: ["itemID", "revisionID", "sha256"])
        return (
            try persistentID(fields["itemID"]), try persistentID(fields["revisionID"]),
            try digest(fields["sha256"])
        )
    }
    private static func bindings(_ value: ItemValue?) throws {
        let ids = try list(value).map { try binding($0).revisionID }
        guard ids == Array(Set(ids)).sorted() else { throw invalid("Bindings must be sorted and unique.") }
    }
    private static func date(_ value: ItemValue?) throws -> String {
        guard let raw = value, case .date(let value) = raw,
            value.utf8.count <= 36, Timestamp.parse(value) != nil
        else {
            throw invalid("Invalid authority date.")
        }
        return value
    }
    private static func names(_ value: ItemValue?) throws -> [String] {
        let names = try list(value).map { try text($0) }
        guard names == Array(Set(names)).sorted() else { throw invalid("Names must be sorted and unique.") }
        return names
    }
    private static func fieldNames(_ value: ItemValue?) throws -> [String] {
        guard let entries = value?.array, entries.count <= 4096 else {
            throw invalid("Authored field-name count exceeds provenance profile.")
        }
        let fields = try entries.map { entry -> String in
            guard let field = entry.string, !field.isEmpty, field.utf8.count <= 1024, !field.contains("\0")
            else { throw invalid("Invalid authored field name.") }
            return field
        }
        guard fields == Array(Set(fields)).sorted() else {
            throw invalid("Field names must be sorted and unique.")
        }
        return fields
    }
    private static func controlBindings(_ value: ItemValue?) throws -> [AuthorityBinding] {
        let refs = try list(value).map(AuthorityBinding.init(value:))
        let ids = refs.map(\.recordID)
        guard ids == Array(Set(ids)).sorted() else {
            throw invalid("Control references must be sorted and unique.")
        }
        return refs
    }
    private static func validatePayload(_ kind: Kind, _ fields: [String: ItemValue]) throws {
        var keys: Set<String>
        switch kind {
        case .authoredEvidence:
            keys = [
                "target", "parents", "frontier", "itemPolicies", "admissionPolicies", "principal",
                "sourceUID", "groups", "aliases", "rights", "evaluated", "intent", "acceptedAuthority",
                "sourceControl",
            ]
        case .enrollmentApproval:
            keys = [
                "approvalProfile", "operationID", "preparationDigest", "targetReplicaID", "pairingID",
                "sourceIsInitiator", "credentialProfile", "sourcePeer", "targetPeer",
                "sourceConfiguration", "targetConfiguration", "sourceOrigins", "targetOrigins",
                "sourceCredential", "targetCredential", "bootstrap", "securityBinding",
                "cut", "administrationPolicies", "sourceAdministration", "sourceUID", "groups",
                "planID", "packageID", "manifestDigest", "boundaryDigest",
            ]
            if fields["issuerAdmission"] != nil { keys.insert("issuerAdmission") }
        case .originRetirement:
            keys =
                fields["effectiveAt"] == nil
                ? ["cut", "pages", "origins", "operationID", "administrationPolicies"]
                : [
                    "cut", "origins", "operationID", "administrationPolicies", "effectiveAt",
                    "retirementProfile",
                    "sourceAdministration", "sourceUID", "groups",
                ]
        case .originRetirementPage: keys = ["operationID", "previous", "members"]
        case .controlCommit: keys = ["controls", "localParent", "deltas", "bootstrap"]
        case .visibilityWitness: keys = ["target", "cut", "modifiedAt", "causeKey"]
        case .reconciliationWitness:
            keys = [
                "itemID", "parents", "frontier", "causes", "exposures", "baseFloor", "modifiedAt",
                "outputRevisionID", "planDigest",
            ]
        case .bootstrapPage: keys = ["manifestID", "entries"]
        case .bootstrapIndex: keys = ["manifestID", "children"]
        case .bootstrap: keys = ["pages", "initial", "administrationPolicies"]
        case .reviewHold: keys = ["target", "evidence", "revocations", "decisionFrontier", "reason"]
        case .reviewDecision:
            keys = [
                "target", "evidence", "holds", "decisionFrontier", "decision", "administrationPolicies",
                "itemPolicies", "reason",
                "sourceControl", "resolution", "controlHolds",
            ]
        }
        if [.authoredEvidence, .originRetirement].contains(kind), fields["sourceAdministration"] != nil {
            keys.insert("sourceAdministration")
        }
        if kind == .reviewDecision, fields["retirements"] != nil { keys.insert("retirements") }
        if let administration = fields["sourceAdministration"] {
            let source = try object(
                administration, keys: ["defaultAdministratorGroup", "serviceOwnerPrincipal"])
            for key in ["defaultAdministratorGroup", "serviceOwnerPrincipal"] {
                let name = try text(source[key])
                guard !name.isEmpty, name.utf8.count <= 128,
                    name.utf8.allSatisfy({
                        (65...90).contains($0) || (97...122).contains($0)
                            || (48...57).contains($0) || [45, 46, 95, 36].contains($0)
                    })
                else { throw invalid("Invalid source administration principal.") }
            }
        }
        guard Set(fields.keys) == keys else { throw invalid("Unknown or missing authority payload fields.") }
        switch kind {
        case .enrollmentApproval:
            if let issuer = fields["issuerAdmission"] {
                guard try controlBindings(issuer).count == 1 else {
                    throw invalid("Enrollment requires one exact issuer admission.")
                }
            }
            guard fields["approvalProfile"] == .text("tractanda.peer-enrollment-approval.v1"),
                fields["credentialProfile"] == .text("org.tractanda.peer-proof/1"),
                fields["sourceIsInitiator"]?.booleanValue != nil,
                let uid = fields["sourceUID"]?.integerValue, uid >= 0, uid <= Int64(UInt32.max),
                let groups = fields["groups"]?.map, groups.count <= maximumEntries
            else { throw invalid("Invalid enrollment administrator testimony.") }
            for (name, value) in groups {
                _ = try text(.text(name))
                guard let gid = value.integerValue, gid >= 0, gid <= Int64(UInt32.max) else {
                    throw invalid("Invalid enrollment group testimony.")
                }
            }
            for key in ["operationID", "targetReplicaID", "pairingID", "planID", "packageID"] {
                _ = try persistentID(fields[key])
            }
            for key in ["sourcePeer", "targetPeer"] { _ = try text(fields[key]) }
            for key in [
                "preparationDigest", "sourceConfiguration", "targetConfiguration",
                "sourceCredential", "targetCredential", "securityBinding", "manifestDigest", "boundaryDigest",
            ] {
                _ = try digest(fields[key])
            }
            _ = try AuthorityBinding(value: fields["cut"]!)
            guard try controlBindings(fields["bootstrap"]).count == 1,
                !(try list(fields["administrationPolicies"])).isEmpty,
                !(try ids(fields["sourceOrigins"])).isEmpty,
                !(try ids(fields["targetOrigins"])).isEmpty
            else { throw invalid("Enrollment requires exact bootstrap/origin/policy dependencies.") }
            try bindings(fields["administrationPolicies"])
        case .originRetirement:
            _ = try AuthorityBinding(value: fields["cut"]!)
            _ = try persistentID(fields["operationID"])
            guard !(try ids(fields["origins"])).isEmpty else { throw invalid("Explicit origins required.") }
            if let effective = fields["effectiveAt"] {
                _ = try date(effective)
                guard fields["retirementProfile"] == .text("tractanda.peer-retirement-time.v1"),
                    let uid = fields["sourceUID"]?.integerValue, uid >= 0, uid <= Int64(UInt32.max),
                    let groups = fields["groups"]?.map, groups.count <= maximumEntries
                else { throw invalid("Invalid timestamp retirement testimony.") }
                for (name, value) in groups {
                    _ = try text(.text(name))
                    guard let gid = value.integerValue, gid >= 0, gid <= Int64(UInt32.max)
                    else { throw invalid("Invalid source group testimony.") }
                }
            } else if try controlBindings(fields["pages"]).count != 1 {
                throw invalid("Historical retirement requires its complete snapshot root.")
            }
            try bindings(fields["administrationPolicies"])
        case .originRetirementPage:
            _ = try persistentID(fields["operationID"])
            guard try controlBindings(fields["previous"]).count <= 1 else {
                throw invalid("Retirement snapshot has at most one previous page.")
            }
            var members: [String] = []
            for member in try list(fields["members"]) {
                let f = try object(member, keys: ["objectID", "sha256", "kind", "eligible"])
                members.append(try persistentID(f["objectID"]))
                _ = try digest(f["sha256"])
                guard ["item", "authority"].contains(try text(f["kind"])),
                    f["eligible"]?.booleanValue != nil
                else {
                    throw invalid("Invalid retirement snapshot member.")
                }
            }
            guard members == Array(Set(members)).sorted() else {
                throw invalid("Retirement members must be sorted and unique.")
            }
        case .controlCommit:
            let controls = try controlBindings(fields["controls"])
            let local = try controlBindings(fields["localParent"])
            guard local.count <= 1, local.allSatisfy(controls.contains) else {
                throw invalid("Local control parent must belong to this cut.")
            }
            guard try list(fields["bootstrap"]).count <= 1 else {
                throw invalid("At most one bootstrap anchor.")
            }
            _ = try controlBindings(fields["bootstrap"])
            var targets: [String] = []
            for delta in try list(fields["deltas"]) {
                let f = try object(
                    delta, keys: ["target", "eligible", "actor", "policies", "causes", "evidence"])
                targets.append(try binding(f["target"]).revisionID)
                guard f["eligible"]?.booleanValue != nil else {
                    throw invalid("Expected eligibility transition.")
                }
                _ = try text(f["actor"])
                _ = try ids(f["policies"])
                _ = try controlBindings(f["causes"])
                guard try controlBindings(f["evidence"]).count <= 1 else {
                    throw invalid("At most one exact selected authored evidence binding.")
                }
            }
            guard targets == Array(Set(targets)).sorted() else {
                throw invalid("Control deltas must be sorted and unique.")
            }
        case .visibilityWitness:
            _ = try binding(fields["target"])
            _ = try AuthorityBinding(value: fields["cut"]!)
            _ = try date(fields["modifiedAt"])
            let keys = try list(fields["causeKey"])
            guard keys.count <= 1 else { throw invalid("At most one reconciliation cause key.") }
            for key in keys { _ = try digest(key) }
        case .reconciliationWitness:
            _ = try persistentID(fields["itemID"])
            _ = try persistentID(fields["outputRevisionID"])
            guard !(try ids(fields["parents"], maximum: 1024)).isEmpty,
                !(try ids(fields["frontier"], maximum: 1024)).isEmpty,
                !(try controlBindings(fields["causes"])).isEmpty
            else { throw invalid("Reconciliation needs accepted ancestry and causes.") }
            guard !(try controlBindings(fields["exposures"])).isEmpty else {
                throw invalid("Reconciliation needs a proven exposure floor.")
            }
            _ = try date(fields["baseFloor"])
            _ = try date(fields["modifiedAt"])
            _ = try digest(fields["planDigest"])
        case .authoredEvidence:
            guard try list(fields["sourceControl"]).count <= 1 else {
                throw invalid("At most one source cut.")
            }
            _ = try controlBindings(fields["sourceControl"])
            _ = try binding(fields["target"])
            _ = try ids(fields["parents"], maximum: 1024)
            _ = try ids(fields["frontier"], maximum: 1024)
            try bindings(fields["itemPolicies"])
            try bindings(fields["admissionPolicies"])
            _ = try text(fields["principal"])
            guard let uid = fields["sourceUID"]?.integerValue, uid >= 0, uid <= Int64(UInt32.max),
                let groups = fields["groups"]?.map, groups.count <= maximumEntries,
                let aliases = fields["aliases"]?.map, aliases.count <= maximumEntries,
                fields["evaluated"]?.booleanValue != nil
            else { throw invalid("Invalid attested principal inputs.") }
            for (name, number) in groups {
                _ = try text(.text(name))
                guard let id = number.integerValue, id >= 0, id <= Int64(UInt32.max) else {
                    throw invalid("Invalid GID testimony.")
                }
            }
            for (alias, name) in aliases {
                _ = try text(.text(alias))
                _ = try text(name)
            }
            let rights = try names(fields["rights"])
            guard !rights.isEmpty, Set(rights).isSubset(of: ["read", "write", "owner", "administrator"])
            else {
                throw invalid("Unknown requested right.")
            }
            guard let intent = fields["intent"] else { throw invalid("Missing normalized intent.") }
            let intentFields = try object(intent, keys: ["writtenFields", "unsetFields"])
            let writes = try fieldNames(intentFields["writtenFields"])
            let unsets = try fieldNames(intentFields["unsetFields"])
            guard Set(writes).isDisjoint(with: unsets) else { throw invalid("Overlapping intent.") }
            var accepted: [String] = []
            for value in try list(fields["acceptedAuthority"]) {
                let ref = try object(value, keys: ["recordID", "sha256"])
                accepted.append(try persistentID(ref["recordID"]))
                _ = try digest(ref["sha256"])
            }
            guard accepted == Array(Set(accepted)).sorted() else {
                throw invalid("Accepted authority must be sorted and unique.")
            }
        case .bootstrapPage:
            _ = try persistentID(fields["manifestID"])
            var entries: [String] = []
            for entry in try list(fields["entries"]) {
                let fields = try object(entry, keys: ["target", "frontier"])
                entries.append(try binding(fields["target"]).revisionID)
                guard !(try ids(fields["frontier"], maximum: 1024)).isEmpty else {
                    throw invalid("Empty bootstrap frontier.")
                }
            }
            guard entries == Array(Set(entries)).sorted() else {
                throw invalid("Bootstrap entries must be sorted and unique.")
            }
        case .bootstrapIndex:
            _ = try persistentID(fields["manifestID"])
            let children = try list(fields["children"])
            guard !children.isEmpty else { throw invalid("Empty bootstrap index.") }
            var ids: [String] = []
            for child in children {
                let ref = try object(child, keys: ["recordID", "sha256"])
                ids.append(try persistentID(ref["recordID"]))
                _ = try digest(ref["sha256"])
            }
            guard ids == Array(Set(ids)).sorted() else {
                throw invalid("Duplicate or unsorted index children.")
            }
        case .bootstrap:
            guard fields["initial"] == .boolean(true) else {
                throw invalid("Bootstrap must be an explicit initial cut.")
            }
            let pages = try list(fields["pages"])
            guard !pages.isEmpty else { throw invalid("Empty bootstrap manifest.") }
            var ids: [String] = []
            for page in pages {
                let fields = try object(page, keys: ["recordID", "sha256"])
                ids.append(try persistentID(fields["recordID"]))
                _ = try digest(fields["sha256"])
            }
            guard ids == Array(Set(ids)).sorted() else { throw invalid("Duplicate or unsorted pages.") }
            try bindings(fields["administrationPolicies"])
        case .reviewHold, .reviewDecision:
            _ = try binding(fields["target"])
            guard let evidence = fields["evidence"] else { throw invalid("Missing evidence binding.") }
            let pair = try object(evidence, keys: ["recordID", "sha256"])
            _ = try persistentID(pair["recordID"])
            _ = try digest(pair["sha256"])
            _ = try ids(fields["decisionFrontier"])
            _ = try text(fields["reason"])
            if kind == .reviewHold {
                try bindings(fields["revocations"])
                guard !(try list(fields["revocations"])).isEmpty else {
                    throw invalid("Hold needs revocation witnesses.")
                }
            } else {
                _ = try ids(fields["holds"])
                guard ["accept", "reject"].contains(try text(fields["decision"])) else {
                    throw invalid("Unknown review decision.")
                }
                try bindings(fields["administrationPolicies"])
                try bindings(fields["itemPolicies"])
                guard try controlBindings(fields["sourceControl"]).count <= 1,
                    try list(fields["resolution"]).count <= 1
                else { throw invalid("Atomic review must name at most one PRE cut and fresh resolution.") }
                for resolution in try list(fields["resolution"]) { _ = try binding(resolution) }
                _ = try controlBindings(fields["controlHolds"])
                _ = try controlBindings(fields["retirements"] ?? .list([]))
            }
        }
    }
    private static func invalid(_ message: String) -> TractandaError {
        TractandaError("invalidAuthority", message)
    }
}
