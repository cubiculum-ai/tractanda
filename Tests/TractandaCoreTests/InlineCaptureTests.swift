import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class InlineCaptureTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let users: [AccountIdentity] = [
            AccountIdentity(uid: getuid(), name: "admin", primaryGroupName: "staff", groupIDs: [70001]),
            AccountIdentity(uid: 50001, name: "alice", primaryGroupName: "staff", groupIDs: [70001]),
            AccountIdentity(uid: 50002, name: "bob", primaryGroupName: "staff", groupIDs: [70001]),
        ]
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard let user = users.first(where: { $0.uid == uid }) else {
                throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return user
        }
        func user(named name: String) throws -> AccountIdentity {
            guard let user = users.first(where: { $0.name == name }) else {
                throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return user
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Unknown group") }
            return 70001
        }
    }
    private let anchor = "2026-03-28T23:30:00.000Z"
    private func fixture(_ body: (ItemStore) throws -> Void) throws {
        // Estimated <1MiB total; existing tiny-fixture guard reserves 10GiB + 32MiB.
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capture-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(AttachmentFixtureCapacity.makeStore(root: root))
    }
    private func create(_ store: ItemStore, _ fields: [String: ItemValue]) throws -> Revision {
        try AttachmentFixtureCapacity.requireFree(at: store.root)
        return try store.commit(
            CommitRequest(classID: "Item", changes: fields, operationID: Identifier.make())
        ).revision
    }
    private func edit(_ store: ItemStore, _ base: Revision, _ fields: [String: ItemValue]) throws -> Revision
    {
        try AttachmentFixtureCapacity.requireFree(at: store.root)
        return try store.commit(
            CommitRequest(
                action: .revise, itemID: base.itemID,
                expectedRevisionID: base.revisionID, changes: fields, operationID: Identifier.make())
        ).revision
    }
    private func category(_ store: ItemStore, _ name: String, fields: [String: ItemValue] = [:]) throws
        -> Revision
    {
        var values: [String: ItemValue] = [
            "subject": .text(name),
            "selection": .object([
                "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
            ]),
        ]
        values.merge(fields) { _, new in new }
        return try create(store, values)
    }
    private func dateConfig(
        _ property: String = "plannedDate", offset: Int64 = 1,
        zone: String = "Europe/Vienna"
    ) -> ItemValue {
        .object(["property": .text(property), "dayOffset": .integer(offset), "timeZone": .text(zone)])
    }
    private func prepare(
        _ store: ItemStore, _ body: String, base: Revision? = nil,
        at: String? = nil, extra: [String: ItemValue] = [:]
    ) throws -> CapturePlan {
        var fields = extra
        fields["body"] = .text(body)
        return try store.prepareCapture(
            CapturePreparation(
                request: CommitRequest(
                    action: base == nil ? .create : .revise, itemID: base?.itemID,
                    expectedRevisionID: base?.revisionID, classID: base == nil ? "Item" : nil,
                    changes: fields, operationID: Identifier.make()), at: at ?? anchor))
    }
    private func save(_ store: ItemStore, _ plan: CapturePlan) throws -> CommitResult {
        try AttachmentFixtureCapacity.requireFree(at: store.root)
        return try store.commitCapture(plan)
    }

    func testConfiguredTomorrowExampleFrozenAcrossDSTMembershipAndRebuild() throws {
        try fixture { store in
            let tomorrow = try category(
                store, "Tomorrow",
                fields: [
                    "captureDate": dateConfig(),
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                        "timeZone": .text("Europe/Vienna"),
                        "timeWindow": .object([
                            "startProperty": .text("plannedDate"), "period": .text("day"),
                            "offset": .integer(1),
                        ]),
                    ]),
                ])
            let ready = try category(store, "Ready")
            let project = try category(store, "Tractanda")
            let body = "#tomorrow we’re #ready to implement hashtag references in #Tractanda"
            let plan = try prepare(store, body, extra: ["unknown": .list([.text("preserved")])])
            XCTAssertTrue(plan.canCommit)
            XCTAssertEqual(plan.commitRequest.changes["plannedDate"], .text("2026-03-30"))
            XCTAssertNil(plan.commitRequest.changes["categoryOverrides"]?.map?[tomorrow.itemID])
            let saved = try save(store, plan).revision
            XCTAssertEqual(saved.fields["body"], .text(body))
            XCTAssertEqual(saved.fields["unknown"], .list([.text("preserved")]))
            for cat in [ready, project] {
                XCTAssertEqual(saved.fields["categoryOverrides"]?.map?[cat.itemID], .text("include"))
            }
            XCTAssertTrue(
                try Categories.explain(
                    saved, category: tomorrow, store: store,
                    at: Timestamp.parse(anchor)!
                ).isIncluded)
            XCTAssertFalse(
                try Categories.explain(
                    saved, category: tomorrow, store: store,
                    at: Timestamp.parse("2026-03-30T12:00:00Z")!
                ).isIncluded)
            _ = try edit(store, tomorrow, ["subject": .text("Next day")])
            XCTAssertTrue(try save(store, plan).wasReplayed)
            try store.rebuildIndex()
            XCTAssertTrue(try save(store, plan).wasReplayed)
            XCTAssertEqual(try store.get(saved.itemID).fields["plannedDate"], .text("2026-03-30"))
            XCTAssertNoThrow(try UUIDVersion1Components(UUID(uuidString: saved.itemID)!))
        }
    }

    func testMidnightFixedTimezoneAndNegativeCalendarOffsets() throws {
        let at = Timestamp.parse("2026-10-24T23:30:00Z")!
        XCTAssertEqual(try CategoryCaptureDate(dateConfig(zone: "Europe/Vienna")).date(at: at), "2026-10-26")
        XCTAssertEqual(
            try CategoryCaptureDate(dateConfig(zone: "America/Los_Angeles")).date(at: at), "2026-10-25")
        XCTAssertEqual(try CategoryCaptureDate(dateConfig(offset: -1)).date(at: at), "2026-10-24")
    }

    func testAmbiguityAliasesQualifiedPathsStableIDsAndUnknowns() throws {
        try fixture { store in
            let deadlines = try category(store, "Deadlines")
            let events = try category(store, "Events")
            let a = try category(
                store, "Tomorrow",
                fields: [
                    "categoryParents": .list([.reference(ItemReference(deadlines.itemID))]),
                    "captureAliases": .list([.text("deadline-tomorrow")]),
                ])
            _ = try category(
                store, "Tomorrow",
                fields: ["categoryParents": .list([.reference(ItemReference(events.itemID))])])
            let ambiguous = try prepare(store, "#tomorrow #unknown")
            XCTAssertEqual(ambiguous.issues.map(\.code), ["ambiguous", "unknown"])
            XCTAssertEqual(ambiguous.mentions[0].candidates.count, 2)
            XCTAssertThrowsError(try save(store, ambiguous))
            for token in ["#[Deadlines/Tomorrow]", "#deadline-tomorrow", "#[\(a.itemID)]"] {
                let plan = try prepare(store, token)
                XCTAssertTrue(plan.canCommit)
                XCTAssertEqual(plan.mentions.first?.categoryID, a.itemID)
            }
        }
    }

    func testLiteralEscapesCodeURLFragmentsAndOrdinaryImportedBodies() throws {
        try fixture { store in
            let ready = try category(store, "Ready")
            let body =
                "\\#literal `#code` https://example.test/#fragment word#inside [link](#ready)\n```swift\n#fenced\n```\n~~~\n#alsoCode\n~~~\n#ready"
            let plan = try prepare(store, body)
            XCTAssertEqual(plan.mentions.map(\.token), ["#ready"])
            let saved = try save(store, plan).revision
            XCTAssertEqual(saved.fields["body"], .text(body))
            XCTAssertEqual(saved.fields["categoryOverrides"]?.map?[ready.itemID], .text("include"))
            let imported = try create(store, ["body": .text("#ready")])
            XCTAssertNil(imported.fields["categoryOverrides"])
            XCTAssertNil(imported.fields["inlineCaptureBindings"])
        }
    }

    func testRenamesCaseNFCAndManualEditsPreserveConsumedBindings() throws {
        try fixture { store in
            let category = try category(store, "Café", fields: ["captureDate": dateConfig()])
            var note = try save(store, prepare(store, "#Café")).revision
            _ = try edit(
                store, category, ["subject": .text("Renamed"), "captureDate": dateConfig(offset: 3)])
            note = try edit(
                store, note,
                [
                    "plannedDate": .text("2030-01-01"),
                    "categoryOverrides": .object([category.itemID: .text("exclude")]),
                ])
            let plan = try prepare(
                store, "#CAFE\u{301} changed body", base: note,
                at: "2026-04-15T12:00:00Z")
            XCTAssertTrue(plan.canCommit)
            XCTAssertTrue(plan.mentions[0].reusedBinding)
            XCTAssertEqual(plan.mentions[0].categoryID, category.itemID)
            XCTAssertNil(plan.commitRequest.changes["plannedDate"])
            let saved = try save(store, plan).revision
            XCTAssertEqual(saved.fields["plannedDate"], .text("2030-01-01"))
            XCTAssertEqual(saved.fields["categoryOverrides"]?.map?[category.itemID], .text("exclude"))
        }
    }

    func testRemovalIsAdditiveButReintroductionIsFreshAndDateConflictsAreVisible() throws {
        try fixture { store in
            let tomorrow = try category(store, "Tomorrow", fields: ["captureDate": dateConfig()])
            let original = try save(store, prepare(store, "#tomorrow")).revision
            let removed = try save(store, prepare(store, "text only", base: original)).revision
            XCTAssertEqual(removed.fields["plannedDate"], original.fields["plannedDate"])
            XCTAssertEqual(removed.fields["inlineCaptureBindings"], original.fields["inlineCaptureBindings"])
            let reintroduced = try prepare(store, "#tomorrow", base: removed, at: "2026-04-02T12:00:00Z")
            XCTAssertFalse(reintroduced.mentions[0].reusedBinding)
            XCTAssertEqual(reintroduced.issues.map(\.code), ["dateConflict"])
            XCTAssertThrowsError(try save(store, reintroduced))
            let excluded = try prepare(
                store, "#tomorrow", extra: ["categoryOverrides": .object([tomorrow.itemID: .text("exclude")])]
            )
            XCTAssertEqual(excluded.issues.map(\.code), ["excluded"])
            let pinned = try prepare(
                store, "#tomorrow",
                extra: [
                    "categoryOverrides": .object([tomorrow.itemID: .text("include")])
                ])
            XCTAssertEqual(pinned.issues.map(\.code), ["dateOverrideConflict"])
            let explicit = try prepare(
                store, "#tomorrow", extra: ["plannedDate": .date("2026-03-30T12:00:00Z")])
            XCTAssertEqual(explicit.issues.map(\.code), ["dateConflict"])
        }
    }

    func testGuardedAtomicCommitRejectsCategorySourceChangesAndTamperedPlan() throws {
        try fixture { store in
            let category = try category(store, "Ready")
            let plan = try prepare(store, "#ready")
            _ = try edit(store, category, ["subject": .text("Changed")])
            XCTAssertThrowsError(try save(store, plan)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "captureChanged")
            }
            XCTAssertEqual(try store.candidates().count, 1)
            let base = try create(store, ["body": .text("before")])
            let editPlan = try prepare(store, "#[\(category.itemID)]", base: base)
            _ = try edit(store, base, ["subject": .text("concurrent")])
            XCTAssertThrowsError(try save(store, editPlan)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "revisionConflict")
            }
            let safe = try prepare(store, "#[\(category.itemID)]")
            var forged = safe.commitRequest
            forged.changes["extra"] = .text("unreviewed")
            let tampered = CapturePlan(
                request: safe.request, evaluatedAt: safe.evaluatedAt, commitRequest: forged,
                categoryRevisionIDs: safe.categoryRevisionIDs, mentions: safe.mentions, issues: safe.issues)
            XCTAssertThrowsError(try save(store, tampered)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "captureChanged")
            }
            XCTAssertEqual(try store.candidates().count, 2)
        }
    }

    func testConfigurationValidationAndNativeClientPreviewCommit() throws {
        try fixture { store in
            for property in [
                "body", "subject", "permissions", "categoryOverrides", "itemID", "inlineCaptureBindings",
            ] {
                XCTAssertThrowsError(
                    try category(store, "Bad", fields: ["captureDate": dateConfig(property)]))
            }
            _ = try category(store, "Next", fields: ["captureDate": dateConfig("customDate", zone: "UTC")])
            let service = ItemService(store: store)
            let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
            let preparation = CapturePreparation(
                request: CommitRequest(
                    classID: "Item",
                    changes: ["body": .text("#Next")], operationID: Identifier.make()), at: anchor)
            let plan = try client.prepareCapture(preparation)
            XCTAssertTrue(plan.canCommit)
            let receipt = try client.commitCapture(plan)
            XCTAssertEqual(try client.revision(itemID: receipt.itemID, revisionID: receipt.revisionID).fields["customDate"], .text("2026-03-29"))
            XCTAssertTrue(try client.commitCapture(plan).wasReplayed)
        }
    }

    func testReadableCatalogCurrentACLAndPersonalExclusion() throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capture-acl-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root, accounts: Accounts())
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]), operationID: "configure")
        func permissions(_ owner: String) -> ItemValue {
            .object([
                "profile": .text(ItemPermissions.profile), "owner": .text(owner),
                "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:]),
            ])
        }
        _ = try category(store, "Ready", fields: ["permissions": permissions("alice")])
        let readable = try category(store, "Ready", fields: ["permissions": permissions("bob")])
        let plan = try store.withAccess(forUID: 50002) { try prepare(store, "#ready") }
        XCTAssertTrue(plan.canCommit, "Hidden duplicate names do not leak or cause ambiguity")
        XCTAssertEqual(plan.mentions[0].categoryID, readable.itemID)
        let note = try store.withAccess(forUID: 50002) { try save(store, plan).revision }
        _ = try store.withAccess(forUID: 50002) {
            try store.commit(
                CommitRequest(
                    classID: "PersonalStateItem",
                    changes: [
                        "target": .reference(ItemReference(note.itemID)),
                        "personalOverrides": .object([readable.itemID: .text("exclude")]),
                    ], operationID: "personal-exclude"))
        }
        let freshNote = try store.withAccess(forUID: 50002) {
            try edit(store, note, ["body": .text("removed")])
        }
        let excluded = try store.withAccess(forUID: 50002) { try prepare(store, "#ready", base: freshNote) }
        XCTAssertEqual(excluded.issues.map(\.code), ["excluded"])
        let frozen = try store.withAccess(forUID: 50002) { try prepare(store, "#[\(readable.itemID)]") }
        _ = try edit(store, readable, ["permissions": permissions("alice")])
        XCTAssertThrowsError(try store.withAccess(forUID: 50002) { try save(store, frozen) }) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
        }
    }

    func testSharedDAGResolutionAndAmbiguityPlansAreBounded() throws {
        func record(_ name: String, parents: [Revision] = [], body: String = "") throws -> Revision {
            try Revision(fields: [
                "itemID": .text(Identifier.make()), "revisionID": .text(Identifier.make()),
                "classID": .text("Item"), "schemaVersion": .integer(1), "createdAt": .date(anchor),
                "modifiedAt": .date(anchor), "actor": .text("fixture"), "operationID": .text("fixture"),
                "requestIdentity": .text("fixture"), "subject": .text(name), "body": .text(body),
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                ]),
                "categoryParents": .list(parents.map { .reference(ItemReference($0.itemID)) }),
            ])
        }
        var graph: [Revision] = []
        var previous: [Revision] = []
        for level in 0..<12 {
            let name = level == 0 ? "ActualRoot" : "Layer\(level)"
            let layer = try [record(name, parents: previous), record(name, parents: previous)]
            graph += layer
            previous = layer
        }
        let path = (["MissingRoot"] + (1..<12).map { "Layer\($0)" }).joined(separator: "/")
        var evaluations = 0
        let request = CommitRequest(
            classID: "Item", changes: ["body": .text("#[\(path)]")], operationID: "dag")
        let result = try InlineCapture.prepare(
            request, base: nil, categories: graph, at: anchor,
            isExcluded: { _ in false }, pathEvaluation: { evaluations += 1 })
        XCTAssertEqual(result.issues.first?.code, "unknown")
        XCTAssertLessThanOrEqual(
            evaluations, graph.count * 12, "Shared ancestors are evaluated once per path position")
        let duplicates = try (0..<20).map { _ in try record("Same") }
        let ambiguous = try InlineCapture.prepare(
            CommitRequest(
                classID: "Item", changes: ["body": .text("#Same")],
                operationID: "duplicates"), base: nil, categories: duplicates, at: anchor,
            isExcluded: { _ in false })
        XCTAssertEqual(ambiguous.issues.first?.code, "ambiguous")
        XCTAssertEqual(ambiguous.mentions.first?.candidates.count, 16)
        let oversized = CommitRequest(
            classID: "Item",
            changes: [
                "body": .text("#Same"),
                "unknown": .text(String(repeating: "x", count: 256 * 1024)),
            ], operationID: "large")
        XCTAssertThrowsError(
            try InlineCapture.prepare(
                oversized, base: nil, categories: duplicates,
                at: anchor, isExcluded: { _ in false })
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "captureLimit") }
        let unbound = try record("Old", body: String(repeating: "x", count: 65 * 1024))
        let edit = CommitRequest(
            action: .revise, itemID: unbound.itemID, expectedRevisionID: unbound.revisionID,
            changes: ["body": .text("#[\(duplicates[0].itemID)]")], operationID: "small-edit")
        XCTAssertTrue(
            try InlineCapture.prepare(
                edit, base: unbound, categories: duplicates, at: anchor,
                isExcluded: { _ in false }
            ).canCommit)
    }
}
