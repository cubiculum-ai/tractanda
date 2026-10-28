import Foundation

/// One ordinary Tractanda wire specification; no prototype aliases or inferred server account.
public enum TractandaJMAP {
    public static let capability = "https://tractanda.ai/ns/jmap/1"
    public static let maximumObjectsInGet = 64
    public static let maximumObjectsInSet = 64
    public static let maximumBlobIDsInCopy = 256
    public static let discoveryMethod = "TractandaSession/get"
    public static let localProfile = "tractanda.local-session.v1"
    /// All tagged ItemValue Int64 values use canonical decimal strings on the wire.
    public static let integerEncoding = "tagged-int64-decimal-v1"
    public static let using = [JMAPKernel.core, capability]
    public static let accountMethods: Set<String> = [
        "Blob/copy", "TractandaAttachment/attachBlob",
        "TractandaAttachment/abort",
        "TractandaAttachment/begin",
        "TractandaAttachment/content",
        "TractandaAttachment/detach",
        "TractandaAttachment/document",
        "TractandaAttachment/documentContent",
        "TractandaAttachment/extractText",
        "TractandaAttachment/finish",
        "TractandaAttachment/integrity",
        "TractandaAttachment/list",
        "TractandaAttachment/upload",
        "TractandaAttachment/uploadStatus",
        "TractandaCategory/installTemplate",
        "TractandaCategory/memberships",
        "TractandaDocumentJob/cancel",
        "TractandaDocumentJob/discard",
        "TractandaDocumentJob/list",
        "TractandaDocumentJob/page",
        "TractandaDocumentJob/rebase",
        "TractandaDocumentJob/resume",
        "TractandaDocumentJob/start",
        "TractandaDocumentJob/status",
        "TractandaItem/changes",
        "TractandaItem/commit",
        "TractandaItem/commitCapture",
        "TractandaItem/conflicts",
        "TractandaItem/explain",
        "TractandaItem/extractedText",
        "TractandaItem/extractedTextUnit",
        "TractandaItem/get", "TractandaItem/getBounded",
        "TractandaItem/history",
        "TractandaItem/prepareCapture",
        "TractandaItem/query",
        "TractandaItem/resolve",
        "TractandaItem/resolveConflict",
        "TractandaItem/setSharing",
        "TractandaItem/sharing",
        "TractandaItem/state",
        "TractandaLearning/categories",
        "TractandaLearning/feedback",
        "TractandaLearning/reset",
        "TractandaLearning/settings",
        "TractandaLearning/status",
        "TractandaLearning/suggest",
        "TractandaLearning/train",
        "TractandaPeer/status",
        "TractandaPeerEnrollment/accept",
        "TractandaPeerEnrollment/read",
        "TractandaPeerEnrollment/register",
        "TractandaPeerEnrollment/status",
        "TractandaPeerEnrollment/step",
        "TractandaPeerPersonal/admin",
        "TractandaRevision/get",
        "TractandaSemantic/configure",
        "TractandaSemantic/rebuild",
        "TractandaSemantic/reset",
        "TractandaSemantic/results",
        "TractandaSemantic/search",
        "TractandaSemantic/status",
        "TractandaStore/configureAccess",
        "TractandaStore/describe",
        "TractandaStore/info",
        "TractandaStore/rebuild",
        "TractandaStore/rebuildCancel",
        "TractandaStore/rebuildStatus",
        "TractandaSync/acceptReview",
        "TractandaSync/rejectReview",
        "TractandaSync/reviews",
    ]
    public static let localControlMethods: Set<String> = [
        "TractandaPeerPersonal/admin", "TractandaPeer/status", "TractandaPeerEnrollment/step",
        "TractandaPeerEnrollment/status", "TractandaPeerEnrollment/accept",
        "TractandaPeerEnrollment/register", "TractandaPeerEnrollment/read",
    ]
    public static func scope(of method: String) -> JMAPMethodDefinition.Scope? {
        if ["Core/echo", discoveryMethod, "TractandaAuth/createSession"].contains(method) { return .session }
        return accountMethods.contains(method) ? .account : nil
    }
    public static func prepareArguments(method: String, arguments: JMAPValue, accountID: String?) throws
        -> JMAPValue
    {
        guard let members = arguments.members else {
            throw TractandaError("invalidArguments", "Arguments must be an object.")
        }
        guard scope(of: method) == .account else { return arguments }
        // An explicit or referenced selection is never replaced by a cached account.
        if arguments["accountId"] != nil || arguments["#accountId"] != nil { return arguments }
        guard let accountID, JMAPRequest.validID(accountID) else {
            throw TractandaError(
                "sessionRequired", "Discover this transport's account before an account-scoped request.")
        }
        return .object(members + [.init("accountId", .string(accountID))])
    }
}

/// Common authenticated discovery view. Local documents remain explicitly local; public documents contain real HTTPS resources.
public struct JMAPDiscoverySession: Sendable {
    public let accountID: String
    public let state: JMAPSessionState
    public let username: String
    public let value: JMAPValue
    public init(data: Data) throws { try self.init(value: JMAPValue.decode(data)) }
    public init(value: JMAPValue) throws {
        let urls = ["apiUrl", "uploadUrl", "downloadUrl", "eventSourceUrl"]
        let local = value["profile"]?.text == TractandaJMAP.localProfile
        let publicHTTPS =
            value["profile"] == nil
            && urls.allSatisfy { key in
                guard let text = value[key]?.text, let url = URLComponents(string: text) else { return false }
                return url.scheme == "https" && !(url.host?.isEmpty ?? true) && url.user == nil
                    && url.password == nil
            }
        guard (local && urls.allSatisfy({ value[$0] == nil })) || publicHTTPS else {
            throw TractandaError("protocolError", "Invalid binding Session document.")
        }
        guard let accounts = value["accounts"]?.members, accounts.count == 1,
            let account = accounts.first, let uuid = UUID(uuidString: account.name),
            uuid.uuidString.lowercased() == account.name,
            account.value["accountCapabilities"]?[TractandaJMAP.capability]?.members != nil,
            value["capabilities"]?[JMAPKernel.core]?.members != nil,
            value["capabilities"]?[TractandaJMAP.capability]?.members != nil,
            let username = value["username"]?.text, let state = value["state"]?.text, !state.isEmpty
        else { throw TractandaError("protocolError", "Invalid Session/account discovery document.") }
        self.accountID = account.name
        self.state = try .init(state)
        self.username = username
        self.value = value
    }
    public init(local: JMAPLocalSession) {
        accountID = local.accountID
        state = local.state
        username = local.username
        value = local.value
    }
}

/// Explicit local-binding metadata, not a public RFC Session missing its resource URLs.
public struct JMAPLocalSession: Sendable {
    public let accountID: String
    public let state: JMAPSessionState
    public let username: String
    public let value: JMAPValue
    public init(data: Data) throws { try self.init(value: JMAPValue.decode(data)) }
    public init(value: JMAPValue) throws {
        guard value["profile"]?.text == TractandaJMAP.localProfile else {
            throw TractandaError("protocolError", "Expected explicit local Session document.")
        }
        let parsed = try JMAPDiscoverySession(value: value)
        accountID = parsed.accountID
        state = parsed.state
        username = parsed.username
        self.value = value
    }
    public init(
        metadata: JMAPSessionMetadata, authorizationBasis: Data,
        stateFactory: (Data) throws -> JMAPSessionState
    ) throws {
        let state = try metadata.state(authorizationBasis: authorizationBasis, stateFactory: stateFactory)
        func object(_ values: [String: JMAPValue]) -> JMAPValue {
            .object(values.keys.sorted().map { .init($0, values[$0]!) })
        }
        var capabilities = metadata.capabilities
        capabilities[JMAPKernel.core] = metadata.limits.value
        let account: JMAPValue = .object([
            .init("name", .string(metadata.accountName)), .init("isPersonal", .bool(metadata.isPersonal)),
            .init("isReadOnly", .bool(metadata.isReadOnly)),
            .init("accountCapabilities", object(metadata.accountCapabilities)),
        ])
        let primary = Dictionary(
            uniqueKeysWithValues: metadata.primaryCapabilities.map {
                ($0, JMAPValue.string(metadata.storeID))
            })
        try self.init(
            value: .object([
                .init("profile", .string(TractandaJMAP.localProfile)),
                .init("capabilities", object(capabilities)),
                .init("accounts", .object([.init(metadata.storeID, account)])),
                .init("primaryAccounts", object(primary)),
                .init("username", .string(metadata.username)), .init("state", .string(state.value)),
            ]))
    }
}

/// Caller-owned value cache. Bind its lifetime to one endpoint/authentication context.
public struct JMAPDiscoveryCache: Sendable {
    public private(set) var session: JMAPDiscoverySession?
    public init(session: JMAPLocalSession? = nil) {
        self.session = session.map(JMAPDiscoverySession.init(local:))
    }
    public mutating func accept(_ session: JMAPLocalSession) { self.session = .init(local: session) }
    public mutating func accept(_ session: JMAPDiscoverySession) { self.session = session }
    public mutating func observe(sessionState: String) {
        if let session, session.state.value != sessionState { self.session = nil }
    }
    public mutating func invalidate() { session = nil }
}
