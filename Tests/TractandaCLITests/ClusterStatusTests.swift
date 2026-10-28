import Foundation
import XCTest

@testable import TractandaCLI
@testable import TractandaCore

final class ClusterStatusTests: XCTestCase {
    private let store = "01010101-0101-1101-8101-010101010101"
    private let local = "02020202-0202-1202-8202-020202020202"
    private let remote = "03030303-0303-1303-8303-030303030303"
    private func fixture() throws -> PeerOperatorStatus {
        let membership = try PersonalMembershipConfiguration(
            storeID: store,
            configurationID: "04040404-0404-1404-8404-040404040404",
            members: [
                .init(replicaID: local, hostname: "local.fixture"),
                .init(replicaID: remote, hostname: "remote.fixture"),
            ])
        return .init(
            canonical: .init(
                storeID: store, replicaID: local, readiness: .ready,
                localDisposed: nil, configuredPairingCount: nil, committedPairingCount: nil,
                personal: try .init(storeID: store, currentMembership: membership, pendingMembership: nil)),
            runtime: try .init(
                state: .active, synchronization: .init(state: .active),
                configuredPeers: [],
                personalPeers: [
                    .init(
                        replicaID: remote,
                        configurationDigest: membership.digest, connected: true, incomingConnectionCount: 1,
                        controlOnly: false, lastErrorCode: "private\nremote error")
                ]))
    }
    func testHumanAndJSONUseSameAccountAwareStatusWithoutAutostart() throws {
        let value = try fixture()
        let payload = try JSONSerialization.jsonObject(with: JSON.encode(value))
        var options = ConnectionOptions()
        options.socketPath = "/private/tmp/cluster-status.sock"
        for suffix in [[], ["--json"]] {
            var sent = 0
            var received = Data()
            let result = try clusterStatusCommand(
                arguments: ["cluster", "status"] + suffix,
                options: options, output: { received = $0 },
                sendForTesting: { connection, request, _ in
                    XCTAssertNil(connection.managedService)
                    XCTAssertEqual(connection.socketPath, options.socketPath)
                    let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
                    let call = (envelope["methodCalls"] as! [[Any]])[0]
                    if call[0] as? String == "TractandaSession/get" {
                        let capability = ItemService.capability
                        return try JSONSerialization.data(withJSONObject: [
                            "methodResponses": [
                                [
                                    call[0],
                                    [
                                        "profile": "tractanda.local-session.v1", "username": "alice",
                                        "state": "metadata",
                                        "capabilities": ["urn:ietf:params:jmap:core": [:], capability: [:]],
                                        "accounts": [self.store: ["accountCapabilities": [capability: [:]]]],
                                        "primaryAccounts": [capability: self.store],
                                    ], call[2],
                                ]
                            ]
                        ])
                    }
                    sent += 1
                    XCTAssertEqual(call[0] as? String, PeerOperatorStatus.nativeMethod)
                    XCTAssertEqual((call[1] as? [String: Any])?["accountId"] as? String, self.store)
                    var response = payload as! [String: Any]
                    response["accountId"] = self.store
                    return try JSONSerialization.data(withJSONObject: [
                        "methodResponses": [[call[0], response, call[2]]]
                    ])
                })
            XCTAssertTrue(result)
            XCTAssertEqual(sent, 1)
            if suffix.isEmpty {
                let text = String(decoding: received, as: UTF8.self)
                XCTAssertEqual(text, clusterStatusText(value))
                XCTAssertTrue(text.contains("remote.fixture"))
                XCTAssertTrue(text.contains("Connected at: unknown"))
                XCTAssertTrue(text.contains("duplex"))
                XCTAssertFalse(text.contains("private\nremote error"))
                XCTAssertTrue(text.contains("peerRuntimeUnavailable"))
            } else {
                let decoded = try JSON.decode(PeerOperatorStatus.self, received)
                XCTAssertEqual(decoded.canonical.personal?.currentMembership?.members.count, 2)
                XCTAssertEqual(decoded.runtime.personalPeers?.first?.lastConnectedAt, nil)
            }
        }
    }
    func testUnknownStaleAndTerminalControlsRemainExplicit() throws {
        let value = try fixture()
        let stale = try PeerOperatorRuntimeStatus(
            state: .active,
            synchronization: .init(state: .disabled),
            personalPeers: [
                .init(
                    replicaID: remote,
                    configurationDigest: String(repeating: "a", count: 64), connected: false)
            ])
        let status = PeerOperatorStatus(canonical: value.canonical, runtime: stale)
        let text = clusterStatusText(status)
        XCTAssertTrue(text.contains("Observed connection: unknown"))
        XCTAssertTrue(text.contains("stale/other configuration"))
        XCTAssertEqual(text, clusterStatusText(status))
        XCTAssertThrowsError(
            try clusterStatusCommand(arguments: ["cluster", "status", "--bad"], options: .init()))
        XCTAssertFalse(try clusterStatusCommand(arguments: ["other"], options: .init()))
    }
}
