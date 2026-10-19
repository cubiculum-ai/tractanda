import CTractandaPlatform
import Foundation
import XCTest
@testable import TractandaCore

final class PeerOperatorStatusTests: XCTestCase {
    func testCanonicalSummaryRequiresExplicitCurrentAdminAndNeverLoadsKeys() throws {
        let root = try GuardedFixtureDirectory.create(prefix: "o", source: "PeerOperatorStatusTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try PeerIntakeStoreTests.Fixture(directory: root); try f.bootstrap()
        XCTAssertThrowsError(try f.receiver.peerOperatorCanonicalStatus())
        XCTAssertThrowsError(try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.peerOperatorCanonicalStatus()
        }) { XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden") }
        let secret = [UInt8](repeating: 0x5a, count: 32)
        let credential = try PeerCredential(binding: .init(peerID: f.context.peerID, storeID: f.storeID,
            localReplicaID: XCTUnwrap(f.receiver.replicaID), remoteReplicaID: f.origin,
            pairingID: PeerIntakeStoreTests.Fixture.id(), localIsInitiator: false,
            configurationDigest: f.context.configurationDigest), secret: secret)
        try f.receiver.withAccess(forUID: f.receiver.ownerUID) {
            try f.receiver.registerPeerCredential(credential, context: f.context,
                expectedContextToken: f.receiver.peerIntakeContextToken(), operationID: PeerIntakeStoreTests.Fixture.id())
        }
        let path = try PeerCredentialStore.path(peerID: f.context.peerID,
            configurationDigest: f.context.configurationDigest).reduce(f.receiverRoot) { $0.appendingPathComponent($1) }
        try FileManager.default.removeItem(at: path)
        let status = try f.receiver.withAccess(forUID: f.receiver.ownerUID) { try f.receiver.peerOperatorCanonicalStatus() }
        XCTAssertEqual(status.storeID, f.storeID); XCTAssertEqual(status.replicaID, f.receiver.replicaID)
        XCTAssertEqual(status.readiness, .ready); XCTAssertEqual(status.localDisposed, false)
        XCTAssertEqual(status.configuredPairingCount, 1); XCTAssertEqual(status.committedPairingCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "Read-only diagnostics cannot repair private keys.")
        let json = String(decoding: try JSON.encode(status), as: UTF8.self)
        for prohibited in [String(decoding: secret, as: UTF8.self), "configurationDigest", "securityToken", "privateBytesDigest", "credentials"] {
            XCTAssertFalse(json.contains(prohibited))
        }
        try f.capacity()
    }
    func testPendingTargetDiagnosticCannotCreateActivationOrOpenOrdinaryService() throws {
        try AttachmentFixtureCapacity.requireFree()
        // One fresh source and one prepared target are estimated below 16 MiB.
        guard UInt64(16 * 1024 * 1024) <= AttachmentFixtureCapacity.fixtureCapBytes else {
            throw TractandaError("resourceLimit", "Status fixture estimate exceeds its cap.")
        }
        let root = try GuardedFixtureDirectory.create(prefix: "o", source: "PeerOperatorStatusTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = PeerEnrollmentApprovalTests.Accounts()
        let sourceRoot = root.appendingPathComponent("source"), targetRoot = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var source: ItemStore! = try ItemStore.initializeFresh(root: sourceRoot, accounts: accounts,
            initialAccessConfiguration: PeerEnrollmentApprovalTests.Fixture.policy)
        defer { source = nil }
        func capacity() throws {
            try AttachmentFixtureCapacity.requireFree(at: root)
            var bytes: UInt64 = 0
            let scan = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            while let file = scan.nextObject() as? URL {
                let metadata = try FileMetadata.read(at: file)
                if metadata.type == .regular {
                    guard metadata.size <= AttachmentFixtureCapacity.fixtureCapBytes - min(bytes, AttachmentFixtureCapacity.fixtureCapBytes)
                    else { throw TractandaError("resourceLimit", "Tiny status fixture exceeded its cap.") }
                    bytes += metadata.size
                }
            }
        }
        let storeID = try CanonicalReaderRequirement.storeIdentity(root: sourceRoot, ownerUID: source.ownerUID)
        let origin = try XCTUnwrap(source.replicaID)
        let preparation = try PeerEnrollment.prepareTarget(root: targetRoot, commonStoreID: storeID, sourceReplicaID: origin)
        let local = try PeerPackage.Context(peerID: "target", storeID: storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("status-source".utf8)), permittedOrigins: [preparation.targetReplicaID])
        let remote = try PeerPackage.Context(peerID: "source", storeID: storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("status-target".utf8)), permittedOrigins: [origin])
        let pairing = try PeerEnrollmentApprovalTests.Fixture.id()
        let request = try PeerEnrollmentApproval.Request(operationID: PeerEnrollmentApprovalTests.Fixture.id(),
            preparationBytes: JSON.encode(preparation), sourceContext: local, targetContext: remote,
            sourceCredential: .init(binding: .init(peerID: local.peerID, storeID: storeID,
                localReplicaID: origin, remoteReplicaID: preparation.targetReplicaID, pairingID: pairing,
                localIsInitiator: true, configurationDigest: local.configurationDigest), secret: Array(0..<32)),
            targetCredential: .init(binding: .init(peerID: remote.peerID, storeID: storeID,
                localReplicaID: preparation.targetReplicaID, remoteReplicaID: origin, pairingID: pairing,
                localIsInitiator: false, configurationDigest: remote.configurationDigest), secret: Array(0..<32)))
        let handle = try source.beginPeerEnrollment(request, forUID: accounts.human)
        var ready = false
        for _ in 0..<1024 {
            try capacity()
            if try source.stepPeerEnrollment(handle, forUID: accounts.human,
                window: .init(maximumUnits: 4, maximumEdges: 8)).manifest != nil { ready = true; break }
        }
        XCTAssertTrue(ready)
        let accepted = try source.acceptPeerEnrollment(handle, forUID: accounts.human)
        let material = try source.peerEnrollmentActivationMaterial(handle, forUID: accounts.human)
        let bootstrap = try AuthorityRecord.list(AuthorityRecordCodec.decode(material.proof.approvalBytes).record.payload["bootstrap"])
        let pin = try PeerEnrollmentActivation.Pin(sourceReplicaID: origin,
            bootstrap: AuthorityBinding(value: XCTUnwrap(bootstrap.first)), approval: XCTUnwrap(accepted.approval))
        let record = try PeerEnrollmentActivation.makeRecord(material, pin: pin)
        var pending: ItemStore! = try ItemStore(root: targetRoot, accounts: accounts,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true, firstSourceOperation: nil,
            targetProvisioning: .init(record: record, credential: material.targetCredential))
        defer { pending = nil }
        let activation = targetRoot.appendingPathComponent(PeerEnrollmentActivation.directory + "/activated.json")
        let status = try pending.withAccess(forUID: pending.ownerUID) { try pending.peerOperatorCanonicalStatus() }
        XCTAssertEqual(status.readiness, .pendingActivation); XCTAssertNil(status.localDisposed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: activation.path))
        XCTAssertThrowsError(try ItemStore.requireInitializedRoot(targetRoot))
        try capacity()
    }
    func testCompatibilityDiagnosticsRetainOnlyExplicitSafeCodes() throws {
        for code in ["incompatiblePeer", "peerCompatibilityRequired", "incompatibleCanonicalReader", "unknownCanonicalCompatibility"] {
            XCTAssertEqual(PeerSynchronizationStatus.safeCode(code), code)
        }
        XCTAssertEqual(PeerSynchronizationStatus.safeCode("remote-injected compatibility details"), "peerRuntimeUnavailable")
    }

    func testDiagnosticBoundsAndUnsafeErrorDetailsAreNotSerialized() throws {
        XCTAssertThrowsError(try PeerSynchronizationStatus(state: .active, activeJobCount: 3))
        XCTAssertThrowsError(try PeerSynchronizationStatus(state: .active, eligibleEdgeCount: 257))
        XCTAssertThrowsError(try PeerSynchronizationStatus(state: .active, outcomeCounts: ["private-path": 1]))
        let sync = try PeerSynchronizationStatus(state: .unavailable, lastErrorCode: "/private/key content")
        XCTAssertEqual(sync.lastErrorCode, "peerRuntimeUnavailable")
        let untrusted = try PeerSynchronizationStatus(state: .active, lastErrorCode: "arbitraryPrivateTokenABC123")
        XCTAssertEqual(untrusted.lastErrorCode, "peerRuntimeUnavailable")
        XCTAssertThrowsError(try PeerOperatorRuntimeStatus(state: .active, incomingConnectionCount: 65, synchronization: sync))
    }
}

extension PeerOperatorStatusTests {
    func testLoadedConfigurationStatusRejectsMalformedPathDigestAndAbsentFacts() throws {
        func make(_ path: String?, _ digest: String?) throws -> PeerOperatorRuntimeStatus {
            try .init(state: .active, configurationPath: path, settingsDigest: digest,
                synchronizationEnabled: false, listenerConfigured: false, synchronization: .init(state: .disabled))
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
        XCTAssertThrowsError(try JSONDecoder().decode(PeerOperatorRuntimeStatus.self, from: JSONSerialization.data(withJSONObject: object)))
        object["synchronizationEnabled"] = false; object["settingsDigest"] = "invalid"
        XCTAssertThrowsError(try JSONDecoder().decode(PeerOperatorRuntimeStatus.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
