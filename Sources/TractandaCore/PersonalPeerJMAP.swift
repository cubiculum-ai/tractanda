import Foundation
import TractandaClient

/// Structured peer capability over the private authenticated TLS binding. Domain intake stays
/// in the existing single-owner gateway; no OS-user registry or remote push intake is exposed.
package enum PersonalPeerJMAP {
    package static let capability = "https://tractanda.ai/ns/private-peer/1"
    package static let helloCapability = "tractanda.personal-sync.v3"
    package static let wireVersion = 4
    package static let maximumChunkBytes = 256 * 1024
    package static let maximumCalls = 16
    package static let operations: Set<String> = [
        "personal.inventory", "personal.inventory.close", "personal.dependencies", "personal.read",
        "personal.membership.ready", "personal.sync.ready",
    ]
    private static let snapshots: Set<String> = ["personal.inventory", "personal.inventory.close"]
    private static let callID = "peer"
    package enum Reply: Sendable {
        case response(Data)
        case problem(Data)
    }
    private static func method(_ operation: String) -> String {
        "TractandaPeer/" + operation.dropFirst("personal.".count)
    }
    private static func value<T: Encodable>(_ object: T) throws -> JMAPValue {
        try .decode(JSON.encode(object))
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ object: JMAPValue) throws -> T {
        try JSON.decode(type, object.encoded())
    }
    private static func decimal(_ string: String) throws -> Int64 {
        guard let number = Int64(string), number >= 0, String(number) == string else {
            throw JMAPMethodError("invalidArguments")
        }
        return number
    }
    private static func number(_ integer: Int64) throws -> JMAPValue {
        let value = try JMAPNumber(String(integer))
        _ = try value.protocolInt(unsigned: true)
        return .number(value)
    }

    /// Only these schema-defined Int64 fields use decimal strings; no arbitrary JSON rewriting.
    private struct Attachment: Codable {
        let attachmentID: String
        let filename: String
        let mediaType: String
        let byteCount: String
        let sha256: String
        init(_ item: AttachmentDescriptor) {
            attachmentID = item.attachmentID
            filename = item.filename
            mediaType = item.mediaType
            byteCount = String(item.byteCount)
            sha256 = item.sha256
        }
        func domain() throws -> AttachmentDescriptor {
            try .init(
                attachmentID: attachmentID, filename: filename, mediaType: mediaType,
                byteCount: decimal(byteCount), sha256: sha256)
        }
    }
    private struct Part: Codable {
        let role: PersonalDocumentPart.Role
        let level: Int
        let ordinal: String
        init(_ item: PersonalDocumentPart) {
            role = item.role
            level = item.level
            ordinal = String(item.ordinal)
        }
        func domain() throws -> PersonalDocumentPart {
            try .init(role: role, level: level, ordinal: decimal(ordinal))
        }
    }
    private struct Descriptor: Codable {
        let kind: PersonalObjectDescriptor.Kind
        let id: String
        let byteCount: String
        let sha256: String
        let itemID: String?
        let parentRevisionIDs: [String]
        let attachment: Attachment?
        let part: Part?
        init(_ item: PersonalObjectDescriptor) {
            kind = item.kind
            id = item.id
            byteCount = String(item.byteCount)
            sha256 = item.sha256
            itemID = item.itemID
            parentRevisionIDs = item.parentRevisionIDs
            attachment = item.attachment.map(Attachment.init)
            part = item.part.map(Part.init)
        }
        func domain() throws -> PersonalObjectDescriptor {
            try .init(
                kind: kind, id: id, byteCount: decimal(byteCount), sha256: sha256, itemID: itemID,
                parentRevisionIDs: parentRevisionIDs, attachment: attachment?.domain(), part: part?.domain())
        }
    }
    private struct Inventory: Codable {
        let snapshotID: String
        let generationID: String
        let cutRowID: String
        let entries: [Descriptor]
        let nextOffset: String?
        let complete: Bool
        init(_ page: PersonalInventoryPage) throws {
            try PersonalSyncValidation.identifier(page.snapshotID)
            guard !page.generationID.isEmpty, page.generationID.utf8.count <= 200,
                page.cutRowID >= 0, page.entries.count <= 128,
                page.nextOffset.map({ $0 >= 0 }) ?? true,
                page.entries.allSatisfy({ $0.kind == .revision }),
                try page.entries.reduce(0, { try $0 + JSON.encode($1).count }) <= 128 * 1024
            else { throw JMAPMethodError("serverFail") }
            for descriptor in page.entries { try descriptor.validate() }
            snapshotID = page.snapshotID
            generationID = page.generationID
            cutRowID = String(page.cutRowID)
            entries = page.entries.map(Descriptor.init)
            nextOffset = page.nextOffset.map(String.init)
            complete = page.complete
        }
        func domain() throws -> PersonalInventoryPage {
            .init(
                snapshotID: snapshotID, generationID: generationID, cutRowID: try decimal(cutRowID),
                entries: try entries.map { try $0.domain() },
                nextOffset: try nextOffset.map { try index($0) }, complete: complete)
        }
    }
    private struct Dependencies: Codable {
        let entries: [Descriptor]
        let nextOffset: String?
        let complete: Bool
        init(_ page: PersonalDependencyPage) {
            entries = page.entries.map(Descriptor.init)
            nextOffset = page.nextOffset.map(String.init)
            complete = page.complete
        }
        func domain() throws -> PersonalDependencyPage {
            .init(
                entries: try entries.map { try $0.domain() },
                nextOffset: try nextOffset.map { try index($0) }, complete: complete)
        }
    }
    private static func index(_ text: String) throws -> Int {
        guard let value = Int(exactly: try decimal(text)) else { throw JMAPMethodError("invalidArguments") }
        return value
    }

    package static func arguments(_ request: PeerExchangeRequest, accountID: String) throws -> JMAPValue {
        let fields = request.fields
        var result: [JMAPMember] = [.init("accountId", .string(accountID))]
        func text(_ key: String) throws -> String {
            guard case .text(let text)? = fields[key] else { throw JMAPMethodError("invalidArguments") }
            return text
        }
        func integer(_ key: String) throws -> Int64 {
            guard case .integer(let integer)? = fields[key], integer >= 0 else {
                throw JMAPMethodError("invalidArguments")
            }
            return integer
        }
        switch request.operation {
        case "personal.inventory", "personal.dependencies", "personal.read":
            result += [
                .init("offset", .string(String(try integer("offset")))),
                .init("limit", try number(integer("limit"))),
            ]
            if request.operation != "personal.inventory" {
                guard case .bytes(let data)? = fields["descriptor"] else {
                    throw JMAPMethodError("invalidArguments")
                }
                result.append(
                    .init(
                        "descriptor", try value(Descriptor(JSON.decode(PersonalObjectDescriptor.self, data))))
                )
            } else {
                for key in ["snapshotID", "knownGeneration"] where fields[key] != nil {
                    result.append(.init(key, .string(try text(key))))
                }
                if fields["afterRowID"] != nil {
                    result.append(.init("afterRowID", .string(String(try integer("afterRowID")))))
                }
            }
        case "personal.inventory.close": result.append(.init("snapshotID", .string(try text("snapshotID"))))
        case "personal.membership.ready":
            guard case .bytes(let data)? = fields["preparation"] else {
                throw JMAPMethodError("invalidArguments")
            }
            result.append(
                .init("preparation", try value(JSON.decode(PersonalMembershipPreparation.self, data))))
        case "personal.sync.ready": break
        default: throw JMAPMethodError("unknownMethod")
        }
        guard Set(result.map(\.name)).subtracting(["accountId"]) == Set(fields.keys) else {
            throw JMAPMethodError("invalidArguments")
        }
        return .object(result)
    }

    package static func internalRequest(
        _ arguments: JMAPValue, operation: String, binding: PeerExchangeBinding
    ) throws -> PeerExchangeRequest {
        guard let account = arguments["accountId"]?.text else { throw JMAPMethodError("invalidArguments") }
        guard account == binding.storeID else { throw JMAPMethodError("accountNotFound") }
        var allowed: Set<String> = ["accountId"]
        var fields: [String: ItemValue] = [:]
        func text(_ key: String) throws -> String {
            guard let text = arguments[key]?.text else { throw JMAPMethodError("invalidArguments") }
            return text
        }
        switch operation {
        case "personal.inventory", "personal.dependencies", "personal.read":
            allowed.formUnion(["offset", "limit"])
            fields["offset"] = .integer(try decimal(text("offset")))
            guard case .number(let limit)? = arguments["limit"] else {
                throw JMAPMethodError("invalidArguments")
            }
            let count = try limit.protocolInt(unsigned: true)
            guard count >= 1, count <= (operation == "personal.read" ? 262_144 : 128) else {
                throw JMAPMethodError("invalidArguments")
            }
            fields["limit"] = .integer(count)
            if operation != "personal.inventory" {
                allowed.insert("descriptor")
                guard let descriptor = arguments["descriptor"] else {
                    throw JMAPMethodError("invalidArguments")
                }
                fields["descriptor"] = .bytes(try JSON.encode(decode(Descriptor.self, descriptor).domain()))
            } else {
                allowed.formUnion(["snapshotID", "knownGeneration", "afterRowID"])
                for key in ["snapshotID", "knownGeneration"] where arguments[key] != nil {
                    fields[key] = .text(try text(key))
                }
                if arguments["afterRowID"] != nil {
                    fields["afterRowID"] = .integer(try decimal(text("afterRowID")))
                }
            }
        case "personal.inventory.close":
            allowed.insert("snapshotID")
            fields["snapshotID"] = .text(try text("snapshotID"))
        case "personal.membership.ready":
            allowed.insert("preparation")
            guard let preparation = arguments["preparation"] else {
                throw JMAPMethodError("invalidArguments")
            }
            fields["preparation"] = .bytes(
                try JSON.encode(decode(PersonalMembershipPreparation.self, preparation)))
        case "personal.sync.ready": break
        default: throw JMAPMethodError("unknownMethod")
        }
        guard let members = arguments.members, Set(members.map(\.name)).isSubset(of: allowed) else {
            throw JMAPMethodError("invalidArguments")
        }
        return .init(operation, fields)
    }

    package static func result(_ bytes: Data, operation: String) throws -> JMAPValue {
        switch operation {
        case "personal.read":
            guard bytes.count <= maximumChunkBytes else { throw JMAPMethodError("responseTooLarge") }
            return .object([.init("bytes", .string(bytes.base64EncodedString()))])
        case "personal.inventory": return try value(Inventory(JSON.decode(PersonalInventoryPage.self, bytes)))
        case "personal.dependencies":
            return try value(Dependencies(JSON.decode(PersonalDependencyPage.self, bytes)))
        case "personal.membership.ready": return try value(JSON.decode(PersonalMembershipReady.self, bytes))
        case "personal.inventory.close", "personal.sync.ready":
            let field = operation == "personal.sync.ready" ? "ready" : "closed"
            let object = try JSON.decode([String: Bool].self, bytes)
            guard let flag = object[field], object.count == 1 else { throw JMAPMethodError("serverFail") }
            return .object([.init(field, .bool(flag))])
        default: throw JMAPMethodError("unknownMethod")
        }
    }
    package static func internalResult(_ result: JMAPValue, operation: String) throws -> Data {
        switch operation {
        case "personal.read":
            guard let encoded = result["bytes"]?.text, let bytes = Data(base64Encoded: encoded),
                bytes.count <= maximumChunkBytes,
                encoded == bytes.base64EncodedString(), result.members?.count == 1
            else { throw JMAPMethodError("invalidArguments") }
            return bytes
        case "personal.inventory": return try JSON.encode(decode(Inventory.self, result).domain())
        case "personal.dependencies": return try JSON.encode(decode(Dependencies.self, result).domain())
        case "personal.membership.ready": return try JSON.encode(decode(PersonalMembershipReady.self, result))
        case "personal.inventory.close", "personal.sync.ready":
            let field = operation == "personal.sync.ready" ? "ready" : "closed"
            guard case .bool(let flag)? = result[field], result.members?.count == 1 else {
                throw JMAPMethodError("invalidArguments")
            }
            return try JSON.encode([field: flag])
        default: throw JMAPMethodError("unknownMethod")
        }
    }

    /// Core constrains inventory descriptor JSON to 128 KiB/128 entries.
    /// Same descriptor schema adds at most 6 quote bytes per entry for its three Int64 strings;
    /// compact JSON is no longer than the existing pretty encoding. Header strings are bounded.
    private static func snapshotBound(_ request: PeerExchangeRequest, name: String, callID: String) throws
        -> Int
    {
        if request.operation == "personal.inventory.close" {
            return try JMAPInvocation(
                name: name, arguments: .object([.init("closed", .bool(true))]), callID: callID
            ).value.encoded().count
        }
        let header: JMAPValue = .object([
            .init("snapshotID", .string(String(repeating: "0", count: 36))),
            .init("generationID", .string(String(repeating: "\u{1}", count: 200))),
            .init("cutRowID", .string(String(Int64.max))), .init("entries", .array([])),
            .init("nextOffset", .string(String(Int64.max))), .init("complete", .bool(false)),
        ])
        guard case .integer(let count)? = request.fields["limit"] else {
            throw JMAPMethodError("invalidArguments")
        }
        return try JMAPInvocation(name: name, arguments: header, callID: callID).value.encoded().count + 128
            * 1024 + Int(count) * 7
    }
    package static func request(
        _ request: PeerExchangeRequest, binding: PeerExchangeBinding, maximumBodyBytes: Int
    ) throws -> Data {
        guard operations.contains(request.operation) else {
            throw TractandaError(
                "unsupportedPeerOperation", "Only peer export and readiness methods are available.")
        }
        let bytes = try JMAPValue.object([
            .init("using", .array([.string(capability)])),
            .init(
                "methodCalls",
                .array([
                    JMAPInvocation(
                        name: method(request.operation),
                        arguments: arguments(request, accountID: binding.storeID), callID: callID
                    ).value
                ])),
        ]).encoded()
        guard bytes.count <= maximumBodyBytes else { throw JMAPProblem("limit", limit: "maxSizeRequest") }
        return bytes
    }
    package static func execute(
        _ data: Data, binding: PeerExchangeBinding, maximumBodyBytes: Int,
        validate: @escaping @Sendable (PeerExchangeBinding) async throws -> Void,
        perform: @escaping @Sendable (PeerExchangeBinding, PeerExchangeRequest) async throws -> Data
    ) async throws -> Reply {
        try await validate(binding)
        let limits = JMAPKernel.Limits(
            maximumRequestBytes: maximumBodyBytes, maximumCalls: maximumCalls, maximumJSONDepth: 64,
            maximumResponseBytes: maximumBodyBytes)
        do {
            let request = try JMAPRequest.decode(data, limits: limits)
            let state = try JMAPSessionState(
                PersonalSyncValidation.digest(
                    JSON.encode([
                        "capability": capability, "storeID": binding.storeID, "pairingID": binding.pairingID,
                        "membership": binding.configurationDigest,
                        "maxCallsInRequest": String(maximumCalls),
                        "maxSizeRequest": String(maximumBodyBytes),
                        "maxSizeResponse": String(maximumBodyBytes),
                        "maxChunkBytes": String(maximumChunkBytes), "maxJSONDepth": "64",
                    ])))
            var definitions: [String: JMAPMethodDefinition] = [:]
            for operation in operations {
                let name = method(operation)
                let mutates = snapshots.contains(operation)
                definitions[name] = .init(
                    capability: capability, effect: mutates ? .mayMutate : .readOnly,
                    maximumResponseBytes: maximumBodyBytes, requiresMutationAdmission: mutates
                ) { arguments, context in
                    do {
                        let internalCall: PeerExchangeRequest
                        do {
                            internalCall = try internalRequest(
                                arguments, operation: operation, binding: binding)
                        } catch let error as JMAPMethodError { throw error } catch {
                            throw JMAPMethodError("invalidArguments")
                        }
                        try await validate(binding)
                        if mutates {
                            try context.replyBudget.reserveMutationResponse(
                                maximumResponseBytes: snapshotBound(
                                    internalCall, name: name, callID: context.callID))
                            context.replyBudget.markDomainOperationBegan()
                        }
                        let bytes = try await perform(binding, internalCall)
                        try await validate(binding)
                        let structured = try result(bytes, operation: operation)
                        let tuple = JMAPInvocation(name: name, arguments: structured, callID: context.callID)
                        guard try tuple.value.encoded().count <= context.replyBudget.availableBytes else {
                            throw JMAPMethodError("responseTooLarge")
                        }
                        return .success([.init(name, structured)])
                    } catch {
                        let error =
                            error as? JMAPMethodError
                            ?? JMAPMethodError(
                                (error as? TractandaError)?.code ?? "serverFail",
                                description: (error as? TractandaError)?.message)
                        return .failure(
                            error, effects: context.replyBudget.provesNoEffects ? .none : .unknown)
                    }
                }
            }
            return .response(
                try await JMAPKernel(
                    methods: definitions, limits: limits,
                    accounts: [
                        try JMAPAccountAccess(
                            accountID: binding.storeID, capabilities: [capability], isReadOnly: false)
                    ],
                    sessionState: { state }
                ).execute(
                    request
                ).value.encoded())
        } catch let problem as JMAPProblem { return .problem(try problem.value.encoded()) }
    }
    package static func response(_ data: Data, request: PeerExchangeRequest) throws -> Data {
        let value = try JMAPValue.decode(data)
        guard value["sessionState"]?.text != nil, let responses = value["methodResponses"]?.elements,
            responses.count == 1,
            let tuple = responses[0].elements, tuple.count == 3, tuple[2].text == callID,
            let name = tuple[0].text, tuple[1].members != nil
        else { throw TractandaError("invalidPeerResponse", "Expected one correlated JMAP response.") }
        if name == "error" {
            guard let type = tuple[1]["type"]?.text else {
                throw TractandaError("invalidPeerResponse", "Missing method error type.")
            }
            throw TractandaError(type, tuple[1]["description"]?.text ?? type)
        }
        guard name == method(request.operation) else {
            throw TractandaError("invalidPeerResponse", "Peer method differs from its request.")
        }
        do { return try internalResult(tuple[1], operation: request.operation) } catch {
            throw TractandaError("invalidPeerResponse", "Peer result differs from its structured schema.")
        }
    }
    package static func isProblem(_ data: Data) -> Bool { JMAPProblem.decode(data) != nil }
    package static func problem(_ data: Data) throws -> any Error {
        guard let problem = JMAPProblem.decode(data) else {
            throw TractandaError("invalidPeerResponse", "Expected a typed JMAP request problem.")
        }
        return problem
    }
}
