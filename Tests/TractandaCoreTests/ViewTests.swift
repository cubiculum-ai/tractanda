import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private final class ViewAccounts: AccountDirectory {
    let alice: UInt32 = 51001
    let bob: UInt32 = 51002
    private let users: [UInt32: AccountIdentity]

    init() {
        users = [
            getuid(): AccountIdentity(
                uid: getuid(), name: "admin", primaryGroupName: "staff", groupIDs: [71001]),
            51001: AccountIdentity(uid: 51001, name: "alice", primaryGroupName: "staff", groupIDs: [71001]),
            51002: AccountIdentity(uid: 51002, name: "bob", primaryGroupName: "staff", groupIDs: [71001]),
        ]
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
        return 71001
    }
}

final class ViewTests: XCTestCase {
    private func create(_ store: ItemStore, _ fields: [String: ItemValue]) throws -> Revision {
        try store.commit(CommitRequest(classID: "Item", changes: fields, operationID: Identifier.make()))
            .revision
    }
    private func edit(_ store: ItemStore, _ item: Revision, _ fields: [String: ItemValue]) throws -> Revision
    {
        try store.commit(
            CommitRequest(
                action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                changes: fields, operationID: Identifier.make())
        ).revision
    }

    func testImmutableReadSnapshotEnforcesCandidateAndEncodedByteBounds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let first = try create(store, ["subject": .text("Unicode λ"), "rank": .integer(2)])
        let second = try create(store, ["subject": .text("second"), "rank": .integer(1)])

        XCTAssertNil(try store.immutableReadSnapshot(maximumCandidates: 1))
        XCTAssertNil(try store.immutableReadSnapshot(maximumSerializedBytes: 1))
        let snapshot = try XCTUnwrap(store.immutableReadSnapshot())
        XCTAssertEqual(Set(snapshot.revisions.map(\.itemID)), [first.itemID, second.itemID])
        let encodedBytes = try snapshot.revisions.map { try JSON.encode($0).count }.reduce(0, +)
        XCTAssertEqual(snapshot.serializedBytes, encodedBytes)
        XCTAssertLessThanOrEqual(snapshot.serializedBytes, 2 * 1024 * 1024)
        XCTAssertFalse(snapshot.state.isEmpty)
    }

    func testRestrictedImmutableSnapshotAdmitsSelectiveSubsetOfLargerStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        var target: Revision?
        for index in 0..<8 {
            let item = try create(store, ["subject": .text("row-\(index)"), "rank": .integer(Int64(index))])
            if index == 5 { target = item }
        }
        let expected = try XCTUnwrap(target)
        let query = try SpotlightQuery("itemID == \"\(expected.itemID)\"")
        let snapshot = try XCTUnwrap(
            store.immutableReadSnapshot(
                maximumCandidates: 1, candidateRestrictions: query.indexCandidateRestrictions))
        XCTAssertEqual(snapshot.revisions.map(\.itemID), [expected.itemID])
        let prepared = try PreparedReadQuery(
            expression: "itemID == \"\(expected.itemID)\"", sort: [ItemSort(property: "subject")],
            evaluatedAt: Date(), timeZone: "UTC", position: 0, limit: 10)
        XCTAssertEqual(try prepared.evaluate(snapshot).ids, [expected.itemID])
    }

    func testPreparedReadEvaluatorMatchesSerialUnicodeDateAndTieOrdering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let firstFields: [String: ItemValue] = [
            "subject": .text("café one"), "eventDate": .date("2026-04-05T10:00:00Z"),
        ]
        let secondFields: [String: ItemValue] = [
            "subject": .text("café two"), "eventDate": .date("2026-04-05T10:00:00+00:00"),
        ]
        let otherFields: [String: ItemValue] = [
            "subject": .text("tea"), "eventDate": .date("2025-01-01T00:00:00Z"),
        ]
        let first = try create(store, firstFields)
        let second = try create(store, secondFields)
        _ = try create(store, otherFields)
        let sort = try [ItemSort(property: "eventDate")]
        let serial = try Categories.query(store: store, expression: "subject == \"café*\"", sort: sort)
        let snapshot = try XCTUnwrap(store.immutableReadSnapshot())
        let prepared = try PreparedReadQuery(
            expression: "subject == \"café*\"", sort: sort,
            evaluatedAt: try XCTUnwrap(Timestamp.parse("2026-09-27T09:00:00Z")), timeZone: "UTC",
            position: 0, limit: 10
        ).evaluate(snapshot)
        XCTAssertEqual(prepared.ids, serial.map(\.itemID))
        XCTAssertEqual(prepared.total, serial.count)
        XCTAssertEqual(prepared.ids, [first.itemID, second.itemID].sorted())
        XCTAssertEqual(prepared.state, snapshot.state)
    }

    func testSavedViewClockKeyPreservesSubMillisecondDateIdentity() throws {
        let start = try XCTUnwrap(Timestamp.parse("2026-09-27T12:00:00.000Z"))
        let first = start.addingTimeInterval(0.0001)
        let second = start.addingTimeInterval(0.0004)
        XCTAssertEqual(Timestamp.format(first), Timestamp.format(second))
        XCTAssertNotEqual(
            savedViewClockKey(at: first, timeZone: "UTC"),
            savedViewClockKey(at: second, timeZone: "UTC"))
    }

    func testClockDependentSavedViewCacheSeparatesSubMillisecondDates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let instant = try XCTUnwrap(Timestamp.parse("2026-09-27T12:00:00.000Z"))
        let later = instant.addingTimeInterval(0.0004)
        XCTAssertEqual(Timestamp.format(instant), Timestamp.format(later))
        let category = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile),
                    "expression": .text("deadline >= $time.now"),
                ])
            ])
        _ = try create(store, ["deadline": .date(Timestamp.format(instant))])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(category.itemID))]),
                ])
            ])
        func page(at date: Date) throws -> ItemIndex.Page {
            try Categories.page(
                store: store, expression: nil, text: nil, categoryPath: [category.itemID],
                excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: date,
                timeZone: "UTC", savedViewID: view.itemID)
        }
        XCTAssertEqual(try page(at: instant).total, 1)
        let selectionKey = String(
            decoding: try JSON.encode([
                "hasExpression": ItemValue.boolean(false), "expression": ItemValue.text(""),
                "hasText": ItemValue.boolean(false), "text": ItemValue.text(""),
                "categoryPath": ItemValue.list([.text(category.itemID)]),
                "excludedCategoryIDs": ItemValue.list([]), "sort": ItemValue.list([]),
            ]), as: UTF8.self)
        let instantKey = store.savedViewPageKey(
            view.itemID, selectionKey: selectionKey,
            timeKey: savedViewClockKey(at: instant, timeZone: "UTC"))
        XCTAssertEqual(try store.cachedSavedViewPage(key: instantKey, position: 0, limit: 10)?.total, 1)
        XCTAssertEqual(try page(at: later).total, 0)
        XCTAssertNotEqual(
            instantKey,
            store.savedViewPageKey(
                view.itemID, selectionKey: selectionKey,
                timeKey: savedViewClockKey(at: later, timeZone: "UTC")))
    }

    func testDefaultOrderUsesModificationInstantsAndStableIdentityTies() throws {
        func item(_ suffix: String, modified: String, created: String) throws -> Revision {
            let fields: [String: ItemValue] = [
                "itemID": .text("00000000-0000-4000-8000-00000000000" + suffix),
                "revisionID": .text(Identifier.make()), "classID": .text("Item"),
                "actor": .text("test"), "operationID": .text("test"), "requestIdentity": .text("test"),
                "schemaVersion": .integer(1), "createdAt": .date(created), "modifiedAt": .date(modified),
            ]
            return try Revision(fields: fields)
        }
        let old = try item("1", modified: "2026-09-10T07:00:00Z", created: "2026-09-10T07:00:00Z")
        let edited = try item("2", modified: "2026-09-10T10:00:00+02:00", created: "2020-01-01T00:00:00Z")
        let tied = try item("3", modified: "2026-09-10T08:00:00Z", created: "2026-09-10T08:00:00Z")
        let unordered = [tied, old, edited]
        XCTAssertEqual(
            try ItemSort.ordered(unordered, by: []).map(\.itemID), [edited, tied, old].map(\.itemID))
        XCTAssertEqual(
            try ItemSort.ordered(unordered, by: [ItemSort(property: "itemID")]).map(\.itemID),
            [old, edited, tied].map(\.itemID))
    }

    func testCreatedIndexUsesItemIDForEqualInstants() throws {
        func item(_ idSuffix: String, timestamp: String) throws -> Revision {
            let fields: [String: ItemValue] = [
                "itemID": .text("00000000-0000-1000-8000-00000000000\(idSuffix)"),
                "revisionID": .text(Identifier.make()), "classID": .text("Item"),
                "actor": .text("test"), "operationID": .text("test"), "requestIdentity": .text("test"),
                "schemaVersion": .integer(1), "createdAt": .date(timestamp), "modifiedAt": .date(timestamp),
            ]
            return try Revision(fields: fields)
        }
        let first = try item("1", timestamp: "2026-09-10T10:00:00+02:00")
        let second = try item("2", timestamp: "2026-09-10T08:00:00Z")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = try ItemIndex(path: directory.appendingPathComponent("items.sqlite").path, create: true)
        try index.put(second)
        try index.put(first)
        let page = try index.orderedPage(
            lexicalText: nil, classEquals: nil, order: .createdAt, position: 0, limit: 10,
            fastCount: true
        ) { _ in true }
        XCTAssertEqual(page.ids, [first.itemID, second.itemID])
        XCTAssertEqual(page.total, 2)
    }

    func testBoundedCandidateIteratorFiltersUnreadableRowsBeforeItsLimit() throws {
        func item(_ index: Int, timestamp: String) throws -> Revision {
            let id = String(format: "00000000-0000-1000-8000-%012x", index)
            let fields: [String: ItemValue] = [
                "itemID": .text(id), "revisionID": .text(Identifier.make()), "classID": .text("Item"),
                "actor": .text("test"), "operationID": .text("test-\(index)"),
                "requestIdentity": .text("test-\(index)"), "schemaVersion": .integer(1),
                "createdAt": .date(timestamp), "modifiedAt": .date(timestamp),
            ]
            return try Revision(fields: fields)
        }
        let index = try ItemIndex(path: ":memory:", create: true)
        let older = "2026-09-01T00:00:00Z"
        let newer = "2026-09-02T00:00:00Z"
        for value in 0..<521 {
            try index.put(item(value, timestamp: value < 100 ? older : newer))
        }
        let identifiers = (0..<521).map { String(format: "00000000-0000-1000-8000-%012x", $0) }
        let readable = Set(identifiers.dropFirst(8))
        let allDateRange: [SpotlightQuery.IndexCandidateRestriction] = [
            .init(field: "createdAt", operation: ">=", value: "0")
        ]
        XCTAssertNil(
            try index.boundedCandidateIDs(restrictions: allDateRange, maximumReadable: 512) {
                readable.contains($0)
            })

        let selectedDateRange: [SpotlightQuery.IndexCandidateRestriction] = [
            .init(
                field: "createdAt", operation: ">=",
                value: String(try XCTUnwrap(Timestamp.parse(newer)).timeIntervalSinceReferenceDate))
        ]
        let selectedReadable = try XCTUnwrap(
            index.boundedCandidateIDs(restrictions: selectedDateRange, maximumReadable: 512) { id in
                readable.contains(id) && !identifiers[100..<108].contains(id)
            })
        XCTAssertEqual(Set(selectedReadable), Set(identifiers.dropFirst(108)))

        let selectedID = identifiers[200]
        let byUUID = try XCTUnwrap(
            index.boundedCandidateIDs(
                restrictions: [.init(field: "itemID", operation: "=", value: selectedID)],
                maximumReadable: 1
            ) { readable.contains($0) })
        XCTAssertEqual(byUUID, [selectedID])
    }

    func testIndexedCandidatePredicatesMatchFullQueryAndRebuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let first = try create(store, ["subject": .text("alpha"), "body": .text("shared text")])
        let second = try create(store, ["subject": .text("beta"), "body": .text("shared text")])
        let third = try create(store, ["subject": .text("gamma"), "body": .text("other")])
        guard case .date(let createdTimestamp)? = first.fields["createdAt"] else {
            return XCTFail("Created time must be a typed date.")
        }
        let instant = try XCTUnwrap(Timestamp.parse(createdTimestamp))
        let iso = Timestamp.format(instant)
        let shiftedFormatter = ISO8601DateFormatter()
        shiftedFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        shiftedFormatter.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 2 * 60 * 60))
        let timezoneEquivalent = shiftedFormatter.string(from: instant)
        let cases = [
            "itemID == \"\(first.itemID)\"",
            "createdAt == $time.iso(\"\(iso)\")",
            "kMDItemContentCreationDate == $time.iso(\"\(timezoneEquivalent)\")",
            "kMDItemContentCreationDate >= $time.iso(\"\(iso)\")",
            "modifiedAt <= $time.iso(\"\(iso)\")",
            "itemID == \"\(second.itemID)\" && (subject == \"beta\" || subject == \"missing\")",
            "createdAt >= $time.iso(\"\(iso)\") || itemID == \"\(first.itemID)\"",
        ]
        for expression in cases {
            let expected = try Categories.query(store: store, expression: expression).map(\.itemID)
            let page = try Categories.page(
                store: store, expression: expression, text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [], position: 0, limit: 20,
                at: Date(), timeZone: "UTC")
            XCTAssertEqual(page.ids, expected, expression)
            XCTAssertEqual(page.total, expected.count, expression)
        }
        XCTAssertEqual(
            Set(try Categories.query(store: store).map(\.itemID)),
            Set([first.itemID, second.itemID, third.itemID]))
        try store.rebuildIndex()
        let expression = "createdAt >= $time.iso(\"\(iso)\") && classID == \"Item\""
        let expected = try Categories.query(store: store, expression: expression).map(\.itemID)
        let rebuilt = try Categories.page(
            store: store, expression: expression, text: nil, categoryPath: [],
            excludedCategoryIDs: [], sort: [], position: 0, limit: 20,
            at: Date(), timeZone: "UTC")
        XCTAssertEqual(rebuilt.ids, expected)
        XCTAssertEqual(rebuilt.total, expected.count)
    }

    func testCandidateRestrictionExtractionRequiresConjunctiveTypedLiterals() throws {
        let id = "00000000-0000-1000-8000-000000000001"
        XCTAssertEqual(
            try SpotlightQuery("itemID == \"\(id)\"").indexCandidateRestrictions.map(\.field), ["itemID"])
        XCTAssertEqual(
            try SpotlightQuery("kMDItemContentModificationDate < $time.iso(\"2026-09-01T00:00:00Z\")")
                .indexCandidateRestrictions.map(\.field), ["modifiedAt"])
        XCTAssertTrue(try SpotlightQuery("createdAt >= $time.today").indexCandidateRestrictions.isEmpty)
        XCTAssertTrue(try SpotlightQuery("itemID == \"*\"").indexCandidateRestrictions.isEmpty)
        XCTAssertTrue(try SpotlightQuery("itemID ==[c] \"\(id)\"").indexCandidateRestrictions.isEmpty)
        XCTAssertTrue(
            try SpotlightQuery("createdAt >= $time.iso(\"2026-09-01T00:00:00Z\") || subject == \"x\"")
                .indexCandidateRestrictions.isEmpty)
        XCTAssertEqual(
            try SpotlightQuery(
                "createdAt >= $time.iso(\"2026-09-01T00:00:00Z\") && (subject == \"x\" || subject == \"y\")"
            ).indexCandidateRestrictions.map(\.field), ["createdAt"])
    }

    func testDefaultNativeOrderAppliesBeforePagingSearchAndSavedViews() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        var items: [Revision] = []
        for index in 0..<70 {
            items.append(
                try create(
                    store,
                    [
                        "subject": .text("Row \(index)"), "rank": .integer(Int64(index)),
                        "sortFixture": .text("yes"), "body": .text("chronological marker"),
                    ]))
        }
        let category = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("sortFixture == \"yes\""),
                ])
            ])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(category.itemID))]), "sort": .list([]),
                ])
            ])
        let rankView = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("sortFixture == \"yes\""),
                    "sort": .list([try ItemSort(property: "rank").value]),
                ])
            ])
        // The timestamp codec has millisecond precision; ensure the subsequent edit is later.
        Thread.sleep(forTimeInterval: 0.002)
        items[0] = try store.commit(
            CommitRequest(
                action: .revise, itemID: items[0].itemID, expectedRevisionID: items[0].revisionID,
                changes: ["subject": .text("Older item edited now")], operationID: Identifier.make())
        ).revision
        let dated = try items.map { item -> (item: Revision, date: Date) in
            guard case .date(let timestamp) = item.fields["modifiedAt"] else {
                throw TractandaError("test", "Missing modification timestamp")
            }
            return (item, try XCTUnwrap(Timestamp.parse(timestamp)))
        }
        let expected = dated.sorted {
            $0.date == $1.date ? $0.item.itemID < $1.item.itemID : $0.date > $1.date
        }.map { $0.item.itemID }
        XCTAssertEqual(expected.first, items[0].itemID)
        struct Page: Decodable {
            let ids: [String]
            let total: Int
        }
        func query(_ arguments: [String: Any]) throws -> Page {
            try JSON.decode(Page.self, client.call("TractandaItem/query", arguments: arguments))
        }
        let base: [String: Any] = ["expression": "sortFixture == \"yes\"", "limit": 64]
        XCTAssertEqual(try query(base).ids, Array(expected.prefix(64)))
        XCTAssertEqual(
            try query(base.merging(["position": 64]) { _, new in new }).ids, Array(expected.suffix(6)))
        XCTAssertEqual(
            try query(["categoryPath": [category.itemID], "sort": [], "limit": 64]).ids,
            Array(expected.prefix(64)))
        XCTAssertEqual(
            try query(["text": "chronological marker", "limit": 64]).ids, Array(expected.prefix(64)))
        XCTAssertEqual(try query(["viewID": view.itemID, "limit": 64]).ids, Array(expected.prefix(64)))
        XCTAssertEqual(
            try query(["viewID": rankView.itemID, "limit": 64]).ids, Array(items.prefix(64).map(\.itemID)))
        let before = try store.get(items[0].itemID)
        try store.rebuildIndex()
        XCTAssertEqual(
            try query(["viewID": view.itemID, "position": 64, "limit": 64]).ids, Array(expected.suffix(6)))
        let createdSort = [try ItemSort(property: "createdAt", isAscending: false)]
        let createdView = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "expression": .text("classID == \"Item\""),
                    "sort": .list(createdSort.map(\.value)),
                ])
            ])
        XCTAssertTrue(try store.savedViewIndexIsReady(createdView.itemID))
        let fullSaved = try Categories.savedViewPage(
            store: store, id: createdView.itemID, sectionID: nil, position: 0, limit: 100,
            at: Date(), timeZone: "UTC")
        let indexedSaved = try Categories.page(
            store: store, expression: "classID == \"Item\"", text: nil, categoryPath: [],
            excludedCategoryIDs: [], sort: createdSort, position: 0, limit: 100,
            at: Date(), timeZone: "UTC", savedViewID: createdView.itemID)
        XCTAssertEqual(indexedSaved.ids, fullSaved.ids)
        XCTAssertEqual(indexedSaved.total, fullSaved.total)
        for (expression, text) in [
            (nil as String?, nil as String?), ("rank >= 20", nil), (nil, "chronological marker"),
        ] {
            let full = try Categories.query(
                store: store, expression: expression, text: text, sort: createdSort
            )
            .map(\.itemID)
            let indexed = try Categories.page(
                store: store, expression: expression, text: text, categoryPath: [],
                excludedCategoryIDs: [], sort: createdSort, position: 0, limit: 100,
                at: Date(), timeZone: "UTC")
            XCTAssertEqual(indexed.ids, full)
            XCTAssertEqual(indexed.total, full.count)
        }
        XCTAssertEqual(try store.get(items[0].itemID), before)
    }

    func testCreatedOrderCountsOnlyItemsReadableByCaller() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let accounts = ViewAccounts()
        let store = try ItemStore(root: directory, accounts: accounts)
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
                "userAliases": .object([:]),
            ]), operationID: "view-access")
        func createShared(_ mode: Int64) throws -> Revision {
            try store.withAccess(forUID: accounts.alice) {
                try store.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: [
                            "createdQueryFixture": .text("yes"),
                            "permissions": .object([
                                "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                                "group": .text("staff"), "mode": .integer(mode), "acl": .object([:]),
                            ]),
                        ], operationID: Identifier.make())
                )
                .revision
            }
        }
        let older = try createShared(0o640)
        _ = try createShared(0o600)
        Thread.sleep(forTimeInterval: 0.003)
        let newer = try createShared(0o640)
        try store.withAccess(forUID: accounts.bob) {
            let full = try Categories.query(
                store: store, expression: "createdQueryFixture == \"yes\"",
                sort: [ItemSort(property: "createdAt", isAscending: false)])
            let page = try Categories.page(
                store: store, expression: "createdQueryFixture == \"yes\"", text: nil,
                categoryPath: [], excludedCategoryIDs: [],
                sort: [ItemSort(property: "createdAt", isAscending: false)], position: 0, limit: 1,
                at: Date(), timeZone: "UTC")
            XCTAssertEqual(full.map(\.itemID), [newer.itemID, older.itemID])
            XCTAssertEqual(page.ids, [newer.itemID])
            XCTAssertEqual(page.total, full.count)
            let second = try Categories.page(
                store: store, expression: "createdQueryFixture == \"yes\"", text: nil,
                categoryPath: [], excludedCategoryIDs: [],
                sort: [ItemSort(property: "createdAt", isAscending: false)], position: 1, limit: 1,
                at: Date(), timeZone: "UTC")
            XCTAssertEqual(second.ids, [older.itemID])
            XCTAssertEqual(second.total, 2)
        }
    }

    func testSavedCategoryPageCacheTracksWritesAndRebuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let category = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("bucket == \"in\""),
                ])
            ])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(category.itemID))]),
                ])
            ])
        XCTAssertFalse(try store.savedViewIndexIsReady(view.itemID))
        let first = try create(store, ["bucket": .text("in")])
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        struct Page: Decodable {
            let ids: [String]
            let total: Int
        }
        func page() throws -> Page {
            try JSON.decode(
                Page.self,
                client.call("TractandaItem/query", arguments: ["viewID": view.itemID, "limit": 1]))
        }
        XCTAssertEqual(try page().ids, [first.itemID])
        let selectionKey = String(
            decoding: try JSON.encode([
                "hasExpression": ItemValue.boolean(false), "expression": ItemValue.text(""),
                "hasText": ItemValue.boolean(false), "text": ItemValue.text(""),
                "categoryPath": ItemValue.list([.text(category.itemID)]),
                "excludedCategoryIDs": ItemValue.list([]), "sort": ItemValue.list([]),
            ]), as: UTF8.self)
        let key = store.savedViewPageKey(
            view.itemID, selectionKey: selectionKey, timeKey: "static", reusableAcrossCommits: true)
        XCTAssertEqual(try store.cachedSavedViewPage(key: key, position: 0, limit: 1)?.total, 1)
        let second = try create(store, ["bucket": .text("in")])
        XCTAssertNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 1))
        XCTAssertEqual(try page().total, 2)
        _ = try edit(store, second, ["bucket": .text("out")])
        XCTAssertEqual(try page().ids, [first.itemID])
        try store.rebuildIndex()
        XCTAssertEqual(try page().total, 1)
    }

    func testSavedViewCacheReusesUnrelatedEditsAndInvalidatesSelectionChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let first = try create(store, ["bucket": .text("in"), "rank": .integer(1)])
        let other = try create(store, ["bucket": .text("out"), "rank": .integer(2)])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "expression": .text("bucket == \"in\""),
                    "sort": .list([try ItemSort(property: "rank").value]),
                ])
            ])
        let selectionKey = String(
            decoding: try JSON.encode([
                "hasExpression": ItemValue.boolean(true),
                "expression": ItemValue.text("bucket == \"in\""),
                "hasText": ItemValue.boolean(false), "text": ItemValue.text(""),
                "categoryPath": ItemValue.list([]), "excludedCategoryIDs": ItemValue.list([]),
                "sort": ItemValue.list([try ItemSort(property: "rank").value]),
            ]), as: UTF8.self)
        let key = store.savedViewPageKey(
            view.itemID, selectionKey: selectionKey, timeKey: "static", reusableAcrossCommits: true)
        func page() throws -> ItemIndex.Page {
            try Categories.page(
                store: store, expression: "bucket == \"in\"", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [try ItemSort(property: "rank")], position: 0,
                limit: 10, at: Date(), timeZone: "UTC", savedViewID: view.itemID)
        }
        XCTAssertEqual(try page().ids, [first.itemID])
        let editedOther = try edit(store, other, ["notes": .text("unrelated")])
        XCTAssertEqual(try store.cachedSavedViewPage(key: key, position: 0, limit: 10)?.ids, [first.itemID])
        _ = try edit(store, editedOther, ["bucket": .text("in")])
        XCTAssertNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 10))
        XCTAssertEqual(try page().total, 2)
    }

    func testSavedViewDefaultOrderInvalidatesWhenEditChangesModifiedAt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let older = try create(store, ["bucket": .text("in")])
        Thread.sleep(forTimeInterval: 0.003)
        let newer = try create(store, ["bucket": .text("in")])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "expression": .text("bucket == \"in\""),
                ])
            ])
        func page() throws -> ItemIndex.Page {
            try Categories.page(
                store: store, expression: "bucket == \"in\"", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [], position: 0, limit: 10, at: Date(),
                timeZone: "UTC", savedViewID: view.itemID)
        }
        XCTAssertEqual(try page().ids, [newer.itemID, older.itemID])
        Thread.sleep(forTimeInterval: 0.003)
        _ = try edit(store, older, ["notes": .text("unrelated to selection")])
        XCTAssertEqual(try page().ids, [older.itemID, newer.itemID])
    }

    func testSavedViewCacheInvalidatesWhenCopyAddsMatchingItem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let item = try create(store, ["bucket": .text("in"), "rank": .integer(1)])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "expression": .text("bucket == \"in\""),
                    "sort": .list([try ItemSort(property: "rank").value]),
                ])
            ])
        func page() throws -> ItemIndex.Page {
            try Categories.page(
                store: store, expression: "bucket == \"in\"", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [try ItemSort(property: "rank")], position: 0,
                limit: 10, at: Date(), timeZone: "UTC", savedViewID: view.itemID)
        }
        XCTAssertEqual(try page().total, 1)
        _ = try store.commit(
            CommitRequest(
                action: .copy, itemID: item.itemID, expectedRevisionID: item.revisionID,
                operationID: Identifier.make()))
        XCTAssertEqual(try page().total, 2)
    }

    func testSavedViewCacheInvalidatesWhenRetypeChangesClassPredicate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let item = try create(store, ["rank": .integer(1)])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "expression": .text("classID == \"Item\""),
                    "sort": .list([try ItemSort(property: "rank").value]),
                ])
            ])
        func page() throws -> ItemIndex.Page {
            try Categories.page(
                store: store, expression: "classID == \"Item\"", text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [try ItemSort(property: "rank")], position: 0,
                limit: 10, at: Date(), timeZone: "UTC", savedViewID: view.itemID)
        }
        XCTAssertEqual(try page().ids, [item.itemID, view.itemID])
        _ = try store.commit(
            CommitRequest(
                action: .retype, itemID: item.itemID, expectedRevisionID: item.revisionID,
                classID: "AppointmentItem", operationID: Identifier.make()))
        XCTAssertEqual(try page().ids, [view.itemID])
    }

    func testSavedViewCacheInvalidatesForManagedRevisionIDPredicate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let item = try create(store, ["rank": .integer(1)])
        let expression = "revisionID == \"\(item.revisionID)\""
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text(expression),
                    "sort": .list([try ItemSort(property: "rank").value]),
                ])
            ])
        func page() throws -> ItemIndex.Page {
            try Categories.page(
                store: store, expression: expression, text: nil, categoryPath: [],
                excludedCategoryIDs: [], sort: [try ItemSort(property: "rank")], position: 0,
                limit: 10, at: Date(), timeZone: "UTC", savedViewID: view.itemID)
        }
        XCTAssertEqual(try page().ids, [item.itemID])
        _ = try edit(store, item, ["notes": .text("new revision identity")])
        XCTAssertTrue(try page().ids.isEmpty)
    }

    func testManualCategorySectionCacheTracksMembershipAndMemberOrdering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let impossibleSelection: [String: ItemValue] = [
            "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
        ]
        let root = try create(store, ["selection": .object(impossibleSelection)])
        let child = try create(
            store,
            [
                "selection": .object(impossibleSelection),
                "categoryParents": .list([.reference(ItemReference(root.itemID))]),
            ])
        let first = try create(
            store, ["categoryOverrides": .object([child.itemID: .text("include")])])
        Thread.sleep(forTimeInterval: 0.003)
        let second = try create(
            store, ["categoryOverrides": .object([child.itemID: .text("include")])])
        var nonmember = try create(store, ["notes": .text("outside the manual category")])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(root.itemID))]),
                    "presentation": .object([
                        "profile": .text(ViewPresentation.profile),
                        "sections": .list([.reference(ItemReference(child.itemID))]),
                    ]),
                ])
            ])
        let selectionKey = String(
            decoding: try JSON.encode([
                "hasExpression": ItemValue.boolean(false), "expression": ItemValue.text(""),
                "hasText": ItemValue.boolean(false), "text": ItemValue.text(""),
                "categoryPath": ItemValue.list([.text(root.itemID), .text(child.itemID)]),
                "excludedCategoryIDs": ItemValue.list([]), "sort": ItemValue.list([]),
            ]), as: UTF8.self)
        let key = store.savedViewPageKey(
            view.itemID, selectionKey: selectionKey, timeKey: "static", reusableAcrossCommits: true)
        func page() throws -> ItemIndex.Page {
            try Categories.savedViewPage(
                store: store, id: view.itemID, sectionID: child.itemID, position: 0, limit: 20,
                at: Date(), timeZone: "UTC")
        }
        XCTAssertEqual(try page().ids, [second.itemID, first.itemID])
        XCTAssertEqual(try store.cachedSavedViewPage(key: key, position: 0, limit: 20)?.total, 2)

        nonmember = try edit(store, nonmember, ["notes": .text("still outside")])
        XCTAssertEqual(
            try store.cachedSavedViewPage(key: key, position: 0, limit: 20)?.ids,
            [second.itemID, first.itemID])
        XCTAssertEqual(try page().ids, [second.itemID, first.itemID])

        let included = try edit(
            store, nonmember, ["categoryOverrides": .object([child.itemID: .text("include")])])
        XCTAssertNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))
        let afterInclude = try page()
        XCTAssertEqual(afterInclude.total, 3)
        XCTAssertEqual(afterInclude.ids, [included.itemID, second.itemID, first.itemID])

        Thread.sleep(forTimeInterval: 0.003)
        _ = try edit(store, first, ["notes": .text("member order changed")])
        XCTAssertNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))
        XCTAssertEqual(try page().ids, [first.itemID, included.itemID, second.itemID])
    }

    func testManualCategoryCacheFallsBackAfterCategoryEditOrPersonalState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let selection: [String: ItemValue] = [
            "language": .text(SpotlightQuery.profile), "expression": .text("itemID == \"\""),
        ]
        let category = try create(store, ["selection": .object(selection)])
        let member = try create(
            store, ["categoryOverrides": .object([category.itemID: .text("include")])])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(category.itemID))]),
                ])
            ])
        let selectionKey = String(
            decoding: try JSON.encode([
                "hasExpression": ItemValue.boolean(false), "expression": ItemValue.text(""),
                "hasText": ItemValue.boolean(false), "text": ItemValue.text(""),
                "categoryPath": ItemValue.list([.text(category.itemID)]),
                "excludedCategoryIDs": ItemValue.list([]), "sort": ItemValue.list([]),
            ]), as: UTF8.self)
        let key = store.savedViewPageKey(
            view.itemID, selectionKey: selectionKey, timeKey: "static", reusableAcrossCommits: true)
        func page() throws -> ItemIndex.Page {
            try Categories.savedViewPage(
                store: store, id: view.itemID, sectionID: nil, position: 0, limit: 20,
                at: Date(), timeZone: "UTC")
        }
        XCTAssertEqual(try page().ids, [member.itemID])
        _ = try edit(store, category, ["subject": .text("Renamed category")])
        XCTAssertNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))
        XCTAssertEqual(try page().ids, [member.itemID])

        _ = try store.commit(
            CommitRequest(
                classID: "PersonalStateItem",
                changes: [
                    "target": .reference(ItemReference(member.itemID)),
                    "personalOverrides": .object([category.itemID: .text("exclude")]),
                ], operationID: Identifier.make()))
        XCTAssertNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))
        XCTAssertEqual(try page().ids, [member.itemID])
        XCTAssertNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))
    }

    func testSavedViewCacheTracksDynamicCategoryRuleClosureDependencies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        func category(_ expression: String, parents: [String] = [], exclusions: [String] = []) throws
            -> Revision
        {
            var selection: [String: ItemValue] = [
                "language": .text(SpotlightQuery.profile), "expression": .text(expression),
            ]
            if !exclusions.isEmpty {
                selection["excludedCategoryIDs"] = .list(exclusions.map { .reference(ItemReference($0)) })
            }
            var fields: [String: ItemValue] = ["selection": .object(selection)]
            if !parents.isEmpty {
                fields["categoryParents"] = .list(parents.map { .reference(ItemReference($0)) })
            }
            return try create(store, fields)
        }
        let excluded = try category("flag == \"blocked\"")
        let root = try category("(bucket == \"in\" && tier == 2) || tier == 3", exclusions: [excluded.itemID])
        let child = try category("rank == 1 && active == true", parents: [root.itemID])
        let matching = try create(
            store,
            [
                "bucket": .text("in"), "tier": .integer(0), "rank": .integer(1),
                "active": .boolean(true), "flag": .text("clear"),
            ])
        var unrelated = try create(store, ["notes": .text("outside")])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "categoryPath": .list([.reference(ItemReference(root.itemID))]),
                ])
            ])
        func page() throws -> ItemIndex.Page {
            try Categories.savedViewPage(
                store: store, id: view.itemID, sectionID: nil, position: 0, limit: 20,
                at: Date(), timeZone: "UTC")
        }
        XCTAssertEqual(try page().ids, [matching.itemID])
        let selectionKey = String(
            decoding: try JSON.encode([
                "hasExpression": ItemValue.boolean(false), "expression": ItemValue.text(""),
                "hasText": ItemValue.boolean(false), "text": ItemValue.text(""),
                "categoryPath": ItemValue.list([.text(root.itemID)]),
                "excludedCategoryIDs": ItemValue.list([]), "sort": ItemValue.list([]),
            ]), as: UTF8.self)
        let key = store.savedViewPageKey(
            view.itemID, selectionKey: selectionKey, timeKey: "static", reusableAcrossCommits: true)
        XCTAssertNotNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))

        unrelated = try edit(store, unrelated, ["notes": .text("still outside")])
        XCTAssertNotNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))
        XCTAssertEqual(try page().ids, [matching.itemID])

        let changed = try edit(
            store, unrelated, ["bucket": .text("in"), "rank": .integer(1), "active": .boolean(true)])
        XCTAssertNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))
        XCTAssertEqual(Set(try page().ids), Set([matching.itemID, changed.itemID]))

        let excludedItem = try edit(store, changed, ["flag": .text("blocked")])
        XCTAssertNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))
        XCTAssertEqual(try page().ids, [matching.itemID])
        XCTAssertEqual(
            try Categories.query(store: store, categoryPath: [root.itemID]).map(\.itemID), [matching.itemID])
        _ = excludedItem
        _ = child
    }

    func testSavedTextViewCacheReusesOnlyWhenExactCorpusIsUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        var item = try create(store, ["details": .object(["nested": .text("needle")])])
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile), "text": .text("needle"),
                    "sort": .list([try ItemSort(property: "createdAt").value]),
                ])
            ])
        func page() throws -> ItemIndex.Page {
            try Categories.savedViewPage(
                store: store, id: view.itemID, sectionID: nil, position: 0, limit: 20,
                at: Date(), timeZone: "UTC")
        }
        XCTAssertEqual(try page().ids, [item.itemID])
        let selectionKey = String(
            decoding: try JSON.encode([
                "hasExpression": ItemValue.boolean(false), "expression": ItemValue.text(""),
                "hasText": ItemValue.boolean(true), "text": ItemValue.text("needle"),
                "categoryPath": ItemValue.list([]), "excludedCategoryIDs": ItemValue.list([]),
                "sort": ItemValue.list([try ItemSort(property: "createdAt").value]),
            ]), as: UTF8.self)
        let key = store.savedViewPageKey(
            view.itemID, selectionKey: selectionKey, timeKey: "static", reusableAcrossCommits: true)
        XCTAssertNotNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))
        item = try edit(store, item, ["unindexedNumber": .integer(3)])
        XCTAssertNotNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))
        XCTAssertEqual(try page().ids, [item.itemID])
        item = try edit(store, item, ["details": .object(["nested": .text("changed")])])
        XCTAssertNil(try store.cachedSavedViewPage(key: key, position: 0, limit: 20))
        XCTAssertTrue(try page().ids.isEmpty)
    }

    func testSavedViewSectionCachesKeepDistinctMembershipAndTotals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        func category(_ marker: String) throws -> Revision {
            try create(
                store,
                [
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile),
                        "expression": .text("sectionMarker == \"\(marker)\""),
                    ])
                ])
        }
        let left = try category("left")
        let right = try category("right")
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile),
                    "presentation": .object([
                        "profile": .text(ViewPresentation.profile),
                        "sections": .list([
                            .reference(ItemReference(left.itemID)), .reference(ItemReference(right.itemID)),
                        ]),
                    ]),
                ])
            ])
        let leftItem = try create(store, ["sectionMarker": .text("left")])
        let rightItem = try create(store, ["sectionMarker": .text("right")])
        let otherRight = try create(store, ["sectionMarker": .text("right")])
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        struct Page: Decodable {
            let ids: [String]
            let total: Int
        }
        func page(_ section: String) throws -> Page {
            try JSON.decode(
                Page.self,
                client.call(
                    "TractandaItem/query",
                    arguments: [
                        "viewID": view.itemID, "sectionID": section, "limit": 1,
                    ]))
        }
        XCTAssertEqual(try page(left.itemID).ids, [leftItem.itemID])
        XCTAssertEqual(try page(right.itemID).total, 2)
        XCTAssertTrue([rightItem.itemID, otherRight.itemID].contains(try page(right.itemID).ids[0]))
        XCTAssertEqual(try page(left.itemID).total, 1)
        XCTAssertFalse(try page(right.itemID).ids.contains(leftItem.itemID))
    }

    func testOrdinaryWritesSkipCategoryGraphValidationButCategoryChangesDoNot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        var validations = 0
        store.beforeCategoryGraphValidation = { validations += 1 }
        let ordinary = try create(store, ["subject": .text("ordinary")])
        XCTAssertEqual(validations, 0)
        _ = try edit(store, ordinary, ["subject": .text("edited")])
        XCTAssertEqual(validations, 0)
        let root = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("marker == \"never\""),
                ])
            ])
        XCTAssertEqual(validations, 1)
        var child = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("marker == \"yes\""),
                ]),
                "categoryParents": .list([.reference(ItemReference(root.itemID))]),
            ])
        XCTAssertEqual(validations, 2)
        let matched = try create(store, ["marker": .text("yes")])
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(
            try Categories.query(store: store, categoryPath: [root.itemID]).map(\.itemID),
            [matched.itemID])
        XCTAssertThrowsError(
            try edit(
                store, root,
                [
                    "categoryParents": .list([.reference(ItemReference(child.itemID))])
                ])
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "categoryCycle") }
        XCTAssertEqual(validations, 3)
        child = try edit(store, child, ["isDeleted": .boolean(true)])
        XCTAssertEqual(validations, 4)
        XCTAssertTrue(try Categories.query(store: store, categoryPath: [root.itemID]).isEmpty)
        _ = try edit(store, child, ["isDeleted": .boolean(false)])
        XCTAssertEqual(validations, 5)
        XCTAssertEqual(
            try Categories.query(store: store, categoryPath: [root.itemID]).map(\.itemID),
            [matched.itemID])
    }

    func testNativeSortPrecedesPaginationAndSurvivesRebuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let service = ItemService(store: store)
        let client = ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
        var items: [Revision] = []
        for index in (0..<70).reversed() {
            items.append(try create(store, ["subject": .text("Row"), "rank": .integer(Int64(index))]))
        }
        let view = try create(
            store,
            [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("rank == *"),
                    "sort": .list([try ItemSort(property: "rank").value]),
                ])
            ])
        struct Page: Decodable {
            let ids: [String]
            let total: Int
        }
        func query(_ position: Int) throws -> Page {
            try JSON.decode(
                Page.self,
                client.call(
                    "TractandaItem/query",
                    arguments: [
                        "viewID": view.itemID, "position": position, "limit": 64,
                    ]))
        }
        let ascending = items.reversed().map(\.itemID)
        XCTAssertEqual(try query(0).ids, Array(ascending.prefix(64)))
        XCTAssertEqual(try query(64).ids, Array(ascending.suffix(6)))
        XCTAssertEqual(try query(64).total, 70)
        let descending = try JSON.decode(
            Page.self,
            client.call(
                "TractandaItem/query",
                arguments: [
                    "expression": "rank == *", "sort": [["property": "rank", "isAscending": false]],
                    "limit": 3,
                ]))
        XCTAssertEqual(descending.ids, items.prefix(3).map(\.itemID))
        try store.rebuildIndex()
        XCTAssertEqual(try query(64).ids, Array(ascending.suffix(6)))
        for arguments: [String: Any] in [
            ["sort": [["property": "rank", "isAscending": "no"]]],
            ["sort": [["property": ""]]], ["sort": [["property": "rank"], ["property": "rank"]]],
            ["sort": NSNull()], ["viewID": view.itemID, "sort": []], ["sectionID": view.itemID],
        ] {
            XCTAssertThrowsError(try client.call("TractandaItem/query", arguments: arguments))
        }
    }

    func testTypedOrderingIsExactStableAndDoesNotFollowReferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let integer = try create(store, ["value": .integer(9_007_199_254_740_993)])
        let real = try create(store, ["value": .real(9_007_199_254_740_992)])
        let negative = try create(store, ["value": .integer(-9_223_372_036_854_775_808)])
        let dateA = try create(store, ["value": .date("2026-09-08T11:00:00+02:00")])
        let dateB = try create(store, ["value": .date("2026-09-08T10:00:00Z")])
        let text = try create(store, ["value": .text("value")])
        let flag = try create(store, ["value": .boolean(false)])
        let absent = try create(store, [:])
        let compound = try create(store, ["value": .reference(ItemReference(integer.itemID))])
        let all = [integer, dateB, absent, flag, real, negative, compound, text, dateA]
        let missing = [absent, compound].sorted { $0.itemID < $1.itemID }
        let expected = [negative, real, integer, dateA, dateB, text, flag]
        XCTAssertEqual(
            try ItemSort.ordered(all, by: [ItemSort(property: "value")]).map(\.itemID),
            (expected + missing).map(\.itemID))
        XCTAssertEqual(
            try ItemSort.ordered(all, by: [ItemSort(property: "value", isAscending: false)]).map(\.itemID),
            (expected.reversed() + missing).map(\.itemID))
        XCTAssertEqual(
            try ItemSort.ordered(all, by: [ItemSort(property: "value.secret")]).map(\.itemID),
            all.map(\.itemID).sorted())
        let maximum = try create(store, ["value": .integer(Int64.max)])
        let larger = try create(store, ["value": .real(9_223_372_036_854_775_808)])
        XCTAssertEqual(
            try ItemSort.ordered([larger, maximum], by: [ItemSort(property: "value")]).first?.itemID,
            maximum.itemID)
        let first = try create(store, ["subject": .text("Alpha"), "rank": .integer(1)])
        let second = try create(store, ["subject": .text("Beta"), "rank": .integer(1)])
        XCTAssertEqual(
            try ItemSort.ordered(
                [second, first],
                by: [
                    ItemSort(property: "rank"), ItemSort(property: "kMDItemTitle"),
                ]
            ).map(\.itemID), [first.itemID, second.itemID])
    }

    func testCategorySortUsesAuthorizedEffectiveMembershipAndOrderedChildren() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        func category(_ subject: String, parents: [Revision] = [], rule: String = "fixture == \"never\"")
            throws
            -> Revision
        {
            try create(
                store,
                [
                    "subject": .text(subject),
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text(rule),
                    ]),
                    "categoryParents": .list(parents.map { .reference(ItemReference($0.itemID)) }),
                ])
        }
        var root = try category("Root")
        let first = try category("First", parents: [root], rule: "branch == \"first\"")
        let second = try category("Second", parents: [root], rule: "branch == \"second\"")
        let blocked = try category("Blocked", rule: "branch == \"blocked\"")
        root = try edit(
            store, root,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("fixture == \"never\""),
                    "excludedCategoryIDs": .list([.reference(ItemReference(blocked.itemID))]),
                ])
            ])
        func item(_ name: String, branch: String, overrides: [String: ItemValue] = [:]) throws -> Revision {
            try create(
                store,
                [
                    "subject": .text(name), "fixture": .text("yes"), "branch": .text(branch),
                    "legacyRank": .text(name), "categoryOverrides": .object(overrides),
                ])
        }
        let firstOnly = try item("B", branch: "first")
        let both = try item("A", branch: "first", overrides: [second.itemID: .text("include")])
        let manualSecond = try item("C", branch: "none", overrides: [second.itemID: .text("include")])
        let secondOnly = try item("Z", branch: "second")
        let rootOnly = try item("D", branch: "none", overrides: [root.itemID: .text("include")])
        let excluded = try item(
            "E", branch: "first", overrides: [blocked.itemID: .text("include")])
        let categorySort = try ItemSort(categoryRootID: root.itemID)
        let metadata = try ItemSort(property: "legacyRank")
        XCTAssertEqual(
            try Categories.query(
                store: store, expression: "fixture == \"yes\"", sort: [categorySort, metadata]
            )
            .map(\.itemID),
            [both, firstOnly, manualSecond, secondOnly, rootOnly, excluded].map(\.itemID))
        XCTAssertEqual(
            try Categories.query(
                store: store, expression: "fixture == \"yes\"",
                sort: [try ItemSort(categoryRootID: root.itemID, isAscending: false), metadata]
            )
            .map(\.itemID),
            [manualSecond, secondOnly, both, firstOnly, rootOnly, excluded].map(\.itemID))
        let projection = try Categories.memberships(
            store: store, ids: [both.itemID, rootOnly.itemID, excluded.itemID],
            categoryRootIDs: [root.itemID], at: Date())
        XCTAssertEqual(projection.roots.first?.children.map(\.id), [first.itemID, second.itemID])
        XCTAssertEqual(projection.memberships[both.itemID]?[root.itemID], [first.itemID, second.itemID])
        XCTAssertNil(projection.memberships[rootOnly.itemID]?[root.itemID])
        XCTAssertNil(projection.memberships[excluded.itemID]?[root.itemID])
        _ = try edit(store, second, ["categoryOrder": .integer(-1)])
        try store.rebuildIndex()
        XCTAssertEqual(
            try Categories.query(
                store: store, expression: "fixture == \"yes\"", sort: [categorySort, metadata]
            )
            .map(\.itemID),
            [both, manualSecond, secondOnly, firstOnly, rootOnly, excluded].map(\.itemID))
    }

    func testCategorySortDescriptorsUseCurrentReferencesInSavedViews() throws {
        let rootID = Identifier.make()
        let descriptor = try ItemSort(categoryRootID: rootID, isAscending: false)
        XCTAssertEqual(descriptor.value.map?["categoryRootID"], .reference(ItemReference(rootID)))
        let definition: [String: ItemValue] = [
            "language": .text(SpotlightQuery.profile), "sort": .list([descriptor.value]),
        ]
        XCTAssertEqual(try SavedViewDefinition(.object(definition)).sort, [descriptor])
        var malformed = definition
        malformed["sort"] = .list([
            .object([
                "categoryRootID": .text(rootID), "isAscending": .boolean(true),
            ])
        ])
        XCTAssertThrowsError(try SavedViewDefinition(.object(malformed)))
        malformed["sort"] = .list([
            .object([
                "property": .text("subject"), "categoryRootID": .reference(ItemReference(rootID)),
            ])
        ])
        XCTAssertThrowsError(try SavedViewDefinition(.object(malformed)))
    }

    func testSavedSectionsIntersectFiltersAndHonorManualDecisions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Identifier.make())
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ItemStore(root: directory)
        let category = try create(
            store,
            [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("subject == \"match\""),
                ])
            ])
        let included = try create(
            store,
            [
                "subject": .text("exception"), "body": .text("chess"),
                "deadline": .date("2026-09-08T10:00:00Z"),
                "categoryOverrides": .object([category.itemID: .text("include")]),
            ])
        _ = try create(
            store,
            [
                "subject": .text("match"), "body": .text("chess"),
                "deadline": .date("2026-09-08T10:00:00Z"),
                "categoryOverrides": .object([category.itemID: .text("exclude")]),
            ])
        _ = try create(
            store,
            [
                "subject": .text("match"), "body": .text("football"),
                "deadline": .date("2026-09-08T10:00:00Z"),
            ])
        var definition: [String: ItemValue] = [
            "language": .text(SpotlightQuery.profile), "text": .text("chess"),
            "expression": .text("deadline >= $time.iso(\"2026-09-08T00:00:00Z\")"),
            "presentation": .object([
                "profile": .text(ViewPresentation.profile),
                "sections": .list([.reference(ItemReference(category.itemID))]),
            ]),
        ]
        let view = try create(store, ["viewDefinition": .object(definition)])
        XCTAssertEqual(
            try Categories.savedView(store: store, id: view.itemID, sectionID: category.itemID).map(\.itemID),
            [included.itemID])
        XCTAssertEqual(
            try Categories.savedView(store: store, id: view.itemID).count, 2,
            "Presentation sections must not narrow a plain view query used by another client.")
        XCTAssertThrowsError(
            try Categories.savedView(store: store, id: view.itemID, sectionID: Identifier.make()))
        definition["presentation"] = .object([
            "profile": .text(ViewPresentation.profile),
            "collapsedSections": .list([.reference(ItemReference(category.itemID))]),
        ])
        XCTAssertThrowsError(try SavedViewDefinition(.object(definition)))
        definition["presentation"] = .object([
            "profile": .text(ViewPresentation.profile), "columns": .list([]),
        ])
        XCTAssertThrowsError(try SavedViewDefinition(.object(definition)))
    }
}
