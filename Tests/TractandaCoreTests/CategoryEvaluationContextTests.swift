import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class CategoryEvaluationContextTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 61_001
        let bob: UInt32 = 61_002
        var users: [UInt32: AccountIdentity] = [:]

        init() {
            users[getuid()] = AccountIdentity(
                uid: getuid(), name: "admin", primaryGroupName: "staff", groupIDs: [71_001])
            users[alice] = AccountIdentity(
                uid: alice, name: "alice", primaryGroupName: "staff", groupIDs: [71_001])
            users[bob] = AccountIdentity(
                uid: bob, name: "bob", primaryGroupName: "staff", groupIDs: [71_001])
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
            return 71_001
        }
    }

    private func permissions(owner: String, mode: Int64) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner), "group": .text("staff"),
            "mode": .integer(mode), "acl": .object([:]),
        ])
    }

    private func create(
        _ store: ItemStore, uid: UInt32, classID: String = "Item", fields: [String: ItemValue]
    ) throws -> Revision {
        try store.withAccess(forUID: uid) {
            try store.commit(
                CommitRequest(
                    classID: classID, changes: fields, operationID: Identifier.make())
            ).revision
        }
    }

    func testPersonalAndManualDecisionsRespectCallerAndBuildOneOverlayIndexPerQuery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-category-context-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try ItemStore(root: root, accounts: accounts)
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]), operationID: "category-context-access")
        let category = try create(
            store, uid: accounts.alice,
            fields: [
                "subject": .text("Overrides"),
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
                ]),
                "permissions": permissions(owner: "alice", mode: 0o640),
            ])
        let shared = try create(
            store, uid: accounts.alice,
            fields: [
                "subject": .text("Shared target"),
                "categoryOverrides": .object([category.itemID: .text("exclude")]),
                "permissions": permissions(owner: "alice", mode: 0o640),
            ])
        let manual = try create(
            store, uid: accounts.alice,
            fields: [
                "subject": .text("Manual target"),
                "categoryOverrides": .object([category.itemID: .text("include")]),
                "permissions": permissions(owner: "alice", mode: 0o640),
            ])
        let privateTarget = try create(
            store, uid: accounts.alice,
            fields: [
                "subject": .text("Private target"),
                "categoryOverrides": .object([category.itemID: .text("include")]),
                "permissions": permissions(owner: "alice", mode: 0o600),
            ])
        let aliceOverlay = try create(
            store, uid: accounts.alice, classID: "PersonalStateItem",
            fields: [
                "target": .reference(ItemReference(shared.itemID)),
                "personalOverrides": .object([category.itemID: .text("include")]),
                "permissions": permissions(owner: "alice", mode: 0o600),
            ])
        let bobOverlay = try create(
            store, uid: accounts.bob, classID: "PersonalStateItem",
            fields: [
                "target": .reference(ItemReference(shared.itemID)),
                "personalOverrides": .object([category.itemID: .text("exclude")]),
                "permissions": permissions(owner: "bob", mode: 0o600),
            ])

        var overlayScans = 0
        store.beforeCategoryOverlayScan = { overlayScans += 1 }
        try store.withAccess(forUID: accounts.alice) {
            let results = try Categories.query(store: store, categoryPath: [category.itemID])
            XCTAssertEqual(
                Set(results.map(\.itemID)), Set([shared.itemID, manual.itemID, privateTarget.itemID]))
            XCTAssertEqual(overlayScans, 1, "One readable-overlay index is built for the full query.")
            let decision = try store.categoryOverride(for: shared, categoryID: category.itemID)
            XCTAssertEqual(decision?.decision, "include")
            XCTAssertEqual(decision?.origin, "personal:\(aliceOverlay.revisionID)")
        }
        overlayScans = 0
        try store.withAccess(forUID: accounts.bob) {
            let results = try Categories.query(store: store, categoryPath: [category.itemID])
            XCTAssertEqual(Set(results.map(\.itemID)), Set([manual.itemID]))
            XCTAssertEqual(overlayScans, 1, "Unreadable Alice overlay is excluded from Bob's index.")
            let decision = try store.categoryOverride(for: shared, categoryID: category.itemID)
            XCTAssertEqual(decision?.decision, "exclude")
            XCTAssertEqual(decision?.origin, "personal:\(bobOverlay.revisionID)")
            XCTAssertTrue(try store.candidates().contains { $0.itemID == bobOverlay.itemID })
            XCTAssertFalse(try store.candidates().contains { $0.itemID == aliceOverlay.itemID })
        }
    }

    func testManualIncludeCandidatesTrackSourceEditsAndIndexRebuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-category-index-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try ItemStore(root: root, accounts: accounts)
        let category = try create(
            store,
            uid: getuid(),
            fields: [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
                ])
            ]
        )
        let ordinary = try create(
            store,
            uid: getuid(),
            fields: [
                "subject": .text("indexed manual target"),
                "categoryOverrides": .object([category.itemID: .text("include")]),
            ]
        )
        let personalTarget = try create(store, uid: getuid(), fields: [:])
        let overlay = try create(
            store,
            uid: getuid(),
            classID: "PersonalStateItem",
            fields: [
                "target": .reference(ItemReference(personalTarget.itemID)),
                "personalOverrides": .object([category.itemID: .text("include")]),
                "permissions": permissions(owner: "admin", mode: 0o600),
            ]
        )
        XCTAssertEqual(
            Set(try Categories.query(store: store, categoryPath: [category.itemID]).map(\.itemID)),
            Set([ordinary.itemID, personalTarget.itemID]))
        XCTAssertEqual(
            try Categories.query(store: store, text: "indexed manual", categoryPath: [category.itemID])
                .map(\.itemID),
            [ordinary.itemID])

        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: ordinary.itemID, expectedRevisionID: ordinary.revisionID,
                changes: ["categoryOverrides": .object([category.itemID: .text("exclude")])],
                operationID: Identifier.make()))
        XCTAssertFalse(
            try store.categoryIncludeCandidates(categoryIDs: [category.itemID]).contains(ordinary.itemID))
        XCTAssertEqual(
            try Categories.query(store: store, categoryPath: [category.itemID]).map(\.itemID),
            [personalTarget.itemID])

        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: overlay.itemID, expectedRevisionID: overlay.revisionID,
                changes: ["personalOverrides": .object([category.itemID: .text("exclude")])],
                operationID: Identifier.make()))
        XCTAssertFalse(
            try store.categoryIncludeCandidates(categoryIDs: [category.itemID])
                .contains(personalTarget.itemID))
        try store.rebuildIndex()
        XCTAssertTrue(try store.categoryIncludeCandidates(categoryIDs: [category.itemID]).isEmpty)
        XCTAssertTrue(try Categories.query(store: store, categoryPath: [category.itemID]).isEmpty)
    }

    func testManualCategoryHierarchyIndexMatchesFullScanAndCounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-category-hierarchy-index-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        func manualCategory(parent: String? = nil) throws -> Revision {
            var fields: [String: ItemValue] = [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
                ])
            ]
            if let parent { fields["categoryParents"] = .list([.reference(ItemReference(parent))]) }
            return try create(store, uid: getuid(), fields: fields)
        }
        let parent = try manualCategory()
        let child = try manualCategory(parent: parent.itemID)
        var includedIDs = Set<String>()
        for index in 0..<300 {
            var overrides: [String: ItemValue] = [:]
            if index.isMultiple(of: 6) {
                overrides[child.itemID] = .text("include")
            }
            if index.isMultiple(of: 60) {
                overrides[parent.itemID] = .text("exclude")
            }
            let item = try create(
                store, uid: getuid(), fields: ["categoryOverrides": .object(overrides)])
            if index.isMultiple(of: 6), !index.isMultiple(of: 60) { includedIDs.insert(item.itemID) }
        }

        let allHeads = try store.candidates()
        let date = Date()
        let evaluator = try CategoryEvaluator(store.readableCategoryHeads(), store: store, at: date)
        var fullScan: [Revision] = []
        for item in allHeads {
            var cache: [String: Membership] = [:]
            if try evaluator.membership(item, categoryID: parent.itemID, cache: &cache).isIncluded {
                fullScan.append(item)
            }
        }
        fullScan = try ItemSort.ordered(fullScan, by: [])

        let indexedStart = ProcessInfo.processInfo.systemUptime
        let indexedPage = try Categories.page(
            store: store, expression: nil, text: nil, categoryPath: [parent.itemID],
            excludedCategoryIDs: [], sort: [], position: 0, limit: 1_000, at: date, timeZone: "UTC")
        let indexedSeconds = ProcessInfo.processInfo.systemUptime - indexedStart
        let candidates = try store.categoryIncludeCandidates(categoryIDs: [parent.itemID, child.itemID])
        XCTAssertEqual(indexedPage.ids, fullScan.map(\.itemID))
        XCTAssertEqual(indexedPage.total, fullScan.count)
        XCTAssertEqual(Set(indexedPage.ids), includedIDs)
        print(
            "Manual category index heads=302 includeCandidates=\(candidates.count) "
                + "matches=\(indexedPage.total) indexedSeconds=\(indexedSeconds)"
        )
    }
}
