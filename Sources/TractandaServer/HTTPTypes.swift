import Foundation

/// Transport metadata remains separate from the native method envelope and its caller identity.
public struct DaemonHTTPRequest: Sendable {
    public let method: String
    public let uri: String
    /// Lowercased names retain all values so security-sensitive duplicates can be rejected.
    public let headers: [String: [String]]
    public let body: Data
    public let localPort: Int

    public init(
        method: String, uri: String, headers: [String: [String]], body: Data, localPort: Int
    ) {
        self.method = method
        self.uri = uri
        self.headers = headers
        self.body = body
        self.localPort = localPort
    }
}

public struct DaemonHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}
