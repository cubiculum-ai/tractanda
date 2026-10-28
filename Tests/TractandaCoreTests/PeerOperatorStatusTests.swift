import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class PeerOperatorStatusTests: XCTestCase {
    func testCanonicalSummaryRequiresExplicitCurrentAdminAndNeverLoadsKeys() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "o", source: "PeerOperatorStatusTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try PeerIntakeStoreTests.Fixture(directory: root)
        try f.bootstrap()
        XCTAssertThrowsError(try f.receiver.peerOperatorCanonicalStatus())
        XCTAssertThrowsError(
            try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.peerOperatorCanonicalStatus()
            }
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        let secret = [UInt8](repeating: 0x5a, count: 32)
        let credential = try PeerCredential(
            binding: .init(
                peerID: f.context.peerID, storeID: f.storeID,
                localReplicaID: XCTUnwrap(f.receiver.replicaID), remoteReplicaID: f.origin,
                pairingID: PeerIntakeStoreTests.Fixture.id(), localIsInitiator: false,
                configurationDigest: f.context.configurationDigest), secret: secret)
        try f.receiver.withAccess(forUID: f.receiver.ownerUID) {
            try f.receiver.registerPeerCredential(
                credential, context: f.context,
                expectedContextToken: f.receiver.peerIntakeContextToken(),
                operationID: PeerIntakeStoreTests.Fixture.id())
        }
        let path = try PeerCredentialStore.path(
            peerID: f.context.peerID,
            configurationDigest: f.context.configurationDigest
        ).reduce(f.receiverRoot) { $0.appendingPathComponent($1) }
        try FileManager.default.removeItem(at: path)
        let status = try f.receiver.withAccess(forUID: f.receiver.ownerUID) {
            try f.receiver.peerOperatorCanonicalStatus()
        }
        XCTAssertEqual(status.storeID, f.storeID)
        XCTAssertEqual(status.replicaID, f.receiver.replicaID)
        XCTAssertEqual(status.readiness, .ready)
        XCTAssertEqual(status.localDisposed, false)
        XCTAssertEqual(status.configuredPairingCount, 1)
        XCTAssertEqual(status.committedPairingCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path.path),
            "Read-only diagnostics cannot repair private keys.")
        let json = String(decoding: try JSON.encode(status), as: UTF8.self)
        for prohibited in [
            String(decoding: secret, as: UTF8.self), "configurationDigest", "securityToken",
            "privateBytesDigest", "credentials",
        ] {
            XCTAssertFalse(json.contains(prohibited))
        }
        try f.capacity()
    }
    func testCompatibilityDiagnosticsRetainOnlyExplicitSafeCodes() throws {
        for code in [
            "incompatiblePeer", "peerCompatibilityRequired", "incompatibleCanonicalReader",
            "unknownCanonicalCompatibility",
        ] {
            XCTAssertEqual(PeerSynchronizationStatus.safeCode(code), code)
        }
        XCTAssertEqual(
            PeerSynchronizationStatus.safeCode("remote-injected compatibility details"),
            "peerRuntimeUnavailable")
    }

    func testDiagnosticBoundsAndUnsafeErrorDetailsAreNotSerialized() throws {
        XCTAssertThrowsError(try PeerSynchronizationStatus(state: .active, activeJobCount: 3))
        XCTAssertThrowsError(try PeerSynchronizationStatus(state: .active, eligibleEdgeCount: 257))
        XCTAssertThrowsError(
            try PeerSynchronizationStatus(state: .active, outcomeCounts: ["private-path": 1]))
        let sync = try PeerSynchronizationStatus(state: .unavailable, lastErrorCode: "/private/key content")
        XCTAssertEqual(sync.lastErrorCode, "peerRuntimeUnavailable")
        let untrusted = try PeerSynchronizationStatus(
            state: .active, lastErrorCode: "arbitraryPrivateTokenABC123")
        XCTAssertEqual(untrusted.lastErrorCode, "peerRuntimeUnavailable")
        XCTAssertThrowsError(
            try PeerOperatorRuntimeStatus(state: .active, incomingConnectionCount: 65, synchronization: sync))
    }
}

extension PeerOperatorStatusTests {
    func testLoadedConfigurationStatusRejectsMalformedPathDigestAndAbsentFacts() throws {
        func make(_ path: String?, _ digest: String?) throws -> PeerOperatorRuntimeStatus {
            try .init(
                state: .active, configurationPath: path, settingsDigest: digest,
                synchronizationEnabled: false, listenerConfigured: false,
                synchronization: .init(state: .disabled))
        }
        let digest = String(repeating: "a", count: 64)
        let value = try make("/protected/peer.json", digest)
        let bytes = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(PeerOperatorRuntimeStatus.self, from: bytes)
        XCTAssertEqual(decoded.configurationPath, value.configurationPath)
        XCTAssertEqual(decoded.settingsDigest, digest)
        for path in ["relative", "/bad\npath", "/bad\0path", "/" + String(repeating: "a", count: 4096)] {
            XCTAssertThrowsError(try make(path, digest))
        }
        for invalid in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 63)] {
            XCTAssertThrowsError(try make("/peer", invalid))
        }
        XCTAssertThrowsError(try make(nil, digest))
        XCTAssertThrowsError(try make("/peer", nil))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "synchronizationEnabled")
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PeerOperatorRuntimeStatus.self, from: JSONSerialization.data(withJSONObject: object)))
        object["synchronizationEnabled"] = false
        object["settingsDigest"] = "invalid"
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PeerOperatorRuntimeStatus.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
