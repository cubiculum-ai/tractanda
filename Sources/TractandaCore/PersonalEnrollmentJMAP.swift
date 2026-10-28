import Foundation
import TractandaClient

/// Host-selected authentication purpose. This value is never decoded from request JSON.
package enum PersonalEnrollmentTransportPurpose: String, Sendable {
    case memberControl, invitation, continuation
}

/// Enrollment uses the common JMAP parser and executor on the explicitly private PSK binding.
/// Domain packets remain structured JSON; only the 32-byte continuation key is base64.
package enum PersonalEnrollmentJMAP {
    package static let capability = "https://tractanda.ai/ns/private-peer-enrollment/1"
    package static let helloCapability = "tractanda.personal-enrollment.v1"
    package static let maximumBodyBytes = 512 * 1024
    package static let maximumClaimBytes = 12 * 1024
    package static let maximumPrivateCredentialsBytes = 128 * 1024
    package static let maximumPrivateCredentialCount =
        2 * (PersonalEnrollmentCapacity.maximumQualifiedMembers - 1)
    /// Domain replies are bounded independently of correlation/envelope overhead.
    package static let maximumResultBytes = 384 * 1024
    private static let callID = "enrollment"
    private static let methods: [String: String] = [
        "enrollment.claim": "claim",
        "enrollment.member.inspect": "memberInspect",
        "enrollment.member.stage": "memberStage",
        "enrollment.member.commit": "memberCommit",
        "enrollment.member.complete": "memberComplete",
        "enrollment.target.stage": "targetStage",
        "enrollment.target.status": "targetStatus",
        "enrollment.target.finish": "targetFinish",
        "enrollment.job.status": "jobStatus",
    ]
    private static let readOnly: Set<String> = [
        "enrollment.member.inspect", "enrollment.target.status", "enrollment.job.status",
    ]
    package static func permits(_ operation: String, purpose: PersonalEnrollmentTransportPurpose) -> Bool {
        switch purpose {
        case .memberControl:
            return [
                "enrollment.member.inspect", "enrollment.member.stage", "enrollment.member.commit",
                "enrollment.member.complete",
            ].contains(operation)
        case .invitation: return operation == "enrollment.claim"
        case .continuation:
            return [
                "enrollment.target.stage", "enrollment.target.status", "enrollment.target.finish",
                "enrollment.job.status",
            ].contains(operation)
        }
    }
    private static func method(_ operation: String) throws -> String {
        guard let name = methods[operation] else { throw JMAPMethodError("unknownMethod") }
        return "TractandaEnrollment/" + name
    }
    /// Classification is only a surface selector on an already authenticated member connection.
    /// It never chooses an authentication purpose or grants access to a handler.
    package static func usesEnrollmentCapability(_ data: Data) -> Bool {
        guard data.count <= maximumBodyBytes,
            let value = try? JMAPValue.decode(data), let using = value["using"]?.elements
        else { return false }
        return using.contains { $0.text == capability }
    }
    private static func object(_ data: Data, maximum: Int = maximumResultBytes) throws -> JMAPValue {
        guard data.count <= maximum else { throw JMAPMethodError("invalidArguments") }
        let value = try JMAPValue.decode(data)
        guard value.members != nil else { throw JMAPMethodError("invalidArguments") }
        return value
    }
    private static func requireFields(_ value: JMAPValue, _ fields: Set<String>) throws {
        guard let members = value.members, Set(members.map(\.name)) == fields else {
            throw JMAPMethodError("invalidArguments")
        }
    }
    private static func operationID(_ value: JMAPValue) throws -> String {
        guard let text = value.text else { throw JMAPMethodError("invalidArguments") }
        do { try PersonalSyncValidation.identifier(text) } catch { throw JMAPMethodError("invalidArguments") }
        return text
    }
    private static func privateCredentialBound(_ payload: JMAPValue) throws {
        guard let credentials = payload["privateCredentials"] else { return }
        guard let values = credentials.elements, values.count <= maximumPrivateCredentialCount else {
            throw JMAPMethodError("invalidArguments")
        }
        var count = 0
        for value in values {
            guard let text = value.text, let bytes = Data(base64Encoded: text),
                bytes.base64EncodedString() == text,
                bytes.count <= maximumPrivateCredentialsBytes - count
            else {
                throw JMAPMethodError("invalidArguments")
            }
            count += bytes.count
        }
    }
    package static func arguments(_ request: PeerExchangeRequest, accountID: String) throws -> JMAPValue {
        var members: [JMAPMember] = [.init("accountId", .string(accountID))]
        let fields = request.fields
        func bytes(_ key: String) throws -> Data {
            guard case .bytes(let data)? = fields[key] else { throw JMAPMethodError("invalidArguments") }
            return data
        }
        if request.operation == "enrollment.claim" {
            guard Set(fields.keys) == ["claim"] else { throw JMAPMethodError("invalidArguments") }
            let data = try bytes("claim")
            guard data.count <= maximumClaimBytes else { throw JMAPMethodError("invalidArguments") }
            let claim = try PersonalEnrollmentClaim.decodePrivate(data)
            members += [
                .init("metadata", try object(JSON.encode(claim.metadata), maximum: maximumClaimBytes)),
                .init(
                    "continuationSecret",
                    .string(claim.continuationSecret.withBytes { Data($0).base64EncodedString() })),
            ]
        } else {
            guard methods[request.operation] != nil, case .text(let id)? = fields["operationID"] else {
                throw JMAPMethodError("invalidArguments")
            }
            members.append(.init("operationID", .string(try operationID(.string(id)))))
            var expected: Set<String> = ["operationID"]
            if ["enrollment.member.stage", "enrollment.member.commit", "enrollment.member.complete"].contains(
                request.operation)
            {
                expected.formUnion(["decision", "payload"])
                members.append(.init("decision", try object(bytes("decision"))))
            } else if request.operation == "enrollment.target.stage" {
                expected.insert("payload")
            }
            if expected.contains("payload") {
                let payload = try object(bytes("payload"))
                try privateCredentialBound(payload)
                members.append(.init("payload", payload))
            }
            guard Set(fields.keys) == expected else { throw JMAPMethodError("invalidArguments") }
        }
        return .object(members)
    }
    package static func internalRequest(
        _ arguments: JMAPValue, operation: String,
        binding: PeerExchangeBinding
    ) throws -> PeerExchangeRequest {
        guard let account = arguments["accountId"]?.text else { throw JMAPMethodError("invalidArguments") }
        guard account == binding.storeID else { throw JMAPMethodError("accountNotFound") }
        if operation == "enrollment.claim" {
            try requireFields(arguments, ["accountId", "metadata", "continuationSecret"])
            guard let metadata = arguments["metadata"],
                let encoded = arguments["continuationSecret"]?.text,
                encoded.utf8.count == 44, let secret = Data(base64Encoded: encoded), secret.count == 32,
                secret.base64EncodedString() == encoded
            else { throw JMAPMethodError("invalidArguments") }
            try requireFields(
                metadata, ["operationID", "targetReplicaID", "targetHostname", "continuationPairingID"])
            let bytes = try metadata.encoded()
            guard bytes.count <= maximumClaimBytes - 36 else { throw JMAPMethodError("invalidArguments") }
            let value = try JSON.decode(PersonalEnrollmentClaimMetadata.self, bytes)
            let claim = PersonalEnrollmentClaim(
                metadata: value,
                continuationSecret: try PersonalEnrollmentSecret(bytes: Array(secret)))
            let data = try claim.privateEncodedBytes()
            guard data.count <= maximumClaimBytes else { throw JMAPMethodError("invalidArguments") }
            return .init(operation, ["claim": .bytes(data)])
        }
        var expected: Set<String> = ["accountId", "operationID"]
        guard let id = arguments["operationID"] else { throw JMAPMethodError("invalidArguments") }
        var fields: [String: ItemValue] = ["operationID": .text(try operationID(id))]
        if ["enrollment.member.stage", "enrollment.member.commit", "enrollment.member.complete"].contains(
            operation)
        {
            expected.formUnion(["decision", "payload"])
            guard let decision = arguments["decision"], decision.members != nil else {
                throw JMAPMethodError("invalidArguments")
            }
            fields["decision"] = .bytes(try decision.encoded())
        } else if operation == "enrollment.target.stage" {
            expected.insert("payload")
        }
        if expected.contains("payload") {
            guard let payload = arguments["payload"], payload.members != nil else {
                throw JMAPMethodError("invalidArguments")
            }
            try privateCredentialBound(payload)
            fields["payload"] = .bytes(try payload.encoded())
        }
        try requireFields(arguments, expected)
        return .init(operation, fields)
    }
    package static func request(
        _ request: PeerExchangeRequest, binding: PeerExchangeBinding,
        purpose: PersonalEnrollmentTransportPurpose, maximumBodyBytes: Int = maximumBodyBytes
    ) throws -> Data {
        guard permits(request.operation, purpose: purpose) else { throw JMAPMethodError("unknownMethod") }
        let data = try JMAPValue.object([
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
        guard data.count <= min(maximumBodyBytes, Self.maximumBodyBytes) else {
            throw JMAPProblem("limit", limit: "maxSizeRequest")
        }
        return data
    }
    package static func execute(
        _ data: Data, binding: PeerExchangeBinding,
        purpose: PersonalEnrollmentTransportPurpose, maximumBodyBytes: Int = maximumBodyBytes,
        validate:
            @escaping @Sendable (PeerExchangeBinding, PersonalEnrollmentTransportPurpose) async throws -> Void,
        perform: (
            @Sendable (PeerExchangeBinding, PersonalEnrollmentTransportPurpose, PeerExchangeRequest)
                async throws -> Data
        )?
    ) async throws -> PersonalPeerJMAP.Reply {
        try await validate(binding, purpose)
        let bound = min(maximumBodyBytes, Self.maximumBodyBytes)
        let limits = JMAPKernel.Limits(
            maximumRequestBytes: bound, maximumCalls: 1,
            maximumJSONDepth: 64, maximumResponseBytes: bound)
        do {
            let request = try JMAPRequest.decode(data, limits: limits)
            let supported: Set<String> = perform == nil ? [JMAPKernel.core] : [JMAPKernel.core, capability]
            guard request.using.allSatisfy({ supported.contains($0) }) else {
                throw JMAPProblem("unknownCapability")
            }
            let state = try JMAPSessionState(
                PersonalSyncValidation.digest(
                    JSON.encode([
                        "capability": capability, "storeID": binding.storeID, "pairingID": binding.pairingID,
                        "membership": binding.configurationDigest, "purpose": purpose.rawValue,
                        "maxSizeRequest": String(bound), "maxCallsInRequest": "1",
                    ])))
            let permitted = Set(
                try methods.keys.filter { permits($0, purpose: purpose) }.map { try method($0) })
            // Purpose admission precedes execution, including the common kernel's built-ins.
            // Declaring Core is fine; executing Core/echo on an enrollment-only binding is not.
            if let forbidden = request.methodCalls.first(where: { !permitted.contains($0.name) }) {
                let reply = try JMAPValue.object([
                    .init("sessionState", .string(state.value)),
                    .init(
                        "methodResponses",
                        .array([
                            JMAPInvocation(
                                name: "error",
                                arguments: .object([.init("type", .string("unknownMethod"))]),
                                callID: forbidden.callID
                            ).value
                        ])),
                ]).encoded()
                guard reply.count <= bound else {
                    throw JMAPProblem("limit", limit: "tractanda.maxResponseBytes")
                }
                return .response(reply)
            }
            var definitions: [String: JMAPMethodDefinition] = [:]
            if let perform {
                for operation in methods.keys where permits(operation, purpose: purpose) {
                    let name = try method(operation)
                    let mutates = !readOnly.contains(operation)
                    definitions[name] = .init(
                        capability: capability,
                        effect: mutates ? .mayMutate : .readOnly, maximumResponseBytes: bound,
                        requiresMutationAdmission: mutates
                    ) { arguments, context in
                        do {
                            let request: PeerExchangeRequest
                            do {
                                request = try internalRequest(
                                    arguments, operation: operation, binding: binding)
                            } catch let error as JMAPMethodError { throw error } catch {
                                throw JMAPMethodError("invalidArguments")
                            }
                            try await validate(binding, purpose)
                            if mutates {
                                let empty = try JMAPInvocation(
                                    name: name, arguments: .object([]), callID: context.callID
                                ).value.encoded().count
                                try context.replyBudget.reserveMutationResponse(
                                    maximumResponseBytes: maximumResultBytes + empty)
                                context.replyBudget.markDomainOperationBegan()
                            }
                            let bytes = try await perform(binding, purpose, request)
                            // Claim consumes its invitation. The committed reply belongs to that
                            // accepted operation; every later request freshly validates the key.
                            if !mutates { try await validate(binding, purpose) }
                            let result = try object(bytes)
                            guard
                                try JMAPInvocation(name: name, arguments: result, callID: context.callID)
                                    .value.encoded().count <= context.replyBudget.availableBytes
                            else {
                                throw JMAPMethodError("responseTooLarge")
                            }
                            return .success([.init(name, result)])
                        } catch {
                            return .failure(
                                sanitized(error),
                                effects: context.replyBudget.provesNoEffects ? .none : .unknown)
                        }
                    }
                }
            }
            let result = try await JMAPKernel(
                methods: definitions, limits: limits,
                accounts: [
                    try .init(accountID: binding.storeID, capabilities: [capability], isReadOnly: false)
                ],
                sessionState: { state }
            ).execute(request).value.encoded()
            return .response(result)
        } catch let problem as JMAPProblem { return .problem(try problem.value.encoded()) }
    }
    private static func sanitized(_ error: any Error) -> JMAPMethodError {
        let code = (error as? JMAPMethodError)?.type ?? (error as? TractandaError)?.code ?? "serverFail"
        let allowed: Set<String> = [
            "invalidArguments", "accountNotFound", "unknownMethod", "responseTooLarge",
            "invalidEnrollmentInput", "enrollmentConflict", "untrustedPeer", "serviceBusy", "cancelled",
            "permissionDenied", "forbidden", "invalidMembership", "unsupportedPeerOperation", "serverFail",
            "serverPartialFail",
            "enrollmentCapacityUnsupported", "enrollmentTopologyUnsupported", "configurationDrift",
            "baselineNotReady", "invitationExpired", "membersOffline", "membershipConflict", "resourceLimit",
            "enrollmentPersistenceUncertain", "principalMappingChanged", "invalidEnrollmentTarget",
        ]
        return JMAPMethodError(allowed.contains(code) ? code : "serverFail")
    }
    package static func response(_ data: Data, request: PeerExchangeRequest) throws -> Data {
        guard data.count <= maximumBodyBytes else {
            throw TractandaError("invalidPeerResponse", "Enrollment reply exceeds its bound.")
        }
        let value = try JMAPValue.decode(data)
        guard value["sessionState"]?.text != nil, let responses = value["methodResponses"]?.elements,
            responses.count == 1, let tuple = responses[0].elements, tuple.count == 3,
            tuple[2].text == callID, let name = tuple[0].text, tuple[1].members != nil
        else {
            throw TractandaError("invalidPeerResponse", "Expected one correlated enrollment response.")
        }
        if name == "error" {
            guard let type = tuple[1]["type"]?.text else {
                throw TractandaError("invalidPeerResponse", "Missing enrollment error type.")
            }
            // Error text is not transported into ordinary diagnostics.
            let error = sanitized(JMAPMethodError(type))
            throw TractandaError(error.type, error.type)
        }
        guard name == (try method(request.operation)) else {
            throw TractandaError("invalidPeerResponse", "Enrollment method differs from request.")
        }
        let result = try tuple[1].encoded()
        guard result.count <= maximumResultBytes else {
            throw TractandaError("invalidPeerResponse", "Enrollment result exceeds its bound.")
        }
        return result
    }
}
