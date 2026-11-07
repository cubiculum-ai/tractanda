import CTractandaPlatform
import TractandaClient
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ItemFieldOperationTests: XCTestCase {
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 52_001
        let bob: UInt32 = 52_002
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            switch uid {
            case tractanda_uid(): name = "admin"
            case alice: name = "alice"
            case bob: name = "bob"
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture account.")
            }
            return AccountIdentity(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [72_001])
        }
        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": return try user(forUID: tractanda_uid())
            case "alice": return try user(forUID: alice)
            case "bob": return try user(forUID: bob)
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture account.")
            }
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Unknown group.") }
            return 72_001
        }
    }

    override func setUpWithError() throws {
        var capacity = statvfs()
        guard statvfs(FileManager.default.temporaryDirectory.path, &capacity) == 0,
            capacity.f_frsize > 0,
            UInt64(capacity.f_bavail) >= (10 * 1024 * 1024 * 1024 + 32 * 1024 * 1024)
                / UInt64(capacity.f_frsize)
        else {
            throw TractandaError("resourceLimit", "Small field-operation fixtures require a 10 GiB reserve.")
        }
    }

    private func fixture(_ body: (URL, Accounts) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-field-ops-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, Accounts())
    }
    private func permissions(owner: String = "alice", mode: Int64 = 0o600) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner), "group": .text("staff"),
            "mode": .integer(mode), "acl": .object([:]),
        ])
    }
    private func policy() -> ItemValue {
        .object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([.text("alice"), .text("bob")]),
        ])
    }
    private func revise(
        _ revision: Revision, _ operations: [ItemFieldOperation], operation: String = Identifier.make()
    ) -> CommitRequest {
        .init(
            action: .revise, itemID: revision.itemID, expectedRevisionID: revision.revisionID,
            operationID: operation, fieldOperations: operations)
    }
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected, "\($0)") }
    }

    func testMaterializesCompleteSnapshotsAndReplaysOriginalIntentAfterRebuild() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try ItemStore.initializeFresh(root: root, accounts: accounts)
            let original = try store!.commit(
                .init(
                    classID: "Item",
                    changes: [
                        "subject": .text("keep"), "notes": .list([.text("old")]),
                        "settings": .object(["unknown": .integer(7), "last": .text("remove")]),
                    ], operationID: "create")
            ).revision
            let request = revise(
                original,
                [
                    .init(op: .append, field: "notes", value: .integer(Int64.max)),
                    .init(op: .append, field: "notes", value: .integer(Int64.max)),
                    .init(
                        op: .setKey, field: "settings", key: "literal./~",
                        value: .date("2026-11-07T12:00:00Z")),
                    .init(op: .removeKey, field: "settings", key: "last"),
                    .init(op: .removeKey, field: "absent", key: "missing"),
                ], operation: "delta")
            let saved = try store!.commit(request).revision
            XCTAssertEqual(saved.fields["subject"], original.fields["subject"])
            XCTAssertEqual(
                saved.fields["notes"], .list([.text("old"), .integer(Int64.max), .integer(Int64.max)]))
            XCTAssertEqual(
                saved.fields["settings"],
                .object([
                    "unknown": .integer(7), "literal./~": .date("2026-11-07T12:00:00Z"),
                ]))
            XCTAssertNil(saved.fields["absent"])
            XCTAssertEqual(
                saved.fields["requestIdentity"]?.string, try JSON.encode(request).base64EncodedString())
            XCTAssertEqual(try saved.provenance?.writtenFields, ["notes", "settings"])
            XCTAssertEqual(try saved.provenance?.unsetFields, [])
            let latest = try store!.commit(
                revise(saved, [.init(op: .append, field: "notes", value: .text("later"))])
            )
            .revision
            XCTAssertTrue(try store!.commit(request).wasReplayed)
            XCTAssertEqual(try store!.get(original.itemID), latest)
            store = nil
            store = try ItemStore.openInitialized(root: root, accounts: accounts)
            try store!.rebuildIndex()
            XCTAssertEqual(try store!.commit(request).revision, saved)
            XCTAssertEqual(try store!.get(original.itemID), latest)
            var changed = request
            changed.fieldOperations![0].value = .text("different intent")
            code("operationMismatch") { _ = try store!.commit(changed) }
        }
    }

    func testMissingAndEmptyCollectionsAndStrictRevisionCAS() throws {
        try fixture { root, accounts in
            let store = try ItemStore.initializeFresh(root: root, accounts: accounts)
            let original = try store.commit(.init(classID: "Item", operationID: "create")).revision
            let first = try store.commit(
                revise(
                    original,
                    [
                        .init(op: .append, field: "notes", value: .list([.text("one tagged list value")])),
                        .init(op: .setKey, field: "settings", key: "only", value: .boolean(true)),
                    ])
            ).revision
            XCTAssertEqual(first.fields["notes"], .list([.list([.text("one tagged list value")])]))
            let second = try store.commit(
                revise(first, [.init(op: .removeKey, field: "settings", key: "only")])
            )
            .revision
            XCTAssertEqual(second.fields["settings"], .object([:]))
            let noOpRequest = revise(
                second, [.init(op: .removeKey, field: "absent", key: "missing")], operation: "no-op")
            let noOp = try store.commit(noOpRequest).revision
            XCTAssertNotEqual(noOp.revisionID, second.revisionID)
            XCTAssertEqual(noOp.supersedes, second.revisionID)
            XCTAssertEqual(try noOp.provenance?.writtenFields, [])
            XCTAssertEqual(try noOp.provenance?.unsetFields, [])
            XCTAssertNil(noOp.fields["absent"])
            XCTAssertTrue(try store.commit(noOpRequest).wasReplayed)
            XCTAssertEqual(try store.history(original.itemID).count, 4)
            let stale = revise(original, [.init(op: .append, field: "notes", value: .text("new"))])
            code("revisionConflict") { _ = try store.commit(stale) }
            var noCAS = stale
            noCAS.expectedRevisionID = nil
            code("invalidArguments") { _ = try store.commit(noCAS) }
            XCTAssertEqual(try store.get(original.itemID), noOp)
        }
    }

    func testInvalidOperationsCannotPartiallyPublishOrBypassReservedFields() throws {
        try fixture { root, accounts in
            let store = try ItemStore.initializeFresh(root: root, accounts: accounts)
            let original = try store.commit(
                .init(
                    classID: "Item", changes: ["scalar": .text("wrong type")], operationID: "create")
            ).revision
            let invalid: [[ItemFieldOperation]] =
                [
                    [
                        .init(op: .append, field: "new", value: .text("not saved")),
                        .init(op: .append, field: "scalar", value: .text("bad")),
                    ],
                    [.init(op: .setKey, field: "scalar", key: "key", value: .text("bad"))],
                    [.init(op: .append, field: "notes")],
                    [.init(op: .append, field: "notes", key: "bad", value: .text("bad"))],
                    [.init(op: .removeKey, field: "map", key: "key", value: .text("bad"))],
                    [.init(op: .setKey, field: "map", key: "", value: .text("bad"))],
                    [
                        .init(op: .setKey, field: "map", key: "key", value: .text("one")),
                        .init(op: .removeKey, field: "map", key: "key"),
                    ],
                    [
                        .init(op: .append, field: "mixed", value: .text("one")),
                        .init(op: .removeKey, field: "mixed", key: "key"),
                    ],
                    Array(
                        repeating: .init(op: .append, field: "notes", value: .text("over bound")), count: 257),
                ]
                + [
                    "itemID", "revisionID", "classID", "schemaVersion", "actor", "revisionAncestry",
                    "attachments", "attachmentText", "attachmentDocument",
                ].map {
                    [.init(op: .append, field: $0, value: .text("forged"))]
                }
            for operations in invalid {
                code("invalidArguments") { _ = try store.commit(revise(original, operations)) }
                XCTAssertEqual(try store.get(original.itemID), original)
            }
            var collision = revise(original, [.init(op: .append, field: "notes", value: .text("new"))])
            collision.changes["notes"] = .list([])
            code("invalidArguments") { _ = try store.commit(collision) }
            collision.changes = [:]
            collision.unset = ["notes"]
            code("invalidArguments") { _ = try store.commit(collision) }
            for action in [CommitRequest.Action.create, .retype, .copy] {
                var request = revise(original, [.init(op: .append, field: "notes", value: .text("bad"))])
                request.action = action
                code("invalidArguments") { _ = try store.commit(request) }
            }
            store.canonicalRecordByteLimitForTesting = 4096
            code("resourceLimit") {
                _ = try store.commit(
                    revise(
                        original,
                        [
                            .init(
                                op: .append, field: "notes", value: .text(String(repeating: "x", count: 5000))
                            )
                        ]))
            }
            XCTAssertEqual(try store.get(original.itemID), original)
        }
    }

    func testCurrentPermissionsAndCategoryChecksApplyToMaterializedEdits() throws {
        try fixture { root, accounts in
            let store = try ItemStore.initializeFresh(root: root, accounts: accounts)
            try store.configurePersonalAccess(policy())
            let shared = try store.withAccess(forUID: accounts.alice) {
                try store.commit(
                    .init(
                        classID: "Item", changes: ["permissions": permissions(mode: 0o666)],
                        operationID: "shared")
                )
                .revision
            }
            code("forbidden") {
                try store.withAccess(forUID: accounts.bob) {
                    _ = try store.commit(
                        revise(
                            shared,
                            [.init(op: .setKey, field: "permissions", key: "mode", value: .integer(0o600))]))
                }
            }
            let privateCategory = try store.withAccess(forUID: accounts.alice) {
                try store.commit(
                    .init(
                        classID: "Item",
                        changes: [
                            "permissions": permissions(),
                            "selection": .object([
                                "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                            ]),
                        ], operationID: "private-category")
                ).revision
            }
            let overlay = try store.withAccess(forUID: accounts.bob) {
                try store.commit(
                    .init(
                        classID: "PersonalStateItem",
                        changes: ["target": .reference(.init(shared.itemID))],
                        operationID: "overlay")
                ).revision
            }
            for (field, target) in [("categoryOverrides", shared), ("personalOverrides", overlay)] {
                code("forbidden") {
                    try store.withAccess(forUID: accounts.bob) {
                        _ = try store.commit(
                            revise(
                                target,
                                [
                                    .init(
                                        op: .setKey, field: field, key: privateCategory.itemID,
                                        value: .text("include"))
                                ]))
                    }
                }
            }
            let request = revise(
                shared, [.init(op: .append, field: "notes", value: .text("new"))], operation: "bob-note")
            let saved = try store.withAccess(forUID: accounts.bob) { try store.commit(request).revision }
            _ = try store.withAccess(forUID: accounts.alice) {
                try store.commit(
                    .init(
                        action: .revise, itemID: shared.itemID, expectedRevisionID: saved.revisionID,
                        changes: ["permissions": permissions()], operationID: "revoke"))
            }
            code("forbidden") { try store.withAccess(forUID: accounts.bob) { _ = try store.commit(request) } }
        }
    }

    func testNativeBoundaryRejectsUnknownKeysAndOversizedOperationArrays() throws {
        try fixture { root, accounts in
            let store = try ItemStore.initializeFresh(root: root, accounts: accounts)
            let original = try store.commit(.init(classID: "Item", operationID: "create")).revision
            let service = ItemService(store: store)
            let client = TractandaCore.ItemClient(transport: { service.handle($0, peerUID: tractanda_uid()) })
            let badOperations: [Any] = [
                [
                    [
                        "op": "append", "field": "notes", "value": ["type": "text", "value": "new"],
                        "extra": true,
                    ]
                ],
                [
                    [
                        "op": "append", "field": "notes", "value": ["type": "text", "value": "new"],
                        "key": "bad",
                    ]
                ],
                [["op": "unknown", "field": "notes"]],
                Array(repeating: ["op": "removeKey", "field": "settings", "key": "a"], count: 257),
                "not an array",
            ]
            for operations in badOperations {
                code("invalidArguments") {
                    _ = try client.call(
                        "TractandaItem/commit",
                        arguments: [
                            "action": "revise", "itemID": original.itemID,
                            "expectedRevisionID": original.revisionID,
                            "changes": [:], "unset": [], "operationID": Identifier.make(),
                            "fieldOperations": operations,
                        ])
                }
                XCTAssertEqual(try store.get(original.itemID), original)
            }
        }
    }

    func testPartialEditsRefreshSavedListFiltersAndCategoryMembership() throws {
        try fixture { root, accounts in
            let store = try ItemStore.initializeFresh(root: root, accounts: accounts)
            let target = try store.commit(
                .init(
                    classID: "Item", changes: ["notes": .list([.text("hidden")])], operationID: "target")
            ).revision
            let category = try store.commit(
                .init(
                    classID: "Item",
                    changes: [
                        "selection": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
                        ])
                    ], operationID: "category")
            ).revision
            let listView = try store.commit(
                .init(
                    classID: "Item",
                    changes: [
                        "viewDefinition": .object([
                            "language": .text(SpotlightQuery.profile),
                            "expression": .text("notes == \"visible\""),
                        ])
                    ], operationID: "list-view")
            ).revision
            let categoryView = try store.commit(
                .init(
                    classID: "Item",
                    changes: [
                        "viewDefinition": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                            "categoryPath": .list([.reference(.init(category.itemID))]),
                        ])
                    ], operationID: "category-view")
            ).revision
            func page(_ view: Revision, expression: String, categories: [String] = []) throws -> [String] {
                try Categories.page(
                    store: store, expression: expression, text: nil, categoryPath: categories,
                    excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
                    timeZone: "UTC", savedViewID: view.itemID
                ).ids
            }
            XCTAssertEqual(try page(listView, expression: "notes == \"visible\""), [])
            XCTAssertEqual(
                try page(categoryView, expression: "itemID == *", categories: [category.itemID]), [])
            _ = try store.commit(
                revise(
                    target,
                    [
                        .init(op: .append, field: "notes", value: .text("visible")),
                        .init(
                            op: .setKey, field: "categoryOverrides", key: category.itemID,
                            value: .text("include")),
                    ]))
            XCTAssertEqual(try page(listView, expression: "notes == \"visible\""), [target.itemID])
            XCTAssertEqual(
                try page(categoryView, expression: "itemID == *", categories: [category.itemID]),
                [target.itemID])
        }
    }

    private struct CoordinatorTransport: ItemTransport {
        let coordinator: ServiceCoordinator
        func send(_ request: Data) async throws -> Data {
            try await coordinator.handle(request, forUID: tractanda_uid())
        }
    }

    func testTwoNativeClientsUseStrictCASAndReconcileWithSmallAppendPayloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-field-clients-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try ItemStore.initializeFresh(root: root) }
        let coordinator = try await ServiceCoordinator(opening: root)
        do {
            let first = TractandaClient.ItemClient(transport: CoordinatorTransport(coordinator: coordinator))
            let second = TractandaClient.ItemClient(transport: CoordinatorTransport(coordinator: coordinator))
            let created = try await first.commit(
                .init(classID: "Item", changes: ["notes": .list([.text("old")])], operationID: "create"))
            let base = try await first.revision(for: created.itemID)
            let requestA = revise(
                base, [.init(op: .append, field: "notes", value: .text("same"))], operation: "a")
            let requestB = revise(
                base, [.init(op: .append, field: "notes", value: .text("same"))], operation: "b")
            async let resultA = Self.capture { try await first.commit(requestA) }
            async let resultB = Self.capture { try await second.commit(requestB) }
            let results = await [resultA, resultB]
            let successes = results.compactMap { try? $0.get() }
            let failures = results.compactMap { result -> TractandaError? in
                if case .failure(let error) = result { return error as? TractandaError }
                return nil
            }
            XCTAssertEqual(successes.count, 1)
            XCTAssertEqual(failures.map(\.code), ["revisionConflict"])
            let current = try await second.revision(for: base.itemID)
            var retry = successes.first?.operationID == "a" ? requestB : requestA
            retry.expectedRevisionID = current.revisionID
            _ = try await second.commit(retry)
            let saved = try await first.revision(for: base.itemID)
            XCTAssertEqual(saved.fields["notes"], .list([.text("old"), .text("same"), .text("same")]))
            XCTAssertTrue(retry.changes.isEmpty)
            XCTAssertEqual(retry.fieldOperations?.count, 1)
            let replay = try await second.commit(retry)
            XCTAssertTrue(replay.wasReplayed)
            await coordinator.close()
        } catch {
            await coordinator.close()
            throw error
        }
    }

    private static func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error>
    {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
