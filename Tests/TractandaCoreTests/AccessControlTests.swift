import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Injectable account data tests policy logic; verify-multi-user.py separately tests real kernel peers.
final class AccessControlTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 50001
        let bob: UInt32 = 50002
        let agent: UInt32 = 50003
        var users: [UInt32: AccountIdentity] = [:]
        let groups: [String: UInt32] = ["staff": 70001, "readers": 70002, "writers": 70003]

        init() {
            for (uid, name) in [(getuid(), "admin"), (alice, "alice"), (bob, "bob"), (agent, "agent")] {
                users[uid] = AccountIdentity(
                    uid: uid, name: name, primaryGroupName: "staff", groupIDs: [70001])
            }
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
            guard let id = groups[name] else { throw TractandaError("unresolvedPrincipal", "Unknown group") }
            return id
        }
    }

    private func config(_ aliases: [String: ItemValue] = [:]) -> ItemValue {
        .object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([.text("alice"), .text("bob"), .text("agent")]),
            "userAliases": .object(aliases),
        ])
    }
    private func permissions(owner: String = "alice", mode: Int64 = 0o640, acl: [String: ItemValue] = [:])
        -> ItemValue
    {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner), "group": .text("staff"),
            "mode": .integer(mode), "acl": .object(acl),
        ])
    }
    private func fixture(_ body: (ItemStore, Accounts) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-access-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try ItemStore(root: root, accounts: accounts)
        _ = try store.configureAccess(config(), operationID: "configure")
        try body(store, accounts)
    }
    private func create(
        _ store: ItemStore, uid: UInt32, fields: [String: ItemValue] = [:], classID: String = "NoteItem"
    ) throws -> Revision {
        try store.withAccess(forUID: uid) {
            try store.commit(CommitRequest(classID: classID, changes: fields, operationID: Identifier.make()))
                .revision
        }
    }
    private func edit(_ store: ItemStore, uid: UInt32, base: Revision, fields: [String: ItemValue]) throws
        -> Revision
    {
        try store.withAccess(forUID: uid) {
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: base.itemID,
                    expectedRevisionID: base.revisionID, changes: fields, operationID: Identifier.make())
            ).revision
        }
    }
    private func assertCode(
        _ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, code, "\($0)", file: file, line: line)
        }
    }
    private func response(_ service: ItemService, uid: UInt32, method: String, args: [String: Any] = [:])
        throws -> [String: Any]
    {
        let data = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": [[method, args, "test"]],
        ])
        let result =
            try JSONSerialization.jsonObject(with: service.handle(data, peerUID: uid)) as! [String: Any]
        if let responses = result["methodResponses"] as? [[Any]] { return responses[0][1] as! [String: Any] }
        return result
    }

    func testPOSIXPrecedenceMaskAndCombinedGroupRequests() throws {
        #if canImport(Darwin)
            // Exercise Apple's actual account/group bridge as well as the injected policy cases.
            let directory = SystemAccountDirectory()
            let actual = try directory.user(forUID: geteuid())
            XCTAssertEqual(try directory.user(named: actual.name).uid, actual.uid)
            XCTAssertTrue(actual.groupIDs.contains(try directory.groupID(named: actual.primaryGroupName)))
        #endif
        let accounts = Accounts()
        let bob = AccountIdentity(
            uid: accounts.bob, name: "bob", primaryGroupName: "staff", groupIDs: [70001, 70002, 70003])
        let resolver = PrincipalResolver(directory: accounts, configuration: nil)
        let split = try ItemPermissions(
            permissions(
                mode: 0o666,
                acl: [
                    "mask": .integer(6), "owningGroup": .integer(0),
                    "groups": .object(["readers": .integer(4), "writers": .integer(2)]),
                ]))
        XCTAssertTrue(try split.allows(4, for: bob, using: resolver))
        XCTAssertTrue(try split.allows(2, for: bob, using: resolver))
        XCTAssertFalse(
            try split.allows(6, for: bob, using: resolver),
            "A read/write open cannot combine rights from separate groups")
        let denied = try ItemPermissions(
            permissions(
                mode: 0o666,
                acl: [
                    "mask": .integer(6), "owningGroup": .integer(6), "users": .object(["bob": .integer(0)]),
                ]))
        XCTAssertFalse(
            try denied.allows(4, for: bob, using: resolver),
            "Named user denial takes precedence over group and other")
        let masked = try ItemPermissions(
            permissions(
                mode: 0o646,
                acl: [
                    "mask": .integer(4), "owningGroup": .integer(6), "users": .object(["bob": .integer(6)]),
                ]))
        XCTAssertTrue(try masked.allows(4, for: bob, using: resolver))
        XCTAssertFalse(try masked.allows(6, for: bob, using: resolver))
        assertCode("invalidPermissions") {
            _ = try ItemPermissions(permissions(mode: 0o644, acl: ["users": .object(["bob": .integer(4)])]))
        }
        assertCode("invalidPermissions") { _ = try ItemPermissions(permissions(mode: 0o755)) }
    }

    func testInheritedMembershipUsesOnlyReadableCategoriesAndPersonalOverrides() throws {
        try fixture { store, accounts in
            let selection: (String) -> ItemValue = {
                .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text($0),
                ])
            }
            let parent = try create(
                store, uid: accounts.alice,
                fields: [
                    "selection": selection("itemID == \"\""), "permissions": permissions(),
                ])
            let child = try create(
                store, uid: accounts.alice,
                fields: [
                    "selection": selection("subject == \"Public note\""),
                    "categoryParents": .list([.reference(ItemReference(parent.itemID))]),
                ])
            let note = try create(
                store, uid: accounts.alice,
                fields: [
                    "subject": .text("Public note"), "permissions": permissions(),
                ])
            try store.withAccess(forUID: accounts.alice) {
                let inherited = try Categories.explain(note, category: parent, store: store)
                XCTAssertTrue(inherited.isIncluded)
                XCTAssertEqual(inherited.inheritancePath, [parent.itemID, child.itemID])
                XCTAssertEqual(inherited.sourceReason, "selection rule")
            }
            let bobState = try store.withAccess(forUID: accounts.bob) { store.state }
            try store.withAccess(forUID: accounts.bob) {
                let hidden = try Categories.explain(note, category: parent, store: store)
                XCTAssertFalse(hidden.isIncluded)
                XCTAssertNil(hidden.inheritancePath)
                XCTAssertTrue(try Categories.query(store: store, categoryPath: [parent.itemID]).isEmpty)
                XCTAssertFalse(try CategoryHierarchy(store.candidates()).items.keys.contains(child.itemID))
            }
            _ = try edit(
                store, uid: accounts.alice, base: child, fields: ["subject": .text("Private classification")])
            XCTAssertEqual(try store.withAccess(forUID: accounts.bob) { store.state }, bobState)
            _ = try create(
                store, uid: accounts.alice,
                fields: [
                    "target": .reference(ItemReference(note.itemID)),
                    "personalOverrides": .object([parent.itemID: .text("exclude")]),
                ], classID: "PersonalStateItem")
            try store.withAccess(forUID: accounts.alice) {
                let membership = try Categories.explain(note, category: parent, store: store)
                XCTAssertFalse(membership.isIncluded)
                XCTAssertEqual(membership.reason, "personal exclude")
                XCTAssertNil(membership.inheritancePath)
                XCTAssertTrue(try Categories.explain(note, category: child, store: store).isIncluded)
            }
            let manuallyIncluded = try edit(
                store, uid: accounts.alice, base: note,
                fields: ["categoryOverrides": .object([child.itemID: .text("include")])])
            try store.withAccess(forUID: accounts.alice) {
                let manual = try Categories.explain(manuallyIncluded, category: child, store: store)
                XCTAssertTrue(manual.isIncluded)
                XCTAssertEqual(manual.reason, "manual include")
                XCTAssertEqual(manual.inheritancePath, [child.itemID])
                XCTAssertEqual(manual.sourceReason, "manual include")
            }
        }
    }

    func testCurrentPermissionsHistoryRetryCopyAndOwnerControl() throws {
        try fixture { store, accounts in
            let request = CommitRequest(
                classID: "NoteItem",
                changes: ["subject": .text("Shared"), "permissions": permissions(mode: 0o660)],
                operationID: "shared-create")
            let first = try store.withAccess(forUID: accounts.alice) { try store.commit(request).revision }
            let editRequest = CommitRequest(
                action: .revise, itemID: first.itemID, expectedRevisionID: first.revisionID,
                changes: ["body": .text("Bob's contribution")], operationID: "bob-edit")
            let second = try store.withAccess(forUID: accounts.bob) { try store.commit(editRequest).revision }
            assertCode("forbidden") {
                _ = try edit(
                    store, uid: accounts.bob, base: second, fields: ["permissions": permissions(mode: 0o666)])
            }
            let copy = try store.withAccess(forUID: accounts.bob) {
                try store.commit(
                    CommitRequest(
                        action: .copy, itemID: second.itemID,
                        expectedRevisionID: second.revisionID, operationID: "copy")
                ).revision
            }
            XCTAssertEqual(copy.fields["permissions"]?.map?["owner"], .text("bob"))
            XCTAssertEqual(copy.fields["permissions"]?.map?["mode"], .integer(0o600))
            let revoked = try edit(
                store, uid: accounts.alice, base: second, fields: ["permissions": permissions(mode: 0o600)])
            try store.withAccess(forUID: accounts.bob) {
                assertCode("forbidden") { _ = try store.get(first.itemID, revisionID: first.revisionID) }
                assertCode("forbidden") { _ = try store.history(first.itemID) }
                assertCode("forbidden") { _ = try store.commit(editRequest) }
                XCTAssertEqual(try store.candidates().map(\.itemID), [copy.itemID])
                XCTAssertEqual(try store.history(copy.itemID).count, 1)
            }
            let shared = try edit(
                store, uid: accounts.alice, base: revoked, fields: ["permissions": permissions()])
            try store.withAccess(forUID: accounts.bob) {
                XCTAssertEqual(try store.history(shared.itemID).count, 4)
                XCTAssertTrue(try store.commit(editRequest).wasReplayed)
            }
        }
    }

    func testServiceAdmissionPrivateQueriesAndRoleResolution() throws {
        try fixture { store, accounts in
            let privatePerson = try create(
                store, uid: accounts.alice, fields: ["mobilePhone": .text("private-number")],
                classID: "NaturalPersonItem")
            let role = try create(
                store, uid: accounts.alice,
                fields: [
                    "phone": .text("office-number"), "permissions": permissions(),
                    "holdings": .list([
                        .object([
                            "key": .text("term"), "start": .date("2020-01-01T00:00:00Z"),
                            "holder": .reference(ItemReference(privatePerson.itemID)),
                        ])
                    ]),
                ], classID: "RoleItem")
            let service = ItemService(store: store)
            XCTAssertEqual(
                try response(service, uid: 60000, method: "Core/echo")["code"] as? String,
                "unresolvedPrincipal")
            let visible = try response(
                service, uid: accounts.bob, method: "TractandaItem/get",
                args: ["ids": [privatePerson.itemID, role.itemID]])
            XCTAssertEqual(visible["notFound"] as? [String], [privatePerson.itemID])
            XCTAssertEqual((visible["list"] as? [Any])?.count, 1)
            let query = try response(
                service, uid: accounts.bob, method: "TractandaItem/query", args: ["text": "private-number"])
            XCTAssertEqual(query["total"] as? Int, 0)
            XCTAssertEqual(
                try response(
                    service, uid: accounts.bob, method: "TractandaItem/resolve",
                    args: ["itemID": role.itemID, "path": "holder.mobilePhone"])["status"] as? String,
                "accessDenied")
            let office = try response(
                service, uid: accounts.bob, method: "TractandaItem/resolve",
                args: ["itemID": role.itemID, "path": "phone"])
            XCTAssertEqual((office["value"] as? [String: Any])?["value"] as? String, "office-number")
            XCTAssertEqual(
                try response(service, uid: accounts.bob, method: "TractandaStore/rebuild")["type"] as? String,
                "forbidden")
        }
    }

    func testSortedSectionQueriesApplyCurrentPermissionsBeforeCountingAndPaging() throws {
        try fixture { store, accounts in
            let category = try create(
                store, uid: accounts.alice,
                fields: [
                    "permissions": permissions(),
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text("rank == *"),
                    ]),
                ])
            _ = try create(store, uid: accounts.alice, fields: ["rank": .integer(-100)])
            let shared = try create(
                store, uid: accounts.alice,
                fields: [
                    "rank": .integer(10), "permissions": permissions(),
                ])
            let view = try create(
                store, uid: accounts.alice,
                fields: [
                    "permissions": permissions(),
                    "viewDefinition": .object([
                        "language": .text(SpotlightQuery.profile),
                        "sort": .list([try ItemSort(property: "rank").value]),
                        "presentation": .object([
                            "profile": .text(ViewPresentation.profile),
                            "sections": .list([.reference(ItemReference(category.itemID))]),
                        ]),
                    ]),
                ])
            let service = ItemService(store: store)
            let args: [String: Any] = ["viewID": view.itemID, "sectionID": category.itemID, "limit": 1]
            let query = try response(service, uid: accounts.bob, method: "TractandaItem/query", args: args)
            XCTAssertEqual(query["ids"] as? [String], [shared.itemID])
            XCTAssertEqual(query["total"] as? Int, 1)
            _ = try edit(
                store, uid: accounts.alice, base: category, fields: ["permissions": permissions(mode: 0o600)])
            XCTAssertEqual(
                try response(service, uid: accounts.bob, method: "TractandaItem/query", args: args)["type"]
                    as? String,
                "forbidden")
        }
    }

    func testDefaultRecentOrderFiltersPrivateEditsBeforeCountingAndPaging() throws {
        try fixture { store, accounts in
            let older = try create(
                store, uid: accounts.alice,
                fields: [
                    "sortFixture": .text("yes"), "permissions": permissions(),
                ])
            Thread.sleep(forTimeInterval: 0.002)
            let newer = try create(
                store, uid: accounts.alice,
                fields: [
                    "sortFixture": .text("yes"), "permissions": permissions(),
                ])
            let hidden = try create(
                store, uid: accounts.alice,
                fields: [
                    "sortFixture": .text("yes"), "permissions": permissions(mode: 0o600),
                ])
            let service = ItemService(store: store)
            let args: [String: Any] = ["expression": "sortFixture == \"yes\"", "limit": 1]
            let first = try response(service, uid: accounts.bob, method: "TractandaItem/query", args: args)
            XCTAssertEqual(first["ids"] as? [String], [newer.itemID])
            XCTAssertEqual(first["total"] as? Int, 2)
            let second = try response(
                service, uid: accounts.bob, method: "TractandaItem/query",
                args: args.merging(["position": 1]) { _, new in new })
            XCTAssertEqual(second["ids"] as? [String], [older.itemID])
            _ = try edit(store, uid: accounts.alice, base: hidden, fields: ["body": .text("Private update")])
            let after = try response(service, uid: accounts.bob, method: "TractandaItem/query", args: args)
            XCTAssertEqual(after["ids"] as? [String], first["ids"] as? [String])
            XCTAssertEqual(after["queryState"] as? String, first["queryState"] as? String)
        }
    }

    func testPersonalCategoriesAndLearningScopesDoNotAlterSharedItem() throws {
        try fixture { store, accounts in
            let category = try create(
                store, uid: accounts.alice,
                fields: [
                    "permissions": permissions(),
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile),
                        "expression": .text("subject == \"never\""),
                    ]),
                ])
            let shared = try create(
                store, uid: accounts.alice,
                fields: ["permissions": permissions(), "subject": .text("chess tournament")])
            let service = ItemService(store: store)
            let before = try store.withAccess(forUID: accounts.bob) { store.state }
            let overlay = try create(
                store, uid: accounts.alice,
                fields: [
                    "target": .reference(ItemReference(shared.itemID)),
                    "personalOverrides": .object([category.itemID: .text("include")]),
                ], classID: "PersonalStateItem")
            XCTAssertEqual(try store.get(shared.itemID), shared)
            try store.withAccess(forUID: accounts.alice) {
                XCTAssertEqual(
                    try Categories.query(store: store, categoryPath: [category.itemID]).map(\.itemID),
                    [shared.itemID])
                XCTAssertEqual(try service.learning.status(for: category.itemID).positiveExamples, 1)
            }
            try store.withAccess(forUID: accounts.bob) {
                XCTAssertEqual(
                    store.state, before,
                    "Private edits must not reveal themselves in another user's state token")
                XCTAssertEqual(try Categories.query(store: store, categoryPath: [category.itemID]).count, 0)
                XCTAssertEqual(try service.learning.status(for: category.itemID).positiveExamples, 0)
            }
            for (text, label) in [
                ("chess players board", "include"), ("garden vegetables soil", "exclude"),
                ("garden soil flowers", "exclude"),
            ] {
                _ = try create(
                    store, uid: accounts.alice,
                    fields: [
                        "subject": .text(text), "categoryOverrides": .object([category.itemID: .text(label)]),
                    ])
            }
            let aliceModel = try store.withAccess(forUID: accounts.alice) {
                try service.learning.train(categoryID: category.itemID).modelID
            }
            XCTAssertNotNil(aliceModel)
            let captured = try store.withAccess(forUID: accounts.alice) { service.learning }
            try store.withAccess(forUID: accounts.bob) {
                assertCode("forbidden") { _ = try captured.status(for: category.itemID) }
            }
            try store.withAccess(forUID: accounts.bob) {
                _ = try service.learning.reset(categoryID: category.itemID)
            }
            XCTAssertEqual(
                try store.withAccess(forUID: accounts.alice) {
                    try service.learning.status(for: category.itemID).modelID
                }, aliceModel)
            assertCode("invalidPersonalState") {
                _ = try create(
                    store, uid: accounts.alice,
                    fields: [
                        "target": .reference(ItemReference(shared.itemID)),
                        "personalOverrides": overlay.fields["personalOverrides"]!,
                    ], classID: "PersonalStateItem")
            }
        }
    }

    func testAliasesGroupRefreshAndRecoveryFromOnlyCanonicalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-alias-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        var store: ItemStore? = try ItemStore(root: root, accounts: accounts)
        let value = config(["former-alice": .text("alice"), "another-alice": .text("alice")])
        _ = try store!.configureAccess(value, operationID: "configure")
        let first = try create(
            store!, uid: accounts.alice, fields: ["permissions": permissions(owner: "former-alice")])
        let oldBytes = try JSON.encode(first)
        try store!.withAccess(forUID: accounts.bob) { XCTAssertEqual(try store!.get(first.itemID), first) }
        accounts.users[accounts.bob] = AccountIdentity(
            uid: accounts.bob, name: "bob", primaryGroupName: "readers", groupIDs: [70002])
        try store!.withAccess(forUID: accounts.bob) {
            assertCode("forbidden") { _ = try store!.get(first.itemID) }
        }
        assertCode("ambiguousPrincipal") {
            _ = try store!.configureAccess(config(["bob": .text("alice")]), operationID: "ambiguous")
        }
        assertCode("invalidAccessConfiguration") {
            _ = try AccessConfiguration(config(["a": .text("b"), "b": .text("a")]))
        }
        assertCode("ambiguousPrincipal") {
            _ = try create(
                store!, uid: accounts.alice,
                fields: [
                    "permissions": permissions(
                        mode: 0o640,
                        acl: [
                            "mask": .integer(4), "owningGroup": .integer(0),
                            "users": .object(["former-alice": .integer(4), "another-alice": .integer(4)]),
                        ])
                ])
        }
        store = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
        store = try ItemStore(root: root, accounts: accounts)
        XCTAssertTrue(store!.isMultiUser)
        try store!.withAccess(forUID: accounts.alice) {
            XCTAssertEqual(try JSON.encode(store!.get(first.itemID)), oldBytes)
        }
        try store!.withAccess(forUID: accounts.bob) {
            assertCode("forbidden") { _ = try store!.get(first.itemID) }
        }
    }
}
