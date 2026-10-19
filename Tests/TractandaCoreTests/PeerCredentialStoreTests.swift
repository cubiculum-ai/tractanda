import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class PeerCredentialStoreTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private let secret = Array("private-test-key-never-exported!".utf8)
    private func credential(
        _ f: Fixture, context: PeerPackage.Context? = nil, store: String? = nil,
        local: String? = nil, remote: String? = nil, initiator: Bool = false, pairing: String? = nil
    ) throws -> PeerCredential {
        let context = context ?? f.context!
        return try PeerCredential(binding: PeerExchangeBinding(
            peerID: context.peerID, storeID: store ?? f.storeID,
            localReplicaID: local ?? XCTUnwrap(f.receiver.replicaID), remoteReplicaID: remote ?? f.origin,
            pairingID: pairing ?? Fixture.id(), localIsInitiator: initiator,
            configurationDigest: context.configurationDigest), secret: secret)
    }
    private func files(_ root: URL, owner: UInt32 = tractanda_uid()) -> DocumentContentFiles {
        DocumentContentFiles(root: root, ownerUID: owner, minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
    }
    private func register(_ f: Fixture, _ value: PeerCredential, context: PeerPackage.Context? = nil) throws {
        try f.receiver.registerPeerCredential(value, context: context ?? f.context,
            expectedContextToken: f.receiver.peerIntakeContextToken(), operationID: Fixture.id())
    }
    private func path(_ f: Fixture, _ value: PeerCredential) throws -> URL {
        try PeerCredentialStore.path(peerID: value.binding.peerID,
            configurationDigest: value.binding.configurationDigest).reduce(f.receiverRoot) {
            $0.appendingPathComponent($1)
        }
    }
    private func code(_ expected: String, _ body: () throws -> Void,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
            XCTAssertFalse(String(describing: $0).contains(String(decoding: self.secret, as: UTF8.self)))
        }
    }
    func testPersistenceExactRetryRestartAndNoExportOrReflectionLeak() throws {
        let f = try Fixture(); try f.bootstrap()
        XCTAssertEqual(secret.count, 32)
        let value = try credential(f)
        try register(f, value)
        let before = try Data(contentsOf: path(f, value))
        try register(f, value)
        XCTAssertEqual(try Data(contentsOf: path(f, value)), before)
        XCTAssertEqual(Mirror(reflecting: value).children.count, 0)
        XCTAssertEqual(String(reflecting: value), "PeerCredential(<redacted>)")
        for row in try f.receiver.exportCatalogueForVerification() {
            for (_, bytes) in try f.receiver.peerMetadataObjects(revisionID: row.revisionID) {
                XCTAssertNil(bytes.range(of: Data(secret)))
            }
        }
        let inventory = try f.receiver.peerIntakeContextToken()
        XCTAssertFalse(inventory.contains(String(decoding: secret, as: UTF8.self)))
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        let restored = try f.receiver.loadPeerCredential(peerID: f.context.peerID)
        XCTAssertEqual(try restored.commitment, try value.commitment)
        restored.withTLSInput { _, bytes in XCTAssertEqual(bytes, secret) }
        XCTAssertEqual(try Data(contentsOf: path(f, value)), before)
        try f.capacity()
    }
    func testUnboundCurrentConfigAndImmutableSecretConflictPreserveOldEncoding() throws {
        let f = try Fixture(); try f.bootstrap()
        let directory = f.receiverRoot.appendingPathComponent(".peer-configuration")
        let latest = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: directory.path).sorted().last)
        let oldBytes = try Data(contentsOf: directory.appendingPathComponent(latest))
        let old = try JSON.decode(AuthorityStore.Configuration.self, oldBytes)
        XCTAssertNil(old.credentialBindings)
        XCTAssertNil(oldBytes.range(of: Data("credentialBindings".utf8)))
        XCTAssertEqual(try JSON.encode(old), oldBytes)
        XCTAssertEqual(AuthorityRecordCodec.sha256(try JSON.encode(old)), AuthorityRecordCodec.sha256(oldBytes))
        let value = try credential(f), store = PeerCredentialStore(files: files(f.receiverRoot))
        try store.stage(value)
        let staged = try Data(contentsOf: path(f, value))
        code("invalidPeerCredential") { _ = try f.receiver.loadPeerCredential(peerID: f.context.peerID) }
        let conflict = try PeerCredential(binding: value.binding, secret: Array(repeating: 19, count: 32))
        code("invalidPeerCredential") { try store.stage(conflict) }
        XCTAssertEqual(try Data(contentsOf: path(f, value)), staged)
        try register(f, value)
        XCTAssertEqual(try f.receiver.loadPeerCredential(peerID: f.context.peerID).commitment, try value.commitment)
    }
    func testWrongStoreActualReplicasAndGenerationCannotRegister() throws {
        let f = try Fixture(); try f.bootstrap()
        for value in [
            try credential(f, store: Fixture.id()), try credential(f, local: Fixture.id()),
            try credential(f, remote: Fixture.id()),
        ] { code("invalidPeerCredential") { try register(f, value) } }
        let wrong = try PeerPackage.Context(peerID: f.context.peerID, storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("different-generation".utf8)),
            permittedOrigins: f.context.permittedOrigins)
        code("invalidPeerCredential") { try register(f, credential(f, context: wrong)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.receiverRoot.appendingPathComponent(".peer-credentials").path))
    }
    func testSupportedProfileExactly32BytesAndStrictIdentities() throws {
        let f = try Fixture(); try f.bootstrap()
        let binding = try credential(f).binding
        for length in [0, 31, 33, 4097] {
            code("invalidPeerCredential") { _ = try PeerCredential(binding: binding, secret: Array(repeating: 1, count: length)) }
        }
        code("invalidPeerCredential") { _ = try PeerCredential(binding: binding, profile: "other/1", secret: secret) }
        XCTAssertThrowsError(try PeerExchangeBinding(peerID: "p", storeID: UUID().uuidString.lowercased(),
            localReplicaID: binding.localReplicaID, remoteReplicaID: binding.remoteReplicaID,
            pairingID: binding.pairingID, localIsInitiator: true, configurationDigest: binding.configurationDigest))
    }
    func testCurrentCommitmentRejectsOtherPairingAndRoleAndPrivateFileSwap() throws {
        let f = try Fixture(); try f.bootstrap()
        let value = try credential(f); try register(f, value)
        for other in [try credential(f), try credential(f, initiator: true, pairing: value.binding.pairingID)] {
            code("invalidPeerCredential") { try register(f, other) }
            XCTAssertThrowsError(try f.receiver.withPeerExchange(binding: other.binding, progress: {}) { _, _ in () })
        }
        let original = try path(f, value)
        try FileManager.default.removeItem(at: original)
        let other = try credential(f, initiator: true, pairing: value.binding.pairingID)
        try PeerCredentialStore(files: files(f.receiverRoot)).stage(other)
        code("invalidPeerCredential") { _ = try f.receiver.loadPeerCredential(peerID: f.context.peerID) }
    }
    func testStageInterruptionIsInertAndExactRetryCompletesAfterRestart() throws {
        let f = try Fixture(); try f.bootstrap()
        let context = try PeerPackage.Context(peerID: "new/alias/../../safe", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("new-private-generation".utf8)),
            permittedOrigins: f.context.permittedOrigins)
        let value = try credential(f, context: context)
        f.receiver.peerCredentialStagedForTesting = { throw TractandaError("testStop", "staged") }
        code("testStop") { try register(f, value, context: context) }
        XCTAssertThrowsError(try f.receiver.loadPeerCredential(peerID: context.peerID))
        let names = try FileManager.default.contentsOfDirectory(atPath: f.receiverRoot.appendingPathComponent(".peer-credentials").path)
        XCTAssertEqual(names.count, 1); XCTAssertEqual(names[0].count, 68)
        f.receiver = nil; f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertThrowsError(try f.receiver.loadPeerCredential(peerID: context.peerID))
        try register(f, value, context: context)
        XCTAssertEqual(try f.receiver.loadPeerCredential(peerID: context.peerID).commitment, try value.commitment)
    }
    func testFreshAdministratorAndContextAndDefaultOffRequired() throws {
        let f = try Fixture(); try f.bootstrap()
        let value = try credential(f), token = try f.receiver.peerIntakeContextToken()
        XCTAssertThrowsError(try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.registerPeerCredential(value, context: f.context, expectedContextToken: token,
                operationID: Fixture.id())
        })
        code("operationReviewRequired") {
            try f.receiver.registerPeerCredential(value, context: f.context, expectedContextToken: "stale",
                operationID: Fixture.id())
        }
        f.receiver = nil
        code("authorityModeRequired") {
            _ = try ItemStore(root: f.receiverRoot, accounts: f.receiverAccounts, revisionProjectionEnabled: true)
        }
        try f.capacity()
        let disabled = try ItemStore(root: f.directory.appendingPathComponent("default-off"), accounts: f.receiverAccounts)
        code("peerIntakeDisabled") { _ = try disabled.loadPeerCredential(peerID: f.context.peerID) }
        try f.capacity()
    }
    func testMissingMalformedOversizedAndUnsafeFilesFailClosed() throws {
        let f = try Fixture(); try f.bootstrap()
        let value = try credential(f); try register(f, value)
        let location = try path(f, value), original = try Data(contentsOf: location)
        func replace(_ bytes: Data, mode: Int = 0o400) throws {
            try? FileManager.default.removeItem(at: location)
            try bytes.write(to: location)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: location.path)
        }
        for bytes in [Data(), Data([0, 0, 0, 1]), Data(repeating: 7, count: 4097), original + Data([0])] {
            try replace(bytes)
            code("invalidPeerCredential") { _ = try f.receiver.loadPeerCredential(peerID: f.context.peerID) }
        }
        try replace(original, mode: 0o600)
        code("invalidPeerCredential") { _ = try f.receiver.loadPeerCredential(peerID: f.context.peerID) }
        try replace(original)
        code("invalidPeerCredential") {
            _ = try PeerCredentialStore(files: files(f.receiverRoot, owner: tractanda_uid() &+ 1))
                .load(peerID: f.context.peerID, configurationDigest: f.context.configurationDigest)
        }
        try FileManager.default.removeItem(at: location)
        code("invalidPeerCredential") { _ = try f.receiver.loadPeerCredential(peerID: f.context.peerID) }
        let target = f.directory.appendingPathComponent("secret-target")
        try original.write(to: target); try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: location, withDestinationURL: target)
        code("invalidPeerCredential") { _ = try f.receiver.loadPeerCredential(peerID: f.context.peerID) }
        try FileManager.default.removeItem(at: location)
        let directory = location.deletingLastPathComponent(), moved = f.directory.appendingPathComponent("private-moved")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
        code("invalidPeerCredential") { _ = try f.receiver.loadPeerCredential(peerID: f.context.peerID) }
    }
    func testStrictPrivateMetadataDecodingAndCurrentBinding() throws {
        let f = try Fixture(); try f.bootstrap()
        let value = try credential(f); try register(f, value)
        let location = try path(f, value), original = try Data(contentsOf: location)
        let headerCount = original.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let metadata = try JSONSerialization.jsonObject(with: original.dropFirst(4).prefix(headerCount)) as! [String: Any]
        let canonicalHeader = String(decoding: original.dropFirst(4).prefix(headerCount), as: UTF8.self)
        let duplicateHeader = Data((String(canonicalHeader.dropLast())
            + ",\n\"profile\":\"org.tractanda.peer-proof/1\"\n}").utf8)
        let duplicateCount = UInt32(duplicateHeader.count)
        let duplicate = Data([UInt8(duplicateCount >> 24), UInt8((duplicateCount >> 16) & 255),
            UInt8((duplicateCount >> 8) & 255), UInt8(duplicateCount & 255)]) + duplicateHeader + original.suffix(32)
        try FileManager.default.removeItem(at: location)
        try duplicate.write(to: location)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: location.path)
        code("invalidPeerCredential") { _ = try f.receiver.loadPeerCredential(peerID: f.context.peerID) }
        for field in ["storeID", "localReplicaID", "remoteReplicaID", "pairingID", "configurationDigest",
                      "profile", "format", "unknown", "localIsInitiator"] {
            var changed = metadata
            switch field {
            case "localIsInitiator": changed[field] = true
            case "configurationDigest": changed[field] = String(repeating: "a", count: 64)
            case "profile", "format", "unknown": changed[field] = "unsupported"
            default: changed[field] = try Fixture.id()
            }
            let header = try JSONSerialization.data(withJSONObject: changed,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let count = UInt32(header.count)
            let bytes = Data([UInt8(count >> 24), UInt8((count >> 16) & 255),
                UInt8((count >> 8) & 255), UInt8(count & 255)]) + header + original.suffix(32)
            try FileManager.default.removeItem(at: location)
            try bytes.write(to: location)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: location.path)
            code("invalidPeerCredential") { _ = try f.receiver.loadPeerCredential(peerID: f.context.peerID) }
        }
    }
    func testRotationCrashRecoveryDisposalAndHistoryDoNotNeedOldSecrets() throws {
        let f = try Fixture(); try f.bootstrap()
        let value = try credential(f); try register(f, value)
        let previous = try f.receiver.loadPeerCredential(peerID: f.context.peerID)
        let next = try PeerPackage.Context(peerID: f.context.peerID, storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("private-rotation".utf8)),
            permittedOrigins: f.context.permittedOrigins)
        let replacement = try credential(f, context: next)
        f.receiver.peerLifecycleBoundaryForTesting = { if $0 == .prepared { throw TractandaError("testStop", "prepared") } }
        code("testStop") { try register(f, replacement, context: next) }
        f.receiver = nil; f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.loadPeerCredential(peerID: next.peerID).commitment, try replacement.commitment)
        XCTAssertThrowsError(try f.receiver.withPeerExchange(binding: previous.binding, progress: {}) { _, _ in () })
        try register(f, replacement, context: next)
        try FileManager.default.removeItem(at: path(f, value))
        f.receiver = nil; f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
        XCTAssertEqual(try f.receiver.loadPeerCredential(peerID: next.peerID).commitment, try replacement.commitment)
        try f.receiver.removePeerIntake(peerID: next.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())
        XCTAssertThrowsError(try f.receiver.withPeerExchange(binding: replacement.binding, progress: {}) { _, _ in () })
        f.receiver = nil; f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertThrowsError(try f.receiver.loadPeerCredential(peerID: next.peerID))
        XCTAssertEqual(try f.receiver.get(f.base.itemID, revisionID: f.base.revisionID), f.base)
        try f.capacity()
    }
}
