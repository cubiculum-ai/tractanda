import CSQLite
import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class ItemChangesTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        var aliasIsAlice = false
        var missingUsers: Set<String> = []
        var aliceGroups: Set<UInt32> = [71001]
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name = uid == tractanda_uid() ? "admin" : uid == 51001 ? "alice" : "bob"
            return AccountIdentity(
                uid: uid, name: name, primaryGroupName: "staff",
                groupIDs: uid == 51001 ? aliceGroups : [71001])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard !missingUsers.contains(name) else {
                throw TractandaError("unresolvedPrincipal", "Fixture principal is missing")
            }
            let resolved = name == "future" ? (aliasIsAlice ? "alice" : "bob") : name
            guard ["admin", "alice", "bob"].contains(resolved) else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
            }
            return try user(
                forUID: resolved == "admin" ? tractanda_uid() : resolved == "alice" ? 51001 : 51002)
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
            }
            return 71001
        }
    }
    private func policy() -> ItemValue {
        .object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([.text("alice"), .text("bob")]),
        ])
    }
    private func permissions(_ owner: String, mode: Int64 = 0o600) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner),
            "group": .text("staff"), "mode": .integer(mode), "acl": .object([:]),
        ])
    }
    private func fixture(_ body: (URL, Accounts) throws -> Void) throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
            "item-changes-" + Identifier.make())
        try PrivateConfiguration.makeDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, Accounts())
    }
    private func open(_ root: URL, _ accounts: Accounts, existing: Bool = false) throws -> ItemStore {
        var limits = PersonalRecoveryIndex.Limits()
        limits.maximumDerivedBytes = AttachmentFixtureCapacity.fixtureCapBytes
        return try ItemStore(
            personalRoot: root, opening: existing ? .existing : .fresh(policy()), accounts: accounts,
            recoveryLimits: limits)
    }
    private func create(_ store: ItemStore, owner: String = "alice", mode: Int64 = 0o600) throws -> Revision {
        try store.commit(
            CommitRequest(
                classID: "Item",
                changes: ["subject": .text("item"), "permissions": permissions(owner, mode: mode)],
                operationID: Identifier.make())
        ).revision
    }
    private func revise(_ store: ItemStore, _ base: Revision, _ fields: [String: ItemValue]) throws
        -> Revision
    {
        try store.commit(
            CommitRequest(
                action: .revise, itemID: base.itemID, expectedRevisionID: base.revisionID,
                changes: fields, operationID: Identifier.make())
        ).revision
    }
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected, "\($0)") }
    }
    func testCreateUpdateReadableTombstoneAndRestore() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            let initial = store.state
            var item = try create(store)
            let created = try store.itemChanges(sinceState: initial)
            XCTAssertEqual(created.created, [item.itemID])
            XCTAssertFalse(created.hasMoreChanges)
            item = try revise(store, item, ["isDeleted": .boolean(true)])
            XCTAssertTrue(try store.get(item.itemID).isDeleted)
            let deleted = try store.itemChanges(sinceState: created.newState)
            XCTAssertEqual(deleted.updated, [item.itemID])
            XCTAssertEqual(deleted.destroyed, [])
            item = try revise(store, item, ["subject": .text("edited tombstone")])
            let edited = try store.itemChanges(sinceState: deleted.newState)
            XCTAssertEqual(edited.updated, [item.itemID])
            _ = try revise(store, item, ["isDeleted": .boolean(false)])
            let restored = try store.itemChanges(sinceState: edited.newState)
            XCTAssertEqual(restored.updated, [item.itemID])
            XCTAssertFalse(restored.hasMoreChanges)
        }
    }
    func testContinuationRecomputesDeliveredCreateAfterInterveningEditAndSupportsSiblingCalls() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            let initial = store.state
            let a = try create(store)
            let b = try create(store)
            let c = try create(store)
            let originals = [a, b, c]
            let first = try store.itemChanges(sinceState: initial, maxChanges: 1)
            XCTAssertTrue(first.hasMoreChanges)
            XCTAssertEqual(first.created.count, 1)
            let delivered = try XCTUnwrap(originals.first { $0.itemID == first.created[0] })
            _ = try revise(store, delivered, ["subject": .text("changed between pages")])
            let second = try store.itemChanges(sinceState: first.newState, maxChanges: 1)
            XCTAssertEqual(second.created.count, 1)
            XCTAssertEqual(second.updated, [])
            XCTAssertTrue(second.hasMoreChanges)
            let sibling = try store.itemChanges(sinceState: first.newState, maxChanges: 1)
            XCTAssertEqual(sibling.updated, second.updated)
            XCTAssertEqual(sibling.created, second.created)
            var token = second.newState
            var seen = Set(first.created + second.created)
            var updated: Set<String> = []
            for _ in 0..<5 {
                let page = try store.itemChanges(sinceState: token, maxChanges: 1)
                seen.formUnion(page.created)
                updated.formUnion(page.updated)
                token = page.newState
                if !page.hasMoreChanges { break }
            }
            XCTAssertEqual(seen, Set(originals.map(\.itemID)))
            XCTAssertEqual(updated, [delivered.itemID])
            let empty = try store.itemChanges(sinceState: token, maxChanges: 1)
            XCTAssertEqual(empty.created + empty.updated + empty.destroyed, [])
        }
    }
    func testPrivateEditsDoNotRotateStateAndAccessChangesClassifyAvailability() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            let initial = try store.withAccess(forUID: 51001) { store.state }
            var item = try create(store, owner: "bob")
            XCTAssertEqual(try store.withAccess(forUID: 51001) { store.state }, initial)
            item = try revise(store, item, ["subject": .text("private edit")])
            XCTAssertEqual(try store.withAccess(forUID: 51001) { store.state }, initial)
            let hidden = try store.withAccess(forUID: 51001) { try store.itemChanges(sinceState: initial) }
            XCTAssertEqual(hidden.created + hidden.updated + hidden.destroyed, [])
            item = try revise(store, item, ["permissions": permissions("bob", mode: 0o644)])
            let grant = try store.withAccess(forUID: 51001) { try store.itemChanges(sinceState: initial) }
            XCTAssertEqual(grant.created, [item.itemID])
            _ = try revise(store, item, ["permissions": permissions("bob")])
            let revoke = try store.withAccess(forUID: 51001) {
                try store.itemChanges(sinceState: grant.newState)
            }
            XCTAssertEqual(revoke.destroyed, [item.itemID])
            code("cannotCalculateChanges") {
                _ = try store.withAccess(forUID: 51002) { try store.itemChanges(sinceState: initial) }
            }
        }
    }
    func testPrincipalRemapAndOSMembershipInvalidateWithoutLeakingIDs() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            _ = try create(store, owner: "future")
            let initial = try store.withAccess(forUID: 51001) { store.state }
            accounts.aliasIsAlice = true
            code("cannotCalculateChanges") {
                _ = try store.withAccess(forUID: 51001) { try store.itemChanges(sinceState: initial) }
            }
            let remapped = try store.withAccess(forUID: 51001) { store.state }
            XCTAssertNotEqual(remapped, initial)
            accounts.aliceGroups.insert(71002)
            code("cannotCalculateChanges") {
                _ = try store.withAccess(forUID: 51001) { try store.itemChanges(sinceState: remapped) }
            }
        }
    }
    // Insert inside ItemChangesTests; its fixture/open/create helpers are private.
    func testActiveContinuationSurvivesCleanPersonalReopen() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts)
            let initial = try store!.requireProtocolState()
            let originals = try (0..<3).map { _ in try create(store!) }
            let first = try store!.itemChanges(sinceState: initial, maxChanges: 1)
            XCTAssertTrue(first.hasMoreChanges)
            XCTAssertEqual(first.created.count, 1)
            let expectedSecond = try store!.itemChanges(sinceState: first.newState, maxChanges: 1)
            XCTAssertTrue(expectedSecond.hasMoreChanges)
            store = nil

            store = try open(root, accounts, existing: true)
            XCTAssertEqual(store!.startupRecovery["reason"], "validatedCheckpoint")
            let second = try store!.itemChanges(sinceState: first.newState, maxChanges: 1)
            XCTAssertEqual(second.created, expectedSecond.created)
            XCTAssertEqual(second.updated, expectedSecond.updated)
            XCTAssertEqual(second.destroyed, expectedSecond.destroyed)
            XCTAssertTrue(second.hasMoreChanges)
            let third = try store!.itemChanges(sinceState: second.newState, maxChanges: 1)
            XCTAssertFalse(third.hasMoreChanges)
            XCTAssertEqual(third.created.count, 1)
            XCTAssertEqual(first.updated + second.updated + third.updated, [])
            XCTAssertEqual(first.destroyed + second.destroyed + third.destroyed, [])
            let delivered = first.created + second.created + third.created
            XCTAssertEqual(delivered.count, Set(delivered).count)
            XCTAssertEqual(Set(delivered), Set(originals.map(\.itemID)))
            let empty = try store!.itemChanges(sinceState: third.newState)
            XCTAssertEqual(empty.created + empty.updated + empty.destroyed, [])
            store = nil
        }
    }

    func testCleanPersonalValidationPreservesSQLiteDateColumns() throws {
        try fixture { root, accounts in
            func dates() throws -> [String] {
                let index = try ItemIndex(
                    path: root.appendingPathComponent("index/items.sqlite").path, create: false)
                defer { index.close() }
                var result: [String] = []
                for sql in [
                    "SELECT id,revision,created,modified FROM items ORDER BY id",
                    "SELECT item,revision,created_at,modified_at FROM revision_catalog ORDER BY item,revision",
                ] {
                    let statement = try index.corpusPrepare(sql)
                    defer { sqlite3_finalize(statement) }
                    while true {
                        let status = index.catalogueStep(statement)
                        if status == SQLITE_DONE { break }
                        guard status == SQLITE_ROW else {
                            throw TractandaError("testIndexRead", "Cannot inspect fixture date columns.")
                        }
                        var columns: [String] = []
                        for column in Int32(0)..<Int32(4) {
                            if sqlite3_column_type(statement, column) == SQLITE_FLOAT {
                                columns.append(
                                    String(sqlite3_column_double(statement, column).bitPattern, radix: 16))
                            } else {
                                columns.append(
                                    sqlite3_column_text(statement, column).map { String(cString: $0) }
                                        ?? "NULL")
                            }
                        }
                        result.append(columns.joined(separator: "|"))
                    }
                }
                return result
            }

            var store: ItemStore? = try open(root, accounts)
            let original = try create(store!)
            let current = try revise(store!, original, ["subject": .text("second revision")])
            let initial = try store!.requireProtocolState()
            store = nil
            let before = try dates()
            XCTAssertEqual(before.count, 3, "One current row plus two historical catalogue rows.")

            store = try open(root, accounts, existing: true)
            XCTAssertEqual(store!.startupRecovery["reason"], "validatedCheckpoint")
            XCTAssertEqual(try store!.requireProtocolState(), initial)
            let after = try dates()
            XCTAssertEqual(after, before)
            XCTAssertEqual(try store!.get(current.itemID).modifiedAt, current.modifiedAt)
            store = nil
        }
    }

    func testCleanReopenRetainsTokensAndExplicitRebuildInvalidatesThem() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts)
            let item = try create(store!)
            let initial = store!.state
            store = nil
            store = try open(root, accounts, existing: true)
            XCTAssertEqual(store!.state, initial)
            XCTAssertEqual(store!.startupRecovery["reason"], "validatedCheckpoint")
            let base = try store!.get(item.itemID)
            _ = try revise(store!, base, ["subject": .text("after reopen")])
            let result = try store!.itemChanges(sinceState: initial)
            XCTAssertEqual(result.updated, [item.itemID])
            try store!.rebuildIndex()
            code("cannotCalculateChanges") { _ = try store!.itemChanges(sinceState: initial) }
            store = nil
        }
    }
    func testDirtyPersonalReopenRecoversAndInvalidatesTokens() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts)
            let item = try create(store!)
            let initial = store!.state
            let original = try store!.get(item.itemID)
            store = nil
            try StoreCheckpoint.markDirty(root: root)
            store = try open(root, accounts, existing: true)
            XCTAssertEqual(store!.startupRecovery["reason"], "dirtyMarker")
            XCTAssertEqual(try store!.get(item.itemID).modifiedAt, original.modifiedAt)
            code("cannotCalculateChanges") { _ = try store!.itemChanges(sinceState: initial) }
            store = nil
        }
    }
    func testPersonalMetadataOnlyDriftRetainsCheckpointAndDates() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts)
            let item = try create(store!)
            let initial = store!.state
            store = nil
            let files = FileManager.default.enumerator(
                at: root.appendingPathComponent("items"), includingPropertiesForKeys: nil)!
            var record: URL?
            while let url = files.nextObject() as? URL {
                if url.pathExtension == "tractanda" {
                    record = url
                    break
                }
            }
            let url = try XCTUnwrap(record)
            let bytes = try Data(contentsOf: url)
            // Replacing identical bytes changes inode/mtime. Opening must only verify them.
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let metadata = try FileMetadata.read(at: url)
            store = try open(root, accounts, existing: true)
            XCTAssertEqual(store!.startupRecovery["reason"], "validatedCheckpoint")
            XCTAssertEqual(store!.state, initial)
            let relative = String(url.path.dropFirst(root.path.count + 1))
            try store!.applyVerification(
                [
                    .init(
                        kind: .metadataChanged, path: relative, revisionID: item.revisionID,
                        detail: "fixture metadata drift"),
                    .init(
                        kind: .missing, path: relative, revisionID: item.revisionID,
                        detail: "stale fixture snapshot"),
                ], scannedGeneration: "fixture-before-restore")
            XCTAssertEqual(try store!.get(item.itemID).revisionID, item.revisionID)
            XCTAssertEqual(store!.state, initial)
            let snapshot = try store!.withAccess(forUID: 51001) {
                try XCTUnwrap(store!.immutableReadSnapshot())
            }
            XCTAssertEqual(snapshot.revisions.map(\.itemID), [item.itemID])
            XCTAssertTrue(
                try store!.withAccess(forUID: 51001) {
                    try store!.verifyImmutableReadSnapshot(snapshot)
                })
            XCTAssertEqual(try store!.get(item.itemID).modifiedAt, item.modifiedAt)
            XCTAssertEqual(try FileMetadata.read(at: url), metadata)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            var alteredFields = item.fields
            alteredFields["subject"] = .text("changed after validation")
            let altered = try Revision(fields: alteredFields, formatVersion: item.formatVersion)
            try RecordCodec.encode(altered).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            XCTAssertThrowsError(
                try store!.withAccess(forUID: 51001) {
                    try store!.verifyImmutableReadSnapshot(snapshot)
                })
            store = nil
        }
    }
    func testRelocatedPersonalTreeRetainsLogicalCheckpoint() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts)
            let item = try create(store!)
            let initial = store!.state
            store = nil
            let relocated = root.deletingLastPathComponent().appendingPathComponent(
                "relocated-" + Identifier.make())
            defer { try? FileManager.default.removeItem(at: relocated) }
            let originalRootMetadata = try FileMetadata.read(at: root)
            try FileManager.default.copyItem(at: root, to: relocated)
            XCTAssertNotEqual(try FileMetadata.read(at: relocated).inode, originalRootMetadata.inode)
            store = try open(relocated, accounts, existing: true)
            XCTAssertEqual(store!.startupRecovery["reason"], "validatedCheckpoint")
            XCTAssertEqual(store!.state, initial)
            let snapshot = try store!.withAccess(forUID: 51001) {
                try XCTUnwrap(store!.immutableReadSnapshot())
            }
            XCTAssertEqual(snapshot.revisions.map(\.itemID), [item.itemID])
            XCTAssertTrue(
                try store!.withAccess(forUID: 51001) {
                    try store!.verifyImmutableReadSnapshot(snapshot)
                })
            XCTAssertEqual(try store!.get(item.itemID).modifiedAt, item.modifiedAt)
            store = nil
        }
    }
    func testChangedCanonicalBytesRejectPersonalCheckpoint() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts)
            let item = try create(store!)
            let initial = store!.state
            store = nil
            let files = FileManager.default.enumerator(
                at: root.appendingPathComponent("items"), includingPropertiesForKeys: nil)!
            var record: URL?
            while let url = files.nextObject() as? URL {
                if url.pathExtension == "tractanda" {
                    record = url
                    break
                }
            }
            let url = try XCTUnwrap(record)
            let original = try RecordCodec.decode(Data(contentsOf: url))
            var fields = original.fields
            fields["subject"] = .text("changed")
            let changed = try Revision(fields: fields, formatVersion: original.formatVersion)
            try RecordCodec.encode(changed).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            store = try open(root, accounts, existing: true)
            XCTAssertEqual(store!.startupRecovery["reason"], "ordinaryCanonicalRebuild")
            XCTAssertEqual(try store!.get(item.itemID).fields["subject"], .text("changed"))
            XCTAssertEqual(try store!.get(item.itemID).modifiedAt, item.modifiedAt)
            code("cannotCalculateChanges") { _ = try store!.itemChanges(sinceState: initial) }
            store = nil
        }
    }
    func testIncompletePersonalProjectionRelationsRecoverFromCanonicalFiles() throws {
        for variation in [
            "policy", "duplicatePolicy", "policyRevision", "projectionACL", "contentACL", "itemsRevision",
            "headRevision", "rawStatus", "orphanItems", "orphanHead",
        ] {
            try fixture { root, accounts in
                var store: ItemStore? = try open(root, accounts)
                let original = try create(store!)
                let item = try revise(store!, original, ["subject": .text("relational fixture")])
                let initial = store!.state
                store = nil
                let index = try ItemIndex(
                    path: root.appendingPathComponent("index/items.sqlite").path, create: false)
                index.personalContentProjectionMode = true
                let unrelated = Identifier.make()
                switch variation {
                case "policy": try index.execute("DELETE FROM current_policy WHERE item=?", [item.itemID])
                case "duplicatePolicy":
                    try index.execute(
                        "INSERT INTO current_policy SELECT item,?,class,permissions FROM current_policy WHERE item=?",
                        [original.revisionID, item.itemID])
                case "policyRevision":
                    try index.execute(
                        "UPDATE current_policy SET revision=? WHERE item=?", [unrelated, item.itemID])
                case "projectionACL":
                    try index.execute("DELETE FROM projection_acl WHERE item=?", [item.itemID])
                case "contentACL": try index.execute("DELETE FROM acl_core WHERE item_id=?", [item.itemID])
                case "itemsRevision":
                    try index.execute(
                        "UPDATE items SET revision=? WHERE id=?", [original.revisionID, item.itemID])
                case "headRevision":
                    try index.execute(
                        "UPDATE head_summaries SET revision=? WHERE item_id=?",
                        [original.revisionID, item.itemID])
                case "rawStatus":
                    try index.execute(
                        "UPDATE current_projection SET status='conflicted' WHERE item=?", [item.itemID])
                case "orphanItems":
                    try index.execute(
                        "INSERT INTO items SELECT ?,revision,class,deleted,modified,created,fields FROM items WHERE id=?",
                        [unrelated, item.itemID])
                case "orphanHead":
                    try index.execute(
                        "INSERT INTO head_summaries SELECT ?,revision,class,deleted,fields,clock_dependent,category FROM head_summaries WHERE item_id=?",
                        [unrelated, item.itemID])
                default: XCTFail("Unknown fixture variation")
                }
                try index.closeChecked()
                store = try open(root, accounts, existing: true)
                XCTAssertEqual(store!.startupRecovery["reason"], "ordinaryCanonicalRebuild", variation)
                XCTAssertEqual(try store!.get(item.itemID), item, variation)
                code("cannotCalculateChanges") { _ = try store!.itemChanges(sinceState: initial) }
                store = nil
            }
        }
    }
    func testMissingPersonalCurrentProjectionRejectsCheckpoint() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts)
            let item = try create(store!)
            let initial = store!.state
            store = nil
            let index = try ItemIndex(
                path: root.appendingPathComponent("index/items.sqlite").path, create: false)
            index.personalContentProjectionMode = true
            try index.execute("DELETE FROM current_projection WHERE item=?", [item.itemID])
            try index.closeChecked()
            store = try open(root, accounts, existing: true)
            XCTAssertEqual(store!.startupRecovery["reason"], "ordinaryCanonicalRebuild")
            XCTAssertEqual(try store!.get(item.itemID).modifiedAt, item.modifiedAt)
            code("cannotCalculateChanges") { _ = try store!.itemChanges(sinceState: initial) }
            store = nil
        }
    }
    func testPersonalCheckpointBindingMismatchRebuilds() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts)
            let item = try create(store!)
            let initial = store!.state
            store = nil
            let index = try ItemIndex(
                path: root.appendingPathComponent("index/items.sqlite").path, create: false)
            try index.execute(
                "UPDATE checkpoint_meta SET value='wrong-root' WHERE key=?", [PersonalIndexCheckpoint.key])
            try index.closeChecked()
            store = try open(root, accounts, existing: true)
            XCTAssertEqual(store!.startupRecovery["reason"], "ordinaryCanonicalRebuild")
            XCTAssertEqual(try store!.get(item.itemID).modifiedAt, item.modifiedAt)
            code("cannotCalculateChanges") { _ = try store!.itemChanges(sinceState: initial) }
            store = nil
        }
    }
    func testInterruptedReconciliationRollsBackCursorAndRetainsDirtyCandidate() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            let initial = store.state
            let item = try create(store)
            store.beforeItemChangesCommitForTesting = {
                throw TractandaError("injected", "interrupted derived flush")
            }
            code("cannotCalculateChanges") { _ = try store.itemChanges(sinceState: initial) }
            store.beforeItemChangesCommitForTesting = nil
            let recovered = try store.itemChanges(sinceState: initial)
            XCTAssertEqual(recovered.created, [item.itemID])
        }
    }
    func testRetentionExpiryRequiresRefreshInsteadOfSkippingHistory() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            var clock = Date()
            store.itemChangesClockForTesting = { clock }
            let initial = store.state
            _ = try create(store)
            let first = try store.itemChanges(sinceState: initial)
            clock.addTimeInterval(ItemIndex.itemChangesMaximumAge + 1)
            _ = try create(store)
            code("cannotCalculateChanges") { _ = try store.itemChanges(sinceState: first.newState) }
            let refreshed = store.state
            let empty = try store.itemChanges(sinceState: refreshed)
            XCTAssertEqual(empty.created + empty.updated + empty.destroyed, [])
        }
    }
    func testDerivedProjectionJournalIncludesUnresolvedAndResolutionOnlyMetadata() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            let item = try create(store)
            let index = try ItemIndex(path: ":memory:", create: true)
            defer { index.close() }
            index.personalContentProjectionMode = true
            try index.put(item)
            try index.replacePersonalProjection(
                itemID: item.itemID, analysis: nil, representative: item,
                permissions: item.fields["permissions"], physicalHeads: [item.revisionID])
            let ready = try index.reconcileItemChanges(projection: true)
            try index.replacePersonalProjection(
                itemID: item.itemID, analysis: nil, representative: item,
                permissions: item.fields["permissions"], physicalHeads: [item.revisionID])
            XCTAssertEqual(
                try index.reconcileItemChanges(projection: true).head, ready.head,
                "An identical projection replay must not manufacture a type change.")
            try index.replacePersonalProjection(
                itemID: item.itemID, analysis: nil, representative: nil,
                permissions: item.fields["permissions"], physicalHeads: [item.revisionID],
                resourceCode: "first-window")
            let unresolved = try index.reconcileItemChanges(projection: true)
            let first = try XCTUnwrap(
                index.itemChangeCandidates(after: ready.head, through: unresolved.head)[item.itemID])
            XCTAssertEqual(first.old?.resolution?.status, .ready)
            XCTAssertEqual(first.new?.resolution?.status, .unmaterializable)
            XCTAssertNotEqual(try first.old?.signature, try first.new?.signature)
            try index.replacePersonalProjection(
                itemID: item.itemID, analysis: nil, representative: nil,
                permissions: item.fields["permissions"], physicalHeads: [item.revisionID],
                resourceCode: "second-window")
            let metadata = try index.reconcileItemChanges(projection: true)
            let changed = try XCTUnwrap(
                index.itemChangeCandidates(after: unresolved.head, through: metadata.head)[item.itemID])
            XCTAssertEqual(changed.old?.revisionID, changed.new?.revisionID)
            XCTAssertNotEqual(try changed.old?.signature, try changed.new?.signature)
            try index.put(item)
            try index.replacePersonalProjection(
                itemID: item.itemID, analysis: nil, representative: item,
                permissions: item.fields["permissions"], physicalHeads: [item.revisionID])
            let resolved = try index.reconcileItemChanges(projection: true)
            let final = try XCTUnwrap(
                index.itemChangeCandidates(after: metadata.head, through: resolved.head)[item.itemID])
            XCTAssertEqual(final.new?.resolution?.status, .ready)
            XCTAssertNotEqual(try final.old?.signature, try final.new?.signature)
        }
    }

    func testStaticDeltaContinuationSeeksWithoutRescanningJournalOrRewritingNoopState() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            let initial = store.state
            let saves = store.itemChangeTokenSavesForTesting
            XCTAssertEqual(store.state, initial)
            XCTAssertEqual(try store.itemChanges(sinceState: initial).newState, initial)
            XCTAssertEqual(store.itemChangeTokenSavesForTesting, saves)
            var expected: Set<String> = []
            for _ in 0..<24 { expected.insert(try create(store).itemID) }
            var page = try store.itemChanges(sinceState: initial, maxChanges: 1)
            let plannedWork = store.itemChangeCandidateRowsForTesting
            var actual = Set(page.created)
            var pages = 1
            while page.hasMoreChanges && pages < 30 {
                page = try store.itemChanges(sinceState: page.newState, maxChanges: 1)
                actual.formUnion(page.created)
                pages += 1
                XCTAssertEqual(
                    store.itemChangeCandidateRowsForTesting, plannedWork,
                    "Static continuation pages must seek their retained plan instead of refolding history.")
            }
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(pages, expected.count)
            let finalSaves = store.itemChangeTokenSavesForTesting
            XCTAssertEqual(store.state, page.newState)
            XCTAssertEqual(store.itemChangeTokenSavesForTesting, finalSaves)
        }
    }

    func testExplicitRebuildInvalidatesRetainedState() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            _ = try create(store)
            let initial = store.state
            try store.rebuildIndex()
            code("cannotCalculateChanges") { _ = try store.itemChanges(sinceState: initial) }
        }
    }
    func testMissingTriggerRepairAndEpochInvalidationShareCrashSafeBoundary() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            let item = try create(store)
            let path = root.appendingPathComponent("index/tracking-repair.sqlite").path
            var index: ItemIndex? = try ItemIndex(path: path, create: true)
            index!.personalContentProjectionMode = true
            try index!.put(item)
            try index!.replacePersonalProjection(
                itemID: item.itemID, analysis: nil, representative: item,
                permissions: item.fields["permissions"], physicalHeads: [item.revisionID])
            let initial = try index!.reconcileItemChanges(projection: true)
            let token = ItemIndex.ChangeToken(
                token: Identifier.make(), epoch: initial.epoch, sequence: initial.head, scope: "fixture",
                users: [:], groups: [:], planID: nil, position: 0, issuedAt: Date().timeIntervalSince1970)
            try index!.saveItemChangeToken(token)
            try index!.execute("DROP TRIGGER item_changes_current_projection_insert")
            try index!.closeChecked()
            index = nil
            index = try ItemIndex(path: path, create: false)
            index!.personalContentProjectionMode = true
            index!.beforeItemChangesSchemaCommitForTesting = {
                throw TractandaError("injected", "interrupted tracking schema repair")
            }
            code("injected") { _ = try index!.reconcileItemChanges(projection: true) }
            XCTAssertEqual(
                try index!.itemChangeToken(token.token)?.epoch, initial.epoch,
                "Failed schema repair must roll back the epoch invalidation as well as DDL.")
            let query = try index!.corpusPrepare(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='item_changes_current_projection_insert'"
            )
            XCTAssertEqual(index!.catalogueStep(query), SQLITE_ROW)
            XCTAssertEqual(
                sqlite3_column_int(query, 0), 0,
                "Failed precommit repair must leave the trigger missing for safe retry detection.")
            sqlite3_finalize(query)
            try index!.closeChecked()
            index = nil
            index = try ItemIndex(path: path, create: false)
            index!.personalContentProjectionMode = true
            let repaired = try index!.reconcileItemChanges(projection: true)
            XCTAssertNotEqual(repaired.epoch, initial.epoch)
            XCTAssertNil(try index!.itemChangeToken(token.token))
            try index!.closeChecked()
            index = nil
        }
    }

    func testUnrelatedMissingPrincipalHasStableStateAndAbsentToPresentInvalidates() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            let readable = try create(store, owner: "alice")
            let other = try create(store, owner: "alice")
            _ = try create(store, owner: "future")
            accounts.missingUsers.insert("future")
            let initial = try store.withAccess(forUID: 51001) { store.state }
            XCTAssertEqual(try store.withAccess(forUID: 51001) { store.state }, initial)
            let empty = try store.withAccess(forUID: 51001) { try store.itemChanges(sinceState: initial) }
            XCTAssertEqual(empty.newState, initial)
            XCTAssertEqual(empty.created + empty.updated + empty.destroyed, [])
            XCTAssertEqual(
                try store.withAccess(forUID: 51001) { try store.get(readable.itemID).itemID }, readable.itemID
            )
            let service = ItemService(store: store)
            func query(_ arguments: [String: Any]) throws -> [String: Any] {
                let request = try nativeFixtureRequest(
                    method: "TractandaItem/query", arguments: arguments,
                    accountID: store.nativeProtocolSessionBasis.identity)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: service.handle(request, peerUID: 51001)) as? [String: Any])
                let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
                let first = try XCTUnwrap(calls.first)
                XCTAssertEqual(first[0] as? String, "TractandaItem/query")
                return try XCTUnwrap(first[1] as? [String: Any])
            }
            let first = try query(["expression": "classID == \"Item\"", "limit": 1])
            let cursor = try XCTUnwrap(first["nextCursor"] as? String)
            let second = try query(["expression": "classID == \"Item\"", "limit": 1, "cursor": cursor])
            XCTAssertEqual(
                Set((first["ids"] as? [String] ?? []) + (second["ids"] as? [String] ?? [])),
                [readable.itemID, other.itemID])
            accounts.missingUsers.remove("future")
            accounts.aliasIsAlice = true
            code("cannotCalculateChanges") {
                _ = try store.withAccess(forUID: 51001) { try store.itemChanges(sinceState: initial) }
            }
            XCTAssertNotEqual(try store.withAccess(forUID: 51001) { store.state }, initial)
        }
    }
    func testEvictedPlanTargetFailsExplicitlyBeforeReturningUnusableFinalState() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            store.itemChangeTokenRowsLimitForTesting = 2
            let initial = store.state
            _ = try create(store)
            _ = try create(store)
            let first = try store.itemChanges(sinceState: initial, maxChanges: 1)
            XCTAssertTrue(first.hasMoreChanges)
            _ = try create(store)
            let current = store.state
            code("cannotCalculateChanges") {
                _ = try store.itemChanges(sinceState: first.newState, maxChanges: 1)
            }
            XCTAssertEqual(try store.itemChanges(sinceState: current).created, [])
        }
    }

    func testUnavailableStateFailsRepliesAndCursorProofWhileDiagnosticsRemainReadable() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts)
            let a = try create(store)
            _ = try create(store)
            _ = try create(store)
            let service = ItemService(store: store)
            func call(_ method: String, _ arguments: [String: Any]) throws -> (String, [String: Any]) {
                let request = try nativeFixtureRequest(
                    method: method, arguments: arguments, accountID: store.nativeProtocolSessionBasis.identity
                )
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: service.handle(request, peerUID: 51001)) as? [String: Any])
                let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
                let first = try XCTUnwrap(calls.first)
                return (try XCTUnwrap(first[0] as? String), try XCTUnwrap(first[1] as? [String: Any]))
            }
            let first = try call("TractandaItem/query", ["expression": "classID == \"Item\"", "limit": 1])
            XCTAssertEqual(first.0, "TractandaItem/query")
            let cursor = try XCTUnwrap(first.1["nextCursor"] as? String)
            let initial = try store.withAccess(forUID: 51001) { try store.requireProtocolState() }
            let snapshot = try store.withAccess(forUID: 51001) {
                try XCTUnwrap(store.immutableReadSnapshot())
            }
            store.beforeItemChangesCommitForTesting = {
                throw TractandaError("injected", "state unavailable")
            }
            XCTAssertEqual(store.state, ItemStore.unavailableProtocolState)
            XCTAssertEqual(store.state, ItemStore.unavailableProtocolState)
            code("serverFail") { _ = try store.requireProtocolState() }
            code("cannotCalculateChanges") { _ = try store.itemChanges(sinceState: initial) }
            XCTAssertNil(try store.withAccess(forUID: 51001) { try store.pooledReadAuthority() })
            XCTAssertFalse(
                try store.withAccess(forUID: 51001) { try store.verifyImmutableReadSnapshot(snapshot) })
            let get = try call("TractandaItem/get", ["ids": [a.itemID]])
            XCTAssertEqual(get.0, "error")
            XCTAssertEqual(get.1["type"] as? String, "serverFail")
            let continued = try call(
                "TractandaItem/query",
                [
                    "expression": "classID == \"Item\"", "limit": 1, "cursor": cursor,
                ])
            XCTAssertEqual(continued.0, "error")
            XCTAssertEqual(continued.1["type"] as? String, "serverFail")
            let info = try call("TractandaStore/info", [:])
            XCTAssertEqual(info.0, "TractandaStore/info")
            XCTAssertEqual(info.1["stateAvailable"] as? Bool, false)
            XCTAssertEqual(info.1["state"] as? String, ItemStore.unavailableProtocolState)
            store.beforeItemChangesCommitForTesting = nil
            let recovered = try call(
                "TractandaItem/query",
                [
                    "expression": "classID == \"Item\"", "limit": 1, "cursor": cursor,
                ])
            XCTAssertEqual(recovered.0, "TractandaItem/query")
        }
    }

}
