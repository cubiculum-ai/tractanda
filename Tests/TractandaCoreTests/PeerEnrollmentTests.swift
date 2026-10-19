import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PeerEnrollmentTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let common = try! UUID.makeVersion1().uuidString.lowercased()
        let source = try! UUID.makeVersion1().uuidString.lowercased()
        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
                "enrollment-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        var intent: URL { root.appendingPathComponent(PeerEnrollment.intentName) }
        func prepare(
            allocate: (() throws -> UUID)? = nil,
            afterLock: (() throws -> Void)? = nil, before: (() throws -> Void)? = nil,
            after: (() throws -> Void)? = nil
        ) throws -> PeerEnrollment.Preparation {
            try AttachmentFixtureCapacity.requireFree(at: root)
            return try PeerEnrollment.prepareTarget(
                root: root, commonStoreID: common,
                sourceReplicaID: source, allocate: allocate ?? UUID.makeVersion1,
                afterLockAcquisition: afterLock, beforeIntentPublication: before,
                afterIntentPublication: after)
        }
        func write(_ bytes: Data, _ name: String, mode: Int = 0o400) throws {
            try AttachmentFixtureCapacity.requireFree(at: root)
            guard bytes.count <= 8192 else {
                throw TractandaError("fixtureLimit", "Fixture exceeds tiny cap.")
            }
            let path = root.appendingPathComponent(name)
            try bytes.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path.path)
        }
        func names() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        }
    }
    private func code(
        _ expected: String, _ body: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }
    func testCommonStoreDistinctUUIDv1AndExactRestartRetry() throws {
        let f = try Fixture()
        let value = try f.prepare()
        XCTAssertEqual(value.commonStoreID, f.common)
        XCTAssertEqual(value.sourceReplicaID, f.source)
        let ids = [value.commonStoreID, value.sourceReplicaID, value.targetReplicaID, value.operationID]
        XCTAssertEqual(Set(ids).count, 4)
        for id in ids { XCTAssertNotNil(UUID(uuidString: id)?.version1Components) }
        XCTAssertEqual(try f.names(), [PeerEnrollment.intentName, ".writer.lock"])
        let before = try Data(contentsOf: f.intent)
        let retry = try f.prepare(allocate: {
            XCTFail("Retry must not allocate")
            return UUID()
        })
        XCTAssertEqual(retry, value)
        XCTAssertEqual(try Data(contentsOf: f.intent), before)
        XCTAssertEqual(try FileMetadata.read(at: f.intent).mode & 0o777, 0o400)
    }
    func testPostPublicationInterruptionAndExactHardlinkAliasRetry() throws {
        let f = try Fixture()
        code("interrupted") {
            _ = try f.prepare(after: { throw TractandaError("interrupted", "durable boundary") })
        }
        let before = try Data(contentsOf: f.intent)
        let alias = f.root.appendingPathComponent(".dependency-" + UUID().uuidString + ".tmp")
        XCTAssertEqual(link(f.intent.path, alias.path), 0)
        let retry = try f.prepare(allocate: {
            XCTFail("Published intent is authoritative")
            return UUID()
        })
        XCTAssertEqual(try JSON.encode(retry), before)
        XCTAssertEqual(try Data(contentsOf: alias), before)
        code("enrollmentPending") { _ = try ItemStore(root: f.root) }
    }
    func testPendingRejectsEveryOpeningModeBeforeCanonicalOrExternalIndexEffects() throws {
        let f = try Fixture()
        _ = try f.prepare()
        let before = try f.names()
        let bytes = try Data(contentsOf: f.intent)
        let external = f.root.deletingLastPathComponent().appendingPathComponent(
            "unused-index-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: external) }
        for authority in [false, true] {
            code("enrollmentPending") {
                _ = try ItemStore(
                    root: f.root, indexDirectory: external,
                    revisionProjectionEnabled: authority, authorityIntakeEnabled: authority)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
            XCTAssertEqual(try f.names(), before)
            XCTAssertEqual(try Data(contentsOf: f.intent), bytes)
        }
        // Releasing Store's failed-init lock must allow exact preparation retry.
        _ = try f.prepare()
    }
    func testChangedRequestConflictsWithoutMutation() throws {
        let f = try Fixture()
        _ = try f.prepare()
        let bytes = try Data(contentsOf: f.intent)
        let before = try f.names()
        for changed in [true, false] {
            code("enrollmentConflict") {
                _ = try PeerEnrollment.prepareTarget(
                    root: f.root,
                    commonStoreID: changed ? try UUID.makeVersion1().uuidString.lowercased() : f.common,
                    sourceReplicaID: changed ? f.source : try UUID.makeVersion1().uuidString.lowercased())
            }
        }
        XCTAssertEqual(try Data(contentsOf: f.intent), bytes)
        XCTAssertEqual(try f.names(), before)
    }
    func testForeignPopulatedCloneAndDisposalEvidenceNeverAdopted() throws {
        for name in [
            "items", "authority", ".tractanda-store-identity.json",
            ReplicaIdentity.name, ".peer-credentials", ".disposed.json", ".dependency-orphan.tmp",
        ] {
            let f = try Fixture()
            try f.write(Data("preserve".utf8), name)
            let before = try f.names()
            XCTAssertThrowsError(try f.prepare())
            XCTAssertEqual(try f.names(), before)  // Rejection must not even create the lock.
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(name)), Data("preserve".utf8))
        }
        let f = try Fixture()
        var store: ItemStore? = try AttachmentFixtureCapacity.makeStore(root: f.root)
        XCTAssertNotNil(store)
        store = nil
        let names = try f.names()
        let identity = f.root.appendingPathComponent(".tractanda-store-identity.json")
        let bytes = try Data(contentsOf: identity)
        XCTAssertThrowsError(try f.prepare())
        XCTAssertEqual(try f.names(), names)
        XCTAssertEqual(try Data(contentsOf: identity), bytes)
    }
    func testMalformedOversizedNoncanonicalAndUnsafeIntentCloseOrdinaryGate() throws {
        let cases = [Data("{".utf8), Data(repeating: 32, count: 4097), Data("{}".utf8)]
        for bytes in cases {
            let f = try Fixture()
            try f.write(bytes, PeerEnrollment.intentName)
            let before = try f.names()
            XCTAssertThrowsError(try f.prepare())
            XCTAssertThrowsError(try ItemStore(root: f.root))
            XCTAssertEqual(try f.names().subtracting([".writer.lock"]), before)
            XCTAssertEqual(try Data(contentsOf: f.intent), bytes)
        }
        let f = try Fixture()
        let original = try f.prepare()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSON.encode(original)) as? [String: Any])
        object["unexpected"] = true
        try f.write(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), PeerEnrollment.intentName)
        XCTAssertThrowsError(try f.prepare())
        XCTAssertThrowsError(try ItemStore(root: f.root))
        try f.write(JSON.encode(original), PeerEnrollment.intentName, mode: 0o600)
        XCTAssertThrowsError(try f.prepare())
        XCTAssertThrowsError(try ItemStore(root: f.root))
    }
    func testSymlinkRootIntentAndLockAndUnsafeRootPermissionsFailClosed() throws {
        let f = try Fixture()
        let other = try Fixture()
        let linkRoot = f.root.appendingPathComponent("link")
        XCTAssertEqual(symlink(other.root.path, linkRoot.path), 0)
        XCTAssertThrowsError(
            try PeerEnrollment.prepareTarget(
                root: linkRoot,
                commonStoreID: f.common, sourceReplicaID: f.source))
        XCTAssertEqual(try other.names(), [])
        try FileManager.default.removeItem(at: linkRoot)
        try other.write(Data("private".utf8), "target")
        XCTAssertEqual(symlink(other.root.appendingPathComponent("target").path, f.intent.path), 0)
        XCTAssertThrowsError(try f.prepare())
        XCTAssertThrowsError(try ItemStore(root: f.root))
        XCTAssertEqual(try other.names(), ["target"])
        try FileManager.default.removeItem(at: f.intent)
        let lock = f.root.appendingPathComponent(".writer.lock")
        try FileManager.default.removeItem(at: lock)
        XCTAssertEqual(symlink(other.root.appendingPathComponent("target").path, lock.path), 0)
        XCTAssertThrowsError(try f.prepare())
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
        XCTAssertThrowsError(try f.prepare())
        XCTAssertEqual(try f.names(), [])
    }
    func testLockContentionAndUnexpectedAliasPreserveIntent() throws {
        let f = try Fixture()
        _ = try f.prepare()
        let before = try Data(contentsOf: f.intent)
        let lock = tractanda_lock(f.root.appendingPathComponent(".writer.lock").path)
        XCTAssertGreaterThanOrEqual(lock, 0)
        code("storeBusy") { _ = try f.prepare() }
        _ = tractanda_unlock(lock)
        _ = try f.prepare()
        try f.write(before, ".dependency-unrelated.tmp")  // Same bytes, different inode is foreign.
        XCTAssertThrowsError(try f.prepare())
        XCTAssertEqual(try Data(contentsOf: f.intent), before)
    }
    func testLockedRecheckUsesFreshDirectoryScan() throws {
        let f = try Fixture()
        XCTAssertThrowsError(
            try f.prepare(afterLock: {
                try f.write(Data("new foreign data".utf8), "foreign")
            }))
        XCTAssertEqual(try f.names(), [".writer.lock", "foreign"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.intent.path))
    }

    func testPinnedPublicationCannotWriteIntoReplacedRootPath() throws {
        let f = try Fixture()
        let moved = f.root.deletingLastPathComponent().appendingPathComponent(
            "moved-enrollment-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: moved) }
        let value = try f.prepare(before: {
            try FileManager.default.moveItem(at: f.root, to: moved)
            try FileManager.default.createDirectory(
                at: f.root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try f.write(Data("preserve replacement".utf8), "foreign")
        })
        XCTAssertEqual(try f.names(), ["foreign"])
        XCTAssertEqual(
            try Data(contentsOf: f.root.appendingPathComponent("foreign")),
            Data("preserve replacement".utf8))
        let bytes = try Data(contentsOf: moved.appendingPathComponent(PeerEnrollment.intentName))
        XCTAssertEqual(try JSON.decode(PeerEnrollment.Preparation.self, bytes), value)
        XCTAssertEqual(
            try PeerEnrollment.prepareTarget(
                root: moved,
                commonStoreID: f.common, sourceReplicaID: f.source), value)
    }

    func testExternalIntentHardlinkAndExcessAliasesAreRejected() throws {
        let f = try Fixture()
        let other = try Fixture()
        _ = try f.prepare()
        let external = other.root.appendingPathComponent("outside")
        XCTAssertEqual(link(f.intent.path, external.path), 0)
        code("invalidEnrollmentTarget") { _ = try f.prepare() }
        try FileManager.default.removeItem(at: external)
        _ = try f.prepare()
        for number in 0..<2 {
            let alias = f.root.appendingPathComponent(".dependency-\(number).tmp")
            XCTAssertEqual(link(f.intent.path, alias.path), 0)
        }
        code("invalidEnrollmentTarget") { _ = try f.prepare() }
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(".writer.lock"))
        code("invalidEnrollmentTarget") { _ = try f.prepare() }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".writer.lock").path))
    }

    func testInvalidIdentityAndAllocationCollisionNeverPublishIntent() throws {
        let f = try Fixture()
        for id in [UUID().uuidString.lowercased(), f.common.uppercased(), "invalid"] {
            XCTAssertThrowsError(
                try PeerEnrollment.prepareTarget(
                    root: f.root,
                    commonStoreID: id, sourceReplicaID: f.source))
        }
        XCTAssertEqual(try f.names(), [])
        code("identifierCollision") { _ = try f.prepare(allocate: { UUID(uuidString: f.source)! }) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.intent.path))
        _ = try f.prepare()
    }
}
