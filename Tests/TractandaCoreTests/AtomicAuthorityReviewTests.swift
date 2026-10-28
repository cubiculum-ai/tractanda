import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class AtomicAuthorityReviewTests: XCTestCase {
    private func canonicalHashes(_ root: URL) throws -> [String: String] {
        try AttachmentFixtureCapacity.requireFree(at: root)
        var result: [String: String] = [:]
        var total: UInt64 = 0
        for case let file as URL in try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        {
            let metadata = try FileMetadata.read(at: file)
            guard metadata.type == .regular else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if relative == StoreCheckpoint.name { continue }
            if [
                "index/items.sqlite", "index/items.sqlite-wal", "index/items.sqlite-shm",
                "index/items.sqlite-journal",
            ].contains(relative) {
                continue
            }
            if relative.hasPrefix("index/rebuild-"), !relative.dropFirst(6).contains("/") {
                var name = String(relative.dropFirst("index/rebuild-".count))
                for suffix in ["-wal", "-shm", "-journal"] where name.hasSuffix(suffix) {
                    name.removeLast(suffix.count)
                    break
                }
                if name.hasSuffix(".sqlite") {
                    name.removeLast(".sqlite".count)
                    if UUID(uuidString: name) != nil { continue }
                }
            }
            guard
                metadata.size <= AttachmentFixtureCapacity.fixtureCapBytes
                    - min(total, AttachmentFixtureCapacity.fixtureCapBytes)
            else {
                throw TractandaError("resourceLimit", "Tiny review canonical hash cap")
            }
            total += metadata.size
            result[relative] = AuthorityRecordCodec.sha256(try Data(contentsOf: file))
        }
        XCTAssertTrue(result.keys.contains { $0.contains("/atomic-accepted/") })
        XCTAssertTrue(result.keys.contains { $0.hasPrefix(".peer-configuration/") })
        return result
    }
    private func assertCanonicalHashes(
        _ root: URL, expected: [String: String], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let actual = try canonicalHashes(root)
        let changed = Set(actual.keys).union(expected.keys).filter { actual[$0] != expected[$0] }.sorted()
        XCTAssertTrue(
            changed.isEmpty,
            "Canonical changed paths (\(changed.count)): " + changed.prefix(48).joined(separator: ", "),
            file: file, line: line)
    }
    private func removeDerivedIndex(_ root: URL) throws {
        for name in ["items.sqlite", "items.sqlite-wal", "items.sqlite-shm", "items.sqlite-journal"] {
            let file = root.appendingPathComponent("index").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    func testRealHeldReviewPublishesOneAtomicPairAndExactRetryThenUnrelatedWrite() throws {
        let f = try AuthorityReviewStoreTests.ReviewedFixture()
        defer {
            f.base.receiver = nil
            f.base.source = nil
            if let files = FileManager.default.enumerator(
                at: f.base.directory, includingPropertiesForKeys: nil)
            {
                for case let file as URL in files {
                    if let metadata = try? FileMetadata.read(at: file), metadata.type == .regular {
                        _ = chmod(file.path, 0o600)
                    }
                }
            }
        }
        f.base.source = nil
        f.base.receiver = nil
        try AtomicAuthorityStoreFixture.transition(f.base.sourceRoot)
        try AtomicAuthorityStoreFixture.transition(f.base.receiverRoot)
        f.base.source = try AtomicAuthorityStoreFixture.open(
            f.base.sourceRoot, accounts: f.base.sourceAccounts)
        f.base.receiver = try AtomicAuthorityStoreFixture.open(
            f.base.receiverRoot, accounts: f.base.receiverAccounts)
        let request = try f.request(operation: "real-atomic-reviewed-pair")
        let result: AuthorityStore.ReviewResult
        do { result = try f.base.receiver.resolveAuthorityReview(request) } catch {
            FileHandle.standardError.write(
                Data(("ATOMIC_REVIEW_FIRST_ERROR " + String(reflecting: error) + "\n").utf8))
            throw error
        }
        XCTAssertFalse(result.wasReplayed)
        XCTAssertEqual(result.disposition, .approved)
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, result.revision.revisionID)
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID, revisionID: f.held.revisionID), f.held)
        let replay = try f.base.receiver.resolveAuthorityReview(request)
        XCTAssertTrue(replay.wasReplayed)
        XCTAssertEqual(replay.revision, result.revision)
        let index = try ItemIndex(
            path: f.base.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let origin = try XCTUnwrap(f.base.receiver.replicaID)
        let root = try XCTUnwrap(index.authorityControlHead(originID: origin))
        XCTAssertTrue(try index.isAcceptedAtomicControl(root))
        XCTAssertEqual(try index.eligibilityAtCut(revisionID: f.held.revisionID, cut: root), .eligible)
        XCTAssertEqual(
            try index.eligibilityAtCut(revisionID: result.revision.revisionID, cut: root), .eligible)
        let coordinator = PeerIntakeCoordinator(
            root: f.base.receiverRoot, ownerUID: tractanda_uid(), storeID: f.base.storeID)
        let raw = try XCTUnwrap(index.retainedAuthorityObject(id: root.recordID))
        let stage = try AtomicControlStage(rootBytes: coordinator.bytes(raw))
        XCTAssertEqual(stage.effects.entryCount, 2)
        XCTAssertEqual(stage.effects.targetCount, 2)
        XCTAssertEqual(stage.parents.entryCount, 1)
        XCTAssertNotNil(try coordinator.journal.atomicAcceptance(packageID: raw.packageID, root: root))
        index.close()
        let unrelated = try f.base.receiver.commit(
            .init(
                classID: "Item",
                changes: ["subject": .text("unrelated after valid review")],
                operationID: "atomic-review-unrelated"))
        XCTAssertTrue(unrelated.isIndexReady, unrelated.warnings.joined(separator: "\n"))
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, result.revision.revisionID)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.base.receiverRoot))
        f.base.receiver = nil
        let canonical = try canonicalHashes(f.base.receiverRoot)
        try removeDerivedIndex(f.base.receiverRoot)
        f.base.receiver = try AtomicAuthorityStoreFixture.open(
            f.base.receiverRoot, accounts: f.base.receiverAccounts)
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID).revisionID, result.revision.revisionID)
        XCTAssertEqual(
            try f.base.receiver.get(unrelated.revision.itemID).revisionID, unrelated.revision.revisionID)
        XCTAssertEqual(try f.base.receiver.get(f.held.itemID, revisionID: f.held.revisionID), f.held)
        XCTAssertTrue(try f.base.receiver.resolveAuthorityReview(request).wasReplayed)
        f.base.receiver = nil
        try assertCanonicalHashes(f.base.receiverRoot, expected: canonical)
        try f.base.capacity()
    }

}
