import Foundation

public enum JMAPSessionError: Error, Equatable, Sendable {
    case invalidAccount, invalidCapability, invalidLimit, invalidExposure, unavailableResources
}

/// Values must come from the binding's actual shared enforcement configuration.
public struct JMAPSessionLimits: Sendable {
    public let maxSizeUpload: Int64
    public let maxConcurrentUpload: Int64
    public let maxSizeRequest: Int64
    public let maxConcurrentRequests: Int64
    public let maxCallsInRequest: Int64
    public let maxObjectsInGet: Int64
    public let maxObjectsInSet: Int64
    public let collationAlgorithms: [String]

    public init(
        maxSizeUpload: Int64, maxConcurrentUpload: Int64, maxSizeRequest: Int64,
        maxConcurrentRequests: Int64, maxCallsInRequest: Int64, maxObjectsInGet: Int64,
        maxObjectsInSet: Int64, collationAlgorithms: [String]
    ) throws {
        let values = [
            maxSizeUpload, maxConcurrentUpload, maxSizeRequest, maxConcurrentRequests,
            maxCallsInRequest, maxObjectsInGet, maxObjectsInSet,
        ]
        guard values.allSatisfy({ $0 >= 0 && $0 <= 9_007_199_254_740_991 }),
            maxConcurrentUpload > 0, maxSizeRequest > 0, maxConcurrentRequests > 0,
            maxCallsInRequest > 0, Set(collationAlgorithms).count == collationAlgorithms.count,
            collationAlgorithms.allSatisfy({ !$0.isEmpty })
        else { throw JMAPSessionError.invalidLimit }
        self.maxSizeUpload = maxSizeUpload
        self.maxConcurrentUpload = maxConcurrentUpload
        self.maxSizeRequest = maxSizeRequest
        self.maxConcurrentRequests = maxConcurrentRequests
        self.maxCallsInRequest = maxCallsInRequest
        self.maxObjectsInGet = maxObjectsInGet
        self.maxObjectsInSet = maxObjectsInSet
        self.collationAlgorithms = collationAlgorithms
    }

    public var value: JMAPValue {
        let numbers: [(String, Int64)] = [
            ("maxSizeUpload", maxSizeUpload), ("maxConcurrentUpload", maxConcurrentUpload),
            ("maxSizeRequest", maxSizeRequest), ("maxConcurrentRequests", maxConcurrentRequests),
            ("maxCallsInRequest", maxCallsInRequest), ("maxObjectsInGet", maxObjectsInGet),
            ("maxObjectsInSet", maxObjectsInSet),
        ]
        return .object(
            numbers.map { .init($0.0, .number(try! JMAPNumber(String($0.1)))) }
                + [.init("collationAlgorithms", .array(collationAlgorithms.map(JMAPValue.string)))])
    }
}

/// An explicit binding assertion, not a request to install or configure these resources.
public struct JMAPSessionResources: Sendable {
    public let api: Bool
    public let upload: Bool
    public let download: Bool
    public let eventSource: Bool
    public init(api: Bool, upload: Bool, download: Bool, eventSource: Bool) {
        self.api = api
        self.upload = upload
        self.download = download
        self.eventSource = eventSource
    }
    fileprivate var complete: Bool { api && upload && download && eventSource }
}

/// Trusted administrator input only. Never derive this value from Host or forwarding headers.
/// TLS deployment and authentication are supplied and verified by the binding, not this DTO.
public struct JMAPHTTPSExposure: Sendable {
    public let baseURL: String
    public let resources: JMAPSessionResources
    public init(baseURL: String, resources: JMAPSessionResources) throws {
        guard baseURL.utf8.count <= 4096,
            baseURL.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }),
            !baseURL.contains("\\"), !baseURL.contains("{"), !baseURL.contains("}"),
            let parts = URLComponents(string: baseURL), parts.scheme == "https",
            let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil,
            parts.port == nil || (1...65535).contains(parts.port!),
            !parts.percentEncodedPath.contains("%"), !parts.path.contains("//"),
            !parts.path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == "." || $0 == ".." })
        else { throw JMAPSessionError.invalidExposure }
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.resources = resources
    }

    fileprivate var members: [JMAPMember] {
        [
            .init("apiUrl", .string(baseURL + "/jmap/api")),
            .init("uploadUrl", .string(baseURL + "/jmap/upload/{accountId}")),
            .init(
                "downloadUrl",
                .string(baseURL + "/jmap/download/{accountId}/{blobId}/{name}?type={type}")),
            .init(
                "eventSourceUrl",
                .string(baseURL + "/jmap/events?types={types}&closeafter={closeafter}&ping={ping}")),
        ]
    }
}

/// Caller-specific metadata supplied by Core's existing identity/authorization provider.
/// This builder neither reads OS accounts nor infers capabilities from installed code.
public struct JMAPSessionMetadata: Sendable {
    public let storeID: String
    public let accountName: String
    public let username: String
    public let isPersonal: Bool
    public let isReadOnly: Bool
    public let limits: JMAPSessionLimits
    public let capabilities: [String: JMAPValue]
    public let accountCapabilities: [String: JMAPValue]
    public let primaryCapabilities: [String]

    public init(
        storeID: String, accountName: String, username: String, isPersonal: Bool = false,
        isReadOnly: Bool, limits: JMAPSessionLimits,
        capabilities: [String: JMAPValue], accountCapabilities: [String: JMAPValue],
        primaryCapabilities: [String] = []
    ) throws {
        guard let uuid = UUID(uuidString: storeID), uuid.uuidString.lowercased() == storeID,
            JMAPRequest.validID(storeID), !accountName.isEmpty
        else { throw JMAPSessionError.invalidAccount }
        guard capabilities[JMAPKernel.core] == nil, accountCapabilities[JMAPKernel.core] == nil,
            Set(accountCapabilities.keys).isSubset(of: Set(capabilities.keys)),
            Set(primaryCapabilities).isSubset(of: Set(accountCapabilities.keys)),
            Set(primaryCapabilities).count == primaryCapabilities.count
        else { throw JMAPSessionError.invalidCapability }
        for (name, value) in Array(capabilities) + Array(accountCapabilities) {
            let url = URLComponents(string: name)
            let standard =
                name.hasPrefix("urn:ietf:params:jmap:") && name.count > "urn:ietf:params:jmap:".count
            let vendor = (url?.scheme == "https" || url?.scheme == "http") && !(url?.host?.isEmpty ?? true)
            guard standard || vendor, !name.contains(where: { $0.isWhitespace }), value.members != nil
            else { throw JMAPSessionError.invalidCapability }
            _ = try value.encoded()
        }
        self.storeID = storeID
        self.accountName = accountName
        self.username = username
        self.isPersonal = isPersonal
        self.isReadOnly = isReadOnly
        self.limits = limits
        self.capabilities = capabilities
        self.accountCapabilities = accountCapabilities
        self.primaryCapabilities = primaryCapabilities
    }

    private func members(exposure: JMAPHTTPSExposure?) -> [JMAPMember] {
        func object(_ values: [String: JMAPValue]) -> JMAPValue {
            .object(values.keys.sorted().map { .init($0, values[$0]!) })
        }
        let account: JMAPValue = .object([
            .init("name", .string(accountName)), .init("isPersonal", .bool(isPersonal)),
            .init("isReadOnly", .bool(isReadOnly)),
            .init("accountCapabilities", object(accountCapabilities)),
        ])
        var server = capabilities
        server[JMAPKernel.core] = limits.value
        let primary = Dictionary(
            uniqueKeysWithValues: primaryCapabilities.map { ($0, JMAPValue.string(storeID)) })
        return [
            .init("capabilities", object(server)), .init("accounts", .object([.init(storeID, account)])),
            .init("primaryAccounts", object(primary)), .init("username", .string(username)),
        ] + (exposure?.members ?? [])
    }

    /// Canonical metadata only: no item/query state. The opaque basis comes from Core's provider.
    /// A nil exposure describes a local binding and produces no public Session document.
    public func stateMaterial(authorizationBasis: Data, exposure: JMAPHTTPSExposure? = nil) throws -> Data {
        if let exposure, !exposure.resources.complete { throw JMAPSessionError.unavailableResources }
        func canonical(_ value: JMAPValue) -> JMAPValue {
            switch value {
            case .object(let members):
                return .object(
                    members.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
                        .map { .init($0.name, canonical($0.value)) })
            case .array(let values): return .array(values.map(canonical))
            default: return value
            }
        }
        return try canonical(
            .object([
                .init("profile", .string("tractanda.session-metadata.v1")),
                .init("authorization", .string(authorizationBasis.base64EncodedString())),
                .init("binding", .string(exposure == nil ? "local" : "https")),
                .init("metadata", .object(members(exposure: exposure))),
            ])
        ).encoded()
    }

    public func state(
        authorizationBasis: Data, exposure: JMAPHTTPSExposure? = nil,
        stateFactory: (Data) throws -> JMAPSessionState
    ) throws -> JMAPSessionState {
        try stateFactory(stateMaterial(authorizationBasis: authorizationBasis, exposure: exposure))
    }

    /// Building a document is not a network-conformance assertion. Binding tests remain required.
    public func session(
        authorizationBasis: Data, exposure: JMAPHTTPSExposure,
        stateFactory: (Data) throws -> JMAPSessionState
    ) throws -> JMAPSessionDocument {
        guard exposure.resources.complete else { throw JMAPSessionError.unavailableResources }
        let state = try state(
            authorizationBasis: authorizationBasis, exposure: exposure, stateFactory: stateFactory)
        return JMAPSessionDocument(
            value: .object(members(exposure: exposure) + [.init("state", .string(state.value))]), state: state
        )
    }
}

public struct JMAPSessionDocument: Sendable {
    public let value: JMAPValue
    public let state: JMAPSessionState
    public func encoded() throws -> Data { try value.encoded() }
}
