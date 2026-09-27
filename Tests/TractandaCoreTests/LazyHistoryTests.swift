import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class LazyHistoryTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 50001
        let bob: UInt32 = 50002
        var users: [UInt32: AccountIdentity] = [:]

        init() {
            users[getuid()] = AccountIdentity(
                uid: getuid(), name: "admin", primaryGroupName: "staff", groupIDs: [70001])
            users[alice] = AccountIdentity(
                uid: alice, name: "alice", primaryGroupName: "staff", groupIDs: [70001])
            users[bob] = AccountIdentity(
                uid: bob, name: "bob", primaryGroupName: "staff", groupIDs: [70001])
        }

        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard let user = users[uid] else { throw TractandaError("unresolvedPrincipal", "Unknown user") }
            return user
        }

        func user(named name: String) throws -> AccountIdentity {
            guard let user = users.values.first(where: { $0.name == name }) else {
                throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return user
        }

        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Unknown group") }
            return 70001
        }
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-lazy-history-\(Identifier.make())")
    }

    private func config() -> ItemValue {
        .object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([.text("alice"), .text("bob")]),
        ])
    }

    private func permissions(owner: String = "alice", mode: Int64) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner), "group": .text("staff"),
            "mode": .integer(mode), "acl": .object([:]),
        ])
    }

    private func assertCode(
        _ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, code, "\($0)", file: file, line: line)
        }
    }

    func testExactHistoricalGetAndHistorySurviveRebuildAndReopen() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let itemID: String
        let revisions: [Revision]
        do {
            let store = try ItemStore(root: root)
            let first = try store.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("history-0")], operationID: "history-create")
            ).revision
            var all = [first]
            var current = first
            for index in 1...4 {
                current = try store.commit(
                    CommitRequest(
                        action: .revise, itemID: first.itemID, expectedRevisionID: current.revisionID,
                        changes: ["subject": .text("history-\(index)")], operationID: "history-\(index)")
                ).revision
                all.append(current)
            }
            try store.rebuildIndex()
            for revision in all {
                XCTAssertEqual(try store.get(first.itemID, revisionID: revision.revisionID), revision)
            }
            XCTAssertEqual(try store.history(first.itemID), all.reversed())
            itemID = first.itemID
            revisions = all
        }
        let reopened = try ItemStore(root: root)
        for revision in revisions {
            XCTAssertEqual(try reopened.get(itemID, revisionID: revision.revisionID), revision)
        }
        XCTAssertEqual(try reopened.history(itemID), revisions.reversed())
    }

    func testOldOperationReplayAfterLaterRevisionsReturnsOriginalRevision() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let first = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("initial")], operationID: "replay-create")
        ).revision
        let originalRequest = CommitRequest(
            action: .revise, itemID: first.itemID, expectedRevisionID: first.revisionID,
            changes: ["subject": .text("first edit")], operationID: "replay-this")
        let original = try store.commit(originalRequest).revision
        let later = try store.commit(
            CommitRequest(
                action: .revise, itemID: first.itemID, expectedRevisionID: original.revisionID,
                changes: ["subject": .text("later edit")], operationID: "replay-later")
        ).revision

        let replay = try store.commit(originalRequest)
        XCTAssertTrue(replay.wasReplayed)
        XCTAssertEqual(replay.revision, original)
        XCTAssertEqual(try store.get(first.itemID), later)
        XCTAssertEqual(try store.get(first.itemID, revisionID: original.revisionID), original)
    }

    func testCurrentHeadPermissionRevocationDeniesOldRevisionAndHistory() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try ItemStore(root: root, accounts: accounts)
        _ = try store.configureAccess(config(), operationID: "lazy-history-access")
        let original = try store.withAccess(forUID: accounts.alice) {
            try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text("visible before revocation"),
                        "permissions": permissions(mode: 0o640),
                    ], operationID: "lazy-history-shared")
            ).revision
        }
        try store.withAccess(forUID: accounts.bob) {
            XCTAssertEqual(try store.get(original.itemID, revisionID: original.revisionID), original)
            XCTAssertEqual(try store.history(original.itemID).count, 1)
        }
        _ = try store.withAccess(forUID: accounts.alice) {
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: original.itemID, expectedRevisionID: original.revisionID,
                    changes: ["permissions": permissions(mode: 0o600)], operationID: "lazy-history-revoke"))
        }
        try store.withAccess(forUID: accounts.bob) {
            let hydrationsBeforeDeniedReads = store.currentHeadHydrationsForTesting
            assertCode("forbidden") { _ = try store.get(original.itemID, revisionID: original.revisionID) }
            assertCode("forbidden") { _ = try store.history(original.itemID) }
            XCTAssertEqual(store.currentHeadHydrationsForTesting, hydrationsBeforeDeniedReads)
        }
    }

    func testCorruptEvictedCurrentHeadFailsClosed() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let current = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("damaged"), "body": .text("large body")],
                operationID: "damaged-current-head")
        ).revision
        XCTAssertEqual(store.evictedCurrentHeadCount, 1)
        let items = root.appendingPathComponent("items")
        let recordURLs =
            FileManager.default.enumerator(at: items, includingPropertiesForKeys: nil)?
            .allObjects as? [URL] ?? []
        let record = try XCTUnwrap(
            recordURLs.first { $0.lastPathComponent == current.revisionID + ".tractanda" })
        XCTAssertEqual(record.path.withCString { chmod($0, mode_t(0o600)) }, 0)
        do {
            let handle = try FileHandle(forWritingTo: record)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("corrupted".utf8))
            try handle.close()
        }
        XCTAssertEqual(record.path.withCString { chmod($0, mode_t(0o400)) }, 0)
        assertCode("recoveryError") { _ = try store.get(current.itemID) }
    }

    func testCrossItemHistoricalLookupDoesNotReadUnauthorizedDamagedRevision() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try ItemStore(root: root, accounts: accounts)
        _ = try store.configureAccess(config(), operationID: "cross-item-history-access")
        let shared = try store.withAccess(forUID: accounts.alice) {
            try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text("Bob can read this item"), "permissions": permissions(mode: 0o640),
                    ], operationID: "cross-item-shared")
            ).revision
        }
        let privateInitial = try store.withAccess(forUID: accounts.alice) {
            try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text("Bob cannot read this item"),
                        "permissions": permissions(mode: 0o600),
                    ], operationID: "cross-item-private")
            ).revision
        }
        _ = try store.withAccess(forUID: accounts.alice) {
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: privateInitial.itemID,
                    expectedRevisionID: privateInitial.revisionID,
                    changes: ["subject": .text("Private newer head")], operationID: "cross-item-private-edit")
            )
        }

        let items = root.appendingPathComponent("items")
        let recordURLs =
            FileManager.default.enumerator(at: items, includingPropertiesForKeys: nil)?
            .allObjects as? [URL] ?? []
        let privateOldURL = try XCTUnwrap(
            recordURLs.first { url in
                guard url.pathExtension == "tractanda",
                    let data = try? Data(contentsOf: url),
                    let revision = try? RecordCodec.decode(data)
                else { return false }
                return revision.revisionID == privateInitial.revisionID
            })
        let madeWritable = privateOldURL.path.withCString { chmod($0, mode_t(0o600)) }
        XCTAssertEqual(
            madeWritable, 0, "Could not make fixture revision writable: \(String(cString: strerror(errno)))")
        do {
            let handle = try FileHandle(forWritingTo: privateOldURL)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("damaged historical bytes".utf8))
            try handle.close()
            let restored = privateOldURL.path.withCString { chmod($0, mode_t(0o400)) }
            XCTAssertEqual(restored, 0, "Could not restore fixture revision mode")
        } catch {
            _ = privateOldURL.path.withCString { chmod($0, mode_t(0o400)) }
            throw error
        }

        try store.withAccess(forUID: accounts.bob) {
            XCTAssertEqual(try store.get(shared.itemID), shared)
            assertCode("notFound") {
                _ = try store.get(shared.itemID, revisionID: privateInitial.revisionID)
            }
        }
    }

    func testHistoricalLookupAfterHistoryCacheEviction() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let payload = String(repeating: "x", count: 3 * 1024 * 1024)
        let first = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("revision-0"), "body": .text(payload)],
                operationID: "eviction-create")
        ).revision
        // Put the oldest historical body into the cache before creating a working
        // set larger than its byte limit.
        XCTAssertEqual(try store.get(first.itemID, revisionID: first.revisionID), first)
        var current = first
        var interveningRevisions: [Revision] = []
        // Retry intent is retained with each revision, so use six 3 MiB bodies:
        // each encoded record remains below 8 MiB and the cache working set exceeds
        // its 16 MiB byte limit.
        for index in 1...6 {
            current = try store.commit(
                CommitRequest(
                    action: .revise, itemID: first.itemID, expectedRevisionID: current.revisionID,
                    changes: ["subject": .text("revision-\(index)"), "body": .text(payload)],
                    operationID: "eviction-\(index)")
            ).revision
            interveningRevisions.append(current)
        }
        for revision in interveningRevisions {
            XCTAssertEqual(try store.get(first.itemID, revisionID: revision.revisionID), revision)
        }
        XCTAssertLessThanOrEqual(store.historicalCacheBytesForTesting, 16 * 1024 * 1024)
        XCTAssertEqual(current.fields["subject"]?.string, "revision-6")
        XCTAssertEqual(try store.get(first.itemID, revisionID: first.revisionID), first)
        XCTAssertEqual(try store.get(first.itemID, revisionID: current.revisionID), current)
        XCTAssertEqual(try store.history(first.itemID).count, 7)
    }

    func testCurrentHeadContentHydratesForGetQueryMutationReplayAndCheckpoint() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let itemID: String
        let original: Revision
        let body = "needle " + String(repeating: "x", count: 2 * 1024 * 1024)
        do {
            let store = try ItemStore(root: root)
            original = try store.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("large"), "body": .text(body)],
                    operationID: "large-head-create")
            ).revision
            itemID = original.itemID
            XCTAssertEqual(store.evictedCurrentHeadCount, 1)
            XCTAssertEqual(try store.get(itemID).fields["body"]?.string, body)
            XCTAssertLessThanOrEqual(store.historicalCacheBytesForTesting, 16 * 1024 * 1024)
            XCTAssertEqual(try store.candidates(text: "needle").map(\.itemID), [itemID])
            XCTAssertEqual(
                try Categories.query(store: store, expression: "body == \"needle *\"").map(\.itemID),
                [itemID])
            XCTAssertEqual(
                try Categories.query(store: store, expression: "requestIdentity == *").map(\.itemID),
                [itemID])
            XCTAssertTrue(try Categories.query(store: store, expression: "body == \"missing\"").isEmpty)
            XCTAssertTrue(try Categories.query(store: store, expression: "body != *").isEmpty)
            let hydrationsBeforeExactPage = store.currentHeadHydrationsForTesting
            let exactPage = try Categories.page(
                store: store, expression: nil, text: nil, categoryPath: [], excludedCategoryIDs: [],
                sort: [], position: 0, limit: 10, at: Date(), timeZone: "UTC")
            XCTAssertEqual(exactPage.ids, [itemID])
            XCTAssertEqual(store.currentHeadHydrationsForTesting, hydrationsBeforeExactPage)

            let changed = try store.commit(
                CommitRequest(
                    action: .revise, itemID: itemID, expectedRevisionID: original.revisionID,
                    changes: ["subject": .text("edited")], operationID: "large-head-edit")
            ).revision
            XCTAssertEqual(changed.fields["body"]?.string, body)
            XCTAssertEqual(
                try store.commit(
                    CommitRequest(
                        classID: "Item", changes: ["subject": .text("large"), "body": .text(body)],
                        operationID: "large-head-create")
                ).revision,
                original)
        }
        let reopened = try ItemStore(root: root)
        XCTAssertEqual(reopened.evictedCurrentHeadCount, 1)
        XCTAssertEqual(try reopened.get(itemID).fields["body"]?.string, body)
        try reopened.rebuildIndex()
        XCTAssertEqual(try reopened.candidates(text: "needle").map(\.itemID), [itemID])
    }

    func testCategoryStructuralEditDoesNotHydrateUnrelatedLargeOrdinaryHead() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let category = try store.commit(
            CommitRequest(
                classID: "CategoryItem",
                changes: [
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text("flag == true"),
                    ])
                ], operationID: "structural-category-create")
        ).revision
        let largeBody = String(repeating: "large ordinary body ", count: 70_000)
        let ordinary = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("ordinary"), "body": .text(largeBody)],
                operationID: "structural-large-ordinary")
        ).revision
        XCTAssertEqual(store.evictedCurrentHeadCount, 1)
        let hydrations = store.currentHeadHydrationsForTesting
        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: category.itemID, expectedRevisionID: category.revisionID,
                changes: [
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text("flag == false"),
                    ])
                ], operationID: "structural-category-edit")
        )
        XCTAssertEqual(store.currentHeadHydrationsForTesting, hydrations)
        XCTAssertEqual(try store.get(ordinary.itemID).fields["body"]?.string, largeBody)
    }
}
