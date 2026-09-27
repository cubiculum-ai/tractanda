import XCTest

@testable import TractandaCore

final class BoundedHeadCacheTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-head-cache-\(Identifier.make())")
    }

    func testEvictedHeadReloadPreservesArbitraryCanonicalFields() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        var firstID: String?
        var firstRequest: CommitRequest?
        let custom = ItemValue.object(["arbitrary": .list([.text("retained"), .integer(42)])])
        for number in 0..<140 {
            let request = CommitRequest(
                classID: "Item",
                changes: ["body": .text("body-\(number)"), "customField": custom],
                operationID: "head-cache-\(number)"
            )
            let revision = try store.commit(request).revision
            if number == 0 {
                firstID = revision.itemID
                firstRequest = request
            }
        }
        XCTAssertLessThanOrEqual(store.currentHeadCacheEntriesForTesting, 128)
        XCTAssertLessThanOrEqual(store.currentHeadCacheBytesForTesting, 4 * 1024 * 1024)

        let reloaded = try store.get(try XCTUnwrap(firstID))
        XCTAssertEqual(reloaded.fields["body"], .text("body-0"))
        XCTAssertEqual(reloaded.fields["customField"], custom)
        XCTAssertEqual(try store.history(reloaded.itemID).map(\.revisionID), [reloaded.revisionID])
        XCTAssertTrue(try store.commit(try XCTUnwrap(firstRequest)).wasReplayed)
        XCTAssertLessThanOrEqual(store.currentHeadCacheEntriesForTesting, 128)
        XCTAssertLessThanOrEqual(store.currentHeadCacheBytesForTesting, 4 * 1024 * 1024)
    }
}
