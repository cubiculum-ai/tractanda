import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class CurrentProjectionStoreTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 51001
        let bob: UInt32 = 51002
        var users: [UInt32: AccountIdentity] = [:]
        init() {
            for (uid, name) in [(tractanda_uid(), "admin"), (alice, "alice"), (bob, "bob")] {
                users[uid] = AccountIdentity(
                    uid: uid, name: name, primaryGroupName: "staff", groupIDs: [71001])
            }
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard let value = users[uid] else { throw TractandaError("unresolvedPrincipal", "Unknown user") }
            return value
        }
        func user(named name: String) throws -> AccountIdentity {
            guard let value = users.values.first(where: { $0.name == name }) else {
                throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return value
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Unknown group") }
            return 71001
        }
    }
    private final class Fixture {
        let root: URL
        let accounts = Accounts()
        var originals: [URL: Data] = [:]
        init() throws {
            try AttachmentFixtureCapacity.requireFree()
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "tractanda-current-" + Identifier.make())
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func store() throws -> ItemStore {
            try ItemStore(root: root, accounts: accounts, revisionProjectionEnabled: true)
        }
        func branch(_ base: Revision, changes: [String: ItemValue], unset: [String] = []) throws -> Revision {
            try AttachmentFixtureCapacity.requireFree()
            let id = try UUID.makeVersion1().uuidString.lowercased()
            var fields = base.fields
            fields["revisionID"] = .text(id)
            fields["supersedes"] = .text(base.revisionID)
            fields["modifiedAt"] = .date(
                try RevisionPublicationClock.after([base.modifiedAt], now: { base.modifiedAt }))
            fields["operationID"] = .text("branch-" + id)
            fields["requestIdentity"] = .text("retained-fixture")
            for (key, value) in changes { fields[key] = value }
            for key in unset { fields.removeValue(forKey: key) }
            fields["revisionAncestry"] = try RevisionProvenance(
                kind: .authored, originReplicaID: XCTUnwrap(base.provenance).originReplicaID,
                parents: [base.revisionID], writtenFields: changes.keys.sorted(), unsetFields: unset.sorted(),
                frontier: []
            ).itemValue
            let revision = try Revision(fields: fields, formatVersion: 2)
            let bytes = try RecordCodec.encode(revision)
            let total = originals.values.reduce(0) { $0 + $1.count }
            guard UInt64(bytes.count + total) <= AttachmentFixtureCapacity.fixtureCapBytes else {
                throw TractandaError("resourceLimit", "Fixture cap")
            }
            let directory = root.appendingPathComponent("items/2026/10/13/12/00/" + base.itemID)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(id + ".tractanda")
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            originals[file] = bytes
            try StoreCheckpoint.markDirty(root: root)
            return revision
        }
        func assertPreserved() throws {
            for (file, bytes) in originals { XCTAssertEqual(try Data(contentsOf: file), bytes) }
        }
    }
    private func permissions(_ mode: Int64) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text("alice"), "group": .text("staff"),
            "mode": .integer(mode), "acl": .object([:]),
        ])
    }
    @discardableResult
    private func configure(_ store: ItemStore) throws -> Revision {
        try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]), operationID: "configure"
        ).revision
    }
    private func create(_ f: Fixture, fields: [String: ItemValue] = [:]) throws -> Revision {
        let store = try f.store()
        return try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("root")].merging(fields) { _, rhs in rhs },
                operationID: "create")
        ).revision
    }
    func testNonoverlapRecoveryMaterializesOnceAndHistoryRetainsEveryPhysicalRevision() throws {
        let f = try Fixture()
        let root = try create(f)
        let a = try f.branch(root, changes: ["subject": .text("left")])
        let b = try f.branch(root, changes: ["body": .text("right")])
        var mergeID = ""
        do {
            let store = try f.store()
            let current = try store.get(root.itemID)
            mergeID = current.revisionID
            XCTAssertEqual(current.fields["subject"], .text("left"))
            XCTAssertEqual(current.fields["body"], .text("right"))
            XCTAssertEqual(try current.provenance?.kind, .automaticMerge)
            XCTAssertGreaterThan(
                try RevisionTimestamp(current.modifiedAt), try RevisionTimestamp(a.modifiedAt))
            XCTAssertGreaterThan(
                try RevisionTimestamp(current.modifiedAt), try RevisionTimestamp(b.modifiedAt))
            XCTAssertEqual(try store.history(root.itemID).count, 4)
            XCTAssertEqual(try store.itemState(root.itemID).status, .ready)
        }
        do {
            let store = try f.store()
            XCTAssertEqual(try store.get(root.itemID).revisionID, mergeID)
            XCTAssertEqual(try store.history(root.itemID).count, 4)
            let next = try store.commit(
                CommitRequest(
                    action: .revise, itemID: root.itemID, expectedRevisionID: mergeID,
                    changes: ["body": .text("next")], operationID: "warm-append")
            ).revision
            XCTAssertGreaterThan(try RevisionTimestamp(next.modifiedAt), try RevisionTimestamp(b.modifiedAt))
        }
        try f.assertPreserved()
    }
    func testConflictingGetHistoricalReadExplicitResolutionAndOriginReplay() throws {
        let f = try Fixture()
        let root = try create(f)
        let a = try f.branch(root, changes: ["subject": .text("left")])
        _ = try f.branch(root, changes: ["subject": .text("right")])
        let store = try f.store()
        let state = try store.itemState(root.itemID)
        XCTAssertEqual(state.status, .conflicted)
        XCTAssertThrowsError(try store.get(root.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "itemUnresolved")
        }
        XCTAssertEqual(try store.get(root.itemID, revisionID: a.revisionID), a)
        XCTAssertEqual(try store.history(root.itemID).count, 3)
        let request = ResolveConflictRequest(
            itemID: root.itemID, expectedStateToken: state.stateToken,
            reviewedFrontier: try XCTUnwrap(state.frontier), changes: ["subject": .text("resolved")],
            unset: [], operationID: "resolve")
        let result = try store.resolveConflict(request)
        XCTAssertEqual(result.revision.fields["subject"], .text("resolved"))
        XCTAssertEqual(try result.revision.provenance?.kind, .resolution)
        XCTAssertEqual(try store.resolveConflict(request).revision, result.revision)
        XCTAssertEqual(try store.history(root.itemID).count, 4)
        XCTAssertThrowsError(
            try store.resolveConflict(
                ResolveConflictRequest(
                    itemID: root.itemID, expectedStateToken: state.stateToken,
                    reviewedFrontier: request.reviewedFrontier, changes: ["subject": .text("stale")],
                    unset: [], operationID: "different")))
        try f.assertPreserved()
    }
    func testConcurrentGrantKeepsOlderRestrictivePolicyForCurrentAndHistoricalReads() throws {
        let f = try Fixture()
        let root: Revision
        do {
            let store = try f.store()
            try configure(store)
            root = try store.withAccess(forUID: f.accounts.alice) {
                try store.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: ["subject": .text("private"), "permissions": permissions(0o600)],
                        operationID: "private")
                ).revision
            }
        }
        _ = try f.branch(root, changes: ["permissions": permissions(0o640)])
        let b = try f.branch(root, changes: ["body": .text("older restriction")])
        let store = try f.store()
        XCTAssertEqual(
            try store.withAccess(forUID: f.accounts.alice) { try store.itemState(root.itemID).status },
            .conflicted)
        XCTAssertThrowsError(
            try store.withAccess(forUID: f.accounts.bob) {
                try store.get(root.itemID, revisionID: b.revisionID)
            })
        XCTAssertThrowsError(try store.withAccess(forUID: f.accounts.bob) { try store.history(root.itemID) })
        let state = try store.withAccess(forUID: f.accounts.alice) { try store.itemState(root.itemID) }
        let result = try store.withAccess(forUID: f.accounts.alice) {
            try store.resolveConflict(
                ResolveConflictRequest(
                    itemID: root.itemID, expectedStateToken: state.stateToken,
                    reviewedFrontier: try XCTUnwrap(state.frontier),
                    changes: ["permissions": permissions(0o640)], unset: [], operationID: "share-resolution"))
        }
        XCTAssertEqual(
            try store.withAccess(forUID: f.accounts.bob) { try store.get(root.itemID) }, result.revision)
        try f.assertPreserved()
    }
    func testNonadministratorOwnerCanResolveLifecycleAndContentChoices() throws {
        let f = try Fixture()
        let original: Revision
        do {
            let store = try f.store()
            try configure(store)
            original = try store.withAccess(forUID: f.accounts.alice) {
                XCTAssertFalse(store.isAdministrator)
                return try store.commit(
                    CommitRequest(
                        classID: "Item", changes: ["permissions": permissions(0o600)],
                        operationID: "owned-lifecycle")
                ).revision
            }
        }
        _ = try f.branch(original, changes: ["isDeleted": .boolean(true)])
        _ = try f.branch(original, changes: ["subject": .text("edited")])
        let store = try f.store()
        let state = try store.withAccess(forUID: f.accounts.alice) { try store.itemState(original.itemID) }
        let result = try store.withAccess(forUID: f.accounts.alice) {
            XCTAssertFalse(store.isAdministrator)
            return try store.resolveConflict(
                ResolveConflictRequest(
                    itemID: original.itemID, expectedStateToken: state.stateToken,
                    reviewedFrontier: try XCTUnwrap(state.frontier),
                    changes: ["isDeleted": .boolean(true), "subject": .text("chosen content")], unset: [],
                    operationID: "owner-lifecycle-resolution"))
        }
        XCTAssertTrue(result.revision.isDeleted)
        XCTAssertEqual(result.revision.fields["subject"], .text("chosen content"))
        try f.assertPreserved()
    }
    func testResolutionCannotRetypeAnotherItemIntoSecondAccessConfigurationRoot() throws {
        let f = try Fixture()
        let original: Revision
        let configuration: Revision
        do {
            let store = try f.store()
            configuration = try configure(store)
            original = try store.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("ordinary")], operationID: "ordinary-root")
            ).revision
        }
        _ = try f.branch(original, changes: ["subject": .text("left")])
        _ = try f.branch(original, changes: ["subject": .text("right")])
        let store = try f.store()
        let state = try store.itemState(original.itemID)
        XCTAssertThrowsError(
            try store.resolveConflict(
                ResolveConflictRequest(
                    itemID: original.itemID, expectedStateToken: state.stateToken,
                    reviewedFrontier: try XCTUnwrap(state.frontier),
                    changes: [
                        "classID": .text(AccessConfiguration.classID), "subject": .text("chosen"),
                        "accessConfiguration": configuration.fields["accessConfiguration"]!,
                    ], unset: [], operationID: "second-config"))
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "invalidAccessConfiguration") }
        XCTAssertEqual(try store.history(original.itemID).count, 3)
        try f.assertPreserved()
    }
    func testFreshGroupRevocationRejectsOrdinaryPublicationWithoutAddingCanonicalFile() throws {
        let f = try Fixture()
        let store = try f.store()
        try configure(store)
        let root = try store.withAccess(forUID: f.accounts.alice) {
            try store.commit(
                CommitRequest(
                    classID: "Item", changes: ["permissions": permissions(0o660)], operationID: "group-item")
            ).revision
        }
        store.beforeProjectionCommitAuthorityForTesting = {
            f.accounts.users[f.accounts.bob] = AccountIdentity(
                uid: f.accounts.bob, name: "bob", primaryGroupName: "staff", groupIDs: [])
        }
        XCTAssertThrowsError(
            try store.withAccess(forUID: f.accounts.bob) {
                try store.commit(
                    CommitRequest(
                        action: .revise, itemID: root.itemID, expectedRevisionID: root.revisionID,
                        changes: ["subject": .text("denied")], operationID: "revoke-race"))
            })
        XCTAssertEqual(try store.history(root.itemID).count, 1)
    }
    func testResourceFailureAfterAutomaticFilePublicationRequiresRecoveryAndRetainsTheFile() throws {
        let f = try Fixture()
        let root = try create(f)
        let store = try f.store()
        _ = try f.branch(root, changes: ["subject": .text("left")])
        _ = try f.branch(root, changes: ["body": .text("right")])
        store.beforeCombinationIndexUpdateForTesting = {
            throw TractandaError("resourceLimit", "Injected after canonical publication")
        }
        XCTAssertThrowsError(try store.rebuildIndex()) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertTrue(StoreCheckpoint.isDirty(root: f.root))
        XCTAssertThrowsError(try store.get(root.itemID))
        let files = try XCTUnwrap(
            FileManager.default.enumerator(
                at: f.root.appendingPathComponent("items"), includingPropertiesForKeys: nil)
        ).allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "tractanda" }
        XCTAssertEqual(files.count, 4, "Published merge remains alongside all three inputs")
        let retained = try Dictionary(uniqueKeysWithValues: files.map { ($0, try Data(contentsOf: $0)) })
        store.beforeCombinationIndexUpdateForTesting = nil
        try store.rebuildIndex()
        XCTAssertEqual(try store.history(root.itemID).count, 4)
        XCTAssertEqual(try store.get(root.itemID).fields["body"], .text("right"))
        for (file, bytes) in retained { XCTAssertEqual(try Data(contentsOf: file), bytes) }
        try f.assertPreserved()
    }
    func testCanonicalPublicationLimitProducesResourceStateAndPreservesOriginals() throws {
        let f = try Fixture()
        let root = try create(f)
        let store = try f.store()
        var combined = RevisionMerge.semanticFields(root)
        combined["subject"] = .text(String(repeating: "a", count: 500))
        combined["body"] = .text(String(repeating: "b", count: 500))
        store.canonicalRecordByteLimitForTesting = try JSON.encode(combined).count + 1
        _ = try f.branch(root, changes: ["subject": .text(String(repeating: "a", count: 500))])
        _ = try f.branch(root, changes: ["body": .text(String(repeating: "b", count: 500))])
        try store.rebuildIndex()
        let state = try store.itemState(root.itemID)
        XCTAssertEqual(state.status, .unmaterializable)
        XCTAssertEqual(state.resource?.phase, .publication)
        XCTAssertEqual(try store.history(root.itemID).count, 3)
        try f.assertPreserved()
        XCTAssertThrowsError(try store.get(root.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "itemUnresolved")
        }
    }
    func testCrossItemCategoryCycleRemainsEvidenceAndExplicitRepairRestoresBothItems() throws {
        let f = try Fixture()
        let a: Revision
        let b: Revision
        do {
            let store = try f.store()
            let fields: [String: ItemValue] = [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                ]), "categoryParents": .list([]),
            ]
            a = try store.commit(CommitRequest(classID: "Item", changes: fields, operationID: "category-a"))
                .revision
            b = try store.commit(CommitRequest(classID: "Item", changes: fields, operationID: "category-b"))
                .revision
        }
        _ = try f.branch(a, changes: ["categoryParents": .list([.reference(ItemReference(b.itemID))])])
        _ = try f.branch(b, changes: ["categoryParents": .list([.reference(ItemReference(a.itemID))])])
        let store = try f.store()
        XCTAssertEqual(try store.itemState(a.itemID).status, .invariantConflict)
        XCTAssertEqual(try store.itemState(b.itemID).status, .invariantConflict)
        XCTAssertEqual(try store.history(a.itemID).count, 2)
        let outsider = try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("not a category")],
                operationID: "ordinary-outsider")
        ).revision
        let state = try store.itemState(a.itemID)
        XCTAssertThrowsError(
            try store.resolveConflict(
                ResolveConflictRequest(
                    itemID: a.itemID, expectedStateToken: state.stateToken,
                    reviewedFrontier: try XCTUnwrap(state.frontier),
                    changes: ["categoryParents": .list([.reference(ItemReference(outsider.itemID))])],
                    unset: [], operationID: "invalid-category-parent")))
        XCTAssertEqual(try store.history(a.itemID).count, 2, "Rejected category target publishes no revision")
        _ = try store.resolveConflict(
            ResolveConflictRequest(
                itemID: a.itemID, expectedStateToken: state.stateToken,
                reviewedFrontier: try XCTUnwrap(state.frontier), changes: ["categoryParents": .list([])],
                unset: [], operationID: "break-cycle"))
        XCTAssertEqual(try store.itemState(a.itemID).status, .ready)
        XCTAssertEqual(try store.itemState(b.itemID).status, .ready)
        try f.assertPreserved()
    }
    func testAccessConfigurationDivergenceDeniesUsersAndPreservesAdministratorResolutionRoute() throws {
        let f = try Fixture()
        let root: Revision
        do {
            let store = try f.store()
            root = try configure(store)
        }
        var left = try XCTUnwrap(root.fields["accessConfiguration"])
        var right = left
        var leftMap = try XCTUnwrap(left.map)
        var rightMap = try XCTUnwrap(right.map)
        leftMap["users"] = .list([.text("alice")])
        rightMap["users"] = .list([.text("bob")])
        left = .object(leftMap)
        right = .object(rightMap)
        _ = try f.branch(root, changes: ["accessConfiguration": left])
        _ = try f.branch(root, changes: ["accessConfiguration": right])
        let store = try f.store()
        XCTAssertThrowsError(
            try store.withAccess(forUID: f.accounts.alice) { try store.itemState(root.itemID) })
        let state = try store.itemState(root.itemID)
        let resolved = try store.resolveConflict(
            ResolveConflictRequest(
                itemID: root.itemID, expectedStateToken: state.stateToken,
                reviewedFrontier: try XCTUnwrap(state.frontier),
                changes: ["accessConfiguration": root.fields["accessConfiguration"]!],
                unset: [], operationID: "config-resolution"))
        XCTAssertEqual(resolved.itemState?.status, .ready)
        XCTAssertNoThrow(
            try store.withAccess(forUID: f.accounts.alice) { _ = try store.queryProjectionCompleteness() })
        try f.assertPreserved()
    }
}
