import NIOCore
import NIOSSL

/// Outbound HTTPS trust is independent of the listener's own certificate and PSK peer binding.
/// Construct off an event loop: loading system trust roots may perform blocking filesystem work.
public final class HTTPSClientTrustContext: @unchecked Sendable {
    private let context: NIOSSLContext
    public init() throws {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.certificateVerification = .fullVerification
        configuration.trustRoots = .default
        configuration.applicationProtocols = ["http/1.1"]
        context = try NIOSSLContext(configuration: configuration)
    }
    public func makeClientHandler(serverHostname: String) throws -> NIOSSLClientHandler {
        // NIOSSL verifies an IP literal against the connected numeric address without placing it in SNI.
        let literal = (try? SocketAddress(ipAddress: serverHostname, port: 443)) != nil
        return try NIOSSLClientHandler(context: context, serverHostname: literal ? nil : serverHostname)
    }
}
