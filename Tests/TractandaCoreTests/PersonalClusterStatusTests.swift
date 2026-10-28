import Foundation
import XCTest

@testable import TractandaCore

final class PersonalClusterStatusTests: XCTestCase {
    private func id(_ n: Int) -> String { String(format: "%08x-0000-1000-8000-000000000000", n) }
    func testDeclaredMaximumStatusFitsOneMiBWithoutDroppingMembersOrObservations() throws {
        let storeID = id(1000)
        let host =
            String(repeating: "a", count: 63) + "." + String(repeating: "b", count: 63)
            + "." + String(repeating: "c", count: 63) + "." + String(repeating: "d", count: 57)
        XCTAssertEqual(host.utf8.count, 249)
        let members = try (1...256).map {
            try PersonalMember(replicaID: id($0), hostname: String(format: "%03x", $0) + "." + host)
        }
        let current = try PersonalMembershipConfiguration(
            storeID: storeID, configurationID: id(1001), members: members)
        let pending = try PersonalMembershipConfiguration(
            storeID: storeID, configurationID: id(1002), members: members)
        let max = Int.max
        let observations = try (0..<512).map { n in
            try PersonalPeerObservation(
                replicaID: id(n % 256 + 1),
                configurationDigest: n < 256 ? current.digest : pending.digest, connected: true,
                incomingConnectionCount: 64, outgoingConnectionCount: 64, controlOnly: false,
                pullRunning: true, completedCuts: max,
                currentPull: .init(
                    phase: .checkpointing, revisionCount: max, transferredBytes: Int64.max,
                    lastProgressAt: "2026-10-26T12:34:56Z"), lastConnectedAt: "2026-10-26T12:34:56Z",
                lastDisconnectedAt: "2026-10-26T12:34:56Z", lastPullStartedAt: "2026-10-26T12:34:56Z",
                lastPullFinishedAt: "2026-10-26T12:34:56Z", lastOutcome: .complete,
                lastErrorCode: "unknownCanonicalCompatibility", lastErrorAt: "2026-10-26T12:34:56Z",
                lastRevisionCount: max, lastTransferredBytes: Int64.max,
                lastRevisionOutcomes: [
                    "known": max, "accepted": max, "merged": max, "conflicted": max, "reviewRequired": max,
                ])
        }
        let personal = try PersonalClusterCanonicalStatus(
            storeID: storeID, currentMembership: current,
            pendingMembership: pending, requiredOnlineReplicaIDs: members.map(\.replicaID),
            baselineSourceReplicaID: id(1))
        // Loaded route serialization has its own 128KiB bound, in addition to 256 entries.
        let runtime = try PeerOperatorRuntimeStatus(
            state: .active, configurationPath: "/" + String(repeating: "x", count: 4095),
            settingsDigest: String(repeating: "f", count: 64), synchronization: .init(state: .active),
            configuredPeers: [], personalPeers: observations)
        let status = PeerOperatorStatus(
            canonical: .init(
                storeID: storeID, replicaID: id(1), readiness: .ready,
                localDisposed: nil, configuredPairingCount: nil, committedPairingCount: nil,
                personal: personal), runtime: runtime)
        let bytes = try status.encoded()
        // Reserve the entire independently bounded routes section, not just this empty fixture's bytes.
        XCTAssertLessThan(bytes.count + 128 * 1024 + 1024, PeerOperatorStatus.maximumResponseBytes)
        let decoded = try JSON.decode(PeerOperatorStatus.self, bytes)
        XCTAssertEqual(decoded.canonical.personal?.currentMembership?.members.count, 256)
        XCTAssertEqual(decoded.canonical.personal?.pendingMembership?.members.count, 256)
        XCTAssertEqual(decoded.runtime.personalPeers?.count, 512)
        XCTAssertThrowsError(
            try PeerOperatorRuntimeStatus(
                state: .active, synchronization: .init(state: .active),
                personalPeers: observations + [observations[0]]))
    }
    func testObservationBoundsAndRemoteErrorsCannotLeakTerminalContent() throws {
        let digest = String(repeating: "a", count: 64)
        let observation = try PersonalPeerObservation(
            replicaID: id(1), configurationDigest: digest,
            connected: false, lastErrorCode: String(repeating: "private\u{1b}[31m", count: 10000))
        XCTAssertEqual(observation.lastErrorCode, "peerRuntimeUnavailable")
        XCTAssertNil(observation.lastConnectedAt)
        XCTAssertNil(observation.lastPullFinishedAt)
        XCTAssertThrowsError(
            try PersonalPeerObservation(
                replicaID: id(1), configurationDigest: digest,
                connected: false, lastConnectedAt: "invented"))
        XCTAssertThrowsError(
            try PersonalPeerObservation(
                replicaID: id(1), configurationDigest: digest,
                connected: false, lastRevisionOutcomes: ["remote private detail": 1]))
        XCTAssertThrowsError(
            try PersonalPeerObservation(
                replicaID: id(1), configurationDigest: digest,
                connected: false, lastTransferredBytes: -1))
    }
}
