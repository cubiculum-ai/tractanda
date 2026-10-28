import CTractandaPlatform
import XCTest

@testable import TractandaCore

/// Current personal stores never acquire the retired metadata-audit intake by calling its APIs.
/// Historical positive flows and their current-invariant mappings are recorded in
/// docs/historical-authority-test-retirement.md; retained format/codec tests remain active.
final class RetiredAuthorityEntryPointTests: XCTestCase {
    final class Fixture {
        let root: URL
        let storeRoot: URL
        let accounts = PeerIntakeStoreTests.Accounts()
        var store: ItemStore!
        let revision: Revision
        static var policy: ItemValue {
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice"), .text("bob")]),
            ])
        }
        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            root = try GuardedFixtureDirectory.create(
                prefix: "retired-intake-", source: #filePath, test: #function)
            storeRoot = root.appendingPathComponent("store")
            store = try ItemStore.initializeFresh(
                root: storeRoot, accounts: accounts, initialAccessConfiguration: Self.policy)
            revision = try store.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("ordinary personal history")],
                    operationID: "retired-intake-content")
            ).revision
        }
        deinit {
            store = nil
            try? FileManager.default.removeItem(at: root)
        }
        func context() throws -> PeerPackage.Context {
            try .init(
                peerID: "retired-peer", storeID: store.personalSyncIdentity().storeID,
                configurationDigest: String(repeating: "a", count: 64),
                permittedOrigins: [UUID.makeVersion1().uuidString.lowercased()])
        }
        /// Include SQLite, retry/configuration files, canonical records and every other regular
        /// file. These refused APIs must not even change disposable bookkeeping.
        func fingerprint() throws -> [String: String] {
            try Self.fingerprint(storeRoot)
        }
        static func fingerprint(_ root: URL) throws -> [String: String] {
            var result: [String: String] = [:]
            var bytes: UInt64 = 0
            let entries = try XCTUnwrap(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let path as URL in entries {
                let metadata = try FileMetadata.read(at: path)
                let relative = String(path.path.dropFirst(root.path.count + 1))
                if metadata.type == .directory {
                    result[relative + "/"] = String(metadata.mode)
                    continue
                }
                guard metadata.type == .regular,
                    metadata.size <= AttachmentFixtureCapacity.fixtureCapBytes
                        - min(bytes, AttachmentFixtureCapacity.fixtureCapBytes)
                else { throw TractandaError("fixture", "Unexpected or oversized personal fixture object") }
                bytes += metadata.size
                result[relative] =
                    String(metadata.mode) + ":" + String(metadata.size) + ":"
                    + AuthorityRecordCodec.sha256(try Data(contentsOf: path))
            }
            return result
        }
    }

    private func assertDisabled(
        _ operation: (Fixture) throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let f = try Fixture()
        let identity = try f.store.personalSyncIdentity()
        let before = try f.fingerprint()
        XCTAssertThrowsError(try operation(f), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerIntakeDisabled", file: file, line: line)
        }
        XCTAssertEqual(
            try f.fingerprint(), before, "Refused metadata intake changed store bytes or modes", file: file,
            line: line)
        XCTAssertEqual(try f.store.personalSyncIdentity(), identity, file: file, line: line)
        XCTAssertEqual(try f.store.get(f.revision.itemID), f.revision, file: file, line: line)
        XCTAssertEqual(try f.store.history(f.revision.itemID), [f.revision], file: file, line: line)
        XCTAssertFalse(try f.store.verificationSnapshot().authorityEnforced, file: file, line: line)
    }

    func testPersonalStoreRejectsLegacyPeerConfigurationWithoutAnyMutation() throws {
        try assertDisabled { try $0.store.configurePeerIntake(peers: [$0.context()]) }
    }

    func testPersonalStoreRejectsLegacyRetirementWithoutAnyMutation() throws {
        try assertDisabled {
            try $0.store.removePeerIntake(
                peerID: "retired-peer", retiredOriginIDs: [UUID.makeVersion1().uuidString.lowercased()],
                operationID: UUID.makeVersion1().uuidString.lowercased())
        }
    }

    func testPersonalStoreRejectsLegacyCredentialRotationWithoutAnyMutation() throws {
        try assertDisabled {
            try $0.store.rotatePeerIntakeCredential(
                peerID: "retired-peer", replacement: $0.context(),
                operationID: UUID.makeVersion1().uuidString.lowercased())
        }
    }

    func testPersonalStoreRejectsLegacyEnrollmentBeforeChangingSourceOrPreparedTarget() throws {
        let f = try PeerEnrollmentApprovalTests.Fixture()
        let identity = try f.source.personalSyncIdentity()
        let before = try Fixture.fingerprint(f.root)
        XCTAssertThrowsError(try f.begin()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerIntakeDisabled")
        }
        XCTAssertEqual(try Fixture.fingerprint(f.root), before)
        XCTAssertEqual(try f.source.personalSyncIdentity(), identity)
        XCTAssertFalse(try f.source.verificationSnapshot().authorityEnforced)
    }
}
