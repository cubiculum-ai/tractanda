import Foundation
import TractandaClient

package typealias NativeMethodOutcome = JMAPMethodOutcome

package struct NativePrincipalPin: Sendable {
    package let uid: UInt32
    package let name: String
    package init(_ authentication: JMAPHTTPAuthentication) {
        uid = authentication.uid
        name = authentication.principalName
    }
    package func validate(uid: UInt32, directory: any AccountDirectory) throws {
        guard uid == self.uid, try directory.user(forUID: uid).name == name else {
            throw TractandaError("forbidden", "Authenticated principal changed before admission.")
        }
    }
}

/// Already decoded and reference-resolved invocation. Domain argument decoding is separate from
/// Request decoding; no optimized/control route may inspect or parse a raw Request envelope.
package struct NativeMethodInvocation: Sendable {
    package let method: String
    package let arguments: JMAPValue
    package let callID: String
    package let callCount: Int
    package let accountID: String?
    package let principal: NativePrincipalPin?
    package let replyBudget: JMAPReplyBudget?
    private let createdIDs: [String: String]
    private let domainNormalized: Bool
    package init(
        _ invocation: JMAPInvocation, context: JMAPMethodContext? = nil, principal: NativePrincipalPin? = nil
    ) {
        method = invocation.name
        accountID = context?.accountID
        self.principal = principal
        arguments =
            context?.accountID == nil
            ? invocation.arguments
            : .object((invocation.arguments.members ?? []).filter { $0.name != "accountId" })
        callID = invocation.callID
        callCount = context?.callCount ?? 1
        replyBudget = context?.replyBudget
        createdIDs = context?.createdIDs ?? [:]
        domainNormalized = false
    }
    /// Explicit ingress state prevents synthetic/optimized invocations from decoding tagged values twice.
    package func normalizedForDomain() throws -> Self {
        guard !domainNormalized else { return self }
        return Self(
            method: method,
            arguments: try TractandaJMAPCodec.argumentsFromWire(
                method: method, arguments: arguments, createdIDs: createdIDs),
            callID: callID, callCount: callCount, accountID: accountID, replyBudget: replyBudget,
            createdIDs: createdIDs, domainNormalized: true, principal: principal)
    }
    package var argumentsJSON: Data { get throws { try arguments.encoded() } }
    package func dictionary() throws -> [String: Any] {
        func check(_ value: JMAPValue) throws {
            if let members = value.members {
                var names: Set<String> = []
                for member in members {
                    // The existing dictionary model cannot represent scalar-distinct canonically
                    // equivalent keys. Reject explicitly instead of dropping content in the bridge.
                    guard names.insert(member.name).inserted else {
                        throw TractandaError(
                            "invalidArguments",
                            "This dictionary contains keys the domain codec cannot distinguish.")
                    }
                    try check(member.value)
                }
            } else if let values = value.elements {
                for child in values { try check(child) }
            }
        }
        try check(arguments)
        guard let object = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else {
            throw TractandaError("invalidArguments", "Method arguments must be an object.")
        }
        return object
    }
    package func replacingArguments(_ value: JMAPValue) -> Self {
        Self(
            method: method, arguments: value, callID: callID, callCount: callCount, accountID: accountID,
            replyBudget: replyBudget, createdIDs: createdIDs, domainNormalized: domainNormalized,
            principal: principal)
    }
    private init(
        method: String, arguments: JMAPValue, callID: String, callCount: Int, accountID: String?,
        replyBudget: JMAPReplyBudget?, createdIDs: [String: String], domainNormalized: Bool,
        principal: NativePrincipalPin?
    ) {
        self.method = method
        self.arguments = arguments
        self.callID = callID
        self.callCount = callCount
        self.accountID = accountID
        self.replyBudget = replyBudget
        self.createdIDs = createdIDs
        self.domainNormalized = domainNormalized
        self.principal = principal
    }
}

extension JMAPMethodOutcome {
    package static func nativeSuccess(_ method: String, _ payload: Any) throws -> Self {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        return .success([
            .init(
                method,
                try TractandaJMAPCodec.extensionResultToWire(method: method, result: JMAPValue.decode(data)))
        ])
    }
    package static func nativeEncodedSuccess<T: Encodable>(_ method: String, _ payload: T) throws -> Self {
        .success([.init(method, try JMAPValue.decode(JSON.encode(payload)))])
    }
    package static func nativeError(_ payload: Any, effects: JMAPEffects = .none) throws -> Self {
        let value = try JMAPValue.decode(JSONSerialization.data(withJSONObject: payload))
        guard let members = value.members, let type = value["type"]?.text else {
            return .failure(.init("serverFail"), effects: effects)
        }
        return .failure(
            .init(
                type, description: value["description"]?.text,
                details: members.filter { $0.name != "type" && $0.name != "description" }), effects: effects)
    }
    package static func nativeFailure(_ error: any Error, budget: JMAPReplyBudget? = nil) -> Self {
        let failure =
            error as? TractandaError ?? TractandaError("serverFail", "The method could not be completed.")
        let partial = budget.map { !$0.provesNoEffects } == true || failure.code == "serverPartialFail"
        return .failure(
            .init(failure.code, description: failure.message), effects: partial ? .unknown : .none)
    }
}

/// One method manifest. A registry controls protocol opt-in, never authentication or domain rights.
package enum NativeMethodCatalog {
    package static let methods = TractandaJMAP.accountMethods.subtracting(TractandaJMAP.localControlMethods)
        .subtracting(["Blob/copy", "TractandaAttachment/attachBlob"])
    package static let readOnly: Set<String> = [
        "TractandaAttachment/content",
        "TractandaAttachment/document",
        "TractandaAttachment/documentContent",
        "TractandaAttachment/integrity",
        "TractandaAttachment/list",
        "TractandaAttachment/uploadStatus",
        "TractandaCategory/memberships",
        "TractandaDocumentJob/list",
        "TractandaDocumentJob/page",
        "TractandaDocumentJob/status",
        "TractandaItem/changes",
        "TractandaItem/conflicts",
        "TractandaItem/explain",
        "TractandaItem/extractedText",
        "TractandaItem/extractedTextUnit",
        "TractandaItem/get",
        "TractandaItem/getBounded",
        "TractandaItem/history",
        "TractandaItem/prepareCapture",
        "TractandaItem/query",
        "TractandaItem/resolve",
        "TractandaItem/sharing",
        "TractandaItem/state",
        "TractandaLearning/categories",
        "TractandaLearning/status",
        "TractandaLearning/suggest",
        "TractandaRevision/get",
        "TractandaSemantic/results",
        "TractandaSemantic/search",
        "TractandaSemantic/status",
        "TractandaStore/describe",
        "TractandaStore/info",
        "TractandaStore/rebuildStatus",
    ]
    package static let compactReceipts: Set<String> = [
        "TractandaItem/commit", "TractandaItem/commitCapture", "TractandaItem/resolveConflict",
        "TractandaSync/acceptReview", "TractandaLearning/settings", "TractandaLearning/feedback",
    ]
    // These paths publish ordinary item revisions; auxiliary copy/review cleanup is observed too.
    package static let completelyObserved = compactReceipts.union([
        "TractandaItem/setSharing", "TractandaCategory/installTemplate",
    ])
    package static let itemWrites = compactReceipts.union([
        "TractandaItem/setSharing", "TractandaCategory/installTemplate", "TractandaAttachment/begin",
        "TractandaAttachment/upload", "TractandaAttachment/finish", "TractandaAttachment/detach",
        "TractandaAttachment/extractText",
        "TractandaDocumentJob/start", "TractandaDocumentJob/resume", "TractandaDocumentJob/rebase",
    ])
    package static func definitions(
        discovery: JMAPValue? = nil,
        dispatch: @escaping @Sendable (JMAPInvocation, JMAPMethodContext) async throws -> JMAPMethodOutcome
    ) -> [String: JMAPMethodDefinition] {
        var result = Dictionary(
            uniqueKeysWithValues: methods.map { method in
                (
                    method,
                    JMAPMethodDefinition(
                        capability: TractandaJMAP.capability,
                        effect: readOnly.contains(method) ? .readOnly : .mayMutate, scope: .account,
                        requiresWritableAccount: itemWrites.contains(method),
                        maximumResponseBytes: 8 * 1024 * 1024 - 16 * 1024,
                        requiresMutationAdmission: !readOnly.contains(method)
                    ) { args, context in
                        try await dispatch(
                            .init(name: method, arguments: args, callID: context.callID), context)
                    }
                )
            })
        result[TractandaJMAP.discoveryMethod] = .init(
            capability: TractandaJMAP.capability, effect: .readOnly,
            scope: .session, maximumResponseBytes: 65_536
        ) { args, _ in
            guard args.members?.isEmpty == true else {
                return .failure(.init("invalidArguments"), effects: .none)
            }
            guard let discovery else { return .failure(.init("serverUnavailable"), effects: .none) }
            return .success([.init(TractandaJMAP.discoveryMethod, discovery)])
        }
        return result
    }

}

extension ItemService {
    /// Reserve a bound from the actual wire schema, on the serialized Store owner, before effects.
    func reserveNativeMutationReply(_ call: NativeMethodInvocation) throws {
        guard !NativeMethodCatalog.readOnly.contains(call.method), let budget = call.replyBudget,
            !budget.hasMutationAdmission
        else {
            return
        }
        try validateNativeMutationArguments(call)
        if NativeMethodCatalog.compactReceipts.contains(call.method) {
            try budget.reserveMutationResponse(
                maximumResponseBytes:
                    MutationReceipt.maximumResponseBytes(method: call.method, callID: call.callID))
            return
        }
        let arguments = try call.dictionary()
        let inputBytes = try call.argumentsJSON.count
        let tupleOverhead =
            try JMAPInvocation(name: call.method, arguments: .object([]), callID: call.callID).value.encoded()
            .count - 2
        let payloadBound: Int
        switch call.method {
        case "TractandaCategory/installTemplate":
            // CategoryTemplate enforces256entries,100ASCII key bytes and UUID36 values.
            payloadBound = 256 * (100 + 36 + 6) + 64
        case "TractandaItem/setSharing":
            guard let id = arguments["itemID"] as? String else {
                throw TractandaError("invalidArguments", "Supply itemID.")
            }
            let current = try store.personalSharingMetadata(id)
            // Both current/proposed ACLs are represented; the remaining metadata is fixed UUID/hash fields.
            let currentWire = try TractandaJMAPCodec.extensionResultToWire(
                method: call.method, result: JMAPValue.decode(JSON.encode(current)))
            let proposedWire = try TractandaJMAPCodec.argumentsToWire(
                method: call.method, arguments: call.arguments)
            payloadBound = try currentWire.encoded().count + proposedWire.encoded().count + 8192
        case "TractandaLearning/train", "TractandaLearning/reset":
            guard let id = arguments["categoryID"] as? String else {
                throw TractandaError("invalidArguments", "Supply categoryID.")
            }
            // Fixed scalar settings/status schema; model ID/date/counters add well under8KiB.
            payloadBound = try JSON.encode(learning.status(for: id)).count + 8192
        case "TractandaSemantic/configure", "TractandaSemantic/reset", "TractandaSemantic/rebuild":
            // Configuration's model text comes from the current or submitted configuration;
            // the remainder consists of finite profile/status strings and scalar counters.
            payloadBound = try nativeSemanticStatusByteCount() + inputBytes + 8192
        case "TractandaAttachment/begin", "TractandaAttachment/upload", "TractandaAttachment/finish",
            "TractandaAttachment/detach", "TractandaAttachment/extractText", "TractandaAttachment/abort",
            "TractandaStore/configureAccess", "TractandaSync/rejectReview",
            "TractandaDocumentJob/start", "TractandaDocumentJob/cancel", "TractandaDocumentJob/discard",
            "TractandaDocumentJob/rebase", "TractandaDocumentJob/resume",
            "TractandaStore/rebuild", "TractandaStore/rebuildCancel":
            // Existing bounded lifecycle schemas: UUIDs/operation IDs/scalar progress, fixed warnings,
            // and at most512UTF8bytes of validated document timeout context. Submitted filename,
            // operation/configuration strings are additionally covered by the exact argument bytes.
            payloadBound = inputBytes + 8192
        default:
            throw TractandaError("serverFail", "This mutator has no reviewed reply-admission contract.")
        }
        try budget.reserveMutationResponse(maximumResponseBytes: tupleOverhead + payloadBound)
    }
}

/// Immutable non-content basis, also usable while exclusive rebuild owns the Store queue.
struct NativeProtocolSessionBasis: Sendable {
    let identity: String
    let persistenceProfile: String
    let isMultiUser: Bool
    let policy: RebuildAdministratorPolicy
    var isReadOnly: Bool
    var maximumConcurrentRequests: Int64 = 1
    var maximumObjectsInSet: Int64 = 0
    func session(authenticationKey: String, username: String) throws -> JMAPLocalSession {
        let limits = try JMAPSessionLimits(
            maxSizeUpload: 0, maxConcurrentUpload: 1,
            maxSizeRequest: Int64(JMAPKernel.Limits().maximumRequestBytes),
            maxConcurrentRequests: maximumConcurrentRequests,
            maxCallsInRequest: Int64(JMAPKernel.Limits().maximumCalls),
            maxObjectsInGet: Int64(TractandaJMAP.maximumObjectsInGet),
            maxObjectsInSet: maximumObjectsInSet, collationAlgorithms: [])
        let info: JMAPValue = .object([
            .init("integerEncoding", .string(TractandaJMAP.integerEncoding)),
            .init("maxBlobIdsInCopy", .number(try JMAPNumber(String(TractandaJMAP.maximumBlobIDsInCopy)))),
            .init("binding", .string("local")), .init("persistenceProfile", .string(persistenceProfile)),
            .init("maxJSONDepth", .number(try JMAPNumber(String(JMAPKernel.Limits().maximumJSONDepth)))),
            .init(
                "maxResponseBytes", .number(try JMAPNumber(String(JMAPKernel.Limits().maximumResponseBytes)))),
        ])
        let metadata = try JMAPSessionMetadata(
            storeID: identity, accountName: "Tractanda", username: username,
            isPersonal: false, isReadOnly: isReadOnly, limits: limits,
            capabilities: [TractandaJMAP.capability: info],
            accountCapabilities: [TractandaJMAP.capability: .object([])],
            primaryCapabilities: [TractandaJMAP.capability])
        let auth = try JSON.encode(["authorization": authenticationKey, "profile": persistenceProfile])
        return try JMAPLocalSession(metadata: metadata, authorizationBasis: auth) { data in
            try JMAPSessionState(PageCorpusInput.digest(data))
        }
    }
    func session(forUID uid: UInt32, accounts: any AccountDirectory) throws -> JMAPLocalSession {
        let account = try policy.accountIfAdmitted(uid: uid, accounts: accounts)
        let administrator = (try? policy.authorize(uid: uid, accounts: accounts)) != nil
        let groups = account.groupIDs.sorted().map(String.init).joined(separator: ",")
        let key = isMultiUser ? "\(account.uid):\(account.name):\(groups):\(administrator)" : "single-user"
        return try session(authenticationKey: key, username: account.name)
    }
    func publicSnapshot(forUID uid: UInt32, accounts: any AccountDirectory, binding: JMAPPublicBinding) throws
        -> JMAPBindingSessionSnapshot
    {
        let local = try session(forUID: uid, accounts: accounts)
        var info = local.value["capabilities"]?[TractandaJMAP.capability]?.members ?? []
        info.removeAll { $0.name == "binding" }
        info.append(.init("binding", .string("https")))
        info.append(.init("blobIdentity", .string("sha256")))
        let metadata = try JMAPSessionMetadata(
            storeID: identity, accountName: "Tractanda", username: local.username,
            isPersonal: false, isReadOnly: isReadOnly, limits: binding.limits,
            capabilities: [TractandaJMAP.capability: .object(info)],
            accountCapabilities: [TractandaJMAP.capability: .object([])],
            primaryCapabilities: [TractandaJMAP.capability])
        let document = try metadata.session(
            authorizationBasis: JSON.encode(["authorizationState": local.state.value]),
            exposure: binding.exposure, stateFactory: { try JMAPSessionState(PageCorpusInput.digest($0)) })
        return .init(document: document.value, state: document.state, accounts: [try accountAccess()])
    }
    func accountAccess() throws -> JMAPAccountAccess {
        try .init(accountID: identity, capabilities: [TractandaJMAP.capability], isReadOnly: isReadOnly)
    }
}

package enum NativeInvocationScope {
    @TaskLocal package static var budget: JMAPReplyBudget?
}
