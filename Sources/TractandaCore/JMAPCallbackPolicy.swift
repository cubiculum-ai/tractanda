import Foundation

/// Local administrator configuration, never an Item, peer payload or client request field.
public struct JMAPCallbackOrigin: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public init(host: String, port: Int = 443) { self.host = host.lowercased(); self.port = port }
}
public struct JMAPCallbackPolicy: Codable, Equatable, Sendable {
    public let privateOrigins: [JMAPCallbackOrigin]
    public init(privateOrigins: [JMAPCallbackOrigin] = []) { self.privateOrigins = privateOrigins }
}

/// A parsed HTTPS endpoint. A URL is private capability material; reflection/logging is redacted.
public struct JMAPCallbackEndpoint: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public let host: String
    public let port: Int
    public let requestTarget: String
    public var origin: JMAPCallbackOrigin { .init(host: host, port: port) }
    public var hostHeader: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return port == 443 ? name : "\(name):\(port)"
    }
    public var description: String { "JMAPCallbackEndpoint(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
    public init(_ value: String) throws {
        guard value.utf8.count <= 8192, !value.isEmpty,
            value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), !value.contains("\\"),
            let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
            parts.user == nil, parts.password == nil, parts.fragment == nil,
            let parsedHost = parts.host, !parsedHost.isEmpty,
            let url = parts.url, url.scheme?.lowercased() == "https"
        else { throw Self.invalid() }
        // URLComponents decodes percent escapes in host; reject them in the original authority.
        guard let delimiter = value.range(of: "://"),
            !value[delimiter.upperBound...].prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }).contains("%")
        else { throw Self.invalid() }
        var name = parsedHost.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        guard !name.hasSuffix("."), !name.contains("%"), !name.contains("@"),
            name.utf8.count <= 253,
            name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45,46,58].contains($0) })
        else { throw Self.invalid() }
        let selectedPort = parts.port ?? 443
        guard (1...65535).contains(selectedPort) else { throw Self.invalid() }
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { throw Self.invalid() }
        host = name; port = selectedPort
        requestTarget = path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
    private static func invalid() -> TractandaError {
        TractandaError("invalidProperties", "A safe absolute HTTPS callback URL is required.")
    }
}
public struct JMAPCallbackResponse: Sendable {
    public let status: Int
    public let retryAfterSeconds: Int?
    public init(status: Int, retryAfterSeconds: Int? = nil) {
        self.status = status; self.retryAfterSeconds = retryAfterSeconds
    }
}
public protocol JMAPCallbackTransport: Sendable {
    /// Validates URL and every resolved address without sending a request.
    func validate(url: String) async throws
    /// Resolves/screens afresh; connects only a vetted address with original Host/TLS identity.
    /// Cancellation and expiry must close pending transport work; redirects are never followed.
    func post(url: String, body: Data, encrypted: Bool, ttlSeconds: Int, expiresAt: Date) async throws
        -> JMAPCallbackResponse
    func close() async
}
