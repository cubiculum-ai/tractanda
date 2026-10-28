import Foundation
import NIOCore
import NIOPosix
import TractandaCore
import XCTest

@testable import TractandaServer

private actor CallbackAddressFixture {
    var addresses: [SocketAddress]
    var calls = 0
    init(_ addresses: [SocketAddress]) { self.addresses = addresses }
    func resolve(_ host: String, _ port: Int) -> [SocketAddress] {
        calls += 1
        return addresses
    }
    func set(_ addresses: [SocketAddress]) { self.addresses = addresses }
    func count() -> Int { calls }
}

final class JMAPCallbackPolicyTests: XCTestCase {
    func testCallbackURLStrictParsingRedactionAndOriginalHostIdentity() throws {
        for url in [
            "http://public.example/", "https://user:secret@public.example/",
            "https://public.example/#fragment",
            "https://public.example/\\other", "https://public.example:0/", "https://public.example:65536/",
            "https://public.example//other", "https://public.example./", "https://public%2eexample/",
            "https://public.example/\r\nAuthorization:x", "https://ümlaut.example/",
        ] {
            XCTAssertThrowsError(try JMAPCallbackEndpoint(url), url)
        }
        let endpoint = try JMAPCallbackEndpoint(
            "https://PUBLIC.example:8443/callback?capability=secret%20value")
        XCTAssertEqual(endpoint.host, "public.example")
        XCTAssertEqual(endpoint.port, 8443)
        XCTAssertEqual(endpoint.hostHeader, "public.example:8443")
        XCTAssertEqual(endpoint.requestTarget, "/callback?capability=secret%20value")
        XCTAssertFalse(String(reflecting: endpoint).contains("capability"))
        XCTAssertFalse(String(describing: endpoint).contains("secret"))
        let ipv6 = try JMAPCallbackEndpoint("https://[2606:4700:4700::1111]/push")
        XCTAssertEqual(ipv6.hostHeader, "[2606:4700:4700::1111]")
    }
    func testIPClassifierCoversSpecialIPv4IPv6MappedAndTransitionRanges() {
        for ip in [
            "0.0.0.0", "224.0.0.1", "240.0.0.1", "255.255.255.255", "::", "ff02::1", "::ffff:127.0.0.1",
        ] {
            XCTAssertNotEqual(NIOJMAPCallbackTransport.addressKind(ip), .publicInternet, ip)
        }
        for ip in [
            "10.0.0.1", "100.64.0.1", "100.127.255.254", "127.0.0.1", "169.254.169.254", "172.16.0.1",
            "172.31.255.255", "192.168.1.1", "192.0.0.8", "192.0.2.1", "192.88.99.1", "198.18.0.1",
            "198.19.255.255", "198.51.100.1", "203.0.113.1", "::1", "fc00::1", "fd7a:115c:a1e0::1",
            "fe80::1", "64:ff9b::a00:1", "2001::1", "2001:db8::1", "2002:a00:1::1", "3fff::1",
            "::ffff:10.1.2.3", "::ffff:100.64.0.1", "::ffff:192.168.1.1",
        ] {
            XCTAssertEqual(NIOJMAPCallbackTransport.addressKind(ip), .privateNetwork, ip)
        }
        for ip in [
            "1.1.1.1", "8.8.8.8", "100.128.0.1", "172.32.0.1", "2606:4700:4700::1111", "::ffff:8.8.8.8",
        ] {
            XCTAssertEqual(NIOJMAPCallbackTransport.addressKind(ip), .publicInternet, ip)
        }
    }
    func testAllDNSAnswersAreScreenedAndExactAdminHostnamePortGrantsPrivateAccess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let addresses = CallbackAddressFixture([
            try SocketAddress(ipAddress: "8.8.8.8", port: 8443),
            try SocketAddress(ipAddress: "127.0.0.1", port: 8443),
        ])
        let denied = try NIOJMAPCallbackTransport(group: group, resolver: { await addresses.resolve($0, $1) })
        do {
            try await denied.validate(url: "https://receiver.fixture:8443/push")
            XCTFail("Mixed private/public answers")
        } catch {}
        let allowed = try NIOJMAPCallbackTransport(
            group: group,
            policy: .init(privateOrigins: [.init(host: "receiver.fixture", port: 8443)]),
            resolver: { await addresses.resolve($0, $1) })
        try await allowed.validate(url: "https://receiver.fixture:8443/push")
        do {
            try await allowed.validate(url: "https://other.fixture:8443/push")
            XCTFail("Different origin")
        } catch {}
        do {
            try await allowed.validate(url: "https://receiver.fixture/push")
            XCTFail("Different port")
        } catch {}
        await denied.close()
        await allowed.close()
    }
    func testDNSRebindingIsRejectedBeforeAnyConnectionAndLiteralCannotBeRemapped() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let addresses = CallbackAddressFixture([try SocketAddress(ipAddress: "8.8.8.8", port: 443)])
        let transport = try NIOJMAPCallbackTransport(
            group: group, resolver: { await addresses.resolve($0, $1) })
        try await transport.validate(url: "https://receiver.fixture/push")
        await addresses.set([try SocketAddress(ipAddress: "::ffff:127.0.0.1", port: 443)])
        do {
            _ = try await transport.post(
                url: "https://receiver.fixture/push", body: Data("{}".utf8),
                encrypted: false, ttlSeconds: 60, expiresAt: Date() + 60)
            XCTFail("Rebound callback")
        } catch {}
        let count = await addresses.count()
        XCTAssertEqual(count, 2)
        await addresses.set([try SocketAddress(ipAddress: "1.1.1.1", port: 443)])
        do {
            try await transport.validate(url: "https://8.8.8.8/push")
            XCTFail("Literal remapped")
        } catch {}
        await transport.close()
    }
    func testForbiddenDestinationsRemainForbiddenEvenWithAdminOriginAndClosedTransportRejects() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        for ip in ["0.0.0.0", "ff02::1"] {
            let fixtureIP = ip
            let transport = try NIOJMAPCallbackTransport(
                group: group,
                policy: .init(privateOrigins: [.init(host: "receiver.fixture")]),
                resolver: { _, port in [try SocketAddress(ipAddress: fixtureIP, port: port)] })
            do {
                try await transport.validate(url: "https://receiver.fixture/")
                XCTFail(ip)
            } catch {}
            await transport.close()
            do {
                try await transport.validate(url: "https://receiver.fixture/")
                XCTFail("Closed")
            } catch {}
        }
    }
}
