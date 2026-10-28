import Foundation
import TractandaClient

/// Trusted in-process authentication context. No request field, accountId or header constructs this.
public struct JMAPHTTPAuthentication: Sendable {
    public let credentialID: String
    public let uid: UInt32
    public let principalName: String
    public let expiresAt: Date
    private let validate: @Sendable () async throws -> AccountIdentity
    private let inspect: (@Sendable () async throws -> AccountIdentity)?
    public init(
        credentialID: String, uid: UInt32, principalName: String, expiresAt: Date,
        checkCurrent: (@Sendable () async throws -> AccountIdentity)? = nil,
        revalidate: @escaping @Sendable () async throws -> AccountIdentity
    ) {
        self.credentialID = credentialID
        self.uid = uid
        self.principalName = principalName
        self.expiresAt = expiresAt
        validate = revalidate
        inspect = checkCurrent
    }
    @discardableResult public func revalidate() async throws -> AccountIdentity {
        let account = try await validate()
        guard account.uid == uid, account.name == principalName else {
            throw TractandaError("invalidSession", "Authenticated identity changed.")
        }
        return account
    }
    /// Background checks do not renew an idle credential. Existing active-byte operations use revalidate().
    @discardableResult public func checkCurrent() async throws -> AccountIdentity {
        let account = try await (inspect ?? validate)()
        guard account.uid == uid, account.name == principalName else {
            throw TractandaError("invalidSession", "Authenticated identity changed.")
        }
        return account
    }

}

/// One captured document and typed state for a particular authenticated binding. Content state is separate.
public struct JMAPBindingSessionSnapshot: Sendable {
    public let document: JMAPValue
    public let state: JMAPSessionState
    public let accounts: [JMAPAccountAccess]
    public init(document: JMAPValue, state: JMAPSessionState, accounts: [JMAPAccountAccess]) {
        self.document = document
        self.state = state
        self.accounts = accounts
    }
}

/// Created only after the concrete HTTP resources are installed. URLs come from administrator configuration.
public struct JMAPPublicBinding: Sendable {
    public let exposure: JMAPHTTPSExposure
    public let limits: JMAPSessionLimits
    public init(exposure: JMAPHTTPSExposure, limits: JMAPSessionLimits) throws {
        guard limits.maxSizeRequest <= Int64(JMAPKernel.Limits().maximumRequestBytes),
            limits.maxCallsInRequest <= Int64(JMAPKernel.Limits().maximumCalls),
            limits.maxConcurrentRequests <= 64,
            limits.maxObjectsInGet == Int64(TractandaJMAP.maximumObjectsInGet)
        else {
            throw TractandaError(
                "invalidConfiguration", "Public limits exceed actual dispatcher enforcement.")
        }
        self.exposure = exposure
        self.limits = limits
    }
    package var kernelLimits: JMAPKernel.Limits {
        .init(maximumRequestBytes: Int(limits.maxSizeRequest), maximumCalls: Int(limits.maxCallsInRequest))
    }

}

/// Uploads own unaccepted bytes only; finish returns the standard {accountId,blobId,type,size} object.
public protocol JMAPBlobUpload: Sendable {
    func append(_ data: Data) async throws
    func finish() async throws -> JMAPValue
    func cancel() async
}
public struct JMAPBlobDownload: Sendable {
    public let size: Int64
    private let reader: @Sendable (Int64, Int) async throws -> Data
    private let closer: @Sendable () async -> Void
    public init(
        size: Int64, read: @escaping @Sendable (Int64, Int) async throws -> Data,
        close: @escaping @Sendable () async -> Void
    ) {
        self.size = size
        reader = read
        closer = close
    }
    public func read(offset: Int64, limit: Int) async throws -> Data { try await reader(offset, limit) }
    public func close() async { await closer() }
}
public protocol JMAPBlobHTTPProvider: Sendable {
    var maximumUploadBytes: Int64 { get }
    var maximumConcurrentUploads: Int64 { get }
    func beginUpload(
        accountID: String, type: String, expectedSize: Int64?, authentication: JMAPHTTPAuthentication
    ) async throws -> any JMAPBlobUpload
    func openDownload(accountID: String, blobID: String, authentication: JMAPHTTPAuthentication) async throws
        -> JMAPBlobDownload
    func methods(authentication: JMAPHTTPAuthentication) async throws -> [String: JMAPMethodDefinition]
}

public struct JMAPSSEEvent: Sendable {
    public let name: String
    public let id: String?
    public let data: JMAPValue
    public init(name: String, id: String? = nil, data: JMAPValue) {
        self.name = name
        self.id = id
        self.data = data
    }
}
public protocol JMAPSSESubscription: Sendable {
    /// nil ends a closeafter=state response or a revoked/closed subscription. No unbounded event queue.
    func next() async throws -> JMAPSSEEvent?
    func cancel() async
}
public protocol JMAPNotificationHTTPProvider: Sendable {
    var maximumObjectsInSet: Int64 { get }
    func subscribe(
        types: [String]?, closeAfterState: Bool, pingSeconds: Int, lastEventID: String?,
        authentication: JMAPHTTPAuthentication
    ) async throws -> any JMAPSSESubscription
    func methods(authentication: JMAPHTTPAuthentication) async throws -> [String: JMAPMethodDefinition]
    func close() async
}
