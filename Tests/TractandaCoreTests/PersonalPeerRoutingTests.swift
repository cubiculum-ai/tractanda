import Foundation
import XCTest

@testable import TractandaCore

final class PersonalPeerRoutingTests: XCTestCase {
    private func endpoint(_ host: String) throws -> PeerRuntimeConfiguration.Endpoint {
        try .init(host: host, port: 48_732)
    }
    func testOrderedAlternativesRoundTripDigestAndEstablishedSingleEndpointBytes() throws {
        let old = Data(#"{"alias":"remote","endpoint":{"host":"remote.example","port":48732}}"#.utf8)
        let single = try JSON.decode(PeerRuntimeConfiguration.Peer.self, old)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(try encoder.encode(single), old)
        let a = try endpoint("remote.local")
        let b = try endpoint("remote.tail.example")
        let first = try PeerRuntimeConfiguration.Peer(
            alias: "remote", host: "remote.lan.example", port: 48_732, fallbackEndpoints: [a, b])
        let second = try PeerRuntimeConfiguration.Peer(
            alias: "remote", host: "remote.lan.example", port: 48_732, fallbackEndpoints: [b, a])
        XCTAssertEqual(
            first.endpoints.map(\.host), ["remote.lan.example", "remote.local", "remote.tail.example"])
        XCTAssertEqual(try JSON.decode(PeerRuntimeConfiguration.Peer.self, JSON.encode(first)), first)
        XCTAssertNotEqual(
            try PeerRuntimeConfiguration(peers: [first]).settingsDigest,
            try PeerRuntimeConfiguration(peers: [second]).settingsDigest)
        XCTAssertThrowsError(
            try PeerRuntimeConfiguration.Peer(
                alias: "remote", host: a.host, port: a.port, fallbackEndpoints: [a]))
        XCTAssertThrowsError(
            try PeerRuntimeConfiguration.Peer(
                alias: "remote", host: "remote.example", port: 48_732,
                fallbackEndpoints: [a, b, endpoint("remote.public.example"), endpoint("too-many.example")]))
        XCTAssertThrowsError(
            try PeerRuntimeConfiguration.Peer(
                alias: "remote", host: "remote.example", port: 48_732,
                fallbackEndpoints: [endpoint("0.0.0.0")]))
        for numeric in ["127.0.0.1", "::1", "0x7f000001", "0x7f.0.0.1"] {
            let peer = try PeerRuntimeConfiguration.Peer(
                alias: "remote", host: "remote.example", port: 48_732,
                fallbackEndpoints: [endpoint(numeric)])
            XCTAssertThrowsError(
                try PersonalPeerRuntimeConfiguration(settings: PeerRuntimeConfiguration(peers: [peer])))
        }
    }
    func testRuntimeOverridesAreLocalCurrentMemberDNSOnlyAndLeaveMembershipUnchanged() throws {
        let local = try UUID.makeVersion1().uuidString.lowercased()
        let remote = try UUID.makeVersion1().uuidString.lowercased()
        let membership = try PersonalMembershipConfiguration(
            storeID: UUID.makeVersion1().uuidString.lowercased(),
            configurationID: UUID.makeVersion1().uuidString.lowercased(),
            members: [
                PersonalMember(replicaID: local, hostname: "local.tail.example"),
                PersonalMember(replicaID: remote, hostname: "remote.tail.example"),
            ])
        for numeric in ["0x7f000001", "0x7f.0.0.1"] {
            XCTAssertThrowsError(try PersonalMember(replicaID: remote, hostname: numeric))
        }
        let bytes = try JSON.encode(membership)
        let defaultPeers = try PersonalPeerRuntimeConfiguration.configuredPeers(
            membership: membership, localReplicaID: local, port: 48_732)
        XCTAssertEqual(defaultPeers.first?.endpoint.host, "remote.tail.example")
        let selected = try PersonalPeerRuntimeConfiguration.configuredPeers(
            membership: membership, localReplicaID: local, port: 48_732,
            endpointOverrides: [remote: [endpoint("remote.local"), endpoint("remote.tail.example")]])
        XCTAssertEqual(selected.first?.endpoints.map(\.host), ["remote.local", "remote.tail.example"])
        XCTAssertEqual(try JSON.encode(membership), bytes)
        for overrides in [
            [local: [try endpoint("local.local")]],
            ["unknown": [try endpoint("unknown.example")]],
            [remote: []],
            [remote: [try endpoint("127.0.0.1")]],
        ] {
            XCTAssertThrowsError(
                try PersonalPeerRuntimeConfiguration.configuredPeers(
                    membership: membership, localReplicaID: local, port: 48_732, endpointOverrides: overrides)
            )
        }
    }
}
