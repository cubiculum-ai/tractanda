import Foundation
import XCTest

@testable import TractandaCore

final class PeerRuntimeConfigurationValueTests: XCTestCase {
    func testV1OptionalDefaultsDeterministicBytesAndEffectiveDigest() throws {
        let disabled = try PeerRuntimeConfiguration.decode(Data(#"{"version":1}"#.utf8))
        XCTAssertNil(disabled.listen)
        XCTAssertTrue(disabled.peers.isEmpty)
        XCTAssertFalse(disabled.synchronization.enabled)
        XCTAssertEqual(disabled.synchronization.intervalSeconds, 300)
        XCTAssertEqual(
            disabled.settingsDigest, "45ad050ab512ad11f0753e7318c34452f62f55df5a44c57d395b8cebf2db83f0")

        let expectedDefaultBytes = Data(
            #"{"peers":[],"synchronization":{"enabled":false,"intervalSeconds":300},"version":1}"#.utf8)
        XCTAssertEqual(try disabled.encoded(), expectedDefaultBytes)
        XCTAssertEqual(try disabled.encoded(), try disabled.encoded())
        XCTAssertEqual(try PeerRuntimeConfiguration.decode(expectedDefaultBytes), disabled)

        let first = try PeerRuntimeConfiguration(
            peers: [
                PeerRuntimeConfiguration.Peer(alias: "beta", host: "BETA.example", port: 48_731),
                PeerRuntimeConfiguration.Peer(alias: "alpha", host: "alpha.example", port: 48_730),
            ])
        let reordered = try PeerRuntimeConfiguration(
            peers: [
                PeerRuntimeConfiguration.Peer(alias: "alpha", host: "alpha.example", port: 48_730),
                PeerRuntimeConfiguration.Peer(alias: "beta", host: "beta.example", port: 48_731),
            ])
        XCTAssertEqual(first.settingsDigest, reordered.settingsDigest)
        XCTAssertEqual(
            first.settingsDigest, "efbd67f9fad65df910c0f3893728a2097a7de4a44d6d0519ab63eb7fba678f25")
        XCTAssertNotEqual(first.settingsDigest, disabled.settingsDigest)

        let encoded = try first.encoded()
        XCTAssertLessThanOrEqual(encoded.count, PeerRuntimeConfiguration.maximumFileBytes)
        XCTAssertEqual(encoded, try first.encoded())
        XCTAssertEqual(try PeerRuntimeConfiguration.decode(encoded), first)
    }

    func testDecodeRejectsUnknownMalformedAndOversizedDocuments() throws {
        XCTAssertThrowsError(try PeerRuntimeConfiguration.decode(Data()))
        XCTAssertThrowsError(try PeerRuntimeConfiguration.decode(Data(repeating: 0x20, count: 65_537)))
        XCTAssertThrowsError(try PeerRuntimeConfiguration.decode(Data("{not-json".utf8)))
        XCTAssertThrowsError(try PeerRuntimeConfiguration.decode(Data(#"{"version":1,"extra":true}"#.utf8)))
        XCTAssertThrowsError(
            try PeerRuntimeConfiguration.decode(
                Data(
                    #"{"version":1,"listen":{"host":"127.0.0.1","port":48740,"extra":1}}"#.utf8)))
        XCTAssertThrowsError(try PeerRuntimeConfiguration.decode(Data(#"{"version":2}"#.utf8)))
        XCTAssertThrowsError(
            try PeerRuntimeConfiguration.decode(
                Data(
                    #"{"version":1,"synchronization":{"enabled":"yes","intervalSeconds":300}}"#.utf8)))
    }

    func testHostAndPeerBoundsRemainStrict() throws {
        XCTAssertEqual(
            try PeerRuntimeConfiguration.Endpoint(host: "BETA.example", port: 48_732).host, "beta.example")
        XCTAssertEqual(try PeerRuntimeConfiguration.Endpoint(host: "0.0.0.0", port: 48_732).host, "0.0.0.0")
        XCTAssertThrowsError(
            try PeerRuntimeConfiguration.Peer(alias: "remote", host: "0.0.0.0", port: 48_732))
        XCTAssertThrowsError(try PeerRuntimeConfiguration.Peer(alias: "remote", host: "::", port: 48_732))
        XCTAssertEqual(
            try PeerRuntimeConfiguration.Peer(alias: "remote", host: "::1", port: 48_732).endpoint.host, "::1"
        )
        for host in ["example.test/path", "999.2.3.4", "bad host", String(repeating: "a", count: 254)] {
            XCTAssertThrowsError(try PeerRuntimeConfiguration.Endpoint(host: host, port: 48_732), host)
        }
        XCTAssertThrowsError(try PeerRuntimeConfiguration.Endpoint(host: "example.test", port: 0))
        XCTAssertThrowsError(try PeerRuntimeConfiguration.Endpoint(host: "example.test", port: 65_536))
        XCTAssertThrowsError(try PeerRuntimeConfiguration.Peer(alias: "local", host: "a.example", port: 1))
        XCTAssertThrowsError(
            try PeerRuntimeConfiguration.Peer(alias: "bad\nalias", host: "a.example", port: 1))

        let repeated = try PeerRuntimeConfiguration.Peer(alias: "alpha", host: "alpha.example", port: 1)
        XCTAssertThrowsError(try PeerRuntimeConfiguration(peers: [repeated, repeated]))
        let maximumPeers = try (0..<256).map {
            try PeerRuntimeConfiguration.Peer(
                alias: "peer-\($0)", host: "peer-\($0).example", port: 1000 + $0)
        }
        XCTAssertEqual(try PeerRuntimeConfiguration(peers: maximumPeers).peers.count, 256)
        let excessivePeers = try (0...256).map {
            try PeerRuntimeConfiguration.Peer(
                alias: "peer-\($0)", host: "peer-\($0).example", port: 1000 + $0)
        }
        XCTAssertThrowsError(try PeerRuntimeConfiguration(peers: excessivePeers))
        XCTAssertEqual(
            try PeerRuntimeConfiguration.Peer(alias: "Peer_Écho", host: "echo.example", port: 48_733).alias,
            "Peer_Écho")

        let largePeers = try (0..<256).map { index in
            let alias = String(format: "peer%03d", index) + String(repeating: "a", count: 248)
            return try PeerRuntimeConfiguration.Peer(
                alias: alias, host: "peer-\(index).example", port: 1000 + index)
        }
        let oversizedConfiguration = try PeerRuntimeConfiguration(peers: largePeers)
        XCTAssertThrowsError(try oversizedConfiguration.encoded())
    }

    func testSynchronizationIntervalBounds() throws {
        XCTAssertEqual(
            try PeerRuntimeConfiguration.Synchronization(enabled: true, intervalSeconds: 15).intervalSeconds,
            15)
        XCTAssertEqual(
            try PeerRuntimeConfiguration.Synchronization(enabled: true, intervalSeconds: 86_400)
                .intervalSeconds, 86_400)
        XCTAssertThrowsError(try PeerRuntimeConfiguration.Synchronization(enabled: true, intervalSeconds: 14))
        XCTAssertThrowsError(
            try PeerRuntimeConfiguration.Synchronization(enabled: true, intervalSeconds: 86_401))
    }
}
