import Foundation

public struct JMAPProblem: Error, Equatable, Sendable {
    public let type: String
    public let status: Int
    public let limit: String?
    public init(_ code: String, status: Int = 400, limit: String? = nil) {
        type = "urn:ietf:params:jmap:error:" + code
        self.status = status
        self.limit = limit
    }
    /// Response binding metadata only; the original problem body is retained by forwarding adapters.
    public static func decode(_ data: Data) -> Self? {
        guard let root = try? JMAPValue.decode(data), let type = root["type"]?.text,
            type.hasPrefix("urn:ietf:params:jmap:error:"), case .number(let number)? = root["status"],
            let status = try? number.protocolInt(unsigned: true), (400...599).contains(status)
        else { return nil }
        return .init(
            String(type.dropFirst("urn:ietf:params:jmap:error:".count)), status: Int(status),
            limit: root["limit"]?.text)
    }
    public var value: JMAPValue {
        var members: [JMAPMember] = [
            .init("type", .string(type)), .init("status", .number(try! JMAPNumber(String(status)))),
        ]
        if let limit { members.append(.init("limit", .string(limit))) }
        return .object(members)
    }
}

public struct JMAPMethodError: Error, Equatable, Sendable {
    public let type: String
    public let description: String?
    public let details: [JMAPMember]
    public init(_ type: String, description: String? = nil, details: [JMAPMember] = []) {
        self.type = type
        self.description = description
        self.details = details.filter { $0.name != "type" && $0.name != "description" }
    }
    var value: JMAPValue {
        var members: [JMAPMember] = [.init("type", .string(type))]
        if let description { members.append(.init("description", .string(description))) }
        members.append(contentsOf: details)
        return .object(members)
    }
}

public struct JMAPInvocation: Equatable, Sendable {
    public let name: String
    public let arguments: JMAPValue
    public let callID: String
    public init(name: String, arguments: JMAPValue, callID: String) {
        self.name = name
        self.arguments = arguments
        self.callID = callID
    }
    public var value: JMAPValue { .array([.string(name), arguments, .string(callID)]) }
}

public struct JMAPRequest: Sendable {
    public let using: [String]
    public let methodCalls: [JMAPInvocation]
    public let createdIDs: [String: String]?
    public let sourceByteCount: Int
    public let sourceMaximumDepth: Int

    public static func decode(_ data: Data, limits: JMAPKernel.Limits = .init()) throws -> Self {
        guard data.count <= limits.maximumRequestBytes else {
            throw JMAPProblem("limit", limit: "maxSizeRequest")
        }
        let object: JMAPValue
        do { object = try JMAPValue.decode(data, maximumDepth: limits.maximumJSONDepth) } catch JMAPJSONError
            .tooDeep
        { throw JMAPProblem("limit", limit: "tractanda.maxJSONDepth") } catch { throw JMAPProblem("notJSON") }
        guard object.members != nil, let usingValues = object["using"]?.elements,
            let callValues = object["methodCalls"]?.elements
        else { throw JMAPProblem("notRequest") }
        let using = try usingValues.map { value in
            guard let text = value.text else { throw JMAPProblem("notRequest") }
            return text
        }
        guard callValues.count <= limits.maximumCalls else {
            throw JMAPProblem("limit", limit: "maxCallsInRequest")
        }
        let calls = try callValues.map { value in
            guard let tuple = value.elements, tuple.count == 3, let name = tuple[0].text,
                tuple[1].members != nil, let callID = tuple[2].text
            else { throw JMAPProblem("notRequest") }
            return JMAPInvocation(name: name, arguments: tuple[1], callID: callID)
        }
        var created: [String: String]?
        if let supplied = object["createdIds"] {
            guard let members = supplied.members else { throw JMAPProblem("notRequest") }
            created = [:]
            for member in members {
                guard validID(member.name), let id = member.value.text, validID(id) else {
                    throw JMAPProblem("notRequest")
                }
                created?[member.name] = id
            }
        }
        func depth(_ value: JMAPValue) -> Int {
            switch value {
            case .array(let children): return children.map { depth($0) + 1 }.max() ?? 0
            case .object(let members): return members.map { depth($0.value) + 1 }.max() ?? 0
            default: return 0
            }
        }
        return Self(
            using: using, methodCalls: calls, createdIDs: created,
            sourceByteCount: data.count, sourceMaximumDepth: depth(object))
    }
    public static func validID(_ value: String) -> Bool {
        (1...255).contains(value.utf8.count)
            && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                    || $0 == 95
            }
    }
}

public enum JMAPResultReference {
    public static func resolve(arguments: JMAPValue, previous: [JMAPInvocation]) throws -> JMAPValue {
        guard let members = arguments.members else { throw JMAPMethodError("invalidArguments") }
        var resolved: [JMAPMember] = []
        for member in members {
            guard member.name.utf8.first == 35 else {
                resolved.append(member)
                continue
            }
            let target = String(decoding: member.name.utf8.dropFirst(), as: UTF8.self)
            guard arguments[target] == nil else { throw JMAPMethodError("invalidArguments") }
            guard let reference = member.value.members, reference.count == 3,
                let resultOf = member.value["resultOf"]?.text,
                let name = member.value["name"]?.text, let path = member.value["path"]?.text,
                let response = previous.first(where: { $0.callID.utf8.elementsEqual(resultOf.utf8) }),
                response.name.utf8.elementsEqual(name.utf8)
            else { throw JMAPMethodError("invalidResultReference") }
            resolved.append(.init(target, try pointer(path, in: response.arguments)))
        }
        return .object(resolved)
    }

    public static func pointer(_ path: String, in value: JMAPValue) throws -> JMAPValue {
        guard path.isEmpty || path.utf8.first == 47 else { throw JMAPMethodError("invalidResultReference") }
        let tokens: [String] =
            try path.isEmpty
            ? []
            : path.utf8.dropFirst().split(separator: 47, omittingEmptySubsequences: false).map { token in
                var output: [UInt8] = []
                var iterator = token.makeIterator()
                while let byte = iterator.next() {
                    if byte == 126 {
                        guard let escaped = iterator.next(), escaped == 48 || escaped == 49 else {
                            throw JMAPMethodError("invalidResultReference")
                        }
                        output.append(escaped == 48 ? 126 : 47)
                    } else {
                        output.append(byte)
                    }
                }
                return String(decoding: output, as: UTF8.self)
            }
        guard tokens.count <= 256 else { throw JMAPMethodError("invalidResultReference") }
        func evaluate(_ current: JMAPValue, offset: Int) throws -> JMAPValue {
            guard offset < tokens.count else { return current }
            let token = tokens[offset]
            if let members = current.members,
                let next = members.first(where: { $0.name.utf8.elementsEqual(token.utf8) })?.value
            {
                return try evaluate(next, offset: offset + 1)
            }
            if let values = current.elements {
                if token == "*" {
                    var results: [JMAPValue] = []
                    for value in values {
                        let result = try evaluate(value, offset: offset + 1)
                        if case .array(let children) = result {
                            results.append(contentsOf: children)
                        } else {
                            results.append(result)
                        }
                    }
                    return .array(results)
                }
                guard !token.isEmpty, token == "0" || token.first != "0",
                    token.utf8.allSatisfy({ (48...57).contains($0) }), let index = Int(token),
                    values.indices.contains(index)
                else { throw JMAPMethodError("invalidResultReference") }
                return try evaluate(values[index], offset: offset + 1)
            }
            throw JMAPMethodError("invalidResultReference")
        }
        return try evaluate(value, offset: 0)
    }
}

public struct JMAPMethodResponse: Sendable {
    public let name: String
    public let arguments: JMAPValue
    public init(_ name: String, _ arguments: JMAPValue) {
        self.name = name
        self.arguments = arguments
    }
}
public enum JMAPEffects: Sendable { case none, changed, unknown }
public enum JMAPMethodOutcome: Sendable {
    case success([JMAPMethodResponse], createdIDs: [String: String] = [:])
    /// A mutating handler must explicitly report whether it changed visible state.
    case failure(JMAPMethodError, effects: JMAPEffects)
}
public struct JMAPMethodContext: Sendable {
    public let createdIDs: [String: String]
    public let callID: String
    public let callCount: Int
    public let accountID: String?
    public let replyBudget: JMAPReplyBudget
}

/// A handler reserves its truthful success bound while holding its existing mutation/CAS admission.
/// The reservation is ephemeral protocol state and must never enter canonical request identity.
public final class JMAPReplyBudget: @unchecked Sendable {
    public let availableBytes: Int
    private let lock = NSLock()
    private var admitted: (response: Int, createdIDs: Int)?
    private var publicationAttempted = false
    private let isMutation: Bool
    private var domainOperationBegan = false
    private var completePublicationObservation = false
    fileprivate init(availableBytes: Int, isMutation: Bool = false) {
        self.availableBytes = availableBytes
        self.isMutation = isMutation
    }
    public func reserveMutationResponse(maximumResponseBytes: Int, maximumCreatedIDBytes: Int = 0) throws {
        guard maximumResponseBytes >= 0, maximumCreatedIDBytes >= 0,
            maximumResponseBytes <= availableBytes,
            maximumCreatedIDBytes <= availableBytes - maximumResponseBytes
        else {
            throw JMAPMethodError("responseTooLarge")
        }
        lock.withLock { admitted = (maximumResponseBytes, maximumCreatedIDBytes) }
    }
    fileprivate var reservation: (response: Int, createdIDs: Int)? { lock.withLock { admitted } }
    /// Domain code calls this immediately before its first potentially durable publication.
    public func markPublicationAttempt() { lock.withLock { publicationAttempted = true } }
    public var effectsPossible: Bool { lock.withLock { publicationAttempted } }
    public var hasMutationAdmission: Bool { lock.withLock { admitted != nil } }
    public func markDomainOperationBegan() { lock.withLock { domainOperationBegan = true } }
    /// Opt in only when every visible write in this method is covered by publication observation.
    public func useCompletePublicationObservation() {
        lock.withLock { completePublicationObservation = true }
    }
    public var provesNoEffects: Bool {
        lock.withLock {
            !publicationAttempted && (!isMutation || !domainOperationBegan || completePublicationObservation)
        }
    }
}
public struct JMAPSessionState: Sendable {
    public static let maximumEncodedBytes = 1024
    public let value: String
    public init(_ value: String) throws {
        guard try JMAPValue.string(value).encoded().count <= Self.maximumEncodedBytes else {
            throw JMAPMethodError("serverFail")
        }
        self.value = value
    }
}

/// Captured account availability only; this value grants no caller identity or domain permission.
public struct JMAPAccountAccess: Sendable {
    public let accountID: String
    public let capabilities: Set<String>
    public let isReadOnly: Bool
    public init(accountID: String, capabilities: Set<String>, isReadOnly: Bool) throws {
        guard JMAPRequest.validID(accountID) else { throw JMAPMethodError("invalidArguments") }
        self.accountID = accountID
        self.capabilities = capabilities
        self.isReadOnly = isReadOnly
    }
}

public struct JMAPMethodDefinition: Sendable {
    public enum Effect: Sendable { case readOnly, mayMutate }
    public enum Scope: Sendable { case session, account }
    public let capability: String
    public let effect: Effect
    public let scope: Scope
    public let requiresWritableAccount: Bool
    /// Upper bound on encoded response tuples, including names and call IDs; reserve before dispatch.
    public let maximumResponseBytes: Int
    public let maximumCreatedIDBytes: Int
    public let requiresMutationAdmission: Bool
    public let handle: @Sendable (JMAPValue, JMAPMethodContext) async throws -> JMAPMethodOutcome
    public init(
        capability: String, effect: Effect, scope: Scope = .account, requiresWritableAccount: Bool = false,
        maximumResponseBytes: Int,
        maximumCreatedIDBytes: Int = 0, requiresMutationAdmission: Bool = false,
        handle: @escaping @Sendable (JMAPValue, JMAPMethodContext) async throws -> JMAPMethodOutcome
    ) {
        self.capability = capability
        self.effect = effect
        self.scope = scope
        self.requiresWritableAccount = requiresWritableAccount
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumCreatedIDBytes = maximumCreatedIDBytes
        self.requiresMutationAdmission = requiresMutationAdmission
        self.handle = handle
    }
}

/// Staged replacement boundary. Binding authentication and domain authorization remain outside this kernel.
public struct JMAPKernel: Sendable {
    public static let core = "urn:ietf:params:jmap:core"
    public struct Limits: Sendable {
        public var maximumRequestBytes: Int
        public var maximumCalls: Int
        public var maximumJSONDepth: Int
        public var maximumResponseBytes: Int
        public init(
            maximumRequestBytes: Int = 8 * 1024 * 1024, maximumCalls: Int = 32,
            maximumJSONDepth: Int = 64, maximumResponseBytes: Int = 8 * 1024 * 1024
        ) {
            self.maximumRequestBytes = maximumRequestBytes
            self.maximumCalls = maximumCalls
            self.maximumJSONDepth = maximumJSONDepth
            self.maximumResponseBytes = maximumResponseBytes
        }
    }
    public let limits: Limits
    private let methods: [String: JMAPMethodDefinition]
    private let accounts: [JMAPAccountAccess]
    private let sessionState: @Sendable () async -> JMAPSessionState
    public init(
        methods: [String: JMAPMethodDefinition] = [:], limits: Limits = .init(),
        accounts: [JMAPAccountAccess] = [],
        sessionState: @escaping @Sendable () async -> JMAPSessionState
    ) {
        self.methods = methods.filter { $0.key != "Core/echo" }
        self.limits = limits
        self.accounts = accounts
        self.sessionState = sessionState
    }
    public struct Response: Sendable {
        public let methodResponses: [JMAPInvocation]
        public let createdIDs: [String: String]?
        public let sessionState: String
        public var value: JMAPValue {
            var members: [JMAPMember] = [
                .init("methodResponses", .array(methodResponses.map(\.value))),
                .init("sessionState", .string(sessionState)),
            ]
            if let createdIDs {
                members.append(
                    .init(
                        "createdIds",
                        .object(createdIDs.keys.sorted().map { .init($0, .string(createdIDs[$0]!)) })))
            }
            return .object(members)
        }
    }
    /// Decode once; bindings may retain this immutable request before constructing their registry.
    public func begin(_ data: Data) throws -> Execution {
        try begin(JMAPRequest.decode(data, limits: limits))
    }
    public func begin(_ request: JMAPRequest) throws -> Execution {
        try Execution(request: request, methods: methods, limits: limits, accounts: accounts)
    }

    /// The asynchronous driver suspends only in the domain handler or Session provider.
    public func execute(_ data: Data) async throws -> Response {
        try await execute(JMAPRequest.decode(data, limits: limits))
    }
    public func execute(_ request: JMAPRequest) async throws -> Response {
        var execution = try begin(request)
        let metadata = await sessionState()
        while let call = try execution.next() {
            do {
                try execution.accept(await call.definition.handle(call.invocation.arguments, call.context))
            } catch { try execution.acceptThrown(error) }
        }
        return try execution.finish(sessionState: metadata)
    }

    /// No Tasks, semaphore waits or Store-queue blocking. Uses the identical execution transitions.
    public func executeSynchronously(
        _ data: Data, sessionState: () -> JMAPSessionState,
        handle: (JMAPInvocation, JMAPMethodContext) throws -> JMAPMethodOutcome
    ) throws -> Response {
        try executeSynchronously(
            JMAPRequest.decode(data, limits: limits), sessionState: sessionState, handle: handle)
    }
    public func executeSynchronously(
        _ request: JMAPRequest, sessionState: () -> JMAPSessionState,
        handle: (JMAPInvocation, JMAPMethodContext) throws -> JMAPMethodOutcome
    ) throws -> Response {
        var execution = try begin(request)
        let metadata = sessionState()
        while let call = try execution.next() {
            do { try execution.accept(handle(call.invocation, call.context)) } catch {
                try execution.acceptThrown(error)
            }
        }
        return try execution.finish(sessionState: metadata)
    }

    public enum ExecutionError: Error, Equatable { case awaitingOutcome, noPendingCall, incomplete }
    public struct PendingCall: Sendable {
        public let invocation: JMAPInvocation
        public let context: JMAPMethodContext
        public let definition: JMAPMethodDefinition
    }

    /// Shared protocol state machine. Drivers only execute a yielded handler and submit its outcome.
    public struct Execution: Sendable {
        private let request: JMAPRequest
        private let methods: [String: JMAPMethodDefinition]
        private let accounts: [JMAPAccountAccess]
        private let opted: Set<String>
        private let reservations: [Int]
        private var slack: Int
        private var pendingBudget: JMAPReplyBudget?
        private var created: [String: String]
        private var responses: [JMAPInvocation] = []
        private var index = 0
        private var pending: JMAPInvocation?
        private var pendingDefinition: JMAPMethodDefinition?

        fileprivate init(
            request: JMAPRequest, methods: [String: JMAPMethodDefinition], limits: Limits,
            accounts: [JMAPAccountAccess]
        ) throws {
            guard request.sourceByteCount <= limits.maximumRequestBytes else {
                throw JMAPProblem("limit", limit: "maxSizeRequest")
            }
            guard request.methodCalls.count <= limits.maximumCalls else {
                throw JMAPProblem("limit", limit: "maxCallsInRequest")
            }
            guard request.sourceMaximumDepth <= limits.maximumJSONDepth else {
                throw JMAPProblem("limit", limit: "tractanda.maxJSONDepth")
            }
            let capabilities = Set(methods.values.map(\.capability)).union([JMAPKernel.core])
            guard request.using.allSatisfy({ capabilities.contains($0) }) else {
                throw JMAPProblem("unknownCapability")
            }
            self.request = request
            self.methods = methods
            self.accounts = accounts
            let opted = Set(request.using)
            self.opted = opted
            created = request.createdIDs ?? [:]
            var reservations: [Int] = []
            var reserved = try Response(methodResponses: [], createdIDs: request.createdIDs, sessionState: "")
                .value.encoded().count
            reserved += JMAPSessionState.maximumEncodedBytes
            func responseLimit() -> JMAPProblem { JMAPProblem("limit", limit: "tractanda.maxResponseBytes") }
            for call in request.methodCalls {
                let fallback = JMAPInvocation(
                    name: "error", arguments: JMAPMethodError("serverPartialFail").value, callID: call.callID)
                let errorBytes = try fallback.value.encoded().count + 64
                let bytes = errorBytes
                guard reserved <= limits.maximumResponseBytes,
                    bytes <= limits.maximumResponseBytes - reserved
                else { throw responseLimit() }
                reserved += bytes + 1
                reservations.append(bytes)
            }
            guard reserved <= limits.maximumResponseBytes else { throw responseLimit() }
            self.reservations = reservations
            slack = limits.maximumResponseBytes - reserved
        }

        /// Core/echo and protocol failures advance internally; only authorized custom methods yield.
        public mutating func next() throws -> PendingCall? {
            guard pending == nil else { throw ExecutionError.awaitingOutcome }
            while index < request.methodCalls.count {
                let call = request.methodCalls[index]
                let definition = methods[call.name]
                pending = call
                pendingDefinition = definition
                let budget = JMAPReplyBudget(
                    availableBytes: reservations[index] + slack, isMutation: definition?.effect == .mayMutate)
                pendingBudget = budget
                do {
                    guard
                        (call.name == "Core/echo" && opted.contains(JMAPKernel.core))
                            || (call.name != "Core/echo"
                                && definition.map({ opted.contains($0.capability) }) == true)
                    else { throw JMAPMethodError("unknownMethod") }
                    let arguments = try JMAPResultReference.resolve(
                        arguments: call.arguments, previous: responses)
                    if call.name == "Core/echo" {
                        try accept(.success([.init(call.name, arguments)]))
                        continue
                    }
                    let accountID: String?
                    if definition!.scope == .account {
                        guard let supplied = arguments["accountId"]?.text, JMAPRequest.validID(supplied)
                        else {
                            throw JMAPMethodError("invalidArguments", description: "accountId is required.")
                        }
                        guard let account = accounts.first(where: { $0.accountID == supplied }) else {
                            throw JMAPMethodError("accountNotFound")
                        }
                        guard
                            definition!.capability == JMAPKernel.core
                                || account.capabilities.contains(definition!.capability)
                        else {
                            throw JMAPMethodError("accountNotSupportedByMethod")
                        }
                        if definition!.requiresWritableAccount && account.isReadOnly {
                            throw JMAPMethodError("accountReadOnly")
                        }
                        accountID = supplied
                    } else {
                        accountID = nil
                    }
                    if definition!.effect == .mayMutate && !definition!.requiresMutationAdmission {
                        try budget.reserveMutationResponse(
                            maximumResponseBytes: definition!.maximumResponseBytes,
                            maximumCreatedIDBytes: definition!.maximumCreatedIDBytes)
                    }
                    let resolved = JMAPInvocation(name: call.name, arguments: arguments, callID: call.callID)
                    return PendingCall(
                        invocation: resolved,
                        context: .init(
                            createdIDs: created, callID: call.callID, callCount: request.methodCalls.count,
                            accountID: accountID, replyBudget: budget),
                        definition: definition!)
                } catch let error as JMAPMethodError { try accept(.failure(error, effects: .none)) }
            }
            return nil
        }
        public mutating func acceptThrown(_ error: any Error) throws {
            guard pending != nil else { throw ExecutionError.noPendingCall }
            let mayMutate = pendingDefinition?.effect == .mayMutate
            try accept(
                .failure(
                    .init(mayMutate ? "serverPartialFail" : "serverFail"),
                    effects: mayMutate ? .unknown : .none))
        }
        public mutating func accept(_ outcome: JMAPMethodOutcome) throws {
            guard let call = pending, let budget = pendingBudget else { throw ExecutionError.noPendingCall }
            let definition = pendingDefinition
            var emitted: [JMAPInvocation]
            var additions: [String: String] = [:]
            var addedMapBytes = 0
            var mayHaveChanged = definition?.effect == .mayMutate
            var allowedBytes = min(
                budget.availableBytes,
                max(reservations[index], definition?.maximumResponseBytes ?? budget.availableBytes))
            switch outcome {
            case .failure(let error, let effects):
                let safeError: JMAPMethodError
                switch effects {
                case .none:
                    safeError = error
                    mayHaveChanged = false
                    if definition?.requiresMutationAdmission == true { allowedBytes = budget.availableBytes }
                case .changed, .unknown: safeError = .init("serverPartialFail")
                }
                emitted = [.init(name: "error", arguments: safeError.value, callID: call.callID)]
            case .success(let results, let newIDs):
                addedMapBytes =
                    newIDs.isEmpty
                    ? 0
                    : (try? JMAPValue.object(
                        newIDs.keys.sorted().map {
                            .init($0, .string(newIDs[$0]!))
                        }
                    ).encoded().count) ?? Int.max
                let reservation = budget.reservation
                let creationLimit = reservation?.createdIDs ?? (definition?.maximumCreatedIDBytes ?? 0)
                let valid =
                    !results.isEmpty && results.allSatisfy { $0.arguments.members != nil }
                    && newIDs.allSatisfy { JMAPRequest.validID($0.key) && JMAPRequest.validID($0.value) }
                    && addedMapBytes <= creationLimit && addedMapBytes <= budget.availableBytes
                    && (!mayHaveChanged || reservation != nil)
                if valid {
                    if let reservation {
                        allowedBytes = min(budget.availableBytes - addedMapBytes, reservation.response)
                    }
                    emitted = results.map {
                        .init(name: $0.name, arguments: $0.arguments, callID: call.callID)
                    }
                    additions = newIDs
                } else {
                    emitted = [
                        .init(
                            name: "error",
                            arguments: JMAPMethodError(
                                mayHaveChanged ? "serverPartialFail" : "serverFail"
                            ).value, callID: call.callID)
                    ]
                    addedMapBytes = 0
                }
            }
            func byteCount(_ values: [JMAPInvocation]) -> Int? {
                (try? JMAPValue.array(values.map(\.value)).encoded().count).map { max(0, $0 - 2) }
            }
            let actual = byteCount(emitted)
            if actual == nil || actual! > allowedBytes || actual! > budget.availableBytes - addedMapBytes {
                emitted = [
                    .init(
                        name: "error",
                        arguments: JMAPMethodError(
                            mayHaveChanged ? "serverPartialFail" : "serverFail"
                        ).value, callID: call.callID)
                ]
                additions = [:]
                addedMapBytes = 0
            }
            let used = byteCount(emitted)! + addedMapBytes
            slack += reservations[index] - used
            for (key, value) in additions { created[key] = value }
            responses.append(contentsOf: emitted)
            pending = nil
            pendingDefinition = nil
            pendingBudget = nil
            index += 1
        }
        public func finish(sessionState: JMAPSessionState) throws -> Response {
            guard index == request.methodCalls.count, pending == nil else { throw ExecutionError.incomplete }
            return Response(
                methodResponses: responses, createdIDs: request.createdIDs == nil ? nil : created,
                sessionState: sessionState.value)
        }
    }
}
